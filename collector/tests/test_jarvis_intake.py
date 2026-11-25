"""One finite intake: wire request, isolated planning, durable dispatch and reads."""
import concurrent.futures
from contextlib import nullcontext
from datetime import datetime, timedelta, timezone
import http.client
from http.server import ThreadingHTTPServer
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import collector
import jarvis_intake
from jarvis_schedule import promote_due

spec = importlib.util.spec_from_file_location("intake_runner", Path(collector.__file__).with_name("jarvis-job-runner.py"))
worker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(worker)


class OvernightIntake(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.base = Path(tmp.name)
        self.root = self.base / "jarvis"
        cfg = collector.load_config(str(self.base / "unused"))
        cfg["chat"]["base_dir"] = tmp.name
        cfg["state_dir"] = str(self.base / "state")
        self.store = collector.Collector(cfg)
        self.token = "fixture"
        server = ThreadingHTTPServer(("127.0.0.1", 0), collector.make_handler(self.store, self.token))
        self.port = server.server_port
        threading.Thread(target=server.serve_forever, kwargs={"poll_interval": .01}, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        self.when = datetime.now(timezone.utc).replace(microsecond=0) + timedelta(days=1)
        self.body = {"request_id": str(uuid.uuid4()), "text": "Research internships and compare trains.",
                     "run_at": self.when.isoformat().replace("+00:00", "Z")}
        paths = patch.multiple(worker, JARVIS_DIR=str(self.root), JOBS_DIR=str(self.root/"jobs"),
                               QUEUE_DIR=str(self.root/".intake-jobs"), STOP_DIR=str(self.root/".jobstop"),
                               INTAKE_LANE=True)
        paths.start()
        self.addCleanup(paths.stop)

    def http(self, path="/v1/jarvis/intake", body=None, auth=True):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            headers = {"Authorization": "Bearer " + self.token} if auth else {}
            conn.request("GET" if body is None else "POST", path,
                         body=json.dumps(body).encode() if body is not None else None, headers=headers)
            res = conn.getresponse()
            raw = res.read()
            return res.status, json.loads(raw) if raw and res.headers.get_content_type() == "application/json" else None
        finally:
            conn.close()

    def test_replay_concurrent_conflicting_invalid_and_paused(self):
        self.assertEqual(self.http(body=self.body, auth=False)[0], 401)
        with patch("collector.admit", return_value=nullcontext(False)):
            self.assertEqual(self.http(body=self.body)[0], 409)
        for overrides in ({"text": "  "}, {"request_id": "../a"}, {"run_at": "yesterday"},
                          {"run_at": "2000-01-01T01:00:00Z"}, {"text": "x"*12001}):
            self.assertEqual(self.http(body={**self.body, **overrides})[0], 400)
        self.body["text"] = "🌕"*12000
        with concurrent.futures.ThreadPoolExecutor(4) as ex:
            replies = list(ex.map(lambda _: self.http(body=self.body), range(4)))
        self.assertTrue(all(r == replies[0] for r in replies))
        self.assertEqual(replies[0][0], 202)
        jid = replies[0][1]["id"]
        self.assertEqual(list((self.root/".intake-jobs").iterdir()), [self.root/".intake-jobs"/jid])
        self.assertEqual(self.http(body={**self.body, "text": "different"})[0], 409)
        self.assertEqual(self.http(body={**self.body, "run_at": "2000-01-01T01:00:00Z"})[0], 409)
        class Later(datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime(2100, 1, 1, tzinfo=timezone.utc)
        with patch("jarvis_intake.datetime", Later):
            self.assertEqual(self.http(body=self.body), replies[0])
        self.assertEqual(self.http("/v1/jarvis/runs/" + jid)[1]["status"], "queued")

    def test_receipt_repairs_interrupted_publication_without_respooling(self):
        real = jarvis_intake.atomic_json
        def interrupted(path, value, **kwargs):
            if value.get("placed"):
                raise OSError("interrupted after creating the queue marker")
            return real(path, value, **kwargs)

        with patch.object(jarvis_intake, "atomic_json", side_effect=interrupted):
            self.assertEqual(self.http(body=self.body)[0], 500)
        jid = next((self.root/".intake-jobs").iterdir()).name
        with self.fake({"tasks": [], "note": "Please supply a destination."}):
            worker.run(jid)
        self.assertEqual(self.http(body=self.body), (202, {"id": jid}))
        self.assertEqual(list((self.root/".intake-jobs").iterdir()), [])
        self.assertEqual((self.root/"jobs"/(jid+".json")).stat().st_nlink, 1)

    def test_id_collision_keeps_the_existing_job(self):
        class AtMinute(datetime):
            @classmethod
            def now(cls, tz=None):
                return datetime(2020, 1, 1, 12, 30, tzinfo=tz)
        old_id = "2020-01-01-1230-1111"
        jobs = self.root/"jobs"
        jobs.mkdir(parents=True)
        existing = jobs/(old_id+".json")
        existing.write_text(json.dumps({"id":old_id, "text":"existing job"}))
        with patch("jarvis_intake.datetime", AtMinute), patch("jarvis_intake.os.urandom",
                side_effect=[bytes.fromhex("1111"), bytes.fromhex("2222")]):
            created = self.http(body=self.body)
        self.assertEqual(created, (202, {"id":"2020-01-01-1230-2222"}))
        self.assertEqual(json.loads(existing.read_text())["text"], "existing job")
        with self.assertRaises(FileExistsError):
            jarvis_intake.atomic_json(existing, {"text":"collision"}, exclusive=True)
        self.assertEqual(existing.stat().st_nlink, 1)

    def fake(self, plan):
        path = self.base / "codex"
        path.write_text(f"#!{sys.executable}\n"+'''
import json, sys
from pathlib import Path
args = sys.argv
assert "--search" not in args and 'web_search="disabled"' in args
assert "--ephemeral" in args and "--ignore-user-config" in args
assert "Research internships" in sys.stdin.read()
schema = json.loads(Path(args[args.index("--output-schema")+1]).read_text())
assert schema["required"] == ["tasks", "note"]
if "context" in schema["properties"]["tasks"]["items"]["required"]:
    assert args[args.index("--model")+1] == "gpt-6-luna"
else:
    assert "--model" not in args
''' + f'Path(args[args.index("--output-last-message")+1]).write_text({json.dumps(plan)!r})\n'
                        + '''print('{"type":"turn.completed","usage":{"output_tokens":7}}')\n''')
        path.chmod(0o700)
        return patch.object(worker, "CODEX", str(path))

    def test_plans_while_research_busy_recovers_child_and_dispatches_on_time(self):
        _, reply = self.http(body=self.body)
        jid = reply["id"]
        (self.root/".jobs"/"2026-09-01-0900-aaaa").touch()
        plan = {"tasks":[{"title":"Internships","text":"Research Chicago openings and supply links."},
                         {"title":"Trains","text":"Compare the two commuter rail options."}], "note":""}
        real = jarvis_intake.file_once
        def interrupted(*args, **kwargs):
            child = real(*args, **kwargs)
            if args[2] == "Trains":
                raise InterruptedError("worker exited after placing marker")
            return child
        with self.fake(plan), patch.object(jarvis_intake, "file_once", side_effect=interrupted):
            with self.assertRaises(InterruptedError):
                worker.run(jid)
        with patch.object(worker, "run_codex", side_effect=AssertionError("replanned on restart")):
            worker.run(jid)
        _, parent = self.http("/v1/jarvis/runs/" + jid)
        self.assertEqual((parent["kind"], parent["status"], parent["run_at"]), ("intake","done",self.body["run_at"]))
        self.assertEqual([c["title"] for c in parent["children"]], ["Internships","Trains"])
        self.assertEqual(parent["files"][0]["path"], "report.md")
        for c in parent["children"]:
            self.assertEqual((c["parent_id"],c["status"]),(jid,"scheduled"))
        self.assertEqual(len(list((self.root/"jobs").glob("*.json"))),3)
        first, second = [c["id"] for c in parent["children"]]
        self.assertEqual(self.store.jarvis_job_stop(second)[0], True)
        self.assertEqual(self.http("/v1/jarvis/runs/" + second)[1]["status"], "stopped")
        promote_due(self.root, self.when-timedelta(hours=1))
        self.assertFalse((self.root/".jobs"/first).exists())
        self.assertTrue((self.root/".jobs"/second).exists())
        with patch.multiple(worker, INTAKE_LANE=False, QUEUE_DIR=str(self.root/".jobs")), \
                patch.object(worker, "run_codex", side_effect=AssertionError("canceled task ran")):
            worker.run(second)
        self.assertEqual(self.http("/v1/jarvis/runs/" + second)[1]["status"], "stopped")
        promote_due(self.root, self.when)
        self.assertEqual(self.http("/v1/jarvis/runs/"+first)[1]["status"], "queued")
        self.assertEqual(self.http(body=self.body), (202,reply))
        self.assertFalse((self.root/".intake-jobs"/jid).exists())

    def test_process_proposes_and_only_confirm_schedules_reviewed_markdown(self):
        process = "/v1/jarvis/intake/process"
        confirm = "/v1/jarvis/intake/confirm"
        dump = {"request_id": self.body["request_id"], "text": "    Research internships\n\n## Trains\n"}
        status, receipt = self.http(process, dump)
        self.assertEqual(status, 202)
        jid = receipt["id"]
        get = "/v1/jarvis/runs/" + jid
        plan = {"tasks": [{"title": "Roles", "goal": "Find internships", "context": "Chicago"},
                          {"title": "Trains", "goal": "Compare service", "context": ""}], "note": ""}
        kept = [{"title": "Summer roles", "goal": "List SWE internships", "context": "Chicago only"}]
        choice = {"id": jid, "tasks": kept, "run_at": self.body["run_at"]}
        self.assertEqual(self.http(confirm, choice)[0], 409)
        with self.fake(plan):
            worker.run(jid)
        self.assertEqual(self.http(process, dump), (202, receipt))
        draft = self.http(get)[1]
        self.assertEqual((draft["status"], draft["kind"], draft["proposal"], draft["children"]),
                         ("review", "brain_dump", plan["tasks"], []))
        self.assertEqual((self.root/"runs"/jid/"files"/"Brain Dump.md").read_text(), dump["text"])
        promote_due(self.root, self.when + timedelta(days=1))
        self.assertFalse((self.root/".scheduled").exists())
        self.assertEqual(self.http(confirm, {**choice, "tasks": []})[0], 400)
        self.assertEqual(self.http(confirm, choice, auth=False)[0], 401)
        with patch("collector.admit", return_value=nullcontext(False)):
            self.assertEqual(self.http(confirm, choice)[0], 409)
        real = jarvis_intake.file_once
        def interrupted(*args, **kwargs):
            real(*args, **kwargs)
            raise OSError("lost progress after scheduling")
        with patch.object(jarvis_intake, "file_once", side_effect=interrupted):
            self.assertEqual(self.http(confirm, choice)[0], 500)
        self.assertTrue(self.http(get)[1]["confirmation_started"])
        self.assertEqual(self.http(confirm, {**choice, "tasks": plan["tasks"]})[0], 409)
        with concurrent.futures.ThreadPoolExecutor(3) as pool:
            self.assertEqual(list(pool.map(lambda _: self.http(confirm, choice), range(3))), [(202, receipt)] * 3)
        done = self.http(get)[1]
        self.assertEqual(done["status"], "done")
        self.assertEqual([kid["title"] for kid in done["children"]], ["Summer roles"])
        child = self.http("/v1/jarvis/runs/" + done["children"][0]["id"])[1]
        self.assertEqual(child["request"], "List SWE internships\n\n## Context\n\nChicago only")
        self.assertEqual(child["status"], "scheduled")

    def test_empty_plan_explains_and_invalid_plan_has_no_children(self):
        for plan, state in (({"tasks": [], "note": "Which destinations should I compare?"}, "done"),
                            ({"tasks": [{"title":"Bad", "text":""}], "note":""}, "error")):
            self.body["request_id"] = str(uuid.uuid4())
            jid = self.http(body=self.body)[1]["id"]
            with self.fake(plan):
                worker.run(jid)
            _, detail = self.http("/v1/jarvis/runs/"+jid)
            self.assertEqual((detail["status"],detail["children"]), (state,[]))
            if state == "done":
                self.assertIn("Which destinations", detail["markdown"])
        self.assertFalse((self.root/".scheduled").exists())
