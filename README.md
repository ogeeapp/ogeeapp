# OGEE Backend

Smart contracts and backend services for OGEE: squared ("power") exposure to stock tokens on Robinhood Chain (chain ID `4663`).

Each market tracks `price² / scale` of a Robinhood stock token (NVDA, TSLA, SPY, PLTR, AAPL). Users buy and sell market tokens with USDG. One vault (`CRAB`) takes the other side of every trade and hedges with the underlying stock on Uniswap v3.

## Layout

```
contracts/   Solidity contracts (Foundry)
app/         Bun services: API, indexer, keeper, migrations
```

### Contracts (`contracts/src`)

| Contract | What it does |
| --- | --- |
| `PowerEngine` | Market list, price checks, carry (funding) accrual, quotes, buy/sell |
| `PowerToken` | ERC-20 position token per market. Only the engine can mint/burn |
| `PowerTokenFactory` | Deploys new `PowerToken`s for the engine |
| `EngineHelper` | Admin checks and view math moved out of the engine (size limit) |
| `CrabVault` | ERC-4626 vault over USDG. Counterparty for all trades, holds the hedges |
| `MarketHours` | Market session calendar, pushed by the keeper |
| `UniswapV3HedgeAdapter` | Swaps through Uniswap v3 `SwapRouter02` for hedging |
| `OgeeLens` | Read-only batched views for markets, the vault and accounts |

`PowerEngine`, `CrabVault` and `MarketHours` are UUPS upgradeable. OpenZeppelin v5.4.0 and forge-std v1.9.7 are vendored in `contracts/lib`.

### Services (`app/src`)

| Service | Entry | What it does |
| --- | --- | --- |
| API | `bin/api.ts` | Read-only REST API (Hono). Reads only from Postgres, makes no RPC calls |
| Indexer | `bin/indexer.ts` | The only process that polls the chain. Writes events and snapshots to Postgres |
| Keeper | `bin/keeper.ts` | Scheduled jobs that send transactions: `sessions`, `accrue`, `hedge`, `carry`, `risk`, `corp-actions` |
| Migrate | `bin/migrate.ts` | Applies Drizzle migrations from `app/drizzle` |

Other folders: `abi/` (contract ABIs), `chain/` (RPC pool, clients, deployment file loader), `db/` (schema and queries), `lib/` (fixed-point and time helpers).

## Requirements

- [Bun](https://bun.sh) 1.2+
- [Foundry](https://getfoundry.sh) (solc 0.8.28 is set in `foundry.toml`)
- Postgres 16 with TimescaleDB (e.g. `timescale/timescaledb:latest-pg16`)

## Contracts

```sh
cd contracts
forge build
forge test
```

## Services

```sh
cd app
bun install
bun run migrate      # set up the database
bun run indexer
bun run keeper
bun run api
```

### Configuration

All config comes from environment variables and is checked at startup (`app/src/config.ts`). The main ones:

| Variable | Default | Notes |
| --- | --- | --- |
| `DATABASE_URL` | – | Required |
| `POSTGRES_PASSWORD` | – | Required |
| `NETWORK` | `fork` | `fork` or `mainnet` |
| `CHAIN_ID` | `4663` | |
| `DEPLOYMENT_FILE` | `/app/deployments/fork.json` | Contract addresses and markets (see below) |
| `PUBLIC_RPC_URL` | Robinhood Chain public RPC | |
| `ALCHEMY_API_KEYS` | empty | Comma-separated, rotated by the RPC pool |
| `RPC_URL_OVERRIDE` | empty | Send all RPC calls to one URL (e.g. a local Anvil fork) |
| `KEEPER_PRIVATE_KEY` | empty | Keeper signer. Without it the keeper sends nothing |
| `KEEPER_ENABLED_JOBS` | all jobs | Comma-separated job names |
| `KEEPER_DRY_RUN` | `0` | `1` = build and simulate transactions but don't send |
| `API_PORT` | `3101` | |
| `CORS_ORIGINS` | empty | Comma-separated allowed origins |
| `LOG_LEVEL` | `info` | Pino log level |

Never commit `.env` files or keys; they are ignored by `.gitignore`.

### Deployment file

The services read contract addresses from a JSON file (`DEPLOYMENT_FILE`). It holds `chainId`, `network`, `deployBlock`, the `contracts` addresses (engine, vault, marketHours, lens, hedgeAdapter, usdg and implementations) and a `markets` list. The full schema is in `app/src/chain/deployment.ts`. The indexer waits and retries until a valid file is present.

## API

All routes are `GET` and versioned under `/v1`. The OpenAPI spec is at `/v1/openapi.json`.

| Route | |
| --- | --- |
| `/v1/health` | Service and indexer status |
| `/v1/config` | Chain, contract addresses and markets (the frontend reads addresses from here) |
| `/v1/markets`, `/v1/markets/{symbol}` | Market list and details |
| `/v1/markets/{symbol}/candles` | Price candles |
| `/v1/markets/{symbol}/carry` | Carry history |
| `/v1/markets/{symbol}/trades` | Recent trades |
| `/v1/markets/{symbol}/regimes` | Pricing regime changes (open, off-hours, paused) |
| `/v1/accounts/{address}/portfolio` | Positions for a wallet |
| `/v1/accounts/{address}/activity` | Trade and vault history for a wallet |
| `/v1/vault`, `/v1/vault/history` | Vault state and NAV history |
| `/v1/corporate-actions` | Splits and other stock events |
| `/v1/stats` | Protocol totals |

## Checks

```sh
cd app
bun run typecheck
bun test
bun run smoke [API_URL]   # hits every route and checks the response shape (default http://127.0.0.1:7201)
bun run rpc-pool:check
```

## License

[MIT](LICENSE)
