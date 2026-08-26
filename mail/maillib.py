#!/usr/bin/env python3
"""Shared floor under the three mail workers: paths, locks, atomic writes, IMAP.

Deploys to /home/pi/charon-mail/bin/maillib.py, next to the three scripts that
import it. Nothing in here talks to a model and nothing in here sends mail. This
is the part all three workers need and none of them should carry a private copy
of, because three slightly different ideas of what a message key is would be
three different mailboxes.

The rule that shapes the whole module: **a message's identity is the hash of its
Message-ID, never its UID.** An IMAP server hands out UIDs per folder and is
entitled to renumber the whole mailbox by bumping UIDVALIDITY, at which point
every stored UID is a confident lie. A Message-ID survives that, survives a
folder move, and once hashed is sixteen hex characters wide, which is a filename
and a URL path segment without any further thought. UIDs are kept as routing
hints for the one job that needs them (telling the server which message to flag
or move) and are re-checked against UIDVALIDITY before they are used for
anything at all.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import fcntl
import hashlib
import imaplib
import json
import os
import re
import ssl
import sys
from datetime import datetime
from email import policy
from email.parser import BytesParser
from email.utils import getaddresses, parseaddr, parsedate_to_datetime
from html.parser import HTMLParser

# The Pi's layout. CHARON_MAIL_BASE exists so the poller can be aimed at a
# scratch directory on the Mac during bring-up, against the same live mailbox,
# without the workers each growing a --base flag. Nothing on the Pi sets it.
BASE = os.environ.get("CHARON_MAIL_BASE") or "/home/pi/charon-mail"

MAIL_DIR = os.path.join(BASE, "mail")
INDEX_DIR = os.path.join(MAIL_DIR, "index")
BODIES_DIR = os.path.join(MAIL_DIR, "bodies")
AI_DIR = os.path.join(MAIL_DIR, "ai")
DRAFTS_DIR = os.path.join(MAIL_DIR, "drafts")
OUTBOX_DIR = os.path.join(MAIL_DIR, "outbox")
QUEUE_DIR = os.path.join(MAIL_DIR, ".queue")
ACTIONS_DIR = os.path.join(MAIL_DIR, ".actions")
STATE_PATH = os.path.join(MAIL_DIR, "state.json")
AUDIT_PATH = os.path.join(MAIL_DIR, "audit.log")

# Two env files, and which worker loads which is a security boundary rather than
# a preference: secrets/env holds the subscription token, secrets/mail-env holds
# the mailbox password. The worker that runs a model loads the first and never
# the second, so the model's process cannot inherit the password even in
# principle. See the systemd units, where the same split is spelled out again.
ENV_PATH = os.path.join(BASE, "secrets", "env")
MAIL_ENV_PATH = os.path.join(BASE, "secrets", "mail-env")

MAIL_ENV_DIR = os.path.join(BASE, "mail-env")
# No model anything lives in this module, deliberately. mail-actions.py imports
# maillib, and the "no model in the send path" rule is structural rather than
# promised: a model caller reachable from the sender's import graph would make
# it a promise again. It all lives in llm.py, which only mail-triage.py imports.

# Where the mailbox lives is configuration, not a constant: see imap_endpoint()
# and smtp_endpoint() below. It has to be read at call time rather than at
# import time, because load_env() runs inside each worker's main() and a module
# constant would have been bound before the env file was ever opened.
IMAP_PORT_DEFAULT = 993
SMTP_PORT_DEFAULT = 465

# Pi Wi-Fi drops. Every socket in this system gets a wall clock, because a hung
# read inside a oneshot unit is a unit that sits in "activating" until systemd's
# TimeoutStartSec fires, and that is minutes of looking healthy while stuck.
NET_TIMEOUT_S = 30

# imaplib refuses any server line longer than 1 MB by default and raises
# "got more than 1000000 bytes" mid-FETCH. A single HTML newsletter clears that
# on its own, so the ceiling goes up before the first connect. It bounds nothing
# useful here: the real bound on what we pull down is BODY_MAX_BYTES.
MAXLINE = 10_000_000

# A body bigger than this is left on the server. The .eml is the archive the
# attachment route parses on demand, so it is worth keeping, but not at the cost
# of a poll that spends four minutes pulling one message down a home uplink.
BODY_MAX_BYTES = 5 * 1024 * 1024

# What the extracted text is allowed to be. The console renders it preformatted
# and the collector serves it whole, so it is bounded on the way in.
TEXT_MAX_CHARS = 64 * 1024

# The only tags that may reach disk. The triage prompt lists these, and the
# triage worker checks them again on the way out: a prompt is a request, and a
# request is not a constraint.
TAGS = (
    "lead",
    "investor",
    "campus",
    "billing",
    "service",
    "personal",
    "newsletter",
    "notification",
    "action-needed",
    "spam",
)

# A message key as it appears in a filename or a spool entry. Sixteen lowercase
# hex characters, asserted every time one arrives from disk rather than trusted
# because this process wrote it: a name from a directory becoming a path is the
# shape of bug worth refusing structurally instead of reasoning about.
KEY_RE = re.compile(r"[0-9a-f]{16}")

# A spool entry name, same shape as the ask queue's ids.
SLUG_RE = re.compile(r"[a-z0-9-]{1,64}")

_locks = []


class MailError(Exception):
    """Something the worker should report and stop doing, not crash on.

    Carries a message written for the journal and for state.json's last_error,
    which means it never carries a credential.
    """


# -- the small shared verbs ---------------------------------------------------

def log(msg):
    """One line to stderr, which is journald under the unit."""
    sys.stderr.write(f"{datetime.now().isoformat(timespec='seconds')}  {msg}\n")
    sys.stderr.flush()


def stamp():
    """Local ISO seconds, the format every other file in this system uses."""
    return datetime.now().isoformat(timespec="seconds")


def parse_time(value):
    """An ISO timestamp from any of these files, or None.

    A naive value is given the local zone rather than being read as UTC, so it
    can be subtracted from an aware one without raising. Same helper, same
    reason, as the ask runner's.
    """
    if not isinstance(value, str) or not value:
        return None
    try:
        at = datetime.fromisoformat(value)
    except ValueError:
        return None
    return at if at.tzinfo else at.astimezone()


def load_env(path):
    """An env file into the environment, without overriding what is set.

    Same contract as the collector's load_env and the ask runner's: systemd's
    EnvironmentFile wins, and this is what makes a worker runnable by hand for a
    test. Takes the path explicitly because which file a worker may read is the
    whole credential split, and a default here would let a worker load the wrong
    one by forgetting an argument.
    """
    try:
        with open(path) as fh:
            lines = fh.readlines()
    except OSError:
        return
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, val = line.partition("=")
        key = key.strip()
        if key and key not in os.environ:
            os.environ[key] = val.strip()


def take_lock(path):
    """Exclusive, non-blocking, held for the life of the process.

    A path unit re-fires while its directory is non-empty and the poll timer
    does not care whether the last poll finished, so a second start landing on
    top of a running drain is ordinary rather than exceptional. Two workers
    sharing one mailbox would double-triage and, in the actions worker, double-
    send. Callers treat False as "already busy" and exit 0: being busy is a
    correct outcome, and a failed unit here would need a human to clear it for
    no reason at all.
    """
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(fd)
        return False
    # Kept in a module list so nothing closes it by garbage collection; the
    # kernel drops it when the process exits, which is exactly the lifetime.
    _locks.append(fd)
    return True


def ensure_dirs():
    """Every directory the mail feature writes into. Cheap, idempotent, and run
    by each worker rather than assumed: a missing .queue turns a first-run
    poller into a silent no-op with a full index."""
    for path in (MAIL_DIR, INDEX_DIR, BODIES_DIR, AI_DIR, DRAFTS_DIR,
                 OUTBOX_DIR, QUEUE_DIR, ACTIONS_DIR):
        os.makedirs(path, exist_ok=True)


def write_atomic(path, data):
    """tmp + os.replace, so the collector and the console never read a half
    written record. Returns True on success.

    This is `write_thread()` from the ask runner, generalized: every file in
    this system has exactly one writer and any number of concurrent readers, and
    os.replace is what makes "one writer" mean "one version".
    """
    tmp = f"{path}.tmp"
    mode = "wb" if isinstance(data, (bytes, bytearray)) else "w"
    try:
        with open(tmp, mode) as fh:
            fh.write(data)
        os.replace(tmp, path)
        return True
    except OSError as exc:
        log(f"cannot write {path}: {exc}")
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def write_json(path, doc):
    """A record, atomically. indent=2 because a human reads these on the Pi."""
    try:
        text = json.dumps(doc, indent=2)
    except (TypeError, ValueError) as exc:
        log(f"cannot serialize {path}: {exc}")
        return False
    return write_atomic(path, text)


def read_json(path):
    """The record, or None if it is not one. Never raises."""
    try:
        with open(path) as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    return doc if isinstance(doc, dict) else None


# -- paths --------------------------------------------------------------------

def index_path(key):
    return os.path.join(INDEX_DIR, f"{key}.json")


def eml_path(key):
    return os.path.join(BODIES_DIR, f"{key}.eml")


def text_path(key):
    return os.path.join(BODIES_DIR, f"{key}.txt")


def ai_path(key):
    return os.path.join(AI_DIR, f"{key}.json")


def draft_path(key):
    return os.path.join(DRAFTS_DIR, f"{key}.json")


def user_draft_path(key):
    return os.path.join(DRAFTS_DIR, f"{key}.user.json")


def outbox_path(oid):
    return os.path.join(OUTBOX_DIR, f"{oid}.json")


# -- the spool ----------------------------------------------------------------
#
# The contract with the collector, which is the thing to not break:
#
#     the writer writes the record and then the spool entry
#     the worker does the work and then deletes the spool entry
#
# The order is the contract. An entry means "not done yet", and only the process
# that did it may say otherwise, so a drain that dies halfway leaves a queue that
# is still exactly true and the next fire picks up where it stopped.

def spool_add(dirpath, name):
    """Create the entry that wakes a worker. Written last, always."""
    try:
        os.makedirs(dirpath, exist_ok=True)
        fd = os.open(os.path.join(dirpath, name), os.O_CREAT | os.O_WRONLY, 0o644)
        os.close(fd)
        return True
    except OSError as exc:
        log(f"cannot spool {name}: {exc}")
        return False


def spool_drop(dirpath, name):
    """Drop the entry. Always attempted: an entry left behind is work this
    process would do again on the next fire."""
    try:
        os.remove(os.path.join(dirpath, name))
    except FileNotFoundError:
        pass
    except OSError as exc:
        log(f"cannot clear the spool entry {name}: {exc}")


def spooled(dirpath):
    """Every entry waiting, oldest arrival first.

    By mtime rather than by name, for the same reason the ask queue is: served
    order should be arrival order, not alphabetical order that happens to be
    close. Names that are not entry-shaped are ignored rather than deleted;
    something else put them there and this is not the process to decide what
    they were.
    """
    out = []
    try:
        with os.scandir(dirpath) as entries:
            for entry in entries:
                if not SLUG_RE.fullmatch(entry.name):
                    continue
                try:
                    out.append((entry.stat().st_mtime, entry.name))
                except OSError:
                    continue
    except OSError:
        return []
    out.sort()
    return [name for _, name in out]


def split_entry(name):
    """`triage-<key>` into ("triage", "<key>"). Returns (None, None) if the
    entry is not one of ours or its subject is not a well formed key or id."""
    verb, _, rest = name.partition("-")
    if not verb or not rest:
        return None, None
    if not SLUG_RE.fullmatch(rest):
        return None, None
    return verb, rest


# -- message identity ---------------------------------------------------------

def msg_key(message_id, date="", from_addr="", subject=""):
    """The sixteen hex characters this message is filed under, forever.

    The Message-ID hashed, with the angle brackets and folding whitespace taken
    off first so the same id hashes alike whether it came out of a Message-ID
    header or out of a References list.

    The fallback is for the small number of messages that arrive with no
    Message-ID at all (some mailing list software, some bulk senders). Date,
    From and Subject joined on NUL, which is the only separator that cannot
    appear in any of the three, so no pair of different messages can be made to
    collide by putting a delimiter inside a subject line. It is weaker than a
    Message-ID and it is deliberately not silent: the index record keeps
    message_id empty, which is how the console can tell a synthesized identity
    from a real one.
    """
    ident = (message_id or "").strip().strip("<>").strip()
    if ident:
        return hashlib.sha256(ident.encode("utf-8", "replace")).hexdigest()[:16]
    seed = "\0".join((date or "", from_addr or "", subject or ""))
    return hashlib.sha256(seed.encode("utf-8", "replace")).hexdigest()[:16]


# -- headers ------------------------------------------------------------------

def parse_message(raw):
    """Raw RFC822 bytes into an EmailMessage, headers already decoded.

    policy.default is what turns `=?utf-8?B?...?=` into text and what gives
    get_body() and iter_attachments(). Malformed mail is normal mail: the parser
    records defects rather than raising, and everything downstream reads through
    helpers that tolerate a missing header.
    """
    return BytesParser(policy=policy.default).parsebytes(raw)


def header(msg, name):
    """One header as a single clean line, or "".

    Folded headers arrive with embedded newlines and runs of spaces; a subject
    that keeps them breaks every log line and audit line it later appears in, so
    whitespace is collapsed here, once, at the boundary.
    """
    try:
        raw = msg.get(name)
    except Exception:  # noqa: BLE001 -- a defective header must not end a poll
        return ""
    if raw is None:
        return ""
    try:
        return " ".join(str(raw).split())
    except Exception:  # noqa: BLE001
        return ""


def first_address(value):
    """(display name, addr) from a header value, both possibly "".

    getaddresses over the already-decoded string: the typed accessors on
    policy.default raise on addresses that do not parse, and mail from the wild
    contains addresses that do not parse.
    """
    if not value:
        return "", ""
    try:
        pairs = getaddresses([value])
    except Exception:  # noqa: BLE001
        return "", ""
    for name, addr in pairs:
        if addr:
            return name.strip(), addr.strip()
    return (pairs[0][0].strip() if pairs else ""), ""


def address_list(value, limit=10):
    """Every address in a header, bare, for the To: line the console prints."""
    if not value:
        return []
    try:
        pairs = getaddresses([value])
    except Exception:  # noqa: BLE001
        return []
    out = []
    for _, addr in pairs:
        addr = addr.strip()
        if addr and addr not in out:
            out.append(addr)
        if len(out) >= limit:
            break
    return out


def reference_ids(msg, limit=12):
    """The thread's References, oldest first, for the reply header.

    Read as a plain regex over the raw value rather than by splitting on
    whitespace: References is one of the headers senders most reliably mangle,
    and the bracketed ids are recoverable from the mangling.
    """
    raw = " ".join((header(msg, "References"), header(msg, "In-Reply-To")))
    ids = []
    for found in re.findall(r"<[^<>\s]+>", raw):
        if found not in ids:
            ids.append(found)
    return ids[-limit:]


def message_date(msg):
    """The Date header as local ISO seconds, or "" when it does not parse.

    Empty rather than "now": the console sorts on this field and a message with
    an unreadable date sorting to the top of the inbox every poll would be a
    permanent piece of furniture.
    """
    raw = header(msg, "Date")
    if not raw:
        return ""
    try:
        at = parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        return ""
    if at is None:
        return ""
    if at.tzinfo:
        at = at.astimezone()
    return at.isoformat(timespec="seconds")


def parse_headers(msg, uid, uidvalidity, flags, size):
    """The index record, which is everything the list view needs and no body.

    One record per message, written by the poller and by nobody else. The AI's
    verdict, the drafts and the outbox all live in their own files keyed the same
    way, so a re-poll that rewrites this record cannot clobber them.
    """
    subject = header(msg, "Subject")[:400]
    from_name, from_addr = first_address(header(msg, "From"))
    _, reply_to = first_address(header(msg, "Reply-To"))
    message_id = header(msg, "Message-ID").strip("<>")
    date = message_date(msg)
    key = msg_key(message_id, date, from_addr, subject)
    lowered = {flag.lower() for flag in flags}
    return {
        "key": key,
        "message_id": message_id,
        "uid": uid,
        "uidvalidity": uidvalidity,
        "from_name": from_name[:120],
        "from_addr": from_addr[:200],
        "to": address_list(header(msg, "To")),
        "reply_to": reply_to[:200],
        "subject": subject,
        "date": date,
        "size": size,
        "unread": "\\seen" not in lowered,
        "flagged": "\\flagged" in lowered,
        "in_inbox": True,
        "references": reference_ids(msg),
        "attachments": [],
        "body_cached": False,
        "truncated": False,
        "indexed_at": stamp(),
    }


def attachments(msg, limit=20):
    """Every non-body part, numbered the way the attachment route addresses it.

    The number is the position in iter_attachments(), which is stable for a
    given .eml, and the .eml is never rewritten. That is the whole reason the
    route can take an index instead of a filename: filenames repeat, are absent,
    and arrive with slashes in them.
    """
    out = []
    try:
        parts = list(msg.iter_attachments())
    except Exception:  # noqa: BLE001
        return out
    for n, part in enumerate(parts):
        if n >= limit:
            break
        try:
            payload = part.get_payload(decode=True) or b""
        except Exception:  # noqa: BLE001
            payload = b""
        name = part.get_filename() or f"part-{n}"
        out.append({
            "n": n,
            "name": " ".join(str(name).split())[:120],
            "size": len(payload),
            "ctype": part.get_content_type(),
        })
    return out


# -- body text ----------------------------------------------------------------

_HTML_DROP = frozenset(("script", "style", "head", "title", "noscript"))
_HTML_BLOCK = frozenset((
    "address", "article", "blockquote", "br", "dd", "div", "dl", "dt",
    "fieldset", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6",
    "header", "hr", "li", "main", "nav", "ol", "p", "pre", "section", "table",
    "td", "th", "tr", "ul",
))


class _Detag(HTMLParser):
    """HTML to something a tty panel can print. Not a renderer, on purpose.

    Two jobs. Drop the parts that are not prose -- script and style bodies are
    the largest thing in a marketing email and none of it is content -- and put
    a newline where the markup meant one, because the alternative is a single
    four thousand character line that the model reads as one sentence.

    convert_charrefs is left on, so entities arrive already decoded in
    handle_data and there is no second unescape pass to get wrong.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self._muted = 0

    def handle_starttag(self, tag, attrs):
        if tag in _HTML_DROP:
            self._muted += 1
        elif tag in _HTML_BLOCK:
            self.parts.append("\n")

    def handle_endtag(self, tag):
        if tag in _HTML_DROP:
            self._muted = max(0, self._muted - 1)
        elif tag in _HTML_BLOCK:
            self.parts.append("\n")

    def handle_data(self, data):
        if not self._muted:
            self.parts.append(data)

    def text(self):
        return "".join(self.parts)


