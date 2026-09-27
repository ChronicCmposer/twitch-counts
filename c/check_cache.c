// ============================================================================
// check_cache.c — the C test driver for cache.c (tc-cache-test).
// ============================================================================
//
//  main(argc, argv): tc_cli_parse -> tc_build_exclusions -> resolve the
//  channel dir -> tc_cache_open -> the counting pass -> the contract dump ->
//  cachestatus -> tc_cache_debug_dump -> tc_cache_close.
//
//  The counting pass drives the cache through the public hooks exactly as
//  core.c's tc_count_run does (the day-tally pattern): every whole-day
//  in-range file asks tc_cache_day with a reset day tally; a hit merges the
//  served day into the run tally and carries the cached exit state forward
//  via tc_cache_exit_state; a miss parses the file into the day tally and
//  reports it back with tc_cache_put_day; unreadable / partial reads drop
//  the pending stash with tc_cache_discard_day.  The driver owns the cache
//  handle so the harness can dump cachestatus + the database (core.c opens
//  and closes its own handle inside tc_count_run, which would hide the
//  handle from the dump).
//
//  The dump is the stable, parseable summary the harness diffs (same shape
//  as the asm check_tc_cache.S + check_tc_dump.S):
//
//    channel=<resolved dir name>
//    window begin=<ymd>:<sod> end=<ymd>:<sod> kind=<k> width=<w> found=<f> req=<r>
//    listing <n>
//    <ymd> <name>
//    users <n>
//    <login> <live> <offline> <unknown>
//    tally files=<f> messages=<m> parsed=<p> states=<l>:<o>:<u> excl=<l>:<o>:<u> unreadable=<u>
//    unreadable <name> <reason>
//    cachestatus used=<0|1> reused=<n> parsed=<n> problem=<text|-> rebuilt=<text|-> path=<text|->
//    cachetables ... / cachecounts ... / cachefile ... / cachecount ...  (when open)
//
//  Exits 0 on success; tc_fail paths exit 1 with "error: ..." on stderr.
// ============================================================================

/* st_mtim in <sys/stat.h> is hidden by -std=c99 on glibc; musl always exposes
   it.  Enable the glibc default feature set (like core.c) and fall back to the
   pre-timespec names when the macros are still off. */
#ifndef _DEFAULT_SOURCE
#define _DEFAULT_SOURCE 1
#endif

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <ctype.h>
#include <dirent.h>
#include <sys/stat.h>

#if TC_PLATFORM_MACOS
#define DRV_ST_MTIM_SEC(st)  ((st).st_mtimespec.tv_sec)
#define DRV_ST_MTIM_NSEC(st) ((st).st_mtimespec.tv_nsec)
#elif defined(__GLIBC__) && !defined(_DEFAULT_SOURCE) && !defined(_GNU_SOURCE)
#define DRV_ST_MTIM_SEC(st)  ((st).st_mtime)
#define DRV_ST_MTIM_NSEC(st) ((st).st_mtimensec)
#else
#define DRV_ST_MTIM_SEC(st)  ((st).st_mtim.tv_sec)
#define DRV_ST_MTIM_NSEC(st) ((st).st_mtim.tv_nsec)
#endif

#define DRV_SEED_LOOKBACK 30        /* setting_default("seed_lookback") */

/* The rebuilt-reason accessor: tc_cache_status's C contract has no slot for
   it (the asm returns it in x4), so cache.c exports this non-header helper
   and the driver declares it locally. */
extern const char *tc_cache_rebuilt_reason(const tc_cache *cache);

