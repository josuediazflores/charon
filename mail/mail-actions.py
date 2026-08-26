#!/usr/bin/env python3
"""Mailbox writes and the one outward action this system has. Drains once.

Deploys to /home/pi/charon-mail/bin/mail-actions.py and is started by
charon-mail-actions.path when mail/.actions stops being empty. Three verbs:

    send-<id>      SMTP a reply the operator queued by clicking SEND, twice
    read-<key>     +FLAGS (\\Seen) on the server
    unread-<key>   -FLAGS (\\Seen), the same door swinging the other way
    archive-<key>  UID MOVE to the archive folder, out of INBOX

Everything else in this system drafts. This file is the exception, and it is
deliberately the dullest code in the repo: no model runs here, no child process
starts here, and nothing in this file decides anything. It reads a record a
human created, checks that the record still says what it said, and does exactly
that one thing. That absence is enforced by a grep documented in the README
rather than described here, because a file that names the string being grepped
for is a file that fails its own test.

Three guards stand between a compromised anything and an email leaving:

    1. the record must exist and still say `queued` -- a second fire on the
       same id finds `sent` and does nothing
    2. the recipient must equal the Reply-To or From of the message being
       replied to, recomputed here from the index rather than trusted from the
       record. There is no way to address a reply at a third party.
    3. any agent session on this box is meant to run under a settings.json that
       denies Edit over mail/**, so a prompt-injected run cannot write the
       record in the first place. Guards 1 and 2 hold on their own; treat this
       third one as defence in depth and verify the settings wiring on your
       install rather than leaning on it

No automatic retry, anywhere in the send path. A send that failed leaves an
error on the dashboard and the retry is a new human click producing a new
record: the failure mode of retrying a send is sending twice, and that is worse
than not sending at all.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import imaplib
import os
import smtplib
import ssl
import sys
import time
from email import policy
from email.message import EmailMessage
from email.utils import formatdate, make_msgid, parseaddr

import maillib
from maillib import MailError, log, stamp

LOCK_PATH = os.path.join(maillib.MAIL_DIR, ".actions.lock")

# What a reply may carry. The collector enforces the same ceiling on the way in;
# this is the second copy, because the file on disk is what actually gets sent.
BODY_MAX_CHARS = 64 * 1024
SUBJECT_MAX_CHARS = 200

# The connection is opened once per drain, on the first read or archive that
# needs it, and not at all for a drain that is only sending. A dict rather than
# a class: this is the whole state, and it lives exactly as long as the process.
_mailbox = {"conn": None, "uidvalidity": None, "error": None}


# -- the mailbox --------------------------------------------------------------

def mailbox():
    """(connection, uidvalidity) or (None, None) after logging why.

    readonly=False, unlike the poller's EXAMINE: this is the one worker that is
    supposed to be able to change a flag.
    """
    if _mailbox["conn"] is None and _mailbox["error"] is None:
        try:
            _mailbox["conn"] = maillib.imap_connect()
            _mailbox["uidvalidity"] = maillib.select_inbox(_mailbox["conn"], readonly=False)
        except MailError as exc:
            _mailbox["error"] = str(exc)
            log(str(exc))
        except Exception as exc:  # noqa: BLE001
            _mailbox["error"] = f"cannot open the mailbox: {exc!r}"
            log(_mailbox["error"])
    return _mailbox["conn"], _mailbox["uidvalidity"]


def routable(key):
    """The uid this key is reachable at right now, or None with a reason logged.

    A uid is only meaningful inside the UIDVALIDITY it was recorded under. When
    the server has renumbered since, the stored uid points at some other
    person's message, so the mutation is skipped and left for the poller to fix:
    it re-backfills on the same mismatch and rewrites every uid it can still
    find. Silently flagging the wrong message would be the worst outcome
    available here.
    """
    record = maillib.read_json(maillib.index_path(key))
    if record is None:
        log(f"{key}: no index record; nothing to act on")
        return None
    conn, live = mailbox()
    if conn is None:
        return None
    if record.get("uidvalidity") != live:
        log(f"{key}: recorded under UIDVALIDITY {record.get('uidvalidity')}, "
            f"mailbox is now {live}; skipping until the poller re-indexes it")
        return None
    uid = record.get("uid")
    if not isinstance(uid, int):
        log(f"{key}: no usable uid")
        return None
    return uid


def mark_read(key):
    """+FLAGS (\\Seen). The index record is not touched here.

    One writer per field: the poller owns index/, and it reconciles flags on
    every pass, so this record is correct within five minutes. The console does
    not wait for that -- it dims the row on click and moves on -- which is why
    writing the record from here would buy nothing and cost the invariant.
    """
    uid = routable(key)
    if uid is None:
        return
    conn, _ = mailbox()
    typ, data = conn.uid("STORE", str(uid), "+FLAGS", "(\\Seen)")
    if typ != "OK":
        log(f"{key}: STORE \\Seen failed: {data}")
    else:
        log(f"{key}: marked read")


def mark_unread(key):
    """-FLAGS (\\Seen). mark_read's mirror, and the same one-writer rule: the
    index record is the poller's, and the console has already drawn the dot."""
    uid = routable(key)
    if uid is None:
        return
    conn, _ = mailbox()
    typ, data = conn.uid("STORE", str(uid), "-FLAGS", "(\\Seen)")
    if typ != "OK":
        log(f"{key}: STORE -\\Seen failed: {data}")
    else:
        log(f"{key}: marked unread")


