// ============================================================================
// tc_layout.inc — FROZEN CONTRACT for twitch-counts-full
// ============================================================================
//
//  This file is READ-ONLY for every phase after Wave A (Phase 2).  It defines
//  the byte layout of the shared .bss data structures and the exact calling
//  contract of every exported symbol.  If a later phase needs a new field it
//  must append at the END of the relevant structure and bump its *_SIZE, or
//  (better) reuse what is here: the offsets below were chosen so that every
//  setting in the Python SETTINGS table has a home.
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Linking:    musl-gcc -static (musl libc + crt1.o)
//
//  Data model: all offsets are byte offsets from the base of their structure;
//  all u64 fields are naturally 8-byte aligned (sizes are rounded up so the
//  next field stays aligned).  Strings are NUL-terminated byte arrays.
//
//  Conventions shared by every module
//  ----------------------------------
//    * Arguments in x0-x7 per AAPCS64; returns in x0 (x1/x2 for multi-value).
//    * Callee-saved registers x19-x28 are preserved by every exported helper.
//    * sp stays 16-byte aligned at every call site.
//    * A "flag" bit set means the option was present on the command line.
//    * A source id (TC_SRC_*) is an index into the source-string table served
//      by tc_source_str(); TC_SRC_NONE means "no value / not resolved".
//
//  Error/exit conventions (frozen)
//  -------------------------------
//    * argparse-equivalent PARSE errors (bad option, conflict, bad typed
//      value, ambiguous abbreviation, unrecognized argument, missing value):
//      print the wrapped usage block then  "<prog>: error: <message>"  to
//      stderr and exit 2.  The message text is byte-identical to CPython's
//      argparse 3.11+ output.
//    * RESOLUTION errors (a typed value from env/config/default fails to
//      convert, or the resolved window is inconsistent): print
//      "error: <message>" to stderr and exit 1.  The message text matches the
//      Python's ConfigError strings ("<flag> (from <source>): <detail>").
//    * Runtime errors in later phases: "error: <message>" + exit 1.
//    * <prog> is basename(argv[0]) (normalized for differential testing by
//      copying the binary to a file named like the Python invocation).
//    * --help / -h prints the full help to stdout and exits 0.
//
// ============================================================================

#ifndef TC_LAYOUT_INC
#define TC_LAYOUT_INC

// ----------------------------------------------------------------------------
// Setting ids — index the provenance array (tc_opts + TC_O_SRC + id*8).
// Frozen numbering: later phases must not renumber.
// ----------------------------------------------------------------------------
    .equ TC_SET_CHANNEL,             0
    .equ TC_SET_USERS_POLICY,        1
    .equ TC_SET_USERS_MAX,           2
    .equ TC_SET_END,                 3
    .equ TC_SET_MIN_COUNT,           4
    .equ TC_SET_SHOW,                5
    .equ TC_SET_SORT,                6
    .equ TC_SET_SHARE_FLOOR,         7
    .equ TC_SET_TOP,                 8
    .equ TC_SET_LOGS_DIR,            9
    .equ TC_SET_HEADER,             10
    .equ TC_SET_STATE,              11
    .equ TC_SET_INTERVAL,           12   // [watch] interval
    .equ TC_SET_MIN_INTERVAL,       13
    .equ TC_SET_HOLD,               14
    .equ TC_SET_FADE_UP,            15
    .equ TC_SET_FADE_DOWN,          16
    .equ TC_SET_SHADES,             17
    .equ TC_SET_USER_WIDTH,         18
    .equ TC_SET_FULL_REPAINT,       19
    .equ TC_SET_STREAMER_MODE,      20
    .equ TC_SET_MIN_REDRAW,         21
    .equ TC_SET_SHOW_TIMING,        22
    .equ TC_SET_TINT_FALLING,       23
    .equ TC_SET_FADE_CURVE,         24
    .equ TC_SET_FADE_K,             25
    .equ TC_SET_HIGHLIGHT,          26
    .equ TC_SET_REPLAY_STEPS,       27
    .equ TC_SET_NOTIFY,             28   // [tail]
    .equ TC_SET_MAX_EVENTS,         29
    .equ TC_SET_SEED_LOOKBACK,      30
    .equ TC_SET_BEGIN,              31   // window-start raw (see tc_window)
    .equ TC_SET_SINCE,              32
    .equ TC_SET_USERS,              33   // CLI-only, positive_int
    .equ TC_SET_EXCLUDE,            34   // repeatable CLI list (accumulates)
    .equ TC_SET_EXCLUDE_GROUP,      35   // repeatable CLI list (accumulates)
    .equ TC_SET_EXCLUDE_BCAST,      36
    .equ TC_SET_INCLUDE,            37   // repeatable CLI list (accumulates)
    .equ TC_SET_CONFIG,             38
    .equ TC_SET_COLOR,              39   // auto/always/never (hand-written)
    .equ TC_SET_COUNT,              40

