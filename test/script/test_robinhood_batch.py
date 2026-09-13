import copy
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))

from robinhood_batch import DEFAULT_CONFIG, validate  # noqa: E402
from robinhood_catalog import (  # noqa: E402
    ASSETS,
    CHAIN_ID,
    PAIRS,
    SLUGS,
    UNISWAP_V3_SWAP_ROUTER,
    URUFU_NFT,
    ZERO,
)


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
            ("hook", "positionManager", "governor", "swapRouter", "rebateDistributor", "liquidityZapper", "multisig",
             "treasury", "rebalancer", "treasuryFeeSink",
             "marketHours", "sequencerUptimeFeed"),
            start=1,
        ):
            core[field] = f"0x{index:040x}"
        core["urufuNft"] = URUFU_NFT
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
            "swapRouter": ZERO,
            "rebateDistributor": ZERO,
            "liquidityZapper": ZERO,
            "externalSwapExecutor": self.config["core"]["externalSwapExecutor"],
            "urufuNft": URUFU_NFT,
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

    def test_requires_canonical_uniswap_executor(self):
        self.assertEqual(
            self.config["core"]["externalSwapExecutor"].lower(),
            UNISWAP_V3_SWAP_ROUTER,
        )
        self.config["core"]["externalSwapExecutor"] = "0x0000000000000000000000000000000000001234"
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertIn(
            "core.externalSwapExecutor is not the canonical Uniswap v3 SwapRouter02",
            errors,
        )

    def test_weth_and_usdg_use_plain_chainlink_adapters(self):
        self.config["assets"]["WETH"]["oracleKind"] = "stock-pause-guarded"
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertIn("assets.WETH.oracleKind must be chainlink", errors)

    def test_example_drawdown_matches_create_pool_default(self):
        self.assertEqual(self.config["defaultRisk"]["drawdownBps"], 2000)

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
                "swapRouter": self.config["core"]["swapRouter"],
                "rebateDistributor": self.config["core"]["rebateDistributor"],
                "liquidityZapper": self.config["core"]["liquidityZapper"],
                "externalSwapExecutor": self.config["core"]["externalSwapExecutor"],
                "urufuNft": URUFU_NFT,
                "startBlocks": {
                    field: 123
                    for field in ("hook", "positionManager", "governor", "swapRouter", "rebateDistributor", "liquidityZapper")
                },
                "receipts": ["0x" + "a" * 64],
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
                "swapRouter": self.config["core"]["swapRouter"],
                "rebateDistributor": self.config["core"]["rebateDistributor"],
                "liquidityZapper": self.config["core"]["liquidityZapper"],
                "externalSwapExecutor": self.config["core"]["externalSwapExecutor"],
                "urufuNft": URUFU_NFT,
                "startBlocks": {
                    field: 123
                    for field in ("hook", "positionManager", "governor", "swapRouter", "rebateDistributor", "liquidityZapper")
                },
                "receipts": ["0x" + "a" * 64],
                "pools": [self._deployed(index, pair, slug) for index, (pair, slug) in enumerate(zip(PAIRS, SLUGS), 1)],
                "poolCount": 18,
            }
        )
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=True)
        self.assertIn("gates.auditComplete is not approved", errors)

    def test_rejects_missing_spread_skew(self):
        pool = next(pool for pool in self.config["pools"] if pool["slug"] == "aapl-msft")
        pool["safety"] = {"stabilizationSeconds": 900, "maxOracleSkew": 0}
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
            "startBlock": 123,
            "receipt": "0x" + f"{index:064x}",
        }


if __name__ == "__main__":
    unittest.main()
