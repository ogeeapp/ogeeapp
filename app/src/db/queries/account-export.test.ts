import { expect, test } from "bun:test";
import type { ApiDependencies } from "../../api/types";
import { buildExportRows, EXPORT_HEADER, EXPORT_ROW_LIMIT, exportActivityRows, toCsv, type ExportActivityRow } from "./account-export";

const address = "0x1111111111111111111111111111111111111111";
const tx = (n: number) => `0x${String(n).padStart(64, "0")}`;

function row(kind: ExportActivityRow["kind"], ts: string, n: number, symbol = "NVDA"): ExportActivityRow {
  return { kind, symbol, usdg: "10", tokens: "2", price: "5", ts, tx_hash: tx(n), log_index: n };
}

test("csv quotes every field and doubles inner quotes", () => {
  const csv = toCsv(["h"], [['a"b'], ["x,y"], ["line\nbreak"]]);
  expect(csv).toBe('﻿"h"\r\n"a""b"\r\n"x,y"\r\n"line\nbreak"\r\n');
});

test("csv neutralises formula-like fields but keeps negative numbers", () => {
  const csv = toCsv(EXPORT_HEADER, [["=SUM(A1)", "+1", "@x", "-12.5", "-cmd", "-3"]]);
  expect(csv.startsWith("﻿")).toBe(true);
  const lines = csv.slice(1).split("\r\n");
  expect(lines[0]).toBe(EXPORT_HEADER.map((value) => `"${value}"`).join(","));
  expect(lines[1]).toBe(`"'=SUM(A1)","'+1","'@x","-12.5","'-cmd","-3"`);
  expect(lines[2]).toBe("");
});

test("export rows label kinds and markets and link the explorer", () => {
  const rows = buildExportRows([
    row("buy", "2026-01-01T00:00:00.000Z", 1),
    { ...row("deposit", "2026-01-02T00:00:00.000Z", 2, "CRAB"), price: null },
  ], undefined, undefined);
  expect(rows[0]).toEqual([
    "2026-01-01T00:00:00.000Z", "Buy", "NVDA²", "2", "5", "10", tx(1), `https://robinhoodchain.blockscout.com/tx/${tx(1)}`,
  ]);
  expect(rows[1]!.slice(1, 5)).toEqual(["Deposit", "CRAB", "2", ""]);
});

test("export date range is inclusive at both UTC day edges", () => {
  const rows = [
    row("buy", "2026-01-31T23:59:59.999Z", 1),
    row("buy", "2026-02-01T00:00:00.000Z", 2),
    row("buy", "2026-02-28T23:59:59.000Z", 3),
    row("buy", "2026-03-01T00:00:00.000Z", 4),
  ];
  expect(buildExportRows(rows, "2026-02-01", "2026-02-28").map((value) => value[6])).toEqual([tx(2), tx(3)]);
  expect(buildExportRows(rows, "2026-02-01", undefined)).toHaveLength(3);
  expect(buildExportRows(rows, undefined, "2026-02-28")).toHaveLength(3);
});

function depsWith(rows: unknown[], calls: Array<{ query: string; params: unknown[] }>) {
  const sql = async () => [];
  Object.assign(sql, { unsafe: async (query: string, params: unknown[]) => { calls.push({ query, params }); return rows; } });
  return { sql, config: { NETWORK: "mainnet" } } as unknown as ApiDependencies;
}

test("export rows query the full history oldest first", async () => {
  const calls: Array<{ query: string; params: unknown[] }> = [];
  const result = await exportActivityRows(depsWith([], calls), address, "trades");
  expect(result).toEqual({ rows: [], truncated: false });
  expect(calls[0]!.params).toEqual([address, "trades"]);
  expect(calls[0]!.query).toContain("order by activity.ts asc");
  expect(calls[0]!.query).toContain(`limit ${EXPORT_ROW_LIMIT + 1}`);
  expect(calls[0]!.query).not.toContain("$3::timestamptz");
});

test("export rows keep the oldest rows when truncated", async () => {
  const rows = Array.from({ length: EXPORT_ROW_LIMIT + 1 }, (_, index) => row("buy", "2026-01-01T00:00:00.000Z", index));
  const result = await exportActivityRows(depsWith(rows, []), address, "all");
  expect(result.truncated).toBe(true);
  expect(result.rows).toHaveLength(EXPORT_ROW_LIMIT);
  expect(result.rows.at(-1)!.tx_hash).toBe(tx(EXPORT_ROW_LIMIT - 1));
});
