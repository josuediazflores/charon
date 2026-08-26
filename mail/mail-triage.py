#!/usr/bin/env python3
"""Verdicts and reply drafts for queued mail. Drains once, then exits.

Deploys to /home/pi/charon-mail/bin/mail-triage.py and is started by
charon-mail-triage.path the moment mail/.queue stops being empty. No polling
loop, no daemon: the path unit is the clock, the same way it is for the ask
runner, and an idle Pi runs nothing at all.

Two kinds of work arrive on the same queue:

    triage-<key>   up to eight at a time, one cheap-tier call for the batch
    draft-<key>    one at a time, one good-tier call each

Tiers rather than model names: llm.py owns which model a tier resolves to under
whichever provider is configured, and hands back the id it actually used so the
record says what really answered. See the repository README.

Batched because the alternative is a session per newsletter, and a session per
newsletter on the good tier is how a subscription gets spent on classifying
receipts. Drafts are not batched: there are a few a day, they are the operator's
outgoing voice, and they get the better model.

**This file imports no mail-sending library, and never will.** The "no model in
the send path" rule is structural rather than promised: this worker is the only
one that runs a model and it has no way to put anything on a wire, and the
actions worker is the only one that can send and it runs no model. Each half is
verified by grepping the file for the other half's imports, which is a test a
reviewer runs in one second and an invariant that cannot quietly rot. The two
commands live in the README and deliberately not here, because a file that
names the string being grepped for is a file that fails its own test.

Every call is text-in, text-out, with no tools: the message goes in as marked
untrusted data and the verdict comes back as fenced text. Under an HTTP provider
that is enforced by the transport having no filesystem at all. Under the
claude-cli provider it is INTENDED to be enforced by running in mail-env/, whose
settings.json has an empty allow list and denies Edit over the whole tree, which
is why the systemd unit sets WorkingDirectory there -- but whether the CLI picks
that file up depends on where your version of it looks for settings, so verify
the wiring on your install before treating it as a boundary.

Either way, everything the model says is re-validated here before it reaches
disk, because a prompt is a request and a request is not a constraint. That
validation -- defang(), the keyed MSG_BLOCK fences, clean_tags, clean_urgency,
clean_summary -- is provider-independent and is what actually holds the line.

Stdlib only, Python 3.11, same rule as the collector: this box gets no venv.
"""

import json
import os
import re
import sys
import time

import llm
import maillib
from maillib import log, stamp

LOCK_PATH = os.path.join(maillib.MAIL_DIR, ".triage.lock")
TRIAGE_PROMPT = os.path.join(maillib.MAIL_ENV_DIR, "triage.md")
REPLY_PROMPT = os.path.join(maillib.MAIL_ENV_DIR, "reply.md")

# Eight messages of headers plus 4,000 characters each is a prompt of roughly
# 35 KB, which Sonnet reads in one pass without hurrying. Larger batches make a
# single failure more expensive: every message in a batch that fails shares the
# failure.
BATCH_MAX = 8

# What the classifier sees of a body. A message that has not said what it wants
# in four thousand characters is a message whose tag is already obvious from the
# first four thousand.
TRIAGE_BODY_CHARS = 4000

# What the drafter sees. Longer, because a reply has to answer the actual thread
# rather than sort it.
DRAFT_BODY_CHARS = 8192

# Three tries and the message is marked failed and leaves the queue. It cannot
# stay: the path unit re-fires while the queue is non-empty, so an entry nothing
# can ever parse would be an infinite loop with a model call in it.
MAX_ATTEMPTS = 3

# One batch, one wall clock. Longer than the ask runner's because eight
# messages of input take longer to read than one question, still short enough
# that a wedged session does not sit on the queue behind everything else.
TRIAGE_TIMEOUT_S = 420
DRAFT_TIMEOUT_S = 300

# Bounds on what the model is allowed to claim, applied on the way in rather
# than on the way out: this output is rendered in a dashboard and read by a
# human who is deciding what to answer first.
TAGS_MAX = 4
SUMMARY_MAX = 3
SUMMARY_CHARS = 160

