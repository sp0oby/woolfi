// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

import {UrufuFeeRebateDistributor} from "../src/UrufuFeeRebateDistributor.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Configures and optionally funds one receipt-tracked rebate token.
/// @dev The signing account must own the distributor and hold FUND_AMOUNT of TOKEN.
contract ConfigureRebate is RobinhoodBroadcastGuard {
    function run() external {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address signer = vm.addr(pk);
        UrufuFeeRebateDistributor distributor = UrufuFeeRebateDistributor(vm.envAddress("REBATE_DISTRIBUTOR"));
        address token = vm.envAddress("TOKEN");
        uint256 weeklyCap = vm.envUint("WEEKLY_CAP");
        uint256 fundAmount = vm.envOr("FUND_AMOUNT", uint256(0));

        require(address(distributor).code.length > 0, "ConfigureRebate: distributor has no code");
        require(token.code.length > 0, "ConfigureRebate: token has no code");
        require(distributor.owner() == signer, "ConfigureRebate: signer is not owner");

        vm.startBroadcast(pk);
        distributor.setWeeklyCap(token, weeklyCap);
        if (fundAmount > 0) {
            SafeTransferLib.safeApproveWithRetry(token, address(distributor), fundAmount);
            distributor.fund(token, fundAmount);
            SafeTransferLib.safeApproveWithRetry(token, address(distributor), 0);
        }
        vm.stopBroadcast();

        console2.log("Rebate token", token);
        console2.log("Weekly cap", weeklyCap);
        console2.log("Funded", fundAmount);
    }
}
