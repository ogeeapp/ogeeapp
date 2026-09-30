import type { Logger } from "pino";
import type { ServiceClients } from "../chain/clients";
import type { Deployment } from "../chain/deployment";
import type { RuntimeConfig } from "../config";
import type { OgeeDbClient } from "../db/client";
import type { createTransactionQueue } from "./tx";

export interface IndexedMarket {
  symbol: string;
  token: string;
  stock: string;
  feed: string;
  config: Record<string, string | number>;
  state: {
    baseCarryWad: string;
    baseCarryUpdatedAt: string;
    lastAccrual: string;
    regime: number;
    lastUtilBps: number;
    buysPaused: boolean;
  };
}

export interface IndexerMetadata {
  globalConfig?: { globalBuysPaused: boolean; maxGlobalExposureBps: number };
  vaultConfig?: {
    cashBufferBps: number;
    hedgeRatioBps: number;
    rebalanceThresholdBps: number;
    maxHedgeSlippageBps: number;
    minHedgeTradeUsdg: string;
    maxTotalDeposits: string;
    publicDeposits: boolean;
    lockSeconds: number;
  };
  marketsById?: Record<string, IndexedMarket>;
  chainTimestamp?: string;
  chainTimeObservedAt?: string;
  lagBlocks?: number | string;
}

export interface KeeperContext {
  sql: OgeeDbClient["sql"];
  clients: ServiceClients;
  deployment: Deployment;
  config: RuntimeConfig;
  logger: Logger;
  tx: ReturnType<typeof createTransactionQueue>;
  metadata(): Promise<IndexerMetadata>;
  now(meta: IndexerMetadata): Date;
}

export async function readIndexerMetadata(sql: OgeeDbClient["sql"]): Promise<IndexerMetadata> {
  const rows = await sql<{ meta: IndexerMetadata }[]>`select meta from keeper_status where job = 'indexer'`;
  return rows[0]?.meta ?? {};
}

export function chainClock(config: RuntimeConfig, meta: IndexerMetadata): Date {
  if (config.NETWORK !== "fork") return new Date();
  const chain = Number(meta.chainTimestamp);
  const observed = Date.parse(meta.chainTimeObservedAt ?? "");
  if (!Number.isFinite(chain) || !Number.isFinite(observed)) {
    throw new Error("Waiting for indexer chain-time snapshot before running fork keeper jobs");
  }
  return new Date(chain * 1000 + Math.max(0, Date.now() - observed));
}

export async function saveJobMeta(context: KeeperContext, job: string, meta: Record<string, unknown>): Promise<void> {
  await context.sql`insert into keeper_status (job, meta) values (${job}, ${JSON.stringify(meta)}::jsonb)
    on conflict (job) do update set meta = keeper_status.meta || excluded.meta`;
}
