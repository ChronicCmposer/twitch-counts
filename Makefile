# Makefile for twitch-counts — C port (primary) and the legacy ARMv8-a
# assembly build.
#
#   twitch-counts: the C reimplementation of twitch-counts.py — the c/*.c
#       modules linked against libc and the vendored libraries in
#       third_party/ (tomlc99, sqlite3 amalgamation, pcre2-8).  It builds on
#       two platforms from the same sources (c/tc_platform.h selects):
#         Linux   static, musl libc (a musl toolchain is built from source
#                 into third_party/musl by the bootstrap rule below; no root)
#         macOS   arm64 Mach-O, dynamically linked against libSystem (Apple
#                 ships no static libc); Apple clang from Xcode / the CLT
#       All vendored C is compiled with the same compiler that compiles the
#       C port, so the two never disagree about the ABI.
#   twitch-counts-asm: the LEGACY hand-written ARMv8-a assembly port
#       (asm/tc_*.S).  Opt-in only, via `make asm`: it builds under
#       build/<os>/asm/ so its objects and product can never collide with the
#       C build's, and its test battery is `make test-asm`.
#   fibonacci: pure Linux syscalls, no libc (as + ld); Linux-only, not built
#       on macOS.
#
# Layout: every object, driver, third-party object and the pcre2 build live
# under build/<os>/ (build/linux, build/darwin) so a tree shared between a
# Mac and a Linux VM never hands one platform's objects to the other's
# linker.  The C binary is copied to ./twitch-counts and the legacy asm
# binary to ./twitch-counts-asm for convenience; the harnesses run the copies
# under build/<os>/.
#
# Entry points:
#   make twitch-counts        build the C port (and refresh ./twitch-counts)
#   make all                  the C port + the Linux-only fibonacci on Linux
#   make asm                  build the legacy assembly port (./twitch-counts-asm)
#   make drivers              the C per-module test drivers (build/<os>/tc-*-test)
#   make drivers-asm          the legacy asm per-module drivers (build/<os>/asm/tc-*-test)
#   make test                 the C battery: fibonacci (Linux), every
#                             test-tc-*.sh harness, and the
#                             twitch-counts-test.py snapshot oracle
#   make test-asm             the legacy asm battery against build/<os>/asm/
#   make check-<harness>      one C harness, e.g. check-tc-watch
#   make check-twitch-counts-py  the snapshot oracle against the C binary
#   make third-party        just the vendored libraries
#   make gen-inc            force-regenerate the committed .inc blobs (asm
#                           and the C string constants under c/)
#   make analyze            GCC -fanalyzer over the vendored C (Linux only)
#   make mca                llvm-mca throughput analysis of one .S module
#   make check-darwin-align cross-assemble + scan Mach-O pointer alignment (any host)
#   make decompile          Ghidra headless decompile of one function
#   make disasm             Ghidra headless disassembly of one function (no natives)
#   make clean              remove build/ and the root binaries

OS      := $(shell uname -s)
os      := $(shell uname -s | tr A-Z a-z)
BUILD   := build/$(os)
NPROC   := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

# All assembly sources, shared headers/includes and committed .inc blobs live
# under asm/; one variable drives every path to them.
ASM     := asm

# All C port sources and the shared c/tc_platform.h live under c/.
C_DIR   := c

AS      := as
LD      := ld

FIB     := fibonacci
# TC is the C product (and the root copy name); TC_ASM is the legacy asm
# product (and its root copy name).
TC      := twitch-counts
TC_ASM  := twitch-counts-asm

# `all` is the default goal: the C port plus the Linux-only fibonacci on
# Linux.  The legacy asm port is opt-in (`make asm`).
ifeq ($(OS),Linux)
LINUX_ONLY  := $(FIB)
LINUX_TESTS := ./test.sh
endif

all: $(LINUX_ONLY) $(TC)

# ---- third-party paths ------------------------------------------------------
THIRD      := third_party
MUSL_VER   := 1.2.6
PCRE2_VER  := 10.48
MUSL_SRC   := $(THIRD)/musl-$(MUSL_VER)
MUSL_DIR   := $(THIRD)/musl
MUSL_GCC   := $(abspath $(MUSL_DIR)/bin/musl-gcc)
MUSL_URL   := https://musl.libc.org/releases/musl-$(MUSL_VER).tar.gz
MUSL_TAR   := $(THIRD)/musl-$(MUSL_VER).tar.gz

TOML       := $(THIRD)/tomlc99
SQLITE     := $(THIRD)/sqlite3
PCRE2_TAR  := $(THIRD)/pcre2-$(PCRE2_VER).tar.gz
PCRE2_URL  := https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$(PCRE2_VER)/pcre2-$(PCRE2_VER).tar.gz
PCRE2_SRC  := $(BUILD)/pcre2-$(PCRE2_VER)
PCRE2_DIR  := $(BUILD)/pcre2
PCRE2_LIB  := $(PCRE2_DIR)/lib/libpcre2-8.a
TOML_O     := $(BUILD)/toml.o
SQLITE_O   := $(BUILD)/sqlite3.o
LIBS       := $(TOML_O) $(SQLITE_O) $(PCRE2_LIB)

