// ============================================================================
// tc_platform.h — the shared contract header for the C port of twitch-counts
// ============================================================================
//
//  This is the single shared header of the pure-C reimplementation of
//  twitch-counts.py.  Every module #includes it first.  It is the C sibling of
//  asm/tc_platform.h + asm/tc_layout.inc: it carries the platform selection,
//  the frozen id scheme, the shared data structures and the cross-module
//  function contract so the modules can call each other.
//
//  Behavioural parity target:  twitch-counts.py is the oracle.  The C binary
//  must be byte-for-byte identical wherever the Python's output is observable
//  (stdout/stderr text, exit codes, the JSON report, the SQLite rollup).
//  Frozen ids below keep their tc_layout.inc values so the C port and the
//  assembly port (and any generated inc blobs) never disagree about a number.
//
//  Platform contract (mirrors the Python Platform class):
//    * per-OS default logs dir / config path / cache path
//    * a change-notification watcher seam: kqueue on macOS, polling on Linux
//  Targets: Linux (musl, static) and macOS arm64 (Apple clang, libSystem).
//
//  Conventions
//  -----------
//    * A "flag" bit (TC_F_*) set means the option was present on the CLI.
//    * A source id (TC_SRC_*) is the provenance of a resolved setting;
//      TC_SRC_NONE means "no value / not resolved".
//    * Error/exit codes match the Python: parse errors 2, resolution/runtime
//      errors 1, SIGINT 130.  Help on stdout exits 0.
//    * C port note: the assembly port keeps its session state in .bss globals
//      (tc_opts, tc_window, ...).  This port passes state explicitly — main()
//      owns a tc_opts/tc_window and threads pointers through the phases — so
//      functions keep no hidden mutable globals and stay testable.
//    * The assembly-only shims of the asm contract (variadic wrappers
//      tc_snprintf_d/i, tc_ioctl_p, tc_entry_ptr) have no C equivalent: C
//      calls snprintf/ioctl directly.  They are deliberately not declared.
//
//  Self-contained: only stdlib headers (<stdint.h>, <stddef.h>, <time.h>,
//  <stdbool.h>).  Vendored-library types (toml_table_t, sqlite3, pcre2) stay
//  opaque behind void*/struct tags so no module is forced to include them.
//
// ============================================================================

#ifndef TC_PLATFORM_H
#define TC_PLATFORM_H

#include <stdint.h>
#include <stddef.h>
#include <time.h>
#include <stdbool.h>

// ----------------------------------------------------------------------------
// Platform selection.  The C port targets exactly two platforms; anything else
// fails loudly at compile time (never silently picks a wrong layout).
// ----------------------------------------------------------------------------
#if defined(__APPLE__)
    #define TC_PLATFORM_MACOS 1
#elif defined(__linux__)
    #define TC_PLATFORM_LINUX 1
#else
    #error "twitch-counts C port supports only macOS (__APPLE__) and Linux (__linux__)"
#endif

// ============================================================================
// Exit codes (match the Python main()/argparse contract)
// ============================================================================
#define TC_EXIT_OK         0
#define TC_EXIT_ERROR      1
#define TC_EXIT_PARSE      2
#define TC_EXIT_INTERRUPT  130     /* 128 + SIGINT, the KeyboardInterrupt code */

// ============================================================================
// FNV-1a 64-bit fingerprints — the rollup-cache fingerprint scheme.
// Standard FNV-1a (offset basis + prime); the cache module hashes the source
// of every counting rule into one of these and stores it as 16 hex chars.
// ============================================================================
#define TC_FNV1A_64_OFFSET_BASIS UINT64_C(14695981039346656037)
#define TC_FNV1A_64_PRIME        UINT64_C(1099511628211)

static inline uint64_t tc_fnv1a_64_bytes(const void *data, size_t len) {
    const unsigned char *bytes = (const unsigned char *)data;
    uint64_t hash = TC_FNV1A_64_OFFSET_BASIS;
    size_t i;
    for (i = 0; i < len; i++) {
        hash ^= (uint64_t)bytes[i];
        hash *= TC_FNV1A_64_PRIME;
    }
    return hash;
}

static inline uint64_t tc_fnv1a_64(const char *text) {
    uint64_t hash = TC_FNV1A_64_OFFSET_BASIS;
    while (*text) {
        hash ^= (unsigned char)*text++;
        hash *= TC_FNV1A_64_PRIME;
    }
    return hash;
}

// ============================================================================
// Frozen small-value ids — mirror asm/tc_layout.inc.  Never renumber.
// ============================================================================

// Setting ids: index tc_opts.src[] (the provenance array).  TC_SET_COUNT is
// the array bound.  Order matches Python's SETTINGS tuple.
enum tc_setting_id {
    TC_SET_CHANNEL = 0,
    TC_SET_USERS_POLICY,
    TC_SET_USERS_MAX,
    TC_SET_END,
    TC_SET_MIN_COUNT,
    TC_SET_SHOW,
    TC_SET_SORT,
    TC_SET_SHARE_FLOOR,
    TC_SET_TOP,
    TC_SET_LOGS_DIR,
    TC_SET_HEADER,
    TC_SET_STATE,
    TC_SET_INTERVAL,        /* [watch] interval */
    TC_SET_MIN_INTERVAL,
    TC_SET_HOLD,
    TC_SET_FADE_UP,
    TC_SET_FADE_DOWN,
    TC_SET_SHADES,
    TC_SET_USER_WIDTH,
    TC_SET_FULL_REPAINT,
    TC_SET_STREAMER_MODE,
    TC_SET_MIN_REDRAW,
    TC_SET_SHOW_TIMING,
    TC_SET_TINT_FALLING,
    TC_SET_FADE_CURVE,
    TC_SET_FADE_K,
    TC_SET_HIGHLIGHT,
    TC_SET_REPLAY_STEPS,
    TC_SET_NOTIFY,          /* [tail] */
    TC_SET_MAX_EVENTS,
    TC_SET_SEED_LOOKBACK,
    TC_SET_BEGIN,           /* window-start raw */
    TC_SET_SINCE,
    TC_SET_USERS,           /* CLI-only, positive_int */
    TC_SET_EXCLUDE,         /* repeatable CLI list */
    TC_SET_EXCLUDE_GROUP,   /* repeatable CLI list */
    TC_SET_EXCLUDE_BCAST,
    TC_SET_INCLUDE,         /* repeatable CLI list */
    TC_SET_CONFIG,
    TC_SET_COLOR,           /* auto/always/never */
    TC_SET_COUNT            /* 41 */
};

