// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiSwapRouter} from "../../src/WoolFiSwapRouter.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {RebalanceKeeper} from "../../src/RebalanceKeeper.sol";
import {STRAND} from "../../src/STRAND.sol";
import {IFeeRebateDistributor} from "../../src/interfaces/IFeeRebateDistributor.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

/// @dev Captures the amount the router reports to the rebate distributor.
contract RecordingDistributor is IFeeRebateDistributor {
    uint256 public lastAmountIn;
    uint256 public calls;

    function recordSwap(address, PoolId, address, uint256 amountIn) external returns (uint256) {
        lastAmountIn = amountIn;
        calls++;
        return 0;
    }
}

/// @notice Regression tests for docs/audit/REVIEW-2.md: R2-2 (session-anchored confirmation, no
///         confirmation during stabilization), R2-4 (permissionless recovery exit), R2-6 (rebate on
///         the settled amount), plus keeper skip behavior.
contract Review2FixesTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    WoolFiUnderwritingVault vault;
    PoolKey poolKey;
    PoolId poolId;

    uint32 constant STABILIZATION = 900;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x5555) << 144));
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
        hook.authorizePool(poolKey, _params(marketHours));
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
        hook.setVault(poolKey, address(vault), 2000);

        // Session open for a long time, so stabilization is not active at the start of each test.
        vm.warp(10 days);
        marketHours.setSessionStart(block.timestamp - 1 days);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: STABILIZATION, maxOracleSkew: 0}));
    }

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

    function _flagBreak() internal {
        oracle0.setPrice(1.2e18);
        hook.checkStructuralBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertTrue(broken, "break flagged");
    }

    /// @dev Close the market, sit out a weekend, reopen. Returns the new session start.
    function _weekendGap() internal returns (uint256 sessionStart) {
        marketHours.setOpen(false);
        vm.warp(block.timestamp + 3 days);
        marketHours.setOpen(true);
        sessionStart = block.timestamp;
    }

    // ------------------------------------------------------------------
    // R2-2: confirmation never runs during stabilization, window anchored to the session
    // ------------------------------------------------------------------

    function testRevert_confirm_duringStabilization() public {
        _flagBreak();
        uint256 sessionStart = _weekendGap();
        vm.expectRevert(
            abi.encodeWithSelector(WoolFiHook.StabilizationActive.selector, sessionStart, sessionStart + STABILIZATION)
        );
        hook.confirmStructuralBreak(poolKey);
        assertEq(vault.totalStaked(), 1000e18, "no drawdown on the opening print");
    }

    function test_confirm_windowStartsAtSessionOpen() public {
        _flagBreak();
        marketHours.setOpen(false);
        (,,, uint256 readyWhileClosed) = hook.breakStatus(poolKey);
        assertEq(readyWhileClosed, type(uint256).max, "ready time unknown while closed");

        vm.warp(block.timestamp + 3 days);
        marketHours.setOpen(true);
        uint256 sessionStart = block.timestamp;
        uint256 expectedReady = sessionStart + hook.DEFAULT_BREAK_CONFIRM_SECONDS();
        (,,, uint256 readyAt) = hook.breakStatus(poolKey);
        assertEq(readyAt, expectedReady, "window counts from the session open");

        // Past stabilization but inside the window: still pending, even though wall-clock time since
        // detection is days.
        vm.warp(sessionStart + STABILIZATION);
        vm.expectRevert(abi.encodeWithSelector(WoolFiHook.BreakConfirmationPending.selector, expectedReady));
        hook.confirmStructuralBreak(poolKey);

        vm.warp(expectedReady);
        hook.confirmStructuralBreak(poolKey);
        (, bool confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(confirmed);
        assertEq(vault.totalStaked(), 800e18);
    }

    function test_confirm_detectedMidSessionUsesDetectionTime() public {
        _flagBreak();
        (,, uint256 detectedAt, uint256 readyAt) = hook.breakStatus(poolKey);
        assertEq(readyAt, detectedAt + hook.DEFAULT_BREAK_CONFIRM_SECONDS());
    }

    function test_confirm_alwaysOpenUsesWallClock() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0}));
        hook.updatePoolConfig(poolKey, _params(IMarketHoursOracle(address(0))));
        _flagBreak();
        (,, uint256 detectedAt, uint256 readyAt) = hook.breakStatus(poolKey);
        assertEq(readyAt, detectedAt + hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        vm.warp(readyAt);
        hook.confirmStructuralBreak(poolKey);
        assertEq(vault.totalStaked(), 800e18);
    }

    // ------------------------------------------------------------------
    // R2-4: permissionless exit after a confirmed break recovers
    // ------------------------------------------------------------------

    function _confirmedBreak() internal {
        _flagBreak();
        skip(hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        hook.confirmStructuralBreak(poolKey);
        assertEq(vault.totalStaked(), 800e18);
    }

    function test_clearRecoveredBreak_afterConfirmInBand() public {
        _confirmedBreak();
        oracle0.setPrice(1e18); // fresh oracle back at the pool price: drift 0
        vm.expectEmit(true, false, false, false, address(hook));
        emit WoolFiHook.StructuralBreakRecovered(poolId, 0);
        vm.prank(makeAddr("anyone"));
        hook.clearRecoveredBreak(poolKey);

        (bool broken, bool confirmed, uint256 detectedAt,) = hook.breakStatus(poolKey);
        assertFalse(broken);
        assertFalse(confirmed);
        assertEq(detectedAt, 0);
        assertEq(hook.poolConfig(poolId).cachedFairPriceWad, 0);
        assertEq(vault.totalStaked(), 800e18, "recovery does not touch the vault");
    }

    function testRevert_clearRecoveredBreak_beforeConfirm() public {
        _flagBreak();
        oracle0.setPrice(1e18);
        vm.expectRevert(WoolFiHook.BreakNotConfirmed.selector);
        hook.clearRecoveredBreak(poolKey);
    }

    function testRevert_clearRecoveredBreak_stillOutOfBand() public {
        _confirmedBreak();
        vm.expectRevert(WoolFiHook.OutOfBand.selector);
        hook.clearRecoveredBreak(poolKey);
        // Between tolerance (500) and hard threshold (1500): still not recovered.
        oracle0.setPrice(1.08e18);
        vm.expectRevert(WoolFiHook.OutOfBand.selector);
        hook.clearRecoveredBreak(poolKey);
    }

    function testRevert_clearRecoveredBreak_notBroken() public {
        vm.expectRevert(WoolFiHook.NotStructurallyBroken.selector);
        hook.clearRecoveredBreak(poolKey);
    }

    function testRevert_clearRecoveredBreak_duringStabilization() public {
        _confirmedBreak();
        oracle0.setPrice(1e18);
        uint256 sessionStart = _weekendGap();
        vm.expectRevert(
            abi.encodeWithSelector(WoolFiHook.StabilizationActive.selector, sessionStart, sessionStart + STABILIZATION)
        );
        hook.clearRecoveredBreak(poolKey);
    }

    function test_governorResolveStillWorksAfterConfirm() public {
        _confirmedBreak();
        hook.resolveStructuralBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken);
    }

    // ------------------------------------------------------------------
    // Keeper skip behavior
    // ------------------------------------------------------------------

    function _keeper() internal returns (RebalanceKeeper keeper) {
        WoolFiPositionManager pm = new WoolFiPositionManager(manager, address(this));
        keeper = new RebalanceKeeper(hook, pm);
    }

    function test_keeper_skipsConfirmDuringStabilizationAndAfterWeekend() public {
        RebalanceKeeper keeper = _keeper();
        _flagBreak();
        uint256 sessionStart = _weekendGap();
        keeper.keep(poolKey); // stabilizing and window not elapsed: no revert, no drawdown
        (, bool confirmed,,) = hook.breakStatus(poolKey);
        assertFalse(confirmed);
        assertEq(vault.totalStaked(), 1000e18);

        vm.warp(sessionStart + hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        keeper.keep(poolKey);
        (, confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(confirmed, "keeper confirms once the session window elapses");
        assertEq(vault.totalStaked(), 800e18);
    }

    function test_keeper_recoveryAttemptSkippedThenClears() public {
        RebalanceKeeper keeper = _keeper();
        _confirmedBreak();

        vm.recordLogs();
        keeper.keep(poolKey); // still out of band: attempted, fails quietly
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertTrue(broken);

        oracle0.setPrice(1e18);
        keeper.keep(poolKey);
        (broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken, "keeper clears a recovered break");
    }

    // ------------------------------------------------------------------
    // R2-6: rebate on the settled amount
    // ------------------------------------------------------------------

    /// @dev In a full-range WoolFi pool a router swap cannot partially fill in practice (the router's
    ///      price limits sit at the tick extremes, which would need ~1e39 of input to reach), so this
    ///      asserts the router reports the amount actually pulled from the trader, which is what a
    ///      partial fill would reduce.
    function test_router_reportsSettledAmountToDistributor() public {
        RecordingDistributor recorder = new RecordingDistributor();
        WoolFiSwapRouter router = new WoolFiSwapRouter(manager, recorder);
        IERC20 token0 = IERC20(Currency.unwrap(currency0));
        token0.approve(address(router), type(uint256).max);

        uint256 before = token0.balanceOf(address(this));
        router.swap(poolKey, true, 1e18, 0, address(this), "");
        uint256 settled = before - token0.balanceOf(address(this));

        assertEq(recorder.calls(), 1);
        assertEq(recorder.lastAmountIn(), settled, "rebate base is the settled input");
    }
}
