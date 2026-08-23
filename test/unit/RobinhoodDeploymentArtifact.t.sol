// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {RobinhoodDeploymentArtifact} from "../../script/lib/RobinhoodDeploymentArtifact.sol";

contract ArtifactHarness is RobinhoodDeploymentArtifact {
    function upsert(string memory path, PoolArtifact memory pool) external {
        _upsertPoolAtPath(path, pool);
    }
}

contract RobinhoodDeploymentArtifactTest is Test {
    string private constant PATH = "cache/robinhood-artifact.test.json";
    ArtifactHarness private harness;

    function setUp() public {
        harness = new ArtifactHarness();
        vm.writeFile(PATH, '{"chainId":4663,"poolCount":0,"pools":[]}');
    }

    function tearDown() public {
        vm.removeFile(PATH);
    }

    function test_appendsThenUpdatesPoolById() public {
        RobinhoodDeploymentArtifact.PoolArtifact memory pool = _pool();
        harness.upsert(PATH, pool);

        string memory json = vm.readFile(PATH);
        assertEq(vm.parseJsonUint(json, ".poolCount"), 1);
        assertEq(vm.parseJsonString(json, ".pools[0].slug"), "mstr-usdg");
        assertEq(vm.parseJsonAddress(json, ".pools[0].vault"), address(0x55));

        RobinhoodDeploymentArtifact.PoolArtifact memory other = _pool();
        other.poolId = bytes32(uint256(2));
        other.slug = "coin-weth";
        other.vault = address(0x77);
        harness.upsert(PATH, other);
        json = vm.readFile(PATH);
        assertEq(vm.parseJsonUint(json, ".poolCount"), 2);
        assertEq(vm.parseJsonString(json, ".pools[1].slug"), "coin-weth");

        pool.slug = "mstr-usdg-v2";
        pool.vault = address(0x66);
        harness.upsert(PATH, pool);

        json = vm.readFile(PATH);
        assertEq(vm.parseJsonUint(json, ".poolCount"), 2);
        assertEq(vm.parseJsonString(json, ".pools[0].slug"), "mstr-usdg-v2");
        assertEq(vm.parseJsonAddress(json, ".pools[0].vault"), address(0x66));
        assertEq(vm.parseJsonString(json, ".pools[1].slug"), "coin-weth");
    }

    function test_rejectsIncompletePool() public {
        RobinhoodDeploymentArtifact.PoolArtifact memory pool = _pool();
        pool.oracle1 = address(0);
        vm.expectRevert("Artifact: zero oracle");
        harness.upsert(PATH, pool);
    }

    function _pool() private pure returns (RobinhoodDeploymentArtifact.PoolArtifact memory) {
        return RobinhoodDeploymentArtifact.PoolArtifact({
            poolId: bytes32(uint256(1)),
            slug: "mstr-usdg",
            token0: address(0x11),
            token1: address(0x22),
            token0Symbol: "MSTR",
            token1Symbol: "USDG",
            oracle0: address(0x33),
            oracle1: address(0x44),
            marketHours: address(0),
            vault: address(0x55),
            tickSpacing: 60,
            baseFeeBps: 30,
            toleranceBps: 500,
            hardThresholdBps: 1500,
            drawdownBps: 1000,
            vaultFeeBps: 2000,
            buybackBps: 1000
        });
    }
}
