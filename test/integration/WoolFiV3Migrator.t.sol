// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {
    WoolFiV3Migrator,
    INonfungiblePositionManagerLike,
    IWoolFiPositionManagerMintV3
} from "../../src/periphery/WoolFiV3Migrator.sol";
import {MockPriceOracle} from "../../src/mocks/MockPriceOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {MockERC20} from "../../src/mocks/MockERC20.sol";

/// @notice Minimal v3 NonfungiblePositionManager stand-in. Each position stores token amounts
///         per unit of liquidity; decreaseLiquidity moves principal into tokensOwed, collect pays
///         tokensOwed out. Enforces the same owner-or-approved rule the real NPM does.
contract MockV3PositionManager {
    struct Position {
        address token0;
        address token1;
        uint128 liquidity;
        uint256 amount0PerLiquidity; // scaled 1e18
        uint256 amount1PerLiquidity; // scaled 1e18
        uint128 owed0;
        uint128 owed1;
    }

    mapping(uint256 => Position) public pos;
    mapping(uint256 => address) public ownerOf;
    mapping(uint256 => address) public getApproved;

    function create(
        uint256 tokenId,
        address owner,
        address token0,
        address token1,
        uint128 liquidity,
        uint256 amount0PerLiquidity,
        uint256 amount1PerLiquidity,
        uint128 fees0,
        uint128 fees1
    ) external {
        ownerOf[tokenId] = owner;
        pos[tokenId] = Position(token0, token1, liquidity, amount0PerLiquidity, amount1PerLiquidity, fees0, fees1);
    }

    function approve(address to, uint256 tokenId) external {
        require(msg.sender == ownerOf[tokenId], "not owner");
        getApproved[tokenId] = to;
    }

    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            uint24,
            int24,
            int24,
            uint128 liquidity,
            uint256,
            uint256,
            uint128 owed0,
            uint128 owed1
        )
    {
        Position memory p = pos[tokenId];
        return (0, address(0), p.token0, p.token1, 3000, -60, 60, p.liquidity, 0, 0, p.owed0, p.owed1);
    }

    function _auth(uint256 tokenId) private view {
        require(msg.sender == ownerOf[tokenId] || msg.sender == getApproved[tokenId], "Not approved");
    }

    function decreaseLiquidity(INonfungiblePositionManagerLike.DecreaseLiquidityParams calldata p)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        _auth(p.tokenId);
        require(block.timestamp <= p.deadline, "Transaction too old");
        Position storage s = pos[p.tokenId];
        require(p.liquidity > 0 && p.liquidity <= s.liquidity, "bad liquidity");
        amount0 = uint256(p.liquidity) * s.amount0PerLiquidity / 1e18;
        amount1 = uint256(p.liquidity) * s.amount1PerLiquidity / 1e18;
        require(amount0 >= p.amount0Min && amount1 >= p.amount1Min, "Price slippage check");
        s.liquidity -= p.liquidity;
        s.owed0 += uint128(amount0);
        s.owed1 += uint128(amount1);
    }

    function collect(INonfungiblePositionManagerLike.CollectParams calldata p)
        external
        payable
        returns (uint256 amount0, uint256 amount1)
    {
        _auth(p.tokenId);
        Position storage s = pos[p.tokenId];
        amount0 = s.owed0 < p.amount0Max ? s.owed0 : p.amount0Max;
        amount1 = s.owed1 < p.amount1Max ? s.owed1 : p.amount1Max;
        s.owed0 -= uint128(amount0);
        s.owed1 -= uint128(amount1);
        if (amount0 > 0) IERC20(s.token0).transfer(p.recipient, amount0);
        if (amount1 > 0) IERC20(s.token1).transfer(p.recipient, amount1);
    }
}

