#!/usr/bin/env python3
"""The Pi's side of MESSAGES-PROTOCOL.md section 5, in one file.

It implements only the Bridge-facing routes, records every request it is given,
and serves exactly one queued outbox item -- once -- so a run can prove that a
send is attempted a single time.

The config allowlists one chat from the moment the Bridge first asks, which is
what a history backfill needs to have anything to do. Ingests are recorded with
a `backfill` flag beside them so a run can tell the stream from the history
without reading either one's events.

It also takes uploads, and plays the app's half of a want. An attachment PUT is
recorded with the four headers that matter and with the digest of the bytes
that actually arrived, so a run can prove the file was not mangled on the way.
Landing the photograph is what makes this stub ask for the video: it is the
person tapping `fetch` on a tile, which is the only way the second attachment
of that row is ever supposed to go up.

  --record <path>   where the transcript is written, after every request
  --token <secret>  what the Authorization header has to carry
  --port <n>        0 for any free port; the chosen one is written to
                    <record>.port so the caller does not have to guess
"""
import argparse
import hashlib
import json
import re
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

ALLOWED_GUID = "iMessage;-;+14085550142"
OTHER_GUID = "iMessage;+;chat8291"


def key(text):
    return hashlib.sha256(text.encode()).hexdigest()[:16]


OUTBOX_ID = "a1b2c3d4e5f60718"

ATTACHMENT = re.compile(r"/v1/messages/attachment/([a-f0-9]{16})/(\d{1,3})")

STATE = {
    "record": [],
    "record_path": None,
    "token": "",
    "outbox_served": False,
    # Events that arrived carrying attachments, by key, so the wanted list can
    # be built out of what the Bridge itself said rather than out of a fixture
    # that could disagree with it.
    "attached": {},
    "stored": [],
    "wanted": [],
    "lock": threading.Lock(),
}


def note(entry):
    with STATE["lock"]:
        entry["at"] = datetime.now(timezone.utc).isoformat()
        STATE["record"].append(entry)
        with open(STATE["record_path"], "w") as handle:
            json.dump(STATE["record"], handle, indent=1)


CONFIG = {
    "updated_at": "2026-08-21T21:00:00Z",
    "chats": {
        ALLOWED_GUID: {"read": True, "send": "confirm", "name": "Nadia Sorin"},
        OTHER_GUID: {"read": False, "send": "off", "name": "Roommates"},
    },
}

QUEUED = {
    "id": OUTBOX_ID,
    "chat_key": key(ALLOWED_GUID),
    "chat_guid": ALLOWED_GUID,
    "body": "Yes, 6 works. I will be there a few minutes early.",
    "status": "queued",
    "at": "2026-08-21T21:03:40Z",
    "sent_at": None,
    "guid": None,
    "message_id": None,
    "error": None,
    "disposition": None,
    "retry_safe": None,
}


