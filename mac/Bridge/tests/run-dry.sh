#!/bin/bash
# The whole Bridge, driven end to end against a fake helper and a stub
# collector, with nothing real touched: no Messages database, no Apple events,
# no download, no login item, and a temporary Application Support directory
# that is thrown away at the end.
#
#   Bridge/tests/run-dry.sh
#
# Build first: xcodegen generate && xcodebuild -scheme CharonBridge ... build

set -u

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
app="$root/DerivedData/Build/Products/Debug/Charon Bridge.app/Contents/MacOS/Charon Bridge"

if [ ! -x "$app" ]; then
  echo "FAIL: no build at $app"
  exit 1
fi

work=$(mktemp -d /tmp/charon-bridge-dry.XXXXXX)
record="$work/record.json"
token="dry-run-token"

python3 "$here/stub_collector.py" --record "$record" --token "$token" &
stub=$!
trap 'kill $stub 2>/dev/null; wait $stub 2>/dev/null' EXIT

for _ in $(seq 1 60); do
  [ -s "$record.port" ] && break
  sleep 0.1
done
if [ ! -s "$record.port" ]; then
  echo "FAIL: the stub collector never came up"
  exit 1
fi
port=$(cat "$record.port")
echo "stub collector on 127.0.0.1:$port"
echo "bridge home $work/home"

CHARON_IMSG_PATH="$here/fake-imsg.py" \
CHARON_COLLECTOR_URL="http://127.0.0.1:$port" \
CHARON_COLLECTOR_TOKEN="$token" \
CHARON_BRIDGE_HOME="$work/home" \
CHARON_FAKE_IMSG_MARKER="$work/helper-starts.txt" \
CHARON_FAKE_IMSG_FILES="$work/files" \
  "$app" --dry-run --exit-after 14 --log-level debug \
  >"$work/stdout.txt" 2>"$work/stderr.txt"
status=$?
echo "bridge exited $status"

kill $stub 2>/dev/null
wait $stub 2>/dev/null

python3 - "$record" "$work/home" "$work/stdout.txt" "$work/helper-starts.txt" \
  "$work/stderr.txt" "$work/files" <<'PY'
import hashlib
import json
import os
import sys

record = json.load(open(sys.argv[1]))
home = sys.argv[2]
trace = open(sys.argv[3]).read().splitlines()
starts = sys.argv[4]
diary = open(sys.argv[5]).read().splitlines()
files = sys.argv[6]
failures = []


def check(name, condition, detail=""):
    print(("PASS  " if condition else "FAIL  ") + name + (f"  [{detail}]" if detail else ""))
    if not condition:
        failures.append(name)


posts = lambda path: [r for r in record if r.get("path") == path and r.get("method") == "POST"]

ingests = posts("/v1/messages/ingest")
live = [r for r in ingests if not r.get("backfill")]
history = [r for r in ingests if r.get("backfill")]

check("exactly one live ingest", len(live) == 1, f"{len(live)} seen")
if live:
    body = live[0]["body"]
    events = body.get("events", [])
    check("the ingest carries protocol 1", body.get("protocol") == 1)
    check("exactly one event", len(events) == 1, f"{len(events)} events")
    if events:
        event = events[0]
        check("it is the allowlisted row", event.get("rowid") == 102, str(event.get("rowid")))
        check("its key is sha256(guid)[:16]", event.get("key") == "ea7b6b628ef7db77",
              str(event.get("key")))
        check("its chat key is sha256(chat_guid)[:16]",
              event.get("chat_key") == "a3ce320ae80d4efe", str(event.get("chat_key")))
        check("it carries the service the row does not",
              event.get("service") == "iMessage", str(event.get("service")))
    check("the cursor is the highest rowid streamed", body.get("cursor") == 103,
          str(body.get("cursor")))
    if events:
        listed = events[0].get("attachments") or []
        check("the event carries both attachments", len(listed) == 2,
              str(len(listed)))
        check("numbered by where they are",
              [a.get("n") for a in listed] == [0, 1],
              str([a.get("n") for a in listed]))
        check("with the type and the size the row gave them",
              [a.get("mime_type") for a in listed]
              == ["image/png", "video/quicktime"],
              str([a.get("mime_type") for a in listed]))
        check("and no path off this Mac on any of them",
              all("original_path" not in a for a in listed),
              str(listed))
    check("and the stream is not marked as history", body.get("backfill") in (None, False),
          str(body.get("backfill")))