// ----------------------------------------------------------------------------
// Small value ids (frozen)
// ----------------------------------------------------------------------------
// State filter ids (tc_opts + TC_O_STATE_FILTER; also tc_window state_filter)
    .equ TC_ST_NONE,     0            // any/all -> no filter
    .equ TC_ST_LIVE,     1
    .equ TC_ST_OFFLINE,  2
    .equ TC_ST_UNKNOWN,  3

// Metric / column ids (tc_opts + TC_O_COLUMNS entries; sort ids share them)
    .equ TC_M_COUNT,         0
    .equ TC_M_LOGIN,         1        // sort-only ("login" is not a column)
    .equ TC_M_LIVE,          2
    .equ TC_M_OFFLINE,       3
    .equ TC_M_UNKNOWN,       4
    .equ TC_M_OFFLINE_SHARE, 5
    .equ TC_M_LIVE_SHARE,    6
    .equ TC_M_MAX,           7

// Header mode ids (tc_opts + TC_O_HEADER_MODE)
    .equ TC_HDR_FULL,    0
    .equ TC_HDR_COMPACT, 1
    .equ TC_HDR_NONE,    2

// --users-policy ids (tc_opts + TC_O_USERS_POLICY)
    .equ TC_POLICY_AT_LEAST, 0
    .equ TC_POLICY_AT_MOST,  1
    .equ TC_POLICY_NEAREST,  2

// --color ids (tc_opts + TC_O_COLOR_MODE)
    .equ TC_COLOR_AUTO,   0
    .equ TC_COLOR_ALWAYS, 1
    .equ TC_COLOR_NEVER,  2

// --complete kind ids (tc_opts + TC_O_COMPLETE_KIND), order = COMPLETE_KINDS
    .equ TC_COMPLETE_CHANNELS, 0
    .equ TC_COMPLETE_GROUPS,   1
    .equ TC_COMPLETE_DATES,    2
    .equ TC_COMPLETE_WEEKS,    3
    .equ TC_COMPLETE_PERIODS,  4
    .equ TC_COMPLETE_USERS,    5
    .equ TC_COMPLETE_INCLUDES, 6

// Fade curve ids (tc_opts + TC_O_FADE_CURVE), order = sorted(CURVES)
    .equ TC_CURVE_LINEAR,     0
    .equ TC_CURVE_POWER,      1
    .equ TC_CURVE_EASE_OUT,   2
    .equ TC_CURVE_BIAS,       3
    .equ TC_CURVE_EASE_IN_OUT,4

// Config section ids passed to tc_config_get (see hook contract below)
    .equ TC_SEC_NONE,  0              // top-level table
    .equ TC_SEC_WATCH, 1              // [watch]
    .equ TC_SEC_TAIL,  2              // [tail]

// Window-start kinds (tc_opts + TC_O_WIN_KIND)
    .equ TC_WIN_BEGIN,    0           // an explicit --begin-style start
    .equ TC_WIN_SINCE,    1           // derived: end - duration
    .equ TC_WIN_USERS,    2           // --users bisection (Phase 4 sizes it)
    .equ TC_WIN_EARLIEST, 3           // default: earliest log file (Phase 4)

// Sentinel for "--watch without a value": resolve interval from config.
// Stored as the double -1.0 in TC_O_INTERVAL when the flag was present with
// no number (Python's WATCH_FROM_CONFIG).  Phase 3 resolves it.
    .equ TC_WATCH_FROM_CONFIG_BITS, 0xBFF0000000000000   // double -1.0

