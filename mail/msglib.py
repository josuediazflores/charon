#!/usr/bin/env python3
"""Shared floor under the MESSAGES channel: paths, keys, tags, the allowlist.

Deploys to /home/pi/charon-mail/bin/msglib.py, next to maillib.py and next to
the one worker that imports it. Nothing in here talks to a model, nothing in
here opens a socket, and nothing in here sends anything: this is the part the
pipeline needs and the part the collector deliberately does not import.

**Why this is a sibling of maillib rather than a parametrisation of it.** The
obvious move is one module with a `kind` argument and two sets of directories
behind it. It was not taken, for three reasons that are all the same reason:

  * ten path constants are read *by name* in three programs. `INDEX_DIR` is a
    module attribute in the poller, in the worker and in the tests, and a
    parametrised module turns every one of those into a call whose argument is
    a string that nothing checks. The failure mode of getting it wrong is
    writing an iMessage body into the mailbox, which is the single worst bug
    this feature could have.
  * the worker on the far side hard-codes its lock, its prompt paths, its verb
    set and its working directory. Those are four decisions per channel, not
    one shape with a parameter, and mail-triage.py already spends its first
    twelve lines making them.
  * a mailbox and a thread of texts are not the same document. A message here
    has a chat, a sender and a direction; a mail has a subject, a From and a
    Reply-To. Sharing the *plumbing* is right and sharing the *record* is not,
    so what comes across from maillib below is exactly the kind-agnostic half.

The rule that shapes the module, and the one the Mac side shares: **identity is
the hash of a GUID.** A message is sha256 of its Messages row GUID, a chat is
sha256 of its chat GUID, both cut to sixteen hex characters, which is a
filename and a URL path segment without any further thought. Row ids are a
cursor and never a name: they are local to one Mac's database and renumber
themselves the day that database is rebuilt.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import hashlib
import json
import os
import re
from datetime import datetime, timezone

import maillib
# The kind-agnostic half of maillib, imported by name rather than reached
# through the module so that what this channel borrows is a list a reader can
# check. Everything here is about files, locks and spools; nothing here knows
# what a mailbox is.
from maillib import (  # noqa: F401 - re-exported for the worker and the tests
    BASE,
    KEY_RE,
    SLUG_RE,
    load_env,
    log,
    read_json,
    spool_add,
    spool_drop,
    spooled,
    split_entry,
    stamp,
    take_lock,
    write_atomic,
    write_json,
)

# The store. `BASE` honours CHARON_MAIL_BASE, which is what lets the tests point
# the whole channel at a temp directory without any worker growing a flag.
MESSAGES_DIR = os.path.join(BASE, "messages")

INDEX_DIR = os.path.join(MESSAGES_DIR, "index")
BODIES_DIR = os.path.join(MESSAGES_DIR, "bodies")
AI_DIR = os.path.join(MESSAGES_DIR, "ai")
DRAFTS_DIR = os.path.join(MESSAGES_DIR, "drafts")
OUTBOX_DIR = os.path.join(MESSAGES_DIR, "outbox")
SUMMARIES_DIR = os.path.join(MESSAGES_DIR, "summaries")
# Two spools, for mail's reason: the worker behind .queue runs a model and
# takes minutes, and a send queued behind one would be a tap with no visible
# effect for the length of an Opus call. Nothing on the Pi consumes .actions --
# the Bridge pulls its queue over HTTP -- so it is a local record of what was
# filed rather than a wake-up, and it is dropped when the send is reported.
QUEUE_DIR = os.path.join(MESSAGES_DIR, ".queue")
ACTIONS_DIR = os.path.join(MESSAGES_DIR, ".actions")
# Charon's own read marks. iMessage's read flags are a fact about the phone in
# the user's pocket; this directory is the fact about what he has seen here.
READ_DIR = os.path.join(MESSAGES_DIR, ".read")
# Written by the collector, one line per stored row; this side only reads it.
THREADS_DIR = os.path.join(MESSAGES_DIR, ".threads")

STATE_PATH = os.path.join(MESSAGES_DIR, "state.json")
CONFIG_PATH = os.path.join(MESSAGES_DIR, "config.json")
CHATS_PATH = os.path.join(MESSAGES_DIR, "chats.json")
BRIDGE_PATH = os.path.join(MESSAGES_DIR, "bridge.json")
AUDIT_PATH = os.path.join(MESSAGES_DIR, "audit.log")

# The session's project directory, borrowed rather than duplicated: its
# settings.json is what is meant to make these sessions tool-less, and one
# sandbox for both channels is one thing to keep true instead of two. Whether
# the CLI reads that file is a property of your install; see llm.py.
ENV_DIR = maillib.MAIL_ENV_DIR
# secrets/env, and never secrets/mail-env. The worker on the far side of this
# module starts a model session that inherits its environment, and a mailbox
# password that is never loaded is a password a model cannot be handed.
ENV_PATH = maillib.ENV_PATH

# The only tags that may reach disk. The triage prompt lists these and the
# worker checks them again on the way out: a prompt is a request, and a request
# is not a constraint. Deliberately not mail's vocabulary. These are the
# categories a text falls into, and the difference between "plans" and
# "appointment" is the difference between a thing to answer and a thing to be
# somewhere for.
TAGS = (
    "plans",
    "money",
    "appointment",
    "delivery",
    "family",
    "work",
    "school",
    "urgent",
    "today",
    "question",
    "fyi",
)

# What a stored text is allowed to be. The Bridge caps at the same number on the
# way out; this is the second half of the same promise, so a body written by an
# older Bridge cannot turn a thread route into a download.
TEXT_MAX_CHARS = 20000

# What may go out. A text is not an email: four thousand characters is already
# several screens, and the cap that matters is the one on the way to another
# person's phone.
SEND_MAX_CHARS = 4000

# What the allowlist may say about a chat. v1 gives behaviour to `off` and
# `confirm`; `auto` is stored and displayed and acted on by nothing, which is
# deliberate -- see MESSAGES.md.
POLICIES = ("off", "confirm", "auto")

# A chat's display name as the app may set it. One line in a picker.
NAME_MAX_CHARS = 120

# A summary is filed by local date, so the date is half of a filing key and is
# asserted every time one arrives from a spool entry or a route.
DATE_RE = re.compile(r"\d{4}-\d{2}-\d{2}")


# -- directories --------------------------------------------------------------

def ensure_dirs():
    """Every directory this channel writes into. Cheap, idempotent, and run by
    each program rather than assumed: a missing .queue turns a first ingest into
    a silent no-op with a full index."""
    for path in (MESSAGES_DIR, INDEX_DIR, BODIES_DIR, AI_DIR, DRAFTS_DIR,
                 OUTBOX_DIR, SUMMARIES_DIR, QUEUE_DIR, ACTIONS_DIR, READ_DIR):
        os.makedirs(path, exist_ok=True)


# -- paths --------------------------------------------------------------------

def index_path(key):
    return os.path.join(INDEX_DIR, f"{key}.json")


def text_path(key):
    return os.path.join(BODIES_DIR, f"{key}.txt")


def ai_path(key):
    return os.path.join(AI_DIR, f"{key}.json")


def draft_path(chat):
    return os.path.join(DRAFTS_DIR, f"{chat}.json")


def user_draft_path(chat):
    """What the user typed, in its own file. Two drafts, two writers, one file
    each, so a regenerate cannot eat what somebody typed."""
    return os.path.join(DRAFTS_DIR, f"{chat}.user.json")


def outbox_path(oid):
    return os.path.join(OUTBOX_DIR, f"{oid}.json")


def summary_path(date):
    return os.path.join(SUMMARIES_DIR, f"{date}.json")


def read_path(chat):
    return os.path.join(READ_DIR, f"{chat}.json")


# -- identity -----------------------------------------------------------------

def msg_key(guid):
    """The sixteen hex characters one message is filed under, forever.

    The row GUID hashed. Unlike mail there is no fallback and none is needed: a
    Messages row always has a GUID, and a row without one is a row the Bridge
    could not have read in the first place.
    """
    return hashlib.sha256((guid or "").encode("utf-8", "replace")).hexdigest()[:16]


def chat_key(chat_guid):
    """The sixteen hex characters one conversation is filed under.

    Same construction as `msg_key` and deliberately the same width: both halves
    of the wire validate one shape, and a route that could name a message can
    name a chat with the same regex.
    """
    return hashlib.sha256(
        (chat_guid or "").encode("utf-8", "replace")).hexdigest()[:16]


# -- time ---------------------------------------------------------------------

def local_date(value):
    """The local YYYY-MM-DD an event belongs to, or None.

    Events arrive stamped UTC with a Z, because that is the one timestamp two
    machines can agree on. A day, though, is a fact about where the user is
    standing: a text at 23:40 Pacific is Thursday's, and filing it under
    Friday because UTC had already rolled over would put it in a summary he
    reads the morning after he stops caring about it. So the conversion to a
    local date happens here, once, and every caller files by what it returns.
    """
    if not isinstance(value, str) or not value:
        return None
    text = value.strip()
    if text.endswith("Z") or text.endswith("z"):
        text = text[:-1] + "+00:00"
    try:
        at = datetime.fromisoformat(text)
    except ValueError:
        return None
    if at.tzinfo is None:
        # A naive stamp is one of our own files, which writes local seconds.
        return at.date().isoformat()
    return at.astimezone().date().isoformat()


def today():
    """The local date, as the summaries are filed."""
    return datetime.now().date().isoformat()


def utc_stamp():
    """ISO 8601 UTC with a Z, the shape everything on the wire uses."""
    return datetime.now(timezone.utc).isoformat(timespec="seconds").replace(
        "+00:00", "Z")


# -- the allowlist ------------------------------------------------------------

def clean_config(doc):
    """One config document, validated. Returns (config, None) or (None, why).

    Strict rather than forgiving, because this file is the allowlist and the
    allowlist is a security control on both sides of the wire: the Bridge drops
    rows from chats it does not name, and the collector refuses sends to chats
    whose policy it does not like. A half-understood entry here would be a
    conversation quietly readable or quietly sendable, and both of those are the
    failure this whole feature is careful about.

    Every rejection names the field. The only callers are a program being
    written against this by hand and a route answering a person.
    """
    if not isinstance(doc, dict):
        return None, "config must be a JSON object"
    chats = doc.get("chats")
    if not isinstance(chats, dict):
        return None, "chats must be an object keyed by chat_guid"

    out = {}
    for guid, entry in chats.items():
        if not isinstance(guid, str) or not guid.strip():
            return None, "every chat key must be a non-empty chat_guid"
        if not isinstance(entry, dict):
            return None, f"the entry for {guid[:40]} must be an object"

        policy = entry.get("send")
        if policy not in POLICIES:
            return None, f"send for {guid[:40]} must be one of {list(POLICIES)}"

        read = entry.get("read")
        if not isinstance(read, bool):
            return None, f"read for {guid[:40]} must be a boolean"

        name = entry.get("name")
        if name is not None and not isinstance(name, str):
            return None, f"name for {guid[:40]} must be a string or null"
        if isinstance(name, str) and len(name) > NAME_MAX_CHARS:
            return None, (f"name for {guid[:40]} must be at most "
                          f"{NAME_MAX_CHARS} characters")

        out[guid] = {"read": read, "send": policy, "name": name or None}

    return {"updated_at": doc.get("updated_at") or utc_stamp(),
            "chats": out}, None


def load_config():
    """The allowlist as the pipeline should read it. Never raises.

    Best effort on purpose, unlike `clean_config`: a worker that refused to run
    because one entry in this file went strange would stop classifying every
    conversation over one bad line. A malformed entry is dropped and the rest of
    the allowlist still means what it says.
    """
    doc = read_json(CONFIG_PATH)
    if not isinstance(doc, dict):
        return {"updated_at": None, "chats": {}}
    chats = doc.get("chats")
    if not isinstance(chats, dict):
        return {"updated_at": doc.get("updated_at"), "chats": {}}
    out = {}
    for guid, entry in chats.items():
        if not isinstance(guid, str) or not guid.strip():
            continue
        if not isinstance(entry, dict):
            continue
        policy = entry.get("send")
        name = entry.get("name")
        out[guid] = {
            "read": bool(entry.get("read")),
            # An unreadable policy reads as `off`, which is the direction a
            # failure in an allowlist should fall.
            "send": policy if policy in POLICIES else "off",
            "name": name if isinstance(name, str) and name else None,
        }
    return {"updated_at": doc.get("updated_at"), "chats": out}


def save_config(doc):
    """Validate and replace the allowlist. Returns (config, None) or (None, why).

    Whole-document replacement rather than a merge, matching what the app sends:
    the picker holds every chat it knows about and posts the state it wants, so a
    merge here would make un-allowlisting a conversation impossible to express.
    """
    config, why = clean_config(doc)
    if why:
        return None, why
    os.makedirs(MESSAGES_DIR, exist_ok=True)
    if not write_json(CONFIG_PATH, config):
        return None, "cannot write the config"
    return config, None


def allowlisted(config=None):
    """The chat_guids marked readable, as a set. The summary's scope."""
    config = config or load_config()
    return {guid for guid, entry in config["chats"].items()
            if entry.get("read")}


def threads_path(chat):
    return os.path.join(THREADS_DIR, f"{chat}.jsonl")


def thread_keys(chat, last=None):
    """The conversation's message keys, oldest first, off the collector's
    per-chat index. None when the file is absent (an older store), which a
    caller must not mistake for an empty conversation."""
    try:
        fh = open(threads_path(chat))
    except OSError:
        return None
    rows = []
    with fh:
        for line in fh:
            try:
                doc = json.loads(line)
            except ValueError:
                continue
            key = doc.get("key") if isinstance(doc, dict) else None
            if isinstance(key, str) and KEY_RE.fullmatch(key):
                rows.append((str(doc.get("at") or ""), doc.get("rowid") or 0, key))
    rows.sort()
    seen, keys = set(), []
    for _, _, key in rows:
        if key in seen:
            continue
        seen.add(key)
        keys.append(key)
    return keys[-last:] if last else keys
