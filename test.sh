#!/bin/sh
# test.sh — verify the AArch64 Fibonacci program.
#
# Checks:
#   1. ./fibonacci 10   prints exactly 0..34 (10 terms, one per line)
#   2. ./fibonacci      (no args) prints the same 10 terms
#   3. ./fibonacci 100  prints 93 terms (F(0)..F(92)), then an overflow
#                        note on stderr, exit code 0
#   4. ./fibonacci abc  prints usage on stderr, exit code 1
#
# Prints PASS/FAIL per check and exits nonzero on any failure.
set -u

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fibonacci-test.XXXXXX") || {
    echo "FAIL: cannot create temp directory"
    exit 2
}
trap 'rm -rf "$tmpdir"' EXIT INT TERM

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

expected_10='0
1
1
2
3
5
8
13
21
34'

# --- Check 1: explicit N=10 -------------------------------------------------
actual=$(./fibonacci 10 2>"$tmpdir/err1")
rc=$?
ok=0
[ "$rc" -eq 0 ] && [ "$actual" = "$expected_10" ] && [ ! -s "$tmpdir/err1" ] && ok=1
ok_or_fail "./fibonacci 10 prints 0 1 1 2 3 5 8 13 21 34" "$ok"

# --- Check 2: default N=10 (no arguments) -----------------------------------
actual=$(./fibonacci 2>"$tmpdir/err2")
rc=$?
ok=0
[ "$rc" -eq 0 ] && [ "$actual" = "$expected_10" ] && [ ! -s "$tmpdir/err2" ] && ok=1
ok_or_fail "./fibonacci (no args) prints the same 10 terms" "$ok"

# --- Check 3: N=100 -> 93 terms then overflow note, exit 0 ------------------
./fibonacci 100 >"$tmpdir/out3" 2>"$tmpdir/err3"
rc=$?
lines=$(wc -l <"$tmpdir/out3")
first=$(sed -n '1p' "$tmpdir/out3")
last=$(sed -n '93p' "$tmpdir/out3")
err3=$(cat "$tmpdir/err3")
ok=0
[ "$rc" -eq 0 ] && \
[ "$lines" -eq 93 ] && \
[ "$first" = "0" ] && \
[ "$last" = "7540113804746346429" ] && \
case "$err3" in
    *"fibonacci: overflow at index 93 (exceeds 64-bit)"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc lines=$lines first=$first last=$last stderr=$err3"
ok_or_fail "./fibonacci 100 prints 93 terms + overflow note, exit 0" "$ok"

# --- Check 4: invalid input -> usage on stderr, exit 1 ----------------------
./fibonacci abc >"$tmpdir/out4" 2>"$tmpdir/err4"
rc=$?
err4=$(cat "$tmpdir/err4")
ok=0
[ "$rc" -eq 1 ] && \
[ ! -s "$tmpdir/out4" ] && \
case "$err4" in
    *"usage: fibonacci [N]"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stdout=$(cat "$tmpdir/out4") stderr=$err4"
ok_or_fail "./fibonacci abc prints usage to stderr, exit 1" "$ok"

# --- Summary ----------------------------------------------------------------
echo
echo "Summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]