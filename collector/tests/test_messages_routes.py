#!/usr/bin/env python3
"""The messages channel's routes, end to end over a real socket.

    python3 -m unittest tests.test_messages_routes -v

Offline and free: the handler is the real one, the Collector is the real one,
the store is a temp directory, and nothing here starts a model or reaches the
network beyond loopback. The polling thread is deliberately not started -- the
messages source is polled by hand where a test needs a fresh envelope, so the
other six sources never fire and no test depends on a timer.

What this covers that the pipeline's own suite cannot: the wire. Auth, the
protocol handshake, the ingest contract including what a duplicate and a
malformed row do to `cursor_ack`, the allowlist as a route rather than as a
function, the two refusals on the send path, and the fact that a queued send
comes back to the Bridge and goes away again when it is reported.
"""

import hashlib
import http.client
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

import collector as C  # noqa: E402

TOKEN = "0123456789abcdef0123456789abcdef"

CHAT_A_GUID = "iMessage;-;+14085550142"
CHAT_B_GUID = "iMessage;+;chat829173645"


def key_of(guid):
    """The rule, spelled out here rather than imported, so this file is a
    second opinion about it rather than a restatement of the code under test."""
    return hashlib.sha256(guid.encode("utf-8")).hexdigest()[:16]


CHAT_A = key_of(CHAT_A_GUID)
CHAT_B = key_of(CHAT_B_GUID)
# The third one is only used by the deep-store test below, where the point is
# that a conversation can be buried under two other conversations' traffic.
CHAT_C_GUID = "iMessage;-;+14085550177"
CHAT_C = key_of(CHAT_C_GUID)
UNKNOWN_CHAT = "0123456789abcdef"


def event(guid, chat_guid, text, rowid, is_from_me=False, minutes=0, key=None):
    when = datetime.now(timezone.utc) - timedelta(minutes=minutes)
    return {
        "key": key or key_of(guid),
        "guid": guid,
        "rowid": rowid,
        "chat_guid": chat_guid,
        "chat_key": key_of(chat_guid),
        "chat_identifier": "+14085550142",
        "chat_name": "Nadia Sorin" if chat_guid == CHAT_A_GUID else "Roommates",
        "is_group": chat_guid == CHAT_B_GUID,
        "service": "iMessage",
        "participants": ["+14085550142"],
        "sender": None if is_from_me else "+14085550142",
        "sender_name": None if is_from_me else "Nadia Sorin",
        "is_from_me": is_from_me,
        "text": text,
        "created_at": when.isoformat(timespec="milliseconds").replace(
            "+00:00", "Z"),
        "attachments": [],
    }


def build(tmp, **overrides):
    """A Collector over a temp store, with every other source switched off."""
    cfg = C.load_config(os.path.join(tmp, "no-such-config.json"))
    for name in ("camera", "pihole", "nodes", "commits", "healthchecks",
                 "cmo", "mail"):
        cfg[name]["enabled"] = False
    cfg["state_dir"] = os.path.join(tmp, "state")
    cfg["dashboard_dir"] = os.path.join(tmp, "public")
    cfg["messages"]["base_dir"] = tmp
    cfg["messages"].update(overrides)
    os.makedirs(cfg["state_dir"], exist_ok=True)
    return C.Collector(cfg)


def allow_fixture_chats(collector, *guids):
    config = collector.messages_config_get()
    for guid in guids:
        config["chats"][guid] = {"read": True, "send": "off"}
    ok, why, _ = collector.messages_config_put(config)
    if not ok:
        raise AssertionError(why)