// ----------------------------------------------------------------------------
// Line parsers — a faithful C port of the Python's regexes.
// ----------------------------------------------------------------------------
/* "[HH:MM:SS]" prefix -> 1 and h/m/s, else 0. */
static int ts_prefix(const char *line, size_t len, int *h, int *m, int *s) {
    if (len < 10 || line[0] != '[' || line[3] != ':' || line[6] != ':'
        || line[9] != ']') {
        return 0;
    }
    if (!isdigit((unsigned char)line[1]) || !isdigit((unsigned char)line[2])
        || !isdigit((unsigned char)line[4]) || !isdigit((unsigned char)line[5])
        || !isdigit((unsigned char)line[7]) || !isdigit((unsigned char)line[8])) {
        return 0;
    }
    *h = (line[1] - '0') * 10 + (line[2] - '0');
    *m = (line[4] - '0') * 10 + (line[5] - '0');
    *s = (line[7] - '0') * 10 + (line[8] - '0');
    return 1;
}

/* LIVE_RE: ^\[\d{2}:\d{2}:\d{2}\] \S+ is (live!|now offline\.)$
   Returns 1 live / 2 offline / 0 not a marker. */
static int line_is_marker(const char *line, size_t len) {
    size_t i;
    int h, m, s;

    if (!ts_prefix(line, len, &h, &m, &s)) {
        return 0;
    }
    if (len < 11 || line[10] != ' ') {
        return 0;
    }
    i = 11;
    while (i < len && line[i] != ' ') {
        i++;
    }
    if (i >= len) {
        return 0;
    }
    if (i + 9 == len && memcmp(line + i, " is live!", 9) == 0) {
        return 1;
    }
    if (i + 16 == len && memcmp(line + i, " is now offline.", 16) == 0) {
        return 2;
    }
    return 0;
}

/* LINE_RE: ^\[(\d{2}):(\d{2}):(\d{2})\] ([^:]+): (.*)$
   Returns 1 and fills who/msg + h/m/s, else 0. */
static int line_message(const char *line, size_t len, const char **who,
                        size_t *who_len, const char **msg, size_t *msg_len,
                        int *h, int *m, int *s) {
    size_t i;

    if (!ts_prefix(line, len, h, m, s)) {
        return 0;
    }
    if (len < 12 || line[10] != ' ') {
        return 0;
    }
    i = 11;
    while (i < len && line[i] != ':') {
        i++;
    }
    if (i + 2 > len || line[i + 1] != ' ') {
        return 0;               /* who holds no colon; ": " must follow */
    }
    *who = line + 11;
    *who_len = i - 11;
    *msg = line + i + 2;
    *msg_len = len - (i + 2);
    return 1;
}

/* LOGIN_RE: ^[A-Za-z0-9_]{1,25}$ */
static int login_re(const char *s, size_t len) {
    size_t i;
    if (len == 0 || len > 25) {
        return 0;
    }
    for (i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (!(isalnum(c) || c == '_')) {
            return 0;
        }
    }
    return 1;
}

/* speaker_login(who) -> 1 with the lowercase login in dst, 0 = system line.
   LOCALIZED_RE is "^(display) (login)$" with a non-ascii display byte. */
static int speaker_login(const char *who, size_t len, char *dst, size_t cap) {
    size_t sp;

    if (login_re(who, len)) {
        size_t i;
        if (len + 1 > cap) {
            return 0;
        }
        for (i = 0; i < len; i++) {
            dst[i] = (char)tolower((unsigned char)who[i]);
        }
        dst[len] = '\0';
        return 1;
    }
    sp = 0;
    while (sp < len && who[sp] != ' ') {
        sp++;
    }
    if (sp == 0 || sp >= len) {
        return 0;
    }
    if (!login_re(who + sp + 1, len - sp - 1)) {
        return 0;
    }
    {
        size_t i;
        int nonascii = 0;
        for (i = 0; i < sp; i++) {
            if ((unsigned char)who[i] > 127) {
                nonascii = 1;
                break;
            }
        }
        if (!nonascii) {
            return 0;
        }
    }
    {
        size_t n = len - sp - 1;
        if (n + 1 > cap) {
            return 0;
        }
        memcpy(dst, who + sp + 1, n);   /* already lowercase [a-z0-9_] */
        dst[n] = '\0';
        return 1;
    }
}

