import { createRoute, OpenAPIHono } from "@hono/zod-openapi";
import type { ApiDependencies } from "../types";
import { statsResponseSchema } from "../schemas";
import { aggregateStats } from "../../db/queries/stats";

const route = createRoute({
  method: "get", path: "/v1/stats", tags: ["markets"],
  responses: { 200: { description: "Aggregate market and vault statistics", content: { "application/json": { schema: statsResponseSchema } } } },
});

export function registerStatsRoutes(app: OpenAPIHono, deps: ApiDependencies): void {
  app.openapi(route, async (context) => {
    context.header("Cache-Control", "public, max-age=5, stale-while-revalidate=30");
    const stats = await deps.cache.getOrLoad("stats:all", 3_000, () => aggregateStats(deps));
    return context.json(stats, 200);
  });
}