class MessagesRoutes(unittest.TestCase):
    """One server for the whole class, and numbered methods.

    Numbered because these are stages of one conversation with one store, not
    six independent facts: the thread route has nothing to order until the
    ingest has run, and the send route has nothing to refuse until the
    allowlist has been posted. unittest runs them alphabetically, which is what
    makes the numbers work.
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="charon-routes-")
        cls.collector = build(cls.tmp)
        cls.httpd = ThreadingHTTPServer(
            ("127.0.0.1", 0), C.make_handler(cls.collector, TOKEN))
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever,
                                      daemon=True)
        cls.thread.start()
        cls.store = os.path.join(cls.tmp, "messages")

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    # -- plumbing ------------------------------------------------------------

    def call(self, method, path, body=None, token=TOKEN):
        url = f"http://127.0.0.1:{self.port}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, method=method, data=data)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                return exc.code, json.loads(raw) if raw else None
            except ValueError:
                return exc.code, None

    def envelope(self):
        """A freshly polled messages envelope out of /v1/telemetry."""
        self.collector.sources["messages"].poll_once()
        status, doc = self.call("GET", "/v1/telemetry")
        self.assertEqual(status, 200)
        return doc["sources"]["messages"]

    def path(self, *parts):
        return os.path.join(self.store, *parts)

    # -- the stages ----------------------------------------------------------

    def test_01_unauthenticated(self):
        status, doc = self.call("GET", "/v1/telemetry", token=None)
        self.assertEqual(status, 401)
        self.assertEqual(doc, {"error": "unauthorized"})

        status, _ = self.call("POST", "/v1/messages/ingest",
                              {"protocol": 1, "events": [], "cursor": 1},
                              token=None)
        self.assertEqual(status, 401)

        status, _ = self.call("GET", "/v1/telemetry", token="x" * 32)
        self.assertEqual(status, 401)

    def test_02_protocol(self):
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 2, "events": [], "cursor": 1})
        self.assertEqual(status, 400)
        self.assertEqual(doc, {"error": "protocol"})

        status, doc = self.call("POST", "/v1/messages/bridge",
                                {"protocol": 99, "fda": True})
        self.assertEqual(status, 400)
        self.assertEqual(doc, {"error": "protocol"})

    def test_03_dormant_before_anything(self):
        snap = self.envelope()
        self.assertEqual(snap["status"], "dormant")
        self.assertEqual(snap["error"]["message"], "no bridge has reported")
        self.assertIsNone(snap["data"])

    def test_04_ingest(self):
        allow_fixture_chats(self.collector, CHAT_A_GUID, CHAT_B_GUID)
        first = event("guid-a-1", CHAT_A_GUID, "are we still on for 6?", 100)
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "events": [first],
                                 "cursor": 100})
        self.assertEqual(status, 200)
        self.assertEqual(doc["stored"], 1)
        self.assertEqual(doc["duplicates"], 0)
        self.assertEqual(doc["cursor_ack"], 100)

        mine = event("guid-a-2", CHAT_A_GUID, "on my way", 102,
                     is_from_me=True, minutes=-1)
        other = event("guid-b-1", CHAT_B_GUID, "rent is due friday", 103,
                      minutes=5)
        bad = event("guid-x-1", CHAT_A_GUID, "not mine to name", 104,
                    key="0" * 16)
        status, doc = self.call(
            "POST", "/v1/messages/ingest",
            {"protocol": 1, "events": [first, mine, other, bad],
             "cursor": 104})
        self.assertEqual(status, 200)
        self.assertEqual(doc["stored"], 2)
        self.assertEqual(doc["duplicates"], 1)
        self.assertEqual(doc["rejected"], 1)
        # Nothing failed to LAND, so the cursor moves past the row that was
        # refused: a malformed event is refused identically forever, and
        # holding the stream on one would wedge it.
        self.assertEqual(doc["cursor_ack"], 104)

        for row in (first, mine, other):
            self.assertTrue(os.path.isfile(
                self.path("index", f"{row['key']}.json")), row["guid"])
            self.assertTrue(os.path.isfile(
                self.path("bodies", f"{row['key']}.txt")), row["guid"])
        self.assertFalse(os.path.isfile(self.path("index", "0" * 16 + ".json")))

        # Only inbound rows enter the triage queue.
        spooled = sorted(os.listdir(self.path(".queue")))
        self.assertEqual(spooled, sorted([f"triage-{first['key']}",
                                          f"triage-{other['key']}"]))

        # A body holds the text and the index record does not.
        with open(self.path("bodies", f"{first['key']}.txt")) as fh:
            self.assertEqual(fh.read(), "are we still on for 6?")
        with open(self.path("index", f"{first['key']}.json")) as fh:
            record = json.load(fh)
        self.assertNotIn("text", record)
        self.assertEqual(record["body_chars"], len("are we still on for 6?"))
        self.assertTrue(record["unread"])

        with open(self.path("state.json")) as fh:
            self.assertEqual(json.load(fh)["cursor"], 104)

    def test_05_ingest_refuses_a_bad_batch(self):
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "events": {}, "cursor": 1})
        self.assertEqual(status, 400)
        self.assertIn("events", doc["error"])

        status, doc = self.call(
            "POST", "/v1/messages/ingest",
            {"protocol": 1, "events": [], "cursor": -1})
        self.assertEqual(status, 400)
        self.assertIn("cursor", doc["error"])

        too_many = [event(f"g{n}", CHAT_A_GUID, "x", n) for n in range(101)]
        status, doc = self.call(
            "POST", "/v1/messages/ingest",
            {"protocol": 1, "events": too_many, "cursor": 200})
        self.assertEqual(status, 400)

    def test_06_bridge_heartbeat(self):
        status, _ = self.call("POST", "/v1/messages/bridge", {
            "protocol": 1, "version": "0.1.0", "host": "example-mbp",
            "helper": {"version": "0.14.1", "state": "verified"},
            "fda": True, "automation": True, "db_ok": True,
            "cursor": 104, "last_event_at": "2026-08-21T21:02:12Z",
            "dropped_not_allowlisted": 31, "last_error": None,
        })
        self.assertEqual(status, 200)

        snap = self.envelope()
        self.assertEqual(snap["status"], "ok", snap.get("stale_reason"))
        bridge = snap["data"]["bridge"]
        self.assertEqual(bridge["cursor"], 104)
        self.assertEqual(bridge["helper"], "0.14.1 · verified")
        self.assertEqual(bridge["dropped"], 31)
        self.assertTrue(bridge["fda"])
        self.assertIsNotNone(bridge["seen_at"])

        counts = snap["data"]["counts"]
        self.assertEqual(counts["chats"], 2)
        # CHAT_A: her text, then his reply a minute later. Replying is reading,
        # so nothing waits there; CHAT_B still does.
        self.assertEqual(counts["unread"], 1)
        self.assertEqual(counts["queued"], 0)

        # Two conversations, newest first, and no body anywhere in the payload.
        chats = snap["data"]["chats"]
        self.assertEqual([row["chat_key"] for row in chats], [CHAT_A, CHAT_B])
        self.assertEqual(chats[0]["last_preview"], "on my way")
        self.assertEqual(chats[0]["last_sender"], "you")
        self.assertEqual(chats[0]["policy"], "off")
        self.assertTrue(chats[1]["is_group"])

    def test_07_degraded_without_a_heartbeat(self):
        """A Mac that has stopped speaking, on its own store.

        Its own Collector rather than the class's, because the fact under test
        is a clock: the store is written with a heartbeat two minutes in the
        past and read with a one-second ceiling, which is deterministic where
        sleeping in a test is not.
        """
        tmp = tempfile.mkdtemp(prefix="charon-stale-")
        try:
            store = os.path.join(tmp, "messages")
            os.makedirs(store)
            old = (datetime.now() - timedelta(minutes=2)).isoformat(
                timespec="seconds")
            with open(os.path.join(store, "state.json"), "w") as fh:
                json.dump({"bridge_seen_at": old, "cursor": 4}, fh)
            with open(os.path.join(store, "bridge.json"), "w") as fh:
                json.dump({"protocol": 1, "fda": True,
                           "helper": {"version": "0.14.1",
                                      "state": "verified"}}, fh)

            src = build(tmp, bridge_stale_after_s=1).sources["messages"]
            src.poll_once()
            snap = src.snapshot()
            self.assertEqual(snap["status"], "degraded")
            self.assertEqual(snap["stale_reason"], "bridge not reporting")

            # Talking, but with the permission it needs switched off.
            with open(os.path.join(store, "state.json"), "w") as fh:
                json.dump({"bridge_seen_at": datetime.now().isoformat(
                    timespec="seconds"), "cursor": 4}, fh)
            with open(os.path.join(store, "bridge.json"), "w") as fh:
                json.dump({"protocol": 1, "fda": False,
                           "helper": {"version": "0.14.1",
                                      "state": "verified"}}, fh)
            src = build(tmp, bridge_stale_after_s=600).sources["messages"]
            src.poll_once()
            snap = src.snapshot()
            self.assertEqual(snap["status"], "degraded")
            self.assertEqual(snap["stale_reason"],
                             "full disk access not granted")

            # Talking, allowed to read, but the helper is not the one we know.
            with open(os.path.join(store, "bridge.json"), "w") as fh:
                json.dump({"protocol": 1, "fda": True,
                           "helper": {"version": "0.9.0",
                                      "state": "mismatch"}}, fh)
            src = build(tmp, bridge_stale_after_s=600).sources["messages"]
            src.poll_once()
            snap = src.snapshot()
            self.assertEqual(snap["status"], "degraded")
            self.assertEqual(snap["stale_reason"], "helper mismatch")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)

    def test_08_config(self):
        status, doc = self.call("POST", "/v1/messages/config", {
            "chats": {CHAT_A_GUID: {"read": True, "send": "blast"}}})
        self.assertEqual(status, 400)
        self.assertIn("send", doc["error"])

        status, doc = self.call("POST", "/v1/messages/config", {
            "chats": {CHAT_A_GUID: {"read": "yes", "send": "off"}}})
        self.assertEqual(status, 400)
        self.assertIn("read", doc["error"])

        status, doc = self.call("POST", "/v1/messages/config", {
            "chats": {"  ": {"read": True, "send": "off"}}})
        self.assertEqual(status, 400)

        status, _ = self.call("POST", "/v1/messages/config", {"chats": {
            CHAT_A_GUID: {"read": True, "send": "confirm",
                          "name": "Nadia Sorin"},
            CHAT_B_GUID: {"read": True, "send": "off", "name": "Roommates"},
        }})
        self.assertEqual(status, 200)

        status, doc = self.call("GET", "/v1/messages/config")
        self.assertEqual(status, 200)
        self.assertEqual(doc["chats"][CHAT_A_GUID]["send"], "confirm")
        self.assertEqual(doc["chats"][CHAT_B_GUID]["send"], "off")
        self.assertTrue(doc["updated_at"])

    def test_08b_a_number_typed_into_the_allowlist_does_not_beat_the_address_book(self):
        # The bulk allow copies the identifier in as the name. That must not
        # win over the directory once the Mac's Contacts knows the person.
        import importlib
        col = importlib.import_module("collector")
        ident = "+14085550199"
        self.assertEqual(col.messages_display_name(ident, "Jo", None, ident), "Jo")
        self.assertEqual(col.messages_display_name("+1 (408) 555-0199", "Jo", None, ident), "Jo")
        self.assertEqual(col.messages_display_name("Jo M.", "Jo", None, ident), "Jo M.")
        self.assertEqual(col.messages_display_name(None, None, "Jo", ident), "Jo")
        self.assertEqual(col.messages_display_name(None, None, ident, ident), ident)
        self.assertEqual(col.messages_display_name("", None, None, ident), ident)

        jo_guid = "iMessage;-;+14085550199"
        status, _ = self.call("POST", "/v1/messages/chats", {
            "protocol": 1,
            "chats": [{"chat_guid": jo_guid, "chat_key": key_of(jo_guid),
                       "chat_identifier": ident, "name": "Jo",
                       "is_group": False, "service": "iMessage"}]})
        self.assertEqual(status, 200)
        # The config is replaced whole, so the entries the rest of the suite
        # relies on ride along and are put back exactly at the end.
        base = {
            CHAT_A_GUID: {"read": True, "send": "confirm", "name": "Nadia Sorin"},
            CHAT_B_GUID: {"read": True, "send": "off", "name": "Roommates"},
        }
        with_jo = dict(base)
        with_jo[jo_guid] = {"read": True, "send": "confirm", "name": ident}
        status, _ = self.call("POST", "/v1/messages/config", {"chats": with_jo})
        self.assertEqual(status, 200)
        status, doc = self.call("GET", "/v1/messages/chats")
        self.assertEqual(status, 200)
        rows = {row["chat_guid"]: row for row in doc["chats"]}
        self.assertEqual(rows[jo_guid]["name"], "Jo")
        self.assertEqual(rows[CHAT_A_GUID]["name"], "Nadia Sorin")
        status, _ = self.call("POST", "/v1/messages/config", {"chats": base})
        self.assertEqual(status, 200)

    def test_08c_your_own_live_reply_clears_the_conversation(self):
        self.addCleanup(self.collector.messages_config_put, self.collector.messages_config_get())
        allow_fixture_chats(self.collector, "iMessage;-;+14085550777")
        # Two live rows into CHAT_A: hers, then his. After his, nothing is
        # waiting: the summary says 0, the read mark sits on his key, and the
        # thread head carries the same count the list does.
        import hashlib
        def ev(guid, from_me, text, at):
            return {"key": hashlib.sha256(guid.encode()).hexdigest()[:16], "guid": guid,
                    "rowid": 900 if from_me else 899, "chat_guid": "iMessage;-;+14085550777",
                    "chat_key": key_of("iMessage;-;+14085550777"), "chat_identifier": "+14085550777",
                    "chat_name": "Read Test", "is_group": False, "service": "iMessage",
                    "participants": ["+14085550777"], "sender": "+14085550777",
                    "sender_name": "Read Test", "is_from_me": from_me, "text": text,
                    "created_at": at, "attachments": []}
        status, doc = self.call("POST", "/v1/messages/ingest", {
            "protocol": 1, "cursor": 899,
            "events": [ev("guid-readtest-in", False, "you around?", "2030-01-01T10:00:00Z")]})
        self.assertEqual(status, 200)
        status, doc = self.call("GET", "/v1/messages/thread/%s?limit=5" % key_of("iMessage;-;+14085550777"))
        self.assertEqual(status, 200)
        self.assertGreaterEqual(doc["chat"]["unread"], 1)
        status, doc = self.call("POST", "/v1/messages/ingest", {
            "protocol": 1, "cursor": 900,
            "events": [ev("guid-readtest-out", True, "yeah, what's up", "2030-01-01T10:00:30Z")]})
        self.assertEqual(status, 200)
        status, doc = self.call("GET", "/v1/messages/thread/%s?limit=5" % key_of("iMessage;-;+14085550777"))
        self.assertEqual(status, 200)
        self.assertEqual(doc["chat"]["unread"], 0)
        mark = self.read_store(".read", key_of("iMessage;-;+14085550777") + ".json") if hasattr(self, "read_store") else None
        if mark is not None:
            self.assertEqual(mark["last_read_key"], hashlib.sha256(b"guid-readtest-out").hexdigest()[:16])

    def test_09_chats_merge(self):
        status, doc = self.call("POST", "/v1/messages/chats", {
            "protocol": 1,
            "chats": [
                {"chat_guid": CHAT_A_GUID, "chat_key": CHAT_A,
                 "chat_identifier": "+14085550142", "name": "Nadia S.",
                 "is_group": False, "service": "iMessage",
                 "participants": ["+14085550142"],
                 "last_message_at": "2026-08-21T21:02:11Z"},
                {"chat_guid": "iMessage;-;+14085550199", "chat_key":
                 key_of("iMessage;-;+14085550199"), "name": "Jo",
                 "is_group": False, "service": "iMessage"},
            ]})
        self.assertEqual(status, 200)
        self.assertEqual(doc["count"], 2)

        status, doc = self.call("POST", "/v1/messages/chats", {
            "protocol": 1,
            "chats": [{"chat_guid": CHAT_A_GUID, "chat_key": "f" * 16}]})
        self.assertEqual(status, 400)

        status, doc = self.call("GET", "/v1/messages/chats")
        self.assertEqual(status, 200)
        rows = {row["chat_guid"]: row for row in doc["chats"]}
        # The allowlist's name wins over the directory's, and the policy the
        # picker draws comes from the allowlist rather than from the phone.
        self.assertEqual(rows[CHAT_A_GUID]["name"], "Nadia Sorin")
        self.assertEqual(rows[CHAT_A_GUID]["policy"], "confirm")
        self.assertTrue(rows[CHAT_A_GUID]["read"])
        # A conversation the phone lists and nobody allowlisted.
        self.assertEqual(rows["iMessage;-;+14085550199"]["policy"], "off")
        self.assertFalse(rows["iMessage;-;+14085550199"]["read"])
        # And one that is allowlisted but no longer listed: kept visible so it
        # can be turned off again.
        self.assertTrue(rows[CHAT_B_GUID]["missing"])

    def test_10_thread(self):
        status, doc = self.call("GET", f"/v1/messages/thread/{UNKNOWN_CHAT}")
        self.assertEqual(status, 404)

        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        self.assertEqual(status, 200)
        self.assertEqual(doc["chat"]["chat_guid"], CHAT_A_GUID)
        self.assertEqual(doc["chat"]["name"], "Nadia Sorin")
        self.assertEqual(doc["chat"]["policy"], "confirm")

        stamps = [row["created_at"] for row in doc["messages"]]
        self.assertEqual(stamps, sorted(stamps), "oldest to newest")
        self.assertEqual(doc["messages"][0]["text"], "are we still on for 6?")
        self.assertEqual(doc["messages"][-1]["text"], "on my way")
        self.assertIsNone(doc["messages"][0]["ai"])
        self.assertIsNone(doc["draft"])
        self.assertEqual(doc["read_to"], key_of("guid-a-2"))  # his reply, the newest row, moved the mark

        # A verdict the worker would have written, read back on the thread.
        os.makedirs(self.path("ai"), exist_ok=True)
        with open(self.path("ai", f"{doc['messages'][0]['key']}.json"),
                  "w") as fh:
            json.dump({"key": doc["messages"][0]["key"], "tags": ["plans"],
                       "urgency": 2, "needs_you": True, "summary": "dinner",
                       "status": "ok", "model": "m", "attempts": 0,
                       "at": "now"}, fh)
        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        self.assertEqual(doc["messages"][0]["ai"]["urgency"], 2)

        # Paging backwards by naming the oldest line on screen.
        oldest = doc["messages"][0]["key"]
        status, page = self.call(
            "GET", f"/v1/messages/thread/{CHAT_A}?before={oldest}")
        self.assertEqual(status, 200)
        self.assertEqual(page["messages"], [])

        status, _ = self.call("GET", f"/v1/messages/thread/{CHAT_A}?limit=nope")
        self.assertEqual(status, 400)
        status, _ = self.call("GET", f"/v1/messages/thread/{CHAT_A}?before=zz")
        self.assertEqual(status, 400)

    def test_11_read_mark(self):
        status, _ = self.call("POST", "/v1/messages/read",
                              {"chat_key": UNKNOWN_CHAT})
        self.assertEqual(status, 404)

        status, _ = self.call("POST", "/v1/messages/read", {"chat_key": CHAT_A})
        self.assertEqual(status, 200)
        self.assertTrue(os.path.isfile(self.path(".read", f"{CHAT_A}.json")))

        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        self.assertIsNotNone(doc["read_to"])

        # The panel counts against the mark, so this conversation is now clear.
        snap = self.envelope()
        by_key = {row["chat_key"]: row for row in snap["data"]["chats"]}
        self.assertEqual(by_key[CHAT_A]["unread"], 0)
        self.assertEqual(by_key[CHAT_B]["unread"], 1)

    def test_12_drafts(self):
        status, doc = self.call("POST", "/v1/messages/draft",
                                {"chat_key": UNKNOWN_CHAT})
        self.assertEqual(status, 404)

        status, doc = self.call("POST", "/v1/messages/draft",
                                {"chat_key": CHAT_A,
                                 "instructions": "tell her yes"})
        self.assertEqual(status, 200)
        self.assertEqual(doc["status"], "pending")
        self.assertIn(f"draft-{CHAT_A}", os.listdir(self.path(".queue")))

        with open(self.path("drafts", f"{CHAT_A}.json")) as fh:
            record = json.load(fh)
        self.assertEqual(record["instructions"], "tell her yes")
        self.assertEqual(record["chat_guid"], CHAT_A_GUID)

        status, _ = self.call("POST", "/v1/messages/draft",
                              {"chat_key": CHAT_A,
                               "instructions": "x" * 900})
        self.assertEqual(status, 400)

        status, _ = self.call("POST", "/v1/messages/save-draft",
                              {"chat_key": CHAT_A, "body": "yeah 6 works"})
        self.assertEqual(status, 200)

        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        self.assertEqual(doc["draft"]["status"], "pending")
        self.assertEqual(doc["user_draft"]["text"], "yeah 6 works")

    def test_13_send(self):
        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": UNKNOWN_CHAT, "body": "hi"})
        self.assertEqual(status, 404)

        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_B, "body": "hi"})
        self.assertEqual(status, 403)
        self.assertIn("not enabled", doc["error"])

        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_A, "body": "x" * 5000})
        self.assertEqual(status, 400)

        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_A, "body": "  "})
        self.assertEqual(status, 400)

        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_A,
                                 "body": "yeah 6 still works"})
        self.assertEqual(status, 200)
        mid = doc["id"]
        self.assertRegex(mid, r"^[a-f0-9]{16}$")
        self.__class__.send_id = mid

        with open(self.path("outbox", f"{mid}.json")) as fh:
            record = json.load(fh)
        self.assertEqual(record["status"], "queued")
        # Computed from the store, never from the request.
        self.assertEqual(record["chat_guid"], CHAT_A_GUID)
        self.assertTrue(os.path.isfile(self.path(".actions", f"send-{mid}")))

        snap = self.envelope()
        self.assertEqual(snap["data"]["counts"]["queued"], 1)

    def test_14_outbox_pull_and_report(self):
        mid = self.__class__.send_id

        status, doc = self.call("GET", "/v1/messages/outbox?status=sent")
        self.assertEqual(status, 400)

        status, doc = self.call("GET", "/v1/messages/outbox?status=queued")
        self.assertEqual(status, 200)
        self.assertEqual([item["id"] for item in doc["items"]], [mid])
        self.assertEqual(doc["items"][0]["body"], "yeah 6 still works")

        status, doc = self.call("POST", f"/v1/messages/outbox/{mid}",
                                {"protocol": 1, "status": "delivered"})
        self.assertEqual(status, 400)

        status, doc = self.call("POST", f"/v1/messages/outbox/{'0' * 16}",
                                {"protocol": 1, "status": "sent"})
        self.assertEqual(status, 404)

        status, _ = self.call("POST", f"/v1/messages/outbox/{mid}", {
            "protocol": 1, "status": "sent", "guid": "p:0/ABCD-1234",
            "message_id": "1842"})
        self.assertEqual(status, 200)

        with open(self.path("outbox", f"{mid}.json")) as fh:
            record = json.load(fh)
        self.assertEqual(record["status"], "sent")
        self.assertEqual(record["guid"], "p:0/ABCD-1234")
        self.assertIsNotNone(record["sent_at"])
        self.assertFalse(os.path.isfile(self.path(".actions", f"send-{mid}")))

        with open(self.path("audit.log")) as fh:
            line = fh.read().strip()
        self.assertIn(f"sent id={mid}", line)
        self.assertIn(f"chat={CHAT_A}", line)
        # The words that went out are not in the trail, only their length.
        self.assertNotIn("yeah 6 still works", line)

        # One send, one report. A replay does not get to rewrite the answer.
        status, doc = self.call("POST", f"/v1/messages/outbox/{mid}", {
            "protocol": 1, "status": "failed", "error": "nope"})
        self.assertEqual(status, 409)

        status, doc = self.call("GET", "/v1/messages/outbox?status=queued")
        self.assertEqual(doc["items"], [])

    def test_15_send_failure_is_recorded(self):
        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_A, "body": "second try"})
        mid = doc["id"]
        status, _ = self.call("POST", f"/v1/messages/outbox/{mid}", {
            "protocol": 1, "status": "failed",
            "error": "Messages.app is not running", "disposition": "no-app",
            "retry_safe": True})
        self.assertEqual(status, 200)

        with open(self.path("outbox", f"{mid}.json")) as fh:
            record = json.load(fh)
        self.assertEqual(record["status"], "failed")
        self.assertEqual(record["disposition"], "no-app")
        self.assertTrue(record["retry_safe"])

        # `failed` needs a reason, and a report with none is not a report.
        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_A, "body": "third"})
        status, _ = self.call("POST", f"/v1/messages/outbox/{doc['id']}",
                              {"protocol": 1, "status": "failed"})
        self.assertEqual(status, 400)

    def test_15a_the_thread_carries_this_chats_outbox(self):
        """A send is visible in its own thread before the row comes back.

        The Bridge performs a send on the Mac and the message returns as an
        ingest event minutes later; between the two the outbox record is the
        only copy this box has, and the thread route is where the app looks.
        """
        # Everything filed by the stages above, plus one filed here.
        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_A, "body": "on the way"})
        self.assertEqual(status, 200)
        mid = doc["id"]

        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        self.assertEqual(status, 200)
        items = {item["id"]: item for item in doc["outbox"]}
        self.assertIn(mid, items)
        self.assertEqual(items[mid]["status"], "queued")
        self.assertEqual(items[mid]["body"], "on the way")
        self.assertIsNone(items[mid]["guid"])
        # Newest last, the way the transcript above it is ordered.
        self.assertEqual(doc["outbox"][-1]["id"], mid)
        stamps = [item["at"] for item in doc["outbox"]]
        self.assertEqual(stamps, sorted(stamps), "oldest to newest")

        # A send reported sent carries the row's guid, which is what lets the
        # app drop the bubble it drew optimistically in favour of the real one.
        status, _ = self.call("POST", f"/v1/messages/outbox/{mid}", {
            "protocol": 1, "status": "sent", "guid": "p:0/EFGH-5678",
            "message_id": "1843"})
        self.assertEqual(status, 200)

        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        items = {item["id"]: item for item in doc["outbox"]}
        self.assertEqual(items[mid]["status"], "sent")
        self.assertEqual(items[mid]["guid"], "p:0/EFGH-5678")
        self.assertEqual(items[mid]["message_id"], "1843")
        self.assertIsNotNone(items[mid]["sent_at"])

        # And one that did not land says so, with the reason it was given.
        status, doc = self.call("POST", "/v1/messages/send",
                                {"chat_key": CHAT_A, "body": "nope"})
        bad = doc["id"]
        status, _ = self.call("POST", f"/v1/messages/outbox/{bad}", {
            "protocol": 1, "status": "failed",
            "error": "Messages.app is not running", "disposition": "no-app"})
        self.assertEqual(status, 200)

        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        items = {item["id"]: item for item in doc["outbox"]}
        self.assertEqual(items[bad]["status"], "failed")
        self.assertEqual(items[bad]["error"], "Messages.app is not running")
        self.assertEqual(items[bad]["disposition"], "no-app")

        # The stages above filed three more, and all three are this chat's.
        self.assertEqual(
            {item["status"] for item in doc["outbox"]},
            {"queued", "sent", "failed"})
        self.assertTrue(all(item["body"] for item in doc["outbox"]))
        self.assertLessEqual(len(doc["outbox"]), 20)

        # One conversation's sends are not another's. CHAT_B has never been
        # allowed to send, so its own list is empty rather than CHAT_A's.
        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_B}")
        self.assertEqual(status, 200)
        self.assertEqual(doc["outbox"], [])

    def test_16_summary(self):
        date = datetime.now().date().isoformat()
        os.makedirs(self.path("summaries"), exist_ok=True)
        with open(self.path("summaries", f"{date}.json"), "w") as fh:
            json.dump({"date": date, "status": "ok",
                       "needs_you": [{"chat_key": CHAT_A, "chat": "Nadia",
                                      "line": "Wants a yes on dinner at 6."}],
                       "noticed": [], "quiet": [],
                       "prose": "Quiet day apart from dinner.",
                       "model": "m", "at": "now",
                       "read": False, "archived": False}, fh)

        status, doc = self.call("GET", "/v1/messages/summary/2020-01-01")
        self.assertEqual(status, 404)

        status, doc = self.call("GET", f"/v1/messages/summary/{date}")
        self.assertEqual(status, 200)
        self.assertEqual(len(doc["needs_you"]), 1)
        self.assertFalse(doc["read"])

        status, _ = self.call("POST", "/v1/messages/summary/read",
                              {"date": date})
        self.assertEqual(status, 200)
        status, _ = self.call("POST", "/v1/messages/summary/archive",
                              {"date": date})
        self.assertEqual(status, 200)

        status, doc = self.call("GET", f"/v1/messages/summary/{date}")
        self.assertTrue(doc["read"])
        self.assertTrue(doc["archived"])

        status, doc = self.call("POST", "/v1/messages/summary/read",
                                {"date": "not-a-date"})
        self.assertEqual(status, 400)
        status, doc = self.call("POST", "/v1/messages/summary/read",
                                {"date": "2020-01-01"})
        self.assertEqual(status, 404)

        # And the strip in the envelope.
        snap = self.envelope()
        rows = snap["data"]["summaries"]
        self.assertEqual(rows[0]["date"], date)
        self.assertEqual(rows[0]["needs_you_n"], 1)
        self.assertEqual(rows[0]["preview"], "Wants a yes on dinner at 6.")
        self.assertTrue(rows[0]["archived"])

    def test_17_unknown_paths_and_methods(self):
        status, doc = self.call("POST", "/v1/messages/nope", {"a": 1})
        self.assertEqual(status, 405)
        # A key of the wrong shape is not a route, so it falls through to the
        # dashboard rather than being answered. The app validates key shapes
        # before it builds a URL for exactly this reason.
        status, _ = self.call("GET", "/v1/messages/thread/zzzz")
        self.assertEqual(status, 404)

    def test_18_backfill_is_stored_read_and_untriaged(self):
        """One conversation's history, as section 7 has it arrive.

        Four things separate it from the stream, and all four are the point of
        this test: the rows land already read, nothing is queued for triage,
        the live cursor does not move, and `cursor_ack` is an echo rather than
        an acknowledgement. The fifth is that none of it is special otherwise:
        the bodies are written the same way and the dedupe is the same dedupe,
        which the live re-post at the end proves.
        """
        with open(self.path("state.json")) as fh:
            before = json.load(fh)["cursor"]
        queued_before = sorted(os.listdir(self.path(".queue")))
        b_unread_before = [row for row in self.envelope()["data"]["chats"]
                           if row["chat_key"] == CHAT_B][0]["unread"]

        # Below everything the stream has carried, which is what history is.
        old = event("guid-a-old-1", CHAT_A_GUID, "did you ever move it?", 12,
                    minutes=60 * 24 * 80)
        mine = event("guid-a-old-2", CHAT_A_GUID, "found it, seven thirty", 13,
                     is_from_me=True, minutes=60 * 24 * 80)
        # Deliberately dated now, and into the conversation with no read mark
        # on it. A backfilled row has to be excluded because the record says it
        # was read, not because it happens to be older than a mark -- and this
        # is the row that can tell those two reasons apart.
        recent = event("guid-b-old-1", CHAT_B_GUID, "bins go out tonight", 14,
                       minutes=-5)

        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "backfill": True,
                                 "events": [old, mine, recent],
                                 "cursor": before})
        self.assertEqual(status, 200)
        self.assertEqual(doc["stored"], 3)
        self.assertEqual(doc["duplicates"], 0)
        # Echoed, not advanced.
        self.assertEqual(doc["cursor_ack"], before)

        for row in (old, mine, recent):
            with open(self.path("index", f"{row['key']}.json")) as fh:
                record = json.load(fh)
            self.assertFalse(record["unread"], row["guid"])
            self.assertTrue(record["backfill"], row["guid"])
            self.assertNotIn("text", record)
            self.assertEqual(record["body_chars"], len(row["text"]))
        with open(self.path("bodies", f"{old['key']}.txt")) as fh:
            self.assertEqual(fh.read(), "did you ever move it?")

        # Nothing new to triage, not even for the inbound one.
        self.assertEqual(sorted(os.listdir(self.path(".queue"))), queued_before)

        with open(self.path("state.json")) as fh:
            state = json.load(fh)
        self.assertEqual(state["cursor"], before)
        self.assertIsInstance(state["backfill_last_at"], str)

        # History is not news. The conversation that was clear stays clear,
        # and the one with no read mark on it does not gain an unread from a
        # row dated five minutes into the future.
        by_key = {row["chat_key"]: row for row in self.envelope()["data"]["chats"]}
        self.assertEqual(by_key[CHAT_A]["unread"], 0)
        self.assertEqual(by_key[CHAT_B]["unread"], b_unread_before)

        # And it is readable, which is what storing it was for. The thread
        # route reads the conversation out of its key index rather than out of
        # a window over the store, so a page of eighty-day-old rows comes back
        # in its place at the top of the conversation.
        status, doc = self.call("GET",
                                f"/v1/messages/thread/{CHAT_A}?limit=200")
        self.assertEqual(status, 200)
        keys = [row["key"] for row in doc["messages"]]
        self.assertIn(old["key"], keys)
        self.assertIn(mine["key"], keys)
        self.assertEqual(keys[0], old["key"], "the history is the oldest of it")
        stamps = [row["created_at"] for row in doc["messages"]]
        self.assertEqual(stamps, sorted(stamps), "oldest to newest")

        # And the same row arriving on the live path is simply a duplicate:
        # history is deduped by key like everything else.
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "events": [old],
                                 "cursor": before})
        self.assertEqual(status, 200)
        self.assertEqual(doc["stored"], 0)
        self.assertEqual(doc["duplicates"], 1)

    def test_19_backfill_envelope_and_refusals(self):
        """A history post with no cursor at all, and the shapes refused."""
        alone = event("guid-a-old-3", CHAT_A_GUID, "see you then", 14,
                      minutes=60 * 24 * 79)
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "backfill": True,
                                 "events": [alone], "cursor": None})
        self.assertEqual(status, 200)
        self.assertEqual(doc["stored"], 1)
        self.assertIsNone(doc["cursor_ack"])

        # A null cursor is a history post's privilege and nothing else's.
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "events": [], "cursor": None})
        self.assertEqual(status, 400)
        self.assertIn("cursor", doc["error"])

        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "backfill": "yes",
                                 "events": [], "cursor": 1})
        self.assertEqual(status, 400)
        self.assertIn("backfill", doc["error"])

    def test_20_idempotent_send_wire_contract(self):
        request_id = "9e284d8e-0959-4b5c-99fd-aac2bab0cdef"
        body = {"chat_key": CHAT_A, "body": "wire test", "request_id": request_id}
        config = self.collector.messages_config_get()
        config["chats"][CHAT_A_GUID] = {"read": True, "send": "confirm"}
        self.collector.messages_config_put(config)
        status, first = self.call("POST", "/v1/messages/send", body)
        self.assertEqual(status, 200)
        self.assertEqual(first.get("request_id"), request_id)
        self.assertEqual(self.call("POST", "/v1/messages/send", body), (200, first))
        for invalid in (None, "", [], "not-a-uuid"):
            status, _ = self.call("POST", "/v1/messages/send", dict(body, request_id=invalid))
            self.assertEqual(status, 400)
        status, thread = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        self.assertEqual(status, 200)
        self.assertIn(request_id, [row.get("request_id") for row in thread["outbox"]])

    def test_21_numeric_sent_row_id_matches_its_text_replay(self):
        config = self.collector.messages_config_get()
        config["chats"][CHAT_A_GUID] = {"read": True, "send": "confirm"}
        self.collector.messages_config_put(config)
        for initial, replay in ((1979, "1979"), ("0", 0)):
            with self.subTest(initial=initial):
                status, send = self.call("POST", "/v1/messages/send",
                                         {"chat_key": CHAT_A, "body": "wire test"})
                self.assertEqual(status, 200)
                mid = send["id"]
                path = f"/v1/messages/outbox/{mid}"
                report = {"protocol": 1, "status": "sent", "guid": "test-guid"}
                for invalid in (True, False, -1, 1979.5):
                    status, _ = self.call("POST", path, dict(report, message_id=invalid))
                    self.assertEqual(status, 400)
                for row_id in (initial, replay):
                    status, _ = self.call("POST", path, dict(report, message_id=row_id))
                    self.assertEqual(status, 200)
                status, thread = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
                self.assertEqual(status, 200)
                row = next(item for item in thread["outbox"] if item["id"] == mid)
                self.assertEqual((row["status"], row["message_id"]), ("sent", str(initial)))
                with open(self.path("audit.log")) as fh:
                    self.assertEqual(sum(f"sent id={mid} " in line for line in fh), 1)


class ChatSummaries(unittest.TestCase):
    """The per-conversation summaries under `messages/.chats/`.

    A fresh store per test and the Collector's own methods rather than the
    socket: what is under test here is the arithmetic a post does on its way
    past, and the wire has its own class above.

    The fact all of this exists for is in the last two tests. The chat list
    used to be the newest two thousand index records by mtime, grouped. A
    history download writes years of old messages with today's mtime, so the
    window stopped meaning "recent": the conversation somebody texted this
    morning could fall out of the list behind a nine-year thread that finished
    downloading a minute ago, and finding out took a stat of every file in the
    store every thirty seconds.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-chats-")
        self.collector = build(self.tmp)
        allow_fixture_chats(self.collector, CHAT_A_GUID, CHAT_B_GUID, CHAT_C_GUID)
        self.store = os.path.join(self.tmp, "messages")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- plumbing ------------------------------------------------------------

    def ingest(self, events, cursor, backfill=False):
        reply, why, _ = self.collector.messages_ingest(
            {"events": events, "cursor": cursor, "backfill": backfill})
        self.assertIsNone(why, why)
        return reply

    def summary(self, chat):
        with open(os.path.join(self.store, ".chats", f"{chat}.json")) as fh:
            return json.load(fh)

    def summaries(self):
        return {chat: self.summary(chat) for chat in (CHAT_A, CHAT_B)}

    def envelope(self, source=None):
        src = source or self.collector.sources["messages"]
        src.poll_once()
        snap = src.snapshot()
        self.assertIsNotNone(snap["data"], snap.get("error"))
        return snap["data"]

    @staticmethod
    def without_stamp(docs):
        """The summaries with `updated_at` taken out. It is the one field that
        is a fact about when a file was written rather than about the
        conversation in it, so it is the one field two runs are entitled to
        disagree on."""
        return {chat: {k: v for k, v in doc.items() if k != "updated_at"}
                for chat, doc in docs.items()}

    # -- what the writer keeps -----------------------------------------------

    def test_a_ingest_writes_the_summary(self):
        first = event("g-1", CHAT_A_GUID, "are we still on for 6?", 100,
                      minutes=10)
        mine = event("g-2", CHAT_A_GUID, "on my way", 101, is_from_me=True,
                     minutes=5)
        last = event("g-3", CHAT_A_GUID, "table is booked", 102, minutes=1)
        self.ingest([first, mine, last], 102)

        doc = self.summary(CHAT_A)
        self.assertEqual(doc["chat_key"], CHAT_A)
        self.assertEqual(doc["chat_guid"], CHAT_A_GUID)
        self.assertEqual(doc["total"], 3)
        # Two inbound rows. Our own text is stored for the thread's sake and
        # was never unread, and his own reply (the newest row at the time it
        # landed) cleared what came before it.
        self.assertEqual(doc["unread"], 1)
        self.assertEqual(doc["unread_keys"], [last["key"]])
        # The newest by the stamp the Mac put on the row.
        self.assertEqual(doc["last_key"], last["key"])
        self.assertEqual(doc["last_at"], last["created_at"])
        self.assertEqual(doc["last_preview"], "table is booked")
        self.assertEqual(doc["last_sender"], "Nadia Sorin")
        self.assertFalse(doc["last_is_from_me"])
        # The triage's, not ours. The pipeline writes the verdicts and this
        # program never has, so the summary says nothing about them and the
        # poll reads them for the chats it lists.
        self.assertIsNone(doc["urgency_max"])
        self.assertIsNone(doc["needs_you"])

        # A re-sent batch is deduped by key, and the summary is not counted
        # twice for it.
        self.ingest([first, mine, last], 102)
        doc = self.summary(CHAT_A)
        self.assertEqual(doc["total"], 3)
        self.assertEqual(doc["unread"], 1)

    def test_b_history_is_stored_and_is_not_news(self):
        """A backfilled row counts as a message and as nothing else."""
        live = event("g-live", CHAT_A_GUID, "table is booked", 102, minutes=1)
        self.ingest([live], 102)
        before = self.summary(CHAT_A)

        old = event("g-old", CHAT_A_GUID, "did you ever move it?", 12,
                    minutes=60 * 24 * 80)
        older = event("g-older", CHAT_A_GUID, "seven thirty then", 11,
                      minutes=60 * 24 * 81)
        self.ingest([old, older], 102, backfill=True)

        after = self.summary(CHAT_A)
        self.assertEqual(after["total"], before["total"] + 2)
        # It lands read (section 7), so it moves neither the count nor the keys.
        self.assertEqual(after["unread"], before["unread"])
        self.assertEqual(after["unread_keys"], before["unread_keys"])
        # And a message from March is not the last line of the conversation,
        # however recently it arrived.
        self.assertEqual(after["last_key"], before["last_key"])
        self.assertEqual(after["last_at"], before["last_at"])
        self.assertEqual(after["last_preview"], "table is booked")

    def test_c_read_clears_the_count(self):
        first = event("g-1", CHAT_A_GUID, "are we still on for 6?", 100,
                      minutes=10)
        second = event("g-2", CHAT_A_GUID, "the corner table", 101, minutes=5)
        self.ingest([first, second], 101)
        self.assertEqual(self.summary(CHAT_A)["unread"], 2)

        ok, why, _ = self.collector.messages_read(CHAT_A)
        self.assertTrue(ok, why)
        doc = self.summary(CHAT_A)
        self.assertEqual(doc["unread"], 0)
        self.assertEqual(doc["unread_keys"], [])
        # The mark is still written, because it is what a rebuild recomputes
        # from and this counter is not.
        self.assertTrue(os.path.isfile(
            os.path.join(self.store, ".read", f"{CHAT_A}.json")))

        third = event("g-3", CHAT_A_GUID, "see you then", 102, minutes=-1)
        self.ingest([third], 102)
        doc = self.summary(CHAT_A)
        self.assertEqual(doc["unread"], 1)
        self.assertEqual(doc["unread_keys"], [third["key"]])

    # -- what the poll draws -------------------------------------------------

    def test_d_the_list_is_ordered_by_when_not_by_mtime(self):
        """The whole reason for the summaries, as one assertion.

        The conversation with the recent message is written first and the
        conversation with the ancient one is written last, so the file that a
        scan would have called newest belongs to the chat that should be at the
        bottom of the list.
        """
        recent = event("g-b", CHAT_B_GUID, "rent is due friday", 200,
                       minutes=1)
        self.ingest([recent], 200)
        ancient = event("g-a", CHAT_A_GUID, "happy new year", 201,
                        minutes=60 * 24 * 300)
        self.ingest([ancient], 201)

        index = os.path.join(self.store, "index")
        self.assertGreaterEqual(
            os.path.getmtime(os.path.join(index, f"{ancient['key']}.json")),
            os.path.getmtime(os.path.join(index, f"{recent['key']}.json")),
            "the old message is the newest file, which is the trap")

        data = self.envelope()
        self.assertEqual([row["chat_key"] for row in data["chats"]],
                         [CHAT_B, CHAT_A])
        self.assertEqual(data["chats"][0]["last_preview"], "rent is due friday")
        self.assertEqual(data["chats"][0]["unread"], 1)
        self.assertEqual(data["counts"]["chats"], 2)
        self.assertEqual(data["counts"]["unread"], 2)

        # The counts are over the store and the list is over the window, which
        # is the point of having both.
        narrow = build(self.tmp, list_max=1).sources["messages"]
        data = self.envelope(narrow)
        self.assertEqual([row["chat_key"] for row in data["chats"]], [CHAT_B])
        self.assertEqual(data["counts"]["chats"], 2)
        self.assertEqual(data["counts"]["unread"], 2)

    def test_e_the_verdicts_are_read_per_poll(self):
        """`urgency_max` and `needs_you` have another program as their writer,
        so they are the one part of a summary the poll still opens files for."""
        first = event("g-1", CHAT_A_GUID, "can you take the dog out", 100,
                      minutes=10)
        second = event("g-2", CHAT_A_GUID, "sorry, one more thing", 101,
                       minutes=5)
        self.ingest([first, second], 101)

        os.makedirs(os.path.join(self.store, "ai"), exist_ok=True)
        # On the older of the two, deliberately: the last line of the
        # conversation is not the one that needs an answer, and a summary that
        # only looked at `last_key` would miss it.
        with open(os.path.join(self.store, "ai", f"{first['key']}.json"),
                  "w") as fh:
            json.dump({"key": first["key"], "status": "ok", "urgency": 3,
                       "needs_you": True, "tags": ["dog"], "summary": "dog",
                       "model": "m", "attempts": 0, "at": "now"}, fh)

        data = self.envelope()
        row = data["chats"][0]
        self.assertEqual(row["urgency_max"], 3)
        self.assertTrue(row["needs_you"])
        self.assertEqual(data["counts"]["needs_you"], 1)

        # A pending record is the worker counting its own attempts, not a
        # verdict, and it stays uncounted.
        with open(os.path.join(self.store, "ai", f"{second['key']}.json"),
                  "w") as fh:
            json.dump({"key": second["key"], "status": "pending",
                       "urgency": 3, "needs_you": True, "attempts": 1}, fh)
        self.assertEqual(self.envelope()["chats"][0]["urgency_max"], 3)

        # And reading the conversation clears it, which is the reason the
        # lookup is over the unread keys rather than over the newest line: the
        # question the list answers is whether there is something here he has
        # not seen, and he has now seen it.
        self.collector.messages_read(CHAT_A)
        data = self.envelope()
        self.assertEqual(data["chats"][0]["urgency_max"], 0)
        self.assertFalse(data["chats"][0]["needs_you"])
        self.assertEqual(data["counts"]["needs_you"], 0)

    # -- the crossing --------------------------------------------------------

    def populate(self):
        """A store shaped like the live one: a stream, a read, more stream,
        a history underneath it, and a second conversation."""
        live = [event(f"g-live-{n}", CHAT_A_GUID, f"line {n}", 300 + n,
                      minutes=10 - n) for n in range(1, 4)]
        self.ingest(live, 303)
        mine = event("g-mine", CHAT_A_GUID, "on my way", 304,
                     is_from_me=True, minutes=6)
        self.ingest([mine], 304)
        self.collector.messages_read(CHAT_A)
        after = [event("g-after-1", CHAT_A_GUID, "one more thing", 305,
                       minutes=2),
                 event("g-after-2", CHAT_A_GUID, "and the table", 306,
                       minutes=1)]
        self.ingest(after, 306)
        history = [event(f"g-old-{n}", CHAT_A_GUID, f"back then {n}", n,
                         minutes=60 * 24 * 90 + n) for n in range(1, 6)]
        self.ingest(history, 306, backfill=True)
        group = event("g-group", CHAT_B_GUID, "bins go out tonight", 307,
                      minutes=3)
        self.ingest([group], 307)
        return after

    def test_f_a_restart_rebuilds_the_same_summaries(self):
        """The one full scan this program is allowed, checked against the
        writer it is standing in for.

        Both sides use the same predicate for what an unread message is, which
        is what makes this an equality rather than an approximation: the ingest
        route counts rows as they arrive and this recomputes the same count
        from the same rows plus the read mark.
        """
        after = self.populate()
        before = self.summaries()
        self.assertEqual(before[CHAT_A]["total"], 11)
        self.assertEqual(before[CHAT_A]["unread"], 2)
        self.assertEqual(before[CHAT_A]["unread_keys"],
                         [after[0]["key"], after[1]["key"]])
        self.assertEqual(before[CHAT_A]["last_preview"], "and the table")

        shutil.rmtree(os.path.join(self.store, ".chats"))
        # A restart, which is where the rebuild happens.
        again = build(self.tmp)
        self.assertEqual(self.without_stamp(self.summaries()),
                         self.without_stamp(before))

        # And it is a no-op the second time: there are summaries on disk, so
        # nothing is scanned and nothing is rewritten.
        stamps = {chat: self.summary(chat)["updated_at"]
                  for chat in (CHAT_A, CHAT_B)}
        again.messages_rebuild_chat_summaries()
        self.assertEqual({chat: self.summary(chat)["updated_at"]
                          for chat in (CHAT_A, CHAT_B)}, stamps)

    def test_g_a_poll_rebuilds_what_a_restart_would_have(self):
        """The same crossing without a restart: a store with an index and no
        summaries builds them on the next poll rather than drawing an empty
        list over a full store."""
        self.populate()
        before = self.summaries()

        shutil.rmtree(os.path.join(self.store, ".chats"))
        data = self.envelope()
        self.assertEqual(self.without_stamp(self.summaries()),
                         self.without_stamp(before))
        self.assertEqual(data["counts"]["chats"], 2)
        self.assertEqual(data["counts"]["unread"], 3)
        self.assertEqual([row["chat_key"] for row in data["chats"]],
                         [CHAT_A, CHAT_B])


