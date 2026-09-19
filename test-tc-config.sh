#!/usr/bin/env bash
# ============================================================================
# test-tc-config.sh — harness for the config/env/exclusion hooks.
#
# Uses the prebuilt config driver at $BUILD/tc-config-test (BUILD defaults
# to build/<os>, e.g. build/darwin or build/linux; override with TC_BUILD,
# as the Makefile does when it runs harnesses via 'make test'). Build it
# first with `make drivers` — this script does not build anything itself.
# Checks:
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
# The Python oracle is `python3 twitch-counts.py` from PATH (needs >= 3.11,
# checked below via tc-test-lib.sh's tc_require_python_tomllib).
#
# ISOLATION: this script protects the real ~/.config/twitch-counts.toml and
# ~/.cache/twitch-counts/rollup.db. HOME, XDG_CONFIG_HOME and XDG_CACHE_HOME
# are exported once, right after the per-run temp dir is created (see the
# "Fixtures" section below), to locations under that temp dir. Every driver
# and python3-oracle invocation for the rest of the script inherits them
# from the environment, so none can reach the real files.
#
# Usage: ./test-tc-config.sh
# ============================================================================
set -u
. "$(dirname "$0")/tc-test-lib.sh"
tc_here

tc_build_dir
PY=python3

DIFF_FAIL=0

# run_case NAME ARG...  -> exit code in $RC, stdout+stderr in $OUT
run_case() {
    local name=$1; shift
    OUT=$("$BIN" "$@" 2>&1); RC=$?
}

# expect_ok NAME ARG... — exit 0
expect_ok() {
    local name=$1; shift
    run_case "$name" "$@"
    if [ "$RC" -eq 0 ]; then ok "$name"; else
        bad "$name: expected exit 0, got $RC (args: $*)"; echo "$OUT" | tail -2
    fi
}

# expect_exit NAME WANT ARG...
expect_exit() {
    local name=$1 want=$2; shift 2
    run_case "$name" "$@"
    if [ "$RC" -eq "$want" ]; then ok "$name"; else
        bad "$name: exit $RC, want $want (args: $*)"; echo "$OUT" | tail -2
    fi
}

# expect_err NAME NEEDLE ARG... — exit 1 and stderr contains the needle
expect_err() {
    local name=$1 needle=$2; shift 2
    run_case "$name" "$@"
    if [ "$RC" -eq 1 ] && printf '%s' "$OUT" | grep -qF -- "$needle"; then ok "$name"; else
        bad "$name: want exit 1 + '$needle' (got rc=$RC, out: $(echo "$OUT" | tail -1))"
    fi
}

# expect_driver NAME ARG... — exit 0 and the driver output matches $OUT
expect_driver() {
    local name=$1; shift
    run_case "$name" "$@"
    if [ "$RC" -eq 0 ]; then ok "$name"; else
        bad "$name: expected exit 0, got $RC"; echo "$OUT" | tail -2
    fi
}

BIN=$(tc_driver tc-config-test) || exit 2

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
TMP=$(tc_sandbox tc-config-test)
# See "ISOLATION" in the header comment. HOME is isolated for both the
# driver's fallback path resolution and Python's MacOS platform class
# (which ignores XDG_* entirely and always uses HOME). XDG_CONFIG_HOME is
# left empty on purpose: the XDG spec (and tc_config.S) treat an empty
# value as "unset", so default-config-path resolution falls through to the
# isolated $HOME/.config -- this is exactly what the b4/DEFAULTOUT case
# below exercises, and it can never reach the real ~/.config since HOME is
# isolated. XDG_CACHE_HOME is pointed at an isolated directory in case a
# differential run's cache lookup ever honours XDG (Python's Linux class
# does; its MacOS class still just uses the isolated HOME).
export HOME="$TMP/home"
export XDG_CONFIG_HOME=
export XDG_CACHE_HOME="$TMP/xdg-cache"
tc_require_python_tomllib          # the first python3 call runs isolated
mkdir -p "$HOME" "$TMP/logs/mychannel" "$XDG_CACHE_HOME"
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
sed "s#DIR#$TMP/logs#g" "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

