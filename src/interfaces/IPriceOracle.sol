// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IPriceOracle
/// @notice Minimal price source for one asset leg of a WoolFi pool.
/// @dev Implementations MUST return a price normalized to 1e18 (WAD) and MUST revert
///      (rather than return a stale or invalid value) when the underlying feed is unhealthy.
///      Returning a bad price silently is a critical failure mode for the hook.
interface IPriceOracle {
    /// @notice Latest USD price of the asset, normalized to 1e18.
    /// @dev Reverts if the price is non-positive or stale beyond the implementation's threshold.
    /// @return priceWad The price in 1e18 fixed-point.
    function getPrice() external view returns (uint256 priceWad);

    /// @notice Runtime safety checks that remain in force when a price observation is allowed to
    ///         be stale (for example, equity-hours pools while the referenced market is closed).
    /// @dev Implementations MUST revert on sequencer, pause, or other operational failures, and
    ///      MUST NOT revert solely because the last print is older than the heartbeat.
    function requireRuntimeGuards() external view;
}

/// @title IPriceOracleMetadata
/// @notice Optional extension used when a pool enables dual-leg timestamp synchronization.
/// @dev Implementations must apply the same validity/freshness checks as `getPrice`; unsafe feed
///      failures must revert instead of returning metadata for an unusable observation.
interface IPriceOracleMetadata is IPriceOracle {
    /// @return priceWad Validated price in 1e18 fixed-point.
    /// @return updatedAt Timestamp of the underlying observation used for `priceWad`.
    function getPriceData() external view returns (uint256 priceWad, uint256 updatedAt);
}
