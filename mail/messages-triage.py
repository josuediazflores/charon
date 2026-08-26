#!/usr/bin/env python3
"""Verdicts, reply drafts and the daily read for queued texts. Drains, exits.

Deploys to /home/pi/charon-mail/bin/messages-triage.py and is started by
charon-messages-triage.path the moment messages/.queue stops being empty. No
polling loop, no daemon: the path unit is the clock, the same way it is for the
mail worker, and an idle Pi runs nothing at all.

Three kinds of work arrive on the same queue:

    triage-<key>        up to eight at a time, one cheap-tier call for the batch
    draft-<chat_key>    one at a time, one good-tier call each
    summary-<date>      one local day of every conversation, good tier

Tiers rather than model names: llm.py owns which model a tier resolves to under
whichever provider is configured, and hands back the id it actually used so the
record says what really answered.

Batched because the alternative is a session per text message, and a session per
text message is how a subscription gets spent classifying "ok". Drafts and
summaries are not batched: there are a few a day, they are the operator's own
voice and their own read of the day, and they get the better model.

**This worker has no way to put anything on a wire.** It writes verdicts, drafts
and summaries. It does not write the queued-send records, it does not talk to
the Mac, and it opens nothing. The Bridge performs sends and runs no model; this
file runs a model and performs nothing. Each half is verified by grepping the
file for the other half's vocabulary, which is a test a reviewer runs in one
second and an invariant that cannot quietly rot. The commands live in
MESSAGES.md and deliberately not here, because a file that names the string
being grepped for is a file that fails its own test.

Every call is text-in, text-out, with no tools: the conversation goes in as
marked untrusted data and the verdict comes back as fenced text. Under an HTTP
provider that is enforced by the transport having no filesystem at all. Under
the claude-cli provider it is INTENDED to be enforced by running in mail-env/,
whose settings.json has an empty allow list and denies Edit over the whole tree,
which is why the systemd unit sets WorkingDirectory there -- but whether the CLI
picks that file up depends on where your version of it looks for settings, so
verify the wiring on your install before treating it as a boundary.

Either way, everything the model says is re-validated here before it reaches
disk, because a prompt is a request and a request is not a constraint. That
validation -- defang(), the keyed fences, clean_tags, clean_urgency, clean_bool,
clean_summary, clean_day -- is provider-independent and is what holds the line.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import json
import os
import re
import sys
import time
from datetime import datetime

import llm
import msglib
from msglib import log, stamp

LOCK_PATH = os.path.join(msglib.MESSAGES_DIR, ".triage.lock")
TRIAGE_PROMPT = os.path.join(msglib.ENV_DIR, "messages-triage.md")
REPLY_PROMPT = os.path.join(msglib.ENV_DIR, "messages-reply.md")
SUMMARY_PROMPT = os.path.join(msglib.ENV_DIR, "messages-summary.md")
# The daily summary was removed from the console (2026-08-22): nobody reads it
# there, and it cost a model call a few times a day. The verb still works when
# a summary-<date> entry is spooled by hand; only the automatic enqueue is off.
SUMMARIES_ENABLED = False

# Eight at a time, like mail. A text is a tenth the size of an email, so the
# batch could be much larger, and it is not: every message in a batch that fails
# shares the failure, and eight is already one call per forty texts.
BATCH_MAX = 8

# What the classifier sees of one text. Almost every message is under two
# hundred characters; this bounds the pathological one that pasted a contract
# into a thread.
TRIAGE_BODY_CHARS = 2000

# What the drafter sees, per message, over the last stretch of the thread.
DRAFT_BODY_CHARS = 1200

# How much of a conversation a draft is written against. Twenty is about a
# screen and a half of texts, which is the window in which the thing being
# answered actually lives. More context is not more accuracy here: it is an
# older conversation competing with the current one.
DRAFT_CONTEXT = 20

# What one draft may be. A text is short, and a model given no ceiling writes an
# email. Clipped rather than rejected: a long draft is still a usable first
# sentence, and the compose box is where it gets cut down anyway.
DRAFT_CHARS = 500

# What the summariser sees of one text. Shorter than triage's: the day's read is
# about the shape of a conversation, not its wording, and a day can hold a few
# hundred messages.
DAY_BODY_CHARS = 400

# How many index records one pass will open, newest by mtime first. The ceiling
# is on the opens rather than on the scandir, the same bound mail's index scan
# carries and for the same reason: a store that outgrows it reports its newest
# INDEX_SCAN_MAX, which is a number you can reason about, rather than getting
# slower every month.
INDEX_SCAN_MAX = 2000

# Three tries and the message is marked failed and leaves the queue. It cannot
# stay: the path unit re-fires while the queue is non-empty, so an entry nothing
# can ever parse would be an infinite loop with a model call in it.
MAX_ATTEMPTS = 3

# One call, one wall clock, so a wedged session does not sit on the queue behind
# everything else.
TRIAGE_TIMEOUT_S = 420
DRAFT_TIMEOUT_S = 300
SUMMARY_TIMEOUT_S = 420

# Bounds on what the model is allowed to claim, applied on the way in rather
# than on the way out: this output is rendered on a screen and read by somebody
# deciding who to answer first.
TAGS_MAX = 4
SUMMARY_CHARS = 160
DAY_ITEMS_MAX = 8
DAY_LINE_CHARS = 200
DAY_PROSE_CHARS = 1200

# Ten minutes. Today's summary is rewritten while messages keep arriving, and
# without this every batch of texts would spend a good-tier call re-reading the
# same day. The debounce is on the file's own age rather than on a timer, so a
# quiet afternoon costs nothing and a busy one costs six calls.
SUMMARY_DEBOUNCE_S = 600

# Positive extraction. Not "strip the code fences and hope": the block must open
# with a key this batch actually asked about and close with the same key, so
# prose around it, a preamble, or a second opinion the model volunteered are all
# simply not matched. \1 is the whole guard.
MSG_BLOCK = re.compile(r"<<<MSG\s+([0-9a-f]{16})>>>(.*?)<<<END\s+\1>>>", re.DOTALL)
REPLY_BLOCK = re.compile(r"<<<REPLY>>>(.*?)<<<END>>>", re.DOTALL)
DAY_BLOCK = re.compile(r"<<<SUMMARY>>>(.*?)<<<END>>>", re.DOTALL)


# -- what the model is shown --------------------------------------------------

def defang(text):
    """Take the fence markers out of a text before it goes inside a fence.

    A message is allowed to contain the literal string that ends its own block,
    and somebody who does so on purpose could close the untrusted region early
    and continue as if they were the prompt. Breaking the run of angle brackets
    costs nothing a classifier needs and closes that door.
    """
    return (text or "").replace("<<<", "< <<").replace(">>>", ">> >")


def body_text(key, limit):
    """One stored text, capped, defanged, or "" when nothing was stored."""
    try:
        with open(msglib.text_path(key)) as fh:
            return defang(fh.read(limit))
    except OSError:
        return ""


def clock(value):
    """`HH:MM` local, or "??:??". The only time format anywhere in these
    prompts: a transcript is read as a sequence of moments in one day, and a
    full ISO stamp on every line is nine characters of noise per message."""
    if not isinstance(value, str) or not value:
        return "??:??"
    text = value.strip()
    if text.endswith("Z") or text.endswith("z"):
        text = text[:-1] + "+00:00"
    try:
        at = datetime.fromisoformat(text)
    except ValueError:
        return "??:??"
    if at.tzinfo is not None:
        at = at.astimezone()
    return at.strftime("%H:%M")


def who(record):
    """One name for the sender of one row. `you` for our own messages, which is
    what makes a transcript readable as a conversation rather than as a list of
    phone numbers."""
    if record.get("is_from_me"):
        return "you"
    return (record.get("sender_name") or record.get("sender")
            or record.get("chat_identifier") or "them")


def chat_name(record):
    return (record.get("chat_name") or record.get("chat_identifier")
            or "unnamed chat")


def message_block(record, limit):
    """One message as the triage prompt sees it: labeled, fenced, untrusted.

    The key is on the marker as well as inside the block, because the model has
    to echo it back and a key it can only see once is a key it can only get
    wrong once.
    """
    key = record["key"]
    lines = [
        f"<<<BEGIN MESSAGE {key}>>>",
        f"key: {key}",
        f"chat: {defang(chat_name(record))[:120]}",
        f"group: {'yes' if record.get('is_group') else 'no'}",
        f"from: {defang(who(record))[:120]}",
        f"time: {record.get('created_at') or 'unknown'}",
        "",
        body_text(key, limit) or "(no text was stored for this message)",
        f"<<<END MESSAGE {key}>>>",
    ]
    return "\n".join(lines)


def read_prompt(path):
    """A prompt file, or None. Absent is fatal for this drain: a session without
    its instructions is a chatbot being handed a stranger's conversation."""
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError as exc:
        log(f"cannot read {path}: {exc}")
        return None


