#!/usr/bin/env bash
# ============================================================================
# test-tc-config.sh — Phase-3 harness for the config/env/exclusion hooks.
#
# Builds the config driver (check_tc_config.o + tc_config.o + tc_cli.o +
# tc_util.o + toml.o) and checks:
#   (a) config file resolution: values + source labels for top-level and
#       [watch]/[tail] keys
#   (b) precedence: CLI > env > config > default
#   (c) config errors: missing explicit file, bad TOML, [watch]/[aliases]
#       non-tables, [exclude] shape errors, unknown groups, --no-exclude
#       conflicts
#   (d) alias rewriting ("<src> -> alias '<key>'")
#   (e) exclusion layers: flat, groups+always, --exclude-group,
#       TWITCH_EXCLUDE, --exclude, --exclude-broadcaster, --include
#   (f) exact exclusion-set contents after each combination
#   (g) differential vs python3 twitch-counts.py: exit codes, error text
#       (normalized), and the resolved exclusion set + source list via the
#       Python --json query.excluded / query.sources.exclude fields.
#
# Usage: ./test-tc-config.sh
# ============================================================================
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
cd "$HERE"

MUSL_GCC=./third_party/musl/bin/musl-gcc
AS=as
BIN=tc-config-test
PY=python3

PASS=0
FAIL=0
DIFF_FAIL=0

ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------------------------------------------------------------------------
# Build the driver
# ---------------------------------------------------------------------------
build() {
    $AS tc_util.S -o tc_util.o &&
    $AS tc_cli.S -o tc_cli.o &&
    $AS tc_config.S -o tc_config.o &&
    $AS check_tc_config.S -o check_tc_config.o &&
    $MUSL_GCC -static -o "$BIN" \
        check_tc_config.o tc_config.o tc_cli.o tc_util.o third_party/tomlc99/toml.o
}

# run_case NAME ARG...  -> exit code in $RC, stdout+stderr in $OUT
run_case() {
    local name=$1; shift
    OUT=$("$HERE/$BIN" "$@" 2>&1); RC=$?
}

# expect_ok NAME ARG... — exit 0
expect_ok() {
    local name=$1; shift
    run_case "$name" "$@"
    if [ "$RC" -eq 0 ]; then ok; else
        bad "$name: expected exit 0, got $RC (args: $*)"; echo "$OUT" | tail -2
    fi
}

# expect_exit NAME WANT ARG...
expect_exit() {
    local name=$1 want=$2; shift 2
    run_case "$name" "$@"
    if [ "$RC" -eq "$want" ]; then ok; else
        bad "$name: exit $RC, want $want (args: $*)"; echo "$OUT" | tail -2
    fi
}

# expect_err NAME NEEDLE ARG... — exit 1 and stderr contains the needle
expect_err() {
    local name=$1 needle=$2; shift 2
    run_case "$name" "$@"
    if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF -- "$needle"; then ok; else
        bad "$name: want exit 1 + '$needle' (got rc=$RC, out: $(echo "$OUT" | tail -1))"
    fi
}

# expect_driver NAME ARG... — exit 0 and the driver output matches $OUT
expect_driver() {
    local name=$1; shift
    run_case "$name" "$@"
    if [ "$RC" -eq 0 ]; then ok; else
        bad "$name: expected exit 0, got $RC"; echo "$OUT" | tail -2
    fi
}

echo "building tc-config-test ..."
if ! build; then
    echo "BUILD FAILED"
    exit 1
fi
echo "build ok"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
TMP=$(mktemp -d /tmp/tc-config-test.XXXXXX)
export XDG_CONFIG_HOME=
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/logs/mychannel"
CFG="$TMP/cfg.toml"
cat > "$CFG" <<'EOF'
channel = "cfgchan"
logs_dir = "DIR"
min_count = 7
top = 20
header = "compact"
sort = "offline"
end = "2026-09-01"
interval = 2.5
shades = 9
user_width = 40
[watch]
min_interval = 1.5
shades = 7
user_width = 35
streamer_mode = true
[tail]
notify = false
max_events = 6
seed_lookback = 12
[aliases]
short = "realchan"
[exclude]
bots = ["bot_a", "bot_b", " BOT_C "]
mods = ["mod_x"]
always = ["bots"]
EOF
sed -i "s#DIR#$TMP/logs#g" "$CFG"

