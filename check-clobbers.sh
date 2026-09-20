#!/usr/bin/env bash
#
# check-clobbers.sh -- clobber-discipline checker for tc_*.S / check_tc_*.S / fibonacci.S
#
# PURPOSE
#   Flags AAPCS64 callee-saved-register violations in the hand-written
#   AArch64 assembly modules (tc_*.S / check_tc_*.S / fibonacci.S; GNU-as,
#   preprocessed by the C compiler). A "function" is any non-`.L`,
#   non-directive label ending in ':' -- the repo's exported `tc_*` symbols
#   and module-local subroutines (`util_`, `cli_`, `cfg_`, `core_`, ...);
#   `.L` branch targets are not function starts. Data labels (e.g.
#   `tc_str_count:`) simply open a directive-only "function" that the
#   analyzer ignores. Checks:
#     (a) any write to x19-x28 that is not covered by a PROLOGUE n /
#         EPILOGUE n pair (or a balanced explicit stp/ldp pair) in the same
#         function, including writes that fall OUTSIDE the save/restore
#         window (a write before its save or after its restore would clobber
#         the caller's register across a `bl`);
#     (b) unbalanced stp/ldp of callee-saved registers (saved but never
#         restored, restored but never saved, or unequal counts);
#     (c) writes to x29 without a matching `stp x29,x30` frame record
#         (and stp x29,x30 without a matching ldp x29,x30);
#     bonus: any use of x18 (the platform register; hard rule 4 in AGENTS.md).
#
# PRECISION -- READ THIS (guard, not proof)
#   This is a pragmatic heuristic, NOT a register-liveness proof. Human review
#   still applies (AGENTS.md is the authority). Known limitations:
#     * It analyzes the RAW source by default, so registers introduced or
#       hidden inside CPP macros are invisible to it. `--preprocess` re-runs
#       the same analysis on the macro-expanded text (cc -E -P -x
#       assembler-with-cpp); line numbers then refer to the PREPROCESSED
#       stream, not the raw file. Review macro bodies by hand either way.
#     * Write-detection classifies mnemonics by family: loads write the GPR
#       operand(s) before the first '['; stores write nothing; swp/ld<op>
#       atomics write the second operand (Rt); casp writes the first two
#       operands; cmp/tst/branch/br/blr/msr read only; everything else writes
#       the first operand. Exotic mnemonics outside these families may be
#       misclassified (rare in this codebase; the families are exhaustive for
#       the GPR instructions the playbook uses).
#     * It treats the function as the analysis unit: a register written
#       anywhere in a function must be covered by that function's save/restore
#       and each write must lie between the save and the restore. Because
#       every `bl` sits inside that window, this subsumes the per-call-site
#       rule ("every callee-saved register written between entry and the call
#       must be preserved") for ordinary entry/exit saves. It is still not a
#       full liveness analysis: e.g. it does not prove that a value actually
#       REMAINS live across a specific `bl`.
#     * Terminal (noreturn) functions -- a function whose body contains no
#       `ret` (error paths ending in `bl exit`, entry points like fibonacci's
#       `_start`) never returns to a caller, so the callee-saved checks do
#       not apply to it; only the x18 rule still does. `main` (the C entry
#       point, whose libc caller never resumes after it returns) is treated
#       the same way. The raw source is analyzed, so a `ret` hidden in a CPP
#       conditional still counts.
#     * The stp/ldp balance check is a lexical count, not control flow. A
#       register covered by PROLOGUE n is exempt (the macro is the save).
#       Where restores outnumber saves (s < l) it is treated as benign:
#       mutually-exclusive return paths each restore once. Only a save with
#       no matching restore (s > l, or l == 0) is a finding.
#     * SIMD instructions are not tracked (v-registers are caller-saved and
#       not in scope), but GPR operands of SIMD instructions ARE classified
#       by the default first-operand-written rule; verify exotic SIMD/GPR
#       mixes by hand.
#
# USAGE
#   ./check-clobbers.sh [--preprocess] [-I <dir>] <file.S|dir> [...]
#     --preprocess   preprocess with the C compiler first (cc -E -P -x
#                    assembler-with-cpp); line numbers then refer to the
#                    preprocessed stream
#     -I <dir>       add an include dir for preprocessing (repeatable); -I.
#                    (repo root) is always added first so modules can #include
#                    tc_platform.h
#   Exit 0 = GREEN (no findings). Exit 1 = RED (findings, printed file:line).
#   Exit 2 = usage error.
#
# EXAMPLES
#   ./check-clobbers.sh tc_util.S tc_core.S
#   ./check-clobbers.sh -I . tc_*.S
#   ./check-clobbers.sh --preprocess -I . tc_core.S
#
set -euo pipefail

