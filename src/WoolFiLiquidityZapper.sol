// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

interface IWoolFiPositionManagerMint {
    function mint(
        PoolKey calldata key,
        uint256 amount0Max,
        uint256 amount1Max,
        uint128 minShares,
        uint256 deadline,
        address to
    ) external returns (uint128 shares);
}

interface IWoolFiWrappedNative {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
}

/// @title WoolFiLiquidityZapper
/// @notice Converts one input asset into a WoolFi pool's two assets, then atomically mints LP shares.
/// @dev Swap calls are limited to governance-allowlisted executors, exact input approvals, declared
///      pool-token outputs, minimum output checks, and a minimum final LP-share amount.
contract WoolFiLiquidityZapper is ReentrancyGuard {
    struct SwapPlan {
        address executor;
        address tokenOut;
        uint256 amountIn;
        uint256 minAmountOut;
        bytes data;
    }

    struct ZapParams {
        PoolKey key;
        address tokenIn; // address(0) means native ETH, wrapped before swaps
        uint256 amountIn;
        SwapPlan swap0;
        SwapPlan swap1;
        uint128 minShares;
        uint256 deadline;
        address recipient;
    }

    struct BalanceSnapshot {
        address token0;
        address token1;
        uint256 input;
        uint256 token0Balance;
        uint256 token1Balance;
    }

    IWoolFiPositionManagerMint public immutable positionManager;
    address public immutable wrappedNative;
    address public owner;

    mapping(address executor => bool allowed) public allowedExecutor;

    event ExecutorAllowed(address indexed executor, bool allowed);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);
    event Zapped(
        address indexed payer,
        address indexed recipient,
        address indexed tokenIn,
        uint256 amountIn,
        uint256 swappedInput,
        uint128 shares
    );

    error NotOwner();
    error ZeroAddress();
    error InvalidAmount();
    error InvalidPoolToken();
    error InvalidNativeValue();
    error InvalidSwapPlan();
    error DeadlineExpired(uint256 deadline);
    error ExecutorNotAllowed(address executor);
    error InsufficientSwapOutput(address token, uint256 received, uint256 minimum);
    error UnsupportedTransferBehavior(uint256 expected, uint256 received);
    error SwapFailed(bytes reason);
    error UnexpectedEther();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IWoolFiPositionManagerMint positionManager_, address wrappedNative_, address owner_) {
        if (address(positionManager_) == address(0) || wrappedNative_ == address(0) || owner_ == address(0)) {
            revert ZeroAddress();
        }
        if (address(positionManager_).code.length == 0 || wrappedNative_.code.length == 0) revert ZeroAddress();
        positionManager = positionManager_;
        wrappedNative = wrappedNative_;
        owner = owner_;
    }

    receive() external payable {
        if (msg.sender != wrappedNative) revert UnexpectedEther();
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    function setExecutorAllowed(address executor, bool allowed) external onlyOwner {
        if (allowed && executor.code.length == 0) revert ZeroAddress();
        allowedExecutor[executor] = allowed;
        emit ExecutorAllowed(executor, allowed);
    }

    function zap(ZapParams calldata p) external payable nonReentrant returns (uint128 shares) {
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.recipient == address(0)) revert ZeroAddress();
        if (p.amountIn == 0) revert InvalidAmount();

        address actualIn = p.tokenIn == address(0) ? wrappedNative : p.tokenIn;
        BalanceSnapshot memory beforeBalances = _snapshot(p.key, actualIn);
        _collectInput(p.tokenIn, actualIn, p.amountIn, beforeBalances.input);

        uint256 swapped = p.swap0.amountIn + p.swap1.amountIn;
        if (swapped > p.amountIn) revert InvalidAmount();
        _executeSwap(p.swap0, actualIn, beforeBalances.token0, beforeBalances.token1);
        _executeSwap(p.swap1, actualIn, beforeBalances.token0, beforeBalances.token1);
        shares = _mintAndRefund(p, actualIn, beforeBalances);

        emit Zapped(msg.sender, p.recipient, actualIn, p.amountIn, swapped, shares);
    }

    function _snapshot(PoolKey calldata key, address tokenIn) private view returns (BalanceSnapshot memory b) {
        b.token0 = Currency.unwrap(key.currency0);
        b.token1 = Currency.unwrap(key.currency1);
        if (b.token0 == address(0) || b.token1 == address(0) || b.token0 == b.token1) revert InvalidPoolToken();
        b.input = SafeTransferLib.balanceOf(tokenIn, address(this));
        b.token0Balance = SafeTransferLib.balanceOf(b.token0, address(this));
        b.token1Balance = SafeTransferLib.balanceOf(b.token1, address(this));
    }

    function _mintAndRefund(ZapParams calldata p, address actualIn, BalanceSnapshot memory b)
        private
        returns (uint128 shares)
    {
        uint256 amount0 = SafeTransferLib.balanceOf(b.token0, address(this)) - b.token0Balance;
        uint256 amount1 = SafeTransferLib.balanceOf(b.token1, address(this)) - b.token1Balance;
        if (amount0 == 0 || amount1 == 0) revert InvalidAmount();

        SafeTransferLib.safeApproveWithRetry(b.token0, address(positionManager), amount0);
        SafeTransferLib.safeApproveWithRetry(b.token1, address(positionManager), amount1);
        shares = positionManager.mint(p.key, amount0, amount1, p.minShares, p.deadline, p.recipient);
        SafeTransferLib.safeApproveWithRetry(b.token0, address(positionManager), 0);
        SafeTransferLib.safeApproveWithRetry(b.token1, address(positionManager), 0);

        bool nativeInput = p.tokenIn == address(0);
        _refundToken(b.token0, b.token0Balance, nativeInput && actualIn == b.token0);
        _refundToken(b.token1, b.token1Balance, nativeInput && actualIn == b.token1);
        if (actualIn != b.token0 && actualIn != b.token1) _refundToken(actualIn, b.input, nativeInput);
    }

    function _executeSwap(SwapPlan calldata plan, address tokenIn, address pool0, address pool1) private {
        if (plan.amountIn == 0) {
            if (
                plan.executor != address(0) || plan.tokenOut != address(0) || plan.minAmountOut != 0
                    || plan.data.length != 0
            ) revert InvalidSwapPlan();
            return;
        }
        if (!allowedExecutor[plan.executor]) revert ExecutorNotAllowed(plan.executor);
        if (plan.tokenOut != pool0 && plan.tokenOut != pool1) revert InvalidPoolToken();
        if (plan.tokenOut == tokenIn) revert InvalidSwapPlan();

        uint256 beforeOut = SafeTransferLib.balanceOf(plan.tokenOut, address(this));
        SafeTransferLib.safeApproveWithRetry(tokenIn, plan.executor, plan.amountIn);
        (bool success, bytes memory reason) = plan.executor.call(plan.data);
        SafeTransferLib.safeApproveWithRetry(tokenIn, plan.executor, 0);
        if (!success) revert SwapFailed(reason);

        uint256 received = SafeTransferLib.balanceOf(plan.tokenOut, address(this)) - beforeOut;
        if (received < plan.minAmountOut) {
            revert InsufficientSwapOutput(plan.tokenOut, received, plan.minAmountOut);
        }
    }

    function _collectInput(address tokenIn, address actualIn, uint256 amount, uint256 balanceBefore) private {
        if (tokenIn == address(0)) {
            if (msg.value != amount) revert InvalidNativeValue();
            IWoolFiWrappedNative(wrappedNative).deposit{value: amount}();
        } else {
            if (msg.value != 0) revert InvalidNativeValue();
            SafeTransferLib.safeTransferFrom(actualIn, msg.sender, address(this), amount);
        }
        uint256 received = SafeTransferLib.balanceOf(actualIn, address(this)) - balanceBefore;
        if (received != amount) revert UnsupportedTransferBehavior(amount, received);
    }

    function _refundToken(address token, uint256 balanceBefore, bool unwrapNative) private {
        uint256 refund = SafeTransferLib.balanceOf(token, address(this)) - balanceBefore;
        if (refund == 0) return;
        if (unwrapNative) {
            IWoolFiWrappedNative(wrappedNative).withdraw(refund);
            SafeTransferLib.safeTransferETH(msg.sender, refund);
        } else {
            SafeTransferLib.safeTransfer(token, msg.sender, refund);
        }
    }
}
