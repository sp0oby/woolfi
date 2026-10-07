// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {UrufuFeeRebateDistributor} from "../../src/UrufuFeeRebateDistributor.sol";
import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockRebateHook, MockNftBalance} from "./mocks/RebateMocks.sol";

/// @notice Branch-level unit tests for the rebate distributor: constructor and admin validation,
///         every early return in `recordSwap`, funding and cap clamps, week rollover, and the
///         withdraw and claim revert paths.
contract UrufuFeeRebateDistributorTest is Test {
    UrufuFeeRebateDistributor dist;
    MockRebateHook hook;
    MockNftBalance nft;
    MockERC20 token;
    address owner = makeAddr("owner");
    address trader = makeAddr("trader");
    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));

    // 1e22 * 30 / 1e4 * 1500 / 1e4 = 4.5e18
    uint256 constant AMOUNT_IN = 1e22;
    uint256 constant FULL_REBATE = 4.5e18;

    function setUp() public {
        vm.warp(10 weeks);
        hook = new MockRebateHook();
        nft = new MockNftBalance();
        token = new MockERC20("T", "T", 18);
        dist = new UrufuFeeRebateDistributor(WoolFiHook(address(hook)), address(nft), owner);
        vm.startPrank(owner);
        dist.setRouter(address(this));
        dist.setWeeklyCap(address(token), 100e18);
        vm.stopPrank();
        hook.setPool(POOL, true, 30);
        hook.setFee(POOL, 30);
        nft.set(trader, 1);
        _fund(1_000e18);
    }

    function _fund(uint256 amount) internal {
        token.mint(address(this), amount);
        token.approve(address(dist), amount);
        dist.fund(address(token), amount);
    }

    // ---------------------------------------------------------------- constructor

    function testRevert_constructor_zeroHook() public {
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        new UrufuFeeRebateDistributor(WoolFiHook(address(0)), address(nft), owner);
    }

    function testRevert_constructor_zeroNft() public {
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        new UrufuFeeRebateDistributor(WoolFiHook(address(hook)), address(0), owner);
    }

    function testRevert_constructor_zeroOwner() public {
        // Ownable rejects a zero owner before the constructor body runs.
        vm.expectRevert();
        new UrufuFeeRebateDistributor(WoolFiHook(address(hook)), address(nft), address(0));
    }

    function testRevert_constructor_hookWithoutCode() public {
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        new UrufuFeeRebateDistributor(WoolFiHook(makeAddr("eoaHook")), address(nft), owner);
    }

    function testRevert_constructor_nftWithoutCode() public {
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        new UrufuFeeRebateDistributor(WoolFiHook(address(hook)), makeAddr("eoaNft"), owner);
    }

    // ---------------------------------------------------------------- admin

    function testRevert_setRouter_alreadySet() public {
        vm.prank(owner);
        vm.expectRevert(UrufuFeeRebateDistributor.RouterAlreadySet.selector);
        dist.setRouter(address(hook));
    }

    function testRevert_setRouter_zeroOrNoCode() public {
        UrufuFeeRebateDistributor fresh = new UrufuFeeRebateDistributor(WoolFiHook(address(hook)), address(nft), owner);
        vm.startPrank(owner);
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidRouter.selector);
        fresh.setRouter(address(0));
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidRouter.selector);
        fresh.setRouter(makeAddr("eoaRouter"));
        vm.stopPrank();
    }

    function testRevert_setRouter_notOwner() public {
        UrufuFeeRebateDistributor fresh = new UrufuFeeRebateDistributor(WoolFiHook(address(hook)), address(nft), owner);
        vm.expectRevert();
        fresh.setRouter(address(this));
    }

    function testRevert_setWeeklyCap_zeroToken() public {
        vm.prank(owner);
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        dist.setWeeklyCap(address(0), 1);
    }

    function test_setWeeklyCap_uint192Boundary() public {
        vm.startPrank(owner);
        dist.setWeeklyCap(address(token), type(uint192).max);
        assertEq(dist.weeklyCap(address(token)), type(uint192).max);
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidCap.selector);
        dist.setWeeklyCap(address(token), uint256(type(uint192).max) + 1);
        vm.stopPrank();
    }

    function testRevert_fund_zeroTokenOrAmount() public {
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        dist.fund(address(0), 1);
        vm.expectRevert(UrufuFeeRebateDistributor.ZeroAmount.selector);
        dist.fund(address(token), 0);
    }

    // ---------------------------------------------------------------- recordSwap

    function testRevert_recordSwap_notRouter() public {
        vm.prank(trader);
        vm.expectRevert(UrufuFeeRebateDistributor.NotRouter.selector);
        dist.recordSwap(trader, POOL, address(token), AMOUNT_IN);
    }

    function test_recordSwap_fullRebate() public {
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), FULL_REBATE);
        assertEq(dist.claimable(trader, address(token)), FULL_REBATE);
        assertEq(dist.totalLiability(address(token)), FULL_REBATE);
    }

    function test_recordSwap_zeroCapReturnsZero() public {
        vm.prank(owner);
        dist.setWeeklyCap(address(token), 0);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0);
    }

    function test_recordSwap_nonHolderReturnsZero() public {
        nft.set(trader, 0);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0);
    }

    function test_recordSwap_unconfiguredPoolReturnsZero() public {
        hook.setPool(POOL, false, 30);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0);
    }

    function test_recordSwap_surchargeClampedToBaseFee() public {
        hook.setFee(POOL, 400);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), FULL_REBATE, "surcharge not rebated");
    }

    function test_recordSwap_discountedFeeEarnsLess() public {
        hook.setFee(POOL, 10);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), FULL_REBATE / 3);
    }

    function test_recordSwap_dustRoundsToZero() public {
        // 1000 * 30 / 1e4 = 3; 3 * 1500 / 1e4 = 0
        assertEq(dist.recordSwap(trader, POOL, address(token), 1000), 0);
        assertEq(dist.totalLiability(address(token)), 0);
    }

    function test_recordSwap_zeroAmountIn() public {
        assertEq(dist.recordSwap(trader, POOL, address(token), 0), 0);
    }

    function test_recordSwap_unfundedReturnsZero() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        vm.prank(owner);
        dist.setWeeklyCap(address(other), 100e18);
        assertEq(dist.recordSwap(trader, POOL, address(other), AMOUNT_IN), 0);
    }

    function test_recordSwap_fullyReservedReturnsZero() public {
        // Leave exactly 1e18 unreserved, reserve it all, then the next swap gets nothing.
        vm.prank(owner);
        dist.withdrawUnreserved(address(token), owner, 1_000e18 - 1e18);
        address other = makeAddr("other");
        nft.set(other, 1);
        assertEq(dist.recordSwap(other, POOL, address(token), 1e30), 1e18, "clamped to available");
        assertEq(dist.unreserved(address(token)), 0);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0, "balance == liability");
    }

    function test_recordSwap_clampedToWeeklyCapThenZero() public {
        vm.prank(owner);
        dist.setWeeklyCap(address(token), 5e18);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), FULL_REBATE);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 5e18 - FULL_REBATE, "cap remainder");
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0, "cap exhausted");
        (uint64 week, uint192 used) = dist.weeklyUsage(trader, address(token));
        assertEq(week, block.timestamp / 1 weeks);
        assertEq(used, 5e18);
    }

    function test_recordSwap_weekRolloverResetsCap() public {
        vm.prank(owner);
        dist.setWeeklyCap(address(token), FULL_REBATE);
        dist.recordSwap(trader, POOL, address(token), AMOUNT_IN);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0, "same week capped");

        // The last second of the week is still capped; the first second of the next resets.
        vm.warp((block.timestamp / 1 weeks + 1) * 1 weeks - 1);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0, "boundary-1 still capped");
        vm.warp(block.timestamp + 1);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), FULL_REBATE, "new week resets");
        assertEq(dist.claimable(trader, address(token)), 2 * FULL_REBATE);
    }

    function test_recordSwap_capLoweredBelowUsage() public {
        dist.recordSwap(trader, POOL, address(token), AMOUNT_IN);
        vm.prank(owner);
        dist.setWeeklyCap(address(token), 1e18);
        assertEq(dist.recordSwap(trader, POOL, address(token), AMOUNT_IN), 0, "used >= cap");
    }

    // ---------------------------------------------------------------- withdraw / claim

    function test_withdrawUnreserved_leavesLiabilities() public {
        dist.recordSwap(trader, POOL, address(token), AMOUNT_IN);
        uint256 free = dist.unreserved(address(token));
        assertEq(free, 1_000e18 - FULL_REBATE);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(UrufuFeeRebateDistributor.ExceedsUnreserved.selector, free + 1, free));
        dist.withdrawUnreserved(address(token), owner, free + 1);
        dist.withdrawUnreserved(address(token), owner, free);
        vm.stopPrank();
        assertEq(dist.unreserved(address(token)), 0);
        vm.prank(trader);
        assertEq(dist.claim(address(token), trader), FULL_REBATE, "accrued rebate still claimable");
    }

    function test_unreserved_zeroWhenUnfunded() public {
        MockERC20 other = new MockERC20("O", "O", 18);
        assertEq(dist.unreserved(address(other)), 0);
    }

    function testRevert_withdrawUnreserved_validation() public {
        vm.startPrank(owner);
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        dist.withdrawUnreserved(address(0), owner, 1);
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        dist.withdrawUnreserved(address(token), address(0), 1);
        vm.expectRevert(UrufuFeeRebateDistributor.ZeroAmount.selector);
        dist.withdrawUnreserved(address(token), owner, 0);
        vm.stopPrank();
        vm.expectRevert();
        dist.withdrawUnreserved(address(token), owner, 1);
    }

    function test_claim_toOtherRecipient() public {
        dist.recordSwap(trader, POOL, address(token), AMOUNT_IN);
        address dest = makeAddr("dest");
        vm.prank(trader);
        dist.claim(address(token), dest);
        assertEq(token.balanceOf(dest), FULL_REBATE);
        assertEq(dist.claimable(trader, address(token)), 0);
        assertEq(dist.totalLiability(address(token)), 0);
    }

    function testRevert_claim_zeroRecipient() public {
        vm.prank(trader);
        vm.expectRevert(UrufuFeeRebateDistributor.InvalidAddress.selector);
        dist.claim(address(token), address(0));
    }

    function testRevert_claim_nothingAccrued() public {
        vm.prank(trader);
        vm.expectRevert(UrufuFeeRebateDistributor.ZeroAmount.selector);
        dist.claim(address(token), trader);
    }

    function test_rebateStaysWithWallet_afterNftTransfer() public {
        dist.recordSwap(trader, POOL, address(token), AMOUNT_IN);
        nft.set(trader, 0);
        vm.prank(trader);
        assertEq(dist.claim(address(token), trader), FULL_REBATE);
    }
}