// ----------------------------------------------------------------------------
// Source ids (frozen).  tc_source_str(id) -> (x0=ptr, x1=len).
// Strings live in tc_cli.S .rodata; ids below TC_SRC_COUNT are the contract.
// The three TC_SRC_DYN_* ids return the live dynamic buffers (see below).
// ----------------------------------------------------------------------------
    .equ TC_SRC_NONE,                   0
    // CLI (resolve() labels a CLI hit with the real flag)
    .equ TC_SRC_CLI_CHANNEL,            1
    .equ TC_SRC_CLI_USERS_POLICY,       2
    .equ TC_SRC_CLI_USERS_MAX,          3
    .equ TC_SRC_CLI_END,                4
    .equ TC_SRC_CLI_MIN_COUNT,          5
    .equ TC_SRC_CLI_SHOW,               6
    .equ TC_SRC_CLI_SORT,               7
    .equ TC_SRC_CLI_SHARE_FLOOR,        8
    .equ TC_SRC_CLI_TOP,                9
    .equ TC_SRC_CLI_LOGS_DIR,          10
    .equ TC_SRC_CLI_HEADER,            11
    .equ TC_SRC_CLI_LIVE,              12
    .equ TC_SRC_CLI_OFFLINE,           13
    .equ TC_SRC_CLI_UNKNOWN,           14
    .equ TC_SRC_CLI_BEGIN,             15
    .equ TC_SRC_CLI_SINCE,             16
    .equ TC_SRC_CLI_USERS,             17
    .equ TC_SRC_CLI_WATCH,             18
    .equ TC_SRC_CLI_WATCH_HOLD,        19
    .equ TC_SRC_CLI_EXCLUDE,           20
    .equ TC_SRC_CLI_EXCLUDE_GROUP,     21
    .equ TC_SRC_CLI_EXCLUDE_BCAST,     22
    .equ TC_SRC_CLI_INCLUDE,           23
    .equ TC_SRC_CLI_CONFIG,            24
    .equ TC_SRC_CLI_STREAMER,          25
    .equ TC_SRC_CLI_COLOR,             26
    .equ TC_SRC_CLI_JSON,              27
    .equ TC_SRC_CLI_BY_STATE,          28
    .equ TC_SRC_CLI_NO_EXCLUDE,        29
    .equ TC_SRC_CLI_NO_CONFIG,         30
    .equ TC_SRC_CLI_NO_CACHE,          31
    .equ TC_SRC_CLI_REBUILD_CACHE,     32
    .equ TC_SRC_CLI_MANUAL,            33
    .equ TC_SRC_CLI_EMIT_FISH,         34
    .equ TC_SRC_CLI_COMPLETE,          35
    .equ TC_SRC_CLI_HELP,              36
    // env ("env " + the variable name)
    .equ TC_SRC_ENV_CHANNEL,           37
    .equ TC_SRC_ENV_USERS_POLICY,      38
    .equ TC_SRC_ENV_USERS_MAX,         39
    .equ TC_SRC_ENV_END,               40
    .equ TC_SRC_ENV_MIN_COUNT,         41
    .equ TC_SRC_ENV_SHOW,              42
    .equ TC_SRC_ENV_SORT,              43
    .equ TC_SRC_ENV_SHARE_FLOOR,       44
    .equ TC_SRC_ENV_TOP,               45
    .equ TC_SRC_ENV_LOGS_DIR,          46
    .equ TC_SRC_ENV_HEADER,            47
    .equ TC_SRC_ENV_STATE,             48
    .equ TC_SRC_ENV_BEGIN,             49
    .equ TC_SRC_ENV_SINCE,             50
    .equ TC_SRC_ENV_EXCLUDE,           51
    .equ TC_SRC_ENV_EXCLUDE_BCAST,     52
    .equ TC_SRC_ENV_WATCH_INTERVAL,    53
    .equ TC_SRC_ENV_WATCH_MIN_INTERVAL,54
    .equ TC_SRC_ENV_WATCH_HOLD,        55
    .equ TC_SRC_ENV_WATCH_FADE_UP,     56
    .equ TC_SRC_ENV_WATCH_FADE_DOWN,   57
    .equ TC_SRC_ENV_WATCH_SHADES,      58
    .equ TC_SRC_ENV_WATCH_USER_WIDTH,  59
    .equ TC_SRC_ENV_WATCH_FULL_REPAINT,60
    .equ TC_SRC_ENV_WATCH_STREAMER_MODE,61
    .equ TC_SRC_ENV_WATCH_MIN_REDRAW,  62
    .equ TC_SRC_ENV_WATCH_SHOW_TIMING, 63
    .equ TC_SRC_ENV_WATCH_TINT_FALLING,64
    .equ TC_SRC_ENV_WATCH_FADE_CURVE,  65
    .equ TC_SRC_ENV_WATCH_FADE_K,      66
    .equ TC_SRC_ENV_WATCH_HIGHLIGHT,   67
    .equ TC_SRC_ENV_WATCH_REPLAY_STEPS,68
    .equ TC_SRC_ENV_TAIL_NOTIFY,       69
    .equ TC_SRC_ENV_TAIL_MAX_EVENTS,   70
    .equ TC_SRC_ENV_TAIL_SEED_LOOKBACK,71
    // config
    .equ TC_SRC_CONFIG,               72   // "config"
    .equ TC_SRC_CONFIG_WATCH,         73   // "config [watch]"
    .equ TC_SRC_CONFIG_TAIL,          74   // "config [tail]"
    // built-in defaults
    .equ TC_SRC_DEFAULT_BUILTIN,      75   // "built-in default"
    .equ TC_SRC_DEFAULT,              76   // "default"
    .equ TC_SRC_DEFAULT_NOW,          77   // "default: now"
    .equ TC_SRC_DEFAULT_EARLIEST,     78   // "default: earliest log file"
    .equ TC_SRC_DEFAULT_UNDER_WATCH,  79   // "default under --watch"
    // dynamic (composed at runtime; see buffers in the options block)
    .equ TC_SRC_DYN_SINCE,            80   // "<since src> <raw> before end"
    .equ TC_SRC_DYN_USERS,            81   // "--users <N>"
    .equ TC_SRC_DYN_ALIAS,            82   // "<src> -> alias '<key>'"
    // exclusion-layer sources (Phase 3 fills tc_excl_sources with these)
    .equ TC_SRC_EXCL_CONFIG,          83   // "config exclude"
    .equ TC_SRC_EXCL_ALWAYS,          84   // "config always:<name>" (dynamic)
    .equ TC_SRC_EXCL_GROUP,           85   // "--exclude-group <name>" (dynamic)
    .equ TC_SRC_EXCL_ENV,             86   // "env TWITCH_EXCLUDE"
    .equ TC_SRC_CONFIG_BEGIN,         87   // "config begin" (window start source)
    .equ TC_SRC_CONFIG_SINCE,         88   // "config since" (window start source)
    .equ TC_SRC_COUNT,                89   // size of the static table

