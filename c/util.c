// ============================================================================
// util.c — shared helpers and the platform path defaults.
//
// The foundation spine (puts/eputs/putu64/fail) and the per-OS path defaults
// are real; this file fills in the string/format helpers, the proleptic
// Gregorian calendar (Howard Hinnant's civil algorithms, verified against
// Python's datetime for years 1..9999), the env/terminal helpers, the file
// reader and the shared state/metric name tables.
// ============================================================================

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <pwd.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>

#ifdef __linux__
#include <sys/ioctl.h>
#endif

// ----------------------------------------------------------------------------
// The selected platform (mirrors Python's PLATFORM singleton).
// ----------------------------------------------------------------------------
const tc_platform tc_platform_current = {
#if TC_PLATFORM_MACOS
    "macOS",
    "~/Library/Application Support/chatterino/Logs/Twitch/Channels"
#else
    "Linux",
    "~/.local/share/chatterino/Logs/Twitch/Channels"
#endif
};

// ----------------------------------------------------------------------------
// Output spine.  tc_putu64 formats through the shared tc_fmt_u64 so every
// number on stdout goes through one writer (decimal digits, then tc_puts).
// ----------------------------------------------------------------------------
void tc_puts(const char *s) {
    fputs(s, stdout);
    fflush(stdout);
}

void tc_eputs(const char *s) {
    fputs(s, stderr);
    fflush(stderr);
}

void tc_putu64(uint64_t v) {
    char buf[24];
    char *end = tc_fmt_u64(buf, v);
    *end = '\0';
    tc_puts(buf);
}

void tc_fail(const char *msg) {
    tc_eputs("error: ");
    tc_eputs(msg);
    tc_eputs("\n");
    exit(TC_EXIT_ERROR);
}

// ----------------------------------------------------------------------------
// Per-OS path defaults — mirrors the Python MacOS/Linux Platform classes;
// returns the string length, or 0 for "no default on this platform".
// ----------------------------------------------------------------------------
size_t tc_default_config_path(char *dst, size_t cap) {
#if TC_PLATFORM_MACOS
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        return 0;
    }
    return (size_t)snprintf(dst, cap, "%s/.config/twitch-counts.toml", home);
#else
    const char *xdg = getenv("XDG_CONFIG_HOME");
    if (xdg != NULL && xdg[0] != '\0') {
        return (size_t)snprintf(dst, cap, "%s/twitch-counts.toml", xdg);
    }
    {
        const char *home = getenv("HOME");
        if (home == NULL || home[0] == '\0') {
            return 0;
        }
        return (size_t)snprintf(dst, cap, "%s/.config/twitch-counts.toml", home);
    }
#endif
}

size_t tc_default_cache_path(char *dst, size_t cap) {
#if TC_PLATFORM_MACOS
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        return 0;
    }
    return (size_t)snprintf(dst, cap, "%s/.cache/twitch-counts/rollup.db", home);
#else
    const char *xdg = getenv("XDG_CACHE_HOME");
    if (xdg != NULL && xdg[0] != '\0') {
        return (size_t)snprintf(dst, cap, "%s/twitch-counts/rollup.db", xdg);
    }
    {
        const char *home = getenv("HOME");
        if (home == NULL || home[0] == '\0') {
            return 0;
        }
        return (size_t)snprintf(dst, cap, "%s/.cache/twitch-counts/rollup.db", home);
    }
#endif
}

size_t tc_platform_default_logs_dir(char *dst, size_t cap) {
#if TC_PLATFORM_MACOS
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        return 0;
    }
    return (size_t)snprintf(dst, cap,
                            "%s/Library/Application Support/chatterino/Logs/"
                            "Twitch/Channels",
                            home);
#else
    /* Linux: the path is believed correct but unverified; the Python raises
       TODO and names --logs-dir, so the C port reports "no default" too. */
    (void)dst;
    (void)cap;
    return 0;
#endif
}

// ----------------------------------------------------------------------------
// String/format helpers.
// ----------------------------------------------------------------------------
size_t tc_strlen(const char *s) {
    return strlen(s);
}

/* Write the decimal digits of v into dst, most-significant first.  Returns
   the cursor one past the last digit; no NUL is written.  v == 0 -> "0". */
