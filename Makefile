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
#   make third-party          just the vendored libraries
#   make gen-inc              force-regenerate the committed .inc blobs
#   make clean                remove build/ and the root binaries

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
ifeq ($(OS),Darwin)
CC            := clang
LINK          := $(CC) -o
TOOLCHAIN_DEP :=
else
CC            := $(MUSL_GCC)
LINK          := $(MUSL_GCC) -static -o
TOOLCHAIN_DEP := $(MUSL_GCC)
endif

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

.PHONY: all run test clean third-party gen-inc drivers $(TC) $(addprefix check-,$(HARNESSES))

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
$(MUSL_GCC):
	@if [ ! -d $(MUSL_SRC) ]; then \
		if [ ! -f $(MUSL_TAR) ]; then \
			echo "==> fetching musl $(MUSL_VER)"; \
			curl -fsSL $(MUSL_URL) -o $(MUSL_TAR); \
		fi; \
		tar xzf $(MUSL_TAR) -C $(THIRD); \
	fi
	cd $(MUSL_SRC) && ./configure --prefix=$$PWD/../musl --syslibdir=$$PWD/../musl/lib
	$(MAKE) -C $(MUSL_SRC) -j$(NPROC)
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
	cd $(PCRE2_SRC) && ./configure --disable-shared --enable-static CC=$(CC) > configure.log
	$(MAKE) -C $(PCRE2_SRC) -j$(NPROC) libpcre2-8.la > /dev/null
	mkdir -p $(PCRE2_DIR)/lib
	cp $(PCRE2_SRC)/.libs/libpcre2-8.a $(PCRE2_LIB)

# ---------------------------------------------------------------------------
# vendored C sources compiled with the platform's compiler
# ---------------------------------------------------------------------------
$(TOML_O): $(TOML)/toml.c $(TOML)/toml.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) -std=c99 -c $< -o $@

$(SQLITE_O): $(SQLITE)/sqlite3.c $(SQLITE)/sqlite3.h | $(BUILD) $(TOOLCHAIN_DEP)
	$(CC) -O2 -DSQLITE_THREADSAFE=1 -c $< -o $@

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
# ---------------------------------------------------------------------------
PRINTF_O := $(BUILD)/check_tc_printf.o

DRIVER_NAMES := cli config core cache cache-bump render misc watch

cli_OBJS        := check_tc_cli.o tc_cli.o tc_config_stub.o tc_util.o
config_OBJS     := check_tc_config.o tc_config.o tc_cli.o tc_util.o
core_OBJS       := check_tc_core.o tc_core.o tc_cli.o tc_config_stub.o tc_util.o tc_cache.o tc_json.o tc_render.o
cache_OBJS      := check_tc_cache.o tc_cache.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_json.o tc_render.o
cache-bump_OBJS := check_tc_cache.o tc_cache_bump.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_json.o tc_render.o
render_OBJS     := check_tc_render.o tc_render.o tc_json.o tc_core.o tc_cli.o tc_config.o tc_cache.o tc_util.o
misc_OBJS       := check_tc_misc.o tc_misc.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_cache.o tc_json.o tc_render.o
watch_OBJS      := check_tc_watch.o tc_watch.o tc_render.o tc_json.o tc_core.o tc_cli.o tc_config.o tc_util.o tc_cache.o tc_misc.o

# The two drivers without tc_core.o need no sqlite3.o but do need the
# harness printf wrappers; the rest link the full vendored set.
cli_LIBS        := $(PRINTF_O) $(TOML_O) $(PCRE2_LIB)
config_LIBS     := $(PRINTF_O) $(TOML_O) $(PCRE2_LIB)

DRIVERS := $(foreach n,$(DRIVER_NAMES),$(BUILD)/tc-$(n)-test)

.SECONDEXPANSION:
$(DRIVERS): $(BUILD)/tc-%-test: $$(addprefix $(BUILD)/,$$($$*_OBJS)) $$(or $$($$*_LIBS),$(LIBS))
	$(LINK) $@ $^

# tc-cache-bump-test: tc_cache.S with its fingerprint constant bumped, so
# the cache harness can prove two fingerprints coexist in one database.
$(BUILD)/tc_cache_bump.S: tc_cache.S | $(BUILD)
	sed 's/tc-cache-fp-v1/tc-cache-fp-v2/' $< > $@

$(BUILD)/tc_cache_bump.o: $(BUILD)/tc_cache_bump.S tc_platform.h tc_layout.inc | $(TOOLCHAIN_DEP)
	$(CC) -I. -c $< -o $@

drivers: $(DRIVERS)

# `make check-<name>` runs one harness (check-watch, check-cli, ...);
# `make test` runs them all in this order.
HARNESSES := twitch-counts tc-cli tc-config tc-core tc-cache tc-render tc-misc tc-watch

check-%: all drivers
	./test-$*.sh

# The full battery: every harness for this platform, fail on any failure.
# (test-twitch-counts.sh exercises the REAL twitch-counts binary; the
# Linux-only fibonacci harness runs only on Linux.)
test: all drivers
	$(if $(LINUX_TESTS),$(LINUX_TESTS),true)
	$(foreach h,$(HARNESSES),./test-$(h).sh &&) true

clean:
	rm -rf build
	rm -f $(FIB) $(TC)