def folder_arg(name):
    """The folder as an IMAP quoted string.

    archive_folder() and sent_folder() already refused quotes, backslashes and
    newlines, so wrapping the name in quotes here is quoting rather than hope.
    imaplib does not quote arguments itself, and an unquoted name with a space
    in it ("Sent Items") arrives at the server as two arguments.
    """
    return f'"{name}"'


def with_create(conn, folder, op):
    """op(), and on anything but OK, one CREATE and one more op().

    A folder that does not exist yet is the ordinary first-run case and not
    worth a human's attention; a CREATE that comes back NO because the folder
    already exists is what this deliberately ignores, because the retry is the
    thing that answers the question either way.
    """
    typ, data = op()
    if typ == "OK":
        return typ, data
    try:
        conn.create(folder_arg(folder))
    except Exception:  # noqa: BLE001
        pass
    return op()


def imap_move(conn, uid, folder):
    """True only when the message is confirmed out of INBOX and in `folder`.

    UID MOVE (RFC 6851) first: one atomic verb, and the server that has it
    cannot leave the message in two places or in none. The fallback is the older
    three-step form -- COPY, then \\Deleted, then UID EXPUNGE of exactly this
    uid -- and the order is the safety property: \\Deleted is set only after the
    COPY has come back OK, so there is no step in here that can lose a message.

    There is no plain-EXPUNGE branch, deliberately. Plain EXPUNGE removes every
    message in INBOX currently flagged \\Deleted, which is a different and much
    larger action than the one that was asked for.
    """
    try:
        typ, data = with_create(conn, folder,
                                lambda: conn.uid("MOVE", str(uid), folder_arg(folder)))
    except imaplib.IMAP4.error as exc:
        typ, data = "NO", repr(exc)
    if typ == "OK":
        return True

    log(f"uid {uid}: UID MOVE to {folder} unavailable ({data}); trying COPY")
    try:
        typ, data = with_create(conn, folder,
                                lambda: conn.uid("COPY", str(uid), folder_arg(folder)))
    except imaplib.IMAP4.error as exc:
        typ, data = "NO", repr(exc)
    if typ != "OK":
        log(f"uid {uid}: COPY to {folder} failed: {data}")
        return False

    typ, data = conn.uid("STORE", str(uid), "+FLAGS", "(\\Deleted)")
    if typ != "OK":
        log(f"uid {uid}: copied to {folder} but STORE \\Deleted failed: {data}")
        return False
    try:
        typ, data = conn.uid("EXPUNGE", str(uid))
    except imaplib.IMAP4.error as exc:
        typ, data = "NO", repr(exc)
    if typ != "OK":
        log(f"uid {uid}: UID EXPUNGE failed ({data}); the copy is in {folder} "
            f"and the original stays flagged in INBOX")
        return False
    return True


def archive(key):
    """A real move out of INBOX into the archive folder. Never an expunge alone.

    On Gmail this verb was +FLAGS (\\Deleted) plus an expunge, because Gmail
    reads deleting a message from INBOX as removing the Inbox label and leaves
    the message in All Mail. On a standards-compliant server that same pair is
    permanent deletion, so the verb is now what it always meant: a move.

    Nothing writes the index record here. The poller's reconcile notices the
    message is gone from INBOX on its next pass and flips in_inbox false, which
    is the same one-writer rule mark_read follows.
    """
    uid = routable(key)
    if uid is None:
        return
    conn, _ = mailbox()
    try:
        folder = maillib.archive_folder()
    except MailError as exc:
        log(f"{key}: {exc}")
        return
    if imap_move(conn, uid, folder):
        log(f"{key}: archived to {folder}")
    else:
        log(f"{key}: could not archive; the message is still in INBOX")


