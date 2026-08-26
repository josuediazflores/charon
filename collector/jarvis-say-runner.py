#!/usr/bin/env python3
"""Jarvis talk lane. Drains the day's say spool once, then exits.

Deploys to /home/pi/halftone-chat/bin/jarvis-say-runner.py and is started by
halftone-jarvis-say.path the moment jarvis/.say stops being empty. **There is no
polling loop and no daemon here.** The path unit is the clock: it fires when a
turn lands, this drains everything waiting, and the box goes back to running
nothing at all. An idle Pi should be idle, and a loop that wakes every ten
seconds to find an empty directory is a loop that runs 8,640 times a day to do
nothing.

This is `chat-runner.py` with the day record under it instead of a thread, and
that file is not modified, not imported and not shared with -- see the contract
under "Why there are two lanes". The stream-json parse, the flock, the
half-second repaint and the process-group kill are copied because they are
already right, and a second opinion about any of them would be a bug farm. What
is genuinely new here is three things:

  * **The usage numbers are kept.** `chat-runner.py` reads `subtype`, `result`,
    `duration_ms` and `is_error` off the CLI's final `result` event and drops
    `usage` on the floor. Every context number in the Jarvis contract comes off
    that field, so this reads it and writes `context`. It is never estimated
    from anything, ever, by anyone -- see `context_from_usage`.
  * **A cleared session id is seeded from a digest, not from the transcript.**
    `POST /v1/jarvis/compact` nulls `claude_session_id` and leaves `turns`
    completely alone, which is what makes the transcript and the context two
    different objects. What re-establishes continuity across that cut is
    `prior_context`, and nothing else does.
  * **The digest itself is produced here.** The compact route writes the
    `compactions` entry and never blocks on a model; the entry arrives with no
    `kept`, and the next turn through this file fills it in. The ordering is
    the interesting part and it is argued at `answer`.

The write contract with the collector, which is the thing to not break:

    collector writes  the day record, the user turn, job cards, notice turns,
                      the model, the spool entry, the stop flag, and every
                      field of a `compactions` entry EXCEPT `kept`
    THIS writes       status, error, partial, the assistant turn, the claude
                      session id, `context`, the `kept` of the newest
                      compaction, and the deletion of both flags

One writer per field, `kept` included -- it is a field of the collector's
object, but the collector cannot produce it without waiting on a model, which
is the one thing its route may not do. A spool entry means "unanswered", and
only the process that answered it may say otherwise, so a drain that dies
halfway leaves a queue that is still exactly true and the next fire picks up
where it stopped.

The lock is `jarvis/.say.lock`, deliberately not `threads/.runner.lock`: a turn
here must never be blocked by, or block, a conversation in the Chat tab. Two
locks, two units, two processes.

The session runs in env/, whose .claude/settings.json is a default-deny
allowlist: reads, greps, and a named list of read-only shell commands. See
env/README.md for what is on it and why. That file is the permission boundary
and it is loaded from the working directory, which is why the unit's
WorkingDirectory= line is a security control rather than a convenience.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import collections
import fcntl
import json
import os
import queue
import re
import signal
import subprocess
import sys
import threading
import time
from datetime import datetime

# The same tree the chat runner works in, and read from the same variable
# rather than a `JARVIS_BASE` of its own. `jarvis/` is a sibling of `threads/`
# under one base_dir in the collector's config, and two environment variables
# naming one directory is an arrangement whose only possible future is the two
# of them disagreeing on a Tuesday.
BASE = os.environ.get("CHAT_BASE") or "/home/pi/halftone-chat"
JARVIS_DIR = os.path.join(BASE, "jarvis")
DAYS_DIR = os.path.join(JARVIS_DIR, "days")
SAY_DIR = os.path.join(JARVIS_DIR, ".say")
STOP_DIR = os.path.join(JARVIS_DIR, ".stop")
LOCK_PATH = os.path.join(JARVIS_DIR, ".say.lock")
# `sayenv/`, not the chat tab's `env/` and not the work lane's `jobenv/`.
# The three surfaces used to share one directory, which meant one permission
# file -- and the write split is enforced by nothing except which settings.json
# the session loads from its working directory. Three surfaces, three envs,
# three walls.
#
# The split as it stands (2026-08-17, amended 2026-08-25): jobs may write this
# box; talk writes exactly one thing, its own memory store, through bin/memory
# and nothing else. That one exception is a whole mechanism rather than an
# allow line -- a CLI that owns the journal and the caps, plus the taint gate
# below -- and the work lane is on the other side of it: jobenv is refused the
# write verbs outright. See the taint gate section below, and memory-tool.py's
# own docstring, which states the whole contract.
ENV_DIR = os.path.join(BASE, "sayenv")
CLAUDE = os.environ.get("CHAT_CLAUDE") or os.path.expanduser("~/.local/bin/claude")

# A day id, asserted again here. Tighter than the chat runner's slug because a
# day is a date and nothing else, and a spool entry's name becoming a path is
# exactly the shape of bug worth refusing structurally rather than reasoning
# about. Not checked for being a real calendar date: this decides what may be
# joined onto a path, and 2026-99-99 is harmless as a filename.
DAY_SHAPE = re.compile(r"\d{4}-\d{2}-\d{2}")

# What the collector is willing to accept as a model, restated. The runner
# reads this value off a file rather than off a request, so it is checked again
# before it becomes argv: the collector is the only writer of the field today,
# and "today" is not a property worth building an exec on.
MODELS = ("sonnet", "opus")

# The window each model is given, for `context.window`. Written into the record
# per turn rather than left for the console to know, because the console is
# forbidden from computing anything about context -- a window it had to carry in
# its own source is a number that goes quietly wrong the day this changes.
#
# 200k is the real figure for both today; the long-context beta is not enabled
# on this box. If it ever is, this dict is the one line that has to move, and
# every meter drawn from a day answered before the change stays truthful because
# the window it was measured against travelled with it.
MODEL_WINDOWS = {"sonnet": 200_000, "opus": 200_000}
DEFAULT_WINDOW = 200_000

# One turn, one wall clock. Ten minutes, as in the chat runner and for its
# reason: this session has tools and a day's conversation behind it, and a
# timeout that fires on real work is a feature that looks broken.
TIMEOUT_S = 600

# The fold gets its own, much shorter wall. It is one bounded summarisation of
# at most FOLD_MAX_CHARS with a single turn and no tools, so three minutes is
# already generous -- and the person waiting is waiting for an answer, not for
# the housekeeping standing in front of it. A fold that overruns is abandoned
# and the turn is answered from the raw transcript instead; see `answer`.
DIGEST_TIMEOUT_S = 180

# How often the record is rewritten while text is streaming in. Every delta
# would be a file write per token; half a second is faster than a reader can
# perceive and slow enough that a long answer costs tens of writes rather than
# thousands. The console polls at 1s while a turn is live, so this is
# comfortably under its own resolution.
PARTIAL_EVERY_S = 0.5

# How often the reader thread is checked when nothing is arriving. This is the
# resolution of the stop flag and of the wall clock, and it is deliberately
# much finer than either: a stop that took two seconds to land would feel
# ignored.
POLL_S = 0.25

# How much of the day gets quoted into a session that cannot be resumed. Only
# reached before the first compaction, or when a fold has failed -- once a
# digest exists it is the seed and this bound stops mattering.
FOLD_MAX_CHARS = 16000

# And how long the digest that replaces it may be. Small on purpose: the digest
# is re-sent at the head of every fresh session for the rest of the day, so a
# generous cap here turns the thing that was built to save context into the
# context problem. Stated in the prompt and enforced on the way in, because a
# model overrunning a character budget by a fifth is ordinary.
DIGEST_MAX_CHARS = 6000

# What the console will draw under an answer. Model output rendered in a
# dashboard, so it is bounded on the way in rather than on the way out.
TOOLS_MAX = 40
# How many memory *writes* may land past that ceiling in one turn. The
# exemption exists because a write issued late in a tool-heavy turn -- exactly
# the long research turns most likely to run one -- would otherwise be the call
# that silently fell off the end of the only surface a person watches. The
# bound exists because an unbounded exemption is itself a way to flood the
# list: eight curations is already far more than a real turn does, and past it
# a write takes its chances with every other tool call. Read verbs get no
# exemption at all -- `list` changes nothing, so a `list` that fell off the end
# cost the record nothing.
MEMORY_TOOLS_EXEMPT = 8
TOOL_ITEM_MAX = 120

# How much streamed text is held before it stops being written to the record.
# A session that decides to print a 10 MB file would otherwise turn a day into
# a document no browser can open. What is cut is announced rather than hidden.
PARTIAL_MAX_CHARS = 200_000

# What `partial` says while the fold runs. It goes in the same field the answer
# streams into, which is a small liberty with a field the contract calls "the
# streaming text of the in-flight turn" -- and it is taken for the reason the
# streaming exists at all: a reader who pressed send and is looking at a blank
# panel cannot tell a fold from a wedge, and the fold is the slowest thing that
# ever happens between the two.
FOLD_NOTE = "folding the day so far…"

_lock_fd = None


def log(msg):
    """One line to stderr, which is journald under the unit."""
    sys.stderr.write(f"{datetime.now().isoformat(timespec='seconds')}  {msg}\n")
    sys.stderr.flush()


def stamp():
    """Local ISO seconds, the format every other file in this system uses."""
    return datetime.now().isoformat(timespec="seconds")


def take_lock():
    """Exclusive, non-blocking. Held for the life of the process.

    A path unit re-fires while its directory is non-empty, so a second start
    landing on top of a running drain is ordinary rather than exceptional --
    and two runners sharing a spool would answer the same turn twice, into the
    same file, with two sessions writing `partial` over each other. Exiting 0
    rather than 1: being already busy is a correct outcome, and a failed unit
    here would need a human to clear it for no reason at all.

    **This is `jarvis/.say.lock` and never `threads/.runner.lock`.** The two
    lanes are separate processes precisely so that a turn here cannot be held
    behind a conversation in the Chat tab, and sharing a lock file would undo
    the whole arrangement while looking like a tidy-up.
    """
    global _lock_fd
    os.makedirs(JARVIS_DIR, exist_ok=True)
    _lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    return True


# -- the day record -----------------------------------------------------------

def day_path(day):
    return os.path.join(DAYS_DIR, f"{day}.json")


def read_day(day):
    """The record, or None if it is not one. Never raises."""
    try:
        with open(day_path(day)) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not isinstance(doc.get("turns"), list):
        return None
    return doc


def write_day(day, doc):
    """tmp + os.replace, so the collector and the console never read a half
    written record. Returns True on success.

    This is called every half second while an answer streams, which is the
    reason it is a replace rather than a rewrite in place: the console is
    fetching this file on a 1s poll, and the two would otherwise collide
    several times per answer.
    """
    path = day_path(day)
    tmp = f"{path}.tmp"
    try:
        os.makedirs(DAYS_DIR, exist_ok=True)
        with open(tmp, "w") as fh:
            json.dump(doc, fh, indent=2)
        os.replace(tmp, path)
        return True
    except OSError as exc:
        log(f"{day}: cannot write the day record: {exc}")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def unspool(day):
    """Drop the say entry. Always attempted: an entry left behind is a turn
    this process would answer again on the next fire."""
    try:
        os.remove(os.path.join(SAY_DIR, day))
    except FileNotFoundError:
        pass
    except OSError as exc:
        log(f"{day}: cannot clear the spool entry: {exc}")


def stop_path(day):
    return os.path.join(STOP_DIR, day)


def stop_requested(day):
    return os.path.exists(stop_path(day))


def clear_stop(day):
    """Drop the stop flag. The runner's alone, like the spool entry, and for
    the same reason: the collector raises it and only the process that acted on
    it can say it has been acted on. A flag left behind would stop the NEXT
    turn, which is a stop button with a delayed fuse."""
    try:
        os.remove(stop_path(day))
    except FileNotFoundError:
        pass
    except OSError as exc:
        log(f"{day}: cannot clear the stop flag: {exc}")


def queued():
    """Every day waiting, oldest arrival first.

    By mtime rather than by name, and the gap is wider here than in the chat
    runner: a thread id sorts chronologically to the minute, but a day id sorts
    to the day, so two entries in this directory are in the right order by name
    only by accident of the calendar. mtime is when the turn was filed, which
    is the order it is owed in.
    """
    out = []
    try:
        with os.scandir(SAY_DIR) as entries:
            for entry in entries:
                if not DAY_SHAPE.fullmatch(entry.name):
                    continue
                try:
                    out.append((entry.stat().st_mtime, entry.name))
                except OSError:
                    continue
    except OSError:
        return []
    out.sort()
    return [name for _, name in out]


# -- the transcript -----------------------------------------------------------

def say_turns(doc):
    """Just the conversation, oldest first. Everything else is skipped.

    Three kinds share `turns` and only one of them is something somebody said.
    A `job` card is a pointer into the work lane's own record, and quoting one
    into a session would put a half-copied job into a conversation that never
    mentioned it. A `notice` is worse: it is the collector's line about context
    running out, and folding that back in as context is the exact pathology the
    contract writes it locally to avoid.

    An unrecognised `kind` is skipped rather than fatal, which is the rule the
    contract puts on the console and which applies here with more force -- this
    one is building a prompt out of it.
    """
    return [t for t in (doc.get("turns") or [])
            if isinstance(t, dict) and t.get("kind") == "say"]


def last_user_text(doc):
    """The question this turn owes an answer to, or "".

    Backwards through the say turns: the collector appends the user turn and
    then files the spool entry, so the newest one is always the unanswered one.
    """
    for turn in reversed(say_turns(doc)):
        if turn.get("role") == "user":
            return str(turn.get("text") or "").strip()
    return ""


# -- memory -------------------------------------------------------------------

# The store the two talk lanes keep about the operator: one durable fact per
# file, written only through bin/memory. A sibling of jarvis/ under the same
# base, so a harness pointing CHAT_BASE at a temp tree points this at one too.
# **Nothing in this file writes into memory/ except under .taint/** -- the
# entries and the journal belong to the tool, which is where the flock, the
# caps and the gate all live.
#
# One copy per talk runner, the same arrangement `tool_summary` and
# `StreamState` already have here: the chat runner is not imported and not
# shared with, and a module the three of them reached into would be a fourth
# thing to deploy in step with them.
MEMORY_DIR = os.path.join(BASE, "memory")
MEMORY_JOURNAL = os.path.join(MEMORY_DIR, ".journal.jsonl")
MEMORY_BIN = os.path.join(BASE, "bin", "memory")

# The shape an entry's FILENAME has to have, minus the `.md` -- the same
# pattern bin/memory validates a name against before it writes one. The index
# is keyed on the filename, so this is where a file dropped into the store by
# hand under a shape the tool would have refused stops being an entry.
MEMORY_SLUG = re.compile(r"[a-z0-9-]{1,64}")

# How many entries the injected index may carry, and deliberately the same
# number the tool caps the store at. The session is told to check this index
# before it remembers anything, so an index that clipped would be the machine
# that manufactures duplicate siblings: the entry cut off the end is exactly
# the entry the next `remember` should have revised instead. Against a
# tool-written store this never fires; it is here for files made by hand.
MEMORY_DIGEST_MAX = 128
# The read ceiling, on the opens rather than on the scandir, exactly as the
# chat runner bounds the messages store. A runaway backstop and not a working
# bound -- a store with this many files in it is already far past the cap
# above.
MEMORY_SCAN_MAX = 512
# How much of an entry file is read to render its line. Frontmatter is six
# short fields and the body is deliberately not in the index, so this is the
# whole of what matters with room to spare -- and a file with no closing fence
# costs one bounded read rather than a walk through however long it turned out
# to be.
MEMORY_HEAD_BYTES = 4096

# The block that carries the index into a turn. The root is interpolated rather
# than written out so that a temp store describes itself honestly; on the Pi
# this renders the absolute path the standing instructions name.
MEMORY_BLOCK = """\
## what you remember