// ----------------------------------------------------------------------------
// The per-line classification (Python fold_lines; the C core's design keeps
// every user in the table — exclusions and the state filter only reshape
// messages/states at finish_tally).
// ----------------------------------------------------------------------------
static void process_line(const char *line, size_t len, int *state,
                         tc_users *day_users, int64_t day_states[3],
                         int64_t *day_messages) {
    const char *who, *msg;
    size_t who_len, msg_len;
    char login[TC_LOGIN_SZ];
    int h, m, s;
    int marker;
    int msg_state;

    (void)msg;
    (void)msg_len;

    if (len == 0 || line[0] == '#') {
        return;
    }
    marker = line_is_marker(line, len);
    if (marker == 1) {
        *state = TC_ST_LIVE;
        return;
    }
    if (marker == 2) {
        *state = TC_ST_OFFLINE;
        return;
    }
    if (!line_message(line, len, &who, &who_len, &msg, &msg_len, &h, &m, &s)) {
        return;
    }
    if (!speaker_login(who, who_len, login, sizeof(login))) {
        return;
    }
    msg_state = (*state == TC_ST_NONE) ? TC_ST_UNKNOWN : *state;
    tc_add_user(day_users, login, strlen(login), msg_state, 1);
    day_states[msg_state - 1] += 1;
    (*day_messages) += 1;
}

/* Fold the complete lines of a file.  A partial final line (after the last
   '\n') is held back rather than parsed — Chatterino may be midway through
   writing it (Python's TailReader keeps it as the remainder). */
static int process_lines(const char *text, size_t len, int enter_state,
                         tc_users *day_users, int64_t day_states[3],
                         int64_t *day_messages) {
    size_t cut = 0;             /* one past the last '\n' */
    size_t start = 0;
    size_t i;
    int state = enter_state;

    for (i = 0; i < len; i++) {
        if (text[i] == '\n') {
            cut = i + 1;
        }
    }
    for (i = 0; i <= cut; i++) {
        if (i < cut && text[i] != '\n') {
            continue;
        }
        process_line(text + start, i - start, &state, day_users, day_states,
                     day_messages);
        start = i + 1;
    }
    return state;
}

// ----------------------------------------------------------------------------
// The channel listing (Python log_files + FILENAME_RE).
// ----------------------------------------------------------------------------
/* "^(.+)-(\d{4})-(\d{2})-(\d{2})\.log$" -> packed ymd, or 0.  A well-shaped
   name that is not a real date (Python's date() ValueError) is skipped. */
static int64_t parse_log_filename(const char *name, size_t len) {
    int64_t y, mo, d;

    if (len < 15) {
        return 0;
    }
    if (memcmp(name + len - 4, ".log", 4) != 0 || name[len - 15] != '-') {
        return 0;
    }
    {
        const char *p = name + len - 14;
        int i;
        for (i = 0; i < 10; i++) {
            if (i == 4 || i == 7) {
                if (p[i] != '-') {
                    return 0;
                }
            } else if (!isdigit((unsigned char)p[i])) {
                return 0;
            }
        }
    }
    y = (name[len - 14] - '0') * 1000 + (name[len - 13] - '0') * 100
        + (name[len - 12] - '0') * 10 + (name[len - 11] - '0');
    mo = (name[len - 9] - '0') * 10 + (name[len - 8] - '0');
    d = (name[len - 6] - '0') * 10 + (name[len - 5] - '0');
    if (y < 1 || mo < 1 || mo > 12 || d < 1 || d > 31) {
        return 0;
    }
    return y * TC_YMD_YEAR_SCALE + mo * TC_YMD_MONTH_SCALE + d;
}

