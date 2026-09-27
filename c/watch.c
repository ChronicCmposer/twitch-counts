// ============================================================================
// watch.c — watch mode and the change-notification watcher seam.
//
//  Byte-for-byte port of the Python reference's watch half:
//    run_watch / resolve_watch / resolve_tail / colorizer / fade_color /
//      palette_chooser / hex_ramp / next_tint_change / watch_status /
//      replay_horizon / replay_tints / launch_tints (3247-3830),
//    TailReader / LiveReaders / count_messages / fold_lines / seek_window /
//      bucket_bounds / seed_stream_state (1309-2003),
//    Screen / PollingWatcher / KqueueWatcher (3462-3608),
//  rendered through the shared render module's frame hooks
//    (tc_frame_begin/end/set_pin/set_tint + tc_plan_presentation +
//     tc_render_text), so the captured lines are byte-identical to the
//  one-shot path under the same settings.
//
//  The watch loop owns its session state explicitly (a tc_wsession threaded
//  through every helper — no hidden mutable globals).  The one exception the
//  fixed render-frame API forces is render.c's s_active_frame seam, which this
//  module drives by arming a tc_frame around each tc_render_text call.
//
//  Highlight rules are matched with vendored PCRE2-8 (compiled at load in
//  UTF+UCP mode so \w/\s follow Python re's Unicode semantics), and the
//  patterns are compiled even under --streamer (a bad pattern is an error);
//  streamer mode only stops them colouring anything.
//
//  Platform seam (matches the Python exactly): kqueue on macOS when
//  [tail] notify is on, polling on Linux — Linux with notify on fails loudly
//  with the Python's TODO message.  The Makefile links libpcre2-8.a; the
//  pcre2.h header lives under the per-platform pcre2 build tree, so it is
//  included by relative path (build/<os>/pcre2-10.48/src/pcre2.h).
// ============================================================================

/* musl exposes the full POSIX set under the default feature set; enable it
   before ANY include (tc_platform.h pulls <time.h> first). */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#define PCRE2_CODE_UNIT_WIDTH 8

#include "tc_platform.h"

#if TC_PLATFORM_MACOS
#include "../build/darwin/pcre2-10.48/src/pcre2.h"
#else
#include "../build/linux/pcre2-10.48/src/pcre2.h"
#endif

#include "../third_party/tomlc99/toml.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#if TC_PLATFORM_MACOS
#include <sys/event.h>
#endif

/* mtime access — same pattern as core.c/config.c (musl exposes st_mtim;
   Apple/Darwin exposes st_mtimespec; glibc hides st_mtim behind feature
   macros). */
#if defined(__APPLE__)
#define TC_ST_MTIME_SEC(s)  ((s).st_mtimespec.tv_sec)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtimespec.tv_nsec)
#elif defined(__GLIBC__) && !defined(_DEFAULT_SOURCE) && !defined(_GNU_SOURCE)
#define TC_ST_MTIME_SEC(s)  ((s).st_mtime)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtimensec)
#else
#define TC_ST_MTIME_SEC(s)  ((s).st_mtim.tv_sec)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtim.tv_nsec)
#endif

// ----------------------------------------------------------------------------
// Constants (defaults mirror the Python Spec table for [watch]/[tail]).
// ----------------------------------------------------------------------------
enum {
    WATCH_LINE_SZ        = 4096,   /* frame line buffer (tint fits inside) */
    WATCH_FRAME_MAX      = 256,    /* captured report lines per frame */
    WATCH_MSG_SZ         = 512,    /* error-message composition buffer */
    WATCH_BUCKET_INIT    = 64,
    WATCH_MATCH_INIT     = 16,
    WATCH_READER_INIT    = 4,
    WATCH_PREV_INIT      = 32,
    WATCH_CARRIED_INIT   = 16,
    WATCH_RAMP_MAX       = TC_HL_MAX + 2,
    WATCH_SEED_LOOKBACK_DEF = 30  /* setting_default("seed_lookback") */
};
#define WATCH_RAMP_UP   0
#define WATCH_RAMP_DOWN 1
#define WATCH_RAMP_HL(i) (2 + (i))

/* The ANSI escape a tinted row is wrapped in (Python ANSI_RESET). */
#define WATCH_ANSI_RESET "\033[0m"

// ----------------------------------------------------------------------------
// Forward declarations (mutual references inside this module).
// ----------------------------------------------------------------------------
typedef struct tc_wsession tc_wsession;

/* The change watcher (kqueue on macOS, polling on Linux).  Opaque to the
   header; this module owns the layout. */
struct tc_watcher {
    int enabled;                    /* 1 = event-driven (kqueue) */
    int max_events;
    int woke_on_write;              /* cumulative, never reset (Python) */
    int woke_on_timer;
#if TC_PLATFORM_MACOS
    int kq;
    int handle_count;
    int handle_cap;
    struct {
        char path[TC_PATH_SZ];
        int fd;
    } *handles;
#endif
};

// ----------------------------------------------------------------------------
// One per-second bucket (Python's buckets dict key).  The sliding window sums
// by scanning and pruning compacts in place, so insertion order is enough.
// ----------------------------------------------------------------------------
typedef struct tc_wbucket {
    int64_t second;
    char login[TC_LOGIN_SZ];
    int state;                      /* TC_ST_LIVE/OFFLINE/UNKNOWN */
    int64_t n;
} tc_wbucket;

/* One highlight match: login said something matching rule `rule` at
   second-of-day `second` (Python's matches dict). */
typedef struct tc_wmatch {
    int64_t second;
    char login[TC_LOGIN_SZ];
    int rule;
} tc_wmatch;

// ----------------------------------------------------------------------------
// A tailed log file (Python TailReader): buckets + matches + the byte offset
// and partial-line remainder that make the incremental read possible.
// ----------------------------------------------------------------------------
typedef struct tc_reader {
    char path[TC_PATH_SZ];
    int64_t ymd;
    tc_wbucket *buckets;
    int64_t bcount, bcap;
    tc_wmatch *matches;
    int64_t mcount, mcap;
    int64_t offset;
    char *remainder;
    size_t rlen, rcap;
    int enter_state;
    int exit_state;
    int64_t dev, ino;               /* file identity (rotation detection) */
    int have_identity;
    int full_reads;
    int appends;
    int partial;                    /* pruned or cold-seeked: not the whole day */
    int64_t revision;
} tc_reader;

// ----------------------------------------------------------------------------
// A compiled highlight rule (the PCRE2-8 side of [[watch.highlight]]).
// curve/k of -1 / -1.0 mean "inherit [watch] fade_curve/fade_k".
// ----------------------------------------------------------------------------
typedef struct tc_hl_compiled {
    uint32_t rgb[3];
    int curve;
    double k;
    int pat_count;
    pcre2_code *codes[TC_HL_PAT_MAX];
    pcre2_match_data *mds[TC_HL_PAT_MAX];
    char source[TC_HL_SRC_SZ];
} tc_hl_compiled;

/* One ramp: `count` escape sequences, freshest first (Python hex_ramp). */
typedef struct tc_ramp {
    int count;
    char **seq;
} tc_ramp;

// ----------------------------------------------------------------------------
// Carried/previous maps for the tint fade (Python colorizer's tints dict and
// the previous frame's counts dict).
// ----------------------------------------------------------------------------
typedef struct tc_tint_entry {
    char login[TC_LOGIN_SZ];
    int dir;                        /* WATCH_RAMP_* */
    double when;                    /* monotonic instant the tint was assigned */
} tc_tint_entry;

typedef struct tc_prev_entry {
    char login[TC_LOGIN_SZ];
    int64_t count;
} tc_prev_entry;

// ----------------------------------------------------------------------------
// The render hook's context (Python colorizer's closure state).
// ----------------------------------------------------------------------------
typedef struct tc_color_ctx {
    tc_prev_entry *prev;            /* previous frame's counts, or NULL */
    int64_t prev_n, prev_cap;
    tc_tint_entry *carried;         /* login -> (direction, when) */
    int64_t carried_n, carried_cap;
    double hold;
    double now;                     /* monotonic instant this frame ages against */
    int enabled;                    /* color_enabled(args) */
    int has_down;                   /* the down ramp exists (tint_falling) */
    double at_wall;                 /* naive-epoch now for the rule ladder */
    tc_wsession *s;
    char out[WATCH_LINE_SZ + 64];   /* the tinted row text (copied by render) */
} tc_color_ctx;

// ----------------------------------------------------------------------------
// The screen (Python Screen): what is painted, so a redraw sends only the
// lines that changed, addressed absolutely.
// ----------------------------------------------------------------------------
typedef struct tc_screen {
    int64_t full_every;
    char **painted;
    int64_t painted_n, painted_cap;
    int width;
    int64_t since_full;
} tc_screen;

// ----------------------------------------------------------------------------
// The watch session — the whole loop's state, threaded explicitly.
// ----------------------------------------------------------------------------
struct tc_wsession {
    const tc_opts *opts;
    const tc_inputs *inputs;

    /* resolved watch/tail knobs */
    double interval;
    double min_interval;
    double hold;
    double min_redraw;
    double fade_k;
    int64_t shades;
    int64_t user_width;
    int64_t full_repaint;
    int64_t replay_steps;
    int streamer_mode;
    int show_timing;
    int tint_falling;
    int fade_curve;
    char fade_curve_name[16];
    int notify;
    int64_t max_events;
    int64_t seed_lookback;
    uint32_t fade_up[3];
    uint32_t fade_down[3];

    /* highlight rules + ramps */
    int hl_active;
    int hl_count;
    tc_hl_compiled highlights[TC_HL_MAX];
    tc_ramp ramps[WATCH_RAMP_MAX];
    int ramp_count;

    /* the window (re-derived every frame) */
    int64_t begin_ymd, begin_sod;
    int64_t end_ymd, end_sod;
    int begin_rolls;
    int win_kind;
    const char *start_source;
    int64_t users_width, users_req, users_found;

    /* dated-log listing, memoized on the directory mtime */
    tc_listing listing;
    int64_t listing_mtime;
    int listing_valid;

    /* tail readers */
    tc_reader *readers;
    int64_t reader_count, reader_cap;
    int64_t retain_seconds;
    int64_t match_seconds;

    /* rollup cache (one connection for the session) */
    tc_cache *cache;
    const char *cache_problem;
    char cache_path[TC_PATH_SZ];

    /* per-frame tables (entries reused across frames) */
    tc_users users;
    tc_tally tally;
    tc_selection selection;
    tc_context context;
    tc_report report;
    tc_users day_users;
    tc_tally day_tally;

    /* the frame capture + tint state */
    tc_frame frame;
    char **frame_lines;
    int64_t frame_max;
    tc_color_ctx color;

    /* the screen and the watcher */
    tc_screen screen;
    tc_watcher *watcher;

    /* SIGINT latch */
    int interrupted;
};

static volatile sig_atomic_t g_watch_interrupted;

