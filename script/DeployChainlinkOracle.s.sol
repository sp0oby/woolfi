// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {ChainlinkOracleAdapter} from "../src/oracle/ChainlinkOracleAdapter.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys a plain Chainlink adapter for WETH or USDG.
/// @dev Unlike stock adapters, this does not call Robinhood token pause state. Required env:
///      CHAINLINK_FEED, FEED_HEARTBEAT, DEPLOYER_PRIVATE_KEY.
contract DeployChainlinkOracle is RobinhoodBroadcastGuard {
    function run() external returns (ChainlinkOracleAdapter adapter) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "DeployChainlinkOracle: wrong chain");
        _requireRobinhoodBroadcastApproval();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address priceFeed = vm.envAddress("CHAINLINK_FEED");
        uint256 heartbeat = vm.envUint("FEED_HEARTBEAT");
        require(priceFeed.code.length > 0, "DeployChainlinkOracle: feed has no code");

        vm.startBroadcast(pk);
        adapter = new ChainlinkOracleAdapter(priceFeed, heartbeat);
        vm.stopBroadcast();

        console2.log("Price feed     ", priceFeed);
        console2.log("Oracle adapter ", address(adapter));
    }
}
