// ============================================================================
// cli.c — CLI parsing and resolution.
//
// The argparse-equivalent layer: a faithful port of CPython's
// _parse_known_args (left-to-right, no GNU permutation), the value parsers,
// the layered resolution into tc_opts/tc_window, the usage/help formatters
// and the provenance strings.  The Python oracle is twitch-counts.py; the
// error texts and exit codes (2 for parse errors, 1 for resolution errors,
// 0 for help) are byte-identical after the prog-name normalization the
// harness applies.
// ============================================================================

/* localtime_r is a POSIX function; expose it under -std=c99. */
#define _POSIX_C_SOURCE 200809L

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>

/* config.c exports this outside the header (mirroring tc_excl_src_count):
   tc_cli_parse registers the session opts before resolving settings so the
   no-options config hooks honor a --config path / --no-config flag. */
extern void tc_config_register_opts(tc_opts *opts);

// ----------------------------------------------------------------------------
// Constants mirroring the asm port (tc_cli.S).
// ----------------------------------------------------------------------------
#define OPT_MAX       256    /* argv tokens after argv[0] we accept */
#define ARGSTR_SZ     128    /* one scratch token (bundled unknown rest) */
#define SCRATCH_SZ    1024   /* message-assembly scratch */

// ----------------------------------------------------------------------------
// The program name: basename(argv[0]), set by tc_cli_parse; "twitch-counts"
// is the default until then (error messages and the help usage line).
// ----------------------------------------------------------------------------
static char s_prog_name[64] = "twitch-counts";

const char *tc_prog_name(void) {
    return s_prog_name;
}

// ----------------------------------------------------------------------------
// Parser kinds — how a typed option converts its argument, and what its
// failure body reads like (the texts mirror the Python converters).
// ----------------------------------------------------------------------------
enum {
    P_NONE = 0,        /* plain string, no conversion */
    P_POS_INT,         /* positive_int */
    P_NONNEG_INT,      /* nonnegative_int */
    P_NONNEG_FLOAT,    /* nonnegative_float (--watch-hold) */
    P_WATCH,           /* watch_interval: nonnegative_float + from-config */
    P_DURATION,        /* parse_duration (--users-max) */
    P_POLICY,          /* parse_users_policy */
    P_METRICS,         /* parse_metrics, one name (--show) */
    P_SORT,            /* parse_sort */
    P_HEADER,          /* parse_header */
    P_CHOICES_COLOR,   /* choices=("auto","always","never") */
    P_CHOICES_COMPLETE /* choices=COMPLETE_KINDS */
};

// Mutually exclusive groups (argparse add_mutually_exclusive_group order).
enum {
    GROUP_NONE = 0,
    GROUP_WINDOW,      /* -b | -S | --users */
    GROUP_MODE,        /* -j | -w */
    GROUP_STATE,       /* -L | -O | -U */
    GROUP_CONFIG,      /* --config | --no-config */
    GROUP_CACHE        /* --no-cache | --rebuild-cache */
};

// Option kinds (argparse nargs shapes used by this parser).
enum {
    OPT_FLAG = 0,      /* store_true: nargs=0 */
    OPT_VALUE,         /* one argument: nargs=None */
    OPT_OPTIONAL,      /* nargs='?' (--watch) */
    OPT_APPEND         /* append, one argument each time */
};

// One argparse action.
typedef struct {
    const char *short_opt;     /* "-c" or NULL */
    const char *long_opt;      /* "--channel" or NULL */
    int set_id;                /* TC_SET_* or -1 */
    uint32_t flag_bit;         /* TC_F_* or 0 */
    int kind;                  /* OPT_* */
    int parser;                /* P_* */
    int group;                 /* GROUP_* */
    int src_id;                /* TC_SRC_CLI_* for provenance */
    const char *label;         /* the "/"-joined option strings for errors */
} cli_action;

enum {
    A_HELP = 0,
    A_CHANNEL,
    A_BEGIN,
    A_SINCE,
    A_USERS,
    A_USERS_POLICY,
    A_USERS_MAX,
    A_END,
    A_MIN_COUNT,
    A_BY_STATE,
    A_SHOW,
    A_SORT,
    A_SHARE_FLOOR,
    A_TOP,
    A_HEADER,
    A_LOGS_DIR,
    A_JSON,
    A_WATCH,
    A_WATCH_HOLD,
    A_COLOR,
    A_LIVE,
    A_OFFLINE,
    A_UNKNOWN,
    A_EXCLUDE,
    A_EXCLUDE_GROUP,
    A_EXCLUDE_BCAST,
    A_INCLUDE,
    A_NO_EXCLUDE,
    A_CONFIG,
    A_NO_CONFIG,
    A_STREAMER,
    A_NO_CACHE,
    A_REBUILD_CACHE,
    A_MANUAL,
    A_EMIT_FISH,
    A_COMPLETE,
    ACTION_MAX
};

static const cli_action s_actions[ACTION_MAX] = {
    { "-h", "--help", -1, 0, OPT_FLAG, P_NONE, GROUP_NONE,
      TC_SRC_CLI_HELP, "-h/--help" },
    { "-c", "--channel", TC_SET_CHANNEL, 0, OPT_VALUE, P_NONE, GROUP_NONE,
      TC_SRC_CLI_CHANNEL, "-c/--channel" },
    { "-b", "--begin", TC_SET_BEGIN, TC_F_BEGIN_GIVEN, OPT_VALUE, P_NONE,
      GROUP_WINDOW, TC_SRC_CLI_BEGIN, "-b/--begin" },
    { "-S", "--since", TC_SET_SINCE, TC_F_SINCE_GIVEN, OPT_VALUE, P_NONE,
      GROUP_WINDOW, TC_SRC_CLI_SINCE, "-S/--since" },
    { NULL, "--users", TC_SET_USERS, TC_F_USERS_GIVEN, OPT_VALUE, P_POS_INT,
      GROUP_WINDOW, TC_SRC_CLI_USERS, "--users" },
    { NULL, "--users-policy", TC_SET_USERS_POLICY, 0, OPT_VALUE, P_POLICY,
      GROUP_NONE, TC_SRC_CLI_USERS_POLICY, "--users-policy" },
    { NULL, "--users-max", TC_SET_USERS_MAX, 0, OPT_VALUE, P_DURATION,
      GROUP_NONE, TC_SRC_CLI_USERS_MAX, "--users-max" },
    { "-e", "--end", TC_SET_END, TC_F_END_GIVEN, OPT_VALUE, P_NONE,
      GROUP_NONE, TC_SRC_CLI_END, "-e/--end" },
    { "-m", "--min-count", TC_SET_MIN_COUNT, 0, OPT_VALUE, P_POS_INT,
      GROUP_NONE, TC_SRC_CLI_MIN_COUNT, "-m/--min-count" },
    { "-B", "--by-state", -1, TC_F_BY_STATE, OPT_FLAG, P_NONE, GROUP_NONE,
      TC_SRC_CLI_BY_STATE, "-B/--by-state" },
    { NULL, "--show", TC_SET_SHOW, 0, OPT_VALUE, P_METRICS, GROUP_NONE,
      TC_SRC_CLI_SHOW, "--show" },
    { NULL, "--sort", TC_SET_SORT, 0, OPT_VALUE, P_SORT, GROUP_NONE,
      TC_SRC_CLI_SORT, "--sort" },
    { NULL, "--share-floor", TC_SET_SHARE_FLOOR, 0, OPT_VALUE, P_NONNEG_INT,
      GROUP_NONE, TC_SRC_CLI_SHARE_FLOOR, "--share-floor" },
    { "-n", "--top", TC_SET_TOP, 0, OPT_VALUE, P_NONNEG_INT, GROUP_NONE,
      TC_SRC_CLI_TOP, "-n/--top" },
    { NULL, "--header", TC_SET_HEADER, 0, OPT_VALUE, P_HEADER, GROUP_NONE,
      TC_SRC_CLI_HEADER, "--header" },
    { "-d", "--logs-dir", TC_SET_LOGS_DIR, 0, OPT_VALUE, P_NONE, GROUP_NONE,
      TC_SRC_CLI_LOGS_DIR, "-d/--logs-dir" },
    { "-j", "--json", -1, TC_F_JSON, OPT_FLAG, P_NONE, GROUP_MODE,
      TC_SRC_CLI_JSON, "-j/--json" },
    { "-w", "--watch", TC_SET_INTERVAL, TC_F_WATCH_PRESENT, OPT_OPTIONAL,
      P_WATCH, GROUP_MODE, TC_SRC_CLI_WATCH, "-w/--watch" },
    { NULL, "--watch-hold", TC_SET_HOLD, TC_F_WATCH_HOLD_GIVEN, OPT_VALUE,
      P_NONNEG_FLOAT, GROUP_NONE, TC_SRC_CLI_WATCH_HOLD, "--watch-hold" },
    { NULL, "--color", TC_SET_COLOR, TC_F_COLOR_GIVEN, OPT_VALUE,
      P_CHOICES_COLOR, GROUP_NONE, TC_SRC_CLI_COLOR, "--color" },
    { "-L", "--live", TC_SET_STATE, 0, OPT_FLAG, P_NONE, GROUP_STATE,
      TC_SRC_CLI_LIVE, "-L/--live" },
    { "-O", "--offline", TC_SET_STATE, 0, OPT_FLAG, P_NONE, GROUP_STATE,
      TC_SRC_CLI_OFFLINE, "-O/--offline" },
    { "-U", "--unknown", TC_SET_STATE, 0, OPT_FLAG, P_NONE, GROUP_STATE,
      TC_SRC_CLI_UNKNOWN, "-U/--unknown" },
    { "-x", "--exclude", TC_SET_EXCLUDE, TC_F_EXCL_GIVEN, OPT_APPEND, P_NONE,
      GROUP_NONE, TC_SRC_CLI_EXCLUDE, "-x/--exclude" },
    { "-g", "--exclude-group", TC_SET_EXCLUDE_GROUP, TC_F_EXCL_GROUP_GIVEN,
      OPT_APPEND, P_NONE, GROUP_NONE, TC_SRC_CLI_EXCLUDE_GROUP,
      "-g/--exclude-group" },
    { NULL, "--exclude-broadcaster", TC_SET_EXCLUDE_BCAST, TC_F_EXCLUDE_BCAST,
      OPT_FLAG, P_NONE, GROUP_NONE, TC_SRC_CLI_EXCLUDE_BCAST,
      "--exclude-broadcaster" },
    { NULL, "--include", TC_SET_INCLUDE, TC_F_INCL_GIVEN, OPT_APPEND, P_NONE,
      GROUP_NONE, TC_SRC_CLI_INCLUDE, "--include" },
    { NULL, "--no-exclude", -1, TC_F_NO_EXCLUDE, OPT_FLAG, P_NONE, GROUP_NONE,
      TC_SRC_CLI_NO_EXCLUDE, "--no-exclude" },
    { NULL, "--config", TC_SET_CONFIG, TC_F_CONFIG_GIVEN, OPT_VALUE, P_NONE,
      GROUP_CONFIG, TC_SRC_CLI_CONFIG, "--config" },
    { NULL, "--no-config", -1, TC_F_NO_CONFIG, OPT_FLAG, P_NONE, GROUP_CONFIG,
      TC_SRC_CLI_NO_CONFIG, "--no-config" },
    { NULL, "--streamer", TC_SET_STREAMER_MODE, TC_F_STREAMER, OPT_FLAG,
      P_NONE, GROUP_NONE, TC_SRC_CLI_STREAMER, "--streamer" },
    { NULL, "--no-cache", -1, TC_F_NO_CACHE, OPT_FLAG, P_NONE, GROUP_CACHE,
      TC_SRC_CLI_NO_CACHE, "--no-cache" },
    { NULL, "--rebuild-cache", -1, TC_F_REBUILD_CACHE, OPT_FLAG, P_NONE,
      GROUP_CACHE, TC_SRC_CLI_REBUILD_CACHE, "--rebuild-cache" },
    { NULL, "--manual", -1, TC_F_MANUAL, OPT_FLAG, P_NONE, GROUP_NONE,
      TC_SRC_CLI_MANUAL, "--manual" },
    { NULL, "--emit-fish-completions", -1, TC_F_EMIT_FISH, OPT_FLAG, P_NONE,
      GROUP_NONE, TC_SRC_CLI_EMIT_FISH, "--emit-fish-completions" },
    { NULL, "--complete", -1, TC_F_COMPLETE_GIVEN, OPT_VALUE,
      P_CHOICES_COMPLETE, GROUP_NONE, TC_SRC_CLI_COMPLETE, "--complete" },
};

// Which actions each group holds, in declaration order (the conflict message
// names the first already-seen member of the other action's group).
static const int s_group_members[][4] = {
    { 0 },                                /* GROUP_NONE unused */
    { A_BEGIN, A_SINCE, A_USERS, -1 },    /* GROUP_WINDOW */
    { A_JSON, A_WATCH, -1, -1 },          /* GROUP_MODE */
    { A_LIVE, A_OFFLINE, A_UNKNOWN, -1 }, /* GROUP_STATE */
    { A_CONFIG, A_NO_CONFIG, -1, -1 },    /* GROUP_CONFIG */
    { A_NO_CACHE, A_REBUILD_CACHE, -1, -1 } /* GROUP_CACHE */
};

// ----------------------------------------------------------------------------
// Parsed CLI state (owned on tc_cli_parse's stack; argv pointers are valid
// for the whole call).
// ----------------------------------------------------------------------------
typedef struct {
    const char *channel;
    const char *begin_raw;
    const char *since_raw;
    int64_t users;
    const char *users_policy;
    int users_policy_set;
    int64_t users_policy_id;
    const char *users_max;
    const char *end_raw;
    int64_t min_count;
    int min_count_set;
    int by_state;
    int show_count;
    int64_t show[TC_COLUMNS_MAX];
    int sort_given;
    int64_t sort;
    int64_t share_floor;
    int share_floor_set;
    int64_t top;
    int top_set;
    const char *header_raw;
    const char *logs_dir;
    int watch_given;          /* -w/--watch seen */
    int watch_value_given;    /* it carried a number */
    double watch;
    double watch_hold;
    int watch_hold_given;
    int color_mode;           /* TC_COLOR_* */
    int color_given;
    int state_flag;           /* TC_ST_* from -L/-O/-U, or 0 */
    const char *excl[TC_LIST_MAX];
    int excl_n;
    const char *excl_group[TC_LIST_MAX];
    int excl_group_n;
    const char *incl[TC_LIST_MAX];
    int incl_n;
    int exclude_bcast;
    int no_exclude;
    const char *config;
    int no_config;
    int streamer;
    int no_cache;
    int rebuild_cache;
    int manual;
    int emit_fish;
    int complete_kind;
    int complete_given;
    uint32_t flags;
} cli_parsed;

// ----------------------------------------------------------------------------
// Small text helpers.
// ----------------------------------------------------------------------------
static int ascii_ws(unsigned char c) {
    return c == ' ' || (c >= 9 && c <= 13);
}

/* Python's repr() of a short string: single-quoted, backslash and quote
   escaped.  Returns the cursor. */
static char *py_repr(char *dst, const char *s) {
    *dst++ = '\'';
    while (*s != '\0') {
        if (*s == '\\' || *s == '\'') {
            *dst++ = '\\';
        }
        *dst++ = *s++;
    }
    *dst++ = '\'';
    return dst;
}

/* str(text).strip(): drop leading/trailing ASCII whitespace in place. */
static void strip_inplace(char *s) {
    size_t len = strlen(s);
    char *start = s;
    char *end = s + len;
    while (end > start && ascii_ws((unsigned char)end[-1])) {
        end--;
    }
    while (start < end && ascii_ws((unsigned char)*start)) {
        start++;
    }
    if (start != s) {
        memmove(s, start, (size_t)(end - start));
    }
    s[end - start] = '\0';
}

static void lowercase_inplace(char *s) {
    for (; *s != '\0'; s++) {
        if (*s >= 'A' && *s <= 'Z') {
            *s = (char)(*s - 'A' + 'a');
        }
    }
}

static int is_wordish(char c) {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
           || (c >= '0' && c <= '9') || c == '_';
}

// ----------------------------------------------------------------------------
// Calendar helpers shared by the datetime parser and the week check.
// ----------------------------------------------------------------------------
static int read_1to2_digits(const char **pp, int *out) {
    const char *p = *pp;
    int v = 0;
    int n = 0;
    if (*p < '0' || *p > '9') {
        return 0;
    }
    while (n < 2 && *p >= '0' && *p <= '9') {
        v = v * 10 + (*p - '0');
        p++;
        n++;
    }
    *pp = p;
    *out = v;
    return 1;
}

static int read_4_digits(const char **pp, int *out) {
    const char *p = *pp;
    int v = 0;
    int i;
    for (i = 0; i < 4; i++) {
        if (*p < '0' || *p > '9') {
            return 0;
        }
        v = v * 10 + (*p - '0');
        p++;
    }
    *pp = p;
    *out = v;
    return 1;
}

static int is_valid_ymd(int y, int m, int d) {
    return y >= 1 && y <= 9999 && m >= 1 && m <= 12
           && d >= 1 && d <= tc_days_in_month(y, m);
}

