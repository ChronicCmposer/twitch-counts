#!/bin/sh
# test-twitch-counts.sh — verify the AArch64 twitch-counts program.
#
# Builds a synthetic Chatterino log tree in a mktemp dir and asserts on the
# program's stdout, stderr and exit codes.  Self-contained: no python3.
#
# Checks (a..n):
#   a. basic run: exact header + sorted table + footer
#   b. -L filter and the state split in the header
#   c. -x exclusion + --include re-inclusion
#   d. --exclude-broadcaster
#   e. -m threshold drops a low user
#   f. -n 2 row cap: 2 rows, "+ N others" row, top:/footer accounting
#   g. -b/-e windowing: whole day, and mid-day second clipping
#   h. -S 1d -e 2026-09-03: a window spanning two days
#   i. --sort login and --by-state columns
#   j. thousands separators on a >999 count
#   k. localized display name counted under its login; system line and
#      per-stream log ignored
#   l. seed state: the previous day's marker seeds the next day's first
#      messages
#   m. error paths: missing --channel, missing --logs-dir, bad channel
#      (with available:), bad datetime, bad duration, conflicting -L -O,
#      --no-exclude + --exclude, unknown flag (usage, exit 1)
#   n. -h exits 0 and mentions --channel
set -u

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/twitch-counts-test.XXXXXX") || {
    echo "FAIL: cannot create temp directory"
    exit 2
}
trap 'rm -rf "$tmpdir"' EXIT INT TERM

channels="$tmpdir/Logs/Twitch/Channels"
mkdir -p "$channels/chroniccmposer" "$channels/powerchan"

# --- synthetic channel logs -------------------------------------------------
cd "$channels/chroniccmposer" || exit 2

# 08-31: a previous-day file whose marker seeds 09-01 (check l)
cat > chroniccmposer-2026-08-31.log << 'EOF'
[15:15:30] ChronicCmposer is live!
EOF

# 09-01: an early pre-marker message (seeded live), a live block, a localized
# display name, a system line and a comment that must all be ignored or mapped.
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

# a per-stream log that must be ignored by the dated-file matcher
cat > chroniccmposer-12345.log << 'EOF'
[15:00:00] ChronicCmposer is live!
EOF

# powerchan: a 1,234-message user for comma formatting (check j)
cd "$channels/powerchan" || exit 2
cat > powerchan-2026-09-01.log << 'EOF'
[10:00:00] powerchan is live!
EOF
i=0
while [ "$i" -lt 1234 ]; do
    printf '[10:00:01] power_user: msg %s\n' "$i" >> powerchan-2026-09-01.log
    i=$((i + 1))
done

cd "$tmpdir" || exit 2
BIN=/var/lib/opencode/dev/shirley-asm/twitch-counts
channels="Logs/Twitch/Channels"

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

# --- check a: basic run, exact stdout --------------------------------------
expected_a='channel:    chroniccmposer        [--channel]
logs dir:   Logs/Twitch/Channels  [--logs-dir]
begin:      2026-08-31 00:00:00   [default: earliest log file]
end:        2026-09-03 23:59:59   [--end]
threshold:  >= 1 message(s)       [built-in default]
state:      live 12 / offline 1   [not filtered]
files:      4 log file(s) in range

user        count
----------  -----
alice           5
bob             4
carol           1
choco_yoda      1
dave            1
early_seed      1
----------  -----
6 of 6 user(s); 13 of 13 message(s) in range'
actual=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 2>"$tmpdir/err_a")
rc=$?
ok=0
[ "$rc" -eq 0 ] && [ "$actual" = "$expected_a" ] && [ ! -s "$tmpdir/err_a" ] && ok=1
if [ "$ok" -eq 0 ]; then
    echo "  detail: rc=$rc"
    printf '%s\n' "$expected_a" > "$tmpdir/exp_a"
    printf '%s\n' "$actual" > "$tmpdir/act_a"
    diff -u "$tmpdir/exp_a" "$tmpdir/act_a" | head -20
fi
ok_or_fail "a. basic run matches expected stdout exactly" "$ok"

