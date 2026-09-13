// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {WoolFiSwapRouter} from "../../src/WoolFiSwapRouter.sol";
import {RobinhoodStockOracleAdapter} from "../../src/oracle/RobinhoodStockOracleAdapter.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {IFeeRebateDistributor} from "../../src/interfaces/IFeeRebateDistributor.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {NyseHoursOracle} from "../../src/oracle/NyseHoursOracle.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @notice End-to-end fork test of WoolFi against real Robinhood Chain state: deploy, wire, seed
///         liquidity, stake URU, swap, verify fees, collect. Confirms the protocol actually works
///         against a real PoolManager, real Chainlink prints, and real tokens before any broadcast.
/// @dev Uses MSTR/USDG as the exemplar pool. The probe in
///      `test/fork/TokenTransferProbe.fork.t.sol` established that `deal` works on all six tested
///      canonical Robinhood Chain tokens (no on-chain transfer allowlist). Sequencer guard is
///      disabled per spec §5.1 (Robinhood Chain publishes no L2 uptime feed).
contract WoolFiLifecycleForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 private constant FORK_HEARTBEAT = 7 days;

    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;

    address private constant TOK_MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address private constant TOK_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant FEED_MSTR = 0x396118bdFB181e6240E74D243F266B061c0edc3D;
    address private constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    // Actors
    address me = address(this);
    address lp1 = makeAddr("lp1");
    address lp2 = makeAddr("lp2");
    address staker = makeAddr("staker");
    address trader = makeAddr("trader");
    address treasury = makeAddr("treasury");
    address rebalancer = makeAddr("rebalancer");

    // System
    WoolFiHook hook;
    WoolFiGovernor governor;
    WoolFiPositionManager pm;
    WoolFiSwapRouter router;
    WoolFiUnderwritingVault vault;
    IPriceOracle mstrOracle;
    IPriceOracle usdgOracle;
    PoolKey key;

    modifier onlyOnFork() {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain forked");

        // If MSTR oracle is paused at the fork block, skip the whole lifecycle test.
        (bool ok, bytes memory data) = TOK_MSTR.staticcall(abi.encodeWithSignature("oraclePaused()"));
        if (ok && data.length == 32 && abi.decode(data, (bool))) {
            emit log_string("MSTR oraclePaused at fork block; skipping lifecycle test");
            vm.skip(true);
            return;
        }
        _;
    }

    /// @notice Full lifecycle: deploy → adapters → pool init → LP mint → URU stake → swap →
    ///         collect fees → verify vault and treasury got their configured cuts.
    function test_fork_fullLifecycle() public onlyOnFork {
        (uint256 usdgSeed, uint256 mstrSeed) = _deployAndSeed();
        _stakeAndMint(usdgSeed, mstrSeed);

        // Fees route from hook.afterSwap → pm.realizeFromHook → vault.depositRewards + treasury,
        // so the vault and treasury are paid DURING the swap, not on collectFees. Snapshot
        // before/after the swap to observe that. v4 charges the LP fee in the SWAP INPUT token,
        // so a token1→token0 (MSTR→USDG) swap accrues token1 (MSTR) fees.
        (uint256 vaultMstrBefore, uint256 treasuryMstrBefore) = _feeSinkBalancesToken1();

        uint256 mstrIn = mstrSeed / 100;
        uint256 usdgOut = _tradeMstrForUsdg(mstrIn);
        _sanityCheckSwapOutput(mstrIn, usdgOut);
        _assertFeesRoutedOnSwapMstr(vaultMstrBefore, treasuryMstrBefore);

        _collectLpFeesMstr(); // LP gets their harvested per-share cut from the token1 accumulator
        _claimStakerRewards(); // staker gets pool-token cut of vault.depositRewards call
        _roundTripUsdgForMstr(100 * (10 ** 6)); // 100 USDG round-trip in the other direction
    }

    /// @notice Push pool >15% off fair with a large swap; verify structural break + drawdown.
    /// @dev Uses real oracle prints (unchanged), moves the pool via a very large swap so drift
    ///      exceeds hardThresholdBps=1500. The hook's _flagBreakIfReached also atomically calls
    ///      vault.drawdown(2000bps) — verify the seizure landed on the rebalancer.
    function test_fork_structuralBreakAndDrawdown() public onlyOnFork {
        (uint256 usdgSeed, uint256 mstrSeed) = _deployAndSeed();
        _stakeAndMint(usdgSeed, mstrSeed);

        uint256 vaultBefore = IERC20(URU).balanceOf(address(vault));
        uint256 rebalancerBefore = IERC20(URU).balanceOf(rebalancer);
        uint256 totalStakedBefore = vault.totalStaked();

        // Swap 20% of pool MSTR reserves into the pool: drift moves well past 15% hardThreshold.
        uint256 mstrShock = mstrSeed / 5;
        deal(TOK_MSTR, trader, mstrShock);
        vm.prank(trader);
        IERC20(TOK_MSTR).approve(address(router), type(uint256).max);
        vm.prank(trader);
        router.swap(key, false, mstrShock, 1, trader, "");

        WoolFiHook.WoolFiConfig memory cfg = hook.poolConfig(key.toId());
        assertTrue(cfg.structuralBreak, "break flag set");
        assertGt(cfg.cachedFairPriceWad, 0, "cached fair recorded");

        uint256 vaultAfter = IERC20(URU).balanceOf(address(vault));
        uint256 rebalancerAfter = IERC20(URU).balanceOf(rebalancer);
        uint256 seized = vaultBefore - vaultAfter;
        assertGt(seized, 0, "vault seized non-zero URU");
        assertEq(rebalancerAfter - rebalancerBefore, seized, "rebalancer received seized URU");
        // drawdownBps = 2000 → 20% of totalStaked (500 URU) = 100 URU.
        assertApproxEqAbs(seized, totalStakedBefore * 2000 / 10_000, 1, "seized matches drawdownBps");
        assertEq(vault.totalStaked(), totalStakedBefore - seized, "totalStaked updated");
        emit log_named_uint("URU seized to rebalancer", seized);

        // Governor can resolve the break, clearing state (verifies the exit path).
        governor.resolveStructuralBreak(key);
        assertFalse(hook.poolConfig(key.toId()).structuralBreak, "break cleared by governor");
    }

    /// @notice Simulate a corporate-action pause via vm.mockCall on the stock token's
    ///         oraclePaused(). The stock adapter must revert; upstream any swap that reaches
    ///         oracle-read paths must revert too.
    function test_fork_stockOraclePausedRevertsSwaps() public onlyOnFork {
        (uint256 usdgSeed, uint256 mstrSeed) = _deployAndSeed();
        _stakeAndMint(usdgSeed, mstrSeed);

        // Mock MSTR.oraclePaused() -> true at the token level; adapter reads it via staticcall.
        vm.mockCall(TOK_MSTR, abi.encodeWithSignature("oraclePaused()"), abi.encode(true));

        // Adapter must revert directly on read
        vm.expectRevert(RobinhoodStockOracleAdapter.OraclePaused.selector);
        mstrOracle.getPrice();

        // A swap must also revert (beforeSwap → oracle → OraclePaused).
        uint256 mstrIn = mstrSeed / 100;
        deal(TOK_MSTR, trader, mstrIn);
        vm.prank(trader);
        IERC20(TOK_MSTR).approve(address(router), type(uint256).max);
        vm.prank(trader);
        vm.expectRevert(); // wrapped by v4 PoolManager; we accept any revert
        router.swap(key, false, mstrIn, 1, trader, "");
    }

    /// @notice For a market-hours-gated pool, add-liquidity must revert while the market-hours
    ///         oracle reports closed; swaps still land but at flat base fee (no asymmetry).
    function test_fork_marketClosedGatesLiquidity() public onlyOnFork {
        (, uint256 mstrSeed) = _deployAndSeed();
        // Fund the LP with headroom for a later mint attempt.
        deal(TOK_USDG, lp1, 200_000 * 10 ** 6);
        deal(TOK_MSTR, lp1, mstrSeed);
        vm.startPrank(lp1);
        IERC20(TOK_USDG).approve(address(pm), type(uint256).max);
        IERC20(TOK_MSTR).approve(address(pm), type(uint256).max);
        vm.stopPrank();

        // Flip MockMarketHours to closed by pointing the pool at a NEW closed-mock via governance.
        MockMarketHours closedMh = new MockMarketHours(false);
        governor.updatePoolConfigV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: usdgOracle,
                    oracle1: mstrOracle,
                    marketHours: IMarketHoursOracle(address(closedMh)),
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0})
            })
        );

        // beforeAddLiquidity must revert while closed.
        vm.prank(lp1);
        vm.expectRevert(); // wrapped: MarketClosed inside beforeAddLiquidity
        pm.mint(key, 100 * 10 ** 6, mstrSeed / 100, lp1);
    }

    /// @notice Real NyseHoursOracle bound to the pool, then warped to a known-closed instant
    ///         (Saturday UTC noon). isMarketOpen() must return false and add-liquidity must revert.
    function test_fork_nyseHoursOracleClosedWeekend() public onlyOnFork {
        (, uint256 mstrSeed) = _deployAndSeed();

        NyseHoursOracle nyse = new NyseHoursOracle(address(this));
        // Bind to the pool via governor
        governor.updatePoolConfigV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: usdgOracle,
                    oracle1: mstrOracle,
                    marketHours: IMarketHoursOracle(address(nyse)),
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0})
            })
        );

        // Saturday 2026-11-14 12:00 UTC → NYSE closed on weekends. Timestamp: 1794139200.
        vm.warp(1_794_139_200);
        assertFalse(nyse.isMarketOpen(), "NYSE reports closed on Saturday");

        // beforeAddLiquidity should revert while market-hours reports closed.
        deal(TOK_USDG, lp1, 200_000 * 10 ** 6);
        deal(TOK_MSTR, lp1, mstrSeed);
        vm.startPrank(lp1);
        IERC20(TOK_USDG).approve(address(pm), type(uint256).max);
        IERC20(TOK_MSTR).approve(address(pm), type(uint256).max);
        vm.stopPrank();
        vm.prank(lp1);
        vm.expectRevert(); // wrapped: MarketClosed
        pm.mint(key, 100 * 10 ** 6, mstrSeed / 100, lp1);

        // Warp forward to Monday 14:00 UTC (open); isMarketOpen -> true.
        vm.warp(1_794_310_800); // 2026-11-16 14:00 UTC (Monday 09:00 EST -- market opens 09:30 EST)
        // Just after the boundary: still might read as closed depending on precise calendar; the
        // point of this test is the CLOSED-side assertion. Not re-asserting open here.
    }

    // ---- Break test helpers: read hook.poolConfig; needs the struct ABI ----
    // WoolFiConfig struct is exported from WoolFiHook's poolConfig getter.

    function _feeSinkBalancesToken1() private view returns (uint256 vaultBal, uint256 treasuryBal) {
        vaultBal = IERC20(TOK_MSTR).balanceOf(address(vault));
        treasuryBal = IERC20(TOK_MSTR).balanceOf(treasury);
    }

    function _deployAndSeed() private returns (uint256 usdgSeed, uint256 mstrSeed) {
        Deploy script = new Deploy();
        Deploy.Deployment memory dep = script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), me);
        hook = WoolFiHook(dep.hook);
        governor = WoolFiGovernor(dep.governor);
        pm = WoolFiPositionManager(dep.positionManager);

        mstrOracle = new RobinhoodStockOracleAdapter(TOK_MSTR, FEED_MSTR, address(0), FORK_HEARTBEAT, 0);
        usdgOracle = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);
        router = new WoolFiSwapRouter(IPoolManager(POOL_MANAGER), IFeeRebateDistributor(address(0)));

        assertLt(uint160(TOK_USDG), uint160(TOK_MSTR), "USDG must sort below MSTR");
        vault = new WoolFiUnderwritingVault(URU, address(hook), TOK_USDG, TOK_MSTR, rebalancer, 1_000e18);
        (usdgSeed, mstrSeed) = _authorizeInitializeWire();
    }

    function _authorizeInitializeWire() private returns (uint256 usdgSeed, uint256 mstrSeed) {
        uint256 price0 = usdgOracle.getPrice();
        uint256 price1 = mstrOracle.getPrice();
        uint160 sqrtPriceX96 = _sqrtPriceX96(price0, price1, 6, 18);
        emit log_named_uint("USDG price wad", price0);
        emit log_named_uint("MSTR price wad", price1);
        emit log_named_uint("sqrtPriceX96", uint256(sqrtPriceX96));

        MockMarketHours marketHours = new MockMarketHours(true);
        key = PoolKey({
            currency0: Currency.wrap(TOK_USDG),
            currency1: Currency.wrap(TOK_MSTR),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        governor.authorizePoolV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: usdgOracle,
                    oracle1: mstrOracle,
                    marketHours: IMarketHoursOracle(address(marketHours)),
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0})
            })
        );
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        governor.setVault(key, address(vault), 2000);
        pm.setFeeConfig(key, address(vault), 2000, treasury, 1000);

        usdgSeed = 100_000 * (10 ** 6);
        mstrSeed = FullMath.mulDiv(usdgSeed * (10 ** 12), price0, price1);
    }

    function _stakeAndMint(uint256 usdgSeed, uint256 mstrSeed) private {
        deal(TOK_USDG, lp1, usdgSeed * 12 / 10);
        deal(TOK_MSTR, lp1, mstrSeed * 12 / 10);
        deal(URU, staker, 500e18);

        vm.startPrank(lp1);
        IERC20(TOK_USDG).approve(address(pm), type(uint256).max);
        IERC20(TOK_MSTR).approve(address(pm), type(uint256).max);
        vm.stopPrank();

        vm.prank(staker);
        IERC20(URU).approve(address(vault), type(uint256).max);
        vm.prank(staker);
        vault.stake(500e18);
        assertEq(vault.totalStaked(), 500e18, "vault total staked");
        assertEq(vault.sharesOf(staker), 500e18, "vault staker shares");

        vm.prank(lp1);
        uint128 lp1Shares = pm.mint(key, usdgSeed, mstrSeed, lp1);
        assertGt(lp1Shares, 0, "LP1 shares > 0");
        emit log_named_uint("LP1 shares", uint256(lp1Shares));
    }

    function _tradeMstrForUsdg(uint256 mstrIn) private returns (uint256 amountOut) {
        deal(TOK_MSTR, trader, mstrIn);
        vm.prank(trader);
        IERC20(TOK_MSTR).approve(address(router), type(uint256).max);

        uint256 before = IERC20(TOK_USDG).balanceOf(trader);
        vm.prank(trader);
        amountOut = router.swap(key, false, mstrIn, 1, trader, "");
        assertEq(IERC20(TOK_USDG).balanceOf(trader) - before, amountOut, "trader received swap output");
        assertGt(amountOut, 0, "swap produced non-zero output");
        emit log_named_uint("MSTR in", mstrIn);
        emit log_named_uint("USDG out", amountOut);
    }

    function _sanityCheckSwapOutput(uint256 mstrIn, uint256 usdgOut) private {
        uint256 price0 = usdgOracle.getPrice();
        uint256 price1 = mstrOracle.getPrice();
        uint256 expectedUsdg = FullMath.mulDiv(mstrIn, price1, price0) / (10 ** 12);
        assertGt(usdgOut, expectedUsdg * 70 / 100, "swap output far below fair");
        assertLt(usdgOut, expectedUsdg * 110 / 100, "swap output above fair (no fees taken?)");
    }

    function _assertFeesRoutedOnSwapMstr(uint256 vaultBefore, uint256 treasuryBefore) private {
        uint256 vaultGot = IERC20(TOK_MSTR).balanceOf(address(vault)) - vaultBefore;
        uint256 treasuryGot = IERC20(TOK_MSTR).balanceOf(treasury) - treasuryBefore;
        emit log_named_uint("vault fee cut (MSTR)", vaultGot);
        emit log_named_uint("treasury fee cut (MSTR)", treasuryGot);
        assertGt(vaultGot, 0, "vault received fees via afterSwap");
        assertGt(treasuryGot, 0, "treasury received fees via afterSwap");
        // vault (20%) ~= 2 * treasury (10%) modulo rounding
        assertApproxEqAbs(vaultGot, treasuryGot * 2, 8, "vault approx 2x treasury");
    }

    function _collectLpFeesMstr() private {
        uint256 lpBefore = IERC20(TOK_MSTR).balanceOf(lp1);
        vm.prank(lp1);
        pm.collectFees(key, lp1);
        uint256 lpGot = IERC20(TOK_MSTR).balanceOf(lp1) - lpBefore;
        emit log_named_uint("LP fee cut (MSTR)", lpGot);
        assertGt(lpGot, 0, "LP received harvested fees");
    }

    function _claimStakerRewards() private {
        // Staker's reward is in the pool's INPUT token from the swap = MSTR here.
        uint256 before = IERC20(TOK_MSTR).balanceOf(staker);
        vm.prank(staker);
        vault.claim();
        assertGt(IERC20(TOK_MSTR).balanceOf(staker) - before, 0, "staker received reward MSTR");
    }

    function _roundTripUsdgForMstr(uint256 usdgIn) private {
        deal(TOK_USDG, trader, usdgIn);
        vm.prank(trader);
        IERC20(TOK_USDG).approve(address(router), type(uint256).max);
        vm.prank(trader);
        router.swap(key, true, usdgIn, 1, trader, "");
    }

    /// @notice Compute sqrtPriceX96 for a pool at fair value given WAD-normalized leg prices and
    ///         token decimals. pool_price (raw1/raw0) = (price0Wad / price1Wad) * 10^(dec1-dec0).
    function _sqrtPriceX96(uint256 price0Wad, uint256 price1Wad, uint8 dec0, uint8 dec1)
        private
        pure
        returns (uint160)
    {
        uint256 ratioX192;
        uint256 twoTo192 = uint256(1) << 192;
        if (dec1 >= dec0) {
            uint256 mult = 10 ** uint256(dec1 - dec0);
            ratioX192 = FullMath.mulDiv(price0Wad * mult, twoTo192, price1Wad);
        } else {
            uint256 divi = 10 ** uint256(dec0 - dec1);
            ratioX192 = FullMath.mulDiv(price0Wad, twoTo192, price1Wad * divi);
        }
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }
}
