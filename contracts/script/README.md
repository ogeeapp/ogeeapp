# Operational scripts

Foundry scripts for upgrading and checking a live OGEE deployment. Run them from `contracts/`.

| Script | Sends transactions | Purpose |
| --- | --- | --- |
| `PostDeployCheck.s.sol` | never | Read-only health check of a deployment; reverts on any failed check |
| `UpgradeV2.s.sol` | yes (with `--broadcast`) | Deploys the V2 `PowerEngine` / `CrabVault` implementations and the TWAP reference, then upgrades directly or writes a timelock batch |
| `TimelockHandoff.s.sol` | yes (with `--broadcast`) | Deploys a `TimelockController` owned by a Safe and moves `DEFAULT_ADMIN_ROLE` to it |

Nothing here stores or reads keys. Sign with Foundry's own flags (`--ledger`, `--account <keystore>`, `--trezor`, ...).
Every script runs as a dry run first: without `--broadcast`, Forge only simulates against the RPC and prints the
transactions it would send.

## Addresses

All scripts find the deployment the same way, later sources overriding earlier ones:

1. Built-in defaults for Robinhood Chain mainnet (chain `4663`): the public contract and market addresses listed in the
   repository README. Operator accounts (admin, keeper, Safe, timelock) are never built in.
2. A deployment file in the app's schema (`app/src/chain/deployment.ts`): `DEPLOYMENT_FILE=<path inside contracts/>`,
   or the raw JSON in `DEPLOYMENT_JSON` (handy in CI, or for a file outside the project:
   `DEPLOYMENT_JSON="$(cat /path/to/mainnet.json)"`).
3. Per-address overrides: `ENGINE`, `VAULT`, `MARKET_HOURS`, `LENS`, `HEDGE_ADAPTER`, `USDG`, `ENGINE_IMPL`,
   `VAULT_IMPL`, `MARKET_HOURS_IMPL`, `ADMIN`, `KEEPER`.

The Uniswap v3 factory is `UNISWAP_V3_FACTORY`, else `SWAP_ROUTER.factory()`, else read from the router address the
hedge adapter was deployed with.

## Recommended order

1. **Rehearse on a fork** (below): `UpgradeV2` direct mode, `PostDeployCheck`, `TimelockHandoff`, `PostDeployCheck`.
2. **Dry-run on mainnet**: `UpgradeV2` without `--broadcast`, `--sender <admin>`.
3. **Upgrade**: `UpgradeV2` with `--broadcast`.
4. **Check**: `PostDeployCheck` with `ENGINE_IMPL` / `VAULT_IMPL` set to the new implementations, then update the
   implementation defaults in `script/lib/OgeeScript.sol` (and the README table) in the same change.
5. **Hand off to the timelock**: `TimelockHandoff` (grant), `PostDeployCheck` with `TIMELOCK`, `ALLOW_EOA_ADMIN=1`,
   then `TimelockHandoff` with `REVOKE_EOA_ADMIN=1`.
6. **Check again**: `PostDeployCheck` with `TIMELOCK` and `SAFE` (and without `ALLOW_EOA_ADMIN`).

Later upgrades go through the Safe: `UpgradeV2` (or a script like it) in `timelock` mode.

## PostDeployCheck

```sh
forge script script/PostDeployCheck.s.sol --rpc-url "$RPC_URL"
```

Needs only an RPC URL on mainnet. Prints `[PASS]` / `[WARN]` / `[FAIL]` per check and a summary; reverts (non-zero
exit) when anything fails. It never broadcasts; the one non-view call it makes (trying `initialize` on each
implementation, which must revert) only happens in the local simulation.

Checks: code at every address; proxy implementation slots against the expected implementations; implementations are
UUPS and have their initializers disabled; engine/vault/USDG/market-hours cross-references and treasury; role holders;
timelock configuration; `maxGlobalExposureBps` in [1000, 10000] and `protocolFeeShareBps` <= 5000; sequencer uptime
feed set and reporting up; vault parameters within the contract's bounds, NAV positive, deposit cap, price reference;
a current or upcoming market session; per market: token/stock/feed/scale against the expected list, `marketIdOf`
round-trip, feed decimals and description, feed age within `maxAgeOpen` / `maxAgeOffHours` for the current session,
`offHoursBuyMaxAge`, buys not paused, hedge route (adapter, pool fee, the Uniswap pool exists, observation cardinality,
in-range liquidity), TWAP reference against the feed; lens results consistent with the engine.

