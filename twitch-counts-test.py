#!/usr/bin/env python3
"""Tests for twitch-counts.

Two halves, because they catch different things:

  characterization -- runs the real command over the real logs and compares each
      invocation against a stored snapshot. It has no opinion about what the
      output should be, only that refactoring must not change it. This is what
      caught a NameError that broke every command including --help, a missing
      setter that crashed --live/--offline/--unknown, and two stale attribute
      references after a record was split.

  unit -- calls into the module directly. Only possible because errors raise
      ConfigError rather than calling sys.exit: a bad channel used to be
      observable only by spawning a process.

    twitch-counts-test            run everything against the stored snapshots
    twitch-counts-test --accept   re-record the snapshots (after an intended change)
    twitch-counts-test --unit     just the fast in-process checks

Snapshots live next to this script in twitch-counts-snapshots/. Volatile fields
(timestamps, cache hit counts) are normalized before comparison.

The command under test comes from TC_TEST_CMD, a shell-style command line;
unset, it defaults to ./twitch-counts. Record the snapshots from the Python
reference with:

    TC_TEST_CMD="python3 twitch-counts.py" twitch-counts-test --accept

then verify the C port against those same snapshots with:

    TC_TEST_CMD="build/<os>/twitch-counts" twitch-counts-test

Each run builds a synthetic Chatterino log tree under a fresh HOME/XDG and
points TWITCH_LOGS_DIR at it, so neither implementation can reach the real
user's config, cache or logs.
"""

import argparse
import atexit
import collections
import datetime
import json
import select
import shlex
import shutil
import signal
import importlib.machinery
import io
import inspect
import importlib.util
import os
import random
import re
import sqlite3
import subprocess
import tempfile
import textwrap
import traceback
import time
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def test_command():
    """The command the characterization half runs: TC_TEST_CMD, else ./twitch-counts.

    TC_TEST_CMD is a shell-style command line, so `--accept` can record the
    snapshots from the Python reference ("python3 twitch-counts.py") and a later
    verify can point at the C port ("build/<os>/twitch-counts") without changing
    the script.  Resolved at module load so both halves always agree.
    """
    raw = os.environ.get("TC_TEST_CMD", "").strip()
    if not raw:
        return [os.path.join(HERE, "twitch-counts")]
    try:
        return shlex.split(raw)
    except ValueError as exc:
        raise SystemExit(f"TC_TEST_CMD is not a valid command line: {exc}") from None


def _command_available(command):
    """True when the command under test resolves to something spawnable."""
    if os.sep in command[0]:
        path = os.path.abspath(command[0])
        return os.path.isfile(path) and os.access(path, os.X_OK)
    return shutil.which(command[0]) is not None


def _write_day(channels_dir, channel, day, entries):
    """Write one Chatterino day file: <channel>/<channel>-YYYY-MM-DD.log.

    `entries` is a list of (hour, minute, second, line) tuples in chronological
    order; `line` is a whole log line ("alice: hi", or the "<channel> is live!"
    marker).  A fixed script per day is what keeps a snapshot reproducible.
    """
    stamp = f"{day:%Y-%m-%d}"
    lines = [f"# Start logging at {stamp} 00:00:00 EDT"]
    lines += [f"[{h:02d}:{m:02d}:{s:02d}] {text}" for h, m, s, text in entries]
    path = os.path.join(channels_dir, channel, f"{channel}-{stamp}.log")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def _chr_day(day):
    """chr: a busy channel with bots, a broadcaster, and pre-live chat.

    Alice crosses 400 messages so --share-floor 400 has a survivor to show; the
    pre-live chat on the first day is the only 'unknown' the range sees.
    """
    entries = []
    if day.day == 1:
        # Chat before the first live marker has no stream state to place it.
        entries += [
            (0, 0, 30, "eve: anyone there?"),
            (0, 1, 0, "frank: loading"),
            (0, 1, 30, "grace: give it a sec"),
            (0, 2, 0, "eve: ok it is up"),
        ]
    entries += [
        (5, 0, 0, "chr is live!"),
        (5, 12, 0, "alice: morning"), (5, 30, 0, "bob: hey"),
        (5, 45, 0, "carol: hi"), (5, 55, 0, "alice: five more"),
        (6, 0, 0, "dave: what's up"), (6, 15, 0, "alice: same as ever"),
        (6, 30, 0, "supibot: !uptime"), (6, 45, 0, "eve: first"),
        (7, 0, 0, "frank: hello"), (7, 15, 0, "grace: welcome"),
        (7, 30, 0, "chr: thanks everyone"), (7, 45, 0, "alice: great start"),
        (8, 0, 0, "hank: nice"), (8, 20, 0, "iris: gg"),
        (8, 40, 0, "jake: o7"), (9, 0, 0, "alice: long day"),
        (9, 20, 0, "bob: yep"), (10, 0, 0, "streamelements: New follower supibot"),
        (10, 30, 0, "alice: almost noon"), (11, 0, 0, "carol: lunch break?"),
        (11, 30, 0, "dave: brb"), (12, 0, 0, "alice: back"),
        (12, 15, 0, "eve: welcome back"), (13, 0, 0, "frank: this is fun"),
        (13, 20, 0, "grace: glad you like it"), (13, 30, 0, "alice: afternoon"),
        (14, 0, 0, "hank: more"), (14, 20, 0, "iris: agreed"),
        (14, 40, 0, "jake: yes"), (15, 0, 0, "alice: almost done"),
        (15, 30, 0, "hank: one more"), (16, 0, 0, "eve: keep it up"),
        (16, 30, 0, "frank: will do"), (17, 0, 0, "grace: nice"),
        (17, 30, 0, "iris: evening"), (18, 0, 0, "alice: evening crew"),
        (18, 30, 0, "bob: evening"), (19, 0, 0, "carol: hello again"),
        (19, 30, 0, "dave: hi"), (19, 45, 0, "jake: last one"),
        (20, 0, 0, "hank: night shift"), (20, 30, 0, "iris: indeed"),
        (20, 45, 0, "alice: almost wrapped"), (21, 0, 0, "alice: wrapping up"),
        (22, 0, 0, "eve: see you all later"), (22, 30, 0, "frank: gg"),
        (23, 0, 0, "chr is now offline."),
        (23, 5, 0, "alice: gg"), (23, 10, 0, "eve: night"),
        (23, 15, 0, "frank: see you"),
    ]
    return entries


def _spaghettieframe_day(day):
    """spaghettieframe: two very active users for -n 0 -m 100, light cast."""
    entries = []
    if day.day == 1:
        entries += [
            (0, 1, 0, "rare: is anyone around"),
            (0, 1, 30, "occasional: quiet in here"),
        ]
    entries += [
        (5, 0, 0, "spaghettieframe is live!"),
        (5, 5, 0, "regular: hello"), (5, 20, 0, "lurker: hi"),
        (6, 0, 0, "occasional: checking in"), (6, 5, 0, "regular: going"),
        (6, 15, 0, "lurker: nice"), (6, 30, 0, "sparse: one message"),
        (7, 0, 0, "regular: another"), (7, 5, 0, "lurker: and"),
        (7, 10, 0, "occasional: out"), (8, 0, 0, "regular: good"),
        (8, 5, 0, "lurker: great"), (9, 0, 0, "regular: done"),
    ]
    if 10 <= day.day <= 19:
        entries += [(8, 30, 0, "rare: only some days")]
    entries += [
        (12, 0, 0, "spaghettieframe is now offline."),
        (12, 5, 0, "regular: gg"), (12, 10, 0, "lurker: see you"),
    ]
    return entries


def _bon_day(day):
    """bon: an even cast of eight, and enough unknown chat for a column."""
    entries = []
    if day.day == 1:
        entries += [
            (0, 0, 45, "mike: early bird"),
            (0, 1, 15, "nina: second"),
        ]
    entries += [
        (5, 0, 0, "bon is live!"),
        (5, 10, 0, "mike: hello"), (5, 25, 0, "nina: hi"),
        (5, 40, 0, "oscar: yo"), (6, 0, 0, "pip: morning"),
        (6, 20, 0, "quin: hey"), (6, 40, 0, "roxy: sup"),
        (7, 0, 0, "sam: hello all"), (7, 15, 0, "tess: hi"),
        (8, 0, 0, "mike: how is it going"), (8, 30, 0, "nina: good"),
        (9, 0, 0, "oscar: same"), (10, 0, 0, "pip: long stream"),
        (11, 0, 0, "quin: yes"), (12, 0, 0, "roxy: lunch"),
        (13, 0, 0, "sam: back"), (14, 0, 0, "tess: welcome back"),
        (15, 0, 0, "mike: afternoon"), (16, 0, 0, "nina: evening soon"),
        (17, 0, 0, "oscar: almost done"), (18, 0, 0, "pip: great stream"),
        (19, 0, 0, "quin: gg"), (20, 0, 0, "roxy: see you"),
        (21, 0, 0, "sam: night"), (22, 0, 0, "tess: bye"),
        (23, 0, 0, "bon is now offline."),
        (23, 5, 0, "mike: gg"), (23, 10, 0, "nina: night"),
        (23, 15, 0, "oscar: see you"),
    ]
    return entries


def _write_bulk_day(channels_dir, channel, day):
    """Write one day dense enough that a cold parse outlasts the SIGINT delay.

    The Ctrl-C unit check interrupts a one-shot run mid-parse; a small fixture
    would finish before the signal lands.  The old day (one line every 5 s) was
    ~530k lines over the range, which the C port parses in ~45 ms -- long done
    by the time the 0.5 s signal arrived.  Each day now carries a cast of five
    chatters posting every second, ~25x denser, so even the C port is still
    mid-parse when SIGINT lands (measured ~1.4 s for the C port over the range,
    ~16 s for the Python reference -- both comfortably beyond the delay).
    """
    stamp = f"{day:%Y-%m-%d}"
    lines = [f"# Start logging at {stamp} 00:00:00 EDT",
             "[00:00:00] biglogs is live!"]
    for second in range(5, 23 * 3600):
        h, m, s = second // 3600, (second // 60) % 60, second % 60
        for chatter in ("bulkuser0", "bulkuser1", "bulkuser2",
                        "bulkuser3", "bulkuser4"):
            lines.append(f"[{h:02d}:{m:02d}:{s:02d}] {chatter}: hello")
    lines.append("[23:00:00] biglogs is now offline.")
    path = os.path.join(channels_dir, channel, f"{channel}-{stamp}.log")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


def _build_fixture_env():
    """A fresh, isolated environment plus a synthetic Chatterino log tree.

    The characterization cases never pass --logs-dir, so they read the default
    location.  This builds the tree the reference and the C port would otherwise
    have to find on a real machine, and points HOME, the XDG directories and
    TWITCH_LOGS_DIR at a fresh directory per run -- neither implementation can
    touch the real user's config, cache or logs, and a bare checkout records
    and verifies the same snapshots.  Returns the fixture root, which every path
    the command under test could print lives beneath.
    """
    root = tempfile.mkdtemp(prefix="twitch-counts-test.")
    atexit.register(shutil.rmtree, root, ignore_errors=True)
    home = os.path.join(root, "home")
    os.environ["HOME"] = home
    os.environ["XDG_CONFIG_HOME"] = os.path.join(home, ".config")
    os.environ["XDG_CACHE_HOME"] = os.path.join(home, ".cache")
    os.makedirs(os.environ["XDG_CONFIG_HOME"], exist_ok=True)
    os.makedirs(os.environ["XDG_CACHE_HOME"], exist_ok=True)
    # The cases exercise --exclude-group and --include, which only mean
    # something when the tool's own documented bots group is configured.
    with open(os.path.join(os.environ["XDG_CONFIG_HOME"], "twitch-counts.toml"),
              "w", encoding="utf-8") as handle:
        handle.write("[exclude]\n"
                     'bots = ["streamelements", "supibot", "fossabot", "nightbot"]\n'
                     'always = ["bots"]\n')
    channels = os.path.join(root, "Logs", "Twitch", "Channels")
    os.environ["TWITCH_LOGS_DIR"] = channels
    start = datetime.date(2026, 7, 1)
    days = [start + datetime.timedelta(days=offset) for offset in range(32)]
    for channel, entries_for in (
        ("chr", _chr_day),
        ("spaghettieframe", _spaghettieframe_day),
        ("bon", _bon_day),
    ):
        os.makedirs(os.path.join(channels, channel), exist_ok=True)
        for day in days:
            _write_day(channels, channel, day, entries_for(day))
    # A channel heavy enough for the SIGINT unit check, never referenced by the
    # characterization cases so the recorded tables stay small and readable.
    os.makedirs(os.path.join(channels, "biglogs"), exist_ok=True)
    for day in days:
        _write_bulk_day(channels, "biglogs", day)
    return root


# The Python reference is also imported in-process for the unit checks, which
# always exercise the reference regardless of what COMMAND points at.
PY_SOURCE = os.path.join(HERE, "twitch-counts.py")
COMMAND = test_command()
if not _command_available(COMMAND):
    raise SystemExit(
        f"command under test is missing or not executable: {COMMAND[0]!r} -- "
        "set TC_TEST_CMD (e.g. TC_TEST_CMD=\"python3 twitch-counts.py\") or "
        "build the C port at ./twitch-counts")
SNAPSHOTS = os.path.join(HERE, "twitch-counts-snapshots")
FIXTURE_ROOT = _build_fixture_env()
# A non-tty subprocess sizes argparse output from COLUMNS (fallback 80); pinning
# it keeps the snapshots independent of whatever shell invoked the test.
SUBPROCESS_ENV = {**os.environ, "COLUMNS": "80", "LINES": "24"}

# A fixed --end keeps live chat from moving the numbers under the test.
END = "2026-08-01 12:00"

CASES = {
    "basic":          ["-c", "chr", "-e", END],
    "bystate":        ["-c", "chr", "-e", END, "-B", "-n", "5"],
    "sort_share":     ["-c", "chr", "-e", END, "-B", "--sort", "offline-share", "-m", "1", "-n", "8"],
    "live":           ["-c", "chr", "-e", END, "-L", "-n", "5"],
    "offline":        ["-c", "chr", "-e", END, "-O", "-n", "5"],
    "unknown":        ["-c", "chr", "-e", END, "-U", "-m", "1"],
    "noexclude":      ["-c", "chr", "-e", END, "--no-exclude", "-n", "5"],
    "include":        ["-c", "chr", "-e", END, "--include", "supibot", "-n", "5"],
    "group":          ["-c", "chr", "-e", END, "-g", "bots", "-n", "3"],
    "broadcaster":    ["-c", "chr", "-e", END, "--exclude-broadcaster", "-n", "3"],
    "week":           ["-c", "chr", "-b", "2026-W28", "-e", "2026-W30", "-n", "5"],
    "dates":          ["-c", "chr", "-b", "2026-07-01", "-e", END, "-n", "5"],
    "json":           ["-c", "chr", "-e", END, "-n", "3", "--json"],
    "json_full":      ["-c", "spaghettieframe", "-e", END, "-m", "1", "--json"],
    "empty":          ["-c", "chr", "-e", END, "-m", "999999"],
    "show":           ["-c", "chr", "-e", END, "--show", "live,unknown,live-share", "-n", "4"],
    "top0":           ["-c", "spaghettieframe", "-e", END, "-n", "0", "-m", "100"],
    "nocache":        ["-c", "chr", "-e", END, "--no-cache", "-n", "5"],
    "bon":            ["-c", "bon", "-e", END, "-n", "6", "-B"],
    "header_compact": ["-c", "chr", "-e", END, "-n", "3", "--header", "compact"],
    "header_none":    ["-c", "chr", "-e", END, "-n", "3", "--header", "none"],
    "header_rolling": ["-c", "chr", "-b", "2026-07-01", "-e", END, "-L", "-n", "2",
                       "--header", "compact"],
    # The compact header used to be derived separately from the full block, and
    # had quietly stopped mentioning the share floor -- a filter that drops users
    # who did meet min_count. These two pin the facts only the compact projection
    # can lose: the floor, and the row cap alongside a non-default sort.
    "header_compact_floor": ["-c", "chr", "-e", END, "--sort", "offline-share",
                             "--share-floor", "400", "-m", "1", "--header", "compact"],
    "header_compact_sort":  ["-c", "chr", "-e", END, "--sort", "login", "-n", "3",
                             "--header", "compact"],
    # --by-state adds 'unknown' itself when the range holds any, and --show can
    # name it too. Asking for both used to render the column twice.
    "show_unknown_twice":   ["-c", "bon", "-e", END, "-B", "--show", "unknown",
                             "-n", "2"],
    "help":           ["--help"],
    "manual":         ["--manual"],
    "completions":    ["--emit-fish-completions"],
    "err_channel":    ["-c", "nope", "-e", END],
    "err_state":      ["-c", "chr", "-e", END, "-B", "-O"],
    "err_json":       ["-c", "nope", "--json"],
    "complete":       ["--complete", "channels"],
}

