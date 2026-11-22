# halftone-collector

Polls eight sources on a Raspberry Pi 5, holds the last good answer for each,
and serves them as one JSON document with per-source freshness and health.
Also serves the built dashboard and proxies the camera's current frame.

Consumed by the Halftone web console, a separate project that is not part of
this repo: the collector serves whatever static build sits in `dashboard_dir`,
and every route below is equally usable from the native Mac client in `mac/`
or from `curl`.

## What it collects

| source | from | every | needs |
| --- | --- | --- | --- |
| `camera` | the camera monitor on `127.0.0.1:8787` | 10s | `MONITOR_API_TOKEN` |
| `pihole` | Pi-hole v6 on the Zero W | 30s | `PIHOLE_APP_PASSWORD` |
| `nodes` | TCP probes + `/proc` for this host | 15s | nothing |
| `commits` | GitHub API | 300s | `GITHUB_TOKEN` |
| `healthchecks` | `/sys`, `/proc`, `statvfs`, one TCP probe | daily | nothing |
| `cmo` | the Daily CMO job's files under `/home/pi/charon-mail` | 60s | nothing |
| `mail` | the Gmail mirror the mail poller writes under `charon-mail/mail` | 60s | nothing |
| `messages` | the iMessage store the Mac Bridge pushes into, under `charon-mail/messages` | 30s | nothing |

**`commits` discovers its own repos.** One call to `/user/repos?sort=pushed`
ranks every repo the token can see, and only the `poll_repos` most recently
pushed (default 8) are read. A repo whose `pushed_at` has not moved since its
last successful read is skipped without a call at all, so the steady state is
**one request per cycle**, not one per repo. Forks are excluded by default:
syncing one bumps its push time to now, which floats other people's commits to
the top of the ranking. Set `commits.repos` to pin an explicit list instead —
it overrides discovery entirely.

**`healthchecks` runs once per local date, not on a clock.** Undervoltage, a
filling disk and a leaking process all look fine at any single instant and are
obvious across ninety days, so this one keeps a history in
`state_dir/healthchecks.json` rather than a number. The gate is the date on
disk: the checks run the first time a poll notices today has no entry yet, so a
box booted at any hour gets today's row within one interval, and a box
restarted six times an afternoon still runs them exactly once.
`healthchecks.interval_s` is how fast the rollover is *noticed*, not how often
the checks run.

It reads `get_throttled`, SoC temperature, root and state-dir free space,
`MemAvailable`, and one TCP probe of the Zero W on `:53`. **A check whose
instrument is absent is omitted from the day, never counted as a failure** —
there is no `get_throttled` on a Mac, and scoring a missing thermometer as a
fever is how a panel earns being ignored. A check that runs and fails makes the
source `degraded`, not `error`: the fetch worked, the finding is bad, and those
need to look different.

**`cmo` needs no secret but still starts `dormant`.** The Daily CMO job
runs once a day on this same box and leaves files behind: `heartbeat/cmo.json`,
the agent's result, the memory ledger, the briefings. This source reads them
off local disk, nothing over the network. Until the job's first run writes a
heartbeat there is nothing to read, so it reports `dormant`, re-checked on
every snapshot so the panel comes alive the moment the first run lands.

**`mail` is a mirror, not a mail client.** The Gmail app password belongs to two
scripts on this same box: a timer that polls IMAP and a path unit that performs
mailbox actions and SMTP sends. Neither has a listening socket. This collector
has the listening socket and no credentials, so it reads the directory those
workers write and, for anything that has to happen out there, drops a spool file
that wakes one of them. It cannot send mail however it is asked to.

The payload carries door summaries only: sender, subject, date, flags, the
triage's tags and urgency, one summary line, and whether there is a draft or an
attachment behind the row. **Bodies never travel in telemetry.** A message's
text, its triage artifact, its drafts and its outbox history come back together
on the message route, capped at 64 KB of body. Dormant until the poller's first
run writes `mail/state.json`; `stale` when that poller has gone quiet for longer
than `poll_stale_after_s`, which is a different question from how old this
program's copy of the directory is.

