"""Run the built Bridge against a local outbox and a fake Messages helper."""
import json
import os
import subprocess
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

from stub_collector import CONFIG, OUTBOX_ID, QUEUED

HERE = Path(__file__).resolve().parent
APP = HERE.parents[1] / "DerivedData/Build/Products/Debug/Charon Bridge.app/Contents/MacOS/Charon Bridge"


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def answer(self, status, obj):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = urlsplit(self.path).path
        if path.endswith("/config"):
            self.server.configs += 1
            self.answer(200, CONFIG)
        elif path.endswith("/outbox"):
            self.answer(200, {"items": [QUEUED] if self.server.offer else []})
        else:
            self.answer(200, {"items": []})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        if self.path.endswith("/outbox/" + OUTBOX_ID):
            self.server.reports.append(body)
            self.answer(self.server.report_status, {"ok": self.server.report_status == 200})
        elif self.path.endswith("/ingest"):
            self.answer(200, {"ok": True, "stored": len(body["events"]),
                              "duplicates": 0, "rejected": 0, "cursor_ack": body["cursor"]})
        else:
            self.answer(200, {"ok": True})

    def do_PUT(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        self.answer(200, {"ok": True})


class CourierTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.server.reports = []
        self.server.offer = True
        self.server.configs = 0
        self.server.report_status = 200
        self.addCleanup(self.server.server_close)
        thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(thread.join)
        self.addCleanup(self.server.shutdown)
        self.home = self.root / "home"
        self.home.mkdir()
        self.journal = self.home / "outbox-seen.json"

    def launch(self):
        before = self.server.configs
        result = subprocess.run([str(APP), "--dry-run", "--exit-after", "2"], env={
            **os.environ, "CHARON_BRIDGE_HOME": str(self.home),
            "CHARON_COLLECTOR_URL": "http://127.0.0.1:%d" % self.server.server_port,
            "CHARON_COLLECTOR_TOKEN": "fixture", "CHARON_IMSG_PATH": str(HERE / "fake-imsg.py"),
            "CHARON_FAKE_IMSG_FILES": str(self.root / "files"),
            "CHARON_FAKE_SEND_MARKER": str(self.root / "attempts"),
        }, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(self.server.configs, before, result.stderr)
        marker = self.root / "attempts"
        return len(marker.read_text().splitlines()) if marker.exists() else 0

    def test_unwritable_attempt_is_never_sent(self):
        self.journal.with_suffix(".json.lock").touch()
        self.home.chmod(0o500)
        self.addCleanup(self.home.chmod, 0o700)
        self.assertEqual(self.launch(), 0)

    def test_corrupt_journal_cannot_authorize_a_new_send(self):
        self.journal.write_text("{broken")
        self.assertEqual(self.launch(), 0)

    def test_legacy_seen_item_reports_uncertainty_without_sending(self):
        self.journal.write_text(json.dumps({"ids": [OUTBOX_ID]}))
        self.assertEqual(self.launch(), 0)
        self.assertTrue(self.server.reports)
        self.assertEqual(self.server.reports[0]["disposition"], "may_have_completed")
        self.assertIs(self.server.reports[0]["retry_safe"], False)

    def test_restart_replays_report_without_another_send_or_queue_entry(self):
        self.server.report_status = 503
        self.assertEqual(self.launch(), 1)
        self.assertTrue(self.server.reports)
        original = self.server.reports[0]
        self.assertEqual(original["status"], "sent")
        self.assertEqual(original["message_id"], "1979")
        self.server.reports.clear()
        self.server.offer = False
        self.server.report_status = 200
        self.assertEqual(self.launch(), 1)
        self.assertEqual(self.server.reports, [original])
        self.server.reports.clear()
        self.assertEqual(self.launch(), 1)
        self.assertEqual(self.server.reports, [])


if __name__ == "__main__":
    unittest.main()
