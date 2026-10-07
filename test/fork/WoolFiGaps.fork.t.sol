// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiSwapRouter} from "../../src/WoolFiSwapRouter.sol";
import {WoolFiLiquidityZapper, IWoolFiPositionManagerMint} from "../../src/WoolFiLiquidityZapper.sol";
import {RobinhoodStockOracleAdapter} from "../../src/oracle/RobinhoodStockOracleAdapter.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {IPriceOracle, IPriceOracleMetadata} from "../../src/interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {IFeeRebateDistributor} from "../../src/interfaces/IFeeRebateDistributor.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @dev Swaps and reads the hook's per-swap fee in the same call frame. The hook keeps the fee in
///      transient storage, which only lives for one transaction; Foundry resets it between the
///      test's top-level calls, so the read has to happen inside the swapping call (exactly how
///      UrufuFeeRebateDistributor reads it after the router's swap settles).
contract FeeProbe {
    function swapAndReadFee(
        WoolFiSwapRouter router,
        WoolFiHook hook,
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn
    ) external returns (uint256 feeBps) {
        address tokenIn = Currency.unwrap(zeroForOne ? key.currency0 : key.currency1);
        IERC20(tokenIn).approve(address(router), amountIn);
        router.swap(key, zeroForOne, amountIn, 1, address(this), "");
        feeBps = hook.lastSwapFeeBps(PoolIdLibrary.toId(key));
    }
}

