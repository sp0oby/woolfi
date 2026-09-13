#!/usr/bin/env python3
"""Fail-closed, resumable coordinator for WoolFi production launch operations."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
import urllib.request
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "script/config/launch-operations.example.json"
ZERO = "0x0000000000000000000000000000000000000000"
PHASES = ("core", "router-rebate", "oracles-pools", "liquidity", "rebate-funding", "ownership", "services")


def load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def digest_operation(operation: dict[str, Any]) -> str:
    canonical = json.dumps(operation, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def validate_config(config: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if config.get("chainId") != 4663:
        errors.append("chainId must equal 4663")
    if config.get("broadcastEnabled") is not False:
        errors.append("broadcastEnabled must remain false in committed configuration")
    if config.get("launchEnabled") is not False:
        errors.append("launchEnabled must remain false in committed configuration")
    operations = config.get("operations")
    if not isinstance(operations, list):
        return errors + ["operations must be an array"]
    ids: set[str] = set()
    phases: set[str] = set()
    for index, operation in enumerate(operations):
        label = f"operations[{index}]"
        if not isinstance(operation, dict):
            errors.append(f"{label} must be an object")
            continue
        op_id = operation.get("id")
        phase = operation.get("phase")
        if not isinstance(op_id, str) or not op_id:
            errors.append(f"{label}.id must be non-empty")
        elif op_id in ids:
            errors.append(f"duplicate operation id: {op_id}")
        else:
            ids.add(op_id)
        if phase not in PHASES:
            errors.append(f"{label}.phase is invalid")
        else:
            phases.add(phase)
        argv = operation.get("argv")
        if argv is not None:
            if not isinstance(argv, list) or not argv or not all(isinstance(v, str) and v for v in argv):
                errors.append(f"{label}.argv must be a non-empty string array")
            elif any(v in ("--broadcast", "--resume") for v in argv):
                errors.append(f"{label}.argv must not contain broadcast flags")
        if "approvalReference" in operation and operation["approvalReference"]:
            errors.append(f"{label}.approvalReference must be empty until an actual approval exists")
        for dependency in operation.get("dependsOn", []):
            if dependency not in ids:
                errors.append(f"{label}.dependsOn must reference an earlier operation: {dependency}")
    missing = set(PHASES) - phases
    if missing:
        errors.append(f"operations missing phases: {', '.join(sorted(missing))}")
    return errors


def plan(config: dict[str, Any]) -> dict[str, Any]:
    return {
        "chainId": config["chainId"],
        "broadcast": False,
        "launchEnabled": False,
        "operations": [
            {
                "id": op["id"],
                "phase": op["phase"],
                "dependsOn": op.get("dependsOn", []),
                "runnable": bool(op.get("argv")),
                "digest": digest_operation(op),
            }
            for op in config["operations"]
        ],
    }


def run_dry(config: dict[str, Any], state_path: Path) -> int:
    state = load(state_path) if state_path.exists() else {"chainId": 4663, "completed": {}}
    completed = state.setdefault("completed", {})
    for operation in config["operations"]:
        op_id = operation["id"]
        digest = digest_operation(operation)
        previous = completed.get(op_id)
        if previous and previous.get("digest") == digest:
            print(f"skip verified simulation {op_id}")
            continue
        missing = [item for item in operation.get("dependsOn", []) if item not in completed]
        if missing:
            print(f"blocked {op_id}: incomplete dependencies {', '.join(missing)}")
            return 1
        argv = operation.get("argv")
        if not argv:
            print(f"checkpoint {op_id}: {operation.get('evidence', 'operator evidence required')}")
            return 1
        env = os.environ.copy()
        env.update({key: str(value) for key, value in operation.get("env", {}).items()})
        env["CONFIRM_MAINNET"] = "false"
        result = subprocess.run(argv, cwd=ROOT, env=env, check=False)
        if result.returncode:
            return result.returncode
        completed[op_id] = {"digest": digest, "simulation": True}
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state_path.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    return 0


class Rpc:
    def __init__(self, url: str):
        self.url = url
        self.request_id = 0

    def call(self, method: str, params: list[Any]) -> Any:
        self.request_id += 1
        payload = json.dumps({"jsonrpc": "2.0", "id": self.request_id, "method": method, "params": params}).encode()
        request = urllib.request.Request(self.url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=20) as response:
            body = json.load(response)
        if "error" in body:
            raise RuntimeError(f"RPC {method}: {body['error']}")
        return body["result"]


def verify_receipts(receipts: dict[str, Any], rpc: Rpc) -> list[str]:
    errors: list[str] = []
    if receipts.get("chainId") != 4663 or rpc.call("eth_chainId", []) != hex(4663):
        errors.append("receipt journal and RPC must use chain 4663")
        return errors
    entries = receipts.get("receipts", [])
    if not isinstance(entries, list) or not entries:
        return errors + ["receipt journal must contain at least one receipt"]
    for index, entry in enumerate(entries):
        tx_hash = entry.get("transactionHash", "")
        if not isinstance(tx_hash, str) or len(tx_hash) != 66 or not tx_hash.startswith("0x"):
            errors.append(f"receipts[{index}] transactionHash is invalid")
            continue
        receipt = rpc.call("eth_getTransactionReceipt", [tx_hash])
        if not receipt or int(receipt.get("status", "0x0"), 16) != 1:
            errors.append(f"receipts[{index}] transaction is missing or failed")
            continue
        if int(receipt["blockNumber"], 16) != entry.get("blockNumber"):
            errors.append(f"receipts[{index}] blockNumber mismatch")
        for label, address in entry.get("contracts", {}).items():
            if not isinstance(address, str) or address.lower() == ZERO:
                errors.append(f"receipts[{index}].contracts.{label} is zero or invalid")
            elif rpc.call("eth_getCode", [address, hex(entry["blockNumber"])]) in ("0x", "0x0", "0x00"):
                errors.append(f"receipts[{index}].contracts.{label} had no code at receipt block")
    return errors


def reconcile_manifest(receipts: dict[str, Any], manifest_path: Path) -> None:
    manifest = load(manifest_path)
    allowed = {
        "hook", "positionManager", "governor", "swapRouter", "rebateDistributor",
        "liquidityZapper", "externalSwapExecutor", "marketHours", "keeper",
    }
    manifest.setdefault("startBlocks", {})
    manifest.setdefault("receipts", [])
    pools = {pool["slug"]: pool for pool in manifest.get("pools", [])}
    for entry in receipts.get("receipts", []):
        tx_hash = entry["transactionHash"]
        block = entry["blockNumber"]
        for key, value in entry.get("manifest", {}).items():
            if key == "pool":
                pool = value
                if not isinstance(pool, dict) or not pool.get("slug") or not pool.get("poolId"):
                    raise ValueError("receipt manifest pool must include slug and poolId")
                existing = pools.get(pool["slug"])
                if existing and existing != pool:
                    raise ValueError(f"manifest conflict for pool {pool['slug']}")
                pool["startBlock"] = block
                pool["receipt"] = tx_hash
                pools[pool["slug"]] = pool
                continue
            if key not in allowed:
                raise ValueError(f"unsupported manifest field: {key}")
            if value.lower() not in (address.lower() for address in entry.get("contracts", {}).values()):
                raise ValueError(f"manifest {key} is not receipt-backed")
            current = str(manifest.get(key, ZERO))
            if current.lower() not in (ZERO, value.lower()):
                raise ValueError(f"manifest conflict at {key}")
            manifest[key] = value
            manifest["startBlocks"][key] = block
        if tx_hash not in manifest["receipts"]:
            manifest["receipts"].append(tx_hash)
    manifest["pools"] = list(pools.values())
    manifest["poolCount"] = len(pools)
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("validate", "plan", "run-dry", "verify-receipts", "reconcile"))
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--state", type=Path, default=ROOT / ".launch-state/simulations.json")
    parser.add_argument("--receipts", type=Path)
    parser.add_argument("--manifest", type=Path, default=ROOT / "frontend/lib/deployments/robinhood.json")
    parser.add_argument("--rpc-url", default=os.getenv("ROBINHOOD_RPC_URL", ""))
    args = parser.parse_args()
    config = load(args.config)
    errors = validate_config(config)
    if errors:
        print(json.dumps({"valid": False, "errors": errors}, indent=2))
        return 1
    if args.command == "validate":
        print(json.dumps({"valid": True, "broadcast": False, "launchEnabled": False}))
        return 0
    if args.command == "plan":
        print(json.dumps(plan(config), indent=2))
        return 0
    if args.command == "run-dry":
        return run_dry(config, args.state)
    if not args.receipts or not args.rpc_url:
        print("verify-receipts requires --receipts and --rpc-url", file=sys.stderr)
        return 2
    receipt_errors = verify_receipts(load(args.receipts), Rpc(args.rpc_url))
    print(json.dumps({"valid": not receipt_errors, "errors": receipt_errors}, indent=2))
    if receipt_errors:
        return 1
    if args.command == "reconcile":
        reconcile_manifest(load(args.receipts), args.manifest)
    return 0


if __name__ == "__main__":
    sys.exit(main())