class Handler(BaseHTTPRequestHandler):

    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def authorised(self):
        header = self.headers.get("Authorization", "")
        if header == "Bearer " + STATE["token"]:
            return True
        note({"path": self.path, "method": self.command, "unauthorised": True})
        self.answer(401, {"error": "unauthorized"})
        return False

    def answer(self, status, document):
        body = json.dumps(document).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if not self.authorised():
            return
        path = urlparse(self.path).path
        if path == "/v1/messages/config":
            note({"method": "GET", "path": self.path})
            self.answer(200, CONFIG)
        elif path == "/v1/messages/outbox":
            with STATE["lock"]:
                first = not STATE["outbox_served"]
                STATE["outbox_served"] = True
            note({"method": "GET", "path": self.path, "served": 1 if first else 0})
            self.answer(200, {"items": [QUEUED] if first else []})
        elif path == "/v1/messages/attachments":
            with STATE["lock"]:
                items = list(STATE["wanted"])
            note({"method": "GET", "path": self.path, "offered": len(items)})
            self.answer(200, {"items": items})
        else:
            note({"method": "GET", "path": self.path, "unknown": True})
            self.answer(404, {"error": "unknown"})

    def do_POST(self):
        if not self.authorised():
            return
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        try:
            body = json.loads(raw) if raw else None
        except ValueError:
            body = {"unparseable": raw.decode("utf-8", "replace")}
        path = urlparse(self.path).path
        entry = {"method": "POST", "path": path, "body": body}
        if path == "/v1/messages/ingest" and isinstance(body, dict):
            entry["backfill"] = body.get("backfill") is True
            with STATE["lock"]:
                for event in body.get("events") or []:
                    if isinstance(event, dict) and event.get("attachments"):
                        STATE["attached"][event["key"]] = event
        note(entry)

        if path == "/v1/messages/ingest":
            # `cursor_ack` is the request's own cursor, whichever kind of
            # ingest this was. For a history post that is the collector
            # echoing a number it did not move, and the Bridge is expected to
            # ignore it rather than persist it.
            self.answer(200, {"ok": True,
                              "stored": len(body.get("events", [])),
                              "duplicates": 0,
                              "cursor_ack": body.get("cursor")})
        elif path == "/v1/messages/bridge":
            self.answer(200, {"ok": True})
        elif path == "/v1/messages/chats":
            self.answer(200, {"ok": True, "count": len(body.get("chats", []))})
        elif path.startswith("/v1/messages/outbox/"):
            self.answer(200, {"ok": True})
        else:
            self.answer(404, {"error": "unknown"})

    def do_PUT(self):
        """One attachment's bytes, recorded rather than kept.

        The digest is computed here over what arrived and put in the record
        beside the one the Bridge claimed, so a run can compare the two without
        either side being asked to mark its own homework.
        """
        if not self.authorised():
            return
        path = urlparse(self.path).path
        found = ATTACHMENT.fullmatch(path)
        if not found:
            note({"method": "PUT", "path": path, "unknown": True})
            self.answer(404, {"error": "unknown"})
            return
        try:
            declared = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            declared = 0
        raw = self.rfile.read(declared) if declared else b""
        seen = {name.lower(): value for name, value in self.headers.items()}
        message, n = found.group(1), int(found.group(2))
        note({"method": "PUT", "path": path, "key": message, "n": n,
              "bytes": len(raw), "declared": declared,
              "sha256": hashlib.sha256(raw).hexdigest(),
              "headers": {name: seen.get(name) for name in
                          ("content-type", "x-charon-filename",
                           "x-charon-protocol", "x-charon-sha256")}})

        with STATE["lock"]:
            if [message, n] not in STATE["stored"]:
                STATE["stored"].append([message, n])
            STATE["wanted"] = [item for item in STATE["wanted"]
                               if [item["key"], item["n"]] not in STATE["stored"]]
            # The photograph landing is the cue to ask for the video. In the
            # real thing that is a person tapping a tile; here it is the only
            # way the second attachment of this row is ever offered, which is
            # exactly the rule under test.
            event = STATE["attached"].get(message)
            listed = (event or {}).get("attachments") or []
            for other in listed:
                position = other.get("n")
                if position in (None, n) or [message, position] in STATE["stored"]:
                    continue
                if any(item["key"] == message and item["n"] == position
                       for item in STATE["wanted"]):
                    continue
                STATE["wanted"].append({
                    "key": message, "n": position, "guid": event.get("guid"),
                    "rowid": event.get("rowid"),
                    "chat_guid": event.get("chat_guid"),
                    "filename": other.get("filename"),
                    "mime_type": other.get("mime_type"),
                    "total_bytes": other.get("total_bytes"),
                })
        self.answer(200, {"ok": True, "bytes": len(raw)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--record", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--port", type=int, default=0)
    arguments = parser.parse_args()

    STATE["record_path"] = arguments.record
    STATE["token"] = arguments.token
    with open(arguments.record, "w") as handle:
        json.dump([], handle)

    server = ThreadingHTTPServer(("127.0.0.1", arguments.port), Handler)
    with open(arguments.record + ".port", "w") as handle:
        handle.write(str(server.server_address[1]))
    server.serve_forever()


if __name__ == "__main__":
    main()
