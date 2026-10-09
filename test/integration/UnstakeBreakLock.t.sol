// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {STRAND} from "../../src/STRAND.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

/// @notice A staker cannot complete an unstake while their vault's pool has a detected but
///         unconfirmed structural break. With a 2-day cooldown, a break flagged before a long market
///         weekend could otherwise be dodged before it confirms.
contract UnstakeBreakLockTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    WoolFiUnderwritingVault vault;
    PoolKey poolKey;
    PoolId poolId;

    uint32 constant STABILIZATION = 900;

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
        poolId = poolKey.toId();
        hook.authorizePool(poolKey, _params(marketHours));
        manager.initialize(poolKey, SQRT_PRICE_1_1);
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
            }),
            ZERO_BYTES
        );

        STRAND strand = new STRAND(address(this));
        vault = new WoolFiUnderwritingVault(
            address(strand),
            address(hook),
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            makeAddr("rebalancer"),
            1_000e18
        );
        strand.mint(address(this), 1000e18);
        strand.approve(address(vault), type(uint256).max);
        vault.stake(1000e18);
        hook.setVault(poolKey, address(vault), 2000);

        // Session open for a long time, so stabilization is not active at the start of each test.
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

    function _flagBreak() internal {
        oracle0.setPrice(1.2e18);
        hook.checkStructuralBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertTrue(broken, "break flagged");
    }

    /// @dev Close the market, sit out a weekend, reopen. Returns the new session start.
    function _weekendGap() internal returns (uint256 sessionStart) {
        marketHours.setOpen(false);
        vm.warp(block.timestamp + 3 days);
        marketHours.setOpen(true);
        sessionStart = block.timestamp;
    }

    // ------------------------------------------------------------------
    // Hook view
    // ------------------------------------------------------------------

    function test_view_unknownVaultAndZeroReadFalse() public view {
        assertFalse(hook.isBreakPendingForVault(address(0)));
        assertFalse(hook.isBreakPendingForVault(address(0xBEEF)));
        assertFalse(hook.isBreakPendingForVault(address(vault)), "no break yet");
    }

    function test_view_trueWhileDetected_falseAfterConfirm() public {
        _flagBreak();
        assertTrue(hook.isBreakPendingForVault(address(vault)));
        (,,, uint256 readyAt) = hook.breakStatus(poolKey);
        vm.warp(readyAt);
        hook.confirmStructuralBreak(poolKey);
        assertFalse(hook.isBreakPendingForVault(address(vault)), "confirmed: drawdown done");
    }

    function test_view_falseAfterConfirmClearsRecoveredBreak() public {
        _flagBreak();
        oracle0.setPrice(1e18);
        (,,, uint256 readyAt) = hook.breakStatus(poolKey);
        vm.warp(readyAt);
        hook.confirmStructuralBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken);
        assertFalse(hook.isBreakPendingForVault(address(vault)));
        assertEq(vault.totalStaked(), 1000e18, "no drawdown");
    }

    function test_view_falseAfterGovernorResolve() public {
        _flagBreak();
        hook.resolveStructuralBreak(poolKey);
        assertFalse(hook.isBreakPendingForVault(address(vault)));
    }

    function test_view_followsVaultRewiring() public {
        address newVault = address(
            new WoolFiUnderwritingVault(
                vault.stakingToken(), address(hook), vault.token0(), vault.token1(), makeAddr("rebalancer"), 1_000e18
            )
        );
        hook.setVault(poolKey, newVault, 2000);
        _flagBreak();
        assertFalse(hook.isBreakPendingForVault(address(vault)), "old vault no longer wired");
        assertTrue(hook.isBreakPendingForVault(newVault));

        hook.setVault(poolKey, address(0), 0);
        assertFalse(hook.isBreakPendingForVault(newVault), "unwired");
    }

    function test_view_falseAfterConfirmEvenIfDrawdownFailed() public {
        // A vault bound to a different hook rejects the drawdown (NotHook): confirm emits
        // DrawdownFailed. Stakers must not then be trapped.
        WoolFiUnderwritingVault foreign = new WoolFiUnderwritingVault(
            vault.stakingToken(), address(oracle0), vault.token0(), vault.token1(), makeAddr("rebalancer"), 1_000e18
        );
        hook.setVault(poolKey, address(foreign), 2000);
        _flagBreak();
        assertTrue(hook.isBreakPendingForVault(address(foreign)));
        (,,, uint256 readyAt) = hook.breakStatus(poolKey);
        vm.warp(readyAt);
        hook.confirmStructuralBreak(poolKey);
        assertFalse(hook.isBreakPendingForVault(address(foreign)));
    }

    // ------------------------------------------------------------------
    // Vault unstake against the real hook
    // ------------------------------------------------------------------

    /// @dev Break flagged late on a Friday before a 3-day weekend. The 2-day cooldown elapses on
    ///      Sunday, but the break cannot confirm until after Tuesday's open: unstake stays blocked
    ///      until the drawdown lands, and the staker takes the haircut.
    function test_unstake_holidayWeekend_cannotDodgeDrawdown() public {
        _flagBreak();
        vault.requestUnstake(1000e18);

        marketHours.setOpen(false);
        vm.warp(block.timestamp + 2 days); // Sunday: cooldown over
        vm.expectRevert(WoolFiUnderwritingVault.BreakPending.selector);
        vault.unstake();

        vm.warp(block.timestamp + 1 days); // Monday holiday, still closed
        vm.expectRevert(WoolFiUnderwritingVault.BreakPending.selector);
        vault.unstake();

        vm.warp(block.timestamp + 1 days); // Tuesday open
        marketHours.setOpen(true);
        uint256 sessionStart = block.timestamp;
        vm.expectRevert(WoolFiUnderwritingVault.BreakPending.selector);
        vault.unstake();

        vm.warp(sessionStart + hook.DEFAULT_BREAK_CONFIRM_SECONDS());
        vm.expectRevert(WoolFiUnderwritingVault.BreakPending.selector);
        vault.unstake();
        hook.confirmStructuralBreak(poolKey);

        assertEq(vault.unstake(), 800e18, "took the 20% haircut");
    }

    /// The hook check fails open, so a caller might try to starve the staticcall of gas to make it
    /// "fail" and skip the block. EIP-150 keeps 1/64 of the gas back, which is far too little to
    /// finish the unstake afterwards, so every gas limit must either revert or hit BreakPending.
    function test_unstake_gasStarvedHookCheckCannotBypassPendingBreak() public {
        _flagBreak();
        vault.requestUnstake(1000e18);
        vm.warp(block.timestamp + vault.COOLDOWN());
        uint256 sharesBefore = vault.sharesOf(address(this));

        for (uint256 g = 21_000; g < 400_000; g += 250) {
            (bool ok,) = address(vault).call{gas: g}(abi.encodeCall(WoolFiUnderwritingVault.unstake, ()));
            assertFalse(ok, "unstake succeeded during a pending break");
        }
        assertEq(vault.sharesOf(address(this)), sharesBefore, "shares unchanged");
        assertTrue(hook.isBreakPendingForVault(address(vault)));
    }

    function test_unstake_afterBreakClearsWithoutDrawdown_paysInFull() public {
        _flagBreak();
        vault.requestUnstake(1000e18);
        vm.warp(block.timestamp + vault.COOLDOWN());
        vm.expectRevert(WoolFiUnderwritingVault.BreakPending.selector);
        vault.unstake();

        oracle0.setPrice(1e18);
        marketHours.setSessionStart(block.timestamp - 1 days);
        hook.confirmStructuralBreak(poolKey);
        assertEq(vault.unstake(), 1000e18);
    }

    function test_unstake_unaffectedWithoutBreak() public {
        vault.requestUnstake(500e18);
        vm.warp(block.timestamp + vault.COOLDOWN());
        assertEq(vault.unstake(), 500e18);
    }
}