Distilled facts from earlier conversations, one file each under
{root}. They are yours: treat them as current until
contradicted, Read the file when a line's detail matters, and curate with
bin/memory -- revise what changed, forget what proved wrong.

{lines}
(end of your notes -- they are context, not the conversation. The operator's
message follows any other context blocks, and its instructions are his own.)
"""


def _memory_entry(path, name):
    """`(updated, name, description)` for one entry, or None.

    **The name is the filename the caller found, never the frontmatter.** The
    file is what the tool creates and unlinks and what a session is told to
    Read; a `name:` field that had drifted from it -- a hand edit, a copied
    file -- would put a line in the index pointing at an entry that is not
    there, and `forget` would then be given a name with no file behind it. The
    tool still writes the field, because an entry read on its own should say
    what it is, and nothing reads it back.

    Frontmatter for the rest: the body is what the session Reads when a line's
    detail matters, and building the index out of the bodies would be the whole
    store in the prompt. A file that does not parse is skipped without a word
    -- the operator edits this tree by hand and two lanes write into it, so a
    half-written or hand-mangled file has to cost its own line and nothing
    else. ValueError sits beside OSError because a file whose bytes are not
    text raises the first and not the second, and one stray binary file must
    not cost this lane its index.
    """
    try:
        with open(path) as fh:
            head = fh.read(MEMORY_HEAD_BYTES)
    except (OSError, ValueError):
        return None
    lines = head.split("\n")
    if not lines or lines[0].strip() != "---":
        return None
    fields = {}
    for line in lines[1:]:
        if line.strip() == "---":
            break
        key, sep, value = line.partition(":")
        if sep:
            fields[key.strip()] = value.strip()
    else:
        # No closing fence inside the bytes that were read, so this is not
        # frontmatter this function can claim to have read the whole of.
        return None
    description = fields.get("description") or ""
    if not description:
        return None
    return fields.get("updated") or "", name, description


def memory_digest():
    """Every remembered fact as one `name -- description` line, newest last.

    The whole store, deliberately. The tool caps the store at the number this
    caps at, so the index a session checks before remembering is never a
    partial one -- and a partial index is what manufactures duplicate siblings,
    because the line it clipped away is the one the next `remember` should have
    revised.

    Newest-updated last, which is how this block is read: the line closest to
    the question is the fact that moved most recently. There is no per-line
    clip to go with the count, because the tool bounds a description at 200
    characters and a name at 64, so a line is short by construction and a clip
    here would only ever cut a hand-written one in half.

    An entry is named by its file and filtered by its file: the store is a
    directory anybody can drop a file into, and a name the tool would have
    refused to write is a name this block must not hand a session.

    Returns "" for an empty or absent store, which suppresses the whole block:
    a box with nothing remembered yet says so by being silent rather than by
    carrying an empty heading. Never raises.
    """
    found = []
    try:
        with os.scandir(MEMORY_DIR) as entries:
            for entry in entries:
                # Dotfiles are the store's own machinery -- the journal, the
                # lock, the taint tree -- and none of them is an entry.
                if entry.name.startswith(".") or not entry.name.endswith(".md"):
                    continue
                name = entry.name[:-3]
                if not MEMORY_SLUG.fullmatch(name):
                    continue
                try:
                    found.append((entry.stat().st_mtime, name, entry.path))
                except OSError:
                    continue
    except OSError:
        return ""
    found.sort(key=lambda row: row[0], reverse=True)

    rows = []
    for _, name, path in found[:MEMORY_SCAN_MAX]:
        entry = _memory_entry(path, name)
        if entry is not None:
            rows.append(entry)

    rows.sort()
    # The newest survive a store somebody hand-filled past the cap: the end of
    # the list is the part that is still true.
    rows = rows[-MEMORY_DIGEST_MAX:]
    return "\n".join(f"{name} -- {description}"
                     for _, name, description in rows)


def memory_context():
    """The standing block that goes at the head of a turn, or "".

    Injected here rather than written into sayenv/CLAUDE.md, where every other
    standing instruction lives, because this one's *contents* move underneath
    the session: CLAUDE.md is loaded once per session, and this lane's session
    is a whole day long -- it would carry the index as it stood at breakfast,
    including a stale account of the entries it had itself written since.

    The block never enters `turns`. It is built at the wire and thrown away, so
    `say_turns`, the fold and the context meter are untouched by it -- and what
    the meter counts on a turn that did carry it is real context, correctly.
    """
    lines = memory_digest()
    if not lines:
        return ""
    return MEMORY_BLOCK.format(root=MEMORY_DIR, lines=lines)


def last_assistant_turn(doc):
    """The newest assistant say turn, or None when there is not one yet.

    Say turns only, for `say_turns`' reason: a job card and a context notice
    are things the collector filed into this array, not moments this assistant
    was handed anything -- and neither of them carries a `memory_seen`, because
    neither of them was ever handed the block.
    """
    for turn in reversed(say_turns(doc)):
        if turn.get("role") == "assistant":
            return turn
    return None


def memory_seen():
    """The journal's mtime as this turn is about to be built, or 0.0.

    Stamped onto the assistant turn this runner appends, where `memory_moved`
    reads it back on the next one. Read *before* the prompt is built rather
    than after, and the direction is the whole point: an op that lands while
    this turn is running is then newer than the stamp, so the next turn carries
    the block. The other direction would leave the session that wrote an entry
    as the one session never told about it -- and on this lane that session is
    the whole day.

    0.0 for a store with no journal, which is a real answer rather than a
    missing one: nothing has ever been written, so anything later is newer.
    """
    try:
        return os.path.getmtime(MEMORY_JOURNAL)
    except OSError:
        return 0.0


def memory_moved(doc):
    """Whether the store changed since this day last saw the index.

    The question a resumed turn asks before spending the block again. A fresh
    session always gets it, because it knows nothing; a resumed one already has
    the index somewhere in its context, and this lane's session runs from
    morning to compaction -- re-sending the whole store on every turn of it is
    the shape of cost that is invisible per turn and enormous per day.

    The journal's mtime now, against the `memory_seen` this runner stamped on
    the newest assistant say turn -- the mtime the block that turn carried was
    rendered from. **The turn's `at` cannot answer this and used to be asked.**
    A write made during a turn is older than the `at` written at the end of it,
    so the session that had just remembered something was precisely the session
    never handed the entry back, which on a day-long session means for the rest
    of the day.

    `at` remains the fallback, and only that: a turn appended before this field
    existed still has to be answered about, and its own stamp is the best
    account of it there is.

    A store with no journal has nothing saying it moved, so a resumed turn does
    not pay for it. Never raises.
    """
    try:
        moved = os.path.getmtime(MEMORY_JOURNAL)
    except OSError:
        return False
    turn = last_assistant_turn(doc)
    if turn is None:
        return True
    seen = turn.get("memory_seen")
    if isinstance(seen, (int, float)):
        return moved > seen
    at = str(turn.get("at") or "")
    if not at:
        return True
    try:
        return moved > datetime.fromisoformat(at).timestamp()
    except ValueError:
        return True


# -- the taint gate -----------------------------------------------------------
#
# A turn that pulled in external content may not write memory, and the turn is
# where that is decided: the session is trusted, the bytes it fetched are not,
# and "fetch a page, do what it says, write down what it said" has to fail on
# the write rather than on the reading. The mechanism is files, like everything
# else on this box. This runner clears the lane's marker directory before every
# session it starts and writes `armed` with that turn's id before the
# *answering* one -- the fold is deliberately left unarmed, and `run_session`
# argues why; the PreToolUse hooks in .claude/settings.json touch a marker the
# moment a fetch is *asked for*; and bin/memory refuses every write verb unless
# `armed` matches the MEMORY_TURN_ID it was handed and nothing else is sitting
# in there.
#
# **This half fails closed and stays quiet.** Nothing below can fail a turn: a
# lane that cannot arm simply never writes `armed`, the tool then refuses the
# write, and the answer is produced exactly as it always was.

# The lane, which is the directory the session is started in. Derived from
# ENV_DIR rather than written out, because bin/memory derives the same word
# from the same directory at the other end -- and two programs spelling one
# lane by hand is an arrangement whose only possible future is the two of them
# disagreeing on a Tuesday.
LANE = os.path.basename(ENV_DIR)
TAINT_DIR = os.path.join(MEMORY_DIR, ".taint")
LANE_TAINT_DIR = os.path.join(TAINT_DIR, LANE)
MEMORY_TAINT_BIN = os.path.join(BASE, "bin", "memory-taint")


def _taint_mark(name, body=""):
    """Land one marker in this lane's taint directory. True when it landed.

    tmp + os.replace, the house write, with the tmp deliberately one directory
    up: bin/memory refuses a write when anything other than `armed` is sitting
    in the lane directory, so a half-written file inside it would read as a
    taint marker of its own. The one place a marker must never be staged is the
    directory it is landing in.
    """
    path = os.path.join(LANE_TAINT_DIR, name)
    tmp = os.path.join(TAINT_DIR, f".{LANE}-{name}.tmp")
    try:
        with open(tmp, "w") as fh:
            fh.write(body)
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def memory_armable():
    """Whether the gate is actually installed in this lane.

    Two facts, both cheap, both checked at every spawn rather than trusted from
    a deploy: this lane's settings.json has to carry the hooks that mark a
    fetch, and the program those hooks run has to be there and be executable.
    Without both, no marker would ever be written no matter what the session
    fetched, and `armed` on its own would then read as permission -- so a
    deploy that landed half of this feature disarms the gate closed rather than
    open.
    """
    try:
        with open(os.path.join(ENV_DIR, ".claude", "settings.json")) as fh:
            settings = fh.read()
    except OSError:
        return False
    if "bin/memory-taint" not in settings:
        return False
    return os.access(MEMORY_TAINT_BIN, os.X_OK)


def clear_taint():
    """Empty this lane's marker directory. True when it is empty afterwards.

    Its own function because the two kinds of session this lane starts want
    different halves of the old one: both clear, only one arms. Markers from
    earlier turns are cleared rather than aged out -- the turn id in `armed`
    already makes a stale marker harmless, and a directory that only ever grows
    is a directory somebody has to explain later. A missing tree self-heals
    here, so a half-created deploy costs one turn and not every turn.
    """
    try:
        os.makedirs(LANE_TAINT_DIR, exist_ok=True)
        for name in os.listdir(LANE_TAINT_DIR):
            try:
                os.remove(os.path.join(LANE_TAINT_DIR, name))
            except OSError:
                pass
    except OSError as exc:
        log(f"cannot clear {LANE_TAINT_DIR}: {exc}")
        return False
    return True


def arm_memory(turn_id):
    """Clear this lane's markers and arm the gate for exactly this session.

    One function rather than three lines at the Popen because the order is the
    whole of it: clear, check, arm, and only then start the session. This lane
    has no tag machinery, so there is nothing to pre-seed here -- the chat
    runner's copy carries that step and this one deliberately does not grow a
    parameter it would never be passed.

    The two checks in front of the arming are what makes a half-landed deploy
    fail closed rather than open: without the hooks or the program they run, no
    marker would ever be written no matter what the session fetched.

    Never raises and never fails the turn. Every failure here costs the session
    its write verbs for one turn, which is exactly what happens on a box that
    has no store at all.
    """
    if not clear_taint():
        return
    if not memory_armable():
        return
    _taint_mark("armed", turn_id)


# -- continuity across a compaction -------------------------------------------
#
# `POST /v1/jarvis/compact` sets `claude_session_id` to null and leaves `turns`
# completely alone. That is the whole mechanism: after it, the transcript and
# the context are no longer the same object. The transcript stays whole because
# it is the record of the day; what gets *sent* is the digest plus whatever came
# after it. Everything below is the "what gets sent" half, and it is the only
# thing standing between a compaction and an assistant that has forgotten the
# morning.

def compactions(doc):
    """The compaction entries, oldest first, ignoring anything malformed."""
    return [c for c in (doc.get("compactions") or []) if isinstance(c, dict)]


def pending_compaction(doc):
    """The newest compaction still owed a digest, or None.

    Only the newest is ever considered. An older entry with no `kept` is one
    this runner already declined to fill -- there was nothing in front of it to
    fold -- and going back for it now would summarise the wrong stretch of the
    day, because the material for a digest is everything up to *its own* `at`
    and that stretch is already inside the newer digest.
    """
    entries = compactions(doc)
    if not entries:
        return None
    newest = entries[-1]
    kept = newest.get("kept")
    if isinstance(kept, str) and kept.strip():
        return None
    return newest


def quote(turns):
    """Say turns as a quoted block, newest-first while filling, then in order.

    The end of a conversation is the part a re-started session needs, and a day
    long enough to be truncated is a day whose opening has already been
    answered.
    """
    kept = []
    total = 0
    for turn in reversed(turns):
        text = str(turn.get("text") or "").strip()
        if not text:
            continue
        label = "You" if turn.get("role") == "user" else "Assistant"
        block = "\n".join(f"> {line}" for line in f"{label}: {text}".splitlines())
        total += len(block)
        if total > FOLD_MAX_CHARS:
            break
        kept.append(block)
    if not kept:
        return ""
    kept.reverse()
    return "\n>\n".join(kept)


def prior_context(doc, until=None):
    """Everything a fresh session must be told, as prose. "" when nothing.

    **This is what re-establishes continuity after a compaction, and it is the
    only thing that does.** The newest digest available is put at the head, and
    only the turns that came after it are quoted underneath -- so a day that has
    been folded three times sends one digest and a handful of exchanges rather
    than three hours of transcript. Before the first compaction there is no
    digest and the whole day is quoted, which is the same function with the
    boundary at midnight.

    `until` bounds it in time and exists for exactly one caller: the fold
    itself, which needs the material a digest is made from, which is the seed
    the session would otherwise have been given at the moment of the
    compaction. So the digest for the second compaction is written out of the
    first digest plus what happened between them, and the raw morning is read
    once a day at most.

    The final say turn is always dropped: it is the user turn being answered
    now, and it arrives on stdin under this.
    """
    turns = say_turns(doc)[:-1]

    boundary = ""
    digest = ""
    folded_at = ""
    for entry in compactions(doc):
        kept = entry.get("kept")
        at = str(entry.get("at") or "")
        if not (isinstance(kept, str) and kept.strip()):
            continue
        if until is not None and at > until:
            # A digest written after the point being reconstructed. It contains
            # the future of this prompt and cannot be its past.
            continue
        boundary = at
        digest = kept.strip()
        folded_at = at

    after = []
    for turn in turns:
        at = str(turn.get("at") or "")
        # A turn with no readable `at` cannot be placed, so it is kept rather
        # than dropped: including it costs tokens, dropping it costs the
        # assistant something that was actually said to it.
        if at and boundary and at <= boundary:
            continue
        if until is not None and at and at >= until:
            continue
        after.append(turn)

    quoted = quote(after)

    if digest:
        head = ("## earlier today, folded\n\n"
                f"{digest}\n\n"
                "The notes above summarise this conversation up to "
                f"{folded_at or 'earlier'}, written when it was folded to make "
                "room. The turns they replaced are still on the day's record; "
                "they are not in this session, so do not refer to them as if "
                "they were said here.\n")
        if not quoted:
            return head
        return f"{head}\n## since then\n\n{quoted}\n"

    if not quoted:
        return ""
    return ("## earlier today\n\n"
            f"{quoted}\n\n"
            "The exchange above happened in a previous session that has since "
            "been retired. Re-check anything it asserts about the state of the "
            "box before relying on it.\n")


def should_resume(doc):
    """Whether this turn continues its own session. Returns (bool, why).

    One condition, and deliberately not the chat runner's two. That one also
    retires a session past forty user turns, as a crude stand-in for a context
    limit it has no way to measure. **This lane measures it exactly**, off the
    CLI's own usage numbers, warns at 50/75/90% and retires the session when a
    person presses compact. Keeping the turn-count rule as well would mean the
    session could be replaced by a threshold nobody was shown, and the
    replacement would leave no `compactions` entry, so no digest would be
    written and continuity would fall back to quoting the raw day.

    So the only question is whether there is a session id, which is precisely
    the question the compact route answers by deleting it.

    The `why` is logged, because "it started a new session" is otherwise an
    invisible decision that changes what the answer knows.
    """
    if not doc.get("claude_session_id"):
        entries = compactions(doc)
        if entries:
            return False, f"session was folded {len(entries)}x today"
        return False, "no session yet"
    return True, "resuming today's session"


def build_prompt(doc, text, resuming):
    """What goes in on stdin.

    No system prompt is assembled here: the session's standing instructions
    live in env/CLAUDE.md, which claude loads from its working directory on
    every session including a resumed one. Prepending them to each turn as well
    would put two copies of the same instructions in the context, and the
    resumed copy would be the one that had drifted.

    The memory block is the exception, and it is one because it is standing
    context whose *contents* move underneath the session -- see
    `memory_context`. It goes in on **both** shapes, and on a resumed turn only
    when the store has actually changed since this day last saw it, which is
    what keeps a day-long session from paying for the whole index every time
    somebody says a sentence to it. See `memory_moved`.
    """
    # Built only when it is going to be sent: the scan is cheap, but a resumed
    # turn that is not carrying the block has no reason to open the store.
    mem = memory_context() if (not resuming or memory_moved(doc)) else ""
    if resuming:
        return f"{mem}\n{text}" if mem else text
    seed = prior_context(doc)
    body = f"{seed}\n{text}" if seed else text
    return f"{mem}\n{body}" if mem else body


# -- the fold -----------------------------------------------------------------

# What the fold asks for. Written as instructions to the same assistant rather
# than to a summariser, because the digest is read back by a session running
# under the same CLAUDE.md and the two should not disagree about who is
# speaking. The character bound is stated here and enforced on the way in --
# see DIGEST_MAX_CHARS.
DIGEST_INSTRUCTIONS = """\
Below is a conversation you and I had earlier today. It is about to leave your
context. Write the digest that replaces it.