# -- the store ----------------------------------------------------------------

def read_index():
    """(key, record) for the newest INDEX_SCAN_MAX rows, unordered by time.

    Two passes, like the collector's: the scandir takes names and mtimes and the
    read pass opens what it kept. mtime is the right window here and the wrong
    order, so callers sort by `created_at` themselves.
    """
    found = []
    try:
        with os.scandir(msglib.INDEX_DIR) as entries:
            for entry in entries:
                name = entry.name
                if not name.endswith(".json"):
                    continue
                key = name[:-5]
                if not msglib.KEY_RE.fullmatch(key):
                    continue
                try:
                    found.append((entry.stat().st_mtime, key, entry.path))
                except OSError:
                    # Vanished between the scan and the stat. Skipped rather
                    # than emptying the list.
                    continue
    except OSError:
        return []

    found.sort(key=lambda row: row[0], reverse=True)

    rows = []
    for _, key, path in found[:INDEX_SCAN_MAX]:
        doc = msglib.read_json(path)
        if doc is not None:
            rows.append((key, doc))
    return rows


def in_time_order(rows):
    """Oldest first, by the stamp the Mac put on the row. A record with no
    stamp sorts first rather than crashing the sort."""
    def at(pair):
        rowid = pair[1].get("rowid")
        return (str(pair[1].get("created_at") or ""),
                rowid if isinstance(rowid, int) else 0)
    return sorted(rows, key=at)


