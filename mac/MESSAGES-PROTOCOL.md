# Charon Messages — the wire between the Mac and the Pi

Version `protocol: 1`. This is the whole contract between **Charon Bridge**
(a small background app on the Mac) and the **collector** (on the Pi 5). The
Charon app is a third party to it: it only ever talks to the collector, the
same way it does for mail. Design reference: the shipped Messages tab.

## 1. Roles

| who | where | does |
|---|---|---|
| **Bridge** | Mac, login item, no window | reads new Messages rows through the `imsg` CLI, keeps only allowlisted chats, pushes them to the collector; pulls queued sends and performs them through Messages.app, from the user's own number; reports a heartbeat |
| **Collector** | Pi, `collector.py` | stores messages under `charon-mail/messages/`, queues triage, serves chats/threads/summaries/drafts, holds the allowlist and the outbox |
| **Pipeline** | Pi, `charon-mail` | `messages-triage.py` reads the queue, writes verdicts, drafts and the daily summary; never sends anything |
| **App** | Mac, `Charon.app` (sandboxed) | shows the Messages tab; files a send as a request; edits the allowlist |

The Mac is never called. Everything is a Bridge→Pi or App→Pi request over
Tailscale. If the Mac is asleep the stream pauses and resumes from its cursor
when it wakes; nothing is lost, it arrives late.

## 2. Transport

- HTTP/1.1, `http://100.64.0.2:8788` (an example tailnet address; tailnet only, as today).
- `Authorization: Bearer <COLLECTOR_API_TOKEN>` on every request. The Bridge
  reads the token from the same Keychain item as the app.
- JSON bodies, UTF-8. Success `{"ok": true, ...}` or 204. Failure
  `{"error": "<short reason>"}` with 4xx/5xx.
- Every Bridge request carries `"protocol": 1`; the collector answers 400
  `{"error": "protocol"}` to a number it does not speak.
- Bodies cap: 512 KiB on ingest, 64 KiB elsewhere.

## 3. Identity

- **message key** `key` = `sha256(guid)[:16]`, 16 hex. `guid` is the Messages row GUID.
- **chat key** `chat_key` = `sha256(chat_guid)[:16]`, 16 hex. `chat_guid` is the
  Messages chat GUID, e.g. `iMessage;-;+14085550142`, or `iMessage;+;chat…` for a group.
- **outbox id** `id`, 16 hex, minted by the collector.
- Dates are ISO 8601 UTC with `Z`. Clients validate key shapes before building a
  URL (unknown paths return the console HTML with 200).

## 4. Records

**Event** (Bridge → collector, one per message row)
```json
{ "key": "…16hex", "guid": "…", "rowid": 184220,
  "chat_guid": "iMessage;-;+14085550142", "chat_key": "…16hex",
  "chat_identifier": "+14085550142", "chat_name": "Nadia Sorin", "is_group": false,
  "service": "iMessage", "participants": ["+14085550142"],
  "sender": "+14085550142", "sender_name": "Nadia Sorin", "is_from_me": false,
  "text": "are we still on for 6? I can grab the table", "created_at": "2026-08-21T21:02:11.120Z",
  "attachments": [ { "n": 0, "filename": "IMG_0412.heic", "mime_type": "image/heic", "total_bytes": 1820331, "missing": false } ] }
```
`text` ≤ 20 000 characters. Reactions (tapbacks) are not events.

**An attachment is metadata on this route and bytes on its own.** `n` is the
attachment's 0-based position in the row, and it is the whole of how the two
sides agree which file they are talking about: the event names it, the upload
carries it in the URL, and the app asks for it back by the same number.
`is_sticker` is optional and is only present when it is true. `original_path`
is not here and never will be: the Bridge keeps it to itself, because a path on
somebody's Mac is not a fact the Pi has any use for.

The index record the collector writes keeps the same list with one field added:
`stored`, which is this side saying whether it holds the bytes. The Bridge does
not send it and could not know it. It is false until an upload lands and true
afterwards, and a thread row carries it beside `n` so the app can tell a photo
it can draw from a photo it has to ask for.