def html_to_text(raw):
    """The fallback for a message with no text/plain part at all."""
    parser = _Detag()
    try:
        parser.feed(raw)
        parser.close()
    except Exception:  # noqa: BLE001 -- malformed markup is not a poll failure
        pass
    return parser.text()


def _tidy(text):
    """Trailing spaces off every line, and no run of more than one blank line.

    A converted newsletter is mostly vertical whitespace otherwise, and vertical
    whitespace costs the same as prose in a 4,000 character prompt window.
    """
    lines = [line.rstrip() for line in text.replace("\r\n", "\n").replace("\r", "\n").split("\n")]
    out = []
    blanks = 0
    for line in lines:
        if line:
            blanks = 0
            out.append(line)
            continue
        blanks += 1
        if blanks <= 1:
            out.append("")
    return "\n".join(out).strip()


def _part_text(part):
    """One text part as a str, whatever it claimed its charset was."""
    try:
        return part.get_content()
    except Exception:  # noqa: BLE001
        pass
    try:
        payload = part.get_payload(decode=True) or b""
    except Exception:  # noqa: BLE001
        return ""
    return payload.decode("utf-8", "replace")


def extract_text(msg, limit=TEXT_MAX_CHARS):
    """The readable body, and whether it was cut. Returns (text, truncated).

    text/plain wins whenever the sender bothered to send one. The HTML fallback
    is a fallback: it exists because a large share of commercial mail is
    HTML-only, not because HTML is a good source of text.

    Nothing here renders, follows a link, or loads a remote image. The output is
    printed preformatted by the console and fed to a classifier as marked
    untrusted data, and both of those are downstream of this staying dumb.
    """
    body = None
    try:
        body = msg.get_body(preferencelist=("plain", "html"))
    except Exception:  # noqa: BLE001
        body = None

    text = ""
    if body is not None:
        raw = _part_text(body)
        text = html_to_text(raw) if body.get_content_type() == "text/html" else raw
    else:
        # A message whose structure get_body could not make sense of. Walk it
        # and take the first text part rather than giving up on the body.
        try:
            parts = list(msg.walk())
        except Exception:  # noqa: BLE001
            parts = []
        for part in parts:
            ctype = part.get_content_type()
            if ctype == "text/plain":
                text = _part_text(part)
                break
            if ctype == "text/html" and not text:
                text = html_to_text(_part_text(part))

    text = _tidy(text)
    if len(text) > limit:
        return text[:limit], True
    return text, False


