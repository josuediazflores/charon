# The Jarvis contract

One assistant, one conversation per day, jobs running beside it. This file is
the agreement between four programs: `collector.py` (routes and records),
`chat-runner.py` (the talk lane), `jarvis-job-runner.py` (the work lane), and
the console. Nothing below is optional and nothing is inferred at a boundary.

**This is a new surface. It does not touch `/v1/chat` or the Chat tab**, which
keep working exactly as they do today. Jarvis lives at `/v1/jarvis/*` and on its
own page.

## Why there are two lanes

`chat-runner.py` takes one global `flock` on `threads/.runner.lock`, so exactly
one runner exists at a time. That is correct for a conversation, which is serial
by nature: you say a thing, it answers, you say the next thing. It is wrong for
work, because a forty-second job holding that lock makes the assistant
unanswerable, which is the single thing this feature exists to prevent.

So the lock is not loosened. Work moves out from under it:

| lane | spool | lock | runner | unit |
|---|---|---|---|---|
| talk | `jarvis/.say` | `jarvis/.say.lock` | `jarvis-say-runner.py` | `halftone-jarvis-say.path` |
| work | `jarvis/.jobs` | `jarvis/.jobs.lock` | `jarvis-job-runner.py` | `halftone-jarvis-job.path` |

**`chat-runner.py` is not modified and not reused.** Both runners are adapted
from it — the same stream-json parse, the same flock, the same half-second
repaint — because that file has already solved those problems and a second
opinion about them would be a bug farm. But the Chat tab keeps its own runner,
its own spool and its own lock, untouched, so nothing built here can break it.
The one thing the new runners do that it does not is keep `usage` off the
`result` event, which is where every context number in this document comes from.

Two locks, two units, two processes. One writer per field still holds, because
the talk lane only ever writes the day record and the work lane only ever writes
job records. Neither reads the other's file for anything but display.

## Paths

```
$BASE/jarvis/
  days/<YYYY-MM-DD>.json     the day record; one per calendar day, local time
  jobs/<job-id>.json         one per job, kept after it finishes
  .say/<YYYY-MM-DD>          spool: a turn is filed for this day
  .jobs/<job-id>             spool: this job is filed
  .stop/<YYYY-MM-DD>         stop the day's in-flight turn
  .jobstop/<job-id>          stop this job
  .say.lock  .jobs.lock      the two runner locks
```

Ids: a day is `YYYY-MM-DD` in local time. A job is
`YYYY-MM-DD-HHMM-xxxx` where `xxxx` is four hex, minted the same way chat ids
already are.

## The day record

`jarvis/days/<YYYY-MM-DD>.json`

```jsonc
{
  "day": "2026-08-17",              // also the id
  "created_at": "2026-08-17T06:02:11",
  "updated_at": "2026-08-17T11:44:03",
  "model": "sonnet",                // 'sonnet' | 'opus'
  "effort": "medium",               // 'low'|'medium'|'high'|'xhigh'|'max'; see below
  "status": "idle",                 // 'idle' | 'running' | 'error'
  "error": null,                    // the runner's own reason, or null
  "claude_session_id": null,        // CLEARED BY COMPACTION. See below.
  "partial": null,                  // streaming text of the in-flight turn
  "turns": [ /* Turn, oldest first */ ],
  "context": { /* Context */ },
  "compactions": [ /* Compaction, oldest first */ ]
}
```

`queued` is NOT a field on the record. Like chat, it is derived per read from
the presence of `jarvis/.say/<day>`, because the collector files the spool entry
and the runner writes the status, and between those two moments no status exists
at all.

### Turn

Three kinds share the array, distinguished by `kind`. A console that does not
recognise a `kind` must skip it rather than fail.

```jsonc
// kind: "say" — the conversation itself. role is 'user' or 'assistant'.
{ "kind": "say", "role": "user", "text": "...", "at": "2026-08-17T11:43:02" }
{ "kind": "say", "role": "assistant", "text": "...", "at": "...",
  "tools": ["Bash(systemctl status ...)"], "model": "sonnet", "elapsed_s": 22.6 }

// kind: "job" — a job card, IN the transcript, updated in place by the
// collector as the job record changes. `job_id` is the join.
{ "kind": "job", "job_id": "2026-08-17-1144-3f0a", "title": "summarise the journal",
  "at": "...", "state": "running" }

// kind: "notice" — a system line in Jarvis's voice. Never model-generated.
// See "The context warning".
{ "kind": "notice", "notice": "context", "text": "...", "at": "...",
  "pct": 52, "action": "compact" }
```