NORMALIZERS = (
    # The fixture root moves on every run, so any path under it that the command
    # prints -- the logs dir in the header or an error -- must compare equal.
    (re.compile(re.escape(FIXTURE_ROOT)), "<fixture>"),
    # The program name is basename(argv[0]): recording runs the Python reference
    # as twitch-counts.py while the C port runs as twitch-counts, so the usage
    # line (the only place either prints it) must not care which.
    (re.compile(r"twitch-counts\.py"), "twitch-counts"),
    (re.compile(r"^(cache|end|begin):.*$", re.M), r"\1: <normalized>"),
    (re.compile(r'"generated_at": "[^"]*"'), '"generated_at": "<normalized>"'),
    (re.compile(r'"(begin|end)": "[^"]*"'), r'"\1": "<normalized>"'),
    (re.compile(r"\d+ day\(s\) reused, \d+ parsed"), "<cache>"),
    # Varies with how warm the cache happens to be; "used" and "problem" are the
    # parts worth pinning. Quoted so the snapshot stays parseable JSON.
    (re.compile(r'"days_reused": \d+'), '"days_reused": "<normalized>"'),
)


def capture(argv):
    result = subprocess.run(COMMAND + argv, capture_output=True, text=True,
                            env=SUBPROCESS_ENV)
    text = result.stdout + result.stderr
    for pattern, replacement in NORMALIZERS:
        text = pattern.sub(replacement, text)
    return text