# Positive extraction. Not "strip the code fences and hope": the block must open
# with a key this batch actually asked about and close with the same key, so
# prose around it, a preamble, or a second opinion the model volunteered are all
# simply not matched. \1 is the whole guard.
MSG_BLOCK = re.compile(r"<<<MSG\s+([0-9a-f]{16})>>>(.*?)<<<END\s+\1>>>", re.DOTALL)
REPLY_BLOCK = re.compile(r"<<<REPLY>>>(.*?)<<<END>>>", re.DOTALL)


# -- what the model is shown --------------------------------------------------

def defang(text):
    """Take the fence markers out of a body before it goes inside a fence.

    A body is allowed to contain the literal string that ends its own block, and
    a phishing message that does so on purpose could close the untrusted region
    early and continue as if it were the prompt. Breaking the run of angle
    brackets costs nothing a classifier needs and closes that door.
    """
    return text.replace("<<<", "< <<").replace(">>>", ">> >")


def body_text(key, limit):
    """The extracted body, capped, or "" when the poller cached no body."""
    try:
        with open(maillib.text_path(key)) as fh:
            return defang(fh.read(limit))
    except OSError:
        return ""


def message_block(record, limit):
    """One message as the prompt sees it: a labeled, fenced, untrusted region.

    The key is on the marker as well as in the body of the block, because the
    model has to echo it back and a key it can only see once is a key it can
    only get wrong once.
    """
    key = record["key"]
    files = ", ".join(a.get("name", "") for a in record.get("attachments") or [])
    lines = [
        f"<<<BEGIN EMAIL {key}>>>",
        f"key: {key}",
        f"from: {record.get('from_name') or ''} <{record.get('from_addr') or ''}>",
        f"date: {record.get('date') or 'unknown'}",
        f"subject: {record.get('subject') or '(no subject)'}",
    ]
    if files:
        lines.append(f"attachments: {files[:200]}")
    lines.append("")
    lines.append(body_text(key, limit) or "(no body was cached for this message)")
    lines.append(f"<<<END EMAIL {key}>>>")
    return "\n".join(lines)


def read_prompt(path):
    """A prompt file, or None. Absent is fatal for this drain: a triage session
    without its instructions is a chatbot being handed a stranger's mail."""
    try:
        with open(path) as fh:
            return fh.read().strip()
    except OSError as exc:
        log(f"cannot read {path}: {exc}")
        return None


# -- the verdict --------------------------------------------------------------

def clean_tags(raw):
    """Only allowlisted tags, deduped, in the order the model offered them.

    The prompt lists the allowlist and the model is good at following it. This
    is not about the model: it is about what may reach a filename-shaped field
    that the console renders and the collector counts.
    """
    out = []
    if not isinstance(raw, list):
        return out
    for tag in raw:
        if not isinstance(tag, str):
            continue
        tag = tag.strip().lower()
        if tag in maillib.TAGS and tag not in out:
            out.append(tag)
        if len(out) >= TAGS_MAX:
            break
    return out


def clean_urgency(raw):
    """An int in 0..3. Anything else becomes 0.

    Clamped rather than rejected: a message the model rated 7 is a message it
    felt strongly about, and dropping the whole verdict over the number would
    lose the tags and the summary too. 0 for unparseable, because an unreadable
    urgency should never be the thing that jumps to the top of the inbox.
    """
    if isinstance(raw, bool):
        return 0
    if isinstance(raw, str):
        raw = raw.strip()
        try:
            raw = int(raw)
        except ValueError:
            return 0
    if isinstance(raw, float):
        raw = int(raw)
    if not isinstance(raw, int):
        return 0
    return max(0, min(3, raw))


def clean_summary(raw):
    """Up to three bullets, each one line, each bounded."""
    out = []
    if isinstance(raw, str):
        raw = [raw]
    if not isinstance(raw, list):
        return out
    for line in raw:
        if not isinstance(line, str):
            continue
        line = " ".join(line.split())[:SUMMARY_CHARS]
        if line:
            out.append(line)
        if len(out) >= SUMMARY_MAX:
            break
    return out


