"""Persist finite overnight requests and idempotently file their individual jobs."""
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
from tempfile import NamedTemporaryFile
from uuid import UUID

MAX_INPUT = 12_000
MAX_TASKS = 24
TITLE = "Plan overnight tasks"
TIMESTAMP = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]{1,6})?(?:Z|[+-][0-9]{2}:[0-9]{2})")


class RequestConflict(ValueError):
    pass


def required_text(value, limit, label):
    if not isinstance(value, str) or not 0 < len(value.strip()) <= limit:
        raise ValueError(f"{label} must be between 1 and {limit} characters")
    text = value.strip()
    text.encode("utf-8")
    return text


def parse_description(doc, *, preserve_markdown=False):
    if not isinstance(doc, dict):
        raise ValueError("Expected a JSON object")
    key = doc.get("request_id")
    if not isinstance(key, str) or len(key) != 36:
        raise ValueError("request_id must be a UUID")
    key = str(UUID(key))
    text = required_text(doc.get("text"), MAX_INPUT, "Description")
    if preserve_markdown:
        text = doc["text"]
        if len(text) > MAX_INPUT:
            raise ValueError(f"Description exceeds {MAX_INPUT} characters")
    return key, text


def parse_request(doc):
    key, text = parse_description(doc)
    return key, text, parse_time(doc.get("run_at"))


def parse_time(raw):
    if not isinstance(raw, str) or not TIMESTAMP.fullmatch(raw):
        raise ValueError("run_at must be an RFC3339 date and time with a timezone")
    when = datetime.fromisoformat(raw.replace("Z", "+00:00")).astimezone(timezone.utc)
    return when.isoformat().replace("+00:00", "Z")


def validate_plan(value):
    if not isinstance(value, dict) or not isinstance(value.get("tasks"), list):
        raise ValueError("Missing tasks in Codex plan")
    tasks = value["tasks"]
    if len(tasks) > MAX_TASKS:
        raise ValueError(f"Plan exceeds {MAX_TASKS} tasks. Split the description into smaller batches.")
    note = value.get("note")
    if not isinstance(note, str) or len(note) > 4000 or (not tasks and not note.strip()):
        raise ValueError("Expected a planning note explaining any unresolved requests")
    note.encode("utf-8")
    clean = []
    for task in tasks:
        if not isinstance(task, dict):
            raise ValueError("Invalid task in Codex plan")
        clean.append({"title": required_text(task.get("title"), 80, "Title"),
                      "text": required_text(task.get("text"), 4000, "Task instructions")})
    return {"tasks": clean, "note": note.strip()}


def atomic_json(path, value, *, exclusive=False, staging=None):
    # Every new-record producer (collector, runner and filing helper) takes
    # this short lock while publishing. A process killed after rename leaves
    # exactly one name, which also satisfies the archive reader's link checks.
    with NamedTemporaryFile("w", dir=staging or path.parent, prefix=".intake-", delete=False) as tmp:
        name = tmp.name
        try:
            json.dump(value, tmp)
            tmp.flush()
            os.fsync(tmp.fileno())
        except BaseException:
            os.unlink(name)
            raise
    try:
        if exclusive:
            with (path.parent.parent / ".job-create.lock").open("a") as lock:
                fcntl.flock(lock, fcntl.LOCK_EX)
                if os.path.lexists(path):
                    raise FileExistsError(path)
                os.rename(name, path)
        else:
            os.replace(name, path)
        directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        Path(name).unlink(missing_ok=True)


def read_json(path):
    try:
        value = json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except ValueError as exc:
        raise OSError("Unreadable intake storage record") from exc
    if not isinstance(value, dict):
        raise OSError("Invalid intake storage record")
    return value


