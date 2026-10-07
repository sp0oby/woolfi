// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {STRAND} from "../../src/STRAND.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {WoolFiBreakHandler} from "./WoolFiBreakHandler.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Stateful invariants for the two-phase structural break, the all-modes single-swap
///         break guard, and PM fee-split conservation. The PM is wired on the hook so fees realize
///         in afterSwap, the pool has a 15-minute post-open stabilization window and a 300s skew
///         limit so every non-break swap mode is exercised.
contract WoolFiBreakInvariantsTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiUnderwritingVault vault;
    STRAND strand;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    WoolFiBreakHandler handler;
    PoolKey poolKey;
    address treasury = makeAddr("treasury");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x6666) << 144));
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
        hook.authorizePoolV2(
            poolKey,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: oracle0,
                    oracle1: oracle1,
                    marketHours: marketHours,
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 900, maxOracleSkew: 300})
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        pm = new WoolFiPositionManager(manager, address(this));
        hook.setPositionManager(address(pm));
        strand = new STRAND(address(this));
        vault = new WoolFiUnderwritingVault(
            address(strand),
            address(hook),
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            makeAddr("rebalancer"),
            1_000_000e18
        );
        hook.setVault(poolKey, address(vault), 2000);
        hook.setBreakConfirmSeconds(poolKey, 1 hours);
        pm.setFeeConfig(poolKey, address(vault), 2000, treasury, 1000);

        // Skip the opening stabilization window so the bootstrap mint is allowed.
        skip(901);

        handler = new WoolFiBreakHandler(
            hook, pm, vault, strand, oracle0, oracle1, marketHours, swapRouter, poolKey, address(this), treasury
        );
        _fund();

        address lp = handler.actors(0);
        vm.prank(lp);
        pm.mint(poolKey, 1e21, 1e21, lp);
        address staker = handler.actors(1);
        vm.prank(staker);
        vault.stake(1_000e18);
        handler.sync();

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](19);
        selectors[0] = WoolFiBreakHandler.mint.selector;
        selectors[1] = WoolFiBreakHandler.burn.selector;
        selectors[2] = WoolFiBreakHandler.swap.selector;
        selectors[3] = WoolFiBreakHandler.swap.selector; // weight swaps x3: they drive the guard
        selectors[4] = WoolFiBreakHandler.swap.selector;
        selectors[5] = WoolFiBreakHandler.checkBreak.selector;
        selectors[6] = WoolFiBreakHandler.confirmBreak.selector;
        selectors[7] = WoolFiBreakHandler.resolveBreak.selector;
        selectors[8] = WoolFiBreakHandler.stake.selector;
        selectors[9] = WoolFiBreakHandler.requestUnstake.selector;
        selectors[10] = WoolFiBreakHandler.unstake.selector;
        selectors[11] = WoolFiBreakHandler.moveOracle.selector;
        selectors[12] = WoolFiBreakHandler.toggleMarket.selector;
        selectors[13] = WoolFiBreakHandler.warp.selector;
        selectors[14] = WoolFiBreakHandler.skewOracles.selector;
        // Extra weight on the break lifecycle so detection, confirmation and drawdown happen often.
        selectors[15] = WoolFiBreakHandler.moveOracle.selector;
        selectors[16] = WoolFiBreakHandler.checkBreak.selector;
        selectors[17] = WoolFiBreakHandler.confirmBreak.selector;
        selectors[18] = WoolFiBreakHandler.warp.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function _fund() internal {
        for (uint256 i; i < 3; i++) {
            address a = handler.actors(i);
            IERC20(Currency.unwrap(currency0)).transfer(a, 1e24);
            IERC20(Currency.unwrap(currency1)).transfer(a, 1e24);
            strand.mint(a, 1e24);
            vm.startPrank(a);
            IERC20(Currency.unwrap(currency0)).approve(address(pm), type(uint256).max);
            IERC20(Currency.unwrap(currency1)).approve(address(pm), type(uint256).max);
            strand.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        IERC20(Currency.unwrap(currency0)).transfer(address(handler), 1e24);
        IERC20(Currency.unwrap(currency1)).transfer(address(handler), 1e24);
        vm.startPrank(address(handler));
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// (a) No successful single swap takes a non-broken pool from inside to beyond the hard
    ///     threshold while moving away from fair, in any mode.
    function invariant_singleSwapNeverBreaksPool() public view {
        assertEq(handler.guardViolations(), 0, "a swap alone crossed the hard threshold");
    }

    /// (b) At most one drawdown per break episode.
    function invariant_atMostOneDrawdownPerEpisode() public view {
        assertLe(handler.maxDrawdownsPerEpisode(), 1, "vault drawn down twice in one break");
    }

    /// (c) Drawdowns only come from confirmation, after the window, with fresh drift still broken.
    function invariant_drawdownOnlyViaTimelyConfirmation() public view {
        assertEq(handler.drawdownOutsideConfirm(), 0, "drawdown outside confirmStructuralBreak");
        assertEq(handler.drawdownTooEarly(), 0, "drawdown before the confirmation window");
        assertEq(handler.drawdownWithoutFreshBreak(), 0, "drawdown with fresh drift back inside");
    }

    /// (d) The vault's accounted backing never exceeds the staking tokens it holds; no shares
    ///     means no backing.
    function invariant_vaultBackingSolvent() public view {
        assertLe(vault.totalStaked(), strand.balanceOf(address(vault)), "vault insolvent");
        if (vault.totalShares() == 0) assertEq(vault.totalStaked(), 0, "backing without shares");
    }

    /// (e) Every realization splits exactly vaultBps / treasuryBps / remainder, and the PM always
    ///     holds enough of each token to pay every LP's pending fees.
    function invariant_feeRoutingConserved() public view {
        assertEq(handler.feeSplitViolations(), 0, "fee split mismatch");
        (uint256 owed0, uint256 owed1) = handler.pendingFeesTotal();
        assertLe(owed0, IERC20(Currency.unwrap(currency0)).balanceOf(address(pm)), "PM short token0 fees");
        assertLe(owed1, IERC20(Currency.unwrap(currency1)).balanceOf(address(pm)), "PM short token1 fees");
    }

    /// A confirmed break is always a broken pool, and a broken pool always has a recovery target.
    function invariant_breakStateConsistent() public view {
        (bool broken, bool confirmed, uint256 detectedAt,) = hook.breakStatus(poolKey);
        WoolFiHook.WoolFiConfig memory c = hook.poolConfig(poolKey.toId());
        if (confirmed) assertTrue(broken, "confirmed but not broken");
        if (broken) {
            assertGt(c.cachedFairPriceWad, 0, "broken without target");
            assertGt(detectedAt, 0, "broken without detection time");
        } else {
            assertEq(c.cachedFairPriceWad, 0, "target without break");
            assertEq(detectedAt, 0, "detection time without break");
        }
    }

    /// @dev Non-vacuity check: the handler's own actions can reach detection, confirmation and a
    ///      single drawdown, so the drawdown invariants above are not trivially satisfied.
    function test_handlerReachesConfirmedDrawdown() public {
        uint256 stakedBefore = vault.totalStaked();
        handler.moveOracle(type(uint256).max); // bound -> 1.6e18, drift far past 15%
        handler.checkBreak();
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertTrue(broken, "oracle jump flags a break");
        handler.confirmBreak(0); // even seed: warp to the window boundary, then confirm
        (, bool confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(confirmed, "break confirmed");
        assertLt(vault.totalStaked(), stakedBefore, "vault drawn down");
        assertEq(handler.drawdownsObserved(), 1);
        handler.confirmBreak(0);
        assertEq(handler.drawdownsObserved(), 1, "second confirm is a no-op");
        assertEq(handler.drawdownOutsideConfirm(), 0);
    }

    /// @dev Run-log signal that the suite is not vacuous: breaks, guard reverts and drawdowns
    ///      must actually occur. Visible with -vv.
    function afterInvariant() external view {
        console2.log("episodes", handler.episodes());
        console2.log("guardReverts", handler.guardRevertsObserved());
        console2.log("drawdowns", handler.drawdownsObserved());
        console2.log("confirmsAttempted", handler.confirmsAttempted());
    }
}
