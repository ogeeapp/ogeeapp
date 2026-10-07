import { z } from "@hono/zod-openapi";
import { isAddress } from "viem";

const decimal = z.string().regex(/^-?\d+(?:\.\d+)?$/);
const isoDateTime = z.string().datetime({ offset: true });
const percent = z.number().finite();

export const errorResponseSchema = z.object({ error: z.string(), message: z.string() });

export const healthResponseSchema = z.object({
  ok: z.boolean(),
  db: z.object({ ok: z.boolean() }),
  lastIndexedBlock: z.number().int().nonnegative().nullable(),
  headBlock: z.number().int().nonnegative().nullable(),
  lagBlocks: z.number().int().nonnegative().nullable(),
  keeper: z.record(z.string(), z.object({
    status: z.enum(["ok", "error", "pending"]), lastOk: isoDateTime.nullable(), lastRun: isoDateTime.nullable(),
  })),
  rpc: z.object({ date: z.string().nullable(), keys: z.array(z.object({
    id: z.string(), requestsToday: z.number().int().nonnegative(), estimatedCuToday: z.number().int().nonnegative(), cooling: z.boolean(),
  })) }),
  warnings: z.array(z.string()),
});

export const configResponseSchema = z.object({
  chainId: z.number().int(),
  network: z.enum(["mainnet", "fork"]),
  forkProof: z.object({ blockNumber: z.number().int().nonnegative(), blockHash: z.string() }).optional(),
  rpcUrl: z.string().url(),
  explorerUrl: z.string().url(),
  contracts: z.object({ engine: z.string(), vault: z.string(), lens: z.string(), usdg: z.string(), marketHours: z.string() }),
  markets: z.array(z.object({ id: z.number().int(), symbol: z.string(), token: z.string(), stock: z.string(), decimals: z.literal(18) })),
  usdgDecimals: z.literal(6),
  crabDecimals: z.literal(12),
  features: z.object({ publicDeposits: z.boolean(), shorts: z.boolean(), limitOrders: z.boolean(), ratio: z.boolean() }),
});

export const sparklineSchema = z.array(z.object({ t: z.number().int(), p: decimal }));

