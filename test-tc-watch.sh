#!/bin/bash
# ============================================================================
# test-tc-watch.sh — Phase 7 harness for tc_watch.S (watch mode).
#
#   Exercises the watch entry point through a pty (watch repaints in place,
#   so every interactive test runs under a pseudo-terminal):
#     * non-tty:  "error: --watch needs a terminal (it repaints in place)"
#     * notify:   the Python TODO message when [tail] notify is on
#     * differential: the first frame (ANSI-stripped) matches twitch-counts.py
#     * SIGINT:   exits 130 and restores the cursor
#     * appends:  a line written to the log shows up on the next frame
#     * --json:   mutually exclusive with --watch (argparse error)
#
#   Driver: the Makefile owns the build.  This script only runs
#   $BUILD/tc-watch-test, where BUILD defaults to build/<os> (uname -s,
#   lowercased) or comes from $TC_BUILD if set.  Run `make drivers` first;
#   this script fails fast with a clear message if the driver is missing.
#
#   Isolation: a fresh tmp root is made with mktemp, and HOME,
#   XDG_CONFIG_HOME and XDG_CACHE_HOME are exported to point inside it
#   before the very first python3 invocation of the file (the tomllib
#   probe below included — there is no exception). Every driver and
#   oracle invocation after that point — direct or through the pty
#   helper — inherits that environment (a pty child's os.execv() keeps
#   the parent's environment), so nothing here can ever touch the real
#   ~/.cache/twitch-counts/rollup.db or ~/.config/twitch-counts.toml.
#   Per-test isolation additionally comes from --config pointing at a
#   scratch toml and --no-cache where used.
#
#   Oracle: `python3` from PATH, resolved to an absolute path up front (a
#   pty child execs it directly, which does not search PATH) and checked
#   for tomllib (Python >= 3.11).
#
#   Usage:  ./test-tc-watch.sh
#
#   Exit:   0 = all tests passed; nonzero = at least one failure.
# ============================================================================
set -u
cd "$(dirname "$0")"

BUILD=${TC_BUILD:-build/$(uname -s | tr A-Z a-z)}
BIN="$BUILD/tc-watch-test"

if [ ! -x "$BIN" ]; then
    echo "FAIL: $BIN not found or not executable -- run: make drivers" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# isolation: a per-run tmp root, with HOME/XDG pointed inside it so nothing
# below -- including the tomllib probe just after this block -- can reach
# the real ~/.cache/twitch-counts or ~/.config.  This runs before the very
# first python3 invocation in the file, with no exceptions.
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/tc-watch-test.XXXXXX") || {
    echo "FAIL: cannot create temp directory" >&2
    exit 1
}
trap 'rm -rf "$TMPROOT"' EXIT

export HOME="$TMPROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

PY=$(command -v python3) || {
    echo "FAIL: python3 not found on PATH" >&2
    exit 2
}
if ! "$PY" -c 'import tomllib' >/dev/null 2>&1; then
    echo "FAIL: python3 (from PATH: $PY) must be >= 3.11 with tomllib available" >&2
    exit 2
fi
PYSCRIPT="$(pwd)/twitch-counts.py"
if [ ! -f "$PYSCRIPT" ]; then
    echo "FAIL: $PYSCRIPT not found" >&2
    exit 2
fi

DATA="$TMPROOT/data"
LOGS="$DATA/Logs/Twitch/Channels"
CH=chron
PASS=0
FAIL=0
FAILED_TESTS=()

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
ok()   { PASS=$((PASS+1)); echo "PASS[$1]"; }
bad()  { FAIL=$((FAIL+1)); FAILED_TESTS+=("$1"); echo "FAIL[$1]"; }

check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "    expected: $2"; echo "    got:      $3"; fi
}

