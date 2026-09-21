# Makefile for twitch-counts (tc_*.S) and fibonacci.S — AArch64 assembly.
#
#   twitch-counts: the port of twitch-counts.py — hand-written ARMv8-a
#       assembly linked against libc and the vendored libraries in
#       third_party/ (tomlc99, sqlite3 amalgamation, pcre2-8).  It builds on
#       two platforms from the same sources (tc_platform.h selects):
#         Linux   static, musl libc (a musl toolchain is built from source
#                 into third_party/musl by the bootstrap rule below; no root)
#         macOS   arm64 Mach-O, dynamically linked against libSystem (Apple
#                 ships no static libc); Apple clang from Xcode / the CLT
#       All vendored C is compiled with the same compiler that assembles the
#       .S files, so the two never disagree about the ABI.
#   fibonacci: pure Linux syscalls, no libc (as + ld); Linux-only, not built
#       on macOS.
#
# Layout: every object, driver, third-party object and the pcre2 build live
# under build/<os>/ (build/linux, build/darwin) so a tree shared between a
# Mac and a Linux VM never hands one platform's objects to the other's
# linker.  The final binary is copied to ./twitch-counts for convenience;
# the harnesses run the copy under build/<os>/.
#
# Entry points:
#   make twitch-counts        build (and refresh ./twitch-counts)
#   make all                  + the Linux-only fibonacci on Linux
#   make drivers              the per-module test drivers (build/<os>/tc-*-test)
#   make test                 every harness for this platform
#   make check-<harness>      one harness, e.g. check-tc-watch
#   make third-party        just the vendored libraries
#   make gen-inc            force-regenerate the committed .inc blobs
#   make analyze            GCC -fanalyzer over the vendored C (Linux only)
#   make mca                llvm-mca throughput analysis of one .S module
#   make decompile          Ghidra headless decompile of one function
#   make disasm             Ghidra headless disassembly of one function (no natives)
#   make clean              remove build/ and the root binaries

OS      := $(shell uname -s)
os      := $(shell uname -s | tr A-Z a-z)
BUILD   := build/$(os)
NPROC   := $(shell nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)

AS      := as
LD      := ld

FIB     := fibonacci
TC      := twitch-counts

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
# Dead-code elimination.  The vendored C (toml/sqlite3/pcre2) is compiled with
# -ffunction-sections/-fdata-sections so each function/data becomes its own
# section, then the final link garbage-collects unreferenced sections.  The
# hand-written tc_*.S objects are NOT split this way (their functions share one
# .text section per module), so gc can only drop whole unused modules — it will
# not reclaim individual assembly functions.  musl is built by its own Makefile
# (see bootstrap) and is left un-split, so its code is also kept whole.
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
VENDOR_CFLAGS := $(CFLAGS) $(TC_MARCH)

# The harness scripts find their drivers through this.
export TC_BUILD := $(BUILD)

# Object files for twitch-counts.  The full module inventory: util, the
# main() orchestrator, the CLI (which also resolves [[watch.highlight]]),
# config/env/exclusions, the counting core, the SQLite rollup cache, the
# renderer, the JSON report, the --manual/--fish/--complete module and watch
# mode.
TC_MODS := tc_util tc_main tc_cli tc_config tc_core tc_cache tc_render \
           tc_json tc_misc tc_watch
TC_OBJS := $(addprefix $(BUILD)/,$(addsuffix .o,$(TC_MODS)))

# Generated .inc blobs — COMMITTED sources (generated but part of the
# deliverable); regenerated only by an explicit `make gen-inc`.
GEN_INCS   := tc_manual.inc tc_fish.inc tc_json_schema.inc

.PHONY: all run test clean third-party gen-inc drivers analyze mca decompile disasm exports $(TC) $(addprefix check-,$(HARNESSES))

ifeq ($(OS),Linux)
LINUX_ONLY  := $(FIB)
LINUX_TESTS := ./test.sh
endif

all: $(LINUX_ONLY) $(TC)

$(BUILD):
	mkdir -p $@

# ---------------------------------------------------------------------------
# fibonacci (pure Linux syscalls, no libc) — Linux only
# ---------------------------------------------------------------------------
ifeq ($(OS),Linux)
$(FIB): $(BUILD)/fibonacci.o
	$(LD) $< -o $@

$(BUILD)/fibonacci.o: fibonacci.S | $(BUILD)
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
# built under build/<os>/ and only libpcre2-8.a is kept.
$(PCRE2_TAR):
	@echo "==> fetching pcre2 $(PCRE2_VER)"
	curl -fsSL $(PCRE2_URL) -o $@

$(PCRE2_LIB): $(PCRE2_TAR) | $(BUILD) $(TOOLCHAIN_DEP)
	rm -rf $(PCRE2_SRC)
	tar xzf $(PCRE2_TAR) -C $(BUILD)
	cd $(PCRE2_SRC) && ./configure --disable-shared --enable-static CC=$(CC) CFLAGS="$(VENDOR_CFLAGS)" > configure.log
	$(MAKE) -C $(PCRE2_SRC) -j$(NPROC) libpcre2-8.la > /dev/null
	mkdir -p $(PCRE2_DIR)/lib
	cp $(PCRE2_SRC)/.libs/libpcre2-8.a $(PCRE2_LIB)

# ---------------------------------------------------------------------------
# vendored C sources compiled with the platform's compiler
# ---------------------------------------------------------------------------
$(TOML_O): $(TOML)/toml.c $(TOML)/toml.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) -std=c99 -O2 $(VENDOR_CFLAGS) -c $< -o $@

