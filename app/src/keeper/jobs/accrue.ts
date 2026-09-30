import { encodeFunctionData } from "viem";
import { PowerEngineAbi as powerEngineAbi } from "../../abi/PowerEngine";
import type { KeeperContext } from "../context";

export async function accrueStale(context: KeeperContext, force = false): Promise<Record<string, unknown>> {
  const metadata = await context.metadata();
  const states = Object.values(metadata.marketsById ?? {});
  if (!states.length) throw new Error("Waiting for indexed market state");
  const now = context.now(metadata).getTime() / 1000;
  const stale = states.some((market) => now - Number(market.state.lastAccrual) >= 6 * 3600);
  if (!force && !stale) return { stale: false };
  const result = await context.tx.submit({
    label: "accrue", to: context.deployment.contracts.engine,
    data: encodeFunctionData({ abi: powerEngineAbi, functionName: "accrueAll" }),
  });
  return { stale, dryRun: result.simulated, lastAccruedAt: context.now(metadata).toISOString() };
}
