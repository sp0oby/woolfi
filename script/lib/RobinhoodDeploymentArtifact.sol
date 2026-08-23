// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {RobinhoodBroadcastGuard} from "./RobinhoodBroadcastGuard.sol";

/// @dev Post-broadcast persistence for production Robinhood pool creation.
abstract contract RobinhoodDeploymentArtifact is RobinhoodBroadcastGuard {
    address private constant ZERO = address(0);
    string internal constant ROBINHOOD_MANIFEST = "frontend/lib/deployments/robinhood.json";

    struct PoolArtifact {
        bytes32 poolId;
        string slug;
        address token0;
        address token1;
        string token0Symbol;
        string token1Symbol;
        address oracle0;
        address oracle1;
        address marketHours;
        address vault;
        int24 tickSpacing;
        uint16 baseFeeBps;
        uint16 toleranceBps;
        uint16 hardThresholdBps;
        uint16 drawdownBps;
        uint16 vaultFeeBps;
        uint16 buybackBps;
    }

    function _persistAfterBroadcast(PoolArtifact memory pool) internal {
        if (!_isBroadcastContext()) return;

        require(block.chainid == 4663, "Artifact: Robinhood mainnet only");
        _validatePool(pool);

        string memory json = vm.readFile(ROBINHOOD_MANIFEST);
        require(vm.parseJsonUint(json, ".chainId") == 4663, "Artifact: wrong chainId");

        _writeCoreAddress(json, ".poolManager", vm.envAddress("POOL_MANAGER"));
        _writeCoreAddress(json, ".hook", vm.envAddress("HOOK"));
        _writeCoreAddress(json, ".positionManager", vm.envAddress("POSITION_MANAGER"));
        _writeCoreAddress(json, ".governor", vm.envAddress("GOVERNOR"));
        _writeCoreAddress(json, ".stakingToken", vm.envAddress("STAKING_TOKEN"));

        _upsertPoolAtPath(ROBINHOOD_MANIFEST, pool);
    }

    function _upsertPoolAtPath(string memory path, PoolArtifact memory pool) internal {
        _validatePool(pool);
        string memory json = vm.readFile(path);
        uint256 count = vm.parseJsonUint(json, ".poolCount");
        uint256 target = count;

        for (uint256 i; i < count; ++i) {
            if (_readPool(json, i).poolId == pool.poolId) {
                target = i;
                break;
            }
        }

        string memory poolsJson = "[";
        uint256 nextCount = target == count ? count + 1 : count;
        for (uint256 i; i < nextCount; ++i) {
            PoolArtifact memory item = i == target ? pool : _readPool(json, i);
            poolsJson = string.concat(poolsJson, i == 0 ? "" : ",", _serializePool(item));
        }
        poolsJson = string.concat(poolsJson, "]");
        vm.writeJson(poolsJson, path, ".pools");
        if (target == count) vm.writeJson(vm.toString(count + 1), path, ".poolCount");
    }

    function _readPool(string memory json, uint256 index) private pure returns (PoolArtifact memory pool) {
        string memory root = string.concat(".pools[", vm.toString(index), "].");
        pool.poolId = vm.parseJsonBytes32(json, string.concat(root, "poolId"));
        pool.slug = vm.parseJsonString(json, string.concat(root, "slug"));
        pool.token0 = vm.parseJsonAddress(json, string.concat(root, "token0"));
        pool.token1 = vm.parseJsonAddress(json, string.concat(root, "token1"));
        pool.token0Symbol = vm.parseJsonString(json, string.concat(root, "token0Symbol"));
        pool.token1Symbol = vm.parseJsonString(json, string.concat(root, "token1Symbol"));
        pool.oracle0 = vm.parseJsonAddress(json, string.concat(root, "oracle0"));
        pool.oracle1 = vm.parseJsonAddress(json, string.concat(root, "oracle1"));
        pool.marketHours = vm.parseJsonAddress(json, string.concat(root, "marketHours"));
        pool.vault = vm.parseJsonAddress(json, string.concat(root, "vault"));
        pool.tickSpacing = int24(vm.parseJsonInt(json, string.concat(root, "tickSpacing")));
        pool.baseFeeBps = uint16(vm.parseJsonUint(json, string.concat(root, "baseFeeBps")));
        pool.toleranceBps = uint16(vm.parseJsonUint(json, string.concat(root, "toleranceBps")));
        pool.hardThresholdBps = uint16(vm.parseJsonUint(json, string.concat(root, "hardThresholdBps")));
        pool.drawdownBps = uint16(vm.parseJsonUint(json, string.concat(root, "drawdownBps")));
        pool.vaultFeeBps = uint16(vm.parseJsonUint(json, string.concat(root, "vaultFeeBps")));
        pool.buybackBps = uint16(vm.parseJsonUint(json, string.concat(root, "buybackBps")));
    }

    function _serializePool(PoolArtifact memory pool) internal returns (string memory json) {
        string memory object = "robinhoodPool";
        vm.serializeBytes32(object, "poolId", pool.poolId);
        vm.serializeString(object, "slug", pool.slug);
        vm.serializeAddress(object, "token0", pool.token0);
        vm.serializeAddress(object, "token1", pool.token1);
        vm.serializeString(object, "token0Symbol", pool.token0Symbol);
        vm.serializeString(object, "token1Symbol", pool.token1Symbol);
        vm.serializeAddress(object, "oracle0", pool.oracle0);
        vm.serializeAddress(object, "oracle1", pool.oracle1);
        vm.serializeAddress(object, "marketHours", pool.marketHours);
        vm.serializeAddress(object, "vault", pool.vault);
        vm.serializeInt(object, "tickSpacing", pool.tickSpacing);
        vm.serializeUint(object, "baseFeeBps", pool.baseFeeBps);
        vm.serializeUint(object, "toleranceBps", pool.toleranceBps);
        vm.serializeUint(object, "hardThresholdBps", pool.hardThresholdBps);
        vm.serializeUint(object, "drawdownBps", pool.drawdownBps);
        vm.serializeUint(object, "vaultFeeBps", pool.vaultFeeBps);
        json = vm.serializeUint(object, "buybackBps", pool.buybackBps);
    }

    function _writeCoreAddress(string memory json, string memory key, address expected) private {
        require(expected != ZERO, "Artifact: zero core address");
        address current = vm.parseJsonAddress(json, key);
        require(current == ZERO || current == expected, string.concat("Artifact: manifest mismatch at ", key));
        vm.writeJson(string.concat('"', vm.toString(expected), '"'), ROBINHOOD_MANIFEST, key);
    }

    function _validatePool(PoolArtifact memory pool) private pure {
        require(pool.poolId != bytes32(0), "Artifact: zero poolId");
        require(bytes(pool.slug).length != 0, "Artifact: empty slug");
        require(bytes(pool.token0Symbol).length != 0, "Artifact: empty token0 symbol");
        require(bytes(pool.token1Symbol).length != 0, "Artifact: empty token1 symbol");
        require(pool.token0 != ZERO && pool.token1 != ZERO, "Artifact: zero token");
        require(pool.oracle0 != ZERO && pool.oracle1 != ZERO, "Artifact: zero oracle");
        require(pool.vault != ZERO, "Artifact: zero vault");
    }
}