// ----------------------------------------------------------------------------
// Flags bitmask (tc_opts + TC_O_FLAGS).  A bit means the option appeared on
// the command line.  Frozen numbering.
// ----------------------------------------------------------------------------
    .equ TC_F_BEGIN_GIVEN,      (1 << 0)
    .equ TC_F_SINCE_GIVEN,      (1 << 1)
    .equ TC_F_END_GIVEN,        (1 << 2)
    .equ TC_F_JSON,             (1 << 3)
    .equ TC_F_WATCH_PRESENT,    (1 << 4)   // -w/--watch seen
    .equ TC_F_WATCH_VALUE,      (1 << 5)   // -w/--watch carried a number
    .equ TC_F_BY_STATE,         (1 << 6)
    .equ TC_F_NO_EXCLUDE,       (1 << 7)
    .equ TC_F_EXCLUDE_BCAST,    (1 << 8)   // --exclude-broadcaster seen
    .equ TC_F_MANUAL,           (1 << 9)
    .equ TC_F_EMIT_FISH,        (1 << 10)
    .equ TC_F_NO_CONFIG,        (1 << 11)
    .equ TC_F_NO_CACHE,         (1 << 12)
    .equ TC_F_REBUILD_CACHE,    (1 << 13)
    .equ TC_F_STREAMER,         (1 << 14)  // --streamer seen
    .equ TC_F_CONFIG_GIVEN,     (1 << 15)  // --config seen
    .equ TC_F_USERS_GIVEN,      (1 << 16)  // --users seen
    .equ TC_F_WATCH_HOLD_GIVEN, (1 << 17)  // --watch-hold seen
    .equ TC_F_COLOR_GIVEN,      (1 << 18)  // --color seen
    .equ TC_F_COMPLETE_GIVEN,   (1 << 19)  // --complete seen
    .equ TC_F_EXCL_GIVEN,       (1 << 20)  // at least one -x/--exclude
    .equ TC_F_EXCL_GROUP_GIVEN, (1 << 21)  // at least one -g/--exclude-group
    .equ TC_F_INCL_GIVEN,       (1 << 22)  // at least one --include

