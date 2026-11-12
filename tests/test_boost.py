import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader("boost", str(Path(__file__).resolve().parents[1] / "bin/cpu-boost"))
spec = importlib.util.spec_from_loader(loader.name, loader)
boost = importlib.util.module_from_spec(spec)
loader.exec_module(boost)


class BoostTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.state = Path(temp.name) / "state.json"
        self.state.write_text(json.dumps({"slow": 23000, "fast": 25000}))
        p = patch.object(boost, "STATE", self.state)
        p.start()
        self.addCleanup(p.stop)
        p = patch.object(boost, "performance_degraded", return_value="")
        p.start()
        self.addCleanup(p.stop)

    def test_profile_switch_preserves_new_profile_limits(self):
        with patch.object(boost, "profile", return_value="balanced"), patch.object(boost, "read_limits", return_value=(15000, 20000)), patch.object(boost, "apply") as apply:
            boost.restore_limits()
            apply.assert_not_called()
            self.assertFalse(self.state.exists())

    def test_failed_restore_keeps_snapshot(self):
        with patch.object(boost, "profile", return_value="performance"), patch.object(boost, "read_limits", return_value=(30000, 32000)), patch.object(boost, "apply", return_value=(False, "failed")):
            with self.assertRaises(RuntimeError):
                boost.restore_limits()
            self.assertTrue(self.state.exists())

    def test_both_limits_must_match(self):
        self.state.unlink()
        with patch.object(boost, "on_ac", return_value=True), patch.object(boost, "available", return_value=True), patch.object(boost, "profile", return_value="performance"), patch.object(boost, "read_limits", side_effect=[(23000, 25000), (30000, 25000)]), patch.object(boost, "apply", return_value=(True, "")), patch.object(boost, "restore_limits") as restore, patch.object(boost, "status"):
            self.assertEqual(boost.cmd_on(), 1)
            restore.assert_called_once()

    def test_battery_cannot_enable(self):
        with patch.object(boost, "on_ac", return_value=False), patch.object(boost, "status"), patch.object(boost, "apply") as apply:
            self.assertEqual(boost.cmd_on(), 1)
            apply.assert_not_called()

    def test_ai_boost_requests_limits_and_saves_level(self):
        self.state.unlink()
        with patch.object(boost, "on_ac", return_value=True), patch.object(boost, "available", return_value=True), patch.object(boost, "profile", return_value="performance"), patch.object(boost, "read_limits", side_effect=[(23000, 25000), (40000, 42000)]), patch.object(boost, "status", return_value=0), patch.object(boost, "apply", return_value=(True, "")) as apply:
            self.assertEqual(boost.cmd_on("ai"), 0)
            apply.assert_called_once_with(40000, 42000)
            self.assertEqual(json.loads(self.state.read_text()), {"slow": 23000, "fast": 25000, "level": "ai"})

    def test_ai_boost_restores_original_limits(self):
        self.state.write_text(json.dumps({"slow": 23000, "fast": 25000, "level": "ai"}))
        with patch.object(boost, "profile", return_value="performance"), patch.object(boost, "read_limits", side_effect=[(40000, 42000), (23000, 25000)]), patch.object(boost, "apply", return_value=(True, "")) as apply:
            self.assertTrue(boost.restore_limits())
            apply.assert_called_once_with(23000, 25000)

    def test_lap_restore_does_not_raise_firmware_limits(self):
        with patch.object(boost, "performance_degraded", return_value="lap-detected"), patch.object(boost, "profile", return_value="performance"), patch.object(boost, "read_limits", return_value=(11000, 11000)), patch.object(boost, "apply", return_value=(True, "")) as apply:
            self.assertTrue(boost.restore_limits())
            apply.assert_called_once_with(11000, 11000)
            self.assertFalse(self.state.exists())

    def test_lap_detection_does_not_block_boost(self):
        self.state.unlink()
        with patch.object(boost, "on_ac", return_value=True), patch.object(boost, "available", return_value=True), patch.object(boost, "profile", return_value="performance"), patch.object(boost, "performance_degraded", return_value="lap-detected"), patch.object(boost, "read_limits", side_effect=[(11000, 11000), (30000, 32000)]), patch.object(boost, "status", return_value=0), patch.object(boost, "apply", return_value=(True, "")) as apply:
            self.assertEqual(boost.cmd_on(), 0)
            apply.assert_called_once_with(30000, 32000)
