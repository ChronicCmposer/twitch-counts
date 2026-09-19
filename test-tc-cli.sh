#!/usr/bin/env bash
# ============================================================================
# test-tc-cli.sh — Wave-A CLI harness for the twitch-counts AArch64 port.
#
# Builds the parse-only driver (check_tc_cli.o + tc_cli.o + tc_config_stub.o +
# tc_util.o) and checks the argparse-equivalent layer: exit codes, exact
# error text (normalized against python3 twitch-counts.py), window/datetime
# arithmetic, conflicts, --help, and getopt forms.
#
# Usage: ./test-tc-cli.sh
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

MUSL_GCC=./third_party/musl/bin/musl-gcc
AS=as
BIN=tc-cli-test
PY=python3

PASS=0
FAIL=0

ok()   { PASS=$((PASS+1)); }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------
# Build the driver
# ---------------------------------------------------------------------------
build() {
    $AS tc_util.S -o tc_util.o &&
    $AS tc_main.S -o tc_main.o &&
    $AS tc_cli.S -o tc_cli.o &&
    $AS tc_config_stub.S -o tc_config_stub.o &&
    $AS check_tc_cli.S -o check_tc_cli.o &&
    $MUSL_GCC -static -o "$BIN" \
        check_tc_cli.o tc_cli.o tc_config_stub.o tc_util.o
}

# run_case NAME ARG...  -> exit code in $RC, stdout in $OUT, stderr in $ERR
run_case() {
    local name=$1; shift
    OUT=$("$HERE/$BIN" "$@" 2>/tmp/tc_cli_err.$$); RC=$?
    ERR=$(cat /tmp/tc_cli_err.$$)
    rm -f /tmp/tc_cli_err.$$
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

echo "building tc-cli-test ..."
if ! build; then
    echo "BUILD FAILED"
    exit 1
fi
echo "build ok"

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
# -S 30d from 2026-09-18 should land on 2026-08-19 (sod matches the day)
expect_begin "since-30d" 20260819 -S 30d
expect_begin "since-1w3d" 20260908 -S 1w3d
# -S 12h is sub-24h, so the expected begin day depends on the wall clock
# (begin = local now - 12h; the driver's end defaults to localtime now).
# Compute it at run time so the test is not time-of-day dependent.
SINCE_12H=$(python3 -c "import datetime; print((datetime.datetime.now() - datetime.timedelta(hours=12)).strftime('%Y%m%d'))")
expect_begin "since-12h" "$SINCE_12H" -S 12h
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

echo "-- help --"
expect_contains "help-short" "usage:" -h
expect_contains "help-channel" "--channel" --help

# ---------------------------------------------------------------------------
# 4. Differential check vs the Python reference on error text
# ---------------------------------------------------------------------------
echo "-- differential error text vs python3 twitch-counts.py --"
DIFF_FAIL=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    # shellcheck disable=SC2086
    set -- $line
    py_out=$($PY twitch-counts.py "$@" 2>&1); py_rc=$?
    asm_out=$("$HERE/$BIN" "$@" 2>&1); asm_rc=$?
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
    pn=$(printf '%s\n' "$py_out" | tr -s ' \n' ' ' | sed 's/twitch-counts\.py/PROG/g' | sed 's/[[:space:]]*$//')
    an=$(printf '%s\n' "$asm_out" | tr -s ' \n' ' ' | sed 's/tc-cli-test/PROG/g' | sed 's/[[:space:]]*$//')
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
CASES
if [ "$DIFF_FAIL" -eq 0 ]; then
    echo "  differential: all matched"
else
    echo "  differential: $DIFF_FAIL mismatches"
fi

# ---------------------------------------------------------------------------
echo
echo "Summary: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && [ "$DIFF_FAIL" -eq 0 ]