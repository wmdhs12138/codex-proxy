import { afterEach, describe, expect, it, vi } from "vitest";

const configState = vi.hoisted(() => ({ proxyApiKey: null as string | null }));

vi.mock("@src/config.js", () => ({
  getConfig: () => ({ server: { proxy_api_key: configState.proxyApiKey } }),
}));
import { Hono } from "hono";
import type { AccountInfo, CodexQuota } from "@src/auth/types.js";
import {
  buildFormattedQuota,
  createQuotaRoutes,
  formatCompactResetCountdown,
  formatResetCountdown,
  selectWeeklyWindow,
} from "@src/routes/quota.js";

function quota(primarySeconds: number | null, primaryRemaining: number, secondary?: { seconds: number; remaining: number }): CodexQuota {
  return {
    plan_type: "plus",
    rate_limit: {
      allowed: true,
      limit_reached: false,
      used_percent: 100 - primaryRemaining,
      remaining_percent: primaryRemaining,
      reset_at: 2_000_000_000,
      limit_window_seconds: primarySeconds,
    },
    secondary_rate_limit: secondary ? {
      limit_reached: false,
      used_percent: 100 - secondary.remaining,
      remaining_percent: secondary.remaining,
      reset_at: 2_000_100_000,
      limit_window_seconds: secondary.seconds,
    } : null,
    code_review_rate_limit: null,
  };
}

function account(id: string, remaining: number, status: AccountInfo["status"] = "active"): AccountInfo {
  return {
    id,
    email: null,
    accountId: null,
    userId: null,
    label: null,
    planType: "plus",
    status,
    usage: { input_tokens: 0, output_tokens: 0, request_count: 0 },
    addedAt: "2026-01-01T00:00:00.000Z",
    expiresAt: null,
    quota: quota(604800, remaining),
    quotaFetchedAt: "2026-07-29T12:00:00.000Z",
  };
}

describe("formatted quota", () => {
  afterEach(() => {
    configState.proxyApiKey = null;
  });

  it("finds a weekly window in secondary when primary is shorter", () => {
    const selected = selectWeeklyWindow(quota(18000, 90, { seconds: 604800, remaining: 72 }));
    expect(selected?.remaining_percent).toBe(72);
  });

  it("uses a weekly additional bucket when the general window is shorter", () => {
    const q = quota(18000, 80);
    q.rate_limits_by_limit_id = {
      review: {
        limit_id: "review",
        limit_name: "Review",
        allowed: true,
        limit_reached: false,
        used_percent: 55,
        remaining_percent: 45,
        reset_at: 2_000_000_000,
        limit_window_seconds: 604800,
      },
    };
    expect(selectWeeklyWindow(q)?.remaining_percent).toBe(45);
  });

  it("formats Chinese and English reset countdowns", () => {
    const now = 1_000_000_000_000;
    const reset = now / 1000 + 2 * 86400 + 3 * 3600;
    expect(formatResetCountdown(reset, now, "zh")).toBe("2天3小时后重置");
    expect(formatResetCountdown(reset, now, "en")).toBe("resets in 2d 3h");
  });

  it("formats a compact reset countdown for narrow balance rows", () => {
    const now = 1_000_000_000_000;
    expect(formatCompactResetCountdown(now / 1000 + 2 * 86400 + 3 * 3600, now)).toBe("2d3h");
    expect(formatCompactResetCountdown(now / 1000 + 3 * 3600 + 7 * 60, now)).toBe("3h7m");
    expect(formatCompactResetCountdown(now / 1000 + 42, now)).toBe("<1m");
  });

  it("uses the best active account for a provider-level display", () => {
    const data = buildFormattedQuota([
      account("low", 18),
      account("high", 81),
      account("disabled", 99, "disabled"),
    ], 1_999_900_000_000);
    expect(data.selected_account_id).toBe("high");
    expect(data.weekly?.remaining_percent).toBe(81);
    expect(data.display).toBe("81% ↻1d3h");
    expect(data.display_compact).toBe(data.display);
    expect(data.display_zh).toContain("周余 81%");
    expect(data.display_en).toContain("Weekly 81% left");
  });

  it("does not present quota from unusable accounts as pool capacity", () => {
    const data = buildFormattedQuota([
      account("disabled", 99, "disabled"),
      account("expired", 87, "expired"),
      account("banned", 76, "banned"),
    ]);
    expect(data.selected_account_id).toBeNull();
    expect(data.weekly).toBeNull();
    expect(data.display).toBe("—");
    expect(data.display_zh).toBe("周额度暂无数据");
  });

  it("returns a compact /v1/quota response by default", async () => {
    const pool = {
      getAccounts: () => [account("only", 81)],
      validateProxyApiKey: () => true,
    };
    const app = new Hono();
    app.route("/", createQuotaRoutes(pool as never));
    const response = await app.request("/v1/quota");
    expect(response.status).toBe(200);
    const body = await response.json() as { data: { display: string; weekly: { remaining_percent: number } } };
    expect(body.data.display).toMatch(/^81% ↻\d+d(?:\d+h)?$/);
    expect(body.data.weekly.remaining_percent).toBe(81);
  });

  it("keeps localized verbose output available on demand", async () => {
    const pool = {
      getAccounts: () => [account("only", 81)],
      validateProxyApiKey: () => true,
    };
    const app = new Hono();
    app.route("/", createQuotaRoutes(pool as never));
    const response = await app.request("/v1/quota?style=verbose&lang=en");
    const body = await response.json() as { data: { display: string } };
    expect(body.data.display).toContain("Weekly 81% left");
  });

  it("requires the configured proxy API key", async () => {
    configState.proxyApiKey = "test-secret";
    const pool = {
      getAccounts: () => [account("only", 81)],
      validateProxyApiKey: (key: string) => key === "test-secret",
    };
    const app = new Hono();
    app.route("/", createQuotaRoutes(pool as never));

    expect((await app.request("/v1/quota")).status).toBe(401);
    expect((await app.request("/v1/quota", {
      headers: { Authorization: "Bearer test-secret" },
    })).status).toBe(200);
  });
});
