import { createRoute, OpenAPIHono } from "@hono/zod-openapi";
import { z } from "@hono/zod-openapi";
import type { ApiDependencies } from "../types";
import {
  candleSchema, carrySchema, errorResponseSchema, limitQuery, marketDetailResponseSchema,
  marketHoldersResponseSchema, marketListResponseSchema, regimeListSchema, rangeQuery, symbolParams, tradeListSchema,
} from "../schemas";
import { marketCandles, marketCarry, getMarketDetail, listMarkets, marketRegimes, marketTrades } from "../../db/queries/markets";
import { marketHolders } from "../../db/queries/holders";
import { dateValue, textValue } from "../types";

const cacheHeader = "public, max-age=5, stale-while-revalidate=30";

const listRoute = createRoute({
  method: "get", path: "/v1/markets", tags: ["markets"],
  responses: { 200: { description: "Current market quotes and capacity", content: { "application/json": { schema: marketListResponseSchema } } } },
});
const detailRoute = createRoute({
  method: "get", path: "/v1/markets/{symbol}", tags: ["markets"], request: { params: symbolParams },
  responses: {
    200: { description: "Market quote and configuration", content: { "application/json": { schema: marketDetailResponseSchema } } },
    404: { description: "Unknown market symbol", content: { "application/json": { schema: errorResponseSchema } } },
  },
});
const candlesRoute = createRoute({
  method: "get", path: "/v1/markets/{symbol}/candles", tags: ["markets"], request: { params: symbolParams, query: rangeQuery },
  responses: {
    200: { description: "OHLC candles", content: { "application/json": { schema: candleSchema } } },
    404: { description: "Unknown market symbol", content: { "application/json": { schema: errorResponseSchema } } },
  },
});
const carryRoute = createRoute({
  method: "get", path: "/v1/markets/{symbol}/carry", tags: ["markets"],
  request: { params: symbolParams, query: z.object({ range: z.enum(["1W", "1M", "ALL"]).default("1W") }) },
  responses: {
    200: { description: "Hourly carry and regime", content: { "application/json": { schema: carrySchema } } },
    404: { description: "Unknown market symbol", content: { "application/json": { schema: errorResponseSchema } } },
  },
});
const tradesRoute = createRoute({
  method: "get", path: "/v1/markets/{symbol}/trades", tags: ["markets"], request: { params: symbolParams, query: limitQuery },
  responses: {
    200: { description: "Recent market trades", content: { "application/json": { schema: tradeListSchema } } },
    404: { description: "Unknown market symbol", content: { "application/json": { schema: errorResponseSchema } } },
  },
});
const regimesRoute = createRoute({
  method: "get", path: "/v1/markets/{symbol}/regimes", tags: ["markets"], request: { params: symbolParams, query: limitQuery },
  responses: {
    200: { description: "Recent market regime changes", content: { "application/json": { schema: regimeListSchema } } },
    404: { description: "Unknown market symbol", content: { "application/json": { schema: errorResponseSchema } } },
  },
});
const holdersRoute = createRoute({
  method: "get", path: "/v1/markets/{symbol}/holders", tags: ["markets"], request: { params: symbolParams },
  responses: {
    200: { description: "Holder count, concentration and distribution", content: { "application/json": { schema: marketHoldersResponseSchema } } },
    404: { description: "Unknown market symbol", content: { "application/json": { schema: errorResponseSchema } } },
  },
});

function publicResponse(context: { header: (name: string, value: string) => void }): void {
  context.header("Cache-Control", cacheHeader);
}

export function registerMarketRoutes(app: OpenAPIHono, deps: ApiDependencies): void {
  app.openapi(listRoute, async (context) => {
    publicResponse(context);
    const markets = await deps.cache.getOrLoad("markets:list", 3_000, () => listMarkets(deps));
    return context.json(markets.map(({ config: _config, stats: _stats, ...market }) => market), 200);
  });

  app.openapi(detailRoute, async (context) => {
    publicResponse(context);
    const { symbol } = context.req.valid("param");
    const market = await deps.cache.getOrLoad(`markets:detail:${symbol}`, 3_000, () => getMarketDetail(deps, symbol));
    if (!market) return context.json({ error: "NOT_FOUND", message: `Unknown market symbol: ${symbol}` }, 404);
    return context.json(market, 200);
  });

  app.openapi(candlesRoute, async (context) => {
    publicResponse(context);
    const { symbol } = context.req.valid("param");
    const { range, series } = context.req.valid("query");
    const candles = await deps.cache.getOrLoad(`markets:candles:${symbol}:${range}:${series}`, 10_000,
      () => marketCandles(deps, symbol, range, series));
    if (!candles) return context.json({ error: "NOT_FOUND", message: `Unknown market symbol: ${symbol}` }, 404);
    return context.json(candles, 200);
  });

  app.openapi(carryRoute, async (context) => {
    publicResponse(context);
    const { symbol } = context.req.valid("param");
    const { range } = context.req.valid("query");
    const points = await deps.cache.getOrLoad(`markets:carry:${symbol}:${range}`, 10_000, () => marketCarry(deps, symbol, range));
    if (!points) return context.json({ error: "NOT_FOUND", message: `Unknown market symbol: ${symbol}` }, 404);
    return context.json(points, 200);
  });

  app.openapi(tradesRoute, async (context) => {
    publicResponse(context);
    const { symbol } = context.req.valid("param");
    const { limit } = context.req.valid("query");
    const trades = await deps.cache.getOrLoad(`markets:trades:${symbol}:${limit}`, 3_000, () => marketTrades(deps, symbol, limit));
    if (!trades) return context.json({ error: "NOT_FOUND", message: `Unknown market symbol: ${symbol}` }, 404);
    return context.json(trades.map((row) => ({
      txHash: textValue(row.tx_hash),
      side: (textValue(row.side).toLowerCase() === "sell" ? "sell" : "buy") as "buy" | "sell",
      account: textValue(row.account),
      recipient: textValue(row.recipient),
      usdg: textValue(row.usdg),
      fee: textValue(row.fee),
      tokens: textValue(row.tokens),
      price: textValue(row.price),
      ts: dateValue(row.ts)?.toISOString() ?? "1970-01-01T00:00:00.000Z",
    })), 200);
  });

  app.openapi(regimesRoute, async (context) => {
    publicResponse(context);
    const { symbol } = context.req.valid("param");
    const { limit } = context.req.valid("query");
    const regimes = await deps.cache.getOrLoad(`markets:regimes:${symbol}:${limit}`, 3_000, () => marketRegimes(deps, symbol, limit));
    if (!regimes) return context.json({ error: "NOT_FOUND", message: `Unknown market symbol: ${symbol}` }, 404);
    const label = (value: unknown): "open" | "off_hours" | "paused" => {
      const parsed = Number(value);
      return parsed === 2 ? "paused" : parsed === 1 ? "off_hours" : "open";
    };
    return context.json(regimes.map((row) => ({
      txHash: textValue(row.tx_hash),
      from: label(row.from_regime),
      to: label(row.to_regime),
      ts: dateValue(row.ts)?.toISOString() ?? "1970-01-01T00:00:00.000Z",
    })), 200);
  });

  app.openapi(holdersRoute, async (context) => {
    context.header("Cache-Control", "public, max-age=30, stale-while-revalidate=120");
    const { symbol } = context.req.valid("param");
    const holders = await deps.cache.getOrLoad(`markets:holders:${symbol}`, 60_000, () => marketHolders(deps, symbol));
    if (!holders) return context.json({ error: "NOT_FOUND", message: `Unknown market symbol: ${symbol}` }, 404);
    return context.json(holders, 200);
  });
}
