// ============================================================================
// cache.c — the SQLite rollup cache.
//
//  Day-level rollup of parsed logs (Python reference: the Cache class,
//  cache_row_valid, CACHE_SCHEMA / CACHE_SCHEMA_VERSION=2 / CACHE_KEEP_DAYS=7
//  in twitch-counts.py).  A cached day is trusted only when the log file still
//  has the same size and mtime AND the live/offline state entering the file is
//  the same as when it was parsed -- the second check is what keeps the state
//  timeline honest, since a day with no markers of its own inherits its
//  classification from earlier days.
//
//  A cache is an optimization and must NEVER fail a query: on any problem
//  tc_cache_open reports a step-named reason ("<step> failed -- <Type>: ...")
//  through the problem out-param and returns a valid handle that
//  tc_cache_used() reports as unused, so the run parses every file instead.
//  Genuine API misuse (a NULL out-param) fails loudly, per the port's
//  philosophy; every recoverable cache problem degrades to parsing.
//
//  Schema (exact SQL from the Python CACHE_SCHEMA):
//    meta(key TEXT PRIMARY KEY, value TEXT);
//    generation(fingerprint TEXT PRIMARY KEY, last_seen TEXT NOT NULL)
//        WITHOUT ROWID;
//    file(fingerprint TEXT NOT NULL, channel TEXT NOT NULL, date TEXT NOT
//        NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
//        enter_state TEXT, exit_state TEXT,
//        PRIMARY KEY(fingerprint, channel, date)) WITHOUT ROWID;
//    counts(fingerprint TEXT NOT NULL, channel TEXT NOT NULL, date TEXT NOT
//        NULL, login TEXT NOT NULL, state TEXT NOT NULL, n INTEGER NOT NULL,
//        PRIMARY KEY(fingerprint, channel, date, login, state)) WITHOUT ROWID;
//
//  Migration (Python Cache._migrate): when the stored meta 'schema' value is
//    not "2", the file/counts/generation tables are dropped and recreated and
//    meta.schema is set to "2".  Reason: "new cache" (the db did not exist)
//    or "new cache layout" (it did).  The generation table records each
//    parser fingerprint seen; registering a fingerprint that is not among the
//    already-known ones yields "new parser generation" (only when at least
//    one generation was already known).  Generations unseen for
//    CACHE_KEEP_DAYS (7) are swept at open (their file/counts/generation rows
//    are deleted).  --rebuild-cache purges the channel across every
//    generation and sets the reason to "--rebuild-cache".
//
//  ============================================================================
//  THE FINGERPRINT SCHEME (reproducible cache format)
//  ============================================================================
//  Python hashes the AST of its own parsing sources (cache_fingerprint);
//  that exact value cannot be reproduced in a different implementation.  This
//  port owns its own stable tag (the Q8 decision, mirroring the asm port):
//
//    FNV-1a 64-bit over a fixed list of parts, rendered as 16 lowercase hex
//    characters (most significant nibble first) into a TC_FP_SZ (17) buffer.
//    Each part is folded byte-by-byte, then a single '\n' separator byte is
//    folded, in order, starting from the FNV-1a offset basis:
//
//      1. "tc-cache-fp-v1"                        -- the fingerprint VERSION.
//           Bump this literal when the parsing logic changes; the cache
//           format itself is versioned by part 2, not by this.
//      2. "schema=2"                              -- CACHE_SCHEMA_VERSION.
//      3. "live=is live!"                         -- the live marker suffix
//           (the parser's LIVE_RE literal).
//      4. "off=is now offline."                   -- the offline marker suffix.
//      5. "login=[A-Za-z0-9_]{1,25}"              -- the login rule (LOGIN_RE).
//      6. "localized=\\S+ [a-z0-9_]{1,25} nonascii" -- the localized-display
//           rule (LOCALIZED_RE plus the non-ascii display requirement).
//      7. "fmt=[HH:MM:SS] who: msg"               -- the message line format
//           (LINE_RE).
//      8. "states=live,offline,unknown"           -- the state set (STATES).
//      9. "whole=0..86399"                        -- the whole-day rule.
//     10. "class=process_lines+process_message+line_is_marker+speaker_login"
//                                                -- the classification
//           functions whose behaviour feeds the cached numbers.
//
//    The parts mirror asm/tc_parse_facts.inc (pfx_fp_live / pfx_fp_off /
//    pfx_fp_login) and the asm cache's s_fp_* table byte-for-byte, so the C
//    and asm ports compute the SAME tag and can share one rollup.db.
//
//    The version literal is a weak symbol (tc_cache_fp_head_override): the
//    tc-cache-bump-test driver defines the strong form to prove that two
//    fingerprint generations coexist in one database, exactly like the asm
//    Makefile's sed bump of tc_cache.S.
//
//  Put semantics (documented deviation from the Python)
//  ---------------------------------------------------
//    The Python writes a whole-day row for ANY successfully cold-read file,
//    whole-day in the window or not (reader.day() covers the whole file).
//    This port writes rollup rows ONLY for whole-day files (the caller asks
//    the cache only for whole days -- the C contract hands the caller the
//    window, so the caller decides): a window-partial day's row would
//    otherwise store window counts, corrupting any later whole-day reuse.
//    "Unreadable / partial days are never written" (spec).  Counts are
//    identical either way; only the cached/reused counters differ in the
//    window-partial case (the Python reuses the day later, this port
//    re-parses it).
//
//  Serving a cached day (documented deviation from the Python)
//  -----------------------------------------------------------
//    The Python's Cache.get returns (counts, exit_state) and the caller
//    carries the exit state forward.  The C contract's tc_cache_day returns
//    only 0/1/2, so the caller recovers the cached exit state with the
//    separate tc_cache_exit_state query (validated by size+mtime, with the
//    entering state deliberately ignored -- the state a day ended in does not
//    depend on how it began).
//
//  C-port design notes
//  -------------------
//    * The cache handle (tc_cache) is an explicit struct; there are no hidden
//      globals.  The sqlite3 connection stays opaque inside this module.
//    * Cached counts are applied straight into the caller's tc_tally user
//      table (tally->users, owned by the caller) rather than through the
//      core's tc_reuse_apply hook: the C contract hands the cache the tally,
//      so the cache can fill it without a cross-module callback.  The user
//      table is grown by appending, keeping entries index-aligned with the
//      put-day snapshot (see below).
//    * tc_cache_put_day receives the whole accumulated tally; the day's own
//      counts are the table's delta since the snapshot tc_cache_day stashed
//      at miss time.  A snapshot is taken only for whole-day misses, so
//      partial days never write.
// ============================================================================

