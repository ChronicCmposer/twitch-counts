#!/bin/sh
# test-twitch-counts-full.sh — verify the REAL twitch-counts-full binary
# (the full AArch64 port of twitch-counts.py).
#
# The binary under test is NOT built here.  It is resolved as
# "$BUILD/twitch-counts-full", where BUILD defaults to
# build/<os> (os = `uname -s` lowercased) and can be overridden with
# TC_BUILD (the Makefile exports TC_BUILD=build/<os> when it drives this
# script via `make test`).  Run `make twitch-counts-full` first if it is
# missing.
#
# Every invocation of the binary runs with HOME, XDG_CONFIG_HOME and
# XDG_CACHE_HOME pointed at a per-run mktemp directory, so it can never
# read or write the real user's ~/.config/twitch-counts.toml or
# ~/.cache/twitch-counts/rollup.db (the assembly honours XDG_CONFIG_HOME /
# XDG_CACHE_HOME, falling back to $HOME/.config or $HOME/.cache).
#
# Builds a synthetic Chatterino log tree under that isolated HOME and
# checks the main() dispatch surface end to end:
#   1. --manual prints the manual and exits 0
#   2. --emit-fish-completions exits 0 and carries a completion for a real flag
#   3. --complete with a logs dir returns candidates and exits 0
#   4. -h prints the usage and exits 0
#   5. no args -> "error: no channel given ..." on stderr, exit 1
#   6. an end-to-end run prints the header + table + footer shape, exit 0
#   7. --json output parses with `python3 -m json.tool` (from PATH)
#   8. --watch on a non-tty prints the needs-a-terminal error, exit 1
#
# Prints PASS/FAIL per check and exits nonzero on any failure.
set -u
. "$(dirname "$0")/tc-test-lib.sh"
tc_here

# ---------------------------------------------------------------------------
# resolve the driver: $BUILD/twitch-counts-full, no in-script build.
# ---------------------------------------------------------------------------
tc_build_dir
BIN=$(tc_driver twitch-counts-full) || exit 2
tmpdir=$(tc_sandbox tc-full-test)

channels="$tmpdir/Logs/Twitch/Channels"
mkdir -p "$channels/chroniccmposer"

# --- synthetic channel logs ------------------------------------------------
cat > "$channels/chroniccmposer/chroniccmposer-2026-09-01.log" << 'EOF'
[15:15:30] ChronicCmposer is live!
[15:15:33] alice: hello world
[15:15:34] bob: hi alice
[15:16:02] carol: testing
[15:17:00] ChronicCmposer is now offline.
EOF

cat > "$channels/chroniccmposer/chroniccmposer-2026-09-02.log" << 'EOF'
[15:10:00] ChronicCmposer is live!
[15:10:05] alice: day two
[15:11:00] bob: second day
[15:12:00] alice: more
[15:13:00] dave: newcomer
[15:14:00] ChronicCmposer is now offline.
EOF

# --- isolation: HOME + XDG_CONFIG_HOME + XDG_CACHE_HOME never touch the
# real user's ~/.config/twitch-counts.toml or ~/.cache/twitch-counts. -------
export HOME="$tmpdir/home"
export XDG_CONFIG_HOME="$tmpdir/xdg-config"
export XDG_CACHE_HOME="$tmpdir/xdg-cache"
tc_require_python_tomllib          # the first python3 call runs isolated
mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"

# --- Check 1: --manual -------------------------------------------------------
"$BIN" --manual >"$tmpdir/manual.out" 2>"$tmpdir/manual.err"
rc=$?
ok=0
[ "$rc" -eq 0 ] &&
    [ ! -s "$tmpdir/manual.err" ] &&
    grep -q "Count Chatterino-logged chat messages per user" "$tmpdir/manual.out" && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/manual.err")"
ok_or_fail "--manual prints the manual and exits 0" "$ok"

