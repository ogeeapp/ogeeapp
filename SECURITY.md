# Security

This file covers how to report a vulnerability, who controls what, what the system trusts, the threats it is built
against, the risks it accepts, and its audit history. Contract invariants and the tests that check them are listed in
[`contracts/INVARIANTS.md`](contracts/INVARIANTS.md). Operational scripts (upgrade, timelock handoff, post-deploy
check) are documented in [`contracts/script/README.md`](contracts/script/README.md).

## Reporting a vulnerability

Please report privately through GitHub's **Report a vulnerability** button on this repository's Security tab
(private vulnerability reporting). Do not open a public issue or pull request for a security problem.

Include the affected contract or service, a description of the impact, and a proof of concept if you have one (a
Foundry test against a mainnet fork is ideal). We aim to acknowledge reports within 72 hours and to agree a disclosure
date with you once a fix is deployed.

In scope: everything in `contracts/src` as deployed on Robinhood Chain (chain ID 4663, addresses in the
[README](README.md#mainnet-deployment)) and the services in `app/` (API, indexer, keeper). Out of scope: the
upstream libraries vendored in `contracts/lib`, third-party contracts (stock tokens, Chainlink feeds, Uniswap, USDG),
and the frontend.

## Roles and privileges

All three upgradeable contracts (`PowerEngine`, `CrabVault`, `MarketHours`) are UUPS proxies using OpenZeppelin
`AccessControl`. `OgeeLens`, `UniswapV3HedgeAdapter`, `UniswapV3TwapReference`, `PowerTokenFactory`, `EngineHelper`
and each `PowerToken` have no owner.

| Role | Contract | Can | Cannot | Holder |
| --- | --- | --- | --- | --- |
| `DEFAULT_ADMIN_ROLE` | Engine, vault, hours | Upgrade the proxy; list markets and change their risk config within `EngineHelper.validate` bounds; `setGlobal` (exposure cap 10–100%, treasury fee share ≤ 50%, treasury, sequencer feed); set hedge routes, the TWAP price reference, vault parameters (lock ≤ 30 days, slippage ≤ 5%, NAV guard ≤ 20%), deposit allowlist and deposit cap; resync hedge units; grant and revoke roles | Move user or LP funds directly (only through an upgrade) | `TimelockController` `0x0F9304D40087B2c7616eA1229f0763E1BAD50aB5` (48-hour minimum delay, self-administered). Its only proposer, executor and canceller is the 2-of-3 Safe `0x66a60131AE3526F8533f7955C44e827Fa40Ab70b`. The former admin EOA renounced every role on 2026-10-07 |
| `KEEPER_ROLE` | Engine | Change a market's base carry by at most 25% per 24 hours, inside the admin bounds | Anything else | Keeper EOA `0xe88f2aAA0653016d5147741262C8FEb496562E48` |
| `KEEPER_ROLE` | Vault | `rebalance` a market's hedge toward the engine's delta target (each swap bounded by `maxHedgeSlippageBps` and the oracle price) | Withdraw funds, change parameters | Keeper EOA (the admin's copy from initialization was renounced in the timelock handoff) |
| `KEEPER_ROLE` | MarketHours | Push the session calendar (at most 32 sessions, each at most 5 days + 1 hour, at most 30 days ahead) | Open a market whose feed is invalid or older than `maxAgeOpen` | Keeper EOA |
| `GUARDIAN_ROLE` | Engine | Pause buys for one market or globally | Pause sells, LP exits or anything else | Keeper EOA and the Safe (fast response; deliberately outside the timelock because it can only reduce risk) |

Every admin action (upgrades included) is scheduled by the Safe on the public timelock and can only be executed by the
Safe 48 hours later, so users can see a pending change and exit first. A compromised single owner key can do nothing on
its own; the Safe can cancel any pending operation.

## Trust assumptions

- **Robinhood stock tokens (issuer).** The engine trusts each token's `oraclePaused()` and `paused()` flags. The issuer
  is expected to set `oraclePaused` around corporate actions. Markets are PAUSED while it is set: buys stop, sells
  continue at the paused mark (see below).
- **Chainlink price feeds.** Feeds return the corporate-action-adjusted price per token (price × uiMultiplier), so the
  index stays continuous across splits. Rounds are rejected when the answer is non-positive, the timestamp is zero or
  in the future, or the value overflows; a stale round (older than `maxAgeOpen` / `maxAgeOffHours`) pauses the
  market. Each entry point reads every feed once.
- **L2 sequencer.** When `sequencerFeed` is set, a down sequencer or a recovery inside a one-hour grace period pauses
  all markets. Mainnet does not set it yet; see Accepted risks.
- **Uniswap v3.** Hedges trade through `SwapRouter02`. Every swap is bounded by the oracle price minus
  `maxHedgeSlippageBps` and its realised amounts are checked by balance deltas. Forced hedge sales are also floored at a
  pool TWAP when a price reference is configured.
- **USDG.** A standard 6-decimal ERC-20 with EIP-2612 permits; no fee-on-transfer or rebasing.
- **Keeper.** Liveness only. If the keeper stops, carry accrues on the next trade (up to seven days are charged), the
  calendar stops being extended (markets then fall back to OFF_HOURS rules), and hedges drift. It cannot take funds.
- **RPC providers (services).** The indexer, keeper and API trust their RPC endpoints for chain data. The API serves
  indexed data only; nothing on-chain depends on it.

## Threat model

| Threat | Boundary |
| --- | --- |
| Stale or manipulated oracle price | Single read per transaction; fail-closed validation; staleness pauses the market; paused sells use the lower of the last accrued price and a newer well-formed round; NAV guard band prices LP entries and exits against an adverse move |
| Trading against a held off-hours price | Off-hours buys revert once the held round is older than `offHoursBuyMaxAge`; off-hours spreads and bands are wider; sells stay open |
| Sandwiching the vault's forced hedge sales | The execution shortfall is charged to whoever triggered the sale; sales are floored at max(oracle, TWAP) less slippage; no gross-up of units sold |
| First-depositor / share inflation | Six decimals of virtual shares (`_decimalsOffset`), a seeded vault, and NAV-band pricing |
| LP front-running a known oracle update | Deposits price at the high edge, exits at the low edge of the NAV guard band |
| Locked LP escaping or pushing the lock | Deposits must be self-received; locked shares cannot be transferred |
| Draining via paused sells | Per-market leaky-bucket cap on paused-sell volume |
| Reentrancy | Transient reentrancy guards on every state-changing entry point; vault payments only to the engine's recipient |
| Malicious or compromised keeper | Bounded carry steps and calendar; rebalances bounded by oracle and slippage; cannot move funds. It could mark closed hours as open, which applies open spreads and the 26-hour open max age to a held price; the guardian (buy pause) and admin can respond, and the calendar is public |
| Compromised admin | 2-of-3 Safe threshold, then a 48-hour public timelock during which users can exit (sells are never pausable) and the Safe can cancel |
| Service abuse (API) | Per-IP rate limit, indexed queries, capped histories, read-only database sessions |
| Stuck keeper | Rejected broadcasts release their nonce; fresh fees per attempt; not-ready health signal; single signer through a Postgres advisory lock |

## Accepted risks

These are known and accepted with the stated bounds. Figures use the live NVDA configuration (10 bps fee, 40 / 150 /
300 bps open / off-hours / paused spread, 50 bps impact at full capacity, 25 USDG maximum trade, 50 USDG per hour
paused-sell budget).

- **Split buys avoid price impact (L-02).** Impact is linear in each trade's size relative to market capacity and does
  not depend on the current skew, so splitting a buy into small trades saves at most the impact term: 50 bps of the
  notional at full capacity, less at smaller sizes. Fees and spreads still apply to every trade, and the per-trade
  maximum, market cap and global cap still bind.
- **Carry is charged at the regime in force when a market is accrued (L-03).** A holder can choose the moment an
  interval is accrued. The keeper accrues every market at each session boundary and at least hourly while positions
  are open, so the window is at most one hour at a carry difference of at most 0.5% per day (about 0.02%). Carry for
  intervals longer than seven days without any accrual is forgiven.
- **LP exits are gated by utilisation (L-04).** LPs can withdraw only NAV − liability / `maxGlobalExposureBps`. With the
  50% global cap, LP exits reach zero when the power book reaches half of NAV (for example after a rally). There is
  no forced deleveraging; exits reopen as holders sell, carry decays positions, or NAV grows. The admin can no longer
  set the exposure cap below 10%. The frontend shows the withdrawable amount.
- **Off-hours exits can revert when the pool is far below the held close (L-06).** If a redeem needs a hedge sale while
  the pool trades more than the slippage allowance below the oracle (or TWAP) floor, the sale and the redeem revert
  even though `maxRedeem` advertises it. The LP can retry with a smaller amount or after the open; no value is lost.
  Large forced sales into thin pools revert in the same way instead of selling below the floor.
- **Treasury fee payouts bear their own shortfall.** When a sell's treasury fee needs a hedge sale (rare: the seller's
  payout is raised first), the treasury receives the fee less the execution shortfall. Slither reports the ignored
  return value; this is intended.
- **No sequencer uptime feed on mainnet yet.** `sequencerFeed` is unset because Chainlink publishes no sequencer uptime
  feed for Robinhood Chain (checked against the chain's feed directory on 2026-10-05). Stale-round checks still pause
  markets whose feeds stop updating. It will be set with `setGlobal` once a feed exists; the scheduled post-deploy
  check reports it as a warning until then.
- **Holiday calendar.** The keeper's NYSE holiday list currently runs through 2028; it must be extended before then.

Slither medium-severity results on `contracts/src` were triaged as false positives: strict equalities against zero
or sentinel values, locals that are intentionally zero-initialised, reentrancy on functions behind
`nonReentrant`, and ignored return values that are not needed (`latestRoundData` fields, view tuples).

## Build of record

Contracts are built with solc 0.8.28, via-IR, 200 optimizer runs, EVM `cancun`, `bytecode_hash = "ipfs"`
(`contracts/foundry.toml`), OpenZeppelin v5.4.0 and forge-std v1.9.7 vendored in `contracts/lib`. All mainnet
contracts are verified on Sourcify (full match). For unchanged contracts, a local `forge build` reproduces the deployed
runtime code byte for byte except for immutables (own address, router) and the metadata trailer. `OgeeLens` is the exception: its
source was restructured after deployment (same behaviour, verified field by field in tests), and the upgrade script
deploys a fresh lens so the live one matches this repository again.

## Audit history

| Date | Type | Scope | Result |
| --- | --- | --- | --- |
| 2026-10-05 | AI-assisted audit (rubric v2, full mode) | Contracts and services at `3fa0913` | Grade 3.9 / 10. Three Medium and six Low contract findings, one Medium and three Low service findings. All Mediums fixed; Lows fixed or accepted above |

Resolution of the 2026-10-05 findings:

| ID | Finding | Status |
| --- | --- | --- |
| M-01 | Paused sells settle at a stale accrued index | Fixed: paused marks use a newer, lower round; hourly keeper accrual |
| M-02 | Weekend held price is a free option | Fixed: `offHoursBuyMaxAge` closes off-hours buys on a stale round |
| M-03 | Forced hedge sales can be self-sandwiched | Fixed: shortfall charged to the caller, no gross-up, TWAP floor |
| B-M1 | One rejected broadcast stops the keeper | Fixed: nonce release, fresh fees, not-ready signal, advisory lock |
| L-01 | Paused-sell cap uses fixed hour windows | Fixed: leaky-bucket budget |
| L-02 | Price impact avoidable by splitting | Accepted (above) |
| L-03 | Carry regime chosen by the accruer | Mitigated by keeper accrual; accepted (above) |
| L-04 | LP exits freeze at high utilisation | Accepted (above); exposure cap floor added |
| L-05 | Lock pushed onto empty accounts by dust | Fixed: locked shares are non-transferable |
| L-06 | Off-hours redeem can revert below the held close | Accepted (above) |
| B-L1 | Snapshot fan-out from dust transfers | Fixed: bounded, chunked, failure-tolerant reads; hedge job checks freshness |
| B-L2 | Unindexed account queries, unbounded history, no rate limit | Fixed |
| B-L3 | Read-only API writes `keeper_status` | Fixed: read-only sessions, write removed |
| Admin | `maxGlobalExposureBps = 0` freezes LP exits; 100% fee share | Fixed: setter bounds |
