// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract FeeOnTransferToken is ERC20 {
    constructor() ERC20("Fee Token", "FEE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = amount / 100;
            super._update(from, address(0), fee);
            amount -= fee;
        }
        super._update(from, to, amount);
    }
}

/// @notice Tests for the underwriting vault. This test contract plays the role of the hook (so it
///         can call `drawdown`) and the fee router (so it can call `depositRewards`).
contract WoolFiUnderwritingVaultTest is Test {
    MockERC20 stakingToken;
    MockERC20 token0;
    MockERC20 token1;
    WoolFiUnderwritingVault vault;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address rebalancer = makeAddr("rebalancer");

    function setUp() public {
        stakingToken = new MockERC20("External Staking Token", "EXT", 18);
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        // this contract is both the hook (drawdown caller) and the reward funder
        vault = new WoolFiUnderwritingVault(
            address(stakingToken), address(this), address(token0), address(token1), rebalancer, 1_000e18
        );

        stakingToken.mint(alice, 1_000e18);
        stakingToken.mint(bob, 1_000e18);
        token0.mint(address(this), 1_000e18);
        token1.mint(address(this), 1_000e18);
        token0.approve(address(vault), type(uint256).max);
        token1.approve(address(vault), type(uint256).max);

        vm.prank(alice);
        stakingToken.approve(address(vault), type(uint256).max);
        vm.prank(bob);
        stakingToken.approve(address(vault), type(uint256).max);
    }

    function _stake(address who, uint256 amount) internal {
        vm.prank(who);
        vault.stake(amount);
    }

    // -----------------------------------------------------------------
    // staking
    // -----------------------------------------------------------------

    function test_stake_accounting() public {
        _stake(alice, 100e18);
        assertEq(vault.sharesOf(alice), 100e18);
        assertEq(vault.totalShares(), 100e18);
        assertEq(vault.totalStaked(), 100e18);
        assertEq(vault.stakingToken(), address(stakingToken));
        assertEq(stakingToken.balanceOf(address(vault)), 100e18);
    }

    function testRevert_stake_zero() public {
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.ZeroAmount.selector);
        vault.stake(0);
    }

    function test_stake_acceptsUpToCap() public {
        _stake(alice, 600e18);
        _stake(bob, 400e18);
        assertEq(vault.totalStaked(), vault.maxTotalStaked());
    }

    function testRevert_stake_exceedsCap() public {
        _stake(alice, 900e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WoolFiUnderwritingVault.CapExceeded.selector, 1_001e18, 1_000e18));
        vault.stake(101e18);
    }

    function testRevert_stake_rejectsFeeOnTransferToken() public {
        FeeOnTransferToken feeToken = new FeeOnTransferToken();
        WoolFiUnderwritingVault feeVault = new WoolFiUnderwritingVault(
            address(feeToken), address(this), address(token0), address(token1), rebalancer, 1_000e18
        );
        feeToken.mint(alice, 100e18);
        vm.startPrank(alice);
        feeToken.approve(address(feeVault), 100e18);
        vm.expectRevert(
            abi.encodeWithSelector(WoolFiUnderwritingVault.UnsupportedTransferBehavior.selector, 100e18, 99e18)
        );
        feeVault.stake(100e18);
        vm.stopPrank();
    }

    function testRevert_constructor_zeroAddress() public {
        vm.expectRevert(WoolFiUnderwritingVault.ZeroAddress.selector);
        new WoolFiUnderwritingVault(address(0), address(this), address(token0), address(token1), rebalancer, 1_000e18);

        vm.expectRevert(WoolFiUnderwritingVault.ZeroAddress.selector);
        new WoolFiUnderwritingVault(
            address(stakingToken), address(this), address(token0), address(token1), address(0), 1_000e18
        );
    }

    function testRevert_constructor_dependencyWithoutCode() public {
        address eoa = makeAddr("notAContract");
        vm.expectRevert(abi.encodeWithSelector(WoolFiUnderwritingVault.NotContract.selector, eoa));
        new WoolFiUnderwritingVault(eoa, address(this), address(token0), address(token1), rebalancer, 1_000e18);

        vm.expectRevert(abi.encodeWithSelector(WoolFiUnderwritingVault.NotContract.selector, eoa));
        new WoolFiUnderwritingVault(address(stakingToken), eoa, address(token0), address(token1), rebalancer, 1_000e18);
    }

    // -----------------------------------------------------------------
    // fee rewards
    // -----------------------------------------------------------------

    function test_rewards_distributedProRata() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);
        vault.depositRewards(100e18, 40e18); // 50/50 split between two equal stakers

        (uint256 ap0, uint256 ap1) = vault.pendingRewards(alice);
        assertEq(ap0, 50e18);
        assertEq(ap1, 20e18);

        uint256 a0 = token0.balanceOf(alice);
        vm.prank(alice);
        (uint256 c0, uint256 c1) = vault.claim();
        assertEq(c0, 50e18);
        assertEq(c1, 20e18);
        assertEq(token0.balanceOf(alice) - a0, 50e18);
    }

    function test_rewards_token1Only() public {
        _stake(alice, 100e18);
        vault.depositRewards(0, 30e18); // fees can arrive in a single token
        (uint256 p0, uint256 p1) = vault.pendingRewards(alice);
        assertEq(p0, 0);
        assertEq(p1, 30e18);
    }

    function testRevert_depositRewards_noStakers() public {
        vm.expectRevert(WoolFiUnderwritingVault.NoStakers.selector);
        vault.depositRewards(1e18, 0);
    }

    /// @notice A staker who joins after fees accrued does not dilute earlier stakers' rewards.
    function test_rewards_lateStakerNoDilution() public {
        _stake(alice, 100e18);
        vault.depositRewards(100e18, 0); // all to alice
        _stake(bob, 100e18); // bob joins after

        (uint256 ap0,) = vault.pendingRewards(alice);
        (uint256 bp0,) = vault.pendingRewards(bob);
        assertEq(ap0, 100e18);
        assertEq(bp0, 0);
    }

    // -----------------------------------------------------------------
    // drawdown haircut
    // -----------------------------------------------------------------

    function test_drawdown_proRataHaircut() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);

        uint256 seized = vault.drawdown(2500); // 25% of 200 = 50
        assertEq(seized, 50e18);
        assertEq(vault.totalStaked(), 150e18);
        assertEq(stakingToken.balanceOf(rebalancer), 50e18);

        // alice redeems: 100 shares * 150 / 200 = 75 tokens (took her pro-rata haircut)
        vm.prank(alice);
        vault.requestUnstake(100e18);
        skip(vault.COOLDOWN());
        uint256 a = stakingToken.balanceOf(alice);
        vm.prank(alice);
        uint256 out = vault.unstake();
        assertEq(out, 75e18);
        assertEq(stakingToken.balanceOf(alice) - a, 75e18);
    }

    function testRevert_drawdown_notHook() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.NotHook.selector);
        vault.drawdown(1000);
    }

    function testRevert_drawdown_bpsTooHigh() public {
        _stake(alice, 100e18);
        vm.expectRevert(WoolFiUnderwritingVault.InvalidBps.selector);
        vault.drawdown(10_001);
    }

    /// @notice A full drawdown seizes exactly the staked balance and never more.
    function test_drawdown_neverOverBalance() public {
        _stake(alice, 100e18);
        _stake(bob, 60e18);
        uint256 seized = vault.drawdown(10_000); // 100%
        assertEq(seized, 160e18);
        assertEq(vault.totalStaked(), 0);
        assertEq(stakingToken.balanceOf(address(vault)), 0);
        // a further drawdown seizes nothing
        assertEq(vault.drawdown(5000), 0);
    }

    // -----------------------------------------------------------------
    // cooldown
    // -----------------------------------------------------------------

    function test_cooldown_enforced() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vault.requestUnstake(100e18);

        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.CooldownActive.selector);
        vault.unstake();

        skip(vault.COOLDOWN());
        vm.prank(alice);
        assertEq(vault.unstake(), 100e18);
    }

    /// @notice A staker mid-cooldown still absorbs a drawdown — they cannot dodge the haircut by exiting.
    function test_pendingUnstaker_stillTakesHaircut() public {
        _stake(alice, 100e18);
        _stake(bob, 100e18);

        vm.prank(alice);
        vault.requestUnstake(100e18); // alice queues her exit

        vault.drawdown(2500); // break happens during her cooldown

        skip(vault.COOLDOWN());
        vm.prank(alice);
        assertEq(vault.unstake(), 75e18); // still took the 25% haircut
    }

    function testRevert_unstake_noPending() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.NoPendingUnstake.selector);
        vault.unstake();
    }

    function testRevert_requestUnstake_alreadyPending() public {
        _stake(alice, 100e18);
        vm.startPrank(alice);
        vault.requestUnstake(50e18);
        vm.expectRevert(WoolFiUnderwritingVault.UnstakeAlreadyPending.selector);
        vault.requestUnstake(10e18);
        vm.stopPrank();
    }

    function testRevert_requestUnstake_tooMany() public {
        _stake(alice, 100e18);
        vm.prank(alice);
        vm.expectRevert(WoolFiUnderwritingVault.InsufficientShares.selector);
        vault.requestUnstake(101e18);
    }
}
