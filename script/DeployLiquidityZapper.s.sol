// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {WoolFiLiquidityZapper, IWoolFiPositionManagerMint} from "../src/WoolFiLiquidityZapper.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys the dedicated one-token LP zapper.
/// @dev Requires DEPLOYER_PRIVATE_KEY, POSITION_MANAGER, WRAPPED_NATIVE, SWAP_EXECUTOR.
///      MULTISIG defaults to deployer.
contract DeployLiquidityZapper is RobinhoodBroadcastGuard {
    string private constant MANIFEST = "frontend/lib/deployments/robinhood.json";

    function run() external returns (WoolFiLiquidityZapper zapper) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("MULTISIG", deployer);
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address wrappedNative = vm.envAddress("WRAPPED_NATIVE");
        address swapExecutor = vm.envAddress("SWAP_EXECUTOR");
        require(positionManager.code.length > 0, "DeployZapper: POSITION_MANAGER has no code");
        require(wrappedNative.code.length > 0, "DeployZapper: WRAPPED_NATIVE has no code");
        require(swapExecutor.code.length > 0, "DeployZapper: SWAP_EXECUTOR has no code");
        require(owner != address(0), "DeployZapper: owner is zero");

        vm.startBroadcast(pk);
        zapper = new WoolFiLiquidityZapper(IWoolFiPositionManagerMint(positionManager), wrappedNative, deployer);
        zapper.setExecutorAllowed(swapExecutor, true);
        if (owner != deployer) zapper.setOwner(owner);
        vm.stopBroadcast();

        if (_isBroadcastContext()) {
            vm.writeJson(string.concat('"', vm.toString(address(zapper)), '"'), MANIFEST, ".liquidityZapper");
            vm.writeJson(string.concat('"', vm.toString(swapExecutor), '"'), MANIFEST, ".externalSwapExecutor");
        }
        console2.log("WoolFiLiquidityZapper", address(zapper));
    }
}
