#!/usr/bin/env python3
"""The assistant's memory store, and the only program that writes it. Deploys
to /home/pi/halftone-chat/bin/memory.

    memory remember <name> <description> <body|->
    memory revise   <name> <description> <body|->
    memory forget   <name>
    memory list
    memory show <name>
    memory taint

**One writing program, because the choke point is where the rules live.**
The journal, the flock, the taint gate, and the caps are all things prompt
discipline can drift and a binary cannot. The talk lanes get this one allow
line and no general write power they do not need, the same shape as
bin/jarvis-job keeping the API token out of session reach
(jarvis-job-file.py:7-11). There is no HTTP route onto the same store for the
same reason there is no token: sessions must never see COLLECTOR_API_TOKEN,
and the collector runs under ProtectHome=read-only with carve-outs named one
directory at a time, so it cannot write this tree at all. Files are the API,
as everywhere else on this box.

**The turn is the trust boundary, and it fails closed.** A turn that pulled in
external content may not write memory. Each runner clears its lane's
memory/.taint/<lane>/ at spawn and writes `armed` holding that turn's
MEMORY_TURN_ID; PreToolUse hooks drop a marker beside it the moment a fetch is
requested; the write verbs here refuse unless `armed` is there, matches this
process's own MEMORY_TURN_ID, and is alone in the directory. A missing tree, a
half-landed deploy, a stale `armed` from the turn before, and a hand-run from
a shell all land on the same refusal, which is deliberate: the operator edits
entry files directly when he wants to, and the tool is the sessions' door.

**Write order: the entry and its journal line under one flock, and the
creative verbs put the entry first.** The spool-goes-last house ordering
(jarvis-job-file.py:116-118) applied to an audit trail: a kill between the two
leaves a remember or a revise with no line, which is recoverable by reading the
store, never a line describing a write that did not happen, which is the one
thing that corrupts undo. `forget` inverts the pair, for the same reason read
the other way round -- the line is the only copy of what the entry said, so it
lands before the file is unlinked. A kill in that gap leaves a line whose op
re-runs cleanly; the other order loses the body the journal exists to keep.

The read verbs -- list, show, taint -- take no lock, need no `armed`, and run
in every lane and from any cwd. `taint` exists so a stuck marker is observable
from anywhere, instead of only as a mystery refusal.

Stdlib only, like everything else on this box.
"""

import fcntl
import json
import os
import re
import sys
from datetime import datetime, timezone

# Where the store lives. Overridable so this file can be exercised on a Mac
# with a temp directory, the same reason every other program here reads
# CHAT_BASE (chat-runner.py:63). The Pi's path is the default because that is
# the box this runs on.
BASE = os.environ.get("CHAT_BASE") or "/home/pi/halftone-chat"
MEM_DIR = os.path.join(BASE, "memory")
JOURNAL_PATH = os.path.join(MEM_DIR, ".journal.jsonl")
LOCK_PATH = os.path.join(MEM_DIR, ".lock")
TAINT_DIR = os.path.join(MEM_DIR, ".taint")

# The lanes, named by the directory each runner starts its session in: cwd at
# the Popen is env for chat (chat-runner.py:1061), sayenv for Jarvis talk
# (jarvis-say-runner.py:942), and jobenv for Jarvis work
# (jarvis-job-runner.py:629).
# The job lane reads and never writes: a tainted say turn could otherwise
# launder a write through bin/jarvis-job into a lane that starts clean by
# construction, and the job runner records a tool count rather than tool lines,
# so the write would be invisible on every surface.
LANES = ("env", "sayenv", "jobenv")
WRITE_LANES = ("env", "sayenv")

# The entry name shape, anchored at every use. Unanchored this pattern matches
# the good prefix of a bad name, which is why the runner uses its own copy as
# SLUG.fullmatch (chat-runner.py:246) and why this file never calls anything
# else on it.
SLUG = re.compile(r"[a-z0-9-]{1,64}")