class ThreadIndex(unittest.TestCase):
    """The per-conversation key indexes under `messages/.threads/`.

    A fresh store per test and the Collector's own methods rather than the
    socket, like the summaries above: what is under test is which messages a
    conversation is made of and in what order, and the wire that carries the
    answer has its own class.

    The fact all of this exists for is `test_b`. A thread used to be found by
    stat-ing every record in the store, opening the newest two thousand of them
    and keeping the ones that named this conversation. That is a cost that grows
    with the store rather than with the conversation, and after a history
    download it is also wrong: a chat whose records all fall outside the window
    comes back empty, which is a nine-year thread being told it does not exist.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-threads-")
        self.collector = build(self.tmp)
        allow_fixture_chats(self.collector, CHAT_A_GUID, CHAT_B_GUID, CHAT_C_GUID)
        self.store = os.path.join(self.tmp, "messages")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    # -- plumbing ------------------------------------------------------------

    def path(self, *parts):
        return os.path.join(self.store, *parts)

    def ingest(self, events, cursor, backfill=False):
        reply, why, _ = self.collector.messages_ingest(
            {"events": events, "cursor": cursor, "backfill": backfill})
        self.assertIsNone(why, why)
        return reply

    def ingest_all(self, events, backfill=False):
        """A long history the way the Bridge sends one: in pages of a hundred,
        which is what the route accepts."""
        for at in range(0, len(events), 100):
            page = events[at:at + 100]
            reply = self.ingest(page, page[-1]["rowid"], backfill=backfill)
            self.assertEqual(reply["stored"], len(page))

    def thread(self, chat, limit=50, before=None):
        doc, why, code = self.collector.messages_thread(chat, limit, before)
        self.assertIsNone(why, f"{why} ({code})")
        return doc

    def keys(self, doc):
        return [row["key"] for row in doc["messages"]]

    def raw_lines(self, chat):
        """One key index exactly as it is on disk, in file order."""
        with open(self.path(".threads", f"{chat}.jsonl")) as fh:
            return [json.loads(line) for line in fh if line.strip()]

    def populate(self):
        """A store shaped like the live one: a stream, a read, more stream, a
        history underneath it, and a second conversation."""
        live = [event(f"g-live-{n}", CHAT_A_GUID, f"line {n}", 300 + n,
                      minutes=10 - n) for n in range(1, 4)]
        self.ingest(live, 303)
        self.collector.messages_read(CHAT_A)
        after = [event("g-after-1", CHAT_A_GUID, "one more thing", 305,
                       minutes=2),
                 event("g-after-2", CHAT_A_GUID, "and the table", 306,
                       minutes=1)]
        self.ingest(after, 306)
        history = [event(f"g-old-{n}", CHAT_A_GUID, f"back then {n}", n,
                         minutes=60 * 24 * 90 - n) for n in range(1, 6)]
        self.ingest(history, 306, backfill=True)
        group = event("g-group", CHAT_B_GUID, "bins go out tonight", 307,
                      minutes=3)
        self.ingest([group], 307)

    # -- the window ----------------------------------------------------------

    def test_a_a_window_and_the_page_behind_it(self):
        """Thirty messages, ten at a time, backwards."""
        rows = [event(f"g-{n}", CHAT_A_GUID, f"line {n}", 400 + n,
                      minutes=60 - n) for n in range(30)]
        self.ingest(rows, 429)
        keys = [row["key"] for row in rows]

        doc = self.thread(CHAT_A, limit=10)
        self.assertEqual(self.keys(doc), keys[20:])
        stamps = [row["created_at"] for row in doc["messages"]]
        self.assertEqual(stamps, sorted(stamps), "oldest to newest")
        self.assertEqual(doc["messages"][0]["text"], "line 20")
        self.assertEqual(doc["messages"][-1]["text"], "line 29")
        self.assertTrue(doc["has_more"])

        # The page behind it, named by the oldest line on screen. Exclusive:
        # the message that was named is the one already drawn.
        doc = self.thread(CHAT_A, limit=10, before=keys[20])
        self.assertEqual(self.keys(doc), keys[10:20])
        self.assertNotIn(keys[20], self.keys(doc))
        self.assertTrue(doc["has_more"])

        # And the start of the conversation, which has nothing behind it.
        doc = self.thread(CHAT_A, limit=10, before=keys[10])
        self.assertEqual(self.keys(doc), keys[:10])
        self.assertFalse(doc["has_more"])
        self.assertEqual(self.thread(CHAT_A, limit=10, before=keys[0])
                         ["messages"], [])

        # A key from another conversation is ignored rather than refused.
        doc = self.thread(CHAT_A, limit=200, before=UNKNOWN_CHAT)
        self.assertEqual(len(doc["messages"]), 30)

        # One line per stored row, and no more than that.
        self.assertEqual(len(self.raw_lines(CHAT_A)), 30)
        self.ingest(rows, 429)
        self.assertEqual(len(self.raw_lines(CHAT_A)), 30,
                         "a duplicate appends nothing")

    # -- the reason it exists ------------------------------------------------

    def test_b_a_deep_store_hides_nothing(self):
        """Two and a half thousand rows, with the conversation that matters
        written first and therefore oldest on disk.

        The old thread build opened the newest two thousand records by mtime,
        so every row of the buried conversation was outside the window and its
        thread came back empty. Nothing here is about the numbers being large:
        the store on the Pi is five times this.
        """
        buried = [event(f"g-c-{n}", CHAT_C_GUID, f"buried {n}", 1000 + n,
                        minutes=60 * 24 * 30 - n) for n in range(100)]
        self.ingest_all(buried, backfill=True)
        loud = [event(f"g-l-{n}", CHAT_A_GUID if n % 2 else CHAT_B_GUID,
                      f"line {n}", 5000 + n, minutes=2400 - n)
                for n in range(2400)]
        self.ingest_all(loud)

        index = self.path("index")
        self.assertEqual(len(os.listdir(index)), 2500)

        def mtimes(rows):
            return [os.path.getmtime(os.path.join(index, f"{row['key']}.json"))
                    for row in rows]

        # The trap, stated rather than assumed: every record of the buried
        # conversation is older on disk than every record above it, and there
        # is more than a window's worth above it.
        self.assertLessEqual(max(mtimes(buried)), min(mtimes(loud)))
        self.assertGreaterEqual(len(loud), 2000)

        doc = self.thread(CHAT_C, limit=200)
        self.assertEqual(self.keys(doc), [row["key"] for row in buried])
        self.assertEqual(doc["messages"][0]["text"], "buried 0")
        self.assertEqual(doc["messages"][-1]["text"], "buried 99")
        self.assertFalse(doc["has_more"])
        self.assertEqual(doc["chat"]["chat_guid"], CHAT_C_GUID)

        # And the two loud ones are whole as well, one page at a time.
        for chat in (CHAT_A, CHAT_B):
            self.assertEqual(len(self.raw_lines(chat)), 1200)
            page = self.thread(chat, limit=50)
            self.assertEqual(len(page["messages"]), 50)
            self.assertTrue(page["has_more"])
        self.assertEqual(sorted(os.listdir(self.path(".threads"))),
                         sorted(f"{chat}.jsonl"
                                for chat in (CHAT_A, CHAT_B, CHAT_C)))

    # -- the crossing --------------------------------------------------------

    def test_c_the_migration_matches_what_the_writer_kept(self):
        """A store with records and no key indexes, which is the live Pi.

        The rebuilt indexes have to be the ones the ingest route would have
        appended, message for message and in the same order, or a thread built
        after a restart is a different conversation than the one before it.
        """
        self.populate()
        before = {chat: self.collector.messages_thread_index(chat)
                  for chat in (CHAT_A, CHAT_B)}
        threads = {chat: self.keys(self.thread(chat, limit=200))
                   for chat in (CHAT_A, CHAT_B)}
        self.assertEqual(len(before[CHAT_A]), 10)
        self.assertEqual(len(before[CHAT_B]), 1)

        shutil.rmtree(self.path(".threads"))
        # A restart, which is where the rebuild happens.
        again = build(self.tmp)
        self.assertEqual({chat: again.messages_thread_index(chat)
                          for chat in (CHAT_A, CHAT_B)}, before)
        self.assertEqual({chat: self.keys(
            again.messages_thread(chat, 200, None)[0])
            for chat in (CHAT_A, CHAT_B)}, threads)

        # A rebuilt file starts ordered, which an appended one is not obliged
        # to be: the history at the bottom of this conversation arrived last.
        for chat in (CHAT_A, CHAT_B):
            self.assertEqual([row["key"] for row in self.raw_lines(chat)],
                             [row[2] for row in before[chat]])

        # And it is a no-op the second time, both whole and one at a time.
        self.assertIsNone(again.messages_rebuild_thread_indexes())
        self.assertIsNone(again.messages_rebuild_thread_index(CHAT_A))

        # A single missing file is the partial case, and it is rebuilt by the
        # tap that finds it missing rather than by a restart.
        os.remove(self.path(".threads", f"{CHAT_A}.jsonl"))
        self.assertEqual(self.keys(again.messages_thread(CHAT_A, 200, None)[0]),
                         threads[CHAT_A])
        self.assertEqual(again.messages_thread_index(CHAT_A), before[CHAT_A])

    def test_d_a_mangled_line_costs_itself(self):
        """These files have one writer, and they sit on a disk a person can
        edit. One bad line is one bad line."""
        rows = [event(f"g-{n}", CHAT_A_GUID, f"line {n}", 500 + n,
                      minutes=30 - n) for n in range(5)]
        self.ingest(rows, 504)
        keys = [row["key"] for row in rows]

        with open(self.path(".threads", f"{CHAT_A}.jsonl"), "a") as fh:
            fh.write("not json at all\n")
            fh.write("\n")
            fh.write("[1, 2, 3]\n")
            fh.write('"a string"\n')
            fh.write('{"rowid": 9, "at": "2026-08-21T21:00:00Z"}\n')
            fh.write('{"key": "zz", "at": "2026-08-21T21:00:00Z"}\n')
            # And the one corruption a reader would actually see: the same
            # message twice.
            fh.write(json.dumps({"key": keys[0], "rowid": 500,
                                 "at": rows[0]["created_at"],
                                 "from_me": False}) + "\n")

        self.assertEqual(self.keys(self.thread(CHAT_A, limit=200)), keys)

        # A line whose record has gone costs its own message and nothing else.
        os.remove(self.path("index", f"{keys[2]}.json"))
        self.assertEqual(self.keys(self.thread(CHAT_A, limit=200)),
                         [keys[0], keys[1], keys[3], keys[4]])

    def test_e_an_empty_conversation_and_an_absent_one(self):
        """404 is for a conversation this program has never heard of, and an
        empty room is for one it knows and holds nothing of."""
        self.ingest([event("g-1", CHAT_A_GUID, "hello", 100, minutes=5)], 100)

        doc, why, code = self.collector.messages_thread(UNKNOWN_CHAT, 50, None)
        self.assertIsNone(doc)
        self.assertEqual(code, 404)
        self.assertIn(UNKNOWN_CHAT, why)

        # A summary with nothing under it: the state a conversation is in
        # between being allowlisted and its first message landing.
        self.collector.messages_chat_summary_put(
            CHAT_B, self.collector.messages_chat_summary_blank(CHAT_B))
        doc = self.thread(CHAT_B)
        self.assertEqual(doc["messages"], [])
        self.assertFalse(doc["has_more"])
        self.assertEqual(doc["chat"]["chat_key"], CHAT_B)
        self.assertEqual(doc["chat"]["policy"], "off")
        # The tap that found no key index wrote one, so the next tap on this
        # conversation does not go looking through the store again.
        self.assertTrue(
            os.path.isfile(self.path(".threads", f"{CHAT_B}.jsonl")))
        self.assertEqual(self.raw_lines(CHAT_B), [])

    def test_f_the_other_routes_resolve_through_the_store(self):
        """The read mark, the two drafts and the send, with no scan under any
        of them. What each one needs is the conversation's newest key or its
        GUID, and both are written down."""
        first = event("g-1", CHAT_A_GUID, "are we still on for 6?", 100,
                      minutes=10)
        last = event("g-2", CHAT_A_GUID, "the corner table", 101, minutes=5)
        group = event("g-3", CHAT_B_GUID, "bins go out tonight", 102, minutes=3)
        self.ingest([first, last, group], 102)
        jo_guid = "iMessage;-;+14085550199"
        ok, why, _ = self.collector.messages_config_put({
            "updated_at": C.stamp(),
            "chats": {
                CHAT_A_GUID: {"read": True, "send": "confirm",
                              "name": "Nadia Sorin"},
                CHAT_B_GUID: {"read": True, "send": "off", "name": "Roommates"},
                jo_guid: {"read": True, "send": "confirm", "name": "Jo"},
            }})
        self.assertTrue(ok, why)

        # The mark is the conversation's newest message, off its summary.
        ok, why, _ = self.collector.messages_read(CHAT_A)
        self.assertTrue(ok, why)
        with open(self.path(".read", f"{CHAT_A}.json")) as fh:
            mark = json.load(fh)
        self.assertEqual(mark["last_read_key"], last["key"])
        self.assertEqual(mark["last_read_at"], last["created_at"])
        self.assertEqual(self.thread(CHAT_A)["read_to"], last["key"])
        self.assertEqual(self.collector.messages_read(UNKNOWN_CHAT)[2], 404)

        status, why, _ = self.collector.messages_draft(CHAT_A, "tell her yes")
        self.assertEqual(status, "pending", why)
        with open(self.path("drafts", f"{CHAT_A}.json")) as fh:
            self.assertEqual(json.load(fh)["chat_guid"], CHAT_A_GUID)
        self.assertEqual(self.collector.messages_draft(UNKNOWN_CHAT, None)[2],
                         404)

        ok, why, _ = self.collector.messages_save_draft(CHAT_A, "yeah 6 works")
        self.assertTrue(ok, why)
        self.assertEqual(
            self.collector.messages_save_draft(UNKNOWN_CHAT, "hi")[2], 404)

        # The one thing that leaves the house. The destination is the store's,
        # never the caller's.
        mid, why, _ = self.collector.messages_send(CHAT_A, "yeah 6 still works")
        self.assertIsNotNone(mid, why)
        with open(self.path("outbox", f"{mid}.json")) as fh:
            self.assertEqual(json.load(fh)["chat_guid"], CHAT_A_GUID)
        self.assertEqual(self.collector.messages_send(CHAT_B, "hi")[2], 403)
        self.assertEqual(self.collector.messages_send(UNKNOWN_CHAT, "hi")[2],
                         404)

        # An allowlisted conversation with nothing stored yet is still a
        # destination: the GUID comes off the allowlist when there is no
        # summary to take it from.
        mid, why, _ = self.collector.messages_send(key_of(jo_guid), "hi")
        self.assertIsNotNone(mid, why)
        with open(self.path("outbox", f"{mid}.json")) as fh:
            self.assertEqual(json.load(fh)["chat_guid"], jo_guid)


# --- the attachments ---------------------------------------------------------

# Not real files, and deliberately not: nothing on either side of this route
# looks inside the bytes. What is under test is that the bytes that went up are
# the bytes that come down, that the digest is checked, and that nothing a
# filename says can reach a path.
PHOTO = b"\x89PNG\r\n\x1a\n" + b"one photograph, near enough for a test. " * 64
OTHER_PHOTO = b"\x89PNG\r\n\x1a\n" + b"a different photograph entirely. " * 71
CLIP = b"\x00\x00\x00\x18ftypqt  " + b"twelve seconds of something. " * 128


def digest_of(blob):
    return hashlib.sha256(blob).hexdigest()


def with_attachments(guid, chat_guid, text, rowid, attachments, **rest):
    """One event carrying files. The module's own `event`, with a list on it."""
    row = event(guid, chat_guid, text, rowid, **rest)
    row["attachments"] = attachments
    return row