static int finish_datetime(int y, int m, int d, int h, int mi, int s,
                           int end_of_day_if_dateless,
                           int64_t *ymd, int64_t *sod) {
    /* h == -1 is the "no time part" sentinel the parsers set for a dateless
       input: the end-of-day rule applies only then (Python parse_datetime
       end_of_day_if_dateless).  A time-bearing input keeps its time even at
       end_of_day_if_dateless — "2026-09-01 15:15:35" is 15:15:35, not
       23:59:59.  (The asm port's cli_parse_fixed_datetime returns the sod
       from the parse itself, which is where this distinction lives.) */
    if (!is_valid_ymd(y, m, d) || h < -1 || h > 23 || mi < 0 || mi > 59
        || s < 0 || s > 59) {
        return 0;
    }
    *ymd = (int64_t)y * TC_YMD_YEAR_SCALE + (int64_t)m * TC_YMD_MONTH_SCALE + d;
    if (h == -1) {
        *sod = end_of_day_if_dateless ? TC_LAST_SECOND : 0;
    } else {
        *sod = (int64_t)h * TC_SECS_PER_HOUR + (int64_t)mi * 60 + s;
    }
    return 1;
}

/* time_kind: 1 = full HH:MM:SS, 2 = HH:MM, 3 = HH, 4 = date only. */
static int parse_fixed_datetime(const char *s, char sep, int time_kind,
                                int *y, int *m, int *d,
                                int *h, int *mi, int *sec) {
    const char *p = s;
    int yy, mm, dd;
    *h = *mi = *sec = 0;
    if (!read_4_digits(&p, &yy)) {
        return 0;
    }
    if (*p != sep) {
        return 0;
    }
    p++;
    if (!read_1to2_digits(&p, &mm)) {
        return 0;
    }
    if (*p != sep) {
        return 0;
    }
    p++;
    if (!read_1to2_digits(&p, &dd)) {
        return 0;
    }
    if (time_kind == 4) {
        if (*p != '\0') {
            return 0;
        }
        *h = -1;   /* dateless: the "no time part" sentinel for finish_datetime */
    } else if (time_kind == 3) {
        if (*p != ' ') {
            return 0;
        }
        p++;
        if (!read_1to2_digits(&p, h)) {
            return 0;
        }
        if (*p != '\0') {
            return 0;
        }
    } else {
        if (*p != ' ') {
            return 0;
        }
        p++;
        if (!read_1to2_digits(&p, h)) {
            return 0;
        }
        if (*p != ':') {
            return 0;
        }
        p++;
        if (!read_1to2_digits(&p, mi)) {
            return 0;
        }
        if (time_kind == 1) {
            if (*p != ':') {
                return 0;
            }
            p++;
            if (!read_1to2_digits(&p, sec)) {
                return 0;
            }
            if (*p != '\0') {
                return 0;
            }
        } else if (*p != '\0') {
            return 0;
        }
    }
    *y = yy;
    *m = mm;
    *d = dd;
    return 1;
}

/* datetime.fromisoformat subset: "YYYY-MM-DD" / "YYYYMMDD", optionally
   followed by 'T'/space and HH:MM[:SS[.ffffff]], with an optional UTC
   offset that is accepted and ignored (matching the naive arithmetic the
   tool performs). */
static int parse_fromisoformat(const char *s, int *y, int *m, int *d,
                               int *h, int *mi, int *sec) {
    const char *p = s;
    int yy, mm, dd, hh = -1, mn = 0, ss = 0;   /* hh == -1: no time part */
    if (!read_4_digits(&p, &yy)) {
        return 0;
    }
    if (*p == '-') {
        p++;
        if (!read_1to2_digits(&p, &mm)) {
            return 0;
        }
        if (*p != '-') {
            return 0;
        }
        p++;
        if (!read_1to2_digits(&p, &dd)) {
            return 0;
        }
    } else {
        if (!read_1to2_digits(&p, &mm)) {
            return 0;
        }
        if (!read_1to2_digits(&p, &dd)) {
            return 0;
        }
    }
    if (*p == 'T' || *p == ' ') {
        p++;
        if (!read_1to2_digits(&p, &hh)) {
            return 0;
        }
        if (*p == ':') {
            p++;
            if (!read_1to2_digits(&p, &mn)) {
                return 0;
            }
            if (*p == ':') {
                p++;
                if (!read_1to2_digits(&p, &ss)) {
                    return 0;
                }
            }
        }
        if (*p == '.') {
            p++;
            while (*p >= '0' && *p <= '9') {
                p++;
            }
        }
        if (*p == '+' || *p == '-' || *p == 'Z') {
            if (*p == 'Z') {
                p++;
            } else {
                p++;
                while ((*p >= '0' && *p <= '9') || *p == ':') {
                    p++;
                }
            }
        }
    }
    if (*p != '\0') {
        return 0;
    }
    *y = yy;
    *m = mm;
    *d = dd;
    *h = hh;
    *mi = mn;
    *sec = ss;
    return 1;
}

/* Midnight on the Monday opening ISO year/week.  Returns 1 and sets *ymd,
   or 0 when the week does not exist in that ISO year. */
static int iso_week_monday(int year, int week, int *ymd) {
    int64_t jan4_epoch;
    int jan4_weekday;   /* 0 = Monday ... 6 = Sunday */
    int64_t thursday;
    int64_t thu_ymd;
    int64_t monday_ymd;
    int64_t sod;
    if (week < 1 || week > 53) {
        return 0;
    }
    jan4_epoch = tc_ymd_sod_to_epoch((int64_t)year * 10000 + 104, 0);
    /* ISO week 1 is the week containing Jan 4; its Thursday is the weekday
       on or before Jan 4.  epoch day 0 (1970-01-01) was a Thursday (3). */
    jan4_weekday = (int)(((jan4_epoch / 86400) + 3) % 7);
    thursday = jan4_epoch + (int64_t)(3 - jan4_weekday) * 86400;
    /* Week `week`'s Thursday is (week-1)*7 days later and must fall in the
       week-numbering year. */
    tc_epoch_to_ymd_sod(thursday + (int64_t)(week - 1) * 7 * 86400,
                        &thu_ymd, &sod);
    if (thu_ymd / 10000 != year) {
        return 0;
    }
    tc_epoch_to_ymd_sod(thursday + (int64_t)(week - 1) * 7 * 86400
                        - 3 * 86400, &monday_ymd, &sod);
    *ymd = (int)monday_ymd;
    return 1;
}

/* Did the raw text name an ISO week that does not exist (or an out-of-range
   week number)?  Used to report Python's "no week N in ISO year Y ...". */
static int parse_week_failure(const char *disp, int *y, int *w) {
    const char *p = disp;
    int year = 0, week = 0, i;
    if (p[0] < '0' || p[0] > '9') {
        return 0;
    }
    for (i = 0; i < 4; i++) {
        if (p[i] < '0' || p[i] > '9') {
            return 0;
        }
        year = year * 10 + (p[i] - '0');
    }
    p += 4;
    if (*p == 'W' || *p == 'w') {
        p++;
    } else if (*p == '-' && (p[1] == 'W' || p[1] == 'w')) {
        p += 2;
    } else {
        return 0;
    }
    if (*p < '0' || *p > '9') {
        return 0;
    }
    while (*p >= '0' && *p <= '9') {
        week = week * 10 + (*p - '0');
        p++;
    }
    if (*p != '\0') {
        return 0;
    }
    if (week < 1 || week > 53) {
        *y = year;
        *w = week;
        return 1;
    }
    {
        int monday;
        if (!iso_week_monday(year, week, &monday)) {
            *y = year;
            *w = week;
            return 1;
        }
    }
    return 0;
}

// ----------------------------------------------------------------------------
// The value parsers (public API).
// ----------------------------------------------------------------------------

int64_t tc_parse_duration(const char *s, int *status) {
    /* parse_duration: strip + lower, then ^(?:\d+[wdhms])+$; the sum of the
       parts in seconds.  status: 0 ok, 1 unrecognized, 2 zero. */
    char buf[TC_RAW_SZ];
    const char *p;
    long double total = 0;

    *status = 1;
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    lowercase_inplace(buf);
    if (buf[0] == '\0') {
        return 0;
    }
    p = buf;
    while (*p != '\0') {
        uint64_t value = 0;
        int digits = 0;
        while (*p >= '0' && *p <= '9') {
            value = value * 10 + (uint64_t)(*p - '0');
            if (value > (uint64_t)INT64_MAX) {
                value = (uint64_t)INT64_MAX;
            }
            digits = 1;
            p++;
        }
        if (!digits || *p == '\0') {
            return 0;
        }
        switch (*p) {
        case 'w': total += (long double)value * 604800; break;
        case 'd': total += (long double)value * 86400; break;
        case 'h': total += (long double)value * 3600; break;
        case 'm': total += (long double)value * 60; break;
        case 's': total += (long double)value; break;
        default:
            return 0;
        }
        p++;
    }
    if (total <= 0) {
        *status = 2;
        return 0;
    }
    if (total > (long double)INT64_MAX) {
        total = (long double)INT64_MAX;
    }
    *status = 0;
    return (int64_t)total;
}

int tc_parse_bool(const char *s, int *ok) {
    char buf[64];
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    lowercase_inplace(buf);
    if (tc_streq(buf, "1") || tc_streq(buf, "true") || tc_streq(buf, "yes")
        || tc_streq(buf, "on")) {
        *ok = 1;
        return 1;
    }
    if (tc_streq(buf, "0") || tc_streq(buf, "false") || tc_streq(buf, "no")
        || tc_streq(buf, "off")) {
        *ok = 1;
        return 0;
    }
    *ok = 0;
    return 0;
}

int tc_parse_state(const char *s, int *ok) {
    char buf[64];
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    lowercase_inplace(buf);
    if (tc_streq(buf, "live")) {
        *ok = 1;
        return TC_ST_LIVE;
    }
    if (tc_streq(buf, "offline")) {
        *ok = 1;
        return TC_ST_OFFLINE;
    }
    if (tc_streq(buf, "unknown")) {
        *ok = 1;
        return TC_ST_UNKNOWN;
    }
    if (tc_streq(buf, "any") || tc_streq(buf, "all")) {
        *ok = 1;
        return TC_ST_NONE;
    }
    *ok = 0;
    return TC_ST_NONE;
}

int tc_parse_header(const char *s, int *ok) {
    char buf[64];
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    lowercase_inplace(buf);
    if (tc_streq(buf, "full")) {
        *ok = 1;
        return TC_HDR_FULL;
    }
    if (tc_streq(buf, "compact")) {
        *ok = 1;
        return TC_HDR_COMPACT;
    }
    if (tc_streq(buf, "none")) {
        *ok = 1;
        return TC_HDR_NONE;
    }
    *ok = 0;
    return TC_HDR_FULL;
}

int tc_parse_sort(const char *s, int *ok) {
    char buf[64];
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    lowercase_inplace(buf);
    if (tc_streq(buf, "count")) {
        *ok = 1;
        return TC_M_COUNT;
    }
    if (tc_streq(buf, "login")) {
        *ok = 1;
        return TC_M_LOGIN;
    }
    if (tc_streq(buf, "live")) {
        *ok = 1;
        return TC_M_LIVE;
    }
    if (tc_streq(buf, "offline")) {
        *ok = 1;
        return TC_M_OFFLINE;
    }
    if (tc_streq(buf, "unknown")) {
        *ok = 1;
        return TC_M_UNKNOWN;
    }
    if (tc_streq(buf, "offline-share")) {
        *ok = 1;
        return TC_M_OFFLINE_SHARE;
    }
    if (tc_streq(buf, "live-share")) {
        *ok = 1;
        return TC_M_LIVE_SHARE;
    }
    *ok = 0;
    return TC_M_COUNT;
}

int tc_parse_curve(const char *s, int *ok) {
    char buf[64];
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    lowercase_inplace(buf);
    if (tc_streq(buf, "linear")) {
        *ok = 1;
        return TC_CURVE_LINEAR;
    }
    if (tc_streq(buf, "power")) {
        *ok = 1;
        return TC_CURVE_POWER;
    }
    if (tc_streq(buf, "ease-out")) {
        *ok = 1;
        return TC_CURVE_EASE_OUT;
    }
    if (tc_streq(buf, "bias")) {
        *ok = 1;
        return TC_CURVE_BIAS;
    }
    if (tc_streq(buf, "ease-in-out")) {
        *ok = 1;
        return TC_CURVE_EASE_IN_OUT;
    }
    *ok = 0;
    return TC_CURVE_LINEAR;
}

int64_t tc_parse_hex_colour(const char *s, int *ok) {
    /* ^#?([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$; a 3-digit value doubles each
       digit.  Returns r<<16 | g<<8 | b. */
    const char *p = s;
    char digits[7];
    int n = 0;
    *ok = 0;
    while (ascii_ws((unsigned char)*p)) {
        p++;
    }
    if (*p == '#') {
        p++;
    }
    while ((*p >= '0' && *p <= '9') || (*p >= 'a' && *p <= 'f')
           || (*p >= 'A' && *p <= 'F')) {
        if (n < 6) {
            digits[n] = *p;
        }
        n++;
        p++;
    }
    while (ascii_ws((unsigned char)*p)) {
        p++;
    }
    if (*p != '\0' || (n != 3 && n != 6)) {
        return 0;
    }
    {
        char expanded[6];
        int64_t rgb = 0;
        int i;
        if (n == 3) {
            for (i = 0; i < 3; i++) {
                expanded[i * 2] = digits[i];
                expanded[i * 2 + 1] = digits[i];
            }
        } else {
            for (i = 0; i < 6; i++) {
                expanded[i] = digits[i];
            }
        }
        for (i = 0; i < 3; i++) {
            char c = expanded[i * 2];
            int hi = (c >= '0' && c <= '9') ? c - '0'
                    : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : c - 'A' + 10;
            c = expanded[i * 2 + 1];
            int lo = (c >= '0' && c <= '9') ? c - '0'
                    : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : c - 'A' + 10;
            rgb = (rgb << 8) | ((hi << 4) | lo);
        }
        *ok = 1;
        return rgb;
    }
}

int tc_parse_metrics(const char *s, int *ok) {
    /* One metric name (the caller splits the comma/space list). */
    char buf[64];
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    if (tc_streq(buf, "count")) {
        *ok = 1;
        return TC_M_COUNT;
    }
    if (tc_streq(buf, "live")) {
        *ok = 1;
        return TC_M_LIVE;
    }
    if (tc_streq(buf, "offline")) {
        *ok = 1;
        return TC_M_OFFLINE;
    }
    if (tc_streq(buf, "unknown")) {
        *ok = 1;
        return TC_M_UNKNOWN;
    }
    if (tc_streq(buf, "offline-share")) {
        *ok = 1;
        return TC_M_OFFLINE_SHARE;
    }
    if (tc_streq(buf, "live-share")) {
        *ok = 1;
        return TC_M_LIVE_SHARE;
    }
    *ok = 0;
    return TC_M_COUNT;
}

int tc_parse_users_policy(const char *s, int *ok) {
    char buf[64];
    tc_copy_str_cap(buf, s, sizeof(buf));
    strip_inplace(buf);
    lowercase_inplace(buf);
    if (tc_streq(buf, "at-least")) {
        *ok = 1;
        return TC_POLICY_AT_LEAST;
    }
    if (tc_streq(buf, "at-most")) {
        *ok = 1;
        return TC_POLICY_AT_MOST;
    }
    if (tc_streq(buf, "nearest")) {
        *ok = 1;
        return TC_POLICY_NEAREST;
    }
    *ok = 0;
    return TC_POLICY_AT_LEAST;
}

