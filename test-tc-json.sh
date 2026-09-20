#!/bin/bash
# ============================================================================
# test-tc-json.sh — harness for tc_json.S.
#
#   Compares the AArch64 JSON emitter byte-for-byte against the Python
#   reference (twitch-counts.py) across the flag matrix, plus structural
#   checks of the emitted document (validity, key order, the generated_at
#   timestamp shape, the unreadable {file, problem} rows, null/true/false
#   handling and the error path).
#
#   Driver:    $BUILD/tc-json-test, resolved via the shared tc-test-lib.sh
#              (override with TC_BUILD=...).  Build it first with
#              `make drivers`; this script performs no builds of its own.
#   Oracle:    `python3 twitch-counts.py` from PATH.  Checked once at the top
#              to be >= 3.11 (i.e. it has the stdlib `tomllib` module) before
#              anything else runs.
#   Fixtures:  a synthetic chroniccmposer + powerchan Chatterino log tree is
#              generated fresh under a mktemp directory at the start of every
#              run (same content as test-tc-render.sh), so the differentials
#              always have real data to compare instead of silently agreeing
#              on empty output.  A dedicated "fixture sanity" check fails
#              loudly if that ever stops being true.
#   Isolation: HOME, XDG_CONFIG_HOME and XDG_CACHE_HOME are exported once, to
#              paths under that same mktemp directory, before ANY python3 or
#              driver invocation runs — so neither the oracle nor the driver
#              can ever touch the user's real config or cache.
#
#   Usage:  ./test-tc-json.sh
#           TC_BUILD=build/darwin ./test-tc-json.sh
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
BIN=$(tc_driver tc-json-test) || exit 2
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
WORKDIR=$(tc_sandbox tc-json-test)

DATA="$WORKDIR/data"
tc_isolate_home "$WORKDIR"
mkdir -p "$DATA"
tc_require_python_tomllib          # the first python3 call runs isolated

LOGS="$DATA/Logs/Twitch/Channels"
CH=chroniccmposer
PC=powerchan
SAW_NONEMPTY_ROWS=0

# ---------------------------------------------------------------------------
# fixtures: synthetic chroniccmposer + powerchan log tree — the same content
# test-tc-render.sh builds (copied here, not imported, so this harness has no
# dependency on that script).
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

