#!/usr/bin/env python3
"""Validated, resumable coordinator for the 18 Robinhood production pools."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request
from pathlib import Path
from typing import Any

from robinhood_batch_deploy import deploy
from robinhood_catalog import (
    ALWAYS_OPEN_SLUGS,
    ASSETS,
    CHAIN_ID,
    GATE_FIELDS,
    PAIRS,
    POOL_MANAGER,
    SLUGS,
    SPREAD_SLUGS,
    STAKING_TOKEN,
    UNISWAP_V3_SWAP_ROUTER,
    URUFU_NFT,
    ZERO,
)

ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
TX_HASH = re.compile(r"^0x[0-9a-fA-F]{64}$")
ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "script/config/robinhood-batch.example.json"
DEFAULT_MANIFEST = ROOT / "frontend/lib/deployments/robinhood.json"


class Rpc:
    def __init__(self, url: str):
        self.url = url
        self.request_id = 0

    def call(self, method: str, params: list[Any]) -> Any:
        self.request_id += 1
        body = json.dumps(
            {"jsonrpc": "2.0", "id": self.request_id, "method": method, "params": params}
        ).encode()
        request = urllib.request.Request(
            self.url, data=body, headers={"Content-Type": "application/json"}
        )
        with urllib.request.urlopen(request, timeout=20) as response:
            result = json.load(response)
        if "error" in result:
            raise RuntimeError(f"RPC {method}: {result['error']}")
        return result["result"]

    def chain_id(self) -> int:
        return int(self.call("eth_chainId", []), 16)

    def has_code(self, address: str) -> bool:
        return self.call("eth_getCode", [address, "latest"]) not in ("0x", "0x0", "0x00")


def _address(value: Any, label: str, errors: list[str], *, allow_zero: bool = False) -> str:
    if not isinstance(value, str) or not ADDRESS.fullmatch(value):
        errors.append(f"{label} must be a 20-byte hex address")
        return ZERO
    if not allow_zero and value.lower() == ZERO:
        errors.append(f"{label} must be nonzero")
    return value.lower()


def _positive(value: Any, label: str, errors: list[str]) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value <= 0:
        errors.append(f"{label} must be a positive integer")
        return 0
    return value


def _nonneg(value: Any, label: str, errors: list[str]) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 0:
        errors.append(f"{label} must be a non-negative integer")
        return 0
    return value


def validate(
    config: dict[str, Any],
    manifest: dict[str, Any],
    rpc: Rpc | None,
    *,
    require_deployed: bool,
) -> list[str]:
    errors: list[str] = []
    if config.get("chainId") != CHAIN_ID:
        errors.append(f"config.chainId must equal {CHAIN_ID}")
    if manifest.get("chainId") != CHAIN_ID:
        errors.append(f"manifest.chainId must equal {CHAIN_ID}")

    core = config.get("core", {})
    if not isinstance(core, dict):
        errors.append("core must be an object")
        core = {}
    contract_addresses: list[tuple[str, str]] = []
    for field in (
        "poolManager", "stakingToken", "hook", "positionManager", "governor",
        "swapRouter", "rebateDistributor", "liquidityZapper", "externalSwapExecutor", "urufuNft",
    ):
        value = _address(core.get(field), f"core.{field}", errors)
        contract_addresses.append((f"core.{field}", value))
    if str(core.get("poolManager", "")).lower() != POOL_MANAGER:
        errors.append("core.poolManager is not the canonical Robinhood PoolManager")
    if str(core.get("stakingToken", "")).lower() != STAKING_TOKEN:
        errors.append("core.stakingToken is not canonical URU")
    if str(core.get("externalSwapExecutor", "")).lower() != UNISWAP_V3_SWAP_ROUTER:
        errors.append("core.externalSwapExecutor is not the canonical Uniswap v3 SwapRouter02")
    if str(core.get("urufuNft", "")).lower() != URUFU_NFT:
        errors.append("core.urufuNft is not canonical Urufu Gemu")
    for field in ("treasury", "rebalancer", "treasuryFeeSink"):
        _address(core.get(field), f"core.{field}", errors)
    multisig = _address(core.get("multisig"), "core.multisig", errors)
    contract_addresses.append(("core.multisig", multisig))
    market_hours = _address(core.get("marketHours"), "core.marketHours", errors)
    contract_addresses.append(("core.marketHours", market_hours))
    sequencer = _address(core.get("sequencerUptimeFeed"), "core.sequencerUptimeFeed", errors)
    contract_addresses.append(("core.sequencerUptimeFeed", sequencer))
    _positive(core.get("sequencerGracePeriod"), "core.sequencerGracePeriod", errors)
    total_cap = _positive(core.get("totalTreasuryAllocationCap"), "core.totalTreasuryAllocationCap", errors)

    assets = config.get("assets", {})
    if not isinstance(assets, dict):
        errors.append("assets must be an object")
        assets = {}
    if set(assets) != set(ASSETS):
        errors.append("assets must contain exactly the canonical curated symbols")
    for symbol, canonical in ASSETS.items():
        item = assets.get(symbol, {})
        if not isinstance(item, dict):
            errors.append(f"assets.{symbol} must be an object")
            continue
        token = _address(item.get("token"), f"assets.{symbol}.token", errors)
        if token != canonical:
            errors.append(f"assets.{symbol}.token is not canonical")
        contract_addresses.append((f"assets.{symbol}.token", token))
        oracle = _address(item.get("oracle"), f"assets.{symbol}.oracle", errors)
        feed = _address(item.get("feed"), f"assets.{symbol}.feed", errors)
        heartbeat = _positive(item.get("heartbeat"), f"assets.{symbol}.heartbeat", errors)
        expected_kind = "chainlink" if symbol in ("WETH", "USDG") else "stock-pause-guarded"
        if item.get("oracleKind") != expected_kind:
            errors.append(f"assets.{symbol}.oracleKind must be {expected_kind}")
        contract_addresses.extend(
            ((f"assets.{symbol}.oracle", oracle), (f"assets.{symbol}.feed", feed))
        )
        if heartbeat > 30 * 24 * 60 * 60:
            errors.append(f"assets.{symbol}.heartbeat is implausibly large")

    pools = config.get("pools", [])
    if not isinstance(pools, list) or len(pools) != len(PAIRS):
        errors.append(f"pools must contain exactly {len(PAIRS)} entries")
        pools = []
    seen_slugs: set[str] = set()
    seen_pairs: set[tuple[str, str]] = set()
    allocated = 0
    by_slug: dict[str, dict[str, Any]] = {}
    for index, pool in enumerate(pools):
        if not isinstance(pool, dict):
            errors.append(f"pools[{index}] must be an object")
            continue
        slug = pool.get("slug")
        base, quote = pool.get("base"), pool.get("quote")
        pair = tuple(sorted((str(base), str(quote))))
        if slug in seen_slugs:
            errors.append(f"duplicate pool slug: {slug}")
        if pair in seen_pairs:
            errors.append(f"duplicate or reversed pair: {slug}")
        seen_slugs.add(str(slug))
        seen_pairs.add(pair)
        by_slug[str(slug)] = pool
        cap = _positive(pool.get("vaultAllocationCap"), f"{slug}.vaultAllocationCap", errors)
        allocated += cap
        _positive(pool.get("sqrtPriceX96"), f"{slug}.sqrtPriceX96", errors)
        liquidity = pool.get("initialLiquidity", {})
        _positive(liquidity.get("base"), f"{slug}.initialLiquidity.base", errors)
        _positive(liquidity.get("quote"), f"{slug}.initialLiquidity.quote", errors)
        slippage = _positive(liquidity.get("slippageBps"), f"{slug}.initialLiquidity.slippageBps", errors)
        if slippage > 10_000:
            errors.append(f"{slug}.initialLiquidity.slippageBps exceeds 10000")
        _validate_risk(slug, pool.get("risk", config.get("defaultRisk", {})), errors)
        _validate_hours_and_safety(str(slug), pool, config.get("defaultSafety", {}), errors)
    if set(seen_slugs) != set(SLUGS):
        errors.append("pool slugs do not exactly match the canonical catalog")
    for (base, quote), slug in zip(PAIRS, SLUGS):
        pool = by_slug.get(slug, {})
        if pool.get("base") != base or pool.get("quote") != quote:
            errors.append(f"{slug} does not match canonical pair {base}/{quote}")
    if allocated > total_cap:
        errors.append("sum of vaultAllocationCap exceeds totalTreasuryAllocationCap")

    deployed = _validate_manifest(manifest, core, errors)
    if require_deployed and deployed != set(SLUGS):
        errors.append(f"deployment incomplete: {len(deployed)}/{len(SLUGS)} canonical pools complete")
    if require_deployed:
        for field in (
            "hook", "positionManager", "governor", "swapRouter", "rebateDistributor", "liquidityZapper"
        ):
            if str(core.get(field, ZERO)).lower() == ZERO:
                errors.append(f"core.{field} is not deployed")
        errors.extend(_validate_gates(config.get("gates", {})))
    if not config.get("nonAtomicTransactionsAcknowledged"):
        errors.append("nonAtomicTransactionsAcknowledged must be true")

    if rpc:
        try:
            if rpc.chain_id() != CHAIN_ID:
                errors.append(f"RPC must report chain ID {CHAIN_ID}")
            for label, address in dict(contract_addresses).items():
                if address != ZERO and not rpc.has_code(address):
                    errors.append(f"{label} has no contract code")
        except Exception as exc:  # readiness must fail closed on RPC errors
            errors.append(str(exc))
    else:
        errors.append("RPC URL is required for code and chain validation")
    return errors


def _validate_hours_and_safety(slug: str, pool: dict[str, Any], default_safety: Any, errors: list[str]) -> None:
    expected = "always-open" if slug in ALWAYS_OPEN_SLUGS else "equity-hours"
    if pool.get("hoursPolicy") != expected:
        errors.append(f"{slug}.hoursPolicy must be {expected}")
    safety = pool.get("safety", default_safety)
    if not isinstance(safety, dict):
        errors.append(f"{slug}.safety must be an object")
        return
    stabilization = _nonneg(safety.get("stabilizationSeconds"), f"{slug}.safety.stabilizationSeconds", errors)
    skew = _nonneg(safety.get("maxOracleSkew"), f"{slug}.safety.maxOracleSkew", errors)
    if slug in ALWAYS_OPEN_SLUGS:
        if stabilization != 0 or skew != 0:
            errors.append(f"{slug} must disable stabilization and oracle skew")
    elif slug in SPREAD_SLUGS:
        if skew == 0:
            errors.append(f"{slug}.safety.maxOracleSkew must be positive")
        if stabilization == 0:
            errors.append(f"{slug}.safety.stabilizationSeconds must be positive")
    elif stabilization == 0:
        errors.append(f"{slug}.safety.stabilizationSeconds must be positive")


def _validate_gates(gates: Any) -> list[str]:
    if not isinstance(gates, dict):
        return ["gates must be an object"]
    errors: list[str] = []
    if set(gates) != set(GATE_FIELDS):
        errors.append("gates must contain exactly the operational launch fields")
    for field in GATE_FIELDS:
        if gates.get(field) is not True:
            errors.append(f"gates.{field} is not approved")
    return errors


def _validate_risk(slug: str, risk: Any, errors: list[str]) -> None:
    if not isinstance(risk, dict):
        errors.append(f"{slug}.risk must be an object")
        return
    tick = _positive(risk.get("tickSpacing"), f"{slug}.risk.tickSpacing", errors)
    if tick > 32767:
        errors.append(f"{slug}.risk.tickSpacing is out of range")
    for field in (
        "kScaled", "baseFeeBps", "toleranceBps", "hardThresholdBps",
        "drawdownBps", "vaultFeeBps", "treasuryFeeBps",
    ):
        value = _positive(risk.get(field), f"{slug}.risk.{field}", errors)
        if field != "kScaled" and value > 10_000:
            errors.append(f"{slug}.risk.{field} exceeds 10000")


def _validate_manifest(
    manifest: dict[str, Any], core: dict[str, Any], errors: list[str]
) -> set[str]:
    start_blocks = manifest.get("startBlocks", {})
    receipts = manifest.get("receipts", [])
    if not isinstance(start_blocks, dict):
        errors.append("manifest startBlocks must be an object")
        start_blocks = {}
    if not isinstance(receipts, list) or any(not isinstance(item, str) or not TX_HASH.fullmatch(item) for item in receipts):
        errors.append("manifest receipts must contain transaction hashes")
        receipts = []
    for manifest_field, config_field in (
        ("poolManager", "poolManager"), ("stakingToken", "stakingToken"),
        ("hook", "hook"), ("positionManager", "positionManager"), ("governor", "governor"),
        ("swapRouter", "swapRouter"), ("rebateDistributor", "rebateDistributor"),
        ("liquidityZapper", "liquidityZapper"), ("externalSwapExecutor", "externalSwapExecutor"),
        ("urufuNft", "urufuNft"),
    ):
        current = str(manifest.get(manifest_field, ZERO)).lower()
        expected = str(core.get(config_field, ZERO)).lower()
        if current != ZERO and expected != ZERO and current != expected:
            errors.append(f"manifest {manifest_field} conflicts with config")
        if current != ZERO and manifest_field not in (
            "poolManager", "stakingToken", "externalSwapExecutor", "urufuNft"
        ):
            if not isinstance(start_blocks.get(manifest_field), int) or start_blocks[manifest_field] <= 0:
                errors.append(f"manifest {manifest_field} lacks a receipt-backed start block")
            if not receipts:
                errors.append(f"manifest {manifest_field} lacks a deployment receipt")
    pools = manifest.get("pools", [])
    if manifest.get("poolCount") != len(pools):
        errors.append("manifest poolCount does not match pools length")
    deployed: set[str] = set()
    pair_keys: set[tuple[str, str]] = set()
    for pool in pools:
        slug = pool.get("slug")
        if slug not in SLUGS:
            errors.append(f"manifest contains unknown pool: {slug}")
            continue
        tokens = tuple(sorted((str(pool.get("token0", "")).lower(), str(pool.get("token1", "")).lower())))
        canonical = PAIRS[SLUGS.index(slug)]
        expected = tuple(sorted((ASSETS[canonical[0]], ASSETS[canonical[1]])))
        if tokens != expected:
            errors.append(f"manifest {slug} token pair mismatch")
        if slug in deployed or tokens in pair_keys:
            errors.append(f"manifest duplicate/reversed pool: {slug}")
        deployed.add(slug)
        pair_keys.add(tokens)
        for field in ("poolId", "oracle0", "oracle1", "vault"):
            if str(pool.get(field, ZERO)).lower() in ("", ZERO):
                errors.append(f"manifest {slug}.{field} is incomplete")
        if not isinstance(pool.get("startBlock"), int) or pool["startBlock"] <= 0:
            errors.append(f"manifest {slug}.startBlock is incomplete")
        if not isinstance(pool.get("receipt"), str) or not TX_HASH.fullmatch(pool["receipt"]):
            errors.append(f"manifest {slug}.receipt is incomplete")
        if slug != "weth-usdg" and str(pool.get("marketHours", ZERO)).lower() == ZERO:
            errors.append(f"manifest {slug}.marketHours is incomplete")
    return deployed


def _load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("readiness", "deploy"))
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--rpc-url", default=os.getenv("ROBINHOOD_RPC_URL", ""))
    parser.add_argument("--broadcast", action="store_true")
    args = parser.parse_args()
    config, manifest = _load(args.config), _load(args.manifest)
    rpc = Rpc(args.rpc_url) if args.rpc_url else None
    errors = validate(config, manifest, rpc, require_deployed=args.command == "readiness")
    if errors:
        print(json.dumps({"ready": False, "errors": errors}, indent=2))
        return 1
    if args.command == "readiness":
        print(json.dumps({"ready": True, "completePools": 18}))
        return 0
    if args.broadcast and os.getenv("CONFIRM_MAINNET", "").lower() != "true":
        print(json.dumps({"ready": False, "errors": ["set CONFIRM_MAINNET=true before broadcast"]}))
        return 1
    return deploy(config, manifest, args.rpc_url, args.broadcast)


if __name__ == "__main__":
    sys.exit(main())