### Context

Taken from the CLI's own `result` event and never estimated.

```jsonc
{ "tokens": 104233,     // input_tokens + cache_read_input_tokens of the last turn
  "window": 200000,     // the model's window
  "pct": 52,            // floor(tokens / window * 100)
  "at": "2026-08-17T11:44:03",
  "stale": false }      // true when no turn has run since the last compaction
```

**This lags by exactly one turn** and every consumer must treat it that way: it
is what the *last* turn sent, so the next turn will be larger. It is a floor,
never a ceiling. The console says "context 52%" and never "52% remaining".

### Compaction

```jsonc
{ "at": "2026-08-17T11:50:00",
  "before_tokens": 104233,
  "kept": "A digest of the day so far: ...",   // what the new session was seeded with
  "turns_folded": 34 }                          // how many turns are behind the digest
```

## Routes

All under the same auth gate as everything else. Writes answer `204` with no
body on success, and `{"error": "..."}` with a real status on failure — the
same contract `/v1/chat` already keeps.

### Reads

| route | answers |
|---|---|
| `GET /v1/jarvis/today` | the day record for today, minting it if absent |
| `GET /v1/jarvis/days` | `{"days": [DaySummary]}`, newest first, capped at 60 |
| `GET /v1/jarvis/day/<YYYY-MM-DD>` | one day record, `404` if none |
| `GET /v1/jarvis/jobs` | `{"jobs": [Job]}`, newest first, capped at 50 |
| `GET /v1/jarvis/runs` | `{"runs": [RunSummary], "next_cursor": string or null}` |
| `GET /v1/jarvis/runs/<job-id>` | Full run detail, including the saved Markdown result |
| `GET /v1/jarvis/runs/<job-id>/files/<file-id>` | The referenced document bytes |

`DaySummary` is `{day, updated_at, turn_count, job_count, status, queued, model,
context: {pct, tokens}, preview}` where `preview` is the first line of the
newest assistant `say` turn.

### Overnight report reader

The first reader uses each existing job record as one run. A run summary contains
`id`, `title`, `status`, `created_at` and `updated_at`. Follow a non-null
`next_cursor` with `?before=<cursor>` to read the next page in descending job-ID
order. Detail adds `request`, `markdown`, nullable `error`, `sources` and `files`.

The overnight job worker defaults to Codex CLI 0.172.0. Set
`JARVIS_CODEX_BIN` to override `~/.local/bin/codex` or `JARVIS_CODEX_HOME` to
override `~/.codex-jarvis`. Sign in with ChatGPT under that same Codex home as
the service user. The worker uses live hosted web search, an empty workspace,
and a read-only permission profile. Codex returns a Markdown report and any
requested CSV, Markdown, JSON or plain text attachments as structured data.
The worker validates the complete response and atomically publishes its files.
For reviewed, scheduled Codex work the same archive includes a readable
`Run steps.md` with the scheduled time, actual start, completed web search
count and saved file links. A private completion receipt lets a restarted
worker finish recording a published result without running that research again.
The structured response limit is 2 MiB and 256 attachments. Job records include
the actual `provider` and, for Codex, the count of completed `web_searches`.
The Mac's conversation model choice applies to the Claude backend. Operators
can select that backend explicitly with `JARVIS_JOB_BACKEND=claude`.

The worker publishes each job’s deliverables under
`$BASE/jarvis/runs/<job-id>/files/`, including the final Markdown reply
as `report.md`, before marking the job done.

For completed jobs, the report reader opens the archived UTF-8 `report.md` and
extracts source labels and HTTP(S) URLs from its Markdown. The inline report
limit is 2 MiB. If the archive is missing, unreadable or larger, the reader
uses the result saved in the job record, including any truncation marker.
Running, stopped and failed jobs display their saved result.

