import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

describe("startup secret boundary", () => {
  it("does not interpolate proxy API keys into the startup log", () => {
    const source = readFileSync("src/index.ts", "utf8");
    const consoleLines = source
      .split("\n")
      .filter((line) => line.includes("console.log"));

    expect(consoleLines.join("\n")).not.toMatch(/proxy_api_key|getProxyApiKey/);
    expect(source).toContain('console.log("  Key:  configured (hidden)")');
  });
});