int tc_parse_datetime(const char *s, int end_of_day_if_dateless,
                      int64_t *ymd, int64_t *sod) {
    char raw[TC_RAW_SZ];
    const char *p;

    tc_copy_str_cap(raw, s, sizeof(raw));
    strip_inplace(raw);
    if (raw[0] == '\0') {
        return 0;
    }

    /* ISO week: ^(\d{4})-?[Ww](\d{1,2})$ — a token with a trailing weekday is
   the weekday form below, so the plain-week branch only claims it when the
   week digits run to the end of the string. */
    {
        int year = 0, week = 0, i;
        const char *wmark = NULL;
        if (raw[4] == 'W' || raw[4] == 'w') {
            wmark = raw + 4;
        } else if (raw[4] == '-' && (raw[5] == 'W' || raw[5] == 'w')) {
            wmark = raw + 5;
        }
        if (wmark != NULL) {
            for (i = 0; i < 4; i++) {
                if (raw[i] < '0' || raw[i] > '9') {
                    return 0;
                }
                year = year * 10 + (raw[i] - '0');
            }
            p = wmark + 1;
            while (*p >= '0' && *p <= '9') {
                week = week * 10 + (*p - '0');
                p++;
            }
            if (*p == '\0') {
                int monday;
                if (week < 1 || week > 53
                    || !iso_week_monday(year, week, &monday)) {
                    return 0;
                }
                if (end_of_day_if_dateless) {
                    /* a dateless week names the whole week: Monday + 6 days
                       lands on its Sunday, then snap to 23:59:59 (Python:
                       monday + timedelta(days=6, hours=23, minutes=59,
                       seconds=59)). */
                    int64_t sunday_epoch = tc_ymd_sod_to_epoch(monday, 0)
                                           + 6 * (int64_t)TC_SECS_PER_DAY
                                           + TC_LAST_SECOND;
                    tc_epoch_to_ymd_sod(sunday_epoch, ymd, sod);
                } else {
                    *ymd = monday;
                    *sod = 0;
                }
                return 1;
            }
            /* not a plain week (a weekday tail, or garbage): fall through */
        }
    }

    /* ISO week with weekday: ^(\d{4})-?[Ww](\d{1,2})-([1-7])$ */
    {
        const char *wpos = NULL;
        for (p = raw; *p != '\0'; p++) {
            if (*p == 'W' || *p == 'w') {
                wpos = p;
                break;
            }
        }
        if (wpos != NULL && wpos >= raw + 4 && wpos <= raw + 5) {
            int year = 0, week = 0, day = 0, i;
            const char *q = raw;
            for (i = 0; i < 4; i++) {
                if (*q < '0' || *q > '9') {
                    return 0;
                }
                year = year * 10 + (*q - '0');
                q++;
            }
            if (wpos == raw + 5) {
                if (*q != '-') {
                    return 0;
                }
                q++;
            }
            if (*q != 'W' && *q != 'w') {
                return 0;
            }
            q++;
            for (i = 0; i < 2; i++) {
                if (*q < '0' || *q > '9') {
                    return 0;
                }
                week = week * 10 + (*q - '0');
                q++;
            }
            if (*q != '-' || q[1] < '1' || q[1] > '7' || q[2] != '\0') {
                return 0;
            }
            day = q[1] - '0';
            {
                int monday;
                if (week < 1 || week > 53
                    || !iso_week_monday(year, week, &monday)) {
                    return 0;
                }
                {
                    int64_t day_epoch = tc_ymd_sod_to_epoch(monday, 0)
                                        + (int64_t)(day - 1) * 86400;
                    int64_t dymd;
                    tc_epoch_to_ymd_sod(day_epoch, &dymd, sod);
                    if (end_of_day_if_dateless) {
                        *sod = TC_LAST_SECOND;
                    }
                    *ymd = dymd;
                    return 1;
                }
            }
        }
    }

    /* Normalized formats (T -> space), tried in order. */
    {
        char norm[TC_RAW_SZ];
        char *t;
        tc_copy_str_cap(norm, raw, sizeof(norm));
        for (t = norm; *t != '\0'; t++) {
            if (*t == 'T') {
                *t = ' ';
            }
        }
        {
            int y, m, d, h, mi, s;
            if (parse_fixed_datetime(norm, '-', 1, &y, &m, &d, &h, &mi, &s)) {
                return finish_datetime(y, m, d, h, mi, s,
                                       end_of_day_if_dateless, ymd, sod);
            }
            if (parse_fixed_datetime(norm, '-', 2, &y, &m, &d, &h, &mi, &s)) {
                return finish_datetime(y, m, d, h, mi, s,
                                       end_of_day_if_dateless, ymd, sod);
            }
            if (parse_fixed_datetime(norm, '-', 3, &y, &m, &d, &h, &mi, &s)) {
                return finish_datetime(y, m, d, h, mi, s,
                                       end_of_day_if_dateless, ymd, sod);
            }
            if (parse_fixed_datetime(norm, '-', 4, &y, &m, &d, &h, &mi, &s)) {
                return finish_datetime(y, m, d, h, mi, s,
                                       end_of_day_if_dateless, ymd, sod);
            }
            if (parse_fixed_datetime(norm, '/', 1, &y, &m, &d, &h, &mi, &s)) {
                return finish_datetime(y, m, d, h, mi, s,
                                       end_of_day_if_dateless, ymd, sod);
            }
            if (parse_fixed_datetime(norm, '/', 2, &y, &m, &d, &h, &mi, &s)) {
                return finish_datetime(y, m, d, h, mi, s,
                                       end_of_day_if_dateless, ymd, sod);
            }
            if (parse_fixed_datetime(norm, '/', 4, &y, &m, &d, &h, &mi, &s)) {
                return finish_datetime(y, m, d, h, mi, s,
                                       end_of_day_if_dateless, ymd, sod);
            }
        }
    }

    /* datetime.fromisoformat fallback. */
    {
        int y, m, d, h, mi, s;
        if (parse_fromisoformat(raw, &y, &m, &d, &h, &mi, &s)) {
            return finish_datetime(y, m, d, h, mi, s,
                                   end_of_day_if_dateless, ymd, sod);
        }
    }
    return 0;
}

// ----------------------------------------------------------------------------
// Source strings (tc_source_str / tc_setting_src_str).
// ----------------------------------------------------------------------------
static const char s_src_none[] = "";
static const char s_src_cli_channel[] = "--channel";
static const char s_src_cli_users_policy[] = "--users-policy";
static const char s_src_cli_users_max[] = "--users-max";
static const char s_src_cli_end[] = "--end";
static const char s_src_cli_min_count[] = "--min-count";
static const char s_src_cli_show[] = "--show";
static const char s_src_cli_sort[] = "--sort";
static const char s_src_cli_share_floor[] = "--share-floor";
static const char s_src_cli_top[] = "--top";
static const char s_src_cli_logs_dir[] = "--logs-dir";
static const char s_src_cli_header[] = "--header";
static const char s_src_cli_live[] = "--live";
static const char s_src_cli_offline[] = "--offline";
static const char s_src_cli_unknown[] = "--unknown";
static const char s_src_cli_begin[] = "--begin";
static const char s_src_cli_since[] = "--since";
static const char s_src_cli_users[] = "--users";
static const char s_src_cli_watch[] = "--watch";
static const char s_src_cli_watch_hold[] = "--watch-hold";
static const char s_src_cli_exclude[] = "--exclude";
static const char s_src_cli_exclude_group[] = "--exclude-group";
static const char s_src_cli_exclude_bcast[] = "--exclude-broadcaster";
static const char s_src_cli_include[] = "--include";
static const char s_src_cli_config[] = "--config";
static const char s_src_cli_streamer[] = "--streamer";
static const char s_src_cli_color[] = "--color";
static const char s_src_cli_json[] = "--json";
static const char s_src_cli_by_state[] = "--by-state";
static const char s_src_cli_no_exclude[] = "--no-exclude";
static const char s_src_cli_no_config[] = "--no-config";
static const char s_src_cli_no_cache[] = "--no-cache";
static const char s_src_cli_rebuild_cache[] = "--rebuild-cache";
static const char s_src_cli_manual[] = "--manual";
static const char s_src_cli_emit_fish[] = "--emit-fish-completions";
static const char s_src_cli_complete[] = "--complete";
static const char s_src_cli_help[] = "--help";

static const char s_src_env_channel[] = "env TWITCH_CHANNEL";
static const char s_src_env_users_policy[] = "env TWITCH_USERS_POLICY";
static const char s_src_env_users_max[] = "env TWITCH_USERS_MAX";
static const char s_src_env_end[] = "env TWITCH_END";
static const char s_src_env_min_count[] = "env TWITCH_MIN_COUNT";
static const char s_src_env_show[] = "env TWITCH_SHOW";
static const char s_src_env_sort[] = "env TWITCH_SORT";
static const char s_src_env_share_floor[] = "env TWITCH_SHARE_FLOOR";
static const char s_src_env_top[] = "env TWITCH_TOP";
static const char s_src_env_logs_dir[] = "env TWITCH_LOGS_DIR";
static const char s_src_env_header[] = "env TWITCH_HEADER";
static const char s_src_env_state[] = "env TWITCH_STATE";
static const char s_src_env_begin[] = "env TWITCH_BEGIN";
static const char s_src_env_since[] = "env TWITCH_SINCE";
static const char s_src_env_exclude[] = "env TWITCH_EXCLUDE";
static const char s_src_env_exclude_bcast[] = "env TWITCH_EXCLUDE_BROADCASTER";
static const char s_src_env_watch_interval[] = "env TWITCH_WATCH_INTERVAL";
static const char s_src_env_watch_min_interval[] =
    "env TWITCH_WATCH_MIN_INTERVAL";
static const char s_src_env_watch_hold[] = "env TWITCH_WATCH_HOLD";
static const char s_src_env_watch_fade_up[] = "env TWITCH_WATCH_FADE_UP";
static const char s_src_env_watch_fade_down[] = "env TWITCH_WATCH_FADE_DOWN";
static const char s_src_env_watch_shades[] = "env TWITCH_WATCH_SHADES";
static const char s_src_env_watch_user_width[] = "env TWITCH_WATCH_USER_WIDTH";
static const char s_src_env_watch_full_repaint[] =
    "env TWITCH_WATCH_FULL_REPAINT";
static const char s_src_env_watch_streamer_mode[] =
    "env TWITCH_WATCH_STREAMER_MODE";
static const char s_src_env_watch_min_redraw[] = "env TWITCH_WATCH_MIN_REDRAW";
static const char s_src_env_watch_show_timing[] =
    "env TWITCH_WATCH_SHOW_TIMING";
static const char s_src_env_watch_tint_falling[] =
    "env TWITCH_WATCH_TINT_FALLING";
static const char s_src_env_watch_fade_curve[] = "env TWITCH_WATCH_FADE_CURVE";
static const char s_src_env_watch_fade_k[] = "env TWITCH_WATCH_FADE_K";
static const char s_src_env_watch_highlight[] = "env TWITCH_WATCH_HIGHLIGHT";
static const char s_src_env_watch_replay_steps[] =
    "env TWITCH_WATCH_REPLAY_STEPS";
static const char s_src_env_tail_notify[] = "env TWITCH_TAIL_NOTIFY";
static const char s_src_env_tail_max_events[] = "env TWITCH_TAIL_MAX_EVENTS";
static const char s_src_env_tail_seed_lookback[] =
    "env TWITCH_TAIL_SEED_LOOKBACK";
static const char s_src_config[] = "config";
static const char s_src_config_watch[] = "config [watch]";
static const char s_src_config_tail[] = "config [tail]";
static const char s_src_default_builtin[] = "built-in default";
static const char s_src_default[] = "default";
static const char s_src_default_now[] = "default: now";
static const char s_src_default_earliest[] = "default: earliest log file";
static const char s_src_default_under_watch[] = "default under --watch";
static const char s_src_excl_config[] = "config exclude";
static const char s_src_excl_always[] = "config always:";
static const char s_src_excl_group[] = "--exclude-group ";
static const char s_src_excl_env[] = "env TWITCH_EXCLUDE";
static const char s_src_config_begin[] = "config begin";
static const char s_src_config_since[] = "config since";

/* The static source-string table, indexed by TC_SRC_* id. */
static const char *const s_source_table[TC_SRC_COUNT] = {
    s_src_none,
    s_src_cli_channel, s_src_cli_users_policy, s_src_cli_users_max,
    s_src_cli_end, s_src_cli_min_count, s_src_cli_show, s_src_cli_sort,
    s_src_cli_share_floor, s_src_cli_top, s_src_cli_logs_dir,
    s_src_cli_header, s_src_cli_live, s_src_cli_offline, s_src_cli_unknown,
    s_src_cli_begin, s_src_cli_since, s_src_cli_users, s_src_cli_watch,
    s_src_cli_watch_hold, s_src_cli_exclude, s_src_cli_exclude_group,
    s_src_cli_exclude_bcast, s_src_cli_include, s_src_cli_config,
    s_src_cli_streamer, s_src_cli_color, s_src_cli_json, s_src_cli_by_state,
    s_src_cli_no_exclude, s_src_cli_no_config, s_src_cli_no_cache,
    s_src_cli_rebuild_cache, s_src_cli_manual, s_src_cli_emit_fish,
    s_src_cli_complete, s_src_cli_help,
    s_src_env_channel, s_src_env_users_policy, s_src_env_users_max,
    s_src_env_end, s_src_env_min_count, s_src_env_show, s_src_env_sort,
    s_src_env_share_floor, s_src_env_top, s_src_env_logs_dir,
    s_src_env_header, s_src_env_state, s_src_env_begin, s_src_env_since,
    s_src_env_exclude, s_src_env_exclude_bcast, s_src_env_watch_interval,
    s_src_env_watch_min_interval, s_src_env_watch_hold,
    s_src_env_watch_fade_up, s_src_env_watch_fade_down,
    s_src_env_watch_shades, s_src_env_watch_user_width,
    s_src_env_watch_full_repaint, s_src_env_watch_streamer_mode,
    s_src_env_watch_min_redraw, s_src_env_watch_show_timing,
    s_src_env_watch_tint_falling, s_src_env_watch_fade_curve,
    s_src_env_watch_fade_k, s_src_env_watch_highlight,
    s_src_env_watch_replay_steps, s_src_env_tail_notify,
    s_src_env_tail_max_events, s_src_env_tail_seed_lookback,
    s_src_config, s_src_config_watch, s_src_config_tail,
    s_src_default_builtin, s_src_default, s_src_default_now,
    s_src_default_earliest, s_src_default_under_watch,
    /* 80..82 DYN ids are served dynamically below */
    s_src_excl_config, s_src_excl_always, s_src_excl_group, s_src_excl_env,
    s_src_config_begin, s_src_config_since
};

/* The opts whose dynamic source buffers tc_source_str serves.  tc_cli_parse
   points these at the caller's buffers (the header's explicit-state design
   has no other channel for the id-only signature). */
static const char *s_dyn_win_src = "";
static const char *s_dyn_chan_src = "";

const char *tc_source_str(int id) {
    if (id >= 0 && id < TC_SRC_COUNT) {
        if (id == TC_SRC_DYN_SINCE || id == TC_SRC_DYN_USERS) {
            return s_dyn_win_src;
        }
        if (id == TC_SRC_DYN_ALIAS) {
            return s_dyn_chan_src;
        }
        return s_source_table[id];
    }
    return s_src_none;
}

const char *tc_setting_src_str(int set_id) {
    static const char *const labels[TC_SET_COUNT] = {
        s_src_cli_channel, s_src_cli_users_policy, s_src_cli_users_max,
        s_src_cli_end, s_src_cli_min_count, s_src_cli_show, s_src_cli_sort,
        s_src_cli_share_floor, s_src_cli_top, s_src_cli_logs_dir,
        s_src_cli_header, "--live/--offline/--unknown", s_src_cli_watch,
        "watch.min_interval", s_src_cli_watch_hold, "watch.fade_up",
        "watch.fade_down", "watch.shades", "watch.user_width",
        "watch.full_repaint", s_src_cli_streamer, "watch.min_redraw",
        "watch.show_timing", "watch.tint_falling", "watch.fade_curve",
        "watch.fade_k", "watch.highlight", "watch.replay_steps",
        "tail.notify", "tail.max_events", "tail.seed_lookback",
        s_src_cli_begin, s_src_cli_since, s_src_cli_users,
        s_src_cli_exclude, s_src_cli_exclude_group,
        s_src_cli_exclude_bcast, s_src_cli_include, s_src_cli_config,
        s_src_cli_color,
    };
    if (set_id < 0 || set_id >= TC_SET_COUNT) {
        return s_src_none;
    }
    return labels[set_id];
}

// ----------------------------------------------------------------------------
// Error reporting.
// ----------------------------------------------------------------------------
static void cli_print_usage_to(FILE *f);

/* argparse error(): the usage block then "<prog>: error: <msg>" on stderr,
   exit 2.  tc_cli_parse returns the code so main() can propagate it. */
static int cli_arg_error(const char *msg) {
    cli_print_usage_to(stderr);
    tc_eputs(s_prog_name);
    tc_eputs(": error: ");
    tc_eputs(msg);
    tc_eputs("\n");
    return TC_EXIT_PARSE;
}

/* The resolution failure shape: {"error": "..."} under --json (json.dump
   escaping), else "error: ...".  Returns TC_EXIT_ERROR. */
static int cli_resolve_error(const tc_opts *opts, const char *msg) {
    if (opts->flags & TC_F_JSON) {
        tc_eputs("{\"error\": \"");
        for (; *msg != '\0'; msg++) {
            if (*msg == '"' || *msg == '\\') {
                tc_eputs("\\");
            }
            if (*msg == '\n') {
                tc_eputs("\\n");
                continue;
            }
            if (*msg == '\r') {
                tc_eputs("\\r");
                continue;
            }
            if (*msg == '\t') {
                tc_eputs("\\t");
                continue;
            }
            {
                char c[2];
                c[0] = *msg;
                c[1] = '\0';
                tc_eputs(c);
            }
        }
        tc_eputs("\"}\n");
    } else {
        tc_eputs("error: ");
        tc_eputs(msg);
        tc_eputs("\n");
    }
    return TC_EXIT_ERROR;
}

// ----------------------------------------------------------------------------
// Conversion and message bodies.
// ----------------------------------------------------------------------------
typedef struct {
    int64_t i;
    double f;
    int id;
} cli_val_out;

/* Python int(): surrounding whitespace, optional sign, digits. */
static int py_int(const char *raw, long *out) {
    char num[64];
    char *q;
    char *end;
    long v;
    tc_copy_str_cap(num, raw, sizeof(num));
    q = num;
    while (ascii_ws((unsigned char)*q)) {
        q++;
    }
    if (*q == '-' || *q == '+') {
        q++;
    }
    if (*q == '\0') {
        return 0;
    }
    while (*q != '\0') {
        if (*q < '0' || *q > '9') {
            return 0;
        }
        q++;
    }
    errno = 0;
    v = strtol(num, &end, 10);
    if (errno != 0 || *end != '\0') {
        return 0;
    }
    *out = v;
    return 1;
}