// State filter ids (tc_opts.state_filter; also tc_window.state_filter).
enum tc_state {
    TC_ST_NONE = 0,         /* any/all -> no filter */
    TC_ST_LIVE,
    TC_ST_OFFLINE,
    TC_ST_UNKNOWN
};

// Metric / column ids (tc_opts.columns[]; sort ids share them).
enum tc_metric {
    TC_M_COUNT = 0,
    TC_M_LOGIN,             /* sort-only ("login" is not a column) */
    TC_M_LIVE,
    TC_M_OFFLINE,
    TC_M_UNKNOWN,
    TC_M_OFFLINE_SHARE,
    TC_M_LIVE_SHARE,
    TC_M_MAX                /* 7 */
};

// Header mode ids.
enum tc_header_mode {
    TC_HDR_FULL = 0,
    TC_HDR_COMPACT,
    TC_HDR_NONE
};

// --users-policy ids.
enum tc_policy {
    TC_POLICY_AT_LEAST = 0,
    TC_POLICY_AT_MOST,
    TC_POLICY_NEAREST
};

// --color ids.
enum tc_color_mode {
    TC_COLOR_AUTO = 0,
    TC_COLOR_ALWAYS,
    TC_COLOR_NEVER
};

// --complete kind ids, order = COMPLETE_KINDS.
enum tc_complete_kind {
    TC_COMPLETE_CHANNELS = 0,
    TC_COMPLETE_GROUPS,
    TC_COMPLETE_DATES,
    TC_COMPLETE_WEEKS,
    TC_COMPLETE_PERIODS,
    TC_COMPLETE_USERS,
    TC_COMPLETE_INCLUDES
};

// Fade curve ids, order = sorted(CURVES).
enum tc_curve {
    TC_CURVE_LINEAR = 0,
    TC_CURVE_POWER,
    TC_CURVE_EASE_OUT,
    TC_CURVE_BIAS,
    TC_CURVE_EASE_IN_OUT
};

// Config section ids passed to tc_config_get.
enum tc_section {
    TC_SEC_NONE = 0,        /* top-level table */
    TC_SEC_WATCH,           /* [watch] */
    TC_SEC_TAIL             /* [tail] */
};

// Window-start kinds.
enum tc_win_kind {
    TC_WIN_BEGIN = 0,       /* an explicit --begin-style start */
    TC_WIN_SINCE,           /* derived: end - duration */
    TC_WIN_USERS,           /* --users bisection (core sizes it) */
    TC_WIN_EARLIEST         /* default: earliest log file */
};

// Metric kinds (tc_metric_info.kind).
enum tc_metric_kind {
    TC_METRIC_KIND_COUNT = 0,
    TC_METRIC_KIND_SHARE
};

// Flags bitmask (tc_opts.flags).  A bit means the option appeared on the CLI.
#define TC_F_BEGIN_GIVEN      (1u << 0)
#define TC_F_SINCE_GIVEN      (1u << 1)
#define TC_F_END_GIVEN        (1u << 2)
#define TC_F_JSON             (1u << 3)
#define TC_F_WATCH_PRESENT    (1u << 4)   /* -w/--watch seen */
#define TC_F_WATCH_VALUE      (1u << 5)   /* -w/--watch carried a number */
#define TC_F_BY_STATE         (1u << 6)
#define TC_F_NO_EXCLUDE       (1u << 7)
#define TC_F_EXCLUDE_BCAST    (1u << 8)   /* --exclude-broadcaster seen */
#define TC_F_MANUAL           (1u << 9)
#define TC_F_EMIT_FISH        (1u << 10)
#define TC_F_NO_CONFIG        (1u << 11)
#define TC_F_NO_CACHE         (1u << 12)
#define TC_F_REBUILD_CACHE    (1u << 13)
#define TC_F_STREAMER         (1u << 14)  /* --streamer seen */
#define TC_F_CONFIG_GIVEN     (1u << 15)  /* --config seen */
#define TC_F_USERS_GIVEN      (1u << 16)  /* --users seen */
#define TC_F_WATCH_HOLD_GIVEN (1u << 17)  /* --watch-hold seen */
#define TC_F_COLOR_GIVEN      (1u << 18)  /* --color seen */
#define TC_F_COMPLETE_GIVEN   (1u << 19)  /* --complete seen */
#define TC_F_EXCL_GIVEN       (1u << 20)  /* at least one -x/--exclude */
#define TC_F_EXCL_GROUP_GIVEN (1u << 21)  /* at least one -g/--exclude-group */
#define TC_F_INCL_GIVEN       (1u << 22)  /* at least one --include */

