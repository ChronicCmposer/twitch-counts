#!/bin/sh
# test-tc-core.sh — Phase 4 test driver for tc_core.S (twitch-counts-full).
#
# Builds a synthetic Chatterino log tree in a mktemp dir and checks:
#   (a) channel resolution: case-insensitive match + exact error strings
#   (b) listing: date filtering, stream-log rejection, invalid-date
#       rejection, sort order
#   (c) window: -b/-e mid-day clipping, -S since with fixed -e,
#       default-earliest, begin>end error
#   (d) counting: per-user per-state counts, state carry, cross-day seed,
#       unknown state, state filter, exclusions (via the private stub),
#       unreadable recording
#   (e) --users sizing: width/found for each policy + the unreachable case
#   (f) differential vs python3 twitch-counts.py: per-user counts, tally
#       totals, and sized (width, found).  python3 (>= 3.11, with tomllib)
#       is a hard requirement of this harness, checked once at the top.
#
# The binary under test is $BUILD/tc-core-test (check_tc_core.o + tc_core.o +
# tc_cli.o + tc_util.o + tc_config_stub.o + toml.o), linked with the exact
# commands the Phase-4 spec allows.  tc_config.o (Phase 3) is NEVER linked.
# It is built ahead of time by `make drivers` (this script never builds
# anything itself); BUILD defaults to build/<os> under this script's own
# directory, using the same `uname -s | tr A-Z a-z` rule as the Makefile,
# and can be overridden with TC_BUILD (as `make test` does).  Run
# `make drivers twitch-counts-full` first if $BUILD/tc-core-test is missing.
#
# Isolation: every invocation of the driver and of the python3 oracle below
# runs with HOME/XDG_CONFIG_HOME/XDG_CACHE_HOME pointed at a directory under
# this run's own mktemp sandbox (exported once, right after the sandbox is
# created), so nothing here can ever touch the real user's
# ~/.cache/twitch-counts/rollup.db or ~/.config/twitch-counts.toml — the
# Python's macOS class ignores XDG and reads HOME directly, its Linux class
# and the assembly honour XDG, so both are set to cover either platform.
set -u

cd "$(dirname "$0")" || exit 2
SCRIPT_DIR=$(pwd)

# --- python3 oracle: must be on PATH and >= 3.11 (tomllib), never a bare
#     hard-coded interpreter path -------------------------------------------
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 not found on PATH (needed to run the oracle, twitch-counts.py)" >&2
    exit 2
fi
if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    echo "FAIL: python3 ($(command -v python3), $(python3 --version 2>&1)) lacks tomllib; need >= 3.11" >&2
    exit 2
fi
PY="$SCRIPT_DIR/twitch-counts.py"
[ -f "$PY" ] || { echo "FAIL: oracle not found: $PY" >&2; exit 2; }

