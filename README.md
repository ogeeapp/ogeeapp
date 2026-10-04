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

### Mainnet deployment

Robinhood Chain mainnet (chain ID `4663`), deployed at block `78474037`. All contracts below are verified on [Sourcify](https://sourcify.dev) (full match). Explorer: [robinhoodchain.blockscout.com](https://robinhoodchain.blockscout.com).

| Contract | Address |
| --- | --- |
| `PowerEngine` (proxy) | [`0x24C07e3b2FfCEE19D9c303c45f1fff4E42fc8E3C`](https://robinhoodchain.blockscout.com/address/0x24C07e3b2FfCEE19D9c303c45f1fff4E42fc8E3C) |
| `CrabVault` (proxy) | [`0x62e10868275CD724cd623e80820e5a895cCeC618`](https://robinhoodchain.blockscout.com/address/0x62e10868275CD724cd623e80820e5a895cCeC618) |
| `MarketHours` (proxy) | [`0xC302aD192Ea10c58a503A00E3B5b5C4D76eE4989`](https://robinhoodchain.blockscout.com/address/0xC302aD192Ea10c58a503A00E3B5b5C4D76eE4989) |
| `OgeeLens` | [`0x616E558A5b4C388e1be8592980ca95A24D36Ee05`](https://robinhoodchain.blockscout.com/address/0x616E558A5b4C388e1be8592980ca95A24D36Ee05) |
| `UniswapV3HedgeAdapter` | [`0x97F436673758f156eb68481687A60C76f24a1f93`](https://robinhoodchain.blockscout.com/address/0x97F436673758f156eb68481687A60C76f24a1f93) |
| `PowerTokenFactory` | [`0xe0a654BC07c4FB87B6e8E54B4e17E0238C25bdbb`](https://robinhoodchain.blockscout.com/address/0xe0a654BC07c4FB87B6e8E54B4e17E0238C25bdbb) |
| `EngineHelper` | [`0xe8F2c080D6bf48A2c8b6A24A7539524Bef5eBE88`](https://robinhoodchain.blockscout.com/address/0xe8F2c080D6bf48A2c8b6A24A7539524Bef5eBE88) |
| `PowerEngine` (implementation) | [`0xD4B1FC5471bC28dC4Fb1e2B6A8E635B3312E8dD4`](https://robinhoodchain.blockscout.com/address/0xD4B1FC5471bC28dC4Fb1e2B6A8E635B3312E8dD4) |
| `CrabVault` (implementation) | [`0x43BFcb5dAdA427FC40e2b97454a31783204e76d0`](https://robinhoodchain.blockscout.com/address/0x43BFcb5dAdA427FC40e2b97454a31783204e76d0) |
| `MarketHours` (implementation) | [`0x2dFFC40B5FA09a584C057D16426B1952AD69865C`](https://robinhoodchain.blockscout.com/address/0x2dFFC40B5FA09a584C057D16426B1952AD69865C) |
| USDG (collateral) | [`0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168`](https://robinhoodchain.blockscout.com/address/0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168) |

Markets (`PowerToken` per market, and the stock token it tracks):

| Market | PowerToken | Stock token |
| --- | --- | --- |
| NVDA | [`0x707602d1617EbfdeB0100829cb65BC9Bd7842051`](https://robinhoodchain.blockscout.com/address/0x707602d1617EbfdeB0100829cb65BC9Bd7842051) | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| TSLA | [`0x230b605b6532020d79dF840Ee185a464d419ae6A`](https://robinhoodchain.blockscout.com/address/0x230b605b6532020d79dF840Ee185a464d419ae6A) | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` |
| SPY | [`0xfb4EF44DdDcC4b24Ba5ea9789741b2817537b35b`](https://robinhoodchain.blockscout.com/address/0xfb4EF44DdDcC4b24Ba5ea9789741b2817537b35b) | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` |
| PLTR | [`0xF00ee0133c66bfcfAC087fCc226638D5a69e4B4e`](https://robinhoodchain.blockscout.com/address/0xF00ee0133c66bfcfAC087fCc226638D5a69e4B4e) | `0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A` |
| AAPL | [`0x9122bC8A36DCBC965aD86574D421b44B7F8e211E`](https://robinhoodchain.blockscout.com/address/0x9122bC8A36DCBC965aD86574D421b44B7F8e211E) | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` |

Always talk to the proxy addresses; implementations change on upgrade. Current addresses are also served by the API at `/v1/config`.

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
