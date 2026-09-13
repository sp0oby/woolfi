// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ERC6909} from "solady/tokens/ERC6909.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";

import {LiquidityAmounts} from "./lib/LiquidityAmounts.sol";
import {IUnderwritingVault} from "./interfaces/IUnderwritingVault.sol";

/// @title WoolFiPositionManager
/// @notice ERC-6909 LP shares over a single full-range v4 position per WoolFi pool.
/// @dev One shared full-range position per pool (owner = this contract, salt 0); `shares == liquidity`,
///      so a holder's share is an exact pro-rata claim on the pool's reserves. Mints go through the
///      pool's hook (`beforeAddLiquidity`), so deposits are only accepted when the pool is in band.
///
///      Native pool fees accrue to the shared position. Because v4 credits *all* of a position's
///      pending fees to whoever next touches it, a naive shared position would let one LP siphon
///      everyone's fees. We prevent that by realizing fees into a per-share accumulator on every
///      mint/burn (a 0-liquidity "poke"), then distributing pro-rata — a standard reward accumulator.
///
///      v1 shares are **non-transferable** (see {_beforeTokenTransfer}): this keeps the accumulator
///      exact without settling fees on transfer. Transferable shares are a later enhancement.
contract WoolFiPositionManager is ERC6909, IUnlockCallback, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    /// @dev Fixed-point scale for the fee-per-share accumulator.
    uint256 private constant ACC_PRECISION = 1e18;
    uint256 private constant BPS = 10_000;
    /// @dev Max combined protocol cut (vault + treasury) that may be diverted from LP fees.
    uint256 private constant MAX_PROTOCOL_FEE_BPS = 5_000; // 50%

    enum Action {
        MINT,
        BURN
    }

    struct CallbackData {
        Action action;
        PoolKey key;
        uint128 liquidity;
        address payer; // MINT: pulls tokens from here
        address recipient; // BURN: principal sent here
    }

    /// @notice Per-pool routing of collected swap fees (PROJECT_SPEC.md §7.3).
    struct FeeConfig {
        address vault; // receives the vault cut as staker rewards (address(0) = none)
        uint16 vaultBps; // share of fees to the underwriting vault (default 2000 = 20%)
        address treasurySink; // receives the treasury policy's fee allocation
        uint16 treasuryBps; // share of fees allocated to the treasury policy
    }

    /// @notice The v4 PoolManager singleton.
    IPoolManager public immutable poolManager;
    /// @notice Governance address allowed to set fee routing.
    address public owner;

    /// @notice Per-pool fee routing config (unset = 100% of fees to LPs).
    mapping(uint256 id => FeeConfig) public feeConfig;

    /// @notice Total shares (== total managed liquidity) per pool id.
    mapping(uint256 id => uint256) public totalShares;
    /// @notice Accumulated fees per share (token0/token1), scaled by {ACC_PRECISION}.
    mapping(uint256 id => uint256) public accFeePerShare0;
    mapping(uint256 id => uint256) public accFeePerShare1;
    /// @notice Each holder's settled fee checkpoint (token0/token1).
    mapping(address owner => mapping(uint256 id => uint256)) public feeDebt0;
    mapping(address owner => mapping(uint256 id => uint256)) public feeDebt1;

    event Mint(uint256 indexed id, address indexed to, uint128 liquidity, uint256 amount0, uint256 amount1);
    event Burn(uint256 indexed id, address indexed from, uint128 liquidity, uint256 amount0, uint256 amount1);
    event FeesCollected(uint256 indexed id, address indexed to, uint256 amount0, uint256 amount1);
    event FeesRouted(uint256 indexed id, uint256 vault0, uint256 vault1, uint256 treasury0, uint256 treasury1);
    event FeeConfigSet(uint256 indexed id, address vault, uint16 vaultBps, address treasurySink, uint16 treasuryBps);
    event OwnerUpdated(address indexed oldOwner, address indexed newOwner);

    error NotPoolManager();
    error NotOwner();
    error NotHook();
    error ZeroLiquidity();
    error TransfersDisabled();
    error InvalidFeeConfig();
    error DeadlineExpired(uint256 deadline);
    error InsufficientShares(uint256 received, uint256 minimum);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(IPoolManager _poolManager, address _owner) {
        if (_owner == address(0)) revert InvalidFeeConfig();
        poolManager = _poolManager;
        owner = _owner;
    }

    /// @notice Hand ownership (fee-routing control) to a new address.
    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidFeeConfig();
        emit OwnerUpdated(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Configure how a pool's swap fees are split (vault rewards / treasury policy / LPs).
    /// @dev Combined protocol cut (vaultBps + treasuryBps) is capped at {MAX_PROTOCOL_FEE_BPS}. The
    ///      remainder always accrues to LPs. Defaults (unset) route 100% to LPs.
    function setFeeConfig(
        PoolKey calldata key,
        address vault,
        uint16 vaultBps,
        address treasurySink,
        uint16 treasuryBps
    ) external onlyOwner {
        if (uint256(vaultBps) + treasuryBps > MAX_PROTOCOL_FEE_BPS) revert InvalidFeeConfig();
        feeConfig[_id(key)] =
            FeeConfig({vault: vault, vaultBps: vaultBps, treasurySink: treasurySink, treasuryBps: treasuryBps});
        emit FeeConfigSet(_id(key), vault, vaultBps, treasurySink, treasuryBps);
    }

    // --------------------------------------------------------------------
    // ERC-6909 metadata + non-transferability
    // --------------------------------------------------------------------

    function name(uint256) public pure override returns (string memory) {
        return "WoolFi LP";
    }

    function symbol(uint256) public pure override returns (string memory) {
        return "WOOLFI-LP";
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }

    /// @dev v1 LP shares are non-transferable; only mint (from == 0) and burn (to == 0) are allowed.
    function _beforeTokenTransfer(address from, address to, uint256, uint256) internal pure override {
        if (from != address(0) && to != address(0)) revert TransfersDisabled();
    }

    // --------------------------------------------------------------------
    // LP actions
    // --------------------------------------------------------------------

    /// @notice Deposit liquidity in the pool's current (in-band) ratio and receive LP shares.
    /// @param key The WoolFi pool key.
    /// @param amount0Max Max token0 the caller will provide.
    /// @param amount1Max Max token1 the caller will provide.
    /// @param to Recipient of the LP shares.
    /// @return shares Shares minted (equal to the liquidity added).
    function mint(PoolKey calldata key, uint256 amount0Max, uint256 amount1Max, address to)
        external
        nonReentrant
        returns (uint128 shares)
    {
        return _mintPosition(key, amount0Max, amount1Max, 0, type(uint256).max, to);
    }

    /// @notice Deposit liquidity with caller-enforced share slippage and transaction deadline bounds.
    function mint(
        PoolKey calldata key,
        uint256 amount0Max,
        uint256 amount1Max,
        uint128 minShares,
        uint256 deadline,
        address to
    ) external nonReentrant returns (uint128 shares) {
        return _mintPosition(key, amount0Max, amount1Max, minShares, deadline, to);
    }

    function _mintPosition(
        PoolKey calldata key,
        uint256 amount0Max,
        uint256 amount1Max,
        uint128 minShares,
        uint256 deadline,
        address to
    ) private returns (uint128 shares) {
        if (block.timestamp > deadline) revert DeadlineExpired(deadline);
        uint256 id = _id(key);
        shares = _liquidityFor(key, amount0Max, amount1Max);
        if (shares == 0) revert ZeroLiquidity();
        if (shares < minShares) revert InsufficientShares(shares, minShares);

        bytes memory ret = poolManager.unlock(abi.encode(CallbackData(Action.MINT, key, shares, msg.sender, to)));
        (uint256 amount0, uint256 amount1) = abi.decode(ret, (uint256, uint256));

        _harvest(to, key, id); // pay `to`'s pending fees before its balance changes
        _mint(to, id, shares);
        totalShares[id] += shares;
        _checkpoint(to, id);

        emit Mint(id, to, shares, amount0, amount1);
    }

    /// @notice Burn LP shares and withdraw the underlying token0/token1 at the current ratio,
    ///         plus any accrued fees.
    /// @param key The WoolFi pool key.
    /// @param shares Shares to burn.
    /// @param to Recipient of the withdrawn tokens and fees.
    /// @return amount0 token0 returned (principal). @return amount1 token1 returned (principal).
    function burn(PoolKey calldata key, uint128 shares, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 id = _id(key);

        bytes memory ret = poolManager.unlock(abi.encode(CallbackData(Action.BURN, key, shares, msg.sender, to)));
        (amount0, amount1) = abi.decode(ret, (uint256, uint256));

        _harvestTo(msg.sender, to, key, id); // pay the caller's pre-burn fee share to `to`
        _burn(msg.sender, id, shares); // reverts if the caller lacks the shares
        totalShares[id] -= shares;
        _checkpoint(msg.sender, id);

        emit Burn(id, msg.sender, shares, amount0, amount1);
    }

    /// @notice Collect accrued fees without changing the LP position.
    /// @dev Realizes pool fees into the accumulator (poke) then pays the caller's share.
    function collectFees(PoolKey calldata key, address to)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 id = _id(key);
        poolManager.unlock(abi.encode(CallbackData(Action.MINT, key, 0, msg.sender, to))); // poke only (liquidity 0)
        (amount0, amount1) = _harvestTo(msg.sender, to, key, id);
        _checkpoint(msg.sender, id);
    }

    /// @notice Hook-only entry point: realize accrued pool fees and route them, *without*
    ///         opening a new {PoolManager.unlock}. Safe to call from inside the pool hook's
    ///         {beforeSwap}/{afterSwap} because the swap caller's unlock is still active.
    /// @dev Caller is gated by `msg.sender == key.hooks` — the hook address is encoded into the
    ///      pool key, so a malicious caller can't impersonate another pool's hook by passing
    ///      forged data. Side effects are identical to a `collectFees(key, *)` poke:
    ///      modifyLiquidity(0) pulls accrued fees out, they get split per the FeeConfig (vault
    ///      cut deposited as rewards, treasury cut transferred to sink), LP remainder folds into
    ///      the per-share accumulator. Idempotent: when there are no pending fees this is a
    ///      cheap modifyLiquidity(0) round-trip with no transfers.
    ///
    ///      This is what makes fee realization automatic in production — without it WoolFi
    ///      depends on an off-chain keeper or an LP touch to make `FeesRouted` fire.
    function realizeFromHook(PoolKey calldata key) external {
        if (msg.sender != address(key.hooks)) revert NotHook();
        uint256 id = _id(key);
        (int24 tickLower, int24 tickUpper) = _fullRange(key.tickSpacing);
        _realizeFees(key, id, tickLower, tickUpper);
    }

    // --------------------------------------------------------------------
    // Unlock callback
    // --------------------------------------------------------------------

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata raw) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        CallbackData memory d = abi.decode(raw, (CallbackData));
        uint256 id = _id(d.key);
        (int24 tickLower, int24 tickUpper) = _fullRange(d.key.tickSpacing);

        _realizeFees(d.key, id, tickLower, tickUpper); // poke: pull pending fees into the accumulator

        if (d.action == Action.MINT) {
            if (d.liquidity == 0) return abi.encode(uint256(0), uint256(0)); // collectFees poke-only path
            (BalanceDelta delta,) =
                poolManager.modifyLiquidity(d.key, _params(tickLower, tickUpper, int256(uint256(d.liquidity))), "");
            uint256 amount0 = _settle(d.key.currency0, d.payer, delta.amount0());
            uint256 amount1 = _settle(d.key.currency1, d.payer, delta.amount1());
            return abi.encode(amount0, amount1);
        } else {
            (BalanceDelta delta,) =
                poolManager.modifyLiquidity(d.key, _params(tickLower, tickUpper, -int256(uint256(d.liquidity))), "");
            uint256 amount0 = _takePrincipal(d.key.currency0, d.recipient, delta.amount0());
            uint256 amount1 = _takePrincipal(d.key.currency1, d.recipient, delta.amount1());
            return abi.encode(amount0, amount1);
        }
    }

    // --------------------------------------------------------------------
    // Views
    // --------------------------------------------------------------------

    /// @notice Fees currently claimable by `owner` for a pool (excludes fees not yet poked).
    function pendingFees(PoolKey calldata key, address account) external view returns (uint256 fee0, uint256 fee1) {
        uint256 id = _id(key);
        uint256 bal = balanceOf(account, id);
        fee0 = bal * accFeePerShare0[id] / ACC_PRECISION - feeDebt0[account][id];
        fee1 = bal * accFeePerShare1[id] / ACC_PRECISION - feeDebt1[account][id];
    }

    /// @notice Preview shares for the supplied token maxima at the pool's current price.
    function previewMint(PoolKey calldata key, uint256 amount0Max, uint256 amount1Max)
        external
        view
        returns (uint128 shares)
    {
        shares = _liquidityFor(key, amount0Max, amount1Max);
    }

    // --------------------------------------------------------------------
    // Internal: fees
    // --------------------------------------------------------------------

    /// @dev Poke the position to realize pending fees, route the protocol cuts (vault/treasury), then
    ///      fold the LP remainder into the per-share accumulator.
    function _realizeFees(PoolKey memory key, uint256 id, int24 tickLower, int24 tickUpper) private {
        uint256 supply = totalShares[id];
        if (supply == 0) return;
        (BalanceDelta delta,) = poolManager.modifyLiquidity(key, _params(tickLower, tickUpper, 0), "");
        uint256 fee0 = _takePrincipal(key.currency0, address(this), delta.amount0());
        uint256 fee1 = _takePrincipal(key.currency1, address(this), delta.amount1());
        (uint256 lp0, uint256 lp1) = _routeProtocolFees(key, id, fee0, fee1);
        if (lp0 > 0) accFeePerShare0[id] += lp0 * ACC_PRECISION / supply;
        if (lp1 > 0) accFeePerShare1[id] += lp1 * ACC_PRECISION / supply;
    }

    /// @dev Split realized fees per the pool's {FeeConfig}: vault cut -> staker rewards, treasury cut
    ///      -> policy sink, remainder -> LPs. Cuts fold back into the LP share when their destination is
    ///      unset (or, for the vault, has no stakers), so no fees are ever stranded.
    function _routeProtocolFees(PoolKey memory key, uint256 id, uint256 fee0, uint256 fee1)
        private
        returns (uint256 lp0, uint256 lp1)
    {
        lp0 = fee0;
        lp1 = fee1;
        if (fee0 == 0 && fee1 == 0) return (lp0, lp1);

        FeeConfig memory fc = feeConfig[id];
        address t0 = Currency.unwrap(key.currency0);
        address t1 = Currency.unwrap(key.currency1);
        uint256 v0;
        uint256 v1;
        uint256 b0;
        uint256 b1;

        if (fc.vault != address(0) && fc.vaultBps > 0 && IUnderwritingVault(fc.vault).totalShares() > 0) {
            v0 = fee0 * fc.vaultBps / BPS;
            v1 = fee1 * fc.vaultBps / BPS;
            if (v0 > 0 || v1 > 0) {
                if (v0 > 0) SafeTransferLib.safeApprove(t0, fc.vault, v0);
                if (v1 > 0) SafeTransferLib.safeApprove(t1, fc.vault, v1);
                IUnderwritingVault(fc.vault).depositRewards(v0, v1);
            }
        }

        if (fc.treasurySink != address(0) && fc.treasuryBps > 0) {
            b0 = fee0 * fc.treasuryBps / BPS;
            b1 = fee1 * fc.treasuryBps / BPS;
            if (b0 > 0) SafeTransferLib.safeTransfer(t0, fc.treasurySink, b0);
            if (b1 > 0) SafeTransferLib.safeTransfer(t1, fc.treasurySink, b1);
        }

        lp0 = fee0 - v0 - b0;
        lp1 = fee1 - v1 - b1;
        if ((v0 | v1 | b0 | b1) != 0) emit FeesRouted(id, v0, v1, b0, b1);
    }

    function _harvest(address account, PoolKey memory key, uint256 id) private {
        _harvestTo(account, account, key, id);
    }

    function _harvestTo(address account, address to, PoolKey memory key, uint256 id)
        private
        returns (uint256 fee0, uint256 fee1)
    {
        uint256 bal = balanceOf(account, id);
        fee0 = bal * accFeePerShare0[id] / ACC_PRECISION - feeDebt0[account][id];
        fee1 = bal * accFeePerShare1[id] / ACC_PRECISION - feeDebt1[account][id];
        if (fee0 > 0) SafeTransferLib.safeTransfer(Currency.unwrap(key.currency0), to, fee0);
        if (fee1 > 0) SafeTransferLib.safeTransfer(Currency.unwrap(key.currency1), to, fee1);
        if (fee0 > 0 || fee1 > 0) emit FeesCollected(id, to, fee0, fee1);
    }

    function _checkpoint(address account, uint256 id) private {
        uint256 bal = balanceOf(account, id);
        feeDebt0[account][id] = bal * accFeePerShare0[id] / ACC_PRECISION;
        feeDebt1[account][id] = bal * accFeePerShare1[id] / ACC_PRECISION;
    }

    // --------------------------------------------------------------------
    // Internal: settlement
    // --------------------------------------------------------------------

    /// @dev Pay the PoolManager `amount` (= -delta) of `currency` on behalf of `payer`. Returns the amount paid.
    function _settle(Currency currency, address payer, int128 delta) private returns (uint256 amount) {
        if (delta >= 0) return 0; // nothing owed to the pool for this currency
        amount = uint256(uint128(-delta));
        poolManager.sync(currency);
        if (payer == address(this)) {
            SafeTransferLib.safeTransfer(Currency.unwrap(currency), address(poolManager), amount);
        } else {
            // `payer` is not attacker-controlled: it is always the `mint` caller (msg.sender), encoded
            // into PM-owned CallbackData, and unlockCallback is gated to the PoolManager. No caller can
            // pull another address's tokens.
            // slither-disable-next-line arbitrary-send-erc20
            SafeTransferLib.safeTransferFrom(Currency.unwrap(currency), payer, address(poolManager), amount);
        }
        poolManager.settle();
    }

    /// @dev Take `amount` (= +delta) of `currency` from the PoolManager to `to`. Returns the amount taken.
    function _takePrincipal(Currency currency, address to, int128 delta) private returns (uint256 amount) {
        if (delta <= 0) return 0;
        amount = uint256(uint128(delta));
        poolManager.take(currency, to, amount);
    }

    // --------------------------------------------------------------------
    // Internal: helpers
    // --------------------------------------------------------------------

    function _liquidityFor(PoolKey calldata key, uint256 amount0Max, uint256 amount1Max)
        private
        view
        returns (uint128)
    {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(key.toId());
        (int24 tickLower, int24 tickUpper) = _fullRange(key.tickSpacing);
        return LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(tickLower),
            TickMath.getSqrtPriceAtTick(tickUpper),
            amount0Max,
            amount1Max
        );
    }

    function _params(int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        private
        pure
        returns (IPoolManager.ModifyLiquidityParams memory)
    {
        return IPoolManager.ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: 0
        });
    }

    function _fullRange(int24 tickSpacing) private pure returns (int24 lower, int24 upper) {
        lower = TickMath.minUsableTick(tickSpacing);
        upper = TickMath.maxUsableTick(tickSpacing);
    }

    function _id(PoolKey memory key) private pure returns (uint256) {
        return uint256(PoolId.unwrap(key.toId()));
    }
}
