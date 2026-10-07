import { expect, test } from "bun:test";
import { TtlCache } from "../../api/cache";
import type { ApiDependencies } from "../../api/types";
import { getMarketDetail, listMarkets, marketCandles, mergeVolume } from "./markets";

test("market list and detail add configured metadata without inventing unknown labels", async () => {
  const sql = async (strings: TemplateStringsArray) => {
    const query = strings.join("?");
    if (query.includes("from markets m")) return ["NVDA", "AMD", "QQQ", "NEW"].map((symbol, id) => ({
      id, symbol, token: `0x${String(id + 1).padStart(40, "0")}`, config: {}, price: "10", norm_factor: "1", regime: 0,
    }));
    return [];
  };
  const deps = { sql, cache: new TtlCache() } as unknown as ApiDependencies;
  const now = new Date("2026-10-05T12:00:00Z");
  const markets = await listMarkets(deps, now);
  expect(markets).toHaveLength(4);
  expect(markets[0]?.meta?.name).toBe("NVIDIA");
  expect(markets[1]?.meta?.color).toBe("#ff6b9a");
  expect(markets[2]?.meta?.category).toBe("Index");
  expect(markets[3]?.meta).toBeUndefined();
  expect(JSON.parse(JSON.stringify(markets[3])).meta).toBeUndefined();
  expect((await getMarketDetail(deps, "AMD", now))?.meta).toEqual(markets[1]?.meta);
});

test("mergeVolume attaches bucket volume and zero-fills buckets without trades", () => {
  const candle = (t: number) => ({ t, o: "1", h: "1", l: "1", c: "1" });
  const merged = mergeVolume([candle(0), candle(900), candle(1800)], [
    { t: "900", v: "12.5", vb: "10", vs: "2.5", n: 3 },
    { t: "3600", v: "99", vb: "99", vs: "0", n: 1 },
  ]);
  expect(merged).toEqual([
    { ...candle(0), v: "0", vb: "0", vs: "0", n: 0 },
    { ...candle(900), v: "12.5", vb: "10", vs: "2.5", n: 3 },
    { ...candle(1800), v: "0", vb: "0", vs: "0", n: 0 },
  ]);
  expect(mergeVolume([], [{ t: 0, v: "1", vb: "1", vs: "0", n: 1 }])).toEqual([]);
});

function candleDeps(bucket: number) {
  const queries: string[] = [];
  const sql = Object.assign(
    async (strings: TemplateStringsArray) => strings.join("?").includes("from markets") ? [{ id: 1 }] : [],
    {
      unsafe: async (query: string) => {
        if (query.includes("from trades")) {
          queries.push(query);
          return [{ t: String(bucket), v: "5", vb: "3", vs: "2", n: 2 }];
        }
        return [{ t: String(bucket), o: "10", h: "11", l: "9", c: "10.5" }];
      },
    },
  );
  return { deps: { sql, cache: new TtlCache(), config: { NETWORK: "mainnet" } } as unknown as ApiDependencies, queries };
}

test("marketCandles buckets trade volume with the range interval", async () => {
  const now = new Date("2026-10-07T12:07:00Z");
  const bucket = Date.UTC(2026, 9, 7, 11, 45) / 1000;
  const day = candleDeps(bucket);
  const candles = await marketCandles(day.deps, "NVDA", "1D", "price", now);
  expect(day.queries[0]).toContain("time_bucket(interval '15 minutes'");
  expect(day.queries[0]).toContain("interval '1 day'");
  expect(candles?.find((candle) => candle.t === bucket)).toMatchObject({ c: "10.5", v: "5", vb: "3", vs: "2", n: 2 });
  expect(candles?.at(-1)).toMatchObject({ v: "0", vb: "0", vs: "0", n: 0 });

  const allBucket = Date.UTC(2026, 9, 7) / 1000;
  const all = candleDeps(allBucket);
  const price = await marketCandles(all.deps, "NVDA", "ALL", "price", now);
  const index = await marketCandles(all.deps, "NVDA", "ALL", "index", now);
  expect(all.queries[0]).toContain("time_bucket(interval '1 day'");
  expect(all.queries[0]?.split("where")[1]).not.toContain("interval");
  expect(price?.map((candle) => candle.v)).toEqual(["5"]);
  expect(index?.map((candle) => candle.v)).toEqual(price?.map((candle) => candle.v));
});

test("getMarketDetail reports 24h buy and sell volume", async () => {
  const sql = async (strings: TemplateStringsArray) => {
    const query = strings.join("?");
    if (query.includes("from markets m")) return [{ id: 1, symbol: "NVDA", token: `0x${"1".padStart(40, "0")}`, config: {}, price: "10", norm_factor: "1", regime: 0 }];
    if (query.includes("buy_volume_24h")) return [{ trades_24h: 4, holders: 2, buy_volume_24h: "7", sell_volume_24h: "3" }];
    return [];
  };
  const deps = { sql, cache: new TtlCache() } as unknown as ApiDependencies;
  const detail = await getMarketDetail(deps, "nvda", new Date("2026-10-07T12:00:00Z"));
  expect(detail?.stats).toEqual({ trades24h: 4, holders: 2, buyVolume24hUsd: "7", sellVolume24hUsd: "3" });
  expect((await listMarkets(deps, new Date("2026-10-07T12:00:00Z")))[0]?.stats).toEqual({
    trades24h: 0, holders: 0, buyVolume24hUsd: "0", sellVolume24hUsd: "0",
  });
});
