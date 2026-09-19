#!/usr/bin/env python3
"""Count Chatterino-logged chat messages per user for a channel over a time range.

Log layout:  <logs-dir>/<channel>/<channel>-YYYY-MM-DD.log
Line format: [HH:MM:SS] <name>: <message>

The date comes from the filename, the time from the line, so timestamps are
naive local time -- the same clock Chatterino wrote them with.

Every setting is a named flag; there are no positional arguments. Values resolve
in this order, first hit wins:

    CLI flag  ->  environment variable  ->  config file  ->  built-in default

{{ENVIRONMENT}}

Row count is capped with --top N (0 means unlimited). Left unset, output to a
terminal is trimmed to what fits the window while piped or redirected output
stays complete, and a "+ N others" row always accounts for what the cap hid.

Ranges accept ISO 8601 weeks wherever a date works: '2026-W31' is Monday 00:00:00
for --begin and Sunday 23:59:59 for --end, extending the existing start-of-period
/ end-of-period rule one granularity up, and '2026-W31-3' picks a single weekday.
The week-numbering year is not the calendar year at the edges -- 2026-W01 begins
2025-12-29 -- so the header's resolved begin/end is worth a glance in January.

--users N sizes the window instead of naming it: the range widens until N users
meet --min-count, and that width is then held for the life of the run, rolling
like --since rather than resizing. The population it counts is the reported one
-- above --min-count, after exclusions and the share floor -- never the displayed
one, since --top and the terminal height cap the display and would stop the
function being invertible above the cap. Those still apply, afterwards.

The exact count is often unreachable: a user count only rises as the window
widens, so two users crossing --min-count together step it past the number you
asked for, and that number then exists at no width at all. --users-policy says
what to do -- at-least (the narrowest window with at least N, the default),
at-most (the widest with no more than N), or nearest, ties going to the narrower
and fresher window. The header reports both numbers whichever way it settles.
--users-max bounds the search, 24h by default.

Per-user columns beyond the count come from --by-state (live, offline, offline%)
or --show, and --sort orders by any of them. Shares divide by the user's own
total, unknown included, so a user's shares add up to 100%. Showing OR ranking by
a share applies --share-floor (default 10) first, because a one-message user is
100% of something -- the floor follows the number on screen, not the sort, so a
column cannot mean one thing sorted by share and another sorted by login. The
header reports how many it dropped, and reports it too when a --share-floor was
given that no share needed, rather than ignoring the flag in silence. JSON always
carries the per-user state counts and leaves shares to the consumer.

--header chooses how much of the provenance block to print: full (every setting
with its source), compact (one line: channel, window, threshold, state split,
exclusions, sort, share floor and row cap), or none. Both are projections of one
table, so neither can disclose something the other drops. It defaults to compact
under --watch, because the block costs 11 of 24 terminal lines there while 9 of
its rows never change; a [watch] header key overrides that while watching.

While watching, the loop keeps state between frames rather than starting over:
today's log is tailed from a byte offset into per-second buckets, so a redraw
reads only what Chatterino appended and re-derives the sliding window by summing
buckets; and the live/offline state entering the window is remembered instead of
being rescanned from the previous day's log. Together those took a tick from
20.5ms to 2.5ms. A half-written final line is held back until its newline
arrives, and truncation, rotation or a changed entering state start the file
again from scratch.

Every knob either half has -- whether to wake on writes, how many change events
to drain, how far back to look for the entering state -- lives in the [tail]
table of the config (or TWITCH_TAIL_* in the environment):

    [tail]
    notify        = true
    max_events    = 4
    seed_lookback = 30

Everything that differs between operating systems -- where Chatterino keeps its
logs, where config and cache belong, how the program is told a file changed, and
how a file is identified across rotation -- sits behind one Platform interface
with a class per OS, chosen from sys.platform at import. Only macOS is complete;
Linux and Windows are stubs, and they are deliberately shaped so that the parts
that need nothing from the platform keep working:

    macOS    logs/config/cache paths, kqueue notification
    Linux    XDG config and cache paths; logs location and inotify are TODO
    Windows  everything TODO; polling and counting still work

A stub answers a path with None and raises Unsupported from a capability at the
point of use, never at import, so --help, --manual, the completion helpers and
plain counting with --logs-dir all work on every platform. The error names both
the gap and the way round it: "TODO - not implemented: change notification on
Linux. set [tail] notify = false to poll on the interval instead". The interface
is also injectable, so each stub can be driven and asserted in tests rather than
being taken on trust.

Waking is event-driven where the platform allows: kqueue reports a write to a
watched log and the loop redraws immediately rather than at the next tick. The
timer still runs, and must -- with a rolling --since window the counts change
with the clock alone, as messages age out of the trailing edge, and the tint fade
is time-driven too. So a write shortens the wait; it does not replace it.

On launch the first frame is not blank: the readers already hold per-second
buckets, so the last `hold` seconds are replayed through the same colorizer the
live loop uses, and the frame arrives with each row already at the shade its last
activity earns. Capped by [watch] replay_steps (0 disables); skipped for a fixed
--begin/--end range, which cannot have moved.

--watch [SECONDS] redraws the report until interrupted. A row turns light green
when its count rises and light grey when it falls, then holds that tint before
returning to plain, stepping one shade dimmer every 1/N of the hold (N being the
length of the fade ramp). The hold is wall-clock, not frames, so it means the
same thing at any interval; 0 holds a tint indefinitely. A row that has never
moved stays plain.

A row can be recoloured by what was said. [[watch.highlight]] rules pair a hex
colour with patterns, and colour is decided by one ladder, each rung superseding
the ones above it:

    falling  <  rising  <  rule 1  <  rule 2  <  ...  (config order)

So a rule beats both the rise and the fall colour -- a falling row whose author
said something notable wears the rule's colour, not grey -- and a later rule beats
an earlier one, both within a single message and across a row's matches. Priority
is the rule's position, not how recently it matched: an older message matching a
later rule still wins. A rule stays in force while its match is within the hold:

    [[watch.highlight]]
    color = "#0000ff"
    match = ["(?i)cc", "(?i)chron"]

The colour is ramped exactly as fade_up and fade_down are, so a highlighted row
ages and expires exactly as an ordinary one does. Hex needs a
24-bit terminal. Message text is matched where it is already parsed and would
otherwise be discarded, so this costs no extra read. The ladder is applied on
every frame rather than frozen when a tint is assigned, so a rule that starts
applying recolours a tint already in flight.

Rises outrank falls: a row already holding a green is left alone when its count
falls, so an active chatter never flips grey because an old message aged out of a
rolling window -- which otherwise hits the busiest rows hardest, since their
messages age out fastest. The green keeps fading on its original clock, so the
row never looks fresher than it is, and it expires to plain rather than to grey.
A rise still overrides a grey immediately.

Every number watch mode uses -- the interval, its floor, the hold, the colours
and the shade count -- lives in the [watch] table of the config, so none of it is
a literal buried in the code:

    [watch]
    interval     = 1.0
    min_interval = 0.1
    hold         = 3.0
    fade_up      = "#87ff87"
    fade_down    = "#8a8a8a"
    shades       = 3
    fade_curve   = "linear"
    fade_k       = 1.0
    user_width   = 20
    full_repaint = 50
    show_timing  = false
    tint_falling = true
    min_redraw   = 0.25
    streamer_mode = false

Rise, fall and every [[watch.highlight]] colour are specified and ramped
identically: one hex triple faded towards the foreground over `shades` steps.
There is one palette mechanism, so they cannot age differently or need separate
explanation.

`hold` sets how long a tint lives and nothing else. How far back a reader keeps
its buckets is the launch replay's reach -- interval x replay_steps -- because
that is the only thing that ever reads them back. The two shared one number
until hold = 0, documented as "the tint never fades", was found to switch off
the cold-read seek and the pruning as a side effect.

A cold read seeks to the window rather than parsing the day to reach it: the log
is chronological, so the first line of a --since window is found by searching
back from the end, and the live/offline state entering it is recovered from the
markers in the part skipped. On a 1.6MB day answering a 7-minute question that
is 329ms and 36,475 buckets down to 26ms and 380. A reader that skipped anything
is partial, so its day is never written to the rollup as though it were whole.

[watch] min_redraw floors how often a log write may force a redraw. The watcher
fires on every append and a busy channel appends several times a second, so
without it the cost of watching scales with how busy the channel is. Arrivals
inside the floor are folded into the next frame rather than lost.

--streamer, or [watch] streamer_mode, drops the content highlights for the run:
the rules stay in the config and stay parsed, so a bad pattern is still an error,
but they colour nothing and record nothing. The header says nothing about them --
a note that highlights exist and are suppressed would be the thing being hidden.
Only the highlights; the channel and the logins are still on screen.

Ctrl-C is a request rather than a crash: text mode exits quietly, --json still
gets {"error": "interrupted"}, and the exit code is 130. The rollup connection is
held by a lease that closes it however the pass ends -- returning, raising or
interrupted -- so nothing outside the counting pass has to remember to.

The status line holds still unless [watch] show_timing is set: the tick time and
wake source it used to carry changed every frame, so that single line forced a
write per tick however still the report was. A tick slower than the interval
still reports itself. [watch] tint_falling turns the grey off for rows whose
count fell, which on a rolling window usually means the window slid rather than
anything a user did.

Waking is scheduled rather than polled: a tint only looks different when its age
crosses a multiple of hold/shades, and both that and its expiry are known when it
is assigned, so the loop waits for the next one instead of polling past it. That
decouples how smooth the fade is from how often the loop wakes -- `interval` now
only bounds how stale an unannounced change may be, since arrivals come from the
watcher and shade steps come from the schedule.

A redraw sends only the lines that changed, addressed absolutely, rather than
rewriting the frame: on a 31-line frame at --watch 0.2 seven lines moved on a
median tick, and the difference is paid by the terminal rather than by this
process -- 7,993 to 1,374 bytes a second, 191 to 22 line rewrites. Because a
painter that believes something wrong about the screen stays wrong, the whole
frame is restated on the first paint, on a width change, and every
`full_repaint` frames.

The user column is pinned to `user_width` characters while watching, and sized
from the rows on screen when it is 0 or when the report is one-shot. Sized from
the rows it moves whenever the widest visible login changes, sliding every count
beside it: measured at 118 shifts across a replayed day of the busiest channel
here. Twitch logins stop at 25 characters -- LOGIN_RE enforces it -- so 25 never
clips and 20 clipped nothing across either channel's history; narrower widths cut
with an ellipsis.

fade_curve and fade_k skew where along that ramp each shade sits -- linear,
power, ease-out, bias or ease-in-out, all of which are the identity at k = 1, so
naming a curve changes nothing until a k is chosen. k > 1 holds the colour and
then drops it; k < 1 dumps it at once and leaves a long pale tail. `hold` still
bounds every tint whatever the curve, so only the path within it is skewed, and
rows still expire together.

The curve bends the palette, not the clock: the fade still advances one shade per
1/N of the hold, and the ramp decides what that shade looks like. So the watch
loop, the launch replay and each rule's own ramp all inherit it from the ramp
they already read, and no per-row work is added. The cost is resolution -- a
large k bunches shades until neighbours round to the same RGB, which is why a
ramp that collapses to a single colour is refused rather than rendered.

A [[watch.highlight]] rule may carry its own `curve` and `k`; either one absent
inherits the [watch] value. Each rule already builds its own ramp, so this is a
per-rule argument rather than a second fade mechanism.

Those resolve like every other setting, through one rule: CLI -> TWITCH_WATCH_*
-> [watch] -> a top-level key of the same name -> built-in. The watch status line
names which layer supplied the interval and hold. The same mechanism gives
--header its [watch] override, so no setting needs a precedence chain of its own. Falls need a rolling window to happen at all:
logs are append-only, so a fixed --begin/--end only ever holds steady, while
--since (or --end defaulting to now) sheds messages from the trailing edge as
they age out. Redrawing homes the
cursor and erases line by line rather than clearing the screen, which is what
keeps it from flickering, and long lines are clipped so nothing wraps.

--json emits one document on stdout carrying its own JSON Schema (2020-12) under
"schema", so a downstream consumer needs nothing external to know what the fields
mean. Payload and schema are generated from one field table, so they cannot
disagree. Row caps never come from the terminal in this mode, diagnostics stay on
stderr, and a failure is reported there as {"error": "..."} with a non-zero exit.

Parsed logs are cached as a per-day rollup in ~/.cache/twitch-counts/rollup.db,
which turns a full count of the busiest channel here from ~7s into ~0.3s. Days
inside the range come from the cache; the partial days at each edge are parsed,
so at most two files are read. A cached day is used only when its log file has
the same size and mtime AND the live/offline state entering the file matches,
since a day with no markers of its own inherits its classification.

The cache invalidates itself. Its fingerprint hashes the STRUCTURE -- the AST,
docstrings stripped -- of every pattern and function listed in CACHE_INPUTS, so
changing what gets counted invalidates while rewording a comment or docstring
does not. When a change alters what is counted or how a message is classified,
add what carries that logic to CACHE_INPUTS.

Rows are tagged with the fingerprint that produced them rather than the whole
cache being discarded on a mismatch, so two versions of the script -- an editor
and a long-running --watch -- coexist instead of destroying each other's rows on
every open. A generation unseen for CACHE_KEEP_DAYS is swept. Bypass with
--no-cache, discard a channel with --rebuild-cache.

Messages are classified live or offline from the "<channel> is live!" and
"<channel> is now offline." markers Chatterino writes, with the state carried
across day boundaries and seeded from earlier files when a range opens
mid-stream. Chat that no marker can place reports as 'unknown' rather than being
assumed offline. Filter with --live/--offline/--unknown, or state = "live" in
the config; the header always shows the split.

Config file (TOML, default ~/.config/twitch-counts.toml):

    logs_dir  = "/path/to/Logs/Twitch/Channels"
    channel   = "chroniccmposer"
    min_count = 50
    since     = "30d"

    [aliases]
    chr = "chroniccmposer"

    # Either a flat list...
    exclude = ["streamelements", "supibot"]

    # ...or named groups, with `always` naming the ones applied by default.
    [exclude]
    bots   = ["streamelements", "supibot", "fossabot", "nightbot"]
    always = ["bots"]

Exclusions are the one setting whose layers ADD rather than override: a one-off
--exclude keeps the config's list in force, because dropping your bot list to
name one extra user is never what you meant. --include subtracts from the merged
set for a single run, and --no-exclude clears it entirely.

Because defaults and config can supply values you did not type, the report header
names the source of every setting it used.

Fish completions are generated from this parser, so they cannot fall out of step
with it. Install (and reinstall after adding a flag) with:

    twitch-counts --emit-fish-completions > ~/.config/fish/completions/twitch-counts.fish

The generated file asks the script itself for candidate channels, exclude groups,
dates and users via the hidden --complete flag, so completion honors the same
config, aliases and environment as a real run.
"""

import argparse
import ast
import bisect
import functools
import hashlib
import inspect
import json
import os
import re
import select
import shutil
import sqlite3
import sys
import textwrap
import time as clock  # 'time' below is datetime.time, so the module needs a name
import tomllib
from collections import Counter
from typing import NamedTuple
from datetime import date, datetime, time, timedelta

class Unsupported(Exception):
    """Something this platform has not implemented yet.

    Raised at the point of use, never at import: --help, --manual and the
    completion helpers say nothing about the filesystem and must work on every
    platform, including ones where nothing else does.
    """


class Platform:
    """What the tool needs to know about the host: where files live, and how it
    learns they changed.

    Only what genuinely varies belongs here. Opening, seeking and reading, the
    SQLite rollup and the per-day filename convention are the same everywhere and
    stay outside.

    A subclass that cannot answer returns None for a path and raises Unsupported
    from the capability, so a platform with no change notification can still
    count -- it simply cannot --watch with notify on.
    """

    name = "unknown"
    logs_hint = None     # where Chatterino is believed to keep logs, for the error

    def logs_dir(self):
        return None

    def config_path(self):
        return None

    def cache_path(self):
        return None

    def file_identity(self, stat):
        """Identity of a file, for telling rotation from growth.

        Portable in modern Python, so it is implemented once here rather than per
        platform. Worth keeping behind the interface anyway: Windows has
        historically reported st_ino as 0 on some filesystems, and a wrong answer
        here is silent -- a rotated log gets tailed as though it had only grown.
        """
        return (stat.st_dev, stat.st_ino)

    def watcher(self, notify=True, max_events=None):
        """A change watcher, or a polling one when notification is switched off."""
        if not notify:
            return PollingWatcher(max_events)
        raise Unsupported(self.todo(
            "change notification",
            "set [tail] notify = false to poll on the interval instead"))

    def todo(self, what, remedy=None):
        message = f"TODO - not implemented: {what} on {self.name}"
        return f"{message}. {remedy}" if remedy else message

    def require_logs_dir(self):
        """The logs directory, or a clear error naming the way round it."""
        found = self.logs_dir()
        if found:
            return found
        hint = f" Chatterino is believed to use {self.logs_hint}." if self.logs_hint else ""
        raise Unsupported(self.todo(
            "the default Chatterino log location",
            f"pass --logs-dir, or set logs_dir in the config.{hint}"))


class MacOS(Platform):
    name = "macOS"

    def logs_dir(self):
        return os.path.expanduser(
            "~/Library/Application Support/chatterino/Logs/Twitch/Channels")

    def config_path(self):
        return os.path.expanduser("~/.config/twitch-counts.toml")

    def cache_path(self):
        return os.path.expanduser("~/.cache/twitch-counts/rollup.db")

    def watcher(self, notify=True, max_events=None):
        if not notify:
            return PollingWatcher(max_events)
        return KqueueWatcher(max_events)


class Linux(Platform):
    """Paths follow the XDG spec, which is a real answer; the rest is TODO."""

    name = "Linux"
    logs_hint = "~/.local/share/chatterino/Logs/Twitch/Channels"

    def _xdg(self, variable, fallback, tail):
        base = os.environ.get(variable) or os.path.expanduser(fallback)
        return os.path.join(base, tail)

    def config_path(self):
        return self._xdg("XDG_CONFIG_HOME", "~/.config", "twitch-counts.toml")

    def cache_path(self):
        return self._xdg("XDG_CACHE_HOME", "~/.cache", "twitch-counts/rollup.db")

    # TODO - not implemented: logs_dir(). The path above is believed correct but
    # unverified, and guessing wrong is worse than asking, so require_logs_dir()
    # raises and names --logs-dir.
    # TODO - not implemented: watcher(). inotify via select.poll on an
    # inotify_init fd, or the third-party inotify_simple; until then Platform's
    # watcher() raises unless notify is off.


class Windows(Platform):
    """Every answer here is still TODO; polling and counting work regardless."""

    name = "Windows"
    logs_hint = r"%APPDATA%\Chatterino2\Logs\Twitch\Channels"

    # TODO - not implemented: config_path() and cache_path() belong under
    # %APPDATA% and %LOCALAPPDATA% rather than the XDG directories, and
    # logs_dir() under %APPDATA%. Unverified, so they stay None and the errors
    # name --config, --logs-dir and --no-cache.
    # TODO - not implemented: watcher(). ReadDirectoryChangesW through pywin32,
    # or a directory poll; until then notify must be off.


PLATFORMS = {"darwin": MacOS, "linux": Linux, "win32": Windows}
# Exact match, not a prefix: an unrecognised platform should report itself
# unsupported rather than be mistaken for one of these.
PLATFORM = PLATFORMS.get(sys.platform, Platform)()

DEFAULT_LOGS_DIR = PLATFORM.logs_dir()
DEFAULT_CONFIG_PATH = PLATFORM.config_path()
DEFAULT_CACHE_PATH = PLATFORM.cache_path()
DEFAULT_MIN_COUNT = 1
# Bump only for changes to the tables themselves; changes to parsing are handled
# per row by the fingerprint, without discarding anything.
CACHE_SCHEMA_VERSION = 2
# Rows from a parser generation unseen for this long are swept at open time.
CACHE_KEEP_DAYS = 7

# Username completion scans a recent window rather than all of history: a full
# scan of the largest channel here takes ~5.3s, which fish would block on at
# every TAB, while seven days costs ~0.2s. The people you want to exclude are
# the ones currently chatting.
USER_COMPLETION_DAYS = 7

# The year/month/day are captured separately so a filename becomes a date with
# three int() calls instead of a strptime, which was the expensive half of
# listing a directory. Chatterino also writes <channel>-<streamID>.log for each
# stream (LoggingChannel::openStreamLogFile) whose lines duplicate these exactly;
# requiring the dashed date shape is what rejects those before any parsing.
FILENAME_RE = re.compile(
    r"^(?P<channel>.+)-(?P<y>\d{4})-(?P<mo>\d{2})-(?P<d>\d{2})\.log$")

# [HH:MM:SS] speaker: message  -- the speaker never contains a colon.
LINE_RE = re.compile(
    r"^\[(?P<h>\d{2}):(?P<m>\d{2}):(?P<s>\d{2})\] (?P<who>[^:]+): (?P<msg>.*)$"
)

# Plain speaker: a Twitch display name that is just the login, possibly capitalized.
LOGIN_RE = re.compile(r"^[A-Za-z0-9_]{1,25}$")

# Localized display name: Chatterino writes "<display> <login>" when the display
# name isn't a case variant of the login (e.g. "반_요다 choco_yoda").
LOCALIZED_RE = re.compile(r"^(?P<display>\S+) (?P<login>[a-z0-9_]{1,25})$")

# Stream state markers, e.g. "[15:15:32] ChronicCmposer is live!". Chatterino
# only writes these while connected, so a transition during one of the many
# disconnects is missed and the state goes stale -- measured against Chatterino's
# own per-stream logs, that costs 0.3% of messages on the busiest channel here.
LIVE_RE = re.compile(r"^\[\d{2}:\d{2}:\d{2}\] \S+ is (?P<state>live!|now offline\.)$")
STATES = ("live", "offline", "unknown")
# Facts about a day, not tunables: making these configurable would be nonsense.
SECONDS_PER_MINUTE = 60
SECONDS_PER_HOUR = 60 * SECONDS_PER_MINUTE
LAST_SECOND_OF_DAY = 24 * SECONDS_PER_HOUR - 1
END_OF_DAY = time(23, 59, 59)

# The knobs for both sections live in SETTINGS with a `section` of "watch" or
# "tail"; this reads a built-in default back out for the few places that need one
# without a resolution (a direct call, or a --help string).
def setting_default(name):
    return SETTINGS_BY_NAME[name].default

# Rows still shown when a terminal is too short for the header plus a table.
MIN_ADAPTIVE_ROWS = 5

# Watch and tail knobs live in SETTINGS with section="watch" / "tail"; both
# ramps run TOWARDS the default foreground (white here), so a tint decays back
# into ordinary text rather than dimming into the background, and the length of
# a ramp IS the number of shades.
#   fade_up:   #87ff87 -> #afffaf -> #d7ffd7
#   fade_down: #8a8a8a -> #b2b2b2 -> #dadada
# The blank line plus the status line the watch loop appends to every frame. Used
# both to reserve space and to emit them, so the two cannot disagree.
WATCH_STATUS_LINES = 2
# Sentinel for "--watch given without a number": take the interval from config.
WATCH_FROM_CONFIG = "from-config"
ANSI_RESET = "\033[0m"
ANSI_RE = re.compile(r"\033\[[0-9;?]*[A-Za-z]")

