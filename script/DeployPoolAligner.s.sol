// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {WoolFiPoolAligner} from "../src/periphery/WoolFiPoolAligner.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys the permissionless, ownerless WoolFiPoolAligner that keeps unseeded pools on their
///         oracle fair price. A broadcast records the address as `poolAligner` in the deployment manifest.
/// @dev Env: DEPLOYER_PRIVATE_KEY, POOL_MANAGER. Robinhood broadcasts additionally require
///      CONFIRM_MAINNET=true. The aligner holds no funds and has no admin.
contract DeployPoolAligner is RobinhoodBroadcastGuard {
    string private constant MANIFEST = "frontend/lib/deployments/robinhood.json";

    function run() external returns (WoolFiPoolAligner aligner) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        require(poolManager.code.length > 0, "DeployPoolAligner: POOL_MANAGER has no code");

        vm.startBroadcast(pk);
        aligner = new WoolFiPoolAligner(IPoolManager(poolManager));
        vm.stopBroadcast();

        if (_isBroadcastContext()) {
            vm.writeJson(string.concat('"', vm.toString(address(aligner)), '"'), MANIFEST, ".poolAligner");
        }
        console2.log("WoolFiPoolAligner", address(aligner));
    }
}
