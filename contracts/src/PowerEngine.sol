// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ICrabVault} from "./interfaces/ICrabVault.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IMarketHours} from "./interfaces/IMarketHours.sol";
import {IPowerEngine} from "./interfaces/IPowerEngine.sol";
import {MarketConfig, MarketState, Regime} from "./libs/OgeeTypes.sol";
import {OgeeMath} from "./libs/OgeeMath.sol";
import {Roles} from "./libs/Roles.sol";
import {PowerToken} from "./PowerToken.sol";
import {PowerTokenFactory} from "./PowerTokenFactory.sol";

/// @title PowerEngine
/// @notice Market registry, oracle guard, carry accrual, quoting, and spot trade execution.
contract PowerEngine is
    Initializable,
    AccessControlUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    IPowerEngine
{
    using SafeERC20 for IERC20;

    uint256 private constant WAD = 1e18;
    uint256 private constant BPS = 10_000;
    uint256 private constant FEED_TO_WAD = 1e10;
    uint256 private constant USDG_TO_WAD = 1e12;
    uint256 private constant MAX_ACCRUAL = 7 days;
    uint256 private constant CARRY_DAY = 1 days;
    uint256 private constant SEQUENCER_GRACE_PERIOD = 1 hours;
    uint256 private constant PAUSED_BAND_BPS = 300;
    /// @dev Chain-independent paused-sell budget window. `block.number` on Arbitrum Orbit chains returns the
    /// parent-chain block number, so a per-block cap would not mean what it says.
    uint256 private constant PAUSED_SELL_WINDOW = 1 hours;
    uint256 private constant MAX_SPOT_WAD = type(uint128).max;
    uint128 private constant MIN_NORM_FACTOR = 1e12;

    bytes32 public constant override KEEPER_ROLE = Roles.KEEPER_ROLE;
    bytes32 public constant override GUARDIAN_ROLE = Roles.GUARDIAN_ROLE;

    struct OracleData {
        uint256 spot;
        uint256 updatedAt;
        uint256 indexWad;
        bool valid;
        bool stockPaused;
        bool sequencerDown;
    }

    struct Quote {
        uint256 amountOut;
        uint256 fee;
        uint256 price;
        uint256 grossUsdg;
    }

    IERC20 public override usdg;
    ICrabVault public override vault;
    IMarketHours public override marketHours;
    address public override treasury;
    IAggregatorV3 public override sequencerFeed;
    uint16 public override maxGlobalExposureBps;
    uint16 public override protocolFeeShareBps;
    bool public override globalBuysPaused;

    MarketConfig[] private _configs;
    MarketState[] private _states;
    mapping(address token => uint8 idPlusOne) private _idPlusOne;
    PowerTokenFactory private immutable _TOKEN_FACTORY;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _TOKEN_FACTORY = new PowerTokenFactory();
        _disableInitializers();
    }

    /// @notice Initializes protocol dependencies and grants the admin role.
    function initialize(address admin, IERC20 usdg_, ICrabVault vault_, IMarketHours marketHours_, address treasury_)
        external
        override
        initializer
    {
        if (
            admin == address(0) || address(usdg_) == address(0) || address(vault_) == address(0)
                || address(marketHours_) == address(0) || treasury_ == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        usdg = usdg_;
        vault = vault_;
        marketHours = marketHours_;
        treasury = treasury_;
        maxGlobalExposureBps = 5_000;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Creates a new market and its immutable PowerToken.
    function listMarket(
        MarketConfig calldata config,
        string calldata name,
        string calldata symbol,
        int64 initialBaseCarryWad
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) returns (uint8 id) {
        if (_configs.length >= type(uint8).max) revert InvalidMarketConfig();
        if (address(config.token) != address(0)) revert InvalidMarketConfig();
        _validateMarketConfig(config);
        // Vault hedge accounting (syncHedgeUnits, NAV) assumes one market per stock token.
        for (uint256 i; i < _configs.length; ++i) {
            if (address(_configs[i].stock) == address(config.stock)) revert InvalidMarketConfig();
        }
        if (initialBaseCarryWad < config.baseCarryMinWad || initialBaseCarryWad > config.baseCarryMaxWad) {
            revert CarryOutOfBounds();
        }

        id = uint8(_configs.length);
        PowerToken token = _TOKEN_FACTORY.deployToken(name, symbol, address(this));
        MarketConfig memory storedConfig = config;
        storedConfig.token = token;
        _configs.push(storedConfig);

        MarketState memory initialState;
        initialState.normFactor = uint128(WAD);
        initialState.lastAccrual = uint64(block.timestamp);
        initialState.baseCarryWad = initialBaseCarryWad;
        initialState.baseCarryUpdatedAt = uint64(block.timestamp);
        _states.push(initialState);
        _idPlusOne[address(token)] = id + 1;

        OracleData memory oracle = _readOracle(_configs[id]);
        if (!oracle.valid) revert OracleInvalid();
        MarketState storage state = _states[id];
        state.lastGoodPrice = uint128(oracle.spot);
        state.lastGoodIndex = uint128(oracle.indexWad);
        state.lastGoodAt = uint64(oracle.updatedAt);
        state.regime = _regime(id, oracle);
        _refreshUtil(id);

        _emitMarketListed(id, token);
    }

    /// @notice Updates mutable risk and carry parameters for an existing market.
    function setMarketConfig(uint8 id, MarketConfig calldata config) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        _requireMarket(id);
        _accrue(id);

        MarketConfig storage current = _configs[id];
        if (
            address(config.stock) != address(current.stock) || address(config.feed) != address(current.feed)
                || address(config.token) != address(current.token) || config.scale != current.scale
                || config.kind != current.kind
        ) {
            revert InvalidMarketConfig();
        }
        _validateMarketConfig(config);
        MarketState storage state = _states[id];
        if (state.baseCarryWad < config.baseCarryMinWad || state.baseCarryWad > config.baseCarryMaxWad) {
            revert CarryOutOfBounds();
        }

        _configs[id] = config;
        emit MarketConfigUpdated(id);
        _refreshUtil(id);
    }

    /// @notice Updates protocol-wide exposure, fee routing, and sequencer settings.
    function setGlobal(
        uint16 maxGlobalExposureBps_,
        uint16 protocolFeeShareBps_,
        address treasury_,
        address sequencerFeed_
    ) external override onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxGlobalExposureBps_ > BPS || protocolFeeShareBps_ > BPS || treasury_ == address(0)) {
            revert InvalidMarketConfig();
        }
        maxGlobalExposureBps = maxGlobalExposureBps_;
        protocolFeeShareBps = protocolFeeShareBps_;
        treasury = treasury_;
        sequencerFeed = IAggregatorV3(sequencerFeed_);
        emit GlobalConfigUpdated(maxGlobalExposureBps_, protocolFeeShareBps_, treasury_, sequencerFeed_);
    }

    /// @notice Moves a market's base carry by at most 25% once per 24-hour window.
    function setBaseCarry(uint8 id, int64 wad) external override onlyRole(KEEPER_ROLE) {
        _requireMarket(id);
        _accrue(id);
        MarketConfig storage config = _configs[id];
        MarketState storage state = _states[id];
        if (wad < config.baseCarryMinWad || wad > config.baseCarryMaxWad) revert CarryOutOfBounds();
        if (wad == state.baseCarryWad) return;
        if (block.timestamp < uint256(state.baseCarryUpdatedAt) + CARRY_DAY) revert CarryChangeTooFast();

        int256 current = int256(state.baseCarryWad);
        int256 next = int256(wad);
        uint256 difference = uint256(next >= current ? next - current : current - next);
        // A zero base carry would otherwise allow no step at all; measure from the upper bound instead.
        uint256 stepBase = current > 0 ? uint256(current) : uint256(int256(config.baseCarryMaxWad));
        uint256 maxStep = stepBase * 2_500 / BPS;
        if (difference > maxStep) revert CarryChangeTooFast();

        state.baseCarryWad = wad;
        state.baseCarryUpdatedAt = uint64(block.timestamp);
        emit BaseCarryUpdated(id, wad);
    }

    /// @notice Stops new buys for one market without blocking sells.
    function setBuysPaused(uint8 id, bool paused) external override onlyRole(GUARDIAN_ROLE) {
        _requireMarket(id);
        _accrue(id);
        MarketState storage state = _states[id];
        if (state.buysPaused == paused) return;
        state.buysPaused = paused;
        emit BuysPaused(id, paused);
    }

    /// @notice Stops new buys for every market without blocking sells.
    function setGlobalBuysPaused(bool paused) external override onlyRole(GUARDIAN_ROLE) {
        if (globalBuysPaused == paused) return;
        globalBuysPaused = paused;
        emit GlobalBuysPaused(paused);
    }

    /// @notice Applies carry and refreshes oracle state for one market.
    function accrue(uint8 id) external override {
        _requireMarket(id);
        _accrue(id);
    }

    /// @notice Applies carry and refreshes oracle state for all markets.
    function accrueAll() external override {
        uint256 count = _configs.length;
        for (uint256 i; i < count; ++i) {
            _accrue(uint8(i));
        }
    }

    /// @notice Buys PowerTokens with an existing USDG allowance.
    function buy(uint8 id, uint256 usdgIn, uint256 minTokensOut, address recipient, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint256 tokensOut)
    {
        return _buy(id, usdgIn, minTokensOut, recipient, deadline);
    }

    /// @notice Attempts an ERC-2612 permit, then buys PowerTokens.
    /// @dev A failed permit is ignored; the subsequent transferFrom enforces the current allowance.
    function buyWithPermit(
        uint8 id,
        uint256 usdgIn,
        uint256 minTokensOut,
        address recipient,
        uint256 deadline,
        uint256 permitDeadline,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override nonReentrant returns (uint256 tokensOut) {
        try IERC20Permit(address(usdg)).permit(msg.sender, address(this), usdgIn, permitDeadline, v, r, s) {} catch {}
        return _buy(id, usdgIn, minTokensOut, recipient, deadline);
    }

    /// @notice Sells the caller's PowerTokens. No approval is needed and buy pauses never block this path.
    function sell(uint8 id, uint256 tokensIn, uint256 minUsdgOut, address recipient, uint256 deadline)
        external
        override
        nonReentrant
        returns (uint256 usdgOut)
    {
        _requireMarket(id);
        _accrue(id);
        if (deadline < block.timestamp) revert Expired();
        if (recipient == address(0)) revert ZeroAddress();
        if (tokensIn == 0) revert TradeTooSmall();

        MarketState storage state = _states[id];
        if (tokensIn > state.vaultShort) revert TradeTooLarge();
        Regime regime = _regime(id, _readOracle(_configs[id]));
        Quote memory quote = _quoteSell(id, tokensIn, regime);
        usdgOut = quote.amountOut;
        if (usdgOut < minUsdgOut) revert Slippage();
        if (regime == Regime.PAUSED) _consumePausedSellCap(id, quote.grossUsdg);

        MarketConfig storage config = _configs[id];
        config.token.burn(msg.sender, tokensIn);
        state.vaultShort -= uint128(tokensIn);
        vault.pay(recipient, usdgOut, id);
        uint256 treasuryFee = Math.mulDiv(quote.fee, protocolFeeShareBps, BPS);
        if (treasuryFee != 0) vault.pay(treasury, treasuryFee, id);

        _refreshUtil(id);
        _emitSold(id, recipient, tokensIn, quote, regime);
    }

    /// @notice Returns the number of listed markets.
    function marketCount() external view override returns (uint8) {
        return uint8(_configs.length);
    }

    /// @notice Returns immutable identity and mutable risk parameters for a market.
    function getConfig(uint8 id) external view override returns (MarketConfig memory) {
        _requireMarket(id);
        return _configs[id];
    }

    /// @notice Returns the last stored accrual and oracle state for a market.
    function getState(uint8 id) external view override returns (MarketState memory) {
        _requireMarket(id);
        return _states[id];
    }

    /// @notice Returns the live market regime, including feed and sequencer guards.
    function currentRegime(uint8 id) external view override returns (Regime) {
        _requireMarket(id);
        return _regime(id, _readOracle(_configs[id]));
    }

    /// @notice Returns the feed spot and update time. `valid` is false for malformed or future rounds.
    function spotPrice(uint8 id) external view override returns (uint256 spot, uint256 updatedAt, bool valid) {
        _requireMarket(id);
        OracleData memory oracle = _readOracle(_configs[id]);
        return (oracle.spot, oracle.updatedAt, oracle.valid);
    }

    /// @notice Returns the live squared-price index, or the last good index while paused.
    function index(uint8 id) external view override returns (uint256 indexWad) {
        _requireMarket(id);
        return _indexForRegime(id, _regime(id, _readOracle(_configs[id])));
    }

    /// @notice Returns normFactor projected to the current timestamp using stored carry and utilization.
    function currentNormFactor(uint8 id) public view override returns (uint256 normFactor) {
        _requireMarket(id);
        MarketState storage state = _states[id];
        Regime regime = _regime(id, _readOracle(_configs[id]));
        return _previewNormFactor(state, _carry(_configs[id], state, regime));
    }

    /// @notice Returns the current fair price per 1e18 PowerTokens in WAD USD.
    function tokenPrice(uint8 id) public view override returns (uint256 priceWad) {
        _requireMarket(id);
        Regime regime = _regime(id, _readOracle(_configs[id]));
        uint256 currentIndex = _indexForRegime(id, regime);
        return Math.mulDiv(currentNormFactor(id), currentIndex, WAD);
    }

    /// @notice Returns the daily carry fraction in WAD for the current regime.
    function currentCarryWad(uint8 id) public view override returns (int256 carryWad) {
        _requireMarket(id);
        MarketState storage state = _states[id];
        return _carry(_configs[id], state, _regime(id, _readOracle(_configs[id])));
    }

    /// @notice Returns the current carry rate in basis points per day.
    function dailyCarryBps(uint8 id) external view override returns (int256 carryBps) {
        return currentCarryWad(id) * int256(BPS) / int256(WAD);
    }

    /// @notice Returns the current USD liability of a market in WAD.
    function liability(uint8 id) public view override returns (uint256 liabilityWad) {
        _requireMarket(id);
        return _liability(id);
    }

    /// @notice Returns the sum of current market liabilities in WAD USD.
    function totalLiability() public view override returns (uint256 liabilityWad) {
        return _totalLiability();
    }

    /// @notice Returns the underlying-stock delta in WAD stock tokens.
    function hedgeDelta(uint8 id) external view override returns (uint256 units) {
        _requireMarket(id);
        uint256 spot = _spotForRegime(id, _regime(id, _readOracle(_configs[id])));
        uint256 numerator = Math.mulDiv(_states[id].vaultShort, currentNormFactor(id), WAD);
        return Math.mulDiv(numerator, 2 * spot, uint256(_configs[id].scale) * WAD);
    }

    /// @notice Returns an executable-side buy estimate plus the gross input remaining under configured caps.
    function quoteBuy(uint8 id, uint256 usdgIn)
        external
        view
        override
        returns (uint256 tokensOut, uint256 fee, uint256 price, uint256 maxUsdgIn)
    {
        _requireMarket(id);
        Regime regime = _regime(id, _readOracle(_configs[id]));
        if (regime == Regime.PAUSED) revert RegimePaused();
        Quote memory quote = _quoteBuy(id, usdgIn, regime);
        tokensOut = quote.amountOut;
        fee = quote.fee;
        price = quote.price;
        maxUsdgIn = _maxUsdgIn(id, regime);
    }

    /// @notice Returns an executable-side sell estimate in USDG.
    function quoteSell(uint8 id, uint256 tokensIn)
        external
        view
        override
        returns (uint256 usdgOut, uint256 fee, uint256 price)
    {
        _requireMarket(id);
        Quote memory quote = _quoteSell(id, tokensIn, _regime(id, _readOracle(_configs[id])));
        return (quote.amountOut, quote.fee, quote.price);
    }

    /// @notice Resolves a listed token to its zero-based market id.
    function marketIdOf(address token) external view override returns (uint8 id) {
        uint8 idPlusOne = _idPlusOne[token];
        if (idPlusOne == 0) revert MarketNotFound();
        return idPlusOne - 1;
    }

    function _buy(uint8 id, uint256 usdgIn, uint256 minTokensOut, address recipient, uint256 deadline)
        private
        returns (uint256 tokensOut)
    {
        _requireMarket(id);
        _accrue(id);
        if (deadline < block.timestamp) revert Expired();
        if (recipient == address(0)) revert ZeroAddress();
        if (_states[id].buysPaused || globalBuysPaused) revert BuysPausedErr();

        Regime regime = _regime(id, _readOracle(_configs[id]));
        if (regime == Regime.PAUSED) revert RegimePaused();
        MarketConfig storage config = _configs[id];
        if (usdgIn < config.minTradeUsdg) revert TradeTooSmall();
        if (usdgIn > config.maxTradeUsdg) revert TradeTooLarge();

        Quote memory quote = _quoteBuy(id, usdgIn, regime);
        tokensOut = quote.amountOut;
        if (tokensOut == 0 || tokensOut < minTokensOut) revert Slippage();
        _checkBuyCaps(id, tokensOut);

        usdg.safeTransferFrom(msg.sender, address(vault), usdgIn);
        uint256 treasuryFee = Math.mulDiv(quote.fee, protocolFeeShareBps, BPS);
        if (treasuryFee != 0) vault.pay(treasury, treasuryFee, id);

        MarketState storage state = _states[id];
        if (tokensOut > type(uint128).max - state.vaultShort) revert MarketCapExceeded();
        config.token.mint(recipient, tokensOut);
        state.vaultShort += uint128(tokensOut);
        _refreshUtil(id);

        _emitBought(id, recipient, usdgIn, quote, regime);
    }

    function _emitBought(uint8 id, address recipient, uint256 usdgIn, Quote memory quote, Regime regime) private {
        emit Bought(
            id,
            msg.sender,
            recipient,
            usdgIn,
            quote.fee,
            quote.amountOut,
            quote.price,
            _indexForRegime(id, regime),
            currentNormFactor(id)
        );
    }

    function _emitMarketListed(uint8 id, PowerToken token) private {
        MarketConfig storage config = _configs[id];
        emit MarketListed(id, address(token), address(config.stock), address(config.feed), config.scale);
    }

    function _emitSold(uint8 id, address recipient, uint256 tokensIn, Quote memory quote, Regime regime) private {
        emit Sold(
            id,
            msg.sender,
            recipient,
            tokensIn,
            quote.amountOut,
            quote.fee,
            quote.price,
            _indexForRegime(id, regime),
            currentNormFactor(id)
        );
    }

    function _quoteBuy(uint8 id, uint256 usdgIn, Regime regime) private view returns (Quote memory quote) {
        MarketConfig storage config = _configs[id];
        uint256 fairPrice = tokenPrice(id);
        quote.price = _tradePrice(id, fairPrice, regime, usdgIn);
        quote.fee = OgeeMath.bpsUp(usdgIn, config.feeBps);
        if (quote.fee >= usdgIn || quote.price == 0) return quote;
        uint256 netWad = (usdgIn - quote.fee) * USDG_TO_WAD;
        quote.amountOut = Math.mulDiv(netWad, WAD, quote.price);
    }

    function _quoteSell(uint8 id, uint256 tokensIn, Regime regime) private view returns (Quote memory quote) {
        MarketConfig storage config = _configs[id];
        uint256 fairPrice = tokenPrice(id);
        uint256 fairGrossWad = Math.mulDiv(tokensIn, fairPrice, WAD);
        uint256 fairGrossUsdg = fairGrossWad / USDG_TO_WAD;
        quote.price = _tradePrice(id, fairPrice, regime, fairGrossUsdg, true);
        if (quote.price == 0) return quote;
        uint256 grossWad = Math.mulDiv(tokensIn, quote.price, WAD);
        quote.grossUsdg = grossWad / USDG_TO_WAD;
        quote.fee = OgeeMath.bpsUp(quote.grossUsdg, config.feeBps);
        quote.amountOut = quote.grossUsdg > quote.fee ? quote.grossUsdg - quote.fee : 0;
    }

    function _tradePrice(uint8 id, uint256 fairPrice, Regime regime, uint256 tradeUsdg) private view returns (uint256) {
        return _tradePrice(id, fairPrice, regime, tradeUsdg, false);
    }

    function _tradePrice(uint8 id, uint256 fairPrice, Regime regime, uint256 tradeUsdg, bool isSell)
        private
        view
        returns (uint256)
    {
        MarketConfig storage config = _configs[id];
        (uint256 spreadBps, uint256 bandBps) = _spreadAndBand(config, regime);
        uint256 capacityUsdg = _marketCapacityWad(id) / USDG_TO_WAD;
        uint256 impactBps;
        if (config.impactBps != 0) {
            if (capacityUsdg == 0) {
                impactBps = bandBps;
            } else if (tradeUsdg >= Math.mulDiv(capacityUsdg, bandBps, config.impactBps)) {
                impactBps = bandBps;
            } else {
                impactBps = Math.mulDiv(config.impactBps, tradeUsdg, capacityUsdg);
            }
        }
        uint256 devBps = spreadBps + impactBps;
        if (devBps > bandBps) devBps = bandBps;
        uint256 adjustment = Math.mulDiv(fairPrice, devBps, BPS);
        return isSell ? fairPrice - adjustment : fairPrice + adjustment;
    }

    function _spreadAndBand(MarketConfig storage config, Regime regime)
        private
        view
        returns (uint256 spreadBps, uint256 bandBps)
    {
        if (regime == Regime.OPEN) return (config.openSpreadBps, config.openBandBps);
        if (regime == Regime.OFF_HOURS) return (config.offHoursSpreadBps, config.offHoursBandBps);
        return (config.pausedSpreadBps, PAUSED_BAND_BPS);
    }

    function _checkBuyCaps(uint8 id, uint256 tokensOut) private view {
        MarketConfig storage config = _configs[id];
        MarketState storage state = _states[id];
        if (tokensOut > type(uint128).max - state.vaultShort) revert MarketCapExceeded();

        int256 navWad = vault.navView();
        if (navWad <= 0) revert GlobalCapExceeded();
        uint256 nav = uint256(navWad);
        uint256 fairPrice = tokenPrice(id);
        uint256 addedLiability = Math.mulDiv(tokensOut, fairPrice, WAD, Math.Rounding.Ceil);
        uint256 newMarketLiability =
            Math.mulDiv(uint256(state.vaultShort) + tokensOut, fairPrice, WAD, Math.Rounding.Ceil);
        uint256 marketCapacity = Math.mulDiv(nav, config.maxMarketExposureBps, BPS);
        if (newMarketLiability > marketCapacity) revert MarketCapExceeded();

        uint256 globalCapacity = Math.mulDiv(nav, maxGlobalExposureBps, BPS);
        if (_totalLiability() + addedLiability > globalCapacity) revert GlobalCapExceeded();
    }

    function _consumePausedSellCap(uint8 id, uint256 grossUsdg) private {
        // Legacy field names: `pausedSellBlock` stores the window index and the cap applies per PAUSED_SELL_WINDOW.
        MarketState storage state = _states[id];
        uint64 currentWindow = uint64(block.timestamp / PAUSED_SELL_WINDOW);
        uint256 used = state.pausedSellBlock == currentWindow ? state.pausedSellUsed : 0;
        uint256 cap = _configs[id].pausedSellCapPerBlockUsdg;
        if (grossUsdg > cap || used > cap - grossUsdg) revert PausedSellCapExceeded();
        state.pausedSellBlock = currentWindow;
        state.pausedSellUsed = uint128(used + grossUsdg);
    }

    function _maxUsdgIn(uint8 id, Regime regime) private view returns (uint256 maxUsdgIn) {
        MarketConfig storage config = _configs[id];
        int256 navWad = vault.navView();
        if (navWad <= 0 || maxGlobalExposureBps == 0) return 0;

        uint256 room = _remainingCapRoom(id, uint256(navWad));
        if (room == 0) return 0;
        uint256 capacityUsdg = _marketCapacityWad(id) / USDG_TO_WAD;
        (uint256 spreadBps, uint256 bandBps) = _spreadAndBand(config, regime);
        uint256 inputRoom = _grossInputForRoom(room / USDG_TO_WAD, capacityUsdg, config, spreadBps, bandBps);
        maxUsdgIn = inputRoom < config.maxTradeUsdg ? inputRoom : config.maxTradeUsdg;
    }

    function _remainingCapRoom(uint8 id, uint256 navWad) private view returns (uint256 room) {
        MarketConfig storage config = _configs[id];
        uint256 marketLimit = Math.mulDiv(navWad, config.maxMarketExposureBps, BPS);
        uint256 marketLiability = _liability(id);
        uint256 globalLimit = Math.mulDiv(navWad, maxGlobalExposureBps, BPS);
        uint256 totalLiabs = _totalLiability();
        uint256 marketRoom = marketLimit > marketLiability ? marketLimit - marketLiability : 0;
        uint256 globalRoom = globalLimit > totalLiabs ? globalLimit - totalLiabs : 0;
        room = marketRoom < globalRoom ? marketRoom : globalRoom;
    }

    function _grossInputForRoom(
        uint256 roomUsdg,
        uint256 capacityUsdg,
        MarketConfig storage config,
        uint256 spreadBps,
        uint256 bandBps
    ) private view returns (uint256 grossUsdg) {
        if (roomUsdg == 0) return 0;
        uint256 feeFactor = BPS - config.feeBps;
        uint256 impactRoomBps = capacityUsdg == 0 ? bandBps : Math.mulDiv(roomUsdg, config.impactBps, capacityUsdg);
        uint256 denominator = impactRoomBps < feeFactor ? feeFactor - impactRoomBps : 0;
        if (denominator == 0) {
            return Math.mulDiv(roomUsdg, BPS + bandBps, feeFactor);
        }

        grossUsdg = Math.mulDiv(roomUsdg, BPS + spreadBps, denominator);
        uint256 impactBps = capacityUsdg == 0 ? bandBps : Math.mulDiv(config.impactBps, grossUsdg, capacityUsdg);
        if (spreadBps + impactBps > bandBps) {
            grossUsdg = Math.mulDiv(roomUsdg, BPS + bandBps, feeFactor);
        }
    }

    function _accrue(uint8 id) private {
        MarketState storage state = _states[id];
        // Timestamp dedupe: on Arbitrum Orbit `block.number` is the parent-chain block, spanning many L2 blocks.
        if (state.lastAccrual == block.timestamp) return;
        MarketConfig storage config = _configs[id];
        Regime previousRegime = state.regime;
        OracleData memory oracle = _readOracle(config);
        Regime regime = _regime(id, oracle);
        int256 carryWad = _carry(config, state, regime);
        uint256 normFactor = _previewNormFactor(state, carryWad);
        state.normFactor = uint128(normFactor);
        state.lastAccrual = uint64(block.timestamp);

        if (regime != Regime.PAUSED && oracle.valid) {
            state.lastGoodPrice = uint128(oracle.spot);
            state.lastGoodIndex = uint128(oracle.indexWad);
            state.lastGoodAt = uint64(oracle.updatedAt);
        }
        state.regime = regime;

        if (previousRegime != regime) emit RegimeChanged(id, previousRegime, regime);
        emit Accrued(id, state.normFactor, int64(carryWad), regime, _indexForRegime(id, regime));
        _refreshUtil(id);
    }

    function _previewNormFactor(MarketState storage state, int256 carryWad) private view returns (uint256) {
        uint256 elapsed = block.timestamp > state.lastAccrual ? block.timestamp - state.lastAccrual : 0;
        if (elapsed > MAX_ACCRUAL) elapsed = MAX_ACCRUAL;
        if (elapsed == 0 || carryWad <= 0) return state.normFactor;

        uint256 decay = Math.mulDiv(uint256(carryWad), elapsed, CARRY_DAY);
        if (decay >= WAD) return MIN_NORM_FACTOR;
        uint256 projected = Math.mulDiv(state.normFactor, WAD - decay, WAD);
        return projected < MIN_NORM_FACTOR ? MIN_NORM_FACTOR : projected;
    }

    function _carry(MarketConfig storage config, MarketState storage state, Regime regime)
        private
        view
        returns (int256 carryWad)
    {
        if (regime != Regime.OPEN) return int256(config.offHoursCarryWad);
        carryWad =
            int256(state.baseCarryWad) + int256(config.skewCarryWad) * int256(uint256(state.lastUtilBps)) / int256(BPS);
        if (carryWad < config.minCarryWad) carryWad = config.minCarryWad;
        if (carryWad > config.maxCarryWad) carryWad = config.maxCarryWad;
    }

    function _refreshUtil(uint8 id) private {
        int256 navWad = vault.navView();
        MarketState storage state = _states[id];
        if (navWad <= 0) {
            state.lastUtilBps = uint16(BPS);
            return;
        }
        uint256 capacity = Math.mulDiv(uint256(navWad), _configs[id].maxMarketExposureBps, BPS);
        if (capacity == 0) {
            state.lastUtilBps = uint16(BPS);
            return;
        }
        uint256 utilization = Math.mulDiv(_liability(id), BPS, capacity);
        if (utilization > BPS) utilization = BPS;
        state.lastUtilBps = uint16(utilization);
    }

    function _liability(uint8 id) private view returns (uint256) {
        uint256 price = tokenPrice(id);
        return Math.mulDiv(_states[id].vaultShort, price, WAD);
    }

    function _totalLiability() private view returns (uint256 total) {
        uint256 count = _configs.length;
        for (uint256 i; i < count; ++i) {
            total += _liability(uint8(i));
        }
    }

    function _indexForRegime(uint8 id, Regime regime) private view returns (uint256) {
        if (regime == Regime.PAUSED) return _states[id].lastGoodIndex;
        OracleData memory oracle = _readOracle(_configs[id]);
        return oracle.valid ? oracle.indexWad : _states[id].lastGoodIndex;
    }

    function _spotForRegime(uint8 id, Regime regime) private view returns (uint256) {
        if (regime == Regime.PAUSED) return _states[id].lastGoodPrice;
        OracleData memory oracle = _readOracle(_configs[id]);
        return oracle.valid ? oracle.spot : _states[id].lastGoodPrice;
    }

    function _marketCapacityWad(uint8 id) private view returns (uint256) {
        int256 navWad = vault.navView();
        if (navWad <= 0) return 0;
        return Math.mulDiv(uint256(navWad), _configs[id].maxMarketExposureBps, BPS);
    }

    function _readOracle(MarketConfig storage config) private view returns (OracleData memory oracle) {
        try config.feed.latestRoundData() returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80) {
            oracle.updatedAt = updatedAt;
            if (
                answer > 0 && updatedAt != 0 && updatedAt <= block.timestamp
                    && uint256(answer) <= MAX_SPOT_WAD / FEED_TO_WAD
            ) {
                uint256 spot = uint256(answer) * FEED_TO_WAD;
                uint256 indexWad = Math.mulDiv(spot, spot, WAD) / config.scale;
                if (indexWad != 0 && indexWad <= type(uint128).max) {
                    oracle.spot = spot;
                    oracle.indexWad = indexWad;
                    oracle.valid = true;
                }
            }
        } catch {}

        try config.stock.oraclePaused() returns (bool paused) {
            oracle.stockPaused = paused;
        } catch {
            oracle.stockPaused = true;
        }
        // A token-level pause freezes transfers, so the vault cannot hedge or raise cash from this stock.
        if (!oracle.stockPaused) {
            try config.stock.paused() returns (bool paused) {
                oracle.stockPaused = paused;
            } catch {
                oracle.stockPaused = true;
            }
        }
        oracle.sequencerDown = _sequencerDown();
    }

    function _sequencerDown() private view returns (bool) {
        if (address(sequencerFeed) == address(0)) return false;
        try sequencerFeed.latestRoundData() returns (uint80, int256 answer, uint256 startedAt, uint256, uint80) {
            if (answer != 0 || startedAt == 0 || startedAt > block.timestamp) return true;
            return block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD;
        } catch {
            return true;
        }
    }

    function _regime(uint8 id, OracleData memory oracle) private view returns (Regime) {
        MarketConfig storage config = _configs[id];
        if (oracle.stockPaused || oracle.sequencerDown || !oracle.valid) return Regime.PAUSED;

        bool open = _isOpen();
        uint256 maxAge = open ? config.maxAgeOpen : config.maxAgeOffHours;
        if (block.timestamp - oracle.updatedAt > maxAge) return Regime.PAUSED;
        return open ? Regime.OPEN : Regime.OFF_HOURS;
    }

    function _isOpen() private view returns (bool) {
        try marketHours.isOpen(block.timestamp) returns (bool open) {
            return open;
        } catch {
            return false;
        }
    }

    function _validateMarketConfig(MarketConfig calldata config) private view {
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

    function _requireMarket(uint8 id) private view {
        if (id >= _configs.length) revert MarketNotFound();
    }

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    uint256[40] private __gap;
}