# --- check b: -L filter and state split -------------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -L 2>"$tmpdir/err_b")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"state:      live 12 / offline 1   [--live keeps live]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"bob"*"3"*"12 of 12 message(s) in range"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "b. -L filter shows state split and live-only counts" "$ok"

# --- check c: -x exclusion + --include re-inclusion -------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -x bob,carol --include bob 2>"$tmpdir/err_c")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"exclude:    1 login(s), 1 in range: carol  [--exclude, minus --include (1)]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"bob"*"4"*"excluded 1 user(s), 1 message(s) not counted"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "c. -x bob,carol --include bob keeps bob, excludes carol" "$ok"

# --- check d: --exclude-broadcaster ------------------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 --exclude-broadcaster 2>"$tmpdir/err_d")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"exclude:    1 login(s), 0 in range: chroniccmposer  [--exclude-broadcaster]"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "d. --exclude-broadcaster names the channel login" "$ok"

# --- check e: -m threshold ---------------------------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -m 4 2>"$tmpdir/err_e")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"threshold:  >= 4 message(s)       [--min-count]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"2 of 6 user(s); 9 of 13 message(s) in range"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "e. -m 4 drops the low users" "$ok"

# --- check f: -n 2 row cap ---------------------------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -n 2 2>"$tmpdir/err_f")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"top:        2 row(s), 4 hidden    [--top]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"+ 4 others"*"2 of 6 user(s) above threshold (6 in range); 9 of 13 message(s) in range"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "f. -n 2 caps the table with a + N others row" "$ok"

# --- check g: -b/-e windowing ------------------------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -b 2026-09-02 -e 2026-09-02 2>"$tmpdir/err_g1")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"begin:      2026-09-02 00:00:00   [--begin]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"3 of 3 user(s); 4 of 4 message(s) in range"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "g1. -b 2026-09-02 -e 2026-09-02 counts only that day" "$ok"

out=$("$BIN" -c chroniccmposer -d "$channels" -b "2026-09-02 12:00:00" -e "2026-09-02 13:00:00" 2>"$tmpdir/err_g2")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"No users met the threshold (0 message(s) in range)."*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "g2. mid-day window clips all of the day's messages out" "$ok"

# --- check h: -S 1d spanning two days -----------------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -S 1d -e 2026-09-03 2>"$tmpdir/err_h")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"begin:      2026-09-02 23:59:59   [--since 1d before end]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"2 of 2 user(s); 3 of 3 message(s) in range"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "h. -S 1d -e 2026-09-03 spans two days" "$ok"

# --- check i: --sort login and --by-state -------------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 --sort login 2>"$tmpdir/err_i1")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"sort:       login                 [--sort]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"alice"*"bob"*"carol"*"choco_yoda"*"dave"*"early_seed"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "i1. --sort login names the sort and orders by login" "$ok"

out=$("$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -B --share-floor 0 2>"$tmpdir/err_i2")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"columns:      count, live, offline, offline-share               [--by-state]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"bob"*"25.0%"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "i2. -B adds live/offline/offline% columns with correct shares" "$ok"

# --- check j: thousands separators ---------------------------------------------
out=$("$BIN" -c powerchan -d "$channels" -e 2026-09-01 2>"$tmpdir/err_j")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"power_user  1,234"*"1 of 1 user(s); 1,234 of 1,234 message(s) in range"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "j. counts get thousands separators (1,234)" "$ok"

# --- check k: localized name, system line, per-stream log -----------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -b 2026-09-01 -e 2026-09-01 2>"$tmpdir/err_k")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"choco_yoda      1"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"Restricted"*|*"반"*) false ;;
    *) true ;;
esac && \
case "$out" in
    *"12345"*"1 of"*"user(s)"*) false ;;
    *) true ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "k. localized login counted; system line and stream log ignored" "$ok"

# --- check l: seed state from the previous day ----------------------------------
out=$("$BIN" -c chroniccmposer -d "$channels" -b 2026-09-01 -e 2026-09-01 2>"$tmpdir/err_l")
rc=$?
ok=0
[ "$rc" -eq 0 ] && \
case "$out" in
    *"state:      live 5 / offline 1    [not filtered]"*) true ;;
    *) false ;;
