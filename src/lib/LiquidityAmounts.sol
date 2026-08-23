// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LiquidityAmounts
/// @notice Minimal liquidity<->amount conversion for full-range positions.
/// @dev Vendored standard Uniswap v3/v4 math (the only piece WoolFi needs is
///      {getLiquidityForAmounts}), implemented on solady's `fullMulDiv` to avoid pulling the
///      v4-periphery dependency. `getAmountsForLiquidity` is not needed: v4's `modifyLiquidity`
///      returns the realized amounts on withdrawal.
library LiquidityAmounts {
    /// @dev 2^96.
    uint256 internal constant Q96 = 0x1000000000000000000000000;

    error Overflow();

    /// @notice Liquidity obtainable from `amount0` between two sqrt prices.
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        uint256 intermediate = FixedPointMathLib.fullMulDiv(sqrtPriceAX96, sqrtPriceBX96, Q96);
        return _toUint128(FixedPointMathLib.fullMulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice Liquidity obtainable from `amount1` between two sqrt prices.
    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return _toUint128(FixedPointMathLib.fullMulDiv(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96));
    }

    /// @notice Max liquidity for which `amount0` and `amount1` are both sufficient at `sqrtPriceX96`.
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }

    function _toUint128(uint256 x) private pure returns (uint128 y) {
        if (x > type(uint128).max) revert Overflow();
        y = uint128(x);
    }
}
