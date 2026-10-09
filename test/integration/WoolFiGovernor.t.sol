// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

contract WoolFiGovernorTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiGovernor governor;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;

    PoolKey poolKey;
    PoolId poolId;

    address multisig = makeAddr("multisig");
    address stranger = makeAddr("stranger");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4444) << 144));
        // deploy with this contract as the bootstrap governor, then hand the role to the governor contract
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(this)), hookAddr);
        hook = WoolFiHook(hookAddr);

        governor = new WoolFiGovernor(address(hook), multisig);
        hook.proposeGovernor(address(governor));
        vm.prank(multisig);
        governor.acceptHookGovernor();

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

    function _paramsV2() internal view returns (WoolFiHook.AuthParamsV2 memory) {
        return WoolFiHook.AuthParamsV2({
            core: _params(), safety: WoolFiHook.SafetyParams({stabilizationSeconds: 300, maxOracleSkew: 60})
        });
    }

    // -----------------------------------------------------------------
    // governance surface (owner = multisig)
    // -----------------------------------------------------------------

    function test_authorizePool_throughGovernor() public {
        vm.prank(multisig);
        governor.authorizePool(poolKey, _params());
        assertTrue(hook.poolConfig(poolId).configured);
    }

    function test_authorizeAndUpdateSafetyV2_throughGovernor() public {
        vm.startPrank(multisig);
        governor.authorizePoolV2(poolKey, _paramsV2());
        assertEq(hook.poolConfig(poolId).stabilizationSeconds, 300);
        assertEq(hook.poolConfig(poolId).maxOracleSkew, 60);

        governor.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 600, maxOracleSkew: 120}));
        assertEq(hook.poolConfig(poolId).stabilizationSeconds, 600);
        assertEq(hook.poolConfig(poolId).maxOracleSkew, 120);

        WoolFiHook.AuthParamsV2 memory update = _paramsV2();
        update.core.baseFeeBps = 50;
        update.safety.maxOracleSkew = 90;
        governor.updatePoolConfigV2(poolKey, update);
        vm.stopPrank();
        assertEq(hook.poolConfig(poolId).baseFeeBps, 50);
        assertEq(hook.poolConfig(poolId).maxOracleSkew, 90);
    }

    function test_updatePoolConfig_throughGovernor() public {
        vm.startPrank(multisig);
        governor.authorizePool(poolKey, _params());
        WoolFiHook.AuthParams memory p = _params();
        p.baseFeeBps = 50;
        governor.updatePoolConfig(poolKey, p);
        vm.stopPrank();
        assertEq(hook.poolConfig(poolId).baseFeeBps, 50);
    }

    function test_setVault_throughGovernor() public {
        vm.startPrank(multisig);
        governor.authorizePool(poolKey, _params());
        governor.setVault(poolKey, address(0xCAFE), 2000);
        vm.stopPrank();
        assertEq(hook.poolConfig(poolId).vault, address(0xCAFE));
        assertEq(hook.poolConfig(poolId).drawdownBps, 2000);
    }

    function test_pauseAndUnpause_throughGovernor() public {
        vm.prank(multisig);
        governor.pauseHook();
        assertTrue(hook.paused());
        vm.prank(multisig);
        governor.unpauseHook();
        assertFalse(hook.paused());
    }

    // -----------------------------------------------------------------
    // emergency-pause guardian
    // -----------------------------------------------------------------

    function test_setGuardian_ownerOnly_emitsAndStores() public {
        address guardian = makeAddr("guardian");
        vm.expectEmit(true, true, false, false, address(governor));
        emit WoolFiGovernor.GuardianSet(address(0), guardian);
        vm.prank(multisig);
        governor.setGuardian(guardian);
        assertEq(governor.guardian(), guardian);
    }

    function testRevert_setGuardian_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.setGuardian(stranger);
    }

    function test_guardian_canPauseOnly() public {
        address guardian = makeAddr("guardian");
        vm.prank(multisig);
        governor.setGuardian(guardian);

        vm.prank(guardian);
        governor.pauseHook();
        assertTrue(hook.paused());

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        governor.unpauseHook();

        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        governor.authorizePool(poolKey, _params());
    }

    function test_guardian_clearedCannotPause() public {
        address guardian = makeAddr("guardian");
        vm.startPrank(multisig);
        governor.setGuardian(guardian);
        governor.setGuardian(address(0));
        vm.stopPrank();

        vm.prank(guardian);
        vm.expectRevert(WoolFiGovernor.NotOwnerOrGuardian.selector);
        governor.pauseHook();
        assertFalse(hook.paused());
    }

    /// @notice Governance clears a structural break end-to-end (spec §3.5: only governance can).
    function test_resolveStructuralBreak_throughGovernor() public {
        vm.prank(multisig);
        governor.authorizePool(poolKey, _params());
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
            }),
            ZERO_BYTES
        );

        oracle0.setPrice(1.2e18); // drift beyond the hard threshold
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertTrue(hook.poolConfig(poolId).structuralBreak);

        vm.prank(multisig);
        governor.resolveStructuralBreak(poolKey);
        assertFalse(hook.poolConfig(poolId).structuralBreak);
    }

    // -----------------------------------------------------------------
    // access control
    // -----------------------------------------------------------------

    function testRevert_authorizePool_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.authorizePool(poolKey, _params());
    }

    function testRevert_pauseHook_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(WoolFiGovernor.NotOwnerOrGuardian.selector);
        governor.pauseHook();
    }

    /// @notice After handing the role to the governor, the old bootstrap governor can no longer
    ///         control the hook directly.
    function testRevert_directHookCall_afterHandoff() public {
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        hook.setPaused(true); // called by this contract (the old bootstrap governor)
    }

    // -----------------------------------------------------------------
    // role handoff (v2 migration path)
    // -----------------------------------------------------------------

    function test_proposeHookGovernor_handsOffRoleAfterAccept() public {
        address newGov = makeAddr("onchainGovernor");
        vm.prank(multisig);
        governor.proposeHookGovernor(newGov);
        // Proposal alone changes nothing; the governor contract still controls the hook.
        assertEq(hook.governor(), address(governor));
        assertEq(hook.pendingGovernor(), newGov);
        vm.prank(multisig);
        governor.pauseHook();
        vm.prank(multisig);
        governor.unpauseHook();

        vm.prank(newGov);
        hook.acceptGovernor();
        assertEq(hook.governor(), newGov);
        assertEq(hook.pendingGovernor(), address(0));

        // the governor contract no longer controls the hook
        vm.prank(multisig);
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        governor.pauseHook();
    }

    function testRevert_proposeHookGovernor_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.proposeHookGovernor(stranger);
    }

    function testRevert_acceptHookGovernor_notOwner() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.acceptHookGovernor();
    }

    // -----------------------------------------------------------------
    // Ownable2Step on the governor contract itself
    // -----------------------------------------------------------------

    function test_transferOwnership_requiresAccept() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(multisig);
        governor.transferOwnership(newOwner);
        // Still owned by multisig until the pending owner accepts.
        assertEq(governor.owner(), multisig);
        assertEq(governor.pendingOwner(), newOwner);
        vm.prank(multisig);
        governor.pauseHook(); // multisig retains control
        vm.prank(multisig);
        governor.unpauseHook();

        vm.prank(newOwner);
        governor.acceptOwnership();
        assertEq(governor.owner(), newOwner);
        assertEq(governor.pendingOwner(), address(0));
    }

    function testRevert_acceptOwnership_notPending() public {
        vm.prank(multisig);
        governor.transferOwnership(makeAddr("newOwner"));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        governor.acceptOwnership();
    }
}
