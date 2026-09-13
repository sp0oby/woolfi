"""Execution layer for the validated Robinhood batch configuration."""

from __future__ import annotations

import os
import subprocess
import time
from pathlib import Path
from typing import Any

from robinhood_catalog import ASSETS, ZERO

ROOT = Path(__file__).resolve().parents[1]


def deploy(config: dict[str, Any], manifest: dict[str, Any], rpc_url: str, broadcast: bool) -> int:
    completed = {pool.get("slug") for pool in manifest.get("pools", [])}
    core = config["core"]
    for pool in config["pools"]:
        if pool["slug"] in completed:
            print(f"skip complete {pool['slug']}")
            continue
        ordered = _ordered_symbols(pool)
        env = os.environ.copy()
        env.update(
            pool_env(core, config["assets"], pool, ordered, config["defaultRisk"], config["defaultSafety"])
        )
        command = ["forge", "script", "script/CreatePool.s.sol:CreatePool", "--rpc-url", rpc_url]
        if broadcast:
            command.append("--broadcast")
        print(f"{'broadcast' if broadcast else 'dry-run'} {pool['slug']} (transactions are non-atomic)")
        result = subprocess.run(command, cwd=ROOT, env=env, check=False)
        if result.returncode:
            return result.returncode
    return 0


def seed(config: dict[str, Any], manifest: dict[str, Any], rpc_url: str, broadcast: bool) -> int:
    deployed = {pool.get("slug") for pool in manifest.get("pools", [])}
    seeded = {pool.get("slug") for pool in manifest.get("seededPools", [])}
    for pool in config["pools"]:
        slug = pool["slug"]
        if slug in seeded:
            print(f"skip seeded {slug}")
            continue
        if slug not in deployed:
            print(f"skip undeployed {slug}")
            continue
        env = os.environ.copy()
        env.update(seed_env(config["core"], pool, config["defaultRisk"]))
        command = [
            "forge",
            "script",
            "script/SeedInitialLiquidity.s.sol:SeedInitialLiquidity",
            "--rpc-url",
            rpc_url,
        ]
        if broadcast:
            command.append("--broadcast")
        print(f"{'broadcast' if broadcast else 'dry-run'} seed {slug}")
        result = subprocess.run(command, cwd=ROOT, env=env, check=False)
        if result.returncode:
            return result.returncode
    return 0


def _ordered_symbols(pool: dict[str, Any]) -> list[str]:
    return sorted((pool["base"], pool["quote"]), key=lambda symbol: int(ASSETS[symbol], 16))


def pool_env(
    core: dict[str, Any],
    assets: dict[str, Any],
    pool: dict[str, Any],
    ordered: list[str],
    default_risk: dict[str, Any],
    default_safety: dict[str, Any],
) -> dict[str, str]:
    risk = pool.get("risk", default_risk)
    safety = pool.get("safety", default_safety)
    return {
        "POOL_MANAGER": core["poolManager"], "HOOK": core["hook"],
        "GOVERNOR": core["governor"], "POSITION_MANAGER": core["positionManager"],
        "STAKING_TOKEN": core["stakingToken"], "REBALANCER": core["rebalancer"],
        "TREASURY_FEE_SINK": core["treasuryFeeSink"],
        "MARKET_HOURS": ZERO if pool["slug"] == "weth-usdg" else core["marketHours"],
        "TOKEN0": ASSETS[ordered[0]], "TOKEN1": ASSETS[ordered[1]],
        "ORACLE0": assets[ordered[0]]["oracle"], "ORACLE1": assets[ordered[1]]["oracle"],
        "TOKEN0_SYMBOL": ordered[0], "TOKEN1_SYMBOL": ordered[1], "POOL_SLUG": pool["slug"],
        "SQRT_PRICE_X96": str(pool["sqrtPriceX96"]),
        "URU_CAP": str(pool["vaultAllocationCap"]),
        "TICK_SPACING": str(risk["tickSpacing"]), "K_SCALED": str(risk["kScaled"]),
        "BASE_FEE_BPS": str(risk["baseFeeBps"]), "TOLERANCE_BPS": str(risk["toleranceBps"]),
        "HARD_THRESHOLD_BPS": str(risk["hardThresholdBps"]), "DRAWDOWN_BPS": str(risk["drawdownBps"]),
        "VAULT_FEE_BPS": str(risk["vaultFeeBps"]), "TREASURY_FEE_BPS": str(risk["treasuryFeeBps"]),
        "STABILIZATION_SECONDS": str(safety["stabilizationSeconds"]),
        "MAX_ORACLE_SKEW": str(safety["maxOracleSkew"]),
    }


def seed_env(core: dict[str, Any], pool: dict[str, Any], default_risk: dict[str, Any]) -> dict[str, str]:
    ordered = _ordered_symbols(pool)
    liquidity = pool["initialLiquidity"]
    amounts = {
        pool["base"]: liquidity["base"],
        pool["quote"]: liquidity["quote"],
    }
    risk = pool.get("risk", default_risk)
    return {
        "HOOK": core["hook"],
        "POSITION_MANAGER": core["positionManager"],
        "TOKEN0": ASSETS[ordered[0]],
        "TOKEN1": ASSETS[ordered[1]],
        "INITIAL_LIQUIDITY_0": str(amounts[ordered[0]]),
        "INITIAL_LIQUIDITY_1": str(amounts[ordered[1]]),
        "MIN_SHARES": str(liquidity.get("minShares") or 1),
        "DEADLINE": str(int(os.getenv("SEED_DEADLINE") or (time.time() + 20 * 60))),
        "TICK_SPACING": str(risk["tickSpacing"]),
    }