/* localtime_r is a POSIX function; expose it under -std=c99. */
#define _POSIX_C_SOURCE 200809L

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <sys/stat.h>

#include "../third_party/sqlite3/sqlite3.h"

// ----------------------------------------------------------------------------
// The tc_cache handle — opaque to every other module (tc_platform.h only
// forward-declares the tag).
// ----------------------------------------------------------------------------
struct tc_cache {
    sqlite3 *db;                        /* NULL = not usable / disabled */
    char fingerprint[TC_FP_SZ];         /* this run's generation tag */
    char path[TC_PATH_SZ];              /* the db path ("" = disabled) */
    char problem_buf[TC_PATH_SZ + 160]; /* composed "<step> failed -- ..." */
    const char *problem;                /* NULL when none */
    const char *rebuilt_reason;         /* "new cache" / ... / NULL */
    int64_t reused;                     /* whole days served */
    int64_t parsed;                     /* whole files parsed (reported back) */
    int64_t swept;                      /* generations swept at open */
    /* pending whole-day stash (tc_cache_day miss -> tc_cache_put_day) */
    int stash_valid;
    int64_t stash_ymd;
    int64_t stash_size;
    int64_t stash_mtime_ns;
    int stash_enter;
    tc_user_entry *stash_snap;          /* malloc'd table copy (index-aligned) */
    int64_t stash_snap_n;
};

// ----------------------------------------------------------------------------
// Fixed SQL (identical strings to the asm port / the Python).
// ----------------------------------------------------------------------------
#define CACHE_SCHEMA_VERSION "2"
#define CACHE_KEEP_DAYS 7

static const char s_schema[] =
    "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);"
    "CREATE TABLE IF NOT EXISTS generation(fingerprint TEXT PRIMARY KEY,"
    " last_seen TEXT NOT NULL) WITHOUT ROWID;"
    "CREATE TABLE IF NOT EXISTS file(fingerprint TEXT NOT NULL,"
    " channel TEXT NOT NULL, date TEXT NOT NULL,"
    " size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,"
    " enter_state TEXT, exit_state TEXT,"
    " PRIMARY KEY(fingerprint, channel, date)) WITHOUT ROWID;"
    "CREATE TABLE IF NOT EXISTS counts(fingerprint TEXT NOT NULL,"
    " channel TEXT NOT NULL, date TEXT NOT NULL,"
    " login TEXT NOT NULL, state TEXT NOT NULL, n INTEGER NOT NULL,"
    " PRIMARY KEY(fingerprint, channel, date, login, state)) WITHOUT ROWID;";

static const char s_drop_tables[] =
    "DROP TABLE IF EXISTS file;"
    "DROP TABLE IF EXISTS counts;"
    "DROP TABLE IF EXISTS generation;";

static const char s_sel_schema[] =
    "SELECT value FROM meta WHERE key = 'schema'";
static const char s_set_schema[] =
    "INSERT OR REPLACE INTO meta VALUES('schema', ?)";
static const char s_sel_gen[] = "SELECT fingerprint FROM generation";
static const char s_ins_gen[] =
    "INSERT INTO generation VALUES(?, ?) ON CONFLICT(fingerprint)"
    " DO UPDATE SET last_seen = excluded.last_seen";
static const char s_sel_stale[] =
    "SELECT fingerprint FROM generation WHERE last_seen < ?";
static const char s_del_counts_fp[] = "DELETE FROM counts WHERE fingerprint = ?";
static const char s_del_file_fp[] = "DELETE FROM file WHERE fingerprint = ?";
static const char s_del_gen_fp[] = "DELETE FROM generation WHERE fingerprint = ?";
static const char s_del_counts_chan[] = "DELETE FROM counts WHERE channel = ?";
static const char s_del_file_chan[] = "DELETE FROM file WHERE channel = ?";
static const char s_del_all_counts[] = "DELETE FROM counts";
static const char s_del_all_file[] = "DELETE FROM file";
static const char s_sel_file[] =
    "SELECT fingerprint, size, mtime_ns, enter_state, exit_state"
    " FROM file WHERE fingerprint = ? AND channel = ? AND date = ?";
static const char s_sel_counts[] =
    "SELECT login, state, n FROM counts"
    " WHERE fingerprint = ? AND channel = ? AND date = ?";
static const char s_del_day_counts[] =
    "DELETE FROM counts WHERE fingerprint = ? AND channel = ? AND date = ?";
static const char s_ins_count[] = "INSERT INTO counts VALUES(?, ?, ?, ?, ?, ?)";
static const char s_ins_file[] =
    "INSERT OR REPLACE INTO file VALUES(?, ?, ?, ?, ?, ?, ?)";
static const char s_master[] =
    "SELECT name FROM sqlite_master WHERE type='table'"
    " AND name NOT LIKE 'sqlite_%' ORDER BY name";
static const char s_count_meta[] = "SELECT COUNT(*) FROM meta";
static const char s_count_generation[] = "SELECT COUNT(*) FROM generation";
static const char s_count_file[] = "SELECT COUNT(*) FROM file";
static const char s_count_counts[] = "SELECT COUNT(*) FROM counts";
static const char s_all_file[] =
    "SELECT fingerprint, channel, date, size, mtime_ns, enter_state,"
    " exit_state FROM file ORDER BY date";
static const char s_all_counts[] =
    "SELECT fingerprint, channel, date, login, state, n"
    " FROM counts ORDER BY date, login";

// ----------------------------------------------------------------------------
// Fingerprint input parts — see the header comment above.  Part 0 (the
// version head) is filled from the (weak) override so the bump test driver
// can register a second generation.
// ----------------------------------------------------------------------------
__attribute__((weak)) const char *tc_cache_fp_head_override(void) {
    return NULL;
}

