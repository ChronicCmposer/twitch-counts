// ============================================================================
// tc_main.S — main() for twitch-counts-full (the FULL port of twitch-counts.py)
// ============================================================================
//
//  Target:     AArch64 (ARMv8-a), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static — musl libc + crt1.o (startfile) + vendored
//              third_party/tomlc99/toml.o, third_party/sqlite3/sqlite3.o,
//              third_party/pcre2/install/lib/libpcre2-8.a:
//
//    third_party/musl/bin/musl-gcc -static -o twitch-counts-full \
//        tc_util.o tc_main.o tc_cli.o tc_config.o tc_core.o tc_cache.o \
//        tc_render.o tc_json.o tc_misc.o tc_watch.o \
//        third_party/tomlc99/toml.o third_party/sqlite3/sqlite3.o \
//        third_party/pcre2/install/lib/libpcre2-8.a
//
//  Behavior — main() dispatch (Python main(), twitch-counts.py 3996-4028)
//  ------------------------------------------------------------------
//    1. tc_cli_parse(argc, argv): argparse-equivalent parse + resolution.
//       Parse errors print the wrapped usage + "<prog>: error: ..." and
//       exit 2; resolution errors print "error: ..." and exit 1; --help
//       prints the full help and exits 0.  Nothing in main() runs until the
//       CLI has either succeeded or exited on its own.
//    2. TC_F_MANUAL        -> tc_misc_manual()            -> return 0
//    3. TC_F_EMIT_FISH     -> tc_misc_fish()              -> return 0
//    4. TC_F_COMPLETE_GIVEN-> tc_misc_complete(TC_O_COMPLETE_KIND) -> return 0
//    5. TC_F_WATCH_PRESENT -> tc_build_exclusions();
//                             tc_cache_open();
//                             rc = tc_watch_run();
//                             tc_cache_close();
//                             if rc == 130 && TC_F_JSON: write
//                                 {"error": "interrupted"} to stderr;
//                             return rc   (0 clean / 130 SIGINT)
//    6. otherwise (one-shot report):
//                             tc_build_exclusions();
//                             tc_cache_open();      (resolves the channel
//                                                    idempotently; the cache
//                                                    row renders from
//                                                    tc_cache_status)
//                             tc_count_run();       (ConfigError-equivalents
//                                                    tc_fail with the exact
//                                                    text + exit 1)
//                             tc_render_report();   (plan, then JSON or text)
//                             tc_cache_close();
//                             return 0
//
//  SIGINT handling (Python's except KeyboardInterrupt)
//  ---------------------------------------------------
//    Text mode leaves SIGINT at the default disposition: the process dies by
//    the signal and the shell reports 130, which is observably identical to
//    Python's KeyboardInterrupt -> report_failure(..., code=130,
//    announce=False) printing nothing and exiting 130.
//    --json installs tc_main_sigint_handler BEFORE the one-shot run.  The
//    handler is async-signal-safe (write(2) + _exit only) and emits the
//    report_failure JSON shape  {"error": "interrupted"}  to stderr and
//    exits 130, matching Python's json.dump + code=130.  The previous
//    disposition is restored after tc_cache_close.
//    The watch path installs NOTHING: tc_watch.S owns its loop SIGINT
//    handler (cursor restored, flushed) and returns 130; main() only adds
//    the JSON error shape afterwards.
//
//  Register roles in main()
//  ------------------------
//    x19 = argc              (consumed by the single tc_cli_parse call)
//    x20 = argv              (consumed by the single tc_cli_parse call)
//    x21 = tc_opts base      (persists across every bl: flags, complete kind)
//    x22 = watch return code (0 or 130; set before tc_cache_close)
//    x23 = previous SIGINT disposition (returned by the first signal(); only
//          used on the --json one-shot path)
//    x24 = pushed for pair balance, otherwise unused
//    The SIGINT handler (tc_main_sigint_handler) is a separate leaf entered
//    by the kernel: it preserves callee-saved registers by construction (it
//    uses none), saves x29/x30 for the write() call, and never returns
//    (_exit), so no restore is needed.
//
//  Library-call table (everything main() itself calls)
//  ---------------------------------------------------
//    tc_cli_parse(x0=argc, x1=argv)                  -> 0 (exits 2/1/0 itself)
//    tc_build_exclusions()                           -> 0
//    tc_cache_open() / tc_cache_close()              -> 0
//    tc_count_run()                                  -> 0
//    tc_render_report()                              -> 0
//    tc_watch_run()                                  -> 0 or 130
//    tc_misc_manual() / tc_misc_fish()               -> 0
//    tc_misc_complete(x0=TC_COMPLETE_*)              -> 0
//    signal(x0=SIGINT, x1=handler)                   -> previous disposition
//    write(x0=fd, x1=buf, x2=len)                    -> ssize_t (w0)
//    fflush(x0=NULL)                                 -> int (w0)
//    _exit(x0=130)                                   -> noreturn
//
//  Module map (what each tc_*.S provides)
//  --------------------------------------
//    tc_util.S    shared utilities: tc_strlen (clobbers x0-x2), tc_puts,
//                 tc_eputs, tc_putu64, tc_fail(msg) noreturn -> exit 1.
//    tc_cli.S     the ENTIRE flag surface + layered resolution (CLI -> env
//                 -> config -> default) + the window + the value parsers +
//                 tc_source_str/tc_prog_name.  Wave E also resolves
//                 [[watch.highlight]] into TC_O_HL_* (see Deviations).
//    tc_config.S  config load (tomlc99), env lookups, aliases, the merged
//                 exclusion set (tc_build_exclusions), config identity/
//                 changed/reload, tc_shorten_path.
//    tc_core.S    channel resolution, log listing, window completion, the
//                 counting pass into tc_users/tc_tally, --users bisection.
//    tc_cache.S   the SQLite rollup cache (open/close/status + per-file
//                 hooks called from inside tc_count_run).
//    tc_render.S  ranking, provenance header, table, footer; the Wave E
//                 entry tc_render_report() (plan then JSON or text);
//                 tc_report_fail for the "error: ..."/{"error": ...} shape.
//    tc_json.S    the self-describing JSON report (tc_json_emit / tc_json_err).
//    tc_misc.S    --manual, --emit-fish-completions, --complete.
//    tc_watch.S   watch mode: tc_watch_run() with its own SIGINT loop
//                 handler, frame capture, tint/ramp machinery, pcre2
//                 highlight matching.
//
//  Deviations from the Python (consolidated across every module)
//  -------------------------------------------------------------
//    tc_config.S:
//      * TOML syntax-error text comes from tomlc99 ("line N: ...") not
//        tomllib ("Invalid ... (at line 1, column N)"); the "could not read
//        config <path>: " prefix is byte-identical.
//      * Python's `aliases = config.get("aliases") or {}` treats a FALSY
//        aliases value as absent; this port accepts "false"/"0"/"0.0" and
//        empty strings/arrays and rejects other non-table values.
//      * Logins longer than 25 characters are truncated to the frozen
//        26-byte entry; the Python keeps them whole.
//      * The exclusion set caps at TC_EX_MAX (512) and fails loudly
//        ("too many excluded logins (max 512)") instead of silently keeping
//        every entry.
//      * Error-order corner cases: a config-table error and a resolution
//        error report whichever tc_cli reaches first; with BOTH [watch] and
//        [tail] non-tables the port checks [watch] first (Python's choice is
//        hash-order/non-deterministic); with no channel AND a bad --begin
//        the port converts the window first.
//    tc_core.S:
//      * Unreadable log files are recorded with the reasons "cannot read" /
//        "file too large" (Python uses exception strings such as
//        "PermissionError: ..."; the differential normalizes these).
//      * A 1 GiB sanity cap on a single log file ("file too large");
//        the Python has no cap.
//      * CRLF line endings are NOT special-cased: a marker line ending in \r
//        is not a marker (the Python reference stripped \r).
//      * A channel dir that cannot be opened after resolution prints
//        "error: cannot open channel directory: <dir>" (the Python would
//        surface the raw OSError).
//      * Wave E fixed a latent memory-corruption bug in add_user: the new
//        table capacity was held in x6 (caller-saved) across the realloc()
//        call, which clobbered it, so the capacity field stored garbage.
//        A log with >54 distinct users then stopped growing the entries
//        array and overflowed it (SIGSEGV).  The capacity now lives in x23
//        (callee-saved); no other line of tc_core.S changed.
//    tc_cache.S:
//      * The cache fingerprint is an FNV-1a 64-bit tag over fixed parsing
//        constants (bump TC_CACHE_FP_VERSION when the parsing logic changes);
//        Python hashes the AST of its own sources, which cannot be
//        reproduced, and auto-invalidates on source edits (NOT replicated).
//      * Rollup rows are written ONLY for whole-day files; a window-partial
//        day re-parses (the Python writes a row for any cold-read day).
//        Counts are identical; only cached/reused counters differ.
//      * No HOME -> no default cache path -> the cache is disabled, NOT an
//        error (the Python leaves a literal "~/.cache" path).
//      * A cache problem never fails the run: the cache is left unused with
//        a step-named reason and every file is parsed instead.
//    tc_render.S:
//      * Share sorts rank by 1000x fixed-point keys (floor(1000*state/total))
//        instead of Python's float comparison; ties break by login, so the
//        order is total and differential-stable.
//      * Wave E fixed TWO latent bugs exposed by the final differential:
//        (1) the exclusion-source join used str_cat for the ", " separator,
//        which copies the separator's trailing NUL and truncated every source
//        after the first out of the header (an exclude line rendered as
//        "[--exclude, ]" instead of "[--exclude, --exclude-broadcaster]");
//        the separator now uses str_cat_n(dst, ", ", 2).  (2) --header none
//        jumped straight to the table, skipping the empty-report check, so an
//        empty range with --header none rendered an empty table instead of
//        Python's "No users met the threshold (...)" line; TC_HDR_NONE now
//        falls through to the shared empty check.  No other lines changed.
//    tc_misc.S:
//      * complete_users uses UTC "now" (the Python uses local time); the
//        differential generates logs covering any 7-day window.
//      * Config TOML errors in completions use tomlc99's message vs
//        tomllib's; the "could not read config <path>: " prefix is identical.
//      * The completion module re-parses the config with tomlc99 directly
//        instead of going through tc_config.S, so a broken config cannot
//        exit 1 at a prompt (run_completion reports on stderr and returns 0).
//      * Completion environment lookups use libc getenv() directly (never
//        tc_env_get, which would load the config and could fail loudly).
//      * The --emit-fish-completions text is a frozen snapshot (tc_fish.inc)
//        generated at build time with the generator's environment; Python
//        evaluates DEFAULT_CONFIG_PATH at runtime (XDG_CONFIG_HOME or
//        expanduser("~/.config")), so the --config line's "default:" path in
//        the fish text can differ when the runtime environment differs.
//    tc_watch.S:
//      * Wave D shipped with [[watch.highlight]] inert (the CLI never parsed
//        it).  Wave E resolves the rules into TC_O_HL_* at CLI time
//        (tc_resolve_highlights) and the pcre2 machinery is live.  Making it
//        live exposed ONE latent bug in the previously-dead compile path:
//        pcre2_match_data_create_from_pattern_8(code, gcontext) needs x1 =
//        NULL so the code's own memctl is used (the preceding pcre2_compile_8
//        leaves x1 as undefined caller-saved garbage, which crashed on the
//        first rule).  Fixed with a single `mov x1, xzr` in
//        watch_compile_patterns; no other line of tc_watch.S changed.
//      * The stream-state seed scans the day-before files directly (the
//        Python may use the rollup's stored exit state; same result, one
//        file read).
//      * On the first tick that discovers a warm whole-day rollup row for a
//        path the session has never read, the file is cold-read once to
//        build the day memo (the Python reads the rollup only); later ticks
//        never re-read.
//      * config reload re-resolves watch/tail settings, the channel and the
//        exclusions; a config-sourced --begin/--since change mid-session is
//        not re-applied to the rolling window.
//      * The per-second buckets are a sorted array (binary-search insert)
//        rather than a dict + bisect list; identical semantics.
//    tc_cli.S (Wave E highlight resolution, parse_highlights):
//      * [[watch.highlight]] is read directly from the config TOML via
//        tomlc99 (the frozen tc_config_get cannot return array-of-tables).
//      * Pattern validation uses pcre2, so the invalid-regex text carries
//        pcre2's message ("missing closing parenthesis") where Python re
//        says "unterminated subpattern at position 0".
//      * The frozen contract caps the rules: TC_HL_MAX (8) rules, 8 patterns
//        per rule, 63-byte pattern strings.  Beyond a cap the config fails
//        with a NEW message ("too many highlight rules (max 8)" / "rule {i}:
//        too many patterns (max 8)" / "rule {i}: pattern too long (max 63
//        characters)"); Python has no such limits.
//      * A colour that is not a string and not a 3-int array fails with a
//        fixed message ("color must be a string or a 3-integer array")
//        instead of Python's repr-based text.
//      * Non-string pattern elements inside a `match` array use tomlc99's raw
//        text; Python str() coerces them (identical for ints and floats,
//        differs for booleans: raw "true" vs str(True)="True").
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------

