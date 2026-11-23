#!/usr/bin/env python3
"""Register existing CMO systemd units. Does not enable, start or stop them."""
import argparse
import json
import os
from pathlib import Path
import re

from cmo_control import GUARD_NAME, MANIFEST, STATE, pairs_from, systemctl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", required=True, help="collector service account")
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--pair", action="append", metavar="TRIGGER:WORKER")
    group.add_argument("--no-jobs", action="store_true")
    args = parser.parse_args()
    if os.geteuid() or not re.fullmatch(r"[a-z_][a-z0-9_-]*", args.user):
        parser.error("Run as root and specify the collector service account.")
    if systemctl("show", "-p", "User", "--value", "halftone-collector.service") != args.user:
        parser.error("The user must match the installed collector service.")
    pairs = pairs_from([p.split(":") for p in args.pair or []])
    units = sorted({*pairs, *pairs.values()})
    for unit in units:
        if systemctl("show", "-p", "LoadState", "--value", unit) != "loaded":
            parser.error(f"{unit} must be installed before registration.")
    for trigger, worker in pairs.items():
        if worker not in systemctl("show", "-p", "Triggers", "--value", trigger).split():
            parser.error(f"{trigger} must already be installed and trigger {worker}.")
    manifest = json.dumps(list(map(list, pairs.items())), indent=2) + "\n"
    if MANIFEST.exists() and MANIFEST.read_text() != manifest:
        parser.error("Existing registration differs. Review it before replacing its scope.")
    for unit in units:
        directory = Path("/etc/systemd/system") / (unit + ".d")
        directory.mkdir(exist_ok=True)
        (directory / GUARD_NAME).write_text(f"[Unit]\nConditionPathExists=!{STATE}/cmo-paused.json\n")
    policy = """polkit.addRule(function(action, subject) {
    if (action.id !== "org.freedesktop.systemd1.manage-units" || subject.user !== %s) return;
    var verb = action.lookup("verb"), unit = action.lookup("unit");
    if ((verb === "stop" && %s.indexOf(unit) >= 0) ||
        (verb === "start" && %s.indexOf(unit) >= 0)) return polkit.Result.YES;
});
""" % (json.dumps(args.user), json.dumps(units), json.dumps(list(pairs)))
    Path("/etc/polkit-1/rules.d/65-charon-cmo.rules").write_text(policy)
    systemctl("daemon-reload")
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(manifest)


if __name__ == "__main__":
    main()
