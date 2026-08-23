"""Execution layer for the validated Robinhood batch configuration."""

from __future__ import annotations

import os
import subprocess
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
        ordered = sorted((pool["base"], pool["quote"]), key=lambda symbol: int(ASSETS[symbol], 16))
        env = os.environ.copy()
        env.update(
            _pool_env(core, config["assets"], pool, ordered, config["defaultRisk"], config["defaultSafety"])
        )
        command = ["forge", "script", "script/CreatePool.s.sol:CreatePool", "--rpc-url", rpc_url]
        if broadcast:
            command.append("--broadcast")
        print(f"{'broadcast' if broadcast else 'dry-run'} {pool['slug']} (transactions are non-atomic)")
        result = subprocess.run(command, cwd=ROOT, env=env, check=False)
        if result.returncode:
            return result.returncode
    return 0


def _pool_env(
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
        "BUYBACK_SINK": core["buybackSink"],
        "MARKET_HOURS": ZERO if pool["slug"] == "weth-usdg" else core["marketHours"],
        "TOKEN0": ASSETS[ordered[0]], "TOKEN1": ASSETS[ordered[1]],
        "ORACLE0": assets[ordered[0]]["oracle"], "ORACLE1": assets[ordered[1]]["oracle"],
        "TOKEN0_SYMBOL": ordered[0], "TOKEN1_SYMBOL": ordered[1], "POOL_SLUG": pool["slug"],
        "SQRT_PRICE_X96": str(pool["sqrtPriceX96"]),
        "TICK_SPACING": str(risk["tickSpacing"]), "K_SCALED": str(risk["kScaled"]),
        "BASE_FEE_BPS": str(risk["baseFeeBps"]), "TOLERANCE_BPS": str(risk["toleranceBps"]),
        "HARD_THRESHOLD_BPS": str(risk["hardThresholdBps"]), "DRAWDOWN_BPS": str(risk["drawdownBps"]),
        "VAULT_FEE_BPS": str(risk["vaultFeeBps"]), "BUYBACK_BPS": str(risk["buybackBps"]),
        "STABILIZATION_SECONDS": str(safety["stabilizationSeconds"]),
        "MAX_ORACLE_SKEW": str(safety["maxOracleSkew"]),
    }
