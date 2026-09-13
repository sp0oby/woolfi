// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceOracleMetadata} from "../interfaces/IPriceOracle.sol";

interface IRobinhoodStockToken {
    function oraclePaused() external view returns (bool);
}

interface IChainlinkAggregator {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title RobinhoodStockOracleAdapter
/// @notice WAD-normalized stock-token price guarded by corporate-action pause and, when
///         available on the deployment chain, an L2 sequencer uptime feed.
/// @dev Robinhood Chain (4663) publishes no L2 sequencer uptime feed and Chainlink has stated it
///      is not expanding that product to new networks. Deploying with `sequencerUptimeFeed_ ==
///      address(0)` and `gracePeriod_ == 0` explicitly opts out of the sequencer guard; the
///      `oraclePaused()` and price-freshness checks remain. Any half-configured pair reverts.
contract RobinhoodStockOracleAdapter is IPriceOracleMetadata {
    uint8 private constant WAD_DECIMALS = 18;
    uint256 private constant STALENESS_FACTOR = 2;

    IRobinhoodStockToken public immutable stockToken;
    IChainlinkAggregator public immutable feed;
    IChainlinkAggregator public immutable sequencerUptimeFeed;
    uint256 public immutable heartbeat;
    uint256 public immutable gracePeriod;
    uint8 public immutable feedDecimals;
    bool public immutable sequencerEnabled;

    error ZeroAddress();
    error NotContract(address target);
    error InvalidHeartbeat();
    error ZeroGracePeriod();
    error IncompleteSequencerConfig(address feed, uint256 gracePeriod);
    error UnsupportedDecimals(uint8 decimals);
    error OraclePaused();
    error SequencerDown(int256 answer);
    error InvalidTimestamp(address source, uint256 timestamp);
    error GracePeriodActive(uint256 startedAt, uint256 gracePeriod);
    error InvalidPrice(int256 answer);
    error IncompleteRound(uint80 roundId, uint80 answeredInRound);
    error StalePrice(uint256 updatedAt, uint256 maxStaleness);

    constructor(
        address stockToken_,
        address feed_,
        address sequencerUptimeFeed_,
        uint256 heartbeat_,
        uint256 gracePeriod_
    ) {
        if (stockToken_ == address(0) || feed_ == address(0)) revert ZeroAddress();
        _requireContract(stockToken_);
        _requireContract(feed_);
        if (heartbeat_ == 0 || heartbeat_ > type(uint256).max / STALENESS_FACTOR) revert InvalidHeartbeat();

        bool sequencerEnabled_ = sequencerUptimeFeed_ != address(0);
        if (sequencerEnabled_) {
            _requireContract(sequencerUptimeFeed_);
            if (gracePeriod_ == 0) revert ZeroGracePeriod();
        } else if (gracePeriod_ != 0) {
            revert IncompleteSequencerConfig(sequencerUptimeFeed_, gracePeriod_);
        }

        uint8 decimals_ = IChainlinkAggregator(feed_).decimals();
        if (decimals_ > WAD_DECIMALS) revert UnsupportedDecimals(decimals_);

        stockToken = IRobinhoodStockToken(stockToken_);
        feed = IChainlinkAggregator(feed_);
        sequencerUptimeFeed = IChainlinkAggregator(sequencerUptimeFeed_);
        heartbeat = heartbeat_;
        gracePeriod = gracePeriod_;
        feedDecimals = decimals_;
        sequencerEnabled = sequencerEnabled_;
    }

    /// @notice Return the latest validated WAD price.
    function getPrice() external view returns (uint256 priceWad) {
        (priceWad,) = _priceData();
    }

    /// @inheritdoc IPriceOracleMetadata
    function getPriceData() external view returns (uint256 priceWad, uint256 updatedAt) {
        return _priceData();
    }

    /// @notice Sequencer, grace-period, and stock-oracle pause checks only.
    function requireRuntimeGuards() external view {
        _requireRuntimeGuards();
    }

    function _requireRuntimeGuards() private view {
        if (sequencerEnabled) {
            (, int256 sequencerAnswer, uint256 sequencerStartedAt, uint256 sequencerUpdatedAt,) =
                sequencerUptimeFeed.latestRoundData();
            if (sequencerAnswer != 0) revert SequencerDown(sequencerAnswer);
            _validateTimestamp(address(sequencerUptimeFeed), sequencerUpdatedAt);
            _validateTimestamp(address(sequencerUptimeFeed), sequencerStartedAt);
            if (block.timestamp - sequencerStartedAt <= gracePeriod) {
                revert GracePeriodActive(sequencerStartedAt, gracePeriod);
            }
        }
        if (stockToken.oraclePaused()) revert OraclePaused();
    }

    function _priceData() private view returns (uint256 priceWad, uint256 updatedAt) {
        _requireRuntimeGuards();

        uint80 roundId;
        int256 answer;
        uint80 answeredInRound;
        (roundId, answer,, updatedAt, answeredInRound) = feed.latestRoundData();
        if (answer <= 0) revert InvalidPrice(answer);
        if (roundId == 0 || answeredInRound < roundId) revert IncompleteRound(roundId, answeredInRound);
        _validateTimestamp(address(feed), updatedAt);

        uint256 maxStaleness = heartbeat * STALENESS_FACTOR;
        if (block.timestamp - updatedAt > maxStaleness) revert StalePrice(updatedAt, maxStaleness);
        priceWad = uint256(answer) * (10 ** (WAD_DECIMALS - feedDecimals));
    }

    function _validateTimestamp(address source, uint256 timestamp) private view {
        if (timestamp == 0 || timestamp > block.timestamp) revert InvalidTimestamp(source, timestamp);
    }

    function _requireContract(address target) private view {
        if (target.code.length == 0) revert NotContract(target);
    }
}
