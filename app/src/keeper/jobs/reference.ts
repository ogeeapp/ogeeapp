import { fetchJsonWithTimeout } from "../http";
import type { KeeperContext } from "../context";

export interface RefQuote {
  stock: string;
  symbol: string;
  bid: string | null;
  ask: string | null;
  tokenBid: string | null;
  tokenAsk: string | null;
  dailyHigh: string | null;
  dailyLow: string | null;
  dailyVolume: string | null;
  mintBurnUsd: string | null;
  halt: boolean;
  generatedAt: Date;
}

type ObjectValue = Record<string, unknown>;

function object(value: unknown): ObjectValue {
  return value && typeof value === "object" && !Array.isArray(value) ? value as ObjectValue : {};
}

function array(value: unknown): unknown[] {
  return Array.isArray(value) ? value : [];
}

function numericString(value: unknown): string | null {
  return typeof value === "string" && /^\d+(?:\.\d+)?$/.test(value) ? value : null;
}

export function normalizeQuotes(payload: unknown): RefQuote[] {
  const newestByStock = new Map<string, RefQuote>();
  for (const value of array(object(payload).quotes)) {
    const quote = object(value);
    const deployment = array(quote.deployments)
      .map(object)
      .find((candidate) => Number(candidate.chainId) === 4663);
    if (!deployment || typeof deployment.contractAddress !== "string"
      || !/^0x[0-9a-fA-F]{40}$/.test(deployment.contractAddress)) continue;

    const symbol = quote.tokenSymbol;
    if (typeof symbol !== "string" || !/^[A-Z0-9.\-]{1,16}$/.test(symbol)) continue;
    const generatedAt = new Date(String(quote.generatedAt));
    if (!Number.isFinite(generatedAt.getTime())) continue;

    const stock = deployment.contractAddress.toLowerCase();
    const normalized: RefQuote = {
      stock,
      symbol,
      bid: numericString(quote.bid),
      ask: numericString(quote.ask),
      tokenBid: numericString(quote.tokenBid),
      tokenAsk: numericString(quote.tokenAsk),
      dailyHigh: numericString(quote.dailyHigh),
      dailyLow: numericString(quote.dailyLow),
      dailyVolume: numericString(quote.dailyTradingVolume),
      mintBurnUsd: numericString(quote.mintBurnUsdVolume),
      halt: quote.isTradingHalt === true,
      generatedAt,
    };
    const previous = newestByStock.get(stock);
    if (!previous || normalized.generatedAt.getTime() > previous.generatedAt.getTime()) {
      newestByStock.set(stock, normalized);
    }
  }
  return [...newestByStock.values()];
}

export async function updateReferencePrices(context: KeeperContext): Promise<Record<string, unknown>> {
  const payload = await fetchJsonWithTimeout("https://api.robinhood.com/rhj/prices/");
  const quotes = normalizeQuotes(payload);
  if (quotes.length === 0) throw new Error("Robinhood prices returned no quotes");

  const rows = quotes.map((quote) => ({
    stock: quote.stock,
    symbol: quote.symbol,
    bid: quote.bid,
    ask: quote.ask,
    token_bid: quote.tokenBid,
    token_ask: quote.tokenAsk,
    daily_high: quote.dailyHigh,
    daily_low: quote.dailyLow,
    daily_volume: quote.dailyVolume,
    mint_burn_usd: quote.mintBurnUsd,
    halt: quote.halt,
    generated_at: quote.generatedAt.toISOString(),
  }));
  const columns = [
    "stock", "symbol", "bid", "ask", "token_bid", "token_ask", "daily_high", "daily_low",
    "daily_volume", "mint_burn_usd", "halt", "generated_at",
  ] as const;
  await context.sql`insert into ref_prices ${context.sql(rows, ...columns)}
    on conflict (stock) do update set stock=excluded.stock, symbol=excluded.symbol, bid=excluded.bid, ask=excluded.ask,
      token_bid=excluded.token_bid, token_ask=excluded.token_ask, daily_high=excluded.daily_high,
      daily_low=excluded.daily_low, daily_volume=excluded.daily_volume, mint_burn_usd=excluded.mint_burn_usd,
      halt=excluded.halt, generated_at=excluded.generated_at, fetched_at=now()`;

  const newestQuoteAt = quotes.reduce(
    (newest, quote) => Math.max(newest, quote.generatedAt.getTime()),
    0,
  );
  return { stored: quotes.length, newestQuoteAt: new Date(newestQuoteAt).toISOString() };
}
