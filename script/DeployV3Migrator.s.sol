// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {
    WoolFiV3Migrator,
    INonfungiblePositionManagerLike,
    IWoolFiPositionManagerMintV3
} from "../src/periphery/WoolFiV3Migrator.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

interface INpmIdentity {
    function factory() external view returns (address);
    function WETH9() external view returns (address);
}

/// @notice Deploys the stateless Uniswap v3 -> WoolFi position migrator.
/// @dev Requires DEPLOYER_PRIVATE_KEY and POSITION_MANAGER (the WoolFi PM). V3_POSITION_MANAGER
///      defaults to the official Robinhood Chain Uniswap v3 NonfungiblePositionManager. The
///      migrator has no owner and holds no funds, so there is no ownership handoff.
contract DeployV3Migrator is RobinhoodBroadcastGuard {
    string private constant MANIFEST = "frontend/lib/deployments/robinhood.json";
    address private constant ROBINHOOD_V3_NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address private constant ROBINHOOD_V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant ROBINHOOD_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    function run() external returns (WoolFiV3Migrator migrator) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address woolfiPm = vm.envAddress("POSITION_MANAGER");
        address v3Npm = vm.envOr("V3_POSITION_MANAGER", ROBINHOOD_V3_NPM);
        require(woolfiPm.code.length > 0, "DeployV3Migrator: POSITION_MANAGER has no code");
        require(v3Npm.code.length > 0, "DeployV3Migrator: V3_POSITION_MANAGER has no code");
        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            require(INpmIdentity(v3Npm).factory() == ROBINHOOD_V3_FACTORY, "DeployV3Migrator: wrong v3 factory");
            require(INpmIdentity(v3Npm).WETH9() == ROBINHOOD_WETH, "DeployV3Migrator: wrong WETH9");
        }

        vm.startBroadcast(pk);
        migrator = new WoolFiV3Migrator(INonfungiblePositionManagerLike(v3Npm), IWoolFiPositionManagerMintV3(woolfiPm));
        vm.stopBroadcast();

        if (_isBroadcastContext()) {
            vm.writeJson(string.concat('"', vm.toString(address(migrator)), '"'), MANIFEST, ".v3Migrator");
            vm.writeJson(string.concat('"', vm.toString(v3Npm), '"'), MANIFEST, ".uniswapV3PositionManager");
        }
        console2.log("WoolFiV3Migrator", address(migrator));
        console2.log("Uniswap v3 NPM  ", v3Npm);
    }
}
