// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICrabVault} from "./interfaces/ICrabVault.sol";
import {IHedgeAdapter} from "./interfaces/IHedgeAdapter.sol";
import {IPowerEngine} from "./interfaces/IPowerEngine.sol";
import {MarketConfig, MarketState, Regime} from "./libs/OgeeTypes.sol";
import {Roles} from "./libs/Roles.sol";

/// @title CrabVault
/// @notice ERC-4626 vault whose share value tracks cash, stock hedges, and engine liabilities.
contract CrabVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable,
    ICrabVault
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant USDG_TO_WAD = 1e12;
    uint256 private constant STOCK_VALUE_DENOMINATOR = 1e30;
    uint256 private constant MAX_LOCK_SECONDS = 30 days;

    bytes32 public constant override KEEPER_ROLE = Roles.KEEPER_ROLE;

    IERC20 public usdg;
    IPowerEngine public override engine;

    bool public override publicDeposits;
    uint32 public override lockSeconds;
    uint16 public override cashBufferBps;
    uint16 public override hedgeRatioBps;
    uint16 public override rebalanceThresholdBps;
    uint16 public override maxHedgeSlippageBps;
    uint128 public override minHedgeTradeUsdg;
    uint128 public override maxTotalDeposits;

    mapping(address account => bool allowed) private _depositors;
    mapping(address account => uint256 timestamp) public lastDeposit;
    mapping(uint8 id => uint256 units) private _hedgeUnits;
    mapping(uint8 id => IHedgeAdapter adapter) private _hedgeAdapters;
    mapping(uint8 id => uint24 fee) private _poolFees;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the USDG vault and grants its admin and keeper roles.
    function initialize(address admin, IERC20 usdg_, IPowerEngine engine_) external override initializer {
        if (admin == address(0)) revert InvalidAdmin();
        if (address(engine_) == address(0)) revert InvalidEngine();
        if (address(usdg_) == address(0)) revert InvalidParams();

        __ERC20_init("Ogee Crab Vault", "CRAB");
        __ERC4626_init(usdg_);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        usdg = usdg_;
        engine = engine_;
        lockSeconds = 1 days;
        cashBufferBps = 1_000;
        hedgeRatioBps = 10_000;
        rebalanceThresholdBps = 1_000;
        maxHedgeSlippageBps = 100;
        minHedgeTradeUsdg = 2e6;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
    }

    /// @notice Returns signed NAV in WAD USD.
    function navView() external view override returns (int256 navWad) {
        return _navView();
    }

    /// @notice Returns positive NAV in USDG base units, or zero when NAV is non-positive.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        int256 nav = _navView();
        return nav > 0 ? uint256(nav) / USDG_TO_WAD : 0;
    }

    /// @notice Returns the current NAV per CRAB share in WAD.
    function navPerShareWad() external view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        int256 nav = _navView();
        if (nav <= 0) return 0;
        return Math.mulDiv(uint256(nav), 1e12, supply);
    }

    /// @notice Enables or disables an account's deposits.
    function setDepositor(address account, bool allowed) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (account == address(0)) revert InvalidParams();
        _depositors[account] = allowed;
        emit DepositorUpdated(account, allowed);
    }

    /// @notice Enables or disables deposits for all accounts.
    function setPublicDeposits(bool enabled) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        publicDeposits = enabled;
        emit PublicDepositsUpdated(enabled);
    }

    /// @notice Updates lock, cash, hedge, trade, and deposit-cap parameters.
    function setParams(
        uint32 lockSeconds_,
        uint16 cashBufferBps_,
        uint16 hedgeRatioBps_,
        uint16 rebalanceThresholdBps_,
        uint16 maxHedgeSlippageBps_,
        uint128 minHedgeTradeUsdg_,
        uint128 maxTotalDeposits_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (
            lockSeconds_ > MAX_LOCK_SECONDS || cashBufferBps_ > 5_000 || hedgeRatioBps_ > 15_000
                || rebalanceThresholdBps_ > BPS || maxHedgeSlippageBps_ > 500
        ) revert InvalidParams();

        lockSeconds = lockSeconds_;
        cashBufferBps = cashBufferBps_;
        hedgeRatioBps = hedgeRatioBps_;
        rebalanceThresholdBps = rebalanceThresholdBps_;
        maxHedgeSlippageBps = maxHedgeSlippageBps_;
        minHedgeTradeUsdg = minHedgeTradeUsdg_;
        maxTotalDeposits = maxTotalDeposits_;
        emit ParamsUpdated(
            lockSeconds_,
            cashBufferBps_,
            hedgeRatioBps_,
            rebalanceThresholdBps_,
            maxHedgeSlippageBps_,
            minHedgeTradeUsdg_,
            maxTotalDeposits_
        );
    }

    /// @notice Configures the adapter and pool fee for a listed market.
    function setHedgeRoute(uint8 id, IHedgeAdapter adapter, uint24 poolFee)
        external
        override
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (
            id >= engine.marketCount() || address(adapter) == address(0) || address(adapter).code.length == 0
                || poolFee == 0
        ) revert InvalidRoute();
        _hedgeAdapters[id] = adapter;
        _poolFees[id] = poolFee;
        emit HedgeRouteUpdated(id, address(adapter), poolFee);
    }

    /// @notice Returns whether an account may deposit.
    function isDepositor(address account) public view override returns (bool) {
        return _depositors[account];
    }

    /// @notice Returns an account's most recent deposit time plus the current lock duration.
    function unlockTime(address account) public view override returns (uint256) {
        uint256 depositedAt = lastDeposit[account];
        return depositedAt == 0 ? 0 : depositedAt + lockSeconds;
    }

    /// @notice Returns the adapter and fee configured for a market.
    function routeForMarket(uint8 id) external view override returns (IHedgeAdapter adapter, uint24 poolFee) {
        return (_hedgeAdapters[id], _poolFees[id]);
    }

    /// @notice Returns the tracked hedge units for a market.
    function hedgeUnits(uint8 id) external view override returns (uint256) {
        return _hedgeUnits[id];
    }

    /// @notice Returns the USDG deposit capacity for an eligible receiver.
    function maxDeposit(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (receiver == address(0) || receiver == address(this) || (!publicDeposits && !_depositors[receiver])) {
            return 0;
        }
        if (maxTotalDeposits == 0) return 0;

        int256 nav = _navView();
        bool emptyBootstrap = totalSupply() == 0 && engine.totalLiability() == 0;
        if (nav <= 0 && !emptyBootstrap) return 0;

        uint256 assets = totalAssets();
        if (assets >= maxTotalDeposits) return 0;
        return uint256(maxTotalDeposits) - assets;
    }

    /// @notice Returns a conservative share amount for minting under the current cap.
    function maxMint(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _convertToShares(maxDeposit(receiver), Math.Rounding.Floor);
    }

    /// @notice Returns zero while locked, otherwise the lesser of share value and safe withdrawable NAV.
    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (unlockTime(owner) > block.timestamp) return 0;
        uint256 assetsFromShares = _convertToAssets(balanceOf(owner), Math.Rounding.Floor);
        uint256 assetsAvailable = _withdrawalLimit();
        return assetsFromShares < assetsAvailable ? assetsFromShares : assetsAvailable;
    }

    /// @notice Returns a conservative share amount that keeps post-withdraw NAV above the liability reserve.
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        if (unlockTime(owner) > block.timestamp) return 0;
        uint256 shares = balanceOf(owner);
        uint256 sharesWithinReserve = _convertToShares(_withdrawalLimit(), Math.Rounding.Floor);
        return shares < sharesWithinReserve ? shares : sharesWithinReserve;
    }

    /// @notice Deposits USDG and records the receiver's lock start.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.deposit(assets, receiver);
    }

    /// @notice Mints CRAB shares with the same eligibility and lock rules as deposits.
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.mint(shares, receiver);
    }

    /// @notice Withdraws USDG after raising cash from configured hedge routes if needed.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.withdraw(assets, receiver, owner);
    }

    /// @notice Redeems CRAB shares after raising cash from configured hedge routes if needed.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256)
    {
        return super.redeem(shares, receiver, owner);
    }

    /// @notice Pays USDG to the engine after selling configured hedges when necessary.
    function pay(address to, uint256 usdgAmount, uint8 preferMarket) external override nonReentrant {
        if (msg.sender != address(engine)) revert NotEngine();
        if (to == address(0)) revert InvalidParams();
        _ensureCash(usdgAmount, preferMarket);
        usdg.safeTransfer(to, usdgAmount);
    }

    /// @notice Rebalances a market's tracked hedge toward the engine's current delta target.
    function rebalance(uint8 id) external override onlyRole(KEEPER_ROLE) nonReentrant returns (int256 unitsDelta) {
        _requireMarket(id);
        if (engine.currentRegime(id) == Regime.PAUSED) revert RegimePaused();

        uint256 price = _marketPrice(id);
        if (price == 0) revert InsufficientLiquidity();
        uint256 target = Math.mulDiv(engine.hedgeDelta(id), hedgeRatioBps, BPS);
        uint256 current = _hedgeUnits[id];
        if (target == current) return 0;

        bool buy = target > current;
        uint256 difference = buy ? target - current : current - target;
        uint256 tradeValue = Math.mulDiv(difference, price, STOCK_VALUE_DENOMINATOR);
        if (tradeValue < minHedgeTradeUsdg) return 0;
        if (target != 0 && Math.mulDiv(difference, BPS, target) < rebalanceThresholdBps) return 0;

        MarketConfig memory config = engine.getConfig(id);
        IHedgeAdapter adapter = _hedgeAdapters[id];
        if (address(adapter) == address(0)) revert InvalidRoute();

        if (buy) {
            uint256 desiredAssets = Math.mulDiv(difference, price, STOCK_VALUE_DENOMINATOR, Math.Rounding.Ceil);
            uint256 cash = usdg.balanceOf(address(this));
            uint256 buffer = Math.mulDiv(totalAssets(), cashBufferBps, BPS);
            uint256 available = cash > buffer ? cash - buffer : 0;
            uint256 amountIn = desiredAssets < available ? desiredAssets : available;
            if (amountIn < minHedgeTradeUsdg) return 0;

            uint256 minOut = _minStockOut(amountIn, price);
            (uint256 spent, uint256 received) =
                _swap(id, adapter, address(usdg), address(config.stock), _poolFees[id], amountIn, minOut);
            _hedgeUnits[id] += received;
            unitsDelta = _toInt(received);
            emit Hedged(id, true, spent, received, _hedgeUnits[id]);
        } else {
            uint256 amountIn = difference;
            uint256 minOut = _minUsdgOut(amountIn, price);
            (uint256 sold, uint256 received) =
                _swap(id, adapter, address(config.stock), address(usdg), _poolFees[id], amountIn, minOut);
            if (sold > current) revert InsufficientLiquidity();
            _hedgeUnits[id] = current - sold;
            unitsDelta = -_toInt(sold);
            emit Hedged(id, false, sold, received, _hedgeUnits[id]);
        }
    }

    /// @notice Resets the tracked hedge to the vault's actual stock-token balance.
    function syncHedgeUnits(uint8 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireMarket(id);
        MarketConfig memory config = engine.getConfig(id);
        uint256 units = config.stock.balanceOf(address(this));
        _hedgeUnits[id] = units;
        emit HedgeUnitsSynced(id, units);
    }

    /// @dev USDG and CRAB are 6 and 12 decimals respectively.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev A deposit must be self-received so a third party cannot restart another holder's lock.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (caller != receiver || !_canDeposit(receiver)) revert InvalidParams();
        uint256 allowed = maxDeposit(receiver);
        if (assets > allowed) revert ERC4626ExceededMaxDeposit(receiver, assets, allowed);
        super._deposit(caller, receiver, assets, shares);
        lastDeposit[receiver] = block.timestamp;
    }

    /// @dev Shares cannot be burned before their owner's latest deposit lock expires.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        if (unlockTime(owner) > block.timestamp) revert WithdrawalLocked();
        if (caller != owner) _spendAllowance(owner, caller, shares);
        _ensureCash(assets, 0);
        if (assets > _withdrawableAssets()) revert InsufficientLiquidity();
        _burn(owner, shares);
        usdg.safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    /// @dev A transfer carries the sender's remaining lock forward to the recipient. Locked shares may only move to
    /// an empty account, so a locked holder cannot extend an existing holder's lock by sending dust.
    function _update(address from, address to, uint256 value) internal override(ERC20Upgradeable) {
        bool propagate = from != address(0) && to != address(0) && from != to && value != 0;
        uint256 senderUnlock = propagate ? unlockTime(from) : 0;
        if (senderUnlock > block.timestamp && balanceOf(to) != 0) revert WithdrawalLocked();

        super._update(from, to, value);
        if (senderUnlock <= block.timestamp) return;
        uint256 receiverUnlock = unlockTime(to);
        if (senderUnlock > receiverUnlock) lastDeposit[to] = senderUnlock - lockSeconds;
    }

    function _navView() private view returns (int256) {
        uint256 grossWad = usdg.balanceOf(address(this)) * USDG_TO_WAD;
        uint256 count = engine.marketCount();
        for (uint256 i; i < count; ++i) {
            uint8 id = uint8(i);
            uint256 units = _hedgeUnits[id];
            if (units != 0) {
                uint256 spot = _marketPrice(id);
                grossWad += Math.mulDiv(units, spot, 1e18);
            }
        }

        uint256 liabilityWad = engine.totalLiability();
        if (grossWad >= liabilityWad) return _toInt(grossWad - liabilityWad);
        return -_toInt(liabilityWad - grossWad);
    }

    function _marketPrice(uint8 id) private view returns (uint256 price) {
        MarketState memory state = engine.getState(id);
        if (engine.currentRegime(id) == Regime.PAUSED) return state.lastGoodPrice;
        bool valid;
        (price,, valid) = engine.spotPrice(id);
        if (!valid) price = state.lastGoodPrice;
    }

    function _withdrawableAssets() private view returns (uint256) {
        uint256 assets = totalAssets();
        uint256 liabilities = engine.totalLiability();
        if (liabilities == 0) return assets;

        uint256 exposureBps = engine.maxGlobalExposureBps();
        if (exposureBps == 0) return 0;
        uint256 required = Math.mulDiv(liabilities, BPS, exposureBps * USDG_TO_WAD, Math.Rounding.Ceil);
        return assets > required ? assets - required : 0;
    }

    function _withdrawalLimit() private view returns (uint256 limit) {
        uint256 headroom = _withdrawableAssets();
        uint256 cash = usdg.balanceOf(address(this));
        if (headroom == 0) return 0;

        uint256 conservativeLimit = headroom;
        if (headroom > cash) {
            conservativeLimit = cash + Math.mulDiv(headroom - cash, BPS - maxHedgeSlippageBps, BPS);
        }

        uint256 liquidAssets = cash;
        uint256 count = engine.marketCount();
        for (uint256 i; i < count; ++i) {
            uint8 id = uint8(i);
            uint256 units = _hedgeUnits[id];
            if (units == 0 || address(_hedgeAdapters[id]) == address(0)) continue;
            uint256 price = _marketPrice(id);
            if (price != 0) liquidAssets += _minUsdgOut(units, price);
        }

        return conservativeLimit < liquidAssets ? conservativeLimit : liquidAssets;
    }

    function _ensureCash(uint256 amount, uint8 preferMarket) private {
        uint256 count = engine.marketCount();
        for (uint256 step; usdg.balanceOf(address(this)) < amount && step <= count; ++step) {
            uint8 id;
            if (step == 0) {
                id = preferMarket;
            } else {
                uint256 candidate = step - 1;
                if (candidate == preferMarket || candidate >= count) continue;
                id = uint8(candidate);
            }

            if (id >= count || _hedgeUnits[id] == 0) continue;
            uint256 price = _marketPrice(id);
            if (price == 0) continue;

            uint256 shortfall = amount - usdg.balanceOf(address(this));
            uint256 grossUnitsNeeded = Math.mulDiv(shortfall, STOCK_VALUE_DENOMINATOR, price, Math.Rounding.Ceil);
            uint256 unitsNeeded = Math.mulDiv(grossUnitsNeeded, BPS, BPS - maxHedgeSlippageBps, Math.Rounding.Ceil);
            uint256 unitsToSell = unitsNeeded < _hedgeUnits[id] ? unitsNeeded : _hedgeUnits[id];
            if (unitsToSell == 0) continue;

            MarketConfig memory config = engine.getConfig(id);
            IHedgeAdapter adapter = _hedgeAdapters[id];
            if (address(adapter) == address(0)) continue;
            uint256 minOut = _minUsdgOut(unitsToSell, price);
            // One failing route (paused stock, drained pool) must not block payments other hedges can cover.
            (bool ok, uint256 sold, uint256 received) =
                _trySwap(adapter, address(config.stock), address(usdg), _poolFees[id], unitsToSell, minOut);
            if (!ok) continue;
            if (sold > _hedgeUnits[id]) revert InsufficientLiquidity();
            _hedgeUnits[id] -= sold;
            emit CashRaised(id, sold, received);
        }

        if (usdg.balanceOf(address(this)) < amount) revert InsufficientLiquidity();
    }

    function _swap(
        uint8,
        IHedgeAdapter adapter,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) private returns (uint256 actualIn, uint256 actualOut) {
        IERC20 input = IERC20(tokenIn);
        IERC20 output = IERC20(tokenOut);
        uint256 inputBefore = input.balanceOf(address(this));
        uint256 outputBefore = output.balanceOf(address(this));

        input.forceApprove(address(adapter), amountIn);
        uint256 reportedOut = adapter.swapExactIn(tokenIn, tokenOut, fee, amountIn, minOut, address(this));
        input.forceApprove(address(adapter), 0);
        (actualIn, actualOut) = _checkSwap(input, output, inputBefore, outputBefore, amountIn, minOut, reportedOut);
    }

    function _trySwap(
        IHedgeAdapter adapter,
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint256 minOut
    ) private returns (bool ok, uint256 actualIn, uint256 actualOut) {
        IERC20 input = IERC20(tokenIn);
        IERC20 output = IERC20(tokenOut);
        uint256 inputBefore = input.balanceOf(address(this));
        uint256 outputBefore = output.balanceOf(address(this));

        input.forceApprove(address(adapter), amountIn);
        try adapter.swapExactIn(tokenIn, tokenOut, fee, amountIn, minOut, address(this)) returns (uint256 reportedOut) {
            input.forceApprove(address(adapter), 0);
            (actualIn, actualOut) =
                _checkSwap(input, output, inputBefore, outputBefore, amountIn, minOut, reportedOut);
            ok = true;
        } catch {
            input.forceApprove(address(adapter), 0);
        }
    }

    function _checkSwap(
        IERC20 input,
        IERC20 output,
        uint256 inputBefore,
        uint256 outputBefore,
        uint256 amountIn,
        uint256 minOut,
        uint256 reportedOut
    ) private view returns (uint256 actualIn, uint256 actualOut) {
        uint256 inputAfter = input.balanceOf(address(this));
        uint256 outputAfter = output.balanceOf(address(this));
        if (inputAfter > inputBefore || outputAfter < outputBefore) revert InsufficientLiquidity();
        actualIn = inputBefore - inputAfter;
        actualOut = outputAfter - outputBefore;
        if (actualIn != amountIn || reportedOut < minOut || actualOut < minOut) revert InsufficientLiquidity();
    }

    function _minStockOut(uint256 usdgAmount, uint256 price) private view returns (uint256) {
        uint256 grossUnits = Math.mulDiv(usdgAmount, STOCK_VALUE_DENOMINATOR, price);
        return Math.mulDiv(grossUnits, BPS - maxHedgeSlippageBps, BPS);
    }

    function _minUsdgOut(uint256 stockUnits, uint256 price) private view returns (uint256) {
        uint256 grossUsdg = Math.mulDiv(stockUnits, price, STOCK_VALUE_DENOMINATOR);
        return Math.mulDiv(grossUsdg, BPS - maxHedgeSlippageBps, BPS);
    }

    function _canDeposit(address receiver) private view returns (bool) {
        return receiver != address(0) && receiver != address(this) && (publicDeposits || _depositors[receiver]);
    }

    function _requireMarket(uint8 id) private view {
        if (id >= engine.marketCount()) revert InvalidMarketId();
    }

    function _toInt(uint256 value) private pure returns (int256) {
        if (value > uint256(type(int256).max)) revert InvalidParams();
        return int256(value);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[40] private __gap;
}
