// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {WoolFiPoolAligner} from "../../src/periphery/WoolFiPoolAligner.sol";
import {STRAND} from "../../src/STRAND.sol";
import {SpreadMath} from "../../src/lib/SpreadMath.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

/// @notice Empty-pool realignment: an unseeded pool is moved to its oracle fair price at zero cost so
///         the first LP is never blocked by OutOfBand and an empty pool cannot sit past the break line.
contract WoolFiPoolAlignerTest is Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiPoolAligner aligner;
    WoolFiUnderwritingVault vault;
    STRAND strand;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    PoolKey poolKey;
    PoolId poolId;

    address lp = makeAddr("lp");
    address anyone = makeAddr("anyone");

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x6666) << 144));
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(this)), hookAddr);
        hook = WoolFiHook(hookAddr);

        oracle0 = new MockPriceOracle(1e18);
        oracle1 = new MockPriceOracle(1e18);
        marketHours = new MockMarketHours(true);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        poolId = poolKey.toId();
        hook.authorizePool(
            poolKey,
            WoolFiHook.AuthParams({
                oracle0: oracle0,
                oracle1: oracle1,
                marketHours: marketHours,
                kScaled: 40_000,
                baseFeeBps: 30,
                toleranceBps: 500,
                hardThresholdBps: 1500
            })
        );
        // Unseeded launch: initialized at the launch price, no liquidity.
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        pm = new WoolFiPositionManager(manager, address(this));
        hook.setPositionManager(address(pm));
        aligner = new WoolFiPoolAligner(manager);

        strand = new STRAND(address(this));
        vault = new WoolFiUnderwritingVault(
            address(strand),
            address(hook),
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            makeAddr("rebalancer"),
            1_000e18
        );
        strand.mint(address(this), 1000e18);
        strand.approve(address(vault), type(uint256).max);
        vault.stake(1000e18);
        hook.setVault(poolKey, address(vault), 2000);

        IERC20(Currency.unwrap(currency0)).transfer(lp, 1e24);
        IERC20(Currency.unwrap(currency1)).transfer(lp, 1e24);
        vm.startPrank(lp);
        IERC20(Currency.unwrap(currency0)).approve(address(pm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(pm), type(uint256).max);
        vm.stopPrank();

        vm.warp(10 days);
        marketHours.setSessionStart(block.timestamp - 1 days);
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 900, maxOracleSkew: 0}));
    }

    function _drift() internal view returns (int256) {
        return hook.currentDrift(poolKey);
    }

    function _mint() internal returns (uint128) {
        vm.prank(lp);
        return pm.mint(poolKey, 1e21, 1e21, lp);
    }

    function _flagBreak(uint256 price0) internal {
        oracle0.setPrice(price0);
        hook.checkStructuralBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertTrue(broken, "break flagged on empty pool");
    }

    // ------------------------------------------------------------------
    // Core behavior
    // ------------------------------------------------------------------

    function test_align_movesEmptyPoolToFair_atZeroCost() public {
        oracle0.setPrice(1.1e18);
        assertEq(_drift(), -909, "launch price is ~9% below fair");

        uint256 m0 = currency0.balanceOf(address(manager));
        uint256 m1 = currency1.balanceOf(address(manager));
        vm.prank(anyone);
        assertTrue(aligner.align(poolKey));

        assertEq(_drift(), 0, "aligned to fair");
        assertEq(currency0.balanceOf(address(manager)), m0, "no token0 moved");
        assertEq(currency1.balanceOf(address(manager)), m1, "no token1 moved");
        assertEq(currency0.balanceOf(address(aligner)) + currency1.balanceOf(address(aligner)), 0, "holds nothing");
        assertEq(currency0.balanceOf(anyone) + currency1.balanceOf(anyone), 0, "caller paid nothing");
    }

    function test_align_noopWhenAlreadyAligned() public {
        assertFalse(aligner.align(poolKey));
        oracle0.setPrice(0.8e18);
        assertTrue(aligner.align(poolKey));
        assertFalse(aligner.align(poolKey), "second call is a no-op");
    }

    function testRevert_align_poolHasLiquidity() public {
        uint128 shares = _mint();
        oracle0.setPrice(1.02e18);
        vm.expectRevert(abi.encodeWithSelector(WoolFiPoolAligner.PoolHasLiquidity.selector, shares));
        aligner.align(poolKey);
    }

    function testRevert_align_unconfiguredPool() public {
        PoolKey memory other = poolKey;
        other.tickSpacing = 10;
        vm.expectRevert(WoolFiPoolAligner.PoolNotConfigured.selector);
        aligner.align(other);
    }

    function testRevert_unlockCallback_onlyPoolManager() public {
        vm.expectRevert(WoolFiPoolAligner.NotPoolManager.selector);
        aligner.unlockCallback("");
    }

    function testRevert_constructor_zeroAddress() public {
        vm.expectRevert(WoolFiPoolAligner.ZeroAddress.selector);
        new WoolFiPoolAligner(IPoolManager(address(0)));
    }

    // ------------------------------------------------------------------
    // First LP
    // ------------------------------------------------------------------

    function test_firstMint_blockedByDrift_thenSucceedsAfterAlign() public {
        oracle0.setPrice(1.1e18); // 10% oracle move since launch

        vm.prank(lp);
        vm.expectRevert(); // hook OutOfBand, wrapped by the PoolManager
        pm.mint(poolKey, 1e21, 1e21, lp);

        aligner.align(poolKey);
        assertGt(_mint(), 0, "first LP mints once aligned");
        assertEq(_drift(), 0);
    }

    // ------------------------------------------------------------------
    // Structural-break state on an empty pool
    // ------------------------------------------------------------------

    function test_falseBreak_alignThenConfirm_clearsWithoutDrawdown() public {
        _flagBreak(1.2e18);
        uint256 staked = strand.balanceOf(address(vault));

        aligner.align(poolKey); // corrective toward the cached target
        vm.warp(block.timestamp + 1 hours);
        hook.confirmStructuralBreak(poolKey);

        (bool broken, bool confirmed,,) = hook.breakStatus(poolKey);
        assertFalse(broken, "break cleared");
        assertFalse(confirmed);
        assertEq(strand.balanceOf(address(vault)), staked, "no drawdown");
    }

    function test_confirmedBreak_alignThenClearRecoveredBreak() public {
        _flagBreak(1.2e18);
        vm.warp(block.timestamp + 1 hours);
        hook.confirmStructuralBreak(poolKey); // nobody aligned in time: confirmed
        (, bool confirmed,,) = hook.breakStatus(poolKey);
        assertTrue(confirmed);

        aligner.align(poolKey);
        hook.clearRecoveredBreak(poolKey);
        (bool broken,,,) = hook.breakStatus(poolKey);
        assertFalse(broken, "recovered");
        assertGt(_mint(), 0, "deposits reopen");
    }

    function test_break_fairOnOtherSide_hopsThroughCachedTarget() public {
        _flagBreak(1.2e18); // cached target 1.2, pool at 1.0
        oracle0.setPrice(0.8e18); // fair now below the pool: direct move would be adversarial

        assertTrue(aligner.align(poolKey));
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        int256 driftVsFresh = SpreadMath.computeDrift(SpreadMath.poolPrice(sqrtP, 18, 18), 0.8e18);
        assertEq(driftVsFresh, 0, "landed on fresh fair");
    }

    // ------------------------------------------------------------------
    // Hook modes
    // ------------------------------------------------------------------

    function test_align_marketClosed_usesLastValidPrint() public {
        oracle0.setPrice(1.1e18);
        marketHours.setOpen(false);
        oracle0.setStale(true);
        oracle1.setStale(true);
        assertTrue(aligner.align(poolKey));

        oracle0.setStale(false);
        oracle1.setStale(false);
        assertEq(_drift(), 0);
    }

    function test_align_duringStabilization() public {
        oracle0.setPrice(0.9e18);
        marketHours.setSessionStart(block.timestamp);
        assertTrue(aligner.align(poolKey));
        assertEq(_drift(), 0);
    }

    function test_align_whileOracleSkewed() public {
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 900, maxOracleSkew: 60}));
        oracle0.setPrice(1.1e18);
        oracle1.setPriceData(1e18, block.timestamp - 1000);
        (,,, bool skewed) = hook.poolSafetyStatus(poolKey);
        assertTrue(skewed);
        assertTrue(aligner.align(poolKey));
        assertEq(_drift(), 0);
    }

    function testRevert_align_whenPaused() public {
        oracle0.setPrice(1.1e18);
        hook.setPaused(true);
        vm.expectRevert();
        aligner.align(poolKey);
    }

    function testRevert_align_staleOracleWhileLive() public {
        oracle0.setPrice(1.1e18);
        oracle0.setStale(true);
        vm.expectRevert();
        aligner.align(poolKey);
    }

    function testRevert_align_oracleRuntimeUnsafe() public {
        oracle0.setPrice(1.1e18);
        oracle0.setRuntimeUnsafe(true);
        vm.expectRevert(MockPriceOracle.MockRuntimeUnsafe.selector);
        aligner.align(poolKey);
    }

    // ------------------------------------------------------------------
    // Fuzz
    // ------------------------------------------------------------------

    /// @dev Any oracle move between -60% and +150% is fully corrected in one call.
    function testFuzz_align_landsWithin1Bps(int256 moveBps) public {
        moveBps = bound(moveBps, -6000, 15_000);
        oracle0.setPrice(uint256(1e18 * (10_000 + moveBps) / 10_000));
        aligner.align(poolKey);
        assertEq(_drift(), 0, "post-align drift under 1 bps");
        assertEq(manager.getLiquidity(poolId), 0);
    }

    /// @dev toSqrtPriceX96 inverts SpreadMath.poolPrice across realistic decimals and prices.
    function testFuzz_toSqrtPriceX96_roundTrips(uint256 fair, uint8 d0, uint8 d1) public view {
        d0 = uint8(bound(d0, 6, 18));
        d1 = uint8(bound(d1, 6, 18));
        fair = bound(fair, 1e9, 1e30); // 1e-9 to 1e12 token1 per token0
        // SpreadMath.poolPrice rounds the raw (smallest-unit) price to WAD before rescaling decimals, so
        // the hook itself cannot resolve 1 bps below ~1e-12 raw. Every Robinhood pair sits far above it
        // (the lowest is a ~$10 18-decimal stock against 6-decimal USDG: 1e-11 raw).
        vm.assume(fair * 10 ** uint256(d1) / 10 ** uint256(d0) >= 1e6);
        uint160 s = aligner.toSqrtPriceX96(fair, d0, d1);
        assertEq(SpreadMath.computeDrift(SpreadMath.poolPrice(s, d0, d1), fair), 0);
    }
}
