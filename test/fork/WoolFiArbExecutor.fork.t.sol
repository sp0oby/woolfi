// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiSwapRouter} from "../../src/WoolFiSwapRouter.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {IFeeRebateDistributor} from "../../src/interfaces/IFeeRebateDistributor.sol";
import {WoolFiArbExecutor, IV3SwapRouter02} from "../../src/periphery/WoolFiArbExecutor.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @notice Live Robinhood Chain fork: a WoolFi WETH/USDG pool is knocked off its Chainlink fair
///         price, then the zero-capital executor arbitrages it against the real Uniswap v3
///         WETH/USDG pool, earning a profit while pulling the WoolFi pool back toward fair.
/// @dev Skips without ROBINHOOD_RPC_URL. Run this suite alone (the public RPC rate-limits).
contract WoolFiArbExecutorForkTest is Test {
    uint256 private constant FORK_HEARTBEAT = 7 days;
    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;
    address private constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant FEED_ETH = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address private constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address private constant V3_ROUTER = 0xCaf681a66D020601342297493863E78C959E5cb2;
    uint24 private constant V3_FEE = 100; // deepest WETH/USDG v3 tier (~$27M)

    address me = address(this);
    address lp = makeAddr("lp");
    address trader = makeAddr("trader");
    address searcher = makeAddr("searcher");

    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiSwapRouter router;
    WoolFiArbExecutor executor;
    IPriceOracle wethOracle;
    IPriceOracle usdgOracle;
    PoolKey key;

    modifier onlyOnFork() {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == 4663, "wrong chain forked");
        _;
    }

    function test_fork_arbRestoresPoolAndProfits() public onlyOnFork {
        _setUpPool();

        int256 driftBefore = hook.currentDrift(key);
        _knockPoolOffFair();
        int256 driftOff = hook.currentDrift(key);
        emit log_named_int("drift at fair (bps)", driftBefore);
        emit log_named_int("drift after shock (bps)", driftOff);
        assertLt(driftOff, -300, "pool knocked >3% below fair");

        // Pool WETH is cheap vs Chainlink: corrective = buy WETH on WoolFi with USDG, sell on v3.
        (uint256 bestIn, uint256 bestProfit) = _bestSize();
        emit log_named_uint("chosen USDG in (6dp)", bestIn);
        emit log_named_uint("simulated profit USDG (6dp)", bestProfit);
        assertGt(bestProfit, 0, "a profitable size exists");

        uint256 searcherUsdgBefore = IERC20(USDG).balanceOf(searcher);
        vm.prank(searcher);
        uint256 profit = executor.execute(_params(bestIn, 1));
        int256 driftAfter = hook.currentDrift(key);

        emit log_named_uint("realized profit USDG (6dp)", profit);
        emit log_named_int("drift after arb (bps)", driftAfter);
        assertGt(profit, 0, "realized profit");
        assertEq(IERC20(USDG).balanceOf(searcher) - searcherUsdgBefore, profit, "searcher paid, fronted nothing");
        assertGt(driftAfter, driftOff, "arb moved pool back toward fair");
        assertEq(IERC20(USDG).balanceOf(address(executor)), 0, "no USDG residue");
        assertEq(IERC20(WETH).balanceOf(address(executor)), 0, "no WETH residue");
        assertEq(IERC20(WETH).allowance(address(executor), V3_ROUTER), 0, "approval reset");
    }

    function test_fork_unprofitableRunReverts() public onlyOnFork {
        _setUpPool();
        _knockPoolOffFair();
        (uint256 bestIn, uint256 bestProfit) = _bestSize();
        vm.expectRevert();
        executor.execute(_params(bestIn, bestProfit * 10 + 1e12));
    }

    // ---------------------------------------------------------------------------------------

    function _params(uint256 usdgIn, uint256 minProfit) private view returns (WoolFiArbExecutor.ArbParams memory) {
        return WoolFiArbExecutor.ArbParams({
            woolfiKey: key,
            zeroForOne: false, // sell USDG (currency1) for WETH (currency0) on WoolFi
            amountIn: usdgIn,
            v3Fee: V3_FEE,
            minProfit: minProfit,
            profitToken: USDG,
            recipient: searcher,
            deadline: block.timestamp + 60
        });
    }

    /// @dev Step candidate sizes via eth_call-style simulation (snapshot + revert), keep the best.
    function _bestSize() private returns (uint256 bestIn, uint256 bestProfit) {
        uint256[6] memory sizes = [uint256(250e6), 500e6, 1_000e6, 2_000e6, 3_000e6, 5_000e6];
        for (uint256 i; i < sizes.length; ++i) {
            uint256 snap = vm.snapshotState();
            try executor.execute(_params(sizes[i], 0)) returns (uint256 p) {
                if (p > bestProfit) (bestIn, bestProfit) = (sizes[i], p);
            } catch {}
            vm.revertToState(snap);
        }
    }

    function _setUpPool() private {
        Deploy script = new Deploy();
        Deploy.Deployment memory dep = script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), me);
        WoolFiGovernor governor = WoolFiGovernor(dep.governor);
        governor.acceptOwnership();
        hook = WoolFiHook(dep.hook);
        pm = WoolFiPositionManager(dep.positionManager);
        router = new WoolFiSwapRouter(IPoolManager(POOL_MANAGER), IFeeRebateDistributor(address(0)));
        executor = new WoolFiArbExecutor(IPoolManager(POOL_MANAGER), IV3SwapRouter02(V3_ROUTER));

        wethOracle = new ChainlinkOracleAdapter(FEED_ETH, FORK_HEARTBEAT);
        usdgOracle = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);
        require(uint160(WETH) < uint160(USDG), "WETH must be token0");

        key = PoolKey({
            currency0: Currency.wrap(WETH),
            currency1: Currency.wrap(USDG),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        governor.authorizePoolV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: wethOracle,
                    oracle1: usdgOracle,
                    marketHours: IMarketHoursOracle(address(0)), // always open
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0})
            })
        );
        uint256 p0 = wethOracle.getPrice();
        uint256 p1 = usdgOracle.getPrice();
        IPoolManager(POOL_MANAGER).initialize(key, _sqrtPriceX96(p0, p1));

        // Seed: 20 WETH + matching USDG at fair (~$100k total).
        uint256 wethSeed = 20e18;
        uint256 usdgSeed = FullMath.mulDiv(wethSeed, p0, p1) / 1e12;
        deal(WETH, lp, wethSeed * 2);
        deal(USDG, lp, usdgSeed * 2);
        vm.startPrank(lp);
        IERC20(WETH).approve(address(pm), type(uint256).max);
        IERC20(USDG).approve(address(pm), type(uint256).max);
        pm.mint(key, wethSeed, usdgSeed, lp);
        vm.stopPrank();
    }

    /// @dev A trader dumps ~3.5% of the pool's WETH: pool price falls ~7%, under the 15% guard.
    function _knockPoolOffFair() private {
        uint256 dump = 0.7e18;
        deal(WETH, trader, dump);
        vm.startPrank(trader);
        IERC20(WETH).approve(address(router), type(uint256).max);
        router.swap(key, true, dump, 1, trader, "");
        vm.stopPrank();
    }

    function _sqrtPriceX96(uint256 price0Wad, uint256 price1Wad) private pure returns (uint160) {
        // token0 WETH (18 dp), token1 USDG (6 dp): raw ratio = p0/p1 * 10^(6-18).
        uint256 ratioX192 = FullMath.mulDiv(price0Wad, uint256(1) << 192, price1Wad * 1e12);
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }
}