**Chat** (Bridge → collector, the directory of conversations)
```json
{ "chat_guid": "…", "chat_key": "…", "chat_identifier": "…", "name": "Nadia Sorin",
  "contact_name": "Nadia Sorin",
  "is_group": false, "service": "iMessage", "participants": ["+14085550142"],
  "last_message_at": "2026-08-21T21:02:11Z" }
```
`name` falls back in this order: a group's own title, then the chat's display
name, then the Contacts match, then null. A raw phone number is never a name;
a conversation with nothing to go on arrives nameless and the console draws it
as the identifier. `contact_name` is optional and carries the Contacts match on
its own, so the Pi can tell a name the user typed from a name the address book
supplied. Both are absent when Contacts is not granted.

**Heartbeat** (Bridge → collector, every 30 s and on change)
```json
{ "protocol": 1, "version": "0.1.0", "host": "macbook",
  "helper": { "version": "0.14.1", "state": "verified|missing|mismatch" },
  "fda": true, "automation": true, "db_ok": true, "contacts": true,
  "cursor": 184220, "last_event_at": "2026-08-21T21:02:12Z",
  "dropped_not_allowlisted": 31, "last_error": null,
  "backfill": { "pending": 2, "done": 1, "rows": 1240 } }
```
`contacts` is whether this Mac has granted Contacts, reported the same way
`fda` and `automation` are: the Bridge says what it can do, it does not ask
here. `backfill` counts allowlisted chats still owed their history, chats whose
history is finished, and rows sent by the backfill in total. Both are optional
and are left out entirely when there is nothing to say, rather than sent as
null, so a collector that predates them sees the heartbeat it already knows.

**Config** (collector-owned, edited by the app, mirrored by the Bridge)
```json
{ "updated_at": "2026-08-21T21:00:00Z",
  "chats": { "iMessage;-;+14085550142": { "read": true, "send": "confirm", "name": "Nadia Sorin" },
             "iMessage;+;chat8291…":    { "read": true, "send": "off",     "name": "Roommates" } } }
```
`send` ∈ `off · confirm · auto`. v1 gives behaviour to `off` and `confirm` only;
`auto` is stored and shown, not acted on.

**Outbox item** (collector-owned)
```json
{ "id": "…16hex", "chat_key": "…", "chat_guid": "…", "body": "Yes, 6 works. …",
  "status": "queued|sent|failed", "at": "…", "sent_at": null,
  "guid": null, "message_id": null, "error": null, "disposition": null, "retry_safe": null }
```

## 5. Endpoints

### Bridge → collector
| method · path | body | reply |
|---|---|---|
| `POST /v1/messages/ingest` | `{protocol, events: [Event…] ≤100, cursor, backfill?}` | `{ok, stored, duplicates, cursor_ack}` |
| `POST /v1/messages/bridge` | Heartbeat | `{ok}` |
| `POST /v1/messages/chats` | `{protocol, chats: [Chat…]}` | `{ok, count}` |
| `GET  /v1/messages/config` | | Config |
| `GET  /v1/messages/outbox?status=queued` | | `{items: [Outbox…] ≤20, oldest first}` |
| `POST /v1/messages/outbox/<id>` | `{status: "sent", guid?, message_id?}` or `{status: "failed", error, disposition?, retry_safe?}` | `{ok}` |
| `PUT  /v1/messages/attachment/<key>/<n>` | the file's raw bytes | `{ok, bytes}` · 404 unknown message or attachment · 413 over the cap |
| `GET  /v1/messages/attachments?status=wanted` | | `{items: [{key, n, guid, rowid, chat_guid, filename, mime_type, total_bytes}] ≤20, oldest first}` |

### App → collector
| method · path | body | reply |
|---|---|---|
| `GET  /v1/telemetry` | | envelope `sources.messages` (§6) |
| `GET  /v1/messages/chats` | | `{chats: [Chat + config fields…]}` |
| `POST /v1/messages/config` | Config | `{ok}` |
| `GET  /v1/messages/thread/<chat_key>?limit=50&before=<key>` | | `{chat, messages: [Event + ai…] oldest→newest, draft, user_draft, outbox, read_to}`; `outbox` is this chat's own sends from the last 24 h (`{id, status, body, at, sent_at, guid, message_id, error, disposition}`, ≤ 20, newest last) |
| `POST /v1/messages/read` | `{chat_key}` | `{ok}` |
| `POST /v1/messages/draft` | `{chat_key, instructions?}` | `{ok, status}` |
| `POST /v1/messages/save-draft` | `{chat_key, body}` | `{ok}` |
| `POST /v1/messages/send` | `{chat_key, body ≤4000}` | `{ok, id}` · 404 unknown chat · 403 policy is `off` |
| `GET  /v1/messages/summary/<YYYY-MM-DD>` | | summary document |
| `POST /v1/messages/summary/read` · `/archive` | `{date}` | `{ok}` |
| `GET  /v1/messages/attachment/<key>/<n>` | | the bytes · 404 when they are not stored |
| `POST /v1/messages/attachment/<key>/<n>/want` | | `{ok}` |

