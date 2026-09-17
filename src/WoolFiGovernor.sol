// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {WoolFiHook} from "./WoolFiHook.sol";

/// @title WoolFiGovernor
/// @notice v1 governance surface for WoolFi: a single owner-controlled entry point that holds the
///         `governor` role on {WoolFiHook}. The owner is a multisig in v1 (PROJECT_SPEC.md §6, §7.4);
///         token voting is outside the v1 production scope.
/// @dev Deliberately minimal — a thin, audited forwarding layer rather than premature voting/timelock
///      machinery. Its value is a durable, immutable-to-the-hook governance endpoint whose *control*
///      can transition (multisig -> on-chain governor) two ways without redeploying the hook:
///        1. transfer ownership of this contract to the new controller (`transferOwnership`, then
///           the new owner calls `acceptOwnership`), or
///        2. repoint the hook's governor role entirely (`proposeHookGovernor`, then the new governor
///           accepts on the hook).
///      Both handoffs are two-step so a mistyped address cannot strand control.
contract WoolFiGovernor is Ownable2Step {
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

    /// @notice Propose a new holder of the hook's `governor` role (e.g. on-chain governance in v2).
    /// @dev Takes effect only after `newGovernor` calls `WoolFiHook.acceptGovernor()`. Until then
    ///      this contract keeps the role.
    function proposeHookGovernor(address newGovernor) external onlyOwner {
        hook.proposeGovernor(newGovernor);
    }

    /// @notice Accept a pending hook-governor proposal addressed to this contract.
    /// @dev Used during deployment (hook is constructed with the deployer as governor, then proposes
    ///      this contract) and in any future migration back to a WoolFiGovernor instance.
    function acceptHookGovernor() external onlyOwner {
        hook.acceptGovernor();
    }

    /// @notice Repoint the hook's position manager (e.g. during a PM upgrade). Passing
    ///         `address(0)` disables auto-realization in afterSwap without removing pools.
    function setHookPositionManager(address newPm) external onlyOwner {
        hook.setPositionManager(newPm);
    }
}
