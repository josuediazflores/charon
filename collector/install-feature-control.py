#!/usr/bin/env python3
"""Register existing feature systemd units. Does not enable, start or stop them."""
import argparse
import json
import os
from pathlib import Path
import re

from feature_control import CONFIG_DIR, FEATURES, STATE, UNIT, guard_name, pairs_from, systemctl


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--user", required=True, help="collector service account")
    parser.add_argument("--feature", choices=FEATURES, required=True)
    parser.add_argument("--service", action="append", default=[])
    parser.add_argument("--bridge", action="append", default=[], help="Registered Messages Bridge hostname without .local")
    parser.add_argument("--no-bridge", action="store_true", help="Confirm there is no Messages Bridge")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--pair", action="append", metavar="TRIGGER:WORKER")
    group.add_argument("--no-jobs", action="store_true")
    args = parser.parse_args()
    if os.geteuid() or not re.fullmatch(r"[a-z_][a-z0-9_-]*", args.user):
        parser.error("Run as root and specify the collector service account.")
    if systemctl("show", "-p", "User", "--value", "halftone-collector.service") != args.user:
        parser.error("The user must match the installed collector service.")
    pairs = pairs_from([p.split(":") for p in args.pair or []])
    services = args.service
    if bool(args.no_jobs) == bool(pairs or services):
        parser.error("Specify existing jobs or explicitly select --no-jobs.")
    if any(not UNIT.fullmatch(u) or not u.endswith(".service") for u in services):
        parser.error("Expected a named standalone service")
    if args.feature == "messages" and bool(args.bridge) == args.no_bridge:
        parser.error("Register each Bridge with --bridge or explicitly select --no-bridge.")
    if args.feature != "messages" and (args.bridge or args.no_bridge):
        parser.error("Bridge registration is specific to Messages.")
    if any(not name or len(name) > 255 or name.endswith(".local") for name in args.bridge):
        parser.error("Use the heartbeat hostname without .local.")
    triggers = sorted({*pairs, *services})
    units = sorted({*triggers, *pairs.values()})
    if set(services) & set(pairs.values()):
        parser.error("A triggered worker cannot also be a standalone service.")
    for unit in units:
        for other in FEATURES:
            foreign = Path("/etc/systemd/system") / (unit + ".d") / guard_name(other)
            if other != args.feature and foreign.exists():
                parser.error(f"{unit} already belongs to {other}.")
    for unit in units:
        if systemctl("show", "-p", "LoadState", "--value", unit) != "loaded":
            parser.error(f"{unit} must be installed before registration.")
    for trigger, worker in pairs.items():
        if worker not in systemctl("show", "-p", "Triggers", "--value", trigger).split():
            parser.error(f"{trigger} must already be installed and trigger {worker}.")
    entries = list(map(list, pairs.items()))
    config = entries if args.feature == "cmo" and not services else {
        "pairs": entries, "services": services, "bridges": sorted(set(args.bridge))}
    manifest = json.dumps(config, indent=2) + "\n"
    MANIFEST = CONFIG_DIR / f"{args.feature}-units.json"
    if MANIFEST.exists() and MANIFEST.read_text() != manifest:
        parser.error("Existing registration differs. Review it before replacing its scope.")
    for unit in units:
        directory = Path("/etc/systemd/system") / (unit + ".d")
        directory.mkdir(exist_ok=True)
        (directory / guard_name(args.feature)).write_text(f"[Unit]\nConditionPathExists=!{STATE}/{args.feature}-paused.json\n")
    policy = """polkit.addRule(function(action, subject) {
    if (action.id !== "org.freedesktop.systemd1.manage-units" || subject.user !== %s) return;
    var verb = action.lookup("verb"), unit = action.lookup("unit");
    if ((verb === "stop" && %s.indexOf(unit) >= 0) ||
        (verb === "start" && %s.indexOf(unit) >= 0)) return polkit.Result.YES;
});
""" % (json.dumps(args.user), json.dumps(units), json.dumps(triggers))
    Path(f"/etc/polkit-1/rules.d/65-charon-{args.feature}.rules").write_text(policy)
    systemctl("daemon-reload")
    MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    MANIFEST.write_text(manifest)


if __name__ == "__main__":
    main()