def chat_records(chat):
    """Every stored message of one conversation, oldest first.

    Through the collector's per-chat key index when the store has one:
    the mtime window below misses any conversation whose rows are old on
    disk, which after a history backfill is most of them. The scan stays
    as the fallback for a store that predates the index."""
    keys = msglib.thread_keys(chat)
    if keys is not None:
        rows = []
        for key in keys:
            doc = msglib.read_json(msglib.index_path(key))
            if isinstance(doc, dict):
                rows.append((key, doc))
        return rows
    return in_time_order([(key, doc) for key, doc in read_index()
                          if doc.get("chat_key") == chat])


def day_records(date):
    """Every stored message of one local date, oldest first, across chats."""
    return in_time_order([(key, doc) for key, doc in read_index()
                          if msglib.local_date(doc.get("created_at")) == date])


def chat_guid_for(chat, records=None):
    """The conversation's real GUID, off the newest record that names it or off
    the allowlist. **Never off a request**: this string is what the Bridge hands
    to Messages.app, and a caller who could choose it could choose a recipient.
    """
    for _, doc in reversed(records if records is not None else chat_records(chat)):
        guid = doc.get("chat_guid")
        if isinstance(guid, str) and guid:
            return guid
    for guid in msglib.load_config()["chats"]:
        if msglib.chat_key(guid) == chat:
            return guid
    return None


# -- the verdict --------------------------------------------------------------

