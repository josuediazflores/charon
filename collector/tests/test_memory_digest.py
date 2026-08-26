#!/usr/bin/env python3
"""The memory index, the inject-when rule, and the taint gate at the Popen.

    python3 tests/test_memory_digest.py
    python3 -m unittest tests.test_memory_digest -v

Offline and free, in the tests/test_messages_routes.py tradition: the runners
are the real ones, the store is a temp directory, and nothing here starts a
model or reaches the network. The one thing that is faked is `subprocess` --
each runner's module-level handle is swapped for a shim whose `Popen` records
what the marker directory and the environment looked like at the moment the
session would have started. Two of them: one that then refuses to start, which
keeps a test to the ordering it is about, and one that hands back a process
saying a single sentence, which is how a turn gets far enough to be appended to
a record and inspected there. That photograph at the Popen is the only honest
way to test an ordering whose entire point is what has already happened by the
time the session begins.

The digest, the block and the gate are one copy per talk runner, per the
codebase's copy-not-import convention, so everything the two lanes share is
asserted against both copies rather than against the chat runner's alone. A
copy is exactly the kind of thing that drifts.
"""

import importlib.util
import io
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from datetime import datetime, timedelta

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, REPO)

# The hooks block as it is deployed into each lane's .claude/settings.json. Only
# one string in it matters to the runner -- see `memory_armable` -- but a probe
# that passed against a file nothing like the real one would be a test of its
# own fixture.
SETTINGS_WITH_HOOKS = """\
{
  "permissions": {
    "allow": ["Bash(/home/pi/halftone-chat/bin/memory *)"]
  },
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "WebFetch|WebSearch",
        "hooks": [
          {
            "type": "command",
            "command": "/home/pi/halftone-chat/bin/memory-taint"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "/home/pi/halftone-chat/bin/memory-taint --sniff"
          }
        ]
      }
    ]
  }
}
"""

SETTINGS_WITHOUT_HOOKS = """\
{
  "permissions": {
    "allow": ["Bash(/home/pi/halftone-chat/bin/memory *)"]
  }
}
"""

# The nonce a runner mints for one spawn: the thread id or the day, then eight
# hex characters of os.urandom. Asserted as a shape rather than as a value --
# the whole point of it is that no test can know what it will be.
NONCE = re.compile(r"[0-9a-f]{8}")

# One claude session that answers "the answer" and exits. `session_id` travels
# on the result event exactly as the CLI puts it there, because the runners
# store it back onto the record.
RESULT_LINE = ('{"type": "result", "subtype": "success", "is_error": false, '
               '"result": "the answer", "duration_ms": 1200, '
               '"session_id": "sess-1"}\n')