$(SQLITE_O): $(SQLITE)/sqlite3.c $(SQLITE)/sqlite3.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) -O2 -DSQLITE_THREADSAFE=0 $(VENDOR_CFLAGS) -c $< -o $@

third-party: $(LIBS)

# ---------------------------------------------------------------------------
# generated .inc blobs (committed sources).  Regenerated ONLY by an explicit
# `make gen-inc`: the blobs embed text the Python renders for the machine
# it runs on, and a fresh checkout gives every file the same mtime, so an
# mtime-driven rule would silently rewrite committed sources on a build.
# ---------------------------------------------------------------------------
gen-inc:
	./gen-tc-misc-inc.sh
	./gen-tc-json-inc.sh
	@echo "regenerated: $(GEN_INCS)"

# ---------------------------------------------------------------------------
# assembly: the tc_*.S sources (and the stubs and harness drivers) go
# through the C preprocessor — tc_platform.h selects the platform — so they
# are assembled with the compiler driver, never with bare `as`.
# ---------------------------------------------------------------------------
$(BUILD)/%.o: %.S tc_platform.h tc_layout.inc | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) -I. -c $< -o $@

# The embedded blobs are inputs to these objects: an .inc change must
# rebuild them.
$(BUILD)/tc_misc.o: tc_manual.inc tc_fish.inc
$(BUILD)/tc_json.o: tc_json_schema.inc

# ---------------------------------------------------------------------------
# twitch-counts
# ---------------------------------------------------------------------------
$(BUILD)/$(TC): $(TC_OBJS) $(LIBS)
	$(LINK) $@ $(TC_OBJS) $(LIBS)

# ./twitch-counts is a copy refreshed by every make (the target is phony so
# the copy is always current for the platform that last ran make).
$(TC): $(BUILD)/$(TC)
	cp -f $< $@

# ---------------------------------------------------------------------------
# per-module test drivers (check_tc_*.S + the modules under test).  The
# Makefile owns every driver link; the test-tc-*.sh harnesses only run
# them (they find $(BUILD) through $TC_BUILD).  One object list per driver
# (the check_tc_<name>.o driver first, then the modules), one static
# pattern rule for all of them.  tc-cli-test and tc-core-test use the
# config stub instead of tc_config.o; every driver that links tc_cli.o
# also links toml.o and libpcre2-8.a because tc_cli resolves
# [[watch.highlight]] through them.
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
PRINTF_O := $(BUILD)/check_tc_printf.o

DRIVER_NAMES := cli config core cache cache-bump render misc watch json

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

DRIVERS := $(foreach n,$(DRIVER_NAMES),$(BUILD)/tc-$(n)-test)

.SECONDEXPANSION:
$(DRIVERS): $(BUILD)/tc-%-test: $$(addprefix $(BUILD)/,$$($$*_OBJS)) $$(or $$($$*_LIBS),$(LIBS))
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
$(BUILD)/tc_cache_bump.S: tc_cache.S | $(BUILD)
	sed 's/tc-cache-fp-v1/tc-cache-fp-v2/' $< > $@

$(BUILD)/tc_cache_bump.o: $(BUILD)/tc_cache_bump.S tc_platform.h tc_layout.inc | $(TOOLCHAIN_DEP)
	$(CC) -I. -c $< -o $@

drivers: $(DRIVERS)

# `make check-<name>` runs one harness (check-watch, check-cli, ...);
# `make test` runs them all in this order.
HARNESSES := twitch-counts tc-cli tc-config tc-core tc-cache tc-render tc-json tc-misc tc-watch

check-%: all drivers
	./test-$*.sh

# The full battery: every harness for this platform, fail on any failure.
# (test-twitch-counts.sh exercises the REAL twitch-counts binary; the
# Linux-only fibonacci harness runs only on Linux.)
test: all drivers
	$(if $(LINUX_TESTS),$(LINUX_TESTS),true)
	$(foreach h,$(HARNESSES),./test-$(h).sh &&) true

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

# `make mca MCA_SRC=tc_core.S MCA_CPU=neoverse-v2` — llvm-mca throughput
# analysis of one module's AArch64 instructions.  The .S files are run through
# the C preprocessor first (tc_platform.h/tc_layout.inc), so the analyzer sees
# exactly the instructions this platform assembles.  Best-effort: directives
# llvm-mca's parser does not understand surface as errors.
MCA_SRC ?= tc_core.S
MCA_CPU ?= neoverse-v2

mca: $(TOOLCHAIN_DEP)
	@command -v llvm-mca >/dev/null || { echo "mca: llvm-mca not on PATH"; exit 1; }
	@test -f $(MCA_SRC) || { echo "mca: no such source: $(MCA_SRC)"; exit 1; }
	$(CC) -I. -E $(MCA_SRC) | llvm-mca -mtriple=aarch64-linux-gnu -mcpu=$(MCA_CPU)

# `make decompile BIN=./twitch-counts FUNC=main` — Ghidra headless decompile of
# one function to C.  Requires analyzeHeadless (installed at ~/bin, see
# AGENTS.md); the first run creates the Ghidra project and imports the binary,
# so it takes a few minutes.
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
exports: $(TC_OBJS)
	@for o in $(TC_OBJS); do \
		echo "== $$(basename $$o)"; \
		nm -g $$o | awk '$$2 == "T" { print "  " $$3 }'; \
	done

clean:
	rm -rf build
	rm -f $(FIB) $(TC)