# -- the mailbox, as configuration --------------------------------------------
#
# Every function down here reads the environment when it is called, never at
# import time. load_env() runs inside each worker's main(), after this module has
# already been imported, so a module constant computed from os.environ would be
# a constant computed before the env file was ever opened: right under systemd's
# EnvironmentFile= and wrong on every hand-run.

# What a folder name is allowed to be. Printable ASCII, which excludes CR and LF
# by construction, minus the two characters that could end or escape the quoted
# string these names are wrapped in on the wire. Non-ASCII names (IMAP's
# modified UTF-7) are deliberately unsupported: supporting them means carrying
# an encoder, and a server whose folders have accents in them can be pointed at
# with one line of config instead.
FOLDER_RE = re.compile(r"[ -~]{1,255}")

_MAIL_ENV_HINT = ("secrets/mail-env.example lists every key and is meant to be "
                  "copied to secrets/mail-env")


def _setting(name):
    """One environment variable, stripped, or ""."""
    return (os.environ.get(name) or "").strip()


def _required(name):
    value = _setting(name)
    if not value:
        raise MailError(f"{name} is not set; {_MAIL_ENV_HINT}")
    return value


def _port(name, default):
    """A port from the environment, or the default when it is unset.

    A value that is not a number is an error rather than a quiet fall back to
    the default: a typo that silently becomes 993 is a worker talking to the
    wrong service and reporting it as a TLS failure.
    """
    raw = _setting(name)
    if not raw:
        return default
    try:
        return int(raw)
    except ValueError:
        raise MailError(f"{name} is {raw!r}, which is not a port number") from None


