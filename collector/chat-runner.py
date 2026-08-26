#!/usr/bin/env python3
"""Halftone chat runner. Drains the turn queue once, then exits.

Deploys to /home/pi/halftone-chat/bin/chat-runner.py and is started by
halftone-chat.path the moment threads/.queue stops being empty. **There is no
polling loop and no daemon here.** The path unit is the clock: it fires when a
turn lands, this drains everything waiting, and the box goes back to running
nothing at all. An idle Pi should be idle, and a loop that wakes every ten
seconds to find an empty directory is a loop that runs 8,640 times a day to do
nothing.

This is the same shape as the CMO pipeline's own one-shot ask runner (not
published here), with a longer leash and a live wire back to the screen. The
differences worth knowing before reading:

  * The answer streams. A chat session runs for a minute with tool calls in
    it, and a reader watching a blank panel for that minute cannot tell it
    from a wedged one -- so the text is written to `partial` as it arrives and
    the console draws it with a cursor on the end.
  * It can be stopped. `threads/.stop/<id>` appears, the process group dies,
    and whatever had been said is kept as the turn with `[stopped]` under it.
  * Every conversation is its own resumed session, and there is no morning run
    underneath it to go stale against -- so the resume test is only about
    length, not about freshness.

The write contract with the collector, which is the thing to not break:

    collector writes  the thread record, the user turn, the spool entry,
                      and the stop flag
    THIS writes       status, partial, the assistant turn, the claude session
                      id, and the deletion of both flags

One writer per field. A spool entry means "unanswered", and only the process
that answered it may say otherwise -- so a drain that dies halfway leaves a
queue that is still exactly true, and the next fire picks up where it stopped.

The session runs in env/, whose .claude/settings.json is a default-deny
allowlist: reads, greps, and a named list of read-only shell commands. See
env/README.md for what is on it and why. That file is the permission boundary
and it is loaded from the working directory, which is why the unit's
WorkingDirectory= line is a security control rather than a convenience.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import collections
import fcntl
import hashlib
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

# Where the conversations live. Overridable so this file can be exercised on a
# Mac with a temp directory -- the collector takes the same path from its own
# config for the same reason. The Pi's path is the default because that is the
# box this runs on.
BASE = os.environ.get("CHAT_BASE") or "/home/pi/halftone-chat"
THREADS_DIR = os.path.join(BASE, "threads")
QUEUE_DIR = os.path.join(THREADS_DIR, ".queue")
STOP_DIR = os.path.join(THREADS_DIR, ".stop")
LOCK_PATH = os.path.join(THREADS_DIR, ".runner.lock")
ENV_DIR = os.path.join(BASE, "env")
CLAUDE = os.environ.get("CHAT_CLAUDE") or os.path.expanduser("~/.local/bin/claude")

# The thread id shape, asserted again here. A spool entry's name is
# attacker-controlled only if something has already written into this
# directory, but a filename from disk becoming a path is exactly the shape of
# bug worth refusing structurally rather than reasoning about.
SLUG = re.compile(r"[a-z0-9-]{1,64}")

# What the collector is willing to accept as a model, restated. The runner
# reads this value off a file rather than off a request, so it is checked again
# before it becomes argv: the collector is the only writer of the field today,
# and "today" is not a property worth building an exec on.
MODELS = ("sonnet", "opus")

# One turn, one wall clock. Ten minutes is long next to the ask runner's five,
# because this session has tools and a conversation behind it: a question that
# reads three files and greps a journal genuinely takes minutes, and a timeout
# that fires on real work is a feature that looks broken. The drain is strictly
# one at a time, so this is also the worst case for every turn queued behind
# it -- which is survivable precisely because a person is watching one
# conversation rather than a queue.
TIMEOUT_S = 600

# How often the record is rewritten while text is streaming in. Every delta
# would be a file write per token; half a second is faster than a reader can
# perceive and slow enough that a long answer costs tens of writes rather than
# thousands. The console polls at 1s, so this is comfortably under its own
# resolution.
PARTIAL_EVERY_S = 0.5

# How often the reader thread is checked when nothing is arriving. This is the
# resolution of the stop flag and of the wall clock, and it is deliberately
# much finer than either: a stop that took two seconds to land would feel
# ignored.
POLL_S = 0.25

# A conversation this long has drifted from whatever it started as, and its
# session is carrying a transcript nobody is reading any more. Past this, the
# next turn starts a fresh session with the thread quoted.
MAX_RESUME_TURNS = 40

# How much of an old conversation gets quoted into a fresh session. The newest
# turns win: the fold exists so a re-started session knows what was already
# said, and the end of a conversation is the part that carries that.
FOLD_MAX_CHARS = 16000

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
# A session that decides to print a 10 MB file would otherwise turn a thread
# into a document no browser can open. What is cut is announced rather than
# hidden.
PARTIAL_MAX_CHARS = 200_000

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
    and two runners sharing a queue would answer the same turn twice, into the
    same file, with two sessions writing `partial` over each other. Exiting 0
    rather than 1: being already busy is a correct outcome, and a failed unit
    here would need a human to clear it for no reason at all.
    """
    global _lock_fd
    os.makedirs(THREADS_DIR, exist_ok=True)
    _lock_fd = os.open(LOCK_PATH, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(_lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return False
    return True


# -- the thread record --------------------------------------------------------

def thread_path(tid):
    return os.path.join(THREADS_DIR, f"{tid}.json")


def read_thread(tid):
    """The record, or None if it is not one. Never raises."""
    try:
        with open(thread_path(tid)) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or not isinstance(doc.get("turns"), list):
        return None
    return doc


def write_thread(tid, doc):
    """tmp + os.replace, so the collector and the console never read a half
    written record. Returns True on success.

    This is called every half second while an answer streams, which is the
    reason it is a replace rather than a rewrite in place: the console is
    fetching this file on a 1s poll, and the two would otherwise collide
    several times per answer.
    """
    path = thread_path(tid)
    tmp = f"{path}.tmp"
    try:
        with open(tmp, "w") as fh:
            json.dump(doc, fh, indent=2)
        os.replace(tmp, path)
        return True
    except OSError as exc:
        log(f"{tid}: cannot write the thread: {exc}")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def unspool(tid):
    """Drop the queue entry. Always attempted: an entry left behind is a turn
    this process would answer again on the next fire."""
    try:
        os.remove(os.path.join(QUEUE_DIR, tid))
    except FileNotFoundError:
        pass
    except OSError as exc:
        log(f"{tid}: cannot clear the spool entry: {exc}")


def stop_path(tid):
    return os.path.join(STOP_DIR, tid)


def stop_requested(tid):
    return os.path.exists(stop_path(tid))


def clear_stop(tid):
    """Drop the stop flag. The runner's alone, like the spool entry, and for
    the same reason: the collector raises it and only the process that acted on
    it can say it has been acted on. A flag left behind would stop the NEXT
    turn, which is a stop button with a delayed fuse."""
    try:
        os.remove(stop_path(tid))
    except FileNotFoundError:
        pass
    except OSError as exc:
        log(f"{tid}: cannot clear the stop flag: {exc}")


def queued():
    """Every id waiting, oldest arrival first.

    By mtime rather than by name. The id sorts chronologically to the minute,
    which is nearly the same order, and "nearly" is the wrong word for the
    order a queue is served in.
    """
    out = []
    try:
        with os.scandir(QUEUE_DIR) as entries:
            for entry in entries:
                if not SLUG.fullmatch(entry.name):
                    continue
                try:
                    out.append((entry.stat().st_mtime, entry.name))
                except OSError:
                    continue
    except OSError:
        return []
    out.sort()
    return [name for _, name in out]


# -- resume or start fresh ----------------------------------------------------

def turn_count(doc, role):
    return sum(1 for t in (doc.get("turns") or [])
               if isinstance(t, dict) and t.get("role") == role)


def should_resume(doc):
    """Whether this turn continues its own session. Returns (bool, why).

    Two conditions, and deliberately not the ask runner's three. That one also
    asks whether the world moved underneath the thread since it last answered,
    because the CMO's files are rewritten by a 6am job and a resumed session
    would answer today's question out of yesterday's reading. **Nothing
    equivalent exists here.** This assistant reads a live box -- systemctl,
    journalctl, df -- and every one of those is re-read at the moment it is
    asked. There is no snapshot to go stale against, so there is no freshness
    test to run.

    The `why` is logged, because "it started a new session" is otherwise an
    invisible decision that changes what the answer knows.
    """
    if not doc.get("claude_session_id"):
        return False, "no session yet"
    turns = turn_count(doc, "user")
    if turns >= MAX_RESUME_TURNS:
        return False, f"thread has {turns} user turns"
    return True, "resuming the thread's session"


def fold(doc):
    """The conversation so far, quoted, for a session that cannot be resumed.

    Newest turns first while filling, then put back in order: the end of a
    conversation is the part a re-started session needs, and a thread long
    enough to be truncated is a thread whose opening has already been answered.

    Headed with what it is, because the session that said these things is gone
    and cannot be asked what it meant.
    """
    turns = [t for t in (doc.get("turns") or []) if isinstance(t, dict)]
    # The last turn is the one being answered now; it arrives separately.
    turns = turns[:-1]
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
    body = "\n>\n".join(kept)
    return ("## earlier in this conversation\n\n"
            f"{body}\n\n"
            "The exchange above happened in a previous session that has since "
            "been retired. Re-check anything it asserts about the state of the "
            "box before relying on it.\n")


# -- tags ---------------------------------------------------------------------

# What an @-tag points the session at. Typing `@cmo` in a message means "go
# read that architecture before you answer", and that is the whole mechanism:
# a tag is a prompt change, not a permission change. Nothing below grants a
# read -- every root is already on env/settings.json's additionalDirectories
# and every tool named is already on its allowlist, so a tag can only aim the
# session at something it was allowed to do anyway. That is why this table is
# allowed to be a table rather than a negotiation.
#
# **Two kinds of entry, because there are two kinds of tag.**
#
#   * An `Architecture` is a *place*: a root, what to call it in a sentence,
#     and the files inside it worth opening first. The last field is a hint
#     and not a whitelist -- a session that needs a fourth briefing may read
#     it.
#   * A `Directive` is an *order*: one imperative sentence saying what the
#     turn owes before it is answered -- a tool pass to make, or a standard
#     the answer has to meet. It carries no root because it points at no
#     single directory -- `@web` is the open internet, `@files` is every
#     directory this session could already open, and `@cite` names no place
#     at all.
#
# The three render differently and are told apart by their type rather than by
# their shape, so a directive that grew a second field would still be a
# directive. Everything else about a tag -- the vocabulary, the boundary rule,
# the dedupe, the chip on the Mac -- is the same for all of them.
#   * A `Digest` is a *place whose current contents are small enough to hand
#     over*. It renders like an architecture and then attaches what is
#     actually in there right now. There is exactly one, and it exists because
#     the messages store is the only root here whose useful content on any
#     given day is forty short lines: a session told to go and read it would
#     spend four tool calls reassembling a transcript that fits in the prompt,
#     and would do it from files whose contents are somebody else's words.
#     Handing it over already assembled is cheaper and, more to the point,
#     lets it be handed over *bounded* -- forty messages, clipped, from
#     allowlisted conversations only.
Architecture = collections.namedtuple("Architecture", "root label files")
Directive = collections.namedtuple("Directive", "line")
Digest = collections.namedtuple("Digest", "root label build")

# The messages store, which this file only ever reads. Overridable for the same
# reason BASE is: so the digest can be exercised against a temp directory on a
# Mac. The variable is the pipeline's own, so pointing one points both.
MESSAGES_ROOT = os.path.join(
    os.environ.get("CHARON_MAIL_BASE") or "/home/pi/charon-mail", "messages")

# What one tagged turn is handed. Forty short lines is a readable stretch of a
# day and about two thousand tokens; a day with three hundred messages in it
# gets its most recent forty, because the tail of a conversation is the part a
# question is ever about.
MESSAGES_DIGEST_MAX = 40
# Per line, so one pasted essay in a group chat cannot become the whole block.
MESSAGES_DIGEST_CHARS = 300
# The read ceiling, on the opens rather than on the scandir, exactly as the
# collector bounds the same directory.
MESSAGES_SCAN_MAX = 2000


def _messages_json(*parts):
    """One small JSON object out of the messages store, or None. Never raises:
    every file here is optional, and on a box with no Bridge the whole
    directory is."""
    try:
        with open(os.path.join(MESSAGES_ROOT, *parts)) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


def _messages_local(value):
    """(YYYY-MM-DD, HH:MM) local for one event stamp, or (None, None).

    Events are stamped UTC with a Z, because that is the one clock two machines
    agree on. A day is a fact about where the user is standing, so both halves
    of this are converted before anything is filed or drawn.
    """
    if not isinstance(value, str) or not value:
        return None, None
    text = value.strip()
    if text[-1:] in ("Z", "z"):
        text = text[:-1] + "+00:00"
    try:
        at = datetime.fromisoformat(text)
    except ValueError:
        return None, None
    if at.tzinfo is not None:
        at = at.astimezone()
    return at.date().isoformat(), at.strftime("%H:%M")


def _messages_allowed():
    """The chat_keys the user allowlisted for reading, as a set.

    The allowlist is keyed by chat GUID and the store files by the hash of one,
    so the mapping is recomputed here. **This is the boundary that matters in
    this function**: a conversation the user did not allowlist does not appear
    in a prompt, and the filter is on what the store is asked for rather than
    on what it returns.
    """
    config = _messages_json("config.json") or {}
    chats = config.get("chats")
    if not isinstance(chats, dict):
        return set()
    out = set()
    for guid, entry in chats.items():
        if not isinstance(guid, str) or not isinstance(entry, dict):
            continue
        if entry.get("read"):
            out.add(hashlib.sha256(
                guid.encode("utf-8", "replace")).hexdigest()[:16])
    return out


def _messages_body(key):
    """One stored text, clipped to a line. "" when there is none."""
    try:
        with open(os.path.join(MESSAGES_ROOT, "bodies", f"{key}.txt"),
                  "rb") as fh:
            raw = fh.read(MESSAGES_DIGEST_CHARS * 4)
    except OSError:
        return ""
    return " ".join(raw.decode("utf-8", "replace").split())[
        :MESSAGES_DIGEST_CHARS]


def messages_digest():
    """Today's texts from allowlisted conversations, plus today's daily read.

    Newest last, which is how a transcript is read and the opposite of how the
    console lists conversations. The session is about to answer a question over
    this text, and a block that ended with the oldest line would put the least
    relevant message closest to the question.

    Returns "" when there is nothing, which renders as the tag's own line and
    no block: a channel with no traffic today should say so by being empty
    rather than by claiming an outage.
    """
    allowed = _messages_allowed()
    if not allowed:
        return ""

    today = datetime.now().date().isoformat()
    found = []
    try:
        with os.scandir(os.path.join(MESSAGES_ROOT, "index")) as entries:
            for entry in entries:
                if not entry.name.endswith(".json"):
                    continue
                try:
                    found.append((entry.stat().st_mtime, entry.name[:-5],
                                  entry.path))
                except OSError:
                    continue
    except OSError:
        return ""
    found.sort(key=lambda row: row[0], reverse=True)

    rows = []
    for _, key, path in found[:MESSAGES_SCAN_MAX]:
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            continue
        if not isinstance(doc, dict) or doc.get("chat_key") not in allowed:
            continue
        date, at = _messages_local(doc.get("created_at"))
        if date != today:
            continue
        rows.append((str(doc.get("created_at") or ""), at, doc, key))

    rows.sort(key=lambda row: row[0])
    rows = rows[-MESSAGES_DIGEST_MAX:]

    lines = []
    for _, at, doc, key in rows:
        chat = (doc.get("chat_name") or doc.get("chat_identifier")
                or "unnamed chat")
        sender = ("you" if doc.get("is_from_me")
                  else (doc.get("sender_name") or doc.get("sender") or "them"))
        lines.append(f"{at or '??:??'} {chat} · {sender}: "
                     f"{_messages_body(key) or '(no text)'}")

    summary = _messages_json("summaries", f"{today}.json")
    if isinstance(summary, dict) and summary.get("status") == "ok":
        needs = summary.get("needs_you")
        for item in (needs if isinstance(needs, list) else [])[:8]:
            if isinstance(item, dict) and isinstance(item.get("line"), str):
                lines.append(f"needs an answer: {item.get('chat') or ''} "
                             f"{item['line']}".strip())
        prose = summary.get("prose")
        if isinstance(prose, str) and prose.strip():
            lines.append(f"today's read: {' '.join(prose.split())}")

    return "\n".join(lines)


TAG_TARGETS = {
    "cmo": Architecture(
        "/home/pi/charon-mail",
        "the CMO architecture",
        "memory/, the newest briefings/*.md, docs/, watchlist/, prompt.md",
    ),
    "mail": Architecture(
        "/home/pi/charon-mail/mail",
        "the mail pipeline",
        "state.json, index/, ai/, drafts/, outbox/, audit.log",
    ),
    "jarvis": Architecture(
        "/home/pi/halftone-chat/jarvis",
        "the Jarvis workspace",
        "days/, jobs/",
    ),
    "messages": Digest(
        MESSAGES_ROOT,
        "the messages channel",
        messages_digest,
    ),
    "web": Directive(
        "search the web first: use WebSearch/WebFetch for current information "
        "relevant to the question BEFORE answering, and ground the answer in "
        "what you find rather than in what this session already believes."
    ),
    "files": Directive(
        "search this box first: use Grep/Glob/Read across the allowed "
        "directories for what is relevant BEFORE answering, and say which "
        "files the answer stands on."
    ),
    "box": Directive(
        "measure this machine first: use the allowed read-only commands "
        "(journalctl, systemctl status, df, free, uptime, vcgencmd, tailscale "
        "status) to check the services and vitals relevant to the question "
        "BEFORE answering, and quote what they actually said."
    ),
    "cite": Directive(
        "every claim in the answer must name what it stands on -- a file path "
        "on this box or a URL. A claim with no source either gets one or gets "
        "dropped."
    ),
    "today": Directive(
        "scope the reading to the last 24 hours: today's and yesterday's "
        "journal entries, the newest briefing, today's mail index entries, "
        "and today's jarvis day. Reach for older material only when the "
        "question explicitly asks for it."
    ),
}

# `@cmo` is a tag. `someone@cmo.example.com` is an address, `@cmojunk` is a
# word that happens to start with one, and neither is an instruction. The
# lookbehind refuses anything that would make the `@` an infix -- a word
# character, a dot, a hyphen, another `@` -- and the `\b` refuses a tag with
# more word stuck on the end of it. Trailing punctuation is not more word, so
# `@cmo,` and `@cmo.` at the end of a sentence both count.
#
# Case-insensitive: `@CMO` at the start of a sentence is the same instruction
# typed by somebody whose keyboard capitalised it, and refusing it would be a
# rule the user has to learn from a tag that silently did nothing.
#
# The alternation is `TAG_TARGETS`' own keys, so the vocabulary is stated once
# and a tag that exists is a tag that matches. Architectures and directives are
# one namespace here on purpose: `@web` is typed, boxed and deduped exactly
# like `@cmo`, and only the block it renders is different.
#
# **The Mac composer scans for this same vocabulary and this same boundary
# rule, by hand and without a regex, in the Mac app's Sources/Chat/
# ChatTags.swift. The two are one contract in two languages: change this,
# change that, or the composer raises a token the runner then ignores.** The
# recipe for adding a word to both halves is written out in mac/TAGS.md; the
# short of it is that this table above is the whole of this side, because
# `TAG_RE` builds itself from its keys and `tagged_context` renders off the
# entry's type.
TAG_RE = re.compile(r"(?<![\w.@-])@(" + "|".join(TAG_TARGETS) + r")\b",
                    re.IGNORECASE)


def turn_tags(text):
    """Which tags this turn asked for, in the order it named them.

    Deduped and lowercased: `@cmo ... @CMO` is one pointer said twice, and the
    block below should not say it twice. Unknown @words are not an error and
    not a warning -- a message with `@someone` in it is a message, and the tag
    vocabulary is deliberately nine words long.

    Architectures and directives come back in one list and in typing order,
    which is the order the user thought in: `@cmo @web` asks for the briefings
    and then the internet, and the block reads in that order too.
    """
    found = []
    for match in TAG_RE.finditer(text or ""):
        name = match.group(1).lower()
        if name not in found:
            found.append(name)
    return found


def tagged_context(tags):
    """The block that goes above a tagged turn, or "" for an untagged one.

    One entry per tag, in the order they were typed, under one header however
    many there are and whichever kinds they are -- because the alternative is
    several phrasings to keep true instead of one. An architecture renders the
    way it always has, two lines: where it lives and what to open in it. A
    directive renders as the single imperative line it is. Mixed tags simply
    interleave, and nothing sorts them: `@cmo @web` reads in the order the
    user thought it.

    The header says what the user did rather than ordering the session around:
    a tag is a pointer, not a restriction on the answer.
    """
    if not tags:
        return ""
    named = ", ".join(f"@{name}" for name in tags)
    lines = [
        "## tagged context",
        "",
        f"The user tagged {named}. Each line below is an obligation this turn "
        "carries before it is answered: a place to read, a pass to make, or a "
        "standard the answer has to meet. Ground the answer in what you "
        "actually find rather than in what this session already believes.",
        "",
    ]
    for name in tags:
        target = TAG_TARGETS[name]
        if isinstance(target, Directive):
            lines.append(f"@{name} -- {target.line}")
            continue
        if isinstance(target, Digest):
            # The place, then what is currently in it. Built at render time
            # rather than stored, because the whole point of this kind is that
            # the content is today's. A build that comes back empty leaves the
            # pointer standing on its own, which is the honest rendering of a
            # channel with nothing in it.
            lines.append(f"@{name} -- {target.label}: {target.root}")
            block = target.build()
            if block:
                for line in block.split("\n"):
                    lines.append(f"  {line}")
            else:
                lines.append("  nothing today, or no conversation is "
                             "allowlisted for reading")
            continue
        lines.append(f"@{name} -- {target.label}: {target.root}")
        lines.append(f"  {target.files}")
    lines.append("")
    return "\n".join(lines)


# -- memory -------------------------------------------------------------------

# The store the two talk lanes keep about the operator: one durable fact per
# file, written only through bin/memory. A sibling of threads/ under the same
# base, so a harness pointing CHAT_BASE at a temp tree points this at one too.
# **Nothing in this file writes into memory/ except under .taint/** -- the
# entries and the journal belong to the tool, which is where the flock, the
# caps and the gate all live.
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
# messages digest bounds its own directory. A runaway backstop and not a
# working bound -- a store with this many files in it is already far past the
# cap above.
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
    else. ValueError sits beside OSError for the same reason it does in
    `messages_digest`: a file whose bytes are not text raises the first and not
    the second, and one stray binary file must not cost this lane its index.
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
    # The newest survive a store somebody hand-filled past the cap, which is
    # the messages digest's clip direction and for its reason: the end of the
    # list is the part that is still true.
    rows = rows[-MEMORY_DIGEST_MAX:]
    return "\n".join(f"{name} -- {description}"
                     for _, name, description in rows)


def memory_context():
    """The standing block that goes at the head of a turn, or "".

    Injected here rather than written into env/CLAUDE.md, where every other
    standing instruction lives, because this one's *contents* move underneath
    the session: CLAUDE.md is loaded once per session, so a long conversation
    would carry the index as it stood when it started -- including a stale
    account of the entries the session had itself written since.
    """
    lines = memory_digest()
    if not lines:
        return ""
    return MEMORY_BLOCK.format(root=MEMORY_DIR, lines=lines)


def last_assistant_turn(doc):
    """The newest assistant turn, or None when there is not one yet."""
    for turn in reversed(doc.get("turns") or []):
        if isinstance(turn, dict) and turn.get("role") == "assistant":
            return turn
    return None


def memory_seen():
    """The journal's mtime as this turn is about to be built, or 0.0.

    Stamped onto the assistant turn this runner appends, where `memory_moved`
    reads it back on the next one. Read *before* the prompt is built rather
    than after, and the direction is the whole point: an op that lands while
    this turn is running is then newer than the stamp, so the next turn carries
    the block. The other direction would leave the session that wrote an entry
    as the one session never told about it.

    0.0 for a store with no journal, which is a real answer rather than a
    missing one: nothing has ever been written, so anything later is newer.
    """
    try:
        return os.path.getmtime(MEMORY_JOURNAL)
    except OSError:
        return 0.0


def memory_moved(doc):
    """Whether the store changed since this conversation last saw the index.

    The question a resumed turn asks before spending the block again. A fresh
    session always gets it, because it knows nothing; a resumed one already has
    the index somewhere in its context, and re-sending the whole store on every
    turn of a long conversation is the shape of cost that is invisible per turn
    and enormous per day.

    The journal's mtime now, against the `memory_seen` this runner stamped on
    the newest assistant turn -- the mtime the block that turn carried was
    rendered from. **The turn's `at` cannot answer this and used to be asked.**
    A write made during a turn is older than the `at` written at the end of it,
    so the session that had just remembered something was precisely the session
    never handed the entry back, for the rest of the conversation. Comparing
    against what the turn saw rather than when it finished makes a
    same-session write re-inject on the next turn, which is what section 3 of
    the spec promises.

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
# else on this box. This runner clears the lane's marker directory and writes
# `armed` with the turn's id before the session starts; the PreToolUse hooks in
# .claude/settings.json touch a marker the moment a fetch is *asked for*; and
# bin/memory refuses every write verb unless `armed` matches the MEMORY_TURN_ID
# it was handed and nothing else is sitting in there.
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

# Tags whose material this box wrote itself, about itself. A turn naming only
# these has reached nothing external and may still write memory; every other
# tag seeds a marker before the session has said a word, because `@web` is a
# turn that *will* fetch and the gate does not have to watch it happen to know
# that. The list is inverted deliberately -- a tag added next year taints by
# omission rather than being exempt by it, which is the safe direction for a
# list somebody will eventually forget to update.
#
# `@jarvis` is deliberately NOT in here, and it is the one that looks like it
# should be. The tree it points at is `jarvis/days` and `jarvis/jobs`, and a
# day record is where an assistant that fetched a page wrote down what the page
# said, verbatim and at length. Pointing a turn at that tree is reaching
# external content one copy later, and one copy later is exactly the laundering
# the gate exists to refuse.
MEMORY_CLEAN_TAGS = frozenset(("box", "cite", "memory"))


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


def arm_memory(turn_id, tags=()):
    """Clear this lane's markers and arm the gate for exactly this turn.

    One function rather than four lines at the Popen because the order is the
    whole of it: clear, check, arm, seed, and only then start the session. A
    seed written before the clear would be wiped by its own clear, which
    disables the gate silently for exactly the turns it exists for -- the
    tagged ones.

    `tags` is this turn's own list from `turn_tags`, so every name in it is a
    word out of the tag vocabulary and never something a message chose. Markers
    from earlier turns are cleared rather than aged out: the turn id in `armed`
    already makes a stale marker harmless, and a directory that only ever grows
    is a directory somebody has to explain later.

    **A seed that will not land takes `armed` back down with it.** The failure
    is a full or read-only disk, and the shape of it is the dangerous one: the
    turn would be armed, tagged `@web`, and carrying no marker to say so, which
    is the gate open on exactly the turn it exists for. Removing `armed` lands
    the turn closed instead -- the write refuses, the answer is produced
    normally, and nothing else about the turn changes.

    Never raises and never fails the turn. Every failure here costs the session
    its write verbs for one turn, which is exactly what happens on a box that
    has no store at all.
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
        return
    if not memory_armable():
        return
    if not _taint_mark("armed", turn_id):
        return
    for name in tags:
        if name in MEMORY_CLEAN_TAGS:
            continue
        if _taint_mark(f"tag-{name}"):
            continue
        log(f"cannot seed tag-{name}; disarming this turn")
        try:
            os.remove(os.path.join(LANE_TAINT_DIR, "armed"))
        except OSError:
            # Best effort, and logged above either way. A tree that refuses
            # both a create and a remove is a tree the tool cannot write an
            # entry into either, so the write this was protecting fails at the
            # store rather than at the gate.
            pass
        return


# -- the prompt ----------------------------------------------------------------


def build_prompt(doc, text, resuming):
    """What goes in on stdin.

    No system prompt is assembled here, unlike the ask runner, and that is the
    design rather than an omission: the session's standing instructions live in
    env/CLAUDE.md, which claude loads from its working directory on every
    session including a resumed one. Prepending them to each turn as well would
    put two copies of the same instructions in the context, and the resumed
    copy would be the one that had drifted.

    The tagged-context block is the exception, and it is one because it is the
    opposite kind of thing: not standing instructions but this turn's pointer,
    true for this message only. So it goes in on **both** shapes -- a resumed
    turn is otherwise the bare user text, which is exactly the turn that would
    have lost it.

    The memory block is the second exception and a different kind again. It is
    standing context, but its *contents* move underneath the session, so it
    cannot live in env/CLAUDE.md: a file loaded once per session would hand a
    forty-turn conversation the index as it stood at the first message. It goes
    in on both shapes too, and on a resumed turn only when the store has
    actually changed since this thread last saw it -- see `memory_moved`.
    **An untagged turn carries the standing memory block and nothing else
    new**, which is the re-baselined form of the invariant this function used
    to state as byte-identity.

    Stable to volatile, top to bottom: what is remembered across conversations,
    then what this turn pointed at, then this conversation, then the message.

    What goes on the wire is not what goes in the record: the thread JSON keeps
    the user's literal text, and these blocks exist only for the length of one
    stdin pipe.
    """
    # Built only when it is going to be sent: the scan is cheap, but a resumed
    # turn that is not carrying the block has no reason to open the store.
    mem = memory_context() if (not resuming or memory_moved(doc)) else ""
    tagged = tagged_context(turn_tags(text))
    if resuming:
        body = f"{tagged}\n{text}" if tagged else text
        return f"{mem}\n{body}" if mem else body
    quoted = fold(doc)
    body = f"{quoted}\n{text}" if quoted else text
    body = f"{tagged}\n{body}" if tagged else body
    return f"{mem}\n{body}" if mem else body


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
        # exemption is per turn and bounded; see `add_tool`.
        self.memory_writes = 0
        self.session_id = None
        # Set by the result event. `ok` stays None until one arrives, which is
        # itself meaningful: a stream that ended without a result is a session
        # that died rather than one that answered.
        self.ok = None
        self.result_text = None
        self.error = None
        self.duration_s = None
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
        """The last line of the stream: the final text and how it went."""
        subtype = event.get("subtype")
        self.ok = not event.get("is_error") and subtype in (None, "success")

        result = event.get("result")
        self.result_text = result if isinstance(result, str) else None

        duration = event.get("duration_ms")
        if isinstance(duration, (int, float)):
            self.duration_s = round(duration / 1000, 1)

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


# -- one turn -----------------------------------------------------------------

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
    with it, and the turn sits wedged until the 600s timeout kills it with the
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
    transcript, and one that ignores the asking does not get to hold the queue.
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


def run_turn(tid, doc, text, on_partial):
    """One session, streamed. Returns (StreamState, stopped).

    `stopped` travels beside the state rather than inside it because it is a
    fact about how the turn ended rather than about what the session said: a
    stopped turn is a success carrying a partial answer, and the caller marks
    it in the transcript rather than treating it as an error.

    `on_partial` is called with the text so far, no more often than the caller
    allows; everything about how that reaches disk is the caller's business,
    which keeps this function about the subprocess and the parser.
    """
    model = doc.get("model")
    if model not in MODELS:
        # Checked again here rather than trusted from the file. See MODELS.
        model = MODELS[0]

    resuming, why = should_resume(doc)
    log(f"{tid}: {'resume' if resuming else 'new session'} ({why}) · {model}")

    # Off the record when the thread names one; "high" when it does not.
    # Deliberately NOT the say runner's absent-means-absent rule: this runner
    # shipped with high hardcoded, so every existing thread has only ever run
    # at high, and a silent drop to the CLI's default would change behaviour
    # nobody asked to change. A thread that sets an effort gets exactly it.
    effort = doc.get("effort")
    if effort not in ("low", "medium", "high", "xhigh", "max"):
        effort = "high"
    cmd = [
        CLAUDE, "-p",
        "--model", model,
        "--effort", effort,
        "--max-turns", "40",
        "--permission-mode", "dontAsk",
        "--output-format", "stream-json",
        "--verbose",
        # Not in the original spec for this runner, and added deliberately:
        # without it the CLI emits no `stream_event` lines at all, so there are
        # no text deltas to accumulate and `partial` would jump from empty to
        # the whole answer in one step. The parser handles both shapes, so
        # dropping this flag degrades to per-message updates rather than
        # breaking.
        "--include-partial-messages",
    ]
    if resuming:
        cmd += ["--resume", doc["claude_session_id"]]

    state = StreamState()
    began = time.monotonic()

    # This turn's id for the gate, and deliberately not the thread id. The
    # thread id is written on the record, is in the URL of nothing but is
    # readable from every lane, and it is the same string for every turn of the
    # conversation -- so a session that learned it could arm-match a turn it
    # was not part of, and a marker left by turn nine would still match turn
    # ten. Four random bytes on the end make it this spawn's and nobody else's,
    # while the thread id in front of it keeps a stray marker legible to a
    # person reading the directory. urandom rather than `random`, because this
    # is a secret for the length of a turn and not a sample.
    turn_id = f"{tid}-{os.urandom(4).hex()}"

    # The memory gate, armed for exactly this turn and in this order: clear,
    # check, arm, seed, spawn. The ordering is the design and not a tidy
    # arrangement of four calls -- see `arm_memory`.
    arm_memory(turn_id, turn_tags(text))

    # The one place this file departs from `env=os.environ`. The turn id
    # travels to bin/memory as an environment variable, which is how a write
    # verb proves it belongs to the turn that was armed; the thread id travels
    # beside it as the one the entry's frontmatter records, so the tool never
    # has to take the nonce apart to find out where a fact was learned. A copy
    # rather than a mutation, because this process drains a whole queue: an id
    # exported into its own environment would still be sitting there for the
    # next turn.
    env = dict(os.environ)
    env["MEMORY_TURN_ID"] = turn_id
    env["MEMORY_THREAD"] = tid

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

    # The prompt goes in on stdin rather than as an argument, the way the ask
    # runner feeds its own: it is prose with newlines in it, and a command line
    # is the wrong place for that. Closed immediately -- there is no second
    # turn coming down this pipe.
    try:
        proc.stdin.write(build_prompt(doc, text, resuming))
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

    # stderr gets its own drain, running the whole turn. Without it a full
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
        if stop_requested(tid):
            stopped = True
            break
        if time.monotonic() - began > TIMEOUT_S:
            timed_out = True
            break
        try:
            line = lines.get(timeout=POLL_S)
        except queue.Empty:
            # Nothing arrived. Still a chance to flush what did: a session that
            # goes quiet mid-sentence while it thinks should leave the last
            # words it said on screen rather than in this process's memory.
            if dirty and time.monotonic() - last_paint >= PARTIAL_EVERY_S:
                on_partial(state)
                last_paint = time.monotonic()
                dirty = False
            continue
        if line is None:
            break
        if state.feed(line):
            dirty = True
            if time.monotonic() - last_paint >= PARTIAL_EVERY_S:
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
            # not a reason to hold the queue open either.
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
        state.error = f"the session did not finish within {TIMEOUT_S}s"
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


def answer(tid):
    """Answer one queued thread. The spool entry is dropped either way.

    Every exit from here leaves the thread `idle` or `error` and `partial`
    null: the console draws its input state off those two fields, so a failure
    that left them alone would be a conversation that looks like it is still
    being worked on for as long as the file exists.
    """
    doc = read_thread(tid)
    if doc is None:
        # A spool entry naming a thread that is not there, or a record that is
        # not a record. Nothing can answer it and nothing ever will be able to,
        # so it leaves the queue rather than being retried forever.
        log(f"{tid}: no readable thread record; dropping the spool entry")
        unspool(tid)
        clear_stop(tid)
        return

    text = ""
    for turn in reversed(doc.get("turns") or []):
        if isinstance(turn, dict) and turn.get("role") == "user":
            text = str(turn.get("text") or "").strip()
            break
    if not text:
        log(f"{tid}: thread has no user turn; dropping the spool entry")
        doc["status"] = "idle"
        doc["partial"] = None
        doc["updated_at"] = stamp()
        write_thread(tid, doc)
        unspool(tid)
        clear_stop(tid)
        return

    # A stop flag raised before this turn started belongs to the turn before
    # it -- a stop that arrived after the answer had already landed. Cleared
    # rather than honoured: stopping a turn that has not begun would abandon it
    # on arrival, which is not what the button says.
    if stop_requested(tid):
        log(f"{tid}: clearing a stop flag left over from an earlier turn")
        clear_stop(tid)

    # `running` is this process's first write, and it is true the moment it is
    # made: the subprocess starts on the next line.
    doc["status"] = "running"
    doc["error"] = None
    doc["partial"] = ""
    doc["updated_at"] = stamp()
    write_thread(tid, doc)

    began = time.monotonic()

    def on_partial(state):
        """Repaint the record with what has been said so far.

        Re-read before writing, exactly as the final write does and for the
        same reason: the collector may have changed the record while this was
        streaming. Only the three fields this process owns are set.
        """
        fresh = read_thread(tid)
        if fresh is None:
            return
        fresh["status"] = "running"
        fresh["partial"] = state.text()
        fresh["updated_at"] = stamp()
        write_thread(tid, fresh)

    # What the store looked like as this turn began, read before the prompt is
    # built and stamped onto the answer below. It is how the next turn decides
    # whether to spend the index again; see `memory_seen`.
    seen = memory_seen()

    state, stopped = run_turn(tid, doc, text, on_partial)

    body = state.final_text()
    if stopped:
        body = f"{body}\n\n[stopped]" if body else "[stopped]"

    elapsed = round(time.monotonic() - began, 1)

    # Re-read immediately before writing rather than reusing the copy loaded a
    # minute ago. The collector cannot have appended a turn -- it refuses while
    # this one is running -- but it can have changed the model, and writing the
    # stale copy back would silently undo that.
    fresh = read_thread(tid)
    if fresh is not None:
        doc = fresh

    if state.ok:
        doc.setdefault("turns", []).append({
            "role": "assistant",
            "text": body,
            "at": stamp(),
            "tools": state.tools,
            # The journal's mtime as this turn began, which is the only thing
            # that answers "has the store moved since this conversation last
            # looked at it". Written on every assistant turn, including the
            # ones that carried no block: 0.0 is the true statement that there
            # was nothing to look at. See `memory_moved`.
            "memory_seen": seen,
            # What actually answered, recorded per turn: the toggle can move
            # between turns, and a transcript that showed only the thread's
            # current setting would relabel history every time it moved.
            "model": doc.get("model"),
            # The session's own account of itself where it gave one, this
            # process's wall clock otherwise. The wall clock is the fallback
            # rather than the preference because it includes this program's own
            # overhead.
            "elapsed_s": state.duration_s or elapsed,
        })
        doc["status"] = "idle"
        doc["error"] = None
        log(f"{tid}: {'stopped' if stopped else 'answered'} in {elapsed}s · "
            f"{len(state.tools)} tools · {len(body)} chars")
    else:
        # The user turn stays. It is still a true record of what was asked, and
        # losing it would mean re-typing a question that the box, not the
        # person, failed to answer.
        doc["status"] = "error"
        doc["error"] = (state.error or "the session failed")[:300]
        log(f"{tid}: failed after {elapsed}s: {doc['error']}")

    doc["partial"] = None
    doc["claude_session_id"] = state.session_id or doc.get("claude_session_id")
    doc["updated_at"] = stamp()

    if not write_thread(tid, doc):
        # The answer is lost and the turn is still owed. Left on the queue on
        # purpose: the next fire will try again, and this is the one failure
        # where a retry is the right behaviour.
        return

    # **The spool entry goes even on failure.** A poisoned turn that stayed
    # queued would be retried by every subsequent fire of the path unit, which
    # is a loop that costs a model call each time and wedges every conversation
    # behind it. The reader sees the error and sends again if he wants to --
    # which is the same retry, with a person deciding it is worth making.
    unspool(tid)
    clear_stop(tid)


def drain():
    """Every turn waiting, oldest first, one at a time, then done.

    Re-scanned each pass rather than snapshotted once, so a turn typed while an
    earlier one is being answered is picked up by this same drain instead of
    waiting for the path unit to fire again.

    `attempted` is the loop's only stop condition beyond an empty queue: if an
    id survives its turn -- a disk that refused the write -- it must not be
    picked again in the same drain, or this becomes a spin on one bad file.
    """
    attempted = set()
    while True:
        waiting = [tid for tid in queued() if tid not in attempted]
        if not waiting:
            return
        tid = waiting[0]
        attempted.add(tid)
        try:
            answer(tid)
        except Exception as exc:  # noqa: BLE001
            # One turn failing is not the drain failing. The queue entry stays,
            # the next fire tries it again, and everything behind it still gets
            # answered now.
            log(f"{tid}: unhandled error: {exc!r}")


def main():
    if not os.path.isdir(ENV_DIR):
        # The session's working directory is where its permission allowlist
        # lives. Without it claude would run in whatever directory this process
        # happened to start in, under whatever settings it found there, which
        # is a different and much wider agent than the one this file documents.
        log(f"{ENV_DIR} is not there; refusing to run a session without it")
        return 1
    if not take_lock():
        # Another drain is already working. Not an error, and not a queue that
        # goes unserved: the running process re-scans after every turn.
        return 0
    began = time.monotonic()
    drain()
    log(f"drain finished in {round(time.monotonic() - began, 1)}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