**The upload** is the one request on this wire whose body is not JSON. It
carries the file and nothing else, and says what it is in headers rather than
around the bytes: `Content-Type` is the attachment's own mime type, or
`application/octet-stream` when the Mac could not name one; `X-Charon-Filename`
is the name the row gave it; `X-Charon-Protocol: 1` is §2's rule kept on a
route with nowhere in the body to put it; and `X-Charon-SHA256` is the hex
digest the Bridge computed while it read the file, which this side recomputes
while it writes. A digest that does not match is a 400 and nothing is kept.

It is **idempotent**. The same key and the same `n` sent twice is 200 both
times, and the second one does not rewrite the file when the digest matches
what is already there. That is what makes a retry free: a Bridge that uploaded
successfully and then lost the answer can send the bytes again without the
store noticing.

The collector keeps them at `messages/attachments/<key>/<n>.<ext>` with a
sidecar `<n>.json` holding `{filename, mime_type, bytes, sha256, at}`. The
extension comes from the sanitised filename, or from the mime type when the
name has none, or is `bin`. Landing an upload flips `stored: true` on that
attachment in the index record, rewritten atomically, and clears any pending
want for it.

**The download** answers with the stored `Content-Type`, `Content-Disposition:
attachment; filename="<safe>"`, `X-Content-Type-Options: nosniff` and
`Cache-Control: private, max-age=86400`. A day of cache is safe on this one
route and on no other here: the bytes under a key and an `n` are a file that
was sent once and cannot change, which is the opposite of every other read on
this channel.

**The want** is how the app asks for a file the Bridge did not send on its own.
It writes `messages/.wants/<key>-<n>.json` holding `{key, n, at}` and is
idempotent: asking twice is one file, and the second tap does not restart the
clock. The Bridge reads the list on its next poll, uploads what it can find,
and the upload clears the want. A want that nothing has answered in seven days
is dropped when the list is next read, because a file the Mac could not produce
in a week is a file the Mac does not have.

## 6. What the telemetry envelope carries (`sources.messages.data`)
```json
{ "bridge": { "seen_at": "…", "fda": true, "automation": true, "helper": "0.14.1 · verified",
              "cursor": 184220, "last_event_at": "…", "dropped": 31, "error": null },
  "counts": { "chats": 7, "unread": 4, "needs_you": 2, "queued": 0 },
  "chats": [ { "chat_key": "…", "chat_guid": "…", "name": "Nadia Sorin", "is_group": false, "service": "iMessage",
               "policy": "confirm", "read": true, "last_at": "…", "last_preview": "are we still on for 6? …",
               "last_sender": "Nadia Sorin", "unread": 1, "urgency_max": 2, "needs_you": true } ],
  "summaries": [ { "date": "2026-08-21", "status": "ok", "read": false, "archived": false,
                   "needs_you_n": 2, "preview": "Nadia wants a yes on dinner at 6; …", "at": "…" } ] }
```
Bodies never travel in telemetry; the thread route carries them. Health:
no heartbeat for 120 s → `degraded · bridge not reporting`; heartbeat with
`fda:false` or `helper` not verified → `degraded` with that reason; no store
yet → `dormant`.

## 7. Semantics that matter

**Upstream is at-least-once, deduped by key.** The Bridge keeps an in-memory
cursor while it streams and persists only the `cursor_ack` the collector
returns. A crash re-sends what was not acked; the collector ignores keys it
already holds. On first run the Bridge has no cursor and starts at "now":
enabling the channel never replays history.