# The history: two pages, the tapback in the middle of the first one dropped
# here rather than by the helper, and nothing of it in the live cursor.
check("one history ingest per page", len(history) == 2, f"{len(history)} seen")
rows = [e.get("rowid") for r in history for e in r["body"].get("events", [])]
check("they cover both pages and skip the tapback", rows == [41, 43, 44, 45], str(rows))
check("each says what it is", all(r["body"].get("backfill") is True for r in history))
check("each names the protocol", all(r["body"].get("protocol") == 1 for r in history))
check("none carries more than a hundred events",
      all(len(r["body"].get("events", [])) <= 100 for r in history))
check("each carries the live cursor as it stood, moving nothing",
      all(r["body"].get("cursor") in (None, 103) for r in history),
      str([r["body"].get("cursor") for r in history]))
check("history rows are the allowlisted chat's",
      all(e.get("chat_key") == "a3ce320ae80d4efe"
          for r in history for e in r["body"].get("events", [])))

# The bytes. The photograph goes on its own the moment the ingest is acked;
# the video does not go at all until the far end asks for it, which this stub
# does the moment the photograph lands. Section 7, both halves of it.
puts = [r for r in record if r.get("method") == "PUT"]
photo = next((r for r in puts if r.get("n") == 0), None)
clip = next((r for r in puts if r.get("n") == 1), None)

check("two attachments were uploaded", len(puts) == 2,
      str([r.get("path") for r in puts]))
check("the photograph went first", bool(puts) and puts[0].get("n") == 0,
      str(puts[0].get("n") if puts else None))

if photo:
    on_disk = os.path.join(files, "IMG_0412.png")
    want = hashlib.sha256(open(on_disk, "rb").read()).hexdigest()
    head = photo["headers"]
    check("the photograph arrived whole", photo["sha256"] == want,
          f'{photo["sha256"]} vs {want}')
    check("and the digest it claimed is the digest it sent",
          head.get("x-charon-sha256") == photo["sha256"],
          str(head.get("x-charon-sha256")))
    check("it carries its own type", head.get("content-type") == "image/png",
          str(head.get("content-type")))
    check("its name, rebuilt from a safe alphabet",
          head.get("x-charon-filename") == "IMG_0412.png",
          str(head.get("x-charon-filename")))
    check("and the protocol it speaks", head.get("x-charon-protocol") == "1",
          str(head.get("x-charon-protocol")))
    check("the length it declared is the length that arrived",
          photo["bytes"] == photo["declared"] == os.path.getsize(on_disk),
          f'{photo["bytes"]} / {photo["declared"]}')

offers = [r for r in record
          if r.get("path", "").startswith("/v1/messages/attachments")]
asked = [r for r in offers if r.get("offered")]
check("the wanted list is polled", bool(offers), f"{len(offers)} polls")
check("and the video was asked for before it went", bool(asked),
      f"{len(asked)} offers")
if clip and asked:
    check("the video went only after it was asked for",
          record.index(asked[0]) < record.index(clip))
    on_disk = os.path.join(files, "IMG_0413.mov")
    want = hashlib.sha256(open(on_disk, "rb").read()).hexdigest()
    check("and arrived whole too", clip["sha256"] == want,
          f'{clip["sha256"]} vs {want}')
    check("with the type the row gave it",
          clip["headers"].get("content-type") == "video/quicktime",
          str(clip["headers"].get("content-type")))
check("nothing of the history was uploaded", len(puts) == 2,
      str([r.get("key") for r in puts]))

try:
    seen = json.load(open(home + "/attachments-seen.json"))
except OSError:
    seen = {}
check("the paths of what was forwarded are remembered",
      bool(seen.get("paths")), str(list(seen.get("paths") or {})))
check("and they are the files on this disk",
      all(path.startswith(files) for row in (seen.get("paths") or {}).values()
          for path in row if path),
      str(seen.get("paths")))

beats = posts("/v1/messages/bridge")
check("at least one heartbeat", len(beats) >= 1, f"{len(beats)} seen")
check("a heartbeat says fda: true", any(b["body"].get("fda") is True for b in beats))
check("a heartbeat counts the dropped chat",
      any(b["body"].get("dropped_not_allowlisted", 0) >= 1 for b in beats))
check("the heartbeat names the helper it would run",
      all(b["body"]["helper"]["version"] == "0.14.1" for b in beats))
check("a heartbeat says whether Contacts is granted",
      any(isinstance(b["body"].get("contacts"), bool) for b in beats),
      str([b["body"].get("contacts") for b in beats][:3]))
progress = [b["body"]["backfill"] for b in beats
            if isinstance(b["body"].get("backfill"), dict)]
