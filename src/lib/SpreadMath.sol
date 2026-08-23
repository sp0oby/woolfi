// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title SpreadMath
/// @notice Pure math primitives for WoolFi's price-peg invariant and asymmetric fee curve.
/// @dev WoolFi pegs a full-range v4 pool's internal price to an oracle-derived fair price
///      (see PROJECT_SPEC.md §3.1, v0.2). All prices are compared in "human" token1-per-token0
///      terms scaled to 1e18 (WAD). Fees and drift are expressed in basis points (bps); the hook
///      is responsible for converting fee bps into v4's pip units (1 bps = 100 pips) at the boundary.
library SpreadMath {
    using FixedPointMathLib for uint256;

    /// @dev 1e18 fixed-point scale.
    uint256 internal constant WAD = 1e18;
    /// @dev Basis-point scale. 10_000 bps = 100%.
    uint256 internal constant BPS = 10_000;
    /// @dev Absolute ceiling on any single-swap fee, in bps (spec §5.3 invariant). 100 bps = 1%.
    uint256 internal constant MAX_FEE_CAP_BPS = 100;
    /// @dev 2^192 — the denominator when squaring a Q64.96 sqrt price into a raw price.
    uint256 internal constant Q192 = 1 << 192;

    /// @notice Thrown when a price that must be strictly positive is zero.
    error NonPositivePrice();
    /// @notice Thrown when the fair price denominator is zero (would divide by zero).
    error ZeroFairPrice();

    // ---------------------------------------------------------------------
    // Price derivation
    // ---------------------------------------------------------------------

    /// @notice Oracle-implied fair price of the pair, as whole-token1 per whole-token0, in WAD.
    /// @dev fair = price0 / price1. One whole token0 worth `price0` USD buys `price0/price1`
    ///      whole token1. Oracle prices must already be normalized to WAD and strictly positive.
    /// @param price0 USD price of token0, in WAD.
    /// @param price1 USD price of token1, in WAD.
    /// @return fairPriceWad Fair token1-per-token0 price, in WAD.
    function fairPrice(uint256 price0, uint256 price1) internal pure returns (uint256 fairPriceWad) {
        if (price0 == 0 || price1 == 0) revert NonPositivePrice();
        fairPriceWad = FixedPointMathLib.fullMulDiv(price0, WAD, price1);
    }

    /// @notice Pool's internal price derived from its Q64.96 sqrt price, as whole-token1
    ///         per whole-token0, in WAD.
    /// @dev raw = (sqrtPriceX96 / 2^96)^2 is token1-raw per token0-raw. Multiplying by
    ///      10^dec0 / 10^dec1 converts raw units to whole-token units. `fullMulDiv` is required
    ///      because sqrtPriceX96^2 overflows 256 bits.
    /// @param sqrtPriceX96 The pool's current sqrt price as a Q64.96 value.
    /// @param decimals0 ERC-20 decimals of token0.
    /// @param decimals1 ERC-20 decimals of token1.
    /// @return poolPriceWad Pool token1-per-token0 price, in WAD.
    function poolPrice(uint160 sqrtPriceX96, uint8 decimals0, uint8 decimals1)
        internal
        pure
        returns (uint256 poolPriceWad)
    {
        if (sqrtPriceX96 == 0) revert NonPositivePrice();
        // rawWad = (sqrtPriceX96^2 * WAD) / 2^192, computed with 512-bit intermediate precision.
        uint256 rawWad = FixedPointMathLib.fullMulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96) * WAD, Q192);
        // Convert raw (per-smallest-unit) price into whole-token units.
        poolPriceWad = FixedPointMathLib.fullMulDiv(rawWad, 10 ** uint256(decimals0), 10 ** uint256(decimals1));
    }

    // ---------------------------------------------------------------------
    // Drift
    // ---------------------------------------------------------------------

    /// @notice Signed relative deviation of the pool price from fair, in bps.
    /// @dev drift = (pool - fair) / fair. Positive means the pool price is above fair
    ///      (token0 over-priced in the pool relative to oracles). The positive branch is
    ///      clamped to int256 max so the function never overflows on pathological inputs;
    ///      the negative branch is naturally bounded to [-BPS, 0] since pool >= 0.
    /// @param poolPriceWad Pool price in WAD (see {poolPrice}).
    /// @param fairPriceWad Fair price in WAD (see {fairPrice}).
    /// @return driftBps Signed drift in basis points.
    function computeDrift(uint256 poolPriceWad, uint256 fairPriceWad) internal pure returns (int256 driftBps) {
        if (fairPriceWad == 0) revert ZeroFairPrice();
        if (poolPriceWad >= fairPriceWad) {
            uint256 mag = FixedPointMathLib.fullMulDiv(poolPriceWad - fairPriceWad, BPS, fairPriceWad);
            uint256 capped = mag > uint256(type(int256).max) ? uint256(type(int256).max) : mag;
            // forge-lint: disable-next-line(unsafe-typecast) — `capped` is clamped to int256 max above.
            driftBps = int256(capped);
        } else {
            uint256 mag = FixedPointMathLib.fullMulDiv(fairPriceWad - poolPriceWad, BPS, fairPriceWad);
            // forge-lint: disable-next-line(unsafe-typecast) — pool < fair implies mag < BPS (10_000).
            driftBps = -int256(mag);
        }
    }

    // ---------------------------------------------------------------------
    // Fee curve
    // ---------------------------------------------------------------------

    /// @notice Asymmetric fee for a swap given the pool's current drift.
    /// @dev Corrective swaps (toward fair) get a discount, adversarial swaps (away from fair)
    ///      get a premium, both scaling with |drift|:
    ///        adversarial = baseFee * (1 + k*|d|)
    ///        corrective  = baseFee * max(0, 1 - k*|d|)
    ///      where k is supplied pre-scaled as `kScaled = k * BPS` (k=4.0 -> 40_000) to keep the
    ///      arithmetic integer. The result is clamped to {MAX_FEE_CAP_BPS}.
    /// @param baseFeeBps Base fee in bps (e.g. 30).
    /// @param driftBps Signed drift in bps (see {computeDrift}).
    /// @param kScaled Steepness k scaled by BPS (k=4.0 -> 40_000).
    /// @param isCorrective True if the swap moves the pool toward fair.
    /// @return feeBps Fee in bps, never exceeding {MAX_FEE_CAP_BPS}.
    function asymmetricFee(uint256 baseFeeBps, int256 driftBps, uint256 kScaled, bool isCorrective)
        internal
        pure
        returns (uint256 feeBps)
    {
        uint256 absDrift = _abs(driftBps);
        uint256 adj = FixedPointMathLib.fullMulDiv(kScaled, absDrift, BPS); // = k*|d| scaled by BPS

        uint256 multiplier;
        if (isCorrective) {
            multiplier = BPS > adj ? BPS - adj : 0;
        } else {
            multiplier = BPS + adj;
        }

        feeBps = FixedPointMathLib.fullMulDiv(baseFeeBps, multiplier, BPS);
        if (feeBps > MAX_FEE_CAP_BPS) feeBps = MAX_FEE_CAP_BPS;
    }

    // ---------------------------------------------------------------------
    // Band / break predicates
    // ---------------------------------------------------------------------

    /// @notice True when |drift| is within the in-band tolerance (inclusive).
    /// @param driftBps Signed drift in bps.
    /// @param toleranceBps Drift tolerance in bps (default 500 = 5%).
    function isInBand(int256 driftBps, uint256 toleranceBps) internal pure returns (bool) {
        return _abs(driftBps) <= toleranceBps;
    }

    /// @notice True when |drift| has reached the hard structural-break threshold (inclusive).
    /// @dev Inclusive (`>=`) so that exactly hitting the threshold triggers protection rather
    ///      than slipping through. Tolerance < |drift| < threshold is the asymmetric-fee region.
    /// @param driftBps Signed drift in bps.
    /// @param hardThresholdBps Structural-break threshold in bps (default 1500 = 15%).
    function isStructuralBreak(int256 driftBps, uint256 hardThresholdBps) internal pure returns (bool) {
        return _abs(driftBps) >= hardThresholdBps;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    /// @dev Absolute value of a signed int as a uint, safe against the int256.min edge.
    function _abs(int256 x) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast) — magnitude of any int256 fits in uint256.
        return x >= 0 ? uint256(x) : uint256(-(x + 1)) + 1;
    }
}
