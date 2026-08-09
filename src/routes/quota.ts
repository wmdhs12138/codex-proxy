/**
 * GET /v1/quota — compact, client-friendly Codex quota summary.
 *
 * This endpoint intentionally returns a pre-formatted display string so simple
 * clients (for example RikkaHub's balance widget) do not need date or quota
 * window formatting logic of their own.
 */

import { Hono } from "hono";
import type { AccountPool } from "../auth/account-pool.js";
import type { AccountInfo, CodexQuota, CodexQuotaWindow } from "../auth/types.js";
import { apiKeyAuth } from "../middleware/api-key-auth.js";

const WEEK_SECONDS = 7 * 24 * 60 * 60;
const WEEK_TOLERANCE_SECONDS = 24 * 60 * 60;

type QuotaWindow = CodexQuotaWindow & { limit_reached?: boolean };

export interface FormattedQuotaAccount {
  id: string;
  label: string | null;
  status: AccountInfo["status"];
  plan_type: string | null;
  used_percent: number | null;
  remaining_percent: number | null;
  reset_at: number | null;
  limit_window_seconds: number | null;
  quota_fetched_at: string | null;
}

function finiteNumber(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function clampPercent(value: number | null): number | null {
  return value == null ? null : Math.max(0, Math.min(100, value));
}

function normalizedPercent(window: QuotaWindow): { used: number | null; remaining: number | null } {
  const usedRaw = finiteNumber(window.used_percent);
  const remainingRaw = finiteNumber(window.remaining_percent);
  const used = clampPercent(usedRaw ?? (remainingRaw == null ? null : 100 - remainingRaw));
  const remaining = clampPercent(
    window.limit_reached === true ? 0 : remainingRaw ?? (usedRaw == null ? null : 100 - usedRaw),
  );
  return { used, remaining };
}

function isWeeklyWindow(window: QuotaWindow | null | undefined): window is QuotaWindow {
  const seconds = finiteNumber(window?.limit_window_seconds);
  return seconds != null && Math.abs(seconds - WEEK_SECONDS) <= WEEK_TOLERANCE_SECONDS;
}

/** Select the weekly window regardless of whether upstream puts it in primary or secondary. */
export function selectWeeklyWindow(quota: CodexQuota): QuotaWindow | null {
  // The top-level window is the general Codex allowance used by normal chat.
  // Prefer it over feature-specific additional buckets such as code review.
  const generalCandidates: QuotaWindow[] = [quota.rate_limit];
  if (quota.secondary_rate_limit) generalCandidates.push(quota.secondary_rate_limit);
  const generalWeekly = generalCandidates.filter(isWeeklyWindow);
  if (generalWeekly.length > 0) {
    return generalWeekly.sort((a, b) => {
      const ar = normalizedPercent(a).remaining ?? 101;
      const br = normalizedPercent(b).remaining ?? 101;
      return ar - br;
    })[0];
  }

  // Some upstream variants only expose weekly metadata in additional buckets.
  const additionalCandidates: QuotaWindow[] = [];
  for (const bucket of Object.values(quota.rate_limits_by_limit_id ?? {})) {
    additionalCandidates.push(bucket);
    if (bucket.secondary_rate_limit) additionalCandidates.push(bucket.secondary_rate_limit);
  }
  const additionalWeekly = additionalCandidates.filter(isWeeklyWindow);
  if (additionalWeekly.length > 0) {
    return additionalWeekly.sort((a, b) => {
      const ar = normalizedPercent(a).remaining ?? 101;
      const br = normalizedPercent(b).remaining ?? 101;
      return ar - br;
    })[0];
  }

  // Compatibility fallback for older cached quota without window metadata.
  return quota.secondary_rate_limit ?? quota.rate_limit ?? null;
}

function roundedPercent(value: number | null): number | null {
  return value == null ? null : Math.round(value * 10) / 10;
}

function formatPercent(value: number | null): string {
  if (value == null) return "—";
  return Number.isInteger(value) ? String(value) : value.toFixed(1);
}

/** Compact, locale-neutral countdown for narrow balance rows. */
export function formatCompactResetCountdown(resetAt: number | null, nowMs = Date.now()): string | null {
  if (resetAt == null || !Number.isFinite(resetAt)) return null;
  const remainingSeconds = Math.max(0, Math.ceil(resetAt - nowMs / 1000));
  if (remainingSeconds < 60) return "<1m";

  const days = Math.floor(remainingSeconds / 86400);
  const hours = Math.floor((remainingSeconds % 86400) / 3600);
  const minutes = Math.floor((remainingSeconds % 3600) / 60);

  if (days > 0) return `${days}d${hours > 0 ? `${hours}h` : ""}`;
  if (hours > 0) return `${hours}h${minutes > 0 ? `${minutes}m` : ""}`;
  return `${Math.max(1, minutes)}m`;
}

export function formatResetCountdown(resetAt: number | null, nowMs = Date.now(), lang: "zh" | "en" = "zh"): string | null {
  if (resetAt == null || !Number.isFinite(resetAt)) return null;
  const remainingSeconds = Math.max(0, Math.ceil(resetAt - nowMs / 1000));
  if (remainingSeconds < 60) return lang === "zh" ? "即将重置" : "resetting soon";

  const days = Math.floor(remainingSeconds / 86400);
  const hours = Math.floor((remainingSeconds % 86400) / 3600);
  const minutes = Math.floor((remainingSeconds % 3600) / 60);

  if (lang === "zh") {
    if (days > 0) return `${days}天${hours > 0 ? `${hours}小时` : ""}后重置`;
    if (hours > 0) return `${hours}小时${minutes > 0 ? `${minutes}分钟` : ""}后重置`;
    return `${Math.max(1, minutes)}分钟后重置`;
  }
  if (days > 0) return `resets in ${days}d${hours > 0 ? ` ${hours}h` : ""}`;
  if (hours > 0) return `resets in ${hours}h${minutes > 0 ? ` ${minutes}m` : ""}`;
  return `resets in ${Math.max(1, minutes)}m`;
}

function formatDisplay(remaining: number | null, resetAt: number | null, nowMs: number, lang: "zh" | "en"): string {
  const percent = formatPercent(remaining);
  const countdown = formatResetCountdown(resetAt, nowMs, lang);
  const base = lang === "zh" ? `周余 ${percent}%` : `Weekly ${percent}% left`;
  return countdown ? `${base} · ${countdown}` : base;
}

function formatCompactDisplay(remaining: number | null, resetAt: number | null, nowMs: number): string {
  const base = `${formatPercent(remaining)}%`;
  const countdown = formatCompactResetCountdown(resetAt, nowMs);
  return countdown ? `${base} ↻${countdown}` : base;
}

export function buildFormattedQuota(accounts: AccountInfo[], nowMs = Date.now()) {
  const formatted: FormattedQuotaAccount[] = accounts.flatMap((account) => {
    if (!account.quota) return [];
    const window = selectWeeklyWindow(account.quota);
    if (!window) return [];
    const percent = normalizedPercent(window);
    return [{
      id: account.id,
      label: account.label,
      status: account.status,
      plan_type: account.quota.plan_type || account.planType,
      used_percent: roundedPercent(percent.used),
      remaining_percent: roundedPercent(percent.remaining),
      reset_at: finiteNumber(window.reset_at),
      limit_window_seconds: finiteNumber(window.limit_window_seconds),
      quota_fetched_at: account.quotaFetchedAt ?? null,
    }];
  });

  const active = formatted.filter((item) => item.status === "active");
  // At provider/pool level, show the best currently usable account: this is
  // the quota the router can still draw from after rotating exhausted accounts.
  // Never fall back to disabled, expired, banned, or exhausted accounts: a
  // positive cached percentage on an unusable account would misrepresent the
  // capacity that clients can actually draw from.
  const selected = [...active].sort((a, b) =>
    (b.remaining_percent ?? -1) - (a.remaining_percent ?? -1)
  )[0] ?? null;

  const displayZh = selected
    ? formatDisplay(selected.remaining_percent, selected.reset_at, nowMs, "zh")
    : "周额度暂无数据";
  const displayEn = selected
    ? formatDisplay(selected.remaining_percent, selected.reset_at, nowMs, "en")
    : "Weekly quota unavailable";
  const displayCompact = selected
    ? formatCompactDisplay(selected.remaining_percent, selected.reset_at, nowMs)
    : "—";

  return {
    // RikkaHub already renders a money-bag icon before this value. Keep its
    // default result deliberately short; verbose localized variants remain
    // available for clients with more horizontal space.
    display: displayCompact,
    display_compact: displayCompact,
    display_zh: displayZh,
    display_en: displayEn,
    strategy: "best_available" as const,
    account_count: accounts.length,
    active_account_count: accounts.filter((account) => account.status === "active").length,
    accounts_with_quota: formatted.length,
    selected_account_id: selected?.id ?? null,
    weekly: selected ? {
      used_percent: selected.used_percent,
      remaining_percent: selected.remaining_percent,
      reset_at: selected.reset_at,
      limit_window_seconds: selected.limit_window_seconds,
      quota_fetched_at: selected.quota_fetched_at,
    } : null,
    accounts: formatted,
  };
}

export function createQuotaRoutes(accountPool: AccountPool): Hono {
  const app = new Hono();
  app.get("/v1/quota", apiKeyAuth(accountPool), (c) => {
    const data = buildFormattedQuota(accountPool.getAccounts());
    const lang = c.req.query("lang")?.toLowerCase();
    const style = c.req.query("style")?.toLowerCase();
    if (style === "verbose") {
      data.display = lang === "en" ? data.display_en : data.display_zh;
    }
    return c.json({ data });
  });
  return app;
}