def file_once(root, key, title, text, run_at, *, parent_id=None, review=False):
    """A retry can finish a started filing but cannot create a second job."""
    root = Path(root)
    jobs, receipts = root / "jobs", root / ".intake-receipts"
    dest = root / (".scheduled" if parent_id else ".intake-jobs")
    for directory in (receipts, jobs, root / ".jobs", dest):
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    receipt_path = receipts / (key + ".json")
    fingerprint = hashlib.sha256(json.dumps([title, text, run_at, parent_id]).encode()).hexdigest()
    with (receipts / ".lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        receipt = read_json(receipt_path)
        if receipt:
            if receipt["fingerprint"] != fingerprint:
                raise RequestConflict("This request ID was already used for a different assignment")
            if receipt["placed"]:
                return receipt["id"]
        elif not parent_id and not review and datetime.fromisoformat(run_at.replace("Z", "+00:00")) <= datetime.now(timezone.utc):
            raise ValueError("Choose a future start time")

        for _ in range(64):
            if receipt is None:
                now = datetime.now()
                jid = now.strftime("%Y-%m-%d-%H%M-") + os.urandom(2).hex()
                receipt = {"id": jid, "created_at": now.isoformat(timespec="seconds"),
                           "fingerprint": fingerprint, "placed": False}
                atomic_json(receipt_path, receipt)
            jid = receipt["id"]
            job_path = jobs / (jid + ".json")
            job = read_json(job_path)
            if job is None:
                created = receipt["created_at"]
                job = {"id": jid, "day": jid[:10], "title": title, "text": text, "intake_key": key,
                       "created_at": created, "updated_at": created, "run_at": run_at,
                       "status": "idle", "error": None}
                if parent_id:
                    job["parent_id"] = parent_id
                else:
                    job["kind"] = "intake"
                    if review:
                        job["review_required"] = True
                try:
                    atomic_json(job_path, job, exclusive=True)
                except FileExistsError:
                    continue
            if job.get("intake_key") == key:
                break
            # A legacy producer won this minute's candidate ID. It owns that file.
            receipt = None
        else:
            raise OSError("Could not allocate a unique job ID")

        marker = dest / (jid + ".json" if parent_id else jid)
        if job.get("status") == "idle" and not (root / ".jobs" / jid).exists():
            try:
                # The ready queues only use the marker name; the scheduler reads its time.
                atomic_json(marker, {"id": jid, "run_at": run_at}, exclusive=True, staging=receipts)
            except FileExistsError:
                pass
        receipt["placed"] = True
        atomic_json(receipt_path, receipt)
        return jid


def review_tasks(tasks):
    if not isinstance(tasks, list) or len(tasks) > MAX_TASKS:
        raise ValueError(f"Expected up to {MAX_TASKS} tasks")
    clean = []
    for task in tasks:
        if not isinstance(task, dict):
            raise ValueError("Invalid task")
        context = task.get("context")
        if not isinstance(context, str) or len(context) > 4000:
            raise ValueError("Context must fit within 4000 characters")
        context.encode("utf-8")
        clean.append({"title": required_text(task.get("title"), 80, "Title"),
                      "goal": required_text(task.get("goal"), 4000, "Goal"),
                      "context": context.strip()})
    return clean


def confirm_review(root, jid, body):
    # Caller serializes confirmations. Persist the choice before filing any child.
    path = Path(root) / "jobs" / (jid + ".json")
    doc = read_json(path)
    if not doc or not doc.get("review_required") or doc.get("status") != "done" or "plan" not in doc:
        raise RequestConflict("This plan is unavailable for review")
    approval = {"run_at": parse_time(body.get("run_at")), "tasks": review_tasks(body.get("tasks"))}
    if not approval["tasks"]:
        raise ValueError("Keep at least one task to schedule")
    if "approval" in doc:
        if doc["approval"] != approval:
            raise RequestConflict("This plan already has a different confirmed schedule")
    else:
        if datetime.fromisoformat(approval["run_at"].replace("Z", "+00:00")) <= datetime.now(timezone.utc):
            raise ValueError("Choose a future start time")
        doc.update(approval=approval, run_at=approval["run_at"])
        atomic_json(path, doc)
    for slot, task in enumerate(approval["tasks"]):
        if slot < len(doc["children"]):
            continue
        instructions = task["goal"]
        if task["context"]:
            instructions += "\n\n## Context\n\n" + task["context"]
        child = file_once(root, f"{jid}-{slot}", task["title"], instructions, doc["run_at"], parent_id=jid)
        doc["children"].append(child)
        atomic_json(path, doc)
    return jid