def _folder(name, default):
    """A folder name from the environment, validated once, here.

    Callers wrap the result in double quotes so it reaches the server as one
    argument, and that wrapping is only quoting if the name cannot carry a
    quote, a backslash or a newline out of the config file with it.
    """
    value = _setting(name) or default
    if not FOLDER_RE.fullmatch(value) or '"' in value or "\\" in value:
        raise MailError(
            f"{name} is {value!r}; a folder name here has to be printable ASCII "
            "with no double quote, backslash or newline in it")
    return value


def imap_endpoint():
    """(host, port) for IMAP over implicit TLS. Port 993 unless overridden.

    The host has to be the name on the server's certificate, which on a
    self-hosted box behind /etc/hosts means mail.<domain> and not 127.0.0.1:
    verification matches the name, not the address it resolves to.
    """
    return (_required("CHARON_IMAP_HOST"),
            _port("CHARON_IMAP_PORT", IMAP_PORT_DEFAULT))


def smtp_endpoint():
    """(host, port) for SMTP submission over implicit TLS. 465 by default."""
    return (_required("CHARON_SMTP_HOST"),
            _port("CHARON_SMTP_PORT", SMTP_PORT_DEFAULT))


def mail_from():
    """The From: header value. The mailbox address unless told otherwise.

    This is a header rather than a login, so `Charon <agent@example.com>` is a
    legal value and the display name survives. What it may not be is something
    parseaddr cannot find an address in, because the send path takes the
    Message-ID domain from it.
    """
    value = _setting("CHARON_MAIL_FROM") or _required("CHARON_MAIL_ADDRESS")
    if "@" not in parseaddr(value)[1]:
        raise MailError(f"CHARON_MAIL_FROM is {value!r}, which carries no address")
    return value


