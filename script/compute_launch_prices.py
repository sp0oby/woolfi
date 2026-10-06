#!/usr/bin/env python3
"""Compute each pool's initial sqrtPriceX96 from live Chainlink feeds on Robinhood Chain.

Reads the batch config, fills assets.*.feed and heartbeat from the docs/oracles.md feed table,
reads both legs' Chainlink answers plus token decimals over eth_call, orders each pool by token
address (lower address is token0), and computes the Q64.96 sqrt price at fair value:

    pool_price (raw1 / raw0) = (price0 / price1) * 10**(dec1 - dec0)
    sqrtPriceX96             = isqrt(pool_price * 2**192)

--dry-run (default) prints a table. --write updates the config in place.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import urllib.request
from pathlib import Path
from typing import Any, Callable

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = ROOT / "script" / "config" / "robinhood-batch.example.json"
ORACLES_DOC = ROOT / "docs" / "oracles.md"
DEFAULT_RPC = "https://rpc.mainnet.chain.robinhood.com"
HEARTBEAT = 86400
WAD = 10**18
EXPECTED_DECIMALS = {"USDG": 6}  # every other catalog token is 18

SEL_DECIMALS = "0x313ce567"
SEL_LATEST_ROUND = "0xfeaf968c"

EthCall = Callable[[str, str], str]


def make_eth_call(rpc_url: str) -> EthCall:
    """Return a function (to, data) -> hex result. The only network touchpoint; tests mock it."""

    def eth_call(to: str, data: str) -> str:
        body = json.dumps(
            {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": to, "data": data}, "latest"]}
        ).encode()
        req = urllib.request.Request(
            rpc_url, body, {"Content-Type": "application/json", "User-Agent": "Mozilla/5.0"}
        )
        with urllib.request.urlopen(req, timeout=30) as resp:
            out = json.load(resp)
        if "error" in out:
            raise RuntimeError(f"eth_call {to} {data}: {out['error']}")
        return out["result"]

    return eth_call


def feeds_from_doc(path: Path = ORACLES_DOC) -> dict[str, str]:
    """Parse the `| SYMBOL | `0x...` |` rows of the docs/oracles.md feed inventory table."""
    feeds: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\|\s*([A-Z]+)\s*\|\s*`(0x[0-9a-fA-F]{40})`", line)
        if m:
            feeds[m.group(1)] = m.group(2)
    return feeds


def read_decimals(eth_call: EthCall, address: str) -> int:
    return int(eth_call(address, SEL_DECIMALS), 16)


def read_feed_wad(eth_call: EthCall, feed: str) -> int:
    """Chainlink answer normalized to 1e18."""
    dec = read_decimals(eth_call, feed)
    raw = eth_call(feed, SEL_LATEST_ROUND)[2:]
    answer = int(raw[64:128], 16)
    if answer >= 2**255:
        answer -= 2**256
    if answer <= 0:
        raise ValueError(f"feed {feed} returned non-positive answer {answer}")
    return answer * 10 ** (18 - dec)


def sqrt_price_x96(price0_wad: int, price1_wad: int, dec0: int, dec1: int) -> int:
    """Q64.96 sqrt of (price0/price1) * 10**(dec1-dec0), integer math throughout."""
    if price0_wad <= 0 or price1_wad <= 0:
        raise ValueError("prices must be positive")
    if dec1 >= dec0:
        ratio_x192 = price0_wad * 10 ** (dec1 - dec0) * 2**192 // price1_wad
    else:
        ratio_x192 = price0_wad * 2**192 // (price1_wad * 10 ** (dec0 - dec1))
    return math.isqrt(ratio_x192)


def compute(config: dict[str, Any], eth_call: EthCall, feeds: dict[str, str]) -> list[dict[str, Any]]:
    assets = config["assets"]
    for symbol, asset in assets.items():
        if symbol not in feeds:
            raise ValueError(f"no feed in docs/oracles.md for {symbol}")
        asset["feed"] = feeds[symbol].lower()
        asset["heartbeat"] = HEARTBEAT

    decimals: dict[str, int] = {}
    for symbol, asset in assets.items():
        dec = read_decimals(eth_call, asset["token"])
        expected = EXPECTED_DECIMALS.get(symbol, 18)
        if dec != expected:
            raise ValueError(f"{symbol} token decimals {dec}, expected {expected}")
        decimals[symbol] = dec

    prices = {symbol: read_feed_wad(eth_call, asset["feed"]) for symbol, asset in assets.items()}

    rows = []
    for pool in config["pools"]:
        a, b = pool["base"], pool["quote"]
        t0, t1 = sorted((a, b), key=lambda s: int(assets[s]["token"], 16))
        value = sqrt_price_x96(prices[t0], prices[t1], decimals[t0], decimals[t1])
        pool["sqrtPriceX96"] = value
        rows.append(
            {"slug": pool["slug"], "token0": t0, "token1": t1, "price0": prices[t0], "price1": prices[t1], "sqrtPriceX96": value}
        )
    return rows


def dump_config(config: dict[str, Any]) -> str:
    """Pretty JSON, but one line per asset and per pool to match the hand-written example."""
    compact = lambda v: json.dumps(v, separators=(", ", ": "))  # noqa: E731
    lines = ["{"]
    keys = list(config)
    for i, key in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        value = config[key]
        if key == "assets":
            lines.append('  "assets": {')
            items = list(value.items())
            for j, (sym, asset) in enumerate(items):
                lines.append(f"    {json.dumps(sym)}: {compact(asset)}{',' if j < len(items) - 1 else ''}")
            lines.append("  }" + comma)
        elif key == "pools":
            lines.append('  "pools": [')
            for j, pool in enumerate(value):
                lines.append(f"    {compact(pool)}{',' if j < len(value) - 1 else ''}")
            lines.append("  ]" + comma)
        else:
            body = json.dumps(value, indent=2).replace("\n", "\n  ")
            lines.append(f"  {json.dumps(key)}: {body}{comma}")
    lines.append("}")
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--rpc-url", default=os.getenv("ROBINHOOD_RPC_URL", DEFAULT_RPC))
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--dry-run", action="store_true", default=True)
    mode.add_argument("--write", action="store_true")
    args = parser.parse_args()

    eth_call = make_eth_call(args.rpc_url)
    config = json.loads(args.config.read_text(encoding="utf-8"))
    rows = compute(config, eth_call, feeds_from_doc())

    print(f"{'pool':<11} {'t0':<5} {'t1':<5} {'price0 USD':>14} {'price1 USD':>14}  sqrtPriceX96")
    for r in rows:
        print(f"{r['slug']:<11} {r['token0']:<5} {r['token1']:<5} {r['price0'] / WAD:>14.4f} {r['price1'] / WAD:>14.4f}  {r['sqrtPriceX96']}")

    if args.write:
        args.config.write_text(dump_config(config), encoding="utf-8")
        print(f"wrote {args.config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
