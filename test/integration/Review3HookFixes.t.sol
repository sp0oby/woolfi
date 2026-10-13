// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {RebalanceKeeper} from "../../src/RebalanceKeeper.sol";
import {STRAND} from "../../src/STRAND.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

/// @dev Anyone. Holds inventory and tries overshoot -> confirm -> swap back in ONE call.
contract Griefer {
    PoolSwapTest immutable router;
    WoolFiHook immutable hook;

    constructor(PoolSwapTest r, WoolFiHook h, address t0, address t1) {
        router = r;
        hook = h;
        IERC20(t0).approve(address(r), type(uint256).max);
        IERC20(t1).approve(address(r), type(uint256).max);
    }

    function _swapTo(PoolKey memory key, bool zeroForOne, uint160 limit) internal {
        router.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1_000_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function attack(PoolKey memory key, uint160 overshoot, uint160 restore) external {
        _swapTo(key, false, overshoot);
        hook.confirmStructuralBreak(key);
        _swapTo(key, true, restore);
    }
}

/// @dev Stands in for the PM so {RebalanceKeeper.keep} can run without a full fee stack.
contract StubPm {
    function collectFees(PoolKey calldata, address) external pure returns (uint256, uint256) {
        return (0, 0);
    }
}

/// @notice Regression suite for the third review's hook findings: H-1 (break-path overshoot and
///         same-block confirm/clear), M/L-2 (equity confirmation window must fit a session), L-4
///         (initial price gate), V-1 (unflaggable gap locks unstakes), V-2 (no governance changes
///         while a break is pending) and V-5 (one pool per vault).
contract Review3HookFixesTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    WoolFiUnderwritingVault vault;
    PoolKey poolKey;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x7777) << 144));
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(this)), hookAddr);
        hook = WoolFiHook(hookAddr);

        oracle0 = new MockPriceOracle(1e18);
        oracle1 = new MockPriceOracle(1e18);
        marketHours = new MockMarketHours(true);
        poolKey = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(address(hook)));
        hook.authorizePool(poolKey, _params(IMarketHoursOracle(address(marketHours))));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
            }),
            ZERO_BYTES
        );

        STRAND strand = new STRAND(address(this));
        vault = new WoolFiUnderwritingVault(
            address(strand),
            address(hook),
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            makeAddr("rebalancer"),
            1_000e18
        );
        strand.mint(address(this), 1000e18);
        strand.approve(address(vault), type(uint256).max);
        vault.stake(1000e18);
        hook.setVault(poolKey, address(vault), 2000); // 20% drawdown

        vm.warp(10 days);
        marketHours.setSessionStart(block.timestamp - 1 days);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _params(IMarketHoursOracle mh) internal view returns (WoolFiHook.AuthParams memory) {
        return WoolFiHook.AuthParams({
            oracle0: oracle0,
            oracle1: oracle1,
            marketHours: mh,
            kScaled: 40_000,
            baseFeeBps: 30,
            toleranceBps: 500,
            hardThresholdBps: 1500
        });
    }

    function _swapTo(bool zeroForOne, uint160 limit) internal {
        swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1_000_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @return reason Empty on success, the raw revert data otherwise.
    function _trySwapTo(bool zeroForOne, uint160 limit) internal returns (bytes memory reason) {
        try swapRouter.swap(
            poolKey,
            IPoolManager.SwapParams({zeroForOne: zeroForOne, amountSpecified: -1_000_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {
            return "";
        } catch (bytes memory r) {
            return r;
        }
    }

    /// @dev Unwraps the PoolManager's `WrappedError` around a hook revert and returns the hook's
    ///      own error selector.
    function innerHookError(bytes calldata reason) external pure returns (bytes4) {
        require(bytes4(reason[:4]) == CustomRevert.WrappedError.selector, "not a wrapped hook error");
        (,, bytes memory inner,) = abi.decode(reason[4:], (address, bytes4, bytes, bytes));
        return bytes4(inner);
    }

    function _assertHookError(bytes memory reason, bytes4 expected) internal view {
        assertGt(reason.length, 0, "expected a revert");
        assertEq(this.innerHookError(reason), expected, "hook error");
    }

    function _sqrtAtFair(uint256 fair) internal pure returns (uint160) {
        return uint160(_sqrt(fair * (1 << 96) / 1e18 * (1 << 96)));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 z) {
        z = x;
        uint256 y = (x + 1) / 2;
        while (y < z) {
            z = y;
            y = (x / y + y) / 2;
        }
    }

    function _flag(uint256 price0) internal {
        oracle0.setPrice(price0);
        hook.checkStructuralBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertTrue(broken, "flagged");
    }

    /// Oracle gaps 20% (fair 1.2), break flagged, arbitrage corrects pool to ~1.197 within the window.
    function _flagThenArbCorrect() internal {
        _flag(1.2e18);
        _swapTo(false, TickMath.getSqrtPriceAtTick(1800)); // ~1.1972, drift ~ -0.23%
        int256 d = hook.currentDrift(poolKey);
        assertLt(d, 0);
        assertGt(d, -50, "pool corrected to within 0.5% of fair");
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
    }

    function _otherKey(int24 tickSpacing) internal view returns (PoolKey memory) {
        return PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, tickSpacing, IHooks(address(hook)));
    }

    // ------------------------------------------------------------------
    // H-1: break-path overshoot bound
    // ------------------------------------------------------------------

    /// Control: honest confirmation after arbitrage clears the break with no drawdown.
    function test_control_correctedBreakClearsWithoutDrawdown() public {
        _flagThenArbCorrect();
        hook.confirmStructuralBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken);
        assertEq(vault.totalStaked(), 1000e18, "no drawdown");
    }

    /// The one-transaction overshoot -> confirm -> restore griefing attack now fails at the overshoot.
    function test_overshootAttack_revertsAndNoDrawdown() public {
        _flagThenArbCorrect();

        Griefer g = new Griefer(swapRouter, hook, Currency.unwrap(currency0), Currency.unwrap(currency1));
        IERC20(Currency.unwrap(currency0)).transfer(address(g), 100e18);
        IERC20(Currency.unwrap(currency1)).transfer(address(g), 100e18);

        vm.expectRevert();
        g.attack(poolKey, TickMath.getSqrtPriceAtTick(4100), TickMath.getSqrtPriceAtTick(1800));

        // The overshoot leg is what reverts.
        _assertHookError(_trySwapTo(false, TickMath.getSqrtPriceAtTick(4100)), WoolFiHook.BreakSwapOvershoot.selector);

        (bool broken, bool confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(broken && !confirmed, "still pending");
        assertEq(vault.totalStaked(), 1000e18, "no drawdown");

        // Honest confirmation afterwards clears it.
        hook.confirmStructuralBreak(poolKey);
        (broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken);
        assertEq(vault.totalStaked(), 1000e18);
    }

    /// At exactly zero drift either direction is still admitted, but only within the tolerance band.
    function test_zeroDriftHop_boundedByTolerance() public {
        _flag(1.2e18);
        _swapTo(false, _sqrtAtFair(1.2e18));
        assertEq(hook.currentDrift(poolKey), 0);

        // A 40% push the other way is an overshoot.
        _assertHookError(_trySwapTo(true, TickMath.getSqrtPriceAtTick(-3300)), WoolFiHook.BreakSwapOvershoot.selector);
        assertEq(hook.currentDrift(poolKey), 0, "pool unmoved");

        // A small move from zero, inside tolerance, still works in either direction.
        _swapTo(true, TickMath.getSqrtPriceAtTick(1500)); // ~1.1618, drift ~ -3.2%
        int256 d = hook.currentDrift(poolKey);
        assertLt(d, -300);
        assertGt(d, -500);
    }

    /// A corrective swap that reduces drift still works, including one that crosses the target by
    /// less than its starting distance; a crossing larger than that reverts.
    function test_correctiveSwaps_withinBound() public {
        _flag(1.2e18); // pool 1.0 vs target 1.2: drift ~ -16.7%

        // Overshoot to ~1.462 (+21.9%) is further from the target than the start: rejected.
        _assertHookError(_trySwapTo(false, TickMath.getSqrtPriceAtTick(3800)), WoolFiHook.BreakSwapOvershoot.selector);

        // Reducing drift without crossing.
        _swapTo(false, TickMath.getSqrtPriceAtTick(1000)); // ~1.105, drift ~ -7.9%
        assertGt(hook.currentDrift(poolKey), -800);

        // Crossing slightly past the target (+1.8%).
        _swapTo(false, TickMath.getSqrtPriceAtTick(2000));
        int256 d = hook.currentDrift(poolKey);
        assertGt(d, 0);
        assertLt(d, 500);

        // Back down across the target, still inside the tolerance band.
        _swapTo(true, TickMath.getSqrtPriceAtTick(1500));
        assertLt(hook.currentDrift(poolKey), 0);
    }

    // ------------------------------------------------------------------
    // H-1: no confirm/clear in the block of a break-mode swap
    // ------------------------------------------------------------------

    /// The flash-clear variant: nudge a genuine break under the threshold, confirm, restore. The
    /// confirm now reverts in the same block; a later block confirms against the price that held.
    function test_flashClear_sameBlockConfirmReverts() public {
        _flag(1.2e18);
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        assertLt(hook.currentDrift(poolKey), -1500, "still genuinely broken at confirm time");

        _swapTo(false, TickMath.getSqrtPriceAtTick(300)); // ~1.030, drift ~ -14.1%
        vm.expectRevert(WoolFiHook.BreakSwapThisBlock.selector);
        hook.confirmStructuralBreak(poolKey);

        (bool broken, bool confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(broken && !confirmed);
        assertEq(vault.totalStaked(), 1000e18);
    }

    /// Confirmation in a later block after a break-mode swap works and draws down.
    function test_confirmInLaterBlockAfterBreakSwap() public {
        _flag(1.2e18);
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        _swapTo(false, TickMath.getSqrtPriceAtTick(100)); // ~1.010, still past the threshold

        vm.expectRevert(WoolFiHook.BreakSwapThisBlock.selector);
        hook.confirmStructuralBreak(poolKey);

        skip(1);
        hook.confirmStructuralBreak(poolKey);
        (bool broken, bool confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(broken && confirmed);
        assertEq(vault.totalStaked(), 800e18, "20% drawn");
    }

    /// clearRecoveredBreak is refused in the block of a break-mode swap too.
    function test_clearRecovered_sameBlockAsBreakSwapReverts() public {
        _flag(1.2e18);
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        hook.confirmStructuralBreak(poolKey);

        _swapTo(false, TickMath.getSqrtPriceAtTick(1800)); // back in band
        vm.expectRevert(WoolFiHook.BreakSwapThisBlock.selector);
        hook.clearRecoveredBreak(poolKey);

        skip(1);
        hook.clearRecoveredBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken);
    }

    /// RebalanceKeeper swallows the new revert and records it.
    function test_keeper_swallowsBreakSwapThisBlock() public {
        RebalanceKeeper keeper = new RebalanceKeeper(hook, WoolFiPositionManager(address(new StubPm())));
        _flag(1.2e18);
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        _swapTo(false, TickMath.getSqrtPriceAtTick(100));

        vm.expectEmit(address(keeper));
        emit RebalanceKeeper.BreakConfirmAttempted(
            false, abi.encodeWithSelector(WoolFiHook.BreakSwapThisBlock.selector)
        );
        keeper.keep(poolKey);

        skip(1);
        vm.expectEmit(address(keeper));
        emit RebalanceKeeper.BreakConfirmAttempted(true, "");
        keeper.keep(poolKey);
    }

    /// Ordinary swaps never write the break-swap timestamp.
    function test_normalSwap_doesNotBlockLaterConfirm() public {
        _swapTo(false, TickMath.getSqrtPriceAtTick(60)); // in-band, normal mode
        _flag(1.2e18);
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        hook.confirmStructuralBreak(poolKey); // no break-mode swap ran: fine
        (, bool confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(confirmed);
    }

    // ------------------------------------------------------------------
    // M/L-2: equity confirmation window must fit a session
    // ------------------------------------------------------------------

    function test_equityWindow_confirmSecondsCapped() public {
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.setBreakConfirmSeconds(poolKey, 8 hours);
        uint32 maxWindow = hook.MAX_EQUITY_BREAK_WINDOW();
        assertEq(maxWindow, 12_600, "NYSE early-close session");
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.setBreakConfirmSeconds(poolKey, maxWindow + 1);
        hook.setBreakConfirmSeconds(poolKey, maxWindow);
    }

    function test_equityWindow_includesStabilization() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 900, maxOracleSkew: 0}));
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.setBreakConfirmSeconds(poolKey, 11_701);
        hook.setBreakConfirmSeconds(poolKey, 11_700);

        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 901, maxOracleSkew: 0}));

        WoolFiHook.AuthParamsV2 memory p = WoolFiHook.AuthParamsV2({
            core: _params(IMarketHoursOracle(address(marketHours))),
            safety: WoolFiHook.SafetyParams({stabilizationSeconds: 901, maxOracleSkew: 0})
        });
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.updatePoolConfigV2(poolKey, p);
    }

    function test_equityWindow_defaultConfirmCounts() public {
        // Stored 0 = 1 hour default, so stabilization may use the remaining 2.5 hours.
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 9001, maxOracleSkew: 0}));
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 9000, maxOracleSkew: 0}));
    }

    function test_equityWindow_enforcedAtAuthorize() public {
        WoolFiHook.AuthParamsV2 memory p = WoolFiHook.AuthParamsV2({
            core: _params(IMarketHoursOracle(address(marketHours))),
            safety: WoolFiHook.SafetyParams({stabilizationSeconds: 9001, maxOracleSkew: 0})
        });
        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.authorizePoolV2(_otherKey(10), p);
        p.safety.stabilizationSeconds = 9000;
        hook.authorizePoolV2(_otherKey(10), p);
    }

    /// Always-open pools keep the 1-day maximum; moving one onto market hours re-checks the window.
    function test_alwaysOpenPool_keepsOneDayMax() public {
        PoolKey memory k = _otherKey(10);
        hook.authorizePool(k, _params(IMarketHoursOracle(address(0))));
        hook.setBreakConfirmSeconds(k, 1 days);

        vm.expectRevert(WoolFiHook.InvalidConfig.selector);
        hook.updatePoolConfig(k, _params(IMarketHoursOracle(address(marketHours))));
    }

    /// The longest allowed equity window ripens inside a regular session (the original PoC used
    /// 8 hours, which is now rejected, and never ripened).
    function test_maxEquityWindow_ripensWithinSession() public {
        hook.setBreakConfirmSeconds(poolKey, hook.MAX_EQUITY_BREAK_WINDOW());
        marketHours.setSessionStart(block.timestamp);
        skip(1 hours);
        _flag(1.2e18);

        vm.warp(marketHours.sessionStart() + 6.5 hours - 1); // last second of the session
        (,,, uint256 readyAt) = hook.breakStatus(poolKey);
        assertLe(readyAt, block.timestamp);
        hook.confirmStructuralBreak(poolKey);
        assertFalse(hook.isBreakPendingForVault(address(vault)), "unstake lock lifted");
        assertEq(vault.totalStaked(), 800e18);
    }

    // ------------------------------------------------------------------
    // L-4: initial price must sit within tolerance of the oracle fair
    // ------------------------------------------------------------------

    function test_initialize_rejectsPriceOutsideTolerance() public {
        PoolKey memory k = _otherKey(10);
        hook.authorizePool(k, _params(IMarketHoursOracle(address(marketHours))));

        try manager.initialize(k, TickMath.getSqrtPriceAtTick(600)) {
            // ~1.062 vs fair 1.0
            fail();
        } catch (bytes memory reason) {
            _assertHookError(reason, WoolFiHook.InitialPriceOutOfBand.selector);
        }

        manager.initialize(k, TickMath.getSqrtPriceAtTick(400)); // ~1.041: inside 5%
    }

    function test_initialize_marketClosedUsesLastValidPrice() public {
        marketHours.setOpen(false);
        oracle0.setStale(true);
        oracle1.setStale(true);

        PoolKey memory k = _otherKey(10);
        hook.authorizePool(k, _params(IMarketHoursOracle(address(marketHours))));
        manager.initialize(k, SQRT_PRICE_1_1);

        // Last valid fair 2.0: a 1:1 initial price is 50% off.
        oracle0.setPrice(2e18);
        oracle0.setStale(true);
        PoolKey memory k2 = _otherKey(20);
        hook.authorizePool(k2, _params(IMarketHoursOracle(address(marketHours))));
        vm.expectRevert();
        manager.initialize(k2, SQRT_PRICE_1_1);
        manager.initialize(k2, _sqrtAtFair(2e18));
    }

    // ------------------------------------------------------------------
    // V-2: governance changes refused while a break is pending
    // ------------------------------------------------------------------

    function test_governanceRefusedWhileBreakPending() public {
        _flag(1.2e18);
        WoolFiHook.AuthParams memory p = _params(IMarketHoursOracle(address(marketHours)));

        vm.expectRevert(WoolFiHook.BreakPendingForPool.selector);
        hook.setVault(poolKey, address(vault), 9999);
        vm.expectRevert(WoolFiHook.BreakPendingForPool.selector);
        hook.updatePoolConfig(poolKey, p);
        vm.expectRevert(WoolFiHook.BreakPendingForPool.selector);
        hook.updatePoolConfigV2(poolKey, WoolFiHook.AuthParamsV2({core: p, safety: WoolFiHook.SafetyParams(0, 0)}));
        vm.expectRevert(WoolFiHook.BreakPendingForPool.selector);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams(0, 0));
        vm.expectRevert(WoolFiHook.BreakPendingForPool.selector);
        hook.setBreakConfirmSeconds(poolKey, 600);

        // Pause / unpause still work.
        hook.setPaused(true);
        hook.setPaused(false);

        // Resolution works; config changes wait for a later block so a batch cannot resolve,
        // rewire and re-flag before locked stakers can leave.
        hook.resolveStructuralBreak(poolKey);
        vm.expectRevert(WoolFiHook.BreakPendingForPool.selector);
        hook.setVault(poolKey, address(vault), 9999);
        skip(1);
        hook.setVault(poolKey, address(vault), 9999);
    }

    function test_governanceAllowedAfterConfirm() public {
        _flag(1.2e18);
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        hook.confirmStructuralBreak(poolKey);
        hook.setVault(poolKey, address(vault), 1000);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams(900, 0));
    }

    // ------------------------------------------------------------------
    // V-5: one pool per vault
    // ------------------------------------------------------------------

    function test_setVault_rejectsVaultMappedToOtherPool() public {
        PoolKey memory k = _otherKey(10);
        hook.authorizePool(k, _params(IMarketHoursOracle(address(marketHours))));

        vm.expectRevert(abi.encodeWithSelector(WoolFiHook.VaultAlreadyMapped.selector, poolKey.toId()));
        hook.setVault(k, address(vault), 2000);

        hook.setVault(poolKey, address(vault), 1000); // same pool: fine
        hook.setVault(poolKey, address(0), 0); // unwire
        hook.setVault(k, address(vault), 2000); // now free
        assertEq(hook.poolConfig(k.toId()).vault, address(vault));
    }

    // ------------------------------------------------------------------
    // V-1: unflaggable gap counts as pending
    // ------------------------------------------------------------------

    function test_pendingView_falseInNormalConditions() public {
        assertFalse(hook.isBreakPendingForVault(address(vault)));
        oracle0.setPrice(1.1e18); // 9% drift: out of band but under the threshold
        assertFalse(hook.isBreakPendingForVault(address(vault)));
        oracle0.setPrice(1.2e18); // flaggable now (open, settled, unskewed): not pending until flagged
        assertFalse(hook.isBreakPendingForVault(address(vault)));
        hook.checkStructuralBreak(poolKey);
        assertTrue(hook.isBreakPendingForVault(address(vault)));
    }

    function test_pendingView_trueForGapWhileClosed() public {
        marketHours.setOpen(false);
        oracle0.setPrice(1.1e18);
        assertFalse(hook.isBreakPendingForVault(address(vault)), "under threshold");
        oracle0.setPrice(1.2e18);
        hook.checkStructuralBreak(poolKey); // silent no-op while closed
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken);
        assertTrue(hook.isBreakPendingForVault(address(vault)), "gap on chain locks unstakes");

        // Stale feeds do not matter: the last valid print is used.
        oracle0.setStale(true);
        assertTrue(hook.isBreakPendingForVault(address(vault)));
    }

    function test_pendingView_trueForGapDuringStabilization() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 900, maxOracleSkew: 0}));
        marketHours.setSessionStart(block.timestamp);
        oracle0.setPrice(1.2e18);
        hook.checkStructuralBreak(poolKey); // no-op while stabilizing
        assertTrue(hook.isBreakPendingForVault(address(vault)));

        skip(900); // settled: flaggable, so the normal path applies
        assertFalse(hook.isBreakPendingForVault(address(vault)));
        hook.checkStructuralBreak(poolKey);
        assertTrue(hook.isBreakPendingForVault(address(vault)));
    }

    function test_pendingView_trueForGapWhileSkewed() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 60}));
        oracle0.setPrice(1.2e18);
        oracle1.setPriceData(1e18, block.timestamp - 1000);
        (,,, bool skewed) = hook.poolSafetyStatus(poolKey);
        assertTrue(skewed);
        assertTrue(hook.isBreakPendingForVault(address(vault)));

        oracle0.setPrice(1.05e18);
        assertFalse(hook.isBreakPendingForVault(address(vault)), "skewed but no gap");
    }

    function test_pendingView_failsOpenOnFault() public {
        marketHours.setOpen(false);
        oracle0.setPrice(1.2e18);
        assertTrue(hook.isBreakPendingForVault(address(vault)));

        oracle0.setRuntimeUnsafe(true);
        assertFalse(hook.isBreakPendingForVault(address(vault)), "oracle fault reads false");
        oracle0.setRuntimeUnsafe(false);

        vm.mockCallRevert(address(marketHours), abi.encodeWithSelector(IMarketHoursOracle.isMarketOpen.selector), "");
        assertFalse(hook.isBreakPendingForVault(address(vault)), "market-hours fault reads false");
        vm.clearMockedCalls();

        // Skew mode with a stale leg: the probe reverts, the view does not.
        marketHours.setOpen(true);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 60}));
        marketHours.setSessionStart(block.timestamp - 1 days);
        oracle1.setStale(true);
        assertFalse(hook.isBreakPendingForVault(address(vault)));
    }
}
