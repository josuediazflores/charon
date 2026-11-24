"""Exercise workspace creation, report publication and job settlement offline."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location(
    "job_runner", Path(__file__).resolve().parents[1] / "jarvis-job-runner.py"
)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class JobArchiveTests(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name) / "jarvis"
        self.jid = "2026-11-24-0630-abcd"
        self.files = self.root / "runs" / self.jid / "files"
        self.record = self.root / "jobs" / (self.jid + ".json")
        for name in ("jobs", ".jobs", ".jobstop"):
            (self.root / name).mkdir(parents=True)
        self.record.write_text(json.dumps({"id": self.jid, "text": "Find internships"}))
        self.spool = self.root / ".jobs" / self.jid
        self.spool.touch()
        paths = patch.multiple(runner, JARVIS_DIR=str(self.root), JOBS_DIR=str(self.record.parent),
                               QUEUE_DIR=str(self.spool.parent), STOP_DIR=str(self.root / ".jobstop"))
        paths.start()
        self.addCleanup(paths.stop)

    def test_job_writes_report_and_requested_deliverable(self):
        report = "# Internship search\n\n[Employer posting](https://example.org/roles/5)"

        def session(jid, doc, prompt, beat):
            self.assertEqual(jid, self.jid)
            self.assertIn(str(self.files), prompt)
            self.assertIn(doc["text"], prompt)
            (self.files / "shortlist.md").write_text("## Summer roles")
            state = runner.StreamState()
            state.feed(json.dumps({"type": "result", "subtype": "success", "result": report}))
            return state, False

        with patch.object(runner, "run_job", session):
            runner.run(self.jid)
        doc = json.loads(self.record.read_text())
        self.assertEqual((doc["status"], doc["result"]), ("done", report))
        self.assertEqual((self.files / "report.md").read_text(), report + "\n")
        self.assertEqual((self.files / "shortlist.md").read_text(), "## Summer roles")
        self.assertFalse(self.spool.exists())

    def test_unavailable_archive_fails_before_calling_model(self):
        (self.root / "runs").symlink_to(self.root / "jobs", target_is_directory=True)
        with patch.object(runner, "run_job") as session:
            runner.run(self.jid)
            session.assert_not_called()
        self.assertEqual(json.loads(self.record.read_text())["status"], "error")
        self.assertFalse(self.spool.exists())
        self.assertFalse((self.root / "jobs" / self.jid).exists())

    def test_report_write_failure_preserves_the_report_in_the_job(self):
        state = runner.StreamState()
        state.feed(json.dumps({"type": "result", "result": "Research findings"}))
        with patch.object(runner, "run_job", return_value=(state, False)), \
                patch.object(runner, "archive_report", side_effect=OSError("disk full")):
            runner.run(self.jid)
        doc = json.loads(self.record.read_text())
        self.assertEqual((doc["status"], doc["result"]), ("error", "Research findings"))
        self.assertIn("disk full", doc["error"])
        self.assertFalse(self.spool.exists())


if __name__ == "__main__":
    unittest.main()
