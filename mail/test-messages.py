#!/usr/bin/env python3
"""Offline test for the MESSAGES pipeline. No model, no network, no cost.

Runs the REAL worker against a throwaway store with a FakeLLM screwed into
llm.run_session, and checks the parts that a deploy cannot check for you:

    the store layout and the key derivation both halves of the wire share
    the allowlist validator, which is a security control and not a formality
    every cleaner, against a model that lies in all four fields at once
    the summary validator, against oversize lists and invented conversations
    that a drain writes verdicts, drafts and summaries AND NOTHING ELSE
      (the whole store is walked before and after and the diff is checked)
    that a past day is frozen: no call, no rewrite, entry dropped
    the four invariant greps that hold the model out of the send path

The FakeLLM is deliberately a LIAR. It answers about a message it was never
shown, invents a tag, returns an urgency of nine, spells a boolean as a word,
writes a summary twice the length it may be, files ten entries where eight are
allowed, and names a conversation that does not exist. Every one of those is a
thing the code below has to survive, and the happy path proves none of them.

    python3 test-messages.py

CHARON_MAIL_BASE is set by this file before msglib is imported, because the
store's paths are module constants: they bind at import time, which is exactly
what makes them safe to read by name in three programs.
"""

import json
import os
import re
import shutil
import sys
import tempfile
from datetime import datetime, timedelta, timezone

REPO = os.path.dirname(os.path.abspath(__file__))

# Before any import that reads it. See the module docstring.
BASE = tempfile.mkdtemp(prefix="charon-messages-test-")
os.environ["CHARON_MAIL_BASE"] = BASE
sys.path.insert(0, REPO)

import msglib  # noqa: E402

STORE = msglib.MESSAGES_DIR

# Two conversations and one that is only ever mentioned by a lying model.
CHAT_A_GUID = "iMessage;-;+14085550142"
CHAT_B_GUID = "iMessage;+;chat829173645"
CHAT_A = msglib.chat_key(CHAT_A_GUID)
CHAT_B = msglib.chat_key(CHAT_B_GUID)
GHOST_CHAT = "ffffffffffffffff"

MODEL = "stub-model-v1"

ok = fail = 0
calls = []


def check(passed, label, detail=""):
    global ok, fail
    if passed:
        ok += 1
        print(f"  ok    {label}")
    else:
        fail += 1
        print(f"  FAIL  {label}" + (f": {detail}" if detail else ""))


# -- the liar -----------------------------------------------------------------

def fake_run_session(prompt, tier, timeout_s, cwd=None):
    """Canned, correctly fenced, and wrong in every field it is allowed to be."""
    calls.append({"tier": tier, "cwd": cwd, "prompt": prompt})

    if "<<<BEGIN MESSAGE" in prompt:
        keys = re.findall(r"^key: ([0-9a-f]{16})$", prompt, re.MULTILINE)
        blocks = []
        for i, key in enumerate(keys):
            blocks.append(f"<<<MSG {key}>>>" + json.dumps({
                "tags": ["plans", "definitely-not-allowed", "PLANS", "money",
                         "work", "school", "family"],
                "urgency": 9 if i == 0 else "2",
                "needs_you": "yes" if i == 0 else 0,
                "summary": "x" * 400,
            }) + f"<<<END {key}>>>")
        # A verdict for a message this batch never contained.
        blocks.append(f"<<<MSG {'a' * 16}>>>" + json.dumps(
            {"tags": ["urgent"], "urgency": 3, "needs_you": True,
             "summary": "ghost"}) + f"<<<END {'a' * 16}>>>")
        return "here you go\n\n" + "\n\n".join(blocks) + "\n\nchatter", None, MODEL

    if "<<<BEGIN DAY>>>" in prompt:
        items = [{"chat_key": CHAT_A, "chat": "Nadia Sorin",
                  "line": "y" * 400}]
        items += [{"chat_key": CHAT_B, "chat": "Roommates",
                   "line": f"line {n}"} for n in range(10)]
        items.append({"chat_key": GHOST_CHAT, "chat": "Nobody",
                      "line": "a conversation that does not exist"})
        return ("<<<SUMMARY>>>\n" + json.dumps({
            "needs_you": items,
            "noticed": [{"chat_key": GHOST_CHAT, "chat": "Nobody",
                         "line": "still does not exist"}],
            "quiet": "not even a list",
            "prose": "  Quiet   day\n apart from dinner.  ",
        }) + "\n<<<END>>>"), None, MODEL

    return "<<<REPLY>>>\nyeah 6 still works, grab the table\n<<<END>>>", None, MODEL