Each supported regular file in the run directory appears with its opaque `id`,
display `label` and report-relative `path`. The file endpoint streams the
original bytes, including larger reports. Supported formats are Markdown,
text, CSV, JSON, PDF, DOCX, JPEG and PNG. Symbolic links and files with multiple
hard links are excluded. Legacy runs can have an empty file list.

### Daily brief

An authenticated `GET /v1/jarvis/brief/YYYY-MM-DD` returns the Pi-local delivery
date, a Markdown report in `markdown`, plain narration in `spoken`, and the
linked run summaries in `runs`. Each run includes an `outcome` taken from its
saved findings or status. The Mac can open the run using its existing ID to
view all sources and files.

A delivery day opens at 6 p.m. on the previous local date and closes at 6 p.m.
on the selected date. Reading an open day shows the work delivered so far.
Completed research follows its completion time. A scheduled assignment still
outstanding at the end of its window appears as pending for that day. A later
completion appears in the brief for its actual completion window. Review plans
and assignments awaiting a future start are excluded.

Reading a day with work materializes `jarvis/daily/YYYY-MM-DD.md` in the shared
store. This file is a generated view and can be regenerated from run records.
It contains report and source links and the same plain narration that playback
uses. The prose quotes the first short finding of up to two completed reports
and gives counts for the rest. Legacy runs can contribute their saved text.
An untouched empty date creates no file. Reading the brief starts no model,
speech synthesis, scheduled job or external request.

### Overnight task descriptions

The Mac's Brain Dump editor sends Markdown and a request UUID to
`POST /v1/jarvis/intake/process`. A 202 receipt identifies the planner.
Once the detail status becomes `review`, the Mac displays `proposal` cards with
`title`, `goal` and `context`. The original source is archived as `Brain Dump.md`.
The review planner uses Codex CLI with gpt-6-luna to summarize goals and constraints.
Processing alone creates zero research jobs. Done sends the reviewed cards,
the planner `id` and a future `run_at` to `POST /v1/jarvis/intake/confirm`.
The collector records that choice before scheduling children. An identical retry
resumes interrupted filing. A different choice after confirmation returns 409.

Earlier clients submit an authenticated `POST /v1/jarvis/intake` with `request_id`
(UUID), `text` (up to 12,000 characters) and `run_at` (a future RFC3339
timestamp with timezone). A 202 response includes the planner run's `id`.
Retry a lost response with the same UUID and input, even after the selected
time. A conflicting reuse returns 409. Each accepted description is one batch.

The dedicated intake watcher drains `jarvis/.intake-jobs` with
`jarvis-job-runner.py --intake`, independently of active research. The planner
calls Codex with search disabled and checkpoints the instructions before it
creates the scheduled child records. A plan can contain up to 24 independent
tasks. Its Markdown report explains any unresolved requests. Child records keep
their parent ID and the selected start time. The collector promotes due tasks
into the existing research queue when Jarvis is enabled; after downtime it
also picks up overdue tasks. Each child has its own status, report and files.
Stopping a child before its start suppresses the research call.

Summaries and details include `kind: "intake"` for planner runs, `parent_id` for
child runs and `run_at` for both. A planner detail includes `children` as run
summaries in plan order. The planner's completion records dispatch. The child
statuses show when research actually finishes.

### Upgrading a Pi that already runs Codex research

Use the approved revision of `iteration/jarvis-daily-brief` for the collector
and both installed worker files. The collector runs in its source directory.
The systemd worker runs from a separate `halftone-chat/bin` installation.
`deploy.sh` only updates the checkout and restarts the collector.

1. Record the current revision, unit states and Jarvis registration in
   `/etc/charon/jarvis-units.json`. Let active jobs finish. From the Pi service
   account, update the collector's working directory to the approved revision
   (use the contents of `collector/` for the public tree). Preserve the installed
   `.env`, `config.json` and run archives. The commands below assume the existing
   Codex research setup and a matching service account in the intake units.
   Run the blocks in the same shell.

   ```sh
   set -eu
   cd "$(systemctl show -p WorkingDirectory --value halftone-collector.service)"
   service_user=$(systemctl show -p User --value halftone-collector.service)
   test "$(id -un)" = "$service_user"
   python3 -B -c 'import collector, jarvis_runs, jarvis_intake, jarvis_schedule, jarvis_brief_audio'
   chat_base=$(python3 -B -c 'import collector; print(collector.load_config()["chat"]["base_dir"])')
   state_dir=$(python3 -B -c 'import collector; print(collector.load_config()["state_dir"])')
   systemctl show -p ReadWritePaths -p StateDirectory halftone-collector.service
   ```

   Check the effective unit grants write access to `$chat_base/jarvis` for
   `daily/`, run files and queues, and to `$state_dir` for the audio cache.
   The supplied collector unit covers both when using the stock paths. Custom
   installations must also match the worker's `CHAT_BASE` and both watched paths.

