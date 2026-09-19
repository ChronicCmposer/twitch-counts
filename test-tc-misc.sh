#!/bin/sh
# test-tc-misc.sh — harness for tc_misc.S (twitch-counts-full).
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
# The binary under test is $BUILD/tc-misc-test (check_tc_misc.o + tc_misc.o +
# tc_core.o + tc_cli.o + tc_config.o + tc_util.o + tc_cache.o + toml.o +
# sqlite3.o + libpcre2-8).  The Makefile
# owns the link (`make drivers`, or `make drivers twitch-counts-full` for
# the full product); this script only runs the result.  BUILD defaults to
# build/<os> (build/darwin on macOS, build/linux on Linux) unless TC_BUILD
# is set in the environment, matching how `make test` invokes harnesses.
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
#
# Isolation: the Python oracle's macOS Platform class calls
# os.path.expanduser("~/.cache/...") / ("~/.config/...") directly and
# ignores XDG_*; its Linux class and the assembly driver honour
# XDG_CONFIG_HOME/XDG_CACHE_HOME instead.  So every invocation of the
# oracle and the driver below runs with HOME *and* XDG_CONFIG_HOME *and*
# XDG_CACHE_HOME pointed at a per-run temp directory (exported once, right
# after mktemp) -- covering both flavours and never touching the real
# ~/.cache/twitch-counts/rollup.db or ~/.config/twitch-counts.toml.
set -u

# absolute directory of this script (captured before any cd)
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
cd "$script_dir" || exit 2

# --- oracle sanity check ------------------------------------------------------
command -v python3 >/dev/null 2>&1 || {
    echo "FAIL: python3 not found on PATH"
    exit 2
}
python3 -c 'import tomllib' >/dev/null 2>&1 || {
    echo "FAIL: python3 >= 3.11 required (tomllib module not found); got: $(python3 --version 2>&1)"
    exit 2
}
PY="python3 $script_dir/twitch-counts.py"

# --- driver under test --------------------------------------------------------
BUILD=${TC_BUILD:-build/$(uname -s | tr A-Z a-z)}
BIN="$script_dir/$BUILD/tc-misc-test"
[ -x "$BIN" ] || {
    echo "FAIL: driver not found: $BIN (run: make drivers)"
    exit 2
}

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tc-misc-test.XXXXXX") || {
    echo "FAIL: cannot create temp directory"
    exit 2
}
trap 'rm -rf "$tmpdir"' EXIT INT TERM

