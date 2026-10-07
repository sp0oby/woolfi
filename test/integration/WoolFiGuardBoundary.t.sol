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
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {SpreadMath} from "../../src/lib/SpreadMath.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

/// @notice Boundary fuzz for the single-swap break guard. For a fuzzed pre-swap drift, swap size,
///         direction and operating mode, the guarded swap must revert with
///         `SwapWouldBreakPool(pre, post)` exactly when the swap alone would take drift from inside
///         the 15% hard threshold to at or beyond it while moving away from fair.
/// @dev The "would" is measured, not modelled: the same swap is replayed from a state snapshot
///      with the hard threshold raised to 100%, which leaves the fee curve unchanged (the fee does
///      not depend on the threshold) and lets the swap land so its true post-drift can be read.
contract WoolFiGuardBoundaryTest is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint16 constant HARD = 1500;

    WoolFiHook hook;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    PoolKey poolKey;
    PoolId poolId;

    enum Mode {
        Open,
        Closed,
        Stabilizing,
        Skewed
    }

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

        vm.warp(1_000_000);
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
        hook.authorizePoolV2(poolKey, _params(HARD, 0));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
            }),
            ZERO_BYTES
        );
    }

    function _params(uint16 hard, uint32 stabilization) internal view returns (WoolFiHook.AuthParamsV2 memory) {
        return WoolFiHook.AuthParamsV2({
            core: WoolFiHook.AuthParams({
                oracle0: oracle0,
                oracle1: oracle1,
                marketHours: marketHours,
                kScaled: 40_000,
                baseFeeBps: 30,
                toleranceBps: 500,
                hardThresholdBps: hard
            }),
            safety: WoolFiHook.SafetyParams({stabilizationSeconds: stabilization, maxOracleSkew: 300})
        });
    }

    function _drift() internal view returns (int256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(poolId);
        uint256 fair = SpreadMath.fairPrice(oracle0.priceWad(), oracle1.priceWad());
        return SpreadMath.computeDrift(SpreadMath.poolPrice(sqrtPriceX96, 18, 18), fair);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _swap(bool zeroForOne, uint256 amount) internal returns (bool ok, bytes memory reason) {
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(poolKey, p, PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}), "") {
            ok = true;
        } catch (bytes memory r) {
            reason = r;
        }
    }

    /// @dev v4 wraps hook reverts; locate the guard selector and decode the (pre, post) words after it.
    function _findGuard(bytes memory data) internal pure returns (bool found, int256 pre, int256 post) {
        bytes4 sel = WoolFiHook.SwapWouldBreakPool.selector;
        for (uint256 i; i + 68 <= data.length; i++) {
            if (data[i] == sel[0] && data[i + 1] == sel[1] && data[i + 2] == sel[2] && data[i + 3] == sel[3]) {
                assembly {
                    let p := add(add(data, 32), add(i, 4))
                    pre := mload(p)
                    post := mload(add(p, 32))
                }
                return (true, pre, post);
            }
        }
    }

    function _enterMode(Mode mode) internal {
        if (mode == Mode.Closed) {
            marketHours.setOpen(false);
        } else if (mode == Mode.Stabilizing) {
            hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 900, maxOracleSkew: 300}));
            marketHours.setSessionStart(block.timestamp - 10);
        } else if (mode == Mode.Skewed) {
            oracle1.setPriceData(oracle1.priceWad(), block.timestamp - 1000);
        }
    }

    function testFuzz_guardRevertsExactlyWhenSwapCrossesThreshold(
        uint256 oraclePrice,
        uint256 amount,
        bool zeroForOne,
        uint8 modeSeed
    ) public {
        Mode mode = Mode(modeSeed % 4);
        // Pool sits at 1:1; fair in [0.87, 1.15] puts pre-drift inside the 15% band.
        oracle0.setPrice(bound(oraclePrice, 0.87e18, 1.15e18));
        oracle1.setPrice(1e18);
        _enterMode(mode);
        int256 pre = _drift();
        vm.assume(!SpreadMath.isStructuralBreak(pre, HARD));
        amount = bound(amount, 1e15, 4e19);

        uint256 snap = vm.snapshotState();
        (bool ok, bytes memory reason) = _swap(zeroForOne, amount);

        // Reference: same state, guard pushed to 100%, so the swap lands and its post-drift is real.
        vm.revertToState(snap);
        WoolFiHook.AuthParamsV2 memory ref = _params(10_000, mode == Mode.Stabilizing ? 900 : 0);
        hook.updatePoolConfigV2(poolKey, ref);
        (bool refOk,) = _swap(zeroForOne, amount);
        vm.assume(refOk);
        int256 post = _drift();

        bool shouldRevert = SpreadMath.isStructuralBreak(post, HARD) && _abs(post) > _abs(pre);
        if (shouldRevert) {
            assertFalse(ok, "crossing swap went through");
            (bool found, int256 gotPre, int256 gotPost) = _findGuard(reason);
            assertTrue(found, "reverted for a reason other than the guard");
            assertEq(gotPre, pre, "guard pre-drift");
            assertEq(gotPost, post, "guard post-drift");
        } else {
            assertTrue(ok, "non-crossing swap reverted");
        }
    }

    /// @dev Corrective flow is never refused, even from deep inside the band.
    function test_guard_correctiveSwapAllowed() public {
        // Pool rich vs fair (about +13%): zeroForOne pushes it back toward fair.
        oracle0.setPrice(0.885e18);
        int256 pre = _drift();
        assertGt(pre, 1000);
        (bool ok,) = _swap(true, 5e18);
        assertTrue(ok, "corrective swap allowed");
        assertLt(_abs(_drift()), _abs(pre));
    }

    /// @dev Pinned crossing case in every mode, so the fuzz's revert branch is known to be live.
    function test_guard_adversarialCrossingRevertsInEveryMode() public {
        for (uint8 m; m < 4; m++) {
            uint256 snap = vm.snapshotState();
            oracle0.setPrice(0.9e18);
            _enterMode(Mode(m));
            int256 pre = _drift();
            assertGt(pre, 0);
            assertLt(pre, int256(uint256(HARD)));
            (bool ok, bytes memory reason) = _swap(false, 2e19); // oneForZero: pool richer still
            assertFalse(ok, "crossing swap refused");
            (bool found, int256 gotPre, int256 gotPost) = _findGuard(reason);
            assertTrue(found, "guard selector");
            assertEq(gotPre, pre);
            assertGe(_abs(gotPost), HARD);
            vm.revertToState(snap);
        }
    }
}