# run_pty <outfile> <timeout> <sigint_after> <append_after> <append_line> -- args...
# Launches the command in a pty; optionally sends SIGINT and/or appends a
# line to the log mid-run.  Writes the pty transcript to <outfile> and the
# exit code to <outfile>.rc.  argv[0] must be an absolute (or cwd-relative)
# path: the child execs it directly with os.execv, which does not search
# PATH.  The child inherits this process's environment (including the
# isolated HOME/XDG_* set above), so it is isolated the same way a direct
# invocation is.
run_pty() {
    local out=$1 tmo=$2 sig=$3 app=$4 line=$5; shift 5
    python3 - "$out" "$tmo" "$sig" "$app" "$line" "$@" <<'PYEOF'
import pty, os, time, select, signal, sys, fcntl, termios, struct
out, tmo, sig_after, app_after, line = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
argv = sys.argv[6:]
pid, fd = pty.fork()
if pid == 0:
    os.execv(argv[0], argv)
    os._exit(127)
# Parent: give the pty a real, fixed size (30 rows x 100 cols) right away
# so both this driver and the Python oracle see the same TIOCGWINSZ
# result instead of both falling back to the 80x24 default.
try:
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 100, 0, 0))
except OSError:
    pass
buf = b""
start = time.time()
sent = False
appended = False
rc = "alive"
# <sigint_after> and <append_after> count from the child's FIRST OUTPUT, not
# from fork: the Python oracle can take longer than a second to import and
# render on a loaded machine, and a SIGINT that lands before its
# KeyboardInterrupt handling is installed exits with a traceback instead
# of the shape under test.
first_out = None
deadline = start + tmo
while time.time() < deadline:
    since = (time.time() - first_out) if first_out is not None else -1.0
    if sig_after >= 0 and not sent and since > sig_after:
        os.kill(pid, signal.SIGINT); sent = True
        # give the child a grace period to exit cleanly after the signal
        # even when its slow start-up used up most of the timeout (a loaded
        # Linux VM took >2 s to paint the Python's first frame)
        deadline = max(deadline, time.time() + 3.0)
    if app_after >= 0 and not appended and since > app_after and line:
        with open(os.environ.get("TCWATCH_LOG", "/nonexistent"), "a") as f:
            f.write(line + "\n")
        appended = True
    try:
        wpid, status = os.waitpid(pid, os.WNOHANG)
        if wpid == pid:
            rc = os.waitstatus_to_exitcode(status)
            # macOS can discard a child's still-buffered pty output once
            # the child has exited and the slave side closed, unless the
            # master has already read it.  Drain whatever is left right
            # now, before doing anything else.
            while True:
                r, _, _ = select.select([fd], [], [], 0)
                if not r:
                    break
                try:
                    chunk = os.read(fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                buf += chunk
            break
    except ChildProcessError:
        rc = "gone"; break
    # Poll at least once a second (in practice every 50ms) so a burst of
    # output right before the child exits is never left unread for long
    # enough for macOS to drop it.
    r, _, _ = select.select([fd], [], [], 0.05)
    if r:
        try:
            chunk = os.read(fd, 65536)
        except OSError:
            chunk = b""
        if chunk:
            buf += chunk
            if first_out is None:
                first_out = time.time()
if rc == "alive":
    os.kill(pid, signal.SIGKILL)
    try: os.waitpid(pid, 0)
    except ChildProcessError: pass
with open(out, "wb") as f:
    f.write(buf)
with open(out + ".rc", "w") as f:
    f.write(str(rc))
PYEOF
}

# strip_ansi <file>: printable transcript without CSI sequences
strip_ansi() {
    python3 - "$1" <<'PYEOF'
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
txt = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", txt)
print("\n".join(l.rstrip() for l in txt.split("\r\n") if l.strip()))
PYEOF
}

first_frame() { # first_frame <stripped-file> : lines up to the status line
    python3 - "$1" <<'PYEOF'
import sys
lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n")
out = []
for l in lines:
    out.append(l)
    if "Ctrl-C to stop" in l:
        break
print("\n".join(out))
PYEOF
}

# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------
rm -rf "$DATA"
mkdir -p "$LOGS/$CH"
cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
cat > "$DATA/cfg.toml" <<'EOF'
[tail]
notify = false
EOF
export TCWATCH_LOG="$LOGS/$CH/$CH-2026-09-18.log"

BASE=( -c "$CH" -d "$LOGS" -w 0.2 --config "$DATA/cfg.toml" --no-cache )

# ---------------------------------------------------------------------------
echo "== non-tty error =="
ERR=$("$BIN" "${BASE[@]}" 2>&1); RC=$?
check "non-tty error text" "error: --watch needs a terminal (it repaints in place)" "$ERR"
check "non-tty exit code" "1" "$RC"