# The caps, restated as numbers rather than as prose in the standing
# instructions, because a cap a prompt states is a cap that drifts. The
# description is what the injected index carries one line at a time, so it is
# one line and short; the body is what a session Reads when the line is not
# enough. The entry cap is deliberately EQUAL to the digest cap in the
# runners: an index that clips is the machine that manufactures duplicate
# siblings, whichever direction the clip runs.
DESC_MAX = 200
BODY_MAX = 2000
ENTRY_MAX = 128

# How many lines `list` prints before it starts counting instead. The same
# number as the runners' MEMORY_DIGEST_MAX (chat-runner.py:690), deliberately:
# `list` is how a session checks the index it was handed, so the two have to
# clip at the same place, in the same direction, and against a store this tool
# wrote neither of them ever clips at all.
LIST_MAX = ENTRY_MAX

# How big the journal gets before it is halved oldest-first. Undo therefore
# has a horizon, stated plainly rather than discovered: past this, the oldest
# before-records are gone and true immediate forgetting is the operator
# hand-editing a line out.
JOURNAL_MAX_BYTES = 512 * 1024

# The one refusal the taint gate gives, for every one of its conditions. A
# gate that told the asker which condition failed is a gate you can
# interrogate, and the session's standing instructions name this refusal
# specifically as the one not to retry.
TAINTED = ("memory is read-only this turn: external content was fetched. "
           "If this should be saved, ask the operator to say it himself next "
           "turn.")

USAGE = ("usage: memory remember|revise <name> <description> <body|->; "
         "memory forget <name>; memory list; memory show <name>; memory taint")


def die(why):
    print(f"memory: {why}", file=sys.stderr)
    sys.exit(1)


def stamp():
    """UTC ISO seconds with the Z, the shape the entry frontmatter carries.

    UTC rather than the local seconds every other program here stamps
    (chat-runner.py:86-88), and the departure is deliberate. `updated` is
    sorted as a string in three places -- here, in `list`, and in the digest
    each runner renders -- and local time sorts an hour of every autumn
    backwards. The cost is that an entry written in the evening carries a
    `created` date one day ahead of the `thread` beside it, which is a
    timestamp being honest about a day boundary rather than a bug.
    """
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def lane():
    """The lane this process is running in, from the directory it started in.

    The runners each Popen their session with cwd set to their own env
    directory, so the basename of the cwd is the lane and nothing has to pass
    it as an argument. This function is byte-identical in bin/memory-taint,
    deliberately: the hook command carries no lane argument, so the two
    programs cannot disagree about which tree a turn's markers live in.
    """
    try:
        here = os.path.basename(os.getcwd())
    except OSError:
        return ""
    return here if here in LANES else ""


def entry_path(name):
    """The file for one entry, or "" if that name is not a plain file here.

    Two refusals, and the order between them is the point. A symlink is
    refused first, before anything resolves it: an entry file is a plain file
    this tool wrote, and a link is an alias for something else -- which is the
    whole attack. `escape.md` pointing out of the tree is the obvious half;
    `j.md` pointing at `.journal.jsonl`, or `alias.md` pointing at another
    entry, are the half realpath cannot see, because both of those resolve to
    a path that is honestly inside the store. Resolving them would let a
    remember overwrite the audit trail, or journal a write under one name that
    landed on another.

    The containment check stays behind it, the collector's own idiom for a
    path that is written to as well as read (chat_thread_path,
    collector.py:4555-4566). The anchored pattern already refuses a dot and a
    slash, so nothing should reach it -- it is what catches a link that
    appeared between the check above and this line.
    """
    root = os.path.realpath(MEM_DIR)
    direct = os.path.join(root, f"{name}.md")
    if os.path.islink(direct):
        return ""
    candidate = os.path.realpath(direct)
    return candidate if candidate.startswith(root + os.sep) else ""


