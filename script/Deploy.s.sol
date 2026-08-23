// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

import {WoolFiHook} from "../src/WoolFiHook.sol";
import {WoolFiPositionManager} from "../src/WoolFiPositionManager.sol";
import {WoolFiGovernor} from "../src/WoolFiGovernor.sol";

import {HookMiner} from "./lib/HookMiner.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys the WoolFi core against an existing staking token: WoolFiHook (CREATE2-mined to encode permissions),
///         WoolFiPositionManager, WoolFiGovernor — and hands the hook's governor role to the governor.
/// @dev Env required:
///        POOL_MANAGER             — v4 PoolManager on the target chain
///        STAKING_TOKEN            — existing standard ERC-20 used by underwriting vaults (URU on Robinhood)
///        DEPLOYER_PRIVATE_KEY     — the broadcaster
///        MULTISIG (optional)      — owner of PM and WoolFiGovernor; defaults to deployer
///      Per-pool wiring (vault, fee config, oracles) is `CreatePool.s.sol`.
contract Deploy is RobinhoodBroadcastGuard {
    struct Deployment {
        address stakingToken;
        address hook;
        address positionManager;
        address governor;
    }

    function run() external returns (Deployment memory dep) {
        _requireRobinhoodBroadcastApproval();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address multisig = vm.envOr("MULTISIG", deployer);
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address stakingToken = vm.envAddress("STAKING_TOKEN");
        require(address(poolManager).code.length > 0, "Deploy: POOL_MANAGER has no code");
        require(stakingToken.code.length > 0, "Deploy: STAKING_TOKEN has no code");

        vm.startBroadcast(pk);
        dep = deployWoolFi(poolManager, stakingToken, deployer, multisig);
        vm.stopBroadcast();

        console2.log("Staking token       ", dep.stakingToken);
        console2.log("WoolFiHook           ", dep.hook);
        console2.log("WoolFiPositionManager", dep.positionManager);
        console2.log("WoolFiGovernor       ", dep.governor);
    }

    /// @dev Deploy logic, separated so a test (or another script) can drive it without broadcast.
    function deployWoolFi(IPoolManager poolManager, address stakingToken, address deployer, address multisig)
        public
        returns (Deployment memory dep)
    {
        require(address(poolManager).code.length > 0, "Deploy: POOL_MANAGER has no code");
        require(stakingToken.code.length > 0, "Deploy: STAKING_TOKEN has no code");
        require(deployer != address(0), "Deploy: deployer is zero");
        require(multisig != address(0), "Deploy: multisig is zero");

        // 1. Mine a CREATE2 salt producing an address with the right permission bits, then deploy
        uint160 flags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG
                | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );
        bytes memory hookInit = abi.encodePacked(type(WoolFiHook).creationCode, abi.encode(poolManager, deployer));
        (address minedHook, bytes32 salt) = HookMiner.find(flags, hookInit);
        address deployed = HookMiner.deploy(salt, hookInit);
        if (deployed != minedHook) revert HookMiner.AddressMismatch(minedHook, deployed);
        WoolFiHook hook = WoolFiHook(deployed);

        // 2. PM owned by multisig; per-pool fee routing configured later via setFeeConfig
        WoolFiPositionManager pm = new WoolFiPositionManager(poolManager, multisig);

        // 3. Governor temporarily belongs to the deployer so all privileged wiring goes through
        //    the production governance surface before ownership is handed to the multisig.
        WoolFiGovernor governor = new WoolFiGovernor(address(hook), deployer);
        hook.setGovernor(address(governor));
        governor.setHookPositionManager(address(pm));
        governor.transferOwnership(multisig);

        dep = Deployment({
            stakingToken: stakingToken, hook: address(hook), positionManager: address(pm), governor: address(governor)
        });
    }
}