The phase is detected from the vault: before the V2 upgrade (`priceReference()` missing) the V2 checks are reported as
`WARN ... [pre-upgrade]`; after it they fail. Force it with `CHECK_PHASE=pre|post`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `ADMIN` / `KEEPER` | from deployment file | Expected admin EOA and keeper; enables the role checks |
| `TIMELOCK` / `SAFE` | unset | After the handoff: the timelock is the only expected admin, the Safe its proposer/executor/canceller |
| `ALLOW_EOA_ADMIN` | `false` | With `TIMELOCK`: the admin EOA may still hold the admin role (between grant and revoke) |
| `EXPECTED_ADMINS` / `EXPECTED_KEEPERS` / `EXPECTED_GUARDIANS` | derived | Comma-separated explicit holder lists. Guardians default to keeper + `ADMIN` |
| `ROLE_CANDIDATES`, `DEPLOYER` | unset | Extra accounts that must not hold any role unless expected (AccessControl is not enumerable) |
| `TREASURY` | unset | Expected treasury (otherwise only non-zero is checked) |
| `MIN_TIMELOCK_DELAY` | `172800` | Minimum accepted timelock delay |
| `ALLOW_UNSET_SEQUENCER_FEED` | `false` | Report an unset `sequencerFeed` as WARN instead of FAIL |
| `EXPECT_PAUSED_MARKETS` | unset | Comma-separated market ids whose stale feed / paused regime is expected (WARN) |
| `ALLOW_STALE_FEEDS` | `false` | Report every stale feed as WARN |
| `MIN_OBSERVATION_CARDINALITY` | TWAP window + 1 | Pool cardinality below this is a WARN |
| `MAX_TWAP_DEVIATION_BPS` | `500` | TWAP vs feed deviation reported as WARN above this |
| `CHECK_PHASE` | `auto` | `pre` or `post` |
| `REPORT_ONLY` | `false` | Print everything but exit 0 even with failures |

### Scheduled CI job

The workflow only needs one secret, an RPC URL for the chain (`RPC_URL`). Expected operator addresses are not secrets
and can live in plain workflow variables:

```sh
cd contracts
forge script script/PostDeployCheck.s.sol --rpc-url "$RPC_URL"
```

with, as workflow `env:` (all optional): `KEEPER`, `ADMIN` or `TIMELOCK` + `SAFE`, and `ALLOW_UNSET_SEQUENCER_FEED=1`
while the chain has no Chainlink L2 sequencer uptime feed. The job fails when the script exits non-zero; the log is the
report. Forge needs the `lib/` submodule contents, which are vendored in the repo, so no extra install step is needed
beyond Foundry itself.

## UpgradeV2

Deploys `PowerEngine` and `CrabVault` implementations and a `UniswapV3TwapReference(factory, usdg, TWAP_WINDOW)`, then:

- `UPGRADE_MODE=direct`: the sender (the current `DEFAULT_ADMIN_ROLE` holder) calls `upgradeToAndCall` on both proxies,
  then `setMarketConfig` per market changing only `offHoursBuyMaxAge`, `vault.setPriceReference(twap)`, and, when
  `SEQUENCER_FEED` is set, `setGlobal` with the current values and the new feed.
- `UPGRADE_MODE=timelock`: the sender only deploys. The upgrade and configuration calls become one `TimelockController`
  batch written to `BATCH_OUTPUT` with the Safe transactions to send (`scheduleBatch`, then `executeBatch` after the
  delay). When the timelock already holds the admin role, the batch is simulated locally through schedule + execute.
  The `setMarketConfig` payloads embed each market's current config: if another config change lands between
  generating and executing the batch, regenerate it.

Guards (the script reverts before broadcasting anything if one fails): both proxies' current implementations must equal
the expected ones; new implementations must be UUPS with initializers disabled; state read before and after the
upgrade must be identical (market count, every market's config and state including `vaultShort` and `lastGoodIndex`,
vault supply, USDG balance, parameters, hedge units and routes, global settings, admin roles); after configuration
every config field except `offHoursBuyMaxAge` must be unchanged.

| Variable | Default | Meaning |
| --- | --- | --- |
| `UPGRADE_MODE` | required | `direct` or `timelock` |
| `EXPECTED_ENGINE_IMPL` / `EXPECTED_VAULT_IMPL` | deployment `engineImpl` / `vaultImpl` | Implementations the proxies must currently point to |
| `OFF_HOURS_BUY_MAX_AGE` | `3600` | Seconds; applied to every market. `OFF_HOURS_BUY_MAX_AGE_<id>` overrides one market |
| `TWAP_WINDOW` | `1800` | TWAP reference window in seconds |
| `SEQUENCER_FEED` | unset | Chainlink L2 sequencer uptime feed to set with `setGlobal` |
| `MIN_OBSERVATION_CARDINALITY` | `TWAP_WINDOW + 1` | Pools below this are logged |
| `INCREASE_CARDINALITY` | `false` | Also call `increaseObservationCardinalityNext` on those pools (permissionless, sender pays gas) |
| `NEW_ENGINE_IMPL` / `NEW_VAULT_IMPL` / `TWAP_REFERENCE` | unset | Reuse already-deployed contracts instead of deploying |
| `TIMELOCK` | required in timelock mode | The `TimelockController` holding `DEFAULT_ADMIN_ROLE` |
| `TIMELOCK_DELAY` / `TIMELOCK_SALT` / `TIMELOCK_PREDECESSOR` | min delay / derived / zero | Batch parameters |
| `SAFE` | unset | Proposer used for the local batch simulation |
| `SIMULATE_BATCH` | `true` | Simulate the batch in timelock mode |
| `BATCH_OUTPUT` | `out/upgrade-v2-batch.json` | Output (written in both modes; must be under `out/`) |