def archive_folder():
    """Where archive moves a message to. Created on first use when missing."""
    return _folder("CHARON_ARCHIVE_FOLDER", "Archive")


def sent_folder():
    """Where a copy of an outgoing message is filed."""
    return _folder("CHARON_SENT_FOLDER", "Sent")


def mail_credentials():
    """(login, password) from the environment, or MailError.

    The password is presented exactly as it appears in secrets/mail-env: nothing
    stripped, nothing normalised. The GMAIL_APP_PASSWORD handling this replaces
    squeezed spaces out of the value, because Google prints app passwords in
    four spaced groups; an ordinary mailbox password may legitimately contain a
    space, and quietly editing a credential before presenting it is a login
    failure that reads like a wrong password.

    The login is CHARON_MAIL_USER when the server wants something other than the
    address, and the address itself otherwise, which is the usual case. Neither
    value is ever logged.
    """
    address = _setting("CHARON_MAIL_ADDRESS")
    password = os.environ.get("CHARON_MAIL_PASSWORD") or ""
    if not address or not password:
        if _setting("GMAIL_ADDRESS") or os.environ.get("GMAIL_APP_PASSWORD"):
            raise MailError(
                "the mail config still uses the GMAIL_* names; the mailbox is "
                "no longer Gmail, so the keys are now CHARON_MAIL_ADDRESS and "
                f"CHARON_MAIL_PASSWORD ({_MAIL_ENV_HINT})")
        raise MailError("CHARON_MAIL_ADDRESS and CHARON_MAIL_PASSWORD are not "
                        "both set; is secrets/mail-env installed and readable? "
                        f"({_MAIL_ENV_HINT})")
    return _setting("CHARON_MAIL_USER") or address, password


