// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {WoolFiHook} from "./WoolFiHook.sol";
import {WoolFiPositionManager} from "./WoolFiPositionManager.sol";

/// @title RebalanceKeeper
/// @notice Permissionless entry point that keeps a WoolFi pool's protocol state fresh
///         (PROJECT_SPEC.md §5.1, §8.1).
/// @dev A thin convenience wrapper; anyone may call {keep} to:
///        1. Force a structural-break check on the hook (so a drift past the hard threshold enters
///           containment even when no swap has occurred since the oracle moved).
///        2. Confirm a pending break once its confirmation window has elapsed, which either fires
///           the vault drawdown or clears the break if the pool has recovered.
///        3. Poke the position manager's fee realization, routing the protocol cuts (vault rewards
///           and treasury policy sink) and refreshing the per-share fee accumulator.
///      Holds no funds and has no privileges — both calls are themselves permissionless and gated by
///      the hook / PM as appropriate.
contract RebalanceKeeper {
    /// @notice The hook this keeper services.
    WoolFiHook public immutable hook;
    /// @notice The position manager this keeper services.
    WoolFiPositionManager public immutable pm;

    error ZeroAddress();

    constructor(WoolFiHook _hook, WoolFiPositionManager _pm) {
        if (address(_hook) == address(0) || address(_pm) == address(0)) revert ZeroAddress();
        hook = _hook;
        pm = _pm;
    }

    /// @notice Refresh a pool's protocol state: detect any structural break, confirm a pending one
    ///         whose window has elapsed, and realize pool fees.
    /// @dev Reverts only if an oracle is stale during detection. A confirmation that cannot run yet
    ///      (market closed, oracle skew, pause) is skipped rather than reverting the whole call;
    ///      {BreakConfirmAttempted} records the outcome for monitoring.
    function keep(PoolKey calldata key) external {
        hook.checkStructuralBreak(key);
        (bool broken, bool confirmed,, uint256 readyAt) = hook.breakStatus(key);
        if (broken && !confirmed && block.timestamp >= readyAt) {
            try hook.confirmStructuralBreak(key) {
                emit BreakConfirmAttempted(true, "");
            } catch (bytes memory reason) {
                emit BreakConfirmAttempted(false, reason);
            }
        }
        pm.collectFees(key, address(this));
    }

    event BreakConfirmAttempted(bool succeeded, bytes reason);
}
