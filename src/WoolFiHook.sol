// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {BaseHook} from "./base/BaseHook.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {SpreadMath} from "./lib/SpreadMath.sol";
import {IPriceOracle, IPriceOracleMetadata} from "./interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "./interfaces/IMarketHoursOracle.sol";
import {IUnderwritingVault} from "./interfaces/IUnderwritingVault.sol";

/// @dev Minimal interface the hook needs from {WoolFiPositionManager}. Declared inline (rather
///      than imported from the PM module) so the hook doesn't pull in the PM's whole compilation
///      unit — keeps the bytecode size in check.
interface IPmRealizeSink {
    function realizeFromHook(PoolKey calldata key) external;
}

/// @title WoolFiHook
/// @notice Uniswap v4 hook that turns a full-range pool into a pair-trade vehicle by pegging the
///         pool's internal price to an oracle-derived fair price via an asymmetric, drift-scaled fee
///         (PROJECT_SPEC.md §3). Swaps toward fair are discounted; swaps away are surcharged.
/// @dev v1 uses a dynamic LP fee only (dynamic-fee flag + a `beforeSwap` fee override) — it does NOT
///      use `beforeSwapReturnDelta`. One hook serves many pools, parametrized per pool. During equity
///      market closure or a structural-break state, the asymmetric logic is disabled and fees go flat.
contract WoolFiHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using LPFeeLibrary for uint24;

    /// @dev bps -> v4 pip fee units (1 bps = 100 pips).
    uint256 private constant BPS_TO_PIPS = 100;
    /// @dev Hard ceilings for config sanity (governance cannot exceed these).
    uint16 private constant MAX_BASE_FEE_BPS = 1000; // 10%
    uint16 private constant MAX_THRESHOLD_BPS = 10_000; // 100%

    /// @notice Per-pool WoolFi configuration.
    /// @dev Address fields each occupy a slot; the numeric/bool fields are grouped to pack tightly.
    struct WoolFiConfig {
        IPriceOracle oracle0; // price source for token0 (USD, 1e18)
        IPriceOracle oracle1; // price source for token1 (USD, 1e18)
        IMarketHoursOracle marketHours; // address(0) when neither leg is a tokenized equity
        address vault; // per-pool underwriting vault; address(0) = no vault wired
        uint256 cachedFairPriceWad; // immutable recovery target while structurally broken
        uint32 kScaled; // steepness k * BPS (k=4.0 -> 40_000)
        uint32 stabilizationSeconds; // flat-fee/no-add interval after a market opens
        uint32 maxOracleSkew; // max leg timestamp difference; zero disables synchronization
        uint16 baseFeeBps; // base fee in bps (e.g. 30)
        uint16 toleranceBps; // in-band tolerance in bps (e.g. 500)
        uint16 hardThresholdBps; // structural-break threshold in bps (e.g. 1500)
        uint16 drawdownBps; // fraction of the vault to seize on a structural break
        uint8 decimals0;
        uint8 decimals1;
        bool configured;
        bool structuralBreak;
    }

    /// @notice Parameters supplied by governance when authorizing a pool.
    struct AuthParams {
        IPriceOracle oracle0;
        IPriceOracle oracle1;
        IMarketHoursOracle marketHours;
        uint32 kScaled;
        uint16 baseFeeBps;
        uint16 toleranceBps;
        uint16 hardThresholdBps;
    }

    struct SafetyParams {
        uint32 stabilizationSeconds;
        uint32 maxOracleSkew;
    }

    /// @notice Atomic authorization/update shape for pools enabling hook safeguards.
    /// @dev The legacy `AuthParams` entry points remain available and default safeguards to zero.
    struct AuthParamsV2 {
        AuthParams core;
        SafetyParams safety;
    }

    /// @notice Governance address authorized to manage pools and pause. Updatable so control can be
    ///         handed from the v1 multisig/`WoolFiGovernor` to on-chain governance later (spec §7.4).
    address public governor;
    /// @notice Position manager that owns the shared full-range LP position for every WoolFi pool
    ///         this hook serves. When set, the hook pokes its `realizeFromHook` from `afterSwap`
    ///         so vault rewards and buyback cuts route automatically on every trade — no keeper
    ///         needed for the steady state. address(0) until governance wires it (`setPositionManager`).
    address public positionManager;
    /// @notice Global emergency pause. When true, swaps and adds revert.
    bool public paused;

    mapping(PoolId => WoolFiConfig) internal _config;

    event PoolAuthorized(PoolId indexed id, address oracle0, address oracle1, address marketHours);
    event PoolConfigUpdated(PoolId indexed id);
    event SwapProcessed(PoolId indexed id, int256 driftBps, bool asymmetricActive, bool structuralBreakTriggered);
    event StructuralBreakTriggered(PoolId indexed id, int256 driftBps);
    event StructuralBreakResolved(PoolId indexed id);
    event StructuralBreakTargetCached(PoolId indexed id, uint256 fairPriceWad);
    event OracleSkewObserved(PoolId indexed id, uint256 updatedAt0, uint256 updatedAt1, uint32 maxSkew);
    event PoolSafetyUpdated(PoolId indexed id, uint32 stabilizationSeconds, uint32 maxOracleSkew);
    event PausedSet(bool paused);
    event VaultSet(PoolId indexed id, address vault, uint16 drawdownBps);
    event GovernorUpdated(address indexed oldGovernor, address indexed newGovernor);
    event PositionManagerUpdated(address indexed oldPm, address indexed newPm);

    error NotGovernor();
    error Paused();
    error PoolNotConfigured();
    error PoolAlreadyConfigured();
    error NotDynamicFee();
    error InvalidConfig();
    error OutOfBand();
    error MarketClosed();
    error NotStructurallyBroken();
    error NotFullRange();
    error AdversarialSwapDuringBreak();
    error StructuralBreakActive();
    error StabilizationActive(uint256 sessionStart, uint256 endsAt);
    error OracleTimestampSkew(uint256 updatedAt0, uint256 updatedAt1, uint32 maxSkew);

    modifier onlyGovernor() {
        if (msg.sender != governor) revert NotGovernor();
        _;
    }

    constructor(IPoolManager _poolManager, address _governor) BaseHook(_poolManager) {
        if (_governor == address(0)) revert InvalidConfig();
        governor = _governor;
    }

    // --------------------------------------------------------------------
    // Hook permissions
    // --------------------------------------------------------------------

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true, // gate authorization + require dynamic fee
            afterInitialize: false,
            beforeAddLiquidity: true, // enforce in-band deposits
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true, // no-op pass-through (reserved)
            afterRemoveLiquidity: false,
            beforeSwap: true, // apply the asymmetric fee
            afterSwap: true, // structural-break detection
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false, // v1 uses dynamic LP fee, not return-delta
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --------------------------------------------------------------------
    // Governance
    // --------------------------------------------------------------------

    /// @notice Authorize a pool for WoolFi and set its config. Must be called before the pool is
    ///         initialized in the PoolManager (so {beforeInitialize} can validate it).
    function authorizePool(PoolKey calldata key, AuthParams calldata p) external onlyGovernor {
        _authorizePool(key, p, SafetyParams(0, 0));
    }

    /// @notice Authorize a pool and atomically enable its stabilization/skew safeguards.
    function authorizePoolV2(PoolKey calldata key, AuthParamsV2 calldata p) external onlyGovernor {
        _authorizePool(key, p.core, p.safety);
    }

    function _authorizePool(PoolKey calldata key, AuthParams calldata p, SafetyParams memory safety) private {
        PoolId id = key.toId();
        if (_config[id].configured) revert PoolAlreadyConfigured();
        if (!key.fee.isDynamicFee()) revert NotDynamicFee();
        _validateParams(p);

        _config[id] = WoolFiConfig({
            oracle0: p.oracle0,
            oracle1: p.oracle1,
            marketHours: p.marketHours,
            vault: address(0),
            cachedFairPriceWad: 0,
            kScaled: p.kScaled,
            stabilizationSeconds: safety.stabilizationSeconds,
            maxOracleSkew: safety.maxOracleSkew,
            baseFeeBps: p.baseFeeBps,
            toleranceBps: p.toleranceBps,
            hardThresholdBps: p.hardThresholdBps,
            drawdownBps: 0,
            decimals0: _decimals(key.currency0),
            decimals1: _decimals(key.currency1),
            configured: true,
            structuralBreak: false
        });

        emit PoolAuthorized(id, address(p.oracle0), address(p.oracle1), address(p.marketHours));
        if (safety.stabilizationSeconds != 0 || safety.maxOracleSkew != 0) {
            emit PoolSafetyUpdated(id, safety.stabilizationSeconds, safety.maxOracleSkew);
        }
    }

    /// @notice Update an authorized pool's tunable parameters.
    function updatePoolConfig(PoolKey calldata key, AuthParams calldata p) external onlyGovernor {
        _updatePoolConfig(key, p);
    }

    /// @notice Update core and safety parameters atomically.
    function updatePoolConfigV2(PoolKey calldata key, AuthParamsV2 calldata p) external onlyGovernor {
        _updatePoolConfig(key, p.core);
        _setPoolSafety(key.toId(), p.safety);
    }

    function _updatePoolConfig(PoolKey calldata key, AuthParams calldata p) private {
        PoolId id = key.toId();
        WoolFiConfig storage c = _config[id];
        if (!c.configured) revert PoolNotConfigured();
        _validateParams(p);

        c.oracle0 = p.oracle0;
        c.oracle1 = p.oracle1;
        c.marketHours = p.marketHours;
        c.kScaled = p.kScaled;
        c.baseFeeBps = p.baseFeeBps;
        c.toleranceBps = p.toleranceBps;
        c.hardThresholdBps = p.hardThresholdBps;

        emit PoolConfigUpdated(id);
    }

    /// @notice Update only post-open stabilization and dual-leg timestamp synchronization.
    function setPoolSafety(PoolKey calldata key, SafetyParams calldata safety) external onlyGovernor {
        PoolId id = key.toId();
        if (!_config[id].configured) revert PoolNotConfigured();
        _setPoolSafety(id, safety);
    }

    function _setPoolSafety(PoolId id, SafetyParams memory safety) private {
        WoolFiConfig storage c = _config[id];
        c.stabilizationSeconds = safety.stabilizationSeconds;
        c.maxOracleSkew = safety.maxOracleSkew;
        emit PoolSafetyUpdated(id, safety.stabilizationSeconds, safety.maxOracleSkew);
    }

    /// @notice Clear a pool's structural-break state, re-enabling the asymmetric fee. Governance-only
    ///         (spec §3.5: a pool only exits break state via an explicit re-authorization).
    function resolveStructuralBreak(PoolKey calldata key) external onlyGovernor {
        PoolId id = key.toId();
        WoolFiConfig storage c = _config[id];
        if (!c.configured) revert PoolNotConfigured();
        if (!c.structuralBreak) revert NotStructurallyBroken();
        c.structuralBreak = false;
        c.cachedFairPriceWad = 0;
        emit StructuralBreakResolved(id);
    }

    /// @notice Set the global emergency pause.
    function setPaused(bool _paused) external onlyGovernor {
        paused = _paused;
        emit PausedSet(_paused);
    }

    /// @notice Hand the governor role to a new address (e.g. v1 multisig -> on-chain governance).
    function setGovernor(address newGovernor) external onlyGovernor {
        if (newGovernor == address(0)) revert InvalidConfig();
        emit GovernorUpdated(governor, newGovernor);
        governor = newGovernor;
    }

    /// @notice Point the hook at its {WoolFiPositionManager}. Once set, every swap's `afterSwap`
    ///         pokes the PM to realize and route accrued fees automatically.
    /// @dev Passing `address(0)` disables auto-realization without removing pools — useful for
    ///      pausing the side effect during a PM upgrade. The PM gate-checks `msg.sender == hook`
    ///      via the pool key, so misconfigured pools can't have their fees siphoned by a wrong
    ///      hook address.
    function setPositionManager(address newPm) external onlyGovernor {
        emit PositionManagerUpdated(positionManager, newPm);
        positionManager = newPm;
    }

    /// @notice Wire (or update) a pool's underwriting vault and the fraction of it seized on a break.
    /// @param vault The per-pool vault (address(0) disables drawdown wiring).
    /// @param drawdownBps Fraction of the vault to seize on a structural break (<= 10_000).
    function setVault(PoolKey calldata key, address vault, uint16 drawdownBps) external onlyGovernor {
        PoolId id = key.toId();
        WoolFiConfig storage c = _config[id];
        if (!c.configured) revert PoolNotConfigured();
        if (drawdownBps > 10_000) revert InvalidConfig();
        c.vault = vault;
        c.drawdownBps = drawdownBps;
        emit VaultSet(id, vault, drawdownBps);
    }

    // --------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------

    /// @notice Read a pool's full WoolFi config.
    function poolConfig(PoolId id) external view returns (WoolFiConfig memory) {
        return _config[id];
    }

    /// @notice Current signed drift (bps) of a pool's price vs. oracle fair price.
    /// @dev Reverts if the pool is unconfigured or an oracle is stale.
    function currentDrift(PoolKey calldata key) external view returns (int256) {
        PoolId id = key.toId();
        WoolFiConfig memory c = _config[id];
        if (!c.configured) revert PoolNotConfigured();
        return _currentDrift(c, id);
    }

    /// @notice Current safety mode and the immutable recovery target for a pool.
    function poolSafetyStatus(PoolKey calldata key)
        external
        view
        returns (bool structurallyBroken, uint256 cachedFairPriceWad, bool stabilizing, bool oracleSkewed)
    {
        PoolId id = key.toId();
        WoolFiConfig memory c = _config[id];
        if (!c.configured) revert PoolNotConfigured();
        structurallyBroken = c.structuralBreak;
        cachedFairPriceWad = c.cachedFairPriceWad;
        if (structurallyBroken || _marketClosed(c)) return (structurallyBroken, cachedFairPriceWad, false, false);
        stabilizing = _stabilizationWindow(c) != 0;
        if (!stabilizing && c.maxOracleSkew != 0) {
            (,,, oracleSkewed) = _oracleFair(c);
        }
    }

    /// @notice Permissionless: recompute drift and flag a structural break (+ trigger drawdown) if
    ///         the pool has crossed the hard threshold but no swap has run since to detect it.
    /// @dev Silent no-op when the pool isn't configured, is paused, is already broken, or the equity
    ///      market is closed (mirrors `afterSwap` gating). Reverts only if an oracle is stale.
    ///      Called by {RebalanceKeeper}; anyone may invoke it.
    function checkStructuralBreak(PoolKey calldata key) external {
        PoolId id = key.toId();
        WoolFiConfig memory c = _config[id];
        if (!c.configured || paused || c.structuralBreak || _marketClosed(c) || _stabilizationWindow(c) != 0) return;
        (uint256 fair,,, bool skewed) = _oracleFair(c);
        if (skewed) return;
        int256 drift = _driftFromFair(c, id, fair);
        _flagBreakIfReached(c, id, drift, fair);
    }

    // --------------------------------------------------------------------
    // Hook callbacks
    // --------------------------------------------------------------------

    /// @dev Only authorized pools may initialize against this hook. The dynamic-fee requirement is
    ///      already guaranteed: {authorizePool} rejects non-dynamic fees, and the poolId (which keys
    ///      the config) includes the fee — so any `configured` pool is necessarily a dynamic-fee pool.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (!_config[key.toId()].configured) revert PoolNotConfigured();
        return IHooks.beforeInitialize.selector;
    }

    /// @dev Compute and override the LP fee from current drift (or flat fee when closed/broken).
    function _beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        internal
        view
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (paused) revert Paused();
        PoolId id = key.toId();
        WoolFiConfig memory c = _config[id];
        if (!c.configured) revert PoolNotConfigured();

        uint256 feeBps;
        if (c.structuralBreak) {
            _requireRuntimeGuards(c);
            _requireCorrectiveBreakSwap(c, id, params.zeroForOne);
            feeBps = c.baseFeeBps;
        } else if (_marketClosed(c) || _stabilizationWindow(c) != 0) {
            // Closed/stabilizing sessions do not require a fresh print, but sequencer/pause
            // failures still hard-revert so flat-fee trading cannot bypass L2 safety.
            _requireRuntimeGuards(c);
            feeBps = c.baseFeeBps;
        } else {
            (uint256 fair,,, bool skewed) = _oracleFair(c);
            if (skewed) {
                feeBps = c.baseFeeBps;
            } else {
                int256 drift = _driftFromFair(c, id, fair);
                if (SpreadMath.isInBand(drift, c.toleranceBps)) {
                    feeBps = c.baseFeeBps;
                } else {
                    bool corrective = (drift > 0 && params.zeroForOne) || (drift < 0 && !params.zeroForOne);
                    feeBps = SpreadMath.asymmetricFee(c.baseFeeBps, drift, c.kScaled, corrective);
                }
            }
        }

        uint24 overrideFee = uint24(feeBps * BPS_TO_PIPS) | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, overrideFee);
    }

    /// @dev Detect structural break from the post-swap price; skip while market closed. Then
    ///      poke the position manager so accrued fees are realized and routed automatically —
    ///      no off-chain keeper needed for steady-state operation. Skipped when the PM isn't
    ///      wired yet, when no LPs exist in the pool, or when the pool isn't configured.
    function _afterSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        PoolId id = key.toId();
        WoolFiConfig memory c = _config[id];

        int256 drift = 0;
        bool asymmetricActive = c.configured && !c.structuralBreak && !_marketClosed(c) && _stabilizationWindow(c) == 0;
        bool triggered = false;
        if (asymmetricActive) {
            (uint256 fair, uint256 updatedAt0, uint256 updatedAt1, bool skewed) = _oracleFair(c);
            if (skewed) {
                asymmetricActive = false;
                emit OracleSkewObserved(id, updatedAt0, updatedAt1, c.maxOracleSkew);
            } else {
                drift = _driftFromFair(c, id, fair);
                triggered = _flagBreakIfReached(c, id, drift, fair);
            }
        }

        // Auto-realize and route fees. We do this AFTER the break check so the structural-break
        // event reflects the pre-routing drift (purer signal for indexers); the routing itself
        // only depends on what's accrued in the v4 position, not on the break state. The PM
        // early-returns when there are no LPs, so this is a cheap no-op on cold pools.
        address pm = positionManager;
        if (pm != address(0) && c.configured) {
            IPmRealizeSink(pm).realizeFromHook(key);
        }

        emit SwapProcessed(id, drift, asymmetricActive, triggered);
        return (IHooks.afterSwap.selector, int128(0));
    }

    /// @dev LPs may only add when the pool is in-band, the market is open, and the position covers
    ///      the **full range** — spec §3.3: WoolFi pools are full-range only, since the hook's drift
    ///      math assumes uniform liquidity across the price domain. The PM always uses full range;
    ///      this guards against direct PoolManager callers attempting a concentrated position.
    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        if (paused) revert Paused();
        PoolId id = key.toId();
        WoolFiConfig memory c = _config[id];
        if (!c.configured) revert PoolNotConfigured();
        if (
            params.tickLower != TickMath.minUsableTick(key.tickSpacing)
                || params.tickUpper != TickMath.maxUsableTick(key.tickSpacing)
        ) revert NotFullRange();
        if (_marketClosed(c)) revert MarketClosed();
        uint256 endsAt = _stabilizationWindow(c);
        if (endsAt != 0) revert StabilizationActive(c.marketHours.currentSessionStart(), endsAt);
        if (c.structuralBreak) revert StructuralBreakActive();
        (uint256 fair, uint256 updatedAt0, uint256 updatedAt1, bool skewed) = _oracleFair(c);
        if (skewed) revert OracleTimestampSkew(updatedAt0, updatedAt1, c.maxOracleSkew);
        if (!SpreadMath.isInBand(_driftFromFair(c, id, fair), c.toleranceBps)) revert OutOfBand();
        return IHooks.beforeAddLiquidity.selector;
    }

    /// @dev No special logic: LPs exit at the current pool ratio (spec §3.4).
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        return IHooks.beforeRemoveLiquidity.selector;
    }

    // --------------------------------------------------------------------
    // Internal helpers
    // --------------------------------------------------------------------

    /// @dev Flags a structural break if drift has crossed the hard threshold, emits the event, and
    ///      triggers vault drawdown when wired. Returns true if a fresh break was just flagged.
    function _flagBreakIfReached(WoolFiConfig memory c, PoolId id, int256 drift, uint256 fair)
        internal
        returns (bool triggered)
    {
        if (SpreadMath.isStructuralBreak(drift, c.hardThresholdBps)) {
            WoolFiConfig storage stored = _config[id];
            stored.structuralBreak = true;
            stored.cachedFairPriceWad = fair;
            triggered = true;
            emit StructuralBreakTriggered(id, drift);
            emit StructuralBreakTargetCached(id, fair);
            if (c.vault != address(0) && c.drawdownBps > 0) {
                IUnderwritingVault(c.vault).drawdown(c.drawdownBps);
            }
        }
    }

    function _currentDrift(WoolFiConfig memory c, PoolId id) internal view returns (int256) {
        uint256 fair;
        if (c.structuralBreak) {
            fair = c.cachedFairPriceWad;
        } else {
            (fair,,,) = _oracleFair(c);
        }
        return _driftFromFair(c, id, fair);
    }

    function _driftFromFair(WoolFiConfig memory c, PoolId id, uint256 fair) internal view returns (int256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(id);
        uint256 pool = SpreadMath.poolPrice(sqrtPriceX96, c.decimals0, c.decimals1);
        return SpreadMath.computeDrift(pool, fair);
    }

    function _oracleFair(WoolFiConfig memory c)
        internal
        view
        returns (uint256 fair, uint256 updatedAt0, uint256 updatedAt1, bool skewed)
    {
        uint256 price0;
        uint256 price1;
        if (c.maxOracleSkew == 0) {
            price0 = c.oracle0.getPrice();
            price1 = c.oracle1.getPrice();
        } else {
            (price0, updatedAt0) = IPriceOracleMetadata(address(c.oracle0)).getPriceData();
            (price1, updatedAt1) = IPriceOracleMetadata(address(c.oracle1)).getPriceData();
            uint256 difference = updatedAt0 > updatedAt1 ? updatedAt0 - updatedAt1 : updatedAt1 - updatedAt0;
            skewed = difference > c.maxOracleSkew;
        }
        fair = SpreadMath.fairPrice(price0, price1);
    }

    function _requireRuntimeGuards(WoolFiConfig memory c) internal view {
        c.oracle0.requireRuntimeGuards();
        c.oracle1.requireRuntimeGuards();
    }

    function _requireCorrectiveBreakSwap(WoolFiConfig memory c, PoolId id, bool zeroForOne) internal view {
        int256 drift = _driftFromFair(c, id, c.cachedFairPriceWad);
        // At the exact target either direction is allowed so recovery cannot deadlock on rounding.
        if (drift == 0) return;
        bool corrective = (drift > 0 && zeroForOne) || (drift < 0 && !zeroForOne);
        if (!corrective) revert AdversarialSwapDuringBreak();
    }

    function _marketClosed(WoolFiConfig memory c) internal view returns (bool) {
        return address(c.marketHours) != address(0) && !c.marketHours.isMarketOpen();
    }

    /// @return endsAt End of the active stabilization interval, or zero when inactive.
    function _stabilizationWindow(WoolFiConfig memory c) internal view returns (uint256 endsAt) {
        if (c.stabilizationSeconds == 0 || address(c.marketHours) == address(0)) return 0;
        uint256 sessionStart = c.marketHours.currentSessionStart();
        if (sessionStart == 0 || block.timestamp < sessionStart) return 0;
        endsAt = sessionStart + c.stabilizationSeconds;
        if (block.timestamp >= endsAt) return 0;
    }

    function _decimals(Currency currency) internal view returns (uint8) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return 18; // native currency
        return IERC20Metadata(token).decimals();
    }

    function _validateParams(AuthParams calldata p) private pure {
        if (address(p.oracle0) == address(0) || address(p.oracle1) == address(0)) revert InvalidConfig();
        if (p.baseFeeBps == 0 || p.baseFeeBps > MAX_BASE_FEE_BPS) revert InvalidConfig();
        if (p.kScaled == 0) revert InvalidConfig();
        if (p.toleranceBps >= p.hardThresholdBps) revert InvalidConfig();
        if (p.hardThresholdBps > MAX_THRESHOLD_BPS) revert InvalidConfig();
    }
}
