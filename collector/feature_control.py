"""Manage only the systemd units registered by the Pi operator for each Charon feature."""
from contextlib import contextmanager
from collections import Counter
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import threading
import uuid

FEATURES = ("cmo", "mail", "messages", "chat", "jarvis")
CONFIG_DIR = Path("/etc/charon")
STATE = Path("/var/lib/halftone-collector")


def guard_name(feature):
    return f"70-charon-{feature}-guard.conf"

UNIT = re.compile(r"[a-zA-Z0-9][a-zA-Z0-9_.@-]*")
LOCKS = {name: threading.Lock() for name in FEATURES}
IN_FLIGHT = Counter()


def canonical_host(host):
    return host.lower().removesuffix(".local")


def pairs_from(items):
    if not isinstance(items, list):
        raise ValueError("Invalid feature unit manifest")
    pairs = {}
    for pair in items:
        if not isinstance(pair, list) or len(pair) != 2:
            raise ValueError("Expected a trigger and worker")
        trigger, worker = pair
        if (not all(isinstance(u, str) and UNIT.fullmatch(u) for u in pair)
                or not trigger.endswith((".path", ".timer")) or not worker.endswith(".service")
                or trigger in pairs):
            raise ValueError("Invalid feature unit pair")
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


class FeatureControl:
    def __init__(self, feature, manifest=None, state=None, run=systemctl):
        if feature not in FEATURES:
            raise ValueError("Unknown feature")
        state = STATE if state is None else state
        self.feature = feature
        self.manifest = manifest or CONFIG_DIR / f"{feature}-units.json"
        self.paused = state / f"{feature}-paused.json"
        self.resuming = state / f"{feature}-resuming.json"
        self.run = run

    def _inventory(self):
        if not self.manifest.is_file():
            raise RuntimeError(f"Register {self.feature} routine control on this collector.")
        config = json.loads(self.manifest.read_text())
        # Existing CMO registrations contain only trigger/worker pairs.
        if isinstance(config, list):
            config = {"pairs": config}
        pairs = pairs_from(config["pairs"])
        services = config.get("services", [])
        bridges = config.get("bridges", [])
        if not isinstance(services, list) or any(not isinstance(s, str) or
                not UNIT.fullmatch(s) or not s.endswith(".service") for s in services):
            raise ValueError("Invalid standalone service")
        if not isinstance(bridges, list) or not all(isinstance(b, str) and b for b in bridges):
            raise ValueError("Invalid Bridge registration")
        triggers = sorted({*pairs, *services})
        units = sorted({*triggers, *pairs.values()})
        for unit in units:
            dropin = "/etc/systemd/system/" + unit + ".d/" + guard_name(self.feature)
            if dropin not in self.run("show", "-p", "DropInPaths", "--value", unit).split():
                raise RuntimeError(f"Missing {self.feature} guard for {unit}.")
        return triggers, units, sorted({canonical_host(b) for b in bridges})

    def _active(self, unit):
        state = self.run("show", "-p", "ActiveState", "--value", unit)
        if not state:
            raise RuntimeError("Cannot verify unit state.")
        return state not in {"inactive", "failed"}

    @staticmethod
    def _record(path):
        data = json.loads(path.read_text())
        return {"restore": data} if isinstance(data, list) else data

    def bridge_state(self, host, acknowledgement=None):
        host = canonical_host(host)
        with LOCKS[self.feature]:
            if not self.paused.exists():
                if self.resuming.exists():
                    return {"enabled": False}
                if self.manifest.is_file():
                    config = json.loads(self.manifest.read_text())
                    if host not in {canonical_host(b) for b in config.get("bridges", [])}:
                        raise RuntimeError("Register this Bridge hostname on the collector.")
                return {"enabled": True}
            record = self._record(self.paused)
            generation = record["generation"]
            if acknowledgement == generation and host in record["awaiting"]:
                record["awaiting"].remove(host)
                atomic_json(self.paused, record)
            return {"enabled": False, "generation": generation}

    def apply(self, enabled=None):
        with LOCKS[self.feature]:
            triggers, units, bridges = self._inventory()
            if enabled is False:
                if not self.paused.exists():
                    previous = self._record(self.resuming)["restore"] if self.resuming.exists() else []
                    restore = sorted(set(previous) | {u for u in triggers if self._active(u)})
                    record = {"restore": restore}
                    if self.feature == "messages":
                        record.update(generation=uuid.uuid4().hex, awaiting=bridges)
                    # Keep the original CMO journal readable by earlier collectors.
                    atomic_json(self.paused, restore if self.feature == "cmo" else record)
                self.resuming.unlink(missing_ok=True)
                # An SMTP submission can have succeeded before its receipt is saved.
                # Let triggered Mail workers finish their current activation.
                stop = triggers if self.feature == "mail" else units
                if stop:
                    self.run("stop", *stop)
            elif enabled is True:
                if self.paused.exists():
                    self.paused.replace(self.resuming)
                if self.resuming.exists():
                    restore = self._record(self.resuming)["restore"]
                    if not isinstance(restore, list) or any(t not in triggers for t in restore):
                        raise RuntimeError("Registration changed while paused. Check the Pi configuration.")
                    if restore:
                        self.run("start", *restore)
                    self.resuming.unlink()
            paused = self.paused.exists()
            if self.resuming.exists():
                return {"enabled": None, "retryEnabled": True}
            if paused:
                active = {u for u in units if self._active(u)}
                if active or IN_FLIGHT[self.feature]:
                    result = {"enabled": None, "retryEnabled": False}
                    if not active or (self.feature == "mail" and not active.intersection(triggers)):
                        result["finishingWork"] = True
                    return result
            if paused and self._record(self.paused).get("awaiting"):
                return {"enabled": None, "retryEnabled": False, "waitingForBridge": True}
            return {"enabled": not paused}


def work_allowed(feature):
    return not ((STATE / f"{feature}-paused.json").exists() or
                (STATE / f"{feature}-resuming.json").exists())


@contextmanager
def admit(feature):
    """Account for requests already underway before confirming a pause."""
    if feature not in FEATURES:
        yield True
        return
    with LOCKS[feature]:
        allowed = work_allowed(feature)
        if allowed:
            IN_FLIGHT[feature] += 1
    try:
        yield allowed
    finally:
        if allowed:
            with LOCKS[feature]:
                IN_FLIGHT[feature] -= 1


def feature_access():
    """Lightweight tab visibility for the normal telemetry poll, including pending pauses."""
    result = {}
    for feature in FEATURES:
        if (CONFIG_DIR / f"{feature}-units.json").is_file():
            with LOCKS[feature]:
                result[feature] = work_allowed(feature)
    return result
