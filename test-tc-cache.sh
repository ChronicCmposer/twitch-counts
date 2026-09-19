#!/bin/sh
# test-tc-cache.sh — Phase 6 test driver for tc_cache.S (twitch-counts-full).
#
# Builds a synthetic Chatterino log tree in a mktemp dir and checks the SQLite
# rollup cache end to end:
#   (a) cold run: parses everything (parsed>0, reused=0), rollup.db is created
#       with the 4 schema tables, rebuilt reason "new cache"
#   (b) warm run: reuses the cached days (reused>0, parsed=0) with identical
#       counts
#   (c) append to a log -> that day's row is invalid -> only that day reparses
#   (d) change the entering state (edit an earlier day's marker) -> the
#       affected days reparse (size/mtime + enter-state cascade)
#   (e) --no-cache -> no db is touched
#   (f) --rebuild-cache -> purges the channel then reparses everything
#   (g) corrupt the db -> cache unavailable with a named problem, the query
#       still succeeds
#   (h) generations: fingerprint-tagged rows coexist (bump the fingerprint
#       constant in a scratch copy: generation count grows, both tags remain,
#       and each generation reuses its own rows)
#   (i) differential vs python3 twitch-counts.py (isolated XDG_CACHE_HOME):
#       cold->warm transitions and the header cache-row strings.  Each side
#       runs on its OWN cache (the fingerprint VALUE differs by design).
#
# The binary under test is tc-cache-test (check_tc_cache.o + tc_cache.o +
# tc_core.o + tc_cli.o + tc_config.o + tc_util.o + toml.o + sqlite3.o), linked
# with the exact commands the Phase-6 spec allows.
set -u

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/tc-cache-test.XXXXXX") || {
    echo "FAIL: cannot create temp directory"
    exit 2
}
trap 'rm -rf "$tmpdir"' EXIT INT TERM

channels="$tmpdir/Logs/Twitch/Channels"
home="$tmpdir/home"
pycache="$tmpdir/pycache"
mkdir -p "$channels/chroniccmposer" "$home" "$pycache"

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

# --- synthetic channel logs (three whole days) -------------------------------
cd "$channels/chroniccmposer" || exit 2
cat > chroniccmposer-2026-09-01.log << 'EOF'
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
cat > chroniccmposer-2026-09-02.log << 'EOF'
[15:10:00] ChronicCmposer is live!
[15:10:05] alice: day two
[15:11:00] bob: second day
[15:12:00] alice: more
[15:13:00] dave: newcomer
[15:14:00] ChronicCmposer is now offline.
EOF
cat > chroniccmposer-2026-09-03.log << 'EOF'
[16:00:00] ChronicCmposer is live!
[16:00:01] alice: third day
[16:00:02] bob: third day too
[16:00:03] alice: more more
[16:01:00] ChronicCmposer is now offline.
EOF

cd "$tmpdir" || exit 2
BIN=/var/lib/opencode/dev/shirley-asm/tc-cache-test
PY=/var/lib/opencode/dev/shirley-asm/twitch-counts.py
DB="$home/.cache/twitch-counts/rollup.db"

run() { # run <outfile> [extra args...]
    out="$1"; shift
    XDG_CACHE_HOME="" HOME="$home" "$BIN" -c chroniccmposer -d "$channels" \
        -e 2026-09-03 "$@" >"$out" 2>"$tmpdir/e"
}

# ============================================================================
# (a) cold run
# ============================================================================
run "$tmpdir/cold.out"
used=$(sed -n 's/^cachestatus used=\([0-9]*\).*/\1/p' "$tmpdir/cold.out")
reused=$(sed -n 's/^cachestatus used=[0-9]* reused=\([0-9]*\).*/\1/p' "$tmpdir/cold.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/cold.out")
rebuilt=$(sed -n 's/^cachestatus .*rebuilt=\([^ ]*\).*/\1/p' "$tmpdir/cold.out")
ok=0
[ "$used" = "1" ] && [ "$reused" = "0" ] && [ "$parsed" = "3" ] && \
    [ "$rebuilt" = "new" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: used=$used reused=$reused parsed=$parsed rebuilt=$rebuilt"
ok_or_fail "a1. cold run parses everything, rebuilt='new cache'" "$ok"

tables=$(sed -n 's/^cachetables //p' "$tmpdir/cold.out")
ok=1
for t in meta generation file counts; do
    case "$tables" in *"$t"*) true ;; *) ok=0 ;; esac