static const char *const s_fp_parts[] = {
    "schema=2",
    "live=is live!",
    "off=is now offline.",
    "login=[A-Za-z0-9_]{1,25}",
    "localized=\\S+ [a-z0-9_]{1,25} nonascii",
    "fmt=[HH:MM:SS] who: msg",
    "states=live,offline,unknown",
    "whole=0..86399",
    "class=process_lines+process_message+line_is_marker+speaker_login",
    NULL,
};
#define TC_CACHE_FP_HEAD_DEFAULT "tc-cache-fp-v1"

// ----------------------------------------------------------------------------
// FNV-1a chaining — folds one byte run into a running hash (the header's
// tc_fnv1a_64_bytes always starts from the offset basis, so the cache needs
// its own chaining form).
// ----------------------------------------------------------------------------
static uint64_t cache_fnv_update(uint64_t hash, const void *data, size_t len) {
    const unsigned char *p = (const unsigned char *)data;
    size_t i;
    for (i = 0; i < len; i++) {
        hash ^= (uint64_t)p[i];
        hash *= TC_FNV1A_64_PRIME;
    }
    return hash;
}

/* Render the hash as 16 lowercase hex chars, most significant nibble first. */
static void cache_fmt_fp(char *dst, uint64_t hash) {
    static const char s_hex[] = "0123456789abcdef";
    int i;
    for (i = 0; i < 16; i++) {
        dst[i] = s_hex[(hash >> (60 - 4 * i)) & 0xF];
    }
    dst[16] = '\0';
}

static void cache_fingerprint_build(tc_cache *cache) {
    const char *head = tc_cache_fp_head_override();
    uint64_t hash = TC_FNV1A_64_OFFSET_BASIS;
    size_t i;

    if (head == NULL) {
        head = TC_CACHE_FP_HEAD_DEFAULT;
    }
    hash = cache_fnv_update(hash, head, strlen(head));
    hash = cache_fnv_update(hash, "\n", 1);
    for (i = 0; s_fp_parts[i] != NULL; i++) {
        hash = cache_fnv_update(hash, s_fp_parts[i], strlen(s_fp_parts[i]));
        hash = cache_fnv_update(hash, "\n", 1);
    }
    cache_fmt_fp(cache->fingerprint, hash);
}

// ----------------------------------------------------------------------------
// State <-> string conversion.  TC_ST_NONE (0) is SQL NULL (Python's None);
// TC_ST_UNKNOWN (3) is the literal "unknown".
// ----------------------------------------------------------------------------
static const char *cache_state_str(int id) {
    switch (id) {
    case TC_ST_LIVE:
        return "live";
    case TC_ST_OFFLINE:
        return "offline";
    case TC_ST_UNKNOWN:
        return "unknown";
    default:
        return NULL;            /* TC_ST_NONE -> SQL NULL */
    }
}

static int cache_state_id(const char *s) {
    if (s == NULL) {
        return TC_ST_NONE;
    }
    if (strcmp(s, "live") == 0) {
        return TC_ST_LIVE;
    }
    if (strcmp(s, "offline") == 0) {
        return TC_ST_OFFLINE;
    }
    if (strcmp(s, "unknown") == 0) {
        return TC_ST_UNKNOWN;
    }
    return TC_ST_NONE;
}

// ----------------------------------------------------------------------------
// "YYYY-MM-DD" from a packed ymd (no NUL trailing concerns: 11 bytes).
// ----------------------------------------------------------------------------
static void cache_fmt_date(char *dst, int64_t ymd) {
    int y, m, d;
    tc_ymd_split(ymd, &y, &m, &d);
    sprintf(dst, "%04d-%02d-%02d", y, m, d);
}

/* "YYYY-MM-DDTHH:MM:SS" local time (Python's isoformat shape, second
   precision like the asm port); the sweep cutoff compares the same shape. */
static void cache_fmt_iso(char *dst, int64_t epoch) {
    struct tm tmv;
    time_t t = (time_t)epoch;
    struct tm *tm = localtime_r(&t, &tmv);
    if (tm == NULL) {
        sprintf(dst, "1970-01-01T00:00:00");
        return;
    }
    sprintf(dst, "%04d-%02d-%02dT%02d:%02d:%02d",
            tm->tm_year + TC_TM_YEAR_BASE, tm->tm_mon + 1, tm->tm_mday,
            tm->tm_hour, tm->tm_min, tm->tm_sec);
}

// ----------------------------------------------------------------------------
// sqlite3 helpers — every step is guarded so a failure degrades, never
// crashes.  Statements are prepared per call (the cache is not hot enough to
// cache prepared statements, and re-preparing keeps error paths trivial).
// ----------------------------------------------------------------------------
static int cache_exec(tc_cache *cache, const char *sql) {
    return sqlite3_exec(cache->db, sql, NULL, NULL, NULL);
}

/* Prepare + bind + step one statement.  Returns 1 ok, 0 on any error.  The
   `bind` helper fills parameter slots in order; it returns 0 on failure. */
typedef struct {
    const char *texts[7];
    int64_t ints[7];
    int text_mask;              /* bit i set: slot i is text; else int64 */
    int n;
} cache_bindings;

static int cache_prepare_bind(tc_cache *cache, const char *sql,
                              const cache_bindings *b, sqlite3_stmt **out) {
    sqlite3_stmt *stmt;
    int rc;
    int i;

    rc = sqlite3_prepare_v2(cache->db, sql, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        return 0;
    }
    for (i = 0; i < b->n; i++) {
        if (b->text_mask & (1 << i)) {
            rc = sqlite3_bind_text(stmt, i + 1, b->texts[i], -1, SQLITE_STATIC);
        } else {
            rc = sqlite3_bind_int64(stmt, i + 1, b->ints[i]);
        }
        if (rc != SQLITE_OK) {
            sqlite3_finalize(stmt);
            return 0;
        }
    }
    *out = stmt;
    return 1;
}

/* Step a statement; returns SQLITE_ROW / SQLITE_DONE / the error rc. */
static int cache_step(sqlite3_stmt *stmt) {
    return sqlite3_step(stmt);
}

/* Compose the step-named problem, close the db and mark the cache unused.
   rc maps to a CPython-sqlite3-style exception name (same map as the asm). */