Write it for yourself. A fresh session with none of this in memory will be
started with your digest as the only thing it knows about the day so far, so
keep what a continuation needs: what I asked for, what you found, what was
decided, what is still open, anything I asked you to remember, and any name,
path or number that would be tedious to establish again. Drop the greetings,
the acknowledgements and your own working-out.

Notes, not a story. Do not check anything against the box while you write it --
everything you are summarising is in the text below, and a fact you go and
re-read now is a fact this digest will still be asserting in six hours.

Answer with the digest and nothing else: no preamble, no sign-off. Keep it
under {chars} characters.
"""


# -- reading the stream -------------------------------------------------------

# Which key in a tool's input is worth printing beside its name. The console
# draws one dim line per tool call -- `→ Bash(systemctl status ...)` -- and the
# argument that makes the line worth reading is different for each tool.
# Ordered: the first key present wins.
TOOL_ARG_KEYS = (
    "command", "file_path", "path", "pattern", "url", "query", "prompt",
    "notebook_path", "description",
)


# What makes a command string more than one thing to run. A composed line says
# "this turn ran this verb on this entry" and says nothing else, so it may only
# be composed for a command that IS only that: `bin/memory forget x; curl ...`
# would otherwise be drawn on the transcript as a tidy `memory(forget x)` with
# the second half of it invisible. `&&` and `||` are already caught by `|`, and
# both are listed anyway, because a reader checking this list against a shell
# should not have to work that out.
MEMORY_COMPOUND = (";", "&&", "||", "|", "\n", "`", "$(")

# The verbs that change the store, and so the only ones the tool ceiling is
# lifted for. `list`, `show` and `taint` read and are worth a line like any
# other tool call, no more.
MEMORY_WRITE_VERBS = frozenset(("remember", "revise", "forget"))

# The one multi-line shape the composer will speak for: the standing
# instructions' own body form. The quoted delimiter is load-bearing twice --
# the shell expands nothing inside the body, and this code can hold the body
# to being body.
MEMORY_HEREDOC = "<<'EOF'"


def _memory_single(command):
    """The single invocation this command amounts to, or None.

    A one-line command qualifies when it carries no compound mark. The blessed
    heredoc form qualifies too: `... - <<'EOF'` ending the first line, then
    body, then a final line that is exactly EOF with nothing after it. The
    body may say anything -- the quoted delimiter keeps the shell out of it --
    but a line that IS the delimiter would end the heredoc early and hand the
    remainder to the shell, so an early EOF line disqualifies the whole
    command rather than compose a line that hides what follows it.
    """
    if "\n" not in command:
        if any(mark in command for mark in MEMORY_COMPOUND):
            return None
        return command
    first, _, rest = command.partition("\n")
    first = first.rstrip()
    if not first.endswith(MEMORY_HEREDOC):
        return None
    head = first[: -len(MEMORY_HEREDOC)].rstrip()
    if any(mark in head for mark in MEMORY_COMPOUND):
        return None
    if not head.split() or head.split()[-1] != "-":
        return None
    lines = rest.split("\n")
    while lines and lines[-1] == "":
        lines.pop()
    if not lines or lines[-1] != "EOF" or "EOF" in lines[:-1]:
        return None
    return head


def memory_call(name, args):
    """`remember charon-owner-brevity` for a call to bin/memory, else "".

    The verb and the entry, which are the two things worth reading about a
    memory op and the first two a 114-character clip of the command string
    drops: a description and a body stand between the entry name and the end of
    that line.

    **One segment or nothing.** A command carrying a `;`, a pipe, a newline or
    a substitution is more than this invocation, and this function has no way
    to say so in the line it composes -- so it declines, and the ordinary
    clipped `Bash(...)` renders instead, showing the command as it actually
    was. The one newline that composes anyway is the blessed heredoc form for
    a multi-line body, `... - <<'EOF'`: _memory_single proves the body inert
    and the terminator final before this function will speak for it. The
    journal is the record of record either way.

    Splitting on whitespace is enough for the rest, and quoting is deliberately
    not this function's problem: the verb and the entry name are both single
    words by the tool's own grammar, and everything that can carry a space or a
    quote comes after them. The per-token bound is the same dashboard bound
    every other line here carries -- no real verb or entry name comes near it,
    since this is model output on its way to a screen.
    """
    if name != "Bash" or not isinstance(args, dict):
        return ""
    command = args.get("command")
    if not isinstance(command, str):
        return ""
    single = _memory_single(command)
    if single is None:
        return ""
    parts = single.split()
    if not parts or parts[0] != MEMORY_BIN:
        return ""
    return " ".join(part[:TOOL_ITEM_MAX] for part in parts[1:3])


def memory_tool_line(name, args):
    """`memory(remember charon-owner-brevity)` for a memory call, else "".

    The one tool call this file composes a line for instead of clipping one out
    of the command string, because it is the only thing a session does in this
    lane that outlives the turn and the transcript is the surface a person
    actually watches. What counts as one, and what the words are, is
    `memory_call`'s business; what the ceiling then does with the line is
    `add_tool`'s.
    """
    said = memory_call(name, args)
    return f"memory({said})" if said else ""


def tool_summary(name, args):
    """One line naming a tool call. `Bash(systemctl status halftone-collector)`.

    The argument is chosen rather than dumped: a Read's whole input is a path
    and an Edit's is two files' worth of text, and the same rule has to draw
    both on one row. A tool whose input has no key worth printing gets its bare
    name, which is still the true statement `Glob()`.

    A memory op is composed rather than clipped; see `memory_tool_line`.
    """
    composed = memory_tool_line(name, args)
    if composed:
        return composed
    label = str(name or "tool")[:TOOL_ITEM_MAX]
    if not isinstance(args, dict):
        return f"{label}()"
    for key in TOOL_ARG_KEYS:
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            arg = " ".join(value.split())
            room = TOOL_ITEM_MAX - len(label) - 2
            if room < 8:
                return f"{label}()"
            if len(arg) > room:
                arg = arg[:room - 1] + "…"
            return f"{label}({arg})"
    return f"{label}()"


class StreamState:
    """What has been read out of the event stream so far.

    Kept as an object with one `feed` method because it is the piece worth
    testing on its own: the rest of this file is subprocesses, flocks and
    signals, and the parser is the part where a mistake shows up as a wrong
    answer on a screen rather than as a crash.

    **Two shapes of text arrive and only one of them may be counted.** With
    --include-partial-messages the CLI emits `stream_event` deltas as tokens
    are produced AND a complete `assistant` message when the block is done. So
    deltas accumulate into `live`, and a completed assistant message replaces
    `live` with its own text rather than adding to it -- the delta buffer and
    the finished block are two accounts of the same sentence, and appending
    both is how an answer comes out doubled.

    Subagent output is skipped for text and kept for tools. A message with a
    `parent_tool_use_id` came from a subagent the session spawned; its prose is
    working-out rather than the answer, but the fact that it ran a command is
    exactly what the tool list is for.
    """

    def __init__(self):
        # Completed assistant text blocks, in order.
        self.blocks = []
        # The delta buffer for the block currently being produced.
        self.live = ""
        self.tools = []
        # How many memory writes have already been let past TOOLS_MAX. The
        # exemption is per session and bounded; see `add_tool`.
        self.memory_writes = 0
        self.session_id = None
        # Set by the result event. `ok` stays None until one arrives, which is
        # itself meaningful: a stream that ended without a result is a session
        # that died rather than one that answered.
        self.ok = None
        self.result_text = None
        self.error = None
        self.duration_s = None
        # The raw usage object off the result event, kept whole and interpreted
        # by `context_from_usage`. **This is the field the chat runner throws
        # away**, and every context number in the contract is downstream of it.
        self.usage = None
        self.truncated = False

    def text(self):
        """Everything said so far, as one string."""
        parts = [b for b in self.blocks if b]
        if self.live:
            parts.append(self.live)
        out = "\n\n".join(parts)
        if len(out) > PARTIAL_MAX_CHARS:
            self.truncated = True
            return out[:PARTIAL_MAX_CHARS] + "\n\n[output truncated]"
        return out

    def add_tool(self, name, args):
        # A memory WRITE lands even when the list is already full, up to
        # MEMORY_TOOLS_EXEMPT of them. TOOLS_MAX exists so a tool-heavy turn
        # cannot flood the record, and the turns most likely to be tool-heavy
        # are the long research ones -- which is exactly where a write issued
        # late would be the call that silently fell off the end. The transcript
        # is the surface a person actually watches, so the calls that change
        # something outside this turn are the ones guaranteed a line on it.
        #
        # The exemption is narrow on both axes deliberately: read verbs do not
        # get it, because a `list` that fell off the end changed nothing, and
        # the count is bounded, because an unbounded exemption is a way to
        # flood the list with the one kind of line that cannot be dropped. Past
        # either edge a memory call is still composed rather than clipped -- it
        # just takes its chances with the ceiling like everything else.
        said = memory_call(name, args)
        if (said and said.split(" ")[0] in MEMORY_WRITE_VERBS
                and self.memory_writes < MEMORY_TOOLS_EXEMPT):
            self.memory_writes += 1
            self.tools.append(memory_tool_line(name, args))
            return
        if len(self.tools) >= TOOLS_MAX:
            return
        self.tools.append(tool_summary(name, args))

    def feed(self, line):
        """One line of the stream. Returns True if the caller should repaint.

        Never raises. A line that is not JSON, or is JSON that is not an event,
        is skipped rather than fatal: this is another program's stdout, the CLI
        is entitled to add event types this one has never heard of, and one
        unreadable line must not cost the answer around it.
        """
        line = line.strip()
        if not line:
            return False
        try:
            event = json.loads(line)
        except ValueError:
            return False
        if not isinstance(event, dict):
            return False

        kind = event.get("type")

        # Every event carries the session, and the last one to say wins: the
        # CLI is entitled to hand back a different id than it was given, and
        # storing the one we sent would leave the next turn resuming a session
        # that has moved on.
        sid = event.get("session_id")
        if isinstance(sid, str) and sid:
            self.session_id = sid

        if kind == "stream_event":
            return self._feed_delta(event)
        if kind == "assistant":
            return self._feed_message(event)
        if kind == "result":
            self._feed_result(event)
            return True
        # `system` (init, api_retry, plugin_install) and `user` (tool results)
        # carry nothing this record shows. Deliberately not an error: they are
        # the majority of the stream by count.
        return False

    def _feed_delta(self, event):
        """A `stream_event`, whose payload is the raw streaming event.

        Only text deltas are taken. `input_json_delta` carries a tool's
        arguments arriving character by character, which is not something to
        show a reader mid-flight -- the completed `assistant` message names the
        tool properly a moment later.
        """
        if event.get("parent_tool_use_id"):
            return False
        inner = event.get("event")
        if not isinstance(inner, dict):
            return False
        delta = inner.get("delta")
        if not isinstance(delta, dict) or delta.get("type") != "text_delta":
            return False
        text = delta.get("text")
        if not isinstance(text, str) or not text:
            return False
        self.live += text
        return True

    def _feed_message(self, event):
        """A complete `assistant` message: text blocks and tool calls.

        This is also the only path that works when the stream carries no
        deltas at all -- without --include-partial-messages there are no
        `stream_event` lines, and an answer arrives here in one piece. The
        console still renders it; it simply arrives per message rather than
        per token.
        """
        message = event.get("message")
        if not isinstance(message, dict):
            return False
        blocks = message.get("content")
        if not isinstance(blocks, list):
            return False

        subagent = bool(event.get("parent_tool_use_id"))
        painted = False
        said = []
        for block in blocks:
            if not isinstance(block, dict):
                continue
            btype = block.get("type")
            if btype == "text" and not subagent:
                text = block.get("text")
                if isinstance(text, str) and text.strip():
                    said.append(text)
            elif btype == "tool_use":
                self.add_tool(block.get("name"), block.get("input"))
                painted = True

        if said:
            self.blocks.extend(said)
            # The deltas that built these blocks are now represented by the
            # blocks themselves. See the class docstring: keeping both is how
            # an answer comes out doubled.
            self.live = ""
            painted = True
        elif not subagent and self.live:
            # A message with no text in it -- a pure tool call -- ends whatever
            # was being streamed before it. Keep it rather than drop it: it is
            # something the session actually said.
            self.blocks.append(self.live)
            self.live = ""
            painted = True
        return painted

    def _feed_result(self, event):
        """The last line of the stream: the final text, how it went, and what
        it cost.

        The cost is the addition this lane exists to make. `usage` is taken
        whole and read later rather than reduced here, because `context` is a
        record field with a contract on it and this class is the parser -- the
        arithmetic belongs next to the window it is divided by.
        """
        subtype = event.get("subtype")
        self.ok = not event.get("is_error") and subtype in (None, "success")

        result = event.get("result")
        self.result_text = result if isinstance(result, str) else None

        duration = event.get("duration_ms")
        if isinstance(duration, (int, float)):
            self.duration_s = round(duration / 1000, 1)

        usage = event.get("usage")
        if isinstance(usage, dict):
            self.usage = usage

        if not self.ok:
            # The CLI puts its own explanation in `result` on a failure. Bounded
            # because it is going onto a dashboard.
            why = (self.result_text or "").strip()[:300]
            self.error = why or f"the session reported {subtype or 'an error'}"

    def final_text(self):
        """The answer to store.

        The result event's own text is preferred over the accumulated blocks:
        it is the CLI's canonical account of what the session said, and the
        accumulation is a reconstruction of the same thing from its parts. The
        reconstruction is the fallback for a stream that ended without a result
        -- a stop, or a process that died -- which is exactly when it is the
        only copy there is.
        """
        if self.result_text and self.result_text.strip():
            text = self.result_text.strip()
            if len(text) > PARTIAL_MAX_CHARS:
                return text[:PARTIAL_MAX_CHARS] + "\n\n[output truncated]"
            return text
        return self.text().strip()


# -- the context meter --------------------------------------------------------

def context_from_usage(usage, model):
    """The contract's `context` object, or None if the CLI did not say.

    **Never estimated.** There is no character-count fallback here and there is
    not one in the console either, because a made-up number on this meter is
    worse than no number: it is the input to a decision about folding the day,
    and the reader cannot tell a measurement from a guess once both are drawn
    as a percentage.

    `tokens` is `input_tokens + cache_read_input_tokens`, per the contract, and
    the omission of `cache_creation_input_tokens` is what makes the figure a
    floor rather than a ceiling -- which the contract then asks every consumer
    to treat it as. A missing cache read is zero, because a first turn genuinely
    reads no cache; a missing `input_tokens` is no reading at all, because that
    is the CLI declining to say and not a turn that sent nothing.

    The percentage floors through integer division rather than through
    `int(tokens / window * 100)`. The collector fires its notice on a crossing
    at exactly 50, 75 and 90, and a float that lands a hair under an integer is
    how a warning goes missing on the one turn it was written for.
    """
    if not isinstance(usage, dict):
        return None
    sent = usage.get("input_tokens")
    if not isinstance(sent, int) or isinstance(sent, bool):
        return None
    cached = usage.get("cache_read_input_tokens")
    if not isinstance(cached, int) or isinstance(cached, bool):
        cached = 0

    tokens = max(0, sent + cached)
    window = MODEL_WINDOWS.get(model, DEFAULT_WINDOW)
    # Clamped at 100 because the console draws a bar and a bar past its own end
    # is a rendering bug in a different program. A day that reaches this is
    # already telling the truth at 100.
    pct = min(100, tokens * 100 // window)
    return {
        "tokens": tokens,
        "window": window,
        "pct": pct,
        "at": stamp(),
        # A turn has now run against this session, so whatever the compact route
        # left true about the previous one no longer is.
        "stale": False,
    }


# -- running a session --------------------------------------------------------

def reader_thread(stdout, sink):
    """Pump stdout into a queue, one line at a time.

    A thread rather than a select loop because the answer has to be readable
    while the wall clock and the stop flag are also being watched, and a
    blocking readline in the main loop can do neither. The sentinel is None,
    which cannot collide with a line.
    """
    try:
        for line in stdout:
            sink.put(line)
    except (OSError, ValueError):
        pass
    finally:
        sink.put(None)


def drain_stderr(stderr, sink):
    """Pump stderr into a bounded ring so it can never wedge the child.

    stderr is a PIPE with an OS buffer of roughly 64KB. If nobody reads it
    while the session runs -- and the main loop below reads only stdout -- a
    session that writes past that buffer (API-retry warnings during an outage,
    a tool-heavy `--verbose` turn) blocks on the write, its stdout goes silent
    with it, and the turn sits wedged until the timeout kills it with the
    answer lost. So a second daemon thread empties it continuously, exactly as
    `reader_thread` does for stdout. Only the tail is ever used, for an error
    message, so the ring keeps the last lines and drops the rest -- an outage
    that logs for ten minutes costs a fixed few kilobytes here, not a gigabyte.
    """
    try:
        for line in stderr:
            sink.append(line)
    except (OSError, ValueError):
        pass


def kill_group(proc):
    """Terminate the session and everything it started.

    The process group, not the process: claude spawns tool subprocesses, and a
    SIGTERM to the parent alone leaves a `journalctl` reading a file with
    nobody to hand it to. Started with start_new_session=True precisely so
    there is a group to name here that does not include this runner.

    TERM then KILL, because a session that is asked politely gets to flush its
    transcript, and one that ignores the asking does not get to hold the spool.
    """
    try:
        pgid = os.getpgid(proc.pid)
    except OSError:
        return
    for sig, grace in ((signal.SIGTERM, 5.0), (signal.SIGKILL, 2.0)):
        try:
            os.killpg(pgid, sig)
        except OSError:
            return
        try:
            proc.wait(timeout=grace)
            return
        except subprocess.TimeoutExpired:
            continue


def run_session(day, cmd, prompt, timeout_s, on_partial=None, arm=False):
    """One claude session, streamed. Returns (StreamState, stopped).

    Factored out of the chat runner's `run_turn` because this lane starts two
    kinds of session -- the answer and the fold -- and they differ only in argv,
    in how long they may take and in whether anything is painted while they run.
    Everything below that line is identical, and two copies of a process-group
    kill is two places to get a stop wrong.

    `stopped` travels beside the state rather than inside it because it is a
    fact about how the session ended rather than about what it said: a stopped
    turn is a success carrying a partial answer, and the caller marks it in the
    transcript rather than treating it as an error. The stop flag is watched
    during the fold as well, so a person who presses stop while the day is
    being folded gets a stop rather than a three-minute wait for one.

    `on_partial` is called with the text so far, no more often than the caller
    allows; everything about how that reaches disk is the caller's business,
    which keeps this function about the subprocess and the parser.

    **`arm` is the one thing the two kinds of session genuinely disagree
    about, and it defaults to the closed side.** The answering turn is a person
    talking to the assistant, so it may write memory. The fold is a session
    handed a transcript and told to summarise it, and that transcript is the
    day -- including whatever the morning's WebFetch put in it. Arming it would
    hand write verbs to the one session in this file whose entire input is
    already-fetched content, which is the laundering path the gate exists to
    refuse. The default is no-arm so that a third kind of session added here
    later is closed until somebody decides otherwise in writing.
    """
    state = StreamState()
    began = time.monotonic()

    # The memory gate. Both kinds of session clear this lane's markers, because
    # a marker outliving the turn that made it is a marker that refuses somebody
    # else's write; only the armed kind then writes `armed`, in this order:
    # clear, check, arm, spawn. The ordering is the design and not a tidy
    # arrangement of three calls -- see `arm_memory`.
    #
    # The turn id is minted here rather than being the day, and the day is the
    # obvious wrong answer: it is the same string from breakfast to midnight
    # and it is written on a record every lane can read, so a marker from this
    # morning would still match this evening. Four random bytes make it this
    # spawn's alone, while the day in front of it keeps a stray marker legible
    # to a person reading the directory. urandom rather than `random`, because
    # this is a secret for the length of a turn and not a sample.
    #
    # A copy of the environment rather than a mutation of it, because this
    # process drains a whole spool: an id exported into its own environment
    # would still be sitting there for the next turn. The fold's copy has both
    # keys taken out of it rather than merely never added -- a key inherited
    # from whatever started this process would otherwise travel into the one
    # session here that is deliberately not armed, and an absence a reader can
    # see beats one they have to infer.
    env = dict(os.environ)
    if arm:
        turn_id = f"{day}-{os.urandom(4).hex()}"
        arm_memory(turn_id)
        env["MEMORY_TURN_ID"] = turn_id
        env["MEMORY_THREAD"] = day
    else:
        clear_taint()
        env.pop("MEMORY_TURN_ID", None)
        env.pop("MEMORY_THREAD", None)

    try:
        proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=ENV_DIR,
            env=env,
            text=True,
            bufsize=1,
            # The group kill_group needs, and the reason a stop can be trusted
            # to take the tool subprocesses with it.
            start_new_session=True,
        )
    except OSError as exc:
        state.ok = False
        state.error = f"cannot start claude: {exc}"
        return state, False

    # The prompt goes in on stdin rather than as an argument: it is prose with
    # newlines in it, and a day's quoted transcript is emphatically not a thing
    # to put on a command line. Closed immediately -- there is no second turn
    # coming down this pipe.
    try:
        proc.stdin.write(prompt)
        proc.stdin.close()
    except OSError as exc:
        kill_group(proc)
        state.ok = False
        state.error = f"cannot send the prompt: {exc}"
        return state, False

    lines = queue.Queue()
    pump = threading.Thread(target=reader_thread, args=(proc.stdout, lines),
                            daemon=True)
    pump.start()

    # stderr gets its own drain, running the whole session. Without it a full
    # stderr buffer stalls the child and the loop below starves; see
    # `drain_stderr`. The ring is bounded because only the tail is ever read.
    err_lines = collections.deque(maxlen=200)
    err_pump = threading.Thread(target=drain_stderr, args=(proc.stderr, err_lines),
                                daemon=True)
    err_pump.start()

    stopped = False
    timed_out = False
    dirty = False
    last_paint = 0.0

    while True:
        if stop_requested(day):
            stopped = True
            break
        if time.monotonic() - began > timeout_s:
            timed_out = True
            break
        try:
            line = lines.get(timeout=POLL_S)
        except queue.Empty:
            # Nothing arrived. Still a chance to flush what did: a session that
            # goes quiet mid-sentence while it thinks should leave the last
            # words it said on screen rather than in this process's memory.
            if on_partial and dirty and time.monotonic() - last_paint >= PARTIAL_EVERY_S:
                on_partial(state)
                last_paint = time.monotonic()
                dirty = False
            continue
        if line is None:
            break
        if state.feed(line):
            dirty = True
            if on_partial and time.monotonic() - last_paint >= PARTIAL_EVERY_S:
                on_partial(state)
                last_paint = time.monotonic()
                dirty = False

    if stopped or timed_out:
        kill_group(proc)
    else:
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            # The stream ended and the process did not. Not a normal exit, and
            # not a reason to hold the spool open either.
            kill_group(proc)

    # The child is done (waited on or killed), so its stderr is at EOF and the
    # drain thread is about to finish. Join it briefly, then read the ring it
    # filled -- never `proc.stderr.read()`, which would be a second reader of a
    # pipe the thread already drained.
    err_pump.join(timeout=2.0)
    tail = "".join(err_lines).strip()[-300:]

    if state.duration_s is None:
        state.duration_s = round(time.monotonic() - began, 1)

    if stopped:
        # A stop is not a failure. Whatever was said is the turn, and the
        # console prints the marker under it -- see `answer`.
        state.ok = True
        state.error = None
    elif timed_out:
        state.ok = False
        state.error = f"the session did not finish within {timeout_s}s"
    elif state.ok is None:
        # The stream ended with no result event. The process died, or was
        # killed by something outside this program.
        code = proc.returncode
        state.ok = False
        state.error = (f"claude exited {code}: {tail}" if tail
                       else f"claude ended without a result (exit {code})")
    elif state.ok and not state.final_text():
        state.ok = False
        state.error = "the session produced no answer"

    return state, stopped


def day_model(doc):
    """The model to run, checked again rather than trusted from the file.

    See MODELS: this string becomes argv, and the collector being its only
    writer today is not a property worth building an exec on.
    """
    model = doc.get("model")
    return model if model in MODELS else MODELS[0]


# The CLI's own `--effort` levels, in its own order. Checked against
# `claude --help`, not guessed.
EFFORTS = ("low", "medium", "high", "xhigh", "max")


def day_effort(doc):
    """How hard to think, off the record, or None to let the CLI decide.

    **None is a real answer and not a fallback to a guess.** A day that nobody
    has set an effort on gets no `--effort` in its argv at all, so the CLI uses
    whatever its own default is. Substituting a level here would pin every old
    day to whatever this file happened to think the default was on the morning
    it was written, and would keep claiming that after the CLI moved.

    Validated for `day_model`'s reason: this string becomes argv, and "the
    collector is its only writer today" is not a property worth building an
    exec on.
    """
    effort = doc.get("effort")
    return effort if effort in EFFORTS else None


def run_turn(day, doc, text, on_partial):
    """The answering session. Returns (StreamState, stopped)."""
    model = day_model(doc)
    resuming, why = should_resume(doc)
    log(f"{day}: {'resume' if resuming else 'new session'} ({why}) · {model}"
        f"{' · ' + day_effort(doc) if day_effort(doc) else ''}")

    effort = day_effort(doc)
    cmd = [
        CLAUDE, "-p",
        "--model", model,
        "--max-turns", "40",
        "--permission-mode", "dontAsk",
        "--output-format", "stream-json",
        "--verbose",
        # Without this the CLI emits no `stream_event` lines at all, so there
        # are no text deltas to accumulate and `partial` would jump from empty
        # to the whole answer in one step. The parser handles both shapes, so
        # dropping this flag degrades to per-message updates rather than
        # breaking.
        "--include-partial-messages",
    ]
    # Only when the day actually names one. See `day_effort`.
    if effort:
        cmd += ["--effort", effort]
    if resuming:
        cmd += ["--resume", doc["claude_session_id"]]

    # The one session in this file that may write memory: a person asked this
    # one a question. See `run_session`.
    return run_session(day, cmd, build_prompt(doc, text, resuming), TIMEOUT_S,
                       on_partial, arm=True)


def make_digest(day, doc, material):
    """Fold `material` into one digest. Returns (digest or None, stopped).

    Its own session, not a passage bolted onto the answering turn. The
    alternative -- asking the answering session for the answer and the digest in
    one reply, behind a delimiter -- saves a round trip and costs the delimiter:
    a turn whose visible text has to be split from its housekeeping is a turn
    that shows the housekeeping to the reader on the first day the model puts
    the marker in the wrong place. This one produces a string or it does not.

    **Its session id is deliberately never stored.** It is a throwaway that has
    read a transcript and answered once, and resuming into it on the next turn
    would give the day a session whose entire history is a summarisation. The
    caller reads the digest off the return value and nothing else off this
    state.

    Run without tools by construction rather than by flag: `--max-turns 1`
    leaves no room for a tool result to come back, and the prompt says to work
    from the text alone. A named disallow flag would be the tidier statement,
    but the spelling of it belongs to the CLI and a rejected argument here fails
    the fold on the exact turn that needed it. A session that spends its one
    turn on a tool call produces no text, which is a failed fold, which the
    caller already handles.

    `--effort` is left off for the same reason -- the accepted values are the
    CLI's to define, and the default is right for a summarisation anyway.
    """
    model = day_model(doc)
    cmd = [
        CLAUDE, "-p",
        "--model", model,
        "--max-turns", "1",
        "--permission-mode", "dontAsk",
        "--output-format", "stream-json",
        "--verbose",
    ]
    prompt = (DIGEST_INSTRUCTIONS.format(chars=DIGEST_MAX_CHARS)
              + "\n\n" + material)

    # No `on_partial`: the fold is not the turn, and streaming a summary of the
    # morning into the panel where the answer is about to appear would read as
    # the assistant answering the wrong question.
    #
    # No `arm` either, which is the default and is stated here anyway because
    # it is a security property rather than an omission: this session's entire
    # input is the day's transcript, which is where every page the assistant
    # fetched today was written down. It reads that and summarises it; it does
    # not get write verbs. `run_session` argues the whole of it.
    state, stopped = run_session(day, cmd, prompt, DIGEST_TIMEOUT_S)
    if stopped:
        return None, True
    if not state.ok:
        log(f"{day}: fold failed: {state.error}")
        return None, False

    digest = state.final_text().strip()
    if not digest:
        return None, False
    if len(digest) > DIGEST_MAX_CHARS:
        # Enforced here as well as asked for in the prompt. A seed that is
        # re-sent at the head of every session for the rest of the day is the
        # last place to be relaxed about a length.
        digest = digest[:DIGEST_MAX_CHARS].rstrip() + "\n\n[digest truncated]"
    return digest, False


def fill_digest(day, entry_at, digest):
    """Write `kept` onto the newest compaction, and only `kept`.

    Re-read before writing, like every other write in this file: the collector
    owns every other field of that entry and owns the array it sits in. Matched
    by `at` rather than by index so that a compaction filed while the fold was
    running is not the one this digest gets attached to -- it summarises the day
    up to `entry_at` and saying otherwise would put the wrong stretch of the
    conversation behind the wrong cut.
    """
    fresh = read_day(day)
    if fresh is None:
        return None
    for entry in reversed(compactions(fresh)):
        if str(entry.get("at") or "") == entry_at:
            entry["kept"] = digest
            fresh["updated_at"] = stamp()
            if write_day(day, fresh):
                return fresh
            return None
    log(f"{day}: the compaction at {entry_at} is gone; dropping its digest")
    return None


# -- one turn -----------------------------------------------------------------

def answer(day):
    """Answer one queued day. The spool entry is dropped either way.

    Every exit from here leaves the day `idle` or `error` and `partial` null:
    the console draws its input state off those two fields, so a failure that
    left them alone would be a conversation that looks like it is still being
    worked on for as long as the file exists.

    The order of work, which is the part worth arguing:

      1. **The fold first, then the answer.** A compaction entry with no `kept`
         means the compact route retired the session and left the digest to
         this lane. The digest is what the fresh session is *seeded with*, so
         producing it after the answer would mean answering out of the raw
         transcript and then writing a summary for a session that never saw it
         -- the cost of the fold with none of the benefit. Producing it first
         costs one short session and every turn for the rest of the day is
         cheap.
      2. **A failed fold does not fail the turn.** The digest is an economy, not
         a precondition: if it cannot be written the question is still answered,
         out of `prior_context`'s raw quoting, and `kept` stays empty so the
         next turn tries again. The person asked a question; the housekeeping
         behind it is not their problem.
      3. **`context` is written last, off the result event.** It is the only
         thing in this file that clears `stale`, because `stale` means no turn
         has run since the fold and this is the turn.
    """
    doc = read_day(day)
    if doc is None:
        # A spool entry naming a day that is not there, or a record that is not
        # a record. Nothing can answer it and nothing ever will be able to, so
        # it leaves the spool rather than being retried forever.
        log(f"{day}: no readable day record; dropping the spool entry")
        unspool(day)
        clear_stop(day)
        return

    text = last_user_text(doc)
    if not text:
        log(f"{day}: no unanswered user turn; dropping the spool entry")
        doc["status"] = "idle"
        doc["partial"] = None
        doc["updated_at"] = stamp()
        write_day(day, doc)
        unspool(day)
        clear_stop(day)
        return

    # **A stop flag found here is for this turn, and is honoured before a
    # session is ever started.**
    #
    # It used to be cleared as leftover, on the reasoning that a stop raised
    # before the turn began must have belonged to the turn before it. That is
    # wrong, and it silently dropped every stop aimed at a queued turn -- which
    # is the case the button exists for most, because a turn waiting on the path
    # unit is exactly when a reader changes their mind and there is no process
    # yet to signal. `collector.py`'s `jarvis_stop` writes the flag whatever the
    # day is doing and says so.
    #
    # What makes this safe is that the ambiguity is now resolved where it is
    # created: `jarvis_say` removes any stop flag when it files a turn, so
    # anything still here was written after this turn was filed. There is no
    # leftover case left to protect against.
    #
    # Abandoned rather than answered-then-stopped: nothing has run, so there is
    # no partial to keep and no subprocess to kill. The user turn stays in the
    # transcript, because they did say it.
    if stop_requested(day):
        log(f"{day}: stopped before the turn began")
        doc["status"] = "idle"
        doc["partial"] = None
        doc["updated_at"] = stamp()
        write_day(day, doc)
        unspool(day)
        clear_stop(day)
        return

    # `running` is this process's first write, and it is true the moment it is
    # made: a session starts a few lines down.
    doc["status"] = "running"
    doc["error"] = None
    doc["partial"] = ""
    doc["updated_at"] = stamp()
    write_day(day, doc)

    began = time.monotonic()

    def paint(partial):
        """Repaint the record with whatever should be on screen right now.

        Re-read before writing, exactly as the final write does and for the
        same reason: the collector may have changed the record while this was
        streaming -- a job card lands in `turns` mid-answer as a matter of
        routine, and that is the whole point of the work lane. Only the three
        fields this process owns are set.
        """
        fresh = read_day(day)
        if fresh is None:
            return
        fresh["status"] = "running"
        fresh["partial"] = partial
        fresh["updated_at"] = stamp()
        write_day(day, fresh)

    stopped = False

    # What the store looked like as this turn began, read before either session
    # is built and stamped onto the answer below. It is how the next turn
    # decides whether to spend the index again; see `memory_seen`.
    seen = memory_seen()

    # -- 1. the fold, if one is owed ------------------------------------------
    pending = pending_compaction(doc)
    if pending is not None:
        entry_at = str(pending.get("at") or "")
        # The material is the seed the session would have been handed at the
        # moment of the compaction: the previous digest plus what happened
        # between the two. So a day folded three times reads its own morning
        # once, not three times.
        material = prior_context(doc, until=entry_at or None)
        if not material.strip():
            # A compaction with nothing in front of it -- compact pressed on an
            # empty day. `kept` stays empty, which is the true statement that
            # nothing was kept, and this branch costs no model call, so the
            # retry on every later turn is free.
            log(f"{day}: the compaction at {entry_at} has nothing to fold")
        else:
            log(f"{day}: folding {len(material)} chars behind the compaction "
                f"at {entry_at}")
            paint(FOLD_NOTE)
            digest, stopped = make_digest(day, doc, material)
            if digest:
                folded = fill_digest(day, entry_at, digest)
                if folded is not None:
                    doc = folded
                    log(f"{day}: folded into {len(digest)} chars")
            paint("")

    # -- 2. the answer --------------------------------------------------------
    if stopped:
        # Stopped while folding. There is no answering session and there will
        # not be one, but the turn ends the way every stopped turn ends, so it
        # is given the same empty state rather than a second exit path.
        state = StreamState()
        state.ok = True
    else:
        state, stopped = run_turn(day, doc, text,
                                  lambda s: paint(s.text()))

    body = state.final_text()
    if stopped:
        body = f"{body}\n\n[stopped]" if body else "[stopped]"

    elapsed = round(time.monotonic() - began, 1)

    # Re-read immediately before writing rather than reusing the copy loaded a
    # minute ago. The collector cannot have appended a user turn -- it refuses
    # while this one is running -- but it can have changed the model, appended a
    # job card, or written a notice, and writing the stale copy back would
    # silently undo all three.
    fresh = read_day(day)
    if fresh is not None:
        doc = fresh

    if state.ok:
        doc.setdefault("turns", []).append({
            # The kind is written explicitly rather than left to be inferred
            # from `role`. Three kinds share this array and a console is
            # required to skip the ones it does not know, which it can only do
            # if every writer says which one it wrote.
            "kind": "say",
            "role": "assistant",
            "text": body,
            "at": stamp(),
            "tools": state.tools,
            # The journal's mtime as this turn began, which is the only thing
            # that answers "has the store moved since this day last looked at
            # it". Written on every say turn, including the ones that carried
            # no block: 0.0 is the true statement that there was nothing to
            # look at. See `memory_moved`.
            "memory_seen": seen,
            # What actually answered, recorded per turn: the toggle can move
            # between turns, and a transcript that showed only the day's
            # current setting would relabel history every time it moved.
            "model": doc.get("model"),
            # The session's own account of itself where it gave one, this
            # process's wall clock otherwise. The wall clock is the fallback
            # rather than the preference because it includes this program's own
            # overhead -- and today that overhead can be a three-minute fold,
            # which is not time the answer took.
            "elapsed_s": state.duration_s or elapsed,
        })
        doc["status"] = "idle"
        doc["error"] = None
        log(f"{day}: {'stopped' if stopped else 'answered'} in {elapsed}s · "
            f"{len(state.tools)} tools · {len(body)} chars")
    else:
        # The user turn stays. It is still a true record of what was asked, and
        # losing it would mean re-typing a question that the box, not the
        # person, failed to answer.
        doc["status"] = "error"
        doc["error"] = (state.error or "the session failed")[:300]
        log(f"{day}: failed after {elapsed}s: {doc['error']}")

    # -- 3. the meter ---------------------------------------------------------
    # Written whenever the CLI said, and not only when the turn succeeded: the
    # tokens went up the wire either way, and a meter that under-reports after a
    # failed turn is a meter saying there is room where there is not. When no
    # result event arrived -- a stop, a dead process -- there is no reading and
    # the previous one stands, which is honest: it is still the last thing that
    # was actually measured, and `stale` still says whether to believe it.
    measured = context_from_usage(state.usage, doc.get("model"))
    if measured is not None:
        doc["context"] = measured

    doc["partial"] = None
    doc["claude_session_id"] = state.session_id or doc.get("claude_session_id")
    doc["updated_at"] = stamp()

    if not write_day(day, doc):
        # The answer is lost and the turn is still owed. Left on the spool on
        # purpose: the next fire will try again, and this is the one failure
        # where a retry is the right behaviour.
        return

    # **The spool entry goes even on failure.** A poisoned turn that stayed
    # queued would be retried by every subsequent fire of the path unit, which
    # is a loop that costs a model call each time and wedges the conversation
    # behind it. The reader sees the error and sends again if he wants to --
    # which is the same retry, with a person deciding it is worth making.
    unspool(day)
    clear_stop(day)


def drain():
    """Every turn waiting, oldest first, one at a time, then done.

    Re-scanned each pass rather than snapshotted once, so a turn typed while an
    earlier one is being answered is picked up by this same drain instead of
    waiting for the path unit to fire again.

    `attempted` is the loop's only stop condition beyond an empty spool: if a
    day survives its turn -- a disk that refused the write -- it must not be
    picked again in the same drain, or this becomes a spin on one bad file.
    """
    attempted = set()
    while True:
        waiting = [day for day in queued() if day not in attempted]
        if not waiting:
            return
        day = waiting[0]
        attempted.add(day)
        try:
            answer(day)
        except Exception as exc:  # noqa: BLE001
            # One turn failing is not the drain failing. The spool entry stays,
            # the next fire tries it again, and everything behind it still gets
            # answered now.
            log(f"{day}: unhandled error: {exc!r}")


def main():
    if not os.path.isdir(ENV_DIR):
        # The session's working directory is where its permission allowlist
        # lives. Without it claude would run in whatever directory this process
        # happened to start in, under whatever settings it found there, which
        # is a different and much wider agent than the one this file documents.
        log(f"{ENV_DIR} is not there; refusing to run a session without it")
        return 1
    if not take_lock():
        # Another drain is already working. Not an error, and not a spool that
        # goes unserved: the running process re-scans after every turn.
        return 0
    began = time.monotonic()
    drain()
    log(f"drain finished in {round(time.monotonic() - began, 1)}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
