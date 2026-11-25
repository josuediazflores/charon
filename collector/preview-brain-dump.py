"""Open a Mac test build with on-demand Codex planning and an in-memory demo queue."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from http.server import ThreadingHTTPServer
import os
from pathlib import Path
import secrets
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
from threading import Thread

import collector
import jarvis_runs


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", type=Path, help="Path to a built Charon.app")
    args = parser.parse_args()
    binary = args.app.resolve() / "Contents/MacOS/Charon"
    codex = shutil.which("codex")
    if not binary.is_file() or not codex:
        parser.error("Supply a built Charon.app and put your signed-in Codex CLI on PATH.")

    runner = Path(__file__).resolve().with_name("jarvis-job-runner.py")
    with TemporaryDirectory(prefix="charon-planner-") as base, ThreadPoolExecutor(max_workers=1) as lane:
        cfg = collector.load_config(str(Path(base) / "config.json"))
        cfg["chat"]["base_dir"] = base
        cfg["state_dir"] = str(Path(base) / "state")
        env = dict(os.environ, CHAT_BASE=base, JARVIS_JOB_BACKEND="codex", JARVIS_CODEX_BIN=codex,
                   JARVIS_CODEX_HOME=os.environ.get("CODEX_HOME") or str(Path.home() / ".codex"))

        class PreviewCollector(collector.Collector):
            def jarvis_intake(self, body, operation="intake"):
                response = super().jarvis_intake(body, operation)
                if response[0]:
                    lane.submit(subprocess.run, [sys.executable, str(runner), "--intake"], env=env, cwd=base)
                return response

        token = secrets.token_urlsafe(32)
        class Handler(collector.make_handler(PreviewCollector(cfg), token)):
            def _dispatch(self, handler):
                if self.command == "POST" and self.path == "/v1/jarvis/intake/process":
                    return super()._dispatch(handler)
                prefix = "/v1/jarvis/runs/"
                if self.command == "GET" and self.path.startswith(prefix) and jarvis_runs.JOB_ID.fullmatch(self.path[len(prefix):]):
                    return super()._dispatch(handler)
                self.send_error(404)

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                return subprocess.call([str(binary), "-mode", "demo"], env=dict(
                    os.environ, CHARON_PREVIEW_PORT=str(server.server_port), CHARON_PREVIEW_TOKEN=token))
            finally:
                server.shutdown()
                thread.join()


if __name__ == "__main__":
    sys.exit(main())
