#!/usr/bin/env python3
"""Offline tests for the actions worker's mailbox writes. No network, no cost.

The one thing in this system that cannot be undone is a message leaving, and
the second thing is a message being deleted from a server that means it. Both
of those live in mail-actions.py, so this is the file that gets a fake IMAP
server nailed under it and every verb it issues recorded.

What these prove, in order of how much they would cost to learn the other way:

    plain EXPUNGE is never issued -- the fake raises if it is called at all
    \\Deleted is never set before a COPY has come back OK
    a UID MOVE is one verb, and a missing folder is created exactly once
    a stale UIDVALIDITY issues no verb at all, rather than moving a stranger's
      message out of the inbox
    the Sent copy is bookkeeping: it cannot fail a send that already happened
    the mailbox config is read at call time, and a missing key names itself

No socket is opened anywhere in here: the fake is injected into the worker's
own connection state, and every credential is a made-up one written over the
ambient environment first.

    python3 test-mail-actions.py
"""

import importlib.util
import os
import shutil
import sys
import tempfile

REPO = os.path.dirname(os.path.abspath(__file__))
BASE = tempfile.mkdtemp(prefix="charon-actions-")

# Before maillib is imported, not after: BASE binds at import time and every
# path in the module is derived from it. Importing first would point this test
# at the Pi's real mail directory.
os.environ["CHARON_MAIL_BASE"] = BASE
sys.path.insert(0, REPO)

import maillib  # noqa: E402

ok = fail = 0

KEY = "00a1b2c3d4e5f601"
UIDVALIDITY = 7
UID = 5

# A whole mailbox that does not exist, written over whatever the box actually
# has. Same reason test-llm.py replaces the CHARON_* block: a real
# secrets/mail-env in the ambient environment could otherwise make a test pass
# that would fail on a clean box, or aim one of these verbs at a live server.
MAILBOX = {
    "CHARON_IMAP_HOST": "mail.example.com",
    "CHARON_SMTP_HOST": "mail.example.com",
    "CHARON_MAIL_ADDRESS": "agent@example.com",
    "CHARON_MAIL_PASSWORD": "not-a-real-password",
}


def check(passed, label, detail=""):
    global ok, fail
    if passed:
        ok += 1
        print(f"  ok    {label}")
    else:
        fail += 1
        print(f"  FAIL  {label}" + (f": {detail}" if detail else ""))


def env(**kw):
    """Replace exactly the CHARON_* and GMAIL_* vars. CHARON_MAIL_BASE survives,
    because the tempdir is this test's whole world."""
    for key in [k for k in os.environ if k.startswith(("CHARON_", "GMAIL_"))]:
        del os.environ[key]
    os.environ.update({k: v for k, v in kw.items() if v is not None})


env(**MAILBOX)

# mail-actions.py is not an importable name (the hyphen) and it reads
# maillib.MAIL_DIR at import time, so it is loaded by path, here, after the
# environment above is in place.
_spec = importlib.util.spec_from_file_location(
    "mail_actions", os.path.join(REPO, "mail-actions.py"))
ma = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ma)


class FakeIMAP:
    """Every verb the actions worker can reach, recorded instead of sent.

    Responses are scripted per verb as a list of (typ, data) consumed in order
    with the last entry repeating, so `MOVE=[("NO", ...)]` refuses every time
    and `MOVE=[("NO", ...), ("OK", ...)]` refuses once. An entry that is an
    exception is raised instead of returned. Anything unscripted answers OK.
    """

    def __init__(self, **script):
        self.calls = []
        self.script = {verb: list(replies) for verb, replies in script.items()}

    def _reply(self, verb):
        queue = self.script.get(verb)
        if not queue:
            return "OK", [b"ok"]
        reply = queue.pop(0) if len(queue) > 1 else queue[0]
        if isinstance(reply, Exception):
            raise reply
        return reply

    def verbs(self):
        return [verb for verb, _ in self.calls]

    def args(self, verb):
        return [args for name, args in self.calls if name == verb]

    def uid(self, command, *args):
        self.calls.append((command.upper(), args))
        return self._reply(command.upper())

    def create(self, folder):
        self.calls.append(("CREATE", (folder,)))
        return self._reply("CREATE")

    def append(self, folder, flags, date_time, message):
        self.calls.append(("APPEND", (folder, flags, date_time, message)))
        return self._reply("APPEND")

    def expunge(self):
        raise AssertionError(
            "plain EXPUNGE must never run in the actions worker: it removes "
            "every message in INBOX currently flagged \\Deleted")

    def close(self):
        raise AssertionError(
            "CLOSE must never run: it expunges on the way out, which is the "
            "same accident wearing a tidier name")


