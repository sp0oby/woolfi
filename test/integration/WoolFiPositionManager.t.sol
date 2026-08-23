// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {STRAND} from "../../src/STRAND.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

contract WoolFiPositionManagerTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiPositionManager pm;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;

    PoolKey poolKey;
    PoolId poolId;
    uint256 shareId;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant FAIR_DRIFT_POS_800 = 925_925_925_925_925_926;
    uint256 constant FAIR_DRIFT_NEG_800 = 1_086_956_521_739_130_435;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();

        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x4444) << 144));
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
        shareId = uint256(PoolId.unwrap(poolId));

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
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        pm = new WoolFiPositionManager(manager, address(this));
        _fundAndApprove(alice);
        _fundAndApprove(bob);
    }

    function _fundAndApprove(address lp) internal {
        IERC20(Currency.unwrap(currency0)).transfer(lp, 1e24);
        IERC20(Currency.unwrap(currency1)).transfer(lp, 1e24);
        vm.startPrank(lp);
        IERC20(Currency.unwrap(currency0)).approve(address(pm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(pm), type(uint256).max);
        vm.stopPrank();
    }

    function _bal(Currency c, address who) internal view returns (uint256) {
        return IERC20(Currency.unwrap(c)).balanceOf(who);
    }

    // -----------------------------------------------------------------
    // DoD: two LPs deposit, drift, one withdraws — wei-exact pro-rata
    // -----------------------------------------------------------------

    /// @notice Equal LPs deposit, the spread drifts (oracle only, no swap so no fees), then both
    ///         withdraw — they must receive identical amounts to the wei (exact pro-rata of reserves).
    function test_equalLPs_driftNoSwap_withdrawIsWeiExact() public {
        vm.prank(alice);
        uint128 sa = pm.mint(poolKey, 100e18, 100e18, alice);
        vm.prank(bob);
        uint128 sb = pm.mint(poolKey, 100e18, 100e18, bob);
        assertEq(sa, sb); // identical deposits -> identical shares/liquidity

        // spread drifts purely via the oracle; the pool price (and reserves) are unchanged
        oracle0.setPrice(FAIR_DRIFT_POS_800);

        uint256 a0Before = _bal(currency0, alice);
        uint256 a1Before = _bal(currency1, alice);
        uint256 b0Before = _bal(currency0, bob);
        uint256 b1Before = _bal(currency1, bob);

        vm.prank(alice);
        pm.burn(poolKey, sa, alice);
        vm.prank(bob);
        pm.burn(poolKey, sb, bob);

        uint256 aOut0 = _bal(currency0, alice) - a0Before;
        uint256 aOut1 = _bal(currency1, alice) - a1Before;
        uint256 bOut0 = _bal(currency0, bob) - b0Before;
        uint256 bOut1 = _bal(currency1, bob) - b1Before;

        assertEq(aOut0, bOut0);
        assertEq(aOut1, bOut1);
        assertGt(aOut0, 0);
        assertEq(pm.totalShares(shareId), 0); // position fully drained
    }

    /// @notice Unequal LPs withdraw in proportion to their shares (within 1-wei rounding dust).
    function test_unequalLPs_withdrawProRata() public {
        vm.prank(alice);
        uint128 sa = pm.mint(poolKey, 100e18, 100e18, alice);
        vm.prank(bob);
        uint128 sb = pm.mint(poolKey, 50e18, 50e18, bob);

        uint256 a0Before = _bal(currency0, alice);
        uint256 b0Before = _bal(currency0, bob);
        vm.prank(alice);
        pm.burn(poolKey, sa, alice);
        vm.prank(bob);
        pm.burn(poolKey, sb, bob);
        uint256 aOut0 = _bal(currency0, alice) - a0Before;
        uint256 bOut0 = _bal(currency0, bob) - b0Before;

        // aOut0 / bOut0 == sa / sb  (cross-multiplied, allowing tiny rounding)
        assertApproxEqAbs(aOut0 * sb, bOut0 * sa, uint256(sa) + sb);
    }

    // -----------------------------------------------------------------
    // fees: pro-rata distribution, no JIT-steal
    // -----------------------------------------------------------------

    function test_fees_distributedProRata_noJitSteal() public {
        vm.prank(alice);
        uint128 sa = pm.mint(poolKey, 100e18, 100e18, alice);
        vm.prank(bob);
        uint128 sb = pm.mint(poolKey, 50e18, 50e18, bob);

        // generate fees in both tokens (in band -> base fee)
        swap(poolKey, true, -1e18, ZERO_BYTES);
        swap(poolKey, false, -1e18, ZERO_BYTES);

        // alice collects first; she must NOT be able to drain bob's share
        vm.prank(alice);
        (uint256 aFee0,) = pm.collectFees(poolKey, alice);
        vm.prank(bob);
        (uint256 bFee0,) = pm.collectFees(poolKey, bob);

        assertGt(aFee0, 0);
        assertGt(bFee0, 0);
        // aFee0 : bFee0 ≈ sa : sb
        assertApproxEqRel(aFee0 * sb, bFee0 * sa, 0.01e18); // within 1%
    }

    // -----------------------------------------------------------------
    // guards
    // -----------------------------------------------------------------

    function testRevert_transfer_disabled() public {
        vm.prank(alice);
        pm.mint(poolKey, 100e18, 100e18, alice);
        vm.prank(alice);
        vm.expectRevert(WoolFiPositionManager.TransfersDisabled.selector);
        pm.transfer(bob, shareId, 1);
    }

    function testRevert_mint_outOfBand() public {
        oracle0.setPrice(FAIR_DRIFT_NEG_800); // out of band
        vm.prank(alice);
        // hook's OutOfBand is double-wrapped (PoolManager + unlock); asserted specifically in the hook tests
        vm.expectRevert();
        pm.mint(poolKey, 100e18, 100e18, alice);
    }

    function testRevert_unlockCallback_notPoolManager() public {
        vm.expectRevert(WoolFiPositionManager.NotPoolManager.selector);
        pm.unlockCallback("");
    }

    // -----------------------------------------------------------------
    // fee routing (vault 20% / buyback 10% / LP 70%) — spec §7.3
    // -----------------------------------------------------------------

    function _vaultWithStaker() internal returns (WoolFiUnderwritingVault vault) {
        STRAND strand = new STRAND(address(this));
        address staker = makeAddr("staker");
        strand.mint(staker, 1000e18);
        vault = new WoolFiUnderwritingVault(
            address(strand), address(this), Currency.unwrap(currency0), Currency.unwrap(currency1), makeAddr("reb")
        );
        vm.startPrank(staker);
        strand.approve(address(vault), type(uint256).max);
        vault.stake(1000e18);
        vm.stopPrank();
    }

    function test_feeRouting_splitsVaultBuybackLp() public {
        WoolFiUnderwritingVault vault = _vaultWithStaker();
        address buyback = makeAddr("buyback");
        pm.setFeeConfig(poolKey, address(vault), 2000, buyback, 1000);

        vm.prank(alice);
        pm.mint(poolKey, 100e18, 100e18, alice);
        swap(poolKey, true, -1e18, ZERO_BYTES);
        swap(poolKey, false, -1e18, ZERO_BYTES);

        uint256 vaultBefore = _bal(currency0, address(vault));
        uint256 buybackBefore = _bal(currency0, buyback);

        vm.prank(alice);
        pm.collectFees(poolKey, alice); // poke routes the realized fees

        uint256 vaultGot = _bal(currency0, address(vault)) - vaultBefore;
        uint256 buybackGot = _bal(currency0, buyback) - buybackBefore;

        assertGt(vaultGot, 0);
        assertGt(buybackGot, 0);
        assertApproxEqAbs(vaultGot, buybackGot * 2, 2); // 20% == 2 x 10%
    }

    /// @notice With the PM wired into the hook, every swap routes accrued fees automatically —
    ///         no LP touch (mint/burn/collectFees) required. This is the production fix for the
    ///         "vault rewards stay at zero between LP interactions" problem.
    function test_feeRouting_autoRealizesFromAfterSwap() public {
        WoolFiUnderwritingVault vault = _vaultWithStaker();
        address buyback = makeAddr("buyback");
        pm.setFeeConfig(poolKey, address(vault), 2000, buyback, 1000);

        // Wire the PM into the hook — this is what enables auto-realization.
        hook.setPositionManager(address(pm));

        // Seed liquidity, then do swaps. No collectFees / burn afterwards.
        vm.prank(alice);
        pm.mint(poolKey, 100e18, 100e18, alice);
        uint256 vaultBefore = _bal(currency0, address(vault));
        uint256 buybackBefore = _bal(currency0, buyback);

        swap(poolKey, true, -1e18, ZERO_BYTES);
        swap(poolKey, false, -1e18, ZERO_BYTES);

        // No LP touch happened after the swaps — yet vault and buyback already received their cuts.
        assertGt(_bal(currency0, address(vault)) - vaultBefore, 0, "vault auto-credited from afterSwap");
        assertGt(_bal(currency0, buyback) - buybackBefore, 0, "buyback auto-credited from afterSwap");
    }

    /// @notice With the PM unset on the hook, afterSwap is a no-op for fee realization — fees
    ///         remain unrealized until an LP touches the PM. Confirms the gating is honored.
    function test_feeRouting_skipsAutoRealizeWhenPmUnset() public {
        WoolFiUnderwritingVault vault = _vaultWithStaker();
        address buyback = makeAddr("buyback");
        pm.setFeeConfig(poolKey, address(vault), 2000, buyback, 1000);
        // Deliberately do NOT call hook.setPositionManager — auto-realize stays disabled.

        vm.prank(alice);
        pm.mint(poolKey, 100e18, 100e18, alice);
        uint256 vaultBefore = _bal(currency0, address(vault));

        swap(poolKey, true, -1e18, ZERO_BYTES);

        assertEq(_bal(currency0, address(vault)), vaultBefore, "vault stays empty until LP touch");
    }

    function testRevert_realizeFromHook_notHook() public {
        vm.expectRevert(WoolFiPositionManager.NotHook.selector);
        pm.realizeFromHook(poolKey);
    }

    /// @notice With a vault configured but no stakers, its cut folds back to LPs (no stranded fees).
    function test_feeRouting_vaultCutFoldsBackWhenNoStakers() public {
        STRAND strand = new STRAND(address(this));
        WoolFiUnderwritingVault emptyVault = new WoolFiUnderwritingVault(
            address(strand), address(this), Currency.unwrap(currency0), Currency.unwrap(currency1), makeAddr("reb")
        );
        address buyback = makeAddr("buyback");
        pm.setFeeConfig(poolKey, address(emptyVault), 2000, buyback, 1000);

        vm.prank(alice);
        pm.mint(poolKey, 100e18, 100e18, alice);
        swap(poolKey, true, -1e18, ZERO_BYTES);

        uint256 buybackBefore = _bal(currency0, buyback);
        vm.prank(alice);
        pm.collectFees(poolKey, alice);

        assertEq(_bal(currency0, address(emptyVault)), 0); // vault got nothing (no stakers)
        assertGt(_bal(currency0, buyback) - buybackBefore, 0); // buyback still taken
    }

    function testRevert_setFeeConfig_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(WoolFiPositionManager.NotOwner.selector);
        pm.setFeeConfig(poolKey, address(0xCAFE), 2000, address(0xBEEF), 1000);
    }

    function testRevert_setFeeConfig_cutTooHigh() public {
        vm.expectRevert(WoolFiPositionManager.InvalidFeeConfig.selector);
        pm.setFeeConfig(poolKey, address(0xCAFE), 4000, address(0xBEEF), 1001); // > 50%
    }

    function test_setOwner_updates() public {
        pm.setOwner(alice);
        assertEq(pm.owner(), alice);
    }

    function testRevert_setOwner_notOwner() public {
        vm.prank(alice);
        vm.expectRevert(WoolFiPositionManager.NotOwner.selector);
        pm.setOwner(alice);
    }

    /// @notice `pendingFees` (post-poke) equals what the LP then collects.
    function test_pendingFees_matchesCollect() public {
        vm.prank(alice);
        pm.mint(poolKey, 100e18, 100e18, alice);
        vm.prank(bob);
        pm.mint(poolKey, 50e18, 50e18, bob);

        swap(poolKey, true, -1e18, ZERO_BYTES);
        swap(poolKey, false, -1e18, ZERO_BYTES);

        vm.prank(alice);
        pm.collectFees(poolKey, alice); // pokes the accumulator up to date

        (uint256 p0, uint256 p1) = pm.pendingFees(poolKey, bob);
        assertGt(p0, 0);

        vm.prank(bob);
        (uint256 c0, uint256 c1) = pm.collectFees(poolKey, bob);
        assertEq(c0, p0);
        assertEq(c1, p1);
    }

    function test_metadata() public view {
        assertEq(pm.name(shareId), "WoolFi LP");
        assertEq(pm.symbol(shareId), "WOOLFI-LP");
        assertEq(pm.tokenURI(shareId), "");
    }
}
