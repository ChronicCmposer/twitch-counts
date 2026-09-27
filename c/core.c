// ============================================================================
// core.c — the counting core.
//
//  The C sibling of asm/tc_core.S: channel resolution, the dated-log listing,
//  window completion (earliest-log begin, --users sizing), the seed, the
//  counting pass with the rollup-cache hooks, the user table and the line
//  parsers.  Behavioural oracle: twitch-counts.py — resolve_channel_dir /
//  log_files / seed_stream_state / count_messages / fold_windows / _search_width,
//  byte-for-byte wherever the Python's output is observable.
//
//  State is passed explicitly (opts/window/tally), never hidden in mutable
//  globals; the one file-scope structure is tc_core_listing, the resolved
//  listing the test drivers dump (the frozen tc_count_run signature has no
//  out-param for it — this mirrors the asm port's exported tc_listing global).
//
//  Deviations from the Python (shared with the asm port, documented in the
//  asm module header):
//    * login/display matching lowercases ASCII only (Python str.lower()
//      lowercases Unicode too).
//    * a file larger than TC_FILE_CAP records {name, "file too large"} and is
//      skipped (Python has no cap).
//    * the rollup is written only for whole in-range days (the Python also
//      stores partial-window days, but those rows are never served and the
//      resulting counts are identical).
//    * channel directories are matched through readdir's d_type, so a
//      symlink-to-directory is not listed as a channel (Python isdir()).
// ============================================================================

/* d_type/DT_DIR in <dirent.h> and st_mtim in <sys/stat.h> are hidden by
   -std=c99 on glibc; musl always exposes them.  Enable the glibc default
   feature set before ANY include (features.h is first pulled in by the shared
   header's <time.h>). */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#include "tc_platform.h"

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

/* mtime access — same pattern as config.c (musl/Apple expose the timespec
   fields directly; glibc hides st_mtim behind feature macros). */
#if defined(__GLIBC__) && !defined(_DEFAULT_SOURCE) && !defined(_GNU_SOURCE)
#define TC_ST_MTIME_SEC(s)  ((s).st_mtime)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtimensec)
#else
#define TC_ST_MTIME_SEC(s)  ((s).st_mtim.tv_sec)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtim.tv_nsec)
#endif

enum {
    CORE_DNAME_MAX         = 256,   /* channel-dir listing cap (asm MAX_DNAMES) */
    CORE_LISTING_INIT      = 64,
    CORE_USERS_INIT        = 64,
    CORE_MSG_SZ            = 4096,  /* error-message composition buffer */
    CORE_SEED_LOOKBACK_DEF = 30,    /* setting_default("seed_lookback") */
    CORE_LOGIN_CAP         = TC_LOGIN_SZ - 1,  /* 25 */
    CORE_NAME_CAP          = 63     /* listing-name field cap */
};

/* The resolved listing — driver hook (the asm port exposes the same state as
   the tc_listing global; the frozen tc_count_run has no out-param for it). */
tc_listing tc_core_listing;

static char s_reason[192];           /* errno-reason composition buffer */

// ----------------------------------------------------------------------------
// Failure path — "error: <msg>" or the --json {"error": ...} shape, exit 1.
// The JSON escaping mirrors cli_resolve_error (tc_cli.c), which is static.
// ----------------------------------------------------------------------------
static void core_fail(const tc_opts *opts, const char *msg) {
    if (opts != NULL && (opts->flags & TC_F_JSON)) {
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

// ----------------------------------------------------------------------------
// errno -> the text Python attaches to an OSError (main()'s backstop and the
// per-file skip() reasons).  tc_errno_reason = "{ExcClass}: {strerror}";
// tc_oserror_text = "{ExcClass}: [Errno N] {strerror}: '{path}'".
// ----------------------------------------------------------------------------
static const char *core_errno_exc_name(int err) {
    switch (err) {
    case EPERM:
    case EACCES:
        return "PermissionError";
    case ENOENT:
        return "FileNotFoundError";
    case EISDIR:
        return "IsADirectoryError";
    case ENOTDIR:
        return "NotADirectoryError";
    case EEXIST:
        return "FileExistsError";
    case EINTR:
        return "InterruptedError";
    case EPIPE:
        return "BrokenPipeError";
    default:
        return "OSError";
    }
}

const char *tc_errno_reason(int err) {
    char *c = s_reason;
    c = tc_cat_cstr(c, core_errno_exc_name(err));
    c = tc_cat_cstr(c, ": ");
    c = tc_cat_cstr(c, strerror(err));
    return s_reason;
}

/* "{ExcClass}: [Errno N] {strerror}" — the caller appends the filename. */
const char *tc_oserror_text(int err) {
    char *c = s_reason;
    c = tc_cat_cstr(c, core_errno_exc_name(err));
    c = tc_cat_cstr(c, ": [Errno ");
    c = tc_fmt_u64(c, (uint64_t)err);
    c = tc_cat_cstr(c, "] ");
    c = tc_cat_cstr(c, strerror(err));
    return s_reason;
}

/* main()'s OSError backstop: f"{type(exc).__name__}: {exc}" for an OSError
   with a filename.  tc_oserror_text() fills s_reason with the
   "{ExcClass}: [Errno N] {strerror}" part; this appends ": '<path>'" onto a
   message buffer the caller already filled with that text. */
static void core_cat_path_tail(char *msg, size_t cap, const char *path) {
    char *c = msg + strlen(msg);
    c = tc_cat_cstr_cap(c, ": '", (size_t)(msg + cap - c));
    c = tc_cat_cstr_cap(c, path, (size_t)(msg + cap - c));
    c = tc_cat_cstr_cap(c, "'", (size_t)(msg + cap - c));
    (void)c;
}

// ----------------------------------------------------------------------------
// Small shared helpers.
// ----------------------------------------------------------------------------
static int core_is_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return 0;
    }
    return S_ISDIR(st.st_mode);
}