char *tc_fmt_u64(char *dst, uint64_t v) {
    char scratch[24];
    int n = 0;
    if (v == 0) {
        *dst = '0';
        return dst + 1;
    }
    while (v != 0) {
        scratch[n++] = (char)('0' + (v % 10));
        v /= 10;
    }
    while (n > 0) {
        *dst++ = scratch[--n];
    }
    return dst;
}

/* Zero-pad v on the left to `width` digits; a value needing more than
   `width` digits is written in full.  Returns the cursor past the digits. */
char *tc_fmt_pad(char *dst, uint64_t v, int width) {
    char digits[24];
    char *end = tc_fmt_u64(digits, v);
    int ndigits = (int)(end - digits);
    while (width > ndigits) {
        *dst++ = '0';
        width--;
    }
    memcpy(dst, digits, (size_t)ndigits);
    return dst + ndigits;
}

/* "YYYY-MM-DD<sep>HH:MM:SS" (19 chars, no NUL).  `sep` is a single byte. */
char *tc_fmt_ymd_sod(char *dst, int64_t ymd, int64_t sod, char sep) {
    int y, m, d, h, min, s;
    tc_ymd_split(ymd, &y, &m, &d);
    tc_sod_split(sod, &h, &min, &s);
    dst = tc_fmt4(dst, (uint64_t)y);
    *dst++ = '-';
    dst = tc_fmt2(dst, (uint64_t)m);
    *dst++ = '-';
    dst = tc_fmt2(dst, (uint64_t)d);
    *dst++ = sep;
    dst = tc_fmt2(dst, (uint64_t)h);
    *dst++ = ':';
    dst = tc_fmt2(dst, (uint64_t)min);
    *dst++ = ':';
    dst = tc_fmt2(dst, (uint64_t)s);
    return dst;
}

void tc_ymd_split(int64_t ymd, int *y, int *m, int *d) {
    *y = (int)(ymd / TC_YMD_YEAR_SCALE);
    *m = (int)((ymd / TC_YMD_MONTH_SCALE) % 100);
    *d = (int)(ymd % 100);
}

void tc_sod_split(int64_t sod, int *h, int *min, int *s) {
    *h = (int)(sod / TC_SECS_PER_HOUR);
    *min = (int)((sod % TC_SECS_PER_HOUR) / 60);
    *s = (int)(sod % 60);
}

/* ASCII whitespace: space and \t \n \v \f \r (the str.strip() set). */
int tc_is_ws(unsigned char c) {
    return c == ' ' || (c >= 9 && c <= 13);
}

char *tc_copy_bytes(char *dst, const char *src, size_t len) {
    memcpy(dst, src, len);
    return dst + len;
}

/* Bounded copy: at most cap-1 bytes plus a NUL (cap = capacity of dst).
   Returns dst unchanged. */