# ISO 8601 week dates: 2026-W31 (or 2026W31) for a whole week, 2026-W31-3 for the
# Wednesday of it. Note that the week-numbering year is not the calendar year at
# the edges -- 2026-W01 begins 2025-12-29.
WEEK_RE = re.compile(r"^(?P<year>\d{4})-?[Ww](?P<week>\d{1,2})$")
WEEKDAY_RE = re.compile(r"^(?P<year>\d{4})-?[Ww](?P<week>\d{1,2})-(?P<day>[1-7])$")

DATETIME_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y-%m-%d %H",
    "%Y-%m-%d",
    "%Y/%m/%d %H:%M:%S",
    "%Y/%m/%d %H:%M",
    "%Y/%m/%d",
)

DURATION_UNITS = {
    "w": "weeks",
    "d": "days",
    "h": "hours",
    "m": "minutes",
    "s": "seconds",
}
DURATION_PART_RE = re.compile(r"(?P<value>\d+)(?P<unit>[wdhms])")
DURATION_RE = re.compile(r"^(?:\d+[wdhms])+$")


# --------------------------------------------------------------------------
# records
# --------------------------------------------------------------------------
#
# Multi-value returns are named rather than positional. Adding a field to any of
# these cannot silently break a caller -- which it has: when count_messages grew
# a sixth value, a five-way unpack in the completion path raised ValueError, the
# completion handler swallowed it, and username completion returned nothing for
# days without looking broken.

class ConfigError(Exception):
    """A problem with what the user asked for: a bad flag, config or channel.

    Raised wherever the problem is noticed and caught once in main(), rather than
    calling sys.exit() from deep inside otherwise-pure functions. That kept the
    completion path having to catch SystemExit -- a net wide enough to swallow an
    unrelated ValueError, which is exactly how a broken username completion went
    unnoticed -- and made every error case testable only by spawning a process.
    """


class Tally(NamedTuple):
    """What one counting pass over a range produced."""
    counts: Counter          # login -> messages, after the state filter
    files: int               # log files covering the range
    messages: int            # total messages counted
    states: Counter          # live/offline/unknown totals for the range
    parsed: int              # files parsed rather than served from cache
    breakdown: Counter       # (login, state) -> messages
    # (filename, reason) for every log the pass could not read. A file that
    # cannot be read is skipped rather than allowed to end the query -- the same
    # bargain the cache makes -- but a count quietly missing a day is worse than
    # no count at all, so what was skipped travels out to be reported.
    unreadable: tuple = ()
    reused: int = 0          # days this pass took from the rollup
    excluded_states: Counter = None   # of `states`, the part excluded logins hold


class ConfigExclusions(NamedTuple):
    groups: dict             # name -> [login]
    always: list             # group names applied to every run
    flat: list               # logins from the flat `exclude = [...]` form


class Exclusions(NamedTuple):
    logins: dict             # login -> the layer that contributed it
    sources: list            # ordered source labels, for the header


class Tinting(NamedTuple):
    tint: object             # callable(text, login, count) -> text
    carried: dict            # login -> (direction, when), for the next frame


class Frame(NamedTuple):
    """Everything a redraw needs in order to colour itself, as one value.

    These six used to travel as separate positional arguments through
    run_report -> render_text -> colorizer, and the three did not agree on their
    order: colorizer declared (hold, now, ramps) where both its callers declared
    (hold, ramps, now). Nothing was actually wrong -- the call site spelled the
    swap out -- but `hold` and `now` are adjacent floats, so transposing them
    raises nothing and silently ages every tint against the wrong clock. A record
    has no order to get wrong.

    A bare Frame() is the one-shot case: no previous counts, so nothing has moved
    and nothing is tinted. None means "take the default" for the rest, resolved in
    one place rather than at each layer that forwards them.
    """
    previous: object = None      # {login: count} from the frame before
    carried: object = None       # {login: (direction, when)} tints still alive
    hold: object = None          # seconds a tint survives before expiring
    ramps: object = None         # ramp key -> escape sequences
    now: object = None           # monotonic instant this frame ages against
    palette_of: object = None    # callable(login) -> ramp key, for match rules

    def resolved(self):
        """Fill in whatever a caller left to the defaults.

        `now` is injected rather than read at the point of use so the tint fade --
        the one piece of output that depends on wall-clock time -- can be asserted
        without sleeping or a terminal, and so every row in a frame ages against
        one instant rather than drifting across the render.
        """
        return self._replace(
            carried=self.carried or {},
            hold=setting_default("hold") if self.hold is None else self.hold,
            ramps=self.ramps or default_ramps(),
            now=clock.monotonic() if self.now is None else self.now,
        )


def default_ramps():
    """The built-in palettes, for a render that was handed none."""
    shades = setting_default("shades")
    curve, k = setting_default("fade_curve"), setting_default("fade_k")
    names = ("up", "down") if setting_default("tint_falling") else ("up",)
    return {name: hex_ramp(parse_hex_colour(setting_default(f"fade_{name}")),
                           shades, curve, k)
            for name in names}


def highlight_key(index):
    """Ramp key for a highlight rule. Distinct from "up"/"down" by construction."""
    return f"highlight{index}"


class WatchSettings(NamedTuple):
    interval: float
    hold: float
    replay_steps: int
    full_repaint: int
    show_timing: bool
    min_redraw: float
    shades: int
    ramps: dict              # "up"/"down"/"highlightN" -> escape sequences
    highlights: tuple        # the rules themselves, for matching
    sources: dict            # which layer supplied interval, hold and highlights


class ConfigLayer(NamedTuple):
    values: dict
    path: str
    loaded: bool


# --------------------------------------------------------------------------
# value parsing
# --------------------------------------------------------------------------

def iso_week_monday(year, week):
    """Midnight on the Monday opening an ISO week."""
    try:
        return datetime.strptime(f"{int(year)}-W{int(week):02d}-1", "%G-W%V-%u")
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"no week {int(week)} in ISO year {int(year)} (weeks run 1-52, or 1-53 in long years)"
        )


def parse_datetime(text, end_of_day_if_dateless):
    """Parse a datetime string. A date with no time snaps to the start or end of day.

    ISO week dates work the same way one granularity up: '2026-W31' is Monday
    00:00:00 for --begin and Sunday 23:59:59 for --end, so naming the same week
    for both counts exactly that week.
    """
    raw = str(text).strip()

    week = WEEK_RE.match(raw)
    if week:
        monday = iso_week_monday(week.group("year"), week.group("week"))
        if end_of_day_if_dateless:
            return monday + timedelta(days=6, hours=23, minutes=59, seconds=59)
        return monday
    weekday = WEEKDAY_RE.match(raw)
    if weekday:
        day = iso_week_monday(weekday.group("year"), weekday.group("week")) + timedelta(
            days=int(weekday.group("day")) - 1
        )
        if end_of_day_if_dateless:
            return datetime.combine(day.date(), time(23, 59, 59))
        return day

    normalized = raw.replace("T", " ")
    for fmt in DATETIME_FORMATS:
        try:
            parsed = datetime.strptime(normalized, fmt)
        except ValueError:
            continue
        if fmt in ("%Y-%m-%d", "%Y/%m/%d") and end_of_day_if_dateless:
            return datetime.combine(parsed.date(), time(23, 59, 59))
        return parsed
    try:
        return datetime.fromisoformat(raw)
    except ValueError:
        raise argparse.ArgumentTypeError(
            f"unrecognized datetime {raw!r} (try 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS', "
            "'2026-W31' for a whole week, or '2026-W31-3' for its Wednesday)"
        )


def parse_duration(text):
    """Parse a relative duration like '30d', '12h', '1w3d'. 'm' means minutes.

    Idempotent: argparse converts a flag once, and the layered resolution runs
    the same parser again over whatever env, config or default supplied -- so a
    timedelta default has to survive a second pass. Every other parser here
    already does this; this one did not, and a timedelta default failed with
    "unrecognized duration '1 day, 0:00:00'".
    """
    if isinstance(text, timedelta):
        return text
    raw = str(text).strip().lower()
    if not DURATION_RE.match(raw):
        raise argparse.ArgumentTypeError(
            f"unrecognized duration {raw!r} (try '30d', '12h', '90m', '1w3d'; "
            "units are w/d/h/m/s and 'm' is minutes)"
        )
    parts = Counter()
    for part in DURATION_PART_RE.finditer(raw):
        parts[DURATION_UNITS[part.group("unit")]] += int(part.group("value"))
    delta = timedelta(**parts)
    if delta <= timedelta(0):
        raise argparse.ArgumentTypeError("duration must be greater than zero")
    return delta


def positive_int(text):
    try:
        value = int(text)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"{text!r} is not an integer")
    if value < 1:
        # The caller's label supplies the context -- this is used for --min-count
        # and for tail.max_events alike.
        raise argparse.ArgumentTypeError("must be 1 or more")
    return value


def nonnegative_int(text):
    try:
        value = int(text)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"{text!r} is not an integer")
    if value < 0:
        raise argparse.ArgumentTypeError("row limit must be 0 (unlimited) or a positive count")
    return value


def adaptive_row_limit(header_lines):
    """Rows that fit the current terminal, or None when output isn't going to one.

    Piped and redirected output stays complete so scripts see every row; only an
    interactive terminal gets trimmed, because that is the only place a 4,779-row
    table is a problem.
    """
    if not sys.stdout.isatty():
        return None
    lines = shutil.get_terminal_size(fallback=(80, 24)).lines
    # header block, blank line, column heading, two rules, footer, the "+ N
    # others" row, and one line of room above the next prompt.
    return max(lines - (header_lines + 8), MIN_ADAPTIVE_ROWS)


HEADER_MODES = ("full", "compact", "none")


def parse_header(text):
    """Parse the provenance-block mode."""
    value = str(text).strip().lower()
    if value not in HEADER_MODES:
        raise argparse.ArgumentTypeError(
            f"unknown header mode {text!r} (expected {', '.join(HEADER_MODES)})"
        )
    return value


def parse_state(text):
    """Parse a chat-state filter: live, offline, unknown, or any/all for no filter."""
    value = str(text).strip().lower()
    if value in STATES:
        return value
    if value in ("any", "all"):
        return None
    raise argparse.ArgumentTypeError(
        f"unknown chat state {text!r} (expected live, offline, unknown or any)"
    )


def nonnegative_float(text):
    try:
        value = float(text)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"{text!r} is not a number of seconds")
    if value < 0:
        raise argparse.ArgumentTypeError("must be 0 or more seconds")
    return value


def positive_float(text):
    try:
        value = float(text)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError(f"{text!r} is not a number")
    if value <= 0:
        # Every curve below divides by or raises to k, and k <= 0 either flattens
        # the ramp to one colour or inverts it. Refuse rather than render nonsense.
        raise argparse.ArgumentTypeError("must be greater than 0")
    return value


# How a tint travels from its seed colour to the foreground. Each takes a
# position x in [0, 1] along the ramp and the skew k, and returns how far toward
# white that step sits.
#
# Every curve is the identity at k = 1, by construction -- so the curve name
# alone changes nothing, and a fade is linear until a k is actually chosen. That
# also makes k the whole knob: k > 1 holds the colour and then drops it, k < 1
# dumps it immediately and leaves a long pale tail.
#
#   linear       x                          k ignored
#   power        x^k                        the workhorse; gamma
#   ease-out     1 - (1-x)^k                power, mirrored
#   bias         x / (k(1-x) + x)           same shape, no pow()
#   ease-in-out  x^k / (x^k + (1-x)^k)      symmetric S: holds, drops, settles
#
# Measured on fade_up = #87ff87 at hold = 180s, a tint is half-faded at 45s for
# k = 0.5, 90s at k = 1, and 127s at k = 2.
CURVES = {
    "linear": lambda x, k: x,
    "power": lambda x, k: x ** k,
    "ease-out": lambda x, k: 1.0 - (1.0 - x) ** k,
    "bias": lambda x, k: x / (k * (1.0 - x) + x),
    "ease-in-out": lambda x, k: (x ** k / (x ** k + (1.0 - x) ** k)) if 0 < x < 1 else x,
}


def parse_curve(text):
    """Parse a fade curve name. Idempotent: names round-trip unchanged."""
    name = str(text).strip().lower()
    if name not in CURVES:
        raise argparse.ArgumentTypeError(
            f"unknown fade curve {name!r} (choose from: {', '.join(sorted(CURVES))})"
        )
    return name


HEX_COLOUR_RE = re.compile(r"^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$")


class Highlight(NamedTuple):
    """A colour and the message patterns that earn it."""
    rgb: tuple
    patterns: tuple
    source: str      # the colour as written, for error messages and the header
    # None inherits [watch] fade_curve / fade_k. A rule that sets either fades on
    # its own schedule while still expiring at the same `hold` as every other.
    curve: object = None
    k: object = None


def parse_hex_colour(text):
    """Parse #rgb or #rrggbb into (r, g, b). Idempotent."""
    if (isinstance(text, (tuple, list)) and len(text) == 3
            and all(isinstance(c, int) for c in text)):
        return tuple(text)
    found = HEX_COLOUR_RE.match(str(text).strip())
    if not found:
        raise argparse.ArgumentTypeError(
            f"{text!r} is not a hex colour like '#0000ff'")
    digits = found.group(1)
    if len(digits) == 3:
        digits = "".join(c * 2 for c in digits)
    return tuple(int(digits[i:i + 2], 16) for i in (0, 2, 4))


def hex_ramp(rgb, steps, curve="linear", k=1.0):
    """Escape sequences fading a colour toward the foreground over `steps`.

    The same shape as the 256-colour ramps: freshest first, each step closer to
    white, so a highlighted row ages and expires on exactly the schedule an
    ordinary green one does.

    `curve` and `k` skew where the shades sit, not when they are worn: the clock
    keeps handing out one shade per 1/N of the hold, and the ramp decides what
    that shade looks like. Bending the palette rather than the clock means every
    consumer -- the watch loop, the launch replay, a rule's own ramp -- inherits
    the curve from the ramp it was already reading, and the per-row hot path
    stays a plain index.

    The cost is resolution: bunching shades makes neighbours round to the same
    RGB. On #87ff87, which has only 120 steps of headroom to white, 36 shades
    stay distinct through k = 2 (33 of 36) but collapse to 20 by k = 6.
    """
    red, green, blue = rgb
    bend = CURVES[curve]
    shades = []
    for step in range(max(1, steps)):
        # Clamped so a curve that overshoots cannot emit an out-of-range channel.
        towards = min(1.0, max(0.0, bend(step / max(1, steps), k)))
        shades.append("\033[38;2;{};{};{}m".format(
            *(round(channel + (255 - channel) * towards)
              for channel in (red, green, blue))))
    return tuple(shades)


def parse_highlights(value):
    """Parse [[watch.highlight]] into (colour, patterns) rules, in priority order."""
    if value in (None, ""):
        return ()
    if not isinstance(value, (list, tuple)):
        raise argparse.ArgumentTypeError("must be a list of tables")
    rules = []
    for index, entry in enumerate(value):
        if isinstance(entry, Highlight):
            rules.append(entry)
            continue
        if not isinstance(entry, dict):
            raise argparse.ArgumentTypeError(
                f"rule {index}: expected a table with `color` and `match`")
        if "color" not in entry or "match" not in entry:
            raise argparse.ArgumentTypeError(
                f"rule {index}: needs both `color` and `match`")
        patterns = entry["match"]
        if isinstance(patterns, str):
            patterns = [patterns]
        if not isinstance(patterns, (list, tuple)) or not patterns:
            raise argparse.ArgumentTypeError(
                f"rule {index}: `match` needs at least one pattern")
        compiled = []
        for pattern in patterns:
            try:
                compiled.append(re.compile(str(pattern)))
            except re.error as exc:
                raise argparse.ArgumentTypeError(
                    f"rule {index}: {pattern!r} is not a valid regex ({exc})")
        # Absent means inherit [watch] fade_curve / fade_k, which is why these
        # stay None rather than defaulting to linear here -- a rule that says
        # nothing must follow the global curve, not override it with a flat one.
        try:
            curve = parse_curve(entry["curve"]) if "curve" in entry else None
            k = positive_float(entry["k"]) if "k" in entry else None
        except argparse.ArgumentTypeError as exc:
            raise argparse.ArgumentTypeError(f"rule {index}: {exc}")
        rules.append(Highlight(parse_hex_colour(entry["color"]), tuple(compiled),
                               str(entry["color"]), curve, k))
    return tuple(rules)


# How to settle for a window when the exact user count is unreachable. It often
# is: a user count only rises as the window widens, and two users crossing
# --min-count in the same instant step it from 8 to 10, so 9 exists at no width
# at all. Measured on a live channel, 4 of 15 counts were unreachable at minute
# resolution and 1 of 15 at ten-second resolution.
USER_POLICIES = ("at-least", "at-most", "nearest")


def parse_users_policy(text):
    """Parse how to settle when the requested user count has no exact window."""
    name = str(text).strip().lower()
    if name not in USER_POLICIES:
        raise argparse.ArgumentTypeError(
            f"unknown --users-policy {name!r} "
            f"(choose from: {', '.join(USER_POLICIES)})"
        )
    return name


def parse_bool(text):
    if isinstance(text, bool):
        return text
    value = str(text).strip().lower()
    if value in ("1", "true", "yes", "on"):
        return True
    if value in ("0", "false", "no", "off"):
        return False
    raise argparse.ArgumentTypeError(f"expected true or false, got {text!r}")


# --------------------------------------------------------------------------
# layered settings resolution
# --------------------------------------------------------------------------

class Setting:
    """A resolved value plus a human-readable note about where it came from."""

    def __init__(self, value, source):
        self.value = value
        self.source = source

    def __bool__(self):
        return self.value is not None


def load_config_layer(args, readers=None):
    """Locate and load the config for this run. Returns (config, path, loaded).

    A watch loop resolves settings on every redraw, which meant reading and
    re-parsing the TOML five times a second -- 0.30ms of a 2ms tick -- to rebuild
    an identical dict. With a session to hold it, the parse is skipped unless the
    file's size or mtime moved, so editing the config mid-session still takes
    effect on the next tick exactly as it did before.
    """
    if readers is not None:
        try:
            identity = config_identity(args)
        except OSError:
            identity = None
        if identity is not None:
            return readers.config.get(identity, lambda: load_config_layer(args))
    if args.no_config or (DEFAULT_CONFIG_PATH is None and args.config is None
                          and not os.environ.get("TWITCH_COUNTS_CONFIG")):
        return ConfigLayer({}, DEFAULT_CONFIG_PATH or "(no default on this platform)",
                           False)
    explicit = args.config is not None or bool(os.environ.get("TWITCH_COUNTS_CONFIG"))
    config_path = os.path.expanduser(
        args.config or os.environ.get("TWITCH_COUNTS_CONFIG") or DEFAULT_CONFIG_PATH
    )
    config, config_loaded = load_config(config_path, explicit)
    return ConfigLayer(config, config_path, config_loaded)


def config_identity(args):
    """What would make the config layer different: which file, and its contents."""
    if args.no_config:
        return ("none",)
    chosen = args.config or os.environ.get("TWITCH_COUNTS_CONFIG") or DEFAULT_CONFIG_PATH
    if chosen is None:
        return ("none",)
    path = os.path.expanduser(chosen)
    if not os.path.isfile(path):
        return (path, None, None)
    info = os.stat(path)
    return (path, info.st_size, info.st_mtime_ns)


def load_config(path, explicit):
    """Read the TOML config. Missing default paths are fine; missing explicit ones are not."""
    if not os.path.isfile(path):
        if explicit:
            raise ConfigError(f"config file not found: {path}")
        return {}, False
    try:
        with open(path, "rb") as handle:
            data = tomllib.load(handle)
    except (tomllib.TOMLDecodeError, OSError) as exc:
        raise ConfigError(f"could not read config {path}: {exc}")
    if not isinstance(data, dict):
        raise ConfigError(f"config {path} must be a table of settings")
    return data, True


def resolve(name, cli_value, env_name, config, config_path, key, default=None,
            default_note="default", section=None):
    """Resolve one setting through CLI -> env -> [section] -> config -> default.

    A section is a config sub-table consulted before the top level, so
    `[watch] header` beats a top-level `header` while watching. Without it, a
    setting that lives in a sub-table needs its own precedence chain -- which is
    how the header mode ended up with a hand-written one, and watch settings with
    a second mechanism that passed the sub-table in as `config`.
    """
    if cli_value is not None:
        return Setting(cli_value, f"--{name}")
    env_value = os.environ.get(env_name)
    if env_value is not None and env_value != "":
        return Setting(env_value, f"env {env_name}")
    if section:
        table = config.get(section)
        if isinstance(table, dict) and table.get(key) is not None:
            return Setting(table[key], f"config [{section}]")
    if key in config and config[key] is not None:
        return Setting(config[key], "config")
    return Setting(default, default_note)


def resolve_window_start(args, config, config_path):
    """Resolve --begin/--since together: the highest layer providing either one wins.

    Returns (kind, Setting) where kind is 'begin', 'since', or None.
    """
    if args.users is not None:
        return "users", Setting(args.users, "--users")
    layers = (
        ("--begin", args.begin, "--since", args.since),
        (
            "env TWITCH_BEGIN", os.environ.get("TWITCH_BEGIN") or None,
            "env TWITCH_SINCE", os.environ.get("TWITCH_SINCE") or None,
        ),
        (
            "config begin", config.get("begin"),
            "config since", config.get("since"),
        ),
    )
    for begin_source, begin_value, since_source, since_value in layers:
        if begin_value is not None and since_value is not None:
            raise ConfigError(f"{begin_source} and {since_source} are mutually exclusive")
        if begin_value is not None:
            return "begin", Setting(begin_value, begin_source)
        if since_value is not None:
            return "since", Setting(since_value, since_source)
    return None, Setting(None, "default")


def shorten_path(path):
    home = os.path.expanduser("~")
    return path.replace(home, "~", 1) if path.startswith(home) else path


def source_label(flag, setting):
    """Name a setting and, when it differs, where its value came from."""
    return flag if setting.source == flag else f"{flag} (from {setting.source})"


def holds_default(settings, name):
    """True when nobody asked for this value -- it is still the built-in one.

    Compared against the Spec's own note rather than a literal, so the two cannot
    drift. Distinguishing "unasked for" from "set to the same value" is what lets
    the header stay quiet about defaults while never dropping a flag the user
    actually passed.
    """
    return settings[name].source == SETTINGS_BY_NAME[name].default_note


def convert(setting, converter, flag):
    """Apply a parser to a resolved value, reporting the source when it fails."""
    try:
        return converter(setting.value)
    except argparse.ArgumentTypeError as exc:
        raise ConfigError(f"{source_label(flag, setting)}: {exc}")


# --------------------------------------------------------------------------
# exclusions
# --------------------------------------------------------------------------

def split_names(value):
    """Normalize a name list: a TOML array, or a comma/space separated string."""
    items = value if isinstance(value, (list, tuple)) else re.split(r"[,\s]+", str(value))
    return [str(item).strip().lower() for item in items if str(item).strip()]


