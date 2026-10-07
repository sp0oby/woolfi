import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))

import robinhood_batch_deploy  # noqa: E402
from robinhood_batch import DEFAULT_CONFIG, validate  # noqa: E402
from robinhood_batch_deploy import pool_env, seed, seed_env  # noqa: E402
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
             "marketHours", "sequencerUptimeFeed", "poolAligner"),
            start=1,
        ):
            core[field] = f"0x{index:040x}"
        core["urufuNft"] = URUFU_NFT
        core["sequencerGracePeriod"] = 3600  # setUp binds a nonzero (fake) sequencer feed above
        core["totalTreasuryAllocationCap"] = 18_000
        self.config["nonAtomicTransactionsAcknowledged"] = True
        for index, asset in enumerate(self.config["assets"].values(), start=100):
            asset["oracle"] = f"0x{index:040x}"
            asset["feed"] = f"0x{index + 100:040x}"
            asset["heartbeat"] = 3600
        for field in self.config["gates"]:
            self.config["gates"][field] = True
        seed_set = set(self.config["seedSet"])
        for pool in self.config["pools"]:
            pool["sqrtPriceX96"] = 2**96
            pool["vaultAllocationCap"] = 1000
            if pool["slug"] in seed_set:
                pool["initialLiquidity"] = {"base": 1, "quote": 1, "slippageBps": 100}
            else:
                pool["initialLiquidity"] = {"base": 0, "quote": 0, "slippageBps": 0}
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
                "poolAligner": self.config["core"]["poolAligner"],
                "externalSwapExecutor": self.config["core"]["externalSwapExecutor"],
                "urufuNft": URUFU_NFT,
                "startBlocks": {
                    field: 123
                    for field in (
                        "hook", "positionManager", "governor", "swapRouter", "rebateDistributor", "liquidityZapper",
                        "poolAligner",
                    )
                },
                "receipts": ["0x" + "a" * 64],
                "pools": [self._deployed(index, pair, slug) for index, (pair, slug) in enumerate(zip(PAIRS, SLUGS), 1)],
                "poolCount": 18,
            }
        )
        self.assertEqual(validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=True), [])

    def test_readiness_requires_pool_aligner(self):
        self.config["core"]["poolAligner"] = ZERO
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=True)
        self.assertIn("core.poolAligner is not deployed", errors)
        self.assertNotIn(
            "core.poolAligner is not deployed",
            validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False),
        )

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

    def test_rejects_spread_skew_tighter_than_heartbeat(self):
        for symbol in ("AAPL", "MSFT"):
            self.config["assets"][symbol]["heartbeat"] = 86400
        pool = next(pool for pool in self.config["pools"] if pool["slug"] == "aapl-msft")
        pool["safety"] = {"stabilizationSeconds": 900, "maxOracleSkew": 120}
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertTrue(any("aapl-msft.safety.maxOracleSkew (120) must be >=" in error for error in errors))
        pool["safety"]["maxOracleSkew"] = 86400
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertFalse(any("aapl-msft.safety.maxOracleSkew" in error for error in errors))

    def test_pool_env_forwards_uru_cap(self):
        pool = self.config["pools"][0]
        ordered = sorted((pool["base"], pool["quote"]), key=lambda symbol: int(ASSETS[symbol], 16))
        env = pool_env(
            self.config["core"],
            self.config["assets"],
            pool,
            ordered,
            self.config["defaultRisk"],
            self.config["defaultSafety"],
        )
        self.assertEqual(env["URU_CAP"], str(pool["vaultAllocationCap"]))

    def test_seed_env_orders_base_and_quote_amounts(self):
        pool = next(item for item in self.config["pools"] if item["slug"] == "weth-usdg")
        pool["initialLiquidity"] = {"base": 11, "quote": 22, "slippageBps": 100, "minShares": 7}
        env = seed_env(self.config["core"], pool, self.config["defaultRisk"])
        token0, token1 = sorted((ASSETS["WETH"], ASSETS["USDG"]))
        self.assertEqual(env["TOKEN0"], token0)
        self.assertEqual(env["TOKEN1"], token1)
        if token0 == ASSETS["WETH"]:
            self.assertEqual(env["INITIAL_LIQUIDITY_0"], "11")
            self.assertEqual(env["INITIAL_LIQUIDITY_1"], "22")
        else:
            self.assertEqual(env["INITIAL_LIQUIDITY_0"], "22")
            self.assertEqual(env["INITIAL_LIQUIDITY_1"], "11")
        self.assertEqual(env["MIN_SHARES"], "7")

    def test_manifest_mismatch_fails_closed(self):
        self.manifest["poolManager"] = "0x0000000000000000000000000000000000009999"
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertIn("manifest poolManager conflicts with config", errors)

    def test_sequencer_feed_may_be_zero_with_zero_grace(self):
        core = self.config["core"]
        core["sequencerUptimeFeed"] = ZERO
        core["sequencerGracePeriod"] = 0
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertFalse(any("sequencer" in error.lower() for error in errors), errors)

    def test_zero_sequencer_feed_rejects_nonzero_grace(self):
        core = self.config["core"]
        core["sequencerUptimeFeed"] = ZERO
        core["sequencerGracePeriod"] = 3600
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertTrue(any("sequencerGracePeriod must be 0" in error for error in errors), errors)

    def test_nonzero_sequencer_feed_requires_code_and_grace(self):
        core = self.config["core"]
        core["sequencerGracePeriod"] = 0
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertTrue(any("sequencerGracePeriod must be positive" in error for error in errors), errors)

        class NoCodeRpc(CodeBearingRpc):
            def has_code(self, address):
                return address != core["sequencerUptimeFeed"].lower()

        core["sequencerGracePeriod"] = 3600
        errors = validate(self.config, self.manifest, NoCodeRpc(), require_deployed=False)
        self.assertIn("core.sequencerUptimeFeed has no contract code", errors)

    def test_seed_set_is_validated(self):
        for bad, message in (
            ([], "seedSet must be a non-empty list"),
            (None, "seedSet must be a non-empty list"),
            (["weth-usdg", "weth-usdg"], "seedSet contains duplicate slugs"),
            (["weth-usdg", "nvda-smh"], "seedSet contains unknown pools: nvda-smh"),
        ):
            self.config["seedSet"] = bad
            errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
            self.assertTrue(any(message in error for error in errors), (bad, errors))

    def test_only_seed_set_pools_require_seed_amounts(self):
        nvda = next(item for item in self.config["pools"] if item["slug"] == "nvda-usdg")
        nvda["initialLiquidity"] = {"base": 0, "quote": 0, "slippageBps": 0}
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertIn("nvda-usdg.initialLiquidity.base must be a positive integer", errors)

        nvda["initialLiquidity"] = {"base": 1, "quote": 1, "slippageBps": 100}
        mstr = next(item for item in self.config["pools"] if item["slug"] == "mstr-usdg")
        del mstr["initialLiquidity"]
        self.assertEqual(validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False), [])

        mstr["initialLiquidity"] = {"base": 5, "quote": 0, "slippageBps": 100}
        errors = validate(self.config, self.manifest, CodeBearingRpc(), require_deployed=False)
        self.assertIn("mstr-usdg.initialLiquidity.base is set but mstr-usdg is not in seedSet", errors)

    def test_seed_skips_pools_outside_seed_set(self):
        config, manifest = self._seed_fixture()
        config["seedSet"] = ["nvda-usdg"]
        with mock.patch.object(robinhood_batch_deploy.subprocess, "run") as run:
            self.assertEqual(seed(config, manifest, "http://rpc", True), 0)
            self.assertEqual(run.call_count, 0)
        self.assertEqual(manifest["seededPools"], [])

    def _seed_fixture(self):
        pool = next(item for item in self.config["pools"] if item["slug"] == "weth-usdg")
        manifest = {
            "chainId": CHAIN_ID,
            "pools": [{"slug": pool["slug"]}],
            "seededPools": [],
        }
        config = copy.deepcopy(self.config)
        config["pools"] = [pool]
        return config, manifest

    def test_seed_records_seeded_pools_on_broadcast_only(self):
        config, manifest = self._seed_fixture()
        slug = config["pools"][0]["slug"]
        forge_output = SimpleNamespace(
            returncode=0, stdout="##### robinhood\nHash: 0x" + "b" * 64 + "\n", stderr=""
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "robinhood.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")

            with mock.patch.object(robinhood_batch_deploy.subprocess, "run", return_value=forge_output) as run:
                self.assertEqual(seed(config, manifest, "http://rpc", False, manifest_path=path), 0)
                self.assertEqual(run.call_count, 1)
            self.assertEqual(manifest["seededPools"], [])
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["seededPools"], [])

            with mock.patch.object(robinhood_batch_deploy.subprocess, "run", return_value=forge_output) as run:
                self.assertEqual(seed(config, manifest, "http://rpc", True, manifest_path=path), 0)
                self.assertEqual(run.call_count, 1)
                self.assertIn("--broadcast", run.call_args.args[0])
            self.assertEqual(manifest["seededPools"], [{"slug": slug, "txHash": "0x" + "b" * 64}])
            self.assertIs(manifest["pools"][0]["seeded"], True)
            self.assertEqual(json.loads(path.read_text(encoding="utf-8"))["seededPools"], manifest["seededPools"])

            # Resumed broadcast must skip the recorded slug instead of double-seeding.
            with mock.patch.object(robinhood_batch_deploy.subprocess, "run", return_value=forge_output) as run:
                self.assertEqual(seed(config, manifest, "http://rpc", True, manifest_path=path), 0)
                self.assertEqual(run.call_count, 0)

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
