// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiPositionManager} from "../src/WoolFiPositionManager.sol";
import {LiquidityAmounts} from "../src/lib/LiquidityAmounts.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Seeds one receipt-tracked pool with approved, slippage-protected initial liquidity.
/// @dev Run once per canonical pool. TOKEN0 must sort below TOKEN1. MIN_SHARES and DEADLINE are
///      mandatory so a stale simulation cannot silently accept a different pool ratio.
///
///      Slippage: shares equal full-range liquidity at the pool's price, and for fixed amounts that
///      liquidity peaks at the price the amounts were sized for. So the script computes the shares
///      the approved amounts would mint at REFERENCE_SQRT_PRICE_X96 (the approved launch price) and
///      requires at least that minus SLIPPAGE_BPS. Seeding into a pool that has moved away from the
///      approved price, before or during inclusion, mints fewer shares and reverts.
contract SeedInitialLiquidity is RobinhoodBroadcastGuard {
    uint256 internal constant MAX_SLIPPAGE_BPS = 1_000;

    struct SeedConfig {
        address provider;
        address recipient;
        address token0;
        address token1;
        address hook;
        WoolFiPositionManager pm;
        uint256 amount0;
        uint256 amount1;
        uint128 minShares;
        uint256 deadline;
        int24 tickSpacing;
        uint160 referenceSqrtPriceX96;
        uint256 slippageBps;
    }

    function run() external returns (uint128 shares) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        SeedConfig memory c = _load(pk);
        _validate(c);
        uint128 slippageFloor =
            minSharesForSlippage(c.referenceSqrtPriceX96, c.tickSpacing, c.amount0, c.amount1, c.slippageBps);
        if (slippageFloor > c.minShares) c.minShares = slippageFloor;
        console2.log("min LP shares", c.minShares);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(c.token0),
            currency1: Currency.wrap(c.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: c.tickSpacing,
            hooks: IHooks(c.hook)
        });

        vm.startBroadcast(pk);
        require(IERC20(c.token0).approve(address(c.pm), c.amount0), "SeedInitialLiquidity: token0 approve");
        require(IERC20(c.token1).approve(address(c.pm), c.amount1), "SeedInitialLiquidity: token1 approve");
        shares = c.pm.mint(key, c.amount0, c.amount1, c.minShares, c.deadline, c.recipient);
        require(IERC20(c.token0).approve(address(c.pm), 0), "SeedInitialLiquidity: token0 reset");
        require(IERC20(c.token1).approve(address(c.pm), 0), "SeedInitialLiquidity: token1 reset");
        vm.stopBroadcast();
        console2.log("LP shares", shares);
    }

    function _load(uint256 pk) private view returns (SeedConfig memory c) {
        c.provider = vm.addr(pk);
        c.recipient = vm.envOr("LP_RECIPIENT", c.provider);
        c.token0 = vm.envAddress("TOKEN0");
        c.token1 = vm.envAddress("TOKEN1");
        c.hook = vm.envAddress("HOOK");
        c.pm = WoolFiPositionManager(vm.envAddress("POSITION_MANAGER"));
        c.amount0 = vm.envUint("INITIAL_LIQUIDITY_0");
        c.amount1 = vm.envUint("INITIAL_LIQUIDITY_1");
        uint256 minShares = vm.envUint("MIN_SHARES");
        require(minShares <= type(uint128).max, "SeedInitialLiquidity: MIN_SHARES overflow");
        c.minShares = uint128(minShares);
        c.deadline = vm.envUint("DEADLINE");
        uint256 tickSpacing = vm.envUint("TICK_SPACING");
        require(tickSpacing <= uint256(uint24(type(int24).max)), "SeedInitialLiquidity: TICK_SPACING overflow");
        c.tickSpacing = int24(uint24(tickSpacing));
        uint256 refPrice = vm.envUint("REFERENCE_SQRT_PRICE_X96");
        require(refPrice <= type(uint160).max, "SeedInitialLiquidity: REFERENCE_SQRT_PRICE_X96 overflow");
        c.referenceSqrtPriceX96 = uint160(refPrice);
        c.slippageBps = vm.envUint("SLIPPAGE_BPS");
    }

    /// @notice Shares the approved amounts mint at the reference price, less `slippageBps`.
    function minSharesForSlippage(
        uint160 referenceSqrtPriceX96,
        int24 tickSpacing,
        uint256 amount0,
        uint256 amount1,
        uint256 slippageBps
    ) public pure returns (uint128) {
        require(slippageBps > 0 && slippageBps <= MAX_SLIPPAGE_BPS, "SeedInitialLiquidity: SLIPPAGE_BPS out of range");
        require(
            referenceSqrtPriceX96 > TickMath.MIN_SQRT_PRICE && referenceSqrtPriceX96 < TickMath.MAX_SQRT_PRICE,
            "SeedInitialLiquidity: bad reference price"
        );
        uint128 expected = LiquidityAmounts.getLiquidityForAmounts(
            referenceSqrtPriceX96,
            TickMath.getSqrtPriceAtTick(TickMath.minUsableTick(tickSpacing)),
            TickMath.getSqrtPriceAtTick(TickMath.maxUsableTick(tickSpacing)),
            amount0,
            amount1
        );
        require(expected > 0, "SeedInitialLiquidity: zero expected shares");
        return uint128((uint256(expected) * (10_000 - slippageBps)) / 10_000);
    }

    function _validate(SeedConfig memory c) private view {
        require(c.token0 < c.token1, "SeedInitialLiquidity: unsorted tokens");
        require(c.token0.code.length > 0 && c.token1.code.length > 0, "SeedInitialLiquidity: token has no code");
        require(address(c.pm).code.length > 0 && c.hook.code.length > 0, "SeedInitialLiquidity: core has no code");
        require(c.amount0 > 0 && c.amount1 > 0 && c.minShares > 0, "SeedInitialLiquidity: zero amount");
        require(c.deadline >= block.timestamp, "SeedInitialLiquidity: expired");
    }
}