2. Install the helpers and the new intake units from that same directory.
   The talk lane invokes the helper as `jarvis-job`.

   ```sh
   mkdir -p "$chat_base/jarvis/.intake-jobs"
   install -m 0644 jarvis_intake.py "$chat_base/bin/jarvis_intake.py"
   install -m 0755 jarvis-job-runner.py "$chat_base/bin/jarvis-job-runner.py"
   install -m 0755 jarvis-job-file.py "$chat_base/bin/jarvis-job"
   sudo install -m 0644 halftone-jarvis-intake.service halftone-jarvis-intake.path /etc/systemd/system/
   sudo systemctl daemon-reload
   sudo python3 install-feature-control.py --user "$service_user" --feature jarvis --extend-pairs \
     --pair halftone-jarvis-say.path:halftone-jarvis-say.service \
     --pair halftone-jarvis-job.path:halftone-jarvis-job.service \
     --pair halftone-jarvis-intake.path:halftone-jarvis-intake.service
   ```

   Retain any additional pairs or services in a custom registration. For
   narration, configure the collector environment using the voice settings
   below. The planner and research worker use the service account's Codex CLI
   sign-in. Keep the ElevenLabs key in the collector environment.

3. Activate after approval. Restarting the collector enables its check for
   due assignments about every ten seconds while Jarvis is on. Enabling the
   intake watcher starts a planner whenever a submitted Brain Dump reaches
   its spool, including after reboot. Process saves review proposals. Done
   schedules the reviewed tasks. The legacy intake route schedules on submission.

   ```sh
   sudo systemctl restart halftone-collector.service
   systemctl is-active halftone-collector.service
   sudo systemctl enable --now halftone-jarvis-intake.path
   systemctl is-active halftone-jarvis-intake.path halftone-jarvis-job.path
   ```

   If Jarvis is paused, leave the watcher activation until Jarvis is resumed.
   Settings → Features → Jarvis pauses both workers and scheduled dispatch.
   To retire just the planner watcher, disable it and stop its active worker
   with `sudo systemctl disable --now halftone-jarvis-intake.path` and
   `sudo systemctl stop halftone-jarvis-intake.service`.

4. In Charon Live, open an existing Overnight tasks report, then open its
   delivery date in Daily Brief and read the transcript. These checks use
   saved runs. Play requests paid synthesis on a cache miss. A private
   deployment using the read gateway also needs the matching gateway revision
   to read a brief remotely. Planner submissions and audio use the tailnet
   action connection on that deployment.

### Writes

| route | body | does |
|---|---|---|
| `POST /v1/jarvis/say` | `{"text": "..."}` | files a turn on today. `409` if one is in flight |
| `POST /v1/jarvis/stop` | — | stops today's in-flight turn |
| `POST /v1/jarvis/model` | `{"model": "sonnet"\|"opus"}` | sets today's model |
| `POST /v1/jarvis/effort` | `{"effort": "low"\|"medium"\|"high"\|"xhigh"\|"max"}` | sets today's effort |
| `POST /v1/jarvis/compact` | — | see below. `409` if a turn is in flight |
| `POST /v1/jarvis/job` | `{"text": "...", "title": "..."}` | starts a job. Never 409 |
| `POST /v1/jarvis/job/<id>/stop` | — | stops one job |
| `POST /v1/jarvis/tts` | `{"text": "..."}` | one sentence in, one `audio/wav` back. See *Voice out* |
| `POST /v1/jarvis/tts/warm` | — | touches the TTS host so the first sentence is not cold |

