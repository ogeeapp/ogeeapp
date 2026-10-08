import { expect, test } from "bun:test";
import type { KeeperContext } from "../context";
import { fetchJsonWithTimeout } from "../http";
import { normalizeQuotes, updateReferencePrices } from "./reference";

const fixture = {
  quotes: [
    {
      tokenSymbol: "CRM",
      deployments: [{ contractAddress: "0xd95B44124e475743a7589e68F3D74008A5536D44", chainId: 4663 }],
      bid: "224.78", ask: "226", tokenBid: "225.038119999144558781", tokenAsk: "226.259520952961430218",
      dailyHigh: "225.1539", dailyLow: "223.01", dailyTradingVolume: "15865", mintBurnUsdVolume: "50.6545813488",
      isTradingHalt: false, generatedAt: "2026-10-08T10:50:42.185010883Z",
    },
    {
      tokenSymbol: "P",
      deployments: [{ contractAddress: "0x1Cdad396DB64BDa184d5182A97Dd9B3C62100b7D", chainId: 4663 }],
      bid: "150.38", ask: "150.99", tokenBid: "150.380000000000000000", tokenAsk: "150.990000000000000000",
      dailyHigh: "155.53", dailyLow: "150.5", dailyTradingVolume: "7265", mintBurnUsdVolume: "5976.46847",
      isTradingHalt: true, generatedAt: "2026-10-08T10:50:42.185010883Z",
    },
    {
      tokenSymbol: "CIEN",
      deployments: [{ contractAddress: "0x44f6D488021f8233B9416294d1FE9b1fEe28382d", chainId: 4663 }],
      bid: "433", ask: "435", tokenBid: "433.000000000000000000", tokenAsk: "435.000000000000000000",
      dailyHigh: "450.06", dailyLow: "431.0754", dailyTradingVolume: "19131", mintBurnUsdVolume: "0",
      isTradingHalt: false, generatedAt: "2026-10-08T10:50:42.185010883Z",
    },
    { tokenSymbol: "MISS", deployments: [], generatedAt: "2026-10-08T10:00:00Z" },
    { tokenSymbol: "CHAIN", deployments: [{ contractAddress: `0x${"1".repeat(40)}`, chainId: 1 }], generatedAt: "2026-10-08T10:00:00Z" },
    { tokenSymbol: "ADDRESS", deployments: [{ contractAddress: "0x1234", chainId: 4663 }], generatedAt: "2026-10-08T10:00:00Z" },
    { tokenSymbol: "NUMBER", deployments: [{ contractAddress: `0x${"2".repeat(40)}`, chainId: 4663 }], bid: 223, generatedAt: "2026-10-08T10:00:00Z" },
    { tokenSymbol: "DATE", deployments: [{ contractAddress: `0x${"3".repeat(40)}`, chainId: 4663 }], generatedAt: "not-a-date" },
    {
      tokenSymbol: "P",
      deployments: [{ contractAddress: "0x1cdad396db64bda184d5182a97dd9b3c62100b7d", chainId: 4663 }],
      bid: "151.1", ask: "151.7", tokenBid: "151.1", tokenAsk: "151.7", dailyHigh: "152", dailyLow: "149",
      dailyTradingVolume: "7266", mintBurnUsdVolume: "5977", isTradingHalt: false,
      generatedAt: "2026-10-08T10:51:42Z",
    },
  ],
};

