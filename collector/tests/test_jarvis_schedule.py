from datetime import datetime, timedelta, timezone
import json
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Event
import unittest
from unittest.mock import patch

import collector
import feature_control
from jarvis_schedule import promote_due


class ScheduledResearchTests(unittest.TestCase):
    def setUp(self):
        tmp = TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        for name in ("jobs", ".jobs", ".scheduled", ".jobstop"):
            (self.root / name).mkdir()
        self.jid = "2026-11-24-1800-0102"
        self.marker = self.root / ".scheduled" / (self.jid + ".json")
        self.job = self.root / "jobs" / (self.jid + ".json")
        self.queue = self.root / ".jobs" / self.jid
        self.start = datetime(2026, 11, 25, 9, 0, tzinfo=timezone.utc)
        stamp = self.start.strftime("%Y-%m-%dT%H:%M:%SZ")
        self.record = {"id": self.jid, "run_at": stamp, "status": "idle",
                       "parent_id": "2026-11-24-1800-cafe"}
        self.job.write_text(json.dumps(self.record))
        self.marker.write_text(json.dumps({"id": self.jid, "run_at": stamp}))

    def test_waits_until_the_chosen_instant_then_releases_once(self):
        promote_due(self.root, self.start - timedelta(seconds=1))
        self.assertFalse(self.queue.exists())
        self.assertTrue(self.marker.is_file())
        promote_due(self.root, self.start)
        self.assertEqual(json.loads(self.queue.read_text())["id"], self.jid)
        self.assertFalse(self.marker.exists())
        self.queue.unlink()  # Consumed by the existing job worker.
        promote_due(self.root, self.start + timedelta(seconds=10))
        self.assertFalse(self.queue.exists())

    def test_startup_releases_overdue_work_and_honors_feature_pause(self):
        service = collector.Collector.__new__(collector.Collector)
        service.sources = {}
        service.stop = Event()
        paused = self.root / "jarvis-paused.json"
        paused.write_text("[]")
        with patch.object(feature_control, "STATE", self.root), \
             patch.object(service, "jarvis_dir", return_value=str(self.root)), \
             patch.object(service, "save"), \
             patch.object(service.stop, "wait", side_effect=lambda _: service.stop.set()), \
             patch("jarvis_schedule.datetime", wraps=datetime) as clock:
            clock.now.return_value = self.start + timedelta(hours=2)
            service.run()
            self.assertFalse(self.queue.exists())
            paused.unlink()
            service.stop.clear()
            service.run()
        self.assertTrue(self.queue.is_file())
        self.assertFalse(self.marker.exists())

    def test_stopped_future_task_reaches_workers_existing_stop_check(self):
        stop = self.root / ".jobstop" / self.jid
        stop.touch()
        promote_due(self.root, self.start - timedelta(hours=3))
        self.assertTrue(stop.exists())
        self.assertTrue(self.queue.is_file())
        self.assertFalse(self.marker.exists())

    def test_stale_marker_cannot_restart_finished_work(self):
        self.record["status"] = "done"
        self.job.write_text(json.dumps(self.record))
        promote_due(self.root, self.start)
        self.assertFalse(self.queue.exists())
        self.assertFalse(self.marker.exists())
