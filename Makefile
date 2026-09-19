# Makefile for fibonacci.S, twitch-counts.S and twitch-counts-full (tc_*.S)
# — AArch64 assembly programs.
#
#   fibonacci / twitch-counts: pure syscalls, no libc (as + ld).
#   twitch-counts-full: the FULL port of twitch-counts.py — hand-written
#       ARMv8-a assembly statically linked against musl libc and the
#       vendored libraries in third_party/ (tomlc99, sqlite3 amalgamation,
#       pcre2-8).  All vendored C is compiled with $(MUSL_GCC) so the static
#       link has no glibc dependency.
#
# Build commands (as specified):
#   as fibonacci.S -o fibonacci.o
#   ld  fibonacci.o -o fibonacci
#   as twitch-counts.S -o twitch-counts.o
#   ld  twitch-counts.o -o twitch-counts
#   $(MUSL_GCC) -static -o twitch-counts-full $(TC_OBJS) \
#       third_party/tomlc99/toml.o third_party/sqlite3/sqlite3.o \
#       third_party/pcre2/install/lib/libpcre2-8.a
#
# Toolchain: musl is built from source into third_party/musl by the
# bootstrap rule below (no root needed; see third_party/README.md for the
# exact configure invocation and source URLs).

AS      := as
LD      := ld
NPROC   := $(shell nproc)

TARGET  := fibonacci
TARGET2 := twitch-counts
TARGET3 := twitch-counts-full

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
PCRE2_SRC  := $(THIRD)/pcre2-$(PCRE2_VER)
PCRE2_DIR  := $(THIRD)/pcre2/install
PCRE2_LIB  := $(PCRE2_DIR)/lib/libpcre2-8.a
PCRE2_URL  := https://github.com/PCRE2Project/pcre2/releases/download/pcre2-$(PCRE2_VER)/pcre2-$(PCRE2_VER).tar.gz
PCRE2_TAR  := $(THIRD)/pcre2-$(PCRE2_VER).tar.gz

# Object files for twitch-counts-full (exact order is for readability only).
# The full module inventory: util, the main() orchestrator, the CLI (which
# also resolves [[watch.highlight]]), config/env/exclusions, the counting
# core, the SQLite rollup cache, the renderer, the JSON report, the
# --manual/--fish/--complete module and watch mode.
TC_OBJS := tc_util.o tc_main.o tc_cli.o tc_config.o tc_core.o tc_cache.o \
           tc_render.o tc_json.o tc_misc.o tc_watch.o

# Generated .inc blobs — COMMITTED sources (generated but part of the
# deliverable); these rules only regenerate when the generator is newer, and
# `make gen-inc` forces regeneration.
GEN_INCS   := tc_manual.inc tc_fish.inc tc_json_schema.inc

.PHONY: all run test clean third-party gen-inc

all: $(TARGET) $(TARGET2) $(TARGET3)

# ---------------------------------------------------------------------------
# fibonacci (pure syscalls, no libc)
# ---------------------------------------------------------------------------
$(TARGET): fibonacci.o
	$(LD) $< -o $@

fibonacci.o: fibonacci.S
	$(AS) $< -o $@

# ---------------------------------------------------------------------------
# twitch-counts (pure syscalls, no libc)
# ---------------------------------------------------------------------------
$(TARGET2): twitch-counts.o
	$(LD) $< -o $@

twitch-counts.o: twitch-counts.S
	$(AS) $< -o $@

# ---------------------------------------------------------------------------
# third-party bootstrap
# ---------------------------------------------------------------------------
# musl toolchain: build once from source into third_party/musl (no root).
# --syslibdir inside the prefix makes musl-gcc's default (dynamic) test
# binaries runnable without root; the final link still uses -static.
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

# pcre2-8 static library, built with the musl toolchain (glibc-built .a
# files are NOT usable in the static musl binary).
$(PCRE2_LIB): $(MUSL_GCC)
	@if [ ! -d $(PCRE2_SRC) ]; then \
		if [ ! -f $(PCRE2_TAR) ]; then \
			echo "==> fetching pcre2 $(PCRE2_VER)"; \
			curl -fsSL $(PCRE2_URL) -o $(PCRE2_TAR); \
		fi; \
		tar xzf $(PCRE2_TAR) -C $(THIRD); \
	fi
	cd $(PCRE2_SRC) && ./configure --prefix=$$PWD/../pcre2/install --disable-shared --enable-static CC=$(MUSL_GCC)
	$(MAKE) -C $(PCRE2_SRC) -j$(NPROC)
	$(MAKE) -C $(PCRE2_SRC) install

