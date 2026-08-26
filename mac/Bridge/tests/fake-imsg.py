#!/usr/bin/env python3
"""A stand-in for the imsg helper, speaking the same JSON-RPC over stdio.

It answers only the methods the Bridge is allowed to call, and after a
subscribe it streams three rows: a tapback, one message in an allowlisted
chat, and one in a chat that is not allowlisted. That is enough to prove the
whole upstream path -- what is kept, what is dropped, and where the cursor
ends up -- without going anywhere near a real Messages database.

Rowids are 101, 102, 103 and the good one is 102 on purpose: the cursor has to
end at 103, the newest row seen, not at the newest row sent.

`messages.after` serves the allowlisted chat's history as two pages, rowids 41
to 45, below everything the stream carries. Page one ends with has_more, page
two ends the history, and one of the five rows is a tapback the Bridge is
expected to drop on its own: the request asks for include_reactions false, and
a helper that ignored that must not turn into an event here either.

The kept row carries two attachments and two real files behind them: a small
PNG, which the Bridge is supposed to upload the moment the ingest is acked, and
a QuickTime clip, which it is supposed to leave alone until somebody asks for
it. The files are written into CHARON_FAKE_IMSG_FILES so a run can be sure the
bytes that arrive on the far end are the bytes that were on this disk.
"""
import json
import os
import sys
import tempfile
import threading
import time

ALLOWED_GUID = "iMessage;-;+14085550142"
OTHER_GUID = "iMessage;+;chat8291"

OUT = threading.Lock()


def mark_started():
    """One line per process, in the file CHARON_FAKE_IMSG_MARKER names.

    How the dry run counts children. The Bridge is supposed to run exactly one
    helper: the watcher and the history reader share it, and both of them ask
    the supervisor for a session at about the same moment on a cold start. When
    that ask was not single-flight, both got one, and the only visible sign was
    two "helper started" lines in the same millisecond -- which is a log line
    somebody has to notice. A file with two lines in it is a failing test.

    Appended with O_APPEND in one write, so two processes racing here cannot
    interleave into one line and undercount themselves.
    """
    path = os.environ.get("CHARON_FAKE_IMSG_MARKER", "")
    if not path:
        return
    line = f"{os.getpid()} {time.time():.6f}\n".encode()
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    except OSError:
        return
    try:
        os.write(fd, line)
    finally:
        os.close(fd)


def emit(document):
    line = json.dumps(document, separators=(",", ":"))
    with OUT:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def reply(rid, result):
    emit({"jsonrpc": "2.0", "id": rid, "result": result})


def fail(rid, code, message, data=None):
    error = {"code": code, "message": message}
    if data is not None:
        error["data"] = data
    emit({"jsonrpc": "2.0", "id": rid, "error": error})


# The two files the kept row points at. Real files, because the whole point of
# the upload path is that it reads a disk: a fixture that only described them
# would prove the JSON and nothing else.
FILES = os.environ.get("CHARON_FAKE_IMSG_FILES") or tempfile.mkdtemp(
    prefix="fake-imsg-files-")


def lay_out_files():
    os.makedirs(FILES, exist_ok=True)
    photo = os.path.join(FILES, "IMG_0412.png")
    clip = os.path.join(FILES, "IMG_0413.mov")
    with open(photo, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n"
                     + b"one photograph, near enough for a test. " * 400)
    with open(clip, "wb") as handle:
        handle.write(b"\x00\x00\x00\x18ftypqt  "
                     + b"twelve seconds of something. " * 900)
    return photo, clip


PHOTO_PATH, CLIP_PATH = lay_out_files()

# Position 0 is an image under the Bridge's own ten-megabyte ceiling, so it
# goes without being asked. Position 1 is a video, so it does not, however
# small the file behind it happens to be. Section 7.
ATTACHED = [
    {"filename": "IMG_0412.png", "transfer_name": "IMG_0412.png",
     "uti": "public.png", "mime_type": "image/png",
     "total_bytes": os.path.getsize(PHOTO_PATH), "is_sticker": False,
     "missing": False, "original_path": PHOTO_PATH},
    {"filename": "IMG_0413.mov", "transfer_name": "IMG_0413.mov",
     "uti": "com.apple.quicktime-movie", "mime_type": "video/quicktime",
     "total_bytes": os.path.getsize(CLIP_PATH), "is_sticker": False,
     "missing": False, "original_path": CLIP_PATH},
]

CHATS = [
    {
        "id": 7,
        "name": "Nadia Sorin",
        "display_name": "",
        "contact_name": "Nadia Sorin",
        "identifier": "+14085550142",
        "guid": ALLOWED_GUID,
        "service": "iMessage",
        "last_message_at": "2026-08-21T21:02:11Z",
        "is_group": False,
        "participants": ["+14085550142"],
        "unread_count": 1,
    },
    {
        "id": 12,
        "name": "Roommates",
        "display_name": "Roommates",
        "identifier": "chat8291",
        "guid": OTHER_GUID,
        "service": "iMessage",
        "last_message_at": "2026-08-21T20:41:03Z",
        "is_group": True,
        "participants": ["+14085550188", "+14085550199"],
        "unread_count": 0,
    },
]