// Source ids — provenance labels (tc_opts.src[], tc_config_get, tc_source_str).
// TC_SRC_DYN_* ids read runtime buffers inside tc_opts (win_src/chan_src).
enum tc_source {
    TC_SRC_NONE = 0,
    /* CLI (resolve() labels a CLI hit with the real flag) */
    TC_SRC_CLI_CHANNEL = 1,
    TC_SRC_CLI_USERS_POLICY,
    TC_SRC_CLI_USERS_MAX,
    TC_SRC_CLI_END,
    TC_SRC_CLI_MIN_COUNT,
    TC_SRC_CLI_SHOW,
    TC_SRC_CLI_SORT,
    TC_SRC_CLI_SHARE_FLOOR,
    TC_SRC_CLI_TOP,
    TC_SRC_CLI_LOGS_DIR,
    TC_SRC_CLI_HEADER,
    TC_SRC_CLI_LIVE,
    TC_SRC_CLI_OFFLINE,
    TC_SRC_CLI_UNKNOWN,
    TC_SRC_CLI_BEGIN,
    TC_SRC_CLI_SINCE,
    TC_SRC_CLI_USERS,
    TC_SRC_CLI_WATCH,
    TC_SRC_CLI_WATCH_HOLD,
    TC_SRC_CLI_EXCLUDE,
    TC_SRC_CLI_EXCLUDE_GROUP,
    TC_SRC_CLI_EXCLUDE_BCAST,
    TC_SRC_CLI_INCLUDE,
    TC_SRC_CLI_CONFIG,
    TC_SRC_CLI_STREAMER,
    TC_SRC_CLI_COLOR,
    TC_SRC_CLI_JSON,
    TC_SRC_CLI_BY_STATE,
    TC_SRC_CLI_NO_EXCLUDE,
    TC_SRC_CLI_NO_CONFIG,
    TC_SRC_CLI_NO_CACHE,
    TC_SRC_CLI_REBUILD_CACHE,
    TC_SRC_CLI_MANUAL,
    TC_SRC_CLI_EMIT_FISH,
    TC_SRC_CLI_COMPLETE,
    TC_SRC_CLI_HELP,
    /* env ("env " + the variable name) */
    TC_SRC_ENV_CHANNEL = 37,
    TC_SRC_ENV_USERS_POLICY,
    TC_SRC_ENV_USERS_MAX,
    TC_SRC_ENV_END,
    TC_SRC_ENV_MIN_COUNT,
    TC_SRC_ENV_SHOW,
    TC_SRC_ENV_SORT,
    TC_SRC_ENV_SHARE_FLOOR,
    TC_SRC_ENV_TOP,
    TC_SRC_ENV_LOGS_DIR,
    TC_SRC_ENV_HEADER,
    TC_SRC_ENV_STATE,
    TC_SRC_ENV_BEGIN,
    TC_SRC_ENV_SINCE,
    TC_SRC_ENV_EXCLUDE,
    TC_SRC_ENV_EXCLUDE_BCAST,
    TC_SRC_ENV_WATCH_INTERVAL,
    TC_SRC_ENV_WATCH_MIN_INTERVAL,
    TC_SRC_ENV_WATCH_HOLD,
    TC_SRC_ENV_WATCH_FADE_UP,
    TC_SRC_ENV_WATCH_FADE_DOWN,
    TC_SRC_ENV_WATCH_SHADES,
    TC_SRC_ENV_WATCH_USER_WIDTH,
    TC_SRC_ENV_WATCH_FULL_REPAINT,
    TC_SRC_ENV_WATCH_STREAMER_MODE,
    TC_SRC_ENV_WATCH_MIN_REDRAW,
    TC_SRC_ENV_WATCH_SHOW_TIMING,
    TC_SRC_ENV_WATCH_TINT_FALLING,
    TC_SRC_ENV_WATCH_FADE_CURVE,
    TC_SRC_ENV_WATCH_FADE_K,
    TC_SRC_ENV_WATCH_HIGHLIGHT,
    TC_SRC_ENV_WATCH_REPLAY_STEPS,
    TC_SRC_ENV_TAIL_NOTIFY,
    TC_SRC_ENV_TAIL_MAX_EVENTS,
    TC_SRC_ENV_TAIL_SEED_LOOKBACK,
    /* config */
    TC_SRC_CONFIG = 72,             /* "config" */
    TC_SRC_CONFIG_WATCH,            /* "config [watch]" */
    TC_SRC_CONFIG_TAIL,             /* "config [tail]" */
    /* built-in defaults */
    TC_SRC_DEFAULT_BUILTIN = 75,    /* "built-in default" */
    TC_SRC_DEFAULT,                 /* "default" */
    TC_SRC_DEFAULT_NOW,             /* "default: now" */
    TC_SRC_DEFAULT_EARLIEST,        /* "default: earliest log file" */
    TC_SRC_DEFAULT_UNDER_WATCH,     /* "default under --watch" */
    /* dynamic (composed at runtime; see the buffers in tc_opts) */
    TC_SRC_DYN_SINCE = 80,          /* "<since src> <raw> before end" */
    TC_SRC_DYN_USERS,               /* "--users <N>" */
    TC_SRC_DYN_ALIAS,               /* "<src> -> alias '<key>'" */
    /* exclusion-layer sources */
    TC_SRC_EXCL_CONFIG = 83,        /* "config exclude" */
    TC_SRC_EXCL_ALWAYS,             /* "config always:<name>" (dynamic) */
    TC_SRC_EXCL_GROUP,              /* "--exclude-group <name>" (dynamic) */
    TC_SRC_EXCL_ENV,                /* "env TWITCH_EXCLUDE" */
    TC_SRC_CONFIG_BEGIN,            /* "config begin" (window start source) */
    TC_SRC_CONFIG_SINCE,            /* "config since" (window start source) */
    TC_SRC_COUNT = 89               /* size of the static table */
};

