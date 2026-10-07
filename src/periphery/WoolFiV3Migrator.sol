// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @notice Minimal subset of the Uniswap v3 NonfungiblePositionManager used by the migrator.
interface INonfungiblePositionManagerLike {
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    function ownerOf(uint256 tokenId) external view returns (address);

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );

    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);
}

interface IWoolFiPositionManagerMintV3 {
    function mint(
        PoolKey calldata key,
        uint256 amount0Max,
        uint256 amount1Max,
        uint128 minShares,
        uint256 deadline,
        address to
    ) external returns (uint128 shares);
}

/// @title WoolFiV3Migrator
/// @notice Moves liquidity from a Uniswap v3 position into a full-range WoolFi LP position in one
///         transaction: withdraw from v3, collect principal plus uncollected v3 fees, mint WoolFi
///         shares, refund whatever the full-range ratio did not use.
/// @dev Stateless and permissionless: no owner, no admin, holds no funds between transactions.
///      The caller must own the v3 NFT and approve this contract for it. The NFT itself never
///      moves; it is left with the owner (emptied of the migrated liquidity). Concentrated v3
///      positions rarely match the full-range ratio, so leftovers are always refunded to the
///      caller. A v3 position that is out of range holds only one token and cannot open a
///      full-range position; it reverts with {SingleSidedPosition}.
contract WoolFiV3Migrator is ReentrancyGuard {
    struct MigrateParams {
        uint256 tokenId;
        PoolKey woolfiKey;
        /// @dev v3 liquidity to remove; 0 means the entire position.
        uint128 liquidity;
        /// @dev Slippage floors on the v3 withdrawal, in v3 token0/token1 order.
        uint256 amount0Min;
        uint256 amount1Min;
        uint128 minShares;
        uint256 deadline;
        address recipient;
    }

    INonfungiblePositionManagerLike public immutable v3PositionManager;
    IWoolFiPositionManagerMintV3 public immutable woolfiPositionManager;

    event Migrated(
        address indexed owner,
        uint256 indexed tokenId,
        address indexed recipient,
        uint128 liquidityRemoved,
        uint256 amount0,
        uint256 amount1,
        uint128 shares,
        uint256 refund0,
        uint256 refund1
    );

    error ZeroAddress();
    error DeadlineExpired(uint256 deadline);
    error NotPositionOwner(address caller, address owner);
    error PairMismatch();
    error LiquidityTooHigh(uint128 requested, uint128 available);
    error NothingToMigrate();
    error SingleSidedPosition(uint256 amount0, uint256 amount1);

    constructor(
        INonfungiblePositionManagerLike v3PositionManager_,
        IWoolFiPositionManagerMintV3 woolfiPositionManager_
    ) {
        if (address(v3PositionManager_) == address(0) || address(woolfiPositionManager_) == address(0)) {
            revert ZeroAddress();
        }
        v3PositionManager = v3PositionManager_;
        woolfiPositionManager = woolfiPositionManager_;
    }

    /// @dev Per-call working state, kept in memory to stay clear of stack limits.
    struct Run {
        address token0;
        address token1;
        uint128 removed;
        uint256 before0;
        uint256 before1;
        uint256 amount0;
        uint256 amount1;
    }

    /// @notice Migrate (part of) a v3 position into WoolFi.
    /// @return shares WoolFi LP shares minted to `p.recipient`.
    function migrate(MigrateParams calldata p) external nonReentrant returns (uint128 shares) {
        if (block.timestamp > p.deadline) revert DeadlineExpired(p.deadline);
        if (p.recipient == address(0)) revert ZeroAddress();
        address owner = v3PositionManager.ownerOf(p.tokenId);
        if (owner != msg.sender) revert NotPositionOwner(msg.sender, owner);

        Run memory r = _validate(p);
        _withdraw(p, r);
        if (r.amount0 == 0 || r.amount1 == 0) revert SingleSidedPosition(r.amount0, r.amount1);

        shares = _mintWoolFi(p, r);
        (uint256 refund0, uint256 refund1) = _refund(r);

        emit Migrated(msg.sender, p.tokenId, p.recipient, r.removed, r.amount0, r.amount1, shares, refund0, refund1);
    }

    function _validate(MigrateParams calldata p) private view returns (Run memory r) {
        uint128 available;
        uint128 owed0;
        uint128 owed1;
        address v3token0;
        address v3token1;
        (,, v3token0, v3token1,,,, available,,, owed0, owed1) = v3PositionManager.positions(p.tokenId);
        address c0 = Currency.unwrap(p.woolfiKey.currency0);
        address c1 = Currency.unwrap(p.woolfiKey.currency1);
        // v3 and v4 both sort a pair by address, so a real match is always (token0 == currency0).
        // The flipped branch is defensive; amounts below are tracked in WoolFi currency order.
        if (v3token0 == c0 && v3token1 == c1) {
            (r.token0, r.token1) = (c0, c1);
        } else if (v3token0 == c1 && v3token1 == c0) {
            (r.token0, r.token1) = (c0, c1);
        } else {
            revert PairMismatch();
        }

        r.removed = p.liquidity == 0 ? available : p.liquidity;
        if (r.removed > available) revert LiquidityTooHigh(r.removed, available);
        if (r.removed == 0 && owed0 == 0 && owed1 == 0) revert NothingToMigrate();
    }

    /// @dev Balance snapshots mean a stray balance already sitting on this contract is never
    ///      swept into a user's mint or refund.
    function _withdraw(MigrateParams calldata p, Run memory r) private {
        r.before0 = SafeTransferLib.balanceOf(r.token0, address(this));
        r.before1 = SafeTransferLib.balanceOf(r.token1, address(this));
        if (r.removed > 0) {
            v3PositionManager.decreaseLiquidity(
                INonfungiblePositionManagerLike.DecreaseLiquidityParams({
                    tokenId: p.tokenId,
                    liquidity: r.removed,
                    amount0Min: p.amount0Min,
                    amount1Min: p.amount1Min,
                    deadline: p.deadline
                })
            );
        }
        v3PositionManager.collect(
            INonfungiblePositionManagerLike.CollectParams({
                tokenId: p.tokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );
        r.amount0 = SafeTransferLib.balanceOf(r.token0, address(this)) - r.before0;
        r.amount1 = SafeTransferLib.balanceOf(r.token1, address(this)) - r.before1;
    }

    function _mintWoolFi(MigrateParams calldata p, Run memory r) private returns (uint128 shares) {
        address pm = address(woolfiPositionManager);
        SafeTransferLib.safeApproveWithRetry(r.token0, pm, r.amount0);
        SafeTransferLib.safeApproveWithRetry(r.token1, pm, r.amount1);
        shares = woolfiPositionManager.mint(p.woolfiKey, r.amount0, r.amount1, p.minShares, p.deadline, p.recipient);
        SafeTransferLib.safeApproveWithRetry(r.token0, pm, 0);
        SafeTransferLib.safeApproveWithRetry(r.token1, pm, 0);
    }

    function _refund(Run memory r) private returns (uint256 refund0, uint256 refund1) {
        refund0 = SafeTransferLib.balanceOf(r.token0, address(this)) - r.before0;
        refund1 = SafeTransferLib.balanceOf(r.token1, address(this)) - r.before1;
        if (refund0 > 0) SafeTransferLib.safeTransfer(r.token0, msg.sender, refund0);
        if (refund1 > 0) SafeTransferLib.safeTransfer(r.token1, msg.sender, refund1);
    }
}