char *tc_copy_str_cap(char *dst, const char *src, size_t cap) {
    size_t n = 0;
    if (cap == 0) {
        return dst;
    }
    while (n + 1 < cap && src[n] != '\0') {
        n++;
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
    return dst;
}

/* Bounded append: writes at most cap-1 bytes plus a NUL starting at the
   cursor (cap = bytes available from the cursor).  Returns the cursor AT
   the NUL so the next append overwrites it (cat_cstr semantics). */
char *tc_cat_cstr_cap(char *cursor, const char *s, size_t cap) {
    size_t n = 0;
    if (cap == 0) {
        return cursor;
    }
    while (n + 1 < cap && s[n] != '\0') {
        n++;
    }
    memcpy(cursor, s, n);
    cursor[n] = '\0';
    return cursor + n;
}

/* Append the whole string (NUL and all); returns the cursor at the NUL. */
char *tc_cat_cstr(char *cursor, const char *s) {
    size_t len = strlen(s);
    memcpy(cursor, s, len + 1);
    return cursor + len;
}

int tc_streq(const char *a, const char *b) {
    return strcmp(a, b) == 0;
}

char *tc_fmt2(char *dst, uint64_t v) {
    return tc_fmt_pad(dst, v, 2);
}

char *tc_fmt4(char *dst, uint64_t v) {
    return tc_fmt_pad(dst, v, 4);
}

// ----------------------------------------------------------------------------
// Calendar arithmetic — proleptic Gregorian, Howard Hinnant's algorithms,
// verified against Python's datetime for years 1..9999.
// ----------------------------------------------------------------------------
#define DAYS_PER_ERA     146097  /* 400 years */
#define DAYS_PER_YEAR    365
#define YEARS_PER_ERA    400
#define EPOCH_ERA_OFFSET 719468  /* days from 0000-03-01 to 1970-01-01 */

int64_t tc_days_from_civil(int y, int m, int d) {
    y -= (m <= 2);
    int64_t era = (y >= 0 ? y : y - 399) / YEARS_PER_ERA;
    unsigned yoe = (unsigned)(y - era * YEARS_PER_ERA);      /* [0, 399] */
    int mp = m + (m > 2 ? -3 : 9);
    unsigned doy = (unsigned)((153 * mp + 2) / 5 + d - 1);   /* [0, 365] */
    unsigned doe = yoe * DAYS_PER_YEAR + yoe / 4 - yoe / 100 + doy;
    return era * DAYS_PER_ERA + (int64_t)doe - EPOCH_ERA_OFFSET;
}

void tc_civil_from_days(int64_t days, int *y, int *m, int *d) {
    int64_t z = days + EPOCH_ERA_OFFSET;
    int64_t era = (z >= 0 ? z : z - (DAYS_PER_ERA - 1)) / DAYS_PER_ERA;
    unsigned doe = (unsigned)(z - era * DAYS_PER_ERA);       /* [0, 146096] */
    unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096)
                   / DAYS_PER_YEAR;
    int64_t yy = (int64_t)yoe + era * YEARS_PER_ERA;
    unsigned doy = doe - (DAYS_PER_YEAR * yoe + yoe / 4 - yoe / 100);
    unsigned mp = (5 * doy + 2) / 153;
    unsigned dd = doy - (153 * mp + 2) / 5 + 1;
    unsigned mm = mp < 10 ? mp + 3 : mp - 9;
    *y = (int)(yy + (mm <= 2));
    *m = (int)mm;
    *d = (int)dd;
}

int tc_is_leap(int y) {
    return (y % 4 == 0 && y % 100 != 0) || (y % 400 == 0);
}

static const unsigned char s_month_days[12] = {
    31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
};

int tc_days_in_month(int y, int m) {
    if (m < 1 || m > 12) {
        return 0;
    }
    if (m == 2) {
        return 28 + tc_is_leap(y);
    }
    return (int)s_month_days[m - 1];
}

/* Seconds since 1970-01-01T00:00:00 for a naive civil date/time — the
   timezone-free calendar mapping Python's datetime arithmetic uses. */
int64_t tc_ymd_sod_to_epoch(int64_t ymd, int64_t sod) {
    int y, m, d;
    tc_ymd_split(ymd, &y, &m, &d);
    return tc_days_from_civil(y, m, d) * TC_SECS_PER_DAY + sod;
}

/* The inverse of tc_ymd_sod_to_epoch; floor-division keeps negative epochs
   inside one day (matching Python's datetime round-trip). */
void tc_epoch_to_ymd_sod(int64_t epoch, int64_t *ymd, int64_t *sod) {
    int64_t q = epoch / TC_SECS_PER_DAY;
    int64_t r = epoch - q * TC_SECS_PER_DAY;
    if (r < 0) {
        q -= 1;
        r += TC_SECS_PER_DAY;
    }
    {
        int y, m, d;
        tc_civil_from_days(q, &y, &m, &d);
        *ymd = (int64_t)y * TC_YMD_YEAR_SCALE + (int64_t)m * TC_YMD_MONTH_SCALE
               + d;
    }
    *sod = r;
}