done
[ "$ok" -eq 0 ] && echo "  detail: tables='$tables'"
ok_or_fail "a2. rollup.db has meta/generation/file/counts tables" "$ok"
ok=0
[ -f "$DB" ] && ok=1
ok_or_fail "a3. rollup.db exists at \$HOME/.cache/twitch-counts/" "$ok"

# ============================================================================
# (b) warm run
# ============================================================================
run "$tmpdir/warm.out"
used=$(sed -n 's/^cachestatus used=\([0-9]*\).*/\1/p' "$tmpdir/warm.out")
reused=$(sed -n 's/^cachestatus used=[0-9]* reused=\([0-9]*\).*/\1/p' "$tmpdir/warm.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/warm.out")
rebuilt=$(sed -n 's/^cachestatus .*rebuilt=\([^ ]*\).*/\1/p' "$tmpdir/warm.out")
ok=0
[ "$used" = "1" ] && [ "$reused" = "3" ] && [ "$parsed" = "0" ] && \
    [ "$rebuilt" = "-" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: used=$used reused=$reused parsed=$parsed rebuilt=$rebuilt"
ok_or_fail "b1. warm run reuses all 3 days (reused=3 parsed=0)" "$ok"

cold_users=$(sed -n '/^users [0-9]/,/^tally/p' "$tmpdir/cold.out" | grep -v '^tally' | sort)
warm_users=$(sed -n '/^users [0-9]/,/^tally/p' "$tmpdir/warm.out" | grep -v '^tally' | sort)
ok=0
[ "$cold_users" = "$warm_users" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: users differ"
printf '%s\n' "$cold_users" > "$tmpdir/cold.users"
printf '%s\n' "$warm_users" > "$tmpdir/warm.users"
diff "$tmpdir/cold.users" "$tmpdir/warm.users" | head -5
ok_or_fail "b2. warm user table identical to cold" "$ok"
cold_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/cold.out")
cold_s=$(sed -n 's/^tally .*states=\([0-9:]*\).*/\1/p' "$tmpdir/cold.out")
warm_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/warm.out")
warm_s=$(sed -n 's/^tally .*states=\([0-9:]*\).*/\1/p' "$tmpdir/warm.out")
ok=0
[ "$cold_m" = "$warm_m" ] && [ "$cold_s" = "$warm_s" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: cold m=$cold_m s=$cold_s warm m=$warm_m s=$warm_s"
ok_or_fail "b3. warm tally totals identical to cold" "$ok"

# ============================================================================
# (c) append to a log -> that day reparses
# ============================================================================
printf '[15:18:00] eve: appended\n' >> "$channels/chroniccmposer/chroniccmposer-2026-09-02.log"
run "$tmpdir/append.out"
reused=$(sed -n 's/^cachestatus used=[0-9]* reused=\([0-9]*\).*/\1/p' "$tmpdir/append.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/append.out")
eve=$(sed -n 's/^eve \(.*\)$/\1/p' "$tmpdir/append.out")
msg=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/append.out")
ok=0
[ "$reused" = "2" ] && [ "$parsed" = "1" ] && [ "$eve" = "0 1 0" ] && \
    [ "$msg" = "14" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: reused=$reused parsed=$parsed eve='$eve' msg=$msg"
ok_or_fail "c1. append invalidates that day; only it reparses" "$ok"

# ============================================================================
# (d) change the entering state: edit 09-01's LAST marker (offline -> live).
#     09-01's exit_state changes -> 09-02's enter_state no longer matches ->
#     both reparse; 09-03's enter is unchanged (09-02 still ends offline).
# ============================================================================
sed -i 's/\[15:17:00\] ChronicCmposer is now offline./[15:17:00] ChronicCmposer is live!/' \
    "$channels/chroniccmposer/chroniccmposer-2026-09-01.log"
run "$tmpdir/state.out"
reused=$(sed -n 's/^cachestatus used=[0-9]* reused=\([0-9]*\).*/\1/p' "$tmpdir/state.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/state.out")
ok=0
[ "$reused" = "1" ] && [ "$parsed" = "2" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: reused=$reused parsed=$parsed"
ok_or_fail "d1. entering-state change reparses 09-01 + 09-02" "$ok"
sed -i 's/\[15:17:00\] ChronicCmposer is live!/[15:17:00] ChronicCmposer is now offline./' \
    "$channels/chroniccmposer/chroniccmposer-2026-09-01.log"

# ============================================================================
# (e) --no-cache: no db touched
# ============================================================================
rm -rf "$home/.cache"
XDG_CACHE_HOME="" HOME="$home" "$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 --no-cache \
    > "$tmpdir/nocache.out" 2>"$tmpdir/e"
used=$(sed -n 's/^cachestatus used=\([0-9]*\).*/\1/p' "$tmpdir/nocache.out")
path=$(sed -n 's/^cachestatus .*path=\([^ ]*\).*/\1/p' "$tmpdir/nocache.out")
ok=0
[ "$used" = "0" ] && [ "$path" = "-" ] && [ ! -e "$home/.cache" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: used=$used path=$path cache-exists=$([ -e "$home/.cache" ] && echo yes || echo no)"
ok_or_fail "e1. --no-cache leaves no db" "$ok"

# ============================================================================
# (f) --rebuild-cache: purge + reparse
# ============================================================================
run "$tmpdir/rebuild.out" --rebuild-cache
used=$(sed -n 's/^cachestatus used=\([0-9]*\).*/\1/p' "$tmpdir/rebuild.out")
reused=$(sed -n 's/^cachestatus used=[0-9]* reused=\([0-9]*\).*/\1/p' "$tmpdir/rebuild.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/rebuild.out")
rebuilt=$(sed -n 's/^cachestatus .*rebuilt=\([^ ]*\).*/\1/p' "$tmpdir/rebuild.out")
ok=0
[ "$used" = "1" ] && [ "$reused" = "0" ] && [ "$parsed" = "3" ] && \
    [ "$rebuilt" = "--rebuild-cache" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: used=$used reused=$reused parsed=$parsed rebuilt=$rebuilt"
ok_or_fail "f1. --rebuild-cache purges and reparses" "$ok"

# ============================================================================
# (g) corrupt the db -> cache unavailable, query still succeeds
# ============================================================================
printf 'GARBAGE!not a sqlite database at all' > "$DB"
rm -f "$DB-wal" "$DB-shm"
run "$tmpdir/corrupt.out"
used=$(sed -n 's/^cachestatus used=\([0-9]*\).*/\1/p' "$tmpdir/corrupt.out")
problem=$(sed -n 's/^cachestatus .*problem=\([^ ]*\).*/\1/p' "$tmpdir/corrupt.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/corrupt.out")
msg=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/corrupt.out")
ok=0
[ "$used" = "0" ] && [ "$parsed" = "3" ] && [ "$msg" = "14" ] && ok=1
case "$problem" in connect*) true ;; *) ok=0 ;; esac
[ "$ok" -eq 0 ] && echo "  detail: used=$used problem='$problem' parsed=$parsed msg=$msg"
ok_or_fail "g1. corrupt db -> cache unavailable, query succeeds, problem named" "$ok"

# ============================================================================
# (h) fingerprint tagging + generation coexistence
# ============================================================================
# h1: every file row carries a 16-hex fingerprint and it is uniform
fps=$(sed -n 's/^cachefile \([0-9a-f]*\) .*/\1/p' "$tmpdir/warm.out" | sort -u)
ok=0
[ "$(printf '%s\n' "$fps" | wc -l)" = "1" ] && [ -n "$fps" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: fps='$fps'"
ok_or_fail "h1. file rows are tagged with one 16-hex fingerprint" "$ok"

# h2: bumping the fingerprint constant creates a second generation; both tag
#     values coexist in the db and the bumped binary reuses its own rows
rm -rf "$home/.cache"
run "$tmpdir/gen1.out"
fps1=$(sed -n 's/^cachefile \([0-9a-f]*\) .*/\1/p' "$tmpdir/gen1.out" | sort -u)
cp /var/lib/opencode/dev/shirley-asm/tc_layout.inc "$tmpdir/tc_layout.inc"
cp /var/lib/opencode/dev/shirley-asm/tc_cache.S "$tmpdir/tc_cache_bump.S"
sed -i 's/tc-cache-fp-v1/tc-cache-fp-v2/' "$tmpdir/tc_cache_bump.S"
as "$tmpdir/tc_cache_bump.S" -o "$tmpdir/tc_cache_bump.o"
/var/lib/opencode/dev/shirley-asm/third_party/musl/bin/musl-gcc -static \
    -o "$tmpdir/tc-cache-bump-test" \
    /var/lib/opencode/dev/shirley-asm/check_tc_cache.o \
    "$tmpdir/tc_cache_bump.o" \
    /var/lib/opencode/dev/shirley-asm/tc_core.o \
    /var/lib/opencode/dev/shirley-asm/tc_cli.o \
    /var/lib/opencode/dev/shirley-asm/tc_config.o \
    /var/lib/opencode/dev/shirley-asm/tc_util.o \
    /var/lib/opencode/dev/shirley-asm/third_party/tomlc99/toml.o \
    /var/lib/opencode/dev/shirley-asm/third_party/sqlite3/sqlite3.o \
    || { echo "FAIL: bump link failed"; fail=$((fail+1)); }
XDG_CACHE_HOME="" HOME="$home" "$tmpdir/tc-cache-bump-test" -c chroniccmposer \
    -d "$channels" -e 2026-09-03 > "$tmpdir/gen2.out" 2>"$tmpdir/e"
rebuilt=$(sed -n 's/^cachestatus .*rebuilt=\(.*\) path=.*/\1/p' "$tmpdir/gen2.out")
reused=$(sed -n 's/^cachestatus used=[0-9]* reused=\([0-9]*\).*/\1/p' "$tmpdir/gen2.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/gen2.out")
fps2=$(sed -n 's/^cachefile \([0-9a-f]*\) .*/\1/p' "$tmpdir/gen2.out" | sort -u)
gen=$(sed -n 's/^cachecounts [0-9]* generation=\([0-9]*\).*/\1/p' "$tmpdir/gen2.out")
ok=0
[ "$rebuilt" = "new parser generation" ] && [ "$reused" = "0" ] && \
    [ "$parsed" = "3" ] && [ "$gen" = "2" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rebuilt=$rebuilt reused=$reused parsed=$parsed gen=$gen fps1=$fps1 fps2=$fps2"
ok_or_fail "h2. fingerprint bump registers a new generation ('new parser generation')" "$ok"
ok=0
[ "$(printf '%s\n' $fps1 $fps2 | sort -u | wc -l)" = "2" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: fps1='$fps1' fps2='$fps2'"
ok_or_fail "h3. both generations' fingerprints coexist in the db" "$ok"
XDG_CACHE_HOME="" HOME="$home" "$tmpdir/tc-cache-bump-test" -c chroniccmposer \
    -d "$channels" -e 2026-09-03 > "$tmpdir/gen3.out" 2>"$tmpdir/e"
reused=$(sed -n 's/^cachestatus used=[0-9]* reused=\([0-9]*\).*/\1/p' "$tmpdir/gen3.out")
parsed=$(sed -n 's/^cachestatus .*parsed=\([0-9]*\) .*/\1/p' "$tmpdir/gen3.out")
ok=0
[ "$reused" = "3" ] && [ "$parsed" = "0" ] && ok=1
[ "$ok" -eq 0 ] && echo "  detail: reused=$reused parsed=$parsed"
ok_or_fail "h4. the bumped generation reuses its own rows on the next run" "$ok"

# ============================================================================
# (i) differential vs python3 (each side on its OWN cache)
# ============================================================================
if command -v python3 >/dev/null 2>&1; then
    # asm cold/warm numbers
    am_cold=$(sed -n 's/^cachestatus .*reused=\([0-9]*\) parsed=\([0-9]*\).*/reused=\1 parsed=\2/p' "$tmpdir/cold.out")
    am_warm=$(sed -n 's/^cachestatus .*reused=\([0-9]*\) parsed=\([0-9]*\).*/reused=\1 parsed=\2/p' "$tmpdir/warm.out")
    # python cold/warm on an isolated cache
    XDG_CACHE_HOME="$pycache" python3 "$PY" -c chroniccmposer -d "$channels" \
        -e 2026-09-03 --no-config > "$tmpdir/py.cold" 2>"$tmpdir/py.cold.err"
    py_cold=$(sed -n 's/.*cache: *\([0-9,]*\) day(s) reused, \([0-9,]*\) parsed.*/\1 \2/p' "$tmpdir/py.cold" | tr -d ',' | tail -1)
    py_cold_rebuilt=$(grep -o "rebuilt: [a-z -]*" "$tmpdir/py.cold" | tail -1)
    XDG_CACHE_HOME="$pycache" python3 "$PY" -c chroniccmposer -d "$channels" \
        -e 2026-09-03 --no-config > "$tmpdir/py.warm" 2>"$tmpdir/py.warm.err"
    py_warm=$(sed -n 's/.*cache: *\([0-9,]*\) day(s) reused, \([0-9,]*\) parsed.*/\1 \2/p' "$tmpdir/py.warm" | tr -d ',' | tail -1)
    py_rebuilt_on_warm=$(grep -c "rebuilt:" "$tmpdir/py.warm")
    ok=0
    [ "$py_cold" = "0 3" ] && [ "$py_warm" = "3 0" ] && ok=1
    [ "$ok" -eq 0 ] && echo "  detail: py_cold='$py_cold' py_warm='$py_warm'"
    ok_or_fail "i1. python cold->warm on its own cache (0 parsed then 3 reused)" "$ok"
    ok=0
    case "$py_cold_rebuilt" in *"new cache"*) true ;; *) false ;; esac && ok=1
    [ "$ok" -eq 0 ] && echo "  detail: py_cold_rebuilt='$py_cold_rebuilt'"
    ok_or_fail "i2. python cold header says 'rebuilt: new cache'" "$ok"
    ok=0
    [ "$py_rebuilt_on_warm" = "0" ] && ok=1
    ok_or_fail "i3. python warm header has no rebuilt reason (path shown)" "$ok"
    # totals agree between implementations on a fresh parsed run over the
    # SAME (current) logs: the python's cache is isolated, so both cold.
    home2="$tmpdir/home2"; mkdir -p "$home2"
    XDG_CACHE_HOME="" HOME="$home2" "$BIN" -c chroniccmposer -d "$channels" \
        -e 2026-09-03 > "$tmpdir/asm.freshcold" 2>"$tmpdir/e"
    py_m=$(sed -n 's/.*; \([0-9,]*\) of \([0-9,]*\) message(s) in range.*/\2/p' "$tmpdir/py.cold" | tr -d ',' | tail -1)
    am_m=$(sed -n 's/^tally .*messages=\([0-9]*\).*/\1/p' "$tmpdir/asm.freshcold")
    ok=0
    [ "$py_m" = "$am_m" ] && ok=1
    [ "$ok" -eq 0 ] && echo "  detail: py_m=$py_m am_m=$am_m"
    ok_or_fail "i4. python and asm count the same messages" "$ok"
    # asm rebuilt reasons match the python's vocabulary on each own cache
    ok=0
    [ "$(sed -n 's/^cachestatus .*rebuilt=\([^ ]*\).*/\1/p' "$tmpdir/cold.out")" = "new" ] && ok=1
    ok_or_fail "i5. asm cold reason is 'new cache' (same vocabulary)" "$ok"
else
    echo "NOTE: python3 not found; differential checks skipped"
fi

# --- Summary ----------------------------------------------------------------
echo
echo "Summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
