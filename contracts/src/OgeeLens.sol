// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ICrabVault} from "./interfaces/ICrabVault.sol";
import {IOgeeLens} from "./interfaces/IOgeeLens.sol";
import {IPowerEngine} from "./interfaces/IPowerEngine.sol";
import {MarketConfig, MarketState, MarketView, VaultView, AccountView} from "./libs/OgeeTypes.sol";
import {PowerToken} from "./PowerToken.sol";

/// @title OgeeLens
/// @notice Stateless batched views for markets, the vault, and one account.
contract OgeeLens is IOgeeLens {
    uint256 private constant BPS = 10_000;
    uint256 private constant USDG_UNIT = 1e6;

    /// @notice Returns all listed markets and their current engine, hedge, and quote state.
    function markets(IPowerEngine engine) external view override returns (MarketView[] memory result) {
        uint256 count = engine.marketCount();
        result = new MarketView[](count);
        ICrabVault crab = engine.vault();

        for (uint256 i; i < count; ++i) {
            uint8 id = uint8(i);
            MarketConfig memory config = engine.getConfig(id);
            MarketState memory state = engine.getState(id);
            (uint256 spot, uint256 spotUpdatedAt, bool oracleValid) = engine.spotPrice(id);
            uint8 regime = uint8(engine.currentRegime(id));
            if (regime == 2 || !oracleValid || spot == 0) {
                spot = state.lastGoodPrice;
                spotUpdatedAt = state.lastGoodAt;
            }
            uint256 hedgeTarget = Math.mulDiv(engine.hedgeDelta(id), crab.hedgeRatioBps(), BPS);
            (uint256 bidPrice, uint256 askPrice, uint256 capacityUsdg) = _oneUsdQuotes(engine, id);

            result[i] = MarketView({
                id: id,
                token: address(config.token),
                stock: address(config.stock),
                symbol: PowerToken(address(config.token)).symbol(),
                scale: config.scale,
                regime: regime,
                buysPaused: state.buysPaused || engine.globalBuysPaused(),
                spot: spot,
                spotUpdatedAt: spotUpdatedAt,
                index: engine.index(id),
                normFactor: engine.currentNormFactor(id),
                price: engine.tokenPrice(id),
                carryWad: engine.currentCarryWad(id),
                vaultShort: state.vaultShort,
                liability: engine.liability(id),
                capacityUsdg: capacityUsdg,
                hedgeUnits: crab.hedgeUnits(id),
                hedgeTarget: hedgeTarget,
                bidPrice1: bidPrice,
                askPrice1: askPrice,
                multiplier: config.stock.uiMultiplier(),
                pendingMultiplier: config.stock.newUIMultiplier(),
                multiplierEffectiveAt: config.stock.effectiveAt(),
                oraclePaused: config.stock.oraclePaused()
            });
        }
    }

    /// @notice Returns current vault NAV, supply, balances, and global liability settings.
    function vault(IPowerEngine engine) external view override returns (VaultView memory result) {
        ICrabVault crab = engine.vault();
        int256 nav = crab.navView();
        result = VaultView({
            nav: nav,
            totalAssets: crab.totalAssets(),
            totalSupply: crab.totalSupply(),
            navPerShare: crab.navPerShareWad(),
            usdgBalance: engine.usdg().balanceOf(address(crab)),
            totalLiability: engine.totalLiability(),
            maxGlobalExposureBps: engine.maxGlobalExposureBps(),
            publicDeposits: crab.publicDeposits()
        });
    }

    /// @notice Returns one account's token balances, allowances, vault shares, and lock time.
    function account(IPowerEngine engine, address user) external view override returns (AccountView memory result) {
        ICrabVault crab = engine.vault();
        IERC20 usdg = engine.usdg();
        uint256 count = engine.marketCount();
        uint256[] memory powerBalances = new uint256[](count);

        for (uint256 i; i < count; ++i) {
            MarketConfig memory config = engine.getConfig(uint8(i));
            powerBalances[i] = config.token.balanceOf(user);
        }

        uint256 crabShares = crab.balanceOf(user);
        result = AccountView({
            user: user,
            usdgBalance: usdg.balanceOf(user),
            usdgAllowanceEngine: usdg.allowance(user, address(engine)),
            usdgAllowanceVault: usdg.allowance(user, address(crab)),
            powerBalances: powerBalances,
            crabShares: crabShares,
            crabValue: crab.convertToAssets(crabShares),
            unlockTime: crab.unlockTime(user),
            isDepositor: crab.isDepositor(user)
        });
    }

    function _oneUsdQuotes(IPowerEngine engine, uint8 id)
        private
        view
        returns (uint256 bidPrice, uint256 askPrice, uint256 capacityUsdg)
    {
        try engine.quoteBuy(id, USDG_UNIT) returns (
            uint256, uint256, uint256 ask, uint256 maxUsdgIn
        ) {
            askPrice = ask;
            capacityUsdg = maxUsdgIn;
        } catch {
            askPrice = 0;
            capacityUsdg = 0;
        }

        uint256 fairPrice = engine.tokenPrice(id);
        if (fairPrice != 0) {
            uint256 tokensForOneUsd = Math.mulDiv(1e18, 1e18, fairPrice);
            try engine.quoteSell(id, tokensForOneUsd) returns (uint256, uint256, uint256 bid) {
                bidPrice = bid;
            } catch {
                bidPrice = 0;
            }
        }
    }
}
