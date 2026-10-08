import { expect, test } from "bun:test";
import { TtlCache } from "../../api/cache";
import type { ApiDependencies } from "../../api/types";
import { flowSeries, hottestTokens, marketTokenFlow } from "./token-flow";

const STOCK = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

test("flowSeries returns an oldest-first window with zeroes for missing dates", () => {
  const result = flowSeries([
    { flow_date: "2026-10-06", mint_burn_usd: "12.5" },
    { flow_date: "2026-10-08", mint_burn_usd: "0" },
  ], 7, "2026-10-08");

  expect(result).toHaveLength(7);
  expect(result[0]).toEqual({ date: "2026-10-02", mintBurnUsd: "0" });
  expect(result[4]).toEqual({ date: "2026-10-06", mintBurnUsd: "12.5" });
  expect(result[6]).toEqual({ date: "2026-10-08", mintBurnUsd: "0" });
});

function depsWith(
  calls: Array<{ query: string; values: unknown[] }>,
  flowRows: Array<Record<string, unknown>> = [],
  hottestRows: Array<Record<string, unknown>> = [],
) {
  const cache = new TtlCache();
  void cache.getOrLoad("markets:list", 60_000, async () => [{ id: 1, symbol: "NVDA" }]);
  const sql = async (strings: TemplateStringsArray, ...values: unknown[]) => {
    const query = strings.join("?");
    calls.push({ query, values });
    if (query.includes("select stock from markets")) return [{ stock: STOCK }];
    if (query.includes("from token_flow")) return flowRows;
    if (query.includes("from ref_prices")) return hottestRows;
    return [];
  };
  return { cache, config: { NETWORK: "mainnet" }, sql } as unknown as ApiDependencies;
}

test("marketTokenFlow resolves a listed market, uses its token rows, and marks fresh today's flow", async () => {
  const calls: Array<{ query: string; values: unknown[] }> = [];
  const now = new Date("2026-10-08T12:00:00Z");
  const deps = depsWith(calls, [
    { flow_date: "2026-10-06", mint_burn_usd: "12.5", updated_at: new Date("2026-10-06T12:00:00Z") },
    { flow_date: "2026-10-08", mint_burn_usd: "4.3", updated_at: new Date("2026-10-08T11:50:00Z") },
  ]);

  const result = await marketTokenFlow(deps, "nvda", 7, now);
  expect(result).toMatchObject({ symbol: "NVDA", todayUsd: "4.3", asOf: "2026-10-08T11:50:00.000Z" });
  expect(result?.days).toHaveLength(7);
  expect(result?.days[0]).toEqual({ date: "2026-10-02", mintBurnUsd: "0" });
  expect(result?.days[4]).toEqual({ date: "2026-10-06", mintBurnUsd: "12.5" });
  expect(result?.days[6]).toEqual({ date: "2026-10-08", mintBurnUsd: "4.3" });
  expect(calls.find((call) => call.query.includes("select stock from markets"))?.values).toContain(1);
  const flowCall = calls.find((call) => call.query.includes("from token_flow"));
  expect(flowCall?.values).toEqual([STOCK, "2026-10-02", "2026-10-08"]);
});

test("marketTokenFlow returns null for unknown markets and stale today values", async () => {
  const unknownCalls: Array<{ query: string; values: unknown[] }> = [];
  expect(await marketTokenFlow(depsWith(unknownCalls), "NOPE", 30, new Date("2026-10-08T12:00:00Z"))).toBeNull();
  expect(unknownCalls).toEqual([]);

  const staleCalls: Array<{ query: string; values: unknown[] }> = [];
  const stale = await marketTokenFlow(depsWith(staleCalls, [
    { flow_date: "2026-10-08", mint_burn_usd: "4.3", updated_at: new Date("2026-10-08T11:44:59Z") },
  ]), "NVDA", 30, new Date("2026-10-08T12:00:00Z"));
  expect(stale?.todayUsd).toBeNull();
  expect(stale?.days).toHaveLength(30);
});

test("hottestTokens returns ranked fresh rows and the listed flag", async () => {
  const calls: Array<{ query: string; values: unknown[] }> = [];
  const now = new Date("2026-10-08T12:00:00Z");
  const result = await hottestTokens(depsWith(calls, [], [
    { symbol: "NVDA", mint_burn_usd: "4300000", fetched_at: new Date("2026-10-08T11:59:00Z"), listed: true },
    { symbol: "USO", mint_burn_usd: "1810000", fetched_at: new Date("2026-10-08T11:59:00Z"), listed: false },
  ]), 8, now);

  expect(result).toEqual({
    asOf: "2026-10-08T11:59:00.000Z",
    tokens: [
      { symbol: "NVDA", mintBurnUsd: "4300000", listedOnOgee: true },
      { symbol: "USO", mintBurnUsd: "1810000", listedOnOgee: false },
    ],
  });
  expect(calls[0]?.query).toContain("left join markets m on lower(m.stock) = r.stock");
  expect(calls[0]?.query).toContain("interval '10 minutes'");
  expect(calls[0]?.query).toContain("order by r.mint_burn_usd desc limit ?");
  expect(calls[0]?.values).toEqual([now.toISOString(), 8]);
});