def config_exclusions(config, config_path):
    """Read `exclude` from the config in either supported shape.

    Flat:    exclude = ["streamelements", "supibot"]
    Grouped: [exclude] with one array per group, plus an optional `always` array
             naming the groups applied to every run.

    Returns (groups, always_group_names, flat_logins).
    """
    raw = config.get("exclude")
    where = shorten_path(config_path)
    if raw is None:
        return ConfigExclusions({}, [], [])
    if isinstance(raw, list):
        return ConfigExclusions({}, [], split_names(raw))
    if not isinstance(raw, dict):
        raise ConfigError(f"`exclude` in {where} must be a list of logins or a table of groups")

    groups = {}
    for name, members in raw.items():
        if name == "always":
            continue
        if not isinstance(members, list):
            raise ConfigError(f"[exclude].{name} in {where} must be a list of logins")
        groups[name] = split_names(members)

    always = raw.get("always", [])
    if not isinstance(always, list):
        raise ConfigError(f"[exclude].always in {where} must be a list of group names")
    known = ", ".join(sorted(groups)) or "(none defined)"
    for name in always:
        if str(name) not in groups:
            raise ConfigError(
                f"[exclude].always in {where} names unknown group {str(name)!r}; "
                f"defined groups: {known}"
            )
    return ConfigExclusions(groups, [str(name) for name in always], [])


def exclusion_layers(args, config, config_path, channel_name):
    """Every layer that can contribute exclusions, in precedence order.

    Each layer is just (source label, logins). Laying them out as data rather
    than eight conditionals puts the order on one screen and makes the additive
    rule visible: nothing here overrides an earlier layer, they all pile on. That
    is the one deliberate exception to first-hit-wins, and it used to be implied
    by a scattering of setdefault calls.
    """
    groups, always, flat = config_exclusions(config, config_path)

    for name in args.exclude_group or []:
        if name not in groups:
            known = ", ".join(sorted(groups)) or "(none defined)"
            raise ConfigError(f"unknown exclude group {name!r}; defined groups: {known}")

    broadcaster = resolve(
        "exclude-broadcaster", args.exclude_broadcaster, "TWITCH_EXCLUDE_BROADCASTER",
        config, config_path, "exclude_broadcaster", default=False, default_note="default",
    )
    wants_broadcaster = convert(broadcaster, parse_bool, "--exclude-broadcaster")

    return [
        ("config exclude", flat),
        *((f"config always:{name}", groups[name]) for name in always),
        *((f"--exclude-group {name}", groups[name]) for name in args.exclude_group or []),
        ("env TWITCH_EXCLUDE", split_names(os.environ.get("TWITCH_EXCLUDE") or "")),
        ("--exclude", [name for value in args.exclude or []
                       for name in split_names(value)]),
        (broadcaster.source, [channel_name.lower()] if wants_broadcaster else []),
    ]


def build_exclusions(args, config, config_path, channel_name):
    """Fold the exclusion layers into {login: source}, then apply --include."""
    if args.no_exclude:
        conflicting = [
            flag for flag, value in (
                ("--exclude", args.exclude),
                ("--exclude-group", args.exclude_group),
                ("--exclude-broadcaster", args.exclude_broadcaster),
                ("--include", args.include),
            ) if value
        ]
        if conflicting:
            raise ConfigError(
                f"--no-exclude cannot be combined with {', '.join(conflicting)}"
            )
        return Exclusions({}, [])

    excluded, sources = {}, []
    for source, logins in exclusion_layers(args, config, config_path, channel_name):
        if not logins:
            continue
        for login in logins:
            excluded.setdefault(login, source)
        if source not in sources:
            sources.append(source)

    removed = 0
    for value in args.include or []:
        for login in split_names(value):
            if excluded.pop(login, None) is not None:
                removed += 1
    if removed:
        sources.append(f"minus --include ({removed})")

    return Exclusions(excluded, sources)


# --------------------------------------------------------------------------
# log reading
# --------------------------------------------------------------------------

def speaker_login(who):
    """Return the lowercase login for a speaker field, or None if it's a system line.

    System notices ("Suspicious User: Restricted", "Unknown error: TimeoutError",
    "A message from x was deleted: ...") also match the "<who>: <text>" shape, so
    the speaker is only accepted as a real chatter when it looks like a login or a
    localized "<non-ascii display> <login>" pair.
    """
    if LOGIN_RE.match(who):
        return who.lower()
    localized = LOCALIZED_RE.match(who)
    if localized and any(ord(c) > 127 for c in localized.group("display")):
        return localized.group("login")
    return None


def resolve_channel_dir(logs_dir, channel):
    """Find the channel's log directory, matching case-insensitively."""
    if not os.path.isdir(logs_dir):
        raise ConfigError(f"logs directory not found: {logs_dir}")
    entries = sorted(
        name for name in os.listdir(logs_dir)
        if os.path.isdir(os.path.join(logs_dir, name))
    )
    for name in entries:
        if name.lower() == channel.lower():
            return os.path.join(logs_dir, name), name
    available = ", ".join(entries) if entries else "(none)"
    raise ConfigError(f"no logs for channel {channel!r} in {logs_dir}\navailable: {available}")


def log_files(channel_dir):
    """Every dated log file as (date, path), ascending.

    Chatterino also writes per-stream logs named <channel>-<streamid>.log whose
    lines duplicate the dated files exactly; skipping them here is what keeps
    messages from being counted twice.
    """
    found = []
    for name in sorted(os.listdir(channel_dir)):
        match = FILENAME_RE.match(name)
        if not match:
            continue
        try:
            file_date = date(int(match.group("y")), int(match.group("mo")),
                             int(match.group("d")))
        except ValueError:
            continue          # a well-shaped name that is not a real date
        found.append((file_date, os.path.join(channel_dir, name)))
    return sorted(found)


def log_files_for(channel_dir, readers=None):
    """log_files(), skipped when the directory has not changed since last asked.

    Two callers want this listing on every redraw -- the range walk and the state
    seed -- and rebuilding it costs 0.6-0.9ms on these channels: a listdir plus a
    regex and a strptime for every name. Over a 0.2s interval that was the single
    largest part of a tick on a short window, where no day is old enough to come
    from the rollup cache and there is otherwise almost nothing to do.

    The directory's own mtime decides. Appending to today's log -- which is what
    Chatterino does constantly -- does not touch it, so the memo holds for a whole
    session; creating or removing a file does, so midnight rollover and a channel
    going live both invalidate it without anything having to notice the date. A
    stat is ~1.3us against ~600x that for the rescan, so the check is free.

    Deliberately a wrapper rather than a memo inside log_files: log_files is a
    CACHE_INPUTS entry, and editing its body changes the rollup fingerprint,
    discarding every cached day for every channel to make a change that alters
    nothing about what is counted.
    """
    if readers is None:
        return log_files(channel_dir)
    try:
        key = (channel_dir, os.stat(channel_dir).st_mtime_ns)
    except OSError:
        # Cannot tell whether it moved; rescan and let log_files raise if it must.
        return log_files(channel_dir)
    return readers.listing.get(key, lambda: log_files(channel_dir))


def log_dates(channel_dir):
    """Every date that has a log file, ascending."""
    return [file_date for file_date, _ in log_files(channel_dir)]


def files_before(listing, day):
    """The slice of a sorted listing whose dates fall before `day`."""
    return listing[:bisect.bisect_left(listing, (day,))]


def files_between(listing, begin, end):
    """The slice of a sorted listing whose dates fall within [begin, end].

    Bisected rather than scanned. Two callers wanted this on every redraw and
    both walked the whole listing, re-deriving begin.date() and end.date() once
    per entry: 374 date() calls a tick to locate a single file, and the cost grew
    with the length of the log history rather than the size of the window. On a
    186-day channel that was 26us of a 113us tick.

    log_files() returns (date, path) sorted, which is what makes this valid.
    """
    first = bisect.bisect_left(listing, (begin.date(),))
    try:
        stop = end.date() + timedelta(days=1)
    except OverflowError:      # an --end at the last representable date
        return listing[first:]
    return listing[first:bisect.bisect_left(listing, (stop,))]


def log_files_in_range(channel_dir, begin, end, readers=None):
    """(date, path) for log files whose filename date falls in the range."""
    return files_between(log_files_for(channel_dir, readers), begin, end)


def seed_stream_state(channel_dir, begin, cache=None, channel=None, readers=None,
                      lookback=None):
    """The live/offline state in force when the range opens, or None if unknowable.

    A stream that started before the range would otherwise leave its first hours
    of chat unclassified, so walk back through earlier files until one carries a
    marker. Beyond the lookback the honest answer is that we don't know.
    """
    lookback = setting_default("seed_lookback") if lookback is None else lookback
    earlier = files_before(log_files_for(channel_dir, readers), begin.date())
    # The answer depends only on the day before the window and that file's
    # identity, so within a run it is worth remembering: rescanning it four times
    # a second was costing more than the counting itself.
    key = None
    if readers is not None and earlier:
        try:
            last = os.stat(earlier[-1][1])
            key = (channel_dir, begin.date(), earlier[-1][0], last.st_size,
                   last.st_mtime_ns)
        except OSError:
            key = None

    def scan():
        if cache is not None and earlier:
            # The day before the range is the only one whose exit state can seed
            # it. A cached 'unknown' proves nothing, so fall through and scan.
            file_date, path = earlier[-1]
            try:
                state = cache.exit_state(channel, file_date, os.stat(path))
            except OSError:
                state = None
            if state:
                return state
        for _, path in reversed(earlier[-lookback:]):
            state = None
            try:
                with open(path, encoding="utf-8", errors="replace") as handle:
                    for line in handle:
                        match = LIVE_RE.match(line.rstrip("\n"))
                        if match:
                            state = ("live" if match.group("state") == "live!"
                                     else "offline")
            except OSError:
                # Guarded like the cache lookup above it, which this loop used to
                # contradict. History we cannot read is no worse than history
                # that was never written: keep walking back, and fall to None.
                continue
            if state:
                return state
        return None

    return scan() if key is None else readers.seed.get(key, scan)


def fold_lines(lines, buckets, state, highlights=(), matches=None, order=None):
    """Fold complete log lines into per-second buckets; return the exit state.

    Buckets are keyed (second-of-day, login, state) rather than just
    (login, state) so a window can be re-derived as it slides without re-reading
    the file -- which is what lets a tail keep the day incrementally. One flat
    dict, because a dict per second cost 40% more memory for the same day
    (31.7MB against 23.5MB on the busiest day here) to no benefit.

    `order`, when given, collects each key once in ascending order so a sliding
    window can bisect straight to its range instead of walking the whole day. Log
    lines are chronological, so this is an append; a clock that steps back -- the
    hour that repeats when DST ends -- inserts in place instead.

    When `highlights` is given, each message is also tested against them and the
    first matching rule is recorded in `matches` as login -> [(second, rule)].
    The message text is already captured by LINE_RE and otherwise thrown away, so
    this is the one place content can be inspected without a second parse.
    """
    for line in lines:
        line = line.rstrip("\n")
        if not line or line.startswith("#"):
            continue
        marker = LIVE_RE.match(line)
        if marker:
            state = "live" if marker.group("state") == "live!" else "offline"
            continue
        match = LINE_RE.match(line)
        if not match:
            continue
        login = speaker_login(match.group("who"))
        if login is None:
            continue
        second = (int(match.group("h")) * SECONDS_PER_HOUR
                  + int(match.group("m")) * SECONDS_PER_MINUTE
                  + int(match.group("s")))
        key = (second, login, state or "unknown")
        seen = buckets.get(key)
        if seen is None:
            buckets[key] = 1
            if order is not None:
                if order and second < order[-1][0]:
                    bisect.insort(order, key)
                else:
                    order.append(key)
        else:
            buckets[key] = seen + 1
        if highlights and matches is not None:
            text = match.group("msg")
            hit = None
            for index, rule in enumerate(highlights):
                if any(pattern.search(text) for pattern in rule.patterns):
                    hit = index   # no break: a later rule supersedes an earlier one
            if hit is not None:
                matches.setdefault(login, []).append((second, hit))
    return state


def line_at_or_after(text, want, span=1 << 16):
    """Offset of the first line whose [HH:MM:SS] is >= `want`, or len(text).

    Searched from the end, doubling until a line *before* the window bounds the
    answer, because the caller wants a recent window and the log is chronological
    -- Chatterino appends to it and never rewrites it.
    """
    size = len(text)
    while True:
        start = 0 if span >= size else text.find("\n", size - span) + 1
        pos, found = start, None
        while pos < size:
            if text.startswith("[", pos) and text[pos + 1:pos + 9] >= want:
                found = pos
                break
            newline = text.find("\n", pos)
            if newline < 0:
                break
            pos = newline + 1
        if found is None:
            return size                 # nothing at or after `want`
        if found > start or start == 0:
            return found                # a line before the window bounds it
        span *= 2                       # the chunk was entirely inside the window