PHOTO_META = {"n": 0, "filename": "IMG_0412.png", "mime_type": "image/png",
              "total_bytes": len(PHOTO), "missing": False}
CLIP_META = {"n": 1, "filename": "IMG_0413.mov", "mime_type": "video/quicktime",
             "total_bytes": len(CLIP), "missing": False}
GONE_META = {"n": 2, "filename": "IMG_0009.heic", "mime_type": "image/heic",
             "total_bytes": 4_200_000, "missing": True}


class Attachments(unittest.TestCase):
    """The bytes: uploaded, served, asked for, and refused.

    One server and one store for the whole class, numbered like the routes
    above and for the same reason: there is nothing to upload until something
    has been ingested, and nothing to want until an upload has been withheld.

    Driven with `http.client` rather than `urllib` because three of the facts
    under test are headers -- the type, the disposition and the cache -- and
    one of them is a `Content-Length` that deliberately disagrees with the body
    behind it, which is the only way to prove the ceiling is checked before the
    body is read rather than after twenty-five megabytes of it.
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="charon-attach-")
        cls.collector = build(cls.tmp)
        cls.httpd = ThreadingHTTPServer(
            ("127.0.0.1", 0), C.make_handler(cls.collector, TOKEN))
        cls.port = cls.httpd.server_address[1]
        cls.thread = threading.Thread(target=cls.httpd.serve_forever,
                                      daemon=True)
        cls.thread.start()
        cls.store = os.path.join(cls.tmp, "messages")

    @classmethod
    def tearDownClass(cls):
        cls.httpd.shutdown()
        cls.httpd.server_close()
        shutil.rmtree(cls.tmp, ignore_errors=True)

    # -- plumbing ------------------------------------------------------------

    def path(self, *parts):
        return os.path.join(self.store, *parts)

    def call(self, method, path, body=None, token=TOKEN):
        url = f"http://127.0.0.1:{self.port}{path}"
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, method=method, data=data)
        if token:
            req.add_header("Authorization", f"Bearer {token}")
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=10) as resp:
                raw = resp.read()
                return resp.status, (json.loads(raw) if raw else None)
        except urllib.error.HTTPError as exc:
            raw = exc.read()
            try:
                return exc.code, json.loads(raw) if raw else None
            except ValueError:
                return exc.code, None

    def raw(self, method, path, body=None, headers=None, token=TOKEN,
            claim=None, cut=False):
        """One request, with the headers on both sides of it visible.

        `claim` overrides the `Content-Length` without changing what is
        actually sent, which is how the ceiling is tested for the price of a
        few bytes rather than the price of the ceiling. `cut` closes this end's
        writing half after the body, which is what an upload that died halfway
        looks like from the server's side -- without it the read simply waits,
        because a socket nobody has closed has not ended.
        """
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        try:
            conn.putrequest(method, path, skip_accept_encoding=True)
            if token:
                conn.putheader("Authorization", f"Bearer {token}")
            if body is not None:
                conn.putheader("Content-Length",
                               str(len(body) if claim is None else claim))
            for name, value in (headers or {}).items():
                conn.putheader(name, value)
            conn.endheaders()
            if body:
                conn.send(body)
            if cut:
                conn.sock.shutdown(socket.SHUT_WR)
            answer = conn.getresponse()
            return answer.status, answer.read(), dict(answer.getheaders())
        finally:
            conn.close()

    def upload(self, key, n, blob, name=None, ctype=None, sha=None,
               claim=None, token=TOKEN, protocol="1", cut=False):
        headers = {}
        if ctype is not None:
            headers["Content-Type"] = ctype
        if name is not None:
            headers["X-Charon-Filename"] = name
        if sha is not None:
            headers["X-Charon-SHA256"] = sha
        if protocol is not None:
            headers["X-Charon-Protocol"] = protocol
        status, raw, _ = self.raw(
            "PUT", f"/v1/messages/attachment/{key}/{n}", blob, headers,
            token=token, claim=claim, cut=cut)
        try:
            return status, json.loads(raw) if raw else None
        except ValueError:
            return status, None

    def wanted(self):
        status, doc = self.call("GET",
                                "/v1/messages/attachments?status=wanted")
        self.assertEqual(status, 200)
        return doc["items"]

    # -- the stages ----------------------------------------------------------

    def test_01_ingest_records_what_is_attached(self):
        allow_fixture_chats(self.collector, CHAT_A_GUID)
        row = with_attachments(
            "guid-att-1", CHAT_A_GUID, "look at this", 500,
            [dict(PHOTO_META), dict(CLIP_META), dict(GONE_META)])
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "events": [row],
                                 "cursor": 500})
        self.assertEqual(status, 200)
        self.assertEqual(doc["stored"], 1)
        self.__class__.key = row["key"]

        with open(self.path("index", f"{row['key']}.json")) as fh:
            record = json.load(fh)
        self.assertEqual([a["n"] for a in record["attachments"]], [0, 1, 2])
        # `stored` is this box's answer, and nothing has been uploaded yet.
        self.assertEqual([a["stored"] for a in record["attachments"]],
                         [False, False, False])
        self.assertTrue(record["attachments"][2]["missing"])

        # The store's two new directories exist as soon as anything is written.
        self.assertTrue(os.path.isdir(self.path("attachments")))
        self.assertTrue(os.path.isdir(self.path(".wants")))

    def test_02_an_n_that_is_not_its_own_position_is_refused(self):
        row = with_attachments(
            "guid-att-bad", CHAT_A_GUID, "mislabelled", 501,
            [{"n": 3, "filename": "a.png", "mime_type": "image/png",
              "total_bytes": 10, "missing": False}])
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "events": [row],
                                 "cursor": 501})
        self.assertEqual(status, 200)
        self.assertEqual(doc["rejected"], 1)
        self.assertIn("position", doc["error"])
        self.assertFalse(os.path.isfile(
            self.path("index", f"{row['key']}.json")))

    def test_03_upload_and_get_round_trip(self):
        status, doc = self.upload(self.key, 0, PHOTO, name="IMG_0412.png",
                                  ctype="image/png", sha=digest_of(PHOTO))
        self.assertEqual(status, 200, doc)
        self.assertEqual(doc, {"ok": True, "bytes": len(PHOTO)})

        # The file and its sidecar, named by the position and the extension.
        self.assertTrue(os.path.isfile(
            self.path("attachments", self.key, "0.png")))
        with open(self.path("attachments", self.key, "0.json")) as fh:
            side = json.load(fh)
        self.assertEqual(side["filename"], "IMG_0412.png")
        self.assertEqual(side["mime_type"], "image/png")
        self.assertEqual(side["bytes"], len(PHOTO))
        self.assertEqual(side["sha256"], digest_of(PHOTO))
        self.assertTrue(side["at"])
        # Nothing of the staging file survives a landing.
        self.assertEqual(
            sorted(os.listdir(self.path("attachments", self.key))),
            ["0.json", "0.png"])

        # And the record now says the store holds it.
        with open(self.path("index", f"{self.key}.json")) as fh:
            record = json.load(fh)
        self.assertEqual([a["stored"] for a in record["attachments"]],
                         [True, False, False])

        status, blob, headers = self.raw(
            "GET", f"/v1/messages/attachment/{self.key}/0")
        self.assertEqual(status, 200)
        self.assertEqual(blob, PHOTO)
        self.assertEqual(headers["Content-Type"], "image/png")
        self.assertEqual(headers["Content-Length"], str(len(PHOTO)))
        self.assertEqual(headers["Content-Disposition"],
                         'attachment; filename="IMG_0412.png"')
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertEqual(headers["Cache-Control"], "private, max-age=86400")

    def test_04_over_the_cap_is_413(self):
        status, doc = self.upload(
            self.key, 1, b"x" * 64, name="IMG_0413.mov",
            ctype="video/quicktime",
            claim=C.MESSAGES_ATTACHMENT_MAX_BYTES + 1)
        self.assertEqual(status, 413)
        self.assertIn(str(C.MESSAGES_ATTACHMENT_MAX_BYTES), doc["error"])
        # Refused on the headers alone: nothing was written and nothing was
        # staged.
        self.assertEqual(
            sorted(os.listdir(self.path("attachments", self.key))),
            ["0.json", "0.png"])

    def test_05_a_message_this_store_does_not_hold_is_404(self):
        status, doc = self.upload("0" * 16, 0, PHOTO, name="x.png",
                                  ctype="image/png")
        self.assertEqual(status, 404)
        self.assertIn("no message", doc["error"])

        # A position past the end of the row's own list is the same answer.
        status, doc = self.upload(self.key, 7, PHOTO, name="x.png",
                                  ctype="image/png")
        self.assertEqual(status, 404)
        self.assertIn("no attachment", doc["error"])

        # And a read of something nobody has uploaded.
        status, raw, _ = self.raw(
            "GET", f"/v1/messages/attachment/{self.key}/1")
        self.assertEqual(status, 404)
        self.assertIn("not stored", json.loads(raw)["error"])

        # A key of the wrong shape is not this route at all.
        status, _, _ = self.raw("GET", "/v1/messages/attachment/zzzz/0")
        self.assertEqual(status, 404)

    def test_06_the_digest_is_checked(self):
        status, doc = self.upload(self.key, 1, CLIP, name="IMG_0413.mov",
                                  ctype="video/quicktime",
                                  sha=digest_of(PHOTO))
        self.assertEqual(status, 400)
        self.assertIn("digest", doc["error"])
        self.assertFalse(os.path.isfile(
            self.path("attachments", self.key, "1.mov")))
        # The staging file went with it.
        self.assertEqual(
            sorted(os.listdir(self.path("attachments", self.key))),
            ["0.json", "0.png"])

        status, doc = self.upload(self.key, 1, CLIP, name="IMG_0413.mov",
                                  ctype="video/quicktime", sha="nonsense")
        self.assertEqual(status, 400)
        self.assertIn("hex", doc["error"])

    def test_07_the_same_upload_twice_does_not_rewrite(self):
        before = os.stat(self.path("attachments", self.key, "0.png"))
        status, doc = self.upload(self.key, 0, PHOTO, name="IMG_0412.png",
                                  ctype="image/png", sha=digest_of(PHOTO))
        self.assertEqual(status, 200)
        self.assertEqual(doc, {"ok": True, "bytes": len(PHOTO)})
        after = os.stat(self.path("attachments", self.key, "0.png"))
        self.assertEqual((before.st_ino, before.st_mtime_ns),
                         (after.st_ino, after.st_mtime_ns),
                         "a matching digest must not rewrite the file")

        # Different bytes under the same name are a genuine replacement.
        status, doc = self.upload(self.key, 0, OTHER_PHOTO,
                                  name="IMG_0412.png", ctype="image/png",
                                  sha=digest_of(OTHER_PHOTO))
        self.assertEqual(status, 200)
        self.assertEqual(doc["bytes"], len(OTHER_PHOTO))
        status, blob, _ = self.raw(
            "GET", f"/v1/messages/attachment/{self.key}/0")
        self.assertEqual(blob, OTHER_PHOTO)
        self.assertEqual(
            sorted(os.listdir(self.path("attachments", self.key))),
            ["0.json", "0.png"], "one attachment is one file")

    def test_08_want_then_the_list_then_the_upload_clears_it(self):
        self.assertEqual(self.wanted(), [])

        status, doc = self.call(
            "POST", f"/v1/messages/attachment/{self.key}/1/want")
        self.assertEqual(status, 200, doc)
        self.assertEqual(doc, {"ok": True})
        self.assertTrue(os.path.isfile(
            self.path(".wants", f"{self.key}-1.json")))

        # Idempotent, and it does not restart the clock: the file's own age is
        # what expires a want nobody can answer.
        stat = os.stat(self.path(".wants", f"{self.key}-1.json"))
        status, _ = self.call(
            "POST", f"/v1/messages/attachment/{self.key}/1/want")
        self.assertEqual(status, 200)
        self.assertEqual(
            os.stat(self.path(".wants", f"{self.key}-1.json")).st_mtime_ns,
            stat.st_mtime_ns)
        self.assertEqual(
            len(os.listdir(self.path(".wants"))), 1, "asking twice is one file")

        items = self.wanted()
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0], {
            "key": self.key, "n": 1, "guid": "guid-att-1", "rowid": 500,
            "chat_guid": CHAT_A_GUID, "filename": "IMG_0413.mov",
            "mime_type": "video/quicktime", "total_bytes": len(CLIP)})

        status, doc = self.upload(self.key, 1, CLIP, name="IMG_0413.mov",
                                  ctype="video/quicktime", sha=digest_of(CLIP))
        self.assertEqual(status, 200, doc)
        self.assertEqual(self.wanted(), [])
        self.assertFalse(os.path.isfile(
            self.path(".wants", f"{self.key}-1.json")))

        status, blob, headers = self.raw(
            "GET", f"/v1/messages/attachment/{self.key}/1")
        self.assertEqual(status, 200)
        self.assertEqual(blob, CLIP)
        self.assertEqual(headers["Content-Type"], "video/quicktime")

    def test_09_a_want_nobody_can_answer_is_dropped(self):
        # A message the store does not hold cannot be wanted at all.
        status, doc = self.call(
            "POST", f"/v1/messages/attachment/{'0' * 16}/0/want")
        self.assertEqual(status, 404)
        status, doc = self.call(
            "POST", f"/v1/messages/attachment/{self.key}/9/want")
        self.assertEqual(status, 404)

        # One that is already stored is answered ok and files nothing: the app
        # has just learned it can stop asking.
        status, _ = self.call(
            "POST", f"/v1/messages/attachment/{self.key}/0/want")
        self.assertEqual(status, 200)
        self.assertEqual(os.listdir(self.path(".wants")), [])

        # And one for a file the Mac has never produced ages out.
        status, _ = self.call(
            "POST", f"/v1/messages/attachment/{self.key}/2/want")
        self.assertEqual(status, 200)
        self.assertEqual(len(self.wanted()), 1)
        old = self.path(".wants", f"{self.key}-2.json")
        stale = time.time() - C.MESSAGES_WANT_MAX_AGE - 60
        os.utime(old, (stale, stale))
        self.assertEqual(self.wanted(), [])
        self.assertFalse(os.path.isfile(old))

    def test_10_the_thread_says_which_are_stored(self):
        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        self.assertEqual(status, 200)
        row = next(m for m in doc["messages"] if m["key"] == self.key)
        self.assertEqual([(a["n"], a["stored"]) for a in row["attachments"]],
                         [(0, True), (1, True), (2, False)])
        self.assertEqual(row["attachments"][2]["missing"], True)

        # A record written before either field existed still answers both, off
        # its own shape: the position is where the item is, and bytes this box
        # does not hold are bytes it says it does not hold.
        older = with_attachments(
            "guid-att-old", CHAT_A_GUID, "from before", 499,
            [{"filename": "old.heic", "mime_type": "image/heic",
              "total_bytes": 900, "missing": False}])
        status, _ = self.call("POST", "/v1/messages/ingest",
                              {"protocol": 1, "events": [older],
                               "cursor": 501})
        self.assertEqual(status, 200)
        index = self.path("index", f"{older['key']}.json")
        with open(index) as fh:
            record = json.load(fh)
        record["attachments"][0].pop("n")
        record["attachments"][0].pop("stored")
        with open(index, "w") as fh:
            json.dump(record, fh)

        status, doc = self.call("GET", f"/v1/messages/thread/{CHAT_A}")
        row = next(m for m in doc["messages"] if m["key"] == older["key"])
        self.assertEqual(row["attachments"][0]["n"], 0)
        self.assertFalse(row["attachments"][0]["stored"])

    def test_11_a_filename_cannot_reach_a_path(self):
        row = with_attachments(
            "guid-att-names", CHAT_A_GUID, "three awkward names", 502,
            [{"n": 0, "filename": "../x.png", "mime_type": "image/png",
              "total_bytes": len(PHOTO), "missing": False},
             {"n": 1, "filename": "caf\u00e9 \"note\".png",
              "mime_type": "image/png", "total_bytes": len(PHOTO),
              "missing": False},
             {"n": 2, "filename": "", "mime_type": "image/png",
              "total_bytes": len(PHOTO), "missing": False}])
        status, doc = self.call("POST", "/v1/messages/ingest",
                                {"protocol": 1, "events": [row],
                                 "cursor": 502})
        self.assertEqual(status, 200, doc)
        key = row["key"]

        # A name with a path in it. The separator is the only character the
        # alphabet refuses, and what is left is a filename.
        status, doc = self.upload(key, 0, PHOTO, name="../x.png",
                                  ctype="image/png")
        self.assertEqual(status, 200, doc)
        self.assertTrue(os.path.isfile(self.path("attachments", key, "0.png")))
        _, _, headers = self.raw("GET", f"/v1/messages/attachment/{key}/0")
        self.assertEqual(headers["Content-Disposition"],
                         'attachment; filename="x.png"')

        # A name with characters no header may carry. Rebuilt, not escaped.
        status, doc = self.upload(key, 1, PHOTO,
                                  name="caf\u00e9 \"note\".png".encode("utf-8"),
                                  ctype="image/png")
        self.assertEqual(status, 200, doc)
        _, _, headers = self.raw("GET", f"/v1/messages/attachment/{key}/1")
        served = headers["Content-Disposition"]
        self.assertTrue(served.startswith('attachment; filename="'), served)
        self.assertEqual(served.count('"'), 2, served)
        for forbidden in ("/", "\\", "\r", "\n", ";"):
            self.assertNotIn(forbidden, served[22:-1], served)
        self.assertEqual(len(os.listdir(self.path("attachments", key))), 4)

        # No name at all. The position becomes the name and the type becomes
        # the extension.
        status, doc = self.upload(key, 2, PHOTO, name="", ctype="image/png")
        self.assertEqual(status, 200, doc)
        self.assertTrue(os.path.isfile(self.path("attachments", key, "2.png")))
        _, _, headers = self.raw("GET", f"/v1/messages/attachment/{key}/2")
        self.assertEqual(headers["Content-Disposition"],
                         'attachment; filename="attachment-2"')

        # Nothing left the message's own directory.
        for room, _, files in os.walk(self.path("attachments")):
            for name in files:
                self.assertTrue(
                    os.path.realpath(os.path.join(room, name)).startswith(
                        os.path.realpath(self.path("attachments")) + os.sep))

    def test_12_a_type_that_is_not_a_type(self):
        row = with_attachments(
            "guid-att-junk", CHAT_A_GUID, "no type at all", 503,
            [{"n": 0, "filename": "mystery", "mime_type": None,
              "total_bytes": 40, "missing": False}])
        status, _ = self.call("POST", "/v1/messages/ingest",
                              {"protocol": 1, "events": [row], "cursor": 503})
        self.assertEqual(status, 200)
        status, doc = self.upload(row["key"], 0, b"forty bytes of nothing much",
                                  name="mystery",
                                  ctype="not a media type at all")
        self.assertEqual(status, 200, doc)
        self.assertTrue(os.path.isfile(
            self.path("attachments", row["key"], "0.bin")))
        _, _, headers = self.raw(
            "GET", f"/v1/messages/attachment/{row['key']}/0")
        self.assertEqual(headers["Content-Type"], "application/octet-stream")

    def test_13_the_refusals_around_the_route(self):
        status, _ = self.upload(self.key, 0, PHOTO, name="x.png",
                                ctype="image/png", token=None)
        self.assertEqual(status, 401)

        status, doc = self.upload(self.key, 0, PHOTO, name="x.png",
                                  ctype="image/png", protocol="2")
        self.assertEqual(status, 400)
        self.assertEqual(doc, {"error": "protocol"})

        status, doc = self.upload(self.key, 0, b"", name="x.png",
                                  ctype="image/png")
        self.assertEqual(status, 400)
        self.assertEqual(doc["error"], "empty body")

        # A body that stops before it said it would is a truncated upload, not
        # a short file.
        status, doc = self.upload(self.key, 0, PHOTO[:100], name="x.png",
                                  ctype="image/png", claim=len(PHOTO),
                                  cut=True)
        self.assertEqual(status, 400)
        self.assertIn("ended early", doc["error"])

        # PUT is still refused everywhere else.
        status, raw, _ = self.raw("PUT", "/v1/messages/nope", b"{}")
        self.assertEqual(status, 405)

        status, doc = self.call("GET",
                                "/v1/messages/attachments?status=sent")
        self.assertEqual(status, 400)
        self.assertIn("wanted", doc["error"])


if __name__ == "__main__":
    unittest.main()
