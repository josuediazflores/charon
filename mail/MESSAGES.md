# MESSAGES: the iMessage channel on the Pi

The mail pipeline's sibling, for texts. A small background app on the Mac reads
new Messages rows, keeps only the conversations the user allowlisted, and pushes
them to the collector over the tailnet; the collector files them under
`messages/`; this worker reads the queue and writes back verdicts, reply drafts
and one daily read. Sends go the other way: the app files one, the collector
queues it, the Mac performs it and reports what happened.

**The Mac is never called.** Every exchange is something the Mac started. A
closed lid pauses the stream and it resumes from its cursor on the next wake,
which is why "the bridge has not reported" is a first-class state on the panel
rather than an error.

**Nothing in this directory can send a text.** The worker below runs a model and
has no way to reach Messages.app. The Mac can reach Messages.app and runs no
model. That split is the whole safety argument and it is checked by grep, not by
promise, in `test-messages.py`.

## Files

| file | what it is |
| --- | --- |
| `msglib.py` | paths, keys, the tag vocabulary, the allowlist validator. Imports the kind-agnostic half of `maillib`. Nothing model-shaped, so anything may import it. |
| `messages-triage.py` | the worker. The only new file that imports `llm`. |
| `mail-env/messages-triage.md` | the classifier's standing instruction |
| `mail-env/messages-reply.md` | the drafter's |
| `mail-env/messages-summary.md` | the daily read's |
| `charon-messages-triage.path` | the schedule: fires when `messages/.queue` is non-empty |
| `charon-messages-triage.service` | the worker, started by the path unit and never enabled itself |
| `test-messages.py` | the offline suite. No model, no network, no cost. |

The store itself is written by the collector, not from here:

```
messages/
  state.json            {last_ingest_at, last_ingest_ok, last_error, cursor, bridge_seen_at}
  config.json           the allowlist: {chats: {<chat_guid>: {read, send, name}}, updated_at}
  chats.json            the conversation directory, as the Mac last listed it
  bridge.json           the last heartbeat, verbatim, plus received_at
  index/<key>.json      one per message: the event minus its text
  bodies/<key>.txt      the text, never HTML, at most 20 000 characters
  ai/<key>.json         {key, tags, urgency 0-3, needs_you, summary, model, status, attempts, at}
  drafts/<chat_key>.json        the worker's draft
  drafts/<chat_key>.user.json   what the user typed
  summaries/<YYYY-MM-DD>.json   the daily read
  outbox/<id>.json      one queued send, and its permanent record afterwards
  audit.log             one line per outward action, appended, never pruned
  .read/<chat_key>.json Charon's own read mark. iMessage's is ignored.
  .queue/               triage-<key> · draft-<chat_key> · summary-<date>
  .actions/send-<id>    this box's note that a send was filed
```

A key is `sha256(guid)[:16]`, sixteen lowercase hex, for both a message and a
conversation. Three programs compute it: the Mac in Swift, `msglib` here, and
the collector in its own file. They are kept honest by a shared fixture rather
than by a shared module, because the collector importing this pipeline is the
one thing the split between them exists to prevent.

## The three verbs

`triage-<key>` -- up to eight messages per call on the cheap tier. Writes
`ai/<key>.json`. Inbound rows only: the user's own texts are stored for the
thread's sake and never classified. Three failures and the message is marked
`failed` and leaves the queue, because the path unit re-fires while the queue is
non-empty and an entry nothing can parse would be a loop with a model call in
it. After a batch lands, today's summary is asked for again unless one is
already asked for or the one on disk is under ten minutes old.

`draft-<chat_key>` -- one call on the good tier, written against the last twenty
messages of the conversation plus the user's optional steering line. Writes
`drafts/<chat_key>.json`. Never retried on its own: a failed draft is one tap
from being asked for again, and a queue entry that re-fires a good-tier session
by itself is a way to spend a subscription on a conversation nobody is waiting
on any more.

`summary-<date>` -- one call on the good tier over every message of one local
date, with each message's verdict beside it. Writes `summaries/<date>.json`.
Two rules that matter: **a past day is frozen** (the file exists, the day is
over, nothing can change, so the entry is dropped without a call), and **today
is rewritten only when it says something new** (identical content leaves the
flags exactly as they are, so a regeneration cannot mark a day the user already
read as unread again). `archived` survives a regeneration; `read` does not.

