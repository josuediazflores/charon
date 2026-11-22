#!/usr/bin/env python3
"""Check import recovery with temporary storage and in-memory transports."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import os
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[1]
sources = ["JSONValue", "Records", "Store", "Core", "Pins", "Paths", "Log",
           "Redact", "Watcher", "Backfill", "Attachments", "MessageIngest"]
scenarios = ("partial-live", "short-cursor", "missing-cursor", "refused", "unavailable",
             "partial-history", "revoke-history", "revoke-live", "concurrent", "disk-full",
             "fresh-restart", "revoke-photo", "revoke-wanted")
with tempfile.TemporaryDirectory(prefix="bridge-imports-") as scratch:
    executable = Path(scratch) / "checks"
    files = [str(root / (name + ".swift")) for name in sources]
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-module-cache-path",
                    os.environ.get("CLANG_MODULE_CACHE_PATH", str(Path(scratch) / "modules")), *files, str(root / "tests/ImportChecks.swift"),
                    "-o", str(executable)], check=True)
    def run(scenario):
        result = subprocess.run([str(executable), scenario], capture_output=True,
                                text=True, timeout=18)
        print(scenario, result.stdout.strip() or result.stderr.strip(), flush=True)
        return result.returncode == 0
    with ThreadPoolExecutor(max_workers=4) as pool:
        passed = list(pool.map(run, sys.argv[1:] or scenarios))
    raise SystemExit(0 if all(passed) else 1)