def read_entry(path):
    """The frontmatter and body of one entry, best effort.

    Best effort because the operator edits these files by hand -- that is the
    documented undo -- so a file with a mangled fence, or bytes that are not
    quite UTF-8 any more, is still an entry whose text the journal has to
    carry into `before` before a revise or a forget takes it away. A file that
    will not open at all is the only failure this reports, by raising OSError
    to a caller that can say what it was doing.
    """
    with open(path, errors="replace") as fh:
        raw = fh.read()
    meta = {}
    body = raw
    if raw.startswith("---\n"):
        end = raw.find("\n---\n", 3)
        if end != -1:
            for line in raw[4:end + 1].splitlines():
                key, sep, val = line.partition(":")
                if sep:
                    meta[key.strip()] = val.strip()
            body = raw[end + 5:]
    return meta, body


def render_entry(name, description, lane_name, thread, created, updated, body):
    """One entry as it sits on disk: frontmatter the digest reads without
    parsing the whole file, then the prose a session Reads when the index line
    is not enough."""
    return ("---\n"
            f"name: {name}\n"
            f"description: {description}\n"
            f"lane: {lane_name}\n"
            f"thread: {thread}\n"
            f"created: {created}\n"
            f"updated: {updated}\n"
            "---\n"
            f"{body}\n")


def entries():
    """Every entry the index carries, `(updated, name, description)`,
    newest-updated last.

    The name is the filename stem and not the frontmatter `name` field, which
    is what the runners' digest keys off too. The stem is what `show`,
    `revise` and `forget` address, so a hand-edited file whose `name:` line
    drifted from its filename would otherwise print a line no verb can act on
    -- and the session is told to curate from these lines. The frontmatter
    keeps its `name` for whoever opens the file; nothing reads it back.

    A stem the anchored pattern refuses is not an entry, an entry with no
    description has no line to give, and a symlink is not something any verb
    here will resolve (entry_path), so all three are skipped in silence: the
    operator edits this tree by hand, and a mangled file costs its own line and
    nothing else. A line naming a file the next `revise` would refuse is worse
    than no line, because these lines are what a session curates from.

    Newest-updated last, the ordering the digest renders in, for the same
    reason: when something has to be dropped it is the oldest.
    """
    rows = []
    try:
        with os.scandir(MEM_DIR) as found:
            for item in found:
                if not item.name.endswith(".md"):
                    continue
                name = item.name[:-3]
                if not SLUG.fullmatch(name):
                    continue
                try:
                    if item.is_symlink():
                        continue
                    meta, _ = read_entry(item.path)
                except OSError:
                    continue
                description = meta.get("description", "")
                if not description:
                    continue
                rows.append((meta.get("updated", ""), name, description))
    except OSError:
        return []
    rows.sort()
    return rows


def entry_count():
    """How many files the store owns. Files rather than parseable entries: the
    cap is about how big the injected index can get, and a malformed file is
    still a name a future `remember` can collide with."""
    total = 0
    try:
        with os.scandir(MEM_DIR) as found:
            for item in found:
                if not item.name.endswith(".md"):
                    continue
                if SLUG.fullmatch(item.name[:-3]):
                    total += 1
    except OSError:
        return 0
    return total


def take_lock():
    """Exclusive and blocking, held across the whole write path.

    Blocking, unlike the runners' own non-blocking lock: being already busy is
    a correct outcome for a drain that will be re-fired, and the wrong outcome
    for a write a session asked for once. Contention is two talk lanes against
    a handful of small file operations, and flock releases when the holder
    dies, so waiting here cannot outlive the process that made us wait.
    """
    try:
        fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX)
    except OSError as exc:
        die(f"cannot lock the store: {exc.strerror or exc}")
    return fd


