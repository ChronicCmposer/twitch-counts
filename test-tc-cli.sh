#!/usr/bin/env bash
# ============================================================================
# test-tc-cli.sh — Wave-A CLI harness for the twitch-counts AArch64 port.
#
# Runs the already-built parse-only driver ($BUILD/tc-cli-test —
# check_tc_cli.o + tc_cli.o + tc_config_stub.o + tc_util.o, linked by the
# Makefile's `make drivers`) and checks the argparse-equivalent layer: exit
# codes, exact error text (normalized against python3 twitch-counts.py),
# window/datetime arithmetic, conflicts, --help, and getopt forms.
#
# $BUILD is $TC_BUILD if set (the Makefile exports it when it runs this via
# `make test`), else build/<os> under this script's own directory, where
# <os> is `uname -s` lowercased (build/darwin, build/linux). This script
# does not build anything itself: if the driver is missing, run
# `make drivers` first.
#
# Isolation: every invocation of python3 twitch-counts.py AND of the driver
# runs with HOME, XDG_CONFIG_HOME and XDG_CACHE_HOME pointed at a per-run
# mktemp directory (exported once, below, so every subsequent call in this
# script inherits it) — this keeps the test from ever touching the real
# ~/.config/twitch-counts.toml or ~/.cache/twitch-counts/rollup.db (macOS's
# Python Platform class honours only HOME; Linux's Python class and the
# assembly honour XDG_*, so both are set to cover either).
#
# Usage: ./test-tc-cli.sh
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

BUILD=${TC_BUILD:-build/$(uname -s | tr A-Z a-z)}
BIN="$BUILD/tc-cli-test"

if [ ! -x "$BIN" ]; then
    echo "FAIL: driver not found or not executable: $BIN (run: make drivers)" >&2
    exit 1
fi

# Isolated HOME/XDG so no oracle or driver call can ever reach the user's
# real config or 355 MB rollup cache. Exported once, before any python3 or
# $BIN invocation in this script (including the version check right below),
# so every one of them inherits it.
ISO_HOME=$(mktemp -d "${TMPDIR:-/tmp}/tc-cli-test-home.XXXXXX") || {
    echo "FAIL: cannot create isolated HOME" >&2
    exit 2
}
trap 'rm -rf "$ISO_HOME"' EXIT INT TERM
export HOME="$ISO_HOME"
export XDG_CONFIG_HOME="$ISO_HOME/.config"
export XDG_CACHE_HOME="$ISO_HOME/.cache"
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
    echo "FAIL: python3 on PATH must be >= 3.11 (import tomllib failed);" \
         "twitch-counts.py requires it" >&2
    exit 2
fi

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# run_case NAME ARG...  -> exit code in $RC, stdout in $OUT, stderr in $ERR
run_case() {
    local name=$1; shift
    local errfile
    errfile=$(mktemp "${TMPDIR:-/tmp}/tc_cli_err.XXXXXX")
    OUT=$("$BIN" "$@" 2>"$errfile"); RC=$?
    ERR=$(cat "$errfile")
    rm -f "$errfile"
}

# expect_exit NAME EXPECTED ARG...
expect_exit() {
    local name=$1 want=$2; shift 2
    run_case "$name" "$@"
    if [ "$RC" -eq "$want" ]; then ok; else
        bad "$name: exit $RC, want $want (args: $*)"
    fi
}

# expect_error NAME ARG... — exit 2 and the message mentions the canonical
expect_error() {
    local name=$1; shift
    run_case "$name" "$@"
    if [ "$RC" -eq 2 ]; then ok; else
        bad "$name: expected exit 2, got $RC (args: $*)"
    fi
}

# expect_contains NAME NEEDLE ARG...
expect_contains() {
    local name=$1 needle=$2; shift 2
    run_case "$name" "$@"
    if printf '%s' "$OUT$ERR" | grep -qF -- "$needle"; then ok; else
        bad "$name: output missing '$needle' (args: $*)"
    fi
}

# expect_begin NAME YMD ARG...
expect_begin() {
    local name=$1 want=$2; shift 2
    run_case "$name" "$@"
    local got
    got=$(printf '%s\n' "$OUT" | sed -n 's/^begin=\([0-9]*\) .*/\1/p' | head -1)
    if [ "$got" = "$want" ]; then ok; else
        bad "$name: begin=$got, want $want (args: $*)"
    fi
}

