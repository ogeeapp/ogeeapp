import postgres from "postgres";
import { drizzle } from "drizzle-orm/postgres-js";
import type { RuntimeConfig } from "../config";
import * as schema from "./schema";

export function createDbClient(config: RuntimeConfig) {
  const sql = postgres(config.DATABASE_URL, {
    max: 10,
    idle_timeout: 20,
    connect_timeout: 10,
    transform: { undefined: null },
  });
  const db = drizzle(sql, { schema });
  return { db, sql };
}

export type OgeeDbClient = ReturnType<typeof createDbClient>;