# ---- per-platform toolchain -------------------------------------------------
# Dead-code elimination.  The vendored C (toml/sqlite3/pcre2) and the C port
# are compiled with -ffunction-sections/-fdata-sections so each function/data
# becomes its own section, then the final link garbage-collects unreferenced
# sections.  The hand-written tc_*.S objects are NOT split this way (their
# functions share one .text section per module), so gc can only drop whole
# unused modules — it will not reclaim individual assembly functions.  musl is
# built by its own Makefile (see bootstrap) and is left un-split, so its code
# is also kept whole.
#
# Platform notes:
#   Linux  (musl-gcc, GNU ld):   -Wl,--gc-sections + -s (strip symbol table)
#   macOS  (Apple clang, ld64):  -Wl,-dead_strip is the Apple equivalent of
#       --gc-sections; GNU --gc-sections does not exist in ld64.  Stripping is
#       deliberately NOT applied on Darwin (-s would strip the .dylib stubs the
#       dynamically-linked build needs to resolve), so only the link-time gc is
#       enabled there.
CFLAGS      := -ffunction-sections -fdata-sections

ifeq ($(OS),Darwin)
CC            := clang
LDFLAGS       := -Wl,-dead_strip
LINK          := $(CC) $(LDFLAGS) -o
TOOLCHAIN_DEP :=
TC_MARCH      := -mcpu=apple-m2
else
CC            := $(MUSL_GCC)
LDFLAGS       := -Wl,--gc-sections -s
LINK          := $(MUSL_GCC) -static $(LDFLAGS) -o
TOOLCHAIN_DEP := $(MUSL_GCC)
TC_MARCH      := -march=armv8.6-a
endif

# The vendored C (toml/sqlite3/pcre2) is compiled for the host CPU
# (TC_MARCH above); the hand-written tc_*.S objects stay at baseline
# ARMv8-a, so this split keeps -march/-mcpu scoped to the C compiles only.
#
# Size flags.  -Os shrinks the vendored objects, which are the bulk of the
# static binary.  It also fixes a latent pcre2 bug: the configure line below
# passes CFLAGS="$(VENDOR_CFLAGS)" with no -O at all, so pcre2 was built at
# the autoconf default -O0 and inflated ~2.5x; -Os here is the only
# optimization flag pcre2 ever sees.  -fno-asynchronous-unwind-tables
# -fno-unwind-tables (together) drop the .eh_frame the C compiles would
# otherwise emit (~89 KB in the old binary; the hand-written .S modules
# generate none).  The tc_*.S objects are deliberately NOT size-optimized:
# they compile with no -O so the hand-written code stays exactly as written.
VENDOR_CFLAGS := $(CFLAGS) $(TC_MARCH) -Os -fno-asynchronous-unwind-tables -fno-unwind-tables

# The harness scripts find their drivers through this.  `make test-asm`
# overrides it per-command with TC_BUILD=$(BUILD)/asm so the same harnesses
# resolve the legacy asm drivers and binary.
export TC_BUILD := $(BUILD)

# Per-module harnesses.  `make test` runs the C battery: the Linux-only
# fibonacci harness, every test-tc-*.sh harness against the C drivers, and
# the twitch-counts-test.py snapshot oracle against the C binary.  `make
# test-asm` runs the legacy asm battery: the same per-module harnesses plus
# test-twitch-counts.sh (the original whole-binary harness), all against
# build/<os>/asm/.
C_HARNESSES := tc-cli tc-config tc-core tc-cache tc-render tc-json tc-misc tc-watch
ASM_HARNESSES := twitch-counts $(C_HARNESSES)

