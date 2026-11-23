"""Manage only the systemd units registered by the Pi operator for CMO."""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading

MANIFEST = Path("/etc/charon/cmo-units.json")
STATE = Path("/var/lib/halftone-collector")
GUARD_NAME = "70-charon-cmo-guard.conf"
UNIT = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.@-]*")
LOCK = threading.Lock()


def pairs_from(items):
    if not isinstance(items, list):
        raise ValueError("Invalid CMO unit manifest")
    pairs = {}
    for pair in items:
        if not isinstance(pair, list) or len(pair) != 2:
            raise ValueError("Expected a trigger and worker")
        trigger, worker = pair
        if (not all(isinstance(u, str) and UNIT.fullmatch(u) for u in pair)
                or not trigger.endswith((".path", ".timer")) or not worker.endswith(".service")
                or trigger in pairs):
            raise ValueError("Invalid CMO unit pair")
        pairs[trigger] = worker
    return pairs


def systemctl(*args):
    result = subprocess.run(["/usr/bin/systemctl", "--no-ask-password", *args],
                            capture_output=True, text=True, timeout=120, check=True)
    return result.stdout.strip()


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        temp = Path(out.name)
        try:
            json.dump(value, out)
            out.flush()
            os.fsync(out.fileno())
        except BaseException:
            temp.unlink(missing_ok=True)
            raise
    try:
        temp.replace(path)
    finally:
        temp.unlink(missing_ok=True)


class CmoControl:
    def __init__(self, manifest=MANIFEST, state=STATE, run=systemctl):
        self.manifest = manifest
        self.paused = state / "cmo-paused.json"
        self.resuming = state / "cmo-resuming.json"
        self.run = run

    def _inventory(self):
        if not self.manifest.is_file():
            raise RuntimeError("Install CMO routine control on this collector.")
        pairs = pairs_from(json.loads(self.manifest.read_text()))
        for unit in {*pairs, *pairs.values()}:
            dropin = "/etc/systemd/system/" + unit + ".d/" + GUARD_NAME
            if dropin not in self.run("show", "-p", "DropInPaths", "--value", unit).split():
                raise RuntimeError("CMO service guards are missing. Check the Pi configuration.")
        return pairs

    def _active(self, unit):
        state = self.run("show", "-p", "ActiveState", "--value", unit)
        if not state:
            raise RuntimeError("Cannot verify CMO unit state.")
        return state not in {"inactive", "failed"}

    def apply(self, enabled=None):
        with LOCK:
            pairs = self._inventory()
            units = sorted({*pairs, *pairs.values()})
            if enabled is False:
                if not self.paused.exists():
                    previous = json.loads(self.resuming.read_text()) if self.resuming.exists() else []
                    restore = set(previous) | {u for u in pairs if self._active(u)}
                    atomic_json(self.paused, sorted(restore))
                self.resuming.unlink(missing_ok=True)
                if units:
                    self.run("stop", *units)
            elif enabled is True:
                if self.paused.exists():
                    self.paused.replace(self.resuming)
                if self.resuming.exists():
                    triggers = json.loads(self.resuming.read_text())
                    if not isinstance(triggers, list) or any(t not in pairs for t in triggers):
                        raise RuntimeError("CMO schedule changed while paused. Check the Pi configuration.")
                    if triggers:
                        self.run("start", *triggers)
                    self.resuming.unlink()
            paused = self.paused.exists()
            if self.resuming.exists() or (paused and any(self._active(u) for u in units)):
                return {"enabled": None, "retryEnabled": not paused}
            return {"enabled": not paused}
