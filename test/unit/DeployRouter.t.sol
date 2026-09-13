// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DeployRouter} from "../../script/DeployRouter.s.sol";

contract DeployRouterTest is Test {
    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant HOOK = address(0xBEEF);
    address private constant URUFU_NFT = 0x60cB7082c8C14B4237C6a24c65E7C2E7abe2Bd17;
    string private constant MANIFEST = "frontend/lib/deployments/robinhood.json";

    function setUp() public {
        vm.chainId(4663);
        vm.etch(POOL_MANAGER, hex"60006000f3");
        vm.etch(HOOK, hex"60006000f3");
        vm.etch(URUFU_NFT, hex"60006000f3");
        vm.setEnv("DEPLOYER_PRIVATE_KEY", "1");
        vm.setEnv("POOL_MANAGER", vm.toString(POOL_MANAGER));
        vm.setEnv("HOOK", vm.toString(HOOK));
        vm.setEnv("URUFU_NFT", vm.toString(URUFU_NFT));
    }

    function test_dryRunDeploysRouterWithoutMutatingManifest() public {
        string memory beforeJson = vm.readFile(MANIFEST);
        assertGt(POOL_MANAGER.code.length, 0);
        DeployRouter script = new DeployRouter();
        address router = script.run();
        assertGt(router.code.length, 0);
        assertEq(vm.readFile(MANIFEST), beforeJson);
    }

    function test_rejectsPoolManagerWithoutCode() public {
        vm.etch(POOL_MANAGER, "");
        DeployRouter script = new DeployRouter();
        vm.expectRevert("DeployRouter: POOL_MANAGER has no code");
        script.run();
    }

    function test_rejectsUnknownChain() public {
        vm.chainId(1);
        DeployRouter script = new DeployRouter();
        vm.expectRevert("DeployRouter: Robinhood chain only");
        script.run();
    }
}