def write_verdict(key, payload, model):
    """One ai record. Returns True when it landed."""
    return maillib.write_json(maillib.ai_path(key), {
        "key": key,
        "tags": clean_tags(payload.get("tags")),
        "urgency": clean_urgency(payload.get("urgency")),
        "summary": clean_summary(payload.get("summary")),
        "model": model,
        "status": "ok",
        "attempts": 0,
        "at": stamp(),
    })


def bump_attempt(key, why):
    """One more try used up, and the entry dropped once they are gone.

    The count lives in the ai record because that is the file that already
    exists per message and the console already reads. A pending record carries
    no verdict at all -- urgency null, no tags -- so nothing downstream can
    mistake "not classified yet" for "classified as unimportant".
    """
    record = maillib.read_json(maillib.ai_path(key)) or {}
    attempts = record.get("attempts")
    attempts = attempts + 1 if isinstance(attempts, int) else 1
    done = attempts >= MAX_ATTEMPTS
    maillib.write_json(maillib.ai_path(key), {
        "key": key,
        "tags": [],
        "urgency": None,
        "summary": [],
        "model": None,
        "status": "failed" if done else "pending",
        "attempts": attempts,
        "error": str(why)[:300],
        "at": stamp(),
    })
    if done:
        log(f"{key}: giving up after {attempts} attempts ({why})")
        maillib.spool_drop(maillib.QUEUE_DIR, f"triage-{key}")


# -- triage -------------------------------------------------------------------

def triage_batch(keys, system):
    """One session for up to eight messages. Unspools only what it parsed.

    A key that comes back parsed is done. A key that does not -- the model
    skipped it, the JSON in its block was malformed, it answered about a message
    nobody asked about -- keeps its queue entry and burns one attempt. That
    asymmetry is the whole retry design: the queue stays true, and the only way
    off it is a verdict or three failures.
    """
    blocks = []
    live = []
    for key in keys:
        record = maillib.read_json(maillib.index_path(key))
        if record is None or record.get("key") != key:
            # A spool entry naming a message that is not indexed. Nothing can
            # ever classify it, so it leaves the queue instead of being retried
            # until the end of time.
            log(f"{key}: no index record; dropping the spool entry")
            maillib.spool_drop(maillib.QUEUE_DIR, f"triage-{key}")
            continue
        blocks.append(message_block(record, TRIAGE_BODY_CHARS))
        live.append(key)

    if not live:
        return

    prompt = "\n\n".join([system, f"Messages in this batch: {len(live)}"] + blocks)
    began = time.monotonic()
    text, failed, model_id = llm.run_session(
        prompt, llm.TIER_CHEAP, TRIAGE_TIMEOUT_S, cwd=maillib.MAIL_ENV_DIR)
    if failed:
        log(f"triage of {len(live)} messages failed: {failed}")
        for key in live:
            bump_attempt(key, failed)
        return

    wanted = set(live)
    seen = set()
    for found in MSG_BLOCK.finditer(text):
        key = found.group(1)
        if key not in wanted or key in seen:
            # A block about a message that was not in this batch. Not an error
            # worth failing over, and absolutely not something to write: the
            # only keys this session was shown are the ones it may answer for.
            continue
        try:
            payload = json.loads(found.group(2).strip())
        except ValueError:
            continue
        if not isinstance(payload, dict):
            continue
        if write_verdict(key, payload, model_id):
            seen.add(key)
            maillib.spool_drop(maillib.QUEUE_DIR, f"triage-{key}")

    for key in wanted - seen:
        bump_attempt(key, "the session returned no usable block for this message")
    log(f"triage: {len(seen)} of {len(live)} classified by {model_id} "
        f"in {round(time.monotonic() - began, 1)}s")


# -- drafts -------------------------------------------------------------------