# --- isolation: never touch the real HOME's config/cache ---------------------
HOME="$tmpdir/home"
XDG_CONFIG_HOME="$HOME/.config"
XDG_CACHE_HOME="$tmpdir/cache"
export HOME XDG_CONFIG_HOME XDG_CACHE_HOME
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

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
    d=$(python3 -c '
import datetime, sys
days = int(sys.argv[1])
now = datetime.datetime.now(datetime.timezone.utc)
print((now - datetime.timedelta(days=days)).strftime("%Y-%m-%d"))
' "$days_ago") || exit 2
    cat > "chroniccmposer-$d.log" << 'EOF'
[10:00:00] ChronicCmposer is live!
[10:00:01] alice: msg
[10:00:02] bob: msg
[10:00:03] carol: msg
[10:01:00] streamelements: alert
[10:01:01] ChronicCmposer is now offline.
EOF
done
d=$(python3 -c '
import datetime
now = datetime.datetime.now(datetime.timezone.utc)
print((now - datetime.timedelta(days=1)).strftime("%Y-%m-%d"))
') || exit 2
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

CFG="$tmpdir/config.toml"
LOGS="$tmpdir/Logs/Twitch/Channels"

# --- differential helper ----------------------------------------------------
run_diff() { # run_diff <name> [args...]
    name=$1
    shift
    $PY "$@" > "$tmpdir/py.out" 2> "$tmpdir/py.err"
    py_rc=$?
    "$BIN" "$@" > "$tmpdir/c.out" 2> "$tmpdir/c.err"
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
TWITCH_EXCLUDE="envuser1 envuser2" $PY --config "$CFG" --logs-dir "$LOGS" \
    --complete includes > "$tmpdir/py.out" 2> "$tmpdir/py.err"
py_rc=$?
TWITCH_EXCLUDE="envuser1 envuser2" "$BIN" --config "$CFG" --logs-dir "$LOGS" \
    --complete includes > "$tmpdir/c.out" 2> "$tmpdir/c.err"
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

# --- --emit-fish-completions across HOME variations --------------------------
# fish_completions() only walks the argparse parser -- it never touches HOME
# or the config -- so the output must stay byte-identical no matter how HOME
# is set, unset, or emptied. These exercise that robustness directly.
home_variant_dir=$(mktemp -d "${TMPDIR:-/tmp}/tc-misc-home.XXXXXX") || exit 2
mkdir -p "$home_variant_dir/home"

# (1) HOME points at a fresh, empty, otherwise-unrelated temp directory
HOME="$home_variant_dir/home" $PY --emit-fish-completions \
    > "$tmpdir/py.out" 2> "$tmpdir/py.err"
py_rc=$?
HOME="$home_variant_dir/home" "$BIN" --emit-fish-completions \
    > "$tmpdir/c.out" 2> "$tmpdir/c.err"
c_rc=$?
ok=1
cmp -s "$tmpdir/py.out" "$tmpdir/c.out" || ok=0
cmp -s "$tmpdir/py.err" "$tmpdir/c.err" || ok=0
[ "$py_rc" -eq "$c_rc" ] || ok=0
ok_or_fail "emit-fish-completions: HOME=<mktemp>/home" "$ok"

# (2) HOME set to the empty string
HOME="" $PY --emit-fish-completions > "$tmpdir/py.out" 2> "$tmpdir/py.err"
py_rc=$?
HOME="" "$BIN" --emit-fish-completions > "$tmpdir/c.out" 2> "$tmpdir/c.err"
c_rc=$?
ok=1
cmp -s "$tmpdir/py.out" "$tmpdir/c.out" || ok=0
cmp -s "$tmpdir/py.err" "$tmpdir/c.err" || ok=0
[ "$py_rc" -eq "$c_rc" ] || ok=0
ok_or_fail "emit-fish-completions: HOME=\"\"" "$ok"

# (3) HOME entirely unset (env -u HOME, on both sides)
env -u HOME $PY --emit-fish-completions > "$tmpdir/py.out" 2> "$tmpdir/py.err"
py_rc=$?
env -u HOME "$BIN" --emit-fish-completions > "$tmpdir/c.out" 2> "$tmpdir/c.err"
c_rc=$?
ok=1
cmp -s "$tmpdir/py.out" "$tmpdir/c.out" || ok=0
cmp -s "$tmpdir/py.err" "$tmpdir/c.err" || ok=0
[ "$py_rc" -eq "$c_rc" ] || ok=0
ok_or_fail "emit-fish-completions: HOME unset (env -u HOME)" "$ok"

# (4) Linux only: same check again with XDG_CONFIG_HOME set explicitly, since
# the Linux Platform class (unlike MacOS) honours XDG_CONFIG_HOME for its own
# paths -- fish_completions() still must not care.
if [ "$(uname -s)" = "Linux" ]; then
    HOME="$home_variant_dir/home" XDG_CONFIG_HOME="$home_variant_dir/home/.config" \
        $PY --emit-fish-completions > "$tmpdir/py.out" 2> "$tmpdir/py.err"
    py_rc=$?
    HOME="$home_variant_dir/home" XDG_CONFIG_HOME="$home_variant_dir/home/.config" \
        "$BIN" --emit-fish-completions > "$tmpdir/c.out" 2> "$tmpdir/c.err"
    c_rc=$?
    ok=1
    cmp -s "$tmpdir/py.out" "$tmpdir/c.out" || ok=0
    cmp -s "$tmpdir/py.err" "$tmpdir/c.err" || ok=0
    [ "$py_rc" -eq "$c_rc" ] || ok=0
    ok_or_fail "emit-fish-completions: Linux, XDG_CONFIG_HOME set" "$ok"
fi

# --- --complete channels with no --logs-dir: platform default ----------------
# Without --logs-dir/TWITCH_LOGS_DIR/config logs_dir, both sides fall back to
# the platform default: on macOS, "~/Library/Application Support/chatterino/
# Logs/Twitch/Channels" under the isolated HOME (a channel dir placed there
# must be listed); on Linux, Platform.logs_dir() is None, so no channel
# directories are contributed (only configured aliases, if any).
# NOTE: this assumes deterministic output ordering and a pristine isolated
# HOME (fresh mktemp dir) with no other stray Logs/Twitch/Channels entries.
if [ "$(uname -s)" = "Darwin" ]; then
    default_logs_dir="$HOME/Library/Application Support/chatterino/Logs/Twitch/Channels"
    mkdir -p "$default_logs_dir/DefaultChan"
    run_diff "complete channels: no --logs-dir (macOS Library default)" \
        --config "$CFG" --complete channels
else
    run_diff "complete channels: no --logs-dir (Linux: none)" \
        --config "$CFG" --complete channels
fi

# --- documented divergences (assert the current C contract) ------------------
# explicit missing config: Python prints "completion failed:" + exit 0;
# the C tc_cli_parse exits 1 first (eager config load).  Both are asserted.
$PY --config "$tmpdir/NO_SUCH.toml" --logs-dir "$LOGS" --complete groups \
    > "$tmpdir/py.out" 2> "$tmpdir/py.err"
py_rc=$?
"$BIN" --config "$tmpdir/NO_SUCH.toml" --logs-dir "$LOGS" --complete groups \
    > "$tmpdir/c.out" 2> "$tmpdir/c.err"
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