# -- fixtures -----------------------------------------------------------------

def seed_message(guid, chat_guid, sender, text, is_from_me=False, when=None):
    """One index record and one body, exactly as the collector writes them."""
    key = msglib.msg_key(guid)
    chat = msglib.chat_key(chat_guid)
    when = when or datetime.now(timezone.utc)
    record = {
        "key": key, "guid": guid, "rowid": abs(hash(guid)) % 100000,
        "chat_guid": chat_guid, "chat_key": chat,
        "chat_identifier": "+14085550142",
        "chat_name": "Nadia Sorin" if chat == CHAT_A else "Roommates",
        "is_group": chat == CHAT_B, "service": "iMessage",
        "participants": ["+14085550142"],
        "sender": None if is_from_me else "+14085550142",
        "sender_name": None if is_from_me else "Nadia Sorin",
        "is_from_me": is_from_me,
        "created_at": when.isoformat(timespec="milliseconds").replace(
            "+00:00", "Z"),
        "attachments": [], "indexed_at": msglib.stamp(),
        "unread": not is_from_me, "body_chars": len(text),
    }
    msglib.write_json(msglib.index_path(key), record)
    msglib.write_atomic(msglib.text_path(key), text)
    return key


def snapshot():
    """Every file under the store, as {relpath: (size, mtime_ns)}."""
    out = {}
    for root, _, names in os.walk(STORE):
        for name in names:
            path = os.path.join(root, name)
            try:
                stat = os.stat(path)
            except OSError:
                continue
            out[os.path.relpath(path, STORE)] = (stat.st_size, stat.st_mtime_ns)
    return out


# -- the sections -------------------------------------------------------------

def test_layout():
    print("\n1. the store layout")
    msglib.ensure_dirs()
    for name, path in (
            ("messages/", STORE), ("index/", msglib.INDEX_DIR),
            ("bodies/", msglib.BODIES_DIR), ("ai/", msglib.AI_DIR),
            ("drafts/", msglib.DRAFTS_DIR), ("outbox/", msglib.OUTBOX_DIR),
            ("summaries/", msglib.SUMMARIES_DIR), (".queue/", msglib.QUEUE_DIR),
            (".actions/", msglib.ACTIONS_DIR), (".read/", msglib.READ_DIR)):
        check(os.path.isdir(path), f"ensure_dirs made {name}")
    check(STORE.startswith(BASE),
          "the store honours CHARON_MAIL_BASE", STORE)
    for label, path in (("index_path", msglib.index_path("0" * 16)),
                        ("text_path", msglib.text_path("0" * 16)),
                        ("ai_path", msglib.ai_path("0" * 16)),
                        ("draft_path", msglib.draft_path("0" * 16)),
                        ("user_draft_path", msglib.user_draft_path("0" * 16)),
                        ("outbox_path", msglib.outbox_path("0" * 16)),
                        ("summary_path", msglib.summary_path("2026-08-21")),
                        ("read_path", msglib.read_path("0" * 16))):
        check(os.path.realpath(path).startswith(os.path.realpath(STORE) + os.sep),
              f"{label} stays inside the store", path)


def test_keys():
    print("\n2. key derivation, the rule both machines share")
    key = msglib.msg_key("ABCD-1234")
    check(re.fullmatch(r"[0-9a-f]{16}", key), "a message key is 16 lowercase hex",
          key)
    check(re.fullmatch(r"[0-9a-f]{16}", CHAT_A), "a chat key is 16 lowercase hex",
          CHAT_A)
    check(msglib.msg_key("ABCD-1234") == key, "the same guid hashes the same way")
    check(msglib.msg_key("ABCD-1235") != key, "a different guid hashes differently")
    check(msglib.chat_key(CHAT_A_GUID) == msglib.msg_key(CHAT_A_GUID),
          "one hash serves both kinds")
    check(CHAT_A != CHAT_B, "two conversations get two keys")


