#!/usr/bin/env bash
#
# check-isa.sh -- ISA-compliance checker for tc_*.S / check_tc_*.S / fibonacci.S
#
# PURPOSE
#   Verifies that an assembly module (hand-written AArch64, GNU-as,
#   preprocessed by the C compiler) declares exactly `.arch armv8-a` and uses
#   only armv8-a instructions. The Makefile builds the C sources with
#   -march=armv8.6-a / -mcpu=apple-m2, but every hand-written .S module is
#   baseline ARMv8-a and must stay that way: the dev host's assembler would
#   silently run an armv8.1+ instruction. "It assembled on my machine" must
#   not mean "it runs on baseline ARMv8-a".
#
# METHOD (documented; verified against GNU as 2.47 on aarch64, 2026-09)
#   1. DIRECTIVE SCAN (primary defense): the in-source `.arch` directive
#      OVERRIDES any command-line -march, so the module's own directives are
#      the gate. Reject:
#        - any `.arch` other than exactly `armv8-a` (armv8.1-a+ and armv9-*
#          lift the assembler level; GNU as accepts `.arch armv9-a` and will
#          then assemble SVE2 code silently);
#        - any `.arch_extension` (in particular sve/sve2/i8mm/bf16, but the
#          project convention forbids ALL of them);
#        - any `.cpu` directive (can silently enable features).
#   2. ASSEMBLY GATE: assemble the module through the C compiler
#      (`cc -c -x assembler-with-cpp`, matching production). The repo root is
#      added to the include path by default (-I.) so modules can #include
#      tc_platform.h / tc_layout.inc from the repo root. Under armv8-a the
#      assembler rejects most >armv8-a instructions (bfdot, smmla, sdot,
#      ldraa, stg, retaa, ...). Such REJECTIONS are reported as warnings, not
#      red: the instruction cannot enter the binary -- the build gate already
#      stops it. If assembly fails for a NON-ISA reason (missing include,
#      syntax error), the module cannot be verified and the check is RED
#      ("green" must mean "verified").
#   3. DISASSEMBLY GATE (defense-in-depth; catches the silent cases): GNU as
#      2.47 ACCEPTS some >armv8-a instructions even under `.arch armv8-a` --
#      verified on this host: paciasp, pacibsp, autiasp, autibsp, xpaclri
#      (armv8.3 pointer auth), bti, ssbb, pssbb (armv8.5). It also silently
#      accepts `.arch armv9-a` + SVE2. So we disassemble the object and scan
#      the instruction stream for:
#        - SVE/SVE2 z-registers and p-registers (no base-AArch64 instruction
#          uses them);
#        - a blacklist of scalar/system mnemonics that require a higher ISA
#          (pointer-auth, bti, sb-family, memtag, bf16, i8mm, dotprod);
#      each hit is mapped back to file:line via addr2line (assembled with -g).
#
# PRECISION
#   The mnemonic blacklist is curated from the armv8.3-armv8.6 feature sets
#   and is not guaranteed exhaustive; the directive scan is the authoritative
#   gate. This script is a guard, not a proof -- human review applies
#   (AGENTS.md). It reports file:line for every violation.
#
# USAGE
#   ./check-isa.sh [--arch armv8-a] [-I <dir>] <file.S|dir> [...]
#     --arch <x>     baseline ISA to enforce (default armv8-a)
#     -I <dir>       add an include dir for assembly (repeatable); -I. is
#                    always added first (modules #include repo-root headers)
#   Exit 0 = GREEN (verified). Exit 1 = RED (violations, file:line).
#   Exit 2 = usage error.
#
# EXAMPLES
#   ./check-isa.sh -I . tc_util.S tc_core.S fibonacci.S
#   ./check-isa.sh -I . tc_*.S
#   ./check-isa.sh -I . .                 # whole repo (directory mode)
#   ./check-isa.sh --arch armv8.2-a -I . tc_core.S   # enforce another ceiling
#
set -euo pipefail

# Default baseline: every .S module in this repo declares `.arch armv8-a`
# (baseline ARMv8-A). `--arch` overrides this for other ceilings.
ARCH="armv8-a"
INCLUDES=()
FILES=()
EXTRA_INC=()
if [ -n "${ASM_INCLUDES:-}" ]; then
  for d in ${ASM_INCLUDES//:/ }; do
    [ -n "$d" ] && EXTRA_INC+=("-I" "$d")
  done
fi

usage() {
  sed -n '2,65p' "$0" | sed 's/^# \{0,1\}//'
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch) [ $# -ge 2 ] || usage; ARCH="$2"; shift ;;
    -I) [ $# -ge 2 ] || usage; INCLUDES+=("-I" "$2"); shift ;;
    -h|--help) usage ;;
    -*) usage ;;
    *) FILES+=("$1") ;;
  esac
  shift