static const char *cache_sqlite_type_name(int rc) {
    switch (rc) {
    case SQLITE_NOTADB:
    case SQLITE_CORRUPT:
    case SQLITE_ERROR:
        return "DatabaseError";
    case SQLITE_NOMEM:
        return "MemoryError";
    default:
        return "OperationalError";
    }
}

static void cache_fail_step(tc_cache *cache, const char *step, int rc) {
    const char *msg = cache->db != NULL ? sqlite3_errmsg(cache->db)
                                        : "unknown error";
    char *p = cache->problem_buf;
    p = tc_cat_cstr(p, step);
    p = tc_cat_cstr(p, " failed -- ");
    p = tc_cat_cstr(p, cache_sqlite_type_name(rc));
    p = tc_cat_cstr(p, ": ");
    p = tc_cat_cstr(p, msg);
    cache->problem = cache->problem_buf;
    if (cache->db != NULL) {
        sqlite3_close(cache->db);
        cache->db = NULL;
    }
}

/* mkdir -p for the parent directory of a path (the Python os.makedirs).
   Only the separator positions are mkdir'd — the final path component (the
   db file itself) is never treated as a directory. */
static int cache_mkdir_parent(const char *path) {
    char tmp[TC_PATH_SZ];
    size_t len = strlen(path);
    size_t i;

    if (len == 0 || len >= sizeof(tmp)) {
        return -1;
    }
    memcpy(tmp, path, len + 1);
    while (len > 1 && tmp[len - 1] == '/') {
        tmp[--len] = '\0';
    }
    for (i = 1; i < len; i++) {
        char saved;
        if (tmp[i] != '/') {
            continue;
        }
        saved = tmp[i];
        tmp[i] = '\0';
        if (tmp[0] != '\0' && mkdir(tmp, TC_DIR_MODE) != 0 && errno != EEXIST) {
            return -1;
        }
        tmp[i] = saved;
    }
    return 0;
}

// ----------------------------------------------------------------------------
// Snapshot management — the whole-day stash.
// ----------------------------------------------------------------------------
static void cache_drop_stash(tc_cache *cache) {
    free(cache->stash_snap);
    cache->stash_snap = NULL;
    cache->stash_snap_n = 0;
    cache->stash_valid = 0;
}

static int cache_snapshot_users(tc_cache *cache, const tc_users *users) {
    int64_t n = users->count;
    tc_user_entry *snap;

    if (n <= 0) {
        cache->stash_snap = NULL;
        cache->stash_snap_n = 0;
        return 1;
    }
    snap = (tc_user_entry *)malloc((size_t)n * sizeof(tc_user_entry));
    if (snap == NULL) {
        return 0;               /* malloc fail -> no put (still parse) */
    }
    memcpy(snap, users->entries, (size_t)n * sizeof(tc_user_entry));
    cache->stash_snap = snap;
    cache->stash_snap_n = n;
    return 1;
}

// ----------------------------------------------------------------------------
// Applying cached counts into the caller's tally.
// ----------------------------------------------------------------------------
/* Find-or-append a login in the user table; returns the entry pointer or NULL
   on realloc failure.  The table only ever grows (append-only), which keeps
   the put-day snapshot index-aligned. */
static tc_user_entry *cache_user_find_or_add(tc_users *users,
                                             const char *login, size_t len) {
    int64_t i;
    for (i = 0; i < users->count; i++) {
        if (strcmp(users->entries[i].login, login) == 0) {
            return &users->entries[i];
        }
    }
    if (users->count >= users->cap) {
        int64_t new_cap = users->cap > 0 ? users->cap * 2 : 16;
        tc_user_entry *grown = (tc_user_entry *)realloc(
            users->entries, (size_t)new_cap * sizeof(tc_user_entry));
        if (grown == NULL) {
            return NULL;
        }
        users->entries = grown;
        users->cap = new_cap;
    }
    {
        tc_user_entry *e = &users->entries[users->count];
        size_t n = len < TC_LOGIN_SZ - 1 ? len : TC_LOGIN_SZ - 1;
        memcpy(e->login, login, n);
        e->login[n] = '\0';
        e->live = 0;
        e->offline = 0;
        e->unknown = 0;
        users->count++;
        return e;
    }
}

static void cache_apply_row(tc_users *users, int64_t *states,
                            const char *login, int state, int64_t n) {
    tc_user_entry *e = cache_user_find_or_add(users, login, strlen(login));
    if (e == NULL) {
        return;                 /* OOM: the day is a miss next time */
    }
    switch (state) {
    case TC_ST_LIVE:
        e->live += n;
        break;
    case TC_ST_OFFLINE:
        e->offline += n;
        break;
    case TC_ST_UNKNOWN:
        e->unknown += n;
        break;
    default:
        return;
    }
    if (state >= TC_ST_LIVE && state <= TC_ST_UNKNOWN) {
        states[state - 1] += n;
    }
}

