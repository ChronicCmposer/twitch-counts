# ============================================================================
# tc-test-lib.sh — the scaffolding every test-tc-*.sh harness shares.
# ============================================================================
#
#   Sourced, never executed:
#
#       . "$(dirname "$0")/tc-test-lib.sh"
#
#   POSIX sh (bash 3.2 on macOS runs it too); the bash-only harnesses may
#   source it as well.  Nothing here builds anything: the Makefile owns
#   every driver link (`make drivers`), the harnesses only run the result.
#
#   Layout / environment
#     tc_here                     cd to the repository root (the harness's own
#                                 directory) and set TC_HERE to it.
#     tc_build_dir                set BUILD: $TC_BUILD when the Makefile
#                                 exports it, else build/<os>; always absolute.
#     tc_driver NAME              print "$BUILD/NAME", or print a FAIL line and
#                                 fail when it is missing or not executable.
#                                 It runs in a command substitution, so the
#                                 caller must propagate the failure:
#                                     BIN=$(tc_driver tc-core-test) || exit 2
#     tc_require_python_tomllib   exit 2 unless python3 on PATH is >= 3.11
#                                 (has tomllib) -- the oracle requirement.
#     tc_sandbox PREFIX           mktemp -d under $TMPDIR (or /tmp), removed
#                                 on EXIT/INT/TERM; prints the path.  A
#                                 harness that needs its own trap sets one
#                                 AFTER calling this (the later trap wins).
#     tc_isolate_home ROOT        export HOME=ROOT/home, XDG_CONFIG_HOME and
#                                 XDG_CACHE_HOME beneath it, so neither the
#                                 driver nor the Python oracle can reach the
#                                 real config or cache.  Call it before the
#                                 first python3 invocation.
#
#   Pass / fail bookkeeping (PASS, FAIL, TC_FAILED)
#     ok NAME                     count a pass;  prints "PASS: NAME"
#     bad NAME [DETAIL...]        count a failure; prints "FAIL: NAME" and one
#                                 "  detail: ..." line per extra argument
#     ok_or_fail NAME FLAG        FLAG 1 -> ok, 0 -> bad
#     check NAME EXPECTED ACTUAL  ok when the two strings are equal, else bad
#                                 with expected/got detail lines
#     tc_summary [EXTRA_FAILS]    print "Summary: N passed, M failed" (and the
#                                 failed names); return 1 on any failure or
#                                 when EXTRA_FAILS (e.g. a differential
#                                 mismatch count) is non-zero.  Harnesses end
#                                 with it so `make test` sees the status.
#
#   Text helpers
#     tc_strip_ansi FILE          the file's text with ANSI escapes removed,
#                                 CRLF split, trailing blanks and empty lines
#                                 dropped (pty transcripts).
# ============================================================================

PASS=0
FAIL=0
TC_FAILED=

tc_here() {
    TC_HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd) || exit 2
    cd "$TC_HERE" || exit 2
}

tc_build_dir() {
    BUILD=${TC_BUILD:-build/$(uname -s | tr A-Z a-z)}
    case $BUILD in
        /*) : ;;
        *)  BUILD="${TC_HERE:-$(pwd)}/$BUILD" ;;
    esac
}

tc_driver() { # BIN=$(tc_driver <name>) || exit 2
    [ -n "${BUILD:-}" ] || tc_build_dir
    if [ ! -x "$BUILD/$1" ]; then
        echo "FAIL: $BUILD/$1 not found or not executable -- run: make drivers" >&2
        return 2
    fi
    printf '%s\n' "$BUILD/$1"
}

tc_require_python_tomllib() {
    if ! python3 -c 'import tomllib' >/dev/null 2>&1; then
        echo "FAIL: python3 on PATH ($(command -v python3 2>/dev/null || echo none)," \
             "$(python3 --version 2>&1)) must be >= 3.11 with tomllib -- it is the oracle" >&2
        exit 2
    fi
}

tc_sandbox() { # tc_sandbox <prefix> -> prints a fresh directory, cleaned up on exit
    _tc_dir=$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX") || {
        echo "FAIL: mktemp -d failed" >&2
        exit 2
    }
    TC_SANDBOX=$_tc_dir
    trap 'rm -rf "$TC_SANDBOX"' EXIT INT TERM
    printf '%s\n' "$_tc_dir"
}

tc_isolate_home() { # tc_isolate_home <root>
    HOME="$1/home"
    XDG_CONFIG_HOME="$HOME/.config"
    XDG_CACHE_HOME="$HOME/.cache"
    export HOME XDG_CONFIG_HOME XDG_CACHE_HOME
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_CACHE_HOME"
}

ok() {
    PASS=$((PASS + 1))
    echo "PASS: $1"
}

bad() {
    FAIL=$((FAIL + 1))
    TC_FAILED="$TC_FAILED
  $1"
    echo "FAIL: $1"
    shift
    for _tc_detail in "$@"; do
        echo "  detail: $_tc_detail"
    done
}

ok_or_fail() { # ok_or_fail <name> <flag: 1=pass, 0=fail>
    if [ "$2" -ne 0 ]; then ok "$1"; else bad "$1"; fi
}

check() { # check <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        ok "$1"
    else
        bad "$1" "expected: $2" "got:      $3"
    fi
}

tc_summary() { # tc_summary [extra failure count]
    _tc_extra=${1:-0}
    echo
    echo "Summary: $PASS passed, $FAIL failed"
    [ -n "$TC_FAILED" ] && printf 'failed:%s\n' "$TC_FAILED"
    [ "$_tc_extra" -ne 0 ] && echo "differential: $_tc_extra mismatch(es)"
    [ "$FAIL" -eq 0 ] && [ "$_tc_extra" -eq 0 ]
}

tc_strip_ansi() { # tc_strip_ansi <file>
    python3 - "$1" <<'PYEOF'
import re, sys
txt = open(sys.argv[1], encoding="utf-8", errors="replace").read()
txt = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", txt)
print("\n".join(l.rstrip() for l in txt.split("\r\n") if l.strip()))
PYEOF
}
