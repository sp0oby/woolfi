// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {
    WoolFiV3Migrator,
    INonfungiblePositionManagerLike,
    IWoolFiPositionManagerMintV3
} from "../../src/periphery/WoolFiV3Migrator.sol";
import {Deploy} from "../../script/Deploy.s.sol";

interface IV3NpmFork {
    function ownerOf(uint256) external view returns (address);
    function approve(address, uint256) external;
    function positions(uint256)
        external
        view
        returns (
            uint96,
            address,
            address token0,
            address token1,
            uint24 fee,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256,
            uint256,
            uint128,
            uint128
        );
}

interface IV3FactoryFork {
    function getPool(address, address, uint24) external view returns (address);
}

interface IV3PoolFork {
    function slot0() external view returns (uint160, int24 tick, uint16, uint16, uint16, uint8, bool);
}

/// @notice Live-fork: migrate a REAL Uniswap v3 WETH/USDG position on Robinhood Chain into a fresh
///         WoolFi WETH/USDG pool initialized at the live Chainlink price.
/// @dev Uses a list of real in-range position NFTs found on 2026-10-07 and picks the first one that
///      is still owned, funded, and in range at the fork block; skips cleanly if none qualify
///      (positions move, so the list is a hint, not a pin). Skips without ROBINHOOD_RPC_URL.
contract WoolFiV3MigratorForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 private constant FORK_HEARTBEAT = 7 days;
    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;
    address private constant V3_NPM = 0x73991a25C818Bf1f1128dEAaB1492D45638DE0D3;
    address private constant V3_FACTORY = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address private constant TOK_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant TOK_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant FEED_ETH = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    address private constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    WoolFiPositionManager pm;
    WoolFiV3Migrator migrator;
    PoolKey key;

    function test_fork_migrateRealV3WethUsdgPosition() public {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain");

        (uint256 tokenId, address owner) = _pickPosition();
        if (tokenId == 0) {
            emit log_string("no candidate v3 position still in range; skipping");
            vm.skip(true);
            return;
        }
        emit log_named_uint("v3 tokenId", tokenId);
        emit log_named_address("v3 owner", owner);

        _deployWoolFiWethUsdg();
        migrator =
            new WoolFiV3Migrator(INonfungiblePositionManagerLike(V3_NPM), IWoolFiPositionManagerMintV3(address(pm)));

        (,,,,,,, uint128 liqBefore,,,,) = IV3NpmFork(V3_NPM).positions(tokenId);
        uint256 weth0 = IERC20(TOK_WETH).balanceOf(owner);
        uint256 usdg0 = IERC20(TOK_USDG).balanceOf(owner);

        vm.startPrank(owner);
        IV3NpmFork(V3_NPM).approve(address(migrator), tokenId);
        uint128 shares = migrator.migrate(
            WoolFiV3Migrator.MigrateParams({
                tokenId: tokenId,
                woolfiKey: key,
                liquidity: 0,
                amount0Min: 0,
                amount1Min: 0,
                minShares: 1,
                deadline: block.timestamp + 1 hours,
                recipient: owner
            })
        );
        vm.stopPrank();

        uint256 id = uint256(PoolId.unwrap(key.toId()));
        (,,,,,,, uint128 liqAfter,,,,) = IV3NpmFork(V3_NPM).positions(tokenId);
        uint256 refundWeth = IERC20(TOK_WETH).balanceOf(owner) - weth0;
        uint256 refundUsdg = IERC20(TOK_USDG).balanceOf(owner) - usdg0;

        emit log_named_uint("v3 liquidity removed", liqBefore);
        emit log_named_uint("WoolFi LP shares minted", shares);
        emit log_named_decimal_uint("WETH refunded", refundWeth, 18);
        emit log_named_decimal_uint("USDG refunded", refundUsdg, 6);

        assertGt(shares, 0, "shares minted");
        assertEq(pm.balanceOf(owner, id), shares, "shares credited to owner");
        assertEq(liqAfter, 0, "v3 position emptied");
        assertEq(IV3NpmFork(V3_NPM).ownerOf(tokenId), owner, "NFT stays with owner");
        assertEq(IERC20(TOK_WETH).balanceOf(address(migrator)), 0, "migrator holds no WETH");
        assertEq(IERC20(TOK_USDG).balanceOf(address(migrator)), 0, "migrator holds no USDG");
        assertEq(IERC20(TOK_WETH).allowance(address(migrator), address(pm)), 0, "WETH approval reset");
        assertEq(IERC20(TOK_USDG).allowance(address(migrator), address(pm)), 0, "USDG approval reset");
    }

    function _pickPosition() private view returns (uint256 tokenId, address owner) {
        uint256[7] memory candidates = [uint256(1405504), 1405321, 1405242, 1405807, 1405838, 1405813, 1405509];
        for (uint256 i; i < candidates.length; ++i) {
            uint256 id = candidates[i];
            try IV3NpmFork(V3_NPM).ownerOf(id) returns (address o) {
                if (o.code.length != 0) continue; // prank-friendly EOAs only
                (,, address t0, address t1, uint24 fee, int24 lo, int24 hi, uint128 liq,,,,) =
                    IV3NpmFork(V3_NPM).positions(id);
                if (liq == 0 || t0 != TOK_WETH || t1 != TOK_USDG) continue;
                address pool = IV3FactoryFork(V3_FACTORY).getPool(t0, t1, fee);
                (, int24 tick,,,,,) = IV3PoolFork(pool).slot0();
                if (tick < lo || tick >= hi) continue; // out of range = single-sided
                return (id, o);
            } catch {
                continue; // burned
            }
        }
    }

    function _deployWoolFiWethUsdg() private {
        Deploy script = new Deploy();
        Deploy.Deployment memory dep =
            script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), address(this));
        WoolFiHook hook = WoolFiHook(dep.hook);
        WoolFiGovernor governor = WoolFiGovernor(dep.governor);
        pm = WoolFiPositionManager(dep.positionManager);
        governor.acceptOwnership();

        ChainlinkOracleAdapter ethOracle = new ChainlinkOracleAdapter(FEED_ETH, FORK_HEARTBEAT);
        ChainlinkOracleAdapter usdgOracle = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);

        // WETH sorts below USDG, so WETH is currency0. WETH/USDG is always-open (no hours oracle).
        key = PoolKey({
            currency0: Currency.wrap(TOK_WETH),
            currency1: Currency.wrap(TOK_USDG),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        governor.authorizePoolV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: ethOracle,
                    oracle1: usdgOracle,
                    marketHours: IMarketHoursOracle(address(0)),
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0})
            })
        );
        uint256 pWeth = ethOracle.getPrice();
        uint256 pUsdg = usdgOracle.getPrice();
        IPoolManager(POOL_MANAGER).initialize(key, _sqrtPriceX96(pWeth, pUsdg, 18, 6));

        // A small pre-existing LP so the migration is not the pool's first deposit.
        uint256 seedWeth = 0.5e18;
        uint256 seedUsdg = FullMath.mulDiv(seedWeth, pWeth, pUsdg) / 1e12;
        deal(TOK_WETH, address(this), seedWeth);
        deal(TOK_USDG, address(this), seedUsdg * 2);
        IERC20(TOK_WETH).approve(address(pm), type(uint256).max);
        IERC20(TOK_USDG).approve(address(pm), type(uint256).max);
        pm.mint(key, seedWeth, seedUsdg * 2, 1, block.timestamp + 1 hours, address(this));
    }

    function _sqrtPriceX96(uint256 price0Wad, uint256 price1Wad, uint8 dec0, uint8 dec1)
        private
        pure
        returns (uint160)
    {
        uint256 twoTo192 = uint256(1) << 192;
        uint256 ratioX192 = dec1 >= dec0
            ? FullMath.mulDiv(price0Wad * 10 ** uint256(dec1 - dec0), twoTo192, price1Wad)
            : FullMath.mulDiv(price0Wad, twoTo192, price1Wad * 10 ** uint256(dec0 - dec1));
        return uint160(FixedPointMathLib.sqrt(ratioX192));
    }
}
