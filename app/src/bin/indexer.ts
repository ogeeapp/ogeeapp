import { createClients } from "../chain/clients";
import { loadConfig, safeConfigSummary } from "../config";
import { createLogger } from "../log";

const config = loadConfig();
const logger = createLogger(config.LOG_LEVEL, "indexer");
const clients = createClients(config);

logger.info(
  {
    config: safeConfigSummary(config),
    rpcEndpoints: clients.pool.stats().endpoints.map(({ id, kind }) => ({ id, kind })),
  },
  "Indexer placeholder started; chain ingestion is implemented in C08",
);

await new Promise<void>((resolve) => {
  process.once("SIGINT", resolve);
  process.once("SIGTERM", resolve);
});
logger.info("Indexer stopped");
