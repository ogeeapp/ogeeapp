import { createClients } from "../chain/clients";
import { loadConfig, safeConfigSummary } from "../config";
import { createLogger } from "../log";

const config = loadConfig();
const logger = createLogger(config.LOG_LEVEL, "keeper");
const clients = createClients(config);

logger.info(
  {
    config: safeConfigSummary(config),
    walletEnabled: Boolean(clients.walletClient),
    rpcEndpoints: clients.pool.stats().endpoints.map(({ id, kind }) => ({ id, kind })),
  },
  "Keeper placeholder started; transaction jobs are implemented in C10",
);

const keepAlive = setInterval(() => {}, 60_000);
await new Promise<void>((resolve) => {
  process.once("SIGINT", resolve);
  process.once("SIGTERM", resolve);
});
clearInterval(keepAlive);
logger.info("Keeper stopped");
