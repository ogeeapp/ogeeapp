// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketConfig} from "./libs/OgeeTypes.sol";

/// @notice Admin validation and view-only math moved out of PowerEngine to keep it under the EIP-170 size limit.
/// @dev Deployed by the engine's constructor. Reverts use the same selectors as IPowerEngine, so callers see the
/// engine's errors. Nothing here runs on the buy/sell execution path.
contract EngineHelper {
    uint256 private constant BPS = 10_000;
    uint256 private constant PAUSED_BAND_BPS = 300;

    error InvalidMarketConfig();
    error CarryChangeTooFast();

    /// @notice Reverts unless `next` is within 25% of the current base carry (or of `maxWad` when current is zero).
    function checkBaseCarryStep(int64 current, int64 next, int64 maxWad) external pure {
        uint256 difference = uint256(next >= current ? int256(next) - current : int256(current) - next);
        // A zero base carry would otherwise allow no step at all; measure from the upper bound instead.
        uint256 stepBase = current > 0 ? uint256(int256(current)) : uint256(int256(maxWad));
        if (difference > stepBase * 2_500 / BPS) revert CarryChangeTooFast();
    }

    /// @notice Gross USDG input whose post-fee, post-spread notional fills `roomUsdg` of liability capacity.
    function grossInputForRoom(
        uint256 roomUsdg,
        uint256 capacityUsdg,
        uint256 feeBps,
        uint256 impactBpsConfig,
        uint256 spreadBps,
        uint256 bandBps
    ) external pure returns (uint256 grossUsdg) {
        if (roomUsdg == 0) return 0;
        uint256 feeFactor = BPS - feeBps;
        uint256 impactRoomBps = capacityUsdg == 0 ? bandBps : Math.mulDiv(roomUsdg, impactBpsConfig, capacityUsdg);
        uint256 denominator = impactRoomBps < feeFactor ? feeFactor - impactRoomBps : 0;
        if (denominator == 0) {
            return Math.mulDiv(roomUsdg, BPS + bandBps, feeFactor);
        }

        grossUsdg = Math.mulDiv(roomUsdg, BPS + spreadBps, denominator);
        uint256 impactBps = capacityUsdg == 0 ? bandBps : Math.mulDiv(impactBpsConfig, grossUsdg, capacityUsdg);
        if (spreadBps + impactBps > bandBps) {
            grossUsdg = Math.mulDiv(roomUsdg, BPS + bandBps, feeFactor);
        }
    }

    function validate(MarketConfig calldata config) external view {
        if (
            address(config.stock) == address(0) || address(config.feed) == address(0) || config.scale == 0
                || config.kind != 0 || config.feed2 != address(0) || config.maxMarketExposureBps == 0
                || config.maxMarketExposureBps > BPS || config.feeBps > 100 || config.impactBps > 1_000
                || config.openSpreadBps > config.openBandBps || config.openBandBps > 1_000
                || config.offHoursSpreadBps > config.offHoursBandBps || config.offHoursBandBps > 1_000
                || config.pausedSpreadBps > PAUSED_BAND_BPS || config.minTradeUsdg == 0
                || config.maxTradeUsdg < config.minTradeUsdg || config.pausedSellCapPerBlockUsdg == 0
                || config.maxAgeOpen == 0 || config.maxAgeOffHours == 0 || config.minCarryWad < 0
                || config.offHoursCarryWad < 0 || config.skewCarryWad < 0 || config.maxCarryWad < config.minCarryWad
                || config.baseCarryMinWad < 0 || config.baseCarryMaxWad < config.baseCarryMinWad
        ) revert InvalidMarketConfig();

        uint8 feedDecimals;
        uint8 stockDecimals;
        try config.feed.decimals() returns (uint8 decimals_) {
            feedDecimals = decimals_;
        } catch {
            revert InvalidMarketConfig();
        }
        try config.stock.decimals() returns (uint8 decimals_) {
            stockDecimals = decimals_;
        } catch {
            revert InvalidMarketConfig();
        }
        if (feedDecimals != 8 || stockDecimals != 18) revert InvalidMarketConfig();
    }
}