A source whose secret is missing reports **`dormant`** and is never retried.
That is a configuration statement, not a failure, and a client should draw it
as "not wired" rather than as an error. So this runs fine with none of the
optional secrets set, and you can add them one at a time.

## Supplying data to an Overview widget

A Mac user can map a reading from a small JSON document to a card. For example, an existing read-only feed returning `{"tank":{"liters":42,"history":[36,39,42]}}` can supply a gauge from **tank › liters** or a trend from **tank › history**. Keep field names and value types stable across requests. The Mac stores the mapping and layout.

Charon's built-in telemetry presets use its authenticated collector connection. The custom JSON URL reader sends no collector token. For a protected source, use a built-in metric when it fits or paste a sanitized JSON snapshot. The [agent widget design guide](../mac/Resources/WidgetHelp/AGENT-WIDGET-DESIGN.md) explains the supported formats and how to add a provider in Swift.

## Endpoints

| method | path | auth | returns |
| --- | --- | --- | --- |
| GET | `/health` | none | `{"ok":true}` and nothing else |
| GET | `/v1/telemetry` | bearer or cookie | all eight sources |
| GET | `/v1/sources/<id>` | bearer or cookie | one source |
| GET | `/v1/camera/latest.jpg` | bearer or cookie | the current frame, `image/jpeg` |
| GET | `/v1/cmo/briefing/<YYYY-MM-DD>` | bearer or cookie | that day's briefing markdown, `text/plain` |
| POST | `/v1/cmo/dismiss` | bearer or cookie | `{"ok":true,"dismissed":<n>}` |
| POST | `/v1/cmo/restore` | bearer or cookie | `{"ok":true,"dismissed":<n>}` |
| POST | `/v1/cmo/ask` | bearer or cookie | `{"ok":true,"id":"<thread>"}` |
| GET | `/v1/mail/message/<key>` | bearer or cookie | one message: record, body, triage, both drafts, outbox |
| GET | `/v1/mail/attachment/<key>/<n>` | bearer or cookie | attachment `n`, parsed out of the raw message |
| POST | `/v1/mail/read` | bearer or cookie | `{"ok":true}` |
| POST | `/v1/mail/unread` | bearer or cookie | `{"ok":true}` |
| POST | `/v1/mail/archive` | bearer or cookie | `{"ok":true}` |
| POST | `/v1/mail/draft` | bearer or cookie | `{"ok":true,"status":"queued"\|"ready"}` |
| POST | `/v1/mail/save-draft` | bearer or cookie | `{"ok":true}` |
| POST | `/v1/mail/send` | bearer or cookie | `{"ok":true,"id":"<outbox id>"}` |
| GET | `/v1/chat` | bearer or cookie | `{"threads":[…]}`, newest-updated first, capped at 50 |
| GET | `/v1/chat/<id>` | bearer or cookie | one conversation, whole, plus `queued` |
| POST | `/v1/chat/new` | bearer or cookie | `{"ok":true,"id":"<thread>"}` |
| POST | `/v1/chat/<id>/send` | bearer or cookie | 204 |
| POST | `/v1/chat/<id>/model` | bearer or cookie | 204 |
| POST | `/v1/chat/<id>/stop` | bearer or cookie | 204 |
| POST | `/v1/chat/<id>/delete` | bearer or cookie | 204, or 409 while a turn is in flight |
| GET, POST, PUT | `/v1/messages/*` | bearer or cookie | the iMessage channel: ingest, chats, threads, summaries, drafts, sends, the allowlist and attachments. Every route and its shape is in `../mac/MESSAGES-PROTOCOL.md` |
| GET, POST | `/v1/jarvis/*` | bearer or cookie | the voice assistant: today, the day list, jobs, say/stop/model/effort/compact, and the TTS proxy. Every route and its shape is in `JARVIS-CONTRACT.md` |
| GET | `/?k=<token>` | — | sets the session cookie, redirects to `/` |
| GET | anything else | bearer or cookie | the dashboard build |

Every other method, and every other POST path, still returns 405.