// ----------------------------------------------------------------------------
// main — the real orchestrator (see the header for the dispatch order).
// ----------------------------------------------------------------------------
    .p2align 2
    .global main
    FUNC_TYPE(main)
main:
    stp x29, x30, [sp, #-16]!        // frame record (sp stays 16-aligned)
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!

    mov x19, x0                      // argc
    mov x20, x1                      // argv
    mov x0, x19
    mov x1, x20
    bl tc_cli_parse                  // exits 2/1/0 on its own

    adrp x21, PAGE(tc_opts)
    add x21, x21, LO12(tc_opts)
    ldr x1, [x21, #TC_O_FLAGS]

    // ---- Python main() dispatch order: manual -> fish -> complete ----
    tst x1, #TC_F_MANUAL
    b.ne .Lmain_manual
    tst x1, #TC_F_EMIT_FISH
    b.ne .Lmain_fish
    tst x1, #TC_F_COMPLETE_GIVEN
    b.ne .Lmain_complete
    tst x1, #TC_F_WATCH_PRESENT
    b.ne .Lmain_watch

    // ---- one-shot report path (Python run_report) --------------------------
    // --json: install the SIGINT handler before the run (Python's try block
    // covers the whole report, so this is before tc_build_exclusions).
    ldr x1, [x21, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.eq .Lmain_report_go
    mov x0, #SIGINT
    adrp x1, PAGE(tc_main_sigint_handler)
    add x1, x1, LO12(tc_main_sigint_handler)
    bl signal
    mov x23, x0                      // previous disposition (callee-saved)
.Lmain_report_go:
    bl tc_build_exclusions
    bl tc_cache_open                 // resolves the channel idempotently
    bl tc_count_run
    bl tc_render_report
    bl tc_cache_close
    // restore the SIGINT disposition
    ldr x1, [x21, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.eq .Lmain_report_done
    mov x0, #SIGINT
    mov x1, x23
    bl signal
.Lmain_report_done:
    mov w0, #0
    b .Lmain_ret

.Lmain_manual:
    bl tc_misc_manual
    mov w0, #0
    b .Lmain_ret

.Lmain_fish:
    bl tc_misc_fish
    mov w0, #0
    b .Lmain_ret

.Lmain_complete:
    ldr x0, [x21, #TC_O_COMPLETE_KIND]
    bl tc_misc_complete
    mov w0, #0
    b .Lmain_ret

    // ---- watch path --------------------------------------------------------
    // tc_watch.S owns its SIGINT loop handler; main() only adds the JSON
    // "interrupted" shape when the returned code is 130 and --json was
    // given (the CLI forbids watch+json, kept for parity with
    // report_failure(args, "interrupted", code=130, announce=False)).
.Lmain_watch:
    bl tc_build_exclusions
    bl tc_cache_open                 // stays open for the session
    bl tc_watch_run
    mov x22, x0                      // rc: 0 clean / 130 SIGINT
    bl tc_cache_close
    cmp x22, #130
    b.ne .Lmain_watch_done
    ldr x1, [x21, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.eq .Lmain_watch_done
    mov x0, #0
    bl fflush                        // order this write after any stdio
    mov x0, #STDERR
    adrp x1, PAGE(s_interrupted)
    add x1, x1, LO12(s_interrupted)
    adrp x2, PAGE(s_interrupted_end)
    add x2, x2, LO12(s_interrupted_end)
    sub x2, x2, x1
    bl write
.Lmain_watch_done:
    mov x0, x22
    b .Lmain_ret

.Lmain_ret:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_main_sigint_handler — SIGINT handler for the --json one-shot.
//   Writes  {"error": "interrupted"}  to stderr and _exit(130) — the exact
//   shape Python's report_failure produces for KeyboardInterrupt under
//   --json.  Async-signal-safe by construction: only write(2) and _exit.
//   Entered by the kernel with sp 16-aligned; the handler never returns, so
//   nothing is restored.  x29/x30 are saved for the write() call; no
//   callee-saved registers are used (the kernel's signal frame preserves
//   them across the handler anyway).
// ----------------------------------------------------------------------------
    .p2align 2
    FUNC_TYPE(tc_main_sigint_handler)
tc_main_sigint_handler:
    stp x29, x30, [sp, #-16]!
    mov x0, #STDERR
    adrp x1, PAGE(s_interrupted)
    add x1, x1, LO12(s_interrupted)
    adrp x2, PAGE(s_interrupted_end)
    add x2, x2, LO12(s_interrupted_end)
    sub x2, x2, x1
    bl write
    mov w0, #130
#ifdef __APPLE__
    bl __exit                        // noreturn (C _exit is __exit on Darwin)
#else
    bl _exit                         // noreturn
#endif

// ----------------------------------------------------------------------------
// Read-only message data.  Lengths are label differences so the writer and
// the string can never drift apart.
// ----------------------------------------------------------------------------
    RODATA
s_interrupted:
    .ascii "{\"error\": \"interrupted\"}\n"
s_interrupted_end:

    .end
