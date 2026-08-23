// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";

import {NyseHoursOracle} from "../src/oracle/NyseHoursOracle.sol";
import {WoolFiGovernor} from "../src/WoolFiGovernor.sol";
import {WoolFiHook} from "../src/WoolFiHook.sol";
import {MockPriceOracle} from "../src/mocks/MockPriceOracle.sol";
import {MultisigMarketHours} from "../src/oracle/MultisigMarketHours.sol";

/// @notice Deploys the on-chain NYSE hours oracle and re-points the live pool at it via
///         `WoolFiGovernor.updatePoolConfig`. Strict superset of `DeployTestnet` — leaves all
///         other pool config untouched.
///
/// @dev Env:
///        DEPLOYER_PRIVATE_KEY   — must currently be the WoolFiGovernor owner
///        GOVERNOR_ADDRESS       — the deployed WoolFiGovernor
///        HOOK_ADDRESS           — the deployed WoolFiHook (for currentConfig reads)
///        TOKEN0                 — pool token0 (lower-sorted address)
///        TOKEN1                 — pool token1
///        ORACLE0                — current price oracle for token0
///        ORACLE1                — current price oracle for token1
///        NYSE_OWNER             — owner of the new NyseHoursOracle (multisig, defaults to deployer)
contract DeployNyseHoursAndSwap is Script {
    using PoolIdLibrary for PoolKey;

    struct Env {
        uint256 pk;
        address deployer;
        address governor;
        address hook;
        address token0;
        address token1;
        address oracle0;
        address oracle1;
        address nyseOwner;
    }

    function run() external returns (address nyse) {
        Env memory e = _loadEnv();

        console2.log("Chain id    ", block.chainid);
        console2.log("Deployer    ", e.deployer);
        console2.log("NYSE owner  ", e.nyseOwner);

        vm.startBroadcast(e.pk);
        nyse = address(new NyseHoursOracle(e.nyseOwner));
        console2.log("NyseHoursOracle", nyse);
        _repointPool(e, nyse);
        vm.stopBroadcast();

        console2.log("");
        console2.log("Pool re-pointed at NyseHoursOracle.");
        console2.log("Update frontend/lib/deployments/<chain>.json marketHours to:", nyse);
    }

    function _loadEnv() internal view returns (Env memory e) {
        e.pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        e.deployer = vm.addr(e.pk);
        e.governor = vm.envAddress("GOVERNOR_ADDRESS");
        e.hook = vm.envAddress("HOOK_ADDRESS");
        e.token0 = vm.envAddress("TOKEN0");
        e.token1 = vm.envAddress("TOKEN1");
        e.oracle0 = vm.envAddress("ORACLE0");
        e.oracle1 = vm.envAddress("ORACLE1");
        e.nyseOwner = _envOr("NYSE_OWNER", e.deployer);
    }

    function _repointPool(Env memory e, address nyse) internal {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(e.token0),
            currency1: Currency.wrap(e.token1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(e.hook)
        });
        WoolFiHook.WoolFiConfig memory cfg = WoolFiHook(e.hook).poolConfig(key.toId());

        WoolFiGovernor(e.governor)
            .updatePoolConfig(
                key,
                WoolFiHook.AuthParams({
                oracle0: MockPriceOracle(e.oracle0),
                oracle1: MockPriceOracle(e.oracle1),
                // type-cheat: NyseHoursOracle implements the same IMarketHoursOracle interface
                // that MultisigMarketHours does. The hook only calls isMarketOpen() on it.
                marketHours: MultisigMarketHours(nyse),
                kScaled: cfg.kScaled,
                baseFeeBps: cfg.baseFeeBps,
                toleranceBps: cfg.toleranceBps,
                hardThresholdBps: cfg.hardThresholdBps
            })
            );
    }

    function _envOr(string memory key, address fallback_) internal view returns (address) {
        try vm.envAddress(key) returns (address v) {
            return v;
        } catch {
            return fallback_;
        }
    }
}