static int listing_append(tc_listing *listing, int64_t ymd, const char *name) {
    tc_listing_entry *grown;

    if (listing->count >= listing->cap) {
        int64_t new_cap = listing->cap > 0 ? listing->cap * 2 : 16;
        grown = (tc_listing_entry *)realloc(
            listing->entries, (size_t)new_cap * sizeof(tc_listing_entry));
        if (grown == NULL) {
            return TC_EXIT_ERROR;
        }
        listing->entries = grown;
        listing->cap = new_cap;
    }
    listing->entries[listing->count].ymd = ymd;
    tc_copy_str_cap(listing->entries[listing->count].name, name,
                    sizeof(listing->entries[listing->count].name));
    listing->count++;
    return TC_EXIT_OK;
}

static int listing_cmp(const void *a, const void *b) {
    const tc_listing_entry *ea = (const tc_listing_entry *)a;
    const tc_listing_entry *eb = (const tc_listing_entry *)b;
    if (ea->ymd != eb->ymd) {
        return ea->ymd < eb->ymd ? -1 : 1;
    }
    return strcmp(ea->name, eb->name);
}

static int build_listing(const char *channel_dir, tc_listing *listing) {
    DIR *d;
    struct dirent *de;

    d = opendir(channel_dir);
    if (d == NULL) {
        fprintf(stderr, "error: cannot read channel directory: %s\n",
                channel_dir);
        return TC_EXIT_ERROR;
    }
    while ((de = readdir(d)) != NULL) {
        int64_t ymd = parse_log_filename(de->d_name, strlen(de->d_name));
        if (ymd != 0
            && listing_append(listing, ymd, de->d_name) != TC_EXIT_OK) {
            closedir(d);
            return TC_EXIT_ERROR;
        }
    }
    closedir(d);
    if (listing->count > 1) {
        qsort(listing->entries, (size_t)listing->count,
              sizeof(tc_listing_entry), listing_cmp);
    }
    return TC_EXIT_OK;
}

// ----------------------------------------------------------------------------
// Channel dir resolution (Python resolve_channel_dir: case-insensitive).
// ----------------------------------------------------------------------------
static int resolve_channel_dir(const char *logs_dir, const char *channel,
                               char *dir_out, size_t dir_cap,
                               char *name_out, size_t name_cap) {
    DIR *d;
    struct dirent *de;
    char found[TC_CHANNEL_SZ];

    if (logs_dir == NULL || logs_dir[0] == '\0') {
        fprintf(stderr, "error: logs directory not found\n");
        return TC_EXIT_ERROR;
    }
    d = opendir(logs_dir);
    if (d == NULL) {
        fprintf(stderr, "error: logs directory not found: %s\n", logs_dir);
        return TC_EXIT_ERROR;
    }
    found[0] = '\0';
    while ((de = readdir(d)) != NULL) {
        char full[TC_PATH_SZ];
        struct stat st;
        size_t i;

        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) {
            continue;
        }
        snprintf(full, sizeof(full), "%s/%s", logs_dir, de->d_name);
        if (stat(full, &st) != 0 || !S_ISDIR(st.st_mode)) {
            continue;
        }
        if (strlen(de->d_name) >= sizeof(found)) {
            continue;
        }
        for (i = 0; de->d_name[i] != '\0'; i++) {
            if (tolower((unsigned char)de->d_name[i])
                != tolower((unsigned char)channel[i])) {
                break;
            }
        }
        if (de->d_name[i] == '\0' && channel[i] == '\0') {
            tc_copy_str_cap(found, de->d_name, sizeof(found));
            break;
        }
    }
    closedir(d);
    if (found[0] == '\0') {
        fprintf(stderr, "error: no logs for channel '%s' in %s\n", channel,
                logs_dir);
        return TC_EXIT_ERROR;
    }
    snprintf(dir_out, dir_cap, "%s/%s", logs_dir, found);
    tc_copy_str_cap(name_out, found, name_cap);
    return TC_EXIT_OK;
}