// ----------------------------------------------------------------------------
// Home/path helpers (mirror os.path.expanduser and the Python shorten_path).
// ----------------------------------------------------------------------------
size_t tc_expanduser(const char *src, char *dst, size_t cap) {
    const char *home = NULL;
    size_t name_end;                 /* index of the '/' (or NUL) after '~' */

    if (src[0] != '~') {
        size_t len = strlen(src);
        if (len + 1 > cap) {
            tc_fail("path too long");
        }
        memcpy(dst, src, len + 1);
        return len;
    }
    name_end = 1;
    while (src[name_end] != '\0' && src[name_end] != '/') {
        name_end++;
    }
    if (name_end == 1) {
        /* bare "~" or "~/...": the HOME variable, then the passwd entry */
        home = getenv("HOME");
        if (home == NULL) {
            struct passwd *pw = getpwuid(getuid());
            if (pw == NULL || pw->pw_dir == NULL) {
                size_t len = strlen(src);
                if (len + 1 > cap) {
                    tc_fail("path too long");
                }
                memcpy(dst, src, len + 1);
                return len;
            }
            home = pw->pw_dir;
        }
    } else {
        /* "~name" or "~name/...": the named user's home */
        char name[256];
        struct passwd *pw;
        size_t nlen = name_end - 1;
        if (nlen >= sizeof(name)) {
            size_t len = strlen(src);
            if (len + 1 > cap) {
                tc_fail("path too long");
            }
            memcpy(dst, src, len + 1);
            return len;
        }
        memcpy(name, src + 1, nlen);
        name[nlen] = '\0';
        pw = getpwnam(name);
        if (pw == NULL || pw->pw_dir == NULL) {
            size_t len = strlen(src);
            if (len + 1 > cap) {
                tc_fail("path too long");
            }
            memcpy(dst, src, len + 1);
            return len;
        }
        home = pw->pw_dir;
    }

    {
        /* strip trailing '/' from home, then join home + src[name_end:] */
        size_t home_len = strlen(home);
        size_t rest_len = strlen(src + name_end);
        size_t total = home_len + rest_len;
        while (home_len > 0 && home[home_len - 1] == '/') {
            home_len--;
            total--;
        }
        if (total == 0) {
            if (cap < 2) {
                tc_fail("path too long");
            }
            dst[0] = '/';
            dst[1] = '\0';
            return 1;
        }
        if (total + 1 > cap) {
            tc_fail("path too long");
        }
        memcpy(dst, home, home_len);
        memcpy(dst + home_len, src + name_end, rest_len + 1);
        return total;
    }
}

/* Python shorten_path: home = expanduser("~"); path.replace(home, "~", 1)
   when path.startswith(home), else path.  The result is either the input
   pointer or a module-owned buffer. */
static char s_shorten_buf[TC_PATH_SZ + 1];

const char *tc_shorten_path(const char *path) {
    static char home_buf[TC_PATH_SZ + 1];
    size_t home_len = tc_expanduser("~", home_buf, sizeof(home_buf));
    size_t path_len = strlen(path);
    if (home_len > 0 && path_len >= home_len
        && memcmp(path, home_buf, home_len) == 0) {
        size_t rest = path_len - home_len;
        if (rest + 2 <= sizeof(s_shorten_buf)) {
            s_shorten_buf[0] = '~';
            memcpy(s_shorten_buf + 1, path + home_len, rest + 1);
            return s_shorten_buf;
        }
    }
    return path;
}

// ----------------------------------------------------------------------------
// Env / terminal helpers (mirror shutil.get_terminal_size and int()).
// ----------------------------------------------------------------------------
/* int(os.environ[name]) when the variable is set to a positive integer
   (Python's int grammar for what matters here: surrounding whitespace, an
   optional '+', digits with single '_' separators); else default_value. */
int64_t tc_env_int(const char *name, int64_t default_value) {
    const char *v = getenv(name);
    const char *p;
    uint64_t value = 0;
    int digits = 0;
    int prev_underscore = 0;
    if (v == NULL) {
        return default_value;
    }
    p = v;
    while (*p != '\0' && tc_is_ws((unsigned char)*p)) {
        p++;
    }
    if (*p == '-') {
        return default_value;
    }
    if (*p == '+') {
        p++;
    }
    while (*p != '\0') {
        if (*p == '_') {
            if (digits == 0 || prev_underscore) {
                return default_value;
            }
            prev_underscore = 1;
            p++;
            continue;
        }
        if (*p < '0' || *p > '9') {
            break;
        }
        value = value * 10 + (uint64_t)(*p - '0');
        if (value > (uint64_t)INT32_MAX) {
            value = (uint64_t)INT32_MAX;
        }
        digits = 1;
        prev_underscore = 0;
        p++;
    }
    if (digits == 0 || prev_underscore) {
        return default_value;
    }
    while (*p != '\0') {
        if (!tc_is_ws((unsigned char)*p)) {
            return default_value;
        }
        p++;
    }
    return value == 0 ? default_value : (int64_t)value;
}

