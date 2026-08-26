#!/usr/bin/env python3
"""End-to-end wiring test. No model, no network beyond loopback, no cost.

Stands up a stdlib HTTP server that speaks the openai-compat shape and answers
with canned, correctly fenced output, then runs the REAL triage worker against
it over a throwaway mailbox. What that proves, which nothing else here does:

    the worker unpacks llm.run_session's three-tuple correctly
    the resolved model id actually reaches the ai record on disk
    the openai-compat backend works against a real socket, not a stub function
    MSG_BLOCK extraction, clean_tags, clean_urgency and clean_summary all still
      run on the way in
    a model that answers about a message it was not shown gets ignored
    a model that emits a tag outside the allowlist gets it dropped

It is deliberately a LIAR of a server: it returns one block for a message that
was never in the batch, and one out-of-allowlist tag, because the point is to
check the validation, not the happy path.

    python3 test-wiring.py
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = os.path.dirname(os.path.abspath(__file__))
KEYS = ["00a1b2c3d4e5f601", "00a1b2c3d4e5f602"]
GHOST = "00a1b2c3d4e5f6ff"          # never in the batch
MODEL = "stub-model-v1"

ok = fail = 0
seen_requests = []


def check(passed, label, detail=""):
    global ok, fail
    if passed:
        ok += 1
        print(f"  ok    {label}")
    else:
        fail += 1
        print(f"  FAIL  {label}" + (f": {detail}" if detail else ""))


def canned():
    blocks = []
    for i, key in enumerate(KEYS):
        blocks.append(
            f"<<<MSG {key}>>>\n" + json.dumps({
                "tags": ["lead", "definitely-not-allowed"],
                "urgency": 9 if i == 0 else 1,          # out of range on purpose
                "summary": ["first line", "second line"],
            }) + f"\n<<<END {key}>>>")
    # A verdict for a message this batch never contained.
    blocks.append(f"<<<MSG {GHOST}>>>\n" + json.dumps(
        {"tags": ["investor"], "urgency": 3, "summary": ["ghost"]}
    ) + f"\n<<<END {GHOST}>>>")
    return "here you go\n\n" + "\n\n".join(blocks) + "\n\ntrailing chatter"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("content-length", 0)))
        seen_requests.append({
            "path": self.path,
            "auth": self.headers.get("authorization"),
            "payload": json.loads(body),
        })
        out = json.dumps({"choices": [
            {"finish_reason": "stop", "message": {"content": canned()}}]}).encode()
        self.send_response(200)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    def log_message(self, *a):
        pass


def main():
    global ok, fail
    srv = HTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()

    base = tempfile.mkdtemp(prefix="charon-wiring-")
    try:
        mail = os.path.join(base, "mail")
        for sub in ("index", "bodies", "ai", "drafts", "outbox", ".queue", ".actions"):
            os.makedirs(os.path.join(mail, sub), exist_ok=True)
        shutil.copytree(os.path.join(REPO, "mail-env"),
                        os.path.join(base, "mail-env"), dirs_exist_ok=True)
        for key in KEYS:
            with open(os.path.join(mail, "index", f"{key}.json"), "w") as fh:
                json.dump({"key": key, "uid": 1, "from_name": "T",
                           "from_addr": "t@example.com", "subject": "s",
                           "date": "2026-08-18T09:00:00-07:00",
                           "attachments": []}, fh)
            with open(os.path.join(mail, "bodies", f"{key}.txt"), "w") as fh:
                fh.write("body text")
            open(os.path.join(mail, ".queue", f"triage-{key}"), "w").close()

        env = dict(os.environ)
        env.update({
            "CHARON_MAIL_BASE": base,
            "CHARON_LLM_PROVIDER": "openai-compat",
            "CHARON_LLM_BASE_URL": f"http://127.0.0.1:{port}/v1",
            "CHARON_LLM_API_KEY": "stub-key",
            "CHARON_MODEL_CHEAP": MODEL,
            "CHARON_MODEL_GOOD": MODEL,
        })
        proc = subprocess.run(
            [sys.executable, os.path.join(REPO, "mail-triage.py")],
            cwd=os.path.join(base, "mail-env"), env=env,
            capture_output=True, text=True, timeout=120)

        print("1. the worker reached the stub over a real socket")
        check(proc.returncode == 0, "worker exited 0", proc.stderr[-300:])
        check(len(seen_requests) == 1, "exactly one call for the batch",
              str(len(seen_requests)))
        if seen_requests:
            req = seen_requests[0]
            check(req["path"] == "/v1/chat/completions", "hit the right path", req["path"])
            check(req["auth"] == "Bearer stub-key", "sent the bearer token")
            check(req["payload"]["model"] == MODEL, "sent the configured model")
            sent = req["payload"]["messages"][0]["content"]
            check(all(k in sent for k in KEYS), "both messages were in the prompt")
            check("<<<BEGIN EMAIL" in sent, "the untrusted regions were fenced")

        print("\n2. verdicts reached disk")
        got = {}
        for key in KEYS + [GHOST]:
            path = os.path.join(mail, "ai", f"{key}.json")
            if os.path.exists(path):
                got[key] = json.load(open(path))
        for key in KEYS:
            check(key in got and got[key].get("status") == "ok",
                  f"{key[-4:]} classified", str((got.get(key) or {}).get("status")))

        print("\n3. the model id the record names is the one that answered")
        for key in KEYS:
            check((got.get(key) or {}).get("model") == MODEL,
                  f"{key[-4:]} record says {MODEL}",
                  str((got.get(key) or {}).get("model")))

        print("\n4. the worker did not believe the liar")
        check(GHOST not in got, "no record for a message never in the batch")
        for key in KEYS:
            tags = (got.get(key) or {}).get("tags") or []
            check("definitely-not-allowed" not in tags,
                  f"{key[-4:]} dropped the invented tag", str(tags))
            check(tags == ["lead"], f"{key[-4:]} kept only the real tag", str(tags))
        check((got.get(KEYS[0]) or {}).get("urgency") == 3,
              "urgency 9 was clamped to 3",
              str((got.get(KEYS[0]) or {}).get("urgency")))
        check((got.get(KEYS[1]) or {}).get("urgency") == 1, "urgency 1 survived")

        print("\n5. the queue drained")
        left = os.listdir(os.path.join(mail, ".queue"))
        check(not left, "no spool entries left behind", str(left))

        print(f"\n{ok} passed, {fail} failed")
        if fail:
            print(proc.stderr[-2000:])
        return 1 if fail else 0
    finally:
        srv.shutdown()
        shutil.rmtree(base, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