# -- IMAP ---------------------------------------------------------------------

def imap_connect():
    """A logged-in IMAP4_SSL, verified, with imaplib's line ceiling raised.

    The ceiling goes up before the socket is opened rather than after, because
    the first thing a connection does is read the greeting and the constructor
    is what reads it.

    The explicit ssl_context is the load-bearing part. imaplib's IMAP4_SSL and
    smtplib's SMTP_SSL build an unverified context when they are not given one:
    PEP 476 turned verification on for http.client and left the mail modules
    alone. Without this line the connection is encrypted against a passive
    listener and wide open to anything that can answer for the address, which
    on a box reaching its own mail server through /etc/hosts is not academic.
    """
    imaplib._MAXLINE = max(imaplib._MAXLINE, MAXLINE)
    host, port = imap_endpoint()
    login, password = mail_credentials()
    try:
        conn = imaplib.IMAP4_SSL(host, port, ssl_context=ssl.create_default_context(),
                                 timeout=NET_TIMEOUT_S)
    except ssl.SSLCertVerificationError as exc:
        # Before OSError: SSLCertVerificationError is one, and "the name does
        # not match" needs a different fix from "nothing is listening".
        raise MailError(f"{host} presented a certificate that does not verify "
                        f"(did the server's ACME renewal fail?): {exc}") from exc
    except OSError as exc:
        raise MailError(f"cannot reach {host}:{port}: {exc}") from exc
    try:
        conn.login(login, password)
    except imaplib.IMAP4.error as exc:
        # The server's rejection text is safe to print; the password never
        # appears in it, and "invalid credentials" versus "authentication
        # disabled on this port" is the difference between two different fixes.
        raise MailError(f"IMAP login refused: {exc}") from exc
    return conn


