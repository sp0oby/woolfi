// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracle, IPriceOracleMetadata} from "../interfaces/IPriceOracle.sol";

/// @title DualOracleAdapter
/// @notice Wraps two {IPriceOracle}s (primary + backup) and enforces an inter-source deviation cap.
/// @dev Designed for an equity leg per PROJECT_SPEC.md: e.g. a verified Chainlink stock feed as primary
///      with a Pyth feed (behind an `IPriceOracle` adapter) as backup. Returns the primary price
///      while both are fresh and within `maxDeviationBps`. Silently fails over to whichever source
///      is fresh when the other reverts on staleness; reverts when both are stale or the two
///      sources disagree beyond the threshold.
///
///      Failover is silent (no event) because {IPriceOracle.getPrice} is `view`. Off-chain monitoring
///      observes failover by reading the two sources directly; the revert cases (both stale, deviation)
///      surface on-chain.
contract DualOracleAdapter is IPriceOracleMetadata {
    /// @notice The preferred price source.
    IPriceOracle public immutable primary;
    /// @notice The backup price source used for the deviation check and as a fallback.
    IPriceOracle public immutable backup;
    /// @notice Max permitted inter-source deviation, in basis points. e.g. 200 = 2%.
    uint16 public immutable maxDeviationBps;

    uint256 private constant BPS = 10_000;

    error InvalidConfig();
    /// @notice Both sources are stale or otherwise unhealthy.
    error BothStale();
    /// @notice The two sources disagree by more than `maxDeviationBps`.
    error PriceDeviation(uint256 primaryPrice, uint256 backupPrice);

    constructor(IPriceOracle _primary, IPriceOracle _backup, uint16 _maxDeviationBps) {
        if (address(_primary) == address(0) || address(_backup) == address(0)) revert InvalidConfig();
        if (_maxDeviationBps == 0 || _maxDeviationBps > BPS) revert InvalidConfig();
        primary = _primary;
        backup = _backup;
        maxDeviationBps = _maxDeviationBps;
    }

    /// @inheritdoc IPriceOracle
    function getPrice() external view returns (uint256 priceWad) {
        uint256 p;
        uint256 b;
        bool pOk;
        bool bOk;
        try primary.getPrice() returns (uint256 _p) {
            p = _p;
            pOk = true;
        } catch {}
        try backup.getPrice() returns (uint256 _b) {
            b = _b;
            bOk = true;
        } catch {}

        if (!pOk && !bOk) revert BothStale();
        if (!pOk) return b; // primary unhealthy -> failover to backup
        if (!bOk) return p; // backup unhealthy -> use primary alone (no deviation check possible)

        uint256 hi = p > b ? p : b;
        uint256 lo = p > b ? b : p;
        // |hi - lo| / lo > maxDeviationBps / BPS  iff  (hi - lo) * BPS > lo * maxDeviationBps
        if ((hi - lo) * BPS > lo * maxDeviationBps) revert PriceDeviation(p, b);
        return p;
    }

    /// @notice Runtime guards for both wrapped sources.
    function requireRuntimeGuards() external view {
        primary.requireRuntimeGuards();
        backup.requireRuntimeGuards();
    }

    /// @inheritdoc IPriceOracleMetadata
    /// @dev Timestamp-aware consumers require both sources to validate. Errors are deliberately
    ///      allowed to bubble here: a stale/invalid/corporate-action/sequencer failure must not be
    ///      converted into the hook's benign timestamp-skew degradation mode.
    function getPriceData() external view returns (uint256 priceWad, uint256 updatedAt) {
        (uint256 p, uint256 pUpdatedAt) = IPriceOracleMetadata(address(primary)).getPriceData();
        (uint256 b,) = IPriceOracleMetadata(address(backup)).getPriceData();
        uint256 hi = p > b ? p : b;
        uint256 lo = p > b ? b : p;
        if ((hi - lo) * BPS > lo * maxDeviationBps) revert PriceDeviation(p, b);
        return (p, pUpdatedAt);
    }
}
