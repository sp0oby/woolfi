// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {STRAND} from "../../src/STRAND.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {WoolFiHandler} from "./WoolFiHandler.sol";

/// @notice Stateful invariant suite over the full WoolFi system (hook + position manager + vault),
///         driven by {WoolFiHandler}. Asserts the accounting invariants from PROJECT_SPEC.md §5.3.
contract WoolFiInvariantsTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiUnderwritingVault vault;
    STRAND strand;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;
    WoolFiHandler handler;

    PoolKey poolKey;
    PoolId poolId;
    uint256 shareId;

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
        strand = new STRAND(address(this));
        vault = new WoolFiUnderwritingVault(
            address(strand),
            address(hook),
            Currency.unwrap(currency0),
            Currency.unwrap(currency1),
            makeAddr("rebalancer"),
            1_000_000e18
        );
        hook.setVault(poolKey, address(vault), 2000); // drawdowns fire on a break
        hook.setPoolSafety(poolKey, WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 300}));

        handler = new WoolFiHandler(hook, pm, vault, strand, oracle0, oracle1, marketHours, swapRouter, poolKey);

        _fundActorsAndHandler();
        _bootstrapLiquidity();

        targetContract(address(handler));
    }

    function _fundActorsAndHandler() internal {
        for (uint256 i; i < 3; i++) {
            address a = handler.actors(i);
            IERC20(Currency.unwrap(currency0)).transfer(a, 1e24);
            IERC20(Currency.unwrap(currency1)).transfer(a, 1e24);
            strand.mint(a, 1e24);
            vm.startPrank(a);
            IERC20(Currency.unwrap(currency0)).approve(address(pm), type(uint256).max);
            IERC20(Currency.unwrap(currency1)).approve(address(pm), type(uint256).max);
            strand.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        // the handler swaps and funds vault rewards from its own balance
        IERC20(Currency.unwrap(currency0)).transfer(address(handler), 1e24);
        IERC20(Currency.unwrap(currency1)).transfer(address(handler), 1e24);
        vm.startPrank(address(handler));
        IERC20(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        IERC20(Currency.unwrap(currency0)).approve(address(vault), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _bootstrapLiquidity() internal {
        address a = handler.actors(0);
        vm.prank(a);
        pm.mint(poolKey, 1e21, 1e21, a); // seed liquidity so swaps have a market
    }

    // -----------------------------------------------------------------
    // invariants (PROJECT_SPEC.md §5.3)
    // -----------------------------------------------------------------

    /// @notice LP shares are always exactly backed by the on-chain position (claims ≤ reserves).
    function invariant_pmSharesBackPosition() public view {
        assertEq(pm.totalShares(shareId), handler.positionLiquidity());
    }

    /// @notice All outstanding LP shares are held by tracked actors (no phantom shares).
    function invariant_pmShareAccounting() public view {
        assertEq(handler.sumPmShares(), pm.totalShares(shareId));
    }

    /// @notice The vault can always cover redemptions: staked accounting never exceeds STRAND held.
    function invariant_vaultSolvent() public view {
        assertLe(vault.totalStaked(), strand.balanceOf(address(vault)));
    }

    /// @notice All vault shares are held by tracked actors.
    function invariant_vaultShareAccounting() public view {
        assertEq(handler.sumVaultShares(), vault.totalShares());
    }

    /// @notice A break always has one immutable nonzero recovery target; resolution clears it.
    function invariant_structuralBreakTargetStateIsConsistent() public view {
        WoolFiHook.WoolFiConfig memory config = hook.poolConfig(poolId);
        if (config.structuralBreak) {
            assertGt(config.cachedFairPriceWad, 0);
        } else {
            assertEq(config.cachedFairPriceWad, 0);
        }
    }
}
