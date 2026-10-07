import { expect, test } from "bun:test";
import { TtlCache } from "../../api/cache";
import type { ApiDependencies } from "../../api/types";
import { getMarketDetail, listMarkets } from "./markets";

test("market list and detail add configured metadata without inventing unknown labels", async () => {
  const sql = async (strings: TemplateStringsArray) => {
    const query = strings.join("?");
    if (query.includes("from markets m")) return ["NVDA", "AMD", "QQQ", "COIN", "NEW"].map((symbol, id) => ({
      id, symbol, token: `0x${String(id + 1).padStart(40, "0")}`, config: {}, price: "10", norm_factor: "1", regime: 0,
    }));
    return [];
  };
  const deps = { sql, cache: new TtlCache() } as unknown as ApiDependencies;
  const now = new Date("2026-10-05T12:00:00Z");
  const markets = await listMarkets(deps, now);
  expect(markets).toHaveLength(5);
  expect(markets[0]?.meta?.name).toBe("NVIDIA");
  expect(markets[1]?.meta?.color).toBe("#ff6b9a");
  expect(markets[2]?.meta?.category).toBe("Index");
  expect(markets[3]?.meta?.name).toBe("Coinbase");
  expect(markets[4]?.meta).toBeUndefined();
  expect(JSON.parse(JSON.stringify(markets[4])).meta).toBeUndefined();
  expect((await getMarketDetail(deps, "AMD", now))?.meta).toEqual(markets[1]?.meta);
});