# ---------------------------------------------------------------------------
# vendored C sources compiled with the musl toolchain
# ---------------------------------------------------------------------------
$(TOML)/toml.o: $(TOML)/toml.c $(TOML)/toml.h | $(MUSL_GCC)
	$(MUSL_GCC) -std=c99 -c $< -o $@

$(SQLITE)/sqlite3.o: $(SQLITE)/sqlite3.c $(SQLITE)/sqlite3.h | $(MUSL_GCC)
	$(MUSL_GCC) -O2 -DSQLITE_THREADSAFE=1 -c $< -o $@

third-party: $(TOML)/toml.o $(SQLITE)/sqlite3.o $(PCRE2_LIB)

# ---------------------------------------------------------------------------
# generated .inc blobs (committed sources; regenerate only when the
# generator is newer, or explicitly with `make gen-inc`)
# ---------------------------------------------------------------------------
tc_manual.inc tc_fish.inc: gen-tc-misc-inc.sh twitch-counts.py
	./gen-tc-misc-inc.sh

tc_json_schema.inc: gen-tc-json-inc.sh twitch-counts.py
	./gen-tc-json-inc.sh

# The embedded blobs are inputs to these objects: an .inc change must rebuild
# them (the generic %.o rule below only names the .S file).
tc_misc.o: tc_manual.inc tc_fish.inc
tc_json.o: tc_json_schema.inc

gen-inc: $(GEN_INCS)
	@echo "regenerated: $(GEN_INCS)"

# ---------------------------------------------------------------------------
# twitch-counts-full
# ---------------------------------------------------------------------------
$(TARGET3): $(TC_OBJS) $(TOML)/toml.o $(SQLITE)/sqlite3.o $(PCRE2_LIB)
	$(MUSL_GCC) -static -o $@ $(TC_OBJS) $(TOML)/toml.o $(SQLITE)/sqlite3.o $(PCRE2_LIB)

# Generic assembly rule (tc_*.S -> tc_*.o); the explicit rules above take
# precedence for fibonacci.o / twitch-counts.o.
%.o: %.S
	$(AS) $< -o $@

# Usage: make run ARGS="10"
run: all
	./$(TARGET) $(ARGS)

# ---------------------------------------------------------------------------
# per-phase driver binaries for the harnesses that expect a PRE-BUILT driver
# (test-tc-core.sh / test-tc-cache.sh; the cli/config/render/misc/watch
# harnesses build their own inside the script)
# ---------------------------------------------------------------------------
tc-core-test: check_tc_core.o tc_core.o tc_cli.o tc_config_stub.o tc_util.o \
		tc_cache.o $(TOML)/toml.o $(SQLITE)/sqlite3.o
	$(MUSL_GCC) -static -o $@ $^

tc-cache-test: check_tc_cache.o tc_cache.o tc_core.o tc_cli.o tc_config.o \
		tc_util.o $(TOML)/toml.o $(SQLITE)/sqlite3.o
	$(MUSL_GCC) -static -o $@ $^

# The full battery: every harness, in build order, fail on any failure.
# (test-twitch-counts-full.sh exercises the REAL twitch-counts-full binary.)
# The core/cache harnesses use pre-built drivers, so build them first.
test: all tc-core-test tc-cache-test
	./test.sh
	./test-twitch-counts.sh
	./test-twitch-counts-full.sh
	./test-tc-cli.sh
	./test-tc-config.sh
	./test-tc-core.sh
	./test-tc-cache.sh
	./test-tc-render.sh
	./test-tc-misc.sh
	./test-tc-watch.sh

clean:
	rm -f $(TARGET) $(TARGET2) $(TARGET3) fibonacci.o twitch-counts.o
	rm -f $(TC_OBJS)
	rm -f tc-util-test tc-main-test tc-cli-test tc-config-test tc-core-test \
	      tc-cache-test tc-render-test tc-misc-test tc-watch-test
	rm -f check_tc_util.o check_tc_main.o check_tc_cli.o check_tc_config.o \
	      check_tc_core.o check_tc_cache.o check_tc_render.o check_tc_misc.o \
	      check_tc_watch.o
	rm -f $(TOML)/toml.o $(SQLITE)/sqlite3.o
	rm -rf $(PCRE2_DIR)