esac && \
case "$out" in
    *"early_seed      1"*) true ;;
    *) false ;;
esac && ok=1
[ "$ok" -eq 0 ] && echo "  detail: rc=$rc" && printf '%s\n' "$out" | head -20
ok_or_fail "l. previous-day marker seeds the next day's pre-marker messages" "$ok"

# --- check m: error paths --------------------------------------------------------
"$BIN" -d "$channels" -e 2026-09-03 >"$tmpdir/out_m1" 2>"$tmpdir/err_m1"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m1" ] && \
case "$(cat "$tmpdir/err_m1")" in
    *"error: no channel given -- pass --channel"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m1. missing --channel errors to stderr, exit 1" "$ok"

"$BIN" -c chroniccmposer -e 2026-09-03 >"$tmpdir/out_m2" 2>"$tmpdir/err_m2"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m2" ] && \
case "$(cat "$tmpdir/err_m2")" in
    *"error: no logs directory given -- pass --logs-dir"*) true ;;
    *) false ;;
esac && \
case "$(cat "$tmpdir/err_m2")" in
    *"Chatterino is believed to use ~/.local/share/chatterino/Logs/Twitch/Channels"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m2. missing --logs-dir errors with the hint, exit 1" "$ok"

"$BIN" -c nope -d "$channels" -e 2026-09-03 >"$tmpdir/out_m3" 2>"$tmpdir/err_m3"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m3" ] && \
case "$(cat "$tmpdir/err_m3")" in
    *"error: no logs for channel 'nope' in "*"available: chroniccmposer, powerchan"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m3. bad channel prints available: list, exit 1" "$ok"

"$BIN" -c chroniccmposer -d "$channels" -b "2026-02-30" -e 2026-09-03 >"$tmpdir/out_m4" 2>"$tmpdir/err_m4"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m4" ] && \
case "$(cat "$tmpdir/err_m4")" in
    *"error: unrecognized datetime '2026-02-30'"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m4. bad datetime (2026-02-30) errors, exit 1" "$ok"

"$BIN" -c chroniccmposer -d "$channels" -S "5x" -e 2026-09-03 >"$tmpdir/out_m5" 2>"$tmpdir/err_m5"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m5" ] && \
case "$(cat "$tmpdir/err_m5")" in
    *"error: unrecognized duration '5x'"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m5. bad duration errors, exit 1" "$ok"

"$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 -L -O >"$tmpdir/out_m6" 2>"$tmpdir/err_m6"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m6" ] && \
case "$(cat "$tmpdir/err_m6")" in
    *"error: --live and --offline are mutually exclusive"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m6. -L -O conflict errors, exit 1" "$ok"

"$BIN" -c chroniccmposer -d "$channels" -e 2026-09-03 --no-exclude -x bob >"$tmpdir/out_m7" 2>"$tmpdir/err_m7"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m7" ] && \
case "$(cat "$tmpdir/err_m7")" in
    *"error: --no-exclude cannot be combined with --exclude"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m7. --no-exclude + --exclude conflict errors, exit 1" "$ok"

"$BIN" --bogus >"$tmpdir/out_m8" 2>"$tmpdir/err_m8"
rc=$?
ok=0
[ "$rc" -eq 1 ] && [ ! -s "$tmpdir/out_m8" ] && \
case "$(cat "$tmpdir/err_m8")" in
    *"usage: twitch-counts [options]"*) true ;;
    *) false ;;
esac && ok=1
ok_or_fail "m8. unknown flag prints usage to stderr, exit 1" "$ok"

# --- check n: -h exits 0 and mentions --channel ----------------------------------
"$BIN" -h >"$tmpdir/out_n" 2>"$tmpdir/err_n"
rc=$?
ok=0
[ "$rc" -eq 0 ] && [ ! -s "$tmpdir/err_n" ] && \
grep -q -- "--channel" "$tmpdir/out_n" && ok=1
ok_or_fail "n. -h exits 0 and mentions --channel" "$ok"

# --- Summary ---------------------------------------------------------------------
echo
echo "Summary: $pass passed, $fail failed"
[ "$fail" -eq 0 ]