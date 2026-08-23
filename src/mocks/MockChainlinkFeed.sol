// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/// @title MockChainlinkFeed
/// @notice Test-only Chainlink aggregator with a settable answer and update timestamp.
/// @dev Not for production. Lets tests drive price, staleness, and round behavior deterministically.
contract MockChainlinkFeed is AggregatorV3Interface {
    uint8 private immutable _decimals;
    int256 public answer;
    uint256 public startedAt;
    uint256 public updatedAt;
    uint80 public roundId;
    uint80 public answeredInRound;

    constructor(uint8 dec, int256 _answer, uint256 _updatedAt) {
        _decimals = dec;
        answer = _answer;
        startedAt = _updatedAt;
        updatedAt = _updatedAt;
        roundId = 1;
        answeredInRound = 1;
    }

    /// @notice Set a new answer and its update timestamp, advancing the round.
    function setAnswer(int256 _answer, uint256 _updatedAt) external {
        answer = _answer;
        startedAt = _updatedAt;
        updatedAt = _updatedAt;
        roundId++;
        answeredInRound = roundId;
    }

    function setRoundData(int256 _answer, uint256 _startedAt, uint256 _updatedAt) external {
        answer = _answer;
        startedAt = _startedAt;
        updatedAt = _updatedAt;
        roundId++;
        answeredInRound = roundId;
    }

    function setRoundIds(uint80 roundId_, uint80 answeredInRound_) external {
        roundId = roundId_;
        answeredInRound = answeredInRound_;
    }

    function decimals() external view override returns (uint8) {
        return _decimals;
    }

    function description() external pure override returns (string memory) {
        return "MockChainlinkFeed";
    }

    function version() external pure override returns (uint256) {
        return 1;
    }

    function getRoundData(uint80 _roundId) external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (_roundId, answer, startedAt, updatedAt, _roundId);
    }

    function latestRoundData() external view override returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
