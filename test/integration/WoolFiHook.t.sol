// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";

import {Currency} from "v4-core/src/types/Currency.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {BaseHook} from "../../src/base/BaseHook.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {STRAND} from "../../src/STRAND.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

/// @notice Integration tests for WoolFiHook against a real v4 PoolManager.
/// @dev Uses two 18-decimal test currencies; decimal-normalization is covered separately in the
///      SpreadMath unit tests. Fee behavior is asserted by comparing swap outputs, never by reading
///      incidental internals — the property tested is the protocol's intended economics.
contract WoolFiHookTest is Deployers {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;

    WoolFiHook hook;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;

    PoolKey poolKey;
    PoolId poolId;

    // fair-price perturbations (oracle1 fixed at $1) chosen so |drift| ≈ 800 bps:
    // pool price is 1.0, so fair = 1/(1±0.08) yields ±800 bps drift.
    uint256 constant FAIR_DRIFT_POS_800 = 925_925_925_925_925_926; // drift +800 (pool above fair)
    uint256 constant FAIR_DRIFT_NEG_800 = 1_086_956_521_739_130_435; // drift -800 (pool below fair)
    int256 constant EXACT_IN = -1e15;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // Deploy the hook to an address whose low bits encode exactly its permissions.
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4444) << 144));
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(this)), hookAddr);
        hook = WoolFiHook(hookAddr);

        oracle0 = new MockPriceOracle(1e18);
        oracle1 = new MockPriceOracle(1e18);
        marketHours = new MockMarketHours(true);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();

        // Governance (this test) authorizes the pool before it is initialized.
        hook.authorizePool(poolKey, _params(marketHours));

        manager.initialize(poolKey, SQRT_PRICE_1_1); // price 1.0 -> in band at fair 1.0

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _params(MockMarketHours mh) internal view returns (WoolFiHook.AuthParams memory) {
        return WoolFiHook.AuthParams({
            oracle0: oracle0,
            oracle1: oracle1,
            marketHours: mh,
            kScaled: 40_000, // k = 4.0
            baseFeeBps: 30,
            toleranceBps: 500,
            hardThresholdBps: 1500
        });
    }

    // -----------------------------------------------------------------
    // initialization / authorization gating
    // -----------------------------------------------------------------

    function test_authorize_setsConfig() public view {
        WoolFiHook.WoolFiConfig memory c = hook.poolConfig(poolId);
        assertTrue(c.configured);
        assertEq(c.baseFeeBps, 30);
        assertEq(c.decimals0, 18);
        assertEq(c.decimals1, 18);
    }

    /// @dev Revert-path tests call the callback directly as the PoolManager. The PoolManager wraps
    ///      hook reverts in `WrappedError`, which hides the specific error; calling the gate directly
    ///      lets us assert the exact error the hook raises (CLAUDE.md: assert specific reverts).
    function testRevert_initialize_unauthorizedPool() public {
        PoolKey memory k = poolKey;
        k.tickSpacing = 30; // different pool id, never authorized
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.PoolNotConfigured.selector);
        hook.beforeInitialize(address(this), k, SQRT_PRICE_1_1);
    }

    function testRevert_authorize_staticFee() public {
        PoolKey memory k = poolKey;
        k.fee = 3000; // static fee, not the dynamic flag
        vm.expectRevert(WoolFiHook.NotDynamicFee.selector);
        hook.authorizePool(k, _params(marketHours));
    }

    function testRevert_authorize_notGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        hook.authorizePool(poolKey, _params(marketHours));
    }

    // -----------------------------------------------------------------
    // the core mechanic: asymmetric fee
    // -----------------------------------------------------------------

    /// @notice For the SAME swap direction at equal |drift|, an adversarial swap must cost more
    ///         (yield less output) than a corrective one. This isolates the fee from price impact.
    function test_swap_outOfBand_adversarialCostsMoreThanCorrective() public {
        uint256 snap = vm.snapshotState();

        // pool above fair (drift +800): a zeroForOne swap pushes price down -> corrective
        oracle0.setPrice(FAIR_DRIFT_POS_800);
        int128 outCorrective = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();

        vm.revertToState(snap);

        // pool below fair (drift -800): the same zeroForOne swap pushes price further down -> adversarial
        oracle0.setPrice(FAIR_DRIFT_NEG_800);
        int128 outAdversarial = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();

        assertGt(outCorrective, outAdversarial);
    }

    /// @notice In band, the fee is flat: same-direction swaps at small +/- drift give equal output.
    function test_swap_inBand_isFlat() public {
        uint256 snap = vm.snapshotState();
        oracle0.setPrice(960_000_000_000_000_000); // drift ~+417 bps, in band
        int128 outA = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();
        vm.revertToState(snap);
        oracle0.setPrice(1_040_000_000_000_000_000); // drift ~-385 bps, in band
        int128 outB = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();
        assertEq(outA, outB);
    }

    /// @notice With the equity market closed, the asymmetric logic is disabled: identical output
    ///         regardless of drift sign (contrast with {test_swap_outOfBand_...}).
    function test_swap_marketClosed_isFlat() public {
        marketHours.setOpen(false);
        uint256 snap = vm.snapshotState();
        oracle0.setPrice(FAIR_DRIFT_POS_800);
        int128 outA = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();
        vm.revertToState(snap);
        oracle0.setPrice(FAIR_DRIFT_NEG_800);
        int128 outB = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();
        assertEq(outA, outB);
    }

    function test_swap_marketClosed_allowsStalePrice() public {
        marketHours.setOpen(false);
        oracle0.setStale(true);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
    }

    function testRevert_swap_marketClosed_runtimeUnsafe() public {
        marketHours.setOpen(false);
        oracle0.setRuntimeUnsafe(true);
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(MockPriceOracle.MockRuntimeUnsafe.selector);
        hook.beforeSwap(address(this), poolKey, p, ZERO_BYTES);
    }

    // -----------------------------------------------------------------
    // structural break
    // -----------------------------------------------------------------

    function test_structuralBreak_isCorrectiveOnly_usesCachedFair_thenResolves() public {
        oracle0.setPrice(1.2e18); // fair 1.2, pool 1.0 -> drift ~-1667 bps (beyond 1500 threshold)
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        WoolFiHook.WoolFiConfig memory broken = hook.poolConfig(poolId);
        assertTrue(broken.structuralBreak);
        assertEq(broken.cachedFairPriceWad, 1.2e18);

        // Live feeds are irrelevant during recovery, even when unusable.
        oracle0.setPrice(10e18);
        oracle0.setStale(true);
        IPoolManager.SwapParams memory adversarial =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.AdversarialSwapDuringBreak.selector);
        hook.beforeSwap(address(this), poolKey, adversarial, ZERO_BYTES);

        // Pool is below cached fair, so one-for-zero is corrective and remains available.
        swap(poolKey, false, EXACT_IN, ZERO_BYTES);

        hook.resolveStructuralBreak(poolKey);
        WoolFiHook.WoolFiConfig memory resolved = hook.poolConfig(poolId);
        assertFalse(resolved.structuralBreak);
        assertEq(resolved.cachedFairPriceWad, 0);
    }

    function testRevert_structuralBreak_runtimeUnsafeBlocksCorrectiveSwap() public {
        oracle0.setPrice(1.2e18);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        assertTrue(hook.poolConfig(poolId).structuralBreak);

        oracle0.setRuntimeUnsafe(true);
        IPoolManager.SwapParams memory corrective =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(MockPriceOracle.MockRuntimeUnsafe.selector);
        hook.beforeSwap(address(this), poolKey, corrective, ZERO_BYTES);
    }

    function test_structuralBreak_statusAndCurrentDrift_doNotReadLiveOracle() public {
        oracle0.setPrice(1.2e18);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        oracle0.setStale(true);

        (bool broken, uint256 cachedFair, bool stabilizing, bool skewed) = hook.poolSafetyStatus(poolKey);
        assertTrue(broken);
        assertEq(cachedFair, 1.2e18);
        assertFalse(stabilizing);
        assertFalse(skewed);
        assertLt(hook.currentDrift(poolKey), 0);
    }

    function test_structuralBreak_correctionCanCrossFair_thenDirectionFlips() public {
        oracle0.setPrice(1.2e18);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        assertLt(hook.currentDrift(poolKey), 0);

        // A corrective trade may cross the cached target; recovery remains live in reverse.
        swap(poolKey, false, -20e18, ZERO_BYTES);
        assertGt(hook.currentDrift(poolKey), 0);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);

        IPoolManager.SwapParams memory nowAdversarial =
            IPoolManager.SwapParams({zeroForOne: false, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MAX_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.AdversarialSwapDuringBreak.selector);
        hook.beforeSwap(address(this), poolKey, nowAdversarial, ZERO_BYTES);
    }

    function testRevert_addLiquidity_duringStructuralBreak() public {
        oracle0.setPrice(1.2e18);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.StructuralBreakActive.selector);
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    function test_removeLiquidity_allowedDuringBreak_withStaleOracle() public {
        oracle0.setPrice(1.2e18);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        oracle0.setStale(true);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: -1e18, salt: 0}),
            ZERO_BYTES
        );
    }

    function testRevert_resolveStructuralBreak_notBroken() public {
        vm.expectRevert(WoolFiHook.NotStructurallyBroken.selector);
        hook.resolveStructuralBreak(poolKey);
    }

    // -----------------------------------------------------------------
    // pause / staleness revert paths
    // -----------------------------------------------------------------

    function testRevert_swap_whenPaused() public {
        hook.setPaused(true);
        IPoolManager.SwapParams memory sp =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.Paused.selector);
        hook.beforeSwap(address(this), poolKey, sp, ZERO_BYTES);
    }

    function testRevert_swap_whenOracleStale() public {
        oracle0.setStale(true);
        IPoolManager.SwapParams memory sp =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(MockPriceOracle.MockStale.selector);
        hook.beforeSwap(address(this), poolKey, sp, ZERO_BYTES);
    }

    // -----------------------------------------------------------------
    // add-liquidity guards
    // -----------------------------------------------------------------

    function testRevert_addLiquidity_outOfBand() public {
        oracle0.setPrice(FAIR_DRIFT_NEG_800); // out of band
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.OutOfBand.selector);
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    function testRevert_addLiquidity_marketClosed() public {
        marketHours.setOpen(false);
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.MarketClosed.selector);
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    /// @notice The hook rejects a non-full-range add (spec §3.3) — protects the uniform-liquidity
    ///         assumption from direct PoolManager callers that bypass the PM.
    function testRevert_addLiquidity_notFullRange() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.NotFullRange.selector);
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    /// @dev LPs may always exit at the current ratio, even out of band (spec §3.4) — unlike adds.
    function test_removeLiquidity_allowedEvenOutOfBand() public {
        oracle0.setPrice(FAIR_DRIFT_NEG_800);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: -50e18, salt: 0
            }),
            ZERO_BYTES
        );
    }

    function testRevert_callback_notPoolManager() public {
        IPoolManager.SwapParams memory sp =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), poolKey, sp, ZERO_BYTES);
    }

    // -----------------------------------------------------------------
    // governance: views, updates, access control
    // -----------------------------------------------------------------

    function test_currentDrift_reflectsOraclePrice() public {
        assertEq(hook.currentDrift(poolKey), 0); // fair 1.0, pool 1.0
        oracle0.setPrice(FAIR_DRIFT_NEG_800);
        assertLt(hook.currentDrift(poolKey), 0); // pool below fair
    }

    function testRevert_currentDrift_notConfigured() public {
        vm.expectRevert(WoolFiHook.PoolNotConfigured.selector);
        hook.currentDrift(_freshKey());
    }

    function test_updatePoolConfig_updatesParams() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.baseFeeBps = 50;
        hook.updatePoolConfig(poolKey, p);
        assertEq(hook.poolConfig(poolId).baseFeeBps, 50);
    }

    function testRevert_updatePoolConfig_notGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        hook.updatePoolConfig(poolKey, _params(marketHours));
    }

    function testRevert_updatePoolConfig_notConfigured() public {
        vm.expectRevert(WoolFiHook.PoolNotConfigured.selector);
        hook.updatePoolConfig(_freshKey(), _params(marketHours));
    }

    function testRevert_authorize_alreadyConfigured() public {
        vm.expectRevert(WoolFiHook.PoolAlreadyConfigured.selector);
        hook.authorizePool(poolKey, _params(marketHours));
    }

    function testRevert_setPaused_notGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        hook.setPaused(true);
    }

    function testRevert_resolveStructuralBreak_notGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        hook.resolveStructuralBreak(poolKey);
    }

    function testRevert_resolveStructuralBreak_notConfigured() public {
        vm.expectRevert(WoolFiHook.PoolNotConfigured.selector);
        hook.resolveStructuralBreak(_freshKey());
    }

    function testRevert_swap_notConfigured() public {
        IPoolManager.SwapParams memory sp =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.PoolNotConfigured.selector);
        hook.beforeSwap(address(this), _freshKey(), sp, ZERO_BYTES);
    }

    function testRevert_addLiquidity_whenPaused() public {
        hook.setPaused(true);
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.Paused.selector);
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    function testRevert_addLiquidity_notConfigured() public {
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(WoolFiHook.PoolNotConfigured.selector);
        hook.beforeAddLiquidity(address(this), _freshKey(), p, ZERO_BYTES);
    }

    function testRevert_constructor_zeroGovernor() public {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address where = address(flags | (uint160(0x5555) << 144));
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(0)), where);
    }

    // -----------------------------------------------------------------
    // governance: config validation (each is a real misconfiguration guard)
    // -----------------------------------------------------------------

    function testRevert_authorize_zeroOracle0() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.oracle0 = IPriceOracle(address(0));
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePool(_freshKey(), p);
    }

    function testRevert_authorize_zeroOracle1() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.oracle1 = IPriceOracle(address(0));
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePool(_freshKey(), p);
    }

    function testRevert_authorize_zeroBaseFee() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.baseFeeBps = 0;
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePool(_freshKey(), p);
    }

    function testRevert_authorize_baseFeeTooHigh() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.baseFeeBps = 1001; // > MAX_BASE_FEE_BPS (1000)
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePool(_freshKey(), p);
    }

    function testRevert_authorize_zeroK() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.kScaled = 0;
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePool(_freshKey(), p);
    }

    function testRevert_authorize_toleranceGeThreshold() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.toleranceBps = 1500;
        p.hardThresholdBps = 1500; // tolerance must be strictly below threshold
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePool(_freshKey(), p);
    }

    function testRevert_authorize_thresholdTooHigh() public {
        WoolFiHook.AuthParams memory p = _params(marketHours);
        p.hardThresholdBps = 10_001; // > MAX_THRESHOLD_BPS (10_000)
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePool(_freshKey(), p);
    }

    /// @notice Mirror of the asymmetric-fee test for the opposite swap direction (oneForZero), which
    ///         is corrective when the pool is below fair.
    function test_swap_oneForZero_outOfBand_adversarialCostsMore() public {
        uint256 snap = vm.snapshotState();

        // pool below fair (drift -800): a oneForZero swap pushes price up -> corrective
        oracle0.setPrice(FAIR_DRIFT_NEG_800);
        int128 outCorrective = swap(poolKey, false, EXACT_IN, ZERO_BYTES).amount0();

        vm.revertToState(snap);

        // pool above fair (drift +800): the same oneForZero swap pushes price further up -> adversarial
        oracle0.setPrice(FAIR_DRIFT_POS_800);
        int128 outAdversarial = swap(poolKey, false, EXACT_IN, ZERO_BYTES).amount0();

        assertGt(outCorrective, outAdversarial);
    }

    /// @notice A pool with no market-hours oracle (crypto/crypto pair) is never "closed".
    function test_swap_noMarketHoursLeg_neverClosed() public {
        WoolFiHook.AuthParams memory p = _params(MockMarketHours(address(0)));
        hook.updatePoolConfig(poolKey, p);

        // Drive out of band; with no market-hours leg the asymmetric fee stays active and swaps work.
        oracle0.setPrice(FAIR_DRIFT_NEG_800);
        assertLt(hook.currentDrift(poolKey), 0);
        swap(poolKey, false, EXACT_IN, ZERO_BYTES); // corrective oneForZero, no revert
    }

    // -----------------------------------------------------------------
    // market-hours transitions (open -> close -> weekend -> reopen)
    // -----------------------------------------------------------------

    /// @notice Structural-break detection is suppressed while the equity market is closed (incl. over
    ///         a weekend warp) and resumes on reopen — the afterSwap z-score/break gate (spec §6.2).
    function test_marketHoursTransition_breakSuppressedWhileClosed() public {
        oracle0.setPrice(1.2e18); // drift beyond the hard threshold

        // closed: swaps are flat and afterSwap must NOT flag a break
        marketHours.setOpen(false);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        // simulate a weekend: time passes, still closed -> still no break
        skip(2 days);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        // reopen: the same out-of-band condition now triggers the break
        marketHours.setOpen(true);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        assertTrue(hook.poolConfig(poolId).structuralBreak);
    }

    // -----------------------------------------------------------------
    // post-open stabilization and dual-leg timestamp synchronization
    // -----------------------------------------------------------------

    function test_stabilization_usesFlatFees_andSuppressesBreak() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 300, maxOracleSkew: 0}));
        uint256 snap = vm.snapshotState();
        oracle0.setPrice(FAIR_DRIFT_POS_800);
        int128 outA = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();
        vm.revertToState(snap);
        oracle0.setPrice(FAIR_DRIFT_NEG_800);
        int128 outB = swap(poolKey, true, EXACT_IN, ZERO_BYTES).amount1();
        assertEq(outA, outB);

        oracle0.setPrice(1.2e18);
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        assertFalse(hook.poolConfig(poolId).structuralBreak);
    }

    function testRevert_addLiquidity_duringStabilization() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 300, maxOracleSkew: 0}));
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        uint256 sessionStart = marketHours.currentSessionStart();
        vm.prank(address(manager));
        vm.expectRevert(
            abi.encodeWithSelector(WoolFiHook.StabilizationActive.selector, sessionStart, sessionStart + uint256(300))
        );
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    function test_stabilization_boundaryEndsExactly() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 300, maxOracleSkew: 0}));
        skip(300);
        (, uint256 cached, bool stabilizing,) = hook.poolSafetyStatus(poolKey);
        assertEq(cached, 0);
        assertFalse(stabilizing);

        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    function test_stabilization_usesOracleSessionStart_notHookTransition() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 300, maxOracleSkew: 0}));
        marketHours.setOpen(false);
        skip(7 days);
        marketHours.setOpen(true);
        skip(299);
        (,, bool stabilizing,) = hook.poolSafetyStatus(poolKey);
        assertTrue(stabilizing);
        skip(1);
        (,, stabilizing,) = hook.poolSafetyStatus(poolKey);
        assertFalse(stabilizing);
    }

    function test_alwaysOpenPool_ignoresStabilizationSetting() public {
        hook.updatePoolConfig(poolKey, _params(MockMarketHours(address(0))));
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 1 days, maxOracleSkew: 0}));
        (,, bool stabilizing,) = hook.poolSafetyStatus(poolKey);
        assertFalse(stabilizing);
    }

    function test_oracleSkew_usesFlatFees_andSuppressesBreak() public {
        skip(1000);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 60}));
        oracle0.setPriceData(1.2e18, block.timestamp);
        oracle1.setPriceData(1e18, block.timestamp - 61);

        (,,, bool skewed) = hook.poolSafetyStatus(poolKey);
        assertTrue(skewed);
        vm.expectEmit(true, false, false, true, address(hook));
        emit WoolFiHook.OracleSkewObserved(poolId, block.timestamp, block.timestamp - 61, uint32(60));
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);
        assertFalse(hook.poolConfig(poolId).structuralBreak);
    }

    function testRevert_addLiquidity_whenOracleTimestampsSkewed() public {
        skip(1000);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 60}));
        oracle0.setPriceData(1e18, block.timestamp);
        oracle1.setPriceData(1e18, block.timestamp - 61);
        IPoolManager.ModifyLiquidityParams memory p =
            IPoolManager.ModifyLiquidityParams({tickLower: -887220, tickUpper: 887220, liquidityDelta: 1e18, salt: 0});
        vm.prank(address(manager));
        vm.expectRevert(
            abi.encodeWithSelector(
                WoolFiHook.OracleTimestampSkew.selector, block.timestamp, block.timestamp - 61, uint32(60)
            )
        );
        hook.beforeAddLiquidity(address(this), poolKey, p, ZERO_BYTES);
    }

    function test_oracleSkew_boundaryIsSynchronized() public {
        skip(1000);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 60}));
        oracle0.setPriceData(1e18, block.timestamp);
        oracle1.setPriceData(1e18, block.timestamp - 60);
        (,,, bool skewed) = hook.poolSafetyStatus(poolKey);
        assertFalse(skewed);
    }

    function testRevert_oracleSkew_doesNotCatchUnsafeFailure() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 60}));
        oracle0.setStale(true);
        IPoolManager.SwapParams memory p =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: EXACT_IN, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
        vm.prank(address(manager));
        vm.expectRevert(MockPriceOracle.MockStale.selector);
        hook.beforeSwap(address(this), poolKey, p, ZERO_BYTES);
    }

    function testFuzz_oracleSkew_statusMatchesStrictBoundary(uint32 difference) public {
        difference = uint32(bound(difference, 0, 1000));
        skip(2000);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 100}));
        oracle0.setPriceData(1e18, block.timestamp);
        oracle1.setPriceData(1e18, block.timestamp - difference);
        (,,, bool skewed) = hook.poolSafetyStatus(poolKey);
        assertEq(skewed, difference > 100);
    }

    // -----------------------------------------------------------------
    // hook <-> underwriting vault wiring
    // -----------------------------------------------------------------

    /// @notice `checkStructuralBreak` triggers detection + drawdown even when no swap has happened
    ///         since the oracle moved (the gap RebalanceKeeper exists to close).
    function test_checkStructuralBreak_withoutSwap_triggersBreakAndDrawdown() public {
        STRAND strand = new STRAND(address(this));
        address rebalancer = makeAddr("rebalancer");
        WoolFiUnderwritingVault vault = new WoolFiUnderwritingVault(
            address(strand), address(hook), Currency.unwrap(currency0), Currency.unwrap(currency1), rebalancer, 1_000e18
        );
        strand.mint(address(this), 1000e18);
        strand.approve(address(vault), type(uint256).max);
        vault.stake(1000e18);
        hook.setVault(poolKey, address(vault), 2000);

        oracle0.setPrice(1.2e18); // drift past hard threshold; NO swap performed
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        vm.prank(makeAddr("keeper"));
        hook.checkStructuralBreak(poolKey);

        assertTrue(hook.poolConfig(poolId).structuralBreak);
        assertEq(vault.totalStaked(), 800e18);
        assertEq(strand.balanceOf(rebalancer), 200e18);
    }

    function test_checkStructuralBreak_noop_whenInBand() public {
        hook.checkStructuralBreak(poolKey); // drift 0 at setUp
        assertFalse(hook.poolConfig(poolId).structuralBreak);
    }

    function test_checkStructuralBreak_noop_whenMarketClosed() public {
        marketHours.setOpen(false);
        oracle0.setPrice(1.2e18); // would-be break suppressed during closure
        hook.checkStructuralBreak(poolKey);
        assertFalse(hook.poolConfig(poolId).structuralBreak);
    }

    function testRevert_checkStructuralBreak_whenOracleStale() public {
        oracle0.setStale(true);
        vm.expectRevert(MockPriceOracle.MockStale.selector);
        hook.checkStructuralBreak(poolKey);
    }

    /// @notice A structural break seizes the configured fraction of the vault, end to end.
    function test_structuralBreak_triggersVaultDrawdown() public {
        STRAND strand = new STRAND(address(this));
        address rebalancer = makeAddr("rebalancer");
        WoolFiUnderwritingVault vault = new WoolFiUnderwritingVault(
            address(strand), address(hook), Currency.unwrap(currency0), Currency.unwrap(currency1), rebalancer, 1_000e18
        );
        strand.mint(address(this), 1000e18);
        strand.approve(address(vault), type(uint256).max);
        vault.stake(1000e18);
        hook.setVault(poolKey, address(vault), 2000); // seize 20% on a break

        oracle0.setPrice(1.2e18); // drift beyond the hard threshold
        swap(poolKey, true, EXACT_IN, ZERO_BYTES);

        assertTrue(hook.poolConfig(poolId).structuralBreak);
        assertEq(vault.totalStaked(), 800e18); // 20% seized
        assertEq(strand.balanceOf(rebalancer), 200e18); // moved to the rebalancer
    }

    function testRevert_setVault_notGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        hook.setVault(poolKey, address(0xCAFE), 2000);
    }

    function testRevert_setVault_notConfigured() public {
        vm.expectRevert(WoolFiHook.PoolNotConfigured.selector);
        hook.setVault(_freshKey(), address(0xCAFE), 2000);
    }

    function testRevert_setVault_bpsTooHigh() public {
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.setVault(poolKey, address(0xCAFE), 10_001);
    }

    function test_setGovernor_updatesGovernor() public {
        address newGov = makeAddr("newGov");
        hook.setGovernor(newGov);
        assertEq(hook.governor(), newGov);
    }

    function testRevert_setGovernor_zeroAddress() public {
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.setGovernor(address(0));
    }

    function testRevert_setGovernor_notGovernor() public {
        vm.prank(address(0xBEEF));
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        hook.setGovernor(address(0xBEEF));
    }

    function _freshKey() internal view returns (PoolKey memory k) {
        k = poolKey;
        k.tickSpacing = 30; // distinct poolId, never authorized
    }
}
