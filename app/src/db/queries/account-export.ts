import { EXPLORER_URL } from "./config";
import type { ApiDependencies, DbRow } from "../../api/types";
import { asRows, dateValue } from "../../api/types";

/** Cap on exported activity rows, oldest first. */
export const EXPORT_ROW_LIMIT = 20_000;

export type ExportType = "all" | "trades" | "vault";

export interface ExportActivityRow extends DbRow {
  kind: "buy" | "sell" | "transfer_in" | "transfer_out" | "deposit" | "withdraw";
  symbol: string;
  usdg: string | null;
  tokens: string | null;
  price: string | null;
  ts: Date | string;
  tx_hash: string;
  log_index: number | string;
}

export const EXPORT_HEADER = [
  "Date (UTC)",
  "Type",
  "Market",
  "Quantity",
  "Price (USDG)",
  "Amount (USDG)",
  "Transaction",
  "Explorer",
];

const KIND_LABELS: Record<ExportActivityRow["kind"], string> = {
  buy: "Buy",
  sell: "Sell",
  deposit: "Deposit",
  withdraw: "Withdraw",
  transfer_in: "Transfer in",
  transfer_out: "Transfer out",
};

/** The oldest EXPORT_ROW_LIMIT activity rows for an address, oldest first. */
export async function exportActivityRows(
  deps: ApiDependencies,
  address: string,
  type: ExportType,
): Promise<{ rows: ExportActivityRow[]; truncated: boolean }> {
  const query = `with activity as (
    select case when t.side = 'buy' then 'buy' else 'sell' end::text as kind,
      m.symbol, t.usdg::text as usdg, t.tokens::text as tokens, t.price::text as price,
      t.ts, t.tx_hash, t.log_index
    from trades t join markets m on m.id = t.market_id
    where t.account = $1 or t.recipient = $1
    union all
    select case when x.to_addr = $1 then 'transfer_in' else 'transfer_out' end::text,
      coalesce(m.symbol, 'CRAB'), null::text, x.amount::text,
      (select price::text from ticks where ticks.market_id = x.market_id and ticks.block <= x.block order by ticks.block desc, ticks.ts desc limit 1),
      x.ts, x.tx_hash, x.log_index
    from transfers x left join markets m on m.id = x.market_id
    where x.from_addr = $1 or x.to_addr = $1
    union all
    select case when lower(v.kind) = 'deposit' then 'deposit' else 'withdraw' end::text,
      'CRAB', v.assets::text, v.shares::text,
      case when v.shares > 0 then (v.assets / v.shares)::text else null end,
      v.ts, v.tx_hash, v.log_index
    from vault_events v where v.account = $1
  )
  select activity.* from activity
  where ($2 = 'all'
    or ($2 = 'trades' and activity.kind in ('buy', 'sell', 'transfer_in', 'transfer_out') and activity.symbol <> 'CRAB')
    or ($2 = 'vault' and activity.symbol = 'CRAB'))
  order by activity.ts asc, activity.tx_hash asc, activity.log_index asc
  limit ${EXPORT_ROW_LIMIT + 1}`;
  const rows = asRows<ExportActivityRow>(await deps.sql.unsafe(query, [address, type]));
  const truncated = rows.length > EXPORT_ROW_LIMIT;
  // Drop the newest row of the over-fetch: it only signals truncation.
  return { rows: truncated ? rows.slice(0, EXPORT_ROW_LIMIT) : rows, truncated };
}

/** CSV rows for activity inside the inclusive UTC date range `from`..`to` (YYYY-MM-DD). */
export function buildExportRows(rows: ExportActivityRow[], from: string | undefined, to: string | undefined): string[][] {
  const fromMs = from ? Date.parse(`${from}T00:00:00.000Z`) : -Infinity;
  const toMs = to ? Date.parse(`${to}T23:59:59.999Z`) : Infinity;
  const output: string[][] = [];
  for (const row of rows) {
    const ts = dateValue(row.ts);
    if (!ts || ts.getTime() < fromMs || ts.getTime() > toMs) continue;
    output.push([
      ts.toISOString(),
      KIND_LABELS[row.kind] ?? row.kind,
      row.symbol === "CRAB" ? "CRAB" : `${row.symbol}²`,
      row.tokens ?? "",
      row.price ?? "",
      row.usdg ?? "",
      row.tx_hash,
      `${EXPLORER_URL}/tx/${row.tx_hash}`,
    ]);
  }
  return output;
}

function csvField(value: string): string {
  const guarded = /^[=+@]/.test(value) || (value.startsWith("-") && !/^-?\d+(\.\d+)?$/.test(value)) ? `'${value}` : value;
  return `"${guarded.replaceAll('"', '""')}"`;
}

/** RFC 4180 CSV with every field quoted, formula-like fields neutralised and a UTF-8 BOM. */
export function toCsv(header: string[], rows: string[][]): string {
  return `﻿${[header, ...rows].map((row) => `${row.map(csvField).join(",")}\r\n`).join("")}`;
}

/** The wallet's activity as CSV, filtered by type and inclusive UTC dates. */
export async function accountExport(
  deps: ApiDependencies,
  address: string,
  type: ExportType,
  from: string | undefined,
  to: string | undefined,
): Promise<{ csv: string; historyComplete: boolean; truncated: boolean }> {
  const { rows, truncated } = await exportActivityRows(deps, address, type);
  return { csv: toCsv(EXPORT_HEADER, buildExportRows(rows, from, to)), historyComplete: true, truncated };
}