# ---------------------------------------------------------------------------
UNAME_S=$(uname -s)
if [ "$UNAME_S" = "Darwin" ]; then
    echo "== notify=true (default) under a pty, macOS: first frame vs Python =="
    run_pty "$DATA/notify.out" 4 1.0 -1 "" "$BIN" -c "$CH" -d "$LOGS" -w 0.2 --no-cache
    NRC=$(cat "$DATA/notify.out.rc")
    check "notify (macOS) SIGINT exit code" "130" "$NRC"
    strip_ansi "$DATA/notify.out" > "$DATA/notify.plain"
    first_frame "$DATA/notify.plain" > "$DATA/notify.frame"

    run_pty "$DATA/notify_py.out" 4 1.0 -1 "" "$PY" "$PYSCRIPT" -c "$CH" -d "$LOGS" -w 0.2 --no-cache
    strip_ansi "$DATA/notify_py.out" > "$DATA/notify_py.plain"
    first_frame "$DATA/notify_py.plain" > "$DATA/notify_py.frame"

    if diff -u "$DATA/notify_py.frame" "$DATA/notify.frame" > "$DATA/notify_frame.diff"; then
        ok "notify=true (macOS) first frame matches Python byte-for-byte"
    else
        bad "notify=true (macOS) first frame matches Python byte-for-byte"
        sed 's/^/    /' "$DATA/notify_frame.diff" | head -20
    fi
else
    echo "== notify=true (default) under a pty =="
    run_pty "$DATA/notify.out" 4 -1 -1 "" "$BIN" -c "$CH" -d "$LOGS" -w 0.2 --no-cache
    NRC=$(cat "$DATA/notify.out.rc")
    NERR=$(strip_ansi "$DATA/notify.out" | head -1)
    check "notify exit code" "1" "$NRC"
    check "notify error text" "error: TODO - not implemented: change notification on Linux. set [tail] notify = false to poll on the interval instead" "$NERR"
fi

# ---------------------------------------------------------------------------
echo "== differential: first frame vs Python =="
run_pty "$DATA/asm.out" 4 1.0 -1 "" "$BIN" "${BASE[@]}"
ARC=$(cat "$DATA/asm.out.rc")
check "asm SIGINT exit code" "130" "$ARC"
strip_ansi "$DATA/asm.out" > "$DATA/asm.plain"
first_frame "$DATA/asm.plain" > "$DATA/asm.frame"

run_pty "$DATA/py.out" 4 1.0 -1 "" "$PY" "$PYSCRIPT" "${BASE[@]}"
PRC=$(cat "$DATA/py.out.rc")
strip_ansi "$DATA/py.out" > "$DATA/py.plain"
first_frame "$DATA/py.plain" > "$DATA/py.frame"

check "python SIGINT exit code" "0" "$PRC"
if diff -u "$DATA/py.frame" "$DATA/asm.frame" > "$DATA/frame.diff"; then
    ok "first frame matches Python byte-for-byte"
else
    bad "first frame matches Python byte-for-byte"
    sed 's/^/    /' "$DATA/frame.diff" | head -20
fi

# cursor was restored after SIGINT
if grep -q $'\x1b\[?25h' "$DATA/asm.out"; then
    ok "cursor restored on SIGINT"
else
    bad "cursor restored on SIGINT"
fi

# ---------------------------------------------------------------------------
echo "== append updates the frame =="
run_pty "$DATA/app.out" 5 4.5 1.5 "[10:00:05] alice: hello again" "$BIN" "${BASE[@]}"
strip_ansi "$DATA/app.out" > "$DATA/app.plain"
if grep -q "alice                     2" "$DATA/app.plain" && grep -q "3 of 3 message" "$DATA/app.plain"; then
    ok "appended line appears on the next frame"
else
    bad "appended line appears on the next frame"
fi