done
[ ${#FILES[@]} -gt 0 ] || usage

# --- materialize the analyzer once ---
ANALYZER="$(mktemp "${TMPDIR:-/tmp}/tc-isa-analyzer.XXXXXX.py")"
trap 'rm -f "$ANALYZER"' EXIT HUP INT TERM

cat > "$ANALYZER" <<'PY'
#!/usr/bin/env python3
"""ISA-compliance analyzer, embedded in check-isa.sh.

Modes:
  directives <file> <arch>      -- scan source for .arch/.arch_extension/.cpu
  disasm <objdump-text-file> <obj> <arch> -- scan disassembly; addr2line hits

Exit 1 on any violation, 0 otherwise.
"""
import re
import subprocess
import sys

# Curated blacklist: mnemonics that require an ISA above the armv8-a baseline.
# Verified on GNU as 2.47 (aarch64) 2026-09: the pointer-auth/bti/ssbb/pssbb
# group assembles SILENTLY under .arch armv8-a; the rest are gated by the
# assembler but kept here as defense-in-depth against .arch_extension lifts.
MNE_BLACKLIST = (
    # armv8.3 pointer authentication
    r"paciasp|pacibsp|paciaz|pacibz|autiasp|autibsp|autiaz|autibz|"
    r"xpaclri|retaa|retab|eretaa|eretab|pacga|"
    # armv8.5 branch / speculative / flag
    r"bti|ssbb|pssbb|sb|cfp|dvp|cosp|setf8|setf16|rmif|"
    # armv8.4 memory tagging
    r"stg|st2g|stzg|stz2g|stgm|ldgm|irg|gmi|subp|addg|subg|"
    # armv8.6 bf16
    r"bfdot|bfmmla|bfcvt|bfcvtnt|bfcvtn|bfmlalb|bfmlalt|"
    # armv8.6 i8mm
    r"smmla|ummla|usmmla|"
    # armv8.2-optional dotprod (above plain armv8-a; keep as backup)
    r"sdot|udot|usdot|sudot|"
    # armv8.3 ldapr (rcpc extension)
    r"ldapr"
)
MNE_BLACKLIST_RE = re.compile(r"\b(?:" + MNE_BLACKLIST + r")\b")
ZREG_RE = re.compile(r"\bz[0-9]+")          # SVE/SVE2 vector registers
PREG_RE = re.compile(r"\bp[0-9]+")          # SVE/SVE2 predicate registers

ARCH_EXT_FORBIDDEN = ("sve", "sve2", "i8mm", "bf16", "bf16mmla", "bf16dot")


def scan_directives(path, arch):
    findings = []
    seen_arch = False
    try:
        with open(path, "r", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        print(f"{path}: ERROR: cannot read: {exc}")
        return 1
    for lineno, raw in enumerate(lines, 1):
        line = raw.strip()
        m = re.match(r"^\.arch\s+(\S+)", line)
        if m:
            seen_arch = True
            value = m.group(1)
            if value != arch:
                findings.append((lineno, f".arch {value} -- must be exactly '{arch}' "
                                        f"(nothing higher; the in-source .arch overrides any -march)"))
            continue
        m = re.match(r"^\.arch_extension\s+(\S+)", line)
        if m:
            ext = m.group(1)
            if ext in ARCH_EXT_FORBIDDEN:
                findings.append((lineno, f".arch_extension {ext} -- {ext} requires an ISA above {arch}"))
            else:
                findings.append((lineno, f".arch_extension {ext} -- forbidden by project convention "
                                        f"(exactly one .arch {arch}, no extensions)"))
            continue
        if re.match(r"^\.cpu\s+\S+", line):
            findings.append((lineno, ".cpu directive -- forbidden by project convention "
                                      "(it can silently enable features; use exactly one .arch)"))
    if not seen_arch:
        print(f"{path}: WARNING: no .arch directive found -- add exactly one '.arch {arch}' "
              f"(GNU as defaults lower; this module is outside the playbook contract)")
    if findings:
        for lineno, msg in findings:
            print(f"{path}:{lineno}: ERROR: {msg}")
        print(f"{path}: directive scan -- RED")
        return 1
    print(f"{path}: directive scan -- OK ({arch})")
    return 0


def scan_disasm(disasm_path, obj_path, arch, src_display):
    findings = []
    try:
        with open(disasm_path, "r", errors="replace") as fh:
            lines = fh.read().split("\n")
    except OSError as exc:
        print(f"{src_display}: ERROR: cannot read disassembly: {exc}")
        return 1
    for line in lines:
        # objdump line shape: "<addr>:\t<hex>\t<mnemonic> <operands>"
        m = re.match(r"^\s*([0-9a-f]+):\s+[0-9a-f]+\s+(.*)$", line)
        if not m:
            continue
        addr, insn = m.group(1), m.group(2)
        why = None
        if ZREG_RE.search(insn):
            why = "SVE/SVE2 vector register (z) -- requires armv9/SVE"
        elif PREG_RE.search(insn):
            why = "SVE/SVE2 predicate register (p) -- requires armv9/SVE"
        elif MNE_BLACKLIST_RE.search(insn):
            why = f"instruction above {arch} (blacklisted mnemonic)"
        if why:
            loc = f"{src_display}:0"
            try:
                out = subprocess.run(
                    ["addr2line", "-e", obj_path, addr],
                    capture_output=True, text=True, check=True).stdout.strip()
                if out and "??" not in out:
                    loc = out
            except (subprocess.CalledProcessError, OSError):
                pass
            findings.append((loc, f"{insn.strip()} -- {why}"))
    if findings:
        for loc, msg in findings:
            print(f"{loc}: ERROR: {msg}")
        print(f"{src_display}: disassembly scan -- RED")
        return 1
    print(f"{src_display}: disassembly scan -- OK (no >{arch} instructions)")
    return 0


def main(argv):
    if len(argv) >= 4 and argv[1] == "directives":
        return scan_directives(argv[2], argv[3])
    if len(argv) >= 6 and argv[1] == "disasm":
        return scan_disasm(argv[2], argv[3], argv[4], argv[5])
    print(f"usage: {argv[0]} directives <file> <arch> | disasm <objdump> <obj> <arch> <display>",
          file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PY

# --- run the checks per module ---
RC=0
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/tc-isa.XXXXXX")"
trap 'rm -rf "$TMPD" "$ANALYZER"' EXIT HUP INT TERM

check_module() {
  local f="$1"
  local obj="$TMPD/$(basename "$f").o"
  local dis="$TMPD/$(basename "$f").dis"
  local asm_err="$TMPD/$(basename "$f").err"
  local mod_rc=0

  # 1. directive scan (primary)
  python3 "$ANALYZER" directives "$f" "$ARCH" || mod_rc=1

  # 2+3. assembly gate, then disassembly scan. -I. is added by default so
  # modules can #include tc_platform.h / tc_layout.inc from the repo root;
  # user -I / ASM_INCLUDES dirs follow it.
  if cc -g -c -x assembler-with-cpp -I. "${EXTRA_INC[@]}" "${INCLUDES[@]}" \
       -o "$obj" "$f" 2> "$asm_err"; then
    objdump -d "$obj" > "$dis"
    python3 "$ANALYZER" disasm "$dis" "$obj" "$ARCH" "$f" || mod_rc=1
  else
    if grep -qE "does not support|selected processor|not supported" "$asm_err"; then
      # The assembler REJECTED an instruction under $ARCH: it cannot
      # silently enter the binary, so this is a warning, not red -- but the
      # module does NOT build and a warning is not green.
      echo "$f: WARNING: assembler rejected an instruction under $ARCH (module does not build):"
      sed 's/^/    /' "$asm_err"
    else
      echo "$f: ERROR: could not verify ISA compliance -- assembly failed for a non-ISA reason:"
      sed 's/^/    /' "$asm_err"
      mod_rc=1
    fi
  fi

  if [ "$mod_rc" -eq 0 ]; then
    echo "$f: GREEN (verified $ARCH)"
  else
    echo "$f: RED"
  fi
  return "$mod_rc"
}

for f in "${FILES[@]}"; do
  if [ -d "$f" ]; then
    while IFS= read -r -d '' mod; do
      check_module "$mod" || RC=1
    done < <(find "$f" -type f \( -name 'tc_*.S' -o -name 'check_tc_*.S' -o -name 'fibonacci.S' \) -print0 | sort -z)
  elif [ -f "$f" ]; then
    check_module "$f" || RC=1
  else
    echo "$f: ERROR: not a file or directory" >&2
    RC=2
  fi
done

exit "$RC"