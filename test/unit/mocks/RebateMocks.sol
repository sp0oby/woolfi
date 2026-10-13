// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolId} from "v4-core/src/types/PoolId.sol";

import {WoolFiHook} from "../../../src/WoolFiHook.sol";

/// @notice Stands in for {WoolFiHook} in distributor tests: the distributor only reads
///         `poolConfig`, `lastSwapFeeBps` and `positionManager`, so all are settable here.
contract MockRebateHook {
    mapping(PoolId => WoolFiHook.WoolFiConfig) internal _config;
    mapping(PoolId => uint256) public feeBps;
    address public positionManager;

    function setPositionManager(address pm) external {
        positionManager = pm;
    }

    function setPool(PoolId id, bool configured, uint16 baseFeeBps) external {
        _config[id].configured = configured;
        _config[id].baseFeeBps = baseFeeBps;
    }

    function setFee(PoolId id, uint256 bps) external {
        feeBps[id] = bps;
    }

    function poolConfig(PoolId id) external view returns (WoolFiHook.WoolFiConfig memory) {
        return _config[id];
    }

    function lastSwapFeeBps(PoolId id) external view returns (uint256) {
        return feeBps[id];
    }
}

/// @notice Minimal ERC-721 balance source with settable balances.
contract MockNftBalance {
    mapping(address => uint256) public balanceOf;

    function set(address who, uint256 bal) external {
        balanceOf[who] = bal;
    }
}

/// @notice Stands in for {WoolFiPositionManager}'s `feeConfig` getter in distributor tests.
contract MockFeeConfigPm {
    struct FeeConfig {
        address vault;
        uint16 vaultBps;
        address treasurySink;
        uint16 treasuryBps;
    }

    mapping(uint256 => FeeConfig) public feeConfig;

    function setTreasury(PoolId id, address sink, uint16 bps) external {
        feeConfig[uint256(PoolId.unwrap(id))].treasurySink = sink;
        feeConfig[uint256(PoolId.unwrap(id))].treasuryBps = bps;
    }
}
