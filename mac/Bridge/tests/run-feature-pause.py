#!/usr/bin/env python3
"""Exercise a real Bridge pause and resume on loopback with the synthetic Messages helper."""
import argparse
from http.server import ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch
from urllib.request import Request, urlopen


def until(condition, description, timeout=45):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return
        time.sleep(0.2)
    raise AssertionError(description)


def exercise(root, mac, routes):
    host = socket.gethostname().removesuffix(".local")
    (root / "messages-units.json").write_text(json.dumps({"pairs": [], "bridges": [host]}))
    collector = routes.build(str(root))
    log = []
    class Handler(routes.C.make_handler(collector, routes.TOKEN)):
        def log_request(self, code="-", size="-"):
            log.append(self.path)

    with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        origin = f"http://127.0.0.1:{server.server_port}"
        def settings(doc):
            request = Request(origin + "/v1/messages/routines", data=json.dumps(doc).encode(),
                              headers={"Authorization": "Bearer " + routes.TOKEN})
            with urlopen(request, timeout=3) as response:
                return json.load(response)
        starts = root / "starts"
        bridge = mac / "DerivedData/Build/Products/Debug/Charon Bridge.app/Contents/MacOS/Charon Bridge"
        env = dict(os.environ, CHARON_BRIDGE_HOME=str(root / "bridge"), CHARON_COLLECTOR_URL=origin,
                   CHARON_COLLECTOR_TOKEN=routes.TOKEN, CHARON_IMSG_PATH=str(mac / "Bridge/tests/fake-imsg.py"),
                   CHARON_FAKE_IMSG_FILES=str(root / "files"), CHARON_FAKE_IMSG_MARKER=str(starts))
        process = None
        try:
            assert settings({"enabled": False})["enabled"] is None
            subprocess.run([bridge, "--once", "--dry-run"], env=env, check=True, timeout=10)
            assert settings({}) == {"enabled": False} and not starts.exists()
            settings({"enabled": True})
            process = subprocess.Popen([bridge, "--dry-run"], env=env)
            until(lambda: starts.exists() and "/v1/messages/bridge" in log, "no running Bridge")
            pid = int(starts.read_text().split()[0])
            assert settings({"enabled": False})["enabled"] is None
            until(lambda: settings({}) == {"enabled": False}, "Bridge did not acknowledge shutdown")
            def stopped():
                try:
                    os.kill(pid, 0)
                except ProcessLookupError:
                    return True
                return False
            until(stopped, "helper still running", 3)
            count = len(log)
            time.sleep(4)
            assert not log[count:], "Bridge issued requests after acknowledging the pause"
            assert settings({"enabled": True}) == {"enabled": True}
            until(lambda: len(starts.read_text().splitlines()) > 1 and "/v1/messages/bridge" in log[count:],
                  "Bridge did not restart and report status")
        finally:
            if process is not None:
                process.terminate()
                process.wait(timeout=10)
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("collector", type=Path)
    args = parser.parse_args()
    sys.path.insert(0, str(args.collector.resolve() / "tests"))
    import test_messages_routes as routes
    import feature_control as control
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        with patch.object(control, "STATE", root), patch.object(control, "CONFIG_DIR", root):
            exercise(root, Path(__file__).resolve().parents[2], routes)
    print("PASS: paused startup, helper exit, idle Bridge, and resume")