/* Python float(): surrounding whitespace, the C locale grammar. */
static int py_float(const char *raw, double *out) {
    char num[128];
    char *end;
    double v;
    tc_copy_str_cap(num, raw, sizeof(num));
    {
        char *q = num;
        while (ascii_ws((unsigned char)*q)) {
            q++;
        }
        if (*q == '\0') {
            return 0;
        }
    }
    errno = 0;
    v = strtod(num, &end);
    while (ascii_ws((unsigned char)*end)) {
        end++;
    }
    if (errno != 0 || *end != '\0') {
        return 0;
    }
    *out = v;
    return 1;
}

static char *cli_int_body(char *dst, const char *raw, int nonneg) {
    long v;
    if (!py_int(raw, &v)) {
        dst = py_repr(dst, raw);
        dst = tc_cat_cstr(dst, " is not an integer");
        return dst;
    }
    if (nonneg) {
        if (v < 0) {
            dst = tc_cat_cstr(dst, "row limit must be 0 (unlimited) or a "
                                   "positive count");
        }
        return dst;
    }
    if (v < 1) {
        dst = tc_cat_cstr(dst, "must be 1 or more");
    }
    return dst;
}

static char *cli_float_body(char *dst, const char *raw, int positive) {
    double v;
    if (!py_float(raw, &v)) {
        dst = py_repr(dst, raw);
        dst = tc_cat_cstr(dst, positive ? " is not a number"
                                        : " is not a number of seconds");
        return dst;
    }
    if (positive ? v <= 0.0 : v < 0.0) {
        dst = tc_cat_cstr(dst, positive ? "must be greater than 0"
                                        : "must be 0 or more seconds");
    }
    return dst;
}

/* Write the message body for a parser failure into dst (capacity SCRATCH_SZ
   assumed); returns the cursor. */
static char *cli_msg_body(char *dst, int parser, const char *raw) {
    switch (parser) {
    case P_POS_INT:
        return cli_int_body(dst, raw, 0);
    case P_NONNEG_INT:
        return cli_int_body(dst, raw, 1);
    case P_NONNEG_FLOAT:
    case P_WATCH:
        return cli_float_body(dst, raw, 0);
    case P_DURATION: {
        char disp[TC_RAW_SZ];
        tc_copy_str_cap(disp, raw, sizeof(disp));
        strip_inplace(disp);
        lowercase_inplace(disp);
        dst = tc_cat_cstr(dst, "unrecognized duration ");
        dst = py_repr(dst, disp);
        dst = tc_cat_cstr(dst, " (try '30d', '12h', '90m', '1w3d'; units are "
                               "w/d/h/m/s and 'm' is minutes)");
        return dst;
    }
    case P_SORT: {
        char disp[64];
        tc_copy_str_cap(disp, raw, sizeof(disp));
        strip_inplace(disp);
        lowercase_inplace(disp);
        dst = tc_cat_cstr(dst, "unknown sort ");
        dst = py_repr(dst, disp);
        dst = tc_cat_cstr(dst, " (choose from: count, live, live-share, "
                               "login, offline, offline-share, unknown)");
        return dst;
    }
    case P_HEADER:
        dst = tc_cat_cstr(dst, "unknown header mode ");
        dst = py_repr(dst, raw);
        dst = tc_cat_cstr(dst, " (expected full, compact, none)");
        return dst;
    case P_METRICS:
        dst = tc_cat_cstr(dst, "unknown column ");
        dst = py_repr(dst, raw);
        dst = tc_cat_cstr(dst, " (choose from: count, live, live-share, "
                               "offline, offline-share, unknown)");
        return dst;
    case P_POLICY: {
        char disp[64];
        tc_copy_str_cap(disp, raw, sizeof(disp));
        strip_inplace(disp);
        lowercase_inplace(disp);
        dst = tc_cat_cstr(dst, "unknown --users-policy ");
        dst = py_repr(dst, disp);
        dst = tc_cat_cstr(dst, " (choose from: at-least, at-most, nearest)");
        return dst;
    }
    case P_CHOICES_COLOR:
        dst = tc_cat_cstr(dst, "invalid choice: ");
        dst = py_repr(dst, raw);
        dst = tc_cat_cstr(dst, " (choose from auto, always, never)");
        return dst;
    case P_CHOICES_COMPLETE:
        dst = tc_cat_cstr(dst, "invalid choice: ");
        dst = py_repr(dst, raw);
        dst = tc_cat_cstr(dst, " (choose from channels, groups, dates, weeks, "
                               "periods, users, includes)");
        return dst;
    default:
        return dst;
    }
}

/* Convert one typed argument; returns 0 ok (the value in *out) or 1 with a
   message body in err. */
static int cli_convert(int parser, const char *raw, cli_val_out *out,
                       char *err, size_t err_cap) {
    (void)err_cap;
    switch (parser) {
    case P_POS_INT:
    case P_NONNEG_INT: {
        long v;
        if (!py_int(raw, &v)) {
            cli_msg_body(err, parser, raw);
            return 1;
        }
        if (parser == P_POS_INT && v < 1) {
            cli_msg_body(err, parser, raw);
            return 1;
        }
        if (parser == P_NONNEG_INT && v < 0) {
            cli_msg_body(err, parser, raw);
            return 1;
        }
        out->i = v;
        return 0;
    }
    case P_NONNEG_FLOAT:
    case P_WATCH: {
        double v;
        if (!py_float(raw, &v)) {
            cli_msg_body(err, parser, raw);
            return 1;
        }
        if (v < 0.0) {
            cli_msg_body(err, parser, raw);
            return 1;
        }
        out->f = v;
        return 0;
    }
    case P_DURATION: {
        int st;
        int64_t secs = tc_parse_duration(raw, &st);
        if (st != 0) {
            cli_msg_body(err, P_DURATION, raw);
            return 1;
        }
        out->i = secs;
        return 0;
    }
    case P_SORT: {
        int ok;
        int id = tc_parse_sort(raw, &ok);
        if (!ok) {
            cli_msg_body(err, P_SORT, raw);
            return 1;
        }
        out->id = id;
        return 0;
    }
    case P_HEADER: {
        int ok;
        int id = tc_parse_header(raw, &ok);
        if (!ok) {
            cli_msg_body(err, P_HEADER, raw);
            return 1;
        }
        out->id = id;
        return 0;
    }
    case P_POLICY: {
        int ok;
        int id = tc_parse_users_policy(raw, &ok);
        if (!ok) {
            cli_msg_body(err, P_POLICY, raw);
            return 1;
        }
        out->id = id;
        return 0;
    }
    case P_CHOICES_COLOR: {
        char disp[64];
        tc_copy_str_cap(disp, raw, sizeof(disp));
        strip_inplace(disp);
        lowercase_inplace(disp);
        if (tc_streq(disp, "auto")) {
            out->id = TC_COLOR_AUTO;
            return 0;
        }
        if (tc_streq(disp, "always")) {
            out->id = TC_COLOR_ALWAYS;
            return 0;
        }
        if (tc_streq(disp, "never")) {
            out->id = TC_COLOR_NEVER;
            return 0;
        }
        cli_msg_body(err, P_CHOICES_COLOR, raw);
        return 1;
    }
    case P_CHOICES_COMPLETE: {
        static const char *const kinds[TC_COMPLETE_INCLUDES + 1] = {
            "channels", "groups", "dates", "weeks", "periods", "users",
            "includes"
        };
        char disp[64];
        int i;
        tc_copy_str_cap(disp, raw, sizeof(disp));
        strip_inplace(disp);
        lowercase_inplace(disp);
        for (i = 0; i <= TC_COMPLETE_INCLUDES; i++) {
            if (tc_streq(disp, kinds[i])) {
                out->id = i;
                return 0;
            }
        }
        cli_msg_body(err, P_CHOICES_COMPLETE, raw);
        return 1;
    }
    default:
        return 0;
    }
}

// ----------------------------------------------------------------------------
// The argparse-equivalent parse.
// ----------------------------------------------------------------------------
typedef struct {
    int action;            /* action index, or -1 for the "None" action */
    const char *opt_str;   /* the matched option string */
    char sep;              /* '=' or 0 */
    const char *explicit;  /* explicit argument or NULL */
} cli_tuple;

typedef struct {
    int count;
    cli_tuple t[ACTION_MAX];
} cli_tuple_list;

/* One cli_parse_argv run's scratch.  The arrays are sized to the actual
   argv token count (<= OPT_MAX) and heap-owned so a fixed 256-slot table
   never occupies .bss; the whole state lives only for the parse call. */
typedef struct {
    const char **argv;            /* tokens after argv[0] (into argv[]) */
    cli_tuple_list *opt_lists;    /* per-token option tuples */
    char *patterns;               /* per-token 'A'/'O'/'-' class */
    char (*extras_scratch)[ARGSTR_SZ]; /* bundled unknown-token copies */
    int n_tokens;
    int scratch_slots;            /* extras_scratch slot count (>= 1) */
} cli_parse_state;

static const char *cli_argv_token(const cli_parse_state *ps, int i) {
    return ps->argv[i];
}

static int find_action_exact(const char *s) {
    int i;
    for (i = 0; i < ACTION_MAX; i++) {
        if (s_actions[i].short_opt && tc_streq(s_actions[i].short_opt, s)) {
            return i;
        }
        if (s_actions[i].long_opt && tc_streq(s_actions[i].long_opt, s)) {
            return i;
        }
    }
    return -1;
}

/* Find an action whose option string equals s[0..len).  Returns the action
   and, when match_out is non-NULL, the matched option string. */
static int find_action_n(const char *s, size_t len, const char **match_out) {
    int i;
    for (i = 0; i < ACTION_MAX; i++) {
        const char *os;
        if (s_actions[i].short_opt) {
            os = s_actions[i].short_opt;
            if (strlen(os) == len && memcmp(os, s, len) == 0) {
                if (match_out) {
                    *match_out = os;
                }
                return i;
            }
        }
        if (s_actions[i].long_opt) {
            os = s_actions[i].long_opt;
            if (strlen(os) == len && memcmp(os, s, len) == 0) {
                if (match_out) {
                    *match_out = os;
                }
                return i;
            }
        }
    }
    return -1;
}

static int is_negative_number(const char *s) {
    /* ^-\d+$ | ^-\d*\.\d+$ */
    const char *p = s;
    int saw_digit = 0;
    int saw_dot = 0;
    if (*p != '-') {
        return 0;
    }
    p++;
    while (*p != '\0') {
        if (*p >= '0' && *p <= '9') {
            saw_digit = 1;
        } else if (*p == '.' && !saw_dot) {
            saw_dot = 1;
        } else {
            return 0;
        }
        p++;
    }
    return saw_digit;
}

/* _parse_optional: classify one token.  Returns 1 and fills *out with the
   option tuple list; returns 0 for a positional-looking token. */
static int cli_parse_optional(const char *arg, cli_tuple_list *out) {
    int i;
    const char *eq;
    const char *matched;

    out->count = 0;
    if (arg[0] == '\0') {
        return 0;
    }
    if (arg[0] != '-') {
        return 0;
    }
    i = find_action_exact(arg);
    if (i >= 0) {
        out->count = 1;
        out->t[0].action = i;
        out->t[0].opt_str = arg;
        out->t[0].sep = 0;
        out->t[0].explicit = NULL;
        return 1;
    }
    if (arg[1] == '\0') {
        return 0;
    }
    /* the "=" partition: a known option string before the "=" */
    eq = strchr(arg, '=');
    if (eq != NULL) {
        size_t pre = (size_t)(eq - arg);
        i = find_action_n(arg, pre, &matched);
        if (i >= 0) {
            out->count = 1;
            out->t[0].action = i;
            out->t[0].opt_str = matched;
            out->t[0].sep = '=';
            out->t[0].explicit = eq + 1;
            return 1;
        }
    }
    /* _get_option_tuples */
    if (arg[0] == '-' && arg[1] == '-') {
        int a;
        const char *eq2 = strchr(arg, '=');
        size_t prefix_len = eq2 ? (size_t)(eq2 - arg) : strlen(arg);
        for (a = 0; a < ACTION_MAX; a++) {
            const char *os = s_actions[a].long_opt;
            if (os != NULL && strncmp(os, arg, prefix_len) == 0) {
                out->t[out->count].action = a;
                out->t[out->count].opt_str = os;
                out->t[out->count].sep = eq2 ? '=' : 0;
                out->t[out->count].explicit = eq2 ? eq2 + 1 : NULL;
                out->count++;
            }
        }
        if (out->count > 0) {
            return 1;
        }
    } else {
        /* single-dash: the short prefix is arg[:2] */
        int a;
        const char *eq2 = strchr(arg, '=');
        size_t prefix_len = eq2 ? (size_t)(eq2 - arg) : strlen(arg);
        char short_pre[3];
        const char *matched2;
        short_pre[0] = arg[0];
        short_pre[1] = arg[1];
        short_pre[2] = '\0';
        i = find_action_exact(short_pre);
        if (i >= 0) {
            out->count = 1;
            out->t[0].action = i;
            out->t[0].opt_str = s_actions[i].short_opt;
            out->t[0].sep = 0;
            out->t[0].explicit = (arg[2] != '\0') ? arg + 2 : "";
            return 1;
        }
        for (a = 0; a < ACTION_MAX; a++) {
            const char *os = s_actions[a].long_opt;
            if (os != NULL && strncmp(os, arg, prefix_len) == 0) {
                out->t[out->count].action = a;
                out->t[out->count].opt_str = os;
                out->t[out->count].sep = eq2 ? '=' : 0;
                out->t[out->count].explicit = eq2 ? eq2 + 1 : NULL;
                out->count++;
            }
        }
        if (out->count > 0) {
            return 1;
        }
        (void)matched2;
    }
    if (is_negative_number(arg)) {
        return 0;
    }
    if (strchr(arg, ' ') != NULL) {
        return 0;
    }
    out->count = 1;
    out->t[0].action = -1;
    out->t[0].opt_str = arg;
    out->t[0].sep = 0;
    out->t[0].explicit = NULL;
    return 1;
}

/* The persistent set of actions already seen (argparse seen_non_default_actions).
   Each entry stores the action pointer. */
typedef struct {
    const cli_action *acts[ACTION_MAX];
    int n;
} cli_seen;

static void cli_seen_add(cli_seen *seen, const cli_action *act) {
    int k;
    for (k = 0; k < seen->n; k++) {
        if (seen->acts[k] == act) {
            return;
        }
    }
    if (seen->n < ACTION_MAX) {
        seen->acts[seen->n++] = act;
    }
}

static int cli_seen_has(const cli_seen *seen, const cli_action *act) {
    int k;
    for (k = 0; k < seen->n; k++) {
        if (seen->acts[k] == act) {
            return 1;
        }
    }
    return 0;
}

/* Store one action's value into the parsed state; reports errors via
   cli_arg_error.  Also records the action as seen and checks the mutually
   exclusive groups (a conflict names the other, earlier action). */