/// @notice Fork coverage for paths never exercised against live Robinhood Chain state:
///         ArbOS / transient storage support on the real node, oracle-skew degraded mode, the
///         post-open stabilization window, a real Uniswap v3 Zap, and the GLD feed cross-check.
/// @dev Skips without ROBINHOOD_RPC_URL. Run suites one at a time; the public RPC rate-limits.
contract WoolFiGapsForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 private constant FORK_HEARTBEAT = 7 days;
    uint16 private constant BASE_FEE = 30;

    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;
    address private constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    address private constant TOK_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant TOK_MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address private constant TOK_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address private constant TOK_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address private constant TOK_QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address private constant TOK_GLD = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;

    address private constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address private constant FEED_MSTR = 0x396118bdFB181e6240E74D243F266B061c0edc3D;
    address private constant FEED_NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address private constant FEED_SPY = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address private constant FEED_QQQ = 0x80901d846d5D7B030F26B480776EE3b29374C2ae;
    address private constant FEED_GLD = 0x470A51258068043bd43dC0a56245625C9fE86eB0;

    address private constant V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2; // SwapRouter02
    address private constant V3_QUOTER = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7; // QuoterV2
    address private constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;

    /// @dev SwapRouter02 exactInputSingle params (no deadline field).
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @dev QuoterV2 quoteExactInputSingle params.
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    address me = address(this);
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address alice = makeAddr("alice");
    address treasury = makeAddr("treasury");

    WoolFiHook hook;
    WoolFiGovernor governor;
    WoolFiPositionManager pm;
    WoolFiSwapRouter router;
    PoolKey key;
    IPriceOracle oracle0;
    IPriceOracle oracle1;
    MockMarketHours hours_;

    modifier onlyOnFork() {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain forked");
        _;
    }

    // ------------------------------------------------------------------
    // 1. ArbOS version + transient storage on the LIVE node
    // ------------------------------------------------------------------

    /// @notice Foundry's local EVM does not emulate Arbitrum precompiles and always runs Cancun
    ///         locally, so both checks go to the live node via vm.rpc. ArbSys.arbOSVersion() returns
    ///         55 + version; transient storage (Cancun) needs ArbOS 20, i.e. >= 75. The tstore/tload
    ///         round trip runs real bytecode on the node through an eth_call code override.
    function test_fork_arbOsSupportsTransientStorage() public onlyOnFork {
        bytes memory raw =
            vm.rpc("eth_call", '[{"to":"0x0000000000000000000000000000000000000064","data":"0x051038f2"},"latest"]');
        uint256 arbOs = abi.decode(raw, (uint256));
        emit log_named_uint("ArbSys.arbOSVersion() raw", arbOs);
        emit log_named_uint("ArbOS version", arbOs - 55);
        assertGe(arbOs, 75, "ArbOS >= 20 required for transient storage");

        // PUSH1 0x2a PUSH1 1 TSTORE PUSH1 1 TLOAD PUSH1 0 MSTORE PUSH1 32 PUSH1 0 RETURN
        bytes memory out = vm.rpc(
            "eth_call",
            '[{"to":"0x000000000000000000000000000000000000dEaD","data":"0x"},"latest",{"0x000000000000000000000000000000000000dEaD":{"code":"0x602a60015d60015c60005260206000f3"}}]'
        );
        assertEq(abi.decode(out, (uint256)), 0x2a, "tstore/tload round trip on live node");
    }

    // ------------------------------------------------------------------
    // 2. Oracle-skew degraded mode
    // ------------------------------------------------------------------

    /// @notice Control + skew: with skew checks off, an 8% oracle move makes adversarial flow pay
    ///         more than the base fee. With maxOracleSkew set and the legs' timestamps apart, the
    ///         same flow pays exactly the base fee, deposits revert with OracleTimestampSkew, and
    ///         the single-swap break guard still rejects a threshold-crossing swap.
    function test_fork_oracleSkewDegradedMode() public onlyOnFork {
        uint256 mstrSeed = _setupMstrUsdg(0, 0);

        _scaleFeed(FEED_MSTR, 108, 0); // MSTR +8%: pool now ~8% above fair, out of band
        uint256 controlFee = _smallAdversarialSwapFee(mstrSeed);
        emit log_named_uint("control fee bps (skew check off)", controlFee);
        assertGt(controlFee, BASE_FEE, "asymmetric surcharge active without skew");

        // Turn on a 120s skew limit and age the USDG leg by 10 minutes (well inside heartbeat).
        governor.setPoolSafety(key, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 120}));
        _ageFeed(FEED_USDG, 600);
        (,,, bool skewed) = hook.poolSafetyStatus(key);
        assertTrue(skewed, "pool reports oracle skew");

        uint256 skewFee = _smallAdversarialSwapFee(mstrSeed);
        emit log_named_uint("skew-mode fee bps", skewFee);
        assertEq(skewFee, BASE_FEE, "skew mode charges flat base fee");

        _assertMintRevertsWith(WoolFiHook.OracleTimestampSkew.selector, mstrSeed);
        _assertBigAdversarialSwapRevertsWith(WoolFiHook.SwapWouldBreakPool.selector, mstrSeed);
    }

    /// @notice Production config check: reads the spread pools' maxOracleSkew straight from the batch
    ///         config and asserts a SPY/QQQ pool configured that way is NOT skewed under live feeds.
    ///         Robinhood Chainlink feeds are deviation-triggered (0.5%) with a 24h heartbeat, so two
    ///         legs routinely update hours apart; the limit must be sized to the heartbeat (86400),
    ///         not seconds, or spread pools sit in degraded mode (flat fee, deposits blocked).
    function test_fork_spreadPoolSkewConfigUnderLiveFeeds() public onlyOnFork {
        uint32 configuredSkew = _spreadSkewFromBatchConfig("spy-qqq");
        assertGe(uint256(configuredSkew), FEED_HEARTBEAT_SECONDS, "spread skew sized to the feed heartbeat");

        _deployCore();
        RobinhoodStockOracleAdapter spy =
            new RobinhoodStockOracleAdapter(TOK_SPY, FEED_SPY, address(0), FORK_HEARTBEAT, 0);
        RobinhoodStockOracleAdapter qqq =
            new RobinhoodStockOracleAdapter(TOK_QQQ, FEED_QQQ, address(0), FORK_HEARTBEAT, 0);
        assertLt(uint160(TOK_SPY), uint160(TOK_QQQ), "SPY sorts below QQQ");
        (, uint256 spyAt) = spy.getPriceData();
        (, uint256 qqqAt) = qqq.getPriceData();
        uint256 gap = spyAt > qqqAt ? spyAt - qqqAt : qqqAt - spyAt;
        emit log_named_uint("SPY/QQQ live feed timestamp gap (s)", gap);
        emit log_named_uint("configured maxOracleSkew (s)", configuredSkew);

        _authorizeAndInit(TOK_SPY, TOK_QQQ, spy, qqq, 18, 18, 900, configuredSkew);
        hours_.setSessionStart(block.timestamp - 1 days); // outside stabilization
        (,, bool stabilizing, bool skewed) = hook.poolSafetyStatus(key);
        assertFalse(stabilizing, "not stabilizing");
        assertFalse(skewed, "spread pool with the configured maxOracleSkew is skewed under live feeds");
    }

    uint256 private constant FEED_HEARTBEAT_SECONDS = 86400;

    function _spreadSkewFromBatchConfig(string memory slug) private view returns (uint32) {
        string memory json = vm.readFile("script/config/robinhood-batch.example.json");
        for (uint256 i; i < 18; ++i) {
            string memory base = string.concat(".pools[", vm.toString(i), "]");
            if (keccak256(bytes(vm.parseJsonString(json, string.concat(base, ".slug")))) == keccak256(bytes(slug))) {
                return uint32(vm.parseJsonUint(json, string.concat(base, ".safety.maxOracleSkew")));
            }
        }
        revert("slug not in batch config");
    }

    // ------------------------------------------------------------------
    // 3. Post-open stabilization window
    // ------------------------------------------------------------------

    function test_fork_stabilizationWindow() public onlyOnFork {
        uint256 mstrSeed = _setupMstrUsdg(900, 0);
        _scaleFeed(FEED_MSTR, 108, 0);

        hours_.setSessionStart(block.timestamp - 60); // market opened 60s ago
        (,, bool stabilizing,) = hook.poolSafetyStatus(key);
        assertTrue(stabilizing, "inside 900s stabilization window");

        uint256 stabFee = _smallAdversarialSwapFee(mstrSeed);
        emit log_named_uint("stabilization fee bps", stabFee);
        assertEq(stabFee, BASE_FEE, "flat fee during stabilization");
        _assertBigAdversarialSwapRevertsWith(WoolFiHook.SwapWouldBreakPool.selector, mstrSeed);

        vm.warp(block.timestamp + 900);
        (,, stabilizing,) = hook.poolSafetyStatus(key);
        assertFalse(stabilizing, "window elapsed");
        uint256 liveFee = _smallAdversarialSwapFee(mstrSeed);
        emit log_named_uint("post-window fee bps", liveFee);
        assertGt(liveFee, BASE_FEE, "asymmetric fee resumes after window");
    }

    // ------------------------------------------------------------------
    // 4. Real Uniswap v3 Zap through SwapRouter02
    // ------------------------------------------------------------------

    function test_fork_zapThroughRealUniswapV3() public onlyOnFork {
        _deployCore();
        oracle0 = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);
        oracle1 = new RobinhoodStockOracleAdapter(TOK_NVDA, FEED_NVDA, address(0), FORK_HEARTBEAT, 0);
        assertLt(uint160(TOK_USDG), uint160(TOK_NVDA), "USDG sorts below NVDA");
        _authorizeAndInit(TOK_USDG, TOK_NVDA, oracle0, oracle1, 6, 18, 0, 0);
        hours_.setSessionStart(block.timestamp - 1 days);
        _seed(TOK_USDG, TOK_NVDA, 100_000e6, _equivalent(100_000e6, 6, 18));

        WoolFiLiquidityZapper zapper = new WoolFiLiquidityZapper(IWoolFiPositionManagerMint(address(pm)), WETH, me);
        zapper.setExecutorAllowed(V3_ROUTER, true);

        uint256 zapIn = 1_000e6;
        uint256 swapIn = 500e6;
        uint256 quoted = _quote(TOK_USDG, TOK_NVDA, swapIn, 500);
        emit log_named_uint("QuoterV2 NVDA out for 500 USDG", quoted);
        assertGt(quoted, 0, "quoter returned output");

        bytes memory routerCall = abi.encodeWithSelector(
            bytes4(0x04e45aaf),
            ExactInputSingleParams({
                tokenIn: TOK_USDG,
                tokenOut: TOK_NVDA,
                fee: 500,
                recipient: address(zapper),
                amountIn: swapIn,
                amountOutMinimum: quoted * 99 / 100,
                sqrtPriceLimitX96: 0
            })
        );
        WoolFiLiquidityZapper.ZapParams memory p = WoolFiLiquidityZapper.ZapParams({
            key: key,
            tokenIn: TOK_USDG,
            amountIn: zapIn,
            swap0: WoolFiLiquidityZapper.SwapPlan(address(0), address(0), 0, 0, ""),
            swap1: WoolFiLiquidityZapper.SwapPlan({
                executor: V3_ROUTER,
                tokenOut: TOK_NVDA,
                amountIn: swapIn,
                minAmountOut: quoted * 99 / 100,
                data: routerCall
            }),
            minShares: 1,
            deadline: block.timestamp + 1 hours,
            recipient: alice
        });

        deal(TOK_USDG, alice, zapIn);
        vm.prank(alice);
        IERC20(TOK_USDG).approve(address(zapper), zapIn);
        vm.prank(alice);
        uint128 shares = zapper.zap(p);

        uint256 usdgDust = IERC20(TOK_USDG).balanceOf(alice);
        uint256 nvdaDust = IERC20(TOK_NVDA).balanceOf(alice);
        emit log_named_uint("alice LP shares", shares);
        emit log_named_uint("USDG refunded (6 dec)", usdgDust);
        emit log_named_uint("NVDA refunded (18 dec)", nvdaDust);

        assertGt(shares, 0, "LP shares minted");
        assertEq(pm.balanceOf(alice, uint256(PoolId.unwrap(key.toId()))), shares, "shares credited to alice");
        assertEq(IERC20(TOK_USDG).balanceOf(address(zapper)), 0, "zapper holds no USDG");
        assertEq(IERC20(TOK_NVDA).balanceOf(address(zapper)), 0, "zapper holds no NVDA");
        assertEq(IERC20(TOK_USDG).allowance(address(zapper), V3_ROUTER), 0, "router approval reset");
        assertEq(IERC20(TOK_USDG).allowance(address(zapper), address(pm)), 0, "pm USDG approval reset");
        assertEq(IERC20(TOK_NVDA).allowance(address(zapper), address(pm)), 0, "pm NVDA approval reset");
        assertGt(usdgDust + nvdaDust, 0, "unused leg refunded to payer");
    }

    // ------------------------------------------------------------------
    // 5. GLD feed vs live Uniswap v3 GLD/USDG price
    // ------------------------------------------------------------------

    function test_fork_gldFeedMatchesMarket() public onlyOnFork {
        (bool ok, bytes memory raw) = FEED_GLD.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok, "GLD feed read failed");
        (, int256 answer,,,) = abi.decode(raw, (uint80, int256, uint256, uint256, uint80));
        uint256 clWad = uint256(answer) * 1e10; // 8 decimals -> WAD

        (bool mOk, bytes memory mRaw) = TOK_GLD.staticcall(abi.encodeWithSignature("uiMultiplier()"));
        if (mOk && mRaw.length == 32) emit log_named_uint("GLD uiMultiplier", abi.decode(mRaw, (uint256)));

        // Deepest GLD/USDG v3 pool by USDG reserve.
        uint24[3] memory fees = [uint24(500), 3000, 10000];
        address best;
        uint256 bestUsdg;
        for (uint256 i; i < 3; ++i) {
            address pool = _getPool(TOK_USDG, TOK_GLD, fees[i]);
            if (pool == address(0)) continue;
            uint256 bal = IERC20(TOK_USDG).balanceOf(pool);
            if (bal > bestUsdg) (best, bestUsdg) = (pool, bal);
        }
        require(best != address(0), "no GLD/USDG v3 pool");
        (bool sOk, bytes memory sRaw) = best.staticcall(abi.encodeWithSignature("slot0()"));
        require(sOk, "slot0 failed");
        uint160 sqrtP = abi.decode(sRaw, (uint160));
        // token0 = USDG (6 dec), token1 = GLD (18 dec). USD per GLD (WAD) = 1e30 * 2^192 / sqrtP^2.
        uint256 v3Wad = FullMath.mulDiv(FullMath.mulDiv(1e30, 1 << 96, sqrtP), 1 << 96, sqrtP);

        emit log_named_address("deepest GLD/USDG v3 pool", best);
        emit log_named_uint("pool USDG reserve (6 dec)", bestUsdg);
        emit log_named_decimal_uint("Chainlink GLD/USD", clWad, 18);
        emit log_named_decimal_uint("Uniswap v3 GLD/USDG", v3Wad, 18);
        uint256 diffBps = (clWad > v3Wad ? clWad - v3Wad : v3Wad - clWad) * 10_000 / v3Wad;
        emit log_named_uint("difference (bps)", diffBps);
        assertLt(diffBps, 300, "Chainlink GLD within 3% of deepest v3 pool");
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deployCore() private {
        Deploy script = new Deploy();
        Deploy.Deployment memory dep = script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), me);
        hook = WoolFiHook(dep.hook);
        governor = WoolFiGovernor(dep.governor);
        governor.acceptOwnership();
        pm = WoolFiPositionManager(dep.positionManager);
        router = new WoolFiSwapRouter(IPoolManager(POOL_MANAGER), IFeeRebateDistributor(address(0)));
        hours_ = new MockMarketHours(true);
    }

    /// @dev MSTR/USDG pool seeded with 100k USDG-equivalent per side, outside any stabilization
    ///      window. Returns the MSTR seed size.
    function _setupMstrUsdg(uint32 stabilization, uint32 maxSkew) private returns (uint256 mstrSeed) {
        _deployCore();
        oracle0 = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);
        oracle1 = new RobinhoodStockOracleAdapter(TOK_MSTR, FEED_MSTR, address(0), FORK_HEARTBEAT, 0);
        _authorizeAndInit(TOK_USDG, TOK_MSTR, oracle0, oracle1, 6, 18, stabilization, maxSkew);
        hours_.setSessionStart(block.timestamp - 1 days);
        mstrSeed = _equivalent(100_000e6, 6, 18);
        _seed(TOK_USDG, TOK_MSTR, 100_000e6, mstrSeed);
    }

    function _authorizeAndInit(
        address t0,
        address t1,
        IPriceOracle o0,
        IPriceOracle o1,
        uint8 d0,
        uint8 d1,
        uint32 stabilization,
        uint32 maxSkew
    ) private {
        oracle0 = o0;
        oracle1 = o1;
        key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        governor.authorizePoolV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: o0,
                    oracle1: o1,
                    marketHours: IMarketHoursOracle(address(hours_)),
                    kScaled: 40_000,
                    baseFeeBps: BASE_FEE,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: stabilization, maxOracleSkew: maxSkew})
            })
        );
        IPoolManager(POOL_MANAGER).initialize(key, _sqrtPriceX96(o0.getPrice(), o1.getPrice(), d0, d1));
        pm.setFeeConfig(key, address(0), 0, treasury, 1000);
    }

    function _seed(address t0, address t1, uint256 a0, uint256 a1) private {
        deal(t0, lp, a0 * 12 / 10);
        deal(t1, lp, a1 * 12 / 10);
        vm.startPrank(lp);
        IERC20(t0).approve(address(pm), type(uint256).max);
        IERC20(t1).approve(address(pm), type(uint256).max);
        uint128 shares = pm.mint(key, a0, a1, lp);
        vm.stopPrank();
        assertGt(shares, 0, "seed shares");
    }

    /// @dev token1 amount worth `amount0` of token0 at the current oracle fair price.
    function _equivalent(uint256 amount0, uint8 d0, uint8 d1) private view returns (uint256) {
        return FullMath.mulDiv(amount0 * 10 ** (d1 - d0), oracle0.getPrice(), oracle1.getPrice());
    }

    /// @dev Adversarial flow when the pool sits ABOVE fair: sell token1 (MSTR) into it. Returns the
    ///      LP fee the hook applied (read from the hook's transient slot in this same tx).
    function _smallAdversarialSwapFee(uint256 mstrSeed) private returns (uint256 feeBps) {
        uint256 amount = mstrSeed / 1000;
        FeeProbe probe = new FeeProbe();
        deal(TOK_MSTR, address(probe), amount);
        feeBps = probe.swapAndReadFee(router, hook, key, false, amount);
    }

    function _assertBigAdversarialSwapRevertsWith(bytes4 selector, uint256 mstrSeed) private {
        uint256 amount = mstrSeed / 10;
        deal(TOK_MSTR, trader, amount);
        vm.startPrank(trader);
        IERC20(TOK_MSTR).approve(address(router), type(uint256).max);
        (bool ok, bytes memory reason) =
            address(router).call(abi.encodeCall(WoolFiSwapRouter.swap, (key, false, amount, 1, trader, "")));
        vm.stopPrank();
        assertFalse(ok, "threshold-crossing swap must revert");
        assertTrue(_containsSelector(reason, selector), "revert carries expected hook error");
    }

    function _assertMintRevertsWith(bytes4 selector, uint256 mstrSeed) private {
        deal(TOK_USDG, lp, 1_000e6);
        deal(TOK_MSTR, lp, mstrSeed / 100);
        vm.startPrank(lp);
        (bool ok, bytes memory reason) = address(pm)
            .call(
                abi.encodeWithSignature(
                    "mint((address,address,uint24,int24,address),uint256,uint256,address)",
                    key,
                    uint256(1_000e6),
                    mstrSeed / 100,
                    lp
                )
            );
        vm.stopPrank();
        assertFalse(ok, "deposit must revert");
        assertTrue(_containsSelector(reason, selector), "deposit revert carries expected hook error");
    }

    /// @dev Hook errors surface wrapped by the PoolManager (WrappedError(target, sel, reason, ...)),
    ///      so search the raw revert bytes for the 4-byte selector.
    function _containsSelector(bytes memory data, bytes4 selector) private pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; ++i) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    /// @dev Scale a feed's live answer by pct/100 and shift its updatedAt back by `ageBy` seconds.
    function _scaleFeed(address feed, int256 pct, uint256 ageBy) private {
        (uint80 r, int256 a, uint256 s, uint256 u, uint80 ar) = _readFeed(feed);
        vm.mockCall(feed, abi.encodeWithSignature("latestRoundData()"), abi.encode(r, a * pct / 100, s, u - ageBy, ar));
    }

    /// @dev Make a feed's latest round look `secs` older than the other leg (price unchanged).
    function _ageFeed(address feed, uint256 secs) private {
        (uint80 r, int256 a, uint256 s,, uint80 ar) = _readFeed(feed);
        // Anchor to the MSTR leg's (possibly mocked) timestamp so the gap is exactly `secs`.
        (,,, uint256 mstrAt,) = _readFeed(FEED_MSTR);
        uint256 target = mstrAt > secs ? mstrAt - secs : 1;
        vm.mockCall(feed, abi.encodeWithSignature("latestRoundData()"), abi.encode(r, a, s, target, ar));
    }

    function _readFeed(address feed) private view returns (uint80, int256, uint256, uint256, uint80) {
        (bool ok, bytes memory raw) = feed.staticcall(abi.encodeWithSignature("latestRoundData()"));
        require(ok, "feed read failed");
        return abi.decode(raw, (uint80, int256, uint256, uint256, uint80));
    }

    function _quote(address tokenIn, address tokenOut, uint256 amountIn, uint24 fee) private returns (uint256) {
        (bool ok, bytes memory raw) = V3_QUOTER.call(
            abi.encodeWithSelector(
                bytes4(0xc6a5026a),
                QuoteExactInputSingleParams({
                    tokenIn: tokenIn, tokenOut: tokenOut, amountIn: amountIn, fee: fee, sqrtPriceLimitX96: 0
                })
            )
        );
        require(ok, "quoter call failed");
        (uint256 amountOut,,,) = abi.decode(raw, (uint256, uint160, uint32, uint256));
        return amountOut;
    }

    function _getPool(address a, address b, uint24 fee) private view returns (address pool) {
        (bool ok, bytes memory raw) =
            V3_FACTORY.staticcall(abi.encodeWithSignature("getPool(address,address,uint24)", a, b, fee));
        if (ok && raw.length == 32) pool = abi.decode(raw, (address));
    }

    function _sqrtPriceX96(uint256 price0Wad, uint256 price1Wad, uint8 dec0, uint8 dec1)
        private
        pure
        returns (uint160)
    {
        uint256 twoTo192 = uint256(1) << 192;
        uint256 ratioX192 = dec1 >= dec0
            ? FullMath.mulDiv(price0Wad * 10 ** uint256(dec1 - dec0), twoTo192, price1Wad)
            : FullMath.mulDiv(price0Wad, twoTo192, price1Wad * 10 ** uint256(dec0 - dec1));
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }
}
