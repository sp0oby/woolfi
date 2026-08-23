// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";

import {RobinhoodStockOracleAdapter} from "../src/oracle/RobinhoodStockOracleAdapter.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys one guarded Chainlink adapter for a canonical Robinhood Stock Token.
/// @dev Resolve feed addresses and heartbeat from Chainlink immediately before deployment.
contract DeployRobinhoodOracle is RobinhoodBroadcastGuard {
    function run() external returns (RobinhoodStockOracleAdapter adapter) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "DeployRobinhoodOracle: wrong chain");
        _requireRobinhoodBroadcastApproval();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address stockToken = vm.envAddress("STOCK_TOKEN");
        address priceFeed = vm.envAddress("CHAINLINK_FEED");
        address sequencerFeed = vm.envAddress("SEQUENCER_UPTIME_FEED");
        uint256 heartbeat = vm.envUint("FEED_HEARTBEAT");
        uint256 gracePeriod = vm.envOr("SEQUENCER_GRACE_PERIOD", uint256(1 hours));

        vm.startBroadcast(pk);
        adapter = new RobinhoodStockOracleAdapter(stockToken, priceFeed, sequencerFeed, heartbeat, gracePeriod);
        vm.stopBroadcast();

        console2.log("Robinhood stock token", stockToken);
        console2.log("Price feed           ", priceFeed);
        console2.log("Oracle adapter       ", address(adapter));
    }
}