def test_dates():
    print("\n3. local dates")
    check(msglib.local_date("2026-08-21T21:02:11.120Z") is not None,
          "a UTC stamp with a Z parses")
    check(msglib.local_date("2026-08-21T09:00:00") == "2026-08-21",
          "a naive stamp is read as local")
    check(msglib.local_date("not a date") is None, "garbage is None")
    check(msglib.local_date(None) is None, "None is None")
    check(msglib.DATE_RE.fullmatch(msglib.today()) is not None,
          "today() is a filing date")


def test_config():
    print("\n4. the allowlist validator")
    good = {"chats": {CHAT_A_GUID: {"read": True, "send": "confirm",
                                    "name": "Nadia Sorin"}}}
    config, why = msglib.clean_config(good)
    check(why is None and config["chats"][CHAT_A_GUID]["send"] == "confirm",
          "a well formed config is accepted", str(why))
    check(config.get("updated_at"), "a config gets an updated_at")

    for label, doc in (
            ("a non-object", ["nope"]),
            ("a missing chats map", {"chats": "nope"}),
            ("an empty guid", {"chats": {"   ": {"read": True, "send": "off"}}}),
            ("a policy outside the vocabulary",
             {"chats": {CHAT_A_GUID: {"read": True, "send": "blast"}}}),
            ("a non-boolean read",
             {"chats": {CHAT_A_GUID: {"read": "yes", "send": "off"}}}),
            ("a name that is not a string",
             {"chats": {CHAT_A_GUID: {"read": True, "send": "off", "name": 7}}}),
            ("an oversize name",
             {"chats": {CHAT_A_GUID: {"read": True, "send": "off",
                                      "name": "n" * 200}}})):
        _, why = msglib.clean_config(doc)
        check(why is not None, f"{label} is refused", "accepted")

    msglib.save_config({"chats": {
        CHAT_A_GUID: {"read": True, "send": "confirm", "name": "Nadia Sorin"},
        CHAT_B_GUID: {"read": True, "send": "off", "name": "Roommates"},
    }})
    loaded = msglib.load_config()
    check(loaded["chats"][CHAT_A_GUID]["send"] == "confirm",
          "save_config round trips")
    check(msglib.allowlisted() == {CHAT_A_GUID, CHAT_B_GUID},
          "both conversations are allowlisted for reading")

    # A file that went strange must not stop the pipeline reading the rest.
    msglib.write_json(msglib.CONFIG_PATH, {"chats": {
        CHAT_A_GUID: {"read": True, "send": "sideways"},
        "": {"read": True, "send": "auto"},
        CHAT_B_GUID: "not an object",
    }})
    loose = msglib.load_config()
    check(loose["chats"][CHAT_A_GUID]["send"] == "off",
          "an unreadable policy reads as off", str(loose))
    check("" not in loose["chats"] and CHAT_B_GUID not in loose["chats"],
          "junk entries are dropped rather than fatal")

    # Put the real one back for the rest of the run.
    msglib.save_config({"chats": {
        CHAT_A_GUID: {"read": True, "send": "confirm", "name": "Nadia Sorin"},
        CHAT_B_GUID: {"read": True, "send": "off", "name": "Roommates"},
    }})


def test_cleaners(mt):
    print("\n5. the cleaners, against a model that lies")
    tags = mt.clean_tags(["plans", "definitely-not-allowed", "PLANS", "money",
                          "work", "school", "family"])
    check("definitely-not-allowed" not in tags, "an invented tag is dropped",
          str(tags))
    check(tags.count("plans") == 1, "a repeat spelled loudly is deduped",
          str(tags))
    check(len(tags) <= mt.TAGS_MAX, "at most four tags survive", str(tags))
    check(tags == ["plans", "money", "work", "school"],
          "the order the model offered them is kept", str(tags))
    check(mt.clean_tags("plans") == [], "a bare string is not a tag list")

    check(mt.clean_urgency(9) == 3, "urgency 9 clamps to 3")
    check(mt.clean_urgency(-2) == 0, "a negative urgency clamps to 0")
    check(mt.clean_urgency("2") == 2, "a numeric string is read")
    check(mt.clean_urgency(True) == 0, "a boolean is not an urgency")
    check(mt.clean_urgency("soon") == 0, "an unparseable urgency is 0")
    check(mt.clean_urgency(2.7) == 2, "a float truncates")

    check(mt.clean_bool(True) is True, "a real boolean survives")
    check(mt.clean_bool("yes") is True, "a spelled boolean is read")
    check(mt.clean_bool("no") is False, "a spelled negative is read")
    check(mt.clean_bool(1) is True, "1 is true")
    check(mt.clean_bool(0) is False, "0 is false")
    check(mt.clean_bool(None) is False, "a missing flag falls to false")
    check(mt.clean_bool({"maybe": 1}) is False, "an object is not a flag")

    long = mt.clean_summary("x" * 400)
    check(len(long) == mt.SUMMARY_CHARS, "a summary is clipped", str(len(long)))
    check(mt.clean_summary(["first", "second"]) == "first",
          "a list summary becomes its first line")
    check(mt.clean_summary("two   words\nover lines") == "two words over lines",
          "whitespace is collapsed to one line")
    check(mt.clean_summary(None) == "", "no summary is the empty string")


