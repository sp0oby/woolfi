// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {STRAND} from "../../src/STRAND.sol";
import {RebalanceKeeper} from "../../src/RebalanceKeeper.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";

contract RebalanceKeeperTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiPositionManager pm;
    WoolFiUnderwritingVault vault;
    STRAND strand;
    RebalanceKeeper keeper;
    MockPriceOracle oracle0;
    MockPriceOracle oracle1;
    MockMarketHours marketHours;

    PoolKey poolKey;
    PoolId poolId;
    address alice = makeAddr("alice");
    address rebalancer = makeAddr("rebalancer");
    address treasury = makeAddr("treasury");

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

        // PM + vault + fee routing wired
        pm = new WoolFiPositionManager(manager, address(this));
        strand = new STRAND(address(this));
        vault = new WoolFiUnderwritingVault(
            address(strand), address(hook), Currency.unwrap(currency0), Currency.unwrap(currency1), rebalancer, 1_000e18
        );
        hook.setVault(poolKey, address(vault), 2000);
        pm.setFeeConfig(poolKey, address(vault), 2000, treasury, 1000);

        // a staker so vault.totalShares > 0 (so PM fee routing actually pushes to vault)
        address staker = makeAddr("staker");
        strand.mint(staker, 100e18);
        vm.startPrank(staker);
        strand.approve(address(vault), type(uint256).max);
        vault.stake(100e18);
        vm.stopPrank();

        // LP provides liquidity via PM, then a few swaps accrue fees
        IERC20(Currency.unwrap(currency0)).transfer(alice, 1e23);
        IERC20(Currency.unwrap(currency1)).transfer(alice, 1e23);
        vm.startPrank(alice);
        IERC20(Currency.unwrap(currency0)).approve(address(pm), type(uint256).max);
        IERC20(Currency.unwrap(currency1)).approve(address(pm), type(uint256).max);
        pm.mint(poolKey, 100e18, 100e18, alice);
        vm.stopPrank();
        swap(poolKey, true, -1e18, ZERO_BYTES);
        swap(poolKey, false, -1e18, ZERO_BYTES);

        keeper = new RebalanceKeeper(hook, pm);
    }

    /// @notice keep() does both jobs in one tx: forces break detection + routes accrued fees.
    function test_keep_triggersBreakAndRoutesFees() public {
        // drift past hard threshold WITHOUT a swap — only checkStructuralBreak can flag it now
        oracle0.setPrice(1.2e18);
        uint256 treasuryBefore = IERC20(Currency.unwrap(currency0)).balanceOf(treasury);

        vm.prank(makeAddr("anyone"));
        keeper.keep(poolKey);

        // break + drawdown happened
        assertTrue(hook.poolConfig(poolId).structuralBreak);
        assertLt(vault.totalStaked(), 100e18); // some STRAND seized

        // fee realization routed the treasury cut to its policy sink
        assertGt(IERC20(Currency.unwrap(currency0)).balanceOf(treasury), treasuryBefore);
    }

    function test_keep_isPermissionless_andHoldsNoFunds() public {
        oracle0.setPrice(1.08e18); // out of band, NOT past threshold
        vm.prank(makeAddr("randomCaller"));
        keeper.keep(poolKey); // no revert

        // keeper holds no funds afterward (fee harvest to keeper is 0 since it has no shares)
        assertEq(IERC20(Currency.unwrap(currency0)).balanceOf(address(keeper)), 0);
        assertEq(IERC20(Currency.unwrap(currency1)).balanceOf(address(keeper)), 0);
    }

    function testRevert_constructor_zeroAddress() public {
        vm.expectRevert(RebalanceKeeper.ZeroAddress.selector);
        new RebalanceKeeper(WoolFiHook(address(0)), pm);
    }
}