def row(rowid, guid, chat, text, **extra):
    message = {
        "id": rowid,
        "chat_id": 7 if chat == ALLOWED_GUID else 12,
        "chat_identifier": "+14085550142" if chat == ALLOWED_GUID else "chat8291",
        "chat_guid": chat,
        "chat_name": "Nadia Sorin" if chat == ALLOWED_GUID else "Roommates",
        "participants": ["+14085550142"] if chat == ALLOWED_GUID else ["+14085550188"],
        "is_group": chat != ALLOWED_GUID,
        "guid": guid,
        "sender": "+14085550142" if chat == ALLOWED_GUID else "+14085550188",
        "sender_name": "Nadia Sorin" if chat == ALLOWED_GUID else "Corin Blake",
        "is_from_me": False,
        "text": text,
        "created_at": "2026-08-21T21:02:11.120Z",
        "attachments": [],
        "is_read": False,
    }
    message.update(extra)
    return message


STREAM = [
    row(101, "5B0A9E5C-1111-4A00-9E11-000000000101", ALLOWED_GUID,
        "Loved “are we still on for 6?”",
        is_reaction=True, reaction_type="love", is_reaction_add=True,
        reacted_to_guid="5B0A9E5C-1111-4A00-9E11-000000000102"),
    row(102, "5B0A9E5C-1111-4A00-9E11-000000000102", ALLOWED_GUID,
        "are we still on for 6? I can grab the table",
        attachments=ATTACHED),
    row(103, "5B0A9E5C-1111-4A00-9E11-000000000103", OTHER_GUID,
        "who has the dog tonight"),
]

# The allowlisted chat's history, in the two pages messages.after hands out.
# Rowid 42 is a tapback, so four of the five rows are events.
HISTORY = {
    0: {
        "messages": [
            row(41, "5B0A9E5C-1111-4A00-9E11-000000000041", ALLOWED_GUID,
                "did you ever move the reservation",
                created_at="2026-06-02T18:14:00.000Z"),
            row(42, "5B0A9E5C-1111-4A00-9E11-000000000042", ALLOWED_GUID,
                "Laughed at “did you ever move the reservation”",
                created_at="2026-06-02T18:15:00.000Z",
                is_reaction=True, reaction_type="laugh", is_reaction_add=True,
                reacted_to_guid="5B0A9E5C-1111-4A00-9E11-000000000041"),
            row(43, "5B0A9E5C-1111-4A00-9E11-000000000043", ALLOWED_GUID,
                "found it, seven thirty",
                created_at="2026-06-02T18:16:00.000Z"),
        ],
        "next_rowid": 43,
        "has_more": True,
    },
    43: {
        "messages": [
            row(44, "5B0A9E5C-1111-4A00-9E11-000000000044", ALLOWED_GUID,
                "the corner table if they have it",
                created_at="2026-07-11T01:20:00.000Z"),
            row(45, "5B0A9E5C-1111-4A00-9E11-000000000045", ALLOWED_GUID,
                "see you then",
                created_at="2026-07-11T01:21:00.000Z"),
        ],
        "next_rowid": 45,
        "has_more": False,
    },
}


def stream(subscription):
    time.sleep(0.4)
    for message in STREAM:
        emit({"jsonrpc": "2.0", "method": "message",
              "params": {"subscription": subscription, "message": message}})
        time.sleep(0.05)


def main():
    mark_started()
    subscription = 0
    for line in iter(sys.stdin.readline, ""):
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except ValueError:
            emit({"jsonrpc": "2.0", "id": None,
                  "error": {"code": -32700, "message": "Parse error"}})
            continue

        rid = request.get("id")
        method = request.get("method")
        params = request.get("params") or {}

        if method in ("initialize", "status"):
            reply(rid, {
                "version": "0.14.1",
                "protocol_version": 1,
                "database": {"path": "/tmp/fake/chat.db", "ready": True,
                             "features": {"unread_state": True, "reactions": True}},
                "bridge": {"ready": False, "error": "not started"},
                "contacts": {"available": True},
                "methods": ["initialize", "status", "chats.list", "watch.subscribe",
                            "watch.unsubscribe", "messages.after", "send",
                            "message.send_status"],
            })
        elif method == "chats.list":
            reply(rid, {"chats": CHATS[: params.get("limit", 20)]})
        elif method == "watch.subscribe":
            subscription += 1
            reply(rid, {"subscription": subscription, "buffer_limit": 256})
            threading.Thread(target=stream, args=(subscription,), daemon=True).start()
        elif method == "watch.unsubscribe":
            reply(rid, {"ok": True})
        elif method == "messages.after":
            since = params.get("since_rowid", 0)
            page = HISTORY.get(since) if params.get("chat_id") == 7 else None
            if page is None:
                # Every other cursor, and the whole-database form the watcher
                # uses after an overflow: nothing to catch up on.
                reply(rid, {"messages": [], "next_rowid": since,
                            "has_more": False})
            else:
                reply(rid, page)
        elif method == "send":
            if "chat_guid" not in params or "text" not in params:
                fail(rid, -32602, "Invalid params")
            else:
                reply(rid, {"ok": True, "transport": "applescript", "id": 1979,
                            "guid": "8DF00000-0000-4000-8000-00000000ABCD"})
        elif method == "message.send_status":
            reply(rid, {"ok": True, "guid": params.get("guid"), "send_state": "delivered"})
        elif rid is not None:
            fail(rid, -32601, "Method not found")


if __name__ == "__main__":
    main()