static int core_stat_size_mtime(const char *path, int64_t *size,
                                int64_t *mtime_ns) {
    struct stat st;
    if (stat(path, &st) != 0) {
        return 0;
    }
    *size = (int64_t)st.st_size;
    *mtime_ns = (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
                + (int64_t)TC_ST_MTIME_NSEC(st);
    return 1;
}

static int core_has_newline(const char *buf, size_t len) {
    return memchr(buf, '\n', len) != NULL;
}

static int core_cstr_cmp(const void *a, const void *b) {
    const char *const *sa = a;
    const char *const *sb = b;
    return strcmp(*sa, *sb);
}

static int core_listing_cmp(const void *a, const void *b) {
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

/* Forward declarations (mutual ordering inside this module). */
static void core_lowercase_into(const char *src, char *dst, size_t cap);
static int core_digits(const char *p, size_t n);

// ----------------------------------------------------------------------------
// Channel resolution (Python resolve_channel_dir): case-insensitive match
// against the subdirectories of the (expanded) logs dir.
// ----------------------------------------------------------------------------
int tc_resolve_channel(const tc_opts *opts, char *channel_dir, size_t dir_cap,
                       char *channel_name, size_t name_cap) {
    char dir[TC_PATH_SZ];
    char lower[TC_CHANNEL_SZ];
    const char *names[CORE_DNAME_MAX];
    char arena[CORE_DNAME_MAX][TC_CHANNEL_SZ];
    int64_t n = 0;
    DIR *d;
    struct dirent *de;
    int64_t i;

    /* os.path.expanduser(logs_dir), then the platform-default fallback for an
       empty value (`root = logs_dir.value or PLATFORM.require_logs_dir()`). */
    tc_expanduser(opts->logs_dir, dir, sizeof(dir));
    if (dir[0] == '\0') {
        if (tc_platform_default_logs_dir(dir, sizeof(dir)) == 0) {
            core_fail(opts,
                "TODO - not implemented: the default Chatterino log location "
                "on Linux. pass --logs-dir, or set logs_dir in the config. "
                "Chatterino is believed to use "
                "~/.local/share/chatterino/Logs/Twitch/Channels.");
        }
    }

    /* os.path.isdir(logs_dir): anything but a directory is "not found". */
    if (!core_is_dir(dir)) {
        char msg[CORE_MSG_SZ];
        char *m = msg;
        m = tc_cat_cstr(m, "logs directory not found: ");
        m = tc_cat_cstr(m, dir);
        core_fail(opts, msg);
    }

    /* os.listdir(logs_dir) filtered to directories, sorted by name.  A
       directory that cannot be listed is main()'s OSError backstop. */
    d = opendir(dir);
    if (d == NULL) {
        char msg[CORE_MSG_SZ];
        int err = errno;
        tc_copy_str_cap(msg, tc_oserror_text(err), sizeof(msg));
        core_cat_path_tail(msg, sizeof(msg), dir);
        core_fail(opts, msg);
    }
    while ((de = readdir(d)) != NULL) {
        size_t len;
        if (de->d_type != DT_DIR) {
            continue;
        }
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) {
            continue;
        }
        len = strlen(de->d_name);
        if (len == 0 || len >= TC_CHANNEL_SZ || n >= CORE_DNAME_MAX) {
            continue;   /* cannot match or cannot be stored; cap like the asm */
        }
        memcpy(arena[n], de->d_name, len + 1);
        names[n] = arena[n];
        n++;
    }
    closedir(d);
    qsort(names, (size_t)n, sizeof(char *), core_cstr_cmp);

    /* the case-insensitive match; the first hit in sorted order wins, exactly
       like the Python loop over its sorted list. */
    core_lowercase_into(opts->channel, lower, sizeof(lower));
    for (i = 0; i < n; i++) {
        if (tc_ascii_casecmp(names[i], lower) == 0) {
            tc_copy_str_cap(channel_name, names[i], name_cap);
            snprintf(channel_dir, dir_cap, "%s/%s", dir, names[i]);
            return TC_EXIT_OK;
        }
    }

    /* "no logs for channel '<ch>' in <dir>\navailable: <join|(none)>" */
    {
        char msg[CORE_MSG_SZ];
        char *m = msg;
        m = tc_cat_cstr(m, "no logs for channel '");
        m = tc_cat_cstr(m, opts->channel);
        m = tc_cat_cstr(m, "' in ");
        m = tc_cat_cstr(m, dir);
        *m++ = '\n';
        *m = '\0';
        m = tc_cat_cstr(m, "available: ");
        if (n == 0) {
            m = tc_cat_cstr(m, "(none)");
        } else {
            for (i = 0; i < n; i++) {
                m = tc_cat_cstr(m, names[i]);
                if (i + 1 < n) {
                    m = tc_cat_cstr(m, ", ");
                }
            }
        }
        core_fail(opts, msg);
    }
    return TC_EXIT_ERROR;   /* unreachable */
}

// ----------------------------------------------------------------------------
// The dated-log listing (Python log_files): every name shaped
// "<anything>-YYYY-MM-DD.log" with a real calendar date, sorted ascending.
// Per-stream logs and invalid dates are rejected before any parsing.
// ----------------------------------------------------------------------------
static void core_listing_append(tc_listing *listing, int64_t ymd,
                                const char *name) {
    if (listing->count >= listing->cap) {
        int64_t new_cap = listing->cap == 0 ? CORE_LISTING_INIT
                                            : listing->cap * 2;
        tc_listing_entry *ne = realloc(listing->entries,
                                       (size_t)new_cap * sizeof(*ne));
        if (ne == NULL) {
            tc_fail("out of memory");
        }
        listing->entries = ne;
        listing->cap = new_cap;
    }
    listing->entries[listing->count].ymd = ymd;
    tc_copy_str_cap(listing->entries[listing->count].name, name,
                    sizeof(listing->entries[listing->count].name));
    listing->count++;
}

static void core_build_listing(const tc_opts *opts, const char *channel_dir,
                               tc_listing *listing) {
    DIR *d;
    struct dirent *de;

    /* the listing is a driver-visible artifact: free any previous build so a
       second tc_count_run (or a --users probe) rebuilds it fresh, and leave
       the final build owned by the caller (check_core.c frees it). */
    free(listing->entries);
    listing->count = 0;
    listing->cap = 0;
    listing->entries = NULL;
    d = opendir(channel_dir);
    if (d == NULL) {
        char msg[CORE_MSG_SZ];
        int err = errno;
        tc_copy_str_cap(msg, tc_oserror_text(err), sizeof(msg));
        core_cat_path_tail(msg, sizeof(msg), channel_dir);
        core_fail(opts, msg);
    }
    while ((de = readdir(d)) != NULL) {
        size_t len = strlen(de->d_name);
        int64_t ymd = tc_parse_log_filename_n(de->d_name, len);
        if (ymd == 0) {
            continue;
        }
        core_listing_append(listing, ymd, de->d_name);
    }
    closedir(d);
    qsort(listing->entries, (size_t)listing->count, sizeof(tc_listing_entry),
          core_listing_cmp);
}

// ----------------------------------------------------------------------------
// Window completion: the earliest-log begin (kind 3) and the --users sizing
// (kind 2, via core_size_users).
// ----------------------------------------------------------------------------
static void core_begin_after_end_check(const tc_opts *opts,
                                       const tc_window *window) {
    int64_t begin_epoch = tc_ymd_sod_to_epoch(window->begin_ymd,
                                              window->begin_sod);
    int64_t end_epoch = tc_ymd_sod_to_epoch(window->end_ymd,
                                            window->end_sod);
    char msg[CORE_MSG_SZ];
    char *m;
    if (begin_epoch <= end_epoch) {
        return;
    }
    m = msg;
    m = tc_cat_cstr(m, "begin (");
    m = tc_fmt_ymd_sod(m, window->begin_ymd, window->begin_sod, ' ');
    m = tc_cat_cstr(m, ") is after end (");
    m = tc_fmt_ymd_sod(m, window->end_ymd, window->end_sod, ' ');
    *m++ = ')';
    *m = '\0';
    core_fail(opts, msg);
}

static void core_complete_window(const tc_opts *opts, tc_window *window,
                                 const char *channel_dir,
                                 const tc_listing *listing) {
    if (window->kind == TC_WIN_EARLIEST) {
        if (listing->count == 0) {
            char msg[CORE_MSG_SZ];
            char *m = msg;
            m = tc_cat_cstr(m, "no log files found in ");
            m = tc_cat_cstr(m, channel_dir);
            core_fail(opts, msg);
        }
        window->begin_ymd = listing->entries[0].ymd;
        window->begin_sod = 0;
        core_begin_after_end_check(opts, window);
    }
    window->threshold = opts->min_count;
    window->state_filter = opts->state_filter;
}

// ----------------------------------------------------------------------------
// The user table — find-or-add machinery the counting pass, the cache merge
// and the --users probes all share.
// ----------------------------------------------------------------------------
static void core_entry_add(tc_user_entry *entry, int state, int64_t n) {
    switch (state) {
    case TC_ST_LIVE:
        entry->live += n;
        return;
    case TC_ST_OFFLINE:
        entry->offline += n;
        return;
    case TC_ST_UNKNOWN:
        entry->unknown += n;
        return;
    default:
        tc_fail("core: internal error: invalid state bucket");  /* invariant */
    }
}

static int64_t core_users_grow(tc_users *table, const char *login, size_t len) {
    tc_user_entry *entry;
    if (len > CORE_LOGIN_CAP) {
        len = CORE_LOGIN_CAP;
    }
    if (table->count >= table->cap) {
        int64_t new_cap = table->cap == 0 ? CORE_USERS_INIT : table->cap * 2;
        tc_user_entry *ne = realloc(table->entries,
                                    (size_t)new_cap * sizeof(*ne));
        if (ne == NULL) {
            tc_fail("out of memory");
        }
        table->entries = ne;
        table->cap = new_cap;
    }
    entry = &table->entries[table->count];
    memset(entry, 0, sizeof(*entry));
    memcpy(entry->login, login, len);
    entry->login[len] = '\0';
    table->count++;
    return table->count - 1;
}

int64_t tc_find_user(const tc_users *table, const char *login, size_t len) {
    int64_t i;
    if (table == NULL || login == NULL) {
        return -1;
    }
    for (i = 0; i < table->count; i++) {
        const tc_user_entry *entry = &table->entries[i];
        if (strlen(entry->login) == len
            && memcmp(entry->login, login, len) == 0) {
            return i;
        }
    }
    return -1;
}

/* Find-or-add + add n to the entry's state bucket; returns the index. */
static int64_t core_get_user_index(tc_users *table, const char *login,
                                   size_t len, int state, int64_t n) {
    int64_t idx = tc_find_user(table, login, len);
    if (idx < 0) {
        idx = core_users_grow(table, login, len);
    }
    core_entry_add(&table->entries[idx], state, n);
    return idx;
}

int tc_add_user(tc_users *table, const char *login, size_t len, int state,
                int64_t n) {
    return (int)core_get_user_index(table, login, len, state, n);
}

int tc_reuse_apply(tc_users *table, const char *login, size_t len, int state,
                   int64_t n) {
    (void)core_get_user_index(table, login, len, state, n);
    return TC_EXIT_OK;
}

int64_t tc_user_count(const tc_user_entry *user) {
    return user->live + user->offline + user->unknown;
}

int64_t tc_user_state(const tc_user_entry *user, int state) {
    switch (state) {
    case TC_ST_LIVE:
        return user->live;
    case TC_ST_OFFLINE:
        return user->offline;
    case TC_ST_UNKNOWN:
        return user->unknown;
    default:
        return 0;
    }
}

/* The fixed-point share key the sort and share columns use: floor(1000 * part
   / total), 0 for an empty total. */
static int64_t core_share_key(int64_t part, int64_t total) {
    if (total <= 0) {
        return 0;
    }
    return (1000 * part) / total;
}

int64_t tc_count_column(const tc_user_entry *user, int metric) {
    switch (metric) {
    case TC_M_COUNT:
        return tc_user_count(user);
    case TC_M_LOGIN:
        return 0;   /* sort-only; the renderer orders by the login string */
    case TC_M_LIVE:
        return user->live;
    case TC_M_OFFLINE:
        return user->offline;
    case TC_M_UNKNOWN:
        return user->unknown;
    case TC_M_OFFLINE_SHARE:
        return core_share_key(user->offline, tc_user_count(user));
    case TC_M_LIVE_SHARE:
        return core_share_key(user->live, tc_user_count(user));
    default:
        return 0;
    }
}

/* The count-column for the resolved state filter: the sum of the buckets
   matching the filter, or all three when unfiltered (Python's counts[]). */
static int64_t core_count_column_for_filter(const tc_user_entry *user,
                                            int filter) {
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

int64_t tc_eff_threshold(const tc_opts *opts) {
    int i;
    int shares = opts->sort >= TC_M_OFFLINE_SHARE;
    if (!shares) {
        for (i = 0; i < opts->column_count; i++) {
            if (opts->columns[i] >= TC_M_OFFLINE_SHARE) {
                shares = 1;
                break;
            }
        }
    }
    if (shares && opts->share_floor != 0
        && opts->share_floor > opts->min_count) {
        return opts->share_floor;
    }
    return opts->min_count;
}

// ----------------------------------------------------------------------------
// Line parsers — the boundary parses of the counting pass (Python's
// LIVE_RE / LINE_RE / LOGIN_RE / LOCALIZED_RE / speaker_login).
// ----------------------------------------------------------------------------
int tc_is_timestamp_header(const char *line, size_t len) {
    static const char digits[] = "0123456789";
    if (len < 11) {
        return 0;
    }
    if (line[0] != '[') {
        return 0;
    }
    if (line[1] < '0' || line[1] > '9' || line[2] < '0' || line[2] > '9') {
        return 0;
    }
    if (line[3] != ':') {
        return 0;
    }
    if (line[4] < '0' || line[4] > '9' || line[5] < '0' || line[5] > '9') {
        return 0;
    }
    if (line[6] != ':') {
        return 0;
    }
    if (line[7] < '0' || line[7] > '9' || line[8] < '0' || line[8] > '9') {
        return 0;
    }
    if (line[9] != ']' || line[10] != ' ') {
        return 0;
    }
    (void)digits;
    return 1;
}

/* The token before a marker literal must be one or more bytes that Python's
   \S+ accepts: not ASCII whitespace (space and \t..\r). */
static int core_marker_token_ok(const char *line, size_t len,
                                size_t literal_len) {
    size_t tok_len = len - 11 - literal_len - 1;   /* minus the space */
    size_t i;
    if (tok_len < 1) {
        return 0;
    }
    for (i = 0; i < tok_len; i++) {
        unsigned char c = (unsigned char)line[11 + i];
        if (c == ' ' || (c >= 9 && c <= 13)) {
            return 0;
        }
    }
    return 1;
}

/* "[HH:MM:SS] <token> is live!" / "[HH:MM:SS] <token> is now offline." — the
   Python LIVE_RE, matched exactly at the end of the line. */
int tc_line_is_marker(const char *line, size_t len) {
    static const char live_lit[] = "is live!";
    static const char offline_lit[] = "is now offline.";
    if (!tc_is_timestamp_header(line, len)) {
        return 0;
    }
    if (len >= sizeof(live_lit) + 1
        && memcmp(line + len - sizeof(live_lit) + 1, live_lit,
                  sizeof(live_lit) - 1) == 0
        && line[len - sizeof(live_lit)] == ' '
        && core_marker_token_ok(line, len, sizeof(live_lit) - 1)) {
        return TC_ST_LIVE;
    }
    if (len >= sizeof(offline_lit) + 1
        && memcmp(line + len - sizeof(offline_lit) + 1, offline_lit,
                  sizeof(offline_lit) - 1) == 0
        && line[len - sizeof(offline_lit)] == ' '
        && core_marker_token_ok(line, len, sizeof(offline_lit) - 1)) {
        return TC_ST_OFFLINE;
    }
    return TC_ST_NONE;
}

int tc_ascii_casecmp(const char *a, const char *b) {
    while (*a != '\0' && *b != '\0') {
        unsigned char ca = (unsigned char)*a;
        if (ca >= 'A' && ca <= 'Z') {
            ca = (unsigned char)(ca + 32);
        }
        if (ca != (unsigned char)*b) {
            return 1;
        }
        a++;
        b++;
    }
    return (*a == '\0' && *b == '\0') ? 0 : 1;
}

/* Lowercase an ASCII string into dst (the channel key for the match). */
static void core_lowercase_into(const char *src, char *dst, size_t cap) {
    size_t i = 0;
    for (;;) {
        unsigned char c;
        if (i + 1 >= cap) {
            dst[i] = '\0';
            return;
        }
        c = (unsigned char)src[i];
        if (c >= 'A' && c <= 'Z') {
            c = (unsigned char)(c + 32);
        }
        dst[i] = (char)c;
        if (c == '\0') {
            return;
        }
        i++;
    }
}

/* The speaker field: find the first ':' after the header; it must be followed
   by ' ' (Python's LINE_RE split, with the [^:]+ speaker rule — a ':' before
   that point makes the line uncountable). */
static int core_message_speaker(const char *line, size_t len,
                                const char **speaker, size_t *speaker_len) {
    size_t i;
    for (i = 11; i < len; i++) {
        if (line[i] == ':') {
            if (i + 1 < len && line[i + 1] == ' ') {
                *speaker = line + 11;
                *speaker_len = i - 11;
                return *speaker_len > 0;
            }
            return 0;
        }
    }
    return 0;
}

/* The speaker login (Python speaker_login): LOGIN_RE ([A-Za-z0-9_]{1,25},
   lowercased) first; then LOCALIZED_RE ("<non-ascii display> <login>").  The
   login is written into dst (>= TC_LOGIN_SZ bytes); returns its length, or 0
   when the speaker is a system line. */
size_t tc_speaker_login_to(const char *s, size_t len, char *dst) {
    size_t i;
    int is_login = len >= 1 && len <= 25;
    if (is_login) {
        for (i = 0; i < len; i++) {
            unsigned char c = (unsigned char)s[i];
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
                  || (c >= '0' && c <= '9') || c == '_')) {
                is_login = 0;
                break;
            }
        }
    }
    if (is_login) {
        for (i = 0; i < len; i++) {
            unsigned char c = (unsigned char)s[i];
            if (c >= 'A' && c <= 'Z') {
                c = (unsigned char)(c + 32);
            }
            dst[i] = (char)c;
        }
        dst[len] = '\0';
        return len;
    }
    /* LOCALIZED_RE: the LAST space splits "<display> <login>"; the right part
       is a lowercase login, the left part is whitespace-free with a byte >=
       128 (any(ord(c) > 127 for c in display)). */
    {
        size_t sp = len;   /* last space index */
        size_t right_len;
        for (i = 0; i < len; i++) {
            if (s[i] == ' ') {
                sp = i;
            }
        }
        if (sp == len || sp == 0) {
            return 0;   /* no space or an empty display */
        }
        right_len = len - sp - 1;
        if (right_len < 1 || right_len > 25) {
            return 0;
        }
        for (i = 0; i < right_len; i++) {
            unsigned char c = (unsigned char)s[sp + 1 + i];
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
                  || c == '_')) {
                return 0;
            }
        }
        for (i = 0; i < sp; i++) {
            unsigned char c = (unsigned char)s[i];
            if (c == ' ' || c == '\t') {
                return 0;
            }
            if (c >= 128) {
                break;
            }
            if (i + 1 == sp) {
                return 0;   /* the display is pure ASCII */
            }
        }
        memcpy(dst, s + sp + 1, right_len);
        dst[right_len] = '\0';
        return right_len;
    }
}

