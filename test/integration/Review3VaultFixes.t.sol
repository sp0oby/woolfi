// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {DeployTimelock} from "../../script/DeployTimelock.s.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Review 3 regression tests for the underwriting vault: matured unstake requests expire
///         (V-1, vault side), a pending request can be replaced (V-4), and 6-decimal rewards no
///         longer truncate to zero (V-3).
contract Review3VaultFixesTest is Deployers {
    uint32 constant STABILIZATION = 900;

    WoolFiHook hook;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    WoolFiUnderwritingVault vault;
    MockERC20 uru;
    PoolKey poolKey;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address rebalancer = makeAddr("rebalancer");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x5555) << 144));
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(this)), hookAddr);
        hook = WoolFiHook(hookAddr);

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
        hook.authorizePool(poolKey, _params(marketHours));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
            }),
            ZERO_BYTES
        );

        uru = new MockERC20("URU", "URU", 18);
        vault = new WoolFiUnderwritingVault(
            address(uru), address(hook), Currency.unwrap(currency0), Currency.unwrap(currency1), rebalancer, 10_000e18
        );
        hook.setVault(poolKey, address(vault), 2000);

        _stake(vault, alice, 500e18);
        _stake(vault, bob, 500e18);

        vm.warp(10 days);
        marketHours.setSessionStart(block.timestamp - 1 days);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: STABILIZATION, maxOracleSkew: 0}));
    }

    function _params(IMarketHoursOracle mh) internal view returns (WoolFiHook.AuthParams memory) {
        return WoolFiHook.AuthParams({
            oracle0: oracle0,
            oracle1: oracle1,
            marketHours: mh,
            kScaled: 40_000,
            baseFeeBps: 30,
            toleranceBps: 500,
            hardThresholdBps: 1500
        });
    }

    function _stake(WoolFiUnderwritingVault v, address who, uint256 amt) internal {
        uru.mint(who, amt);
        vm.startPrank(who);
        uru.approve(address(v), type(uint256).max);
        v.stake(amt);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // V-1: a matured request is no longer a perpetual exit option
    // ------------------------------------------------------------------

    /// The review PoC: Alice requested once and sat on the matured request for 30 days, then exited
    /// at full value the moment a gap was visible but not yet flaggable. Now the request has expired,
    /// a fresh request restarts the cooldown, and the drawdown lands on both stakers.
    function test_V1_staleRequestCannotDodgeGap() public {
        vm.prank(alice);
        vault.requestUnstake(500e18);
        vm.warp(block.timestamp + 30 days);

        // Requested shares keep earning rewards.
        MockERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        vault.depositRewards(100e18, 0);
        (uint256 aliceFee,) = vault.pendingRewards(alice);
        assertEq(aliceFee, 50e18, "pending shares earn full rewards");

        // The matured request has expired: there is no standing exit option to hold.
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.UnstakeRequestExpired.selector);
        vault.unstake();

        // Weekend gap, then the open: nothing can be flagged yet (stabilization). The vault refuses
        // the stale request either way (the hook may also report the unflaggable gap as pending).
        marketHours.setOpen(false);
        vm.warp(block.timestamp + 2 days);
        oracle0.setPrice(1.2e18);
        marketHours.setOpen(true);
        marketHours.setSessionStart(block.timestamp);
        oracle0.setPrice(1.2e18);
        vm.prank(alice);
        vm.expectRevert();
        vault.unstake();

        // A fresh request restarts the full cooldown, which outlasts stabilization + confirmation.
        vm.prank(alice);
        vault.requestUnstake(500e18);
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.CooldownActive.selector);
        vault.unstake();

        vm.warp(block.timestamp + STABILIZATION);
        hook.checkStructuralBreak(poolKey);
        assertTrue(hook.isBreakPendingForVault(address(vault)));
        (,,, uint256 readyAt) = hook.breakStatus(poolKey);
        vm.warp(readyAt);
        oracle0.setPrice(1.2e18);
        hook.confirmStructuralBreak(poolKey);
        assertEq(uru.balanceOf(rebalancer), 200e18, "full 20% of both stakers seized");

        (uint256 releaseAt,) = vault.unstakeWindow(alice);
        vm.warp(releaseAt);
        vm.prank(alice);
        assertEq(vault.unstake(), 400e18, "alice took the haircut");
    }

    function test_V1_claimWindowBoundaries() public {
        vm.prank(alice);
        vault.requestUnstake(100e18);
        (uint256 releaseAt, uint256 expiresAt) = vault.unstakeWindow(alice);
        assertEq(releaseAt, block.timestamp + vault.COOLDOWN());
        assertEq(expiresAt, releaseAt + vault.UNSTAKE_CLAIM_WINDOW());
        assertEq(vault.UNSTAKE_CLAIM_WINDOW(), 1 days);

        uint256 snap = vm.snapshotState();
        vm.warp(expiresAt);
        vm.prank(alice);
        assertEq(vault.unstake(), 100e18, "last second of the window is claimable");
        vm.revertToState(snap);

        vm.warp(expiresAt + 1);
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.UnstakeRequestExpired.selector);
        vault.unstake();

        // An expired request is replaced by a new one.
        vm.prank(alice);
        vault.requestUnstake(100e18);
        vm.warp(block.timestamp + vault.COOLDOWN());
        vm.prank(alice);
        assertEq(vault.unstake(), 100e18);
        (releaseAt, expiresAt) = vault.unstakeWindow(alice);
        assertEq(releaseAt, 0);
        assertEq(expiresAt, 0);
    }

    // ------------------------------------------------------------------
    // V-4: a small pending request can be enlarged (replaced)
    // ------------------------------------------------------------------

    function test_V4_pendingRequestCanBeReplaced() public {
        vm.prank(alice);
        vault.requestUnstake(1e18);
        vm.warp(block.timestamp + 1 days);

        vm.prank(alice);
        vault.requestUnstake(500e18);
        (uint256 shares, uint256 releaseAt) = vault.pendingUnstake(alice);
        assertEq(shares, 500e18, "new amount applies");
        assertEq(releaseAt, block.timestamp + vault.COOLDOWN(), "cooldown restarts");

        // Replacing cannot shortcut the cooldown of the original request.
        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.CooldownActive.selector);
        vault.unstake();

        vm.warp(releaseAt);
        vm.prank(alice);
        assertEq(vault.unstake(), 500e18);
    }

    // ------------------------------------------------------------------
    // V-3: 6-decimal rewards no longer truncate to zero
    // ------------------------------------------------------------------

    /// The review PoC: 1,000 swaps of $1,000 USDG, each sending a $0.60 vault cut to a vault with
    /// 1,000,000 URU staked. With a 1e18 accumulator every deposit rounded to zero.
    function test_V3_usdgRewardsNotLost_1mUruStaked() public {
        MockERC20 usdg = new MockERC20("USDG", "USDG", 6);
        MockERC20 stock = new MockERC20("NVDA", "NVDA", 18);
        WoolFiUnderwritingVault v = new WoolFiUnderwritingVault(
            address(uru), address(hook), address(usdg), address(stock), rebalancer, 10_000_000e18
        );
        _stake(v, alice, 1_000_000e18);

        usdg.mint(address(this), 1_000 * 600_000);
        usdg.approve(address(v), type(uint256).max);
        for (uint256 i; i < 1000; ++i) {
            v.depositRewards(600_000, 0);
        }
        assertGt(v.accReward0(), 0);
        (uint256 claimable,) = v.pendingRewards(alice);
        assertEq(claimable, 600e6, "the sole staker can claim all $600");

        vm.prank(alice);
        (uint256 got,) = v.claim();
        assertEq(got, 600e6);
        assertEq(usdg.balanceOf(alice), 600e6);
    }

    /// A single $1,000 swap's cut against a 1B URU vault (1e27 shares) split between two stakers:
    /// paid pro-rata and never more than deposited.
    function test_V3_usdgRewardsProRata_1bUruStaked() public {
        MockERC20 usdg = new MockERC20("USDG", "USDG", 6);
        MockERC20 stock = new MockERC20("NVDA", "NVDA", 18);
        WoolFiUnderwritingVault v = new WoolFiUnderwritingVault(
            address(uru), address(hook), address(usdg), address(stock), rebalancer, 1_000_000_000e18
        );
        _stake(v, alice, 750_000_000e18);
        _stake(v, bob, 250_000_000e18);

        usdg.mint(address(this), 600_000);
        usdg.approve(address(v), type(uint256).max);
        v.depositRewards(600_000, 0);

        (uint256 a,) = v.pendingRewards(alice);
        (uint256 b,) = v.pendingRewards(bob);
        assertEq(a, 450_000);
        assertEq(b, 150_000);
        assertLe(a + b, usdg.balanceOf(address(v)));
    }

    // ------------------------------------------------------------------
    // F2 (fixed in the hook): a drawdown increase queued during a pending break cannot execute
    // against stakers the break has locked in.
    // ------------------------------------------------------------------

    function test_F2_queuedDrawdownIncreaseRefusedDuringPendingBreak() public {
        address safe = makeAddr("safe");
        TimelockController timelock = new DeployTimelock().deployTimelock(address(this), safe, 3 days, 0);
        WoolFiGovernor governor = new WoolFiGovernor(address(hook), address(timelock));
        hook.proposeGovernor(address(governor));
        vm.prank(address(timelock));
        governor.acceptHookGovernor();

        oracle0.setPrice(1.2e18);
        hook.checkStructuralBreak(poolKey);
        assertTrue(hook.isBreakPendingForVault(address(vault)));

        bytes memory data = abi.encodeCall(WoolFiGovernor.setVault, (poolKey, address(vault), 9999));
        vm.prank(safe);
        timelock.schedule(address(governor), 0, data, bytes32(0), bytes32(0), 3 days);
        vm.prank(alice);
        vault.requestUnstake(500e18);

        // Holiday weekend keeps the break pending past the timelock delay.
        marketHours.setOpen(false);
        vm.warp(block.timestamp + 3 days);
        assertTrue(hook.isBreakPendingForVault(address(vault)));
        vm.prank(safe);
        vm.expectRevert(WoolFiHook.BreakPendingForPool.selector);
        timelock.execute(address(governor), 0, data, bytes32(0), bytes32(0));
    }
}
