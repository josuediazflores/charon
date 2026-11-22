#!/usr/bin/env python3
"""Run the built Bridge and real collector on loopback with a fake Messages helper.

    python3 Bridge/tests/run-collector-pair.py /path/to/collector
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
from http.server import ThreadingHTTPServer
from unittest.mock import patch
from urllib.request import Request, urlopen
from uuid import uuid4


def check_pair(routes, directory):
    mac = Path(__file__).resolve().parents[2]
    bridge = mac / "DerivedData/Build/Products/Debug/Charon Bridge.app/Contents/MacOS/Charon Bridge"
    collector = routes.build(str(directory))
    ok, why, _ = collector.messages_config_put({
        "chats": {routes.CHAT_A_GUID: {"read": True, "send": "confirm"}}
    })
    assert ok, why
    actual_write = routes.C.write_atomic
    triage = Path(collector.messages_path(routes.C.MESSAGES_QUEUE_NAME, "triage-ea7b6b628ef7db77"))
    rejected_once = False

    def fail_first_triage(path, content):
        nonlocal rejected_once
        if Path(path) == triage and not rejected_once:
            rejected_once = True
            return False
        return actual_write(path, content)

    handler = routes.C.make_handler(collector, routes.TOKEN)
    with ThreadingHTTPServer(("127.0.0.1", 0), handler) as server:
        origin = f"http://127.0.0.1:{server.server_port}"

        def api(path, body=None):
            req = Request(origin + "/v1/messages/" + path,
                          data=json.dumps(body).encode() if body is not None else None,
                          headers={"Authorization": "Bearer " + routes.TOKEN,
                                   "Content-Type": "application/json"})
            with urlopen(req, timeout=5) as response:
                return json.load(response)

        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            action = {"chat_key": routes.CHAT_A, "body": "offline fixture", "request_id": str(uuid4())}
            accepted = api("send", action)
            assert accepted == api("send", action)
            env = dict(os.environ, CHARON_BRIDGE_HOME=str(directory / "bridge"),
                       CHARON_COLLECTOR_URL=origin, CHARON_COLLECTOR_TOKEN=routes.TOKEN,
                       CHARON_IMSG_PATH=str(mac / "Bridge/tests/fake-imsg.py"),
                       CHARON_FAKE_IMSG_FILES=str(directory / "files"),
                       CHARON_FAKE_SEND_MARKER=str(directory / "sends"))
            with patch.object(routes.C, "write_atomic", side_effect=fail_first_triage):
                subprocess.run([str(bridge), "--dry-run", "--exit-after", "18"],
                               env=env, check=True, stdout=subprocess.DEVNULL, timeout=45)

            assert (directory / "sends").read_text().splitlines() == ["send"]
            result = api("thread/" + routes.CHAT_A)
            receipt, = result["outbox"]
            assert (receipt["status"], receipt["message_id"], receipt["request_id"]) == (
                "sent", "1979", action["request_id"]), receipt
            assert rejected_once and triage.is_file(), "the failed triage entry was not repaired"
            assert sorted(row["rowid"] for row in result["messages"]) == [41, 43, 44, 45, 102]
            state = json.loads((directory / "bridge/state.json").read_text())
            assert state["cursor"] == 103
            assert state["backfill"][routes.CHAT_A_GUID]["done"]
            assert api("send", action) == accepted
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("collector", type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(args.collector.resolve() / "tests"))
    import test_messages_routes
    with tempfile.TemporaryDirectory() as root:
        check_pair(test_messages_routes, Path(root))
    print("PASS: one send, five unique imported rows, repaired triage and both checkpoints")
