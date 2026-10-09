// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {WoolFiLiquidityZapper, IWoolFiPositionManagerMint} from "../../src/WoolFiLiquidityZapper.sol";
import {UrufuFeeRebateDistributor} from "../../src/UrufuFeeRebateDistributor.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

import {Deploy} from "../../script/Deploy.s.sol";
import {DeployTimelock} from "../../script/DeployTimelock.s.sol";
import {TimelockHandoff} from "../../script/TimelockHandoff.s.sol";

/// @dev Exposes the Transaction Builder writer so the JSON can be round-tripped.
contract TimelockHandoffHarness is TimelockHandoff {
    function builderJson(address safe, string memory name, Call[] memory calls) external view returns (string memory) {
        return _builderJson(safe, name, calls);
    }
}

/// @notice End-to-end governance handoff: the real Deploy flow, the TimelockController from
///         DeployTimelock, and the exact Safe batches TimelockHandoff writes, executed as the Safe.
contract WoolFiTimelockTest is Deployers {
    using PoolIdLibrary for PoolKey;

    uint256 constant DELAY = 3 days;

    address safe = makeAddr("safe");
    address stranger = makeAddr("stranger");
    address rebalancer = makeAddr("rebalancer");

    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiGovernor governor;
    UrufuFeeRebateDistributor distributor;
    WoolFiLiquidityZapper zapper;
    WoolFiUnderwritingVault vault;
    TimelockController timelock;
    TimelockHandoff handoff;
    MockERC20 uru;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    PoolKey poolKey;
    PoolId poolId;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        uru = new MockERC20("URU", "URU", 18);

        Deploy deployScript = new Deploy();
        Deploy.Deployment memory dep = deployScript.deployWoolFi(manager, address(uru), address(deployScript), safe);
        hook = WoolFiHook(dep.hook);
        pm = WoolFiPositionManager(dep.positionManager);
        governor = WoolFiGovernor(dep.governor); // ownership still pending to the Safe

        MockERC20 nft = new MockERC20("Urufu Gemu", "GEMU", 0);
        distributor = new UrufuFeeRebateDistributor(hook, address(nft), safe);
        zapper = new WoolFiLiquidityZapper(IWoolFiPositionManagerMint(address(pm)), address(uru), safe);
        vault = new WoolFiUnderwritingVault(
            address(uru), address(hook), Currency.unwrap(currency0), Currency.unwrap(currency1), rebalancer, 1_000e18
        );

        timelock = new DeployTimelock().deployTimelock(address(this), safe, DELAY, 0);
        handoff = new TimelockHandoff();

        oracle0 = new MockPriceOracle(1e18);
        oracle1 = new MockPriceOracle(1e18);
        marketHours = new MockMarketHours(true);
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
    }

    // -----------------------------------------------------------------
    // helpers
    // -----------------------------------------------------------------

    function _addresses() internal view returns (TimelockHandoff.Addresses memory a) {
        a.timelock = address(timelock);
        a.governor = address(governor);
        a.positionManager = address(pm);
        a.rebateDistributor = address(distributor);
        a.liquidityZapper = address(zapper);
        a.vaults = new address[](1);
        a.vaults[0] = address(vault);
    }

    /// @dev Execute a Safe batch exactly as written to the Transaction Builder JSON.
    function _runAsSafe(TimelockHandoff.Call[] memory calls) internal {
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(safe);
            (bool ok, bytes memory ret) = calls[i].to.call(calls[i].data);
            if (!ok) {
                assembly {
                    revert(add(ret, 32), mload(ret))
                }
            }
        }
    }

    function _handOff() internal {
        (TimelockHandoff.Call[] memory schedule, TimelockHandoff.Call[] memory execute,) =
            handoff.buildHandoff(_addresses(), safe, keccak256("salt"));
        _runAsSafe(schedule);
        vm.warp(block.timestamp + DELAY);
        _runAsSafe(execute);
    }

    function _params() internal view returns (WoolFiHook.AuthParams memory) {
        return WoolFiHook.AuthParams({
            oracle0: oracle0,
            oracle1: oracle1,
            marketHours: marketHours,
            kScaled: 40_000,
            baseFeeBps: 30,
            toleranceBps: 500,
            hardThresholdBps: 1500
        });
    }

    /// @dev Schedule then (after the delay) execute one governor call through the timelock as the Safe.
    function _viaTimelock(bytes memory data, bytes32 salt) internal {
        vm.prank(safe);
        timelock.schedule(address(governor), 0, data, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        timelock.execute(address(governor), 0, data, bytes32(0), salt);
    }

    // -----------------------------------------------------------------
    // deployment and handoff
    // -----------------------------------------------------------------

    function test_deployTimelock_rolesAndNoAdmin() public view {
        assertEq(timelock.getMinDelay(), DELAY);
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), safe));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), safe));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), safe));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), safe));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0))); // execution is not open
    }

    function testRevert_deployTimelock_rejectsDeployerAsMultisig() public {
        DeployTimelock script = new DeployTimelock();
        vm.expectRevert("DeployTimelock: MULTISIG must not be the deployer");
        script.deployTimelock(safe, safe, DELAY, 0);
    }

    function testRevert_deployTimelock_robinhoodRequires3dAndSafeCode() public {
        DeployTimelock script = new DeployTimelock();
        vm.chainId(4663);
        vm.expectRevert("DeployTimelock: MULTISIG has no code");
        script.deployTimelock(address(this), safe, DELAY, 0);

        vm.etch(safe, hex"00");
        vm.expectRevert("DeployTimelock: delay below 3 days");
        script.deployTimelock(address(this), safe, DELAY - 1, 0);
    }

    function test_handoff_movesEveryOwnedContractToTimelock() public {
        _handOff();
        assertEq(governor.owner(), address(timelock));
        assertEq(pm.owner(), address(timelock));
        assertEq(distributor.owner(), address(timelock));
        assertEq(zapper.owner(), address(timelock));
        assertEq(governor.guardian(), safe);
        assertEq(governor.pendingOwner(), address(0));
    }

    function test_handoff_batchShape() public view {
        (
            TimelockHandoff.Call[] memory schedule,
            TimelockHandoff.Call[] memory execute,
            TimelockHandoff.Operation memory op
        ) = handoff.buildHandoff(_addresses(), safe, keccak256("salt"));
        // governor: accept + setGuardian + transfer; PM, distributor, zapper: transfer; plus scheduleBatch.
        assertEq(schedule.length, 7);
        assertEq(schedule[0].to, address(governor));
        assertEq(schedule[0].data, abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        assertEq(schedule[1].data, abi.encodeCall(WoolFiGovernor.setGuardian, (safe)));
        assertEq(schedule[2].data, abi.encodeCall(Ownable.transferOwnership, (address(timelock))));
        assertEq(execute.length, 1);
        assertEq(op.targets.length, 4);
        assertEq(op.delay, DELAY);
        assertEq(schedule[6].to, address(timelock));
        assertEq(
            schedule[6].data,
            abi.encodeCall(
                TimelockController.scheduleBatch, (op.targets, op.values, op.payloads, bytes32(0), op.salt, DELAY)
            )
        );
    }

    /// @dev Write batch JSON, parse it back, and run the parsed calldata: what the Safe imports is
    ///      exactly what the builder produced, and it completes the handoff.
    function test_builderJson_roundTripsAndExecutes() public {
        TimelockHandoffHarness harness = new TimelockHandoffHarness();
        (TimelockHandoff.Call[] memory schedule, TimelockHandoff.Call[] memory execute,) =
            harness.buildHandoff(_addresses(), safe, keccak256("salt"));

        TimelockHandoff.Call[] memory parsed = _parse(harness.builderJson(safe, "schedule", schedule));
        assertEq(parsed.length, schedule.length);
        for (uint256 i; i < parsed.length; ++i) {
            assertEq(parsed[i].to, schedule[i].to);
            assertEq(parsed[i].data, schedule[i].data);
        }
        _runAsSafe(parsed);
        vm.warp(block.timestamp + DELAY);
        _runAsSafe(_parse(harness.builderJson(safe, "execute", execute)));
        assertEq(governor.owner(), address(timelock));
        assertEq(zapper.owner(), address(timelock));
    }

    function _parse(string memory json) internal view returns (TimelockHandoff.Call[] memory calls) {
        assertEq(vm.parseJsonString(json, ".version"), "1.0");
        assertEq(vm.parseJsonString(json, ".chainId"), vm.toString(block.chainid));
        uint256 n;
        while (vm.keyExistsJson(json, string.concat(".transactions[", vm.toString(n), "]"))) ++n;
        calls = new TimelockHandoff.Call[](n);
        for (uint256 i; i < n; ++i) {
            string memory k = string.concat(".transactions[", vm.toString(i), "]");
            assertEq(vm.parseJsonString(json, string.concat(k, ".value")), "0");
            calls[i].to = vm.parseJsonAddress(json, string.concat(k, ".to"));
            calls[i].data = vm.parseJsonBytes(json, string.concat(k, ".data"));
        }
    }

    function testRevert_handoff_earlyExecute() public {
        (TimelockHandoff.Call[] memory schedule, TimelockHandoff.Call[] memory execute,) =
            handoff.buildHandoff(_addresses(), safe, keccak256("salt"));
        _runAsSafe(schedule);
        vm.warp(block.timestamp + DELAY - 1);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        _runAsSafe(execute);
    }

    function testRevert_handoff_rebalancerIsSafe() public {
        TimelockHandoff.Addresses memory a = _addresses();
        a.vaults[0] = address(
            new WoolFiUnderwritingVault(
                address(uru), address(hook), Currency.unwrap(currency0), Currency.unwrap(currency1), safe, 1e18
            )
        );
        vm.expectRevert("TimelockHandoff: vault rebalancer is the Safe (M-3)");
        handoff.buildHandoff(a, safe, keccak256("salt"));
    }

    function testRevert_handoff_rebalancerIsTimelock() public {
        TimelockHandoff.Addresses memory a = _addresses();
        a.vaults[0] = address(
            new WoolFiUnderwritingVault(
                address(uru),
                address(hook),
                Currency.unwrap(currency0),
                Currency.unwrap(currency1),
                address(timelock),
                1e18
            )
        );
        vm.expectRevert("TimelockHandoff: vault rebalancer is the timelock (M-3)");
        handoff.buildHandoff(a, safe, keccak256("salt"));
    }

    function testRevert_handoff_contractNotOwnedBySafe() public {
        TimelockHandoff.Addresses memory a = _addresses();
        a.liquidityZapper =
            address(new WoolFiLiquidityZapper(IWoolFiPositionManagerMint(address(pm)), address(uru), stranger));
        vm.expectRevert("TimelockHandoff: contract not owned by the Safe");
        handoff.buildHandoff(a, safe, keccak256("salt"));
    }

    function testRevert_handoff_timelockWithAdmin() public {
        address[] memory roles = new address[](1);
        roles[0] = safe;
        TimelockHandoff.Addresses memory a = _addresses();
        a.timelock = address(new TimelockController(DELAY, roles, roles, safe));
        vm.expectRevert("TimelockHandoff: Safe holds timelock admin");
        handoff.buildHandoff(a, safe, keccak256("salt"));
    }

    // -----------------------------------------------------------------
    // after the handoff
    // -----------------------------------------------------------------

    function testRevert_safeDirectOwnerCall_afterHandoff() public {
        _handOff();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        governor.authorizePool(poolKey, _params());

        vm.prank(safe);
        vm.expectRevert(WoolFiPositionManager.NotOwner.selector);
        pm.transferOwnership(safe);
    }

    function test_configChange_waitsForDelay() public {
        _handOff();
        _viaTimelock(abi.encodeCall(WoolFiGovernor.authorizePool, (poolKey, _params())), keccak256("auth"));

        WoolFiHook.AuthParams memory p = _params();
        p.baseFeeBps = 50;
        bytes memory data = abi.encodeCall(WoolFiGovernor.updatePoolConfig, (poolKey, p));
        bytes32 salt = keccak256("update");
        vm.prank(safe);
        timelock.schedule(address(governor), 0, data, bytes32(0), salt, DELAY);

        vm.warp(block.timestamp + DELAY - 1);
        vm.prank(safe);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(governor), 0, data, bytes32(0), salt);
        assertEq(hook.poolConfig(poolId).baseFeeBps, 30);

        vm.warp(block.timestamp + 1);
        vm.prank(safe);
        timelock.execute(address(governor), 0, data, bytes32(0), salt);
        assertEq(hook.poolConfig(poolId).baseFeeBps, 50);
    }

    function testRevert_scheduleBelowMinDelay() public {
        _handOff();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockInsufficientDelay.selector, DELAY - 1, DELAY));
        timelock.schedule(address(governor), 0, abi.encodeCall(WoolFiGovernor.unpauseHook, ()), 0, 0, DELAY - 1);
    }

    function test_guardian_pausesInstantly_cannotUnpauseOrConfigure() public {
        _handOff();
        vm.prank(safe);
        governor.pauseHook();
        assertTrue(hook.paused());

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        governor.unpauseHook();

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        governor.setVault(poolKey, address(vault), 2000);

        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, safe));
        governor.setGuardian(stranger);

        _viaTimelock(abi.encodeCall(WoolFiGovernor.unpauseHook, ()), keccak256("unpause"));
        assertFalse(hook.paused());
    }

    function testRevert_stranger_cannotPause() public {
        _handOff();
        vm.prank(stranger);
        vm.expectRevert(WoolFiGovernor.NotOwnerOrGuardian.selector);
        governor.pauseHook();
    }

    function test_clearingGuardian_disablesInstantPause() public {
        _handOff();
        _viaTimelock(abi.encodeCall(WoolFiGovernor.setGuardian, (address(0))), keccak256("clear"));
        assertEq(governor.guardian(), address(0));

        vm.prank(safe);
        vm.expectRevert(WoolFiGovernor.NotOwnerOrGuardian.selector);
        governor.pauseHook();

        // The owner (timelock) can still pause, with the delay.
        _viaTimelock(abi.encodeCall(WoolFiGovernor.pauseHook, ()), keccak256("pause"));
        assertTrue(hook.paused());
    }

    function test_noAdmin_rolesChangeOnlyThroughTimelock() public {
        bytes32 proposer = timelock.PROPOSER_ROLE();
        bytes32 admin = timelock.DEFAULT_ADMIN_ROLE();
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, safe, admin));
        timelock.grantRole(proposer, stranger);

        bytes memory data = abi.encodeCall(IAccessControl.grantRole, (proposer, stranger));
        vm.prank(safe);
        timelock.schedule(address(timelock), 0, data, bytes32(0), keccak256("grant"), DELAY);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        timelock.execute(address(timelock), 0, data, bytes32(0), keccak256("grant"));
        assertTrue(timelock.hasRole(proposer, stranger));
    }

    function test_safe_canCancelScheduledChange() public {
        _handOff();
        bytes memory data = abi.encodeCall(WoolFiGovernor.setGuardian, (stranger));
        bytes32 salt = keccak256("bad");
        vm.prank(safe);
        timelock.schedule(address(governor), 0, data, bytes32(0), salt, DELAY);
        bytes32 id = timelock.hashOperation(address(governor), 0, data, bytes32(0), salt);

        bytes32 canceller = timelock.CANCELLER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, canceller)
        );
        timelock.cancel(id);

        vm.prank(safe);
        timelock.cancel(id);
        vm.warp(block.timestamp + DELAY);
        vm.prank(safe);
        vm.expectPartialRevert(TimelockController.TimelockUnexpectedOperationState.selector);
        timelock.execute(address(governor), 0, data, bytes32(0), salt);
        assertEq(governor.guardian(), safe);
    }

    function testRevert_stranger_cannotScheduleOrExecute() public {
        _handOff();
        bytes memory data = abi.encodeCall(WoolFiGovernor.unpauseHook, ());
        bytes32 proposer = timelock.PROPOSER_ROLE();
        vm.prank(stranger);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, stranger, proposer)
        );
        timelock.schedule(address(governor), 0, data, bytes32(0), 0, DELAY);
    }
}