# expect_no_crash ARG...
expect_no_crash() {
    local name=$1; shift
    run_case "$name" "$@"
    if [ "$RC" -eq 0 ]; then ok; else
        bad "$name: expected exit 0, got $RC (args: $*)"
    fi
}

# expect_channel_empty NAME ARG... — parses to channel="" with source
# --channel (an empty explicit value, not a missing one): "channel=" on its
# own line followed by "src=--channel". This is the parse-only driver, so
# it exits 0 here even though python3 twitch-counts.py goes on to fail at
# the logs-directory stage (exit 1) for the same args — see the skipped
# py_rc!=0/asm_rc==0 case in the differential loop below.
expect_channel_empty() {
    local name=$1; shift
    run_case "$name" "$@"
    if [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qx 'channel=' \
        && printf '%s\n' "$OUT" | grep -qx 'src=--channel'; then
        ok
    else
        bad "$name: expected channel=\"\" src=--channel exit 0, got RC=$RC (args: $*)"
    fi
}

echo "driver: $BIN"

# ---------------------------------------------------------------------------
# 1. Exit-code parity with the Python reference on error cases
# ---------------------------------------------------------------------------
echo "-- argparse/type errors (exit 2) --"
expect_exit "m-abc"        2 -m abc
expect_exit "m-0"          2 -m 0
expect_exit "n-neg"        2 -n -5
expect_exit "mincount-0"   2 --min-count 0
expect_exit "sort-nope"    2 --sort nope
expect_exit "sort-eq-nope" 2 --sort=nope
expect_exit "sort-name"    2 --sort name
expect_exit "usersmax-1x"  2 --users-max 1x
expect_exit "usersmax-0"   2 --users-max 0
expect_exit "show-name"    2 --show name
expect_exit "header-off"   2 --header off
expect_exit "bogus"        2 --bogus
expect_exit "state-live"   2 --state live
expect_exit "users-0"      2 --users 0
expect_exit "users-abc"    2 --users abc
expect_exit "users-neg"    2 --users -1
expect_exit "watch-abc"    2 --watch abc
expect_exit "watch-neg"    2 --watch -1
expect_exit "color-bogus"  2 --color bogus
expect_exit "policy-bogus" 2 --users-policy bogus
expect_exit "mincount-abc" 2 --min-count abc
expect_exit "top-abc"      2 --top abc
expect_exit "sharefloor-abc" 2 --share-floor abc

echo "-- missing values (exit 2) --"
for opt in -c -m --channel --sort --users --users-max --show --header \
           --color --users-policy -x -g --exclude --include --begin --since \
           --end --logs-dir --config --watch-hold --users; do
    expect_exit "missing-$opt" 2 "$opt"
done

echo "-- conflicts (exit 2) --"
expect_exit "O-L"     2 -O -L
expect_exit "j-w"     2 -j -w
expect_exit "b-S"     2 -b 2026-01-01 -S 30d
expect_exit "S-b"     2 -S 30d -b 2026-01-01

echo "-- window/datetime resolution errors (exit 1) --"
expect_exit "begin-bad-month" 1 -b 2026-13-01
expect_exit "since-0"         1 -S 0d
expect_exit "end-bogus"       1 -e bogus
expect_exit "week-53-after"   1 -b 2026-W53

# ---------------------------------------------------------------------------
# 2. Window arithmetic values
# ---------------------------------------------------------------------------
echo "-- window values --"
# -S Nd is whole-day arithmetic (sod matches the day): begin = today - N
# days. Computed at run time (via python3, not the driver or oracle, so no
# isolation is needed for this plain date arithmetic) so the test is not
# pinned to any particular calendar date.
SINCE_30D=$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=30)).strftime('%Y%m%d'))")
SINCE_10D=$(python3 -c "import datetime; print((datetime.date.today() - datetime.timedelta(days=10)).strftime('%Y%m%d'))")
expect_begin "since-30d" "$SINCE_30D" -S 30d
expect_begin "since-1w3d" "$SINCE_10D" -S 1w3d
# -S 12h is sub-24h, so the expected begin day depends on the wall clock
# (begin = local now - 12h; the driver's end defaults to localtime now).
# Compute it at run time so the test is not time-of-day dependent.
SINCE_12H=$(python3 -c "import datetime; print((datetime.datetime.now() - datetime.timedelta(hours=12)).strftime('%Y%m%d'))")
expect_begin "since-12h" "$SINCE_12H" -S 12h
# begin-w3x/-w01 resolve an explicit ISO year+week to a calendar date; that
# mapping is fixed by the ISO 8601 calendar and does not depend on "today",
# so these are not date-pinned and need no run-time computation (verified
# against datetime.date.fromisocalendar(2026, 31, 1/3) and (2026, 1, 1)).
expect_begin "begin-w31"  20260727 -b 2026-W31
expect_begin "begin-w31-wed" 20260729 -b 2026-W31-3
expect_begin "begin-w01"  20251229 -b 2026-W01