def test_summary_validator(mt):
    print("\n6. the summary validator")
    known = {CHAT_A, CHAT_B}
    items = [{"chat_key": CHAT_B, "chat": "Roommates", "line": f"line {n}"}
             for n in range(12)]
    check(len(mt.clean_items(items, known)) == mt.DAY_ITEMS_MAX,
          "an oversize list is clipped to eight")
    check(mt.clean_items([{"chat_key": GHOST_CHAT, "line": "nope"}], known) == [],
          "an entry naming no conversation is dropped")
    check(mt.clean_items([{"chat_key": CHAT_A, "line": "z" * 400}],
                         known)[0]["line"] == "z" * mt.DAY_LINE_CHARS,
          "a long line is clipped")
    check(mt.clean_items(["not an object"], known) == [],
          "a non-object entry is ignored")
    check(mt.clean_items("not a list", known) == [], "a non-list is ignored")
    check(mt.clean_items([{"chat_key": CHAT_A, "line": "   "}], known) == [],
          "an empty line is dropped")

    content, why = mt.clean_day({"needs_you": items, "noticed": [],
                                 "quiet": "junk", "prose": "  a   b "}, known)
    check(why is None, "a usable payload validates", str(why))
    check(content["quiet"] == [], "a list that is not a list becomes empty")
    check(content["prose"] == "a b", "prose is collapsed")
    _, why = mt.clean_day("not an object", known)
    check(why is not None, "a non-object payload is refused")


