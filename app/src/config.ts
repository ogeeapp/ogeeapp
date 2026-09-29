import { z } from "zod";

const routeSchema = z
  .string()
  .default("public,alchemy")
  .transform((value) => value.split(",").map((item) => item.trim().toLowerCase()))
  .pipe(z.array(z.enum(["public", "alchemy"])).min(1));

const envSchema = z.object({
  NODE_ENV: z.enum(["development", "production", "test"]).default("development"),
  NETWORK: z.enum(["mainnet", "fork"]).default("fork"),
  CHAIN_ID: z.coerce.number().int().positive().default(4663),
  DATABASE_URL: z.string().url(),
  POSTGRES_PASSWORD: z.string().min(1),
  ALCHEMY_API_KEYS: z.string().default(""),
  ALCHEMY_URL_TEMPLATE: z
    .string()
    .default("https://robinhood-mainnet.g.alchemy.com/v2/{key}"),
  PUBLIC_RPC_URL: z.string().url().default("https://rpc.mainnet.chain.robinhood.com"),
  RPC_URL_OVERRIDE: z.string().default(""),
  RPC_ROUTE_LOGS: routeSchema,
  RPC_ROUTE_STATE: routeSchema,
  RPC_ROUTE_TX: z
    .string()
    .default("alchemy,public")
    .transform((value) => value.split(",").map((item) => item.trim().toLowerCase()))
    .pipe(z.array(z.enum(["public", "alchemy"])).min(1)),
  INDEXER_POLL_ACTIVE_MS: z.coerce.number().int().positive().default(5000),
  INDEXER_POLL_BASE_MS: z.coerce.number().int().positive().default(15000),
  INDEXER_POLL_IDLE_MS: z.coerce.number().int().positive().default(60000),
  DEPLOYMENT_FILE: z.string().min(1).default("/app/deployments/fork.json"),
  KEEPER_PRIVATE_KEY: z
    .string()
    .regex(/^0x[0-9a-fA-F]{64}$/)
    .optional()
    .or(z.literal("")),
  KEEPER_ENABLED_JOBS: z.string().default("sessions,accrue,hedge,carry,risk,corp-actions"),
  API_PORT: z.coerce.number().int().min(1).max(65535).default(3101),
  CORS_ORIGINS: z.string().default(""),
  LOG_LEVEL: z.enum(["fatal", "error", "warn", "info", "debug", "trace", "silent"]).default("info"),
});

type ParsedConfig = z.infer<typeof envSchema>;

export type RuntimeConfig = Omit<ParsedConfig, "ALCHEMY_API_KEYS" | "CORS_ORIGINS"> & {
  readonly ALCHEMY_API_KEYS: readonly string[];
  readonly CORS_ORIGINS: readonly string[];
};

export class ConfigurationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ConfigurationError";
  }
}

export function loadConfig(source: Record<string, string | undefined> = process.env): RuntimeConfig {
  const result = envSchema.safeParse(source);
  if (!result.success) {
    const details = result.error.issues
      .map((issue) => `${issue.path.join(".") || "environment"}: ${issue.message}`)
      .join("; ");
    throw new ConfigurationError(`Invalid service configuration: ${details}`);
  }

  if (!result.data.ALCHEMY_URL_TEMPLATE.includes("{key}")) {
    throw new ConfigurationError("ALCHEMY_URL_TEMPLATE must include the {key} placeholder");
  }

  return Object.freeze({
    ...result.data,
    ALCHEMY_API_KEYS: Object.freeze(
      result.data.ALCHEMY_API_KEYS.split(",").map((key) => key.trim()).filter(Boolean),
    ),
    CORS_ORIGINS: Object.freeze(
      result.data.CORS_ORIGINS.split(",").map((origin) => origin.trim()).filter(Boolean),
    ),
  });
}

export function safeConfigSummary(config: RuntimeConfig): Record<string, string | number | boolean> {
  return {
    network: config.NETWORK,
    chainId: config.CHAIN_ID,
    databaseConfigured: Boolean(config.DATABASE_URL),
    publicRpcHost: new URL(config.PUBLIC_RPC_URL).host,
    rpcOverrideEnabled: Boolean(config.RPC_URL_OVERRIDE.trim()),
    alchemyKeyCount: config.ALCHEMY_API_KEYS.length,
    apiPort: config.API_PORT,
    logLevel: config.LOG_LEVEL,
  };
}
