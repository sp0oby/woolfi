// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {WoolFiSwapRouter} from "../src/WoolFiSwapRouter.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Standalone deploy script for {WoolFiSwapRouter}. Idempotent: writes the resulting
///         address into the existing `frontend/lib/deployments/<chain>.json` under `.swapRouter`
///         so the dashboard's swap panel can pick it up without redeploying the rest of the system.
contract DeployRouter is RobinhoodBroadcastGuard {
    string internal constant MANIFEST = "frontend/lib/deployments/robinhood.json";

    function run() external returns (address router) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "DeployRouter: Robinhood chain only");
        _requireRobinhoodBroadcastApproval();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        require(address(poolManager).code.length > 0, "DeployRouter: POOL_MANAGER has no code");

        string memory json = vm.readFile(MANIFEST);
        require(vm.parseJsonUint(json, ".chainId") == ROBINHOOD_CHAIN_ID, "DeployRouter: wrong manifest chain");
        address manifestManager = vm.parseJsonAddress(json, ".poolManager");
        require(
            manifestManager == address(0) || manifestManager == address(poolManager),
            "DeployRouter: PoolManager manifest mismatch"
        );

        address existing = vm.parseJsonAddress(json, ".swapRouter");
        if (existing != address(0)) {
            require(existing.code.length > 0, "DeployRouter: manifest router has no code");
            try WoolFiSwapRouter(existing).poolManager() returns (IPoolManager currentManager) {
                require(address(currentManager) == address(poolManager), "DeployRouter: router manager mismatch");
            } catch {
                revert("DeployRouter: manifest router is incompatible");
            }
            console2.log("Reusing swapRouter", existing);
            return existing;
        }

        console2.log("Chain id   ", block.chainid);
        console2.log("Deployer   ", vm.addr(pk));
        console2.log("PoolManager", address(poolManager));

        vm.startBroadcast(pk);
        WoolFiSwapRouter r = new WoolFiSwapRouter(poolManager);
        vm.stopBroadcast();
        router = address(r);

        console2.log("swapRouter ", router);

        if (_isBroadcastContext()) {
            // writeJson expects a JSON string literal for an address, including quotes.
            vm.writeJson(string.concat('"', vm.toString(router), '"'), MANIFEST, ".swapRouter");
            console2.log("Patched JSON at", MANIFEST);
        }
    }
}