check("a heartbeat carries the backfill's progress", bool(progress))
counts = [b["body"]["attachments"] for b in beats
          if isinstance(b["body"].get("attachments"), dict)]
check("a heartbeat counts the uploads", bool(counts))
check("and one of them has both files up with nothing refused",
      any(c.get("uploaded") == 2 and c.get("failed") == 0 for c in counts),
      str(counts[-1] if counts else None))
check("and one of them has the chat done with its rows counted",
      any(p.get("pending") == 0 and p.get("done") == 1 and p.get("rows") == 4
          for p in progress), str(progress[-1] if progress else None))

chats = posts("/v1/messages/chats")
check("one chats post", len(chats) == 1, f"{len(chats)} seen")
if chats:
    listed = chats[0]["body"].get("chats", [])
    check("with both chats", len(listed) == 2)
    by_key = {row.get("chat_key"): row for row in listed}
    nadia = by_key.get("a3ce320ae80d4efe", {})
    check("the chat record carries the Contacts name",
          nadia.get("contact_name") == "Nadia Sorin", str(nadia.get("contact_name")))
    check("and is named by it when there is no title",
          nadia.get("name") == "Nadia Sorin", str(nadia.get("name")))
    group = by_key.get("6c281cb5620022c7", {})
    check("a group is named by its own title",
          group.get("name") == "Roommates", str(group.get("name")))
    check("and carries no contact name", group.get("contact_name") is None,
          str(group.get("contact_name")))

reports = [r for r in record if r.get("path", "").startswith("/v1/messages/outbox/")]
check("one outbox report", len(reports) == 1, f"{len(reports)} seen")
if reports:
    check("for the item that was served",
          reports[0]["path"] == "/v1/messages/outbox/a1b2c3d4e5f60718", reports[0]["path"])
    check("reported sent", reports[0]["body"].get("status") == "sent",
          str(reports[0]["body"]))
    check("with the guid the helper returned",
          reports[0]["body"].get("guid") == "8DF00000-0000-4000-8000-00000000ABCD")

try:
    state = json.load(open(home + "/state.json"))
except OSError:
    state = {}
check("state.json holds the acked cursor", state.get("cursor") == 103, str(state.get("cursor")))

marks = state.get("backfill") or {}
mark = marks.get("iMessage;-;+14085550142") or {}
check("state.json keeps the mark under the chat's own guid", bool(mark), str(list(marks)))
check("the chat's history is done", mark.get("done") is True, str(mark.get("done")))
check("with every row it sent counted", mark.get("count") == 4, str(mark.get("count")))
check("and the helper's cursor to resume from", mark.get("rowid") == 45,
      str(mark.get("rowid")))
check("the mark says when it finished", isinstance(mark.get("at"), str), str(mark.get("at")))

# One child, however many things asked for one. The watcher and the history
# reader both call the supervisor within milliseconds of the start, and before
# the ask was single-flight both of them got a helper of their own: two `imsg
# rpc` processes on the same database, two watch subscriptions, and one line in
# the log to say so. The pid marker is the count.
try:
    children = [line for line in open(starts).read().splitlines() if line.strip()]
except OSError:
    children = []
check("the helper was spawned exactly once", len(children) == 1,
      f"{len(children)} started: {children}")
said = [line for line in diary if "helper started" in line]
check("and the log says so once", len(said) == 1, f"{len(said)} lines")

everything = json.dumps(record)
check("nothing from the chat that is not allowlisted left the Mac",
      "who has the dog tonight" not in everything and "chat8291" not in
      json.dumps([r for r in record if r.get("path") == "/v1/messages/ingest"]))
check("no request was refused for its token",
      not [r for r in record if r.get("unauthorised")])
check("the dry run traced its requests", len([t for t in trace if '"would"' in t]) >= 4,
      f"{len(trace)} lines")
check("the trace carries no message text",
      "are we still on for 6" not in "\n".join(trace))
check("the trace names an upload by its size and not its bytes",
      any('"PUT"' in line and '"bytes"' in line for line in trace),
      str([line for line in trace if '"PUT"' in line][:1]))
check("and nothing anywhere on stdout or in the log names a home directory",
      "/Users/" not in "\n".join(trace) + "\n".join(diary))

print()
print(f"{len(record)} requests recorded, {len(failures)} failures")
sys.exit(1 if failures else 0)
PY
result=$?

if [ $result -eq 0 ]; then
  rm -rf "$work"
else
  echo "kept $work for the postmortem"
fi
exit $result