def clean_tags(raw):
    """Only allowlisted tags, deduped, in the order the model offered them.

    The prompt lists the allowlist and the model is good at following it. This
    is not about the model: it is about what may reach a field the console
    renders and the collector counts.
    """
    out = []
    if not isinstance(raw, list):
        return out
    for tag in raw:
        if not isinstance(tag, str):
            continue
        tag = tag.strip().lower()
        if tag in msglib.TAGS and tag not in out:
            out.append(tag)
        if len(out) >= TAGS_MAX:
            break
    return out


def clean_urgency(raw):
    """An int in 0..3. Anything else becomes 0.

    Clamped rather than rejected: a message the model rated 7 is one it felt
    strongly about, and dropping the whole verdict over the number would lose
    the tags and the summary too. 0 for unparseable, because an unreadable
    urgency should never be the thing that jumps to the top of the screen.
    """
    if isinstance(raw, bool):
        return 0
    if isinstance(raw, str):
        raw = raw.strip()
        try:
            raw = int(raw)
        except ValueError:
            return 0
    if isinstance(raw, float):
        raw = int(raw)
    if not isinstance(raw, int):
        return 0
    return max(0, min(3, raw))


def clean_bool(raw):
    """A flag, from whatever shape the model chose to express it in.

    False for anything unreadable, and that direction is the decision: this flag
    drives a list whose whole value is being short, and a broken parse that
    added a conversation to it would make the list less true every time it
    failed.
    """
    if isinstance(raw, bool):
        return raw
    if isinstance(raw, str):
        word = raw.strip().lower()
        if word in ("true", "yes", "y", "1"):
            return True
        return False
    if isinstance(raw, (int, float)):
        return bool(raw)
    return False


def clean_summary(raw):
    """One line, bounded. A list becomes its first usable string, because a
    model that answered in mail's shape still answered."""
    if isinstance(raw, list):
        raw = next((line for line in raw if isinstance(line, str)), "")
    if not isinstance(raw, str):
        return ""
    return " ".join(raw.split())[:SUMMARY_CHARS]


def write_verdict(key, payload, model):
    """One ai record. Returns True when it landed.

    Field for field the shape mail writes, plus `needs_you`, so the collector's
    reading of an artifact is one piece of code rather than two.
    """
    return msglib.write_json(msglib.ai_path(key), {
        "key": key,
        "tags": clean_tags(payload.get("tags")),
        "urgency": clean_urgency(payload.get("urgency")),
        "needs_you": clean_bool(payload.get("needs_you")),
        "summary": clean_summary(payload.get("summary")),
        "model": model,
        "status": "ok",
        "attempts": 0,
        "at": stamp(),
    })


def bump_attempt(key, why):
    """One more try used up, and the entry dropped once they are gone.

    The count lives in the ai record because that is the file that already
    exists per message and the console already reads. A pending record carries
    no verdict at all -- urgency null, no tags -- so nothing downstream can
    mistake "not classified yet" for "classified as nothing".
    """
    record = msglib.read_json(msglib.ai_path(key)) or {}
    attempts = record.get("attempts")
    attempts = attempts + 1 if isinstance(attempts, int) else 1
    done = attempts >= MAX_ATTEMPTS
    msglib.write_json(msglib.ai_path(key), {
        "key": key,
        "tags": [],
        "urgency": None,
        "needs_you": False,
        "summary": "",
        "model": None,
        "status": "failed" if done else "pending",
        "attempts": attempts,
        "error": str(why)[:300],
        "at": stamp(),
    })
    if done:
        log(f"{key}: giving up after {attempts} attempts ({why})")
        msglib.spool_drop(msglib.QUEUE_DIR, f"triage-{key}")


# -- triage -------------------------------------------------------------------

