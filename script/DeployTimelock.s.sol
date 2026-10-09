// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {UNSTAKE_COOLDOWN} from "../src/WoolFiUnderwritingVault.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys the OpenZeppelin TimelockController that owns WoolFi's privileged contracts
///         (KNOWN-ISSUES M-3). The Safe is the only proposer and executor (and, by OZ default, the
///         only canceller); there is no admin, so roles can change only through the timelock itself.
/// @dev Env: DEPLOYER_PRIVATE_KEY, MULTISIG, optional TIMELOCK_DELAY (seconds, default 259200 = 3 days).
///      On Robinhood Chain the delay must be at least 3 days and longer than the vault unstake
///      cooldown (so stakers can always exit before a queued change executes), MULTISIG must be a contract (the Safe) and
///      must differ from the deployer, and a broadcast also needs CONFIRM_MAINNET=true. A broadcast
///      records the address as `timelock` in the deployment manifest. Ownership moves to the
///      timelock afterwards through the Safe batches written by script/TimelockHandoff.s.sol.
contract DeployTimelock is RobinhoodBroadcastGuard {
    string internal constant MANIFEST = "frontend/lib/deployments/robinhood.json";
    uint256 internal constant MIN_PRODUCTION_DELAY = 3 days;

    function run() external returns (TimelockController timelock) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address multisig = vm.envAddress("MULTISIG");
        uint256 delay = vm.envOr("TIMELOCK_DELAY", MIN_PRODUCTION_DELAY);
        timelock = deployTimelock(vm.addr(pk), multisig, delay, pk);

        if (_isBroadcastContext()) {
            vm.writeJson(string.concat('"', vm.toString(address(timelock)), '"'), MANIFEST, ".timelock");
            console2.log("Patched JSON at", MANIFEST);
        }
        console2.log("TimelockController", address(timelock));
        console2.log("  minDelay          ", delay);
        console2.log("  proposer/executor ", multisig);
    }

    /// @dev Split out so tests can exercise the checks and constructor arguments directly.
    function deployTimelock(address deployer, address multisig, uint256 delay, uint256 pk)
        public
        returns (TimelockController timelock)
    {
        require(multisig != address(0), "DeployTimelock: MULTISIG is zero");
        require(multisig != deployer, "DeployTimelock: MULTISIG must not be the deployer");
        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            require(multisig.code.length > 0, "DeployTimelock: MULTISIG has no code");
            require(delay >= MIN_PRODUCTION_DELAY, "DeployTimelock: delay below 3 days");
            require(delay > UNSTAKE_COOLDOWN, "DeployTimelock: delay not above unstake cooldown");
        }

        address[] memory roles = new address[](1);
        roles[0] = multisig;

        if (pk != 0) vm.startBroadcast(pk);
        timelock = new TimelockController(delay, roles, roles, address(0));
        if (pk != 0) vm.stopBroadcast();
    }
}