// ----------------------------------------------------------------------------
// The options block — ONE .bss object, symbol `tc_opts`, size TC_OPTS_SIZE.
// Everything a later phase reads that is decided by the CLI lives here.
// ----------------------------------------------------------------------------
    .equ TC_O_CHANNEL,         0          // 64  resolved channel (post-alias)
    .equ TC_O_CHANNEL_SZ,      64
    .equ TC_O_LOGS_DIR,        64         // 512 resolved logs dir
    .equ TC_O_LOGS_DIR_SZ,     512
    .equ TC_O_BEGIN_RAW,       576        // 64  --begin / TWITCH_BEGIN / config begin
    .equ TC_O_BEGIN_RAW_SZ,    64
    .equ TC_O_SINCE_RAW,       640        // 64  --since / TWITCH_SINCE / config since
    .equ TC_O_SINCE_RAW_SZ,    64
    .equ TC_O_END_RAW,         704        // 64  --end / TWITCH_END / config end
    .equ TC_O_END_RAW_SZ,      64
    .equ TC_O_CONFIG_PATH,     768        // 512 --config / default config path
    .equ TC_O_CONFIG_PATH_SZ,  512
    .equ TC_O_PROG_PTR,        1280       // 8   basename(argv[0]) pointer
    .equ TC_O_PROG_LEN,        1288       // 8   basename(argv[0]) length
    // ---- resolved u64 values ----------------------------------------------
    .equ TC_O_MIN_COUNT,       1296       // 8   positive_int
    .equ TC_O_TOP,             1304       // 8   nonnegative_int; 0 = unlimited
    .equ TC_O_SHARE_FLOOR,     1312       // 8   nonnegative_int
    .equ TC_O_USERS,           1320       // 8   --users N requested (0 = none)
    .equ TC_O_USERS_MAX,       1328       // 8   seconds (parse_duration)
    .equ TC_O_USERS_POLICY,    1336       // 8   TC_POLICY_*
    .equ TC_O_STATE_FILTER,    1344       // 8   TC_ST_*
    .equ TC_O_SORT,            1352       // 8   TC_M_*
    .equ TC_O_HEADER_MODE,     1360       // 8   TC_HDR_*
    .equ TC_O_COLOR_MODE,      1368       // 8   TC_COLOR_*
    .equ TC_O_COMPLETE_KIND,   1376       // 8   TC_COMPLETE_*
    .equ TC_O_CONFIG_LOADED,   1384       // 8   0/1 (Phase 3 sets when config read)
    .equ TC_O_EXCL_BCAST_VAL,  1392       // 8   0/1 resolved exclude-broadcaster
    // ---- merged metric columns (BY_STATE first, then --show, deduped) ------
    .equ TC_O_COLUMNS,         1400       // 48  6 x u64 TC_M_*
    .equ TC_O_COLUMNS_SZ,      48
    .equ TC_O_COLUMN_COUNT,    1448       // 8   number of columns (<= 6)
    .equ TC_O_COLUMNS_SRC,     1456       // 8   source id for the merged
                                          //     columns (TC_SRC_*); the
                                          //     composed text pointer is
                                          //     TC_O_COLUMNS_SRC_PTR
    // ---- watch/tail doubles ------------------------------------------------
    .equ TC_O_INTERVAL,        1464       // 8   double; -1.0 = from-config
    .equ TC_O_MIN_INTERVAL,    1472       // 8   double
    .equ TC_O_HOLD,            1480       // 8   double
    .equ TC_O_MIN_REDRAW,      1488       // 8   double
    .equ TC_O_FADE_K,          1496       // 8   double
    // ---- watch/tail u64 ----------------------------------------------------
    .equ TC_O_SHADES,          1504       // 8
    .equ TC_O_USER_WIDTH,      1512       // 8
    .equ TC_O_FULL_REPAINT,    1520       // 8
    .equ TC_O_REPLAY_STEPS,    1528       // 8
    .equ TC_O_STREAMER_MODE,   1536       // 8   0/1
    .equ TC_O_SHOW_TIMING,     1544       // 8   0/1
    .equ TC_O_TINT_FALLING,    1552       // 8   0/1
    .equ TC_O_FADE_CURVE,      1560       // 8   TC_CURVE_*
    .equ TC_O_NOTIFY,          1568       // 8   0/1 [tail]
    .equ TC_O_MAX_EVENTS,      1576       // 8   [tail]
    .equ TC_O_SEED_LOOKBACK,   1584       // 8   [tail]
    // ---- watch colours -----------------------------------------------------
    .equ TC_O_FADE_UP_RGB,     1592       // 12  3 x u32
    .equ TC_O_FADE_DOWN_RGB,   1604       // 12  3 x u32
    .equ TC_O_FADE_UP_RAW,     1616       // 16  raw colour string (source display)
    .equ TC_O_FADE_DOWN_RAW,   1632       // 16
    // ---- [[watch.highlight]] rules -----------------------------------------
    .equ TC_O_HL_COUNT,        1648       // 8   number of rules (<= TC_HL_MAX)
    .equ TC_O_HL_ARR,          1656       // TC_HL_MAX x TC_HL_RULE_SZ
    // The Python has no limits here; these are the fixed-array capacities
    // (a config beyond them fails loudly, never silently truncates).
    // Every tc_opts offset after the array is an expression of
    // TC_O_HL_ARR_SZ, so they can be raised freely.
    .equ TC_HL_MAX,            32         // max rules
    .equ TC_HL_RGB,            0          //   12  3 x u32
    .equ TC_HL_CURVE,          12         //   8   TC_CURVE_* (-1 = inherit)
    .equ TC_HL_K,              20         //   8   double (-1.0 = inherit)
    .equ TC_HL_PAT_COUNT,      28         //   8
    .equ TC_HL_RULE_SZ,        40         //   (36 rounded up to 8)
    // The pattern texts are NOT in the rule record (they would push every
    // later tc_opts field past the reach of a load/store immediate).  They
    // live in tc_hl_patterns (tc_cli.S, .global), TC_HL_MAX x TC_HL_PAT_MAX
    // slots of TC_HL_PAT_SZ bytes: pattern j of rule i is at
    //   tc_hl_patterns + (i * TC_HL_PAT_MAX + j) * TC_HL_PAT_SZ
    .equ TC_HL_PAT_MAX,        64         //   max patterns per rule
    .equ TC_HL_PAT_SZ,         256        //   one pattern slot (NUL included)
    .equ TC_O_HL_ARR_SZ,       (TC_HL_MAX * TC_HL_RULE_SZ)
    // ---- flags + provenance ------------------------------------------------
    .equ TC_O_FLAGS,           (1656 + TC_O_HL_ARR_SZ)   // 8  bitmask
    .equ TC_O_SRC,             (1664 + TC_O_HL_ARR_SZ)   // TC_SET_COUNT x 8
    .equ TC_O_SRC_SZ,          (TC_SET_COUNT * 8)
    // ---- dynamic source buffers --------------------------------------------
    .equ TC_O_WIN_SRC,         (1664 + TC_O_HL_ARR_SZ + TC_O_SRC_SZ)  // 128
    .equ TC_O_WIN_SRC_SZ,      128        // TC_SRC_DYN_SINCE / _DYN_USERS
    .equ TC_O_CHAN_SRC,        (TC_O_WIN_SRC + TC_O_WIN_SRC_SZ)       // 128
    .equ TC_O_CHAN_SRC_SZ,     128        // TC_SRC_DYN_ALIAS (Phase 3 writes)
    .equ TC_O_COLUMNS_SRC_BUF, (TC_O_CHAN_SRC + TC_O_CHAN_SRC_SZ)     // 64
    .equ TC_O_COLUMNS_SRC_BUF_SZ, 64
    // ---- raw repeatable CLI lists ------------------------------------------
    .equ TC_O_EXCL_COUNT,      (TC_O_COLUMNS_SRC_BUF + TC_O_COLUMNS_SRC_BUF_SZ)
    .equ TC_O_EXCL_LIST,       (TC_O_EXCL_COUNT + 8)    // TC_LIST_MAX x 64
    .equ TC_O_INCL_COUNT,      (TC_O_EXCL_LIST + TC_LIST_MAX*64)
    .equ TC_O_INCL_LIST,       (TC_O_INCL_COUNT + 8)    // TC_LIST_MAX x 64
    .equ TC_O_EXCL_GROUP_COUNT,(TC_O_INCL_LIST + TC_LIST_MAX*64)
    .equ TC_O_EXCL_GROUP_LIST, (TC_O_EXCL_GROUP_COUNT + 8)  // TC_LIST_MAX x 32
    .equ TC_LIST_MAX,          32
    // Pointer to the composed columns-source string ("--by-state, --show",
    // "--show", "env TWITCH_SHOW", ...) in TC_O_COLUMNS_SRC_BUF; 0 when no
    // columns were asked for.  TC_O_COLUMNS_SRC keeps the id form.
    .equ TC_O_COLUMNS_SRC_PTR, (TC_O_EXCL_GROUP_LIST + TC_LIST_MAX*32)  // 8
    .equ TC_OPTS_SIZE,         (TC_O_COLUMNS_SRC_PTR + 8)