test("normalizeQuotes keeps valid Robinhood quotes, exact strings, and the newest duplicate", () => {
  expect(normalizeQuotes({ quotes: fixture.quotes.slice(0, 3) }).find((quote) => quote.symbol === "P")?.halt).toBe(true);
  const quotes = normalizeQuotes(fixture);
  expect(quotes).toHaveLength(4);
  const p = quotes.find((quote) => quote.symbol === "P")!;
  expect(p).toMatchObject({
    stock: "0x1cdad396db64bda184d5182a97dd9b3c62100b7d",
    bid: "151.1", ask: "151.7", tokenBid: "151.1", tokenAsk: "151.7",
    dailyHigh: "152", dailyLow: "149", dailyVolume: "7266", mintBurnUsd: "5977", halt: false,
  });
  expect(p.generatedAt.toISOString()).toBe("2026-10-08T10:51:42.000Z");
  expect(quotes.find((quote) => quote.symbol === "CRM")).toMatchObject({
    stock: "0xd95b44124e475743a7589e68f3d74008a5536d44",
    bid: "224.78", tokenBid: "225.038119999144558781", tokenAsk: "226.259520952961430218",
  });
  expect(quotes.find((quote) => quote.symbol === "NUMBER")?.bid).toBeNull();
  expect(quotes.find((quote) => quote.symbol === "CIEN")?.tokenAsk).toBe("435.000000000000000000");
});

function fakeContext() {
  const statements: { query: string; values: unknown[] }[] = [];
  const inserts: { rows: Record<string, unknown>[]; columns: string[] }[] = [];
  const sql = (...args: unknown[]) => {
    const first = args[0];
    if (Array.isArray(first) && "raw" in first) {
      statements.push({ query: (first as TemplateStringsArray).join("?"), values: args.slice(1) });
      return Promise.resolve([]);
    }
    inserts.push({ rows: first as Record<string, unknown>[], columns: args.slice(1) as string[] });
    return "<quote-rows>";
  };
  return {
    context: { sql, logger: { warn() {} } } as unknown as KeeperContext,
    statements,
    inserts,
  };
}

type FetchImplementation = (input: RequestInfo | URL, init?: RequestInit) => Promise<Response>;

async function withFetch<T>(fetcher: FetchImplementation, run: () => Promise<T>): Promise<T> {
  const previous = globalThis.fetch;
  globalThis.fetch = fetcher as typeof fetch;
  try {
    return await run();
  } finally {
    globalThis.fetch = previous;
  }
}

test("updateReferencePrices performs one bulk upsert and records the newest quote time", async () => {
  const calls: { url: string; init: RequestInit | undefined }[] = [];
  const { context, statements, inserts } = fakeContext();
  const result = await withFetch(async (input: RequestInfo | URL, init?: RequestInit) => {
    calls.push({ url: String(input), init });
    return Response.json(fixture);
  }, () => updateReferencePrices(context));

  expect(calls).toHaveLength(1);
  expect(calls[0]?.url).toBe("https://api.robinhood.com/rhj/prices/");
  expect((calls[0]?.init?.headers as Record<string, string>)?.["User-Agent"]).toBe("ogee-keeper/1.0 (+https://ogeeapp.xyz)");
  expect((calls[0]?.init?.headers as Record<string, string>)?.Accept).toBe("application/json");
  expect(statements).toHaveLength(1);
  expect(statements[0]?.query).toContain("insert into ref_prices");
  expect(statements[0]?.query).toContain("on conflict (stock) do update set");
  expect(statements[0]?.query).toContain("fetched_at=now()");
  expect(inserts).toHaveLength(1);
  expect(inserts[0]?.rows).toHaveLength(4);
  expect(inserts[0]?.rows[0]).toHaveProperty("token_bid");
  expect(result).toEqual({ stored: 4, newestQuoteAt: "2026-10-08T10:51:42.000Z" });
});

test("updateReferencePrices rejects empty data and hides URL queries on HTTP errors", async () => {
  const { context } = fakeContext();
  await withFetch(async () => Response.json({ quotes: [] }), async () => {
    await expect(updateReferencePrices(context)).rejects.toThrow("Robinhood prices returned no quotes");
  });

  await withFetch(async () => new Response("unavailable", { status: 503 }), async () => {
    await expect(updateReferencePrices(context)).rejects.toThrow("api.robinhood.com returned HTTP 503");
  });

  await withFetch(async () => new Response("unavailable", { status: 503 }), async () => {
    await expect(fetchJsonWithTimeout("https://api.robinhood.com/rhj/prices/?apikey=secret"))
      .rejects.toThrow("api.robinhood.com returned HTTP 503");
  });
});
