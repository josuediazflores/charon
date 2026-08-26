#!/usr/bin/env python3
"""bin/memory and bin/memory-taint, run as the programs the box runs.

    python3 tests/test_memory_tool.py
    python3 -m unittest tests.test_memory_tool -v

Offline and free: every test starts the two real scripts as subprocesses
against a temp CHAT_BASE, and nothing here reaches the network or starts a
model. Nothing imports the tool either, deliberately. The lane comes from the
directory the process starts in, the taint gate comes from its environment,
and the write path takes a flock, so a test that called main() in-process
would be exercising something this box never runs.

What this covers that reading the code cannot: that the gate refuses on every
one of its conditions with one sentence, that a hook firing is enough to stop
the very next write, that two lanes writing at once produce two whole journal
lines rather than one interleaved one, and that each verb's journal line lands
on the side of the op that cannot afford to lose it -- after the entry when a
verb creates, before the unlink when one destroys.
"""

import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOL = os.path.join(REPO, "memory-tool.py")
HOOK = os.path.join(REPO, "memory-taint.py")

# The two keys the runners export at the Popen, and they are deliberately
# different values here. MEMORY_TURN_ID is minted fresh for every spawn -- the
# conversation id with eight hex characters after it -- and is the only thing
# the gate matches; MEMORY_THREAD is the plain conversation id, and is the only
# thing an entry's frontmatter carries. Keeping them apart in this file is what
# stops a test passing because the tool confused one for the other.
THREAD = "2026-08-25-a41f"
TURN = f"{THREAD}-3f9a2b1c"

# The refusals, restated here rather than imported. These four sentences are
# the ones the standing instructions in every env CLAUDE.md tell the session
# how to read, so a test file that got them from the code under test would
# agree with a typo.
TAINTED = ("memory: memory is read-only this turn: external content was "
           "fetched. If this should be saved, ask the operator to say it "
           "himself next turn.")
EXISTS = "already exists -- retry once as revise"
ABSENT = "does not exist -- retry once as remember"
JOBLANE = "the job lane reads memory and does not write it"

LANES = ("env", "sayenv", "jobenv")


def store(tmp):
    """The tree the deploy ritual makes: the store, its per-lane marker
    directories, and the three env directories the runners start sessions in.
    """
    for lane in LANES:
        os.makedirs(os.path.join(tmp, "memory", ".taint", lane), exist_ok=True)
        os.makedirs(os.path.join(tmp, lane), exist_ok=True)
    return os.path.join(tmp, "memory")


def arm(tmp, lane="env", turn=TURN):
    """What a runner does at spawn: clear the lane's markers, then write
    `armed` holding this turn's id."""
    marks = os.path.join(tmp, "memory", ".taint", lane)
    shutil.rmtree(marks, ignore_errors=True)
    os.makedirs(marks, exist_ok=True)
    with open(os.path.join(marks, "armed"), "w") as fh:
        fh.write(turn)


def mark(tmp, lane="env", name="hook-1234"):
    """What a PreToolUse hook does: one marker beside `armed`."""
    with open(os.path.join(tmp, "memory", ".taint", lane, name), "w") as fh:
        fh.write("")


def run(tmp, args, lane="env", turn=TURN, thread=THREAD, stdin=None,
        script=None):
    """One invocation, started where the box would start it, carrying the two
    keys a runner exports. Either key can be dropped with None, which is what
    a lane that exports neither looks like."""
    env = dict(os.environ)
    env["CHAT_BASE"] = tmp
    env.pop("MEMORY_TURN_ID", None)
    env.pop("MEMORY_THREAD", None)
    if turn is not None:
        env["MEMORY_TURN_ID"] = turn
    if thread is not None:
        env["MEMORY_THREAD"] = thread
    return subprocess.run(
        [sys.executable, script or TOOL, *args],
        cwd=os.path.join(tmp, lane) if lane else tmp,
        env=env, input=stdin, capture_output=True, text=True, timeout=60)