def test_drain(mt):
    print("\n7. the drain, with the liar wired in")
    now = datetime.now(timezone.utc)
    key_in_a = seed_message("guid-a-1", CHAT_A_GUID, "nadia",
                            "are we still on for 6?", when=now)
    key_in_b = seed_message("guid-b-1", CHAT_B_GUID, "roommate",
                            "rent is due friday", when=now)
    key_mine = seed_message("guid-a-2", CHAT_A_GUID, "me", "on my way",
                            is_from_me=True, when=now)

    # A day that is over and already answered. Nothing may touch it.
    frozen = (datetime.now() - timedelta(days=1)).date().isoformat()
    frozen_doc = {"date": frozen, "status": "ok", "needs_you": [],
                  "noticed": [], "quiet": [], "prose": "yesterday",
                  "model": "old-model", "at": "2026-08-20T09:00:00",
                  "read": True, "archived": False}
    msglib.write_json(msglib.summary_path(frozen), frozen_doc)

    # The collector's job, done by hand: inbound rows only.
    msglib.spool_add(msglib.QUEUE_DIR, f"triage-{key_in_a}")
    msglib.spool_add(msglib.QUEUE_DIR, f"triage-{key_in_b}")
    msglib.spool_add(msglib.QUEUE_DIR, f"draft-{CHAT_A}")
    msglib.spool_add(msglib.QUEUE_DIR, f"summary-{frozen}")
    # The day summary no longer enqueues itself after a triage batch (the console
    # dropped the block); the verb still runs when an entry is spooled by hand.
    today = datetime.now().date().isoformat()
    msglib.spool_add(msglib.QUEUE_DIR, f"summary-{today}")
    msglib.spool_add(msglib.QUEUE_DIR, "nonsense-entry")

    before = snapshot()
    mt.main()
    after = snapshot()

    verdict_a = msglib.read_json(msglib.ai_path(key_in_a)) or {}
    verdict_b = msglib.read_json(msglib.ai_path(key_in_b)) or {}
    check(verdict_a.get("status") == "ok", "the first message got a verdict",
          str(verdict_a.get("status")))
    check(verdict_b.get("status") == "ok", "the second message got a verdict",
          str(verdict_b.get("status")))
    check(verdict_a.get("model") == MODEL,
          "the record names the model that answered", str(verdict_a.get("model")))
    check(not os.path.exists(msglib.ai_path(key_mine)),
          "our own message was never triaged")
    check(not os.path.exists(msglib.ai_path("a" * 16)),
          "no verdict for a message the batch never held")
    check("definitely-not-allowed" not in (verdict_a.get("tags") or []),
          "the invented tag never reached disk", str(verdict_a.get("tags")))
    check(verdict_a.get("urgency") == 3, "urgency 9 landed as 3",
          str(verdict_a.get("urgency")))
    check(verdict_a.get("needs_you") is True, "a spelled boolean landed as one",
          str(verdict_a.get("needs_you")))
    check(verdict_b.get("needs_you") is False, "0 landed as false",
          str(verdict_b.get("needs_you")))
    check(len(verdict_a.get("summary") or "") <= mt.SUMMARY_CHARS,
          "the oversize summary was clipped on the way in")

    draft = msglib.read_json(msglib.draft_path(CHAT_A)) or {}
    check(draft.get("status") == "ready", "the draft is ready",
          str(draft.get("status")))
    check("6 still works" in (draft.get("text") or ""), "the draft holds the text",
          str(draft.get("text")))
    check(draft.get("chat_guid") == CHAT_A_GUID,
          "the draft names the real conversation guid", str(draft.get("chat_guid")))
    check(len(draft.get("text") or "") <= mt.DRAFT_CHARS, "the draft is bounded")

    today = msglib.today()
    summary = msglib.read_json(msglib.summary_path(today)) or {}
    check(summary.get("status") == "ok", "today's summary was written",
          str(summary.get("status")))
    check(len(summary.get("needs_you") or []) == mt.DAY_ITEMS_MAX,
          "the summary's oversize list was clipped",
          str(len(summary.get("needs_you") or [])))
    check(all(item["chat_key"] in (CHAT_A, CHAT_B)
              for item in summary.get("needs_you") or []),
          "the invented conversation was dropped")
    check(summary.get("noticed") == [],
          "a section that named only a ghost came out empty")
    check(summary.get("read") is False, "a new summary is unread")

    check(msglib.read_json(msglib.summary_path(frozen)) == frozen_doc,
          "the past day was not rewritten")
    check(not any("<<<BEGIN DAY>>>" in call["prompt"]
                  and frozen in call["prompt"].split("The local date is ")[-1][:10]
                  for call in calls),
          "the past day cost no model call")

    check(msglib.spooled(msglib.QUEUE_DIR) == [], "the queue drained",
          str(msglib.spooled(msglib.QUEUE_DIR)))

    tiers = [call["tier"] for call in calls]
    check(tiers.count("cheap") == 1, "one cheap call for the batch", str(tiers))
    check(tiers.count("good") == 2, "one good call each for draft and day",
          str(tiers))
    check(all(call["cwd"] == msglib.ENV_DIR for call in calls),
          "every session ran in the sandbox directory")

    print("\n8. the drain wrote nowhere else")
    allowed = ("ai/", "drafts/", "summaries/", ".queue/", ".triage.lock")
    touched = sorted(name for name, meta in after.items()
                     if before.get(name) != meta)
    gone = sorted(name for name in before if name not in after)
    stray = [name for name in touched + gone
             if not name.startswith(allowed)]
    check(not stray, "no file outside ai/ drafts/ summaries/ .queue/ changed",
          str(stray))
    check(all(before.get(name) == after.get(name) for name in before
              if name.startswith(("index/", "bodies/"))),
          "not one index record or body was touched")
    check("config.json" not in touched, "the allowlist was not touched")
    check(not any(name.startswith("outbox/") for name in touched + gone),
          "nothing was filed for sending")