# powerchan: a 1,234-message user for wide integer rendering
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
# JSON differential helper — byte-for-byte vs the Python reference with the
# generated_at timestamp masked (it is the one expected difference).
# ---------------------------------------------------------------------------
json_diff() {
    local name="$1"; shift
    local a_out a_rc p_out p_rc
    a_out=$("$BIN" "$@" --no-config --no-cache 2>/dev/null); a_rc=$?
    p_out=$(python3 "$PYSCRIPT" "$@" --no-config --no-cache 2>/dev/null); p_rc=$?
    if [ "$a_rc" != "$p_rc" ]; then
        bad "$name" "rc asm=$a_rc py=$p_rc"; return
    fi
    if [ "$a_rc" -eq 0 ]; then
        # the emitted document must parse
        if ! printf '%s' "$a_out" | python3 -m json.tool >/dev/null 2>&1; then
            bad "$name" "invalid JSON"; return
        fi
        # track whether this differential exercised populated rows
        if printf '%s' "$a_out" | grep -q '"login"'; then
            SAW_NONEMPTY_ROWS=1
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

# ---------------------------------------------------------------------------
# 1. JSON differentials
# ---------------------------------------------------------------------------
echo "== JSON differentials =="
json_diff "json basic" -c "$CH" -d "$LOGS" -e 2026-09-03 --json
json_diff "json by-state + shares" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -B --share-floor 0
json_diff "json by-state default floor" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -B
json_diff "json cap n2" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -n 2
json_diff "json exclusion" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -x bob,carol
json_diff "json sort login" -c "$CH" -d "$LOGS" -e 2026-09-03 --json --sort login
json_diff "json users 3" -c "$CH" -d "$LOGS" -e 2026-09-03 --json --users 3
json_diff "json live filter" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -L
json_diff "json offline filter" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -O
json_diff "json begin-explicit" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -b 2026-09-02
json_diff "json powerchan commas" -c "$PC" -d "$LOGS" -e 2026-09-01 --json -B --share-floor 0

# ---------------------------------------------------------------------------
# 2. fixture sanity — refuse to be vacuous: at least one differential above
#    must have compared a populated report (a row containing "login").
# ---------------------------------------------------------------------------
echo "== fixture sanity =="
ok_or_fail "fixture sanity: non-empty rows" "$SAW_NONEMPTY_ROWS"

# ---------------------------------------------------------------------------
# 3. structural checks of the emitted document
# ---------------------------------------------------------------------------
echo "== structural checks =="

a_out=$("$BIN" -c "$CH" -d "$LOGS" -e 2026-09-03 --json --no-config --no-cache 2>/dev/null)

# valid JSON (already implied by json_diff, but explicit here for the driver)
if printf '%s' "$a_out" | python3 -m json.tool >/dev/null 2>&1; then
    ok "document parses as JSON"
else
    bad "document parses as JSON"
fi

# schema must be the first key, and schema_version present
first=$(printf '%s' "$a_out" | sed -n '2p' | tr -d ' ')
if [ "$first" = '"schema":{' ]; then
    ok "schema first key"
else
    bad "schema first key" "got [$first]"
fi

# generated_at must be a full local date-time (python fromisoformat accepts it)
gen=$(printf '%s' "$a_out" | python3 -c 'import json,sys; print(json.load(sys.stdin)["generated_at"])')
if printf '%s' "$gen" | python3 -c 'import sys; from datetime import datetime; datetime.fromisoformat(sys.stdin.read().strip())' >/dev/null 2>&1; then
    ok "generated_at is a date-time ($gen)"
else
    bad "generated_at is a date-time" "got [$gen]"
fi

# required top-level keys, in insertion order after the schema blob
required=$(printf '%s' "$a_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k in ("schema_version", "generated_at", "query", "totals", "rows"):
    if k not in d:
        sys.exit(1)
print("ok")
')
check "required top-level keys present" "ok" "$required"

# rows length must agree between the assembly and the Python reference
p_rows=$(python3 "$PYSCRIPT" -c "$CH" -d "$LOGS" -e 2026-09-03 --json --no-config --no-cache 2>/dev/null \
    | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))')
a_rows=$(printf '%s' "$a_out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["rows"]))')
check "rows length matches python ($a_rows)" "$p_rows" "$a_rows"

# the unreadable {file, problem} rows: make one log unreadable and confirm
# the shape is valid JSON with a "file" and a "problem" key per entry
chmod 000 "$LOGS/$CH/$CH-2026-09-02.log" 2>/dev/null
u_out=$("$BIN" -c "$CH" -d "$LOGS" -e 2026-09-03 --json --no-config --no-cache 2>/dev/null)
chmod 644 "$LOGS/$CH/$CH-2026-09-02.log" 2>/dev/null
ucheck=$(printf '%s' "$u_out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
un = d["totals"].get("unreadable", [])
if not isinstance(un, list) or len(un) == 0:
    sys.exit(1)
for e in un:
    if not isinstance(e, dict) or "file" not in e or "problem" not in e:
        sys.exit(1)
print("ok")
')
check "unreadable rows carry file+problem" "ok" "$ucheck"

# top: null when unlimited (no --top)
top_null=$(printf '%s' "$a_out" | python3 -c '
import json, sys
q = json.load(sys.stdin)["query"]
print("null" if q.get("top") is None else "not-null")
')
check "top null when unlimited" "null" "$top_null"

# share_floor applied: true when a floor is requested and applied
sf_true=$("$BIN" -c "$CH" -d "$LOGS" -e 2026-09-03 --json -B --share-floor 1 --no-config --no-cache 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["query"]["share_floor"]["applied"])')
check "share_floor applied true" "True" "$sf_true"

# ---------------------------------------------------------------------------
# 4. JSON error path — the {"error": ...} shape on stderr, exit 1
# ---------------------------------------------------------------------------
echo "== JSON error path =="
err_out=$(mktemp "$WORKDIR/err.XXXXXX")
err_rc=0
"$BIN" -c "$CH" -d "$LOGS" -e 2026-09-03 -L -B --json --no-config --no-cache 2>"$err_out" >/dev/null || err_rc=$?
if printf '%s' "$(cat "$err_out")" | grep -q '{"error":'; then
    ok "json error path emits {\"error\": ...}"
else
    bad "json error path emits {\"error\": ...}" "got [$(cat "$err_out")]"
fi
check "json error path exit 1" "1" "$err_rc"
rm -f "$err_out"

# ---------------------------------------------------------------------------
# summary
# ---------------------------------------------------------------------------
tc_summary