// ----------------------------------------------------------------------------
// tc_window — the resolved time range (symbol `tc_window` in .bss).
// tc_cli_parse fills everything except the earliest-log-file begin (kind 3)
// and the --users sizing (kind 2), which Phase 4 completes.
// ----------------------------------------------------------------------------
    .equ TC_W_BEGIN_YMD,    0          // 8  begin as YYYYMMDD u64 (0 until Phase 4)
    .equ TC_W_BEGIN_SOD,    8          // 8  seconds-of-day
    .equ TC_W_END_YMD,      16         // 8  end as YYYYMMDD u64
    .equ TC_W_END_SOD,      24         // 8  seconds-of-day
    .equ TC_W_KIND,         32         // 8  TC_WIN_*
    .equ TC_W_START_SRC,    40         // 8  pointer to the start source string
    .equ TC_W_THRESHOLD,    48         // 8  min_count (resolved)
    .equ TC_W_STATE_FILTER, 56         // 8  TC_ST_* (resolved)
    .equ TC_W_BEGIN_ROLLS,  64         // 8  1 when begin slides with end (since/users)
    .equ TC_W_USERS_WIDTH,  72         // 8  sized width seconds (Phase 4)
    .equ TC_W_USERS_REQ,    80         // 8  requested N
    .equ TC_W_USERS_FOUND,  88         // 8  found N
    .equ TC_WIN_SIZE,       96