// ----------------------------------------------------------------------------
// Stream-state seed (Python seed_stream_state / core.c core_seed_state): the
// cache's exit state of the day before the range, else a marker scan back
// over up to 30 earlier files.
// ----------------------------------------------------------------------------
static int scan_markers(const char *fpath) {
    char *buf;
    size_t len;
    size_t cut = 0;
    size_t start = 0;
    size_t i;
    int state = TC_ST_NONE;

    if (tc_read_all(fpath, TC_FILE_CAP, &buf, &len) != 0) {
        return TC_ST_NONE;
    }
    for (i = 0; i < len; i++) {
        if (buf[i] == '\n') {
            cut = i + 1;
        }
    }
    for (i = 0; i <= cut; i++) {
        int marker;
        if (i < cut && buf[i] != '\n') {
            continue;
        }
        marker = line_is_marker(buf + start, i - start);
        if (marker == 1) {
            state = TC_ST_LIVE;
        } else if (marker == 2) {
            state = TC_ST_OFFLINE;
        }
        start = i + 1;
    }
    free(buf);
    return state;
}

static int seed_stream_state(tc_cache *cache, const char *channel,
                             const char *channel_dir,
                             const tc_listing *listing, int64_t begin_ymd) {
    int64_t idx = -1;
    int64_t i;

    for (i = 0; i < listing->count; i++) {
        if (listing->entries[i].ymd < begin_ymd) {
            idx = i;
        } else {
            break;
        }
    }
    if (idx < 0) {
        return TC_ST_NONE;
    }
    /* The day before the range is the only one whose exit state can seed. */
    if (tc_cache_used(cache)) {
        char fpath[TC_PATH_SZ];
        struct stat st;
        int64_t mtime_ns;
        int stt;

        snprintf(fpath, sizeof(fpath), "%s/%s", channel_dir,
                 listing->entries[idx].name);
        if (stat(fpath, &st) == 0) {
            mtime_ns = (int64_t)DRV_ST_MTIM_SEC(st) * TC_NANOSEC
                       + DRV_ST_MTIM_NSEC(st);
            stt = tc_cache_exit_state(cache, channel, listing->entries[idx].ymd,
                                      fpath, (int64_t)st.st_size, mtime_ns);
            if (stt != TC_ST_NONE) {
                return stt;
            }
        }
    }
    for (i = idx; i >= 0 && i >= idx - (DRV_SEED_LOOKBACK - 1); i--) {
        char fpath[TC_PATH_SZ];
        int state;

        snprintf(fpath, sizeof(fpath), "%s/%s", channel_dir,
                 listing->entries[i].name);
        state = scan_markers(fpath);
        if (state != TC_ST_NONE) {
            return state;
        }
    }
    return TC_ST_NONE;
}

// ----------------------------------------------------------------------------
// The counting pass (Python count_messages, one-shot; the day-tally pattern
// of core.c's core_run_count).
// ----------------------------------------------------------------------------
static void record_unreadable(tc_tally *tally, const char *name,
                              const char *reason) {
    if (tally->unreadable_count >= TC_T_UNR_MAX) {
        return;
    }
    tc_copy_str_cap(tally->unreadable[tally->unreadable_count].name, name,
                    TC_T_UNR_NAME_SZ);
    tc_copy_str_cap(tally->unreadable[tally->unreadable_count].reason, reason,
                    TC_T_UNR_REASON_SZ);
    tally->unreadable_count++;
}

/* Merge one day's counts (parsed or served) into the run tally (the core's
   core_merge_day: the day table is authoritative for both paths). */
static void merge_day(tc_users *run_users, tc_tally *run_tally,
                      const tc_tally *day) {
    const tc_users *du = day->users;
    int64_t i;
    for (i = 0; i < du->count; i++) {
        const tc_user_entry *entry = &du->entries[i];
        size_t llen = strlen(entry->login);
        if (entry->live > 0) {
            tc_add_user(run_users, entry->login, llen, TC_ST_LIVE,
                        entry->live);
            run_tally->states[TC_ST_LIVE - 1] += entry->live;
        }
        if (entry->offline > 0) {
            tc_add_user(run_users, entry->login, llen, TC_ST_OFFLINE,
                        entry->offline);
            run_tally->states[TC_ST_OFFLINE - 1] += entry->offline;
        }
        if (entry->unknown > 0) {
            tc_add_user(run_users, entry->login, llen, TC_ST_UNKNOWN,
                        entry->unknown);
            run_tally->states[TC_ST_UNKNOWN - 1] += entry->unknown;
        }
    }
}

