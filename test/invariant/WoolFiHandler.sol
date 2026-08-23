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

/// @notice Invariant-test handler: drives the WoolFi system through random but valid-ish action
///         sequences (mint/burn/swap/stake/oracle moves/market toggles). Drawdowns occur organically
///         when a swap pushes drift past the hard threshold while a vault is wired.
/// @dev `fail_on_revert = false` (foundry.toml), so reverting actions are tolerated; the guards just
///      reduce wasted runs. Tracks the actor set so invariants can sum per-actor balances.
contract WoolFiHandler is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    IPoolManager immutable manager;
    PoolSwapTest immutable swapRouter;
    WoolFiHook immutable hook;
    WoolFiPositionManager immutable pm;
    WoolFiUnderwritingVault immutable vault;
    STRAND immutable strand;
    MockPriceOracle immutable oracle0;
    MockPriceOracle immutable oracle1;
    MockMarketHours immutable marketHours;

    PoolKey key;
    PoolId immutable id;
    uint256 immutable shareId;
    int24 immutable tickLower;
    int24 immutable tickUpper;
    address immutable token0;
    address immutable token1;

    address[3] public actors;

    constructor(
        WoolFiHook _hook,
        WoolFiPositionManager _pm,
        WoolFiUnderwritingVault _vault,
        STRAND _strand,
        MockPriceOracle _oracle0,
        MockPriceOracle _oracle1,
        MockMarketHours _marketHours,
        PoolSwapTest _swapRouter,
        PoolKey memory _key
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
        tickLower = TickMath.minUsableTick(_key.tickSpacing);
        tickUpper = TickMath.maxUsableTick(_key.tickSpacing);
        token0 = Currency.unwrap(_key.currency0);
        token1 = Currency.unwrap(_key.currency1);
        actors = [makeAddr("lp0"), makeAddr("lp1"), makeAddr("lp2")];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    // --- LP actions ---

    function mint(uint256 seed, uint256 amount) external {
        // only attempt in-band + open (else beforeAddLiquidity reverts and wastes the run)
        if (!marketHours.isMarketOpen()) return;
        try hook.currentDrift(key) returns (int256 drift) {
            if (drift > 500 || drift < -500) return;
        } catch {
            return;
        }
        address a = _actor(seed);
        amount = bound(amount, 1e15, 1e22);
        vm.prank(a);
        pm.mint(key, amount, amount, a);
    }

    function burn(uint256 seed, uint256 shareSeed) external {
        address a = _actor(seed);
        uint256 bal = pm.balanceOf(a, shareId);
        if (bal == 0) return;
        uint256 shares = bound(shareSeed, 1, bal);
        vm.prank(a);
        pm.burn(key, uint128(shares), a);
    }

    function swap(uint256 amount, bool zeroForOne) external {
        amount = bound(amount, 1e12, 1e20);
        PoolSwapTest.TestSettings memory s = PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
        IPoolManager.SwapParams memory p = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: -int256(amount),
            sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        });
        swapRouter.swap(key, p, s, "");
    }

    // --- vault actions ---

    function stake(uint256 seed, uint256 amount) external {
        address a = _actor(seed);
        uint256 bal = strand.balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        vm.prank(a);
        vault.stake(amount);
    }

    function depositRewards(uint256 amount0, uint256 amount1) external {
        if (vault.totalShares() == 0) return;
        amount0 = bound(amount0, 0, IERC20(token0).balanceOf(address(this)));
        amount1 = bound(amount1, 0, IERC20(token1).balanceOf(address(this)));
        if (amount0 == 0 && amount1 == 0) return;
        vault.depositRewards(amount0, amount1);
    }

    // --- environment ---

    function moveOracle(uint256 priceSeed) external {
        oracle0.setPrice(bound(priceSeed, 0.5e18, 2e18));
    }

    function moveOracleTimestamps(uint32 difference, bool reverse) external {
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

    function toggleMarket(uint256 seed) external {
        marketHours.setOpen(seed % 2 == 0);
    }

    // --- views for invariants ---

    function sumPmShares() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; i++) {
            total += pm.balanceOf(actors[i], shareId);
        }
    }

    function sumVaultShares() external view returns (uint256 total) {
        for (uint256 i; i < actors.length; i++) {
            total += vault.sharesOf(actors[i]);
        }
    }

    function positionLiquidity() external view returns (uint128 liquidity) {
        (liquidity,,) = manager.getPositionInfo(id, address(pm), tickLower, tickUpper, bytes32(0));
    }
}
