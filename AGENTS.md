# AGENTS.md — shirley-asm (AArch64 assembly)

> **Read this file before writing, reviewing, or modifying any assembly in
> this repo.** It is the working contract for every `.S` module (the
> `tc_*.S` module set, `fibonacci.S`, the `check_tc_*.S` test drivers), for
> the shared macros in `tc_platform.h`, and for the two checker scripts that
> live at the repo root (`./check-isa.sh`, `./check-clobbers.sh`). It is
> self-contained: an agent dropped into this repo with no other context can
> follow it.

---

## What this project is

Hand-written **ARMv8-A / ARMv8.6-A AArch64 assembly** project. Two deliverables, both assembled by the project's own Makefile:

- **`twitch-counts`** — port of `twitch-counts.py`: hand-written `tc_*.S` modules linked against libc and the vendored libraries under `third_party/` (tomlc99, sqlite3 amalgamation, pcre2-8). Builds from the same sources on two platforms (`tc_platform.h` selects):
  - **Linux** — static, musl libc (musl toolchain bootstrapped from source into `third_party/musl`; no root).
  - **macOS** — arm64 Mach-O, dynamically linked against libSystem.
- **`fibonacci`** — pure Linux syscalls, no libc (`as` + `ld`); Linux-only.

### Repo layout
- `tc_*.S`, `tc_platform.h`, `tc_layout.inc` — the assembly modules.  The
  `twitch-counts` module set (the Makefile's `TC_MODS`) is:
  - `tc_main.S` — `main()` dispatch/orchestration
  - `tc_util.S` — shared helpers (`tc_puts`, `tc_fail`, `tc_fmt_u64`,
    `tc_read_all`, `tc_hl_bad_regex`, ...) and the Wave-1 shared constants
  - `tc_cli.S` — CLI parsing, resolves `[[watch.highlight]]`
  - `tc_config.S` — config / env / exclusions
  - `tc_core.S` — the counting core
  - `tc_cache.S` — the SQLite rollup cache
  - `tc_render.S` — output formatting
  - `tc_json.S` — the JSON report
  - `tc_misc.S` — `--manual` / `--fish` / `--complete`
  - `tc_watch.S` — watch mode
- `*.inc` (`tc_manual.inc`, `tc_fish.inc`, `tc_json_schema.inc`) — committed
  generated blobs (regenerate only with `make gen-inc`).  `tc_parse_facts.inc`
  is NOT generated: it is a hand-maintained shared include (marker strings
  the core and cache modules both embed) with no generator.
- `build/<os>/` — per-platform objects, drivers, third-party build products (never share objects between Linux/macOS).
- `third_party/` — vendored C (toml, sqlite3), bootstrapped musl, fetched pcre2 tarball.
- `check_tc_*.S` + `test-tc-*.sh` — per-module test drivers and harnesses.
- `gen-tc-*.sh` — regenerate the `.inc` blobs.
- `check-isa.sh`, `check-clobbers.sh` — the two assembly checker scripts (at the repo root; see [Checkers](#checkers)).
- `scripts/` — the Ghidra analysis scripts invoked by the Makefile analysis targets.

---

## Assembly-authoring contract

This is the shared working contract for every `.S` module. It was originally
written as the *Assembly Authoring Playbook* for an ARMv8.2-A `cc_*.S`
controller in a sibling project (`core/controller/asm/`); it is adopted here
as the project's discipline, **adapted to this repo's reality** — the module
set is `tc_*.S`, the exported prefix is `tc_`, and the ISA policy is
ARMv8-A baseline / ARMv8.6-A (see [Execution environment](#execution-environment)).
Where the repo deviates from the playbook, the deviation is called out in a
"Repo note".

### Mandate (Gate 0.0)

- **Before ANY backend-logic work** — assembly, checker edits, Makefile
  wiring, plan updates — load the **`code-philosophy`** skill (Gate 0.0).
  Every law applies to assembly: guard clauses become branch-first control
  flow; parse-don't-validate means untrusted input is converted to trusted
  invariants at the function boundary; atomic predictability means a function
  never surprises its caller; fail-fast means an invalid state halts with a
  loud error return (never a silent continuation); intentional naming means
  `tc_` / module-prefix / `.L` names that read like English.
- **Never** write assembly that "probably works". A function that has not been
  proven (Gate 3) is not built (hard rule 9).

### Execution environment

- **GNU-as syntax, preprocessed by the C compiler** (`$(CC)` = `musl-gcc` on
  Linux, `clang` on macOS — never bare `as`). CPP is the macro engine; the
  assembler is the final consumer. `tc_platform.h` selects the platform
  (ELF/musl vs Mach-O/Darwin) before anything is assembled.
- **ISA: in-source `.arch armv8-a`** in every module, and the Makefile passes
  **`-march=armv8.6-a`** (`TC_MARCH`) through the compiler driver — i.e. the
  project targets ARMv8-A baseline instructions with ARMv8.6-A features
  available at build time. The `.S` sources' declared `.arch` is the floor,
  not the ceiling.
- **Repo note (deviation from the playbook):** the playbook mandated
  `.arch armv8.2-a` exactly, with no `-march` reaching the assembler, to hold
  Graviton2 parity. This repo deliberately differs: it is a dual-platform
  project (Linux + macOS/Apple Silicon) that builds for **ARMv8.6-A**, so
  there is no single `armv8.2-a` ceiling. The playbook's *spirit* still
  holds: the in-source `.arch` directive is the gate, and a module must never
  silently exceed the project's declared target. The dev host's assembler
  **silently accepts** some higher-ISA instructions (`paciasp`, `bti`,
  `ssbb`/`pssbb`, SVE/SVE2) — "It assembled on my machine" must never mean
  "it runs on the target". That is precisely what `check-isa.sh` exists to
  prevent.

### Hard rules

> **Rule 0 — x30 is preserved across every `bl`.** A `bl` clobbers x30 (the
> link register). Any function that calls MUST save x30 before the call —
> `PROLOGUE n` always does (`stp x29,x30`), or an explicit `stp x30,...`
> (e.g. `stp x19,x30,[sp,#-16]!`) — and restore it before its own `ret`.
> Only `b sym` is a tail call; `bl` is never one. A `ret` after a `bl`
> without restoring x30 returns to the bl's RETURN ADDRESS and loops back
> into the function — the #1 silent-wrongness source (the wrong-link /
> infinite-loop bug). `check-clobbers.sh` now enforces this, and local
> (`module_*:`) functions are covered too.

1. **ISA**: one `.arch` directive per module, declared to the project's
   target (currently `armv8-a`); no `.arch_extension` that silently enables
   features the module does not declare (in particular never `sve`, `sve2`,
   `i8mm`, `bf16` unless the build target truly requires them), no `.cpu`.
   The in-source `.arch` overrides any `-march`, so it is the gate.
2. **Callee-saved registers**: preserve **x19–x28 and x29** across every
   `bl` (AAPCS64; x30 is Rule 0). A function may use them but must restore
   them before `ret`.
3. **Stack alignment**: `sp` is 16-byte aligned at every call site.
4. **Never use x18** (platform register).
5. **Never join statements with `;`** — it is a comment character in this
   project's dialect. One instruction per line. Comments use `//`.
6. **Constants are CPP macros, not `.equ`** — module-local `.equ` collisions
   fail to assemble. Every constant lives in `tc_platform.h` or a module
   header.
7. **`PROLOGUE n` / `EPILOGUE n`** — assembler macros (`.if \n >= k` chains)
   that keep `sp` aligned and preserve callee-saved registers in pairs
   x19/x20, x21/x22, …, x27/x28 (`n <= 5`). `EPILOGUE n` must match
   `PROLOGUE n`. Prefer them over hand-rolled `stp`/`ldp` pairs. Both macros
   default to `n=0`; every `tc_*.S` module uses them.
8. **Fixed-arity wrappers for variadic libc calls** — AAPCS64 variadic rules
   (register save area / `x8` indirect forms as required). Never `bl` a
   variadic C function directly from assembly; call a fixed-arity wrapper.
9. **Never build on an unverified function** — a function that has not passed
   Gate 3 is not wired into a build target.

### Function shape (every exported function)

```
    .p2align 2
    .global tc_name
    FUNC_TYPE(tc_name)            # ELF: .type tc_name,%function (empty on Mach-O)
tc_name:
    ... body ...
    ret
```

The file ends with `.end`.

### Local helpers are FULL AAPCS64 functions

A module-prefix local subroutine (`util_*:`, `cli_*:`, `cfg_*:`, ...) is a
FULL AAPCS64 function with the SAME obligations as an exported `tc_*`
function — it is never "just a jump target". It must:

- preserve **x19–x28 AND x30** across its own `bl`s: save x30 before every
  call (`PROLOGUE n` does `stp x29,x30`; an explicit `stp x30,...` also
  counts) and restore it before its own `ret`;
- keep `sp` 16-byte aligned at its own call sites;
- restore all its callee-saved saves before returning.

`check-clobbers.sh` analyzes local helpers as their own functions — a helper
that clobbers x19 or x30 is a RED finding on the helper, never attributed to
the enclosing `tc_*` function.

### Naming rules

- Exported symbols: **`tc_`** prefix (e.g. `tc_strlen`, `tc_puts`,
  `tc_fail`, `tc_fmt_u64`, `tc_read_all`) — this is the repo's convention,
  declared in `tc_layout.inc`.
- Module-local symbols: **module prefix** — `main_`, `util_`, `cli_`,
  `cfg_`, `core_`, `cache_`, `render_`, `json_`, `misc_`, `watch_`
  (matching the module's purpose; note the config module uses `cfg_`).
- Branch targets and local labels: **`.L`** prefix (e.g. `.Lret`, `.Lloop`).
- Never use `tc_` for a non-exported label and never branch to a bare
  non-`.L` label.

### Macro set (shared header `tc_platform.h`)

All macros are defined in `tc_platform.h` with **dual-platform expansions**
(Darwin/Mach-O and ELF/musl variants selected by the header). Do not redefine
them in a module. The set actually used by this repo:

| Macro | Expansion / purpose |
|---|---|
| `PAGE(sym)` | ELF: `sym` (plain adrp placeholder); Darwin: `sym@PAGE` |
| `LO12(sym)` | ELF: `:lo12:sym`; Darwin: `sym@PAGEOFF` — pair with `PAGE` for `adrp`+`add`/`ldr` page-relative addressing |
| `RODATA` | ELF: `.section .rodata`; Darwin: `.section __DATA,__const` |
| `FUNC_TYPE(sym)` | ELF: `.type sym,%function`; Darwin: empty (no Mach-O equivalent) |
| `LEA reg,sym` | `adrp reg,sym` + `add reg,reg,:lo12:sym` (Darwin: `@PAGE`/`@PAGEOFF`) |
| `LEA_OFF reg,sym,off` | `LEA` plus an offset |
| `LOAD_EXTERN_DATA_ADDR reg,sym` | load the address of an external data symbol (Darwin uses GOT) |
| `PROLOGUE n=0` / `EPILOGUE n=0` | paired save/restore, callee-saved pairs x19/x20 … x27/x28 (`n <= 5`) |
| `MOV_DIV10_MAGIC reg` | materialize the divide-by-10 magic constant (`umulh` >> 3) |
| `MOV_NANOSEC reg` | materialize the nanoseconds constant |
| `SWAR_MASK_01` / `SWAR_MASK_80` | CPP constants: SWAR has-zero-byte low-bit mask / detection mask (`01` mask << 7) |
| `LOAD_ST_MODE n,base` / `LOAD_ST_DEV n,base` | load `mode_t`/`dev_t` fields — **platform-sized** (16-bit on Darwin, 32/64-bit on musl); use these, never a hardcoded load width |
| `LOWER_BYTE reg,skip` | fold one ASCII byte in `reg` from `A`-`Z` to `a`-`z` in place: `cmp reg,#'A'; b.lt skip; cmp reg,#'Z'; b.gt skip; add reg,reg,#0x20` — `skip` is a `.L` label at the call site; clobbers flags + `reg` (the lowercase-copy sites in tc_core/tc_config/tc_misc/tc_cli) |
| `PAD2 cur` | write two ASCII spaces at `cur` and advance it by 2: `mov w1,#' '; strb w1,[cur],#1; strb w1,[cur],#1` — clobbers w1/x1 + `cur` (the table-emit sites in tc_render.S); `cur` must not be x1/w1 |

### The 5 gates

Work proceeds one gate at a time. A gate is complete only when its exit
criteria are met.

- **Gate 0 — Scope / contract & test-first.** One function per task. Write
  the contract (inputs, outputs, invariants, failure modes) and the
  differential test harness *before* the assembly. Load `code-philosophy`
  (Gate 0.0).
- **Gate 1 — Module skeleton.** Create `tc_<module>.S`, the module header
  (`tc_layout.inc` for shared constants), use the shared macros from
  `tc_platform.h`, wire the module into the Makefile (`TC_MODS` / driver
  objects), and run the checkers on the new module. The skeleton must pass
  both checkers green.
- **Gate 2 — Implement ONE function, ≤ 80 instructions.** One function per
  commit-sized step. If a function exceeds 80 instructions, split it.
- **Gate 3 — Prove the function.** (a) a driver harness (`check_tc_*.S`)
  runs it; (b) a differential test (`test-tc-*.sh`) compares it against the
  Python reference; (c) the disassembly is reviewed; (d) `check-isa.sh` is
  GREEN on the module; (e) `check-clobbers.sh` is GREEN on the raw AND the
  preprocessed form. A function is "unverified" until Gate 3 passes.
- **Gate 4 — Module complete.** Every function in the module is proven; the
  module passes both checkers green.
- **Gate 5 — Integration.** The module is wired into the `twitch-counts`
  build, linked, and smoke-tested end to end (`make twitch-counts` and the
  full `make test`).

### Checkers

Both scripts live at the **repo root** (`./check-isa.sh`,
`./check-clobbers.sh`). They are **guards, not proofs** — human review always
applies. Run them after every edit to a `.S` module. They are invoked
manually (not yet wired into the Makefile).

#### `check-isa.sh` — ISA compliance

```sh
./check-isa.sh tc_*.S              # files or a directory
./check-isa.sh -I . tc_core.S      # add include dirs (needed for tc_platform.h)
./check-isa.sh --strict-blacklist-update -I . tc_*.S   # blacklist self-check
```

What it does: (1) rejects any `.arch` above its configured ceiling (default
`armv8-a`, matching this repo's declared baseline; `--arch` overrides) and
any `.arch_extension` (and any `.cpu`); (2) assembles the module (`-I.` is
added by default so modules can `#include tc_platform.h` / `tc_layout.inc`)
and disassembles the object; (3) scans the disassembly for instructions or
registers that require a higher ISA (pointer-auth, `bti`, `ssbb`/`pssbb`,
SVE/SVE2 `z`/`p` registers, bf16/i8mm/dotprod, memtag).

**Green** = directive scan clean, object assembles, disassembly scan clean.
**Red** (non-zero exit, `file:line` printed) = a `.arch`/`.arch_extension`
violation, a >ceiling instruction present in the object, OR an instruction
the assembler *rejects* under the ceiling (e.g. `bfdot`). Rejections are
fail-loud (RED, exit non-zero): the module does not build and "a warning is
not green" — an exit-code-gated CI loop keyed on `$?` must not pass.

Optional self-check: `--strict-blacklist-update` probes every mnemonic in
the curated blacklist under a high arch (default `armv9-a`) and fails if one
does not assemble — a dead blacklist entry is a typo. Conservative: skipped
when the host assembler does not know the high arch, and the probe-fragile
mnemonics (st2g/stz2g/cosp) are skipped, not failed.

**Repo note (current status):** the checker was imported from the
`core/controller/asm/` playbook project and has been adapted to this repo —
it now enforces this repo's declared `.arch armv8-a` baseline (the playbook
project enforced armv8.2-a), matches `tc_*.S` / `check_tc_*.S` /
`fibonacci.S` in directory mode, and adds `-I.` by default. `tc_util.S`,
`tc_core.S`, `fibonacci.S`, and the other modules pass GREEN.

#### `check-clobbers.sh` — clobber discipline (AAPCS64 callee-saved)

```sh
./check-clobbers.sh tc_*.S          # raw + preprocessed, always
./check-clobbers.sh -I . tc_core.S  # add include dirs (needed for tc_platform.h)
```

What it does: for EVERY function — exported `tc_*:` and local helper
`module_*:` alike (any non-`.L` label starts a function) — it checks
(a) every write to x19–x28 is covered by `PROLOGUE n`/`EPILOGUE n` or a
balanced `stp`/`ldp` pair, and each write lies inside its save/restore
window; (b) `stp`/`ldp` of callee-saved registers are balanced — only the
dangerous directions are flagged (a save with no restore, a restore with no
save, or strictly more saves than restores; restores outnumbering saves is
benign — one PROLOGUE with several return paths); (c) writes to x29 have a
matching `stp x29,x30` frame record; (d) **x30**: any function that calls
(`bl`) must save x30 before the call — `PROLOGUE n` always does
(`stp x29,x30`), or an explicit `stp x30,...` / `str x30, [sp, #-16]!` —
and restore it before its own `ret` (a `bl` after the restore followed by a
`ret` is the wrong-link bug); bonus: any use of x18 is flagged.

It analyzes the RAW source AND the macro-preprocessed text by default, so a
register hidden inside a CPP macro is still caught (preprocessed findings
are labeled `(preprocessed)`; their line numbers refer to the expanded
stream). Data/rodata labels form empty functions (no findings). A function
that never `ret`s (a noreturn fail-loud helper) is not required to restore
its saves, and a pure leaf (no `bl`) never clobbers x30.

**Green** = no findings. **Red** (non-zero exit, `file:line` printed) = one
or more findings. Review macro bodies by hand either way. See the comment
header in the script for a full precision statement.

**Repo note (current status):** the checker was imported from the
`core/controller/asm/` playbook project and has been adapted to this repo —
it now detects functions by any non-`.L` label (so both exported `tc_*`
symbols and module-local helpers are analyzed), matches `tc_*.S` /
`check_tc_*.S` / `fibonacci.S` in directory mode, adds `-I.` by default, and
adds x30 (Rule 0) checking. The current modules pass GREEN with real
coverage (a non-zero function count).

### Debugging-time discipline

Run the two checkers BEFORE reaching for gdb. The clobber/x30 checker is
deterministic and catches the wrong-link bug (a `ret` after a `bl` with no
x30 restore) and local-helper clobbers; `check-isa.sh` catches silent
>armv8-a instructions. A "garbage x0 / runaway writes" symptom is most often
a clobbered x30 or a caller-saved register across a call — check
`./check-clobbers.sh .` and `./check-isa.sh -I . tc_*.S` first, then gdb
only after both are green and a real logic bug remains.

### What "green" means

- `check-isa.sh`: every module printed `GREEN` and the script exited 0.
- `check-clobbers.sh`: every module printed `GREEN` (raw AND preprocessed)
  and the script exited 0 with a non-zero function count.
- A module is "green" only when **both** scripts exit 0 on it. Anything else
  — a red finding, or an ISA rejection — means the module must be fixed.

### Module layout (created in Gate 1, one per module)

- `tc_<module>.S` — the assembly module (what the checkers inspect).
- `tc_layout.inc` — shared constants and exported-symbol declarations (CPP
  macros / layout), included by the modules.
- `tc_platform.h` — the shared header: platform selection plus the macro set
  (PROLOGUE/EPILOGUE, LEA family, FUNC_TYPE, RODATA, PAGE/LO12, MOV_*,
  SWAR masks, LOAD_ST_*).
- Makefile wiring — `TC_MODS` and the per-driver object lists; the module is
  compiled through the C compiler preprocessor (`tc_platform.h`), never bare
  `as`.
- `check_tc_<module>.S` + `test-tc-<module>.sh` — driver harness and
  differential test (created with the first function, Gate 3).

### Human code-review checklist (the real gate)

- [ ] `code-philosophy` loaded and applied (Gate 0.0)
- [ ] exactly one `.arch` per module, declared to the project's target; no
  `.arch_extension`, no `.cpu`
- [ ] x19–x28, x29, and x30 preserved across every `bl`; restored before `ret`
- [ ] `sp` 16-byte aligned at every call site
- [ ] no x18, no `;`, no `.equ`
- [ ] constants are CPP macros; `PROLOGUE n`/`EPILOGUE n` matched
- [ ] naming: `tc_` / module prefix / `.L` labels
- [ ] ≤ 80 instructions per function
- [ ] `check-isa.sh` green; `check-clobbers.sh` green on raw AND
  preprocessed **with real coverage** (non-zero function count)
- [ ] driver + differential + disasm proof exists (Gate 3)

---

## Build & test

| Command | Purpose |
|---|---|
| `make twitch-counts` | build (and refresh `./twitch-counts`) |
| `make all` | + Linux-only `fibonacci` on Linux |
| `make drivers` | per-module test drivers (`build/<os>/tc-*-test`) |
| `make test` | every harness for this platform (fails on any failure) |
| `make check-<h>` | one harness, e.g. `make check-tc-watch` |
| `make third-party` | just the vendored libraries |
| `make gen-inc` | force-regenerate committed `.inc` blobs |
| `make clean` | remove `build/` and root binaries |

The `.S` sources go through the C preprocessor (`tc_platform.h`), so they are assembled with the **compiler driver** (`$(CC)` = `musl-gcc` on Linux, `clang` on macOS), never bare `as`. The Makefile also passes `-march=armv8.6-a` (`TC_MARCH`).

## Static analysis tooling & when to use it
The Makefile exposes four analysis targets. See `scripts/` for the Ghidra scripts they invoke.

| Command | Tool | When to use |
|---|---|---|
| `make analyze` | GCC `-fanalyzer` | Bug-finding over the **vendored C** (UAF, leaks, OOB, taint, null-deref). Runs through `musl-gcc` so it sees the same musl headers the build uses. **Linux only** (macOS uses clang, no `-fanalyzer`). Default = `toml.c` only — this box has ~6GB RAM, so the 250k-line sqlite3 amalgamation is opt-in: `make analyze ANALYZE_SRCS="...sqlite3.c"`. |
| `make mca` | `llvm-mca` | **Instruction-level** throughput/scheduling of one hand-written `.S` module: `make mca MCA_SRC=tc_core.S MCA_CPU=neoverse-v2`. The `.S` is preprocessed first so `llvm-mca` sees real instructions. Best-effort (some assembler directives it can't parse surface as errors). |
| `make disasm` | Ghidra (headless) | **Disassembly of one function** from a built binary: `make disasm BIN=./twitch-counts FUNC=main` (or `FUNC=0x...`). Pure-Java — works everywhere. **Use this for Ghidra work on aarch64.** |
| `make decompile` | Ghidra (headless) | **Decompile one function to C**: `make decompile BIN=... FUNC=...`. **Unavailable on aarch64 Linux** — Ghidra ships no native decompiler for that host, so the target exits early and tells you to use `make disasm`. |

### Decision rules
1. **C source** (vendored C) → `make analyze`. **C++** → `clang-tidy` (via `compile_commands.json`).
2. **Hand-written assembly** → `make mca` for throughput; treat it as the ISA-level sanity check.
3. **A built binary without source** → `make disasm` (or `make decompile` where the native decompiler exists).
4. **Quick facts** about an object/binary → `objdump` / `readelf` / `nm` / `llvm-objdump`.

## Gotchas (verified)
- **Linux binaries are fully stripped** (`-s` at link), so `nm` shows no symbols and Ghidra names functions `FUN_<addr>` (plus `entry` for the musl `_start`). Function selectors must be a **name that survives** (`entry`) or a **hex address** (`FUNC=0x...`). On a miss the Ghidra scripts print the full function directory.
- **Ghidra on aarch64 Linux cannot decompile** (native decompiler not shipped). Don't attempt a source build on this box — use `make disasm`.
- **`-fanalyzer` is heavy** — keep the default source set small (toml.c); only include sqlite3/pcre2 when the machine can take it.
- Inline `asm`/`.S` is invisible to all source-level analyzers — machine-level tools (`mca`, `disasm`) are the only ones that see it.

## Environment tool availability (this host, aarch64 Linux)
- **Compilers/asm:** `gcc` 15.3 (host aarch64, has `-fanalyzer`), `aarch64-linux-gnu-gcc`, `clang`/`clang++` 21.1.8, `clang-tidy`, `as`/`ld`/`objdump`/`readelf`/`nm` (binutils), `gdb`, project-bootstrapped `musl-gcc` (in `third_party/musl/bin`).
- **Static analysis:** GCC `-fanalyzer`, `llvm-mca`, `llvm-exegesis`, `clang-tidy`.
- **Reverse engineering:** **Ghidra 12.1.3** + Temurin JDK 21 at `~/bin/` (symlinked into `~/.local/bin` on PATH: `analyzeHeadless`, `ghidraRun`, `java`, `javac`).
- **Dynamic:** `qemu-aarch64` (user-mode), `gdb`.
- **Scripting:** `python3` 3.15-alpha (pip 25.3; **angr NOT installed**), `node`/`npm`, `go`, `perl`, `bash`.
- **Not present:** `rustc`/`cargo`, `sqlite3` CLI, `rsync`, Python `angr`/`capstone`.