# ---- a. config resolution: values + sources -------------------------------
echo "-- (a) config file resolution --"
expect_driver "a1-top-level-values" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01
echo "$OUT" | grep -q '^min_count=7$'           && ok "a1 min_count" || bad "a1 min_count"
echo "$OUT" | grep -q '^top=20$'                && ok "a1 top" || bad "a1 top"
echo "$OUT" | grep -q '^sort=3$'                && ok "a1 sort" || bad "a1 sort"
echo "$OUT" | grep -q '^config_loaded=1$'       && ok "a1 loaded" || bad "a1 loaded"
echo "$OUT" | grep -q '^src=config$'            && ok "a1 config src" || bad "a1 config src"
echo "$OUT" | grep -q '^notify=0$'              && ok "a1 notify" || bad "a1 notify"
echo "$OUT" | grep -q '^max_events=6$'          && ok "a1 max_events" || bad "a1 max_events"
echo "$OUT" | grep -q '^seed_lookback=12$'      && ok "a1 seed_lookback" || bad "a1 seed_lookback"
echo "$OUT" | grep -q '^src=config \[tail\]$'   && ok "a1 tail src" || bad "a1 tail src"

expect_driver "a2-watch-section" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01 --watch
echo "$OUT" | grep -q '^shades=7$'              && ok "a2 shades" || bad "a2 shades"
echo "$OUT" | grep -q '^user_width=35$'         && ok "a2 user_width" || bad "a2 user_width"
echo "$OUT" | grep -q '^src=config \[watch\]$'  && ok "a2 watch src" || bad "a2 watch src"
# [watch] beats top-level: interval comes from top-level (2.5 = 0x4004000000000000)
echo "$OUT" | grep -q '^interval=4612811918334230528$' && ok "a2 interval" || bad "a2 interval"

# ---- b. precedence --------------------------------------------------------
echo "-- (b) precedence: CLI > env > config > default --"
expect_driver "b1-env-beats-config" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01
run_case "b1-env-beats-config" --config "$CFG" -c foo -e 2026-09-01 -b 2026-09-01
TWITCH_CHANNEL=envchan TWITCH_MIN_COUNT=9 "$BIN" --config "$CFG" -e 2026-09-01 -b 2026-09-01 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
    TWOUT=$(TWITCH_CHANNEL=envchan TWITCH_MIN_COUNT=9 "$BIN" --config "$CFG" -e 2026-09-01 -b 2026-09-01 2>&1)
    echo "$TWOUT" | grep -q '^channel=envchan$'      && ok "b1 channel" || bad "b1 channel"
    echo "$TWOUT" | grep -q '^chan_src=env TWITCH_CHANNEL$' && ok "b1 chan src" || bad "b1 chan src"
    echo "$TWOUT" | grep -q '^min_count=9$'          && ok "b1 min" || bad "b1 min"
    echo "$TWOUT" | grep -q '^src=env TWITCH_MIN_COUNT$' && ok "b1 min src" || bad "b1 min src"
else
    bad "b1 env run failed"