# -- the audit trail ----------------------------------------------------------

def audit(line):
    """One line, appended, never pruned, never rewritten.

    This is the permanent record of every outward action the system has ever
    taken. The poller's retention rules explicitly exclude this file and the
    outbox, because an audit trail with a retention policy is a retention policy.
    """
    try:
        with open(maillib.AUDIT_PATH, "a") as fh:
            fh.write(line + "\n")
    except OSError as exc:
        log(f"cannot append to the audit log: {exc}")


def one_line(value, limit):
    """A field that is about to go into a header or an audit line.

    Newlines out, runs of whitespace collapsed, length capped. In an audit line
    this keeps one record on one line; in a header it is the entire defense
    against header injection, since a subject carrying a newline plus `Bcc:` is
    a subject that adds a recipient.
    """
    return " ".join(str(value or "").split())[:limit]


# -- sending ------------------------------------------------------------------

def build(record, index, sender):
    """The message itself. text/plain, threaded, addressed to one person.

    `sender` is the From: header, which is not necessarily the login: a mailbox
    may send as `Charon <agent@example.com>` while authenticating as something
    else entirely. In-Reply-To and References are what make a client show the
    reply inside the original conversation rather than as a new thread.
    References is the original's own chain plus the message being answered,
    oldest first, which is what every threading client expects to walk.
    """
    msg = EmailMessage()
    msg["From"] = sender
    msg["To"] = record["to"]
    msg["Subject"] = record["subject"]
    msg["Date"] = formatdate(localtime=True)

    parent = one_line(index.get("message_id"), 300)
    if parent:
        msg["In-Reply-To"] = f"<{parent}>"
        chain = [ref for ref in (index.get("references") or [])
                 if isinstance(ref, str) and ref.startswith("<")]
        chain.append(f"<{parent}>")
        msg["References"] = " ".join(chain[-12:])

    # A Message-ID of our own, minted from the sending domain. Under Gmail there
    # was a reason not to: Gmail stamped one on submission, and an id invented
    # here would have carried the Pi's hostname. The sending domain is ours now,
    # and the id is worth knowing twice over -- the outbox record keeps it as
    # the receipt for what went out, and the copy filed to the Sent folder has
    # to be the same message the recipient got, down to its id.
    domain = parseaddr(sender)[1].rpartition("@")[2] or None
    msg["Message-ID"] = make_msgid(domain=domain)
    msg.set_content(record["body"])
    return msg


def transmit(msg, login, password):
    """SMTP, once. Returns None on success or a reason.

    Everything that can be checked has been checked by the time this runs, so
    the only failures left are the network, the certificate, the credential, and
    the recipient being refused.

    The explicit context is the same point it is in maillib.imap_connect():
    smtplib builds an unverified one when it is not handed a context, so without
    this line the submission is encrypted and unauthenticated, and the password
    goes to whatever answered for the address.
    """
    host, port = maillib.smtp_endpoint()
    try:
        with smtplib.SMTP_SSL(host, port, timeout=maillib.NET_TIMEOUT_S,
                              context=ssl.create_default_context()) as smtp:
            smtp.login(login, password)
            refused = smtp.send_message(msg)
    except smtplib.SMTPAuthenticationError as exc:
        return f"the mail server refused the password for the mailbox login: {exc}"
    except smtplib.SMTPException as exc:
        return f"SMTP refused the message: {exc}"
    except ssl.SSLCertVerificationError as exc:
        # Ahead of OSError, which it is a subclass of.
        return (f"{host} presented a certificate that does not verify "
                f"(did the server's ACME renewal fail?): {exc}")
    except OSError as exc:
        return f"cannot reach {host}:{port}: {exc}"
    if refused:
        return f"recipient refused: {sorted(refused)}"
    return None


