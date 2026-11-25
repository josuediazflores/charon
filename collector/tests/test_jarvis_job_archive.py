"""Exercise workspace creation, report publication and job settlement offline."""

import importlib.util
import json
import os
import sys
import textwrap
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
        paths = patch.multiple(runner, JOB_BACKEND="claude", JARVIS_DIR=str(self.root), JOBS_DIR=str(self.record.parent),
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

    def fake_codex(self, body):
        exe = self.root.parent / "fake-codex"
        exe.write_text(f"#!{sys.executable}\n" + textwrap.dedent(body))
        exe.chmod(0o700)
        return patch.multiple(runner, CODEX=str(exe), JOB_BACKEND="codex")

    def test_codex_uses_hosted_search_and_publishes_typed_files(self):
        with self.fake_codex("""
            import json, os, sys
            from pathlib import Path
            args = sys.argv[1:]
            assert "--search" in args and args[args.index("--ask-for-approval")+1] == "never"
            assert "shell_tool" in args and "--ignore-user-config" in args and "--ephemeral" in args
            assert 'permissions.jarvis.filesystem={":workspace_roots"="read"}' in args
            assert "permissions.jarvis.network.enabled=false" in args
            assert 'forced_login_method="chatgpt"' in args
            assert "OPENAI_API_KEY" not in os.environ and "SSH_AUTH_SOCK" not in os.environ
            assert Path.home() == Path.cwd() and "sonnet" not in args
            assert "Find internships" in sys.stdin.read()
            schema = json.loads(Path(args[args.index("--output-schema")+1]).read_text())
            assert schema["required"] == ["markdown", "files"]
            result = {"markdown": "[Role](https://example.org/job). [List](roles.csv)",
                      "files":[{"name":"roles.csv", "content":"role,link\\nSWE,https://example.org/job\\n"}]}
            Path(args[args.index("--output-last-message")+1]).write_text(json.dumps(result))
            print(json.dumps({"type":"item.completed","item":{"type":"web_search"}}))
            print(json.dumps({"type":"turn.completed","usage":{"output_tokens":44}}))
        """), patch.dict(os.environ, {"OPENAI_API_KEY": "fixture", "SSH_AUTH_SOCK": "fixture"}):
            runner.run(self.jid)
        doc = json.loads(self.record.read_text())
        self.assertEqual((doc["status"], doc["provider"], doc["web_searches"]), ("done", "codex", 1))
        self.assertEqual(doc["usage"], {"output_tokens": 44})
        self.assertEqual((self.files / "report.md").read_text().strip(), doc["result"])
        self.assertEqual((self.files / "roles.csv").read_text(), "role,link\nSWE,https://example.org/job\n")
        self.assertFalse(self.spool.exists())

    def test_scheduled_codex_recovers_published_report_after_interrupted_settlement(self):
        job = json.loads(self.record.read_text())
        job.update(parent_id="2026-11-23-1200-abcd", intake_key="batch-0",
                   run_at="2026-11-24T09:00:00Z")
        self.record.write_text(json.dumps(job))
        result = runner.CodexState()
        result.ok, result.result_text, result.web_searches = True, "Found five open roles.", 4
        result.files = [{"name": "Run steps.md", "content": "Requested deliverable"}]
        result.usage = {"output_tokens": 99}
        with patch.object(runner, "JOB_BACKEND", "codex"), \
             patch.object(runner, "run_codex", return_value=(result, False)) as model:
            with patch.object(runner, "settle", side_effect=InterruptedError("exit after publish")):
                with self.assertRaises(InterruptedError):
                    runner.run(self.jid)
            self.assertEqual(json.loads(self.record.read_text())["status"], "running")
            (self.root/".jobstop"/self.jid).touch()
            runner.run(self.jid)
            model.assert_called_once()
        doc = json.loads(self.record.read_text())
        self.assertEqual((doc["status"], doc["result"], doc["usage"], doc["web_searches"]),
                         ("done", result.result_text, result.usage, 4))
        self.assertFalse(self.spool.exists())
        self.assertFalse((self.root/".jobstop"/self.jid).exists())
        steps = (self.files/"Run steps 2.md").read_text()
        self.assertIn("4 completed web search calls", steps)
        self.assertIn("Run%20steps.md", steps)
        self.assertEqual((self.files/"Run steps.md").read_text(), "Requested deliverable")

    def test_codex_requires_a_terminal_event_and_zero_exit(self):
        for events, exit_code in (([], 0), ([{"type": "turn.completed"}], 1)):
            with self.subTest(events=events), self.fake_codex(f"""
                import json, sys
                from pathlib import Path
                Path(sys.argv[sys.argv.index("--output-last-message")+1]).write_text(
                    json.dumps({{"markdown":"premature report","files":[]}}))
                for event in {events}:
                    print(json.dumps(event))
                sys.exit({exit_code})
            """):
                runner.run(self.jid)
                doc = json.loads(self.record.read_text())
                self.assertEqual(doc["status"], "error")
                self.assertFalse((self.files / "report.md").exists())

    def test_codex_rejects_unsafe_or_invalid_files_before_publishing(self):
        for bad in ("../other.md", "REPORT.MD", "hidden.sh", "roles.csv"):
            with self.subTest(bad=bad), self.fake_codex(f"""
                import json, sys
                from pathlib import Path
                files = [{{"name":name,"content":"body"}} for name in ("roles.csv", {bad!r})]
                Path(sys.argv[sys.argv.index("--output-last-message")+1]).write_text(
                    json.dumps({{"markdown":"report","files":files}}))
                print(json.dumps({{"type":"turn.completed"}}))
            """):
                runner.run(self.jid)
                self.assertEqual(json.loads(self.record.read_text())["status"], "error")
                self.assertEqual(list(self.files.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