// ----------------------------------------------------------------------------
// tc_cache_open — session open (the one-shot owner calls this before counting
//   and tc_cache_close after; watch mode opens once per session).
//
//   On ANY problem the handle is still returned (valid, reporting unused)
//   with a step-named problem; the caller parses every file.  An empty path
//   means "no cache" (--no-cache / no default location): not a fault.
// ============================================================================
int tc_cache_open(const char *path, int rebuild, const char *channel,
                  tc_cache **cache_out, const char **problem_out) {
    tc_cache *cache;
    int existed;
    int rc;
    sqlite3_stmt *stmt;
    int known = 0;
    int present = 0;
    int64_t now;
    char iso[32];

    if (cache_out == NULL || problem_out == NULL) {
        tc_fail("cache: tc_cache_open: NULL out-param");
    }
    *problem_out = NULL;
    if (*cache_out != NULL) {
        tc_cache_close(*cache_out);
        *cache_out = NULL;
    }

    cache = (tc_cache *)calloc(1, sizeof(*cache));
    if (cache == NULL) {
        *problem_out = "connect failed -- MemoryError: out of memory";
        return TC_EXIT_OK;      /* still a valid (unusable) handle contract */
    }
    cache_fingerprint_build(cache);

    if (path == NULL || path[0] == '\0') {
        /* no default location / --no-cache: disabled, not a fault */
        *cache_out = cache;
        return TC_EXIT_OK;
    }
    tc_copy_str_cap(cache->path, path, sizeof(cache->path));

    /* existed = os.path.exists(path) BEFORE connect (Python _connect). */
    {
        struct stat st;
        existed = (stat(path, &st) == 0);
    }

    /* mkdir -p dirname(path); OSError names the "connect" step. */
    if (cache_mkdir_parent(path) != 0) {
        snprintf(cache->problem_buf, sizeof(cache->problem_buf),
                 "connect failed -- OSError: %s", strerror(errno));
        cache->problem = cache->problem_buf;
        *cache_out = cache;
        return TC_EXIT_OK;
    }

    /* ---- step "connect": open + WAL + schema ---- */
    rc = sqlite3_open_v2(path, &cache->db,
                         SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, NULL);
    if (rc != SQLITE_OK) {
        cache_fail_step(cache, "connect", rc);
        *cache_out = cache;
        return TC_EXIT_OK;
    }
    if (cache_exec(cache, "PRAGMA journal_mode=WAL") != SQLITE_OK
        || cache_exec(cache, "BEGIN") != SQLITE_OK
        || cache_exec(cache, s_schema) != SQLITE_OK) {
        cache_fail_step(cache, "connect", SQLITE_ERROR);
        *cache_out = cache;
        return TC_EXIT_OK;
    }

    /* ---- step "migrate" ---- */
    {
        int need_migrate = 1;
        rc = sqlite3_prepare_v2(cache->db, s_sel_schema, -1, &stmt, NULL);
        if (rc != SQLITE_OK) {
            cache_fail_step(cache, "migrate", rc);
            *cache_out = cache;
            return TC_EXIT_OK;
        }
        if (cache_step(stmt) == SQLITE_ROW) {
            /* column_text is owned by the statement: compare BEFORE the
               finalize below frees the row memory */
            const char *stored = (const char *)sqlite3_column_text(stmt, 0);
            if (stored != NULL
                && strcmp(stored, CACHE_SCHEMA_VERSION) == 0) {
                need_migrate = 0;
            }
        }
        sqlite3_finalize(stmt);
        if (need_migrate) {
            if (cache_exec(cache, s_drop_tables) != SQLITE_OK
                || cache_exec(cache, s_schema) != SQLITE_OK
                || sqlite3_prepare_v2(cache->db, s_set_schema, -1, &stmt,
                                      NULL) != SQLITE_OK) {
                cache_fail_step(cache, "migrate", SQLITE_ERROR);
                *cache_out = cache;
                return TC_EXIT_OK;
            }
            sqlite3_bind_text(stmt, 1, CACHE_SCHEMA_VERSION, -1,
                              SQLITE_STATIC);
            sqlite3_step(stmt);
            sqlite3_finalize(stmt);
            cache->rebuilt_reason = existed ? "new cache layout"
                                            : "new cache";
        }
    }

    /* ---- step "register": known set read BEFORE the upsert (Python) ---- */
    rc = sqlite3_prepare_v2(cache->db, s_sel_gen, -1, &stmt, NULL);
    if (rc != SQLITE_OK) {
        cache_fail_step(cache, "register", rc);
        *cache_out = cache;
        return TC_EXIT_OK;
    }
    while (cache_step(stmt) == SQLITE_ROW) {
        const char *row = (const char *)sqlite3_column_text(stmt, 0);
        known = 1;
        if (row != NULL && strcmp(row, cache->fingerprint) == 0) {
            present = 1;
        }
    }
    sqlite3_finalize(stmt);

    now = (int64_t)time(NULL);
    cache_fmt_iso(iso, now);
    {
        cache_bindings b;
        memset(&b, 0, sizeof(b));
        b.texts[0] = cache->fingerprint;
        b.texts[1] = iso;
        b.text_mask = 3;        /* both slots text */
        b.n = 2;
        if (!cache_prepare_bind(cache, s_ins_gen, &b, &stmt)) {
            cache_fail_step(cache, "register", SQLITE_ERROR);
            *cache_out = cache;
            return TC_EXIT_OK;
        }
        cache_step(stmt);
        sqlite3_finalize(stmt);
    }
    if (known && !present && cache->rebuilt_reason == NULL) {
        cache->rebuilt_reason = "new parser generation";
    }

    /* ---- step "sweep": drop generations unseen for CACHE_KEEP_DAYS ---- */
    cache_fmt_iso(iso, now - CACHE_KEEP_DAYS * TC_SECS_PER_DAY);
    {
        cache_bindings b;
        memset(&b, 0, sizeof(b));
        b.texts[0] = iso;
        b.text_mask = 1;
        b.n = 1;
        if (!cache_prepare_bind(cache, s_sel_stale, &b, &stmt)) {
            cache_fail_step(cache, "sweep", SQLITE_ERROR);
            *cache_out = cache;
            return TC_EXIT_OK;
        }
    }
    while (cache_step(stmt) == SQLITE_ROW) {
        const char *old = (const char *)sqlite3_column_text(stmt, 0);
        sqlite3_stmt *dstmt;
        cache_bindings d;

        if (old == NULL) {
            continue;
        }
        memset(&d, 0, sizeof(d));
        d.texts[0] = old;
        d.text_mask = 1;
        d.n = 1;
        if (!cache_prepare_bind(cache, s_del_counts_fp, &d, &dstmt)) {
            cache_fail_step(cache, "sweep", SQLITE_ERROR);
            *cache_out = cache;
            return TC_EXIT_OK;
        }
        cache_step(dstmt);
        sqlite3_finalize(dstmt);
        if (!cache_prepare_bind(cache, s_del_file_fp, &d, &dstmt)) {
            cache_fail_step(cache, "sweep", SQLITE_ERROR);
            *cache_out = cache;
            return TC_EXIT_OK;
        }
        cache_step(dstmt);
        sqlite3_finalize(dstmt);
        if (!cache_prepare_bind(cache, s_del_gen_fp, &d, &dstmt)) {
            cache_fail_step(cache, "sweep", SQLITE_ERROR);
            *cache_out = cache;
            return TC_EXIT_OK;
        }
        cache_step(dstmt);
        sqlite3_finalize(dstmt);
        cache->swept++;
    }
    sqlite3_finalize(stmt);

    /* ---- step "rebuild" (only with --rebuild-cache) ---- */
    if (rebuild) {
        if (channel == NULL) {
            /* Python _purge with channel=None discards every channel */
            if (cache_exec(cache, s_del_all_counts) != SQLITE_OK
                || cache_exec(cache, s_del_all_file) != SQLITE_OK) {
                cache_fail_step(cache, "rebuild", SQLITE_ERROR);
                *cache_out = cache;
                return TC_EXIT_OK;
            }
        } else {
            cache_bindings b;
            memset(&b, 0, sizeof(b));
            b.texts[0] = channel;
            b.text_mask = 1;
            b.n = 1;
            if (!cache_prepare_bind(cache, s_del_counts_chan, &b, &stmt)) {
                cache_fail_step(cache, "rebuild", SQLITE_ERROR);
                *cache_out = cache;
                return TC_EXIT_OK;
            }
            cache_step(stmt);
            sqlite3_finalize(stmt);
            if (!cache_prepare_bind(cache, s_del_file_chan, &b, &stmt)) {
                cache_fail_step(cache, "rebuild", SQLITE_ERROR);
                *cache_out = cache;
                return TC_EXIT_OK;
            }
            cache_step(stmt);
            sqlite3_finalize(stmt);
        }
        cache->rebuilt_reason = "--rebuild-cache";
    }

    /* ---- commit (names the active step on failure, like the asm) ---- */
    if (cache_exec(cache, "COMMIT") != SQLITE_OK) {
        cache_fail_step(cache, rebuild ? "rebuild" : "sweep", SQLITE_ERROR);
        *cache_out = cache;
        return TC_EXIT_OK;
    }

    *cache_out = cache;
    return TC_EXIT_OK;
}

