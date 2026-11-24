"""Read-only views over saved jobs and their optional run-owned deliverables."""

from contextlib import contextmanager
import errno
import hashlib
import json
import os
import re
import stat
from urllib.parse import urlsplit


JOB_ID = re.compile(r"[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{4}-[0-9a-f]{4}")
_DIR = os.O_DIRECTORY | os.O_RDONLY | os.O_NOFOLLOW
_FILE = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
_LINK = re.compile(r"(?:\[([^\[\]\n]{1,256})\]\(\s*<?)?(https?://[^\s<>\"\\\x00-\x1f\x7f]+)", re.I)
_TYPES = {
    ".md": "text/markdown; charset=utf-8", ".txt": "text/plain; charset=utf-8",
    ".csv": "text/csv; charset=utf-8", ".json": "application/json",
    ".pdf": "application/pdf", ".docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".png": "image/png",
}


class RunError(Exception):
    def __init__(self, code, reason):
        super().__init__(reason)
        self.code = code


@contextmanager
def directory(root, parts):
    # Pin each directory before checking the next component. Job writers can
    # replace entries while a request is in flight.
    fd = os.open(root, _DIR)
    try:
        for part in parts:
            next_fd = os.open(part, _DIR, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        yield fd
    finally:
        os.close(fd)


def regular_file(directory_fd, name):
    fd = os.open(name, _FILE, dir_fd=directory_fd)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
            raise RunError(404, "File unavailable")
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def job_doc(root, jid):
    with directory(root, ["jobs"]) as fd, regular_file(fd, jid + ".json") as f:
        try:
            doc = json.load(f)
        except (ValueError, UnicodeError):
            raise RunError(500, "Unreadable job record")
    if not isinstance(doc, dict) or doc.get("id") != jid:
        raise RunError(500, "Invalid job record")
    return doc


def _text(doc, key):
    value = doc.get(key)
    return value if isinstance(value, str) else ""


def row(doc, queued):
    status = _text(doc, "status")
    if status == "idle" and queued(doc["id"]):
        status = "queued"
    return {"id": doc["id"], "title": _text(doc, "title"), "status": status,
            "created_at": _text(doc, "created_at"), "updated_at": _text(doc, "updated_at")}


def list_runs(root, queued, before, page_size):
    if before is not None and not JOB_ID.fullmatch(before):
        raise RunError(400, "Invalid run cursor")
    try:
        with directory(root, ["jobs"]) as fd, os.scandir(fd) as entries:
            ids = sorted((e.name[:-5] for e in entries if e.name.endswith(".json")
                          and JOB_ID.fullmatch(e.name[:-5]) and (not before or e.name[:-5] < before)
                          and e.is_file(follow_symlinks=False)), reverse=True)
    except FileNotFoundError:
        ids = []
    rows = []
    for jid in ids:
        try:
            rows.append(row(job_doc(root, jid), queued))
        except (FileNotFoundError, RunError):
            continue  # One incomplete, obsolete or concurrently removed record.
        if len(rows) == page_size + 1:
            return {"runs": rows[:-1], "next_cursor": rows[-2]["id"]}
    return {"runs": rows, "next_cursor": None}


def sources(markdown):
    found = {}
    for match in _LINK.finditer(markdown):
        url = match[2].rstrip(".,;:!?]")
        # Preserve a balanced parenthesis in URLs such as wiki article names.
        extra = url.count(")") - url.count("(")
        if extra > 0:
            url = url[:len(url) - min(extra, len(url) - len(url.rstrip(")")))]
        try:
            target = urlsplit(url)
            valid = target.hostname and target.username is None and target.password is None
            target.port  # Reject invalid ports as well as malformed IPv6 hosts.
        except ValueError:
            continue
        if valid:
            found.setdefault(url, {"label": match[1] or url, "url": url})
    return list(found.values())


def _visible(name):
    return not name.startswith(".") and "\\" not in name and all(c.isprintable() for c in name)


def _file_rows(root, jid):
    rows = []
    try:
        with directory(root, ["runs", jid, "files"]) as fd:
            for parent, dirs, names, parent_fd in os.fwalk(".", dir_fd=fd):
                dirs[:] = [d for d in dirs if _visible(d)]
                for name in names:
                    if not _visible(name) or os.path.splitext(name)[1].lower() not in _TYPES:
                        continue
                    try:
                        st = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                    except FileNotFoundError:
                        continue
                    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1:
                        continue
                    path = os.path.relpath(os.path.join(parent, name), ".")
                    file_id = hashlib.sha256(os.fsencode(path)).hexdigest()
                    rows.append({"id": file_id, "label": name, "path": path})
    except OSError as exc:
        if exc.errno not in (errno.ENOENT, errno.ENOTDIR, errno.ELOOP):
            raise
    return sorted(rows, key=lambda r: r["path"])


def detail(root, queued, jid):
    doc = job_doc(root, jid)
    markdown = _text(doc, "result")
    return {**row(doc, queued), "request": _text(doc, "text"), "error": _text(doc, "error") or None,
            "markdown": markdown, "sources": sources(markdown), "files": _file_rows(root, jid)}


def open_file(root, jid, file_id):
    job_doc(root, jid)  # An orphaned archive isn't a run.
    for entry in _file_rows(root, jid):
        if entry["id"] == file_id:
            *parents, name = entry["path"].split("/")
            with directory(root, ["runs", jid, "files", *parents]) as fd:
                return regular_file(fd, name), name, _TYPES[os.path.splitext(name)[1].lower()]
    raise RunError(404, "No such run file")