def seek_window(text, floor):
    """Where a window opening at second-of-day `floor` starts, and the stream
    state entering it: (offset, state or None).

    Reading a whole day to answer a question about its last few minutes was the
    single largest cost in this program -- 49ms of a 365ms startup on a 1.6MB
    log, and 35,931 buckets held for the 245 a 7-minute window can reach. The
    log is chronological, so the answer is a seek.

    The state entering the window still has to come from the part being skipped:
    a marker there is what says whether the stream is live. rfind locates the
    last candidate at C speed and LIVE_RE then confirms the line really is one,
    so the fast path never widens what counts as a marker.
    """
    if floor <= 0:
        return 0, None
    want = "%02d:%02d:%02d" % (floor // SECONDS_PER_HOUR,
                               floor // SECONDS_PER_MINUTE % 60, floor % 60)
    start = line_at_or_after(text, want)
    if start <= 0:
        return 0, None
    prefix = text[:start]
    state = None
    for literal, said in ((" is live!", "live"), (" is now offline.", "offline")):
        at = prefix.rfind(literal)
        while at >= 0:
            line_start = prefix.rfind("\n", 0, at) + 1
            line_end = prefix.find("\n", at)
            line = prefix[line_start:line_end if line_end >= 0 else len(prefix)]
            if LIVE_RE.match(line):
                if state is None or line_start > state[0]:
                    state = (line_start, said)
                break
            at = prefix.rfind(literal, 0, at)
    return start, (state[1] if state else None)


def bucket_bounds(file_date, begin, end):
    """The [lo, hi] seconds-of-day this file contributes to a range, or None."""
    day_start = datetime.combine(file_date, time(0, 0, 0))
    lo = 0 if begin <= day_start else int((begin - day_start).total_seconds())
    last = day_start + timedelta(seconds=LAST_SECOND_OF_DAY)
    hi = LAST_SECOND_OF_DAY if end >= last else int((end - day_start).total_seconds())
    return (lo, hi) if lo <= hi else None


def sum_buckets(buckets, bounds=None):
    """Flatten per-second buckets to (login, state) counts, optionally windowed."""
    out = Counter()
    if bounds is None:
        for (_, login, state), n in buckets.items():
            out[(login, state)] += n
        return out
    lo, hi = bounds
    for (second, login, state), n in buckets.items():
        if lo <= second <= hi:
            out[(login, state)] += n
    return out


class TailSettings(NamedTuple):
    notify: bool
    max_events: int
    seed_lookback: int


_UNSET = object()


class Memo:
    """One remembered answer, kept for as long as its key holds.

    Eight of these accumulated on LiveReaders as bare attributes, each with its
    own key shape and its own staleness rule written out at the point of use --
    and the one time I keyed one on too little, it served a stale window and was
    caught only by an unrelated test. Naming the pattern puts the rule next to
    the value it guards and makes the set of them readable as a list.

    Not every cache here fits: `files` and `days` are keyed dictionaries rather
    than one answer, `cache` is opened once and never re-keyed, and `tally`
    compares its windows by identity because comparing Counters by value would
    cost more than the fold it is avoiding. Those stay as they are.
    """

    __slots__ = ("key", "value")

    def __init__(self):
        self.key, self.value = _UNSET, None

    def get(self, key, build):
        """The value for `key`, building and remembering it on a miss."""
        if self.key is _UNSET or self.key != key:
            self.key, self.value = key, build()
        return self.value

    def forget(self):
        self.key, self.value = _UNSET, None


class LiveReaders:
    """State a long-running loop keeps between frames.

    Without it every tick re-reads today's log from the top and re-derives the
    live/offline state entering the window by scanning yesterday's log -- 7.6ms
    and 11.2ms respectively, both reproducing exactly what the previous tick
    computed a quarter of a second earlier.

    `listing` is the third of these: the directory listing behind log_files(),
    which two callers ask for on every tick and which changes only when a file
    appears or goes.
    """

    def __init__(self, highlights=(), platform=None):
        self.files = {}     # path -> TailReader
        self.seed = Memo()      # (channel_dir, date, file identity) -> state
        self.listing = Memo()   # (channel_dir, dir mtime_ns) -> [(date, path), ...]
        # One cache connection for the loop. Opening one per tick cost 0.48ms of
        # a 2ms tick -- connect, schema check, register, sweep, commit, close --
        # five times a second, often to serve no cached day at all. It was per
        # tick only because closing it was how an fd leak got fixed; holding one
        # and closing it once is the better answer to the same problem.
        self.cache = None        # (Cache | None, problem | None), once opened
        self.config = Memo()     # config file identity -> ConfigLayer
        # Whole days served from the rollup, already flattened. A day inside the
        # range cannot change -- Chatterino opens a dated log with QIODevice::Append
        # and only ever reopens today's (LoggingChannel::openLogFile) -- so the
        # file identity the cache already checks fully describes it. Re-reading
        # 41,888 rows out of SQLite and rebuilding Counters five times a second
        # was 42% of a 30-day tick.
        self.days = {}           # (channel, date, size, mtime_ns, enter) -> (counts, exit)
        self.inputs = Memo()     # (config identity, args) -> Inputs, all but the window
        self.width = Memo()      # (config identity, args) -> a sized --users window
        # Seconds of slack to keep behind the window when pruning a reader, or 0
        # to keep everything. The watch loop sets it to `hold`, which is as far
        # back as the launch replay and the highlight palettes ever look.
        self.retain_seconds = 0   # buckets: how far behind the window to keep
        self.match_seconds = 0    # matches: 0 means they never expire
        # (files in range, the window objects folded, the Tally they produced).
        # Reused when every one of those objects comes back identical.
        self.tally = None
        self.highlights = highlights
        self.platform = platform or PLATFORM

    def reader(self, path, file_date):
        found = self.files.get(path)
        if found is None:
            found = self.files[path] = TailReader(path, file_date, self.highlights,
                                                 self.platform)
        return found

    def paths(self):
        return list(self.files)

    def retain(self, paths, dates):
        """Drop readers and memoized days that are no longer in range.

        Nothing evicted them before, so a session left running across midnights
        accumulated a full day of buckets per day -- 165MB after a week of
        --since 30m on the busiest channel here, none of it reachable again,
        since a day that has left a rolling window cannot re-enter it.

        Safe because a past day's log is finished: Chatterino opens a dated log
        with QIODevice::Append and only ever reopens today's, so a reader
        rebuilt later reads the same bytes. Dropping the paths also stops the
        watcher watching files that can no longer change.
        """
        keep, live = set(paths), set(dates)
        for path in [p for p in self.files if p not in keep]:
            del self.files[path]
        for key in [k for k in self.days if k[1] not in live]:
            del self.days[key]


class TailReader:
    """One log file, kept up to date by reading only what has been appended.

    Chatterino writes these while we read them, so a watch loop re-parsing the
    whole of today's log several times a second reproduces work it already did --
    measured at 7.6ms per tick, 72% of the tick, and entirely redundant whenever
    nothing was written.

    The reader keeps a byte offset and the per-second buckets built so far, and
    starts over from scratch whenever it cannot prove the file only grew:

      - the file shrank, or its inode changed (truncation, rotation)
      - the live/offline state entering the file changed, which would reclassify
        messages that carry no marker of their own

    A partial final line is held back rather than parsed, since Chatterino may be
    midway through writing it.
    """

    def __init__(self, path, file_date, highlights=(), platform=None):
        self.path = path
        self.file_date = file_date
        self.highlights = highlights
        self.platform = platform or PLATFORM
        # Lifetime counters, deliberately outside reset(): they say how the
        # reader has behaved overall, which a re-read must not erase.
        self.full_reads = 0
        self.appends = 0
        self.reset(None)

    def reset(self, enter_state):
        """Discard what was read and start the file again from byte zero.

        The slid window goes with it: after a truncation or a state change the
        keys it was built from may no longer exist, or may mean something else.
        """
        self.buckets = {}   # (second, login, state) -> n
        self.order = []     # those keys, ascending by second, for bisecting
        self.window_ = None  # (revision, lo, hi, counts) from the last window()
        self.revision = 0    # bumped whenever a fold changes the buckets
        self.partial = False  # True once pruned: day() no longer covers the day
        self.matches = {}   # login -> [(second, rule index)], ascending
        self.offset = 0
        self.remainder = ""
        self.enter_state = enter_state
        self.exit_state = enter_state
        self.identity = None

    def refresh(self, enter_state, stat, floor=0):
        """Bring the buckets up to date. Returns True if anything was read.

        `floor` is the earliest second-of-day the caller can ever ask about. On a
        cold read it lets the reader seek past everything older instead of
        parsing the day to reach its last few minutes; the state entering the
        kept part comes from the markers in the part skipped. A reader that
        skipped anything is `partial`, so its day is never written to the rollup
        as though it were whole.
        """
        identity = self.platform.file_identity(stat)
        rewound = stat.st_size < self.offset or (
            self.identity is not None and identity != self.identity)
        if rewound or enter_state != self.enter_state:
            self.reset(enter_state)
        self.identity = identity
        if stat.st_size == self.offset and self.offset:
            return False        # nothing appended since last time
        cold = self.offset == 0
        with open(self.path, "rb") as handle:
            handle.seek(self.offset)
            chunk = handle.read()
            self.offset = handle.tell()
        text = self.remainder + chunk.decode("utf-8", errors="replace")
        if cold and floor > 0:
            start, entering = seek_window(text, floor)
            if start:
                text = text[start:]
                self.partial = True
                if entering is not None:
                    self.exit_state = entering
        # Keep anything after the last newline: it may be half-written.
        cut = text.rfind("\n")
        if cut < 0:
            self.remainder = text
            return False
        self.remainder = text[cut + 1:]
        self.exit_state = fold_lines(text[:cut].split("\n"), self.buckets,
                                     self.exit_state, self.highlights, self.matches,
                                     self.order)
        self.revision += 1
        self.full_reads += cold
        self.appends += not cold
        return True

    def prune(self, floor, match_floor=None):
        """Drop everything before second-of-day `floor`. Returns keys removed.

        A --since 30m session accumulates today's log from byte zero and keeps
        all of it: measured mid-afternoon on the busiest channel here, 24,239
        keys held and 303 -- 1.2% -- reachable by the window, growing to a full
        day by evening. The log is append-only and chronological, so a key below
        a window that only moves forward can never be read again.

        Purely a memory measure. Windowing bisects, so a shorter list does not
        make it faster; it makes the process smaller, which is what matters to
        something left running for days.
        """
        if floor <= 0 or not self.order or self.order[0][0] >= floor:
            return 0
        cut = bisect.bisect_left(self.order, (floor,))
        for key in self.order[:cut]:
            del self.buckets[key]
        del self.order[:cut]
        # Matches decide colour for as long as `hold`, which may be forever;
        # buckets are only ever read back as far as the replay reaches. A caller
        # passing match_floor <= 0 is saying the tints never expire -- the
        # short-circuit below only skips rebuilding lists that would keep every
        # entry anyway, so it is speed rather than semantics.
        if match_floor is None:
            match_floor = floor
        for login, hits in ([] if match_floor <= 0 else list(self.matches.items())):
            kept = [hit for hit in hits if hit[0] >= match_floor]
            if kept:
                self.matches[login] = kept
            else:
                del self.matches[login]
        # The day is no longer whole, so it must not be written to the rollup as
        # if it were, and the slid window was built over keys that are now gone.
        self.partial = True
        self.window_ = None
        return cut

    def window(self, begin, end):
        """Counts for the part of this file inside [begin, end].

        Bisects to the range rather than walking the day. A sliding window asks
        for this on every redraw, and by evening today's log holds most of its
        86,400 seconds while a --since 30m window wants ~1,800 of them: the scan
        was 0.71ms of a 2ms tick, and grew as the day went on.
        """
        bounds = bucket_bounds(self.file_date, begin, end)
        if bounds is None:
            return Counter()
        lo, hi = bounds
        # A short tuple sorts before any longer one starting with it, so (lo,)
        # lands on the first key of that second and (hi + 1,) just past the last.
        span = lambda a, b: (bisect.bisect_left(self.order, (a,)),
                             bisect.bisect_left(self.order, (b + 1,)))
        if self.window_ is not None:
            revision, was_lo, was_hi, held = self.window_
            # The revision matters as much as the bounds: at a 0.2s interval
            # several ticks share a second, so `end` can be unchanged while new
            # messages land inside the window. Sliding on bounds alone would
            # return a stale count for as long as that second lasted.
            if revision == self.revision and was_lo <= lo and was_hi <= hi:
                # A rolling window only ever advances, and at a 0.2s interval it
                # advances past almost nothing: measured over 200 ticks of a
                # --since 30m watch, 0.04 keys of 271 entered or left per tick.
                # Re-summing all 271 cost 58us; adjusting the two edges costs 1.6.
                dropped = self.order[span(was_lo, lo - 1)[0]:span(was_lo, lo - 1)[1]]
                added = self.order[span(was_hi + 1, hi)[0]:span(was_hi + 1, hi)[1]]
                if not dropped and not added:
                    return held
                out = held.copy()   # a new object: callers may still hold the old
                for key in dropped:
                    out[(key[1], key[2])] -= self.buckets[key]
                for key in added:
                    out[(key[1], key[2])] += self.buckets[key]
                out += Counter()    # drop anything that reached zero or below
                self.window_ = (self.revision, lo, hi, out)
                return out
        out = Counter()
        first, last = span(lo, hi)
        for key in self.order[first:last]:
            out[(key[1], key[2])] += self.buckets[key]
        self.window_ = (self.revision, lo, hi, out)
        return out

    def day(self):
        return sum_buckets(self.buckets)


def count_messages(channel_dir, begin, end, state_filter=None, initial_state=None,
                   cache=None, channel=None, readers=None, excluded=()):
    """Count messages per login, and tally how the range splits by stream state.

    Two tiers: a day wholly inside the range comes from the rollup cache, and
    anything else is read by a TailReader. The loop keeps its readers between
    frames so a redraw costs only what was appended; a one-shot run uses a
    throwaway, whose first refresh is exactly a whole-file parse. One
    implementation of message classification either way.
    """
    windows = []            # one per file read, in range order
    files_total = 0
    parsed = 0
    unreadable = []
    reused = 0
    current = initial_state

    def skip(path, exc):
        """Record a file we could not read, and stop trusting the stream state.

        Whether the stream went live or offline inside a day we never saw is not
        knowable, so the state does not carry across it. Chat after the gap reads
        as 'unknown' until the next marker, which is what this tool already does
        for anything no marker can place -- better than inheriting a state that
        may have changed behind the gap.
        """
        unreadable.append((os.path.basename(path),
                           f"{type(exc).__name__}: {exc.strerror or exc}"))
        return None

    in_range = list(log_files_in_range(channel_dir, begin, end, readers))
    if readers is not None:
        # Do this first: a reader dropped here is one fewer file to stat below,
        # and one fewer path for the change watcher to arm.
        readers.retain([p for _, p in in_range], [d for d, _ in in_range])
    for file_date, path in in_range:
        files_total += 1
        day_start = datetime.combine(file_date, time(0, 0, 0))
        day_end = datetime.combine(file_date, END_OF_DAY)
        whole_day = begin <= day_start and day_end <= end
        bounds = bucket_bounds(file_date, begin, end)
        cached = None
        try:
            stat = os.stat(path)
        except OSError as exc:
            current = skip(path, exc)
            continue
        if cache is not None and whole_day:
            # A whole day inside the range is settled: same file, same answer.
            # Keep the flattened counts rather than re-reading the rollup and
            # rebuilding them, which was the largest cost in a long-window tick.
            memo = (channel, file_date, stat.st_size, stat.st_mtime_ns, current)
            cached = None if readers is None else readers.days.get(memo)
            if cached is None:
                cached = cache.get(channel, file_date, stat, current)
                if cached is not None and readers is not None:
                    readers.days[memo] = cached
        if cached is not None:
            reused += 1
            window, current = cached
        else:
            reader = (readers.reader(path, file_date) if readers is not None
                      else TailReader(path, file_date))
            floor = 0
            if readers is not None and readers.retain_seconds and bounds:
                floor = max(0, int(bounds[0] - readers.retain_seconds))
            try:
                read = reader.refresh(current, stat, floor)
            except OSError as exc:
                current = skip(path, exc)
                continue
            parsed += read
            window = reader.window(begin, end)
            # Only write the rollup after a cold read: an incremental append
            # would otherwise rewrite the whole day's rows several times a second.
            if (cache is not None and read and reader.appends == 0
                    and not reader.partial):
                cache.put(channel, file_date, stat, current, reader.exit_state,
                          reader.day())
            current = reader.exit_state
            if floor:
                # After the rollup write, never before it: the put needs the day.
                reader.prune(floor, (bounds[0] - readers.match_seconds
                                     if readers.match_seconds else 0))
        windows.append(window)

    return fold_windows(windows, Bookkeeping(files_total, parsed, tuple(unreadable),
                                             reused, tuple(in_range)),
                        state_filter, excluded, readers)


class Bookkeeping(NamedTuple):
    """What a gathering pass observed about the files, rather than the messages.

    Kept apart from the counts because it describes *this* pass even when the
    counts are reused from the last one: nothing was parsed, so `parsed` is 0,
    but the tally is the same tally.
    """
    files: int
    parsed: int
    unreadable: tuple
    reused: int
    shape: tuple             # the (date, path) pairs the windows came from


def fold_windows(windows, seen, state_filter=None, excluded=(), readers=None):
    """Add per-file windows into one Tally, or reuse the last one unchanged.

    Folding is the expensive half, and on a rolling window it usually folds
    exactly what it folded last time: measured live at --watch 0.2 over a
    30-minute window, 184 of 199 consecutive ticks produced an identical count.
    TailReader.window returns the *same object* when neither edge moved and
    nothing was appended, so identity over the whole set is a complete test --
    and holding those objects is what keeps the identities meaningful.
    """
    # The filter belongs in the key: it decides what folding produces, and
    # nothing else here would notice a session reused with a different one.
    shape = (state_filter, seen.shape)
    if readers is not None and readers.tally is not None:
        was_shape, was_windows, was_tally = readers.tally
        if (was_shape == shape and len(was_windows) == len(windows)
                and all(a is b for a, b in zip(was_windows, windows))):
            # Counts are reused; the bookkeeping still describes this pass.
            return was_tally._replace(files=seen.files, parsed=seen.parsed,
                                      unreadable=seen.unreadable, reused=seen.reused)

    counts = Counter()
    breakdown = Counter()
    states = Counter()
    # Tracked across every state, not just the filtered one, because the header's
    # split is drawn before the filter: without this it counted the bots the
    # table had already thrown away, and sum(states) disagreed with the footer's
    # total by exactly the excluded messages.
    excluded_states = Counter()
    for window in windows:
        for (login, state), n in window.items():
            states[state] += n
            if login in excluded:
                excluded_states[state] += n
            if state_filter is None or state == state_filter:
                counts[login] += n
                breakdown[(login, state)] += n
    tally = Tally(counts, seen.files, sum(counts.values()), states, seen.parsed,
                  breakdown, seen.unreadable, seen.reused, excluded_states)
    if readers is not None:
        readers.tally = (shape, tuple(windows), tally)
    return tally


# --------------------------------------------------------------------------
# rollup cache
# --------------------------------------------------------------------------

# Everything that can change a cached number. The fingerprint below hashes the
# SOURCE of each entry, so editing a pattern or a parsing function invalidates
# the cache by itself -- there is no version constant to remember to bump. When
# a new feature changes what gets counted or how a message is classified, add
# whatever carries that logic to this tuple and stale caches rebuild on the next
# run.
CACHE_INPUTS = (
    FILENAME_RE,
    LINE_RE,
    LOGIN_RE,
    LOCALIZED_RE,
    LIVE_RE,
    STATES,
    speaker_login,
    fold_lines,      # the classification itself
    bucket_bounds,   # which seconds of a file a range covers
    sum_buckets,     # how buckets flatten into the counts that get stored
    TailReader,      # how a file is turned into buckets, whole or incrementally
    log_files,
)

CACHE_SCHEMA = """
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE IF NOT EXISTS generation(
    fingerprint TEXT PRIMARY KEY, last_seen TEXT NOT NULL
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS file(
    fingerprint TEXT NOT NULL, channel TEXT NOT NULL, date TEXT NOT NULL,
    size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
    enter_state TEXT, exit_state TEXT,
    PRIMARY KEY(fingerprint, channel, date)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS counts(
    fingerprint TEXT NOT NULL, channel TEXT NOT NULL, date TEXT NOT NULL,
    login TEXT NOT NULL, state TEXT NOT NULL, n INTEGER NOT NULL,
    PRIMARY KEY(fingerprint, channel, date, login, state)
) WITHOUT ROWID;
"""


@functools.cache
def cache_fingerprint():
    """Identity of the code that produces cached values.

    Hashes the *structure* of each entry in CACHE_INPUTS -- the AST with
    docstrings removed -- rather than its source text. Rewording a docstring or
    adding a blank line no longer throws away a 10MB cache; changing what gets
    counted still does.

    Memoized: the AST parse is cheap but the watch loop asks once per redraw.

    A Python upgrade can move ast.dump's output and so invalidate everything.
    That is the conservative direction, and it happens about as often as you
    upgrade Python.
    """
    parts = [f"schema={CACHE_SCHEMA_VERSION}"]
    for item in CACHE_INPUTS:
        if isinstance(item, re.Pattern):
            parts.append(f"pattern:{item.pattern}")
        elif callable(item):
            try:
                tree = ast.parse(textwrap.dedent(inspect.getsource(item)))
            except (OSError, TypeError, SyntaxError):
                # No source (frozen or interactive): fall back to the name, which
                # at least keeps the fingerprint stable rather than random.
                parts.append(f"callable:{getattr(item, '__name__', repr(item))}")
                continue
            for node in ast.walk(tree):
                if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef,
                                     ast.ClassDef, ast.Module)):
                    if ast.get_docstring(node) is not None:
                        node.body = node.body[1:]
            parts.append(ast.dump(tree))
        else:
            parts.append(repr(item))
    return hashlib.sha256("\n".join(parts).encode("utf-8")).hexdigest()[:16]


class CachedFile(NamedTuple):
    """One row of the cache's file table."""
    fingerprint: str
    size: int
    mtime_ns: int
    enter_state: str
    exit_state: str


def cache_row_valid(cached, stat, enter_state, fingerprint=None,
                    match_enter_state=True):
    """Is a cached day still usable?

    Three independent ways a row goes stale, and they are easy to conflate:

      - the log file changed, by size or mtime
      - the live/offline state *entering* the file changed, so a day carrying no
        markers of its own would now be classified differently
      - the parser that produced it is not the one asking

    The parser check is per row rather than per database on purpose. Wiping
    everything on a mismatch meant two versions of the script -- an editor and a
    long-running --watch, say -- destroyed each other's rows on every open, four
    times a second, so neither was ever cached. Tagged rows simply coexist.

    Kept separate from the SQL so the rules can be asserted without a database --
    the cache is where this session's two worst bugs lived, and it had no tests.
    """
    if cached is None:
        return False
    if fingerprint is not None and cached.fingerprint != fingerprint:
        return False
    if cached.size != stat.st_size or cached.mtime_ns != stat.st_mtime_ns:
        return False
    if match_enter_state and cached.enter_state != enter_state:
        return False
    return True


class Cache:
    """Day-level rollup of parsed logs.

    A cached day is trusted only when the log file still has the same size and
    mtime AND the live/offline state entering the file is the same as when it was
    parsed -- the second check is what keeps the state timeline honest, since a
    file with no markers of its own inherits its classification from earlier days.
    """

    def __init__(self, connection, path, rebuilt_reason, fingerprint, swept=0):
        self.connection = connection
        self.path = path
        self.rebuilt_reason = rebuilt_reason
        self.fingerprint = fingerprint
        self.swept = swept
        self.hits = 0

    @staticmethod
    def _connect(path):
        """Open the file and put the base schema in place. Returns (conn, existed)."""
        os.makedirs(os.path.dirname(path), exist_ok=True)
        existed = os.path.exists(path)
        connection = sqlite3.connect(path, timeout=10.0)
        connection.execute("PRAGMA journal_mode=WAL")
        connection.executescript(CACHE_SCHEMA)
        return connection, existed

    @staticmethod
    def _migrate(connection, existed):
        """Recreate the tables if they are the wrong shape. Returns a reason or None."""
        stored = connection.execute(
            "SELECT value FROM meta WHERE key = 'schema'").fetchone()
        if stored is not None and stored[0] == str(CACHE_SCHEMA_VERSION):
            return None
        # The tables themselves changed shape; nothing can be carried over.
        connection.executescript(
            "DROP TABLE IF EXISTS file;"
            "DROP TABLE IF EXISTS counts;"
            "DROP TABLE IF EXISTS generation;"
        )
        connection.executescript(CACHE_SCHEMA)
        connection.execute("INSERT OR REPLACE INTO meta VALUES('schema', ?)",
                           (str(CACHE_SCHEMA_VERSION),))
        return "new cache" if not existed else "new cache layout"

    @staticmethod
    def _register(connection, fingerprint, now):
        """Record this parser generation as seen. Returns a reason or None.

        `known` is read before the insert, so "have I been here before" is asked
        of the state this run inherited rather than the one it just created.
        """
        known = {row[0] for row in connection.execute(
            "SELECT fingerprint FROM generation")}
        connection.execute(
            "INSERT INTO generation VALUES(?, ?) ON CONFLICT(fingerprint) "
            "DO UPDATE SET last_seen = excluded.last_seen",
            (fingerprint, now.isoformat()),
        )
        # Informational: this parser has no rows yet, but nothing was lost.
        return "new parser generation" if known and fingerprint not in known else None

    @staticmethod
    def _sweep(connection, now):
        """Drop generations unseen for CACHE_KEEP_DAYS. Returns how many went."""
        cutoff = (now - timedelta(days=CACHE_KEEP_DAYS)).isoformat()
        stale = [row[0] for row in connection.execute(
            "SELECT fingerprint FROM generation WHERE last_seen < ?", (cutoff,))]
        for old in stale:
            connection.execute("DELETE FROM counts WHERE fingerprint = ?", (old,))
            connection.execute("DELETE FROM file WHERE fingerprint = ?", (old,))
            connection.execute("DELETE FROM generation WHERE fingerprint = ?", (old,))
        return len(stale)

    @staticmethod
    def _purge(connection, channel):
        """--rebuild-cache: discard a channel across every generation.

        The user asked for the channel, not for a version of the parser.
        """
        if channel is None:
            connection.execute("DELETE FROM counts")
            connection.execute("DELETE FROM file")
        else:
            connection.execute("DELETE FROM counts WHERE channel = ?", (channel,))
            connection.execute("DELETE FROM file WHERE channel = ?", (channel,))

    @classmethod
    def open(cls, path, rebuild=False, channel=None):
        """Open (creating if needed). Returns (cache, problem).

        A cache is an optimization and must never fail a query, so any failure
        yields (None, reason) and the run parses every file instead. But failing
        open and failing *silent* are different decisions, and this used to make
        only the first: an unusable cache was indistinguishable from a healthy
        one -- 6.6s rather than 0.4s on a large channel, no message, exit 0, and
        the sole hint was a header row that simply did not appear. The reason now
        travels back so the header can say what happened.

        The steps are separate functions so a failure names the one that broke
        rather than reporting "cache" for anything between a missing directory
        and a bad sweep.

        A parser change discards nothing: rows carry the fingerprint that produced
        them, so generations coexist and each run reads its own. Old generations
        go once they have been CACHE_KEEP_DAYS unseen.
        """
        if not path:
            return None, None    # no default location on this platform; not a fault
        connection, step = None, "connect"
        try:
            connection, existed = cls._connect(path)
            step = "migrate"
            reason = cls._migrate(connection, existed)
            step = "register"
            fingerprint = cache_fingerprint()
            now = datetime.now()
            # Registering is a side effect, not a reason lookup: it must happen
            # whether or not the migration already had something to report, so it
            # cannot sit on the right of an `or`. A fresh cache that skipped this
            # never recorded its own generation, and the next run then announced
            # itself as new.
            generation_reason = cls._register(connection, fingerprint, now)
            reason = reason or generation_reason
            step = "sweep"
            swept = cls._sweep(connection, now)
            if rebuild:
                step = "rebuild"
                cls._purge(connection, channel)
                reason = "--rebuild-cache"
            connection.commit()
            return cls(connection, path, reason, fingerprint, swept), None
        except (sqlite3.Error, OSError) as exc:
            if connection is not None:
                # Closing matters: run_watch reopens per tick, and a leaked handle
                # per failed tick is how this hit EMFILE once already.
                try:
                    connection.close()
                except sqlite3.Error:
                    pass
            return None, f"{step} failed -- {type(exc).__name__}: {exc}"

    def get(self, channel, file_date, stat, enter_state):
        """Cached (login, state) counts and exit state, or None if not usable."""
        try:
            row = self.connection.execute(
                "SELECT fingerprint, size, mtime_ns, enter_state, exit_state FROM file "
                "WHERE fingerprint = ? AND channel = ? AND date = ?",
                (self.fingerprint, channel, file_date.isoformat()),
            ).fetchone()
            cached = CachedFile(*row) if row else None
            if not cache_row_valid(cached, stat, enter_state, self.fingerprint):
                return None
            exit_state = cached.exit_state
            counts = Counter()
            for login, state, n in self.connection.execute(
                "SELECT login, state, n FROM counts "
                "WHERE fingerprint = ? AND channel = ? AND date = ?",
                (self.fingerprint, channel, file_date.isoformat()),
            ):
                counts[(login, state)] = n
            self.hits += 1
            return counts, exit_state
        except sqlite3.Error:
            return None

    def put(self, channel, file_date, stat, enter_state, exit_state, day_counts):
        try:
            date = file_date.isoformat()
            self.connection.execute(
                "DELETE FROM counts WHERE fingerprint = ? AND channel = ? AND date = ?",
                (self.fingerprint, channel, date),
            )
            self.connection.executemany(
                "INSERT INTO counts VALUES(?, ?, ?, ?, ?, ?)",
                [
                    (self.fingerprint, channel, date, login, state, n)
                    for (login, state), n in day_counts.items()
                ],
            )
            self.connection.execute(
                "INSERT OR REPLACE INTO file VALUES(?, ?, ?, ?, ?, ?, ?)",
                (self.fingerprint, channel, date, stat.st_size, stat.st_mtime_ns,
                 enter_state, exit_state),
            )
            self.connection.commit()
        except sqlite3.Error:
            pass

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False

    def close(self):
        """Release the connection.

        One-shot runs could leave this to process exit, but --watch calls the
        report once a second: each connection holds the database plus its WAL and
        shared-memory files, so an unclosed one leaks two descriptors a tick and
        eventually takes the process out with EMFILE.
        """
        try:
            self.connection.close()
        except sqlite3.Error:
            pass

    def exit_state(self, channel, file_date, stat):
        """The state a cached day ended in, or None when it can't be answered."""
        try:
            row = self.connection.execute(
                "SELECT fingerprint, size, mtime_ns, enter_state, exit_state FROM file "
                "WHERE fingerprint = ? AND channel = ? AND date = ?",
                (self.fingerprint, channel, file_date.isoformat()),
            ).fetchone()
        except sqlite3.Error:
            return None
        cached = CachedFile(*row) if row else None
        # The entering state is irrelevant here: we only want what the day ended
        # in, which does not depend on how it began.
        if not cache_row_valid(cached, stat, None, self.fingerprint,
                               match_enter_state=False):
            return None
        return cached.exit_state


# --------------------------------------------------------------------------
# shell completion
# --------------------------------------------------------------------------

# dest -> how the emitted fish completion should offer values for that flag.
VALUE_COMPLETIONS = {
    "exclude_group": ("dynamic", "groups"),
    "exclude": ("dynamic", "users"),
    "include": ("dynamic", "includes"),
    "begin": ("dynamic", "periods"),
    "since": ("static", "6h 12h 7d 14d 30d 90d"),
    "watch": ("static", "0.5 1 2 5 10"),
    "watch_hold": ("static", "0 1 3 5 10 30"),
    "color": ("static", "auto always never"),
    # "show" and "sort" are filled in by fish_completions() from METRICS, which
    # is defined further down.
    "config": ("file", None),
}

FISH_HELPERS = """\
# Pass along the channel and config already typed on the command line, so the
# candidates match the run the user is actually composing.
function __twitch_counts_context
    set -l tokens (commandline -opc)
    set -l count (count $tokens)
    set -l args
    for i in (seq $count)
        switch $tokens[$i]
            case -c --channel
                test $count -gt $i; and set -a args --channel $tokens[(math $i + 1)]
            case --config
                test $count -gt $i; and set -a args --config $tokens[(math $i + 1)]
            case --no-config
                set -a args --no-config
        end
    end
    # An empty printf would emit a bare newline, which fish turns into one
    # empty-string argument -- enough to make argparse reject the call.
    if set -q args[1]
        printf '%s\\n' $args
    end
end

function __twitch_counts_complete
    twitch-counts --complete $argv[1] (__twitch_counts_context) 2>/dev/null
end"""


# Read straight from os.environ rather than through the settings table: the
# config path is needed before any of it resolves, and the window start and the
# exclusion layers merge across sources in ways a single Spec cannot express.
UNTABLED_ENVIRONMENT = (
    ("TWITCH_COUNTS_CONFIG", "which config file to load"),
    ("TWITCH_BEGIN", "start of the range, as --begin"),
    ("TWITCH_SINCE", "how far before --end to start, as --since"),
    ("TWITCH_EXCLUDE", "logins to exclude; adds to the config groups"),
)

