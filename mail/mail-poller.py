#!/usr/bin/env python3
"""The mailbox into files on disk. Runs every five minutes, one pass, exits.

Deploys to /home/pi/charon-mail/bin/mail-poller.py and is started by
charon-mail-poll.timer. This is the only process in the system that reads the
mailbox, and it holds the only copy of the mailbox password along with the
actions worker. The collector never touches IMAP: one credential holder, and
every mutation the dashboard wants goes through a spool file instead.

Four things happen per pass, in this order:

    1. new mail          UID SEARCH above the cursor, then fetch and index it
    2. flags reconcile   what is unread and what is still in INBOX
    3. prune             old, archived, nothing depends on it
    4. state.json        the cursor and the health line, written last

Written last on purpose. state.json is what the collector reads to decide
whether this feature is alive, so it is the receipt for a pass that finished,
not a promise made by one that started.

**BODY.PEEK everywhere.** A bare `RFC822` or `BODY[...]` fetch sets \\Seen as a
side effect, so one careless fetch here marks an entire mailbox read,
irreversibly, for a human who was using it. The SELECT is EXAMINE (readonly) as
well, which makes that structural rather than careful: this process cannot
change a flag even if a fetch spec is wrong.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import os
import re
import sys
import time
from datetime import datetime, timedelta

import maillib
from maillib import MailError, log, stamp

LOCK_PATH = os.path.join(maillib.MAIL_DIR, ".poller.lock")

# First sync, and the sync after a UIDVALIDITY reset. Bounded twice: by count so
# a decade-old mailbox does not pull 40,000 messages down a home uplink, and by
# age so the bound is the recent past rather than an arbitrary slice.
BACKFILL_MAX = 200
BACKFILL_DAYS = 30

# Backfilled mail older than this is indexed but not triaged. The first sync
# would otherwise queue 200 messages at once, and a week-old newsletter does not
# need a verdict: nothing is going to be done about it either way.
TRIAGE_SKIP_DAYS = 7

# Headers for fifty messages is one round trip and a few hundred kilobytes.
# Fetching them one at a time over the Pi's Wi-Fi is the difference between a
# two second pass and a two minute one.
FETCH_CHUNK = 50

# Gone from INBOX, older than this, and nothing on disk points at it. See
# prune(): the outbox and the audit log are never in scope, ever.
PRUNE_DAYS = 90

# A FETCH response is bytes, and the attributes are not JSON, so they are read
# with three narrow regexes rather than a general IMAP parser. Anything these
# cannot find is treated as absent, which is how a server with an unexpected
# attribute order costs a flag rather than a pass.
RE_UID = re.compile(rb"\bUID\s+(\d+)")
RE_FLAGS = re.compile(rb"\bFLAGS\s+\(([^)]*)\)")
RE_SIZE = re.compile(rb"\bRFC822\.SIZE\s+(\d+)")


# -- reading what imaplib hands back ------------------------------------------

def fetch_parts(data):
    """A FETCH payload as (attributes, literal) per message.

    imaplib returns a flat list where a literal arrives as a tuple of (the
    attribute text up to the literal, the literal itself), and the bytes element
    that follows carries whatever the server wrote after it. Usually that is
    just the closing paren, but a server is entitled to put FLAGS there, so the
    trailing element is glued onto the attribute text rather than dropped and
    every regex below sees the whole line.
    """
    out = []
    for i, item in enumerate(data):
        if not isinstance(item, tuple) or len(item) < 2:
            continue
        attrs = item[0] or b""
        nxt = data[i + 1] if i + 1 < len(data) else None
        if isinstance(nxt, (bytes, bytearray)):
            attrs = attrs + b" " + bytes(nxt)
        out.append((attrs, item[1] or b""))
    return out


def int_attr(attrs, pattern):
    found = pattern.search(attrs)
    if not found:
        return None
    try:
        return int(found.group(1))
    except ValueError:
        return None


def flag_attr(attrs):
    found = RE_FLAGS.search(attrs)
    if not found:
        return []
    return found.group(1).decode("ascii", "replace").split()


def chunked(items, size):
    for i in range(0, len(items), size):
        yield items[i:i + size]


def index_keys():
    """Every key with an index record. Names are re-validated rather than
    trusted: this directory is read by a process that turns names into paths."""
    out = []
    try:
        with os.scandir(maillib.INDEX_DIR) as entries:
            for entry in entries:
                name, _, ext = entry.name.rpartition(".")
                if ext == "json" and maillib.KEY_RE.fullmatch(name):
                    out.append(name)
    except OSError:
        return []
    return out


# -- new mail -----------------------------------------------------------------

def fetch_body(conn, uid):
    """The whole message, raw, or None. PEEK, so it stays unread."""
    typ, data = conn.uid("FETCH", str(uid), "(BODY.PEEK[])")
    if typ != "OK":
        log(f"uid {uid}: body fetch failed: {data}")
        return None
    for _, raw in fetch_parts(data):
        if raw:
            return raw
    return None


def wants_triage(record, backfill):
    """Whether this message gets a verdict queued for it.

    Three ways to say no: it already has one (a UIDVALIDITY reset re-indexes
    messages that were triaged months ago, and paying for that twice is just
    paying twice), it is old backfill, or its date is unreadable and it arrived
    in a backfill, where the safe reading of "no date" is "old".
    """
    if os.path.exists(maillib.ai_path(record["key"])):
        return False
    if not backfill:
        return True
    at = maillib.parse_time(record.get("date"))
    if at is None:
        return False
    return datetime.now().astimezone() - at <= timedelta(days=TRIAGE_SKIP_DAYS)


def store(conn, record, backfill):
    """One message onto disk: body, then record, then spool entry.

    That order is the contract. The record claims `body_cached`, so the body is
    written before the claim; the spool entry means "not triaged yet", so it is
    written after the thing triage will read. A pass that dies between any two
    of these steps leaves state that is still true.
    """
    key = record["key"]
    eml = maillib.eml_path(key)
    raw = None

    if record["size"] and record["size"] > maillib.BODY_MAX_BYTES:
        log(f"{key}: {record['size']} bytes is over the cache ceiling; headers only")
    elif os.path.exists(eml) and os.path.getsize(eml) > 0:
        # Re-indexed after a UIDVALIDITY reset. The .eml is keyed by Message-ID
        # and mail is immutable, so the copy on disk is the same bytes the
        # server would send again, and reading it is cheaper than a round trip.
        try:
            with open(eml, "rb") as fh:
                raw = fh.read()
        except OSError as exc:
            log(f"{key}: cannot re-read the cached body ({exc}); fetching it again")
            raw = fetch_body(conn, record["uid"])
    else:
        fetched = fetch_body(conn, record["uid"])
        if fetched and maillib.write_atomic(eml, fetched):
            raw = fetched

    # Every body-derived field is derived here, on both paths. The re-index path
    # used to trust the record it was replacing, which quietly dropped the
    # attachment list for every message in a mailbox that had been renumbered.
    if raw:
        msg = maillib.parse_message(raw)
        text, truncated = maillib.extract_text(msg)
        maillib.write_atomic(maillib.text_path(key), text)
        record["attachments"] = maillib.attachments(msg)
        record["body_cached"] = True
        record["truncated"] = truncated

    if not maillib.write_json(maillib.index_path(key), record):
        return False
    if wants_triage(record, backfill):
        maillib.spool_add(maillib.QUEUE_DIR, f"triage-{key}")
    return True


def ingest(conn, uids, uidvalidity, backfill, state):
    """Fetch, index and queue every uid given. Returns how many landed.

    Ascending order with a cursor that stops advancing at the first failure: a
    message that could not be written must stay above the cursor or it is never
    seen again, and everything below the failure is genuinely done. Re-fetching
    a message that was already indexed is harmless, so the cursor is allowed to
    be conservative and never allowed to be optimistic.
    """
    stored = 0
    stalled = False
    for chunk in chunked(sorted(uids), FETCH_CHUNK):
        spec = ",".join(str(uid) for uid in chunk)
        typ, data = conn.uid("FETCH", spec, "(UID FLAGS RFC822.SIZE BODY.PEEK[HEADER])")
        if typ != "OK":
            raise MailError(f"header fetch failed for {len(chunk)} uids: {data}")

        by_uid = {}
        for attrs, raw in fetch_parts(data):
            uid = int_attr(attrs, RE_UID)
            if uid is not None:
                by_uid[uid] = (attrs, raw)

        for uid in chunk:
            got = by_uid.get(uid)
            if got is None:
                # The message was deleted between the SEARCH and the FETCH.
                # Ordinary in a live mailbox, and the cursor may pass it.
                if not stalled:
                    state["last_uid"] = uid
                continue
            attrs, raw = got
            try:
                msg = maillib.parse_message(raw)
                record = maillib.parse_headers(
                    msg, uid, uidvalidity, flag_attr(attrs), int_attr(attrs, RE_SIZE) or 0)
                ok = store(conn, record, backfill)
            except Exception as exc:  # noqa: BLE001
                # One unparseable message is not a failed pass. It stays above
                # the cursor and gets one more try on the next fire.
                log(f"uid {uid}: cannot index: {exc!r}")
                ok = False
            if ok:
                stored += 1
                if not stalled:
                    state["last_uid"] = uid
            else:
                stalled = True
    return stored


# -- flags --------------------------------------------------------------------

def reconcile(conn, uidvalidity):
    """What the mailbox thinks, over what this index remembers.

    The operator reads mail in other clients too, so `unread` here goes stale
    the moment they open something on a phone, and `in_inbox` goes stale the moment
    anything moves a message out of INBOX -- including this system's own archive
    verb, which is a move rather than a flag. Two searches settle both for the
    whole mailbox at once, which is cheaper than one FETCH per record and does
    not care how many messages changed.

    `flagged` is deliberately not reconciled: nothing in the console acts on a
    star, and a third search per pass to keep a field nothing reads current is
    work for its own sake. It stays whatever it was at index time.

    Records from an older UIDVALIDITY are skipped rather than updated. Their
    uids belong to a numbering the server has thrown away, and matching them
    against this one would flip flags at random.
    """
    unseen = set(maillib.uid_search(conn, "UNSEEN"))
    present = set(maillib.uid_search(conn, "ALL"))
    changed = 0
    for key in index_keys():
        record = maillib.read_json(maillib.index_path(key))
        if record is None or record.get("uidvalidity") != uidvalidity:
            continue
        uid = record.get("uid")
        if not isinstance(uid, int):
            continue
        unread = uid in unseen
        in_inbox = uid in present
        if unread == record.get("unread") and in_inbox == record.get("in_inbox"):
            continue
        record["unread"] = unread
        record["in_inbox"] = in_inbox
        if maillib.write_json(maillib.index_path(key), record):
            changed += 1
    return changed, len(present)


# -- prune --------------------------------------------------------------------

def outbox_keys():
    """Every message key some outbox record points at.

    A key that was ever replied to is never pruned, however old and however
    archived: the outbox and the audit log are the permanent record of the one
    irreversible thing this system does, and a send whose original is missing is
    an audit trail with a hole in it.
    """
    keys = set()
    try:
        with os.scandir(maillib.OUTBOX_DIR) as entries:
            for entry in entries:
                if not entry.name.endswith(".json"):
                    continue
                record = maillib.read_json(entry.path)
                if record and isinstance(record.get("key"), str):
                    keys.add(record["key"])
    except OSError:
        pass
    return keys


def prune():
    """Drop what is gone, old, and unreferenced. All three, or it stays.

    Never touches outbox/ or audit.log. Never touches anything still in INBOX,
    however old: an old message sitting in the inbox is sitting there because
    somebody left it there.
    """
    protected = outbox_keys()
    now = datetime.now().astimezone()
    removed = 0
    for key in index_keys():
        path = maillib.index_path(key)
        record = maillib.read_json(path)
        if record is None or record.get("in_inbox"):
            continue
        if key in protected:
            continue
        if os.path.exists(maillib.draft_path(key)) or \
                os.path.exists(maillib.user_draft_path(key)):
            continue
        at = maillib.parse_time(record.get("date"))
        if at is None:
            try:
                at = datetime.fromtimestamp(os.path.getmtime(path)).astimezone()
            except OSError:
                continue
        if now - at < timedelta(days=PRUNE_DAYS):
            continue
        for victim in (path, maillib.eml_path(key), maillib.text_path(key),
                       maillib.ai_path(key)):
            try:
                os.remove(victim)
            except FileNotFoundError:
                pass
            except OSError as exc:
                log(f"{key}: cannot prune {victim}: {exc}")
        removed += 1
    return removed


# -- the pass -----------------------------------------------------------------

def poll(conn, state):
    """One full pass. Mutates state as it goes; the caller writes it out.

    Mutating rather than returning a fresh dict is what makes a pass that dies
    halfway leave a usable cursor: whatever was finished before the exception is
    already in `state`, and the finally in main() writes it.
    """
    live = maillib.select_inbox(conn, readonly=True)
    stored_validity = state.get("uidvalidity")
    last_uid = state.get("last_uid")

    backfill = (not isinstance(stored_validity, int) or stored_validity != live
                or not isinstance(last_uid, int))
    if backfill:
        why = "first poll" if not isinstance(stored_validity, int) \
            else f"UIDVALIDITY {stored_validity} is now {live}"
        log(f"{why}: backfilling the newest {BACKFILL_MAX} messages "
            f"within {BACKFILL_DAYS} days")
        state["uidvalidity"] = live
        state["last_uid"] = 0
        since = maillib.imap_date(datetime.now() - timedelta(days=BACKFILL_DAYS))
        uids = maillib.uid_search(conn, "SINCE", since)[-BACKFILL_MAX:]
    else:
        # `UID <n>:*` is not empty when nothing is above n. The server returns
        # the highest existing uid instead, because the range is read as
        # "n to infinity" and * resolves to that highest uid, so the result is
        # filtered rather than trusted. Without this every quiet poll re-indexes
        # the newest message.
        uids = [uid for uid in maillib.uid_search(conn, "UID", f"{last_uid + 1}:*")
                if uid > last_uid]

    new = ingest(conn, uids, live, backfill, state) if uids else 0
    changed, total = reconcile(conn, live)
    removed = prune()
    log(f"{new} new, {changed} flag changes, {removed} pruned, {total} in INBOX")
    state["new_messages"] = new
    state["mailbox_total"] = total
    return new


def write_state(state, error, seconds):
    """The cursor and the health line, written last and written always.

    Always, including after a failure: `last_error` is how the collector draws
    this source as degraded instead of as quietly fine, and a pass that failed
    without saying so is the worst version of every one of these bugs.
    """
    state["schema_version"] = 1
    state["last_poll_at"] = stamp()
    # Both spellings of the outcome, because the collector keys degraded on
    # the boolean and prints the sentence. One without the other is a panel
    # that either cannot turn amber or cannot say why it did.
    state["last_poll_ok"] = error is None
    state["last_error"] = error
    state["duration_s"] = seconds
    state["indexed"] = len(index_keys())
    state.setdefault("new_messages", 0)
    state.setdefault("mailbox_total", 0)
    maillib.write_json(maillib.STATE_PATH, state)


def main():
    maillib.load_env(maillib.MAIL_ENV_PATH)
    if not maillib.take_lock(LOCK_PATH):
        # The last pass is still running. Not an error: this one has nothing to
        # add, and the timer will be back in five minutes.
        return 0
    maillib.ensure_dirs()

    began = time.monotonic()
    state = maillib.read_json(maillib.STATE_PATH) or {}
    conn = None
    error = None
    try:
        conn = maillib.imap_connect()
        poll(conn, state)
    except MailError as exc:
        error = str(exc)
        log(error)
    except Exception as exc:  # noqa: BLE001
        error = f"poll failed: {exc!r}"
        log(error)
    finally:
        maillib.imap_close(conn)

    write_state(state, error, round(time.monotonic() - began, 1))
    # Exit 0 even on a failed pass. The failure is recorded in state.json where
    # the dashboard shows it; a failed unit would additionally need a human to
    # clear it before the timer would run again, and an unreachable mailbox is
    # an ordinary Tuesday on a home uplink.
    return 0


if __name__ == "__main__":
    sys.exit(main())
