"""Release scheduled research into the existing job queue when it is due."""

from datetime import datetime, timezone
import json
import os
import sys

from jarvis_runs import JOB_ID, RunError, directory, job_doc, regular_file


def promote_due(root, now=None):
    if not root:
        return
    now = now or datetime.now(timezone.utc)
    try:
        with directory(root, [".scheduled"]) as pending, os.scandir(pending) as entries:
            for entry in entries:
                jid = entry.name.removesuffix(".json")
                if entry.name != jid + ".json" or not JOB_ID.fullmatch(jid):
                    continue
                try:
                    with regular_file(pending, entry.name) as f:
                        marker = json.load(f)
                    if not isinstance(marker, dict) or marker.get("id") != jid:
                        raise ValueError("invalid schedule marker")
                    stamp = marker["run_at"]
                    due = datetime.fromisoformat(stamp.replace("Z", "+00:00"))
                    if due.tzinfo is None:
                        raise ValueError("run_at needs a time zone")
                    stopped = os.path.exists(os.path.join(root, ".jobstop", jid))
                    if not stopped and now < due:
                        continue
                    job = job_doc(root, jid)
                    if not JOB_ID.fullmatch(job.get("parent_id") or "") or job.get("run_at") != stamp:
                        raise ValueError("schedule does not match its task")
                    if job.get("status") != "idle":
                        if job.get("status") in ("running", "done", "error"):
                            os.unlink(entry.name, dir_fd=pending)
                        continue
                    # The rename is the handoff. A restart sees either a pending
                    # marker or the worker's spool entry, even if the Pi was off
                    # at the selected time. The worker checks stop before Codex.
                    with directory(root, [".jobs"]) as queue:
                        os.replace(entry.name, jid, src_dir_fd=pending, dst_dir_fd=queue)
                        os.fsync(queue)
                        os.fsync(pending)
                except FileNotFoundError:
                    # A marker already claimed, or a record still being filed.
                    continue
                except (OSError, RunError, AttributeError, KeyError, TypeError, ValueError) as exc:
                    print(f"Jarvis schedule: could not release {jid}: {exc}", file=sys.stderr)
    except FileNotFoundError:
        return  # No scheduled tasks on a fresh or older store.
    except OSError as exc:
        print(f"Jarvis schedule unavailable: {exc}", file=sys.stderr)
