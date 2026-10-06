import json
import math
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))

from compute_launch_prices import (  # noqa: E402
    SEL_DECIMALS,
    SEL_LATEST_ROUND,
    compute,
    dump_config,
    sqrt_price_x96,
)

USDG = "0x5fc5360d0400a0fd4f2af552add042d716f1d168"
MSTR = "0xec262a75e413fafd0df80480274532c79d42da09"
WETH = "0x0bd7d308f8e1639fab988df18a8011f41eacad73"
F_USDG = "0x61b7e5650328764b076a108eff5fa7282a1b9ad2"
F_MSTR = "0x396118bdfb181e6240e74d243f266b061c0edc3d"
F_WETH = "0x78f3556b67e17df817d51ef5a990cdaf09e8d3a9"


def word(n: int) -> str:
    return format(n, "064x")


class MockRpc:
    def __init__(self, token_decimals, feed_answers):
        self.token_decimals = token_decimals
        self.feed_answers = feed_answers

    def __call__(self, to, data):
        to = to.lower()
        if data == SEL_DECIMALS:
            if to in self.feed_answers:
                return "0x" + word(8)
            return "0x" + word(self.token_decimals[to])
        if data == SEL_LATEST_ROUND:
            return "0x" + word(1) + word(self.feed_answers[to]) + word(0) + word(1) + word(1)
        raise AssertionError((to, data))


def config(assets, pools):
    return {
        "assets": {s: {"token": t, "oracle": "0x" + "0" * 40, "feed": "0x" + "0" * 40, "heartbeat": 0} for s, t in assets},
        "pools": [{"slug": f"{b.lower()}-{q.lower()}", "base": b, "quote": q, "sqrtPriceX96": 0} for b, q in pools],
    }


FEEDS = {"USDG": F_USDG, "MSTR": F_MSTR, "WETH": F_WETH}


class SqrtPriceTest(unittest.TestCase):
    def test_usdg_mstr_6_vs_18_decimals(self):
        # USDG sorts below MSTR, so USDG is token0. price0=$1, price1=$130.
        cfg = config([("MSTR", MSTR), ("USDG", USDG)], [("MSTR", "USDG")])
        rpc = MockRpc({USDG: 6, MSTR: 18}, {F_USDG: 1 * 10**8, F_MSTR: 130 * 10**8})
        rows = compute(cfg, rpc, FEEDS)
        self.assertEqual((rows[0]["token0"], rows[0]["token1"]), ("USDG", "MSTR"))
        # raw1/raw0 = (1/130) * 10**12
        expected = math.isqrt(10**12 * 2**192 // 130)
        self.assertEqual(cfg["pools"][0]["sqrtPriceX96"], expected)
        self.assertEqual(cfg["assets"]["MSTR"]["feed"], F_MSTR)
        self.assertEqual(cfg["assets"]["MSTR"]["heartbeat"], 86400)

    def test_weth_usdg_order_flips(self):
        # WETH (0x0b..) sorts below USDG (0x5f..), so WETH is token0 even though base is WETH.
        cfg = config([("WETH", WETH), ("USDG", USDG)], [("WETH", "USDG")])
        rpc = MockRpc({USDG: 6, WETH: 18}, {F_USDG: 1 * 10**8, F_WETH: 4000 * 10**8})
        rows = compute(cfg, rpc, FEEDS)
        self.assertEqual((rows[0]["token0"], rows[0]["token1"]), ("WETH", "USDG"))
        # raw1/raw0 = 4000 / 10**12
        expected = math.isqrt(4000 * 2**192 // 10**12)
        self.assertEqual(cfg["pools"][0]["sqrtPriceX96"], expected)

    def test_decimals_mismatch_raises(self):
        cfg = config([("MSTR", MSTR), ("USDG", USDG)], [("MSTR", "USDG")])
        rpc = MockRpc({USDG: 18, MSTR: 18}, {F_USDG: 10**8, F_MSTR: 10**8})
        with self.assertRaisesRegex(ValueError, "USDG token decimals 18"):
            compute(cfg, rpc, FEEDS)

    def test_sqrt_price_unit_parity(self):
        self.assertEqual(sqrt_price_x96(10**18, 10**18, 18, 18), 2**96)

    def test_dump_round_trips(self):
        cfg = config([("MSTR", MSTR), ("USDG", USDG)], [("MSTR", "USDG")])
        self.assertEqual(json.loads(dump_config(cfg)), cfg)


if __name__ == "__main__":
    unittest.main()