int64_t tc_parse_log_filename_n(const char *name, size_t len) {
    int y, mo, d;
    if (len < 16) {
        return 0;
    }
    /* suffix ".log" and the three '-' separators */
    if (memcmp(name + len - 4, ".log", 4) != 0) {
        return 0;
    }
    if (name[len - 15] != '-' || name[len - 10] != '-'
        || name[len - 7] != '-') {
        return 0;
    }
    /* year (4 digits), month (2), day (2) */
    if (!core_digits(name + len - 14, 4) || !core_digits(name + len - 9, 2)
        || !core_digits(name + len - 6, 2)) {
        return 0;
    }
    y = (int)((name[len - 14] - '0') * 1000 + (name[len - 13] - '0') * 100
              + (name[len - 12] - '0') * 10 + (name[len - 11] - '0'));
    mo = (int)((name[len - 9] - '0') * 10 + (name[len - 8] - '0'));
    d = (int)((name[len - 6] - '0') * 10 + (name[len - 5] - '0'));
    if (y < 1 || mo < 1 || mo > 12 || d < 1 || d > tc_days_in_month(y, mo)) {
        return 0;   /* a well-shaped name that is not a real date */
    }
    return (int64_t)y * TC_YMD_YEAR_SCALE + (int64_t)mo * TC_YMD_MONTH_SCALE
           + d;
}

