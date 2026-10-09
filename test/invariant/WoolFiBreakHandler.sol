// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {STRAND} from "../../src/STRAND.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {SpreadMath} from "../../src/lib/SpreadMath.sol";

/// @notice Handler for the two-phase structural-break and single-swap-guard invariants. Every action
///         records ghost state that the invariant suite asserts on:
///         - guard: a successful swap never takes a non-broken pool from inside to past the hard
///           threshold while moving away from fair;
///         - drawdown: the vault's backing only drops via {WoolFiHook.confirmStructuralBreak}, at most
///           once per break episode, after the window, with fresh drift still past the threshold;
///         - fee routing: each swap-time realization splits exactly vaultBps / treasuryBps / remainder.
contract WoolFiBreakHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint16 internal constant HARD = 1500;
    uint16 internal constant VAULT_BPS = 2000;
    uint16 internal constant TREASURY_BPS = 1000;

    IPoolManager immutable manager;
    PoolSwapTest immutable swapRouter;
    WoolFiHook immutable hook;
    WoolFiPositionManager immutable pm;
    WoolFiUnderwritingVault immutable vault;
    STRAND immutable strand;
    MockPriceOracle immutable oracle0;
    MockPriceOracle immutable oracle1;
    MockMarketHours immutable marketHours;
    address immutable governor;
    address immutable treasury;

    PoolKey key;
    PoolId immutable id;
    uint256 immutable shareId;
    address immutable token0;
    address immutable token1;

    address[3] public actors;

    // --- ghost state ---
    uint256 public guardViolations;
    uint256 public drawdownOutsideConfirm;
    uint256 public drawdownTooEarly;
    uint256 public drawdownWithoutFreshBreak;
    uint256 public feeSplitViolations;
    uint256 public episodes;
    uint256 public drawdownsThisEpisode;
    uint256 public maxDrawdownsPerEpisode;
    uint256 public drawdownsObserved;
    uint256 public guardRevertsObserved;
    uint256 public confirmsAttempted;
    uint256 public unstakeDuringPendingBreak;
    uint256 public unstakesBlockedByBreak;
    bool internal lastBroken;
    uint256 internal stakedBaseline;

    constructor(
        WoolFiHook _hook,
        WoolFiPositionManager _pm,
        WoolFiUnderwritingVault _vault,
        STRAND _strand,
        MockPriceOracle _oracle0,
        MockPriceOracle _oracle1,
        MockMarketHours _marketHours,
        PoolSwapTest _swapRouter,
        PoolKey memory _key,
        address _governor,
        address _treasury
    ) {
        hook = _hook;
        manager = _hook.poolManager();
        pm = _pm;
        vault = _vault;
        strand = _strand;
        oracle0 = _oracle0;
        oracle1 = _oracle1;
        marketHours = _marketHours;
        swapRouter = _swapRouter;
        key = _key;
        id = _key.toId();
        shareId = uint256(PoolId.unwrap(_key.toId()));
        token0 = Currency.unwrap(_key.currency0);
        token1 = Currency.unwrap(_key.currency1);
        governor = _governor;
        treasury = _treasury;
        actors = [makeAddr("blp0"), makeAddr("blp1"), makeAddr("blp2")];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // ------------------------------------------------------------------ //
    // Observation helpers
    // ------------------------------------------------------------------ //

    /// @dev Drift measured the way the hook does on every non-break swap path: the mocks return the
    ///      same price from getPrice / getPriceData / getLastValidPrice, so one formula covers open,
    ///      closed, stabilizing and skewed modes.
    function _drift() internal view returns (int256) {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(id);
        uint256 fair = SpreadMath.fairPrice(oracle0.priceWad(), oracle1.priceWad());
        return SpreadMath.computeDrift(SpreadMath.poolPrice(sqrtPriceX96, 18, 18), fair);
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x >= 0 ? uint256(x) : uint256(-x);
    }

    function _pendingBreak() internal view returns (bool) {
        (bool broken, bool confirmed,,) = hook.breakStatus(key);
        return broken && !confirmed;
    }

    function _broken() internal view returns (bool) {
        return hook.poolConfig(id).structuralBreak;
    }

    /// @dev Called before and after every action. Any drop in vault backing outside an unstake is a
    ///      drawdown; `allowDrawdown` is true only inside {confirmStructuralBreak}.
    function _settle(bool allowDrawdown) internal returns (bool drew) {
        uint256 staked = vault.totalStaked();
        if (staked < stakedBaseline) {
            drew = true;
            drawdownsObserved++;
            drawdownsThisEpisode++;
            if (drawdownsThisEpisode > maxDrawdownsPerEpisode) maxDrawdownsPerEpisode = drawdownsThisEpisode;
            if (!allowDrawdown) drawdownOutsideConfirm++;
        }
        stakedBaseline = staked;
        bool broken = _broken();
        if (broken && !lastBroken) {
            episodes++;
            drawdownsThisEpisode = 0;
        }
        lastBroken = broken;
    }

    modifier observed() {
        _settle(false);
        _;
        _settle(false);
    }

    // ------------------------------------------------------------------ //
    // LP actions
    // ------------------------------------------------------------------ //

    function mint(uint256 seed, uint256 amount) external observed {
        address a = _actor(seed);
        amount = bound(amount, 1e15, 1e21);
        vm.prank(a);
        try pm.mint(key, amount, amount, a) {} catch {}
    }

    function burn(uint256 seed, uint256 shareSeed) external observed {
        address a = _actor(seed);
        uint256 bal = pm.balanceOf(a, shareId);
        if (bal == 0) return;
        uint256 shares = bound(shareSeed, 1, bal);
        vm.prank(a);
        try pm.burn(key, uint128(shares), a) {} catch {}
    }

    // ------------------------------------------------------------------ //
    // Swaps: single-swap guard + fee-split conservation
    // ------------------------------------------------------------------ //

    struct Balances {
        uint256 pm0;
        uint256 pm1;
        uint256 v0;
        uint256 v1;
        uint256 b0;
        uint256 b1;
    }

    function _balances() internal view returns (Balances memory b) {
        b.pm0 = IERC20(token0).balanceOf(address(pm));
        b.pm1 = IERC20(token1).balanceOf(address(pm));
        b.v0 = IERC20(token0).balanceOf(address(vault));
        b.v1 = IERC20(token1).balanceOf(address(vault));
        b.b0 = IERC20(token0).balanceOf(treasury);
        b.b1 = IERC20(token1).balanceOf(treasury);
    }

    function swap(uint256 amount, bool zeroForOne) external observed {
        amount = bound(amount, 1e12, 3e20);
        bool preBroken = _broken();
        int256 pre = _drift();
        bool vaultHadShares = vault.totalShares() > 0;
        Balances memory before = _balances();

        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        try swapRouter.swap(key, p, s, "") {}
        catch (bytes memory reason) {
            if (reason.length >= 4 && _containsSelector(reason, WoolFiHook.SwapWouldBreakPool.selector)) {
                guardRevertsObserved++;
            }
            return;
        }

        int256 post = _drift();
        if (
            !preBroken && !SpreadMath.isStructuralBreak(pre, HARD) && SpreadMath.isStructuralBreak(post, HARD)
                && _abs(post) > _abs(pre)
        ) guardViolations++;

        _checkFeeSplit(before, _balances(), vaultHadShares);
    }

    function _checkFeeSplit(Balances memory b, Balances memory a, bool vaultHadShares) internal {
        uint256 f0 = (a.pm0 - b.pm0) + (a.v0 - b.v0) + (a.b0 - b.b0);
        uint256 f1 = (a.pm1 - b.pm1) + (a.v1 - b.v1) + (a.b1 - b.b1);
        uint256 ev0 = vaultHadShares ? f0 * VAULT_BPS / 10_000 : 0;
        uint256 ev1 = vaultHadShares ? f1 * VAULT_BPS / 10_000 : 0;
        if (a.v0 - b.v0 != ev0 || a.v1 - b.v1 != ev1) feeSplitViolations++;
        if (a.b0 - b.b0 != f0 * TREASURY_BPS / 10_000 || a.b1 - b.b1 != f1 * TREASURY_BPS / 10_000) {
            feeSplitViolations++;
        }
    }

    /// @dev v4 wraps hook reverts; scan the revert bytes for the guard selector.
    function _containsSelector(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i; i + 4 <= data.length; i++) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    // ------------------------------------------------------------------ //
    // Two-phase break
    // ------------------------------------------------------------------ //

    function checkBreak() external observed {
        try hook.checkStructuralBreak(key) {} catch {}
    }

    /// @dev Half the time, jump exactly to the window boundary (the tightest legal confirmation);
    ///      the other half, call wherever time is (usually too early, which must not draw down).
    function confirmBreak(uint256 seed) external {
        _settle(false);
        confirmsAttempted++;
        (bool broken,,, uint256 readyAt) = hook.breakStatus(key);
        // readyAt is type(uint256).max while the market is closed; only jump to real deadlines.
        if (broken && seed % 2 == 0 && block.timestamp < readyAt && readyAt <= block.timestamp + 2 days) {
            vm.warp(readyAt);
        }
        int256 fresh = _drift();
        try hook.confirmStructuralBreak(key) {} catch {}
        bool drew = _settle(true);
        if (drew) {
            if (!broken || block.timestamp < readyAt) drawdownTooEarly++;
            if (!SpreadMath.isStructuralBreak(fresh, HARD)) drawdownWithoutFreshBreak++;
        }
    }

    function resolveBreak() external observed {
        vm.prank(governor);
        try hook.resolveStructuralBreak(key) {} catch {}
    }

    // ------------------------------------------------------------------ //
    // Vault
    // ------------------------------------------------------------------ //

    function stake(uint256 seed, uint256 amount) external observed {
        address a = _actor(seed);
        uint256 bal = strand.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal < 1e22 ? bal : 1e22);
        vm.prank(a);
        try vault.stake(amount) {} catch {}
    }

    function requestUnstake(uint256 seed, uint256 shareSeed) external observed {
        address a = _actor(seed);
        uint256 shares = vault.sharesOf(a);
        if (shares == 0) return;
        vm.prank(a);
        try vault.requestUnstake(bound(shareSeed, 1, shares)) {} catch {}
    }

    /// @dev Unstaking legitimately lowers totalStaked, so re-baseline without counting a drawdown.
    function unstake(uint256 seed) external {
        _settle(false);
        address a = _actor(seed);
        bool pendingBefore = _pendingBreak();
        vm.prank(a);
        try vault.unstake() {
            if (pendingBefore) unstakeDuringPendingBreak++;
        } catch (bytes memory reason) {
            if (bytes4(reason) == WoolFiUnderwritingVault.BreakPending.selector) unstakesBlockedByBreak++;
        }
        stakedBaseline = vault.totalStaked();
        _settle(false);
    }

    // ------------------------------------------------------------------ //
    // Environment
    // ------------------------------------------------------------------ //

    /// @dev Wide range so the oracle alone can push the pool well past the 15% hard threshold.
    function moveOracle(uint256 priceSeed) external observed {
        oracle0.setPrice(bound(priceSeed, 0.6e18, 1.6e18));
        oracle1.setPrice(oracle1.priceWad()); // keep legs time-aligned unless the skew action fires
    }

    function skewOracles(uint32 difference, bool reverse) external observed {
        difference = uint32(bound(difference, 0, 1000));
        if (block.timestamp <= 1000) skip(1001);
        uint256 older = block.timestamp - difference;
        if (reverse) {
            oracle0.setPriceData(oracle0.priceWad(), older);
            oracle1.setPriceData(oracle1.priceWad(), block.timestamp);
        } else {
            oracle0.setPriceData(oracle0.priceWad(), block.timestamp);
            oracle1.setPriceData(oracle1.priceWad(), older);
        }
    }

    function toggleMarket(uint256 seed) external observed {
        marketHours.setOpen(seed % 2 == 0);
    }

    function warp(uint256 secondsSeed) external observed {
        uint256 s = secondsSeed % 4 == 0 ? bound(secondsSeed, 1 days, 8 days) : bound(secondsSeed, 1, 2 hours);
        skip(s);
    }

    // ------------------------------------------------------------------ //
    // Views
    // ------------------------------------------------------------------ //

    function pendingFeesTotal() external view returns (uint256 f0, uint256 f1) {
        for (uint256 i; i < actors.length; i++) {
            (uint256 a0, uint256 a1) = pm.pendingFees(key, actors[i]);
            f0 += a0;
            f1 += a1;
        }
    }

    function sync() external {
        stakedBaseline = vault.totalStaked();
        lastBroken = _broken();
    }
}
