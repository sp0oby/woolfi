import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "script"))

from launch_orchestrator import (  # noqa: E402
    DEFAULT_CONFIG,
    reconcile_manifest,
    run_dry,
    validate_config,
    verify_receipts,
)


class ReceiptRpc:
    def call(self, method, params):
        if method == "eth_chainId":
            return hex(4663)
        if method == "eth_getTransactionReceipt":
            return {"status": "0x1", "blockNumber": "0x7b"}
        if method == "eth_getCode":
            return "0x6000"
        raise AssertionError(method)


class LaunchOrchestratorTest(unittest.TestCase):
    def setUp(self):
        self.config = json.loads(DEFAULT_CONFIG.read_text(encoding="utf-8"))

    def test_committed_plan_is_disabled_and_complete(self):
        self.assertEqual(validate_config(self.config), [])
        self.assertFalse(self.config["broadcastEnabled"])
        self.assertFalse(self.config["launchEnabled"])

    def test_rejects_embedded_broadcast_flag(self):
        self.config["operations"][0]["argv"].append("--broadcast")
        self.assertTrue(any("broadcast flags" in error for error in validate_config(self.config)))

    def test_dry_run_resumes_matching_operation_digest(self):
        operation = self.config["operations"][0]
        operation["argv"] = [sys.executable, "-c", "pass"]
        self.config["operations"] = [operation]
        with tempfile.TemporaryDirectory() as directory:
            state = Path(directory) / "state.json"
            self.assertEqual(run_dry(self.config, state), 0)
            self.assertEqual(run_dry(self.config, state), 0)
            saved = json.loads(state.read_text(encoding="utf-8"))
            self.assertTrue(saved["completed"]["deploy-core"]["simulation"])

    def test_receipt_verification_and_manifest_reconciliation(self):
        tx_hash = "0x" + "a" * 64
        hook = "0x" + "1" * 40
        receipts = {
            "chainId": 4663,
            "receipts": [{
                "operationId": "deploy-core",
                "transactionHash": tx_hash,
                "blockNumber": 123,
                "contracts": {"hook": hook},
                "manifest": {"hook": hook},
            }],
        }
        self.assertEqual(verify_receipts(receipts, ReceiptRpc()), [])
        with tempfile.TemporaryDirectory() as directory:
            manifest_path = Path(directory) / "manifest.json"
            manifest_path.write_text(json.dumps({"chainId": 4663, "hook": "0x" + "0" * 40, "pools": []}))
            reconcile_manifest(receipts, manifest_path)
            manifest = json.loads(manifest_path.read_text())
            self.assertEqual(manifest["hook"], hook)
            self.assertEqual(manifest["startBlocks"]["hook"], 123)
            self.assertEqual(manifest["receipts"], [tx_hash])


if __name__ == "__main__":
    unittest.main()
