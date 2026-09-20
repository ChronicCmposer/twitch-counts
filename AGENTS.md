# AGENTS.md — shirley-asm (AArch64 assembly)

Hand-written **ARMv8-A / ARMv8.6-A AArch64 assembly** project. Two deliverables, both assembled by the project's own Makefile:

- **`twitch-counts`** — port of `twitch-counts.py`: hand-written `tc_*.S` modules linked against libc and the vendored libraries under `third_party/` (tomlc99, sqlite3 amalgamation, pcre2-8). Builds from the same sources on two platforms (`tc_platform.h` selects):
  - **Linux** — static, musl libc (musl toolchain bootstrapped from source into `third_party/musl`; no root).
  - **macOS** — arm64 Mach-O, dynamically linked against libSystem.
- **`fibonacci`** — pure Linux syscalls, no libc (`as` + `ld`); Linux-only.

## Repo layout
- `tc_*.S`, `tc_platform.h`, `tc_layout.inc` — the assembly modules.
- `*.inc` (`tc_manual.inc`, `tc_fish.inc`, `tc_json_schema.inc`) — committed generated blobs (regenerate only with `make gen-inc`).
- `build/<os>/` — per-platform objects, drivers, third-party build products (never share objects between Linux/macOS).
- `third_party/` — vendored C (toml, sqlite3), bootstrapped musl, fetched pcre2 tarball.
- `check_tc_*.S` + `test-tc-*.sh` — per-module test drivers and harnesses.
- `gen-tc-*.sh` — regenerate the `.inc` blobs.

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

The `.S` sources go through the C preprocessor (`tc_platform.h`), so they are assembled with the **compiler driver** (`$(CC)` = `musl-gcc` on Linux, `clang` on macOS), never bare `as`.

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