def armed_or_die(lane_name):
    """Refuse the write unless this exact turn armed the gate and stayed clean.

    Three conditions, all required: `armed` exists, its content is this
    process's own MEMORY_TURN_ID, and it is the only file in the lane's marker
    directory. The runner writes `armed` at spawn, after checking that the
    hooks block and the taint binary are actually there, and every PreToolUse
    fetch hook drops a marker beside it. So "clean" means the same thing here
    as it means in the session: nothing from outside this box has been read
    into this turn.

    Checked inside the lock rather than before it, because a check outside
    leaves a window where a marker lands between the check and the write.
    """
    turn = (os.environ.get("MEMORY_TURN_ID") or "").strip()
    marks = os.path.join(TAINT_DIR, lane_name)
    try:
        names = os.listdir(marks)
    except OSError:
        die(TAINTED)
    if not turn or names != ["armed"]:
        die(TAINTED)
    try:
        with open(os.path.join(marks, "armed")) as fh:
            got = fh.read().strip()
    except OSError:
        die(TAINTED)
    if got != turn:
        die(TAINTED)


def write_entry(path, text):
    """tmp + os.replace, the house style (write_atomic, collector.py:289-291).

    A digest scan runs on every spawn of both talk lanes, and a half-written
    frontmatter read mid-scan costs that entry its line in the index for the
    whole turn.
    """
    tmp = f"{path}.tmp"
    try:
        with open(tmp, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
    except OSError as exc:
        try:
            os.remove(tmp)
        except OSError:
            pass
        die(f"cannot write the entry: {exc.strerror or exc}")


def journal(lane_name, op, name, before, after, unjournaled):
    """One line per op, appended whole, on whichever side of the op cannot
    afford to lose it: after the entry for remember and revise, before the
    unlink for forget.

    The description travels with the body in both records, or revise and
    forget cannot be undone: the description is the very thing the index
    injects, so an undo that restored only the prose would restore an entry
    the sessions read differently.

    `unjournaled` is what to say when the append fails, and it is the caller's
    line to write because the ordering differs by verb -- remember and revise
    have already changed the store by the time this runs, and forget has not
    touched it yet.

    Mode 0600 because this file retains the bodies of forgotten entries. The
    settings-level Read fence is what keeps it away from the sessions; this is
    just the file saying what it is.
    """
    line = json.dumps({
        "at": stamp(),
        "lane": lane_name,
        "op": op,
        "name": name,
        "before": before,
        "after": after,
    }, ensure_ascii=False) + "\n"
    try:
        fd = os.open(JOURNAL_PATH,
                     os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    except OSError as exc:
        die(f"{unjournaled}: {exc.strerror or exc}")
    try:
        # One write, so an interleaved op from the other lane lands before or
        # after this line and never inside it.
        os.write(fd, line.encode("utf-8"))
    except OSError as exc:
        die(f"{unjournaled}: {exc.strerror or exc}")
    finally:
        os.close(fd)


def rotate():
    """Halve the journal oldest-first once it has crossed the size bound.

    Under the same flock as the append that pushed it over, so no reader
    catches the file mid-rewrite and no writer halves a file another writer is
    appending to. A failure here is silent on purpose: by the time this runs
    the op and its line are both done, and refusing an op that succeeded
    because its audit trail could not be trimmed would be the tail wagging the
    dog.

    In bytes, because this is a byte operation on whole lines: rotation is not
    the place to form an opinion about the encoding of a file the operator is
    invited to hand-edit.

    The tmp is created at 0600 rather than opened and narrowed afterwards. It
    holds the bodies of forgotten entries the whole time it is being written,
    and a plain open would leave those bytes at whatever the umask allows for
    the length of the write -- the audit trail's Read fence would be the only
    thing left in front of them. O_EXCL for the same reason it refuses to
    inherit anything already at that path; nothing else rotates while this
    flock is held, so a tmp that exists is one a killed rotation left behind,
    and it is removed and remade rather than allowed to wedge rotation shut
    for good.
    """
    try:
        if os.path.getsize(JOURNAL_PATH) <= JOURNAL_MAX_BYTES:
            return
        with open(JOURNAL_PATH, "rb") as fh:
            lines = fh.readlines()
    except OSError:
        return
    tmp = f"{JOURNAL_PATH}.tmp"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    try:
        try:
            fd = os.open(tmp, flags, 0o600)
        except OSError:
            os.remove(tmp)
            fd = os.open(tmp, flags, 0o600)
    except OSError:
        return
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.writelines(lines[len(lines) // 2:])
        os.replace(tmp, JOURNAL_PATH)
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass


# -- the read verbs -----------------------------------------------------------
#
# No flock, no `armed`, every lane, any cwd. They read a tree that only this
# program writes, so there is nothing for a lock to protect them from, and a
# refusal nobody can inspect is a mystery rather than a boundary.

def verb_list():
    """The index the digest injects, newest-updated last.

    Same source, same key, same ordering, same clip: names come off the
    filename stem, malformed files are skipped rather than shown, and the
    store cap equals the digest cap, so against a store this tool wrote these
    are the lines a session was already given. On a store built by hand the
    two can still differ at the margin: the digest renders each line from a
    bounded head of the file where this reads the whole of it, and this skips
    a symlink where the digest only sees whatever it points at.

    Past the cap the newest survive, the direction the digest clips in, and
    what did not fit is counted rather than dropped in silence: a session
    comparing this against the index in its prompt has to be told the store is
    bigger than either of them shows.
    """
    rows = entries()
    for _, name, description in rows[-LIST_MAX:]:
        print(f"{name} -- {description}")
    clipped = len(rows) - LIST_MAX
    if clipped > 0:
        print(f"+ {clipped} more entries")


def verb_show(name):
    if not SLUG.fullmatch(name):
        die(f"{name!r} is not a memory name")
    path = entry_path(name)
    if not path:
        die(f"{name} is not a plain file inside the store")
    try:
        with open(path, errors="replace") as fh:
            sys.stdout.write(fh.read())
    except OSError:
        die(f"{name} is not in the store")


def verb_taint():
    """This lane and the marker files living in it, from anywhere.

    The whole directory listing, `armed` included, because these are the
    filenames on disk and a summary would be this program's opinion about a
    refusal that is supposed to be inspectable.
    """
    here = lane()
    if not here:
        print("not in a lane")
        return
    try:
        names = sorted(os.listdir(os.path.join(TAINT_DIR, here)))
    except OSError:
        names = []
    print(f"{here} -- {', '.join(names) if names else 'no markers'}")


# -- the write verbs ----------------------------------------------------------

def write_verb(verb, name, description, body):
    """Lane, lock, taint, validate, the op and its line, release, print.

    That order is the whole design in one function, and two pieces of it are
    load-bearing beyond looking tidy: the taint check happens inside the lock,
    and the op and its journal line are ordered so that whichever one a kill
    takes, the survivor is the recoverable half -- the entry first when a verb
    creates, the line first when a verb destroys.
    """
    here = lane()
    if not here:
        die("the write verbs run inside a session, from its own lane "
            f"directory; this cwd is not one of {', '.join(LANES)}")
    if here not in WRITE_LANES:
        die("the job lane reads memory and does not write it: say what you "
            "learned in your result, and the talk lane saves it")

    # The heredoc form, which is how a body with quotes or newlines arrives.
    # Read before the lock: there is no reason to hold the store while waiting
    # on a pipe that the shell may not have finished feeding.
    if body == "-":
        body = sys.stdin.read()

    try:
        os.makedirs(MEM_DIR, exist_ok=True)
    except OSError as exc:
        die(f"cannot open the store: {exc.strerror or exc}")

    fd = take_lock()
    try:
        armed_or_die(here)

        # The pattern first and the path second, in that order: a name the
        # pattern refuses is a name that has no business being joined onto
        # anything, and realpath raises on some of what it would be handed.
        if not SLUG.fullmatch(name):
            die(f"{name!r} is not a memory name: lowercase letters, digits "
                "and hyphens, up to 64 characters")
        path = entry_path(name)
        if not path:
            die(f"{name} is not a plain file inside the store")

        if verb != "forget":
            description = description.strip()
            body = body.strip()
            if not description:
                die("the description is empty; it is the line the index "
                    "injects, so it is the part that has to say something")
            if len(description) > DESC_MAX:
                die(f"the description is over {DESC_MAX} characters; the "
                    "index carries it as one line, so say it shorter")
            if "\n" in description or "\r" in description:
                die("the description is one line; the detail goes in the body")
            if not body:
                die("the body is empty")
            if len(body) > BODY_MAX:
                die(f"the body is over {BODY_MAX} characters; one fact per "
                    "entry, and a fact this long is either two facts or a "
                    "file the session should Read instead")

        # The plain conversation id -- the chat thread, the Jarvis day -- from
        # MEMORY_THREAD and not from the turn id the gate matches. The runners
        # mint MEMORY_TURN_ID fresh at every spawn, so stamping that here would
        # give each entry a value that identifies one process and nothing a
        # person can look up afterwards. A lane that exported neither key
        # leaves a dash. Whitespace is collapsed because this lands in
        # frontmatter, where a newline in a value would forge a field.
        thread = " ".join(
            (os.environ.get("MEMORY_THREAD") or "").split()) or "-"
        now = stamp()
        exists = os.path.exists(path)

        if verb == "remember":
            if exists:
                die(f"{name} already exists -- retry once as revise")
            if entry_count() >= ENTRY_MAX:
                die(f"the store is full at {ENTRY_MAX} entries -- forget one "
                    "that no longer earns its place, then remember this")
            before, after = None, {"description": description, "body": body}
            write_entry(path, render_entry(name, description, here, thread,
                                           now, now, body))
            journal(here, verb, name, before, after,
                    f"{name} is written but not journaled")
            done = f"remembered {name}"

        elif verb == "revise":
            if not exists:
                die(f"{name} does not exist -- retry once as remember")
            try:
                meta, old = read_entry(path)
            except OSError as exc:
                die(f"cannot read {name}: {exc.strerror or exc}")
            # `created` is the one field a revise keeps: lane and thread say
            # who last touched the entry, and created says when the fact
            # entered the store, which a rewrite does not change.
            before = {"description": meta.get("description", ""),
                      "body": old.strip()}
            after = {"description": description, "body": body}
            write_entry(path, render_entry(name, description, here, thread,
                                           meta.get("created") or now, now,
                                           body))
            journal(here, verb, name, before, after,
                    f"{name} is written but not journaled")
            done = f"revised {name}"

        else:
            if not exists:
                die(f"{name} is not in the store")
            try:
                meta, old = read_entry(path)
            except OSError as exc:
                die(f"cannot read {name}: {exc.strerror or exc}")
            before = {"description": meta.get("description", ""),
                      "body": old.strip()}
            # The one verb whose line goes first. Everywhere else the entry is
            # the durable thing and the line describes it; here the line is
            # about to be the only copy of what the entry said, so a kill
            # between the two must leave the line and not the deletion. The
            # cost is a journaled op that then failed, which re-runs cleanly
            # and is visible as an entry the store still has; the other order
            # costs a body nothing kept, which is the one loss undo cannot
            # cover.
            journal(here, verb, name, before, None,
                    f"cannot journal the forget, so {name} is still here")
            try:
                os.remove(path)
            except OSError as exc:
                die(f"cannot forget {name}: {exc.strerror or exc}")
            done = f"forgot {name}"

        rotate()
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)

    # The one line of stdout, so the session can tell the reader what it did.
    print(done)


def main():
    if len(sys.argv) < 2:
        die(USAGE)
    verb = sys.argv[1]
    args = sys.argv[2:]

    if verb == "list":
        if args:
            die("usage: memory list")
        return verb_list()
    if verb == "show":
        if len(args) != 1:
            die("usage: memory show <name>")
        return verb_show(args[0])
    if verb == "taint":
        if args:
            die("usage: memory taint")
        return verb_taint()

    if verb == "forget":
        if len(args) != 1:
            die("usage: memory forget <name>")
        return write_verb(verb, args[0], None, None)
    if verb in ("remember", "revise"):
        if len(args) != 3:
            die(f"usage: memory {verb} <name> <description> <body|->")
        return write_verb(verb, args[0], args[1], args[2])

    die(f"no such verb: {verb!r}; {USAGE}")


if __name__ == "__main__":
    main()
