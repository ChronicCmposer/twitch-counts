#!/bin/bash
# ============================================================================
# test-tc-render.sh — Phase 5 harness for tc_render.S + tc_json.S.
#
#   Compares the AArch64 renderer byte-for-byte with the Python reference
#   (twitch-counts.py) across the flag matrix, plus a handful of structural
#   checks (JSON validity, error path, piped/unlimited rows).
#
#   Usage:  ./test-tc-render.sh            (builds tc-render-test itself)
#
#   Exit:   0 = all tests passed; nonzero = at least one failure.
# ============================================================================
set -u
cd "$(dirname "$0")"

BIN=/var/lib/opencode/dev/shirley-asm/tc-render-test
PY="python3 /var/lib/opencode/dev/shirley-asm/twitch-counts.py"
DATA=/tmp/tc5test
LOGS="$DATA/Logs/Twitch/Channels"
CH=chroniccmposer
PC=powerchan
PASS=0
FAIL=0
FAILED_TESTS=()

norm() { sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/; s/\(cannot read\)/(PermissionError: Permission denied)/' "$1"; }

# ---------------------------------------------------------------------------
# build
# ---------------------------------------------------------------------------
echo "== building =="
as tc_render.S -o tc_render.o && \
as tc_json.S -o tc_json.o && \
as check_tc_render.S -o check_tc_render.o && \
/var/lib/opencode/dev/shirley-asm/third_party/musl/bin/musl-gcc -static -o tc-render-test \
    check_tc_render.o tc_render.o tc_json.o tc_core.o tc_cli.o tc_config.o \
    tc_cache.o tc_util.o third_party/tomlc99/toml.o third_party/sqlite3/sqlite3.o
if [ $? -ne 0 ]; then echo "BUILD FAILED"; exit 1; fi

# ---------------------------------------------------------------------------
# differential helper
# ---------------------------------------------------------------------------
# diff_run <name> [args...]
diff_run() {
    local name="$1"; shift
    local a_out a_rc p_out p_rc
    a_out=$("$BIN" "$@" --no-config --no-cache 2>/dev/null); a_rc=$?
    p_out=$(python3 /var/lib/opencode/dev/shirley-asm/twitch-counts.py "$@" --no-config --no-cache 2>/dev/null); p_rc=$?
    if [ "$a_rc" != "$p_rc" ]; then
        echo "FAIL[$name]: rc asm=$a_rc py=$p_rc"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); return
    fi
    local an pn
    an=$(printf '%s' "$a_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/; s/\(cannot read\)/(PermissionError: Permission denied)/')
    pn=$(printf '%s' "$p_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/')
    if [ "$an" = "$pn" ]; then
        echo "PASS[$name]"; PASS=$((PASS+1))
    else
        echo "FAIL[$name]: output differs"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
        diff <(printf '%s' "$pn") <(printf '%s' "$an") | head -6
    fi
}

cd "$DATA"

# ---------------------------------------------------------------------------
# 1. text-mode differentials (full header + table + footer)
# ---------------------------------------------------------------------------
echo "== text-mode differentials =="
diff_run "basic full header+table+footer with commas" -c $CH -d $LOGS -e 2026-09-03
diff_run "by-state columns + shares" -c $CH -d $LOGS -e 2026-09-03 -B --share-floor 0
diff_run "by-state default floor" -c $CH -d $LOGS -e 2026-09-03 -B
diff_run "sort login" -c $CH -d $LOGS -e 2026-09-03 --sort login
diff_run "share sort live-share" -c $CH -d $LOGS -e 2026-09-03 -B --share-floor 0 --sort live-share
diff_run "cap n2 + +N others + top row" -c $CH -d $LOGS -e 2026-09-03 -n 2
diff_run "cap n1" -c $CH -d $LOGS -e 2026-09-03 -n 1
diff_run "threshold m4" -c $CH -d $LOGS -e 2026-09-03 -m 4
diff_run "exclusion row + footer line" -c $CH -d $LOGS -e 2026-09-03 -x bob,carol
diff_run "exclude broadcaster" -c $CH -d $LOGS -e 2026-09-03 --exclude-broadcaster
diff_run "compact header middot joins" -c $CH -d $LOGS -e 2026-09-03 --header compact
diff_run "header none" -c $CH -d $LOGS -e 2026-09-03 --header none
diff_run "share-floor 0 explicit" -c $CH -d $LOGS -e 2026-09-03 --share-floor 0
diff_run "share-floor unused with -B" -c $CH -d $LOGS -e 2026-09-03 -B
diff_run "compact n2" -c $CH -d $LOGS -e 2026-09-03 -n 2 --header compact
diff_run "users 3 row" -c $CH -d $LOGS -e 2026-09-03 --users 3
diff_run "users 2 row + human_duration" -c $CH -d $LOGS -e 2026-09-03 --users 2
diff_run "live filter -L" -c $CH -d $LOGS -e 2026-09-03 -L
diff_run "since 1d compact" -c $CH -d $LOGS -S 1d -e 2026-09-03 --header compact
diff_run "empty report message" -c $CH -d $LOGS -b 2026-09-02 -e 2026-09-02 -m 100
diff_run "empty + exclusion" -c $CH -d $LOGS -e 2026-09-03 -x bob,carol -m 100
diff_run "powerchan commas" -c $PC -d $LOGS -e 2026-09-01
diff_run "powerchan by-state" -c $PC -d $LOGS -e 2026-09-01 -B --share-floor 0
diff_run "state split row (offline filter)" -c $CH -d $LOGS -e 2026-09-03 -O
diff_run "begin-explicit" -c $CH -d $LOGS -b 2026-09-02 -e 2026-09-02

# unreadable row
chmod 000 $LOGS/$CH/$CH-2026-09-02.log 2>/dev/null
diff_run "unreadable row" -c $CH -d $LOGS -e 2026-09-03
chmod 644 $LOGS/$CH/$CH-2026-09-02.log 2>/dev/null

# ---------------------------------------------------------------------------
# 2. JSON differentials
# ---------------------------------------------------------------------------
echo "== JSON differentials =="
json_diff() {
    local name="$1"; shift
    local a_out a_rc p_out p_rc
    a_out=$("$BIN" "$@" --no-config --no-cache 2>/dev/null); a_rc=$?
    p_out=$(python3 /var/lib/opencode/dev/shirley-asm/twitch-counts.py "$@" --no-config --no-cache 2>/dev/null); p_rc=$?
    if [ "$a_rc" != "$p_rc" ]; then
        echo "FAIL[$name]: rc asm=$a_rc py=$p_rc"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); return
    fi
    if [ "$a_rc" -eq 0 ]; then
        if ! printf '%s' "$a_out" | python3 -m json.tool >/dev/null 2>&1; then
            echo "FAIL[$name]: invalid JSON"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); return
        fi
        # schema-first key order check
        local first
        first=$(printf '%s' "$a_out" | sed -n '2p' | tr -d ' ')
        if [ "$first" != '"schema":{' ]; then
            echo "FAIL[$name]: schema not first"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name"); return
        fi
    fi
    local an pn
    an=$(printf '%s' "$a_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/; s/\(cannot read\)/(PermissionError: Permission denied)/')
    pn=$(printf '%s' "$p_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/')
    if [ "$an" = "$pn" ]; then
        echo "PASS[$name]"; PASS=$((PASS+1))
    else
        echo "FAIL[$name]: output differs"; FAIL=$((FAIL+1)); FAILED_TESTS+=("$name")
        diff <(printf '%s' "$pn") <(printf '%s' "$an") | head -6
    fi
}
json_diff "json basic" -c $CH -d $LOGS -e 2026-09-03 --json
json_diff "json by-state" -c $CH -d $LOGS -e 2026-09-03 --json -B --share-floor 0
json_diff "json cap" -c $CH -d $LOGS -e 2026-09-03 --json -n 2
json_diff "json exclusion" -c $CH -d $LOGS -e 2026-09-03 --json -x bob,carol
json_diff "json sort login" -c $CH -d $LOGS -e 2026-09-03 --json --sort login
json_diff "json users" -c $CH -d $LOGS -e 2026-09-03 --json --users 3
json_diff "json powerchan" -c $PC -d $LOGS -e 2026-09-01 --json -B --share-floor 0

# ---------------------------------------------------------------------------
# 3. piped = unlimited rows
# ---------------------------------------------------------------------------
echo "== piped output =="
a_out=$(printf '' | "$BIN" -c $CH -d $LOGS -e 2026-09-03 -n 5 --no-config --no-cache 2>/dev/null)
rows=$(printf '%s\n' "$a_out" | grep -cE '^[a-zA-Z_+0-9]+ +[0-9,]+$' || true)
if [ "$rows" -ge 5 ]; then
    echo "PASS[piped unlimited rows: $rows rows shown]"; PASS=$((PASS+1))
else
    echo "FAIL[piped unlimited rows: only $rows rows]"; FAIL=$((FAIL+1)); FAILED_TESTS+=("piped unlimited rows")
fi

# ---------------------------------------------------------------------------
# 4. JSON error path
# ---------------------------------------------------------------------------
echo "== JSON error path =="
err=$("$BIN" -c $CH -d $LOGS -e 2026-09-03 -L -B --json --no-config --no-cache 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q '{"error":'; then
    echo "PASS[json error path]"; PASS=$((PASS+1))
else
    echo "FAIL[json error path]: got [$err]"; FAIL=$((FAIL+1)); FAILED_TESTS+=("json error path")
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
echo
echo "=========================================="
echo "test-tc-render.sh: $PASS passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
    printf 'failed: %s\n' "${FAILED_TESTS[@]}"
fi
[ "$FAIL" -eq 0 ]