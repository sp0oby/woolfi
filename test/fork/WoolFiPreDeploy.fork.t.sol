// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {WoolFiHook} from "../../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../../src/WoolFiGovernor.sol";
import {WoolFiPositionManager} from "../../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../../src/WoolFiUnderwritingVault.sol";
import {RobinhoodStockOracleAdapter} from "../../src/oracle/RobinhoodStockOracleAdapter.sol";
import {ChainlinkOracleAdapter} from "../../src/oracle/ChainlinkOracleAdapter.sol";
import {IPriceOracle} from "../../src/interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "../../src/interfaces/IMarketHoursOracle.sol";
import {MockMarketHours} from "../../src/mocks/MockMarketHours.sol";
import {Deploy} from "../../script/Deploy.s.sol";

/// @notice Pre-deployment fork validation: builds the entire WoolFi stack against real Robinhood
///         Chain contracts and reads real Chainlink feeds, all on an in-memory fork.
/// @dev Skips cleanly when ROBINHOOD_RPC_URL is not set (keeps CI green without secrets).
///
///      What it validates that the mocked integration tests cannot:
///      - HookMiner CREATE2 mining reaches an address whose permission bits are honored by the
///        real Uniswap v4 PoolManager on 4663.
///      - RobinhoodStockOracleAdapter's runtime guards (oraclePaused + Chainlink round validity)
///        succeed against live Robinhood Stock Tokens and their production Chainlink feeds.
///      - ChainlinkOracleAdapter reads the WETH (ETH/USD alias) and USDG proxies correctly.
///      - WoolFiGovernor.authorizePoolV2 + PoolManager.initialize round-trip against a real
///        deployed PoolManager, using real oracle prints as fair value.
///
///      What it does NOT validate:
///      - Swap/mint flows (Robinhood Stock Tokens are permissioned; `deal` cannot bypass
///        transfer allowlists at the token level). Integration tests already cover the swap and
///        LP-mint code paths with the same v4 PoolManager implementation.
///      - Multisig ownership handoff (that's a live-broadcast operation).
///
///      Chainlink feed addresses come from docs/oracles.md (authoritative: the JSON Chainlink
///      docs load their tables from). A large adapter heartbeat (7 days) is used because a fork
///      block near a weekend would otherwise reject perfectly valid weekend prints.
contract WoolFiPreDeployForkTest is Test {
    using PoolIdLibrary for PoolKey;

    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 private constant FORK_HEARTBEAT = 7 days;

    address private constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address private constant URU = 0x9fbe210007dDd8389f98d0253018e65CC48b9D24;

    // Canonical Robinhood Chain token addresses (see script/robinhood_catalog.py).
    address private constant TOK_MSTR = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address private constant TOK_COIN = 0x6330D8C3178a418788dF01a47479c0ce7CCF450b;
    address private constant TOK_CRCL = 0xdF0992E440dD0be65BD8439b609d6D4366bf1CB5;
    address private constant TOK_NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address private constant TOK_SPY = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address private constant TOK_WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address private constant TOK_USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address private constant TOK_QQQ = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address private constant TOK_PLTR = 0x894E1EC2D74FFE5AEF8Dc8A9e84686acCB964F2A;
    address private constant TOK_AAPL = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address private constant TOK_MSFT = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
    address private constant TOK_TSLA = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;

    // Live Chainlink proxies on 4663 (see docs/oracles.md inventory).
    address private constant FEED_MSTR = 0x396118bdFB181e6240E74D243F266B061c0edc3D;
    address private constant FEED_COIN = 0xA3a468A452940B7D6b69991207B508c609a98Ef2;
    address private constant FEED_CRCL = 0x6652eDf64bA3731C4F2D3ce821A0Fb1f1f6b482a;
    address private constant FEED_NVDA = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address private constant FEED_SPY = 0x319724394D3A0e3669269846abE664Cd621f9f6A;
    address private constant FEED_QQQ = 0x80901d846d5D7B030F26B480776EE3b29374C2ae;
    address private constant FEED_PLTR = 0x820ABedFF239034956B7A9d2F0a331f9F075eB4c;
    address private constant FEED_AAPL = 0x6B22A786bAa607d76728168703a39Ea9C99f2cD0;
    address private constant FEED_TSLA = 0x4A1166a659A55625345e9515b32adECea5547C38;
    address private constant FEED_MSFT = 0x45C3C877C15E6BA2EBB19eA114Ea508d14C1Af2E;
    address private constant FEED_WETH = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9; // ETH/USD alias
    address private constant FEED_USDG = 0x61B7e5650328764B076A108EFF5fa7282a1B9aD2;

    struct StockLeg {
        string symbol;
        address token;
        address feed;
        uint256 minWad;
        uint256 maxWad;
    }

    modifier onlyOnFork() {
        string memory rpc = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        require(block.chainid == ROBINHOOD_CHAIN_ID, "wrong chain forked");
        _;
    }

    /// @notice HookMiner uses the standard Arachnid CREATE2 factory at 0x4e59... Arbitrum Orbit
    ///         chains (RH Chain included) genesis-deploy it, so no etch is expected — but if a
    ///         particular fork block is missing it, fail loudly with a clear message.
    function _requireCreate2Factory() private view {
        address factory = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        require(factory.code.length > 0, "CREATE2 factory missing on fork; add vm.etch and retry");
    }

    function test_fork_deployWoolFiCore() public onlyOnFork {
        _requireCreate2Factory();
        Deploy script = new Deploy();
        address multisig = makeAddr("multisig");
        Deploy.Deployment memory dep =
            script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), multisig);

        assertEq(dep.stakingToken, URU, "staking token wired");
        assertGt(dep.hook.code.length, 0, "hook has code");
        assertGt(dep.positionManager.code.length, 0, "pm has code");
        assertGt(dep.governor.code.length, 0, "governor has code");
        assertEq(WoolFiHook(dep.hook).governor(), dep.governor, "hook governor set");
        assertEq(WoolFiHook(dep.hook).positionManager(), dep.positionManager, "hook pm set");
        assertEq(WoolFiGovernor(dep.governor).owner(), multisig, "governor owned by multisig");
        assertEq(WoolFiPositionManager(dep.positionManager).owner(), multisig, "pm owned by multisig");
    }

    function test_fork_allStockAdaptersReadRealFeeds() public onlyOnFork {
        StockLeg[10] memory legs = _stockLegs();
        for (uint256 i; i < legs.length; ++i) {
            StockLeg memory leg = legs[i];
            // Skip legs whose stock oracle is paused at the fork block (corporate action in flight).
            // The adapter reverts on pause; test intent is to verify happy-path oracle reads.
            (bool ok, bytes memory data) = leg.token.staticcall(abi.encodeWithSignature("oraclePaused()"));
            if (ok && data.length == 32 && abi.decode(data, (bool))) {
                emit log_named_string("skipping paused stock oracle", leg.symbol);
                continue;
            }
            RobinhoodStockOracleAdapter adapter =
                new RobinhoodStockOracleAdapter(leg.token, leg.feed, address(0), FORK_HEARTBEAT, 0);
            assertFalse(adapter.sequencerEnabled(), string.concat(leg.symbol, ": sequencer must be disabled"));
            uint256 price = adapter.getPrice();
            assertGt(price, leg.minWad, string.concat(leg.symbol, " price below sane floor"));
            assertLt(price, leg.maxWad, string.concat(leg.symbol, " price above sane ceiling"));
        }
    }

    function test_fork_wethUsdgAdaptersReadRealFeeds() public onlyOnFork {
        ChainlinkOracleAdapter wethAdapter = new ChainlinkOracleAdapter(FEED_WETH, FORK_HEARTBEAT);
        ChainlinkOracleAdapter usdgAdapter = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);

        uint256 wethPrice = wethAdapter.getPrice();
        // ETH/USD alias: wide band $500 - $50,000 covers any realistic block for the next decade.
        assertGt(wethPrice, 500e18, "WETH price below sane floor");
        assertLt(wethPrice, 50_000e18, "WETH price above sane ceiling");

        uint256 usdgPrice = usdgAdapter.getPrice();
        // USDG should always be near $1. Allow a wide 90-110c band for any depeg edge case.
        assertGt(usdgPrice, 0.9e18, "USDG price below sane floor");
        assertLt(usdgPrice, 1.1e18, "USDG price above sane ceiling");
    }

    function test_fork_authorizeMstrUsdgPool() public onlyOnFork {
        _requireCreate2Factory();

        // Bail out if the MSTR oracle is paused at the fork block; the initialize path calls the
        // adapter's runtime guards, which would revert. Skip is the correct outcome — the real
        // deploy path would also be gated by governance until pause clears.
        (bool ok, bytes memory data) = TOK_MSTR.staticcall(abi.encodeWithSignature("oraclePaused()"));
        if (ok && data.length == 32 && abi.decode(data, (bool))) {
            emit log_string("MSTR oraclePaused at fork block; skipping pool authorize");
            return;
        }

        Deploy script = new Deploy();
        address me = address(this);
        // Deploy script drives its own privileged wiring calls (setGovernor etc.), so the
        // deployer argument must be the script's own address. Multisig = me so this test can
        // drive governor authorize without vm.prank.
        Deploy.Deployment memory dep = script.deployWoolFi(IPoolManager(POOL_MANAGER), URU, address(script), me);
        WoolFiHook hook = WoolFiHook(dep.hook);
        WoolFiGovernor governor = WoolFiGovernor(dep.governor);
        WoolFiPositionManager pm = WoolFiPositionManager(dep.positionManager);

        RobinhoodStockOracleAdapter mstrAdapter =
            new RobinhoodStockOracleAdapter(TOK_MSTR, FEED_MSTR, address(0), FORK_HEARTBEAT, 0);
        ChainlinkOracleAdapter usdgAdapter = new ChainlinkOracleAdapter(FEED_USDG, FORK_HEARTBEAT);
        MockMarketHours marketHours = new MockMarketHours(true);

        // MSTR is 18 dec, USDG is 6 dec. USDG < MSTR in address ordering, so USDG is token0.
        assertLt(uint160(TOK_USDG), uint160(TOK_MSTR), "USDG must sort below MSTR");

        (address token0, address token1) = (TOK_USDG, TOK_MSTR);
        (IPriceOracle oracle0, IPriceOracle oracle1) = (usdgAdapter, mstrAdapter);

        // Vault: token0/token1 are pool assets for fee rewards; URU is the deposit asset.
        WoolFiUnderwritingVault vault =
            new WoolFiUnderwritingVault(URU, address(hook), token0, token1, makeAddr("rebalancer"), 1_000e18);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });

        governor.authorizePoolV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: oracle0,
                    oracle1: oracle1,
                    marketHours: IMarketHoursOracle(address(marketHours)),
                    kScaled: 40_000,
                    baseFeeBps: 30,
                    toleranceBps: 500,
                    hardThresholdBps: 1500
                }),
                safety: WoolFiHook.SafetyParams({stabilizationSeconds: 0, maxOracleSkew: 0})
            })
        );
        governor.setVault(key, address(vault), 2000);
        pm.setFeeConfig(key, address(vault), 2000, makeAddr("treasury"), 1000);

        // Authorization succeeded — the governor and hook accepted the real-feed adapters.
        assertTrue(hook.poolConfig(key.toId()).configured, "pool config recorded");
        assertEq(hook.poolConfig(key.toId()).vault, address(vault), "vault wired");

        // Cross-check: the hook can now read fair value against real oracles without reverting.
        uint256 usdgPrice = oracle0.getPrice();
        uint256 mstrPrice = oracle1.getPrice();
        assertGt(usdgPrice, 0.9e18);
        assertLt(usdgPrice, 1.1e18);
        assertGt(mstrPrice, 10e18);
        assertLt(mstrPrice, 10_000e18);
    }

    function _stockLegs() private pure returns (StockLeg[10] memory legs) {
        legs[0] = StockLeg("MSTR", TOK_MSTR, FEED_MSTR, 10e18, 10_000e18);
        legs[1] = StockLeg("COIN", TOK_COIN, FEED_COIN, 10e18, 10_000e18);
        legs[2] = StockLeg("CRCL", TOK_CRCL, FEED_CRCL, 1e18, 10_000e18);
        legs[3] = StockLeg("NVDA", TOK_NVDA, FEED_NVDA, 10e18, 10_000e18);
        legs[4] = StockLeg("SPY", TOK_SPY, FEED_SPY, 100e18, 10_000e18);
        legs[5] = StockLeg("QQQ", TOK_QQQ, FEED_QQQ, 100e18, 10_000e18);
        legs[6] = StockLeg("PLTR", TOK_PLTR, FEED_PLTR, 1e18, 10_000e18);
        legs[7] = StockLeg("AAPL", TOK_AAPL, FEED_AAPL, 10e18, 10_000e18);
        legs[8] = StockLeg("TSLA", TOK_TSLA, FEED_TSLA, 10e18, 10_000e18);
        legs[9] = StockLeg("MSFT", TOK_MSFT, FEED_MSFT, 10e18, 10_000e18);
    }
}
