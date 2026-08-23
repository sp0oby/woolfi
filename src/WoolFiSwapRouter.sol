// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

/// @title WoolFiSwapRouter
/// @notice Minimal v4 swap router for WoolFi pools. Wraps `PoolManager.unlock` so end users can
///         swap with a single `approve` + `swap` from an EOA without writing their own callback.
/// @dev Exact-input ERC20 swaps only. The WoolFi hook prices the asymmetric fee from the supplied
///      `hookData` — see {WoolFiHook.beforeSwap}. We do not skim or modify deltas, so the only
///      WoolFi-specific state involved is whatever the hook returns inside the swap callback. Native
///      ETH is intentionally unsupported in v1; WoolFi pools are ERC20/ERC20.
contract WoolFiSwapRouter is IUnlockCallback, ReentrancyGuard {
    IPoolManager public immutable poolManager;

    error NotPoolManager();
    error ZeroAmount();
    error InsufficientOutput(uint256 received, uint256 minimum);

    event Swap(address indexed payer, address indexed recipient, bool zeroForOne, uint256 amountIn, uint256 amountOut);

    /// @dev Encoded across the `unlock` boundary.
    struct CallbackData {
        address payer;
        address recipient;
        PoolKey key;
        IPoolManager.SwapParams params;
        bytes hookData;
    }

    constructor(IPoolManager _manager) {
        poolManager = _manager;
    }

    /// @notice Swap `amountIn` of token-in for at least `amountOutMinimum` of token-out.
    /// @param key The pool to swap on. Must be a WoolFi pool (the hook validates).
    /// @param zeroForOne True to swap token0 -> token1, false to swap token1 -> token0.
    /// @param amountIn Amount of token-in (in wei). Must be > 0.
    /// @param amountOutMinimum Minimum acceptable output. Caller-supplied slippage bound; the
    ///        router reverts with {InsufficientOutput} if the swap would settle below this.
    /// @param recipient Address that receives token-out.
    /// @param hookData Passed verbatim to the hook in `beforeSwap` / `afterSwap`.
    /// @return amountOut Output the recipient actually received.
    function swap(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOutMinimum,
        address recipient,
        bytes calldata hookData
    ) external nonReentrant returns (uint256 amountOut) {
        if (amountIn == 0) revert ZeroAmount();

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            // negative = exact input
            amountSpecified: -int256(amountIn),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });

        bytes memory raw = poolManager.unlock(
            abi.encode(
                CallbackData({payer: msg.sender, recipient: recipient, key: key, params: params, hookData: hookData})
            )
        );
        amountOut = abi.decode(raw, (uint256));

        if (amountOut < amountOutMinimum) revert InsufficientOutput(amountOut, amountOutMinimum);
        emit Swap(msg.sender, recipient, zeroForOne, amountIn, amountOut);
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));

        BalanceDelta delta = poolManager.swap(d.key, d.params, d.hookData);

        // For an exact-input swap, the token-in delta is negative (we owe the pool) and the
        // token-out delta is positive (the pool owes us). We settle the input from the payer and
        // take the output to the recipient.
        (Currency cIn, Currency cOut, int128 dIn, int128 dOut) = d.params.zeroForOne
            ? (d.key.currency0, d.key.currency1, delta.amount0(), delta.amount1())
            : (d.key.currency1, d.key.currency0, delta.amount1(), delta.amount0());

        uint256 amountIn = _settle(cIn, d.payer, dIn);
        uint256 amountOut = _take(cOut, d.recipient, dOut);
        amountIn; // silence solc unused warning; emitted in {swap}.

        return abi.encode(amountOut);
    }

    /// @dev Pay the PoolManager the amount we owe. Pulls from `payer` via SafeTransferLib.
    function _settle(Currency currency, address payer, int128 delta) private returns (uint256 amount) {
        if (delta >= 0) return 0; // nothing owed
        amount = uint256(uint128(-delta));
        poolManager.sync(currency);
        // `payer` is the msg.sender of {swap}; encoded into a router-only struct passed across
        // `unlock` and `unlockCallback` is gated to the PoolManager. No external caller can
        // arrange for an unrelated address's tokens to be pulled.
        // slither-disable-next-line arbitrary-send-erc20
        SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
        poolManager.settle();
    }

    /// @dev Pull the amount we're owed from the PoolManager to `to`.
    function _take(Currency currency, address to, int128 delta) private returns (uint256 amount) {
        if (delta <= 0) return 0;
        amount = uint256(uint128(delta));
        poolManager.take(currency, to, amount);
    }
}
