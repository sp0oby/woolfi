// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {WoolFiArbExecutor, IV3SwapRouter02} from "../src/periphery/WoolFiArbExecutor.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys the permissionless, ownerless WoolFiArbExecutor used by arb-agent/.
/// @dev Env: DEPLOYER_PRIVATE_KEY, POOL_MANAGER, SWAP_EXECUTOR (Uniswap v3 SwapRouter02).
///      Robinhood broadcasts additionally require CONFIRM_MAINNET=true. The executor holds no funds
///      and has no admin, so anyone may deploy their own instance; this script is a convenience.
contract DeployArbExecutor is RobinhoodBroadcastGuard {
    function run() external returns (WoolFiArbExecutor executor) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address poolManager = vm.envAddress("POOL_MANAGER");
        address v3Router = vm.envAddress("SWAP_EXECUTOR");
        require(poolManager.code.length > 0, "DeployArbExecutor: POOL_MANAGER has no code");
        require(v3Router.code.length > 0, "DeployArbExecutor: SWAP_EXECUTOR has no code");

        vm.startBroadcast(pk);
        executor = new WoolFiArbExecutor(IPoolManager(poolManager), IV3SwapRouter02(v3Router));
        vm.stopBroadcast();

        console2.log("WoolFiArbExecutor", address(executor));
    }
}
