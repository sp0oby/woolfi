// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {WoolFiHook} from "../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../src/WoolFiPositionManager.sol";
import {RebalanceKeeper} from "../src/RebalanceKeeper.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys the stateless, permissionless keeper wrapper for verified core addresses.
contract DeployKeeper is RobinhoodBroadcastGuard {
    function run() external returns (RebalanceKeeper keeper) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        WoolFiHook hook = WoolFiHook(vm.envAddress("HOOK"));
        WoolFiPositionManager pm = WoolFiPositionManager(vm.envAddress("POSITION_MANAGER"));
        require(address(hook).code.length > 0, "DeployKeeper: hook has no code");
        require(address(pm).code.length > 0, "DeployKeeper: PM has no code");

        vm.startBroadcast(pk);
        keeper = new RebalanceKeeper(hook, pm);
        vm.stopBroadcast();
        console2.log("RebalanceKeeper", address(keeper));
    }
}