**`/v1/jarvis/job` never answers 409, and that is the whole point of the
feature.** A job is filed whatever the talk lane is doing, and the talk lane
stays answerable whatever the jobs are doing.

Text cap is the same `CHAT_TEXT_MAX` (4000) the chat routes already enforce.

## The context warning

The collector writes a `notice` turn when the day's `context.pct` **crosses** a
threshold, at `50`, `75` and `90`.

Three rules, all load-bearing:

1. **Never model-generated.** A generated warning costs a round trip, is
   nondeterministic, and — the real problem — becomes context itself, at the
   exact moment context is the thing going wrong. The collector writes it.
2. **Once per crossing.** State is `context.pct` against the highest threshold
   already noticed on this day, tracked as the largest `pct` of any existing
   `notice` turn. 51, 52, 53% do not each get a line.
3. **It carries the action, not just the news.** `"action": "compact"` is what
   the console draws a button on.

Wording is the collector's, in his voice, and states the number:

> "We're at 52% of my context for today. I can fold what's happened so far into
> a summary and keep going — say the word."

## What compaction does

`POST /v1/jarvis/compact`:

1. Refuses with `409` if a turn is in flight. Compacting under a live session
   would race the runner's own rewrite of `claude_session_id`.
2. Writes a `compactions` entry holding the digest.
3. Sets `claude_session_id` to `null`.
4. Sets `context.stale = true`.
5. **Leaves `turns` completely alone.**

Step 5 is the point. **After compaction the transcript and the context are no
longer the same object.** The day's transcript stays whole because it is the
record of your day; what gets *sent* is the digest plus whatever came after it.
Everything about a continuous conversation depends on that separation existing.

Mechanically it is nearly free: `chat-runner.py` already branches on
`claude_session_id`, passing `--resume <id>` when there is one and starting a
fresh session when there is not. Clearing the id is the whole trick; the digest
is prepended to the next turn's prompt as the seed.

The digest is produced by the **talk lane** on the next turn, not by the compact
route, so the route never blocks on a model. Until that turn runs,
`context.stale` is true and the console draws the meter as `—` rather than a
number it no longer believes.

## What the console must not do

- Never estimate tokens from character counts. If `context` is absent, draw `—`.
- Never say "% remaining". The number lags by a turn and is a floor.
- Never fabricate a `notice`. They come off the record.
- Never poll `/v1/jarvis/today` faster than 1s while a turn is live, or 5s while
  it is idle — the same rates the chat view already uses, for the same reasons.
- Never write to `/v1/chat/*`. That surface belongs to the Chat tab.


## Effort

`--effort` is a real flag on the CLI (`low, medium, high, xhigh, max`) and the
say runner passes the day's value straight through.

Three things follow from how the CLI behaves, checked rather than assumed:

1. **An unknown value is a warning, not a failure.** The CLI prints "Unknown
   --effort value ... using the default effort" and answers anyway. So a record
   written by a newer console cannot break an older runner, and the collector
   still validates the enum -- a value it does not recognise is refused at the
   route rather than filed and silently downgraded three minutes later.
2. **It is per session, not per turn.** The flag is passed on the process that
   the runner starts, so changing it takes effect on the NEXT turn. The console
   says so rather than implying the change is retroactive.
3. **Absent means absent.** A day record with no `effort` gets no flag at all
   and the CLI uses its own default. `medium` is what the console SHOWS in that
   case, and it does not write the field until somebody chooses -- so the
   default can move under us without every old day claiming a value it never
   ran with.

Changing effort is refused with `409` while a turn is in flight, for
`/model`'s reason: the runner has already read the record.


## Write powers (2026-08-17)

Two rulings sit here. On 2026-08-17 the owner widened the original read-only
ruling so that the work lane could write. On 2026-08-25 they moved both halves
at once, giving the talk lanes a memory store they write themselves and refusing
that same store to the work lane. Where that leaves it: **the talk lanes write
exactly one thing, their own memory store, through `bin/memory`; the work lane
writes files but never that store.** The 2026-08-17 half was chosen over a
scoped workspace and over full shell because it turns the two-lane split into
the safety model — every mutation is a visible card in the transcript with its
own stop button, so anything a poisoned page or email talks a session into
shows up on screen as a job before it lands. The 2026-08-25 half is argued
under the table.

