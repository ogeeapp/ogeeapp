import { expect, test } from "bun:test";
import type { ApiDependencies } from "../../api/types";
import { aggregateStats } from "./stats";

test("stats default fees, traders and all-time totals when nothing has traded", async () => {
  const deps = {
    config: { NETWORK: "mainnet" },
    sql: async (strings: TemplateStringsArray) => {
      const query = strings.join("?");
      if (query.includes("from markets")) return [];
      if (query.includes("vault_ticks")) return [];
      if (query.includes("traders_all")) return [{}];
      return [{ trades_24h: 0 }];
    },
  } as unknown as ApiDependencies;
  const stats = await aggregateStats(deps);
  expect(stats).toMatchObject({
    openInterestUsd: "0", volume24hUsd: "0", trades24h: 0, tvlUsd: "0",
    fees24hUsd: "0", uniqueTraders24h: 0, volumeAllTimeUsd: "0", tradesAllTime: 0, tradersAllTime: 0,
    markets: [],
  });
});