/* The count-column value of one user under the state filter. */
static int64_t user_count_for_filter(const tc_user_entry *entry,
                                     int state_filter) {
    if (state_filter == TC_ST_NONE) {
        return tc_user_count(entry);
    }
    return tc_user_state(entry, state_filter);
}

/* Finish the run tally from the users table (the core's core_finish_tally):
   messages = non-excluded count-column total; excluded_states = the excluded
   split; the states become the non-excluded split. */
static void finish_tally(const tc_window *window, const tc_excl_set *excl,
                         tc_users *users, tc_tally *tally) {
    int64_t i;
    memset(tally->excluded_states, 0, sizeof(tally->excluded_states));
    tally->messages = 0;
    for (i = 0; i < users->count; i++) {
        tc_user_entry *entry = &users->entries[i];
        size_t llen = strlen(entry->login);
        if (tc_excl_contains(excl, entry->login, llen)) {
            int s;
            for (s = 0; s < 3; s++) {
                int64_t n = tc_user_state(entry, s + TC_ST_LIVE);
                tally->excluded_states[s] += n;
                tally->states[s] -= n;
            }
        } else {
            tally->messages += user_count_for_filter(entry,
                                                     window->state_filter);
        }
    }
}

static void reset_users(tc_users *users) {
    users->count = 0;           /* the entries buffer is kept and reused */
}

static void reset_tally(tc_tally *tally) {
    int64_t i;
    tally->files = 0;
    tally->messages = 0;
    for (i = 0; i < 3; i++) {
        tally->states[i] = 0;
        tally->excluded_states[i] = 0;
    }
    tally->parsed = 0;
    tally->reused = 0;
    tally->unreadable_count = 0;
}

static void count_pass(tc_cache *cache, const char *channel,
                       const char *channel_dir, const tc_listing *listing,
                       const tc_window *window,
                       int64_t current, tc_tally *tally) {
    tc_users day_users = {0};
    tc_tally day_tally = {0};
    int64_t i;

    day_tally.users = &day_users;

    for (i = 0; i < listing->count; i++) {
        int64_t ymd = listing->entries[i].ymd;
        char fpath[TC_PATH_SZ];
        struct stat st;
        int64_t size, mtime_ns;
        int whole_day;
        int status;
        int enter;

        if (ymd < window->begin_ymd || ymd > window->end_ymd) {
            continue;
        }
        tally->files++;

        /* whole_day: begin <= day_start and day_end <= end */
        whole_day =
            (window->begin_ymd < ymd
             || (window->begin_ymd == ymd && window->begin_sod == 0))
            && (window->end_ymd > ymd
                || (window->end_ymd == ymd
                    && window->end_sod == TC_LAST_SECOND));

        snprintf(fpath, sizeof(fpath), "%s/%s", channel_dir,
                 listing->entries[i].name);
        if (stat(fpath, &st) != 0) {
            char reason[TC_T_UNR_REASON_SZ];
            snprintf(reason, sizeof(reason), "OSError: %s", strerror(errno));
            record_unreadable(tally, listing->entries[i].name, reason);
            current = TC_ST_NONE;   /* skip(): stop trusting the stream */
            tc_cache_discard_day(cache);
            continue;
        }
        size = (int64_t)st.st_size;
        mtime_ns = (int64_t)DRV_ST_MTIM_SEC(st) * TC_NANOSEC
                   + DRV_ST_MTIM_NSEC(st);

        /* rollup-cache serve: a whole day inside the range is settled. */
        if (tc_cache_used(cache) && whole_day) {
            reset_users(&day_users);
            reset_tally(&day_tally);
            status = tc_cache_day(cache, channel, ymd, fpath, size, mtime_ns,
                                  (int)current, &day_tally);
            if (status == 1) {
                merge_day(tally->users, tally, &day_tally);
                current = tc_cache_exit_state(cache, channel, ymd, fpath,
                                              size, mtime_ns);
                continue;
            }
            /* status 0 (miss) or 2 (row unusable): parse normally. */
        }

        {
            char *buf;
            size_t len;
            int rr = tc_read_all(fpath, TC_FILE_CAP, &buf, &len);
            if (rr != 0) {
                char reason[TC_T_UNR_REASON_SZ];
                if (rr == 1) {
                    tc_copy_str_cap(reason, "file too large",
                                    sizeof(reason));
                } else {
                    snprintf(reason, sizeof(reason), "OSError: %s",
                             strerror(errno));
                }
                record_unreadable(tally, listing->entries[i].name, reason);
                free(buf);
                current = TC_ST_NONE;
                tc_cache_discard_day(cache);
                continue;
            }
            /* no complete line: nothing folded, nothing parsed, and the
               stream state does not carry across it */
            if (len == 0 || memchr(buf, '\n', len) == NULL) {
                free(buf);
                tc_cache_discard_day(cache);
                continue;
            }
            enter = (int)current;
            reset_users(&day_users);
            reset_tally(&day_tally);
            current = process_lines(buf, len, enter, &day_users,
                                    day_tally.states, &day_tally.messages);
            free(buf);

            merge_day(tally->users, tally, &day_tally);

            /* write the whole day to the rollup after a cold, whole-file
               read; unreadable / partial days never write */
            if (whole_day) {
                tc_cache_put_day(cache, channel, ymd, fpath, size, mtime_ns,
                                 enter, (int)current, &day_tally);
            }
            tc_cache_discard_day(cache);
        }
    }
}