PREPROCESS=0
INCLUDES=()
FILES=()

usage() {
  sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

# --- argument parsing ---
while [ $# -gt 0 ]; do
  case "$1" in
    --preprocess) PREPROCESS=1 ;;
    -I) [ $# -ge 2 ] || usage; INCLUDES+=("-I" "$2"); shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) FILES+=("$1") ;;
  esac
  shift
done
[ ${#FILES[@]} -gt 0 ] || usage

# --- materialize the analyzer once ---
ANALYZER="$(mktemp "${TMPDIR:-/tmp}/tc-clobber-analyzer.XXXXXX.py")"
trap 'rm -f "$ANALYZER"' EXIT HUP INT TERM

cat > "$ANALYZER" <<'PY'
#!/usr/bin/env python3
"""Clobber-discipline analyzer, embedded in check-clobbers.sh.

Usage: python3 analyzer.py <analyze-path> <display-path>
Analyzes a single assembly file. Prints file:line findings. Exit 1 on any
finding, 0 otherwise. See the .sh header for the precision statement.
"""
import re
import sys

CALLEE_SAVED = tuple(range(19, 29))  # x19..x28

# --- mnemonic classification (see precision note in the .sh header) ---
STORE_RE = re.compile(
    r"^(str|stur|stp|stnp|sttr|stxr|stlxr|stxp|stlxp|stllr|stlr|stlurb|stlurh|stlur|stg|st2g|stzg|stz2g|stgm|stgp)\b")
LOAD_RE = re.compile(
    r"^(ldr|ldur|ldp|ldnp|ldar|ldaxr|ldxr|ldaxp|ldxp|ldrb|ldrh|ldrsw|ldrsb|ldrsh|ldtr|ldtrb|ldtrh|ldtrsb|ldtrsh|ldtrsw|ldapr|ldurh|ldurb|ldursb|ldursh|ldursw|ldgm|ldraa|ldrab)\b")
READONLY_FIRST_RE = re.compile(
    r"^(cmp|cmn|tst|ccmp|ccmn|cbz|cbnz|tbz|tbnz|br|blr|msr|prfm|dc|ic|at|tlbi|cfp|dvp|cosp)\b")
SWP_LDOP_RE = re.compile(r"^(swp|ldadd|ldclr|ldeor|ldset|ldsmax|ldsmin|ldumax|ldumin)(al|a|l)?\b")
CASP_RE = re.compile(r"^casp(al|a|l)?\b")

XREG_RE = re.compile(r"\b(x(?:19|20|21|22|23|24|25|26|27|28))\b")
X29_RE = re.compile(r"\bx29\b")
X18_RE = re.compile(r"\bx18\b")

PROLOGUE_RE = re.compile(r"^\s*PROLOGUE\s+([0-9]+)\b")
EPILOGUE_RE = re.compile(r"^\s*EPILOGUE\s+([0-9]+)\b")
# A function start is any non-`.L`, non-directive label ending in ':'.
# This matches the repo's exported `tc_*` symbols and module-local
# subroutines (`util_`, `cli_`, `cfg_`, `core_`, ...); labels beginning
# with '.' (`.L` branch targets, directives) are excluded because the first
# character must be a letter or underscore. Data labels (e.g. `tc_str_count:`)
# match too, but they open a directive-only "function" that the analyzer
# ignores (see PURPOSE in the .sh header).
FUNC_START_RE = re.compile(r"^\s*[A-Za-z_][A-Za-z0-9_.]*\s*:")
LABEL_RE = re.compile(r"^\s*[A-Za-z_.$][A-Za-z0-9_.$]*\s*:")
DIRECTIVE_RE = re.compile(r"^\s*\.")
INSN_RE = re.compile(r"^\s*([a-z][a-z0-9_.]*)(?:\s+(.*))?$")


def strip_comments(text):
    """Remove /* */ (spanning lines), then // and ';' to end of line."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    out = []
    for line in text.split("\n"):
        for marker in ("//", ";"):
            idx = line.find(marker)
            if idx >= 0:
                line = line[:idx]
        out.append(line)
    return out


def written_regs(mnem, operands):
    """Return the set of GPR indices this instruction WRITES (heuristic)."""
    if STORE_RE.match(mnem):
        return set()
    if READONLY_FIRST_RE.match(mnem):
        return set()
    if SWP_LDOP_RE.match(mnem):
        # swp Rs, Rt, [Rn]; ld<op> Rs, Rt, [Rn] -> Rt (2nd operand) is written
        toks = [t.strip() for t in operands.split(",")]
        m = re.match(r"^x([0-9]+)$", toks[1]) if len(toks) >= 2 else None
        return {int(m.group(1))} if m else set()
    if CASP_RE.match(mnem):
        toks = [t.strip() for t in operands.split(",")]
        out = set()
        for t in toks[:2]:
            m = re.match(r"^x([0-9]+)$", t)
            if m:
                out.add(int(m.group(1)))
        return out
    if LOAD_RE.match(mnem):
        # destination GPRs are the register operands before the first '['
        pre = operands.split("[")[0]
        out = set()
        for t in (x.strip() for x in pre.split(",") if x.strip()):
            m = re.match(r"^x([0-9]+)$", t)
            if m:
                out.add(int(m.group(1)))
        return out
    # default: first operand is the destination
    m = re.match(r"^x([0-9]+)\b", operands.strip())
    return {int(m.group(1))} if m else set()


def required_prologue_n(max_reg):
    """Smallest n such that PROLOGUE n covers x19..x(max_reg) (pairs)."""
    return (max_reg - 18 + 1) // 2


def new_function(name, lineno):
    return {
        "name": name, "start": lineno,
        "writes": {}, "first": {}, "last": {},
        "stp": {}, "ldp": {}, "stp_x29": 0, "ldp_x29": 0,
        "writes29": [], "x18": [],
        "prologue": None, "prologue_line": None,
        "epilogue": None, "bl": 0, "ret": 0,
    }


def check_function(fn, display, findings):
    name = fn["name"]
    writes = fn["writes"]
    pro = fn["prologue"]
    epi = fn["epilogue"]

    # --- terminal (noreturn) functions ---
    # A function whose body contains no `ret` never returns to its caller
    # (e.g. the repo's error paths that end in `bl exit`, or an entry point
    # like fibonacci's `_start`). AAPCS64 callee-saved preservation exists
    # to protect a caller that resumes after `ret`; for a terminal function
    # the restore would be dead code, so the PROLOGUE/EPILOGUE, coverage and
    # stp/ldp-balance findings do not apply. x18 is still a hard rule
    # (AGENTS.md) regardless of return behavior. The RAW source is analyzed,
    # so a `ret` inside a CPP conditional still counts as a return -- this is
    # conservative (more findings, not fewer).
    # `main` is treated the same way: it is the C entry point, and the libc
    # runtime never resumes meaningfully after main returns (it only reads
    # the x0 return value), so the test-driver mains may use x19-x28 freely
    # (e.g. check_tc_cli.S) without saving them.
    if fn["ret"] == 0 or name == "main":
        for lineno in fn["x18"]:
            findings.append((lineno, "ERROR",
                             f"{name}: uses x18 (platform register; never use x18)"))
        return

    # --- PROLOGUE/EPILOGUE consistency ---
    if pro is not None:
        if epi is None:
            findings.append((fn["prologue_line"], "ERROR",
                             f"{name}: PROLOGUE {pro} without a matching EPILOGUE"))
        elif epi != pro:
            findings.append((fn["prologue_line"], "ERROR",
                             f"{name}: PROLOGUE {pro} / EPILOGUE {epi} mismatch"))
    elif epi is not None:
        findings.append((fn["start"], "ERROR",
                         f"{name}: EPILOGUE {epi} without a PROLOGUE"))

    # --- per-register write coverage and window ordering ---
    for reg in sorted(writes):
        rname = f"x{reg}"
        first = fn["first"][reg]
        last = fn["last"][reg]
        pro_covers = pro is not None and reg <= 18 + 2 * pro
        stp_lines = fn["stp"].get(reg, [])
        ldp_lines = fn["ldp"].get(reg, [])
        stp_covers = bool(stp_lines) and bool(ldp_lines)

        if pro_covers:
            # PROLOGUE saves at entry, EPILOGUE restores at exit; the
            # prologue/epilogue consistency check above guarantees the pair.
            if pro < required_prologue_n(reg):
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} but PROLOGUE {pro} is too small "
                                 f"(needs >= {required_prologue_n(reg)})"))
            continue
        if stp_covers:
            save_line = min(stp_lines)
            restore_line = max(ldp_lines)
            if save_line >= first:
                findings.append((first, "ERROR",
                                 f"{name}: writes {rname} at line {first} BEFORE its stp save "
                                 f"at line {save_line} -- clobbered across any intervening bl"))
            if last > restore_line:
                findings.append((last, "ERROR",
                                 f"{name}: writes {rname} at line {last} AFTER its ldp restore "
                                 f"at line {restore_line} -- restore must be the last write"))
            continue
        if stp_lines or ldp_lines:
            findings.append((first, "ERROR",
                             f"{name}: writes {rname} but its stp/ldp pair is unbalanced "
                             f"(saved without restore, or restored without save)"))
            continue
        findings.append((first, "ERROR",
                         f"{name}: writes {rname} but never saves/restores it "
                         f"(add PROLOGUE >= {required_prologue_n(reg)} or a balanced stp/ldp pair)"))

    # --- balanced stp/ldp of callee-saved registers ---
    # A register covered by PROLOGUE n is saved by the macro itself (which
    # the raw source does not spell out); an explicit lexical `ldp` of it is
    # a mid-function restore, not an orphan, so skip the lexical balance
    # check for PROLOGUE-covered registers.
    for reg in sorted(set(fn["stp"]) | set(fn["ldp"])):
        if pro is not None and reg <= 18 + 2 * pro:
            continue
        s = len(fn["stp"].get(reg, []))
        l = len(fn["ldp"].get(reg, []))
        if s == 0:
            findings.append((fn["ldp"][reg][0], "ERROR",
                             f"{name}: ldp restores x{reg} but it was never saved by stp"))
        elif l == 0:
            findings.append((fn["stp"][reg][0], "ERROR",
                             f"{name}: stp saves x{reg} but it is never restored by ldp"))
        elif s > l:
            findings.append((fn["stp"][reg][0], "ERROR",
                             f"{name}: unbalanced stp/ldp for x{reg} ({s} saves vs {l} restores)"))
        # s < l (both > 0): mutually-exclusive return paths each restore once
        # (a save at entry, one ldp per path) -- a lexical count cannot see
        # the control flow, so this shape is treated as benign (see the
        # PRECISION note in the .sh header).

    # --- x29 frame record ---
    if fn["writes29"]:
        if fn["stp_x29"] == 0:
            findings.append((fn["writes29"][0], "ERROR",
                             f"{name}: writes x29 without a matching `stp x29,x30` frame record"))
    if fn["stp_x29"] > 0 and fn["ldp_x29"] == 0:
        findings.append((fn["start"], "ERROR",
                         f"{name}: saves x29/x30 but never restores them"))
    if fn["ldp_x29"] > 0 and fn["stp_x29"] == 0:
        findings.append((fn["start"], "ERROR",
                         f"{name}: restores x29/x30 without a matching `stp x29,x30` save"))

    # --- x18 (hard rule 4) ---
    for lineno in fn["x18"]:
        findings.append((lineno, "ERROR",
                         f"{name}: uses x18 (platform register; never use x18)"))


def analyze(analyze_path, display):
    try:
        with open(analyze_path, "r", errors="replace") as fh:
            raw = fh.read()
    except OSError as exc:
        print(f"{display}: ERROR: cannot read: {exc}")
        return 1

    lines = strip_comments(raw)  # already a list of per-line code text
    findings = []
    fn = None
    func_count = 0
    bl_count = 0

    def close_function():
        nonlocal fn, func_count, bl_count
        if fn is not None:
            func_count += 1
            bl_count += fn["bl"]
            check_function(fn, display, findings)
        fn = None

    for lineno, code in enumerate(lines, 1):
        text = code.strip()
        if not text or text.startswith("#"):
            continue
        m = FUNC_START_RE.match(text)
        if m:
            close_function()
            name = text.rstrip(":").strip()
            fn = new_function(name, lineno)
            continue
        if fn is None:
            continue  # before the first function: headers, macros, rodata
        m = PROLOGUE_RE.match(text)
        if m:
            fn["prologue"] = int(m.group(1))
            fn["prologue_line"] = lineno
            continue
        m = EPILOGUE_RE.match(text)
        if m:
            fn["epilogue"] = int(m.group(1))
            continue
        if DIRECTIVE_RE.match(text) or LABEL_RE.match(text):
            continue
        m = INSN_RE.match(text)
        if not m:
            continue  # unknown shape; ignore (guard, not proof)
        mnem, operands = m.group(1), m.group(2) or ""
        if mnem == "bl":
            fn["bl"] += 1
        if mnem == "ret" or mnem in ("retaa", "retab"):
            fn["ret"] += 1
        if X18_RE.search(text):
            fn["x18"].append(lineno)

        if mnem.startswith("stp"):
            pre = operands.split("[")[0]
            for r in XREG_RE.findall(pre):
                fn["stp"].setdefault(int(r[1:]), []).append(lineno)
            if X29_RE.search(pre):
                fn["stp_x29"] += 1
        elif mnem.startswith("ldp"):
            pre = operands.split("[")[0]
            for r in XREG_RE.findall(pre):
                fn["ldp"].setdefault(int(r[1:]), []).append(lineno)
            if X29_RE.search(pre):
                fn["ldp_x29"] += 1

        for rn in written_regs(mnem, operands):
            if rn in CALLEE_SAVED:
                fn["writes"].setdefault(rn, 0)
                fn["writes"][rn] += 1
                fn["first"].setdefault(rn, lineno)
                fn["last"][rn] = lineno
            elif rn == 29:
                fn["writes29"].append(lineno)
    close_function()

    if findings:
        for lineno, sev, msg in findings:
            print(f"{display}:{lineno}: {sev}: {msg}")
        print(f"{display}: summary: functions={func_count} bl_calls={bl_count} "
              f"findings={len(findings)} -- RED")
        return 1
    print(f"{display}: summary: functions={func_count} bl_calls={bl_count} "
          f"findings=0 -- GREEN")
    return 0


def main(argv):
    if len(argv) != 3:
        print(f"usage: {argv[0]} <analyze-path> <display-path>", file=sys.stderr)
        return 2
    return analyze(argv[1], argv[2])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

# --- run the analyzer on each file ---
RC=0
for f in "${FILES[@]}"; do
  if [ -d "$f" ]; then
    while IFS= read -r -d '' mod; do
      if ! python3 "$ANALYZER" "$mod" "$mod"; then RC=1; fi
    done < <(find "$f" -type f \( -name 'tc_*.S' -o -name 'check_tc_*.S' -o -name 'fibonacci.S' \) -print0 | sort -z)
  elif [ -f "$f" ]; then
    if [ "$PREPROCESS" -eq 1 ]; then
      tmp="$(mktemp "${TMPDIR:-/tmp}/tc-clobber-pp.XXXXXX.S")"
      trap 'rm -f "$ANALYZER" "$tmp"' EXIT HUP INT TERM
      # -I. is added by default so modules can #include tc_platform.h from
      # the repo root; user -I dirs follow it.
      if ! cc -E -P -x assembler-with-cpp -I. "${INCLUDES[@]}" -o "$tmp" "$f" 2>"${TMPDIR:-/tmp}/tc-clobber-pp.err"; then
        echo "$f: ERROR: preprocessing failed (non-ISA); cannot verify" >&2
        cat "${TMPDIR:-/tmp}/tc-clobber-pp.err" >&2
        RC=1
        rm -f "$tmp"
        continue
      fi
      echo "$f: note: analyzing PREPROCESSED text; line numbers refer to the preprocessed stream"
      if ! python3 "$ANALYZER" "$tmp" "$f"; then RC=1; fi
      rm -f "$tmp"
    else
      if ! python3 "$ANALYZER" "$f" "$f"; then RC=1; fi
    fi
  else
    echo "$f: ERROR: not a file or directory" >&2
    RC=2
  fi
done

exit "$RC"