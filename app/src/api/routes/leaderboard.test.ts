import { expect, test } from "bun:test";
import pino from "pino";
import { createApiApp } from "../app";
import { TtlCache } from "../cache";
import type { ApiDependencies } from "../types";

const first = "0x1111111111111111111111111111111111111111";
const second = "0x2222222222222222222222222222222222222222";
const third = "0x3333333333333333333333333333333333333333";

function appWith(calls: string[]) {
  const sql = async () => [];
  Object.assign(sql, {
    unsafe: async (query: string) => {
      calls.push(query);
      return [
        { account: third, volume: "5", trades: 1, markets: 1, top_market: "NVDA", last_trade_at: new Date("2026-10-06T00:00:00Z") },
        { account: first, volume: "30", trades: 3, markets: 2, top_market: "TSLA", last_trade_at: new Date("2026-10-07T00:00:00Z") },
        { account: second, volume: "20", trades: 5, markets: 1, top_market: "NVDA", last_trade_at: new Date("2026-10-05T00:00:00Z") },
      ];
    },
  });
  return createApiApp({
    sql,
    config: { CORS_ORIGINS: [], API_RATE_LIMIT_PER_MINUTE: 0, API_CLIENT_IP_HEADER: "", NETWORK: "mainnet" },
    deployment: {},
    logger: pino({ level: "silent" }),
    cache: new TtlCache(),
  } as unknown as ApiDependencies);
}

test("leaderboard ranks by volume over 7D by default", async () => {
  const response = await appWith([]).request("/v1/leaderboard");
  expect(response.status).toBe(200);
  expect(response.headers.get("cache-control")).toBe("public, max-age=30, stale-while-revalidate=120");
  const body = await response.json() as { range: string; sort: string; totalTraders: number; rows: Array<{ rank: number; address: string }> };
  expect(body.range).toBe("7D");
  expect(body.sort).toBe("volume");
  expect(body.totalTraders).toBe(3);
  expect(body.rows.map((row) => [row.rank, row.address])).toEqual([[1, first], [2, second], [3, third]]);
});

test("leaderboard limits rows but counts every trader", async () => {
  const response = await appWith([]).request("/v1/leaderboard?range=ALL&sort=trades&limit=2");
  const body = await response.json() as { totalTraders: number; rows: Array<{ address: string }> };
  expect(body.totalTraders).toBe(3);
  expect(body.rows.map((row) => row.address)).toEqual([second, first]);
});

test("leaderboard rejects unknown ranges and limits", async () => {
  const app = appWith([]);
  expect((await app.request("/v1/leaderboard?range=1Y")).status).toBe(400);
  expect((await app.request("/v1/leaderboard?sort=pnl")).status).toBe(400);
  expect((await app.request("/v1/leaderboard?limit=101")).status).toBe(400);
});