# --- driver: built ahead of time by `make drivers`, never here -------------
BUILD=${TC_BUILD:-build/$(uname -s | tr A-Z a-z)}
case $BUILD in
    /*) : ;;
    *) BUILD="$SCRIPT_DIR/$BUILD" ;;
esac
BIN="$BUILD/tc-core-test"
[ -x "$BIN" ] || {
    echo "FAIL: driver not found: $BIN (run: make drivers)" >&2
    exit 2
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tc-core-test.XXXXXX") || {
    echo "FAIL: cannot create temp directory"
    exit 2
}
trap 'rm -rf "$tmpdir"' EXIT INT TERM

# Sandbox HOME/XDG so the driver and the python3 oracle can never reach the
# real user's config/cache (see "Isolation" above).
home_sandbox="$tmpdir/home"
mkdir -p "$home_sandbox/.config" "$home_sandbox/.cache"
HOME="$home_sandbox"
XDG_CONFIG_HOME="$home_sandbox/.config"
XDG_CACHE_HOME="$home_sandbox/.cache"
export HOME XDG_CONFIG_HOME XDG_CACHE_HOME

channels="$tmpdir/Logs/Twitch/Channels"
mkdir -p "$channels/chroniccmposer" "$channels/sizer" "$channels/unkchan" \
         "$channels/latechan" "$channels/empty"

pass=0
fail=0
ok_or_fail() { # ok_or_fail <name> <ok: 1=pass, 0=fail>
    if [ "$2" -ne 0 ]; then
        echo "PASS: $1"
        pass=$((pass + 1))
    else
        echo "FAIL: $1"
        fail=$((fail + 1))
    fi
}

# --- synthetic channel logs --------------------------------------------------
cd "$channels/chroniccmposer" || exit 2

# 08-31: a previous-day marker that seeds 09-01 (state carry / seed test)
cat > chroniccmposer-2026-08-31.log << 'EOF'
[15:15:30] ChronicCmposer is live!
EOF

# 09-01: a pre-marker message (seeded live), a live block, a localized
# display name, a system line and a comment (all must be classified right)
cat > chroniccmposer-2026-09-01.log << 'EOF'
[08:00:00] early_seed: before any marker
[15:15:32] ChronicCmposer is live!
[15:15:33] alice: hello world
[15:15:34] bob: hi alice
[15:16:00] 반_요다 choco_yoda: hello
[15:16:01] Suspicious User: Restricted
# a comment line
[15:16:02] carol: testing
[15:17:00] ChronicCmposer is now offline.
[15:17:05] bob: good stream
EOF

cat > chroniccmposer-2026-09-02.log << 'EOF'
[15:10:00] ChronicCmposer is live!
[15:10:05] alice: day two
[15:11:00] bob: second day
[15:12:00] alice: more
[15:13:00] dave: newcomer
[15:14:00] ChronicCmposer is now offline.
EOF

# Created AFTER 09-02 to prove the listing sorts ascending, not by mtime.
cat > chroniccmposer-2026-09-03.log << 'EOF'
[16:00:00] ChronicCmposer is live!
[16:00:01] alice: third day
[16:00:02] bob: third day too
[16:00:03] alice: more more
[16:01:00] ChronicCmposer is now offline.
EOF

# A per-stream log that the dated-file matcher must reject.
cat > chroniccmposer-12345.log << 'EOF'
[15:00:00] ChronicCmposer is live!
EOF

# A well-shaped name with an impossible date (2026-02-30) that must be
# rejected before it can be counted.
cat > chroniccmposer-2026-02-30.log << 'EOF'
[12:00:00] nobody: never
EOF

# sizer: four users crossing the threshold at distinct widths
cd "$channels/sizer" || exit 2
cat > sizer-2026-09-01.log << 'EOF'
[12:00:00] sizer is live!
[12:00:00] userA: a
[12:00:00] userB: b
[12:00:01] userC: c
[12:00:02] userD: d
EOF

# unkchan: a first message with no state known (seed cannot help)
cd "$channels/unkchan" || exit 2
cat > unkchan-2026-09-01.log << 'EOF'
[09:00:00] mystery: pre-marker
[10:00:00] unkchan is live!
[10:00:01] known: post-marker
EOF

# latechan: only a 09-05 log, for the earliest-begin > end error
cd "$channels/latechan" || exit 2
cat > latechan-2026-09-05.log << 'EOF'
[12:00:00] latechan is live!
EOF

# unreadable: a directory whose name matches the dated-log shape
cd "$channels" || exit 2
mkdir -p "unrchan/unrchan-2026-09-02.log"
cat > unrchan/unrchan-2026-09-01.log << 'EOF'
[12:00:00] unrchan is live!
[12:00:01] a: hi
EOF

cd "$tmpdir" || exit 2

# ============================================================================
# (a) channel resolution
# ============================================================================
# a1. case-insensitive match resolves to the real on-disk name
out=$("$BIN" -c CHRONICCMPOSER -d "$channels" -e 2026-09-03 2>"$tmpdir/e")
ok=0
[ "$(printf '%s\n' "$out" | sed -n 's/^channel=//p')" = "chroniccmposer" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: $out"
ok_or_fail "a1. case-insensitive channel match" "$ok"

# a2. missing logs dir
"$BIN" -c chroniccmposer -d "$channels/nope" -e 2026-09-03 \
    >"$tmpdir/o" 2>"$tmpdir/e"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/o" ] && \
    [ "$(cat "$tmpdir/e")" = "error: logs directory not found: $channels/nope" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/e")"
ok_or_fail "a2. 'logs directory not found' exact" "$ok"

# a3. bad channel with available: list
"$BIN" -c nope -d "$channels" -e 2026-09-03 >"$tmpdir/o" 2>"$tmpdir/e"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/o" ] && \
    [ "$(cat "$tmpdir/e")" = "error: no logs for channel 'nope' in $channels
available: chroniccmposer, empty, latechan, sizer, unkchan, unrchan" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/e")"
ok_or_fail "a3. 'no logs for channel' + available list exact" "$ok"

# a4. no log files found in an existing but empty channel dir
"$BIN" -c empty -d "$channels" -e 2026-09-03 >"$tmpdir/o" 2>"$tmpdir/e"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/o" ] && \
    [ "$(cat "$tmpdir/e")" = "error: no log files found in $channels/empty" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/e")"
ok_or_fail "a4. 'no log files found' exact" "$ok"

# a5. earliest-begin > end (Python's begin>end check for kind 3)
"$BIN" -c latechan -d "$channels" -e 2026-09-03 >"$tmpdir/o" 2>"$tmpdir/e"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/o" ] && \
    [ "$(cat "$tmpdir/e")" = "error: begin (2026-09-05 00:00:00) is after end (2026-09-03 23:59:59)" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/e")"
ok_or_fail "a5. earliest begin>end error exact" "$ok"

# ============================================================================
# (b) listing
# ============================================================================
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 2>"$tmpdir/e")
listing=$(printf '%s\n' "$out" | sed -n '/^listing /,$p' | sed -n '/^[0-9]/p' | awk '{print $1}')
ok=0
[ "$listing" = "20260831
20260901
20260902
20260903" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: listing='$listing'"
ok_or_fail "b1. listing sorted ascending, stream/invalid-date files rejected" "$ok"

# ============================================================================
# (c) window
# ============================================================================
# c1. -b/-e mid-day: window 09-01 15:15:33..15:15:35 clips to those seconds
out=$("$BIN" -c chroniccmposer -d "$channels" -b "2026-09-01 15:15:33" -e "2026-09-01 15:15:35" 2>"$tmpdir/e")
users=$(printf '%s\n' "$out" | sed -n '/^users [0-9]/,$p' | sed -n 's/^\([a-z_0-9]*\) [0-9]* [0-9]* [0-9]*$/\1/p' | tr '\n' ' ')
msg=$(printf '%s\n' "$out" | sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p')
ok=0
[ "$users" = "alice bob " ] && [ "$msg" = "2" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: users='$users' msg=$msg"
ok_or_fail "c1. -b/-e mid-day clipping (lo/hi)" "$ok"

# c2. -S since with fixed -e spans two days
out=$("$BIN" -c chroniccmposer -d "$channels" -S 1d -e 2026-09-03 2>"$tmpdir/e")
begin=$(printf '%s\n' "$out" | sed -n 's/^window begin=\([0-9]*\):\([0-9]*\) end=.*/\1 \2/p')
msg=$(printf '%s\n' "$out" | sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p')
ok=0
[ "$begin" = "20260902 86399" ] && [ "$msg" = "3" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: begin='$begin' msg=$msg"
ok_or_fail "c2. -S since with fixed -e" "$ok"

# c3. default-earliest window begins at the earliest log file 00:00:00
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 2>"$tmpdir/e")
begin=$(printf '%s\n' "$out" | sed -n 's/^window begin=\([0-9]*\):\([0-9]*\) end=.*/\1 \2/p')
kind=$(printf '%s\n' "$out" | sed -n 's/^window .*kind=\([0-9]*\).*/\1/p')
ok=0
[ "$begin" = "20260831 0" ] && [ "$kind" = "3" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: begin='$begin' kind=$kind"
ok_or_fail "c3. default-earliest window" "$ok"

# ============================================================================
# (d) counting
# ============================================================================
# d1. per-user per-state counts, cross-file state carry (basic run)
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 2>"$tmpdir/e")
users=$(printf '%s\n' "$out" | sed -n '/^users [0-9]/,$p' | sed -n 's/^\([a-z_0-9]*\) \(.*\)$/\1 \2/p' | tr '\n' '|')
msg=$(printf '%s\n' "$out" | sed -n 's/^tally .*messages=\([0-9]*\) parsed=\([0-9]*\) states=\([0-9:]*\).*/\1 \2 \3/p')
ok=0
[ "$msg" = "13 4 12:1:0" ] && ok=1
case "$users" in
    *"alice 5 0 0"*"bob 3 1 0"*"carol 1 0 0"*"choco_yoda 1 0 0"*"dave 1 0 0"*"early_seed 1 0 0"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: users='$users' msg='$msg'"
ok_or_fail "d1. per-user per-state counts + state carry" "$ok"

# d2. seed from the previous day (08-31 marker makes 09-01's pre-marker live)
out=$("$BIN" -c chroniccmposer -d "$channels" -b 2026-09-01 -e 2026-09-01 2>"$tmpdir/e")
state=$(printf '%s\n' "$out" | sed -n 's/^tally .*states=\([0-9:]*\).*/\1/p')
es=$(printf '%s\n' "$out" | sed -n 's/^tally .*early_seed//p')
msg=$(printf '%s\n' "$out" | sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p')
ok=0
[ "$state" = "5:1:0" ] && [ "$msg" = "6" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: state=$state msg=$msg"
ok_or_fail "d2. cross-day seed state" "$ok"

# d3. unknown state when nothing can seed it
out=$("$BIN" -c unkchan -d "$channels" -b 2026-09-01 -e 2026-09-01 2>"$tmpdir/e")
state=$(printf '%s\n' "$out" | sed -n 's/^tally .*states=\([0-9:]*\).*/\1/p')
mystery=$(printf '%s\n' "$out" | sed -n 's/^mystery \(.*\)$/\1/p')
ok=0
[ "$state" = "1:0:1" ] && [ "$mystery" = "0 0 1" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: state=$state mystery='$mystery'"
ok_or_fail "d3. unknown state" "$ok"

# d4. state filter (-L): count column is live-only, states keep all
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -L 2>"$tmpdir/e")
msg=$(printf '%s\n' "$out" | sed -n 's/^tally .*messages=\([0-9]*\) .*states=\([0-9:]*\).*/\1 \2/p')
bob=$(printf '%s\n' "$out" | sed -n 's/^bob \(.*\)$/\1/p')
ok=0
[ "$msg" = "12 12:1:0" ] && [ "$bob" = "3 1 0" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: msg='$msg' bob='$bob'"
ok_or_fail "d4. -L state filter" "$ok"

# d5. exclusions via the private stub: -x bob,carol subtracts from tally
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -x bob,carol 2>"$tmpdir/e")
tally=$(printf '%s\n' "$out" | sed -n 's/^tally .*messages=\([0-9]*\) .*states=\([0-9:]*\) excl=\([0-9:]*\).*/\1 \2 \3/p')
ok=0
[ "$tally" = "8 8:0:0 4:1:0" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: tally='$tally'"
ok_or_fail "d5. exclusions subtract from tally" "$ok"

# d6. unreadable recording (a directory named like a dated log)
out=$("$BIN" -c unrchan -d "$channels" -b 2026-09-01 -e 2026-09-03 2>"$tmpdir/e")
unr=$(printf '%s\n' "$out" | sed -n 's/^unreadable \(.*\)$/\1/p')
files=$(printf '%s\n' "$out" | sed -n 's/^tally files=\([0-9]*\).*/\1/p')
msg=$(printf '%s\n' "$out" | sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p')
ok=0
[ "$unr" = "unrchan-2026-09-02.log cannot read" ] && [ "$files" = "2" ] && [ "$msg" = "1" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: unr='$unr' files=$files msg=$msg"
ok_or_fail "d6. unreadable log recorded" "$ok"

# ============================================================================
# (e) --users sizing (population: userA/userB at 12:00:00, userC 12:00:01,
#     userD 12:00:02; end 12:00:10; threshold 1):
#       reported(w): w<8 -> 0, 8<=w<9 -> 1, 9<=w<10 -> 2, w>=10 -> 4
#     --users 3: at-least -> (10, 4), at-most -> (9, 2), nearest -> (9, 2)
#     --users 5: unreachable -> (86400, 4)
# ============================================================================
SIZER_ARGS="-c sizer -d $channels -e \"2026-09-01 12:00:10\""

out=$("$BIN" -c sizer -d "$channels" -e "2026-09-01 12:00:10" --users 3 --users-policy at-least 2>"$tmpdir/e")
sized=$(printf '%s\n' "$out" | sed -n 's/^window .*width=\([0-9]*\) found=\([0-9]*\) req=\([0-9]*\).*/\1 \2 \3/p')
ok=0
[ "$sized" = "10 4 3" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: sized='$sized'"
ok_or_fail "e1. --users at-least sizing" "$ok"

out=$("$BIN" -c sizer -d "$channels" -e "2026-09-01 12:00:10" --users 3 --users-policy at-most 2>"$tmpdir/e")
sized=$(printf '%s\n' "$out" | sed -n 's/^window .*width=\([0-9]*\) found=\([0-9]*\) req=\([0-9]*\).*/\1 \2 \3/p')
ok=0
[ "$sized" = "9 2 3" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: sized='$sized'"
ok_or_fail "e2. --users at-most sizing" "$ok"

out=$("$BIN" -c sizer -d "$channels" -e "2026-09-01 12:00:10" --users 3 --users-policy nearest 2>"$tmpdir/e")
sized=$(printf '%s\n' "$out" | sed -n 's/^window .*width=\([0-9]*\) found=\([0-9]*\) req=\([0-9]*\).*/\1 \2 \3/p')
ok=0
[ "$sized" = "9 2 3" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: sized='$sized'"
ok_or_fail "e3. --users nearest (ties to narrower)" "$ok"

out=$("$BIN" -c sizer -d "$channels" -e "2026-09-01 12:00:10" --users 5 --users-policy at-least 2>"$tmpdir/e")
sized=$(printf '%s\n' "$out" | sed -n 's/^window .*width=\([0-9]*\) found=\([0-9]*\) req=\([0-9]*\).*/\1 \2 \3/p')
ok=0
[ "$sized" = "86400 4 5" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: sized='$sized'"
ok_or_fail "e4. --users unreachable count" "$ok"

# ============================================================================
# (f) differential vs python3 (python3 >= 3.11 with tomllib is a hard
# requirement of this harness, verified at the top; the body below keeps its
# original indentation from when it was wrapped in a "python3 found?" check)
# ============================================================================
    # f1. basic
    "$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 >"$tmpdir/my"
    python3 "$PY" -c chroniccmposer -d "$channels" -e 2026-09-03 --no-config --no-cache >"$tmpdir/py"
    awk '/^users [0-9]/{u=1; next} u==1 && NF==4 && $1 !~ /^tally/ {print $1, $2+$3+$4}' "$tmpdir/my" | sort > "$tmpdir/myrows"
    python3 - "$tmpdir/py" << 'PYEOF' | sort > "$tmpdir/pyrows"
import sys
rows = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("---"):
        continue
    p = line.split()
    if len(p) == 2 and p[0] != "user" and p[1].isdigit():
        rows[p[0]] = int(p[1])
for k, v in sorted(rows.items()):
    print(k, v)
PYEOF
    ok=1
    diff "$tmpdir/myrows" "$tmpdir/pyrows" >/dev/null 2>&1 || { ok=0; echo "  per-user diff:"; diff "$tmpdir/myrows" "$tmpdir/pyrows"; }
    py_m=$(sed -n 's/.*; [0-9,]* of \([0-9,]*\) message(s) in range.*/\1/p' "$tmpdir/py" | tr -d ',' | tail -1)
    my_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/my")
    [ "$py_m" = "$my_m" ] || { ok=0; echo "  messages python=$py_m mine=$my_m"; }
    py_f=$(sed -n 's/.*files: *\([0-9]*\) log file.*/\1/p' "$tmpdir/py" | tail -1)
    my_f=$(sed -n 's/^tally files=\([0-9]*\).*/\1/p' "$tmpdir/my")
    [ "$py_f" = "$my_f" ] || { ok=0; echo "  files python=$py_f mine=$my_f"; }
    my_s=$(sed -n 's/^tally .*states=\([0-9:]*\).*/\1/p' "$tmpdir/my" | awk -F: '{print $1":"$2}')
    py_lo=$(sed -n '/^state:/s/.*live \([0-9,]*\) \/ offline \([0-9,]*\).*/\1 \2/p' "$tmpdir/py" | tr -d ',' | awk '{print $1":"$2}')
    [ "$py_lo" = "$my_s" ] || { ok=0; echo "  states python=$py_lo mine=$my_s"; }
    ok_or_fail "diff: basic per-user counts + totals" "$ok"

    # f2. -L filter
    "$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -L >"$tmpdir/my"
    python3 "$PY" -c chroniccmposer -d "$channels" -e 2026-09-03 -L --no-config --no-cache >"$tmpdir/py"
    awk '/^users [0-9]/{u=1; next} u==1 && NF==4 && $1 !~ /^tally/ {print $1, $2}' "$tmpdir/my" | sort > "$tmpdir/myrows"
    python3 - "$tmpdir/py" << 'PYEOF' | sort > "$tmpdir/pyrows"
import sys
rows = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("---"):
        continue
    p = line.split()
    if len(p) == 2 and p[0] != "user" and p[1].isdigit():
        rows[p[0]] = int(p[1])
for k, v in sorted(rows.items()):
    print(k, v)
PYEOF
    ok=1
    diff "$tmpdir/myrows" "$tmpdir/pyrows" >/dev/null 2>&1 || { ok=0; echo "  per-user diff:"; diff "$tmpdir/myrows" "$tmpdir/pyrows"; }
    py_m=$(sed -n 's/.*; [0-9,]* of \([0-9,]*\) message(s) in range.*/\1/p' "$tmpdir/py" | tr -d ',' | tail -1)
    my_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/my")
    [ "$py_m" = "$my_m" ] || { ok=0; echo "  messages python=$py_m mine=$my_m"; }
    ok_or_fail "diff: -L filter" "$ok"

    # f3. exclusions via -x
    "$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -x bob,carol >"$tmpdir/my"
    python3 "$PY" -c chroniccmposer -d "$channels" -e 2026-09-03 -x bob,carol --no-config --no-cache >"$tmpdir/py"
    # mine keeps excluded rows in the table; python drops them.  Compare the
    # non-excluded rows and the totals.
    awk '/^users [0-9]/{u=1; next} u==1 && NF==4 && $1 !~ /^tally/ && $1!="bob" && $1!="carol" {print $1, $2+$3+$4}' "$tmpdir/my" | sort > "$tmpdir/myrows"
    python3 - "$tmpdir/py" << 'PYEOF' | sort > "$tmpdir/pyrows"
import sys
rows = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("---"):
        continue
    p = line.split()
    if len(p) == 2 and p[0] != "user" and p[1].isdigit():
        rows[p[0]] = int(p[1])
for k, v in sorted(rows.items()):
    print(k, v)
PYEOF
    ok=1
    diff "$tmpdir/myrows" "$tmpdir/pyrows" >/dev/null 2>&1 || { ok=0; echo "  per-user diff:"; diff "$tmpdir/myrows" "$tmpdir/pyrows"; }
    py_m=$(sed -n 's/.*; [0-9,]* of \([0-9,]*\) message(s) in range.*/\1/p' "$tmpdir/py" | tr -d ',' | tail -1)
    my_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/my")
    [ "$py_m" = "$my_m" ] || { ok=0; echo "  messages python=$py_m mine=$my_m"; }
    py_e=$(sed -n 's/.*excluded \([0-9,]*\) user(s), \([0-9,]*\) message(s) not counted.*/\2/p' "$tmpdir/py" | tr -d ',' | tail -1)
    my_e=$(sed -n 's/^tally .*excl=\([0-9:]*\).*/\1/p' "$tmpdir/my" | awk -F: '{print $1+$2+$3}')
    [ "$py_e" = "$my_e" ] || { ok=0; echo "  excluded messages python=$py_e mine=$my_e"; }
    ok_or_fail "diff: -x exclusions" "$ok"

    # f4. -b/-e mid-day
    "$BIN" -c chroniccmposer -d "$channels" -b "2026-09-01 15:15:33" -e "2026-09-01 15:15:35" >"$tmpdir/my"
    python3 "$PY" -c chroniccmposer -d "$channels" -b "2026-09-01 15:15:33" -e "2026-09-01 15:15:35" --no-config --no-cache >"$tmpdir/py"
    awk '/^users [0-9]/{u=1; next} u==1 && NF==4 && $1 !~ /^tally/ {print $1, $2+$3+$4}' "$tmpdir/my" | sort > "$tmpdir/myrows"
    python3 - "$tmpdir/py" << 'PYEOF' | sort > "$tmpdir/pyrows"
import sys
rows = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("---"):
        continue
    p = line.split()
    if len(p) == 2 and p[0] != "user" and p[1].isdigit():
        rows[p[0]] = int(p[1])
for k, v in sorted(rows.items()):
    print(k, v)
PYEOF
    ok=1
    diff "$tmpdir/myrows" "$tmpdir/pyrows" >/dev/null 2>&1 || { ok=0; echo "  per-user diff:"; diff "$tmpdir/myrows" "$tmpdir/pyrows"; }
    py_m=$(sed -n 's/.*; [0-9,]* of \([0-9,]*\) message(s) in range.*/\1/p' "$tmpdir/py" | tr -d ',' | tail -1)
    my_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/my")
    [ "$py_m" = "$my_m" ] || { ok=0; echo "  messages python=$py_m mine=$my_m"; }
    ok_or_fail "diff: -b/-e mid-day" "$ok"

    # f5. -S with -e
    "$BIN" -c chroniccmposer -d "$channels" -S 1d -e 2026-09-03 >"$tmpdir/my"
    python3 "$PY" -c chroniccmposer -d "$channels" -S 1d -e 2026-09-03 --no-config --no-cache >"$tmpdir/py"
    awk '/^users [0-9]/{u=1; next} u==1 && NF==4 && $1 !~ /^tally/ {print $1, $2+$3+$4}' "$tmpdir/my" | sort > "$tmpdir/myrows"
    python3 - "$tmpdir/py" << 'PYEOF' | sort > "$tmpdir/pyrows"
import sys
rows = {}
for line in open(sys.argv[1]):
    line = line.rstrip("\n")
    if line.startswith("---"):
        continue
    p = line.split()
    if len(p) == 2 and p[0] != "user" and p[1].isdigit():
        rows[p[0]] = int(p[1])
for k, v in sorted(rows.items()):
    print(k, v)
PYEOF
    ok=1
    diff "$tmpdir/myrows" "$tmpdir/pyrows" >/dev/null 2>&1 || { ok=0; echo "  per-user diff:"; diff "$tmpdir/myrows" "$tmpdir/pyrows"; }
    py_m=$(sed -n 's/.*; [0-9,]* of \([0-9,]*\) message(s) in range.*/\1/p' "$tmpdir/py" | tr -d ',' | tail -1)
    my_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/my")
    [ "$py_m" = "$my_m" ] || { ok=0; echo "  messages python=$py_m mine=$my_m"; }
    ok_or_fail "diff: -S since + -e" "$ok"

    # f6. --users sizing vs the python header's "users:" row
    for pol in at-least at-most nearest; do
        "$BIN" -c sizer -d "$channels" -e "2026-09-01 12:00:10" --users 3 --users-policy "$pol" >"$tmpdir/my"
        python3 "$PY" -c sizer -d "$channels" -e "2026-09-01 12:00:10" --users 3 --users-policy "$pol" --no-config --no-cache >"$tmpdir/py"
        py_u=$(sed -n 's/.*users: *\([0-9,]*\) asked for, \([0-9,]*\) found over \([^ ]*\).*/\1 \2 \3/p' "$tmpdir/py" | tr -d ',' | tail -1)
        my_u=$(sed -n 's/^window .*width=\([0-9]*\) found=\([0-9]*\) req=\([0-9]*\).*/\1 \2 \3/p' "$tmpdir/my")
        py_req=$(printf '%s\n' "$py_u" | awk '{print $1}')
        py_found=$(printf '%s\n' "$py_u" | awk '{print $2}')
        py_dur=$(printf '%s\n' "$py_u" | awk '{print $3}')
        my_req=$(printf '%s\n' "$my_u" | awk '{print $3}')
        my_found=$(printf '%s\n' "$my_u" | awk '{print $2}')
        # python's duration is human_duration(width); re-derive seconds
        py_width=$(python3 - "$py_dur" << 'PYEOF'
import sys
s = sys.argv[1]
total = 0; n = ""
for ch in s:
    if ch.isdigit():
        n += ch
    else:
        total += int(n) * {"d":86400,"h":3600,"m":60,"s":1}[ch]
        n = ""
print(total)
PYEOF
)
        my_width=$(printf '%s\n' "$my_u" | awk '{print $1}')
        ok=0
        [ "$py_req" = "$my_req" ] && [ "$py_found" = "$my_found" ] && \
        [ "$py_width" = "$my_width" ] && ok=1
        [ "$ok" -eq 0 ] && echo "  detail: py='$py_u'($py_width) my='$my_u'"
        ok_or_fail "diff: --users $pol sizing" "$ok"
    done

# --- Summary ----------------------------------------------------------------
echo
echo "Summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]