// ----------------------------------------------------------------------------
// Clock helpers (Python clock.monotonic / time.sleep).
// ----------------------------------------------------------------------------
static double watch_monotonic(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void watch_sleep(double seconds) {
    struct timespec req;
    struct timespec rem;
    if (seconds <= 0.0) {
        return;
    }
    req.tv_sec = (time_t)seconds;
    req.tv_nsec = (long)((seconds - (double)req.tv_sec) * 1000000000.0);
    while (nanosleep(&req, &rem) != 0 && errno == EINTR && !g_watch_interrupted) {
        req = rem;
    }
}

// ----------------------------------------------------------------------------
// Failure helpers.
// ----------------------------------------------------------------------------
static void watch_fail(const tc_wsession *s, const char *msg) {
    if (s != NULL && s->opts != NULL && (s->opts->flags & TC_F_JSON)) {
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
        exit(TC_EXIT_ERROR);
    }
    tc_fail(msg);
}

/* Python source_label(flag, setting): "flag" when the value came from the
   flag itself, else "flag (from <source>)". */
static const char *watch_source_label(char *buf, size_t cap,
                                      const char *flag, int src) {
    const char *label = tc_source_str(src);
    if (label != NULL && strcmp(label, flag) == 0) {
        return flag;
    }
    snprintf(buf, cap, "%s (from %s)", flag,
             label != NULL ? label : "unknown");
    return buf;
}

// ----------------------------------------------------------------------------
// Setting resolution (Python resolve() for the [watch]/[tail] tables):
//   env TWITCH_WATCH_*  >  config [watch]  >  top-level key  >  default.
// Returns 1 with the value+source when a value was found, 0 for the default.
// ----------------------------------------------------------------------------
static int watch_resolve(const tc_wsession *s, const char *env_name,
                         const char *key, int section, int env_src,
                         const char **value_out, int *src_out) {
    const char *v = NULL;
    (void)s;
    if (tc_env_get(env_name, &v) && v != NULL && v[0] != '\0') {
        *value_out = v;
        *src_out = env_src;
        return 1;
    }
    if (tc_config_get(key, section, &v, src_out) && v != NULL
        && v[0] != '\0') {
        *value_out = v;
        return 1;
    }
    *value_out = NULL;
    *src_out = TC_SRC_DEFAULT_BUILTIN;
    return 0;
}

static void watch_resolve_double(tc_wsession *s, const char *env_name,
                                 const char *key, int section, int env_src,
                                 double default_value, double *out) {
    const char *v;
    int src;
    char msg[WATCH_MSG_SZ];
    if (!watch_resolve(s, env_name, key, section, env_src, &v, &src)) {
        *out = default_value;
        return;
    }
    {
        char *end = NULL;
        double val = strtod(v, &end);
        if (end == v || *end != '\0') {
            snprintf(msg, sizeof(msg), "%s: %s is not a number of seconds",
                     tc_source_str(src), v);
            watch_fail(s, msg);
        }
        *out = val;
    }
}

static void watch_resolve_int(tc_wsession *s, const char *env_name,
                              const char *key, int section, int env_src,
                              int64_t default_value, int64_t *out) {
    const char *v;
    int src;
    char msg[WATCH_MSG_SZ];
    if (!watch_resolve(s, env_name, key, section, env_src, &v, &src)) {
        *out = default_value;
        return;
    }
    {
        char *end = NULL;
        long long val = strtoll(v, &end, 10);
        if (end == v || *end != '\0') {
            snprintf(msg, sizeof(msg), "%s: %s is not an integer",
                     tc_source_str(src), v);
            watch_fail(s, msg);
        }
        *out = (int64_t)val;
    }
}

static void watch_resolve_bool(tc_wsession *s, const char *env_name,
                               const char *key, int section, int env_src,
                               int default_value, int *out) {
    const char *v;
    int src;
    int ok;
    char msg[WATCH_MSG_SZ];
    if (!watch_resolve(s, env_name, key, section, env_src, &v, &src)) {
        *out = default_value;
        return;
    }
    if (!tc_parse_bool(v, &ok)) {
        /* 0 is a valid value ("false"); only a failed parse is an error */
        if (!ok) {
            snprintf(msg, sizeof(msg), "%s: %s is not a boolean",
                     tc_source_str(src), v);
            watch_fail(s, msg);
        }
        *out = 0;
        return;
    }
    *out = 1;
}

static void watch_resolve_hex(tc_wsession *s, const char *env_name,
                              const char *key, int section, int env_src,
                              const char *default_value, uint32_t rgb[3]) {
    const char *v;
    int src;
    int ok;
    int64_t packed;
    char msg[WATCH_MSG_SZ];
    if (!watch_resolve(s, env_name, key, section, env_src, &v, &src)) {
        v = default_value;
        src = TC_SRC_DEFAULT_BUILTIN;
    }
    packed = tc_parse_hex_colour(v, &ok);
    if (!ok) {
        snprintf(msg, sizeof(msg), "%s: %s is not a hex colour like '#0000ff'",
                 tc_source_str(src), v);
        watch_fail(s, msg);
    }
    rgb[0] = (uint32_t)((packed >> 16) & 0xFF);
    rgb[1] = (uint32_t)((packed >> 8) & 0xFF);
    rgb[2] = (uint32_t)(packed & 0xFF);
}

static void watch_resolve_curve(tc_wsession *s, const char *env_name,
                                const char *key, int section, int env_src,
                                int *curve_out, char *name_out,
                                size_t name_cap) {
    const char *v;
    int src;
    int ok;
    char msg[WATCH_MSG_SZ];
    if (!watch_resolve(s, env_name, key, section, env_src, &v, &src)) {
        v = "linear";
    }
    {
        int id = tc_parse_curve(v, &ok);
        if (!ok) {
            snprintf(msg, sizeof(msg),
                     "%s: unknown fade curve %s (choose from: bias, ease-in-out, "
                     "ease-out, linear, power)",
                     tc_source_str(src), v);
            watch_fail(s, msg);
        }
        *curve_out = id;
    }
    tc_copy_str_cap(name_out, v, name_cap);
}

/* The resolved watch knobs (Python resolve_watch; the CLI already resolved
   interval and hold, so those are read from opts). */
static void watch_resolve_settings(tc_wsession *s) {
    tc_opts *opts = (tc_opts *)s->opts;

    watch_resolve_double(s, "TWITCH_WATCH_MIN_INTERVAL", "min_interval",
                         TC_SEC_WATCH, TC_SRC_ENV_WATCH_MIN_INTERVAL, 0.1,
                         &s->min_interval);
    watch_resolve_int(s, "TWITCH_WATCH_SHADES", "shades", TC_SEC_WATCH,
                      TC_SRC_ENV_WATCH_SHADES, 3, &s->shades);
    watch_resolve_hex(s, "TWITCH_WATCH_FADE_UP", "fade_up", TC_SEC_WATCH,
                      TC_SRC_ENV_WATCH_FADE_UP, "#87ff87", s->fade_up);
    watch_resolve_hex(s, "TWITCH_WATCH_FADE_DOWN", "fade_down", TC_SEC_WATCH,
                      TC_SRC_ENV_WATCH_FADE_DOWN, "#8a8a8a", s->fade_down);
    watch_resolve_int(s, "TWITCH_WATCH_USER_WIDTH", "user_width", TC_SEC_WATCH,
                      TC_SRC_ENV_WATCH_USER_WIDTH, 20, &s->user_width);
    watch_resolve_int(s, "TWITCH_WATCH_FULL_REPAINT", "full_repaint",
                      TC_SEC_WATCH, TC_SRC_ENV_WATCH_FULL_REPAINT, 50,
                      &s->full_repaint);
    if (!(opts->flags & TC_F_STREAMER)) {
        watch_resolve_bool(s, "TWITCH_WATCH_STREAMER_MODE", "streamer_mode",
                           TC_SEC_WATCH, TC_SRC_ENV_WATCH_STREAMER_MODE, 0,
                           &s->streamer_mode);
    } else {
        s->streamer_mode = opts->streamer_mode;
    }
    watch_resolve_double(s, "TWITCH_WATCH_MIN_REDRAW", "min_redraw",
                         TC_SEC_WATCH, TC_SRC_ENV_WATCH_MIN_REDRAW, 0.25,
                         &s->min_redraw);
    watch_resolve_bool(s, "TWITCH_WATCH_SHOW_TIMING", "show_timing",
                       TC_SEC_WATCH, TC_SRC_ENV_WATCH_SHOW_TIMING, 0,
                       &s->show_timing);
    watch_resolve_bool(s, "TWITCH_WATCH_TINT_FALLING", "tint_falling",
                       TC_SEC_WATCH, TC_SRC_ENV_WATCH_TINT_FALLING, 1,
                       &s->tint_falling);
    watch_resolve_curve(s, "TWITCH_WATCH_FADE_CURVE", "fade_curve",
                        TC_SEC_WATCH, TC_SRC_ENV_WATCH_FADE_CURVE,
                        &s->fade_curve, s->fade_curve_name,
                        sizeof(s->fade_curve_name));
    watch_resolve_double(s, "TWITCH_WATCH_FADE_K", "fade_k", TC_SEC_WATCH,
                         TC_SRC_ENV_WATCH_FADE_K, 1.0, &s->fade_k);
    watch_resolve_int(s, "TWITCH_WATCH_REPLAY_STEPS", "replay_steps",
                      TC_SEC_WATCH, TC_SRC_ENV_WATCH_REPLAY_STEPS, 200,
                      &s->replay_steps);

    /* interval: the CLI stores -1.0 ("from config") when --watch carried no
       number, exactly like Python's WATCH_FROM_CONFIG sentinel. */
    if (opts->interval == TC_WATCH_FROM_CONFIG_VALUE) {
        const char *v;
        int src;
        if (watch_resolve(s, "TWITCH_WATCH_INTERVAL", "interval",
                          TC_SEC_WATCH, TC_SRC_ENV_WATCH_INTERVAL, &v, &src)) {
            char *end = NULL;
            double val = strtod(v, &end);
            if (end == v || *end != '\0') {
                char msg[WATCH_MSG_SZ];
                snprintf(msg, sizeof(msg), "%s: %s is not a number of seconds",
                         tc_source_str(src), v);
                watch_fail(s, msg);
            }
            opts->interval = val;
            opts->src[TC_SET_INTERVAL] = src;
        } else {
            opts->interval = 1.0;
            opts->src[TC_SET_INTERVAL] = TC_SRC_DEFAULT_BUILTIN;
        }
    }
    s->interval = opts->interval;
    s->hold = opts->hold;

    /* interval floor (Python resolve_watch's ConfigError) */
    if (s->interval < s->min_interval) {
        const char *min_src_str = NULL;
        int min_src = TC_SRC_DEFAULT_BUILTIN;
        char buf[WATCH_MSG_SZ];
        char msg[WATCH_MSG_SZ];
        const char *iv = watch_source_label(
            buf, sizeof(buf), "--watch", opts->src[TC_SET_INTERVAL]);
        (void)watch_resolve(s, "TWITCH_WATCH_MIN_INTERVAL", "min_interval",
                            TC_SEC_WATCH, TC_SRC_ENV_WATCH_MIN_INTERVAL,
                            &min_src_str, &min_src);
        snprintf(msg, sizeof(msg),
                 "%s: interval must be at least %gs (%s)", iv,
                 s->min_interval,
                 watch_source_label(buf, sizeof(buf), "watch.min_interval",
                                    min_src));
        watch_fail(s, msg);
    }
}

/* The resolved tail settings (Python resolve_tail). */
static void watch_resolve_tail(tc_wsession *s) {
    watch_resolve_bool(s, "TWITCH_TAIL_NOTIFY", "notify", TC_SEC_TAIL,
                       TC_SRC_ENV_TAIL_NOTIFY, 1, &s->notify);
    watch_resolve_int(s, "TWITCH_TAIL_MAX_EVENTS", "max_events", TC_SEC_TAIL,
                      TC_SRC_ENV_TAIL_MAX_EVENTS, 4, &s->max_events);
    watch_resolve_int(s, "TWITCH_TAIL_SEED_LOOKBACK", "seed_lookback",
                      TC_SEC_TAIL, TC_SRC_ENV_TAIL_SEED_LOOKBACK, 30,
                      &s->seed_lookback);
}

// ----------------------------------------------------------------------------
// Ramp construction (Python hex_ramp + the CURVES table).  Each curve is the
// identity at k=1.  Channel rounding uses Python round()'s half-even rule so
// the escape sequences are byte-identical.
// ----------------------------------------------------------------------------
static double watch_curve_bend(int curve, double x, double k) {
    switch (curve) {
    case TC_CURVE_POWER:
        return pow(x, k);
    case TC_CURVE_EASE_OUT:
        return 1.0 - pow(1.0 - x, k);
    case TC_CURVE_BIAS:
        return x / (k * (1.0 - x) + x);
    case TC_CURVE_EASE_IN_OUT:
        if (x > 0.0 && x < 1.0) {
            double a = pow(x, k);
            double b = pow(1.0 - x, k);
            return a / (a + b);
        }
        return x;
    default:                        /* linear */
        return x;
    }
}

static long watch_round_half_even(double x) {
    double f = floor(x);
    double diff = x - f;
    if (diff < 0.5) {
        return (long)f;
    }
    if (diff > 0.5) {
        return (long)(f + 1.0);
    }
    return fmod(f, 2.0) == 0.0 ? (long)f : (long)(f + 1.0);
}

static void watch_ramp_free(tc_ramp *ramp) {
    int i;
    for (i = 0; i < ramp->count; i++) {
        free(ramp->seq[i]);
    }
    free(ramp->seq);
    ramp->seq = NULL;
    ramp->count = 0;
}

/* Python hex_ramp(rgb, steps, curve, k): `count` escape sequences, freshest
   first. */
static void watch_hex_ramp(tc_ramp *ramp, const uint32_t rgb[3],
                           int64_t steps, int curve, double k) {
    int64_t n = steps > 1 ? steps : 1;
    int64_t i;
    ramp->count = 0;
    ramp->seq = malloc((size_t)n * sizeof(char *));
    if (ramp->seq == NULL) {
        tc_fail("out of memory");
    }
    for (i = 0; i < n; i++) {
        double x = (double)i / (double)n;
        double towards = watch_curve_bend(curve, x, k);
        long r = watch_round_half_even(
            (double)rgb[0] + (255.0 - (double)rgb[0]) * towards);
        long g = watch_round_half_even(
            (double)rgb[1] + (255.0 - (double)rgb[1]) * towards);
        long b = watch_round_half_even(
            (double)rgb[2] + (255.0 - (double)rgb[2]) * towards);
        char buf[48];
        if (r < 0) { r = 0; }
        if (r > 255) { r = 255; }
        if (g < 0) { g = 0; }
        if (g > 255) { g = 255; }
        if (b < 0) { b = 0; }
        if (b > 255) { b = 255; }
        snprintf(buf, sizeof(buf), "\033[38;2;%ld;%ld;%ldm", r, g, b);
        ramp->seq[ramp->count] = malloc(strlen(buf) + 1);
        if (ramp->seq[ramp->count] == NULL) {
            tc_fail("out of memory");
        }
        strcpy(ramp->seq[ramp->count], buf);
        ramp->count++;
    }
}

static int watch_ramp_collapses(const tc_ramp *ramp) {
    int i;
    if (ramp->count < 2) {
        return 0;
    }
    for (i = 1; i < ramp->count; i++) {
        if (strcmp(ramp->seq[i], ramp->seq[0]) != 0) {
            return 0;
        }
    }
    return 1;
}

/* Python resolve_watch's ramp build + the degenerate-collapse refusal. */
static void watch_build_ramps(tc_wsession *s) {
    int i;

    watch_hex_ramp(&s->ramps[WATCH_RAMP_UP], s->fade_up, s->shades,
                   s->fade_curve, s->fade_k);
    if (s->tint_falling) {
        watch_hex_ramp(&s->ramps[WATCH_RAMP_DOWN], s->fade_down, s->shades,
                       s->fade_curve, s->fade_k);
    }
    if (s->hl_active) {
        for (i = 0; i < s->hl_count && WATCH_RAMP_HL(i) < WATCH_RAMP_MAX;
             i++) {
            const tc_hl_compiled *hl = &s->highlights[i];
            int curve = hl->curve < 0 ? s->fade_curve : hl->curve;
            double k = hl->k < 0.0 ? s->fade_k : hl->k;
            watch_hex_ramp(&s->ramps[WATCH_RAMP_HL(i)], hl->rgb, s->shades,
                           curve, k);
        }
    }
    s->ramp_count = (s->tint_falling ? WATCH_RAMP_DOWN + 1 : WATCH_RAMP_UP + 1)
                    + (s->hl_active ? s->hl_count : 0);

    /* a ramp of many shades that renders as one colour is refused (Python's
       "collapse" check) — the fade would silently do nothing. */
    if (s->shades > 1) {
        char hl_name[TC_HL_MAX][24];
        const char *names[WATCH_RAMP_MAX];
        int ni = 0;
        char msg[WATCH_MSG_SZ];
        names[ni++] = "up";
        if (s->tint_falling) {
            names[ni++] = "down";
        }
        for (i = 0; i < s->hl_count && s->hl_active && ni < WATCH_RAMP_MAX;
             i++) {
            snprintf(hl_name[i], sizeof(hl_name[i]), "highlight%d", i);
            names[ni++] = hl_name[i];
        }
        for (i = 0; i < ni; i++) {
            if (watch_ramp_collapses(&s->ramps[WATCH_RAMP_UP + i])) {
                snprintf(msg, sizeof(msg),
                         "watch.fade_curve '%s' with fade_k %.6g collapses "
                         "the %s ramp to a single colour -- lower k, or raise "
                         "watch.shades",
                         s->fade_curve_name, s->fade_k, names[i]);
                watch_fail(s, msg);
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Highlight parsing (Python parse_highlights) via a fresh tomlc99 parse of
// the already-validated config file (config.c keeps its parsed root private).
// PCRE2 is compiled in UTF+UCP mode so \w/\s follow Python re's Unicode
// semantics ("keysé" must not match "(?i)keys[^\w\s]*(?!\S)").
// ----------------------------------------------------------------------------
static char *watch_toml_unquote(const char *raw) {
    char *unquoted = NULL;
    if (raw[0] == '"' || raw[0] == '\'') {
        if (toml_rtos(raw, &unquoted) == 0 && unquoted != NULL) {
            return unquoted;
        }
        if (unquoted != NULL) {
            free(unquoted);
        }
        return NULL;
    }
    return strdup(raw);
}

/* Compile one pattern into the rule; fails loudly on a bad regex (Python:
   "rule {index}: {pattern!r} is not a valid regex ({exc})"). */
static void watch_hl_compile(tc_wsession *s, tc_hl_compiled *hl, int rule_idx,
                             const char *pattern) {
    pcre2_code *code;
    pcre2_match_data *md;
    int errcode;
    PCRE2_SIZE erroff;
    char msg[WATCH_MSG_SZ];

    if (hl->pat_count >= TC_HL_PAT_MAX) {
        return;
    }
    code = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED,
                         PCRE2_UTF | PCRE2_UCP, &errcode, &erroff, NULL);
    if (code == NULL) {
        PCRE2_UCHAR ebuf[128];
        pcre2_get_error_message(errcode, ebuf, sizeof(ebuf));
        snprintf(msg, sizeof(msg), "rule %d: %s is not a valid regex (%s)",
                 rule_idx, pattern, (const char *)ebuf);
        watch_fail(s, msg);
    }
    md = pcre2_match_data_create_from_pattern(code, NULL);
    hl->codes[hl->pat_count] = code;
    hl->mds[hl->pat_count] = md;
    hl->pat_count++;
}

static void watch_parse_highlights(tc_wsession *s) {
    const char *path = s->inputs->config_path;
    toml_table_t *root = NULL;
    toml_table_t *watch_tab = NULL;
    toml_array_t *hl_arr = NULL;
    FILE *f;
    char errbuf[128];
    int n;
    int i;

    s->hl_count = 0;
    if (!s->opts->config_loaded || path == NULL || path[0] == '\0') {
        return;
    }
    f = fopen(path, "rb");
    if (f == NULL) {
        return;                     /* the config loaded earlier; cannot re-read */
    }
    root = toml_parse_file(f, errbuf, sizeof(errbuf));
    fclose(f);
    if (root == NULL) {
        return;
    }
    watch_tab = toml_table_in(root, "watch");
    if (watch_tab == NULL) {
        toml_free(root);
        return;
    }
    hl_arr = toml_array_in(watch_tab, "highlight");
    if (hl_arr == NULL) {
        toml_free(root);
        return;
    }
    n = toml_array_nelem(hl_arr);
    if (n > TC_HL_MAX) {
        n = TC_HL_MAX;
    }
    for (i = 0; i < n; i++) {
        toml_table_t *rule = toml_table_at(hl_arr, i);
        const char *color_raw;
        toml_array_t *match_arr;
        const char *match_raw;
        const char *curve_raw;
        const char *k_raw;
        tc_hl_compiled *hl = &s->highlights[s->hl_count];
        char msg[WATCH_MSG_SZ];
        int ok;
        int64_t packed;
        int p;

        memset(hl, 0, sizeof(*hl));
        hl->curve = -1;
        hl->k = -1.0;

        if (rule == NULL) {
            snprintf(msg, sizeof(msg),
                     "rule %d: expected a table with `color` and `match`", i);
            watch_fail(s, msg);
        }
        color_raw = toml_raw_in(rule, "color");
        match_raw = toml_raw_in(rule, "match");
        match_arr = toml_array_in(rule, "match");
        if (color_raw == NULL || (match_raw == NULL && match_arr == NULL)) {
            snprintf(msg, sizeof(msg),
                     "rule %d: needs both `color` and `match`", i);
            watch_fail(s, msg);
        }
        {
            char *color = watch_toml_unquote(color_raw);
            if (color == NULL) {
                snprintf(msg, sizeof(msg),
                         "rule %d: needs both `color` and `match`", i);
                watch_fail(s, msg);
            }
            packed = tc_parse_hex_colour(color, &ok);
            if (!ok) {
                snprintf(msg, sizeof(msg), "%s is not a hex colour like "
                         "'#0000ff'", color);
                watch_fail(s, msg);
            }
            hl->rgb[0] = (uint32_t)((packed >> 16) & 0xFF);
            hl->rgb[1] = (uint32_t)((packed >> 8) & 0xFF);
            hl->rgb[2] = (uint32_t)(packed & 0xFF);
            tc_copy_str_cap(hl->source, color, sizeof(hl->source));
            free(color);
        }

        /* `match` is either a bare string or an array of strings. */
        if (match_raw != NULL) {
            char *pat = watch_toml_unquote(match_raw);
            if (pat == NULL) {
                snprintf(msg, sizeof(msg),
                         "rule %d: `match` needs at least one pattern", i);
                watch_fail(s, msg);
            }
            watch_hl_compile(s, hl, i, pat);
            free(pat);
        } else {
            int mn = toml_array_nelem(match_arr);
            for (p = 0; p < mn; p++) {
                const char *mraw = toml_raw_at(match_arr, p);
                char *pat;
                if (mraw == NULL) {
                    continue;
                }
                pat = watch_toml_unquote(mraw);
                if (pat == NULL) {
                    continue;
                }
                watch_hl_compile(s, hl, i, pat);
                free(pat);
            }
        }
        if (hl->pat_count == 0) {
            snprintf(msg, sizeof(msg),
                     "rule %d: `match` needs at least one pattern", i);
            watch_fail(s, msg);
        }

        curve_raw = toml_raw_in(rule, "curve");
        if (curve_raw != NULL) {
            char *cv = watch_toml_unquote(curve_raw);
            if (cv != NULL) {
                int id = tc_parse_curve(cv, &ok);
                if (!ok) {
                    snprintf(msg, sizeof(msg),
                             "rule %d: unknown fade curve %s", i, cv);
                    free(cv);
                    watch_fail(s, msg);
                }
                hl->curve = id;
                free(cv);
            }
        }
        k_raw = toml_raw_in(rule, "k");
        if (k_raw != NULL) {
            char *kv = watch_toml_unquote(k_raw);
            if (kv != NULL) {
                char *end = NULL;
                double val = strtod(kv, &end);
                if (end == kv || *end != '\0' || val <= 0.0) {
                    snprintf(msg, sizeof(msg),
                             "rule %d: %s must be greater than 0", i, kv);
                    free(kv);
                    watch_fail(s, msg);
                }
                hl->k = val;
                free(kv);
            }
        }

        s->hl_count++;
    }
    toml_free(root);

    /* streamer mode keeps the rules parsed (a bad pattern still errors) but
       colours nothing and builds no ramps (Python resolve_watch). */
    s->hl_active = s->hl_count > 0 && !s->streamer_mode;
}

static void watch_free_highlights(tc_wsession *s) {
    int i;
    int p;
    for (i = 0; i < s->hl_count; i++) {
        tc_hl_compiled *hl = &s->highlights[i];
        for (p = 0; p < hl->pat_count; p++) {
            if (hl->mds[p] != NULL) {
                pcre2_match_data_free(hl->mds[p]);
            }
            if (hl->codes[p] != NULL) {
                pcre2_code_free(hl->codes[p]);
            }
        }
    }
}

// ----------------------------------------------------------------------------
// Line parsing (Python LINE_RE + speaker_login + the per-second bucket).
// ----------------------------------------------------------------------------
/* Split "[HH:MM:SS] who: msg" at the first ": " after the header.  Returns 1
   with the second-of-day, the login and the message span. */
static int watch_message_parse(const char *line, size_t len,
                               int64_t *second, char *login,
                               size_t *login_len, const char **msg,
                               size_t *msg_len) {
    size_t i;
    size_t who_len;
    if (!tc_is_timestamp_header(line, len)) {
        return 0;
    }
    for (i = 11; i < len; i++) {
        if (line[i] == ':') {
            if (i + 1 < len && line[i + 1] == ' ') {
                who_len = i - 11;
                if (who_len == 0) {
                    return 0;
                }
                *second = (int64_t)(line[1] - '0') * 10 + (int64_t)(line[2] - '0');
                *second = *second * 60 + (int64_t)(line[4] - '0') * 10
                          + (int64_t)(line[5] - '0');
                *second = *second * 60 + (int64_t)(line[7] - '0') * 10
                          + (int64_t)(line[8] - '0');
                *login_len = tc_speaker_login_to(line + 11, who_len, login);
                if (*login_len == 0) {
                    return 0;
                }
                *msg = line + i + 2;
                *msg_len = len - i - 2;
                return 1;
            }
            return 0;
        }
    }
    return 0;
}

// ----------------------------------------------------------------------------
// Bucket/match storage.
// ----------------------------------------------------------------------------
static tc_wbucket *watch_bucket_find(tc_reader *r, int64_t second,
                                     const char *login, size_t login_len,
                                     int state) {
    int64_t i;
    for (i = 0; i < r->bcount; i++) {
        if (r->buckets[i].second == second
            && r->buckets[i].state == state
            && strlen(r->buckets[i].login) == login_len
            && memcmp(r->buckets[i].login, login, login_len) == 0) {
            return &r->buckets[i];
        }
    }
    return NULL;
}

static tc_wbucket *watch_bucket_add(tc_reader *r, int64_t second,
                                    const char *login, size_t login_len,
                                    int state, int64_t n) {
    tc_wbucket *b;
    if (r->bcount >= r->bcap) {
        int64_t new_cap = r->bcap == 0 ? WATCH_BUCKET_INIT : r->bcap * 2;
        tc_wbucket *nb = realloc(r->buckets, (size_t)new_cap * sizeof(*nb));
        if (nb == NULL) {
            tc_fail("out of memory");
        }
        r->buckets = nb;
        r->bcap = new_cap;
    }
    b = &r->buckets[r->bcount];
    memset(b, 0, sizeof(*b));
    b->second = second;
    b->state = state;
    b->n = n;
    if (login_len >= TC_LOGIN_SZ) {
        login_len = TC_LOGIN_SZ - 1;
    }
    memcpy(b->login, login, login_len);
    b->login[login_len] = '\0';
    r->bcount++;
    return b;
}

static void watch_match_add(tc_reader *r, int64_t second, const char *login,
                            size_t login_len, int rule) {
    tc_wmatch *m;
    if (r->mcount >= r->mcap) {
        int64_t new_cap = r->mcap == 0 ? WATCH_MATCH_INIT : r->mcap * 2;
        tc_wmatch *nm = realloc(r->matches, (size_t)new_cap * sizeof(*nm));
        if (nm == NULL) {
            tc_fail("out of memory");
        }
        r->matches = nm;
        r->mcap = new_cap;
    }
    m = &r->matches[r->mcount];
    memset(m, 0, sizeof(*m));
    m->second = second;
    m->rule = rule;
    if (login_len >= TC_LOGIN_SZ) {
        login_len = TC_LOGIN_SZ - 1;
    }
    memcpy(m->login, login, login_len);
    m->login[login_len] = '\0';
    r->mcount++;
}

/* Does any of a rule's patterns match the message?  (Python's
   `any(pattern.search(text) for pattern in rule.patterns)`.) */
static int watch_rule_matches(const tc_hl_compiled *hl, const char *msg,
                              size_t msg_len) {
    int p;
    for (p = 0; p < hl->pat_count; p++) {
        int rc = pcre2_match(hl->codes[p], (PCRE2_SPTR)msg,
                             (PCRE2_SIZE)msg_len, 0, 0, hl->mds[p], NULL);
        if (rc >= 0) {
            return 1;
        }
        if (rc == PCRE2_ERROR_NOMATCH) {
            continue;
        }
        /* any other error (bad UTF-8 etc.) is treated as no match */
    }
    return 0;
}

// ----------------------------------------------------------------------------
// Reader engine (Python TailReader).
// ----------------------------------------------------------------------------
static void watch_reader_reset(tc_reader *r, int enter_state) {
    r->bcount = 0;
    r->mcount = 0;
    r->offset = 0;
    r->rlen = 0;
    r->enter_state = enter_state;
    r->exit_state = enter_state;
    r->have_identity = 0;
    r->partial = 0;
    r->revision = 0;
}

static void watch_reader_free(tc_reader *r) {
    free(r->buckets);
    free(r->matches);
    free(r->remainder);
    memset(r, 0, sizeof(*r));
}

static tc_reader *watch_reader_get(tc_wsession *s, const char *path,
                                   int64_t ymd) {
    int64_t i;
    for (i = 0; i < s->reader_count; i++) {
        if (strcmp(s->readers[i].path, path) == 0) {
            return &s->readers[i];
        }
    }
    if (s->reader_count >= s->reader_cap) {
        int64_t new_cap = s->reader_cap == 0 ? WATCH_READER_INIT
                                             : s->reader_cap * 2;
        tc_reader *nr = realloc(s->readers, (size_t)new_cap * sizeof(*nr));
        if (nr == NULL) {
            tc_fail("out of memory");
        }
        s->readers = nr;
        s->reader_cap = new_cap;
    }
    {
        tc_reader *r = &s->readers[s->reader_count];
        memset(r, 0, sizeof(*r));
        tc_copy_str_cap(r->path, path, sizeof(r->path));
        r->ymd = ymd;
        watch_reader_reset(r, TC_ST_NONE);
        s->reader_count++;
        return r;
    }
}

/* Read the tail of a file from `offset` to EOF, capped at TC_FILE_CAP.
   Returns 0 ok, 1 file too large, 2 error. */
static int watch_read_tail(const char *path, int64_t offset, char **buf_out,
                           size_t *len_out) {
    int fd;
    size_t cap = TC_READ_CHUNK_WATCH;
    char *buf;
    size_t used = 0;
    int rc = 0;

    *buf_out = NULL;
    *len_out = 0;
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return 2;
    }
    if (lseek(fd, offset, SEEK_SET) < 0) {
        close(fd);
        return 2;
    }
    buf = malloc(cap);
    if (buf == NULL) {
        close(fd);
        return 2;
    }
    for (;;) {
        ssize_t got;
        if (used == cap) {
            size_t grown = cap * 2;
            char *nbuf;
            if (grown > TC_FILE_CAP) {
                grown = (size_t)TC_FILE_CAP;
            }
            if (grown <= used) {
                rc = 1;
                break;
            }
            nbuf = realloc(buf, grown);
            if (nbuf == NULL) {
                free(buf);
                close(fd);
                return 2;
            }
            buf = nbuf;
            cap = grown;
        }
        got = read(fd, buf + used, cap - used);
        if (got > 0) {
            used += (size_t)got;
            if (used > TC_FILE_CAP) {
                rc = 1;
                break;
            }
            continue;
        }
        if (got < 0) {
            if (errno == EINTR) {
                continue;
            }
            rc = 2;
            break;
        }
        break;
    }
    close(fd);
    if (rc != 0) {
        free(buf);
        *buf_out = NULL;
        *len_out = 0;
        return rc;
    }
    *buf_out = buf;
    *len_out = used;
    return 0;
}

/* Grow the remainder buffer to hold `need` more bytes. */
static void watch_remainder_grow(tc_reader *r, size_t add) {
    if (r->rlen + add + 1 <= r->rcap) {
        return;
    }
    {
        size_t new_cap = r->rcap == 0 ? TC_READ_CHUNK_WATCH : r->rcap;
        char *nb;
        while (new_cap < r->rlen + add + 1) {
            new_cap *= 2;
        }
        nb = realloc(r->remainder, new_cap);
        if (nb == NULL) {
            tc_fail("out of memory");
        }
        r->remainder = nb;
        r->rcap = new_cap;
    }
}

/* Fold complete lines into buckets + matches (Python fold_lines).  Returns
   the exit state. */
static int watch_fold_text(tc_reader *r, const char *text, size_t len,
                           tc_wsession *s) {
    const char *end = text + len;
    const char *last = text;        /* one past the last '\n' */
    const char *p;
    const char *line;
    int state = r->exit_state;

    for (p = text; p < end; p++) {
        if (*p == '\n') {
            last = p + 1;
        }
    }
    line = text;
    while (line < last) {
        const char *nl = memchr(line, '\n', (size_t)(last - line));
        size_t llen = nl == NULL ? (size_t)(last - line)
                                 : (size_t)(nl - line);
        int m;
        if (llen == 0) {
            line = nl + 1;
            continue;
        }
        if (line[0] == '#') {
            line = nl + 1;
            continue;
        }
        m = tc_line_is_marker(line, llen);
        if (m != TC_ST_NONE) {
            state = m;
            line = nl + 1;
            continue;
        }
        {
            int64_t second;
            char login[TC_LOGIN_SZ];
            size_t login_len;
            const char *msg;
            size_t msg_len;
            if (watch_message_parse(line, llen, &second, login, &login_len,
                                    &msg, &msg_len)) {
                tc_wbucket *b;
                int st = state == TC_ST_LIVE ? TC_ST_LIVE
                       : state == TC_ST_OFFLINE ? TC_ST_OFFLINE
                       : TC_ST_UNKNOWN;
                b = watch_bucket_find(r, second, login, login_len, st);
                if (b == NULL) {
                    watch_bucket_add(r, second, login, login_len, st, 1);
                } else {
                    b->n++;
                }
                if (s->hl_active && s->hl_count > 0) {
                    int hit = -1;
                    int idx;
                    for (idx = 0; idx < s->hl_count; idx++) {
                        if (watch_rule_matches(&s->highlights[idx], msg,
                                               msg_len)) {
                            hit = idx;      /* no break: a later rule wins */
                        }
                    }
                    if (hit >= 0) {
                        watch_match_add(r, second, login, login_len, hit);
                    }
                }
            }
        }
        line = nl + 1;
    }
    return state;
}

/* Python line_at_or_after: the offset of the first line whose [HH:MM:SS] is
   >= the 8-byte `want` key, or len(text). */
static size_t watch_line_at_or_after(const char *text, size_t size,
                                     const char *want) {
    size_t span = 1u << 16;
    for (;;) {
        size_t start = 0;
        size_t pos;
        size_t found = size;
        if (span < size) {
            const char *nl = memchr(text + size - span, '\n', span);
            start = nl == NULL ? 0 : (size_t)(nl - text) + 1;
        }
        pos = start;
        while (pos < size) {
            if (text[pos] == '[' && pos + 9 <= size
                && memcmp(text + pos + 1, want, 8) >= 0) {
                found = pos;
                break;
            }
            {
                const char *nl = memchr(text + pos, '\n', size - pos);
                if (nl == NULL) {
                    break;
                }
                pos = (size_t)(nl - text) + 1;
            }
        }
        if (found == size) {
            return size;            /* nothing at or after `want` */
        }
        if (found > start || start == 0) {
            return found;           /* a line before the window bounds it */
        }
        span *= 2;                  /* the chunk was entirely inside the window */
    }
}

/* Python seek_window: where a window opening at second-of-day `floor` starts
   in `text`, and the stream state entering it.  Returns the start offset (0 =
   none) and sets *entering to the last marker state in the skipped prefix. */
static size_t watch_seek_window(const char *text, size_t len, int64_t floor,
                                int *entering) {
    char want[9];
    size_t start;
    size_t pos = 0;
    int best_state = TC_ST_NONE;

    *entering = TC_ST_NONE;
    if (floor <= 0) {
        return 0;
    }
    snprintf(want, sizeof(want), "%02lld:%02lld:%02lld",
             (long long)(floor / TC_SECS_PER_HOUR),
             (long long)(floor / 60 % 60),
             (long long)(floor % 60));
    start = watch_line_at_or_after(text, len, want);
    if (start <= 0) {
        return 0;
    }
    /* the state entering the kept part comes from the markers in the skipped
       prefix: the last marker line wins, exactly like Python's rfind loop */
    while (pos < start) {
        const char *nl = memchr(text + pos, '\n', start - pos);
        size_t llen = nl == NULL ? start - pos : (size_t)(nl - (text + pos));
        int m = tc_line_is_marker(text + pos, llen);
        if (m != TC_ST_NONE) {
            best_state = m;
        }
        if (nl == NULL) {
            break;
        }
        pos = (size_t)(nl - text) + 1;
    }
    *entering = best_state;
    return start;
}

/* Python TailReader.refresh: bring the buckets up to date.  Returns 1 if
   anything was read, 0 if not, -1 on a read error. */
static int watch_reader_refresh(tc_reader *r, int enter_state,
                                const struct stat *st, int64_t floor,
                                tc_wsession *s) {
    int64_t dev = (int64_t)st->st_dev;
    int64_t ino = (int64_t)st->st_ino;
    int rewound;
    int cold;
    int status;
    char *chunk = NULL;
    size_t chunk_len = 0;
    char *text;
    size_t text_len;

    rewound = (int64_t)st->st_size < r->offset
              || (r->have_identity
                  && (dev != r->dev || ino != r->ino));
    if (rewound || enter_state != r->enter_state) {
        watch_reader_reset(r, enter_state);
    }
    r->dev = dev;
    r->ino = ino;
    r->have_identity = 1;
    if ((int64_t)st->st_size == r->offset && r->offset != 0) {
        return 0;                   /* nothing appended since last time */
    }
    cold = r->offset == 0;
    status = watch_read_tail(r->path, r->offset, &chunk, &chunk_len);
    if (status != 0) {
        if (status == 1) {
            errno = EFBIG;
        }
        return -1;
    }
    r->offset += (int64_t)chunk_len;

    /* text = remainder + chunk */
    watch_remainder_grow(r, chunk_len);
    memcpy(r->remainder + r->rlen, chunk, chunk_len);
    r->rlen += chunk_len;
    r->remainder[r->rlen] = '\0';
    free(chunk);
    text = r->remainder;
    text_len = r->rlen;

    if (cold && floor > 0) {
        size_t start;
        int entering;
        start = watch_seek_window(text, text_len, floor, &entering);
        if (start > 0) {
            text += start;
            text_len -= start;
            r->partial = 1;
            if (entering != TC_ST_NONE) {
                r->exit_state = entering;
            }
        }
    }
    {
        const char *nl = NULL;
        size_t i;
        for (i = 0; i < text_len; i++) {
            if (text[i] == '\n') {
                nl = text + i;
            }
        }
        if (nl == NULL) {
            memmove(r->remainder, text, text_len);
            r->rlen = text_len;
            r->remainder[text_len] = '\0';
            return 0;               /* nothing complete yet */
        }
        {
            size_t cut = (size_t)(nl - text);
            size_t keep = text_len - cut - 1;
            /* fold through the last newline (inclusive): Python's
               text[:cut].split("\n") treats the segment before the last
               newline as a complete line */
            r->exit_state = watch_fold_text(r, text, cut + 1, s);
            if (keep > 0) {
                memmove(r->remainder, text + cut + 1, keep);
            }
            r->rlen = keep;
            r->remainder[keep] = '\0';
        }
    }
    r->revision++;
    if (cold) {
        r->full_reads++;
    } else {
        r->appends++;
    }
    return 1;
}

/* Python TailReader.prune: drop buckets before `floor` and matches before
   `match_floor` (<= 0 keeps everything). */
static void watch_reader_prune(tc_reader *r, int64_t floor,
                               int64_t match_floor) {
    int64_t i;
    if (floor > 0) {
        int64_t kept = 0;
        for (i = 0; i < r->bcount; i++) {
            if (r->buckets[i].second >= floor) {
                if (kept != i) {
                    r->buckets[kept] = r->buckets[i];
                }
                kept++;
            }
        }
        r->bcount = kept;
        r->partial = 1;
        r->revision++;
    }
    if (match_floor > 0) {
        int64_t kept = 0;
        for (i = 0; i < r->mcount; i++) {
            if (r->matches[i].second >= match_floor) {
                if (kept != i) {
                    r->matches[kept] = r->matches[i];
                }
                kept++;
            }
        }
        r->mcount = kept;
    }
}

/* Python TailReader.window + fold_windows' per-file merge: every bucket in
   [lo, hi] seconds-of-day adds to the users table and the per-state tally. */
static void watch_reader_window(tc_reader *r, int64_t lo, int64_t hi,
                                tc_users *users, tc_tally *tally) {
    int64_t i;
    for (i = 0; i < r->bcount; i++) {
        const tc_wbucket *b = &r->buckets[i];
        if (b->second < lo || b->second > hi) {
            continue;
        }
        tc_add_user(users, b->login, strlen(b->login), b->state, b->n);
        tally->states[b->state - TC_ST_LIVE] += b->n;
    }
}

// ----------------------------------------------------------------------------
// The dated-log listing (Python log_files), memoized on the directory mtime.
// ----------------------------------------------------------------------------
static int watch_listing_cmp(const void *a, const void *b) {
    const tc_listing_entry *ea = a;
    const tc_listing_entry *eb = b;
    if (ea->ymd < eb->ymd) {
        return -1;
    }
    if (ea->ymd > eb->ymd) {
        return 1;
    }
    return strcmp(ea->name, eb->name);
}

static void watch_build_listing(tc_wsession *s) {
    const char *channel_dir = s->inputs->channel_dir;
    DIR *d;
    struct dirent *de;

    free(s->listing.entries);
    s->listing.count = 0;
    s->listing.cap = 0;
    s->listing.entries = NULL;

    d = opendir(channel_dir);
    if (d == NULL) {
        char msg[WATCH_MSG_SZ];
        tc_copy_str_cap(msg, tc_oserror_text(errno), sizeof(msg));
        watch_fail(s, msg);
    }
    while ((de = readdir(d)) != NULL) {
        size_t len = strlen(de->d_name);
        int64_t ymd = tc_parse_log_filename_n(de->d_name, len);
        if (ymd == 0) {
            continue;
        }
        if (s->listing.count >= s->listing.cap) {
            int64_t new_cap = s->listing.cap == 0 ? 64 : s->listing.cap * 2;
            tc_listing_entry *ne = realloc(s->listing.entries,
                                           (size_t)new_cap * sizeof(*ne));
            if (ne == NULL) {
                tc_fail("out of memory");
            }
            s->listing.entries = ne;
            s->listing.cap = new_cap;
        }
        s->listing.entries[s->listing.count].ymd = ymd;
        tc_copy_str_cap(s->listing.entries[s->listing.count].name, de->d_name,
                        sizeof(s->listing.entries[0].name));
        s->listing.count++;
    }
    closedir(d);
    qsort(s->listing.entries, (size_t)s->listing.count,
          sizeof(tc_listing_entry), watch_listing_cmp);
}

/* Python log_files_for: rescan only when the directory's mtime changed. */
static void watch_listing_refresh(tc_wsession *s) {
    struct stat st;
    int64_t mtime_ns;
    if (stat(s->inputs->channel_dir, &st) != 0) {
        watch_build_listing(s);
        s->listing_valid = 1;
        s->listing_mtime = 0;
        return;
    }
    mtime_ns = (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
               + (int64_t)TC_ST_MTIME_NSEC(st);
    if (s->listing_valid && mtime_ns == s->listing_mtime) {
        return;
    }
    watch_build_listing(s);
    s->listing_valid = 1;
    s->listing_mtime = mtime_ns;
}

// ----------------------------------------------------------------------------
// The seed (Python seed_stream_state): the live/offline state in force when
// the range opens, cache-first then a walk back through earlier files.
// ----------------------------------------------------------------------------
static int64_t watch_index_before(const tc_listing *listing, int64_t ymd) {
    int64_t i;
    for (i = 0; i < listing->count; i++) {
        if (listing->entries[i].ymd >= ymd) {
            return i - 1;
        }
    }
    return listing->count - 1;
}

static int watch_scan_markers(const char *buf, size_t len) {
    const char *end = buf + len;
    const char *line = buf;
    int state = TC_ST_NONE;
    while (line < end) {
        const char *nl = memchr(line, '\n', (size_t)(end - line));
        size_t llen = nl == NULL ? (size_t)(end - line)
                                 : (size_t)(nl - line);
        int m = tc_line_is_marker(line, llen);
        if (m != TC_ST_NONE) {
            state = m;
        }
        if (nl == NULL) {
            break;
        }
        line = nl + 1;
    }
    return state;
}

static int watch_seed_state(tc_wsession *s, const tc_window *win) {
    int64_t start = watch_index_before(&s->listing, win->begin_ymd);
    int64_t lookback;
    int64_t limit;
    int64_t i;

    if (start < 0) {
        return TC_ST_NONE;
    }

    /* rollup-cache hook: the day before the range's stored exit state. */
    if (s->cache != NULL) {
        const tc_listing_entry *entry = &s->listing.entries[start];
        char fpath[TC_PATH_SZ];
        struct stat st;
        int state;
        snprintf(fpath, sizeof(fpath), "%s/%s", s->inputs->channel_dir,
                 entry->name);
        if (stat(fpath, &st) == 0) {
            state = tc_cache_exit_state(s->cache, s->inputs->channel_name,
                                        entry->ymd, fpath, (int64_t)st.st_size,
                                        (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
                                        + (int64_t)TC_ST_MTIME_NSEC(st));
            if (state != TC_ST_NONE) {
                return state;
            }
        }
    }

    /* walk back, newest first, at most seed_lookback files. */
    lookback = s->seed_lookback > 0 ? s->seed_lookback
                                    : WATCH_SEED_LOOKBACK_DEF;
    limit = start - lookback + 1;
    if (limit < 0) {
        limit = 0;
    }
    for (i = start; i >= limit; i--) {
        const tc_listing_entry *entry = &s->listing.entries[i];
        char fpath[TC_PATH_SZ];
        char *buf = NULL;
        size_t len = 0;
        int state;
        snprintf(fpath, sizeof(fpath), "%s/%s", s->inputs->channel_dir,
                 entry->name);
        if (tc_read_all(fpath, TC_FILE_CAP, &buf, &len) != 0) {
            continue;
        }
        state = watch_scan_markers(buf, len);
        free(buf);
        if (state != TC_ST_NONE) {
            return state;
        }
    }
    return TC_ST_NONE;
}

// ----------------------------------------------------------------------------
// The count pass (Python count_messages + fold_windows, driven by readers).
// ----------------------------------------------------------------------------
static void watch_reset_users(tc_users *users) {
    users->count = 0;
}

static void watch_reset_tally(tc_tally *tally) {
    tc_users *users = tally->users;
    memset(tally, 0, sizeof(*tally));
    tally->users = users;
}

static void watch_record_unreadable(tc_tally *tally, const char *name,
                                    const char *reason) {
    tc_unreadable_entry *entry;
    if (tally->unreadable_count >= TC_T_UNR_MAX) {
        return;
    }
    entry = &tally->unreadable[tally->unreadable_count];
    tc_copy_str_cap(entry->name, name, sizeof(entry->name));
    tc_copy_str_cap(entry->reason, reason, sizeof(entry->reason));
    tally->unreadable_count++;
}

/* The count column under the resolved state filter (core's
   count_column_for_filter). */
static int64_t watch_count_column(const tc_user_entry *user, int filter) {
    switch (filter) {
    case TC_ST_LIVE:
        return user->live;
    case TC_ST_OFFLINE:
        return user->offline;
    case TC_ST_UNKNOWN:
        return user->unknown;
    default:
        return tc_user_count(user);
    }
}

static void watch_merge_day(tc_users *run_users, tc_tally *run_tally,
                            const tc_tally *day) {
    const tc_users *du = day->users;
    int64_t i;
    for (i = 0; i < du->count; i++) {
        const tc_user_entry *entry = &du->entries[i];
        size_t llen = strlen(entry->login);
        if (entry->live > 0) {
            tc_reuse_apply(run_users, entry->login, llen, TC_ST_LIVE,
                           entry->live);
            run_tally->states[TC_ST_LIVE - 1] += entry->live;
        }
        if (entry->offline > 0) {
            tc_reuse_apply(run_users, entry->login, llen, TC_ST_OFFLINE,
                           entry->offline);
            run_tally->states[TC_ST_OFFLINE - 1] += entry->offline;
        }
        if (entry->unknown > 0) {
            tc_reuse_apply(run_users, entry->login, llen, TC_ST_UNKNOWN,
                           entry->unknown);
            run_tally->states[TC_ST_UNKNOWN - 1] += entry->unknown;
        }
    }
}

/* Apply exclusions (core's core_finish_tally). */
static void watch_finish_tally(const tc_window *win,
                               const tc_excl_set *exclusions,
                               tc_users *users, tc_tally *tally) {
    int64_t i;
    memset(tally->excluded_states, 0, sizeof(tally->excluded_states));
    tally->messages = 0;
    for (i = 0; i < users->count; i++) {
        tc_user_entry *entry = &users->entries[i];
        size_t llen = strlen(entry->login);
        if (tc_excl_contains(exclusions, entry->login, llen)) {
            int s;
            for (s = 0; s < 3; s++) {
                int64_t n = tc_user_state(entry, s + TC_ST_LIVE);
                tally->excluded_states[s] += n;
                tally->states[s] -= n;
            }
        } else {
            tally->messages += watch_count_column(entry, win->state_filter);
        }
    }
}

/* Fold one in-range day into the run tally (Python count_messages' loop
   body + core.c's core_fold_day, driven by the session's readers). */
static void watch_fold_day(tc_wsession *s, const tc_window *win,
                           const tc_listing_entry *entry, int *current,
                           tc_users *users, tc_tally *tally) {
    int64_t ymd = entry->ymd;
    int64_t lo;
    int64_t hi;
    int whole_day;
    char fpath[TC_PATH_SZ];
    struct stat st;
    int enter;
    tc_reader *reader;

    tally->files++;

    lo = win->begin_ymd < ymd ? 0 : win->begin_sod;
    hi = win->end_ymd > ymd ? TC_LAST_SECOND : win->end_sod;
    whole_day =
        (win->begin_ymd < ymd
         || (win->begin_ymd == ymd && win->begin_sod == 0))
        && (win->end_ymd > ymd
            || (win->end_ymd == ymd && win->end_sod == TC_LAST_SECOND));

    snprintf(fpath, sizeof(fpath), "%s/%s", s->inputs->channel_dir,
             entry->name);

    if (stat(fpath, &st) != 0) {
        watch_record_unreadable(tally, entry->name, tc_errno_reason(errno));
        if (s->cache != NULL) {
            tc_cache_discard_day(s->cache);
        }
        *current = TC_ST_NONE;
        return;
    }

    /* rollup-cache serve: a whole day inside the range is settled. */
    if (s->cache != NULL && whole_day) {
        int status;
        watch_reset_users(&s->day_users);
        watch_reset_tally(&s->day_tally);
        status = tc_cache_day(s->cache, s->inputs->channel_name, ymd, fpath,
                              (int64_t)st.st_size,
                              (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
                              + (int64_t)TC_ST_MTIME_NSEC(st),
                              *current, &s->day_tally);
        if (status == 1) {
            tally->reused++;
            watch_merge_day(users, tally, &s->day_tally);
            *current = tc_cache_exit_state(s->cache, s->inputs->channel_name,
                                           ymd, fpath, (int64_t)st.st_size,
                                           (int64_t)TC_ST_MTIME_SEC(st)
                                               * TC_NANOSEC
                                           + (int64_t)TC_ST_MTIME_NSEC(st));
            return;
        }
        /* status 0 (miss) or 2 (row unusable): parse normally. */
    }

    reader = watch_reader_get(s, fpath, ymd);
    {
        int64_t floor = 0;
        int status;
        if (s->retain_seconds > 0) {
            floor = lo - s->retain_seconds;
            if (floor < 0) {
                floor = 0;
            }
        }
        status = watch_reader_refresh(reader, *current, &st, floor, s);
        if (status < 0) {
            if (s->cache != NULL) {
                tc_cache_discard_day(s->cache);
            }
            if (errno == EFBIG) {
                watch_record_unreadable(tally, entry->name, "file too large");
            } else {
                watch_record_unreadable(tally, entry->name,
                                        tc_errno_reason(errno));
            }
            *current = TC_ST_NONE;
            return;
        }
        tally->parsed += status;
        enter = *current;
        watch_reader_window(reader, lo, hi, users, tally);

        /* only a whole, cold, un-partial read is written to the rollup */
        if (s->cache != NULL && status && reader->appends == 0
            && !reader->partial && whole_day) {
            tc_cache_put_day(s->cache, s->inputs->channel_name, ymd, fpath,
                             (int64_t)st.st_size,
                             (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
                             + (int64_t)TC_ST_MTIME_NSEC(st),
                             enter, reader->exit_state, tally);
            tc_cache_discard_day(s->cache);
        }
        *current = reader->exit_state;
        if (floor > 0) {
            int64_t match_floor = s->match_seconds > 0
                                      ? lo - s->match_seconds : 0;
            if (match_floor < 0) {
                match_floor = 0;
            }
            watch_reader_prune(reader, floor, match_floor);
        }
    }
}

/* Drop readers whose paths are no longer in the window's in-range listing
   (Python LiveReaders.retain). */
static void watch_retain_readers(tc_wsession *s, const tc_window *win) {
    int64_t i;
    for (i = 0; i < s->reader_count;) {
        tc_reader *r = &s->readers[i];
        int64_t j;
        int keep = 0;
        for (j = 0; j < s->listing.count; j++) {
            const tc_listing_entry *entry = &s->listing.entries[j];
            if (entry->ymd < win->begin_ymd || entry->ymd > win->end_ymd) {
                continue;
            }
            {
                char fpath[TC_PATH_SZ];
                snprintf(fpath, sizeof(fpath), "%s/%s",
                         s->inputs->channel_dir, entry->name);
                if (strcmp(fpath, r->path) == 0) {
                    keep = 1;
                    break;
                }
            }
        }
        if (keep) {
            i++;
        } else {
            watch_reader_free(r);
            memmove(&s->readers[i], &s->readers[i + 1],
                    (size_t)(s->reader_count - i - 1) * sizeof(*r));
            s->reader_count--;
        }
    }
}

/* One counting pass over a window into users/tally (Python count_messages +
   fold_windows).  The readers keep their buckets between passes. */
static void watch_count(tc_wsession *s, const tc_window *win,
                        tc_users *users, tc_tally *tally) {
    int current;
    int64_t i;

    watch_reset_users(users);
    watch_reset_tally(tally);
    tally->users = users;

    watch_retain_readers(s, win);
    current = watch_seed_state(s, win);

    for (i = 0; i < s->listing.count; i++) {
        const tc_listing_entry *entry = &s->listing.entries[i];
        if (entry->ymd < win->begin_ymd || entry->ymd > win->end_ymd) {
            continue;
        }
        watch_fold_day(s, win, entry, &current, users, tally);
    }

    watch_finish_tally(win, &s->inputs->exclusions, users, tally);
}

// ----------------------------------------------------------------------------
// --users sizing (Python size_window + _search_width, via core_size_users).
// ----------------------------------------------------------------------------
static int64_t watch_reported_width(tc_wsession *s, const tc_window *base,
                                    int64_t seconds, tc_users *scratch_users,
                                    tc_tally *scratch_tally) {
    tc_window probe;
    int64_t end_epoch;
    int64_t begin_epoch;
    int64_t eff;
    int64_t n = 0;
    int64_t i;

    end_epoch = tc_ymd_sod_to_epoch(base->end_ymd, base->end_sod);
    begin_epoch = end_epoch - seconds;
    probe = *base;
    tc_epoch_to_ymd_sod(begin_epoch, &probe.begin_ymd, &probe.begin_sod);
    probe.begin_rolls = 1;

    watch_count(s, &probe, scratch_users, scratch_tally);
    eff = tc_eff_threshold(s->opts);
    for (i = 0; i < scratch_users->count; i++) {
        tc_user_entry *entry = &scratch_users->entries[i];
        size_t llen = strlen(entry->login);
        if (tc_excl_contains(&s->inputs->exclusions, entry->login, llen)) {
            continue;
        }
        if (watch_count_column(entry, probe.state_filter) >= eff) {
            n++;
        }
    }
    return n;
}

static void watch_size_users(tc_wsession *s, tc_window *win) {
    int64_t requested = s->opts->users;
    int64_t ceiling = s->opts->users_max >= 1 ? s->opts->users_max : 1;
    int64_t end_epoch;
    int64_t widest;
    int64_t over_width;
    int64_t over;
    int64_t under_width;
    int64_t under;
    int64_t lo;
    int64_t hi;
    int64_t mid;
    int64_t width;
    int64_t found;
    tc_users scratch_users = {0};
    tc_tally scratch_tally = {0};
    int64_t saved_retain = s->retain_seconds;

    scratch_tally.users = &scratch_users;
    end_epoch = tc_ymd_sod_to_epoch(win->end_ymd, win->end_sod);

    /* no pruning while searching: a narrow probe must not discard buckets a
       wider one still needs (Python _search_width disables retain_seconds) */
    s->retain_seconds = 0;

    widest = watch_reported_width(s, win, ceiling, &scratch_users,
                                  &scratch_tally);

    /* bisection 1: the smallest width with count >= requested */
    lo = 1;
    hi = ceiling;
    while (lo < hi) {
        mid = lo + (hi - lo) / 2;
        if (watch_reported_width(s, win, mid, &scratch_users,
                                 &scratch_tally) >= requested) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    over_width = lo;
    over = watch_reported_width(s, win, over_width, &scratch_users,
                                &scratch_tally);

    /* bisection 2: the widest width with count <= requested */
    lo = 1;
    hi = ceiling;
    while (lo < hi) {
        mid = lo + (hi - lo + 1) / 2;
        if (watch_reported_width(s, win, mid, &scratch_users,
                                 &scratch_tally) <= requested) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    under_width = lo;
    under = watch_reported_width(s, win, under_width, &scratch_users,
                                 &scratch_tally);

    if (widest < requested) {
        width = ceiling;
        found = widest;
    } else if (s->opts->users_policy == TC_POLICY_AT_MOST) {
        width = under_width;
        found = under;
    } else if (s->opts->users_policy == TC_POLICY_NEAREST) {
        int64_t du = under - requested;
        int64_t dv = over - requested;
        if (du < 0) {
            du = -du;
        }
        if (dv < 0) {
            dv = -dv;
        }
        if (du <= dv) {
            width = under_width;
            found = under;
        } else {
            width = over_width;
            found = over;
        }
    } else {
        width = over_width;
        found = over;
    }

    win->users_width = width;
    win->users_found = found;
    tc_epoch_to_ymd_sod(end_epoch - width, &win->begin_ymd, &win->begin_sod);
    s->users_width = width;
    s->users_found = found;

    s->retain_seconds = saved_retain;
    free(scratch_users.entries);
}

// ----------------------------------------------------------------------------
// Window resolution (Python resolve_context; the end/begin of every frame).
// ----------------------------------------------------------------------------
static int watch_window_start_at(tc_wsession *s, int64_t end_ymd,
                                 int64_t end_sod, int64_t *begin_ymd,
                                 int64_t *begin_sod) {
    int kind = s->win_kind;
    const tc_opts *opts = s->opts;

    if (kind == TC_WIN_EARLIEST) {
        if (s->listing.count == 0) {
            char msg[WATCH_MSG_SZ];
            snprintf(msg, sizeof(msg), "no log files found in %s",
                     s->inputs->channel_dir);
            watch_fail(s, msg);
        }
        *begin_ymd = s->listing.entries[0].ymd;
        *begin_sod = 0;
        return 0;
    }
    if (kind == TC_WIN_BEGIN) {
        const char *raw = opts->begin_raw[0] != '\0' ? opts->begin_raw : NULL;
        const char *v = NULL;
        int src;
        if (raw == NULL) {
            if (tc_env_get("TWITCH_BEGIN", &v) && v != NULL && v[0] != '\0') {
                raw = v;
            } else if (tc_config_get("begin", TC_SEC_NONE, &v, &src)
                       && v != NULL && v[0] != '\0') {
                raw = v;
            }
        }
        if (raw == NULL) {
            *begin_ymd = 0;
            *begin_sod = 0;
            return 0;
        }
        if (!tc_parse_datetime(raw, 0, begin_ymd, begin_sod)) {
            char msg[WATCH_MSG_SZ];
            snprintf(msg, sizeof(msg), "--begin: %s is not a datetime", raw);
            watch_fail(s, msg);
        }
        return 0;
    }
    if (kind == TC_WIN_SINCE) {
        const char *raw = opts->since_raw[0] != '\0' ? opts->since_raw : NULL;
        const char *v = NULL;
        int src;
        int64_t delta;
        int st;
        int64_t end_epoch;
        int64_t begin_epoch;
        if (raw == NULL) {
            if (tc_env_get("TWITCH_SINCE", &v) && v != NULL && v[0] != '\0') {
                raw = v;
            } else if (tc_config_get("since", TC_SEC_NONE, &v, &src)
                       && v != NULL && v[0] != '\0') {
                raw = v;
            }
        }
        if (raw == NULL) {
            *begin_ymd = 0;
            *begin_sod = 0;
            return 0;
        }
        delta = tc_parse_duration(raw, &st);
        if (st != 0) {
            char msg[WATCH_MSG_SZ];
            snprintf(msg, sizeof(msg), "--since: unrecognized duration %s",
                     raw);
            watch_fail(s, msg);
        }
        end_epoch = tc_ymd_sod_to_epoch(end_ymd, end_sod);
        begin_epoch = end_epoch - delta;
        tc_epoch_to_ymd_sod(begin_epoch, begin_ymd, begin_sod);
        return 0;
    }
    /* TC_WIN_USERS: begin = end - the sized width (set during priming) */
    if (s->users_width > 0) {
        int64_t end_epoch = tc_ymd_sod_to_epoch(end_ymd, end_sod);
        tc_epoch_to_ymd_sod(end_epoch - s->users_width, begin_ymd, begin_sod);
        return 0;
    }
    *begin_ymd = end_ymd;
    *begin_sod = end_sod;
    return 0;
}

/* Re-derive the frame's window (Python resolve_context per redraw). */
static void watch_resolve_window(tc_wsession *s, tc_window *win) {
    const tc_opts *opts = s->opts;
    int64_t end_ymd;
    int64_t end_sod;

    if (opts->src[TC_SET_END] == TC_SRC_DEFAULT_NOW) {
        time_t now = time(NULL);
        struct tm tmv;
        localtime_r(&now, &tmv);
        end_ymd = (int64_t)(tmv.tm_year + TC_TM_YEAR_BASE) * 10000
                  + (int64_t)(tmv.tm_mon + 1) * 100 + tmv.tm_mday;
        end_sod = (int64_t)tmv.tm_hour * TC_SECS_PER_HOUR
                  + (int64_t)tmv.tm_min * 60 + tmv.tm_sec;
    } else {
        if (!tc_parse_datetime(opts->end_raw, 1, &end_ymd, &end_sod)) {
            char msg[WATCH_MSG_SZ];
            snprintf(msg, sizeof(msg), "--end: %s is not a datetime",
                     opts->end_raw);
            watch_fail(s, msg);
        }
    }
    s->end_ymd = end_ymd;
    s->end_sod = end_sod;

    if (s->win_kind == TC_WIN_USERS) {
        /* the sized width is applied to the current end every frame */
        int64_t end_epoch = tc_ymd_sod_to_epoch(end_ymd, end_sod);
        tc_epoch_to_ymd_sod(end_epoch - s->users_width, &s->begin_ymd,
                            &s->begin_sod);
    } else {
        watch_window_start_at(s, end_ymd, end_sod, &s->begin_ymd,
                              &s->begin_sod);
    }
    s->begin_rolls = (s->win_kind == TC_WIN_SINCE
                      || s->win_kind == TC_WIN_USERS);

    win->begin_ymd = s->begin_ymd;
    win->begin_sod = s->begin_sod;
    win->end_ymd = s->end_ymd;
    win->end_sod = s->end_sod;
    win->begin_rolls = s->begin_rolls;
    win->kind = (enum tc_win_kind)s->win_kind;
    win->threshold = opts->min_count;
    win->state_filter = opts->state_filter;
    win->start_source = s->start_source;
    win->users_width = s->users_width;
    win->users_req = s->users_req;
    win->users_found = s->users_found;
}

// ----------------------------------------------------------------------------
// Tint machinery (Python colorizer + fade_color + palette_chooser).
// ----------------------------------------------------------------------------
static int watch_prev_lookup(const tc_color_ctx *ctx, const char *login,
                             int64_t *count_out) {
    int64_t i;
    for (i = 0; i < ctx->prev_n; i++) {
        if (strcmp(ctx->prev[i].login, login) == 0) {
            *count_out = ctx->prev[i].count;
            return 1;
        }
    }
    return 0;
}

static tc_tint_entry *watch_tint_lookup(tc_color_ctx *ctx, const char *login) {
    int64_t i;
    for (i = 0; i < ctx->carried_n; i++) {
        if (strcmp(ctx->carried[i].login, login) == 0) {
            return &ctx->carried[i];
        }
    }
    return NULL;
}

static void watch_tint_remove(tc_color_ctx *ctx, const char *login) {
    int64_t i;
    for (i = 0; i < ctx->carried_n; i++) {
        if (strcmp(ctx->carried[i].login, login) == 0) {
            memmove(&ctx->carried[i], &ctx->carried[i + 1],
                    (size_t)(ctx->carried_n - i - 1)
                        * sizeof(ctx->carried[0]));
            ctx->carried_n--;
            return;
        }
    }
}

static void watch_tint_set(tc_color_ctx *ctx, const char *login, int dir,
                           double when) {
    tc_tint_entry *entry = watch_tint_lookup(ctx, login);
    if (entry == NULL) {
        if (ctx->carried_n >= ctx->carried_cap) {
            int64_t new_cap = ctx->carried_cap == 0 ? WATCH_CARRIED_INIT
                                                    : ctx->carried_cap * 2;
            tc_tint_entry *ne = realloc(ctx->carried,
                                        (size_t)new_cap * sizeof(*ne));
            if (ne == NULL) {
                tc_fail("out of memory");
            }
            ctx->carried = ne;
            ctx->carried_cap = new_cap;
        }
        entry = &ctx->carried[ctx->carried_n];
        memset(entry, 0, sizeof(*entry));
        tc_copy_str_cap(entry->login, login, sizeof(entry->login));
        ctx->carried_n++;
    }
    entry->dir = dir;
    entry->when = when;
}

/* Python fade_color: the shade for a tint of a given age, or NULL once it
   has expired. */
static const char *watch_fade_color(tc_wsession *s, int dir, double age,
                                    double hold) {
    tc_ramp *ramp = &s->ramps[dir];
    if (hold <= 0.0) {
        return ramp->count > 0 ? ramp->seq[0] : NULL;   /* never dim */
    }
    if (age >= hold) {
        return NULL;
    }
    {
        double step = hold / (double)(ramp->count > 0 ? ramp->count : 1);
        int idx = (int)(age / step);
        if (idx >= ramp->count) {
            idx = ramp->count - 1;
        }
        return idx >= 0 ? ramp->seq[idx] : NULL;
    }
}

/* Python palette_chooser: the highest-numbered rule whose match is within
   `hold`, or -1 (fall back to the rise/fall colour). */
static int watch_choose_palette(tc_wsession *s, const char *login,
                                double at_wall, double hold) {
    int best = -1;
    double cutoff = hold <= 0.0 ? 0.0 : at_wall - hold;
    int64_t ri;
    if (!s->hl_active || s->hl_count == 0) {
        return -1;
    }
    for (ri = 0; ri < s->reader_count; ri++) {
        const tc_reader *r = &s->readers[ri];
        int64_t mi;
        for (mi = 0; mi < r->mcount; mi++) {
            const tc_wmatch *m = &r->matches[mi];
            double when;
            if (strcmp(m->login, login) != 0) {
                continue;
            }
            when = (double)tc_ymd_sod_to_epoch(r->ymd, m->second);
            if (when > at_wall || (hold > 0.0 && when < cutoff)) {
                continue;
            }
            if (m->rule > best) {
                best = m->rule;
            }
        }
    }
    return best;
}

/* The per-row colour decision (Python colorizer's inner tint()).  Mutates
   the carried map; returns the ramp sequence (or NULL for plain). */
static const char *watch_colorize_login(tc_color_ctx *ctx, const char *login,
                                        int64_t count) {
    tc_wsession *s = ctx->s;
    int64_t before;
    int have_before;
    tc_tint_entry *entry;
    int dir;
    int palette;
    const char *seq;

    have_before = ctx->prev != NULL
                  && watch_prev_lookup(ctx, login, &before);
    if (ctx->prev == NULL) {
        /* first frame: nothing has moved yet */
    } else if (!have_before || count > before) {
        watch_tint_set(ctx, login, WATCH_RAMP_UP, ctx->now);
    } else if (count < before && ctx->has_down) {
        entry = watch_tint_lookup(ctx, login);
        if (entry == NULL || entry->dir == WATCH_RAMP_DOWN) {
            /* rises outrank falls: while a green is holding, the fall is
               dropped rather than repainting the row grey */
            watch_tint_set(ctx, login, WATCH_RAMP_DOWN, ctx->now);
        }
    }
    entry = watch_tint_lookup(ctx, login);
    if (entry == NULL) {
        return NULL;
    }
    dir = entry->dir;
    palette = watch_choose_palette(s, login, ctx->at_wall, ctx->hold);
    if (palette >= 0) {
        dir = WATCH_RAMP_HL(palette);
    }
    seq = watch_fade_color(s, dir, ctx->now - entry->when, ctx->hold);
    if (seq == NULL) {
        watch_tint_remove(ctx, login);
        return NULL;
    }
    return seq;
}

/* The render hook (tc_tint_fn): tint one rendered row, returning the text
   buffer render.c copies into the frame. */
static char *watch_tint_row(char *text, const char *login, int64_t count,
                            void *ctx_) {
    tc_color_ctx *ctx = ctx_;
    const char *seq;
    char *out = ctx->out;

    if (!ctx->enabled) {
        return text;
    }
    seq = watch_colorize_login(ctx, login, count);
    if (seq == NULL) {
        return text;
    }
    snprintf(out, sizeof(ctx->out), "%s%s" WATCH_ANSI_RESET, seq, text);
    return out;
}

/* Drop carried tints that have already expired (Python colorizer's opening
   filter). */
static void watch_drop_expired(tc_color_ctx *ctx) {
    int64_t i;
    if (ctx->hold <= 0.0) {
        return;
    }
    i = 0;
    while (i < ctx->carried_n) {
        if (ctx->now - ctx->carried[i].when >= ctx->hold) {
            memmove(&ctx->carried[i], &ctx->carried[i + 1],
                    (size_t)(ctx->carried_n - i - 1)
                        * sizeof(ctx->carried[0]));
            ctx->carried_n--;
        } else {
            i++;
        }
    }
}

/* Rebuild the previous-counts map from the just-counted users table (Python
   `previous = counts`). */
static void watch_build_prev(tc_wsession *s) {
    tc_color_ctx *ctx = &s->color;
    const tc_excl_set *exclusions = &s->inputs->exclusions;
    int filter = s->context.window.state_filter;
    int64_t i;

    ctx->prev_n = 0;
    for (i = 0; i < s->users.count; i++) {
        const tc_user_entry *entry = &s->users.entries[i];
        size_t llen = strlen(entry->login);
        int64_t count;
        if (tc_excl_contains(exclusions, entry->login, llen)) {
            continue;
        }
        count = watch_count_column(entry, filter);
        if (count <= 0) {
            continue;
        }
        if (ctx->prev_n >= ctx->prev_cap) {
            int64_t new_cap = ctx->prev_cap == 0 ? WATCH_PREV_INIT
                                                 : ctx->prev_cap * 2;
            tc_prev_entry *ne = realloc(ctx->prev,
                                        (size_t)new_cap * sizeof(*ne));
            if (ne == NULL) {
                tc_fail("out of memory");
            }
            ctx->prev = ne;
            ctx->prev_cap = new_cap;
        }
        tc_copy_str_cap(ctx->prev[ctx->prev_n].login, entry->login,
                        sizeof(ctx->prev[0].login));
        ctx->prev[ctx->prev_n].count = count;
        ctx->prev_n++;
    }
}

// ----------------------------------------------------------------------------
// The launch replay (Python replay_horizon / replay_tints / launch_tints).
// ----------------------------------------------------------------------------
static double watch_replay_horizon(double hold, double interval,
                                   int64_t max_steps) {
    double horizon = hold > 0.0 ? hold : interval * (double)max_steps;
    int64_t n = (int64_t)(horizon / interval);
    if (n < 1) {
        n = 1;
    }
    if (n > max_steps) {
        n = max_steps;
    }
    return (double)n * interval;
}

/* Per-login filtered counts for a window [begin_epoch, end_epoch] summed from
   the readers' buckets (Python replay_tints' counts Counter). */
static void watch_window_counts(tc_wsession *s, int64_t begin_epoch,
                                int64_t end_epoch, int filter,
                                tc_color_ctx *ctx) {
    int64_t begin_ymd, begin_sod, end_ymd, end_sod;
    int64_t ri;

    tc_epoch_to_ymd_sod(begin_epoch, &begin_ymd, &begin_sod);
    tc_epoch_to_ymd_sod(end_epoch, &end_ymd, &end_sod);
    ctx->prev_n = 0;
    for (ri = 0; ri < s->reader_count; ri++) {
        const tc_reader *r = &s->readers[ri];
        int64_t lo;
        int64_t hi;
        int64_t bi;
        if (r->ymd < begin_ymd || r->ymd > end_ymd) {
            continue;
        }
        lo = begin_ymd < r->ymd ? 0 : begin_sod;
        hi = end_ymd > r->ymd ? TC_LAST_SECOND : end_sod;
        if (lo > hi) {
            continue;
        }
        for (bi = 0; bi < r->bcount; bi++) {
            const tc_wbucket *b = &r->buckets[bi];
            int64_t pi;
            if (b->second < lo || b->second > hi) {
                continue;
            }
            if (filter != TC_ST_NONE && b->state != filter) {
                continue;
            }
            for (pi = 0; pi < ctx->prev_n; pi++) {
                if (strcmp(ctx->prev[pi].login, b->login) == 0) {
                    ctx->prev[pi].count += b->n;
                    break;
                }
            }
            if (pi == ctx->prev_n) {
                if (ctx->prev_n >= ctx->prev_cap) {
                    int64_t new_cap = ctx->prev_cap == 0 ? WATCH_PREV_INIT
                                                         : ctx->prev_cap * 2;
                    tc_prev_entry *ne = realloc(
                        ctx->prev, (size_t)new_cap * sizeof(*ne));
                    if (ne == NULL) {
                        tc_fail("out of memory");
                    }
                    ctx->prev = ne;
                    ctx->prev_cap = new_cap;
                }
                tc_copy_str_cap(ctx->prev[ctx->prev_n].login, b->login,
                                sizeof(ctx->prev[0].login));
                ctx->prev[ctx->prev_n].count = b->n;
                ctx->prev_n++;
            }
        }
    }
}

/* Python replay_tints: step a virtual clock from `hold` ago up to now through
   the real colorizer, so the first frame arrives already coloured. */
static void watch_launch_tints(tc_wsession *s) {
    tc_color_ctx *ctx = &s->color;
    double hold = s->hold;
    double interval = s->interval;
    double now;
    double horizon;
    int64_t steps;
    int64_t step;
    int64_t end_epoch;
    int64_t begin_epoch;
    tc_prev_entry *prev_map = NULL;     /* the previous step's counts */
    int64_t prev_n = 0;
    int filter;

    if (s->reader_count == 0 || s->replay_steps == 0) {
        return;
    }
    now = watch_monotonic();
    horizon = watch_replay_horizon(hold, interval, s->replay_steps);
    steps = (int64_t)(horizon / interval);
    if (steps < 1) {
        steps = 1;
    }
    end_epoch = tc_ymd_sod_to_epoch(s->end_ymd, s->end_sod);
    begin_epoch = tc_ymd_sod_to_epoch(s->begin_ymd, s->begin_sod);
    filter = s->context.window.state_filter;

    for (step = steps; step >= 0; step--) {
        double back = (double)step * interval;
        int64_t at_end = end_epoch - (int64_t)back;
        int64_t at_begin = s->begin_rolls ? begin_epoch - (int64_t)back
                                          : begin_epoch;
        int64_t i;
        tc_color_ctx step_ctx;

        memset(&step_ctx, 0, sizeof(step_ctx));
        step_ctx.s = s;
        step_ctx.hold = hold;
        step_ctx.enabled = 1;
        step_ctx.has_down = s->ramp_count > WATCH_RAMP_DOWN;
        step_ctx.now = now - back;
        step_ctx.at_wall = (double)at_end;
        step_ctx.prev = prev_map;       /* the previous step's counts */
        step_ctx.prev_n = prev_n;
        step_ctx.carried = ctx->carried;
        step_ctx.carried_n = ctx->carried_n;
        step_ctx.carried_cap = ctx->carried_cap;

        /* sum the window's filtered counts into the session's prev map */
        watch_window_counts(s, at_begin, at_end, filter, ctx);

        /* feed each count through the colorizer for its effect on the tints */
        for (i = 0; i < ctx->prev_n; i++) {
            (void)watch_colorize_login(&step_ctx, ctx->prev[i].login,
                                       ctx->prev[i].count);
        }

        /* carry the tint state into the next (younger) step */
        ctx->carried = step_ctx.carried;
        ctx->carried_n = step_ctx.carried_n;
        ctx->carried_cap = step_ctx.carried_cap;

        /* the current counts become the next step's previous */
        free(prev_map);
        prev_map = ctx->prev;
        prev_n = ctx->prev_n;
        ctx->prev = NULL;
        ctx->prev_n = 0;
        ctx->prev_cap = 0;
    }
    free(prev_map);
    /* the live loop's first frame has previous = None, exactly like Python's
       run_watch (`previous = None` before the loop) */
    ctx->prev_n = 0;
}

// ----------------------------------------------------------------------------
// The status line (Python watch_status).
// ----------------------------------------------------------------------------
static void watch_status(char *dst, size_t cap, double interval, double hold,
                         const char *interval_src, const char *hold_src,
                         double elapsed, int show_timing, const char *woke) {
    char held[32];
    size_t used;

    if (hold <= 0.0) {
        snprintf(held, sizeof(held), "indefinite");
    } else {
        snprintf(held, sizeof(held), "%gs", hold);
    }
    used = (size_t)snprintf(dst, cap, "every %gs (%s), hold %s (%s)",
                            interval, interval_src, held, hold_src);
    if (show_timing) {
        snprintf(dst + used, cap - used, ", tick %.0fms",
                 elapsed * 1000.0);
        used = strlen(dst);
        if (woke != NULL) {
            snprintf(dst + used, cap - used, ", woke on %s", woke);
            used = strlen(dst);
        }
    }
    if (elapsed > interval) {
        snprintf(dst + used, cap - used, " -- %.0fms tick, slower than the "
                                         "interval", elapsed * 1000.0);
    }
}

// ----------------------------------------------------------------------------
// The screen (Python Screen.paint + clip).
// ----------------------------------------------------------------------------
static void watch_screen_free(tc_screen *screen) {
    int64_t i;
    for (i = 0; i < screen->painted_n; i++) {
        free(screen->painted[i]);
    }
    free(screen->painted);
    memset(screen, 0, sizeof(*screen));
}

/* Python clip: cut a line to a visible width, keeping escape sequences.
   Visible width counts *codepoints*, not bytes: a UTF-8 continuation byte
   (10xxxxxx, e.g. the 2nd/3rd byte of the "…" ellipsis login_cell emits)
   must not add to the column count, or a line containing one gets measured
   as wider than it actually displays and the tail (here, the count column)
   gets clipped off. */
static void watch_clip(char *dst, size_t cap, const char *text, int width) {
    size_t out = 0;
    size_t i = 0;
    size_t vis = 0;
    int had_esc = 0;

    if (cap == 0) {
        return;
    }
    /* measure the visible width first */
    {
        size_t j = 0;
        size_t v = 0;
        while (text[j] != '\0') {
            if (text[j] == '\033') {
                had_esc = 1;
                while (text[j] != '\0'
                       && !((text[j] >= 'A' && text[j] <= 'Z')
                            || (text[j] >= 'a' && text[j] <= 'z'))) {
                    j++;
                }
                if (text[j] != '\0') {
                    j++;
                }
                continue;
            }
            if (((unsigned char)text[j] & 0xC0) != 0x80) {
                v++;
            }
            j++;
        }
        if ((int)v <= width) {
            tc_copy_str_cap(dst, text, cap);
            return;
        }
    }
    while (text[i] != '\0' && vis < (size_t)width && out + 1 < cap) {
        if (text[i] == '\033') {
            size_t start = i;
            while (text[i] != '\0'
                   && !((text[i] >= 'A' && text[i] <= 'Z')
                        || (text[i] >= 'a' && text[i] <= 'z'))) {
                i++;
            }
            if (text[i] != '\0') {
                i++;
            }
            {
                size_t len = i - start;
                if (out + len + 2 >= cap) {
                    break;
                }
                memcpy(dst + out, text + start, len);
                out += len;
            }
            continue;
        }
        if (((unsigned char)text[i] & 0xC0) != 0x80) {
            vis++;
        }
        dst[out++] = text[i++];
    }
    if (had_esc && out + strlen(WATCH_ANSI_RESET) + 1 < cap) {
        memcpy(dst + out, WATCH_ANSI_RESET, strlen(WATCH_ANSI_RESET));
        out += strlen(WATCH_ANSI_RESET);
    }
    dst[out] = '\0';
}

/* Python Screen.paint: emit the whole frame on a full repaint, else only the
   changed lines, addressed absolutely. */
static void watch_screen_paint(tc_screen *screen, char *const *lines,
                               int64_t n) {
    int width = tc_term_columns();
    char **frame = NULL;
    char *out = NULL;
    size_t out_len = 0;
    size_t need;
    int full;
    int64_t i;

    frame = malloc((size_t)(n > 0 ? n : 1) * sizeof(char *));
    if (frame == NULL) {
        tc_fail("out of memory");
    }
    for (i = 0; i < n; i++) {
        frame[i] = malloc(WATCH_LINE_SZ + 64);
        if (frame[i] == NULL) {
            tc_fail("out of memory");
        }
        watch_clip(frame[i], WATCH_LINE_SZ + 64, lines[i], width);
    }

    full = (screen->painted_n == 0 || width != screen->width
            || (screen->full_every
                && screen->since_full >= screen->full_every));
    need = 16 + (size_t)n * (WATCH_LINE_SZ + 64 + 8);
    out = malloc(need);
    if (out == NULL) {
        tc_fail("out of memory");
    }
    if (full) {
        memcpy(out, "\033[2J\033[H", 7);
        out_len = 7;
        for (i = 0; i < n; i++) {
            size_t l = strlen(frame[i]);
            memcpy(out + out_len, frame[i], l);
            out_len += l;
            memcpy(out + out_len, "\033[K\n", 4);
            out_len += 4;
        }
        memcpy(out + out_len, "\033[J", 3);
        out_len += 3;
        screen->since_full = 0;
    } else {
        for (i = 0; i < n; i++) {
            size_t l;
            if (i < screen->painted_n
                && strcmp(screen->painted[i], frame[i]) == 0) {
                continue;
            }
            l = (size_t)snprintf(out + out_len, need - out_len,
                                 "\033[%lld;1H", (long long)(i + 1));
            out_len += l;
            l = strlen(frame[i]);
            memcpy(out + out_len, frame[i], l);
            out_len += l;
            memcpy(out + out_len, "\033[K", 3);
            out_len += 3;
        }
        if (n < screen->painted_n) {
            size_t l = (size_t)snprintf(out + out_len, need - out_len,
                                        "\033[%lld;1H\033[J",
                                        (long long)(n + 1));
            out_len += l;
        }
        screen->since_full++;
    }
    out[out_len] = '\0';

    /* swap the painted frame */
    for (i = 0; i < screen->painted_n; i++) {
        free(screen->painted[i]);
    }
    if (screen->painted_n < n && screen->painted_cap < n) {
        char **np = realloc(screen->painted, (size_t)n * sizeof(char *));
        if (np == NULL) {
            tc_fail("out of memory");
        }
        screen->painted = np;
        screen->painted_cap = n;
    }
    for (i = 0; i < n; i++) {
        screen->painted[i] = frame[i];
    }
    screen->painted_n = n;
    screen->width = width;
    free(frame);

    if (out_len > 0) {
        tc_puts(out);
    }
    free(out);
}

// ----------------------------------------------------------------------------
// Selection/report construction.
// ----------------------------------------------------------------------------
static void watch_fill_selection(tc_wsession *s) {
    tc_selection *sel = &s->selection;
    const tc_tally *tally = &s->tally;

    memset(sel, 0, sizeof(*sel));
    sel->users = &s->users;
    sel->total_messages = tally->messages;
    sel->files = tally->files;
    sel->parsed = tally->parsed;
    sel->reused = tally->reused;
    sel->states[0] = tally->states[0];
    sel->states[1] = tally->states[1];
    sel->states[2] = tally->states[2];
    sel->excluded_counts = tally->excluded_states[0]
                         + tally->excluded_states[1]
                         + tally->excluded_states[2];
    sel->exclusions = &s->inputs->exclusions;
    sel->cache = s->cache;
    sel->cache_problem = s->cache_problem;
    sel->unreadable_count = tally->unreadable_count;
    if (tally->unreadable_count > 0) {
        memcpy(sel->unreadable, tally->unreadable,
               (size_t)tally->unreadable_count * sizeof(tc_unreadable_entry));
    }
}

/* Count + lay out + capture one frame.  Returns the captured line count. */
static int64_t watch_render_frame(tc_wsession *s, double now,
                                  double at_wall) {
    tc_window *win = &s->context.window;
    tc_report *report = &s->report;
    int64_t pin;

    watch_resolve_window(s, win);
    watch_count(s, win, &s->users, &s->tally);
    watch_fill_selection(s);

    report->args = (tc_opts *)s->opts;
    report->context = &s->context;
    report->selection = &s->selection;

    /* the tint state for this frame */
    s->color.s = s;
    s->color.now = now;
    s->color.at_wall = at_wall;
    s->color.hold = s->hold;
    s->color.has_down = s->ramp_count > WATCH_RAMP_DOWN;
    watch_drop_expired(&s->color);

    pin = s->user_width > 0 ? s->user_width : 0;
    s->frame.capture = 0;
    s->frame.lines = (const char **)s->frame_lines;
    s->frame.max = s->frame_max;
    s->frame.count = 0;
    s->frame.pin_width = 0;
    s->frame.tint_fn = NULL;
    s->frame.tint_ctx = NULL;

    if (tc_plan_presentation(report) != TC_EXIT_OK) {
        return 0;
    }
    tc_frame_set_pin(&s->frame, (int)pin);
    if (s->color.enabled) {
        tc_frame_set_tint(&s->frame, watch_tint_row, &s->color);
    }
    tc_frame_begin(&s->frame);
    tc_render_text(report);
    tc_frame_end(&s->frame);

    return s->frame.count;
}

// ----------------------------------------------------------------------------
// The loop (Python run_watch).
// ----------------------------------------------------------------------------
static double watch_next_tint_change(const tc_tint_entry *carried,
                                     int64_t carried_n, double hold,
                                     int64_t shades, double now) {
    double step;
    double soonest = -1.0;
    int64_t i;
    if (hold <= 0.0 || carried_n == 0) {
        return -1.0;
    }
    step = hold / (double)(shades > 1 ? shades : 1);
    for (i = 0; i < carried_n; i++) {
        double age = now - carried[i].when;
        double due;
        int64_t idx;
        if (age >= hold) {
            continue;               /* already expired: the row is plain */
        }
        idx = (int64_t)(age / step) + 1;
        due = carried[i].when + (double)idx * step;
        if (due > carried[i].when + hold) {
            due = carried[i].when + hold;
        }
        if (soonest < 0.0 || due < soonest) {
            soonest = due;
        }
    }
    return soonest;
}

static void watch_sigint_handler(int sig) {
    (void)sig;
    g_watch_interrupted = 1;
}

/* "now" as a naive-civil epoch (Python datetime.now() -> the replay's and
   the ladder's wall clock). */
static double watch_wall_now(void);

static int watch_run_loop(tc_wsession *s) {
    tc_watcher *changes = s->watcher;
    tc_screen *screen = &s->screen;
    double interval = s->interval;
    double min_redraw = s->min_redraw;
    double painted_at = -1.0;
    int first = 1;
    char status_buf[256];
    char wake_buf[16];
    const char *woke;

    tc_puts("\033[?25l");           /* hide the cursor; it would blink */

    while (!g_watch_interrupted) {
        double started;
        double elapsed;
        double wait;
        double due;
        double now_wall;
        int64_t count;
        int64_t i;

        /* a floor on how often a write can force a redraw */
        if (painted_at >= 0.0 && min_redraw > 0.0) {
            double early = min_redraw - (watch_monotonic() - painted_at);
            if (early > 0.0) {
                watch_sleep(early);
            }
        }
        started = watch_monotonic();
        now_wall = watch_wall_now();
        count = watch_render_frame(s, started, now_wall);
        elapsed = watch_monotonic() - started;

        woke = NULL;
        if (changes->enabled) {
            snprintf(wake_buf, sizeof(wake_buf), "%s",
                     (changes->woke_on_write && !first) ? "write" : "timer");
            woke = wake_buf;
        }
        watch_status(status_buf, sizeof(status_buf), interval, s->hold,
                     tc_source_str(s->opts->src[TC_SET_INTERVAL]),
                     tc_source_str(s->opts->src[TC_SET_HOLD]), elapsed,
                     s->show_timing, woke);

        {
            char *frame_lines[WATCH_FRAME_MAX + 2];
            int64_t n = count;
            if (count > WATCH_FRAME_MAX) {
                n = WATCH_FRAME_MAX;
            }
            for (i = 0; i < n; i++) {
                frame_lines[i] = s->frame_lines[i];
            }
            if (n + 1 < WATCH_FRAME_MAX + 2) {
                frame_lines[n] = s->frame_lines[WATCH_FRAME_MAX];
                s->frame_lines[WATCH_FRAME_MAX][0] = '\0';
                frame_lines[n + 1] = s->frame_lines[WATCH_FRAME_MAX + 1];
                snprintf(s->frame_lines[WATCH_FRAME_MAX + 1], WATCH_LINE_SZ,
                         "watching -- %s -- Ctrl-C to stop", status_buf);
                n += 2;
            }
            watch_screen_paint(screen, frame_lines, n);
        }
        painted_at = watch_monotonic();

        /* the next frame compares against these counts */
        watch_build_prev(s);
        first = 0;

        /* arm the watcher on the current reader set */
        tc_watcher_clear(changes);
        for (i = 0; i < s->reader_count; i++) {
            tc_watcher_add(changes, s->readers[i].path);
        }

        /* wake for whichever comes first: the next shade step, or the
           interval (the watcher cuts either short on a write) */
        wait = interval - elapsed;
        due = watch_next_tint_change(s->color.carried, s->color.carried_n,
                                     s->hold, s->shades, watch_monotonic());
        if (due >= 0.0) {
            double until = due - watch_monotonic();
            if (until < wait) {
                wait = until;
            }
        }
        if (wait < 0.0) {
            wait = 0.0;
        }
        tc_watcher_poll(changes, wait);
    }
    return TC_EXIT_OK;
}

// ----------------------------------------------------------------------------
// The watcher seam (kqueue on macOS, polling on Linux — the Python's exact
// behaviour: Linux with notify on fails loudly).
// ----------------------------------------------------------------------------
tc_watcher *tc_watcher_new(int notify, int max_events) {
    tc_watcher *w;
    if (max_events <= 0) {
        max_events = 4;             /* setting_default("max_events") */
    }
#if TC_PLATFORM_MACOS
    if (notify) {
        w = calloc(1, sizeof(*w));
        if (w == NULL) {
            tc_fail("out of memory");
        }
        w->enabled = 1;
        w->max_events = max_events;
        w->kq = kqueue();
        if (w->kq < 0) {
            free(w);
            tc_fail("kqueue: unable to open a change-notification queue");
        }
        return w;
    }
#else
    if (notify) {
        tc_fail("TODO - not implemented: change notification on Linux. set "
                "[tail] notify = false to poll on the interval instead");
    }
#endif
    w = calloc(1, sizeof(*w));
    if (w == NULL) {
        tc_fail("out of memory");
    }
    w->enabled = 0;
    w->max_events = max_events;
    return w;
}

void tc_watcher_free(tc_watcher *w) {
    if (w == NULL) {
        return;
    }
    tc_watcher_clear(w);
#if TC_PLATFORM_MACOS
    if (w->kq >= 0) {
        close(w->kq);
    }
#endif
    free(w);
}

int tc_watcher_add(tc_watcher *w, const char *path) {
#if TC_PLATFORM_MACOS
    int fd;
    struct kevent ev;
    if (w == NULL || !w->enabled) {
        return 0;
    }
    fd = open(path, O_RDONLY);
    if (fd < 0) {
        return -1;                  /* a file we cannot open is not watched */
    }
    if (w->handle_count >= w->handle_cap) {
        int new_cap = w->handle_cap == 0 ? 8 : w->handle_cap * 2;
        void *nh = realloc(w->handles, (size_t)new_cap * sizeof(*w->handles));
        if (nh == NULL) {
            close(fd);
            return -1;
        }
        w->handles = nh;
        w->handle_cap = new_cap;
    }
    w->handles[w->handle_count].fd = fd;
    tc_copy_str_cap(w->handles[w->handle_count].path, path,
                    sizeof(w->handles[0].path));
    EV_SET(&ev, (uintptr_t)fd, EVFILT_VNODE,
           EV_ADD | EV_ENABLE | EV_CLEAR,
           NOTE_WRITE | NOTE_EXTEND | NOTE_DELETE | NOTE_RENAME, 0, 0);
    if (kevent(w->kq, &ev, 1, NULL, 0, NULL) < 0) {
        close(fd);
        return -1;
    }
    w->handle_count++;
    return 0;
#else
    (void)w;
    (void)path;
    return 0;                       /* polling needs no handles */
#endif
}

int tc_watcher_poll(tc_watcher *w, double timeout_s) {
    if (w == NULL || timeout_s <= 0.0) {
        return 0;
    }
#if TC_PLATFORM_MACOS
    if (w->enabled && w->handle_count > 0) {
        struct timespec ts;
        struct kevent events[64];
        int n;
        ts.tv_sec = (time_t)timeout_s;
        ts.tv_nsec = (long)((timeout_s - (double)ts.tv_sec) * 1000000000.0);
        n = kevent(w->kq, NULL, 0, events,
                   w->max_events > 64 ? 64 : w->max_events, &ts);
        if (n < 0) {
            if (errno == EINTR && g_watch_interrupted) {
                return 0;
            }
            return -1;
        }
        if (n > 0) {
            w->woke_on_write++;
            return 1;
        }
        w->woke_on_timer++;
        return 0;
    }
#endif
    watch_sleep(timeout_s);
    w->woke_on_timer++;
    return 0;
}

void tc_watcher_clear(tc_watcher *w) {
    if (w == NULL) {
        return;
    }
#if TC_PLATFORM_MACOS
    {
        int i;
        for (i = 0; i < w->handle_count; i++) {
            close(w->handles[i].fd);
        }
        w->handle_count = 0;
    }
#else
    (void)w;
#endif
}

// ----------------------------------------------------------------------------
// Session lifecycle.
// ----------------------------------------------------------------------------
static void watch_session_free(tc_wsession *s) {
    int64_t i;
    int r;
    if (s->watcher != NULL) {
        tc_watcher_free(s->watcher);
        s->watcher = NULL;
    }
    if (s->cache != NULL) {
        tc_cache_close(s->cache);
        s->cache = NULL;
    }
    for (i = 0; i < s->reader_count; i++) {
        watch_reader_free(&s->readers[i]);
    }
    free(s->readers);
    free(s->listing.entries);
    free(s->users.entries);
    free(s->day_users.entries);
    free(s->color.prev);
    free(s->color.carried);
    for (r = 0; r < s->ramp_count; r++) {
        watch_ramp_free(&s->ramps[r]);
    }
    watch_free_highlights(s);
    if (s->frame_lines != NULL) {
        for (i = 0; i < s->frame_max + 2; i++) {
            free(s->frame_lines[i]);
        }
        free(s->frame_lines);
    }
    watch_screen_free(&s->screen);
    free(s->report.plan.reported);
    free(s->report.plan.excl_names);
}

static void watch_session_init(tc_wsession *s, const tc_opts *opts,
                               const tc_inputs *inputs) {
    memset(s, 0, sizeof(*s));
    s->opts = opts;
    s->inputs = inputs;
    s->win_kind = inputs->kind;
    s->users_req = opts->users;
    s->frame_max = WATCH_FRAME_MAX;
    s->color.s = s;
    s->screen.full_every = 0;
    s->day_tally.users = &s->day_users;
}

/* "now" as a naive-civil epoch (Python datetime.now() -> the replay's and
   the ladder's wall clock). */
static double watch_wall_now(void) {
    int64_t ymd;
    int64_t sod;
    time_t now = time(NULL);
    struct tm tmv;
    localtime_r(&now, &tmv);
    ymd = (int64_t)(tmv.tm_year + TC_TM_YEAR_BASE) * 10000
          + (int64_t)(tmv.tm_mon + 1) * 100 + tmv.tm_mday;
    sod = (int64_t)tmv.tm_hour * TC_SECS_PER_HOUR
          + (int64_t)tmv.tm_min * 60 + tmv.tm_sec;
    return (double)tc_ymd_sod_to_epoch(ymd, sod);
}

// ----------------------------------------------------------------------------
// tc_watch_run — the watch entry point.
// ----------------------------------------------------------------------------
int tc_watch_run(const tc_opts *opts, const tc_inputs *inputs) {
    tc_wsession session;
    tc_wsession *s = &session;
    tc_window *win;
    int status;
    struct sigaction sa;
    int color_enabled;
    int64_t i;

    if (!isatty(1)) {
        tc_fail("--watch needs a terminal (it repaints in place)");
    }

    watch_session_init(s, opts, inputs);
    tc_aliases_apply((tc_opts *)opts);

    watch_resolve_settings(s);
    watch_resolve_tail(s);
    watch_parse_highlights(s);
    watch_build_ramps(s);

    /* the report context: everything the plan/header reads besides the
       per-frame window */
    s->context.settings = (tc_opts *)opts;
    s->context.config = inputs->config;
    s->context.config_loaded = inputs->config_loaded;
    tc_copy_str_cap(s->context.config_path, inputs->config_path,
                    sizeof(s->context.config_path));
    tc_copy_str_cap(s->context.channel_dir, inputs->channel_dir,
                    sizeof(s->context.channel_dir));
    tc_copy_str_cap(s->context.channel_name, inputs->channel_name,
                    sizeof(s->context.channel_name));
    s->context.tail.notify = s->notify;
    s->context.tail.max_events = s->max_events;
    s->context.tail.seed_lookback = s->seed_lookback;
    s->context.exclusions = inputs->exclusions;

    /* colour: --color wins; auto = tty and not NO_COLOR (Python
       color_enabled). */
    if (opts->color_mode == TC_COLOR_NEVER) {
        color_enabled = 0;
    } else if (opts->color_mode == TC_COLOR_ALWAYS) {
        color_enabled = 1;
    } else {
        color_enabled = isatty(1) && getenv("NO_COLOR") == NULL;
    }
    s->color.enabled = color_enabled;

    /* one rollup connection for the life of the loop */
    if (!(opts->flags & TC_F_NO_CACHE)) {
        if (tc_default_cache_path(s->cache_path, sizeof(s->cache_path)) > 0) {
            tc_cache_open(s->cache_path,
                          (opts->flags & TC_F_REBUILD_CACHE) ? 1 : 0,
                          inputs->channel_name, &s->cache, &s->cache_problem);
        }
    }

    /* retention floors (Python session_floors) */
    s->retain_seconds = (int64_t)watch_replay_horizon(
        s->hold, s->interval, s->replay_steps);
    s->match_seconds = s->hold > 0.0 ? (int64_t)s->hold : 0;

    /* the base window + the launch prime */
    watch_listing_refresh(s);
    win = &s->context.window;
    watch_resolve_window(s, win);
    if (s->win_kind == TC_WIN_USERS) {
        s->start_source = opts->win_src;
        watch_size_users(s, win);
        s->begin_ymd = win->begin_ymd;
        s->begin_sod = win->begin_sod;
    } else if (s->win_kind == TC_WIN_EARLIEST) {
        s->start_source = "default: earliest log file";
        if (s->listing.count > 0) {
            s->begin_ymd = s->listing.entries[0].ymd;
            s->begin_sod = 0;
        }
    } else if (s->win_kind == TC_WIN_BEGIN) {
        s->start_source = "--begin";
    } else if (s->win_kind == TC_WIN_SINCE) {
        s->start_source = opts->win_src[0] != '\0' ? opts->win_src
                                                   : "--since";
    }
    win->start_source = s->start_source;

    /* prime the readers + count once (Python build_report_data) */
    watch_count(s, win, &s->users, &s->tally);

    /* the launch replay tints the first frame */
    watch_launch_tints(s);

    /* the watcher: Linux with notify on fails loudly here, exactly like the
       Python's Unsupported raise at this point in run_watch */
    s->watcher = tc_watcher_new(s->notify, (int)s->max_events);
    s->screen.full_every = s->full_repaint;

    /* frame line buffers */
    s->frame_lines = malloc((size_t)(s->frame_max + 2) * sizeof(char *));
    if (s->frame_lines == NULL) {
        tc_fail("out of memory");
    }
    for (i = 0; i < s->frame_max + 2; i++) {
        s->frame_lines[i] = malloc(WATCH_LINE_SZ);
        if (s->frame_lines[i] == NULL) {
            tc_fail("out of memory");
        }
        s->frame_lines[i][0] = '\0';
    }

    /* SIGINT is a request: the loop latches it and returns 0, restoring the
       cursor (Python's `except KeyboardInterrupt: pass` in run_watch). */
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = watch_sigint_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, NULL);

    status = watch_run_loop(s);

    tc_puts("\033[?25h\n");         /* restore the cursor */
    watch_session_free(s);
    return status;
}