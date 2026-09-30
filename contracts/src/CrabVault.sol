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
import {ReentrancyGuardTransientUpgradeable} from
    "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICrabVault} from "./interfaces/ICrabVault.sol";
import {IHedgeAdapter} from "./interfaces/IHedgeAdapter.sol";
import {IPowerEngine} from "./interfaces/IPowerEngine.sol";
import {Regime, ValuationMark} from "./libs/OgeeTypes.sol";
import {Roles} from "./libs/Roles.sol";

/// @title CrabVault
/// @notice ERC-4626 vault whose share value tracks cash, stock hedges, and engine liabilities.
/// @dev Entry points fetch one engine valuation and derive NAV, the NAV guard band, and limits from it.
/// Deposits price shares at the high edge of the band and exits at the low edge, so a holder who can predict the
/// next oracle update cannot enter or exit at a stale NAV. The band is the NAV change from an adverse feed move of
/// `navGuardOpenBps` (open market) or `navGuardClosedBps` (off-hours or paused) in every market, including the
/// hedged delta and the short-gamma term, so a fully hedged vault pays only the gamma component.
contract CrabVault is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardTransientUpgradeable,
    UUPSUpgradeable,
    ICrabVault
{
    using Math for uint256;
    using SafeERC20 for IERC20;

    uint256 private constant BPS = 10_000;
    uint256 private constant USDG_TO_WAD = 1e12;
    uint256 private constant STOCK_VALUE_DENOMINATOR = 1e30;
    uint256 private constant MAX_LOCK_SECONDS = 30 days;
    uint256 private constant MAX_NAV_GUARD_BPS = 2_000;

    bytes32 public constant override KEEPER_ROLE = Roles.KEEPER_ROLE;

    struct Valuation {
        uint256 cash;
        uint256 liability;
        int256 nav;
        int256 navLow;
        int256 navHigh;
        ValuationMark[] marks;
    }

    IERC20 public usdg;
    IPowerEngine public override engine;

    bool public override publicDeposits;
    uint32 public override lockSeconds;
    uint16 public override cashBufferBps;
    uint16 public override hedgeRatioBps;
    uint16 public override rebalanceThresholdBps;
    uint16 public override maxHedgeSlippageBps;
    uint16 public override navGuardOpenBps;
    uint16 public override navGuardClosedBps;
    uint128 public override minHedgeTradeUsdg;
    uint128 public override maxTotalDeposits;

    mapping(address account => bool allowed) private _depositors;
    mapping(address account => uint256 timestamp) public lastDeposit;
    mapping(uint8 id => uint256 units) private _hedgeUnits;
    mapping(uint8 id => IHedgeAdapter adapter) private _hedgeAdapters;
    mapping(uint8 id => uint24 fee) private _poolFees;
    mapping(uint8 id => address stock) private _stocks;

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
        __ReentrancyGuardTransient_init();
        __UUPSUpgradeable_init();

        usdg = usdg_;
        engine = engine_;
        lockSeconds = 1 days;
        cashBufferBps = 1_000;
        hedgeRatioBps = 10_000;
        rebalanceThresholdBps = 1_000;
        maxHedgeSlippageBps = 100;
        navGuardOpenBps = 50;
        navGuardClosedBps = 300;
        minHedgeTradeUsdg = 2e6;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(KEEPER_ROLE, admin);
    }

    /// @notice Returns signed NAV in WAD USD.
    function navView() external view override returns (int256 navWad) {
        return _valuation().nav;
    }

    /// @notice Returns mid NAV plus the low (exit) and high (entry) edges of the NAV guard band, all in WAD USD.
    function navBand() external view override returns (int256 navWad, int256 lowWad, int256 highWad) {
        Valuation memory v = _valuation();
        return (v.nav, v.navLow, v.navHigh);
    }

    /// @notice Returns NAV in WAD for engine-supplied liabilities and regime spots, without calling the engine.
    function navFor(uint256 liabilityWad, uint256[] memory spots) external view override returns (int256) {
        return _navFrom(usdg.balanceOf(address(this)), liabilityWad, spots);
    }

    /// @notice Returns positive mid NAV in USDG base units, or zero when NAV is non-positive.
    function totalAssets() public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _assetsOf(_valuation().nav);
    }

    /// @notice Returns the current mid NAV per CRAB share in WAD.
    function navPerShareWad() external view override returns (uint256) {
        uint256 supply = totalSupply();
        if (supply == 0) return 1e18;
        int256 nav = _valuation().nav;
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

    /// @notice Sets the assumed adverse feed move used to price entries and exits, per regime.
    function setNavGuard(uint16 openBps, uint16 closedBps) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (openBps > MAX_NAV_GUARD_BPS || closedBps > MAX_NAV_GUARD_BPS) revert InvalidParams();
        navGuardOpenBps = openBps;
        navGuardClosedBps = closedBps;
        emit NavGuardUpdated(openBps, closedBps);
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
        _stocks[id] = address(engine.getConfig(id).stock);
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
        return _maxDeposit(receiver, _valuation());
    }

    /// @notice Returns a conservative share amount for minting under the current cap.
    function maxMint(address receiver) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        Valuation memory v = _valuation();
        return _toShares(_maxDeposit(receiver, v), v.navHigh, Math.Rounding.Floor);
    }

    /// @notice Returns zero while locked, otherwise the lesser of guarded share value and safe withdrawable NAV.
    function maxWithdraw(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _maxWithdraw(owner, _valuation());
    }

    /// @notice Returns a conservative share amount that keeps post-withdraw NAV above the liability reserve.
    function maxRedeem(address owner) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _maxRedeem(owner, _valuation());
    }

    /// @notice Shares for `assets` at the high (entry) edge of the NAV guard band.
    function previewDeposit(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _toShares(assets, _valuation().navHigh, Math.Rounding.Floor);
    }

    /// @notice Assets for `shares` at the high (entry) edge of the NAV guard band.
    function previewMint(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _toAssets(shares, _valuation().navHigh, Math.Rounding.Ceil);
    }

    /// @notice Shares burned for `assets` at the low (exit) edge of the NAV guard band.
    function previewWithdraw(uint256 assets) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _toShares(assets, _valuation().navLow, Math.Rounding.Ceil);
    }

    /// @notice Assets for `shares` at the low (exit) edge of the NAV guard band.
    function previewRedeem(uint256 shares) public view override(ERC4626Upgradeable, IERC4626) returns (uint256) {
        return _toAssets(shares, _valuation().navLow, Math.Rounding.Floor);
    }

    /// @notice Deposits USDG and records the receiver's lock start.
    function deposit(uint256 assets, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        Valuation memory v = _valuation();
        uint256 maxAssets = _maxDeposit(receiver, v);
        if (assets > maxAssets) revert ERC4626ExceededMaxDeposit(receiver, assets, maxAssets);
        shares = _toShares(assets, v.navHigh, Math.Rounding.Floor);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @notice Mints CRAB shares with the same eligibility and lock rules as deposits.
    function mint(uint256 shares, address receiver)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        Valuation memory v = _valuation();
        uint256 maxShares = _toShares(_maxDeposit(receiver, v), v.navHigh, Math.Rounding.Floor);
        if (shares > maxShares) revert ERC4626ExceededMaxMint(receiver, shares, maxShares);
        assets = _toAssets(shares, v.navHigh, Math.Rounding.Ceil);
        _deposit(_msgSender(), receiver, assets, shares);
    }

    /// @notice Withdraws USDG after raising cash from configured hedge routes if needed.
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 shares)
    {
        Valuation memory v = _valuation();
        uint256 maxAssets = _maxWithdraw(owner, v);
        if (assets > maxAssets) revert ERC4626ExceededMaxWithdraw(owner, assets, maxAssets);
        shares = _toShares(assets, v.navLow, Math.Rounding.Ceil);
        _withdrawWith(v, _msgSender(), receiver, owner, assets, shares);
    }

    /// @notice Redeems CRAB shares after raising cash from configured hedge routes if needed.
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626Upgradeable, IERC4626)
        nonReentrant
        returns (uint256 assets)
    {
        Valuation memory v = _valuation();
        uint256 maxShares = _maxRedeem(owner, v);
        if (shares > maxShares) revert ERC4626ExceededMaxRedeem(owner, shares, maxShares);
        assets = _toAssets(shares, v.navLow, Math.Rounding.Floor);
        _withdrawWith(v, _msgSender(), receiver, owner, assets, shares);
    }

    /// @notice Pays USDG to the engine after selling configured hedges when necessary.
    function pay(address to, uint256 usdgAmount, uint8 preferMarket) external override nonReentrant {
        if (msg.sender != address(engine)) revert NotEngine();
        if (to == address(0)) revert InvalidParams();
        if (usdg.balanceOf(address(this)) < usdgAmount) {
            (, ValuationMark[] memory marks) = engine.valuation();
            _ensureCash(usdgAmount, preferMarket, marks);
        }
        usdg.safeTransfer(to, usdgAmount);
    }

    /// @notice Rebalances a market's tracked hedge toward the engine's current delta target.
    function rebalance(uint8 id) external override onlyRole(KEEPER_ROLE) nonReentrant returns (int256 unitsDelta) {
        Valuation memory v = _valuation();
        if (id >= v.marks.length) revert InvalidMarketId();
        ValuationMark memory mark = v.marks[id];
        if (mark.regime == Regime.PAUSED) revert RegimePaused();

        uint256 price = mark.spot;
        if (price == 0) revert InsufficientLiquidity();
        uint256 target = Math.mulDiv(engine.hedgeDelta(id), hedgeRatioBps, BPS);
        uint256 current = _hedgeUnits[id];
        if (target == current) return 0;

        bool buy = target > current;
        uint256 difference = buy ? target - current : current - target;
        if (Math.mulDiv(difference, price, STOCK_VALUE_DENOMINATOR) < minHedgeTradeUsdg) return 0;
        if (target != 0 && Math.mulDiv(difference, BPS, target) < rebalanceThresholdBps) return 0;

        IHedgeAdapter adapter = _hedgeAdapters[id];
        if (address(adapter) == address(0)) revert InvalidRoute();
        address stock = _stocks[id];

        if (buy) {
            uint256 desiredAssets = Math.mulDiv(difference, price, STOCK_VALUE_DENOMINATOR, Math.Rounding.Ceil);
            uint256 buffer = Math.mulDiv(_assetsOf(v.nav), cashBufferBps, BPS);
            uint256 available = v.cash > buffer ? v.cash - buffer : 0;
            uint256 amountIn = desiredAssets < available ? desiredAssets : available;
            if (amountIn < minHedgeTradeUsdg) return 0;

            uint256 minOut = _minStockOut(amountIn, price);
            (uint256 spent, uint256 received) = _swap(adapter, address(usdg), stock, _poolFees[id], amountIn, minOut);
            uint256 unitsAfter = current + received;
            _hedgeUnits[id] = unitsAfter;
            unitsDelta = _toInt(received);
            emit Hedged(id, true, spent, received, unitsAfter);
        } else {
            uint256 minOut = _minUsdgOut(difference, price);
            (uint256 sold, uint256 received) = _swap(adapter, stock, address(usdg), _poolFees[id], difference, minOut);
            if (sold > current) revert InsufficientLiquidity();
            uint256 unitsAfter = current - sold;
            _hedgeUnits[id] = unitsAfter;
            unitsDelta = -_toInt(sold);
            emit Hedged(id, false, sold, received, unitsAfter);
        }
    }

    /// @notice Resets the tracked hedge to the vault's actual stock-token balance.
    function syncHedgeUnits(uint8 id) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (id >= engine.marketCount()) revert InvalidMarketId();
        uint256 units = engine.getConfig(id).stock.balanceOf(address(this));
        _hedgeUnits[id] = units;
        emit HedgeUnitsSynced(id, units);
    }

    /// @dev USDG and CRAB are 6 and 12 decimals respectively.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @dev A deposit must be self-received so a third party cannot restart another holder's lock.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        if (caller != receiver || !_canDeposit(receiver) || shares == 0) revert InvalidParams();
        super._deposit(caller, receiver, assets, shares);
        lastDeposit[receiver] = block.timestamp;
    }

    /// @dev Only reachable through overridden entry points; kept so no inherited path skips the vault's checks.
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
    {
        _withdrawWith(_valuation(), caller, receiver, owner, assets, shares);
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

    /// @dev Shares cannot be burned before their owner's latest deposit lock expires.
    function _withdrawWith(
        Valuation memory v,
        address caller,
        address receiver,
        address owner,
        uint256 assets,
        uint256 shares
    ) private {
        if (unlockTime(owner) > block.timestamp) revert WithdrawalLocked();
        if (caller != owner) _spendAllowance(owner, caller, shares);
        if (v.cash < assets) {
            _ensureCash(assets, 0, v.marks);
            v = _valuation();
        }
        if (assets > _withdrawableAssets(v)) revert InsufficientLiquidity();
        _burn(owner, shares);
        usdg.safeTransfer(receiver, assets);
        emit Withdraw(caller, receiver, owner, assets, shares);
    }

    function _valuation() private view returns (Valuation memory v) {
        (v.liability, v.marks) = engine.valuation();
        v.cash = usdg.balanceOf(address(this));

        uint256 grossWad = v.cash * USDG_TO_WAD;
        int256 up;
        int256 down;
        uint256 openMove = navGuardOpenBps;
        uint256 closedMove = navGuardClosedBps;
        uint256 count = v.marks.length;
        for (uint256 i; i < count; ++i) {
            ValuationMark memory mark = v.marks[i];
            uint256 hedgeValue;
            uint256 units = _hedgeUnits[uint8(i)];
            if (units != 0) {
                hedgeValue = Math.mulDiv(units, mark.spot, 1e18);
                grossWad += hedgeValue;
            }
            uint256 move = mark.regime == Regime.OPEN ? openMove : closedMove;
            if (move == 0 || (hedgeValue == 0 && mark.liability == 0)) continue;

            // NAV change for a feed move of ±move: hedge gains h·m, the power liability grows by L·((1±m)² − 1).
            int256 hedgeMove = _toInt(Math.mulDiv(hedgeValue, move, BPS));
            int256 deltaMove = _toInt(Math.mulDiv(mark.liability, 2 * move, BPS));
            int256 gammaMove = _toInt(Math.mulDiv(mark.liability, move * move, BPS * BPS));
            int256 upScenario = hedgeMove - deltaMove - gammaMove;
            int256 downScenario = deltaMove - hedgeMove - gammaMove;
            int256 best = upScenario > downScenario ? upScenario : downScenario;
            int256 worst = upScenario < downScenario ? upScenario : downScenario;
            if (best > 0) up += best;
            if (worst < 0) down += worst;
        }

        v.nav = grossWad >= v.liability ? _toInt(grossWad - v.liability) : -_toInt(v.liability - grossWad);
        v.navLow = v.nav + down;
        v.navHigh = v.nav + up;
    }

    function _navFrom(uint256 cash, uint256 liabilityWad, uint256[] memory spots) private view returns (int256) {
        uint256 grossWad = cash * USDG_TO_WAD;
        uint256 count = spots.length;
        for (uint256 i; i < count; ++i) {
            uint256 units = _hedgeUnits[uint8(i)];
            if (units != 0) grossWad += Math.mulDiv(units, spots[i], 1e18);
        }
        if (grossWad >= liabilityWad) return _toInt(grossWad - liabilityWad);
        return -_toInt(liabilityWad - grossWad);
    }

    function _assetsOf(int256 navWad) private pure returns (uint256) {
        return navWad > 0 ? uint256(navWad) / USDG_TO_WAD : 0;
    }

    function _toShares(uint256 assets, int256 navWad, Math.Rounding rounding) private view returns (uint256) {
        return assets.mulDiv(totalSupply() + 10 ** _decimalsOffset(), _assetsOf(navWad) + 1, rounding);
    }

    function _toAssets(uint256 shares, int256 navWad, Math.Rounding rounding) private view returns (uint256) {
        return shares.mulDiv(_assetsOf(navWad) + 1, totalSupply() + 10 ** _decimalsOffset(), rounding);
    }

    function _maxDeposit(address receiver, Valuation memory v) private view returns (uint256) {
        if (!_canDeposit(receiver) || maxTotalDeposits == 0) return 0;
        bool emptyBootstrap = totalSupply() == 0 && v.liability == 0;
        if (v.nav <= 0 && !emptyBootstrap) return 0;

        uint256 assets = _assetsOf(v.nav);
        if (assets >= maxTotalDeposits) return 0;
        return uint256(maxTotalDeposits) - assets;
    }

    function _maxWithdraw(address owner, Valuation memory v) private view returns (uint256) {
        if (unlockTime(owner) > block.timestamp) return 0;
        uint256 assetsFromShares = _toAssets(balanceOf(owner), v.navLow, Math.Rounding.Floor);
        uint256 assetsAvailable = _withdrawalLimit(v);
        return assetsFromShares < assetsAvailable ? assetsFromShares : assetsAvailable;
    }

    function _maxRedeem(address owner, Valuation memory v) private view returns (uint256) {
        if (unlockTime(owner) > block.timestamp) return 0;
        uint256 shares = balanceOf(owner);
        uint256 sharesWithinReserve = _toShares(_withdrawalLimit(v), v.navLow, Math.Rounding.Floor);
        return shares < sharesWithinReserve ? shares : sharesWithinReserve;
    }

    function _withdrawableAssets(Valuation memory v) private view returns (uint256) {
        uint256 assets = _assetsOf(v.nav);
        if (v.liability == 0) return assets;

        uint256 exposureBps = engine.maxGlobalExposureBps();
        if (exposureBps == 0) return 0;
        uint256 required = Math.mulDiv(v.liability, BPS, exposureBps * USDG_TO_WAD, Math.Rounding.Ceil);
        return assets > required ? assets - required : 0;
    }

    function _withdrawalLimit(Valuation memory v) private view returns (uint256) {
        uint256 headroom = _withdrawableAssets(v);
        if (headroom == 0) return 0;

        uint256 cash = v.cash;
        uint256 slippageBps = maxHedgeSlippageBps;
        uint256 conservativeLimit = headroom;
        if (headroom > cash) {
            conservativeLimit = cash + Math.mulDiv(headroom - cash, BPS - slippageBps, BPS);
        }

        uint256 liquidAssets = cash;
        uint256 count = v.marks.length;
        for (uint256 i; i < count; ++i) {
            uint8 id = uint8(i);
            uint256 units = _hedgeUnits[id];
            if (units == 0 || address(_hedgeAdapters[id]) == address(0)) continue;
            uint256 price = v.marks[i].spot;
            if (price != 0) liquidAssets += _minUsdgOut(units, price);
        }

        return conservativeLimit < liquidAssets ? conservativeLimit : liquidAssets;
    }

    function _ensureCash(uint256 amount, uint8 preferMarket, ValuationMark[] memory marks) private {
        uint256 count = marks.length;
        for (uint256 step; usdg.balanceOf(address(this)) < amount && step <= count; ++step) {
            uint8 id;
            if (step == 0) {
                id = preferMarket;
            } else {
                uint256 candidate = step - 1;
                if (candidate == preferMarket || candidate >= count) continue;
                id = uint8(candidate);
            }

            if (id >= count) continue;
            uint256 units = _hedgeUnits[id];
            IHedgeAdapter adapter = _hedgeAdapters[id];
            uint256 price = marks[id].spot;
            if (units == 0 || price == 0 || address(adapter) == address(0)) continue;

            uint256 shortfall = amount - usdg.balanceOf(address(this));
            uint256 grossUnitsNeeded = Math.mulDiv(shortfall, STOCK_VALUE_DENOMINATOR, price, Math.Rounding.Ceil);
            uint256 unitsNeeded = Math.mulDiv(grossUnitsNeeded, BPS, BPS - maxHedgeSlippageBps, Math.Rounding.Ceil);
            uint256 unitsToSell = unitsNeeded < units ? unitsNeeded : units;
            if (unitsToSell == 0) continue;

            uint256 minOut = _minUsdgOut(unitsToSell, price);
            // One failing route (paused stock, drained pool) must not block payments other hedges can cover.
            (bool ok, uint256 sold, uint256 received) =
                _trySwap(adapter, _stocks[id], address(usdg), _poolFees[id], unitsToSell, minOut);
            if (!ok) continue;
            if (sold > units) revert InsufficientLiquidity();
            _hedgeUnits[id] = units - sold;
            emit CashRaised(id, sold, received);
        }

        if (usdg.balanceOf(address(this)) < amount) revert InsufficientLiquidity();
    }

    function _swap(
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

    function _toInt(uint256 value) private pure returns (int256) {
        if (value > uint256(type(int256).max)) revert InvalidParams();
        return int256(value);
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[39] private __gap;
}