// ----------------------------------------------------------------------------
// tc_cache_close — release the connection and the handle.
// ============================================================================
void tc_cache_close(tc_cache *cache) {
    if (cache == NULL) {
        return;
    }
    cache_drop_stash(cache);
    if (cache->db != NULL) {
        sqlite3_close(cache->db);
        cache->db = NULL;
    }
    free(cache);
}

// ----------------------------------------------------------------------------
// tc_cache_used — 1 when the cache is usable (db open and healthy).
// ============================================================================
int tc_cache_used(const tc_cache *cache) {
    if (cache == NULL) {
        return 0;
    }
    return cache->db != NULL;
}

// ----------------------------------------------------------------------------
// tc_cache_status — the report header's cache row.
// ============================================================================
void tc_cache_status(const tc_cache *cache, int64_t *reused, int64_t *parsed,
                     const char **problem, const char **path) {
    if (cache == NULL) {
        *reused = 0;
        *parsed = 0;
        *problem = NULL;
        *path = NULL;
        return;
    }
    *reused = cache->reused;
    *parsed = cache->parsed;
    *problem = cache->problem;
    *path = cache->path[0] != '\0' ? cache->path : NULL;
}

// ----------------------------------------------------------------------------
// tc_cache_rebuilt_reason — the rebuilt-reason accessor (the report header's
//   "rebuilt:" row and the test driver's cachestatus line).  NOT part of the
//   tc_platform.h contract: the C tc_cache_status has no slot for it (the asm
//   returns it in x4), so this helper is exported here and callers declare it
//   locally.
// ============================================================================
const char *tc_cache_rebuilt_reason(const tc_cache *cache) {
    if (cache == NULL) {
        return NULL;
    }
    return cache->rebuilt_reason;
}

// ----------------------------------------------------------------------------
// tc_cache_day — the rollup hook: 0 miss (caller parses), 1 served (the
//   cached counts are applied to tally->users and tally->states), 2 bad
//   (defensive: the caller should parse without writing back).
//
//   The caller decides whole-day (the C contract hands it the window) and
//   pre-stats the file, so this function only ever answers for a whole-day
//   file.  The caller recovers the cached exit state with tc_cache_exit_state.
// ============================================================================
int tc_cache_day(tc_cache *cache, const char *channel, int64_t ymd,
                 const char *fpath, int64_t size, int64_t mtime_ns,
                 int enter_state, tc_tally *tally) {
    sqlite3_stmt *stmt;
    cache_bindings b;
    char date[16];
    int cached_enter;

    (void)fpath;

    if (cache == NULL || cache->db == NULL || tally == NULL
        || tally->users == NULL) {
        return 0;               /* unusable / nothing to fill: a miss */
    }
    cache_drop_stash(cache);

    cache_fmt_date(date, ymd);
    memset(&b, 0, sizeof(b));
    b.texts[0] = cache->fingerprint;
    b.texts[1] = channel;
    b.texts[2] = date;
    b.text_mask = 7;            /* slots 0..2 text */
    b.n = 3;
    if (!cache_prepare_bind(cache, s_sel_file, &b, &stmt)) {
        return 0;               /* sqlite error is a miss, never a failure */
    }
    if (cache_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        /* no row: stash the stat + a table snapshot so a later put writes
           this day (the caller only asks for whole days) */
        cache->stash_valid = 1;
        cache->stash_ymd = ymd;
        cache->stash_size = size;
        cache->stash_mtime_ns = mtime_ns;
        cache->stash_enter = enter_state;
        if (!cache_snapshot_users(cache, tally->users)) {
            cache_drop_stash(cache);
        }
        return 0;
    }
    /* row present: cache_row_valid — size + mtime_ns + enter_state */
    if (sqlite3_column_int64(stmt, 1) != size
        || sqlite3_column_int64(stmt, 2) != mtime_ns) {
        sqlite3_finalize(stmt);
        cache->stash_valid = 1;
        cache->stash_ymd = ymd;
        cache->stash_size = size;
        cache->stash_mtime_ns = mtime_ns;
        cache->stash_enter = enter_state;
        if (!cache_snapshot_users(cache, tally->users)) {
            cache_drop_stash(cache);
        }
        return 0;
    }
    cached_enter = cache_state_id(
        (const char *)sqlite3_column_text(stmt, 3));
    sqlite3_finalize(stmt);
    if (cached_enter != enter_state) {
        /* entering state changed -> the day may be classified differently */
        cache->stash_valid = 1;
        cache->stash_ymd = ymd;
        cache->stash_size = size;
        cache->stash_mtime_ns = mtime_ns;
        cache->stash_enter = enter_state;
        if (!cache_snapshot_users(cache, tally->users)) {
            cache_drop_stash(cache);
        }
        return 0;
    }

    /* hit: apply every counts row (login, state, n) into the tally */
    if (!cache_prepare_bind(cache, s_sel_counts, &b, &stmt)) {
        return 0;
    }
    while (cache_step(stmt) == SQLITE_ROW) {
        const char *login = (const char *)sqlite3_column_text(stmt, 0);
        const char *state = (const char *)sqlite3_column_text(stmt, 1);
        int64_t n = sqlite3_column_int64(stmt, 2);
        if (login != NULL) {
            cache_apply_row(tally->users, tally->states, login,
                            cache_state_id(state), n);
        }
    }
    sqlite3_finalize(stmt);
    cache->reused++;
    return 1;
}