## The units

```bash
# once, before anything
mkdir -p /home/pi/charon-mail/messages/.queue
mkdir -p /home/pi/charon-mail/messages/{ai,drafts,summaries}
touch    /home/pi/charon-mail/messages/.triage.lock

sudo cp charon-messages-triage.{path,service} /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now charon-messages-triage.path
```

**Enable the `.path`, never the `.service`.** The path unit is the schedule;
enabling the service would run a drain at every boot whether or not anything is
waiting. The directories and the lock file have to exist first: systemd refuses
to start a unit whose `ReadWritePaths` names nothing, and a Path unit watching a
directory that is not there sits inactive forever while looking healthy.

Stopping the AI half is one command, and texts keep arriving and stay readable
without it:

```bash
sudo systemctl disable --now charon-messages-triage.path
```

There is no timer and no poller here. Nothing on this box fetches anything for
this channel: the Mac pushes.

## Invariants, and the greps that hold them

```bash
grep -c smtplib messages-triage.py                      # 0
grep -cE '^(import|from) llm\b' messages-triage.py      # 1
grep -c outbox messages-triage.py                       # 0
grep -cE '^(import|from) (subprocess|socket|urllib)\b' messages-triage.py   # 0
grep -rlE '^(import|from) llm\b' *.py | grep -v '^test-'
#   exactly mail-triage.py and messages-triage.py
```

The third one is the interesting one. The worker cannot even *name* the
directory queued sends live in, which is a stronger statement than "it does not
write there" and a cheaper one to check. The unit says the same thing a second
way: `ai/`, `drafts/`, `summaries/`, `.queue/` and the lock are the only
writable paths it is given, and the rest of the store is mounted read-only under
it.

The other rules, restated because they are the ones to not break:

* Record first, spool entry last. An entry means "not done yet", and only the
  process that did the work may say otherwise.
* One writer per field. The collector writes what arrived and what the human
  decided; this worker writes verdicts, drafts and summaries; the Mac writes
  nothing on disk at all.
* Bodies never travel in telemetry. The thread route carries them, with its own
  ceiling.
* The recipient of a send is computed on the Pi from the conversation being
  answered, never taken from the request.
* Nothing retries a send. A failed one is visible in the thread and the retry is
  a new human tap.

## Running the tests

```bash
python3 test-messages.py            # this directory, offline, ~1s
```

115 checks: the store layout, the key derivation, the allowlist validator, every
cleaner against a model that lies in all four fields at once, the summary
validator against oversize lists and invented conversations, a full drain with a
FakeLLM screwed into `llm.run_session`, a walk of the whole store before and
after that drain to prove nothing outside `ai/ drafts/ summaries/ .queue/` was
touched, a frozen past day, and the greps above.

The collector's own half has its own suite, in its own component:

```bash
cd ../collector && python3 -m unittest tests.test_messages_routes -v
```

Neither one starts a model, opens a socket beyond loopback, or touches the Pi.

## What is v2

Written down so it is a decision rather than an omission.

* **`send: auto`.** The policy is stored, validated and shown, and nothing acts
  on it: v1 gives behaviour to `off` and `confirm` only. Making it mean
  something is a design question about what a confirmation is worth, not a
  missing feature.
* **Agent drafting from the pinned conversation.** A draft today is written
  against one thread. Letting the assistant draft with the rest of Charon in
  view -- the calendar, the mail, the day's summary -- is a different prompt with
  a different context budget and its own failure modes.
* **Attachments in a verdict.** The bytes do reach the Pi: the Bridge uploads
  the images off live messages by itself and sends everything else when the
  console asks for it, and the collector stores and serves them
  (`../mac/MESSAGES-PROTOCOL.md`). This worker never opens one, though, so
  triage, drafts and the daily read are written from the text alone.
* **Reactions.** Tapbacks are not events and do not arrive. A thread that showed
  them would need them to be an edit to an existing record rather than a new
  one, which is a different write contract.