def test_thread_index(mt):
    print("\n8b. the per-chat key index feeds the draft context")
    import json as _json
    chat = "ab" * 8
    os.makedirs(msglib.THREADS_DIR, exist_ok=True)
    keys = []
    for i in range(3):
        key = f"{i:016x}"
        keys.append(key)
        msglib.write_json(msglib.index_path(key), {
            "chat_key": chat, "chat_guid": "any;-;+15550001111",
            "sender_name": "T", "is_from_me": False, "is_group": False,
            "created_at": f"2026-08-2{i}T10:00:00Z"})
        with open(msglib.text_path(key), "w") as fh:
            fh.write(f"line {i}")
    with open(msglib.threads_path(chat), "w") as fh:
        for i, key in enumerate(keys):
            fh.write(_json.dumps({"key": key, "rowid": i,
                                  "at": f"2026-08-2{i}T10:00:00Z"}) + "\n")
        fh.write("not json\n")
        fh.write(_json.dumps({"key": keys[0], "rowid": 0,
                              "at": "2026-08-20T10:00:00Z"}) + "\n")
    got = msglib.thread_keys(chat)
    check(got == keys, "keys come back ordered and deduped", str(got))
    check(msglib.thread_keys("cd" * 8) is None,
          "an absent index is None, not an empty conversation")
    rows = mt.chat_records(chat)
    check([k for k, _ in rows] == keys,
          "chat_records follows the index, not the mtime window",
          str([k for k, _ in rows]))
    check(mt.chat_records("cd" * 8) == [],
          "a chat in no index and no window is empty")
    # A draft for a conversation with nothing in it fails out loud.
    ghost = "ef" * 8
    msglib.spool_add(msglib.QUEUE_DIR, f"draft-{ghost}")
    mt.drain()
    doc = msglib.read_json(msglib.draft_path(ghost)) or {}
    check(doc.get("status") == "failed"
          and doc.get("error") == "no messages in this conversation",
          "the empty draft wrote its failure", str(doc.get("status")))


def test_invariants():
    print("\n9. the invariants, as greps")
    path = os.path.join(REPO, "messages-triage.py")
    with open(path) as fh:
        text = fh.read()

    check(text.count("smtplib") == 0,
          "the worker names no mail transport [grep -c smtplib = 0]")
    check(len(re.findall(r"^(?:import|from) llm\b", text, re.M)) == 1,
          "the worker imports llm exactly once "
          "[grep -cE '^(import|from) llm\\b' = 1]")
    check(text.count("outbox") == 0,
          "the worker cannot even name the send store [grep -c outbox = 0]")
    banned = re.findall(r"^(?:import|from) (subprocess|socket|urllib)\b",
                        text, re.M)
    check(not banned, "the worker starts no process and opens no socket",
          str(banned))

    # The two workers allowed to run a model, and llm.py itself. Tests are
    # excluded because a test of the seam has to import the seam; what this
    # asserts is that no *worker* grew a model call, which is the property the
    # send path depends on.
    others = []
    for name in sorted(os.listdir(REPO)):
        if not name.endswith(".py") or name.startswith("test-"):
            continue
        if name in ("messages-triage.py", "mail-triage.py", "llm.py"):
            continue
        with open(os.path.join(REPO, name)) as fh:
            if re.search(r"^(?:import|from) llm\b", fh.read(), re.M):
                others.append(name)
    check(not others,
          "no other worker in the repo reaches a model", str(others))

    with open(os.path.join(REPO, "msglib.py")) as fh:
        lib = fh.read()
    check(not re.search(r"^(?:import|from) llm\b", lib, re.M),
          "msglib holds nothing model-shaped, so importing it is safe")


def main():
    print(f"store: {STORE}")
    try:
        # The prompts the worker reads live beside the mail ones. Copied rather
        # than pointed at, so a missing prompt file fails this test.
        os.makedirs(msglib.ENV_DIR, exist_ok=True)
        for name in ("messages-triage.md", "messages-reply.md",
                     "messages-summary.md"):
            src = os.path.join(REPO, "mail-env", name)
            if not os.path.exists(src):
                print(f"  FAIL  the prompt {name} is missing")
                return 1
            shutil.copy(src, os.path.join(msglib.ENV_DIR, name))

        import importlib.util
        spec = importlib.util.spec_from_file_location(
            "messages_triage", os.path.join(REPO, "messages-triage.py"))
        mt = importlib.util.module_from_spec(spec)
        sys.modules["messages_triage"] = mt
        spec.loader.exec_module(mt)
        # The seam, and the only thing stubbed anywhere in this file.
        mt.llm.run_session = fake_run_session

        test_layout()
        test_keys()
        test_dates()
        test_config()
        test_cleaners(mt)
        test_summary_validator(mt)
        test_drain(mt)
        test_thread_index(mt)
        test_invariants()

        print(f"\n{ok} passed, {fail} failed")
        return 1 if fail else 0
    finally:
        shutil.rmtree(BASE, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