contract WoolFiV3MigratorTest is Deployers {
    using PoolIdLibrary for PoolKey;

    WoolFiHook hook;
    WoolFiPositionManager pm;
    MockV3PositionManager npm;
    WoolFiV3Migrator migrator;
    PoolKey wkey;
    address token0;
    address token1;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 constant TOKEN_ID = 42;

    function setUp() public {
        deployFreshManagerAndRouters();
        (currency0, currency1) = deployMintAndApprove2Currencies();
        token0 = Currency.unwrap(currency0);
        token1 = Currency.unwrap(currency1);
        hook = _deployHook();
        wkey = _initialize();
        pm = new WoolFiPositionManager(manager, address(this));
        npm = new MockV3PositionManager();
        migrator = new WoolFiV3Migrator(
            INonfungiblePositionManagerLike(address(npm)), IWoolFiPositionManagerMintV3(address(pm))
        );

        // NPM holds the underlying for the mock position.
        IERC20(token0).transfer(address(npm), 10_000e18);
        IERC20(token1).transfer(address(npm), 10_000e18);
        // Concentrated-style position: 100 liquidity units -> 100 token0 + 80 token1, plus fees.
        npm.create(TOKEN_ID, alice, token0, token1, 100e18, 1e18, 0.8e18, 2e18, 3e18);
        vm.prank(alice);
        npm.approve(address(migrator), TOKEN_ID);
    }

    function _deployHook() private returns (WoolFiHook deployedHook) {
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        address hookAddr = address(flags | (uint160(0x6666) << 144));
        deployCodeTo("WoolFiHook.sol:WoolFiHook", abi.encode(manager, address(this)), hookAddr);
        deployedHook = WoolFiHook(hookAddr);
    }

    function _initialize() private returns (PoolKey memory poolKey) {
        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        hook.authorizePool(
            poolKey,
            WoolFiHook.AuthParams({
                oracle0: new MockPriceOracle(1e18),
                oracle1: new MockPriceOracle(1e18),
                marketHours: new MockMarketHours(true),
                kScaled: 40_000,
                baseFeeBps: 30,
                toleranceBps: 500,
                hardThresholdBps: 1500
            })
        );
        manager.initialize(poolKey, SQRT_PRICE_1_1);
    }

    function _params(uint128 liquidity, uint128 minShares)
        private
        view
        returns (WoolFiV3Migrator.MigrateParams memory)
    {
        return WoolFiV3Migrator.MigrateParams({
            tokenId: TOKEN_ID,
            woolfiKey: wkey,
            liquidity: liquidity,
            amount0Min: 0,
            amount1Min: 0,
            minShares: minShares,
            deadline: block.timestamp + 1 hours,
            recipient: alice
        });
    }

    function test_migrate_fullPosition_mintsSharesAndRefundsLeftover() public {
        uint256 a0Before = IERC20(token0).balanceOf(alice);
        uint256 a1Before = IERC20(token1).balanceOf(alice);
        uint256 id = uint256(keccak256(abi.encode(wkey)));

        vm.prank(alice);
        uint128 shares = migrator.migrate(_params(0, 1));

        assertGt(shares, 0, "shares minted");
        assertEq(pm.balanceOf(alice, id), shares, "shares credited to recipient");
        // Collected 102 token0 / 83 token1 (principal + fees). At a 1:1 pool price the full-range
        // mint is bounded by token1: ~83 of each consumed, ~19 token0 refunded.
        uint256 refund0 = IERC20(token0).balanceOf(alice) - a0Before;
        uint256 refund1 = IERC20(token1).balanceOf(alice) - a1Before;
        assertApproxEqAbs(refund0, 19e18, 1e15, "token0 leftover refunded");
        assertLt(refund1, 1e15, "token1 almost fully used");

        (,, uint128 liqLeft,,,,) = npm.pos(TOKEN_ID);
        assertEq(liqLeft, 0, "v3 position emptied");
        assertEq(npm.ownerOf(TOKEN_ID), alice, "NFT stays with owner");
        _assertMigratorClean();
    }

    function test_migrate_partialLiquidity() public {
        vm.prank(alice);
        uint128 shares = migrator.migrate(_params(40e18, 1));
        assertGt(shares, 0);
        (,, uint128 liqLeft,,,,) = npm.pos(TOKEN_ID);
        assertEq(liqLeft, 60e18, "only requested liquidity removed");
        _assertMigratorClean();
    }

    function test_migrate_emitsEvent() public {
        vm.expectEmit(true, true, true, false, address(migrator));
        emit WoolFiV3Migrator.Migrated(alice, TOKEN_ID, alice, 100e18, 0, 0, 0, 0, 0);
        vm.prank(alice);
        migrator.migrate(_params(0, 1));
    }

    function testRevert_migrate_wrongPair() public {
        MockERC20 other = new MockERC20("OTHER", "OTH", 18);
        npm.create(7, alice, token0, address(other), 1e18, 1e18, 1e18, 0, 0);
        vm.prank(alice);
        npm.approve(address(migrator), 7);
        WoolFiV3Migrator.MigrateParams memory p = _params(0, 1);
        p.tokenId = 7;
        vm.prank(alice);
        vm.expectRevert(WoolFiV3Migrator.PairMismatch.selector);
        migrator.migrate(p);
    }

    function testRevert_migrate_notOwner() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(WoolFiV3Migrator.NotPositionOwner.selector, bob, alice));
        migrator.migrate(_params(0, 1));
    }

    function testRevert_migrate_minShares() public {
        vm.prank(alice);
        vm.expectRevert(); // WoolFiPositionManager.InsufficientShares
        migrator.migrate(_params(0, type(uint128).max));
        (,, uint128 liq,,,,) = npm.pos(TOKEN_ID);
        assertEq(liq, 100e18, "atomic: v3 position untouched on revert");
    }

    function testRevert_migrate_expiredDeadline() public {
        WoolFiV3Migrator.MigrateParams memory p = _params(0, 1);
        p.deadline = block.timestamp - 1;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WoolFiV3Migrator.DeadlineExpired.selector, p.deadline));
        migrator.migrate(p);
    }

    function testRevert_migrate_zeroRecipient() public {
        WoolFiV3Migrator.MigrateParams memory p = _params(0, 1);
        p.recipient = address(0);
        vm.prank(alice);
        vm.expectRevert(WoolFiV3Migrator.ZeroAddress.selector);
        migrator.migrate(p);
    }

    function testRevert_migrate_liquidityTooHigh() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WoolFiV3Migrator.LiquidityTooHigh.selector, 101e18, 100e18));
        migrator.migrate(_params(101e18, 1));
    }

    function testRevert_migrate_singleSided() public {
        // Out-of-range v3 position: all token0, no token1, no fees.
        npm.create(9, alice, token0, token1, 10e18, 1e18, 0, 0, 0);
        vm.prank(alice);
        npm.approve(address(migrator), 9);
        WoolFiV3Migrator.MigrateParams memory p = _params(0, 1);
        p.tokenId = 9;
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(WoolFiV3Migrator.SingleSidedPosition.selector, 10e18, 0));
        migrator.migrate(p);
    }

    function testRevert_migrate_nothingToMigrate() public {
        npm.create(11, alice, token0, token1, 0, 1e18, 1e18, 0, 0);
        WoolFiV3Migrator.MigrateParams memory p = _params(0, 1);
        p.tokenId = 11;
        vm.prank(alice);
        vm.expectRevert(WoolFiV3Migrator.NothingToMigrate.selector);
        migrator.migrate(p);
    }

    function testRevert_migrate_withoutApproval() public {
        npm.create(12, bob, token0, token1, 10e18, 1e18, 1e18, 0, 0);
        WoolFiV3Migrator.MigrateParams memory p = _params(0, 1);
        p.tokenId = 12;
        vm.prank(bob);
        vm.expectRevert(bytes("Not approved"));
        migrator.migrate(p);
    }

    function test_migrate_feesOnlyPosition() public {
        // Liquidity already removed, only uncollected fees left: collected and deposited.
        npm.create(13, alice, token0, token1, 0, 1e18, 1e18, 5e18, 5e18);
        vm.prank(alice);
        npm.approve(address(migrator), 13);
        WoolFiV3Migrator.MigrateParams memory p = _params(0, 1);
        p.tokenId = 13;
        vm.prank(alice);
        uint128 shares = migrator.migrate(p);
        assertGt(shares, 0);
        _assertMigratorClean();
    }

    function test_migrate_doesNotSweepStrayBalance() public {
        IERC20(token0).transfer(address(migrator), 7e18); // someone sends tokens by mistake
        uint256 a0Before = IERC20(token0).balanceOf(alice);
        vm.prank(alice);
        migrator.migrate(_params(0, 1));
        assertApproxEqAbs(IERC20(token0).balanceOf(alice) - a0Before, 19e18, 1e15, "refund excludes stray");
        assertEq(IERC20(token0).balanceOf(address(migrator)), 7e18, "stray balance untouched");
    }

    function testRevert_constructor_zeroAddress() public {
        vm.expectRevert(WoolFiV3Migrator.ZeroAddress.selector);
        new WoolFiV3Migrator(INonfungiblePositionManagerLike(address(0)), IWoolFiPositionManagerMintV3(address(pm)));
    }

    function _assertMigratorClean() private view {
        assertEq(IERC20(token0).balanceOf(address(migrator)), 0, "no token0 left");
        assertEq(IERC20(token1).balanceOf(address(migrator)), 0, "no token1 left");
        assertEq(IERC20(token0).allowance(address(migrator), address(pm)), 0, "token0 approval reset");
        assertEq(IERC20(token1).allowance(address(migrator), address(pm)), 0, "token1 approval reset");
    }
}
