// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {DeployV3Migrator} from "../../script/DeployV3Migrator.s.sol";

contract DeployV3MigratorHarness is DeployV3Migrator {
    function check(string memory manifest, address woolfiPm) external view {
        _requireManifestPositionManager(manifest, woolfiPm);
    }
}

/// @notice P-3: the migrator deploy refuses a POSITION_MANAGER that differs from the manifest's.
contract DeployV3MigratorManifestTest is Test {
    DeployV3MigratorHarness harness;
    address pm = makeAddr("pm");

    function setUp() public {
        harness = new DeployV3MigratorHarness();
    }

    /// @dev One file per test: tests run in parallel.
    function _write(string memory path, address manifestPm) internal {
        vm.writeFile(path, string.concat('{"chainId":4663,"positionManager":"', vm.toString(manifestPm), '"}'));
    }

    function test_matchingManifestPasses() public {
        string memory tmp = "test/unit/.tmp-v3migrator-test_matchingManifestPasses.json";
        _write(tmp, pm);
        harness.check(tmp, pm);
        vm.removeFile(tmp);
    }

    function test_zeroManifestEntrySkipsCheck() public {
        string memory tmp = "test/unit/.tmp-v3migrator-test_zeroManifestEntrySkipsCheck.json";
        _write(tmp, address(0));
        harness.check(tmp, pm);
        vm.removeFile(tmp);
    }

    function test_missingManifestSkipsCheck() public view {
        harness.check("test/unit/.does-not-exist.json", pm);
    }

    function testRevert_mismatchedManifest() public {
        string memory tmp = "test/unit/.tmp-v3migrator-testRevert_mismatchedManifest.json";
        _write(tmp, makeAddr("otherPm"));
        vm.expectRevert(bytes("DeployV3Migrator: POSITION_MANAGER != manifest positionManager"));
        harness.check(tmp, pm);
        vm.removeFile(tmp);
    }

    function test_liveManifestIsReadable() public view {
        // The checked-in manifest parses; its pre-launch zero entry skips the check.
        harness.check("frontend/lib/deployments/robinhood.json", pm);
    }
}
