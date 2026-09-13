// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH} from "solady/tokens/WETH.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiLiquidityZapper, IWoolFiPositionManagerMint} from "../../src/WoolFiLiquidityZapper.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

contract MockAllowedSwapExecutor {
    bytes public reentryData;
    bool public reentrySucceeded;

    function setReentry(bytes calldata data) external {
        reentryData = data;
    }

    function swap(address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut, address recipient) external {
        if (reentryData.length != 0) (reentrySucceeded,) = msg.sender.call(reentryData);
        IERC20(tokenIn).transferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenOut).transfer(recipient, amountOut);
    }

    function fail() external pure {
        revert("swap failed");
    }
}

contract WoolFiLiquidityZapperTest is Deployers {
    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiLiquidityZapper zapper;
    MockAllowedSwapExecutor executor;
    PoolKey woolfiKey;
    address alice = makeAddr("alice");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        hook = _deployHook();
        woolfiKey = _initialize(currency0, currency1);
        pm = new WoolFiPositionManager(manager, address(this));
        WETH weth = new WETH();
        zapper = new WoolFiLiquidityZapper(IWoolFiPositionManagerMint(address(pm)), address(weth), address(this));
        executor = new MockAllowedSwapExecutor();
        zapper.setExecutorAllowed(address(executor), true);

        IERC20(Currency.unwrap(currency0)).transfer(alice, 1_000e18);
        IERC20(Currency.unwrap(currency1)).transfer(address(executor), 1_000e18);
        vm.prank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(zapper), type(uint256).max);
    }

    function _deployHook() private returns (WoolFiHook deployedHook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x7777) << 144));
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(this)), hookAddr);
        deployedHook = WoolFiHook(hookAddr);
    }

    function _initialize(Currency c0, Currency c1) private returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        hook.authorizePool(
            poolKey,
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
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _plan(address tokenIn, address tokenOut, uint256 amount)
        private
        view
        returns (WoolFiLiquidityZapper.SwapPlan memory)
    {
        return WoolFiLiquidityZapper.SwapPlan({
            executor: address(executor),
            tokenOut: tokenOut,
            amountIn: amount,
            minAmountOut: amount,
            data: abi.encodeCall(MockAllowedSwapExecutor.swap, (tokenIn, tokenOut, amount, amount, address(zapper)))
        });
    }

    function _emptyPlan() private pure returns (WoolFiLiquidityZapper.SwapPlan memory) {
        return WoolFiLiquidityZapper.SwapPlan(address(0), address(0), 0, 0, "");
    }

    function _params(
        PoolKey memory key,
        address tokenIn,
        uint256 amountIn,
        WoolFiLiquidityZapper.SwapPlan memory swap0,
        WoolFiLiquidityZapper.SwapPlan memory swap1
    ) private view returns (WoolFiLiquidityZapper.ZapParams memory) {
        return WoolFiLiquidityZapper.ZapParams({
            key: key,
            tokenIn: tokenIn,
            amountIn: amountIn,
            swap0: swap0,
            swap1: swap1,
            minShares: 1,
            deadline: block.timestamp,
            recipient: alice
        });
    }

    function test_zapPoolToken_mintsAndRefundsDust() public {
        address token0 = Currency.unwrap(currency0);
        address token1 = Currency.unwrap(currency1);
        uint256 before0 = IERC20(token0).balanceOf(alice);

        vm.prank(alice);
        uint128 shares = zapper.zap(_params(woolfiKey, token0, 100e18, _plan(token0, token1, 40e18), _emptyPlan()));

        assertGt(shares, 0);
        assertApproxEqAbs(before0 - IERC20(token0).balanceOf(alice), 80e18, 2);
        assertEq(IERC20(token0).balanceOf(address(zapper)), 0);
        assertEq(IERC20(token1).balanceOf(address(zapper)), 0);
        assertEq(IERC20(token0).allowance(address(zapper), address(executor)), 0);
    }

    function test_zapThirdToken_usesTwoRoutes() public {
        MockERC20 usdg = new MockERC20("USDG", "USDG", 6);
        usdg.mint(alice, 100e6);
        IERC20(Currency.unwrap(currency0)).transfer(address(executor), 50e18);
        vm.prank(alice);
        usdg.approve(address(zapper), 100e6);

        WoolFiLiquidityZapper.SwapPlan memory s0 = _plan(address(usdg), Currency.unwrap(currency0), 50e6);
        WoolFiLiquidityZapper.SwapPlan memory s1 = _plan(address(usdg), Currency.unwrap(currency1), 50e6);
        s0.minAmountOut = 50e18;
        s0.data = abi.encodeCall(
            MockAllowedSwapExecutor.swap, (address(usdg), Currency.unwrap(currency0), 50e6, 50e18, address(zapper))
        );
        s1.minAmountOut = 50e18;
        s1.data = abi.encodeCall(
            MockAllowedSwapExecutor.swap, (address(usdg), Currency.unwrap(currency1), 50e6, 50e18, address(zapper))
        );

        vm.prank(alice);
        uint128 shares = zapper.zap(_params(woolfiKey, address(usdg), 100e6, s0, s1));
        assertGt(shares, 0);
        assertEq(usdg.balanceOf(address(zapper)), 0);
    }

    function testRevert_zapRejectsUnapprovedExecutor() public {
        WoolFiLiquidityZapper.SwapPlan memory plan =
            _plan(Currency.unwrap(currency0), Currency.unwrap(currency1), 50e18);
        plan.executor = address(0xBEEF);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WoolFiLiquidityZapper.ExecutorNotAllowed.selector, address(0xBEEF)));
        zapper.zap(_params(woolfiKey, Currency.unwrap(currency0), 100e18, plan, _emptyPlan()));
    }

    function testRevert_zapEnforcesSwapMinimum() public {
        WoolFiLiquidityZapper.SwapPlan memory plan =
            _plan(Currency.unwrap(currency0), Currency.unwrap(currency1), 40e18);
        plan.minAmountOut = 41e18;
        vm.prank(alice);
        vm.expectRevert();
        zapper.zap(_params(woolfiKey, Currency.unwrap(currency0), 100e18, plan, _emptyPlan()));
    }

    function testRevert_zapEnforcesShareMinimumAndDeadline() public {
        WoolFiLiquidityZapper.ZapParams memory p = _params(
            woolfiKey,
            Currency.unwrap(currency0),
            100e18,
            _plan(Currency.unwrap(currency0), Currency.unwrap(currency1), 50e18),
            _emptyPlan()
        );
        p.minShares = type(uint128).max;
        vm.prank(alice);
        vm.expectPartialRevert(WoolFiPositionManager.InsufficientShares.selector);
        zapper.zap(p);

        p.minShares = 1;
        p.deadline = 99;
        vm.warp(100);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WoolFiLiquidityZapper.DeadlineExpired.selector, 99));
        zapper.zap(p);
    }

    function testRevert_zapBubblesExecutorFailure() public {
        WoolFiLiquidityZapper.SwapPlan memory plan =
            _plan(Currency.unwrap(currency0), Currency.unwrap(currency1), 50e18);
        plan.data = abi.encodeCall(MockAllowedSwapExecutor.fail, ());
        vm.prank(alice);
        vm.expectPartialRevert(WoolFiLiquidityZapper.SwapFailed.selector);
        zapper.zap(_params(woolfiKey, Currency.unwrap(currency0), 100e18, plan, _emptyPlan()));
    }

    function test_zapBlocksExecutorReentrancy() public {
        WoolFiLiquidityZapper.ZapParams memory p = _params(
            woolfiKey,
            Currency.unwrap(currency0),
            100e18,
            _plan(Currency.unwrap(currency0), Currency.unwrap(currency1), 50e18),
            _emptyPlan()
        );
        executor.setReentry(abi.encodeCall(WoolFiLiquidityZapper.zap, (p)));
        vm.prank(alice);
        zapper.zap(p);
        assertFalse(executor.reentrySucceeded());
    }

    function testRevert_executorPolicyOnlyOwner() public {
        vm.prank(alice);
        vm.expectRevert(WoolFiLiquidityZapper.NotOwner.selector);
        zapper.setExecutorAllowed(address(executor), false);
    }

    function test_nativeInput_wrapsAndRefundsAsEth() public {
        WETH weth = WETH(payable(zapper.wrappedNative()));
        MockERC20 other = new MockERC20("Other", "OTH", 18);
        Currency c0 = address(weth) < address(other) ? Currency.wrap(address(weth)) : Currency.wrap(address(other));
        Currency c1 = address(weth) < address(other) ? Currency.wrap(address(other)) : Currency.wrap(address(weth));
        PoolKey memory nativeKey = _initialize(c0, c1);
        other.mint(address(executor), 100e18);
        vm.deal(alice, 100e18);

        vm.prank(alice);
        uint128 shares = zapper.zap{value: 100e18}(
            _params(nativeKey, address(0), 100e18, _plan(address(weth), address(other), 40e18), _emptyPlan())
        );

        assertGt(shares, 0);
        assertApproxEqAbs(alice.balance, 20e18, 2);
        assertEq(weth.balanceOf(address(zapper)), 0);
        assertEq(other.balanceOf(address(zapper)), 0);
    }
}
