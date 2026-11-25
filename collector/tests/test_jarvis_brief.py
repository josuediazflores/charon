"""A Pi-local daily brief retains run, source and archive provenance."""
from contextlib import nullcontext
from datetime import datetime
import http.client
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import collector
import jarvis_runs as runs


class DailyBrief(unittest.TestCase):
    def setUp(self):
        tz = patch.dict(os.environ, {"TZ": "America/Los_Angeles"})
        tz.start()
        time.tzset()
        self.addCleanup(time.tzset)
        self.addCleanup(tz.stop)
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.root = self.base / "jarvis"
        self.jobs = self.root / "jobs"
        self.jobs.mkdir(parents=True)
        self.seq = 0
        self.day = "2026-11-24"
        self.now = datetime.fromisoformat("2026-11-24T11:00:00-08:00")
        self.token = "daily-brief-test"
        cfg = collector.load_config(str(self.base / "none"))
        cfg["chat"]["base_dir"] = str(self.base)
        cfg["state_dir"] = str(self.base / "state")
        store = collector.Collector(cfg)
        server = ThreadingHTTPServer(("127.0.0.1", 0), collector.make_handler(store, self.token))
        self.port = server.server_port
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)

    def add(self, **fields):
        self.seq += 1
        jid = f"2026-01-01-0000-{self.seq:04x}"
        doc = {"id": jid, "status": "done", "title": "Compare libraries",
               "result": "Two libraries open early.", "updated_at": self.now.isoformat(), **fields}
        (self.jobs / (jid + ".json")).write_text(json.dumps(doc))
        return jid

    def brief(self, now=None):
        return runs.daily_brief(self.root, lambda _: False, self.day, now=now or self.now)

    def get(self, date, auth=True):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        try:
            conn.request("GET", "/v1/jarvis/brief/" + date,
                         headers={"Authorization": "Bearer " + self.token} if auth else {})
            resp = conn.getresponse()
            return resp.status, json.loads(resp.read())
        finally:
            conn.close()

    def test_remote_read_keeps_the_archive_untouched(self):
        self.add()
        with patch.object(runs, "_store_brief", side_effect=AssertionError("wrote remote read")):
            conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
            try:
                conn.request("GET", "/v1/jarvis/brief/" + self.day,
                             headers={"Authorization": "Bearer " + self.token, "X-Charon-Read-Only": "1"})
                response = conn.getresponse()
                self.assertEqual(response.status, 200)
                self.assertTrue(json.loads(response.read())["markdown"])
            finally:
                conn.close()
        self.assertFalse((self.root/"daily").exists())

    def test_archive_bounds_and_results(self):
        self.add(updated_at="2026-11-23T17:59:59")
        evening = self.add(updated_at="2026-11-24T02:00:00Z", result="Archived lead")
        self.add(updated_at="2026-11-24T11:01:00-08:00")
        self.add(updated_at="2026-11-24T18:00:00-08:00")
        self.add(kind="intake", title="A brain dump")
        self.add(status="queued", parent_id=evening, run_at="2026-11-25T10:00:00Z")
        due = self.add(parent_id=evening, run_at="2026-11-24T09:00:00Z", status="running")
        stopped = self.add(result="Earlier output\n[stopped]")
        failed = self.add(status="error", error="Could not finish")
        files = self.root / "runs" / evening / "files"
        files.mkdir(parents=True)
        (files / "report.md").write_text("# Library comparison\n\nTwo libraries open before 7 a.m.\n\n[Hours](https://example.org/hours)")
        doc = self.brief()
        self.assertEqual(doc["date"], self.day)
        self.assertEqual({r["id"]: r["status"] for r in doc["runs"]},
                         {evening: "done", due: "running", stopped: "stopped", failed: "error"})
        self.assertIn("Two libraries open before 7 a.m.", doc["spoken"])
        self.assertNotIn("https://", doc["spoken"])
        self.assertIn(f"(/v1/jarvis/runs/{evening})", doc["markdown"])
        self.assertIn(f"(../runs/{evening}/files/report.md)", doc["markdown"])
        self.assertIn("https://example.org/hours", doc["markdown"])
        self.assertIn(doc["spoken"], doc["markdown"])
        archive = self.root / "daily" / (self.day + ".md")
        mtime = archive.stat().st_mtime_ns
        self.assertEqual(archive.read_text(), doc["markdown"])
        self.assertEqual(self.brief(), doc)
        self.assertEqual(archive.stat().st_mtime_ns, mtime)

    def test_late_completion_and_history_beyond_list_page(self):
        child = self.add(parent_id="2026-01-01-0000-ffaa", run_at="2026-11-24T09:00:00Z",
                         updated_at="2026-11-25T12:00:00Z")
        for _ in range(70):
            self.add(updated_at="2026-11-01T07:00:00-08:00")
        later = datetime.fromisoformat("2026-11-27T00:00:00Z")
        outcome = self.brief(later)["runs"]
        self.assertEqual([(r["id"], r["status"]) for r in outcome], [(child, "pending")])
        with patch.object(runs, "job_doc", wraps=runs.job_doc) as reads:
            self.brief(later)
            self.assertEqual(reads.call_count, 1)
        self.day = "2026-11-25"
        self.assertEqual(self.brief(later)["runs"][0]["status"], "done")

    def test_dst_empty_auth_and_validation(self):
        self.day = "2026-11-01"
        # The hour after clocks fell back is still the same delivery date.
        self.add(updated_at="2026-11-01T01:00:00Z")
        self.add(updated_at="2026-11-01T08:30:00Z")
        self.add(updated_at="2026-11-01T09:30:00Z")
        self.add(updated_at="2026-11-02T02:00:00Z")
        self.assertEqual(len(self.brief()["runs"]), 3)
        self.assertEqual(self.get("2026-11-01", False)[0], 401)
        with patch("collector.admit", return_value=nullcontext(False)):
            self.assertEqual(self.get("2026-11-01")[0], 409)
        for malformed in ("2026-02-30", "20260101", "2026-11-01/extra"):
            self.assertEqual(self.get(malformed)[0], 400)
        code, empty = self.get("2020-11-10")
        self.assertEqual((code, empty["runs"]), (200, []))
        self.assertIn("no overnight assignments", empty["spoken"])
        self.assertFalse((self.root/"daily"/"2020-11-10.md").exists())

    def test_external_files_are_never_read_or_written(self):
        jid = self.add(updated_at="2026-11-23T18:00:00")
        outside = self.base/"outside"
        outside.mkdir()
        (outside/"2026-11-24.md").write_text("untouched")
        (self.root/"daily").symlink_to(outside, target_is_directory=True)
        self.assertEqual(self.get(self.day)[0], 500)
        self.assertEqual((outside/"2026-11-24.md").read_text(), "untouched")
        (self.root/"daily").unlink()
        (self.jobs/"2026-01-01-0000-ffff.json").symlink_to(self.jobs/(jid+".json"))
        self.assertEqual(len(self.brief()["runs"]), 1)