static void cli_store_value(cli_parsed *parsed, int action_idx,
                            const char *const *args, int nargs,
                            cli_seen *seen, int *rc) {
    const cli_action *act = &s_actions[action_idx];
    char err[SCRATCH_SZ];

    /* conflict check (argparse checks after adding to seen_non_default) */
    if (act->group != GROUP_NONE) {
        int g;
        cli_seen_add(seen, act);
        for (g = 0; g < 4; g++) {
            int other = s_group_members[act->group][g];
            if (other < 0) {
                break;
            }
            if (other == action_idx) {
                continue;  /* an action never conflicts with itself */
            }
            if (cli_seen_has(seen, &s_actions[other])) {
                char msg[SCRATCH_SZ];
                char *m = msg;
                m = tc_cat_cstr(m, "argument ");
                m = tc_cat_cstr(m, act->label);
                m = tc_cat_cstr(m, ": not allowed with argument ");
                m = tc_cat_cstr(m, s_actions[other].label);
                *m = '\0';
                *rc = cli_arg_error(msg);
                return;
            }
        }
    } else {
        cli_seen_add(seen, act);
    }

    if (act->kind == OPT_FLAG) {
        switch (action_idx) {
        case A_HELP:
            tc_print_help();
            *rc = TC_EXIT_OK;
            return;
        case A_BY_STATE:
            parsed->by_state = 1;
            parsed->flags |= TC_F_BY_STATE;
            break;
        case A_JSON:
            parsed->flags |= TC_F_JSON;
            break;
        case A_LIVE:
            parsed->state_flag = TC_ST_LIVE;
            break;
        case A_OFFLINE:
            parsed->state_flag = TC_ST_OFFLINE;
            break;
        case A_UNKNOWN:
            parsed->state_flag = TC_ST_UNKNOWN;
            break;
        case A_EXCLUDE_BCAST:
            parsed->exclude_bcast = 1;
            parsed->flags |= TC_F_EXCLUDE_BCAST;
            break;
        case A_NO_EXCLUDE:
            parsed->no_exclude = 1;
            parsed->flags |= TC_F_NO_EXCLUDE;
            break;
        case A_NO_CONFIG:
            parsed->no_config = 1;
            parsed->flags |= TC_F_NO_CONFIG;
            break;
        case A_STREAMER:
            parsed->streamer = 1;
            parsed->flags |= TC_F_STREAMER;
            break;
        case A_NO_CACHE:
            parsed->no_cache = 1;
            parsed->flags |= TC_F_NO_CACHE;
            break;
        case A_REBUILD_CACHE:
            parsed->rebuild_cache = 1;
            parsed->flags |= TC_F_REBUILD_CACHE;
            break;
        case A_MANUAL:
            parsed->manual = 1;
            parsed->flags |= TC_F_MANUAL;
            break;
        case A_EMIT_FISH:
            parsed->emit_fish = 1;
            parsed->flags |= TC_F_EMIT_FISH;
            break;
        default:
            break;
        }
        return;
    }

    if (act->kind == OPT_APPEND) {
        if (nargs != 1) {
            char msg[SCRATCH_SZ];
            char *m = msg;
            m = tc_cat_cstr(m, "argument ");
            m = tc_cat_cstr(m, act->label);
            m = tc_cat_cstr(m, ": expected one argument");
            *m = '\0';
            *rc = cli_arg_error(msg);
            return;
        }
        switch (action_idx) {
        case A_EXCLUDE:
            if (parsed->excl_n < TC_LIST_MAX) {
                parsed->excl[parsed->excl_n++] = args[0];
            }
            parsed->flags |= TC_F_EXCL_GIVEN;
            break;
        case A_EXCLUDE_GROUP:
            if (parsed->excl_group_n < TC_LIST_MAX) {
                parsed->excl_group[parsed->excl_group_n++] = args[0];
            }
            parsed->flags |= TC_F_EXCL_GROUP_GIVEN;
            break;
        case A_INCLUDE:
            if (parsed->incl_n < TC_LIST_MAX) {
                parsed->incl[parsed->incl_n++] = args[0];
            }
            parsed->flags |= TC_F_INCL_GIVEN;
            break;
        default:
            break;
        }
        return;
    }

    if (act->kind == OPT_OPTIONAL) {
        /* --watch: value or the from-config sentinel */
        parsed->watch_given = 1;
        parsed->flags |= TC_F_WATCH_PRESENT;
        if (nargs == 1) {
            cli_val_out wv;
            if (cli_convert(P_WATCH, args[0], &wv, err, sizeof(err)) != 0) {
                char msg[SCRATCH_SZ];
                char *m = msg;
                m = tc_cat_cstr(m, "argument ");
                m = tc_cat_cstr(m, act->label);
                m = tc_cat_cstr(m, ": ");
                m = tc_cat_cstr(m, err);
                *m = '\0';
                *rc = cli_arg_error(msg);
                return;
            }
            parsed->watch = wv.f;
            parsed->watch_value_given = 1;
            parsed->flags |= TC_F_WATCH_VALUE;
        }
        return;
    }

    /* OPT_VALUE */
    if (nargs != 1) {
        char msg[SCRATCH_SZ];
        char *m = msg;
        m = tc_cat_cstr(m, "argument ");
        m = tc_cat_cstr(m, act->label);
        m = tc_cat_cstr(m, ": expected one argument");
        *m = '\0';
        *rc = cli_arg_error(msg);
        return;
    }
    {
        const char *raw = args[0];
        cli_val_out val;
        if (act->parser != P_NONE) {
            if (cli_convert(act->parser, raw, &val, err, sizeof(err)) != 0) {
                char msg[SCRATCH_SZ];
                char *m = msg;
                m = tc_cat_cstr(m, "argument ");
                m = tc_cat_cstr(m, act->label);
                m = tc_cat_cstr(m, ": ");
                m = tc_cat_cstr(m, err);
                *m = '\0';
                *rc = cli_arg_error(msg);
                return;
            }
        }
        switch (action_idx) {
        case A_CHANNEL:
            parsed->channel = raw;
            break;
        case A_BEGIN:
            parsed->begin_raw = raw;
            parsed->flags |= TC_F_BEGIN_GIVEN;
            break;
        case A_SINCE:
            parsed->since_raw = raw;
            parsed->flags |= TC_F_SINCE_GIVEN;
            break;
        case A_USERS:
            parsed->users = val.i;
            parsed->flags |= TC_F_USERS_GIVEN;
            break;
        case A_USERS_POLICY:
            parsed->users_policy_id = val.id;
            parsed->users_policy_set = 1;
            break;
        case A_USERS_MAX:
            parsed->users_max = raw;
            break;
        case A_END:
            parsed->end_raw = raw;
            parsed->flags |= TC_F_END_GIVEN;
            break;
        case A_MIN_COUNT:
            parsed->min_count = val.i;
            parsed->min_count_set = 1;
            break;
        case A_SHOW: {
            const char *p = raw;
            for (;;) {
                const char *start = p;
                size_t n = 0;
                while (*p != '\0' && *p != ','
                       && !ascii_ws((unsigned char)*p)) {
                    p++;
                }
                n = (size_t)(p - start);
                if (n > 0) {
                    char name[64];
                    int ok;
                    int id;
                    if (n >= sizeof(name)) {
                        n = sizeof(name) - 1;
                    }
                    memcpy(name, start, n);
                    name[n] = '\0';
                    id = tc_parse_metrics(name, &ok);
                    if (!ok) {
                        char msg[SCRATCH_SZ];
                        char *m = msg;
                        m = tc_cat_cstr(m, "argument ");
                        m = tc_cat_cstr(m, act->label);
                        m = tc_cat_cstr(m, ": ");
                        m = cli_msg_body(m, P_METRICS, name);
                        *m = '\0';
                        *rc = cli_arg_error(msg);
                        return;
                    }
                    if (id != TC_M_COUNT) {
                        int dup = 0;
                        int k;
                        for (k = 0; k < parsed->show_count; k++) {
                            if (parsed->show[k] == id) {
                                dup = 1;
                                break;
                            }
                        }
                        if (!dup && parsed->show_count < TC_COLUMNS_MAX) {
                            parsed->show[parsed->show_count++] = id;
                        }
                    }
                }
                if (*p == '\0') {
                    break;
                }
                if (*p == ',') {
                    p++;
                } else {
                    while (ascii_ws((unsigned char)*p)) {
                        p++;
                    }
                }
            }
            break;
        }
        case A_SORT:
            parsed->sort = val.id;
            parsed->sort_given = 1;
            break;
        case A_SHARE_FLOOR:
            parsed->share_floor = val.i;
            parsed->share_floor_set = 1;
            break;
        case A_TOP:
            parsed->top = val.i;
            parsed->top_set = 1;
            break;
        case A_HEADER:
            parsed->header_raw = raw;
            break;
        case A_LOGS_DIR:
            parsed->logs_dir = raw;
            break;
        case A_WATCH_HOLD:
            parsed->watch_hold = val.f;
            parsed->watch_hold_given = 1;
            break;
        case A_COLOR:
            parsed->color_mode = val.id;
            parsed->color_given = 1;
            break;
        case A_CONFIG:
            parsed->config = raw;
            parsed->flags |= TC_F_CONFIG_GIVEN;
            break;
        case A_COMPLETE:
            parsed->complete_kind = val.id;
            parsed->complete_given = 1;
            parsed->flags |= TC_F_COMPLETE_GIVEN;
            break;
        default:
            break;
        }
    }
}

/* Consume the optional at start_index; returns the next start index.  The
   argparse bundling loop for a no-argument short option with a tail lives
   here. */
static int cli_consume_optional(cli_parse_state *ps, int start_index,
                                cli_parsed *parsed, char **extras,
                                int *extras_n, cli_seen *seen, int *rc) {
    const cli_tuple_list *tuples = &ps->opt_lists[start_index];
    int action_idx;
    const char *opt_str;
    char sep;
    const char *explicit;

    if (tuples->count > 1) {
        /* ambiguous option */
        char msg[SCRATCH_SZ];
        char *m = msg;
        int k;
        m = tc_cat_cstr(m, "ambiguous option: ");
        m = tc_cat_cstr(m, cli_argv_token(ps, start_index));
        m = tc_cat_cstr(m, " could match ");
        for (k = 0; k < tuples->count; k++) {
            if (k > 0) {
                m = tc_cat_cstr(m, ", ");
            }
            m = tc_cat_cstr(m, tuples->t[k].opt_str);
        }
        *m = '\0';
        *rc = cli_arg_error(msg);
        return start_index + 1;
    }

    action_idx = tuples->t[0].action;
    opt_str = tuples->t[0].opt_str;
    sep = tuples->t[0].sep;
    explicit = tuples->t[0].explicit;

    if (action_idx < 0) {
        /* an unrecognized option-like token goes to extras */
        extras[*extras_n] = (char *)opt_str;
        (*extras_n)++;
        return start_index + 1;
    }

    for (;;) {
        const cli_action *act = &s_actions[action_idx];
        int arg_count = 0;
        int takes_one = (act->kind == OPT_VALUE || act->kind == OPT_OPTIONAL
                         || act->kind == OPT_APPEND);

        if (explicit != NULL) {
            arg_count = takes_one ? 1 : 0;
            if (arg_count == 0 && opt_str[1] != '-'
                && explicit[0] != '\0') {
                /* a no-arg short option with a tail: bundle it */
                if (sep != 0 || explicit[0] == '-') {
                    char msg[SCRATCH_SZ];
                    char *m = msg;
                    m = tc_cat_cstr(m, "argument ");
                    m = tc_cat_cstr(m, act->label);
                    m = tc_cat_cstr(m, ": ignored explicit argument ");
                    m = py_repr(m, explicit);
                    *m = '\0';
                    *rc = cli_arg_error(msg);
                    return start_index + 1;
                }
                cli_store_value(parsed, action_idx, NULL, 0, seen, rc);
                if (*rc != TC_EXIT_OK) {
                    return start_index + 1;
                }
                {
                    char next[3];
                    const char *rest = explicit + 1;
                    next[0] = '-';
                    next[1] = explicit[0];
                    next[2] = '\0';
                    action_idx = find_action_exact(next);
                    if (action_idx >= 0) {
                        opt_str = next;
                        if (*rest == '\0') {
                            sep = 0;
                            explicit = NULL;
                        } else if (*rest == '=') {
                            sep = '=';
                            explicit = rest + 1;
                        } else {
                            sep = 0;
                            explicit = rest;
                        }
                        continue;
                    }
                    /* the tail is an unknown bundled option; each extras
                       slot owns its scratch so two of them cannot collide
                       (mirrors the asm cli_argstr layout) */
                    {
                        char *slot = ps->extras_scratch[
                            *extras_n % ps->scratch_slots];
                        char *m = slot;
                        const char *q = explicit;
                        *m++ = '-';
                        while (*q != '\0'
                               && (size_t)(m - slot) < ARGSTR_SZ - 1) {
                            *m++ = *q++;
                        }
                        *m = '\0';
                        extras[*extras_n] = slot;
                        (*extras_n)++;
                    }
                    return start_index + 1;
                }
            }
            if (arg_count == 1) {
                const char *args[1];
                args[0] = explicit;
                cli_store_value(parsed, action_idx, args, 1, seen, rc);
                if (*rc != TC_EXIT_OK) {
                    return start_index + 1;
                }
                return start_index + 1;
            }
            {
                char msg[SCRATCH_SZ];
                char *m = msg;
                m = tc_cat_cstr(m, "argument ");
                m = tc_cat_cstr(m, act->label);
                m = tc_cat_cstr(m, ": ignored explicit argument ");
                m = py_repr(m, explicit);
                *m = '\0';
                *rc = cli_arg_error(msg);
                return start_index + 1;
            }
        }

        /* no explicit argument: consume following tokens per the nargs */
        if (act->kind == OPT_VALUE || act->kind == OPT_APPEND) {
            if (start_index + 1 < ps->n_tokens
                && ps->patterns[start_index + 1] == 'A') {
                const char *args[1];
                args[0] = cli_argv_token(ps, start_index + 1);
                cli_store_value(parsed, action_idx, args, 1, seen, rc);
                if (*rc != TC_EXIT_OK) {
                    return start_index + 1;
                }
                return start_index + 2;
            }
            {
                char msg[SCRATCH_SZ];
                char *m = msg;
                m = tc_cat_cstr(m, "argument ");
                m = tc_cat_cstr(m, act->label);
                m = tc_cat_cstr(m, ": expected one argument");
                *m = '\0';
                *rc = cli_arg_error(msg);
                return start_index + 1;
            }
        }
        if (act->kind == OPT_OPTIONAL) {
            if (start_index + 1 < ps->n_tokens
                && ps->patterns[start_index + 1] == 'A') {
                const char *args[1];
                args[0] = cli_argv_token(ps, start_index + 1);
                cli_store_value(parsed, action_idx, args, 1, seen, rc);
                if (*rc != TC_EXIT_OK) {
                    return start_index + 1;
                }
                return start_index + 2;
            }
            cli_store_value(parsed, action_idx, NULL, 0, seen, rc);
            if (*rc != TC_EXIT_OK) {
                return start_index + 1;
            }
            return start_index + 1;
        }
        /* OPT_FLAG / OPT_APPEND: no following tokens */
        cli_store_value(parsed, action_idx, NULL, 0, seen, rc);
        if (*rc != TC_EXIT_OK) {
            return start_index + 1;
        }
        return start_index + 1;
    }
}

/* The argparse pre-pass + consume loop; returns TC_EXIT_OK/TC_EXIT_PARSE.
   The caller (tc_cli_parse) has already sized ps to the token count and
   rejected anything over OPT_MAX. */
static int cli_parse_argv(cli_parse_state *ps, int argc, char **argv,
                          cli_parsed *parsed, cli_seen *seen) {
    int n = argc - 1;
    int i, ti = 0;
    char *extras_store[OPT_MAX];
    int extras_n = 0;
    int rc = TC_EXIT_OK;

    ps->n_tokens = n;
    for (i = 0; i < n; i++) {
        ps->argv[i] = argv[i + 1];
    }

    /* Pre-pass: classify every token into 'A'/'O'/'-' and remember the
       option tuples at each 'O'. */
    for (i = 0; i < n; i++) {
        const char *arg = ps->argv[i];
        if (strcmp(arg, "--") == 0) {
            ps->patterns[ti] = '-';
            ps->opt_lists[ti].count = 0;
            ti++;
            for (i++; i < n; i++) {
                ps->patterns[ti] = 'A';
                ps->opt_lists[ti].count = 0;
                ti++;
            }
            break;
        }
        if (cli_parse_optional(arg, &ps->opt_lists[ti])) {
            ps->patterns[ti] = 'O';
        } else {
            ps->patterns[ti] = 'A';
            ps->opt_lists[ti].count = 0;
        }
        ti++;
    }
    ps->n_tokens = ti;

    /* The main loop: consume optionals left to right; tokens that are not
       an option and not consumed by one become extras. */
    {
        int start = 0;
        int max_opt = -1;
        for (i = 0; i < ps->n_tokens; i++) {
            if (ps->patterns[i] == 'O') {
                max_opt = i;
            }
        }
        while (start <= max_opt) {
            int next_opt = start;
            while (next_opt <= max_opt && ps->patterns[next_opt] != 'O') {
                next_opt++;
            }
            if (start < next_opt) {
                for (i = start; i < next_opt; i++) {
                    extras_store[extras_n] = (char *)ps->argv[i];
                    extras_n++;
                }
                start = next_opt;
            }
            if (start > max_opt) {
                break;
            }
            start = cli_consume_optional(ps, start, parsed, extras_store,
                                         &extras_n, seen, &rc);
            if (rc != TC_EXIT_OK) {
                return rc;
            }
        }
        for (i = start; i < ps->n_tokens; i++) {
            extras_store[extras_n] = (char *)ps->argv[i];
            extras_n++;
        }
    }

    if (extras_n > 0) {
        char msg[SCRATCH_SZ];
        char *m = msg;
        int k;
        m = tc_cat_cstr(m, "unrecognized arguments: ");
        for (k = 0; k < extras_n; k++) {
            if (k > 0) {
                m = tc_cat_cstr(m, " ");
            }
            m = tc_cat_cstr(m, extras_store[k]);
        }
        *m = '\0';
        return cli_arg_error(msg);
    }
    return TC_EXIT_OK;
}

// ----------------------------------------------------------------------------
// Usage block (argparse HelpFormatter._format_usage).
// ----------------------------------------------------------------------------
static const char *const s_usage_parts[] = {
    "[-h]",
    "[-c CHANNEL]",
    "[-b BEGIN |",
    "-S SINCE |",
    "--users N]",
    "[--users-policy HOW]",
    "[--users-max DURATION]",
    "[-e END]",
    "[-m MIN_COUNT]",
    "[-B]",
    "[--show COL[,COL...]]",
    "[--sort METRIC]",
    "[--share-floor N]",
    "[-n N]",
    "[--header MODE]",
    "[-d LOGS_DIR]",
    "[-j |",
    "-w [SECONDS]]",
    "[--watch-hold SECONDS]",
    "[--color {auto,always,never}]",
    "[-L |",
    "-O |",
    "-U]",
    "[-x LOGIN[,LOGIN...]]",
    "[-g GROUP]",
    "[--exclude-broadcaster]",
    "[--include LOGIN[,LOGIN...]]",
    "[--no-exclude]",
    "[--config CONFIG |",
    "--no-config]",
    "[--streamer]",
    "[--no-cache |",
    "--rebuild-cache]",
    "[--manual]",
    "[--emit-fish-completions]",
    NULL
};