// ============================================================================
// Fixed-size constants — mirror tc_layout.inc capacities.  These are the
// fail-loud ceilings of the fixed arrays below (a config beyond one fails,
// never silently truncates).
// ============================================================================
#define TC_CHANNEL_SZ       64      /* resolved channel name buffer */
#define TC_PATH_SZ          512     /* logs dir / config path buffer */
#define TC_RAW_SZ           64      /* --begin/--since/--end raw text */
#define TC_COLUMNS_MAX      6       /* merged metric columns */
#define TC_LIST_MAX         32      /* repeatable CLI list capacity */
#define TC_LIST_ITEM_SZ     64      /* one login/group item */
#define TC_LIST_GROUP_SZ    32      /* one --exclude-group item */
#define TC_HL_MAX           32      /* max [[watch.highlight]] rules */
#define TC_HL_PAT_MAX       64      /* max patterns per rule */
#define TC_HL_PAT_SZ        256     /* max length of one pattern (NUL incl.) */
#define TC_HL_SRC_SZ        16      /* the colour as written */
#define TC_EX_MAX           512     /* merged exclusion-set capacity */
#define TC_LOGIN_SZ         26      /* login / exclusion-name stride (25+NUL) */
#define TC_T_UNR_MAX        64      /* unreadable-file report capacity */
#define TC_T_UNR_NAME_SZ    64
#define TC_T_UNR_REASON_SZ  64
#define TC_PLAN_HDR_MAX     16      /* header provenance rows */
#define TC_PLAN_ARENA_SZ    8192    /* render scratch arena */
#define TC_FP_SZ            17      /* FNV-1a hex fingerprint (16 chars + NUL) */
#define TC_HDR_LABEL_SZ     40
#define TC_HDR_VALUE_SZ     128
/* The exclude-provenance row joins every exclusion-layer source label with
   ", " (Python `", ".join(exclude_sources)`); a config with several
   always:/--exclude-group layers must never truncate.  The port's own
   dynamic labels are capped at 63 chars each (config.c's 64-byte slots), so
   1024 covers ~16 of them plus separators — far beyond any realistic config
   and the longest the fixtures emit (41-46 chars). */
#define TC_HDR_SOURCE_SZ    1024
#define TC_HDR_COMPACT_SZ   96

// --watch given without a number: resolve the interval from config.  The
// assembly port stores this as the bit pattern of the double -1.0; the C port
// keeps the value itself (interval == -1.0 means "from config").
#define TC_WATCH_FROM_CONFIG_VALUE (-1.0)

// Shared time/scale constants (same values as tc_layout.inc).
#define TC_SECS_PER_DAY     86400
#define TC_SECS_PER_HOUR    3600
#define TC_SECS_PER_WEEK    604800
#define TC_TM_YEAR_BASE     1900    /* struct tm.tm_year counts from 1900 */
#define TC_YMD_YEAR_SCALE   10000   /* packed date: y*10000 + m*100 + d */
#define TC_YMD_MONTH_SCALE  100
#define TC_YMD_MIN          10101   /* 0001-01-01 */
#define TC_YMD_MAX          99991231
#define TC_YEAR1_EPOCH      (-62135596800LL)  /* 0001-01-01T00:00:00 UTC */
#define TC_LAST_SECOND      86399
#define TC_FILE_CAP         (1024LL * 1024 * 1024)  /* 1 GiB sanity cap/file */
#define TC_READ_CHUNK_CORE  8192
#define TC_READ_CHUNK_WATCH 65536
#define TC_DIR_MODE         0777    /* mkdir mode for the cache walk */
#define TC_NANOSEC          INT64_C(1000000000)

// ============================================================================
// Forward declarations — every shared type, so structs can reference each
// other by pointer (and tc_context/tc_report by value once defined).
// ============================================================================
typedef struct tc_highlight tc_highlight;
typedef struct tc_opts tc_opts;
typedef struct tc_window tc_window;
typedef struct tc_users tc_users;
typedef struct tc_listing tc_listing;
typedef struct tc_tally tc_tally;
typedef struct tc_excl_set tc_excl_set;
typedef struct tc_plan tc_plan;
typedef struct tc_frame tc_frame;
typedef struct tc_context tc_context;
typedef struct tc_inputs tc_inputs;
typedef struct tc_selection tc_selection;
typedef struct tc_report tc_report;
typedef struct tc_cache tc_cache;       /* opaque; cache.c owns the layout */
typedef struct tc_watcher tc_watcher;   /* opaque; watch.c owns the layout */
typedef struct tc_platform tc_platform;

// ============================================================================
// Shared data structures
// ============================================================================

// One [[watch.highlight]] rule: a colour and the message patterns that earn
// it.  curve/k of -1 / -1.0 mean "inherit [watch] fade_curve/fade_k".
// Patterns are NUL-terminated heap strings (capacity caps mirror the asm).
struct tc_highlight {
    uint32_t rgb[3];
    int curve;                          /* TC_CURVE_* or -1 = inherit */
    double k;                           /* -1.0 = inherit */
    int pat_count;                      /* <= TC_HL_PAT_MAX */
    char *patterns[TC_HL_PAT_MAX];
    char source[TC_HL_SRC_SZ];          /* the colour as written */
};

// The resolved options — the C counterpart of the asm tc_opts .bss block and
// of Python's Resolved settings.  tc_cli_parse fills it; every later phase
// reads it.  src[TC_SET_*] carries the provenance (TC_SRC_*) of each setting.
struct tc_opts {
    char channel[TC_CHANNEL_SZ];        /* resolved channel (post-alias) */
    char logs_dir[TC_PATH_SZ];
    char begin_raw[TC_RAW_SZ];
    char since_raw[TC_RAW_SZ];
    char end_raw[TC_RAW_SZ];
    char config_path[TC_PATH_SZ];
    const char *prog;                   /* basename(argv[0]); set by parse */

    /* resolved scalar values */
    int64_t min_count;
    int64_t top;                        /* 0 = unlimited */
    int64_t share_floor;
    int64_t users;                      /* --users N requested (0 = none) */
    int64_t users_max;                  /* seconds */
    enum tc_policy users_policy;
    enum tc_state state_filter;
    enum tc_metric sort;
    enum tc_header_mode header_mode;
    enum tc_color_mode color_mode;
    enum tc_complete_kind complete_kind;
    int config_loaded;
    int excl_bcast_val;

