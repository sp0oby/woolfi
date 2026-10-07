// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiArbExecutor, IV3SwapRouter02} from "../../src/periphery/WoolFiArbExecutor.sol";

/// @dev Stand-in for a deep v3 pool: pays `rateBps / 10_000` of tokenOut per tokenIn from its own
///      balance and honours `amountOutMinimum` the way SwapRouter02 does.
contract MockV3Router {
    uint256 public rateBps;

    function setRateBps(uint256 r) external {
        rateBps = r;
    }

    function exactInputSingle(IV3SwapRouter02.ExactInputSingleParams calldata p) external returns (uint256 out) {
        IERC20(p.tokenIn).transferFrom(msg.sender, address(this), p.amountIn);
        out = p.amountIn * rateBps / 10_000;
        require(out >= p.amountOutMinimum, "Too little received");
        IERC20(p.tokenOut).transfer(p.recipient, out);
    }
}

/// @notice Executor mechanics against a real v4 PoolManager (hookless pool; the executor is
///         hook-agnostic) and a mock v3 hedge venue with a controllable rate.
contract WoolFiArbExecutorTest is Deployers {
    WoolFiArbExecutor executor;
    MockV3Router v3;
    PoolKey poolKey;
    address searcher = makeAddr("searcher");
    address payee = makeAddr("payee");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        (poolKey,) = initPoolAndAddLiquidity(currency0, currency1, IHooks(address(0)), 3000, SQRT_PRICE_1_1);

        v3 = new MockV3Router();
        executor = new WoolFiArbExecutor(manager, IV3SwapRouter02(address(v3)));
        // Fund the hedge venue so it can pay out either token.
        IERC20(Currency.unwrap(currency0)).transfer(address(v3), 1e24);
        IERC20(Currency.unwrap(currency1)).transfer(address(v3), 1e24);
    }

    function _params(uint256 amountIn, uint256 minProfit) internal view returns (WoolFiArbExecutor.ArbParams memory) {
        return WoolFiArbExecutor.ArbParams({
            woolfiKey: poolKey,
            zeroForOne: true,
            amountIn: amountIn,
            v3Fee: 500,
            minProfit: minProfit,
            profitToken: Currency.unwrap(currency0),
            recipient: payee,
            deadline: block.timestamp + 60
        });
    }

    function test_execute_profitPath_paysRecipient_noCapital_noResidue() public {
        v3.setRateBps(10_500); // hedge venue pays 5% more than the v4 pool's ~1:1
        uint256 searcherBefore0 = IERC20(Currency.unwrap(currency0)).balanceOf(searcher);

        vm.prank(searcher);
        uint256 profit = executor.execute(_params(1e15, 1));

        assertGt(profit, 0, "profit");
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(payee), profit, "recipient paid in tokenIn");
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(searcher), searcherBefore0, "caller fronted nothing");
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(executor)), 0, "no tokenIn residue");
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(executor)), 0, "no tokenOut residue");
        assertEq(IERC20(Currency.unwrap(currency1)).allowance(address(executor), address(v3)), 0, "approval reset");
        assertEq(IERC20(Currency.unwrap(currency0)).allowance(address(executor), address(v3)), 0, "no stray approval");
    }

    function testRevert_execute_belowMinProfit() public {
        v3.setRateBps(10_500);
        WoolFiArbExecutor.ArbParams memory p = _params(1e15, 1e18);
        vm.expectRevert(); // InsufficientProfit(profit, 1e18)
        executor.execute(p);
    }

    function testRevert_execute_unprofitableHedgeNeverSettlesAtLoss() public {
        v3.setRateBps(9_000); // hedge returns less than owed
        vm.expectRevert();
        executor.execute(_params(1e15, 0));
    }

    function testRevert_execute_deadline() public {
        v3.setRateBps(10_500);
        WoolFiArbExecutor.ArbParams memory p = _params(1e15, 0);
        p.deadline = block.timestamp - 1;
        vm.expectRevert(abi.encodeWithSelector(WoolFiArbExecutor.DeadlineExpired.selector, p.deadline));
        executor.execute(p);
    }

    function testRevert_execute_wrongProfitToken() public {
        WoolFiArbExecutor.ArbParams memory p = _params(1e15, 0);
        p.profitToken = Currency.unwrap(currency1);
        vm.expectRevert(
            abi.encodeWithSelector(
                WoolFiArbExecutor.InvalidProfitToken.selector, Currency.unwrap(currency0), Currency.unwrap(currency1)
            )
        );
        executor.execute(p);
    }

    function testRevert_execute_zeroAmount() public {
        vm.expectRevert(WoolFiArbExecutor.ZeroAmount.selector);
        executor.execute(_params(0, 0));
    }

    function testRevert_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(WoolFiArbExecutor.NotPoolManager.selector);
        executor.unlockCallback(abi.encode(_params(1, 0)));
    }

    function test_execute_reverseDirection() public {
        v3.setRateBps(10_500);
        WoolFiArbExecutor.ArbParams memory p = _params(1e15, 1);
        p.zeroForOne = false;
        p.profitToken = Currency.unwrap(currency1);
        uint256 profit = executor.execute(p);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(payee), profit);
        assertEq(IERC20(Currency.unwrap(currency0)).allowance(address(executor), address(v3)), 0);
    }
}
