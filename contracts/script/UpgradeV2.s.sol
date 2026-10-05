// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {CrabVault} from "../src/CrabVault.sol";
import {OgeeLens} from "../src/OgeeLens.sol";
import {PowerEngine} from "../src/PowerEngine.sol";
import {UniswapV3TwapReference, IUniswapV3FactoryLike} from "../src/UniswapV3TwapReference.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IHedgeAdapter} from "../src/interfaces/IHedgeAdapter.sol";
import {ICrabVault} from "../src/interfaces/ICrabVault.sol";
import {IPowerEngine} from "../src/interfaces/IPowerEngine.sol";
import {IPriceReference} from "../src/interfaces/IPriceReference.sol";
import {MarketConfig} from "../src/libs/OgeeTypes.sol";
import {OgeeScript, IUniswapV3PoolOps, IUUPSOps} from "./lib/OgeeScript.sol";

/// @title UpgradeV2
/// @notice Upgrades PowerEngine and CrabVault to V2 and applies the V2 settings: a per-market `offHoursBuyMaxAge`,
/// a Uniswap v3 TWAP price reference on the vault, and optionally the L2 sequencer uptime feed.
///
/// UPGRADE_MODE=direct   the broadcaster (current DEFAULT_ADMIN_ROLE holder) deploys, upgrades and configures.
/// UPGRADE_MODE=timelock the broadcaster only deploys the implementations and the TWAP reference; the upgrade and
///                       configuration calls are written as one TimelockController batch (schedule + execute calldata)
///                       for a Safe to propose. The batch is simulated locally when the timelock already holds admin.
///
/// Guards: the proxies' current ERC-1967 implementations must equal EXPECTED_ENGINE_IMPL / EXPECTED_VAULT_IMPL (or the
/// deployment file's engineImpl / vaultImpl), and state read before and after the upgrade must be identical (market
/// count and configs, vaultShort / lastGoodIndex / full market state, vault supply, params and hedge routes, global
/// settings, roles). Any mismatch reverts the whole script before anything is broadcast.
/// @dev See script/README.md for the environment variables and the recommended order of operations.
contract UpgradeV2 is OgeeScript {
    uint256 private constant DEFAULT_WINDOW = 1_800;
    uint256 private constant DEFAULT_OFF_HOURS_BUY_MAX_AGE = 3_600;

    struct Snapshot {
        uint8 marketCount;
        uint256 totalSupply;
        uint256 usdgBalance;
        uint16 maxGlobalExposureBps;
        uint16 protocolFeeShareBps;
        address treasury;
        address sequencerFeed;
        bool globalBuysPaused;
        address engineVault;
        address vaultEngine;
        bytes32 vaultParams;
        bytes32 roles;
        bytes32[] configs;
        bytes32[] states;
        uint128[] vaultShort;
        uint128[] lastGoodIndex;
        uint256[] hedgeUnits;
        bytes32[] routes;
    }

    struct Plan {
        string mode;
        address engine;
        address vault;
        address usdg;
        address factory;
        uint32 window;
        uint64 offHoursBuyMaxAge;
        address sequencerFeed;
        uint256 minCardinality;
        bool increaseCardinality;
        address newEngineImpl;
        address newVaultImpl;
        address twap;
        address lens;
        address oldEngineImpl;
        address oldVaultImpl;
    }

    Deployment private _d;
    Plan private _p;
    address[] private _targets;
    bytes[] private _payloads;
    string[] private _labels;

    function run() external {
        Deployment memory d = loadDeployment();
        _d.engine = d.engine;
        _d.vault = d.vault;
        _d.usdg = d.usdg;
        _d.hedgeAdapter = d.hedgeAdapter;
        _d.admin = d.admin;

        _plan(d);
        _logPools();

        if (_eq(_p.mode, "direct")) _direct();
        else if (_eq(_p.mode, "timelock")) _timelock();
        else revert("UpgradeV2: UPGRADE_MODE must be direct or timelock");
    }

    // ---------------------------------------------------------------- planning and guards

    function _plan(Deployment memory d) private {
        _p.mode = vm.envString("UPGRADE_MODE");
        _p.engine = d.engine;
        _p.vault = d.vault;
        _p.usdg = d.usdg;
        require(_p.usdg != address(0), "UpgradeV2: USDG unknown");
        require(address(IPowerEngine(_p.engine).usdg()) == _p.usdg, "UpgradeV2: engine.usdg() != USDG");
        require(address(IPowerEngine(_p.engine).vault()) == _p.vault, "UpgradeV2: engine.vault() != VAULT");

        _p.oldEngineImpl = vm.envOr("EXPECTED_ENGINE_IMPL", d.engineImpl);
        _p.oldVaultImpl = vm.envOr("EXPECTED_VAULT_IMPL", d.vaultImpl);
        require(_p.oldEngineImpl != address(0), "UpgradeV2: EXPECTED_ENGINE_IMPL required");
        require(_p.oldVaultImpl != address(0), "UpgradeV2: EXPECTED_VAULT_IMPL required");
        require(
            implementationOf(_p.engine) == _p.oldEngineImpl,
            string.concat("UpgradeV2: engine implementation is ", vm.toString(implementationOf(_p.engine)))
        );
        require(
            implementationOf(_p.vault) == _p.oldVaultImpl,
            string.concat("UpgradeV2: vault implementation is ", vm.toString(implementationOf(_p.vault)))
        );

        _p.factory = uniswapFactory(d.hedgeAdapter);
        require(_p.factory != address(0) && _p.factory.code.length != 0, "UpgradeV2: Uniswap v3 factory not found");
        uint256 window = vm.envOr("TWAP_WINDOW", DEFAULT_WINDOW);
        require(window >= 60 && window <= type(uint32).max, "UpgradeV2: TWAP_WINDOW out of range");
        _p.window = uint32(window);
        uint256 maxAge = vm.envOr("OFF_HOURS_BUY_MAX_AGE", DEFAULT_OFF_HOURS_BUY_MAX_AGE);
        require(maxAge <= type(uint64).max, "UpgradeV2: OFF_HOURS_BUY_MAX_AGE too large");
        _p.offHoursBuyMaxAge = uint64(maxAge);
        _p.minCardinality = vm.envOr("MIN_OBSERVATION_CARDINALITY", window + 1);
        require(_p.minCardinality <= type(uint16).max, "UpgradeV2: MIN_OBSERVATION_CARDINALITY too large");
        _p.increaseCardinality = vm.envOr("INCREASE_CARDINALITY", false);

        _p.sequencerFeed = vm.envOr("SEQUENCER_FEED", address(0));
        if (_p.sequencerFeed != address(0)) {
            require(_p.sequencerFeed.code.length != 0, "UpgradeV2: SEQUENCER_FEED has no code");
            (, int256 answer, uint256 startedAt,,) = IAggregatorV3(_p.sequencerFeed).latestRoundData();
            require(answer == 0 && startedAt != 0, "UpgradeV2: SEQUENCER_FEED does not report the sequencer up");
        }

        _p.newEngineImpl = vm.envOr("NEW_ENGINE_IMPL", address(0));
        _p.newVaultImpl = vm.envOr("NEW_VAULT_IMPL", address(0));
        _p.twap = vm.envOr("TWAP_REFERENCE", address(0));
        // The lens is stateless and ownerless; a fresh one keeps the deployed lens identical to this source.
        _p.lens = vm.envOr("NEW_LENS", address(0));

        console2.log("== UpgradeV2 mode", _p.mode, "chain", block.chainid);
        console2.log("  engine", _p.engine, "impl", _p.oldEngineImpl);
        console2.log("  vault ", _p.vault, "impl", _p.oldVaultImpl);
        console2.log("  uniswap factory", _p.factory, "twap window", _p.window);
        console2.log("  offHoursBuyMaxAge", _p.offHoursBuyMaxAge);
        console2.log("  sequencerFeed", _p.sequencerFeed);
    }

    /// @dev Deploys what was not supplied through NEW_ENGINE_IMPL / NEW_VAULT_IMPL / TWAP_REFERENCE / NEW_LENS (the lens
    /// is skipped with DEPLOY_LENS=0). Must run inside a broadcast.
    function _deploy() private {
        if (_p.newEngineImpl == address(0)) _p.newEngineImpl = address(new PowerEngine());
        if (_p.newVaultImpl == address(0)) _p.newVaultImpl = address(new CrabVault());
        if (_p.twap == address(0)) {
            _p.twap = address(new UniswapV3TwapReference(IUniswapV3FactoryLike(_p.factory), _p.usdg, _p.window));
        }
        if (_p.lens == address(0) && vm.envOr("DEPLOY_LENS", true)) _p.lens = address(new OgeeLens());
    }

    function _validateDeployed() private view {
        _requireImpl(_p.newEngineImpl, "new engine implementation");
        _requireImpl(_p.newVaultImpl, "new vault implementation");
        require(_p.newEngineImpl != _p.oldEngineImpl && _p.newVaultImpl != _p.oldVaultImpl, "UpgradeV2: same impl");
        UniswapV3TwapReference twap = UniswapV3TwapReference(_p.twap);
        require(_p.twap.code.length != 0, "UpgradeV2: TWAP reference has no code");
        require(
            address(twap.factory()) == _p.factory && twap.usdg() == _p.usdg && twap.window() == _p.window,
            "UpgradeV2: TWAP reference factory/usdg/window mismatch"
        );
        console2.log("  new engine impl", _p.newEngineImpl);
        console2.log("  new vault impl ", _p.newVaultImpl);
        console2.log("  twap reference ", _p.twap);
        if (_p.lens != address(0)) {
            require(_p.lens.code.length != 0, "UpgradeV2: lens has no code");
            // Point the deployment file (contracts.lens), the API config and the README at this address.
            console2.log("  new lens       ", _p.lens);
        }
    }

    function _requireImpl(address impl, string memory name) private view {
        require(impl.code.length != 0, string.concat("UpgradeV2: ", name, " has no code"));
        require(
            IUUPSOps(impl).proxiableUUID() == IMPLEMENTATION_SLOT,
            string.concat("UpgradeV2: ", name, " is not UUPS")
        );
        require(initializersDisabled(impl), string.concat("UpgradeV2: ", name, " initializers not disabled"));
    }

    // ---------------------------------------------------------------- direct mode

    function _direct() private {
        address admin = msg.sender;
        if (_d.admin != address(0)) require(admin == _d.admin, "UpgradeV2: sender is not ADMIN");
        require(
            IPowerEngine(_p.engine).hasRole(DEFAULT_ADMIN_ROLE, admin)
                && ICrabVault(_p.vault).hasRole(DEFAULT_ADMIN_ROLE, admin),
            "UpgradeV2: sender lacks DEFAULT_ADMIN_ROLE on engine and vault"
        );
        console2.log("  admin (sender)", admin);

        Snapshot memory before = _snapshot();

        vm.startBroadcast();
        _deploy();
        IUUPSOps(_p.engine).upgradeToAndCall(_p.newEngineImpl, "");
        IUUPSOps(_p.vault).upgradeToAndCall(_p.newVaultImpl, "");
        vm.stopBroadcast();

        _validateDeployed();
        require(implementationOf(_p.engine) == _p.newEngineImpl, "UpgradeV2: engine slot not updated");
        require(implementationOf(_p.vault) == _p.newVaultImpl, "UpgradeV2: vault slot not updated");
        _compare(before, _snapshot());

        _buildConfigCalls();
        vm.startBroadcast();
        for (uint256 i; i < _targets.length; ++i) {
            (bool ok, bytes memory ret) = _targets[i].call(_payloads[i]);
            if (!ok) _bubble(ret, _labels[i]);
        }
        _increaseCardinality();
        vm.stopBroadcast();

        _verifyConfigured(before);
        _writeOutput(address(0), 0, bytes32(0), bytes32(0));
    }

    // ---------------------------------------------------------------- timelock mode

    function _timelock() private {
        address timelock = vm.envAddress("TIMELOCK");
        require(timelock.code.length != 0, "UpgradeV2: TIMELOCK has no code");
        TimelockController tl = TimelockController(payable(timelock));
        uint256 minDelay = tl.getMinDelay();
        uint256 delay = vm.envOr("TIMELOCK_DELAY", minDelay);
        require(delay >= minDelay, "UpgradeV2: TIMELOCK_DELAY below the timelock minimum");

        Snapshot memory before = _snapshot();

        vm.startBroadcast();
        _deploy();
        _increaseCardinality();
        vm.stopBroadcast();
        _validateDeployed();

        _targets.push(_p.engine);
        _payloads.push(abi.encodeCall(IUUPSOps.upgradeToAndCall, (_p.newEngineImpl, "")));
        _labels.push("engine.upgradeToAndCall");
        _targets.push(_p.vault);
        _payloads.push(abi.encodeCall(IUUPSOps.upgradeToAndCall, (_p.newVaultImpl, "")));
        _labels.push("vault.upgradeToAndCall");
        _buildConfigCalls();

        bytes32 predecessor = vm.envOr("TIMELOCK_PREDECESSOR", bytes32(0));
        bytes32 salt = vm.envOr(
            "TIMELOCK_SALT", keccak256(abi.encode("ogee.upgrade-v2", _p.newEngineImpl, _p.newVaultImpl, _p.twap))
        );
        uint256[] memory values = new uint256[](_targets.length);
        bytes32 id = tl.hashOperationBatch(_targets, values, _payloads, predecessor, salt);
        console2.log("  timelock", timelock, "delay", delay);
        console2.log("  operation id");
        console2.logBytes32(id);

        _writeOutput(timelock, delay, predecessor, salt);

        if (!vm.envOr("SIMULATE_BATCH", true)) return;
        if (
            !IPowerEngine(_p.engine).hasRole(DEFAULT_ADMIN_ROLE, timelock)
                || !ICrabVault(_p.vault).hasRole(DEFAULT_ADMIN_ROLE, timelock)
        ) {
            console2.log("  [WARN] timelock lacks DEFAULT_ADMIN_ROLE on engine/vault: batch not simulated");
            return;
        }
        _simulateBatch(tl, values, predecessor, salt, delay, before);
    }

    /// @dev Local-only: pranked calls and warps are never broadcast.
    function _simulateBatch(
        TimelockController tl,
        uint256[] memory values,
        bytes32 predecessor,
        bytes32 salt,
        uint256 delay,
        Snapshot memory before
    ) private {
        address timelock = address(tl);
        // 1) storage compatibility: the two upgrade calls alone must leave all state unchanged.
        uint256 snap = vm.snapshotState();
        vm.startPrank(timelock);
        IUUPSOps(_p.engine).upgradeToAndCall(_p.newEngineImpl, "");
        IUUPSOps(_p.vault).upgradeToAndCall(_p.newVaultImpl, "");
        vm.stopPrank();
        _compare(before, _snapshot());
        vm.revertToState(snap);

        // 2) the exact batch through schedule + execute, as the Safe will do it.
        address proposer = vm.envOr("SAFE", address(0));
        if (proposer == address(0) || !tl.hasRole(tl.PROPOSER_ROLE(), proposer)) {
            proposer = address(uint160(uint256(keccak256("ogee.simulated-proposer"))));
            vm.prank(timelock);
            tl.grantRole(tl.PROPOSER_ROLE(), proposer);
            vm.prank(timelock);
            tl.grantRole(tl.EXECUTOR_ROLE(), proposer);
        }
        vm.prank(proposer);
        tl.scheduleBatch(_targets, values, _payloads, predecessor, salt, delay);
        vm.warp(block.timestamp + delay);
        vm.prank(proposer);
        tl.executeBatch(_targets, values, _payloads, predecessor, salt);
        require(implementationOf(_p.engine) == _p.newEngineImpl, "UpgradeV2: batch did not upgrade the engine");
        require(implementationOf(_p.vault) == _p.newVaultImpl, "UpgradeV2: batch did not upgrade the vault");
        _verifyConfigured(before);
        console2.log("  [PASS] batch simulated through scheduleBatch + executeBatch");
    }

    // ---------------------------------------------------------------- configuration

    function _buildConfigCalls() private {
        IPowerEngine engine = IPowerEngine(_p.engine);
        uint8 count = engine.marketCount();
        for (uint8 id; id < count; ++id) {
            MarketConfig memory cfg = engine.getConfig(id);
            uint64 target = _maxAgeFor(id);
            if (cfg.offHoursBuyMaxAge == target) continue;
            cfg.offHoursBuyMaxAge = target;
            _targets.push(_p.engine);
            _payloads.push(abi.encodeCall(IPowerEngine.setMarketConfig, (id, cfg)));
            _labels.push(string.concat("engine.setMarketConfig(", vm.toString(id), ")"));
        }
        _targets.push(_p.vault);
        _payloads.push(abi.encodeCall(ICrabVault.setPriceReference, (IPriceReference(_p.twap))));
        _labels.push("vault.setPriceReference");
        if (_p.sequencerFeed != address(0)) {
            _targets.push(_p.engine);
            _payloads.push(
                abi.encodeCall(
                    IPowerEngine.setGlobal,
                    (engine.maxGlobalExposureBps(), engine.protocolFeeShareBps(), engine.treasury(), _p.sequencerFeed)
                )
            );
            _labels.push("engine.setGlobal(sequencerFeed)");
        }
    }

    function _maxAgeFor(uint8 id) private view returns (uint64) {
        uint256 v = vm.envOr(string.concat("OFF_HOURS_BUY_MAX_AGE_", vm.toString(id)), uint256(_p.offHoursBuyMaxAge));
        require(v <= type(uint64).max, "UpgradeV2: per-market max age too large");
        return uint64(v);
    }

    function _verifyConfigured(Snapshot memory before) private view {
        IPowerEngine engine = IPowerEngine(_p.engine);
        require(engine.marketCount() == before.marketCount, "UpgradeV2: marketCount changed");
        for (uint8 id; id < before.marketCount; ++id) {
            MarketConfig memory cfg = engine.getConfig(id);
            require(cfg.offHoursBuyMaxAge == _maxAgeFor(id), "UpgradeV2: offHoursBuyMaxAge not applied");
            cfg.offHoursBuyMaxAge = 0;
            require(keccak256(abi.encode(cfg)) == before.configs[id], "UpgradeV2: config drifted");
        }
        require(address(ICrabVault(_p.vault).priceReference()) == _p.twap, "UpgradeV2: priceReference not set");
        address expectedSeq = _p.sequencerFeed != address(0) ? _p.sequencerFeed : before.sequencerFeed;
        require(address(engine.sequencerFeed()) == expectedSeq, "UpgradeV2: sequencerFeed mismatch");
        require(engine.maxGlobalExposureBps() == before.maxGlobalExposureBps, "UpgradeV2: maxGlobalExposureBps changed");
        require(engine.protocolFeeShareBps() == before.protocolFeeShareBps, "UpgradeV2: protocolFeeShareBps changed");
        require(engine.treasury() == before.treasury, "UpgradeV2: treasury changed");
        console2.log("  [PASS] V2 configuration applied; other config fields unchanged");

        for (uint8 id; id < before.marketCount; ++id) {
            MarketConfig memory cfg = engine.getConfig(id);
            (, uint24 fee) = ICrabVault(_p.vault).routeForMarket(id);
            uint256 ref = IPriceReference(_p.twap).referencePrice(address(cfg.stock), fee);
            (uint256 spot,,) = engine.spotPrice(id);
            console2.log("  market", id);
            console2.log("    twap reference / feed spot (wad)", ref, spot);
            if (ref == 0) console2.log("    [WARN] TWAP unavailable for this pool (observation history too short?)");
        }
    }

    // ---------------------------------------------------------------- pools

    function _logPools() private view {
        IPowerEngine engine = IPowerEngine(_p.engine);
        uint8 count = engine.marketCount();
        for (uint8 id; id < count; ++id) {
            (, uint24 fee) = ICrabVault(_p.vault).routeForMarket(id);
            address pool = poolOf(_p.factory, address(engine.getConfig(id).stock), _p.usdg, fee);
            (uint16 card, uint16 next) = cardinalityOf(pool);
            console2.log("  market", id, "pool", pool);
            console2.log("    observation cardinality / next", card, next);
            if (next < _p.minCardinality) {
                console2.log(
                    _p.increaseCardinality
                        ? "    below MIN_OBSERVATION_CARDINALITY: will call increaseObservationCardinalityNext"
                        : "    [WARN] below MIN_OBSERVATION_CARDINALITY (set INCREASE_CARDINALITY=1 to grow it)",
                    _p.minCardinality
                );
            }
        }
    }

    /// @dev Permissionless; the broadcaster pays for the new observation slots. Must run inside a broadcast.
    function _increaseCardinality() private {
        if (!_p.increaseCardinality) return;
        IPowerEngine engine = IPowerEngine(_p.engine);
        uint8 count = engine.marketCount();
        for (uint8 id; id < count; ++id) {
            (, uint24 fee) = ICrabVault(_p.vault).routeForMarket(id);
            address pool = poolOf(_p.factory, address(engine.getConfig(id).stock), _p.usdg, fee);
            if (pool == address(0)) continue;
            (, uint16 next) = cardinalityOf(pool);
            if (next < _p.minCardinality) {
                IUniswapV3PoolOps(pool).increaseObservationCardinalityNext(uint16(_p.minCardinality));
            }
        }
    }

    // ---------------------------------------------------------------- snapshots

    function _snapshot() private view returns (Snapshot memory s) {
        IPowerEngine engine = IPowerEngine(_p.engine);
        ICrabVault vault = ICrabVault(_p.vault);
        s.marketCount = engine.marketCount();
        s.totalSupply = vault.totalSupply();
        s.usdgBalance = engine.usdg().balanceOf(_p.vault);
        s.maxGlobalExposureBps = engine.maxGlobalExposureBps();
        s.protocolFeeShareBps = engine.protocolFeeShareBps();
        s.treasury = engine.treasury();
        s.sequencerFeed = address(engine.sequencerFeed());
        s.globalBuysPaused = engine.globalBuysPaused();
        s.engineVault = address(engine.vault());
        s.vaultEngine = address(vault.engine());
        s.vaultParams = keccak256(
            abi.encode(
                vault.lockSeconds(),
                vault.cashBufferBps(),
                vault.hedgeRatioBps(),
                vault.rebalanceThresholdBps(),
                vault.maxHedgeSlippageBps(),
                vault.navGuardOpenBps(),
                vault.navGuardClosedBps(),
                vault.minHedgeTradeUsdg(),
                vault.maxTotalDeposits(),
                vault.publicDeposits()
            )
        );
        address admin = msg.sender;
        s.roles = keccak256(
            abi.encode(
                engine.hasRole(DEFAULT_ADMIN_ROLE, admin),
                vault.hasRole(DEFAULT_ADMIN_ROLE, admin),
                _d.admin == address(0) ? false : engine.hasRole(DEFAULT_ADMIN_ROLE, _d.admin),
                _d.admin == address(0) ? false : vault.hasRole(DEFAULT_ADMIN_ROLE, _d.admin)
            )
        );

        uint256 n = s.marketCount;
        s.configs = new bytes32[](n);
        s.states = new bytes32[](n);
        s.vaultShort = new uint128[](n);
        s.lastGoodIndex = new uint128[](n);
        s.hedgeUnits = new uint256[](n);
        s.routes = new bytes32[](n);
        for (uint8 id; id < n; ++id) {
            MarketConfig memory cfg = engine.getConfig(id);
            cfg.offHoursBuyMaxAge = 0; // the one field V2 changes; hashed without it
            s.configs[id] = keccak256(abi.encode(cfg));
            s.states[id] = keccak256(abi.encode(engine.getState(id)));
            s.vaultShort[id] = engine.getState(id).vaultShort;
            s.lastGoodIndex[id] = engine.getState(id).lastGoodIndex;
            s.hedgeUnits[id] = vault.hedgeUnits(id);
            (IHedgeAdapter adapter, uint24 fee) = vault.routeForMarket(id);
            s.routes[id] = keccak256(abi.encode(adapter, fee));
        }
    }

    function _compare(Snapshot memory a, Snapshot memory b) private pure {
        require(a.marketCount == b.marketCount, "UpgradeV2: marketCount changed across upgrade");
        require(a.totalSupply == b.totalSupply, "UpgradeV2: vault totalSupply changed across upgrade");
        require(a.usdgBalance == b.usdgBalance, "UpgradeV2: vault USDG balance changed across upgrade");
        require(a.maxGlobalExposureBps == b.maxGlobalExposureBps, "UpgradeV2: maxGlobalExposureBps changed");
        require(a.protocolFeeShareBps == b.protocolFeeShareBps, "UpgradeV2: protocolFeeShareBps changed");
        require(a.treasury == b.treasury, "UpgradeV2: treasury changed across upgrade");
        require(a.sequencerFeed == b.sequencerFeed, "UpgradeV2: sequencerFeed changed across upgrade");
        require(a.globalBuysPaused == b.globalBuysPaused, "UpgradeV2: globalBuysPaused changed across upgrade");
        require(a.engineVault == b.engineVault && a.vaultEngine == b.vaultEngine, "UpgradeV2: cross-references changed");
        require(a.vaultParams == b.vaultParams, "UpgradeV2: vault params changed across upgrade");
        require(a.roles == b.roles, "UpgradeV2: roles changed across upgrade");
        for (uint256 i; i < a.marketCount; ++i) {
            require(a.vaultShort[i] == b.vaultShort[i], "UpgradeV2: vaultShort changed across upgrade");
            require(a.lastGoodIndex[i] == b.lastGoodIndex[i], "UpgradeV2: lastGoodIndex changed across upgrade");
            require(a.configs[i] == b.configs[i], "UpgradeV2: market config changed across upgrade");
            require(a.states[i] == b.states[i], "UpgradeV2: market state changed across upgrade");
            require(a.hedgeUnits[i] == b.hedgeUnits[i], "UpgradeV2: hedgeUnits changed across upgrade");
            require(a.routes[i] == b.routes[i], "UpgradeV2: hedge route changed across upgrade");
        }
        console2.log("  [PASS] state identical before and after the upgrade (storage layout compatible)");
    }

    // ---------------------------------------------------------------- output

    function _writeOutput(address timelock, uint256 delay, bytes32 predecessor, bytes32 salt) private {
        string memory calls = "[";
        uint256[] memory values = new uint256[](_targets.length);
        for (uint256 i; i < _targets.length; ++i) {
            if (i != 0) calls = string.concat(calls, ",");
            calls = string.concat(
                calls,
                "\n    {\"target\": \"",
                vm.toString(_targets[i]),
                "\", \"value\": \"0\", \"description\": \"",
                _labels[i],
                "\", \"data\": \"",
                vm.toString(_payloads[i]),
                "\"}"
            );
        }
        calls = string.concat(calls, "\n  ]");

        string memory json = string.concat(
            "{\n  \"chainId\": ",
            vm.toString(block.chainid),
            ",\n  \"mode\": \"",
            _p.mode,
            "\",\n  \"engine\": \"",
            vm.toString(_p.engine),
            "\",\n  \"vault\": \"",
            vm.toString(_p.vault),
            "\",\n  \"previousImplementations\": {\"engine\": \"",
            vm.toString(_p.oldEngineImpl),
            "\", \"vault\": \"",
            vm.toString(_p.oldVaultImpl),
            "\"},\n  \"newImplementations\": {\"engine\": \"",
            vm.toString(_p.newEngineImpl),
            "\", \"vault\": \"",
            vm.toString(_p.newVaultImpl),
            "\", \"twapReference\": \"",
            vm.toString(_p.twap),
            "\"},\n  \"calls\": ",
            calls
        );

        if (timelock != address(0)) {
            bytes memory scheduleData =
                abi.encodeCall(TimelockController.scheduleBatch, (_targets, values, _payloads, predecessor, salt, delay));
            bytes memory executeData =
                abi.encodeCall(TimelockController.executeBatch, (_targets, values, _payloads, predecessor, salt));
            bytes32 id = TimelockController(payable(timelock)).hashOperationBatch(
                _targets, values, _payloads, predecessor, salt
            );
            json = string.concat(
                json,
                ",\n  \"timelock\": {\"address\": \"",
                vm.toString(timelock),
                "\", \"delay\": ",
                vm.toString(delay),
                ", \"predecessor\": \"",
                vm.toString(predecessor),
                "\", \"salt\": \"",
                vm.toString(salt),
                "\", \"operationId\": \"",
                vm.toString(id),
                "\"},\n  \"safeTransactions\": [\n    {\"step\": \"schedule\", \"to\": \"",
                vm.toString(timelock),
                "\", \"value\": \"0\", \"data\": \"",
                vm.toString(scheduleData),
                "\"},\n    {\"step\": \"execute (after the delay)\", \"to\": \"",
                vm.toString(timelock),
                "\", \"value\": \"0\", \"data\": \"",
                vm.toString(executeData),
                "\"}\n  ]"
            );
        }
        json = string.concat(json, "\n}\n");

        string memory path = vm.envOr("BATCH_OUTPUT", string("out/upgrade-v2-batch.json"));
        vm.writeFile(path, json);
        console2.log("  wrote", path);
    }

    // ---------------------------------------------------------------- utils

    function _bubble(bytes memory ret, string memory label) private pure {
        if (ret.length == 0) revert(string.concat("UpgradeV2: ", label, " reverted"));
        assembly ("memory-safe") {
            revert(add(ret, 32), mload(ret))
        }
    }

    function _eq(string memory a, string memory b) private pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