# Where --manual grows its environment section. Written there as a marker rather
# than a list, because the two hand-kept lists this replaces had drifted to 8
# and 13 of the 35 variables that actually work.
ENVIRONMENT_PLACEHOLDER = "{{ENVIRONMENT}}"


def environment_names():
    """Every environment variable this program reads, with what it sets."""
    # The long flag where there is one, otherwise whatever the Spec calls
    # itself -- which for a config-only setting is its table path, and for a
    # hand-declared one the flag as written. lstrip("-") mangled
    # "--live/--offline/--unknown" into "live/--offline/--unknown".
    named = [(spec.env, spec.flags[-1] if spec.flags else spec.flag)
             for spec in SETTINGS if spec.env]
    return sorted(named + list(UNTABLED_ENVIRONMENT))


def environment_manual():
    """The environment section of --manual, as one block of text."""
    names = environment_names()
    width = max(len(name) for name, _ in names)
    head = (f"Environment variables ({len(names)}). Each is overridden by its flag "
            f"and\noverrides the config file:\n")
    body = "\n".join(f"    {name:<{width}}  {what}" for name, what in names)
    return head + body


def fish_quote(text):
    """Escape a string for a fish single-quoted literal."""
    return text.replace("\\", "\\\\").replace("'", "\\'")


def fish_completions(command="twitch-counts"):
    """Emit fish completions derived from the parser, so they cannot drift from it."""
    parser = build_parser()
    # Metric names come from METRICS itself, so a new metric completes without
    # anyone editing a list of strings.
    value_sources = dict(VALUE_COMPLETIONS)
    value_sources.update({spec.name: spec.complete for spec in SETTINGS if spec.complete})
    lines = [
        f"# fish completions for {command} -- GENERATED, edits will be lost.",
        f"# Regenerate: {command} --emit-fish-completions > "
        f"~/.config/fish/completions/{command}.fish",
        "",
        FISH_HELPERS,
        "",
        f"# No bare filename completion; flags that want paths ask for it below.",
        f"complete -c {command} -f",
    ]
    # parser._actions is the only way to walk registered arguments; the shape of
    # each action (option_strings, nargs, help, dest) is stable public data.
    for action in parser._actions:
        if not action.option_strings or action.help == argparse.SUPPRESS:
            continue
        parts = [f"complete -c {command}"]
        for option in action.option_strings:
            parts.append(f"-l {option[2:]}" if option.startswith("--") else f"-s {option[1:]}")
        if action.nargs != 0:
            kind, payload = value_sources.get(action.dest, (None, None))
            if kind == "dynamic":
                parts.append(f"-x -a '(__twitch_counts_complete {payload})'")
            elif kind == "static":
                parts.append(f"-x -a '{payload}'")
            elif kind == "dir":
                parts.append("-x -a '(__fish_complete_directories)'")
            elif kind == "file":
                parts.append("-r -F")
            else:
                parts.append("-x")
        if action.help:
            parts.append(f"-d '{fish_quote(action.help)}'")
        lines.append(" ".join(parts))
    return "\n".join(lines)


class CompletionSite(NamedTuple):
    """What a completion handler is given.

    Built in stages so a handler only pays for what it needs: `channel_dir` and
    `channel_name` are None unless the kind asked for a channel.
    """
    args: object
    config: dict
    config_path: str
    logs_root: str
    aliases: dict
    channel_dir: str = None
    channel_name: str = None


def complete_groups(site):
    return sorted(config_exclusions(site.config, site.config_path).groups)


def complete_channels(site):
    names = set(site.aliases)
    if os.path.isdir(site.logs_root):
        names.update(
            name for name in os.listdir(site.logs_root)
            if os.path.isdir(os.path.join(site.logs_root, name))
        )
    return sorted(names)


def complete_dates(site):
    return [date.isoformat() for date in log_dates(site.channel_dir)]


def complete_weeks(site):
    weeks = []
    for date in log_dates(site.channel_dir):
        year, week, _ = date.isocalendar()
        token = f"{year}-W{week:02d}"
        if token not in weeks:
            weeks.append(token)
    return weeks


def complete_periods(site):
    # Both forms are offered; fish sorts them itself, and typing "2026-W"
    # narrows to weeks straight away.
    return complete_weeks(site) + complete_dates(site)


def complete_includes(site):
    # Only what the merged exclusions would actually drop is worth re-including.
    return sorted(build_exclusions(
        site.args, site.config, site.config_path, site.channel_name
    ).logins)


def complete_users(site):
    end = datetime.now().replace(microsecond=0)
    begin = end - timedelta(days=USER_COMPLETION_DAYS)
    cache, _ = Cache.open(DEFAULT_CACHE_PATH)
    counts = count_messages(
        site.channel_dir, begin, end, cache=cache, channel=site.channel_name
    ).counts
    if cache is not None:
        cache.close()
    groups, _, flat = config_exclusions(site.config, site.config_path)
    known = set(flat)
    for members in groups.values():
        known.update(members)
    # Recent chatters first, then configured names that haven't spoken lately.
    return [login for login, _ in counts.most_common()] + sorted(known - set(counts))


# kind -> (handler, needs a resolved channel). COMPLETE_KINDS is derived from
# this, so the list of kinds and the code that serves them cannot drift apart.
COMPLETIONS = {
    "channels": (complete_channels, False),
    "groups": (complete_groups, False),
    "dates": (complete_dates, True),
    "weeks": (complete_weeks, True),
    "periods": (complete_periods, True),
    "users": (complete_users, True),
    "includes": (complete_includes, True),
}
COMPLETE_KINDS = tuple(COMPLETIONS)


def completion_candidates(args):
    """Candidates for --complete KIND, resolved through the same config as a real run."""
    handler, needs_channel = COMPLETIONS[args.complete]
    config, config_path, _ = load_config_layer(args)
    logs_dir = resolve(
        "logs-dir", args.logs_dir, "TWITCH_LOGS_DIR", config, config_path, "logs_dir",
        default=DEFAULT_LOGS_DIR,
    )
    aliases = config.get("aliases") if isinstance(config.get("aliases"), dict) else {}
    site = CompletionSite(args, config, config_path,
                          os.path.expanduser(str(logs_dir.value)), aliases)
    if needs_channel:
        channel = resolve("channel", args.channel, "TWITCH_CHANNEL",
                          config, config_path, "channel")
        if not channel:
            return []
        key = str(channel.value)
        channel_dir, channel_name = resolve_channel_dir(
            site.logs_root, str(aliases.get(key, key))
        )
        site = site._replace(channel_dir=channel_dir, channel_name=channel_name)
    return handler(site)


def run_completion(args):
    """Print candidates one per line. Completion must never fail loudly at a prompt."""
    try:
        candidates = completion_candidates(args)
    except (ConfigError, Unsupported, OSError, ValueError, TypeError, KeyError) as exc:
        # fish discards stderr, so this stays quiet at a prompt while still being
        # visible when the command is run by hand -- a broken completion should
        # not look like "no candidates".
        print(f"completion failed: {exc!r}", file=sys.stderr)
        return 0
    for candidate in candidates:
        print(candidate)
    return 0


# --------------------------------------------------------------------------
# per-user metrics
# --------------------------------------------------------------------------

# Ranking by a ratio puts every one-message user at 100%, so a share sort needs a
# sample floor of its own -- 106 of this data's 174 chroniccmposer users have
# fewer than five messages.
DEFAULT_SHARE_FLOOR = 10


class Metric:
    """A per-user column: how to compute it, label it, and print it."""

    def __init__(self, name, header, kind, get, description):
        self.name = name
        self.header = header
        self.kind = kind  # "count" or "share"
        self.get = get
        self.description = description

    def render(self, states, total):
        value = self.get(states, total)
        return f"{value:.1f}%" if self.kind == "share" else f"{value:,}"


def _state_count(state):
    return lambda states, total: states.get(state, 0)


def _state_share(state):
    # Denominator is the user's whole total, unknown included, so the shares of
    # a user's states always add up to 100%.
    return lambda states, total: (100.0 * states.get(state, 0) / total) if total else 0.0


METRICS = {
    metric.name: metric
    for metric in (
        Metric("count", "count", "count", lambda states, total: total,
               "Messages sent in range."),
        Metric("live", "live", "count", _state_count("live"),
               "Messages sent while the channel was live."),
        Metric("offline", "offline", "count", _state_count("offline"),
               "Messages sent while the channel was offline."),
        Metric("unknown", "unknown", "count", _state_count("unknown"),
               "Messages no live/offline marker could place."),
        Metric("offline-share", "offline%", "share", _state_share("offline"),
               "Share of this user's messages sent while offline."),
        Metric("live-share", "live%", "share", _state_share("live"),
               "Share of this user's messages sent while live."),
    )
}

# --by-state is shorthand for this column set; 'unknown' joins it only when the
# range actually contains unplaceable messages.
BY_STATE_COLUMNS = ("live", "offline", "offline-share")
STATE_METRICS = {"live", "offline", "unknown", "offline-share", "live-share"}
SORT_CHOICES = ("count", "login") + tuple(
    name for name in METRICS if name != "count"
)


def parse_metrics(text):
    """Parse metric names from a list or a comma/space separated string.

    Idempotent: argparse converts the flag once, and the layered resolution runs
    the same parser again over whatever env or config supplied.
    """
    items = (
        text if isinstance(text, (list, tuple))
        else re.split(r"[,\s]+", str(text).strip())
    )
    names = []
    for item in items:
        name = str(item).strip()
        if not name:
            continue
        if name not in METRICS:
            raise argparse.ArgumentTypeError(
                f"unknown column {name!r} (choose from: {', '.join(sorted(METRICS))})"
            )
        if name not in names:
            names.append(name)
    return names


def parse_sort(text):
    name = str(text).strip().lower()
    if name not in SORT_CHOICES:
        raise argparse.ArgumentTypeError(
            f"unknown sort {name!r} (choose from: {', '.join(sorted(SORT_CHOICES))})"
        )
    return name


def sort_rows(rows, sort_name, states_by_login):
    """Order (login, count) rows by the chosen metric, ties broken by login."""
    if sort_name == "login":
        return sorted(rows, key=lambda row: row[0])
    metric = METRICS[sort_name]
    return sorted(
        rows,
        key=lambda row: (-metric.get(states_by_login.get(row[0], {}), row[1]), row[0]),
    )


# --------------------------------------------------------------------------
# JSON report
# --------------------------------------------------------------------------

JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"
# The $id carries the major version, so a consumer pinned to one never silently
# receives a document shaped like another. 2.0.0 turned query.share_floor from an
# integer-or-null into {requested, applied}: as a bare integer it could not say
# whether a floor that was asked for had actually acted, which made an ignored
# --share-floor indistinguishable from one nobody set.
REPORT_SCHEMA_ID = "urn:twitch-counts:report:2"
REPORT_SCHEMA_VERSION = "2.1.0"


class JsonField:
    """One field, described once for both the payload and the embedded schema.

    The value and its description come from the same object, so the schema
    shipped with a document cannot drift from the document it describes.
    """

    def __init__(self, name, json_type, description, get, fmt=None, nullable=False,
                 items=None):
        self.name = name
        self.json_type = json_type
        self.description = description
        self.get = get
        self.fmt = fmt
        self.nullable = nullable
        self.items = items

    def schema(self):
        node = {
            "type": [self.json_type, "null"] if self.nullable else self.json_type,
            "description": self.description,
        }
        if self.fmt:
            node["format"] = self.fmt
        if self.items:
            node["items"] = self.items
        return node


def report_sources(report):
    """Where each reported setting came from, including the derived ones.

    The only entry in QUERY_FIELDS that computes rather than reads, because the
    window start, the row cap and the exclusion list each resolve through a path
    the settings table cannot describe on its own.
    """
    context, settings = report.context, report.context.settings
    return settings.sources(
        begin=context.window.start_source,
        top=report.presentation.limit_source,
        state=(settings["state"].source if settings["state"] else "not filtered"),
        exclude=", ".join(report.selection.exclude_sources) or "none",
    )


# Both tables read a Report directly. They used to read a flat dict that
# emit_json built by unpacking that same Report -- twenty-odd keys, all but one a
# rename of a field one attribute away. That mapping was hand-maintained, so a
# record which grew a field reached the text header automatically and reached
# JSON only if someone remembered; the share floor is exactly where that failed.
QUERY_FIELDS = (
    JsonField("channel", "string", "Channel whose logs were counted.",
              lambda r: r.context.channel_name),
    JsonField("begin", "string", "Inclusive start of the counted range.",
              lambda r: r.context.window.begin.isoformat(), fmt="date-time"),
    JsonField("end", "string", "Inclusive end of the counted range.",
              lambda r: r.context.window.end.isoformat(), fmt="date-time"),
    JsonField("min_count", "integer", "Minimum messages required to appear in rows.",
              lambda r: r.context.window.threshold),
    JsonField("top", "integer", "Row cap applied, or null when unlimited.",
              lambda r: r.presentation.limit, nullable=True),
    JsonField("state", "string",
              "Stream-state filter applied (live, offline, unknown), or null for none.",
              lambda r: r.context.window.state_filter, nullable=True),
    JsonField("excluded", "array", "Logins excluded from the counts.",
              lambda r: sorted(r.selection.excluded), items={"type": "string"}),
    JsonField("sort", "string", "Metric the rows are ordered by, descending.",
              lambda r: r.presentation.sort_name),
    JsonField("share_floor", "object",
              "The --share-floor filter. Keys: requested (integer) -- the value "
              "resolved from flag, environment, config or built-in default; and "
              "applied (boolean) -- false when no share was shown or sorted by, "
              "so the floor had nothing to act on, or when it was set to 0. How "
              "many users it dropped is totals.users_below_share_floor. Reporting "
              "both is what tells a floor nobody asked for apart from one that "
              "was asked for and silently did nothing.",
              lambda r: {"requested": r.context.settings["share_floor"].value,
                         "applied": r.presentation.share_floor is not None}),
    JsonField("sources", "object",
              "Where each setting came from: a flag, an environment variable, "
              "the config file, or a default.",
              report_sources),
)

TOTALS_FIELDS = (
    JsonField("users_shown", "integer", "Users present in rows.",
              lambda r: len(r.presentation.displayed)),
    JsonField("users_above_threshold", "integer",
              "Users meeting min_count, before any row cap.",
              lambda r: len(r.presentation.reported)),
    JsonField("users_in_range", "integer",
              "Users with any message in range, after exclusions.",
              lambda r: len(r.selection.counts)),
    JsonField("users_excluded", "integer",
              "Excluded logins that actually appeared in range.",
              lambda r: len(r.selection.excluded_counts)),
    JsonField("messages_shown", "integer", "Messages attributed to users in rows.",
              lambda r: sum(n for _, n in r.presentation.displayed)),
    JsonField("messages_in_range", "integer",
              "Messages in range after exclusions and the state filter.",
              lambda r: r.selection.total_messages),
    JsonField("messages_hidden", "integer", "Messages held by users the row cap dropped.",
              lambda r: sum(n for _, n in r.presentation.hidden)),
    JsonField("messages_excluded", "integer", "Messages removed by exclusions.",
              lambda r: sum(r.selection.excluded_counts.values())),
    JsonField("truncated", "boolean", "True when the row cap dropped users.",
              lambda r: bool(r.presentation.hidden)),
    JsonField("states", "object",
              "Messages in range by stream state, before the state filter. "
              "Keys are live, offline and unknown; absent keys mean zero.",
              lambda r: {k: r.selection.states[k] for k in STATES
                         if r.selection.states[k]}),
    JsonField("log_files", "integer", "Log files covering the range.",
              lambda r: r.selection.files),
    JsonField("users_below_share_floor", "integer",
              "Users meeting min_count but dropped by the share floor.",
              lambda r: r.presentation.below_floor),
    JsonField("cache", "object",
              "Whether the day-rollup cache served this query. Keys: used "
              "(boolean), days_reused (integer), and problem (string or null) "
              "naming the step that failed when the cache could not be opened "
              "and every file had to be parsed instead.",
              lambda r: {"used": r.selection.cache is not None,
                         "days_reused": r.selection.cache.hits
                         if r.selection.cache else 0,
                         "problem": r.selection.cache_problem}),
    JsonField("unreadable", "array",
              "Log files inside the range that could not be read and were "
              "skipped, each an object with 'file' and 'problem'. Empty on a "
              "complete count. A non-empty list means these numbers omit whole "
              "days, and that chat after each gap may read as 'unknown' because "
              "the stream state could not be carried across it.",
              lambda r: [{"file": name, "problem": why}
                         for name, why in r.selection.unreadable],
              items={"type": "object"}),
)

ROW_FIELDS = (
    JsonField("login", "string", "Twitch login, lowercased.", lambda row: row[0]),
    JsonField("count", "integer", "Messages sent in range.", lambda row: row[1]),
    JsonField("states", "object",
              "This user's messages by stream state. Keys are live, offline and "
              "unknown; absent keys mean zero. Shares are left to the consumer: "
              "offline share is states.offline / count.",
              lambda row: {state: n for state, n in sorted(row[2].items()) if n}),
)


def _object_schema(fields, description):
    return {
        "type": "object",
        "description": description,
        "additionalProperties": False,
        "required": [field.name for field in fields],
        "properties": {field.name: field.schema() for field in fields},
    }


def report_schema():
    """JSON Schema (2020-12) for the document this program emits."""
    return {
        "$schema": JSON_SCHEMA_DIALECT,
        "$id": REPORT_SCHEMA_ID,
        "title": "twitch-counts report",
        "description": (
            "Per-user Twitch chat message counts for one channel over a time range, "
            "derived from Chatterino logs."
        ),
        "type": "object",
        "additionalProperties": False,
        "required": ["schema_version", "generated_at", "query", "totals", "rows"],
        "properties": {
            "schema": {
                "type": "object",
                "description": "This schema, embedded so the document explains itself.",
            },
            "schema_version": {
                "type": "string",
                "description": "Semantic version of this report format.",
            },
            "generated_at": {
                "type": "string",
                "format": "date-time",
                "description": "When the report was produced.",
            },
            "query": _object_schema(QUERY_FIELDS, "What was asked for, and where each setting came from."),
            "totals": _object_schema(TOTALS_FIELDS, "Counts describing the range and what was withheld."),
            "rows": {
                "type": "array",
                "description": (
                    "Users ordered by query.sort descending, ties broken by login."
                ),
                "items": _object_schema(ROW_FIELDS, "One user's message count."),
            },
        },
    }


def build_report(report):
    """The self-describing report document."""
    states_by_login = report.selection.states_by_login
    return {
        "schema": report_schema(),
        "schema_version": REPORT_SCHEMA_VERSION,
        "generated_at": datetime.now().replace(microsecond=0).isoformat(),
        "query": {field.name: field.get(report) for field in QUERY_FIELDS},
        "totals": {field.name: field.get(report) for field in TOTALS_FIELDS},
        "rows": [
            {
                field.name: field.get((login, count, states_by_login.get(login, {})))
                for field in ROW_FIELDS
            }
            for login, count in report.presentation.displayed
        ],
    }


# --------------------------------------------------------------------------
# settings table
# --------------------------------------------------------------------------

class Spec(NamedTuple):
    """One setting, declared once and used four ways.

    From a single row we build the argparse argument, the layered resolution, the
    fish completion candidates, and the JSON `sources` entry. Keeping them in one
    place is what stops them disagreeing -- --show and --sort were in the text
    header but missing from JSON until the resolution half was unified, and the
    flag declarations were a third copy of the same knowledge.

    Settings that do not fit this shape (--live/--offline/--unknown sharing one
    value, --watch's optional argument, the mutually exclusive groups) stay
    hand-written in build_parser; `flags` empty means "resolved here, declared
    there".
    """
    name: str          # attribute on the parsed args, and the JSON sources key
    flag: str          # what to call it in an error message
    env: str           # environment variable
    key: str           # config key
    parser: object     # converts the resolved value, or None to take it as-is
    default: object = None
    default_note: str = "default"
    flags: tuple = ()  # argparse option strings; empty means declared by hand
    help: str = ""
    metavar: str = ""
    complete: object = None  # completion spec, as in VALUE_COMPLETIONS
    section: str = ""        # config sub-table consulted first, when active
    # callable(args) -> (value, note), for a default that depends on the run
    default_when: object = None
    # False for knobs that tune how the tool runs rather than what it reports;
    # they resolve like everything else but do not belong in a report's sources.
    report: bool = True

    def add_to(self, parser):
        """Declare this setting as an argparse argument."""
        if not self.flags:
            return
        kwargs = {"help": self.help}
        if self.parser is not None:
            kwargs["type"] = self.parser
        if self.metavar:
            kwargs["metavar"] = self.metavar
        parser.add_argument(*self.flags, **kwargs)