/* One INSERT INTO counts row (defined after tc_cache_put_day). */
static int cache_put_one_count(tc_cache *cache, const char *channel,
                               const char *date, const char *login,
                               const char *state, int64_t n);

// ----------------------------------------------------------------------------
// tc_cache_put_day — report a successfully parsed file back to the cache and,
//   for a whole-day miss the cache stashed, write the day's rollup rows.
//
//   The day's own counts are the user table's delta since the snapshot (the
//   table only grows, so the delta is exactly this file's contribution).
//   parsed is incremented for every reported parse -- even when the db is
//   unusable -- so tc_cache_status stays accurate for a degraded run.
// ============================================================================
void tc_cache_put_day(tc_cache *cache, const char *channel, int64_t ymd,
                      const char *fpath, int64_t size, int64_t mtime_ns,
                      int enter_state, int exit_state, const tc_tally *tally) {
    cache_bindings b;
    sqlite3_stmt *stmt;
    char date[16];
    int64_t i;

    (void)fpath;
    (void)size;
    (void)mtime_ns;
    (void)enter_state;

    if (cache == NULL) {
        return;
    }
    cache->parsed++;

    if (cache->db == NULL || !cache->stash_valid || tally == NULL
        || tally->users == NULL) {
        cache_drop_stash(cache);
        return;
    }
    if (cache->stash_ymd != ymd) {
        cache_drop_stash(cache);    /* defensive: never write a wrong day */
        return;
    }

    cache_fmt_date(date, ymd);

    /* The put owns the whole day: DELETE + INSERTs + file row are one
       transaction, so a mid-put failure can never leave a file row pointing
       at partial counts (Python's single commit). */
    if (cache_exec(cache, "BEGIN") != SQLITE_OK) {
        cache_drop_stash(cache);
        return;
    }

    /* DELETE the day's old counts */
    memset(&b, 0, sizeof(b));
    b.texts[0] = cache->fingerprint;
    b.texts[1] = channel;
    b.texts[2] = date;
    b.text_mask = 7;
    b.n = 3;
    if (!cache_prepare_bind(cache, s_del_day_counts, &b, &stmt)) {
        goto put_rollback;
    }
    cache_step(stmt);
    sqlite3_finalize(stmt);

    /* INSERT the delta rows (login, state, n) for every grown bucket */
    for (i = 0; i < tally->users->count; i++) {
        const tc_user_entry *e = &tally->users->entries[i];
        int64_t old_live = 0, old_offline = 0, old_unknown = 0;
        int64_t dl, doff, du;

        if (i < cache->stash_snap_n) {
            old_live = cache->stash_snap[i].live;
            old_offline = cache->stash_snap[i].offline;
            old_unknown = cache->stash_snap[i].unknown;
        }
        dl = e->live - old_live;
        doff = e->offline - old_offline;
        du = e->unknown - old_unknown;
        if (dl > 0 && !cache_put_one_count(cache, channel, date, e->login,
                                           "live", dl)) {
            goto put_rollback;
        }
        if (doff > 0 && !cache_put_one_count(cache, channel, date, e->login,
                                             "offline", doff)) {
            goto put_rollback;
        }
        if (du > 0 && !cache_put_one_count(cache, channel, date, e->login,
                                           "unknown", du)) {
            goto put_rollback;
        }
    }

    /* INSERT OR REPLACE the file row (mixed text/int/NULL slots, bound by
       hand because the generic helper binds one type per slot) */
    {
        sqlite3_stmt *fstmt;
        if (sqlite3_prepare_v2(cache->db, s_ins_file, -1, &fstmt, NULL)
            != SQLITE_OK) {
            goto put_rollback;
        }
        sqlite3_bind_text(fstmt, 1, cache->fingerprint, -1, SQLITE_STATIC);
        sqlite3_bind_text(fstmt, 2, channel, -1, SQLITE_STATIC);
        sqlite3_bind_text(fstmt, 3, date, -1, SQLITE_STATIC);
        sqlite3_bind_int64(fstmt, 4, cache->stash_size);
        sqlite3_bind_int64(fstmt, 5, cache->stash_mtime_ns);
        if (cache->stash_enter != TC_ST_NONE) {
            sqlite3_bind_text(fstmt, 6, cache_state_str(cache->stash_enter),
                              -1, SQLITE_STATIC);
        } else {
            sqlite3_bind_null(fstmt, 6);
        }
        if (exit_state != TC_ST_NONE) {
            sqlite3_bind_text(fstmt, 7, cache_state_str(exit_state), -1,
                              SQLITE_STATIC);
        } else {
            sqlite3_bind_null(fstmt, 7);
        }
        if (cache_step(fstmt) != SQLITE_DONE) {
            sqlite3_finalize(fstmt);
            goto put_rollback;
        }
        sqlite3_finalize(fstmt);
    }

    if (cache_exec(cache, "COMMIT") != SQLITE_OK) {
        goto put_rollback;
    }
    cache_drop_stash(cache);
    return;

put_rollback:
    cache_exec(cache, "ROLLBACK");
    cache_drop_stash(cache);
}