    /* merged metric columns (BY_STATE first, then --show, deduped) */
    enum tc_metric columns[TC_COLUMNS_MAX];
    int column_count;
    enum tc_source columns_src;

    /* watch/tail doubles */
    double interval;                    /* -1.0 = from config */
    double min_interval;
    double hold;
    double min_redraw;
    double fade_k;

    /* watch/tail u64 */
    int64_t shades;
    int64_t user_width;
    int64_t full_repaint;
    int64_t replay_steps;
    int streamer_mode;
    int show_timing;
    int tint_falling;
    enum tc_curve fade_curve;
    int notify;                         /* [tail] */
    int64_t max_events;
    int64_t seed_lookback;

    /* watch colours */
    uint32_t fade_up_rgb[3];
    uint32_t fade_down_rgb[3];
    char fade_up_raw[16];
    char fade_down_raw[16];

    /* [[watch.highlight]] rules */
    int hl_count;
    tc_highlight highlights[TC_HL_MAX];

    /* flags + provenance */
    uint32_t flags;                     /* TC_F_* bitmask */
    enum tc_source src[TC_SET_COUNT];

    /* dynamic source buffers (TC_SRC_DYN_*) */
    char win_src[128];
    char chan_src[128];
    char columns_src_buf[64];
    const char *columns_src_ptr;

    /* raw repeatable CLI lists */
    int excl_count;
    char excl_list[TC_LIST_MAX][TC_LIST_ITEM_SZ];
    int incl_count;
    char incl_list[TC_LIST_MAX][TC_LIST_ITEM_SZ];
    int excl_group_count;
    char excl_group_list[TC_LIST_MAX][TC_LIST_GROUP_SZ];
};

// The resolved time range.  tc_cli_parse fills everything except the
// earliest-log-file begin (kind 3) and the --users sizing (kind 2), which
// tc_count_run completes.  Dates are packed YYYYMMDD (TC_YMD_*_SCALE).
struct tc_window {
    int64_t begin_ymd;
    int64_t begin_sod;                  /* seconds-of-day */
    int64_t end_ymd;
    int64_t end_sod;
    enum tc_win_kind kind;
    const char *start_source;           /* label of the window start */
    int64_t threshold;                  /* min_count (resolved) */
    enum tc_state state_filter;
    int begin_rolls;                    /* 1 when begin slides with end */
    int64_t users_width;                /* sized width seconds (core fills) */
    int64_t users_req;                  /* requested N */
    int64_t users_found;                /* found N */
};

// The user table — the counting core owns it: allocates, fills, serves
// lookups.  Entry = {login, live, offline, unknown}; the per-state split is
// Python's `breakdown`, the total is Python's `counts`.
typedef struct tc_user_entry {
    char login[TC_LOGIN_SZ];
    int64_t live;
    int64_t offline;
    int64_t unknown;
} tc_user_entry;

struct tc_users {
    int64_t cap;                        /* allocated capacity */
    int64_t count;
    tc_user_entry *entries;             /* malloc'd array */
};

// Dated log files (core fills, sorted ascending).  Entry = {ymd, name}.
typedef struct tc_listing_entry {
    int64_t ymd;
    char name[64];
} tc_listing_entry;

struct tc_listing {
    int64_t count;
    int64_t cap;
    tc_listing_entry *entries;          /* malloc'd array */
};

// One log the pass could not read: name + reason ("PermissionError: ...").
typedef struct tc_unreadable_entry {
    char name[TC_T_UNR_NAME_SZ];
    char reason[TC_T_UNR_REASON_SZ];
} tc_unreadable_entry;

// Counting-pass results (Python Tally).  The users table carries counts and
// breakdown; the rest is per-pass bookkeeping.
struct tc_tally {
    tc_users *users;                    /* owned by the caller */
    int64_t files;                      /* log files covering the range */
    int64_t messages;                   /* total messages counted */
    int64_t states[3];                  /* live/offline/unknown, post-filter */
    int64_t parsed;                     /* files parsed rather than cached */
    int64_t reused;                     /* days taken from the rollup */
    int64_t excluded_states[3];         /* of `states`, excluded logins' part */
    int64_t unreadable_count;
    tc_unreadable_entry unreadable[TC_T_UNR_MAX];
};

// The merged exclusion set (Python Exclusions): who is excluded, and which
// layer said so.  entry.source_idx indexes sources[]; sources[].ptr may point
// at rodata, at a tc_opts raw list, or at a module-owned buffer.
struct tc_excl_set {
    int64_t count;
    struct {
        char login[TC_LOGIN_SZ];
        int64_t source_idx;
    } entries[TC_EX_MAX];
    struct {
        const char *ptr;
        int64_t len;
    } sources[TC_EX_MAX];
};
typedef tc_excl_set tc_exclusions;      /* Python's Exclusions NamedTuple */

// A display row the presentation builds (asm ROW_* contract).
typedef struct tc_reported_row {
    char login[TC_LOGIN_SZ];
    int64_t count;
    int64_t live;
    int64_t offline;
    int64_t unknown;
    int64_t key;                        /* stable tie-break for sorting */
} tc_reported_row;

// One provenance fact (Python HeaderRow), in both shapes it is ever shown in.
typedef struct tc_header_row {
    char label[TC_HDR_LABEL_SZ];
    char value[TC_HDR_VALUE_SZ];
    char source[TC_HDR_SOURCE_SZ];
    char compact[TC_HDR_COMPACT_SZ];    /* "" = full-header row only */
} tc_header_row;