// ----------------------------------------------------------------------------
// tc_excl_set — the merged exclusion set (Phase 3 builds, Phases 4/5 read).
// ----------------------------------------------------------------------------
    .equ TC_EX_COUNT,       0          // 8  number of entries
    .equ TC_EX_ENTRIES,     8          // TC_EX_MAX x {login[26], source_idx u64}
    .equ TC_EX_MAX,         512
    .equ TC_EX_LOGIN_SZ,    26
    .equ TC_EX_ENTRY_SZ,    (TC_EX_LOGIN_SZ + 8)          // 34
    .equ TC_EX_SET_SZ,      (8 + TC_EX_MAX * TC_EX_ENTRY_SZ)
    // Parallel source table: entry i's source_idx indexes tc_excl_sources[i].
    // Each record is {ptr u64, len u64}; ptr may point at rodata (a TC_SRC_*
    // string), at tc_opts raw lists, or at tc_excl_src_buf (dynamic composed
    // strings like "config always:NAME").
    .equ TC_EX_SRC_ENTRY_SZ, 16
    .equ TC_EX_SRC_TABLE_SZ, (TC_EX_MAX * TC_EX_SRC_ENTRY_SZ)
    .equ TC_EX_SRC_BUF_SZ,   (TC_EX_MAX * 64)             // dynamic strings

// ----------------------------------------------------------------------------
// tc_users — the user table (Phase 4 owns: allocates, fills, serves lookups).
// Entry: {login[26], live u64, offline u64, unknown u64} = 50 bytes.
// ----------------------------------------------------------------------------
    .equ TC_US_CAP,         0          // 8  allocated capacity
    .equ TC_US_COUNT,       8          // 8  current count
    .equ TC_US_ENTRIES,     16         // 8  pointer to the entry array
    .equ TC_US_HEADER_SZ,   24
    .equ TC_US_LOGIN_SZ,    26
    .equ TC_US_LIVE,        26
    .equ TC_US_OFFLINE,     34
    .equ TC_US_UNKNOWN,     42
    .equ TC_US_ENTRY_SZ,    50

// ----------------------------------------------------------------------------
// tc_tally — counting-pass results (Phase 4 fills, Phases 5/6 read).
// ----------------------------------------------------------------------------
    .equ TC_T_USERS_PTR,     0         // 8  pointer to tc_users header
    .equ TC_T_FILES,         8         // 8  log files read
    .equ TC_T_MESSAGES,      16         // 8  total messages counted
    .equ TC_T_STATES,        24         // 24 post-exclusion state counts [3]
    .equ TC_T_PARSED,        48         // 8  lines parsed
    .equ TC_T_REUSED,        56         // 8  days reused from the cache
    .equ TC_T_EXCLUDED_STATES,64        // 24 excluded state counts [3]
    .equ TC_T_UNREADABLE,    88         // {count u64, entries[64] of {name[64], reason[32]}}
    .equ TC_T_UNR_COUNT,     88
    .equ TC_T_UNR_ENTRIES,   96
    .equ TC_T_UNR_MAX,       64
    .equ TC_T_UNR_NAME_SZ,   64
    .equ TC_T_UNR_REASON_SZ, 32
    .equ TC_T_UNR_ENTRY_SZ,  (64 + 32)                    // 96
    .equ TC_TALLY_SIZE,      (96 + TC_T_UNR_MAX * TC_T_UNR_ENTRY_SZ)

// ----------------------------------------------------------------------------
// tc_listing — dated log files (Phase 4 fills, sorted ascending).
// Entry: {ymd u64, name[64]}.
// ----------------------------------------------------------------------------
    .equ TC_L_COUNT,        0          // 8
    .equ TC_L_CAP,          8          // 8
    .equ TC_L_ENTRIES,      16         // 8  pointer to the entry array
    .equ TC_L_HEADER_SZ,    24
    .equ TC_L_YMD,          0
    .equ TC_L_NAME,         8          // 64
    .equ TC_L_ENTRY_SZ,     72

