"""End-to-end, read-only overnight run navigation using an isolated job store."""

import http.client
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import collector as C
import jarvis_runs as runs


class RunRoutes(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.root = base / "jarvis"
        self.jobs = self.root / "jobs"
        self.jobs.mkdir(parents=True)
        cfg = C.load_config(str(base / "missing.json"))
        cfg["chat"]["base_dir"] = str(base)
        cfg["state_dir"] = str(base / "state")
        store = C.Collector(cfg)
        self.token = "run-route-test"
        server = ThreadingHTTPServer(("127.0.0.1", 0), C.make_handler(store, self.token))
        self.port = server.server_port
        thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01}, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.jid = "2026-11-24-0618-0001"
        self.result = ("A" * 5020 + "\n[Posting](https://example.org/roles/(mobile)) and "
                       "[draft](items/draft.docx). Also <https://example.org/roles/(mobile)>.")
        self.save(self.jid)
        self.files = self.root / "runs" / self.jid / "files"

    def save(self, jid, **fields):
        record = {"id": jid, "title": "Internship search", "text": "Find roles", "status": "done",
                  "result": self.result, "created_at": "2026-11-24T06:18:00Z"}
        (self.jobs / (jid + ".json")).write_text(json.dumps({**record, **fields}))

    def get(self, path="", auth=True):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=4)
        try:
            conn.request("GET", "/v1/jarvis/runs" + path,
                         headers={"Authorization": "Bearer " + self.token} if auth else {})
            resp = conn.getresponse()
            data = resp.read()
            if resp.getheader("Content-Type") == "application/json" and not resp.getheader("Content-Disposition"):
                data = json.loads(data)
            return resp.status, data
        finally:
            conn.close()

    def test_list_and_full_result_do_not_modify_legacy_job(self):
        before = (self.jobs / (self.jid + ".json")).read_bytes()
        code, page = self.get()
        self.assertEqual(code, 200)
        self.assertEqual([r["id"] for r in page["runs"]], [self.jid])
        self.assertNotIn("result", page["runs"][0])
        code, run = self.get("/" + self.jid)
        self.assertEqual(code, 200)
        self.assertEqual(run["markdown"], self.result)
        self.assertEqual(run["request"], "Find roles")
        self.assertEqual(run["sources"], [{"label": "Posting", "url": "https://example.org/roles/(mobile)"}])
        self.assertEqual(run["files"], [])
        self.assertEqual((self.jobs / (self.jid + ".json")).read_bytes(), before)
        self.assertEqual(list(self.root.iterdir()), [self.jobs])

    def test_pagination_queued_state_and_missing_records(self):
        second = "2026-11-23-0618-0002"
        third = "2026-11-22-0618-0003"
        self.save(second, status="idle")
        self.save(third, status="error", error="worker stopped", result="")
        (self.root / ".jobs").mkdir()
        (self.root / ".jobs" / second).touch()
        with patch.object(C, "JARVIS_JOBS_MAX", 2):
            page = self.get()[1]
            self.assertEqual([row["id"] for row in page["runs"]], [self.jid, second])
            self.assertEqual(page["runs"][1]["status"], "queued")
            page = self.get("?before=" + page["next_cursor"])[1]
            self.assertEqual([row["id"] for row in page["runs"]], [third])
            self.assertIsNone(page["next_cursor"])
        self.assertEqual(self.get("/" + third)[1]["error"], "worker stopped")
        self.assertEqual(self.get("?before=bad")[0], 400)
        self.assertEqual(self.get("/2026-11-24-0618-ffff")[0], 404)

    def test_scoped_regular_file_served_verbatim(self):
        (self.files / "items").mkdir(parents=True)
        file = self.files / "items/draft.docx"
        file.write_bytes(b"document bytes")
        (self.files / "summary.md").write_text("# Morning\n")
        hidden = self.root / "private.md"
        hidden.write_text("outside run")
        (self.files / "link.md").symlink_to(hidden)
        (self.files / "outside").symlink_to(self.root, target_is_directory=True)
        os.link(hidden, self.files / "alias.md")
        (self.files / ".hidden.md").write_text("hidden")
        doc = self.get("/" + self.jid)[1]
        self.assertEqual([f["path"] for f in doc["files"]], ["items/draft.docx", "summary.md"])
        path = "/" + self.jid + "/files/" + doc["files"][0]["id"]
        self.assertEqual(self.get(path), (200, b"document bytes"))
        for route in ("", "/" + self.jid, path):
            self.assertEqual(self.get(route, auth=False)[0], 401)
        self.assertEqual(self.get("/" + self.jid + "/files/%2e%2e/private.md")[0], 404)
        file.unlink()
        file.symlink_to(hidden)
        self.assertEqual(self.get(path)[0], 404)

    def test_rejects_invalid_authorities_and_keeps_plain_web_sources(self):
        text = "Direct https://example.org/a. [no](file:///tmp/no) https://user:pw@secret.test/a https://[bad"
        self.assertEqual(runs.sources(text), [{"label": "https://example.org/a", "url": "https://example.org/a"}])

    def test_completed_report_and_sources_use_the_archive(self):
        self.files.mkdir(parents=True)
        report = self.files / "report.md"
        full = "Summary\n\n[Full posting](https://example.org/late-source)\n"
        report.write_text(full)
        self.save(self.jid, result="Summary\n\n[output truncated]")
        detail = self.get("/" + self.jid)[1]
        self.assertEqual(detail["markdown"], full)
        self.assertEqual(detail["sources"], [{"label": "Full posting", "url": "https://example.org/late-source"}])
        file_path = "/" + self.jid + "/files/" + detail["files"][0]["id"]
        with patch.object(runs, "INLINE_REPORT_BYTES", 16):
            self.assertEqual(self.get("/" + self.jid)[1]["markdown"], "Summary\n\n[output truncated]")
            self.assertEqual(self.get(file_path), (200, full.encode()))
        for state, result in (("active", "Running"), ("error", "Partial"), ("done", "Partial\n\n[stopped]")):
            self.save(self.jid, status=state, result=result)
            self.assertEqual(self.get("/" + self.jid)[1]["markdown"], result)

    def test_unreadable_or_external_report_uses_job_result(self):
        self.files.mkdir(parents=True)
        report = self.files / "report.md"
        report.write_bytes(b"\xff")
        self.assertEqual(self.get("/" + self.jid)[1]["markdown"], self.result)
        report.unlink()
        outside = self.root / "outside.md"
        outside.write_text("External content")
        report.symlink_to(outside)
        self.assertEqual(self.get("/" + self.jid)[1]["markdown"], self.result)
        report.unlink()
        os.link(outside, report)
        self.assertEqual(self.get("/" + self.jid)[1]["markdown"], self.result)