# ---- a. config resolution: values + sources -------------------------------
echo "-- (a) config file resolution --"
expect_driver "a1-top-level-values" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01
echo "$OUT" | grep -q '^min_count=7$'           && ok || bad "a1 min_count"
echo "$OUT" | grep -q '^top=20$'                && ok || bad "a1 top"
echo "$OUT" | grep -q '^sort=3$'                && ok || bad "a1 sort"
echo "$OUT" | grep -q '^config_loaded=1$'       && ok || bad "a1 loaded"
echo "$OUT" | grep -q '^src=config$'            && ok || bad "a1 config src"
echo "$OUT" | grep -q '^notify=0$'              && ok || bad "a1 notify"
echo "$OUT" | grep -q '^max_events=6$'          && ok || bad "a1 max_events"
echo "$OUT" | grep -q '^seed_lookback=12$'      && ok || bad "a1 seed_lookback"
echo "$OUT" | grep -q '^src=config \[tail\]$'   && ok || bad "a1 tail src"

expect_driver "a2-watch-section" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01 --watch
echo "$OUT" | grep -q '^shades=7$'              && ok || bad "a2 shades"
echo "$OUT" | grep -q '^user_width=35$'         && ok || bad "a2 user_width"
echo "$OUT" | grep -q '^src=config \[watch\]$'  && ok || bad "a2 watch src"
# [watch] beats top-level: interval comes from top-level (2.5 = 0x4004000000000000)
echo "$OUT" | grep -q '^interval=4612811918334230528$' && ok || bad "a2 interval"

# ---- b. precedence --------------------------------------------------------
echo "-- (b) precedence: CLI > env > config > default --"
expect_driver "b1-env-beats-config" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01
run_case "b1-env-beats-config" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01
TWITCH_CHANNEL=envchan TWITCH_MIN_COUNT=9 "$HERE/$BIN" --config "$CFG" -e 2026-09-01 -b 2026-09-01 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    TWOUT=$(TWITCH_CHANNEL=envchan TWITCH_MIN_COUNT=9 "$HERE/$BIN" --config "$CFG" -e 2026-09-01 -b 2026-09-01 2>&1)
    echo "$TWOUT" | grep -q '^channel=envchan$'      && ok || bad "b1 channel"
    echo "$TWOUT" | grep -q '^chan_src=env TWITCH_CHANNEL$' && ok || bad "b1 chan src"
    echo "$TWOUT" | grep -q '^min_count=9$'          && ok || bad "b1 min"
    echo "$TWOUT" | grep -q '^src=env TWITCH_MIN_COUNT$' && ok || bad "b1 min src"
else
    bad "b1 env run failed"