def triage_batch(keys, system):
    """One session for up to eight messages. Unspools only what it parsed.

    A key that comes back parsed is done. A key that does not -- the model
    skipped it, the JSON in its block was malformed, it answered about a message
    nobody asked about -- keeps its queue entry and burns one attempt. That
    asymmetry is the whole retry design: the queue stays true, and the only way
    off it is a verdict or three failures.
    """
    blocks = []
    live = []
    for key in keys:
        record = msglib.read_json(msglib.index_path(key))
        if record is None or record.get("key") != key:
            # A spool entry naming a message that is not indexed. Nothing can
            # ever classify it, so it leaves the queue instead of being retried
            # until the end of time.
            log(f"{key}: no index record; dropping the spool entry")
            msglib.spool_drop(msglib.QUEUE_DIR, f"triage-{key}")
            continue
        blocks.append(message_block(record, TRIAGE_BODY_CHARS))
        live.append(key)

    if not live:
        return

    prompt = "\n\n".join([system, f"Messages in this batch: {len(live)}"] + blocks)
    began = time.monotonic()
    text, failed, model_id = llm.run_session(
        prompt, llm.TIER_CHEAP, TRIAGE_TIMEOUT_S, cwd=msglib.ENV_DIR)
    if failed:
        log(f"triage of {len(live)} messages failed: {failed}")
        for key in live:
            bump_attempt(key, failed)
        return

    wanted = set(live)
    seen = set()
    for found in MSG_BLOCK.finditer(text):
        key = found.group(1)
        if key not in wanted or key in seen:
            # A block about a message that was not in this batch. Not an error
            # worth failing over, and absolutely not something to write: the
            # only keys this session was shown are the ones it may answer for.
            continue
        try:
            payload = json.loads(found.group(2).strip())
        except ValueError:
            continue
        if not isinstance(payload, dict):
            continue
        if write_verdict(key, payload, model_id):
            seen.add(key)
            msglib.spool_drop(msglib.QUEUE_DIR, f"triage-{key}")

    for key in wanted - seen:
        bump_attempt(key, "the session returned no usable block for this message")
    log(f"triage: {len(seen)} of {len(live)} classified by {model_id} "
        f"in {round(time.monotonic() - began, 1)}s")

    if seen:
        queue_today()


def queue_today():
    """Ask for today's summary again, unless one is already asked for or the
    one on disk is recent.

    Two guards rather than one. The spool check stops a batch of forty texts
    from filing forty requests for the same day; the age check stops a busy
    afternoon from spending a good-tier call every time three messages land.
    Together they put a floor of SUMMARY_DEBOUNCE_S under the cost of a day.
    """
    if not SUMMARIES_ENABLED:
        return
    date = msglib.today()
    entry = f"summary-{date}"
    if entry in msglib.spooled(msglib.QUEUE_DIR):
        return
    try:
        age = time.time() - os.path.getmtime(msglib.summary_path(date))
    except OSError:
        age = None
    if age is not None and age < SUMMARY_DEBOUNCE_S:
        return
    msglib.spool_add(msglib.QUEUE_DIR, entry)


# -- drafts -------------------------------------------------------------------

