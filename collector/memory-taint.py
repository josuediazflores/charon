#!/usr/bin/env python3
"""The taint hook: one marker file, so a turn that fetched cannot write
memory. Deploys to /home/pi/halftone-chat/bin/memory-taint.

    memory-taint            the WebFetch|WebSearch matcher; always marks
    memory-taint --sniff    the Bash matcher; marks only for reddit-fetch.py

**Named as a PreToolUse hook in all three envs, never run by hand.** The
matcher decides which form fires. WebFetch and WebSearch are fetches by
definition, so the bare form marks unconditionally; Bash is nearly every tool
call on this box, so the --sniff form reads the hook payload and marks only
when the command's first token is reddit-fetch.py, the third fetch channel and
the one both talk CLAUDE.mds steer to over WebFetch. Any future
network-reaching Bash allow line has to be added to this sniff in the same edit
that adds it.

**The first token, and not the line.** A command that merely mentions the
fetcher is not a fetch, and the one that mentions it most is `bin/memory
remember` recording where a fact came from -- a sniff that read the whole line
would let a session taint itself by writing down its own sources. Everything
this program cannot read stands in for a fetch instead: an unparseable payload,
a payload carrying no command, an empty read, a read that never arrives.

**PreToolUse and not PostToolUse**, so the marker exists before the fetched
bytes do. A fetch and a write batched into one assistant message cannot
outrun a hook that has already run.

**It exits 0 in every case, including every error.** A hook that fails is a
tool call that fails, and a memory gate that broke ordinary turns would be
removed within a day. The gate does not rest on that grace to be safe: bin/
memory refuses a write without an `armed` file matching the turn, and each
runner arms only after checking that this binary and the hooks block are
actually on disk, so a half-landed deploy lands closed rather than open.

The lane comes from cwd, by the same function bin/memory uses, because the
hook command carries no lane argument -- the two programs cannot disagree
about which tree a turn's markers live in if neither one is told. A cwd
neither of them recognises marks every lane rather than none.

Stdlib only, like everything else on this box.
"""

import json
import os
import select
import sys
import time

BASE = os.environ.get("CHAT_BASE") or "/home/pi/halftone-chat"
TAINT_DIR = os.path.join(BASE, "memory", ".taint")

LANES = ("env", "sayenv", "jobenv")

# The one Bash command that reaches the network on this box today, and the
# shape the allow rules admit it in: an absolute path, first word of the line,
# arguments after it (chat-env/settings.json:11-12, jarvis-say-env:12-13). So
# the first token is the whole of what can actually fetch. The suffix form is
# here because the fetcher's directory is not this file's business to pin; a
# bare relative `reddit-fetch.py` is not a form any allow rule admits, and an
# interpreter in front of it -- `python3 <path>` -- is not one either.
#
# **Both arms, and both on purpose.** The absolute one is the exact string the
# allow rules name, and it moves with the install: set FETCH_BIN in the unit's
# environment when the fetcher lives somewhere other than the default below.
# The suffix one is the backstop that does not depend on getting that right,
# which is why the override is only allowed to widen what counts as a fetch and
# never to switch the sniff off -- an unset, empty or wrong FETCH_BIN still
# leaves every `/...reddit-fetch.py` first token tainting the turn.
#
# **Any future network-reaching Bash allow line has to be added here in the
# same edit that adds it**, or the gate is open for whatever that line admits.
FETCH_BIN = (os.environ.get("FETCH_BIN")
             or "/home/pi/feed-worker/reddit-fetch.py")
FETCH_SUFFIX = "/reddit-fetch.py"

# How long to wait for the hook payload. It is a few hundred bytes the CLI has
# already composed, so half a second is generous; what the deadline buys is
# that a hook wired to something that writes nothing and closes nothing cannot
# hang a tool call, and this one runs in front of every Bash call in three
# lanes. The byte ceiling is the same kind of backstop.
STDIN_DEADLINE_S = 0.5
STDIN_MAX_BYTES = 1 << 20