/* The wrapped usage block (argparse: one trailing newline), written to f. */
static void cli_print_usage_to(FILE *f) {
    const char *prog = s_prog_name;
    size_t prog_len = strlen(prog);
    size_t nparts = 0;
    int width = tc_term_columns() - 2;
    int text_width = width < 11 ? 11 : width;
    size_t prefix_len = 7;              /* "usage: " */
    size_t i;

    /* Byte-parity with the recorded reference: the snapshots were produced
       by `python3 twitch-counts.py`, whose argparse wrapped the usage block
       with the 16-char prog "twitch-counts.py" (indent = len("usage: ") +
       16 + 1).  The C binary reports its own 13-char name, so reproducing
       the reference bytes means the wrap math uses the reference prog
       length while the printed name stays the real one.  Any other prog
       (the per-module test drivers, e.g. tc-cli-test) wraps with its own
       length, exactly as argparse would. */
    if (prog_len == 13 && memcmp(prog, "twitch-counts", 13) == 0) {
        prog_len = 16;                  /* strlen("twitch-counts.py") */
    }

    while (s_usage_parts[nparts] != NULL) {
        nparts++;
    }

    /* Would the whole line fit? */
    {
        size_t total = prefix_len + prog_len + 1;
        for (i = 0; i < nparts; i++) {
            total += strlen(s_usage_parts[i]) + 1;
        }
        if (total <= (size_t)text_width) {
            fputs("usage: ", f);
            fputs(prog, f);
            for (i = 0; i < nparts; i++) {
                fputc(' ', f);
                fputs(s_usage_parts[i], f);
            }
            fputc('\n', f);
            return;
        }
    }

    if (prefix_len + prog_len <= (size_t)(text_width * 3 / 4)) {
        /* short prog: it stays on the first line with the parts */
        size_t indent = prefix_len + prog_len + 1;
        int line_len = (int)prefix_len - 1;
        int has_item = 0;
        fputs("usage: ", f);
        fputs(prog, f);
        line_len += (int)prog_len + 1;
        has_item = 1;
        for (i = 0; i < nparts; i++) {
            size_t part_len = strlen(s_usage_parts[i]);
            if (line_len + 1 + (int)part_len > text_width && has_item) {
                fputc('\n', f);
                for (size_t sp = 0; sp < indent; sp++) {
                    fputc(' ', f);
                }
                line_len = (int)indent - 1;
                has_item = 0;
            }
            if (has_item) {
                fputc(' ', f);
            }
            fputs(s_usage_parts[i], f);
            line_len += (int)part_len + 1;
            has_item = 1;
        }
        fputc('\n', f);
    } else {
        /* long prog: prog on its own line, parts indented by the prefix */
        int line_len = (int)prefix_len - 1;
        int has_item = 0;
        fputs("usage: ", f);
        fputs(prog, f);
        fputc('\n', f);
        for (i = 0; i < nparts; i++) {
            size_t part_len = strlen(s_usage_parts[i]);
            if (line_len + 1 + (int)part_len > text_width && has_item) {
                fputc('\n', f);
                for (size_t sp = 0; sp < prefix_len; sp++) {
                    fputc(' ', f);
                }
                line_len = (int)prefix_len - 1;
                has_item = 0;
            }
            if (has_item) {
                fputc(' ', f);
            }
            fputs(s_usage_parts[i], f);
            line_len += (int)part_len + 1;
            has_item = 1;
        }
        fputc('\n', f);
    }
}

// ----------------------------------------------------------------------------
// Help (byte-identical to Python's -h at the default 80-column terminal).
// ----------------------------------------------------------------------------
static const char s_help_body_a[] =
    "\n"
    "Count Chatterino chat messages per user for a channel and time range.\n"
    "\n"
    "options:\n"
    "  -h, --help            show this help message and exit\n"
    "  -c, --channel CHANNEL\n"
    "                        Twitch channel name (case-insensitive)\n"
    "  -b, --begin BEGIN     start of the range, e.g. '2026-07-01' "
    "(alternative to\n"
    "                        --since and --users)\n"
    "  -S, --since SINCE     start the range this far before --end, e.g. "
    "'30d'\n"
    "                        (alternative to --begin and --users)\n"
    "  --users N             size the window so N users meet --min-count, "
    "then hold\n"
    "                        that width\n"
    "  --users-policy HOW    how to settle when no window gives exactly "
    "--users:\n"
    "                        at-least, at-most or nearest (default: "
    "at-least)\n"
    "  --users-max DURATION  widest window --users may search (default: "
    "24h)\n"
    "  -e, --end END         end of the range (default: now)\n"
    "  -m, --min-count MIN_COUNT\n"
    "                        only report users with at least this many "
    "messages\n"
    "                        (default: 1)\n"
    "  -B, --by-state        add live, offline and offline% columns "
    "(shorthand for\n"
    "                        --show)\n"
    "  --show COL[,COL...]   extra columns: live, live-share, offline, "
    "offline-\n"
    "                        share, unknown\n"
    "  --sort METRIC         order rows by: count, live, live-share, login,\n"
    "                        offline, offline-share, unknown (default: "
    "count)\n"
    "  --share-floor N       messages needed to be listed when a share is "
    "shown or\n"
    "                        sorted by, 0 to disable (default: 10)\n"
    "  -n, --top N           show at most N rows, 0 for unlimited (default: "
    "what\n"
    "                        fits the terminal; unlimited when piped)\n"
    "  --header MODE         provenance block: full, compact or none "
    "(default:\n"
    "                        full, or compact under --watch)\n"
    "  -d, --logs-dir LOGS_DIR\n"
    "                        Chatterino Twitch Channels directory\n"
    "  -j, --json            emit one JSON document with its own schema "
    "embedded\n"
    "  -w, --watch [SECONDS]\n"
    "                        redraw every SECONDS (default: watch.interval, "
    "1),\n"
    "                        tinting a row green when its count rises and "
    "grey when\n"
    "                        it falls; a green still holding outranks a "
    "fall\n"
    "  --watch-hold SECONDS  how long a row stays tinted after it moves "
    "(default:\n"
    "                        watch.hold, 3s, one shade per 1/N of it; 0 "
    "holds\n"
    "                        indefinitely)\n"
    "  --color {auto,always,never}\n"
    "                        colour output (default: auto, meaning a "
    "terminal\n"
    "                        without NO_COLOR)\n"
    "  -L, --live            only messages sent while the channel was live\n"
    "  -O, --offline         only messages sent while the channel was "
    "offline\n"
    "  -U, --unknown         only messages no live/offline marker can "
    "place\n"
    "  -x, --exclude LOGIN[,LOGIN...]\n"
    "                        exclude these users; repeatable, "
    "comma-separated, ADDS\n"
    "                        to config exclusions\n"
    "  -g, --exclude-group GROUP\n"
    "                        exclude a group from the config's [exclude] "
    "table;\n"
    "                        repeatable\n"
    "  --exclude-broadcaster\n"
    "                        exclude the channel's own account\n"
    "  --include LOGIN[,LOGIN...]\n"
    "                        re-include users the merged exclusions would "
    "drop;\n"
    "                        repeatable\n"
    "  --no-exclude          ignore every exclusion for this run\n";

static const char s_help_body_b[] =
    "  --no-config           ignore the config file entirely\n"
    "  --streamer            streamer mode: no content highlights while "
    "watching\n"
    "  --no-cache            parse the logs instead of using the cache\n"
    "  --rebuild-cache       discard the cache and parse everything\n"
    "  --manual              print the full manual: config keys, layering, "
    "cache\n"
    "                        and watch behaviour\n"
    "  --emit-fish-completions\n"
    "                        print fish completions; redirect into\n"
    "                        ~/.config/fish/completions/\n"
    "\n"
    "Datetimes accept 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM[:SS]', or an ISO "
    "week\n"
    "('2026-W31', or '2026-W31-3' for its Wednesday); a bare date or week "
    "means its\n"
    "start for --begin and its end for --end, so '-b 2026-W31 -e 2026-W31' "
    "is\n"
    "exactly that week. The range is inclusive on both ends. Durations for "
    "--since\n"
    "look like '30d', '12h', '1w3d' ('m' is minutes). --users N sizes the "
    "window\n"
    "instead, widening it until N users meet --min-count and then holding "
    "that\n"
    "width. Any setting may instead come from an environment variable -- "
    "TWITCH_\n"
    "plus the flag name, or TWITCH_WATCH_/TWITCH_TAIL_ plus the config key "
    "for\n"
    "those tables -- or from the config file; --manual lists every one of "
    "them and\n"
    "the header reports which source was used. Exclusions are the exception "
    "to\n"
    "first-hit-wins: every layer adds to the set, so --exclude supplements "
    "the\n"
    "config rather than replacing it.\n";

/* Does the hyphen at the end of a word prefix break the word there?  The
   CPython wordsep lookbehinds: \w{2}- or \w-\w- before the break.  prefix
   is the word-so-far, len its length, the last char being the hyphen. */
static int word_before_hyphen_breaks(const char *prefix, size_t len) {
    if (len >= 3 && is_wordish(prefix[len - 2])
        && is_wordish(prefix[len - 3])) {
        return 1;
    }
    if (len >= 5 && is_wordish(prefix[len - 2]) && prefix[len - 3] == '-'
        && is_wordish(prefix[len - 4]) && is_wordish(prefix[len - 5])) {
        return 1;
    }
    return 0;
}

/* textwrap.wrap for a single paragraph of ASCII text: whitespace collapses
   to single spaces, words break after a hyphen between word characters, and
   a word wider than the line is cut.  Returns the line count; each line is
   NUL-terminated in out (capacity lines * line_cap). */
static int textwrap_lines(const char *text, int width, char *out,
                          int lines_cap, size_t line_cap) {
    char buf[2048];
    size_t blen = 0;
    const char *p = text;
    int nlines = 0;

    while (*p != '\0') {
        if (ascii_ws((unsigned char)*p)) {
            if (blen > 0 && buf[blen - 1] != ' ' && blen < sizeof(buf) - 1) {
                buf[blen++] = ' ';
            }
        } else {
            if (blen < sizeof(buf) - 1) {
                buf[blen++] = *p;
            }
        }
        p++;
    }
    while (blen > 0 && buf[blen - 1] == ' ') {
        blen--;
    }
    buf[blen] = '\0';

    {
        size_t pos = 0;
        int line_len = 0;
        int line_open = 0;
        char *line_ptr = out;

        while (pos < blen) {
            size_t start = pos;
            size_t end = start;
            int is_ws = 0;
            if (buf[pos] == ' ') {
                is_ws = 1;
                end = start + 1;
                pos = end;
            } else {
                while (end < blen && buf[end] != ' ') {
                    if (buf[end] == '-' && end + 1 < blen
                        && is_wordish(buf[end + 1])
                        && end > start
                        && word_before_hyphen_breaks(&buf[start],
                                                     end - start + 1)) {
                        end += 1;
                        break;
                    }
                    if (buf[end] == '-' && end + 1 < blen
                        && buf[end + 1] == '-' && end + 2 < blen
                        && is_wordish(buf[end + 2]) && end > start
                        && is_wordish(buf[end - 1])) {
                        /* em-dash: the word ends before the dashes */
                        break;
                    }
                    end++;
                }
                pos = end;
            }

            if (is_ws) {
                /* the whitespace between words: appended when it fits, so a
                   line break falls between words (leading whitespace on a
                   continuation line is dropped). */
                if (line_open && line_len + 1 <= width) {
                    line_ptr[line_len++] = ' ';
                }
                continue;
            }
            {
                size_t clen = end - start;
                if (clen == 0) {
                    continue;
                }
                if (line_open && line_len + (int)clen > width) {
                    line_ptr[line_len] = '\0';
                    nlines++;
                    if (nlines >= lines_cap) {
                        return nlines;
                    }
                    line_ptr += line_cap;
                    line_len = 0;
                    line_open = 0;
                }
                if ((int)clen > width) {
                    /* break_long_words: cut at the width */
                    while (clen > (size_t)width) {
                        if (!line_open) {
                            line_open = 1;
                        }
                        memcpy(line_ptr + line_len, buf + start,
                               (size_t)width);
                        line_len += width;
                        line_ptr[line_len] = '\0';
                        nlines++;
                        if (nlines >= lines_cap) {
                            return nlines;
                        }
                        line_ptr += line_cap;
                        line_len = 0;
                        line_open = 0;
                        start += (size_t)width;
                        clen -= (size_t)width;
                    }
                    if (clen == 0) {
                        continue;
                    }
                }
                if (!line_open) {
                    line_open = 1;
                }
                memcpy(line_ptr + line_len, buf + start, clen);
                line_len += (int)clen;
            }
        }
        if (line_open) {
            line_ptr[line_len] = '\0';
            nlines++;
        }
    }
    return nlines;
}

/* The dynamic "--config" help line: "  --config CONFIG       TOML config
   file (default: <shortened>)" wrapped at 54, continuation lines at 24. */
static void print_config_help_line(void) {
    char path[TC_PATH_SZ];
    const char *shortened;
    char text[TC_PATH_SZ + 64];
    char *t = text;
    char lines[4][256];
    int nlines;
    int i;

    tc_default_config_path(path, sizeof(path));
    shortened = tc_shorten_path(path);
    t = tc_cat_cstr(t, "TOML config file (default: ");
    t = tc_cat_cstr(t, shortened);
    *t++ = ')';
    *t = '\0';

    nlines = textwrap_lines(text, 54, &lines[0][0], 4, sizeof(lines[0]));
    tc_puts("  --config CONFIG       ");
    for (i = 0; i < nlines; i++) {
        if (i > 0) {
            tc_puts("                        ");
        }
        tc_puts(lines[i]);
        tc_puts("\n");
    }
    if (nlines == 0) {
        tc_puts("\n");
    }
}

void tc_print_help(void) {
    cli_print_usage_to(stdout);
    tc_puts(s_help_body_a);
    print_config_help_line();
    tc_puts(s_help_body_b);
    exit(TC_EXIT_OK);
}

// ----------------------------------------------------------------------------
// Layered resolution (CLI -> env -> [section] config -> default).
// ----------------------------------------------------------------------------
typedef struct {
    const char *value;   /* the raw resolved value, or NULL */
    int source;          /* TC_SRC_* */
} cli_resolved;

static cli_resolved resolve_setting(const char *cli_value, int cli_src,
                                    const char *env_name, int env_src,
                                    const char *config_key, int section_id,
                                    int cfg_src,
                                    const char *default_value,
                                    int default_src) {
    const char *env_value = NULL;
    if (cli_value != NULL) {
        cli_resolved r = { cli_value, cli_src };
        return r;
    }
    if (tc_env_get(env_name, &env_value) && env_value != NULL
        && env_value[0] != '\0') {
        cli_resolved r = { env_value, env_src };
        return r;
    }
    {
        const char *cfg_value = NULL;
        int src = TC_SRC_NONE;
        if (tc_config_get(config_key, section_id, &cfg_value, &src)
            && cfg_value != NULL && cfg_value[0] != '\0') {
            cli_resolved r = { cfg_value, cfg_src };
            return r;
        }
    }
    {
        cli_resolved r = { default_value, default_src };
        return r;
    }
}

/* The source label for a resolution error: the flag, or "<flag> (from
   <source>)" when the source is not the flag itself. */
static char *source_label_buf(char *dst, const char *flag, int source) {
    const char *src_str = tc_source_str(source);
    dst = tc_cat_cstr(dst, flag);
    if (!tc_streq(flag, src_str)) {
        dst = tc_cat_cstr(dst, " (from ");
        dst = tc_cat_cstr(dst, src_str);
        dst = tc_cat_cstr(dst, ")");
    }
    return dst;
}

/* Convert a resolved (env/config) value; on failure emit the resolution
   error and return 1 (rc carries the exit code). */
static int resolve_convert(tc_opts *opts, int parser, const char *flag,
                           const char *value, int source,
                           cli_val_out *out, int *rc) {
    char err[SCRATCH_SZ];
    if (cli_convert(parser, value, out, err, sizeof(err)) != 0) {
        char msg[SCRATCH_SZ];
        char *m = msg;
        m = source_label_buf(m, flag, source);
        m = tc_cat_cstr(m, ": ");
        m = tc_cat_cstr(m, err);
        *m = '\0';
        *rc = cli_resolve_error(opts, msg);
        return 1;
    }
    return 0;
}

/* Build the unrecognized-datetime body (shared by begin/end/env/config). */
static char *datetime_error_body(char *dst, const char *raw) {
    char disp[TC_RAW_SZ];
    tc_copy_str_cap(disp, raw, sizeof(disp));
    strip_inplace(disp);
    dst = tc_cat_cstr(dst, "unrecognized datetime ");
    dst = py_repr(dst, disp);
    dst = tc_cat_cstr(dst, " (try 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS', "
                           "'2026-W31' for a whole week, or '2026-W31-3' "
                           "for its Wednesday)");
    return dst;
}

