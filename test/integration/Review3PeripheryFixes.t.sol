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
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiSwapRouter} from "../../src/WoolFiSwapRouter.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {UrufuFeeRebateDistributor} from "../../src/UrufuFeeRebateDistributor.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {MockUrufuNft} from "./WoolFiSwapRouter.t.sol";

/// @notice Review 3 regression tests for the periphery: the self-LP rebate wash (P-1), PM reward
///         precision for 6-decimal-sized fees (V-3, PM side), and the deadline / min-output
///         overloads on the router and the position manager (F8).
contract Review3PeripheryFixesTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiSwapRouter router;
    UrufuFeeRebateDistributor dist;
    WoolFiPositionManager pm;
    MockUrufuNft nft;

    address protocol = address(0xBEEF);
    address treasury = makeAddr("treasury");

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
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hookAddr));
        hook.authorizePool(
            key,
            WoolFiHook.AuthParams({
                oracle0: new MockPriceOracle(1e18),
                oracle1: new MockPriceOracle(1e18),
                marketHours: new MockMarketHours(true),
                kScaled: 40_000,
                baseFeeBps: 30,
                toleranceBps: 500,
                hardThresholdBps: 1500
            })
        );
        manager.initialize(key, SQRT_PRICE_1_1);

        pm = new WoolFiPositionManager(manager, address(this));
        nft = new MockUrufuNft();
        dist = new UrufuFeeRebateDistributor(hook, address(nft), protocol);
        router = new WoolFiSwapRouter(manager, dist);
        vm.startPrank(protocol);
        dist.setRouter(address(router));
        dist.setWeeklyCap(Currency.unwrap(currency0), 1e18);
        dist.setWeeklyCap(Currency.unwrap(currency1), 1e18);
        vm.stopPrank();
        _t0().transfer(protocol, 1e18);
        _t1().transfer(protocol, 1e18);
        vm.startPrank(protocol);
        _t0().approve(address(dist), 1e18);
        _t1().approve(address(dist), 1e18);
        dist.fund(Currency.unwrap(currency0), 1e18);
        dist.fund(Currency.unwrap(currency1), 1e18);
        vm.stopPrank();

        nft.mint(address(this), 1); // the attacker holds one Urufu Gemu
        _t0().approve(address(router), type(uint256).max);
        _t1().approve(address(router), type(uint256).max);
        _t0().approve(address(pm), type(uint256).max);
        _t1().approve(address(pm), type(uint256).max);
    }

    function _t0() internal view returns (IERC20Minimal) {
        return IERC20Minimal(Currency.unwrap(currency0));
    }

    function _t1() internal view returns (IERC20Minimal) {
        return IERC20Minimal(Currency.unwrap(currency1));
    }

    function _bal() internal view returns (uint256) {
        return _t0().balanceOf(address(this)) + _t1().balanceOf(address(this));
    }

    function _wash(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            uint256 out = router.swap(key, true, 1e18, 0, address(this), ZERO_BYTES);
            router.swap(key, false, out, 0, address(this), ZERO_BYTES);
        }
    }

    function _claimAll() internal returns (uint256 r0, uint256 r1) {
        r0 = dist.claimable(address(this), Currency.unwrap(currency0));
        r1 = dist.claimable(address(this), Currency.unwrap(currency1));
        if (r0 > 0) dist.claim(Currency.unwrap(currency0), address(this));
        if (r1 > 0) dist.claim(Currency.unwrap(currency1), address(this));
    }

    // ------------------------------------------------------------------
    // P-1: self-LP rebate wash
    // ------------------------------------------------------------------

    /// The original PoC: no PM wired, the attacker is the sole (direct) LP and there is no protocol
    /// cut. The rebate rate is now capped at the treasury cut (zero), so the wash earns nothing.
    function test_P1_selfLpWash_noProtocolCut_earnsNoRebate() public {
        uint256 start = _bal();
        IPoolManager.ModifyLiquidityParams memory add = IPoolManager.ModifyLiquidityParams({
            tickLower: -887220, tickUpper: 887220, liquidityDelta: 100e18, salt: 0
        });
        modifyLiquidityRouter.modifyLiquidity(key, add, ZERO_BYTES);
        _wash(400);
        add.liquidityDelta = -100e18;
        modifyLiquidityRouter.modifyLiquidity(key, add, ZERO_BYTES);

        (uint256 r0, uint256 r1) = _claimAll();
        assertEq(r0 + r1, 0, "no rebate without a protocol cut");
        assertLe(_bal(), start, "wash trading is not profitable");
    }

    /// Production wiring: the attacker is the PM's only LP and the pool routes 15% of fees to the
    /// treasury (the new default). The rebate is at most the treasury cut, so LP fees + rebate never
    /// exceed the fees the attacker paid.
    function test_P1_selfLpWash_throughPm_notProfitable() public {
        pm.setFeeConfig(key, address(0), 0, treasury, 1500);
        hook.setPositionManager(address(pm));

        uint256 start = _bal();
        uint128 shares = pm.mint(key, 100e18, 100e18, address(this));
        _wash(400);
        pm.burn(key, shares, address(this));
        (uint256 r0, uint256 r1) = _claimAll();
        uint256 end = _bal();

        uint256 treasuryGot = _t0().balanceOf(treasury) + _t1().balanceOf(treasury);
        assertGt(r0 + r1, 0, "the advertised 15% rebate still accrues");
        assertLe(r0 + r1, treasuryGot + 800, "rebates never exceed the treasury cut (1 wei/swap rounding)");
        assertLe(end, start, "wash trading is not profitable");
    }

    /// A pool configured with a smaller treasury cut pays a proportionally smaller rebate.
    function test_P1_rebateRateFollowsTreasuryCut() public {
        pm.setFeeConfig(key, address(0), 0, treasury, 1000);
        hook.setPositionManager(address(pm));
        pm.mint(key, 100e18, 100e18, address(this));

        assertEq(dist.rebateBpsFor(key.toId()), 1000);
        router.swap(key, true, 1e18, 0, address(this), ZERO_BYTES);
        // 1e18 * 30 bps * 10% (not 15%)
        assertEq(dist.claimable(address(this), Currency.unwrap(currency0)), 3e14);
    }

    // ------------------------------------------------------------------
    // V-3 (PM side): 6-decimal-sized fees against a liquidity-sized share supply
    // ------------------------------------------------------------------

    /// With ~1e30 shares, a $1,000 USDG-sized swap (1e9 raw units, 30 bps fee = 3e6) used to add
    /// `3e6 * 1e18 / 1e30 = 0` to the accumulator: the fee was realized into the PM and lost to LPs.
    function test_V3_pmRewardPrecision_largeSupply() public {
        hook.setPositionManager(address(pm));
        uint128 shares = pm.mint(key, 1e30, 1e30, address(this));
        assertGt(shares, 1e29, "liquidity-sized supply");

        uint256 pmBefore = _t0().balanceOf(address(pm));
        router.swap(key, true, 1e9, 0, address(this), ZERO_BYTES);
        uint256 realized = _t0().balanceOf(address(pm)) - pmBefore;
        assertGt(realized, 2.9e6, "fee realized into the PM");

        (uint256 fee0,) = pm.pendingFees(key, address(this));
        assertGt(fee0, 0, "fee no longer truncates to zero");
        assertLe(fee0, realized, "never more than realized");
        assertApproxEqAbs(fee0, realized, 1, "LP is owed the whole realized fee");

        uint256 before = _t0().balanceOf(address(this));
        (uint256 got0,) = pm.collectFees(key, address(this));
        assertEq(got0, fee0);
        assertEq(_t0().balanceOf(address(this)) - before, fee0);
    }

    // ------------------------------------------------------------------
    // F8: deadline / min-output overloads
    // ------------------------------------------------------------------

    function testRevert_router_swapPastDeadline() public {
        hook.setPositionManager(address(pm));
        pm.mint(key, 100e18, 100e18, address(this));
        vm.expectRevert(abi.encodeWithSelector(WoolFiSwapRouter.DeadlineExpired.selector, block.timestamp - 1));
        router.swap(key, true, 1e16, 0, address(this), ZERO_BYTES, block.timestamp - 1);
    }

    function test_router_swapWithDeadline_matchesSixArgSwap() public {
        hook.setPositionManager(address(pm));
        pm.mint(key, 100e18, 100e18, address(this));

        uint256 snap = vm.snapshotState();
        uint256 plain = router.swap(key, true, 1e16, 0, address(this), ZERO_BYTES);
        vm.revertToState(snap);

        uint256 before = _t1().balanceOf(address(this));
        uint256 out = router.swap(key, true, 1e16, plain, address(this), ZERO_BYTES, block.timestamp);
        assertEq(out, plain, "same output as the 6-argument swap");
        assertEq(_t1().balanceOf(address(this)) - before, out);
    }

    function testRevert_router_swapWithDeadline_slippage() public {
        hook.setPositionManager(address(pm));
        pm.mint(key, 100e18, 100e18, address(this));
        uint256 snap = vm.snapshotState();
        uint256 quote = router.swap(key, true, 1e16, 0, address(this), ZERO_BYTES);
        vm.revertToState(snap);
        vm.expectRevert(abi.encodeWithSelector(WoolFiSwapRouter.InsufficientOutput.selector, quote, quote + 1));
        router.swap(key, true, 1e16, quote + 1, address(this), ZERO_BYTES, block.timestamp);
    }

    function testRevert_pm_burnPastDeadline() public {
        hook.setPositionManager(address(pm));
        uint128 shares = pm.mint(key, 10e18, 10e18, address(this));
        vm.expectRevert(abi.encodeWithSelector(WoolFiPositionManager.DeadlineExpired.selector, block.timestamp - 1));
        pm.burn(key, shares, 0, 0, block.timestamp - 1, address(this));
    }

    function testRevert_pm_burnBelowMinimums() public {
        hook.setPositionManager(address(pm));
        uint128 shares = pm.mint(key, 10e18, 10e18, address(this));
        uint256 snap = vm.snapshotState();
        (uint256 a0, uint256 a1) = pm.burn(key, shares, address(this));
        vm.revertToState(snap);

        vm.expectRevert(abi.encodeWithSelector(WoolFiPositionManager.InsufficientOutput.selector, a0, a1));
        pm.burn(key, shares, a0 + 1, 0, block.timestamp, address(this));
        vm.expectRevert(abi.encodeWithSelector(WoolFiPositionManager.InsufficientOutput.selector, a0, a1));
        pm.burn(key, shares, 0, a1 + 1, block.timestamp, address(this));
    }

    function test_pm_burnWithBounds_matchesThreeArgBurn() public {
        hook.setPositionManager(address(pm));
        uint128 shares = pm.mint(key, 10e18, 10e18, address(this));
        uint256 snap = vm.snapshotState();
        (uint256 a0, uint256 a1) = pm.burn(key, shares, address(this));
        vm.revertToState(snap);

        address to = makeAddr("to");
        (uint256 b0, uint256 b1) = pm.burn(key, shares, a0, a1, block.timestamp, to);
        assertEq(b0, a0);
        assertEq(b1, a1);
        assertEq(_t0().balanceOf(to), a0);
        assertEq(_t1().balanceOf(to), a1);
        assertEq(pm.balanceOf(address(this), uint256(PoolId.unwrap(key.toId()))), 0);
        assertEq(pm.totalShares(uint256(PoolId.unwrap(key.toId()))), 0);
    }
}