static int term_winsize_field(int offset) {
#if TC_PLATFORM_MACOS
    struct winsize ws;
    if (ioctl(1, TIOCGWINSZ, &ws) == 0) {
        return offset == 0 ? (int)ws.ws_row : (int)ws.ws_col;
    }
#else
    struct winsize ws;
    if (ioctl(1, TIOCGWINSZ, &ws) == 0) {
        return offset == 0 ? (int)ws.ws_row : (int)ws.ws_col;
    }
#endif
    return 0;
}

int tc_term_columns(void) {
    int64_t v = tc_env_int("COLUMNS", 0);
    if (v > 0) {
        return (int)v;
    }
    v = term_winsize_field(2);
    return v > 0 ? (int)v : 80;
}

int tc_term_lines(void) {
    int64_t v = tc_env_int("LINES", 0);
    if (v > 0) {
        return (int)v;
    }
    v = term_winsize_field(0);
    return v > 0 ? (int)v : 24;
}

// ----------------------------------------------------------------------------
// File reading — read a whole file into a malloc'd buffer, capped at `cap`
// bytes.  Returns 0 ok, 1 the file exceeded cap (buf holds the prefix),
// 2 error (buf is NULL).
// ----------------------------------------------------------------------------
int tc_read_all(const char *path, uint64_t cap, char **buf_out,
                size_t *len_out) {
    FILE *f;
    char *buf;
    size_t used = 0;
    size_t alloc = TC_READ_CHUNK_CORE;

    *buf_out = NULL;
    *len_out = 0;
    f = fopen(path, "rb");
    if (f == NULL) {
        return 2;
    }
    buf = malloc(alloc);
    if (buf == NULL) {
        fclose(f);
        return 2;
    }
    for (;;) {
        size_t got;
        if (used == alloc) {
            size_t grown = alloc * 2;
            char *nbuf;
            if (grown > cap) {
                grown = cap;
            }
            if (grown <= used) {
                *buf_out = buf;
                *len_out = used;
                fclose(f);
                return 1;
            }
            nbuf = realloc(buf, grown);
            if (nbuf == NULL) {
                free(buf);
                fclose(f);
                return 2;
            }
            buf = nbuf;
            alloc = grown;
        }
        got = fread(buf + used, 1, alloc - used, f);
        if (got > 0) {
            used += got;
            if (used > cap) {
                *buf_out = buf;
                *len_out = used;
                fclose(f);
                return 1;
            }
            continue;
        }
        if (ferror(f)) {
            free(buf);
            fclose(f);
            return 2;
        }
        break;
    }
    fclose(f);
    *buf_out = buf;
    *len_out = used;
    return 0;
}

// ----------------------------------------------------------------------------
// Shared state/metric name tables (one copy of the literals, like the asm).
// ----------------------------------------------------------------------------
const char *tc_state_str(int id) {
    static const char *const names[3] = { "live", "offline", "unknown" };
    if (id < TC_ST_LIVE || id > TC_ST_UNKNOWN) {
        return NULL;
    }
    return names[id - 1];
}

const char *tc_metric_str(int id) {
    static const char *const names[TC_M_MAX] = {
        "count", "login", "live", "offline", "unknown",
        "offline-share", "live-share"
    };
    if (id < TC_M_COUNT || id >= TC_M_MAX) {
        return NULL;
    }
    return names[id];
}

// ----------------------------------------------------------------------------
// Window-order check — fail with the Python-identical
// "begin (A) is after end (B)" when begin is later than end.
// ----------------------------------------------------------------------------
void tc_win_begin_after_end_check(const tc_window *window) {
    char msg[128];
    char *cursor = msg;
    int64_t begin_epoch = tc_ymd_sod_to_epoch(window->begin_ymd,
                                              window->begin_sod);
    int64_t end_epoch = tc_ymd_sod_to_epoch(window->end_ymd,
                                            window->end_sod);
    if (begin_epoch <= end_epoch) {
        return;
    }
    cursor = tc_cat_cstr(cursor, "begin (");
    cursor = tc_fmt_ymd_sod(cursor, window->begin_ymd, window->begin_sod, ' ');
    cursor = tc_cat_cstr(cursor, ") is after end (");
    cursor = tc_fmt_ymd_sod(cursor, window->end_ymd, window->end_sod, ' ');
    *cursor++ = ')';
    *cursor = '\0';
    tc_fail(msg);
}