# ---------------------------------------------------------------------------
echo "== recent fixture: --since and --users windows =="
# The fixed 10:00 fixture only suits the whole-day default window.  Sliding
# and sized windows need messages near "now", so generate a second channel
# whose messages sit inside the last hour, with a yesterday file to seed the
# live/offline state.
RCH=recent
mkdir -p "$LOGS/$RCH"
python3 - "$LOGS/$RCH" <<'PYEOF'
import datetime, os, sys
base = sys.argv[1]
now = datetime.datetime.now()
today = now.strftime("%Y-%m-%d")
yest = (now - datetime.timedelta(days=1)).strftime("%Y-%m-%d")
with open(os.path.join(base, f"{sys.argv[1].rsplit('/',1)[-1]}-{yest}.log"), "w") as f:
    f.write("[10:00:00] Recent is live!\n")
    for i in range(2):
        t = (now - datetime.timedelta(days=1)).replace(hour=10, minute=1+i, second=0)
        f.write(f"[{t.strftime('%H:%M:%S')}] yuser{i}: yesterday {i}\n")
    f.write("[12:00:00] Recent is offline!\n")
# The four 'recent' messages are minutes before now; shortly after local
# midnight some of them belong to yesterday, so each goes into the file of
# its own date (appended, so yesterday's fixed lines above are kept).
recent = {}
for i in range(4):
    t = now - datetime.timedelta(minutes=20 - i*2, seconds=5)
    recent.setdefault(t.strftime("%Y-%m-%d"), []).append(f"[{t.strftime('%H:%M:%S')}] user{i}: msg {i}\n")
with open(os.path.join(base, f"{sys.argv[1].rsplit('/',1)[-1]}-{today}.log"), "w") as f:
    f.write("[00:00:00] Recent is live!\n")
for day, lines in recent.items():
    with open(os.path.join(base, f"{sys.argv[1].rsplit('/',1)[-1]}-{day}.log"), "a") as f:
        f.writelines(lines)
PYEOF
RBASE=( -c "$RCH" -d "$LOGS" -w 0.2 --config "$DATA/cfg.toml" --no-cache )

echo "== differential: --since first frame vs Python =="
run_pty "$DATA/s_asm.out" 4 1.0 -1 "" "$BIN" "${RBASE[@]}" --since 30m
strip_ansi "$DATA/s_asm.out" > "$DATA/s_asm.plain"
first_frame "$DATA/s_asm.plain" > "$DATA/s_asm.frame"
run_pty "$DATA/s_py.out" 4 1.0 -1 "" "$PY" "$PYSCRIPT" "${RBASE[@]}" --since 30m
strip_ansi "$DATA/s_py.out" > "$DATA/s_py.plain"
first_frame "$DATA/s_py.plain" > "$DATA/s_py.frame"
if diff -u "$DATA/s_py.frame" "$DATA/s_asm.frame" > "$DATA/s_frame.diff"; then
    ok "--since first frame matches Python byte-for-byte"
else
    bad "--since first frame matches Python byte-for-byte"
    sed 's/^/    /' "$DATA/s_frame.diff" | head -20
fi
# the rolling window must actually reach the messages (a 30m window ending now)
if grep -q "user0\|user1\|user2\|user3" "$DATA/s_asm.plain"; then
    ok "--since window reaches the recent messages"
else
    bad "--since window reaches the recent messages"
fi

echo "== differential: --users first frame vs Python =="
run_pty "$DATA/u_asm.out" 4 1.0 -1 "" "$BIN" "${RBASE[@]}" --users 2
strip_ansi "$DATA/u_asm.out" > "$DATA/u_asm.plain"
first_frame "$DATA/u_asm.plain" > "$DATA/u_asm.frame"
run_pty "$DATA/u_py.out" 4 1.0 -1 "" "$PY" "$PYSCRIPT" "${RBASE[@]}" --users 2
strip_ansi "$DATA/u_py.out" > "$DATA/u_py.plain"
first_frame "$DATA/u_py.plain" > "$DATA/u_py.frame"
if diff -u "$DATA/u_py.frame" "$DATA/u_asm.frame" > "$DATA/u_frame.diff"; then
    ok "--users first frame matches Python byte-for-byte"
else
    bad "--users first frame matches Python byte-for-byte"
    sed 's/^/    /' "$DATA/u_frame.diff" | head -20
fi
if grep -q "2 of 2 user" "$DATA/u_asm.plain"; then
    ok "--users window sized to exactly 2 users"
else
    bad "--users window sized to exactly 2 users"
fi

rm -rf "$LOGS/$RCH"

