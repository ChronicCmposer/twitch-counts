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
    `tc_read_all`, ...) and the Wave-1 shared constants
  - `tc_cli.S` — CLI parsing, resolves `[[watch.highlight]]`
  - `tc_config.S` — config / env / exclusions
  - `tc_core.S` — the counting core
  - `tc_cache.S` — the SQLite rollup cache
  - `tc_render.S` — output formatting
  - `tc_json.S` — the JSON report
  - `tc_misc.S` — `--manual` / `--fish` / `--complete`
  - `tc_watch.S` — watch mode
- `*.inc` (`tc_manual.inc`, `tc_fish.inc`, `tc_json_schema.inc`, plus
  `tc_parse_facts.inc`) — committed generated blobs (regenerate only with `make gen-inc`).
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

1. **ISA**: one `.arch` directive per module, declared to the project's
   target (currently `armv8-a`); no `.arch_extension` that silently enables
   features the module does not declare (in particular never `sve`, `sve2`,
   `i8mm`, `bf16` unless the build target truly requires them), no `.cpu`.
   The in-source `.arch` overrides any `-march`, so it is the gate.
2. **Callee-saved registers**: preserve **x19–x28 and x29** across every
   `bl` (AAPCS64). A function may use them but must restore them before
   `ret`.
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

### Naming rules

- Exported symbols: **`tc_`** prefix (e.g. `tc_strlen`, `tc_puts`,
  `tc_fail`, `tc_fmt_u64`, `tc_read_all`) — this is the repo's convention,
  declared in `tc_layout.inc`.
- Module-local symbols: **module prefix** — `main_`, `util_`, `cli_`,
  `config_`, `core_`, `cache_`, `render_`, `json_`, `misc_`, `watch_`
  (matching the module's purpose).
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
  Python reference; (c) the disassembly is reviewed; (d) **both checker
  scripts are green**. A function is "unverified" until Gate 3 passes.
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
```

What it does: (1) rejects any `.arch` above its configured ceiling and any
`.arch_extension` (and any `.cpu`); (2) assembles the module and
disassembles the object; (3) scans the disassembly for instructions or
registers that require a higher ISA (pointer-auth, `bti`, `ssbb`/`pssbb`,
SVE/SVE2 `z`/`p` registers, bf16/i8mm/dotprod, memtag).

**Green** = directive scan clean, object assembles, disassembly scan clean.
**Red** (non-zero exit, `file:line` printed) = a `.arch`/`.arch_extension`
violation or a >ceiling instruction present in the object. An instruction
the assembler *rejects* at the ceiling (e.g. `bfdot`) prints a **warning**,
not red: it cannot silently enter the binary — the build gate already stops
it. A warning is not green; a module that produces one does not build.

**Repo note (current status — read before trusting a result):** the checker
was imported from the `core/controller/asm/` playbook project and still
enforces the playbook's exact `armv8.2-a` ceiling. This repo's modules
declare `.arch armv8-a` (built with `-march=armv8.6-a` via the Makefile), so
`./check-isa.sh tc_*.S` currently reports **RED on every module at the
directive scan** (`must be exactly 'armv8.2-a'`), while the disassembly scan
is clean. The checker's ceiling and the repo's ISA policy must be reconciled
before a check can go green — either widen the checker to this repo's
declared target or raise the modules' `.arch`; do **not** silently pick one
without deciding the project's ISA policy. Treat a RED today as "the
directive gate disagrees with the playbook ceiling", not as proof that the
module contains a >armv8.6-a instruction.

#### `check-clobbers.sh` — clobber discipline (AAPCS64 callee-saved)

```sh
./check-clobbers.sh tc_*.S
./check-clobbers.sh --preprocess tc_core.S     # macro-expanded text
```

What it does: for every function it checks (a) every write to x19–x28 is
covered by `PROLOGUE n`/`EPILOGUE n` or a balanced `stp`/`ldp` pair, and
each write lies inside its save/restore window; (b) `stp`/`ldp` of
callee-saved registers are balanced; (c) writes to x29 have a matching
`stp x29,x30` frame record; bonus: any use of x18 is flagged.

**Green** = no findings. **Red** (non-zero exit, `file:line` printed) = one
or more findings.

**Known blind spot:** the clobber checker reads the raw `.S`; registers
hidden inside CPP macros are invisible to it. Use `--preprocess` to re-run on
the macro-expanded text (line numbers then refer to the preprocessed stream),
and always review macro bodies by hand. See the comment header in the script
for a full precision statement.

**Repo note (current status — read before trusting a result):** the checker
was imported from the `core/controller/asm/` playbook project and hunts
exported **`cc_`** function labels (its `FUNC_START_RE` matches
`^\s*cc_[A-Za-z0-9_]+\s*:`). This repo exports `tc_` symbols, so
`./check-clobbers.sh tc_*.S` currently reports `functions=0 … GREEN` on every
module — a **trivially green result that provides no coverage**. Do not
mistake that GREEN for proof of clobber discipline. Until the checker learns
the `tc_` prefix (and the module files it scans by name), human review of
every `PROLOGUE`/`EPILOGUE` window is the real gate.

### What "green" means

- `check-isa.sh`: every module printed `GREEN` and the script exited 0.
- `check-clobbers.sh`: every module printed `GREEN` and the script exited 0
  **and** reported a non-zero function count (see the repo note above — a
  `functions=0` GREEN is vacuous).
- A module is "green" only when **both** scripts exit 0 on it. Anything else
  — a red finding, or an ISA warning — means the module must be fixed.

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
- [ ] x19–x28 and x29 preserved across every `bl`; restored before `ret`
- [ ] `sp` 16-byte aligned at every call site
- [ ] no x18, no `;`, no `.equ`
- [ ] constants are CPP macros; `PROLOGUE n`/`EPILOGUE n` matched
- [ ] naming: `tc_` / module prefix / `.L` labels
- [ ] ≤ 80 instructions per function
- [ ] `check-isa.sh` and `check-clobbers.sh` green **with real coverage**
  (see the checkers' repo notes)
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