// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiPoolAligner} from "../../src/periphery/WoolFiPoolAligner.sol";
import {RobinhoodStockOracleAdapter} from "../../src/oracle/RobinhoodStockOracleAdapter.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @notice Unseeded-pool launch on live Robinhood Chain state: an NVDA/USDG pool initialized 10% off
///         live Chainlink blocks the first LP (OutOfBand) until the aligner moves it to fair for free.
/// @dev Skips without ROBINHOOD_RPC_URL.
contract WoolFiPoolAlignerForkTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 private constant FORK_HEARTBEAT = 7 days;

    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;
    address private constant TOK_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant TOK_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address private constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;
    address private constant FEED_NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;

    address lp = makeAddr("lp");
    address anyone = makeAddr("anyone");

    function test_fork_unseededNvdaUsdg_alignUnblocksFirstLp() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain forked");
        assertLt(uint160(TOK_USDG), uint160(TOK_NVDA), "USDG is currency0");

        Deploy script = new Deploy();
        Deploy.Deployment memory dep =
            script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), address(this));
        WoolFiHook hook = WoolFiHook(dep.hook);
        WoolFiGovernor governor = WoolFiGovernor(dep.governor);
        governor.acceptOwnership();
        WoolFiPositionManager pm = WoolFiPositionManager(dep.positionManager);
        MockMarketHours hours_ = new MockMarketHours(true);
        hours_.setSessionStart(block.timestamp - 1 days);

        IPriceOracle usdg = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);
        IPriceOracle nvda = new RobinhoodStockOracleAdapter(TOK_NVDA, FEED_NVDA, address(0), FORK_HEARTBEAT, 0);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(TOK_USDG),
            currency1: Currency.wrap(TOK_NVDA),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        governor.authorizePoolV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: usdg,
                    oracle1: nvda,
                    marketHours: IMarketHoursOracle(address(hours_)),
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0})
            })
        );
        // Stale launch price: 10% off live Chainlink, no liquidity (an unseeded pool weeks after launch).
        IPoolManager(POOL_MANAGER).initialize(key, _sqrtPriceX96(usdg.getPrice() * 110 / 100, nvda.getPrice()));
        pm.setFeeConfig(key, address(0), 0, makeAddr("treasury"), 1000);

        int256 before = hook.currentDrift(key);
        emit log_named_int("drift before align (bps)", before);
        assertGt(before, 500, "out of band");

        uint256 nvdaUsd = nvda.getPrice();
        uint256 nvdaAmount = 10_000e18 * 1e18 / nvdaUsd; // ~$10k of NVDA
        deal(TOK_USDG, lp, 10_000e6);
        deal(TOK_NVDA, lp, nvdaAmount);
        vm.startPrank(lp);
        IERC20(TOK_USDG).approve(address(pm), type(uint256).max);
        IERC20(TOK_NVDA).approve(address(pm), type(uint256).max);
        vm.expectRevert(); // hook OutOfBand, wrapped by the PoolManager
        pm.mint(key, 10_000e6, nvdaAmount, lp);
        vm.stopPrank();

        WoolFiPoolAligner aligner = new WoolFiPoolAligner(IPoolManager(POOL_MANAGER));
        uint256 g = gasleft();
        vm.prank(anyone);
        assertTrue(aligner.align(key));
        emit log_named_uint("align gas (live fork)", g - gasleft());
        assertEq(IERC20(TOK_USDG).balanceOf(anyone) + IERC20(TOK_NVDA).balanceOf(anyone), 0, "caller paid nothing");

        int256 afterDrift = hook.currentDrift(key);
        emit log_named_int("drift after align (bps)", afterDrift);
        assertEq(afterDrift, 0);

        vm.prank(lp);
        uint128 shares = pm.mint(key, 10_000e6, nvdaAmount, lp);
        emit log_named_uint("first LP shares", shares);
        assertGt(shares, 0, "first LP mints after align");
        assertEq(IPoolManager(POOL_MANAGER).getLiquidity(key.toId()), shares);
    }

    /// @dev token0 = USDG (6 decimals), token1 = NVDA (18 decimals).
    function _sqrtPriceX96(uint256 price0Wad, uint256 price1Wad) private pure returns (uint160) {
        uint256 ratioX192 = FullMath.mulDiv(price0Wad * 1e12, uint256(1) << 192, price1Wad);
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }
}
