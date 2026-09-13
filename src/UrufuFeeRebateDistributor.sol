// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";

import {WoolFiHook} from "./WoolFiHook.sol";
import {IFeeRebateDistributor} from "./interfaces/IFeeRebateDistributor.sol";

interface IERC721Balance {
    function balanceOf(address owner) external view returns (uint256);
}

/// @title UrufuFeeRebateDistributor
/// @notice Credits Urufu Gemu NFT holders with a capped rebate in each swap's input token.
/// @dev The authorized WoolFi router records successful swaps after settlement. Rebates equal
///      `amountIn * poolBaseFeeBps * REBATE_BPS / 1e8`, so directional surcharges are never
///      rebated. Credits belong to the trading wallet and do not follow an NFT transfer.
contract UrufuFeeRebateDistributor is IFeeRebateDistributor, Ownable, ReentrancyGuard {
    uint256 public constant BPS = 10_000;
    uint16 public constant REBATE_BPS = 1_500; // 15% of the base-fee portion

    struct WeeklyUsage {
        uint64 week;
        uint192 amount;
    }

    WoolFiHook public immutable hook;
    IERC721Balance public immutable urufuNft;
    address public router;

    mapping(address token => uint256 cap) public weeklyCap;
    mapping(address token => uint256 amount) public totalLiability;
    mapping(address account => mapping(address token => uint256 amount)) public claimable;
    mapping(address account => mapping(address token => WeeklyUsage usage)) public weeklyUsage;

    event RouterSet(address indexed router);
    event WeeklyCapSet(address indexed token, uint256 cap);
    event Funded(address indexed funder, address indexed token, uint256 amount);
    event RebateAccrued(
        address indexed trader, PoolId indexed poolId, address indexed token, uint256 amount, uint64 week
    );
    event RebateClaimed(address indexed trader, address indexed token, address indexed recipient, uint256 amount);

    error NotRouter();
    error RouterAlreadySet();
    error InvalidAddress();
    error InvalidRouter();
    error InvalidCap();
    error ZeroAmount();

    modifier onlyRouter() {
        if (msg.sender != router) revert NotRouter();
        _;
    }

    constructor(WoolFiHook hook_, address urufuNft_, address owner_) Ownable(owner_) {
        if (address(hook_) == address(0) || urufuNft_ == address(0) || owner_ == address(0)) revert InvalidAddress();
        if (address(hook_).code.length == 0 || urufuNft_.code.length == 0) revert InvalidAddress();
        hook = hook_;
        urufuNft = IERC721Balance(urufuNft_);
    }

    /// @notice Permanently bind the only router allowed to record swaps.
    function setRouter(address router_) external onlyOwner {
        if (router != address(0)) revert RouterAlreadySet();
        if (router_ == address(0) || router_.code.length == 0) revert InvalidRouter();
        router = router_;
        emit RouterSet(router_);
    }

    /// @notice Configure a raw-token weekly rebate cap. Zero disables accrual for the token.
    function setWeeklyCap(address token, uint256 cap) external onlyOwner {
        if (token == address(0)) revert InvalidAddress();
        if (cap > type(uint192).max) revert InvalidCap();
        weeklyCap[token] = cap;
        emit WeeklyCapSet(token, cap);
    }

    /// @notice Supply tokens used to honor accrued rebate claims.
    function fund(address token, uint256 amount) external nonReentrant {
        if (token == address(0)) revert InvalidAddress();
        if (amount == 0) revert ZeroAmount();
        SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
        emit Funded(msg.sender, token, amount);
    }

    /// @inheritdoc IFeeRebateDistributor
    function recordSwap(address trader, PoolId poolId, address tokenIn, uint256 amountIn)
        external
        onlyRouter
        returns (uint256 rebate)
    {
        uint256 cap = weeklyCap[tokenIn];
        if (cap == 0 || urufuNft.balanceOf(trader) == 0) return 0;

        WoolFiHook.WoolFiConfig memory config = hook.poolConfig(poolId);
        if (!config.configured) return 0;

        uint256 baseFee = amountIn * config.baseFeeBps / BPS;
        rebate = baseFee * REBATE_BPS / BPS;
        if (rebate == 0) return 0;

        uint64 currentWeek;
        (rebate, currentWeek) = _reserveRebate(trader, tokenIn, rebate, cap);
        if (rebate > 0) emit RebateAccrued(trader, poolId, tokenIn, rebate, currentWeek);
    }

    function _reserveRebate(address trader, address token, uint256 requested, uint256 cap)
        private
        returns (uint256 rebate, uint64 currentWeek)
    {
        rebate = requested;
        uint256 balance = SafeTransferLib.balanceOf(token, address(this));
        uint256 liability = totalLiability[token];
        if (balance <= liability) return (0, 0);
        uint256 available = balance - liability;
        if (rebate > available) rebate = available;

        currentWeek = uint64(block.timestamp / 1 weeks);
        WeeklyUsage storage usage = weeklyUsage[trader][token];
        uint256 used = usage.week == currentWeek ? usage.amount : 0;
        if (used >= cap) return (0, currentWeek);
        if (rebate > cap - used) rebate = cap - used;

        uint256 updated = used + rebate;
        usage.week = currentWeek;
        usage.amount = uint192(updated);
        claimable[trader][token] += rebate;
        totalLiability[token] = liability + rebate;
    }

    /// @notice Claim all accrued rebates for one input token.
    function claim(address token, address recipient) external nonReentrant returns (uint256 amount) {
        if (recipient == address(0)) revert InvalidAddress();
        amount = claimable[msg.sender][token];
        if (amount == 0) revert ZeroAmount();
        claimable[msg.sender][token] = 0;
        totalLiability[token] -= amount;
        SafeTransferLib.safeTransfer(token, recipient, amount);
        emit RebateClaimed(msg.sender, token, recipient, amount);
    }
}
