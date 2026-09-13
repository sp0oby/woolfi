// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {IPriceOracleMetadata} from "../interfaces/IPriceOracle.sol";

/// @title ChainlinkOracleAdapter
/// @notice Wraps a single Chainlink price feed as an {IPriceOracle}, enforcing staleness and
///         validity checks and normalizing the answer to 1e18 (PROJECT_SPEC.md §6.1).
/// @dev One adapter instance per feed. Feed address, heartbeat, and decimals are immutable —
///      changing a feed means deploying a new adapter and re-pointing the hook via governance.
contract ChainlinkOracleAdapter is IPriceOracleMetadata {
    /// @notice The wrapped Chainlink aggregator.
    AggregatorV3Interface public immutable feed;
    /// @notice Expected max seconds between feed updates, per the feed's published heartbeat.
    uint256 public immutable heartbeat;
    /// @notice The feed's native decimals, cached at deploy.
    uint8 public immutable feedDecimals;

    /// @dev WAD scale (1e18) — the normalized output precision.
    uint256 private constant WAD_DECIMALS = 18;
    /// @dev Spec §6.1: a price is stale once its age exceeds 2x the heartbeat.
    uint256 private constant STALENESS_FACTOR = 2;

    /// @notice Thrown when the feed address is zero.
    error ZeroAddress();
    /// @notice Thrown when the configured heartbeat is zero.
    error ZeroHeartbeat();
    /// @notice Thrown when the feed reports more than 18 decimals (cannot up-scale to WAD).
    error UnsupportedDecimals(uint8 decimals);
    /// @notice Thrown when the feed returns a non-positive price.
    error InvalidPrice(int256 answer);
    /// @notice Thrown when the latest answer is older than the staleness threshold.
    error StalePrice(uint256 updatedAt, uint256 maxStaleness);
    /// @notice Thrown when the latest round is incomplete or unanswered.
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);

    /// @param _feed Address of the Chainlink aggregator.
    /// @param _heartbeat Published heartbeat of the feed, in seconds.
    constructor(address _feed, uint256 _heartbeat) {
        if (_feed == address(0)) revert ZeroAddress();
        if (_heartbeat == 0) revert ZeroHeartbeat();
        uint8 dec = AggregatorV3Interface(_feed).decimals();
        if (dec > WAD_DECIMALS) revert UnsupportedDecimals(dec);
        feed = AggregatorV3Interface(_feed);
        heartbeat = _heartbeat;
        feedDecimals = dec;
    }

    /// @notice Return the latest validated WAD price.
    function getPrice() external view returns (uint256 priceWad) {
        (priceWad,) = _priceData();
    }

    /// @inheritdoc IPriceOracleMetadata
    function getPriceData() external view returns (uint256 priceWad, uint256 updatedAt) {
        return _priceData();
    }

    /// @notice Rejects a non-positive or timestamp-invalid print without applying heartbeat age.
    function requireRuntimeGuards() external view {
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (roundId == 0 || answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);
        if (updatedAt == 0 || updatedAt > block.timestamp) revert StalePrice(updatedAt, heartbeat * STALENESS_FACTOR);
    }

    function _priceData() private view returns (uint256 priceWad, uint256 updatedAt) {
        uint80 roundId;
        int256 answer;
        uint80 answeredInRound;
        (roundId, answer,, updatedAt, answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (roundId == 0 || answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);

        uint256 maxStaleness = heartbeat * STALENESS_FACTOR;
        uint256 age = block.timestamp > updatedAt ? block.timestamp - updatedAt : 0;
        if (age > maxStaleness) revert StalePrice(updatedAt, maxStaleness);

        priceWad = uint256(answer) * (10 ** (WAD_DECIMALS - feedDecimals));
    }
}