def imap_close(conn):
    """Best effort. A logout that fails changes nothing about the work already
    done, and raising here would turn a finished poll into a failed unit."""
    if conn is None:
        return
    try:
        conn.logout()
    except Exception:  # noqa: BLE001
        pass


def select_inbox(conn, readonly):
    """SELECT (or EXAMINE) INBOX and return its UIDVALIDITY as an int.

    readonly=True issues EXAMINE, which is how the poller is structurally unable
    to change a flag no matter what it fetches. The actions worker is the only
    caller that passes False, and it is the only worker allowed to mutate.

    UIDVALIDITY comes back as an untagged response rather than in the SELECT
    result, and a mailbox that does not report one is a mailbox whose UIDs we
    refuse to trust at all, hence 0 (which matches no stored record).
    """
    typ, _ = conn.select("INBOX", readonly=readonly)
    if typ != "OK":
        raise MailError("cannot select INBOX")
    try:
        raw = conn.response("UIDVALIDITY")[1]
        return int(raw[0])
    except (IndexError, TypeError, ValueError):
        return 0


def uid_search(conn, *criteria):
    """UID SEARCH, as a list of ints. An empty result is [] and not an error."""
    typ, data = conn.uid("SEARCH", None, *criteria)
    if typ != "OK":
        raise MailError(f"UID SEARCH {' '.join(criteria)} failed: {data}")
    if not data or not data[0]:
        return []
    return [int(part) for part in data[0].split() if part.isdigit()]


_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun",
           "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def imap_date(at):
    """A datetime as IMAP's `1-Aug-2026`.

    Built from a table rather than strftime("%d-%b-%Y"): %b is locale dependent,
    the Pi's locale is not something this code sets, and a SEARCH SINCE with a
    localized month name is rejected by the server in a way that reads like a
    connection problem.
    """
    return f"{at.day}-{_MONTHS[at.month - 1]}-{at.year}"
