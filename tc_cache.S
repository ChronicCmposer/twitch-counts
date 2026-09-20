// ============================================================================
// tc_cache.S — the SQLite rollup cache for twitch-counts
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//  Linking:    the Makefile links every driver and the binary; this module
//              needs the vendored sqlite3.o.
//
//  What this module owns (the shared contract is tc_layout.inc)
//  ----------------------------------------------------------------------
//    * the day-level rollup cache: a SQLite database holding per-day,
//      per-login, per-state message counts plus the file identity that made
//      them valid (Python reference: the Cache class, count_messages cache
//      interplay, cache_row_valid, CACHE_SCHEMA / CACHE_SCHEMA_VERSION=2 /
//      CACHE_KEEP_DAYS=7).
//    * the cache path: XDG default $XDG_CACHE_HOME/twitch-counts/rollup.db
//      (or $HOME/.cache/twitch-counts/rollup.db).  No HOME -> no default ->
//      cache disabled, NOT an error (the Python leaves a literal "~/.cache"
//      path in that case; this port treats it as "no default location").
//    * open/close lifecycle for one-shot runs; the watch loop (tc_watch.S)
//      opens once and keeps the connection for the session.
//
//  Exported (all .global, AAPCS64; x19-x28 preserved by every helper)
//  ----------------------------------------------------------------
//    tc_cache_open()            session open: resolve path, connect, migrate,
//                               register, sweep, purge (--rebuild-cache).
//                               Never fails the process: on any problem the
//                               cache is left unused with a step-named reason
//                               ("<step> failed -- <Type>: <detail>") and the
//                               run parses every file instead.
//    tc_cache_close()           close the connection (one-shot owner).
//    tc_cache_used()  -> x0 = 0/1
//    tc_cache_status() -> (x0=used 0/1, x1=reused u64, x2=parsed u64,
//                               x3=problem_ptr|0, x4=rebuilt_reason_ptr|0,
//                               x5=path_ptr|0)
//        reused/parsed are read from tc_tally (TC_T_REUSED / TC_T_PARSED) so
//        the header row and the tally always agree.  tc_render.S's header row
//        consumes this.
//    tc_cache_day(x0=fpath, x1=lo, x2=hi, x3=enter_state, x4=ymd)
//        -> x0 = 0 parse normally, 1 reused (x1 = cached exit_state), 2 stat
//        failed.  Called once per in-range file by tc_core.S's loop, right
//        after the path is built.  On a whole-day hit it applies the cached
//        (login,state) counts to tc_users + the all-state totals and returns
//        1; on a whole-day miss it stashes the stat + a user-table snapshot
//        so tc_cache_put_day can write the day after parsing; non-whole days
//        and cache-off runs fall through to a normal parse.
//    tc_cache_put_day(x0=exit_state)  after a successful whole-file parse:
//        write the day's counts (the user-table delta since the snapshot) and
//        the file row; no-op without a stash (not cached / not whole-day).
//    tc_cache_discard_day()      drop a pending stash (unreadable / partial
//                                reads never write rollup rows).
//    tc_cache_debug_dump()       test-only: print the schema + rows of the
//                                open database (used by test-tc-cache.sh when
//                                no sqlite3 CLI is present).
//
//  Calling contract with tc_core.S
//  ----------------------------------------------------
//    core_count_final's loop calls tc_cache_day(fpath, lo, hi, enter_state, ymd)
//    before reading the file.  enter_state is the live/offline/unknown state
//    in force entering the day (core_cur_state); ymd is the entry's date.
//    The cache module never touches core_cur_state: the core stores the
//    returned exit_state itself.  It DOES write tc_users (tc_find_user/tc_add_user
//    and the all-state totals are exported by tc_core.S for this) and reads
//    the tally (TC_T_REUSED is incremented by the CORE when result == 1; the
//    cache module only applies counts).
//
//  Schema (exact SQL from the Python CACHE_SCHEMA)
//  ----------------------------------------------
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
//  Migration (Python Cache._migrate): when the stored meta schema value is
//    not "2", the file/counts/generation tables are dropped and recreated and
//    meta.schema is set to "2".  Reason: "new cache" (db did not exist) or
//    "new cache layout" (it did).  The generation table records each parser
//    fingerprint seen; registering a fingerprint that is not among the
//    already-known ones yields "new parser generation" (only when at least
//    one generation was already known).  Generations unseen for
//    CACHE_KEEP_DAYS (7) are swept at open (their file/counts/generation rows
//    are deleted).  --rebuild-cache purges the channel across every
//    generation and sets the reason to "--rebuild-cache" (the Python's purge
//    then the normal pass repopulates it).
//
//  Fingerprint (documented deviation from the Python)
//  -------------------------------------------------
//    Python hashes the AST of its own parsing sources (cache_fingerprint);
//    that exact value cannot be reproduced in a different implementation.
//    This port uses its own stable tag: FNV-1a 64-bit over a fixed list of
//    constants that capture what the counting logic depends on (the marker
//    literals, the login/localized rules, the message format, the state set,
//    the whole-day rule and a manual version constant).  The tag changes when
//    the parsing logic changes (bump TC_CACHE_FP_VERSION) and is stable
//    across runs.  CACHE_INPUTS-style automatic invalidation (hashing the
//    source) is NOT replicated: an edit to tc_core.S's parsing must be
//    accompanied by bumping the version constant.  Tagged generations still
//    coexist in one database exactly like the Python's.
//
//  Put semantics (documented deviation from the Python)
//  ---------------------------------------------------
//    The Python writes a whole-day row for ANY successfully cold-read file,
//    whole-day in the window or not (reader.day() covers the whole file).
//    This port writes rollup rows ONLY for whole-day files (the window covers
//    the day 00:00:00..23:59:59): a window-partial day's row would otherwise
//    store window counts, corrupting any later whole-day reuse.  "Unreadable
//    / partial days are never written" (spec).  Counts are identical either
//    way; only the cached/reused counters differ in the window-partial case
//    (the Python reuses the day later, this port re-parses it).
//
//  Failure handling
//  ----------------
//    A cache is an optimization and must never fail a query.  Every open step
//    is named ("connect","migrate","register","sweep","rebuild") and a
//    failure composes "<step> failed -- <Type>: <detail>" and leaves the
//    cache unused; the run then parses everything.  get/put failures are
//    per-call: get treats them as a miss, put drops the stash.  The exception
//    type names approximate CPython's sqlite3 module (OperationalError /
//    DatabaseError / MemoryError from a small errcode map; OSError for
//    errno-based failures); the differential normalizes this text.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
#include "tc_parse_facts.inc"
    .text