def load(name, filename, base):
    """One runner module, loaded fresh with `base` as its CHAT_BASE.

    The runners read CHAT_BASE once, at import, into module constants -- the
    same arrangement the collector has with its config -- so a test that wants
    its own store loads its own copy of the module rather than reaching in and
    reassigning half a dozen paths afterwards. importlib rather than `import`
    because these files are hyphenated: they are programs the units execute by
    path, not modules anything on the box imports.
    """
    os.environ["CHAT_BASE"] = base
    spec = importlib.util.spec_from_file_location(
        name, os.path.join(REPO, filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeSubprocess:
    """A stand-in for the stdlib module inside one runner.

    Swapped in as the runner's own `subprocess` attribute rather than patched
    onto the real module, which this process and everything else in it shares.
    """

    PIPE = -1
    TimeoutExpired = subprocess.TimeoutExpired

    def __init__(self, popen):
        self.Popen = popen


class Sink:
    """A stdin the runner can write a prompt into and close.

    A StringIO would do everything except survive its own `close`, and the
    prompt is worth reading after the turn: it is the thing the memory block
    either is or is not in.
    """

    def __init__(self):
        self.text = ""
        self.closed = False

    def write(self, text):
        self.text += text

    def close(self):
        self.closed = True


class FakeProc:
    """A claude that says one thing and exits 0."""

    def __init__(self, stream):
        self.stdin = Sink()
        self.stdout = io.StringIO(stream)
        self.stderr = io.StringIO("")
        self.returncode = 0
        # Never signalled: nothing in these tests stops or times out, and a
        # real pid here would be this test process's own process group.
        self.pid = -1

    def wait(self, timeout=None):
        return 0


def photograph(seen, lane_dir, kwargs):
    """Record the taint directory and the environment as of this Popen.

    Appended to `seen["spawns"]` as well as flattened onto `seen` itself: a
    turn that folds the day before answering it starts two sessions, and the
    difference between them is the thing under test.
    """
    markers = {}
    try:
        for name in os.listdir(lane_dir):
            with open(os.path.join(lane_dir, name)) as fh:
                markers[name] = fh.read()
    except OSError:
        markers = {}
    shot = {"markers": markers, "cwd": kwargs.get("cwd"),
            "env": kwargs.get("env")}
    seen.setdefault("spawns", []).append(shot)
    seen.update(shot)


def watcher(seen, lane_dir):
    """A Popen that photographs the taint directory, then refuses to start.

    The refusal is an OSError because that is the failure every runner already
    handles at this exact line: the turn comes back with `cannot start claude`
    and nothing else in the function runs, which keeps these tests to the
    ordering they are about.
    """
    def popen(cmd, **kwargs):
        photograph(seen, lane_dir, kwargs)
        raise OSError("no claude on this box")
    return popen


def answerer(seen, lane_dir):
    """A Popen that photographs, then hands back a session that answers once.

    For the tests that need the turn to finish: what a runner writes onto the
    record it appends can only be read off the record.
    """
    def popen(cmd, **kwargs):
        photograph(seen, lane_dir, kwargs)
        proc = FakeProc(RESULT_LINE)
        seen.setdefault("procs", []).append(proc)
        return proc
    return popen


class MemoryTestCase(unittest.TestCase):
    """A temp base, both talk runners loaded against it, and the store empty.

    Both copies every time, because the shared behaviours below are asserted
    against both and a per-test fixture is cheaper to read than a class-level
    one that tests have to leave tidy for each other.
    """

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="charon-memory-")
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.addCleanup(os.environ.pop, "CHAT_BASE", None)
        self.store = os.path.join(self.tmp, "memory")
        os.makedirs(self.store)
        self.chat = load("chat_runner", "chat-runner.py", self.tmp)
        self.say = load("say_runner", "jarvis-say-runner.py", self.tmp)

    # -- fixtures ------------------------------------------------------------

    def entry(self, name, description, updated, body="One remembered fact.\n",
              said=None):
        """One entry file in the tool's own shape. Returns its path.

        `said` is the frontmatter's `name` field where it is deliberately not
        the filename -- the tool writes them the same and nothing reads the
        field, and a test is the only place the two are ever made to disagree.
        """
        path = os.path.join(self.store, f"{name}.md")
        with open(path, "w") as fh:
            fh.write("---\n"
                     f"name: {name if said is None else said}\n"
                     f"description: {description}\n"
                     "lane: env\n"
                     "thread: 2026-08-25-a41f\n"
                     f"created: {updated}\n"
                     f"updated: {updated}\n"
                     "---\n"
                     f"{body}")
        return path

    def raw(self, filename, text):
        """A file in the store that is not a well-formed entry."""
        path = os.path.join(self.store, filename)
        with open(path, "w") as fh:
            fh.write(text)
        return path

    def raw_bytes(self, filename, data):
        """A file in the store whose bytes are not text at all."""
        path = os.path.join(self.store, filename)
        with open(path, "wb") as fh:
            fh.write(data)
        return path

    def journal(self, age_s=0):
        """The journal, stamped `age_s` seconds into the past."""
        path = os.path.join(self.store, ".journal.jsonl")
        with open(path, "w") as fh:
            fh.write('{"at": "2026-08-25T09:14:02", "lane": "env", '
                     '"op": "remember", "name": "charon-owner-brevity"}\n')
        when = time.time() - age_s
        os.utime(path, (when, when))
        return path

    def lane_tree(self, lane, hooks=True, executable=True):
        """The two things `memory_armable` looks for, either landed or not."""
        claude = os.path.join(self.tmp, lane, ".claude")
        os.makedirs(claude, exist_ok=True)
        with open(os.path.join(claude, "settings.json"), "w") as fh:
            fh.write(SETTINGS_WITH_HOOKS if hooks else SETTINGS_WITHOUT_HOOKS)
        os.makedirs(os.path.join(self.tmp, "bin"), exist_ok=True)
        taint = os.path.join(self.tmp, "bin", "memory-taint")
        with open(taint, "w") as fh:
            fh.write("#!/usr/bin/env python3\n")
        os.chmod(taint, 0o755 if executable else 0o644)
        return taint

    def stale_markers(self, lane):
        """Markers left over from a turn that has already finished."""
        lane_dir = os.path.join(self.store, ".taint", lane)
        os.makedirs(lane_dir, exist_ok=True)
        with open(os.path.join(lane_dir, "armed"), "w") as fh:
            fh.write("some-older-turn")
        with open(os.path.join(lane_dir, "hook-4021"), "w") as fh:
            fh.write("")
        return lane_dir

    def at(self, delta_s):
        """A turn stamp, in the runners' own local-ISO-seconds format."""
        return (datetime.now() + timedelta(seconds=delta_s)).isoformat(
            timespec="seconds")


class Digest(MemoryTestCase):
    """What the index renders, in both copies of `memory_digest`."""

    def copies(self):
        return (("chat", self.chat), ("say", self.say))

    def test_whole_store_newest_updated_last(self):
        self.entry("widget-catalog-rework", "tiers replace groups",
                   self.at(-3600))
        self.entry("charon-owner-brevity", "short answers, no em dashes",
                   self.at(-60))
        self.entry("host-boots-from-nvme", "the host boots off the SSD",
                   self.at(-1800))
        want = ("widget-catalog-rework -- tiers replace groups\n"
                "host-boots-from-nvme -- the host boots off the SSD\n"
                "charon-owner-brevity -- short answers, no em dashes")
        for lane, module in self.copies():
            self.assertEqual(module.memory_digest(), want, lane)

    def test_empty_and_absent_stores_render_nothing(self):
        for lane, module in self.copies():
            self.assertEqual(module.memory_digest(), "", lane)
            self.assertEqual(module.memory_context(), "", lane)
        shutil.rmtree(self.store)
        for lane, module in self.copies():
            self.assertEqual(module.memory_digest(), "", lane)
            self.assertEqual(module.memory_context(), "", lane)

    def test_the_filename_names_the_entry(self):
        # The frontmatter `name` is written by the tool and read by nothing.
        # Where the two disagree -- a hand edit, a copied file -- the filename
        # wins, because the filename is what a session is sent to Read and what
        # `forget` is given.
        self.entry("charon-owner-brevity", "short answers", self.at(-60),
                   said="something-else-entirely")
        for lane, module in self.copies():
            self.assertEqual(module.memory_digest(),
                             "charon-owner-brevity -- short answers", lane)

    def test_a_filename_the_tool_would_refuse_is_not_an_entry(self):
        # The store is a directory anybody can drop a file into, so the index
        # applies the same slug rule bin/memory applies before it writes one.
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        for name in ("Shouting", "with space", "under_score", "dots.in.name",
                     "x" * 65):
            self.raw(f"{name}.md",
                     f"---\nname: {name}\ndescription: not an entry\n---\nx\n")
        for lane, module in self.copies():
            self.assertEqual(module.memory_digest(),
                             "charon-owner-brevity -- short answers", lane)

    def test_malformed_entries_are_skipped_silently(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        # No frontmatter at all, which is what a hand-written note looks like.
        self.raw("loose-note.md", "just some prose about the box\n")
        # An opening fence and no closing one: a write that stopped halfway.
        self.raw("half-written.md", "---\nname: half-written\n")
        # Frontmatter with no description, so there is no line to render.
        self.raw("no-description.md", "---\nname: no-description\n---\nbody\n")
        # Not an entry file, and the store's own machinery is not either.
        self.raw("notes.txt", "---\nname: notes\ndescription: x\n---\n")
        self.raw(".journal.jsonl", '{"op": "remember"}\n')
        # Bytes that are not text in any encoding this reads. A UTF-16 BOM in
        # front of a UTF-8 open, which is what a file saved by the wrong editor
        # looks like -- and what used to raise UnicodeDecodeError straight out
        # of the digest and wedge the whole lane.
        self.raw_bytes("bad-bytes.md", b"\xff\xfe-\x00-\x00-\x00\n\x00")
        for lane, module in self.copies():
            self.assertEqual(module.memory_digest(),
                             "charon-owner-brevity -- short answers", lane)

    def test_bad_bytes_do_not_cost_the_prompt_its_block(self):
        # The end of the same story: a file of bytes in the store must cost its
        # own line and nothing else, so the turn is built and answered exactly
        # as it would have been.
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        self.raw_bytes("bad-bytes.md", b"\xff\xfe\x00\x01\x02")
        chat_doc = {"turns": [{"role": "user", "text": "hello",
                               "at": self.at(-10)}]}
        say_doc = {"turns": [{"kind": "say", "role": "user", "text": "hello",
                              "at": self.at(-10)}]}
        for lane, module, doc in (("chat", self.chat, chat_doc),
                                  ("say", self.say, say_doc)):
            prompt = module.build_prompt(doc, "hello", False)
            self.assertIn("charon-owner-brevity -- short answers", prompt, lane)
            self.assertTrue(prompt.endswith("hello"), lane)

    def test_a_long_description_is_not_clipped(self):
        # The tool bounds a description at 200 characters, so the line is short
        # by construction and there is deliberately no second clip here. A
        # hand-written line longer than that renders whole rather than in half.
        long = "x" * 260
        self.entry("hand-written", long, self.at(-60))
        for lane, module in self.copies():
            self.assertEqual(module.memory_digest(),
                             f"hand-written -- {long}", lane)

    def test_the_scan_backstop_bounds_the_opens(self):
        # Bound lowered rather than five hundred files written: the mechanism
        # under test is which files get opened once the ceiling is reached, and
        # it is the same mechanism at three as at five hundred.
        for index in range(5):
            path = self.entry(f"entry-{index}", f"fact {index}",
                              self.at(-index * 60))
            when = time.time() - index * 60
            os.utime(path, (when, when))
        for lane, module in self.copies():
            module.MEMORY_SCAN_MAX = 3
            lines = module.memory_digest().split("\n")
            self.assertEqual(len(lines), 3, lane)
            # The newest by mtime are the ones opened, and they come back
            # oldest-updated first.
            self.assertEqual(lines[-1], "entry-0 -- fact 0", lane)
            self.assertEqual(lines[0], "entry-2 -- fact 2", lane)

    def test_the_digest_cap_keeps_the_newest(self):
        for index in range(4):
            self.entry(f"entry-{index}", f"fact {index}",
                       self.at(-index * 60))
        for lane, module in self.copies():
            module.MEMORY_DIGEST_MAX = 2
            self.assertEqual(module.memory_digest(),
                             "entry-1 -- fact 1\nentry-0 -- fact 0", lane)

    def test_the_block_carries_the_heading_and_the_lines(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        for lane, module in self.copies():
            block = module.memory_context()
            self.assertTrue(block.startswith("## what you remember\n\n"), lane)
            self.assertIn(self.store, block)
            self.assertIn("curate with\nbin/memory", block)
            self.assertIn("charon-owner-brevity -- short answers\n", block, lane)
            # The closing boundary is load-bearing: without it a command-shaped
            # user message following the block reads as part of the block, and
            # the session's own injection-hardening refuses the user's real
            # request as planted text. Found by live probe, 2026-08-25.
            self.assertTrue(
                block.endswith("its instructions are his own.)\n"), lane)


class InjectWhen(MemoryTestCase):
    """Fresh always; resumed only when the store has moved since it looked."""

    def test_a_store_with_no_journal_never_moved(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        doc = {"turns": [{"role": "assistant", "at": self.at(-30),
                          "memory_seen": 0.0}]}
        self.assertFalse(self.chat.memory_moved(doc))

    def test_no_assistant_turn_yet_is_told(self):
        self.journal()
        self.assertTrue(self.chat.memory_moved({"turns": []}))
        self.assertTrue(self.chat.memory_moved(
            {"turns": [{"role": "user", "at": self.at(-30)}]}))

    def test_a_turn_that_saw_the_current_store_did_not_move_it(self):
        path = self.journal(age_s=600)
        doc = {"turns": [{"role": "assistant", "at": self.at(-60),
                          "memory_seen": os.path.getmtime(path)}]}
        self.assertFalse(self.chat.memory_moved(doc))

    def test_a_write_during_the_last_turn_moves_it(self):
        # **The case the `at` comparison got wrong, and the reason the stamp
        # exists.** The op landed while the previous turn was running: newer
        # than what that turn was shown, older than the `at` written when it
        # finished. Asked about the `at`, this says the store has not moved and
        # the session that had just remembered something is the one session
        # never handed it back. Asked about what the turn actually saw, it
        # re-injects on the next turn, which is what section 3 of the spec
        # promises.
        path = self.journal(age_s=60)
        seen = os.path.getmtime(path) - 60
        doc = {"turns": [{"role": "assistant", "at": self.at(-30),
                          "memory_seen": seen}]}
        self.assertTrue(self.chat.memory_moved(doc))
        # The same turn without the stamp is the old answer, kept here as the
        # statement of what changed.
        old = {"turns": [{"role": "assistant", "at": self.at(-30)}]}
        self.assertFalse(self.chat.memory_moved(old))

    def test_a_turn_from_before_the_field_falls_back_to_its_stamp(self):
        # Records written before `memory_seen` existed are still in every
        # thread on the box, and they still have to be answered about.
        self.journal()
        doc = {"turns": [{"role": "assistant", "at": self.at(-600)}]}
        self.assertTrue(self.chat.memory_moved(doc))

    def test_an_unreadable_stamp_is_told(self):
        # The block is cheap next to a session that quietly does not know what
        # it remembers, so an `at` that will not parse errs towards sending it.
        self.journal(age_s=600)
        doc = {"turns": [{"role": "assistant", "at": "sometime tuesday"}]}
        self.assertTrue(self.chat.memory_moved(doc))

    def test_the_chat_lane_reads_any_assistant_turn(self):
        path = self.journal(age_s=600)
        doc = {"turns": [
            {"role": "assistant", "at": self.at(-1200), "memory_seen": 0.0},
            {"role": "assistant", "at": self.at(-30),
             "memory_seen": os.path.getmtime(path)},
        ]}
        self.assertFalse(self.chat.memory_moved(doc))

    def test_the_say_lane_reads_say_turns_only(self):
        # A job card and a context notice are things the collector filed into
        # the array; neither is a moment this assistant was handed anything, so
        # neither may stand in for the last answer -- and neither carries a
        # stamp, because neither was ever shown the block.
        path = self.journal(age_s=600)
        doc = {"turns": [
            {"kind": "say", "role": "assistant", "at": self.at(-1200),
             "memory_seen": os.path.getmtime(path) - 600},
            {"kind": "job", "role": "assistant", "at": self.at(-30),
             "memory_seen": os.path.getmtime(path)},
            {"kind": "notice", "role": "assistant", "at": self.at(-20),
             "memory_seen": os.path.getmtime(path)},
        ]}
        self.assertTrue(self.say.memory_moved(doc))


class Stamping(MemoryTestCase):
    """`memory_seen` is written onto every assistant turn a runner appends."""

    def setUp(self):
        super().setUp()
        os.makedirs(os.path.join(self.tmp, "threads"))
        os.makedirs(os.path.join(self.tmp, "jarvis", "days"))

    def chat_turn(self, tid="2026-08-25-a41f"):
        """One whole chat turn, answered, from the record and back onto it."""
        self.lane_tree("env")
        seen = {}
        lane_dir = os.path.join(self.store, ".taint", "env")
        self.chat.subprocess = FakeSubprocess(answerer(seen, lane_dir))
        self.chat.write_thread(tid, {"model": "sonnet", "turns": [
            {"role": "user", "text": "what do you remember",
             "at": self.at(-10)}]})
        self.chat.answer(tid)
        return seen, self.chat.read_thread(tid)["turns"][-1]

    def say_turn(self, day="2026-08-25"):
        """One whole say turn, answered, with no fold owed."""
        self.lane_tree("sayenv")
        seen = {}
        lane_dir = os.path.join(self.store, ".taint", "sayenv")
        self.say.subprocess = FakeSubprocess(answerer(seen, lane_dir))
        self.say.write_day(day, {"model": "sonnet", "turns": [
            {"kind": "say", "role": "user", "text": "what do you remember",
             "at": self.at(-10)}]})
        self.say.answer(day)
        return seen, self.say.read_day(day)["turns"][-1]

    def test_the_chat_turn_records_the_journal_it_was_built_from(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        path = self.journal(age_s=600)
        seen, turn = self.chat_turn()
        # What was actually sent, beside what was recorded about it: the stamp
        # is only meaningful as an account of the block this prompt carried.
        prompt = seen["procs"][0].stdin.text
        self.assertTrue(prompt.startswith("## what you remember"))
        self.assertIn("charon-owner-brevity -- short answers", prompt)
        self.assertTrue(seen["procs"][0].stdin.closed)
        self.assertEqual(turn["role"], "assistant")
        self.assertEqual(turn["memory_seen"], os.path.getmtime(path))

    def test_the_say_turn_records_the_journal_it_was_built_from(self):
        path = self.journal(age_s=600)
        _, turn = self.say_turn()
        self.assertEqual(turn["role"], "assistant")
        self.assertEqual(turn["memory_seen"], os.path.getmtime(path))

    def test_a_store_that_has_never_been_written_stamps_zero(self):
        # 0.0 is the true statement that there was nothing to look at, and it
        # is what makes the first op after it read as newer.
        for _, turn in (self.chat_turn(), self.say_turn()):
            self.assertEqual(turn["memory_seen"], 0.0)

    def test_a_write_during_the_turn_is_newer_than_the_stamp(self):
        # The whole reason the stamp is read before the prompt is built: an op
        # that lands while the session is running must come back as movement.
        self.journal(age_s=600)
        _, turn = self.chat_turn()
        self.journal()
        doc = {"turns": [turn]}
        self.assertTrue(self.chat.memory_moved(doc))


class Composition(MemoryTestCase):
    """`build_prompt` on all four shapes, and the untagged invariant."""

    def chat_doc(self):
        return {"turns": [
            {"role": "user", "text": "what is the box doing",
             "at": self.at(-1200)},
            {"role": "assistant", "text": "idle", "at": self.at(-1100)},
            {"role": "user", "text": "@box and now", "at": self.at(-10)},
        ]}

    def say_doc(self):
        return {"turns": [
            {"kind": "say", "role": "user", "text": "morning",
             "at": self.at(-1200)},
            {"kind": "say", "role": "assistant", "text": "morning",
             "at": self.at(-1100)},
            {"kind": "say", "role": "user", "text": "and now",
             "at": self.at(-10)},
        ]}

    def test_chat_fresh_is_memory_then_tags_then_fold_then_text(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        text = "@box and now"
        prompt = self.chat.build_prompt(self.chat_doc(), text, False)
        self.assertTrue(prompt.startswith("## what you remember"))
        self.assertLess(prompt.index("## tagged context"),
                        prompt.index("## earlier in this conversation"))
        self.assertLess(prompt.index("## earlier in this conversation"),
                        prompt.index(text))
        self.assertTrue(prompt.endswith(text))

    def test_chat_resumed_is_memory_then_tags_then_text(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        self.journal()
        text = "@box and now"
        prompt = self.chat.build_prompt(self.chat_doc(), text, True)
        self.assertTrue(prompt.startswith("## what you remember"))
        self.assertNotIn("## earlier in this conversation", prompt)
        self.assertLess(prompt.index("## tagged context"), prompt.index(text))
        self.assertTrue(prompt.endswith(text))

    def test_say_fresh_is_memory_then_prior_context_then_text(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        text = "and now"
        prompt = self.say.build_prompt(self.say_doc(), text, False)
        self.assertTrue(prompt.startswith("## what you remember"))
        self.assertLess(prompt.index("## earlier today"), prompt.index(text))
        self.assertTrue(prompt.endswith(text))

    def test_say_resumed_is_memory_then_text(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        self.journal()
        text = "and now"
        prompt = self.say.build_prompt(self.say_doc(), text, True)
        self.assertTrue(prompt.startswith("## what you remember"))
        self.assertNotIn("## earlier today", prompt)
        self.assertTrue(prompt.endswith(text))

    def test_a_resumed_turn_that_has_seen_the_store_pays_nothing(self):
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        path = self.journal(age_s=600)
        doc = self.chat_doc()
        doc["turns"][1]["memory_seen"] = os.path.getmtime(path)
        self.assertEqual(self.chat.build_prompt(doc, "and now", True),
                         "and now")

    def test_an_untagged_turn_carries_the_block_and_nothing_else_new(self):
        # The re-baselined invariant, stated as the equation it is: what a turn
        # renders now is exactly what it rendered before this feature, with the
        # standing block in front of it. Measured by taking the before against
        # an empty store, which is the same code path a box with no memory
        # runs.
        chat_doc, say_doc = self.chat_doc(), self.say_doc()
        self.journal(age_s=600)
        before = {
            ("chat", False): self.chat.build_prompt(chat_doc, "and now", False),
            ("chat", True): self.chat.build_prompt(chat_doc, "and now", True),
            ("say", False): self.say.build_prompt(say_doc, "and now", False),
            ("say", True): self.say.build_prompt(say_doc, "and now", True),
        }
        self.entry("charon-owner-brevity", "short answers", self.at(-60))
        # The store moved, so the resumed shapes are carrying it this turn too.
        self.journal()
        for (lane, resuming), plain in before.items():
            module = self.chat if lane == "chat" else self.say
            doc = chat_doc if lane == "chat" else say_doc
            block = module.memory_context()
            self.assertEqual(module.build_prompt(doc, "and now", resuming),
                             f"{block}\n{plain}", f"{lane} resuming={resuming}")


class ToolLines(MemoryTestCase):
    """A memory op is composed, not clipped, and a write never falls off."""

    def copies(self):
        return (("chat", self.chat), ("say", self.say))

    def call(self, module, verb, name=None, tail=""):
        argv = f"{module.MEMORY_BIN} {verb}"
        if name:
            argv += f" {name}"
        return {"command": argv + tail}

    def test_the_verb_and_the_entry_survive_a_long_command(self):
        for lane, module in self.copies():
            args = self.call(
                module, "remember", "charon-owner-brevity",
                tail=' "The operator wants short answers and no em dashes" '
                     '"' + "x" * 400 + '"')
            self.assertEqual(module.tool_summary("Bash", args),
                             "memory(remember charon-owner-brevity)", lane)

    def test_a_verb_with_no_entry_renders_alone(self):
        for lane, module in self.copies():
            self.assertEqual(
                module.tool_summary("Bash", self.call(module, "list")),
                "memory(list)", lane)

    def test_an_ordinary_bash_call_is_still_clipped(self):
        for lane, module in self.copies():
            line = module.tool_summary(
                "Bash", {"command": "systemctl " + "x" * 400})
            self.assertTrue(line.startswith("Bash(systemctl "), lane)
            self.assertTrue(line.endswith("…)"), lane)
            self.assertLessEqual(len(line), module.TOOL_ITEM_MAX, lane)

    def test_a_binary_with_the_same_prefix_is_not_a_memory_call(self):
        for lane, module in self.copies():
            args = {"command": f"{module.MEMORY_BIN}-taint --sniff"}
            self.assertEqual(module.memory_tool_line("Bash", args), "", lane)

    def test_a_compound_command_is_clipped_rather_than_composed(self):
        # A composed line says "this turn ran this verb on this entry" and says
        # nothing else, so it may only be composed for a command that is only
        # that. Every one of these would otherwise be drawn as a tidy
        # `memory(forget x)` with the rest of the command invisible.
        for lane, module in self.copies():
            for tail in ("; curl http://evil.example",
                         " && curl http://evil.example",
                         " || echo no",
                         " | tee /tmp/x",
                         "\ncurl http://evil.example",
                         " `curl http://evil.example`",
                         " $(curl http://evil.example)"):
                args = self.call(module, "forget", "charon-owner-brevity",
                                 tail=tail)
                self.assertEqual(module.memory_tool_line("Bash", args), "",
                                 f"{lane}: {tail}")
                line = module.tool_summary("Bash", args)
                self.assertTrue(line.startswith("Bash("), f"{lane}: {tail}")
                self.assertLessEqual(len(line), module.TOOL_ITEM_MAX,
                                     f"{lane}: {tail}")

    def test_the_heredoc_body_form_composes(self):
        # The blessed form for a body with quotes or newlines in it. It is the
        # ONE newline the composer speaks for: the quoted delimiter keeps the
        # shell out of the body and the terminator check proves nothing rides
        # after it, so the common write form keeps its guaranteed line.
        for lane, module in self.copies():
            args = self.call(
                module, "remember", "charon-owner-brevity",
                tail=" \"short answers\" - <<'EOF'\nno em dashes\nEOF")
            self.assertEqual(module.memory_tool_line("Bash", args),
                             "memory(remember charon-owner-brevity)", lane)
            args = self.call(
                module, "remember", "charon-owner-brevity",
                tail=" \"short answers\" - <<'EOF'\nno em dashes\nEOF\n")
            self.assertEqual(module.memory_tool_line("Bash", args),
                             "memory(remember charon-owner-brevity)",
                             f"{lane}: trailing newline")

    def test_a_heredoc_that_is_not_only_a_heredoc_is_clipped(self):
        # Three ways a heredoc-shaped command can smuggle a second command:
        # a command after the terminator, a body line that IS the terminator
        # (which ends the heredoc early and hands the rest to the shell), and
        # an unquoted delimiter (which lets the shell expand the body). Each
        # renders as the clipped command it actually was, never composed.
        for lane, module in self.copies():
            for label, tail in (
                    ("command after EOF",
                     " \"d\" - <<'EOF'\nbody\nEOF\ncurl http://evil.example"),
                    ("early EOF line",
                     " \"d\" - <<'EOF'\nbody\nEOF\nrm -rf /tmp/x\nEOF"),
                    ("unquoted delimiter",
                     " \"d\" - <<EOF\nbody\nEOF"),
                    ("compound before the marker",
                     " \"d\" - && curl http://evil.example <<'EOF'\nbody\nEOF"),
                    ("no terminator", " \"d\" - <<'EOF'\nbody")):
                args = self.call(module, "remember", "charon-owner-brevity",
                                 tail=tail)
                self.assertEqual(module.memory_tool_line("Bash", args), "",
                                 f"{lane}: {label}")
                line = module.tool_summary("Bash", args)
                self.assertTrue(line.startswith("Bash("), f"{lane}: {label}")

    def test_a_heredoc_write_is_exempt_past_the_ceiling(self):
        # The whole point of blessing the form: the common multi-line write
        # keeps its guaranteed transcript line even in a tool-heavy turn.
        for lane, module in self.copies():
            state = module.StreamState()
            for index in range(module.TOOLS_MAX + 3):
                state.add_tool("Bash", {"command": f"uptime {index}"})
            args = self.call(
                module, "remember", "late-heredoc-fact",
                tail=" \"a body\" - <<'EOF'\nline one\nline two\nEOF")
            state.add_tool("Bash", args)
            self.assertEqual(state.tools[-1],
                             "memory(remember late-heredoc-fact)", lane)

    def test_a_memory_write_lands_past_the_tool_ceiling(self):
        for lane, module in self.copies():
            state = module.StreamState()
            for index in range(module.TOOLS_MAX + 5):
                state.add_tool("Bash", {"command": f"uptime {index}"})
            self.assertEqual(len(state.tools), module.TOOLS_MAX, lane)
            state.add_tool("Bash", self.call(module, "remember", "late-fact"))
            self.assertEqual(state.tools[-1], "memory(remember late-fact)",
                             lane)
            self.assertEqual(len(state.tools), module.TOOLS_MAX + 1, lane)

    def test_the_exemption_is_bounded(self):
        # The exemption is the one line that cannot be dropped, so an unbounded
        # one would be a way to flood the list with exactly those. Past the
        # bound a write takes its chances with the ceiling like anything else.
        for lane, module in self.copies():
            state = module.StreamState()
            for index in range(module.TOOLS_MAX):
                state.add_tool("Bash", {"command": f"uptime {index}"})
            for index in range(module.MEMORY_TOOLS_EXEMPT + 4):
                state.add_tool("Bash",
                               self.call(module, "revise", f"fact-{index}"))
            self.assertEqual(len(state.tools),
                             module.TOOLS_MAX + module.MEMORY_TOOLS_EXEMPT,
                             lane)
            self.assertEqual(state.tools[-1],
                             f"memory(revise fact-{module.MEMORY_TOOLS_EXEMPT - 1})",
                             lane)

    def test_all_three_write_verbs_are_exempt_and_no_others(self):
        for lane, module in self.copies():
            for verb in ("remember", "revise", "forget"):
                state = module.StreamState()
                for index in range(module.TOOLS_MAX):
                    state.add_tool("Bash", {"command": f"uptime {index}"})
                state.add_tool("Bash", self.call(module, verb, "a-fact"))
                self.assertEqual(state.tools[-1], f"memory({verb} a-fact)",
                                 f"{lane}: {verb}")
            for verb in ("list", "show", "taint"):
                state = module.StreamState()
                for index in range(module.TOOLS_MAX):
                    state.add_tool("Bash", {"command": f"uptime {index}"})
                state.add_tool("Bash", self.call(module, verb, "a-fact"))
                self.assertEqual(len(state.tools), module.TOOLS_MAX,
                                 f"{lane}: {verb}")

    def test_a_read_verb_under_the_ceiling_is_still_composed(self):
        # It obeys the cap; it is not clipped. The two are separate rules.
        for lane, module in self.copies():
            state = module.StreamState()
            state.add_tool("Bash", self.call(module, "list"))
            self.assertEqual(state.tools, ["memory(list)"], lane)


class TaintOrdering(MemoryTestCase):
    """Clear, check, arm, seed, spawn -- asserted at the spawn."""

    def setUp(self):
        super().setUp()
        self.job = load("job_runner", "jarvis-job-runner.py", self.tmp)

    def spawn_chat(self, text, tid="2026-08-25-a41f"):
        """One chat turn, up to the Popen and no further."""
        seen = {}
        lane_dir = os.path.join(self.store, ".taint", "env")
        self.chat.subprocess = FakeSubprocess(watcher(seen, lane_dir))
        doc = {"model": "sonnet", "turns": [
            {"role": "user", "text": text, "at": self.at(-10)}]}
        state, stopped = self.chat.run_turn(tid, doc, text, lambda s: None)
        self.assertFalse(state.ok)
        return seen

    def assertTurnId(self, seen, prefix):
        """The armed file, the exported id and the shape they both have."""
        turn_id = seen["env"].get("MEMORY_TURN_ID")
        self.assertTrue(turn_id.startswith(f"{prefix}-"), turn_id)
        self.assertTrue(NONCE.fullmatch(turn_id[len(prefix) + 1:]), turn_id)
        # Byte for byte, with no newline: bin/memory compares the file's whole
        # content against its own environment variable.
        self.assertEqual(seen["markers"].get("armed"), turn_id)
        return turn_id

    def test_a_tagged_turn_has_its_marker_before_the_session_starts(self):
        # The seed-then-clear inversion this guards against would leave the
        # directory empty right here, on exactly the turns the gate exists for.
        self.lane_tree("env")
        self.stale_markers("env")
        seen = self.spawn_chat("@web what happened today")
        self.assertTrue(seen["markers"])
        self.assertTurnId(seen, "2026-08-25-a41f")
        self.assertIn("tag-web", seen["markers"])
        # The previous turn's markers are gone, and no staging file was left
        # inside the lane directory to read as a marker of its own.
        self.assertNotIn("hook-4021", seen["markers"])
        self.assertEqual(sorted(seen["markers"]), ["armed", "tag-web"])

    def test_a_clean_tag_seeds_nothing(self):
        self.lane_tree("env")
        seen = self.spawn_chat("@box @cite how is the Pi")
        self.assertEqual(sorted(seen["markers"]), ["armed"])

    def test_the_jarvis_tag_is_not_clean(self):
        # `@jarvis` points at jarvis/days, which is where an assistant that
        # fetched a page this morning wrote down what the page said. Reaching
        # that tree is reaching external content one copy later, and one copy
        # later is the laundering the gate exists to refuse.
        self.lane_tree("env")
        seen = self.spawn_chat("@jarvis what did you do today")
        self.assertEqual(sorted(seen["markers"]), ["armed", "tag-jarvis"])

    def test_an_unknown_tag_would_taint_by_omission(self):
        # The clean set is inverted on purpose, so this asserts the direction
        # rather than a word: a tag outside it seeds, whatever it turns out to
        # mean later.
        self.lane_tree("env")
        seen = self.spawn_chat("@today what is left")
        self.assertEqual(sorted(seen["markers"]), ["armed", "tag-today"])

    def test_a_seed_that_will_not_land_takes_armed_down_with_it(self):
        # A full or read-only disk, simulated at the one function that touches
        # it. The dangerous shape is the turn that is armed, tagged `@web`, and
        # carrying no marker to say so -- the gate open on exactly the turn it
        # exists for. It has to land closed instead.
        self.lane_tree("env")
        real = self.chat._taint_mark

        def only_armed(name, body=""):
            return real(name, body) if name == "armed" else False

        self.chat._taint_mark = only_armed
        seen = self.spawn_chat("@web what happened today")
        self.assertEqual(seen["markers"], {})

    def test_the_turn_id_travels_in_a_copied_environment(self):
        self.lane_tree("env")
        seen = self.spawn_chat("plain question")
        self.assertTurnId(seen, "2026-08-25-a41f")
        # The thread travels beside it, plain: it is what the entry's
        # frontmatter records, so the tool never takes the nonce apart.
        self.assertEqual(seen["env"].get("MEMORY_THREAD"), "2026-08-25-a41f")
        self.assertEqual(seen["cwd"], os.path.join(self.tmp, "env"))
        # Copied, not mutated: this process drains a queue and the next turn
        # must not inherit this one's id.
        self.assertNotIn("MEMORY_TURN_ID", os.environ)
        self.assertNotIn("MEMORY_THREAD", os.environ)

    def test_every_spawn_mints_its_own_id(self):
        # The thread id is the same string for every turn of a conversation and
        # is readable from every lane, so a marker left by turn nine must not
        # match turn ten.
        self.lane_tree("env")
        first = self.spawn_chat("one")["env"]["MEMORY_TURN_ID"]
        second = self.spawn_chat("two")["env"]["MEMORY_TURN_ID"]
        self.assertNotEqual(first, second)

    def test_missing_hooks_disarm_the_gate_closed(self):
        self.lane_tree("env", hooks=False)
        self.stale_markers("env")
        seen = self.spawn_chat("@web what happened today")
        # Nothing to match against, so the tool refuses every write verb -- and
        # the stale markers were still cleared, because the clear runs first.
        self.assertNotIn("armed", seen["markers"])
        self.assertEqual(seen["markers"], {})

    def test_a_missing_taint_binary_disarms_the_gate_closed(self):
        self.lane_tree("env", executable=False)
        seen = self.spawn_chat("plain question")
        self.assertEqual(seen["markers"], {})

    def test_a_missing_lane_tree_self_heals(self):
        self.lane_tree("env")
        shutil.rmtree(os.path.join(self.store, ".taint"), ignore_errors=True)
        seen = self.spawn_chat("plain question")
        self.assertTurnId(seen, "2026-08-25-a41f")

    def test_the_say_lane_arms_the_session_a_person_is_talking_to(self):
        self.lane_tree("sayenv")
        self.stale_markers("sayenv")
        seen = {}
        lane_dir = os.path.join(self.store, ".taint", "sayenv")
        self.say.subprocess = FakeSubprocess(watcher(seen, lane_dir))
        doc = {"model": "sonnet", "turns": [
            {"kind": "say", "role": "user", "text": "and now",
             "at": self.at(-10)}]}
        state, stopped = self.say.run_turn("2026-08-25", doc, "and now", None)
        self.assertFalse(state.ok)
        self.assertEqual(sorted(seen["markers"]), ["armed"])
        self.assertTurnId(seen, "2026-08-25")
        self.assertEqual(seen["env"].get("MEMORY_THREAD"), "2026-08-25")
        self.assertEqual(seen["cwd"], os.path.join(self.tmp, "sayenv"))

    def test_the_fold_is_never_armed(self):
        # The fold's entire input is the day's transcript, which is where every
        # page the assistant fetched today was written down. Arming it would
        # hand write verbs to the one session in that file whose input is
        # already-fetched content. It still clears, because a marker outliving
        # the turn that made it refuses somebody else's write.
        self.lane_tree("sayenv")
        self.stale_markers("sayenv")
        seen = {}
        lane_dir = os.path.join(self.store, ".taint", "sayenv")
        self.say.subprocess = FakeSubprocess(watcher(seen, lane_dir))
        digest, stopped = self.say.make_digest(
            "2026-08-25", {"model": "sonnet"}, "the morning, quoted")
        self.assertIsNone(digest)
        self.assertEqual(seen["markers"], {})
        self.assertNotIn("MEMORY_TURN_ID", seen["env"])
        self.assertNotIn("MEMORY_THREAD", seen["env"])

    def test_a_turn_that_folds_first_arms_only_the_second_spawn(self):
        # The same two facts through the real path: `answer` folds a pending
        # compaction and then answers, and the difference between the two
        # spawns is the whole of this decision.
        self.lane_tree("sayenv")
        os.makedirs(os.path.join(self.tmp, "jarvis", "days"))
        seen = {}
        lane_dir = os.path.join(self.store, ".taint", "sayenv")
        self.say.subprocess = FakeSubprocess(answerer(seen, lane_dir))
        day = "2026-08-25"
        self.say.write_day(day, {
            "model": "sonnet",
            "compactions": [{"at": self.at(-600)}],
            "turns": [
                {"kind": "say", "role": "user", "text": "morning",
                 "at": self.at(-1200)},
                {"kind": "say", "role": "assistant", "text": "morning",
                 "at": self.at(-1100)},
                {"kind": "say", "role": "user", "text": "and now",
                 "at": self.at(-10)},
            ]})
        self.say.answer(day)
        fold, answer = seen["spawns"]
        self.assertEqual(fold["markers"], {})
        self.assertNotIn("MEMORY_TURN_ID", fold["env"])
        self.assertNotIn("MEMORY_THREAD", fold["env"])
        self.assertTrue(answer["markers"].get("armed", "").startswith(day))
        self.assertEqual(answer["env"].get("MEMORY_TURN_ID"),
                         answer["markers"]["armed"])
        self.assertEqual(answer["env"].get("MEMORY_THREAD"), day)

    def test_the_work_lane_arms_but_is_handed_no_turn_id(self):
        self.lane_tree("jobenv")
        seen = {}
        lane_dir = os.path.join(self.store, ".taint", "jobenv")
        self.job.subprocess = FakeSubprocess(watcher(seen, lane_dir))
        jid = "2026-08-25-1412-a41f"
        state, stopped = self.job.run_job(jid, {"model": "sonnet"},
                                          "do the thing", lambda s: None)
        self.assertFalse(state.ok)
        self.assertEqual(seen["markers"], {"armed": jid})
        # The armed content is the job id and nothing is ever handed one to
        # match it with, which is what makes this lane read-only by mechanism
        # rather than by rule.
        self.assertNotIn("MEMORY_TURN_ID", seen["env"])
        self.assertNotIn("MEMORY_THREAD", seen["env"])


if __name__ == "__main__":
    unittest.main()