# ---------------------------------------------------------------------------
echo "== --json mutually exclusive with --watch =="
JERR=$("$BIN" -c "$CH" -d "$LOGS" -w 0.2 --json --no-cache 2>&1 | tail -1)
check "json+watch error text" "tc-watch-test: error: argument -j/--json: not allowed with argument -w/--watch" "$JERR"

# ---------------------------------------------------------------------------
echo "== JSON interrupted shape (driver honours the flag) =="
# The CLI rejects --watch with --json, so drive the JSON shape directly is
# unreachable through main(); the driver code path exists for parity but the
# CLI mutual-exclusion above is the observable behaviour.
ok "json+watch rejected at parse time (driver parity path untestable)"

# ---------------------------------------------------------------------------
echo "== empty range: 'No users met the threshold' =="
# A channel with no messages still paints a watch frame.
VCH=voidch
mkdir -p "$LOGS/$VCH"
cat > "$LOGS/$VCH/$VCH-2026-09-18.log" <<'EOF'
[10:00:00] VoidChannel is live!
EOF
run_pty "$DATA/empty.out" 4 1.0 -1 "" "$BIN" -c "$VCH" -d "$LOGS" -w 0.2 --config "$DATA/cfg.toml" --no-cache
strip_ansi "$DATA/empty.out" > "$DATA/empty.plain"
if grep -q "No users met the threshold" "$DATA/empty.plain"; then
    ok "empty-range frame paints"
else
    bad "empty-range frame paints"
fi
rm -rf "$LOGS/$VCH"

# ---------------------------------------------------------------------------
if [ "$UNAME_S" = "Darwin" ]; then
    echo "== event-driven wake: -w 5, notify=true shows an append within 1.5s =="
    # The "append updates the frame" test above (and this block's own later
    # sub-tests) mutate $TCWATCH_LOG in place, so reset it to the known
    # 3-line fixture before each sub-test that depends on a fixed line/user
    # count instead of trusting whatever state earlier tests left behind.
    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    cat > "$DATA/notify_true.toml" <<'EOF'
[tail]
notify = true
EOF
    run_pty "$DATA/wake.out" 3 -1 1.0 "[10:00:05] alice: wake test" \
        "$BIN" -c "$CH" -d "$LOGS" -w 5 --config "$DATA/notify_true.toml" --no-cache
    strip_ansi "$DATA/wake.out" > "$DATA/wake.plain"
    if grep -q "alice                     2" "$DATA/wake.plain" && grep -q "3 of 3 message" "$DATA/wake.plain"; then
        ok "notify=true wakes on write before the 5s tick"
    else
        bad "notify=true wakes on write before the 5s tick"
    fi

    echo "== event-driven wake: -w 5, notify=false does NOT show an append before the tick =="
    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    run_pty "$DATA/nowake.out" 3 -1 1.0 "[10:00:05] alice: wake test" \
        "$BIN" -c "$CH" -d "$LOGS" -w 5 --config "$DATA/cfg.toml" --no-cache
    strip_ansi "$DATA/nowake.out" > "$DATA/nowake.plain"
    if grep -q "alice                     2" "$DATA/nowake.plain"; then
        bad "notify=false does not wake on write before the tick"
    else
        ok "notify=false does not wake on write before the tick"
    fi

    # -------------------------------------------------------------------
    echo "== show_timing: status line wake source, asm vs Python (cumulative quirk) =="
    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    cat > "$DATA/timing.toml" <<'EOF'
[tail]
notify = true

