#!/bin/sh
# test-tc-misc.sh — Phase 8 test driver for tc_misc.S (twitch-counts-full).
#
# Builds a synthetic Chatterino log tree (logs inside the last 7 days so the
# --complete users window catches them) and checks:
#   (a) --manual byte-identical to python3 twitch-counts.py --manual
#   (b) --emit-fish-completions byte-identical to the python's
#   (c) --complete channels/groups/dates/weeks/periods/users/includes vs the
#       python (stdout, stderr and exit code, byte-for-byte)
#   (d) exit codes 0 for every kind
#   (e) empty state: no logs dir -> empty stdout, exit 0; an empty channel dir
#       -> empty stdout, exit 0; a missing channel dir -> the Python's
#       "completion failed: ConfigError(...)" on stderr, exit 0
#
# The binary under test is tc-misc-test (check_tc_misc.o + tc_misc.o +
# tc_core.o + tc_cli.o + tc_config.o + tc_util.o + tc_cache.o + toml.o +
# sqlite3.o), linked with the Phase-8 commands.  tc_cache.o + sqlite3.o are
# required because the Phase-4 tc_core.o calls the Phase-6 rollup-cache hooks
# (tc_cache_day/tc_cache_put_day/tc_cache_discard_day).
#
# Documented divergences (the Python wins; the C port differs by design):
#   * --manual/--emit-fish/--complete without any channel anywhere: the C
#     tc_cli_parse resolves the channel eagerly and exits 1 ("no channel
#     given") where the Python short-circuits before resolution.  The test
#     always supplies a channel via the synthetic config, so it does not
#     exercise that corner.
#   * --complete with an explicit --config that does not exist: tc_cli_parse
#     exits 1 ("error: config file not found") where the Python prints
#     "completion failed: ConfigError('config file not found: ...')" and
#     exits 0.  Both are asserted here as the current contract.
#   * complete_users uses UTC "now" (begin = end - 7d); the Python uses local
#     time.  The synthetic logs cover [now-6d, now-1d], safely inside either
#     window, so the candidates match.
set -u

# absolute directory of this script (captured before any cd)
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tc-misc-test.XXXXXX") || {
    echo "FAIL: cannot create temp directory"
    exit 2
}
trap 'rm -rf "$tmpdir"' EXIT INT TERM

channels="$tmpdir/Logs/Twitch/Channels"
mkdir -p "$channels/chroniccmposer" "$channels/OtherChan" "$channels/EMPTYDIR"

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

# --- synthetic channel logs (inside any 7-day window ending "now") ----------
cd "$channels/chroniccmposer" || exit 2
for days_ago in 6 5 4 3 2; do
    d=$(date -u -d "$days_ago days ago" +%Y-%m-%d)
    cat > "chroniccmposer-$d.log" << 'EOF'
[10:00:00] ChronicCmposer is live!
[10:00:01] alice: msg
[10:00:02] bob: msg
[10:00:03] carol: msg
[10:01:00] streamelements: alert
[10:01:01] ChronicCmposer is now offline.
EOF
done
d=$(date -u -d "1 day ago" +%Y-%m-%d)
cat > "chroniccmposer-$d.log" << 'EOF'
[10:00:00] ChronicCmposer is live!
[10:00:01] alice: msg
[10:00:02] alice: msg
[10:00:03] bob: msg
[10:01:00] ChronicCmposer is now offline.
EOF
# a per-stream log that the dated-file matcher must reject
cat > chroniccmposer-12345.log << 'EOF'
[10:00:00] ChronicCmposer is live!
EOF
cd "$tmpdir" || exit 2

# --- config: aliases + grouped exclusions -----------------------------------
cat > "$tmpdir/config.toml" << 'EOF'
channel = "chroniccmposer"

[aliases]
cc = "chroniccmposer"

[exclude]
bots = ["streamelements", "supibot"]
regulars = ["alice", "bob"]
always = ["bots"]
EOF

# --- build ----------------------------------------------------------------
cd "$script_dir" || exit 2
as tc_misc.S -o tc_misc.o || exit 2
as check_tc_misc.S -o check_tc_misc.o || exit 2
/var/lib/opencode/dev/shirley-asm/third_party/musl/bin/musl-gcc \
    -static -o tc-misc-test \
    check_tc_misc.o tc_misc.o tc_core.o tc_cli.o tc_config.o tc_util.o \
    tc_cache.o third_party/tomlc99/toml.o third_party/sqlite3/sqlite3.o \
    || exit 2
BIN=./tc-misc-test
PY="python3 twitch-counts.py"
CFG="$tmpdir/config.toml"
LOGS="$tmpdir/Logs/Twitch/Channels"

