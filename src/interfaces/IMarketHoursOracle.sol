// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IMarketHoursOracle
/// @notice Reports whether the equity market backing a tokenized-equity leg is currently open.
/// @dev When the market is closed, the hook disables its asymmetric fee and reverts to flat fees
///      (PROJECT_SPEC.md §6.2). Source is a Chainlink market-status feed where available, else a
///      multisig-updated flag.
interface IMarketHoursOracle {
    /// @notice True when the relevant equity market (e.g. NYSE) is currently open for trading.
    function isMarketOpen() external view returns (bool);

    /// @notice Start timestamp of the active trading session, or zero when no session is active.
    /// @dev This lets hooks derive post-open stabilization without storing a fragile observed
    ///      closed-to-open transition of their own.
    function currentSessionStart() external view returns (uint256);
}