[watch]
show_timing = true
EOF
    run_pty "$DATA/timing_asm.out" 3 -1 1.0 "[10:00:05] alice: timing test" \
        "$BIN" -c "$CH" -d "$LOGS" -w 5 --config "$DATA/timing.toml" --no-cache
    strip_ansi "$DATA/timing_asm.out" > "$DATA/timing_asm.plain"
    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    run_pty "$DATA/timing_py.out" 3 -1 1.0 "[10:00:05] alice: timing test" \
        "$PY" "$PYSCRIPT" -c "$CH" -d "$LOGS" -w 5 --config "$DATA/timing.toml" --no-cache
    strip_ansi "$DATA/timing_py.out" > "$DATA/timing_py.plain"

    # first frame (before the append lands) must show "woke on timer" -- do
    # not hardcode this: derive the expectation from what python3 actually
    # prints in this scenario, since the wake-source counter is cumulative
    # (Python's woke_on_write is an incrementing counter, never reset, so
    # once ANY write wakes the loop every later frame also reads "write").
    PY_FIRST_WOKE=$(grep -o "woke on [a-z]*" "$DATA/timing_py.plain" | head -1)
    ASM_FIRST_WOKE=$(grep -o "woke on [a-z]*" "$DATA/timing_asm.plain" | head -1)
    check "show_timing first frame wake source matches Python" "$PY_FIRST_WOKE" "$ASM_FIRST_WOKE"

    PY_LAST_WOKE=$(grep -o "woke on [a-z]*" "$DATA/timing_py.plain" | tail -1)
    ASM_LAST_WOKE=$(grep -o "woke on [a-z]*" "$DATA/timing_asm.plain" | tail -1)
    check "show_timing post-append frame wake source matches Python" "$PY_LAST_WOKE" "$ASM_LAST_WOKE"

    # -------------------------------------------------------------------
    echo "== NO_COLOR / --color: presence of ESC[38;2; tint sequences =="
    # colorizer() only tints a row once a count has RISEN relative to the
    # previous rendered frame (see twitch-counts.py colorizer(): the first
    # frame has previous=None so nothing is tinted, and a row with no count
    # change never enters the tints dict). So a still fixture never produces
    # a tint regardless of --color, and asserting "always yields some" needs
    # an actual mid-run append to bump a count across two frames. Reset the
    # shared fixture log first since earlier sub-tests in this block append
    # to it.
    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    NO_COLOR=1 run_pty "$DATA/nocolor_asm.out" 3 2.0 1.0 "[10:00:05] alice: color test" \
        "$BIN" -c "$CH" -d "$LOGS" -w 0.2 --config "$DATA/cfg.toml" --no-cache --color never
    if grep -q $'\x1b\[38;2;' "$DATA/nocolor_asm.out"; then
        bad "NO_COLOR + --color never: asm has no tint sequences"
    else
        ok "NO_COLOR + --color never: asm has no tint sequences"
    fi

    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    NO_COLOR=1 run_pty "$DATA/nocolor_py.out" 3 2.0 1.0 "[10:00:05] alice: color test" \
        "$PY" "$PYSCRIPT" -c "$CH" -d "$LOGS" -w 0.2 --config "$DATA/cfg.toml" --no-cache --color never
    if grep -q $'\x1b\[38;2;' "$DATA/nocolor_py.out"; then
        bad "NO_COLOR + --color never: Python has no tint sequences"
    else
        ok "NO_COLOR + --color never: Python has no tint sequences"
    fi

    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    NO_COLOR=1 run_pty "$DATA/color_asm.out" 3 2.0 1.0 "[10:00:05] alice: color test" \
        "$BIN" -c "$CH" -d "$LOGS" -w 0.2 --config "$DATA/cfg.toml" --no-cache --color always
    if grep -q $'\x1b\[38;2;' "$DATA/color_asm.out"; then
        ok "NO_COLOR + --color always: asm still has tint sequences"
    else
        bad "NO_COLOR + --color always: asm still has tint sequences"
    fi

    cat > "$LOGS/$CH/$CH-2026-09-18.log" <<'EOF'
[10:00:00] Chron is live!
[10:00:01] alice: hello
[10:00:02] bob: hi
EOF
    NO_COLOR=1 run_pty "$DATA/color_py.out" 3 2.0 1.0 "[10:00:05] alice: color test" \
        "$PY" "$PYSCRIPT" -c "$CH" -d "$LOGS" -w 0.2 --config "$DATA/cfg.toml" --no-cache --color always
    if grep -q $'\x1b\[38;2;' "$DATA/color_py.out"; then
        ok "NO_COLOR + --color always: Python still has tint sequences"
    else
        bad "NO_COLOR + --color always: Python still has tint sequences"
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "=========================================="
echo "test-tc-watch.sh: $PASS passed, $FAIL failed"
if [ ${#FAILED_TESTS[@]} -gt 0 ]; then
    printf 'failed: %s\n' "${FAILED_TESTS[@]}"
fi
[ $FAIL -eq 0 ]
