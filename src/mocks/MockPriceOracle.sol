// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracleMetadata} from "../interfaces/IPriceOracle.sol";

/// @title MockPriceOracle
/// @notice Test-only {IPriceOracle} with a settable WAD price and a toggleable stale flag.
/// @dev Lets hook tests exercise drift, staleness-revert, and structural-break paths deterministically.
contract MockPriceOracle is IPriceOracleMetadata {
    uint256 public priceWad;
    uint256 public updatedAt;
    bool public stale;
    bool public runtimeUnsafe;

    /// @notice Thrown when the mock is configured to simulate a stale feed.
    error MockStale();
    /// @notice Thrown when the mock is configured to simulate a sequencer/pause failure.
    error MockRuntimeUnsafe();

    constructor(uint256 _priceWad) {
        priceWad = _priceWad;
        updatedAt = block.timestamp;
    }

    function setPrice(uint256 _priceWad) external {
        priceWad = _priceWad;
        updatedAt = block.timestamp;
    }

    function setPriceData(uint256 _priceWad, uint256 _updatedAt) external {
        priceWad = _priceWad;
        updatedAt = _updatedAt;
    }

    function setStale(bool _stale) external {
        stale = _stale;
    }

    function setRuntimeUnsafe(bool _runtimeUnsafe) external {
        runtimeUnsafe = _runtimeUnsafe;
    }

    function requireRuntimeGuards() external view {
        if (runtimeUnsafe) revert MockRuntimeUnsafe();
    }

    /// @notice Return the configured validated price.
    function getPrice() external view returns (uint256) {
        if (stale) revert MockStale();
        return priceWad;
    }

    /// @inheritdoc IPriceOracleMetadata
    function getPriceData() external view returns (uint256, uint256) {
        if (stale) revert MockStale();
        return (priceWad, updatedAt);
    }
}