export const marketSchema = z.object({
  id: z.number().int(), symbol: z.string(), token: z.string(), regime: z.enum(["open", "off_hours", "paused"]),
  meta: z.object({ name: z.string(), category: z.string(), color: z.string().regex(/^#[0-9a-fA-F]{6}$/) }).optional(),
  session: z.object({ open: z.boolean(), opensAt: isoDateTime.nullable(), closesAt: isoDateTime.nullable() }),
  buysPaused: z.boolean(), spot: decimal, index: decimal, price: decimal, bid: decimal, ask: decimal,
  dailyCarryPct: percent, change24hPct: percent, volume24hUsd: decimal, openInterestUsd: decimal,
  capacityUsd: decimal, utilizationPct: percent, oracleUpdatedAt: isoDateTime.nullable(), asOf: isoDateTime.nullable(),
  sparkline: sparklineSchema,
  corpAction: z.object({ kind: z.string(), effectiveAt: isoDateTime.nullable(), status: z.string() }).optional(),
  quoteParams: z.object({ feeBps: z.number().int(), spreadBps: z.number().int(), bandBps: z.number().int(), impactBps: z.number().int(),
    maxTradeUsd: decimal, minTradeUsd: decimal, capacityUsd: decimal, globalCapacityUsd: decimal }),
});

export const marketListResponseSchema = z.array(marketSchema);
export const marketDetailResponseSchema = marketSchema.extend({
  config: z.record(z.string(), z.unknown()),
  stats: z.object({ trades24h: z.number().int().nonnegative(), holders: z.number().int().nonnegative() }),
});

export const candleSchema = z.array(z.object({ t: z.number().int(), o: decimal, h: decimal, l: decimal, c: decimal }));
export const carrySchema = z.array(z.object({ t: z.number().int(), dailyCarryPct: percent, regime: z.enum(["open", "off_hours", "paused"]) }));

export const tradeListSchema = z.array(z.object({
  txHash: z.string(), side: z.enum(["buy", "sell"]), account: z.string(), recipient: z.string(),
  usdg: decimal, fee: decimal, tokens: decimal, price: decimal, ts: isoDateTime,
}));
export const regimeListSchema = z.array(z.object({
  txHash: z.string(), from: z.enum(["open", "off_hours", "paused"]), to: z.enum(["open", "off_hours", "paused"]), ts: isoDateTime,
}));

export const portfolioResponseSchema = z.object({
  positions: z.array(z.object({ symbol: z.string(), balance: decimal, price: decimal, value: decimal, avgCost: decimal,
    costBasis: decimal, unrealizedPnl: decimal, realizedPnl: decimal })),
  crab: z.object({ shares: decimal, value: decimal, costBasis: decimal, change: decimal, changePct: percent.nullable(),
    historyComplete: z.boolean(), unlockTime: isoDateTime.nullable(), isDepositor: z.boolean() }),
  totals: z.object({ powerValue: decimal, unrealizedPnl: decimal, realizedPnl: decimal }),
  /** False when the cost-basis ledger was capped to the newest entries. */
  historyComplete: z.boolean(),
});

export const activityResponseSchema = z.object({
  items: z.array(z.object({ id: z.string(), kind: z.enum(["buy", "sell", "deposit", "withdraw", "transfer_in", "transfer_out"]),
    symbol: z.string(), usdg: decimal.nullable(), tokens: decimal.nullable(), price: decimal.nullable(), ts: isoDateTime, txHash: z.string() })),
  nextCursor: z.string().nullable(),
});

export const vaultResponseSchema = z.object({
  nav: decimal, navPerShare: decimal, totalSupply: decimal, usdg: decimal, totalLiability: decimal,
  utilizationPct: percent, maxGlobalExposurePct: percent, publicDeposits: z.boolean(),
  markets: z.array(z.object({ symbol: z.string(), liability: decimal, hedgeUnits: decimal, hedgeTarget: decimal, hedgeValue: decimal, deltaPct: percent })),
  change7dPct: percent, change30dPct: percent.nullable(), changeSinceInceptionPct: percent.nullable(),
  carryEarned30d: decimal.optional(), depositCapRemaining: decimal,
});
export const vaultHistorySchema = z.array(z.object({ t: z.number().int(), navPerShare: decimal, nav: decimal }));
export const corpActionsSchema = z.array(z.object({ id: z.string(), symbol: z.string(), kind: z.string(), status: z.string(),
  processDate: z.string().nullable(), effectiveAt: isoDateTime.nullable(), oldMultiplier: decimal.nullable(), newMultiplier: decimal.nullable(),
  verifiedContinuity: z.boolean().nullable(), details: z.record(z.string(), z.unknown()) }));
export const statsResponseSchema = z.object({ openInterestUsd: decimal, volume24hUsd: decimal, trades24h: z.number().int().nonnegative(), tvlUsd: decimal,
  fees24hUsd: decimal, uniqueTraders24h: z.number().int().nonnegative(), volumeAllTimeUsd: decimal,
  tradesAllTime: z.number().int().nonnegative(), tradersAllTime: z.number().int().nonnegative(),
  markets: z.array(z.object({ symbol: z.string(), price: decimal, dailyCarryPct: percent, regime: z.enum(["open", "off_hours", "paused"]) })) });

const count = z.number().int().nonnegative();
export const historyRangeQuery = z.object({ range: z.enum(["7D", "30D", "90D", "ALL"]).default("30D") });
export const statsHistoryResponseSchema = z.object({
  range: z.enum(["7D", "30D", "90D", "ALL"]), from: isoDateTime, to: isoDateTime,
  summary: z.object({ volumeUsd: decimal, buyVolumeUsd: decimal, sellVolumeUsd: decimal, feesUsd: decimal, trades: count, uniqueTraders: count }),
  points: z.array(z.object({ t: z.number().int(), volumeUsd: decimal, buyVolumeUsd: decimal, sellVolumeUsd: decimal, feesUsd: decimal,
    trades: count, uniqueTraders: count, tvlUsd: decimal.nullable() })),
  markets: z.array(z.object({ symbol: z.string(), volumeUsd: decimal, trades: count, sharePct: percent })),
});

const boardRange = z.enum(["7D", "30D", "ALL"]);
const boardSort = z.enum(["volume", "trades"]);
export const leaderboardQuery = z.object({
  range: boardRange.default("7D"),
  sort: boardSort.default("volume"),
  limit: z.coerce.number().int().min(1).max(100).default(50),
});
const leaderboardRowSchema = z.object({ rank: z.number().int().positive(), address: z.string(), volumeUsd: decimal,
  trades: count, markets: count, topMarket: z.string().nullable(), lastTradeAt: isoDateTime });
export const leaderboardResponseSchema = z.object({ range: boardRange, sort: boardSort,
  totalTraders: count, rows: z.array(leaderboardRowSchema), generatedAt: isoDateTime });

export const symbolParams = z.object({ symbol: z.string().min(1).max(16).transform((value) => value.toUpperCase()) });
export const addressParams = z.object({ address: z.string().refine((value) => isAddress(value, { strict: false }), "Invalid EVM address").transform((value) => value.toLowerCase()) });
export const rangeQuery = z.object({ range: z.enum(["1H", "4H", "1D", "1W", "1M", "ALL"]).default("1D"), series: z.enum(["price", "index"]).default("price") });
export const carryRangeQuery = z.object({ range: z.enum(["1W", "1M", "ALL"]).default("1W") });
export const limitQuery = z.object({ limit: z.coerce.number().int().min(1).max(200).default(50) });
export const activityQuery = z.object({ type: z.enum(["all", "trades", "vault"]).default("all"), cursor: z.string().max(512).optional(), limit: z.coerce.number().int().min(1).max(100).default(50) });
export const corpActionsQuery = z.object({ symbol: z.string().min(1).max(16).transform((value) => value.toUpperCase()).optional() });
