import { OpenAPIHono } from "@hono/zod-openapi";
import { cors } from "hono/cors";
import type { ApiDependencies } from "./types";
import { openApiDocument } from "./openapi";
import { registerConfigRoutes } from "./routes/config";
import { registerHealthRoutes } from "./routes/health";
import { registerMarketRoutes } from "./routes/markets";
import { safeErrorSummary } from "../log";

export function createApiApp(deps: ApiDependencies) {
  const allowedOrigins = new Set(deps.config.CORS_ORIGINS);
  const app = new OpenAPIHono({
    defaultHook: (result, context) => {
      if (!result.success) {
        return context.json({ error: "BAD_REQUEST", message: "Invalid request parameters." }, 400);
      }
    },
  });

  app.use("*", cors({
    origin: (origin) => origin && allowedOrigins.has(origin) ? origin : "",
    allowMethods: ["GET", "OPTIONS"],
    allowHeaders: ["Content-Type", "Authorization"],
    exposeHeaders: ["Cache-Control"],
    maxAge: 600,
    credentials: false,
  }));
  app.use("*", async (context, next) => {
    const startedAt = Date.now();
    await next();
    deps.logger.info({
      method: context.req.method,
      path: context.req.path,
      status: context.res.status,
      durationMs: Date.now() - startedAt,
    }, "API request");
  });

  registerHealthRoutes(app, deps);
  registerConfigRoutes(app, deps);
  registerMarketRoutes(app, deps);

  app.get("/v1/openapi.json", (context) => {
    try {
      return context.json(app.getOpenAPI31Document(openApiDocument));
    } catch (error) {
      deps.logger.error({ err: safeErrorSummary(error) }, "OpenAPI document generation failed");
      return context.json({ error: "INTERNAL_ERROR", message: "OpenAPI document unavailable." }, 500);
    }
  });
  app.notFound((context) => context.json({ error: "NOT_FOUND", message: "Route not found." }, 404));
  app.onError((error, context) => {
    const record = error && typeof error === "object" ? error as { status?: unknown; apiError?: unknown } : undefined;
    const status = typeof record?.status === "number" && record.status >= 400 && record.status < 600 ? record.status : 500;
    const message = status < 500 ? error.message : "Internal server error.";
    deps.logger.error({ err: safeErrorSummary(error), status }, "API request failed");
    return context.json({
      error: typeof record?.apiError === "string" ? record.apiError : status === 500 ? "INTERNAL_ERROR" : "BAD_REQUEST",
      message,
    }, status as 400 | 404 | 422 | 500);
  });
  return app;
}