def draft_one(chat, system):
    """One reply draft, on the good tier, for one conversation.

    Written against the conversation rather than one message, which is the whole
    difference from mail: a text answers a thread, and the message that came in
    last is very often not the one being answered.

    The record is written for every outcome including failure, because the
    console draws its spinner from this file and a draft that failed silently is
    a spinner that never stops.

    No automatic retry. A failed draft is one tap away from being asked for
    again, and a queue entry that re-fires a good-tier session on its own is a
    way to spend a subscription on a conversation nobody is waiting on any more.
    """
    entry = f"draft-{chat}"
    records = chat_records(chat)
    if not records:
        log(f"{chat}: no messages in this conversation; the request fails")
        prior = msglib.read_json(msglib.draft_path(chat)) or {}
        msglib.write_json(msglib.draft_path(chat), {
            "chat_key": chat,
            "chat_guid": chat_guid_for(chat, records=[]),
            "status": "failed",
            "text": "",
            "instructions": prior.get("instructions") or "",
            "model": None,
            "error": "no messages in this conversation",
            "at": msglib.stamp(),
        })
        msglib.spool_drop(msglib.QUEUE_DIR, entry)
        return

    existing = msglib.read_json(msglib.draft_path(chat)) or {}
    instructions = ""
    if existing.get("status") == "pending":
        raw = existing.get("instructions")
        instructions = raw.strip()[:2000] if isinstance(raw, str) else ""

    window = records[-DRAFT_CONTEXT:]
    head = window[-1][1]
    lines = [
        f"## the conversation: {defang(chat_name(head))[:120]}"
        f" ({'group' if head.get('is_group') else 'direct'})",
        "",
        "<<<BEGIN THREAD>>>",
    ]
    for key, record in window:
        lines.append(f"[{clock(record.get('created_at'))}] "
                     f"{defang(who(record))[:60]}: "
                     f"{body_text(key, DRAFT_BODY_CHARS) or '(no text)'}")
    lines.append("<<<END THREAD>>>")

    parts = [system, "\n".join(lines)]
    if instructions:
        # The operator's own words, from the console, and the one piece of text
        # in this prompt that is an instruction rather than data.
        parts.append("## what the operator asked for in this reply\n\n"
                     + defang(instructions))

    text, failed, model_id = llm.run_session(
        "\n\n".join(parts), llm.TIER_GOOD, DRAFT_TIMEOUT_S, cwd=msglib.ENV_DIR)

    body = ""
    if not failed:
        found = REPLY_BLOCK.search(text)
        if found:
            body = found.group(1).strip()[:DRAFT_CHARS]
            if not body:
                failed = "the session returned an empty reply"
        else:
            failed = "the session did not return a fenced reply"

    doc = {
        "chat_key": chat,
        "chat_guid": chat_guid_for(chat, records),
        "status": "failed" if failed else "ready",
        "text": body,
        "instructions": instructions,
        "model": model_id,
        "error": str(failed)[:300] if failed else None,
        "at": stamp(),
    }
    if failed:
        log(f"{chat}: draft failed: {failed}")
    if msglib.write_json(msglib.draft_path(chat), doc):
        msglib.spool_drop(msglib.QUEUE_DIR, entry)
    # A write that failed leaves the entry queued: the record still says
    # pending, which is still true, and the next fire tries again. This is the
    # one failure where a retry is the right behaviour.


# -- the daily read -----------------------------------------------------------

def clean_items(raw, known):
    """One of the summary's three lists, validated. Never raises.

    `known` is the set of chat_keys that were actually in the day handed to the
    model. An entry naming anything else is dropped rather than clipped: the
    console turns a chat_key into a tap target, and a key that names no
    conversation is a row that goes nowhere.
    """
    out = []
    if not isinstance(raw, list):
        return out
    for item in raw:
        if not isinstance(item, dict):
            continue
        chat = item.get("chat_key")
        if not isinstance(chat, str) or chat not in known:
            continue
        line = item.get("line")
        if not isinstance(line, str):
            continue
        line = " ".join(line.split())[:DAY_LINE_CHARS]
        if not line:
            continue
        name = item.get("chat")
        name = " ".join(name.split())[:120] if isinstance(name, str) else None
        out.append({"chat_key": chat, "chat": name or None, "line": line})
        if len(out) >= DAY_ITEMS_MAX:
            break
    return out


def clean_day(payload, known):
    """The whole summary document's content, validated. (content, None) or
    (None, why).

    Content only: `read`, `archived` and `at` are the store's, not the model's,
    and keeping them out of here is what lets the writer below compare two
    summaries for sameness without a flag making them differ.
    """
    if not isinstance(payload, dict):
        return None, "the session did not return a JSON object"
    prose = payload.get("prose")
    if not isinstance(prose, str):
        prose = ""
    prose = " ".join(prose.split())[:DAY_PROSE_CHARS]
    return {
        "needs_you": clean_items(payload.get("needs_you"), known),
        "noticed": clean_items(payload.get("noticed"), known),
        "quiet": clean_items(payload.get("quiet"), known),
        "prose": prose,
    }, None