def spawn(tmp, args, lane="env", turn=TURN, thread=THREAD):
    """The same invocation left running, for the tests that need two of them
    at once or one of them waiting."""
    env = dict(os.environ)
    env["CHAT_BASE"] = tmp
    env["MEMORY_TURN_ID"] = turn
    env["MEMORY_THREAD"] = thread
    return subprocess.Popen(
        [sys.executable, TOOL, *args], cwd=os.path.join(tmp, lane), env=env,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def hold_lock(tmp):
    """The store's flock, taken by the test itself, so what the tool does
    while somebody else holds it is observable."""
    fd = os.open(os.path.join(tmp, "memory", ".lock"),
                 os.O_CREAT | os.O_RDWR, 0o644)
    fcntl.flock(fd, fcntl.LOCK_EX)
    return fd


def drop_lock(fd):
    fcntl.flock(fd, fcntl.LOCK_UN)
    os.close(fd)


def entry(tmp, name):
    """The frontmatter and body of one entry, parsed here rather than
    imported, so this file is a second opinion about the shape."""
    with open(os.path.join(tmp, "memory", f"{name}.md")) as fh:
        raw = fh.read()
    head, _, body = raw.partition("\n---\n")
    meta = {}
    for line in head.splitlines():
        key, sep, val = line.partition(":")
        if sep and line != "---":
            meta[key.strip()] = val.strip()
    return meta, body


def journal(tmp):
    """Every journal line, parsed. A line that will not parse fails here,
    which is the point: the file is the audit trail."""
    path = os.path.join(tmp, "memory", ".journal.jsonl")
    if not os.path.exists(path):
        return []
    with open(path) as fh:
        return [json.loads(line) for line in fh if line.strip()]


def markers(tmp, lane="env"):
    try:
        return sorted(os.listdir(os.path.join(tmp, "memory", ".taint", lane)))
    except OSError:
        return []


class Verbs(unittest.TestCase):
    """The six verbs as stages of one store's life.

    Numbered because these are stages rather than independent facts: there is
    nothing to revise before something has been remembered, and nothing to
    refuse as a duplicate before the name is taken. unittest runs them
    alphabetically, which is what makes the numbers work.
    """

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        store(cls.tmp)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp, ignore_errors=True)

    def test_01_remember(self):
        arm(self.tmp)
        proc = run(self.tmp, [
            "remember", "charon-owner-brevity",
            "The operator wants short answers and no em dashes anywhere",
            "The operator prefers concise replies. Never use an em dash."])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "remembered charon-owner-brevity\n")
        self.assertEqual(proc.stderr, "")

        meta, body = entry(self.tmp, "charon-owner-brevity")
        self.assertEqual(meta["name"], "charon-owner-brevity")
        self.assertEqual(meta["description"],
                         "The operator wants short answers and no em "
                         "dashes anywhere")
        self.assertEqual(meta["lane"], "env")
        # The plain conversation id, not the turn id the gate matched: the
        # turn id is minted per spawn, so an entry stamped with it would name
        # a process nobody can look up afterwards.
        self.assertEqual(meta["thread"], THREAD)
        self.assertNotEqual(meta["thread"], TURN)
        self.assertEqual(meta["created"], meta["updated"])
        self.assertTrue(meta["created"].endswith("Z"), meta["created"])
        self.assertEqual(body,
                         "The operator prefers concise replies. Never use an "
                         "em dash.\n")

        lines = journal(self.tmp)
        self.assertEqual(len(lines), 1)
        line = lines[0]
        self.assertEqual(sorted(line),
                         ["after", "at", "before", "lane", "name", "op"])
        self.assertEqual(line["lane"], "env")
        self.assertEqual(line["op"], "remember")
        self.assertEqual(line["name"], "charon-owner-brevity")
        self.assertIsNone(line["before"])
        self.assertEqual(line["after"], {
            "description":
                "The operator wants short answers and no em dashes anywhere",
            "body": "The operator prefers concise replies. Never use an "
                    "em dash."})

        # The journal keeps the bodies of forgotten entries, so it says so in
        # its mode as well as in the settings-level Read fence.
        path = os.path.join(self.tmp, "memory", ".journal.jsonl")
        self.assertEqual(os.stat(path).st_mode & 0o777, 0o600)

    def test_02_remember_over_an_existing_name(self):
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "charon-owner-brevity", "d", "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn(f"charon-owner-brevity {EXISTS}", proc.stderr)
        self.assertEqual(proc.stdout, "")
        # The refusal is total: the entry it would have overwritten is
        # untouched and the journal never heard about it.
        meta, _ = entry(self.tmp, "charon-owner-brevity")
        self.assertNotEqual(meta["description"], "d")
        self.assertEqual(len(journal(self.tmp)), 1)

    def test_03_a_second_entry_from_the_other_talk_lane(self):
        # The say lane's conversation id is the day, and its turn id is that
        # day plus the spawn's own hex.
        day, turn = "2026-08-25", "2026-08-25-9c1d0e2f"
        arm(self.tmp, "sayenv", turn=turn)
        proc = run(self.tmp, [
            "remember", "widget-catalog-rework",
            "tiers replace groups; five stages, stage 0 shipped",
            "The groups concept is gone."],
            lane="sayenv", turn=turn, thread=day)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        meta, _ = entry(self.tmp, "widget-catalog-rework")
        self.assertEqual(meta["lane"], "sayenv")
        self.assertEqual(meta["thread"], day)

    def test_04_list(self):
        proc = run(self.tmp, ["list"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(
            sorted(proc.stdout.splitlines()),
            ["charon-owner-brevity -- The operator wants short answers "
             "and no em dashes anywhere",
             "widget-catalog-rework -- tiers replace groups; five stages, "
             "stage 0 shipped"])

    def test_05_show(self):
        proc = run(self.tmp, ["show", "charon-owner-brevity"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertTrue(proc.stdout.startswith("---\nname: charon-owner-"))
        self.assertIn("Never use an em dash.", proc.stdout)

        proc = run(self.tmp, ["show", "no-such-entry"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("not in the store", proc.stderr)

    def test_06_revise(self):
        before_meta, _ = entry(self.tmp, "charon-owner-brevity")
        arm(self.tmp)
        proc = run(self.tmp, [
            "revise", "charon-owner-brevity",
            "The operator wants short answers, and never an em dash",
            "Concise replies. A comma, a colon, or a spaced double hyphen."])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "revised charon-owner-brevity\n")

        meta, body = entry(self.tmp, "charon-owner-brevity")
        self.assertEqual(meta["description"],
                         "The operator wants short answers, and never an "
                         "em dash")
        self.assertIn("spaced double hyphen", body)
        # created is the one field a rewrite keeps.
        self.assertEqual(meta["created"], before_meta["created"])
        self.assertGreaterEqual(meta["updated"], meta["created"])

        line = journal(self.tmp)[-1]
        self.assertEqual(line["op"], "revise")
        self.assertEqual(line["before"], {
            "description":
                "The operator wants short answers and no em dashes anywhere",
            "body": "The operator prefers concise replies. Never use an "
                    "em dash."})
        self.assertEqual(line["after"]["description"],
                         "The operator wants short answers, and never an "
                         "em dash")

    def test_07_revise_something_absent(self):
        arm(self.tmp)
        proc = run(self.tmp, ["revise", "never-remembered", "d", "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn(f"never-remembered {ABSENT}", proc.stderr)
        self.assertFalse(os.path.exists(
            os.path.join(self.tmp, "memory", "never-remembered.md")))

    def test_08_body_from_stdin(self):
        arm(self.tmp)
        text = 'He said "no em dashes".\n\nA second paragraph, quoted too.\n'
        proc = run(self.tmp, [
            "remember", "heredoc-body", "a body with quotes and newlines",
            "-"], stdin=text)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        _, body = entry(self.tmp, "heredoc-body")
        self.assertEqual(body, text.strip() + "\n")
        self.assertEqual(journal(self.tmp)[-1]["after"]["body"], text.strip())

    def test_09_forget(self):
        arm(self.tmp)
        proc = run(self.tmp, ["forget", "heredoc-body"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "forgot heredoc-body\n")
        self.assertFalse(os.path.exists(
            os.path.join(self.tmp, "memory", "heredoc-body.md")))

        # The journal is the undo, so it keeps both halves of what it deleted.
        line = journal(self.tmp)[-1]
        self.assertEqual(line["op"], "forget")
        self.assertIsNone(line["after"])
        self.assertEqual(line["before"]["description"],
                         "a body with quotes and newlines")
        self.assertIn("A second paragraph", line["before"]["body"])

    def test_10_forget_something_absent(self):
        arm(self.tmp)
        proc = run(self.tmp, ["forget", "heredoc-body"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("heredoc-body is not in the store", proc.stderr)

    def test_11_usage(self):
        for args in ([], ["chew"], ["remember", "one-arg"],
                     ["forget"], ["list", "extra"], ["show"]):
            proc = run(self.tmp, args)
            self.assertEqual(proc.returncode, 1, args)
            self.assertTrue(proc.stderr.startswith("memory: "), args)
            self.assertEqual(proc.stdout, "", args)

    def test_12_a_turn_with_no_thread_writes_a_dash(self):
        # The gate and the frontmatter read different keys, so a lane that
        # armed the turn but exported no MEMORY_THREAD still writes -- it just
        # has no conversation to name. The dash is the entry saying so.
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "unattributed", "d", "b"],
                   thread=None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        meta, _ = entry(self.tmp, "unattributed")
        self.assertEqual(meta["thread"], "-")

        # And a MEMORY_THREAD carrying a newline cannot forge a second
        # frontmatter field: this value lands on one line or not at all.
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "forged", "d", "b"],
                   thread="2026-08-25\ndescription: not this one")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        meta, _ = entry(self.tmp, "forged")
        self.assertEqual(meta["description"], "d")
        self.assertNotIn("\n", meta["thread"])


class Ordering(unittest.TestCase):
    """The index `list` prints: what it is keyed on, what it skips, how it is
    ordered, and where it stops. Hand-written files throughout, because a
    store built through the tool inside one second has nothing to order and
    cannot be pushed past the cap at all."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        store(self.tmp)
        self.write("middle", "the middle one", "2026-03-01T00:00:00Z")
        self.write("newest", "the newest one", "2026-08-01T00:00:00Z")
        self.write("oldest", "the oldest one", "2026-01-01T00:00:00Z")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def write(self, name, description, updated, declared=None):
        # `declared` is the frontmatter `name:` field when a hand-edit has
        # made it disagree with the filename, which is the case the stem rule
        # exists for.
        with open(os.path.join(self.tmp, "memory", f"{name}.md"), "w") as fh:
            fh.write(f"---\nname: {declared or name}\n"
                     f"description: {description}\n"
                     f"lane: env\nthread: -\ncreated: {updated}\n"
                     f"updated: {updated}\n---\nbody\n")

    def test_newest_updated_last(self):
        proc = run(self.tmp, ["list"])
        self.assertEqual(proc.stdout.splitlines(), [
            "oldest -- the oldest one",
            "middle -- the middle one",
            "newest -- the newest one"])

    def test_malformed_and_stray_files_are_skipped(self):
        with open(os.path.join(self.tmp, "memory", "mangled.md"), "w") as fh:
            fh.write("no frontmatter here at all\n")
        with open(os.path.join(self.tmp, "memory", "notes.txt"), "w") as fh:
            fh.write("---\nname: notes\ndescription: not an entry\n---\nx\n")
        proc = run(self.tmp, ["list"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(proc.stdout.splitlines()), 3)
        self.assertNotIn("mangled", proc.stdout)
        self.assertNotIn("notes", proc.stdout)

    def test_an_empty_store_lists_nothing(self):
        for name in ("middle", "newest", "oldest"):
            os.remove(os.path.join(self.tmp, "memory", f"{name}.md"))
        proc = run(self.tmp, ["list"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, "")

    def test_the_name_is_the_filename_and_not_the_frontmatter(self):
        # The digest keys off the stem and so does this, because the stem is
        # what show, revise and forget address. A line naming something no
        # verb can act on would be worse than no line: the session is told to
        # curate from these.
        self.write("stem-wins", "the file knows its own name",
                   "2026-09-01T00:00:00Z", declared="something-else")
        proc = run(self.tmp, ["list"])
        self.assertIn("stem-wins -- the file knows its own name", proc.stdout)
        self.assertNotIn("something-else", proc.stdout)

        proc = run(self.tmp, ["show", "stem-wins"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_a_stem_that_is_not_a_slug_is_not_an_entry(self):
        for name in ("Upper-Case", "with space", "under_score", "café"):
            self.write(name, "should not be listed", "2026-09-01T00:00:00Z")
        # And a file with no description has no line to give.
        with open(os.path.join(self.tmp, "memory", "bare.md"), "w") as fh:
            fh.write("---\nname: bare\nlane: env\nthread: -\n"
                     "created: 2026-09-01T00:00:00Z\n"
                     "updated: 2026-09-01T00:00:00Z\n---\nbody\n")
        proc = run(self.tmp, ["list"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(proc.stdout.splitlines()), 3)
        self.assertNotIn("should not be listed", proc.stdout)
        self.assertNotIn("bare", proc.stdout)

    def test_past_the_cap_the_newest_survive_and_the_rest_are_counted(self):
        # Only a hand-filled store can get here: the tool caps the store at
        # the same number, which is the point of them being one number. What
        # `list` owes a session in that case is the count it is not showing,
        # because the standing instruction says this index is the whole store.
        for i in range(130):
            self.write(f"pad-{i:03d}", f"pad {i}",
                       f"2026-10-{i // 24 + 1:02d}T{i % 24:02d}:00:00Z")
        proc = run(self.tmp, ["list"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = proc.stdout.splitlines()
        self.assertEqual(len(lines), 129)
        # 133 entries, 128 lines, and the three from setUp are the oldest of
        # them, so they are the first to go.
        self.assertEqual(lines[-1], "+ 5 more entries")
        self.assertNotIn("the oldest one", proc.stdout)
        self.assertEqual(lines[-2], "pad-129 -- pad 129")
        self.assertEqual(lines[0], "pad-002 -- pad 2")


class TaintGate(unittest.TestCase):
    """The gate's four states, plus the ways a deploy can be half there.

    Every refusal is the same sentence, which is itself the thing under test:
    a gate that named which condition failed would be a gate you can
    interrogate one condition at a time.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        store(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def remember(self, **kwargs):
        return run(self.tmp, ["remember", "a-fact", "a description",
                              "a body"], **kwargs)

    def assertRefused(self, proc):
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stderr.strip(), TAINTED)
        self.assertEqual(proc.stdout, "")
        self.assertFalse(os.path.exists(
            os.path.join(self.tmp, "memory", "a-fact.md")))
        self.assertEqual(journal(self.tmp), [])

    def test_armed_alone_and_matching_permits(self):
        arm(self.tmp)
        proc = self.remember()
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_no_armed_refuses(self):
        self.assertRefused(self.remember())

    def test_armed_from_an_earlier_turn_refuses(self):
        arm(self.tmp, turn="2026-08-24-old")
        self.assertRefused(self.remember())

    def test_a_marker_beside_armed_refuses(self):
        arm(self.tmp)
        mark(self.tmp, name="hook-3312")
        self.assertRefused(self.remember())

    def test_a_pre_seeded_tag_marker_refuses(self):
        # What the chat runner seeds when a turn's tags are not all inside the
        # clean set: an @web turn is tainted before the session starts.
        arm(self.tmp)
        mark(self.tmp, name="tag-web")
        self.assertRefused(self.remember())

    def test_no_turn_id_refuses(self):
        # A hand-run from the operator's own shell. Deliberate: he edits
        # entry files directly, and the tool is the sessions' door.
        arm(self.tmp)
        self.assertRefused(self.remember(turn=None))

    def test_an_empty_turn_id_refuses(self):
        arm(self.tmp, turn="")
        self.assertRefused(self.remember(turn=""))

    def test_a_missing_marker_tree_refuses(self):
        # A half-landed deploy: the binaries are there and the tree is not.
        shutil.rmtree(os.path.join(self.tmp, "memory", ".taint"))
        self.assertRefused(self.remember())

    def test_an_arm_the_runner_withheld_refuses(self):
        # The runner writes `armed` only after checking that its settings.json
        # carries the hooks block and that bin/memory-taint is executable, so
        # a half-landed deploy leaves the directory swept and empty. The
        # liveness checks themselves live in the runners; this is the half of
        # them the tool is responsible for, which is that an unarmed lane is a
        # refused lane.
        arm(self.tmp)
        os.remove(os.path.join(self.tmp, "memory", ".taint", "env", "armed"))
        self.assertRefused(self.remember())

    def test_revise_and_forget_are_gated_too(self):
        arm(self.tmp)
        self.assertEqual(self.remember().returncode, 0)
        mark(self.tmp, name="hook-77")
        for args in (["revise", "a-fact", "d", "b"], ["forget", "a-fact"]):
            proc = run(self.tmp, args)
            self.assertEqual(proc.returncode, 1, args)
            self.assertEqual(proc.stderr.strip(), TAINTED)
        # Refused, so the entry is exactly as the permitted turn left it.
        meta, _ = entry(self.tmp, "a-fact")
        self.assertEqual(meta["description"], "a description")

    def test_the_gate_is_checked_inside_the_lock(self):
        # Checking before the lock leaves a window: a marker landing between
        # the check and the write would be missed by a turn that had already
        # been cleared. So a tainted write waits for the lock like any other
        # write, and refuses only once it holds it.
        arm(self.tmp)
        mark(self.tmp, name="hook-3312")
        fd = hold_lock(self.tmp)
        proc = spawn(self.tmp, ["remember", "a-fact", "d", "b"])
        try:
            time.sleep(0.5)
            self.assertIsNone(proc.poll(),
                              "the gate answered without taking the lock")
        finally:
            drop_lock(fd)
        _, err = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(err.strip(), TAINTED)

    def test_the_read_verbs_are_not_gated(self):
        arm(self.tmp)
        self.assertEqual(self.remember().returncode, 0)
        mark(self.tmp, name="hook-77")
        for args in (["list"], ["show", "a-fact"], ["taint"]):
            proc = run(self.tmp, args, turn=None)
            self.assertEqual(proc.returncode, 0, (args, proc.stderr))
        self.assertIn("a-fact", run(self.tmp, ["list"], turn=None).stdout)


class Lanes(unittest.TestCase):
    """Which lane the tool thinks it is in, and what that lane may do."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        store(self.tmp)
        for lane in LANES:
            arm(self.tmp, lane)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_both_talk_lanes_write(self):
        for lane in ("env", "sayenv"):
            proc = run(self.tmp, ["remember", f"from-{lane}", "d", "b"],
                       lane=lane)
            self.assertEqual(proc.returncode, 0, proc.stderr)
            meta, _ = entry(self.tmp, f"from-{lane}")
            self.assertEqual(meta["lane"], lane)

    def test_the_job_lane_is_refused_every_write_verb(self):
        for args in (["remember", "from-jobenv", "d", "b"],
                     ["revise", "from-jobenv", "d", "b"],
                     ["forget", "from-jobenv"]):
            proc = run(self.tmp, args, lane="jobenv")
            self.assertEqual(proc.returncode, 1, args)
            self.assertIn(JOBLANE, proc.stderr)
        self.assertFalse(os.path.exists(
            os.path.join(self.tmp, "memory", "from-jobenv.md")))
        self.assertEqual(journal(self.tmp), [])

    def test_the_job_lane_reads(self):
        run(self.tmp, ["remember", "a-fact", "a description", "b"])
        for args in (["list"], ["show", "a-fact"], ["taint"]):
            proc = run(self.tmp, args, lane="jobenv")
            self.assertEqual(proc.returncode, 0, (args, proc.stderr))
        self.assertIn("a-fact -- a description",
                      run(self.tmp, ["list"], lane="jobenv").stdout)

    def test_an_unknown_cwd_cannot_write(self):
        proc = run(self.tmp, ["remember", "a-fact", "d", "b"], lane=None)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("this cwd is not one of", proc.stderr)
        self.assertEqual(journal(self.tmp), [])

    def test_the_read_verbs_work_from_an_arbitrary_cwd(self):
        run(self.tmp, ["remember", "a-fact", "a description", "b"])
        proc = run(self.tmp, ["list"], lane=None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("a-fact -- a description", proc.stdout)
        proc = run(self.tmp, ["show", "a-fact"], lane=None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("name: a-fact", proc.stdout)

    def test_taint_prints_the_lane_and_its_markers(self):
        proc = run(self.tmp, ["taint"])
        self.assertEqual(proc.stdout, "env -- armed\n")

        mark(self.tmp, "sayenv", "hook-3312")
        proc = run(self.tmp, ["taint"], lane="sayenv")
        self.assertEqual(proc.stdout, "sayenv -- armed, hook-3312\n")

        shutil.rmtree(os.path.join(self.tmp, "memory", ".taint", "jobenv"))
        proc = run(self.tmp, ["taint"], lane="jobenv")
        self.assertEqual(proc.stdout, "jobenv -- no markers\n")

        proc = run(self.tmp, ["taint"], lane=None)
        self.assertEqual(proc.stdout, "not in a lane\n")


class Validation(unittest.TestCase):
    """Names, caps, and the store's own size."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        store(self.tmp)
        arm(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def test_a_name_is_the_anchored_slug_and_nothing_else(self):
        for name in ("Charon", "charon owner", "charon_owner", "charon.md",
                     "charon/owner", "../evil", "..", ".journal.jsonl", "",
                     "a" * 65, "charon\nowner", "café"):
            proc = run(self.tmp, ["remember", name, "d", "b"])
            self.assertEqual(proc.returncode, 1, name)
            self.assertIn("is not a memory name", proc.stderr, name)
        self.assertEqual(journal(self.tmp), [])
        self.assertEqual(
            [n for n in os.listdir(os.path.join(self.tmp, "memory"))
             if n.endswith(".md")], [])

    def test_traversal_never_reaches_a_path(self):
        outside = os.path.join(self.tmp, "outside.md")
        proc = run(self.tmp, ["remember", "../outside", "d", "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertFalse(os.path.exists(outside))

    def verbs_refuse(self, name):
        """Every verb that resolves a name, including the read one: a link is
        not an entry, whichever direction it points."""
        for args in (["remember", name, "d", "b"],
                     ["revise", name, "d", "b"],
                     ["forget", name],
                     ["show", name]):
            proc = run(self.tmp, args)
            self.assertEqual(proc.returncode, 1, args)
            self.assertIn("is not a plain file inside the store",
                          proc.stderr, args)
            self.assertEqual(proc.stdout, "", args)

    def test_a_symlink_out_of_the_store_is_refused(self):
        # The name passes the pattern; the file it names is not in the store
        # at all. A pattern cannot see a symlink, which is why the path check
        # exists.
        outside = os.path.join(self.tmp, "outside.md")
        with open(outside, "w") as fh:
            fh.write("not an entry\n")
        os.symlink(outside, os.path.join(self.tmp, "memory", "escape.md"))
        self.verbs_refuse("escape")
        with open(outside) as fh:
            self.assertEqual(fh.read(), "not an entry\n")

    def test_a_symlink_inside_the_store_is_refused_too(self):
        # The half a containment check cannot catch: this link resolves to a
        # path that is honestly inside the store, so realpath is satisfied and
        # the alias would still be an alias -- a revise through `alias`
        # rewriting `real`, and journaling it under the name it was asked for
        # rather than the file it changed.
        real = os.path.join(self.tmp, "memory", "real.md")
        with open(real, "w") as fh:
            fh.write("---\nname: real\ndescription: the entry itself\n"
                     "lane: env\nthread: -\ncreated: 2026-01-01T00:00:00Z\n"
                     "updated: 2026-01-01T00:00:00Z\n---\nbody\n")
        os.symlink(real, os.path.join(self.tmp, "memory", "alias.md"))
        self.verbs_refuse("alias")
        with open(real) as fh:
            self.assertIn("description: the entry itself", fh.read())
        # The alias is not an entry, so it is not in the index either.
        self.assertNotIn("alias", run(self.tmp, ["list"]).stdout)

    def test_a_link_onto_the_journal_is_refused(self):
        # The sharpest version of the same shape: a name whose file is the
        # audit trail. Left resolvable, `remember j` would overwrite the one
        # file that remembers what was deleted, and do it under the store's
        # own flock.
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "a-fact", "a description", "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        journal_path = os.path.join(self.tmp, "memory", ".journal.jsonl")
        with open(journal_path, "rb") as fh:
            before = fh.read()

        os.symlink(journal_path, os.path.join(self.tmp, "memory", "j.md"))
        self.verbs_refuse("j")
        with open(journal_path, "rb") as fh:
            self.assertEqual(fh.read(), before)
        self.assertEqual(len(journal(self.tmp)), 1)

    def test_the_description_is_one_short_line(self):
        proc = run(self.tmp, ["remember", "a-fact", "d" * 201, "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("over 200 characters", proc.stderr)

        proc = run(self.tmp, ["remember", "a-fact", "two\nlines", "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("one line", proc.stderr)

        proc = run(self.tmp, ["remember", "a-fact", "   ", "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("description is empty", proc.stderr)

        proc = run(self.tmp, ["remember", "a-fact", "d" * 200, "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_the_body_is_capped(self):
        proc = run(self.tmp, ["remember", "a-fact", "d", "b" * 2001])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("over 2000 characters", proc.stderr)

        proc = run(self.tmp, ["remember", "a-fact", "d", "  "])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("body is empty", proc.stderr)

        proc = run(self.tmp, ["remember", "a-fact", "d", "b" * 2000])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        _, body = entry(self.tmp, "a-fact")
        self.assertEqual(body, "b" * 2000 + "\n")

    def test_a_stdin_body_is_capped_too(self):
        proc = run(self.tmp, ["remember", "a-fact", "d", "-"],
                   stdin="b" * 2001)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("over 2000 characters", proc.stderr)

    def test_an_entry_with_bad_bytes_still_lists_and_forgets(self):
        # Hand-editing entry files is the documented undo, so a file that came
        # back from an editor as not quite UTF-8 has to stay survivable: it is
        # still an entry, and forget still has to journal what it deleted.
        with open(os.path.join(self.tmp, "memory", "mangled.md"), "wb") as fh:
            fh.write(b"---\nname: mangled\ndescription: bad bytes \xff\xfe\n"
                     b"lane: env\nthread: -\ncreated: 2026-01-01T00:00:00Z\n"
                     b"updated: 2026-01-01T00:00:00Z\n---\nbody \xff\n")
        proc = run(self.tmp, ["list"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("mangled -- bad bytes", proc.stdout)

        proc = run(self.tmp, ["forget", "mangled"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertIn("bad bytes",
                      journal(self.tmp)[-1]["before"]["description"])

    def test_the_store_is_capped_at_128_entries(self):
        for i in range(128):
            with open(os.path.join(self.tmp, "memory", f"pad-{i}.md"),
                      "w") as fh:
                fh.write(f"---\nname: pad-{i}\ndescription: pad\nlane: env\n"
                         "thread: -\ncreated: 2026-01-01T00:00:00Z\n"
                         "updated: 2026-01-01T00:00:00Z\n---\npad\n")
        proc = run(self.tmp, ["remember", "one-too-many", "d", "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("full at 128 entries", proc.stderr)
        self.assertIn("forget one", proc.stderr)

        # A full store still curates: revise and forget are how it gets back
        # under the cap, so neither may be refused by it.
        arm(self.tmp)
        proc = run(self.tmp, ["revise", "pad-0", "still fits", "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        arm(self.tmp)
        proc = run(self.tmp, ["forget", "pad-0"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "one-too-many", "d", "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)


class Journal(unittest.TestCase):
    """The audit trail: which side of the op its line lands on, its bound, the
    mode it is written at, and what two lanes writing at once do to it."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        store(self.tmp)
        self.path = os.path.join(self.tmp, "memory", ".journal.jsonl")

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def fill(self, count=600):
        """A journal already past its size bound."""
        pad = "x" * 1000
        with open(self.path, "w") as fh:
            for i in range(count):
                fh.write(json.dumps({"at": "2026-01-01T00:00:00Z",
                                     "lane": "env", "op": "remember",
                                     "name": f"pad-{i}", "before": None,
                                     "after": {"description": "pad",
                                               "body": pad}}) + "\n")
        self.assertGreater(os.path.getsize(self.path), 512 * 1024)

    def test_the_entry_is_written_before_the_line(self):
        # A kill between the two writes is not something a test can stage, so
        # the journal is made unwritable instead, which lands in the same
        # place: the op happened and the line did not. For a verb that creates,
        # that is the only direction the pair is allowed to fail in -- the
        # entry is on disk to be read back.
        os.mkdir(self.path)
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "a-fact", "a description", "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("written but not journaled", proc.stderr)
        self.assertTrue(os.path.exists(
            os.path.join(self.tmp, "memory", "a-fact.md")))
        self.assertTrue(os.path.isdir(self.path))

    def test_a_forget_journals_before_it_deletes(self):
        # And a verb that destroys inverts the pair, because the failure that
        # matters inverts with it: the line is about to be the only copy of
        # what the entry said. So an unwritable journal costs the delete, not
        # the record of it.
        with open(os.path.join(self.tmp, "memory", "a-fact.md"), "w") as fh:
            fh.write("---\nname: a-fact\ndescription: a description\n"
                     "lane: env\nthread: -\ncreated: 2026-01-01T00:00:00Z\n"
                     "updated: 2026-01-01T00:00:00Z\n---\nthe body\n")
        os.mkdir(self.path)
        arm(self.tmp)
        proc = run(self.tmp, ["forget", "a-fact"])
        self.assertEqual(proc.returncode, 1)
        self.assertIn("a-fact is still here", proc.stderr)
        self.assertEqual(proc.stdout, "")
        self.assertTrue(os.path.exists(
            os.path.join(self.tmp, "memory", "a-fact.md")))

    def test_a_forget_that_cannot_delete_still_has_its_line(self):
        # The other direction of the same ordering, staged by making the store
        # directory unwritable after the entry is in it: the line lands, the
        # unlink fails, and what is left is an op that simply re-runs. That is
        # the trade the inversion buys -- a re-runnable line, instead of a body
        # nothing kept.
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "a-fact", "a description", "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

        arm(self.tmp)
        mem = os.path.join(self.tmp, "memory")
        os.chmod(mem, 0o500)
        try:
            proc = run(self.tmp, ["forget", "a-fact"])
        finally:
            os.chmod(mem, 0o700)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("cannot forget a-fact", proc.stderr)
        self.assertTrue(os.path.exists(os.path.join(mem, "a-fact.md")))

        lines = journal(self.tmp)
        self.assertEqual([line["op"] for line in lines],
                         ["remember", "forget"])
        self.assertEqual(lines[-1]["before"], {"description": "a description",
                                               "body": "b"})
        self.assertIsNone(lines[-1]["after"])

        # Re-running it is all the recovery there is to do.
        arm(self.tmp)
        proc = run(self.tmp, ["forget", "a-fact"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertFalse(os.path.exists(os.path.join(mem, "a-fact.md")))

    def test_halved_oldest_first_past_the_size_bound(self):
        self.fill()
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "a-fact", "a description", "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

        lines = journal(self.tmp)
        self.assertEqual(len(lines), 301)
        self.assertEqual(lines[0]["name"], "pad-300")
        self.assertEqual(lines[-1]["name"], "a-fact")
        self.assertLess(os.path.getsize(self.path), 512 * 1024)
        # Rotation writes a new file, so it has to hand back the old one's
        # mode rather than whatever the umask happens to say.
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_rotation_never_widens_what_it_rewrites(self):
        # Two halves, and the second one is a source check on purpose. The
        # file rotation leaves behind is 0600 even under a umask that would
        # have made it 0666 -- that much is observable. That the tmp it wrote
        # through was created 0600, rather than created wide and narrowed
        # afterwards, is not: the window between a plain open and a chmod is
        # microseconds, and a test that tried to catch a mode inside it would
        # be a race that passes on a fast morning. So the ordering is pinned
        # where it is written down instead.
        was = os.umask(0)
        try:
            self.fill()
            arm(self.tmp)
            proc = run(self.tmp, ["remember", "a-fact", "a description", "b"])
            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)
        finally:
            os.umask(was)
        # And nothing is left behind to wedge the next rotation shut.
        self.assertFalse(os.path.exists(f"{self.path}.tmp"))

        with open(TOOL) as fh:
            source = fh.read()
        self.assertIn("flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL", source)
        self.assertIn("os.open(tmp, flags, 0o600)", source)
        self.assertNotIn("os.chmod", source)

    def test_a_stale_rotation_tmp_does_not_wedge_rotation(self):
        # O_EXCL means the tmp cannot be inherited, and nothing else rotates
        # under this flock, so one left by a killed rotation is stale by
        # definition: removed and remade, not treated as a reason to stop
        # rotating for good.
        self.fill()
        with open(f"{self.path}.tmp", "w") as fh:
            fh.write("left behind by a rotation that was killed\n")
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "a-fact", "a description", "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(len(journal(self.tmp)), 301)
        self.assertFalse(os.path.exists(f"{self.path}.tmp"))

    def test_a_second_writer_waits(self):
        arm(self.tmp)
        fd = hold_lock(self.tmp)
        proc = spawn(self.tmp, ["remember", "a-fact", "d", "b"])
        try:
            time.sleep(0.5)
            self.assertIsNone(proc.poll(), "the tool wrote through the lock")
            self.assertFalse(os.path.exists(
                os.path.join(self.tmp, "memory", "a-fact.md")))
        finally:
            drop_lock(fd)
        out, err = proc.communicate(timeout=30)
        self.assertEqual(proc.returncode, 0, err)
        self.assertEqual(out, "remembered a-fact\n")

    def test_two_lanes_at_once_leave_two_whole_lines(self):
        arm(self.tmp, "env", turn="turn-env")
        arm(self.tmp, "sayenv", turn="turn-say")
        procs = [spawn(self.tmp, ["remember", f"from-{lane}", "a description",
                                  "b" * 1500], lane=lane, turn=turn)
                 for lane, turn in (("env", "turn-env"),
                                    ("sayenv", "turn-say"))]
        for proc in procs:
            out, err = proc.communicate(timeout=60)
            self.assertEqual(proc.returncode, 0, err)

        lines = journal(self.tmp)
        self.assertEqual(sorted(line["name"] for line in lines),
                         ["from-env", "from-sayenv"])
        self.assertEqual(sorted(line["lane"] for line in lines),
                         ["env", "sayenv"])
        for name in ("from-env", "from-sayenv"):
            self.assertTrue(os.path.exists(
                os.path.join(self.tmp, "memory", f"{name}.md")))


class Hook(unittest.TestCase):
    """bin/memory-taint: the lane it derives, what it marks, and the fact that
    it never fails a turn."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        store(self.tmp)

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def hook(self, args, lane="env", stdin=""):
        proc = run(self.tmp, args, lane=lane, stdin=stdin, script=HOOK)
        # The hook is a PreToolUse gate on every Bash call in three lanes. A
        # non-zero exit here is a broken turn, so there is no case where one
        # is acceptable.
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc

    def test_the_bare_form_marks_its_own_lane(self):
        for lane in LANES:
            self.hook([], lane=lane)
            names = [n for n in markers(self.tmp, lane)
                     if n.startswith("hook-")]
            self.assertEqual(len(names), 1, lane)

    def test_it_creates_a_lane_directory_that_is_not_there(self):
        shutil.rmtree(os.path.join(self.tmp, "memory", ".taint"))
        self.hook([])
        self.assertTrue(any(n.startswith("hook-") for n in markers(self.tmp)))

    def test_an_unknown_cwd_marks_every_lane(self):
        # The lane is derived, so a cwd neither program recognises is exactly
        # the case where the hook and the tool could disagree about where a
        # turn's markers live -- and the tool's answer is the one that decides
        # a write. All three, therefore, rather than none.
        self.hook([], lane=None)
        for lane in LANES:
            self.assertTrue(any(n.startswith("hook-")
                                for n in markers(self.tmp, lane)), lane)

    def test_it_marks_lanes_it_has_to_create(self):
        shutil.rmtree(os.path.join(self.tmp, "memory", ".taint"))
        self.hook([], lane=None)
        for lane in LANES:
            self.assertTrue(any(n.startswith("hook-")
                                for n in markers(self.tmp, lane)), lane)

    def test_sniff_marks_a_reddit_fetch(self):
        self.hook(["--sniff"], stdin=json.dumps({
            "tool_name": "Bash",
            "tool_input": {"command":
                           "/home/pi/feed-worker/reddit-fetch.py sub python"}
        }))
        self.assertTrue(any(n.startswith("hook-") for n in markers(self.tmp)))

    def test_sniff_marks_the_fetcher_wherever_it_lives(self):
        # The allow rules name one absolute path today; the file it points at
        # is the fetcher wherever the directory ends up.
        self.hook(["--sniff"], lane="sayenv", stdin=json.dumps({
            "tool_name": "Bash",
            "tool_input": {
                "command": "/home/pi/tools/reddit-fetch.py t 3"}}))
        self.assertTrue(any(n.startswith("hook-")
                            for n in markers(self.tmp, "sayenv")))

    def test_sniff_reads_the_first_token_and_not_the_line(self):
        # The command that mentions the fetcher most often is the one saving a
        # fact about where something came from. Reading the whole line would
        # let a turn taint itself by writing down its own sources, which is a
        # refusal with no fetch behind it.
        memory = "/home/pi/halftone-chat/bin/memory"
        for command in (
                f'{memory} remember reddit-source "where project news comes '
                f'from" "the operator reads it with reddit-fetch.py, not '
                f'the web"',
                f"{memory} remember heredoc-body \"a body\" - <<'EOF'\n"
                "he pulls this with reddit-fetch.py\nEOF",
                "echo reddit-fetch.py",
                "grep -rn reddit-fetch.py /home/pi/feed-worker"):
            self.hook(["--sniff"], stdin=json.dumps({
                "tool_name": "Bash", "tool_input": {"command": command}}))
        self.assertEqual(markers(self.tmp), [])

    def test_sniff_leaves_an_ordinary_command_alone(self):
        for command in ("ls -la", "systemctl status halftone-collector",
                        "journalctl -u halftone-chat -n 50"):
            self.hook(["--sniff"], stdin=json.dumps({
                "tool_name": "Bash", "tool_input": {"command": command}}))
        self.assertEqual(markers(self.tmp), [])

    def test_sniff_marks_a_payload_it_cannot_read(self):
        # The stdin shape is an assumption about this CLI build until the live
        # probes settle it, so a payload that yields no command at all is a
        # Bash call this program cannot clear. Marking costs one refused write
        # on a turn that fetched nothing; the other way round costs the store.
        for payload in ("not json at all",
                        "{broken reddit-fetch.py",
                        json.dumps({"tool_name": "Bash", "tool_input": {}}),
                        json.dumps({"tool_name": "Bash"}),
                        json.dumps(["a", "list", "instead"]),
                        json.dumps({"tool_input": {"command": ["not", "a",
                                                              "string"]}})):
            shutil.rmtree(os.path.join(self.tmp, "memory", ".taint", "env"))
            os.makedirs(os.path.join(self.tmp, "memory", ".taint", "env"))
            self.hook(["--sniff"], stdin=payload)
            self.assertTrue(any(n.startswith("hook-")
                                for n in markers(self.tmp)), payload)

    def test_sniff_marks_when_stdin_is_empty(self):
        # A hook that was handed nothing is a hook that cannot say the call
        # was clean, and it fails closed like every other unreadable payload.
        self.hook(["--sniff"], stdin="")
        self.assertTrue(any(n.startswith("hook-") for n in markers(self.tmp)))

    def test_sniff_does_not_wait_on_stdin_forever(self):
        # The deadline, which is what keeps a PreToolUse hook in front of every
        # Bash call from being able to hang a turn: stdin here is a pipe with
        # nothing in it that nobody closes.
        env = dict(os.environ)
        env["CHAT_BASE"] = self.tmp
        proc = subprocess.Popen(
            [sys.executable, HOOK, "--sniff"],
            cwd=os.path.join(self.tmp, "env"), env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True)
        started = time.monotonic()
        try:
            proc.wait(timeout=20)
        finally:
            proc.kill()
            proc.stdin.close()
            proc.stdout.close()
            proc.stderr.close()
        self.assertEqual(proc.returncode, 0)
        self.assertLess(time.monotonic() - started, 10)
        # And a deadline that ran out marks, for the reason an empty read does.
        self.assertTrue(any(n.startswith("hook-") for n in markers(self.tmp)))

    def test_a_hook_firing_refuses_the_next_write(self):
        # The whole gate, end to end and in the order it happens: the runner
        # arms the turn, the session fetches, the hook marks, the write is
        # refused with the one sentence the standing instructions name.
        arm(self.tmp)
        proc = run(self.tmp, ["remember", "a-fact", "a description", "b"])
        self.assertEqual(proc.returncode, 0, proc.stderr)

        arm(self.tmp)
        self.hook([])
        proc = run(self.tmp, ["remember", "another-fact", "a description",
                              "b"])
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stderr.strip(), TAINTED)
        self.assertFalse(os.path.exists(
            os.path.join(self.tmp, "memory", "another-fact.md")))
        self.assertEqual(len(journal(self.tmp)), 1)

        # And the refusal is inspectable from any lane, which is what `taint`
        # is for.
        proc = run(self.tmp, ["taint"], lane="jobenv", turn=None)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        proc = run(self.tmp, ["taint"])
        self.assertTrue(proc.stdout.startswith("env -- armed, hook-"))


if __name__ == "__main__":
    unittest.main()