**Allowing one chat backfills that chat.** When a conversation becomes
allowlisted (`read: true`), the Bridge reads its entire history once, in pages,
and stores it on the Pi as read and untriaged. The rows go to the same ingest
route with `backfill: true`, which is what tells the collector to mark them
read, to raise no triage entry for them, and to leave the cursor alone. The
live cursor is unaffected: a page of old rows says nothing about where the
present is, so the `cursor_ack` a history post comes back with is an echo of
what was sent and the Bridge never persists it. Progress is kept per chat and
written after every page, so a Bridge that stops halfway through a history
resumes from where it was rather than starting the conversation again. One
chat is read at a time and the pages share the helper with the live watch, so
turning on a nine-year thread slows the backfill, not the stream. A chat is
backfilled once; switching it off and on again does not do it a second time.

**The allowlist is enforced twice.** The Bridge drops rows from chats that are
not `read: true` before they leave the Mac (it counts them, it does not log
them). The collector refuses sends to chats whose policy is `off` or unknown.
The Bridge re-checks the same before performing a send.

**A send is one attempt, reported honestly.** The app files it; the collector
queues it; the Bridge performs it once and reports `sent` or `failed` with the
disposition it got. Nothing retries on its own. A failed item stays visible in
the thread for the user to resend by hand.

**Photos come on their own; everything else is asked for.** Right after the
ingest ack, the Bridge uploads every attachment of a **live** event whose mime
type starts with `image/`, whose `total_bytes` is at most 10 MiB and whose file
is not `missing`. Nothing else goes up by itself: not videos, not files, not a
bigger image, and not a single attachment of a backfilled history however small
it is. Those wait for a want, which is a person tapping `fetch` on a tile.

The rule is the same shape as the backfill's. A conversation switched on today
should not spend the evening pushing nine years of pictures up a home
connection, and a photo somebody just sent is the one the thread is about to
draw. The ceiling on the automatic half is the Bridge's own and is deliberately
below the wire's: 10 MiB is a photograph, and the 25 MiB the route accepts is
there for the video somebody actually asked to see.

**The bytes go to the Pi and nowhere else, and the Bridge never transcodes.**
A HEIC is uploaded as a HEIC; the Mac app decodes it, because the Mac app is
already a program that can. Converting on the way past would mean the store
holds something other than what was sent, which is a second copy of somebody's
photograph with our fingerprints on it.

**One attempt per poll cycle, with the watcher's backoff.** An upload that
fails leaves `stored: false` and leaves the want where it is, so the next cycle
tries again. Five failures and the want is dropped and the reason logged once:
a file that will not go up will not go up. A `missing` file reports nothing at
all and never becomes an attempt -- the app draws `not on this Mac`, which is
the honest answer and the only one available.

**Nothing about an attachment is logged but its count.** `uploaded 2 photos
(3.1 MB)` is the whole of what a successful cycle says. Not the filename, which
came off somebody's camera, and not the path, which names this Mac's home
directory -- §8's redaction rule, applied to the one new place a path could
have leaked from.

**Our own read state.** "Unread" in Charon means not yet seen in Charon; the
Messages app's read flags are ignored. `POST /v1/messages/read` moves the
per-chat mark.

**Outbound rows are stored, not triaged.** The user's own texts (`is_from_me`)
go into the thread for context; only inbound rows enter the triage queue.

**Summaries are by local date.** `today` regenerates at most every 10 minutes
while messages arrive; past dates freeze.

## 8. Limits and safety

- Text ≤ 20 000 chars per event; send body ≤ 4 000 chars; ingest ≤ 100 events
  per post; outbox pull ≤ 20; attachments ≤ 20 per event.
- One attachment upload ≤ 25 MiB, refused with 413 over it. The Bridge's own
  ceiling for the images it sends without being asked is 10 MiB, which is a
  policy on the Mac rather than a rule on the wire. The collector streams the
  body to a temporary file inside the store and renames it into place, so a
  25 MiB photograph is 25 MiB on disk and never 50 MiB in a Pi's memory.
- The wanted list is ≤ 20 items, oldest first, and a want older than 7 days is
  dropped on read rather than served again.
- An attachment's filename is rebuilt from a conservative alphabet before it
  reaches a path or a header, exactly as the mailbox does it, and a name that
  survives nothing at all becomes `attachment-<n>`.
- Every log line on the Mac that could carry a path has the home directory
  redacted; no message bodies are logged.
- Permissions the Bridge needs on the Mac: Full Disk Access (to read), Automation
  for Messages (to send). Both are granted by the user in System Settings; the
  Bridge only reports whether it has them.
- The collector's token is the only credential in the system; rotating it is
  rotate-and-restart, as today.