SETTINGS = (
    Spec("channel", "--channel", "TWITCH_CHANNEL", "channel", None,
         flags=("-c", "--channel"),
         help="Twitch channel name (case-insensitive)",
         complete=("dynamic", "channels")),
    Spec("users_policy", "--users-policy", "TWITCH_USERS_POLICY", "users_policy",
         parse_users_policy, "at-least", "built-in default",
         flags=("--users-policy",), metavar="HOW",
         help="how to settle when no window gives exactly --users: "
              "at-least, at-most or nearest (default: at-least)",
         complete=("static", " ".join(USER_POLICIES)), report=False),
    Spec("users_max", "--users-max", "TWITCH_USERS_MAX", "users_max", parse_duration,
         timedelta(hours=24), "built-in default",
         flags=("--users-max",), metavar="DURATION",
         help="widest window --users may search (default: 24h)",
         complete=("static", "1h 6h 24h 7d"), report=False),
    Spec("end", "--end", "TWITCH_END", "end", None,
         flags=("-e", "--end"), help="end of the range (default: now)",
         complete=("dynamic", "periods")),
    Spec("min_count", "--min-count", "TWITCH_MIN_COUNT", "min_count", positive_int,
         DEFAULT_MIN_COUNT, "built-in default",
         flags=("-m", "--min-count"),
         help=f"only report users with at least this many messages "
              f"(default: {DEFAULT_MIN_COUNT})",
         complete=("static", "10 25 50 100 500")),
    Spec("show", "--show", "TWITCH_SHOW", "show", parse_metrics,
         flags=("--show",), metavar="COL[,COL...]",
         help="extra columns: "
              + ", ".join(sorted(n for n in METRICS if n != "count")),
         complete=("static", " ".join(sorted(n for n in METRICS if n != "count")))),
    Spec("sort", "--sort", "TWITCH_SORT", "sort", parse_sort,
         flags=("--sort",), metavar="METRIC",
         help="order rows by: " + ", ".join(sorted(SORT_CHOICES)) + " (default: count)",
         complete=("static", " ".join(sorted(SORT_CHOICES)))),
    Spec("share_floor", "--share-floor", "TWITCH_SHARE_FLOOR", "share_floor",
         nonnegative_int, DEFAULT_SHARE_FLOOR, "built-in default",
         flags=("--share-floor",), metavar="N",
         help="messages needed to be listed when a share is shown or sorted by, "
              f"0 to disable (default: {DEFAULT_SHARE_FLOOR})",
         complete=("static", "0 5 10 25 50 100")),
    Spec("top", "--top", "TWITCH_TOP", "top", nonnegative_int,
         flags=("-n", "--top"), metavar="N",
         help="show at most N rows, 0 for unlimited "
              "(default: what fits the terminal; unlimited when piped)",
         complete=("static", "10 20 25 50 100 0")),
    Spec("logs_dir", "--logs-dir", "TWITCH_LOGS_DIR", "logs_dir", None,
         DEFAULT_LOGS_DIR, "built-in default",
         flags=("-d", "--logs-dir"),
         help="Chatterino Twitch Channels directory",
         complete=("dir", None)),
    Spec("header", "--header", "TWITCH_HEADER", "header", parse_header,
         flags=("--header",), metavar="MODE",
         help="provenance block: full, compact or none "
              "(default: full, or compact under --watch)",
         complete=("static", " ".join(HEADER_MODES)),
         section="watch",
         # Watch redraws the block several times a second and 9 of its 11 rows
         # never change, so one line is the better default there.
         default_when=lambda args: ("compact", "default under --watch")
                                   if args.watch is not None else ("full", "default")),
    Spec("state", "--live/--offline/--unknown", "TWITCH_STATE", "state", parse_state),

    # Section settings: resolved from this table like everything else, declared
    # nowhere (flags=()) because they come from [watch]/[tail] or, for the two
    # that have flags, from --watch and --watch-hold via cli_overrides.
    Spec("interval", "--watch", "TWITCH_WATCH_INTERVAL", "interval",
         nonnegative_float, 1.0, "built-in default", section="watch", report=False),
    Spec("min_interval", "watch.min_interval", "TWITCH_WATCH_MIN_INTERVAL",
         "min_interval", nonnegative_float, 0.1, "built-in default", section="watch", report=False),
    Spec("hold", "--watch-hold", "TWITCH_WATCH_HOLD", "hold", nonnegative_float,
         3.0, "built-in default", section="watch", report=False),
    Spec("fade_up", "watch.fade_up", "TWITCH_WATCH_FADE_UP", "fade_up",
         parse_hex_colour, "#87ff87", "built-in default", section="watch", report=False),
    Spec("fade_down", "watch.fade_down", "TWITCH_WATCH_FADE_DOWN", "fade_down",
         parse_hex_colour, "#8a8a8a", "built-in default", section="watch", report=False),
    Spec("shades", "watch.shades", "TWITCH_WATCH_SHADES", "shades", positive_int,
         3, "built-in default", section="watch", report=False),
    Spec("user_width", "watch.user_width", "TWITCH_WATCH_USER_WIDTH", "user_width",
         nonnegative_int, 20, "built-in default", section="watch", report=False),
    Spec("full_repaint", "watch.full_repaint", "TWITCH_WATCH_FULL_REPAINT",
         "full_repaint", nonnegative_int, 50, "built-in default", section="watch",
         report=False),
    # Declared by hand in build_parser: a store_true flag needs default=None so
    # that not passing it stays distinguishable from passing --streamer false,
    # which is what lets the config still win when the flag is absent.
    Spec("streamer_mode", "--streamer", "TWITCH_WATCH_STREAMER_MODE",
         "streamer_mode", parse_bool, False, "built-in default", section="watch",
         report=False),
    Spec("min_redraw", "watch.min_redraw", "TWITCH_WATCH_MIN_REDRAW", "min_redraw",
         nonnegative_float, 0.25, "built-in default", section="watch", report=False),
    Spec("show_timing", "watch.show_timing", "TWITCH_WATCH_SHOW_TIMING",
         "show_timing", parse_bool, False, "built-in default", section="watch",
         report=False),
    Spec("tint_falling", "watch.tint_falling", "TWITCH_WATCH_TINT_FALLING",
         "tint_falling", parse_bool, True, "built-in default", section="watch",
         report=False),
    Spec("fade_curve", "watch.fade_curve", "TWITCH_WATCH_FADE_CURVE", "fade_curve",
         parse_curve, "linear", "built-in default", section="watch", report=False),
    Spec("fade_k", "watch.fade_k", "TWITCH_WATCH_FADE_K", "fade_k", positive_float,
         1.0, "built-in default", section="watch", report=False),
    Spec("highlight", "watch.highlight", "TWITCH_WATCH_HIGHLIGHT", "highlight",
         parse_highlights, (), "built-in default", section="watch", report=False),
    Spec("replay_steps", "watch.replay_steps", "TWITCH_WATCH_REPLAY_STEPS",
         "replay_steps", nonnegative_int, 200, "built-in default", section="watch",
         report=False),
    Spec("notify", "tail.notify", "TWITCH_TAIL_NOTIFY", "notify", parse_bool,
         True, "built-in default", section="tail", report=False),
    Spec("max_events", "tail.max_events", "TWITCH_TAIL_MAX_EVENTS", "max_events",
         positive_int, 4, "built-in default", section="tail", report=False),
    Spec("seed_lookback", "tail.seed_lookback", "TWITCH_TAIL_SEED_LOOKBACK",
         "seed_lookback", positive_int, 30, "built-in default", section="tail", report=False),
)
SETTINGS_BY_NAME = {spec.name: spec for spec in SETTINGS}


class Resolved:
    """Resolved settings, keyed by name, each keeping where it came from."""

    def __init__(self, settings):
        self._settings = settings

    def __getitem__(self, name):
        return self._settings[name]

    def replace(self, name, setting):
        """Re-label or re-value a setting after resolution.

        Two settings are refined once more is known: --live/--offline/--unknown
        share one Spec but should name the flag actually typed, and a channel
        alias rewrites both value and source. Going through here keeps the header
        rows and the JSON sources map in step with the local variable.
        """
        self._settings[name] = setting
        return setting

    def value(self, name, fallback=None):
        setting = self._settings[name]
        return fallback if setting.value is None else setting.value

    def source(self, name):
        return self._settings[name].source

    def sources(self, **extra):
        """The provenance map, for the JSON payload.

        Sorted so the payload is canonical: reordering SETTINGS should not change
        a byte of output.
        """
        found = {name: s.source for name, s in self._settings.items()
                 if s.value is not None and SETTINGS_BY_NAME[name].report}
        found.update(extra)
        return dict(sorted(found.items()))


def resolve_settings(args, config, config_path, cli_overrides=None, sections=()):
    """Walk SETTINGS once, resolving and converting each entry.

    `sections` names the config sub-tables that apply to this run -- ("watch",)
    while watching -- so a Spec can prefer [watch] over the top level.
    """
    overrides = cli_overrides or {}
    for section in {spec.section for spec in SETTINGS if spec.section}:
        table = config.get(section)
        if table is not None and not isinstance(table, dict):
            raise ConfigError(
                f"[{section}] in {shorten_path(config_path)} must be a table")
    out = {}
    for spec in SETTINGS:
        cli = overrides.get(spec.name, getattr(args, spec.name, None))
        default, default_note = spec.default, spec.default_note
        if spec.default_when is not None:
            default, default_note = spec.default_when(args)
        setting = resolve(spec.flag.lstrip("-"), cli, spec.env, config, config_path,
                          spec.key, default=default, default_note=default_note,
                          section=spec.section if spec.section in sections else None)
        # resolve() labels a CLI hit with the attribute name; use the real flag.
        if setting.source == spec.flag.lstrip("-"):
            setting = Setting(setting.value, spec.flag)
        if spec.parser is not None and setting.value is not None:
            setting = Setting(convert(setting, spec.parser, spec.flag), setting.source)
        out[spec.name] = setting
    return Resolved(out)


# --------------------------------------------------------------------------
# watch mode
# --------------------------------------------------------------------------

def watch_interval(text):
    """Parse --watch's optional value.

    With nargs='?' argparse runs `type` over a string `const` too, so the "take
    the interval from config" sentinel arrives here and has to pass through
    untouched rather than being parsed as a number.
    """
    if text == WATCH_FROM_CONFIG:
        return WATCH_FROM_CONFIG
    return nonnegative_float(text)


def resolve_watch(args, config, config_path):
    """Watch settings, read out of the resolved table and validated together."""
    settings = resolve_settings(
        args, config, config_path,
        {"interval": args.watch if isinstance(args.watch, (int, float)) else None,
         "hold": args.watch_hold},
        sections=("watch", "tail"),
    )
    interval, floor = settings["interval"], settings["min_interval"]
    if interval.value < floor.value:
        raise ConfigError(
            f"{source_label('--watch', interval)}: interval must be at least "
            f"{floor.value:g}s ({source_label('watch.min_interval', floor)})"
        )
    highlights = settings["highlight"].value or ()
    if settings["streamer_mode"].value:
        # Going live is a moment, not a configuration. The rules stay in the
        # config and stay parsed -- a bad pattern is still an error -- they just
        # colour nothing, record nothing, and build no ramps. Nothing is added to
        # the header about them either: an on-screen note that highlights exist
        # and are suppressed is itself the thing being hidden.
        highlights = ()
    # One mechanism for every palette: a colour, and the same number of shades
    # fading it toward the foreground along the same curve. Rise, fall and each
    # highlight therefore expire to plain together, however they got there --
    # `hold` still bounds every tint, and only the path within it is skewed.
    shades = settings["shades"].value
    curve, k = settings["fade_curve"].value, settings["fade_k"].value
    ramps = {"up": hex_ramp(settings["fade_up"].value, shades, curve, k)}
    if settings["tint_falling"].value:
        ramps["down"] = hex_ramp(settings["fade_down"].value, shades, curve, k)
    for index, rule in enumerate(highlights):
        # Each rule already builds its own ramp, so letting it carry its own
        # curve costs two arguments rather than a second fade mechanism.
        ramps[highlight_key(index)] = hex_ramp(
            rule.rgb, shades,
            curve if rule.curve is None else rule.curve,
            k if rule.k is None else rule.k,
        )
    for key, ramp in ramps.items():
        # A ramp of many shades that renders as one colour means the curve has
        # bunched every step below the terminal's resolution -- silently, since
        # the fade still "works". Only the degenerate case is refused; mild
        # collapse is a documented cost of a large k.
        if shades > 1 and len(set(ramp)) == 1:
            raise ConfigError(
                f"watch.fade_curve {curve!r} with fade_k {k:g} collapses the "
                f"{key} ramp to a single colour -- lower k, or raise watch.shades"
            )
    return WatchSettings(
        interval.value, settings["hold"].value, settings["replay_steps"].value,
        settings["full_repaint"].value, settings["show_timing"].value,
        settings["min_redraw"].value, shades,
        ramps, highlights,
        {"interval": interval.source, "hold": settings["hold"].source,
         "highlight": settings["highlight"].source},
    )


def resolve_tail(args, config, config_path, settings=None):
    """Tail settings, read out of the resolved table."""
    if settings is None:
        settings = resolve_settings(args, config, config_path, sections=("tail",))
    return TailSettings(settings["notify"].value, settings["max_events"].value,
                        settings["seed_lookback"].value)


def color_enabled(args):
    if args.color == "never":
        return False
    if args.color == "always":
        return True
    return sys.stdout.isatty() and not os.environ.get("NO_COLOR")


def fade_color(direction, age, hold, ramps):
    """The shade for a tint of a given age, or None once it has expired."""
    shades = ramps[direction]
    if hold <= 0:
        return shades[0]  # 0 means hold indefinitely, so never dim
    if age >= hold:
        return None
    return shades[min(int(age / (hold / len(shades))), len(shades) - 1)]


def palette_chooser(readers, highlights, at_wall, hold):
    """Return login -> ramp key, or None when no rule is in force.

    Precedence runs falling < rising < the rules in the order they are written,
    so the last rule to match beats every earlier one -- and either way a rule
    beats the plain rise and fall colours. Priority is the rule's position, not
    how recently it matched: an earlier message matching a later rule still wins.

    A rule stays in force while its match is within the hold, the same lifetime
    the tint has, so colour and fade expire together instead of one outliving
    the other.
    """
    if not highlights or readers is None:
        return lambda login: None
    cutoff = None if hold <= 0 else at_wall - timedelta(seconds=hold)

    def choose(login):
        best = None
        for reader in readers.files.values():
            day_start = datetime.combine(reader.file_date, time(0, 0, 0))
            for second, index in reader.matches.get(login, ()):
                when = day_start + timedelta(seconds=second)
                if when > at_wall or (cutoff is not None and when < cutoff):
                    continue
                if best is None or index > best:
                    best = index
        return None if best is None else highlight_key(best)

    return choose


def colorizer(frame, enabled):
    """Tint a row by how its count moved, then let that tint fade out over `hold`.

    Green is assigned on an increase and grey on a decrease, but green outranks
    grey: a row already holding a green is left alone when its count falls, so an
    active chatter never flips grey just because an old message aged out of a
    rolling window. A rise still overrides a grey immediately.

    A row whose count did not move keeps its tint, but the tint ages: each 1/N of
    the hold steps one shade dimmer, and past the hold the row goes plain. So
    colour says what a user last did *and* roughly how long ago, and a table
    nobody is typing in settles back to plain instead of staying lit forever.

    Returns (tint, tints) where tints carries {login: (direction, when)} into the
    next frame. Expiry is by wall clock, so rows scrolled off by --top age at the
    same rate as visible ones and never return wearing a stale highlight.
    """
    frame = frame.resolved()
    previous, carried = frame.previous, frame.carried
    hold, ramps, now = frame.hold, frame.ramps, frame.now
    tints = {
        login: entry for login, entry in carried.items()
        if hold <= 0 or now - entry[1] < hold
    }
    choose = frame.palette_of or (lambda login: None)
    if not enabled:
        return Tinting(lambda text, login, count: text, tints)

    def tint(text, login, count):
        before = None if previous is None else previous.get(login)
        if previous is None:
            pass  # first frame: nothing has moved yet
        elif before is None or count > before:
            tints[login] = ("up", now)
        elif (count < before and "down" in ramps
              and tints.get(login, ("down", 0))[0] == "down"):
            # Rises outrank falls: while a green is still holding, a fall is
            # dropped rather than repainting the row grey. In a rolling window a
            # fall is usually the window sliding rather than anything the user
            # did -- and it lands hardest on the busiest rows, whose older
            # messages age out fastest. The green keeps fading on its own clock,
            # so suppressing the fall never makes a row look fresher than it is.
            tints[login] = ("down", now)
        entry = tints.get(login)
        if entry is None:
            return text
        # The ladder, applied every frame rather than frozen at assignment: a
        # matching rule supersedes the rise or fall colour for as long as it
        # holds, so a falling row that said something notable wears the rule's
        # colour, not grey.
        palette = choose(login) or entry[0]
        color = fade_color(palette, now - entry[1], hold, ramps)
        if color is None:
            tints.pop(login, None)
            return text
        return f"{color}{text}{ANSI_RESET}"

    return Tinting(tint, tints)


def visible_width(text):
    return len(ANSI_RE.sub("", text))


def clip(text, width):
    """Cut a line to a visible width, keeping escape sequences intact.

    A wrapped line would make the frame taller than the redraw expects, which is
    what turns an in-place repaint into a scrolling mess.
    """
    if visible_width(text) <= width:
        return text
    kept = []
    shown = 0
    index = 0
    while index < len(text) and shown < width:
        match = ANSI_RE.match(text, index)
        if match:
            kept.append(match.group())
            index = match.end()
            continue
        kept.append(text[index])
        shown += 1
        index += 1
    return "".join(kept) + (ANSI_RESET if "\033" in text else "")


class Screen:
    """Keeps what is on the terminal so a redraw can send only what moved.

    Clearing the screen every tick is what makes watch(1) flash; homing the
    cursor and rewriting every line avoids that, but it still hands the terminal
    a whole frame to re-parse and re-lay-out several times a second. Our own cost
    for that is microseconds -- the terminal's is not. Measured on a live
    --watch 0.2 frame of 31 lines, 7 changed on a median tick, and emulator CPU
    was the thing that showed it.

        bytes/second        7,598  ->  2,462
        line rewrites/sec     205  ->     40

    Every frame still fully specifies the screen at intervals, because a painter
    that believes something wrong about the terminal stays wrong: a full repaint
    happens on the first frame, whenever the width changes, and every
    `full_every` frames as a backstop against anything that wrote over us.
    """

    def __init__(self, full_every=None):
        self.full_every = (setting_default("full_repaint") if full_every is None
                           else full_every)
        self.painted = None
        self.width = None
        self.since_full = 0

    def paint(self, lines):
        width = shutil.get_terminal_size(fallback=(80, 24)).columns
        frame = [clip(text, width) for text in lines]
        full = (self.painted is None or width != self.width
                or (self.full_every and self.since_full >= self.full_every))
        if full:
            parts = ["\033[2J\033[H"]
            for text in frame:
                parts.append(text + "\033[K\n")
            parts.append("\033[J")
            self.since_full = 0
        else:
            parts = []
            for row, text in enumerate(frame):
                if row < len(self.painted) and self.painted[row] == text:
                    continue
                # Absolute addressing: nothing here depends on where the cursor
                # was left, so a skipped line cannot shift the ones after it.
                parts.append(f"\033[{row + 1};1H{text}\033[K")
            if len(frame) < len(self.painted):
                parts.append(f"\033[{len(frame) + 1};1H\033[J")
            self.since_full += 1
        self.painted, self.width = frame, width
        if parts:                      # an unchanged frame writes nothing at all
            sys.stdout.write("".join(parts))
            sys.stdout.flush()
        return len(parts)


class PollingWatcher:
    """Wait on the clock alone. The behaviour every platform can manage.

    Also what a platform without change notification falls back to, and what
    [tail] notify = false selects deliberately.
    """

    enabled = False

    def __init__(self, max_events=None):
        self.max_events = max_events or setting_default("max_events")
        self.handles = {}
        self.woke_on_write = 0
        self.woke_on_timer = 0

    def arm(self, paths):
        """Nothing to arm: the timer is the only wake source."""

    def wait(self, timeout):
        if timeout <= 0:
            return False
        clock.sleep(timeout)
        self.woke_on_timer += 1
        return False

    def close(self):
        pass


class KqueueWatcher(PollingWatcher):
    """Wake when a log file is written, rather than only when the timer says so.

    Chatterino writes these files while we read them, so polling on a fixed
    interval trades latency against wasted wakeups: a quarter-second tick reacts
    quickly but re-derives everything four times a second, most of them after no
    write at all.

    The timer cannot go away, though, and that is worth being clear about: with a
    rolling --since window the counts change with the clock even when nothing is
    written, because messages age out of the trailing edge, and the tint fade is
    time-driven too. So this shortens the wait rather than replacing it -- wake on
    a write, or when the interval expires, whichever comes first.

    kqueue is macOS and the BSDs; other platforms answer with their own watcher,
    or with PollingWatcher until one exists.
    """

    enabled = True

    def __init__(self, max_events=None):
        super().__init__(max_events)
        self.queue = select.kqueue()

    def arm(self, paths):
        """Track exactly `paths`, opening and closing descriptors as it changes."""
        wanted = set(paths)
        for path in list(self.handles):
            if path not in wanted:
                self.handles.pop(path).close()
        for path in wanted - set(self.handles):
            try:
                handle = open(path, "rb")
            except OSError:
                continue
            self.handles[path] = handle
            self.queue.control([select.kevent(
                handle.fileno(),
                filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE | select.KQ_EV_CLEAR,
                fflags=(select.KQ_NOTE_WRITE | select.KQ_NOTE_EXTEND
                        | select.KQ_NOTE_DELETE | select.KQ_NOTE_RENAME),
            )], 0, 0)

    def wait(self, timeout):
        """Block until a watched file changes or `timeout` elapses."""
        if timeout <= 0:
            return False
        if not self.handles:
            return super().wait(timeout)
        events = self.queue.control(None, self.max_events, timeout)
        if events:
            self.woke_on_write += 1
            return True
        self.woke_on_timer += 1
        return False

    def close(self):
        for handle in self.handles.values():
            handle.close()
        self.handles.clear()
        self.queue.close()


def replay_horizon(hold, interval, max_steps):
    """How far back the launch replay reaches, in seconds.

    Also how far back a reader must keep its buckets, which is why it has a name
    of its own. `hold` used to serve as both, so setting it to 0 -- documented as
    "the tint never fades" -- silently turned off the cold-read seek and the
    pruning with it: 439ms and 49,565 buckets against 32ms and 484. Fade duration
    and data retention are different quantities that happened to coincide.
    """
    horizon = hold if hold > 0 else interval * max_steps
    return max(1, min(int(horizon / interval), max_steps)) * interval


def session_floors(watch):
    """(buckets, matches) retention for a watch session, in seconds.

    Two different questions that used to share one answer. Buckets are only ever
    read back as far as the launch replay reaches, so that is their floor. A
    match decides colour for as long as `hold`, which may be forever -- 0 here
    means never drop one. Deriving both from `hold` made hold=0 turn off the
    cold-read seek and the pruning as a side effect.
    """
    return (replay_horizon(watch.hold, watch.interval, watch.replay_steps),
            max(watch.hold, 0))


def replay_tints(readers, window, frame, interval, max_steps, highlights=()):
    """Reconstruct the tint state a session already running would be holding.

    Without this the first frame is entirely plain -- not because nothing has
    happened, but because there is no previous frame to compare against. Yet the
    answer is already in hand: the readers hold per-second buckets, so the window
    can be re-derived at any recent moment.

    So step a virtual clock from `hold` ago up to now and feed each step through
    the real colorizer. Whatever tint state falls out is by construction what a
    session running that whole time would hold -- the same rules about rises
    outranking falls, clocks resetting and shades ageing, because it is the same
    code rather than a second implementation of it.

    Only the buckets are summed. Days served from the cache contribute a constant
    across so short a horizon, and the colouring depends on differences, so a
    constant cancels out.
    """
    if not readers.files or not max_steps:
        return {}
    frame = frame.resolved()
    hold, now = frame.hold, frame.now
    steps = max(1, int(replay_horizon(hold, interval, max_steps) / interval))
    carried, previous = {}, None
    for step in range(steps, -1, -1):
        back = step * interval
        at_end = window.end - timedelta(seconds=back)
        at_begin = (window.begin - timedelta(seconds=back) if window.begin_rolls
                    else window.begin)
        counts = Counter()
        for reader in readers.files.values():
            for (login, state), n in reader.window(at_begin, at_end).items():
                if window.state_filter is None or state == window.state_filter:
                    counts[login] += n
        # Only the virtual clock and what it can see move between steps; the hold
        # and the palettes are the same ones the live loop will use.
        tinting = colorizer(frame._replace(
            previous=previous, carried=carried, now=now - back,
            palette_of=palette_chooser(readers, highlights, at_end, hold),
        ), True)
        for login, count in counts.items():
            tinting.tint("", login, count)   # called for its effect on the tints
        carried, previous = tinting.carried, counts
    return carried


def launch_tints(readers, context, watch, frame):
    """Tint state for the very first frame.

    Only a window whose end tracks the clock can have moved: a fixed --begin/--end
    range over append-only logs is the same range it was a minute ago, so every
    row in it is genuinely unchanged and plain is the truthful answer.
    """
    if context.settings["end"]:
        return {}
    return replay_tints(readers, context.window, frame._replace(hold=watch.hold),
                        watch.interval, watch.replay_steps, watch.highlights)


