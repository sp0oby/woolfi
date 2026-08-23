import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))

from robinhood_batch import DEFAULT_CONFIG, validate  # noqa: E402
from robinhood_catalog import ASSETS, CHAIN_ID, PAIRS, SLUGS, ZERO  # noqa: E402


class CodeBearingRpc:
    def chain_id(self):
        return CHAIN_ID

    def has_code(self, _address):
        return True


class RobinhoodBatchTest(unittest.TestCase):
    def setUp(self):
        self.config = json.loads(DEFAULT_CONFIG.read_text(encoding="utf-8"))
        core = self.config["core"]
        for index, field in enumerate(
            ("hook", "positionManager", "governor", "multisig", "treasury", "rebalancer", "buybackSink",
             "marketHours", "sequencerUptimeFeed"),
            start=1,
        ):
            core[field] = f"0x{index:040x}"
        core["totalTreasuryAllocationCap"] = 18_000
        self.config["nonAtomicTransactionsAcknowledged"] = True
        for index, asset in enumerate(self.config["assets"].values(), start=100):
            asset["oracle"] = f"0x{index:040x}"
            asset["feed"] = f"0x{index + 100:040x}"
            asset["heartbeat"] = 3600
        for field in self.config["gates"]:
            self.config["gates"][field] = True
        for pool in self.config["pools"]:
            pool["sqrtPriceX96"] = 2**96
            pool["vaultAllocationCap"] = 1000
            pool["initialLiquidity"] = {"base": 1, "quote": 1, "slippageBps": 100}
        self.manifest = {
            "chainId": CHAIN_ID,
            "poolManager": ZERO,
            "stakingToken": ZERO,
            "hook": ZERO,
            "positionManager": ZERO,
            "governor": ZERO,
            "poolCount": 0,
            "pools": [],
        }

    def test_preflight_accepts_exact_pending_catalog(self):
        self.assertEqual(validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False), [])

    def test_rejects_duplicate_or_reversed_pair(self):
        self.config["pools"][1]["base"] = "USDG"
        self.config["pools"][1]["quote"] = "MSTR"
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertTrue(any("duplicate or reversed" in error for error in errors))

    def test_rejects_noncanonical_token(self):
        self.config["assets"]["MSTR"]["token"] = "0x0000000000000000000000000000000000001234"
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertIn("assets.MSTR.token is not canonical", errors)

    def test_readiness_requires_all_eighteen_manifest_entries(self):
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=True)
        self.assertIn("deployment incomplete: 0/18 canonical pools complete", errors)
        self.manifest.update(
            {
                "poolManager": self.config["core"]["poolManager"],
                "stakingToken": self.config["core"]["stakingToken"],
                "hook": self.config["core"]["hook"],
                "positionManager": self.config["core"]["positionManager"],
                "governor": self.config["core"]["governor"],
                "pools": [self._deployed(index, pair, slug) for index, (pair, slug) in enumerate(zip(PAIRS, SLUGS), 1)],
                "poolCount": 18,
            }
        )
        self.assertEqual(validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=True), [])

    def test_readiness_requires_approved_gates(self):
        self.config["gates"]["auditComplete"] = False
        self.manifest.update(
            {
                "poolManager": self.config["core"]["poolManager"],
                "stakingToken": self.config["core"]["stakingToken"],
                "hook": self.config["core"]["hook"],
                "positionManager": self.config["core"]["positionManager"],
                "governor": self.config["core"]["governor"],
                "pools": [self._deployed(index, pair, slug) for index, (pair, slug) in enumerate(zip(PAIRS, SLUGS), 1)],
                "poolCount": 18,
            }
        )
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=True)
        self.assertIn("gates.auditComplete is not approved", errors)

    def test_rejects_missing_spread_skew(self):
        self.config["pools"][11]["safety"] = {"stabilizationSeconds": 900, "maxOracleSkew": 0}
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertTrue(any("aapl-msft.safety.maxOracleSkew must be positive" in error for error in errors))

    def test_manifest_mismatch_fails_closed(self):
        self.manifest["poolManager"] = "0x0000000000000000000000000000000000009999"
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertIn("manifest poolManager conflicts with config", errors)

    def _deployed(self, index, pair, slug):
        token0, token1 = sorted((ASSETS[pair[0]], ASSETS[pair[1]]))
        return {
            "slug": slug,
            "poolId": f"0x{index:064x}",
            "token0": token0,
            "token1": token1,
            "oracle0": f"0x{index + 300:040x}",
            "oracle1": f"0x{index + 400:040x}",
            "marketHours": ZERO if slug == "weth-usdg" else self.config["core"]["marketHours"],
            "vault": f"0x{index + 500:040x}",
        }


if __name__ == "__main__":
    unittest.main()