/* One INSERT INTO counts row.  Returns 1 ok, 0 on any prepare/bind error. */
static int cache_put_one_count(tc_cache *cache, const char *channel,
                               const char *date, const char *login,
                               const char *state, int64_t n) {
    sqlite3_stmt *stmt;
    cache_bindings b;
    int rc;

    memset(&b, 0, sizeof(b));
    b.texts[0] = cache->fingerprint;
    b.texts[1] = channel;
    b.texts[2] = date;
    b.texts[3] = login;
    b.texts[4] = state;
    b.text_mask = 0x1F;         /* slots 0..4 text */
    b.n = 6;
    b.ints[5] = n;
    if (!cache_prepare_bind(cache, s_ins_count, &b, &stmt)) {
        return 0;
    }
    rc = cache_step(stmt);
    sqlite3_finalize(stmt);
    return rc == SQLITE_DONE;
}

// ----------------------------------------------------------------------------
// tc_cache_discard_day — drop a pending stash (unreadable / partial reads
//   never write rollup rows; no parsed count).
// ============================================================================
void tc_cache_discard_day(tc_cache *cache) {
    if (cache == NULL) {
        return;
    }
    cache_drop_stash(cache);
}

// ----------------------------------------------------------------------------
// tc_cache_exit_state — the state a cached day ended in, or 0 when it cannot
//   be answered (Python Cache.exit_state).  The entering state is deliberately
//   NOT compared: the state a day ended in does not depend on how it began.
//
//   Returns TC_ST_LIVE/OFFLINE/UNKNOWN (1/2/3) for a valid row, else 0.
//   Callers treat a cached "unknown" as "proves nothing" (the Python comment).
// ============================================================================
int tc_cache_exit_state(tc_cache *cache, const char *channel, int64_t ymd,
                        const char *fpath, int64_t size, int64_t mtime_ns) {
    sqlite3_stmt *stmt;
    cache_bindings b;
    char date[16];
    int exit_state;

    (void)fpath;

    if (cache == NULL || cache->db == NULL || channel == NULL) {
        return 0;
    }
    cache_fmt_date(date, ymd);
    memset(&b, 0, sizeof(b));
    b.texts[0] = cache->fingerprint;
    b.texts[1] = channel;
    b.texts[2] = date;
    b.text_mask = 7;
    b.n = 3;
    if (!cache_prepare_bind(cache, s_sel_file, &b, &stmt)) {
        return 0;
    }
    if (cache_step(stmt) != SQLITE_ROW) {
        sqlite3_finalize(stmt);
        return 0;
    }
    if (sqlite3_column_int64(stmt, 1) != size
        || sqlite3_column_int64(stmt, 2) != mtime_ns) {
        sqlite3_finalize(stmt);
        return 0;
    }
    exit_state = cache_state_id(
        (const char *)sqlite3_column_text(stmt, 4));
    sqlite3_finalize(stmt);
    return exit_state;
}

// ----------------------------------------------------------------------------
// tc_cache_debug_dump — test-only schema/row dump (the tc-cache-test driver
//   prints this so the harness can assert on the database without a sqlite3
//   CLI).  Format mirrors the asm port exactly.
// ============================================================================
static void cache_dump_col_text(sqlite3_stmt *stmt, int idx) {
    const char *s = (const char *)sqlite3_column_text(stmt, idx);
    if (s != NULL) {
        tc_puts(s);
    }
    tc_puts(" ");
}

static void cache_dump_col_text_dash(sqlite3_stmt *stmt, int idx) {
    const char *s = (const char *)sqlite3_column_text(stmt, idx);
    if (s != NULL) {
        tc_puts(s);
    } else {
        tc_puts("-");
    }
}

static void cache_dump_col_i64(sqlite3_stmt *stmt, int idx) {
    tc_putu64((uint64_t)sqlite3_column_int64(stmt, idx));
    tc_puts(" ");
}

static void cache_dump_count(const tc_cache *cache, const char *sql,
                             const char *label) {
    sqlite3_stmt *stmt;
    if (sqlite3_prepare_v2(cache->db, sql, -1, &stmt, NULL) != SQLITE_OK) {
        return;
    }
    tc_puts(label);
    if (cache_step(stmt) == SQLITE_ROW) {
        tc_putu64((uint64_t)sqlite3_column_int64(stmt, 0));
    }
    sqlite3_finalize(stmt);
}

void tc_cache_debug_dump(const tc_cache *cache) {
    sqlite3_stmt *stmt;

    if (cache == NULL || cache->db == NULL) {
        return;
    }
    /* ---- table names ---- */
    tc_puts("cachetables ");
    if (sqlite3_prepare_v2(cache->db, s_master, -1, &stmt, NULL)
        == SQLITE_OK) {
        while (cache_step(stmt) == SQLITE_ROW) {
            cache_dump_col_text(stmt, 0);
        }
        sqlite3_finalize(stmt);
    }
    tc_puts("\n");

    /* ---- row counts ---- */
    tc_puts("cachecounts ");
    cache_dump_count(cache, s_count_meta, "meta=");
    cache_dump_count(cache, s_count_generation, " generation=");
    cache_dump_count(cache, s_count_file, " file=");
    cache_dump_count(cache, s_count_counts, " counts=");
    tc_puts("\n");

    /* ---- file rows ---- */
    if (sqlite3_prepare_v2(cache->db, s_all_file, -1, &stmt, NULL)
        != SQLITE_OK) {
        return;
    }
    while (cache_step(stmt) == SQLITE_ROW) {
        tc_puts("cachefile ");
        cache_dump_col_text(stmt, 0);
        cache_dump_col_text(stmt, 1);
        cache_dump_col_text(stmt, 2);
        cache_dump_col_i64(stmt, 3);
        cache_dump_col_i64(stmt, 4);
        cache_dump_col_text_dash(stmt, 5);
        tc_puts(" ");
        cache_dump_col_text_dash(stmt, 6);
        tc_puts("\n");
    }
    sqlite3_finalize(stmt);

    /* ---- counts rows ---- */
    if (sqlite3_prepare_v2(cache->db, s_all_counts, -1, &stmt, NULL)
        != SQLITE_OK) {
        return;
    }
    while (cache_step(stmt) == SQLITE_ROW) {
        tc_puts("cachecount ");
        cache_dump_col_text(stmt, 0);
        cache_dump_col_text(stmt, 1);
        cache_dump_col_text(stmt, 2);
        cache_dump_col_text(stmt, 3);
        cache_dump_col_text(stmt, 4);
        tc_putu64((uint64_t)sqlite3_column_int64(stmt, 5));
        tc_puts("\n");
    }
    sqlite3_finalize(stmt);
}