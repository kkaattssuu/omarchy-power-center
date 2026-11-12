"""Controller regressions with isolated state and mocked desktop commands."""
import importlib.machinery
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

loader = importlib.machinery.SourceFileLoader(
    "eco_ctl", str(Path(__file__).resolve().parents[1] / "bin/eco-ctl"))
spec = importlib.util.spec_from_loader(loader.name, loader)
ctl = importlib.util.module_from_spec(spec)
loader.exec_module(ctl)


class ControllerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        state = Path(self.directory.name)
        for name, value in {"STATE_DIR": state, "CONFIG_FILE": state / "config.json",
                            "SNAPSHOT_FILE": state / "snapshot.json"}.items():
            mock = patch.object(ctl, name, value)
            mock.start()
            self.addCleanup(mock.stop)

    def test_restores_previous_profile_after_eco(self):
        for profile in ("performance", "balanced", "power-saver"):
            with self.subTest(profile=profile), \
                    patch.object(ctl, "run", return_value=profile) as run, \
                    patch.object(ctl, "get_glass_state", return_value={}), \
                    patch.object(ctl, "hypr_get", return_value={"bool": False}), \
                    patch.object(ctl, "hypr_eval"), \
                    patch.object(ctl, "get_brightness_raw", return_value=50), \
                    patch.object(ctl, "get_brightness_max", return_value=100), \
                    patch.object(ctl, "set_brightness_pct"), \
                    patch.object(ctl, "restore_glass_state"), \
                    patch.object(ctl, "notify"), patch.object(ctl, "cmd_get"):
                config = dict(ctl.DEFAULT_CONFIG)
                ctl._eco_on(config)
                self.assertEqual(ctl.load_snapshot()["powerProfile"], profile)
                ctl._eco_off(config)
                self.assertEqual(run.call_args.args[0], ["powerprofilesctl", "set", profile])
                self.assertFalse(ctl.load_config()["active"])

    def test_failed_atomic_write_preserves_previous_settings(self):
        ctl.save_config({"active": True})
        with patch.object(ctl.os, "replace", side_effect=OSError("write failed")):
            with self.assertRaises(OSError):
                ctl.save_config({"active": False})
        self.assertEqual(json.loads(ctl.CONFIG_FILE.read_text()), {"active": True})
        self.assertEqual(list(ctl.STATE_DIR.iterdir()), [ctl.CONFIG_FILE])

    def test_idle_poll_does_not_collect_unused_telemetry(self):
        with patch.object(ctl, "run"), patch.object(ctl, "cmd_get") as get, \
                patch.object(ctl, "is_ac_online", return_value=True):
            ctl.cmd_poll()
            ctl.save_config({"auto_switch_battery": True, "_last_ac": True})
            ctl.cmd_poll()
            get.assert_not_called()

    def test_ac_transitions_still_toggle_eco(self):
        ctl.save_config({"auto_switch_battery": True, "_last_ac": True, "active": False})
        with patch.object(ctl, "run"), patch.object(ctl, "is_ac_online", return_value=False), \
                patch.object(ctl, "_eco_on") as enable:
            ctl.cmd_poll()
            enable.assert_called_once()
        ctl.save_config({"auto_switch_battery": True, "_last_ac": False, "active": True})
        with patch.object(ctl, "run"), patch.object(ctl, "is_ac_online", return_value=True), \
                patch.object(ctl, "_eco_off") as disable:
            ctl.cmd_poll()
            disable.assert_called_once()

    def test_holding_battery_status_fallback(self):
        supply = Path(self.directory.name) / "supplies"
        battery = supply / "BAT0"
        battery.mkdir(parents=True)
        for key, value in {"present": "1", "status": "Not charging", "energy_now": "34000000", "energy_full": "36000000", "power_now": "0"}.items():
            (battery / key).write_text(value)
        with patch.object(ctl, "POWER_SUPPLY", supply), patch.object(ctl, "run", return_value="percentage\t95%\nstate\tholding\ntime\t"):
            telemetry = ctl.compute_battery_telemetry()
            self.assertEqual(telemetry["rate_watts"], 0)
            self.assertEqual(telemetry["time"], "")


if __name__ == "__main__":
    unittest.main()
