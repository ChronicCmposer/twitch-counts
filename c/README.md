# c/ — the C port of twitch-counts.py

This directory holds the **pure-C reimplementation** of `twitch-counts.py`.
It is the **primary** deliverable of this repo. The Python script remains the
behavioral **oracle**: every observable byte of output (text, JSON, `--manual`,
error messages, exit codes) must match it exactly, and the snapshot harness
(`make check-twitch-counts-py`) enforces that.

The legacy hand-written ARMv8-a assembly port (`asm/tc_*.S`) is still built
and tested, but only opt-in (`make asm` / `make test-asm`); this C port is
what plain `make` / `make test` build and verify.

## The one deliberate divergence (Q8 of the design record)

The C port is byte-identical to the Python **except for the cache
fingerprint**, and that difference is intentional:

| | Python | C |
|---|---|---|
| Fingerprint input | source-AST sha256 of the Python module itself | FNV-1a 64-bit over a C-owned header + the shared parse facts |
| Version marker | derived from the Python source | `tc-cache-fp-v1` (`TC_CACHE_FP_HEAD_DEFAULT` in `cache.c`) |

`cache.c` folds the literal `tc-cache-fp-v1` plus the shared facts
(`schema=2`, the `live=`/`off=` markers, the login regex, the line format,
the state set, the process class list — the `s_fp_parts` table) through
64-bit FNV-1a, so the fingerprint changes exactly when the **C parser facts**
change, not when the Python source is edited.

**Consequence:** a `rollup.db` written by the C port is **not
interchangeable** with one written by Python (or by the assembly port, whose
fingerprint is also C/AST-independent). Never assume cross-implementation
cache compatibility. With `--no-cache` the observable output is byte-identical
across all implementations.

## Module inventory

| Module | Purpose |
|---|---|
| `util.c` | Shared helpers: puts/eputs/putu64/fail spine, string/format helpers, proleptic date math, per-OS path defaults |
| `main.c` | Entry point / orchestrator: owns session state, dispatch order, exit codes (parse 2, runtime 1, SIGINT 130; watch-SIGINT latches to exit 0) |
| `cli.c` | CLI parsing and resolution: a faithful port of CPython `_parse_known_args` (left-to-right, no GNU permutation), value parsers, `[[watch.highlight]]` |
| `config.c` | Env/config access, alias application, exclusion building; tomlc99-backed loader matching Python's config semantics |
| `core.c` | The counting core: channel resolution, dated-log listing, window completion, seeding, message/line processing |
| `cache.c` | The SQLite rollup cache: day-level rollup, schema v2, keep-days 7, the C-owned FNV-1a fingerprint (`tc-cache-fp-v1`) |
| `render.c` | Output formatting: plan → text or JSON, byte-for-byte port of the presentation half |
| `json.c` | The self-describing JSON report: `json.dump(indent=2, ensure_ascii=False)`-identical output |
| `misc.c` | `--manual`, `--emit-fish-completions`, `--complete` |
| `watch.c` | Watch mode: tailing, colorizer, fade, change notification (the only module that uses pcre2) |
| `tc_platform.h` | Shared platform header (ELF/musl vs Mach-O/Darwin selection, macros, shared constants) — the C sibling of `asm/tc_platform.h` |

Generated string blobs live here too as committed sources:
`tc_manual.inc`, `tc_fish.inc`, `tc_json_schema.inc` (the same text the asm
port embeds, as C string constants).

## Build layout

- **C port (primary):** `make` / `make all` builds `build/<os>/twitch-counts`
  and refreshes the root copy `./twitch-counts`.
- **Legacy asm port:** opt-in `make asm` builds `build/<os>/asm/twitch-counts-asm`
  and refreshes `./twitch-counts-asm`. Its objects and product live under
  `build/<os>/asm/` so they never collide with the C build.
- **Platforms:** Linux → static, musl libc, stripped (`-static
  -Wl,--gc-sections -s`); macOS → arm64 Mach-O, dynamically linked against
  libSystem (`-Wl,-dead_strip`, not stripped).

## Build / test / regenerate

```sh
make all                    # the C port (+ Linux-only fibonacci on Linux)
make test                   # full C battery: every test-tc-*.sh harness + the snapshot oracle
make check-<harness>        # one C harness, e.g. make check-tc-watch
make check-twitch-counts-py # the snapshot oracle against the C binary
make asm                    # legacy asm port (build/<os>/asm/twitch-counts-asm)
make test-asm               # legacy asm battery
make gen-inc                # force-regenerate the committed .inc blobs (asm/ and c/)
make clean                  # remove build/ and the root binaries
```

The per-module `check_<name>.c` drivers are linked by the Makefile into
`build/<os>/tc-<name>-test`; the `test-tc-*.sh` harnesses only run them
(they resolve the build tree through `$TC_BUILD`).

## Vendored libraries and the size recipe

The C port links the vendored C in `third_party/`:

- **musl 1.2.6** — static libc, bootstrapped from source into
  `third_party/musl` (no root; Linux only).
- **tomlc99** — the TOML config parser.
- **sqlite3 amalgamation** (3.46.x) — the rollup cache, compiled with an
  `SQLITE_OMIT_*` set plus `SQLITE_THREADSAFE=0`.
- **pcre2-8** (10.48) — watch-mode regexes; built per platform under
  `build/<os>/`.

All vendored C is compiled with the same compiler that compiles the port, so
the ABI never disagrees. The size-flag recipe (same for port and vendored
code): `-Os -ffunction-sections -fdata-sections
-fno-asynchronous-unwind-tables -fno-unwind-tables`, plus
`-Wl,--gc-sections -s` at link on Linux. The `-fno-*unwind-tables` pair drops
`.eh_frame` from every project/vendored object (the only `.eh_frame` in the
final binary is the ~1 KB residual from the toolchain's crt glue).

## Toolchain notes

- **Snapshot oracle:** `twitch-counts-test.py` takes the command under test
  from `TC_TEST_CMD` (a shell-style command line), falling back to
  `./twitch-counts` when unset:
  `TC_TEST_CMD="build/<os>/twitch-counts" python3 twitch-counts-test.py`.
- **SIGINT distinction:** a one-shot run interrupted by Ctrl-C exits 130
  (quietly in text mode; `{"error": "interrupted"}` under `--json`), matching
  Python's `KeyboardInterrupt`. Under **watch mode**, SIGINT is a request, not
  a crash: the loop handler latches and the watch session exits **0** — the
  watch harness asserts this (`SIGINT under watch -> 0`).