def draft_one(key, system):
    """One reply draft, on Opus, for one message.

    The record is written for every outcome including failure, because the
    console draws `queued` from this file and a draft that failed silently is a
    spinner that never stops.

    No automatic retry. A failed draft is one click away from being asked for
    again, and a queue entry that re-fires an Opus session on its own is a way
    to spend a subscription on a message nobody is waiting for any more.
    """
    entry = f"draft-{key}"
    record = maillib.read_json(maillib.index_path(key))
    if record is None or record.get("key") != key:
        log(f"{key}: no index record; dropping the draft request")
        maillib.spool_drop(maillib.QUEUE_DIR, entry)
        return

    existing = maillib.read_json(maillib.draft_path(key)) or {}
    instructions = existing.get("instructions")
    instructions = instructions.strip()[:2000] if isinstance(instructions, str) else ""

    parts = [system, message_block(record, DRAFT_BODY_CHARS)]
    if instructions:
        # The operator's own words, from the dashboard, and the one piece of
        # text in this prompt that is an instruction rather than data.
        parts.append("## what the operator asked for in this reply\n\n"
                     + defang(instructions))
    text, failed, model_id = llm.run_session(
        "\n\n".join(parts), llm.TIER_GOOD, DRAFT_TIMEOUT_S,
        cwd=maillib.MAIL_ENV_DIR)

    body = ""
    if not failed:
        found = REPLY_BLOCK.search(text)
        if found:
            body = found.group(1).strip()
        else:
            failed = "the session did not return a fenced reply"

    doc = {
        "key": key,
        "status": "failed" if failed else "ready",
        "text": body,
        "instructions": instructions,
        "model": model_id,
        "error": str(failed)[:300] if failed else None,
        "at": stamp(),
    }
    if failed:
        log(f"{key}: draft failed: {failed}")
    if maillib.write_json(maillib.draft_path(key), doc):
        maillib.spool_drop(maillib.QUEUE_DIR, entry)
    # A write that failed leaves the entry queued: the record still says
    # `queued`, which is still true, and the next fire tries again. This is the
    # one failure where a retry is the right behaviour.


# -- the drain ----------------------------------------------------------------

def drain():
    """Everything waiting, oldest first, then done.

    Re-scanned each pass rather than snapshotted once, so mail that arrives
    while a batch is running is picked up by this same drain instead of waiting
    for the path unit to fire again.

    `attempted` is the only stop condition beyond an empty queue: an entry that
    survives its turn must not be picked again in the same drain, or this
    becomes a spin on one bad message with a model call in the middle of it.
    """
    triage_system = None
    reply_system = None
    attempted = set()

    while True:
        waiting = [name for name in maillib.spooled(maillib.QUEUE_DIR)
                   if name not in attempted]
        if not waiting:
            return

        verb, subject = maillib.split_entry(waiting[0])
        if verb not in ("triage", "draft") or not maillib.KEY_RE.fullmatch(subject or ""):
            log(f"{waiting[0]}: not a queue entry this worker understands; dropping it")
            attempted.add(waiting[0])
            maillib.spool_drop(maillib.QUEUE_DIR, waiting[0])
            continue

        if verb == "triage":
            if triage_system is None:
                triage_system = read_prompt(TRIAGE_PROMPT)
                if triage_system is None:
                    return
            batch = []
            for name in waiting:
                kind, key = maillib.split_entry(name)
                if kind == "triage" and maillib.KEY_RE.fullmatch(key or ""):
                    batch.append(key)
                    attempted.add(name)
                if len(batch) >= BATCH_MAX:
                    break
            try:
                triage_batch(batch, triage_system)
            except Exception as exc:  # noqa: BLE001
                # One batch failing is not the drain failing. The entries stay,
                # the next fire tries them again, and the drafts behind them
                # still get written now.
                log(f"triage batch failed: {exc!r}")
        else:
            attempted.add(waiting[0])
            if reply_system is None:
                reply_system = read_prompt(REPLY_PROMPT)
                if reply_system is None:
                    return
            try:
                draft_one(subject, reply_system)
            except Exception as exc:  # noqa: BLE001
                log(f"{subject}: draft failed: {exc!r}")


def main():
    # secrets/env only: the subscription token, and never the mailbox password.
    # The session this worker starts inherits this environment, so what is not
    # loaded here is what a model can never be handed.
    maillib.load_env(maillib.ENV_PATH)
    if not maillib.take_lock(LOCK_PATH):
        # Another drain is already working. Not an error, and not a queue that
        # goes unserved: the running process re-scans after every batch.
        return 0
    maillib.ensure_dirs()
    began = time.monotonic()
    drain()
    log(f"drain finished in {round(time.monotonic() - began, 1)}s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