```sh
# dry run (no signature needed)
UPGRADE_MODE=direct forge script script/UpgradeV2.s.sol --rpc-url "$RPC_URL" --sender <admin>

# real run
UPGRADE_MODE=direct forge script script/UpgradeV2.s.sol --rpc-url "$RPC_URL" --ledger --sender <admin> --broadcast

# timelock batch
UPGRADE_MODE=timelock TIMELOCK=<timelock> SAFE=<safe> \
  forge script script/UpgradeV2.s.sol --rpc-url "$RPC_URL" --ledger --sender <deployer> --broadcast
```

The script prints the new implementation addresses; record them (`ENGINE_IMPL` / `VAULT_IMPL` for `PostDeployCheck`,
the defaults in `script/lib/OgeeScript.sol`, the README, and the app's deployment file).

## TimelockHandoff

Deploys `TimelockController(TIMELOCK_MIN_DELAY, [SAFE], [SAFE], address(0))` (the Safe proposes, executes and cancels;
the timelock administers itself) and grants it `DEFAULT_ADMIN_ROLE` on the engine, vault and market hours. With
`REVOKE_EOA_ADMIN=1` the sender then renounces its own `DEFAULT_ADMIN_ROLE` on all three, and its vault `KEEPER_ROLE`
when `KEEPER` holds that role. It refuses to revoke unless the timelock holds the role on every proxy, the timelock is
wired exactly as above, and `SAFE` has code.

`KEEPER_ROLE` and the engine's `GUARDIAN_ROLE` are untouched: the guardian can only pause buys, which never blocks
sells, so it can stay with a fast EOA or Safe outside the timelock. `GRANT_GUARDIAN_TO_SAFE=1` also grants it to the
Safe.

| Variable | Default | Meaning |
| --- | --- | --- |
| `SAFE` | required | Safe that will propose/execute/cancel |
| `TIMELOCK_MIN_DELAY` | `172800` | Delay in seconds (48 h) |
| `TIMELOCK` | unset | Reuse an existing timelock instead of deploying |
| `REVOKE_EOA_ADMIN` | `false` | Renounce the sender's admin roles after the grant |
| `GRANT_GUARDIAN_TO_SAFE` | `false` | Also make the Safe an engine guardian |
| `ADMIN` / `KEEPER` | deployment file | Sender must equal `ADMIN` when set; `KEEPER` decides the vault keeper renounce |

```sh
SAFE=<safe> forge script script/TimelockHandoff.s.sol --rpc-url "$RPC_URL" --ledger --sender <admin> --broadcast
SAFE=<safe> TIMELOCK=<timelock> REVOKE_EOA_ADMIN=1 \
  forge script script/TimelockHandoff.s.sol --rpc-url "$RPC_URL" --ledger --sender <admin> --broadcast
```

## Fork rehearsal

Use a throwaway Anvil fork with the admin unlocked; never a shared node.

```sh
anvil --fork-url "$RPC_URL" --port 7299 --chain-id 4663 &
cast rpc anvil_impersonateAccount <admin> --rpc-url http://127.0.0.1:7299
cast rpc anvil_setBalance <admin> 0x56BC75E2D63100000 --rpc-url http://127.0.0.1:7299
F=http://127.0.0.1:7299

UPGRADE_MODE=direct forge script script/UpgradeV2.s.sol --rpc-url $F --unlocked --sender <admin> --broadcast
ENGINE_IMPL=<new> VAULT_IMPL=<new> ADMIN=<admin> KEEPER=<keeper> ALLOW_UNSET_SEQUENCER_FEED=1 \
  forge script script/PostDeployCheck.s.sol --rpc-url $F

# any address with code can stand in for the Safe on a fork
SAFE=<contract> REVOKE_EOA_ADMIN=1 KEEPER=<keeper> \
  forge script script/TimelockHandoff.s.sol --rpc-url $F --unlocked --sender <admin> --broadcast
ENGINE_IMPL=<new> VAULT_IMPL=<new> ADMIN=<admin> KEEPER=<keeper> TIMELOCK=<timelock> SAFE=<contract> \
  ALLOW_UNSET_SEQUENCER_FEED=1 forge script script/PostDeployCheck.s.sol --rpc-url $F
```

`broadcast/`, `cache/` and `out/` are git-ignored; fork runs leave nothing to commit.
