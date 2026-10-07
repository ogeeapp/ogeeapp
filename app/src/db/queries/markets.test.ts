import { expect, test } from "bun:test";
import { TtlCache } from "../../api/cache";
import type { ApiDependencies } from "../../api/types";
import { getMarketDetail, listMarkets, mergeVolume } from "./markets";

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
