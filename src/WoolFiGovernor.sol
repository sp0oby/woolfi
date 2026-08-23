// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {WoolFiHook} from "./WoolFiHook.sol";

/// @title WoolFiGovernor
/// @notice v1 governance surface for WoolFi: a single owner-controlled entry point that holds the
///         `governor` role on {WoolFiHook}. The owner is a multisig in v1 (PROJECT_SPEC.md §6, §7.4);
///         full on-chain STRAND voting is deferred to v2.
/// @dev Deliberately minimal — a thin, audited forwarding layer rather than premature voting/timelock
///      machinery. Its value is a durable, immutable-to-the-hook governance endpoint whose *control*
///      can transition (multisig -> on-chain governor) two ways without redeploying the hook:
///        1. transfer ownership of this contract to the new controller (`transferOwnership`), or
///        2. repoint the hook's governor role entirely (`setHookGovernor`).
contract WoolFiGovernor is Ownable {
    /// @notice The hook this governor controls.
    WoolFiHook public immutable hook;

    /// @param hook_ The WoolFiHook whose `governor` role this contract holds.
    /// @param multisig The initial owner (v1 multisig).
    constructor(address hook_, address multisig) Ownable(multisig) {
        hook = WoolFiHook(hook_);
    }

    /// @notice Authorize a new WoolFi pool (before it is initialized in the PoolManager).
    function authorizePool(PoolKey calldata key, WoolFiHook.AuthParams calldata params) external onlyOwner {
        hook.authorizePool(key, params);
    }

    function authorizePoolV2(PoolKey calldata key, WoolFiHook.AuthParamsV2 calldata params) external onlyOwner {
        hook.authorizePoolV2(key, params);
    }

    /// @notice Update an authorized pool's tunable parameters.
    function updatePoolConfig(PoolKey calldata key, WoolFiHook.AuthParams calldata params) external onlyOwner {
        hook.updatePoolConfig(key, params);
    }

    function updatePoolConfigV2(PoolKey calldata key, WoolFiHook.AuthParamsV2 calldata params) external onlyOwner {
        hook.updatePoolConfigV2(key, params);
    }

    function setPoolSafety(PoolKey calldata key, WoolFiHook.SafetyParams calldata params) external onlyOwner {
        hook.setPoolSafety(key, params);
    }

    /// @notice Clear a pool's structural-break state.
    function resolveStructuralBreak(PoolKey calldata key) external onlyOwner {
        hook.resolveStructuralBreak(key);
    }

    /// @notice Wire (or update) a pool's underwriting vault and its drawdown fraction.
    function setVault(PoolKey calldata key, address vault, uint16 drawdownBps) external onlyOwner {
        hook.setVault(key, vault, drawdownBps);
    }

    /// @notice Engage the hook's global emergency pause.
    function pauseHook() external onlyOwner {
        hook.setPaused(true);
    }

    /// @notice Release the hook's global emergency pause.
    function unpauseHook() external onlyOwner {
        hook.setPaused(false);
    }

    /// @notice Hand the hook's `governor` role to a new controller (e.g. on-chain governance in v2).
    /// @dev After this, only `newGovernor` can manage the hook; this contract loses the role.
    function setHookGovernor(address newGovernor) external onlyOwner {
        hook.setGovernor(newGovernor);
    }

    /// @notice Repoint the hook's position manager (e.g. during a PM upgrade). Passing
    ///         `address(0)` disables auto-realization in afterSwap without removing pools.
    function setHookPositionManager(address newPm) external onlyOwner {
        hook.setPositionManager(newPm);
    }
}
