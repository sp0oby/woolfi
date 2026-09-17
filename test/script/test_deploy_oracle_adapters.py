import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))

from deploy_oracle_adapters import DEFAULT_CONFIG, SCRIPTS, adapter_env, run_adapters  # noqa: E402
from robinhood_catalog import ASSETS, ZERO  # noqa: E402

ADAPTER = "0x00000000000000000000000000000000000000ab"


class RecordingRunner:
    """Stands in for subprocess.run: records every call, returns a parseable adapter line."""

    def __init__(self, returncode=0, stdout=f"Chain id 4663\nOracle adapter        {ADAPTER}\n"):
        self.calls = []
        self.returncode = returncode
        self.stdout = stdout

    def __call__(self, command, **kwargs):
        self.calls.append({"command": command, "env": kwargs.get("env", {})})
        return SimpleNamespace(returncode=self.returncode, stdout=self.stdout, stderr="")


class DeployOracleAdaptersTest(unittest.TestCase):
    def setUp(self):
        self.config = json.loads(DEFAULT_CONFIG.read_text(encoding="utf-8"))
        for index, asset in enumerate(self.config["assets"].values(), start=1):
            asset["feed"] = f"0x{index:040x}"
            asset["heartbeat"] = 86_400

    def test_skips_recorded_adapters_and_picks_script_per_kind(self):
        self.config["assets"]["MSTR"]["oracle"] = "0x0000000000000000000000000000000000000123"
        runner = RecordingRunner()
        code, deployed = run_adapters(self.config, "http://rpc", broadcast=False, runner=runner)
        self.assertEqual(code, 0)
        self.assertNotIn("MSTR", deployed)
        self.assertEqual(len(runner.calls), len(self.config["assets"]) - 1)
        by_symbol = dict(zip([s for s in self.config["assets"] if s != "MSTR"], runner.calls))
        self.assertIn(SCRIPTS["chainlink"], by_symbol["WETH"]["command"])
        self.assertIn(SCRIPTS["stock-pause-guarded"], by_symbol["NVDA"]["command"])
        self.assertEqual(by_symbol["NVDA"]["env"]["STOCK_TOKEN"], ASSETS["NVDA"])
        self.assertNotIn("STOCK_TOKEN", by_symbol["WETH"]["env"])
        self.assertNotIn("--broadcast", by_symbol["NVDA"]["command"])

    def test_dry_run_never_writes_config(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "batch.json"
            path.write_text(json.dumps(self.config), encoding="utf-8")
            before = path.read_text(encoding="utf-8")
            code, deployed = run_adapters(
                self.config, "http://rpc", broadcast=False, runner=RecordingRunner(), config_path=path
            )
            self.assertEqual(code, 0)
            self.assertEqual(deployed["WETH"], ADAPTER)
            self.assertEqual(self.config["assets"]["WETH"]["oracle"], ZERO)
            self.assertEqual(path.read_text(encoding="utf-8"), before)

    def test_broadcast_writes_adapter_back_and_persists(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "batch.json"
            path.write_text(json.dumps(self.config), encoding="utf-8")
            runner = RecordingRunner()
            code, deployed = run_adapters(
                self.config, "http://rpc", broadcast=True, runner=runner, config_path=path
            )
            self.assertEqual(code, 0)
            self.assertTrue(all("--broadcast" in call["command"] for call in runner.calls))
            self.assertEqual(self.config["assets"]["USDG"]["oracle"], ADAPTER)
            persisted = json.loads(path.read_text(encoding="utf-8"))
            self.assertEqual(persisted["assets"]["USDG"]["oracle"], ADAPTER)
            self.assertEqual(set(deployed), set(self.config["assets"]))

    def test_sequencer_env_follows_core_opt_out(self):
        core = self.config["core"]
        asset = self.config["assets"]["MSTR"]
        disabled = adapter_env(core, "MSTR", asset)
        self.assertIsNone(disabled["SEQUENCER_UPTIME_FEED"])
        self.assertIsNone(disabled["SEQUENCER_GRACE_PERIOD"])
        core["sequencerUptimeFeed"] = "0x0000000000000000000000000000000000000abc"
        core["sequencerGracePeriod"] = 3600
        enabled = adapter_env(core, "MSTR", asset)
        self.assertEqual(enabled["SEQUENCER_UPTIME_FEED"], core["sequencerUptimeFeed"])
        self.assertEqual(enabled["SEQUENCER_GRACE_PERIOD"], "3600")
        # Runner env must drop stale shell values when the opt-out applies.
        core["sequencerUptimeFeed"] = ZERO
        runner = RecordingRunner()
        import os

        os.environ["SEQUENCER_UPTIME_FEED"] = "0x0000000000000000000000000000000000000abc"
        try:
            run_adapters(self.config, "http://rpc", broadcast=False, runner=runner)
        finally:
            os.environ.pop("SEQUENCER_UPTIME_FEED", None)
        stock_call = next(c for c in runner.calls if SCRIPTS["stock-pause-guarded"] in c["command"])
        self.assertNotIn("SEQUENCER_UPTIME_FEED", stock_call["env"])

    def test_rejects_zero_feed_before_running(self):
        self.config["assets"]["COIN"]["feed"] = ZERO
        with self.assertRaises(ValueError):
            run_adapters(self.config, "http://rpc", broadcast=False, runner=RecordingRunner())

    def test_stops_on_first_failure(self):
        runner = RecordingRunner(returncode=1)
        code, deployed = run_adapters(self.config, "http://rpc", broadcast=True, runner=runner)
        self.assertEqual(code, 1)
        self.assertEqual(deployed, {})
        self.assertEqual(len(runner.calls), 1)

    def test_unparseable_output_fails_closed(self):
        runner = RecordingRunner(stdout="no address here\n")
        code, deployed = run_adapters(self.config, "http://rpc", broadcast=True, runner=runner)
        self.assertEqual(code, 1)
        self.assertEqual(deployed, {})


if __name__ == "__main__":
    unittest.main()
