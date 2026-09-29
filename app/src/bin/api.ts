import { Hono } from "hono";
import { createLogger, safeErrorSummary } from "../log";
import { loadConfig, safeConfigSummary } from "../config";
import { createRpcPool } from "../chain/rpc-pool";
import { createDbClient } from "../db/client";

const config = loadConfig();
const logger = createLogger(config.LOG_LEVEL, "api");
const { sql } = createDbClient(config);
// Health exposes this process's counters only. API handlers never construct a
// viem client and never issue chain RPC calls.
const rpcPool = createRpcPool(config);
const app = new Hono();

app.get("/v1/health", async (context) => {
  try {
    await sql`select 1`;
    const stats = rpcPool.stats();
    const rpcKeys = stats.endpoints.map((endpoint) => {
      const requestsToday = Object.values(endpoint.classes).reduce(
        (total, counters) => total + counters.requests,
        0,
      );
      const estimatedCuToday = Object.values(endpoint.classes).reduce(
        (total, counters) => total + counters.estimatedCu,
        0,
      );
      return {
        id: endpoint.id,
        requestsToday,
        estimatedCuToday,
        cooling: endpoint.cooling,
      };
    });

    return context.json({
      ok: true,
      db: { ok: true },
      lastIndexedBlock: null,
      headBlock: null,
      lagBlocks: null,
      keeper: {},
      rpc: { date: stats.date, keys: rpcKeys },
      warnings: ["Indexer and keeper health will appear when their workers are implemented."],
    });
  } catch (error) {
    logger.warn({ err: safeErrorSummary(error) }, "Health check could not reach the database");
    return context.json(
      { ok: false, db: { ok: false }, warnings: ["Database is unavailable."] },
      503,
    );
  }
});

const server = Bun.serve({
  hostname: "0.0.0.0",
  port: config.API_PORT,
  fetch: app.fetch,
});

logger.info(
  { config: safeConfigSummary(config), port: config.API_PORT },
  "API placeholder listening",
);

const shutdown = async () => {
  server.stop(true);
  await sql.end({ timeout: 5 });
  logger.info("API stopped");
};
process.once("SIGINT", () => void shutdown());
process.once("SIGTERM", () => void shutdown());
