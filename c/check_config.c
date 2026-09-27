// ============================================================================
// check_config.c — test driver for the config/env/exclusion hooks.
//
//  main() parses the harness's CLI into a tc_opts (the C cli.c is still a stub
//  while the CLI milestone is in flight, so this driver resolves the settings
//  the harness asserts against through the config hooks themselves), drives
//  the hooks in the Python's order — load, resolve, aliases, exclusions —
//  then prints the stable dump test-tc-config.sh asserts against:
//
//      channel=<resolved channel>
//      chan_src=<source label, or "<src> -> alias '<key>'">
//      src=<logs_dir source>  logs_dir=<...>
//      config=<resolved path>  config_loaded=<0|1>
//      src=<source>  <setting>=<value>   (min_count, top, header, sort, state,
//          users_policy, users_max, end, begin, interval, hold, shades,
//          user_width, fade_up, notify, max_events, seed_lookback)
//      excl_count=<N>
//      excl=<login>|<source label>       (one line per merged exclusion)
//      excl_sources=<", ".join(source labels)>
//
//  Resolution order per setting mirrors Python resolve(): CLI -> env
//  (tc_env_get) -> config (tc_config_get, section-aware) -> built-in default.
//  Sections: [watch] is consulted only under --watch; [tail] always.
//  The exclusion set is produced by tc_build_exclusions.
//
//  Error cases exit 1 with "error: <msg>" on stderr (via tc_fail), matching
//  the Python's ConfigError -> report_failure shape the harness diffs.
// ============================================================================

#include "tc_platform.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

extern int64_t tc_excl_src_count;   /* exported by config.c (mirrors the asm) */

static tc_opts s_opts;
static tc_window s_win;
static tc_excl_set s_set;

// ----------------------------------------------------------------------------
// Source labels — the driver's own tc_source_str while cli.c is a stub.  The
// strings are the Python's exact source labels.
// ----------------------------------------------------------------------------
static const char *drv_src_label(int id) {
    switch (id) {
    case TC_SRC_CLI_CHANNEL: return "--channel";
    case TC_SRC_CLI_USERS_POLICY: return "--users-policy";
    case TC_SRC_CLI_USERS_MAX: return "--users-max";
    case TC_SRC_CLI_END: return "--end";
    case TC_SRC_CLI_MIN_COUNT: return "--min-count";
    case TC_SRC_CLI_SHOW: return "--show";
    case TC_SRC_CLI_SORT: return "--sort";
    case TC_SRC_CLI_SHARE_FLOOR: return "--share-floor";
    case TC_SRC_CLI_TOP: return "--top";
    case TC_SRC_CLI_LOGS_DIR: return "--logs-dir";
    case TC_SRC_CLI_HEADER: return "--header";
    case TC_SRC_CLI_LIVE: return "--live";
    case TC_SRC_CLI_OFFLINE: return "--offline";
    case TC_SRC_CLI_UNKNOWN: return "--unknown";
    case TC_SRC_CLI_BEGIN: return "--begin";
    case TC_SRC_CLI_SINCE: return "--since";
    case TC_SRC_CLI_USERS: return "--users";
    case TC_SRC_CLI_WATCH: return "--watch";
    case TC_SRC_CLI_WATCH_HOLD: return "--watch-hold";
    case TC_SRC_CLI_EXCLUDE: return "--exclude";
    case TC_SRC_CLI_EXCLUDE_GROUP: return "--exclude-group";
    case TC_SRC_CLI_EXCLUDE_BCAST: return "--exclude-broadcaster";
    case TC_SRC_CLI_INCLUDE: return "--include";
    case TC_SRC_CLI_CONFIG: return "--config";
    case TC_SRC_CLI_NO_EXCLUDE: return "--no-exclude";
    case TC_SRC_CLI_NO_CONFIG: return "--no-config";
    case TC_SRC_ENV_CHANNEL: return "env TWITCH_CHANNEL";
    case TC_SRC_ENV_USERS_POLICY: return "env TWITCH_USERS_POLICY";
    case TC_SRC_ENV_USERS_MAX: return "env TWITCH_USERS_MAX";
    case TC_SRC_ENV_END: return "env TWITCH_END";
    case TC_SRC_ENV_MIN_COUNT: return "env TWITCH_MIN_COUNT";
    case TC_SRC_ENV_SORT: return "env TWITCH_SORT";
    case TC_SRC_ENV_TOP: return "env TWITCH_TOP";
    case TC_SRC_ENV_LOGS_DIR: return "env TWITCH_LOGS_DIR";
    case TC_SRC_ENV_HEADER: return "env TWITCH_HEADER";
    case TC_SRC_ENV_STATE: return "env TWITCH_STATE";
    case TC_SRC_ENV_EXCLUDE: return "env TWITCH_EXCLUDE";
    case TC_SRC_ENV_EXCLUDE_BCAST: return "env TWITCH_EXCLUDE_BROADCASTER";
    case TC_SRC_ENV_WATCH_INTERVAL: return "env TWITCH_WATCH_INTERVAL";
    case TC_SRC_ENV_WATCH_HOLD: return "env TWITCH_WATCH_HOLD";
    case TC_SRC_ENV_WATCH_SHADES: return "env TWITCH_WATCH_SHADES";
    case TC_SRC_ENV_WATCH_USER_WIDTH: return "env TWITCH_WATCH_USER_WIDTH";
    case TC_SRC_ENV_WATCH_FADE_UP: return "env TWITCH_WATCH_FADE_UP";
    case TC_SRC_ENV_TAIL_NOTIFY: return "env TWITCH_TAIL_NOTIFY";
    case TC_SRC_ENV_TAIL_MAX_EVENTS: return "env TWITCH_TAIL_MAX_EVENTS";
    case TC_SRC_ENV_TAIL_SEED_LOOKBACK: return "env TWITCH_TAIL_SEED_LOOKBACK";
    case TC_SRC_CONFIG: return "config";
    case TC_SRC_CONFIG_WATCH: return "config [watch]";
    case TC_SRC_CONFIG_TAIL: return "config [tail]";
    case TC_SRC_DEFAULT_BUILTIN: return "built-in default";
    case TC_SRC_DEFAULT: return "default";
    case TC_SRC_DEFAULT_NOW: return "default: now";
    case TC_SRC_DEFAULT_UNDER_WATCH: return "default under --watch";
    case TC_SRC_DEFAULT_EARLIEST: return "default: earliest log file";
    case TC_SRC_EXCL_CONFIG: return "config exclude";
    default: return "";
    }
}