fi
CLIOUT=$(TWITCH_CHANNEL=envchan "$BIN" --config "$CFG" -c clichan -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$CLIOUT" | grep -q '^channel=clichan$'         && ok "b2 cli beats env" || bad "b2 cli beats env"
echo "$CLIOUT" | grep -q '^chan_src=--channel$'      && ok "b2 cli src" || bad "b2 cli src"
CFGOUT=$("$BIN" --config "$CFG" -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$CFGOUT" | grep -q '^min_count=7$'             && ok "b3 config beats default" || bad "b3 config beats default"
DEFAULTOUT=$("$BIN" -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$DEFAULTOUT" | grep -q '^min_count=1$'         && ok "b4 default" || bad "b4 default"
# TWITCH_COUNTS_CONFIG selects the file
TCC=$(TWITCH_COUNTS_CONFIG="$CFG" "$BIN" -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$TCC" | grep -q '^config_loaded=1$'            && ok "b5 env config path" || bad "b5 env config path"
echo "$TCC" | grep -q '^min_count=7$'                && ok "b5 env config value" || bad "b5 env config value"
# --no-config ignores everything
NC=$("$BIN" --no-config -c x -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$NC" | grep -q '^config_loaded=0$'             && ok "b6 no-config" || bad "b6 no-config"
echo "$NC" | grep -q '^min_count=1$'                 && ok "b6 no-config min" || bad "b6 no-config min"

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
echo "$OUT" | grep -q '^channel=realchan$'                       && ok "d1 channel" || bad "d1 channel"
echo "$OUT" | grep -q "^chan_src=--channel -> alias 'short'\$"   && ok "d1 src" || bad "d1 src"

# ---- e. exclusions --------------------------------------------------------
echo "-- (e) exclusions --"
FLAT="$TMP/flat.toml"
printf 'channel = "c"\nexclude = ["one", "two", " three "]\n' > "$FLAT"
expect_driver "e1-flat" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01
echo "$OUT" | grep -q '^excl_count=3$'              && ok "e1 count" || bad "e1 count"
echo "$OUT" | grep -q '^excl=one|src=config exclude$'     && ok "e1 one" || bad "e1 one"
echo "$OUT" | grep -q '^excl=two|src=config exclude$'     && ok "e1 two" || bad "e1 two"
echo "$OUT" | grep -q '^excl=three|src=config exclude$'   && ok "e1 three" || bad "e1 three"
echo "$OUT" | grep -q '^excl_sources=config exclude$'      && ok "e1 sources" || bad "e1 sources"

GRP="$TMP/grp.toml"
cat > "$GRP" <<'EOF'
channel = "c"
[exclude]
bots = ["spammy", "nasty"]
mods = ["mod1"]
always = ["bots"]
EOF
expect_driver "e2-groups-always" --config "$GRP" -c c -e 2026-09-01 -b 2026-09-01
echo "$OUT" | grep -q '^excl_count=2$'              && ok "e2 count" || bad "e2 count"
echo "$OUT" | grep -q '^excl=spammy|src=config always:bots$' && ok "e2 spammy" || bad "e2 spammy"
echo "$OUT" | grep -q '^excl_sources=config always:bots$'    && ok "e2 sources" || bad "e2 sources"

expect_driver "e3-exclude-group" --config "$GRP" -c c -e 2026-09-01 -b 2026-09-01 -g mods
echo "$OUT" | grep -q '^excl=mod1|src=--exclude-group mods$'  && ok "e3 mod1" || bad "e3 mod1"
echo "$OUT" | grep -q '^excl_sources=config always:bots, --exclude-group mods$' && ok "e3 sources" || bad "e3 sources"

expect_driver "e4-env-exclude" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01
ENVOUT=$(TWITCH_EXCLUDE="envbot1, envbot2 envbot3" "$BIN" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 2>&1)
echo "$ENVOUT" | grep -q '^excl=envbot1|src=env TWITCH_EXCLUDE$' && ok "e4 envbot1" || bad "e4 envbot1"
echo "$ENVOUT" | grep -q '^excl_sources=config exclude, env TWITCH_EXCLUDE$' && ok "e4 sources" || bad "e4 sources"

expect_driver "e5-cli-exclude" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 -x "cli1 cli2" -x cli3
echo "$OUT" | grep -q '^excl=cli1|src=--exclude$'  && ok "e5 cli1" || bad "e5 cli1"
echo "$OUT" | grep -q '^excl=cli3|src=--exclude$'  && ok "e5 cli3" || bad "e5 cli3"
echo "$OUT" | grep -q '^excl_sources=config exclude, --exclude$' && ok "e5 sources" || bad "e5 sources"

expect_driver "e6-broadcaster" --config "$FLAT" -c MyChannel -e 2026-09-01 -b 2026-09-01 --exclude-broadcaster
echo "$OUT" | grep -q '^excl=mychannel|src=--exclude-broadcaster$' && ok "e6 bcast" || bad "e6 bcast"
echo "$OUT" | grep -q '^excl_sources=config exclude, --exclude-broadcaster$' && ok "e6 sources" || bad "e6 sources"

expect_driver "e7-include" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 --include two
echo "$OUT" | grep -q '^excl_count=2$'              && ok "e7 count" || bad "e7 count"
echo "$OUT" | grep -q '^excl_sources=config exclude, minus --include (1)$' && ok "e7 sources" || bad "e7 sources"

expect_driver "e8-include-all" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 --include one,two --include three
echo "$OUT" | grep -q '^excl_count=0$'              && ok "e8 count" || bad "e8 count"
echo "$OUT" | grep -q '^excl_sources=config exclude, minus --include (3)$' && ok "e8 sources" || bad "e8 sources"

expect_driver "e9-noexclude-clear" --config "$FLAT" -c c -e 2026-09-01 -b 2026-09-01 --no-exclude
echo "$OUT" | grep -q '^excl_count=0$'              && ok "e9 count" || bad "e9 count"
echo "$OUT" | grep -q '^excl_sources=$'             && ok "e9 sources" || bad "e9 sources"

expect_driver "e10-alias-broadcaster" --config "$CFG" -c short -e 2026-09-01 -b 2026-09-01 --exclude-broadcaster
echo "$OUT" | grep -q '^excl=realchan|src=--exclude-broadcaster$' && ok "e10 aliased bcast" || bad "e10 aliased bcast"

# ---- h. platform config path resolution ------------------------------------
# macOS (uname -s = Darwin): the default config path is always
# $HOME/.config/twitch-counts.toml -- XDG_CONFIG_HOME is ignored entirely
# (unlike the Linux/else branch, which must honour it). HOME="" and an
# unset HOME both fall back the same way Python's os.path.expanduser does:
# HOME="" is treated as unset by expanduser and (like an unset HOME) falls
# through to the passwd entry -- except CPython's fallback keeps the
# computed "" prefix, landing on "/.config/twitch-counts.toml", while an
# actually-unset HOME lands on the passwd home's "~/.config/...". Both
# scenarios below stay read-only (default-path config resolution only,
# no log dir / cache access) precisely because an unset or empty HOME
# would otherwise resolve straight to the real account, defeating the
# isolation this script relies on elsewhere -- see the ISOLATION note.
echo "-- (h) platform config path resolution (Darwin) --"

is_darwin() { [ "$(uname -s)" = "Darwin" ]; }

# LOGS must exist, with a real log for channel "c" on the queried date,
# before h1/h2 run python3 --json: python3 errors out before ever reaching
# query.sources (the thing h1/h2 pin) if the logs dir has no matching log
# file, regardless of which config won. The full log fixtures used by
# section (g) are for a different channel/dir layout and are populated
# later; this h-local fixture is deliberately separate from that one.
LOGS="$TMP/logs"
mkdir -p "$LOGS/c"
cat > "$LOGS/c/c-2026-09-01.log" <<'EOF'
[12:00:00] alice: hello world
EOF

if is_darwin; then
    # h1: a config at $XDG_CONFIG_HOME must NOT be loaded when there is no
    # config at $HOME/.config -- the driver and python3 must both fall back
    # to their built-in defaults (config not found), never the XDG file.
    mkdir -p "$TMP/xdgcfg"
    cat > "$TMP/xdgcfg/twitch-counts.toml" <<'EOF'
channel = "c"
min_count = 99
EOF
    rm -f "$HOME/.config/twitch-counts.toml" 2>/dev/null
    H1=$(XDG_CONFIG_HOME="$TMP/xdgcfg" "$BIN" -c c -e 2026-09-01 -b 2026-09-01 2>&1)
    echo "$H1" | grep -q '^config_loaded=0$'   && ok "h1 asm: XDG config must not load (config_loaded)" || bad "h1 asm: XDG config must not load (config_loaded)"
    echo "$H1" | grep -q '^min_count=1$'       && ok "h1 asm: XDG config must not load (min_count default)" || bad "h1 asm: XDG config must not load (min_count default)"
    PYH1=$(XDG_CONFIG_HOME="$TMP/xdgcfg" "$PY" twitch-counts.py --json -c c -d "$LOGS" -e 2026-09-01 -b 2026-09-01 2>&1)
    printf '%s\n' "$PYH1" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['query']['sources']['min_count'])
" 2>/dev/null | grep -q '^built-in default$' && ok "h1 py: XDG config must not load (sources.min_count)" || bad "h1 py: XDG config must not load (sources.min_count)"

    # h2: a config at BOTH $XDG_CONFIG_HOME and $HOME/.config -- the
    # HOME/.config one must win; XDG is ignored, not merely lower priority.
    mkdir -p "$HOME/.config"
    cat > "$HOME/.config/twitch-counts.toml" <<'EOF'
channel = "c"
min_count = 5
EOF
    H2=$(XDG_CONFIG_HOME="$TMP/xdgcfg" "$BIN" -c c -e 2026-09-01 -b 2026-09-01 2>&1)
    echo "$H2" | grep -q '^config_loaded=1$'   && ok "h2 asm: HOME/.config must load" || bad "h2 asm: HOME/.config must load"
    echo "$H2" | grep -q '^min_count=5$'       && ok "h2 asm: HOME/.config value must win over XDG" || bad "h2 asm: HOME/.config value must win over XDG"
    PYH2=$(XDG_CONFIG_HOME="$TMP/xdgcfg" "$PY" twitch-counts.py --json -c c -d "$LOGS" -e 2026-09-01 -b 2026-09-01 2>&1)
    printf '%s\n' "$PYH2" | python3 -c "
import json,sys
d=json.load(sys.stdin)
print(d['query']['sources']['min_count'])
" 2>/dev/null | grep -q '^config$' && ok "h2 py: HOME/.config value must win over XDG" || bad "h2 py: HOME/.config value must win over XDG"
    rm -f "$HOME/.config/twitch-counts.toml"

    # h3/h4: HOME="" and an unset HOME must resolve to the SAME default
    # config path on both sides (no execution beyond path resolution / the
    # help text, so the real account is never touched). HOME="" keeps the
    # empty prefix ("/.config/..."); an unset HOME falls to the passwd
    # home ("~/.config/..." once shortened, since it prefixes the real
    # home). We only check that asm and python3 agree with EACH OTHER,
    # not a hardcoded path, since the passwd home varies by machine.
    # default_path_from_help TEXT -- pulls the "(default: ...)" value out of
    # a --help dump, tolerating the wrap onto a continuation line.
    default_path_from_help() {
        printf '%s' "$1" | tr -s ' \t\n' ' ' | \
            sed -n 's/.*--config CONFIG[^(]*(default: \([^)]*\)).*/\1/p'
    }

    ASM_EMPTY=$(default_path_from_help "$(HOME="" XDG_CONFIG_HOME= "$BIN" --help 2>&1)")
    PY_EMPTY=$(default_path_from_help "$(HOME="" XDG_CONFIG_HOME= "$PY" twitch-counts.py --help 2>&1)")
    if [ -n "$ASM_EMPTY" ] && [ -n "$PY_EMPTY" ]; then
        [ "$ASM_EMPTY" = "$PY_EMPTY" ] && ok "h3 HOME='' default path match" || \
            bad "h3 HOME='' default path mismatch: asm=[$ASM_EMPTY] py=[$PY_EMPTY]"
    else
        bad "h3 could not extract default-path text (asm=[$ASM_EMPTY] py=[$PY_EMPTY])"
    fi

    ASM_UNSET=$(default_path_from_help "$(env -u HOME XDG_CONFIG_HOME= "$BIN" --help 2>&1)")
    PY_UNSET=$(default_path_from_help "$(env -u HOME XDG_CONFIG_HOME= "$PY" twitch-counts.py --help 2>&1)")
    if [ -n "$ASM_UNSET" ] && [ -n "$PY_UNSET" ]; then
        [ "$ASM_UNSET" = "$PY_UNSET" ] && ok "h4 HOME-unset default path match" || \
            bad "h4 HOME-unset default path mismatch: asm=[$ASM_UNSET] py=[$PY_UNSET]"
    else
        bad "h4 could not extract default-path text (asm=[$ASM_UNSET] py=[$PY_UNSET])"
    fi
else
    echo "(skipped -- Linux else-branch behaviour cannot run here; covered by review of the bash syntax only)"
fi

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
    pout=$(env ${DIFF_ENV[@]+"${DIFF_ENV[@]}"} python3 twitch-counts.py --json -d "$LOGS" -c mychannel \
        -b 2026-09-01 -e 2026-09-01 --top 50 ${DIFF_FLAGS[@]+"${DIFF_FLAGS[@]}"} 2>/dev/null)
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
    asmout=$(env ${DIFF_ENV[@]+"${DIFF_ENV[@]}"} "$BIN" -c mychannel -d "$LOGS" -b 2026-09-01 -e 2026-09-01 --top 50 ${DIFF_FLAGS[@]+"${DIFF_FLAGS[@]}"} 2>&1)
    local py_excl py_src asm_excl asm_src
    py_excl=$(printf '%s\n' "$pyout" | sed -n 's/^excluded=//p')
    py_src=$(printf '%s\n' "$pyout" | sed -n 's/^exclude=//p')
    asm_excl=$(printf '%s\n' "$asmout" | sed -n 's/^excl=\([^|]*\)|.*/\1/p' | sort | tr '\n' ',' | sed 's/,$//')
    asm_src=$(printf '%s\n' "$asmout" | sed -n 's/^excl_sources=//p')
    [ -z "$asm_src" ] && asm_src="none"
    if [ "$py_excl" != "$asm_excl" ]; then
        DIFF_FAIL=$((DIFF_FAIL+1)); echo "  DIFF $name excluded: py=[$py_excl] asm=[$asm_excl]"
    else
        ok "$name excluded"
    fi
    if [ "$py_src" != "$asm_src" ]; then
        DIFF_FAIL=$((DIFF_FAIL+1)); echo "  DIFF $name exclude-sources: py=[$py_src] asm=[$asm_src]"
    else
        ok "$name exclude-sources"
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
    asm_out=$("$BIN" "$@" 2>&1); asm_rc=$?
    if [ "$py_rc" -ne "$asm_rc" ]; then
        DIFF_FAIL=$((DIFF_FAIL+1)); echo "  DIFF $name exit: py=$py_rc asm=$asm_rc"
        return
    fi
    [ "$py_rc" -eq 0 ] && { ok "$name"; return; }
    local pn an tmp_pat
    tmp_pat=$(printf 's#%s#CFGDIR#g' "$TMP")
    pn=$(printf '%s\n' "$py_out" | sed "$tmp_pat" | tr -s ' \n' ' ' | sed 's/twitch-counts\.py/PROG/g' | sed 's/[[:space:]]*$//')
    an=$(printf '%s\n' "$asm_out" | sed "$tmp_pat" | tr -s ' \n' ' ' | sed 's/tc-config-test/PROG/g' | sed 's/[[:space:]]*$//')
    if [ "$pn" = "$an" ]; then ok "$name"; else
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
    ok "de10-bad-toml"
else
    bad "de10 bad-toml prefix"
fi

# ---------------------------------------------------------------------------
tc_summary "$DIFF_FAIL"