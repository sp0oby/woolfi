// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

import {WoolFiHook} from "./WoolFiHook.sol";

/// @title WoolFiGovernor
/// @notice v1 governance surface for WoolFi: a single owner-controlled entry point that holds the
///         `governor` role on {WoolFiHook}. Token voting is outside the v1 production scope.
/// @dev Production control layout (PROJECT_SPEC.md section 7.4, KNOWN-ISSUES M-3):
///        - owner: an OpenZeppelin TimelockController (minimum delay 24h) whose only proposer and
///          executor is the Safe multisig and which has no admin. Every owner call below
///          (pool authorization, oracle rebinding, vault wiring, break resolution, unpause,
///          governor migration) is therefore public for at least the timelock delay before it can
///          execute.
///        - guardian: the Safe itself, which may only engage the emergency pause (`pauseHook`)
///          with no delay. Releasing the pause is an owner call and waits for the timelock.
///      Control can still transition without redeploying the hook, two ways, both two-step so a
///      mistyped address cannot strand control:
///        1. transfer ownership of this contract (`transferOwnership`, then `acceptOwnership`), or
///        2. repoint the hook's governor role (`proposeHookGovernor`, then the new governor
///           accepts on the hook).
contract WoolFiGovernor is Ownable2Step {
    /// @notice The hook this governor controls.
    WoolFiHook public immutable hook;

    /// @notice Address allowed to engage the emergency pause without the owner's delay. Zero disables it.
    address public guardian;

    event GuardianSet(address indexed previousGuardian, address indexed newGuardian);

    error NotOwnerOrGuardian();

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

    /// @notice Set a pool's break-confirmation window (zero selects the hook default).
    function setBreakConfirmSeconds(PoolKey calldata key, uint32 confirmSeconds) external onlyOwner {
        hook.setBreakConfirmSeconds(key, confirmSeconds);
    }

    /// @notice Wire (or update) a pool's underwriting vault and its drawdown fraction.
    function setVault(PoolKey calldata key, address vault, uint16 drawdownBps) external onlyOwner {
        hook.setVault(key, vault, drawdownBps);
    }

    /// @notice Set (or clear, with `address(0)`) the emergency-pause guardian.
    function setGuardian(address newGuardian) external onlyOwner {
        emit GuardianSet(guardian, newGuardian);
        guardian = newGuardian;
    }

    /// @notice Engage the hook's global emergency pause. Callable by the owner or the guardian.
    function pauseHook() external {
        // msg.sender is never address(0), so a cleared guardian matches nobody.
        if (msg.sender != owner() && msg.sender != guardian) {
            revert NotOwnerOrGuardian();
        }
        hook.setPaused(true);
    }

    /// @notice Release the hook's global emergency pause. Owner only, so it waits for the timelock.
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