// ----------------------------------------------------------------------------
// musl / sqlite3 / shared-module externals
// ----------------------------------------------------------------------------
    .globl sqlite3_open_v2
    .globl sqlite3_close
    .globl sqlite3_exec
    .globl sqlite3_prepare_v2
    .globl sqlite3_step
    .globl sqlite3_bind_text
    .globl sqlite3_bind_int64
    .globl sqlite3_bind_null
    .globl sqlite3_column_text
    .globl sqlite3_column_int64
    .globl sqlite3_finalize
    .globl sqlite3_reset
    .globl sqlite3_errmsg
    .globl sqlite3_errcode
    .globl malloc
    .globl free
    .globl getenv
    .globl tc_expanduser
    .globl mkdir
    .globl stat
    .globl time
    .globl localtime_r
    .globl strerror
    .globl __errno_location
    .globl strcmp
    .globl tc_strlen
    .globl tc_channel_name
    .globl tc_resolve_channel
    .globl tc_reuse_apply
    .globl tc_puts
    .globl tc_eputs
    .globl tc_putu64
    .globl tc_opts
    .globl tc_tally
    .globl tc_users
    .globl tc_cat_cstr
    .globl tc_entry_ptr
    .globl tc_state_str
    .globl tc_str_live
    .globl tc_str_offline
    .globl tc_str_unknown

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ SQLITE_OK,            0
    .equ SQLITE_ERROR,         1
    .equ SQLITE_NOMEM,         7
    .equ SQLITE_CORRUPT,       11
    .equ SQLITE_NOTADB,        26
    .equ SQLITE_ROW,           100
    .equ SQLITE_DONE,          101
    .equ SQLITE_STATIC,        0
    .equ SQLITE_OPEN_READWRITE, 0x00000002
    .equ SQLITE_OPEN_CREATE,    0x00000004
    .equ SQLITE_OPEN_FULLMUTEX, 0x00010000
    .equ OPEN_FLAGS,           (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
    .equ CACHE_KEEP_DAYS,      7
    // STAT_SZ / ST_SIZE / ST_MTIM_SEC / ST_MTIM_NSEC come from tc_platform.h
    // (per-platform struct stat offsets); see the LOAD_ST_MODE/LOAD_ST_DEV
    // notes there for the fields that also differ in width.
    .equ PATH_SZ,              640
    .equ SCRATCH_SZ,           512
    .equ FP_SZ,                17       // 16 hex chars + NUL
    .equ PROB_BUF_SZ,          256
    .equ FNV_OFFSET,           0xcbf29ce484222325
    .equ FNV_PRIME,            0x100000001b3

// ----------------------------------------------------------------------------
// .bss — private state (not part of the shared contract)
// ----------------------------------------------------------------------------
    .bss
    .p2align 4
cache_db:        .skip 8          // sqlite3* (0 = not open)
cache_path:      .skip PATH_SZ    // resolved db path ("" = none)
cache_path_ptr:  .skip 8
cache_channel:   .skip 8          // tc_channel_name() pointer (stashed)
cache_fp:        .skip FP_SZ      // fingerprint hex + NUL
cache_reason:    .skip 8          // rebuilt_reason ptr (0 = none)
cache_problem:   .skip 8          // problem ptr (0 = none)
cache_problem_buf: .skip PROB_BUF_SZ
cache_swept:     .skip 8
cache_hits:      .skip 8
cache_stat:      .skip STAT_SZ    // last stat of the current day
cache_epoch:     .skip 8          // time_t slot for localtime_r
cache_tm:        .skip 64         // struct tm
cache_stash:     .skip 8          // 0/1 a whole-day miss is pending
cache_stash_ymd: .skip 8
cache_stash_size:  .skip 8
cache_stash_mtime: .skip 8
cache_stash_enter: .skip 8
cache_snap:      .skip 8          // malloc'd user-table snapshot (0 none)
cache_snap_n:    .skip 8          // users captured in the snapshot
cache_scratch:   .skip SCRATCH_SZ // date / iso formatting
cache_scratch2:  .skip SCRATCH_SZ // mkdir path scratch

// ----------------------------------------------------------------------------
// .rodata — SQL and message literals
// ----------------------------------------------------------------------------
    RODATA
s_step_connect:     .asciz "connect"
s_step_migrate:     .asciz "migrate"
s_step_register:    .asciz "register"
s_step_sweep:       .asciz "sweep"
s_step_rebuild:     .asciz "rebuild"
s_failed:           .asciz " failed -- "
s_colon_space:      .asciz ": "
s_type_operr:       .asciz "OperationalError"
s_type_dberr:       .asciz "DatabaseError"
s_type_memerr:      .asciz "MemoryError"
s_reason_new_cache: .asciz "new cache"
s_reason_new_layout:.asciz "new cache layout"
s_reason_new_gen:   .asciz "new parser generation"
s_reason_rebuild:   .asciz "--rebuild-cache"
s_env_xdg_cache:    .asciz "XDG_CACHE_HOME"
s_env_home:         .asciz "HOME"
s_home_cache_tail:  .asciz "/.cache"
s_cache_default:    .asciz "~/.cache/twitch-counts/rollup.db"
s_path_tail:        .asciz "/twitch-counts/rollup.db"
s_sep:              .asciz "\n"
s_schema_version:   .asciz "2"
s_pragma_wal:       .asciz "PRAGMA journal_mode=WAL"
s_begin:            .asciz "BEGIN"
s_commit:           .asciz "COMMIT"
s_rollback:         .asciz "ROLLBACK"
s_sql_meta:         .asciz "CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT)"
s_sql_generation:   .asciz "CREATE TABLE IF NOT EXISTS generation(fingerprint TEXT PRIMARY KEY, last_seen TEXT NOT NULL) WITHOUT ROWID"
s_sql_file:         .asciz "CREATE TABLE IF NOT EXISTS file(fingerprint TEXT NOT NULL, channel TEXT NOT NULL, date TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL, enter_state TEXT, exit_state TEXT, PRIMARY KEY(fingerprint, channel, date)) WITHOUT ROWID"
s_sql_counts:       .asciz "CREATE TABLE IF NOT EXISTS counts(fingerprint TEXT NOT NULL, channel TEXT NOT NULL, date TEXT NOT NULL, login TEXT NOT NULL, state TEXT NOT NULL, n INTEGER NOT NULL, PRIMARY KEY(fingerprint, channel, date, login, state)) WITHOUT ROWID"
s_sql_drop:         .asciz "DROP TABLE IF EXISTS file; DROP TABLE IF EXISTS counts; DROP TABLE IF EXISTS generation;"
s_sql_sel_schema:   .asciz "SELECT value FROM meta WHERE key = 'schema'"
s_sql_set_schema:   .asciz "INSERT OR REPLACE INTO meta VALUES('schema', ?)"
s_sql_sel_gen:      .asciz "SELECT fingerprint FROM generation"
s_sql_ins_gen:      .asciz "INSERT INTO generation VALUES(?, ?) ON CONFLICT(fingerprint) DO UPDATE SET last_seen = excluded.last_seen"
s_sql_sel_stale:    .asciz "SELECT fingerprint FROM generation WHERE last_seen < ?"
s_sql_del_counts_fp: .asciz "DELETE FROM counts WHERE fingerprint = ?"
s_sql_del_file_fp:   .asciz "DELETE FROM file WHERE fingerprint = ?"
s_sql_del_gen_fp:    .asciz "DELETE FROM generation WHERE fingerprint = ?"
s_sql_del_counts_chan: .asciz "DELETE FROM counts WHERE channel = ?"
s_sql_del_file_chan:   .asciz "DELETE FROM file WHERE channel = ?"
s_sql_sel_file:     .asciz "SELECT fingerprint, size, mtime_ns, enter_state, exit_state FROM file WHERE fingerprint = ? AND channel = ? AND date = ?"
s_sql_sel_counts:   .asciz "SELECT login, state, n FROM counts WHERE fingerprint = ? AND channel = ? AND date = ?"
s_sql_del_day_counts: .asciz "DELETE FROM counts WHERE fingerprint = ? AND channel = ? AND date = ?"
s_sql_ins_count:    .asciz "INSERT INTO counts VALUES(?, ?, ?, ?, ?, ?)"
s_sql_ins_file:     .asciz "INSERT OR REPLACE INTO file VALUES(?, ?, ?, ?, ?, ?, ?)"
s_sql_master:       .asciz "SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name"
s_sql_count_meta:   .asciz "SELECT COUNT(*) FROM meta"
s_sql_count_generation: .asciz "SELECT COUNT(*) FROM generation"
s_sql_count_file:   .asciz "SELECT COUNT(*) FROM file"
s_sql_count_counts: .asciz "SELECT COUNT(*) FROM counts"
s_sql_all_file:     .asciz "SELECT fingerprint, channel, date, size, mtime_ns, enter_state, exit_state FROM file ORDER BY date"
s_sql_all_counts:   .asciz "SELECT fingerprint, channel, date, login, state, n FROM counts ORDER BY date, login"
s_lbl_meta:         .asciz "meta="
s_lbl_generation:   .asciz " generation="
s_lbl_file:         .asciz " file="
s_lbl_counts:       .asciz " counts="
s_cachetables:      .asciz "cachetables "
s_cachecounts:      .asciz "cachecounts "
s_cachefile:        .asciz "cachefile "
s_cachecount:       .asciz "cachecount "
s_dash:             .asciz "-"
s_newline:          .asciz "\n"
s_space:            .asciz " "

// fingerprint input parts (stable tag; see header).  The marker/login
// literals come from tc_parse_facts.inc: pfx_fp_live / pfx_fp_off /
// pfx_fp_login are the "live="/"off="/"login=" prefixes emitted immediately
// before the shared parser labels, so each part is one contiguous string
// ("live=is live!" etc.) that the parsers reference byte-for-byte.
s_fp_head:   .asciz "tc-cache-fp-v1"
s_fp_schema: .asciz "schema=2"
s_fp_local:  .asciz "localized=\\S+ [a-z0-9_]{1,25} nonascii"
s_fp_fmt:    .asciz "fmt=[HH:MM:SS] who: msg"
s_fp_states: .asciz "states=live,offline,unknown"
s_fp_whole:  .asciz "whole=0..86399"
s_fp_class:  .asciz "class=process_lines+process_message+line_is_marker+speaker_login"
    .p2align 3
s_fp_parts:
    .quad s_fp_head
    .quad s_fp_schema
    .quad pfx_fp_live
    .quad pfx_fp_off
    .quad pfx_fp_login
    .quad s_fp_local
    .quad s_fp_fmt
    .quad s_fp_states
    .quad s_fp_whole
    .quad s_fp_class
    .quad 0

    .text

// ============================================================================
// tc_cache_open — session open (the one-shot owner calls this before counting
//   and tc_cache_close after; watch mode calls it once per session).
// ============================================================================
    .p2align 2
    .global tc_cache_open
    FUNC_TYPE(tc_cache_open)
tc_cache_open:
    PROLOGUE 2
    // ---- reset session state ----
    LEA x9, cache_db
    str xzr, [x9]
    LEA x9, cache_problem
    str xzr, [x9]
    LEA x9, cache_reason
    str xzr, [x9]
    LEA x9, cache_path_ptr
    str xzr, [x9]
    LEA x9, cache_swept
    str xzr, [x9]
    LEA x9, cache_hits
    str xzr, [x9]
    // ---- flags ----
    LEA x9, tc_opts
    ldr x10, [x9, #TC_O_FLAGS]
    tst x10, #TC_F_NO_CACHE
    b.ne .Lco_no_cache
    tst x10, #TC_F_REBUILD_CACHE
    cset x19, ne                    // x19 = rebuild 0/1
    // ---- resolve the channel first ----
    // The channel dir name (core_name) is filled by tc_resolve_channel,
    // which tc_count_run normally calls later.  The cache needs the name at
    // open time (the purge binds it), and tc_channel_name() only returns the
    // pointer, whose CONTENT is empty until resolution.  Resolve now; the
    // re-resolution inside tc_count_run is idempotent.
    bl tc_resolve_channel
    // ---- resolve the cache path ----
    bl cache_resolve_cache_path
    LEA x9, cache_path
    ldrb w10, [x9]
    cbz w10, .Lco_no_path           // no default location; not a fault
    LEA x9, cache_path_ptr
    LEA x10, cache_path
    str x10, [x9]
    // ---- existed = stat(path) == 0 (Python os.path.exists before connect)
    mov x0, x10
    LEA x1, cache_stat
    bl stat
    cmp w0, #0
    cset x20, eq                    // x20 = existed 0/1
    // ---- mkdir -p dirname(path) ----
    LEA x0, cache_path
    bl cache_mkdir_cache_dir
    // ---- channel + fingerprint ----
    bl tc_channel_name
    LEA x9, cache_channel
    str x0, [x9]
    bl cache_fingerprint_build
    // ---- step "connect": open + WAL + begin + schema ----
    LEA x0, cache_path
    LEA x1, cache_db
    ldr x2, =OPEN_FLAGS
    mov x3, #0
    bl sqlite3_open_v2
    cbnz w0, .Lco_fail_connect
    LEA x0, s_pragma_wal
    bl cache_db_exec
    cbnz w0, .Lco_fail_connect
    LEA x0, s_begin
    bl cache_db_exec
    cbnz w0, .Lco_fail_connect
    LEA x0, s_sql_meta
    bl cache_db_exec
    cbnz w0, .Lco_fail_connect
    LEA x0, s_sql_generation
    bl cache_db_exec
    cbnz w0, .Lco_fail_connect
    LEA x0, s_sql_file
    bl cache_db_exec
    cbnz w0, .Lco_fail_connect
    LEA x0, s_sql_counts
    bl cache_db_exec
    cbnz w0, .Lco_fail_connect
    // ---- step "migrate" ----
    mov x0, x20                     // existed
    bl cache_migrate_step                 // x0 = 0 ok (reason in tc_cache_tmp), else failed
    cbnz x0, .Lco_open_done
// ---- step "register" ----
    bl cache_register_step                 // x0 = 0 ok (reason OR'd into tc_cache_tmp)
    cbnz x0, .Lco_open_done
    // move the composed reason (migrate or generation) into place
    LEA x9, cache_tmp_reason
    ldr x10, [x9]
    LEA x9, cache_reason
    str x10, [x9]
    // ---- step "sweep" ----
    bl cache_sweep_step                   // x0 = 0 ok
    cbnz x0, .Lco_open_done
    // ---- step "rebuild" (only with --rebuild-cache) ----
    cbz x19, .Lco_commit
    bl cache_purge_step                   // x0 = 0 ok
    cbnz x0, .Lco_open_done
    LEA x9, cache_reason
    LEA x10, s_reason_rebuild
    str x10, [x9]
.Lco_commit:
    LEA x0, s_commit
    bl cache_db_exec
    cbnz w0, .Lco_fail_commit
.Lco_open_done:
    EPILOGUE 2
    ret
.Lco_no_cache:
    EPILOGUE 2
    ret
.Lco_no_path:
    EPILOGUE 2
    ret
.Lco_fail_connect:
    LEA x0, s_step_connect
    bl cache_fail_sqlite
    b .Lco_open_done
.Lco_fail_commit:
    // Python's commit sits after the sweep (or the rebuild purge); name it
    // whichever step was active.
    cbz x19, .Lco_fail_commit_sweep
    LEA x0, s_step_rebuild
    bl cache_fail_sqlite
    b .Lco_open_done
.Lco_fail_commit_sweep:
    LEA x0, s_step_sweep
    bl cache_fail_sqlite
    b .Lco_open_done

// ============================================================================
// tc_cache_close — close the connection (one-shot owner).
// ============================================================================
    .p2align 2
    .global tc_cache_close
    FUNC_TYPE(tc_cache_close)
tc_cache_close:
    PROLOGUE 0
    LEA x0, cache_db
    ldr x1, [x0]
    cbz x1, .Lcc_done
    str xzr, [x0]
    mov x0, x1
    bl sqlite3_close
.Lcc_done:
    EPILOGUE 0
    ret

// ============================================================================
// tc_cache_used() -> x0 = 0/1
// ============================================================================
    .p2align 2
    .global tc_cache_used
    FUNC_TYPE(tc_cache_used)
tc_cache_used:
    LEA x0, cache_db
    ldr x0, [x0]
    cmp x0, #0
    cset x0, ne
    ret

// ============================================================================
// tc_cache_status() -> (x0=used, x1=reused, x2=parsed, x3=problem_ptr,
//                       x4=rebuilt_reason_ptr, x5=path_ptr)
// ============================================================================
    .p2align 2
    .global tc_cache_status
    FUNC_TYPE(tc_cache_status)
tc_cache_status:
    LEA x9, cache_db
    ldr x0, [x9]
    cmp x0, #0
    cset x0, ne
    LEA x9, tc_tally
    ldr x1, [x9, #TC_T_REUSED]
    ldr x2, [x9, #TC_T_PARSED]
    LEA x9, cache_problem
    ldr x3, [x9]
    LEA x9, cache_reason
    ldr x4, [x9]
    LEA x9, cache_path_ptr
    ldr x5, [x9]
    ret

// ============================================================================
// tc_cache_day(x0=fpath, x1=lo, x2=hi, x3=enter_state, x4=ymd)
//   -> x0 = 0 parse normally, 1 reused (x1 = cached exit_state), 2 stat fail
// ============================================================================
    .p2align 2
    .global tc_cache_day
    FUNC_TYPE(tc_cache_day)
tc_cache_day:
    PROLOGUE 5
    mov x19, x0                     // fpath
    mov x20, x1                     // lo
    mov x21, x2                     // hi
    mov x22, x3                     // enter_state
    mov x23, x4                     // ymd
    // any pending stash from a previous file must already be gone; drop it
    // defensively (put_day/discard_day are no-ops without a stash)
    bl cache_drop_stash
    // cache open?
    LEA x9, cache_db
    ldr x9, [x9]
    cbz x9, .Lcd_nocache
    // stat the file
    mov x0, x19
    LEA x1, cache_stat
    bl stat
    cbnz w0, .Lcd_statfail
    // whole_day? (lo == 0 and hi == 86399)
    cbnz x20, .Lcd_parse
    ldr x9, =LAST_SECOND
    cmp x21, x9
    b.ne .Lcd_parse
    // whole day: try the cache
    mov x0, x23
    mov x1, x22
    bl cache_get_day                 // x0 = 1 hit (x1 = exit), 0 miss
    cmp w0, #1
    b.eq .Lcd_hit
    // miss: stash the stat + enter state and snapshot the user table so the
    // put (after parsing) can write the whole-day counts.
    LEA x9, cache_stash_ymd
    str x23, [x9]
    LEA x9, cache_stash_size
    LEA x10, cache_stat
    ldr x11, [x10, #ST_SIZE]
    str x11, [x9]
    LEA x9, cache_stash_mtime
    ldr x11, [x10, #ST_MTIM_SEC]
    MOV_NANOSEC x12
    mul x11, x11, x12
    ldr x12, [x10, #ST_MTIM_NSEC]
    add x11, x11, x12
    str x11, [x9]
    LEA x9, cache_stash_enter
    str x22, [x9]
    LEA x9, cache_stash
    mov x10, #1
    str x10, [x9]
    bl cache_snapshot_users
    mov x0, #0
    b .Lcd_done
.Lcd_hit:
    mov x0, #1                       // x1 already carries the exit_state
    b .Lcd_done
.Lcd_parse:
    mov x0, #0
    b .Lcd_done
.Lcd_statfail:
    bl tc_capture_errno             // the reason tc_core reports
    mov x0, #2
    b .Lcd_done
.Lcd_nocache:
    mov x0, #0
.Lcd_done:
    EPILOGUE 5
    ret

// ============================================================================
// tc_cache_put_day(x0=exit_state) — write the stashed whole day after a
//   successful whole-file parse.  No-op without a stash.
// ============================================================================
    .p2align 2
    .global tc_cache_put_day
    FUNC_TYPE(tc_cache_put_day)
tc_cache_put_day:
    PROLOGUE 5
    mov x19, x0                     // exit_state
    LEA x9, cache_stash
    ldr x9, [x9]
    cbz x9, .Lcp_done               // nothing stashed
    LEA x9, cache_db
    ldr x9, [x9]
    cbz x9, .Lcp_discard
    LEA x9, cache_snap
    ldr x9, [x9]
    cbz x9, .Lcp_discard
    // ---- date string ----
    LEA x9, cache_stash_ymd
    ldr x0, [x9]
    LEA x1, cache_scratch
    bl cache_fmt_date
    LEA x20, cache_scratch  // date ptr
    // ---- DELETE counts for this (fp, channel, date) ----
    LEA x0, s_sql_del_day_counts
    bl cache_prepare_stmt                 // x0 = stmt or 0
    cbz x0, .Lcp_discard
    mov x21, x0                     // stmt
    LEA x0, cache_fp
    mov x2, x0
    mov x0, x21
    mov x1, #1
    bl cache_bind_text_stmt
    LEA x2, cache_channel
    ldr x2, [x2]
    mov x0, x21
    mov x1, #2
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #3
    mov x2, x20
    bl cache_bind_text_stmt
    mov x0, x21
    bl cache_step_stmt
    mov x0, x21
    bl sqlite3_finalize
    // ---- INSERT counts rows (delta of the user table since the snapshot) ----
    LEA x0, s_sql_ins_count
    bl cache_prepare_stmt
    cbz x0, .Lcp_discard
    mov x21, x0                     // counts stmt
    LEA x22, tc_users
    ldr x23, [x22, #TC_US_COUNT]    // new_n
    ldr x24, [x22, #TC_US_ENTRIES]  // entries
    LEA x25, cache_snap
    ldr x25, [x25]                  // snap value (the malloc'd array)
    LEA x26, cache_snap_n
    ldr x26, [x26]                  // snap_n
    mov x27, #0                     // i
.Lcp_user_loop:
    cmp x27, x23
    b.ge .Lcp_users_done
    // entry pointer (survives the bind calls in x28)
    mov x0, x24
    mov x1, x27
    mov x2, #TC_US_ENTRY_SZ
    bl tc_entry_ptr
    mov x28, x0
    ldr x16, [x28, #TC_US_LIVE]
    ldr x17, [x28, #TC_US_OFFLINE]
    ldr x14, [x28, #TC_US_UNKNOWN]
    // old counts: snapshot when i < snap_n else zero
    mov x9, #24
    mul x9, x27, x9
    mov x10, #0
    mov x11, #0
    mov x12, #0
    cmp x27, x26
    b.ge .Lcp_old_zero
    add x13, x25, x9
    ldr x10, [x13]
    ldr x11, [x13, #8]
    ldr x12, [x13, #16]
.Lcp_old_zero:
    sub x16, x16, x10                // dl (live delta)
    sub x17, x17, x11                // do (offline delta)
    sub x14, x14, x12                // du (unknown delta)
    // park dl/do/du on the stack so the bind calls cannot clobber them
    sub sp, sp, #32
    str x16, [sp]
    str x17, [sp, #8]
    str x14, [sp, #16]
    // bind fingerprint, channel, date, login
    mov x0, x21
    mov x1, #1
    LEA x2, cache_fp
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #2
    LEA x2, cache_channel
    ldr x2, [x2]
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #3
    mov x2, x20
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #4
    mov x2, x28                     // entry login ptr
    bl cache_bind_text_stmt
    // live
    ldr x9, [sp]
    cbz x9, .Lcp_no_live
    mov x0, x21
    mov x1, #5
    LEA x2, tc_str_live
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #6
    ldr x2, [sp]
    bl cache_bind_int64_stmt
    mov x0, x21
    bl cache_step_stmt
    mov x0, x21
    bl sqlite3_reset
.Lcp_no_live:
    // offline
    ldr x9, [sp, #8]
    cbz x9, .Lcp_no_off
    mov x0, x21
    mov x1, #5
    LEA x2, tc_str_offline
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #6
    ldr x2, [sp, #8]
    bl cache_bind_int64_stmt
    mov x0, x21
    bl cache_step_stmt
    mov x0, x21
    bl sqlite3_reset
.Lcp_no_off:
    // unknown
    ldr x9, [sp, #16]
    cbz x9, .Lcp_no_unk
    mov x0, x21
    mov x1, #5
    LEA x2, tc_str_unknown
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #6
    ldr x2, [sp, #16]
    bl cache_bind_int64_stmt
    mov x0, x21
    bl cache_step_stmt
    mov x0, x21
    bl sqlite3_reset
.Lcp_no_unk:
    add sp, sp, #32
    add x27, x27, #1
    b .Lcp_user_loop
.Lcp_users_done:
    mov x0, x21
    bl sqlite3_finalize
    // ---- INSERT OR REPLACE INTO file ----
    LEA x0, s_sql_ins_file
    bl cache_prepare_stmt
    cbz x0, .Lcp_discard
    mov x21, x0
    mov x0, x21
    mov x1, #1
    LEA x2, cache_fp
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #2
    LEA x2, cache_channel
    ldr x2, [x2]
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #3
    mov x2, x20
    bl cache_bind_text_stmt
    mov x0, x21
    mov x1, #4
    LEA x2, cache_stash_size
    ldr x2, [x2]
    bl cache_bind_int64_stmt
    mov x0, x21
    mov x1, #5
    LEA x2, cache_stash_mtime
    ldr x2, [x2]
    bl cache_bind_int64_stmt
    // enter_state (state id -> string; 0 -> NULL)
    LEA x2, cache_stash_enter
    ldr x0, [x2]
    bl cache_state_str
    cbz x0, .Lcp_enter_null
    mov x2, x0
    mov x0, x21
    mov x1, #6
    bl cache_bind_text_stmt
    b .Lcp_enter_done
.Lcp_enter_null:
    mov x0, x21
    mov x1, #6
    bl sqlite3_bind_null
.Lcp_enter_done:
    // exit_state (state id -> string; 0 -> NULL)
    mov x0, x19
    bl cache_state_str
    cbz x0, .Lcp_exit_null
    mov x2, x0
    mov x0, x21
    mov x1, #7
    bl cache_bind_text_stmt
    b .Lcp_exit_done
.Lcp_exit_null:
    mov x0, x21
    mov x1, #7
    bl sqlite3_bind_null
.Lcp_exit_done:
    mov x0, x21
    bl cache_step_stmt
    mov x0, x21
    bl sqlite3_finalize
    // ---- commit ----
    LEA x0, s_commit
    bl cache_db_exec
.Lcp_discard:
    bl cache_drop_stash
.Lcp_done:
    EPILOGUE 5
    ret

// ============================================================================
// tc_cache_discard_day — drop a pending stash (unreadable/partial reads
//   never write rollup rows).
// ============================================================================
    .p2align 2
    .global tc_cache_discard_day
    FUNC_TYPE(tc_cache_discard_day)
tc_cache_discard_day:
    PROLOGUE 0
    bl cache_drop_stash
    EPILOGUE 0
    ret

// ============================================================================
// tc_cache_debug_dump — test-only schema/row dump of the open database.
// ============================================================================
    .p2align 2
    .global tc_cache_debug_dump
    FUNC_TYPE(tc_cache_debug_dump)
tc_cache_debug_dump:
    PROLOGUE 1
    LEA x9, cache_db
    ldr x9, [x9]
    cbz x9, .Lcdd_done
    // ---- table names ----
    LEA x0, s_sql_master
    bl cache_prepare_stmt
    cbz x0, .Lcdd_done
    mov x19, x0                     // stmt
    LEA x0, s_cachetables
    bl tc_puts
.Lcdd_tbl_loop:
    mov x0, x19
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lcdd_tbl_done
    mov x0, x19
    mov x1, #0
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    b .Lcdd_tbl_loop
.Lcdd_tbl_done:
    LEA x0, s_newline
    bl tc_puts
    mov x0, x19
    bl sqlite3_finalize
    // ---- row counts ----
    LEA x0, s_cachecounts
    bl tc_puts
    LEA x0, s_lbl_meta
    bl tc_puts
    LEA x0, s_sql_count_meta
    bl cache_dump_count
    LEA x0, s_lbl_generation
    bl tc_puts
    LEA x0, s_sql_count_generation
    bl cache_dump_count
    LEA x0, s_lbl_file
    bl tc_puts
    LEA x0, s_sql_count_file
    bl cache_dump_count
    LEA x0, s_lbl_counts
    bl tc_puts
    LEA x0, s_sql_count_counts
    bl cache_dump_count
    LEA x0, s_newline
    bl tc_puts
    // ---- file rows ----
    LEA x0, s_sql_all_file
    bl cache_prepare_stmt
    cbz x0, .Lcdd_done
    mov x19, x0
.Lcdd_file_loop:
    mov x0, x19
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lcdd_file_done
    LEA x0, s_cachefile
    bl tc_puts
    mov x0, x19
    mov x1, #0
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #1
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #2
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #3
    bl sqlite3_column_int64
    bl tc_putu64
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #4
    bl sqlite3_column_int64
    bl tc_putu64
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #5
    bl sqlite3_column_text
    cbz x0, .Lcdd_file_en_dash
    bl tc_puts
    b .Lcdd_file_ent_done
.Lcdd_file_en_dash:
    LEA x0, s_dash
    bl tc_puts
.Lcdd_file_ent_done:
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #6
    bl sqlite3_column_text
    cbz x0, .Lcdd_file_ex_dash
    bl tc_puts
    b .Lcdd_file_ex_done
.Lcdd_file_ex_dash:
    LEA x0, s_dash
    bl tc_puts
.Lcdd_file_ex_done:
    LEA x0, s_newline
    bl tc_puts
    b .Lcdd_file_loop
.Lcdd_file_done:
    mov x0, x19
    bl sqlite3_finalize
    // ---- counts rows ----
    LEA x0, s_sql_all_counts
    bl cache_prepare_stmt
    cbz x0, .Lcdd_done
    mov x19, x0
.Lcdd_cnt_loop:
    mov x0, x19
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lcdd_cnt_done
    LEA x0, s_cachecount
    bl tc_puts
    // fingerprint, channel, date, login
    mov x0, x19
    mov x1, #0
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #1
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #2
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #3
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #4
    bl sqlite3_column_text
    bl tc_puts
    LEA x0, s_space
    bl tc_puts
    mov x0, x19
    mov x1, #5
    bl sqlite3_column_int64
    bl tc_putu64
    LEA x0, s_newline
    bl tc_puts
    b .Lcdd_cnt_loop
.Lcdd_cnt_done:
    mov x0, x19
    bl sqlite3_finalize
.Lcdd_done:
    EPILOGUE 1
    ret

// ============================================================================
// cache_dump_count(x0=count_sql) — print "<n> " for a SELECT COUNT(*) statement.
// ============================================================================
    .p2align 2
cache_dump_count:
    PROLOGUE 1
    mov x19, x0
    bl cache_prepare_stmt
    cbz x0, .Ldc_done
    mov x20, x0
    mov x0, x20
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Ldc_fin
    mov x0, x20
    mov x1, #0
    bl sqlite3_column_int64
    bl tc_putu64
.Ldc_fin:
    mov x0, x20
    bl sqlite3_finalize
.Ldc_done:
    EPILOGUE 1
    ret

// ============================================================================
// cache_migrate_step(x0=existed) -> x0 = 0 ok (reason in tc_cache_tmp), else failed
//   (problem composed, db closed).
// ============================================================================
    .p2align 2
cache_migrate_step:
    PROLOGUE 2
    mov x19, x0                     // existed
    // stored = SELECT value FROM meta WHERE key='schema'
    LEA x0, s_sql_sel_schema
    bl cache_prepare_stmt
    cbz x0, .Lms_fail
    mov x20, x0                     // stmt
    mov x0, x20
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lms_migrate               // no meta row -> migrate
    // The column_text pointer is owned by the statement: strcmp BEFORE
    // finalize (finalize frees the row memory).  Save the result in x21.
    mov x0, x20
    mov x1, #0
    bl sqlite3_column_text
    cbz x0, .Lms_finalize_migrate   // NULL value -> migrate
    mov x21, x0                     // stored value ptr (valid until finalize)
    LEA x1, s_schema_version
    bl strcmp
    cbnz w0, .Lms_finalize_migrate  // stored != "2" -> migrate
    mov x0, x20
    bl sqlite3_finalize
    b .Lms_ok                       // stored == "2": nothing to do
.Lms_finalize_migrate:
    mov x0, x20
    bl sqlite3_finalize
    b .Lms_migrate
.Lms_migrate:
    // drop + recreate + set schema
    LEA x0, s_sql_drop
    bl cache_db_exec
    cbnz w0, .Lms_fail
    LEA x0, s_sql_meta
    bl cache_db_exec
    cbnz w0, .Lms_fail
    LEA x0, s_sql_generation
    bl cache_db_exec
    cbnz w0, .Lms_fail
    LEA x0, s_sql_file
    bl cache_db_exec
    cbnz w0, .Lms_fail
    LEA x0, s_sql_counts
    bl cache_db_exec
    cbnz w0, .Lms_fail
    LEA x0, s_sql_set_schema
    bl cache_prepare_stmt
    cbz x0, .Lms_fail
    mov x20, x0
    mov x0, x20
    mov x1, #1
    LEA x2, s_schema_version
    bl cache_bind_text_stmt
    mov x0, x20
    bl cache_step_stmt
    mov x0, x20
    bl sqlite3_finalize
    // reason = existed ? "new cache layout" : "new cache"
    LEA x0, cache_tmp_reason
    cbz x19, .Lms_new_cache
    LEA x1, s_reason_new_layout
    str x1, [x0]
    b .Lms_ok
.Lms_new_cache:
    LEA x1, s_reason_new_cache
    str x1, [x0]
    b .Lms_ok
.Lms_ok:
    mov x0, #0
    b .Lms_out
.Lms_fail:
    LEA x0, s_step_migrate
    bl cache_fail_sqlite
    mov x0, #1
.Lms_out:
    EPILOGUE 2
    ret

// ============================================================================
// cache_register_step() -> x0 = 0 ok (reason OR'd into tc_cache_tmp), else failed.
//   known-set read BEFORE the upsert, exactly like the Python.
// ============================================================================
    .p2align 2
cache_register_step:
    PROLOGUE 3
    // known = { SELECT fingerprint FROM generation }
    LEA x0, s_sql_sel_gen
    bl cache_prepare_stmt
    cbz x0, .Lrs_fail
    mov x19, x0                     // stmt
    mov x20, #0                     // known (any generation row seen)
    mov x21, #0                     // present (our fp among them)
.Lrs_loop:
    mov x0, x19
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lrs_loop_done
    mov x20, #1
    mov x0, x19
    mov x1, #0
    bl sqlite3_column_text
    mov x22, x0                     // row fp
    LEA x0, cache_fp
    mov x1, x22
    bl strcmp
    cbnz w0, .Lrs_loop
    mov x21, #1
    b .Lrs_loop
.Lrs_loop_done:
    mov x0, x19
    bl sqlite3_finalize
    // now = datetime.now()
    mov x0, #0
    bl time
    mov x23, x0
    LEA x0, cache_scratch
    mov x1, x0
    mov x0, x23
    bl cache_fmt_iso                       // x1 -> out; x0 -> cursor (unused)
    // INSERT ... ON CONFLICT(fingerprint) DO UPDATE SET last_seen=...
    LEA x0, s_sql_ins_gen
    bl cache_prepare_stmt
    cbz x0, .Lrs_fail
    mov x19, x0
    mov x0, x19
    mov x1, #1
    LEA x2, cache_fp
    bl cache_bind_text_stmt
    mov x0, x19
    mov x1, #2
    LEA x2, cache_scratch
    bl cache_bind_text_stmt
    mov x0, x19
    bl cache_step_stmt
    mov x0, x19
    bl sqlite3_finalize
    // reason = known && !present ? "new parser generation" : (keep existing)
    cbz x20, .Lrs_ok
    cbnz x21, .Lrs_ok
    LEA x0, cache_tmp_reason
    ldr x1, [x0]
    cbnz x1, .Lrs_ok                // migrate's reason wins
    LEA x1, s_reason_new_gen
    str x1, [x0]
.Lrs_ok:
    mov x0, #0
    b .Lrs_out
.Lrs_fail:
    LEA x0, s_step_register
    bl cache_fail_sqlite
    mov x0, #1
.Lrs_out:
    EPILOGUE 3
    ret

// ============================================================================
// cache_sweep_step() -> x0 = 0 ok, else failed.  Drops generations unseen for
//   CACHE_KEEP_DAYS; records how many in cache_swept.
// ============================================================================
    .p2align 2
cache_sweep_step:
    PROLOGUE 3
    // now
    mov x0, #0
    bl time
    mov x19, x0
    ldr x20, =SECS_PER_DAY
    mov x21, #CACHE_KEEP_DAYS
    mul x20, x20, x21
    sub x19, x19, x20               // now - 7 days
    LEA x0, cache_scratch
    mov x1, x0
    mov x0, x19
    bl cache_fmt_iso
    // SELECT fingerprint FROM generation WHERE last_seen < ?
    LEA x0, s_sql_sel_stale
    bl cache_prepare_stmt
    cbz x0, .Lsw_fail
    mov x19, x0                     // stmt
    mov x0, x19
    mov x1, #1
    LEA x2, cache_scratch
    bl cache_bind_text_stmt
    mov x20, #0                     // swept count
.Lsw_loop:
    mov x0, x19
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lsw_loop_done
    mov x0, x19
    mov x1, #0
    bl sqlite3_column_text
    mov x21, x0                     // stale fp
    // DELETE counts/file/generation WHERE fingerprint = ?
    LEA x0, s_sql_del_counts_fp
    bl cache_prepare_stmt
    cbz x0, .Lsw_fail2
    mov x22, x0
    mov x0, x22
    mov x1, #1
    mov x2, x21
    bl cache_bind_text_stmt
    mov x0, x22
    bl cache_step_stmt
    mov x0, x22
    bl sqlite3_finalize
    LEA x0, s_sql_del_file_fp
    bl cache_prepare_stmt
    cbz x0, .Lsw_fail2
    mov x22, x0
    mov x0, x22
    mov x1, #1
    mov x2, x21
    bl cache_bind_text_stmt
    mov x0, x22
    bl cache_step_stmt
    mov x0, x22
    bl sqlite3_finalize
    LEA x0, s_sql_del_gen_fp
    bl cache_prepare_stmt
    cbz x0, .Lsw_fail2
    mov x22, x0
    mov x0, x22
    mov x1, #1
    mov x2, x21
    bl cache_bind_text_stmt
    mov x0, x22
    bl cache_step_stmt
    mov x0, x22
    bl sqlite3_finalize
    add x20, x20, #1
    b .Lsw_loop
.Lsw_loop_done:
    mov x0, x19
    bl sqlite3_finalize
    LEA x9, cache_swept
    str x20, [x9]
    mov x0, #0
    b .Lsw_out
.Lsw_fail2:
    mov x0, x19
    bl sqlite3_finalize
.Lsw_fail:
    LEA x0, s_step_sweep
    bl cache_fail_sqlite
    mov x0, #1
.Lsw_out:
    EPILOGUE 3
    ret

// ============================================================================
// cache_purge_step() -> x0 = 0 ok, else failed.  --rebuild-cache: drop the channel
//   across every generation (Python Cache._purge).
// ============================================================================
    .p2align 2
cache_purge_step:
    PROLOGUE 1
    LEA x0, s_sql_del_counts_chan
    bl cache_prepare_stmt
    cbz x0, .Lpg_fail
    mov x19, x0
    mov x0, x19
    mov x1, #1
    LEA x2, cache_channel
    ldr x2, [x2]
    bl cache_bind_text_stmt
    mov x0, x19
    bl cache_step_stmt
    mov x0, x19
    bl sqlite3_finalize
    LEA x0, s_sql_del_file_chan
    bl cache_prepare_stmt
    cbz x0, .Lpg_fail
    mov x19, x0
    mov x0, x19
    mov x1, #1
    LEA x2, cache_channel
    ldr x2, [x2]
    bl cache_bind_text_stmt
    mov x0, x19
    bl cache_step_stmt
    mov x0, x19
    bl sqlite3_finalize
    mov x0, #0
    b .Lpg_out
.Lpg_fail:
    LEA x0, s_step_rebuild
    bl cache_fail_sqlite
    mov x0, #1
.Lpg_out:
    EPILOGUE 1
    ret

// ============================================================================
// cache_get_day(x0=ymd, x1=enter_state) -> x0 = 1 hit (x1 = exit_state), 0 miss
//   SELECT the file row; cache_row_valid (fingerprint + size + mtime_ns +
//   enter_state); on hit apply every counts row via tc_reuse_apply and return
//   the cached exit_state.  Any sqlite error is a miss.
// ============================================================================
    .p2align 2
cache_get_day:
    PROLOGUE 5
    mov x19, x0                     // ymd
    mov x20, x1                     // enter_state
    // date string
    LEA x0, cache_scratch
    mov x1, x0
    mov x0, x19
    bl cache_fmt_date
    LEA x21, cache_scratch  // date ptr
    // SELECT the file row
    LEA x0, s_sql_sel_file
    bl cache_prepare_stmt
    cbz x0, .Lcg_miss
    mov x22, x0                     // stmt
    mov x0, x22
    mov x1, #1
    LEA x2, cache_fp
    bl cache_bind_text_stmt
    mov x0, x22
    mov x1, #2
    LEA x2, cache_channel
    ldr x2, [x2]
    bl cache_bind_text_stmt
    mov x0, x22
    mov x1, #3
    mov x2, x21
    bl cache_bind_text_stmt
    mov x0, x22
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lcg_miss_fin
    // row: size=col1, mtime=col2, enter=col3, exit=col4
    mov x0, x22
    mov x1, #1
    bl sqlite3_column_int64
    mov x23, x0                     // cached size
    mov x0, x22
    mov x1, #2
    bl sqlite3_column_int64
    mov x24, x0                     // cached mtime
    // The column_text pointers are owned by the statement: convert the
    // enter/exit state strings to ids BEFORE finalize frees the row memory.
    mov x0, x22
    mov x1, #3
    bl sqlite3_column_text
    mov x25, x0                     // cached enter str (may be 0)
    mov x0, x22
    mov x1, #4
    bl sqlite3_column_text
    mov x26, x0                     // cached exit str (may be 0)
    mov x0, x25
    bl cache_state_id                     // x0 = cached enter id 0/1/2/3
    mov x25, x0
    mov x0, x26
    bl cache_state_id                     // x0 = cached exit id 0/1/2/3
    mov x26, x0
    mov x0, x22
    bl sqlite3_finalize
    // validity: size + mtime_ns
    LEA x9, cache_stat
    ldr x10, [x9, #ST_SIZE]
    cmp x23, x10
    b.ne .Lcg_miss
    ldr x10, [x9, #ST_MTIM_SEC]
    MOV_NANOSEC x11
    mul x10, x10, x11
    ldr x11, [x9, #ST_MTIM_NSEC]
    add x10, x10, x11
    cmp x24, x10
    b.ne .Lcg_miss
    // validity: enter_state — compare ids directly (x25 vs x20, both 0/1/2/3)
    cmp x25, x20
    b.ne .Lcg_miss
    // hit: apply every counts row
    LEA x0, s_sql_sel_counts
    bl cache_prepare_stmt
    cbz x0, .Lcg_miss
    mov x22, x0
    mov x0, x22
    mov x1, #1
    LEA x2, cache_fp
    bl cache_bind_text_stmt
    mov x0, x22
    mov x1, #2
    LEA x2, cache_channel
    ldr x2, [x2]
    bl cache_bind_text_stmt
    mov x0, x22
    mov x1, #3
    mov x2, x21
    bl cache_bind_text_stmt
.Lcg_apply_loop:
    mov x0, x22
    bl cache_step_stmt
    cmp w0, #SQLITE_ROW
    b.ne .Lcg_apply_done
    mov x0, x22
    mov x1, #0
    bl sqlite3_column_text
    mov x27, x0                     // login
    mov x0, x22
    mov x1, #1
    bl sqlite3_column_text
    mov x28, x0                     // state str
    mov x0, x22
    mov x1, #2
    bl sqlite3_column_int64
    mov x23, x0                     // n
    mov x0, x27
    bl tc_strlen
    mov x24, x0                     // login len (callee-saved)
    mov x0, x28
    bl cache_state_id                     // x0 = TC_ST_* (0/1/2/3)
    mov x2, x0
    mov x0, x27
    mov x1, x24
    mov x3, x23
    bl tc_reuse_apply
    b .Lcg_apply_loop
.Lcg_apply_done:
    mov x0, x22
    bl sqlite3_finalize
    LEA x9, cache_hits
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    // return exit_state (x26 is already the cached exit id 0/1/2/3)
    mov x1, x26
    mov x0, #1
    b .Lcg_out
.Lcg_miss_fin:
    mov x0, x22
    bl sqlite3_finalize
.Lcg_miss:
    mov x0, #0
.Lcg_out:
    EPILOGUE 5
    ret

// ============================================================================
// (record-pointer arithmetic is the shared tc_entry_ptr in tc_util.S)
// ============================================================================

// ============================================================================
// cache_snapshot_users — malloc an array of old_count*3 u64s holding the live/
//   offline/unknown counts per existing user; stashed for the put.
// ============================================================================
    .p2align 2
cache_snapshot_users:
    PROLOGUE 3
    LEA x19, tc_users
    ldr x20, [x19, #TC_US_COUNT]    // n
    ldr x21, [x19, #TC_US_ENTRIES]  // entries
    mov x1, #24
    mul x0, x20, x1                 // malloc(n * 24): the product must be the
    bl malloc                       // argument (it used to land in x1, so this
                                    // allocated n bytes and overran the heap)
    cbz x0, .Lsu_none               // malloc fail -> no put (still parse)
    mov x22, x0                     // snap
    LEA x23, cache_snap
    str x22, [x23]
    LEA x23, cache_snap_n
    str x20, [x23]
    mov x24, #0                     // i
.Lsu_loop:
    cmp x24, x20
    b.ge .Lsu_done
    mov x0, x21
    mov x1, x24
    mov x2, #TC_US_ENTRY_SZ
    bl tc_entry_ptr
    mov x9, x0                      // entry
    mov x0, x22
    mov x1, x24
    mov x2, #24
    bl tc_entry_ptr
    mov x10, x0                     // snap slot
    ldr x11, [x9, #TC_US_LIVE]
    ldr x12, [x9, #TC_US_OFFLINE]
    ldr x13, [x9, #TC_US_UNKNOWN]
    str x11, [x10]
    str x12, [x10, #8]
    str x13, [x10, #16]
    add x24, x24, #1
    b .Lsu_loop
.Lsu_done:
    b .Lsu_out
.Lsu_none:
    LEA x9, cache_snap
    str xzr, [x9]
.Lsu_out:
    EPILOGUE 3
    ret

// ============================================================================
// cache_drop_stash — free the snapshot and clear the stash.
// ============================================================================
    .p2align 2
cache_drop_stash:
    PROLOGUE 0
    LEA x9, cache_snap
    ldr x0, [x9]
    cbz x0, .Lcds_done
    str xzr, [x9]
    bl free
.Lcds_done:
    LEA x9, cache_stash
    str xzr, [x9]
    EPILOGUE 0
    ret

// ============================================================================
// cache_state_str(x0=state 0/1/2/3) -> x0 = "live"/"offline"/"unknown"/0
//   Thin wrapper over the shared tc_state_str (TC_ST_* ids are 1/2/3 and 0
//   means "no state", which is exactly this function's contract).
// ============================================================================
    .p2align 2
cache_state_str:
    b tc_state_str

// ============================================================================
// cache_state_id(x0=str) -> x0 = 0/1/2/3 (unknown/live/offline/unknown-string)
// ============================================================================
    .p2align 2
cache_state_id:
    PROLOGUE 1
    cbz x0, .Lsi_zero
    mov x19, x0
    LEA x0, tc_str_live
    mov x1, x19
    bl strcmp
    cbz w0, .Lsi_one
    LEA x0, tc_str_offline
    mov x1, x19
    bl strcmp
    cbz w0, .Lsi_two
    mov x0, #3
    b .Lsi_out
.Lsi_zero:
    mov x0, #0
    b .Lsi_out
.Lsi_one:
    mov x0, #1
    b .Lsi_out
.Lsi_two:
    mov x0, #2
.Lsi_out:
    EPILOGUE 1
    ret

// ============================================================================
// cache_resolve_cache_path -- DEFAULT_CACHE_PATH per platform class into
//   cache_path:
//     MacOS: expanduser("~/.cache/twitch-counts/rollup.db")   (XDG_* ignored)
//     Linux: os.path.join(XDG_CACHE_HOME or expanduser("~/.cache"),
//                         "twitch-counts/rollup.db") -- an empty variable
//            counts as unset, a set one is used verbatim.
//   expanduser follows CPython (HOME present even if empty; else the
//   password database), so there is no "no HOME -> no cache" case any more.
// ============================================================================
    .p2align 2
cache_resolve_cache_path:
    PROLOGUE 2
#ifndef __APPLE__
    LEA x0, s_env_xdg_cache
    bl getenv
    cbz x0, .Lrcp_default
    ldrb w1, [x0]
    cbz w1, .Lrcp_default
    mov x19, x0                     // base = XDG_CACHE_HOME, verbatim
    LEA x0, cache_path
    mov x1, x19
    mov x2, #PATH_SZ
    bl cache_cat_cstr_cap                 // x0 = cursor at the NUL
    mov x20, x0
    mov x0, x19
    bl tc_strlen
    sub x9, x0, #1
    ldrb w9, [x19, x9]
    LEA x1, s_path_tail  // "/twitch-counts/rollup.db"
    cmp w9, #'/'
    b.ne .Lrcp_join
    add x1, x1, #1                  // os.path.join: no doubled slash
.Lrcp_join:
    mov x0, x20
    LEA_OFF x2, cache_path, PATH_SZ
    sub x2, x2, x20                 // bytes left from the cursor
    bl cache_cat_cstr_cap
    b .Lrcp_done
.Lrcp_default:
#endif
    LEA x0, s_cache_default
    LEA x1, cache_path
    mov x2, #PATH_SZ
    bl tc_expanduser
.Lrcp_done:
    EPILOGUE 2
    ret

// ============================================================================
// cache_mkdir_cache_dir(x0=path) — mkdir -p the directory component of the cache
//   path (Python os.makedirs(dirname, exist_ok=True)).  Failures are ignored:
//   a bad directory surfaces later as sqlite3_open_v2's CANTOPEN.
// ============================================================================
    .p2align 2
cache_mkdir_cache_dir:
    PROLOGUE 2
    mov x19, x0                     // path
    // find the last '/' (dirname ends there)
    mov x20, x19
    mov x21, #0                     // last slash pos
    mov x22, #0                     // index
.Lmcd_len:
    ldrb w9, [x20, x22]
    cbz w9, .Lmcd_len_done
    cmp w9, #'/'
    b.ne .Lmcd_next
    mov x21, x22
.Lmcd_next:
    add x22, x22, #1
    cmp x22, #(PATH_SZ - 1)
    b.ge .Lmcd_len_done
    b .Lmcd_len
.Lmcd_len_done:
    cbz x21, .Lmcd_done             // no directory component
    // copy the dirname [0..last slash) into scratch2, NUL-terminated
    LEA x0, cache_scratch2
    mov x20, x0                     // scratch cursor
    mov x22, #0                     // i
.Lmcd_copy:
    cmp x22, x21
    b.ge .Lmcd_copy_done
    ldrb w9, [x19, x22]
    strb w9, [x20, x22]
    add x22, x22, #1
    b .Lmcd_copy
.Lmcd_copy_done:
    mov w9, #0
    strb w9, [x20, x22]
    // walk '/' boundaries creating each missing parent, then the whole
    // dirname (mkdir -p semantics)
    mov x22, #0                     // i
.Lmcd_loop:
    cmp x22, x21
    b.ge .Lmcd_last
    ldrb w9, [x20, x22]
    cmp w9, #'/'
    b.ne .Lmcd_loop_next
    mov w10, #0
    strb w10, [x20, x22]            // temporarily NUL at the slash
    mov x0, x20
    mov x1, #DIR_MODE                // 0777 (umask still applies)
    bl mkdir
    ldrb w9, [x19, x22]             // restore the slash from the original path
    strb w9, [x20, x22]
.Lmcd_loop_next:
    add x22, x22, #1
    b .Lmcd_loop
.Lmcd_last:
    mov x0, x20
    mov x1, #DIR_MODE
    bl mkdir                        // the final component (no trailing slash)
.Lmcd_done:
    EPILOGUE 2
    ret

// ============================================================================
// cache_fingerprint_build — FNV-1a 64 over the fixed parts, rendered as 16 hex
//   chars into cache_fp.
// ============================================================================
    .p2align 2
cache_fingerprint_build:
    PROLOGUE 3
    ldr x19, =FNV_OFFSET             // hash
    LEA x20, s_fp_parts
    mov x21, #0                     // part index
.Lfb_loop:
    ldr x22, [x20, x21, lsl #3]     // part ptr
    cbz x22, .Lfb_hash_done
    mov x0, x22
    bl tc_strlen
    mov x2, x0
    mov x0, x19
    mov x1, x22
    bl cache_fnv1a
    mov x19, x0
    // separator byte '\n' between parts
    LEA x1, s_sep
    mov x0, x19
    mov x2, #1
    bl cache_fnv1a
    mov x19, x0
    add x21, x21, #1
    b .Lfb_loop
.Lfb_hash_done:
    // render 16 hex chars, most significant nibble first
    LEA x23, cache_fp
    mov x24, #15                    // nibble index
.Lfb_hex:
    cmp x24, #0
    b.lt .Lfb_hex_done
    mov x9, #4
    mul x9, x24, x9
    lsrv x10, x19, x9
    and x10, x10, #0xF
    cmp x10, #10
    b.lt .Lfb_digit
    add x10, x10, #('a' - 10)
    b .Lfb_store
.Lfb_digit:
    add x10, x10, #'0'
.Lfb_store:
    strb w10, [x23, x24]
    sub x24, x24, #1
    b .Lfb_hex
.Lfb_hex_done:
    mov w9, #0
    strb w9, [x23, #16]
    EPILOGUE 3
    ret

// ============================================================================
// cache_fnv1a(x0=hash, x1=ptr, x2=len) -> x0 = hash
// ============================================================================
    .p2align 2
cache_fnv1a:
    mov x3, #0
.Lf_loop:
    cmp x3, x2
    b.ge .Lf_done
    ldrb w4, [x1, x3]
    eor x0, x0, x4
    ldr x5, =FNV_PRIME
    mul x0, x0, x5
    add x3, x3, #1
    b .Lf_loop
.Lf_done:
    ret

// ============================================================================
// cache_db_exec(x0=sql) -> x0 = sqlite3_exec rc
// ============================================================================
    .p2align 2
cache_db_exec:
    PROLOGUE 1
    mov x19, x0
    LEA x0, cache_db
    ldr x0, [x0]
    mov x1, x19
    mov x2, #0
    mov x3, #0
    mov x4, #0
    bl sqlite3_exec
    EPILOGUE 1
    ret

// ============================================================================
// cache_prepare_stmt(x0=sql) -> x0 = stmt ptr or 0 on error
// ============================================================================
    .p2align 2
cache_prepare_stmt:
    PROLOGUE 1
    mov x19, x0
    LEA x0, cache_db
    ldr x0, [x0]
    mov x1, x19
    mov x2, #-1
    sub sp, sp, #16                 // ppStmt slot
    mov x3, sp
    mov x4, #0
    bl sqlite3_prepare_v2
    cbnz x0, .Lps_fail
    ldr x0, [sp]
    add sp, sp, #16
    EPILOGUE 1
    ret
.Lps_fail:
    add sp, sp, #16
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// cache_bind_text_stmt(x0=stmt, x1=idx, x2=str) -> x0 = rc
// ============================================================================
    .p2align 2
cache_bind_text_stmt:
    PROLOGUE 0
    mov x3, #-1
    mov x4, #SQLITE_STATIC
    bl sqlite3_bind_text
    EPILOGUE 0
    ret

// ============================================================================
// cache_bind_int64_stmt(x0=stmt, x1=idx, x2=val) -> x0 = rc
// ============================================================================
    .p2align 2
cache_bind_int64_stmt:
    PROLOGUE 0
    bl sqlite3_bind_int64
    EPILOGUE 0
    ret

// ============================================================================
// cache_step_stmt(x0=stmt) -> x0 = sqlite3_step rc
// ============================================================================
    .p2align 2
cache_step_stmt:
    PROLOGUE 0
    bl sqlite3_step
    EPILOGUE 0
    ret

// ============================================================================
// cache_fail_sqlite(x0=step) — compose "<step> failed -- <Type>: <errmsg>",
//   close the db and clear cache_db.
// ============================================================================
    .p2align 2
cache_fail_sqlite:
    PROLOGUE 3
    mov x19, x0                     // step
    LEA x0, cache_db
    ldr x20, [x0]                   // db
    mov x0, x20
    bl sqlite3_errcode
    mov x21, x0                     // rc
    bl cache_sqlite_type_name             // x0 = type ptr
    mov x22, x0
    mov x0, x20
    bl sqlite3_errmsg
    mov x23, x0                     // msg
    // compose
    LEA x0, cache_problem_buf
    mov x24, x0
    mov x1, x19
    bl tc_cat_cstr
    LEA x1, s_failed
    bl tc_cat_cstr
    mov x1, x22
    bl tc_cat_cstr
    LEA x1, s_colon_space
    bl tc_cat_cstr
    mov x1, x23
    bl tc_cat_cstr
    LEA x9, cache_problem
    LEA x10, cache_problem_buf
    str x10, [x9]
    // close the db
    mov x0, x20
    cbz x0, .Lcfs_done
    bl sqlite3_close
.Lcfs_done:
    LEA x9, cache_db
    str xzr, [x9]
    EPILOGUE 3
    ret

// ============================================================================
// cache_sqlite_type_name(x0=rc) -> x0 = Python-exception-name approximation.
// ============================================================================
    .p2align 2
cache_sqlite_type_name:
    cmp w0, #SQLITE_NOTADB
    b.eq .Lstn_db
    cmp w0, #SQLITE_CORRUPT
    b.eq .Lstn_db
    cmp w0, #SQLITE_ERROR
    b.eq .Lstn_db
    cmp w0, #SQLITE_NOMEM
    b.eq .Lstn_mem
    LEA x0, s_type_operr
    ret
.Lstn_db:
    LEA x0, s_type_dberr
    ret
.Lstn_mem:
    LEA x0, s_type_memerr
    ret

// ============================================================================
// cache_cat_cstr_cap(x0=cursor, x1=s, x2=cap) — bounded append; writes at most
//   cap-1 bytes plus a NUL (cap = bytes available from the cursor).
//   Returns the cursor at the NUL.
// ============================================================================
    .p2align 2
cache_cat_cstr_cap:
    PROLOGUE 1
    mov x19, x0
    mov x20, x2                     // cap
    mov x2, #0                      // i
.Lccc_loop:
    sub x3, x20, #1
    cmp x2, x3
    b.ge .Lccc_full
    ldrb w3, [x1, x2]
    strb w3, [x19, x2]
    cbz w3, .Lccc_done
    add x2, x2, #1
    b .Lccc_loop
.Lccc_full:
    mov w3, #0
    strb w3, [x19, x2]
    add x19, x19, x2
    b .Lccc_out
.Lccc_done:
    // the NUL was copied at [x19 + x2]; return the cursor AT it so the
    // caller's next append overwrites it (cat_cstr semantics)
    add x19, x19, x2
.Lccc_out:
    mov x0, x19
    EPILOGUE 1
    ret

// ============================================================================
// cache_fmt_date(x0=ymd, x1=out) -> x0 = cursor after "YYYY-MM-DD" (NUL written).
// ============================================================================
    .p2align 2
cache_fmt_date:
    PROLOGUE 3
    mov x19, x0                     // ymd
    mov x20, x1                     // out
    mov x21, #YMD_YEAR_SCALE
    udiv x22, x19, x21              // y
    mov x21, #YMD_MONTH_SCALE
    udiv x23, x19, x21
    msub x23, x23, x21, x19         // d
    mov x21, #YMD_YEAR_SCALE
    udiv x24, x19, x21
    mov x21, #YMD_YEAR_SCALE
    mul x24, x24, x21
    sub x24, x19, x24
    mov x21, #YMD_MONTH_SCALE
    udiv x24, x24, x21              // mo
    mov x0, x20
    mov x1, x22
    mov x2, #4
    bl cache_put_pad
    mov w1, #'-'
    strb w1, [x0], #1
    mov x1, x24
    mov x2, #2
    bl cache_put_pad
    mov w1, #'-'
    strb w1, [x0], #1
    mov x1, x23
    mov x2, #2
    bl cache_put_pad
    mov w1, #0
    strb w1, [x0]
    EPILOGUE 3
    ret

// ============================================================================
// cache_fmt_iso(x0=epoch, x1=out) -> x0 = cursor after "YYYY-MM-DDTHH:MM:SS".
//   Local time via localtime_r; UTC fallback (1970-01-01) if it fails.
// ============================================================================
    .p2align 2
cache_fmt_iso:
    PROLOGUE 3
    mov x19, x0                     // epoch
    mov x20, x1                     // out
    LEA x0, cache_epoch
    str x19, [x0]
    mov x1, x0
    LEA x0, cache_tm
    mov x21, x0                     // tm
    LEA x0, cache_epoch
    mov x1, x21
    bl localtime_r
    cbz x0, .Lfiso_epoch0
    // struct tm fields are 32-bit ints — load with 32-bit loads, not ldr
    ldr w22, [x21, #TM_YEAR]
    add x22, x22, #TM_YEAR_BASE             // y
    ldr w23, [x21, #TM_MON]
    add x23, x23, #1                // mo
    ldr w24, [x21, #TM_MDAY]        // d
    ldr w9, [x21, #TM_HOUR]         // h
    ldr w10, [x21, #TM_MIN]         // mi
    ldr w11, [x21, #TM_SEC]         // s
    b .Lfiso_emit
.Lfiso_epoch0:
    mov x22, #1970
    mov x23, #1
    mov x24, #1
    mov x9, #0
    mov x10, #0
    mov x11, #0
.Lfiso_emit:
    mov x0, x20
    mov x1, x22
    mov x2, #4
    bl cache_put_pad
    mov w1, #'-'
    strb w1, [x0], #1
    mov x1, x23
    mov x2, #2
    bl cache_put_pad
    mov w1, #'-'
    strb w1, [x0], #1
    mov x1, x24
    mov x2, #2
    bl cache_put_pad
    mov w1, #'T'
    strb w1, [x0], #1
    mov x1, x9
    mov x2, #2
    bl cache_put_pad
    mov w1, #':'
    strb w1, [x0], #1
    mov x1, x10
    mov x2, #2
    bl cache_put_pad
    mov w1, #':'
    strb w1, [x0], #1
    mov x1, x11
    mov x2, #2
    bl cache_put_pad
    mov w1, #0
    strb w1, [x0]
    EPILOGUE 3
    ret

// ============================================================================
// cache_put_pad(x0=buf, x1=value, x2=width) -> x0 = cursor after the digits.
//   Zero-pads to `width`; value must fit (<= 9999 for the callers here).
// ============================================================================
    .p2align 2
cache_put_pad:
    PROLOGUE 3
    mov x19, x0                     // buf
    mov x20, x1                     // value
    mov x21, x2                     // width
    sub sp, sp, #32
    add x22, sp, #31
    mov x23, #0                     // digit count
    mov x3, x20
    cbz x3, .Lpp_zero
.Lpp_loop:
    mov x4, #10
    udiv x5, x3, x4
    msub x6, x5, x4, x3
    add x6, x6, #'0'
    strb w6, [x22]
    sub x22, x22, #1
    add x23, x23, #1
    mov x3, x5
    cbnz x3, .Lpp_loop
    b .Lpp_pad
.Lpp_zero:
    mov w4, #'0'
    strb w4, [x22]
    sub x22, x22, #1
    mov x23, #1
.Lpp_pad:
    mov x5, x21
    sub x5, x5, x23
.Lpp_pad_go:
    cmp x5, #0
    b.le .Lpp_copy                 // value wider than the field: no padding
    mov w4, #'0'
    strb w4, [x19], #1
    sub x5, x5, #1
    b .Lpp_pad_go
.Lpp_copy:
    add x22, x22, #1
.Lpp_copy_loop:
    cbz x23, .Lpp_done
    ldrb w4, [x22], #1
    strb w4, [x19], #1
    sub x23, x23, #1
    b .Lpp_copy_loop
.Lpp_done:
    mov x0, x19
    add sp, sp, #32
    EPILOGUE 3
    ret

// ============================================================================
// cache_tmp_reason — bss slot for migrate/register reasons (private).
// ============================================================================
    .bss
    .p2align 3
cache_tmp_reason: .skip 8

    .end