def load_module():
    """Import the script as a module.

    It must be registered in sys.modules before exec: inspect.getsource() on a
    *class* resolves the file through sys.modules[cls.__module__], so without
    this the cache fingerprint silently falls back to class names and stops
    covering their bodies -- which is exactly the failure the fingerprint exists
    to prevent, hidden inside the tests that check it.
    """
    loader = importlib.machinery.SourceFileLoader("twitch_counts", PY_SOURCE)
    spec = importlib.util.spec_from_loader("twitch_counts", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    loader.exec_module(module)
    return module



class Term:
    """A terminal just big enough to replay what Screen emits.

    The diff painter is only correct if the screen it produces is the one a full
    repaint would have produced, and bytes cannot show that. This replays both
    and compares the grid.
    """

    CSI = re.compile(r"\033\[([0-9;?]*)([A-Za-z])")

    def __init__(self, rows=40, cols=120):
        self.rows, self.cols = rows, cols
        self.grid = [""] * rows
        self.r = self.c = 0

    def feed(self, data):
        i = 0
        while i < len(data):
            m = self.CSI.match(data, i)
            if m:
                nums = [int(x) for x in m.group(1).split(";") if x.isdigit()]
                cmd = m.group(2)
                if cmd == "H":
                    self.r = (nums[0] - 1) if nums else 0
                    self.c = (nums[1] - 1) if len(nums) > 1 else 0
                elif cmd == "J":
                    if not nums or nums[0] == 0:
                        self.grid[self.r] = self.grid[self.r][:self.c]
                        for k in range(self.r + 1, self.rows):
                            self.grid[k] = ""
                    elif nums[0] == 2:
                        self.grid = [""] * self.rows
                elif cmd == "K":
                    self.grid[self.r] = self.grid[self.r][:self.c]
                elif cmd == "m":
                    self._put(m.group(0))       # SGR is part of the cell content
                i = m.end()
                continue
            ch = data[i]
            if ch == "\n":
                self.r += 1
                self.c = 0
                if self.r >= self.rows:
                    self.grid.pop(0); self.grid.append(""); self.r = self.rows - 1
            elif ch == "\r":
                self.c = 0
            else:
                self._put(ch)
            i += 1

    def _put(self, text):
        if not 0 <= self.r < self.rows:
            return
        row = self.grid[self.r]
        if len(row) < self.c:
            row += " " * (self.c - len(row))
        self.grid[self.r] = row[:self.c] + text + row[self.c + len(text):]
        if not text.startswith("\033"):
            self.c += len(text)

    def screen(self):
        return [r.rstrip() for r in self.grid]


def paint_capture(screen, lines):
    """Run Screen.paint and return what it wrote, without touching stdout."""
    buf = io.StringIO()
    saved = sys.stdout
    sys.stdout = buf
    try:
        screen.paint(lines)
    finally:
        sys.stdout = saved
    return buf.getvalue()

def unit_checks(module, failures=None):
    """Error paths, asserted in-process. Each is a ConfigError with a message."""
    expectations = [
        (["-c", "nosuch", "--no-config"], "no logs for channel"),
        (["-c", "chr", "-B", "-O"], "counts one state only"),
        (["-c", "chr", "-b", "2026-08-01", "-e", "2026-07-01"], "is after end"),
        (["-c", "chr", "-b", "2025-W53"], "no week 53"),
        (["-c", "chr", "--no-exclude", "-x", "bob"], "cannot be combined"),
        (["-c", "chr", "-g", "nosuchgroup"], "unknown exclude group"),
    ]
    # Owned by the caller so a crash part-way through still reports whatever
    # was found before it. A broken invariant tends to take an unrelated check
    # down with it -- an empty listing leaves a `next(iter(...))` with nothing --
    # and losing every earlier finding to that traceback hides the actual cause.
    failures = [] if failures is None else failures
    # --- every environment variable the code reads is documented -----------
    # Two hand-kept lists had drifted to 8 and 13 of the 35 that actually work,
    # so the list is generated now; this is what keeps it honest. Any os.environ
    # read of a TWITCH_ name must appear in what --manual prints.
    source = open(PY_SOURCE).read()
    read_by_code = set(re.findall(r'environ\.get\("(TWITCH_[A-Z_]+)"', source))
    read_by_code |= {spec.env for spec in module.SETTINGS if spec.env}
    documented = {name for name, _ in module.environment_names()}
    for name in sorted(read_by_code - documented):
        failures.append(f"{name} is read by the code but absent from --manual")
    for name in sorted(documented - read_by_code):
        failures.append(f"{name} is documented but never read")
    manual = module.__doc__.replace(module.ENVIRONMENT_PLACEHOLDER,
                                    module.environment_manual())
    if module.ENVIRONMENT_PLACEHOLDER in manual:
        failures.append("the environment placeholder survived into --manual")
    for name in sorted(read_by_code):
        if name not in manual:
            failures.append(f"{name} missing from the rendered manual")
    # The epilog must not go back to naming a subset as though it were the set.
    epilog = module.build_parser().epilog or ""
    named = set(re.findall(r"TWITCH_[A-Z_]+", epilog))
    concrete = {n for n in named if not n.endswith("_")}
    if concrete:
        failures.append(f"--help names specific variables again ({sorted(concrete)}); "
                        f"it should state the rule and point at --manual")
    if "--manual" not in epilog:
        failures.append("--help does not point at --manual for the full list")

    # --- --users sizes the window from the reported population -------------
    # A synthetic day, so the step function is known exactly rather than
    # whatever the live channel happens to be doing. Each user speaks 3 times in
    # one minute, so with --min-count 3 a user "appears" the moment the window
    # reaches their minute -- and two of them share a minute, which is how a
    # count becomes unreachable.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        day = "2026-07-15"
        END_AT = f"{day} 12:00:00"
        lines = [f"# Start logging at {day} 00:00:00 EDT",
                 f"[00:00:00] chan is live!"]
        #  minutes before noon -> who speaks then
        speakers = {50: ["ann"], 40: ["bob"], 30: ["cal", "dot"],   # 3 unreachable
                    10: ["eve"]}
        for back, who in sorted(speakers.items(), reverse=True):
            stamp = f"{11 + (60 - back) // 60:02d}:{(60 - back) % 60:02d}"
            for name in who:
                for _ in range(3):
                    lines.append(f"[{stamp}:00] {name}: hi")
        with open(os.path.join(chan, f"chan-{day}.log"), "w") as handle:
            handle.write("\n".join(lines) + "\n")

        def sized(target, policy="at-least", extra=()):
            args = module.build_parser().parse_args(
                ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "3",
                 "-e", END_AT, "--users", str(target),
                 "--users-policy", policy, "--users-max", "2h"] + list(extra))
            report = module.build_report_data(args)
            width, requested, found = report.context.window.sized
            return int(width.total_seconds()), requested, found, report

        # cal and dot share a minute, so the count steps 1 -> 3 and 2 exists at
        # no width at all. Reachable here: 0, 1, 3, 4, 5.
        for target, policy, want_found, why in (
            (1, "at-least", 1, "one user, exactly"),
            (3, "at-least", 3, "three users, exactly"),
            (2, "at-least", 3, "2 is unreachable: at-least overshoots to 3"),
            (2, "at-most", 1, "2 is unreachable: at-most settles for 1"),
            (2, "nearest", 1, "2 is unreachable: nearest ties, narrower wins"),
            (99, "at-least", 5, "more than exist: reports what it found"),
        ):
            _, requested, found, _ = sized(target, policy)
            if requested != target:
                failures.append(f"--users {target}: reported requesting {requested}")
            if found != want_found:
                failures.append(f"--users {target} --users-policy {policy} found "
                                f"{found}, expected {want_found} ({why})")

        # at-most takes the widest window still holding the count, at-least the
        # narrowest -- so on a plateau the two differ.
        narrow, _, a, _ = sized(3, "at-least")
        wide, _, b, _ = sized(3, "at-most")
        if a != b:
            failures.append(f"plateau: at-least found {a}, at-most {b}")
        if wide <= narrow:
            failures.append(f"at-most window ({wide}s) should be wider than "
                            f"at-least ({narrow}s) on a plateau")

        # --top and the terminal height cap the display, and must not be able to
        # steer the sizing: the population that counts is the reported one.
        base, _, found, _ = sized(4, "at-least")
        capped, _, found_capped, report = sized(4, "at-least", ["-n", "1"])
        if (base, found) != (capped, found_capped):
            failures.append(f"--top changed the sizing: {base}s/{found} vs "
                            f"{capped}s/{found_capped}")
        if len(report.presentation.displayed) != 1:
            failures.append("--top should still cap the display afterwards")

        # The window rolls but never resizes: that is the whole promise.
        args = module.build_parser().parse_args(
            ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "3",
             "-e", END_AT, "--users", "3"])
        session = module.LiveReaders()
        searches = {"n": 0}
        real_search = module._search_width

        def counting_search(*a, **k):
            searches["n"] += 1
            return real_search(*a, **k)

        module._search_width = counting_search
        try:
            widths = set()
            for _ in range(3):
                widths.add(
                    module.build_report_data(args, session).context.window.sized[0])
        finally:
            module._search_width = real_search
        if len(widths) != 1:
            failures.append(f"--users resized mid-session: {sorted(widths)}")
        # With a fixed --end the search is deterministic, so equal widths prove
        # nothing on their own -- it has to actually run once.
        if searches["n"] != 1:
            failures.append(f"--users searched {searches['n']}x over 3 ticks; the "
                            f"width is meant to be settled at initialization")
        # A one-shot run has no session to remember it, and searches every time.
        searches["n"] = 0
        module._search_width = counting_search
        try:
            module.build_report_data(args)
            module.build_report_data(args)
        finally:
            module._search_width = real_search
        if searches["n"] != 2:
            failures.append(f"one-shot --users searched {searches['n']}x for 2 runs")
        if not module.build_report_data(args, session).context.window.begin_rolls:
            failures.append("--users should roll like --since, not pin its begin")

        # The header states both numbers, and only reaches compact when they differ.
        _, _, _, report = sized(2, "at-least")
        row = next((r for r in report.presentation.rows if r.label == "users"), None)
        if row is None:
            failures.append("--users produced no header row")
        else:
            if "2 asked for" not in row.value or "3 found" not in row.value:
                failures.append(f"users row hides the mismatch: {row.value!r}")
            if not row.compact:
                failures.append("a mismatched users row should reach the compact header")
        _, _, _, exact = sized(3, "at-least")
        hit = next(r for r in exact.presentation.rows if r.label == "users")
        if hit.compact:
            failures.append(f"an exact users row should stay out of compact "
                            f"({hit.compact!r})")

    # --users cannot be combined with the other two ways to start a window.
    for clash in (["--users", "5", "-S", "30m"], ["--users", "5", "-b", "2026-07-01"]):
        noise = io.StringIO()
        saved = sys.stderr
        sys.stderr = noise                 # argparse prints usage before exiting
        try:
            module.build_parser().parse_args(["-c", "chr"] + clash)
            failures.append(f"{' '.join(clash)} should be rejected")
        except SystemExit:
            pass
        finally:
            sys.stderr = saved
        if "not allowed with" not in noise.getvalue():
            failures.append(f"{' '.join(clash)}: argparse did not say why")

    # --- the cache lease settles itself however the pass ends --------------
    # Three call sites used to honour a `cache_owned` flag, and none of them ran
    # when the pass raised. The rule now lives with the resource.
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "r.db")

        def alive(cache):
            try:
                cache.connection.execute("SELECT 1")
                return True
            except Exception:
                return False

        for owned, blow_up, want_alive, why in (
            (True, None, False, "owned, returned normally"),
            (True, KeyboardInterrupt, False, "owned, interrupted"),
            (True, RuntimeError, False, "owned, raised"),
            (False, None, True, "borrowed, returned normally"),
            (False, KeyboardInterrupt, True, "borrowed, interrupted"),
        ):
            cache, _ = module.Cache.open(path)
            try:
                with module.CacheLease(cache, None, owned=owned):
                    if blow_up:
                        raise blow_up
            except (KeyboardInterrupt, RuntimeError):
                pass
            if alive(cache) != want_alive:
                failures.append(f"CacheLease {why}: connection "
                                f"{'still open' if not want_alive else 'was closed'}")
            if not want_alive and not isinstance(cache.hits, int):
                failures.append(f"CacheLease {why}: a closed cache lost the "
                                f"counters the header reads after it")
            if want_alive:
                cache.close()
        # Cache itself is a context manager, so a caller with no ownership
        # question does not need the lease at all.
        cache, _ = module.Cache.open(path)
        with cache:
            pass
        if alive(cache):
            failures.append("Cache.__exit__ did not close the connection")
        # A lease over no cache at all (--no-cache) must be harmless.
        with module.CacheLease(None, None, owned=True):
            pass

    # --- Ctrl-C is a request, not a crash ----------------------------------
    # main()'s handler is only reachable from a real process, so this one costs
    # a subprocess. Worth it: an interrupted --json used to emit a thirty-line
    # traceback where the manual promises {"error": ...}.
    def interrupt(argv, delay=0.5):
        proc = subprocess.Popen(COMMAND + argv, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, env=SUBPROCESS_ENV)
        time.sleep(delay)
        proc.send_signal(signal.SIGINT)
        out, err = proc.communicate(timeout=20)
        return out.decode("utf-8", "replace"), err.decode("utf-8", "replace"), \
            proc.returncode

    # biglogs is the fixture's heavy channel: a cold parse outlasts the delay,
    # so the signal lands while the run is still working.
    slow = ["-c", "biglogs", "-m", "1", "--no-cache"]  # long enough to interrupt
    out, err, code = interrupt(slow)
    if "Traceback" in err:
        failures.append("SIGINT on a one-shot run still prints a traceback")
    if code != 130:
        failures.append(f"SIGINT exited {code}, expected 130 (128 + SIGINT)")
    if err.strip():
        failures.append(f"SIGINT in text mode should stay quiet, said {err.strip()[:60]!r}")
    out, err, code = interrupt(slow + ["--json"])
    if "Traceback" in err:
        failures.append("SIGINT under --json still prints a traceback")
    if code != 130:
        failures.append(f"SIGINT under --json exited {code}, expected 130")
    try:
        payload = json.loads(err)
    except Exception:
        payload = None
        failures.append(f"SIGINT under --json did not emit JSON on stderr: "
                        f"{err.strip()[:60]!r}")
    if payload is not None and "error" not in payload:
        failures.append(f"SIGINT under --json emitted {payload!r}, expected an error")

    # --- streamer mode drops the highlights and says nothing about them ----
    rules = {"watch": {"shades": 12, "highlight": [
        {"color": "#87ffff", "match": ["(?i)secret"]},
        {"color": "#ff8787", "match": ["(?i)other"]}]}}
    loud = module.resolve_watch(
        module.build_parser().parse_args(["-c", "chr", "-w"]), rules, "<unit>")
    if len(loud.highlights) != 2 or "highlight0" not in loud.ramps:
        failures.append(f"streamer mode fixture: {len(loud.highlights)} rules, "
                        f"ramps {sorted(loud.ramps)}")
    for argv, table, why in (
        (["-c", "chr", "-w", "--streamer"], rules, "--streamer"),
        (["-c", "chr", "-w"], {"watch": dict(rules["watch"], streamer_mode=True)},
         "[watch] streamer_mode"),
    ):
        quiet = module.resolve_watch(module.build_parser().parse_args(argv),
                                     table, "<unit>")
        if quiet.highlights:
            failures.append(f"{why}: {len(quiet.highlights)} rules survived")
        if any(k.startswith("highlight") for k in quiet.ramps):
            failures.append(f"{why}: highlight ramps were still built "
                            f"({sorted(quiet.ramps)})")
    # The flag must not override a config that turned it on, nor turn it on by
    # merely existing: store_true defaults to None so an absent flag is silent.
    still_on = module.resolve_watch(
        module.build_parser().parse_args(["-c", "chr", "-w"]),
        {"watch": dict(rules["watch"], streamer_mode=True)}, "<unit>")
    if still_on.highlights:
        failures.append("an absent --streamer overrode streamer_mode in the config")
    # A bad pattern is still a config error: the rules are parsed, just unused.
    try:
        module.resolve_watch(
            module.build_parser().parse_args(["-c", "chr", "-w", "--streamer"]),
            {"watch": {"shades": 12, "highlight": [{"color": "#87ffff",
                                                    "match": ["("]}]}}, "<unit>")
        failures.append("streamer mode swallowed an invalid highlight pattern")
    except (module.ConfigError, argparse.ArgumentTypeError):
        pass
    # And nothing about the suppressed rules reaches the header.
    report = module.build_report_data(module.build_parser().parse_args(
        ["-c", "chr", "-e", END, "-n", "2", "--watch", "1", "--streamer"]))
    labels = [row.label for row in report.presentation.rows]
    text = " ".join(f"{r.label} {r.value} {r.compact or ''}"
                    for r in report.presentation.rows).lower()
    for word in ("streamer", "highlight", "suppress"):
        if word in text:
            failures.append(f"the header mentions {word!r} in streamer mode: "
                            f"{labels}")

    # --- retention is not the fade duration --------------------------------
    # `hold` reads as a purely cosmetic setting, but the reader's floor used to
    # be derived from it, so hold=0 -- "the tint never fades" -- silently turned
    # off the cold-read seek and the pruning: 439ms and 49,565 buckets against
    # 32ms and 484.
    for hold, interval, steps, want in ((20.0, 5.0, 200, 20.0),
                                        (180.0, 2.0, 200, 180.0),
                                        (0.0, 5.0, 200, 1000.0),
                                        (0.0, 0.2, 50, 10.0),
                                        (10_000.0, 5.0, 100, 500.0)):
        got = module.replay_horizon(hold, interval, steps)
        if abs(got - want) > 1e-9:
            failures.append(f"replay_horizon({hold}, {interval}, {steps}) = {got}, "
                            f"expected {want}")
    if module.replay_horizon(0.0, 5.0, 200) <= 0:
        failures.append("replay_horizon: hold=0 must still bound retention, or the "
                        "seek and the pruning both switch off")

    # And the wiring: what run_watch actually hands the session.
    for hold, want_buckets, want_matches in ((20.0, 20.0, 20.0), (0.0, 1000.0, 0.0)):
        watch = module.resolve_watch(
            module.build_parser().parse_args(["-c", "chr", "-w"]),
            {"watch": {"hold": hold, "interval": 5.0, "replay_steps": 200,
                       "shades": 12}}, "<unit>")
        buckets, matches = module.session_floors(watch)
        if abs(buckets - want_buckets) > 1e-9:
            failures.append(f"session_floors(hold={hold}) keeps buckets for "
                            f"{buckets}s, expected {want_buckets}s -- retention "
                            f"is following the fade again")
        if abs(matches - want_matches) > 1e-9:
            failures.append(f"session_floors(hold={hold}) keeps matches for "
                            f"{matches}s, expected {want_matches}s")

    # Matches expire with the tint, buckets with the replay. A reader told the
    # tints never expire must keep its matches while still pruning buckets.
    def loaded():
        rdr = module.TailReader(os.path.join(tempfile.gettempdir(), "absent.log"),
                                datetime.date(2026, 7, 15))
        module.fold_lines(["[01:00:00] a: hi", "[02:00:00] b: hi",
                           "[03:00:00] c: hi"],
                          rdr.buckets, "live", (), rdr.matches, rdr.order)
        rdr.matches = {"a": [(3600, 0)], "c": [(10800, 0)]}
        return rdr

    rdr = loaded()
    rdr.prune(2 * 3600, match_floor=2 * 3600)
    if "a" in rdr.matches:
        failures.append("prune: a match below the floor should go when tints expire")
    rdr = loaded()
    rdr.prune(2 * 3600, match_floor=0)
    if "a" not in rdr.matches or "c" not in rdr.matches:
        failures.append(f"prune: match_floor=0 means the tints never expire, so no "
                        f"match may be dropped ({sorted(rdr.matches)})")
    if len(rdr.order) != 2:
        failures.append(f"prune: buckets should still be pruned when matches are "
                        f"kept ({len(rdr.order)} keys)")

    # --- Memo: one remembered answer, rebuilt only when its key moves -------
    builds = []
    memo = module.Memo()
    for key in ("a", "a", "b", "b", "a"):
        memo.get(key, lambda k=key: builds.append(k) or f"value-{k}")
    if builds != ["a", "b", "a"]:
        failures.append(f"Memo rebuilt on {builds}, expected ['a', 'b', 'a']")
    if memo.get("a", lambda: "wrong") != "value-a":
        failures.append("Memo returned a rebuilt value for an unchanged key")
    # A build that legitimately returns None must still be remembered.
    nulls = []
    memo = module.Memo()
    for _ in range(3):
        memo.get("k", lambda: nulls.append(1))
    if len(nulls) != 1:
        failures.append(f"Memo rebuilt a None value {len(nulls)}x -- the miss test "
                        f"is looking at the value instead of the key")
    memo.forget()
    memo.get("k", lambda: nulls.append(1))
    if len(nulls) != 2:
        failures.append("Memo.forget did not force a rebuild")

    # --- fold_windows is separable from gathering --------------------------
    from collections import Counter as _C
    seen = module.Bookkeeping(files=2, parsed=1, unreadable=(), reused=1,
                              shape=(("d1", "p1"), ("d2", "p2")))
    windows = [_C({("alice", "live"): 3, ("bot", "offline"): 5}),
               _C({("alice", "offline"): 2})]
    tally = module.fold_windows(windows, seen)
    if dict(tally.counts) != {"alice": 5, "bot": 5}:
        failures.append(f"fold_windows counts: {dict(tally.counts)}")
    if dict(tally.states) != {"live": 3, "offline": 7}:
        failures.append(f"fold_windows states: {dict(tally.states)}")
    if (tally.files, tally.parsed, tally.reused) != (2, 1, 1):
        failures.append("fold_windows did not carry the bookkeeping through")
    filtered = module.fold_windows(windows, seen, state_filter="live")
    if dict(filtered.counts) != {"alice": 3}:
        failures.append(f"fold_windows --live: {dict(filtered.counts)}")
    if dict(filtered.states) != {"live": 3, "offline": 7}:
        failures.append("fold_windows: the split is drawn before the filter")
    excl = module.fold_windows(windows, seen, excluded={"bot"})
    if dict(excl.excluded_states) != {"offline": 5}:
        failures.append(f"fold_windows excluded_states: {dict(excl.excluded_states)}")

    # --- a cold read seeks to the window instead of parsing the whole day --
    # The risk this trades for speed is the stream state: skipping the prefix
    # skips the markers in it, so the state entering the window has to be
    # recovered from what was skipped. Getting that wrong silently reclassifies
    # every message in the window, so it is asserted before the speed is.
    def build_log(entries):
        """entries: (hh:mm:ss, who-or-None-for-marker, text) in order."""
        out = ["# Start logging at 2026-07-15 00:00:00 EDT"]
        for stamp, who, text in entries:
            out.append(f"[{stamp}] {who}: {text}" if who else f"[{stamp}] {text}")
        return "\n".join(out) + "\n"

    body = build_log([
        ("00:00:01", None, "chan is live!"),
        ("00:00:02", "alice", "early"),
        ("06:00:00", None, "chan is now offline."),
        ("06:00:01", "bob", "mid"),
        ("12:00:00", None, "chan is live!"),
        ("12:00:01", "carol", "late"),
        ("18:00:00", "dave", "later"),
    ])
    for floor, want_off_after, want_state, why in (
        (0, None, None, "no floor asks for everything"),
        (1, "00:00:01", None, "a floor before the first line keeps it all"),
        (6 * 3600 + 1, "06:00:01", "offline", "after the offline marker"),
        (12 * 3600 + 1, "12:00:01", "live", "after the live marker"),
        (18 * 3600, "18:00:00", "live", "long after the last marker"),
        (23 * 3600, None, None, "past everything in the file"),
    ):
        offset, state = module.seek_window(body, floor)
        landed = body[offset:offset + 10] if offset < len(body) else None
        if want_off_after is None and floor >= 23 * 3600:
            if offset != len(body):
                failures.append(f"seek_window {why}: expected the end, got {offset}")
            continue
        if want_off_after and (landed is None
                               or not landed.startswith(f"[{want_off_after}")):
            failures.append(f"seek_window {why}: landed on {landed!r}, "
                            f"expected [{want_off_after}")
        if state != want_state:
            failures.append(f"seek_window {why}: entering state {state!r}, "
                            f"expected {want_state!r}")

    # A line that merely contains the marker text is not a marker.
    faked = build_log([("00:00:01", None, "chan is live!"),
                       ("05:00:00", "alice", "the stream is now offline. lol"),
                       ("06:00:00", "bob", "hi")])
    _, state = module.seek_window(faked, 6 * 3600)
    if state != "live":
        failures.append(f"seek_window: a chat message spoofed a marker ({state!r})")

    # End to end: a seeked read must agree with a full one, message for message.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        day = "2026-07-15"
        with open(os.path.join(chan, f"chan-{day}.log"), "w") as handle:
            handle.write(build_log(
                [("00:00:01", None, "chan is live!")]
                + [(f"{h:02d}:{m:02d}:00", f"user{(h + m) % 7}", "hi")
                   for h in range(24) for m in (0, 20, 40)]
                + [("11:00:00", None, "chan is now offline.")]))

        def count(floor_seconds):
            args = module.build_parser().parse_args(
                ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
                 "-b", f"{day} 12:00:00", "-e", f"{day} 23:59:59", "-B"])
            readers = module.LiveReaders()
            readers.retain_seconds = floor_seconds
            rep = module.build_report_data(args, readers)
            reader = next(iter(readers.files.values()))
            return (dict(rep.selection.counts), dict(rep.selection.states),
                    len(reader.order), reader.partial)

        whole = count(0)                 # no floor: reads the day
        seeked = count(60)               # a floor: seeks to noon minus a minute
        if whole[0] != seeked[0]:
            failures.append(f"seek: counts differ from a full read "
                            f"({whole[0]} vs {seeked[0]})")
        if whole[1] != seeked[1]:
            failures.append(f"seek: the live/offline split differs from a full "
                            f"read ({whole[1]} vs {seeked[1]})")
        if seeked[2] >= whole[2]:
            failures.append(f"seek: held {seeked[2]} keys, a full read held "
                            f"{whole[2]} -- nothing was skipped")
        if not seeked[3]:
            failures.append("seek: a reader that skipped a prefix must be partial, "
                            "or its day gets written to the rollup as if whole")
        if whole[3]:
            failures.append("seek: a full read must not be marked partial")

    # --- excluded users leave the state split, not just the total ----------
    report = module.build_report_data(module.build_parser().parse_args(
        ["-c", "chr", "-e", END, "-m", "50"]))
    split = sum(report.selection.states.values())
    if not report.selection.excluded_counts:
        failures.append("state split check: nobody was excluded, so it proves nothing")
    elif split != report.selection.total_messages:
        failures.append(
            f"the header's state split ({split:,}) disagrees with the footer's "
            f"total ({report.selection.total_messages:,}) by "
            f"{split - report.selection.total_messages:,} -- excluded users are "
            f"still in the split")
    # With nothing excluded the two were always equal; keep it that way.
    plain = module.build_report_data(module.build_parser().parse_args(
        ["-c", "chr", "-e", END, "-m", "50", "--no-exclude"]))
    if sum(plain.selection.states.values()) != plain.selection.total_messages:
        failures.append("--no-exclude: the split and the total should agree")

    # --- falling rows can be left untinted ---------------------------------
    for flag, want in ((True, ["down", "up"]), (False, ["up"])):
        cfg = {"watch": {"shades": 12, "fade_up": "#87ff87", "fade_down": "#8a8a8a",
                         "tint_falling": flag}}
        settings = module.resolve_watch(
            module.build_parser().parse_args(["-c", "chr", "-w"]), cfg, "<unit>")
        if sorted(settings.ramps) != want:
            failures.append(f"tint_falling={flag}: ramps {sorted(settings.ramps)}, "
                            f"expected {want}")
        # A row whose count fell, through the real colorizer.
        tint, _ = module.colorizer(
            module.Frame(previous={"a": 10}, carried={}, hold=60.0,
                         ramps=settings.ramps, now=0.0), True)
        painted = tint("row", "a", 5)
        if flag and painted == "row":
            failures.append("tint_falling=True: a falling row was not tinted")
        if not flag and painted != "row":
            failures.append(f"tint_falling=False: a falling row was still tinted "
                            f"({painted!r})")
        # Rising must be unaffected either way.
        tint, _ = module.colorizer(
            module.Frame(previous={"a": 1}, carried={}, hold=60.0,
                         ramps=settings.ramps, now=0.0), True)
        if tint("row", "a", 9) == "row":
            failures.append(f"tint_falling={flag}: a rising row lost its tint")

    # --- the loop waits for the next shade step rather than polling past it -
    carried = {"a": ("up", 100.0)}
    step = 20.0 / 12                       # hold / shades
    for now, want in ((100.0, 100.0 + step), (100.5, 100.0 + step),
                      (101.7, 100.0 + 2 * step), (119.0, 120.0)):
        due = module.next_tint_change(carried, 20.0, 12, now)
        if due is None or abs(due - want) > 1e-9:
            failures.append(f"next_tint_change at {now}: got {due}, expected {want}")
    if module.next_tint_change(carried, 20.0, 12, 121.0) is not None:
        failures.append("next_tint_change: an expired tint is still scheduled")
    if module.next_tint_change(carried, 0.0, 12, 100.0) is not None:
        failures.append("next_tint_change: hold 0 never fades, so nothing is due")
    if module.next_tint_change({}, 20.0, 12, 100.0) is not None:
        failures.append("next_tint_change: nothing carried, nothing due")
    # The soonest of several wins, and expiry caps the last step.
    many = {"a": ("up", 100.0), "b": ("up", 100.9), "c": ("down", 90.0)}
    due = module.next_tint_change(many, 20.0, 12, 101.0)
    if due is None or due > 100.0 + step + 1e-9:
        failures.append(f"next_tint_change: did not pick the soonest ({due})")

    # --- the status line holds still unless asked for timing ---------------
    # It used to carry the tick time, which changed every frame and so wrote a
    # line every frame no matter how still the report was.
    for show, expect_timing in ((False, False), (True, True)):
        cfg = {"watch": {"shades": 12, "show_timing": show}}
        settings = module.resolve_watch(
            module.build_parser().parse_args(["-c", "chr", "-w"]), cfg, "<unit>")
        if settings.show_timing is not show:
            failures.append(f"show_timing={show} did not resolve")
    frozen = module.resolve_watch(
        module.build_parser().parse_args(["-c", "chr", "-w"]),
        {"watch": {"shades": 12}}, "<unit>")
    if frozen.show_timing:
        failures.append("show_timing should default to off, so the line holds still")

    src = {"interval": "--watch", "hold": "config [watch]"}
    quiet = [module.watch_status(0.2, 20.0, src, ms / 1000, False, "timer")
             for ms in (0, 3, 7, 12)]
    if len(set(quiet)) != 1:
        failures.append(f"status line moved between ticks with show_timing off: "
                        f"{sorted(set(quiet))}")
    if "tick" in quiet[0] or "woke" in quiet[0]:
        failures.append(f"status line still carries per-tick detail: {quiet[0]!r}")
    loud = [module.watch_status(0.2, 20.0, src, ms / 1000, True, "timer")
            for ms in (0, 3, 7)]
    if len(set(loud)) != 3:
        failures.append("show_timing on should make the line follow the tick")
    if "tick 3ms" not in loud[1] or "woke on timer" not in loud[1]:
        failures.append(f"show_timing on lost its detail: {loud[1]!r}")
    # A tick slower than the interval always says so: rare, and actionable.
    slow = module.watch_status(0.2, 20.0, src, 0.9, False, "timer")
    if "slower than the interval" not in slow or "900ms" not in slow:
        failures.append(f"a slow tick went unreported: {slow!r}")

    # --- the diff painter must put the same screen up as a full repaint ----
    # It sends a fifth of the bytes, but only if what lands is identical. This
    # replays both through a terminal model and compares the grid, not the bytes.
    def full_repaint(lines, width, first):
        parts = ["\033[2J\033[H"] if first else ["\033[H"]
        for text in lines:
            parts.append(module.clip(text, width) + "\033[K\n")
        parts.append("\033[J")
        return "".join(parts)

    random.seed(11)
    generated = []
    body = [f"user{i:02d}  {100 + i:>5}" for i in range(14)]
    for step in range(200):
        frame = ["header · a · b", "", "user        count", "-" * 17]
        for row in body:
            if random.random() < 0.25:          # a shade step, text unchanged
                shade = random.randrange(12)
                row = f"\033[38;2;{135 + shade};255;{135 + shade}m{row}\033[0m"
            frame.append(row)
        frame += ["-" * 17, f"{random.randrange(20)} of 40 user(s)"]
        if step % 37 == 0:                      # frames change height sometimes
            frame = frame[:random.randrange(8, len(frame))]
        frame += ["", f"watching -- tick {random.randrange(20)}ms -- Ctrl-C"]
        generated.append(frame)

    expected, actual = Term(cols=120), Term(cols=120)
    painter = module.Screen(full_every=50)
    drift = 0
    for i, frame in enumerate(generated):
        expected.feed(full_repaint(frame, 120, i == 0))
        actual.feed(paint_capture(painter, frame))
        if expected.screen() != actual.screen():
            drift += 1
            if drift == 1:
                bad = next(r for r, (x, y) in
                           enumerate(zip(expected.screen(), actual.screen())) if x != y)
                failures.append(
                    f"diff painter: frame {i} row {bad} differs -- "
                    f"full {expected.screen()[bad][:40]!r} vs "
                    f"diff {actual.screen()[bad][:40]!r}")
    if drift > 1:
        failures.append(f"diff painter: {drift} of {len(generated)} frames differed")

    # An unchanged frame must write nothing at all -- that is the whole point.
    painter = module.Screen(full_every=0)
    frame = ["one", "two", "three"]
    paint_capture(painter, frame)
    if paint_capture(painter, frame) != "":
        failures.append("diff painter: an unchanged frame still wrote to the terminal")

    # A shorter frame must erase the tail rather than leave it behind.
    painter = module.Screen(full_every=0)
    grid = Term(cols=120)
    grid.feed(paint_capture(painter, ["a", "b", "c", "d"]))
    grid.feed(paint_capture(painter, ["a", "b"]))
    if grid.screen()[:4] != ["a", "b", "", ""]:
        failures.append(f"diff painter: a shorter frame left rows behind "
                        f"({grid.screen()[:4]})")

    # A resize must force a full repaint: the clipping changed under us.
    painter = module.Screen(full_every=0)
    paint_capture(painter, ["x" * 40])
    painter.width = 20                       # pretend the terminal narrowed
    if "\033[2J" not in paint_capture(painter, ["x" * 40]):
        failures.append("diff painter: a width change did not force a full repaint")

    # And the backstop must fire, so a screen someone else wrote over heals.
    painter = module.Screen(full_every=3)
    paint_capture(painter, ["a"])
    fired = sum(1 for i in range(9)
                if "\033[2J" in paint_capture(painter, [f"line {i}"]))
    if fired < 2:
        failures.append(f"diff painter: full_repaint=3 fired {fired} times in 9 frames")

    # --- locating files is a bisect, and the edges are inclusive -----------
    listing = [(datetime.date(2026, 7, d), f"/x/chan-2026-07-{d:02d}.log")
               for d in (1, 2, 5, 9, 10)]
    D = lambda d, h=0: datetime.datetime(2026, 7, d, h)
    for want, args_, why in (
        ([1, 2, 5, 9, 10], (D(1), D(10, 23)), "the whole listing"),
        ([1], (D(1), D(1, 23)), "a single day, both edges on it"),
        ([2, 5], (D(2), D(5)), "both edges land on real files"),
        ([5], (D(3), D(6)), "edges in the gaps around one file"),
        ([], (D(6), D(8)), "a range with no files at all"),
        ([1, 2], (D(1), D(4)), "lower edge inclusive"),
        ([9, 10], (D(9), D(31)), "an end past the last file"),
        ([1, 2, 5, 9, 10], (datetime.datetime(2020, 1, 1), D(31)),
         "a begin before the first file"),
    ):
        got = [d.day for d, _ in module.files_between(listing, *args_)]
        if got != want:
            failures.append(f"files_between {why}: got {got}, expected {want}")
    for want, day, why in (
        ([1, 2], datetime.date(2026, 7, 5), "before a day that exists"),
        ([1, 2, 5], datetime.date(2026, 7, 6), "before a day that does not"),
        ([], datetime.date(2026, 7, 1), "before the first"),
        ([1, 2, 5, 9, 10], datetime.date(2027, 1, 1), "before everything"),
    ):
        got = [d.day for d, _ in module.files_before(listing, day)]
        if got != want:
            failures.append(f"files_before {why}: got {got}, expected {want}")

    for argv, expected in expectations:
        args = module.build_parser().parse_args(argv)
        try:
            module.run_report(args)
            failures.append(f"{' '.join(argv)}: expected ConfigError, got none")
        except module.ConfigError as exc:
            if expected not in str(exc):
                failures.append(f"{' '.join(argv)}: {expected!r} not in {str(exc)[:60]!r}")

    # --- tint rules, with time injected rather than slept through ----------
    ramps = {"up": module.hex_ramp((0, 0, 255), 3),
             "down": module.hex_ramp((255, 0, 0), 3)}

    def shade(text):
        """Which palette and which shade a rendered row is wearing."""
        found = re.search(r"\033\[38;2;\d+;\d+;\d+m", text)
        if not found:
            return None
        for name, ramp in ramps.items():
            if found.group() in ramp:
                return (name, ramp.index(found.group()) + 1)
        return ("?", 0)

    def sequence(hold, moves):
        """Drive colorizer over a series of (now, count) and report the shades."""
        carried, previous, out = {}, None, []
        for now, count in moves:
            tinting = module.colorizer(
                module.Frame(previous, carried, hold, ramps, now), True)
            out.append(shade(tinting.tint("row", "alice", count)))
            carried, previous = tinting.carried, {"alice": count}
        return out

    # a rise then three thirds of a 3s hold, then expiry
    got = sequence(3.0, [(0.0, 5), (1.0, 6), (1.5, 6), (2.5, 6), (3.5, 6), (4.5, 6)])
    want = [None, ("up", 1), ("up", 1), ("up", 2), ("up", 3), None]
    if got != want:
        failures.append(f"fade over the hold: expected {want}, got {got}")

    # a fall on a plain row greys it; a rise outranks a held green
    got = sequence(3.0, [(0.0, 5), (1.0, 4), (2.0, 6), (2.5, 5)])
    want = [None, ("down", 1), ("up", 1), ("up", 1)]
    if got != want:
        failures.append(f"rise outranks fall: expected {want}, got {got}")

    # hold 0 never dims and never expires
    got = sequence(0.0, [(0.0, 5), (1.0, 6), (500.0, 6)])
    want = [None, ("up", 1), ("up", 1)]
    if got != want:
        failures.append(f"indefinite hold: expected {want}, got {want if got == want else got}")

    # --- the same rules through render_text, no terminal involved ----------
    args = module.build_parser().parse_args(
        ["-c", "chr", "-e", END, "-n", "3", "--color", "always"])
    report = module.build_report_data(args)
    counts = dict(report.selection.counts)
    stale = {login: n - 1 for login, n in counts.items()}   # everyone just spoke
    lines, carried = module.render_text(
        report, module.Frame(stale, {}, 3.0, ramps, 0.0))
    fresh = [l for l in lines if ramps["up"][0] in l]
    if not fresh:
        failures.append("render_text: a risen row was not tinted with the first shade")
    later, _ = module.render_text(
        report, module.Frame(counts, carried, 3.0, ramps, 2.5))
    if not [l for l in later if ramps["up"][2] in l]:
        failures.append("render_text: an ageing row did not reach the last shade")
    if report.selection.cache is not None:
        report.selection.cache.close()

    # --- header modes: watch defaults to compact, one-shot to full ---------
    for argv, expected in ((["-c", "chr", "-e", END], "full"),
                           (["-c", "chr", "-e", END, "-w", "1"], "compact"),
                           (["-c", "chr", "-e", END, "-w", "1", "--header", "full"], "full"),
                           (["-c", "chr", "-e", END, "--header", "none"], "none")):
        report = module.build_report_data(module.build_parser().parse_args(argv))
        if report.presentation.header_mode != expected:
            failures.append(f"{' '.join(argv)}: header {report.presentation.header_mode!r}"
                            f" != {expected!r}")
        if report.selection.cache is not None:
            report.selection.cache.close()

    # Suppressing the header must widen the table, not just blank it.
    def rows_for(mode):
        args = module.build_parser().parse_args(
            ["-c", "chr", "-e", END, "-m", "1", "--header", mode])
        report = module.build_report_data(args)
        if report.selection.cache is not None:
            report.selection.cache.close()
        return report.presentation.limit
    # limits are None when not piped; only compare when the terminal drives them
    if rows_for("none") is not None and rows_for("full") is not None:
        if not rows_for("none") > rows_for("full"):
            failures.append("--header none did not free rows for the table")

    # --- cache validity, asserted without a database -----------------------
    Stat = collections.namedtuple("Stat", "st_size st_mtime_ns")
    cached = module.CachedFile(fingerprint="abc", size=10, mtime_ns=99,
                               enter_state="live", exit_state="offline")
    for row, stat, enter, fp, expected, label in (
        (cached, Stat(10, 99), "live", "abc", True, "unchanged file, same parser"),
        (cached, Stat(11, 99), "live", "abc", False, "size changed"),
        (cached, Stat(10, 98), "live", "abc", False, "mtime changed"),
        (cached, Stat(10, 99), "offline", "abc", False, "entering state changed"),
        (cached, Stat(10, 99), None, "abc", False, "entering state went unknown"),
        (cached, Stat(10, 99), "live", "xyz", False, "written by another parser"),
        (None, Stat(10, 99), "live", "abc", False, "no cached row"),
    ):
        if module.cache_row_valid(row, stat, enter, fp) is not expected:
            failures.append(f"cache_row_valid: {label}")
    if not module.cache_row_valid(cached, Stat(10, 99), "offline", "abc",
                                  match_enter_state=False):
        failures.append("cache_row_valid: exit-state lookup must ignore enter_state")

    # --- cache round trip, against a temporary database --------------------
    with tempfile.TemporaryDirectory() as tmp:
        log = os.path.join(tmp, "chan-2026-01-01.log")
        with open(log, "w") as handle:
            handle.write("first\n")
        stat = os.stat(log)
        day = datetime.date(2026, 1, 1)
        counts = collections.Counter({("alice", "live"): 3, ("bob", "offline"): 1})
        path = os.path.join(tmp, "rollup.db")

        cache, _ = module.Cache.open(path)
        cache.put("chan", day, stat, None, "live", counts)
        hit = cache.get("chan", day, stat, None)
        if hit is None or hit[0] != counts or hit[1] != "live":
            failures.append(f"cache round trip: got {hit!r}")
        if cache.get("chan", day, stat, "live") is not None:
            failures.append("cache: a changed entering state must miss")
        if cache.exit_state("chan", day, stat) != "live":
            failures.append("cache: exit_state should survive the round trip")

        with open(log, "a") as handle:      # the log grows, as today's always does
            handle.write("second\n")
        if cache.get("chan", day, os.stat(log), None) is not None:
            failures.append("cache: a changed file must miss")
        cache.close()

        # A second parser generation must coexist, not wipe. This is the bug that
        # made an editor and a running --watch destroy each other's rows.
        original = module.cache_fingerprint
        module.cache_fingerprint = lambda: "0000000000000000"
        try:
            other, _ = module.Cache.open(path)
            if other.rebuilt_reason != "new parser generation":
                failures.append(f"cache: reason {other.rebuilt_reason!r} for a new parser")
            if other.get("chan", day, stat, None) is not None:
                failures.append("cache: rows of another parser must not be served")
            other.put("chan", day, stat, None, "offline", counts)
            other.close()
        finally:
            module.cache_fingerprint = original

        back, _ = module.Cache.open(path)
        survived = back.get("chan", day, stat, None)
        if survived is None or survived[1] != "live":
            failures.append("cache: the original generation's rows were destroyed")
        if back.rebuilt_reason is not None:
            failures.append(f"cache: unexpected rebuild {back.rebuilt_reason!r}")
        back.close()

        # Generations unseen for CACHE_KEEP_DAYS are swept.
        con = sqlite3.connect(path)
        stale_day = (datetime.datetime.now()
                     - datetime.timedelta(days=module.CACHE_KEEP_DAYS + 1)).isoformat()
        con.execute("UPDATE generation SET last_seen = ? WHERE fingerprint = ?",
                    (stale_day, "0000000000000000"))
        con.commit(); con.close()
        swept, _ = module.Cache.open(path)
        if swept.swept != 1:
            failures.append(f"cache: swept {swept.swept} stale generations, expected 1")
        left = swept.connection.execute(
            "SELECT COUNT(*) FROM file WHERE fingerprint = ?", ("0000000000000000",)
        ).fetchone()[0]
        if left:
            failures.append("cache: a swept generation left rows behind")
        swept.close()

    # --- incremental tailing -----------------------------------------------
    with tempfile.TemporaryDirectory() as tmp:
        day = datetime.date(2026, 1, 1)
        log = os.path.join(tmp, f"chan-{day}.log")

        def append(text):
            with open(log, "a") as handle:
                handle.write(text)

        append("# Start logging at 2026-01-01 00:00:00 EDT\n"
               "[10:00:00] alice: one\n[10:00:01] bob: two\n")
        reader = module.TailReader(log, day)
        begin = datetime.datetime(2026, 1, 1, 0, 0, 0)
        end = datetime.datetime(2026, 1, 1, 23, 59, 59)

        reader.refresh(None, os.stat(log))
        if sum(reader.window(begin, end).values()) != 2:
            failures.append("tail: cold read missed messages")
        if reader.full_reads != 1 or reader.appends != 0:
            failures.append("tail: first refresh should be a full read")

        if reader.refresh(None, os.stat(log)):
            failures.append("tail: an unchanged file should read nothing")

        append("[10:00:02] alice: three\n")
        reader.refresh(None, os.stat(log))
        if sum(reader.window(begin, end).values()) != 3:
            failures.append("tail: an appended message was missed")
        if reader.appends != 1:
            failures.append("tail: the append should have been incremental")

        # A half-written final line must be held back, then completed.
        append("[10:00:03] carol: par")
        reader.refresh(None, os.stat(log))
        if sum(reader.window(begin, end).values()) != 3:
            failures.append("tail: a partial line must not be counted yet")
        append("tial\n")
        reader.refresh(None, os.stat(log))
        if sum(reader.window(begin, end).values()) != 4:
            failures.append("tail: a completed line must be picked up")

        # The window is re-derived from buckets, not re-read.
        narrow = reader.window(datetime.datetime(2026, 1, 1, 10, 0, 2),
                               datetime.datetime(2026, 1, 1, 10, 0, 3))
        if sum(narrow.values()) != 2:
            failures.append(f"tail: window filter wrong, got {sum(narrow.values())}")

        # Truncation must force a full re-read rather than silently under-count.
        before = reader.full_reads
        with open(log, "w") as handle:
            handle.write("[11:00:00] dave: fresh\n")
        reader.refresh(None, os.stat(log))
        if reader.full_reads != before + 1:
            failures.append("tail: truncation should trigger a full re-read")
        if sum(reader.window(begin, end).values()) != 1:
            failures.append("tail: counts should reflect the truncated file")

        # A different entering state reclassifies, so it must start over.
        before = reader.full_reads
        reader.refresh("live", os.stat(log))
        if reader.full_reads != before + 1:
            failures.append("tail: a changed entering state should re-read")
        if reader.window(begin, end).get(("dave", "live")) != 1:
            failures.append("tail: messages should adopt the new entering state")

        # A throwaway reader -- what a one-shot run uses -- must agree with the
        # incrementally-built one. Same class now, so this checks the cold path.
        fresh = module.TailReader(log, day)
        fresh.refresh("live", os.stat(log))
        if fresh.window(begin, end) != reader.window(begin, end):
            failures.append("tail: a cold read differs from an incremental one")

    # --- [tail] settings ----------------------------------------------------
    tail_args = module.build_parser().parse_args(["-c", "chr"])
    for cfg, expected, label in (
        ({}, (True, 4, 30), "built-in defaults"),
        ({"tail": {"notify": False, "max_events": 9, "seed_lookback": 3}},
         (False, 9, 3), "[tail] overrides"),
        ({"seed_lookback": 5}, (True, 4, 5), "top-level fallback"),
    ):
        got = tuple(module.resolve_tail(tail_args, cfg, "x.toml"))
        if got != expected:
            failures.append(f"resolve_tail {label}: {got} != {expected}")
    for cfg, label in (({"tail": 5}, "[tail] not a table"),
                       ({"tail": {"max_events": 0}}, "max_events below one"),
                       ({"tail": {"notify": "maybe"}}, "notify not a boolean")):
        try:
            module.resolve_tail(tail_args, cfg, "x.toml")
            failures.append(f"resolve_tail: {label} was accepted")
        except module.ConfigError:
            pass

    # Every knob both sections have must be declared in the settings table, so
    # none of them can be a literal buried in the code.
    sectioned = {spec.section: set() for spec in module.SETTINGS if spec.section}
    for spec in module.SETTINGS:
        if spec.section:
            sectioned[spec.section].add(spec.name)
    expected = {"watch": {"interval", "min_interval", "hold", "fade_up", "fade_down",
                          "header", "replay_steps", "highlight", "shades",
                          "fade_curve", "fade_k", "user_width", "full_repaint",
                          "show_timing", "tint_falling", "min_redraw",
                          "streamer_mode"},
                "tail": {"notify", "max_events", "seed_lookback"}}
    if sectioned != expected:
        failures.append(f"section settings drifted: {sectioned} != {expected}")

    # Resolving a knob is not the same as using it: these drive behaviour.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        for date, text in (("2026-03-01", "[12:00:00] Chan is live!\n"),
                           ("2026-03-02", "[12:00:00] alice: quiet day\n"),
                           ("2026-03-03", "[12:00:00] bob: another\n")):
            with open(os.path.join(chan, f"chan-{date}.log"), "w") as handle:
                handle.write(text)
        begin = datetime.datetime(2026, 3, 3, 0, 0, 0)
        near = module.seed_stream_state(chan, begin, None, "chan", None, 1)
        far = module.seed_stream_state(chan, begin, None, "chan", None, 5)
        if near is not None:
            failures.append(f"seed_lookback=1 reached too far back: {near!r}")
        if far != "live":
            failures.append(f"seed_lookback=5 should have found the marker, got {far!r}")

        # ...and the configured value must actually reach it, through the whole
        # path: [tail] -> Context -> select_rows -> seed_stream_state.
        for lookback, expected in ((1, "unknown"), (5, "live")):
            cfg = os.path.join(tmp, f"cfg{lookback}.toml")
            with open(cfg, "w") as handle:
                handle.write(f"[tail]\nseed_lookback = {lookback}\n")
            report = module.build_report_data(module.build_parser().parse_args(
                ["--config", cfg, "--no-cache", "-d", tmp, "-c", "chan",
                 "-b", "2026-03-03", "-e", "2026-03-03", "-m", "1"]))
            if report.selection.cache is not None:
                report.selection.cache.close()
            if not report.selection.states.get(expected):
                failures.append(f"[tail] seed_lookback={lookback}: expected the range to "
                                f"count as {expected}, got {dict(report.selection.states)}")

    # max_events must reach the kqueue call, not just the constructor.  kqueue
    # is macOS and the BSDs; on every other platform this check has nothing to
    # test, and constructing the watcher would crash on select.kqueue.
    if hasattr(select, "kqueue"):
        class RecordingQueue:
            def __init__(self): self.asked = None
            def control(self, changes, count, timeout=None):
                self.asked = count
                return []
            def close(self): pass

        watcher = module.KqueueWatcher(7)
        if watcher.queue is not None:      # only where kqueue exists
            watcher.queue.close()
            watcher.queue = RecordingQueue()
            watcher.handles = {"fake": None}
            watcher.wait(0.01)
            if watcher.queue.asked != 7:
                failures.append(f"max_events not passed through: asked for {watcher.queue.asked}")
            watcher.handles = {}
            watcher.close()

    # The fingerprint must cover the classification, wherever it lives.
    if module.fold_lines not in module.CACHE_INPUTS:
        failures.append("fold_lines is not fingerprinted; parser changes would be missed")

    # ...and every entry must actually yield source. A callable whose body cannot
    # be read contributes only its name, so edits to it would go unnoticed.
    for item in module.CACHE_INPUTS:
        if isinstance(item, re.Pattern) or not callable(item):
            continue
        try:
            inspect.getsource(item)
        except (OSError, TypeError) as exc:
            failures.append(f"CACHE_INPUTS: {getattr(item, '__name__', item)!r} has no "
                            f"readable source ({exc.__class__.__name__}), so the "
                            f"fingerprint ignores its body")

    # --- launch replay: the first frame must not be uniformly plain ---------
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        now = datetime.datetime.now()
        day = now.date()
        lines = [f"# Start logging at {now:%Y-%m-%d %H:%M:%S} EDT"]
        for who, ago in (("fresh", 2), ("aged", 70), ("expired", 200)):
            for extra in (ago + 6, ago):
                stamp = (now - datetime.timedelta(seconds=extra)).strftime("%H:%M:%S")
                lines.append(f"[{stamp}] {who}: x")
        # one message leaves a 10-minute window ~40s ago, so this row fell
        for extra in (640, 100):
            stamp = (now - datetime.timedelta(seconds=extra)).strftime("%H:%M:%S")
            lines.append(f"[{stamp}] shrinking: x")
        with open(os.path.join(chan, f"chan-{day}.log"), "w") as handle:
            handle.write("\n".join(lines) + "\n")

        ramps = {"up": module.hex_ramp((0, 255, 0), 3),
                 "down": module.hex_ramp((255, 0, 0), 3)}
        args = module.build_parser().parse_args(
            ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
             "-S", "10m", "-w"])
        readers = module.LiveReaders()
        report = module.build_report_data(args, readers)
        window = report.context.window
        hold, interval = 90.0, 2.0
        base = module.Frame(hold=hold, ramps=ramps, now=1000.0)
        carried = module.replay_tints(readers, window, base, interval, 200)
        # hold 90 over three shades: 0-30s, 30-60s, 60-90s, then nothing
        for login, direction in (("fresh", "up"), ("aged", "up"),
                                 ("shrinking", "down")):
            if login not in carried:
                failures.append(f"replay: {login} should have been tinted")
        if "expired" in carried:
            failures.append("replay: a row idle for 200s should not be tinted")
        if carried.get("fresh", ("", 0))[0] != "up":
            failures.append("replay: a recent message should read as a rise")
        if carried.get("shrinking", ("", 0))[0] != "down":
            failures.append("replay: a message ageing out should read as a fall")
        # the shade must reflect *when*, not merely that something happened
        shades = {name: module.fade_color(entry[0], 1000.0 - entry[1], hold, ramps)
                  for name, entry in carried.items()}
        if shades.get("fresh") != ramps["up"][0]:
            failures.append(f"replay: fresh should be the first shade, got {shades.get('fresh')!r}")
        if shades.get("aged") != ramps["up"][2]:
            failures.append(f"replay: aged (70s) should be the last shade, got {shades.get('aged')!r}")

        # The launch decision: a rolling window reconstructs, a fixed one cannot.
        watch = module.resolve_watch(args, {"watch": {"hold": hold, "interval": interval,
                                                      "fade_up": [11, 12, 13],
                                                      "fade_down": [21, 22, 23]}}, "x")
        if not module.launch_tints(readers, report.context, watch, base):
            failures.append("launch_tints: a rolling window should reconstruct tints")
        fixed = module.build_report_data(module.build_parser().parse_args(
            ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
             "-b", str(day), "-e", f"{day} 23:59:59", "-w"]), module.LiveReaders())
        if fixed.selection.cache is not None:
            fixed.selection.cache.close()
        if module.launch_tints(readers, fixed.context, watch, base):
            failures.append("launch_tints: a fixed range cannot have moved, so no tints")

        # A fixed range cannot have moved, and the bound must be respected.
        if module.replay_tints(readers, window, base, interval, 0):
            failures.append("replay: replay_steps=0 should disable it")
        if module.replay_tints(module.LiveReaders(), window, base, interval, 200):
            failures.append("replay: with no buckets there is nothing to reconstruct")

    # --- content highlights -------------------------------------------------
    if module.parse_hex_colour("#0000ff") != (0, 0, 255):
        failures.append("parse_hex_colour: #0000ff")
    if module.parse_hex_colour("#00f") != (0, 0, 255):
        failures.append("parse_hex_colour: short form #00f")
    ramp = module.hex_ramp((0, 0, 255), 3)
    if ramp[0] != "\033[38;2;0;0;255m":
        failures.append(f"hex_ramp: freshest shade is {ramp[0]!r}")
    if len(ramp) != 3 or not ramp[-1].startswith("\033[38;2;170;170;255"):
        failures.append(f"hex_ramp: should fade toward white, got {ramp!r}")
    for bad, why in (("nope", "not hex"), ("#12345", "wrong length")):
        try:
            module.parse_hex_colour(bad)
            failures.append(f"parse_hex_colour accepted {why}")
        except Exception:
            pass
    for bad, why in ((5, "not a list"), ([{"color": "#fff"}], "no match key"),
                     ([{"color": "#fff", "match": []}], "empty match list"),
                     ([{"color": "#fff", "match": ["("]}], "invalid regex"),
                     ([{"color": "zzz", "match": ["x"]}], "bad colour")):
        try:
            module.parse_highlights(bad)
            failures.append(f"parse_highlights accepted {why}")
        except Exception:
            pass

    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        now = datetime.datetime.now()
        day = now.date()
        lines = [f"# Start logging at {now:%Y-%m-%d %H:%M:%S} EDT"]
        for who, text, ago in (("plainuser", "just chatting", 3),
                               ("fan", "love CHRONIC streams", 2),
                               ("shouter", "hey CC how are you", 1)):
            stamp = (now - datetime.timedelta(seconds=ago)).strftime("%H:%M:%S")
            lines.append(f"[{stamp}] {who}: {text}")
        with open(os.path.join(chan, f"chan-{day}.log"), "w") as handle:
            handle.write("\n".join(lines) + "\n")

        rules = module.parse_highlights(
            [{"color": "#0000ff", "match": ["(?i)cc", "(?i)chron"]}])
        readers = module.LiveReaders(rules)
        args = module.build_parser().parse_args(
            ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
             "-S", "10m", "-w", "--color", "always"])
        report = module.build_report_data(args, readers)
        reader = next(iter(readers.files.values()))
        if set(reader.matches) != {"fan", "shouter"}:
            failures.append(f"highlight matching: {sorted(reader.matches)} "
                            "should be fan and shouter only")

        # the chooser turns a match into a highlight ramp key, and nothing else
        choose = module.palette_chooser(readers, rules, now, 60.0)
        for login, expected in (("fan", module.highlight_key(0)),
                                ("shouter", module.highlight_key(0)),
                                ("plainuser", None)):
            if choose(login) != expected:
                failures.append(f"palette_chooser({login}) -> {choose(login)!r}, "
                                f"expected {expected!r}")
        # a match older than the hold stops highlighting
        stale = module.palette_chooser(readers, rules, now, 0.5)
        if stale("fan") is not None:
            failures.append("palette_chooser: a match past the hold should lapse")

        # --- the precedence ladder: fall < rise < rule 0 < rule 1 < ... -------
        two = module.parse_highlights([{"color": "#0000ff", "match": ["(?i)cc"]},
                                       {"color": "#00ff00", "match": ["(?i)chron"]}])
        pair = module.LiveReaders(two)
        both = os.path.join(chan, f"chan-{day}.log")
        with open(both, "a") as handle:
            stamp = (now - datetime.timedelta(seconds=1)).strftime("%H:%M:%S")
            handle.write(f"[{stamp}] mixer: CC and chronic together\n")
            handle.write(f"[{stamp}] earlyonly: just CC here\n")
        reader2 = pair.reader(both, day)
        reader2.refresh(None, os.stat(both))
        # one message matching both rules takes the later rule
        if reader2.matches.get("mixer", [(None, None)])[-1][1] != 1:
            failures.append(f"ladder: a message matching both rules should take the "
                            f"later one, got {reader2.matches.get('mixer')!r}")
        if reader2.matches.get("earlyonly", [(None, None)])[-1][1] != 0:
            failures.append("ladder: a message matching only rule 0 should take rule 0")
        # a login with hits from both rules resolves to the later rule, even if
        # the earlier rule matched more recently
        # both in the past, with the *earlier-defined* rule matching *longer* ago,
        # so this discriminates rule order from recency
        second_now = now.hour * 3600 + now.minute * 60 + now.second
        pair.reader(both, day).matches.setdefault("split", []).extend(
            [(second_now - 100, 1), (second_now - 10, 0)])
        picker = module.palette_chooser(pair, two, now, 0.0)
        if picker("split") != module.highlight_key(1):
            failures.append(f"ladder: rule order beats recency, got {picker('split')!r}")

        # a rule supersedes a fall, not just a rise
        ramps2 = {"up": module.hex_ramp((0, 255, 0), 1),
                  "down": module.hex_ramp((128, 128, 128), 1),
                  module.highlight_key(0): module.hex_ramp((0, 0, 255), 1)}
        chooser = lambda login: module.highlight_key(0) if login == "faller" else None
        tinting = module.colorizer(
            module.Frame({"faller": 5}, {}, 60.0, ramps2, 0.0, chooser), True)
        painted = tinting.tint("row", "faller", 4)      # count fell
        if ramps2[module.highlight_key(0)][0] not in painted:
            failures.append("ladder: a rule should supersede the fall colour")
        if tinting.carried["faller"][0] != "down":
            failures.append("ladder: the event behind the tint should still be the fall")

        # A fixed range cannot have moved, and the bound must be respected.

        # end to end: the highlight ramp must reach the rendered row
        ramps = {"up": module.hex_ramp((135, 255, 135), 1),
                 "down": module.hex_ramp((138, 138, 138), 1),
                 module.highlight_key(0): module.hex_ramp((0, 0, 255), 1)}
        counts = dict(report.selection.counts)
        stale_counts = {login: n - 1 for login, n in counts.items()}
        rendered, _ = module.render_text(
            report, module.Frame(stale_counts, {}, 60.0, ramps, 0.0, choose))
        blue = [l for l in rendered if "38;2;0;0;255m" in l]
        if len(blue) != 2:
            failures.append(f"render: expected 2 highlighted rows, got {len(blue)}")
        if any("plainuser" in l for l in blue):
            failures.append("render: a non-matching row was highlighted")
        if report.selection.cache is not None:
            report.selection.cache.close()

    # --- platform interface -------------------------------------------------
    if set(module.PLATFORMS) != {"darwin", "linux", "win32"}:
        failures.append(f"PLATFORMS should cover the three: {sorted(module.PLATFORMS)}")
    if not isinstance(module.PLATFORM, module.Platform):
        failures.append("PLATFORM should be a Platform instance")

    for cls, implemented in ((module.MacOS, True), (module.Linux, False),
                             (module.Windows, False), (module.Platform, False)):
        host = cls()
        # Notification: implemented platforms give a watcher, stubs say TODO.
        # On a host without kqueue the MacOS watcher cannot even be constructed,
        # so there is nothing its notify path can prove here; the polling half
        # below still exercises every class.
        can_notify = not (cls is module.MacOS and not hasattr(select, "kqueue"))
        if can_notify:
            try:
                watcher = host.watcher(notify=True)
                if not implemented:
                    failures.append(f"{host.name}: watcher(notify=True) should be Unsupported")
                else:
                    if not watcher.enabled:
                        failures.append(f"{host.name}: watcher should be notification-backed")
                    watcher.close()
            except module.Unsupported as exc:
                if implemented:
                    failures.append(f"{host.name}: watcher should work, got {exc}")
                if "TODO - not implemented" not in str(exc):
                    failures.append(f"{host.name}: error should read TODO, got {exc!r}")
                if "notify = false" not in str(exc):
                    failures.append(f"{host.name}: error should name the way round it")
        # Polling is always available, so a stub platform can still --watch.
        polling = host.watcher(notify=False)
        if polling.enabled:
            failures.append(f"{host.name}: notify=false must not be notification-backed")
        polling.close()
        # A missing log location is an error at use, naming the flag that fixes it.
        try:
            found = host.require_logs_dir()
            if not implemented:
                failures.append(f"{host.name}: require_logs_dir should be Unsupported")
            elif not found:
                failures.append(f"{host.name}: require_logs_dir returned nothing")
        except module.Unsupported as exc:
            if implemented:
                failures.append(f"{host.name}: logs_dir should be known, got {exc}")
            if "--logs-dir" not in str(exc):
                failures.append(f"{host.name}: logs error should name --logs-dir")
        # File identity is portable, so every platform answers it.
        with tempfile.NamedTemporaryFile() as handle:
            if not host.file_identity(os.stat(handle.name)):
                failures.append(f"{host.name}: file_identity should be answered")

    # Which paths each platform actually answers. Linux gets XDG for free since
    # that is a real spec; Windows conventions are unverified, so they stay TODO.
    answers = {
        module.MacOS:    {"logs_dir": True,  "config_path": True,  "cache_path": True},
        module.Linux:    {"logs_dir": False, "config_path": True,  "cache_path": True},
        module.Windows:  {"logs_dir": False, "config_path": False, "cache_path": False},
        module.Platform: {"logs_dir": False, "config_path": False, "cache_path": False},
    }
    for cls, expected in answers.items():
        host = cls()
        for name, should_answer in expected.items():
            value = getattr(host, name)()
            if bool(value) != should_answer:
                failures.append(f"{host.name}.{name}(): "
                                f"{'expected a path' if should_answer else 'expected None'}"
                                f", got {value!r}")

    # Linux paths follow XDG rather than being TODO, and honour the variables.
    saved = os.environ.get("XDG_CONFIG_HOME")
    os.environ["XDG_CONFIG_HOME"] = "/tmp/xdg-probe"
    try:
        if module.Linux().config_path() != "/tmp/xdg-probe/twitch-counts.toml":
            failures.append("Linux config_path should honour XDG_CONFIG_HOME")
    finally:
        if saved is None:
            del os.environ["XDG_CONFIG_HOME"]
        else:
            os.environ["XDG_CONFIG_HOME"] = saved

    # No default cache location means no cache, not a crash.
    if module.Cache.open(None) != (None, None):
        failures.append("Cache.open(None) should decline rather than fail")

    # Counting must work on a platform whose capabilities are stubs: that is the
    # whole point of raising at the point of use rather than at import.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        now = datetime.datetime.now()
        with open(os.path.join(chan, f"chan-{now.date()}.log"), "w") as handle:
            handle.write(f"# Start logging at {now:%Y-%m-%d %H:%M:%S} EDT\n"
                         f"[{now:%H:%M:%S}] alice: hello\n[{now:%H:%M:%S}] bob: hi\n")
        for cls in (module.Linux, module.Windows):
            readers = module.LiveReaders((), cls())
            report = module.build_report_data(module.build_parser().parse_args(
                ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
                 "-S", "1h"]), readers)
            if report.selection.cache is not None:
                report.selection.cache.close()
            if len(report.presentation.displayed) != 2:
                failures.append(f"{cls().name}: counting should work, got "
                                f"{report.presentation.displayed}")
            if next(iter(readers.files.values())).platform.name != cls().name:
                failures.append(f"{cls().name}: the injected platform was not used")

    # --- change notification ----------------------------------------------
    # Linux change notification is a documented TODO, so this only runs where
    # the platform actually answers with a watcher; a wrong error is still
    # reported rather than skipped.
    try:
        watcher = module.PLATFORM.watcher()
    except module.Unsupported as exc:
        if "TODO - not implemented" not in str(exc):
            failures.append(f"watcher: unexpected error, got {exc!r}")
    else:
        try:
            with tempfile.TemporaryDirectory() as tmp:
                path = os.path.join(tmp, "watched.log")
                with open(path, "w") as handle:
                    handle.write("x\n")
                watcher.arm([path])
                if watcher.enabled:
                    if watcher.wait(0.05):
                        failures.append("watcher: woke without a write")
                    with open(path, "a") as handle:
                        handle.write("y\n")
                    if not watcher.wait(1.0):
                        failures.append("watcher: a write did not wake it")
                watcher.arm([])       # dropping a path must release its descriptor
                if watcher.handles:
                    failures.append("watcher: descriptors outlived their path")
        finally:
            watcher.close()

    # The fingerprint must be stable, or every run rebuilds the cache.
    if module.cache_fingerprint() != module.cache_fingerprint():
        failures.append("cache_fingerprint is not deterministic")

    # Every Spec that declares flags must be reachable from the parser.
    declared = {a.dest for a in module.build_parser()._actions}
    for spec in module.SETTINGS:
        if spec.flags and spec.name not in declared:
            failures.append(f"Spec {spec.name!r} declares flags but is not in the parser")

    # --- the login column is pinned under --watch, and only there ----------
    # The point is stability across frames, so the checks compare frames with
    # different populations rather than inspecting one.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        today = datetime.date.today().isoformat()
        log = os.path.join(chan, f"chan-{today}.log")

        def say(who, n=60):
            with open(log, "a") as handle:
                for i in range(n):
                    handle.write(f"[00:00:{i % 60:02d}] {who}: hi\n")

        with open(log, "w") as handle:
            handle.write(f"# Start logging at {today} 00:00:00 EDT\n")
        say("bob")

        def table(argv, config=None):
            path = os.path.join(tmp, "w.toml")
            with open(path, "w") as handle:
                handle.write(config if config is not None else "")
            full = ["--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
                    "--config", path] + list(argv)
            report = module.build_report_data(module.build_parser().parse_args(full))
            lines, _ = module.render_text(report)
            rule = [l for l in lines if l.startswith("-")][0]
            return rule.split("  ")[0]           # the login column's own rule

        WATCH = ["--watch", "1"]
        first = table(WATCH, "[watch]\nuser_width = 20\n")
        if len(first) != 20:
            failures.append(f"user_width: watch column is {len(first)}, expected 20")

        # A much longer login arrives; the column must not move.
        say("a_considerably_longer_log")   # 25 chars: the Twitch maximum
        second = table(WATCH, "[watch]\nuser_width = 20\n")
        if second != first:
            failures.append(f"user_width: column moved when a longer login arrived "
                            f"({len(first)} -> {len(second)})")
        # ...and the name that did not fit is clipped, not allowed to overrun.
        report = module.build_report_data(module.build_parser().parse_args(
            ["--no-cache", "-d", tmp, "-c", "chan", "-m", "1", "--no-config",
             "--watch", "1"]))
        headers, rows = module.results_table(report)
        pinned = module.pin_user_column(report, headers, rows)
        if pinned != 20:
            failures.append(f"user_width: default should be 20, got {pinned}")
        if any(len(r[0]) > pinned for r in rows):
            failures.append(f"user_width: a cell overran the pin: "
                            f"{[r[0] for r in rows]}")
        if not any(r[0].endswith("…") for r in rows):
            failures.append(f"user_width: a clipped login lost its ellipsis: "
                            f"{[r[0] for r in rows]}")

        # 0 restores the self-sizing behaviour, which must differ from a pin.
        auto = table(WATCH, "[watch]\nuser_width = 0\n")
        if len(auto) == 20:
            failures.append("user_width = 0 should size from the rows, not pin at 20")
        if len(auto) != 25:
            failures.append(f"user_width = 0: sized to {len(auto)}, expected 25")

        # A one-shot report is untouched, whatever the config says.
        oneshot = table([], "[watch]\nuser_width = 20\n")
        if len(oneshot) == 20:
            failures.append("user_width: a one-shot report was pinned")
        if oneshot != auto:
            failures.append(f"user_width: one-shot differs from auto "
                            f"({len(oneshot)} vs {len(auto)})")

        # A narrow pin still clips rather than overflowing.
        narrow = table(WATCH, "[watch]\nuser_width = 8\n")
        if len(narrow) != 8:
            failures.append(f"user_width = 8 gave a {len(narrow)}-wide column")

    # --- windowing bisects to its range, and must still get the edges right
    # window() stopped walking the whole day, so the boundaries are now decided
    # by bisect rather than by a comparison per bucket. Off-by-one here silently
    # drops or double-counts a second at the edge of every rolling window.
    def folded(pairs, state="live"):
        """Build a reader's buckets and key order from (hh:mm:ss, login) pairs."""
        buckets, order = {}, []
        lines = [f"[{t}] {who}: hi" for t, who in pairs]
        module.fold_lines(lines, buckets, state, (), None, order)
        return buckets, order

    buckets, order = folded([
        ("00:00:10", "a"), ("01:00:00", "b"), ("01:00:00", "c"),
        ("12:00:00", "d"), ("23:59:59", "e"),
    ])
    if order != sorted(order) or len(order) != 5:
        failures.append(f"fold_lines: key order is {order}, expected 5 ascending")
    if len(set(order)) != len(order):
        failures.append("fold_lines: a key was recorded in the order list twice")
    if sum(buckets.values()) != 5:
        failures.append("fold_lines: lost a message while bucketing")
    # A repeat of an existing key must bump the count, not re-enter the order.
    again_b, again_o = folded([("01:00:00", "b"), ("01:00:00", "b")])
    if len(again_o) != 1 or sum(again_b.values()) != 2:
        failures.append(f"fold_lines: repeat key gave order {again_o}, "
                        f"counts {again_b}")

    day = datetime.date(2026, 7, 15)
    # Built through the real constructor -- reset() is what establishes the
    # reader's invariants, and __new__ silently skips any it gains later.
    reader = module.TailReader(os.path.join(tempfile.gettempdir(), "absent.log"), day)
    reader.buckets, reader.order = buckets, order

    def at(h1, m1, s1, h2, m2, s2):
        got = reader.window(datetime.datetime(2026, 7, 15, h1, m1, s1),
                            datetime.datetime(2026, 7, 15, h2, m2, s2))
        return sum(got.values())

    for want, args_, why in (
        (5, (0, 0, 0, 23, 59, 59), "the whole day"),
        (1, (0, 0, 10, 0, 0, 10), "a single second, inclusive at both ends"),
        (2, (1, 0, 0, 1, 0, 0), "two logins sharing one second"),
        (0, (0, 0, 11, 0, 59, 59), "a gap between buckets"),
        (3, (0, 0, 10, 1, 0, 0), "lower edge inclusive"),
        (3, (0, 0, 11, 12, 0, 0), "upper edge inclusive (01:00:00 x2 + 12:00:00)"),
        (1, (23, 59, 59, 23, 59, 59), "the last second of the day"),
        (0, (23, 59, 58, 23, 59, 58), "just before it"),
    ):
        got = at(*args_)
        if got != want:
            failures.append(f"window {why}: got {got}, expected {want}")

    # A clock that steps back -- the repeated hour when DST ends -- must not
    # leave the index unsorted, or bisect silently loses the earlier messages.
    out_of_order, oo_order = folded([
        ("02:00:00", "a"), ("01:30:00", "b"), ("02:00:01", "c")])
    if oo_order != sorted(oo_order):
        failures.append(f"fold_lines: order not sorted after a clock step back: "
                        f"{oo_order}")
    reader.buckets, reader.order = out_of_order, oo_order
    if at(1, 0, 0, 3, 0, 0) != 3:
        failures.append("window: a clock step back lost messages")

    # --- a tally is reused only when every window came back identical ------
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        today = datetime.date.today().isoformat()
        log = os.path.join(chan, f"chan-{today}.log")
        with open(log, "w") as handle:
            handle.write(f"# Start logging at {today} 00:00:00 EDT\n")
            handle.write("[00:00:00] chan is live!\n[00:00:01] alice: one\n")

        def count(extra=()):
            args = module.build_parser().parse_args(
                ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
                 "-b", f"{today} 00:00:00", "-e", f"{today} 23:59:59"] + list(extra))
            rep = module.build_report_data(args, session)
            return rep

        session = module.LiveReaders()
        first = count()
        if first.selection.total_messages != 1:
            failures.append(f"tally reuse: setup counted "
                            f"{first.selection.total_messages}")
        again = count()
        if again.selection.counts is not first.selection.counts:
            failures.append("tally reuse: an unchanged tick rebuilt the counts")
        # The bookkeeping must still describe this pass, not the cached one.
        if again.selection.parsed != 0:
            failures.append(f"tally reuse: reported {again.selection.parsed} files "
                            f"parsed on a tick that read nothing")
        if again.selection.files != first.selection.files:
            failures.append("tally reuse: file count went stale")
        # A new message must break the reuse.
        with open(log, "a") as handle:
            handle.write("[00:00:02] bob: two\n")
        grown = count()
        if grown.selection.total_messages != 2:
            failures.append(f"tally reuse: a new message was missed "
                            f"({grown.selection.total_messages})")
        if grown.selection.counts is again.selection.counts:
            failures.append("tally reuse: reused a tally after the log grew")
        # So must a different state filter, which changes what folding produces.
        only_live = count(["-L"])
        if only_live.selection.counts is grown.selection.counts:
            failures.append("tally reuse: a different --live/--offline reused the "
                            "unfiltered tally")
        if only_live.selection.total_messages != 2:
            failures.append(f"tally reuse: --live counted "
                            f"{only_live.selection.total_messages}, expected 2")
        offline = count(["-O"])
        if offline.selection.total_messages != 0:
            failures.append(f"tally reuse: --offline counted "
                            f"{offline.selection.total_messages}, expected 0")

    # --- the exclusion set is derived once per session ---------------------
    builds = {"n": 0}
    real_be = module.build_exclusions

    def counting_be(*a, **k):
        builds["n"] += 1
        return real_be(*a, **k)

    module.build_exclusions = counting_be
    try:
        session = module.LiveReaders()
        # One Namespace for the loop, as run_watch has: the session memo is keyed
        # on the args object, so a fresh one each tick is a different run.
        args = module.build_parser().parse_args(
            ["-c", "chr", "-e", END, "-m", "50", "-n", "2"])
        seen = []
        for _ in range(4):
            rep = module.build_report_data(args, session)
            seen.append(sorted(rep.selection.excluded))
        if builds["n"] != 1:
            failures.append(f"exclusions: rebuilt {builds['n']}x over 4 ticks")
        if len(set(map(tuple, seen))) != 1:
            failures.append(f"exclusions: drifted across ticks {seen}")
        if not seen[0]:
            failures.append("exclusions: the fixture excluded nobody, so this "
                            "proves nothing")
        if session.cache and session.cache[0] is not None:
            session.cache[0].close()
    finally:
        module.build_exclusions = real_be

    # --- the window slides instead of re-summing ---------------------------
    # A rolling window advances past almost nothing per tick, so window() keeps
    # its last answer and adjusts the two edges. Everything here is about the
    # ways that shortcut can go stale.
    def reader_from(pairs, day=datetime.date(2026, 7, 15)):
        rdr = module.TailReader(os.path.join(tempfile.gettempdir(), "absent.log"), day)
        module.fold_lines([f"[{t}] {who}: hi" for t, who in pairs],
                          rdr.buckets, "live", (), None, rdr.order)
        return rdr

    def at(rdr, h1, m1, s1, h2, m2, s2):
        return rdr.window(datetime.datetime(2026, 7, 15, h1, m1, s1),
                          datetime.datetime(2026, 7, 15, h2, m2, s2))

    rdr = reader_from([("10:00:00", "a"), ("10:00:10", "b"), ("10:00:20", "c"),
                       ("10:00:30", "d")])
    if sum(at(rdr, 10, 0, 0, 10, 0, 30).values()) != 4:
        failures.append("slide: first window wrong")
    # advance both edges: one drops off the front, none joins the back
    if sum(at(rdr, 10, 0, 5, 10, 0, 30).values()) != 3:
        failures.append("slide: a key leaving the front was not dropped")
    # advance the far edge only -- but there is nothing new to find
    if sum(at(rdr, 10, 0, 5, 10, 0, 40).values()) != 3:
        failures.append("slide: extending the end invented a message")
    # bounds moving backwards must fall back to a full re-sum
    if sum(at(rdr, 10, 0, 0, 10, 0, 30).values()) != 4:
        failures.append("slide: a window moving backwards kept the slid answer")

    # The staleness that bounds alone cannot see: at a 0.2s interval several
    # ticks share a second, so `end` repeats while new messages land inside it.
    rdr = reader_from([("10:00:00", "a")])
    if sum(at(rdr, 10, 0, 0, 10, 0, 5).values()) != 1:
        failures.append("slide: setup wrong")
    module.fold_lines(["[10:00:03] b: hi"], rdr.buckets, "live", (), None, rdr.order)
    rdr.revision += 1
    if sum(at(rdr, 10, 0, 0, 10, 0, 5).values()) != 2:
        failures.append("slide: a message arriving inside unchanged bounds was "
                        "missed -- the revision guard is not working")
    # a repeat of an existing key changes the count without changing the order
    module.fold_lines(["[10:00:03] b: again"], rdr.buckets, "live", (), None, rdr.order)
    rdr.revision += 1
    if sum(at(rdr, 10, 0, 0, 10, 0, 5).values()) != 3:
        failures.append("slide: a repeated key was not picked up")

    # A reset must discard it: the keys it was built from may be gone.
    rdr.reset(None)
    if rdr.window_ is not None:
        failures.append("slide: reset left the cached window behind")

    # And the whole thing must agree with a full re-sum over a real day.
    # Only where the platform knows a default logs location at all (Linux
    # leaves it as a TODO) and the day file actually exists.
    real = (os.path.join(module.DEFAULT_LOGS_DIR, "bonnie", "bonnie-2026-07-17.log")
            if module.DEFAULT_LOGS_DIR else None)
    if real and os.path.exists(real):
        day = datetime.date(2026, 7, 17)
        slid = module.TailReader(real, day); slid.refresh(None, os.stat(real))
        plain = module.TailReader(real, day); plain.refresh(None, os.stat(real))
        drift = 0
        for step in range(120):
            b = (datetime.datetime.combine(day, datetime.time(19, 0))
                 + datetime.timedelta(seconds=0.2 * step))
            e = b + datetime.timedelta(minutes=30)
            plain.window_ = None            # force the full path
            if slid.window(b, e) != plain.window(b, e):
                drift += 1
        if drift:
            failures.append(f"slide: {drift} of 120 advancing frames disagreed "
                            f"with a full re-sum")

    # --- a reader keeps only what its window can still reach ---------------
    rdr = reader_from([("10:00:00", "a"), ("10:00:10", "b"), ("11:00:00", "c")])
    rdr.matches = {"a": [(36000, 0)], "c": [(39600, 1)]}
    before = len(rdr.order)
    dropped = rdr.prune(10 * 3600 + 30)          # keep only 11:00:00
    if dropped != 2 or len(rdr.order) != 1:
        failures.append(f"prune: dropped {dropped}, {len(rdr.order)} keys left")
    if len(rdr.buckets) != 1:
        failures.append(f"prune: buckets not pruned with the order ({rdr.buckets})")
    if "a" in rdr.matches or "c" not in rdr.matches:
        failures.append(f"prune: matches not pruned to the floor ({rdr.matches})")
    if not rdr.partial:
        failures.append("prune: a pruned reader must not be cached as a whole day")
    if sum(at(rdr, 10, 0, 0, 23, 59, 59).values()) != 1:
        failures.append("prune: the surviving window is wrong")
    # A floor below everything held changes nothing, and never sets `partial`.
    fresh = reader_from([("10:00:00", "a")])
    if fresh.prune(0) or fresh.prune(1) or fresh.partial:
        failures.append("prune: pruned when there was nothing below the floor")

    # End to end: a session with a floor keeps only the reachable tail.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        today = datetime.date.today().isoformat()
        with open(os.path.join(chan, f"chan-{today}.log"), "w") as handle:
            handle.write(f"# Start logging at {today} 00:00:00 EDT\n")
            handle.write("[00:00:00] chan is live!\n")
            for hour in range(24):
                handle.write(f"[{hour:02d}:00:00] alice: hi\n")
        # The window opens at noon, so the morning can never be read again.
        args = module.build_parser().parse_args(
            ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
             "-b", f"{today} 12:00:00", "-e", f"{today} 23:59:59"])
        loose = module.LiveReaders()
        plain = module.build_report_data(args, loose)
        kept_all = len(next(iter(loose.files.values())).order)
        tight = module.LiveReaders()
        tight.retain_seconds = 3600          # keep an hour of slack behind it
        rep = module.build_report_data(args, tight)
        kept_some = len(next(iter(tight.files.values())).order)
        if kept_all != 24:
            failures.append(f"prune: unpruned reader holds {kept_all} keys, "
                            f"expected the whole day's 24")
        if kept_some != 13:                  # 11:00 through 23:00 inclusive
            failures.append(f"prune: kept {kept_some} keys, expected 13 "
                            f"(noon window plus an hour of slack)")
        if rep.selection.total_messages != plain.selection.total_messages:
            failures.append(f"prune: the count changed from "
                            f"{plain.selection.total_messages} to "
                            f"{rep.selection.total_messages}")

    # --- the resolved inputs are reused, but not blindly -------------------
    resolutions = {"n": 0}
    real_rs = module.resolve_settings

    def counting_rs(*a, **k):
        resolutions["n"] += 1
        return real_rs(*a, **k)

    module.resolve_settings = counting_rs
    try:
        with tempfile.TemporaryDirectory() as tmp:
            cfg = os.path.join(tmp, "c.toml")
            with open(cfg, "w") as handle:
                handle.write("min_count = 3\n[aliases]\nchr = \"bon\"\n")
            args = module.build_parser().parse_args(
                ["-c", "chr", "-e", END, "--config", cfg, "--watch", "1"])
            session = module.LiveReaders()
            first = module.resolve_context(args, session)
            for _ in range(5):
                module.resolve_context(args, session)
            if resolutions["n"] != 1:
                failures.append(f"inputs: resolved {resolutions['n']}x over 6 ticks")
            # The window must still move even though the rest is reused.
            moving = module.resolve_context(args, session)
            if moving.window.end < first.window.end:
                failures.append("inputs: the window went backwards")
            if first.window.threshold != 3:
                failures.append(f"inputs: read min_count {first.window.threshold}")
            # Editing the config mid-session must still land.
            time.sleep(0.01)
            with open(cfg, "w") as handle:
                handle.write("min_count = 9\n[aliases]\nchr = \"bon\"\n")
            after = module.resolve_context(args, session)
            if after.window.threshold != 9:
                failures.append(f"inputs: a config edit was not picked up "
                                f"({after.window.threshold})")
            # Different arguments on the same session must not reuse the answer.
            before = resolutions["n"]
            other = module.build_parser().parse_args(
                ["-c", "chr", "-e", END, "--config", cfg, "-m", "77"])
            got = module.resolve_context(other, session)
            if got.window.threshold != 77:
                failures.append(f"inputs: reused another run's answer "
                                f"({got.window.threshold}, expected 77)")
            if resolutions["n"] == before:
                failures.append("inputs: did not re-resolve for different args")
            # No session, no memo.
            n = resolutions["n"]
            module.resolve_context(args)
            module.resolve_context(args)
            if resolutions["n"] != n + 2:
                failures.append("inputs: memoized without a session to hold it")
    finally:
        module.resolve_settings = real_rs

    # --- a session drops what has left the window --------------------------
    # Nothing evicted readers before, so a session running across midnights grew
    # by a day of buckets per day and never gave any of it back.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        days = ["2026-07-10", "2026-07-11", "2026-07-12"]
        for day in days:
            with open(os.path.join(chan, f"chan-{day}.log"), "w") as handle:
                handle.write(f"# Start logging at {day} 00:00:00 EDT\n")
                handle.write("[12:00:00] chan is live!\n")
                for n in range(4):
                    handle.write(f"[12:00:0{n}] alice: hi {n}\n")

        def over(begin, end, readers):
            args = module.build_parser().parse_args(
                ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
                 "-b", begin, "-e", end])
            rep = module.build_report_data(args, readers)
            return rep

        session = module.LiveReaders()
        wide = over(days[0], f"{days[-1]} 23:59:59", session)
        if len(session.files) != 3:
            failures.append(f"retain: expected 3 readers over 3 days, "
                            f"got {len(session.files)}")
        # The window narrows to the last day; the other two can never return.
        narrow = over(days[-1], f"{days[-1]} 23:59:59", session)
        if len(session.files) != 1:
            failures.append(f"retain: {len(session.files)} readers kept after the "
                            f"window narrowed to one day")
        if narrow.selection.total_messages != 4:
            failures.append(f"retain: narrowed count is "
                            f"{narrow.selection.total_messages}, expected 4")
        # Widening again must rebuild them and reach the same answer as before.
        again = over(days[0], f"{days[-1]} 23:59:59", session)
        if again.selection.total_messages != wide.selection.total_messages:
            failures.append(f"retain: re-widening gave "
                            f"{again.selection.total_messages}, first pass gave "
                            f"{wide.selection.total_messages}")
        if len(session.files) != 3:
            failures.append("retain: re-widening did not rebuild the readers")
        # A one-shot run has no session, so nothing to evict and nothing to keep.
        solo = over(days[0], f"{days[-1]} 23:59:59", None)
        if solo.selection.total_messages != wide.selection.total_messages:
            failures.append("retain: a session disagreed with a one-shot run")

    # --- whole days are taken from the rollup once, not once per tick ------
    argv = ["-c", "chr", "-e", END, "-m", "50", "-n", "3"]
    session = module.LiveReaders()
    reads = {"n": 0}
    real_get = module.Cache.get

    def counting_get(self, channel, file_date, stat, enter_state, _real=real_get):
        reads["n"] += 1
        return _real(self, channel, file_date, stat, enter_state)

    module.Cache.get = counting_get
    try:
        seen = []
        for tick in range(3):
            rep = module.build_report_data(module.build_parser().parse_args(argv),
                                           session)
            seen.append((reads["n"], rep.selection.reused,
                         rep.selection.total_messages))
            reads["n"] = 0
        first, second, third = seen
        if first[0] == 0:
            failures.append("day memo: nothing was read from the rollup at all")
        elif second[0] or third[0]:
            failures.append(f"day memo: re-read the rollup on later ticks "
                            f"({second[0]}, {third[0]} calls)")
        if not (first[2] == second[2] == third[2]):
            failures.append(f"day memo: counts drifted across ticks "
                            f"{[t[2] for t in seen]}")
        # `reused` must describe this pass, not the session. The connection now
        # outlives the tick, so cache.hits accumulates; counting a second channel
        # through the same session is what tells the two apart.
        if not (first[1] == second[1] == third[1]):
            failures.append(f"day memo: reused count is not per-pass "
                            f"{[t[1] for t in seen]}")
        other = module.build_report_data(module.build_parser().parse_args(
            ["-c", "bon", "-e", END, "-m", "5000", "-n", "1"]), session)
        if session.cache and session.cache[0] is not None:
            hits = session.cache[0].hits
            row = next((r for r in other.presentation.rows if r.label == "cache"),
                       None)
            if row is None:
                failures.append("cache row missing from a cached run")
            elif f"{other.selection.reused:,} day(s) reused" not in row.value:
                failures.append(
                    f"cache row says {row.value!r}; this pass reused "
                    f"{other.selection.reused} day(s) and the session has "
                    f"{hits} cumulative hits -- the row is reporting the session")
            session.cache[0].close()
    finally:
        module.Cache.get = real_get

    # A whole day already memoized must still be re-read when its file changes.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        past = "2026-06-01"
        log = os.path.join(chan, f"chan-{past}.log")
        with open(log, "w") as handle:
            handle.write(f"# Start logging at {past} 00:00:00 EDT\n")
            handle.write("[12:00:00] chan is live!\n[12:00:01] alice: one\n")
        cache_path = os.path.join(tmp, "rollup.db")
        saved = module.DEFAULT_CACHE_PATH
        module.DEFAULT_CACHE_PATH = cache_path
        try:
            session = module.LiveReaders()

            def whole_day():
                rep = module.build_report_data(module.build_parser().parse_args(
                    ["--no-config", "-d", tmp, "-c", "chan", "-m", "1",
                     "-b", past, "-e", f"{past} 23:59:59"]), session)
                return rep.selection.total_messages

            whole_day()                       # populates cache and memo
            if whole_day() != 1:
                failures.append("day memo: a settled day changed under a repeat read")
            time.sleep(0.01)
            with open(log, "a") as handle:
                handle.write("[12:00:02] alice: two\n")
            after = whole_day()
            if after != 2:
                failures.append(f"day memo: served a stale day after the file grew "
                                f"({after} messages, expected 2)")
            if session.cache and session.cache[0] is not None:
                session.cache[0].close()
        finally:
            module.DEFAULT_CACHE_PATH = saved

    # --- log_files keeps dated logs and nothing else -----------------------
    # Chatterino writes <channel>-<streamID>.log beside the dated ones, whose
    # lines duplicate them exactly (LoggingChannel::addMessage); counting both
    # would double every message.
    with tempfile.TemporaryDirectory() as tmp:
        for name in ("chan-2026-07-15.log", "chan-2026-07-16.log",
                     "chan-51234567890.log",   # a stream log: same lines, dedup'd out
                     "chan-20260715.log",      # a stream id that reads like a date
                     "chan-2026-13-45.log",    # well-shaped, not a real date
                     "chan-2026-02-30.log",    # nor is this one
                     "chan-2026-7-5.log",      # unpadded: not the shape Chatterino writes
                     "notes.txt", "chan.log"):
            open(os.path.join(tmp, name), "w").close()
        try:
            found = module.log_files(tmp)
        except Exception as exc:
            found = []
            failures.append(f"log_files raised on a mixed directory: "
                            f"{type(exc).__name__}: {exc}")
        got = sorted(os.path.basename(p) for _, p in found)
        want = ["chan-2026-07-15.log", "chan-2026-07-16.log"]
        if got != want:
            failures.append(f"log_files kept {got}, expected {want}")
        if [d for d, _ in found] != [datetime.date(2026, 7, 15),
                                     datetime.date(2026, 7, 16)]:
            failures.append(f"log_files dates wrong: {[d for d, _ in found]}")

    # --- a watch session opens one cache connection, not one per tick ------
    opens = {"n": 0}
    real_open = module.Cache.open

    def counting_open(path, rebuild=False, channel=None):
        opens["n"] += 1
        return real_open(path, rebuild, channel)

    module.Cache.open = staticmethod(counting_open)
    try:
        argv = ["-c", "chr", "-e", END, "-m", "50", "-n", "3"]
        session = module.LiveReaders()
        for _ in range(4):
            rep = module.build_report_data(module.build_parser().parse_args(argv), session)
        if opens["n"] != 1:
            failures.append(f"session cache: opened {opens['n']}x over 4 ticks")
        if session.cache is None or session.cache[0] is None:
            failures.append("session cache: not kept on the readers")
        else:
            # A tick borrows it, so leaving the pass must not have closed it.
            try:
                session.cache[0].connection.execute("SELECT 1")
            except Exception as exc:
                failures.append(f"session cache: a tick closed what it borrowed "
                                f"({type(exc).__name__})")
            session.cache[0].close()

        # A one-shot run owns its connection, and the lease closes it on the way
        # out -- nothing outside select_rows has to remember to.
        opens["n"] = 0
        solo = module.build_report_data(module.build_parser().parse_args(argv))
        if opens["n"] != 1:
            failures.append(f"one-shot run opened the cache {opens['n']}x")
        if solo.selection.cache is None:
            failures.append("one-shot run reported no cache at all")
        else:
            try:
                solo.selection.cache.connection.execute("SELECT 1")
                failures.append("one-shot run left its connection open")
            except Exception:
                pass                       # closed, as the lease promises
            # The header still reads it after the close.
            if not isinstance(solo.selection.cache.hits, int):
                failures.append("a closed cache lost the counters the header needs")
    finally:
        module.Cache.open = real_open

    # --- the config is parsed once a session, but an edit still lands ------
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "c.toml")
        with open(path, "w") as handle:
            handle.write("min_count = 7\n")
        argv = ["-c", "chr", "-e", END, "--config", path]
        session = module.LiveReaders()
        parses = {"n": 0}
        real_load = module.load_config

        def counting_load(p, explicit, _real=real_load):
            parses["n"] += 1
            return _real(p, explicit)

        module.load_config = counting_load
        try:
            args = module.build_parser().parse_args(argv)
            first = module.load_config_layer(args, session)
            for _ in range(5):
                module.load_config_layer(args, session)
            if parses["n"] != 1:
                failures.append(f"config: parsed {parses['n']}x over 6 unchanged reads")
            if first.values.get("min_count") != 7:
                failures.append(f"config: read {first.values!r}")
            # Editing it mid-session must take effect, as re-reading always did.
            time.sleep(0.01)
            with open(path, "w") as handle:
                handle.write("min_count = 9\n")
            again = module.load_config_layer(args, session)
            if again.values.get("min_count") != 9:
                failures.append(f"config: an edit was not picked up ({again.values!r})")
            # No session means no memo.
            before = parses["n"]
            module.load_config_layer(args)
            module.load_config_layer(args)
            if parses["n"] != before + 2:
                failures.append("config: memoized without a session to hold it")
        finally:
            module.load_config = real_load

    # --- the directory listing is memoized, and invalidated by the directory
    # The risk this trades for speed is a stale listing: a session that misses
    # midnight rollover would silently stop counting the new day forever. So the
    # invalidation matters more than the hit rate, and is asserted first.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)

        def write(day, lines=3):
            with open(os.path.join(chan, f"chan-{day}.log"), "a") as handle:
                for n in range(lines):
                    handle.write(f"[00:0{n}:10] alice: hi {n}\n")

        write("2026-07-28")
        readers = module.LiveReaders()
        scans = {"n": 0}
        real = module.log_files

        def counting(directory, _real=real):
            scans["n"] += 1
            return _real(directory)

        module.log_files = counting
        try:
            first = module.log_files_for(chan, readers)
            if scans["n"] != 1 or len(first) != 1:
                failures.append(f"listing: first call scanned {scans['n']}x, "
                                f"found {len(first)}")
            # A repeat with nothing changed must not rescan.
            module.log_files_for(chan, readers)
            module.log_files_for(chan, readers)
            if scans["n"] != 1:
                failures.append(f"listing: an unchanged directory rescanned "
                                f"({scans['n']} scans)")

            # Chatterino appending to today's log must NOT invalidate, or the memo
            # never holds during a live stream -- the whole point of it.
            write("2026-07-28")
            module.log_files_for(chan, readers)
            if scans["n"] != 1:
                failures.append(
                    "listing: appending to a log invalidated the memo -- correct "
                    "but inert, the optimization cannot hold on this filesystem")

            # A new day's file MUST invalidate, or a session stops at midnight.
            write("2026-07-29")
            after = module.log_files_for(chan, readers)
            if scans["n"] != 2:
                failures.append("listing: a new log file did not invalidate the memo")
            if len(after) != 2:
                failures.append(f"listing: new file not picked up, saw {len(after)}")

            # So must a removal.
            os.remove(os.path.join(chan, "chan-2026-07-29.log"))
            gone = module.log_files_for(chan, readers)
            if len(gone) != 1:
                failures.append(f"listing: removal not picked up, saw {len(gone)}")

            # No readers means no memo: a one-shot run keeps its old behaviour.
            before = scans["n"]
            module.log_files_for(chan, None)
            module.log_files_for(chan, None)
            if scans["n"] != before + 2:
                failures.append("listing: memoized without a session to hold it")

            # A directory that cannot be stat'd must fall back, not serve a stale
            # answer -- os.stat is the only thing standing between the two.
            missing = os.path.join(tmp, "gone")
            try:
                module.log_files_for(missing, readers)
                failures.append("listing: a missing directory should still raise")
            except OSError:
                pass
        finally:
            module.log_files = real

        # End to end: a counting pass over a session must see a file that appears
        # after the readers were primed.
        args = module.build_parser().parse_args(
            ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
             "-b", "2026-07-28", "-e", "2026-07-30 23:59:59"])
        live = module.LiveReaders()
        one = module.build_report_data(args, live)
        if one.selection.cache is not None:
            one.selection.cache.close()
        write("2026-07-30", lines=4)
        two = module.build_report_data(args, live)
        if two.selection.cache is not None:
            two.selection.cache.close()
        if two.selection.files != one.selection.files + 1:
            failures.append(f"listing: a new day did not reach the count "
                            f"({one.selection.files} -> {two.selection.files} files)")
        if two.selection.total_messages != one.selection.total_messages + 4:
            failures.append(f"listing: new day's messages missing "
                            f"({one.selection.total_messages} -> "
                            f"{two.selection.total_messages})")

    # --- an unreadable log is skipped, never fatal, and never silent -------
    # One bad file used to end the whole query with a traceback, losing every
    # other day and breaking the documented --json failure shape.
    with tempfile.TemporaryDirectory() as tmp:
        chan = os.path.join(tmp, "chan")
        os.makedirs(chan)
        days = ["2026-07-28", "2026-07-29", "2026-07-30"]
        for day in days:
            with open(os.path.join(chan, f"chan-{day}.log"), "w") as handle:
                handle.write(f"# Start logging at {day} 00:00:00 EDT\n")
                handle.write("[00:00:05] chan is live!\n")
                for n in range(5):
                    handle.write(f"[00:0{n}:10] alice: hello {n}\n")

        def count(argv=()):
            report = module.build_report_data(module.build_parser().parse_args(
                ["--no-config", "--no-cache", "-d", tmp, "-c", "chan", "-m", "1",
                 "-b", days[0], "-e", f"{days[-1]} 23:59:59"] + list(argv)))
            if report.selection.cache is not None:
                report.selection.cache.close()
            return report

        whole = count()
        if whole.selection.total_messages != 15:
            failures.append(f"fixture: expected 15 messages, got "
                            f"{whole.selection.total_messages}")
        blocked = os.path.join(chan, f"chan-{days[1]}.log")
        os.chmod(blocked, 0o000)
        try:
            partial = count()
        except Exception as exc:
            partial = None
            failures.append(f"an unreadable log ended the query: "
                            f"{type(exc).__name__}: {exc}")
        finally:
            os.chmod(blocked, 0o644)
        if partial is not None:
            if partial.selection.total_messages != 10:
                failures.append(f"unreadable log: expected the other 10 messages, "
                                f"got {partial.selection.total_messages}")
            if len(partial.selection.unreadable) != 1:
                failures.append(f"unreadable log was not recorded: "
                                f"{partial.selection.unreadable}")
            rows = {row.label: row for row in partial.presentation.rows}
            if "unreadable" not in rows:
                failures.append("a skipped log produced no header row")
            elif not rows["unreadable"].compact:
                failures.append("a skipped log is invisible in the compact header")
            doc = module.build_report(partial)
            if len(doc["totals"]["unreadable"]) != 1:
                failures.append(f"JSON did not report the skipped log: "
                                f"{doc['totals']['unreadable']}")
            # A complete count must stay quiet about it.
            if module.build_report(whole)["totals"]["unreadable"]:
                failures.append("a complete count claimed something was unreadable")
            if any(r.label == "unreadable" for r in whole.presentation.rows):
                failures.append("a complete count grew an 'unreadable' header row")

    # --- one aligner, used by both the header block and the table ----------
    widths = module.column_widths([["a", "bbbb"], ["ccc", "d"]])
    if widths != [3, 4]:
        failures.append(f"column_widths: got {widths}, expected [3, 4]")
    if module.column_widths([["a", "bbbb"]], caps=(None, 2)) != [1, 2]:
        failures.append("column_widths: a cap did not bound the column")
    if module.align_row(["a", "b"], [3, 4]) != "a    b":
        failures.append(f"align_row left: {module.align_row(['a', 'b'], [3, 4])!r}")
    if module.align_row(["a", "b"], [3, 4], align="lr") != "a       b":
        failures.append(f"align_row lr: {module.align_row(['a', 'b'], [3, 4], 'lr')!r}")
    if module.align_row(["a"], []) != "a":
        failures.append("align_row: a cell with no width should print bare")

    # --- columns join the list at most once --------------------------------
    # Stated against the operation rather than through one invocation, because
    # the duplicate came from the one caller that added a column without asking
    # whether it was already there.
    for start, name, before, want in (
        (["live", "offline", "offline-share"], "unknown", "offline-share",
         ["live", "offline", "unknown", "offline-share"]),
        (["live", "offline", "unknown", "offline-share"], "unknown", "offline-share",
         ["live", "offline", "unknown", "offline-share"]),   # already present
        (["live"], "unknown", "offline-share", ["live", "unknown"]),  # anchor absent
        (["live"], "count", None, ["live"]),                 # count is implicit
        (["live"], "offline", None, ["live", "offline"]),
    ):
        got = module.add_column(list(start), name, before)
        if got != want:
            failures.append(f"add_column({start}, {name!r}, {before!r}) -> {got}, "
                            f"expected {want}")

    for argv in (["-B", "--show", "unknown"], ["-B", "--show", "unknown,live"],
                 ["-B", "--show", "offline-share"], ["-B"], ["--show", "live,live"]):
        report = module.build_report_data(module.build_parser().parse_args(
            ["-c", "bon", "-e", END, "-n", "1"] + argv))
        if report.selection.cache is not None:
            report.selection.cache.close()
        columns = report.presentation.columns
        if len(columns) != len(set(columns)):
            failures.append(f"{' '.join(argv)}: duplicate column in {columns}")

    # Every JSON field must resolve against a real Report. The flat dict this
    # replaced was hand-maintained, so a renamed record field failed only at the
    # moment someone ran --json.
    report = module.build_report_data(module.build_parser().parse_args(
        ["-c", "chr", "-e", END, "-n", "2"]))
    if report.selection.cache is not None:
        report.selection.cache.close()
    for table, label in ((module.QUERY_FIELDS, "query"),
                         (module.TOTALS_FIELDS, "totals")):
        for field in table:
            try:
                field.get(report)
            except Exception as exc:
                failures.append(f"{label}.{field.name} does not resolve: "
                                f"{type(exc).__name__}: {exc}")

    # --- JSON must distinguish the three share-floor states -----------------
    # A bare integer could not: an ignored --share-floor read the same as one
    # nobody set, while `sources` insisted a flag had supplied it.
    for argv, want, why in (
        (["--share-floor", "400", "--sort", "count"], (400, False), "asked for, no share"),
        (["--share-floor", "400", "--sort", "offline-share"], (400, True), "acting"),
        (["--share-floor", "0", "-B"], (0, False), "explicitly disabled"),
    ):
        report = module.build_report_data(module.build_parser().parse_args(
            ["-c", "chr", "-e", END, "-m", "1", "-n", "2"] + argv))
        if report.selection.cache is not None:
            report.selection.cache.close()
        # Guarded so a field broken elsewhere is reported by the resolution check
        # above rather than aborting the run before any failure is printed.
        try:
            floor = module.build_report(report)["query"]["share_floor"]
        except Exception as exc:
            failures.append(f"share_floor {why}: building the report raised "
                            f"{type(exc).__name__}: {exc}")
            continue
        got = (floor["requested"], floor["applied"])
        if got != want:
            failures.append(f"share_floor {why}: got {got}, expected {want}")

    # --- a broken cache must fail open, but never fail silent --------------
    # An unusable cache costs 17x on a large channel and used to look exactly
    # like a healthy run. Failing open is right; failing without a word is not.
    with tempfile.TemporaryDirectory() as tmp:
        broken = os.path.join(tmp, "sub", "rollup.db")
        os.makedirs(os.path.dirname(broken))
        with open(broken, "wb") as handle:
            handle.write(b"definitely not a sqlite file" * 40)
        cache, problem = module.Cache.open(broken)
        if cache is not None:
            failures.append("Cache.open on a corrupt file should decline")
            cache.close()
        if not problem:
            failures.append("Cache.open failed without saying why")
        elif "connect" not in problem:
            failures.append(f"cache problem should name the step, got {problem!r}")

        # A query still runs, and the header still says the cache is gone -- in
        # compact too, which is the mode --watch defaults to.
        saved = module.DEFAULT_CACHE_PATH
        module.DEFAULT_CACHE_PATH = broken
        try:
            report = module.build_report_data(module.build_parser().parse_args(
                ["-c", "chr", "-e", END, "-n", "2", "--header", "compact"]))
        finally:
            module.DEFAULT_CACHE_PATH = saved
        if report.selection.cache is not None:
            report.selection.cache.close()
        if not report.selection.cache_problem:
            failures.append("a run over a broken cache did not record the problem")
        rows = {row.label: row for row in report.presentation.rows}
        if "cache" not in rows:
            failures.append("a broken cache produced no header row at all")
        elif not rows["cache"].compact:
            failures.append("a broken cache is invisible in the compact header")
        elif rows["cache"].compact not in module.compact_header(report):
            failures.append("the cache warning did not reach the compact header")

    # --- fade curves -------------------------------------------------------
    # k = 1 is the identity for every curve, which is what makes naming one
    # harmless: the fade stays linear until a k is actually chosen. If this ever
    # fails, changing fade_curve alone silently repaints every watch session.
    for name, fn in module.CURVES.items():
        if max(abs(fn(i / 200, 1.0) - i / 200) for i in range(201)) > 1e-9:
            failures.append(f"curve {name!r} is not the identity at k=1")
        for k in (0.25, 2.0, 6.0):
            values = [fn(i / 200, k) for i in range(201)]
            if abs(values[0]) > 1e-9 or abs(values[-1] - 1.0) > 1e-9:
                failures.append(f"curve {name!r} at k={k:g} does not span 0..1")
            if any(b < a - 1e-12 for a, b in zip(values, values[1:])):
                failures.append(f"curve {name!r} at k={k:g} is not monotone")
            if any(v < -1e-12 or v > 1 + 1e-12 for v in values):
                failures.append(f"curve {name!r} at k={k:g} leaves 0..1")

    # The default settings must produce exactly the ramp the linear formula did,
    # or every existing config silently changes appearance on upgrade.
    seed = (0x87, 0xff, 0x87)
    expected = tuple(
        "\033[38;2;{};{};{}m".format(
            *(round(c + (255 - c) * (i / 36)) for c in seed))
        for i in range(36)
    )
    if module.hex_ramp(seed, 36) != expected:
        failures.append("default hex_ramp no longer matches the linear ramp")

    # A rule inherits the global curve unless it names its own.
    watch_cfg = {"watch": {
        "shades": 36, "fade_curve": "power", "fade_k": 2.0,
        "highlight": [
            {"color": "#ff87ff", "match": ["a"]},
            {"color": "#87ffff", "match": ["b"], "curve": "ease-out", "k": 3},
        ],
    }}
    watch = module.resolve_watch(
        module.build_parser().parse_args(["-c", "chr", "-w"]), watch_cfg, "<unit>")
    if watch.ramps["highlight0"] != module.hex_ramp((0xff, 0x87, 0xff), 36, "power", 2.0):
        failures.append("highlight rule did not inherit the global fade curve")
    if watch.ramps["highlight1"] != module.hex_ramp((0x87, 0xff, 0xff), 36, "ease-out", 3.0):
        failures.append("highlight rule did not use its own fade curve")
    if watch.ramps["up"] == module.hex_ramp((0x87, 0xff, 0x87), 36):
        failures.append("the global fade curve never reached the rise ramp")

    # k <= 0 breaks every curve, and a ramp bunched into one colour is a config
    # error rather than a fade that silently stops fading.
    for section, why in (
        ({"shades": 36, "fade_k": 0}, "fade_k = 0"),
        ({"shades": 36, "fade_k": -1}, "negative fade_k"),
        ({"shades": 36, "fade_curve": "wobble"}, "unknown curve"),
        ({"shades": 36, "fade_curve": "power", "fade_k": 400}, "collapsed ramp"),
        ({"shades": 36, "highlight": [{"color": "#f00", "match": ["a"], "k": 0}]},
         "per-rule k = 0"),
    ):
        try:
            module.resolve_watch(module.build_parser().parse_args(["-c", "chr", "-w"]),
                                 {"watch": section}, "<unit>")
            failures.append(f"resolve_watch accepted {why}")
        except (module.ConfigError, argparse.ArgumentTypeError):
            pass

    # --- the compact header is a projection, not a second implementation ---
    # Stated as a rule rather than a recorded string: anything that removes users
    # from the table has to survive into the one-line header, or the short table
    # it produces is unexplainable. The share floor is how this broke before.
    report = module.build_report_data(module.build_parser().parse_args(
        ["-c", "chr", "-e", END, "--sort", "offline-share", "--share-floor", "400",
         "-m", "1", "--header", "compact"]))
    if report.selection.cache is not None:
        report.selection.cache.close()
    rows = report.presentation.rows
    compact = module.compact_header(report)

    if not report.presentation.below_floor:
        failures.append("compact header check: fixture dropped nobody, so it proves nothing")
    for label in ("share floor", "sort", "threshold", "channel"):
        row = next((r for r in rows if r.label == label), None)
        if row is None:
            failures.append(f"header row {label!r} missing from the table")
        elif not row.compact:
            failures.append(f"header row {label!r} has no compact form")
        elif row.compact not in compact:
            failures.append(f"header row {label!r} did not reach the compact header")

    # Full-only rows must stay out of it, or compact stops being compact.
    for label in ("logs dir", "config", "cache", "end"):
        row = next((r for r in rows if r.label == label), None)
        if row is not None and row.compact:
            failures.append(f"header row {label!r} should be full-only")

    # Nothing in the compact line may come from anywhere but the table.
    known = {r.compact for r in rows if r.compact}
    for part in compact.split(" · "):
        if part not in known:
            failures.append(f"compact header part {part!r} is not from a header row")
    return failures


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    accept = "--accept" in argv
    unit_only = "--unit" in argv

    module = load_module()
    failures = []
    try:
        unit_checks(module, failures)
    except Exception:
        failures.append("unit_checks raised before finishing:\n"
                        + textwrap.indent(traceback.format_exc(), "    "))
    for failure in failures:
        print(f"UNIT FAIL  {failure}")
    passed_unit = len(failures) == 0
    print(f"unit: {'ok' if passed_unit else str(len(failures)) + ' failed'}")
    if unit_only:
        return 0 if passed_unit else 1

    os.makedirs(SNAPSHOTS, exist_ok=True)
    changed = []
    for name, case_argv in CASES.items():
        actual = capture(case_argv)
        path = os.path.join(SNAPSHOTS, name + ".txt")
        if accept or not os.path.exists(path):
            with open(path, "w") as handle:
                handle.write(actual)
            continue
        with open(path) as handle:
            expected = handle.read()
        if expected != actual:
            changed.append(name)

    if accept:
        print(f"recorded {len(CASES)} snapshots")
        return 0 if passed_unit else 1
    for name in changed:
        print(f"SNAPSHOT DIFF  {name}")
    print(f"characterization: {len(CASES) - len(changed)}/{len(CASES)} unchanged")
    return 0 if passed_unit and not changed else 1


if __name__ == "__main__":
    sys.exit(main())