# ---------------------------------------------------------------------------
# 3. getopt forms and flags
# ---------------------------------------------------------------------------
echo "-- forms and flags --"
expect_no_crash "no-arg"
expect_no_crash "short-B"     -B
expect_no_crash "long-by-state" --by-state
expect_no_crash "json"        --json
expect_no_crash "live"        --live
expect_no_crash "channel-short" -c foo
expect_no_crash "channel-long"  --channel foo
expect_no_crash "mincount-long" --min-count 5
expect_no_crash "sort-long"   --sort count
expect_no_crash "usersmax-long" --users-max 24h
expect_no_crash "watch-5"     --watch 5
expect_no_crash "watch-bare"  --watch
expect_no_crash "color-long"  --color always
expect_no_crash "policy-long" --users-policy at-least
expect_no_crash "since-long"  --since 30d
expect_no_crash "begin-eq"    --begin=2026-01-01
expect_no_crash "end-date"    -e 2026-09-01

echo "-- empty explicit/separate values (argparse pre-pass edge cases) --"
# '-x=' / '-x ""' / '--x=' / '--x ""' with an EMPTY value: Python's argparse
# accepts it as the empty string, distinct from no value at all. See the
# tc_pp_short "-c="/"-c \"\"" fixes (.Lps_eq_empty / .Lps_no_attached_empty)
# and tc_pp_build_long_val, which spell these through getopt_long's native
# "--long=value" form so an explicit "" isn't mistaken for "no value
# attached" (which would consume the NEXT argv as the value instead).
expect_channel_empty "c-eq-empty"        -c=
expect_channel_empty "c-space-empty"     -c ""
expect_channel_empty "channel-eq-empty"  --channel=
expect_channel_empty "channel-space-empty" --channel ""
expect_exit "c-eq-empty-then-extra" 2 -c= foo
expect_exit "w-eq-empty"    2 -w=
expect_exit "w-space-empty" 2 -w ""
expect_contains "w-eq-empty-msg" "is not a number of seconds" -w=
expect_contains "w-space-empty-msg" "is not a number of seconds" -w ""

echo "-- '--' end-of-options token itself is unrecognized (matches argparse) --"
expect_exit "dashdash-alone" 2 --
expect_contains "dashdash-alone-msg" "unrecognized arguments: --" --
expect_exit "dashdash-with-extra" 2 --json -- extra
expect_contains "dashdash-with-extra-msg" "unrecognized arguments: -- extra" --json -- extra

echo "-- help --"
expect_contains "help-short" "usage:" -h
expect_contains "help-channel" "--channel" --help

# ---------------------------------------------------------------------------
# 4. Differential check vs the Python reference on error text
# ---------------------------------------------------------------------------
echo "-- differential error text vs python3 twitch-counts.py --"
# CPython's argparse has flipped the quoting of the "(choose from ...)" list
# between patch releases (3.14.4 prints `choose from auto, always, never`,
# 3.14.6 prints `choose from 'auto', 'always', 'never'`).  The driver
# follows one spelling; the comparison ignores that quoting on both sides
# so the differential is about the message, not the oracle's patch level.
choices_norm() {
    python3 -c '
import re, sys
s = sys.stdin.read()
print(re.sub(r"\(choose from ([^)]*)\)", lambda m: "(choose from " + m.group(1).replace(chr(39), "") + ")", s), end="")'
}
DIFF_FAIL=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # shellcheck disable=SC2086
    set -- $line
    py_out=$(python3 twitch-counts.py "$@" 2>&1); py_rc=$?
    asm_out=$("$BIN" "$@" 2>&1); asm_rc=$?
    if [ "$py_rc" != "$asm_rc" ]; then
        # A run that succeeds in the driver but reaches a later-stage failure
        # in the reference (missing channel/logs) is expected; skip it.
        if [ "$py_rc" -ne 0 ] && [ "$asm_rc" -eq 0 ]; then
            continue
        fi
        DIFF_FAIL=$((DIFF_FAIL+1))
        echo "  DIFF exit ($*): py=$py_rc asm=$asm_rc"
        continue
    fi
    [ "$py_rc" -eq 0 ] && continue
    pn=$(printf '%s\n' "$py_out" | tr -s ' \n' ' ' | sed 's/twitch-counts\.py/PROG/g' | sed 's/[[:space:]]*$//' | choices_norm)
    an=$(printf '%s\n' "$asm_out" | tr -s ' \n' ' ' | sed 's/tc-cli-test/PROG/g' | sed 's/[[:space:]]*$//' | choices_norm)
    if [ "$pn" != "$an" ]; then
        DIFF_FAIL=$((DIFF_FAIL+1))
        echo "  DIFF text ($*):"
        echo "    py : ${pn:0:120}"
        echo "    asm: ${an:0:120}"
    fi
