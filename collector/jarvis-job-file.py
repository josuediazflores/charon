#!/usr/bin/env python3
"""File one Jarvis job from inside a session. Deploys to
/home/pi/halftone-chat/bin/jarvis-job.

    jarvis-job "<title>" "<instruction...>"

**This exists so the talk lane can delegate without holding the API token.**
The session must never see COLLECTOR_API_TOKEN -- the allowlist fences .env and
/proc/*/environ specifically -- so it cannot call POST /v1/jarvis/job. What it
can do, as the service user, is what this script does: write the same two files
that route writes, validated the same way.

**Deliberately NOT the route's three writes, and the missing one is the point.**
`jarvis_job` in collector.py writes record, card, spool. The card is an append
to the day record -- the file the say runner is rewriting every half second
while an answer streams, which is exactly when this script runs, because the
session invoking it IS that answer. Appending here would race its own parent.
So: record and spool only, and the card arrives through the collector's
reconcile-on-read (`jarvis_reconcile_jobs` rebuilds missing cards from job
records at their own timestamp). A card that appears one poll later is the
ordinary case for every job, however filed.

One writer per field still holds: this writes the same fields the collector
writes at filing (id, day, title, text, timestamps, idle, no error), and the
job runner overwrites status the moment it picks the job up. Nothing here ever
touches a day record or another job's file.

Stdlib only, like everything else on this box.
"""

import os
import re
import sys
from datetime import datetime
from pathlib import Path
from jarvis_intake import atomic_json

BASE = os.environ.get("CHAT_BASE") or "/home/pi/halftone-chat"
JOBS_DIR = os.path.join(BASE, "jarvis", "jobs")
SPOOL_DIR = os.path.join(BASE, "jarvis", ".jobs")

# The collector's own caps, restated: the route enforces these on its side and
# a helper that filed something the route would refuse is a second opinion
# about what a job is.
TITLE_MAX = 80
TEXT_MAX = 4000

_DAY = re.compile(r"\d{4}-\d{2}-\d{2}")


def die(why):
    print(f"jarvis-job: {why}", file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) != 3:
        die('usage: jarvis-job "<title>" "<instruction>"')
    title = sys.argv[1].strip()[:TITLE_MAX]
    text = sys.argv[2].strip()
    if not title:
        die("the title is empty")
    if not text:
        die("the instruction is empty")
    if len(text) > TEXT_MAX:
        die(f"the instruction is over {TEXT_MAX} characters; a job this size "
            "should be a file the job reads, not an argument")

    if not os.path.isdir(os.path.join(BASE, "jarvis")):
        die(f"{BASE}/jarvis is not there; this box is not set up for jarvis")

    now = datetime.now()
    day = now.strftime("%Y-%m-%d")
    stamp = now.isoformat(timespec="seconds")

    # The collector's mint: day, local minute, four hex, re-rolled on the
    # collision that should never happen rather than writing over a job that
    # is running.
    os.makedirs(JOBS_DIR, exist_ok=True)
    os.makedirs(SPOOL_DIR, exist_ok=True)
    jid = None
    for _ in range(8):
        candidate = (f"{day}-{now.strftime('%H%M')}-"
                     f"{os.urandom(2).hex()}")
        if not os.path.exists(os.path.join(JOBS_DIR, f"{candidate}.json")):
            jid = candidate
            break
    if not jid:
        die("could not mint a job id")

    job = {
        "id": jid,
        "day": day,
        "title": title,
        "text": text,
        "created_at": stamp,
        "updated_at": stamp,
        # Idle, truthfully: nothing is running, and the spool entry below is
        # how "filed, not started" is said. The job runner overwrites this the
        # moment it picks the job up.
        "status": "idle",
        "error": None,
    }

    # Atomic for the reason every record write on this box is: the job runner
    # scans this directory, and a half-written record read mid-scan costs its
    # own row.
    path = Path(JOBS_DIR, f"{jid}.json")
    try:
        atomic_json(path, job, exclusive=True)
    except OSError as exc:
        die(f"cannot write the job: {exc.strerror or exc}")

    # The spool goes last, the route's own ordering: the path unit fires on
    # this, and an entry that appeared first could wake a runner for a job
    # that is not on disk yet.
    try:
        with open(os.path.join(SPOOL_DIR, jid), "w") as fh:
            fh.write(jid)
    except OSError as exc:
        die(f"job written but not queued: {exc.strerror or exc}")

    # The one line of stdout, so the session can tell the reader what it filed.
    print(jid)


if __name__ == "__main__":
    main()