# --- differential helper ----------------------------------------------------
run_diff() { # run_diff <name> [args...]
    name=$1
    shift
    # fresh cache dir so the Python never reuses stale rollup days
    mkdir -p "$tmpdir/cache"
    XDG_CACHE_HOME="$tmpdir/cache" $PY "$@" > "$tmpdir/py.out" 2> "$tmpdir/py.err"
    py_rc=$?
    XDG_CACHE_HOME="$tmpdir/cache" $BIN "$@" > "$tmpdir/c.out" 2> "$tmpdir/c.err"
    c_rc=$?
    ok=1
    cmp -s "$tmpdir/py.out" "$tmpdir/c.out" || ok=0
    cmp -s "$tmpdir/py.err" "$tmpdir/c.err" || ok=0
    [ "$py_rc" -eq "$c_rc" ] || ok=0
    if [ $ok -ne 1 ]; then
        echo "  py.rc=$py_rc c.rc=$c_rc"
        diff "$tmpdir/py.out" "$tmpdir/c.out" | head -6
        diff "$tmpdir/py.err" "$tmpdir/c.err" | head -6
    fi
    ok_or_fail "$name" "$ok"
}

# --- (a) --manual byte-identical --------------------------------------------
run_diff "manual" --config "$CFG" --logs-dir "$LOGS" --manual

# --- (b) --emit-fish-completions byte-identical ------------------------------
run_diff "emit-fish-completions" --config "$CFG" --logs-dir "$LOGS" \
    --emit-fish-completions

# --- (c)+(d) --complete kinds: stdout+stderr+exit, byte-for-byte -------------
for kind in channels groups dates weeks periods users includes; do
    run_diff "complete $kind" --config "$CFG" --logs-dir "$LOGS" --complete "$kind"
done

# includes with the merged layers: CLI excludes, --include, --exclude-group,
# env TWITCH_EXCLUDE, --exclude-broadcaster
run_diff "complete includes layers" --config "$CFG" --logs-dir "$LOGS" \
    --complete includes -x "Foo,Bar Baz" -g regulars --include alice
TWITCH_EXCLUDE="envuser1 envuser2" XDG_CACHE_HOME="$tmpdir/cache" \
    $PY --config "$CFG" --logs-dir "$LOGS" --complete includes \
    > "$tmpdir/py.out" 2> "$tmpdir/py.err"
py_rc=$?
TWITCH_EXCLUDE="envuser1 envuser2" XDG_CACHE_HOME="$tmpdir/cache" \
    $BIN --config "$CFG" --logs-dir "$LOGS" --complete includes \
    > "$tmpdir/c.out" 2> "$tmpdir/c.err"
c_rc=$?
ok=1
cmp -s "$tmpdir/py.out" "$tmpdir/c.out" || ok=0
cmp -s "$tmpdir/py.err" "$tmpdir/c.err" || ok=0
[ "$py_rc" -eq "$c_rc" ] || ok=0
ok_or_fail "complete includes TWITCH_EXCLUDE" "$ok"

# --- (e) empty state ---------------------------------------------------------
# no logs dir at all: empty stdout, exit 0, Python's ConfigError on stderr
run_diff "empty state: no logs dir" --config "$CFG" \
    --logs-dir "$tmpdir/NO_SUCH_DIR" --complete dates

# an existing channel dir with no dated files: empty stdout, exit 0
run_diff "empty state: empty channel dir" --config "$CFG" --logs-dir "$LOGS" \
    --complete dates -c EMPTYDIR

# a channel with no matching dir: Python's "no logs for channel" on stderr
run_diff "empty state: no channel dir" --config "$CFG" --logs-dir "$LOGS" \
    --complete dates -c nosuchchan

# unknown --exclude-group stays quiet (stderr report, exit 0)
run_diff "empty state: unknown group" --config "$CFG" --logs-dir "$LOGS" \
    --complete includes -g nosuchgroup

# --- documented divergences (assert the current C contract) ------------------
# explicit missing config: Python prints "completion failed:" + exit 0;
# the C tc_cli_parse exits 1 first (eager config load).  Both are asserted.
XDG_CACHE_HOME="$tmpdir/cache" $PY --config "$tmpdir/NO_SUCH.toml" \
    --logs-dir "$LOGS" --complete groups > "$tmpdir/py.out" 2> "$tmpdir/py.err"
py_rc=$?
XDG_CACHE_HOME="$tmpdir/cache" $BIN --config "$tmpdir/NO_SUCH.toml" \
    --logs-dir "$LOGS" --complete groups > "$tmpdir/c.out" 2> "$tmpdir/c.err"
c_rc=$?
ok=1
[ "$py_rc" -eq 0 ] && [ "$c_rc" -eq 1 ] || ok=0
grep -q "completion failed: ConfigError('config file not found" "$tmpdir/py.err" \
    || ok=0
grep -q "error: config file not found" "$tmpdir/c.err" || ok=0
cmp -s "$tmpdir/py.out" "$tmpdir/c.out" || ok=0
ok_or_fail "documented divergence: missing explicit config" "$ok"

echo
echo "tc-misc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]