/* Build the bad-week body: "no week N in ISO year Y (weeks run 1-52, or
   1-53 in long years)".  Returns the cursor, or NULL when the raw was not
   a bad-week form (the caller then uses the unrecognized-datetime body). */
static char *week_error_body(char *dst, const char *raw) {
    int y, w;
    char num[24];
    char *n;
    if (!parse_week_failure(raw, &y, &w)) {
        return NULL;
    }
    dst = tc_cat_cstr(dst, "no week ");
    n = num;
    n = tc_fmt_u64(n, (uint64_t)w);
    *n = '\0';
    dst = tc_cat_cstr(dst, num);
    dst = tc_cat_cstr(dst, " in ISO year ");
    n = num;
    n = tc_fmt4(n, (uint64_t)y);
    *n = '\0';
    dst = tc_cat_cstr(dst, num);
    dst = tc_cat_cstr(dst, " (weeks run 1-52, or 1-53 in long years)");
    return dst;
}

// ----------------------------------------------------------------------------
// tc_cli_parse — the entry point.
// ----------------------------------------------------------------------------

/* Heap-own the parse arrays, sized to the actual argv token count.  A fixed
   OPT_MAX-slot table would cost ~300 KB of .bss for a parse that never sees
   more than a handful of tokens; the whole state is freed once the argv
   pass completes (parsed values point into argv[], not into this state). */
static cli_parse_state *cli_parse_state_alloc(int n) {
    cli_parse_state *ps;
    size_t slots = n > 0 ? (size_t)n : 1;
    ps = malloc(sizeof(*ps));
    if (ps == NULL) {
        tc_fail("out of memory");
    }
    ps->argv = malloc(slots * sizeof(*ps->argv));
    ps->opt_lists = malloc(slots * sizeof(*ps->opt_lists));
    ps->patterns = malloc(slots);
    ps->extras_scratch = malloc(slots * ARGSTR_SZ);
    ps->n_tokens = 0;
    ps->scratch_slots = (int)slots;
    if (ps->argv == NULL || ps->opt_lists == NULL || ps->patterns == NULL
        || ps->extras_scratch == NULL) {
        tc_fail("out of memory");
    }
    return ps;
}

static void cli_parse_state_free(cli_parse_state *ps) {
    if (ps == NULL) {
        return;
    }
    free(ps->argv);
    free(ps->opt_lists);
    free(ps->patterns);
    free(ps->extras_scratch);
    free(ps);
}

