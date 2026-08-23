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
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiSwapRouter} from "../../src/WoolFiSwapRouter.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

/// @notice Integration tests for WoolFiSwapRouter against a real v4 PoolManager + WoolFi hook.
contract WoolFiSwapRouterTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiSwapRouter router;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;

    PoolKey poolKey;
    PoolId poolId;

    address constant ALICE = address(0xA11CE);

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

        hook.authorizePool(poolKey, _params());
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
            }),
            ZERO_BYTES
        );

        router = new WoolFiSwapRouter(manager);

        // Fund Alice and approve the router as her spender for both tokens.
        IERC20Minimal(Currency.unwrap(currency0)).transfer(ALICE, 10e18);
        IERC20Minimal(Currency.unwrap(currency1)).transfer(ALICE, 10e18);
        vm.startPrank(ALICE);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(router), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(router), type(uint256).max);
        vm.stopPrank();
    }

    function _params() internal view returns (WoolFiHook.AuthParams memory) {
        return WoolFiHook.AuthParams({
            oracle0: oracle0,
            oracle1: oracle1,
            marketHours: marketHours,
            kScaled: 40_000,
            baseFeeBps: 30,
            toleranceBps: 500,
            hardThresholdBps: 1500
        });
    }

    // -----------------------------------------------------------------
    // Happy paths
    // -----------------------------------------------------------------

    function test_swap_zeroForOne_transfersTokens() public {
        uint256 in0 = 1e16;
        uint256 b0Before = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(ALICE);
        uint256 b1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 out = router.swap(poolKey, true, in0, 0, ALICE, ZERO_BYTES);

        uint256 b0After = IERC20Minimal(Currency.unwrap(currency0)).balanceOf(ALICE);
        uint256 b1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(ALICE);

        assertEq(b0Before - b0After, in0, "spent exactly amountIn");
        assertEq(b1After - b1Before, out, "received amountOut");
        assertGt(out, 0, "got something back");
    }

    function test_swap_oneForZero_transfersTokens() public {
        uint256 in1 = 1e16;
        uint256 b1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(ALICE);

        vm.prank(ALICE);
        uint256 out = router.swap(poolKey, false, in1, 0, ALICE, ZERO_BYTES);

        uint256 b1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(ALICE);
        assertEq(b1Before - b1After, in1, "spent exactly amountIn");
        assertGt(out, 0, "got something back");
    }

    function test_swap_recipientReceivesOutput() public {
        address bob = address(0xB0B);
        uint256 b1Before = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bob);

        vm.prank(ALICE);
        uint256 out = router.swap(poolKey, true, 1e16, 0, bob, ZERO_BYTES);

        uint256 b1After = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(bob);
        assertEq(b1After - b1Before, out, "bob got the output");
    }

    // -----------------------------------------------------------------
    // Slippage
    // -----------------------------------------------------------------

    function test_swap_acceptsAtMinimum() public {
        // First learn the actual output for this swap size at this state.
        uint256 snap = vm.snapshotState();
        vm.prank(ALICE);
        uint256 quote = router.swap(poolKey, true, 1e16, 0, ALICE, ZERO_BYTES);
        vm.revertToState(snap);

        // Now demand exactly that. Should pass.
        vm.prank(ALICE);
        uint256 out = router.swap(poolKey, true, 1e16, quote, ALICE, ZERO_BYTES);
        assertEq(out, quote);
    }

    function testRevert_swap_slippageTooTight() public {
        uint256 snap = vm.snapshotState();
        vm.prank(ALICE);
        uint256 quote = router.swap(poolKey, true, 1e16, 0, ALICE, ZERO_BYTES);
        vm.revertToState(snap);

        // Demand one wei more than achievable.
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(WoolFiSwapRouter.InsufficientOutput.selector, quote, quote + 1));
        router.swap(poolKey, true, 1e16, quote + 1, ALICE, ZERO_BYTES);
    }

    // -----------------------------------------------------------------
    // Revert paths
    // -----------------------------------------------------------------

    function testRevert_swap_zeroAmount() public {
        vm.prank(ALICE);
        vm.expectRevert(WoolFiSwapRouter.ZeroAmount.selector);
        router.swap(poolKey, true, 0, 0, ALICE, ZERO_BYTES);
    }

    function testRevert_unlockCallback_notPoolManager() public {
        vm.expectRevert(WoolFiSwapRouter.NotPoolManager.selector);
        router.unlockCallback(bytes(""));
    }
}
