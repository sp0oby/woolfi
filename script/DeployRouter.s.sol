// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {WoolFiHook} from "../src/WoolFiHook.sol";
import {WoolFiSwapRouter} from "../src/WoolFiSwapRouter.sol";
import {UrufuFeeRebateDistributor} from "../src/UrufuFeeRebateDistributor.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @notice Deploys the swap router and its Urufu Gemu NFT-holder rebate distributor.
/// @dev Idempotent: reuses and verifies a complete existing pair, or deploys both together.
///      Requires POOL_MANAGER, URUFU_NFT, DEPLOYER_PRIVATE_KEY, and either a receipt-backed
///      manifest hook or HOOK for a dry run. MULTISIG defaults to the deployer.
contract DeployRouter is RobinhoodBroadcastGuard {
    string internal constant MANIFEST = "frontend/lib/deployments/robinhood.json";
    address internal constant URUFU_NFT = 0x60cB7082c8C14B4237C6a24c65E7C2E7abe2Bd17;

    function run() external returns (address router) {
        require(block.chainid == ROBINHOOD_CHAIN_ID, "DeployRouter: Robinhood chain only");
        _requireRobinhoodBroadcastApproval();

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address multisig = vm.envOr("MULTISIG", deployer);
        IPoolManager poolManager = IPoolManager(vm.envAddress("POOL_MANAGER"));
        address urufuNft = vm.envOr("URUFU_NFT", URUFU_NFT);
        require(address(poolManager).code.length > 0, "DeployRouter: POOL_MANAGER has no code");
        require(urufuNft.code.length > 0, "DeployRouter: URUFU_NFT has no code");

        (WoolFiHook hook, address existing, address existingDistributor) = _manifestState(poolManager, urufuNft);
        if (existing != address(0)) {
            _validateExisting(existing, existingDistributor, poolManager, hook, urufuNft);
            console2.log("Reusing swapRouter", existing);
            return existing;
        }
        require(existingDistributor == address(0), "DeployRouter: orphan distributor in manifest");

        console2.log("Chain id   ", block.chainid);
        console2.log("Deployer   ", deployer);
        console2.log("PoolManager", address(poolManager));
        console2.log("Urufu NFT  ", urufuNft);

        address distributor;
        (router, distributor) = _deployPair(pk, deployer, multisig, poolManager, hook, urufuNft);

        console2.log("swapRouter ", router);
        console2.log("rebates    ", distributor);

        if (_isBroadcastContext()) {
            // writeJson expects a JSON string literal for an address, including quotes.
            vm.writeJson(string.concat('"', vm.toString(router), '"'), MANIFEST, ".swapRouter");
            vm.writeJson(string.concat('"', vm.toString(distributor), '"'), MANIFEST, ".rebateDistributor");
            vm.writeJson(string.concat('"', vm.toString(urufuNft), '"'), MANIFEST, ".urufuNft");
            console2.log("Patched JSON at", MANIFEST);
        }
    }

    function _manifestState(IPoolManager poolManager, address urufuNft)
        private
        view
        returns (WoolFiHook hook, address existing, address existingDistributor)
    {
        string memory json = vm.readFile(MANIFEST);
        require(vm.parseJsonUint(json, ".chainId") == ROBINHOOD_CHAIN_ID, "DeployRouter: wrong manifest chain");
        address manifestManager = vm.parseJsonAddress(json, ".poolManager");
        require(
            manifestManager == address(0) || manifestManager == address(poolManager),
            "DeployRouter: PoolManager manifest mismatch"
        );
        address manifestHook = vm.parseJsonAddress(json, ".hook");
        hook = WoolFiHook(manifestHook == address(0) ? vm.envAddress("HOOK") : manifestHook);
        require(address(hook).code.length > 0, "DeployRouter: manifest hook has no code");
        address manifestNft = vm.parseJsonAddress(json, ".urufuNft");
        require(manifestNft == address(0) || manifestNft == urufuNft, "DeployRouter: NFT manifest mismatch");
        existing = vm.parseJsonAddress(json, ".swapRouter");
        existingDistributor = vm.parseJsonAddress(json, ".rebateDistributor");
    }

    function _validateExisting(
        address existing,
        address existingDistributor,
        IPoolManager poolManager,
        WoolFiHook hook,
        address urufuNft
    ) private view {
        require(existing.code.length > 0, "DeployRouter: manifest router has no code");
        require(existingDistributor.code.length > 0, "DeployRouter: distributor missing");
        WoolFiSwapRouter currentRouter = WoolFiSwapRouter(existing);
        require(address(currentRouter.poolManager()) == address(poolManager), "DeployRouter: router manager mismatch");
        require(
            address(currentRouter.rebateDistributor()) == existingDistributor,
            "DeployRouter: router distributor mismatch"
        );
        UrufuFeeRebateDistributor distributor = UrufuFeeRebateDistributor(existingDistributor);
        require(address(distributor.hook()) == address(hook), "DeployRouter: distributor hook mismatch");
        require(address(distributor.urufuNft()) == urufuNft, "DeployRouter: distributor NFT mismatch");
        require(distributor.router() == existing, "DeployRouter: distributor router mismatch");
    }

    function _deployPair(
        uint256 pk,
        address deployer,
        address multisig,
        IPoolManager poolManager,
        WoolFiHook hook,
        address urufuNft
    ) private returns (address router, address distributor) {
        vm.startBroadcast(pk);
        UrufuFeeRebateDistributor d = new UrufuFeeRebateDistributor(hook, urufuNft, deployer);
        WoolFiSwapRouter r = new WoolFiSwapRouter(poolManager, d);
        d.setRouter(address(r));
        d.transferOwnership(multisig);
        vm.stopBroadcast();
        return (address(r), address(d));
    }
}
