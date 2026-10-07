// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @notice Minimal Uniswap v3 SwapRouter02 surface (exactInputSingle has no deadline field).
interface IV3SwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// @title WoolFiArbExecutor
/// @notice Zero-capital, single-transaction arbitrage between a WoolFi v4 pool and a Uniswap v3
///         pool on the same pair. WoolFi discounts swaps that move a pool toward its oracle fair
///         price, so when a WoolFi pool drifts off fair the corrective trade there is cheap and the
///         hedge on the deep v3 pool closes the loop at a profit.
/// @dev Uses v4 flash accounting: inside `PoolManager.unlock` the executor swaps on the WoolFi pool
///      (owing tokenIn, owed tokenOut), takes tokenOut, sells it on v3 for tokenIn, settles the
///      tokenIn debt, and sends the surplus to `recipient`. The caller fronts nothing but gas.
///      Permissionless, ownerless, holds no funds between transactions, and resets every approval
///      it grants. Native-ETH legs are unsupported (WoolFi pools are ERC20/ERC20).
contract WoolFiArbExecutor is IUnlockCallback, ReentrancyGuard {
    struct ArbParams {
        PoolKey woolfiKey;
        bool zeroForOne; // WoolFi-side direction: true sells currency0 for currency1
        uint256 amountIn; // exact tokenIn sold into the WoolFi pool
        uint24 v3Fee; // fee tier of the v3 hedge pool
        uint256 minProfit; // in tokenIn units
        address profitToken; // must equal tokenIn; explicit so callers can't misread the unit
        address recipient;
        uint256 deadline;
    }

    IPoolManager public immutable poolManager;
    IV3SwapRouter02 public immutable v3Router;

    event Arbitrage(
        bytes32 indexed poolId, address indexed recipient, address tokenIn, uint256 amountIn, uint256 profit
    );

    error NotPoolManager();
    error DeadlineExpired(uint256 deadline);
    error ZeroAmount();
    error ZeroAddress();
    error NativeCurrencyUnsupported();
    error InvalidProfitToken(address expected, address provided);
    error InsufficientProfit(uint256 profit, uint256 minProfit);
    error HedgeShortfall(uint256 received, uint256 owed);

    constructor(IPoolManager poolManager_, IV3SwapRouter02 v3Router_) {
        if (address(poolManager_) == address(0) || address(v3Router_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        v3Router = v3Router_;
    }

    /// @notice Run one corrective arbitrage. Reverts unless profit (in tokenIn) is at least `minProfit`.
    /// @return profit tokenIn sent to `p.recipient`.
    function execute(ArbParams calldata p) external nonReentrant returns (uint256 profit) {
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.amountIn == 0) revert ZeroAmount();
        if (p.recipient == address(0)) revert ZeroAddress();
        (address tokenIn,) = _tokens(p.woolfiKey, p.zeroForOne);
        if (p.profitToken != tokenIn) revert InvalidProfitToken(tokenIn, p.profitToken);

        profit = abi.decode(poolManager.unlock(abi.encode(p)), (uint256));
        if (profit < p.minProfit) revert InsufficientProfit(profit, p.minProfit);

        SafeTransferLib.safeTransfer(tokenIn, p.recipient, profit);
        emit Arbitrage(keccak256(abi.encode(p.woolfiKey)), p.recipient, tokenIn, p.amountIn, profit);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        ArbParams memory p = abi.decode(raw, (ArbParams));
        (address tokenIn, address tokenOut) = _tokens(p.woolfiKey, p.zeroForOne);

        // 1. Corrective swap on WoolFi: exact input of tokenIn.
        BalanceDelta delta = poolManager.swap(
            p.woolfiKey,
            IPoolManager.SwapParams({
                zeroForOne: p.zeroForOne,
                amountSpecified: -int256(p.amountIn),
                sqrtPriceLimitX96: p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (int128 dIn, int128 dOut) =
            p.zeroForOne ? (delta.amount0(), delta.amount1()) : (delta.amount1(), delta.amount0());
        uint256 owed = uint256(uint128(-dIn));
        uint256 gotOut = uint256(uint128(dOut));

        // 2. Take tokenOut from the PoolManager and hedge it on v3 back into tokenIn.
        poolManager.take(Currency.wrap(tokenOut), address(this), gotOut);
        SafeTransferLib.safeApproveWithRetry(tokenOut, address(v3Router), gotOut);
        uint256 received = v3Router.exactInputSingle(
            IV3SwapRouter02.ExactInputSingleParams({
                tokenIn: tokenOut,
                tokenOut: tokenIn,
                fee: p.v3Fee,
                recipient: address(this),
                amountIn: gotOut,
                amountOutMinimum: owed, // never settle at a loss; the outer check enforces minProfit
                sqrtPriceLimitX96: 0
            })
        );
        SafeTransferLib.safeApproveWithRetry(tokenOut, address(v3Router), 0);
        if (received < owed) revert HedgeShortfall(received, owed);

        // 3. Settle the tokenIn debt to the PoolManager; the surplus stays here for `execute` to pay out.
        poolManager.sync(Currency.wrap(tokenIn));
        SafeTransferLib.safeTransfer(tokenIn, address(poolManager), owed);
        poolManager.settle();

        return abi.encode(received - owed);
    }

    function _tokens(PoolKey memory key, bool zeroForOne) private pure returns (address tokenIn, address tokenOut) {
        address c0 = Currency.unwrap(key.currency0);
        address c1 = Currency.unwrap(key.currency1);
        if (c0 == address(0) || c1 == address(0)) revert NativeCurrencyUnsupported();
        (tokenIn, tokenOut) = zeroForOne ? (c0, c1) : (c1, c0);
    }
}
