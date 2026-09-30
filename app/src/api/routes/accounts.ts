import { createRoute, OpenAPIHono } from "@hono/zod-openapi";
import type { ApiDependencies } from "../types";
import { activityQuery, activityResponseSchema, addressParams, portfolioResponseSchema } from "../schemas";
import { accountActivity, accountPortfolio } from "../../db/queries/accounts";

const portfolioRoute = createRoute({
  method: "get", path: "/v1/accounts/{address}/portfolio", tags: ["accounts"], request: { params: addressParams },
  responses: { 200: { description: "Wallet positions, cost basis, and Crab holdings", content: { "application/json": { schema: portfolioResponseSchema } } } },
});
const activityRoute = createRoute({
  method: "get", path: "/v1/accounts/{address}/activity", tags: ["accounts"], request: { params: addressParams, query: activityQuery },
  responses: { 200: { description: "Cursor-paginated wallet activity", content: { "application/json": { schema: activityResponseSchema } } } },
});

export function registerAccountRoutes(app: OpenAPIHono, deps: ApiDependencies): void {
  app.openapi(portfolioRoute, async (context) => {
    context.header("Cache-Control", "private, max-age=5");
    const { address } = context.req.valid("param");
    return context.json(await accountPortfolio(deps, address), 200);
  });
  app.openapi(activityRoute, async (context) => {
    context.header("Cache-Control", "private, max-age=5");
    const { address } = context.req.valid("param");
    const { type, cursor, limit } = context.req.valid("query");
    return context.json(await accountActivity(deps, address, type, cursor, limit), 200);
  });
}