// ----------------------------------------------------------------------------
// Value parsers (the cli.c parsers are stubs; minimal, harness-sufficient).
// ----------------------------------------------------------------------------
static int drv_ascii_casecmp(const char *a, const char *b) {
    while (*a != '\0' && *b != '\0') {
        unsigned char ca = (unsigned char)*a;
        unsigned char cb = (unsigned char)*b;
        if (ca >= 'A' && ca <= 'Z') ca = (unsigned char)(ca - 'A' + 'a');
        if (cb >= 'A' && cb <= 'Z') cb = (unsigned char)(cb - 'A' + 'a');
        if (ca != cb) {
            return (int)ca - (int)cb;
        }
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

static int64_t drv_parse_int(const char *s, int *ok) {
    char *end = NULL;
    long long v = strtoll(s, &end, 10);
    if (end == s || *end != '\0') {
        *ok = 0;
        return 0;
    }
    *ok = 1;
    return (int64_t)v;
}

static double drv_parse_double(const char *s, int *ok) {
    char *end = NULL;
    double v = strtod(s, &end);
    if (end == s || *end != '\0') {
        *ok = 0;
        return 0.0;
    }
    *ok = 1;
    return v;
}

static int drv_parse_bool(const char *s, int *ok) {
    if (drv_ascii_casecmp(s, "1") == 0 || drv_ascii_casecmp(s, "true") == 0
        || drv_ascii_casecmp(s, "yes") == 0 || drv_ascii_casecmp(s, "on") == 0) {
        *ok = 1;
        return 1;
    }
    if (drv_ascii_casecmp(s, "0") == 0 || drv_ascii_casecmp(s, "false") == 0
        || drv_ascii_casecmp(s, "no") == 0 || drv_ascii_casecmp(s, "off") == 0) {
        *ok = 1;
        return 0;
    }
    *ok = 0;
    return 0;
}

static int drv_parse_sort(const char *s, int *ok) {
    if (drv_ascii_casecmp(s, "count") == 0) { *ok = 1; return TC_M_COUNT; }
    if (drv_ascii_casecmp(s, "login") == 0) { *ok = 1; return TC_M_LOGIN; }
    if (drv_ascii_casecmp(s, "live") == 0) { *ok = 1; return TC_M_LIVE; }
    if (drv_ascii_casecmp(s, "offline") == 0) { *ok = 1; return TC_M_OFFLINE; }
    if (drv_ascii_casecmp(s, "unknown") == 0) { *ok = 1; return TC_M_UNKNOWN; }
    if (drv_ascii_casecmp(s, "offline-share") == 0) { *ok = 1; return TC_M_OFFLINE_SHARE; }
    if (drv_ascii_casecmp(s, "live-share") == 0) { *ok = 1; return TC_M_LIVE_SHARE; }
    *ok = 0;
    return TC_M_COUNT;
}

static int drv_parse_header(const char *s, int *ok) {
    if (drv_ascii_casecmp(s, "full") == 0) { *ok = 1; return TC_HDR_FULL; }
    if (drv_ascii_casecmp(s, "compact") == 0) { *ok = 1; return TC_HDR_COMPACT; }
    if (drv_ascii_casecmp(s, "none") == 0) { *ok = 1; return TC_HDR_NONE; }
    *ok = 0;
    return TC_HDR_FULL;
}

static int drv_parse_state(const char *s, int *ok) {
    if (drv_ascii_casecmp(s, "live") == 0) { *ok = 1; return TC_ST_LIVE; }
    if (drv_ascii_casecmp(s, "offline") == 0) { *ok = 1; return TC_ST_OFFLINE; }
    if (drv_ascii_casecmp(s, "unknown") == 0) { *ok = 1; return TC_ST_UNKNOWN; }
    if (drv_ascii_casecmp(s, "any") == 0 || drv_ascii_casecmp(s, "all") == 0) {
        *ok = 1;
        return TC_ST_NONE;
    }
    *ok = 0;
    return TC_ST_NONE;
}

static int drv_parse_datetime(const char *s, int end_of_day, int64_t *ymd,
                              int64_t *sod) {
    int y = 0, m = 0, d = 0, h = 0, mi = 0, sec = 0;
    int n = 0;
    int have_time = 0;
    if (sscanf(s, "%d-%d-%d %d:%d:%d%n", &y, &m, &d, &h, &mi, &sec, &n) == 6
        && s[n] == '\0') {
        have_time = 1;
    } else if (sscanf(s, "%d-%d-%d%n", &y, &m, &d, &n) == 3 && s[n] == '\0') {
        h = mi = sec = 0;
    } else if (sscanf(s, "%d/%d/%d%n", &y, &m, &d, &n) == 3 && s[n] == '\0') {
        h = mi = sec = 0;
    } else {
        return 0;
    }
    if (m < 1 || m > 12 || d < 1 || d > 31 || h < 0 || h > 23 || mi < 0
        || mi > 59 || sec < 0 || sec > 60) {
        return 0;
    }
    if (end_of_day && !have_time) {
        h = 23;
        mi = 59;
        sec = 59;
    }
    *ymd = (int64_t)y * TC_YMD_YEAR_SCALE + (int64_t)m * TC_YMD_MONTH_SCALE + d;
    *sod = (int64_t)h * TC_SECS_PER_HOUR + (int64_t)mi * 60 + sec;
    return 1;
}

static int64_t drv_dbl_bits(double d) {
    int64_t bits;
    memcpy(&bits, &d, sizeof(bits));
    return bits;
}

// ----------------------------------------------------------------------------
// CLI parsing (the subset the config harness drives).
// ----------------------------------------------------------------------------
static void drv_arg_error(const char *msg) {
    fprintf(stderr, "tc-config-test: error: %s\n", msg);
    exit(2);
}

static const char *drv_value(int argc, char **argv, int *i, const char *flag) {
    if (*i + 1 >= argc) {
        char buf[128];
        snprintf(buf, sizeof(buf), "argument %s: expected one argument", flag);
        drv_arg_error(buf);
    }
    (*i)++;
    return argv[*i];
}

static void drv_help(void) {
    char def[TC_PATH_SZ];
    size_t len = tc_default_config_path(def, sizeof(def));
    printf("usage: tc-config-test [-h] [-c CHANNEL] [-d LOGS_DIR] "
           "[-b DATETIME] [-e DATETIME] [-n N]\n"
           "                         [--config CONFIG] [--no-config] "
           "[--watch [SECONDS]] [-x LIST] [-g NAME] [--include LIST]\n"
           "                         [--exclude-broadcaster] [--no-exclude]\n"
           "\n"
           "config test driver for the twitch-counts C port\n"
           "\n"
           "options:\n"
           "  -c, --channel CHANNEL       Twitch channel name (case-insensitive)\n"
           "  -d, --logs-dir LOGS_DIR     Chatterino Twitch Channels directory\n"
           "  -b, --begin DATETIME        Inclusive start of the counted range\n"
           "  -e, --end DATETIME          Inclusive end of the counted range\n"
           "  -n, --top N                 show at most N rows, 0 for unlimited\n"
           "  --config CONFIG             path to the TOML config file\n");
    if (len > 0) {
        printf("                              (default: %s)\n", def);
    }
    printf("  --no-config                 ignore the config file\n"
           "  --watch [SECONDS]           redraw the report every SECONDS\n"
           "  -x, --exclude LIST          exclude these logins (repeatable)\n"
           "  -g, --exclude-group NAME    exclude a named group (repeatable)\n"
           "  --include LIST              re-include these logins (repeatable)\n"
           "  --exclude-broadcaster       exclude the channel itself\n"
           "  --no-exclude                clear every exclusion\n"
           "  -h, --help                  show this help message and exit\n");
    exit(0);
}

static void drv_parse_args(int argc, char **argv, tc_opts *opts) {
    for (int i = 1; i < argc; i++) {
        const char *a = argv[i];
        const char *val;
        if (strcmp(a, "-h") == 0 || strcmp(a, "--help") == 0) {
            drv_help();
        } else if (strcmp(a, "-c") == 0 || strcmp(a, "--channel") == 0) {
            val = drv_value(argc, argv, &i, a);
            snprintf(opts->channel, sizeof(opts->channel), "%s", val);
            opts->src[TC_SET_CHANNEL] = TC_SRC_CLI_CHANNEL;
        } else if (strcmp(a, "-d") == 0 || strcmp(a, "--logs-dir") == 0) {
            val = drv_value(argc, argv, &i, a);
            snprintf(opts->logs_dir, sizeof(opts->logs_dir), "%s", val);
            opts->src[TC_SET_LOGS_DIR] = TC_SRC_CLI_LOGS_DIR;
        } else if (strcmp(a, "-b") == 0 || strcmp(a, "--begin") == 0) {
            val = drv_value(argc, argv, &i, a);
            snprintf(opts->begin_raw, sizeof(opts->begin_raw), "%s", val);
            opts->flags |= TC_F_BEGIN_GIVEN;
        } else if (strcmp(a, "-e") == 0 || strcmp(a, "--end") == 0) {
            val = drv_value(argc, argv, &i, a);
            snprintf(opts->end_raw, sizeof(opts->end_raw), "%s", val);
            opts->flags |= TC_F_END_GIVEN;
        } else if (strcmp(a, "-n") == 0 || strcmp(a, "--top") == 0) {
            val = drv_value(argc, argv, &i, a);
            int ok;
            opts->top = drv_parse_int(val, &ok);
            if (!ok) {
                char buf[160];
                snprintf(buf, sizeof(buf), "argument --top: %s is not an integer", val);
                drv_arg_error(buf);
            }
            opts->src[TC_SET_TOP] = TC_SRC_CLI_TOP;
        } else if (strcmp(a, "--config") == 0) {
            val = drv_value(argc, argv, &i, a);
            snprintf(opts->config_path, sizeof(opts->config_path), "%s", val);
            opts->flags |= TC_F_CONFIG_GIVEN;
        } else if (strcmp(a, "--watch") == 0) {
            opts->flags |= TC_F_WATCH_PRESENT;
            if (i + 1 < argc && argv[i + 1][0] != '-') {
                val = argv[++i];
                int ok;
                opts->interval = drv_parse_double(val, &ok);
                if (!ok) {
                    char buf[160];
                    snprintf(buf, sizeof(buf),
                             "argument --watch: %s is not a number of seconds", val);
                    drv_arg_error(buf);
                }
                opts->flags |= TC_F_WATCH_VALUE;
                opts->src[TC_SET_INTERVAL] = TC_SRC_CLI_WATCH;
            }
        } else if (strcmp(a, "--no-config") == 0) {
            opts->flags |= TC_F_NO_CONFIG;
        } else if (strcmp(a, "--no-exclude") == 0) {
            opts->flags |= TC_F_NO_EXCLUDE;
        } else if (strcmp(a, "--exclude-broadcaster") == 0) {
            opts->flags |= TC_F_EXCLUDE_BCAST;
            opts->excl_bcast_val = 1;
            opts->src[TC_SET_EXCLUDE_BCAST] = TC_SRC_CLI_EXCLUDE_BCAST;
        } else if (strcmp(a, "-x") == 0 || strcmp(a, "--exclude") == 0) {
            val = drv_value(argc, argv, &i, a);
            if (opts->excl_count >= TC_LIST_MAX) {
                drv_arg_error("argument --exclude: too many values");
            }
            snprintf(opts->excl_list[opts->excl_count], TC_LIST_ITEM_SZ, "%s", val);
            opts->excl_count++;
            opts->flags |= TC_F_EXCL_GIVEN;
        } else if (strcmp(a, "-g") == 0 || strcmp(a, "--exclude-group") == 0) {
            val = drv_value(argc, argv, &i, a);
            if (opts->excl_group_count >= TC_LIST_MAX) {
                drv_arg_error("argument --exclude-group: too many values");
            }
            snprintf(opts->excl_group_list[opts->excl_group_count],
                     TC_LIST_GROUP_SZ, "%s", val);
            opts->excl_group_count++;
            opts->flags |= TC_F_EXCL_GROUP_GIVEN;
        } else if (strcmp(a, "--include") == 0) {
            val = drv_value(argc, argv, &i, a);
            if (opts->incl_count >= TC_LIST_MAX) {
                drv_arg_error("argument --include: too many values");
            }
            snprintf(opts->incl_list[opts->incl_count], TC_LIST_ITEM_SZ, "%s", val);
            opts->incl_count++;
            opts->flags |= TC_F_INCL_GIVEN;
        } else if (strcmp(a, "--live") == 0) {
            opts->state_filter = TC_ST_LIVE;
            opts->src[TC_SET_STATE] = TC_SRC_CLI_LIVE;
        } else if (strcmp(a, "--offline") == 0) {
            opts->state_filter = TC_ST_OFFLINE;
            opts->src[TC_SET_STATE] = TC_SRC_CLI_OFFLINE;
        } else if (strcmp(a, "--unknown") == 0) {
            opts->state_filter = TC_ST_UNKNOWN;
            opts->src[TC_SET_STATE] = TC_SRC_CLI_UNKNOWN;
        } else {
            char buf[256];
            snprintf(buf, sizeof(buf), "unrecognized arguments: %s", a);
            drv_arg_error(buf);
        }
    }
}

// ----------------------------------------------------------------------------
// Layered resolution — CLI > tc_env_get > tc_config_get > default.
// ----------------------------------------------------------------------------
typedef struct {
    int set;                  /* TC_SET_* */
    const char *key;          /* config key */
    int section;              /* TC_SEC_* */
    const char *env;          /* TWITCH_* variable */
    int env_src;              /* TC_SRC_ENV_* */
    int cli_src;              /* TC_SRC_CLI_* */
} drv_spec;

/* Returns 1 when CLI/env/config supplied a value; *out = raw string, *src =
   the source id.  Returns 0 (no value) when only a default remains. */
static int drv_lookup(const drv_spec *sp, const char *cli_value,
                      const char **out, int *src) {
    if (cli_value != NULL) {
        *out = cli_value;
        *src = sp->cli_src;
        return 1;
    }
    const char *env = NULL;
    if (sp->env != NULL && tc_env_get(sp->env, &env)) {
        *out = env;
        *src = sp->env_src;
        return 1;
    }
    const char *cfg = NULL;
    int cfg_src = TC_SRC_NONE;
    if (sp->key != NULL && tc_config_get(sp->key, sp->section, &cfg, &cfg_src)) {
        *out = cfg;
        *src = cfg_src;
        return 1;
    }
    *out = NULL;
    *src = TC_SRC_NONE;
    return 0;
}

static void drv_value_error(const char *flag, int src, const char *why) {
    const char *label = drv_src_label(src);
    char buf[512];
    if (label[0] != '\0' && strcmp(label, flag) != 0) {
        snprintf(buf, sizeof(buf), "%s (from %s): %s", flag, label, why);
    } else {
        snprintf(buf, sizeof(buf), "%s: %s", flag, why);
    }
    tc_fail(buf);
}

static void drv_resolve_channel(tc_opts *opts) {
    if (opts->src[TC_SET_CHANNEL] == TC_SRC_DYN_ALIAS) {
        return;                       /* the first aliases pass rewrote it */
    }
    if (opts->src[TC_SET_CHANNEL] == TC_SRC_CLI_CHANNEL) {
        return;                       /* -c was parsed already */
    }
    const char *v;
    int src;
    if (tc_env_get("TWITCH_CHANNEL", &v)) {
        snprintf(opts->channel, sizeof(opts->channel), "%s", v);
        opts->src[TC_SET_CHANNEL] = TC_SRC_ENV_CHANNEL;
        return;
    }
    if (tc_config_get("channel", TC_SEC_NONE, &v, &src)) {
        snprintf(opts->channel, sizeof(opts->channel), "%s", v);
        opts->src[TC_SET_CHANNEL] = src;
        return;
    }
    opts->src[TC_SET_CHANNEL] = TC_SRC_DEFAULT;
}

static void drv_resolve_logs_dir(tc_opts *opts) {
    if (opts->src[TC_SET_LOGS_DIR] == TC_SRC_CLI_LOGS_DIR) {
        return;
    }
    static const drv_spec spec = {
        TC_SET_LOGS_DIR, "logs_dir", TC_SEC_NONE, "TWITCH_LOGS_DIR",
        TC_SRC_ENV_LOGS_DIR, TC_SRC_CLI_LOGS_DIR
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        snprintf(opts->logs_dir, sizeof(opts->logs_dir), "%s", v);
    } else {
        size_t len = tc_platform_default_logs_dir(opts->logs_dir,
                                                  sizeof(opts->logs_dir));
        if (len == 0) {
            opts->logs_dir[0] = '\0';
        }
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_LOGS_DIR] = src;
}

static void drv_resolve_min_count(tc_opts *opts) {
    static const drv_spec spec = {
        TC_SET_MIN_COUNT, "min_count", TC_SEC_NONE, "TWITCH_MIN_COUNT",
        TC_SRC_ENV_MIN_COUNT, TC_SRC_CLI_MIN_COUNT
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->min_count = drv_parse_int(v, &ok);
        if (!ok) {
            drv_value_error("--min-count", src, "is not an integer");
        }
    } else {
        opts->min_count = 1;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_MIN_COUNT] = src;
}

static void drv_resolve_top(tc_opts *opts) {
    if (opts->src[TC_SET_TOP] == TC_SRC_CLI_TOP) {
        return;                       /* -n/--top was parsed already */
    }
    static const drv_spec spec = {
        TC_SET_TOP, "top", TC_SEC_NONE, "TWITCH_TOP",
        TC_SRC_ENV_TOP, TC_SRC_CLI_TOP
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->top = drv_parse_int(v, &ok);
        if (!ok) {
            drv_value_error("--top", src, "is not an integer");
        }
    } else {
        opts->top = 0;
        src = TC_SRC_DEFAULT;
    }
    opts->src[TC_SET_TOP] = src;
}

static void drv_resolve_header(tc_opts *opts) {
    int watch = (opts->flags & TC_F_WATCH_PRESENT) != 0;
    static const drv_spec spec = {
        TC_SET_HEADER, "header", TC_SEC_NONE, "TWITCH_HEADER",
        TC_SRC_ENV_HEADER, TC_SRC_CLI_HEADER
    };
    drv_spec s = spec;
    s.section = watch ? TC_SEC_WATCH : TC_SEC_NONE;
    const char *v;
    int src;
    if (drv_lookup(&s, NULL, &v, &src)) {
        int ok;
        opts->header_mode = (enum tc_header_mode)drv_parse_header(v, &ok);
        if (!ok) {
            drv_value_error("--header", src, "unknown header mode");
        }
    } else if (watch) {
        opts->header_mode = TC_HDR_COMPACT;
        src = TC_SRC_DEFAULT_UNDER_WATCH;
    } else {
        opts->header_mode = TC_HDR_FULL;
        src = TC_SRC_DEFAULT;
    }
    opts->src[TC_SET_HEADER] = src;
}

static void drv_resolve_sort(tc_opts *opts) {
    static const drv_spec spec = {
        TC_SET_SORT, "sort", TC_SEC_NONE, "TWITCH_SORT",
        TC_SRC_ENV_SORT, TC_SRC_CLI_SORT
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->sort = (enum tc_metric)drv_parse_sort(v, &ok);
        if (!ok) {
            drv_value_error("--sort", src, "unknown sort");
        }
    } else {
        opts->sort = TC_M_COUNT;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_SORT] = src;
}

static void drv_resolve_state(tc_opts *opts) {
    if (opts->src[TC_SET_STATE] == TC_SRC_CLI_LIVE
        || opts->src[TC_SET_STATE] == TC_SRC_CLI_OFFLINE
        || opts->src[TC_SET_STATE] == TC_SRC_CLI_UNKNOWN) {
        return;
    }
    static const drv_spec spec = {
        TC_SET_STATE, "state", TC_SEC_NONE, "TWITCH_STATE",
        TC_SRC_ENV_STATE, TC_SRC_CLI_LIVE
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->state_filter = (enum tc_state)drv_parse_state(v, &ok);
        if (!ok) {
            drv_value_error("--live", src, "unknown chat state");
        }
    } else {
        opts->state_filter = TC_ST_NONE;
        src = TC_SRC_DEFAULT;
    }
    opts->src[TC_SET_STATE] = src;
}

static void drv_resolve_users_policy(tc_opts *opts) {
    static const drv_spec spec = {
        TC_SET_USERS_POLICY, "users_policy", TC_SEC_NONE, "TWITCH_USERS_POLICY",
        TC_SRC_ENV_USERS_POLICY, TC_SRC_CLI_USERS_POLICY
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        if (drv_ascii_casecmp(v, "at-least") == 0) {
            opts->users_policy = TC_POLICY_AT_LEAST;
            ok = 1;
        } else if (drv_ascii_casecmp(v, "at-most") == 0) {
            opts->users_policy = TC_POLICY_AT_MOST;
            ok = 1;
        } else if (drv_ascii_casecmp(v, "nearest") == 0) {
            opts->users_policy = TC_POLICY_NEAREST;
            ok = 1;
        } else {
            ok = 0;
        }
        if (!ok) {
            drv_value_error("--users-policy", src, "unknown --users-policy");
        }
    } else {
        opts->users_policy = TC_POLICY_AT_LEAST;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_USERS_POLICY] = src;
}

static void drv_resolve_users_max(tc_opts *opts) {
    static const drv_spec spec = {
        TC_SET_USERS_MAX, "users_max", TC_SEC_NONE, "TWITCH_USERS_MAX",
        TC_SRC_ENV_USERS_MAX, TC_SRC_CLI_USERS_MAX
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->users_max = drv_parse_int(v, &ok);
        if (!ok) {
            drv_value_error("--users-max", src, "unrecognized duration");
        }
    } else {
        opts->users_max = 86400;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_USERS_MAX] = src;
}

static void drv_resolve_interval(tc_opts *opts) {
    if (opts->flags & TC_F_WATCH_VALUE) {
        return;                       /* --watch SECONDS parsed already */
    }
    int watch = (opts->flags & TC_F_WATCH_PRESENT) != 0;
    static const drv_spec spec = {
        TC_SET_INTERVAL, "interval", TC_SEC_NONE, "TWITCH_WATCH_INTERVAL",
        TC_SRC_ENV_WATCH_INTERVAL, TC_SRC_CLI_WATCH
    };
    drv_spec s = spec;
    s.section = watch ? TC_SEC_WATCH : TC_SEC_NONE;
    const char *v;
    int src;
    if (drv_lookup(&s, NULL, &v, &src)) {
        int ok;
        opts->interval = drv_parse_double(v, &ok);
        if (!ok) {
            drv_value_error("--watch", src, "is not a number of seconds");
        }
    } else {
        opts->interval = 1.0;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_INTERVAL] = src;
}

static void drv_resolve_hold(tc_opts *opts) {
    int watch = (opts->flags & TC_F_WATCH_PRESENT) != 0;
    static const drv_spec spec = {
        TC_SET_HOLD, "hold", TC_SEC_NONE, "TWITCH_WATCH_HOLD",
        TC_SRC_ENV_WATCH_HOLD, TC_SRC_CLI_WATCH_HOLD
    };
    drv_spec s = spec;
    s.section = watch ? TC_SEC_WATCH : TC_SEC_NONE;
    const char *v;
    int src;
    if (drv_lookup(&s, NULL, &v, &src)) {
        int ok;
        opts->hold = drv_parse_double(v, &ok);
        if (!ok) {
            drv_value_error("--watch-hold", src, "is not a number of seconds");
        }
    } else {
        opts->hold = 3.0;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_HOLD] = src;
}

static void drv_resolve_shades(tc_opts *opts) {
    int watch = (opts->flags & TC_F_WATCH_PRESENT) != 0;
    static const drv_spec spec = {
        TC_SET_SHADES, "shades", TC_SEC_NONE, "TWITCH_WATCH_SHADES",
        TC_SRC_ENV_WATCH_SHADES, TC_SRC_CLI_WATCH
    };
    drv_spec s = spec;
    s.section = watch ? TC_SEC_WATCH : TC_SEC_NONE;
    const char *v;
    int src;
    if (drv_lookup(&s, NULL, &v, &src)) {
        int ok;
        opts->shades = drv_parse_int(v, &ok);
        if (!ok) {
            drv_value_error("watch.shades", src, "is not an integer");
        }
    } else {
        opts->shades = 3;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_SHADES] = src;
}

static void drv_resolve_user_width(tc_opts *opts) {
    int watch = (opts->flags & TC_F_WATCH_PRESENT) != 0;
    static const drv_spec spec = {
        TC_SET_USER_WIDTH, "user_width", TC_SEC_NONE, "TWITCH_WATCH_USER_WIDTH",
        TC_SRC_ENV_WATCH_USER_WIDTH, TC_SRC_CLI_WATCH
    };
    drv_spec s = spec;
    s.section = watch ? TC_SEC_WATCH : TC_SEC_NONE;
    const char *v;
    int src;
    if (drv_lookup(&s, NULL, &v, &src)) {
        int ok;
        opts->user_width = drv_parse_int(v, &ok);
        if (!ok) {
            drv_value_error("watch.user_width", src, "is not an integer");
        }
    } else {
        opts->user_width = 20;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_USER_WIDTH] = src;
}

static void drv_resolve_fade_up(tc_opts *opts) {
    int watch = (opts->flags & TC_F_WATCH_PRESENT) != 0;
    static const drv_spec spec = {
        TC_SET_FADE_UP, "fade_up", TC_SEC_NONE, "TWITCH_WATCH_FADE_UP",
        TC_SRC_ENV_WATCH_FADE_UP, TC_SRC_CLI_WATCH
    };
    drv_spec s = spec;
    s.section = watch ? TC_SEC_WATCH : TC_SEC_NONE;
    const char *v;
    int src;
    if (drv_lookup(&s, NULL, &v, &src)) {
        snprintf(opts->fade_up_raw, sizeof(opts->fade_up_raw), "%s", v);
    } else {
        snprintf(opts->fade_up_raw, sizeof(opts->fade_up_raw), "#87ff87");
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_FADE_UP] = src;
}

static void drv_resolve_notify(tc_opts *opts) {
    static const drv_spec spec = {
        TC_SET_NOTIFY, "notify", TC_SEC_TAIL, "TWITCH_TAIL_NOTIFY",
        TC_SRC_ENV_TAIL_NOTIFY, TC_SRC_CLI_WATCH
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->notify = drv_parse_bool(v, &ok);
        if (!ok) {
            drv_value_error("tail.notify", src, "expected true or false");
        }
    } else {
        opts->notify = 1;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_NOTIFY] = src;
}

static void drv_resolve_max_events(tc_opts *opts) {
    static const drv_spec spec = {
        TC_SET_MAX_EVENTS, "max_events", TC_SEC_TAIL, "TWITCH_TAIL_MAX_EVENTS",
        TC_SRC_ENV_TAIL_MAX_EVENTS, TC_SRC_CLI_WATCH
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->max_events = drv_parse_int(v, &ok);
        if (!ok) {
            drv_value_error("tail.max_events", src, "is not an integer");
        }
    } else {
        opts->max_events = 4;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_MAX_EVENTS] = src;
}

static void drv_resolve_seed_lookback(tc_opts *opts) {
    static const drv_spec spec = {
        TC_SET_SEED_LOOKBACK, "seed_lookback", TC_SEC_TAIL,
        "TWITCH_TAIL_SEED_LOOKBACK", TC_SRC_ENV_TAIL_SEED_LOOKBACK,
        TC_SRC_CLI_WATCH
    };
    const char *v;
    int src;
    if (drv_lookup(&spec, NULL, &v, &src)) {
        int ok;
        opts->seed_lookback = drv_parse_int(v, &ok);
        if (!ok) {
            drv_value_error("tail.seed_lookback", src, "is not an integer");
        }
    } else {
        opts->seed_lookback = 30;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    opts->src[TC_SET_SEED_LOOKBACK] = src;
}

static void drv_resolve_broadcaster(tc_opts *opts) {
    if (opts->flags & TC_F_EXCLUDE_BCAST) {
        return;                       /* CLI already resolved */
    }
    const char *v;
    int src;
    if (tc_env_get("TWITCH_EXCLUDE_BROADCASTER", &v)) {
        int ok;
        opts->excl_bcast_val = drv_parse_bool(v, &ok);
        if (!ok) {
            drv_value_error("--exclude-broadcaster", TC_SRC_ENV_EXCLUDE_BCAST,
                            "expected true or false");
        }
        opts->src[TC_SET_EXCLUDE_BCAST] = TC_SRC_ENV_EXCLUDE_BCAST;
        return;
    }
    if (tc_config_get("exclude_broadcaster", TC_SEC_NONE, &v, &src)) {
        int ok;
        opts->excl_bcast_val = drv_parse_bool(v, &ok);
        if (!ok) {
            drv_value_error("--exclude-broadcaster", src,
                            "expected true or false");
        }
        opts->src[TC_SET_EXCLUDE_BCAST] = src;
        return;
    }
    opts->excl_bcast_val = 0;
    opts->src[TC_SET_EXCLUDE_BCAST] = TC_SRC_DEFAULT;
}

static void drv_resolve_window(tc_opts *opts, tc_window *win) {
    if (opts->flags & TC_F_END_GIVEN) {
        if (!drv_parse_datetime(opts->end_raw, 1, &win->end_ymd,
                                &win->end_sod)) {
            char buf[160];
            snprintf(buf, sizeof(buf),
                     "argument --end: unrecognized datetime '%s'", opts->end_raw);
            drv_arg_error(buf);
        }
        opts->src[TC_SET_END] = TC_SRC_CLI_END;
    } else {
        const char *v;
        int src;
        if (tc_env_get("TWITCH_END", &v)) {
            if (!drv_parse_datetime(v, 1, &win->end_ymd, &win->end_sod)) {
                drv_value_error("--end", TC_SRC_ENV_END, "unrecognized datetime");
            }
            src = TC_SRC_ENV_END;
        } else if (tc_config_get("end", TC_SEC_NONE, &v, &src)
                   && drv_parse_datetime(v, 1, &win->end_ymd, &win->end_sod)) {
            /* config end, parsed */
        } else {
            /* default: now — the harness always passes --end, so the exact
               wall-clock value is never observable here. */
            win->end_ymd = 0;
            win->end_sod = 0;
            src = TC_SRC_DEFAULT_NOW;
        }
        opts->src[TC_SET_END] = src;
    }
    if (opts->flags & TC_F_BEGIN_GIVEN) {
        if (!drv_parse_datetime(opts->begin_raw, 0, &win->begin_ymd,
                                &win->begin_sod)) {
            char buf[160];
            snprintf(buf, sizeof(buf),
                     "argument --begin: unrecognized datetime '%s'",
                     opts->begin_raw);
            drv_arg_error(buf);
        }
        win->start_source = "--begin";
        opts->src[TC_SET_BEGIN] = TC_SRC_CLI_BEGIN;
        win->kind = TC_WIN_BEGIN;
    } else {
        win->start_source = "default";
        win->kind = TC_WIN_EARLIEST;
    }
}

static void drv_resolve_all(tc_opts *opts, tc_window *win) {
    drv_resolve_logs_dir(opts);
    drv_resolve_min_count(opts);
    drv_resolve_top(opts);
    drv_resolve_header(opts);
    drv_resolve_sort(opts);
    drv_resolve_state(opts);
    drv_resolve_users_policy(opts);
    drv_resolve_users_max(opts);
    drv_resolve_interval(opts);
    drv_resolve_hold(opts);
    drv_resolve_shades(opts);
    drv_resolve_user_width(opts);
    drv_resolve_fade_up(opts);
    drv_resolve_notify(opts);
    drv_resolve_max_events(opts);
    drv_resolve_seed_lookback(opts);
    drv_resolve_broadcaster(opts);
    drv_resolve_window(opts, win);
}

// ----------------------------------------------------------------------------
// The stable dump.
// ----------------------------------------------------------------------------
static void drv_print(const tc_opts *opts, const tc_window *win,
                      const tc_excl_set *set) {
    printf("channel=%s\n", opts->channel);
    if (opts->src[TC_SET_CHANNEL] == TC_SRC_DYN_ALIAS) {
        printf("chan_src=%s\n", opts->chan_src);
    } else {
        printf("chan_src=%s\n", drv_src_label(opts->src[TC_SET_CHANNEL]));
    }
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_LOGS_DIR]));
    printf("logs_dir=%s\n", opts->logs_dir);
    printf("config=%s\n", opts->config_path);
    printf("config_loaded=%d\n", opts->config_loaded);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_MIN_COUNT]));
    printf("min_count=%lld\n", (long long)opts->min_count);
    printf("top=%lld\n", (long long)opts->top);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_HEADER]));
    printf("header=%d\n", (int)opts->header_mode);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_SORT]));
    printf("sort=%d\n", (int)opts->sort);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_STATE]));
    printf("state=%d\n", (int)opts->state_filter);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_USERS_POLICY]));
    printf("users_policy=%d\n", (int)opts->users_policy);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_USERS_MAX]));
    printf("users_max=%lld\n", (long long)opts->users_max);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_END]));
    printf("end=%lld %lld\n", (long long)win->end_ymd, (long long)win->end_sod);
    printf("src=%s\n", win->start_source);
    printf("begin=%lld %lld\n", (long long)win->begin_ymd,
           (long long)win->begin_sod);
    printf("interval=%lld\n", (long long)drv_dbl_bits(opts->interval));
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_INTERVAL]));
    printf("hold=%lld\n", (long long)drv_dbl_bits(opts->hold));
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_HOLD]));
    printf("shades=%lld\n", (long long)opts->shades);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_SHADES]));
    printf("user_width=%lld\n", (long long)opts->user_width);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_USER_WIDTH]));
    printf("fade_up=%s\n", opts->fade_up_raw);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_FADE_UP]));
    printf("notify=%d\n", opts->notify);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_NOTIFY]));
    printf("max_events=%lld\n", (long long)opts->max_events);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_MAX_EVENTS]));
    printf("seed_lookback=%lld\n", (long long)opts->seed_lookback);
    printf("src=%s\n", drv_src_label(opts->src[TC_SET_SEED_LOOKBACK]));
    printf("excl_count=%lld\n", (long long)set->count);
    for (int64_t i = 0; i < set->count; i++) {
        int64_t si = set->entries[i].source_idx;
        printf("excl=%s|src=%.*s\n", set->entries[i].login,
               (int)set->sources[si].len, set->sources[si].ptr);
    }
    printf("excl_sources=");
    for (int64_t i = 0; i < tc_excl_src_count; i++) {
        if (i > 0) {
            printf(", ");
        }
        printf("%.*s", (int)set->sources[i].len, set->sources[i].ptr);
    }
    printf("\n");
}

int main(int argc, char **argv) {
    memset(&s_opts, 0, sizeof(s_opts));
    memset(&s_win, 0, sizeof(s_win));
    memset(&s_set, 0, sizeof(s_set));
    drv_parse_args(argc, argv, &s_opts);
    /* First pass: register the opts and load the config (fail loudly).  The
       no-channel guard is skipped here (the source is TC_SRC_NONE, not
       TC_SRC_DEFAULT) and the alias rewrite runs on whatever -c supplied. */
    tc_aliases_apply(&s_opts);
    drv_resolve_channel(&s_opts);
    /* Second pass: the guard + alias rewrite now that the channel resolved. */
    tc_aliases_apply(&s_opts);
    drv_resolve_all(&s_opts, &s_win);
    tc_build_exclusions(&s_opts, &s_set);
    drv_print(&s_opts, &s_win, &s_set);
    return 0;
}