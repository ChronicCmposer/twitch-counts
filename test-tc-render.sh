#!/bin/bash
# ============================================================================
# test-tc-render.sh — harness for tc_render.S + tc_json.S.
#
#   Compares the AArch64 renderer byte-for-byte against the Python reference
#   (twitch-counts.py) across the flag matrix, plus a handful of structural
#   checks (JSON validity, error path, piped/unlimited rows).
#
#   Driver:    $BUILD/tc-render-test, resolved via the shared tc-test-lib.sh
#              (override with TC_BUILD=...).  Build it first with
#              `make drivers`; this script performs no builds of its own.
#   Oracle:    `python3 twitch-counts.py` from PATH.  Checked once at the top
#              to be >= 3.11 (i.e. it has the stdlib `tomllib` module) before
#              anything else runs.
#   Fixtures:  a synthetic chroniccmposer + powerchan Chatterino log tree
#              (the same content test-twitch-counts.sh builds) is generated
#              fresh under a mktemp directory at the start of every run, so
#              the differentials below always have real data to compare
#              instead of silently agreeing on empty output.  A dedicated
#              "fixture sanity" check fails loudly if that ever stops being
#              true.
#   Isolation: HOME, XDG_CONFIG_HOME and XDG_CACHE_HOME are exported once, to
#              paths under that same mktemp directory, before ANY python3 or
#              driver invocation runs — so neither the oracle (which follows
#              HOME on macOS) nor the driver (which honours XDG) can ever
#              touch the user's real ~/.config/twitch-counts.toml or
#              ~/.cache/twitch-counts/rollup.db.
#
#   Usage:  ./test-tc-render.sh
#           TC_BUILD=build/darwin ./test-tc-render.sh
#
#   Exit:   0 = all tests passed; 1 = at least one test failed; 2 = a setup
#           problem (missing driver, missing/too-old python3, ...).
# ============================================================================
set -u
. "$(dirname "$0")/tc-test-lib.sh"
tc_here

# ---------------------------------------------------------------------------
# driver + oracle resolution (no builds happen here — see `make drivers`)
# ---------------------------------------------------------------------------
tc_build_dir
BIN=$(tc_driver tc-render-test) || exit 2
PYSCRIPT="$TC_HERE/twitch-counts.py"
if [ ! -f "$PYSCRIPT" ]; then
    echo "FAIL: oracle script not found: $PYSCRIPT"
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "FAIL: python3 not found on PATH"
    exit 2
fi

# ---------------------------------------------------------------------------
# isolation: exported once, before any oracle/driver call — never touch the
# user's real HOME / config / cache.
# ---------------------------------------------------------------------------
WORKDIR=$(tc_sandbox tc-render-test)

DATA="$WORKDIR/data"
tc_isolate_home "$WORKDIR"
mkdir -p "$DATA"
tc_require_python_tomllib          # the first python3 call runs isolated

LOGS="$DATA/Logs/Twitch/Channels"
CH=chroniccmposer
PC=powerchan
SAW_NONEMPTY_TABLE=0

# ---------------------------------------------------------------------------
# fixtures: synthetic chroniccmposer + powerchan log tree — the same content
# test-twitch-counts.sh builds (copied here, not imported, so this harness
# has no dependency on that script).
# ---------------------------------------------------------------------------
echo "== building fixtures =="
mkdir -p "$LOGS/$CH" "$LOGS/$PC"

cd "$LOGS/$CH" || exit 2

# 08-31: a previous-day file whose marker seeds 09-01.
cat > "$CH-2026-08-31.log" << 'EOF'
[15:15:30] ChronicCmposer is live!
EOF

# 09-01: an early pre-marker message (seeded live), a live block, a localized
# display name, a system line and a comment that must all be ignored or
# mapped.
cat > "$CH-2026-09-01.log" << 'EOF'
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

cat > "$CH-2026-09-02.log" << 'EOF'
[15:10:00] ChronicCmposer is live!
[15:10:05] alice: day two
[15:11:00] bob: second day
[15:12:00] alice: more
[15:13:00] dave: newcomer
[15:14:00] ChronicCmposer is now offline.
EOF

cat > "$CH-2026-09-03.log" << 'EOF'
[16:00:00] ChronicCmposer is live!
[16:00:01] alice: third day
[16:00:02] bob: third day too
[16:00:03] alice: more more
[16:01:00] ChronicCmposer is now offline.
EOF

