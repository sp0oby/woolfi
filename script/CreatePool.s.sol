// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {WoolFiHook} from "../src/WoolFiHook.sol";
import {WoolFiGovernor} from "../src/WoolFiGovernor.sol";
import {WoolFiPositionManager} from "../src/WoolFiPositionManager.sol";
import {WoolFiUnderwritingVault} from "../src/WoolFiUnderwritingVault.sol";
import {IPriceOracle} from "../src/interfaces/IPriceOracle.sol";
import {IMarketHoursOracle} from "../src/interfaces/IMarketHoursOracle.sol";
import {RobinhoodDeploymentArtifact} from "./lib/RobinhoodDeploymentArtifact.sol";

/// @notice Authorizes and initializes a WoolFi pool, deploys its underwriting vault, and wires the
///         hook drawdown + PM fee routing for it.
/// @dev The broadcaster MUST be the owner of {WoolFiGovernor} and {WoolFiPositionManager} (the v1
///      multisig). For testnet single-signer runs, set `MULTISIG=DEPLOYER_ADDRESS` so the same key
///      that ran `Deploy.s.sol` runs this.
///
///      Required env:
///        DEPLOYER_PRIVATE_KEY
///        POOL_MANAGER, HOOK, GOVERNOR, POSITION_MANAGER, STAKING_TOKEN
///        TOKEN0, TOKEN1                — sorted (currency0 address < currency1 address)
///        ORACLE0, ORACLE1              — IPriceOracle for each leg (1e18-normalized USD)
///        MARKET_HOURS                  — IMarketHoursOracle (use address(0) for crypto/crypto pairs)
///        REBALANCER, BUYBACK_SINK      — treasury / keeper addresses
///        SQRT_PRICE_X96                — initial pool price (Q64.96)
///      Optional env (defaults per PROJECT_SPEC.md §3, §7.3):
///        TICK_SPACING (60), K_SCALED (40000), BASE_FEE_BPS (30), TOLERANCE_BPS (500),
///        HARD_THRESHOLD_BPS (1500), DRAWDOWN_BPS (2000), VAULT_FEE_BPS (2000), BUYBACK_BPS (1000),
///        STABILIZATION_SECONDS (0), MAX_ORACLE_SKEW (0)
///      Robinhood broadcast env:
///        POOL_SLUG, TOKEN0_SYMBOL, TOKEN1_SYMBOL
contract CreatePool is RobinhoodDeploymentArtifact {
    using PoolIdLibrary for PoolKey;

    struct PoolConfig {
        address token0;
        address token1;
        IPriceOracle oracle0;
        IPriceOracle oracle1;
        IMarketHoursOracle marketHours;
        address rebalancer;
        address buybackSink;
        uint160 sqrtPriceX96;
        int24 tickSpacing;
        uint32 kScaled;
        uint16 baseFeeBps;
        uint16 toleranceBps;
        uint16 hardThresholdBps;
        uint16 drawdownBps;
        uint16 vaultFeeBps;
        uint16 buybackBps;
        uint32 stabilizationSeconds;
        uint32 maxOracleSkew;
    }

    function run() external returns (PoolKey memory key, address vault) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        WoolFiHook hook = WoolFiHook(vm.envAddress("HOOK"));
        WoolFiGovernor governor = WoolFiGovernor(vm.envAddress("GOVERNOR"));
        WoolFiPositionManager pm = WoolFiPositionManager(vm.envAddress("POSITION_MANAGER"));
        address stakingToken = vm.envAddress("STAKING_TOKEN");

        PoolConfig memory c = _loadConfig();
        require(c.token0 < c.token1, "CreatePool: token0 must sort below token1");
        _requireContract(address(poolManager), "POOL_MANAGER");
        _requireContract(address(hook), "HOOK");
        _requireContract(address(governor), "GOVERNOR");
        _requireContract(address(pm), "POSITION_MANAGER");
        _requireContract(stakingToken, "STAKING_TOKEN");
        _requireContract(c.token0, "TOKEN0");
        _requireContract(c.token1, "TOKEN1");
        _requireContract(address(c.oracle0), "ORACLE0");
        _requireContract(address(c.oracle1), "ORACLE1");
        require(c.rebalancer != address(0), "CreatePool: REBALANCER is zero");
        require(c.buybackSink != address(0), "CreatePool: BUYBACK_SINK is zero");

        vm.startBroadcast(pk);

        // 1. per-pool underwriting vault (token0/1 = the pool's tokens for fee rewards)
        vault = address(new WoolFiUnderwritingVault(stakingToken, address(hook), c.token0, c.token1, c.rebalancer));

        // 2. build the pool key (dynamic fee, with the hook)
        key = PoolKey({
            currency0: Currency.wrap(c.token0),
            currency1: Currency.wrap(c.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: c.tickSpacing,
            hooks: IHooks(address(hook))
        });

        // 3. governance authorizes the pool BEFORE initialize (beforeInitialize requires config)
        governor.authorizePoolV2(
            key,
            WoolFiHook.AuthParamsV2({
                core: WoolFiHook.AuthParams({
                    oracle0: c.oracle0,
                    oracle1: c.oracle1,
                    marketHours: c.marketHours,
                    kScaled: c.kScaled,
                    baseFeeBps: c.baseFeeBps,
                    toleranceBps: c.toleranceBps,
                    hardThresholdBps: c.hardThresholdBps
                }),
                safety: WoolFiHook.SafetyParams({
                    stabilizationSeconds: c.stabilizationSeconds, maxOracleSkew: c.maxOracleSkew
                })
            })
        );

        // 4. initialize the pool in the PoolManager
        poolManager.initialize(key, c.sqrtPriceX96);

        // 5. wire the vault into the hook (drawdown on structural break) and into the PM (fee routing)
        governor.setVault(key, vault, c.drawdownBps);
        pm.setFeeConfig(key, vault, c.vaultFeeBps, c.buybackSink, c.buybackBps);

        vm.stopBroadcast();

        console2.log("Vault         ", vault);
        console2.log("Pool currency0", c.token0);
        console2.log("Pool currency1", c.token1);

        if (_isBroadcastContext()) {
            _persistAfterBroadcast(
                PoolArtifact({
                    poolId: PoolId.unwrap(key.toId()),
                    slug: vm.envString("POOL_SLUG"),
                    token0: c.token0,
                    token1: c.token1,
                    token0Symbol: vm.envString("TOKEN0_SYMBOL"),
                    token1Symbol: vm.envString("TOKEN1_SYMBOL"),
                    oracle0: address(c.oracle0),
                    oracle1: address(c.oracle1),
                    marketHours: address(c.marketHours),
                    vault: vault,
                    tickSpacing: c.tickSpacing,
                    baseFeeBps: c.baseFeeBps,
                    toleranceBps: c.toleranceBps,
                    hardThresholdBps: c.hardThresholdBps,
                    drawdownBps: c.drawdownBps,
                    vaultFeeBps: c.vaultFeeBps,
                    buybackBps: c.buybackBps
                })
            );
        }
    }

    function _loadConfig() internal view returns (PoolConfig memory c) {
        c.token0 = vm.envAddress("TOKEN0");
        c.token1 = vm.envAddress("TOKEN1");
        c.oracle0 = IPriceOracle(vm.envAddress("ORACLE0"));
        c.oracle1 = IPriceOracle(vm.envAddress("ORACLE1"));
        c.marketHours = IMarketHoursOracle(vm.envOr("MARKET_HOURS", address(0)));
        c.rebalancer = vm.envAddress("REBALANCER");
        c.buybackSink = vm.envAddress("BUYBACK_SINK");
        c.sqrtPriceX96 = uint160(vm.envUint("SQRT_PRICE_X96"));
        c.tickSpacing = int24(int256(vm.envOr("TICK_SPACING", uint256(60))));
        c.kScaled = uint32(vm.envOr("K_SCALED", uint256(40_000)));
        c.baseFeeBps = uint16(vm.envOr("BASE_FEE_BPS", uint256(30)));
        c.toleranceBps = uint16(vm.envOr("TOLERANCE_BPS", uint256(500)));
        c.hardThresholdBps = uint16(vm.envOr("HARD_THRESHOLD_BPS", uint256(1500)));
        c.drawdownBps = uint16(vm.envOr("DRAWDOWN_BPS", uint256(2000)));
        c.vaultFeeBps = uint16(vm.envOr("VAULT_FEE_BPS", uint256(2000)));
        c.buybackBps = uint16(vm.envOr("BUYBACK_BPS", uint256(1000)));
        c.stabilizationSeconds = uint32(vm.envOr("STABILIZATION_SECONDS", uint256(0)));
        c.maxOracleSkew = uint32(vm.envOr("MAX_ORACLE_SKEW", uint256(0)));
    }

    function _requireContract(address target, string memory label) private view {
        require(target.code.length > 0, string.concat("CreatePool: ", label, " has no code"));
    }
}