fi
CLIOUT=$(TWITCH_CHANNEL=envchan "$HERE/$BIN" --config "$CFG" -c clichan -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$CLIOUT" | grep -q '^channel=clichan$'         && ok || bad "b2 cli beats env"
echo "$CLIOUT" | grep -q '^chan_src=--channel$'      && ok || bad "b2 cli src"
CFGOUT=$("$HERE/$BIN" --config "$CFG" -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$CFGOUT" | grep -q '^min_count=7$'             && ok || bad "b3 config beats default"
DEFAULTOUT=$("$HERE/$BIN" -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$DEFAULTOUT" | grep -q '^min_count=1$'         && ok || bad "b4 default"
# TWITCH_COUNTS_CONFIG selects the file
TCC=$(TWITCH_COUNTS_CONFIG="$CFG" "$HERE/$BIN" -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$TCC" | grep -q '^config_loaded=1$'            && ok || bad "b5 env config path"
echo "$TCC" | grep -q '^min_count=7$'                && ok || bad "b5 env config value"
# --no-config ignores everything
NC=$("$HERE/$BIN" --no-config -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$NC" | grep -q '^config_loaded=0$'             && ok || bad "b6 no-config"
echo "$NC" | grep -q '^min_count=1$'                 && ok || bad "b6 no-config min"

# ---- c. config errors -----------------------------------------------------
echo "-- (c) config errors --"
expect_err "c1-missing-explicit" "config file not found: $TMP/nope.toml" \
    --config "$TMP/nope.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = \n' > "$TMP/bad.toml"
expect_err "c2-bad-toml" "could not read config $TMP/bad.toml: " \
    --config "$TMP/bad.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = "x"\nwatch = "str"\n' > "$TMP/watchstr.toml"
expect_err "c3-watch-not-table" "[watch] in $TMP/watchstr.toml must be a table" \
    --config "$TMP/watchstr.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = "x"\ntail = 5\n' > "$TMP/tailstr.toml"
expect_err "c4-tail-not-table" "[tail] in $TMP/tailstr.toml must be a table" \
    --config "$TMP/tailstr.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = "x"\naliases = "str"\n' > "$TMP/aliasstr.toml"
expect_err "c5-aliases-not-table" "[aliases] in $TMP/aliasstr.toml must be a table of name = channel" \
    --config "$TMP/aliasstr.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = "x"\nexclude = "str"\n' > "$TMP/exclstr.toml"
expect_err "c6-exclude-shape" "\`exclude\` in $TMP/exclstr.toml must be a list of logins or a table of groups" \
    --config "$TMP/exclstr.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = "x"\n[exclude]\nfoo = "a"\n' > "$TMP/exclfoo.toml"
expect_err "c7-group-not-list" "[exclude].foo in $TMP/exclfoo.toml must be a list of logins" \
    --config "$TMP/exclfoo.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = "x"\n[exclude]\nbots = ["a"]\nalways = "bots"\n' > "$TMP/exclalw.toml"
expect_err "c8-always-not-list" "[exclude].always in $TMP/exclalw.toml must be a list of group names" \
    --config "$TMP/exclalw.toml" -c foo -e 2026-09-01 -b 2026-09-01
printf 'channel = "x"\n[exclude]\nbots = ["a"]\nalways = ["ghosts"]\n' > "$TMP/exclunk.toml"
expect_err "c9-always-unknown" "[exclude].always in $TMP/exclunk.toml names unknown group 'ghosts'; defined groups: bots" \
    --config "$TMP/exclunk.toml" -c foo -e 2026-09-01 -b 2026-09-01
expect_err "c10-unknown-group" "unknown exclude group 'ghosts'; defined groups: bots, mods" \
    --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01 -g ghosts
printf 'channel = "x"\nexclude = ["a"]\n' > "$TMP/exclflat2.toml"
expect_err "c11-unknown-no-groups" "unknown exclude group 'ghosts'; defined groups: (none defined)" \
    --config "$TMP/exclflat2.toml" -c foo -e 2026-09-01 -b 2026-09-01 -g ghosts
expect_err "c12-noexcl-x" "--no-exclude cannot be combined with --exclude" \
    --config "$TMP/exclflat2.toml" -c foo -e 2026-09-01 -b 2026-09-01 --no-exclude -x a
expect_err "c13-noexcl-g" "--no-exclude cannot be combined with --exclude-group" \
    --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01 --no-exclude -g bots
expect_err "c14-noexcl-bcast" "--no-exclude cannot be combined with --exclude-broadcaster" \
    --config "$TMP/exclflat2.toml" -c foo -e 2026-09-01 -b 2026-09-01 --no-exclude --exclude-broadcaster
expect_err "c15-noexcl-incl" "--no-exclude cannot be combined with --include" \
    --config "$TMP/exclflat2.toml" -c foo -e 2026-09-01 -b 2026-09-01 --no-exclude --include a
expect_err "c16-noexcl-multi" "--no-exclude cannot be combined with --exclude, --include" \
    --config "$TMP/exclflat2.toml" -c foo -e 2026-09-01 -b 2026-09-01 --no-exclude -x a --include b

# ---- d. aliases -----------------------------------------------------------
echo "-- (d) aliases --"
expect_driver "d1-alias" --config "$CFG" -c short -e 2026-09-01 -b 2026-09-01
echo "$OUT" | grep -q '^channel=realchan$'                       && ok || bad "d1 channel"
echo "$OUT" | grep -q "^chan_src=--channel -> alias 'short'\$"   && ok || bad "d1 src"

# ---- e. exclusions --------------------------------------------------------
echo "-- (e) exclusions --"
FLAT="$TMP/flat.toml"
printf 'channel = "c"\nexclude = ["one", "two", " three "]\n' > "$FLAT"
expect_driver "e1-flat" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01
echo "$OUT" | grep -q '^excl_count=3$'              && ok || bad "e1 count"
echo "$OUT" | grep -q '^excl=one|src=config exclude$'     && ok || bad "e1 one"
echo "$OUT" | grep -q '^excl=two|src=config exclude$'     && ok || bad "e1 two"
echo "$OUT" | grep -q '^excl=three|src=config exclude$'   && ok || bad "e1 three"
echo "$OUT" | grep -q '^excl_sources=config exclude$'      && ok || bad "e1 sources"

GRP="$TMP/grp.toml"
cat > "$GRP" <<'EOF'
channel = "c"
[exclude]
bots = ["spammy", "nasty"]
mods = ["mod1"]
always = ["bots"]
EOF
expect_driver "e2-groups-always" --config "$GRP" -c c -e 2026-09-01 -b 2026-09-01
echo "$OUT" | grep -q '^excl_count=2$'              && ok || bad "e2 count"
echo "$OUT" | grep -q '^excl=spammy|src=config always:bots$' && ok || bad "e2 spammy"
echo "$OUT" | grep -q '^excl_sources=config always:bots$'    && ok || bad "e2 sources"

expect_driver "e3-exclude-group" --config "$GRP" -c c -e 2026-09-01 -b 2026-09-01 -g mods
echo "$OUT" | grep -q '^excl=mod1|src=--exclude-group mods$'  && ok || bad "e3 mod1"
echo "$OUT" | grep -q '^excl_sources=config always:bots, --exclude-group mods$' && ok || bad "e3 sources"

expect_driver "e4-env-exclude" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01
ENVOUT=$(TWITCH_EXCLUDE="envbot1, envbot2 envbot3" "$HERE/$BIN" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$ENVOUT" | grep -q '^excl=envbot1|src=env TWITCH_EXCLUDE$' && ok || bad "e4 envbot1"
echo "$ENVOUT" | grep -q '^excl_sources=config exclude, env TWITCH_EXCLUDE$' && ok || bad "e4 sources"

expect_driver "e5-cli-exclude" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 -x "cli1 cli2" -x cli3
echo "$OUT" | grep -q '^excl=cli1|src=--exclude$'  && ok || bad "e5 cli1"
echo "$OUT" | grep -q '^excl=cli3|src=--exclude$'  && ok || bad "e5 cli3"
echo "$OUT" | grep -q '^excl_sources=config exclude, --exclude$' && ok || bad "e5 sources"

expect_driver "e6-broadcaster" --config "$FLAT" -c MyChannel -e 2026-09-01 -b 2026-09-01 --exclude-broadcaster
echo "$OUT" | grep -q '^excl=mychannel|src=--exclude-broadcaster$' && ok || bad "e6 bcast"
echo "$OUT" | grep -q '^excl_sources=config exclude, --exclude-broadcaster$' && ok || bad "e6 sources"

expect_driver "e7-include" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 --include two
echo "$OUT" | grep -q '^excl_count=2$'              && ok || bad "e7 count"
echo "$OUT" | grep -q '^excl_sources=config exclude, minus --include (1)$' && ok || bad "e7 sources"

expect_driver "e8-include-all" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 --include one,two --include three
echo "$OUT" | grep -q '^excl_count=0$'              && ok || bad "e8 count"
echo "$OUT" | grep -q '^excl_sources=config exclude, minus --include (3)$' && ok || bad "e8 sources"

expect_driver "e9-noexclude-clear" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 --no-exclude
echo "$OUT" | grep -q '^excl_count=0$'              && ok || bad "e9 count"
echo "$OUT" | grep -q '^excl_sources=$'             && ok || bad "e9 sources"

expect_driver "e10-alias-broadcaster" --config "$CFG" -c short -e 2026-09-01 -b 2026-09-01 --exclude-broadcaster
echo "$OUT" | grep -q '^excl=realchan|src=--exclude-broadcaster$' && ok || bad "e10 aliased bcast"

# ---- g. differential vs python3 -------------------------------------------
echo "-- (g) differential vs python3 twitch-counts.py --"
LOGS="$TMP/logs"
cat > "$LOGS/mychannel/mychannel-2026-09-01.log" <<'EOF'
[12:00:00] alice: hello world
[12:00:01] bob: hi there
[12:00:02] mychannel is live!
[12:00:03] alice: second message
[12:00:04] spammy: go away
[12:00:05] bot_a: beep
EOF

# split_env ARGS... -> sets DIFF_ENV (env assignments) and DIFF_FLAGS (flags)
split_env() {
    DIFF_ENV=()
    DIFF_FLAGS=()
    local a
    for a in "$@"; do
        case "$a" in
            *=*) DIFF_ENV+=("$a") ;;
            *)   DIFF_FLAGS+=("$a") ;;
        esac
    done
}

py_query() {
    # py_query [ENVVAR=val]... [ARG]...  -> prints excluded=... / exclude=...
    split_env "$@"
    local pout
    pout=$(env "${DIFF_ENV[@]}" python3 twitch-counts.py --json -d "$LOGS" -c mychannel \
        -b 2026-09-01 -e 2026-09-01 --top 50 "${DIFF_FLAGS[@]}" 2>/dev/null)
    if ! printf '%s\n' "$pout" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null; then
        echo 'excluded=PY-NONJSON'
        echo 'exclude=PY-NONJSON'
        return
    fi
    printf '%s\n' "$pout" | python3 -c "
import json,sys
d=json.load(sys.stdin)
q=d['query']
print('excluded=' + ','.join(sorted(q['excluded'])))
print('exclude=' + q['sources'].get('exclude','MISSING'))
print('channel=' + q['sources'].get('channel','MISSING'))
"
}

diff_case() {
    local name=$1; shift
    # remaining args: [ENVVAR=val]... [ARG]...  applied to BOTH sides
    split_env "$@"
    local pyout asmout
    pyout=$(py_query "$@")
    asmout=$(env "${DIFF_ENV[@]}" "$HERE/$BIN" -c mychannel -d "$LOGS" -b 2026-09-01 -e 2026-09-01 --top 50 "${DIFF_FLAGS[@]}" 2>&1)
    local py_excl py_src asm_excl asm_src
    py_excl=$(printf '%s\n' "$pyout" | sed -n 's/^excluded=//p')
    py_src=$(printf '%s\n' "$pyout" | sed -n 's/^exclude=//p')
    asm_excl=$(printf '%s\n' "$asmout" | sed -n 's/^excl=\([^|]*\)|.*/\1/p' | sort | tr '\n' ',' | sed 's/,$//')
    asm_src=$(printf '%s\n' "$asmout" | sed -n 's/^excl_sources=//p')
    [ -z "$asm_src" ] && asm_src="none"
    if [ "$py_excl" != "$asm_excl" ]; then
        DIFF_FAIL=$((DIFF_FAIL+1)); echo "  DIFF $name excluded: py=[$py_excl] asm=[$asm_excl]"
    else
        ok
    fi
    if [ "$py_src" != "$asm_src" ]; then
        DIFF_FAIL=$((DIFF_FAIL+1)); echo "  DIFF $name exclude-sources: py=[$py_src] asm=[$asm_src]"
    else
        ok
    fi
}

diff_case dg1-flat --config "$TMP/flat.toml"
diff_case dg2-groups --config "$GRP"
diff_case dg3-group-cli --config "$GRP" -g mods
diff_case dg4-env TWITCH_EXCLUDE="envbot1, envbot2" --config "$TMP/flat.toml"
diff_case dg5-cli -x "clix, cliy" --config "$TMP/flat.toml"
diff_case dg6-bcast --exclude-broadcaster --config "$TMP/flat.toml"
diff_case dg7-include --include two --config "$TMP/flat.toml"
diff_case dg8-noexclude --no-exclude --config "$TMP/flat.toml"

# error-message differential: exit codes + normalized stderr
err_diff() {
    local name=$1; shift
    local py_out py_rc asm_out asm_rc
    py_out=$(python3 twitch-counts.py "$@" 2>&1); py_rc=$?
    asm_out=$("$HERE/$BIN" "$@" 2>&1); asm_rc=$?
    if [ "$py_rc" -ne "$asm_rc" ]; then
        DIFF_FAIL=$((DIFF_FAIL+1)); echo "  DIFF $name exit: py=$py_rc asm=$asm_rc"
        return
    fi
    [ "$py_rc" -eq 0 ] && { ok; return; }
    local pn an tmp_pat
    tmp_pat=$(printf 's#%s#CFGDIR#g' "$TMP")
    pn=$(printf '%s\n' "$py_out" | sed "$tmp_pat" | tr -s ' \n' ' ' | sed 's/twitch-counts\.py/PROG/g' | sed 's/[[:space:]]*$//')
    an=$(printf '%s\n' "$asm_out" | sed "$tmp_pat" | tr -s ' \n' ' ' | sed 's/tc-config-test/PROG/g' | sed 's/[[:space:]]*$//')
    if [ "$pn" = "$an" ]; then ok; else
        DIFF_FAIL=$((DIFF_FAIL+1))
        echo "  DIFF $name text:"
        echo "    py : $pn"
        echo "    asm: $an"
    fi
}

err_diff de1-missing --config "$TMP/nope.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01
err_diff de2-watch-table --config "$TMP/watchstr.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01
err_diff de3-aliases-table --config "$TMP/aliasstr.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01
err_diff de4-exclude-shape --config "$TMP/exclstr.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01
err_diff de5-group-not-list --config "$TMP/exclfoo.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01
err_diff de6-always-not-list --config "$TMP/exclalw.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01
err_diff de7-always-unknown --config "$TMP/exclunk.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01
err_diff de8-unknown-group --config "$GRP" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01 -g ghosts
err_diff de9-noexcl --config "$TMP/flat.toml" -d "$LOGS" -c mychannel -b 2026-09-01 -e 2026-09-01 --no-exclude -x a
# bad TOML: prefix identical, engine text differs (tomlc99 vs tomllib) — compare the prefix only
run_case "de10-bad-toml" --config "$TMP/bad.toml" -c foo -e 2026-09-01 -b 2026-09-01
if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF "could not read config $TMP/bad.toml: "; then
    ok
else
    bad "de10 bad-toml prefix"
fi

# ---------------------------------------------------------------------------
rm -rf "$TMP"
echo
echo "Summary: $PASS passed, $FAIL failed"
if [ "$DIFF_FAIL" -gt 0 ]; then
    echo "differential: $DIFF_FAIL mismatches"
fi
[ "$FAIL" -eq 0 ] && [ "$DIFF_FAIL" -eq 0 ]