def lane():
    """The lane this process is running in, from the directory it started in.

    Byte-identical to the same function in bin/memory, deliberately: a hook
    that derived the lane differently from the tool would write markers into a
    tree the tool never reads, and the gate would be open with every file in
    place.
    """
    try:
        here = os.path.basename(os.getcwd())
    except OSError:
        return ""
    return here if here in LANES else ""


def payload():
    """The hook's stdin, up to a deadline; "" when nothing arrives in time.

    select and os.read on the raw descriptor rather than sys.stdin.read(),
    because a read that waits for EOF is a read that can wait forever, and
    this program sits in front of every Bash call in three lanes. Whatever has
    arrived when the clock runs out is what gets parsed, and a payload that is
    empty or cut off is one sniffed() cannot clear.
    """
    chunks = []
    total = 0
    deadline = time.monotonic() + STDIN_DEADLINE_S
    while total < STDIN_MAX_BYTES:
        left = deadline - time.monotonic()
        if left <= 0:
            break
        try:
            ready, _, _ = select.select([0], [], [], left)
        except (OSError, ValueError):
            break
        if not ready:
            break
        try:
            chunk = os.read(0, 65536)
        except OSError:
            break
        if not chunk:
            break
        chunks.append(chunk)
        total += len(chunk)
    return b"".join(chunks).decode("utf-8", "replace")


def sniffed(raw):
    """Whether this PreToolUse payload is a Bash call that fetches.

    The documented shape is {"tool_name": ..., "tool_input": {"command": ...}}.
    When the command is there, the answer is that command's first whitespace
    token and nothing else, for the reason at the head of this file: the rest
    of the line is arguments, filenames and prose, and prose is what a
    `bin/memory remember` carries.

    When the payload yields no command at all -- not JSON, no tool_input, an
    empty read, a truncated one -- this returns True. The stdin shape is an
    assumption about this CLI build until the live probes settle it, so a
    payload this program cannot read is a Bash call it cannot clear. That
    costs a refused write on a turn that fetched nothing; the other way round
    costs the store.
    """
    try:
        doc = json.loads(raw)
    except ValueError:
        return True
    command = None
    if isinstance(doc, dict):
        found = doc.get("tool_input")
        if isinstance(found, dict) and isinstance(found.get("command"), str):
            command = found["command"]
        elif isinstance(doc.get("command"), str):
            command = doc["command"]
    if command is None:
        return True
    first = (command.split() or [""])[0]
    return first == FETCH_BIN or first.endswith(FETCH_SUFFIX)


def touch(lane_name):
    """One marker in one lane's tree, mkdir -p first.

    mkdir -p rather than assume: each runner creates its own lane directory at
    spawn, so a half-created tree self-heals, and a hook that fired before any
    runner ever did should still leave its mark rather than lose it. The
    try/except is per lane so that one unwritable tree cannot swallow the
    marks meant for the others.
    """
    try:
        marks = os.path.join(TAINT_DIR, lane_name)
        os.makedirs(marks, exist_ok=True)
        with open(os.path.join(marks, f"hook-{os.getpid()}"), "w") as fh:
            fh.write("")
    except OSError:
        pass


def main():
    if "--sniff" in sys.argv[1:] and not sniffed(payload()):
        return

    # A cwd this program does not recognise is not a reason to let a fetch
    # through unrecorded: bin/memory derives its lane the same way, so a
    # session somewhere neither of them expected is exactly the case where the
    # two could disagree, and the tool's answer is the one that decides a
    # write. Marking all three costs at most a refused write in lanes that did
    # not fetch, and a refusal is inspectable with `memory taint`; the other
    # choice is a fetch nobody wrote down.
    here = lane()
    for lane_name in ((here,) if here else LANES):
        touch(lane_name)


if __name__ == "__main__":
    try:
        main()
    except Exception:
        pass
    sys.exit(0)
