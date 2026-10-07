// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WoolFiHook} from "../WoolFiHook.sol";
import {SpreadMath} from "../lib/SpreadMath.sol";

/// @title WoolFiPoolAligner
/// @notice Moves an EMPTY WoolFi pool's price to its oracle fair price at zero cost, so unseeded
///         pools keep tracking Chainlink and the first liquidity provider is never blocked by
///         {WoolFiHook.OutOfBand}, and an empty pool cannot sit past the structural-break threshold.
/// @dev With zero liquidity a v4 swap moves the price to `sqrtPriceLimitX96` while consuming no input,
///      so an exact-input swap of 1 wei with the limit set to the fair sqrt price lands the pool on fair
///      and leaves every balance delta at zero. Nothing is ever owed or settled.
///
///      Fair price comes from the oracle adapters stored in the hook's pool config, read with
///      `getLastValidPrice` (no freshness requirement): nothing is at stake in an empty pool, and the
///      hook itself still applies its own oracle checks inside the swap.
///
///      Permissionless, ownerless, holds no funds. Reverts when the pool has liquidity.
///
///      Modes, as enforced by the hook during the swap:
///      - live: works; the hook needs fresh oracle prints, so a stale feed reverts the swap.
///      - market closed / stabilization: works against the last valid print (flat fee, zero input).
///      - oracle skew: works (flat fee).
///      - structural break: the hook only allows swaps toward the cached break target. When the fresh
///        fair price lies on the other side, the aligner first moves to the cached target (where either
///        direction is allowed) and then to fair, in the same unlock.
///      - paused hook, oracle runtime guard failure (feed paused, invalid round): reverts.
contract WoolFiPoolAligner is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager public immutable poolManager;

    event PoolAligned(PoolId indexed id, uint160 fromSqrtPriceX96, uint160 toSqrtPriceX96, uint256 fairPriceWad);

    error ZeroAddress();
    error NotPoolManager();
    error PoolHasLiquidity(uint128 liquidity);
    error PoolNotConfigured();
    error NonZeroDelta();

    constructor(IPoolManager poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
    }

    /// @notice Align an empty pool to its oracle fair price.
    /// @return moved False when the pool was already within 1 bps of fair (no-op).
    function align(PoolKey calldata key) external returns (bool moved) {
        PoolId id = key.toId();
        uint128 liquidity = poolManager.getLiquidity(id);
        if (liquidity != 0) revert PoolHasLiquidity(liquidity);

        WoolFiHook.WoolFiConfig memory c = WoolFiHook(address(key.hooks)).poolConfig(id);
        if (!c.configured) revert PoolNotConfigured();

        uint256 fair = SpreadMath.fairPrice(c.oracle0.getLastValidPrice(), c.oracle1.getLastValidPrice());
        (uint160 current,,,) = poolManager.getSlot0(id);
        uint160 target = toSqrtPriceX96(fair, c.decimals0, c.decimals1);
        if (
            target == current
                || SpreadMath.computeDrift(SpreadMath.poolPrice(current, c.decimals0, c.decimals1), fair) == 0
        ) {
            return false;
        }

        // During a break the hook only accepts swaps toward the cached target. If fair lies the other
        // way, hop through the cached target first (drift there is zero, so either direction passes).
        uint160 via;
        if (c.structuralBreak) {
            int256 driftVsCached =
                SpreadMath.computeDrift(SpreadMath.poolPrice(current, c.decimals0, c.decimals1), c.cachedFairPriceWad);
            bool zeroForOne = target < current;
            bool corrective =
                driftVsCached == 0 || (driftVsCached > 0 && zeroForOne) || (driftVsCached < 0 && !zeroForOne);
            if (!corrective) via = toSqrtPriceX96(c.cachedFairPriceWad, c.decimals0, c.decimals1);
        }

        poolManager.unlock(abi.encode(key, via, target));
        emit PoolAligned(id, current, target, fair);
        return true;
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, uint160 via, uint160 target) = abi.decode(raw, (PoolKey, uint160, uint160));
        if (via != 0) _moveTo(key, via);
        _moveTo(key, target);
        return "";
    }

    /// @notice Convert a WAD token1-per-token0 price into a v4 sqrtPriceX96, clamped to the swappable range.
    /// @dev Inverse of {SpreadMath.poolPrice}: sqrtPriceX96 = sqrt(fair * 10^dec1 / (1e18 * 10^dec0) * 2^192).
    function toSqrtPriceX96(uint256 fairWad, uint8 decimals0, uint8 decimals1) public pure returns (uint160) {
        uint256 num = fairWad * 10 ** uint256(decimals1);
        uint256 den = 1e18 * 10 ** uint256(decimals0);
        uint256 sqrtPrice;
        if (num / den < 1 << 63) {
            // Exact path: the Q192 price fits in 256 bits.
            sqrtPrice = FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(num, 1 << 192, den));
        } else if (num / den < 1 << 128) {
            // Large prices: take the root of the Q96 value and rescale (relative error below 1e-19).
            sqrtPrice = FixedPointMathLib.sqrt(FixedPointMathLib.fullMulDiv(num, 1 << 96, den)) << 48;
        } else {
            sqrtPrice = TickMath.MAX_SQRT_PRICE;
        }
        if (sqrtPrice <= TickMath.MIN_SQRT_PRICE) return TickMath.MIN_SQRT_PRICE + 1;
        if (sqrtPrice >= TickMath.MAX_SQRT_PRICE) return TickMath.MAX_SQRT_PRICE - 1;
        return uint160(sqrtPrice);
    }

    function _moveTo(PoolKey memory key, uint160 limit) private {
        (uint160 current,,,) = poolManager.getSlot0(key.toId());
        if (limit == current) return;
        BalanceDelta delta = poolManager.swap(
            key,
            IPoolManager.SwapParams({zeroForOne: limit < current, amountSpecified: -1, sqrtPriceLimitX96: limit}),
            ""
        );
        if (delta.amount0() != 0 || delta.amount1() != 0) revert NonZeroDelta();
    }
}