**Dismiss and restore are curation, not editing.** They append to and prune
`memory/dismissed.jsonl` in the CMO's own directory: one line per item or
draft the user has waved off, `{kind, title, lane, date, dismissed_at}`. The
console dims those rows and collects them on an archive page, and the agent's
next run treats them as dead. **Nothing is deleted from the agent's memory** —
a dismissed item stays in `seen-items.jsonl`, which is exactly what stops it
being rediscovered as new next week, and restore is one click. Both routes are
idempotent on `kind + title + date`, bodies are capped at 4 KB, and under
systemd this needs `ReadWritePaths=/home/pi/charon-mail/memory` in the unit.

**The mail routes queue work; they never do it.** Each one writes a file and,
where a machine has to act on it, a spool entry that wakes the worker owning
that action: `read` and `archive` go to `mail/.actions/`, `draft` files a
request and wakes the triage worker, `save-draft` writes what the reader typed
and wakes nobody, and `send` mints an `outbox/<id>.json` in state `queued` for
the actions worker to pick up. The record is always written before the spool
entry, because the entry is what wakes the worker.

**The recipient of a send is computed here, not supplied.** `POST /v1/mail/send`
takes a message key and a body, and nothing else: the address comes off the
message being replied to (`Reply-To`, else `From`), and so does the subject. A
caller that could name the recipient would make this endpoint one cross-site
POST away from being a way to send mail as its owner. The actions worker checks
the address against the same record again before it opens a socket. Reply bodies
are capped at 8,000 characters over a 64 KB request cap, the other three routes
keep the 4 KB cap, and under systemd all five need
`ReadWritePaths=/home/pi/charon-mail/mail` in the unit.

**The chat routes are the same contract with a streaming worker behind them.**
`POST /v1/chat/<id>/send` appends the user turn to
`~/halftone-chat/threads/<id>.json` and drops a spool entry in `threads/.queue/`;
`halftone-chat.path` fires, `chat-runner.py` drains it, and the answer arrives
in the same file. This process writes the record, the user turn, the spool
entry and the stop flag. **The runner writes `status`, `partial`, the assistant
turn and the claude session id, and it is the only thing that deletes either
flag.** One writer per field.

Two consequences of that split are worth stating, because both look like bugs
otherwise. First, `send` never sets `status` to `running` — nothing is running
yet, and the honest way to say "filed, not started" is the spool entry, which
is why `GET /v1/chat/<id>` reports `queued` beside the record rather than
folding the two together. Second, one turn is in flight per thread: `send` and
`model` answer **409** while a thread is queued or running, because a second
turn would be answered by a session that never saw the first one's answer.

`stop` writes `threads/.stop/<id>`, which the runner checks between stream
events; it terminates the session's process group and keeps whatever was
already said, with `[stopped]` under it. Stopping an idle thread is a 204 no-op
rather than an error — it is the state the caller asked for.

`delete` is the one chat write that is the act rather than a request for it:
there is no worker on the far side of removing a file, so this process unlinks
the record and any stale stop flag itself. It is also **409 while a turn is
queued or running**, and that refusal is load-bearing rather than tidy — the
runner rewrites the record every half second while an answer streams, so a
record deleted under a live session comes back on the runner's next write as a
conversation the reader believes they deleted. Stop it first, then delete it.

`GET /v1/chat` carries a `preview` per row: the newest assistant turn's first
non-empty line, whitespace collapsed, cut at 160 characters. Derived here rather
than in the console for the reason the turn bodies stay off this route at all —
a client that had to be sent fifty whole conversations to summarise them would
be reading the entire directory to draw one page. Empty on a thread with no
answer yet, and absent from a payload written before this field existed.

**Chat is not a source.** It has no `interval_s`, no entry in `Collector.sources`
and no place in `/v1/telemetry`. A conversation is interactive: the tab asks for
the thread it is looking at, on its own cadence, the way it already asks for a
briefing. Messages are capped at 4,000 characters over a 24 KB request cap, and
under systemd this needs `ReadWritePaths=/home/pi/halftone-chat/threads` in
the unit — `threads`, not the parent, so `env/` (the session's own permission
allowlist) stays unwritable by the process with the listening port.

**Nothing in this process starts a model.** `chat-runner.py` does, under its own
path unit, in `~/halftone-chat/env/` — see `chat-env/README.md` for the
allowlist and why each entry is on it.