def watch_status(interval, hold, sources, elapsed, show_timing, woke=None):
    """The status line under a watch frame.

    Steady by default. It used to carry the tick time and the wake source, both
    of which change on essentially every frame, so this one line guaranteed a
    write per tick however still the report was -- 19% of every line write, and
    the only thing standing between an idle screen and sending the terminal
    nothing at all. The timings are still there behind [watch] show_timing, and
    a tick slower than the interval still says so, because that is rare and
    worth the repaint it costs.
    """
    held = "indefinite" if hold <= 0 else f"{hold:g}s"
    status = (f"every {interval:g}s ({sources['interval']}), "
              f"hold {held} ({sources['hold']})")
    if show_timing:
        status += f", tick {elapsed * 1000:.0f}ms"
        if woke is not None:
            status += f", woke on {woke}"
    if elapsed > interval:
        status += f" -- {elapsed * 1000:.0f}ms tick, slower than the interval"
    return status


def next_tint_change(carried, hold, shades, now):
    """When the soonest carried tint next changes appearance, or None.

    A tint only looks different when its age crosses a multiple of hold/shades,
    or when it expires at hold -- and both instants are known the moment it is
    assigned. So the loop can wait for the next one instead of polling past it.

    This decouples how smooth the fade is from how often the loop wakes. Before,
    `interval` had to be short enough for the finest shade step or the fade went
    choppy; now it only bounds how stale an *unannounced* change may be -- a
    message ageing out of a rolling window -- while arrivals come from the
    watcher and shade steps come from here.
    """
    if hold <= 0 or not carried:
        return None                    # nothing fading, or fading indefinitely
    step = hold / max(1, shades)
    soonest = None
    for _, when in carried.values():
        age = now - when
        if age >= hold:
            continue                   # already expired: the row is plain
        # min() only absorbs float error: with step = hold/shades, the last
        # boundary lands exactly on hold, never past it (measured worst
        # overshoot 1.2e-10s). It is a guard, not a rule.
        due = when + min((int(age / step) + 1) * step, hold)
        if soonest is None or due < soonest:
            soonest = due
    return soonest


def run_watch(args, platform=None):
    """Redraw the report until interrupted."""
    if not sys.stdout.isatty():
        raise ConfigError("--watch needs a terminal (it repaints in place)")
    platform = platform or PLATFORM
    config, config_path, _ = load_config_layer(args)
    watch = resolve_watch(args, config, config_path)
    interval, hold, ramps, sources = watch.interval, watch.hold, watch.ramps, watch.sources
    min_redraw = watch.min_redraw
    previous = None
    carried = {}
    first = True
    screen = Screen(watch.full_repaint)
    readers = LiveReaders(watch.highlights, platform)
    # Set before the first count, not after: it is also how far back a cold read
    # needs to seek, and the launch replay below is the furthest anything ever
    # looks behind the window.
    readers.retain_seconds, readers.match_seconds = session_floors(watch)

    # Prime the readers, then rebuild the tint state from what they hold, so the
    # first frame arrives already coloured instead of uniformly plain.
    priming = build_report_data(args, readers)
    carried = launch_tints(readers, priming.context, watch,
                           Frame(ramps=ramps, now=clock.monotonic()))
    tail = resolve_tail(args, config, config_path)
    changes = platform.watcher(tail.notify, tail.max_events)
    sys.stdout.write("\033[?25l")  # hide the cursor; it would blink mid-table
    painted_at = None
    try:
        while True:
            # A floor on how often a write can force a redraw. The watcher fires
            # on every append, and a busy channel appends several times a second
            # -- measured at 3.9 paints/s against a 5s interval, with gaps as
            # short as 1ms. Arrivals during the floor are not lost, only folded
            # into the next frame, so this caps the cost of a busy channel
            # instead of scaling with it.
            if painted_at is not None and min_redraw > 0:
                early = min_redraw - (clock.monotonic() - painted_at)
                if early > 0:
                    clock.sleep(early)
            started = clock.monotonic()
            lines, counts, carried = run_report(
                args, collect=True, readers=readers,
                frame=Frame(
                    previous=previous, carried=carried, hold=hold, ramps=ramps,
                    now=started,
                    palette_of=palette_chooser(readers, watch.highlights,
                                               datetime.now(), hold),
                ),
            )
            elapsed = clock.monotonic() - started
            woke = None
            if changes.enabled:
                woke = "write" if changes.woke_on_write and not first else "timer"
            status = watch_status(interval, hold, sources, elapsed,
                                  watch.show_timing, woke)
            frame = lines + ["", f"watching -- {status} -- Ctrl-C to stop"]
            assert len(frame) - len(lines) == WATCH_STATUS_LINES
            screen.paint(frame)
            painted_at = clock.monotonic()
            previous = counts
            first = False
            # Rebuilding the cache once is a request; doing it every second is not.
            args.rebuild_cache = False
            changes.arm(readers.paths())
            # Wake for whichever comes first: the next shade step, or the
            # interval. The watcher still cuts either short when a log is
            # written, so arrivals are unaffected by how long this is.
            wait = interval - elapsed
            due = next_tint_change(carried, hold, watch.shades, clock.monotonic())
            if due is not None:
                wait = min(wait, due - clock.monotonic())
            changes.wait(max(wait, 0.0))
    except KeyboardInterrupt:
        pass
    finally:
        changes.close()
        if readers.cache and readers.cache[0] is not None:
            readers.cache[0].close()
        sys.stdout.write("\033[?25h\n")
        sys.stdout.flush()
    return 0


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------

def build_parser():
    """Assemble the CLI.

    Settings that follow the plain shape are declared from SETTINGS; the ones
    that do not -- shared values, optional arguments, mutually exclusive groups --
    are written out here. Declaration order is the order --help lists them in.
    """
    parser = argparse.ArgumentParser(
        description="Count Chatterino chat messages per user for a channel and time range.",
        epilog=(
            "Datetimes accept 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM[:SS]', or an ISO week "
            "('2026-W31', or '2026-W31-3' for its Wednesday); a bare date or week means "
            "its start for --begin and its end for --end, so '-b 2026-W31 -e 2026-W31' is "
            "exactly that week. The range is inclusive on both ends. "
            "Durations for --since look like '30d', '12h', '1w3d' ('m' is "
            "minutes). --users N sizes the window instead, widening it until N users "
            "meet --min-count and then holding that width. Any setting may instead "
            "come from an environment variable -- TWITCH_ plus the flag name, or "
            "TWITCH_WATCH_/TWITCH_TAIL_ plus the config key for those tables -- or "
            "from the config file; --manual lists every one of them and the header "
            "reports which "
            "source was used. Exclusions are the exception to first-hit-wins: every layer "
            "adds to the set, so --exclude supplements the config rather than replacing it."
        ),
    )

    def declare(name):
        SETTINGS_BY_NAME[name].add_to(parser)
    declare("channel")

    window = parser.add_mutually_exclusive_group()
    window.add_argument(
        "-b", "--begin",
        help="start of the range, e.g. '2026-07-01' "
             "(alternative to --since and --users)",
    )
    window.add_argument(
        "-S", "--since",
        help="start the range this far before --end, e.g. '30d' "
             "(alternative to --begin and --users)",
    )
    window.add_argument(
        "--users", type=positive_int, metavar="N",
        help="size the window so N users meet --min-count, then hold that width",
    )
    declare("users_policy")
    declare("users_max")
    declare("end")
    declare("min_count")
    parser.add_argument(
        "-B", "--by-state", action="store_true",
        help="add live, offline and offline%% columns (shorthand for --show)",
    )
    declare("show")
    declare("sort")
    declare("share_floor")
    declare("top")
    declare("header")
    declare("logs_dir")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "-j", "--json", action="store_true",
        help="emit one JSON document with its own schema embedded",
    )
    mode.add_argument(
        "-w", "--watch", nargs="?", const=WATCH_FROM_CONFIG, type=watch_interval,
        metavar="SECONDS",
        help=f"redraw every SECONDS (default: watch.interval, "
             f"{setting_default('interval'):g}), tinting a row green when its count "
             "rises and grey when it falls; a green still holding outranks a fall",
    )
    parser.add_argument(
        "--watch-hold", type=nonnegative_float, metavar="SECONDS",
        help=f"how long a row stays tinted after it moves (default: watch.hold, "
             f"{setting_default('hold'):g}s, one shade per 1/N of it; 0 holds indefinitely)",
    )
    parser.add_argument(
        "--color", choices=("auto", "always", "never"), default="auto",
        help="colour output (default: auto, meaning a terminal without NO_COLOR)",
    )

    state = parser.add_mutually_exclusive_group()
    state.add_argument(
        "-L", "--live", action="store_true",
        help="only messages sent while the channel was live",
    )
    state.add_argument(
        "-O", "--offline", action="store_true",
        help="only messages sent while the channel was offline",
    )
    state.add_argument(
        "-U", "--unknown", action="store_true",
        help="only messages no live/offline marker can place",
    )

    parser.add_argument(
        "-x", "--exclude", action="append", metavar="LOGIN[,LOGIN...]",
        help="exclude these users; repeatable, comma-separated, ADDS to config exclusions",
    )
    parser.add_argument(
        "-g", "--exclude-group", action="append", metavar="GROUP",
        help="exclude a group from the config's [exclude] table; repeatable",
    )
    parser.add_argument(
        "--exclude-broadcaster", action="store_true", default=None,
        help="exclude the channel's own account",
    )
    parser.add_argument(
        "--include", action="append", metavar="LOGIN[,LOGIN...]",
        help="re-include users the merged exclusions would drop; repeatable",
    )
    parser.add_argument(
        "--no-exclude", action="store_true",
        help="ignore every exclusion for this run",
    )

    config = parser.add_mutually_exclusive_group()
    config.add_argument(
        "--config", help=f"TOML config file (default: {shorten_path(DEFAULT_CONFIG_PATH)})"
    )
    config.add_argument(
        "--no-config", action="store_true", help="ignore the config file entirely"
    )

    parser.add_argument(
        "--streamer", dest="streamer_mode", action="store_true", default=None,
        help="streamer mode: no content highlights while watching",
    )

    cache = parser.add_mutually_exclusive_group()
    cache.add_argument(
        "--no-cache", action="store_true", help="parse the logs instead of using the cache"
    )
    cache.add_argument(
        "--rebuild-cache", action="store_true", help="discard the cache and parse everything"
    )

    parser.add_argument(
        "--manual", action="store_true",
        help="print the full manual: config keys, layering, cache and watch behaviour",
    )
    parser.add_argument(
        "--emit-fish-completions", action="store_true",
        help="print fish completions; redirect into ~/.config/fish/completions/",
    )
    parser.add_argument("--complete", choices=COMPLETE_KINDS, help=argparse.SUPPRESS)
    return parser


def report_failure(args, message, code=1, announce=True):
    """Fail in the shape the caller was promised, and return the exit code."""
    # A pipeline deserves a parseable failure rather than a truncated stream.
    if args.json:
        json.dump({"error": message}, sys.stderr)
        sys.stderr.write("\n")
    elif announce:
        print(f"error: {message}", file=sys.stderr)
    return code


def main(argv=None):
    args = build_parser().parse_args(argv)

    if args.manual:
        # The module docstring is the manual; --help is the summary. Keeping both
        # in one file matters for a script that lives alone on PATH.
        print(__doc__.strip().replace(ENVIRONMENT_PLACEHOLDER,
                                      environment_manual()))
        return 0
    if args.emit_fish_completions:
        print(fish_completions())
        return 0
    if args.complete:
        return run_completion(args)
    try:
        if args.watch is not None:
            return run_watch(args)
        return run_report(args)
    except (ConfigError, Unsupported) as exc:
        return report_failure(args, str(exc))
    except KeyboardInterrupt:
        # Ctrl-C is a request, not a crash. Text mode says nothing -- the shell
        # has already echoed ^C -- while --json still gets the shape it was
        # promised instead of a thirty-line traceback on stderr. 130 is the
        # shell convention for a process ended by SIGINT.
        return report_failure(args, "interrupted", code=130, announce=False)
    except OSError as exc:
        # The backstop for I/O that could not simply be skipped -- the logs
        # directory itself, the config, the terminal. An individual log file no
        # longer reaches here; it is skipped and reported in the header. What is
        # left would otherwise escape as a traceback, and --json is documented to
        # fail as {"error": ...}, which a traceback plainly is not.
        return report_failure(args, f"{type(exc).__name__}: {exc}")


class Report(NamedTuple):
    """A finished report: what was asked, what was found, how to lay it out.

    Grouped by phase rather than flat -- it was 27 fields, and a renderer that
    takes the whole world documents none of its dependencies. Each renderer now
    reaches into the phase it actually needs.
    """
    args: object
    context: Context
    selection: Selection
    presentation: Presentation


def run_report(args, frame=None, collect=False, readers=None):
    """One-shot report, or a frame for the watch loop."""
    report = build_report_data(args, readers)
    if args.json:
        return emit_json(report)
    lines, tints = render_text(report, frame)
    if collect:
        return lines, dict(report.selection.counts), tints
    print("\n".join(lines))
    return 0


class Window(NamedTuple):
    """What range was asked for, and how it was arrived at."""
    begin: object
    end: object
    threshold: int
    state_filter: object
    start_source: str
    # True when begin was derived from --since, so it slides with end rather
    # than staying put. The replay needs to know which edges move.
    begin_rolls: bool = False
    start_kind: str = ""      # "begin", "since", "users", or "" for the default
    requested_users: object = None   # the N of --users, before it is sized
    # (width, requested, found) once --users has been resolved. The header needs
    # all three: the exact count is often unreachable, and saying so is the
    # point of the policy.
    sized: object = None


class Context(NamedTuple):
    """Resolved inputs: everything decided before a single log line is read."""
    config: dict
    config_path: str
    config_loaded: bool
    settings: object
    channel_dir: str
    channel_name: str
    window: Window
    tail: TailSettings
    exclusions: object = None


class Selection(NamedTuple):
    """What the counting pass found, after exclusions."""
    counts: Counter
    total_messages: int
    states: Counter
    states_by_login: dict
    files: int
    parsed: int
    excluded: dict
    excluded_counts: dict
    exclude_sources: list
    cache: object
    # Why the cache could not be opened, or None. Distinct from cache=None with
    # no problem, which is --no-cache: asked for, not broken.
    cache_problem: object = None
    unreadable: tuple = ()    # (filename, reason) for logs that were skipped
    reused: int = 0           # days this pass took from the rollup


class HeaderRow(NamedTuple):
    """One provenance fact, in both the shapes it is ever shown in.

    `compact` is the same fact abbreviated for the one-line header, or None for
    rows that only earn their space in the full block. Both headers read this one
    table, in this one order, so a fact cannot be disclosed in one mode and go
    missing from the other -- which is how the share floor, a filter that drops
    users who did meet min_count, came to be invisible in compact mode.
    """
    label: str
    value: str
    source: str
    compact: object = None


class Ranking(NamedTuple):
    """Which users survived the threshold and the floor, and in what order."""
    reported: list
    columns: list             # metric columns beyond "count"
    columns_source: object
    sort_name: str
    share_floor: object       # the floor that acted, or None if none did
    below_floor: int
    # Whether any share was shown or sorted by. Distinguishes "no floor was
    # needed" from "a floor was asked for and had nothing to act on".
    shares_shown: bool = False


class Presentation(NamedTuple):
    """How the selection is to be laid out."""
    rows: list                # the whole header, as HeaderRow records
    columns: list             # metric columns beyond "count"
    reported: list
    displayed: list
    hidden: list
    limit: object
    limit_source: str
    sort_name: str
    share_floor: object
    below_floor: int
    header_mode: str
    header_source: str


class Inputs(NamedTuple):
    """The half of a context a redraw cannot change.

    Only the window moves while watching -- its end is the clock. Everything
    here is decided by the config file and the command line, both fixed for the
    session, so a watch loop that re-derived it every tick was re-walking every
    Spec, recompiling the highlight patterns and listing the logs directory to
    find a channel folder that cannot move: 88us of a 251us tick on a 30-minute
    window, all of it reproducing the previous tick exactly.
    """
    config: dict
    config_path: str
    config_loaded: bool
    settings: object
    channel_dir: str
    channel_name: str
    tail: TailSettings
    kind: str            # how the window starts: "begin", "since" or neither
    start_setting: object
    exclusions: object   # who is excluded, and which layers said so


def resolve_inputs(args, readers=None):
    """Settings, channel and tail. Memoized per session.

    Two things can make it stale and both are in the key: the config file, by the
    (path, size, mtime_ns) identity the config-layer memo already computes, so an
    edit mid-session re-resolves everything here; and the arguments, because
    nothing stops a caller reusing a session with different ones -- which is
    exactly what happened when this was keyed on the config alone.
    """
    if readers is None:
        return build_inputs(args, readers)
    try:
        identity = config_identity(args)
    except OSError:
        return build_inputs(args, readers)   # cannot tell; resolve afresh
    return readers.inputs.get((identity, args), lambda: build_inputs(args, readers))


def build_inputs(args, readers=None):
    """Resolve everything a redraw cannot change. See resolve_inputs."""
    config, config_path, config_loaded = load_config_layer(args, readers)  # ConfigLayer

    aliases = config.get("aliases") or {}
    if not isinstance(aliases, dict):
        raise ConfigError(f"[aliases] in {config_path} must be a table of name = channel")

    # --- resolve settings -------------------------------------------------
    cli_state = next((name for name in STATES if getattr(args, name)), None)
    settings = resolve_settings(
        args, config, config_path, {"state": cli_state},
        sections=("watch", "tail") if args.watch is not None else ("tail",))
    if cli_state:  # name the flag the user actually typed
        settings.replace("state", Setting(settings["state"].value, f"--{cli_state}"))

    logs_dir = settings["logs_dir"]
    channel = settings["channel"]
    if not channel:
        raise ConfigError(
            "no channel given -- pass --channel, set TWITCH_CHANNEL, "
            f"or add channel = \"...\" to {shorten_path(config_path)}"
        )
    channel_key = str(channel.value)
    if channel_key in aliases:
        channel = settings.replace("channel", Setting(
            aliases[channel_key], f"{channel.source} -> alias {channel_key!r}"
        ))

    root = logs_dir.value or PLATFORM.require_logs_dir()
    channel_dir, channel_name = resolve_channel_dir(
        os.path.expanduser(str(root)), str(channel.value)
    )
    kind, start_setting = resolve_window_start(args, config, config_path)

    built = Inputs(config, config_path, config_loaded, settings, channel_dir,
                   channel_name, resolve_tail(args, config, config_path, settings),
                   kind, start_setting,
                   # Derived from the config and the resolved channel, both fixed
                   # for the session -- rebuilding it per redraw walked the
                   # exclude table and re-split every name, 6.3us a tick.
                   build_exclusions(args, config, config_path, channel_name))
    return built


def size_window(args, context, readers=None):
    """Widen a --users window until the reported population matches, then fix it.

    Only the *reported* population counts -- users meeting --min-count after
    exclusions and the share floor -- never the displayed one, because --top and
    the terminal height cap the display and would make the function stop being
    invertible above the cap. Those still apply, afterwards, to whatever this
    window turns out to hold.

    The count only rises as the window widens, so this is a bisection. What it
    cannot promise is an exact hit: two users crossing --min-count in the same
    instant step the count from 8 to 10, and 9 then exists at no width at all --
    measured on a live channel, 4 of 15 counts were unreachable at minute
    resolution. --users-policy says what to do about that, and the header says
    what actually happened.

    Resolved once. Its result is a width, and a --since window of fixed width is
    what the session keeps for the rest of its life.
    """
    if context.window.start_kind != "users":
        return context     # every other window kind is already exactly sized
    if readers is None:
        return context._replace(window=_sized_window(args, context, None))
    try:
        key = (config_identity(args), args)
    except OSError:
        return context._replace(window=_sized_window(args, context, readers))
    width = readers.width.get(key, lambda: _search_width(args, context, readers))
    return context._replace(window=_apply_width(context.window, width))


def _apply_width(window, sized):
    """Put a resolved (width, requested, found) onto a window."""
    width, requested, found = sized
    return window._replace(begin=window.end - width, begin_rolls=True,
                           start_source=f"--users {requested}",
                           sized=(width, requested, found))


def _sized_window(args, context, readers):
    return _apply_width(context.window, _search_width(args, context, readers))


def _search_width(args, context, readers):
    """Bisect for the window width. Returns (width, requested, users found).

    In whole seconds throughout: a bisection on timedeltas invites the classic
    off-by-one, and this one found it -- guarding `mid <= lo` by bumping mid to
    lo + 1s makes the last step unable to move `hi`, and the loop never ends.
    """
    settings = context.settings
    requested = context.window.requested_users
    policy = settings["users_policy"].value
    ceiling = max(1, int(settings["users_max"].value.total_seconds()))

    # A one-shot run has no session, but the search is inherently many passes
    # over the same files -- so it gets readers regardless, or every probe would
    # re-parse the day from scratch.
    session = readers if readers is not None else LiveReaders()
    keep = session.retain_seconds
    # No pruning or seeking while searching: a narrow probe would otherwise
    # discard buckets a wider one still needs, with no way to get them back.
    session.retain_seconds = 0

    seen = {}

    def reported(seconds):
        if seconds not in seen:
            probe = context._replace(window=context.window._replace(
                begin=context.window.end - timedelta(seconds=seconds),
                begin_rolls=True))
            selection = select_rows(args, probe, session)
            seen[seconds] = len(plan_presentation(args, probe, selection).reported)
        return seen[seconds]

    try:
        # Widest first: every narrower probe is then a subset already in memory.
        widest = reported(ceiling)
        lo, hi = 1, ceiling
        while lo < hi:                       # smallest width with count >= N
            mid = lo + (hi - lo) // 2        # floors, so mid < hi and this ends
            if reported(mid) >= requested:
                hi = mid
            else:
                lo = mid + 1
        over_width, over = lo, reported(lo)

        # The other side needs its own bisection, not over_width - 1: when the
        # count sits on a plateau at exactly N, the widest window still holding
        # N is what "at most N" means, and that can be minutes wider. Measured
        # on a live channel, the plateau at 8 users was 700s across.
        lo, hi = 1, ceiling
        while lo < hi:                       # widest width with count <= N
            mid = lo + (hi - lo + 1) // 2    # ceils, so mid > lo and this ends
            if reported(mid) <= requested:
                lo = mid
            else:
                hi = mid - 1
        under_width, under = lo, reported(lo)

        if widest < requested:      # unreachable at any width the ceiling allows
            return timedelta(seconds=ceiling), requested, widest
        if policy == "at-least":
            chosen, found = over_width, over
        elif policy == "at-most":
            chosen, found = under_width, under
        elif abs(under - requested) <= abs(over - requested):
            # nearest, ties to the narrower window: it is the fresher data, and
            # <= rather than < is what actually implements that -- with < the
            # tie fell to the wider one, against the stated rule.
            chosen, found = under_width, under
        else:
            chosen, found = over_width, over
        return timedelta(seconds=chosen), requested, found
    finally:
        session.retain_seconds = keep