// ----------------------------------------------------------------------------
// The contract dump (same shapes as the asm check_tc_dump.S + check driver).
// ----------------------------------------------------------------------------
static void dump_channel(const char *channel) {
    printf("channel=%s\n", channel);
}

static void dump_window(const tc_window *window) {
    printf("window begin=%lld:%lld end=%lld:%lld kind=%lld width=%lld"
           " found=%lld req=%lld\n",
           (long long)window->begin_ymd, (long long)window->begin_sod,
           (long long)window->end_ymd, (long long)window->end_sod,
           (long long)window->kind, (long long)window->users_width,
           (long long)window->users_found, (long long)window->users_req);
}

static void dump_listing(const tc_listing *listing) {
    int64_t i;
    printf("listing %lld\n", (long long)listing->count);
    for (i = 0; i < listing->count; i++) {
        printf("%lld %s\n", (long long)listing->entries[i].ymd,
               listing->entries[i].name);
    }
}

static void dump_users(const tc_users *users) {
    int64_t i;
    printf("users %lld\n", (long long)users->count);
    for (i = 0; i < users->count; i++) {
        printf("%s %lld %lld %lld\n", users->entries[i].login,
               (long long)users->entries[i].live,
               (long long)users->entries[i].offline,
               (long long)users->entries[i].unknown);
    }
}

static void dump_tally(const tc_tally *tally) {
    printf("tally files=%lld messages=%lld parsed=%lld states=%lld:%lld:%lld"
           " excl=%lld:%lld:%lld unreadable=%lld\n",
           (long long)tally->files, (long long)tally->messages,
           (long long)tally->parsed, (long long)tally->states[0],
           (long long)tally->states[1], (long long)tally->states[2],
           (long long)tally->excluded_states[0],
           (long long)tally->excluded_states[1],
           (long long)tally->excluded_states[2],
           (long long)tally->unreadable_count);
}

static void dump_unreadable(const tc_tally *tally) {
    int64_t i;
    for (i = 0; i < tally->unreadable_count; i++) {
        printf("unreadable %s %s\n", tally->unreadable[i].name,
               tally->unreadable[i].reason);
    }
}

