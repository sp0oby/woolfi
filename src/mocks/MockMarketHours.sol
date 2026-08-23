// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IMarketHoursOracle} from "../interfaces/IMarketHoursOracle.sol";

/// @title MockMarketHours
/// @notice Test-only {IMarketHoursOracle} with a settable open/closed flag.
contract MockMarketHours is IMarketHoursOracle {
    bool public open;
    uint256 public sessionStart;

    constructor(bool _open) {
        open = _open;
        if (_open) sessionStart = block.timestamp;
    }

    function setOpen(bool _open) external {
        if (_open && !open) sessionStart = block.timestamp;
        open = _open;
        if (!_open) sessionStart = 0;
    }

    function setSessionStart(uint256 start) external {
        sessionStart = start;
    }

    /// @inheritdoc IMarketHoursOracle
    function isMarketOpen() external view returns (bool) {
        return open;
    }

    /// @inheritdoc IMarketHoursOracle
    function currentSessionStart() external view returns (uint256) {
        return open ? sessionStart : 0;
    }
}