def finish(oid, record, status, detail):
    """Terminal state, one audit line, entry dropped. In that order.

    The audit line is written first because it is the only permanent copy: if
    the disk refuses the outbox record after a message has already gone out, the
    dashboard is wrong and the log is still right, and that is the correct way
    round.

    The entry is dropped on failure too. A queue entry left behind would re-fire
    this unit and re-attempt a send, and a duplicate email is worse than an
    error message: retrying is a human clicking SEND again, which writes a new
    record with a new id.
    """
    at = stamp()
    fields = (f"id={oid} key={record.get('key')} to={one_line(record.get('to'), 200)} "
              f"subject=\"{one_line(record.get('subject'), 200)}\"")
    if status == "sent":
        record["status"] = "sent"
        record["sent_at"] = at
        record["smtp_reply"] = detail
        record["error"] = None
        audit(f"{at} sent {fields} smtp=\"{one_line(detail, 200)}\"")
    else:
        record["status"] = "error"
        record["sent_at"] = None
        record["smtp_reply"] = None
        record["error"] = one_line(detail, 500)
        audit(f"{at} error {fields} error=\"{one_line(detail, 300)}\"")
    maillib.write_json(maillib.outbox_path(oid), record)
    maillib.spool_drop(maillib.ACTIONS_DIR, f"send-{oid}")


def append_sent(oid, record, msg):
    """A copy of what just left, filed to the Sent folder. Best effort.

    Runs strictly after finish(), and nothing in here may change the verdict on
    a send: the message is already gone, the status on disk is already `sent`
    and the spool entry is already dropped. This is bookkeeping, so its failures
    land on the record and are never raised. IMAP has no "record what I sent"
    verb; APPEND with \\Seen is how every mail client does this.
    """
    why = None
    folder = None
    conn, _ = mailbox()
    if conn is None:
        why = _mailbox["error"] or "no IMAP connection"
    else:
        try:
            folder = maillib.sent_folder()
            raw = msg.as_bytes(policy=policy.SMTP)
            typ, data = with_create(conn, folder, lambda: conn.append(
                folder_arg(folder), "(\\Seen)",
                imaplib.Time2Internaldate(time.time()), raw))
            if typ != "OK":
                why = f"APPEND said {typ}: {data}"
        except Exception as exc:  # noqa: BLE001
            why = f"APPEND failed: {exc!r}"
    if why is None:
        record["sent_copy"] = folder
        record["sent_copy_error"] = None
        log(f"{oid}: copy filed to {folder}")
    else:
        record["sent_copy"] = None
        record["sent_copy_error"] = one_line(why, 300)
        log(f"{oid}: sent, but the Sent copy was not filed: {why}")
    maillib.write_json(maillib.outbox_path(oid), record)


def send(oid):
    """One queued reply. Every exit from here is terminal for this id."""
    record = maillib.read_json(maillib.outbox_path(oid))
    if record is None:
        log(f"{oid}: no outbox record; dropping the entry")
        maillib.spool_drop(maillib.ACTIONS_DIR, f"send-{oid}")
        return
    if record.get("status") != "queued":
        # Already terminal. A path unit that re-fired, or a second entry for an
        # id that has been sent. Doing nothing here is the guard working.
        log(f"{oid}: status is {record.get('status')!r}, not queued; nothing to send")
        maillib.spool_drop(maillib.ACTIONS_DIR, f"send-{oid}")
        return

    key = record.get("key") or ""
    if not maillib.KEY_RE.fullmatch(key):
        finish(oid, record, "error", "the record names no message to reply to")
        return
    index = maillib.read_json(maillib.index_path(key))
    if index is None:
        finish(oid, record, "error", "the message being replied to is no longer indexed")
        return

    # Defense in depth. The collector computes `to` from the index and never
    # accepts one from the browser; this checks the same thing again against the
    # same source, so a record written by anything other than the collector
    # still cannot address a reply at somebody who was not the sender.
    wanted = parseaddr(record.get("to") or "")[1].strip().lower()
    allowed = {parseaddr(addr)[1].strip().lower()
               for addr in (index.get("reply_to"), index.get("from_addr"))
               if isinstance(addr, str) and addr.strip()}
    if not wanted or wanted not in allowed:
        finish(oid, record, "error",
               "the recipient is not the sender of the message being replied to")
        return

    body = record.get("body")
    if not isinstance(body, str) or not body.strip():
        finish(oid, record, "error", "the draft is empty")
        return
    record["body"] = body[:BODY_MAX_CHARS]
    record["to"] = wanted
    subject = one_line(record.get("subject"), SUBJECT_MAX_CHARS)
    if not subject:
        original = one_line(index.get("subject"), SUBJECT_MAX_CHARS - 4)
        subject = original if original.lower().startswith("re:") else f"Re: {original}"
    record["subject"] = subject or "Re:"

    try:
        login, password = maillib.mail_credentials()
        sender = maillib.mail_from()
    except MailError as exc:
        finish(oid, record, "error", str(exc))
        return

    try:
        msg = build(record, index, sender)
        # The id this box minted, kept before the message is handed over: it is
        # the only durable link between the outbox record, the audit line and
        # the copy in the Sent folder.
        record["message_id"] = str(msg["Message-ID"] or "").strip("<>")
        failed = transmit(msg, login, password)
    except Exception as exc:  # noqa: BLE001
        # Something neither the SMTP errors nor the header builder named. This
        # is the one outcome where whether the message went out is genuinely
        # unknown, so it is recorded as an error that says so: the alternative
        # is a record stuck on `queued` forever, which reads on the dashboard as
        # a send still in flight and is never going to become true.
        log(f"{oid}: send did not complete cleanly: {exc!r}")
        finish(oid, record, "error",
               f"the send did not complete cleanly and may or may not have gone out: {exc!r}")
        return
    if failed:
        log(f"{oid}: {failed}")
        finish(oid, record, "error", failed)
        return
    # What the server actually said in reply to DATA is not something smtplib
    # hands back: send_message discards it once it has confirmed a 250. Writing
    # a plausible "250 2.0.0 OK" into a permanent audit log would be inventing a
    # receipt, so the field records what is actually known.
    finish(oid, record, "sent", "accepted, no recipients refused")
    log(f"{oid}: sent to {record['to']}")
    # Strictly after finish(). The status flip and the dropped spool entry are
    # the double-send guard, and they have to be on disk before anything else is
    # attempted: a Sent copy that fails is a bookkeeping gap, while a crash
    # before finish() is a message that goes out twice.
    append_sent(oid, record, msg)