/* The cachestatus line, asm-check_tc_cache.S format. */
static void dump_cachestatus(tc_cache *cache) {
    int64_t reused, parsed;
    const char *problem, *path;
    int used = tc_cache_used(cache);

    tc_cache_status(cache, &reused, &parsed, &problem, &path);
    printf("cachestatus used=%d reused=%lld parsed=%lld problem=%s rebuilt=%s"
           " path=%s\n",
           used, (long long)reused, (long long)parsed,
           problem != NULL ? problem : "-",
           tc_cache_rebuilt_reason(cache) != NULL
               ? tc_cache_rebuilt_reason(cache)
               : "-",
           path != NULL ? path : "-");
}

// ----------------------------------------------------------------------------
// main — the driver entry.
// ----------------------------------------------------------------------------
int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    tc_excl_set exclusions;
    tc_cache *cache = NULL;
    const char *open_problem = NULL;
    char channel_dir[TC_PATH_SZ];
    char channel_name[TC_CHANNEL_SZ];
    char cache_path[TC_PATH_SZ];
    tc_listing listing;
    tc_users users;
    tc_tally tally;
    int status;

    memset(&opts, 0, sizeof(opts));
    memset(&window, 0, sizeof(window));
    memset(&exclusions, 0, sizeof(exclusions));
    memset(&listing, 0, sizeof(listing));
    memset(&users, 0, sizeof(users));
    memset(&tally, 0, sizeof(tally));
    tally.users = &users;

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;
    }
    status = tc_build_exclusions(&opts, &exclusions);
    if (status != TC_EXIT_OK) {
        return status;
    }
    status = resolve_channel_dir(opts.logs_dir, opts.channel, channel_dir,
                                 sizeof(channel_dir), channel_name,
                                 sizeof(channel_name));
    if (status != TC_EXIT_OK) {
        return status;
    }

    /* cache path: --no-cache disables (no db touched); else the platform
       default (XDG_CACHE_HOME on Linux, ~/.cache on macOS). */
    if (opts.flags & TC_F_NO_CACHE) {
        cache_path[0] = '\0';
    } else {
        tc_default_cache_path(cache_path, sizeof(cache_path));
    }
    tc_cache_open(cache_path,
                  (opts.flags & TC_F_REBUILD_CACHE) ? 1 : 0, channel_name,
                  &cache, &open_problem);
    (void)open_problem;

    if (build_listing(channel_dir, &listing) != TC_EXIT_OK) {
        tc_cache_close(cache);
        return TC_EXIT_ERROR;
    }
    if (window.kind == TC_WIN_EARLIEST && listing.count > 0) {
        /* begin = earliest log file at 00:00:00 (tc_count_run normally
           completes this; the driver replicates it because it owns the
           counting pass here) */
        window.begin_ymd = listing.entries[0].ymd;
        window.begin_sod = 0;
    }

    {
        int64_t current = seed_stream_state(cache, channel_name, channel_dir,
                                            &listing, window.begin_ymd);
        count_pass(cache, channel_name, channel_dir, &listing, &window,
                   current, &tally);
    }
    finish_tally(&window, &exclusions, &users, &tally);

    /* The tally's parsed/reused mirror the cache's counters so the tally line
       and the cachestatus line always agree (the cache owns the counters). */
    {
        int64_t creused, cparsed;
        const char *cproblem, *cpath;
        tc_cache_status(cache, &creused, &cparsed, &cproblem, &cpath);
        tally.reused = creused;
        tally.parsed = cparsed;
    }

    dump_channel(channel_name);
    dump_window(&window);
    dump_listing(&listing);
    dump_users(&users);
    dump_tally(&tally);
    dump_unreadable(&tally);
    dump_cachestatus(cache);
    tc_cache_debug_dump(cache);

    free(listing.entries);
    free(users.entries);
    tc_cache_close(cache);
    return TC_EXIT_OK;
}