**Why the cookie exists.** The dashboard renders the camera frame through a
`<canvas>`, which means an `<img>` tag, which *cannot* send an `Authorization`
header — and its dither reads the pixels back, which needs the image
same-origin or it fails silently with a blank box. A same-origin `HttpOnly`
cookie solves both. Visit `/?k=<token>` once per browser; the token then
leaves the address bar.

## The status vocabulary

| status | meaning | draw it as |
| --- | --- | --- |
| `ok` | fresh | normally |
| `stale` | last known good, past its budget | the old value **with its age** |
| `degraded` | reached it, some fields missing | what came back, null the rest |
| `dormant` | never configured | "not wired" — not an error |
| `error` | configured, tried, failed, nothing cached | fault |

**Two independent staleness layers.** `age_s` is how old *our copy* is;
fields inside `data` carry whether the upstream itself admits to being stale.
The envelope takes the worse of the two. Without that split, a 3-second-old
response from a monitor that has seen nothing for four hours renders as a
green lamp over a dead camera.

**The staleness budgets are asymmetric on purpose.** A stale counter is still
roughly true, so Pi-hole coasts for an hour. A stale reachability claim is
actively false — "the Zero W was up ten minutes ago" is not evidence it is up
now — so node results expire to `error` after 90 seconds.

## Setup

```sh
cp config.example.json config.json     # adjust addresses
cp .env.example .env && chmod 600 .env
echo "COLLECTOR_API_TOKEN=$(openssl rand -hex 32)" >> .env
python3 collector.py once              # poll everything, print the payload
python3 collector.py serve
```

Stdlib only — no venv, no pip, nothing to install on a Pi that already has
python3. Targets 3.11 (Bookworm).

## Deploy

```sh
./deploy.sh
```

Pulls on the Pi and restarts the unit. Secrets and `config.json` are
gitignored and never travel; they are created once on the box by hand.

```sh
# the writable roots first: systemd fails a ReadWritePaths= that is not there
mkdir -p ~/charon-mail/{memory,ask,mail,messages} ~/halftone-chat/{threads,jarvis}

sudo cp halftone-collector.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now halftone-collector
```

### The chat runner

Its own pair of units, and the path unit is what gets enabled — enabling the
service instead would run a drain at every boot whether or not anything is
waiting.

```sh
# the directories first: ReadWritePaths= fails on a path that is not there,
# and the path unit needs its queue directory to watch.
mkdir -p ~/halftone-chat/{bin,threads/.queue,threads/.stop,env/.claude}

cp chat-runner.py           ~/halftone-chat/bin/
cp chat-env/CLAUDE.md       ~/halftone-chat/env/
cp chat-env/settings.json   ~/halftone-chat/env/.claude/settings.json

sudo cp halftone-chat.service halftone-chat.path /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now halftone-chat.path
```

`CHAT_BASE` overrides `/home/pi/halftone-chat` for a run by hand, which is
how the runner gets exercised off the Pi. Watch it with
`journalctl -u halftone-chat -f`: one line per turn.

Turning the feature off is `sudo systemctl disable --now halftone-chat.path`.
Messages still file to disk after that and simply never get answered, which the
CHAT tab draws as queued — the true state.

## Security

This endpoint serves whole-network telemetry and proxies live camera stills.
It refuses to start without a token of at least 24 characters.

Bind the **tailnet** address, not `0.0.0.0`. On a home LAN the token is
protected only by WPA2, and anything already on that wifi — a guest's phone, a
smart plug, a TV — can reach the port. Never bind `::`: this Pi holds a global
IPv6 address, so a dual-stack bind is one permissive router rule away from
publishing a private camera feed with no NAT as a backstop.

Two separate tokens by design: `COLLECTOR_API_TOKEN` (browser → collector) and
`MONITOR_API_TOKEN` (collector → monitor) are different trust boundaries.

The Gmail app password is deliberately not a third. It belongs to the mail
poller and the actions worker, which have no listening socket; this process has
the socket and no way to reach Gmail with it. Anyone who takes the collector
token can read the mailbox mirror and queue a reply to an address the mailbox
itself supplies. They cannot choose a recipient and cannot log into the account.

Use a **fine-grained, read-only** GitHub PAT. Classic `repo` scope grants write
to every repository the account can reach.