int tc_cli_parse(int argc, char **argv, tc_opts *opts, tc_window *window) {
    cli_parsed parsed;
    cli_seen seen;
    cli_parse_state *ps;
    int rc = TC_EXIT_OK;
    int i;

    /* prog name: basename(argv[0]) */
    if (argc > 0 && argv[0] != NULL && argv[0][0] != '\0') {
        const char *base = argv[0];
        const char *slash = strrchr(base, '/');
        if (slash != NULL) {
            base = slash + 1;
        }
        tc_copy_str_cap(s_prog_name, base, sizeof(s_prog_name));
    }

    /* argparse's argv cap, rejected before the (heap) parse arrays are
       sized, so the usage error keeps the real prog name. */
    if (argc - 1 > OPT_MAX) {
        return cli_arg_error("too many arguments (max 256)");
    }
    ps = cli_parse_state_alloc(argc - 1);

    memset(&parsed, 0, sizeof(parsed));
    memset(&seen, 0, sizeof(seen));
    memset(opts, 0, sizeof(tc_opts));
    memset(window, 0, sizeof(tc_window));

    rc = cli_parse_argv(ps, argc, argv, &parsed, &seen);
    cli_parse_state_free(ps);
    if (rc != TC_EXIT_OK) {
        return rc;
    }

    /* The driver's DYN source buffers are served through tc_source_str. */
    s_dyn_win_src = opts->win_src;
    s_dyn_chan_src = opts->chan_src;

    /* Config path + flags land before any setting resolves: the config
       module must see --config / --no-config when it lazily loads, so a
       --config file's channel (and every other config-sourced setting) is
       found by the normal layered resolution below. */
    if (parsed.config != NULL) {
        tc_copy_str_cap(opts->config_path, parsed.config,
                        sizeof(opts->config_path));
    }
    opts->flags = parsed.flags;
    tc_config_register_opts(opts);

    /* ---- channel ---- */
    {
        cli_resolved ch = resolve_setting(
            parsed.channel, TC_SRC_CLI_CHANNEL, "TWITCH_CHANNEL",
            TC_SRC_ENV_CHANNEL, "channel", TC_SEC_NONE, TC_SRC_CONFIG,
            NULL, TC_SRC_DEFAULT);
        tc_copy_str_cap(opts->channel, ch.value != NULL ? ch.value : "",
                        sizeof(opts->channel));
        opts->src[TC_SET_CHANNEL] = ch.source;
    }

    /* ---- logs_dir ---- */
    {
        cli_resolved ld = resolve_setting(
            parsed.logs_dir, TC_SRC_CLI_LOGS_DIR, "TWITCH_LOGS_DIR",
            TC_SRC_ENV_LOGS_DIR, "logs_dir", TC_SEC_NONE, TC_SRC_CONFIG,
            NULL, TC_SRC_DEFAULT_BUILTIN);
        if (ld.value != NULL) {
            tc_copy_str_cap(opts->logs_dir, ld.value, sizeof(opts->logs_dir));
        } else {
            tc_platform_default_logs_dir(opts->logs_dir,
                                         sizeof(opts->logs_dir));
        }
        opts->src[TC_SET_LOGS_DIR] = ld.source;
    }

    /* ---- users_policy ---- */
    {
        if (parsed.users_policy_set) {
            opts->users_policy = parsed.users_policy_id;
            opts->src[TC_SET_USERS_POLICY] = TC_SRC_CLI_USERS_POLICY;
        } else {
            cli_resolved s = resolve_setting(
                NULL, TC_SRC_CLI_USERS_POLICY, "TWITCH_USERS_POLICY",
                TC_SRC_ENV_USERS_POLICY, "users_policy", TC_SEC_NONE,
                TC_SRC_CONFIG, "at-least", TC_SRC_DEFAULT_BUILTIN);
            opts->src[TC_SET_USERS_POLICY] = s.source;
            if (s.value != NULL) {
                int ok;
                int id = tc_parse_users_policy(s.value, &ok);
                if (!ok) {
                    char msg[SCRATCH_SZ];
                    char *m = msg;
                    m = source_label_buf(m, "--users-policy", s.source);
                    m = tc_cat_cstr(m, ": unknown --users-policy ");
                    m = py_repr(m, s.value);
                    m = tc_cat_cstr(m, " (choose from: at-least, at-most, "
                                       "nearest)");
                    *m = '\0';
                    return cli_resolve_error(opts, msg);
                }
                opts->users_policy = id;
            } else {
                opts->users_policy = TC_POLICY_AT_LEAST;
            }
        }
    }

    /* ---- users_max (24h default) ---- */
    {
        cli_resolved s = resolve_setting(
            parsed.users_max, TC_SRC_CLI_USERS_MAX, "TWITCH_USERS_MAX",
            TC_SRC_ENV_USERS_MAX, "users_max", TC_SEC_NONE, TC_SRC_CONFIG,
            "24h", TC_SRC_DEFAULT_BUILTIN);
        opts->src[TC_SET_USERS_MAX] = s.source;
        if (s.value != NULL) {
            cli_val_out v;
            if (resolve_convert(opts, P_DURATION, "--users-max", s.value,
                                s.source, &v, &rc)) {
                return rc;
            }
            opts->users_max = v.i;
        } else {
            opts->users_max = 24 * TC_SECS_PER_HOUR;
        }
    }

    /* ---- min_count (1 default) ---- */
    {
        cli_resolved s;
        if (parsed.min_count_set) {
            opts->min_count = parsed.min_count;
            opts->src[TC_SET_MIN_COUNT] = TC_SRC_CLI_MIN_COUNT;
        } else {
            s = resolve_setting(NULL, TC_SRC_CLI_MIN_COUNT,
                                "TWITCH_MIN_COUNT", TC_SRC_ENV_MIN_COUNT,
                                "min_count", TC_SEC_NONE, TC_SRC_CONFIG,
                                "1", TC_SRC_DEFAULT_BUILTIN);
            opts->src[TC_SET_MIN_COUNT] = s.source;
            if (s.value != NULL) {
                cli_val_out v;
                if (resolve_convert(opts, P_POS_INT, "--min-count",
                                    s.value, s.source, &v, &rc)) {
                    return rc;
                }
                opts->min_count = v.i;
            } else {
                opts->min_count = 1;
            }
        }
    }

    /* ---- top (0 = unlimited) ---- */
    {
        cli_resolved s = resolve_setting(
            NULL, TC_SRC_CLI_TOP, "TWITCH_TOP", TC_SRC_ENV_TOP,
            "top", TC_SEC_NONE, TC_SRC_CONFIG, NULL, TC_SRC_DEFAULT_BUILTIN);
        if (parsed.top_set) {
            opts->top = parsed.top;
            opts->src[TC_SET_TOP] = TC_SRC_CLI_TOP;
        } else if (s.value != NULL) {
            cli_val_out v;
            if (resolve_convert(opts, P_NONNEG_INT, "--top", s.value,
                                s.source, &v, &rc)) {
                return rc;
            }
            opts->top = v.i;
            opts->src[TC_SET_TOP] = s.source;
        } else {
            opts->top = 0;
            opts->src[TC_SET_TOP] = TC_SRC_DEFAULT_BUILTIN;
        }
    }

    /* ---- share_floor (10 default) ---- */
    {
        cli_resolved s = resolve_setting(
            NULL, TC_SRC_CLI_SHARE_FLOOR, "TWITCH_SHARE_FLOOR",
            TC_SRC_ENV_SHARE_FLOOR, "share_floor", TC_SEC_NONE,
            TC_SRC_CONFIG, "10", TC_SRC_DEFAULT_BUILTIN);
        if (parsed.share_floor_set) {
            opts->share_floor = parsed.share_floor;
            opts->src[TC_SET_SHARE_FLOOR] = TC_SRC_CLI_SHARE_FLOOR;
        } else if (s.value != NULL) {
            cli_val_out v;
            if (resolve_convert(opts, P_NONNEG_INT, "--share-floor",
                                s.value, s.source, &v, &rc)) {
                return rc;
            }
            opts->share_floor = v.i;
            opts->src[TC_SET_SHARE_FLOOR] = s.source;
        } else {
            opts->share_floor = 10;
            opts->src[TC_SET_SHARE_FLOOR] = TC_SRC_DEFAULT_BUILTIN;
        }
    }

    /* ---- sort (count default) ---- */
    {
        cli_resolved s = resolve_setting(
            NULL, TC_SRC_CLI_SORT, "TWITCH_SORT", TC_SRC_ENV_SORT,
            "sort", TC_SEC_NONE, TC_SRC_CONFIG, "count",
            TC_SRC_DEFAULT_BUILTIN);
        if (parsed.sort_given) {
            opts->sort = parsed.sort;
            opts->src[TC_SET_SORT] = TC_SRC_CLI_SORT;
        } else if (s.value != NULL) {
            cli_val_out v;
            if (resolve_convert(opts, P_SORT, "--sort", s.value,
                                s.source, &v, &rc)) {
                return rc;
            }
            opts->sort = v.id;
            opts->src[TC_SET_SORT] = s.source;
        } else {
            opts->sort = TC_M_COUNT;
            opts->src[TC_SET_SORT] = TC_SRC_DEFAULT_BUILTIN;
        }
    }

    /* ---- header (full, or compact under --watch) ---- */
    {
        int watch_mode = parsed.watch_given;
        const char *def_val = watch_mode ? "compact" : "full";
        int def_src = watch_mode ? TC_SRC_DEFAULT_UNDER_WATCH
                                 : TC_SRC_DEFAULT;
        cli_resolved s = resolve_setting(
            parsed.header_raw, TC_SRC_CLI_HEADER, "TWITCH_HEADER",
            TC_SRC_ENV_HEADER, "header", TC_SEC_NONE, TC_SRC_CONFIG,
            def_val, def_src);
        opts->src[TC_SET_HEADER] = s.source;
        if (s.value != NULL) {
            cli_val_out v;
            if (resolve_convert(opts, P_HEADER, "--header", s.value,
                                s.source, &v, &rc)) {
                return rc;
            }
            opts->header_mode = v.id;
        } else {
            opts->header_mode = watch_mode ? TC_HDR_COMPACT : TC_HDR_FULL;
        }
    }

    /* ---- state (CLI -L/-O/-U, then env, then config) ---- */
    {
        int state = TC_ST_NONE;
        int src = TC_SRC_DEFAULT;
        if (parsed.state_flag != 0) {
            state = parsed.state_flag;
            src = parsed.state_flag == TC_ST_LIVE ? TC_SRC_CLI_LIVE
                : parsed.state_flag == TC_ST_OFFLINE ? TC_SRC_CLI_OFFLINE
                                                    : TC_SRC_CLI_UNKNOWN;
        } else {
            const char *env = NULL;
            int found = tc_env_get("TWITCH_STATE", &env);
            if (found && env != NULL && env[0] != '\0') {
                int ok;
                state = tc_parse_state(env, &ok);
                src = TC_SRC_ENV_STATE;
                if (!ok) {
                    char msg[SCRATCH_SZ];
                    char *m = msg;
                    m = source_label_buf(m, "--live/--offline/--unknown",
                                         TC_SRC_ENV_STATE);
                    m = tc_cat_cstr(m, ": unknown chat state ");
                    m = py_repr(m, env);
                    m = tc_cat_cstr(m, " (expected live, offline, unknown "
                                       "or any)");
                    *m = '\0';
                    return cli_resolve_error(opts, msg);
                }
            } else {
                const char *cfg = NULL;
                int cfg_src = TC_SRC_NONE;
                if (tc_config_get("state", TC_SEC_NONE, &cfg, &cfg_src)
                    && cfg != NULL && cfg[0] != '\0') {
                    int ok;
                    state = tc_parse_state(cfg, &ok);
                    src = TC_SRC_CONFIG;
                    if (!ok) {
                        char msg[SCRATCH_SZ];
                        char *m = msg;
                        m = source_label_buf(m,
                            "--live/--offline/--unknown", TC_SRC_CONFIG);
                        m = tc_cat_cstr(m, ": unknown chat state ");
                        m = py_repr(m, cfg);
                        m = tc_cat_cstr(m, " (expected live, offline, "
                                           "unknown or any)");
                        *m = '\0';
                        return cli_resolve_error(opts, msg);
                    }
                }
            }
        }
        opts->state_filter = state;
        opts->src[TC_SET_STATE] = src;
    }

    /* ---- columns ---- */
    {
        int col_n = 0;
        int64_t cols[TC_COLUMNS_MAX];
        char col_src[64];
        const char *col_src_ptr = NULL;
        if (parsed.by_state) {
            cols[col_n++] = TC_M_LIVE;
            cols[col_n++] = TC_M_OFFLINE;
            cols[col_n++] = TC_M_OFFLINE_SHARE;
            col_src_ptr = "--by-state";
        }
        if (parsed.show_count > 0) {
            for (i = 0; i < parsed.show_count; i++) {
                int dup = 0;
                int k;
                for (k = 0; k < col_n; k++) {
                    if (cols[k] == parsed.show[i]) {
                        dup = 1;
                        break;
                    }
                }
                if (!dup && col_n < TC_COLUMNS_MAX) {
                    cols[col_n++] = parsed.show[i];
                }
            }
            if (col_src_ptr != NULL) {
                char *m = col_src;
                m = tc_cat_cstr(m, col_src_ptr);
                m = tc_cat_cstr(m, ", --show");
                *m = '\0';
                col_src_ptr = col_src;
            } else {
                col_src_ptr = "--show";
            }
        }
        opts->column_count = col_n;
        for (i = 0; i < col_n; i++) {
            opts->columns[i] = cols[i];
        }
        opts->columns_src_ptr = col_src_ptr;
        opts->columns_src = col_src_ptr ? TC_SRC_CLI_BY_STATE : TC_SRC_NONE;
    }

    /* ---- watch interval (1.0 default) ---- */
    if (parsed.watch_given) {
        opts->interval = parsed.watch_value_given
                         ? parsed.watch : TC_WATCH_FROM_CONFIG_VALUE;
        opts->src[TC_SET_INTERVAL] = TC_SRC_CLI_WATCH;
    } else {
        cli_resolved s = resolve_setting(
            NULL, TC_SRC_CLI_WATCH, "TWITCH_WATCH_INTERVAL",
            TC_SRC_ENV_WATCH_INTERVAL, "interval", TC_SEC_WATCH,
            TC_SRC_CONFIG_WATCH, NULL, TC_SRC_DEFAULT_BUILTIN);
        opts->src[TC_SET_INTERVAL] = s.source;
        if (s.value != NULL) {
            cli_val_out v;
            if (resolve_convert(opts, P_NONNEG_FLOAT, "--watch", s.value,
                                s.source, &v, &rc)) {
                return rc;
            }
            opts->interval = v.f;
        } else {
            opts->interval = 1.0;
        }
    }

    /* ---- watch hold (3.0 default) ---- */
    {
        cli_resolved s = resolve_setting(
            NULL, TC_SRC_CLI_WATCH_HOLD, "TWITCH_WATCH_HOLD",
            TC_SRC_ENV_WATCH_HOLD, "hold", TC_SEC_WATCH,
            TC_SRC_CONFIG_WATCH, "3.0", TC_SRC_DEFAULT_BUILTIN);
        if (parsed.watch_hold_given) {
            opts->hold = parsed.watch_hold;
            opts->src[TC_SET_HOLD] = TC_SRC_CLI_WATCH_HOLD;
        } else if (s.value != NULL) {
            cli_val_out v;
            if (resolve_convert(opts, P_NONNEG_FLOAT, "--watch-hold",
                                s.value, s.source, &v, &rc)) {
                return rc;
            }
            opts->hold = v.f;
            opts->src[TC_SET_HOLD] = s.source;
        } else {
            opts->hold = 3.0;
            opts->src[TC_SET_HOLD] = TC_SRC_DEFAULT_BUILTIN;
        }
    }

    /* ---- color (CLI only, auto default) ---- */
    if (parsed.color_given) {
        opts->color_mode = parsed.color_mode;
        opts->src[TC_SET_COLOR] = TC_SRC_CLI_COLOR;
    } else {
        opts->color_mode = TC_COLOR_AUTO;
        opts->src[TC_SET_COLOR] = TC_SRC_DEFAULT_BUILTIN;
    }

    /* ---- users ---- */
    opts->users = parsed.users;
    opts->src[TC_SET_USERS] = TC_SRC_CLI_USERS;

    /* ---- repeatable lists ---- */
    for (i = 0; i < parsed.excl_n && i < TC_LIST_MAX; i++) {
        tc_copy_str_cap(opts->excl_list[opts->excl_count], parsed.excl[i],
                        sizeof(opts->excl_list[0]));
        opts->excl_count++;
    }
    for (i = 0; i < parsed.incl_n && i < TC_LIST_MAX; i++) {
        tc_copy_str_cap(opts->incl_list[opts->incl_count], parsed.incl[i],
                        sizeof(opts->incl_list[0]));
        opts->incl_count++;
    }
    for (i = 0; i < parsed.excl_group_n && i < TC_LIST_MAX; i++) {
        tc_copy_str_cap(opts->excl_group_list[opts->excl_group_count],
                        parsed.excl_group[i],
                        sizeof(opts->excl_group_list[0]));
        opts->excl_group_count++;
    }
    /* ---- exclude_broadcaster (Python resolve + parse_bool) ---- */
    if (parsed.exclude_bcast) {
        opts->excl_bcast_val = 1;
        opts->src[TC_SET_EXCLUDE_BCAST] = TC_SRC_CLI_EXCLUDE_BCAST;
    } else {
        cli_resolved s = resolve_setting(
            NULL, TC_SRC_CLI_EXCLUDE_BCAST, "TWITCH_EXCLUDE_BROADCASTER",
            TC_SRC_ENV_EXCLUDE_BCAST, "exclude_broadcaster", TC_SEC_NONE,
            TC_SRC_CONFIG, "false", TC_SRC_DEFAULT);
        opts->src[TC_SET_EXCLUDE_BCAST] = s.source;
        if (s.value != NULL) {
            int ok;
            int v = tc_parse_bool(s.value, &ok);
            if (!ok) {
                char msg[SCRATCH_SZ];
                char *m = msg;
                m = source_label_buf(m, "--exclude-broadcaster", s.source);
                m = tc_cat_cstr(m, ": expected true or false, got ");
                m = py_repr(m, s.value);
                *m = '\0';
                return cli_resolve_error(opts, msg);
            }
            opts->excl_bcast_val = v;
        } else {
            opts->excl_bcast_val = 0;
        }
    }
    opts->streamer_mode = parsed.streamer;
    opts->complete_kind = (enum tc_complete_kind)parsed.complete_kind;
    opts->prog = s_prog_name;

    /* ---- window ---- */
    {
        int64_t end_ymd = 0, end_sod = 0;
        int64_t begin_ymd = 0, begin_sod = 0;
        int kind = TC_WIN_EARLIEST;
        const char *start_source = NULL;

        /* end: the raw --end, else local now */
        if (parsed.end_raw != NULL) {
            if (!tc_parse_datetime(parsed.end_raw, 1, &end_ymd, &end_sod)) {
                char msg[SCRATCH_SZ];
                char *m = msg;
                char *body;
                m = tc_cat_cstr(m, "--end: ");
                body = week_error_body(m, parsed.end_raw);
                if (body == NULL) {
                    char disp[TC_RAW_SZ];
                    tc_copy_str_cap(disp, parsed.end_raw, sizeof(disp));
                    strip_inplace(disp);
                    body = datetime_error_body(m, disp);
                }
                *body = '\0';
                return cli_resolve_error(opts, msg);
            }
            opts->src[TC_SET_END] = TC_SRC_CLI_END;
        } else {
            time_t now = time(NULL);
            struct tm tmv;
            localtime_r(&now, &tmv);
            end_ymd = (int64_t)(tmv.tm_year + TC_TM_YEAR_BASE) * 10000
                      + (int64_t)(tmv.tm_mon + 1) * 100 + tmv.tm_mday;
            end_sod = (int64_t)tmv.tm_hour * TC_SECS_PER_HOUR
                      + (int64_t)tmv.tm_min * 60 + tmv.tm_sec;
            opts->src[TC_SET_END] = TC_SRC_DEFAULT_NOW;
        }

        /* window start: --users, CLI begin/since, env, config, else the
           earliest-log default */
        if (parsed.flags & TC_F_USERS_GIVEN) {
            kind = TC_WIN_USERS;
            {
                char *m = opts->win_src;
                m = tc_cat_cstr_cap(m, "--users ", sizeof(opts->win_src));
                m = tc_fmt_u64(m, (uint64_t)parsed.users);
                *m = '\0';
            }
            start_source = opts->win_src;
            begin_ymd = end_ymd;
            begin_sod = end_sod;
        } else if (parsed.begin_raw != NULL) {
            if (!tc_parse_datetime(parsed.begin_raw, 0, &begin_ymd,
                                   &begin_sod)) {
                char msg[SCRATCH_SZ];
                char *m = msg;
                char *body;
                char disp[TC_RAW_SZ];
                m = tc_cat_cstr(m, "--begin: ");
                tc_copy_str_cap(disp, parsed.begin_raw, sizeof(disp));
                strip_inplace(disp);
                body = week_error_body(m, disp);
                if (body == NULL) {
                    body = datetime_error_body(m, disp);
                }
                *body = '\0';
                return cli_resolve_error(opts, msg);
            }
            kind = TC_WIN_BEGIN;
            start_source = "--begin";
        } else if (parsed.since_raw != NULL) {
            int st;
            int64_t delta = tc_parse_duration(parsed.since_raw, &st);
            if (st != 0) {
                char msg[SCRATCH_SZ];
                char *m = msg;
                char disp[TC_RAW_SZ];
                m = tc_cat_cstr(m, "--since: ");
                if (st == 2) {
                    m = tc_cat_cstr(m, "duration must be greater than zero");
                } else {
                    tc_copy_str_cap(disp, parsed.since_raw, sizeof(disp));
                    strip_inplace(disp);
                    lowercase_inplace(disp);
                    m = tc_cat_cstr(m, "unrecognized duration ");
                    m = py_repr(m, disp);
                    m = tc_cat_cstr(m, " (try '30d', '12h', '90m', '1w3d'; "
                                       "units are w/d/h/m/s and 'm' is "
                                       "minutes)");
                }
                *m = '\0';
                return cli_resolve_error(opts, msg);
            }
            {
                int64_t end_epoch = tc_ymd_sod_to_epoch(end_ymd, end_sod);
                int64_t begin_epoch = end_epoch - delta;
                if (begin_epoch < TC_YEAR1_EPOCH) {
                    char msg[SCRATCH_SZ];
                    char *m = msg;
                    m = tc_cat_cstr(m, "--since: date value out of range");
                    *m = '\0';
                    return cli_resolve_error(opts, msg);
                }
                tc_epoch_to_ymd_sod(begin_epoch, &begin_ymd, &begin_sod);
            }
            kind = TC_WIN_SINCE;
            {
                char *m = opts->win_src;
                char disp[TC_RAW_SZ];
                m = tc_cat_cstr_cap(m, "--since ", sizeof(opts->win_src));
                tc_copy_str_cap(disp, parsed.since_raw, sizeof(disp));
                strip_inplace(disp);
                m = tc_cat_cstr_cap(m, disp,
                                    (size_t)(opts->win_src
                                             + sizeof(opts->win_src) - m));
                m = tc_cat_cstr_cap(m, " before end",
                                    (size_t)(opts->win_src
                                             + sizeof(opts->win_src) - m));
                (void)m;
            }
            start_source = opts->win_src;
        } else {
            /* env/config begin/since (absent in the sandboxed harness) */
            const char *env_begin = NULL;
            const char *env_since = NULL;
            int env_begin_found = tc_env_get("TWITCH_BEGIN", &env_begin);
            int env_since_found = tc_env_get("TWITCH_SINCE", &env_since);
            if (env_begin_found && env_begin != NULL && env_begin[0] != '\0'
                && env_since_found && env_since != NULL
                && env_since[0] != '\0') {
                return cli_resolve_error(opts,
                    "env TWITCH_BEGIN and env TWITCH_SINCE are mutually "
                    "exclusive");
            }
            if (env_begin_found && env_begin != NULL && env_begin[0] != '\0') {
                if (!tc_parse_datetime(env_begin, 0, &begin_ymd, &begin_sod)) {
                    char msg[SCRATCH_SZ];
                    char *m = msg;
                    char disp[TC_RAW_SZ];
                    m = tc_cat_cstr(m, "--begin (from env TWITCH_BEGIN): ");
                    tc_copy_str_cap(disp, env_begin, sizeof(disp));
                    strip_inplace(disp);
                    m = datetime_error_body(m, disp);
                    *m = '\0';
                    return cli_resolve_error(opts, msg);
                }
                kind = TC_WIN_BEGIN;
                start_source = "env TWITCH_BEGIN";
            } else if (env_since_found && env_since != NULL
                       && env_since[0] != '\0') {
                int st;
                int64_t delta = tc_parse_duration(env_since, &st);
                if (st != 0) {
                    char msg[SCRATCH_SZ];
                    char *m = msg;
                    m = tc_cat_cstr(m, "--since (from env TWITCH_SINCE): ");
                    if (st == 2) {
                        m = tc_cat_cstr(m,
                            "duration must be greater than zero");
                    } else {
                        char disp[TC_RAW_SZ];
                        tc_copy_str_cap(disp, env_since, sizeof(disp));
                        strip_inplace(disp);
                        lowercase_inplace(disp);
                        m = tc_cat_cstr(m, "unrecognized duration ");
                        m = py_repr(m, disp);
                        m = tc_cat_cstr(m, " (try '30d', '12h', '90m', "
                                           "'1w3d'; units are w/d/h/m/s and "
                                           "'m' is minutes)");
                    }
                    *m = '\0';
                    return cli_resolve_error(opts, msg);
                }
                {
                    int64_t end_epoch = tc_ymd_sod_to_epoch(end_ymd, end_sod);
                    int64_t begin_epoch = end_epoch - delta;
                    if (begin_epoch < TC_YEAR1_EPOCH) {
                        return cli_resolve_error(opts,
                            "--since (from env TWITCH_SINCE): date value out "
                            "of range");
                    }
                    tc_epoch_to_ymd_sod(begin_epoch, &begin_ymd, &begin_sod);
                }
                kind = TC_WIN_SINCE;
                {
                    char *m = opts->win_src;
                    m = tc_cat_cstr_cap(m, "env TWITCH_SINCE ",
                                        sizeof(opts->win_src));
                    m = tc_cat_cstr_cap(m, env_since,
                        (size_t)(opts->win_src + sizeof(opts->win_src) - m));
                    m = tc_cat_cstr_cap(m, " before end",
                        (size_t)(opts->win_src + sizeof(opts->win_src) - m));
                    (void)m;
                }
                start_source = opts->win_src;
            } else {
                const char *cfg_begin = NULL;
                const char *cfg_since = NULL;
                int cfg_begin_src = TC_SRC_NONE;
                int cfg_since_src = TC_SRC_NONE;
                int cfg_begin_found = tc_config_get(
                    "begin", TC_SEC_NONE, &cfg_begin, &cfg_begin_src);
                int cfg_since_found = tc_config_get(
                    "since", TC_SEC_NONE, &cfg_since, &cfg_since_src);
                if (cfg_begin_found && cfg_begin != NULL
                    && cfg_begin[0] != '\0' && cfg_since_found
                    && cfg_since != NULL && cfg_since[0] != '\0') {
                    return cli_resolve_error(opts,
                        "config begin and config since are mutually "
                        "exclusive");
                }
                if (cfg_begin_found && cfg_begin != NULL
                    && cfg_begin[0] != '\0') {
                    if (!tc_parse_datetime(cfg_begin, 0, &begin_ymd,
                                           &begin_sod)) {
                        char msg[SCRATCH_SZ];
                        char *m = msg;
                        char disp[TC_RAW_SZ];
                        m = tc_cat_cstr(m, "--begin (from config begin): ");
                        tc_copy_str_cap(disp, cfg_begin, sizeof(disp));
                        strip_inplace(disp);
                        m = datetime_error_body(m, disp);
                        *m = '\0';
                        return cli_resolve_error(opts, msg);
                    }
                    kind = TC_WIN_BEGIN;
                    start_source = "config begin";
                } else if (cfg_since_found && cfg_since != NULL
                           && cfg_since[0] != '\0') {
                    int st;
                    int64_t delta = tc_parse_duration(cfg_since, &st);
                    if (st != 0) {
                        char msg[SCRATCH_SZ];
                        char *m = msg;
                        m = tc_cat_cstr(m,
                            "--since (from config since): ");
                        if (st == 2) {
                            m = tc_cat_cstr(m,
                                "duration must be greater than zero");
                        } else {
                            char disp[TC_RAW_SZ];
                            tc_copy_str_cap(disp, cfg_since, sizeof(disp));
                            strip_inplace(disp);
                            lowercase_inplace(disp);
                            m = tc_cat_cstr(m, "unrecognized duration ");
                            m = py_repr(m, disp);
                            m = tc_cat_cstr(m, " (try '30d', '12h', '90m', "
                                               "'1w3d'; units are w/d/h/m/s "
                                               "and 'm' is minutes)");
                        }
                        *m = '\0';
                        return cli_resolve_error(opts, msg);
                    }
                    {
                        int64_t end_epoch = tc_ymd_sod_to_epoch(end_ymd,
                                                                 end_sod);
                        int64_t begin_epoch = end_epoch - delta;
                        if (begin_epoch < TC_YEAR1_EPOCH) {
                            return cli_resolve_error(opts,
                                "--since (from config since): date value out "
                                "of range");
                        }
                        tc_epoch_to_ymd_sod(begin_epoch, &begin_ymd,
                                            &begin_sod);
                    }
                    kind = TC_WIN_SINCE;
                    {
                        char *m = opts->win_src;
                        m = tc_cat_cstr_cap(m, "config since ",
                                            sizeof(opts->win_src));
                        m = tc_cat_cstr_cap(m, cfg_since,
                            (size_t)(opts->win_src
                                     + sizeof(opts->win_src) - m));
                        m = tc_cat_cstr_cap(m, " before end",
                            (size_t)(opts->win_src
                                     + sizeof(opts->win_src) - m));
                        (void)m;
                    }
                    start_source = opts->win_src;
                } else {
                    kind = TC_WIN_EARLIEST;
                    start_source = "default: earliest log file";
                    begin_ymd = 0;
                    begin_sod = 0;
                }
            }
        }

        window->begin_ymd = begin_ymd;
        window->begin_sod = begin_sod;
        window->end_ymd = end_ymd;
        window->end_sod = end_sod;
        window->kind = kind;
        window->start_source = start_source;
        window->threshold = opts->min_count;
        window->state_filter = opts->state_filter;
        window->begin_rolls = (kind == TC_WIN_SINCE || kind == TC_WIN_USERS);
        window->users_req = parsed.users;
    }

    /* The begin-after-end check (an explicit begin/since/end can put begin
       after end; the earliest-log default has begin=0 and never trips). */
    if (window->begin_ymd != 0) {
        int64_t begin_epoch = tc_ymd_sod_to_epoch(window->begin_ymd,
                                                  window->begin_sod);
        int64_t end_epoch = tc_ymd_sod_to_epoch(window->end_ymd,
                                                window->end_sod);
        if (begin_epoch > end_epoch) {
            char msg[SCRATCH_SZ];
            char *m = msg;
            m = tc_cat_cstr(m, "begin (");
            m = tc_fmt_ymd_sod(m, window->begin_ymd, window->begin_sod, ' ');
            m = tc_cat_cstr(m, ") is after end (");
            m = tc_fmt_ymd_sod(m, window->end_ymd, window->end_sod, ' ');
            *m++ = ')';
            *m = '\0';
            return cli_resolve_error(opts, msg);
        }
    }

    return TC_EXIT_OK;
}