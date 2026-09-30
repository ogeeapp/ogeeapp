import { encodeFunctionData, keccak256, stringToHex } from "viem";
import { MarketHoursAbi as marketHoursAbi } from "../../abi/MarketHours";
import { computeSessions, type Session } from "../sessions";
import type { KeeperContext } from "../context";

export function sessionHash(sessions: Session[]): string {
  return keccak256(stringToHex(JSON.stringify(sessions.map((s) => [s.open.toString(), s.close.toString()]))));
}

export async function updateSessions(context: KeeperContext): Promise<Record<string, unknown>> {
  const meta = await context.metadata();
  const now = context.now(meta);
  const sessions = computeSessions(now);
  const sessionsHash = sessionHash(sessions);
  const rows = await context.sql<{ meta: Record<string, unknown> }[]>`select meta from keeper_status where job = 'sessions'`;
  const prior = rows[0]?.meta ?? {};
  const horizon = Number(prior.horizon ?? 0);
  if (prior.sessionsHash === sessionsHash && horizon - now.getTime() / 1000 >= 7 * 86400) return {};
  const result = await context.tx.submit({
    label: "sessions", to: context.deployment.contracts.marketHours,
    data: encodeFunctionData({ abi: marketHoursAbi, functionName: "setSessions", args: [sessions] }),
  });
  if (result.simulated) return { dryRun: true, proposedSessionsHash: sessionsHash };
  return {
    sessionsHash, horizon: sessions.at(-1)?.close.toString() ?? "0",
    sessions: sessions.map((session) => ({ open: session.open.toString(), close: session.close.toString() })),
    dryRun: false,
  };
}
