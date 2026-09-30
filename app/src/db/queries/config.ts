import type { ApiDependencies } from "../../api/types";
import { asRows, numberValue } from "../../api/types";

export async function runtimeConfigResponse(deps: ApiDependencies) {
  const rows = asRows<Record<string, unknown>>(await deps.sql`
    select id, symbol, token, stock from markets order by id
  `);
  const marketRows = rows.length > 0
    ? rows
    : deps.deployment.markets.map((market) => ({
      id: market.id,
      symbol: market.symbol,
      token: market.token,
      stock: market.stock,
    }));

  return {
    chainId: deps.config.CHAIN_ID,
    network: deps.config.NETWORK,
    ...(deps.config.NETWORK === "fork" && deps.deployment.forkProof
      ? { forkProof: deps.deployment.forkProof }
      : {}),
    rpcUrl: deps.config.PUBLIC_RPC_URL,
    explorerUrl: "https://robinhoodchain.blockscout.com",
    contracts: {
      engine: deps.deployment.contracts.engine,
      vault: deps.deployment.contracts.vault,
      lens: deps.deployment.contracts.lens,
      usdg: deps.deployment.contracts.usdg,
      marketHours: deps.deployment.contracts.marketHours,
    },
    markets: marketRows.map((market) => ({
      id: numberValue(market.id),
      symbol: String(market.symbol),
      token: String(market.token).toLowerCase(),
      stock: String(market.stock).toLowerCase(),
      decimals: 18 as const,
    })),
    usdgDecimals: 6 as const,
    crabDecimals: 12 as const,
    features: { publicDeposits: false, shorts: false, limitOrders: false, ratio: false },
  };
}
