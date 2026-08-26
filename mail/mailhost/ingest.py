#!/usr/bin/env python3
"""The Worker's POST, injected into Stalwart over loopback SMTP.

Deploys to /home/pi/charon-mail/mailhost/ingest.py and runs under
mail-ingest.service. One job, and the whole inbound path is this hop:

    sender -> MX -> Cloudflare Email Routing -> charon-mail-bridge (Worker)
           -> https://mail-ingest.example.com/ingest  (cloudflared)
           -> here -> smtp 127.0.0.1:25 -> Stalwart -> the agent's mailbox
           -> mail-poller.py over IMAP, exactly as before

Cloudflare holds the MX because this box cannot: a home uplink has no reverse
DNS, port 25 inbound is blocked by the ISP, and a residential address on a
receiving MX is a deliverability argument nobody wins. So mail arrives over
HTTPS through a tunnel and becomes SMTP again in the last three feet.

Deliberately dumb: no queue, no retry, no disk writes, no parsing of the
message beyond handing the bytes on. The retry lives one hop up, where SMTP
already has one -- a non-2xx from here makes the Worker setReject, and the
sending MTA holds the message and tries again, which is a better queue than
anything this file could keep on an SD card. The cost of that design is a
duplicate delivery when a retry follows a partial success, and downstream that
is free: the poller keys a message by sha256(Message-ID), so the same message
twice is the same key twice.

Stdlib only, Python 3.11, same rule as the rest of the box: no venv.
"""

import hmac
import os
import smtplib
import sys
import urllib.parse
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from json import dumps

# Loopback only, and not configurable. The tunnel is the front door and the
# only one: a bind on the LAN address would publish a port that injects into a
# mailbox to every device on the network, with one bearer token in front of it.
BIND = "127.0.0.1"
DEFAULT_PORT = 8789

# Stalwart's plain SMTP listener, loopback, no TLS and no auth. That is not a
# gap: the listener is bound to 127.0.0.1 and Stalwart is configured to trust
# local injection, so reaching it already means being on this box.
SMTP_HOST = "127.0.0.1"
SMTP_PORT = 25
SMTP_TIMEOUT = 30

# 25 MB, which is Cloudflare's own ceiling on what an Email Worker will hand
# over, so a body above it is a malformed request rather than a big message.
# Checked against Content-Length before a byte is read: reading whatever a
# caller claims is how a write path turns into a way to exhaust a Pi's memory.
MAX_BODY_BYTES = 26_214_400

# RFC 5321 4.5.3.1.3. A bound on an address that arrives in a header, so a
# 40 KB "recipient" is refused at the door instead of inside smtplib.
MAX_ADDR_CHARS = 320

# The null return path. Bounces and delivery reports arrive with an empty
# envelope sender, and MAIL FROM:<> is how that is said on the wire.
NULL_SENDER = "<>"


def stamp():
    """Local ISO seconds, the format every other file in this system uses."""
    return datetime.now().isoformat(timespec="seconds")


def log(msg):
    """One line to stdout, which is journald under the unit.

    Never the token, never a header, never a byte of the message: the whole of
    what this process is allowed to say about a message is who it was for, how
    big it was, and what happened to it.
    """
    print(f"{stamp()}  {msg}")


def envelope_addr(raw):
    """One envelope address from a header, or None.

    Whitespace and control characters are refused rather than stripped. These
    values come off the SMTP dialogue at Cloudflare, so a recipient carrying a
    CR is an attempt to write a second command into the injection dialogue, and
    smtplib would put it straight into RCPT TO.

    Nothing else about the shape is judged. `"odd@name"@example.com` is a legal
    address, and a validator that counts the @ signs refuses real mail forever
    -- forever, because the sender keeps retrying a message this will keep
    rejecting.
    """
    value = (raw or "").strip()
    if not value or len(value) > MAX_ADDR_CHARS or "@" not in value:
        return None
    for ch in value:
        if ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F:
            return None
    return value


def addr_domain(addr):
    """The domain half, lowercased. rpartition, so a quoted local part with an
    @ in it does not move the split."""
    return addr.rpartition("@")[2].rstrip(".").lower()