def resolve_context(args, readers=None):
    """Settings, channel and time range -- everything decided before reading logs."""
    inputs = resolve_inputs(args, readers)
    settings, config, config_path = inputs.settings, inputs.config, inputs.config_path

    end_setting = settings["end"]
    if end_setting:
        end = convert(
            end_setting, lambda v: parse_datetime(v, end_of_day_if_dateless=True), "--end"
        )  # parsed here: --end needs the end-of-period rule --begin does not
    else:
        end = datetime.now().replace(microsecond=0)
        end_setting = Setting(end, "default: now")

    kind, start_setting = inputs.kind, inputs.start_setting
    if kind == "users":
        # A placeholder until size_window bisects for the real width; nothing
        # reads `begin` between here and there.
        begin = end
    elif kind == "begin":
        begin = convert(
            start_setting, lambda v: parse_datetime(v, end_of_day_if_dateless=False), "--begin"
        )
    elif kind == "since":
        delta = convert(start_setting, parse_duration, "--since")
        begin = end - delta
        start_setting = Setting(
            begin, f"{start_setting.source} {start_setting.value} before end"
        )
    else:
        dates = log_dates(inputs.channel_dir)
        if not dates:
            raise ConfigError(f"no log files found in {inputs.channel_dir}")
        begin = datetime.combine(dates[0], time(0, 0, 0))
        start_setting = Setting(begin, "default: earliest log file")

    if begin > end:
        raise ConfigError(f"begin ({begin}) is after end ({end})")

    return Context(config, config_path, inputs.config_loaded, settings,
                   inputs.channel_dir, inputs.channel_name,
                   Window(begin, end, settings["min_count"].value,
                          settings["state"].value, start_setting.source,
                          kind in ("since", "users"), kind,
                          start_setting.value if kind == "users" else None),
                   inputs.tail, inputs.exclusions)


class CacheLease:
    """A cache for one counting pass, and whoever is responsible for closing it.

    A one-shot run opens and closes its own; a watch session opens one and keeps
    it for the life of the loop, so a tick must not close what it borrowed. That
    distinction used to travel as a `cache_owned` flag on Selection, with three
    call sites remembering to honour it -- and none of them ran when the pass
    raised, which is why an interrupted run left rollup.db-wal behind.

    As a context manager the rule is where the resource is, and the counting pass
    cannot leave without settling it.
    """

    __slots__ = ("cache", "problem", "owned")

    def __init__(self, cache, problem, owned):
        self.cache, self.problem, self.owned = cache, problem, owned

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        if self.owned and self.cache is not None:
            self.cache.close()
        return False


def open_cache(args, channel_name, readers):
    """The rollup cache for this pass, as a lease that knows who closes it."""
    if args.no_cache:
        return CacheLease(None, None, True)
    if readers is None or args.rebuild_cache:
        return CacheLease(*Cache.open(DEFAULT_CACHE_PATH, args.rebuild_cache,
                                      channel_name), owned=True)
    if readers.cache is None:
        readers.cache = Cache.open(DEFAULT_CACHE_PATH, False, channel_name)
    return CacheLease(*readers.cache, owned=False)

def select_rows(args, context, readers=None):
    """Count the range and drop the excluded, leaving the population to report on."""
    config, config_path = context.config, context.config_path
    channel_dir, channel_name = context.channel_dir, context.channel_name
    begin, end = context.window.begin, context.window.end
    state_filter = context.window.state_filter
    exclusions = context.exclusions or build_exclusions(
        args, config, config_path, channel_name)
    excluded, exclude_sources = exclusions.logins, exclusions.sources

    # Everything that touches the connection happens inside this block; the
    # header afterwards reads only plain attributes of the Cache object, which
    # outlive it. Leaving the block closes a borrowed-from-nobody connection
    # however the pass ends -- return, raise, or Ctrl-C.
    with open_cache(args, channel_name, readers) as lease:
        cache, cache_problem = lease.cache, lease.problem
        initial_state = seed_stream_state(channel_dir, begin, cache, channel_name,
                                          readers, context.tail.seed_lookback)
        tally = count_messages(
            channel_dir, begin, end, state_filter, initial_state, cache,
            channel_name, readers, excluded,
        )
    counts, files_read = tally.counts, tally.files
    total_messages, states, parsed, breakdown = (
        tally.messages, tally.states, tally.parsed, tally.breakdown
    )

    # Excluded users leave the report and the denominators alike, so the totals
    # describe the population actually shown.
    excluded_counts = {login: n for login, n in counts.items() if login in excluded}
    if excluded_counts:
        counts = Counter(
            {login: n for login, n in counts.items() if login not in excluded}
        )
        total_messages -= sum(excluded_counts.values())
        # The split describes the population the report is about, so it loses
        # the same messages the total does.
        states = +(states - (tally.excluded_states or Counter()))

    states_by_login = {}
    for (login, state), n in breakdown.items():
        if login in counts:
            states_by_login.setdefault(login, {})[state] = n

    # The defaulted tail is named: these have grown one at a time, and a
    # positional list that long swaps two of them without a word -- which is
    # exactly what happened when `reused` was added ahead of another field.
    return Selection(counts, total_messages, states, states_by_login, files_read,
                     parsed, excluded, excluded_counts, exclude_sources, cache,
                     cache_problem=cache_problem, unreadable=tally.unreadable,
                     reused=tally.reused)


def add_column(columns, name, before=None):
    """Add a metric column once, optionally ahead of another. Returns `columns`.

    The single place a column joins the list, so "each column at most once" is a
    property of the operation rather than a check every caller has to remember.
    It was remembered when appending and forgotten when inserting, which is how
    --by-state with --show unknown came to render the column twice.
    """
    if name == "count" or name in columns:
        return columns          # count is implicit, and repeats say nothing new
    at = columns.index(before) if before in columns else len(columns)
    columns.insert(at, name)
    return columns


def choose_columns(args, settings):
    """The metric columns beyond 'count', and what asked for them."""
    columns = list(BY_STATE_COLUMNS) if args.by_state else []
    source = "--by-state" if args.by_state else None
    show = settings["show"]
    if show:
        for name in show.value:
            add_column(columns, name)
        source = f"{source}, {show.source}" if source else show.source
    return columns, source


def rank_users(settings, counts, threshold, sort_name, columns, states_by_login):
    """Users meeting the threshold, ordered, with the share floor applied.

    The floor exists because a share means little on a handful of messages: one
    offline message out of one is 100% offline. That is a statement about the
    number on screen, so the floor follows the number -- it applies whenever a
    share is *shown* as a column or ranked by, not only when one drives the sort.

    Gating on the sort alone was the older scope, and it let a single offline%
    column mean two different things: sorted by that share a 2-message user was
    dropped, sorted by login the same user sat there reading 100.0%.

    Returns the ordered rows plus (floor, dropped, shares_shown), the last so the
    header can report a floor that was asked for and had nothing to act on. A
    flag that silently does nothing is what the provenance block exists to catch.
    """
    reported = [(login, count) for login, count in counts.items() if count >= threshold]
    shares_shown = any(
        name in METRICS and METRICS[name].kind == "share"
        for name in (sort_name, *columns)
    )
    floor = settings["share_floor"].value
    share_floor, below_floor = None, 0
    if shares_shown and floor:
        kept = [row for row in reported if row[1] >= floor]
        share_floor, below_floor = floor, len(reported) - len(kept)
        reported = kept
    return (sort_rows(reported, sort_name, states_by_login),
            share_floor, below_floor, shares_shown)


def window_span(context):
    """The counted range as one short phrase, for the compact header."""
    begin, end = context.window.begin, context.window.end
    if not context.settings["end"]:
        return f"{begin:%m-%d %H:%M}..now"      # --end defaulted, and keeps moving
    if begin.date() == end.date():
        return f"{begin:%m-%d %H:%M}..{end:%H:%M}"
    return f"{begin:%Y-%m-%d}..{end:%Y-%m-%d}"


def state_row(context, selection):
    """How the range splits live/offline/unknown, and what filtered it."""
    states, state_filter = selection.states, context.window.state_filter
    if not states:
        return None

    def split(separator):
        return separator.join(f"{name} {states[name]:,}"
                              for name in STATES if states[name])

    return HeaderRow(
        "state", split(" / "),
        f"{context.settings['state'].source} keeps {state_filter}" if state_filter
        else "not filtered",
        f"{state_filter} only" if state_filter else split(" "),
    )


def exclude_row(context, selection):
    """Who was excluded, and how many of them actually spoke in range.

    Two numbers hide here, and the compact form reports the second -- so the full
    row names both rather than letting the header modes disagree with nothing to
    say which is which.
    """
    names = sorted(selection.excluded)
    if not names:
        return None
    preview = ", ".join(names[:3])
    if len(names) > 3:
        preview += f", +{len(names) - 3} more"
    appeared = len(selection.excluded_counts)
    return HeaderRow(
        "exclude", f"{len(names)} login(s), {appeared} in range: {preview}",
        ", ".join(selection.exclude_sources),
        f"-{appeared} excl" if appeared else None,
    )


def share_floor_row(settings, ranking):
    """The share floor: what it did, or why it did nothing.

    A floor that acted explains a short table. A floor that was asked for and
    could not act explains nothing -- which is exactly why it has to be said,
    rather than letting an ignored flag pass in silence.
    """
    asked = not holds_default(settings, "share_floor")
    if not ranking.share_floor and not asked:
        return None
    if ranking.share_floor:
        value = (f">= {ranking.share_floor:,} message(s), "
                 f"{ranking.below_floor:,} user(s) dropped")
        compact = f"floor >={ranking.share_floor:,}, -{ranking.below_floor:,}"
    elif not ranking.shares_shown:
        value, compact = "not applied -- no share is shown or sorted by", "floor unused"
    else:
        value, compact = "disabled -- every share shown, on however few messages", "floor off"
    return HeaderRow("share floor", value, settings["share_floor"].source, compact)


def human_duration(delta):
    """A timedelta as the shortest thing --since would accept back."""
    seconds = int(delta.total_seconds())
    parts = []
    for unit, size in (("d", 86400), ("h", 3600), ("m", 60), ("s", 1)):
        if seconds >= size:
            parts.append(f"{seconds // size}{unit}")
            seconds %= size
    return "".join(parts) or "0s"


def users_row(context):
    """What --users asked for, what it found, and over how long.

    The exact count is often unreachable -- a user count only rises as the
    window widens, and two users crossing --min-count together step it past the
    value asked for -- so the row reports both numbers rather than implying the
    request was met. It reaches the compact header only when they differ.
    """
    if not context.window.sized:
        return None
    width, requested, found = context.window.sized
    policy = context.settings["users_policy"]
    return HeaderRow(
        "users",
        f"{requested:,} asked for, {found:,} found over {human_duration(width)}",
        f"{policy.source} {policy.value}",
        None if found == requested else f"{found:,}/{requested:,} users")


def cache_row(selection):
    """Whether the rollup cache served this run, or why it could not."""
    cache = selection.cache
    if cache is not None:
        return HeaderRow(
            # Counted for this pass. cache.hits now spans the whole session --
            # the connection outlives the tick -- and the day memo bypasses it
            # entirely, so neither describes what this redraw actually did.
            "cache",
            f"{selection.reused:,} day(s) reused, {selection.parsed:,} parsed",
            f"rebuilt: {cache.rebuilt_reason}" if cache.rebuilt_reason
            else shorten_path(cache.path))
    if not selection.cache_problem:
        return None                     # --no-cache: asked for, not broken
    # A dead cache is a 17x slowdown that otherwise looks exactly like a healthy
    # run, so unlike the healthy row this one carries a compact form: the mode
    # most likely to be watching is the one that must not hide it.
    return HeaderRow("cache", f"unavailable -- {selection.cache_problem}",
                     "every file parsed", "no cache")


def unreadable_row(selection):
    """Log files skipped because they could not be read.

    Compact too: a count silently missing a day is the one omission a reader has
    no way to notice from the numbers themselves.
    """
    skipped = selection.unreadable
    if not skipped:
        return None
    names = ", ".join(name for name, _ in skipped[:2])
    if len(skipped) > 2:
        names += f", +{len(skipped) - 2} more"
    return HeaderRow("unreadable",
                     f"{len(skipped)} file(s) skipped: {names} ({skipped[0][1]})",
                     "not counted", f"{len(skipped)} unread")


def provenance_rows(context, selection, ranking):
    """The header table: every fact that explains the numbers under it, in order.

    One entry per fact, in the order both header modes read them. A row that has
    nothing to say returns None and drops out, so each row's condition lives with
    its value instead of in a parallel list of guards -- and the table stays a
    table you can read top to bottom.
    """
    settings, window = context.settings, context.window
    begin, end = window.begin, window.end
    logs_dir = settings["logs_dir"]
    end_setting = settings["end"] if settings["end"] else Setting(end, "default: now")
    rows = (
        HeaderRow("channel", context.channel_name, settings["channel"].source,
                  context.channel_name),
        HeaderRow("logs dir", shorten_path(str(logs_dir.value)), logs_dir.source),
        # The window is two rows here, each with its own provenance, but one span
        # in compact -- so the span rides on 'begin' and 'end' stays full-only.
        HeaderRow("begin", str(begin), window.start_source, window_span(context)),
        HeaderRow("end", str(end), end_setting.source),
        HeaderRow("threshold", f">= {window.threshold} message(s)",
                  settings["min_count"].source, f">={window.threshold}"),
        users_row(context),
        state_row(context, selection),
        exclude_row(context, selection),
        HeaderRow("columns", ", ".join(["count"] + ranking.columns),
                  ranking.columns_source) if ranking.columns else None,
        HeaderRow("sort", ranking.sort_name,
                  settings["sort"].source if settings["sort"] else "default",
                  f"by {ranking.sort_name}") if ranking.sort_name != "count" else None,
        share_floor_row(settings, ranking),
        HeaderRow("config", shorten_path(context.config_path), "loaded")
        if context.config_loaded else None,
        cache_row(selection),
        unreadable_row(selection),
    )
    return [row for row in rows if row is not None]


def choose_limit(args, settings, header_mode, header_rows):
    """The row cap, and what set it."""
    top = settings["top"]
    if top:
        # 0 is the documented way to switch a configured limit back off.
        return top.value or None, top.source
    if args.json:
        # Machine output must never be trimmed by the size of a window.
        return None, "unlimited for --json"
    # Reserve exactly what the chosen header will occupy: the full block plus its
    # files: line and top: row, one line for compact, nothing for none.
    reserved = {"full": len(header_rows) + 2, "compact": 2, "none": 0}[header_mode]
    limit = adaptive_row_limit(
        reserved + (WATCH_STATUS_LINES if args.watch is not None else 0)
    )
    return limit, "terminal height"


def plan_presentation(args, context, selection):
    """Choose columns and ordering, then lay the result out under its header."""
    settings, window = context.settings, context.window
    states_by_login = selection.states_by_login

    columns, columns_source = choose_columns(args, settings)
    sort_name = settings["sort"].value or "count"
    if window.state_filter and (set(columns) & STATE_METRICS
                                or sort_name in STATE_METRICS):
        raise ConfigError(
            f"--{window.state_filter} counts one state only, so per-state columns "
            "and sorts would be degenerate -- drop the state filter to compare states"
        )

    reported, share_floor, below_floor, shares_shown = rank_users(
        settings, selection.counts, window.threshold, sort_name, columns,
        states_by_login
    )

    # 'unknown' earns a column only when the range actually contains some.
    if args.by_state and any(
        states_by_login.get(login, {}).get("unknown") for login, _ in reported
    ):
        add_column(columns, "unknown", before="offline-share")

    ranking = Ranking(reported, columns, columns_source, sort_name,
                      share_floor, below_floor, shares_shown)
    rows = provenance_rows(context, selection, ranking)

    header = settings["header"]
    limit, limit_source = choose_limit(args, settings, header.value, rows)
    displayed = reported[:limit] if limit else reported
    hidden = reported[len(displayed):]
    if limit and reported:
        # Appended here, not at render time, so Presentation.rows is the whole
        # header and both modes see the cap. It has to come after the limit,
        # which in turn sized itself against the rows above it.
        rows.append(HeaderRow(
            "top",
            f"{limit:,} row(s)" + (f", {len(hidden):,} hidden" if hidden else ""),
            limit_source,
            f"{len(displayed):,}/{len(reported):,} rows" if hidden else None,
        ))

    return Presentation(rows, columns, reported, displayed, hidden, limit,
                        limit_source, sort_name, share_floor, below_floor,
                        header.value, header.source)


def build_report_data(args, readers=None):
    """Resolve, count, and lay out -- the three phases of a report."""
    context = size_window(args, resolve_context(args, readers), readers)
    selection = select_rows(args, context, readers)
    presentation = plan_presentation(args, context, selection)
    return Report(args, context, selection, presentation)




def emit_json(report):
    """Write the self-describing JSON document for a report."""
    json.dump(build_report(report), sys.stdout, indent=2, ensure_ascii=False)
    sys.stdout.write("\n")
    return 0


def compact_header(report):
    """The provenance block boiled down to one line.

    A projection of the same table the full block renders: every row carrying a
    compact form, in table order, without the [source] tags -- which is what
    costs eleven lines. Nothing is re-derived here, so the two headers cannot
    disagree about what is worth saying.
    """
    return " \u00b7 ".join(
        row.compact for row in report.presentation.rows if row.compact
    )


def column_widths(rows, caps=()):
    """Width of each column: its widest cell, bounded by caps[i] where given.

    A cap does not truncate; it stops a column being *padded* to its widest, so
    one long value -- a logs dir, a config path -- cannot push every column after
    it off to the right. Beyond the cap a cell simply overruns its neighbour.
    """
    widths = []
    for index in range(max((len(row) for row in rows), default=0)):
        widest = max((len(row[index]) for row in rows if index < len(row)), default=0)
        cap = caps[index] if index < len(caps) else None
        widths.append(widest if cap is None else min(widest, cap))
    return widths


def align_row(cells, widths, align="l", gap="  "):
    """Pad cells to `widths`. `align` is 'l'/'r' per column, the last repeating.

    With column_widths above, the one place this script turns a row of strings
    into a line. The provenance block and the results table each had their own
    copy -- same job, different conventions, and no way for a change to one to
    reach the other.
    """
    out = []
    for index, cell in enumerate(cells):
        width = widths[index] if index < len(widths) else 0
        side = align[index] if index < len(align) else align[-1]
        out.append(cell.rjust(width) if side == "r" else cell.ljust(width))
    return gap.join(out).rstrip()


def header_lines(report, files_read):
    """The provenance block, in whichever of its three sizes was asked for."""
    layout = report.presentation
    if layout.header_mode == "none":
        return []
    if layout.header_mode == "compact":
        return [compact_header(report), ""]
    cells = [[f"{row.label}:", row.value, f"[{row.source}]"] for row in layout.rows]
    # The source tag is last and never padded; the value is capped so a long path
    # does not push every tag rightwards.
    widths = column_widths(cells, caps=(None, 48, 0))
    lines = [align_row(row, widths) for row in cells]
    lines.append(align_row(["files:", f"{files_read} log file(s) in range"], widths))
    lines.append("")
    return lines


def results_table(report):
    """Header row, rule, and one row of cells per displayed user.

    Returns (headers, rows) as raw cells; alignment and tinting happen together
    in render_text, which is the only place that knows how wide the frame is.
    """
    selection, layout = report.selection, report.presentation
    states_by_login = selection.states_by_login
    shown_columns = ["count"] + layout.columns
    headers = ["user"] + [METRICS[name].header for name in shown_columns]
    rows = [
        [login] + [METRICS[name].render(states_by_login.get(login, {}), count)
                   for name in shown_columns]
        for login, count in layout.displayed
    ]
    if layout.hidden:
        # Never let a cap hide messages silently -- the same rule the exclusion
        # and provenance reporting follow. The remainder aggregates the states of
        # everyone it stands for, so its shares mean the same thing as a row's.
        pooled = Counter()
        for login, _ in layout.hidden:
            for state, n in states_by_login.get(login, {}).items():
                pooled[state] += n
        hidden_messages = sum(count for _, count in layout.hidden)
        rows.append(
            [f"+ {len(layout.hidden):,} others"]
            + [METRICS[name].render(pooled, hidden_messages) for name in shown_columns]
        )
    return headers, rows


def pin_user_column(report, headers, rows):
    """Pin the login column to a fixed width, clipping what will not fit.

    Sized from the visible rows, this column moves whenever the widest login on
    screen changes. Replaying a day of the busiest channel here through a rolling
    30-minute window, that was 118 shifts across 4,260 frames -- about twice a
    minute at peak -- and each one slides every column to its right by up to 14
    places, because the counts are what the eye is trying to hold still.

    Only under --watch. A one-shot report has no next frame to stay still for, so
    there the column sizes itself and nothing is wasted.

    Returns the width to pin, or 0 to size from the rows as before. Twitch logins
    stop at 25 characters, so 25 is the width at which clipping becomes
    impossible rather than merely unobserved; the default 20 clipped nothing at
    all across either channel's history while costing five columns less.
    """
    if report.args.watch is None:
        return 0
    width = report.context.settings["user_width"].value
    if not width:
        return 0          # 0 asks for the self-sizing behaviour back
    for cells in [headers, *rows]:
        if len(cells[0]) > width:
            cells[0] = cells[0][:width - 1] + "\u2026"
    return width


def footer_lines(report):
    """The counts that must reconcile with the table above them."""
    selection, layout = report.selection, report.presentation
    displayed, reported = layout.displayed, layout.reported
    shown = sum(count for _, count in displayed)
    if layout.hidden:
        users = (f"{len(displayed):,} of {len(reported):,} user(s) above threshold "
                 f"({len(selection.counts):,} in range)")
    else:
        users = f"{len(reported):,} of {len(selection.counts):,} user(s)"
    lines = [f"{users}; {shown:,} of {selection.total_messages:,} message(s) in range"]
    if selection.excluded_counts:
        lines.append(
            f"excluded {len(selection.excluded_counts):,} user(s), "
            f"{sum(selection.excluded_counts.values()):,} message(s) not counted"
        )
    return lines


def render_text(report, frame=None):
    """Render a report as terminal lines, plus the tint state for the next frame.

    A Frame carries what the colouring needs; omitting it renders the one-shot
    case, where nothing has moved and nothing is tinted.
    """
    frame = frame or Frame()
    selection, layout = report.selection, report.presentation
    displayed = layout.displayed
    tint, tints = colorizer(frame, color_enabled(report.args))

    out = header_lines(report, selection.files)
    if not layout.reported:
        out.append("No users met the threshold "
                   f"({selection.total_messages} message(s) in range).")
        if selection.excluded_counts:
            out.extend(footer_lines(report)[1:])
        return out, tints

    headers, rows = results_table(report)
    pinned = pin_user_column(report, headers, rows)
    widths = column_widths([headers] + rows)
    if pinned:
        widths[0] = pinned      # pinned, not merely capped: it must not shrink
    rule = align_row(["-" * width for width in widths], widths)

    out.append(align_row(headers, widths, align="lr"))
    out.append(rule)
    for index, row in enumerate(rows):
        text = align_row(row, widths, align="lr")
        if index < len(displayed):  # the trailing "+ N others" row is left plain
            text = tint(text, *displayed[index])
        out.append(text)
    out.append(rule)
    out.extend(footer_lines(report))
    return out, tints


if __name__ == "__main__":
    sys.exit(main())
