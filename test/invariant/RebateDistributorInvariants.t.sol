// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {UrufuFeeRebateDistributor} from "../../src/UrufuFeeRebateDistributor.sol";
import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";
import {MockRebateHook, MockNftBalance} from "../unit/mocks/RebateMocks.sol";

/// @notice Drives the distributor as router, owner, funder and traders.
contract RebateDistributorHandler is Test {
    UrufuFeeRebateDistributor immutable dist;
    MockRebateHook immutable hook;
    MockNftBalance immutable nft;
    address immutable owner;
    MockERC20[2] public tokens;
    address[4] public traders;
    PoolId constant POOL = PoolId.wrap(bytes32(uint256(1)));

    uint256 public ghostAccrued0;
    uint256 public ghostClaimed0;
    uint256 public capViolations;

    constructor(
        UrufuFeeRebateDistributor _dist,
        MockRebateHook _hook,
        MockNftBalance _nft,
        address _owner,
        MockERC20 t0,
        MockERC20 t1
    ) {
        dist = _dist;
        hook = _hook;
        nft = _nft;
        owner = _owner;
        tokens = [t0, t1];
        traders = [makeAddr("tr0"), makeAddr("tr1"), makeAddr("tr2"), makeAddr("tr3")];
    }

    function recordSwap(uint256 traderSeed, uint256 tokenSeed, uint256 amountIn, uint256 feeBps) external {
        address trader = traders[traderSeed % traders.length];
        MockERC20 t = tokens[tokenSeed % 2];
        hook.setFee(POOL, bound(feeBps, 0, 1000));
        amountIn = bound(amountIn, 0, 1e30);
        uint256 week = block.timestamp / 1 weeks;
        (uint64 w, uint192 usedBefore) = dist.weeklyUsage(trader, address(t));
        uint256 used = w == week ? usedBefore : 0;
        uint256 rebate = dist.recordSwap(trader, POOL, address(t), amountIn);
        if (used + rebate > dist.weeklyCap(address(t)) && rebate > 0) capViolations++;
        if (tokenSeed % 2 == 0) ghostAccrued0 += rebate;
    }

    function fund(uint256 tokenSeed, uint256 amount) external {
        MockERC20 t = tokens[tokenSeed % 2];
        amount = bound(amount, 1, 1e24);
        t.mint(address(this), amount);
        t.approve(address(dist), amount);
        dist.fund(address(t), amount);
    }

    /// @dev Direct transfers (donations) also count as funding.
    function donate(uint256 tokenSeed, uint256 amount) external {
        tokens[tokenSeed % 2].mint(address(dist), bound(amount, 1, 1e22));
    }

    function claim(uint256 traderSeed, uint256 tokenSeed) external {
        address trader = traders[traderSeed % traders.length];
        MockERC20 t = tokens[tokenSeed % 2];
        if (dist.claimable(trader, address(t)) == 0) return;
        vm.prank(trader);
        uint256 amount = dist.claim(address(t), trader);
        if (tokenSeed % 2 == 0) ghostClaimed0 += amount;
    }

    function withdrawUnreserved(uint256 tokenSeed, uint256 amount) external {
        MockERC20 t = tokens[tokenSeed % 2];
        uint256 free = dist.unreserved(address(t));
        if (free == 0) return;
        vm.prank(owner);
        dist.withdrawUnreserved(address(t), owner, bound(amount, 1, free));
    }

    function setCap(uint256 tokenSeed, uint256 cap) external {
        vm.prank(owner);
        dist.setWeeklyCap(address(tokens[tokenSeed % 2]), bound(cap, 0, 1e24));
    }

    function toggleHolder(uint256 traderSeed) external {
        address trader = traders[traderSeed % traders.length];
        nft.set(trader, nft.balanceOf(trader) == 0 ? 1 : 0);
    }

    function warp(uint256 s) external {
        skip(bound(s, 1, 10 days));
    }

    function sumClaimable(address token) external view returns (uint256 total) {
        for (uint256 i; i < traders.length; i++) {
            total += dist.claimable(traders[i], token);
        }
    }
}

/// @notice (f) The distributor never owes more than it holds, liabilities equal the sum of
///         claimables, and no wallet ever accrues beyond its weekly cap.
contract RebateDistributorInvariantsTest is Test {
    UrufuFeeRebateDistributor dist;
    RebateDistributorHandler handler;
    MockERC20 t0;
    MockERC20 t1;

    function setUp() public {
        vm.warp(10 weeks);
        address owner = makeAddr("owner");
        MockRebateHook hook = new MockRebateHook();
        MockNftBalance nft = new MockNftBalance();
        t0 = new MockERC20("A", "A", 18);
        t1 = new MockERC20("B", "B", 6);
        dist = new UrufuFeeRebateDistributor(WoolFiHook(address(hook)), address(nft), owner);
        hook.setPool(PoolId.wrap(bytes32(uint256(1))), true, 30);
        handler = new RebateDistributorHandler(dist, hook, nft, owner, t0, t1);
        vm.startPrank(owner);
        dist.setRouter(address(handler));
        dist.setWeeklyCap(address(t0), 50e18);
        dist.setWeeklyCap(address(t1), 50e6);
        vm.stopPrank();
        for (uint256 i; i < 4; i++) {
            if (i % 2 == 0) nft.set(handler.traders(i), 1);
        }
        targetContract(address(handler));
    }

    function invariant_liabilitiesNeverExceedBalance() public view {
        assertLe(dist.totalLiability(address(t0)), t0.balanceOf(address(dist)), "token0 over-promised");
        assertLe(dist.totalLiability(address(t1)), t1.balanceOf(address(dist)), "token1 over-promised");
    }

    function invariant_liabilityEqualsSumOfClaimables() public view {
        assertEq(dist.totalLiability(address(t0)), handler.sumClaimable(address(t0)));
        assertEq(dist.totalLiability(address(t1)), handler.sumClaimable(address(t1)));
    }

    function invariant_accruedMinusClaimedIsLiability() public view {
        assertEq(handler.ghostAccrued0() - handler.ghostClaimed0(), dist.totalLiability(address(t0)));
    }

    function invariant_weeklyCapRespected() public view {
        assertEq(handler.capViolations(), 0, "wallet exceeded weekly cap");
    }
}
