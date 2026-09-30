import { fixed, decimal } from "../../lib/fixed";
import { apiNow } from "../../api/clock";
import type { ApiDependencies, DbRow } from "../../api/types";
import { asRows, numberValue } from "../../api/types";
import { listMarkets } from "./markets";

export async function aggregateStats(deps: ApiDependencies) {
  const now = await apiNow(deps);
  const [markets, vaultResult, tradeResult] = await Promise.all([
    listMarkets(deps, now),
    deps.sql`select total_assets::text from vault_ticks order by ts desc limit 1`,
    deps.sql`select count(*)::int as trades_24h from trades where ts >= ${now.toISOString()}::timestamptz - interval '24 hours'`,
  ]);
  const openInterest = markets.reduce((total, market) => total + fixed(market.openInterestUsd), 0n);
  const volume = markets.reduce((total, market) => total + fixed(market.volume24hUsd), 0n);
  const vault = asRows<DbRow>(vaultResult)[0];
  const trade = asRows<DbRow>(tradeResult)[0];
  return {
    openInterestUsd: decimal(openInterest),
    volume24hUsd: decimal(volume),
    trades24h: numberValue(trade?.trades_24h),
    tvlUsd: String(vault?.total_assets ?? "0"),
    markets: markets.map((market) => ({
      symbol: market.symbol,
      price: market.price,
      dailyCarryPct: market.dailyCarryPct,
      regime: market.regime,
    })),
  };
}