def use_fake(fake, uidvalidity=UIDVALIDITY):
    """Nail the fake into the worker's connection state. mailbox() only builds
    a connection when there is neither one nor an error, so this is also what
    guarantees nothing in here can reach a socket."""
    ma._mailbox["conn"] = fake
    ma._mailbox["uidvalidity"] = uidvalidity
    ma._mailbox["error"] = None
    return fake


def index_record(uidvalidity=UIDVALIDITY, uid=UID):
    """The poller's record for the one message these tests act on."""
    maillib.write_json(maillib.index_path(KEY), {
        "key": KEY,
        "message_id": "parent@example.net",
        "uid": uid,
        "uidvalidity": uidvalidity,
        "from_addr": "someone@example.net",
        "reply_to": "",
        "subject": "hello",
        "references": ["<older@example.net>"],
        "in_inbox": True,
    })
    return maillib.read_json(maillib.index_path(KEY))


def outbox_record():
    """What finish() has already written by the time append_sent runs."""
    return {"key": KEY, "to": "someone@example.net", "subject": "Re: hello",
            "body": "hi there", "status": "sent", "sent_at": maillib.stamp(),
            "smtp_reply": "accepted, no recipients refused", "error": None}


def main():
    maillib.ensure_dirs()
    index = index_record()

    print("1. archive is a UID MOVE")
    env(**MAILBOX)
    fake = use_fake(FakeIMAP())
    ma.archive(KEY)
    moves = fake.args("MOVE")
    check(len(moves) == 1, "exactly one UID MOVE", str(fake.verbs()))
    check(moves and moves[0] == (str(UID), '"Archive"'),
          "carrying the uid and the quoted folder", str(moves))
    check("STORE" not in fake.verbs(), "nothing was flagged", str(fake.verbs()))
    check("EXPUNGE" not in fake.verbs(), "nothing was expunged", str(fake.verbs()))

    print("\n2. a folder that does not exist yet is created once")
    fake = use_fake(FakeIMAP(MOVE=[("NO", [b"[TRYCREATE] no such mailbox"]),
                                   ("OK", [b"moved"])]))
    ma.archive(KEY)
    check(fake.verbs() == ["MOVE", "CREATE", "MOVE"],
          "MOVE, CREATE, MOVE and no more", str(fake.verbs()))
    check(fake.args("CREATE") == [('"Archive"',)],
          "one CREATE, quoted the same way", str(fake.args("CREATE")))

    print("\n3. a server without MOVE falls back in a safe order")
    fake = use_fake(FakeIMAP(MOVE=[("NO", [b"unknown command"])]))
    ma.archive(KEY)
    order = fake.verbs()
    check(order == ["MOVE", "CREATE", "MOVE", "COPY", "STORE", "EXPUNGE"],
          "COPY, then the flag, then a UID EXPUNGE", str(order))
    check("STORE" in order and "COPY" in order
          and order.index("STORE") > order.index("COPY"),
          "\\Deleted is set only after the COPY came back OK", str(order))
    check(fake.args("COPY") == [(str(UID), '"Archive"')],
          "the COPY names the uid and the quoted folder", str(fake.args("COPY")))
    check(fake.args("STORE") == [(str(UID), "+FLAGS", "(\\Deleted)")],
          "the flag goes on exactly that uid", str(fake.args("STORE")))
    check(fake.args("EXPUNGE") == [(str(UID),)],
          "and the expunge is a UID EXPUNGE of exactly that uid",
          str(fake.args("EXPUNGE")))

    print("\n4. a COPY that fails leaves the message alone")
    fake = use_fake(FakeIMAP(MOVE=[("NO", [b"unknown command"])],
                             COPY=[("NO", [b"over quota"])]))
    ma.archive(KEY)
    check("STORE" not in fake.verbs(),
          "nothing is ever flagged \\Deleted without a copy", str(fake.verbs()))
    check("EXPUNGE" not in fake.verbs(), "and nothing is expunged", str(fake.verbs()))

    print("\n5. a uid from a numbering the server threw away is not used")
    index_record(uidvalidity=999)
    fake = use_fake(FakeIMAP())
    ma.archive(KEY)
    check(fake.calls == [], "a stale UIDVALIDITY issues no verb at all",
          str(fake.verbs()))
    index = index_record()

    print("\n6. the message that gets built")
    env(**dict(MAILBOX, CHARON_MAIL_FROM="Charon <agent@example.com>"))
    draft = {"key": KEY, "to": "someone@example.net", "subject": "Re: hello",
             "body": "hi there"}
    msg = ma.build(draft, index, maillib.mail_from())
    mid = str(msg["Message-ID"] or "")
    check(mid.startswith("<") and mid.endswith("@example.com>"),
          "a Message-ID minted from the sending domain", mid)
    check(str(msg["From"]) == "Charon <agent@example.com>",
          "From keeps the display name it was given", str(msg["From"]))
    check(str(msg["To"]) == "someone@example.net", "To is the one recipient")
    check(str(msg["In-Reply-To"]) == "<parent@example.net>",
          "threaded to the message being answered", str(msg["In-Reply-To"]))
    check(str(msg["References"]).split()
          == ["<older@example.net>", "<parent@example.net>"],
          "References is the chain, oldest first", str(msg["References"]))
    check(msg.get_content().strip() == "hi there", "the body is the draft")

    env(**MAILBOX)
    plain = ma.build(draft, index, maillib.mail_from())
    check(str(plain["From"]) == "agent@example.com",
          "From falls back to the address", str(plain["From"]))
    check(str(plain["Message-ID"]).endswith("@example.com>"),
          "and the id still comes from its domain", str(plain["Message-ID"]))

    print("\n7. the Sent copy is bookkeeping, never a verdict")
    oid = "reply-0001"
    fake = use_fake(FakeIMAP())
    ma.append_sent(oid, outbox_record(), msg)
    appended = fake.args("APPEND")
    check(len(appended) == 1, "one APPEND", str(fake.verbs()))
    check(appended and appended[0][0] == '"Sent"',
          "to the quoted Sent folder", str(appended and appended[0][0]))
    check(appended and appended[0][1] == "(\\Seen)",
          "filed as already read", str(appended and appended[0][1]))
    check(appended and isinstance(appended[0][3], bytes)
          and mid.encode() in appended[0][3],
          "carrying the same Message-ID that went out")
    filed = maillib.read_json(maillib.outbox_path(oid)) or {}
    check(filed.get("sent_copy") == "Sent", "the record names the folder",
          str(filed.get("sent_copy")))
    check(filed.get("status") == "sent", "and the status is untouched",
          str(filed.get("status")))

    fake = use_fake(FakeIMAP(APPEND=[("NO", [b"mailbox is over quota"])]))
    ma.append_sent(oid, outbox_record(), msg)
    filed = maillib.read_json(maillib.outbox_path(oid)) or {}
    check(filed.get("status") == "sent",
          "a refused APPEND does not unsend anything", str(filed.get("status")))
    check(filed.get("sent_copy") is None, "sent_copy says there is no copy",
          str(filed.get("sent_copy")))
    check("over quota" in (filed.get("sent_copy_error") or ""),
          "and the reason is on the record", str(filed.get("sent_copy_error")))

    fake = use_fake(FakeIMAP(APPEND=[RuntimeError("socket closed")]))
    ma.append_sent(oid, outbox_record(), msg)
    filed = maillib.read_json(maillib.outbox_path(oid)) or {}
    check(filed.get("status") == "sent",
          "an APPEND that raises does not either", str(filed.get("status")))
    check("socket closed" in (filed.get("sent_copy_error") or ""),
          "and it lands as a reason, not a traceback",
          str(filed.get("sent_copy_error")))

    ma._mailbox.update({"conn": None, "uidvalidity": None,
                        "error": "cannot reach mail.example.com:993"})
    ma.append_sent(oid, outbox_record(), msg)
    filed = maillib.read_json(maillib.outbox_path(oid)) or {}
    check(filed.get("status") == "sent",
          "and neither does having no connection at all", str(filed.get("status")))
    check("cannot reach" in (filed.get("sent_copy_error") or ""),
          "which is recorded as the connection error it was",
          str(filed.get("sent_copy_error")))

    print("\n8. credentials, verbatim, or an error that names its file")
    env(**dict(MAILBOX, CHARON_MAIL_PASSWORD="two words  spaced"))
    login, password = maillib.mail_credentials()
    check(login == "agent@example.com", "the address is the login by default", login)
    check(password == "two words  spaced",
          "the password is passed through untouched", repr(password))
    env(**dict(MAILBOX, CHARON_MAIL_USER="agent"))
    check(maillib.mail_credentials()[0] == "agent",
          "CHARON_MAIL_USER wins when the server wants a bare name")
    env()
    try:
        maillib.mail_credentials()
        check(False, "an unset mailbox is an error")
    except maillib.MailError as exc:
        check("CHARON_MAIL_PASSWORD" in str(exc) and "mail-env.example" in str(exc),
              "an unset mailbox names the keys and the example file", str(exc))
    env(GMAIL_ADDRESS="old@gmail.com", GMAIL_APP_PASSWORD="abcd efgh ijkl mnop")
    try:
        maillib.mail_credentials()
        check(False, "config left on the GMAIL_* names is an error")
    except maillib.MailError as exc:
        check("GMAIL_*" in str(exc) and "CHARON_MAIL_ADDRESS" in str(exc),
              "config left on the GMAIL_* names says exactly that", str(exc))

    print("\n9. endpoints default to the implicit-TLS ports")
    env(**MAILBOX)
    check(maillib.imap_endpoint() == ("mail.example.com", 993),
          "IMAP is 993", str(maillib.imap_endpoint()))
    check(maillib.smtp_endpoint() == ("mail.example.com", 465),
          "SMTP is 465", str(maillib.smtp_endpoint()))
    env(**dict(MAILBOX, CHARON_IMAP_PORT="1993", CHARON_SMTP_PORT="1465"))
    check(maillib.imap_endpoint()[1] == 1993 and maillib.smtp_endpoint()[1] == 1465,
          "an override wins",
          str((maillib.imap_endpoint(), maillib.smtp_endpoint())))
    env(**dict(MAILBOX, CHARON_IMAP_PORT="993x"))
    try:
        maillib.imap_endpoint()
        check(False, "a port that is not a number is an error, not a default")
    except maillib.MailError as exc:
        check("CHARON_IMAP_PORT" in str(exc),
              "a port that is not a number is an error, not a default", str(exc))
    env(CHARON_MAIL_ADDRESS="agent@example.com", CHARON_MAIL_PASSWORD="x")
    try:
        maillib.imap_endpoint()
        check(False, "a missing host is an error")
    except maillib.MailError as exc:
        check("CHARON_IMAP_HOST" in str(exc) and "mail-env.example" in str(exc),
              "a missing host names itself and the example file", str(exc))

    print("\n10. folder names are checked where they are read")
    env(**MAILBOX)
    check(maillib.archive_folder() == "Archive" and maillib.sent_folder() == "Sent",
          "the defaults are Archive and Sent")
    env(**dict(MAILBOX, CHARON_ARCHIVE_FOLDER="Archive/2026"))
    check(maillib.archive_folder() == "Archive/2026",
          "a hierarchy separator is an ordinary character")
    check(ma.folder_arg("Sent Items") == '"Sent Items"',
          "a name with a space becomes one quoted argument")
    for bad in ('Ar"chive', "Arch\\ive", "Arch\nive", "Arch\rive", "Archivé"):
        env(**dict(MAILBOX, CHARON_ARCHIVE_FOLDER=bad))
        try:
            maillib.archive_folder()
            check(False, f"{bad!r} is refused")
        except maillib.MailError:
            check(True, f"{bad!r} is refused")

    print("\n11. a whole send, with the socket taken out of it")
    env(**MAILBOX)
    oid = "reply-0002"

    class Watching(FakeIMAP):
        """Reads the outbox record at APPEND time, which is how the ordering
        rule gets asserted rather than asserted about."""
        seen = None

        def append(self, *args):
            self.seen = ((maillib.read_json(maillib.outbox_path(oid)) or {}),
                         maillib.spooled(maillib.ACTIONS_DIR))
            return super().append(*args)

    sent = []
    real_transmit = ma.transmit
    try:
        ma.transmit = lambda msg, login, password: sent.append(
            (msg, login, password)) or None
        fake = use_fake(Watching())
        maillib.write_json(maillib.outbox_path(oid), {
            "id": oid, "key": KEY, "to": "someone@example.net",
            "subject": "Re: hello", "body": "hi there", "status": "queued"})
        maillib.spool_add(maillib.ACTIONS_DIR, f"send-{oid}")
        ma.send(oid)

        check(len(sent) == 1, "the message was handed to transmit once", str(len(sent)))
        check(sent and sent[0][1] == "agent@example.com",
              "with the login, which is not necessarily the From",
              str(sent and sent[0][1]))
        filed = maillib.read_json(maillib.outbox_path(oid)) or {}
        check(filed.get("status") == "sent", "the record is terminal",
              str(filed.get("status")))
        check(sent and filed.get("message_id")
              == str(sent[0][0]["Message-ID"]).strip("<>"),
              "and keeps the id of the message that actually went out",
              str(filed.get("message_id")))
        check(filed.get("sent_copy") == "Sent", "the copy was filed",
              str(filed.get("sent_copy")))
        check(maillib.spooled(maillib.ACTIONS_DIR) == [],
              "the spool entry is gone", str(maillib.spooled(maillib.ACTIONS_DIR)))
        at_append = fake.seen or ({}, ["never appended"])
        check(at_append[0].get("status") == "sent",
              "the status was already flipped before the copy was attempted",
              str(at_append[0].get("status")))
        check(at_append[1] == [],
              "and the entry was already dropped: the double-send guard lands "
              "first, always", str(at_append[1]))

        print("\n12. the recipient guard still refuses a third party")
        sent.clear()
        maillib.write_json(maillib.outbox_path(oid), {
            "id": oid, "key": KEY, "to": "somebody-else@example.org",
            "subject": "Re: hello", "body": "hi there", "status": "queued"})
        maillib.spool_add(maillib.ACTIONS_DIR, f"send-{oid}")
        ma.send(oid)
        check(sent == [], "nothing was transmitted", str(sent))
        filed = maillib.read_json(maillib.outbox_path(oid)) or {}
        check(filed.get("status") == "error", "the record says error",
              str(filed.get("status")))
        check("recipient" in (filed.get("error") or ""), "and says why",
              str(filed.get("error")))
    finally:
        ma.transmit = real_transmit

    print(f"\n{ok} passed, {fail} failed")
    return 1 if fail else 0


if __name__ == "__main__":
    try:
        code = main()
    finally:
        shutil.rmtree(BASE, ignore_errors=True)
    sys.exit(code)
