// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {console2} from "forge-std/Script.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

import {WoolFiGovernor} from "../src/WoolFiGovernor.sol";
import {UNSTAKE_COOLDOWN} from "../src/WoolFiUnderwritingVault.sol";
import {RobinhoodBroadcastGuard} from "./lib/RobinhoodBroadcastGuard.sol";

/// @dev The two-step ownership surface shared by WoolFiGovernor, UrufuFeeRebateDistributor
///      (OpenZeppelin Ownable2Step) and WoolFiPositionManager, WoolFiLiquidityZapper (hand-rolled,
///      same selectors).
interface ITwoStepOwnable {
    function owner() external view returns (address);
    function pendingOwner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function acceptOwnership() external;
}

interface IRebalancerView {
    function rebalancer() external view returns (address);
}

/// @notice Writes the two Safe Transaction Builder batches that move WoolFi's privileged contracts
///         behind the TimelockController (KNOWN-ISSUES M-3). It never broadcasts: the Safe signs both
///         batches in its own UI.
/// @dev Run read-only against the live chain:
///        MULTISIG=<safe> forge script script/TimelockHandoff.s.sol --rpc-url $ROBINHOOD_RPC_URL
///      Output: script/out/timelock-handoff-1-schedule.json and script/out/timelock-handoff-2-execute.json.
///      Batch 1 (now): accept any ownership still pending to the Safe, set the Safe as the governor's
///      pause guardian, `transferOwnership(timelock)` on each owned contract, and schedule the matching
///      `acceptOwnership()` calls on the timelock. Batch 2 (after the delay): execute that schedule.
///      Market-hours oracles stay with the Safe: they hold no funds and need same-day holiday or
///      session fixes, which a 3-day delay would make impossible.
///      Optional env: HANDOFF_SALT (bytes32) to reschedule after a cancel.
contract TimelockHandoff is RobinhoodBroadcastGuard {
    string internal constant MANIFEST = "frontend/lib/deployments/robinhood.json";
    string internal constant OUT_SCHEDULE = "script/out/timelock-handoff-1-schedule.json";
    string internal constant OUT_EXECUTE = "script/out/timelock-handoff-2-execute.json";
    bytes32 internal constant DEFAULT_SALT = keccak256("woolfi.timelock.handoff.v1");
    uint256 internal constant MIN_PRODUCTION_DELAY = 3 days;

    struct Addresses {
        address timelock;
        address governor;
        address positionManager;
        address rebateDistributor;
        address liquidityZapper;
        address[] vaults;
    }

    struct Call {
        address to;
        bytes data;
    }

    /// @notice The scheduled operation: identical arguments are passed to scheduleBatch and executeBatch.
    struct Operation {
        address[] targets;
        uint256[] values;
        bytes[] payloads;
        bytes32 salt;
        uint256 delay;
    }

    function run() external {
        require(!_isBroadcastContext(), "TimelockHandoff: read-only; the Safe signs the batches");
        address safe = vm.envAddress("MULTISIG");
        bytes32 salt = vm.envOr("HANDOFF_SALT", DEFAULT_SALT);
        Addresses memory a = _manifestAddresses();

        (Call[] memory schedule, Call[] memory execute, Operation memory op) = buildHandoff(a, safe, salt);
        vm.createDir("script/out", true);
        vm.writeFile(OUT_SCHEDULE, _builderJson(safe, "WoolFi timelock handoff 1/2: schedule", schedule));
        vm.writeFile(OUT_EXECUTE, _builderJson(safe, "WoolFi timelock handoff 2/2: execute", execute));

        bytes32 id = TimelockController(payable(a.timelock))
            .hashOperationBatch(op.targets, op.values, op.payloads, bytes32(0), op.salt);
        console2.log("Safe            ", safe);
        console2.log("Timelock        ", a.timelock);
        console2.log("Contracts moved ", op.targets.length);
        console2.log("Delay (seconds) ", op.delay);
        console2.log("Operation id");
        console2.logBytes32(id);
        console2.log("Wrote", OUT_SCHEDULE);
        console2.log("Wrote", OUT_EXECUTE);
    }

    /// @notice Validate the live setup and build both batches. Reverts on anything that would make
    ///         the handoff unsafe or impossible.
    function buildHandoff(Addresses memory a, address safe, bytes32 salt)
        public
        view
        returns (Call[] memory schedule, Call[] memory execute, Operation memory op)
    {
        require(safe != address(0), "TimelockHandoff: MULTISIG is zero");
        require(a.timelock.code.length > 0, "TimelockHandoff: timelock has no code");
        TimelockController timelock = TimelockController(payable(a.timelock));
        _checkTimelockRoles(timelock, safe);
        _checkRebalancers(a.vaults, safe, a.timelock);

        op = _operation(a, salt, timelock.getMinDelay());
        schedule = _scheduleCalls(a, safe, op);
        execute = new Call[](1);
        execute[0] = Call(
            a.timelock,
            abi.encodeCall(TimelockController.executeBatch, (op.targets, op.values, op.payloads, bytes32(0), salt))
        );
    }

    /// @dev The timelock operation: `acceptOwnership()` on every owned contract the manifest lists.
    function _operation(Addresses memory a, bytes32 salt, uint256 delay) internal pure returns (Operation memory op) {
        address[4] memory owned = [a.governor, a.positionManager, a.rebateDistributor, a.liquidityZapper];
        uint256 count;
        for (uint256 i; i < owned.length; ++i) {
            if (owned[i] != address(0)) ++count;
        }
        require(count > 0, "TimelockHandoff: nothing to hand off");
        op.targets = new address[](count);
        op.values = new uint256[](count);
        op.payloads = new bytes[](count);
        op.salt = salt;
        op.delay = delay;
        uint256 t;
        for (uint256 i; i < owned.length; ++i) {
            if (owned[i] == address(0)) continue;
            op.targets[t] = owned[i];
            op.payloads[t] = abi.encodeCall(ITwoStepOwnable.acceptOwnership, ());
            ++t;
        }
    }

    /// @dev Batch 1: per contract, accept a handoff still pending to the Safe, set the guardian on the
    ///      governor, and transfer ownership to the timelock; then schedule the operation.
    function _scheduleCalls(Addresses memory a, address safe, Operation memory op)
        internal
        view
        returns (Call[] memory schedule)
    {
        Call[] memory buf = new Call[](op.targets.length * 2 + 2);
        uint256 n;
        for (uint256 i; i < op.targets.length; ++i) {
            n = _appendOwnershipCalls(buf, n, op.targets[i], a, safe);
        }
        buf[n++] = Call(
            a.timelock,
            abi.encodeCall(
                TimelockController.scheduleBatch, (op.targets, op.values, op.payloads, bytes32(0), op.salt, op.delay)
            )
        );
        schedule = new Call[](n);
        for (uint256 i; i < n; ++i) {
            schedule[i] = buf[i];
        }
    }

    function _appendOwnershipCalls(Call[] memory buf, uint256 n, address target, Addresses memory a, address safe)
        internal
        view
        returns (uint256)
    {
        require(target.code.length > 0, "TimelockHandoff: owned contract has no code");
        ITwoStepOwnable c = ITwoStepOwnable(target);
        if (c.owner() != safe) {
            // Deploy.s.sol stages the governor handoff; the Safe completes it here.
            require(c.pendingOwner() == safe, "TimelockHandoff: contract not owned by the Safe");
            buf[n++] = Call(target, abi.encodeCall(ITwoStepOwnable.acceptOwnership, ()));
        }
        if (target == a.governor && WoolFiGovernor(target).guardian() != safe) {
            buf[n++] = Call(target, abi.encodeCall(WoolFiGovernor.setGuardian, (safe)));
        }
        buf[n++] = Call(target, abi.encodeCall(ITwoStepOwnable.transferOwnership, (a.timelock)));
        return n;
    }

    function _checkTimelockRoles(TimelockController timelock, address safe) internal view {
        require(timelock.hasRole(timelock.PROPOSER_ROLE(), safe), "TimelockHandoff: Safe is not proposer");
        require(timelock.hasRole(timelock.EXECUTOR_ROLE(), safe), "TimelockHandoff: Safe is not executor");
        require(timelock.hasRole(timelock.CANCELLER_ROLE(), safe), "TimelockHandoff: Safe is not canceller");
        // admin=address(0) at deploy leaves the timelock as its own only admin.
        require(!timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), safe), "TimelockHandoff: Safe holds timelock admin");
        require(
            timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)),
            "TimelockHandoff: timelock is not self-administered"
        );
        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            require(timelock.getMinDelay() >= MIN_PRODUCTION_DELAY, "TimelockHandoff: delay below 3 days");
            require(timelock.getMinDelay() > UNSTAKE_COOLDOWN, "TimelockHandoff: delay not above unstake cooldown");
        }
    }

    /// @dev KNOWN-ISSUES M-3: seized URU goes to each vault's immutable rebalancer, which must be
    ///      neither the Safe nor the timelock the Safe controls.
    function _checkRebalancers(address[] memory vaults, address safe, address timelock) internal view {
        for (uint256 i; i < vaults.length; ++i) {
            if (vaults[i] == address(0)) continue;
            address rebalancer = IRebalancerView(vaults[i]).rebalancer();
            require(rebalancer != safe, "TimelockHandoff: vault rebalancer is the Safe (M-3)");
            require(rebalancer != timelock, "TimelockHandoff: vault rebalancer is the timelock (M-3)");
        }
    }

    function _manifestAddresses() internal view returns (Addresses memory a) {
        string memory json = vm.readFile(MANIFEST);
        a.timelock = vm.parseJsonAddress(json, ".timelock");
        a.governor = vm.parseJsonAddress(json, ".governor");
        a.positionManager = vm.parseJsonAddress(json, ".positionManager");
        a.rebateDistributor = vm.parseJsonAddress(json, ".rebateDistributor");
        a.liquidityZapper = vm.parseJsonAddress(json, ".liquidityZapper");
        uint256 pools = vm.parseJsonUint(json, ".poolCount");
        a.vaults = new address[](pools);
        for (uint256 i; i < pools; ++i) {
            a.vaults[i] = vm.parseJsonAddress(json, string.concat(".pools[", vm.toString(i), "].vault"));
        }
    }

    /// @dev Safe Transaction Builder import format.
    function _builderJson(address safe, string memory name, Call[] memory calls) internal view returns (string memory) {
        string memory txs;
        for (uint256 i; i < calls.length; ++i) {
            txs = string.concat(
                txs,
                i == 0 ? "" : ",",
                '{"to":"',
                vm.toString(calls[i].to),
                '","value":"0","data":"',
                vm.toString(calls[i].data),
                '","contractMethod":null,"contractInputsValues":null}'
            );
        }
        return string.concat(
            '{"version":"1.0","chainId":"',
            vm.toString(block.chainid),
            '","createdAt":',
            vm.toString(block.timestamp * 1000),
            ',"meta":{"name":"',
            name,
            '","description":"Generated by script/TimelockHandoff.s.sol","txBuilderVersion":"1.16.5",',
            '"createdFromSafeAddress":"',
            vm.toString(safe),
            '","createdFromOwnerAddress":"","checksum":""},"transactions":[',
            txs,
            "]}"
        );
    }
}