// The presentation plan (asm tc_plan .bss block / Python Presentation).
// render.c fills it; json.c and watch.c read it.  reported[] is a malloc'd
// array; displayed/hidden are the head/tail of it after the --top cap.
struct tc_plan {
    enum tc_metric columns[TC_COLUMNS_MAX];
    int col_count;
    enum tc_metric sort;
    int64_t share_floor;                /* applied floor (0 = none) */
    int64_t below_floor;                /* rows dropped by the floor */
    int shares_shown;                   /* a share column shown or sorted */
    tc_reported_row *reported;          /* rows after the floor */
    int64_t reported_n;
    int64_t displayed_n;                /* rows after the --top cap */
    int64_t hidden_n;                   /* rows dropped by the cap */
    int64_t limit;                      /* --top N (0 = unlimited) */
    const char *limit_source;
    enum tc_header_mode header_mode;
    int64_t in_range;                   /* users in the time range */
    int64_t excl_appeared;              /* excluded users that appeared */
    int64_t excl_msgs;                  /* messages from excluded users */
    int hdr_count;
    tc_header_row hdr_rows[TC_PLAN_HDR_MAX];
    const char **excl_names;            /* malloc'd sorted names */
    int64_t excl_names_n;
    int64_t msgs_shown;
    int64_t msgs_hidden;
    int cache_used;
    int64_t cache_reused;
    int64_t cache_parsed;
    const char *cache_problem;
    const char *cache_rebuilt;
    const char *cache_path;
    char arena[TC_PLAN_ARENA_SZ];       /* render scratch */
    size_t arena_cur;
    const char *src_join;               /* ", "-joined exclusion sources */
};

// Tint hook: colour one rendered row.  Returns the (possibly reallocated)
// text buffer holding the tinted row.
typedef char *(*tc_tint_fn)(char *text, const char *login, int64_t count,
                            void *ctx);

// Frame-capture + tinting state (asm tc_frame / Python Frame).  The void*
// members are module-owned maps (previous counts, carried tints, ramps,
// palette lookup) kept opaque so the header stays self-contained.
struct tc_frame {
    int capture;                        /* 1 while capturing */
    const char **lines;                 /* captured line-pointer array */
    int64_t max;
    int64_t count;
    int64_t pin_width;                  /* 0 = no pin */
    tc_tint_fn tint_fn;                 /* tint hook (0 = none) */
    void *tint_ctx;
    void *previous;                     /* {login: count} from the frame before */
    void *carried;                      /* {login: (direction, when)} */
    double hold;                        /* seconds a tint survives */
    void *ramps;                        /* ramp key -> escape sequences */
    double now;                         /* monotonic instant */
    void *palette_of;                   /* callable(login) -> ramp key */
};

// [tail] settings (Python TailSettings).
typedef struct tc_tail_settings {
    int notify;
    int64_t max_events;
    int64_t seed_lookback;
} tc_tail_settings;

// Watch settings (Python WatchSettings).  src_* record which layer supplied
// interval, hold and highlights.
typedef struct tc_watch_settings {
    double interval;
    double hold;
    int64_t replay_steps;
    int64_t full_repaint;
    int show_timing;
    double min_redraw;
    int64_t shades;
    int64_t user_width;
    int hl_count;
    tc_highlight highlights[TC_HL_MAX];
    int src_interval;                   /* TC_SRC_* */
    int src_hold;
    int src_highlights;
    void *ramps;                        /* ramp key -> escape sequences */
} tc_watch_settings;

// Config-layer result (Python ConfigLayer).  `values` is the parsed
// toml_table_t* (opaque here); the config module casts it.
typedef struct tc_config_layer {
    void *values;
    char path[TC_PATH_SZ];
    int loaded;
} tc_config_layer;

// Config-file exclusions (Python ConfigExclusions): groups, always-applied
// group names, and the flat `exclude = [...]` form.
typedef struct tc_config_exclusions {
    int64_t group_count;
    struct {
        char name[TC_LIST_ITEM_SZ];
        char members[TC_LIST_MAX][TC_LIST_ITEM_SZ];
        int64_t member_count;
    } groups[TC_LIST_MAX];
    char always[TC_LIST_MAX][TC_LIST_ITEM_SZ];
    int64_t always_count;
    char flat[TC_EX_MAX][TC_LIST_ITEM_SZ];
    int64_t flat_count;
} tc_config_exclusions;

// One row of the cache's file table (Python CachedFile).  fingerprint is the
// 16-hex FNV-1a of the parser generation that produced the row.
typedef struct tc_cached_file {
    char fingerprint[TC_FP_SZ];
    int64_t size;
    int64_t mtime_ns;
    int enter_state;                    /* TC_ST_* */
    int exit_state;                     /* TC_ST_* */
} tc_cached_file;

// Resolved inputs (Python Context).  settings points at the caller's tc_opts.
struct tc_context {
    void *config;                       /* toml_table_t* */
    char config_path[TC_PATH_SZ];
    int config_loaded;
    tc_opts *settings;
    char channel_dir[TC_PATH_SZ];
    char channel_name[TC_CHANNEL_SZ];
    tc_window window;
    tc_tail_settings tail;
    tc_excl_set exclusions;
};

// The half of a context a redraw cannot change (Python Inputs).
struct tc_inputs {
    void *config;
    char config_path[TC_PATH_SZ];
    int config_loaded;
    tc_opts *settings;
    char channel_dir[TC_PATH_SZ];
    char channel_name[TC_CHANNEL_SZ];
    tc_tail_settings tail;
    int kind;                           /* TC_WIN_* window start */
    int start_setting;                  /* TC_SET_BEGIN or TC_SET_SINCE */
    tc_excl_set exclusions;
};

// What the counting pass found, after exclusions (Python Selection).
struct tc_selection {
    tc_users *users;                    /* counts + per-state breakdown */
    int64_t total_messages;
    int64_t files;
    int64_t parsed;
    int64_t reused;
    int64_t states[3];
    int64_t excluded_counts;            /* messages from excluded users */
    const tc_excl_set *exclusions;
    tc_cache *cache;
    const char *cache_problem;          /* why the cache could not be opened */
    tc_unreadable_entry unreadable[TC_T_UNR_MAX];
    int64_t unreadable_count;
};

