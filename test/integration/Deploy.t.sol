// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {STRAND} from "../../src/STRAND.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {HookMiner} from "../../script/lib/HookMiner.sol";

/// @notice Verifies the deploy scripts' underlying logic end-to-end: HookMiner produces an address
///         the canonical CREATE2 factory actually deploys to (with the right permission bits), the
///         post-deploy wiring matches what {Deploy.s.sol} does, and a {CreatePool.s.sol}-style
///         authorize → initialize → wire flow goes through cleanly.
contract DeployTest is Deployers {
    using PoolIdLibrary for PoolKey;

    address multisig = makeAddr("multisig");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
    }

    function _deployCore()
        internal
        returns (STRAND strand, WoolFiHook hook, WoolFiPositionManager pm, WoolFiGovernor gov)
    {
        strand = new STRAND(multisig);

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory hookInit = abi.encodePacked(type(WoolFiHook).creationCode, abi.encode(manager, address(this)));
        (address minedHook, bytes32 salt) = HookMiner.find(flags, hookInit);
        address deployed = HookMiner.deploy(salt, hookInit);
        assertEq(deployed, minedHook); // mining math == the canonical factory's CREATE2
        hook = WoolFiHook(deployed);

        assertEq(uint160(deployed) & ((uint160(1) << 14) - 1), uint160(flags)); // permission bits encoded

        pm = new WoolFiPositionManager(manager, multisig);
        gov = new WoolFiGovernor(address(hook), address(this));
        hook.setGovernor(address(gov));
        gov.setHookPositionManager(address(pm));
        gov.transferOwnership(multisig);
    }

    function test_deploy_wiresEverything() public {
        (STRAND strand, WoolFiHook hook, WoolFiPositionManager pm, WoolFiGovernor gov) = _deployCore();
        assertEq(hook.governor(), address(gov));
        assertEq(hook.positionManager(), address(pm));
        assertEq(gov.owner(), multisig);
        assertEq(pm.owner(), multisig);
        assertEq(strand.owner(), multisig);
        assertEq(address(gov.hook()), address(hook));
    }

    function test_deployScript_usesExternalStakingToken() public {
        MockERC20 stakingToken = new MockERC20("External URU Substitute", "URU", 18);
        Deploy deploymentScript = new Deploy();

        Deploy.Deployment memory dep =
            deploymentScript.deployWoolFi(manager, address(stakingToken), address(deploymentScript), multisig);

        assertEq(dep.stakingToken, address(stakingToken));
        assertEq(WoolFiHook(dep.hook).governor(), dep.governor);
        assertEq(WoolFiHook(dep.hook).positionManager(), dep.positionManager);
        assertEq(WoolFiGovernor(dep.governor).owner(), multisig);
        assertEq(WoolFiPositionManager(dep.positionManager).owner(), multisig);
    }

    function testRevert_deployScript_rejectsNonContractStakingToken() public {
        Deploy deploymentScript = new Deploy();
        vm.expectRevert("Deploy: STAKING_TOKEN has no code");
        deploymentScript.deployWoolFi(manager, makeAddr("stakingToken"), address(deploymentScript), multisig);
    }

    function test_createPool_authorizeInitializeAndWire() public {
        (STRAND strand, WoolFiHook hook, WoolFiPositionManager pm, WoolFiGovernor gov) = _deployCore();

        MockPriceOracle oracle0 = new MockPriceOracle(1e18);
        MockPriceOracle oracle1 = new MockPriceOracle(1e18);
        MockMarketHours mh = new MockMarketHours(true);
        WoolFiUnderwritingVault vault = new WoolFiUnderwritingVault(
            address(strand),
            address(hook),
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            makeAddr("rebalancer")
        );

        PoolKey memory key = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        uint256 id = uint256(PoolId.unwrap(key.toId()));
        address buyback = makeAddr("buyback");

        vm.startPrank(multisig);
        gov.authorizePool(
            key,
            WoolFiHook.AuthParams({
                oracle0: oracle0,
                oracle1: oracle1,
                marketHours: mh,
                kScaled: 40_000,
                baseFeeBps: 30,
                toleranceBps: 500,
                hardThresholdBps: 1500
            })
        );
        vm.stopPrank();

        manager.initialize(key, SQRT_PRICE_1_1);

        vm.startPrank(multisig);
        gov.setVault(key, address(vault), 2000);
        pm.setFeeConfig(key, address(vault), 2000, buyback, 1000);
        vm.stopPrank();

        assertTrue(hook.poolConfig(key.toId()).configured);
        assertEq(hook.poolConfig(key.toId()).vault, address(vault));

        (address fv, uint16 vb, address bs, uint16 bb) = pm.feeConfig(id);
        assertEq(fv, address(vault));
        assertEq(vb, 2000);
        assertEq(bs, buyback);
        assertEq(bb, 1000);
    }
}