How it is enforced — three envs, three permission files, and the working
directory is the wall:

| surface | env | may |
|---|---|---|
| Chat tab | `env/` | read, plus its memory store via the `bin/memory` helper |
| Jarvis talk | `sayenv/` | read, plus file jobs via the helper, plus its memory store via `bin/memory` |
| Jarvis work | `jobenv/` | read, Write/Edit, Task, WebSearch/WebFetch; memory is readable here and not writable |

**Memory (2026-08-25).** The talk lanes keep a store of durable facts about
the operator under `~/halftone-chat/memory/`, written only through the allowlisted
`bin/memory`, and the work lane reads that store without being able to write
it. The asymmetry is deliberate, and it is the helper's own reasoning run
backwards. A job starts clean by construction and its record carries no
provenance, so a say turn that had swallowed a poisoned page could launder a
memory write through a filed job and the store would have no way to tell where
the fact came from. The job runner also records a tool *count* rather than tool
lines, so that write would be invisible on every surface this contract
describes. A job that learns something worth keeping says so in its result, and
the say lane or the operator saves it. In the two lanes that do write: the write is
refused outright when the turn fetched anything from outside the box, and every
one that goes through lands as a line in the transcript and in
`memory/.journal.jsonl`, which is itself denied to all three envs for reading
because it retains the bodies of forgotten entries.

Still true in every env: the credential fences (`.env`, `.ssh`, `secrets/`,
`.claude/`, the /proc leak files) hold for reading AND writing, and
`NoNewPrivileges` on the units makes sudo structurally impossible rather than
merely denied. Bash is the read-only command set everywhere but for one line,
`Bash(/home/pi/halftone-chat/bin/memory *)`, which lands in all three envs,
`env/` and `sayenv/` included, and mutates nothing outside
`~/halftone-chat/memory/`. A mutating *command* proper (a restart, an install)
is still added to `jobenv` deliberately, one line at a time, when a job proves
the need.

**The helper.** `bin/jarvis-job "<title>" "<instruction>"` lets a session file
a job without holding the API token, which it must never see. It writes the
job record and the spool entry — the route's first and third writes — and
deliberately not the card, because the say session invoking it is the very
process whose runner is rewriting the day record each half second. The card is
rebuilt on the next read by `jarvis_reconcile_jobs`, the same repair every
lost-append already gets.

## Voice out

Speech is a side route, never part of an answer. The console extracts complete
sentences from `partial` and posts them one at a time to `POST /v1/jarvis/tts`;
the collector proxies each to a Kokoro-class TTS host on the tailnet (`tts.base`
in `config.json`, shared secret `HALFTONE_TTS_KEY` from `.env`, forwarded as
`X-Halftone-Key`) and streams the WAV back, so the audio stays same-origin with
the page that plays it and the browser never talks to that host. A phrase in
`canned/manifest.json` is answered from memory instead, with no network hop at
all. Leave the `tts` block out of `config.json` and voice is simply off: both
routes answer 503, and a sleeping host is a 502 with a reason. Either way the
client draws a dim word and the text lane is untouched -- a TTS failure is never
a failed answer.

### Daily Brief narration

Play sends an authenticated `POST /v1/jarvis/brief/YYYY-MM-DD/audio` with the SHA-256
of the displayed spoken transcript in `transcript_sha256`. The collector reads its
own brief for that Pi-local date and returns 409 if the transcript has changed.
The first play uses ElevenLabs speech synthesis; replays use a recording keyed by
transcript, voice, model and format in `state_dir/jarvis-brief-audio/`. The response
is a mono 24 kHz WAV. The existing conversation voice continues to use its configured
local speech service.

Set `ELEVENLABS_API_KEY` and `ELEVENLABS_VOICE_ID` in the collector environment.
The optional `ELEVENLABS_TTS_MODEL` defaults to `eleven_flash_v2_5`. Install
`jarvis_brief_audio.py` next to `collector.py`. Each new recording consumes
the configured ElevenLabs account's speech allowance when the user clicks Play.
[ElevenLabs speech API](https://elevenlabs.io/docs/api-reference/text-to-speech/convert).
