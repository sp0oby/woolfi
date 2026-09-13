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
import {WoolFiLiquidityZapper, IWoolFiPositionManagerMint} from "../../src/WoolFiLiquidityZapper.sol";
import {RobinhoodStockOracleAdapter} from "../../src/oracle/RobinhoodStockOracleAdapter.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @notice Mock allowlisted swap executor. Same shape as the integration test's mock: pull
///         tokenIn via transferFrom, deliver tokenOut from own balance. Represents a
///         governance-approved DEX aggregator on a fork; no dependency on real V3 pool
///         liquidity on chain 4663.
contract MockZapExecutor {
    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);
    }
}

/// @notice Fork test: WoolFiLiquidityZapper end-to-end against real 4663 state. User has USDG
///         only, wants to mint MSTR/USDG LP shares. Zapper collects USDG, leaves half as USDG,
///         routes half through a governance-allowlisted executor to MSTR, mints LP shares, and
///         resets approvals.
/// @dev The executor is a mock rather than a real V3 router because chain 4663's V3 liquidity
///      for MSTR/USDG at any given fork block is not something we can assume. The zapper's own
///      logic (allowlist, approval reset, balance tracking, refund, min-shares) is what this
///      test exercises against real WoolFi + real tokens + real PoolManager.
contract WoolFiZapperForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 private constant FORK_HEARTBEAT = 7 days;

    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;
    address private constant TOK_MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address private constant TOK_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant TOK_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant FEED_MSTR = 0x396118bdFB181e6240E74D243F266B061c0edc3D;
    address private constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    address me = address(this);
    address lp1 = makeAddr("lp1");
    address alice = makeAddr("alice");
    address treasury = makeAddr("treasury");
    address rebalancer = makeAddr("rebalancer");

    WoolFiHook hook;
    WoolFiGovernor governor;
    WoolFiPositionManager pm;
    WoolFiLiquidityZapper zapper;
    MockZapExecutor executor;
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
        (bool ok, bytes memory data) = TOK_MSTR.staticcall(abi.encodeWithSignature("oraclePaused()"));
        if (ok && data.length == 32 && abi.decode(data, (bool))) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_fork_zapUsdgToMstrUsdgLp() public onlyOnFork {
        _setupPool();
        _seedInitialLiquidity();

        // Alice starts with 100 USDG only; wants MSTR/USDG LP shares.
        uint256 aliceUsdg = 100 * 10 ** 6;
        deal(TOK_USDG, alice, aliceUsdg);

        // Fund the mock executor with MSTR to hand out. Pretend the "market rate" is fair.
        uint256 price0 = usdgOracle.getPrice();
        uint256 price1 = mstrOracle.getPrice();
        uint256 usdgToSwap = 50 * 10 ** 6; // half of alice's input
        // fair MSTR out per USDG: usdgToSwap * 1e12 (upscale to 18 dec) * price0 / price1
        uint256 mstrOut = FullMath.mulDiv(usdgToSwap * 10 ** 12, price0, price1);
        deal(TOK_MSTR, address(executor), mstrOut * 2); // headroom for slippage/rounding
        emit log_named_uint("mstrOut synth", mstrOut);

        vm.prank(alice);
        IERC20(TOK_USDG).approve(address(zapper), type(uint256).max);

        WoolFiLiquidityZapper.SwapPlan memory swap0 = _emptyPlan(); // token0 = USDG = tokenIn, no swap
        WoolFiLiquidityZapper.SwapPlan memory swap1 = WoolFiLiquidityZapper.SwapPlan({
            executor: address(executor),
            tokenOut: TOK_MSTR,
            amountIn: usdgToSwap,
            minAmountOut: mstrOut * 95 / 100,
            data: abi.encodeCall(MockZapExecutor.swap, (TOK_USDG, TOK_MSTR, usdgToSwap, mstrOut, address(zapper)))
        });

        WoolFiLiquidityZapper.ZapParams memory params = WoolFiLiquidityZapper.ZapParams({
            key: key,
            tokenIn: TOK_USDG,
            amountIn: aliceUsdg,
            swap0: swap0,
            swap1: swap1,
            minShares: 1,
            deadline: block.timestamp + 1 hours,
            recipient: alice
        });

        vm.prank(alice);
        uint128 shares = zapper.zap(params);
        assertGt(shares, 0, "alice received LP shares");
        emit log_named_uint("alice LP shares", uint256(shares));

        // Zapper must reset its approvals to 0 after the mint.
        assertEq(IERC20(TOK_USDG).allowance(address(zapper), address(pm)), 0, "USDG approval reset");
        assertEq(IERC20(TOK_MSTR).allowance(address(zapper), address(pm)), 0, "MSTR approval reset");
        assertEq(IERC20(TOK_USDG).allowance(address(zapper), address(executor)), 0, "USDG-exec approval reset");

        // Alice is credited as the LP: her PM balance is nonzero, zapper's is zero.
        uint256 poolId = uint256(PoolId.unwrap(PoolIdLibrary.toId(key)));
        assertEq(pm.balanceOf(alice, poolId), uint256(shares), "PM shares owned by alice");
        assertEq(pm.balanceOf(address(zapper), poolId), 0, "zapper does not hold LP shares");

        // Zapper should not hold leftover MSTR/USDG (either the swap delivered exactly or the
        // refund path returned dust to alice).
        assertEq(IERC20(TOK_USDG).balanceOf(address(zapper)), 0, "no residual USDG in zapper");
        assertEq(IERC20(TOK_MSTR).balanceOf(address(zapper)), 0, "no residual MSTR in zapper");
    }

    function test_fork_zapRejectsUnallowedExecutor() public onlyOnFork {
        _setupPool();
        _seedInitialLiquidity();

        deal(TOK_USDG, alice, 100 * 10 ** 6);
        vm.prank(alice);
        IERC20(TOK_USDG).approve(address(zapper), type(uint256).max);

        MockZapExecutor rogue = new MockZapExecutor();
        // rogue is NOT allowlisted

        WoolFiLiquidityZapper.SwapPlan memory swap1 = WoolFiLiquidityZapper.SwapPlan({
            executor: address(rogue),
            tokenOut: TOK_MSTR,
            amountIn: 50 * 10 ** 6,
            minAmountOut: 0,
            data: abi.encodeCall(MockZapExecutor.swap, (TOK_USDG, TOK_MSTR, 50 * 10 ** 6, 0, address(zapper)))
        });
        WoolFiLiquidityZapper.ZapParams memory params = WoolFiLiquidityZapper.ZapParams({
            key: key,
            tokenIn: TOK_USDG,
            amountIn: 100 * 10 ** 6,
            swap0: _emptyPlan(),
            swap1: swap1,
            minShares: 1,
            deadline: block.timestamp + 1 hours,
            recipient: alice
        });
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WoolFiLiquidityZapper.ExecutorNotAllowed.selector, address(rogue)));
        zapper.zap(params);
    }

    // ---- setup helpers ----

    function _setupPool() private {
        Deploy script = new Deploy();
        Deploy.Deployment memory dep = script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), me);
        hook = WoolFiHook(dep.hook);
        governor = WoolFiGovernor(dep.governor);
        pm = WoolFiPositionManager(dep.positionManager);

        mstrOracle = new RobinhoodStockOracleAdapter(TOK_MSTR, FEED_MSTR, address(0), FORK_HEARTBEAT, 0);
        usdgOracle = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);
        MockMarketHours marketHours = new MockMarketHours(true);

        assertLt(uint160(TOK_USDG), uint160(TOK_MSTR), "USDG must sort below MSTR");
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

        uint256 price0 = usdgOracle.getPrice();
        uint256 price1 = mstrOracle.getPrice();
        uint160 sqrtPriceX96 = _sqrtPriceX96(price0, price1);
        IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);

        // Optional vault + fee routing so the pool is fully wired even if we don't use it here.
        WoolFiHook(dep.hook); // silence
        pm.setFeeConfig(key, address(0), 0, treasury, 1000);

        // Zapper + allowlisted mock executor.
        zapper = new WoolFiLiquidityZapper(IWoolFiPositionManagerMint(address(pm)), TOK_WETH, me);
        executor = new MockZapExecutor();
        zapper.setExecutorAllowed(address(executor), true);
    }

    function _seedInitialLiquidity() private {
        // A pre-existing LP anchors the pool so the zapper's mint isn't the first (avoids
        // beforeAddLiquidity band edge cases on a fresh pool). 100k USDG-equivalent.
        uint256 price0 = usdgOracle.getPrice();
        uint256 price1 = mstrOracle.getPrice();
        uint256 usdgSeed = 100_000 * 10 ** 6;
        uint256 mstrSeed = FullMath.mulDiv(usdgSeed * 10 ** 12, price0, price1);
        deal(TOK_USDG, lp1, usdgSeed * 12 / 10);
        deal(TOK_MSTR, lp1, mstrSeed * 12 / 10);
        vm.startPrank(lp1);
        IERC20(TOK_USDG).approve(address(pm), type(uint256).max);
        IERC20(TOK_MSTR).approve(address(pm), type(uint256).max);
        uint128 shares = pm.mint(key, usdgSeed, mstrSeed, lp1);
        vm.stopPrank();
        assertGt(shares, 0, "seed LP shares > 0");
    }

    function _emptyPlan() private pure returns (WoolFiLiquidityZapper.SwapPlan memory) {
        return WoolFiLiquidityZapper.SwapPlan(address(0), address(0), 0, 0, "");
    }

    function _sqrtPriceX96(uint256 price0Wad, uint256 price1Wad) private pure returns (uint160) {
        // USDG (dec0=6), MSTR (dec1=18): dec1 > dec0, so multiplier is 10^12.
        uint256 twoTo192 = uint256(1) << 192;
        uint256 ratioX192 = FullMath.mulDiv(price0Wad * 10 ** 12, twoTo192, price1Wad);
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }
}