def inject(envelope_from, envelope_to, body):
    """Hand one message to Stalwart, or raise OSError.

    The bytes go through untouched. Everything above this has already signed
    them: DKIM is computed over these exact octets, and a well-meant newline
    fix here is a signature broken at the only hop that had no business
    touching it. smtplib's own dot-stuffing is the sole edit, and that one is
    required by the protocol.
    """
    smtp = smtplib.SMTP(SMTP_HOST, SMTP_PORT, timeout=SMTP_TIMEOUT)
    try:
        smtp.ehlo_or_helo_if_needed()
        # Raw MIME off the internet is 8-bit more often than not. Declaring it
        # is what keeps a server that is strict about 7-bit DATA from refusing
        # a perfectly ordinary message; when the extension is not advertised,
        # the bytes go anyway and the option would be a syntax error.
        opts = ["BODY=8BITMIME"] if smtp.has_extn("8bitmime") else []
        smtp.sendmail(envelope_from, [envelope_to], body, mail_options=opts)
    finally:
        # QUIT after the fact must never change the answer. sendmail returning
        # means Stalwart took the message; letting a failed QUIT raise would
        # have the Worker reject a message that is already in the mailbox, and
        # the sender would send it a second time.
        try:
            smtp.quit()
        except Exception:  # noqa: BLE001
            smtp.close()


def make_handler(token, mail_domain):

    class Handler(BaseHTTPRequestHandler):
        server_version = "charon-ingest"
        protocol_version = "HTTP/1.1"
        # A Worker that dies mid-POST otherwise holds a thread here until the
        # kernel gives up on the socket, which on a long-lived daemon is a slow
        # leak rather than a visible failure.
        timeout = 60

        # -- plumbing --------------------------------------------------------

        def _json(self, code, payload, extra=None):
            body = dumps(payload, separators=(",", ":")).encode()
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Cache-Control", "no-store")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()
            # HEAD gets the headers and not the body. A body on a HEAD response
            # leaves the client reading it as the start of the next one.
            if self.command != "HEAD":
                self.wfile.write(body)

        def _done(self, code, result, to="-", size=0, drained=False):
            """One response and one log line, which together are the entire
            record of a message passing through here.

            Every path out of do_POST goes through this, refusals included: a
            401 that leaves no trace is a rotated token that looks like a dead
            tunnel for as long as it takes somebody to think of it.

            `drained` is whether the body was read. When it was not -- every
            refusal below decides before reading 25 MB it is going to throw
            away -- what is left in the socket is MIME rather than a request
            line, so the connection is closed instead of kept alive parsing a
            message as a verb.
            """
            if not drained:
                self.close_connection = True
            self._json(code, {"ok": True} if code == 200 else {"error": result})
            log(f"{to}  {size} bytes  {result}")

        def log_message(self, fmt, *a):
            # Suppressed. The line above is the record, and the request line
            # would double every entry in the journal with the half of it that
            # carries no envelope, no size and no outcome.
            pass

        def log_error(self, fmt, *a):
            # Kept, because `_done` only runs once a request has parsed: a read
            # that timed out or a request line that was never one leaves no
            # other trace, and during bring-up that silence reads as mail that
            # never arrived.
            log(f"-  0 bytes  http error: {fmt % a}")

        def _path(self):
            return urllib.parse.urlparse(self.path).path.rstrip("/") or "/"

        def _refuse(self):
            # Any of these verbs may carry a body this handler never reads, so
            # the connection cannot be handed back to the keep-alive loop.
            self.close_connection = True
            self._json(405, {"error": "method not allowed"},
                       {"Allow": "GET, POST"})

        do_PUT = do_DELETE = do_PATCH = do_HEAD = do_OPTIONS = _refuse

        # -- routes ----------------------------------------------------------

        def do_GET(self):
            if self._path() != "/health":
                return self._json(404, {"error": "not found"})
            # Unauthenticated on purpose, and it says nothing but that this
            # process is answering. It is what tells "the tunnel is down" apart
            # from "the daemon is down" from the Mac, and a token on that check
            # would make a rotated secret look like a broken tunnel.
            self._json(200, {"ok": True})

        def do_POST(self):
            path = self._path()
            if path == "/health":
                return self._refuse()
            if path != "/ingest":
                return self._done(404, "refused: unknown path")

            header = self.headers.get("Authorization", "")
            # compare_digest, not ==: the comparison is over a path a stranger
            # can reach, and the token is the only thing in front of a port
            # that writes into a mailbox.
            if not (header.startswith("Bearer ")
                    and hmac.compare_digest(header[7:], token)):
                return self._done(401, "refused: bad or missing token")

            raw_length = self.headers.get("Content-Length")
            try:
                length = int(raw_length)
            except (TypeError, ValueError):
                # 411 rather than 400: this is exactly the case the code is
                # for, and a body whose length was never declared is one this
                # handler will not start reading.
                return self._done(411, "refused: no usable Content-Length")
            if length <= 0:
                return self._done(400, "refused: empty body")
            if length > MAX_BODY_BYTES:
                return self._done(413, f"refused: over {MAX_BODY_BYTES} bytes",
                                  size=length)

            envelope_to = envelope_addr(self.headers.get("X-Envelope-To"))
            # A return path this cannot safely put in a MAIL FROM becomes the
            # null sender rather than a refusal: the message is still
            # deliverable, and <> is what a bounce already carries. A recipient
            # has no such fallback, so a bad one is where this stops.
            envelope_from = envelope_addr(
                self.headers.get("X-Envelope-From")) or NULL_SENDER
            if envelope_to is None:
                return self._done(400, "refused: no usable X-Envelope-To",
                                  size=length)
            if mail_domain and addr_domain(envelope_to) != mail_domain:
                # Permanent, deliberately. A recipient at another domain is a
                # misrouted Email Routing rule, and a temporary failure would
                # have some stranger's MTA retry it for four days.
                return self._done(400, f"refused: not a {mail_domain} recipient",
                                  to=envelope_to, size=length)

            try:
                body = self.rfile.read(length)
            except OSError:
                return self._done(400, "refused: could not read the body",
                                  to=envelope_to, size=length)
            if len(body) != length:
                return self._done(400, "refused: body shorter than declared",
                                  to=envelope_to, size=len(body))

            try:
                inject(envelope_from, envelope_to, body)
            except OSError as exc:
                # smtplib.SMTPException subclasses OSError, so one clause
                # covers a refusal by Stalwart and a socket that was never
                # answered. Both mean the same thing here: this message is not
                # in the mailbox, so say so and let the sender bring it back.
                return self._done(451, f"deferred: {exc.__class__.__name__}",
                                  to=envelope_to, size=length, drained=True)
            self._done(200, "accepted", to=envelope_to, size=length, drained=True)

    return Handler