def day_prompt(date, records, system):
    """The day, grouped by conversation, each message with its verdict beside
    it. Returns (prompt, known_chat_keys)."""
    by_chat = {}
    for key, record in records:
        by_chat.setdefault(record.get("chat_key"), []).append((key, record))

    lines = ["<<<BEGIN DAY>>>"]
    known = set()
    for chat, rows in by_chat.items():
        if not isinstance(chat, str) or not msglib.KEY_RE.fullmatch(chat):
            continue
        known.add(chat)
        head = rows[-1][1]
        lines.append("")
        lines.append(f"## chat {chat}  {defang(chat_name(head))[:120]}"
                     f" ({'group' if head.get('is_group') else 'direct'})")
        for key, record in rows:
            lines.append(f"[{clock(record.get('created_at'))}] "
                         f"{defang(who(record))[:60]}: "
                         f"{body_text(key, DAY_BODY_CHARS) or '(no text)'}")
            art = msglib.read_json(msglib.ai_path(key))
            if isinstance(art, dict) and art.get("status") == "ok":
                tags = ",".join(t for t in (art.get("tags") or [])
                                if isinstance(t, str)) or "none"
                lines.append(
                    f"    verdict: urgency {art.get('urgency')}, "
                    f"needs_you {bool(art.get('needs_you'))}, tags {tags}"
                    f" -- {defang(str(art.get('summary') or ''))[:200]}")
    lines.append("<<<END DAY>>>")

    return "\n\n".join([system, f"The local date is {date}.",
                        "\n".join(lines)]), known


def summary_one(date):
    """One local day, read once and written only when it changed.

    Past days freeze. A summary for a date that is over and already on disk is
    the answer forever: nothing new can arrive in it, and a regeneration would
    spend a good-tier call to produce the same paragraph with a newer timestamp
    and an unread flag the user already cleared.

    Today is different and is rewritten as the day fills in, which is why the
    sameness check is on content rather than on the whole record: a rewrite that
    says exactly what the last one said must not mark the day unread again.
    """
    entry = f"summary-{date}"
    existing = msglib.read_json(msglib.summary_path(date))

    if existing is not None and date < msglib.today():
        log(f"{date}: already summarised and the day is over; leaving it alone")
        msglib.spool_drop(msglib.QUEUE_DIR, entry)
        return

    system = read_prompt(SUMMARY_PROMPT)
    if system is None:
        return

    records = day_records(date)
    if not records:
        log(f"{date}: no messages on this date; dropping the request")
        msglib.spool_drop(msglib.QUEUE_DIR, entry)
        return

    prompt, known = day_prompt(date, records, system)
    began = time.monotonic()
    text, failed, model_id = llm.run_session(
        prompt, llm.TIER_GOOD, SUMMARY_TIMEOUT_S, cwd=msglib.ENV_DIR)

    content = None
    if not failed:
        found = DAY_BLOCK.search(text)
        if not found:
            failed = "the session did not return a fenced summary"
        else:
            try:
                payload = json.loads(found.group(1).strip())
            except ValueError:
                payload = None
            content, why = clean_day(payload, known)
            if why:
                failed, content = why, None

    if failed:
        log(f"{date}: summary failed: {failed}")
        if existing is not None and existing.get("status") == "ok":
            # A failed regeneration must not eat the last good read of the day.
            # The record on disk is still true; it is only older than it could
            # have been.
            msglib.spool_drop(msglib.QUEUE_DIR, entry)
            return
        msglib.write_json(msglib.summary_path(date), {
            "date": date, "status": "failed",
            "needs_you": [], "noticed": [], "quiet": [], "prose": "",
            "model": model_id, "error": str(failed)[:300], "at": stamp(),
            "read": False,
            "archived": bool((existing or {}).get("archived")),
        })
        msglib.spool_drop(msglib.QUEUE_DIR, entry)
        return

    same = (existing is not None
            and existing.get("status") == "ok"
            and all(existing.get(field) == content[field] for field in content))
    if same:
        log(f"{date}: summary unchanged; leaving the flags as they are")
        msglib.spool_drop(msglib.QUEUE_DIR, entry)
        return

    msglib.write_json(msglib.summary_path(date), {
        "date": date,
        "status": "ok",
        **content,
        "model": model_id,
        "error": None,
        "at": stamp(),
        # A day that says something new is unread again. `archived` survives,
        # because archiving is the stronger statement and a day that
        # un-archived itself every ten minutes would be unusable.
        "read": False,
        "archived": bool((existing or {}).get("archived")),
    })
    log(f"{date}: summary written by {model_id} in "
        f"{round(time.monotonic() - began, 1)}s "
        f"({len(content['needs_you'])} needing an answer)")
    msglib.spool_drop(msglib.QUEUE_DIR, entry)