# a per-stream log that must be ignored by the dated-file matcher
cat > "$CH-12345.log" << 'EOF'
[15:00:00] ChronicCmposer is live!
EOF

# powerchan: a 1,234-message user for comma formatting
cd "$LOGS/$PC" || exit 2
cat > "$PC-2026-09-01.log" << 'EOF'
[10:00:00] powerchan is live!
EOF
i=0
while [ "$i" -lt 1234 ]; do
    printf '[10:00:01] power_user: msg %s\n' "$i" >> "$PC-2026-09-01.log"
    i=$((i + 1))
done

cd "$DATA" || exit 2

# ---------------------------------------------------------------------------
# differential helper (text mode)
# ---------------------------------------------------------------------------
# diff_run <name> [args...]
diff_run() {
    local name="$1"; shift
    local a_out a_rc p_out p_rc
    a_out=$("$BIN" "$@" --no-config --no-cache 2>/dev/null); a_rc=$?
    p_out=$(python3 "$PYSCRIPT" "$@" --no-config --no-cache 2>/dev/null); p_rc=$?
    if [ "$a_rc" != "$p_rc" ]; then
        bad "$name" "rc asm=$a_rc py=$p_rc"; return
    fi
    local an pn
    an=$(printf '%s' "$a_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/')
    pn=$(printf '%s' "$p_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/')
    # track whether this differential actually exercised a populated report
    # table (a "<name>   <count>" row) rather than comparing empty output.
    if printf '%s\n' "$an" | grep -Eq '^[A-Za-z_][A-Za-z0-9_]*[[:space:]]+[0-9,]+$'; then
        SAW_NONEMPTY_TABLE=1
    fi
    if [ "$an" = "$pn" ]; then
        ok "$name"
    else
        bad "$name" "output differs"
        diff <(printf '%s' "$pn") <(printf '%s' "$an") | head -6
    fi
}

# ---------------------------------------------------------------------------
# 1. text-mode differentials (full header + table + footer)
# ---------------------------------------------------------------------------
echo "== text-mode differentials =="
diff_run "basic full header+table+footer with commas" -c "$CH" -d "$LOGS" -e 2026-09-03
diff_run "by-state columns + shares" -c "$CH" -d "$LOGS" -e 2026-09-03 -B --share-floor 0
diff_run "by-state default floor" -c "$CH" -d "$LOGS" -e 2026-09-03 -B
diff_run "sort login" -c "$CH" -d "$LOGS" -e 2026-09-03 --sort login
diff_run "share sort live-share" -c "$CH" -d "$LOGS" -e 2026-09-03 -B --share-floor 0 --sort live-share
diff_run "cap n2 + +N others + top row" -c "$CH" -d "$LOGS" -e 2026-09-03 -n 2
diff_run "cap n1" -c "$CH" -d "$LOGS" -e 2026-09-03 -n 1
diff_run "threshold m4" -c "$CH" -d "$LOGS" -e 2026-09-03 -m 4
diff_run "exclusion row + footer line" -c "$CH" -d "$LOGS" -e 2026-09-03 -x bob,carol
diff_run "exclude broadcaster" -c "$CH" -d "$LOGS" -e 2026-09-03 --exclude-broadcaster
diff_run "compact header middot joins" -c "$CH" -d "$LOGS" -e 2026-09-03 --header compact
diff_run "header none" -c "$CH" -d "$LOGS" -e 2026-09-03 --header none
diff_run "share-floor 0 explicit" -c "$CH" -d "$LOGS" -e 2026-09-03 --share-floor 0
diff_run "share-floor unused with -B" -c "$CH" -d "$LOGS" -e 2026-09-03 -B
diff_run "compact n2" -c "$CH" -d "$LOGS" -e 2026-09-03 -n 2 --header compact
diff_run "users 3 row" -c "$CH" -d "$LOGS" -e 2026-09-03 --users 3
diff_run "users 2 row + human_duration" -c "$CH" -d "$LOGS" -e 2026-09-03 --users 2
diff_run "live filter -L" -c "$CH" -d "$LOGS" -e 2026-09-03 -L
diff_run "since 1d compact" -c "$CH" -d "$LOGS" -S 1d -e 2026-09-03 --header compact
diff_run "empty report message" -c "$CH" -d "$LOGS" -b 2026-09-02 -e 2026-09-02 -m 100
diff_run "empty + exclusion" -c "$CH" -d "$LOGS" -e 2026-09-03 -x bob,carol -m 100
diff_run "powerchan commas" -c "$PC" -d "$LOGS" -e 2026-09-01
diff_run "powerchan by-state" -c "$PC" -d "$LOGS" -e 2026-09-01 -B --share-floor 0
diff_run "state split row (offline filter)" -c "$CH" -d "$LOGS" -e 2026-09-03 -O
diff_run "begin-explicit" -c "$CH" -d "$LOGS" -b 2026-09-02 -e 2026-09-02

# unreadable row
chmod 000 "$LOGS/$CH/$CH-2026-09-02.log" 2>/dev/null
diff_run "unreadable row" -c "$CH" -d "$LOGS" -e 2026-09-03
chmod 644 "$LOGS/$CH/$CH-2026-09-02.log" 2>/dev/null

# ---------------------------------------------------------------------------
# 2. fixture sanity — refuse to be vacuous: at least one differential above
#    must have compared a populated report table, not just empty output.
# ---------------------------------------------------------------------------
echo "== fixture sanity =="
ok_or_fail "fixture sanity: non-empty table" "$SAW_NONEMPTY_TABLE"

# ---------------------------------------------------------------------------
# 3. JSON differentials
# ---------------------------------------------------------------------------
echo "== JSON differentials =="
json_diff() {
    local name="$1"; shift
    local a_out a_rc p_out p_rc
    a_out=$("$BIN" "$@" --no-config --no-cache 2>/dev/null); a_rc=$?
    p_out=$(python3 "$PYSCRIPT" "$@" --no-config --no-cache 2>/dev/null); p_rc=$?
    if [ "$a_rc" != "$p_rc" ]; then
        bad "$name" "rc asm=$a_rc py=$p_rc"; return
    fi
    if [ "$a_rc" -eq 0 ]; then
        if ! printf '%s' "$a_out" | python3 -m json.tool >/dev/null 2>&1; then
            bad "$name" "invalid JSON"; return
        fi
        # schema-first key order check
        local first
        first=$(printf '%s' "$a_out" | sed -n '2p' | tr -d ' ')
        if [ "$first" != '"schema":{' ]; then
            bad "$name" "schema not first"; return
        fi
    fi
    local an pn
    an=$(printf '%s' "$a_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/')
    pn=$(printf '%s' "$p_out" | sed -E 's/"generated_at": "[^"]*"/"generated_at": "X"/')
    if [ "$an" = "$pn" ]; then
        ok "$name"
    else
        bad "$name" "output differs"
        diff <(printf '%s' "$pn") <(printf '%s' "$an") | head -6
    fi
}
json_diff "json basic" -c "$CH" -d "$LOGS" -e 2026-09-03 --json
json_diff "json by-state" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -B --share-floor 0
json_diff "json cap" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -n 2
json_diff "json exclusion" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -x bob,carol
json_diff "json sort login" -c "$CH" -d "$LOGS" -e 2026-09-03 --json --sort login
json_diff "json users" -c "$CH" -d "$LOGS" -e 2026-09-03 --json --users 3
json_diff "json powerchan" -c "$PC" -d "$LOGS" -e 2026-09-01 --json -B --share-floor 0

# ---------------------------------------------------------------------------
# 4. piped = unlimited rows
# ---------------------------------------------------------------------------
echo "== piped output =="
a_out=$(printf '' | "$BIN" -c "$CH" -d "$LOGS" -e 2026-09-03 -n 5 --no-config --no-cache 2>/dev/null)
rows=$(printf '%s\n' "$a_out" | grep -cE '^[a-zA-Z_+0-9]+ +[0-9,]+$' || true)
if [ "$rows" -ge 5 ]; then
    ok "piped unlimited rows: $rows rows shown"
else
    bad "piped unlimited rows: only $rows rows"
fi

# ---------------------------------------------------------------------------
# 5. JSON error path
# ---------------------------------------------------------------------------
echo "== JSON error path =="
err=$("$BIN" -c "$CH" -d "$LOGS" -e 2026-09-03 -L -B --json --no-config --no-cache 2>&1 >/dev/null)
if printf '%s' "$err" | grep -q '{"error":'; then
    ok "json error path"
else
    bad "json error path" "got [$err]"
fi

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
tc_summary