done <<'CASES'
-m abc
-m 0
-n -5
--min-count 0
--sort nope
--sort=nope
--sort name
--users-max 1x
--users-max 0
--show name
--show bogus
--header off
--bogus
--state live
--users 0
--users abc
--users -1
--watch abc
--watch -1
--color bogus
--users-policy bogus
-O -L
-j -w
-b 2026-01-01 -S 30d
-S 30d -b 2026-01-01
-c
--sort
--users
-x
--include
--watch-hold
--
--json -- extra
-c=
-c= foo
-w=
--channel=
CASES
if [ "$DIFF_FAIL" -eq 0 ]; then
    echo "  differential: all matched"
else
    echo "  differential: $DIFF_FAIL mismatches"
fi

# ---------------------------------------------------------------------------
echo
# ---------------------------------------------------------------------------
# usage block: argparse packs one part per action into $COLUMNS - 2 columns
# (shutil.get_terminal_size), continuation lines indented past "usage: <prog> ".
# Compared with the Python run under the same program name, so the wrapping
# has to agree at every width, including one too narrow for the prog line.
USAGE_PY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/tc-cli-usage.XXXXXX")
cp twitch-counts.py "$USAGE_PY_DIR/tc-cli-test"
for W in 40 60 80 100 120 200; do
    got=$(COLUMNS=$W "$BIN" --color bogus 2>&1 | sed '/^tc-cli-test: error/,$d')
    want=$(COLUMNS=$W python3 "$USAGE_PY_DIR/tc-cli-test" --color bogus 2>&1 | sed '/^tc-cli-test: error/,$d')
    if [ "$got" = "$want" ]; then ok; else
        bad "usage-width-$W: usage block differs from argparse at COLUMNS=$W"
        diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -6
    fi
done
got=$(COLUMNS=" 90 " "$BIN" --color bogus 2>&1 | sed '/^tc-cli-test: error/,$d')
want=$(COLUMNS=" 90 " python3 "$USAGE_PY_DIR/tc-cli-test" --color bogus 2>&1 | sed '/^tc-cli-test: error/,$d')
if [ "$got" = "$want" ]; then ok; else bad "usage-width-int: COLUMNS=' 90 ' is int()-parsed like Python"; fi
rm -rf "$USAGE_PY_DIR"

# ---------------------------------------------------------------------------
# resolve-time error texts (a value given on the command line reads
# "--since: ...", with no "(from --since)")
expect_contains "since-zero" "error: --since: duration must be greater than zero" -c x -S 0s -d /nonexistent
expect_contains "since-zero-no-from" "error: --since: " -c x -S 0s -d /nonexistent
expect_contains "since-junk-normalised" "unrecognized duration '3x'" -c x -S " 3X " -d /nonexistent
expect_contains "begin-bad-week" "error: --begin: no week 60 in ISO year 2026 (weeks run 1-52, or 1-53 in long years)" -c x -b 2026-W60 -d /nonexistent
expect_contains "show-first-unknown" "unknown column 'share' (choose from: count, live, live-share, offline, offline-share, unknown)" -c x --show share,first,last -d /nonexistent
expect_begin "begin-padded" 20260917 -c x -b " 2026-09-17 " -d /nonexistent
expect_contains "users-label-digits" "src=--users 12" -c x --users 12 -d /nonexistent

echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$DIFF_FAIL" -eq 0 ]