def main():
    token = os.environ.get("INGEST_TOKEN", "")
    if len(token) < 24:
        raise SystemExit(
            "INGEST_TOKEN must be set to at least 24 characters.\n"
            "This port injects into the agent's mailbox with nothing else in\n"
            "front of it, so it does not start without one. Generate it, then\n"
            "give the Worker the same value:\n\n"
            "  python3 -c \"import secrets; print(secrets.token_hex(24))\"\n"
            "  wrangler secret put INGEST_TOKEN\n\n"
            "ingest-env.example is the file this is read from; copy it to\n"
            "~/charon-mail/secrets/ingest-env and chmod 600 it.\n")

    raw_port = (os.environ.get("INGEST_PORT") or "").strip()
    try:
        port = int(raw_port) if raw_port else DEFAULT_PORT
    except ValueError:
        # Not a quiet fall back to the default: a typo that silently becomes
        # 8789 is a tunnel pointed at a port nothing is listening on, reported
        # as a 502 from Cloudflare.
        raise SystemExit(f"INGEST_PORT is {raw_port!r}, which is not a port "
                         f"number.\n") from None

    mail_domain = (os.environ.get("MAIL_DOMAIN") or "").strip().rstrip(".").lower()

    # stdout is the record and journald is on the other end of it. Python
    # block-buffers a pipe, so without this a quiet hour of mail arrives in
    # `journalctl -f` all at once and minutes late. `python3 -u` in the unit
    # would do the same; doing it here means a run by hand behaves identically.
    sys.stdout.reconfigure(line_buffering=True)

    httpd = ThreadingHTTPServer((BIND, port), make_handler(token, mail_domain))
    log(f"mail ingest on http://{BIND}:{port} -> smtp {SMTP_HOST}:{SMTP_PORT}")
    log(f"envelope recipients accepted at {mail_domain}" if mail_domain else
        "MAIL_DOMAIN is unset: any recipient the Worker sends is injected")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