# ---------------------------------------------------------------------------
# C port (primary).  The compile recipe:
#   -std=c99 -Os -ffunction-sections -fdata-sections
#   -fno-asynchronous-unwind-tables -fno-unwind-tables -I$(C_DIR)
# (identical dead-section/unwind discipline to the vendored C, minus the
# -march tuning — a micro-architecture codegen knob, not an ABI concern).
# The link goes through $(LINK) and inherits the platform's dead-code
# stripping (-static -Wl,--gc-sections -s on Linux, -Wl,-dead_strip on
# macOS).
#
# C_SRCS uses $(wildcard), so the rules work as soon as any c/*.c exists
# (a parallel agent is creating the module set); a completely empty c/ trips
# the fail-loud guard in the link recipe instead of silently producing a
# library-only binary.
C_SRCS := $(filter-out $(C_DIR)/check_%.c,$(wildcard $(C_DIR)/*.c))
C_OBJS := $(patsubst $(C_DIR)/%.c,$(BUILD)/%.o,$(C_SRCS))

# The C modules compiled into the per-module test drivers: everything except
# the orchestrator (c/main.c -> $(BUILD)/main.o), which defines the real
# main() the check_<name>.c drivers replace.  Each driver links every other
# module (the link-time gc drops what the driver never calls).
C_DRIVER_MODS := $(filter-out $(BUILD)/main.o,$(C_OBJS))

C_CFLAGS := -std=c99 -Os $(CFLAGS) -fno-asynchronous-unwind-tables -fno-unwind-tables -I$(C_DIR)

$(BUILD)/%.o: $(C_DIR)/%.c $(C_DIR)/tc_platform.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) $(C_CFLAGS) -c $< -o $@

# c/watch.c is the only C module that #includes the pcre2 header (by relative
# path into the per-platform pcre2 build tree).  Order-only on the configured
# header: only the header must exist to compile, the .a is a link
# prerequisite.  (See the pcre2 extract+configure rule above.)
$(BUILD)/watch.o: | $(PCRE2_SRC)/src/pcre2.h

# The generated string blobs are inputs to these objects: an .inc change (a
# `make gen-inc` regeneration) must rebuild them, or the object keeps the old
# text.  Mirror of the asm tc_misc.o/tc_json.o .inc dependencies above.
$(BUILD)/misc.o: $(C_DIR)/tc_manual.inc $(C_DIR)/tc_fish.inc
$(BUILD)/json.o: $(C_DIR)/tc_json_schema.inc

$(BUILD)/$(TC): $(C_OBJS) $(LIBS)
	@test -n "$(C_SRCS)" || { echo "Makefile: no C sources in $(C_DIR)/ -- the C skeleton is not in place yet"; exit 1; }
	$(LINK) $@ $(C_OBJS) $(LIBS)

# ./twitch-counts is a copy refreshed by every make (the target is phony so
# the copy is always current for the platform that last ran make).  The old
# copy is removed first: overwriting a signed Mach-O in place after it has
# been executed leaves the kernel's cached code signature stale, and macOS
# then SIGKILLs the next run (exit 137) although codesign says it is valid.
$(TC): $(BUILD)/$(TC)
	rm -f $@
	cp $< $@

# ---------------------------------------------------------------------------
# asm module inventory.  The full module set: util, the main() orchestrator,
# the CLI (which also resolves [[watch.highlight]]), config/env/exclusions,
# the counting core, the SQLite rollup cache, the renderer, the JSON report,
# the --manual/--fish/--complete module and watch mode.
ASM_MODS := tc_util tc_main tc_cli tc_config tc_core tc_cache tc_render \
            tc_json tc_misc tc_watch
ASM_OBJS := $(addprefix $(BUILD)/asm/,$(addsuffix .o,$(ASM_MODS)))
ASM_BIN  := $(BUILD)/asm/$(TC_ASM)

# Generated .inc blobs — COMMITTED sources (generated but part of the
# deliverable); regenerated only by an explicit `make gen-inc`.  The asm/
# blobs feed the legacy assembly; the c/ headers are the same text as C
# string constants for the C port (see gen-tc-c-inc.sh).
GEN_INCS   := $(ASM)/tc_manual.inc $(ASM)/tc_fish.inc $(ASM)/tc_json_schema.inc
C_GEN_INCS := $(C_DIR)/tc_manual.inc $(C_DIR)/tc_fish.inc $(C_DIR)/tc_json_schema.inc

.PHONY: all run test test-asm asm drivers drivers-asm clean third-party gen-inc \
        analyze mca check-darwin-align decompile disasm exports \
        check-twitch-counts-py $(TC) $(TC_ASM) $(addprefix check-,$(C_HARNESSES))

$(BUILD):
	mkdir -p $@

$(BUILD)/asm: | $(BUILD)
	mkdir -p $@

# ---------------------------------------------------------------------------
# fibonacci (pure Linux syscalls, no libc) — Linux only
# ---------------------------------------------------------------------------
ifeq ($(OS),Linux)
$(FIB): $(BUILD)/fibonacci.o
	$(LD) $< -o $@

$(BUILD)/fibonacci.o: $(ASM)/fibonacci.S | $(BUILD)
	$(AS) $< -o $@

# Usage: make run ARGS="10"
run: $(FIB)
	./$(FIB) $(ARGS)
endif

# ---------------------------------------------------------------------------
# third-party bootstrap
# ---------------------------------------------------------------------------
# musl toolchain (Linux only): build once from source into third_party/musl
# (no root).  --syslibdir inside the prefix makes musl-gcc's default
# (dynamic) test binaries runnable without root; the final link still uses
# -static.  Kept outside build/ because it is a toolchain, not a product.
# CFLAGS_MUSL splits musl's functions/data into per-symbol sections so the
# final -Wl,--gc-sections link can drop the libc code this binary never uses
# (the largest single dead-code source in the static link).
$(MUSL_GCC):
	@if [ ! -d $(MUSL_SRC) ]; then \
		if [ ! -f $(MUSL_TAR) ]; then \
			echo "==> fetching musl $(MUSL_VER)"; \
			curl -fsSL $(MUSL_URL) -o $(MUSL_TAR); \
		fi; \
		tar xzf $(MUSL_TAR) -C $(THIRD); \
	fi
	cd $(MUSL_SRC) && ./configure --prefix=$$PWD/../musl --syslibdir=$$PWD/../musl/lib
	$(MAKE) -C $(MUSL_SRC) -j$(NPROC) CFLAGS="$(CFLAGS)"
	$(MAKE) -C $(MUSL_SRC) install

# pcre2-8 static library, built per platform with the platform's compiler
# (a musl-built or a Darwin-built .a is not usable by the other).  The
# tarball is fetched once into third_party/; the source is extracted and
# built under build/<os>/ and only libpcre2-8.a is kept.  The configure is
# passed CFLAGS="$(VENDOR_CFLAGS)", so pcre2 inherits -Os (fixing the -O0
# inflation above) and the no-unwind-tables flags from the same source as
# the toml/sqlite3 compiles.
$(PCRE2_TAR):
	@echo "==> fetching pcre2 $(PCRE2_VER)"
	curl -fsSL $(PCRE2_URL) -o $@

# The pcre2 header is consumed directly by the C port: c/watch.c includes
# ../build/<os>/pcre2-10.48/src/pcre2.h by relative path (only that module
# does).  The real pcre2.h does not ship in the tarball — ./configure
# generates it from src/pcre2.h.in — so the extract+configure step is its
# own rule and the object compile order-only-depends on the configured
# header, instead of waiting for the whole configure+make+install chain that
# produces the .a (and instead of failing on a clean tree, where the
# previous single rule only extracted pcre2 when the LINK ran).
$(PCRE2_SRC)/src/pcre2.h: $(PCRE2_TAR) | $(BUILD) $(TOOLCHAIN_DEP)
	rm -rf $(PCRE2_SRC)
	tar xzf $(PCRE2_TAR) -C $(BUILD)
	cd $(PCRE2_SRC) && ./configure --disable-shared --enable-static CC=$(CC) CFLAGS="$(VENDOR_CFLAGS)" > configure.log

$(PCRE2_LIB): $(PCRE2_SRC)/src/pcre2.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(MAKE) -C $(PCRE2_SRC) -j$(NPROC) libpcre2-8.la > /dev/null
	mkdir -p $(PCRE2_DIR)/lib
	cp $(PCRE2_SRC)/.libs/libpcre2-8.a $(PCRE2_LIB)

# ---------------------------------------------------------------------------
# vendored C sources compiled with the platform's compiler
# ---------------------------------------------------------------------------
$(TOML_O): $(TOML)/toml.c $(TOML)/toml.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) -std=c99 -Os $(VENDOR_CFLAGS) -c $< -o $@

# sqlite3 compile flags.  The rollup cache only uses the core API
# (open/prepare/step/finalize/bind/column plus PRAGMA journal_mode=WAL), so
# the SQLITE_OMIT_* set compiles unused features out to shrink the object.
# Deliberately NOT omitted: SQLITE_OMIT_TRIGGER (the cache schema would not
# compile with it) and SQLITE_OMIT_WAL (the cache path issues PRAGMA
# journal_mode=WAL at runtime; omitting WAL breaks it).
SQLITE_OMIT := -DSQLITE_OMIT_JSON -DSQLITE_OMIT_FOREIGN_KEY \
               -DSQLITE_OMIT_AUTOVACUUM -DSQLITE_OMIT_EXPLAIN \
               -DSQLITE_OMIT_UTF16 -DSQLITE_OMIT_SHARED_CACHE \
               -DSQLITE_OMIT_LOAD_EXTENSION -DSQLITE_OMIT_LOOKASIDE \
               -DSQLITE_OMIT_DEPRECATED -DSQLITE_OMIT_PROGRESS_CALLBACK

$(SQLITE_O): $(SQLITE)/sqlite3.c $(SQLITE)/sqlite3.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) -Os -DSQLITE_THREADSAFE=0 $(SQLITE_OMIT) $(VENDOR_CFLAGS) -c $< -o $@

third-party: $(LIBS)

# ---------------------------------------------------------------------------
# generated .inc blobs (committed sources).  Regenerated ONLY by an explicit
# `make gen-inc`: the blobs embed text the Python renders for the machine
# it runs on, and a fresh checkout gives every file the same mtime, so an
# mtime-driven rule would silently rewrite committed sources on a build.
# gen-tc-misc-inc.sh and gen-tc-json-inc.sh emit the asm/ blobs;
# gen-tc-c-inc.sh emits the same text as C string constants under c/.
# ---------------------------------------------------------------------------
gen-inc:
	mkdir -p $(ASM) $(C_DIR)
	./gen-tc-misc-inc.sh
	./gen-tc-json-inc.sh
	./gen-tc-c-inc.sh
	@echo "regenerated: $(GEN_INCS) $(C_GEN_INCS)"

# ---------------------------------------------------------------------------
# legacy assembly: the tc_*.S sources (and the stubs and harness drivers) go
# through the C preprocessor — tc_platform.h selects the platform — so they
# are assembled with the compiler driver, never with bare `as`.  Everything
# builds under build/<os>/asm/ so it can never collide with the C build.
# ---------------------------------------------------------------------------
$(BUILD)/asm/%.o: $(ASM)/%.S $(ASM)/tc_platform.h $(ASM)/tc_layout.inc | $(BUILD)/asm $(TOOLCHAIN_DEP)
	$(CC) -I$(ASM) -c $< -o $@

# The embedded blobs are inputs to these objects: an .inc change must
# rebuild them.
$(BUILD)/asm/tc_misc.o: $(ASM)/tc_manual.inc $(ASM)/tc_fish.inc
$(BUILD)/asm/tc_json.o: $(ASM)/tc_json_schema.inc

$(ASM_BIN): $(ASM_OBJS) $(LIBS)
	$(LINK) $@ $(ASM_OBJS) $(LIBS)

# ./twitch-counts-asm is a copy refreshed by every `make asm` (same
# remove-then-copy dance as ./twitch-counts, for the same macOS code-signing
# reason).
$(TC_ASM): $(ASM_BIN)
	rm -f $@
	cp $< $@

asm: $(TC_ASM)

# ---------------------------------------------------------------------------
# C per-module test drivers (check_<name>.c + the C modules under test).
# The Makefile owns every driver link; the test-tc-*.sh harnesses only run
# them (they find $(BUILD) through $TC_BUILD).  One rule drives every
# driver: check_<name>.c is compiled (through the shared c/%.o rule) and
# linked against every C module except the orchestrator (main.o) plus the
# vendored libs.  The link-time gc drops the modules a driver never calls,
# so a single module list stays correct as the C sources evolve.
#
# A parallel agent owns the C sources, including the check_<name>.c drivers.
# Until a given check_<name>.c lands, the fallback rule below builds a stub
# driver that FAILS loudly, so `make drivers`/`make test` never hard-errors
# on a missing source and never silently skips the harness.
# ---------------------------------------------------------------------------
DRIVER_NAMES := cli config core cache cache-bump render misc watch json

DRIVERS := $(foreach n,$(DRIVER_NAMES),$(BUILD)/tc-$(n)-test)

# The check_<name>.c driver sources land as the parallel agent implements
# them, so the wildcard is re-read on every make: a driver flips from the
# failing stub to the real driver the moment its source exists.
REAL_NAMES := $(filter $(DRIVER_NAMES),$(patsubst $(C_DIR)/check_%.c,%,$(wildcard $(C_DIR)/check_*.c)))
STUB_NAMES := $(filter-out $(REAL_NAMES),$(DRIVER_NAMES))
REAL_DRIVERS := $(foreach n,$(REAL_NAMES),$(BUILD)/tc-$(n)-test)
STUB_DRIVERS := $(foreach n,$(STUB_NAMES),$(BUILD)/tc-$(n)-test)

# Real drivers: one static pattern rule per existing check_<name>.c, which is
# compiled (through the shared c/%.o rule) and linked against every C module
# except the orchestrator (main.o) plus the vendored libs.  The link-time gc
# drops the modules a driver never calls, so a single module list stays
# correct as the C sources evolve.  These are STATIC pattern rules (explicit
# rules), so make never runs an implicit-rule search for a driver: that search
# would prefer the stub rule below whenever the shared module objects already
# exist (their prerequisites are all present while the real rule's
# check_<name>.o would still need building) and would silently link failing
# stubs from a clean build.
$(REAL_DRIVERS): $(BUILD)/tc-%-test: $(BUILD)/check_%.o $(C_DRIVER_MODS) $(LIBS)
	$(LINK) $@ $(C_DRIVER_MODS) $< $(LIBS)

# Fallback for a missing c/check_<name>.c: link a stub whose main() prints a
# descriptive failure and exits 2, so the harness run fails loudly instead of
# the whole make run dying on a missing source.  Two guards keep the stub
# honest across source edits:
#   - the phony force prerequisite re-links the stub on every make, so a real
#     driver whose source later disappears cannot linger as an up-to-date
#     stale artifact, and
#   - the recipe drops any stale check_<name>.o (built while the source
#     existed), so when the source comes back the real rule must rebuild it
#     and the driver flips back to the real link.
# Both live only on the stub rule: the moment the source lands and the driver
# moves to the real rule above, normal incremental builds resume.
.PHONY: drivers-stub-force
drivers-stub-force:
$(STUB_DRIVERS): $(BUILD)/tc-%-test: drivers-stub-force $(C_DRIVER_MODS) $(LIBS)
	@echo "==> c/check_$*.c not found: linking a FAILING stub driver $@"
	@rm -f "$(BUILD)/check_$*.o"
	@printf '%s\n' \
		'/* GENERATED by the Makefile: c/check_$*.c is missing. */' \
		'#include <stdio.h>' \
		'int main(void) {' \
		'    fprintf(stderr, "FAIL: c/check_$*.c missing: this driver is a stub, so the harness fails loudly. Add the check source or drop it from DRIVER_NAMES.\n");' \
		'    return 2;' \
		'}' > "$(BUILD)/check_$*_stub.c"
	$(CC) $(C_CFLAGS) -c "$(BUILD)/check_$*_stub.c" -o "$(BUILD)/check_$*_stub.o"
	$(LINK) $@ $(C_DRIVER_MODS) "$(BUILD)/check_$*_stub.o" $(LIBS)

drivers: $(DRIVERS)

# ---------------------------------------------------------------------------
# legacy asm per-module test drivers (check_tc_*.S + the modules under
# test).  The Makefile owns every driver link; the test-tc-*.sh harnesses
# only run them under TC_BUILD=$(BUILD)/asm.  One object list per driver
# (the check_tc_<name>.o driver first, then the modules), one static pattern
# rule for all of them.  tc-cli-test and tc-core-test use the config stub
# instead of tc_config.o; every driver that links tc_cli.o also links toml.o
# and libpcre2-8.a because tc_cli resolves [[watch.highlight]] through them.
#
# Every driver that links tc_core.o also links tc_json.o and tc_render.o:
# the counting core's failure path emits the --json error shape through
# tc_json_err, and tc_json needs the render module's plan.
#
# tc_dump (the contract-structure printer) is a shared driver helper:
# check_tc_dump.S is the single copy.  It is linked by every driver whose
# check_<name>.S used to define its own tc_dump — core and cache — and by
# cache-bump too, because that driver reuses check_tc_cache.o and so
# inherits the tc_dump removal.
# ---------------------------------------------------------------------------
PRINTF_O := $(BUILD)/asm/check_tc_printf.o

cli_OBJS        := check_tc_cli.o tc_cli.o tc_config_stub.o tc_util.o tc_render.o tc_json.o tc_core.o tc_cache.o
config_OBJS     := check_tc_config.o tc_config.o tc_cli.o tc_util.o tc_render.o tc_json.o tc_core.o tc_cache.o
core_OBJS       := check_tc_core.o check_tc_dump.o tc_core.o tc_cli.o tc_config_stub.o tc_util.o tc_cache.o tc_json.o tc_render.o
cache_OBJS      := check_tc_cache.o check_tc_dump.o tc_cache.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_json.o tc_render.o
cache-bump_OBJS := check_tc_cache.o check_tc_dump.o tc_cache_bump.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_json.o tc_render.o
render_OBJS     := check_tc_render.o tc_render.o tc_json.o tc_core.o tc_cli.o tc_config.o tc_cache.o tc_util.o
json_OBJS       := check_tc_json.o tc_json.o tc_render.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_cache.o
misc_OBJS       := check_tc_misc.o tc_misc.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_cache.o tc_json.o tc_render.o
watch_OBJS      := check_tc_watch.o tc_watch.o tc_render.o tc_json.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_cache.o tc_misc.o

# Every driver now links the full vendored set (cli and config pull the
# render/core/cache closure through tc_report_fail and the shared helpers,
# so they link sqlite3.o like the rest).
cli_LIBS        := $(PRINTF_O) $(TOML_O) $(PCRE2_LIB) $(SQLITE_O)
config_LIBS     := $(PRINTF_O) $(TOML_O) $(PCRE2_LIB) $(SQLITE_O)

ASM_DRIVERS := $(foreach n,$(DRIVER_NAMES),$(BUILD)/asm/tc-$(n)-test)

.SECONDEXPANSION:
$(ASM_DRIVERS): $(BUILD)/asm/tc-%-test: $$(addprefix $(BUILD)/asm/,$$($$*_OBJS)) $$(or $$($$*_LIBS),$(LIBS))
	$(LINK) $@ $^

# tc-cache-bump-test: tc_cache.S with its fingerprint VERSION constant
# bumped (tc-cache-fp-v1 -> tc-cache-fp-v2), so the cache harness can prove
# two fingerprint generations coexist in one database.
#
# Fingerprint-bump contract: this sed rewrites ONLY the version literal
# (s_fp_head in tc_cache.S).  The shared fingerprint PARTS ("live=", "off=",
# the login regex) come from tc_parse_facts.inc, which tc_cache.S #includes
# — the generated bump source still carries that #include, so the parts stay
# identical to the real binary's on purpose: the bump-test must not drift
# from the parser facts, or a row the real binary wrote could never be found
# by the test's database.  A cache FORMAT change bumps the parts in
# tc_parse_facts.inc (every consumer rebuilds); a version bump here alone
# only invalidates old rows.
$(BUILD)/asm/tc_cache_bump.S: $(ASM)/tc_cache.S | $(BUILD)/asm
	sed 's/tc-cache-fp-v1/tc-cache-fp-v2/' $< > $@

$(BUILD)/asm/tc_cache_bump.o: $(BUILD)/asm/tc_cache_bump.S $(ASM)/tc_platform.h $(ASM)/tc_layout.inc | $(TOOLCHAIN_DEP)
	$(CC) -I$(ASM) -c $< -o $@

drivers-asm: $(ASM_DRIVERS)

# ---------------------------------------------------------------------------
# harnesses.  `make check-<name>` runs one C harness (check-tc-cli, ...);
# `make test` runs them all in this order.  `make test-asm` runs the legacy
# asm battery against the asm build (see the C_HARNESSES / ASM_HARNESSES
# definitions above).
#
# The check-<name> targets are explicit phony targets (the harness script is
# not a file any rule produces): GNU make skips implicit-rule search for phony
# targets, so a `check-%` PATTERN rule can never match them ("Nothing to be
# done") — every harness must declare its own recipe.  Each depends on the
# driver(s) its script runs, so the right driver is built (never the whole
# set) and then the script executes.
# ---------------------------------------------------------------------------
check-tc-cli: $(BUILD)/tc-cli-test
	./test-tc-cli.sh
check-tc-config: $(BUILD)/tc-config-test
	./test-tc-config.sh
check-tc-core: $(BUILD)/tc-core-test
	./test-tc-core.sh
check-tc-cache: $(BUILD)/tc-cache-test $(BUILD)/tc-cache-bump-test
	./test-tc-cache.sh
check-tc-render: $(BUILD)/tc-render-test
	./test-tc-render.sh
check-tc-json: $(BUILD)/tc-json-test
	./test-tc-json.sh
check-tc-misc: $(BUILD)/tc-misc-test
	./test-tc-misc.sh
check-tc-watch: $(BUILD)/tc-watch-test
	./test-tc-watch.sh

# The snapshot oracle (twitch-counts-test.py) against the C binary.  The
# script honors TC_TEST_CMD (the C-port convention); when it is unset there
# it falls back to ./twitch-counts, which is the same binary.
check-twitch-counts-py: $(BUILD)/$(TC)
	TC_TEST_CMD="$(BUILD)/$(TC)" python3 twitch-counts-test.py

# The full C battery: every harness for this platform plus the snapshot
# oracle, fail on any failure.  (The Linux-only fibonacci harness runs only
# on Linux.)
test: all drivers
	$(if $(LINUX_TESTS),$(LINUX_TESTS),true)
	$(foreach h,$(C_HARNESSES),./test-$(h).sh &&) true
	$(MAKE) check-twitch-counts-py

# The legacy asm battery.  Requires the asm drivers (built by drivers-asm
# through the ASM_DRIVERS prerequisite) and the asm product binary.
test-asm: $(TC_ASM) $(ASM_DRIVERS)
	$(foreach h,$(ASM_HARNESSES),TC_BUILD=$(BUILD)/asm TC_BIN_NAME=$(TC_ASM) ./test-$(h).sh &&) true

# ---------------------------------------------------------------------------
# static analysis & inspection (see ~/AGENTS.md "Tooling inventory")
# ---------------------------------------------------------------------------
# `make analyze` — GCC -fanalyzer over the vendored C.  Linux only: the macOS
# compiler is clang, which has no -fanalyzer.  Runs through $(MUSL_GCC) so the
# analysis sees the same musl headers the real build uses.  Console
# diagnostics; for SARIF add `-fdiagnostics-format=sarif-file`.
#
# Default is toml.c only: this box has ~6GB RAM and a full -fanalyzer pass over
# the 250k-line sqlite3 amalgamation is far too heavy here.  Include the others
# explicitly when the machine can take it:
#   make analyze ANALYZE_SRCS="third_party/tomlc99/toml.c third_party/sqlite3/sqlite3.c"
ANALYZE_SRCS := $(TOML)/toml.c

ifeq ($(OS),Linux)
analyze: $(TOOLCHAIN_DEP)
	@for src in $(ANALYZE_SRCS); do \
		echo "==> -fanalyzer $$src"; \
		$(CC) -std=c99 -O2 $(VENDOR_CFLAGS) -fanalyzer -Wpsabi -c $$src -o /dev/null \
			|| exit 1; \
	done
else
analyze:
	@echo "analyze: -fanalyzer is GCC-only; this platform assembles with $(CC)"; exit 1
endif

# `make mca MCA_SRC=asm/tc_core.S MCA_CPU=neoverse-v2` — llvm-mca throughput
# analysis of one module's AArch64 instructions.  The .S files are run through
# the C preprocessor first (tc_platform.h/tc_layout.inc), so the analyzer sees
# exactly the instructions this platform assembles.  Best-effort: directives
# llvm-mca's parser does not understand surface as errors.
MCA_SRC ?= $(ASM)/tc_core.S
MCA_CPU ?= neoverse-v2

mca: $(TOOLCHAIN_DEP)
	@command -v llvm-mca >/dev/null || { echo "mca: llvm-mca not on PATH"; exit 1; }
	@test -f $(MCA_SRC) || { echo "mca: no such source: $(MCA_SRC)"; exit 1; }
	$(CC) -I$(ASM) -E $(MCA_SRC) | llvm-mca -mtriple=aarch64-linux-gnu -mcpu=$(MCA_CPU)

# `make check-darwin-align` — catch Mach-O 8-byte-pointer-alignment link
# failures on ANY host.  ld64 rejects a pointer relocation
# (ARM64_RELOC_UNSIGNED, 8 bytes) whose address is not 8-byte aligned —
# "pointer not aligned in ..." — e.g. a .quad pointer table left misaligned
# after a run of .asciz strings.  The Darwin link path cannot run on a Linux
# host, so this target reproduces the ld64 check: it cross-assembles every
# hand-written module with clang's integrated assembler for arm64-apple-darwin
# and scans each object's relocations (llvm-readobj, or llvm-objdump -r as a
# coarser fallback) for exactly that condition.  clang is named explicitly
# (not $(CC)) because $(CC) is musl-gcc on Linux and cannot emit Mach-O;
# on macOS the same triple is the native one, so the target works there too.
#
# Module set: every asm/ .S (find, maxdepth 1), so new modules are
# covered automatically.  fibonacci.S is SKIPPED with a note: it is Linux-only
# (ELF-only .section .rodata, never linked on Darwin), so the Darwin
# pointer-alignment check does not apply.  ANY other module that fails to
# cross-assemble is RED (fail-loud: "a warning is not green" — an unverifiable
# module must not pass).  Missing tools (clang / llvm-readobj / llvm-objdump /
# python3) are also fail-loud.
#
# No build/ writes: objects and the embedded scanner go to a mktemp dir.
check-darwin-align:
	@command -v clang >/dev/null || { echo "check-darwin-align: clang not on PATH (needed for the arm64-apple-darwin cross-assembler)"; exit 1; }
	@command -v llvm-readobj >/dev/null || command -v llvm-objdump >/dev/null || { echo "check-darwin-align: neither llvm-readobj nor llvm-objdump on PATH"; exit 1; }
	@command -v python3 >/dev/null || { echo "check-darwin-align: python3 not on PATH"; exit 1; }
	@tmp=$$(mktemp -d "$${TMPDIR:-/tmp}/tc-darwin-align.XXXXXX"); \
	trap 'rm -rf "$$tmp"' EXIT HUP INT TERM; \
	anal="$$tmp/scan.py"; \
	{ printf '%s\n' \
'import re' \
'import shutil' \
'import subprocess' \
'import sys' \
'' \
'# Mach-O arm64 relocation record (llvm-readobj --relocations):' \
'#   <addr> <symnum> <len> <ext> <TYPE> <scat> <sym>' \
'# ARM64_RELOC_UNSIGNED with len 3 is an 8-byte pointer (.quad); ld64 rejects' \
'# a pointer whose address is not 8-byte aligned ("pointer not aligned in ...").' \
'REL_READOBJ_RE = re.compile(r"\s*(0x[0-9a-fA-F]+)\s+\d+\s+(\d+)\s+\d+\s+ARM64_RELOC_UNSIGNED\s+\d+\s+(.*)")' \
'# llvm-objdump -r fallback: no length field, so every UNSIGNED relocation is' \
'# treated as a pointer (coarser; this repo only emits 8-byte UNSIGNED).' \
'REL_OBJDUMP_RE = re.compile(r"\s*(0x[0-9a-fA-F]+|[0-9a-fA-F]+)\s+ARM64_RELOC_UNSIGNED\s+(\S+)")' \
'SECTION_RE = re.compile(r"Section (\S+) \{|RELOCATION RECORDS FOR \[([^\]]+)\]")' \
'' \
'def scan(text, obj, rel_re):' \
'    section = None' \
'    bad = 0' \
'    for line in text.splitlines():' \
'        m = SECTION_RE.search(line)' \
'        if m:' \
'            section = m.group(1) or m.group(2)' \
'            continue' \
'        if section == "__text":' \
'            continue  # code relocations never carry data pointers' \
'        m = rel_re.match(line)' \
'        if not m:' \
'            continue' \
'        addr = m.group(1)' \
'        if len(m.groups()) == 3:' \
'            if m.group(2) != "3":' \
'                continue  # only 8-byte pointers are alignment-checked' \
'            sym = m.group(3).strip()' \
'        else:' \
'            sym = m.group(2)' \
'        if int(addr, 16) % 8:' \
'            print(f"{obj}: {sym} @ {addr} -> MISALIGNED (in {section})")' \
'            bad = 1' \
'    return bad' \
'' \
'def main(argv):' \
'    if len(argv) != 2:' \
'        print("usage: darwin-align.py <object>", file=sys.stderr)' \
'        return 2' \
'    obj = argv[1]' \
'    if shutil.which("llvm-readobj"):' \
'        text = subprocess.run(' \
'            ["llvm-readobj", "--relocations", obj],' \
'            capture_output=True, text=True).stdout' \
'        return scan(text, obj, REL_READOBJ_RE)' \
'    text = subprocess.run(' \
'        ["llvm-objdump", "-r", obj],' \
'        capture_output=True, text=True).stdout' \
'    return scan(text, obj, REL_OBJDUMP_RE)' \
'' \
'if __name__ == "__main__":' \
'    sys.exit(main(sys.argv))' \
	; } > "$$anal"; \
	mods=$$(find $(ASM) -maxdepth 1 -name '*.S' | sort); \
	rc=0; n=0; \
	for mod in $$mods; do \
		name=$$(basename "$$mod"); \
		if [ "$$name" = "fibonacci.S" ]; then \
			echo "check-darwin-align: SKIP $$mod -- Linux-only (ELF-only .section .rodata; never linked on Darwin)"; \
			continue; \
		fi; \
		obj="$$tmp/$${name%.S}.o"; \
		n=$$((n+1)); \
		if ! clang --target=arm64-apple-darwin -I$(ASM) -c "$$mod" -o "$$obj" 2> "$$tmp/$${name%.S}.err"; then \
			echo "check-darwin-align: RED $$mod -- cannot cross-assemble for arm64-apple-darwin (fail-loud: unverifiable)"; \
			sed 's/^/    /' "$$tmp/$${name%.S}.err"; \
			rc=1; \
			continue; \
		fi; \
		if python3 "$$anal" "$$obj"; then \
			echo "check-darwin-align: PASS $$mod (0 misaligned 8-byte pointer relocations)"; \
		else \
			echo "check-darwin-align: RED $$mod -- misaligned 8-byte pointer relocation(s) listed above"; \
			rc=1; \
		fi; \
	done; \
	if [ "$$rc" -eq 0 ]; then \
		echo "check-darwin-align: GREEN -- all $$n modules aligned"; \
	else \
		echo "check-darwin-align: RED -- at least one module has a misaligned 8-byte pointer relocation"; \
	fi; \
	exit "$$rc"

# `make decompile BIN=./twitch-counts FUNC=main` — Ghidra headless decompile of
# one function to C.  Requires analyzeHeadless (installed at ~/bin, see
# AGENTS.md); the first run creates the Ghidra project and imports the binary,
# so it takes a few minutes.  The default BIN is the C binary; for the legacy
# asm port pass BIN=build/<os>/asm/twitch-counts-asm.
#
# Decompilation needs Ghidra's NATIVE decompiler for the host.  Ghidra ships
# those only for x86_64 Linux/Windows and macOS; aarch64 Linux (this host) does
# NOT ship one, so `make decompile` exits early there — use `make disasm`
# instead, which is pure-Java and works on any host.
GHIDRA_ANALYZE ?= $(HOME)/bin/analyzeHeadless
GHIDRA_HOME    := $(HOME)/bin/ghidra_12.1.3_PUBLIC
GHIDRA_PROJ    := $(BUILD)/ghidra-proj
DECOMP_BIN     ?= $(BUILD)/$(TC)
DECOMP_FUNC    ?= $(if $(FUNC),$(FUNC),main)
GHIDRA_NATIVE  := $(GHIDRA_HOME)/Ghidra/Features/Decompiler/os/linux_arm_64/decompile

decompile:
	@test -x $(GHIDRA_ANALYZE) || { echo "decompile: analyzeHeadless not found at $(GHIDRA_ANALYZE)"; exit 1; }
	@test -f $(DECOMP_BIN) || { echo "decompile: $(DECOMP_BIN) not found (build it first)"; exit 1; }
	@test -f $(GHIDRA_NATIVE) || { echo "decompile: Ghidra native decompiler not shipped for aarch64 Linux"; echo "  build it from source, or use 'make disasm' (pure-Java disassembly) instead"; exit 1; }
	@mkdir -p $(GHIDRA_PROJ)
	$(GHIDRA_ANALYZE) $(GHIDRA_PROJ) tcproj -import $(DECOMP_BIN) \
		-overwrite \
		-scriptPath scripts -postScript ghidra_decompile.java $(DECOMP_FUNC)

# `make disasm BIN=./twitch-counts FUNC=main` — Ghidra headless DISASSEMBLY of
# one function.  Pure-Java, no native decompiler needed, so it works on aarch64
# Linux where `make decompile` cannot.
disasm: 
	@test -x $(GHIDRA_ANALYZE) || { echo "disasm: analyzeHeadless not found at $(GHIDRA_ANALYZE)"; exit 1; }
	@test -f $(DECOMP_BIN) || { echo "disasm: $(DECOMP_BIN) not found (build it first)"; exit 1; }
	@mkdir -p $(GHIDRA_PROJ)
	$(GHIDRA_ANALYZE) $(GHIDRA_PROJ) tcproj -import $(DECOMP_BIN) \
		-overwrite \
		-scriptPath scripts -postScript ghidra_disasm.java $(DECOMP_FUNC)

# `make exports` — audit the exported (.globl) FUNCTION symbols of the
# assembly modules against the hand-written "Exported symbol contracts"
# section in tc_layout.inc.  The contracts are documented, not generated;
# this target prints the ground truth nm sees in the OBJECTS (the final
# binaries are stripped on Linux, the objects are not), so a writer can
# verify the doc's symbol list or regenerate it after a refactor.  Best on
# Linux (GNU/LLVM nm); the module objects are what it inspects.
exports: $(ASM_OBJS)
	@for o in $(ASM_OBJS); do \
		echo "== $$(basename $$o)"; \
		nm -g $$o | awk '$$2 == "T" { print "  " $$3 }'; \
	done

clean:
	rm -rf build
	rm -f $(FIB) $(TC) $(TC_ASM)
	rm -f *.o tc-*-test twitch-counts-full