static int core_digits(const char *p, size_t n) {
    size_t i;
    for (i = 0; i < n; i++) {
        if (p[i] < '0' || p[i] > '9') {
            return 0;
        }
    }
    return 1;
}

// ----------------------------------------------------------------------------
// The seed (Python seed_stream_state): the live/offline state in force when
// the range opens.  Cache-first (the day before begin.date()'s stored exit
// state), then a walk back through up to seed_lookback earlier files, newest
// first; the first file carrying any marker supplies its last marker's state.
// ----------------------------------------------------------------------------
static int64_t core_index_before(const tc_listing *listing, int64_t ymd) {
    int64_t i;
    for (i = 0; i < listing->count; i++) {
        if (listing->entries[i].ymd >= ymd) {
            return i - 1;
        }
    }
    return listing->count - 1;
}

/* The last marker state in a buffer, processing every line including a
   partial final one (the Python seed loop iterates the file the same way). */
static int core_scan_markers(const char *buf, size_t len) {
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

static int core_seed_state(const tc_opts *opts, const tc_window *window,
                           const char *channel_dir, const char *channel_name,
                           const tc_listing *listing, tc_cache *cache) {
    int64_t start = core_index_before(listing, window->begin_ymd);
    int64_t lookback;
    int64_t limit;
    int64_t i;

    if (start < 0) {
        return TC_ST_NONE;
    }

    /* rollup-cache hook: the day before the range's stored exit state.  A
       cached 'unknown' proves nothing, so it falls through to the scan. */
    if (cache != NULL) {
        const tc_listing_entry *entry = &listing->entries[start];
        char fpath[TC_PATH_SZ];
        int64_t size = 0;
        int64_t mtime_ns = 0;
        int state;
        snprintf(fpath, sizeof(fpath), "%s/%s", channel_dir, entry->name);
        if (core_stat_size_mtime(fpath, &size, &mtime_ns)) {
            state = tc_cache_exit_state(cache, channel_name, entry->ymd,
                                        fpath, size, mtime_ns);
            if (state != TC_ST_NONE) {
                return state;
            }
        }
    }

    /* walk back, newest first, at most seed_lookback files; unreadable
       history is no worse than history that was never written. */
    lookback = opts->seed_lookback > 0 ? opts->seed_lookback
                                       : CORE_SEED_LOOKBACK_DEF;
    limit = start - lookback + 1;
    if (limit < 0) {
        limit = 0;
    }
    for (i = start; i >= limit; i--) {
        const tc_listing_entry *entry = &listing->entries[i];
        char fpath[TC_PATH_SZ];
        char *buf = NULL;
        size_t len = 0;
        int state;
        snprintf(fpath, sizeof(fpath), "%s/%s", channel_dir, entry->name);
        if (tc_read_all(fpath, TC_FILE_CAP, &buf, &len) != 0) {
            continue;
        }
        state = core_scan_markers(buf, len);
        free(buf);
        if (state != TC_ST_NONE) {
            return state;
        }
    }
    return TC_ST_NONE;
}

// ----------------------------------------------------------------------------
// The counting pass (Python count_messages + fold_windows + TailReader).
// One pass folds every in-range day into a users table and a tally; the
// per-day scratch table is what the rollup hooks read and write.
// ----------------------------------------------------------------------------
static void core_reset_users(tc_users *users) {
    users->count = 0;   /* the entries buffer is kept and reused */
}

static void core_reset_tally(tc_tally *tally) {
    tc_users *users = tally->users;
    memset(tally, 0, sizeof(*tally));
    tally->users = users;
}

static void core_record_unreadable(tc_tally *tally, const char *name,
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

/* Count one in-window message into the day table.  The line has already been
   split at the first ": " (Python's LINE_RE + speaker_login + bucket). */
static void core_count_message(const char *line, size_t len, int64_t lo,
                               int64_t hi, int state, tc_users *day_users,
                               tc_tally *day_tally) {
    const char *speaker;
    size_t speaker_len;
    int64_t second;
    char login[TC_LOGIN_SZ];
    size_t login_len;
    int st;

    if (!tc_is_timestamp_header(line, len)) {
        return;
    }
    if (!core_message_speaker(line, len, &speaker, &speaker_len)) {
        return;
    }
    /* second-of-day from the [HH:MM:SS] digits */
    second = (int64_t)(line[1] - '0') * 10 + (int64_t)(line[2] - '0');
    second = second * 60 + (int64_t)(line[4] - '0') * 10
             + (int64_t)(line[5] - '0');
    second = second * 60 + (int64_t)(line[7] - '0') * 10
             + (int64_t)(line[8] - '0');
    if (second < lo || second > hi) {
        return;
    }
    login_len = tc_speaker_login_to(speaker, speaker_len, login);
    if (login_len == 0) {
        return;
    }
    st = state == TC_ST_LIVE ? TC_ST_LIVE
       : state == TC_ST_OFFLINE ? TC_ST_OFFLINE : TC_ST_UNKNOWN;
    tc_add_user(day_users, login, login_len, st, 1);
    day_tally->states[st - TC_ST_LIVE] += 1;
    day_tally->messages += 1;
}

/* Fold the complete lines of one file (the partial tail is dropped, as in the
   Python).  Returns the exit state. */
static int core_process_lines(const char *buf, size_t len, int64_t lo,
                              int64_t hi, int state, tc_users *day_users,
                              tc_tally *day_tally) {
    const char *end = buf + len;
    const char *last = buf;   /* one past the last '\n' */
    const char *p;
    const char *line;

    for (p = buf; p < end; p++) {
        if (*p == '\n') {
            last = p + 1;
        }
    }
    line = buf;
    while (line < last) {
        const char *nl = memchr(line, '\n', (size_t)(last - line));
        size_t llen = (size_t)(nl - line);   /* excludes the '\n' */
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
        core_count_message(line, llen, lo, hi, state, day_users, day_tally);
        line = nl + 1;
    }
    return state;
}

/* Merge one day's counts (parsed or served) into the run tally.  The day
   tally's users table is authoritative for both paths. */
static void core_merge_day(tc_users *run_users, tc_tally *run_tally,
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

/* Fold one in-range day into the run tally: files++, stat, the rollup-cache
   serve for a whole day, else read + parse + put.  `current` is the live/
   offline state carried across days (0 = unknown). */
static void core_fold_day(const tc_window *window,
                          const char *channel_dir, const char *channel_name,
                          const tc_listing_entry *entry, tc_cache *cache,
                          tc_users *run_users, tc_tally *run_tally,
                          tc_users *day_users, tc_tally *day_tally,
                          int *current) {
    int64_t ymd = entry->ymd;
    int64_t lo;
    int64_t hi;
    int whole_day;
    char fpath[TC_PATH_SZ];
    int64_t size = 0;
    int64_t mtime_ns = 0;
    char *buf = NULL;
    size_t len = 0;
    int status;
    int enter;

    run_tally->files++;

    /* bucket_bounds: the [lo, hi] seconds-of-day this file contributes. */
    lo = window->begin_ymd < ymd ? 0 : window->begin_sod;
    hi = window->end_ymd > ymd ? TC_LAST_SECOND : window->end_sod;
    whole_day =
        (window->begin_ymd < ymd
         || (window->begin_ymd == ymd && window->begin_sod == 0))
        && (window->end_ymd > ymd
            || (window->end_ymd == ymd && window->end_sod == TC_LAST_SECOND));

    snprintf(fpath, sizeof(fpath), "%s/%s", channel_dir, entry->name);

    /* os.stat(path): a failure is skip() — recorded, and the state is not
       trusted to carry across the gap. */
    if (!core_stat_size_mtime(fpath, &size, &mtime_ns)) {
        int err = errno;
        core_record_unreadable(run_tally, entry->name, tc_errno_reason(err));
        *current = TC_ST_NONE;
        return;
    }

    /* rollup-cache serve: a whole day inside the range is settled. */
    if (cache != NULL && whole_day) {
        core_reset_users(day_users);
        core_reset_tally(day_tally);
        status = tc_cache_day(cache, channel_name, ymd, fpath, size,
                              mtime_ns, *current, day_tally);
        if (status == 1) {
            run_tally->reused++;
            core_merge_day(run_users, run_tally, day_tally);
            *current = tc_cache_exit_state(cache, channel_name, ymd, fpath,
                                           size, mtime_ns);
            return;
        }
        /* status 0 (miss) or 2 (row unusable): parse normally. */
    }

    /* read the whole file (Python TailReader.refresh on a cold read) */
    status = tc_read_all(fpath, TC_FILE_CAP, &buf, &len);
    if (status != 0) {
        if (cache != NULL) {
            tc_cache_discard_day(cache);
        }
        if (status == 1) {
            core_record_unreadable(run_tally, entry->name, "file too large");
        } else {
            int err = errno;
            core_record_unreadable(run_tally, entry->name,
                                   tc_errno_reason(err));
        }
        if (buf != NULL) {
            free(buf);
        }
        *current = TC_ST_NONE;
        return;
    }

    /* no complete line: nothing folded, nothing parsed, state unchanged */
    if (!core_has_newline(buf, len)) {
        if (cache != NULL) {
            tc_cache_discard_day(cache);
        }
        free(buf);
        return;
    }

    enter = *current;
    core_reset_users(day_users);
    core_reset_tally(day_tally);
    *current = core_process_lines(buf, len, lo, hi, enter, day_users,
                                  day_tally);
    free(buf);
    run_tally->parsed++;

    core_merge_day(run_users, run_tally, day_tally);

    /* write the whole day to the rollup after a cold, whole-file read */
    if (cache != NULL) {
        if (whole_day) {
            tc_cache_put_day(cache, channel_name, ymd, fpath, size, mtime_ns,
                             enter, *current, day_tally);
        }
        tc_cache_discard_day(cache);
    }
}

/* Apply exclusions to the run tally (Python fold_windows' excluded handling +
   select_rows' subtraction): the states become the non-excluded all-state
   split, excluded_states the excluded split, messages the non-excluded
   count-column total.  The users table keeps every user, excluded included. */
static void core_finish_tally(const tc_window *window,
                              const tc_excl_set *exclusions, tc_users *users,
                              tc_tally *tally) {
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
            tally->messages += core_count_column_for_filter(entry,
                                                            window->state_filter);
        }
    }
}

/* One counting pass over [window.begin, window.end] into users/tally. */
static void core_run_count(const tc_opts *opts, const tc_window *window,
                           const char *channel_dir, const char *channel_name,
                           const tc_excl_set *exclusions, tc_cache *cache,
                           const tc_listing *listing, tc_users *users,
                           tc_tally *tally) {
    tc_users day_users = {0};
    tc_tally day_tally = {0};
    int current;
    int64_t i;

    core_reset_users(users);
    core_reset_tally(tally);
    day_tally.users = &day_users;

    current = core_seed_state(opts, window, channel_dir, channel_name,
                              listing, cache);

    for (i = 0; i < listing->count; i++) {
        const tc_listing_entry *entry = &listing->entries[i];
        if (entry->ymd < window->begin_ymd || entry->ymd > window->end_ymd) {
            continue;
        }
        core_fold_day(window, channel_dir, channel_name, entry, cache,
                      users, tally, &day_users, &day_tally, &current);
    }

    core_finish_tally(window, exclusions, users, tally);
    free(day_users.entries);
}

// ----------------------------------------------------------------------------
// --users sizing (Python size_window + _search_width + _apply_width).  The
// probe recounts into scratch tables; the reported population is the
// non-excluded users whose count-column meets the effective threshold.
// ----------------------------------------------------------------------------
static int64_t core_reported_width(const tc_opts *opts,
                                   const tc_window *window,
                                   const char *channel_dir,
                                   const char *channel_name,
                                   const tc_excl_set *exclusions,
                                   tc_cache *cache, const tc_listing *listing,
                                   tc_users *scratch_users,
                                   tc_tally *scratch_tally, int64_t seconds) {
    tc_window probe = *window;
    int64_t begin_epoch;
    int64_t eff;
    int64_t n = 0;
    int64_t i;

    begin_epoch = tc_ymd_sod_to_epoch(probe.end_ymd, probe.end_sod) - seconds;
    tc_epoch_to_ymd_sod(begin_epoch, &probe.begin_ymd, &probe.begin_sod);
    probe.begin_rolls = 1;

    core_run_count(opts, &probe, channel_dir, channel_name, exclusions, cache,
                   listing, scratch_users, scratch_tally);
    eff = tc_eff_threshold(opts);
    for (i = 0; i < scratch_users->count; i++) {
        tc_user_entry *entry = &scratch_users->entries[i];
        size_t llen = strlen(entry->login);
        if (tc_excl_contains(exclusions, entry->login, llen)) {
            continue;
        }
        if (core_count_column_for_filter(entry, probe.state_filter) >= eff) {
            n++;
        }
    }
    return n;
}

static void core_size_users(const tc_opts *opts, tc_window *window,
                            const char *channel_dir, const char *channel_name,
                            const tc_excl_set *exclusions, tc_cache *cache,
                            const tc_listing *listing, tc_users *scratch_users,
                            tc_tally *scratch_tally) {
    int64_t requested = opts->users;
    int64_t ceiling = opts->users_max >= 1 ? opts->users_max : 1;
    int64_t end_epoch = tc_ymd_sod_to_epoch(window->end_ymd,
                                            window->end_sod);
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

    /* widest first: every narrower probe is then a subset already seen. */
    widest = core_reported_width(opts, window, channel_dir, channel_name,
                                 exclusions, cache, listing, scratch_users,
                                 scratch_tally, ceiling);

    /* bisection 1: the smallest width with count >= requested */
    lo = 1;
    hi = ceiling;
    while (lo < hi) {
        mid = lo + (hi - lo) / 2;   /* floors, so mid < hi and this ends */
        if (core_reported_width(opts, window, channel_dir, channel_name,
                                exclusions, cache, listing, scratch_users,
                                scratch_tally, mid) >= requested) {
            hi = mid;
        } else {
            lo = mid + 1;
        }
    }
    over_width = lo;
    over = core_reported_width(opts, window, channel_dir, channel_name,
                               exclusions, cache, listing, scratch_users,
                               scratch_tally, over_width);

    /* bisection 2: the widest width with count <= requested */
    lo = 1;
    hi = ceiling;
    while (lo < hi) {
        mid = lo + (hi - lo + 1) / 2;   /* ceils, so mid > lo and this ends */
        if (core_reported_width(opts, window, channel_dir, channel_name,
                                exclusions, cache, listing, scratch_users,
                                scratch_tally, mid) <= requested) {
            lo = mid;
        } else {
            hi = mid - 1;
        }
    }
    under_width = lo;
    under = core_reported_width(opts, window, channel_dir, channel_name,
                                exclusions, cache, listing, scratch_users,
                                scratch_tally, under_width);

    if (widest < requested) {
        /* unreachable at any width the ceiling allows */
        width = ceiling;
        found = widest;
    } else if (opts->users_policy == TC_POLICY_AT_MOST) {
        width = under_width;
        found = under;
    } else if (opts->users_policy == TC_POLICY_NEAREST) {
        int64_t du = under - requested;
        int64_t dv = over - requested;
        if (du < 0) {
            du = -du;
        }
        if (dv < 0) {
            dv = -dv;
        }
        if (du <= dv) {
            /* ties to the narrower window: it is the fresher data */
            width = under_width;
            found = under;
        } else {
            width = over_width;
            found = over;
        }
    } else {   /* at-least */
        width = over_width;
        found = over;
    }

    window->users_width = width;
    window->users_found = found;
    tc_epoch_to_ymd_sod(end_epoch - width, &window->begin_ymd,
                        &window->begin_sod);
}

// ----------------------------------------------------------------------------
// tc_count_run — the counting entry point: resolve the channel, build the
// listing, complete the window, open the rollup cache, count.  The caller's
// window is completed in place (the asm port mutates the same structure; the
// driver dump needs the earliest begin and the sized width/found).
// ----------------------------------------------------------------------------
int tc_count_run(const tc_opts *opts, const tc_window *window_in,
                 tc_tally *tally) {
    tc_window window;
    tc_excl_set exclusions;
    char channel_dir[TC_PATH_SZ];
    char channel_name[TC_CHANNEL_SZ];
    tc_cache *cache = NULL;
    const char *cache_problem = NULL;
    char cache_path[TC_PATH_SZ];
    tc_users probe_users = {0};
    tc_tally probe_tally = {0};
    int status;

    if (tally == NULL || tally->users == NULL) {
        tc_fail("core: internal error: tally users table not initialized");
    }
    window = *window_in;

    /* resolve the channel (idempotent; errors exit 1) */
    tc_resolve_channel(opts, channel_dir, sizeof(channel_dir),
                       channel_name, sizeof(channel_name));

    /* the dated-log listing, sorted ascending */
    core_build_listing(opts, channel_dir, &tc_core_listing);

    /* complete the window: earliest begin, no-files and begin>end errors */
    core_complete_window(opts, &window, channel_dir, &tc_core_listing);

    /* the rollup cache never fails the query: an unopenable cache degrades to
       parsing every file (cache stays NULL and every hook is skipped). */
    if (!(opts->flags & TC_F_NO_CACHE)) {
        if (tc_default_cache_path(cache_path, sizeof(cache_path)) > 0) {
            tc_cache_open(cache_path,
                          (opts->flags & TC_F_REBUILD_CACHE) ? 1 : 0,
                          channel_name, &cache, &cache_problem);
        }
    }

    /* the merged exclusion set (once per run; probes and the final pass
       share it — Python builds it once in build_inputs) */
    status = tc_build_exclusions(opts, &exclusions);
    if (status != TC_EXIT_OK) {
        if (cache != NULL) {
            tc_cache_close(cache);
        }
        return status;
    }

    /* --users sizing: probes into scratch tables, then the sized window */
    probe_tally.users = &probe_users;
    if (window.kind == TC_WIN_USERS) {
        core_size_users(opts, &window, channel_dir, channel_name, &exclusions,
                        cache, &tc_core_listing, &probe_users, &probe_tally);
    }

    /* the final count into the caller's tables */
    core_run_count(opts, &window, channel_dir, channel_name, &exclusions,
                   cache, &tc_core_listing, tally->users, tally);

    if (cache != NULL) {
        tc_cache_close(cache);
    }
    free(probe_users.entries);

    *(tc_window *)window_in = window;
    return TC_EXIT_OK;
}