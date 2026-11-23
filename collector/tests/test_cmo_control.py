import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from cmo_control import CmoControl, GUARD_NAME, pairs_from


class RoutineTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.manifest = self.root / "units.json"
        self.manifest.write_text(json.dumps([["daily.timer", "daily.service"], ["ask.path", "ask.service"]]))
        self.active = {"daily.timer", "daily.service", "ask.service", "mail.timer"}
        self.simulate_failure = False
        self.calls = []
        self.control = CmoControl(self.manifest, self.root, self.run_systemctl)

    def run_systemctl(self, verb, *args):
        if verb == "show":
            unit = args[-1]
            if args[1] == "DropInPaths":
                return f"/etc/systemd/system/{unit}.d/{GUARD_NAME}"
            return "active" if unit in self.active else "inactive"
        self.calls.append((verb, args))
        if self.simulate_failure:
            raise OSError("permission denied")
        if verb == "stop":
            self.assertTrue(self.control.paused.exists())
            self.active.difference_update(args)
        elif verb == "start":
            self.assertFalse(self.control.paused.exists())
            self.active.update(args)
        else:
            self.fail(f"Unexpected verb {verb}")

    def test_pause_and_resume_across_restart(self):
        self.assertTrue(self.control.apply()["enabled"])
        self.assertEqual(self.calls, [])
        self.assertFalse(self.control.apply(False)["enabled"])
        self.assertEqual(self.active, {"mail.timer"})
        reopened = CmoControl(self.manifest, self.root, self.run_systemctl)
        self.assertFalse(reopened.apply()["enabled"])
        reopened.apply(False)
        self.assertTrue(reopened.apply(True)["enabled"])
        self.assertEqual(self.active, {"daily.timer", "mail.timer"})
        count = len(self.calls)
        reopened.apply(True)
        self.assertEqual(len(self.calls), count)

    def test_partial_changes_are_not_reported_as_finished(self):
        self.simulate_failure = True
        with self.assertRaises(OSError):
            self.control.apply(False)
        self.assertEqual(self.control.apply(), {"enabled": None, "retryEnabled": False})
        self.simulate_failure = False
        self.control.apply(False)
        self.simulate_failure = True
        with self.assertRaises(OSError):
            self.control.apply(True)
        self.assertEqual(self.control.apply(), {"enabled": None, "retryEnabled": True})
        self.simulate_failure = False
        self.control.apply(True)
        self.assertEqual(self.active, {"daily.timer", "mail.timer"})

    def test_missing_registration_and_guards_fail_closed(self):
        self.manifest.unlink()
        with self.assertRaises(RuntimeError):
            self.control.apply(False)
        self.manifest.write_text('[["daily.timer", "daily.service"]]')
        self.control.run = lambda *args: ""
        with self.assertRaises(RuntimeError):
            self.control.apply(False)
        self.assertFalse(self.control.paused.exists())
        self.assertEqual(self.calls, [])

    def test_explicit_registration_with_no_jobs(self):
        self.manifest.write_text("[]")
        self.assertFalse(self.control.apply(False)["enabled"])
        self.assertTrue(self.control.apply(True)["enabled"])
        self.assertEqual(self.calls, [])

    def test_invalid_registration(self):
        for invalid in [[["-bad.timer", "daily.service"]], [["daily.timer", "bad/path.service"]], [["daily.service", "daily.timer"]]]:
            with self.assertRaises(ValueError):
                pairs_from(invalid)


if __name__ == "__main__":
    unittest.main()
