// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

/// @title IFeeRebateDistributor
/// @notice Optional post-swap accounting for Urufu Gemu NFT-holder fee rebates.
interface IFeeRebateDistributor {
    /// @notice Accrue an input-token rebate for an eligible trader.
    /// @return rebate Amount credited in `tokenIn`, or zero when ineligible/capped.
    function recordSwap(address trader, PoolId poolId, address tokenIn, uint256 amountIn)
        external
        returns (uint256 rebate);
}
