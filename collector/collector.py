#!/usr/bin/env python3
"""Telemetry collector for the Halftone console.

Polls eight sources on a schedule, holds the last good answer for each, and
serves them as one JSON document with per-source freshness and health. Also
serves the built dashboard and proxies the camera's current frame.

Design notes worth reading before changing anything:

**Stdlib only, no venv, no pip.** The Pi already has python3 for the sleep
monitor and nothing else. Adding a dependency to a box whose job is to sit
still for months costs more than urllib's clumsiness does. Target 3.11 --
no PEP 695 syntax.

**Two independent staleness layers.** `age_s` says how old *our copy* is;
fields inside `data` say whether the upstream itself admits to being stale.
The envelope status is the worse of the two. Without that split, a 3-second
old response from a monitor that has seen nothing for four hours renders as
a green lamp over a dead camera -- which is precisely the failure this whole
program exists to prevent.

**A source that was never configured is not a source in trouble.** That is
the `dormant` status. It never retries, never backs off, and a client should
draw it as "not wired", not as an error.

Run:  python3 collector.py serve
"""

from feature_control import FEATURES, FeatureControl, admit, feature_access

import argparse
import hashlib
import hmac
import http.server
import json
import os
import random
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta
# The one route that has to understand a mail format rather than a file layout:
# an attachment lives inside the raw message and is dug out on demand. Parsing
# is stdlib, like everything else here, and it happens per request rather than
# in the poll loop, so this import costs the panels nothing.
from email import policy as email_policy
from email.parser import BytesParser

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(HERE, "config.json")

DEFAULTS = {
    "api_bind": "127.0.0.1",
    "api_port": 8788,
    "api_token_env": "COLLECTOR_API_TOKEN",
    "state_dir": os.path.join(HERE, "state"),
    "dashboard_dir": os.path.join(HERE, "public"),

    "camera": {
        "enabled": True,
        "base_url": "http://127.0.0.1:8787",
        "token_env": "MONITOR_API_TOKEN",
        "interval_s": 10,
        "stale_after_s": 30,
        # A five-minute-old sleep verdict is a fiction, so it expires hard.
        "drop_after_s": 300,
        "frame_enabled": True,
        "frame_min_interval_s": 8,
    },
    "pihole": {
        "enabled": True,
        # Empty by default: an unconfigured host renders as `dormant` ("not
        # wired") rather than sending probes at whatever happens to sit at a
        # guessed address on a stranger's LAN. Set it in config.json.
        "host": "",
        "scheme": "http",
        "password_env": "PIHOLE_APP_PASSWORD",
        "interval_s": 30,
        "stale_after_s": 120,
        # A daily counter an hour old is still approximately true.
        "drop_after_s": 3600,
    },
    "nodes": {
        "enabled": True,
        "interval_s": 15,
        "timeout_s": 2.0,
        "stale_after_s": 45,
        # Shortest by far, deliberately. A stale counter is roughly true; a
        # stale reachability claim is actively false. "It was up 10 minutes
        # ago" is not evidence it is up now.
        "drop_after_s": 90,
        "temp_caution_c": 70,
        "temp_fault_c": 80,
        "list": [],
    },
    "commits": {
        "enabled": True,
        "token_env": "GITHUB_TOKEN",
        "interval_s": 300,
        "stale_after_s": 1800,
        "drop_after_s": 86400,
        "count": 5,
        # Ask GitHub which repos exist instead of being told. On by default:
        # see the note in CommitsSource for why the default goes this way.
        "discover": True,
        # How many of the most recently pushed repos to actually read commits
        # from. A repo nobody has pushed to cannot hold a recent commit, so
        # reading further down the list buys nothing but API calls.
        "poll_repos": 8,
        # Forks off by default -- syncing a fork bumps its push time to now,
        # which floats other people's commits to the top of the ranking.
        "include_forks": False,
        # Stop spending when the hourly budget gets this low.
        "min_rate_remaining": 50,
        # An explicit list, which wins over discovery when it is non-empty.
        "repos": [],
        # Repos with no remote at all. GitHub structurally cannot see these,
        # so the payload names them rather than quietly under-reporting.
        "untracked": [],
    },
    "healthchecks": {
        "enabled": True,
        # How often we ask "is today's run still missing?", NOT how often the
        # checks run. The checks run once per local date; this is only the
        # resolution at which the date rollover is noticed.
        "interval_s": 600,
        "stale_after_s": 3600,
        # Three days. The history is the value here, not the last poll, and a
        # box that was off over a long weekend should come back with its
        # ninety-day strip intact rather than an empty panel.
        "drop_after_s": 259200,
        "history_days": 90,
        "temp_max_c": 75,
        "root_disk_max_pct": 90,
        "state_disk_max_pct": 90,
        "mem_min_available_mb": 200,
        # The one Zero W touchpoint in this source, kept flat and prefixed so
        # retiring that box is a matter of deleting four keys and one helper.
        # Flat because the config merge is one level deep: a nested "zero"
        # block would be replaced wholesale by any box that overrode one key.
        "zero_enabled": True,
        # Empty by default, like pihole.host: no address is guessed on a box
        # that has not been told where its second node lives.
        "zero_addr": "",
        "zero_port": 53,
        "zero_timeout_s": 2.0,
    },
    "cmo": {
        "enabled": True,
        # Reading four small local files, so the cost is a few stats. Fast
        # enough that the heartbeat's own "running" state is visible while a
        # run is happening rather than only after it ends.
        "interval_s": 60,
        "stale_after_s": 3600,
        # Three days, like healthchecks and for the same reason: this source
        # answers once a day, so a copy older than a single run is still the
        # last true thing anyone knows, and dropping it would blank the panel
        # over a long weekend.
        "drop_after_s": 259200,
        "base_dir": "/home/pi/charon-mail",
        # Days in the items-per-day strip, and the most briefings to offer as
        # links. Both are display windows, not retention: nothing is deleted.
        # The briefings window is a quarter rather than a fortnight because the
        # console's archive page lists them all, and an archive that silently
        # forgets the tenth-oldest day is a filing cabinet with a hole in it.
        # Still bounded: this is a scandir on every poll, not a directory walk.
        "history_days": 14,
        "briefings_max": 90,
        # 90 minutes. The wrapper's own wall clock is 75 minutes per attempt
        # with one retry, so anything past this is a run that died without
        # getting to write its own epitaph.
        "running_stuck_after_s": 5400,
        # How much of the dedup ledger's tail to read. It is append-mostly and
        # compaction is weekly, so an uncompacted month is megabytes and this
        # runs every interval on a Pi.
        "seen_items_max_bytes": 1048576,
        # Flat, like healthchecks' zero_* keys and for the same reason: the
        # config merge is one level deep, so a nested block would be replaced
        # wholesale by a box that overrode a single key inside it.
    },
    "mail": {
        "enabled": True,
        # Reading a directory of small local files, like cmo, so the cost is a
        # scandir and a few hundred opens. The poller's own timer is every five
        # minutes; this is only how quickly its work becomes visible.
        "interval_s": 60,
        # Its own base_dir rather than cmo's, even though today they are the
        # same directory: the config merge is one level deep, so a box that
        # moved one of the two would otherwise move both.
        "base_dir": "/home/pi/charon-mail",
        # A display window like briefings_max, not retention: the message route
        # serves anything this list does not carry, and nothing here deletes.
        "list_max": 50,
        # Twenty minutes, which is four missed fires of a five-minute timer.
        # This is the mailbox's own staleness -- how long the inbox on screen
        # may go without a poll -- and it is a different question from how old
        # our copy of it is, which the envelope already answers.
        "poll_stale_after_s": 1200,
    },
    "messages": {
        "enabled": True,
        # Reading a directory of small local files, like mail, so the cost is a
        # scandir and a few hundred opens. Faster than mail's because a text is
        # a text somebody is waiting on: thirty seconds is how long a reply can
        # sit on the Pi before it is on screen.
        "interval_s": 30,
        # Its own base_dir rather than mail's, even though today they are the
        # same directory: the config merge is one level deep, so a box that
        # moved one of the two would otherwise move both.
        "base_dir": "/home/pi/charon-mail",
        # A display window, not retention: the thread route serves anything this
        # list does not carry, and nothing here deletes.
        "list_max": 50,
        # Two minutes, which is four missed heartbeats. This is the Bridge's own
        # silence -- how long the Mac may go without saying it is alive -- and it
        # is a different question from how old our copy of the store is, which
        # the envelope already answers. A sleeping laptop crosses this in two
        # minutes and that is correct: the stream really has paused.
        "bridge_stale_after_s": 120,
    },
    # The chat assistant's threads. **Not a source**, which is why this block
    # has no interval_s, no stale_after_s and no entry in `Collector.sources`:
    # nothing here is polled and nothing here joins the telemetry payload. A
    # conversation is interactive -- the console asks for the thread it is
    # looking at, on its own cadence, the way it already asks for a briefing --
    # and a chat that also arrived once a minute in a document about disk
    # temperature would be a second copy of the same state going stale on its
    # own schedule.
    #
    # So the only thing configured here is where the threads live. The Pi path
    # is the documented default; a Mac running this for a smoke test overrides
    # it in config.json and needs nothing else.
    "chat": {
        "base_dir": "/home/pi/halftone-chat",
    },
}

USER_AGENT = "halftone-collector/1"


# --- small shared helpers ----------------------------------------------------

def stamp():
    return datetime.now().isoformat(timespec="seconds")


def iso(dt):
    return dt.isoformat(timespec="seconds") if dt else None


def load_env(path=None):
    """Read .env without overriding anything already in the environment.

    Same contract as the sleep monitor's: systemd's EnvironmentFile wins, and
    this is the fallback for running by hand.
    """
    path = path or os.path.join(HERE, ".env")
    if not os.path.exists(path):
        return
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            key = key.strip()
            if key and key not in os.environ:
                os.environ[key] = val.strip()


def load_config(path=CONFIG_PATH):
    """Merge config.json over DEFAULTS, one level deep for nested blocks.

    One level is deliberate and matches the monitor: it means adding a new key
    to DEFAULTS needs no action on any deployed box, because the machine's own
    config.json only carries what it actually overrides.
    """
    cfg = {k: (dict(v) if isinstance(v, dict) else v) for k, v in DEFAULTS.items()}
    if os.path.exists(path):
        with open(path) as fh:
            user = json.load(fh)
        for key, val in user.items():
            if isinstance(val, dict) and isinstance(cfg.get(key), dict):
                cfg[key].update(val)
            else:
                cfg[key] = val
    return cfg


def write_atomic(path, text):
    """Write via tmp + os.replace so a reader never sees a half-written file."""
    tmp = f"{path}.tmp"
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(tmp, "w") as fh:
            fh.write(text)
        os.replace(tmp, path)
        return True
    except OSError:
        try:
            os.remove(tmp)
        except OSError:
            pass
        return False


def http_json(url, headers=None, timeout=6.0, method="GET", body=None):
    """GET/POST JSON. Returns (status, parsed_or_none, headers).

    Raises only for genuine transport failures; HTTP error statuses come back
    as values because several of them are meaningful here (401 from Pi-hole's
    /api/auth is how you detect v6, 304 from GitHub means "unchanged").
    """
    req = urllib.request.Request(url, method=method)
    req.add_header("User-Agent", USER_AGENT)
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, data=data, timeout=timeout) as resp:
            raw = resp.read()
            try:
                parsed = json.loads(raw) if raw else None
            except ValueError:
                parsed = None
            return resp.status, parsed, dict(resp.headers)
    except urllib.error.HTTPError as exc:
        raw = exc.read()
        try:
            parsed = json.loads(raw) if raw else None
        except ValueError:
            parsed = None
        return exc.code, parsed, dict(exc.headers or {})


def tcp_open(host, port, timeout=2.0):
    """Reachability without root. Returns (ok, rtt_ms).

    A TCP connect, not ICMP: ping needs CAP_NET_RAW or a setuid binary, and a
    web service should need neither. Pinned to AF_INET because this Pi has
    global IPv6 and a dual-stack name would try v6 first and burn the budget.
    """
    started = time.monotonic()
    try:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            sock.connect((host, int(port)))
        return True, round((time.monotonic() - started) * 1000, 1)
    except OSError:
        return False, None


def read_first_line(path):
    try:
        with open(path) as fh:
            return fh.readline().strip()
    except OSError:
        return None


def self_stats():
    """Uptime, load and temperature for the box we are running on.

    Free, and more truthful than a loopback TCP connect: the fact that this
    process answered the request is already proof the host is up.
    """
    out = {"uptime_s": None, "load1": None, "temp_c": None}
    line = read_first_line("/proc/uptime")
    if line:
        try:
            out["uptime_s"] = int(float(line.split()[0]))
        except (ValueError, IndexError):
            pass
    line = read_first_line("/proc/loadavg")
    if line:
        try:
            out["load1"] = float(line.split()[0])
        except (ValueError, IndexError):
            pass
    for probe in ("/sys/class/thermal/thermal_zone0/temp",):
        line = read_first_line(probe)
        if line:
            try:
                out["temp_c"] = round(int(line) / 1000.0, 1)
                break
            except ValueError:
                pass
    return out


# --- the source framework ----------------------------------------------------

class Source:
    """One polled feed, with its own cadence, cache, backoff and health.

    Subclasses implement `configured` and `fetch`. Everything else -- status
    arithmetic, last-known-good, backoff, the wire envelope -- lives here so
    that five sources cannot drift into five different ideas of what "stale"
    means.
    """

    name = "source"

    def __init__(self, cfg, block):
        self.cfg = cfg
        self.block = block
        self.interval = float(block.get("interval_s", 60))
        self.stale_after = float(block.get("stale_after_s", self.interval * 4))
        self.drop_after = float(block.get("drop_after_s", self.interval * 20))
        self.enabled = bool(block.get("enabled", True))

        self.lock = threading.Lock()
        self.data = None
        self.fetched_at = None
        self.error = None
        self.failures = 0
        self.next_at = 0.0

    # -- to implement --------------------------------------------------------

    @property
    def configured(self):
        """False when this source has never been set up (no key, no host).

        Distinct from broken. A dormant source is a configuration statement,
        so it is never retried and never logged as a failure.
        """
        return True

    def why_dormant(self):
        return "not configured"

    def fetch(self):
        raise NotImplementedError

    # -- the machinery -------------------------------------------------------

    def backoff(self):
        """Exponential from the base interval, capped, with jitter.

        Jitter matters more than it looks: without it, five sources that all
        started together stay in lockstep forever after a restart and hammer
        the network in bursts.
        """
        base = self.interval * (2 ** min(self.failures, 6))
        capped = min(base, max(self.interval * 20, 900))
        return capped * random.uniform(0.9, 1.1)

    def poll_once(self):
        if not self.enabled or not self.configured:
            self.next_at = time.monotonic() + 3600
            return
        try:
            data = self.fetch()
            with self.lock:
                self.data = data
                self.fetched_at = datetime.now()
                self.error = None
                self.failures = 0
            self.next_at = time.monotonic() + self.interval * random.uniform(0.9, 1.1)
        except Exception as exc:  # noqa: BLE001 - a source must never kill the loop
            with self.lock:
                self.failures += 1
                self.error = {"kind": type(exc).__name__, "message": str(exc)[:300],
                              "at": iso(datetime.now())}
            wait = self.backoff()
            self.next_at = time.monotonic() + wait
            print(f"{stamp()}  {self.name}: {type(exc).__name__}: "
                  f"{str(exc)[:160]} (retry in {wait:.0f}s)", file=sys.stderr)

    def semantic_status(self, data):
        """Override to downgrade based on what the payload itself admits.

        This is the second staleness layer. A perfectly fresh fetch can carry
        an upstream's confession that it has no idea what is going on.

        Return None, a status string, or a ("status", "why") pair. The reason
        travels to the client because `age_s` structurally cannot express it:
        when we fetch every 10s, a camera dead for two hours still reports
        age_s: 3, and a client with only that number renders "stale 3s ago"
        over a two-hour outage. The number is true and the sentence is a lie.
        """
        return None

    def snapshot(self):
        with self.lock:
            data, fetched_at = self.data, self.fetched_at
            error, failures = self.error, self.failures

        if not self.enabled or not self.configured:
            return {
                "status": "dormant",
                "fetched_at": None, "age_s": None, "interval_s": self.interval,
                "consecutive_failures": 0,
                "error": {"kind": "not_configured", "message": self.why_dormant()},
                "data": None,
            }

        age = (datetime.now() - fetched_at).total_seconds() if fetched_at else None

        # Null when the status came from transport age -- the client's own age
        # rendering is correct in that case and a duplicated sentence is worse
        # than none. Non-null only when the payload itself confessed.
        reason = None

        if data is None:
            status = "error"
        elif age is not None and age > self.drop_after:
            status = "error"
        elif age is not None and age > self.stale_after:
            status = "stale"
        else:
            sem = self.semantic_status(data)
            if isinstance(sem, tuple):
                sem, reason = sem
            status = sem or "ok"

        # A source that is currently failing but still holds a usable cached
        # answer is degraded, not dead -- the client should show the old value
        # with its age rather than an empty panel.
        if error and status == "ok":
            status = "degraded"

        return {
            "status": status,
            "fetched_at": iso(fetched_at),
            "age_s": int(age) if age is not None else None,
            "stale_reason": reason,
            "interval_s": self.interval,
            "next_attempt_in_s": max(0, int(self.next_at - time.monotonic())),
            "consecutive_failures": failures,
            "error": error,
            "data": data,
        }


_SECRET_QS = re.compile(r"([?&](?:k|token|sid|password)=)[^&\s]+", re.I)


def redact_secrets(line):
    """Strip credential-bearing query params out of anything we log.

    A secret in a URL is already the weak part of the ?k= design -- it is
    visible in browser history and in any proxy between here and there. The
    part we control is not making it permanent: journald keeps logs across
    reboots and ships them into any journal export or backup, so an
    unredacted request line turns a session-mint token into a durable one.
    """
    return _SECRET_QS.sub(r"\1<redacted>", line)


def human_span(seconds):
    if seconds is None:
        return None
    seconds = int(seconds)
    if seconds < 60:
        return f"{seconds}s"
    if seconds < 3600:
        return f"{seconds // 60}m"
    if seconds < 86400:
        return f"{seconds // 3600}h {(seconds % 3600) // 60:02d}m"
    return f"{seconds // 86400}d {(seconds % 86400) // 3600:02d}h"


# --- camera ------------------------------------------------------------------

class CameraSource(Source):
    """The camera monitor's state, and the readiness of its current frame.

    Deliberately reports **stillness**, not sleep. The monitor's own tuner
    reports no clean threshold pair against real labeled data, breathing does
    not register at this ROI, and an empty scene reads as still overnight. So
    the verdict says what was measured and the label says so too. Upgrade the
    wording when `tune` stops disagreeing with the config, not before.
    """

    name = "camera"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.base = (block.get("base_url") or "").rstrip("/")
        self.token = os.environ.get(block.get("token_env") or "", "")

    @property
    def configured(self):
        return bool(self.base and self.token)

    def why_dormant(self):
        if not self.base:
            return "camera.base_url is unset"
        return f"{self.block.get('token_env')} is unset; cannot reach the monitor"

    def fetch(self):
        status, body, _ = http_json(
            f"{self.base}/v1/state",
            headers={"Authorization": f"Bearer {self.token}"})
        if status != 200 or not isinstance(body, dict):
            raise RuntimeError(f"monitor /v1/state returned HTTP {status}")

        mon = body.get("monitor") or {}
        frame = body.get("frame") or {}
        alive = mon.get("alive")
        feed_ok = mon.get("feed_ok")
        log_stale = bool(body.get("stale"))
        state = body.get("state") or "unknown"

        # The three cases the dashboard has to tell apart. They share one
        # staleness and need three different sentences.
        if alive is False:
            cam_state, verdict, tone = "offline", "not being watched", "fault"
        elif feed_ok is False:
            cam_state, verdict, tone = "offline", "camera offline", "fault"
        elif log_stale:
            cam_state, verdict, tone = "stale", "no recent reading", "caution"
        else:
            cam_state = "live"
            elapsed = human_span(body.get("elapsed_s"))
            sess = body.get("session") or {}
            # The merged block's clock, not the per-state one: `elapsed_s`
            # resets on every stir, so an hour of sleep with one reposition
            # would read "still · 3m". Dogs are polyphasic; the block is the
            # number a human wants.
            block = human_span(sess.get("elapsed_s"))
            stirs = sess.get("stirs") or 0
            stir_note = f" · {stirs} stir{'s' if stirs != 1 else ''}" \
                if stirs else ""
            if state == "asleep":
                verdict, tone = f"still · {block or elapsed}{stir_note}", "nominal"
            elif state == "away":
                verdict, tone = "scene reads empty", "standby"
            elif (body.get("presence") or {}).get("reliable") is False:
                # "unknown" with presence distrusted is not a transient: the
                # empty-scene references stopped matching the scene and both
                # away/asleep stay disabled until someone re-baselines. This
                # exact condition once ran five days flying "no reading".
                # Checked before in_stir: a block can be open when the refs
                # go stale, and the outage outranks the nuance.
                verdict, tone = "references stale", "fault"
            elif sess.get("in_stir"):
                # Moving, but inside a sleep block that is still open -- the
                # movement has not yet outlasted the monitor's merge window.
                # Saying "moving" here is the exact miscount the session
                # field exists to prevent.
                verdict, tone = f"stirring · {block}{stir_note}", "nominal"
            elif state == "awake":
                verdict, tone = f"moving · {elapsed}", "default"
            else:
                verdict, tone = "no reading", "fault"

        return {
            "state": state,
            "since": body.get("since"),
            "elapsed_s": body.get("elapsed_s"),
            "last_sample": body.get("last_sample"),
            "last_score": body.get("last_score"),
            "monitor_stale": log_stale,
            "monitor_stale_for_s": body.get("stale_for_s"),
            "monitor": mon,
            "presence": body.get("presence"),
            "session": body.get("session"),
            "frame": {
                "available": bool(frame.get("available")),
                "ts": frame.get("ts"),
                "age_s": frame.get("age_s"),
                # Same-origin path on THIS server. The monitor's own route
                # needs a bearer header, which an <img> cannot send.
                "url": "/v1/camera/latest.jpg" if frame.get("available") else None,
            },
            "display": {
                "camera_state": cam_state,
                "stamp": frame.get("ts") or body.get("last_sample"),
                # "stillness", not "sleep state" -- see the class docstring.
                "verdict": {"label": "stillness", "value": verdict, "tone": tone},
            },
        }

    def semantic_status(self, data):
        # Fresh transport over a dead monitor is still a dead monitor. Each
        # branch carries its own sentence, because "stale" alone sends the
        # client back to age_s -- which here measures how recently we asked,
        # not how long the answer has been useless.
        mon = data.get("monitor") or {}
        if mon.get("alive") is False:
            return "stale", "monitor not running"
        if data.get("monitor_stale"):
            # Cause from feed_ok, duration from monitor_stale_for_s -- never
            # from feed_down_for_s. That one is scoped to the current monitor
            # process, and the watch unit exits every 10 minutes while the feed
            # is down, so it resets forever: a camera unplugged since lunch
            # reports "down 7m" all afternoon. monitor_stale_for_s is measured
            # from the last actual sample and survives the restarts.
            since = human_span(data.get("monitor_stale_for_s"))
            what = "camera feed down" if mon.get("feed_ok") is False else "no sample"
            return "stale", f"{what} {since}" if since else what
        if (data.get("presence") or {}).get("reliable") is False:
            # Fresh transport, live monitor, and no verdicts possible: the
            # references stopped matching the scene, so away/asleep are
            # disabled until an empty scene is re-baselined. Human action is
            # the fix, so it must wear a frame, not pass as healthy.
            return "degraded", ("references stale; re-run reference on an "
                                "empty scene")
        return None


# --- pi-hole -----------------------------------------------------------------

class PiholeSource(Source):
    """Pi-hole v6, with the session held open between polls.

    FTL caps concurrent sessions (default 16). Authenticating on every poll
    would burn through that cap in minutes and start evicting sessions --
    including the browser login of whoever is using the admin UI. So one SID is
    held and only re-issued on 401.

    v5's /admin/api.php is gone in v6; version is detected from the *body
    shape* of /api/auth rather than its status code, because the live box
    answers 401 with a perfectly informative JSON session object.
    """

    name = "pihole"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.host = block.get("host") or ""
        self.scheme = block.get("scheme") or "http"
        self.password = os.environ.get(block.get("password_env") or "", "")
        self.sid = None
        self.api_version = None

    @property
    def configured(self):
        return bool(self.host and self.password)

    def why_dormant(self):
        if not self.host:
            return "pihole.host is unset"
        return (f"{self.block.get('password_env')} is unset; set a Pi-hole "
                f"app password (Settings > Web interface / API)")

    def base(self):
        return f"{self.scheme}://{self.host}"

    def detect_version(self):
        status, body, _ = http_json(f"{self.base()}/api/auth", timeout=5)
        if isinstance(body, dict) and "session" in body:
            return 6
        status, body, _ = http_json(
            f"{self.base()}/admin/api.php?summaryRaw", timeout=5)
        if status == 200 and isinstance(body, dict) and "dns_queries_today" in body:
            return 5
        raise RuntimeError(
            "could not identify the Pi-hole API; neither /api/auth nor "
            "/admin/api.php looked like a known version")

    def authenticate(self):
        status, body, _ = http_json(
            f"{self.base()}/api/auth", method="POST",
            body={"password": self.password}, timeout=6)
        session = (body or {}).get("session") or {}
        if not session.get("valid") or not session.get("sid"):
            raise RuntimeError(f"pi-hole auth rejected (HTTP {status})")
        self.sid = session["sid"]

    def api6(self, path):
        """One authenticated v6 GET, re-authenticating once on 401."""
        if not self.sid:
            self.authenticate()
        url = f"{self.base()}/api/{path.lstrip('/')}"
        status, body, _ = http_json(url, headers={"X-FTL-SID": self.sid}, timeout=6)
        if status == 401:
            self.sid = None
            self.authenticate()
            status, body, _ = http_json(url, headers={"X-FTL-SID": self.sid}, timeout=6)
        if status != 200:
            raise RuntimeError(f"pi-hole {path} returned HTTP {status}")
        return body or {}

    def fetch(self):
        if self.api_version is None:
            self.api_version = self.detect_version()

        if self.api_version == 5:
            status, body, _ = http_json(
                f"{self.base()}/admin/api.php?summaryRaw", timeout=6)
            if status != 200 or not isinstance(body, dict):
                raise RuntimeError(f"pi-hole v5 summary returned HTTP {status}")
            return {
                "api_version": 5,
                "queries_today": body.get("dns_queries_today"),
                "blocked_today": body.get("ads_blocked_today"),
                "block_rate_pct": round(float(body.get("ads_percentage_today") or 0), 1),
                "domains_on_list": body.get("domains_being_blocked"),
                "clients_active": body.get("unique_clients"),
                "top_blocked": None,
                "host_uptime_s": None, "host_cpu_pct": None, "host_mem_pct": None,
            }

        # v6. Every field is read with .get chains: a renamed field should null
        # one metric and mark the source degraded, not blow the whole poll up.
        summary = self.api6("stats/summary")
        queries = summary.get("queries") or {}
        gravity = summary.get("gravity") or {}
        clients = summary.get("clients") or {}

        top_blocked = None
        try:
            top = self.api6("stats/top_domains?blocked=true&count=1")
            items = top.get("domains") or top.get("top_domains") or []
            if items:
                first = items[0]
                top_blocked = first.get("domain") if isinstance(first, dict) else str(first)
        except Exception:  # noqa: BLE001 - a missing extra must not fail the source
            top_blocked = None

        # The Zero W's own vitals, from a call we are already authenticated
        # for -- cheaper and more honest than SSHing from a web service. This
        # is what fills the Zero W's uptime and load in the hardware view
        # without the collector needing shell access to it at all.
        #
        # Path confirmed against the live box: /api/info/system, NOT
        # /api/info/ftl. Note `ftl.%mem` is FTL's own share of memory, not the
        # machine's, so it is named for what it actually measures.
        host = {"host_uptime_s": None, "host_cpu_pct": None,
                "host_cores": None, "host_procs": None,
                "ftl_cpu_pct": None, "ftl_mem_pct": None}
        try:
            sysinfo = (self.api6("info/system") or {}).get("system") or {}
            cpu = sysinfo.get("cpu") or {}
            ftl = sysinfo.get("ftl") or {}
            host = {
                "host_uptime_s": sysinfo.get("uptime"),
                "host_procs": sysinfo.get("procs"),
                "host_cores": cpu.get("nprocs"),
                "host_cpu_pct": round(float(cpu.get("%cpu")), 1)
                if cpu.get("%cpu") is not None else None,
                "ftl_cpu_pct": round(float(ftl.get("%cpu")), 1)
                if ftl.get("%cpu") is not None else None,
                "ftl_mem_pct": round(float(ftl.get("%mem")), 1)
                if ftl.get("%mem") is not None else None,
            }
        except Exception:  # noqa: BLE001 - vitals are a bonus, not the source
            pass

        blocked = queries.get("blocked")
        total = queries.get("total")
        return {
            "api_version": 6,
            "queries_today": total,
            "blocked_today": blocked,
            "block_rate_pct": round(float(queries.get("percent_blocked") or 0), 1),
            "domains_on_list": gravity.get("domains_being_blocked"),
            "clients_active": clients.get("active"),
            "top_blocked": top_blocked,
            **host,
        }

    def semantic_status(self, data):
        # Reached it, but the number that matters did not come back.
        if data.get("blocked_today") is None or data.get("queries_today") is None:
            return "degraded"
        return None


# --- nodes -------------------------------------------------------------------

class NodesSource(Source):
    """Up/down for everything on the LAN worth knowing about.

    Probes the *service*, not the box. A Pi-hole whose FTL has died but whose
    web server still answers on :80 is down for every purpose the house cares
    about -- so the Zero W is probed on :53, which is what it exists to do.
    """

    name = "nodes"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.timeout = float(block.get("timeout_s", 2.0))
        self.nodes = list(block.get("list") or [])
        self.down_since = {}

    @property
    def configured(self):
        return bool(self.nodes)

    def why_dormant(self):
        return "nodes.list is empty"

    def tone_for(self, connected, temp):
        if not connected:
            return "fault", "Offline"
        if temp is not None:
            if temp >= float(self.block.get("temp_fault_c", 80)):
                return "fault", "Hot"
            if temp >= float(self.block.get("temp_caution_c", 70)):
                return "caution", "Warm"
        return "nominal", "Connected"

    def fetch(self):
        out = []
        for node in self.nodes:
            probe = node.get("probe") or "tcp:22"
            addr = node.get("addr") or node.get("host")
            connected, rtt = False, None
            stats = {"uptime_s": None, "load1": None, "temp_c": None}

            if probe == "self":
                # We are answering this request, which is the proof.
                connected, rtt = True, None
                stats = self_stats()
            elif probe.startswith("tcp:"):
                connected, rtt = tcp_open(addr, probe.split(":", 1)[1], self.timeout)

            key = node.get("id") or addr
            if connected:
                self.down_since.pop(key, None)
            else:
                self.down_since.setdefault(key, datetime.now())

            tone, label = self.tone_for(connected, stats["temp_c"])
            # Link strength is a display affordance, not a measurement: three
            # pips when it answered fast, two when slow, none when it did not.
            link = 0 if not connected else (3 if (rtt is None or rtt < 50) else 2)

            out.append({
                "id": key,
                "host": node.get("host"),
                "addr": addr,
                "kind": node.get("kind"),
                "role": node.get("role"),
                "probe": probe,
                "connected": connected,
                "rtt_ms": rtt,
                "uptime_s": stats["uptime_s"],
                "load1": stats["load1"],
                "temp_c": stats["temp_c"],
                "link": link,
                "tone": tone,
                "label": label,
                "down_since": iso(self.down_since.get(key)),
                "checked_at": iso(datetime.now()),
            })

        return {
            "nodes": out,
            "connected": sum(1 for n in out if n["connected"]),
            "total": len(out),
        }


# --- healthchecks ------------------------------------------------------------

class HealthchecksSource(Source):
    """A once-a-day pass over the things that rot slowly, kept as a history.

    Every other source answers "what is true right now". This one answers "has
    anything been quietly getting worse", which is a different question and
    needs a different shape: a strip of days, not a number. Undervoltage, a
    filling disk and a leaking process all look fine at any single instant and
    are obvious across ninety of them.

    **The gate is the local date, on disk, and nothing else.** No run_at hour:
    the checks run the first time a poll notices that today has no entry yet.
    That means a box booted at any hour gets today's row within one interval
    instead of waiting until tomorrow morning, and a box restarted six times an
    afternoon still runs them exactly once, because the date that says "done"
    lives in state_dir rather than in this process. An hour-of-day trigger has
    the opposite pair of failures -- it misses the day entirely if the box is
    off at the appointed minute, and it re-fires on every restart within the
    minute unless you write the same file anyway.

    **A failing check is `degraded`, never `error`.** The fetch succeeded; the
    findings are bad. Collapsing those two would make a full disk look like a
    collector that cannot see the disk, and the panel needs to tell a red row
    apart from a missing one.

    **A check whose instrument is absent is omitted, not failed.** There is no
    `get_throttled` on a Mac and no `/proc/meminfo` either, so those rows simply
    do not appear in a day run from a laptop. Counting an absent thermometer as
    a fever would make the dev box permanently red and train everyone to ignore
    the panel, which is the only real way a health check can fail.
    """

    name = "healthchecks"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.state_dir = cfg["state_dir"]
        self.path = os.path.join(self.state_dir, "healthchecks.json")
        self.history_days = max(1, int(block.get("history_days", 90)))

    # -- the checks ----------------------------------------------------------

    def check_throttled(self):
        """The Pi's own record of undervoltage and thermal capping.

        The single most useful bit on this hardware and the one nothing else
        surfaces: a failing PSU or a tired USB-C cable shows up here as a set
        flag hours before it shows up as corruption. The sysfs file is read
        first because it costs no process; vcgencmd is the fallback for kernels
        that do not export it. Note the two spellings -- sysfs gives bare hex,
        vcgencmd gives `throttled=0x0` -- and that int(x, 16) eats both.
        """
        raw = read_first_line(
            "/sys/devices/platform/soc/soc:firmware/get_throttled")
        if raw is None:
            try:
                out = subprocess.run(["vcgencmd", "get_throttled"],
                                     capture_output=True, text=True, timeout=5)
            except (OSError, subprocess.SubprocessError):
                return None
            if out.returncode != 0:
                return None
            _, _, raw = (out.stdout or "").strip().partition("=")
        raw = raw.strip()
        try:
            flags = int(raw, 16)
        except ValueError:
            return None
        return {
            "id": "throttled", "label": "throttling", "ok": flags == 0,
            # The raw word, not a decoded sentence. Every bit in it means
            # something different and the ones that matter are worth looking up
            # rather than paraphrasing wrongly here.
            "detail": "0x0" if flags == 0 else f"0x{flags:x}",
        }

    def check_soc_temp(self):
        line = read_first_line("/sys/class/thermal/thermal_zone0/temp")
        if line is None:
            return None
        try:
            temp_c = int(line) / 1000.0
        except ValueError:
            return None
        limit = float(self.block.get("temp_max_c", 75))
        return {
            "id": "soc_temp", "label": "soc temp", "ok": temp_c < limit,
            "detail": f"{temp_c:.1f}°C (max {limit:g})",
        }

    def check_disk(self, check_id, label, path, limit):
        """Used percentage of the whole filesystem, straight from statvfs.

        f_bavail, not f_bfree: the difference is the root reserve, which this
        process cannot spend, so counting it as headroom would report space
        that does not exist for the thing actually filling the disk.

        Divided by f_blocks, which is deliberately **not** what `df` prints.
        df divides by used + available, leaving the reserve out of both halves,
        so it reads a few points lower. On the Pi's ext4 root that gap is the
        ~5% reserve and this is the more conservative of the two, which is the
        right direction for a threshold to err in. On an APFS Mac the gap is
        large and meaningless -- every volume in the container shares f_blocks,
        so a dev box reads ~90% used where df says 22%. Raise the limit locally
        if that bothers you; the number is honest about the container.
        """
        try:
            st = os.statvfs(path)
        except OSError:
            return None
        if not st.f_blocks:
            return None
        pct = 100.0 * (1 - st.f_bavail / st.f_blocks)
        free_gib = st.f_bavail * st.f_frsize / (1024 ** 3)
        return {
            "id": check_id, "label": label, "ok": pct < float(limit),
            "detail": f"{pct:.0f}% used · {free_gib:.1f} GiB free",
        }

    def check_memory(self):
        """MemAvailable, not MemFree.

        MemFree on a box that has been up for months is always near zero and
        always alarming for no reason -- the kernel spends idle RAM on page
        cache and hands it straight back on demand. MemAvailable is the
        kernel's own estimate of what a new allocation could actually get,
        which is the number a health check is asking about.
        """
        try:
            with open("/proc/meminfo") as fh:
                for line in fh:
                    if line.startswith("MemAvailable:"):
                        available_mb = int(line.split()[1]) / 1024.0
                        break
                else:
                    return None
        except (OSError, ValueError, IndexError):
            return None
        floor_mb = float(self.block.get("mem_min_available_mb", 200))
        return {
            "id": "memory", "label": "memory", "ok": available_mb > floor_mb,
            "detail": f"{available_mb / 1024:.1f} GiB free",
        }

    def check_zero_dns(self):
        """Whether the house can still resolve names.

        Deliberately the only thing in this source that touches the Zero W, and
        deliberately :53 rather than :80 -- a Pi-hole whose web UI answers but
        whose FTL has died is, for every purpose the house has, down.
        """
        if not self.block.get("zero_enabled", True):
            return None
        addr = self.block.get("zero_addr") or ""
        if not addr:
            return None
        port = int(self.block.get("zero_port", 53))
        ok, rtt = tcp_open(addr, port, float(self.block.get("zero_timeout_s", 2.0)))
        return {
            "id": "zero_dns", "label": "pizero dns", "ok": ok,
            "detail": f"{rtt}ms" if ok else f"{addr}:{port} no answer",
        }

    def run_checks(self, today):
        """One day's row. Absent instruments drop out; nothing else does."""
        rows = [row for row in (
            self.check_throttled(),
            self.check_soc_temp(),
            self.check_disk("root_disk", "root disk", "/",
                            self.block.get("root_disk_max_pct", 90)),
            self.check_disk("state_disk", "state disk", self.state_dir,
                            self.block.get("state_disk_max_pct", 90)),
            self.check_memory(),
            self.check_zero_dns(),
        ) if row is not None]
        return {
            "date": today,
            "ran_at": stamp(),
            "pass": sum(1 for r in rows if r["ok"]),
            "fail": sum(1 for r in rows if not r["ok"]),
            "checks": rows,
        }

    # -- the day file --------------------------------------------------------

    def load_days(self):
        """The history as written, newest first, or [] if it is unreadable.

        A truncated or hand-mangled file is treated as a missing one rather
        than as a fetch failure. This source's entire job is to still be
        running in six months; refusing to record today because yesterday's
        bytes are bad would be the one failure it cannot afford. Rows without a
        usable date are dropped, because the date is the primary key.
        """
        try:
            with open(self.path) as fh:
                days = json.load(fh)
        except (OSError, ValueError):
            return []
        if not isinstance(days, list):
            return []
        return [d for d in days
                if isinstance(d, dict) and isinstance(d.get("date"), str)]

    # -- the poll ------------------------------------------------------------

    def fetch(self):
        days = self.load_days()
        today = datetime.now().date().isoformat()
        newest = days[0]["date"] if days else ""

        if today > newest:
            # The state dir is one of the things being measured, so it has to
            # exist before the disk check runs. write_atomic would create it,
            # but only after the check meant to report on it had already given
            # up and omitted itself.
            try:
                os.makedirs(self.state_dir, exist_ok=True)
            except OSError:
                pass
            days.insert(0, self.run_checks(today))
            del days[self.history_days:]
            write_atomic(self.path, json.dumps(days))

        # today == newest is the ordinary case: already ran, nothing to do.
        # today < newest means the clock went backwards -- an NTP correction
        # after a Pi boots with no RTC, which is routine here. Nothing is
        # deleted in that case: the future-dated rows were real measurements
        # taken on a real day, and re-running under a wrong date would only
        # write a second wrong row next to them.

        return {"days": days}

    def semantic_status(self, data):
        days = data.get("days") or []
        if not days:
            # Nothing recorded yet and no fetch has failed. The first poll of a
            # fresh box gets here for a few milliseconds and never again.
            return None

        newest = days[0]
        try:
            ran_at = datetime.fromisoformat(newest.get("ran_at"))
        except (TypeError, ValueError):
            ran_at = None
        # Twenty-six hours, not twenty-four. The run lands within one interval
        # of local midnight once it is in step, but the day a box boots it
        # lands wherever the boot did, so consecutive runs can legitimately sit
        # a little over a day apart. A 24h threshold would flag that as a fault
        # exactly once per reboot, which is how a panel earns being ignored.
        if ran_at is None or (datetime.now() - ran_at).total_seconds() > 26 * 3600:
            return "stale", f"no check run since {newest.get('date')}"

        failing = [c.get("label") or c.get("id")
                   for c in (newest.get("checks") or []) if not c.get("ok")]
        if failing:
            # Degraded, not error: see the class docstring. The names travel in
            # the reason because the client shows one lamp per source, and
            # "something in today's run failed" is not an actionable sentence.
            return "degraded", "failing: " + ", ".join(failing)
        return None


# --- cmo ---------------------------------------------------------------------

# `briefings/2026-08-15.md` and `2026-08-15.md` both, which is why it is
# anchored at the end rather than at both: the heartbeat carries the path the
# wrapper wrote and the directory carries bare names.
_BRIEFING_DATE = re.compile(r"(\d{4}-\d{2}-\d{2})\.md$")

# The curation ledger: one line per thing the user has waved off, written by
# the dismiss route and read by both this source and the agent's next run.
#
# **Dismissal is not deletion, and the difference is the whole point.** A
# dismissed item stays in seen-items.jsonl, which is exactly what stops the
# agent rediscovering it as new next week; this file only says the user does
# not want to be shown it again. Everything in it is restorable, so the cost
# of waving something off by mistake is one click.
DISMISSED_NAME = "dismissed.jsonl"

# A display window, like briefings_max, and for the same reason: the archive
# page has to be long enough to find a mistake in, not long enough to be a
# record. Nothing here is ever dropped from the file.
DISMISSED_MAX = 200

# How much of the ledger's tail to read for that window. Small because this
# file grows at human speed -- a handful of lines on a busy day -- so a quarter
# megabyte is already several years of it, and reading a file with no ceiling
# at all on every poll is the habit worth not forming.
DISMISSED_MAX_BYTES = 262144

# --- ask the cmo -------------------------------------------------------------
#
# A thread is one conversation: `ask/<id>.json` holds it, `ask/.queue/<id>`
# says the runner still owes it an answer. **This program writes the question
# and nothing else.** The answer turns, and the removal of the spool entry, are
# the ask-runner's alone -- one writer per field is what keeps a half-drained
# queue from being ambiguous, and it is why the POST route below can reply the
# instant the question is on disk.
ASK_DIR_NAME = "ask"
ASK_QUEUE_NAME = ".queue"

# A thread id is a local minute plus four hex, which sorts, reads as a time,
# and cannot collide across a restart the way a counter would. Shaped like
# every other slug this server serves so one regex vets both the route and the
# filename.
_ASK_NAME = re.compile(r"([a-z0-9-]{1,64})\.json")

# The display window, like briefings_max: the page is long enough to find
# yesterday's question in, not long enough to be a record. Nothing is deleted.
ASK_MAX = 50

# How many directory entries the poll will consider at all. The ask directory
# gains a file per conversation and nothing prunes it, so unlike briefings/ and
# docs/ -- which are scanned whole because a name is all they yield -- this one
# needs a ceiling: every entry here costs an open, and a poll that reads every
# thread on the box gets slower every week to draw a list of the newest few.
# The prefilter is the mtime, which scandir already carries.
ASK_SCAN_MAX = 400

# The question's first line, as the thread's name in the list. Long enough to
# recognise a question by, short enough to stay one row.
ASK_FIRST_Q_CHARS = 80

# What the POST route accepts. 2000 characters is a long question and a short
# essay; the byte cap above it leaves room for that in UTF-8 plus the JSON.
QUESTION_MAX = 2000


def dismissal_matches(row, entry):
    """Whether a ledger line is the same dismissal as `entry`.

    Identity is kind + title + date, deliberately without the lane. The lane
    is the console's label for where an item came from rather than part of
    what was dismissed, and letting it into the key would mean a lane the
    agent renamed leaves a line behind that no restore can ever find.
    """
    return (row.get("kind") == entry["kind"]
            and row.get("title") == entry["title"]
            and row.get("date") == entry["date"])


def read_dismissed_lines(path):
    """The whole ledger as [(text, parsed-or-None)]. Missing file -> [].

    The original text travels beside the parse because the rewrite in
    `Collector.cmo_restore` writes the kept lines back verbatim: the agent may
    one day add a field of its own to a line, and re-serialising from our parse
    would quietly drop it. Raises OSError for anything other than absence,
    which is a real fault and not an empty list.
    """
    out = []
    try:
        with open(path) as fh:
            for raw in fh:
                text = raw.strip()
                if not text:
                    continue
                try:
                    doc = json.loads(text)
                except ValueError:
                    doc = None
                out.append((text, doc if isinstance(doc, dict) else None))
    except FileNotFoundError:
        # The file does not exist until the first dismissal. That is the
        # ordinary state of a fresh box, not a failure.
        return []
    return out


class CmoSource(Source):
    """The Daily CMO agent's own account of its last run, read off disk.

    Nothing is polled over the network here. The job runs once a day on this
    box and leaves files behind, so this source's whole contribution is to read
    them honestly and to say plainly which of them are not there.

    **The heartbeat is required; everything else is optional.** The wrapper
    writes `heartbeat/cmo.json` through a tmp file and os.replace, so a reader
    structurally cannot catch it half-written -- which means an unreadable or
    non-dict heartbeat is a genuine fault and is allowed to become the error
    envelope. The agent's result, the dedup ledger and the briefings directory
    are written by the agent itself, mid-run, at whatever moment it decided to
    stop; each is read in its own try/except and degrades to an empty answer
    rather than taking the whole panel down with it.

    **`agent-result.json` may describe an EARLIER run than the heartbeat.** The
    wrapper deletes it when a run starts and the agent writes it as its last
    action, so a run that fails leaves the previous success sitting there. That
    is the behaviour worth having -- yesterday's items beat an empty panel --
    but only if the client is told which day it is looking at, which is what
    `agent_date` exists for.
    """

    name = "cmo"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.base = (block.get("base_dir") or "").rstrip("/")
        self.heartbeat_path = (os.path.join(self.base, "heartbeat", "cmo.json")
                               if self.base else "")
        self.history_days = max(1, int(block.get("history_days", 14)))
        self.briefings_max = max(1, int(block.get("briefings_max", 90)))
        self.seen_items_max = int(block.get("seen_items_max_bytes", 1048576))

    @property
    def configured(self):
        # Checked on every snapshot rather than once at startup, on purpose:
        # the first run of the job is what creates this file, and the panel
        # should come alive at that moment rather than at the next restart of
        # the collector.
        return bool(self.base) and os.path.isfile(self.heartbeat_path)

    def why_dormant(self):
        if not self.base or not os.path.isdir(self.base):
            return f"cmo.base_dir not found ({self.base or 'unset'})"
        return "no heartbeat yet; the CMO job has never run"

    # -- the optional files --------------------------------------------------

    def read_agent(self):
        """The agent's own summary of its last completed run, or None.

        None is a real answer here and not a failure: the wrapper removes this
        file at the start of every run, so a run in flight legitimately has no
        result yet.
        """
        try:
            with open(os.path.join(self.base, "state", "agent-result.json")) as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            return None
        return doc if isinstance(doc, dict) else None

    def read_items_daily(self):
        """New items per calendar day, from the dedup ledger.

        Exactly `history_days` days ending today, oldest first and zero-filled.
        The zero-fill is the point: a strip that silently omits the days with
        no items draws a flat line over a week of nothing and calls it steady.

        Bounded by bytes rather than lines, and read as bytes rather than text:
        seeking into the tail of a file lands mid-line, and in text mode it can
        land mid-character too. In binary the damage is confined to the one
        partial line that gets discarded -- which is either already outside the
        window or too old to be in it.

        [] on any read failure, never a row of zeros. Fourteen zeros would be
        an assertion that nothing was found on any of those days, which is a
        different and much worse thing to say than nothing at all.
        """
        path = os.path.join(self.base, "memory", "seen-items.jsonl")
        counts = {}
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as fh:
                if size > self.seen_items_max:
                    fh.seek(size - self.seen_items_max)
                    fh.readline()
                for raw in fh:
                    try:
                        row = json.loads(raw)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    # first_seen, never last_seen: the question is when an item
                    # arrived, and last_seen moves every time it is re-crawled.
                    day = row.get("first_seen")
                    if isinstance(day, str) and day:
                        counts[day[:10]] = counts.get(day[:10], 0) + 1
        except OSError:
            return []

        today = datetime.now().date()
        days = []
        for back in range(self.history_days - 1, -1, -1):
            date = (today - timedelta(days=back)).isoformat()
            days.append({"date": date, "count": counts.get(date, 0)})
        return days

    def read_briefings(self):
        """Every briefing on disk, newest first, capped. [] if there is none.

        One scandir and no stat per name: only the filename is needed, the
        directory only grows, and this runs every interval.
        """
        dates = []
        try:
            with os.scandir(os.path.join(self.base, "briefings")) as entries:
                for entry in entries:
                    found = _BRIEFING_DATE.fullmatch(entry.name)
                    if found:
                        dates.append(found.group(1))
        except OSError:
            return []
        # The name IS the date, in a format that sorts correctly as a string,
        # so no parsing is needed to order them.
        dates.sort(reverse=True)
        return dates[:self.briefings_max]

    def read_dossiers(self):
        """Watchlist companies with a research dossier on disk, as slugs,
        sorted. [] if the directory does not exist, which is the ordinary
        state until the first research pass writes one.

        Same one-scandir discipline as `read_briefings`: the console only
        needs to know which company names are doors, and the file bodies have
        their own route.
        """
        slugs = []
        try:
            with os.scandir(os.path.join(self.base, "watchlist")) as entries:
                for entry in entries:
                    found = _SLUG_NAME.fullmatch(entry.name)
                    if found:
                        slugs.append(found.group(1))
        except OSError:
            return []
        slugs.sort()
        return slugs

    def read_docs(self):
        """The operator's own reference documents on disk, as {slug, updated},
        sorted by slug. [] if the directory does not exist, which is the
        ordinary state on any box that is not the Pi -- these files are written
        by hand, not by the job, so this is an optional enrichment exactly like
        the dossiers are.

        One scandir like the two above, plus one stat per name. The stat is the
        whole reason to touch the inodes at all: the console keys its unseen
        dot on `updated`. An entry that vanishes between the scan and the stat
        is skipped rather than emptying the list -- a document being rewritten
        mid-poll is an ordinary event in a directory a person edits.
        """
        docs = []
        try:
            with os.scandir(os.path.join(self.base, "docs")) as entries:
                for entry in entries:
                    found = _SLUG_NAME.fullmatch(entry.name)
                    if not found:
                        continue
                    try:
                        mtime = entry.stat().st_mtime
                    except OSError:
                        continue
                    docs.append({
                        "slug": found.group(1),
                        # Local ISO seconds, like every other timestamp this
                        # program writes, and never a pre-rendered age.
                        "updated": iso(datetime.fromtimestamp(mtime)),
                    })
        except OSError:
            return []
        docs.sort(key=lambda doc: doc["slug"])
        return docs

    def read_dismissed(self):
        """What the user has waved off, newest first, capped. [] if none.

        Bounded by bytes and read as bytes for the same reasons the dedup
        ledger's tail is: a seek into a file lands mid-line, and in text mode
        it can land mid-character too, so binary confines the damage to the one
        partial line that gets discarded.

        [] on any read failure, and a missing file is the ordinary case rather
        than a failure at all -- nothing creates this file until the first
        dismissal. Unlike the daily strip there is no zero-fill question here:
        an empty list says "nothing dismissed", which is true either way.
        """
        path = os.path.join(self.base, "memory", DISMISSED_NAME)
        rows = []
        try:
            size = os.path.getsize(path)
            with open(path, "rb") as fh:
                if size > DISMISSED_MAX_BYTES:
                    fh.seek(size - DISMISSED_MAX_BYTES)
                    fh.readline()
                for raw in fh:
                    try:
                        row = json.loads(raw)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    # Named through rather than passed on whole: this file is
                    # written by two programs and the console renders every
                    # field it is handed.
                    rows.append({
                        "kind": row.get("kind"),
                        "title": row.get("title"),
                        "lane": row.get("lane"),
                        "date": row.get("date"),
                        "dismissed_at": row.get("dismissed_at"),
                    })
        except OSError:
            return []
        # Append-only, so the file is already in chronological order and the
        # newest-first the archive wants is the reversed tail.
        rows.reverse()
        return rows[:DISMISSED_MAX]

    def read_ask(self):
        """Every ask thread as a one-line summary, newest-updated first, capped.
        [] when the directory is missing, which is the ordinary state until the
        first question -- and the ordinary state forever on a box that is not
        the Pi.

        Two passes on purpose. The scandir pass takes only names and mtimes and
        keeps the newest `ASK_MAX` of at most `ASK_SCAN_MAX` entries; the read
        pass opens just those. mtime is a faithful prefilter because the runner
        rewrites the whole record when it sets `updated`, so the two move
        together -- and the returned list is still ordered by `updated` itself,
        which is the field the console reasons about.

        Every read is guarded on its own: a thread being rewritten mid-poll is
        an ordinary event here (that is exactly what the runner does), and one
        unparseable file must cost its own row rather than the whole list.
        """
        found = []
        try:
            with os.scandir(os.path.join(self.base, ASK_DIR_NAME)) as entries:
                for entry in entries:
                    if not _ASK_NAME.fullmatch(entry.name):
                        continue
                    try:
                        mtime = entry.stat().st_mtime
                    except OSError:
                        # Vanished between the scan and the stat. Skipped
                        # rather than emptying the list, same as read_docs.
                        continue
                    found.append((mtime, entry.path))
                    if len(found) >= ASK_SCAN_MAX:
                        break
        except OSError:
            return []

        found.sort(key=lambda row: row[0], reverse=True)

        rows = []
        for _, path in found[:ASK_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(doc, dict):
                continue
            turns = doc.get("turns")
            turns = turns if isinstance(turns, list) else []
            first_q = ""
            for turn in turns:
                if isinstance(turn, dict) and turn.get("role") == "q":
                    first_q = str(turn.get("text") or "")[:ASK_FIRST_Q_CHARS]
                    break
            # Named through rather than passed on whole, like the dismissal
            # ledger and for the same reason: this file is written by another
            # program and the console renders every field it is handed. The
            # turn bodies stay out of the payload entirely -- they travel by
            # the thread route, the way briefing markdown does.
            rows.append({
                "id": doc.get("id"),
                "first_q": first_q,
                "turns": len(turns),
                "updated": doc.get("updated"),
                "status": doc.get("status"),
            })
        # By `updated`, not by mtime: the mtime got us the right fifty files
        # and this is the order the console was promised. A record with no
        # `updated` sorts last rather than crashing the sort.
        rows.sort(key=lambda row: row["updated"] or "", reverse=True)
        return rows

    # -- the poll ------------------------------------------------------------

    def fetch(self):
        # Deliberately undefended: see the class docstring. A heartbeat that
        # cannot be read is a fault, and the error envelope is the honest way
        # to say so.
        with open(self.heartbeat_path) as fh:
            hb = json.load(fh)
        if not isinstance(hb, dict):
            raise ValueError("heartbeat/cmo.json is not a JSON object")

        agent = self.read_agent()
        agent_date = None
        if agent:
            found = _BRIEFING_DATE.search(str(agent.get("briefing") or ""))
            agent_date = found.group(1) if found else None

        return {
            # Passed through as written, timestamps included. ISO strings, never
            # a pre-rendered "4m": a relative string baked in here is wrong the
            # moment the payload is cached, which is the lie this whole design
            # exists to avoid.
            "heartbeat": hb,
            "agent": agent,
            # Which run `agent` actually describes, which is not always the run
            # the heartbeat describes.
            "agent_date": agent_date,
            "items_daily": self.read_items_daily(),
            "briefings": self.read_briefings(),
            # The user's own curation, which is a different fact from anything
            # the agent reports: the run says what was found, this says what he
            # does not want shown again. The console dims rather than removes
            # the rows it names, so the two readings stay separable.
            "dismissed": self.read_dismissed(),
            # Which watchlist companies have a dossier to open. Slugs only;
            # the markdown travels by its own route like the briefings do.
            "dossiers": self.read_dossiers(),
            # The operator's ground-truth reference documents, same door-only
            # rule as the dossiers. `updated` is the file's mtime, which is
            # what the console's unseen-dot keys on; it is a timestamp of the
            # copy on disk, not a claim about the content's age.
            "docs": self.read_docs(),
            # The operator's own questions and what the CMO answered. Summaries
            # only -- one line per thread, the same door-only rule as the
            # dossiers -- because a thread's text travels by its own route and
            # a payload that carried every answer would grow without limit.
            "ask": self.read_ask(),
        }

    def semantic_status(self, data):
        # No missed-window check here yet, deliberately. There is no systemd
        # timer on the box, so "should have run by now" has no schedule to be
        # measured against and would fire every day on a machine where the job
        # is still started by hand. When the timer lands, key it on the
        # heartbeat's own `next_run` rather than on a clock kept in here.
        hb = data.get("heartbeat") or {}
        status = hb.get("status")

        if status in ("ok", "no_new_items"):
            return None

        if status == "running":
            try:
                started = datetime.fromisoformat(hb.get("started_at"))
            except (TypeError, ValueError):
                started = None
            if started is None:
                # A run with no start time cannot be timed, and inventing a
                # verdict for it would be worse than saying nothing.
                return None
            # now(tzinfo) rather than now(): the wrapper stamps started_at with
            # `date -Is`, which carries an offset, and subtracting an aware
            # timestamp from a naive one raises rather than being wrong quietly.
            age = (datetime.now(started.tzinfo) - started).total_seconds()
            if age <= float(self.block.get("running_stuck_after_s", 5400)):
                return None
            # Stale, not degraded: whatever is on screen is the previous run's
            # work, which is exactly what a stale panel means. Short phrases
            # here -- the reason becomes the console's pill, and the full
            # sentence renders in the panel body from heartbeat.detail.
            return "stale", f"run started {human_span(age)} ago and never finished"

        if status == "failed_timeout":
            return "degraded", "run timed out"
        if status == "auth_expired":
            return "degraded", "claude auth expired"
        if status == "failed_no_briefing":
            return "degraded", "run wrote no briefing"
        if status == "failed_claude_error":
            return "degraded", "claude errored"
        # An unrecognised word is not a pass. The wrapper and this file are
        # versioned separately, so a status added there arrives here as a
        # stranger, and reading a stranger as healthy is how a broken run comes
        # out green.
        return "degraded", f"unrecognised status {status!r}"


# --- mail --------------------------------------------------------------------
#
# The mailbox is a directory, not a service. A timer on this same box logs into
# Gmail, writes what it found under `mail/`, and exits; this program reads those
# files and writes back exactly three kinds of thing -- a spool entry, a draft
# somebody typed, and an outbox record. **It holds no mail credentials and opens
# no socket to Gmail.** That split is the whole security argument: the two
# processes that can touch the mailbox from outside have no listening port, and
# the one with a listening port cannot send mail however it is asked to.
MAIL_DIR_NAME = "mail"

# Two spools rather than one, because the workers behind them are not
# comparable: triage runs an LLM and takes minutes, and a send queued behind one
# would be a click with no visible effect for the length of an Opus call. A
# separate path unit watches each directory.
MAIL_QUEUE_NAME = ".queue"
MAIL_ACTIONS_NAME = ".actions"

# A message key is sha256(Message-ID)[:16]: route-safe and filename-safe by
# construction, which is why one shape vets the URL, the field in a POST body
# and the directory entry. A message the route could never name must not appear
# in the payload as a door either -- the same argument as _SLUG_NAME's.
_MAIL_KEY = re.compile(r"[a-f0-9]{16}")
_MAIL_KEY_NAME = re.compile(r"([a-f0-9]{16})\.json")

# An outbox record is named for the send, not for the message: one message can
# be replied to twice and each attempt is its own permanent line in the audit
# trail. Same shape as an ask thread's name because it is minted the same way.
_MAIL_ID_NAME = re.compile(r"([a-z0-9-]{1,64})\.json")

# How many index records one poll will open. The ceiling sits on the opens
# rather than on the scandir, and the window is the newest by mtime rather than
# whatever the directory happened to name first -- unlike `read_ask`'s, because
# this window decides which messages the console can see at all. A mailbox that
# outgrows it reports its newest MAIL_SCAN_MAX, which is a bound you can reason
# about; a poll that opened every record would get slower every month instead.
MAIL_SCAN_MAX = 600

# The outbox is the audit trail and is never pruned, so it is the one directory
# here that grows without limit. Only the newest few hundred records are read
# for the per-message badge; an older send is still on disk and still travels
# with its own message on the message route, which is where anyone looking for
# it would look.
MAIL_OUTBOX_SCAN_MAX = 200

# One row's worth of each. Every one of these fields came out of a mail header
# or an LLM, both of which can be arbitrarily long, and all of them are drawn as
# a single line in a fixed grid.
MAIL_SUBJECT_CHARS = 120
MAIL_SUMMARY_CHARS = 160
MAIL_NAME_CHARS = 80
MAIL_TAG_CHARS = 24
MAIL_TAGS_MAX = 6

# What the counts call urgent. 3 is "needs attention today" and 2 is the band
# the console already draws in caution tone, so a count that named only the top
# one would be smaller than what the panel is visibly worried about.
MAIL_URGENT_MIN = 2

# How much of an extracted body one message route will serve. The poller caps
# what it stores at the same number; this is the second half of the same
# promise, so a .txt written by hand or by an older poller cannot turn a page
# into a download. What is cut is announced rather than hidden -- a body that
# silently stops mid-sentence is a worse answer than a truncated one that says
# it is truncated.
MAIL_BODY_SERVE_MAX = 65536

# The raw message, which is only ever opened to dig an attachment out of it.
# The poller stores nothing bigger; the ceiling is here too because this file is
# read whole into memory to be parsed, and a Pi has 8 GB to run everything else
# in as well.
MAIL_EML_MAX_BYTES = 5 * 1024 * 1024

# An attachment name comes from whoever sent the message and goes into a
# response header, so it is rebuilt rather than passed through: CR or LF in a
# header is response splitting, a quote ends the parameter early, and a slash is
# a path in somebody's downloads folder. Reduced to a conservative alphabet, and
# a name of our own when nothing survives.
_MAIL_FILENAME_SAFE = re.compile(r"[^A-Za-z0-9._-]+")
MAIL_FILENAME_CHARS = 100

# A shape check on a declared content type, not a decision to render anything:
# attachments are always served with Content-Disposition: attachment and the
# nosniff header every response here carries. This only keeps a malformed type
# out of a header we write.
_MAIL_CTYPE = re.compile(r"[a-z0-9][a-z0-9.+-]{0,60}/[a-z0-9][a-z0-9.+-]{0,60}")

# A shape check on a reply address, not an opinion about what a valid address
# is. Its job is to refuse the characters that would make one address into two
# recipients or one header into two -- this string ends up in an SMTP envelope,
# and v1 replies to exactly one person.
_MAIL_ADDRESS = re.compile(r"[^\s<>,;:\"@]{1,64}@[A-Za-z0-9.-]{1,250}\.[A-Za-z]{2,63}")

# What the reply routes accept. A long email is a few thousand characters, and
# the byte cap on the route above it leaves room for this in UTF-8 plus the JSON
# around it -- a body limit that fires on valid input is a bug that only shows
# up on the day it matters.
MAIL_REPLY_CHARS = 8000

# Steering for a draft, not a brief: the thread is the context and the prompt
# file is where the voice lives, so this is room for "keep it short, decline
# politely" rather than for a second prompt written in a textarea.
MAIL_INSTRUCTIONS_CHARS = 500

# --- messages ----------------------------------------------------------------
#
# The iMessage channel, and the one feature here whose upstream is not on this
# box. A small background app on the Mac ("the Bridge") reads new Messages rows,
# keeps only the conversations the user allowlisted, and posts them here; it
# pulls queued sends back and performs them through Messages.app. **The Mac is
# never called.** Everything is a push or a pull the Mac starts, which is what
# lets a laptop sleep for two days and resume from its cursor.
#
# The division of labour, which is the thing to not break:
#
#     this program writes  index records, bodies, the per-conversation
#                          summaries and key indexes, the allowlist, the chat
#                          directory, the heartbeat, read marks, draft requests,
#                          queued sends, and the two spool entries
#     the triage worker    verdicts, drafts and the daily summaries
#     the Bridge           nothing on disk. It reports, and this program writes
#                          what it reported.
#
# One writer per field, as everywhere else here. And the security line is the
# same shape as mail's, one step further: this process has no way to send a
# text, and the process that can send has no way to reach a model.
MESSAGES_DIR_NAME = "messages"

# Two spools, for mail's reason: the worker behind .queue runs a model and takes
# minutes, and a send queued behind one would be a tap with no visible effect
# for the length of an Opus call. Nothing on the Pi consumes .actions -- the
# Bridge pulls its queue over HTTP -- so it is this box's own note that a send
# was filed, dropped when the Bridge reports what happened to it.
MESSAGES_QUEUE_NAME = ".queue"
MESSAGES_ACTIONS_NAME = ".actions"
# Charon's own read marks, per conversation. The Messages app's read flags are a
# fact about the phone in the user's pocket and are deliberately ignored:
# "unread" here means not yet seen HERE.
MESSAGES_READ_NAME = ".read"

# One small file per conversation, maintained by the ingest route: who, when,
# the last line, how many unread, how many in total. It exists because the
# alternative does not survive a history.
#
# The chat list used to be built by opening the newest MESSAGES_SCAN_MAX index
# records by mtime and grouping them. That worked while the store was only ever
# the live stream, where mtime and recency are the same fact. Backfill broke
# both halves of it at once: tens of thousands of records make the stat pass
# expensive every thirty seconds, and they are written in backfill order, so
# "newest by mtime" is whichever conversation was backfilled last rather than
# whichever conversation somebody just texted. A chat with a message from this
# morning could fall out of the list entirely behind a nine-year thread that
# finished downloading a minute ago.
#
# So the writer keeps the answer instead. One read and one write per
# conversation per post, and the poll opens one file per conversation rather
# than two thousand records to find out what the conversations are.
MESSAGES_CHAT_SUMMARY_NAME = ".chats"
# What the summary keeps of the newest line. Longer than MESSAGES_PREVIEW_CHARS
# on purpose: the envelope clips to its own ceiling on the way out, and the
# slack means the stored line is still a full preview if that ceiling ever
# moves.
MESSAGES_CHAT_PREVIEW_CHARS = 140
# How many unread inbound keys one summary remembers, and therefore how many
# verdicts a poll may look up for one conversation. The triage's urgency and
# "needs you" are written by the pipeline rather than by this program, so they
# cannot be maintained on write; they are read per poll for the listed chats
# only, and this is what keeps that bounded at list_max * (this + 1) opens.
MESSAGES_CHAT_KEYS_MAX = 20

# One append-only line per stored row, filed under the conversation it belongs
# to: `messages/.threads/<chat_key>.jsonl`, holding the key, the rowid, the
# stamp the Mac put on the row and whether it was ours.
#
# The second half of the lesson the summaries above taught. The chat list
# stopped being derived from the index because a history download makes mtime
# meaningless and a full store expensive to stat. A thread was still derived
# from it: every record in the store stat-ed, the newest two thousand opened,
# and the handful belonging to one conversation kept. That is slow on every tap
# once a store holds tens of thousands of rows, and it is wrong as well -- a
# conversation whose rows all fall outside the window comes back empty or as a
# 404, which is a nine-year thread being told it does not exist.
#
# So the writer keeps this too. One append per stored row, which is the
# cheapest write in the store and lands inside a lock the ingest route is
# already holding, and a thread open reads one small file and then opens
# exactly the messages it is about to draw.
#
# Deliberately lines rather than a JSON array: an array has to be read, parsed
# and rewritten whole for every message that arrives, which is the cost this
# exists to avoid. Appended and never rewritten means a post of a hundred rows
# is a hundred short appends, and a line that somehow arrives mangled costs its
# own message rather than the conversation.
MESSAGES_THREAD_INDEX_NAME = ".threads"

# Sixteen lowercase hex, for both a message and a conversation. The same shape
# as a mail key and the same regex object, which is the point: one shape vets a
# URL segment, a field in a POST body and a directory entry, and a second copy
# of it would be one edit away from disagreeing with the first. What differs
# between the two channels is what gets hashed, and that lives on the Mac and in
# msglib, not here.
_MESSAGES_KEY = _MAIL_KEY
_MESSAGES_REQUEST_ID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
_MESSAGES_KEY_NAME = _MAIL_KEY_NAME
# The same shape with the key index's extension, for the one directory in this
# store whose entries are not `.json`.
_MESSAGES_THREAD_NAME = re.compile(r"([a-f0-9]{16})\.jsonl")

# The wire version. Every Bridge request carries it and a number this program
# does not speak is a 400 rather than a best effort: the alternative is a newer
# Bridge silently half-working against an older Pi.
MESSAGES_PROTOCOL = 1

# One hundred events of twenty thousand characters is not a real post -- the
# Bridge batches what it finds since its cursor, which on a wake-up is tens of
# short texts. Half a megabyte holds a genuinely large catch-up with room to
# spare, and reading whatever Content-Length claims is how a write path turns
# into a way to exhaust a Pi's memory from the tailnet.
MESSAGES_INGEST_MAX_BYTES = 512 * 1024
# Everything else on this channel: a heartbeat, an allowlist, a chat directory,
# a draft, a send. 64 KB holds MESSAGES_SEND_MAX at four bytes a character with
# room left for the JSON around it.
MESSAGES_BODY_MAX_BYTES = 65536

# The protocol's own limits, restated here because this side enforces them. A
# cap that only the sender honours is not a cap.
MESSAGES_TEXT_MAX = 20000
MESSAGES_SEND_MAX = 4000
MESSAGES_INGEST_MAX_EVENTS = 100
MESSAGES_OUTBOX_PULL_MAX = 20
# What the thread route hands back beside the transcript: this conversation's
# own recent sends, so the app can draw a text it filed before the Bridge has
# performed it and the row has come back up through ingest. A day, because a
# send older than that is either in the transcript already or is never coming,
# and twenty, because it is the same ceiling the Bridge pulls at.
MESSAGES_THREAD_OUTBOX_MAX = 20
MESSAGES_THREAD_OUTBOX_AGE = 24 * 3600

# How many outbox records one poll will open to count what is waiting. The
# ceiling is on the opens rather than on the scandir, the same bound mail's
# index scan carries and for the same reason. It used to bound a window over
# the message index as well -- first for the chat list, then for the thread --
# and neither is read that way any more: both come out of a file the writer
# keeps, and nothing here opens a record it is not going to use.
MESSAGES_SCAN_MAX = 2000
# What one thread route will serve, and what it serves when nobody said. Bodies
# travel on this route, so the ceiling is the one that keeps a tap on a
# five-year-old conversation from being a megabyte.
MESSAGES_THREAD_MAX = 200
MESSAGES_THREAD_DEFAULT = 50
# Two weeks of daily reads in the envelope. The summary route serves any date
# the store holds; this is the strip the screen draws.
MESSAGES_SUMMARIES_MAX = 14

# One row's worth of each. Every one of these came out of somebody's phone or
# out of a model, and all of them are drawn as a single line in a fixed grid.
# The summary document's own ceilings are not here: the worker that writes it
# clips every field on the way in, which is the only place a bound on a model's
# output can actually be enforced, and a second set of numbers here would be a
# second opinion about a file this program only forwards.
MESSAGES_NAME_CHARS = 120
MESSAGES_PREVIEW_CHARS = 120
MESSAGES_ERROR_CHARS = 300
# A chat GUID, a row GUID, a phone number or handle. Long enough for anything
# Messages actually mints and short enough that a hostile Bridge cannot fill the
# disk one field at a time.
MESSAGES_GUID_CHARS = 512
MESSAGES_HANDLE_CHARS = 200
# A group chat is a group chat, not a mailing list, and an event that claims two
# hundred participants is an event to refuse rather than to store.
MESSAGES_PARTICIPANTS_MAX = 64
MESSAGES_ATTACHMENTS_MAX = 20

# --- the attachments themselves ----------------------------------------------
#
# The one place on this channel where bytes travel. Everything else here is a
# line of text or a small JSON object; this is somebody's photograph, and the
# rules around it are the rules that keep a Pi with 8 GB and an SD card from
# being filled up by a laptop over the tailnet.
#
# `messages/attachments/<message key>/<n>.<ext>` holds the file and `<n>.json`
# beside it holds what the upload said about it. Filed under the message rather
# than under the conversation because the message key is what both sides
# already agree on: the Bridge uploads by it, the app asks by it, and a
# directory per message is a directory that goes away with the message.
MESSAGES_ATTACHMENTS_DIR_NAME = "attachments"
# What the app has asked for and the Bridge has not yet sent. One small file per
# request, named for the pair it names, so asking twice is one file rather than
# two and the Bridge's poll is a scandir over the outstanding asks and nothing
# else.
MESSAGES_WANTS_NAME = ".wants"

# Twenty-five mebibytes, which is a video somebody actually wants to watch and
# is not a video library. The Bridge holds a lower ceiling of its own for the
# photos it uploads unasked; this is the wire's, and it is the one that is
# enforced, because a cap only the sender honours is not a cap.
#
# The body is streamed to a temporary file inside the attachment's own
# directory and renamed into place, so the largest an upload ever is in this
# process's memory is one chunk of it.
MESSAGES_ATTACHMENT_MAX_BYTES = 25 * 1024 * 1024
MESSAGES_ATTACHMENT_CHUNK = 256 * 1024
# The same bound the outbox pull carries and for the same reason: the Bridge
# does a little work per cycle rather than all of it in one.
MESSAGES_WANTS_PULL_MAX = 20
# A week. A file the Mac has not managed to produce in seven days is a file the
# Mac does not have -- Messages ages the big ones out -- and a want nobody can
# answer should not be asked forever.
MESSAGES_WANT_MAX_AGE = 7 * 86400

# A name that arrived from somebody else's phone and is about to become both a
# path segment and a header parameter. Rebuilt rather than passed through, on
# `_MAIL_FILENAME_SAFE`'s argument one channel over, and with the same alphabet
# and the same ceiling so the two cannot drift into two ideas of safe.
_MESSAGES_WANT_NAME = re.compile(r"([a-f0-9]{16})-(\d{1,3})\.json")
# The extension the stored file is given. Short, lowercase and alphanumeric:
# it is the tail of a filename this program builds, so anything that is not
# plainly an extension becomes `bin` rather than being trusted.
_MESSAGES_EXT = re.compile(r"[a-z0-9]{1,8}")
# The hex digest the upload carries, checked for shape before it is compared:
# a header is a stranger's string even when the stranger is the Bridge.
_MESSAGES_SHA256 = re.compile(r"[a-f0-9]{64}")
# What a mime type is worth as a file extension when the name has none. Only
# the types this channel actually carries; anything else falls through to the
# subtype, and anything that is not a plain word after that is `bin`.
MESSAGES_MIME_EXT = {
    "image/jpeg": "jpg", "image/png": "png", "image/heic": "heic",
    "image/heif": "heif", "image/gif": "gif", "image/webp": "webp",
    "image/tiff": "tiff", "image/bmp": "bmp",
    "video/quicktime": "mov", "video/mp4": "mp4", "video/3gpp": "3gp",
    "audio/x-caf": "caf", "audio/mp4": "m4a", "audio/mpeg": "mp3",
    "audio/amr": "amr", "application/pdf": "pdf", "text/plain": "txt",
}
# The whole directory of conversations in one post. A phone with more than this
# many allowlistable chats is a phone, but the picker is a list somebody scrolls.
MESSAGES_CHATS_MAX = 500

# Steering for a draft, not a brief: the conversation is the context and the
# prompt file is where the voice lives, so this is room for "tell her I am
# running late" rather than for a second prompt typed into a text field.
MESSAGES_INSTRUCTIONS_CHARS = 500

# What the allowlist may say about a conversation. v1 gives behaviour to `off`
# and `confirm`; `auto` is stored and shown and acted on by nothing. Kept in the
# vocabulary anyway so the app can offer it and the store can hold the user's
# intent before the code that honours it exists.
MESSAGES_POLICIES = ("off", "confirm", "auto")
# The two states a send can end in, as the Bridge reports them.
MESSAGES_REPORT_STATES = ("sent", "failed")

# --- the chat assistant ------------------------------------------------------
#
# A fifth thing on this box that files work for a worker to do, and the closest
# relative of the ask feature: `threads/<id>.json` holds one conversation,
# `threads/.queue/<id>` says the chat-runner still owes it an answer turn, and
# `threads/.stop/<id>` says the reader changed his mind about the turn being
# worked on right now.
#
# **The division of labour is the ask contract, restated because it is the
# thing to not break:**
#
#     this program writes  the thread record, the user turn, the spool entry,
#                          and the stop flag
#     the runner writes    status, partial, the assistant turn, the claude
#                          session id, and the deletion of both flags
#
# One writer per field. Notice what follows from it: this program never sets
# `status` to `running` when it files a turn. It cannot -- nothing is running
# yet, and a status this process wrote would be a claim about a subprocess it
# did not start. The honest way to say "filed, not started" is the spool entry
# itself, which is why the thread route reports `queued` beside the record
# rather than folding the two into one field.
CHAT_THREADS_NAME = "threads"
CHAT_QUEUE_NAME = ".queue"
CHAT_STOP_NAME = ".stop"

# Archiving is a flag beside the record and not a field inside it, which is the
# same call `queued` makes and for a stronger version of the same reason. One
# writer per field: the runner rewrites the whole thread record every half
# second while an answer streams, so a field this program set inside that file
# would be racing a process that has no idea it exists and would lose. A flag
# file is outside the record, is written only here, and survives every rewrite
# the runner does.
#
# It is also the honest shape for what archiving IS. Deleting is an act on the
# conversation; archiving is a statement about where the reader wants it shown,
# which is a property of the console rather than of the transcript. Nothing in
# the record changes, `updated_at` does not move, and un-archiving is removing
# a file rather than editing one.
CHAT_ARCHIVE_NAME = ".archive"

# Same shape as an ask thread's name, because it is minted the same way: a
# local minute plus four hex, which sorts, reads as a time, and survives a
# restart that a counter would not.
_CHAT_NAME = re.compile(r"([a-z0-9-]{1,64})\.json")

# The display window. Fifty conversations is a page long enough to find last
# week's in and short enough to draw, and a thread this list leaves out is still
# on its own route.
CHAT_MAX = 50

# How many directory entries the list will consider at all, prefiltered by the
# mtime scandir already carries. `read_ask`'s argument exactly: this directory
# gains a file per conversation and the reader prunes it by hand at best, so
# every entry costs an open and a list that read them all would get slower every
# week to draw the newest fifty.
CHAT_SCAN_MAX = 400

# The first line of the first user message, as the thread's name in the list.
CHAT_TITLE_CHARS = 80

# And the first line of the newest answer, as what the conversation came to.
# Longer than the title because it is a sentence rather than a name, and clipped
# to one line by the console, which has one line of room for it. Cut here rather
# than there for the reason every other field in this list is: the turn bodies
# never travel on this route, and a console that had to be sent a whole
# conversation to show a summary of it would be reading fifty of them to draw a
# page.
CHAT_PREVIEW_CHARS = 160

# What the send route accepts. Twice the ask route's ceiling: a question to the
# CMO is a question, and this is a conversation with a box -- pasting a stack
# trace or a unit file into it is the ordinary case rather than the abusive
# one.
CHAT_TEXT_MAX = 4000

# The two models the toggle offers. A closed set rather than a passthrough:
# this string becomes an argument to a subprocess on the Pi, and the narrow
# place to say which strings are allowed is here rather than in the runner's
# argv.
CHAT_MODELS = ("sonnet", "opus")


def chat_preview(turns):
    """The newest answer's first line of prose, for the list. "" when there is
    not one yet.

    **Backwards through the turns, not forwards**, and it matters on exactly the
    threads a reader is most likely to be scanning for: a conversation is a
    stack of exchanges and the row is ordered by when it last moved, so the
    answer that belongs beside `2m` is the last one, not the first.

    The first *non-empty* line rather than the first, because a model's answer
    routinely opens on a blank one, and whitespace is collapsed for the reason
    `mail_line` collapses it -- this is drawn as a single row, and a tab in it
    is a hole in the row. Tool lines are not considered at all: what the session
    ran is working-out, it is already on the thread route for anyone who opens
    it, and a row reading `Bash(systemctl status ...)` would be a summary of the
    method rather than of the answer.
    """
    if not isinstance(turns, list):
        return ""
    for turn in reversed(turns):
        if not isinstance(turn, dict) or turn.get("role") != "assistant":
            continue
        text = turn.get("text")
        if not isinstance(text, str):
            return ""
        for line in text.splitlines():
            line = " ".join(line.split())
            if line:
                return line[:CHAT_PREVIEW_CHARS]
        return ""
    return ""


# --- jarvis ------------------------------------------------------------------
#
# The sixth thing on this box that files work for a worker to do, and the chat
# assistant one level up: one conversation per calendar day rather than one per
# thread, with jobs running beside it in a lane of their own.
# `jarvis/days/<day>.json` holds the day, `jarvis/.say/<day>` says the say
# runner still owes it an answer turn, `jarvis/.stop/<day>` says the reader
# changed his mind about the turn being worked on right now, and the job spool
# and job stop flag say those same two things about one job.
#
# **Deliberately the same shapes as the chat block above**, down to the names.
# `chat-runner.py` has already solved the spool, the flock and the half-second
# repaint, and a second opinion about any of them would be a bug farm.
#
# **The division of labour is the chat contract with a third program in it:**
#
#     this program writes    the day record, the user turn, the notice turn, the
#                            job card, a job record at the moment it is minted,
#                            the compaction entry, and every spool and stop flag
#     the say runner writes  status, partial, the assistant turn, the claude
#                            session id, `context`, a compaction's `kept`, and
#                            the deletion of the say flags
#     the job runner writes  a job record after it is minted, and nothing else
#
# One writer per field, with one seam chat does not have. `POST /v1/jarvis/job`
# must never answer 409 -- that is the entire reason there is a second lane --
# so a job card is appended to the day record at a moment when the say runner
# may be mid-turn and rewriting that record from its own copy. That append can
# lose. It is repaired on read rather than prevented on write, which is also how
# a card's state stays true; see `Collector.jarvis_reconcile_jobs`.
#
# `queued` is a field on nothing here, for the reason it is a field on no thread
# either: this program files the spool entry and a runner writes the status, and
# between those two moments no status exists at all.
JARVIS_DIR_NAME = "jarvis"
JARVIS_DAYS_NAME = "days"
JARVIS_JOBS_NAME = "jobs"
JARVIS_SAY_NAME = ".say"
JARVIS_JOBSPOOL_NAME = ".jobs"
JARVIS_STOP_NAME = ".stop"
JARVIS_JOBSTOP_NAME = ".jobstop"

# A day record's name is its id and its id is a date. Asserted as a shape rather
# than trusted, like every other name this program turns into a path.
_JARVIS_DAY_NAME = re.compile(r"(\d{4}-\d{2}-\d{2})\.json")

# A job id is the stamped shape ask and chat ids already use, and it is pinned
# here rather than left as a slug: unlike a thread id, which this program only
# ever echoes back, a job id names a spool entry another process acts on, and
# the two halves of it are load-bearing. The date is how a day finds its own
# jobs without opening any of them -- see `jarvis_day_jobs` -- and the four hex
# are there because a person can file twice in one minute.
_JARVIS_JOB_ID = re.compile(r"\d{4}-\d{2}-\d{2}-\d{4}-[0-9a-f]{4}")
_JARVIS_JOB_NAME = re.compile(r"(\d{4}-\d{2}-\d{2}-\d{4}-[0-9a-f]{4})\.json")

# Two months of days. Long enough to scroll back through a quarter's worth of
# what was going on, short enough to draw, and a day this list leaves out is
# still on its own route.
JARVIS_DAYS_MAX = 60

# And fifty jobs, the chat list's window for the chat list's reason: a page long
# enough to find yesterday's in.
JARVIS_JOBS_MAX = 50

# How much of a job's result the LIST route carries per row.
#
# `jarvis-job-runner.py` caps what it stores at 200,000 characters, which is the
# right cap for a record on disk and the wrong one for a route that serves fifty
# of them at once: the worst case there is a ten-megabyte JSON body, built and
# held in memory, on a Pi, for a page whose job is to draw cards. The cards are
# a few lines each; nothing on screen has ever wanted the other 199,000
# characters.
#
# So the row is cut here and says so, with the same marker the runner uses when
# it cuts at its own ceiling -- a reader who meets "[output truncated]" learns
# the same thing whichever limit produced it. The record on disk keeps
# everything.
JARVIS_JOB_ROW_CHARS = 4_000

# The CLI's own `--effort` levels, in its own order, checked against
# `claude --help` rather than assumed.
#
# **Validated here even though the CLI is forgiving.** An unknown value only
# makes it warn and fall back to its default, so a bad record would answer --
# just not at the effort the record claims, and the console would keep showing
# a setting that never applied. Refusing at the route means a value on disk is
# always a value that ran.
JARVIS_EFFORTS = ("low", "medium", "high", "xhigh", "max")

# There is no scan cap here, and its absence is the decision.
#
# `chat_list` may stop early at CHAT_SCAN_MAX because it prefilters on the mtime
# that `scandir` already carries, so the entries it keeps are the newest ones by
# construction. None of the jarvis listings have that: they order by a name or a
# timestamp inside the record, and `scandir` yields in directory order, which is
# neither. A cap applied before the sort would hand an arbitrary subset to it and
# return the newest of *that*, so the day list would quietly stop including
# today once the directory grew past the cap -- a bug that is invisible on every
# box small enough to catch it on.
#
# Reading names is cheap. Opening records is not, and that is capped, per
# listing, by JARVIS_DAYS_MAX / JARVIS_JOBS_MAX / JARVIS_DAY_JOBS_MAX. The bound
# that costs something is kept; the one that corrupted the answer is gone.

# And how many of one day's jobs the day route will open to reconcile its cards.
# The same ceiling as the jobs list, because a day that somehow collected four
# hundred jobs would otherwise cost four hundred opens on the one route the
# console polls every second while a turn is live.
JARVIS_DAY_JOBS_MAX = 50

# The three crossings that get a line. Not a step size: 50, 75 and 90 are three
# different sentences about the day -- there is room, there is not much room,
# and this is going to stop working -- and a warning every n percent would say
# the third one four times before it was true.
JARVIS_NOTICE_STEPS = (50, 75, 90)

# The voice proxy's two clocks, and the name of its key. The env name is pinned
# here rather than made a config knob: the wire names HALFTONE_TTS_KEY on both
# ends, and a knob to rename one end is a knob that can disagree with the other.
JARVIS_TTS_KEY_ENV = "HALFTONE_TTS_KEY"
# Long enough for a cold Kokoro. launchd spawns the service on this very
# connection, the model takes 2-5s to load, and generation runs 4-6x realtime
# on top of that -- so a first sentence can honestly take ten seconds. See
# `Collector.jarvis_tts` for why waiting that long here blocks nothing.
# 60, not the 15 it was sized at. Fifteen fit Kokoro's 4-6x realtime with
# room; the engine behind the TTS server is the server's own choice, and a
# heavier one synthesizes at 0.6-0.9x realtime --
# SLOWER than playback -- so a long sentence legitimately needs half a minute.
# The wait costs nothing here: this route is a browser's own await, never a
# poll, and the console retries-then-skips a sentence that still misses.
JARVIS_TTS_TIMEOUT_S = 60.0
# Short on purpose. Under socket activation the CONNECTION is the whole job --
# it is what makes launchd spawn Kokoro -- and the answer that follows is
# almost beside the point. Two seconds lands a handshake on any LAN that is
# awake and gives up quickly on one that is not.
JARVIS_TTS_WARM_TIMEOUT_S = 2.0

# The pre-rendered phrases, shipped in the repo so a deploy's `git pull`
# carries voice and code together. See `jarvis_load_canned`.
JARVIS_CANNED_DIR = os.path.join(HERE, "canned")


def jarvis_canned_key(text):
    """One sentence reduced to the words someone actually said.

    Canned matching folds case, drops punctuation and collapses whitespace,
    because the model writing the answers is free with commas ("Certainly,
    sir.") and the clips were recorded without asking it. Two phrasings that
    differ only in punctuation are the same phrase to a listener, so they are
    the same key here. Apostrophes stay: "I'm" is one word, not two.
    """
    return " ".join(re.findall(r"[a-z0-9']+", text.lower()))


def jarvis_load_canned():
    """Every pre-rendered phrase, read whole into memory at startup.

    Returns {canned key: WAV bytes}. A megabyte of resident audio buys the
    two things the Mac proxy cannot offer: zero-latency playback for the
    phrases Jarvis says most, and a voice for them while the Mac is asleep.
    Read once at startup rather than per request for the same reason the
    voice style is resolved once on the Mac -- these files change only on
    deploy, and a deploy restarts this process.

    A missing directory is the feature switched off, not an error; so is a
    manifest with none of its audio rendered yet, which is how a fresh clone
    arrives. Anything else wrong (bad JSON, a *partly* rendered shelf) is said
    out loud and disables the whole set, because serving half a manifest would
    leave "why does this one phrase go to the Mac" as a mystery for later.

    Regenerating the shelf: the manifest is the list of phrases, not a promise
    that the audio exists. Render each `text` with any Kokoro-class TTS into
    the `file` beside it -- the voice only has to match itself across the set,
    since every phrase not on the shelf is spoken by the Mac anyway.
    """
    path = os.path.join(JARVIS_CANNED_DIR, "manifest.json")
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8") as fh:
            manifest = json.load(fh)
        entries = list(manifest.get("clips") or [])
        # The shipped state: phrases listed, nothing rendered. Reported once
        # as a fact rather than raised as a fault, for the same reason an
        # unconfigured source is `dormant` rather than an error. A shelf that
        # is *partly* rendered still falls through to the open() below and
        # disables the whole set -- that one really is a broken install.
        if entries and not any(
                os.path.exists(os.path.join(JARVIS_CANNED_DIR, entry["file"]))
                for entry in entries):
            print(f"{stamp()}  jarvis canned clips not rendered: "
                  f"{len(entries)} phrases in the manifest, no audio on disk")
            return {}
        clips = {}
        for entry in entries:
            with open(os.path.join(JARVIS_CANNED_DIR,
                                   entry["file"]), "rb") as fh:
                clips[jarvis_canned_key(entry["text"])] = fh.read()
        return clips
    except (OSError, ValueError, KeyError, TypeError) as exc:
        print(f"{stamp()}  jarvis canned clips disabled: "
              f"{type(exc).__name__}: {exc}")
        return {}


def jarvis_band(pct):
    """The highest notice threshold at or under `pct`, or 0 when there is none.

    The band, rather than the number itself, is what "already warned" has to
    mean. The contract tracks that state as the largest `pct` of any existing
    notice turn, so 52 and 53 must resolve to the same fact or every point of
    drift gets its own line -- which is rule two, and the difference between a
    warning and a ticker.
    """
    if isinstance(pct, bool) or not isinstance(pct, (int, float)):
        return 0
    band = 0
    for step in JARVIS_NOTICE_STEPS:
        if pct >= step:
            band = step
    return band


def jarvis_notice_band(turns):
    """The band this day has already been warned at, read off its own turns.

    **State lives in the transcript rather than in a field**, which the contract
    asks for and which is also the only version that survives this file having
    two writers: a `last_notice` field would sit in a record the say runner
    rewrites from its own copy every half second, so the first rewrite after a
    warning would forget the warning and the next poll would write it again.
    The notice turns are the record. Anything derivable from them is derived.
    """
    if not isinstance(turns, list):
        return 0
    best = 0
    for turn in turns:
        if not isinstance(turn, dict) or turn.get("kind") != "notice":
            continue
        best = max(best, jarvis_band(turn.get("pct")))
    return best


def jarvis_notice_text(pct):
    """The context warning, in his voice, with the number in it.

    Written here rather than asked for, which is the first of the contract's
    three rules and the one worth restating: a generated warning costs a round
    trip, is nondeterministic, and -- the real problem -- becomes context
    itself, at the exact moment context is the thing going wrong.
    """
    return (f"We're at {pct}% of my context for today. I can fold what's "
            f"happened so far into a summary and keep going -- say the word.")


def jarvis_counts(turns):
    """(say turns, job cards) for one day's transcript.

    Two numbers rather than one and a subset of it: the summary carries both,
    and a `turn_count` that included the cards would count the same line twice
    on a row that also says how many jobs ran. Notices are in neither, because
    they are this program talking rather than any part of the day's work.
    """
    if not isinstance(turns, list):
        return 0, 0
    says = jobs = 0
    for turn in turns:
        if not isinstance(turn, dict):
            continue
        kind = turn.get("kind")
        if kind == "say":
            says += 1
        elif kind == "job":
            jobs += 1
    return says, jobs


def jarvis_new_day(day, model):
    """A fresh day record, whole. The schema in one place, so the fields the
    console was promised exist from the first read rather than appearing one at
    a time as three programs get round to writing them.

    `status` is the one status this program ever writes here, and it writes it
    as part of creating the record rather than as an opinion about a process --
    `chat_new` makes the same call for the same reason. `context` is null and
    not an object of zeroes: nothing has run, so there is no `result` event to
    have taken a number off, and a zero here would be this program estimating
    the one quantity the contract says is never estimated.
    """
    now = stamp()
    return {
        "day": day,
        "created_at": now,
        "updated_at": now,
        "model": model,
        "status": "idle",
        "error": None,
        # No session yet. The say runner mints one and writes it here, and
        # clearing it is the whole of what compaction does.
        "claude_session_id": None,
        "partial": None,
        "turns": [],
        "context": None,
        "compactions": [],
    }


def mail_line(value, limit):
    """One line of at most `limit` characters, or None.

    Whitespace is collapsed rather than preserved: a subject can carry newlines
    and tabs, an LLM's bullet can carry both, and every field this touches is
    drawn as a single row. Empty becomes None so the console can say "(no
    subject)" in its own voice instead of drawing a blank where a subject goes.
    """
    if not isinstance(value, str):
        return None
    return " ".join(value.split())[:limit] or None


def mail_urgency(art):
    """The triage's 0-3, clamped, or None when it did not say.

    Clamped rather than trusted. The number is an LLM's, re-validated by the
    worker that wrote it, and the console maps it onto tones -- so a 7 arriving
    here would surface as an index error in a client, which is a strange way to
    find out that a prompt changed.
    """
    value = art.get("urgency")
    # bools are ints in Python, and `urgency: true` is not an urgency.
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return None
    return max(0, min(3, int(value)))


def mail_tags(art):
    """The triage's tags as row-safe words. [] when there are none.

    Shaped, not allowlisted. The allowlist belongs to the triage worker and it
    validates against it before writing; a second copy of that list here would
    be one edit away from silently dropping a word the worker learned to write.
    What this guards is the row, which draws each tag as a bracketed word.
    """
    tags = art.get("tags")
    if not isinstance(tags, list):
        return []
    out = []
    for tag in tags:
        word = mail_line(tag, MAIL_TAG_CHARS)
        if word:
            out.append(word)
        if len(out) >= MAIL_TAGS_MAX:
            break
    return out


def mail_reply_address(record):
    """Where a reply to this message goes, or None when nothing usable is on
    file. Reply-To when the sender named one, otherwise From.

    **This is the only place a recipient is decided.** The console sends a key
    and prose; where that prose goes is a property of the message being replied
    to, and a client that could name it would make this server one cross-site
    POST away from being a way to send mail as the operator.
    """
    for field in ("reply_to", "from_addr"):
        value = record.get(field)
        if isinstance(value, str) and _MAIL_ADDRESS.fullmatch(value.strip()):
            return value.strip()
    return None


def mail_reply_subject(record):
    """`Re:` the original, once.

    Computed here rather than accepted from the caller for the same reason the
    address is: everything about where this lands and what it answers comes off
    the record, and the caller supplies only the words. Flattened and clipped
    because the original subject is a stranger's string going back out in a
    header of ours.
    """
    subject = mail_line(record.get("subject"), MAIL_SUBJECT_CHARS)
    if not subject:
        return "Re: (no subject)"
    return subject if subject[:3].lower() == "re:" else f"Re: {subject}"


def mail_filename(part, n):
    """A download name for one attachment, safe to put in a header.

    Never the sender's string as written -- see `_MAIL_FILENAME_SAFE`. A part
    that arrives with no usable name gets one built from its position, which is
    the same number the route was asked for.
    """
    try:
        raw = part.get_filename()
    except Exception:  # noqa: BLE001 - a header this malformed is not a crash
        raw = None
    name = _MAIL_FILENAME_SAFE.sub("-", raw or "").strip("-.")[:MAIL_FILENAME_CHARS]
    return name or f"attachment-{n}"


def mail_ctype(part):
    """The part's declared type when it is shaped like one, otherwise the
    generic. See `_MAIL_CTYPE`: this is a header hygiene check, not trust.
    """
    try:
        value = (part.get_content_type() or "").lower()
    except Exception:  # noqa: BLE001 - same argument as the filename's
        value = ""
    return value if _MAIL_CTYPE.fullmatch(value) else "application/octet-stream"


class MailSource(Source):
    """The mailbox on disk: what the poller fetched, what the triage made of it.

    Same local-disk model as `CmoSource` and for the same reason. Nothing
    here is polled over the network; three workers on this box own the mailbox
    and this source's whole contribution is to read what they left behind and
    to say plainly which of it is not there.

    **`state.json` is required; everything else degrades to empty.** The poller
    writes it through tmp + os.replace at the end of a run, so a copy that
    cannot be read is a genuine fault and is allowed to become the error
    envelope -- exactly the heartbeat's argument. The index records, the triage
    artifacts, the drafts and the outbox are written by three different programs
    at whatever moment each of them chose to stop, so each is read in its own
    guard: one mangled file costs its own row, never the panel.

    **Bodies never travel in this payload.** A message here is a door: who,
    what, when, and what the triage thought of it. The text itself has its own
    route with its own ceiling, because fifty full emails inside a document the
    console fetches every few seconds is a different program than this one.
    """

    name = "mail"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.base = (block.get("base_dir") or "").rstrip("/")
        self.root = os.path.join(self.base, MAIL_DIR_NAME) if self.base else ""
        self.state_path = os.path.join(self.root, "state.json") if self.root else ""
        self.list_max = max(1, int(block.get("list_max", 50)))
        self.poll_stale_after = float(block.get("poll_stale_after_s", 1200))

    @property
    def configured(self):
        # Re-checked on every snapshot rather than once at startup, like the
        # CMO heartbeat: the poller's first run is what creates this file, and
        # the panel should come alive at that moment rather than at the next
        # restart of the collector.
        return bool(self.root) and os.path.isfile(self.state_path)

    def why_dormant(self):
        if not self.base or not os.path.isdir(self.base):
            return f"mail.base_dir not found ({self.base or 'unset'})"
        return "no mailbox state yet; the mail poller has never run"

    # -- the directories -----------------------------------------------------

    def read_index(self):
        """The header records in the scan window, as [(key, record)]. [] when
        the directory is missing, which is the ordinary state until the poller's
        first run and the ordinary state forever on a box that is not the Pi.

        Two passes, like `read_ask`: the scandir takes names and mtimes and the
        read pass opens what it kept. The prefilter is faithful because the
        poller rewrites the whole record when a flag moves, so a message that
        just became read sorts to the front of the window rather than out of it.

        The key comes from the filename rather than from the record. The
        filename is what every route here names, and a record whose own `key`
        field went missing is still a message somebody can open.
        """
        found = []
        try:
            with os.scandir(os.path.join(self.root, "index")) as entries:
                for entry in entries:
                    if not _MAIL_KEY_NAME.fullmatch(entry.name):
                        continue
                    try:
                        mtime = entry.stat().st_mtime
                    except OSError:
                        # Vanished between the scan and the stat. Skipped rather
                        # than emptying the list, same as read_docs: the poller
                        # prunes this directory while we are reading it.
                        continue
                    found.append((mtime, entry.name[:16], entry.path))
        except OSError:
            return []

        found.sort(key=lambda row: row[0], reverse=True)

        rows = []
        for _, key, path in found[:MAIL_SCAN_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict):
                rows.append((key, doc))
        return rows

    def read_ai(self, keys):
        """The triage verdicts for `keys`, as {key: record}. {} when there are
        none, which is every message's state between arriving and being read by
        the triage worker.

        One scandir to learn which keys have an artifact at all, then one open
        per artifact that belongs to a message this poll is reporting on. The
        scandir is what keeps a long tail of artifacts for messages outside the
        window from costing an open apiece on every poll.
        """
        have = []
        try:
            with os.scandir(os.path.join(self.root, "ai")) as entries:
                for entry in entries:
                    found = _MAIL_KEY_NAME.fullmatch(entry.name)
                    if found and found.group(1) in keys:
                        have.append((found.group(1), entry.path))
        except OSError:
            return {}

        out = {}
        for key, path in have:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict) and doc.get("status") != "pending":
                # A pending record is the worker counting its own attempts, not
                # a verdict: it carries no urgency and no tags, and a row that
                # showed it as "triaged" would read as "triaged as nothing".
                # Absent keeps the message in triage_pending, which is true.
                out[key] = doc
        return out

    def read_drafts(self, keys):
        """Which of `keys` have a draft of either kind, as a set.

        One scandir and no opens: the list only says whether the door has
        something behind it, and both drafts -- the AI's and the human's --
        travel on the message route where they can be read side by side.
        """
        out = set()
        try:
            with os.scandir(os.path.join(self.root, "drafts")) as entries:
                for entry in entries:
                    name = entry.name
                    if name.endswith(".user.json"):
                        name = name[:-len(".user.json")]
                    elif name.endswith(".json"):
                        name = name[:-len(".json")]
                    else:
                        continue
                    if name in keys:
                        out.add(name)
        except OSError:
            return set()
        return out

    def read_outbox(self, keys):
        """The newest send record per key, and how many sends are still queued.
        Returns ({key: status}, count).

        By mtime, which is a faithful ordering here because the actions worker
        rewrites the record when it turns one to sent, so the most recently
        touched record for a message is also the last thing that happened to it.

        The queued count is over every record in the window rather than over
        `keys`: a reply waiting to go out is a fact about the mailbox even when
        the message it answers has scrolled off the list.
        """
        found = []
        try:
            with os.scandir(os.path.join(self.root, "outbox")) as entries:
                for entry in entries:
                    if not _MAIL_ID_NAME.fullmatch(entry.name):
                        continue
                    try:
                        found.append((entry.stat().st_mtime, entry.path))
                    except OSError:
                        continue
        except OSError:
            return {}, 0

        found.sort(key=lambda row: row[0], reverse=True)

        statuses = {}
        queued = 0
        for _, path in found[:MAIL_OUTBOX_SCAN_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(doc, dict):
                continue
            if doc.get("status") == "queued":
                queued += 1
            key = doc.get("key")
            # Newest first, so the first record naming a message is the one
            # whose badge that row should carry.
            if isinstance(key, str) and key in keys and key not in statuses:
                statuses[key] = mail_line(doc.get("status"), MAIL_TAG_CHARS)
        return statuses, queued

    # -- one row -------------------------------------------------------------

    def summarise(self, key, doc, art, has_draft, outbox_status):
        """One message as a row: who, what, when, and what the triage thought.

        Named through rather than passed on whole, like the ask summaries and
        for the same reason: these records are written by other programs and the
        console renders every field it is handed. Every string is clipped and
        flattened on the way out, because the strings in a message belong to
        whoever sent it.
        """
        summary = art.get("summary") if art else None
        first = None
        if isinstance(summary, list):
            first = next((line for line in summary if isinstance(line, str)), None)
        attachments = doc.get("attachments")
        return {
            "key": key,
            # One string, the name when the header had one and the address
            # otherwise: the row has one column for who, and choosing here is
            # what lets the console draw the field without knowing the rule.
            "from": mail_line(doc.get("from_name") or doc.get("from_addr"),
                              MAIL_NAME_CHARS),
            "subject": mail_line(doc.get("subject"), MAIL_SUBJECT_CHARS),
            # As the poller wrote it: an ISO string, like every other timestamp
            # in this system, and never a pre-rendered age.
            "date": doc.get("date"),
            "unread": bool(doc.get("unread")),
            "flagged": bool(doc.get("flagged")),
            # None rather than 0 when there is no verdict yet: "not triaged" and
            # "triaged as ignorable" are different states and the console draws
            # them differently.
            "urgency": mail_urgency(art) if art else None,
            "tags": mail_tags(art) if art else [],
            "summary_line": mail_line(first, MAIL_SUMMARY_CHARS),
            # Whether each door has something behind it. The artifacts, the
            # drafts and the body itself travel on the message route.
            "has_ai": art is not None,
            "has_draft": has_draft,
            "attachments_n": len(attachments) if isinstance(attachments, list) else 0,
            "outbox_status": outbox_status,
        }

    # -- the poll ------------------------------------------------------------

    def fetch(self):
        # Deliberately undefended, exactly like the CMO heartbeat: the poller
        # writes this file through tmp + os.replace, so a copy that cannot be
        # read or is not an object is a genuine fault, and the error envelope is
        # the honest way to say so.
        with open(self.state_path) as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            raise ValueError("mail/state.json is not a JSON object")

        records = self.read_index()
        keys = {key for key, _ in records}
        ai = self.read_ai(keys)
        drafted = self.read_drafts(keys)
        outbox, queued = self.read_outbox(keys)

        # An explicit false is what an archive leaves behind; a record from a
        # poller that has not learned to write the field is still in the inbox.
        # The list is the inbox view, so an archived message leaves it while
        # keeping its place on disk and its own route -- which is what makes an
        # archive undoable in Gmail rather than a deletion here.
        inbox = [(key, doc) for key, doc in records
                 if doc.get("in_inbox") is not False]
        # By the header date, not by mtime: mtime got us the right window and
        # this is the order a mailbox is read in. A record with no date sorts
        # last rather than crashing the sort.
        inbox.sort(key=lambda row: str(row[1].get("date") or ""), reverse=True)

        urgent = 0
        pending = 0
        for key, _ in inbox:
            art = ai.get(key)
            if art is None:
                pending += 1
                continue
            level = mail_urgency(art)
            if level is not None and level >= MAIL_URGENT_MIN:
                urgent += 1

        return {
            # The poller's own account of itself, named through rather than
            # passed whole. `last_poll_ok` and `last_error` are in the payload
            # because `semantic_status` is handed the payload and nothing else:
            # it cannot open a file of its own to find out whether the last run
            # went badly.
            "last_poll_at": state.get("last_poll_at"),
            "last_poll_ok": state.get("last_poll_ok"),
            "last_error": mail_line(state.get("last_error"), 200),
            "counts": {
                # Over the scan window rather than the list window, deliberately:
                # five unread above a list of three is a fact about the mailbox,
                # and the two numbers answering different questions is the point
                # of having both.
                "inbox": len(inbox),
                "unread": sum(1 for _, doc in inbox if doc.get("unread")),
                "urgent": urgent,
                # No artifact at all, rather than an artifact that failed: the
                # triage gives up after three attempts, and a verdict that will
                # never arrive is not something to sit waiting for.
                "triage_pending": pending,
                "outbox_queued": queued,
            },
            # Door summaries, never bodies. See the class docstring.
            "messages": [
                self.summarise(key, doc, ai.get(key), key in drafted,
                               outbox.get(key))
                for key, doc in inbox[:self.list_max]
            ],
        }

    def semantic_status(self, data):
        # The poller's silence before its complaints. A five-minute timer that
        # has not fired in twenty minutes is the bigger fact about the inbox on
        # screen, and it subsumes whatever the last write claimed -- while
        # `age_s` cannot say any of this, because it measures how recently we
        # read the directory rather than how recently anyone filled it.
        last = data.get("last_poll_at")
        try:
            when = datetime.fromisoformat(last) if last else None
        except (TypeError, ValueError):
            when = None
        if when is None:
            return "degraded", ("poller has not recorded a poll yet" if not last
                                else "poller wrote an unreadable last_poll_at")

        # now(tzinfo) rather than now(), like the CMO's running check: the
        # poller stamps local ISO seconds today, and an offset appearing there
        # later must not turn this line into a crash.
        age = (datetime.now(when.tzinfo) - when).total_seconds()
        if age > self.poll_stale_after:
            return "stale", f"no mail poll for {human_span(age)}"

        if data.get("last_poll_ok") is False:
            # Degraded, not stale: the mailbox on screen is current, and what
            # failed is the attempt to make it more so. The poller's own
            # sentence travels because "the last poll failed" without a reason
            # sends the reader to the journal for something we already have.
            return "degraded", data.get("last_error") or "last mail poll failed"
        return None




def messages_key(guid):
    """The sixteen hex characters a GUID is filed under: sha256, cut to 16.

    One function for both kinds, because it is one rule: a message key is the
    hash of the message row's GUID and a chat key is the hash of the chat's, and
    a second implementation for the second kind would be a second thing that
    could drift.

    The third implementation of that rule overall, and deliberately so: the
    Bridge hashes in Swift, `msglib` hashes in the pipeline, and this hashes
    here. Sharing the code would mean this process importing the pipeline, which
    is the one thing the split between them exists to prevent. What is shared is
    the sentence, and the tests on both sides check the same fixture against it.

    Only ever used to *recognise* something the store already knows, never to
    mint a name from a caller's string: the routes take a key and look it up,
    and the GUID a send is addressed to is read off the store.
    """
    return hashlib.sha256(
        (guid or "").encode("utf-8", "replace")).hexdigest()[:16]


def messages_one_line(value, limit):
    """A field that is about to go into an audit line. Never None.

    Newlines out, runs of whitespace collapsed, length capped. `mail_line`'s
    twin with the empty case answered differently: that one returns None so a
    console can say "(no subject)" in its own voice, and this one returns "" so
    a permanent line in an audit file cannot read `error="None"`.
    """
    return " ".join(str(value or "").split())[:limit]


def messages_arrived_unread(record):
    """Whether one stored index record is an inbound row that landed unread.

    The one predicate behind two numbers that have to agree: the count the
    ingest route keeps as rows arrive, and the count the migration recomputes
    from a store that already holds them. Written once so those two cannot
    drift into two different ideas of what an unread message is.

    Our own texts are never unread. Neither is history: a backfilled row is
    read the moment it lands (section 7), the record says so, and a
    conversation switched on today must not arrive carrying years behind it.
    `unread` is defaulted true for records written before the field existed.
    """
    if record.get("is_from_me") or record.get("backfill"):
        return False
    return bool(record.get("unread", True))


def messages_count(value):
    """A non-negative whole number off a summary, or 0.

    Never raises. These files are this program's own, but they are on a disk a
    person can edit, and one hand-mangled counter should cost its own row
    rather than the panel it sits in.
    """
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return 0
    return max(0, int(value))


def messages_newest_first(pairs):
    """(key, created_at) pairs, newest first, with the key breaking a tie.

    A tie is not hypothetical -- two rows of one conversation can share a
    millisecond -- and an order that depends on which one a scandir happened to
    hand over first is an order the migration cannot reproduce.
    """
    return sorted(pairs, key=lambda row: (str(row[1] or ""), row[0]),
                  reverse=True)


def messages_rowid(record):
    """The Messages row number off a record or an index line, or 0.

    Never raises and never returns a bool. It is a sort key rather than a fact
    anything is looked up by, so a record that lost it should sort to the front
    of its second rather than take a conversation down with it.
    """
    value = record.get("rowid")
    if isinstance(value, bool) or not isinstance(value, int):
        return 0
    return value


def messages_thread_line(key, record):
    """One line of a conversation's key index, newline included.

    Four fields, which is the whole of what ordering and paging a thread needs:
    the key to open the message by, the stamp and the rowid to put it in its
    place, and whether it was ours. Everything else about the message is in the
    index record, one open away, and duplicating any of it here would be a
    second copy of a fact with a different writer.

    Compact separators on purpose: this file is only ever read by this program,
    and a store with a nine-year conversation in it holds tens of thousands of
    these lines.
    """
    return json.dumps({"key": key, "rowid": messages_rowid(record),
                       "at": record.get("created_at"),
                       "from_me": bool(record.get("is_from_me"))},
                      separators=(",", ":")) + "\n"


def messages_thread_index_text(records):
    """{key: record} for one conversation, as the whole text of its key index.

    Written in the order the reader sorts into, so a rebuilt file starts
    ordered and stays that way until the next live row is appended to the end
    of it. The dict is the dedupe: one index record is one message, so a
    conversation cannot come out of a rebuild holding the same key twice.
    """
    ordered = sorted(records.items(),
                     key=lambda row: (str(row[1].get("created_at") or ""),
                                      messages_rowid(row[1]), row[0]))
    return "".join(messages_thread_line(key, record)
                   for key, record in ordered)


def messages_attachment_name(raw, n):
    """A download name for one attachment, safe in a path and in a header.

    `mail_filename`'s twin, and deliberately the same alphabet: this string
    arrived from somebody else's phone and ends up in both a filename we open
    and a `Content-Disposition` we write, where a CR is a second header, a
    quote ends the parameter early and a slash is a directory somewhere else.
    A name that survives none of that becomes its own position, which is the
    number the route was asked for.
    """
    name = _MAIL_FILENAME_SAFE.sub("-", raw or "").strip("-.")[:MAIL_FILENAME_CHARS]
    return name or f"attachment-{n}"


def messages_attachment_ctype(value):
    """The declared type when it is shaped like one, otherwise the generic.

    A header hygiene check rather than trust, exactly as `mail_ctype` is:
    everything served out of this store carries `nosniff` and a download
    disposition, so the only thing this decides is whether a malformed string
    gets to be a header at all.
    """
    value = (value or "").strip().lower()
    return value if _MAIL_CTYPE.fullmatch(value) else "application/octet-stream"


def messages_attachment_ext(name, ctype):
    """What the stored file is called after the `<n>.`.

    The sanitised name's own extension first, because a file that arrived as a
    `.heic` should still be one on disk; then what the mime type is worth; then
    `bin`. Pure, and both of its inputs are kept in the sidecar beside the
    file, so the name a read computes is the name the write computed rather
    than a second guess at it.
    """
    tail = os.path.splitext(name or "")[1].lstrip(".").lower()
    if _MESSAGES_EXT.fullmatch(tail):
        return tail
    known = MESSAGES_MIME_EXT.get((ctype or "").strip().lower())
    if known:
        return known
    tail = (ctype or "").strip().lower().rsplit("/", 1)[-1]
    return tail if _MESSAGES_EXT.fullmatch(tail) else "bin"


def messages_attachment_rows(listed):
    """One record's attachments, as a thread row carries them.

    Two fields are filled in here rather than trusted off the record. `n` is
    the attachment's own position, which is how both halves of the upload name
    it, and a record written before the field existed has the position anyway
    -- it is where the item is in the list. `stored` is this box saying whether
    it holds the bytes, so it is false unless the file says otherwise; an older
    record predates the number and the bytes together.

    An entry that is not an object is skipped without renumbering the ones
    after it: the position is the identity, and shifting it would point a tile
    at somebody else's photograph.
    """
    rows = []
    for n, item in enumerate(listed or []):
        if not isinstance(item, dict):
            continue
        row = dict(item)
        carried = item.get("n")
        row["n"] = (carried if isinstance(carried, int)
                    and not isinstance(carried, bool) else n)
        row["stored"] = bool(item.get("stored"))
        rows.append(row)
    return rows


def _messages_str(row, field, limit, required=False):
    """One string field off an event. (value, None) or (None, why)."""
    value = row.get(field)
    if value is None or value == "":
        if required:
            return None, f"{field} is required"
        return None, None
    if not isinstance(value, str):
        return None, f"{field} must be a string"
    if len(value) > limit:
        return None, f"{field} must be at most {limit} characters"
    return value, None


def clean_message_event(row):
    """One ingest event, validated. Returns (record, None) or (None, why).

    Every field is checked for type and length before anything is written,
    because this is the one route on the box that accepts bulk content from
    another machine and every string in it was typed by a stranger.

    **The key is recomputed, never trusted.** A caller who could name the
    filename could name any filename, and the containment check in
    `messages_path` would be the only thing between a 16-hex regex and an
    arbitrary write. Recomputing it from the GUID makes the name a function of
    the content, so an event whose key does not match its own GUID is a bug or
    an attack and is refused either way. `chat_key` is recomputed on the same
    argument: it is what groups a conversation, and a row filed under the wrong
    conversation is a message shown to the wrong thread.

    Returns the record with `text` still on it. The caller strips it out into
    the body file, which is the split that keeps bodies out of the panel.
    """
    if not isinstance(row, dict):
        return None, "an event must be a JSON object"

    guid, why = _messages_str(row, "guid", MESSAGES_GUID_CHARS, required=True)
    if why:
        return None, why

    key = row.get("key")
    if not isinstance(key, str) or not _MESSAGES_KEY.fullmatch(key):
        return None, "key must be a 16-character message key"
    if key != messages_key(guid):
        return None, "key does not match its guid"

    rowid = row.get("rowid")
    if isinstance(rowid, bool) or not isinstance(rowid, int) or rowid < 0:
        return None, "rowid must be a non-negative integer"

    chat_guid, why = _messages_str(row, "chat_guid", MESSAGES_GUID_CHARS,
                                   required=True)
    if why:
        return None, why
    chat_key = row.get("chat_key")
    if not isinstance(chat_key, str) or not _MESSAGES_KEY.fullmatch(chat_key):
        return None, "chat_key must be a 16-character chat key"
    if chat_key != messages_key(chat_guid):
        return None, "chat_key does not match its chat_guid"

    text = row.get("text")
    if not isinstance(text, str):
        return None, "text must be a string"
    if len(text) > MESSAGES_TEXT_MAX:
        return None, f"text must be at most {MESSAGES_TEXT_MAX} characters"

    created_at, why = _messages_str(row, "created_at", 64, required=True)
    if why:
        return None, why

    for field in ("is_group", "is_from_me"):
        if not isinstance(row.get(field), bool):
            return None, f"{field} must be a boolean"

    optional = {}
    for field, limit in (("chat_identifier", MESSAGES_HANDLE_CHARS),
                         ("chat_name", MESSAGES_NAME_CHARS),
                         ("service", 32),
                         ("sender", MESSAGES_HANDLE_CHARS),
                         ("sender_name", MESSAGES_NAME_CHARS)):
        value, why = _messages_str(row, field, limit)
        if why:
            return None, why
        optional[field] = value

    participants = row.get("participants")
    if participants is None:
        participants = []
    if not isinstance(participants, list):
        return None, "participants must be a list"
    if len(participants) > MESSAGES_PARTICIPANTS_MAX:
        return None, (f"participants must hold at most "
                      f"{MESSAGES_PARTICIPANTS_MAX} entries")
    for who in participants:
        if not isinstance(who, str) or len(who) > MESSAGES_HANDLE_CHARS:
            return None, "each participant must be a short string"

    attachments = row.get("attachments")
    if attachments is None:
        attachments = []
    if not isinstance(attachments, list):
        return None, "attachments must be a list"
    if len(attachments) > MESSAGES_ATTACHMENTS_MAX:
        return None, (f"attachments must hold at most "
                      f"{MESSAGES_ATTACHMENTS_MAX} entries")
    clean_attachments = []
    for at, item in enumerate(attachments):
        if not isinstance(item, dict):
            return None, "each attachment must be an object"
        name, why = _messages_str(item, "filename", MESSAGES_NAME_CHARS)
        if why:
            return None, why
        mime, why = _messages_str(item, "mime_type", 128)
        if why:
            return None, why
        total = item.get("total_bytes")
        if total is not None and (isinstance(total, bool)
                                  or not isinstance(total, int)):
            return None, "total_bytes must be an integer or null"
        # The position, and it has to be the position. `n` is the whole of how
        # the two sides agree which file they mean -- the event names it, the
        # upload carries it in a URL, the app asks for it back by it -- so a
        # number that disagrees with where the item actually is would file one
        # photograph under another one's tile. A Bridge older than the field
        # sends none and gets its own index, which is the same answer.
        carried = item.get("n")
        if carried is not None and (isinstance(carried, bool)
                                    or carried != at):
            return None, "n must be the attachment's own position"
        # Metadata on this route; the bytes have one of their own. `stored` is
        # this box's answer and never the caller's: it is false until an upload
        # lands, and a Bridge that claimed otherwise would be claiming
        # something about a disk it cannot see.
        clean = {
            "n": at,
            "filename": name, "mime_type": mime, "total_bytes": total,
            "missing": bool(item.get("missing")),
            "stored": False,
        }
        # Only when it is true. A sticker is a kind of image and the app draws
        # it as one; the field is here so it can say so, not so every ordinary
        # photograph carries a false.
        if item.get("is_sticker"):
            clean["is_sticker"] = True
        clean_attachments.append(clean)

    return {
        "key": key,
        "guid": guid,
        "rowid": rowid,
        "chat_guid": chat_guid,
        "chat_key": chat_key,
        "chat_identifier": optional["chat_identifier"],
        "chat_name": optional["chat_name"],
        "is_group": row["is_group"],
        "service": optional["service"],
        "participants": participants,
        "sender": optional["sender"],
        "sender_name": optional["sender_name"],
        "is_from_me": row["is_from_me"],
        "created_at": created_at,
        "attachments": clean_attachments,
        "text": text,
    }, None


_MESSAGES_NUMBERISH = re.compile(r"^\+?[\d\s().-]{6,}$")


def messages_display_name(typed, directory, carried, identifier):
    """The name a conversation is drawn under.

    The allowlist's name wins only when somebody actually typed one: a name
    that is the identifier, or reads as a phone number, is the number copied
    in by a bulk allow and must not beat the address book. Then the directory
    (what the Mac's Contacts knows), then whatever the row carried, then the
    identifier itself.
    """
    ident = identifier if isinstance(identifier, str) else ""
    def real(name):
        if not isinstance(name, str):
            return None
        name = name.strip()
        if not name or name == ident or _MESSAGES_NUMBERISH.match(name):
            return None
        return name
    return real(typed) or real(directory) or real(carried) or ident or None


class MessagesSource(Source):
    """The iMessage store on disk: what the Bridge pushed, what the triage made
    of it, and whether the Mac is still there.

    Same local-disk model as `MailSource` and for the same reason: nothing here
    is polled over the network. The difference is upstream. Mail's poller is a
    timer on this box, so its silence is a fact this box can check directly;
    this channel's upstream is a laptop that is entitled to be asleep, which is
    why the heartbeat is a first-class part of the payload rather than an
    afterthought. A closed lid is not an outage, but it is not "current" either,
    and the only honest way to say so is to report when the Mac last spoke.

    **`state.json` is required; everything else degrades to empty.** The ingest
    route writes it inside the feature lock at the end of a post, so a copy that
    cannot be read is a genuine fault and is allowed to become the error
    envelope. The index records, the verdicts, the drafts and the summaries are
    written by two different programs at whatever moment each of them chose to
    stop, so each is read in its own guard: one mangled file costs its own row,
    never the panel.

    **Bodies never travel in this payload.** A conversation here is a door: who,
    when, how many unread, what the triage thought. The one exception is the
    last line's preview, which is a clipped 120 characters and is the whole
    reason a list of conversations is readable at all; the texts themselves have
    their own route with its own ceiling, because fifty full threads inside a
    document the console fetches twice a minute is a different program.

    **The chat list is read, never derived.** The writer keeps one summary per
    conversation under `messages/.chats/` and this poll opens those, in the
    numbers a person has conversations. It used to group the newest two
    thousand index records by mtime, which was true only while the store was
    the live stream and nothing else: a history download writes years of old
    messages with today's mtime, so the window stopped meaning "recent" and
    started meaning "whatever finished downloading last". The verdicts are the
    one thing still read per poll, because the pipeline owns them.
    """

    name = "messages"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.base = (block.get("base_dir") or "").rstrip("/")
        self.root = os.path.join(self.base, MESSAGES_DIR_NAME) if self.base else ""
        self.state_path = os.path.join(self.root, "state.json") if self.root else ""
        self.list_max = max(1, int(block.get("list_max", 50)))
        self.bridge_stale_after = float(block.get("bridge_stale_after_s", 120))
        # Set by the Collector that owns this source. The summaries are the
        # writer's, so the poll cannot build them; this is the one call it is
        # allowed to make back into the write side, and only to say "there is
        # an index here and no summaries -- go and make them".
        self.migrate = None

    @property
    def configured(self):
        # Re-checked on every snapshot rather than once at startup, like the
        # mailbox: the first thing any Bridge does is post a heartbeat, and the
        # panel should come alive at that moment rather than at the next restart
        # of the collector.
        return bool(self.root) and os.path.isfile(self.state_path)

    def why_dormant(self):
        if not self.base or not os.path.isdir(self.base):
            return f"messages.base_dir not found ({self.base or 'unset'})"
        return "no bridge has reported"

    # -- the directories -----------------------------------------------------

    def read_json(self, *parts):
        """One small JSON object out of the store, or None. Never raises: every
        file read here is optional by construction."""
        try:
            with open(os.path.join(self.root, *parts)) as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            return None
        return doc if isinstance(doc, dict) else None

    def read_chat_summaries(self):
        """Every conversation's summary, as [(chat_key, record)].

        One open per conversation, and there is exactly one file per
        conversation, so this is the whole cost of learning what the chat list
        is. It replaced a scan of the index that opened the newest two thousand
        records by mtime every thirty seconds -- which was both expensive once
        the store held a history and wrong, because a backfill writes years of
        old messages with today's mtime.

        Never raises. A summary that cannot be read costs its own row rather
        than the panel, like every other file in this store.
        """
        rows = []
        try:
            with os.scandir(os.path.join(self.root,
                                         MESSAGES_CHAT_SUMMARY_NAME)) as entries:
                paths = [(found.group(1), entry.path)
                         for entry in entries
                         for found in [_MESSAGES_KEY_NAME.fullmatch(entry.name)]
                         if found]
        except OSError:
            return []
        for chat, path in paths:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict):
                rows.append((chat, doc))
        return rows

    def index_has_rows(self):
        """Whether the index holds anything at all. One scandir, stopped at the
        first record: this is only ever asked when there are no summaries, to
        tell a store that has never seen a message from one that predates the
        summaries and needs them built."""
        try:
            with os.scandir(os.path.join(self.root, "index")) as entries:
                for entry in entries:
                    if _MESSAGES_KEY_NAME.fullmatch(entry.name):
                        return True
        except OSError:
            return False
        return False

    def read_ai(self, keys):
        """The triage verdicts for `keys`, as {key: record}.

        One open attempted per key, and no scandir. The directory it used to
        list grows with every inbound message ever triaged, and listing it to
        find at most a thousand named files got slower every week for no
        answer it did not already have: the caller knows exactly which keys it
        is asking about, and a key with no verdict is a file that is not there.

        A pending record is the worker counting its own attempts rather than a
        verdict, so it is skipped: absent keeps the message uncounted, which is
        true.
        """
        out = {}
        for key in keys:
            try:
                with open(os.path.join(self.root, "ai", f"{key}.json")) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict) and doc.get("status") == "ok":
                out[key] = doc
        return out

    def read_queued(self):
        """How many sends are waiting for the Bridge to perform them.

        A count, not a list: the queue itself has its own route, and a number is
        what the panel draws. Bounded by the same scan ceiling as everything
        else here.
        """
        queued = 0
        try:
            with os.scandir(os.path.join(self.root, "outbox")) as entries:
                names = [entry.path for entry in entries
                         if entry.name.endswith(".json")]
        except OSError:
            return 0
        for path in names[:MESSAGES_SCAN_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict) and doc.get("status") == "queued":
                queued += 1
        return queued

    def read_summaries(self):
        """The newest daily reads, as rows for the strip. Bodies of their own
        lists never travel; one preview line does."""
        found = []
        try:
            with os.scandir(os.path.join(self.root, "summaries")) as entries:
                for entry in entries:
                    name = entry.name
                    if not name.endswith(".json"):
                        continue
                    date = name[:-5]
                    if not DATE_SHAPE.fullmatch(date):
                        continue
                    found.append((date, entry.path))
        except OSError:
            return []

        found.sort(reverse=True)

        rows = []
        for date, path in found[:MESSAGES_SUMMARIES_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(doc, dict):
                continue
            needs = doc.get("needs_you")
            needs = needs if isinstance(needs, list) else []
            # The first thing that wants an answer, or the opening of the
            # paragraph. One line either way, because this is a row in a strip.
            preview = None
            for item in needs:
                if isinstance(item, dict):
                    preview = mail_line(item.get("line"), MESSAGES_PREVIEW_CHARS)
                    if preview:
                        break
            if not preview:
                preview = mail_line(doc.get("prose"), MESSAGES_PREVIEW_CHARS)
            rows.append({
                "date": date,
                "status": doc.get("status"),
                "read": bool(doc.get("read")),
                "archived": bool(doc.get("archived")),
                "needs_you_n": len(needs),
                "preview": preview,
                "at": doc.get("at"),
            })
        return rows

    # -- the poll ------------------------------------------------------------

    def fetch(self):
        # Deliberately undefended, exactly like the mailbox's state file: the
        # ingest route writes this through tmp + os.replace, so a copy that
        # cannot be read or is not an object is a genuine fault, and the error
        # envelope is the honest way to say so.
        with open(self.state_path) as fh:
            state = json.load(fh)
        if not isinstance(state, dict):
            raise ValueError("messages/state.json is not a JSON object")

        heartbeat = self.read_json("bridge.json") or {}
        config = self.read_json("config.json") or {}
        policies = config.get("chats")
        policies = policies if isinstance(policies, dict) else {}
        directory = self.read_json("chats.json") or {}
        names = {}
        listed = directory.get("chats")
        if isinstance(listed, list):
            for row in listed:
                if isinstance(row, dict) and isinstance(row.get("chat_key"), str):
                    names[row["chat_key"]] = row

        summaries = self.read_chat_summaries()
        # A store that predates the summaries, or one whose summaries were
        # thrown away. Built once, here, because the alternative is a chat list
        # that stays empty until the next message arrives in every conversation
        # the user has. It rebuilds the key indexes beside them, on the same
        # argument and behind their own already-built check. Costs a pass over
        # the index, which together with the start-up call is the only place in
        # this program allowed to do one; the writer's own log says how long it
        # took.
        if not summaries and self.migrate and self.index_has_rows():
            self.migrate()
            summaries = self.read_chat_summaries()

        # Newest conversation first, by the stamp the Mac put on the newest
        # message rather than by anything about the file: this is the order a
        # messages list is read in everywhere else on both machines, and it is
        # the order a history download must not be able to disturb.
        summaries.sort(key=lambda row: str(row[1].get("last_at") or ""),
                       reverse=True)
        listed = summaries[:self.list_max]

        # The verdicts, for the conversations that are actually going out. The
        # pipeline writes them and this program does not, so they are the one
        # part of a summary that cannot be kept up to date on write: they are
        # read per poll instead, over the unread inbound keys each listed chat
        # is holding. Bounded by construction at list_max *
        # MESSAGES_CHAT_KEYS_MAX opens, and typically a handful.
        #
        # The unread keys and not the newest line, deliberately. This asks the
        # same question the old scan did -- is there something here he has not
        # seen that wants an answer -- so reading a conversation still clears
        # its mark on the list. Taking the newest line in as well would be
        # cheap and would mean a chat he has just read carrying "needs you"
        # afterwards, which is a different claim than the screen has ever made.
        # The cost is the bound: a conversation sitting on more than
        # MESSAGES_CHAT_KEYS_MAX unread is judged on its newest twenty.
        wanted = set()
        for _, doc in listed:
            for key in doc.get("unread_keys") or []:
                if isinstance(key, str):
                    wanted.add(key)
        ai = self.read_ai(wanted)

        chats = []
        needs_total = 0
        # Over every conversation the store holds rather than over the listed
        # ones: the number under the list is how much is waiting, and a person
        # with sixty chats should not be told about fifty of them.
        unread_total = sum(messages_count(doc.get("unread"))
                           for _, doc in summaries)
        for chat, doc in listed:
            guid = doc.get("chat_guid")
            entry = policies.get(guid) if isinstance(guid, str) else None
            entry = entry if isinstance(entry, dict) else {}
            listed_row = names.get(chat) or {}

            urgency_max = 0
            needs_you = False
            for key in doc.get("unread_keys") or []:
                art = ai.get(key) if isinstance(key, str) else None
                if art is None:
                    continue
                level = mail_urgency(art)
                if level is not None:
                    urgency_max = max(urgency_max, level)
                if art.get("needs_you"):
                    needs_you = True

            if needs_you:
                needs_total += 1

            chats.append({
                "chat_key": chat,
                "chat_guid": guid,
                # The allowlist's name wins over the directory's, which wins
                # over the row's: the first is what the user typed, the second
                # is what the Mac's address book knows, and the third is
                # whatever the message happened to carry.
                "name": mail_line(messages_display_name(
                                      entry.get("name"), listed_row.get("name"),
                                      doc.get("chat_name"), doc.get("chat_identifier")),
                                  MESSAGES_NAME_CHARS),
                "is_group": bool(doc.get("is_group")),
                "service": doc.get("service"),
                # An unknown conversation reads as `off`, which is the direction
                # a missing entry in an allowlist should fall.
                "policy": (entry.get("send")
                           if entry.get("send") in MESSAGES_POLICIES else "off"),
                "read": bool(entry.get("read")),
                "last_at": doc.get("last_at"),
                # Clipped again on the way out. The summary keeps a longer line
                # than the envelope draws, so this ceiling stays the envelope's
                # own rather than becoming whatever the writer happened to keep.
                "last_preview": mail_line(doc.get("last_preview"),
                                          MESSAGES_PREVIEW_CHARS),
                "last_sender": ("you" if doc.get("last_is_from_me")
                                else mail_line(doc.get("last_sender"),
                                               MESSAGES_NAME_CHARS)),
                "unread": messages_count(doc.get("unread")),
                "urgency_max": urgency_max,
                "needs_you": needs_you,
            })

        helper = heartbeat.get("helper")
        helper = helper if isinstance(helper, dict) else {}
        helper_state = helper.get("state")
        helper_line = " · ".join(
            part for part in (helper.get("version"), helper_state)
            if isinstance(part, str) and part) or None

        return {
            "bridge": {
                # Ours, not the Bridge's: the moment the heartbeat landed here.
                # A clock on a laptop is not a clock this program can reason
                # about, and staleness has to be measured against ours.
                "seen_at": state.get("bridge_seen_at"),
                "version": heartbeat.get("version"),
                "host": mail_line(heartbeat.get("host"), MESSAGES_NAME_CHARS),
                "fda": heartbeat.get("fda"),
                "automation": heartbeat.get("automation"),
                "db_ok": heartbeat.get("db_ok"),
                "helper": helper_line,
                "helper_state": helper_state,
                "cursor": heartbeat.get("cursor"),
                "last_event_at": heartbeat.get("last_event_at"),
                "dropped": heartbeat.get("dropped_not_allowlisted"),
                "error": mail_line(heartbeat.get("last_error"),
                                   MESSAGES_ERROR_CHARS),
            },
            "counts": {
                # Every conversation the store holds rather than the ones the
                # list carries, deliberately: the two numbers answer different
                # questions and having both is the point.
                "chats": len(summaries),
                "unread": unread_total,
                # Conversations waiting on him, not messages. The screen says
                # "2 need you" over a list of conversations, and a message count
                # there would name a number nothing on the page adds up to.
                # Over the listed chats, because those are the only ones whose
                # verdicts were read.
                "needs_you": needs_total,
                "queued": self.read_queued(),
            },
            "chats": chats,
            "summaries": self.read_summaries(),
            "config_updated_at": config.get("updated_at"),
            # The ingest route's own account of itself, named through for
            # `semantic_status`'s sake: it is handed the payload and nothing
            # else, so it cannot open a file to find out whether the last post
            # went badly.
            "last_ingest_at": state.get("last_ingest_at"),
            "last_ingest_ok": state.get("last_ingest_ok"),
            "last_error": mail_line(state.get("last_error"),
                                    MESSAGES_ERROR_CHARS),
            "cursor": state.get("cursor"),
        }

    def semantic_status(self, data):
        # The Bridge's silence before its complaints, exactly the ordering the
        # mailbox uses: a Mac that has not spoken in two minutes is the bigger
        # fact about the conversation list on screen, and it subsumes whatever
        # the last heartbeat claimed. `age_s` cannot say any of this, because it
        # measures how recently we read the directory rather than how recently
        # anyone filled it.
        bridge = data.get("bridge") or {}
        seen = bridge.get("seen_at")
        try:
            when = datetime.fromisoformat(seen) if seen else None
        except (TypeError, ValueError):
            when = None
        if when is None:
            return "degraded", "bridge not reporting"

        # now(tzinfo) rather than now(), like the mailbox's poll check: this
        # stamp is local ISO seconds today, and an offset appearing there later
        # must not turn this line into a crash.
        age = (datetime.now(when.tzinfo) - when).total_seconds()
        if age > self.bridge_stale_after:
            return "degraded", "bridge not reporting"

        # A Bridge that is talking but cannot read. Distinct from silence and
        # drawn differently: this one is fixed in System Settings, not by waking
        # a laptop, and saying so is the difference between a person fixing it
        # in a minute and a person restarting things at random.
        if bridge.get("fda") is False:
            return "degraded", "full disk access not granted"

        state = bridge.get("helper_state")
        if state is not None and state != "verified":
            return "degraded", f"helper {state}"

        if data.get("last_ingest_ok") is False:
            # Degraded, not stale: the conversations on screen are current, and
            # what failed is an attempt to add to them. The route's own sentence
            # travels because "the last ingest failed" without a reason sends
            # the reader to the journal for something we already have.
            return "degraded", data.get("last_error") or "the last ingest failed"
        return None


# --- commits -----------------------------------------------------------------

GITHUB_API = "https://api.github.com"


class CommitsSource(Source):
    """The newest commits across every repo the token can see.

    Discovered, not listed. The list was the whole problem: it named two repos
    while the account held forty-nine, four of them created that week. A panel
    whose accuracy depends on someone remembering to edit config.json is a
    panel that is quietly wrong most of the time, and quietly wrong is the one
    failure mode this program exists to prevent.

    Discovery could cost forty-nine calls a cycle. Three things stop it:

    **One call ranks everything.** /user/repos?sort=pushed returns every repo
    the token can see, most recently pushed first, carrying `pushed_at` on
    each. Only the top few can possibly hold a recent commit, so only the top
    few are read -- `poll_repos`, default eight.

    **`pushed_at` is a validator we already paid for.** It moves only when
    something was pushed, so a repo whose `pushed_at` still matches what was
    recorded at its last successful read cannot have gained a commit, and is
    skipped without an HTTP call at all. In the steady state that collapses the
    whole source to the single ranking call.

    **ETags cover what `pushed_at` cannot.** A 304 is free -- it does not count
    against the hourly budget -- and it catches the case the timestamp gets
    wrong in the expensive direction: a push to a non-default branch moves
    `pushed_at` while leaving this repo's commit page identical.

    The one direction that can mislead is a 304 on the ranking call within
    GitHub's own ~60s response cache, which could hide a push that landed in
    that window. It surfaces on the next cycle, so the cost is bounded at one
    extra interval on a panel that is already five minutes coarse.

    Forks are excluded by default, and the ranking is what makes that matter:
    syncing a fork bumps its `pushed_at` to now, floating it to the top of the
    list, where somebody else's commits evict the owner's actual work from a
    five-row panel. Measured against this account, the second-ranked repo was a
    fork whose recent commits were all written by strangers. Set
    commits.include_forks to put them back.

    Not /search/commits (a separate, much tighter 30/min budget plus
    eventual-consistency lag that would make this panel intermittently wrong),
    and not /users/{u}/events (public repos only, so it would silently drop
    private work).
    """

    name = "commits"

    def __init__(self, cfg, block):
        super().__init__(cfg, block)
        self.token = os.environ.get(block.get("token_env") or "", "")
        self.pinned = list(block.get("repos") or [])
        self.discover = bool(block.get("discover", True))
        self.count = int(block.get("count", 5))
        self.poll_repos = int(block.get("poll_repos", 8))
        self.include_forks = bool(block.get("include_forks", False))
        self.rate_floor = int(block.get("min_rate_remaining", 50))

        self.etags = {}      # repo -> ETag of its commits page
        self.cache = {}      # repo -> the commit rows we last read
        self.pushed = {}     # repo -> the pushed_at those rows were read at
        self.repo_etag = None
        self.repo_list = []  # [(full_name, pushed_at)], newest push first
        self.rate = {}
        self.calls = 0

    @property
    def configured(self):
        return bool(self.token) and (self.discover or bool(self.pinned))

    def why_dormant(self):
        if not self.token:
            return (f"{self.block.get('token_env')} is unset; use a fine-grained "
                    f"read-only PAT with contents:read + metadata:read")
        return "commits.discover is off and commits.repos is empty"

    # -- plumbing ------------------------------------------------------------

    def api(self, path, etag=None):
        """One GitHub call, with its conditional header and the rate ledger.

        Everything goes through here so `api_calls` in the payload is counted
        rather than estimated. The call count is the entire point of this
        design, and a number nobody measures is a number that drifts.
        """
        headers = {
            "Authorization": f"Bearer {self.token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        if etag:
            headers["If-None-Match"] = etag
        self.calls += 1
        status, body, resp = http_json(f"{GITHUB_API}{path}", headers=headers,
                                       timeout=8)

        remaining = resp.get("X-RateLimit-Remaining")
        if remaining is not None:
            reset = resp.get("X-RateLimit-Reset")
            self.rate = {
                "remaining": int(remaining),
                "limit": int(resp.get("X-RateLimit-Limit") or 0),
                "resets_at": iso(datetime.fromtimestamp(int(reset))) if reset else None,
            }
        return status, body, resp

    def budget_ok(self):
        """Whether there is enough hourly budget left to spend on a repo.

        Not about this source's own appetite -- a dozen calls an hour against
        five thousand is nothing. It is about never being the process that
        spends the *last* of a shared token's budget, and about degrading one
        repo at a time if something else on this account starts misbehaving,
        rather than all at once at the moment the limit hits zero.
        """
        remaining = self.rate.get("remaining")
        return remaining is None or remaining > self.rate_floor

    def rank(self):
        """The repos worth asking about, most recently pushed first."""
        if self.pinned:
            # An explicit list beats discovery. Someone writing repos down is
            # stating an intent, and quietly polling something else because it
            # happened to be newer would be a surprise. These carry no
            # pushed_at, so none of them can take the skip path in fetch();
            # they fall through to their ETag exactly as they did before
            # discovery existed.
            return [(name, None) for name in self.pinned]

        status, body, resp = self.api(
            "/user/repos?per_page=100&sort=pushed&affiliation=owner",
            etag=self.repo_etag)

        if status == 304:
            # Nothing in the repo list changed, every `pushed_at` included, so
            # the ranking we hold is still right and every repo below will take
            # the skip path. This is the free cycle, and the common one.
            return self.repo_list
        if status != 200 or not isinstance(body, list):
            raise RuntimeError(f"GitHub /user/repos returned HTTP {status}")
        if resp.get("ETag"):
            self.repo_etag = resp["ETag"]

        rows = [(r.get("full_name"), r.get("pushed_at") or "")
                for r in body
                if r.get("full_name") and (self.include_forks or not r.get("fork"))]
        # Ranked here rather than trusting `sort=pushed` to have done it: the
        # ordering is load-bearing now, and a repo created but never pushed to
        # carries a null `pushed_at` that has to land last instead of wherever
        # a null happens to fall.
        rows.sort(key=lambda r: r[1], reverse=True)
        self.repo_list = rows

        # One page, deliberately. `sort=pushed` puts the hundred most recently
        # pushed first, and a repo that cannot reach that hundred cannot reach
        # a five-row panel either, so paginating would buy nothing at all.

        # Forget repos that were renamed, deleted, or handed away, so a process
        # that runs for months does not keep merging commits from repos it can
        # no longer even see.
        live = {name for name, _ in rows}
        for book in (self.cache, self.etags, self.pushed):
            for name in [n for n in book if n not in live]:
                del book[name]
        return rows

    def commit_rows(self, full_name, body):
        short = full_name.split("/")[-1]
        return [{
            "id": c.get("sha", "")[:7],
            "sha": c.get("sha", "")[:7],
            # Subject line only. The body never fits a five-row list.
            "title": ((c.get("commit") or {}).get("message") or "").split("\n")[0],
            "repo": short,
            # ISO, never a pre-rendered "4m". A relative string baked
            # server-side is wrong the moment the payload is cached, which
            # is exactly the lie this design is trying to avoid.
            "committed_at": (((c.get("commit") or {}).get("author") or {})
                             .get("date")),
            "url": c.get("html_url"),
        } for c in body]

    # -- the poll ------------------------------------------------------------

    def fetch(self):
        self.calls = 0
        ranked = self.rank()
        if not ranked:
            raise RuntimeError(
                "this token can see no repositories; check the PAT's "
                "repository access")
        window = ranked[:max(1, self.poll_repos)]

        ok = failed = empty = deferred = 0
        for full_name, pushed_at in window:
            # Nothing pushed since the last successful read means no new
            # commit, so the cached page is still current and the call is
            # skipped outright. This is what holds the steady state at one
            # call: the timestamp came free with the ranking.
            if (pushed_at and self.pushed.get(full_name) == pushed_at
                    and full_name in self.cache):
                ok += 1
                continue

            if not self.budget_ok():
                # Out of budget, not out of luck. What is left in the window is
                # the least recently pushed part of it, so deferring it to the
                # next cycle costs the least freshness available to give up.
                deferred += 1
                continue

            try:
                status, body, resp = self.api(
                    f"/repos/{full_name}/commits?per_page={self.count}",
                    etag=self.etags.get(full_name))
            except Exception:  # noqa: BLE001 - one bad repo is not the source
                failed += 1
                continue

            if status == 304:
                self.pushed[full_name] = pushed_at
                ok += 1
                continue
            if status == 409:
                # A repo created and never committed to. GitHub says 409 and
                # means "there is nothing here", which is a true answer to the
                # question asked, not a failure -- so it counts as read, and
                # must never colour the panel. One repo on this account is in
                # exactly this state at all times.
                self.cache[full_name] = []
                self.pushed[full_name] = pushed_at
                empty += 1
                ok += 1
                continue
            if status in (403, 429) and self.rate.get("remaining") == 0:
                raise RuntimeError(
                    f"GitHub rate limit exhausted; resets {self.rate.get('resets_at')}")
            if status != 200 or not isinstance(body, list):
                failed += 1
                continue

            if resp.get("ETag"):
                self.etags[full_name] = resp["ETag"]
            self.cache[full_name] = self.commit_rows(full_name, body)
            self.pushed[full_name] = pushed_at
            ok += 1

        # Only a total loss is an error. Some repos failing is degraded, and a
        # window we chose not to spend budget on is not a failure at all.
        if ok == 0 and not deferred:
            raise RuntimeError("no repo could be read")

        # Merged across the whole cache, not just this window: the panel wants
        # the newest commits anywhere, and a repo that has dropped out of the
        # window still holds the newest commit it ever had.
        merged = [c for rows in self.cache.values() for c in rows]
        merged.sort(key=lambda c: c.get("committed_at") or "", reverse=True)
        return {
            "commits": merged[:self.count],
            "repos_ok": ok,
            "repos_failed": failed,
            # Named, not hidden: these have no git remote at all, so GitHub
            # structurally cannot see them and the counts above are a floor.
            # Discovery does not make this obsolete -- it widens what GitHub
            # can see, and these are the repos GitHub has never heard of.
            "repos_untracked": list(self.block.get("untracked") or []),
            "rate_limit": self.rate or None,
            # Additive, and all diagnostic: how wide the net was, how much of
            # it we actually pulled, and what that cost in calls.
            "repos_seen": len(ranked),
            "repos_polled": len(window),
            "repos_empty": empty,
            "repos_deferred": deferred,
            "discovered": not self.pinned,
            "api_calls": self.calls,
        }

    def semantic_status(self, data):
        # Deferred repos need a sentence, because age_s structurally cannot
        # carry one: the fetch happened seconds ago and succeeded, and the
        # panel is still not showing everything it was asked for.
        deferred = data.get("repos_deferred") or 0
        if deferred:
            left = (data.get("rate_limit") or {}).get("remaining")
            return "degraded", (f"GitHub budget low ({left} left); {deferred} "
                                f"repo(s) deferred to the next cycle")
        if data.get("repos_failed"):
            return "degraded"
        return None


# --- the collector -----------------------------------------------------------

WORST = ["ok", "degraded", "stale", "dormant", "error"]


class Collector:
    """Owns the sources, polls them on one thread, and answers snapshots.

    One thread, not one per source: five sources on a Pi do not justify five
    threads, and a single loop makes the ordering obvious when something
    misbehaves. Each source keeps its own `next_at`, so their cadences stay
    independent regardless.
    """

    def __init__(self, cfg):
        self.cfg = cfg
        self.started_at = datetime.now()
        self.state_dir = cfg["state_dir"]
        self.sources = {
            "camera": CameraSource(cfg, cfg["camera"]),
            "pihole": PiholeSource(cfg, cfg["pihole"]),
            "nodes": NodesSource(cfg, cfg["nodes"]),
            "commits": CommitsSource(cfg, cfg["commits"]),
            "healthchecks": HealthchecksSource(cfg, cfg["healthchecks"]),
            "cmo": CmoSource(cfg, cfg["cmo"]),
            "mail": MailSource(cfg, cfg["mail"]),
            "messages": MessagesSource(cfg, cfg["messages"]),
        }
        self.stop = threading.Event()
        self._frame = {"bytes": None, "at": 0.0, "ts": None}
        self._frame_lock = threading.Lock()
        # The server is threaded, and both curation routes are read-modify-write
        # over one small file. Two dismissals landing together without this lose
        # one of the two lines.
        self._ledger_lock = threading.Lock()
        # The ask route is read-modify-write too, over a different file, and a
        # question waiting on a dismissal to finish would be two unrelated
        # things sharing a queue.
        self._ask_lock = threading.Lock()
        # And a third for the mailbox, which has five write routes over four
        # directories. Its own lock for the same reason the ask one is not the
        # ledger's, and it matters more here: two clicks on SEND must not
        # interleave between minting an id and writing the record it names.
        self._mail_lock = threading.Lock()
        # And a fifth for the messages store, which has more write routes than
        # any other feature here: an ingest, a heartbeat, a chat directory, an
        # allowlist, a read mark, two kinds of draft, a send, and a report on
        # that send. Its own lock rather than the mailbox's for the ask lock's
        # reason, and it earns it twice over -- the ingest is a loop of writes
        # that a concurrent send must not interleave with, and the send itself
        # mints an id and then writes the record it names.
        self._messages_lock = threading.Lock()
        # And a fourth for the chat threads. Its own for the ask lock's reason,
        # and it earns it more plainly than any of the others: the send route
        # is read-modify-write over a record the runner is also rewriting, and
        # the in-flight check that makes "one turn per thread" true is only
        # true if the check and the write that follows it are one step.
        self._chat_lock = threading.Lock()
        # And a fifth for Jarvis. Its own rather than the chat lock's, on the
        # argument every lock above it makes -- the two surfaces share a base
        # directory and nothing else, so a job being filed should not wait on a
        # chat thread being archived -- and it carries one duty none of the
        # others do: minting today. "Create the day record only if it is not
        # there" is a read and a write that have to be one step, or two polls
        # arriving together mint it twice and the second one overwrites the
        # first's turns with an empty array.
        self._jarvis_lock = threading.Lock()
        # {canned key: WAV bytes}, immutable after this line -- readers on
        # request threads need no lock over a dict that is never written.
        self.jarvis_canned = jarvis_load_canned()
        self.restore()
        # The chat list and every thread are read out of files the ingest
        # route keeps, and a store that predates them has neither. Built here,
        # before anything is served, because the first poll would otherwise
        # draw an empty list over a full store and the first tap would go
        # looking for one conversation in all of it. A no-op on every start
        # after the first, and on a box that has never had a message on it.
        self.sources["messages"].migrate = self.messages_migrate
        with admit("messages") as allowed:
            if allowed:
                self.messages_migrate()

    # -- persistence ---------------------------------------------------------

    def cache_path(self):
        return os.path.join(self.state_dir, "cache.json")

    def save(self):
        payload = {}
        for name, src in self.sources.items():
            with src.lock:
                if src.data is not None and src.fetched_at:
                    payload[name] = {"data": src.data, "fetched_at": iso(src.fetched_at)}
        write_atomic(self.cache_path(), json.dumps(payload))

    def restore(self):
        """Reload the last good values so a restart does not show five empty
        panels. Ages are recomputed from the stored timestamps, so nothing
        restored can ever render as fresh."""
        try:
            with open(self.cache_path()) as fh:
                payload = json.load(fh)
        except (OSError, ValueError):
            return
        for name, entry in payload.items():
            src = self.sources.get(name)
            if not src:
                continue
            try:
                src.data = entry["data"]
                src.fetched_at = datetime.fromisoformat(entry["fetched_at"])
            except (KeyError, ValueError, TypeError):
                continue

    # -- polling -------------------------------------------------------------

    def run(self):
        last_save = 0.0
        while not self.stop.is_set():
            now = time.monotonic()
            for name, src in self.sources.items():
                if now >= src.next_at:
                    with admit(name) as allowed:
                        if allowed:
                            src.poll_once()
            if now - last_save > 60:
                self.save()
                last_save = now
            self.stop.wait(1.0)

    # -- the payload ---------------------------------------------------------

    def telemetry(self):
        sources = {}
        for name, src in self.sources.items():
            with admit(name) as allowed:
                if allowed:
                    sources[name] = src.snapshot()
        counts = {k: 0 for k in WORST}
        for snap in sources.values():
            counts[snap["status"]] = counts.get(snap["status"], 0) + 1
        worst = "ok"
        for level in WORST:
            if counts.get(level):
                worst = level
        return {
            "schema": 1,
            "server_time": iso(datetime.now()),
            "collector": {
                "version": USER_AGENT,
                "started_at": iso(self.started_at),
                "uptime_s": int((datetime.now() - self.started_at).total_seconds()),
            },
            "feature_access": feature_access(),
            "health": {"worst": worst, **counts},
            "sources": sources,
        }

    # -- the camera frame ----------------------------------------------------

    def frame(self):
        """Fetch the monitor's current frame, holding its token server-side.

        This proxy is not a convenience. An <img> tag cannot send an
        Authorization header, and the dashboard's dither reads the image back
        off a canvas -- which needs it same-origin or it fails silently with a
        blank box. Serving it from here solves both at once and keeps the
        monitor bound to loopback.
        """
        block = self.cfg["camera"]
        if not block.get("frame_enabled", True):
            return None, "frame_enabled is false"
        base = (block.get("base_url") or "").rstrip("/")
        token = os.environ.get(block.get("token_env") or "", "")
        if not base or not token:
            return None, "camera source is not configured"

        min_gap = float(block.get("frame_min_interval_s", 8))
        with self._frame_lock:
            fresh = self._frame["bytes"] is not None and \
                (time.monotonic() - self._frame["at"]) < min_gap
            if fresh:
                return self._frame["bytes"], None

        req = urllib.request.Request(f"{base}/v1/frame.jpg")
        req.add_header("Authorization", f"Bearer {token}")
        req.add_header("User-Agent", USER_AGENT)
        try:
            with urllib.request.urlopen(req, timeout=6) as resp:
                body = resp.read()
                ts = resp.headers.get("X-Frame-Timestamp")
        except urllib.error.HTTPError as exc:
            try:
                detail = json.loads(exc.read() or b"{}").get("error")
            except ValueError:
                detail = None
            return None, detail or f"monitor returned HTTP {exc.code}"
        except Exception as exc:  # noqa: BLE001
            return None, str(exc)[:200]

        with self._frame_lock:
            self._frame = {"bytes": body, "at": time.monotonic(), "ts": ts}
        return body, None

    # -- one CMO briefing ----------------------------------------------------

    def briefing(self, date):
        """One day's briefing markdown, by date. Returns (bytes, None) or
        (None, why).

        The date arrives already shaped by the route's regex, so the containment
        check below is belt and braces -- the same argument as `_static`'s: a
        path assertion that exists in only one place is one edit away from
        existing nowhere, and this one serves a directory of files written by an
        agent rather than by the build.
        """
        base = (self.cfg["cmo"].get("base_dir") or "").rstrip("/")
        if not base:
            return None, "cmo.base_dir is unset"
        root = os.path.realpath(os.path.join(base, "briefings"))
        candidate = os.path.realpath(os.path.join(root, f"{date}.md"))
        if not candidate.startswith(root + os.sep):
            return None, f"no briefing for {date}"
        try:
            with open(candidate, "rb") as fh:
                return fh.read(), None
        except OSError:
            return None, f"no briefing for {date}"

    def dossier(self, slug):
        """One watchlist company's dossier markdown, by slug. Returns
        (bytes, None) or (None, why). Same shape and same belt-and-braces
        containment as `briefing`, for the same reasons.
        """
        base = (self.cfg["cmo"].get("base_dir") or "").rstrip("/")
        if not base:
            return None, "cmo.base_dir is unset"
        root = os.path.realpath(os.path.join(base, "watchlist"))
        candidate = os.path.realpath(os.path.join(root, f"{slug}.md"))
        if not candidate.startswith(root + os.sep):
            return None, f"no dossier for {slug}"
        try:
            with open(candidate, "rb") as fh:
                return fh.read(), None
        except OSError:
            return None, f"no dossier for {slug}"

    def doc(self, slug):
        """One of the operator's reference documents, by slug. Returns
        (bytes, None) or (None, why). Same shape and same belt-and-braces
        containment as `dossier`, for the same reasons.
        """
        base = (self.cfg["cmo"].get("base_dir") or "").rstrip("/")
        if not base:
            return None, "cmo.base_dir is unset"
        root = os.path.realpath(os.path.join(base, "docs"))
        candidate = os.path.realpath(os.path.join(root, f"{slug}.md"))
        if not candidate.startswith(root + os.sep):
            return None, f"no document named {slug}"
        try:
            with open(candidate, "rb") as fh:
                return fh.read(), None
        except OSError:
            return None, f"no document named {slug}"

    def ask_thread(self, tid):
        """One ask thread's record, verbatim. Returns (bytes, None) or
        (None, why). Same shape and same belt-and-braces containment as `doc`.

        The bytes as they sit on disk, not a re-serialisation of a parse: this
        file is written by the runner and read by the console, and a collector
        that round-tripped it through its own json would silently drop any
        field the runner learns to write before this program learns to read it.
        The console asks for a thread it already saw in the payload, so an
        unreadable one is a 404 like every other missing file here.
        """
        path = self.ask_thread_path(tid)
        if not path:
            return None, "cmo.base_dir is unset"
        try:
            with open(path, "rb") as fh:
                return fh.read(), None
        except OSError:
            return None, f"no thread {tid}"

    # -- the CMO curation ledger ---------------------------------------------

    # The only two writes in this program, and both land in the CMO agent's
    # own directory rather than in the state dir. Under systemd that needs
    # `ReadWritePaths=/home/pi/charon-mail/memory` in the unit -- ProtectHome
    # is read-only there, so without that line every dismissal fails EROFS
    # while every read carries on working, which looks like a console bug.

    def dismissed_path(self):
        base = (self.cfg["cmo"].get("base_dir") or "").rstrip("/")
        return os.path.join(base, "memory", DISMISSED_NAME) if base else ""

    def cmo_dismiss(self, entry):
        """Append one dismissal. Returns (count, None) or (None, why).

        Idempotent on kind + title + date. The console dismisses optimistically
        and lets the next poll confirm, so a double click, a retry after a
        timeout, or the same item open in two tabs must not write the line
        twice -- and a duplicate is not an error to report either, because the
        state the caller asked for is the state it gets.

        Append rather than rewrite: the agent reads this file at the start of
        a run, and an append is the one write it cannot catch half-done.
        """
        path = self.dismissed_path()
        if not path:
            return None, "cmo.base_dir is unset"

        with self._ledger_lock:
            try:
                lines = read_dismissed_lines(path)
            except OSError as exc:
                return None, f"cannot read the ledger: {exc.strerror or exc}"
            if any(doc and dismissal_matches(doc, entry) for _, doc in lines):
                return len(lines), None

            row = dict(entry)
            # Local ISO seconds, like every other timestamp this program
            # writes. The console never renders it as an age.
            row["dismissed_at"] = stamp()
            try:
                os.makedirs(os.path.dirname(path), exist_ok=True)
                with open(path, "a") as fh:
                    fh.write(json.dumps(row) + "\n")
            except OSError as exc:
                return None, f"cannot write the ledger: {exc.strerror or exc}"
            return len(lines) + 1, None

    def cmo_restore(self, entry):
        """Drop every line matching `entry`. Returns (count, None) or (None, why).

        Through tmp + os.replace, unlike the append: this one rewrites the
        whole file, and the agent reading a truncated copy mid-write would
        treat a dismissed item as live again. Kept lines are written back
        verbatim rather than re-serialised, so nothing another writer added to
        them is lost on the way through.

        Restoring something that is not in the file is a no-op reported as a
        success, the mirror of dismiss's idempotence and for the same reason.
        """
        path = self.dismissed_path()
        if not path:
            return None, "cmo.base_dir is unset"

        with self._ledger_lock:
            try:
                lines = read_dismissed_lines(path)
            except OSError as exc:
                return None, f"cannot read the ledger: {exc.strerror or exc}"
            kept = [text for text, doc in lines
                    if not (doc and dismissal_matches(doc, entry))]
            if len(kept) == len(lines):
                return len(lines), None
            body = "".join(f"{text}\n" for text in kept)
            if not write_atomic(path, body):
                return None, "cannot rewrite the ledger"
            return len(kept), None

    # -- ask the cmo ---------------------------------------------------------

    # The third write, and the one that starts a process rather than recording
    # a preference: a spool entry here is what wakes the ask-runner's path unit.
    # Needs `ReadWritePaths=/home/pi/charon-mail/ask` in the unit for the same
    # reason the ledger needs its own line -- ProtectHome is read-only, so
    # without it every question fails EROFS while every read carries on working.
    #
    # **This program never writes an answer turn and never deletes a spool
    # entry.** Those are the runner's, exclusively. The split is what makes the
    # queue unambiguous: a spool entry means "unanswered", and only the process
    # that answered it is in a position to say otherwise.

    def ask_dir(self):
        base = (self.cfg["cmo"].get("base_dir") or "").rstrip("/")
        return os.path.join(base, ASK_DIR_NAME) if base else ""

    def ask_thread_path(self, tid):
        """The record for one thread id, or "" if it would escape the ask dir.

        The id arrives already shaped by a regex in every caller, so this is
        belt and braces -- the same argument as `briefing`'s, and it matters
        more here because this path is also written to.
        """
        root = self.ask_dir()
        if not root:
            return ""
        root = os.path.realpath(root)
        candidate = os.path.realpath(os.path.join(root, f"{tid}.json"))
        return candidate if candidate.startswith(root + os.sep) else ""

    def ask_new_id(self):
        """A fresh thread id: local minute plus four hex.

        The minute is there to be read -- a directory listing sorts into the
        order the questions were asked -- and the hex is there because a person
        can ask twice in one minute. Re-rolled if the name is somehow taken,
        rather than appending to a stranger's conversation.
        """
        root = self.ask_dir()
        for _ in range(8):
            tid = (f"{datetime.now().strftime('%Y-%m-%d-%H%M')}"
                   f"-{os.urandom(2).hex()}")
            if not root or not os.path.exists(os.path.join(root, f"{tid}.json")):
                return tid
        return None

    def cmo_ask(self, question, thread=None):
        """Spool one question. Returns (thread_id, None, None) or
        (None, why, code).

        A three-part answer, unlike the ledger's two, because the caller has to
        tell "you named a thread that does not exist" (404) from "the disk
        refused" (500) -- both are failures of this one call and the console
        draws them differently.

        The record is written before the spool entry, and that order is the
        whole contract: the runner is woken by the spool entry, so an entry
        that appeared first could name a file that is not there yet. The
        record goes through tmp + os.replace for the same reason the restore
        rewrite does -- the runner reads this file the moment it wakes, and a
        truncated copy would be a thread with no question in it.
        """
        root = self.ask_dir()
        if not root:
            return None, "cmo.base_dir is unset", 500

        # One at a time: the server is threaded, and appending to a thread is
        # read-modify-write over its record. Its own lock rather than the
        # ledger's, so a question and a dismissal never wait on each other.
        with self._ask_lock:
            now = stamp()
            turn = {"role": "q", "text": question, "at": now,
                    "reads": None, "duration_s": None, "error": None}

            if thread:
                path = self.ask_thread_path(thread)
                if not path:
                    return None, f"no thread {thread}", 404
                try:
                    with open(path) as fh:
                        doc = json.load(fh)
                except FileNotFoundError:
                    return None, f"no thread {thread}", 404
                except (OSError, ValueError):
                    # It exists and it is not readable. Not a 404 -- saying
                    # "no such thread" about a thread that is right there sends
                    # the reader looking in the wrong place.
                    return None, f"thread {thread} is unreadable", 500
                if not isinstance(doc, dict) or not isinstance(doc.get("turns"), list):
                    return None, f"thread {thread} is not a thread record", 500
                tid = thread
                doc["turns"].append(turn)
                doc["updated"] = now
                doc["status"] = "thinking"
            else:
                tid = self.ask_new_id()
                if not tid:
                    return None, "could not mint a thread id", 500
                path = self.ask_thread_path(tid)
                if not path:
                    return None, "could not place the thread", 500
                doc = {
                    "id": tid,
                    "created": now,
                    "updated": now,
                    # No session yet. The runner mints one and writes it here,
                    # which is what a follow-up resumes.
                    "session_id": None,
                    "status": "thinking",
                    "turns": [turn],
                }

            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the thread", 500

            # Idempotent by construction: the name is the id and the content is
            # the id, so the same question spooled twice is the same one entry.
            spool = os.path.join(root, ASK_QUEUE_NAME, tid)
            try:
                os.makedirs(os.path.dirname(spool), exist_ok=True)
                with open(spool, "w") as fh:
                    fh.write(tid)
            except OSError as exc:
                # The question is on disk and nothing will come to answer it.
                # Reported as a failure rather than a success with a silence
                # after it, which is the version the console cannot explain.
                return None, f"cannot queue the question: {exc.strerror or exc}", 500

            return tid, None, None

    # -- the chat assistant --------------------------------------------------

    # The fourth write, and the one that starts a conversation rather than
    # answering a question. Needs `ReadWritePaths=/home/pi/halftone-chat` in
    # the unit for the same reason every write above it needs its own line --
    # ProtectHome is read-only, so without it every send fails EROFS while
    # every read carries on working, which looks like a broken console rather
    # than a unit file one line short.
    #
    # See the write contract at CHAT_THREADS_NAME. The short version, because
    # it is the thing to not break: **this program never writes `status`,
    # `partial`, an assistant turn, or the claude session id, and never deletes
    # a spool entry.** Those are the runner's, exclusively.

    def chat_dir(self):
        base = (self.cfg["chat"].get("base_dir") or "").rstrip("/")
        return os.path.join(base, CHAT_THREADS_NAME) if base else ""

    def chat_thread_path(self, tid):
        """The record for one thread id, or "" if it would escape the threads
        directory. Belt and braces over the route regex, like
        `ask_thread_path`, and it matters here for the same reason: this path
        is written to as well as read.
        """
        root = self.chat_dir()
        if not root:
            return ""
        root = os.path.realpath(root)
        candidate = os.path.realpath(os.path.join(root, f"{tid}.json"))
        return candidate if candidate.startswith(root + os.sep) else ""

    def chat_flag_path(self, kind, tid):
        """The spool or stop entry for one thread, contained the same way.

        `kind` is one of this module's own constants and never arrives from a
        request, but the join still gets the containment check: the id beside
        it did arrive from one, and a path built half from trusted and half
        from untrusted parts is trusted nowhere.
        """
        root = self.chat_dir()
        if not root:
            return ""
        root = os.path.realpath(os.path.join(root, kind))
        candidate = os.path.realpath(os.path.join(root, tid))
        return candidate if candidate.startswith(root + os.sep) else ""

    def chat_is_queued(self, tid):
        """Whether the runner still owes this thread an answer turn.

        The spool entry is the authority on that, not `status`: the collector
        writes the entry and the runner deletes it, so between the send
        returning and the path unit firing there is a window in which the
        thread is genuinely waiting and no process has had cause to write a
        status yet. A console that read only `status` would draw that window as
        idle and put the input back in the reader's hands mid-turn.
        """
        path = self.chat_flag_path(CHAT_QUEUE_NAME, tid)
        return bool(path) and os.path.exists(path)

    def chat_is_archived(self, tid):
        """Whether the reader has put this conversation away.

        Read exactly like `chat_is_queued` and stored the same way, because it
        is the same kind of fact: something true about a thread that is not
        written inside the thread. See CHAT_ARCHIVE_NAME.
        """
        path = self.chat_flag_path(CHAT_ARCHIVE_NAME, tid)
        return bool(path) and os.path.exists(path)

    def chat_set_archived(self, tid, archived):
        """Put a conversation away, or take it back out. Returns
        (True, None, None) or (None, why, code).

        **The second write in this program that is the act rather than a
        request for it**, and for `chat_delete`'s reason: there is no worker on
        the far side of archiving. Nothing has to run, nothing has to be
        signalled, and filing a request would be inventing a queue so that
        something else could touch a file.

        **Not refused mid-turn, and that is deliberate** -- the one place this
        parts company with `chat_delete`. Deleting under a live session leaves
        the runner writing a partial into a path nothing names any more; this
        touches a file in a different directory that the runner never reads, so
        a conversation can be archived while it is still answering and will
        finish answering. Which is the useful behaviour: a thread you have
        stopped caring about is exactly the one you want out of the list
        without waiting for it.

        The thread is read first so that archiving something that does not
        exist is a 404 rather than a flag file for a conversation nobody has.
        That orphan would then be a row-shaped hole: `chat_list` reads flags per
        row, so a flag with no record is invisible until an id is minted that
        collides with it, which is the same trap the stop flag is cleaned up to
        avoid.
        """
        with self._chat_lock:
            doc, why, code = self.chat_read(tid)
            if doc is None:
                return None, why, code

            path = self.chat_flag_path(CHAT_ARCHIVE_NAME, tid)
            if not path:
                return None, "no such conversation", 404

            if archived:
                try:
                    os.makedirs(os.path.dirname(path), exist_ok=True)
                    # Touched, not written: the flag is its own existence and a
                    # body would be a second place for this fact to live.
                    with open(path, "w"):
                        pass
                except OSError as exc:
                    return None, f"cannot archive it: {exc.strerror or exc}", 500
            else:
                try:
                    os.remove(path)
                except FileNotFoundError:
                    # Already out, which is the state the caller asked for.
                    pass
                except OSError as exc:
                    return None, f"cannot restore it: {exc.strerror or exc}", 500
            return True, None, None

    def chat_new_id(self):
        """A fresh thread id: local minute plus four hex, like `ask_new_id`."""
        root = self.chat_dir()
        for _ in range(8):
            tid = (f"{datetime.now().strftime('%Y-%m-%d-%H%M')}"
                   f"-{os.urandom(2).hex()}")
            if not root or not os.path.exists(os.path.join(root, f"{tid}.json")):
                return tid
        return None

    def chat_read(self, tid):
        """One thread record as a dict, or (None, why, code).

        Shared by every route that has to look before it writes, so the three
        ways a thread can fail to be one -- absent, unreadable, not a record --
        are told apart in a single place and answered with the same codes
        everywhere.
        """
        path = self.chat_thread_path(tid)
        if not path:
            return None, "chat.base_dir is unset", 500
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except FileNotFoundError:
            return None, f"no thread {tid}", 404
        except (OSError, ValueError):
            # It exists and it is not readable. Not a 404, for `cmo_ask`'s
            # reason: saying "no such thread" about a thread that is right
            # there sends the reader looking in the wrong place.
            return None, f"thread {tid} is unreadable", 500
        if not isinstance(doc, dict) or not isinstance(doc.get("turns"), list):
            return None, f"thread {tid} is not a thread record", 500
        return doc, None, None

    def chat_list(self):
        """Every conversation as a one-line summary, newest-updated first,
        capped. [] when the directory is missing, which is the ordinary state
        until the first conversation and the ordinary state forever on a box
        that is not the Pi.

        Two passes, exactly like `read_ask`: scandir takes names and mtimes and
        keeps the newest `CHAT_MAX` of at most `CHAT_SCAN_MAX`, then only those
        are opened. mtime is a faithful prefilter because both writers rewrite
        the whole record whenever they touch `updated_at`, so the two move
        together -- and the returned order is by `updated_at` itself, which is
        the field the console was promised.
        """
        found = []
        try:
            with os.scandir(self.chat_dir()) as entries:
                for entry in entries:
                    if not _CHAT_NAME.fullmatch(entry.name):
                        continue
                    try:
                        mtime = entry.stat().st_mtime
                    except OSError:
                        continue
                    found.append((mtime, entry.name, entry.path))
                    if len(found) >= CHAT_SCAN_MAX:
                        break
        except OSError:
            return []

        found.sort(key=lambda row: row[0], reverse=True)

        rows = []
        for _, name, path in found[:CHAT_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                # A record being rewritten mid-list is ordinary here -- that is
                # exactly what the runner does every half second while a turn
                # streams -- so one unreadable file costs its own row rather
                # than the whole list.
                continue
            if not isinstance(doc, dict):
                continue
            turns = doc.get("turns")
            turns = turns if isinstance(turns, list) else []
            # Named through rather than passed on whole, like `read_ask`: this
            # file is written by another program and the console renders every
            # field it is handed. The turn bodies stay out of the list entirely
            # -- they travel by the thread route.
            rows.append({
                "id": doc.get("id"),
                "title": str(doc.get("title") or "")[:CHAT_TITLE_CHARS],
                # The one field here derived from the bodies rather than copied
                # off the record, and the reason the list is worth reading: a
                # row that carries only its question says what was asked and
                # nothing about what came back. Empty on a thread with no answer
                # yet, which the console draws as nothing -- "waiting" is
                # already said by the queued and running words beside it.
                "preview": chat_preview(turns),
                "updated_at": doc.get("updated_at"),
                "status": doc.get("status"),
                "model": doc.get("model"),
                "turn_count": len(turns),
                # The spool entry, reported per row for the reason
                # `chat_is_queued` gives: between a send and the runner's first
                # write there is no status that says "waiting", and a list that
                # drew those threads as idle would be wrong about the one thing
                # a reader is watching this list for. Derived from the id the
                # record claims rather than from the filename, so a record that
                # disagrees with its own name cannot point this at a stranger.
                "queued": self.chat_is_queued(doc["id"])
                if isinstance(doc.get("id"), str) and _SLUG.fullmatch(doc["id"])
                else False,
                # Reported per row rather than filtered here, so one list answer
                # serves both of the console's views and switching between them
                # costs no round trip. The cap is the reason to revisit that: a
                # box with more than CHAT_MAX archived conversations would spend
                # the window on threads nobody asked to see. Fifty is a long way
                # off, and when it arrives the fix is a query parameter here,
                # not a second route.
                "archived": self.chat_is_archived(doc["id"])
                if isinstance(doc.get("id"), str) and _SLUG.fullmatch(doc["id"])
                else False,
            })
        # By `updated_at`, not by mtime: the mtime got us the right fifty files
        # and this is the order the console was promised. A record with no
        # timestamp sorts last rather than crashing the sort.
        rows.sort(key=lambda row: row["updated_at"] or "", reverse=True)
        return rows

    def chat_thread(self, tid):
        """One thread, whole, plus whether it is waiting on the runner.
        Returns (doc, None, None) or (None, why, code).

        **Parsed and re-emitted, unlike `ask_thread`, which serves the bytes as
        they sit on disk.** That trick is worth having -- it means a field the
        runner learns to write reaches the console before this program learns
        to read it -- and it is not available here, because the answer carries
        one fact that is not in the file: the spool entry. `queued` lives in
        the filesystem by design (it is what wakes the path unit), so serving
        it means building an object rather than forwarding bytes.

        The cost is real and worth naming: a field added to the record by the
        runner alone still travels, because everything the parse found is
        copied out; but a field added *beside* `queued` here needs both sides
        to agree. That is the trade -- one derived field for one round trip.
        """
        doc, why, code = self.chat_read(tid)
        if doc is None:
            return None, why, code
        # A copy rather than a mutation of the parse, so nothing here can be
        # mistaken for something the file said.
        out = dict(doc)
        out["queued"] = self.chat_is_queued(tid)
        return out, None, None

    def chat_new(self, model):
        """Start an empty conversation. Returns (tid, None, None) or
        (None, why, code).

        **No spool entry**, which is the whole difference between this and
        `send`: a thread with no turns in it has nothing to answer, and waking
        the runner to discover that would be a session started to read an empty
        file. The reader gets an id and a place to type.
        """
        root = self.chat_dir()
        if not root:
            return None, "chat.base_dir is unset", 500

        with self._chat_lock:
            tid = self.chat_new_id()
            if not tid:
                return None, "could not mint a thread id", 500
            path = self.chat_thread_path(tid)
            if not path:
                return None, "could not place the thread", 500

            now = stamp()
            doc = {
                "id": tid,
                # Named by its first message, which has not been typed yet. The
                # empty string rather than a placeholder: the console draws
                # "untitled" in its own voice, and a title written here would
                # be a fact this program invented about a conversation nobody
                # has had.
                "title": "",
                "created_at": now,
                "updated_at": now,
                "model": model,
                # Idle, and truthfully so: nothing is queued and nothing is
                # running. This is the one status this program ever writes, and
                # it writes it as part of creating the record rather than as an
                # opinion about a process.
                "status": "idle",
                "error": None,
                # No session yet. The runner mints one and writes it here,
                # which is what the next turn resumes.
                "claude_session_id": None,
                "turns": [],
                "partial": None,
            }
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the thread", 500
            return tid, None, None

    def chat_send(self, tid, text):
        """Append one user turn and wake the runner. Returns (True, None, None)
        or (None, why, code).

        The record is written before the spool entry, and that order is the
        contract: the path unit fires on the entry, so an entry that appeared
        first could name a turn that is not on disk yet.

        **One turn in flight per thread.** Refused with 409 when the thread is
        already queued or already running -- not because two turns would race
        (they would not; the runner drains one at a time) but because the
        second one would be answered by a session that never saw the first
        one's answer, which is a conversation that quietly stops being one. The
        check and the write share the lock, so the answer cannot go stale
        between them.
        """
        root = self.chat_dir()
        if not root:
            return None, "chat.base_dir is unset", 500

        with self._chat_lock:
            doc, why, code = self.chat_read(tid)
            if doc is None:
                return None, why, code
            if self.chat_is_queued(tid):
                return None, "this thread already has a turn waiting", 409
            if doc.get("status") == "running":
                return None, "this thread is mid-answer", 409

            now = stamp()
            doc.setdefault("turns", []).append(
                {"role": "user", "text": text, "at": now})
            doc["updated_at"] = now
            # The first message names the conversation. Only the first: a title
            # that moved with the newest turn would rename every thread in the
            # list every time it was used.
            if not doc.get("title"):
                doc["title"] = " ".join(text.split())[:CHAT_TITLE_CHARS]
            # `status` is deliberately untouched. See the contract above: this
            # process has started nothing, and the spool entry below is the
            # honest way to say a turn is owed.

            path = self.chat_thread_path(tid)
            if not path or not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the thread", 500

            # Idempotent by construction, like the ask spool: the name is the
            # id and the content is the id, so the same turn spooled twice is
            # the same one entry.
            spool = self.chat_flag_path(CHAT_QUEUE_NAME, tid)
            if not spool:
                return None, "could not place the spool entry", 500
            try:
                os.makedirs(os.path.dirname(spool), exist_ok=True)
                with open(spool, "w") as fh:
                    fh.write(tid)
            except OSError as exc:
                # The turn is on disk and nothing will come to answer it.
                # Reported as a failure rather than a success with a silence
                # after it, which is the version the console cannot explain.
                return None, f"cannot queue the turn: {exc.strerror or exc}", 500
            return True, None, None

    def chat_set_model(self, tid, model):
        """Change which model answers this thread. Returns (True, None, None)
        or (None, why, code).

        Refused while a turn is in flight, for the reason the send refusal
        gives in miniature: the runner reads this field when it builds the
        argv, and a value that changed after it read it would put a thread on
        screen claiming to have been answered by a model that did not answer
        it.
        """
        with self._chat_lock:
            doc, why, code = self.chat_read(tid)
            if doc is None:
                return None, why, code
            if self.chat_is_queued(tid) or doc.get("status") == "running":
                return None, "the model cannot change mid-answer", 409
            if doc.get("model") == model:
                # Already what was asked for. A success rather than a no-op
                # error, the same idempotence `cmo_dismiss` follows: the state
                # the caller asked for is the state it gets.
                return True, None, None

            doc["model"] = model
            # `updated_at` is deliberately not touched. It orders the list by
            # when the conversation last moved, and flipping a toggle is not
            # the conversation moving -- a thread that jumped to the top of the
            # list on a settings change would be lying about what happened.
            path = self.chat_thread_path(tid)
            if not path or not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the thread", 500
            return True, None, None

    def chat_set_effort(self, tid, effort):
        """`chat_set_model`'s twin, and `jarvis_set_effort`'s cousin: refused
        mid-answer because the runner has already read the record to build its
        argv, and `updated_at` untouched because flipping a setting is not the
        conversation moving.

        Validation happens at the dispatch, against the same JARVIS_EFFORTS the
        jarvis route checks -- one CLI, one enum, one place it is written down.
        """
        with self._chat_lock:
            doc, why, code = self.chat_read(tid)
            if doc is None:
                return None, why, code
            if self.chat_is_queued(tid) or doc.get("status") == "running":
                return None, "the effort cannot change mid-answer", 409
            if doc.get("effort") == effort:
                return True, None, None
            doc["effort"] = effort
            path = self.chat_thread_path(tid)
            if not path or not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the thread", 500
            return True, None, None

    def chat_stop(self, tid):
        """Ask the runner to abandon the turn it is working on. Returns
        (True, None, None) or (None, why, code).

        A flag on disk rather than a signal, because this process does not know
        the runner's pid and should not: the runner is a oneshot unit started
        by a path watcher, it may not have started yet, and the thing being
        asked for is "stop whatever is or is about to be running for this
        thread". A file says that to all three cases at once.

        **A no-op on an idle thread is a success, not a 409.** Stopping
        something that already stopped is the state the caller asked for, and a
        console that had to tell a hurried second click from a real error would
        be drawing an error over a thread that is simply finished. The runner
        clears a flag it finds with nothing to stop.
        """
        with self._chat_lock:
            doc, why, code = self.chat_read(tid)
            if doc is None:
                return None, why, code

            flag = self.chat_flag_path(CHAT_STOP_NAME, tid)
            if not flag:
                return None, "could not place the stop flag", 500
            try:
                os.makedirs(os.path.dirname(flag), exist_ok=True)
                with open(flag, "w") as fh:
                    fh.write(tid)
            except OSError as exc:
                return None, f"cannot ask it to stop: {exc.strerror or exc}", 500
            return True, None, None

    def chat_delete(self, tid):
        """Take a conversation off the box. Returns (True, None, None) or
        (None, why, code).

        **The one write in this program that is the act rather than a request
        for it**, and the exception to the division of labour stated at the top
        of this section rather than a hole in it. Every other chat write puts
        something on disk for `chat-runner.py` to pick up, because every other
        one needs a model run or a subprocess signalled. This one needs neither:
        there is no worker on the far side of a deletion, and filing a request
        to delete a file would be inventing a queue so that something else could
        call `os.remove`.

        **Refused while a turn is in flight, and that is the whole of the
        interlock.** The runner rewrites the record every half second while an
        answer streams; deleting it under a live session leaves that process
        writing a partial into a path nothing names any more, and the file it
        recreates on its next write is a conversation the reader believes he
        deleted. `queued` is refused for the same reason one step earlier -- the
        turn is filed and the unit has not fired yet, so nothing is running and
        something is about to be. The stop route is the way through: stop it,
        then delete it.

        The flags go with the record, and the queue entry is not one of the
        things that can be here to go: a queued thread was refused above, so
        only a stale stop flag can survive this, and leaving one behind would
        arm the next thread to be minted with this id. Nothing mints a repeat of
        a stamped id, which is exactly the kind of "cannot happen" that stops
        being true the day the clock is wrong.
        """
        with self._chat_lock:
            doc, why, code = self.chat_read(tid)
            if doc is None:
                return None, why, code

            if self.chat_is_queued(tid) or doc.get("status") == "running":
                return None, "a turn is in flight", 409

            path = self.chat_thread_path(tid)
            if not path:
                return None, "no such conversation", 404
            try:
                os.remove(path)
            except FileNotFoundError:
                # Already gone, which is the state the caller asked for. Not an
                # error for `chat_stop`'s reason: a second click on a row that
                # has already left the list would otherwise draw a failure over
                # a deletion that worked.
                pass
            except OSError as exc:
                return None, f"cannot delete it: {exc.strerror or exc}", 500

            # Both flags go with the record. The archive flag matters more than
            # the stop flag does: a stale stop flag arms the next thread minted
            # with this id, and a stale archive flag would file it away on
            # sight, so a reader who deleted a thread and started a new one
            # would find the new one already gone from the list.
            for kind in (CHAT_STOP_NAME, CHAT_ARCHIVE_NAME):
                flag = self.chat_flag_path(kind, tid)
                if not flag:
                    continue
                try:
                    os.remove(flag)
                except OSError:
                    # Tidiness, not correctness, and the record it belonged to
                    # is already gone. Saying FAILED here would report a
                    # deletion that happened as one that did not.
                    pass
            return True, None, None

    # -- jarvis --------------------------------------------------------------

    # The write contract is stated at JARVIS_DIR_NAME. The short version,
    # because it is the thing to not break: **once a record exists, this program
    # never writes `status`, `partial`, an assistant turn, the claude session
    # id, `context`, a compaction's `kept`, or anything at all on a job
    # record, and never deletes a spool entry.** Those belong to the two
    # runners. The one status written here is the `idle` that is part of
    # creating a record, which `chat_new` writes for the same reason: it is a
    # field of a new file rather than an opinion about a process.
    #
    # **This needs `ReadWritePaths=/home/pi/halftone-chat/jarvis` in the
    # unit, and the directory has to exist before the unit starts.** The chat
    # section's line grants `.../halftone-chat/threads` and not its parent, so
    # nothing here inherits it: without a line of its own, ProtectHome leaves
    # this tree read-only and every jarvis write fails EROFS while every read
    # carries on working -- which looks like a broken console rather than a unit
    # file one line short. Exactly the trap the ledger, the ask directory and
    # the mailbox each have a line for.

    def jarvis_dir(self):
        """The root of the jarvis tree.

        **Under `chat.base_dir` rather than under a `jarvis.base_dir` of its
        own**, because the contract's paths put `jarvis/` and `threads/` side by
        side under one `$BASE` and a second knob naming the same parent is a
        second knob that can disagree with the first. The failure that would
        buy is the quiet one: a box where the collector files a turn into one
        tree while the runner watches another, which looks exactly like an
        assistant that has stopped answering.
        """
        base = (self.cfg["chat"].get("base_dir") or "").rstrip("/")
        return os.path.join(base, JARVIS_DIR_NAME) if base else ""

    def jarvis_days_dir(self):
        root = self.jarvis_dir()
        return os.path.join(root, JARVIS_DAYS_NAME) if root else ""

    def jarvis_jobs_dir(self):
        root = self.jarvis_dir()
        return os.path.join(root, JARVIS_JOBS_NAME) if root else ""

    def jarvis_day_id(self):
        """Today, local time, which is also the id of today's record.

        Computed once per request and then passed around rather than re-read at
        each step: a write that asked twice would, once a year at midnight, file
        a turn into one day and its spool entry into the next.
        """
        return datetime.now().strftime("%Y-%m-%d")

    def jarvis_day_path(self, day):
        """The record for one day, or "" if it would escape the days directory.
        Belt and braces over the route regex, like `chat_thread_path`, and it
        matters here for the same reason: this path is written to as well as
        read.
        """
        root = self.jarvis_days_dir()
        if not root or not isinstance(day, str):
            return ""
        root = os.path.realpath(root)
        candidate = os.path.realpath(os.path.join(root, f"{day}.json"))
        return candidate if candidate.startswith(root + os.sep) else ""

    def jarvis_job_path(self, jid):
        """The record for one job, contained the same way."""
        root = self.jarvis_jobs_dir()
        if not root or not isinstance(jid, str):
            return ""
        root = os.path.realpath(root)
        candidate = os.path.realpath(os.path.join(root, f"{jid}.json"))
        return candidate if candidate.startswith(root + os.sep) else ""

    def jarvis_flag_path(self, kind, name):
        """One of the four spool or stop entries, contained the same way.

        `kind` is this module's own constant and never arrives from a request,
        but the join still gets the containment check for `chat_flag_path`'s
        reason: the name beside it did arrive from one, and a path built half
        from trusted and half from untrusted parts is trusted nowhere.
        """
        root = self.jarvis_dir()
        if not root or not isinstance(name, str):
            return ""
        root = os.path.realpath(os.path.join(root, kind))
        candidate = os.path.realpath(os.path.join(root, name))
        return candidate if candidate.startswith(root + os.sep) else ""

    def jarvis_is_queued(self, day):
        """Whether the say runner still owes today an answer turn.

        The spool entry is the authority, not `status`, for the reason
        `chat_is_queued` gives at length: between the say route returning and
        the path unit firing, the day is genuinely waiting and no process has
        had cause to write a status yet. A console reading only `status` would
        draw that window as idle and hand the input back mid-turn.

        The shape is asserted here rather than at each caller, because the day
        this is asked about comes off a record two other programs write: the
        containment check inside `jarvis_flag_path` already stops a doctored
        `day` escaping the tree, and this stops one pointing at a different day
        inside it.
        """
        if not isinstance(day, str) or not DATE_SHAPE.fullmatch(day):
            return False
        path = self.jarvis_flag_path(JARVIS_SAY_NAME, day)
        return bool(path) and os.path.exists(path)

    def jarvis_job_is_queued(self, jid):
        """The same fact about one job, out of the other spool, shape-checked
        for the same reason: a card names its job and the card is somebody
        else's file.
        """
        if not isinstance(jid, str) or not _JARVIS_JOB_ID.fullmatch(jid):
            return False
        path = self.jarvis_flag_path(JARVIS_JOBSPOOL_NAME, jid)
        return bool(path) and os.path.exists(path)

    def jarvis_new_job_id(self, day):
        """A fresh job id: the day it belongs to, the local minute, four hex.

        **The day comes from the caller rather than from the clock**, which is
        the one place this differs from `chat_new_id` and the only place it
        matters. The day was decided when the request arrived; a request that
        crosses midnight between those two lines would otherwise mint an id
        filed under tomorrow, and tomorrow's record would then be the one that
        reconciled a card sitting in today's transcript.

        Re-rolled if the name is somehow taken, rather than writing over a job
        that is running.
        """
        root = self.jarvis_jobs_dir()
        for _ in range(8):
            jid = f"{day}-{datetime.now().strftime('%H%M')}-{os.urandom(2).hex()}"
            if not root or not os.path.exists(os.path.join(root, f"{jid}.json")):
                return jid
        return None

    def jarvis_read_day(self, day):
        """One day record as a dict, or (None, why, code).

        Shared by every route that has to look before it writes, exactly like
        `chat_read`, so the three ways a day can fail to be one -- absent,
        unreadable, not a record -- are told apart in one place and answered
        with the same codes everywhere. A record that gets past this has a
        `turns` list, which is what lets every caller below append without
        asking again.
        """
        path = self.jarvis_day_path(day)
        if not path:
            return None, "chat.base_dir is unset", 500
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except FileNotFoundError:
            return None, f"no record for {day}", 404
        except (OSError, ValueError):
            # It exists and it is not readable. Not a 404, for `chat_read`'s
            # reason: saying "no such day" about a day that is right there sends
            # the reader looking in the wrong place.
            return None, f"the record for {day} is unreadable", 500
        if not isinstance(doc, dict) or not isinstance(doc.get("turns"), list):
            return None, f"the record for {day} is not a day record", 500
        return doc, None, None

    def jarvis_read_job(self, jid):
        """One job record as a dict, or (None, why, code). `jarvis_read_day`'s
        three failures, minus the turns check -- a job has no transcript, and
        every other field in it belongs to the job runner rather than to this
        program, which is why nothing here asserts what they are.
        """
        path = self.jarvis_job_path(jid)
        if not path:
            return None, "chat.base_dir is unset", 500
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except FileNotFoundError:
            return None, f"no job {jid}", 404
        except (OSError, ValueError):
            return None, f"job {jid} is unreadable", 500
        if not isinstance(doc, dict):
            return None, f"job {jid} is not a job record", 500
        return doc, None, None

    def jarvis_day_jobs(self, day):
        """Every job record minted on `day`, oldest first, capped. [] when the
        directory is missing, which is the ordinary state until the first job.

        The names alone answer "whose jobs are these" -- a job id opens with the
        day it was filed under, see `jarvis_new_job_id` -- so only that day's
        records are ever opened, and a box with a year of jobs on it costs one
        scandir.

        The names get the right files and `created_at` gets the right order,
        which is `chat_list`'s two-step for `chat_list`'s reason. An id is
        stamped to the minute and finished with four random hex, so two jobs
        filed in the same minute sort by a coin toss -- rare, entirely possible
        while somebody is firing off work, and exactly the moment an order that
        looks chronological had better be one.
        """
        root = self.jarvis_jobs_dir()
        if not root:
            return []
        names = []
        try:
            with os.scandir(root) as entries:
                for entry in entries:
                    found = _JARVIS_JOB_NAME.fullmatch(entry.name)
                    if not found or not found.group(1).startswith(f"{day}-"):
                        continue
                    names.append(found.group(1))
        except OSError:
            return []
        # **Newest kept, not earliest.** A job id is `<day>-HHMM-xxxx`, so a
        # plain ascending sort puts the morning first and `[:MAX]` would then
        # keep the oldest fifty and drop everything after them -- on a busy day
        # the cards that vanish would be the ones still running. Reversed here
        # and re-sorted ascending below, so what is dropped is the far end of
        # the morning and what survives is what a reader is watching.
        names.sort(reverse=True)
        out = []
        for jid in names[:JARVIS_DAY_JOBS_MAX]:
            doc, _, _ = self.jarvis_read_job(jid)
            # A job being rewritten mid-read is ordinary here -- that is what
            # the job runner does while one runs -- so an unreadable record
            # costs its own card rather than the whole transcript. `chat_list`
            # makes this call for the same reason one level down.
            if doc is not None:
                out.append(doc)
        # A record with no timestamp sorts first rather than crashing the sort,
        # which is the same shrug `chat_list` gives at the other end.
        out.sort(key=lambda job: job.get("created_at") or "")
        return out

    def jarvis_job_counts(self):
        """How many jobs each day has, as {day: count}, from the job
        directory's names alone.

        One scandir and no opens at all, because a job id opens with its day and
        the number the list wants is a tally of prefixes. Counted off the
        records rather than off each day's cards for two reasons: the records
        are the fact and the cards are the copy, and reconciling sixty days
        properly would be sixty scandirs on a route whose whole job is to be
        cheap enough to poll.
        """
        counts = {}
        root = self.jarvis_jobs_dir()
        if not root:
            return counts
        try:
            with os.scandir(root) as entries:
                for entry in entries:
                    found = _JARVIS_JOB_NAME.fullmatch(entry.name)
                    if not found:
                        continue
                    counts[found.group(1)[:10]] = (
                        counts.get(found.group(1)[:10], 0) + 1)
        except OSError:
            return {}
        return counts

    def jarvis_card(self, job, at=None):
        """One `kind: "job"` turn for a job record.

        A view of the job rather than a copy of it: only the three fields the
        contract names travel, because a card carrying the job's own prose would
        put the same paragraph in the transcript twice and the jobs route
        already serves the record whole.

        **The card says `state` and the job record says `status`**, and the
        rename happens here rather than in either file. It is not an accident of
        two authors: `status` is what every record on this box calls the field a
        runner owns, and `state` is what the contract calls the word on the
        card -- which is a different value, because the card folds `queued` into
        it. Translating in one function is how both stay true.

        `queued` is folded in rather than reported beside it because the card is
        one word on screen, and the seconds between a job being filed and its
        path unit firing are exactly the seconds somebody is watching it -- so a
        card reading `idle` in that window would be the same lie
        `chat_is_queued` exists to prevent, one field over.
        """
        jid = job.get("id")
        return {
            "kind": "job",
            "job_id": jid,
            "title": str(job.get("title") or "")[:CHAT_TITLE_CHARS],
            # The card keeps the time it was filed at, not the time the job last
            # moved: it sits in a transcript, and a line that slid down the page
            # every time a job changed state would reorder the conversation
            # around it.
            "at": at or job.get("created_at"),
            "state": ("queued" if self.jarvis_job_is_queued(jid)
                      else job.get("status")),
        }

    def jarvis_reconcile_jobs(self, doc):
        """The day's turns with every job card carrying its job record's state,
        including cards that never made it onto the record. Returns a new list
        and does not touch `doc`.

        **Reconciled on read, never on write**, and the reasons compound.

        The write version needs the job runner to open the day record every time
        a job changes state. That is precisely the one-writer-per-field rule the
        two lanes exist to keep: it would put the work lane inside the file the
        talk lane rewrites every half second, so a card would be updated by one
        process and overwritten by another with no lock between them. Two
        programs racing over one array so that a label can say `done` is a lot
        of machinery to arrive at the wrong architecture.

        The read version costs one scandir and at most JARVIS_DAY_JOBS_MAX
        opens, and it cannot be stale by construction -- it asks the job records
        what they say at the moment somebody looks, so there is no window in
        which the card and the job disagree, because there is no second copy to
        disagree with.

        And it repairs the one race this surface genuinely has. `POST
        /v1/jarvis/job` never answers 409, so a card is appended while the say
        runner may be mid-turn and about to rewrite the record from its own
        copy -- a rewrite that drops the card entirely. A card that is missing
        here is rebuilt from the job record and slotted in at its own timestamp,
        so a lost append costs nothing a reader can see.
        """
        turns = doc.get("turns")
        turns = list(turns) if isinstance(turns, list) else []

        day = doc.get("day")
        jobs = {}
        if isinstance(day, str) and DATE_SHAPE.fullmatch(day):
            for job in self.jarvis_day_jobs(day):
                jid = job.get("id")
                if isinstance(jid, str) and _JARVIS_JOB_ID.fullmatch(jid):
                    jobs[jid] = job
        if not jobs:
            return turns

        seen = set()
        out = []
        for turn in turns:
            if not isinstance(turn, dict) or turn.get("kind") != "job":
                out.append(turn)
                continue
            job = jobs.get(turn.get("job_id"))
            if job is None:
                # A card whose job record is gone. Left exactly as it was found
                # rather than dropped: the transcript is the record of the day,
                # and a line vanishing out of the middle of it because a file
                # was tidied away is a worse story than a stale word.
                out.append(turn)
                continue
            seen.add(turn.get("job_id"))
            # The card's own `at` wins, so a card that has been sitting in this
            # transcript since ten o'clock does not move because the job it
            # names finished at noon.
            out.append({**turn, **self.jarvis_card(job, turn.get("at"))})

        missing = [self.jarvis_card(job) for jid, job in jobs.items()
                   if jid not in seen]
        if not missing:
            return out

        # Merged by timestamp rather than appended, and stably: a rebuilt card
        # belongs where the job was filed, which is in the middle of a
        # conversation that carried on around it. Appending them all to the end
        # would put this morning's job under this afternoon's answer.
        #
        # A tie goes to the turn already on the record, which is why the test is
        # `<` and not `<=`. Timestamps here are seconds, so a job filed in the
        # same second as a turn is common rather than exotic -- and the card was
        # appended after that turn when it was written, so putting it back in
        # front of it would reorder the transcript to repair it.
        missing.sort(key=lambda card: card.get("at") or "")
        merged = []
        i = 0
        for turn in out:
            at = (turn.get("at") if isinstance(turn, dict) else None) or ""
            while i < len(missing) and (missing[i].get("at") or "") < at:
                merged.append(missing[i])
                i += 1
            merged.append(turn)
        merged.extend(missing[i:])
        return merged

    def jarvis_notice(self, doc, in_flight):
        """Append the context warning if the day has just crossed a threshold.
        Returns True when it wrote one, having mutated `doc`; the caller
        persists it.

        The three rules the contract makes load-bearing are all here. It is
        written rather than asked for (see `jarvis_notice_text`). It fires once
        per crossing, by comparing the band of the current reading against the
        band of the largest notice already on the day (see
        `jarvis_notice_band`). And it carries `action: "compact"`, which is what
        the console draws a button on -- the news alone would be a line telling
        the reader that something is wrong and nothing about what to do.

        **Not written while a turn is in flight**, which the contract does not
        ask for and the file layout demands. The say runner rewrites this record
        every half second from its own copy, so a turn appended underneath it
        survives only until the next repaint. Deferring costs at most one
        poll -- the console reads this route every five seconds while idle --
        and the button the notice carries would have answered 409 during that
        window anyway, because compaction refuses under a live session.

        A stale reading is skipped for a harder reason than caution: after a
        compaction, `pct` is what the *old* session sent and nothing has run
        since, so warning on it would be warning about context that has already
        been thrown away.
        """
        if in_flight:
            return False
        context = doc.get("context")
        if not isinstance(context, dict) or context.get("stale"):
            return False
        pct = context.get("pct")
        if isinstance(pct, bool) or not isinstance(pct, (int, float)):
            return False
        pct = int(pct)
        band = jarvis_band(pct)
        if not band or band <= jarvis_notice_band(doc.get("turns")):
            return False

        now = stamp()
        doc["turns"].append({
            "kind": "notice", "notice": "context",
            "text": jarvis_notice_text(pct), "at": now,
            # The reading, not the threshold. The sentence says 52 and the
            # record has to agree with the sentence; the threshold is recovered
            # from it by `jarvis_band` whenever the question is asked again.
            "pct": pct,
            "action": "compact",
        })
        # A notice is a line appearing in the transcript, so the day has moved
        # and the list should say so. This is the one difference from
        # `chat_set_model`, which deliberately leaves the timestamp alone: a
        # toggle is not the conversation moving and a warning is.
        doc["updated_at"] = now
        return True

    def _jarvis_ensure_day(self, day, mint=False, notice=False):
        """The raw record for one day, minted and warned as asked. Returns
        (doc, None, None) or (None, why, code).

        **Called with `self._jarvis_lock` held**, by every route that touches a
        day, so "does today exist yet" is asked and answered in one place.

        Minting is a read followed by a write and is safe only because they
        share the lock: `write_atomic` replaces whatever is there, so two polls
        arriving together without it would both see 404 and the second would
        drop an empty `turns` array on top of the first. An O_EXCL create would
        make that safe against other processes too and is not used, because
        nothing else on this box mints a day record and tmp + os.replace is the
        discipline every other write here keeps.

        The record comes back exactly as it sits on disk. The reconciliation and
        `queued` are `jarvis_serve`'s, and are deliberately not folded in: this
        is the object the write routes append to, and persisting a reconciled
        copy is the one thing `jarvis_reconcile_jobs` exists not to do.
        """
        path = self.jarvis_day_path(day)
        if not path:
            return None, "chat.base_dir is unset", 500

        doc, why, code = self.jarvis_read_day(day)
        if doc is None:
            if code != 404 or not mint:
                return None, why, code
            # A new day starts on the cheap model rather than inheriting
            # yesterday's. The toggle is a decision about one conversation, and
            # a choice made once in August that quietly governed every morning
            # after it would be a setting pretending to be a gesture.
            doc = jarvis_new_day(day, CHAT_MODELS[0])
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the day", 500

        if notice and self.jarvis_notice(
                doc, in_flight=self.jarvis_is_queued(day)
                or doc.get("status") == "running"):
            # A failed write here is deliberately not an error. The reading that
            # earned the warning is still on the record, so the next poll works
            # it out again and tries again -- and refusing to serve a
            # conversation over one line that can be written a second later
            # would be the wrong end of the stick entirely.
            write_atomic(path, json.dumps(doc, indent=2))
        return doc, None, None

    def jarvis_serve(self, doc):
        """One day record as the console gets it: job cards brought up to date,
        `queued` beside the status.

        A copy rather than a mutation of the parse, for `chat_thread`'s reason
        -- nothing here can be mistaken for something the file said -- and it
        carries `chat_thread`'s trade too. A field the say runner learns to
        write travels without this program learning to read it, because
        everything the parse found is copied out; a field added *beside*
        `queued` needs both sides to agree.
        """
        out = dict(doc)
        out["turns"] = self.jarvis_reconcile_jobs(doc)
        out["queued"] = self.jarvis_is_queued(doc.get("day"))
        return out

    def jarvis_today(self):
        """Today's conversation, minting it on the first look. Returns
        (doc, None, None) or (None, why, code).

        Minting on a GET is not the accident it looks like. A day record is not
        a thing a person creates -- the day happens whether or not anybody types
        into it -- so there is no gesture to hang a POST on, and the alternative
        is a console that has to ask for today, read a 404 and ask for it to
        exist before it can draw an empty page.
        """
        with self._jarvis_lock:
            day = self.jarvis_day_id()
            doc, why, code = self._jarvis_ensure_day(day, mint=True, notice=True)
            if doc is None:
                return None, why, code
            return self.jarvis_serve(doc), None, None

    def jarvis_day(self, day):
        """One day, whole, or (None, why, code). 404 when there is no record --
        a day nobody spoke on has none, and minting one because somebody
        scrolled back to it would fill this directory with empty mornings.

        Warned only when it is today. A crossing is a fact about a conversation
        that can still be compacted; writing one into a record that has been
        finished for a week would be a button offering to fold a day that
        nothing is going to send again.
        """
        with self._jarvis_lock:
            doc, why, code = self._jarvis_ensure_day(
                day, mint=False, notice=day == self.jarvis_day_id())
            if doc is None:
                return None, why, code
            return self.jarvis_serve(doc), None, None

    def jarvis_days(self):
        """Every day as a one-line summary, newest first, capped. [] when the
        directory is missing, which is the ordinary state until the first
        conversation and the ordinary state forever on a box that is not the Pi.

        **Sorted by name, not by mtime**, which is the one place this parts
        company with `chat_list`. A day's id is its date, so the filename is
        already the order the console was promised -- and mtime is not: a
        compaction or a late notice on Tuesday would otherwise lift it over
        Wednesday, which is a list that reorders itself while nothing new has
        happened.

        The turn bodies stay out entirely, for `chat_list`'s reason: they travel
        on the day route, and a console that had to be sent sixty transcripts to
        draw sixty rows is reading a year of conversation to show a page.
        """
        found = []
        try:
            with os.scandir(self.jarvis_days_dir()) as entries:
                for entry in entries:
                    match = _JARVIS_DAY_NAME.fullmatch(entry.name)
                    if not match:
                        continue
                    found.append((match.group(1), entry.path))
        except OSError:
            return []

        found.sort(key=lambda row: row[0], reverse=True)
        counts = self.jarvis_job_counts()

        rows = []
        for day, path in found[:JARVIS_DAYS_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                # A record being rewritten mid-list is ordinary -- that is what
                # the say runner does every half second while a turn streams --
                # so one unreadable file costs its own row rather than the list.
                continue
            if not isinstance(doc, dict):
                continue
            turns = doc.get("turns")
            turns = turns if isinstance(turns, list) else []
            context = doc.get("context")
            context = context if isinstance(context, dict) else {}
            says, cards = jarvis_counts(turns)
            rows.append({
                # The record's own `day` rather than the filename, so a record
                # that disagrees with its own name cannot make a row that points
                # at a stranger. `chat_list` derives its flags the same way.
                "day": doc.get("day") or day,
                "updated_at": doc.get("updated_at"),
                "turn_count": says,
                # Off the job directory rather than off the cards, because the
                # cards are a copy that a lost append can be one short of. See
                # `jarvis_job_counts`; `cards` is the fallback for the day this
                # box has a jobs directory it cannot read.
                "job_count": counts.get(doc.get("day") or day, cards),
                "status": doc.get("status"),
                "queued": self.jarvis_is_queued(doc.get("day") or day),
                "model": doc.get("model"),
                # Shaped even when the day has no reading, because a row reaches
                # into this object to draw a meter and `context.pct` on a null
                # is a client that stops rendering the list. The nulls inside it
                # are the console's cue to draw `-`; it is told never to
                # estimate one.
                "context": {"pct": context.get("pct"),
                            "tokens": context.get("tokens")},
                # `chat_preview` unchanged, and it needs nothing added: it walks
                # backwards for the newest `role: "assistant"` turn, and in this
                # transcript only a `say` turn carries a role at all, so a job
                # card and a notice are skipped without it ever learning what
                # they are.
                "preview": chat_preview(turns),
            })
        return rows

    def jarvis_jobs(self):
        """Every job, newest first, capped. [] when the directory is missing.

        **Served whole, unlike `chat_list`'s rows**, and the reason is that
        there is nothing underneath this route: the contract gives jobs a list
        and no door of their own, so a summary here would leave the console with
        no way at all to show what a job was asked to do or what it came back
        with. The cost is named rather than hidden -- a job's text is capped at
        CHAT_TEXT_MAX and fifty of them is the worst this route can be -- and it
        buys what `chat_thread` buys: a field the job runner learns to write
        reaches the console without this program learning to read it, which
        matters more here because this program writes a job record once and the
        runner owns it forever after.

        Newest first, and by `created_at` rather than by the name that found it,
        for `jarvis_day_jobs`'s reason: the id is stamped only to the minute, so
        two jobs filed inside one minute would otherwise be ordered by their
        random hex. Inside one *second* they still are, because that is the
        resolution `stamp` writes and the id shape is the contract's -- which is
        as far as this goes, since the two jobs concerned were filed by the same
        hand between two frames of a repaint.
        """
        # **Every name is read before any is dropped, and the scan cap is
        # deliberately not applied here.**
        #
        # `chat_list` may stop at CHAT_SCAN_MAX because it prefilters on the
        # mtime scandir already carries, so the entries it keeps are already the
        # newest ones. This loop has no such ordering: `scandir` yields in
        # directory order, which is neither creation order nor name order. A
        # `break` at 400 would hand an arbitrary 400 to the sort below, and the
        # fifty "newest" returned would be the newest of an arbitrary subset --
        # a list that silently stops including today's jobs once the directory
        # is big enough, which is the worst failure shape available: correct on
        # every box small enough to notice it on.
        #
        # Reading names is cheap; what is expensive is opening records, and that
        # is capped at JARVIS_JOBS_MAX below and always has been. So the bound
        # that matters is kept and the one that corrupted the answer is gone.
        found = []
        try:
            with os.scandir(self.jarvis_jobs_dir()) as entries:
                for entry in entries:
                    match = _JARVIS_JOB_NAME.fullmatch(entry.name)
                    if match:
                        found.append(match.group(1))
        except OSError:
            return []

        found.sort(reverse=True)
        rows = []
        for jid in found[:JARVIS_JOBS_MAX]:
            doc, _, _ = self.jarvis_read_job(jid)
            if doc is None:
                continue
            out = dict(doc)
            # Beside the record rather than in it, for `chat_is_queued`'s
            # reason: the job runner writes `state` and this program writes the
            # spool entry, and the seconds between them are the seconds a reader
            # is watching the row.
            out["queued"] = self.jarvis_job_is_queued(jid)
            # Cut per row, not per record. See JARVIS_JOB_ROW_CHARS.
            result = out.get("result")
            if isinstance(result, str) and len(result) > JARVIS_JOB_ROW_CHARS:
                out["result"] = result[:JARVIS_JOB_ROW_CHARS] + "\n\n[output truncated]"
            rows.append(out)
        # A record with no timestamp sorts last rather than crashing the sort.
        rows.sort(key=lambda row: row.get("created_at") or "", reverse=True)
        return rows

    def jarvis_say(self, text):
        """Append one user turn to today and wake the say runner. Returns
        (True, None, None) or (None, why, code).

        The record is written before the spool entry, and that order is the
        contract: the path unit fires on the entry, so an entry that appeared
        first could name a turn that is not on disk yet.

        **One turn in flight per day**, refused with 409 when the day is already
        queued or already running -- not because two turns would race, but
        because the second would be answered by a session that never saw the
        first one's answer, which is a conversation that quietly stops being
        one. The check and the write share the lock, so the answer cannot go
        stale between them. This is the refusal the job lane exists to make
        harmless: the thing you wanted to do while it was busy has its own
        route, and that one never says no.

        Today is minted if it is not there, because this can legitimately be the
        first thing that happens on a given day -- a reader who types before the
        page has finished polling should not be told there is no today.
        """
        with self._jarvis_lock:
            day = self.jarvis_day_id()
            doc, why, code = self._jarvis_ensure_day(day, mint=True)
            if doc is None:
                return None, why, code
            if self.jarvis_is_queued(day):
                return None, "today already has a turn waiting", 409
            if doc.get("status") == "running":
                return None, "today is mid-answer", 409

            now = stamp()
            doc["turns"].append(
                {"kind": "say", "role": "user", "text": text, "at": now})
            doc["updated_at"] = now
            # `status` is deliberately untouched. See the contract at
            # JARVIS_DIR_NAME: this process has started nothing, and the spool
            # entry below is the honest way to say a turn is owed.

            path = self.jarvis_day_path(day)
            if not path or not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the day", 500

            # **A new turn invalidates any stop flag still on disk, and clearing
            # it is this function's job rather than the runner's.**
            #
            # `jarvis_stop` writes the flag whatever the day is doing, on
            # purpose -- its whole point is that "stop whatever is or is about to
            # be running" covers the queued case, where no process exists to
            # signal. That leaves the flag genuinely ambiguous at pickup: it
            # means either "abandon the turn you are about to start" or "a stop
            # arrived seconds after the last answer already landed", and the
            # runner cannot tell those apart from the file.
            #
            # It does not have to. Filing a turn is the moment the ambiguity is
            # created, so it is the moment to resolve it: anything on disk now
            # belongs to a turn that is already over. After this, a flag the
            # runner finds can only have been written after this turn was filed,
            # which means it is for this turn and must be honoured.
            #
            # Failure here is not fatal to the send. The cost is one stop that
            # arrives early and abandons a turn the reader did want -- annoying,
            # recoverable by asking again, and better than refusing a message
            # because a stale file could not be removed.
            stale_stop = self.jarvis_flag_path(JARVIS_STOP_NAME, day)
            if stale_stop:
                try:
                    os.remove(stale_stop)
                except OSError:
                    pass

            # Idempotent by construction, like both spools above it: the name is
            # the day and the content is the day, so the same turn spooled twice
            # is the same one entry.
            spool = self.jarvis_flag_path(JARVIS_SAY_NAME, day)
            if not spool:
                return None, "could not place the spool entry", 500
            try:
                os.makedirs(os.path.dirname(spool), exist_ok=True)
                with open(spool, "w") as fh:
                    fh.write(day)
            except OSError as exc:
                # The turn is on disk and nothing will come to answer it.
                # Reported as a failure rather than a success with a silence
                # after it, which is the version the console cannot explain.
                return None, f"cannot queue the turn: {exc.strerror or exc}", 500
            return True, None, None

    def jarvis_stop(self):
        """Ask the say runner to abandon today's turn. Returns (True, None,
        None) or (None, why, code).

        A flag rather than a signal, for `chat_stop`'s reason: this process does
        not know the runner's pid and should not, the runner may not have
        started yet, and "stop whatever is or is about to be running for today"
        is a sentence a file says to all three cases at once.

        A no-op on an idle day is a success. Stopping something that already
        stopped is the state the caller asked for, and a console that had to
        tell a hurried second click from a real error would draw a failure over
        a turn that simply finished.
        """
        with self._jarvis_lock:
            day = self.jarvis_day_id()
            doc, why, code = self._jarvis_ensure_day(day)
            if doc is None:
                return None, why, code

            flag = self.jarvis_flag_path(JARVIS_STOP_NAME, day)
            if not flag:
                return None, "could not place the stop flag", 500
            try:
                os.makedirs(os.path.dirname(flag), exist_ok=True)
                with open(flag, "w") as fh:
                    fh.write(day)
            except OSError as exc:
                return None, f"cannot ask it to stop: {exc.strerror or exc}", 500
            return True, None, None

    def jarvis_set_model(self, model):
        """Change which model answers today. Returns (True, None, None) or
        (None, why, code).

        Refused while a turn is in flight, for `chat_set_model`'s reason: the
        runner reads this field when it builds its argv, and a value that
        changed after it read it would put a turn on screen claiming to have
        been answered by a model that did not answer it.

        `updated_at` is deliberately not touched. It orders the days list by
        when a day last moved, and flipping a toggle is not the day moving.
        """
        with self._jarvis_lock:
            day = self.jarvis_day_id()
            doc, why, code = self._jarvis_ensure_day(day)
            if doc is None:
                return None, why, code
            if self.jarvis_is_queued(day) or doc.get("status") == "running":
                return None, "the model cannot change mid-answer", 409
            if doc.get("model") == model:
                # Already what was asked for. A success rather than a no-op
                # error, the same idempotence every other setter here keeps.
                return True, None, None

            doc["model"] = model
            path = self.jarvis_day_path(day)
            if not path or not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the day", 500
            return True, None, None

    def jarvis_set_effort(self, effort):
        """Change how hard today's sessions think. Returns (True, None, None)
        or (None, why, code).

        `jarvis_set_model`'s twin, refused mid-answer for the same reason and
        leaving `updated_at` alone for the same one.

        **Takes effect on the next turn, not this one.** `--effort` is passed to
        the process the runner starts, so a session already running was started
        without it. The console says so rather than implying otherwise.
        """
        with self._jarvis_lock:
            day = self.jarvis_day_id()
            doc, why, code = self._jarvis_ensure_day(day)
            if doc is None:
                return None, why, code
            if self.jarvis_is_queued(day) or doc.get("status") == "running":
                return None, "the effort cannot change mid-answer", 409
            if doc.get("effort") == effort:
                return True, None, None

            doc["effort"] = effort
            path = self.jarvis_day_path(day)
            if not path or not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the day", 500
            return True, None, None

    def jarvis_compact(self):
        """Fold today's context without touching today's transcript. Returns
        (True, None, None) or (None, why, code).

        **`turns` is left completely alone, and that is the point of the
        route.** After this, the transcript and the context are no longer the
        same object: the day stays whole because it is the record of the day,
        and what gets *sent* becomes the digest plus whatever comes after it.
        Every continuous conversation this feature is for depends on that
        separation existing.

        Mechanically it is nearly free. The runner already branches on
        `claude_session_id`, resuming when there is one and starting fresh when
        there is not, so clearing the id is the whole trick.

        Refused with 409 while a turn is in flight, because compacting under a
        live session would race the runner's own rewrite of that id -- the two
        writes would be about different sessions and the loser would leave a day
        resuming something that no longer exists.

        `kept` is written null and filled in by the say runner on the next turn,
        which reads oddly until you see what the alternative is: producing the
        digest here means this route blocks on a model, and a compaction that
        takes forty seconds is the exact stall the second lane was built to
        prevent. Until that turn runs, `context.stale` is true and the console
        draws the meter as `-` rather than a number it no longer believes.
        """
        with self._jarvis_lock:
            day = self.jarvis_day_id()
            doc, why, code = self._jarvis_ensure_day(day)
            if doc is None:
                return None, why, code
            if self.jarvis_is_queued(day) or doc.get("status") == "running":
                return None, "a turn is in flight", 409

            now = stamp()
            context = doc.get("context")
            context = dict(context) if isinstance(context, dict) else {}
            compactions = doc.get("compactions")
            compactions = list(compactions) if isinstance(compactions, list) else []
            compactions.append({
                "at": now,
                # Null when the day has no reading yet, which is a day being
                # compacted before anything ran. Honest rather than zero: a
                # number here would be this program guessing at the one quantity
                # that only ever comes off a `result` event.
                "before_tokens": context.get("tokens"),
                "kept": None,
                # The whole array, not the say turns in it. What is being folded
                # is the transcript, and a job card and a notice are lines in
                # the transcript too.
                "turns_folded": len(doc["turns"]),
            })
            doc["compactions"] = compactions
            doc["claude_session_id"] = None
            # Set even on a day that had no context at all, where it leaves an
            # object carrying nothing but `stale`. That is the right shape: it
            # says there is no number and says why, which is more than a null
            # says.
            context["stale"] = True
            doc["context"] = context
            # A compaction is a thing that happened to the day, unlike the model
            # toggle above it, so the list is allowed to say the day moved.
            doc["updated_at"] = now

            path = self.jarvis_day_path(day)
            if not path or not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the day", 500
            return True, None, None

    def jarvis_job(self, text, title):
        """File one job and put a card for it in today's transcript. Returns
        (jid, None, None) or (None, why, code).

        **This never answers 409, and that is the whole feature.** A job is
        filed whatever the talk lane is doing, which is why it is filed into a
        different spool, watched by a different unit, held by a different lock.
        Nothing here reads the talk lane's state and nothing here waits on it.

        Three writes, in an order that is the contract: the job record, then the
        card that names it, then the spool entry. The record goes first because
        the card is a pointer to it and a card naming a file that is not there
        is a row the day route would rebuild from nothing. The spool goes last
        because the path unit fires on it, so an entry that appeared first could
        wake a runner for a job that is not on disk yet.

        **The card's write is allowed to fail silently, and only the card's.**
        It is an append to a record the say runner may be rewriting from its own
        copy this half second, so it can be lost whatever this returns -- and a
        lost card is repaired on the next read out of the job record itself. See
        `jarvis_reconcile_jobs`. Failing the whole request over it would refuse
        a job that is already filed and already about to run, which is a 500
        describing something that worked.
        """
        with self._jarvis_lock:
            day = self.jarvis_day_id()
            doc, why, code = self._jarvis_ensure_day(day, mint=True)
            if doc is None:
                return None, why, code

            jid = self.jarvis_new_job_id(day)
            if not jid:
                return None, "could not mint a job id", 500
            jpath = self.jarvis_job_path(jid)
            if not jpath:
                return None, "could not place the job", 500

            now = stamp()
            job = {
                "id": jid,
                # The day it belongs to, written down rather than sliced back
                # out of the id at every read. The id is the authority and this
                # is the convenience; they cannot disagree, because nothing but
                # this line ever writes it.
                "day": day,
                "title": title,
                "text": text,
                "created_at": now,
                "updated_at": now,
                # Idle, and truthfully so, for `chat_new`'s reason: nothing is
                # running, and a status this process wrote about a subprocess it
                # did not start would be a claim rather than a fact. The spool
                # entry below is how "filed, not started" is said. It is also
                # the only status this program ever writes here -- `running`,
                # `done` and `error` are the job runner's, and it overwrites
                # this one the moment it picks the job up.
                "status": "idle",
                "error": None,
            }
            if not write_atomic(jpath, json.dumps(job, indent=2)):
                return None, "cannot write the job", 500

            doc["turns"].append(self.jarvis_card(job, now))
            doc["updated_at"] = now
            dpath = self.jarvis_day_path(day)
            if dpath:
                write_atomic(dpath, json.dumps(doc, indent=2))

            spool = self.jarvis_flag_path(JARVIS_JOBSPOOL_NAME, jid)
            if not spool:
                return None, "could not place the spool entry", 500
            try:
                os.makedirs(os.path.dirname(spool), exist_ok=True)
                with open(spool, "w") as fh:
                    fh.write(jid)
            except OSError as exc:
                # The job is on disk and nothing will come to run it. Reported
                # as a failure for `jarvis_say`'s reason, and the card left
                # behind is not a lie -- it will read `idle` forever, which is
                # exactly what happened.
                return None, f"cannot queue the job: {exc.strerror or exc}", 500
            return jid, None, None

    def jarvis_job_stop(self, jid):
        """Ask the job runner to abandon one job. Returns (True, None, None) or
        (None, why, code).

        `jarvis_stop` one lane over, with the same three-cases-at-once argument
        for a file and the same "a no-op is a success" answer. The job is read
        first so that stopping a job nobody has is a 404 rather than a flag with
        no record, which would be an orphan waiting to arm the next id minted to
        collide with it -- `chat_delete` cleans up after itself for exactly that
        reason.
        """
        with self._jarvis_lock:
            doc, why, code = self.jarvis_read_job(jid)
            if doc is None:
                return None, why, code

            flag = self.jarvis_flag_path(JARVIS_JOBSTOP_NAME, jid)
            if not flag:
                return None, "could not place the stop flag", 500
            try:
                os.makedirs(os.path.dirname(flag), exist_ok=True)
                with open(flag, "w") as fh:
                    fh.write(jid)
            except OSError as exc:
                return None, f"cannot ask it to stop: {exc.strerror or exc}", 500
            return True, None, None

    # -- the voice proxy -----------------------------------------------------

    # Why a proxy at all: the browser cannot fetch audio from the Mac
    # directly -- Safari refuses the cross-origin hop from an https page --
    # so the collector stands in the middle and the audio arrives same-origin
    # with the page that plays it. The Mac's address comes from config.json,
    # never from source; the key comes from .env and is forwarded, never
    # logged, never echoed back in an error.
    #
    # Not a source, like chat and for chat's reason: nothing polls it, nothing
    # here joins /v1/telemetry, and a Mac that is asleep is a dim word in the
    # console rather than a lamp going red over the whole box.

    def jarvis_tts_config(self):
        """The voice service's base URL and key. Returns (base, key), either
        of which may be "".

        Configured means BOTH halves, and the two routes treat anything less
        as one state rather than inventing a third: a base with no key would
        forward requests the Mac is contractually bound to 401, and "half
        configured" and "not configured" are the same screen to a console
        that can do nothing about either.
        """
        block = self.cfg.get("tts") or {}
        base = (block.get("base") or "").rstrip("/")
        key = os.environ.get(JARVIS_TTS_KEY_ENV, "")
        return base, key

    def jarvis_tts(self, text):
        """One sentence to the Mac's /speak, its WAV straight back. Returns
        (bytes, None, None) or (None, why, code).

        **This is the one call in this file that is allowed to be slow.**
        Every other answer here is fast because a poll sits behind it; this
        one is the browser awaiting its own fetch -- the speaker pipeline
        asked for this sentence's audio and does nothing else until it lands
        -- and the server is threaded, so a cold Kokoro spending ten seconds
        here blocks nobody's poll. That is why the timeout is generous, not 6s.

        The body is read whole rather than relayed in pieces: a sentence's
        WAV is one or two megabytes, bounded by the text cap upstream of it,
        and the Mac sends the file complete, not chunked. A relay loop would
        buy nothing but a place for a half-written answer to hide.

        Every way of not coming home with audio is a 502 in this program's
        own words -- including an answer from the Mac itself, whose status is
        never passed through: its 401 relayed as ours would read "your cookie
        is bad" to a console whose cookie is fine. The console draws the 502
        as a dim word beside an intact text lane, and that is the entire
        failure model: a sleeping Mac mutes Jarvis, it never breaks him.
        """
        base, key = self.jarvis_tts_config()
        if not base or not key:
            return None, "tts is not configured", 503

        req = urllib.request.Request(f"{base}/speak", method="POST")
        req.add_header("User-Agent", USER_AGENT)
        req.add_header("X-Halftone-Key", key)
        req.add_header("Content-Type", "application/json")
        data = json.dumps({"text": text}).encode()
        try:
            with urllib.request.urlopen(
                    req, data=data, timeout=JARVIS_TTS_TIMEOUT_S) as resp:
                return resp.read(), None, None
        except urllib.error.HTTPError as exc:
            try:
                detail = json.loads(exc.read() or b"{}").get("error")
            except ValueError:
                detail = None
            return None, (detail
                          or f"the voice service refused: HTTP {exc.code}"), 502
        except Exception as exc:  # noqa: BLE001
            return None, f"the mac is not answering: {str(exc)[:200]}", 502

    def jarvis_tts_warm(self):
        """Touch the voice service's port. Returns (True, None, None) or
        (None, why, code).

        **Under launchd socket activation the connection IS the point.**
        launchd holds the Mac's port and spawns Kokoro on the first
        connection, so the useful work of this call is done the moment the
        handshake lands -- the 204 after it is a courtesy, and an HTTP-level
        refusal still means something answered the port, which is everything
        the caller wanted to cause. Only a transport failure says the Mac was
        not there, and only that is a 502.

        No key is sent, because the Mac's /warm takes none: it starts a model
        load and answers nothing, so there is nothing on that route for a
        stranger on the tailnet to take.
        """
        base, key = self.jarvis_tts_config()
        if not base or not key:
            return None, "tts is not configured", 503

        req = urllib.request.Request(f"{base}/warm", method="POST", data=b"")
        req.add_header("User-Agent", USER_AGENT)
        try:
            with urllib.request.urlopen(
                    req, timeout=JARVIS_TTS_WARM_TIMEOUT_S):
                pass
        except urllib.error.HTTPError:
            pass
        except Exception as exc:  # noqa: BLE001
            return None, f"the mac is not answering: {str(exc)[:200]}", 502
        return True, None, None

    # -- the mailbox ---------------------------------------------------------

    # The remaining writes, and the only ones in this program that can end with
    # words in front of another person. They need
    # `ReadWritePaths=/home/pi/charon-mail/mail` in the unit for exactly the
    # reason the ledger and the ask directory need theirs: ProtectHome is
    # read-only, so without it every mail POST fails EROFS while every read
    # carries on working, which looks like a console bug.
    #
    # The division of labour is the ask contract with more workers on the far
    # side. **This program writes what the human decided and nothing else**: a
    # draft he typed, an outbox record he asked for, and a spool entry naming
    # the action. It never writes an index record, never turns an outbox record
    # to `sent`, never deletes a spool entry, and never opens a socket to
    # Gmail. One writer per field is what keeps a half-drained queue
    # unambiguous, and holding no credentials is what keeps the process with a
    # listening port unable to send anything.

    def mail_dir(self):
        base = (self.cfg["mail"].get("base_dir") or "").rstrip("/")
        return os.path.join(base, MAIL_DIR_NAME) if base else ""

    def mail_path(self, *parts):
        """A path inside the mailbox, or "" if it would leave it.

        Every path this program builds under `mail/` goes through here, reads
        and writes alike. The keys and ids arrive already shaped by a regex in
        each caller, so this is belt and braces -- the same argument as
        `ask_thread_path`'s, and it carries more weight here because five of
        these paths are written to and one of them is a send.
        """
        root = self.mail_dir()
        if not root:
            return ""
        root = os.path.realpath(root)
        candidate = os.path.realpath(os.path.join(root, *parts))
        return candidate if candidate.startswith(root + os.sep) else ""

    def mail_json(self, *parts):
        """One small JSON object out of the mailbox, or None.

        Never raises. Every file read through here is optional by construction:
        a message has no triage artifact until the triage runs, no draft until
        somebody asks for one, and no user draft until somebody types.
        """
        path = self.mail_path(*parts)
        if not path:
            return None
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            return None
        return doc if isinstance(doc, dict) else None

    def mail_record(self, key):
        """The header record for one message, or None if there is no such
        message. The existence check every write route starts with."""
        return self.mail_json("index", f"{key}.json")

    def mail_body(self, key):
        """The extracted text, capped, and whether it was cut. ("", False) when
        there is none, which is the ordinary state for a message whose body the
        poller has not cached yet.

        Decoded with errors="replace" and never allowed to raise: this is the
        one file in the system whose bytes were chosen by a stranger, and a
        route that 500s on a malformed encoding is a route that a sender can
        turn off from the outside.
        """
        path = self.mail_path("bodies", f"{key}.txt")
        if not path:
            return "", False
        try:
            with open(path, "rb") as fh:
                # One byte past the ceiling, which is how the cut is noticed
                # without reading a file of unknown size to find out.
                raw = fh.read(MAIL_BODY_SERVE_MAX + 1)
        except OSError:
            return "", False
        return raw[:MAIL_BODY_SERVE_MAX].decode("utf-8", "replace"), \
            len(raw) > MAIL_BODY_SERVE_MAX

    def mail_outbox_for(self, key):
        """Every send record naming this message, newest first. [] if none.

        Whole records rather than summaries, unlike the list's badge: this is
        the audit trail of the one thing in this system that reaches another
        person, and a console that can show what was actually sent, when, and
        what the server said back is the reason for keeping it. Bounded like the
        source's read, and on demand rather than on every poll.
        """
        root = self.mail_path("outbox")
        if not root:
            return []
        found = []
        try:
            with os.scandir(root) as entries:
                for entry in entries:
                    if not _MAIL_ID_NAME.fullmatch(entry.name):
                        continue
                    try:
                        found.append((entry.stat().st_mtime, entry.path))
                    except OSError:
                        continue
        except OSError:
            return []
        found.sort(key=lambda row: row[0], reverse=True)

        rows = []
        for _, path in found[:MAIL_OUTBOX_SCAN_MAX]:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict) and doc.get("key") == key:
                rows.append(doc)
        # Oldest first: the reader draws these as a history under the reply
        # box, and a history reads downward. The scan window above is newest
        # first only so the cap keeps the right end of a long tail.
        rows.reverse()
        return rows

    def mail_message(self, key):
        """Everything the console needs to read one message. Returns
        (payload, None) or (None, why).

        A merge rather than a file, which is why this one is re-serialised
        instead of being served verbatim the way an ask thread is: the five
        files behind it are written by four different programs, and asking the
        console to fetch them one at a time would be four round trips to draw
        one page.

        The body is the only large thing here and it arrives capped. Nothing
        else on this route grows with the size of the mailbox.
        """
        record = self.mail_record(key)
        if record is None:
            return None, f"no message {key}"
        text, truncated = self.mail_body(key)
        # The header record as the poller wrote it, flattened into the payload:
        # this route is the reader, and the fields the list leaves out (to,
        # references, attachment names, sizes) are exactly what a reader wants.
        # Flat rather than nested because the console types this document as
        # one message, not as an envelope holding one.
        payload = dict(record)
        payload["key"] = key
        # The poller keeps To: as a list; the reader draws one line.
        to = record.get("to")
        if isinstance(to, list):
            payload["to"] = ", ".join(str(a) for a in to if a) or None
        payload["body"] = text
        payload["body_truncated"] = bool(record.get("body_truncated")) or truncated
        ai = self.mail_json("ai", f"{key}.json")
        # The same rule as the list: a pending record is not a verdict.
        payload["ai"] = ai if isinstance(ai, dict) \
            and ai.get("status") != "pending" else None
        # Two drafts, two writers, one field each: the triage owns the
        # first and the human owns the second, so a regenerate cannot eat
        # what somebody typed and a save cannot be mistaken for a verdict.
        payload["draft"] = self.mail_json("drafts", f"{key}.json")
        payload["user_draft"] = self.mail_json("drafts", f"{key}.user.json")
        payload["outbox"] = self.mail_outbox_for(key)
        return payload, None

    def mail_attachment(self, key, n):
        """One attachment, dug out of the raw message on demand. Returns
        (bytes, filename, content-type, None) or (None, None, None, why).

        Parsed rather than extracted at poll time. Attachments are the one part
        of a mailbox that is large and rarely opened, so a directory of them
        would be a second copy of every PDF anyone ever sent, kept for the day
        somebody clicks. The .eml is already on disk and stdlib email can find
        part n inside it.

        `n` is the position in the same enumeration the poller indexed: the
        parts of the parsed message, in walk order, that carry a filename or
        declare themselves an attachment. Both sides count the same way or the
        numbers mean nothing, so this comment is the contract.
        """
        path = self.mail_path("bodies", f"{key}.eml")
        if not path:
            return None, None, None, f"no message {key}"
        try:
            if os.path.getsize(path) > MAIL_EML_MAX_BYTES:
                return None, None, None, "the raw message is too large to parse"
            with open(path, "rb") as fh:
                msg = BytesParser(policy=email_policy.default).parse(fh)
        except OSError:
            return None, None, None, f"no raw message for {key}"
        except Exception:  # noqa: BLE001 - hostile input, see the docstring
            return None, None, None, "the raw message could not be parsed"

        try:
            parts = [part for part in msg.walk()
                     if part.get_filename()
                     or part.get_content_disposition() == "attachment"]
            if n >= len(parts):
                return None, None, None, f"no attachment {n}"
            part = parts[n]
            body = part.get_payload(decode=True)
        except Exception:  # noqa: BLE001 - a broken part is a 404, not a 500
            return None, None, None, f"attachment {n} could not be read"
        if body is None:
            return None, None, None, f"attachment {n} has no content"
        return bytes(body), mail_filename(part, n), mail_ctype(part), None

    def mail_action(self, verb, key):
        """Queue one mailbox mutation. (True, None, None) or (None, why, code).

        Read and archive both land in `.actions/`, where the one worker allowed
        to talk to IMAP picks them up. The index record is checked first so a
        console naming a message that is not here gets a 404 rather than a spool
        entry nothing will ever resolve.

        Idempotent by construction: the entry is named for the verb and the key,
        so the same action queued twice is the same one file. A double click
        costs nothing, which is what lets the console mark read optimistically.
        """
        if not self.mail_dir():
            return None, "mail.base_dir is unset", 500
        if self.mail_record(key) is None:
            return None, f"no message {key}", 404
        spool = self.mail_path(MAIL_ACTIONS_NAME, f"{verb}-{key}")
        if not spool:
            return None, "could not place the spool entry", 500
        with self._mail_lock:
            # Atomic even though it is one short line: a path unit fires on the
            # directory becoming non-empty, so the worker can be reading this
            # file within milliseconds of it appearing, and an entry it caught
            # empty would be an action with no subject.
            if not write_atomic(spool, key):
                return None, f"cannot queue the {verb}", 500
        return True, None, None

    def mail_draft(self, key, instructions, force):
        """Ask for an AI reply draft. (status, None, None) or (None, why, code).

        The record is written before the spool entry, the same contract as
        `cmo_ask` and for the same reason: the entry is what wakes the worker,
        so an entry that appeared first could name a file that is not there yet.

        A draft that is already `ready` is left alone unless the caller insists.
        Each of these costs an Opus call, a double click is the common case, and
        re-queueing on top of an answer that already arrived would spend a
        minute to produce the same paragraph.
        """
        if not self.mail_dir():
            return None, "mail.base_dir is unset", 500
        if self.mail_record(key) is None:
            return None, f"no message {key}", 404
        path = self.mail_path("drafts", f"{key}.json")
        spool = self.mail_path(MAIL_QUEUE_NAME, f"draft-{key}")
        if not path or not spool:
            return None, "could not place the draft", 500

        with self._mail_lock:
            if not force:
                existing = self.mail_json("drafts", f"{key}.json")
                if existing and existing.get("status") == "ready":
                    return "ready", None, None
            doc = {
                "key": key,
                "status": "queued",
                # Short steering from the reader, or None. The prompt file is
                # where the voice lives; this is where "decline politely" goes.
                "instructions": instructions,
                # Named here as nulls so the shape of the record is complete
                # from the first write, and named with the worker's own field
                # names so the record keeps one shape across both writers.
                # Everything past this point -- the text, the model, the turn
                # to ready or failed -- is the worker's.
                "text": None,
                "model": None,
                "error": None,
                "at": stamp(),
            }
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the draft", 500
            if not write_atomic(spool, key):
                # The request is on disk and nothing is coming to answer it.
                # Reported as a failure rather than as a success followed by a
                # silence, which is the version the console cannot explain.
                return None, "cannot queue the draft", 500
        return "queued", None, None

    def mail_save_draft(self, key, body):
        """Save what the human typed. (True, None, None) or (None, why, code).

        Its own file, not the AI's, so the two never overwrite each other. No
        spool entry either: nothing has to happen because somebody typed, and a
        queue entry per keystroke would wake a worker for nothing. This is the
        one mail write that wakes no one.
        """
        if not self.mail_dir():
            return None, "mail.base_dir is unset", 500
        if self.mail_record(key) is None:
            return None, f"no message {key}", 404
        path = self.mail_path("drafts", f"{key}.user.json")
        if not path:
            return None, "could not place the draft", 500
        # The AI draft's shape exactly, because the reader treats the two files
        # as the same kind of thing once they are text. A draft he typed is
        # ready the moment it is saved; the null fields are the ones only a
        # session can fill.
        doc = {"key": key, "status": "ready", "text": body,
               "instructions": None, "model": None, "error": None,
               "at": stamp()}
        with self._mail_lock:
            # tmp + os.replace, like every other record here: the console
            # debounce-saves while the user types and re-reads this file when
            # the page is reopened, so a half-written copy would be a reply that
            # lost its second half.
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the draft", 500
        return True, None, None

    def mail_new_id(self):
        """A fresh outbox id: local minute plus four hex, minted exactly like an
        ask thread's and for the same reasons -- see `ask_new_id`. Re-rolled if
        the name is taken, which here would mean overwriting somebody's audit
        record rather than joining somebody's conversation.
        """
        for _ in range(8):
            mid = (f"{datetime.now().strftime('%Y-%m-%d-%H%M')}"
                   f"-{os.urandom(2).hex()}")
            path = self.mail_path("outbox", f"{mid}.json")
            if path and not os.path.exists(path):
                return mid
        return None

    def mail_send(self, key, body):
        """Queue one reply for sending. (id, None, None) or (None, why, code).

        The only route in this program whose effect leaves the house, so the
        recipient is not a parameter. **`to` is computed here from the message
        being replied to and the caller cannot influence it** -- see
        `mail_reply_address`. The subject is derived for the same reason: the
        caller supplies words, not a destination.

        The record is written before the spool entry, the ask contract again,
        and it matters most here: the entry is what wakes the process that opens
        an SMTP connection, and an entry naming a record that is not on disk yet
        would be a send with no content -- or, worse, a send whose content
        arrived a moment later than the read.

        Queued and nothing more. The actions worker checks the address against
        the index record again before it connects, which is the second lock on
        the same door and worth having on the one action that cannot be undone.
        """
        if not self.mail_dir():
            return None, "mail.base_dir is unset", 500
        record = self.mail_record(key)
        if record is None:
            return None, f"no message {key}", 404
        to = mail_reply_address(record)
        if not to:
            # Neither 400 nor 404: the request is well formed and the message is
            # real. What is missing is an address to answer, which is a fact
            # about the mail rather than a mistake by the caller.
            return None, f"message {key} has no usable reply address", 409

        references = record.get("references")
        if not isinstance(references, (str, list)):
            references = None

        with self._mail_lock:
            mid = self.mail_new_id()
            if not mid:
                return None, "could not mint an outbox id", 500
            path = self.mail_path("outbox", f"{mid}.json")
            spool = self.mail_path(MAIL_ACTIONS_NAME, f"send-{mid}")
            if not path or not spool:
                return None, "could not place the outbox record", 500

            doc = {
                "id": mid,
                "key": key,
                "to": to,
                "subject": mail_reply_subject(record),
                "body": body,
                # Copied off the record rather than left for the worker to look
                # up: this file is the permanent line in the audit trail, and a
                # record that cannot say what it was answering is a weaker one.
                # The worker still reads the index for the address check.
                "in_reply_to": record.get("message_id"),
                "references": references,
                "status": "queued",
                "queued_at": stamp(),
                # The worker's fields, named as nulls so the record's shape is
                # complete from the first write.
                "sent_at": None,
                "smtp_reply": None,
                "error": None,
            }
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the outbox record", 500
            if not write_atomic(spool, mid):
                # The record exists and says queued, and nothing is coming for
                # it. Said out loud, because a SEND that answered ok and then
                # sat there forever is the failure a person cannot diagnose.
                return None, "cannot queue the send", 500
        return mid, None, None

    # -- the messages store --------------------------------------------------

    # More write routes than any other feature here, and the same division of
    # labour as the mailbox with one process further away. **This program writes
    # what arrived and what the human decided, and nothing else**: the records
    # the Bridge pushed, the allowlist he edited, the draft he asked for, the
    # send he tapped, and the spool entries naming the work. It never writes a
    # verdict, never turns a send to `sent` on its own, and has no way to reach
    # Messages.app -- the Mac is never called from here, in either direction.
    #
    # They need the store's directories in the unit's ReadWritePaths for the
    # mailbox's reason: ProtectHome is read-only, so without them every write
    # here fails EROFS while every read carries on working, which looks like a
    # console bug rather than a permissions one.

    def messages_dir(self):
        base = (self.cfg["messages"].get("base_dir") or "").rstrip("/")
        return os.path.join(base, MESSAGES_DIR_NAME) if base else ""

    def messages_path(self, *parts):
        """A path inside the store, or "" if it would leave it.

        Every path this program builds under `messages/` goes through here,
        reads and writes alike. The keys, ids and dates arrive already shaped by
        a regex in each caller, so this is belt and braces -- `mail_path`'s
        argument, and it carries more weight here because one of these paths
        ends with a text on somebody's phone.
        """
        root = self.messages_dir()
        if not root:
            return ""
        root = os.path.realpath(root)
        candidate = os.path.realpath(os.path.join(root, *parts))
        return candidate if candidate.startswith(root + os.sep) else ""

    def messages_json(self, *parts):
        """One small JSON object out of the store, or None. Never raises: every
        file read through here is optional by construction."""
        path = self.messages_path(*parts)
        if not path:
            return None
        try:
            with open(path) as fh:
                doc = json.load(fh)
        except (OSError, ValueError):
            return None
        return doc if isinstance(doc, dict) else None

    def messages_ensure_dirs(self):
        """Every directory a write route needs. Run per write rather than at
        startup: the store's first directory is created by the first heartbeat,
        and a collector that started before the Pi had one should not need a
        restart to notice."""
        for name in ("index", "bodies", "ai", "drafts", "outbox", "summaries",
                     MESSAGES_ATTACHMENTS_DIR_NAME,
                     MESSAGES_QUEUE_NAME, MESSAGES_ACTIONS_NAME,
                     MESSAGES_READ_NAME, MESSAGES_CHAT_SUMMARY_NAME,
                     MESSAGES_THREAD_INDEX_NAME, MESSAGES_WANTS_NAME):
            path = self.messages_path(name)
            if path:
                try:
                    os.makedirs(path, exist_ok=True)
                except OSError:
                    return False
        return True

    def messages_record(self, key):
        """The index record for one message, or None."""
        return self.messages_json("index", f"{key}.json")

    def messages_text(self, key):
        """One stored text, capped, and whether it was cut. ("", False) when
        there is none.

        Decoded with errors="replace" and never allowed to raise: these bytes
        were typed by somebody else, and a route that 500s on a malformed
        encoding is a route a stranger can turn off from the outside.
        """
        path = self.messages_path("bodies", f"{key}.txt")
        if not path:
            return "", False
        try:
            with open(path, "rb") as fh:
                # One byte past the ceiling, which is how the cut is noticed
                # without reading a file of unknown size to find out.
                raw = fh.read(MESSAGES_BODY_MAX_BYTES + 1)
        except OSError:
            return "", False
        return raw[:MESSAGES_BODY_MAX_BYTES].decode("utf-8", "replace"), \
            len(raw) > MESSAGES_BODY_MAX_BYTES

    def messages_state(self):
        return self.messages_json("state.json") or {}

    def messages_write_state(self, **fields):
        """Merge fields into state.json. Called with the feature lock held.

        Read-modify-write over one small file, which is exactly why it is never
        called without the lock: the ingest route and the heartbeat route both
        touch it, and a heartbeat landing mid-ingest would otherwise drop one of
        the two writes.
        """
        path = self.messages_path("state.json")
        if not path:
            return False
        state = self.messages_json("state.json") or {}
        state.update(fields)
        return write_atomic(path, json.dumps(state, indent=2))

    # -- the per-conversation summaries --------------------------------------
    #
    # One file per conversation under `messages/.chats/`, and this program is
    # its only writer. Everything the chat list draws lives there: who the
    # conversation is with, the newest line and when it landed, how many
    # inbound rows have arrived unread since the read mark moved, and how many
    # rows the store holds in total.
    #
    # **Kept on write rather than computed on read**, which is the whole point.
    # A poll that has to find the newest message of every conversation has to
    # look at every message, and a store with a history in it has tens of
    # thousands. A post already knows which conversation each row belongs to
    # and already holds the lock, so folding the row into its summary there
    # costs one read and one write per conversation per post and turns the
    # thirty-second poll into one open per conversation.
    #
    # **Two fields are deliberately not maintained here.** `urgency_max` and
    # `needs_you` come out of the triage's verdicts, which the pipeline writes
    # and this program never touches. Keeping them current on write would mean
    # this process reading a file whose writer is another program on another
    # schedule, so the summary carries them as null and the poll fills them in
    # for the conversations it is actually listing, over `last_key` and the
    # bounded set of unread keys below it.

    def messages_chat_summary_blank(self, chat):
        return {"chat_key": chat, "chat_guid": None, "chat_identifier": None,
                "chat_name": None, "is_group": False, "service": None,
                "participants": None, "last_key": None, "last_at": None,
                "last_preview": None, "last_sender": None,
                "last_is_from_me": False, "unread": 0, "unread_keys": [],
                "total": 0, "urgency_max": None, "needs_you": None,
                "updated_at": None}

    def messages_chat_summary_doc(self, chat):
        """One conversation's summary exactly as it is on disk, or None.

        The route side's question, and the reason it is not the one below: that
        one answers "what do I fold this row into" and always has an answer,
        and this one answers "does this program know this conversation at all".
        A blank invented here would turn a 404 into an empty room with somebody
        else's name on the door.
        """
        doc = self.messages_json(MESSAGES_CHAT_SUMMARY_NAME, f"{chat}.json")
        return doc if isinstance(doc, dict) else None

    def messages_chat_summary(self, chat):
        """One conversation's summary, or a blank one. Never raises."""
        doc = self.messages_chat_summary_doc(chat)
        if doc is None:
            return self.messages_chat_summary_blank(chat)
        doc["chat_key"] = chat
        return doc

    def messages_chat_summary_put(self, chat, doc):
        """Write one summary. Called with the feature lock held."""
        path = self.messages_path(MESSAGES_CHAT_SUMMARY_NAME, f"{chat}.json")
        if not path:
            return False
        doc["updated_at"] = stamp()
        return write_atomic(path, json.dumps(doc, indent=2))

    def messages_chat_summary_fold(self, doc, key, record, text):
        """Fold one freshly stored row into its conversation's summary, in
        place. Called with the feature lock held, once per stored row.

        Three things happen and each has its own rule:

        `total` counts rows, so it moves for every one of them, history
        included.

        The last_* fields describe the newest message *by the stamp the Mac put
        on it*, never by the order rows arrived. This is the rule a backfill
        exists to break: a history page delivered a minute ago is full of
        messages from March, and the conversation's last line is still the one
        from this morning.

        `unread` moves only for a live inbound row. History lands read
        (section 7) and our own texts were never unread, which is exactly what
        `messages_arrived_unread` says. The keys go in beside the count because
        the poll needs something to look the triage's verdicts up by, and they
        are trimmed to the newest MESSAGES_CHAT_KEYS_MAX so one busy
        conversation cannot turn a summary into a log.
        """
        doc["total"] = messages_count(doc.get("total")) + 1

        when = str(record.get("created_at") or "")
        if when >= str(doc.get("last_at") or ""):
            doc["chat_guid"] = record.get("chat_guid")
            doc["chat_identifier"] = record.get("chat_identifier")
            doc["chat_name"] = record.get("chat_name")
            doc["is_group"] = bool(record.get("is_group"))
            doc["service"] = record.get("service")
            doc["participants"] = record.get("participants")
            doc["last_key"] = key
            doc["last_at"] = record.get("created_at")
            doc["last_preview"] = mail_line(text, MESSAGES_CHAT_PREVIEW_CHARS)
            doc["last_sender"] = mail_line(
                record.get("sender_name") or record.get("sender"),
                MESSAGES_NAME_CHARS)
            doc["last_is_from_me"] = bool(record.get("is_from_me"))

        if messages_arrived_unread(record):
            doc["unread"] = messages_count(doc.get("unread")) + 1
            keys = [k for k in (doc.get("unread_keys") or [])
                    if isinstance(k, str) and k != key]
            keys.append(key)
            # The newest by arrival, which for a live stream is the newest
            # full stop. The rebuild replays the store oldest-first and lands
            # on the same list for the same reason.
            doc["unread_keys"] = keys[-MESSAGES_CHAT_KEYS_MAX:]
        elif bool(record.get("is_from_me")) and not record.get("backfill") \
                and when >= str(doc.get("last_at") or ""):
            # A live text of his own. Replying is reading: nothing that came
            # before it is waiting on him, whichever screen he answered from.
            # The mark moves too, so a rebuild lands on the same answer and
            # the app sees the same thing the summary says.
            doc["unread"] = 0
            doc["unread_keys"] = []
            chat = doc.get("chat_key") or record.get("chat_key")
            path = self.messages_path(MESSAGES_READ_NAME, f"{chat}.json") if chat else None
            if path:
                write_atomic(path, json.dumps({
                    "chat_key": chat, "last_read_key": key,
                    "last_read_at": record.get("created_at"), "at": stamp(),
                    "by": "own reply"}, indent=2))
        return doc

    def messages_chat_summary_clear(self, chat):
        """Move one conversation's summary to "nothing waiting". Called with
        the feature lock held, by the read route and by nothing else."""
        doc = self.messages_chat_summary(chat)
        doc["unread"] = 0
        doc["unread_keys"] = []
        return self.messages_chat_summary_put(chat, doc)

    def messages_rebuild_chat_summaries(self):
        """Build `messages/.chats/` from one full scan of `index/`.

        **The only full scan in this program, and it runs at most once per
        store.** It exists for the crossing: a Pi that has been holding
        messages since before the summaries did, whose chat list would
        otherwise stay empty until every one of its conversations happened to
        receive another message. It is a no-op the moment there is a summary on
        disk, so a restart costs a scandir of one directory.

        Held under the feature lock for its whole length, which is the simple
        way to be safe against an ingest landing halfway through: a post that
        arrives during the rebuild waits, and then folds its rows into the
        summaries this produced rather than into a half-built set. The rebuild
        writes into a staging directory and swaps it in, so a poll running
        beside it sees either no summaries or all of them.

        Correct by construction against the writer, because the two use the
        same predicate: `unread` here is the inbound non-history rows newer
        than the read mark, which is exactly the set the ingest route has been
        counting one row at a time.
        """
        root = self.messages_dir()
        if not root:
            return None
        index = self.messages_path("index")
        target = self.messages_path(MESSAGES_CHAT_SUMMARY_NAME)
        staging = self.messages_path(f"{MESSAGES_CHAT_SUMMARY_NAME}.rebuild")
        if not index or not target or not staging:
            return None

        with self._messages_lock:
            began = time.monotonic()

            # Nothing to rebuild from. Answered before anything is created, so
            # a box that has never had a message on it does not grow a message
            # store because this ran at startup.
            try:
                with os.scandir(index) as entries:
                    names = [entry.name for entry in entries
                             if _MESSAGES_KEY_NAME.fullmatch(entry.name)]
            except OSError:
                return None
            if not names:
                return None

            # Already built, which is every start after the first. A scandir
            # of one small directory rather than a flag somebody has to
            # remember to write: the summaries themselves are the record that
            # there are summaries.
            try:
                with os.scandir(target) as entries:
                    for entry in entries:
                        if _MESSAGES_KEY_NAME.fullmatch(entry.name):
                            return None
            except OSError:
                pass

            if not self.messages_ensure_dirs():
                return None

            rows = 0
            groups = {}
            for name in names:
                key = name[:16]
                try:
                    with open(os.path.join(index, name)) as fh:
                        record = json.load(fh)
                except (OSError, ValueError):
                    continue
                if not isinstance(record, dict):
                    continue
                chat = record.get("chat_key")
                if not isinstance(chat, str) or not _MESSAGES_KEY.fullmatch(chat):
                    continue
                rows += 1
                groups.setdefault(chat, []).append((key, record))

            if not groups:
                return None

            built = {}
            for chat, held in groups.items():
                mark = self.messages_json(MESSAGES_READ_NAME, f"{chat}.json")
                since = (mark or {}).get("last_read_at")
                since = since if isinstance(since, str) else ""
                doc = self.messages_chat_summary_blank(chat)
                # Oldest first, so the fold sees the rows in the order the
                # ingest route would have seen them and lands on the same
                # answer. The read mark is applied here rather than inside the
                # fold: the writer never counts a row the user has already
                # cleared, because clearing is what zeroed the counter.
                ordered = messages_newest_first(
                    [(key, record.get("created_at")) for key, record in held])
                by_key = dict(held)
                # One body per conversation, not one per row. The preview is
                # only ever taken from the newest message, and replaying
                # oldest-first means the newest is the last row folded.
                newest = ordered[0][0]
                for key, when in reversed(ordered):
                    record = by_key[key]
                    if since and messages_arrived_unread(record) \
                            and str(when or "") <= since:
                        record = dict(record)
                        record["unread"] = False
                    text = self.messages_text(key)[0] if key == newest else ""
                    self.messages_chat_summary_fold(doc, key, record, text)
                built[chat] = doc

            try:
                os.makedirs(staging, exist_ok=True)
                for name in os.listdir(staging):
                    os.remove(os.path.join(staging, name))
                for chat, doc in built.items():
                    doc["updated_at"] = stamp()
                    if not write_atomic(os.path.join(staging, f"{chat}.json"),
                                        json.dumps(doc, indent=2)):
                        return None
                # The swap. The check above proved there is no summary in
                # there; anything else is a leftover tmp of ours or something
                # the operating system dropped in, and it must not be the
                # reason a rename fails and a store never gets its chat list.
                for name in os.listdir(target):
                    leftover = os.path.join(target, name)
                    if os.path.isfile(leftover):
                        os.remove(leftover)
                os.rmdir(target)
                os.replace(staging, target)
            except OSError as exc:
                print(f"{stamp()}  messages: could not place the rebuilt chat "
                      f"summaries: {exc}", file=sys.stderr)
                return None

            took = time.monotonic() - began
            print(f"{stamp()}  messages: rebuilt {len(built)} chat "
                  f"summar{'y' if len(built) == 1 else 'ies'} from {rows} "
                  f"record{'' if rows == 1 else 's'} in {took:.2f}s",
                  file=sys.stderr)
            return len(built)

    # -- the per-conversation key indexes ------------------------------------
    #
    # One append-only `.jsonl` per conversation under `messages/.threads/`, and
    # this program is its only writer. Everything that wants one conversation
    # rather than the list of them -- the thread route, the read mark, the two
    # drafts, the send -- starts here.
    #
    # **Kept on write rather than found on read**, which is the summaries'
    # argument one level down. Finding a conversation's messages in the store
    # means looking at the store: the route used to stat every index record,
    # open the newest two thousand of them and keep the ones whose `chat_key`
    # matched. That cost grew with the store rather than with the conversation,
    # and after a history download it was also wrong, because a chat whose rows
    # all fell outside the window came back empty. A post already knows which
    # conversation each row belongs to, so it writes the line then, and a tap
    # opens one small file and then the fifty messages it is about to draw.

    def messages_thread_index_append(self, chat, key, record):
        """Append one stored row to its conversation's key index. Called with
        the feature lock held, once per stored row, never for a duplicate.

        Append and flush rather than read-modify-write: one writer holds the
        lock, the line is short enough to reach the disk in one write, and a
        file that is only ever added to cannot lose what is already in it.

        The lines are not in the conversation's order and are not meant to be
        -- a history page arrives years out of order -- so the reader sorts.
        What this guarantees is that every stored row has a line.
        """
        path = self.messages_path(MESSAGES_THREAD_INDEX_NAME, f"{chat}.jsonl")
        if not path:
            return False
        try:
            with open(path, "a", encoding="utf-8") as fh:
                fh.write(messages_thread_line(key, record))
                fh.flush()
        except OSError:
            return False
        return True

    def messages_thread_index(self, chat):
        """One conversation's rows as [(at, rowid, key, from_me)], oldest
        first, or None when there is no index file for it at all.

        None and an empty list are different answers and the difference is the
        whole of the migration: an empty list is a conversation this program
        has looked at and found nothing in, and None is one it has never
        written a line for, which on a store older than this directory means
        "go and build it".

        Never raises. A line that is not JSON, not an object, or not carrying a
        key of the right shape is dropped: one writer appends to these, but
        they sit on a disk a person can edit, and a mangled line should cost
        its own message rather than the conversation around it.

        Deduped by key on the way out. The writer cannot produce a repeat --
        ingest counts a duplicate and returns before it appends anything -- so
        this is belt and braces over the one corruption a reader would see,
        which is the same message drawn twice.
        """
        path = self.messages_path(MESSAGES_THREAD_INDEX_NAME, f"{chat}.jsonl")
        if not path:
            return None
        seen = {}
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for line in fh:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        row = json.loads(line)
                    except ValueError:
                        continue
                    if not isinstance(row, dict):
                        continue
                    key = row.get("key")
                    if not isinstance(key, str) \
                            or not _MESSAGES_KEY.fullmatch(key) \
                            or key in seen:
                        continue
                    seen[key] = (str(row.get("at") or ""), messages_rowid(row),
                                 key, bool(row.get("from_me")))
        except OSError:
            return None
        # By the stamp the Mac put on the row, then the rowid, then the key.
        # The first two are the conversation's own order; the third is there so
        # that two rows sharing both cannot come back in whichever order they
        # happened to be appended in, because `before` pages by naming a key
        # and a window that moved between two requests would draw a message
        # twice or skip one.
        return sorted(seen.values())

    def messages_rebuild_thread_index(self, chat):
        """Build one conversation's key index from a pass over `index/`.

        The partial case: a conversation whose summary predates this directory,
        or one whose file was removed because an append to it failed. Costs one
        pass over the store for one conversation and happens once for it, so
        the tap that pays for it is slow and every tap after it is not.

        Written even when the conversation turns out to hold nothing, because
        the file is this program's note that it has already looked: without it,
        every tap on an empty conversation would scan the store again.

        Idempotent, and re-checked under the lock rather than before it: the
        whole-store rebuild may have been placing this very file while this
        call was waiting for the lock.
        """
        index = self.messages_path("index")
        path = self.messages_path(MESSAGES_THREAD_INDEX_NAME, f"{chat}.jsonl")
        if not index or not path:
            return None
        with self._messages_lock:
            if os.path.exists(path):
                return None
            began = time.monotonic()
            try:
                with os.scandir(index) as entries:
                    names = [entry.name for entry in entries
                             if _MESSAGES_KEY_NAME.fullmatch(entry.name)]
            except OSError:
                return None
            found = {}
            for name in names:
                try:
                    with open(os.path.join(index, name)) as fh:
                        record = json.load(fh)
                except (OSError, ValueError):
                    continue
                if isinstance(record, dict) and record.get("chat_key") == chat:
                    found[name[:16]] = record
            if not self.messages_ensure_dirs():
                return None
            if not write_atomic(path, messages_thread_index_text(found)):
                return None
            took = time.monotonic() - began
            print(f"{stamp()}  messages: rebuilt the key index for {chat} from "
                  f"{len(found)} of {len(names)} records in {took:.2f}s",
                  file=sys.stderr)
            return len(found)

    def messages_rebuild_thread_indexes(self):
        """Build `messages/.threads/` from one full scan of `index/`.

        The crossing, and the twin of the summaries' rebuild above: a Pi that
        has been holding messages since before the key indexes existed, whose
        conversations would otherwise each be rebuilt the slow way the first
        time somebody opened them. One pass over the store, every conversation
        written out of it, and a no-op the moment there is one of these files
        on disk.

        Held under the feature lock for its whole length, which is the simple
        way to be safe against an ingest landing halfway through: a post that
        arrives during the rebuild waits, and then appends to the file this
        produced rather than to a half-built one. Written into a staging
        directory and swapped in, so a thread read running beside it sees
        either no index for a conversation -- which it answers by rebuilding
        that one, harmlessly and idempotently -- or all of them.
        """
        root = self.messages_dir()
        if not root:
            return None
        index = self.messages_path("index")
        target = self.messages_path(MESSAGES_THREAD_INDEX_NAME)
        staging = self.messages_path(f"{MESSAGES_THREAD_INDEX_NAME}.rebuild")
        if not index or not target or not staging:
            return None

        with self._messages_lock:
            began = time.monotonic()

            # Already built, which is every start after the first. Asked before
            # the index is scanned rather than after it, unlike the summaries':
            # the summaries have just asked the expensive half of this question
            # on the same store, and the answer here is a scandir of one small
            # directory.
            try:
                with os.scandir(target) as entries:
                    for entry in entries:
                        if _MESSAGES_THREAD_NAME.fullmatch(entry.name):
                            return None
            except OSError:
                pass

            # Nothing to rebuild from. Answered before anything is created, so
            # a box that has never had a message on it does not grow a message
            # store because this ran at startup.
            try:
                with os.scandir(index) as entries:
                    names = [entry.name for entry in entries
                             if _MESSAGES_KEY_NAME.fullmatch(entry.name)]
            except OSError:
                return None
            if not names:
                return None

            if not self.messages_ensure_dirs():
                return None

            rows = 0
            groups = {}
            for name in names:
                try:
                    with open(os.path.join(index, name)) as fh:
                        record = json.load(fh)
                except (OSError, ValueError):
                    continue
                if not isinstance(record, dict):
                    continue
                chat = record.get("chat_key")
                if not isinstance(chat, str) or not _MESSAGES_KEY.fullmatch(chat):
                    continue
                rows += 1
                # Keyed by key rather than appended to a list, which is where
                # the dedupe comes from: one index record is one message.
                groups.setdefault(chat, {})[name[:16]] = record

            if not groups:
                return None

            try:
                os.makedirs(staging, exist_ok=True)
                for name in os.listdir(staging):
                    os.remove(os.path.join(staging, name))
                for chat, records in groups.items():
                    if not write_atomic(os.path.join(staging, f"{chat}.jsonl"),
                                        messages_thread_index_text(records)):
                        return None
                # The swap. The check above proved there is no key index in
                # there; anything else is a leftover tmp of ours or something
                # the operating system dropped in, and it must not be the
                # reason a rename fails and a store never gets its threads.
                for name in os.listdir(target):
                    leftover = os.path.join(target, name)
                    if os.path.isfile(leftover):
                        os.remove(leftover)
                os.rmdir(target)
                os.replace(staging, target)
            except OSError as exc:
                print(f"{stamp()}  messages: could not place the rebuilt key "
                      f"indexes: {exc}", file=sys.stderr)
                return None

            took = time.monotonic() - began
            print(f"{stamp()}  messages: rebuilt {len(groups)} conversation key "
                  f"index{'' if len(groups) == 1 else 'es'} from {rows} "
                  f"record{'' if rows == 1 else 's'} in {took:.2f}s",
                  file=sys.stderr)
            return len(groups)

    def messages_migrate(self):
        """Both one-time rebuilds, in the order a store needs them.

        One call rather than two callers, because it is one crossing: a store
        from before either directory existed needs both, each answers "already
        done" for itself in a scandir, and the moment to ask -- a start, or a
        poll that finds records and no chat list -- is the same moment.
        """
        self.messages_rebuild_chat_summaries()
        self.messages_rebuild_thread_indexes()

    def messages_config(self):
        """The allowlist as an object, always. Never raises."""
        doc = self.messages_json("config.json")
        if not isinstance(doc, dict):
            return {"updated_at": None, "chats": {}}
        chats = doc.get("chats")
        return {"updated_at": doc.get("updated_at"),
                "chats": chats if isinstance(chats, dict) else {}}

    def messages_chat_guid(self, chat, summary=None):
        """The conversation's real GUID, off its summary or off the allowlist.
        **Never off a request.**

        This string is what the Bridge hands to Messages.app. A caller who could
        choose it could choose a recipient, which is the same argument that
        keeps a mail reply's address out of the request body, one step more
        serious: an email address at least has to be typed, and a chat GUID is
        already a conversation somebody is in.

        The summary carries the GUID of the newest message in the conversation,
        which is the same fact this used to read by opening the newest index
        record a two-thousand-file window happened to hold -- with the window's
        failure mode taken away. The allowlist is the fallback, for a chat that
        is switched on and has not been written to yet.

        `summary` is the conversation's summary when the caller already has it
        in hand, `{}` to say there is none, and None to have it looked up. The
        difference is one file open, never a different answer.
        """
        doc = (self.messages_chat_summary_doc(chat) if summary is None
               else summary)
        guid = (doc or {}).get("chat_guid")
        if isinstance(guid, str) and guid:
            return guid
        for guid in self.messages_config()["chats"]:
            if isinstance(guid, str) and messages_key(guid) == chat:
                return guid
        return None

    def messages_policy(self, guid):
        """What the allowlist says about one conversation: (policy, read).

        An unknown conversation is `off`, which is the direction a missing entry
        in an allowlist has to fall: the send route refuses it, and the refusal
        is the correct answer rather than a lookup failure.
        """
        entry = self.messages_config()["chats"].get(guid)
        if not isinstance(entry, dict):
            return "off", False
        policy = entry.get("send")
        return (policy if policy in MESSAGES_POLICIES else "off",
                entry.get("read") is True)

    # -- what the Bridge pushes ----------------------------------------------

    def messages_import_allowlist(self):
        """Read consent for new imports. Called with the config writer's lock held."""
        path = self.messages_path("config.json")
        if not path:
            return None
        try:
            with open(path) as fh:
                config = json.load(fh)
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            return None
        chats = config.get("chats") if isinstance(config, dict) else None
        return chats if isinstance(chats, dict) else None

    def messages_ensure_triage(self, key, record):
        """A live inbound record needs either a durable queue entry or a verdict."""
        if record.get("backfill") or record["is_from_me"]:
            return True
        spool = self.messages_path(MESSAGES_QUEUE_NAME, f"triage-{key}")
        if not spool:
            return False
        if os.path.isfile(spool):
            return True
        verdict = self.messages_json("ai", f"{key}.json")
        if verdict and verdict.get("status") in ("ok", "failed"):
            return True
        return write_atomic(spool, key)

    def messages_ingest(self, doc):
        """Store one batch of message rows. (reply, None, None) or
        (None, why, code).

        At-least-once upstream, deduped by key: the Bridge keeps its cursor in
        memory while it streams and persists only what comes back here, so a
        crash re-sends what was not acked and this side ignores keys it already
        holds. That is the whole delivery contract, and it is why a duplicate is
        a counted success rather than an error.

        Per event: the body first, then the index record, then the row folded
        into its conversation's summary and appended to its key index, and the
        spool entry last. The order is the same one the mail workers keep and
        it is the contract: the entry is what wakes the triage worker, so an
        entry that appeared first could name a record that is not there yet,
        and a record that appeared before its body would be a message the
        worker classifies as empty.

        **Only inbound rows are queued.** Our own texts are stored for the
        thread's sake and never triaged: a verdict on something the user wrote
        himself is a model reading his outbox back to him.

        `cursor_ack` is what the Bridge persists, so it is deliberately
        conservative. A temporary failure persists the landed prefix locally and
        returns HTTP 503 so both old and new bridges replay the entire batch.
        A successful receipt can skip a permanently refused row: a malformed
        event will be refused identically forever, and blocking the cursor on
        one would wedge the stream on a row that can never be accepted.

        **A history batch is stored, never queued** (section 7). When
        `backfill` is set, the rows are one allowlisted conversation's past
        rather than its present: they land already read, they raise no triage
        entry, and they leave the cursor exactly where the live stream put it.
        A verdict on a text from March is a model telling somebody about their
        own past, and a conversation switched on today should not arrive with
        years of unread behind it. Everything else is the same route: the same
        bodies, the same records, the same dedupe by key.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500

        events = doc["events"]
        cursor = doc["cursor"]
        backfill = bool(doc.get("backfill"))

        stored = duplicates = rejected = 0
        # The conversations this post touched, read once and written once at
        # the end rather than per row: a hundred events of one conversation is
        # one read and one write, and every one of them is inside the lock the
        # loop already holds.
        touched = {}
        # Conversations whose key index refused an append during this post.
        # Skipped for the rest of it and removed at the end, below.
        broken = set()
        acked = None
        failure = None
        first_error = None

        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 503
            allowlist = self.messages_import_allowlist() if events else {}
            if allowlist is None:
                return None, "cannot read the Messages allowlist", 503

            for row in events:
                record, why = clean_message_event(row)
                if not why:
                    entry = allowlist.get(record["chat_guid"])
                    if not isinstance(entry, dict) or entry.get("read") is not True:
                        why = "reading is not enabled for this conversation"
                if why:
                    # Refused, permanently. Counted and named in the reply so a
                    # Bridge being written against this learns what it got
                    # wrong, and skipped over rather than blocking the cursor.
                    rejected += 1
                    first_error = first_error or why
                    if isinstance(row, dict) \
                            and isinstance(row.get("rowid"), int):
                        acked = max(acked or 0, row["rowid"])
                    continue

                key = record["key"]
                rowid = record["rowid"]
                index = self.messages_path("index", f"{key}.json")
                body = self.messages_path("bodies", f"{key}.txt")
                if not index or not body:
                    failure = "the store rejected a path"
                    break

                if os.path.exists(index):
                    if not backfill:
                        previous = self.messages_record(key)
                        if previous is None or not self.messages_ensure_triage(key, previous):
                            failure = "cannot verify the queued message"
                            break
                    duplicates += 1
                    acked = max(acked or 0, rowid)
                    continue

                text = record.pop("text")
                record["indexed_at"] = stamp()
                # What the row was when it arrived. The per-conversation read
                # mark is what the panel actually counts against; this field is
                # the fact that this row was somebody else's, kept on the record
                # so a thread can be drawn without the mark.
                #
                # History is the exception, and it is written down rather than
                # inferred: a backfilled row is read the moment it lands, and
                # the flag beside it says why, so a thread can tell the past it
                # was handed from the present it watched arrive.
                record["unread"] = not backfill and not record["is_from_me"]
                if backfill:
                    record["backfill"] = True
                record["body_chars"] = len(text)

                if not write_atomic(body, text):
                    failure = "cannot write a message body"
                    break
                if not write_atomic(index, json.dumps(record, indent=2)):
                    failure = "cannot write an index record"
                    break
                stored += 1

                # The conversation's summary, which is what the chat list is
                # built from. Folded here, beside the record, because this is
                # the only moment anything knows that this row is new: a
                # duplicate returned above without touching it, which is what
                # keeps a re-sent batch from counting an unread twice.
                chat = record["chat_key"]
                if chat not in touched:
                    touched[chat] = self.messages_chat_summary(chat)
                self.messages_chat_summary_fold(touched[chat], key, record, text)

                # And the conversation's key index, which is how the thread
                # route finds this row again. Per row rather than per post,
                # unlike the summary beside it: a summary is arithmetic that
                # can be recomputed from the store, and a line that was never
                # written is a message the conversation has lost until
                # something goes looking for it.
                #
                # An append that fails takes the whole file out of service for
                # the rest of this post and the file itself off the disk at the
                # end of it. The rows are stored either way, and an index with
                # a hole in it cannot be told from a whole one, where an index
                # that is not there is rebuilt on the next tap.
                if chat not in broken \
                        and not self.messages_thread_index_append(
                            chat, key, record):
                    broken.add(chat)

                if not self.messages_ensure_triage(key, record):
                    failure = "cannot queue the message for triage"
                    break
                acked = max(acked or 0, rowid)

            # After every row of the batch, so a hundred events of one
            # conversation cost one write. A summary that will not write is
            # not a landing failure: the rows are on disk and the next post
            # into that conversation rewrites it, so the cursor stays where the
            # records put it.
            for chat, doc in touched.items():
                if not self.messages_chat_summary_put(chat, doc):
                    print(f"{stamp()}  messages: could not write the summary "
                          f"for {chat}", file=sys.stderr)

            # A key index that refused a line is worse than no key index at
            # all, because nothing can see that it is short. Removed, so the
            # next read of that conversation rebuilds it from the records --
            # which are on disk, which is why none of this is a landing
            # failure: re-sending the batch would only be deduped.
            for chat in broken:
                path = self.messages_path(MESSAGES_THREAD_INDEX_NAME,
                                          f"{chat}.jsonl")
                try:
                    if path:
                        os.remove(path)
                except OSError:
                    pass
                print(f"{stamp()}  messages: could not append to the key index "
                      f"for {chat}; it will be rebuilt on the next read",
                      file=sys.stderr)

            fields = {
                "last_ingest_at": stamp(),
                "last_ingest_ok": failure is None,
                "last_error": failure,
            }
            if backfill:
                # An echo, not an acknowledgement. A page of old rows says
                # nothing about where the present is, so the cursor is neither
                # moved nor recomputed here; what goes back is the number that
                # came in, and the Bridge is expected to ignore it.
                ack = cursor
                fields["backfill_last_at"] = fields["last_ingest_at"]
            else:
                ack = (acked or 0) if failure else cursor
                known = self.messages_state().get("cursor")
                # Never backwards. The Bridge is the one that decides where to
                # resume; this number is what the panel shows and what a second
                # Bridge would start from, and a late-arriving retry of an old
                # batch must not rewind it.
                fields["cursor"] = (max(ack, known) if isinstance(known, int)
                                    else ack)
            if not self.messages_write_state(**fields):
                return None, "cannot write the Messages ingest state", 503
            if failure:
                return None, failure, 503

        reply = {"ok": True, "stored": stored, "duplicates": duplicates,
                 "cursor_ack": ack}
        if rejected:
            reply["rejected"] = rejected
            reply["error"] = str(first_error)[:MESSAGES_ERROR_CHARS]
        return reply, None, None

    def messages_bridge(self, doc):
        """Record one heartbeat. (True, None, None) or (None, why, code).

        Stored verbatim plus the moment it landed, because the moment it landed
        is the only clock in this exchange that this program can reason about: a
        laptop's own idea of the time is a claim, and staleness has to be
        measured against ours or a Mac with a wrong clock reads as permanently
        fresh or permanently dead.

        This is also the route that brings the channel to life: the first
        heartbeat creates `state.json`, which is what `MessagesSource.configured`
        looks for, so the panel stops being dormant the moment a Bridge says
        hello rather than at the next collector restart.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        path = self.messages_path("bridge.json")
        if not path:
            return None, "could not place the heartbeat", 500
        record = dict(doc)
        record["received_at"] = stamp()
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            if not write_atomic(path, json.dumps(record, indent=2)):
                return None, "cannot write the heartbeat", 500
            if not self.messages_write_state(bridge_seen_at=record["received_at"]):
                return None, "cannot write the messages state", 500
        return True, None, None

    def messages_chats_put(self, chats):
        """Replace the conversation directory. (count, None, None) or
        (None, why, code).

        Whole-list replacement rather than a merge, matching what the Bridge
        sends: it reads the whole chat list off the Mac each time, so a merge
        here would leave a conversation that was deleted on the phone in the
        picker forever.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        path = self.messages_path("chats.json")
        if not path:
            return None, "could not place the chat directory", 500
        doc = {"updated_at": stamp(), "chats": chats}
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the chat directory", 500
        return len(chats), None, None

    def messages_directory_name(self, chat):
        """What the Mac's address book calls this conversation, or None.

        One read of the directory per thread open; it is a hundred-odd rows
        and the name of a thread is worth it."""
        doc = self.messages_json("chats.json") or {}
        rows = doc.get("chats") if isinstance(doc, dict) else doc
        if not isinstance(rows, list):
            return None
        for row in rows:
            if isinstance(row, dict) and row.get("chat_key") == chat:
                name = row.get("name") or row.get("contact_name")
                return name if isinstance(name, str) and name else None
        return None

    def messages_chats_get(self):
        """The directory merged with the allowlist, for the settings picker.

        Merged here rather than on the Mac because the two files have different
        writers and different lifetimes: the directory is whatever the phone
        currently has, the allowlist is what the user decided about it, and a
        client joining them would need both routes and a rule for a conversation
        that appears in one and not the other.
        """
        doc = self.messages_json("chats.json") or {}
        listed = doc.get("chats")
        listed = listed if isinstance(listed, list) else []
        config = self.messages_config()["chats"]

        out = []
        seen = set()
        for row in listed:
            if not isinstance(row, dict):
                continue
            guid = row.get("chat_guid")
            entry = config.get(guid) if isinstance(guid, str) else None
            entry = entry if isinstance(entry, dict) else {}
            merged = dict(row)
            merged["policy"] = (entry.get("send")
                                if entry.get("send") in MESSAGES_POLICIES
                                else "off")
            merged["read"] = bool(entry.get("read"))
            shown = messages_display_name(entry.get("name"), merged.get("name"),
                                          merged.get("contact_name"),
                                          merged.get("chat_identifier"))
            if shown:
                merged["name"] = shown
            out.append(merged)
            if isinstance(guid, str):
                seen.add(guid)

        # An allowlisted conversation the directory no longer names. Kept
        # visible rather than dropped: a chat the user turned on and the phone
        # then stopped listing is exactly the row he needs to see to turn it off
        # again, and a picker that silently forgot it would leave a permission
        # granted with nowhere to revoke it.
        for guid, entry in config.items():
            if guid in seen or not isinstance(entry, dict):
                continue
            out.append({
                "chat_guid": guid,
                "chat_key": messages_key(guid),
                "name": entry.get("name"),
                "policy": (entry.get("send")
                           if entry.get("send") in MESSAGES_POLICIES else "off"),
                "read": bool(entry.get("read")),
                "missing": True,
            })

        return {"chats": out, "updated_at": doc.get("updated_at")}

    # -- what the app edits --------------------------------------------------

    def messages_config_get(self):
        return self.messages_config()

    def messages_config_put(self, config):
        """Replace the allowlist. (True, None, None) or (None, why, code).

        Already validated by `parse_messages_config` before it gets here, which
        is the one piece of vetting in this program that is deliberately a
        second copy of somebody else's: `msglib` on the pipeline side validates
        the same document the same way, and this file does not import it.
        Importing would put the whole mail pipeline inside the import graph of
        the process with a listening port, to save forty lines that are a table
        of three field types.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        path = self.messages_path("config.json")
        if not path:
            return None, "could not place the config", 500
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            if not write_atomic(path, json.dumps(config, indent=2)):
                return None, "cannot write the config", 500
        return True, None, None

    def messages_thread(self, chat, limit, before):
        """One conversation, oldest to newest, with bodies. (payload, None, None)
        or (None, why, code).

        The one route on this channel that carries text, and the reason the
        telemetry payload does not have to. A merge rather than a file, like the
        mail message route: the records, the bodies, the verdicts and the two
        drafts are written by three programs, and asking the app to fetch them
        one at a time would be a round trip per message.

        **The conversation is read out of its key index, never out of a scan
        of the store.** `.threads/<chat_key>.jsonl` says which messages this
        conversation holds and in what order, the window is chosen from that,
        and then exactly the messages in the window are opened. A tap costs the
        length of the conversation plus the fifty rows being drawn rather than
        the size of the store -- and a long thread comes back whole, which
        under the old mtime window it did not: a conversation whose records all
        fell outside the newest two thousand files answered empty or 404.

        `before` pages backwards by naming the oldest message already on screen.
        A key that is not in this conversation is ignored rather than refused:
        the app holds it from a previous answer, and the conversation may have
        been pruned underneath it.
        """
        summary = self.messages_chat_summary_doc(chat)
        rows = self.messages_thread_index(chat)
        if rows is None and summary is not None:
            # A conversation this program knows and has never written a key
            # index for: a store older than the indexes, or one that lost a
            # file. Built once, here, at the cost of this one tap.
            self.messages_rebuild_thread_index(chat)
            rows = self.messages_thread_index(chat)
        rows = rows or []
        guid = self.messages_chat_guid(chat, summary=summary or {})
        # A conversation is real if the store holds a summary for it, a row of
        # it, or an allowlist entry naming it. None of the three is a 404, and
        # a summary with nothing under it is an empty thread rather than an
        # absent one: the messages may simply not have arrived yet.
        if not rows and summary is None and guid is None:
            return None, f"no conversation {chat}", 404

        if before:
            cut = next((i for i, row in enumerate(rows) if row[2] == before),
                       None)
            if cut is not None:
                rows = rows[:cut]

        window = rows[-limit:] if limit else rows
        policy, allowed = self.messages_policy(guid)
        config_entry = self.messages_config()["chats"].get(guid) or {}

        messages = []
        for _, _, key, _ in window:
            record = self.messages_record(key)
            if record is None:
                # A line whose record is gone. One message costs itself, which
                # is the rule every other read in this store keeps.
                continue
            text, truncated = self.messages_text(key)
            item = dict(record)
            item["key"] = key
            item["text"] = text
            item["text_truncated"] = truncated
            # `n` and `stored` on every attachment, filled in from the record's
            # own shape where an older one predates them. The app decides
            # between drawing a photograph and offering to fetch it on these
            # two fields alone, so neither may be absent on a row it draws.
            item["attachments"] = messages_attachment_rows(
                record.get("attachments"))
            art = self.messages_json("ai", f"{key}.json")
            # The same rule as the panel: a pending record is the worker
            # counting attempts, not a verdict.
            item["ai"] = art if isinstance(art, dict) \
                and art.get("status") == "ok" else None
            messages.append(item)

        # Who the conversation is with, off its summary. The newest record in
        # the window would answer differently for a page of a five-year-old
        # thread, and the identity of a conversation is not a fact about which
        # page of it is on screen.
        head = summary or (messages[-1] if messages else {})
        mark = self.messages_json(MESSAGES_READ_NAME, f"{chat}.json") or {}
        return {
            "chat": {
                "chat_key": chat,
                "chat_guid": guid,
                "name": mail_line(messages_display_name(
                                      config_entry.get("name"),
                                      self.messages_directory_name(chat),
                                      head.get("chat_name"),
                                      head.get("chat_identifier")),
                                  MESSAGES_NAME_CHARS),
                "is_group": bool(head.get("is_group")),
                "service": head.get("service"),
                "participants": head.get("participants"),
                "policy": policy,
                "read": allowed,
                "unread": messages_count(summary.get("unread")) if isinstance(summary, dict) else 0,
            },
            "messages": messages,
            "has_more": len(rows) > len(window),
            # Two drafts, two writers, one field each: the worker owns the first
            # and the human owns the second, so a regenerate cannot eat what
            # somebody typed and a save cannot be mistaken for a verdict.
            "draft": self.messages_json("drafts", f"{chat}.json"),
            "user_draft": self.messages_json("drafts", f"{chat}.user.json"),
            # What this conversation has filed and the Bridge has not yet
            # turned into a message row. Beside the transcript rather than in
            # it: an outbox item is a request, and the transcript is a record.
            "outbox": self.messages_thread_outbox(chat),
            "read_to": mark.get("last_read_key"),
        }, None, None

    def messages_read(self, chat):
        """Move this conversation's read mark to its newest message.
        (True, None, None) or (None, why, code).

        Charon's own read state, and the whole of it. The Messages app's flags
        are not consulted and not written: what this records is that the user
        has seen this conversation *here*, which is a different fact and the
        only one this console is entitled to have an opinion about.

        The mark is a key and a timestamp rather than a count, so it survives
        messages arriving between the tap and the write. Both come off the
        conversation's summary, which is where the newest message is already
        written down: reading it there rather than finding it in the store is
        the same answer over the whole conversation instead of over whatever
        window a scan happened to cover.

        Two files, one act. The mark is the durable record and is what a
        rebuild recomputes from; the conversation's summary is the number the
        chat list draws, and it is zeroed here rather than recomputed on the
        next poll because the poll no longer opens the messages it would have
        to count.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        summary = self.messages_chat_summary_doc(chat)
        if summary is None:
            return None, f"no conversation {chat}", 404
        path = self.messages_path(MESSAGES_READ_NAME, f"{chat}.json")
        if not path:
            return None, "could not place the read mark", 500
        doc = {"chat_key": chat, "last_read_key": summary.get("last_key"),
               "last_read_at": summary.get("last_at"), "at": stamp()}
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the read mark", 500
            self.messages_chat_summary_clear(chat)
        return True, None, None

    def messages_draft(self, chat, instructions):
        """Ask for an AI reply draft. (status, None, None) or (None, why, code).

        The record is written before the spool entry, the same contract as
        everything else that wakes a worker here: the entry is what starts the
        session, so an entry that appeared first could name a file that is not
        there yet.

        Unlike mail there is no "you already have one" short circuit and no
        force flag. A text draft is written against the whole conversation, so
        the same request an hour later is a genuinely different question, and
        the steering line is the usual reason somebody asks twice.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        summary = self.messages_chat_summary_doc(chat)
        if summary is None:
            return None, f"no conversation {chat}", 404
        guid = self.messages_chat_guid(chat, summary=summary)
        path = self.messages_path("drafts", f"{chat}.json")
        spool = self.messages_path(MESSAGES_QUEUE_NAME, f"draft-{chat}")
        if not path or not spool:
            return None, "could not place the draft", 500

        doc = {
            "chat_key": chat,
            "chat_guid": guid,
            "status": "pending",
            # Short steering from the reader, or None. The prompt file is where
            # the voice lives; this is where "tell her I am running late" goes.
            "instructions": instructions,
            # Named here as nulls so the shape of the record is complete from
            # the first write, and named with the worker's own field names so
            # the record keeps one shape across both writers.
            "text": None,
            "model": None,
            "error": None,
            "at": stamp(),
        }
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the draft", 500
            if not write_atomic(spool, chat):
                # The request is on disk and nothing is coming to answer it.
                # Reported as a failure rather than as a success followed by a
                # silence, which is the version the app cannot explain.
                return None, "cannot queue the draft", 500
        return "pending", None, None

    def messages_save_draft(self, chat, body):
        """Save what the human typed. (True, None, None) or (None, why, code).

        Its own file, not the worker's, so the two never overwrite each other.
        No spool entry either: nothing has to happen because somebody typed, and
        a queue entry per keystroke would wake a worker for nothing. This is the
        one write on this channel that wakes no one.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        if self.messages_chat_summary_doc(chat) is None:
            return None, f"no conversation {chat}", 404
        path = self.messages_path("drafts", f"{chat}.user.json")
        if not path:
            return None, "could not place the draft", 500
        doc = {"chat_key": chat, "status": "ready", "text": body,
               "instructions": None, "model": None, "error": None,
               "at": stamp()}
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the draft", 500
        return True, None, None

    # -- the one thing that leaves the house ---------------------------------

    def messages_new_id(self):
        """A fresh send id: sixteen hex, minted here. Re-rolled if the name is
        taken, which would mean overwriting somebody's audit record."""
        for _ in range(8):
            mid = os.urandom(8).hex()
            path = self.messages_path("outbox", f"{mid}.json")
            if path and not os.path.exists(path):
                return mid
        return None

    def messages_send(self, chat, body, request_id=None):
        """Queue one text for sending. (id, None, None) or (None, why, code).

        The only route on this channel whose effect leaves the house, so the
        recipient is not a parameter. **`chat_guid` is computed here from the
        conversation being answered and the caller cannot influence it** -- see
        `messages_chat_guid`. A caller supplies words, never a destination.

        The allowlist is checked here and checked again by the Bridge before it
        performs the send. Two locks on the same door, and worth having on the
        one action that cannot be undone: `off` and unknown are both refusals,
        and they are the same refusal on purpose, because "I have never heard of
        this conversation" is not a weaker no than "the user turned this one
        off".

        The record is written before the spool entry, and it matters most here.
        Queued and nothing more: nothing on this box performs it, nothing here
        retries it, and a failed send stays visible for the user to send again
        by hand.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        if request_id is not None and (not isinstance(request_id, str) or
                not _MESSAGES_REQUEST_ID.fullmatch(request_id)):
            return None, "request_id must be a lowercase UUID", 400

        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 503
            mid = (messages_key("send:" + request_id) if request_id is not None
                   else self.messages_new_id())
            if not mid:
                return None, "could not mint a send id", 500
            path = self.messages_path("outbox", f"{mid}.json")
            spool = self.messages_path(MESSAGES_ACTIONS_NAME, f"send-{mid}")
            if not path or not spool:
                return None, "could not place the send record", 500

            if os.path.exists(path):
                existing = self.messages_json("outbox", f"{mid}.json")
                if existing is None:
                    return None, "cannot verify the existing send", 503
                if (request_id is None or existing.get("request_id") != request_id
                        or existing.get("chat_key") != chat or existing.get("body") != body):
                    return None, "send id is already in use", 409
                return mid, None, None

            guid = self.messages_chat_guid(chat)
            if guid is None:
                return None, f"no conversation {chat}", 404
            policy, read = self.messages_policy(guid)
            if not read or policy != "confirm":
                return None, "sending is not enabled for this conversation", 403

            doc = {
                "id": mid,
                "chat_key": chat,
                "chat_guid": guid,
                "body": body,
                "status": "queued",
                "at": stamp(),
                # The Bridge's fields, named as nulls so the record's shape is
                # complete from the first write.
                "sent_at": None,
                "guid": None,
                "message_id": None,
                "error": None,
                "disposition": None,
                "retry_safe": None,
            }
            if request_id is not None:
                doc["request_id"] = request_id
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the send record", 503
            # The Bridge pulls queued records directly from outbox/. This
            # marker is informational. Once the record lands, submission has
            # succeeded even if the marker cannot be written.
            write_atomic(spool, mid)
        return mid, None, None

    def messages_thread_outbox(self, chat):
        """This conversation's recent sends, oldest first. Bounded.

        The thread route's answer to a gap the transcript cannot close on its
        own: a text is filed here, performed on the Mac, written into
        `chat.db`, and only then comes back up through ingest as a message. For
        the seconds or minutes in between, the outbox record is the only copy
        of it this system has, and an app that drew the transcript alone would
        show nothing where the user just pressed Enter.

        **A scan of `outbox/`, and bounded three ways.** The directory is small
        by construction -- one file per send this box has ever been asked to
        make -- but "small" is a fact about today, so: the entries are sorted
        newest first, the walk stops at the first record older than a day, and
        no more than `MESSAGES_SCAN_MAX` files are opened whatever the mtimes
        say. A per-chat index would be a second thing to keep correct for a
        directory that holds tens of files.

        mtime rather than the record's own `at` decides where the walk stops,
        and it is the safe direction: a record is rewritten when it is
        reported, so its mtime is never earlier than its `at`, and a file whose
        mtime is outside the window cannot hold a stamp inside it.
        """
        root = self.messages_path("outbox")
        if not root:
            return []
        found = []
        try:
            with os.scandir(root) as entries:
                for entry in entries:
                    if not _MESSAGES_KEY_NAME.fullmatch(entry.name):
                        continue
                    try:
                        found.append((entry.stat().st_mtime, entry.path))
                    except OSError:
                        continue
        except OSError:
            return []
        found.sort(reverse=True)

        floor = time.time() - MESSAGES_THREAD_OUTBOX_AGE
        items = []
        for mtime, path in found[:MESSAGES_SCAN_MAX]:
            if mtime < floor:
                break
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if not isinstance(doc, dict) or doc.get("chat_key") != chat:
                continue
            try:
                when = datetime.fromisoformat(doc.get("at"))
            except (TypeError, ValueError):
                when = None
            # A record whose stamp is unreadable is kept rather than dropped:
            # the file is inside the mtime window, so it is recent, and a send
            # this box cannot date is still a send it made.
            if when is not None and when < datetime.now(when.tzinfo) - timedelta(
                    seconds=MESSAGES_THREAD_OUTBOX_AGE):
                continue
            items.append({
                "id": doc.get("id"),
                "request_id": doc.get("request_id"),
                "status": doc.get("status"),
                "body": doc.get("body"),
                "at": doc.get("at"),
                "sent_at": doc.get("sent_at"),
                # The Messages row this send became, which is what lets the app
                # recognise its own optimistic bubble when the real row arrives.
                "guid": doc.get("guid"),
                "message_id": doc.get("message_id"),
                "error": doc.get("error"),
                "disposition": doc.get("disposition"),
                "retry_safe": doc.get("retry_safe"),
            })
            if len(items) >= MESSAGES_THREAD_OUTBOX_MAX:
                break
        # Newest last, the way the transcript above it is ordered.
        items.reverse()
        return items

    def messages_outbox_queued(self):
        """What the Bridge should perform, oldest first. Bounded.

        Oldest first because a conversation is a sequence: two replies filed a
        minute apart have to arrive in the order they were written, and a pull
        that handed back the newest would reverse them.
        """
        found = []
        root = self.messages_path("outbox")
        if not root:
            return []
        try:
            with os.scandir(root) as entries:
                for entry in entries:
                    if not _MESSAGES_KEY_NAME.fullmatch(entry.name):
                        continue
                    try:
                        found.append((entry.stat().st_mtime, entry.path))
                    except OSError:
                        continue
        except OSError:
            return []
        found.sort()

        items = []
        for _, path in found:
            try:
                with open(path) as fh:
                    doc = json.load(fh)
            except (OSError, ValueError):
                continue
            if isinstance(doc, dict) and doc.get("status") == "queued":
                items.append(doc)
            if len(items) >= MESSAGES_OUTBOX_PULL_MAX:
                break
        return items

    def messages_outbox_report(self, mid, report):
        """Record what happened to one send. (True, None, None) or
        (None, why, code).

        The Bridge is the only writer of these fields, and it writes each of
        them once: a send is one attempt, reported honestly, and nothing on
        either side retries it. A report naming a record that is not queued any
        more is accepted only when its outcome matches the recorded one. This
        lets a Bridge retry a lost HTTP acknowledgement across a restart.

        The audit line is written before the record turns, because it is the
        only permanent copy: an outward action this system took has a line in
        that file whatever happens to the record afterwards.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        path = self.messages_path("outbox", f"{mid}.json")
        spool = self.messages_path(MESSAGES_ACTIONS_NAME, f"send-{mid}")
        if not path:
            return None, "could not place the send record", 500

        with self._messages_lock:
            doc = self.messages_json("outbox", f"{mid}.json")
            if doc is None:
                return None, f"no queued send {mid}", 404
            if doc.get("status") != "queued":
                fields = (("guid", "message_id") if report["status"] == "sent"
                          else ("error", "disposition", "retry_safe"))
                if (doc.get("status") == report["status"] and
                        all(doc.get(field) == report.get(field) for field in fields)):
                    return True, None, None
                return None, f"send {mid} is already {doc.get('status')}", 409

            state = report["status"]
            doc["status"] = state
            doc["sent_at"] = stamp()
            if state == "sent":
                doc["guid"] = report.get("guid")
                doc["message_id"] = report.get("message_id")
            else:
                doc["error"] = report.get("error")
                doc["disposition"] = report.get("disposition")
                doc["retry_safe"] = report.get("retry_safe")

            line = (f"{doc['sent_at']} {state} id={mid} "
                    f"chat={doc.get('chat_key')} chars={len(doc.get('body') or '')}")
            if state == "sent":
                line += f" guid=\"{messages_one_line(doc.get('guid'), 120)}\""
            else:
                line += (f" error=\"{messages_one_line(doc.get('error'), 200)}\""
                         f" disposition=\"{messages_one_line(doc.get('disposition'), 60)}\"")
            audit = self.messages_path("audit.log")
            if audit:
                try:
                    with open(audit, "a") as fh:
                        fh.write(line + "\n")
                except OSError:
                    # The trail is best effort and the record is not. A disk
                    # that refused the append will refuse the record too, and
                    # that is the failure worth reporting.
                    pass

            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the send record", 500
            if spool:
                try:
                    os.remove(spool)
                except OSError:
                    # Informational only: nothing on this box consumes it, and
                    # an entry left behind is a stale note rather than work that
                    # happens twice.
                    pass
        return True, None, None

    # -- the attachments -----------------------------------------------------
    #
    # The only bytes on this channel, and the only route on this server whose
    # request body is not JSON. Four calls hold the whole of it: the Bridge
    # stages an upload and then names it, the app reads one back, the app asks
    # for one that is not here, and the Bridge reads the list of asks.
    #
    # **Nothing here mints a path from a caller's string.** The directory is
    # the message key, which the route already matched against sixteen hex; the
    # file is the attachment's position, which the route already matched
    # against three digits; and the extension is computed from the sidecar by a
    # function whose whole output alphabet is `[a-z0-9]`. `messages_path`
    # asserts containment over the top of all three, the same belt and braces
    # every other path in this store gets.

    def messages_attachment_permission(self, record):
        allowlist = self.messages_import_allowlist()
        if allowlist is None:
            return "cannot read the Messages allowlist", 503
        entry = allowlist.get(record.get("chat_guid"))
        if not isinstance(entry, dict) or entry.get("read") is not True:
            return "reading is not enabled for this conversation", 403
        return None, None

    def messages_attachment_staging(self, key, n):
        """Where an upload's bytes are written before they are named.
        (path, None, None) or (None, why, code).

        Called before a byte is read, so a message this store has never heard
        of is a 404 that costs nothing rather than a 404 that costs twenty-five
        megabytes of somebody's uplink. The staging file is inside the
        attachment's own directory, which is what makes the rename that
        finishes an upload a rename rather than a copy across filesystems, and
        it is uniquely named so two uploads of the same pair cannot write over
        each other halfway.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            record = self.messages_record(key)
            if record is None:
                return None, f"no message {key}", 404
            why, code = self.messages_attachment_permission(record)
            if why:
                return None, why, code
            listed = record.get("attachments")
            if not isinstance(listed, list) or n >= len(listed):
                return None, f"no attachment {n} on {key}", 404
            room = self.messages_path(MESSAGES_ATTACHMENTS_DIR_NAME, key)
            if not room:
                return None, "could not place the attachment", 500
            try:
                os.makedirs(room, exist_ok=True)
            except OSError:
                return None, "cannot create the attachment directory", 500
            return os.path.join(room, f".{n}.{os.urandom(8).hex()}.part"), None, None

    def messages_attachment_store(self, key, n, staged, size, digest,
                                  ctype, filename, claimed):
        """Name one staged upload and record that the store holds it.
        (reply, None, None) or (None, why, code).

        **Idempotent, and cheaply so.** The same pair uploaded twice is 200
        both times, and the second one does not rewrite the file when the
        digest already on disk is the digest that just arrived. That is what
        makes a retry free: a Bridge whose upload landed and whose answer did
        not can send the bytes again without this side noticing.

        The claimed digest is checked against the one computed while the body
        was being written, which is the only moment both numbers exist. A
        mismatch throws the staging file away and answers 400: half a
        photograph filed as a whole one is worse than no photograph.

        Three things land together at the end, in this order: the file, its
        sidecar, and the `stored` flag on the index record. The flag is last
        because it is what everything else reads to decide the bytes are there,
        and a flag ahead of its file would be a tile that draws a hole.
        """
        def scrap():
            try:
                os.remove(staged)
            except OSError:
                pass

        if claimed and not _MESSAGES_SHA256.fullmatch(claimed):
            scrap()
            return None, "the digest is not sixty-four hex characters", 400
        if claimed and claimed != digest:
            scrap()
            return None, "the digest does not match the bytes", 400

        with self._messages_lock:
            record = self.messages_record(key)
            index = self.messages_path("index", f"{key}.json")
            if record is None or not index:
                scrap()
                return None, f"no message {key}", 404
            why, code = self.messages_attachment_permission(record)
            if why:
                scrap()
                return None, why, code
            listed = record.get("attachments")
            if not isinstance(listed, list) or n >= len(listed):
                scrap()
                return None, f"no attachment {n} on {key}", 404

            named = listed[n] if isinstance(listed[n], dict) else {}
            name = messages_attachment_name(
                filename or named.get("filename"), n)
            kind = messages_attachment_ctype(ctype or named.get("mime_type"))
            here = self.messages_path(MESSAGES_ATTACHMENTS_DIR_NAME, key,
                                      f"{n}.{messages_attachment_ext(name, kind)}")
            sidecar = self.messages_path(MESSAGES_ATTACHMENTS_DIR_NAME, key,
                                         f"{n}.json")
            if not here or not sidecar:
                scrap()
                return None, "could not place the attachment", 500

            held = self.messages_json(MESSAGES_ATTACHMENTS_DIR_NAME, key,
                                      f"{n}.json") or {}
            same = (held.get("sha256") == digest
                    and os.path.isfile(here))
            if same:
                scrap()
                size = held.get("bytes") if isinstance(held.get("bytes"), int) \
                    else size
            else:
                # A file already here under another extension is the same
                # attachment sent again with a better name. Named from the
                # sidecar it was written with rather than guessed at, so the
                # store cannot end up holding one photograph twice.
                if held:
                    was_name = messages_attachment_name(held.get("filename"), n)
                    was_kind = messages_attachment_ctype(held.get("mime_type"))
                    was_ext = messages_attachment_ext(was_name, was_kind)
                    stale = self.messages_path(MESSAGES_ATTACHMENTS_DIR_NAME,
                                               key, f"{n}.{was_ext}")
                    if stale and stale != here:
                        try:
                            os.remove(stale)
                        except OSError:
                            pass
                try:
                    os.replace(staged, here)
                except OSError:
                    scrap()
                    return None, "cannot write the attachment", 500
                if not write_atomic(sidecar, json.dumps(
                        {"filename": name, "mime_type": kind, "bytes": size,
                         "sha256": digest, "at": stamp()}, indent=2)):
                    return None, "cannot write the attachment record", 500

            if isinstance(listed[n], dict):
                listed[n]["n"] = n
                listed[n]["stored"] = True
                if not write_atomic(index, json.dumps(record, indent=2)):
                    return None, "cannot write the index record", 500

            # Whoever asked has been answered. Removed rather than marked, so
            # the Bridge's next poll is a scandir over what is still owed.
            want = self.messages_path(MESSAGES_WANTS_NAME, f"{key}-{n}.json")
            if want:
                try:
                    os.remove(want)
                except OSError:
                    pass

        return {"ok": True, "bytes": size}, None, None

    def messages_attachment_open(self, key, n):
        """One stored attachment, ready to be streamed.
        (path, size, filename, content-type, None) or (None, .., why).

        A path rather than the bytes, unlike the mailbox's route beside it. An
        email attachment has to be parsed out of a message that is already
        being read whole; this one is a file, and handing back a path lets the
        route copy it to the socket a chunk at a time rather than hold
        twenty-five megabytes in a Pi's memory to send it.
        """
        held = self.messages_json(MESSAGES_ATTACHMENTS_DIR_NAME, key, f"{n}.json")
        if not isinstance(held, dict):
            return None, 0, None, None, f"attachment {n} of {key} is not stored"
        name = messages_attachment_name(held.get("filename"), n)
        kind = messages_attachment_ctype(held.get("mime_type"))
        path = self.messages_path(MESSAGES_ATTACHMENTS_DIR_NAME, key,
                                  f"{n}.{messages_attachment_ext(name, kind)}")
        if not path:
            return None, 0, None, None, f"no attachment {n} of {key}"
        try:
            size = os.path.getsize(path)
        except OSError:
            # The sidecar without its file: a half-finished delete, or a disk
            # that lost one of the two. Reported as not stored, which is what
            # the app already knows how to draw.
            return None, 0, None, None, f"attachment {n} of {key} is not stored"
        return path, size, name, kind, None

    def messages_attachment_want(self, key, n):
        """Ask the Bridge for one attachment it did not send.
        (True, None, None) or (None, why, code).

        Idempotent by construction: the entry is named for the pair it names,
        so a second tap is the same one file. Deliberately not rewritten on the
        second tap either -- the file's age is what expires a want nobody can
        answer, and restarting that clock on every tap would make it
        unexpirable.

        An attachment this store already holds is not a want and is answered
        `ok` anyway: the app has just learned it can stop asking, and a 409
        here would be a failed tap on a photograph that is sitting on disk.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        with self._messages_lock:
            if not self.messages_ensure_dirs():
                return None, "cannot create the messages store", 500
            record = self.messages_record(key)
            if record is None:
                return None, f"no message {key}", 404
            listed = record.get("attachments")
            if not isinstance(listed, list) or n >= len(listed):
                return None, f"no attachment {n} on {key}", 404
            if isinstance(listed[n], dict) and listed[n].get("stored"):
                return True, None, None
            path = self.messages_path(MESSAGES_WANTS_NAME, f"{key}-{n}.json")
            if not path:
                return None, "could not place the want", 500
            if os.path.exists(path):
                return True, None, None
            if not write_atomic(path, json.dumps(
                    {"key": key, "n": n, "at": stamp()}, indent=2)):
                return None, "cannot write the want", 500
        return True, None, None

    def messages_attachments_wanted(self):
        """What the Bridge should upload, oldest first. Bounded.

        The join the Bridge cannot do for itself: a want names a message and a
        position, and what the Mac needs in order to find the file again is the
        row's own guid, its rowid and the conversation it was in. All three are
        on the index record, so this route reads the want, opens the record and
        hands back one flat item.

        Three kinds of want are dropped rather than served. One older than a
        week, because Messages ages big files out and a file the Mac could not
        produce in seven days is a file the Mac does not have. One whose
        message is gone. One whose attachment is already stored, which is the
        race between a tap and an upload that was already on its way.
        """
        room = self.messages_path(MESSAGES_WANTS_NAME)
        if not room:
            return []
        found = []
        try:
            with os.scandir(room) as entries:
                for entry in entries:
                    if not _MESSAGES_WANT_NAME.fullmatch(entry.name):
                        continue
                    try:
                        found.append((entry.stat().st_mtime, entry.name))
                    except OSError:
                        continue
        except OSError:
            return []
        found.sort()

        def forget(name):
            path = self.messages_path(MESSAGES_WANTS_NAME, name)
            try:
                if path:
                    os.remove(path)
            except OSError:
                pass

        now = time.time()
        items = []
        for when, name in found:
            matched = _MESSAGES_WANT_NAME.fullmatch(name)
            key, n = matched.group(1), int(matched.group(2))
            if now - when > MESSAGES_WANT_MAX_AGE:
                forget(name)
                continue
            record = self.messages_record(key)
            listed = record.get("attachments") if isinstance(record, dict) else None
            if not isinstance(listed, list) or n >= len(listed) \
                    or not isinstance(listed[n], dict):
                forget(name)
                continue
            if listed[n].get("stored"):
                forget(name)
                continue
            items.append({
                "key": key,
                "n": n,
                "guid": record.get("guid"),
                "rowid": messages_rowid(record),
                "chat_guid": record.get("chat_guid"),
                "filename": listed[n].get("filename"),
                "mime_type": listed[n].get("mime_type"),
                "total_bytes": listed[n].get("total_bytes"),
            })
            if len(items) >= MESSAGES_WANTS_PULL_MAX:
                break
        return items

    # -- the daily read ------------------------------------------------------

    def messages_summary(self, date):
        """One day's summary document, or (None, why). Served as it was written:
        the worker already validated and clipped every field in it."""
        doc = self.messages_json("summaries", f"{date}.json")
        if doc is None:
            return None, f"no summary for {date}"
        return doc, None

    def messages_summary_flag(self, date, field):
        """Mark one day read or archived. (True, None, None) or
        (None, why, code).

        Read-modify-write over a file the worker also rewrites, which is why it
        holds the feature lock. The worker preserves `archived` across a
        regeneration and clears `read` when the content changed, so these two
        flags and that rule are one design: a day that says something new comes
        back unread, and a day the user filed away stays filed.
        """
        if not self.messages_dir():
            return None, "messages.base_dir is unset", 500
        path = self.messages_path("summaries", f"{date}.json")
        if not path:
            return None, "could not place the summary", 500
        with self._messages_lock:
            doc = self.messages_json("summaries", f"{date}.json")
            if doc is None:
                return None, f"no summary for {date}", 404
            doc[field] = True
            if not write_atomic(path, json.dumps(doc, indent=2)):
                return None, "cannot write the summary", 500
        return True, None, None


# --- server ------------------------------------------------------------------

COOKIE = "hc_session"
# The only route with a variable in it. The date shape is asserted here so that
# nothing else in the path can be one, and `Collector.briefing` asserts
# containment again on top of it.
BRIEFING_ROUTE = re.compile(r"/v1/cmo/briefing/(\d{4}-\d{2}-\d{2})")
DOSSIER_ROUTE = re.compile(r"/v1/cmo/dossier/([a-z0-9-]{1,64})")
DOC_ROUTE = re.compile(r"/v1/cmo/doc/([a-z0-9-]{1,64})")
# The scandir-side twin of both slug routes, shared rather than copied so the
# two halves cannot drift: a file the route could never name must not appear in
# the payload as a door either.
_SLUG_NAME = re.compile(r"([a-z0-9-]{1,64})\.md")

# The bare shape, for the one place a slug arrives in a body rather than in a
# path: the thread id an ask follow-up names. The route regexes assert it
# themselves, so this is only for what the router never sees.
_SLUG = re.compile(r"[a-z0-9-]{1,64}")

# The write routes, and the entire exception to "there is no write path".
# Fixed strings rather than a prefix match: the exception is meant to be
# narrow enough to read, and every other POST stays the 405 it always was.
DISMISS_ROUTE = "/v1/cmo/dismiss"
RESTORE_ROUTE = "/v1/cmo/restore"
ASK_ROUTE = "/v1/cmo/ask"
# The read side of the same conversation. Only a GET can match this, so the
# POST route above and this one cannot be confused for each other.
ASK_THREAD_ROUTE = re.compile(r"/v1/cmo/ask/([a-z0-9-]{1,64})")

# The mailbox's five, which are the same shape of exception: each files
# something on disk and, where a machine has to act on it, wakes the worker that
# owns that action. None of them talks to Gmail -- this process has no mail
# credentials to talk with. `send` is the only route in the program whose result
# leaves the house, which is why the address it uses is computed from the
# message being replied to rather than taken from the caller. See
# `Collector.mail_send`.
MAIL_READ_ROUTE = "/v1/mail/read"
MAIL_UNREAD_ROUTE = "/v1/mail/unread"
MAIL_ARCHIVE_ROUTE = "/v1/mail/archive"
MAIL_DRAFT_ROUTE = "/v1/mail/draft"
MAIL_SAVE_DRAFT_ROUTE = "/v1/mail/save-draft"
MAIL_SEND_ROUTE = "/v1/mail/send"
MAIL_POST_ROUTES = (MAIL_READ_ROUTE, MAIL_UNREAD_ROUTE, MAIL_ARCHIVE_ROUTE,
                    MAIL_DRAFT_ROUTE, MAIL_SAVE_DRAFT_ROUTE, MAIL_SEND_ROUTE)

# The messages channel's fourteen, and the widest write surface in the program.
# They are the same shape of exception as the mailbox's -- each files something
# on disk and, where a machine has to act on it, leaves the note that names the
# action -- with one difference worth stating plainly: three of them are written
# by a program on another machine rather than by a person in a browser.
#
# `ingest`, `bridge` and the POST half of `chats` are the Bridge's. It is
# authenticated with the same bearer as everything else and it is trusted
# exactly as far as that: every event it posts is re-validated field by field,
# every key is recomputed from its own GUID, and nothing it says can name a path.
#
# `send` is the only route on this channel whose result leaves the house, which
# is why the conversation it goes to is computed here from the store and never
# taken from the caller. See `Collector.messages_send`.
MESSAGES_INGEST_ROUTE = "/v1/messages/ingest"
MESSAGES_BRIDGE_ROUTE = "/v1/messages/bridge"
MESSAGES_CHATS_ROUTE = "/v1/messages/chats"
MESSAGES_CONFIG_ROUTE = "/v1/messages/config"
MESSAGES_READ_ROUTE = "/v1/messages/read"
MESSAGES_DRAFT_ROUTE = "/v1/messages/draft"
MESSAGES_SAVE_DRAFT_ROUTE = "/v1/messages/save-draft"
MESSAGES_SEND_ROUTE = "/v1/messages/send"
MESSAGES_OUTBOX_ROUTE = "/v1/messages/outbox"
# The Bridge's other pull: what the app has asked for and the Mac has not sent.
# Plural, and one segment shallower than the route that names a single file, so
# no key can be mistaken for it and no `?status=` can be mistaken for a path.
MESSAGES_WANTED_ROUTE = "/v1/messages/attachments"
MESSAGES_SUMMARY_READ_ROUTE = "/v1/messages/summary/read"
MESSAGES_SUMMARY_ARCHIVE_ROUTE = "/v1/messages/summary/archive"
MESSAGES_POST_ROUTES = (
    MESSAGES_INGEST_ROUTE, MESSAGES_BRIDGE_ROUTE, MESSAGES_CHATS_ROUTE,
    MESSAGES_CONFIG_ROUTE, MESSAGES_READ_ROUTE, MESSAGES_DRAFT_ROUTE,
    MESSAGES_SAVE_DRAFT_ROUTE, MESSAGES_SEND_ROUTE,
    MESSAGES_SUMMARY_READ_ROUTE, MESSAGES_SUMMARY_ARCHIVE_ROUTE,
)

# The three with a variable in them. The key and date shapes are asserted here
# so that nothing else in the path can be one, and `Collector.messages_path`
# asserts containment again on top of it -- the same belt and braces as the
# briefing route's date.
#
# `summary/read` and `summary/archive` are fixed strings one segment deeper than
# nothing and could in principle collide with the summary route below; they
# cannot, because a date is four digits and a hyphen and neither word is. They
# are also POSTs and this is a GET, so no ordering rule is needed either way.
MESSAGES_THREAD_ROUTE = re.compile(r"/v1/messages/thread/([a-f0-9]{16})")
MESSAGES_REPORT_ROUTE = re.compile(r"/v1/messages/outbox/([a-f0-9]{16})")
MESSAGES_SUMMARY_ROUTE = re.compile(r"/v1/messages/summary/(\d{4}-\d{2}-\d{2})")

# The bytes. One path, three verbs: the Bridge PUTs it, the app GETs it, and
# the app POSTs `/want` under it to say it would like the Bridge to. Three
# digits of position, on `MAIL_ATTACHMENT_ROUTE`'s argument -- the bound belongs
# in the route rather than in an int() that would happily take sixty digits --
# and the ingest route refuses an event with more than MESSAGES_ATTACHMENTS_MAX
# anyway, so nothing this matches can be a real attachment past twenty.
MESSAGES_ATTACHMENT_ROUTE = re.compile(
    r"/v1/messages/attachment/([a-f0-9]{16})/(\d{1,3})")
MESSAGES_WANT_ROUTE = re.compile(
    r"/v1/messages/attachment/([a-f0-9]{16})/(\d{1,3})/want")

# The two mail read routes. The key shape is asserted here so nothing else in
# the path can be one, and `Collector.mail_path` asserts containment again on
# top of it -- the same belt and braces as the briefing route's date.
# The chat assistant's seven. Five writes and two reads, and four of the five
# are the same shape of exception as everything above: each files something on
# disk and, where a machine has to act on it, wakes the worker that owns that
# action. Nothing here runs a model -- this process starts no subprocess and
# holds no credentials for one; `chat-runner.py` does that under its own path
# unit.
#
# `delete` is the fifth and is not that shape: it is the act itself, because
# there is no worker on the far side of removing a file. It carries its own
# interlock instead -- see `chat_delete` -- and it is a POST like the rest
# rather than a DELETE, because the only thing this server's method dispatch
# knows how to be is read-only or one of these.
#
# `new` is matched as a fixed string and tested BEFORE the thread pattern,
# because `new` is itself a legal slug and would otherwise be read as a thread
# id. A minted id is always a stamped `YYYY-MM-DD-HHMM-xxxx`, so the word can
# never collide with a real one -- but that is an argument about what ids look
# like today, and the ordering is what makes it true regardless.
CHAT_LIST_ROUTE = "/v1/chat"
CHAT_NEW_ROUTE = "/v1/chat/new"
CHAT_THREAD_ROUTE = re.compile(r"/v1/chat/([a-z0-9-]{1,64})")
CHAT_ACTION_ROUTE = re.compile(
    r"/v1/chat/([a-z0-9-]{1,64})/(send|model|stop|delete|archive|effort)")

# Jarvis's ten: four reads and six writes, and every one of the writes is the
# same shape of exception as everything above -- it files something on disk and,
# where a machine has to act on it, wakes the worker that owns that action.
# Nothing here runs a model either; the two runners do that under their own path
# units.
#
# **Almost none of these name what they act on.** `say`, `stop`, `model` and
# `compact` act on today, and today is a fact about the clock rather than an
# argument -- a console that could name the day it was writing into could write
# into yesterday, which is a conversation that has already happened. The two
# routes that do carry an id carry a job's, because jobs are the one thing here
# there can be several of at once.
#
# `days` and `day/<date>` are two routes rather than one with an optional
# segment, so the reads stay fixed strings where they can be. The date is
# fullmatch'd into the path for the briefing route's reason: it is half of a
# filing key, and `Collector.jarvis_day_path` asserts containment again on top
# of it.
JARVIS_TODAY_ROUTE = "/v1/jarvis/today"
JARVIS_DAYS_ROUTE = "/v1/jarvis/days"
JARVIS_JOBS_ROUTE = "/v1/jarvis/jobs"
JARVIS_DAY_ROUTE = re.compile(r"/v1/jarvis/day/(\d{4}-\d{2}-\d{2})")

JARVIS_SAY_ROUTE = "/v1/jarvis/say"
JARVIS_STOP_ROUTE = "/v1/jarvis/stop"
JARVIS_MODEL_ROUTE = "/v1/jarvis/model"
JARVIS_EFFORT_ROUTE = "/v1/jarvis/effort"
JARVIS_COMPACT_ROUTE = "/v1/jarvis/compact"
JARVIS_JOB_ROUTE = "/v1/jarvis/job"
JARVIS_POST_ROUTES = (JARVIS_SAY_ROUTE, JARVIS_STOP_ROUTE, JARVIS_MODEL_ROUTE,
                      JARVIS_EFFORT_ROUTE, JARVIS_COMPACT_ROUTE, JARVIS_JOB_ROUTE)
# The two voice proxies, deliberately NOT in the tuple above: that tuple feeds
# `_jarvis`, whose entire shape is "write the day, answer 204, read it back off
# the poll", and neither of these touches the day record at all -- one answers
# with a body of audio and the other with the fact of a connection. Both are
# exact strings, so no ordering rule is needed between them.
JARVIS_TTS_ROUTE = "/v1/jarvis/tts"
JARVIS_TTS_WARM_ROUTE = "/v1/jarvis/tts/warm"
# Two segments longer than the route above it, so no ordering rule is needed
# between them -- unlike `/v1/chat/new`, which is a legal thread id and has to
# be tested first. The id shape is the minted one rather than a slug, because
# this one names a spool entry another process acts on. See `_JARVIS_JOB_ID`.
JARVIS_JOB_STOP_ROUTE = re.compile(
    r"/v1/jarvis/job/(\d{4}-\d{2}-\d{2}-\d{4}-[0-9a-f]{4})/stop")

MAIL_MESSAGE_ROUTE = re.compile(r"/v1/mail/message/([a-f0-9]{16})")
# Three digits of part number: a message with a thousand attachments is not a
# message, and the bound belongs in the route rather than in an int() that would
# happily accept a number with sixty digits in it.
MAIL_ATTACHMENT_ROUTE = re.compile(r"/v1/mail/attachment/([a-f0-9]{16})/(\d{1,3})")

# A dismissal is four short strings. This leaves room for a title at its full
# length several times over, and reading whatever Content-Length claims is how
# a write path turns into a way to exhaust a Pi's memory from the tailnet.
MAX_BODY_BYTES = 4096
# The ask route's own ceiling. A 2000-character question is up to four bytes
# per character in UTF-8 plus the JSON around it, so the dismissal's cap would
# refuse a long but perfectly ordinary question -- and a body limit that fires
# on valid input is a bug that only shows up on the day it matters.
ASK_BODY_MAX_BYTES = 12288
# The two mail routes that carry a written reply, and only those two: the other
# three carry a key and, at most, a sentence of steering, so they keep the
# dismissal's cap. 64 KB holds MAIL_REPLY_CHARS at four bytes a character with
# room left for the JSON around it.
MAIL_BODY_MAX_BYTES = 65536
# The chat send route's own ceiling, on the same argument the ask route makes:
# CHAT_TEXT_MAX characters at up to four bytes each in UTF-8, plus the JSON
# around it. A cap that fires on valid input is a bug that only shows up on the
# day somebody pastes a real unit file into the box.
CHAT_BODY_MAX_BYTES = 24576
TITLE_MAX = 500
DISMISS_KINDS = ("item", "draft")
# fullmatch'd, like the briefing route's date and for the same reason: the day
# is the second half of a filing key and nothing else in the object is shaped.
DATE_SHAPE = re.compile(r"\d{4}-\d{2}-\d{2}")


def parse_dismissal(doc):
    """Validate one dismissal body. Returns (entry, None) or (None, why).

    Both routes share this. `lane` is accepted and stored on dismiss and
    ignored on restore, because it is a label rather than part of the identity
    -- see `dismissal_matches`. Every rejection names the field, since the only
    caller is a console being written against this by hand.
    """
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"

    kind = doc.get("kind")
    if kind not in DISMISS_KINDS:
        return None, f"kind must be one of {list(DISMISS_KINDS)}"

    title = doc.get("title")
    if not isinstance(title, str) or not title.strip():
        return None, "title must be a non-empty string"
    if len(title) > TITLE_MAX:
        return None, f"title must be at most {TITLE_MAX} characters"

    date = doc.get("date")
    if not isinstance(date, str) or not DATE_SHAPE.fullmatch(date):
        return None, "date must be YYYY-MM-DD"

    lane = doc.get("lane")
    if lane is not None and not isinstance(lane, str):
        return None, "lane must be a string or null"

    # The title is stored exactly as the console sent it, whitespace included:
    # it is matched by equality against itself, and a server that tidied it
    # would leave the console unable to name what it just wrote.
    return {"kind": kind, "title": title, "lane": lane or None, "date": date}, None


def parse_question(doc):
    """Validate one ask body. Returns ((question, thread), None) or (None, why).

    The thread is optional and, when present, is checked for shape only -- that
    it names a thread which exists is `Collector.cmo_ask`'s to answer, because
    only it knows where the threads are and only it can say so without racing
    the runner.

    The question is stripped, unlike a dismissal's title: a title is matched by
    equality against a copy of itself, but a question is prose being handed to
    an agent, and a trailing newline from a textarea is not part of it.
    """
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"

    question = doc.get("question")
    if not isinstance(question, str) or not question.strip():
        return None, "question must be a non-empty string"
    question = question.strip()
    if len(question) > QUESTION_MAX:
        return None, f"question must be at most {QUESTION_MAX} characters"

    thread = doc.get("thread")
    if thread is not None:
        if not isinstance(thread, str):
            return None, "thread must be a string or null"
        if not _SLUG.fullmatch(thread):
            return None, "thread is not a thread id"

    return (question, thread or None), None


def parse_chat_model(doc, required):
    """Pull a model name out of a body. Returns (model, None) or (None, why).

    Shared by `new`, where it is optional and defaults, and by the model route,
    where it is the whole request. A closed set rather than a passthrough: this
    string becomes an argument in the runner's argv, and the narrow place to
    decide which strings are allowed is here.
    """
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"
    model = doc.get("model")
    if model is None and not required:
        return CHAT_MODELS[0], None
    if model not in CHAT_MODELS:
        return None, f"model must be one of {list(CHAT_MODELS)}"
    return model, None


def parse_chat_text(doc):
    """Validate one send body. Returns (text, None) or (None, why).

    Stripped, like a question and unlike a mail reply: this is prose being
    handed to a session, and the trailing newline a textarea leaves behind is
    not part of what he said. Nothing else is touched -- the interior
    whitespace of a pasted log is the paste.
    """
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"
    text = doc.get("text")
    if not isinstance(text, str) or not text.strip():
        return None, "text must be a non-empty string"
    text = text.strip()
    if len(text) > CHAT_TEXT_MAX:
        return None, f"text must be at most {CHAT_TEXT_MAX} characters"
    return text, None


def parse_jarvis_job(doc):
    """Validate one job body. Returns ((text, title), None) or (None, why).

    The instruction shares `parse_chat_text` with everything else a person types
    at this box, ceiling included: the contract names CHAT_TEXT_MAX for this
    route, and a second constant for the same kind of prose would be one edit
    away from disagreeing with the first.

    The title is optional and falls back to the instruction's first line. Not an
    invented field -- it is the call `chat_send` already makes when it names a
    thread by its first message, and the alternative is a card with a blank
    where its name goes because a console forgot one field.
    """
    text, why = parse_chat_text(doc)
    if why:
        return None, why

    title = doc.get("title")
    if title is not None and not isinstance(title, str):
        return None, "title must be a string or null"
    # Collapsed for `mail_line`'s reason: this is drawn as a single row in a
    # transcript, and a newline in it is a hole in the row.
    title = " ".join((title or text).split())[:CHAT_TITLE_CHARS]
    return (text, title), None


def parse_mail_key(doc):
    """Validate a body that names one message. Returns (key, None) or
    (None, why).

    The shape only. That the key names a message which exists is the
    Collector's to answer, because only it knows where the mailbox is -- the
    same split as the ask route's thread id.
    """
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"
    key = doc.get("key")
    if not isinstance(key, str) or not _MAIL_KEY.fullmatch(key):
        return None, "key must be a 16-character message key"
    return key, None


def parse_mail_draft(doc):
    """Validate a draft request. Returns ((key, instructions, force), None) or
    (None, why).

    `force` is what a reader asking for a second draft sends. It is a flag
    rather than a separate route because it changes one decision inside one
    write, and a route per adverb is how a narrow write surface stops being
    narrow.
    """
    key, why = parse_mail_key(doc)
    if why:
        return None, why

    instructions = doc.get("instructions")
    if instructions is not None:
        if not isinstance(instructions, str):
            return None, "instructions must be a string or null"
        instructions = instructions.strip()
        if len(instructions) > MAIL_INSTRUCTIONS_CHARS:
            return None, ("instructions must be at most "
                          f"{MAIL_INSTRUCTIONS_CHARS} characters")

    force = doc.get("force")
    if force is not None and not isinstance(force, bool):
        return None, "force must be a boolean or null"

    return (key, instructions or None, bool(force)), None


def parse_mail_reply(doc):
    """Validate a body that carries written words: save-draft and send. Returns
    ((key, body), None) or (None, why).

    Stored exactly as typed, unlike a question. This text is restored into the
    textarea the reader is still working in, and a server that tidied its
    whitespace would move somebody's cursor between two keystrokes -- and for
    send, the words that went out have to be the words on screen.

    Notice what is *not* in here: no recipient and no subject. Both are computed
    from the message being replied to. See `Collector.mail_send`.
    """
    key, why = parse_mail_key(doc)
    if why:
        return None, why

    body = doc.get("body")
    if not isinstance(body, str) or not body.strip():
        return None, "body must be a non-empty string"
    if len(body) > MAIL_REPLY_CHARS:
        return None, f"body must be at most {MAIL_REPLY_CHARS} characters"

    return (key, body), None


# -- the messages channel's bodies --------------------------------------------
#
# Shape only, and in one place per body rather than inside each route: the
# Collector answers whether the thing named exists, because only it knows where
# the store is. The same split as the mail routes', with one addition -- the
# protocol number, which every Bridge request carries and which is checked
# before anything else in the body is read.


def parse_messages_protocol(doc):
    """The version handshake. Returns (None) when it is fine, or a reason.

    A number this program does not speak is refused rather than best-efforted.
    The alternative is a newer Bridge silently half-working against an older Pi,
    which presents as messages that mostly arrive.
    """
    if not isinstance(doc, dict):
        return "body must be a JSON object"
    if doc.get("protocol") != MESSAGES_PROTOCOL:
        return "protocol"
    return None


def parse_messages_ingest(doc):
    """One batch of message rows. Returns ((events, cursor, backfill), None) or
    (None, why).

    The envelope only. Each event is validated on the way to disk by
    `clean_message_event`, so that one bad row is one counted rejection rather
    than a refused batch: a Bridge streaming a hundred rows after a weekend
    should not lose ninety-nine of them to the hundredth.

    `backfill` marks a page of one conversation's history rather than a piece
    of the live stream. It is optional and defaults to false, so a Bridge that
    predates section 7 posts exactly what it always did.
    """
    why = parse_messages_protocol(doc)
    if why:
        return None, why

    events = doc.get("events")
    if not isinstance(events, list):
        return None, "events must be a list"
    if len(events) > MESSAGES_INGEST_MAX_EVENTS:
        return None, (f"events must hold at most "
                      f"{MESSAGES_INGEST_MAX_EVENTS} entries")

    backfill = doc.get("backfill", False)
    if not isinstance(backfill, bool):
        return None, "backfill must be a boolean"

    cursor = doc.get("cursor")
    # A history post may carry no cursor at all: a Bridge can be reading a
    # conversation's past before the live stream has a present to report.
    # Nothing on that path moves the cursor anyway, so there is nothing to
    # insist on here.
    if backfill and cursor is None:
        return (events, None, True), None
    if isinstance(cursor, bool) or not isinstance(cursor, int) or cursor < 0:
        return None, "cursor must be a non-negative integer"

    return (events, cursor, backfill), None


def parse_messages_bridge(doc):
    """One heartbeat. Returns (heartbeat, None) or (None, why).

    Stored verbatim, so what is checked is that it is storable rather than that
    it is complete: a Bridge that grew a field should not need this program
    redeployed, and a Bridge that lost one should show as degraded rather than
    be refused. The three fields the health rule reads are shape-checked, and
    everything else is carried through as it arrived.
    """
    why = parse_messages_protocol(doc)
    if why:
        return None, why

    for field in ("fda", "automation", "db_ok"):
        value = doc.get(field)
        if value is not None and not isinstance(value, bool):
            return None, f"{field} must be a boolean or null"

    helper = doc.get("helper")
    if helper is not None and not isinstance(helper, dict):
        return None, "helper must be an object or null"

    cursor = doc.get("cursor")
    if cursor is not None and (isinstance(cursor, bool)
                               or not isinstance(cursor, int)):
        return None, "cursor must be an integer or null"

    return doc, None


def parse_messages_chats(doc):
    """The conversation directory. Returns (chats, None) or (None, why).

    Each row is reduced to the fields the picker draws rather than stored as it
    arrived: this list is rendered on the Mac, and a field nothing reads is a
    field nothing bounds.
    """
    why = parse_messages_protocol(doc)
    if why:
        return None, why

    rows = doc.get("chats")
    if not isinstance(rows, list):
        return None, "chats must be a list"
    if len(rows) > MESSAGES_CHATS_MAX:
        return None, f"chats must hold at most {MESSAGES_CHATS_MAX} entries"

    out = []
    for row in rows:
        if not isinstance(row, dict):
            return None, "each chat must be an object"
        guid, why = _messages_str(row, "chat_guid", MESSAGES_GUID_CHARS,
                                  required=True)
        if why:
            return None, why
        key = row.get("chat_key")
        if not isinstance(key, str) or not _MESSAGES_KEY.fullmatch(key):
            return None, "chat_key must be a 16-character chat key"
        if key != messages_key(guid):
            return None, "chat_key does not match its chat_guid"

        fields = {}
        for field, limit in (("chat_identifier", MESSAGES_HANDLE_CHARS),
                             ("name", MESSAGES_NAME_CHARS),
                             ("service", 32),
                             ("last_message_at", 64)):
            value, why = _messages_str(row, field, limit)
            if why:
                return None, why
            fields[field] = value

        participants = row.get("participants")
        participants = participants if isinstance(participants, list) else []
        if len(participants) > MESSAGES_PARTICIPANTS_MAX:
            return None, (f"participants must hold at most "
                          f"{MESSAGES_PARTICIPANTS_MAX} entries")
        for who in participants:
            if not isinstance(who, str) or len(who) > MESSAGES_HANDLE_CHARS:
                return None, "each participant must be a short string"

        out.append({"chat_guid": guid, "chat_key": key,
                    "is_group": bool(row.get("is_group")),
                    "participants": participants, **fields})
    return out, None


def parse_messages_config(doc):
    """The allowlist. Returns (config, None) or (None, why).

    **A deliberate second copy of `msglib.clean_config`.** The pipeline
    validates the same document the same way, and this file does not import it:
    importing would put the whole mail pipeline into the import graph of the
    process that holds the listening port, to save a table of three field types.
    The two are kept honest by a fixture rather than by a shared module, which
    is the same bargain the key hash makes.

    Strict, because this file is the allowlist and the allowlist is a security
    control on both sides of the wire. A half-understood entry is a conversation
    quietly readable or quietly sendable.
    """
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"
    chats = doc.get("chats")
    if not isinstance(chats, dict):
        return None, "chats must be an object keyed by chat_guid"
    if len(chats) > MESSAGES_CHATS_MAX:
        return None, f"chats must hold at most {MESSAGES_CHATS_MAX} entries"

    out = {}
    for guid, entry in chats.items():
        if not isinstance(guid, str) or not guid.strip():
            return None, "every chat key must be a non-empty chat_guid"
        if len(guid) > MESSAGES_GUID_CHARS:
            return None, (f"a chat_guid must be at most "
                          f"{MESSAGES_GUID_CHARS} characters")
        if not isinstance(entry, dict):
            return None, f"the entry for {guid[:40]} must be an object"

        policy = entry.get("send")
        if policy not in MESSAGES_POLICIES:
            return None, (f"send for {guid[:40]} must be one of "
                          f"{list(MESSAGES_POLICIES)}")

        read = entry.get("read")
        if not isinstance(read, bool):
            return None, f"read for {guid[:40]} must be a boolean"

        name = entry.get("name")
        if name is not None and not isinstance(name, str):
            return None, f"name for {guid[:40]} must be a string or null"
        if isinstance(name, str) and len(name) > MESSAGES_NAME_CHARS:
            return None, (f"name for {guid[:40]} must be at most "
                          f"{MESSAGES_NAME_CHARS} characters")

        out[guid] = {"read": read, "send": policy, "name": name or None}

    return {"updated_at": stamp(), "chats": out}, None


def parse_messages_chat(doc):
    """A body that names one conversation. Returns (chat_key, None) or
    (None, why)."""
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"
    chat = doc.get("chat_key")
    if not isinstance(chat, str) or not _MESSAGES_KEY.fullmatch(chat):
        return None, "chat_key must be a 16-character chat key"
    return chat, None


def parse_messages_draft(doc):
    """A draft request. Returns ((chat_key, instructions), None) or
    (None, why)."""
    chat, why = parse_messages_chat(doc)
    if why:
        return None, why
    instructions = doc.get("instructions")
    if instructions is not None:
        if not isinstance(instructions, str):
            return None, "instructions must be a string or null"
        instructions = instructions.strip()
        if len(instructions) > MESSAGES_INSTRUCTIONS_CHARS:
            return None, ("instructions must be at most "
                          f"{MESSAGES_INSTRUCTIONS_CHARS} characters")
    return (chat, instructions or None), None


def parse_messages_body(doc):
    """A body that carries written words: save-draft and send. Returns
    ((chat_key, body), None) or (None, why).

    Stored exactly as typed. This text is restored into the compose box the user
    is still working in, and a server that tidied its whitespace would move
    somebody's cursor between two keystrokes. For send, the words that went out
    have to be the words that were on screen.

    Notice what is *not* in here: no recipient and no conversation GUID. Both
    are computed from the conversation being answered. See
    `Collector.messages_send`.
    """
    chat, why = parse_messages_chat(doc)
    if why:
        return None, why
    body = doc.get("body")
    if not isinstance(body, str) or not body.strip():
        return None, "body must be a non-empty string"
    if len(body) > MESSAGES_SEND_MAX:
        return None, f"body must be at most {MESSAGES_SEND_MAX} characters"
    return (chat, body), None


def parse_messages_report(doc):
    """What the Bridge says happened to one send. Returns (report, None) or
    (None, why).

    Two shapes behind one route, told apart by `status`. `sent` may name what
    Messages.app called the row it created; `failed` carries a reason and,
    optionally, whether trying again could work. Nothing here acts on
    `retry_safe`: it is recorded so a person deciding whether to tap send again
    has the Mac's own opinion in front of him.
    """
    why = parse_messages_protocol(doc)
    if why:
        return None, why

    state = doc.get("status")
    if state not in MESSAGES_REPORT_STATES:
        return None, f"status must be one of {list(MESSAGES_REPORT_STATES)}"

    out = {"status": state}
    if state == "sent":
        # Older Bridges report the SQLite row ID as a JSON integer. Keep
        # its stored and wire form identical to the newer string report.
        row_id = doc.get("message_id")
        if type(row_id) is int and row_id >= 0:
            doc = dict(doc, message_id=str(row_id))
        for field in ("guid", "message_id"):
            value, why = _messages_str(doc, field, MESSAGES_GUID_CHARS)
            if why:
                return None, why
            out[field] = value
        return out, None

    error, why = _messages_str(doc, "error", MESSAGES_ERROR_CHARS, required=True)
    if why:
        return None, why
    disposition, why = _messages_str(doc, "disposition", 64)
    if why:
        return None, why
    retry_safe = doc.get("retry_safe")
    if retry_safe is not None and not isinstance(retry_safe, bool):
        return None, "retry_safe must be a boolean or null"
    out.update({"error": error, "disposition": disposition,
                "retry_safe": retry_safe})
    return out, None


def parse_messages_date(doc):
    """A body that names one local date. Returns (date, None) or (None, why)."""
    if not isinstance(doc, dict):
        return None, "body must be a JSON object"
    date = doc.get("date")
    if not isinstance(date, str) or not DATE_SHAPE.fullmatch(date):
        return None, "date must be YYYY-MM-DD"
    return date, None


STATIC_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".ico": "image/x-icon",
    ".woff2": "font/woff2",
    # The canned voice lines under /canned/. An extension not in this map is a
    # 404 by design, so the shelf's arrival has to be recorded here or every
    # canned fetch dies as a JSON 404 while the manifest beside it serves fine
    # -- which is exactly how it presented.
    ".wav": "audio/wav",
    ".txt": "text/plain; charset=utf-8",
}


def make_handler(collector, token):
    cfg = collector.cfg

    class Handler(http.server.BaseHTTPRequestHandler):
        server_version = USER_AGENT
        protocol_version = "HTTP/1.1"

        # -- plumbing --------------------------------------------------------

        def _headers(self, code, ctype, length, extra=None):
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(length))
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            for k, v in (extra or {}).items():
                self.send_header(k, v)
            self.end_headers()

        def _json(self, code, payload, extra=None):
            body = json.dumps(payload, separators=(",", ":")).encode()
            self._headers(code, "application/json", len(body),
                          {"Cache-Control": "no-store", **(extra or {})})
            self.wfile.write(body)

        def _no_content(self):
            """204, for a write whose result is read back somewhere else.

            Not `_headers`, because that one always writes a Content-Type and a
            Content-Length: a 204 is defined to carry no body at all, and
            announcing the length of a body that cannot exist is the kind of
            header a proxy is entitled to be confused by. The connection stays
            usable without one -- 204 is self-delimiting by status.
            """
            self.send_response(204)
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Referrer-Policy", "no-referrer")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()

        def log_message(self, fmt, *a):
            # The request line only. Never headers, never the cookie -- under
            # systemd this goes straight to journald.
            #
            # And never the ?k= mint token, which the cookie rule above missed:
            # it rides in the URL by construction, so the plain request line
            # persisted a working credential into the journal, where it
            # outlives the browser session and lands in any journal export.
            sys.stderr.write(f"{stamp()}  {self.address_string()}  "
                             f"{redact_secrets(fmt % a)}\n")

        def _read_body(self, limit=MAX_BODY_BYTES):
            """The request body, parsed. Returns (doc, None) or (None, why).

            Capped before a byte is read. An oversized body is refused rather
            than drained, and refusing to drain means this connection can no
            longer be trusted to start at a request line -- so it is closed
            rather than kept alive reading a JSON tail as a verb.

            The cap is per route rather than global: a dismissal is four short
            strings and a question is prose, and one number for both would
            either refuse a real question or let a dismissal carry a novel.
            """
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                self.close_connection = True
                return None, "malformed Content-Length"
            if length <= 0:
                return None, "empty body"
            if length > limit:
                self.close_connection = True
                return None, f"body must be at most {limit} bytes"
            try:
                raw = self.rfile.read(length)
            except OSError:
                self.close_connection = True
                return None, "could not read the body"
            try:
                return json.loads(raw), None
            except ValueError:
                return None, "body is not valid JSON"

        def _feature_control(self, feature, bridge):
            if not self.headers.get("Authorization", "").startswith("Bearer ") or not hmac.compare_digest(
                    self.headers["Authorization"][7:], token):
                self.close_connection = True
                return self._deny()
            doc, error = self._read_body(1024)
            if error or not isinstance(doc, dict):
                return self._json(400, {"error": "Expected a JSON object."})
            control = FeatureControl(feature)
            try:
                if bridge:
                    host, ack = doc.get("host"), doc.get("ack")
                    if (not isinstance(host, str) or not 0 < len(host) <= 255 or
                            (ack is not None and not isinstance(ack, str))):
                        return self._json(400, {"error": "Invalid Bridge status."})
                    state = control.bridge_state(host, ack)
                else:
                    if doc and (set(doc) != {"enabled"} or type(doc["enabled"]) is not bool):
                        return self._json(400, {"error": "Expected {} or a boolean enabled field."})
                    state = control.apply(doc.get("enabled"))
            except (KeyError, TypeError, OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
                message = str(exc) if isinstance(exc, RuntimeError) else "Cannot verify feature jobs. Check the Pi registration and permissions."
                return self._json(503, {"error": message})
            return self._json(200, state)

        def _dispatch(self, handler):
            path = urllib.parse.urlparse(self.path).path.rstrip("/")
            parts = path.split("/")
            name = parts[2] if len(parts) >= 3 and parts[1] == "v1" else ""
            feature = name
            if name == "sources" and len(parts) == 4:
                feature = parts[3]
            if feature not in FEATURES:
                return handler()
            if not self._authorized():
                self.close_connection = True
                return self._deny()
            if self.command == "POST":
                bridge = path == "/v1/messages/bridge-control"
                if path == f"/v1/{feature}/routines" or bridge:
                    return self._feature_control(feature, bridge)
                # A send that already happened can still record its outcome.
                if MESSAGES_REPORT_ROUTE.fullmatch(path):
                    return handler()
            with admit(feature) as allowed:
                if allowed:
                    return handler()
            self.close_connection = True
            return self._json(409, {"error": f"{feature} is paused."})

        def do_GET(self):
            return self._dispatch(self._get)

        def do_POST(self):
            return self._dispatch(self._post)

        def do_PUT(self):
            return self._dispatch(self._put)

        def _post(self):
            """The two curation routes, the ask route, and the mailbox's five.
            Everything else is still read-only.

            Dismissal is the user curating his own view: the archive page
            collects what he has waved off and the agent's next run treats it
            as dead. Nothing is deleted by either route -- restore is one
            click, and the item never leaves the CMO's memory, which is what
            stops it coming back as a discovery.

            The ask route is the one write here that starts something: the
            question lands on disk, a spool entry wakes the runner's path unit,
            and the answer arrives on a later poll. This returns the moment the
            question is filed -- it does not wait for an answer, because the
            answer takes a minute and an HTTP request that holds a connection
            open for one is a request that dies on the first sleeping laptop.

            The mail routes are that same shape, several times over, and one of
            them ends in an email leaving the house. Every one of them returns
            as soon as the file is on disk; a worker with credentials this
            process does not have does the rest.
            """
            path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"

            # The same gate as GET, and before the body is read: an
            # unauthenticated caller does not get to spend anything here.
            if not self._authorized():
                self.close_connection = True
                return self._deny()

            if path == ASK_ROUTE:
                return self._ask()

            # `new` before the thread pattern, because `new` is a legal slug.
            # See the note on CHAT_NEW_ROUTE.
            if path == CHAT_NEW_ROUTE:
                return self._chat_new()

            found = CHAT_ACTION_ROUTE.fullmatch(path)
            if found:
                return self._chat_action(found.group(1), found.group(2))

            if path == JARVIS_TTS_ROUTE:
                return self._jarvis_tts()

            if path == JARVIS_TTS_WARM_ROUTE:
                return self._jarvis_tts_warm()

            if path in JARVIS_POST_ROUTES:
                return self._jarvis(path)

            found = JARVIS_JOB_STOP_ROUTE.fullmatch(path)
            if found:
                ok, why, code = collector.jarvis_job_stop(found.group(1))
                return (self._json(code or 500, {"error": why}) if not ok
                        else self._no_content())

            if path in MAIL_POST_ROUTES:
                return self._mail(path)

            if path in MESSAGES_POST_ROUTES:
                return self._messages(path)

            # The Bridge closing the loop on one send. A regex route rather
            # than a fixed string because it names the record it is answering,
            # and it is tested after the fixed strings above for no reason
            # beyond reading order: no id can spell one of them.
            # The app asking for one attachment the Bridge did not send. Tested
            # before the outbox report below only for reading order: the two
            # patterns cannot both match a path.
            #
            # The only route on this server with no body at all. The URL is the
            # whole of the request -- a key, a position, and the word -- so
            # nothing is read; a body that arrives anyway is drained so the
            # connection can still be trusted to start at a request line.
            found = MESSAGES_WANT_ROUTE.fullmatch(path)
            if found:
                try:
                    length = int(self.headers.get("Content-Length") or 0)
                except ValueError:
                    length = -1
                if length < 0 or length > MESSAGES_BODY_MAX_BYTES:
                    self.close_connection = True
                    return self._json(400, {"error": "the want route takes "
                                                     "no body"})
                if length:
                    self.rfile.read(length)
                ok, why, code = collector.messages_attachment_want(
                    found.group(1), int(found.group(2)))
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            found = MESSAGES_REPORT_ROUTE.fullmatch(path)
            if found:
                doc, why = self._read_body(MESSAGES_BODY_MAX_BYTES)
                if why:
                    return self._json(400, {"error": why})
                report, why = parse_messages_report(doc)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.messages_outbox_report(
                    found.group(1), report)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            if path not in (DISMISS_ROUTE, RESTORE_ROUTE):
                self.close_connection = True
                return self._json(405, {"error": "read-only server"})

            doc, why = self._read_body()
            if why:
                return self._json(400, {"error": why})
            entry, why = parse_dismissal(doc)
            if why:
                return self._json(400, {"error": why})

            act = (collector.cmo_dismiss if path == DISMISS_ROUTE
                   else collector.cmo_restore)
            count, why = act(entry)
            if count is None:
                # The request was fine and the disk was not. Named as a server
                # fault so the console can say FAILED rather than silently
                # keeping an optimistic state the file never took.
                return self._json(500, {"error": why})
            return self._json(200, {"ok": True, "dismissed": count})

        def _ask(self):
            """POST /v1/cmo/ask -- file one question, answer later.

            The id comes back because it is the thread the console will poll
            and the thread a follow-up names. Nothing else does: the question
            is already in the caller's hand, and the answer does not exist yet.
            """
            doc, why = self._read_body(ASK_BODY_MAX_BYTES)
            if why:
                return self._json(400, {"error": why})
            parsed, why = parse_question(doc)
            if why:
                return self._json(400, {"error": why})

            question, thread = parsed
            tid, why, code = collector.cmo_ask(question, thread)
            if tid is None:
                return self._json(code or 500, {"error": why})
            return self._json(200, {"ok": True, "id": tid})

        def _chat_new(self):
            """POST /v1/chat/new -- start an empty conversation.

            The id comes back for `_ask`'s reason: it is the thread the console
            routes to and polls, and it did not exist a moment ago, so there is
            no other way for the caller to learn what it is called. Nothing
            else does -- the conversation has no turns in it yet.

            An empty body is a valid request here, unlike everywhere else on
            this server: the only field is optional. So the body is read only
            when there is one, and a caller that sends nothing gets the default
            model rather than "empty body".

            **Tested as a number, not as a present header.** Both http.client
            and every browser send `Content-Length: 0` on a POST with no body,
            and `"0"` is a true string -- so the presence test that reads
            naturally here would send an empty body to `_read_body`, which
            correctly refuses it, and the no-body call this route exists to
            allow would 400. A malformed length falls through to `_read_body`
            on purpose: it owns that error message and the connection handling
            that goes with it.
            """
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            doc = {}
            if length != 0:
                doc, why = self._read_body(CHAT_BODY_MAX_BYTES)
                if why:
                    return self._json(400, {"error": why})
            model, why = parse_chat_model(doc, required=False)
            if why:
                return self._json(400, {"error": why})

            tid, why, code = collector.chat_new(model)
            if tid is None:
                return self._json(code or 500, {"error": why})
            return self._json(200, {"ok": True, "id": tid})

        def _chat_action(self, tid, verb):
            """The five routes that act on one existing conversation.

            All five answer 204 rather than a body. There is nothing to say:
            the console already holds the text it typed, and everything that
            happens next -- the runner picking the turn up, the answer
            streaming in, the stop taking effect -- is read back off the thread
            route, which is the one source of truth for what the thread
            contains. A body here would be a second one. `delete` answers the
            same way for the harder version of that argument: its thread route
            is a 404 now, and the list the console re-reads is the record of
            what is left.

            The Collector answers each with its own status code, because "no
            such thread", "already mid-answer" and "the disk refused" are three
            different screens and only it can tell them apart.

            The two verbs with no body are taken first, and taken before
            `_read_body`: a POST with no `Content-Length` is the ordinary shape
            of both, and reading a body that was never sent is a wait on a
            socket that has nothing more to give.

            `archive` reads its own body rather than sharing the read below it,
            because it is the one verb here that is not about the turn: the two
            underneath dispatch on what a turn should contain, and folding a
            flag on the side into that branch would put an unrelated third
            meaning on the same parse.
            """
            if verb == "stop":
                ok, why, code = collector.chat_stop(tid)
                return (self._json(code or 500, {"error": why}) if not ok
                        else self._no_content())

            if verb == "delete":
                ok, why, code = collector.chat_delete(tid)
                return (self._json(code or 500, {"error": why}) if not ok
                        else self._no_content())

            if verb == "archive":
                doc, why = self._read_body(CHAT_BODY_MAX_BYTES)
                if why:
                    return self._json(400, {"error": why})
                archived = doc.get("archived")
                if not isinstance(archived, bool):
                    return self._json(
                        400, {"error": "archived must be true or false"})
                ok, why, code = collector.chat_set_archived(tid, archived)
                return (self._json(code or 500, {"error": why}) if not ok
                        else self._no_content())

            doc, why = self._read_body(CHAT_BODY_MAX_BYTES)
            if why:
                return self._json(400, {"error": why})

            if verb == "model":
                model, why = parse_chat_model(doc, required=True)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.chat_set_model(tid, model)
            elif verb == "effort":
                effort = doc.get("effort")
                if effort not in JARVIS_EFFORTS:
                    return self._json(400, {
                        "error": "effort must be one of "
                                 + ", ".join(JARVIS_EFFORTS)})
                ok, why, code = collector.chat_set_effort(tid, effort)
            else:
                text, why = parse_chat_text(doc)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.chat_send(tid, text)

            if not ok:
                return self._json(code or 500, {"error": why})
            return self._no_content()

        def _jarvis(self, path):
            """The five write routes that act on today, grouped by what their
            body carries.

            All five answer 204, and there is nothing to say: the console holds
            the text it typed, and the turn appearing, the answer streaming, the
            compaction landing and the job starting are all read back off the
            day route, which is the one source of truth for what today contains.
            A body here would be a second one. `job` answers the same way even
            though it mints an id, unlike `/v1/chat/new` which returns one --
            because the id names nothing the console can fetch on its own, and
            the card carrying it is already in the transcript it is about to
            poll.

            `stop` and `compact` are taken first and taken before `_read_body`,
            for `_chat_action`'s reason: a POST with no `Content-Length` is the
            ordinary shape of both, and reading a body that was never sent is a
            wait on a socket with nothing left to give.

            The Collector answers each with its own status code, because "no day
            yet", "a turn is in flight" and "the disk refused" are three
            different screens and only it can tell them apart.
            """
            if path == JARVIS_STOP_ROUTE:
                ok, why, code = collector.jarvis_stop()
                return (self._json(code or 500, {"error": why}) if not ok
                        else self._no_content())

            if path == JARVIS_COMPACT_ROUTE:
                ok, why, code = collector.jarvis_compact()
                return (self._json(code or 500, {"error": why}) if not ok
                        else self._no_content())

            # The chat send route's ceiling, because these carry the same kind
            # of prose under the same CHAT_TEXT_MAX.
            doc, why = self._read_body(CHAT_BODY_MAX_BYTES)
            if why:
                return self._json(400, {"error": why})

            if path == JARVIS_MODEL_ROUTE:
                model, why = parse_chat_model(doc, required=True)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.jarvis_set_model(model)
            elif path == JARVIS_EFFORT_ROUTE:
                effort = doc.get("effort")
                # Named in the error rather than left to be guessed. The CLI
                # would accept anything and quietly fall back; this will not.
                if effort not in JARVIS_EFFORTS:
                    return self._json(400, {
                        "error": "effort must be one of "
                                 + ", ".join(JARVIS_EFFORTS)})
                ok, why, code = collector.jarvis_set_effort(effort)
            elif path == JARVIS_SAY_ROUTE:
                text, why = parse_chat_text(doc)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.jarvis_say(text)
            else:
                parsed, why = parse_jarvis_job(doc)
                if why:
                    return self._json(400, {"error": why})
                text, title = parsed
                ok, why, code = collector.jarvis_job(text, title)

            if not ok:
                return self._json(code or 500, {"error": why})
            return self._no_content()

        def _jarvis_tts(self):
            """POST /v1/jarvis/tts -- one sentence in, one WAV back.

            The one POST on this server that answers with a body of bytes,
            because the body IS the result: unlike every write above, there
            is no record to read this back from -- the audio exists only in
            this answer -- so the 204-and-poll shape has nothing to offer.
            Sent no-store like the camera frame: an <audio> pipeline that got
            yesterday's WAV out of a cache would speak with great confidence
            and no relation to the turn on screen.

            The text takes the same parse and the same cap as everything a
            person types at this assistant: it is the same prose, one
            sentence at a time, and the Mac holds the same 4000 at its own
            door -- so a body this route accepts is a body the Mac accepts,
            and the 400 for an oversized one is issued here, before a byte
            crosses the tailnet.
            """
            doc, why = self._read_body(CHAT_BODY_MAX_BYTES)
            if why:
                return self._json(400, {"error": why})
            text, why = parse_chat_text(doc)
            if why:
                return self._json(400, {"error": why})

            # A sentence with a pre-rendered clip never crosses the tailnet:
            # the canned set (see `jarvis_load_canned`) answers from memory,
            # ahead of the "is tts configured" check on purpose -- these
            # phrases speak even when the Mac is asleep or unconfigured,
            # which is exactly when a spoken "I'm afraid something has gone
            # wrong" earns its keep.
            canned = collector.jarvis_canned.get(jarvis_canned_key(text))
            if canned is not None:
                self._headers(200, "audio/wav", len(canned),
                              {"Cache-Control": "no-store"})
                return self.wfile.write(canned)

            body, why, code = collector.jarvis_tts(text)
            if body is None:
                return self._json(code or 500, {"error": why})
            self._headers(200, "audio/wav", len(body),
                          {"Cache-Control": "no-store"})
            return self.wfile.write(body)

        def _jarvis_tts_warm(self):
            """POST /v1/jarvis/tts/warm -- touch the Mac's port, say only
            whether it was there.

            No body is read, and none is ever sent: a POST with no
            Content-Length is this route's ordinary shape, for `stop` and
            `compact`'s reason -- reading a body that was never sent is a
            wait on a socket with nothing left to give. The rest of the
            argument, including why the answer barely matters, lives on
            `Collector.jarvis_tts_warm`.
            """
            ok, why, code = collector.jarvis_tts_warm()
            return (self._json(code or 500, {"error": why}) if not ok
                    else self._no_content())

        def _mail(self, path):
            """The five mail write routes, grouped by what their body carries.

            Three of them name a message and nothing else; two of them carry a
            written reply and so read against the larger cap. The Collector
            answers each with its own status code, because "no such message" and
            "the disk refused" are drawn differently and only it can tell them
            apart.
            """
            if path in (MAIL_READ_ROUTE, MAIL_UNREAD_ROUTE, MAIL_ARCHIVE_ROUTE):
                doc, why = self._read_body()
                if why:
                    return self._json(400, {"error": why})
                key, why = parse_mail_key(doc)
                if why:
                    return self._json(400, {"error": why})
                verb = {MAIL_READ_ROUTE: "read", MAIL_UNREAD_ROUTE: "unread",
                        MAIL_ARCHIVE_ROUTE: "archive"}[path]
                ok, why, code = collector.mail_action(verb, key)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            if path == MAIL_DRAFT_ROUTE:
                doc, why = self._read_body()
                if why:
                    return self._json(400, {"error": why})
                parsed, why = parse_mail_draft(doc)
                if why:
                    return self._json(400, {"error": why})
                key, instructions, force = parsed
                status, why, code = collector.mail_draft(key, instructions, force)
                if status is None:
                    return self._json(code or 500, {"error": why})
                # The status comes back because "queued" and "you already have
                # one" are the same success to this server and two different
                # screens in the console: one starts polling, the other reads.
                return self._json(200, {"ok": True, "status": status})

            doc, why = self._read_body(MAIL_BODY_MAX_BYTES)
            if why:
                return self._json(400, {"error": why})
            parsed, why = parse_mail_reply(doc)
            if why:
                return self._json(400, {"error": why})
            key, body = parsed

            if path == MAIL_SAVE_DRAFT_ROUTE:
                ok, why, code = collector.mail_save_draft(key, body)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            # The send. The id comes back because it is the outbox record the
            # console polls for the turn to sent or error; the recipient does
            # not, because the console never chose it and reads it back off the
            # record with everything else.
            mid, why, code = collector.mail_send(key, body)
            if mid is None:
                return self._json(code or 500, {"error": why})
            return self._json(200, {"ok": True, "id": mid})

        def _messages(self, path):
            """The messages channel's ten POST routes, grouped by what their
            body carries.

            Three of them are the Bridge's and carry a protocol number: an
            ingest batch, a heartbeat, and the conversation directory. Seven are
            the app's: the allowlist, a read mark, a draft request, a saved
            draft, a send, and the two summary flags. The Collector answers each
            with its own status code, because "no such conversation", "sending
            is off here" and "the disk refused" are three different screens and
            only it can tell them apart.

            An unknown `protocol` comes back as 400 `{"error": "protocol"}`
            exactly, and that string is load-bearing: it is the one error the
            Bridge is expected to recognise and stop on rather than retry.
            """
            if path == MESSAGES_INGEST_ROUTE:
                doc, why = self._read_body(MESSAGES_INGEST_MAX_BYTES)
                if why:
                    return self._json(400, {"error": why})
                parsed, why = parse_messages_ingest(doc)
                if why:
                    return self._json(400, {"error": why})
                events, cursor, backfill = parsed
                reply, why, code = collector.messages_ingest(
                    {"events": events, "cursor": cursor,
                     "backfill": backfill})
                if reply is None:
                    return self._json(code or 500, {"error": why})
                return self._json(200, reply)

            doc, why = self._read_body(MESSAGES_BODY_MAX_BYTES)
            if why:
                return self._json(400, {"error": why})

            if path == MESSAGES_BRIDGE_ROUTE:
                heartbeat, why = parse_messages_bridge(doc)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.messages_bridge(heartbeat)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            if path == MESSAGES_CHATS_ROUTE:
                chats, why = parse_messages_chats(doc)
                if why:
                    return self._json(400, {"error": why})
                count, why, code = collector.messages_chats_put(chats)
                if count is None:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True, "count": count})

            if path == MESSAGES_CONFIG_ROUTE:
                config, why = parse_messages_config(doc)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.messages_config_put(config)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            if path in (MESSAGES_SUMMARY_READ_ROUTE,
                        MESSAGES_SUMMARY_ARCHIVE_ROUTE):
                date, why = parse_messages_date(doc)
                if why:
                    return self._json(400, {"error": why})
                field = ("read" if path == MESSAGES_SUMMARY_READ_ROUTE
                         else "archived")
                ok, why, code = collector.messages_summary_flag(date, field)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            if path == MESSAGES_READ_ROUTE:
                chat, why = parse_messages_chat(doc)
                if why:
                    return self._json(400, {"error": why})
                ok, why, code = collector.messages_read(chat)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            if path == MESSAGES_DRAFT_ROUTE:
                parsed, why = parse_messages_draft(doc)
                if why:
                    return self._json(400, {"error": why})
                chat, instructions = parsed
                status, why, code = collector.messages_draft(chat, instructions)
                if status is None:
                    return self._json(code or 500, {"error": why})
                # The status comes back because the app starts polling on it:
                # a draft that is `pending` is a spinner, and the route that
                # filed it is the only thing that knows it was filed.
                return self._json(200, {"ok": True, "status": status})

            parsed, why = parse_messages_body(doc)
            if why:
                return self._json(400, {"error": why})
            chat, body = parsed

            if path == MESSAGES_SAVE_DRAFT_ROUTE:
                ok, why, code = collector.messages_save_draft(chat, body)
                if not ok:
                    return self._json(code or 500, {"error": why})
                return self._json(200, {"ok": True})

            # The send. The id comes back because it is the record the app polls
            # for the turn to sent or failed; the conversation GUID does not,
            # because the app never chose it.
            request_id = doc.get("request_id")
            if "request_id" in doc and request_id is None:
                return self._json(400, {"error": "request_id must be a lowercase UUID"})
            mid, why, code = collector.messages_send(chat, body, request_id)
            if mid is None:
                return self._json(code or 500, {"error": why})
            receipt = {"ok": True, "id": mid}
            if request_id is not None:
                receipt["request_id"] = request_id
            return self._json(200, receipt)

        def _refuse(self):
            self._json(405, {"error": "read-only server"})

        def _refuse_unread(self):
            """405 for a verb whose body was never read.

            The connection cannot be trusted to start at a request line after
            this -- whatever the caller was sending is still in the socket --
            so it is closed rather than kept alive reading a JSON tail as a
            verb. `_read_body`'s argument, for the one verb that reaches here
            before any body has been touched.
            """
            self.close_connection = True
            self._json(405, {"error": "read-only server"})

        do_DELETE = do_PATCH = _refuse

        # -- the one write that is not JSON ----------------------------------

        def _put(self):
            """The Bridge handing over one attachment's bytes, and nothing else.

            Every other write on this server is a small JSON document. This one
            is a file, and the shape of the route follows from that: what it is
            arrives in headers rather than around the body, the body is
            streamed to disk rather than parsed, and the cap is checked against
            `Content-Length` before a byte is read.
            """
            path = urllib.parse.urlparse(self.path).path.rstrip("/") or "/"

            if not self._authorized():
                self.close_connection = True
                return self._deny()

            found = MESSAGES_ATTACHMENT_ROUTE.fullmatch(path)
            if not found:
                return self._refuse_unread()
            return self._messages_attachment_put(found.group(1),
                                                 int(found.group(2)))

        def _messages_attachment_put(self, key, n):
            """PUT /v1/messages/attachment/<key>/<n> -- one file, uploaded.

            The order here is the whole of the memory argument. The protocol
            number, the length and the ceiling are checked first, so a
            twenty-six megabyte body is refused for the price of its headers.
            The message is looked up second, so a key this store has never held
            costs nothing either. Only then is the body read, and it is read a
            chunk at a time into a file beside where it will live, with the
            digest computed on the way past -- the bytes are never in this
            process twice and never in it whole.

            A refusal that skips the body leaves the connection unusable, so
            every one of them closes it. That is the same rule `_read_body`
            keeps and for the same reason: what the caller was sending is still
            in the socket, and the next thing read off it would be read as a
            request line.
            """
            # Section 2 asks every Bridge request to name the protocol it
            # speaks. There is nowhere in this body to put it, so it rides in a
            # header, and the error string is the same one the JSON routes
            # answer with -- it is the one the Bridge stops on rather than
            # retries.
            spoken = self.headers.get("X-Charon-Protocol")
            if spoken is not None and spoken.strip() != str(MESSAGES_PROTOCOL):
                self.close_connection = True
                return self._json(400, {"error": "protocol"})

            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                self.close_connection = True
                return self._json(400, {"error": "malformed Content-Length"})
            if length <= 0:
                self.close_connection = True
                return self._json(400, {"error": "empty body"})
            if length > MESSAGES_ATTACHMENT_MAX_BYTES:
                self.close_connection = True
                return self._json(413, {
                    "error": f"an attachment must be at most "
                             f"{MESSAGES_ATTACHMENT_MAX_BYTES} bytes"})

            staged, why, code = collector.messages_attachment_staging(key, n)
            if staged is None:
                self.close_connection = True
                return self._json(code or 500, {"error": why})

            size, digest, why = self._drain_to(staged, length)
            if why:
                try:
                    os.remove(staged)
                except OSError:
                    pass
                self.close_connection = True
                return self._json(400, {"error": why})

            reply, why, code = collector.messages_attachment_store(
                key, n, staged, size, digest,
                self.headers.get("Content-Type"),
                self.headers.get("X-Charon-Filename"),
                (self.headers.get("X-Charon-SHA256") or "").strip().lower())
            if reply is None:
                return self._json(code or 500, {"error": why})
            return self._json(200, reply)

        def _drain_to(self, path, length):
            """The request body, written to a file. (bytes, sha256, None) or
            (None, None, why).

            A chunk at a time, hashed as it goes, so the digest and the file
            are the same read of the same bytes rather than two. Twenty-five
            megabytes goes past in two hundred and fifty-six kilobyte pieces
            and none of it is held.

            A body that ends early is an error rather than a short file. The
            length was declared by the caller and this loop trusts it exactly
            as far as the ceiling above already did: it will not read past it,
            and it will not pretend a truncated upload is a whole one.
            """
            digest = hashlib.sha256()
            read = 0
            try:
                with open(path, "wb") as handle:
                    while read < length:
                        chunk = self.rfile.read(
                            min(MESSAGES_ATTACHMENT_CHUNK, length - read))
                        if not chunk:
                            return None, None, "the body ended early"
                        digest.update(chunk)
                        handle.write(chunk)
                        read += len(chunk)
            except OSError:
                return None, None, "could not read the body"
            return read, digest.hexdigest(), None

        # -- auth ------------------------------------------------------------

        def _authorized(self):
            header = self.headers.get("Authorization", "")
            if header.startswith("Bearer "):
                if hmac.compare_digest(header[7:], token):
                    return True
            # Browsers cannot attach a bearer to an <img> or a stylesheet, so
            # a same-origin HttpOnly cookie carries it instead.
            raw = self.headers.get("Cookie", "")
            for part in raw.split(";"):
                name, _, value = part.strip().partition("=")
                if name == COOKIE and hmac.compare_digest(value, token):
                    return True
            return False

        def _deny(self):
            self._json(401, {"error": "unauthorized"},
                       {"WWW-Authenticate": 'Bearer realm="halftone"'})

        # -- routes ----------------------------------------------------------

        def _get(self):
            parsed = urllib.parse.urlparse(self.path)
            path = parsed.path.rstrip("/") or "/"
            query = urllib.parse.parse_qs(parsed.query)

            if path == "/health":
                # Unauthenticated and deliberately empty. No version, no
                # hostname, no source list -- nothing to pivot on.
                return self._json(200, {"ok": True})

            # Mint the cookie from a one-time link, then redirect so the token
            # leaves the address bar (and the browser history, and any Referer).
            key = (query.get("k") or [None])[0]
            if key and hmac.compare_digest(key, token):
                secure = "; Secure" if cfg.get("https") else ""
                self.send_response(302)
                self.send_header("Location", "/")
                self.send_header(
                    "Set-Cookie",
                    f"{COOKIE}={token}; HttpOnly; SameSite=Strict; Path=/; "
                    f"Max-Age=2592000{secure}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

            if not self._authorized():
                return self._deny()

            if path == "/v1/telemetry":
                return self._json(200, collector.telemetry())

            if path.startswith("/v1/sources/"):
                name = path.rsplit("/", 1)[-1]
                src = collector.sources.get(name)
                if not src:
                    return self._json(404, {"error": f"no source {name!r}"})
                return self._json(200, src.snapshot())

            if path in ("/v1/camera/latest.jpg", "/v1/camera/latest"):
                body, err = collector.frame()
                if body is None:
                    return self._json(503, {"error": err or "no frame"})
                self._headers(200, "image/jpeg", len(body),
                              {"Cache-Control": "no-store", "Pragma": "no-cache"})
                return self.wfile.write(body)

            # The markdown itself, not a rendering of it: the console links out
            # to a day's briefing and the browser is a perfectly good reader.
            # Hyphenated in the URL and underscored as a source id, because the
            # id is a JSON key and the path is a path.
            found = BRIEFING_ROUTE.fullmatch(path)
            if found:
                body, err = collector.briefing(found.group(1))
                if body is None:
                    return self._json(404, {"error": err})
                self._headers(200, "text/plain; charset=utf-8", len(body),
                              {"Cache-Control": "no-store"})
                return self.wfile.write(body)

            # A watchlist company's dossier, same treatment as a briefing:
            # the file is the answer, the console renders it.
            found = DOSSIER_ROUTE.fullmatch(path)
            if found:
                body, err = collector.dossier(found.group(1))
                if body is None:
                    return self._json(404, {"error": err})
                self._headers(200, "text/plain; charset=utf-8", len(body),
                              {"Cache-Control": "no-store"})
                return self.wfile.write(body)

            # One of the operator's reference documents, the third file route
            # and the same treatment again.
            found = DOC_ROUTE.fullmatch(path)
            if found:
                body, err = collector.doc(found.group(1))
                if body is None:
                    return self._json(404, {"error": err})
                self._headers(200, "text/plain; charset=utf-8", len(body),
                              {"Cache-Control": "no-store"})
                return self.wfile.write(body)

            # One ask thread, whole. The fourth file route, and the only one
            # serving JSON rather than markdown -- so it is typed as JSON and
            # sent no-store, because a thread being answered right now changes
            # under the reader and a cached copy of it is a stale answer.
            found = ASK_THREAD_ROUTE.fullmatch(path)
            if found:
                body, err = collector.ask_thread(found.group(1))
                if body is None:
                    return self._json(404, {"error": err})
                self._headers(200, "application/json", len(body),
                              {"Cache-Control": "no-store"})
                return self.wfile.write(body)

            # Every conversation, as a list of doors. Not part of the telemetry
            # payload and deliberately so -- see the `chat` block in DEFAULTS:
            # a conversation is interactive, the tab asks for what it is
            # looking at, and nothing here is polled on the collector's own
            # clock. no-store for the thread route's reason, one level up: the
            # list changes while the reader is looking at it.
            if path == CHAT_LIST_ROUTE:
                return self._json(200, {"threads": collector.chat_list()})

            # One conversation, whole, plus whether the runner still owes it a
            # turn. The sixth file route and the second serving JSON -- and the
            # one route in this program that builds its answer rather than
            # forwarding a file, because `queued` lives in the filesystem
            # rather than in the record. See `Collector.chat_thread`.
            found = CHAT_THREAD_ROUTE.fullmatch(path)
            if found:
                doc, err, code = collector.chat_thread(found.group(1))
                if doc is None:
                    return self._json(code or 404, {"error": err})
                return self._json(200, doc)

            # Today's conversation, minted on the first look at it. Not part of
            # the telemetry payload, for the reason the chat routes are not:
            # this is interactive, the tab asks for what it is looking at on its
            # own cadence, and a conversation arriving once a minute inside a
            # document about disk temperature would be a second copy of the same
            # state going stale on somebody else's clock. no-store like the
            # thread route and for the same reason -- it changes under the
            # reader while he watches it.
            if path == JARVIS_TODAY_ROUTE:
                doc, err, code = collector.jarvis_today()
                if doc is None:
                    return self._json(code or 500, {"error": err})
                return self._json(200, doc)

            # The days, as a list of doors, and the jobs beside them. Two lists
            # rather than one payload with both in it: the console draws them on
            # different pages at different moments, and a job list arriving with
            # every read of the history would be sixty records nobody asked for.
            if path == JARVIS_DAYS_ROUTE:
                return self._json(200, {"days": collector.jarvis_days()})

            if path == JARVIS_JOBS_ROUTE:
                return self._json(200, {"jobs": collector.jarvis_jobs()})

            # One past day, whole. 404 rather than an empty record when there is
            # none, unlike the today route above -- see `Collector.jarvis_day`.
            found = JARVIS_DAY_ROUTE.fullmatch(path)
            if found:
                doc, err, code = collector.jarvis_day(found.group(1))
                if doc is None:
                    return self._json(code or 404, {"error": err})
                return self._json(200, doc)

            # One message, whole: the header record, the extracted body, the
            # triage, both drafts and its outbox records. The fifth file route
            # and the first that merges rather than serves -- see
            # `Collector.mail_message` -- and no-store like the thread, because
            # a message being triaged or replied to changes under the reader.
            found = MAIL_MESSAGE_ROUTE.fullmatch(path)
            if found:
                doc, err = collector.mail_message(found.group(1))
                if doc is None:
                    return self._json(404, {"error": err})
                return self._json(200, doc)

            # One attachment out of the raw message. Always a download, never a
            # rendering: the bytes belong to whoever sent the mail, and this
            # server shares an origin with the dashboard.
            found = MAIL_ATTACHMENT_ROUTE.fullmatch(path)
            if found:
                body, name, ctype, err = collector.mail_attachment(
                    found.group(1), int(found.group(2)))
                if body is None:
                    return self._json(404, {"error": err})
                self._headers(200, ctype, len(body), {
                    "Cache-Control": "no-store",
                    # The filename is rebuilt from a safe alphabet upstream, so
                    # nothing here can end the parameter early or start a
                    # second header. See `mail_filename`.
                    "Content-Disposition": f'attachment; filename="{name}"',
                })
                return self.wfile.write(body)

            # The messages channel's five reads. Every one of them is
            # no-store for the mail message route's reason, one level up: a
            # conversation being triaged, drafted or replied to changes under
            # the reader while he is looking at it, and a cached copy of it is
            # a stale answer rather than a fast one.
            #
            # The allowlist and the conversation directory are two routes
            # rather than one: the directory is whatever the phone currently
            # has and the allowlist is what the user decided about it, and the
            # Bridge reads the first without ever needing the second.
            if path == MESSAGES_CONFIG_ROUTE:
                return self._json(200, collector.messages_config_get())

            if path == MESSAGES_CHATS_ROUTE:
                return self._json(200, collector.messages_chats_get())

            # The Bridge's pull. `status` is accepted and only one value is
            # servable: a queue is the only thing here that is a queue, and a
            # route that quietly served everything when asked for `sent` would
            # be a full audit trail arriving where twenty records were expected.
            if path == MESSAGES_OUTBOX_ROUTE:
                wanted = (query.get("status") or ["queued"])[0]
                if wanted != "queued":
                    return self._json(400, {"error": "status must be queued"})
                return self._json(200,
                                  {"items": collector.messages_outbox_queued()})

            # The Bridge's other pull, and the same shape of answer: `status`
            # is accepted, one value is servable, and anything else is a 400
            # rather than a list that means something the caller did not ask
            # for. What comes back is a join the Mac cannot do for itself --
            # the want plus enough of the row to find the file again.
            if path == MESSAGES_WANTED_ROUTE:
                asked = (query.get("status") or ["wanted"])[0]
                if asked != "wanted":
                    return self._json(400, {"error": "status must be wanted"})
                return self._json(
                    200, {"items": collector.messages_attachments_wanted()})

            # One attachment, as bytes. The mailbox's route one channel over,
            # with one deliberate difference: this one may be cached, privately
            # and for a day. Everything else on this channel is a document that
            # changes under the reader, and the bytes under a key and a
            # position are a file somebody sent once that cannot.
            #
            # Streamed rather than read whole. A photograph is a megabyte and a
            # video is twenty-five, and a Pi has eight gigabytes to run
            # everything else in as well.
            found = MESSAGES_ATTACHMENT_ROUTE.fullmatch(path)
            if found:
                where, size, name, ctype, err = collector.messages_attachment_open(
                    found.group(1), int(found.group(2)))
                if where is None:
                    return self._json(404, {"error": err})
                try:
                    handle = open(where, "rb")
                except OSError:
                    return self._json(404, {"error": "the attachment could not "
                                                     "be read"})
                with handle:
                    self._headers(200, ctype, size, {
                        "Cache-Control": "private, max-age=86400",
                        # Rebuilt from a safe alphabet upstream, so nothing
                        # here can end the parameter early or start a second
                        # header. See `messages_attachment_name`.
                        "Content-Disposition": f'attachment; filename="{name}"',
                    })
                    while True:
                        chunk = handle.read(MESSAGES_ATTACHMENT_CHUNK)
                        if not chunk:
                            break
                        self.wfile.write(chunk)
                return

            # One conversation, whole, and the only route on this channel that
            # carries text. `limit` and `before` page it; both are clamped here
            # rather than trusted, because they arrive in a URL.
            found = MESSAGES_THREAD_ROUTE.fullmatch(path)
            if found:
                try:
                    limit = int((query.get("limit")
                                 or [MESSAGES_THREAD_DEFAULT])[0])
                except ValueError:
                    return self._json(400, {"error": "limit must be a number"})
                limit = max(1, min(MESSAGES_THREAD_MAX, limit))
                before = (query.get("before") or [None])[0]
                if before is not None and not _MESSAGES_KEY.fullmatch(before):
                    return self._json(
                        400, {"error": "before must be a 16-character key"})
                doc, why, code = collector.messages_thread(
                    found.group(1), limit, before)
                if doc is None:
                    return self._json(code or 404, {"error": why})
                return self._json(200, doc)

            # One day's read, as the worker wrote it.
            found = MESSAGES_SUMMARY_ROUTE.fullmatch(path)
            if found:
                doc, why = collector.messages_summary(found.group(1))
                if doc is None:
                    return self._json(404, {"error": why})
                return self._json(200, doc)

            return self._static(path)

        # -- static ----------------------------------------------------------

        def _static(self, path):
            """Serve the built dashboard.

            Hand-written rather than SimpleHTTPRequestHandler, which serves
            directory listings and has a long history of path-traversal bugs.
            Every resolved path is asserted to be inside the root.
            """
            root = cfg.get("dashboard_dir")
            if not root or not os.path.isdir(root):
                return self._json(404, {
                    "error": "not found",
                    "hint": "no dashboard build here yet; the API is unaffected",
                })

            rel = path.lstrip("/") or "index.html"
            candidate = os.path.realpath(os.path.join(root, rel))
            root_real = os.path.realpath(root)
            if not candidate.startswith(root_real + os.sep) and candidate != root_real:
                return self._json(404, {"error": "not found"})
            if os.path.isdir(candidate):
                candidate = os.path.join(candidate, "index.html")
            if not os.path.isfile(candidate):
                # SPA fallback: unknown paths get the shell, which routes.
                candidate = os.path.join(root_real, "index.html")
                if not os.path.isfile(candidate):
                    return self._json(404, {"error": "not found"})

            ext = os.path.splitext(candidate)[1].lower()
            ctype = STATIC_TYPES.get(ext)
            if ctype is None:
                return self._json(404, {"error": "unsupported file type"})
            try:
                with open(candidate, "rb") as fh:
                    body = fh.read()
            except OSError:
                return self._json(404, {"error": "not found"})
            cache = "no-store" if ext == ".html" else "public, max-age=300"
            self._headers(200, ctype, len(body), {"Cache-Control": cache})
            self.wfile.write(body)

    return Handler


def cmd_serve(cfg, args):
    from http.server import ThreadingHTTPServer

    token = os.environ.get(cfg["api_token_env"], "")
    if len(token) < 24:
        raise SystemExit(
            f"{cfg['api_token_env']} must be set to at least 24 characters.\n"
            f"This endpoint reports when the house is empty and serves live\n"
            f"stills of its interior, so it does not start without one.\n\n"
            f"  echo \"{cfg['api_token_env']}=$(openssl rand -hex 32)\" >> .env\n")

    os.makedirs(cfg["state_dir"], exist_ok=True)
    collector = Collector(cfg)
    thread = threading.Thread(target=collector.run, daemon=True)
    thread.start()

    bind = args.bind or cfg["api_bind"]
    port = int(args.port or cfg["api_port"])
    # Never bind "::". This host has a global IPv6 address, and a dual-stack
    # bind is one permissive router rule away from publishing the inside of a
    # home to the open internet, with no NAT as a backstop.
    httpd = ThreadingHTTPServer((bind, port), make_handler(collector, token))

    print(f"{stamp()}  collector on http://{bind}:{port}")
    for name, src in collector.sources.items():
        state = "ready" if (src.enabled and src.configured) else \
            f"dormant ({src.why_dormant()})"
        print(f"    {name:<12} every {src.interval:>4.0f}s   {state}")
    if bind not in ("127.0.0.1", "localhost"):
        print(f"{stamp()}  bound beyond loopback -- anything on this network can\n"
              f"           reach it with the token. Prefer the tailnet address.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        collector.stop.set()
        collector.save()


def cmd_once(cfg, args):
    """Poll everything once and print the payload. For debugging by hand."""
    collector = Collector(cfg)
    for src in collector.sources.values():
        src.poll_once()
    print(json.dumps(collector.telemetry(), indent=2))


def main():
    load_env()
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("serve", help="run the collector and HTTP server")
    p.add_argument("--bind", help="interface to bind (default from config)")
    p.add_argument("--port", type=int, help="port (default from config)")
    p.set_defaults(fn=cmd_serve)

    p = sub.add_parser("once", help="poll every source once and print the JSON")
    p.set_defaults(fn=cmd_once)

    args = ap.parse_args()
    cfg = load_config()
    args.fn(cfg, args)


if __name__ == "__main__":
    main()