// A finished report: what was asked, what was found, how to lay it out
// (Python Report).  render.c fills plan; json.c/watch.c read the bundle.
struct tc_report {
    tc_opts *args;
    tc_context *context;
    tc_selection *selection;
    tc_plan plan;
};

// What a completion handler is given (Python CompletionSite).
typedef struct tc_completion_site {
    const tc_opts *args;
    void *config;                       /* toml_table_t* */
    char config_path[TC_PATH_SZ];
    char logs_root[TC_PATH_SZ];
    void *aliases;                      /* toml_table_t* */
    char channel_dir[TC_PATH_SZ];
    char channel_name[TC_CHANNEL_SZ];
} tc_completion_site;

// One metric column: name, header, kind (Python Metric's shape).
typedef struct tc_metric_info {
    const char *name;
    const char *header;
    int kind;                           /* TC_METRIC_KIND_* */
} tc_metric_info;

// The platform: name + logs hint, and the per-OS path defaults (the path
// functions below mirror Python's Platform.logs_dir/config_path/cache_path).
struct tc_platform {
    const char *name;                   /* "macOS" / "Linux" */
    const char *logs_hint;              /* where Chatterino keeps logs (or NULL) */
};

// The selected platform (defined in util.c).
extern const tc_platform tc_platform_current;

// Metric metadata table, indexed by TC_M_* (defined in render.c).
extern const tc_metric_info tc_metrics[TC_M_MAX];

// ============================================================================
// Public function contract — one group per module.
// ============================================================================

// ----------------------------------------------------------------------------
// util.c — shared helpers (plus the platform path defaults).  Mirrors the
// tc_util.S exports, adapted to C: multi-value returns become out-params.
// ----------------------------------------------------------------------------
size_t tc_strlen(const char *s);
void tc_puts(const char *s);                        /* stdout, flushes */
void tc_eputs(const char *s);                       /* stderr, unbuffered */
void tc_putu64(uint64_t v);                         /* decimal to stdout */
void tc_fail(const char *msg);                      /* "error: <msg>", exit 1 */
char *tc_fmt_u64(char *dst, uint64_t v);            /* -> dst+digits, no NUL */
char *tc_fmt_pad(char *dst, uint64_t v, int width); /* zero-padded, -> dst+width */
char *tc_fmt_ymd_sod(char *dst, int64_t ymd, int64_t sod, char sep);
void tc_ymd_split(int64_t ymd, int *y, int *m, int *d);
void tc_sod_split(int64_t sod, int *h, int *min, int *s);
int tc_is_ws(unsigned char c);
char *tc_copy_bytes(char *dst, const char *src, size_t len);   /* -> dst+len */
char *tc_copy_str_cap(char *dst, const char *src, size_t cap); /* bounded copy */
char *tc_cat_cstr_cap(char *cursor, const char *s, size_t cap);
char *tc_cat_cstr(char *cursor, const char *s);
int tc_streq(const char *a, const char *b);
char *tc_fmt2(char *dst, uint64_t v);               /* 2 zero-padded digits */
char *tc_fmt4(char *dst, uint64_t v);               /* 4 zero-padded digits */
int64_t tc_days_from_civil(int y, int m, int d);    /* days since 1970-01-01 */
void tc_civil_from_days(int64_t days, int *y, int *m, int *d);
int tc_is_leap(int y);
int tc_days_in_month(int y, int m);
int64_t tc_ymd_sod_to_epoch(int64_t ymd, int64_t sod);
void tc_epoch_to_ymd_sod(int64_t epoch, int64_t *ymd, int64_t *sod);
size_t tc_expanduser(const char *src, char *dst, size_t cap); /* -> len */
const char *tc_shorten_path(const char *path);              /* -> display ptr */
size_t tc_default_config_path(char *dst, size_t cap);       /* -> len, 0 = none */
size_t tc_default_cache_path(char *dst, size_t cap);
size_t tc_platform_default_logs_dir(char *dst, size_t cap);
int64_t tc_env_int(const char *name, int64_t default_value);
int tc_term_columns(void);
int tc_term_lines(void);
int tc_read_all(const char *path, uint64_t cap, char **buf_out, size_t *len_out);
const char *tc_state_str(int id);                   /* TC_ST_* -> "live", ... */
const char *tc_metric_str(int id);                  /* TC_M_* -> "count", ... */
void tc_win_begin_after_end_check(const tc_window *window); /* fail if after */

// ----------------------------------------------------------------------------
// main.c — the entry point (defined in c/main.c).  The C runtime calls main;
// no other module calls it.  A test driver that includes this header must
// match this exact signature (argc/argv may be left unused with (void) casts).
// ----------------------------------------------------------------------------
int main(int argc, char **argv);

// ----------------------------------------------------------------------------
// cli.c — parse + resolution.  tc_cli_parse fills *opts and *window and
// returns TC_EXIT_OK / TC_EXIT_PARSE / TC_EXIT_ERROR (help on stdout: OK).
// ----------------------------------------------------------------------------
int tc_cli_parse(int argc, char **argv, tc_opts *opts, tc_window *window);
const char *tc_source_str(int id);                  /* -> label for TC_SRC_* */
const char *tc_prog_name(void);                     /* basename(argv[0]) */
void tc_print_help(void);                           /* stdout, then exit 0 */
const char *tc_setting_src_str(int set_id);         /* TC_SET_* -> label */
int tc_parse_datetime(const char *s, int end_of_day_if_dateless,
                      int64_t *ymd, int64_t *sod);  /* -> 1 ok, 0 bad */
int64_t tc_parse_duration(const char *s, int *status); /* 0 ok/1 unrec/2 zero */
int tc_parse_bool(const char *s, int *ok);
int tc_parse_state(const char *s, int *ok);         /* -> TC_ST_* */
int tc_parse_header(const char *s, int *ok);        /* -> TC_HDR_* */
int tc_parse_sort(const char *s, int *ok);          /* -> TC_M_* */
int tc_parse_curve(const char *s, int *ok);         /* -> TC_CURVE_* */
int64_t tc_parse_hex_colour(const char *s, int *ok);/* -> r<<16|g<<8|b */
int tc_parse_metrics(const char *s, int *ok);       /* -> TC_M_* (one name) */
int tc_parse_users_policy(const char *s, int *ok);  /* -> TC_POLICY_* */

