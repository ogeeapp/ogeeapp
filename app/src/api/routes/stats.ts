import { createRoute, OpenAPIHono } from "@hono/zod-openapi";
import type { ApiDependencies } from "../types";
import { historyRangeQuery, statsHistoryResponseSchema, statsResponseSchema } from "../schemas";
import { aggregateStats } from "../../db/queries/stats";
import { protocolHistory } from "../../db/queries/analytics";

const route = createRoute({
  method: "get", path: "/v1/stats", tags: ["markets"],
  responses: { 200: { description: "Aggregate market and vault statistics", content: { "application/json": { schema: statsResponseSchema } } } },
});

const historyRoute = createRoute({
  method: "get", path: "/v1/stats/history", tags: ["markets"], request: { query: historyRangeQuery },
  responses: { 200: { description: "Daily protocol history", content: { "application/json": { schema: statsHistoryResponseSchema } } } },
});

export function registerStatsRoutes(app: OpenAPIHono, deps: ApiDependencies): void {
  app.openapi(route, async (context) => {
    context.header("Cache-Control", "public, max-age=5, stale-while-revalidate=30");
    const stats = await deps.cache.getOrLoad("stats:all", 3_000, () => aggregateStats(deps));
    return context.json(stats, 200);
  });

  app.openapi(historyRoute, async (context) => {
    context.header("Cache-Control", "public, max-age=30, stale-while-revalidate=120");
    const { range } = context.req.valid("query");
    return context.json(await deps.cache.getOrLoad(`stats:history:${range}`, 60_000, () => protocolHistory(deps, range)), 200);
  });
}