// ============================================================================
// Exported symbol contracts (see each module's header for the full text)
// ============================================================================
//
// tc_util.S
//   tc_strlen(x0=s)                       -> x0 = length (no NUL)
//   tc_puts(x0=s)                         print s to stdout (flushes stdio)
//   tc_eputs(x0=s)                        print s to stderr (unbuffered)
//   tc_putu64(x0=v)                       print u64 decimal to stdout
//   tc_fail(x0=msg)                       "error: <msg>\n" stderr, exit 1
//
// tc_cli.S
//   tc_cli_parse(x0=argc, x1=argv)        -> 0; fills tc_opts + tc_window.
//       Parse errors: usage + "<prog>: error: ..." to stderr, exit 2.
//       Resolution errors: "error: ..." to stderr, exit 1.
//       --help prints the full help to stdout and exits 0.
//   tc_source_str(x0=id)                  -> (x0=ptr, x1=len); TC_SRC_* or
//       TC_SRC_DYN_* (reads the live buffers in tc_opts).
//   tc_prog_name()                        -> x0 = basename(argv[0]) pointer
//   tc_print_help()                       prints help to stdout, exit 0
//   tc_civil_from_days(x0=z)              -> x0=y, x1=m, x2=d (port of the
//       Python/reference civil math; exported for Phase 4+ formatters)
//   tc_parse_datetime(x0=s, x1=eod)       -> (x0=ymd, x1=sod, x2=ok 0/1)
//       DATETIME_FORMATS + ISO weeks + fromisoformat week subset.
//   tc_parse_duration(x0=s)               -> (x0=seconds, x1=status)
//       status 0 ok, 1 unrecognized, 2 zero.
//   tc_parse_positive_int(x0=s)           -> (x0=value, x1=ok)
//   tc_parse_nonnegative_int(x0=s)        -> (x0=value, x1=ok)
//   tc_parse_nonnegative_float(x0=s)      -> (x0=bits, x1=ok) (double bits)
//   tc_parse_positive_float(x0=s)         -> (x0=bits, x1=ok)
//   tc_parse_bool(x0=s)                   -> (x0=value 0/1, x1=ok)
//   tc_parse_state(x0=s)                  -> (x0=TC_ST_*, x1=ok)
//   tc_parse_header(x0=s)                 -> (x0=TC_HDR_*, x1=ok)
//   tc_parse_sort(x0=s)                   -> (x0=TC_M_*, x1=ok)
//   tc_parse_curve(x0=s)                  -> (x0=TC_CURVE_*, x1=ok)
//   tc_parse_hex_colour(x0=s)             -> (x0=r<<16|g<<8|b, x1=ok)
//   (all "ok" = 1 on success; callers print the argparse message themselves)
//
// tc_config.S  (Phase 3 provides the real implementations; this file is the
//   Wave-A stub so the phase-2 test binary links)
//   tc_env_get(x0=name)                   -> (x0=found 0/1, x1=value_ptr)
//       value_ptr is a NUL-terminated string.  Unset OR empty ("" ) -> 0,
//       mirroring Python's `os.environ.get(n) not in (None, "")`.
//   tc_config_get(x0=key, x1=section_id)  -> (x0=found, x1=value_ptr,
//                                             x2=source_id)
//       section_id: TC_SEC_NONE/WATCH/TAIL.  found=1 only for a key present
//       with a non-null value.  source_id is TC_SRC_CONFIG / _CONFIG_WATCH /
//       _CONFIG_TAIL, the label the resolver records.
//   tc_aliases_apply()                    -> 0
//       Rewrites tc_opts+TC_O_CHANNEL and fills TC_O_CHAN_SRC when the
//       resolved channel matches a [aliases] key ("<src> -> alias '<key>'").
//       No-op stub now; Phase 3 implements.
//   tc_excl_contains(x0=ptr, x1=len)      -> x0 = 1 if the login is in
//       tc_excl_set (lowercased compare), else 0.  Phase 3 implements.
//
// tc_main.S
//   main()                                bringup smoke until Wave E.
//
// ============================================================================

#endif // TC_LAYOUT_INC

// pcre2_compile options for [[watch.highlight]] patterns: PCRE2_UTF | PCRE2_UCP
// (Python re on str is Unicode-aware: \\w \\d \\s \\b and (?i) folding) |
// PCRE2_MATCH_INVALID_UTF (a log line with invalid UTF-8 must not raise)
    .equ PCRE2_OPTS, 0x040A0000