// ----------------------------------------------------------------------------
// config.c — env/config access and exclusion building.
// ----------------------------------------------------------------------------
int tc_env_get(const char *name, const char **value_out);  /* 1 found, 0 unset */
int tc_config_get(const char *key, int section_id, const char **value_out,
                  int *source_out);                /* 1 found, 0 absent */
int tc_config_changed(void);                        /* 1 = differs from snapshot */
void tc_config_reload(void);
size_t tc_config_identity(char *dst, size_t cap);   /* -> len; cache fingerprint */
void tc_aliases_apply(tc_opts *opts);               /* rewrite channel aliases */
int tc_build_exclusions(const tc_opts *opts, tc_excl_set *set); /* -> TC_EXIT_OK */
int tc_excl_contains(const tc_excl_set *set, const char *ptr, size_t len);

// ----------------------------------------------------------------------------
// core.c — the counting core.
// ----------------------------------------------------------------------------
int tc_resolve_channel(const tc_opts *opts, char *channel_dir, size_t dir_cap,
                       char *channel_name, size_t name_cap);
int tc_count_run(const tc_opts *opts, const tc_window *window,
                 tc_tally *tally);                   /* -> TC_EXIT_OK */
int64_t tc_count_column(const tc_user_entry *user, int metric); /* TC_M_* value */
int64_t tc_user_state(const tc_user_entry *user, int state);
int64_t tc_user_count(const tc_user_entry *user);
int tc_add_user(tc_users *table, const char *login, size_t len, int state,
                int64_t n);
int64_t tc_find_user(const tc_users *table, const char *login, size_t len);
int tc_reuse_apply(tc_users *table, const char *login, size_t len, int state,
                   int64_t n);                      /* cache hook */
int64_t tc_eff_threshold(const tc_opts *opts);      /* effective --users floor */
int tc_line_is_marker(const char *line, size_t len); /* 1 live / 2 offline / 0 */
int tc_is_timestamp_header(const char *line, size_t len);
size_t tc_speaker_login_to(const char *s, size_t len, char *dst); /* -> login len */
int64_t tc_parse_log_filename_n(const char *name, size_t len);   /* -> ymd or 0 */
int tc_ascii_casecmp(const char *a, const char *b);
const char *tc_errno_reason(int err);               /* "ExcClass: strerror" */
const char *tc_oserror_text(int err);               /* OSError-style reason */

// ----------------------------------------------------------------------------
// cache.c — the SQLite rollup cache.  A cache must never fail a query: on a
// problem tc_cache_open reports it and the run parses every file instead.
// ----------------------------------------------------------------------------
int tc_cache_open(const char *path, int rebuild, const char *channel,
                  tc_cache **cache_out, const char **problem_out);
void tc_cache_close(tc_cache *cache);
int tc_cache_used(const tc_cache *cache);
void tc_cache_status(const tc_cache *cache, int64_t *reused, int64_t *parsed,
                     const char **problem, const char **path);
int tc_cache_day(tc_cache *cache, const char *channel, int64_t ymd,
                 const char *fpath, int64_t size, int64_t mtime_ns,
                 int enter_state, tc_tally *tally); /* 0 miss / 1 served / 2 bad */
void tc_cache_put_day(tc_cache *cache, const char *channel, int64_t ymd,
                      const char *fpath, int64_t size, int64_t mtime_ns,
                      int enter_state, int exit_state, const tc_tally *tally);
void tc_cache_discard_day(tc_cache *cache);
int tc_cache_exit_state(tc_cache *cache, const char *channel, int64_t ymd,
                        const char *fpath, int64_t size, int64_t mtime_ns);
void tc_cache_debug_dump(const tc_cache *cache);    /* test-only */

// ----------------------------------------------------------------------------
// render.c — output formatting (plan, then text or JSON).
// ----------------------------------------------------------------------------
int tc_render_report(tc_report *report);            /* plan, then text/json */
int tc_render_text(tc_report *report);
int tc_plan_presentation(tc_report *report);
void tc_report_fail(const tc_report *report, const char *msg); /* exit 1 */
void tc_frame_begin(tc_frame *frame);
void tc_frame_end(tc_frame *frame);
void tc_frame_set_pin(tc_frame *frame, int width);
void tc_frame_set_tint(tc_frame *frame, tc_tint_fn fn, void *ctx);

// ----------------------------------------------------------------------------
// json.c — the self-describing JSON report.
// ----------------------------------------------------------------------------
int tc_json_emit(const tc_report *report);
void tc_json_err(const char *msg);                  /* {"error": ...} exit 1 */

// ----------------------------------------------------------------------------
// misc.c — --manual / --emit-fish-completions / --complete.
// ----------------------------------------------------------------------------
int tc_misc_manual(void);
int tc_misc_fish(void);
int tc_misc_complete(const tc_opts *opts);
void tc_misc_now_utc(int64_t *ymd, int64_t *sod);

// ----------------------------------------------------------------------------
// watch.c — watch mode + the change-notification watcher seam.
// ----------------------------------------------------------------------------
int tc_watch_run(const tc_opts *opts, const tc_inputs *inputs);
tc_watcher *tc_watcher_new(int notify, int max_events);
void tc_watcher_free(tc_watcher *w);
int tc_watcher_add(tc_watcher *w, const char *path);
int tc_watcher_poll(tc_watcher *w, double timeout_s); /* 1 changed/0 timeout/-1 err */
void tc_watcher_clear(tc_watcher *w);

#endif /* TC_PLATFORM_H */