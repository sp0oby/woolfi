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
import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiSwapRouter} from "../../src/WoolFiSwapRouter.sol";
import {UrufuFeeRebateDistributor} from "../../src/UrufuFeeRebateDistributor.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {SpreadMath} from "../../src/lib/SpreadMath.sol";
import {IFeeRebateDistributor} from "../../src/interfaces/IFeeRebateDistributor.sol";

contract MockUrufuNft is ERC721 {
    constructor() ERC721("Urufu Gemu", "URUFU") {}

    function mint(address to, uint256 tokenId) external {
        _mint(to, tokenId);
    }
}

/// @notice Distributor that always reverts, to prove rebate accounting is fail-open.
contract RevertingDistributor {
    error Boom();

    function recordSwap(address, PoolId, address, uint256) external pure returns (uint256) {
        revert Boom();
    }
}

/// @notice Integration tests for WoolFiSwapRouter against a real v4 PoolManager + WoolFi hook.
contract WoolFiSwapRouterTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiSwapRouter router;
    UrufuFeeRebateDistributor rebateDistributor;
    MockUrufuNft urufuNft;
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

        urufuNft = new MockUrufuNft();
        rebateDistributor = new UrufuFeeRebateDistributor(hook, address(urufuNft), address(this));
        router = new WoolFiSwapRouter(manager, rebateDistributor);
        rebateDistributor.setRouter(address(router));
        rebateDistributor.setWeeklyCap(Currency.unwrap(currency0), 1e18);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(rebateDistributor), 1e18);
        rebateDistributor.fund(Currency.unwrap(currency0), 1e18);

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

    function test_swap_nftHolderAccruesAndClaimsBaseFeeRebate() public {
        uint256 amountIn = 1e16;
        uint256 expected = amountIn * 30 / 10_000 * 1_500 / 10_000;
        urufuNft.mint(ALICE, 1);

        vm.prank(ALICE);
        router.swap(poolKey, true, amountIn, 0, ALICE, ZERO_BYTES);

        address tokenIn = Currency.unwrap(currency0);
        assertEq(rebateDistributor.claimable(ALICE, tokenIn), expected);
        uint256 beforeClaim = IERC20Minimal(tokenIn).balanceOf(ALICE);
        vm.prank(ALICE);
        assertEq(rebateDistributor.claim(tokenIn, ALICE), expected);
        assertEq(IERC20Minimal(tokenIn).balanceOf(ALICE) - beforeClaim, expected);
    }

    function test_swap_nonHolderGetsNoRebate() public {
        vm.prank(ALICE);
        router.swap(poolKey, true, 1e16, 0, ALICE, ZERO_BYTES);

        assertEq(rebateDistributor.claimable(ALICE, Currency.unwrap(currency0)), 0);
    }

    function test_swap_rebateIsClampedToWeeklyCap() public {
        uint256 amountIn = 1e16;
        uint256 expected = amountIn * 30 / 10_000 * 1_500 / 10_000;
        uint256 cap = expected / 2;
        urufuNft.mint(ALICE, 1);
        rebateDistributor.setWeeklyCap(Currency.unwrap(currency0), cap);

        vm.prank(ALICE);
        router.swap(poolKey, true, amountIn, 0, ALICE, ZERO_BYTES);

        assertEq(rebateDistributor.claimable(ALICE, Currency.unwrap(currency0)), cap);
    }

    function test_swap_unfundedInputTokenAccruesNothing() public {
        urufuNft.mint(ALICE, 1);
        rebateDistributor.setWeeklyCap(Currency.unwrap(currency1), 1e18);

        vm.prank(ALICE);
        router.swap(poolKey, false, 1e16, 0, ALICE, ZERO_BYTES);

        assertEq(rebateDistributor.claimable(ALICE, Currency.unwrap(currency1)), 0);
    }

    function test_nftTransferDoesNotMoveEarnedRebate() public {
        address bob = address(0xB0B);
        urufuNft.mint(ALICE, 1);

        vm.prank(ALICE);
        router.swap(poolKey, true, 1e16, 0, ALICE, ZERO_BYTES);
        uint256 earned = rebateDistributor.claimable(ALICE, Currency.unwrap(currency0));

        vm.prank(ALICE);
        urufuNft.transferFrom(ALICE, bob, 1);

        assertGt(earned, 0);
        assertEq(rebateDistributor.claimable(ALICE, Currency.unwrap(currency0)), earned);
        assertEq(rebateDistributor.claimable(bob, Currency.unwrap(currency0)), 0);
    }

    /// @notice M-2: a discounted corrective swap is rebated on the fee actually charged, not the
    ///         configured base fee.
    function test_rebate_correctiveSwapUsesChargedFee() public {
        uint256 amountIn = 1e16;
        urufuNft.mint(ALICE, 1);
        oracle0.setPrice(925_925_925_925_925_926); // pool 1.0 above fair: drift ~+800 bps
        int256 drift = hook.currentDrift(poolKey);
        uint256 charged = SpreadMath.asymmetricFee(30, drift, 40_000, true);
        assertLt(charged, 30, "corrective fee is discounted");

        vm.prank(ALICE);
        router.swap(poolKey, true, amountIn, 0, ALICE, ZERO_BYTES); // zeroForOne lowers price: corrective

        uint256 expected = amountIn * charged / 10_000 * 1_500 / 10_000;
        uint256 baseRebate = amountIn * 30 / 10_000 * 1_500 / 10_000;
        assertEq(rebateDistributor.claimable(ALICE, Currency.unwrap(currency0)), expected);
        assertLt(expected, baseRebate);
    }

    /// @notice An adversarial (surcharged) swap is rebated at most the base-fee amount.
    function test_rebate_adversarialSwapCappedAtBaseFee() public {
        uint256 amountIn = 1e16;
        urufuNft.mint(ALICE, 1);
        rebateDistributor.setWeeklyCap(Currency.unwrap(currency1), 1e18);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(rebateDistributor), 1e18);
        rebateDistributor.fund(Currency.unwrap(currency1), 1e18);
        oracle0.setPrice(925_925_925_925_925_926); // drift ~+800 bps

        vm.prank(ALICE);
        router.swap(poolKey, false, amountIn, 0, ALICE, ZERO_BYTES); // oneForZero raises price: adversarial

        uint256 baseRebate = amountIn * 30 / 10_000 * 1_500 / 10_000;
        assertEq(rebateDistributor.claimable(ALICE, Currency.unwrap(currency1)), baseRebate);
    }

    function test_withdrawUnreserved_respectsLiabilities() public {
        address token = Currency.unwrap(currency0);
        urufuNft.mint(ALICE, 1);
        vm.prank(ALICE);
        router.swap(poolKey, true, 1e16, 0, ALICE, ZERO_BYTES);
        uint256 owed = rebateDistributor.claimable(ALICE, token);
        assertGt(owed, 0);
        uint256 free = rebateDistributor.unreserved(token);
        assertEq(free, 1e18 - owed);

        vm.expectRevert(abi.encodeWithSelector(UrufuFeeRebateDistributor.ExceedsUnreserved.selector, free + 1, free));
        rebateDistributor.withdrawUnreserved(token, address(this), free + 1);

        address treasury = address(0x7EA5);
        rebateDistributor.withdrawUnreserved(token, treasury, free);
        assertEq(IERC20Minimal(token).balanceOf(treasury), free);
        assertEq(rebateDistributor.unreserved(token), 0);

        vm.prank(ALICE);
        assertEq(rebateDistributor.claim(token, ALICE), owed); // accrued rebate still fully claimable
    }

    function testRevert_withdrawUnreserved_notOwner() public {
        vm.prank(ALICE);
        vm.expectRevert();
        rebateDistributor.withdrawUnreserved(Currency.unwrap(currency0), ALICE, 1);
    }

    function test_distributor_twoStepOwnership() public {
        address newOwner = address(0xB0B);
        rebateDistributor.transferOwnership(newOwner);
        assertEq(rebateDistributor.owner(), address(this));
        assertEq(rebateDistributor.pendingOwner(), newOwner);
        vm.prank(newOwner);
        rebateDistributor.acceptOwnership();
        assertEq(rebateDistributor.owner(), newOwner);
    }

    function testRevert_rebateRecord_onlyRouter() public {
        vm.expectRevert(UrufuFeeRebateDistributor.NotRouter.selector);
        rebateDistributor.recordSwap(ALICE, poolId, Currency.unwrap(currency0), 1e16);
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
    // -----------------------------------------------------------------
    // Rebate module wiring
    // -----------------------------------------------------------------

    function _routerWith(IFeeRebateDistributor d) internal returns (WoolFiSwapRouter r) {
        r = new WoolFiSwapRouter(manager, d);
        vm.startPrank(ALICE);
        IERC20Minimal(Currency.unwrap(currency0)).approve(address(r), type(uint256).max);
        IERC20Minimal(Currency.unwrap(currency1)).approve(address(r), type(uint256).max);
        vm.stopPrank();
    }

    function test_swap_withoutDistributor_skipsRebate() public {
        WoolFiSwapRouter bare = _routerWith(IFeeRebateDistributor(address(0)));
        urufuNft.mint(ALICE, 77);
        vm.prank(ALICE);
        uint256 out = bare.swap(poolKey, true, 1e16, 0, ALICE, ZERO_BYTES);
        assertGt(out, 0);
        assertEq(rebateDistributor.claimable(ALICE, Currency.unwrap(currency0)), 0, "no rebate path");
    }

    function test_swap_revertingDistributor_failsOpen() public {
        WoolFiSwapRouter r = _routerWith(IFeeRebateDistributor(address(new RevertingDistributor())));
        vm.expectEmit(true, false, false, true, address(r));
        emit WoolFiSwapRouter.RebateRecordFailed(ALICE, abi.encodeWithSelector(RevertingDistributor.Boom.selector));
        vm.prank(ALICE);
        uint256 out = r.swap(poolKey, false, 1e16, 0, ALICE, ZERO_BYTES);
        assertGt(out, 0, "trade settles even though rebate accounting reverted");
    }

    function test_swap_holderEmitsRebateRecorded() public {
        urufuNft.mint(ALICE, 78);
        vm.expectEmit(true, true, false, false, address(router));
        emit WoolFiSwapRouter.RebateRecorded(ALICE, Currency.unwrap(currency0), 0);
        vm.prank(ALICE);
        router.swap(poolKey, true, 1e18, 0, ALICE, ZERO_BYTES);
    }

    function test_swap_dustInputYieldsZeroOutput() public {
        // One wei in rounds to zero out: the take leg has nothing to pull.
        uint256 b1 = IERC20Minimal(Currency.unwrap(currency1)).balanceOf(ALICE);
        vm.prank(ALICE);
        uint256 out = router.swap(poolKey, true, 1, 0, ALICE, ZERO_BYTES);
        assertEq(out, 0);
        assertEq(IERC20Minimal(Currency.unwrap(currency1)).balanceOf(ALICE), b1);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(WoolFiSwapRouter.InsufficientOutput.selector, 0, 1));
        router.swap(poolKey, true, 1, 1, ALICE, ZERO_BYTES);
    }

    function testFuzz_swap_slippageBoundExact(uint256 amountIn, bool zeroForOne) public {
        amountIn = bound(amountIn, 1e6, 5e18);
        uint256 snap = vm.snapshotState();
        vm.prank(ALICE);
        uint256 quote = router.swap(poolKey, zeroForOne, amountIn, 0, ALICE, ZERO_BYTES);
        vm.revertToState(snap);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(WoolFiSwapRouter.InsufficientOutput.selector, quote, quote + 1));
        router.swap(poolKey, zeroForOne, amountIn, quote + 1, ALICE, ZERO_BYTES);
        vm.prank(ALICE);
        assertEq(router.swap(poolKey, zeroForOne, amountIn, quote, ALICE, ZERO_BYTES), quote);
    }
}
