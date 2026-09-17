#!/usr/bin/env python3
"""Deploy one oracle adapter per catalog asset whose batch-config `oracle` is still zero.

Stock/ETF legs get a `RobinhoodStockOracleAdapter`; WETH and USDG get a plain
`ChainlinkOracleAdapter`. Inputs come from `assets.<SYMBOL>.{token,feed,heartbeat,oracleKind}`
in the batch config. On `--broadcast` the resulting adapter address is written back into
`assets.<SYMBOL>.oracle` after every successful deploy, so an interrupted run resumes by
skipping whatever is already recorded. Dry runs never write.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

from robinhood_catalog import ASSETS, ZERO

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "script/config/robinhood-batch.example.json"
ADAPTER_LINE = re.compile(r"Oracle adapter\s+(0x[0-9a-fA-F]{40})")

SCRIPTS = {
    "stock-pause-guarded": "script/DeployRobinhoodOracle.s.sol:DeployRobinhoodOracle",
    "chainlink": "script/DeployChainlinkOracle.s.sol:DeployChainlinkOracle",
}


def adapter_env(core: dict[str, Any], symbol: str, asset: dict[str, Any]) -> dict[str, str | None]:
    """Env overlay for one adapter deploy. A `None` value means "unset this variable"."""
    kind = asset.get("oracleKind")
    if kind not in SCRIPTS:
        raise ValueError(f"assets.{symbol}.oracleKind must be one of {sorted(SCRIPTS)}")
    feed = str(asset.get("feed", ZERO))
    heartbeat = asset.get("heartbeat", 0)
    if feed.lower() == ZERO or isinstance(heartbeat, bool) or not isinstance(heartbeat, int) or heartbeat <= 0:
        raise ValueError(f"assets.{symbol} needs a nonzero feed and positive heartbeat before adapter deploy")
    env: dict[str, str | None] = {"CHAINLINK_FEED": feed, "FEED_HEARTBEAT": str(heartbeat)}
    if kind == "stock-pause-guarded":
        env["STOCK_TOKEN"] = ASSETS.get(symbol, str(asset.get("token", ZERO)))
        sequencer = str(core.get("sequencerUptimeFeed", ZERO))
        if sequencer.lower() != ZERO:
            env["SEQUENCER_UPTIME_FEED"] = sequencer
            env["SEQUENCER_GRACE_PERIOD"] = str(core.get("sequencerGracePeriod", 0))
        else:
            # Spec 5.1: no L2 uptime feed on 4663, deploy with the guard disabled. Clear any
            # stale values from the operator's shell so they cannot silently re-enable it.
            env["SEQUENCER_UPTIME_FEED"] = None
            env["SEQUENCER_GRACE_PERIOD"] = None
    return env


def run_adapters(
    config: dict[str, Any],
    rpc_url: str,
    broadcast: bool,
    runner: Callable[..., Any] = subprocess.run,
    config_path: Path | None = None,
) -> tuple[int, dict[str, str]]:
    core = config["core"]
    deployed: dict[str, str] = {}
    for symbol, asset in config["assets"].items():
        if str(asset.get("oracle", ZERO)).lower() != ZERO:
            print(f"skip {symbol}: adapter already recorded {asset['oracle']}")
            continue
        overlay = adapter_env(core, symbol, asset)
        env = os.environ.copy()
        for key, value in overlay.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
        command = ["forge", "script", SCRIPTS[asset["oracleKind"]], "--rpc-url", rpc_url]
        if broadcast:
            command.append("--broadcast")
        print(f"{'broadcast' if broadcast else 'dry-run'} adapter {symbol} ({asset['oracleKind']})")
        result = runner(command, cwd=ROOT, env=env, check=False, capture_output=True, text=True)
        sys.stdout.write(result.stdout or "")
        sys.stderr.write(result.stderr or "")
        if result.returncode:
            return result.returncode, deployed
        match = ADAPTER_LINE.search(result.stdout or "")
        if not match:
            print(f"error: could not parse adapter address for {symbol}", file=sys.stderr)
            return 1, deployed
        deployed[symbol] = match.group(1)
        if broadcast:
            asset["oracle"] = match.group(1)
            if config_path is not None:
                write_config(config_path, config)
    return 0, deployed


def write_config(path: Path, config: dict[str, Any]) -> None:
    path.write_text(json.dumps(config, indent=2) + "\n", encoding="utf-8")


def load(path: Path) -> dict[str, Any]:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--rpc-url", default=os.getenv("ROBINHOOD_RPC_URL", ""))
    parser.add_argument("--broadcast", action="store_true")
    args = parser.parse_args()
    if not args.rpc_url:
        print("--rpc-url (or ROBINHOOD_RPC_URL) is required", file=sys.stderr)
        return 2
    if args.broadcast and os.getenv("CONFIRM_MAINNET", "").lower() != "true":
        print(json.dumps({"ready": False, "errors": ["set CONFIRM_MAINNET=true before broadcast"]}))
        return 1
    config = load(args.config)
    code, deployed = run_adapters(config, args.rpc_url, args.broadcast, config_path=args.config)
    print(json.dumps({"broadcast": args.broadcast, "adapters": deployed}, indent=2))
    return code


if __name__ == "__main__":
    sys.exit(main())
