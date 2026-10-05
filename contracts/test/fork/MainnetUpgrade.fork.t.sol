// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {CrabVault} from "../../src/CrabVault.sol";
import {PowerEngine} from "../../src/PowerEngine.sol";
import {PowerToken} from "../../src/PowerToken.sol";
import {UniswapV3TwapReference, IUniswapV3FactoryLike} from "../../src/UniswapV3TwapReference.sol";
import {IHedgeAdapter} from "../../src/interfaces/IHedgeAdapter.sol";
import {MarketConfig, MarketState, Regime} from "../../src/libs/OgeeTypes.sol";

interface IUniswapV3PoolSlot0 {
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
}

interface IUniswapV3FactoryPools {
    function getPool(address a, address b, uint24 fee) external view returns (address);
}

interface IRouterFactory {
    function factory() external view returns (address);
}

/// @notice Upgrade rehearsal on a fork of Robinhood Chain mainnet (read-only: nothing is broadcast). Skipped unless
/// FORK_RPC_URL is set; FORK_BLOCK pins a block. Run:
///   FORK_RPC_URL=https://rpc.mainnet.chain.robinhood.com forge test --match-path test/fork/MainnetUpgrade.fork.t.sol -vv
/// Upgrades the live PowerEngine and CrabVault proxies to implementations built from this tree (impersonating the
/// admin), proves every stored field survives, then exercises accrual, quotes, a small buy/sell, a rebalance against
/// the real Uniswap route, and the TWAP reference against the real factory.
contract MainnetUpgradeForkTest is Test {
    address internal constant ADMIN = 0x7C68924928CE35Db1040D13aF029bccDE80Aa93c;
    PowerEngine internal constant ENGINE = PowerEngine(0x24C07e3b2FfCEE19D9c303c45f1fff4E42fc8E3C);
    CrabVault internal constant VAULT = CrabVault(0x62e10868275CD724cd623e80820e5a895cCeC618);
    address internal constant MARKET_HOURS = 0xC302aD192Ea10c58a503A00E3B5b5C4D76eE4989;
    IERC20 internal constant USDG = IERC20(0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168);
    /// Vault keeper on mainnet (RoleGranted log); the admin's own keeper role was revoked after deployment.
    address internal constant KEEPER = 0xe88f2aAA0653016d5147741262C8FEb496562E48;
    address internal constant ADAPTER = 0x97F436673758f156eb68481687A60C76f24a1f93;
    bytes32 internal constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    bool internal forked;

    struct Snapshot {
        bytes[] configs;
        bytes[] states;
        uint256[] hedgeUnits;
        address[] adapters;
        uint24[] fees;
        uint8 count;
        uint256 totalSupply;
        uint256 totalAssets;
        int256 nav;
        uint256 vaultCash;
        uint256 adminShares;
        uint256 adminLastDeposit;
        bytes engineGlobals;
        bytes vaultParams;
        bytes roles;
    }

    function setUp() public {
        string memory url = vm.envOr("FORK_RPC_URL", string(""));
        if (bytes(url).length == 0) return;
        uint256 blockNumber = vm.envOr("FORK_BLOCK", uint256(0));
        if (blockNumber == 0) vm.createSelectFork(url);
        else vm.createSelectFork(url, blockNumber);
        forked = true;
        require(block.chainid == 4663, "not Robinhood Chain mainnet");
    }

    function _snapshot() internal view returns (Snapshot memory s) {
        s.count = ENGINE.marketCount();
        s.configs = new bytes[](s.count);
        s.states = new bytes[](s.count);
        s.hedgeUnits = new uint256[](s.count);
        s.adapters = new address[](s.count);
        s.fees = new uint24[](s.count);
        for (uint8 i; i < s.count; ++i) {
            s.configs[i] = abi.encode(ENGINE.getConfig(i));
            s.states[i] = abi.encode(ENGINE.getState(i));
            s.hedgeUnits[i] = VAULT.hedgeUnits(i);
            (IHedgeAdapter a, uint24 f) = VAULT.routeForMarket(i);
            (s.adapters[i], s.fees[i]) = (address(a), f);
        }
        s.totalSupply = VAULT.totalSupply();
        s.totalAssets = VAULT.totalAssets();
        s.nav = VAULT.navView();
        s.vaultCash = USDG.balanceOf(address(VAULT));
        s.adminShares = VAULT.balanceOf(ADMIN);
        s.adminLastDeposit = VAULT.lastDeposit(ADMIN);
        s.engineGlobals = abi.encode(
            address(ENGINE.usdg()),
            address(ENGINE.vault()),
            address(ENGINE.marketHours()),
            ENGINE.treasury(),
            address(ENGINE.sequencerFeed()),
            ENGINE.maxGlobalExposureBps(),
            ENGINE.protocolFeeShareBps(),
            ENGINE.globalBuysPaused(),
            ENGINE.totalLiability()
        );
        s.vaultParams = abi.encode(
            address(VAULT.usdg()),
            address(VAULT.engine()),
            VAULT.publicDeposits(),
            VAULT.lockSeconds(),
            VAULT.cashBufferBps(),
            VAULT.hedgeRatioBps(),
            VAULT.rebalanceThresholdBps(),
            VAULT.maxHedgeSlippageBps(),
            VAULT.navGuardOpenBps(),
            VAULT.navGuardClosedBps(),
            VAULT.minHedgeTradeUsdg(),
            VAULT.maxTotalDeposits(),
            _priceReference()
        );
        s.roles = abi.encode(
            ENGINE.hasRole(bytes32(0), ADMIN),
            ENGINE.hasRole(ENGINE.KEEPER_ROLE(), ADMIN),
            ENGINE.hasRole(ENGINE.GUARDIAN_ROLE(), ADMIN),
            VAULT.hasRole(bytes32(0), ADMIN),
            VAULT.hasRole(VAULT.KEEPER_ROLE(), ADMIN),
            VAULT.isDepositor(ADMIN)
        );
    }

    /// `priceReference` was appended from the storage gap; implementations older than the TWAP floor lack the getter.
    /// Absent reads as zero, which is also what the new implementation must read from the untouched gap slot.
    function _priceReference() internal view returns (address) {
        (bool ok, bytes memory ret) = address(VAULT).staticcall(abi.encodeWithSignature("priceReference()"));
        return ok && ret.length == 32 ? abi.decode(ret, (address)) : address(0);
    }

    function _assertSame(Snapshot memory a, Snapshot memory b) internal pure {
        assertEq(a.count, b.count, "marketCount");
        for (uint256 i; i < a.count; ++i) {
            assertEq(a.configs[i], b.configs[i], "getConfig");
            assertEq(a.states[i], b.states[i], "getState");
            assertEq(a.hedgeUnits[i], b.hedgeUnits[i], "hedgeUnits");
            assertEq(a.adapters[i], b.adapters[i], "route adapter");
            assertEq(a.fees[i], b.fees[i], "route fee");
        }
        assertEq(a.totalSupply, b.totalSupply, "totalSupply");
        assertEq(a.totalAssets, b.totalAssets, "totalAssets");
        assertEq(a.nav, b.nav, "navView");
        assertEq(a.vaultCash, b.vaultCash, "vault cash");
        assertEq(a.adminShares, b.adminShares, "admin shares");
        assertEq(a.adminLastDeposit, b.adminLastDeposit, "lastDeposit");
        assertEq(a.engineGlobals, b.engineGlobals, "engine globals");
        assertEq(a.vaultParams, b.vaultParams, "vault params");
        assertEq(a.roles, b.roles, "roles");
    }

    function _upgrade() internal returns (address engineImpl, address vaultImpl) {
        engineImpl = address(new PowerEngine());
        vaultImpl = address(new CrabVault());
        vm.startPrank(ADMIN);
        ENGINE.upgradeToAndCall(engineImpl, "");
        VAULT.upgradeToAndCall(vaultImpl, "");
        vm.stopPrank();
        assertEq(address(uint160(uint256(vm.load(address(ENGINE), IMPL_SLOT)))), engineImpl);
        assertEq(address(uint160(uint256(vm.load(address(VAULT), IMPL_SLOT)))), vaultImpl);
    }

    function testForkUpgradePreservesStateAndTrades() public {
        if (!forked) vm.skip(true);
        console2.log("fork block", block.number, "timestamp", block.timestamp);
        console2.log("engine impl before", address(uint160(uint256(vm.load(address(ENGINE), IMPL_SLOT)))));
        console2.log("vault impl before", address(uint160(uint256(vm.load(address(VAULT), IMPL_SLOT)))));
        Snapshot memory before = _snapshot();
        _upgrade();
        _assertSame(before, _snapshot());
        assertEq(address(ENGINE.marketHours()), MARKET_HOURS, "market hours unchanged");
        console2.log("upgrade: every getConfig/getState field, vault supply/NAV/params, roles preserved");
        console2.log("  markets", before.count, "CRAB supply", before.totalSupply);
        console2.log("  totalAssets (USDG wei)", before.totalAssets);

        ENGINE.accrueAll();
        for (uint8 i; i < before.count; ++i) {
            assertEq(ENGINE.getConfig(i).token.totalSupply(), ENGINE.getState(i).vaultShort, "supply != vaultShort");
            _logQuotes(i);
        }
        _rebalance(0, before.count); // live book as-is
        (address user, uint8 id) = _tradeRoundTrip(before.count);
        if (user != address(0)) _hedgedPosition(user, id);
    }

    /// Opens a position the keeper must hedge, rebalances through the real Uniswap route, closes the position, and
    /// rebalances back. Skipped gracefully when the route cannot fill within the vault's slippage limit.
    function _hedgedPosition(address user, uint8 id) internal {
        (,,, uint256 maxIn) = ENGINE.quoteBuy(id, 1e6);
        uint256 amount = maxIn * 9 / 10;
        if (amount < 1e6) return;
        this.dealUsdg(user, amount);
        vm.startPrank(user);
        USDG.approve(address(ENGINE), amount);
        uint256 tokens = ENGINE.buy(id, amount, 0, user, block.timestamp);
        vm.stopPrank();
        console2.log("opened position for hedge test, usdg", amount, "tokens", tokens);
        _rebalance(id, id + 1);
        vm.prank(user);
        uint256 out = ENGINE.sell(id, tokens, 0, user, block.timestamp);
        console2.log("closed position, usdg back", out);
        assertEq(ENGINE.getConfig(id).token.totalSupply(), ENGINE.getState(id).vaultShort);
        _rebalance(id, id + 1);
        assertGe(VAULT.navView(), 0, "vault solvent after hedged round trip");
    }

    function _logQuotes(uint8 id) internal view {
        MarketConfig memory c = ENGINE.getConfig(id);
        Regime regime = ENGINE.currentRegime(id);
        (uint256 spot,, bool valid) = ENGINE.spotPrice(id);
        uint256 fair = ENGINE.tokenPrice(id);
        console2.log(string.concat("market ", vm.toString(id), " ", PowerToken(address(c.token)).symbol()));
        console2.log("  regime", uint8(regime), "feed valid", valid);
        console2.log("  spot (WAD)", spot, "fair token price (WAD)", fair);
        try ENGINE.quoteBuy(id, 10e6) returns (uint256 out, uint256 fee, uint256 ask, uint256 maxIn) {
            assertGe(ask, fair, "ask below fair");
            console2.log("  quoteBuy(10 USDG): tokens", out, "fee", fee);
            console2.log("    ask", ask, "maxUsdgIn", maxIn);
        } catch {
            console2.log("  quoteBuy: closed (regime/staleness/stock pause)");
        }
        if (fair != 0) {
            (uint256 usdgOut, uint256 fee2, uint256 bid) = ENGINE.quoteSell(id, 1e36 / fair);
            assertLe(bid, fair, "bid above fair");
            console2.log("  quoteSell($1 of tokens): usdg", usdgOut, "fee", fee2);
            console2.log("    bid", bid);
        }
    }

    /// Funds a fresh account (via `deal`, else by borrowing the admin's USDG) and does a small buy then sell.
    function _tradeRoundTrip(uint8 count) internal returns (address, uint8) {
        address user = makeAddr("forkTrader");
        uint256 amount = 5e6;
        try this.dealUsdg(user, amount) {
            console2.log("deal() on USDG: works");
        } catch {
            console2.log("deal() on USDG: failed, borrowing from admin");
            vm.prank(ADMIN);
            require(USDG.transfer(user, amount), "admin transfer");
        }
        assertEq(USDG.balanceOf(user), amount);

        for (uint8 id; id < count; ++id) {
            vm.startPrank(user);
            USDG.approve(address(ENGINE), amount);
            try ENGINE.buy(id, amount, 0, user, block.timestamp) returns (uint256 tokens) {
                uint256 out = ENGINE.sell(id, tokens, 0, user, block.timestamp);
                vm.stopPrank();
                console2.log("buy/sell round trip on market", id);
                console2.log("  tokens", tokens, "usdg back", out);
                assertLe(out, amount, "round trip profit");
                assertEq(ENGINE.getConfig(id).token.totalSupply(), ENGINE.getState(id).vaultShort);
                return (user, id);
            } catch (bytes memory err) {
                vm.stopPrank();
                console2.log("buy closed on market", id);
                console2.logBytes(err);
            }
        }
        console2.log("no market open for buys at this block");
        return (address(0), 0);
    }

    function dealUsdg(address to, uint256 amount) external {
        deal(address(USDG), to, amount);
    }

    function _rebalance(uint8 from, uint8 to) internal {
        address keeper = KEEPER;
        if (!VAULT.hasRole(VAULT.KEEPER_ROLE(), keeper)) {
            // Keeper rotated since this test was written: grant a local stand-in (fork only).
            keeper = makeAddr("forkKeeper");
            bytes32 role = VAULT.KEEPER_ROLE();
            vm.prank(ADMIN);
            VAULT.grantRole(role, keeper);
        }
        for (uint8 id = from; id < to; ++id) {
            uint256 unitsBefore = VAULT.hedgeUnits(id);
            vm.prank(keeper);
            try VAULT.rebalance(id) returns (int256 delta) {
                console2.log("rebalance market", id);
                console2.logInt(delta);
                assertLe(VAULT.hedgeUnits(id), ENGINE.getConfig(id).stock.balanceOf(address(VAULT)), "phantom hedge");
                if (delta == 0) assertEq(VAULT.hedgeUnits(id), unitsBefore);
            } catch (bytes memory err) {
                console2.log("rebalance skipped (paused regime or no liquidity) on market", id);
                console2.logBytes(err);
            }
        }
    }

    /// Deploys the TWAP reference against the factory behind the hedge adapter's SwapRouter02 and reports what it
    /// returns per market (zero while a pool's observation cardinality cannot serve the window).
    function testForkTwapReferenceOnLivePools() public {
        if (!forked) vm.skip(true);
        address router = _adapterRouter();
        address factory = IRouterFactory(router).factory();
        console2.log("SwapRouter02", router);
        console2.log("UniswapV3Factory", factory);
        UniswapV3TwapReference ref =
            new UniswapV3TwapReference(IUniswapV3FactoryLike(factory), address(USDG), 30 minutes);
        uint8 count = ENGINE.marketCount();
        for (uint8 id; id < count; ++id) {
            MarketConfig memory c = ENGINE.getConfig(id);
            (, uint24 fee) = VAULT.routeForMarket(id);
            address pool = IUniswapV3FactoryPools(factory).getPool(address(c.stock), address(USDG), fee);
            uint256 twap = ref.referencePrice(address(c.stock), fee);
            (uint256 spot,,) = ENGINE.spotPrice(id);
            console2.log(string.concat("market ", vm.toString(id), " ", PowerToken(address(c.token)).symbol()));
            console2.log("  stock", address(c.stock), "fee", fee);
            console2.log("  pool", pool);
            if (pool != address(0)) {
                (, int24 tick,, uint16 card, uint16 cardNext,,) = IUniswapV3PoolSlot0(pool).slot0();
                console2.log("  observationCardinality", card, "next", cardNext);
                console2.logInt(tick);
            }
            console2.log("  referencePrice (WAD)", twap, "feed spot (WAD)", spot);
        }
    }

    /// SwapRouter02 is an immutable of the adapter: find the PUSH32 constant in its runtime code that answers
    /// factory().
    function _adapterRouter() internal view returns (address) {
        bytes memory code = ADAPTER.code;
        for (uint256 i; i + 33 <= code.length; ++i) {
            if (uint8(code[i]) != 0x7f) continue;
            bool padded = true;
            for (uint256 k = 1; k <= 12; ++k) {
                if (code[i + k] != 0) {
                    padded = false;
                    break;
                }
            }
            if (!padded) continue;
            uint160 word;
            for (uint256 k = 13; k <= 32; ++k) {
                word = (word << 8) | uint160(uint8(code[i + k]));
            }
            address candidate = address(word);
            if (candidate.code.length == 0) continue;
            (bool ok, bytes memory ret) = candidate.staticcall(abi.encodeCall(IRouterFactory.factory, ()));
            if (ok && ret.length == 32) return candidate;
        }
        revert("router not found");
    }
}
