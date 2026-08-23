// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

/// @dev Shared safety latch for every Robinhood production broadcast script.
abstract contract RobinhoodBroadcastGuard is Script {
    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;

    function _requireRobinhoodBroadcastApproval() internal view {
        if (!_isBroadcastContext()) return;
        require(block.chainid == ROBINHOOD_CHAIN_ID, "Robinhood: broadcast requires chain 4663");
        require(vm.envOr("CONFIRM_MAINNET", false), "Robinhood: set CONFIRM_MAINNET=true");
    }

    function _isBroadcastContext() internal view returns (bool) {
        return vm.isContext(VmSafe.ForgeContext.ScriptBroadcast) || vm.isContext(VmSafe.ForgeContext.ScriptResume);
    }
}
