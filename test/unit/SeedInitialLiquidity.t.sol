// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

import {LiquidityAmounts} from "../../src/lib/LiquidityAmounts.sol";
import {SeedInitialLiquidity} from "../../script/SeedInitialLiquidity.s.sol";

/// @notice The seed script's slippage floor: approved amounts sized at the launch price must not mint
///         into a pool that has moved away from that price.
contract SeedInitialLiquidityTest is Test {
    int24 constant SPACING = 60;
    SeedInitialLiquidity script;

    function setUp() public {
        script = new SeedInitialLiquidity();
    }

    /// Amounts that exactly fund `liquidity` across the full range at `sqrtPrice`.
    function _amountsAt(uint160 sqrtPrice, uint128 liquidity) internal pure returns (uint256 a0, uint256 a1) {
        uint160 lo = TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(SPACING));
        uint160 hi = TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(SPACING));
        a0 = SqrtPriceMath.getAmount0Delta(sqrtPrice, hi, liquidity, true);
        a1 = SqrtPriceMath.getAmount1Delta(lo, sqrtPrice, liquidity, true);
    }

    function _sharesAt(uint160 sqrtPrice, uint256 a0, uint256 a1) internal pure returns (uint128) {
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(SPACING)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(SPACING)),
            a0,
            a1
        );
    }

    function test_floorIsExpectedSharesLessSlippage() public view {
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        (uint256 a0, uint256 a1) = _amountsAt(ref, 1e18);
        uint128 expected = _sharesAt(ref, a0, a1);
        assertEq(script.minSharesForSlippage(ref, SPACING, a0, a1, 100), uint128((uint256(expected) * 9_900) / 10_000));
    }

    function test_seedAtReferencePriceClearsFloor() public view {
        uint160 ref = TickMath.getSqrtPriceAtTick(-23_000);
        (uint256 a0, uint256 a1) = _amountsAt(ref, 5e20);
        assertGe(_sharesAt(ref, a0, a1), script.minSharesForSlippage(ref, SPACING, a0, a1, 50));
    }

    /// A pool roughly 4% away from the launch price (400 ticks) mints well under a 1% floor, in
    /// either direction, so the seed transaction reverts instead of seeding at a bad ratio.
    function test_movedPoolFallsBelowFloor() public view {
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        (uint256 a0, uint256 a1) = _amountsAt(ref, 1e18);
        uint128 floor_ = script.minSharesForSlippage(ref, SPACING, a0, a1, 100);
        assertLt(_sharesAt(TickMath.getSqrtPriceAtTick(400), a0, a1), floor_);
        assertLt(_sharesAt(TickMath.getSqrtPriceAtTick(-400), a0, a1), floor_);
    }

    function test_rejectsOutOfRangeSlippage() public {
        uint160 ref = TickMath.getSqrtPriceAtTick(0);
        vm.expectRevert(bytes("SeedInitialLiquidity: SLIPPAGE_BPS out of range"));
        script.minSharesForSlippage(ref, SPACING, 1e18, 1e18, 0);
        vm.expectRevert(bytes("SeedInitialLiquidity: SLIPPAGE_BPS out of range"));
        script.minSharesForSlippage(ref, SPACING, 1e18, 1e18, 1_001);
    }

    function test_rejectsBadReferencePrice() public {
        vm.expectRevert(bytes("SeedInitialLiquidity: bad reference price"));
        script.minSharesForSlippage(0, SPACING, 1e18, 1e18, 100);
    }
}
