import { expect, test } from "bun:test";
import { createHedgeJob } from "./jobs/hedge";
import { createLogger } from "../log";
import type { KeeperContext } from "./context";

test("a sell during the hedge cooldown queues the new target until the throttle expires", async () => {
  const originalNow = Date.now;
  let now = 1_000_000;
  Date.now = () => now;
  let target = "10";
  let units = "0";
  let submitted = 0;
  const context = {
    metadata: async () => ({ vaultConfig: { minHedgeTradeUsdg: "2", rebalanceThresholdBps: 1000 } }),
    sql: async () => [{ market_id: 0, spot: "100", regime: 0, hedge_units: units, hedge_target: target }],
    deployment: { contracts: { vault: "0x0000000000000000000000000000000000000001" } },
    tx: { submit: async () => { submitted++; return { simulated: false }; } },
    logger: createLogger("silent"),
  } as unknown as KeeperContext;
  try {
    const job = createHedgeJob(context);
    expect((await job()).attempted).toEqual([0]);
    now += 10_000; units = "10"; target = "0";
    const cooling = await job();
    expect(cooling.attempted).toEqual([]);
    expect(cooling.retryAfterMs).toBe(110_000);
    expect(submitted).toBe(1);
    now += 110_001;
    expect((await job()).attempted).toEqual([0]);
    expect(submitted).toBe(2);
  } finally { Date.now = originalNow; }
});