# --- Check 2: --emit-fish-completions ----------------------------------------
"$BIN" --emit-fish-completions >"$tmpdir/fish.out" 2>"$tmpdir/fish.err"
rc=$?
ok=0
[ "$rc" -eq 0 ] &&
    [ ! -s "$tmpdir/fish.err" ] &&
    grep -q "complete -c twitch-counts -s c -l channel" "$tmpdir/fish.out" && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/fish.err")"
ok_or_fail "--emit-fish-completions carries a real flag line and exits 0" "$ok"

# --- Check 3: --complete with a logs dir -------------------------------------
"$BIN" --no-config --no-cache -c chroniccmposer \
    -d "$channels" --complete channels >"$tmpdir/comp.out" 2>"$tmpdir/comp.err"
rc=$?
ok=0
[ "$rc" -eq 0 ] &&
    [ ! -s "$tmpdir/comp.err" ] &&
    grep -q "chroniccmposer" "$tmpdir/comp.out" && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/comp.err")"
ok_or_fail "--complete channels returns candidates and exits 0" "$ok"

# --- Check 4: -h -------------------------------------------------------------
"$BIN" -h >"$tmpdir/help.out" 2>"$tmpdir/help.err"
rc=$?
ok=0
[ "$rc" -eq 0 ] && grep -q "usage: twitch-counts-full" "$tmpdir/help.out" && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc"
ok_or_fail "-h prints the usage and exits 0" "$ok"

# --- Check 5: no args --------------------------------------------------------
"$BIN" >"$tmpdir/noargs.out" 2>"$tmpdir/noargs.err"
rc=$?
ok=0
[ "$rc" -eq 1 ] &&
    [ ! -s "$tmpdir/noargs.out" ] &&
    grep -q "error: no channel given" "$tmpdir/noargs.err" && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/noargs.err")"
ok_or_fail "no args errors 'no channel given' on stderr, exit 1" "$ok"

# --- Check 6: end-to-end run shape -------------------------------------------
"$BIN" --no-config --no-cache -c chroniccmposer -d "$channels" \
    -e 2026-09-01 >"$tmpdir/e2e.out" 2>"$tmpdir/e2e.err"
rc=$?
ok=0
[ "$rc" -eq 0 ] &&
    [ ! -s "$tmpdir/e2e.err" ] &&
    grep -q "^channel:    chroniccmposer" "$tmpdir/e2e.out" &&
    grep -q "^user   count" "$tmpdir/e2e.out" &&
    grep -q "^-----  -----" "$tmpdir/e2e.out" &&
    grep -q "^3 of 3 user(s); 3 of 3 message(s) in range" "$tmpdir/e2e.out" && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/e2e.err")"
ok_or_fail "end-to-end run prints header + table + footer, exit 0" "$ok"

# --- Check 7: --json parses --------------------------------------------------
"$BIN" --no-config --no-cache -c chroniccmposer -d "$channels" \
    -e 2026-09-01 --json >"$tmpdir/json.out" 2>"$tmpdir/json.err"
rc=$?
python3 -m json.tool "$tmpdir/json.out" >"$tmpdir/json.pretty" 2>"$tmpdir/json.tool.err"
jrc=$?
ok=0
[ "$rc" -eq 0 ] && [ "$jrc" -eq 0 ] && [ ! -s "$tmpdir/json.err" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc json.tool rc=$jrc stderr=$(cat "$tmpdir/json.err")"
ok_or_fail "--json output parses with python3 -m json.tool" "$ok"

# --- Check 8: --watch on a non-tty -------------------------------------------
"$BIN" --no-config --no-cache -c chroniccmposer -d "$channels" \
    -w 0.2 >"$tmpdir/watch.out" 2>"$tmpdir/watch.err"
rc=$?
ok=0
[ "$rc" -eq 1 ] &&
    grep -q "error: --watch needs a terminal" "$tmpdir/watch.err" && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc stderr=$(cat "$tmpdir/watch.err")"
ok_or_fail "--watch on a non-tty errors and exits 1" "$ok"

# --- Summary ----------------------------------------------------------------
tc_summary