# -- the drain ----------------------------------------------------------------

def drain():
    """Everything waiting, oldest first, then done.

    Re-scanned each pass, and `attempted` keeps an entry that survived its turn
    from being picked twice in one drain. Sends are strictly one at a time and
    strictly in arrival order, which is the order the human clicked in.
    """
    attempted = set()
    while True:
        waiting = [name for name in maillib.spooled(maillib.ACTIONS_DIR)
                   if name not in attempted]
        if not waiting:
            return
        name = waiting[0]
        attempted.add(name)
        verb, subject = maillib.split_entry(name)

        try:
            if verb == "send" and subject:
                try:
                    send(subject)
                finally:
                    # Dropped whatever happened, including an exception raised
                    # after the message was already accepted. finish() drops it
                    # too and this is the same call twice, which is the point:
                    # there must be no path where a send entry survives its
                    # attempt, because surviving means being tried again.
                    maillib.spool_drop(maillib.ACTIONS_DIR, name)
            elif verb in ("read", "unread", "archive") \
                    and maillib.KEY_RE.fullmatch(subject or ""):
                {"read": mark_read, "unread": mark_unread,
                 "archive": archive}[verb](subject)
                maillib.spool_drop(maillib.ACTIONS_DIR, name)
            else:
                log(f"{name}: not an action this worker understands; dropping it")
                maillib.spool_drop(maillib.ACTIONS_DIR, name)
        except Exception as exc:  # noqa: BLE001
            # One action failing is not the drain failing. A read or an archive
            # keeps its entry and is retried on the next fire; a send never is.
            log(f"{name}: unhandled error: {exc!r}")


def main():
    # secrets/mail-env only: the mail server, the mailbox address and its
    # password. This worker never loads the subscription token, and the worker
    # that runs a model never loads this file. That split is the whole reason
    # there are two.
    maillib.load_env(maillib.MAIL_ENV_PATH)
    if not maillib.take_lock(LOCK_PATH):
        # Another drain holds the mailbox. Not an error: it re-scans after every
        # action, so nothing queued goes unserved.
        return 0
    maillib.ensure_dirs()
    began = time.monotonic()
    try:
        drain()
    finally:
        # LOGOUT and nothing else. IMAP's CLOSE expunges every message in the
        # mailbox currently flagged \\Deleted, and on a standards server an
        # expunge is a permanent deletion rather than the label removal it was
        # on Gmail. A stray flag left anywhere in INBOX by an interrupted move
        # would be destroyed by what looks like a tidy shutdown.
        maillib.imap_close(_mailbox["conn"])
    log(f"drain finished in {round(time.monotonic() - began, 1)}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
