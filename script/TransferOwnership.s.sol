// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {WoolFiPositionManager} from "../src/WoolFiPositionManager.sol";

/// @notice One-shot ownership handoff from the deployer EOA to a real multisig (e.g. a Safe).
///
/// @dev Run AFTER `DeployTestnet.s.sol` on a deployment whose Ownable contracts are still held by
///      the deployer key. Reads:
///        - DEPLOYER_PRIVATE_KEY  — the current owner, must sign every transfer
///        - MULTISIG_ADDRESS      — the new owner
///        - STRAND_ADDRESS, GOVERNOR_ADDRESS, PM_ADDRESS, MARKET_HOURS_ADDRESS
///      Anything left unset is silently skipped so the script is idempotent: re-running it after a
///      partial run only retries what still belongs to the deployer.
///
///      The underwriting vault's `rebalancer` is intentionally NOT touched: it is `immutable` at
///      construction and would require a vault redeploy (and migration of staked assets) to change.
contract TransferOwnership is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address multisig = vm.envAddress("MULTISIG_ADDRESS");
        require(multisig != address(0), "TransferOwnership: MULTISIG_ADDRESS unset");
        require(multisig != deployer, "TransferOwnership: multisig == deployer (no-op)");

        console2.log("Chain id ", block.chainid);
        console2.log("Deployer ", deployer);
        console2.log("Multisig ", multisig);

        address strand = _envOr("STRAND_ADDRESS", address(0));
        address governor = _envOr("GOVERNOR_ADDRESS", address(0));
        address pm = _envOr("PM_ADDRESS", address(0));
        address marketHours = _envOr("MARKET_HOURS_ADDRESS", address(0));

        vm.startBroadcast(pk);
        _maybeTransferOwnable("STRAND", strand, deployer, multisig);
        _maybeTransferOwnable("WoolFiGovernor", governor, deployer, multisig);
        _maybeTransferPm(pm, deployer, multisig);
        _maybeTransferOwnable("MultisigMarketHours", marketHours, deployer, multisig);
        vm.stopBroadcast();

        console2.log("");
        console2.log("Handoff complete. Verify with `cast call <addr> 'owner()(address)'` on Base Sepolia.");
    }

    function _maybeTransferOwnable(string memory label, address target, address deployer, address multisig) internal {
        if (target == address(0)) {
            console2.log(string.concat("skip  ", label, " (address unset)"));
            return;
        }
        address current = Ownable(target).owner();
        if (current == multisig) {
            console2.log(string.concat("done  ", label, " (already multisig)"));
            return;
        }
        if (current != deployer) {
            console2.log(string.concat("skip  ", label, " (owner is not deployer)"));
            return;
        }
        Ownable(target).transferOwnership(multisig);
        console2.log(string.concat("xfer  ", label));
    }

    /// @dev WoolFiPositionManager uses a custom `setOwner(address)` rather than OZ Ownable.
    function _maybeTransferPm(address target, address deployer, address multisig) internal {
        if (target == address(0)) {
            console2.log("skip  WoolFiPositionManager (address unset)");
            return;
        }
        address current = WoolFiPositionManager(target).owner();
        if (current == multisig) {
            console2.log("done  WoolFiPositionManager (already multisig)");
            return;
        }
        if (current != deployer) {
            console2.log("skip  WoolFiPositionManager (owner is not deployer)");
            return;
        }
        WoolFiPositionManager(target).setOwner(multisig);
        console2.log("xfer  WoolFiPositionManager");
    }

    function _envOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallback_;
        }
    }
}