# -- the drain ----------------------------------------------------------------

def valid_subject(verb, subject):
    """Whether this entry names something this worker can act on. A key for the
    two that name a message or a conversation, a local date for the third."""
    if verb in ("triage", "draft"):
        return bool(subject) and bool(msglib.KEY_RE.fullmatch(subject))
    if verb == "summary":
        return bool(subject) and bool(msglib.DATE_RE.fullmatch(subject))
    return False


def drain():
    """Everything waiting, oldest first, then done.

    Re-scanned each pass rather than snapshotted once, so texts that arrive
    while a batch is running are picked up by this same drain instead of waiting
    for the path unit to fire again. It is also what lets a triage batch file a
    summary request that this same drain then serves.

    `attempted` is the only stop condition beyond an empty queue: an entry that
    survives its turn must not be picked again in the same drain, or this
    becomes a spin on one bad message with a model call in the middle of it.
    """
    triage_system = None
    reply_system = None
    attempted = set()

    while True:
        waiting = [name for name in msglib.spooled(msglib.QUEUE_DIR)
                   if name not in attempted]
        if not waiting:
            return

        verb, subject = msglib.split_entry(waiting[0])
        if verb not in ("triage", "draft", "summary") \
                or not valid_subject(verb, subject):
            log(f"{waiting[0]}: not a queue entry this worker understands; "
                f"dropping it")
            attempted.add(waiting[0])
            msglib.spool_drop(msglib.QUEUE_DIR, waiting[0])
            continue

        if verb == "triage":
            if triage_system is None:
                triage_system = read_prompt(TRIAGE_PROMPT)
                if triage_system is None:
                    return
            batch = []
            for name in waiting:
                kind, key = msglib.split_entry(name)
                if kind == "triage" and msglib.KEY_RE.fullmatch(key or ""):
                    batch.append(key)
                    attempted.add(name)
                if len(batch) >= BATCH_MAX:
                    break
            try:
                triage_batch(batch, triage_system)
            except Exception as exc:  # noqa: BLE001
                # One batch failing is not the drain failing. The entries stay,
                # the next fire tries them again, and the drafts behind them
                # still get written now.
                log(f"triage batch failed: {exc!r}")

        elif verb == "draft":
            attempted.add(waiting[0])
            if reply_system is None:
                reply_system = read_prompt(REPLY_PROMPT)
                if reply_system is None:
                    return
            try:
                draft_one(subject, reply_system)
            except Exception as exc:  # noqa: BLE001
                log(f"{subject}: draft failed: {exc!r}")

        else:
            attempted.add(waiting[0])
            try:
                summary_one(subject)
            except Exception as exc:  # noqa: BLE001
                log(f"{subject}: summary failed: {exc!r}")


def main():
    # secrets/env only: the subscription token, and never the mailbox password.
    # The session this worker starts inherits this environment, so what is not
    # loaded here is what a model can never be handed.
    msglib.load_env(msglib.ENV_PATH)
    if not msglib.take_lock(LOCK_PATH):
        # Another drain is already working. Not an error, and not a queue that
        # goes unserved: the running process re-scans after every batch.
        return 0
    msglib.ensure_dirs()
    began = time.monotonic()
    drain()
    log(f"drain finished in {round(time.monotonic() - began, 1)}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
