// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {RebalanceKeeper} from "../../src/RebalanceKeeper.sol";
import {STRAND} from "../../src/STRAND.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {HookMiner} from "../../script/lib/HookMiner.sol";

/// @notice Full end-to-end lifecycle of the WoolFi protocol in one scripted scenario. Walks every
///         mechanic in realistic sequence and asserts the state-combination invariants the focused
///         tests don't reach (e.g. fee routing after a drawdown, LP burn out of band, governance
///         handoff after extensive activity).
contract LifecycleTest is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    // ----- system contracts -----
    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiUnderwritingVault vault;
    WoolFiGovernor governor;
    RebalanceKeeper keeper;
    STRAND strand;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;

    // ----- pool -----
    PoolKey poolKey;
    PoolId poolId;
    uint256 shareId;

    // ----- actors -----
    address multisig = makeAddr("multisig");
    address rebalancer = makeAddr("rebalancer");
    address treasury = makeAddr("treasury");
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address staker1 = makeAddr("staker1");
    address staker2 = makeAddr("staker2");
    address keeperEoa = makeAddr("keeperEoa");

    // ----- spec params -----
    uint16 constant BASE_FEE_BPS = 30;
    uint16 constant TOLERANCE_BPS = 500;
    uint16 constant HARD_THRESHOLD_BPS = 1500;
    uint16 constant DRAWDOWN_BPS = 2000; // 20%
    uint16 constant VAULT_FEE_BPS = 2000;
    uint16 constant TREASURY_FEE_BPS = 1000;
    uint32 constant K_SCALED = 40_000;

    // shorthand
    function _t0() internal view returns (IERC20) {
        return IERC20(Currency.unwrap(currency0));
    }

    function _t1() internal view returns (IERC20) {
        return IERC20(Currency.unwrap(currency1));
    }

    // -------------------------------------------------------------------
    // setUp — full deploy + pool authorize + initial wiring
    // -------------------------------------------------------------------

    function setUp() public {
        // v4 manager + routers + two 18-decimal test currencies
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        // STRAND owned by multisig from day one
        strand = new STRAND(multisig);

        // Hook deployed via CREATE2 to a permission-encoded address (Deploy.s.sol path)
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory hookInit = abi.encodePacked(type(WoolFiHook).creationCode, abi.encode(manager, address(this)));
        (address minedHook,) = HookMiner.find(flags, hookInit);
        (, bytes32 salt) = HookMiner.find(flags, hookInit);
        address deployed = HookMiner.deploy(salt, hookInit);
        require(deployed == minedHook, "deploy mismatch");
        hook = WoolFiHook(deployed);

        pm = new WoolFiPositionManager(manager, multisig);
        governor = new WoolFiGovernor(deployed, multisig);
        hook.setGovernor(address(governor));
        keeper = new RebalanceKeeper(hook, pm);

        // oracles + market-hours
        oracle0 = new MockPriceOracle(1e18);
        oracle1 = new MockPriceOracle(1e18);
        marketHours = new MockMarketHours(true);

        // build pool key
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        shareId = uint256(PoolId.unwrap(poolId));

        // governance authorizes + initialize + wire vault + fee routing
        vm.startPrank(multisig);
        governor.authorizePool(
            poolKey,
            WoolFiHook.AuthParams({
                oracle0: oracle0,
                oracle1: oracle1,
                marketHours: marketHours,
                kScaled: K_SCALED,
                baseFeeBps: BASE_FEE_BPS,
                toleranceBps: TOLERANCE_BPS,
                hardThresholdBps: HARD_THRESHOLD_BPS
            })
        );
        vm.stopPrank();
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        vault = new WoolFiUnderwritingVault(
            address(strand), address(hook), Currency.unwrap(currency0), Currency.unwrap(currency1), rebalancer, 2_000e18
        );

        vm.startPrank(multisig);
        governor.setVault(poolKey, address(vault), DRAWDOWN_BPS);
        pm.setFeeConfig(poolKey, address(vault), VAULT_FEE_BPS, treasury, TREASURY_FEE_BPS);
        strand.mint(staker1, 1_000e18);
        strand.mint(staker2, 1_000e18);
        vm.stopPrank();

        // fund LPs with both pool tokens and approve PM
        _fundLp(lp1, 1e23);
        _fundLp(lp2, 1e23);

        // approve vault from stakers
        vm.prank(staker1);
        strand.approve(address(vault), type(uint256).max);
        vm.prank(staker2);
        strand.approve(address(vault), type(uint256).max);

        // approve swapRouter from this contract (already done by deployMintAndApprove2Currencies)
    }

    function _fundLp(address lp, uint256 amount) internal {
        _t0().transfer(lp, amount);
        _t1().transfer(lp, amount);
        vm.startPrank(lp);
        _t0().approve(address(pm), type(uint256).max);
        _t1().approve(address(pm), type(uint256).max);
        vm.stopPrank();
    }

    // -------------------------------------------------------------------
    // THE LIFECYCLE
    // -------------------------------------------------------------------

    function test_fullLifecycle_e2e() public {
        // =================================================================
        // Phase A — initial state is clean
        // =================================================================
        assertEq(pm.totalShares(shareId), 0);
        assertEq(vault.totalShares(), 0);
        assertEq(vault.totalStaked(), 0);
        assertFalse(hook.poolConfig(poolId).structuralBreak);
        assertEq(hook.governor(), address(governor));
        assertEq(governor.owner(), multisig);

        // =================================================================
        // Phase B — stakers underwrite the pool first
        //   staker1 stakes 600 STRAND, staker2 stakes 400 → totalShares 1000
        // =================================================================
        vm.prank(staker1);
        vault.stake(600e18);
        vm.prank(staker2);
        vault.stake(400e18);
        assertEq(vault.totalShares(), 1_000e18);
        assertEq(vault.totalStaked(), 1_000e18);
        assertEq(vault.sharesOf(staker1), 600e18);
        assertEq(vault.sharesOf(staker2), 400e18);

        // =================================================================
        // Phase C — LPs deposit through the PM (in-band, market open)
        //   lp2 deposits 2x lp1 → ratio of shares matches
        // =================================================================
        vm.prank(lp1);
        uint128 sa = pm.mint(poolKey, 100e18, 100e18, lp1);
        vm.prank(lp2);
        uint128 sb = pm.mint(poolKey, 200e18, 200e18, lp2);
        assertGt(sa, 0);
        assertApproxEqAbs(sb, sa * 2, 1); // 2:1 deposit ratio at equal price

        // Invariant: PM shares == on-chain v4 position liquidity
        (uint128 posLiq,,) = manager.getPositionInfo(
            poolId, address(pm), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), bytes32(0)
        );
        assertEq(pm.totalShares(shareId), posLiq);

        // =================================================================
        // Phase D — in-band swaps run at base fee; collecting routes the cuts
        // =================================================================
        // a few swaps in both directions accrue fees in token0 and token1
        swap(poolKey, true, -1e17, ZERO_BYTES);
        swap(poolKey, false, -1e17, ZERO_BYTES);

        // lp1 collects → PM realizes the position's fees and routes them
        uint256 vaultT0Before = _t0().balanceOf(address(vault));
        uint256 treasuryT0Before = _t0().balanceOf(treasury);
        uint256 lp1T0Before = _t0().balanceOf(lp1);
        vm.prank(lp1);
        pm.collectFees(poolKey, lp1);

        uint256 vaultGot = _t0().balanceOf(address(vault)) - vaultT0Before;
        uint256 treasuryGot = _t0().balanceOf(treasury) - treasuryT0Before;
        uint256 lp1Got = _t0().balanceOf(lp1) - lp1T0Before;
        assertGt(vaultGot, 0);
        assertGt(treasuryGot, 0);
        assertGt(lp1Got, 0);
        // vault cut (20%) == 2 x treasury cut (10%) ± rounding
        assertApproxEqAbs(vaultGot, treasuryGot * 2, 4);

        // =================================================================
        // Phase E — stakers claim accrued rewards (pro-rata to shares)
        // =================================================================
        uint256 s1T0Before = _t0().balanceOf(staker1);
        uint256 s2T0Before = _t0().balanceOf(staker2);
        vm.prank(staker1);
        vault.claim();
        vm.prank(staker2);
        vault.claim();
        uint256 s1Got = _t0().balanceOf(staker1) - s1T0Before;
        uint256 s2Got = _t0().balanceOf(staker2) - s2T0Before;
        // staker1 has 600/1000 = 1.5x staker2's 400 → reward ratio matches stake ratio
        assertApproxEqAbs(s1Got * 400, s2Got * 600, 4);
        assertGt(s1Got, 0);

        // =================================================================
        // Phase F — drift out of band (not broken) → asymmetric fee mode
        // =================================================================
        oracle0.setPrice(1.08e18); // drift ≈ -741 bps : out of band, well below 1500 hard threshold
        // a swap runs without break and the asymmetric fee logic kicks in (mechanic itself is
        // already proven in WoolFiHookTest; here we only verify the integration doesn't blow up)
        swap(poolKey, true, -1e16, ZERO_BYTES);
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        // =================================================================
        // Phase G — direct-to-PoolManager concentrated add is rejected
        //   (hook's full-range guard protects the uniform-liquidity assumption)
        // =================================================================
        {
            IPoolManager.ModifyLiquidityParams memory bad =
                IPoolManager.ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1e15, salt: 0});
            vm.prank(address(manager));
            vm.expectRevert(WoolFiHook.NotFullRange.selector);
            hook.beforeAddLiquidity(address(this), poolKey, bad, "");
        }

        // =================================================================
        // Phase H — stale oracle reverts swaps (no fee math on bad price)
        // =================================================================
        oracle0.setStale(true);
        {
            IPoolManager.SwapParams memory sp =
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
            vm.prank(address(manager));
            vm.expectRevert(MockPriceOracle.MockStale.selector);
            hook.beforeSwap(address(this), poolKey, sp, "");
        }
        oracle0.setStale(false);

        // =================================================================
        // Phase I — market closes
        //   (1) addLiquidity reverts MarketClosed
        //   (2) swap still allowed but flat
        //   (3) drift past hard threshold during closure does NOT trigger a break
        // =================================================================
        marketHours.setOpen(false);
        {
            IPoolManager.ModifyLiquidityParams memory params = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e15,
                salt: 0
            });
            vm.prank(address(manager));
            vm.expectRevert(WoolFiHook.MarketClosed.selector);
            hook.beforeAddLiquidity(address(this), poolKey, params, "");
        }
        oracle0.setPrice(1.2e18); // drift beyond hard threshold...
        swap(poolKey, true, -1e15, ZERO_BYTES); // ...but break detection is suppressed
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        // =================================================================
        // Phase J — market reopens; the keeper forces break detection + drawdown
        //   without needing a swap (closes the gap the spec §3.5 calls out)
        // =================================================================
        marketHours.setOpen(true);
        uint256 totalStakedBefore = vault.totalStaked();
        uint256 rebalancerBefore = strand.balanceOf(rebalancer);

        vm.prank(keeperEoa);
        keeper.keep(poolKey);

        assertTrue(hook.poolConfig(poolId).structuralBreak);
        uint256 seizedExpected = totalStakedBefore * DRAWDOWN_BPS / 10_000;
        assertEq(vault.totalStaked(), totalStakedBefore - seizedExpected);
        assertEq(strand.balanceOf(rebalancer) - rebalancerBefore, seizedExpected);
        // STRAND solvency invariant after drawdown
        assertLe(vault.totalStaked(), strand.balanceOf(address(vault)));

        // =================================================================
        // Phase K — staker requests unstake during break, cooldown + redemption
        //   shares stay exposed to drawdown during cooldown (already happened above);
        //   redemption returns the post-haircut value, not the original stake
        // =================================================================
        vm.prank(staker1);
        vault.requestUnstake(300e18);
        // cannot unstake before cooldown elapses
        vm.prank(staker1);
        vm.expectRevert(WoolFiUnderwritingVault.CooldownActive.selector);
        vault.unstake();

        skip(vault.COOLDOWN());

        uint256 strand1Before = strand.balanceOf(staker1);
        vm.prank(staker1);
        uint256 redeemed = vault.unstake();
        // 300 of 1000 shares; totalStaked = 1000 - 200 = 800; redeemed = 300 * 800 / 1000 = 240
        assertEq(redeemed, 240e18);
        assertEq(strand.balanceOf(staker1) - strand1Before, 240e18);

        // =================================================================
        // Phase L — governance resolves the break; asymmetric fees return
        // =================================================================
        vm.prank(multisig);
        governor.resolveStructuralBreak(poolKey);
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        // a swap now runs the asymmetric path again (drift is still ≠ 0 from prior phases)
        oracle0.setPrice(1e18); // bring fair back near pool to avoid an immediate re-break
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        // =================================================================
        // Phase M — LP can withdraw even out of band (spec §3.4)
        // =================================================================
        oracle0.setPrice(1.5e18); // far out of band
        uint128 lp1Shares = uint128(pm.balanceOf(lp1, shareId));
        uint256 lp1T0BeforeBurn = _t0().balanceOf(lp1);
        uint256 lp1T1BeforeBurn = _t1().balanceOf(lp1);
        vm.prank(lp1);
        pm.burn(poolKey, lp1Shares, lp1);
        // got SOMETHING back in both tokens
        assertGt(_t0().balanceOf(lp1), lp1T0BeforeBurn);
        assertGt(_t1().balanceOf(lp1), lp1T1BeforeBurn);
        // and lp1's shares are zero
        assertEq(pm.balanceOf(lp1, shareId), 0);

        // =================================================================
        // Phase N — governance hand-off (v2 migration path)
        // =================================================================
        address newGov = makeAddr("v2Governor");
        vm.prank(multisig);
        governor.setHookGovernor(newGov);
        assertEq(hook.governor(), newGov);

        // old governor contract can no longer manage the hook
        vm.prank(multisig);
        vm.expectRevert(WoolFiHook.NotGovernor.selector);
        governor.pauseHook();

        // new governor can: pause via direct hook call (the new on-chain gov is `newGov`)
        vm.prank(newGov);
        hook.setPaused(true);
        assertTrue(hook.paused());
        // a swap reverts (Paused) — checked directly because the PoolManager wraps the revert
        {
            IPoolManager.SwapParams memory sp =
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e14, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
            vm.prank(address(manager));
            vm.expectRevert(WoolFiHook.Paused.selector);
            hook.beforeSwap(address(this), poolKey, sp, "");
        }
        // unpause for the final invariants
        vm.prank(newGov);
        hook.setPaused(false);

        // =================================================================
        // Final invariants — the protocol is still consistent after all that
        // =================================================================
        // PM shares back the v4 position 1:1
        (uint128 posLiqFinal,,) = manager.getPositionInfo(
            poolId, address(pm), TickMath.minUsableTick(60), TickMath.maxUsableTick(60), bytes32(0)
        );
        assertEq(pm.totalShares(shareId), posLiqFinal);

        // sum of remaining LP balances == PM totalShares
        assertEq(pm.balanceOf(lp1, shareId) + pm.balanceOf(lp2, shareId), pm.totalShares(shareId));
        // (and after Phase M, lp1's share is zero — so lp2 owns everything)
        assertEq(pm.balanceOf(lp1, shareId), 0);
        assertEq(pm.balanceOf(lp2, shareId), pm.totalShares(shareId));

        // vault is still solvent
        assertLe(vault.totalStaked(), strand.balanceOf(address(vault)));
        // sum of remaining staker shares == vault totalShares (only staker2 fully in;
        // staker1 burned 300 of 600 in Phase K and still holds 300)
        assertEq(vault.sharesOf(staker1) + vault.sharesOf(staker2), vault.totalShares());

        // rebalancer holds exactly what was seized
        assertEq(strand.balanceOf(rebalancer), seizedExpected);

        // treasury policy sink received its 10% cut on each fee realization
        assertGt(_t0().balanceOf(treasury), 0);
    }

    function test_hookSafetyLifecycle_reopenSkewBreakRecoveryResolve() public {
        vm.prank(lp1);
        pm.mint(poolKey, 100e18, 100e18, lp1);

        vm.prank(multisig);
        governor.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 300, maxOracleSkew: 60}));

        marketHours.setOpen(false);
        skip(2 days);
        marketHours.setOpen(true);
        {
            IPoolManager.ModifyLiquidityParams memory add = IPoolManager.ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 1e15,
                salt: 0
            });
            uint256 start = marketHours.currentSessionStart();
            vm.prank(address(manager));
            vm.expectRevert(abi.encodeWithSelector(WoolFiHook.StabilizationActive.selector, start, start + 300));
            hook.beforeAddLiquidity(address(this), poolKey, add, "");
        }

        skip(300);
        oracle0.setPriceData(1.2e18, block.timestamp);
        oracle1.setPriceData(1e18, block.timestamp - 61);
        swap(poolKey, true, -1e15, ZERO_BYTES);
        assertFalse(hook.poolConfig(poolId).structuralBreak);

        oracle1.setPriceData(1e18, block.timestamp);
        swap(poolKey, true, -1e15, ZERO_BYTES);
        WoolFiHook.WoolFiConfig memory broken = hook.poolConfig(poolId);
        assertTrue(broken.structuralBreak);
        assertEq(broken.cachedFairPriceWad, 1.2e18);

        oracle0.setStale(true);
        {
            IPoolManager.SwapParams memory adversarial =
                IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT});
            vm.prank(address(manager));
            vm.expectRevert(WoolFiHook.AdversarialSwapDuringBreak.selector);
            hook.beforeSwap(address(this), poolKey, adversarial, "");
        }
        swap(poolKey, false, -1e15, ZERO_BYTES);

        vm.prank(multisig);
        governor.resolveStructuralBreak(poolKey);
        broken = hook.poolConfig(poolId);
        assertFalse(broken.structuralBreak);
        assertEq(broken.cachedFairPriceWad, 0);
    }
}
