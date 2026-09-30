import { encodeFunctionData } from "viem";
import { CrabVaultAbi as crabVaultAbi } from "../../abi/CrabVault";
import { safeErrorSummary } from "../../log";
import type { KeeperContext } from "../context";

export function createHedgeJob(context: KeeperContext) {
  const lastAttempt = new Map<number, number>();
  return async (): Promise<Record<string, unknown>> => {
    const metadata = await context.metadata();
    const settings = metadata.vaultConfig;
    if (!settings) throw new Error("Waiting for indexed vault configuration");
    const ticks = await context.sql<{ market_id: number; spot: string; hedge_units: string; hedge_target: string; regime: number }[]>`
      select distinct on (market_id) market_id, spot, hedge_units, hedge_target, regime from ticks order by market_id, ts desc`;
    const attempted: number[] = [];
    let retryAfterMs: number | undefined;
    for (const tick of ticks) {
      const target = Number(tick.hedge_target);
      const difference = Math.abs(target - Number(tick.hedge_units));
      if (tick.regime === 2 || !Number.isFinite(difference) || difference === 0) continue;
      if (difference * Number(tick.spot) < Number(settings.minHedgeTradeUsdg)) continue;
      if (target > 0 && difference / target * 10000 < settings.rebalanceThresholdBps) continue;
      const cooldown = 120_000 - (Date.now() - (lastAttempt.get(tick.market_id) ?? 0));
      if (cooldown > 0) {
        // A new trade can change the target during the throttle window. Keep
        // that work queued so it runs as soon as the market can hedge again.
        retryAfterMs = Math.min(retryAfterMs ?? Infinity, cooldown);
        continue;
      }
      lastAttempt.set(tick.market_id, Date.now());
      try {
        await context.tx.submit({
          label: `hedge:${tick.market_id}`, to: context.deployment.contracts.vault,
          data: encodeFunctionData({ abi: crabVaultAbi, functionName: "rebalance", args: [tick.market_id] }),
        });
        attempted.push(tick.market_id);
      } catch (error) {
        context.logger.warn({ market: tick.market_id, err: safeErrorSummary(error) }, "Hedge simulation/send failed; skipping this market");
      }
    }
    return { attempted, retryAfterMs: retryAfterMs ?? null };
  };
}
