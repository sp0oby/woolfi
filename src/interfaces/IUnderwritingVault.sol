// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IUnderwritingVault
/// @notice Interface to a per-pool underwriting vault, used by the hook (drawdown) and the position
///         manager (fee-reward routing).
/// @dev On a structural break the hook calls {drawdown} to seize a fraction of the configured staking token,
///      socializing the loss across stakers pro-rata (PROJECT_SPEC.md §3.5). The position manager
///      routes a configured share of pool fees to stakers via {depositRewards} (§7.3).
interface IUnderwritingVault {
    /// @notice Seize `bps` (basis points) of the vault's staked assets to fund a rebalance.
    /// @dev Callable only by the bound hook. Never pays out more than the vault holds.
    /// @param bps Fraction of staked assets to seize, in basis points (<= 10_000).
    /// @return seized The amount of staking tokens seized.
    function drawdown(uint256 bps) external returns (uint256 seized);

    /// @notice Total staking shares outstanding (0 when the vault has no stakers).
    function totalShares() external view returns (uint256);

    /// @notice Fund staker rewards with `amount0`/`amount1` of the pool's tokens (pulled from caller).
    function depositRewards(uint256 amount0, uint256 amount1) external;
}
