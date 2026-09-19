// ============================================================================
// tc_core.S — channel resolution, log listing, window completion, counting
//             and --users sizing for twitch-counts
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//  Linking:    by the Makefile (build/<os>/twitch-counts and the drivers)
//
//  What this module owns (the shared contract is tc_layout.inc)
//  ----------------------------------------------------------------------
//    * channel resolution:  the logs dir is listed (opendir/readdir), the
//      directory names are sorted, and the channel is matched
//      case-insensitively (Python resolve_channel_dir).
//    * the dated log listing:  entries matching <anything>-YYYY-MM-DD.log
//      with a real calendar date, sorted ascending by (date, name) into the
//      contract's tc_listing structure (Python log_files).
//    * window completion:  the earliest-log-file begin (kind 3), the
//      --users sizing (kind 2), and the begin>end check for kind 3
//      (Python resolve_context).  tc_cli has already resolved kinds 0/1.
//    * the counting pass:  seed state from earlier files (seed_lookback),
//      per-file line folding with state carry, per-user per-state counts in
//      tc_users, and the tally in tc_tally (Python count_messages +
//      fold_windows), including unreadable-file recording and the exclusion
//      subtraction via tc_excl_contains.
//    * the --users bisection (Python size_window/_search_width/_apply_width)
//      producing (width, found) into TC_W_USERS_WIDTH / TC_W_USERS_FOUND and
//      begin = end - width.
//
//  Deviation notes
//  ---------------
//    * Unreadable log files are recorded with the Python's OSError text
//      ("<ExcClass>: <strerror>", tc_errno_reason) or with "file too large".
//    * A 1 GiB sanity cap on a single log file ("file too large").  The
//      Python has no cap; a cap this large is not reachable by real logs.
//    * CRLF line endings are NOT special-cased: a marker line ending in \r
//      is not a marker, exactly as in the Python (the reference stripped \r).
//    * A channel dir that cannot be opened after resolution prints
//      "error: cannot open channel directory: <dir>" (Python would surface
//      the raw OSError; not exercised by the differential).
//
//  Exported (all .global, AAPCS64, x19-x28 preserved)
//  --------------------------------------------------
//    tc_count_run()                resolve channel + listing + window, then
//                                  count into tc_users/tc_tally (exit 1 with
//                                  "error: ..." on ConfigError-equivalents).
//    tc_count_column(x0=index)     -> x0 = the count-column for a user-table
//                                  entry: the sum of the states matching the
//                                  resolved state filter (all three when
//                                  unfiltered).  tc_render.S needs this for the
//                                  ranking; it is an addition beyond the
//                                  contract's symbol list, documented here.
//    tc_user_state(x0=index, x1=TC_ST_*) -> x0 = that state's count for the
//                                  entry.  Addition (render columns).
//
//  Notes for tc_render.S / tc_cache.S (what the contract does NOT say but
//  this module relies on)
//  -------------------------------------------------------------------------
//    * tc_users entries include EXCLUDED users, with their counts intact.
//      The exclusion subtraction is applied to the TALLY only (states,
//      excluded_states, messages).  tc_render.S must skip excluded entries when
//      ranking/rendering (call tc_excl_contains(login, len) on each entry)
//      and can compute the "excluded appeared" information by walking the
//      table exactly as the reference did.
//    * Tally fields are post-exclusion: TC_T_STATES is the non-excluded
//      all-state split, TC_T_MESSAGES is the non-excluded count-column
//      total, TC_T_EXCLUDED_STATES is the excluded all-state split.
//    * TC_T_USERS_PTR points at the tc_users header.
//    * The listing/tally/user-table allocation uses malloc; all pointers in
//      the contract structures are heap pointers that the owner (this
//      module, once per run) frees or reuses.
//
//  Cache integration (this file is the ONLY place the cache hooks
//  live; tc_cache.S provides the SQLite rollup)
//  -------------------------------------------------------------------------
//    * core_count_final's loop calls tc_cache_day(fpath, lo, hi, enter_state,
//      ymd) once per in-range file, right after the path is built and before
//      the read.  Result 1 = the day came from the rollup (counts already
//      applied to tc_users + the all-state totals; x1 = cached exit_state):
//      the loop stores it into core_cur_state, bumps TC_T_REUSED and
//      moves on without reading the file.  Result 2 = stat failed: the loop
//      records the file as unreadable and resets the stream state (Python's
//      skip()).  Result 0 = parse normally; if the file was a whole day the
//      cache module stashed a snapshot and tc_cache_put_day writes the day
//      after a successful whole-file parse (no-op otherwise).
//    * The cache module NEVER reads core_cur_state; the loop passes the
//      entering state in and stores the returned exit state itself.
//    * tc_reuse_apply(x0=login, x1=len, x2=TC_ST_*, x3=n) is exported for the
//      cache module: it adds n to one user's state bucket and the matching
//      all-state total, exactly like core_process_message's increment section.
//    * tc_find_user/tc_add_user gained a third parameter (x2 = table base) so the
//      cache module can reuse the exact table logic; core_process_message passes
//      the tc_users base.
//    * One-shot runs open/close the cache around tc_count_run (the driver's
//      main).  Watch mode (tc_watch.S) opens once per session and keeps the
//      connection; core_count_final uses whatever tc_cache.S has open.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

// ----------------------------------------------------------------------------
// musl / shared-module externals
// ----------------------------------------------------------------------------
    .globl malloc
    .globl free
    .globl realloc
    .globl opendir
    .globl strerror
    .globl stat
    .globl tc_expanduser
    .globl readdir
    .globl closedir
    .globl open
    .globl close
    .globl read
    .globl __errno_location
    .globl strcmp
    .globl tc_strlen
    .globl tc_fail
    .globl tc_civil_from_days
    .globl tc_excl_contains
    // rollup-cache hooks (implemented in tc_cache.S)
    .globl tc_cache_day
    .globl tc_cache_put_day
    .globl tc_cache_discard_day
    .globl tc_cat_cstr
    .globl tc_days_from_civil
    .globl tc_ymd_sod_to_epoch
    .globl tc_epoch_to_ymd_sod
    .globl tc_days_in_month
    .globl tc_report_fail

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ LAST_SECOND,     86399
    .equ FILE_CAP,        1073741824      // 1 GiB sanity cap (documented)
    .equ MAX_DNAMES,      256
    .equ DNAME_SZ,        256
    .equ READ_CHUNK,      8192
    .equ LISTING_INIT,    64
    .equ USERS_INIT,      64
    .equ CF_ENTRY,        0               // core_count_final frame slots
    .equ CF_LO,           8
    .equ CF_HI,           16
    .equ CF_CPTR,         24
    .equ CF_BUF,          32              // malloc'd file buffer across calls
    .equ CF_LEN,          40
    .equ CF_FRAME_SZ,     48

// ============================================================================
// .bss — private scratch (not part of the shared contract; the contract
// structures tc_opts/tc_window/tc_users/tc_tally/tc_listing live in tc_cli.S)
// ============================================================================
    .bss
    .p2align 4
core_scratch:    .skip 2048          // error-message composition buffer
core_reason:     .skip 128           // "{ExcClass}: {strerror}" of a skipped file
core_statbuf:    .skip STAT_SZ       // os.path.isdir(logs_dir)
    .global tc_last_errno
tc_last_errno:      .skip 8             // errno of the last captured failure
core_fmt:        .skip 64            // datetime formatting buffer
core_login:      .skip 32            // core_speaker_login output (<= 25 + NUL)
core_dirpath:    .skip 640           // logs_dir + "/" + channel_name
core_fpath:      .skip 704           // dirpath + "/" + file name
core_name:       .skip 64            // resolved channel directory name
core_chlower:    .skip 64            // lowercased resolved channel
core_dnames:     .skip MAX_DNAMES * 8
core_darena:     .skip MAX_DNAMES * DNAME_SZ
core_dname_count:.skip 8
core_list_key:   .skip 80            // sort scratch (listing entry copy)
core_cur_state:  .skip 8             // 0 = unknown, 1 = live, 2 = offline
core_g_live:     .skip 8             // all-user all-state totals
core_g_off:      .skip 8
core_g_unk:      .skip 8

// ============================================================================
// .rodata — message literals (lengths via label arithmetic where it matters)
// ============================================================================
    RODATA
s_dir_not_found:    .asciz "logs directory not found: "
s_logs_dir_unsupported: .asciz "TODO - not implemented: the default Chatterino log location on Linux. pass --logs-dir, or set logs_dir in the config. Chatterino is believed to use ~/.local/share/chatterino/Logs/Twitch/Channels."
s_no_logs_pre:      .asciz "no logs for channel '"
s_no_logs_mid:      .asciz "' in "
s_avail:            .asciz "available: "
s_none_paren:       .asciz "(none)"
s_no_files_pre:     .asciz "no log files found in "
s_cant_open_dir:    .asciz "cannot open channel directory: "
s_begin_paren:      .asciz "begin ("
s_is_after_end:     .asciz ") is after end ("
s_too_large:        .asciz "file too large"
s_oom:              .asciz "out of memory"
lit_is_live:        .asciz "is live!"
lit_is_offline:     .asciz "is now offline."

    .text

// ============================================================================
// tc_count_run — the counting entry point.
//   Reads the resolved tc_opts + tc_window, then:
//     resolve channel -> build listing -> complete window -> count.
//   Errors (ConfigError-equivalents) go through tc_fail: "error: ..." + exit 1.
// ============================================================================
    .p2align 2
    .global tc_count_run
    FUNC_TYPE(tc_count_run)
tc_count_run:
    PROLOGUE 1
    bl tc_resolve_channel
    bl core_build_listing
    bl core_complete_window
    bl core_count_final
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// tc_channel_name() -> x0 = pointer to the resolved channel directory name
//   (the real on-disk name found by the case-insensitive match; what the
//   Python calls context.channel_name).  Addition for tc_render.S's channel
//   header row, documented here.
// ============================================================================
    .p2align 2
    .global tc_channel_name
    FUNC_TYPE(tc_channel_name)
tc_channel_name:
    LEA x0, core_name
    ret

// ============================================================================
// tc_count_column(x0=user index) -> x0 = the count-column for the entry:
//   the sum of the states matching the resolved state filter (TC_W_STATE_FILTER),
//   or all three states when unfiltered.  Exported for tc_render.S.
// ============================================================================
    .p2align 2
    .global tc_count_column
    FUNC_TYPE(tc_count_column)
tc_count_column:
    PROLOGUE 1
    LEA x1, tc_users
    ldr x2, [x1, #TC_US_ENTRIES]
    mov x3, #TC_US_ENTRY_SZ
    mul x3, x0, x3
    add x2, x2, x3                  // entry ptr
    LEA x3, tc_window
    ldr x4, [x3, #TC_W_STATE_FILTER]
    cmp x4, #TC_ST_LIVE
    b.eq .Lcc_live
    cmp x4, #TC_ST_OFFLINE
    b.eq .Lcc_off
    cmp x4, #TC_ST_UNKNOWN
    b.eq .Lcc_unk
    ldr x0, [x2, #TC_US_LIVE]
    ldr x5, [x2, #TC_US_OFFLINE]
    add x0, x0, x5
    ldr x5, [x2, #TC_US_UNKNOWN]
    add x0, x0, x5
    EPILOGUE 1
    ret
.Lcc_live:
    ldr x0, [x2, #TC_US_LIVE]
    EPILOGUE 1
    ret
.Lcc_off:
    ldr x0, [x2, #TC_US_OFFLINE]
    EPILOGUE 1
    ret
.Lcc_unk:
    ldr x0, [x2, #TC_US_UNKNOWN]
    EPILOGUE 1
    ret

// ============================================================================
// tc_user_state(x0=user index, x1=TC_ST_*) -> x0 = that state's count.
// ============================================================================
    .p2align 2
    .global tc_user_state
    FUNC_TYPE(tc_user_state)
tc_user_state:
    LEA x2, tc_users
    ldr x3, [x2, #TC_US_ENTRIES]
    mov x4, #TC_US_ENTRY_SZ
    mul x4, x0, x4
    add x2, x3, x4
    cmp x1, #TC_ST_LIVE
    b.eq .Lus_live
    cmp x1, #TC_ST_OFFLINE
    b.eq .Lus_off
    ldr x0, [x2, #TC_US_UNKNOWN]
    ret
.Lus_live:
    ldr x0, [x2, #TC_US_LIVE]
    ret
.Lus_off:
    ldr x0, [x2, #TC_US_OFFLINE]
    ret

// ============================================================================
// core_eff_threshold — the effective reported() floor for --users sizing:
//   max(min_count, share_floor) when a share is shown or sorted by and the
//   share floor is nonzero, else min_count.  (Python rank_users ordering:
//   the >= threshold filter, then the >= floor filter when it acts.)
// ============================================================================
    .p2align 2
core_eff_threshold:
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_MIN_COUNT]
    ldr x2, [x0, #TC_O_SORT]
    cmp x2, #TC_M_OFFLINE_SHARE
    b.ge .Lef_shown
    ldr x3, [x0, #TC_O_COLUMN_COUNT]
    mov x4, #0
.Lef_col:
    cmp x4, x3
    b.ge .Lef_check
    add x5, x0, #TC_O_COLUMNS
    ldr x6, [x5, x4, lsl #3]
    cmp x6, #TC_M_OFFLINE_SHARE
    b.ge .Lef_shown
    add x4, x4, #1
    b .Lef_col
.Lef_shown:
    b .Lef_floor
.Lef_check:
    b .Lef_out
.Lef_floor:
    ldr x2, [x0, #TC_O_SHARE_FLOOR]
    cbz x2, .Lef_out
    cmp x2, x1
    b.le .Lef_out
    mov x0, x2
    ret
.Lef_out:
    mov x0, x1
    ret


// ============================================================================
// tc_resolve_channel — find the channel directory (case-insensitive) and
//   build core_dirpath = <logs_dir>/<real name>; exits on error.
//   Exported so tc_cache_open can resolve the channel before it
//   captures the channel name (the counting pass would otherwise resolve it
//   too late for the open-time purge).  Idempotent: calling it again from
//   tc_count_run re-reads the directory with identical results.
// ============================================================================
    .p2align 2
    .global tc_resolve_channel
    FUNC_TYPE(tc_resolve_channel)
tc_resolve_channel:
    PROLOGUE 5
    // os.path.expanduser(logs_dir): the Python expands the setting when it
    // resolves it, whatever its source, so "~/..." works from the command
    // line, the environment and the config, and the header and every error
    // show the expanded path.  In place (idempotent on a second call).
    LEA_OFF x0, tc_opts, TC_O_LOGS_DIR
    LEA x1, core_scratch
    mov x2, #TC_O_LOGS_DIR_SZ
    bl tc_expanduser
    LEA_OFF x0, tc_opts, TC_O_LOGS_DIR
    LEA x1, core_scratch
    bl core_copy_str
    // lowercased channel for matching
    LEA_OFF x0, tc_opts, TC_O_CHANNEL
    LEA x1, core_chlower
    bl core_lowercase_copy
    // os.path.isdir(logs_dir): anything but a directory is "not found"
    LEA_OFF x0, tc_opts, TC_O_LOGS_DIR
    LEA x1, core_statbuf
    bl stat
    cbnz w0, .Lrc_dir_notfound
    LEA x0, core_statbuf
    LOAD_ST_MODE 1, x0
    and w1, w1, #S_IFMT
    cmp w1, #S_IFDIR
    b.ne .Lrc_dir_notfound
    // os.listdir(logs_dir): a directory that cannot be listed is main()'s
    // OSError backstop, "PermissionError: [Errno 13] Permission denied: '...'"
    bl core_list_channel_dirs
    cbz x0, .Lrc_dir_oserror
    // find the channel case-insensitively
    LEA x20, core_dname_count
    ldr x19, [x20]                     // count
    mov x21, #0                        // index
.Lrc_find:
    cmp x21, x19
    b.ge .Lrc_no_channel
    LEA x22, core_dnames
    ldr x22, [x22, x21, lsl #3]        // name
    LEA x1, core_chlower
    mov x0, x22
    bl core_ascii_casecmp
    cbz x0, .Lrc_found
    add x21, x21, #1
    b .Lrc_find
.Lrc_found:
    // x22 = the real directory name
    LEA x0, core_name
    mov x1, x22
    bl core_copy_str
    // dirpath = logs_dir + "/" + name
    LEA x0, core_dirpath
    mov x23, x0
    LEA x0, tc_opts
    add x1, x0, #TC_O_LOGS_DIR
    mov x0, x23
    bl tc_cat_cstr
    mov w2, #'/'
    strb w2, [x0], #1
    mov x23, x0
    LEA x1, core_name
    mov x0, x23
    bl tc_cat_cstr
    EPILOGUE 5
    ret

.Lrc_dir_oserror:
    bl tc_capture_errno
    LEA x0, core_scratch
    LEA_OFF x1, tc_opts, TC_O_LOGS_DIR
    bl tc_oserror_text
    bl tc_report_fail

.Lrc_dir_notfound:
    // logs_dir unset (empty string): the resolved setting has no value at
    // all (Python's logs_dir.value is None, require_logs_dir() raises
    // Unsupported on Linux; macOS always has a built-in default so this
    // is unreachable there once tc_cli applies it).  logs_dir set but the
    // directory does not exist: today's "logs directory not found: <path>".
    LEA_OFF x0, tc_opts, TC_O_LOGS_DIR
    ldrb w1, [x0]
    cbnz w1, .Lrc_dir_notfound_set
    // `root = logs_dir.value or PLATFORM.require_logs_dir()`: an empty value
    // (e.g. -d "") falls back to the platform default; the macOS class has
    // one, the Linux class raises Unsupported
    mov x1, #TC_O_LOGS_DIR_SZ
    bl tc_platform_default_logs_dir    // x0 = length, 0 = no default
    cbnz x0, .Lrc_dir_defaulted
    LEA x0, s_logs_dir_unsupported
    bl tc_report_fail
.Lrc_dir_defaulted:
    // start over with the default in place (expanduser + isdir + opendir)
    EPILOGUE 5
    b tc_resolve_channel
.Lrc_dir_notfound_set:
    // "logs directory not found: <dir>"
    LEA x0, core_scratch
    mov x19, x0
    LEA x1, s_dir_not_found
    bl tc_cat_cstr
    mov x19, x0
    LEA x0, tc_opts
    add x1, x0, #TC_O_LOGS_DIR
    mov x0, x19
    bl tc_cat_cstr
    mov w1, #0
    strb w1, [x0]
    LEA x0, core_scratch
    bl tc_report_fail

.Lrc_no_channel:
    // "no logs for channel '<ch>' in <dir>\navailable: <join|(none)>"
    LEA x0, core_scratch
    mov x19, x0
    LEA x1, s_no_logs_pre
    bl tc_cat_cstr
    mov x19, x0
    LEA x0, tc_opts
    add x1, x0, #TC_O_CHANNEL
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    LEA x1, s_no_logs_mid
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    LEA x0, tc_opts
    add x1, x0, #TC_O_LOGS_DIR
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    mov w2, #'\n'
    strb w2, [x19], #1
    LEA x1, s_avail
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    ldr x20, [x20]                     // dname count
    cbz x20, .Lrc_avail_none
    mov x21, #0
.Lrc_avail_loop:
    LEA x22, core_dnames
    ldr x22, [x22, x21, lsl #3]
    mov x0, x19
    mov x1, x22
    bl tc_cat_cstr
    mov x19, x0
    add x23, x21, #1
    cmp x23, x20
    b.ge .Lrc_avail_done
    mov w2, #','
    strb w2, [x19], #1
    mov w2, #' '
    strb w2, [x19], #1
    mov x21, x23
    b .Lrc_avail_loop
.Lrc_avail_none:
    LEA x1, s_none_paren
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
.Lrc_avail_done:
    mov w2, #0
    strb w2, [x19]
    LEA x0, core_scratch
    bl tc_fail

// ============================================================================
// core_list_channel_dirs — os.listdir(logs_dir) filtered to directories:
//   fills core_dnames/core_darena/core_dname_count with every subdirectory
//   name (minus "." and "..", capped at MAX_DNAMES entries of DNAME_SZ-1
//   bytes), sorted by core_sort_dnames.
//   -> x0 = 1, or 0 when opendir failed (errno left for tc_capture_errno).
// ============================================================================
    .p2align 2
core_list_channel_dirs:
    PROLOGUE 1
    LEA_OFF x0, tc_opts, TC_O_LOGS_DIR
    bl opendir
    cbz x0, .Llcd_fail
    mov x19, x0                        // DIR*
    LEA x20, core_dname_count
    str xzr, [x20]
.Llcd_list:
    mov x0, x19
    bl readdir
    cbz x0, .Llcd_done
    ldrb w1, [x0, #D_TYPE_OFF]         // d_type
    cmp w1, #DT_DIR
    b.ne .Llcd_list
    add x1, x0, #D_NAME_OFF            // d_name
    // skip "." and ".."
    ldrb w2, [x1]
    cmp w2, #'.'
    b.ne .Llcd_keep
    ldrb w2, [x1, #1]
    cbz w2, .Llcd_list
    cmp w2, #'.'
    b.ne .Llcd_keep
    ldrb w2, [x1, #2]
    cbz w2, .Llcd_list
.Llcd_keep:
    ldr x3, [x20]
    cmp x3, #MAX_DNAMES
    b.ge .Llcd_list
    // name length, capped at DNAME_SZ-1 (Darwin d_name can run up to 1023
    // bytes; this cap already rejects anything that long, same as Linux)
    mov x4, x1
    mov x5, #0
.Llcd_nlen:
    ldrb w6, [x4]
    cbz w6, .Llcd_nlen_done
    add x4, x4, #1
    add x5, x5, #1
    cmp x5, #(DNAME_SZ - 1)
    b.ge .Llcd_list
    b .Llcd_nlen
.Llcd_nlen_done:
    // copy into the arena
    LEA x6, core_darena
    mov x7, #DNAME_SZ
    mul x7, x3, x7
    add x6, x6, x7
    LEA x8, core_dnames
    str x6, [x8, x3, lsl #3]
    mov x9, #0
.Llcd_copy:
    cmp x9, x5
    b.ge .Llcd_copy_done
    ldrb w10, [x1, x9]
    strb w10, [x6, x9]
    add x9, x9, #1
    b .Llcd_copy
.Llcd_copy_done:
    mov w10, #0
    strb w10, [x6, x9]
    add x3, x3, #1
    str x3, [x20]
    b .Llcd_list
.Llcd_done:
    mov x0, x19
    bl closedir
    bl core_sort_dnames
    mov x0, #1
    EPILOGUE 1
    ret
.Llcd_fail:
    mov x0, #0
    EPILOGUE 1
    ret

// ============================================================================
// core_build_listing — fill tc_listing with every dated log file, ascending.
// ============================================================================
    .p2align 2
core_build_listing:
    PROLOGUE 5
    LEA x19, tc_listing
    str xzr, [x19, #TC_L_COUNT]
    str xzr, [x19, #TC_L_CAP]
    str xzr, [x19, #TC_L_ENTRIES]
    LEA x0, core_dirpath
    bl opendir
    cbz x0, .Lbl_cant_open
    mov x20, x0                        // DIR*
.Lbl_list:
    mov x0, x20
    bl readdir
    cbz x0, .Lbl_done
    add x22, x0, #D_NAME_OFF           // d_name (callee-saved)
    mov x0, x22
    bl core_parse_log_filename              // x0 = ymd or 0 (clobbers x0-x2)
    cbz x0, .Lbl_list
    mov x21, x0                        // ymd
    mov x23, #0                        // name len
.Lbl_nlen:
    ldrb w4, [x22, x23]
    cbz w4, .Lbl_nlen_done
    add x23, x23, #1
    cmp x23, #63
    b.gt .Lbl_list
    b .Lbl_nlen
.Lbl_nlen_done:
    // grow the entry array if needed
    ldr x24, [x19, #TC_L_COUNT]
    ldr x25, [x19, #TC_L_CAP]
    cmp x24, x25
    b.lt .Lbl_append
    cbz x25, .Lbl_new64
    lsl x25, x25, #1
    b .Lbl_alloc
.Lbl_new64:
    mov x25, #LISTING_INIT
.Lbl_alloc:
    mov x26, x25                       // new cap (x25 is clobbered by realloc)
    ldr x0, [x19, #TC_L_ENTRIES]
    mov x1, #TC_L_ENTRY_SZ
    mul x1, x25, x1
    bl realloc
    cbz x0, .Lbl_oom
    str x0, [x19, #TC_L_ENTRIES]
    str x26, [x19, #TC_L_CAP]
    ldr x24, [x19, #TC_L_COUNT]
.Lbl_append:
    ldr x25, [x19, #TC_L_ENTRIES]
    mov x26, #TC_L_ENTRY_SZ
    mul x26, x24, x26
    add x25, x25, x26
    str x21, [x25, #TC_L_YMD]
    add x26, x25, #TC_L_NAME
    mov x27, #0
.Lbl_copy:
    cmp x27, x23
    b.ge .Lbl_copy_done
    ldrb w28, [x22, x27]
    strb w28, [x26, x27]
    add x27, x27, #1
    b .Lbl_copy
.Lbl_copy_done:
    mov w28, #0
    strb w28, [x26, x27]
    add x24, x24, #1
    str x24, [x19, #TC_L_COUNT]
    b .Lbl_list
.Lbl_done:
    mov x0, x20
    bl closedir
    bl core_sort_listing
    EPILOGUE 5
    ret

.Lbl_cant_open:
    // os.listdir(channel_dir) raised: main()'s OSError backstop text
    bl tc_capture_errno
    LEA x0, core_scratch
    LEA x1, core_dirpath
    bl tc_oserror_text                 // x0 = the NUL-terminated text
    bl tc_report_fail                  // text or {"error": ...}, exit 1

.Lbl_oom:
    LEA x0, s_oom
    bl tc_fail

// ============================================================================
// core_parse_log_filename(x0=name) -> x0 = ymd (YYYYMMDD), or 0 when the name is
//   not "<anything>-YYYY-MM-DD.log" with a real calendar date.
// ============================================================================
    .p2align 2
core_parse_log_filename:
    PROLOGUE 3
    mov x19, x0                        // name
    mov x0, x19
    bl tc_strlen
    mov x20, x0                        // len
    cmp x20, #16
    b.lt .Lplf_fail
    // suffix ".log"
    sub x2, x20, #4
    ldrb w3, [x19, x2]
    cmp w3, #'.'
    b.ne .Lplf_fail
    sub x2, x20, #3
    ldrb w3, [x19, x2]
    cmp w3, #'l'
    b.ne .Lplf_fail
    sub x2, x20, #2
    ldrb w3, [x19, x2]
    cmp w3, #'o'
    b.ne .Lplf_fail
    sub x2, x20, #1
    ldrb w3, [x19, x2]
    cmp w3, #'g'
    b.ne .Lplf_fail
    // separators '-' at len-15, len-10, len-7
    sub x2, x20, #15
    ldrb w3, [x19, x2]
    cmp w3, #'-'
    b.ne .Lplf_fail
    sub x2, x20, #10
    ldrb w3, [x19, x2]
    cmp w3, #'-'
    b.ne .Lplf_fail
    sub x2, x20, #7
    ldrb w3, [x19, x2]
    cmp w3, #'-'
    b.ne .Lplf_fail
    // the channel part before the date must be nonempty
    sub x2, x20, #15
    cbz x2, .Lplf_fail
    // year (len-14 .. len-11)
    sub x2, x20, #14
    mov x3, #0
    mov x4, #0
.Lplf_y:
    cmp x4, #4
    b.ge .Lplf_mo
    ldrb w5, [x19, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    mov x6, #10
    mul x3, x3, x6
    add x3, x3, x5
    add x2, x2, #1
    add x4, x4, #1
    b .Lplf_y
.Lplf_mo:
    // month (len-9, len-8)
    sub x2, x20, #9
    ldrb w5, [x19, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    mov x6, #10
    mul x7, x5, x6
    add x2, x2, #1
    ldrb w5, [x19, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    add x7, x7, x5                    // mo
    // day (len-6, len-5)
    sub x2, x20, #6
    ldrb w5, [x19, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    mov x6, #10
    mul x8, x5, x6
    add x2, x2, #1
    ldrb w5, [x19, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    add x8, x8, x5                    // d
    // validate the calendar date
    cbz x3, .Lplf_fail                // year 0
    cmp x7, #1
    b.lt .Lplf_fail
    cmp x7, #12
    b.gt .Lplf_fail
    cmp x8, #1
    b.lt .Lplf_fail
    mov x0, x3
    mov x1, x7
    stp x3, x7, [sp, #-16]!
    stp x8, x30, [sp, #-16]!
    bl tc_days_in_month
    ldp x8, x30, [sp], #16
    ldp x3, x7, [sp], #16
    cmp x8, x0
    b.gt .Lplf_fail
    // ymd = y*10000 + mo*100 + d
    mov x5, #YMD_YEAR_SCALE
    mul x3, x3, x5
    mov x5, #YMD_MONTH_SCALE
    mul x7, x7, x5
    add x3, x3, x7
    add x3, x3, x8
    mov x0, x3
    EPILOGUE 3
    ret
.Lplf_fail:
    mov x0, #0
    EPILOGUE 3
    ret

// ============================================================================
// core_complete_window — finish the window tc_cli left open:
//   kind EARLIEST: begin = earliest log file 00:00:00 (+ no-files and
//                  begin>end errors); kind USERS: the --users sizing.
//   Always fills TC_W_THRESHOLD and TC_W_STATE_FILTER from the options.
// ============================================================================
    .p2align 2
core_complete_window:
    PROLOGUE 5
    LEA x19, tc_window
    ldr x20, [x19, #TC_W_KIND]
    cmp x20, #TC_WIN_EARLIEST
    b.eq .Lcw_earliest
    cmp x20, #TC_WIN_USERS
    b.eq .Lcw_users
    b .Lcw_fill
.Lcw_earliest:
    LEA x21, tc_listing
    ldr x22, [x21, #TC_L_COUNT]
    cbnz x22, .Lcw_earliest_ok
    // "no log files found in <dirpath>"
    LEA x0, core_scratch
    mov x23, x0
    LEA x1, s_no_files_pre
    bl tc_cat_cstr
    mov x23, x0
    LEA x1, core_dirpath
    mov x0, x23
    bl tc_cat_cstr
    mov w1, #0
    strb w1, [x0]
    LEA x0, core_scratch
    bl tc_fail
.Lcw_earliest_ok:
    ldr x23, [x21, #TC_L_ENTRIES]
    ldr x24, [x23]
    str x24, [x19, #TC_W_BEGIN_YMD]
    str xzr, [x19, #TC_W_BEGIN_SOD]
    bl core_window_begin_after_end_check
    b .Lcw_fill
.Lcw_users:
    bl core_size_users
    b .Lcw_fill
.Lcw_fill:
    LEA x20, tc_opts
    ldr x21, [x20, #TC_O_MIN_COUNT]
    str x21, [x19, #TC_W_THRESHOLD]
    ldr x21, [x20, #TC_O_STATE_FILTER]
    str x21, [x19, #TC_W_STATE_FILTER]
    EPILOGUE 5
    ret

// ============================================================================
// core_window_begin_after_end_check — "begin (B) is after end (E)" when the
//   resolved begin (kind EARLIEST) is later than the resolved end.
// ============================================================================
    .p2align 2
core_window_begin_after_end_check:
    PROLOGUE 3
    LEA x19, tc_window
    ldr x0, [x19, #TC_W_BEGIN_YMD]
    ldr x1, [x19, #TC_W_BEGIN_SOD]
    bl tc_ymd_sod_to_epoch
    mov x20, x0
    ldr x0, [x19, #TC_W_END_YMD]
    ldr x1, [x19, #TC_W_END_SOD]
    bl tc_ymd_sod_to_epoch
    mov x21, x0
    cmp x20, x21
    b.le .Lwae_done
    LEA x0, core_scratch
    mov x22, x0
    LEA x1, s_begin_paren
    bl tc_cat_cstr
    mov x22, x0
    ldr x1, [x19, #TC_W_BEGIN_YMD]
    ldr x2, [x19, #TC_W_BEGIN_SOD]
    mov x0, x1
    mov x1, x2
    mov x2, x22                          // format into the scratch cursor
    bl core_fmt_ymd_sod
    mov x22, x0
    LEA x1, s_is_after_end
    mov x0, x22
    bl tc_cat_cstr
    mov x22, x0
    ldr x1, [x19, #TC_W_END_YMD]
    ldr x2, [x19, #TC_W_END_SOD]
    mov x0, x1
    mov x1, x2
    mov x2, x22                          // format into the scratch cursor
    bl core_fmt_ymd_sod
    mov w1, #')'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    LEA x0, core_scratch
    bl tc_fail
.Lwae_done:
    EPILOGUE 3
    ret

// ============================================================================
// core_size_users — the --users bisection (Python _search_width + _apply_width).
//   Sets TC_W_USERS_WIDTH / TC_W_USERS_FOUND and begin = end - width.
// ============================================================================
    .p2align 2
core_size_users:
    PROLOGUE 5
    // end_epoch
    LEA x9, tc_window
    ldr x0, [x9, #TC_W_END_YMD]
    ldr x1, [x9, #TC_W_END_SOD]
    bl tc_ymd_sod_to_epoch
    mov x19, x0                        // end_epoch
    // requested / ceiling
    LEA x9, tc_opts
    ldr x20, [x9, #TC_O_USERS]
    ldr x21, [x9, #TC_O_USERS_MAX]
    cmp x21, #1
    b.ge .Lsu_ceiling_ok
    mov x21, #1
.Lsu_ceiling_ok:
    bl core_eff_threshold
    mov x22, x0                        // eff
    // widest = reported(ceiling)
    mov x0, x21
    bl core_reported_width
    mov x23, x0                        // widest
    cmp x23, x20
    b.lt .Lsu_unreachable
    // ---- bisection 1: smallest width with count >= requested ----
    mov x9, #1                         // lo
    mov x10, x21                       // hi
.Lsu_b1:
    cmp x9, x10
    b.ge .Lsu_b1_done
    sub x11, x10, x9
    lsr x11, x11, #1
    add x11, x9, x11                   // mid (floors)
    stp x9, x10, [sp, #-16]!
    stp x11, x19, [sp, #-16]!
    stp x20, x21, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    mov x0, x11
    bl core_reported_width
    ldp x22, x23, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x11, x19, [sp], #16
    ldp x9, x10, [sp], #16
    cmp x0, x20
    b.lt .Lsu_b1_else
    mov x10, x11
    b .Lsu_b1
.Lsu_b1_else:
    add x9, x11, #1
    b .Lsu_b1
.Lsu_b1_done:
    mov x24, x9                        // over_width
    mov x0, x9
    bl core_reported_width
    mov x25, x0                        // over
    // ---- bisection 2: widest width with count <= requested ----
    mov x9, #1
    mov x10, x21
.Lsu_b2:
    cmp x9, x10
    b.ge .Lsu_b2_done
    sub x11, x10, x9
    add x11, x11, #1
    lsr x11, x11, #1
    add x11, x9, x11                   // mid (ceils)
    stp x9, x10, [sp, #-16]!
    stp x11, x19, [sp, #-16]!
    stp x20, x21, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    stp x24, x25, [sp, #-16]!
    mov x0, x11
    bl core_reported_width
    ldp x24, x25, [sp], #16
    ldp x22, x23, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x11, x19, [sp], #16
    ldp x9, x10, [sp], #16
    cmp x0, x20
    b.gt .Lsu_b2_else
    mov x9, x11
    b .Lsu_b2
.Lsu_b2_else:
    sub x10, x11, #1
    b .Lsu_b2
.Lsu_b2_done:
    mov x26, x9                        // under_width
    mov x0, x9
    bl core_reported_width
    mov x27, x0                        // under
    // ---- policy ----
    LEA x9, tc_opts
    ldr x9, [x9, #TC_O_USERS_POLICY]
    cmp x9, #TC_POLICY_AT_MOST
    b.eq .Lsu_at_most
    cmp x9, #TC_POLICY_NEAREST
    b.eq .Lsu_nearest
    // at-least
    mov x1, x24
    mov x2, x25
    b .Lsu_apply
.Lsu_at_most:
    mov x1, x26
    mov x2, x27
    b .Lsu_apply
.Lsu_nearest:
    sub x9, x27, x20
    cmp x9, #0
    b.ge .Lsu_n_absu
    neg x9, x9
.Lsu_n_absu:
    sub x10, x25, x20
    cmp x10, #0
    b.ge .Lsu_n_abso
    neg x10, x10
.Lsu_n_abso:
    cmp x9, x10
    b.le .Lsu_n_under                 // ties to the narrower window
    mov x1, x24
    mov x2, x25
    b .Lsu_apply
.Lsu_n_under:
    mov x1, x26
    mov x2, x27
    b .Lsu_apply
.Lsu_unreachable:
    mov x1, x21                       // width = ceiling
    mov x2, x23                       // found = widest
    b .Lsu_apply
.Lsu_apply:
    LEA x9, tc_window
    str x1, [x9, #TC_W_USERS_WIDTH]
    str x2, [x9, #TC_W_USERS_FOUND]
    sub x0, x19, x1                   // begin = end - width
    bl tc_epoch_to_ymd_sod
    LEA x9, tc_window  // reload: the call clobbered x9
    str x0, [x9, #TC_W_BEGIN_YMD]
    str x1, [x9, #TC_W_BEGIN_SOD]
    EPILOGUE 5
    ret

// ============================================================================
// core_reported_width(x0=seconds) -> x0 = the reported population for the
//   window [end - seconds, end]: non-excluded users whose count-column is
//   >= the effective threshold (min_count, or share_floor when a share is
//   shown and the floor is nonzero).  Side effect: recounts into the user
//   table + tally for the probe window (the final pass overwrites).
// ============================================================================
    .p2align 2
core_reported_width:
    PROLOGUE 5
    mov x19, x0                        // seconds
    LEA x20, tc_window
    ldr x0, [x20, #TC_W_END_YMD]
    ldr x1, [x20, #TC_W_END_SOD]
    bl tc_ymd_sod_to_epoch
    sub x0, x0, x19                    // begin_epoch
    bl tc_epoch_to_ymd_sod             // x0=ymd, x1=sod
    str x0, [x20, #TC_W_BEGIN_YMD]
    str x1, [x20, #TC_W_BEGIN_SOD]
    bl core_count_final
    bl core_eff_threshold
    mov x21, x0                        // eff
    LEA x22, tc_users
    ldr x23, [x22, #TC_US_COUNT]
    ldr x24, [x22, #TC_US_ENTRIES]
    mov x25, #0                        // n
    mov x26, #0                        // i
.Lrw_loop:
    cmp x26, x23
    b.ge .Lrw_done
    mov x27, #TC_US_ENTRY_SZ
    mul x27, x26, x27
    add x27, x24, x27                  // entry
    mov x0, x27
    bl tc_strlen
    mov x1, x0
    mov x0, x27
    bl tc_excl_contains
    cbnz x0, .Lrw_next
    mov x0, x26
    bl tc_count_column
    cmp x0, x21
    b.lt .Lrw_next
    add x25, x25, #1
.Lrw_next:
    add x26, x26, #1
    b .Lrw_loop
.Lrw_done:
    mov x0, x25
    EPILOGUE 5
    ret

// ============================================================================
// core_count_final — the counting pass for the resolved window [begin, end]:
//   seed state, fold every in-range file, then finish the tally.  Fills
//   tc_users and tc_tally (fresh each call; probes overwrite later).
// ============================================================================
    .p2align 2
core_count_final:
    PROLOGUE 5
    sub sp, sp, #CF_FRAME_SZ
    bl core_reset_count
    bl core_seed_state                    // x0 = 0/1/2
    LEA x9, core_cur_state
    str x0, [x9]
    LEA x19, tc_listing
    ldr x19, [x19, #TC_L_COUNT]        // count
    LEA x20, tc_listing
    ldr x20, [x20, #TC_L_ENTRIES]      // entries
    LEA x21, tc_window
    ldr x22, [x21, #TC_W_BEGIN_YMD]
    ldr x23, [x21, #TC_W_BEGIN_SOD]
    ldr x24, [x21, #TC_W_END_YMD]
    ldr x25, [x21, #TC_W_END_SOD]
    LEA x26, tc_tally
    mov x27, #0                         // i
.Lcf_loop:
    cmp x27, x19
    b.ge .Lcf_done
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x27, x9
    add x9, x20, x9                     // entry
    ldr x10, [x9, #TC_L_YMD]
    cmp x10, x22
    b.lt .Lcf_next
    cmp x10, x24
    b.gt .Lcf_next
    // in range: files++
    ldr x11, [x26, #TC_T_FILES]
    add x11, x11, #1
    str x11, [x26, #TC_T_FILES]
    // lo/hi (bucket_bounds)
    mov x11, #0
    cmp x22, x10
    b.lt .Lcf_lo_ok
    mov x11, x23
.Lcf_lo_ok:
    ldr x12, =LAST_SECOND
    cmp x24, x10
    b.gt .Lcf_hi_ok
    mov x12, x25
.Lcf_hi_ok:
    str x9, [sp, #CF_ENTRY]
    str x11, [sp, #CF_LO]
    str x12, [sp, #CF_HI]
    // build the file path
    LEA x0, core_fpath
    LEA x1, core_dirpath
    bl tc_cat_cstr
    mov w2, #'/'
    strb w2, [x0], #1
    str x0, [sp, #CF_CPTR]
    ldr x1, [sp, #CF_ENTRY]
    add x1, x1, #TC_L_NAME
    bl tc_cat_cstr
    // ---- rollup-cache hook ----
    // A whole-day file inside the range may come from the rollup.  The cache
    // module stats the path and returns 0 = parse normally, 1 = reused (x1 =
    // cached exit_state; counts already applied to tc_users + totals), 2 =
    // stat failed (record unreadable + reset state, like Python's skip()).
    LEA x0, core_fpath
    ldr x1, [sp, #CF_LO]
    ldr x2, [sp, #CF_HI]
    LEA x9, core_cur_state
    ldr x3, [x9]
    ldr x4, [sp, #CF_ENTRY]
    ldr x4, [x4, #TC_L_YMD]
    bl tc_cache_day
    cmp w0, #1
    b.eq .Lcf_cached
    cmp w0, #2
    b.eq .Lcf_cache_unreadable
    // read the whole file
    LEA x0, core_fpath
    bl core_read_file                     // x0=status, x1=buf, x2=len
    cbnz x0, .Lcf_unreadable
    // ok: buf = x1, len = x2 -> keep them in the frame across calls
    str x1, [sp, #CF_BUF]
    str x2, [sp, #CF_LEN]
    mov x0, x1
    mov x1, x2
    bl core_has_newline
    cbz x0, .Lcf_free
    ldr x2, [sp, #CF_LO]
    ldr x3, [sp, #CF_HI]
    ldr x0, [sp, #CF_BUF]
    ldr x1, [sp, #CF_LEN]
    bl core_process_lines
    ldr x11, [x26, #TC_T_PARSED]
    add x11, x11, #1
    str x11, [x26, #TC_T_PARSED]
    // ---- write the whole day to the rollup (no-op unless the
    // cache module stashed this file's snapshot) ----
    LEA x9, core_cur_state
    ldr x0, [x9]
    bl tc_cache_put_day
    b .Lcf_free
.Lcf_unreadable:
    mov x9, x0                          // status
    stp x9, x1, [sp, #-16]!             // save status + buf across the call
    bl tc_cache_discard_day             // drop any pending stash
    ldp x9, x1, [sp], #16
    str x1, [sp, #CF_BUF]               // buf (may be 0)
    cmp x9, #1
    b.eq .Lcf_too_large
    // skip(): f"{type(exc).__name__}: {exc.strerror}" from the errno that
    // core_read_file captured
    LEA x0, core_reason
    bl tc_errno_reason
    mov x1, x0
    ldr x0, [sp, #CF_ENTRY]
    add x0, x0, #TC_L_NAME
    b .Lcf_record
.Lcf_too_large:
    ldr x0, [sp, #CF_ENTRY]
    add x0, x0, #TC_L_NAME
    LEA x1, s_too_large
.Lcf_record:
    bl core_record_unreadable
    ldr x10, [sp, #CF_BUF]
    cbz x10, .Lcf_state_reset
    mov x0, x10
    bl free
.Lcf_state_reset:
    LEA x9, core_cur_state
    str xzr, [x9]
    b .Lcf_next
.Lcf_free:
    bl tc_cache_discard_day             // no-newline days never write
    ldr x9, [sp, #CF_BUF]
    cbz x9, .Lcf_next
    mov x0, x9
    bl free
.Lcf_next:
    add x27, x27, #1
    b .Lcf_loop
.Lcf_cached:
    // the day came from the rollup.  x1 = cached exit_state; the
    // cache module already applied the counts to tc_users + the totals.
    ldr x11, [x26, #TC_T_REUSED]
    add x11, x11, #1
    str x11, [x26, #TC_T_REUSED]
    LEA x9, core_cur_state
    str x1, [x9]
    b .Lcf_next
.Lcf_cache_unreadable:
    // stat failed inside the cache hook (errno captured there);
    // record + reset state, exactly like Python's skip().
    LEA x0, core_reason
    bl tc_errno_reason
    mov x1, x0
    ldr x0, [sp, #CF_ENTRY]
    add x0, x0, #TC_L_NAME
    bl core_record_unreadable
    LEA x9, core_cur_state
    str xzr, [x9]
    b .Lcf_next
.Lcf_done:
    add sp, sp, #CF_FRAME_SZ
    bl core_finish_tally
    EPILOGUE 5
    ret

// ============================================================================
// core_reset_count — zero the tally and the global counters, reset the user
//   table count (the entry buffer is kept and reused across probes).
// ============================================================================
    .p2align 2
core_reset_count:
    PROLOGUE 0
    LEA x0, core_g_live
    mov x1, #0
    str x1, [x0]
    str x1, [x0, #8]
    str x1, [x0, #16]
    LEA x0, core_cur_state
    str x1, [x0]
    LEA x0, tc_tally
    mov x1, #TC_TALLY_SIZE
    bl core_memzero_own
    LEA x0, tc_tally
    LEA x1, tc_users
    str x1, [x0, #TC_T_USERS_PTR]
    str xzr, [x1, #TC_US_COUNT]
    EPILOGUE 0
    ret

// ============================================================================
// core_finish_tally — apply exclusions to the tally: TC_T_STATES becomes the
//   non-excluded all-state split, TC_T_EXCLUDED_STATES the excluded split,
//   TC_T_MESSAGES the non-excluded count-column total.
// ============================================================================
    .p2align 2
core_finish_tally:
    PROLOGUE 5
    LEA x19, tc_tally
    LEA x20, core_g_live
    ldr x21, [x20]
    ldr x22, [x20, #8]
    ldr x23, [x20, #16]
    str x21, [x19, #TC_T_STATES + 0]
    str x22, [x19, #TC_T_STATES + 8]
    str x23, [x19, #TC_T_STATES + 16]
    str xzr, [x19, #TC_T_EXCLUDED_STATES + 0]
    str xzr, [x19, #TC_T_EXCLUDED_STATES + 8]
    str xzr, [x19, #TC_T_EXCLUDED_STATES + 16]
    str xzr, [x19, #TC_T_MESSAGES]
    LEA x24, tc_users
    ldr x25, [x24, #TC_US_COUNT]
    ldr x26, [x24, #TC_US_ENTRIES]
    mov x27, #0                         // i
.Lft_loop:
    cmp x27, x25
    b.ge .Lft_done
    mov x28, #TC_US_ENTRY_SZ
    mul x28, x27, x28
    add x28, x26, x28                   // entry
    mov x0, x28
    bl tc_strlen
    mov x1, x0
    mov x0, x28
    bl tc_excl_contains
    cbz x0, .Lft_not_excl
    ldr x9, [x28, #TC_US_LIVE]
    ldr x10, [x28, #TC_US_OFFLINE]
    ldr x11, [x28, #TC_US_UNKNOWN]
    ldr x12, [x19, #TC_T_EXCLUDED_STATES + 0]
    add x12, x12, x9
    str x12, [x19, #TC_T_EXCLUDED_STATES + 0]
    ldr x12, [x19, #TC_T_EXCLUDED_STATES + 8]
    add x12, x12, x10
    str x12, [x19, #TC_T_EXCLUDED_STATES + 8]
    ldr x12, [x19, #TC_T_EXCLUDED_STATES + 16]
    add x12, x12, x11
    str x12, [x19, #TC_T_EXCLUDED_STATES + 16]
    ldr x12, [x19, #TC_T_STATES + 0]
    sub x12, x12, x9
    str x12, [x19, #TC_T_STATES + 0]
    ldr x12, [x19, #TC_T_STATES + 8]
    sub x12, x12, x10
    str x12, [x19, #TC_T_STATES + 8]
    ldr x12, [x19, #TC_T_STATES + 16]
    sub x12, x12, x11
    str x12, [x19, #TC_T_STATES + 16]
    b .Lft_next
.Lft_not_excl:
    mov x0, x27
    bl tc_count_column
    ldr x9, [x19, #TC_T_MESSAGES]
    add x9, x9, x0
    str x9, [x19, #TC_T_MESSAGES]
.Lft_next:
    add x27, x27, #1
    b .Lft_loop
.Lft_done:
    EPILOGUE 5
    ret

// ============================================================================
// core_record_unreadable(x0=name, x1=reason) — capped unreadable list.
// ============================================================================
    .p2align 2
// ============================================================================
// errno -> the text Python attaches to an OSError.
//   tc_capture_errno()            stores errno in tc_last_errno; call it right
//                                 after the failing libc call, before anything
//                                 else can clobber errno.
//   tc_errno_reason(x0=dst)       "{ExcClass}: {strerror}"   (skip(): the
//                                 header/JSON reason for an unreadable file)
//   tc_oserror_text(x0=dst, x1=path)
//                                 "{ExcClass}: [Errno N] {strerror}: '{path}'"
//                                 (main()'s backstop: f"{type(exc).__name__}:
//                                 {exc}" for an OSError with a filename)
//   All three preserve x19-x28; the text is NUL-terminated and x0 = dst.
// ============================================================================
    .p2align 2
    .global tc_capture_errno
    FUNC_TYPE(tc_capture_errno)
tc_capture_errno:
    PROLOGUE 0
    bl __errno_location
    ldr w0, [x0]
    LEA x9, tc_last_errno
    str x0, [x9]
    EPILOGUE 0
    ret

    .p2align 2
    .global tc_errno_reason
    FUNC_TYPE(tc_errno_reason)
tc_errno_reason:
    PROLOGUE 1
    mov x19, x0
    LEA x9, tc_last_errno
    ldr x20, [x9]
    mov x0, x20
    bl core_errno_exc_name
    mov x1, x0
    mov x0, x19
    bl tc_cat_cstr
    LEA x1, s_exc_sep
    bl tc_cat_cstr
    str x0, [sp, #-16]!                // the cursor, across strerror()
    mov x0, x20
    bl strerror
    mov x1, x0
    ldr x0, [sp], #16
    bl tc_cat_cstr
    mov x0, x19                        // dst (before x19 is restored)
    EPILOGUE 1
    ret

    .p2align 2
    .global tc_oserror_text
    FUNC_TYPE(tc_oserror_text)
tc_oserror_text:
    PROLOGUE 2
    mov x19, x0                        // dst (kept for the return)
    mov x21, x1                        // path
    LEA x9, tc_last_errno
    ldr x20, [x9]
    mov x0, x20
    bl core_errno_exc_name
    mov x1, x0
    mov x0, x19
    bl tc_cat_cstr
    LEA x1, s_exc_errno_pre  // ": [Errno "
    bl tc_cat_cstr
    mov x22, x0
    // the errno number
    mov x1, x20
    bl core_fmt_u64
    LEA x1, s_exc_errno_post  // "] "
    bl tc_cat_cstr
    mov x22, x0
    mov x0, x20
    bl strerror
    mov x1, x0
    mov x0, x22
    bl tc_cat_cstr
    LEA x1, s_exc_path_pre  // ": '"
    bl tc_cat_cstr
    mov x1, x21
    bl tc_cat_cstr
    mov w1, #'\''
    strb w1, [x0], #1
    strb wzr, [x0]
    mov x0, x19
    EPILOGUE 2
    ret

// core_errno_exc_name(x0=errno) -> x0 = the OSError subclass Python raises for it
// (the errno values below are the same on Darwin and Linux)
    .p2align 2
core_errno_exc_name:
    cmp x0, #1                          // EPERM
    b.eq .Leen_perm
    cmp x0, #13                         // EACCES
    b.eq .Leen_perm
    cmp x0, #2                          // ENOENT
    b.eq .Leen_notfound
    cmp x0, #21                         // EISDIR
    b.eq .Leen_isdir
    cmp x0, #20                         // ENOTDIR
    b.eq .Leen_notdir
    cmp x0, #17                         // EEXIST
    b.eq .Leen_exists
    cmp x0, #4                          // EINTR
    b.eq .Leen_intr
    cmp x0, #32                         // EPIPE
    b.eq .Leen_pipe
    LEA x0, s_exc_oserror
    ret
.Leen_perm:
    LEA x0, s_exc_perm
    ret
.Leen_notfound:
    LEA x0, s_exc_notfound
    ret
.Leen_isdir:
    LEA x0, s_exc_isdir
    ret
.Leen_notdir:
    LEA x0, s_exc_notdir
    ret
.Leen_exists:
    LEA x0, s_exc_exists
    ret
.Leen_intr:
    LEA x0, s_exc_intr
    ret
.Leen_pipe:
    LEA x0, s_exc_pipe
    ret

// core_fmt_u64(x0=cursor, x1=value) -> x0 = cursor after the decimal digits
    .p2align 2
core_fmt_u64:
    sub sp, sp, #32
    add x9, sp, #31
    mov x10, #0                         // digit count
    mov x11, x1
.Lcfu_gen:
    mov x12, #10
    udiv x13, x11, x12
    msub x14, x13, x12, x11
    add x14, x14, #'0'
    strb w14, [x9]
    sub x9, x9, #1
    add x10, x10, #1
    mov x11, x13
    cbnz x11, .Lcfu_gen
.Lcfu_copy:
    cbz x10, .Lcfu_done
    ldrb w14, [x9, #1]!
    strb w14, [x0], #1
    sub x10, x10, #1
    b .Lcfu_copy
.Lcfu_done:
    strb wzr, [x0]
    add sp, sp, #32
    ret

    RODATA
s_exc_sep:          .asciz ": "
s_exc_errno_pre:    .asciz ": [Errno "
s_exc_errno_post:   .asciz "] "
s_exc_path_pre:     .asciz ": '"
s_exc_oserror:      .asciz "OSError"
s_exc_perm:         .asciz "PermissionError"
s_exc_notfound:     .asciz "FileNotFoundError"
s_exc_isdir:        .asciz "IsADirectoryError"
s_exc_notdir:       .asciz "NotADirectoryError"
s_exc_exists:       .asciz "FileExistsError"
s_exc_intr:         .asciz "InterruptedError"
s_exc_pipe:         .asciz "BrokenPipeError"
    .text

    .p2align 2
core_record_unreadable:
    LEA x2, tc_tally
    ldr x3, [x2, #TC_T_UNR_COUNT]
    ldr x4, =TC_T_UNR_MAX
    cmp x3, x4
    b.ge .Lru_done
    add x4, x2, #TC_T_UNR_ENTRIES
    mov x5, #TC_T_UNR_ENTRY_SZ
    mul x5, x3, x5
    add x4, x4, x5
    mov x6, #0
.Lru_name:
    cmp x6, #(TC_T_UNR_NAME_SZ - 1)
    b.ge .Lru_name_done
    ldrb w7, [x0, x6]
    strb w7, [x4, x6]
    cbz w7, .Lru_name_done
    add x6, x6, #1
    b .Lru_name
.Lru_name_done:
    mov w7, #0
    strb w7, [x4, x6]
    add x4, x4, #TC_T_UNR_NAME_SZ
    mov x6, #0
.Lru_reason:
    cmp x6, #(TC_T_UNR_REASON_SZ - 1)
    b.ge .Lru_reason_done
    ldrb w7, [x1, x6]
    strb w7, [x4, x6]
    cbz w7, .Lru_reason_done
    add x6, x6, #1
    b .Lru_reason
.Lru_reason_done:
    mov w7, #0
    strb w7, [x4, x6]
    add x3, x3, #1
    str x3, [x2, #TC_T_UNR_COUNT]
.Lru_done:
    ret

// ============================================================================
// core_seed_state — the live/offline state in force when the range opens.
//   Walks back through files whose date < begin.date(), newest first, at most
//   seed_lookback of them; returns the LAST marker found in the first such
//   file that has any (0 = unknown).  Unreadable files are skipped.
// ============================================================================
    .p2align 2
core_seed_state:
    PROLOGUE 5
    LEA x19, tc_listing
    ldr x20, [x19, #TC_L_COUNT]
    ldr x21, [x19, #TC_L_ENTRIES]
    LEA x22, tc_window
    ldr x23, [x22, #TC_W_BEGIN_YMD]
    mov x24, #0                         // idx
.Lss_find:
    cmp x24, x20
    b.ge .Lss_none
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x24, x9
    add x9, x21, x9
    ldr x10, [x9, #TC_L_YMD]
    cmp x10, x23
    b.ge .Lss_found
    add x24, x24, #1
    b .Lss_find
.Lss_none:
    mov x0, #0
    b .Lss_out
.Lss_found:
    sub x24, x24, #1                     // newest file before begin.date()
    cmp x24, #0
    b.lt .Lss_none2
    LEA x25, tc_opts
    ldr x26, [x25, #TC_O_SEED_LOOKBACK]
    sub x27, x24, x26
    add x27, x27, #1                     // limit = start - (lookback - 1)
    cmp x27, #0
    b.ge .Lss_lim_ok
    mov x27, #0
.Lss_lim_ok:
    mov x28, #0                          // found state
.Lss_loop:
    cmp x24, x27
    b.lt .Lss_none2
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x24, x9
    add x9, x21, x9                      // entry
    // build the file path
    LEA x0, core_fpath
    LEA x1, core_dirpath
    bl tc_cat_cstr
    mov w2, #'/'
    strb w2, [x0], #1
    mov x10, x0
    add x1, x9, #TC_L_NAME
    mov x0, x10
    bl tc_cat_cstr
    LEA x0, core_fpath
    bl core_read_file                      // x0=status, x1=buf, x2=len
    cbnz x0, .Lss_next
    // keep buf/len on the stack: core_scan_markers may clobber x9-x17
    stp x1, x2, [sp, #-16]!
    mov x0, x1
    mov x1, x2
    bl core_scan_markers                      // x0 = last marker state 0/1/2
    mov x28, x0
    ldr x0, [sp]
    bl free
    add sp, sp, #16
    cbnz x28, .Lss_found_state
    b .Lss_next
.Lss_next:
    sub x24, x24, #1
    b .Lss_loop
.Lss_found_state:
    mov x0, x28
    b .Lss_out
.Lss_none2:
    mov x0, #0
.Lss_out:
    EPILOGUE 5
    ret

// ============================================================================
// core_read_file(x0=path) -> x0 = status (0 ok, 1 too large, 2 error),
//   x1 = malloc'd buffer (caller frees; 0 on early error), x2 = bytes read.
// ============================================================================
    .p2align 2
core_read_file:
    PROLOGUE 3
    mov x19, x0                         // path
    mov x0, x19
    mov x1, #O_RDONLY
    bl open
    cmp x0, #0
    b.lt .Lrf_open_fail
    mov x20, x0                         // fd
    mov x0, #READ_CHUNK
    bl malloc
    cbz x0, .Lrf_alloc_fail
    mov x21, x0                         // buf
    mov x22, #READ_CHUNK                // cap
    mov x23, #0                         // total (callee-saved: survives calls)
.Lrf_loop:
    cmp x23, x22
    b.lt .Lrf_read
    // grow
    lsl x22, x22, #1
    ldr x10, =FILE_CAP
    cmp x22, x10
    b.lt .Lrf_grow_ok
    mov x22, x10
    add x22, x22, #1                    // probe byte past the cap
.Lrf_grow_ok:
    cmp x22, x23
    b.le .Lrf_large
    mov x0, x21
    mov x1, x22
    bl realloc
    cbz x0, .Lrf_alloc_fail2
    mov x21, x0
.Lrf_read:
    mov x0, x20
    mov x1, x21
    add x1, x1, x23
    sub x2, x22, x23
    bl read
    cmp x0, #0
    b.lt .Lrf_retry
    b.eq .Lrf_done
    add x23, x23, x0
    ldr x10, =FILE_CAP
    cmp x23, x10
    b.gt .Lrf_large
    b .Lrf_loop
.Lrf_retry:
    // read() returned -1; consult errno (its VALUE, not a return code — the
    // old `ldr x2, =EINTR` / cmp against read()'s x0 here compared a return
    // code against errno's numeric value and could never match on either
    // platform).  fd/buf/cap/total live in x19-x23 (path is x19), all
    // callee-saved, so they need no manual spill across this call: it
    // clobbers only x0-x17 like any libc call.
    bl __errno_location                // x0 = &errno
    ldr w0, [x0]
    LEA x9, tc_last_errno  // read() failed (e.g. EISDIR): keep / the reason before close()/free()
    str x0, [x9]                       // can clobber errno
    cmp w0, #EINTR
    b.eq .Lrf_read
    b .Lrf_read_err
.Lrf_done:
    mov x0, x20
    bl close
    mov x0, #0
    mov x1, x21
    mov x2, x23
    EPILOGUE 3
    ret
.Lrf_large:
    mov x0, x20
    bl close
    mov x0, #1
    mov x1, x21
    mov x2, x23
    EPILOGUE 3
    ret
.Lrf_read_err:
    mov x0, x20
    bl close
    mov x0, x21
    bl free
    mov x0, #2
    mov x1, #0
    mov x2, #0
    EPILOGUE 3
    ret
.Lrf_open_fail:
    bl tc_capture_errno                 // open() failed: the reason
    mov x0, #2
    mov x1, #0
    mov x2, #0
    EPILOGUE 3
    ret
.Lrf_alloc_fail:
    mov x0, x20
    bl close
    mov x0, #2
    mov x1, #0
    mov x2, #0
    EPILOGUE 3
    ret
.Lrf_alloc_fail2:
    mov x0, x20
    bl close
    mov x0, x21
    bl free
    mov x0, #2
    mov x1, #0
    mov x2, #0
    EPILOGUE 3
    ret

// ============================================================================
// core_has_newline(x0=buf, x1=len) -> x0 = 1 when the buffer holds a '\n'.
// ============================================================================
    .p2align 2
core_has_newline:
    mov x2, #0
.Lhn:
    cmp x2, x1
    b.ge .Lhn_no
    ldrb w3, [x0, x2]
    cmp w3, #'\n'
    b.eq .Lhn_yes
    add x2, x2, #1
    b .Lhn
.Lhn_yes:
    mov x0, #1
    ret
.Lhn_no:
    mov x0, #0
    ret

// ============================================================================
// core_scan_markers(x0=buf, x1=len) -> x0 = the LAST marker state (1 live, 2
//   offline, 0 none).  Processes every line including a partial final line,
//   exactly as the Python's seed loop does.
// ============================================================================
    .p2align 2
core_scan_markers:
    PROLOGUE 4
    mov x19, x0                         // buf
    add x20, x19, x1                    // end
    mov x21, #0                         // state
    mov x22, x19                        // line start
.Lsm_loop:
    cmp x22, x20
    b.ge .Lsm_done
    mov x23, x22
    mov x25, #0                          // newline-found flag
.Lsm_find:
    cmp x23, x20
    b.ge .Lsm_line                      // partial final line
    ldrb w3, [x23]
    add x23, x23, #1
    cmp w3, #'\n'
    b.ne .Lsm_find
    mov x25, #1
.Lsm_line:
    sub x24, x23, x22                   // line len (incl '\n' when found)
    cbz x25, .Lsm_line_len_ok
    sub x24, x24, #1
.Lsm_line_len_ok:
    cbz x24, .Lsm_next
    mov x0, x22
    mov x1, x24
    bl core_line_is_marker
    cbz x0, .Lsm_next
    mov x21, x0
.Lsm_next:
    mov x22, x23
    b .Lsm_loop
.Lsm_done:
    mov x0, x21
    EPILOGUE 4
    ret

// ============================================================================
// core_line_is_marker(x0=line, x1=len) -> x0 = 1 (live), 2 (offline), or 0.
// ============================================================================
    .p2align 2
core_line_is_marker:
    PROLOGUE 1
    mov x19, x0
    mov x20, x1
    cmp x1, #11
    b.lt .Llim_no
    ldrb w2, [x0]
    cmp w2, #'['
    b.ne .Llim_no
    ldrb w2, [x0, #1]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #2]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #3]
    cmp w2, #':'
    b.ne .Llim_no
    ldrb w2, [x0, #4]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #5]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #6]
    cmp w2, #':'
    b.ne .Llim_no
    ldrb w2, [x0, #7]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #8]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #9]
    cmp w2, #']'
    b.ne .Llim_no
    ldrb w2, [x0, #10]
    cmp w2, #' '
    b.ne .Llim_no
    mov x0, x19
    mov x1, x20
    LEA x2, lit_is_live
    mov x3, #8
    bl core_marker_match
    cbnz x0, .Llim_live
    mov x0, x19
    mov x1, x20
    LEA x2, lit_is_offline
    mov x3, #15
    bl core_marker_match
    cbnz x0, .Llim_off
.Llim_no:
    mov x0, #0
    EPILOGUE 1
    ret
.Llim_live:
    mov x0, #1
    EPILOGUE 1
    ret
.Llim_off:
    mov x0, #2
    EPILOGUE 1
    ret

// ============================================================================
// core_marker_match(x0=line, x1=len, x2=literal, x3=litlen) -> x0 = 1 when the
//   line ends with the literal, preceded by a space and a non-empty,
//   space-free token: "[HH:MM:SS] <token> <literal>".
// ============================================================================
    .p2align 2
core_marker_match:
    mov x4, x3
    cmp x1, x4
    b.lt .Lmm_no
    add x5, x0, x1                      // line end
    sub x6, x5, x4                      // literal start
    mov x7, #0
.Lmm_cmp:
    cmp x7, x4
    b.ge .Lmm_cmp_ok
    ldrb w8, [x6, x7]
    ldrb w9, [x2, x7]
    cmp w8, w9
    b.ne .Lmm_no
    add x7, x7, #1
    b .Lmm_cmp
.Lmm_cmp_ok:
    sub x7, x5, x4
    sub x7, x7, #1
    ldrb w8, [x7]
    cmp w8, #' '
    b.ne .Lmm_no
    sub x9, x1, x4
    sub x9, x9, #12                     // token length
    cmp x9, #1
    b.lt .Lmm_no
    add x10, x0, #11                    // token start
    mov x11, #0
.Lmm_tok:
    cmp x11, x9
    b.ge .Lmm_yes
    ldrb w12, [x10, x11]
    cmp w12, #' '
    b.eq .Lmm_no
    add x11, x11, #1
    b .Lmm_tok
.Lmm_yes:
    mov x0, #1
    ret
.Lmm_no:
    mov x0, #0
    ret

// ============================================================================
// core_process_lines(x0=buf, x1=len, x2=lo, x3=hi) — fold one file's complete
//   lines (the partial tail is dropped, as in the Python).  Updates the
//   global cur_state from markers and counts in-window messages.
// ============================================================================
    .p2align 2
core_process_lines:
    PROLOGUE 5
    mov x19, x0                         // buf
    add x20, x19, x1                    // end
    mov x21, x2                         // lo
    mov x22, x3                         // hi
    LEA x23, core_cur_state
    ldr x23, [x23]                      // cur_state (0/1/2)
    // one past the last '\n'
    mov x24, x19
    mov x25, x19
.Lpl_find_last:
    cmp x24, x20
    b.ge .Lpl_last_done
    ldrb w3, [x24]
    cmp w3, #'\n'
    b.ne .Lpl_last_next
    add x25, x24, #1
.Lpl_last_next:
    add x24, x24, #1
    b .Lpl_find_last
.Lpl_last_done:
    mov x24, x19                        // line start
.Lpl_loop:
    cmp x24, x25
    b.ge .Lpl_done
    mov x26, x24
.Lpl_nl:
    cmp x26, x25
    b.ge .Lpl_line
    ldrb w3, [x26]
    add x26, x26, #1
    cmp w3, #'\n'
    b.ne .Lpl_nl
.Lpl_line:
    sub x27, x26, x24                   // line len incl '\n'
    sub x27, x27, #1                    // line len excl '\n'
    sub x26, x26, #1                    // point at '\n'
    cbz x27, .Lpl_next
    ldrb w3, [x24]
    cmp w3, #'#'
    b.eq .Lpl_next
    mov x0, x24
    mov x1, x27
    bl core_line_is_marker
    cbnz x0, .Lpl_marker
    mov x0, x24
    mov x1, x27
    mov x2, x21
    mov x3, x22
    mov x4, x23
    bl core_process_message
    b .Lpl_next
.Lpl_marker:
    mov x23, x0
.Lpl_next:
    add x24, x26, #1
    b .Lpl_loop
.Lpl_done:
    LEA x9, core_cur_state
    str x23, [x9]
    EPILOGUE 5
    ret

// ============================================================================
// core_process_message(x0=line, x1=len, x2=lo, x3=hi, x4=state) -> x0 = 1 if the
//   message was counted.  The speaker is classified by core_speaker_login; the
//   state (0 = unknown) becomes TC_ST_UNKNOWN for the count.
// ============================================================================
    .p2align 2
core_process_message:
    PROLOGUE 4
    mov x19, x0                         // line
    mov x20, x1                         // len
    mov x21, x2                         // lo
    mov x22, x3                         // hi
    mov x23, x4                         // state
    cmp x20, #11
    b.lt .Lpm_skip
    ldrb w3, [x19]
    cmp w3, #'['
    b.ne .Lpm_skip
    ldrb w3, [x19, #1]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #2]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #3]
    cmp w3, #':'
    b.ne .Lpm_skip
    ldrb w3, [x19, #4]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #5]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #6]
    cmp w3, #':'
    b.ne .Lpm_skip
    ldrb w3, [x19, #7]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #8]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #9]
    cmp w3, #']'
    b.ne .Lpm_skip
    ldrb w3, [x19, #10]
    cmp w3, #' '
    b.ne .Lpm_skip
    // find the first ": " in the rest
    add x24, x19, #11
    add x3, x19, x20
.Lpm_find_colon:
    cmp x24, x3
    b.ge .Lpm_skip
    ldrb w4, [x24]
    add x24, x24, #1
    cmp w4, #':'
    b.ne .Lpm_find_colon
    cmp x24, x3
    b.ge .Lpm_skip
    ldrb w4, [x24]
    cmp w4, #' '
    b.ne .Lpm_find_colon
    // colon at x24-1; speaker = [line+11, x24-1)
    sub x24, x24, #1
    sub x25, x24, x19
    sub x25, x25, #11                   // speaker len
    cbz x25, .Lpm_skip
    add x4, x19, #11
    mov x5, #0
.Lpm_spk:
    cmp x5, x25
    b.ge .Lpm_spk_ok
    ldrb w6, [x4, x5]
    cmp w6, #':'
    b.eq .Lpm_skip
    add x5, x5, #1
    b .Lpm_spk
.Lpm_spk_ok:
    // second-of-day from line[1..8]
    ldrb w6, [x19, #1]
    sub w6, w6, #'0'
    mov x7, #10
    mul x7, x6, x7
    ldrb w6, [x19, #2]
    sub w6, w6, #'0'
    add x7, x7, x6                      // h
    mov x8, #SECS_PER_HOUR
    mul x7, x7, x8
    ldrb w6, [x19, #4]
    sub w6, w6, #'0'
    mov x9, #10
    mul x9, x6, x9
    ldrb w6, [x19, #5]
    sub w6, w6, #'0'
    add x9, x9, x6                      // m
    mov x10, #60
    mul x9, x9, x10
    add x7, x7, x9
    ldrb w6, [x19, #7]
    sub w6, w6, #'0'
    mov x10, #10
    mul x10, x6, x10
    ldrb w6, [x19, #8]
    sub w6, w6, #'0'
    add x10, x10, x6                    // s
    add x26, x7, x10                    // second
    // clip to [lo, hi]
    cmp x26, x21
    b.lt .Lpm_skip
    cmp x26, x22
    b.gt .Lpm_skip
    // speaker login
    mov x0, x4
    mov x1, x25
    bl core_speaker_login                    // x0 = login ptr or 0, x1 = login len
    cbz x0, .Lpm_skip
    mov x24, x0                         // login ptr
    mov x25, x1                         // login len
    mov x26, x23                        // state survives the table calls
    cbnz x26, .Lpm_state_set
    mov x26, #TC_ST_UNKNOWN
.Lpm_state_set:
    mov x0, x24
    mov x1, x25
    LEA x2, tc_users
    bl tc_find_user                        // x0 = index or -1
    cmp x0, #0
    b.ge .Lpm_have_user
    mov x0, x24
    mov x1, x25
    LEA x2, tc_users
    bl tc_add_user                         // x0 = index
.Lpm_have_user:
    // entry = users.entries + index*50
    LEA x9, tc_users
    ldr x10, [x9, #TC_US_ENTRIES]
    mov x11, #TC_US_ENTRY_SZ
    mul x11, x0, x11
    add x10, x10, x11                   // entry
    cmp x26, #TC_ST_LIVE
    b.eq .Lpm_inc_live
    cmp x26, #TC_ST_OFFLINE
    b.eq .Lpm_inc_off
    b .Lpm_inc_unk
.Lpm_inc_live:
    ldr x11, [x10, #TC_US_LIVE]
    add x11, x11, #1
    str x11, [x10, #TC_US_LIVE]
    LEA x12, core_g_live
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_counted
.Lpm_inc_off:
    ldr x11, [x10, #TC_US_OFFLINE]
    add x11, x11, #1
    str x11, [x10, #TC_US_OFFLINE]
    LEA x12, core_g_off
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_counted
.Lpm_inc_unk:
    ldr x11, [x10, #TC_US_UNKNOWN]
    add x11, x11, #1
    str x11, [x10, #TC_US_UNKNOWN]
    LEA x12, core_g_unk
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
.Lpm_counted:
    mov x0, #1
    b .Lpm_out
.Lpm_skip:
    mov x0, #0
.Lpm_out:
    EPILOGUE 4
    ret

// ============================================================================
// core_speaker_login(x0=speaker, x1=slen) -> x0 = login_buf ptr, x1 = login len,
//   or x0 = 0 when the speaker is not a real chatter.  LOGIN_RE first, then
//   LOCALIZED_RE with a non-ASCII display byte.
// ============================================================================
    .p2align 2
core_speaker_login:
    PROLOGUE 0
    // LOGIN_RE: ^[A-Za-z0-9_]{1,25}$
    cmp x1, #1
    b.lt .Lsl_fail
    cmp x1, #25
    b.gt .Lsl_localized
    mov x2, #0
.Lsl_login:
    cmp x2, x1
    b.ge .Lsl_login_ok
    ldrb w3, [x0, x2]
    bl core_is_login_char
    b.ne .Lsl_localized
    add x2, x2, #1
    b .Lsl_login
.Lsl_login_ok:
    // lowercase into login_buf
    LEA x4, core_login
    mov x2, #0
.Lsl_lower:
    cmp x2, x1
    b.ge .Lsl_lower_done
    ldrb w3, [x0, x2]
    cmp w3, #'A'
    b.lt .Lsl_lstore
    cmp w3, #'Z'
    b.gt .Lsl_lstore
    add w3, w3, #('a' - 'A')
.Lsl_lstore:
    strb w3, [x4, x2]
    add x2, x2, #1
    b .Lsl_lower
.Lsl_lower_done:
    mov w3, #0
    strb w3, [x4, x2]
    mov x0, x4
    EPILOGUE 0
    ret
.Lsl_localized:
    // LOCALIZED_RE: ^(\S+) ([a-z0-9_]{1,25})$ with a non-ASCII display
    // find the LAST space
    mov x2, #0
    mov x3, #-1                         // last space index
.Lsl_find_sp:
    cmp x2, x1
    b.ge .Lsl_sp_found
    ldrb w4, [x0, x2]
    cmp w4, #' '
    b.ne .Lsl_sp_next
    mov x3, x2
.Lsl_sp_next:
    add x2, x2, #1
    b .Lsl_find_sp
.Lsl_sp_found:
    cmp x3, #0
    b.lt .Lsl_fail                      // no space
    cbz x3, .Lsl_fail                   // empty display
    mov x6, x3                          // space index
    // right part = [x6+1, x1): [a-z0-9_]{1,25}
    sub x4, x1, x6
    sub x4, x4, #1                      // right len
    cmp x4, #1
    b.lt .Lsl_fail
    cmp x4, #25
    b.gt .Lsl_fail
    add x5, x0, x6
    add x5, x5, #1                      // right start
    mov x2, #0
.Lsl_right:
    cmp x2, x4
    b.ge .Lsl_right_ok
    ldrb w3, [x5, x2]
    bl core_is_lower_login_char
    b.ne .Lsl_fail
    add x2, x2, #1
    b .Lsl_right
.Lsl_right_ok:
    // left part = [0, x6): no space/tab, and contains a byte > 127
    mov x2, #0
    mov x7, #0                          // has non-ascii
.Lsl_left:
    cmp x2, x6
    b.ge .Lsl_left_ok
    ldrb w3, [x0, x2]
    cmp w3, #' '
    b.eq .Lsl_fail
    cmp w3, #9
    b.eq .Lsl_fail
    cmp w3, #128
    b.lt .Lsl_left_next
    mov x7, #1
.Lsl_left_next:
    add x2, x2, #1
    b .Lsl_left
.Lsl_left_ok:
    cbz x7, .Lsl_fail
    // login = right (already lowercase); copy into login_buf
    LEA x8, core_login
    mov x2, #0
.Lsl_copy:
    cmp x2, x4
    b.ge .Lsl_copy_done
    ldrb w7, [x5, x2]
    strb w7, [x8, x2]
    add x2, x2, #1
    b .Lsl_copy
.Lsl_copy_done:
    mov w7, #0
    strb w7, [x8, x4]
    mov x0, x8
    EPILOGUE 0
    ret
.Lsl_fail:
    mov x0, #0
    EPILOGUE 0
    ret

// core_is_login_char — sets EQ iff w3 is in [A-Za-z0-9_] (used as a predicate)
    .p2align 2
core_is_login_char:
    cmp w3, #'0'
    b.lt .Lilc_no
    cmp w3, #'9'
    b.le .Lilc_yes
    cmp w3, #'A'
    b.lt .Lilc_no
    cmp w3, #'Z'
    b.le .Lilc_yes
    cmp w3, #'_'
    b.eq .Lilc_yes
    cmp w3, #'a'
    b.lt .Lilc_no
    cmp w3, #'z'
    b.le .Lilc_yes
.Lilc_no:
    cmp w3, #-1                         // force Z=0
    ret
.Lilc_yes:
    cmp w3, w3                          // force Z=1
    ret

// core_is_lower_login_char — like core_is_login_char but only [a-z0-9_]
    .p2align 2
core_is_lower_login_char:
    cmp w3, #'0'
    b.lt .Lilc2_no
    cmp w3, #'9'
    b.le .Lilc2_yes
    cmp w3, #'_'
    b.eq .Lilc2_yes
    cmp w3, #'a'
    b.lt .Lilc2_no
    cmp w3, #'z'
    b.le .Lilc2_yes
.Lilc2_no:
    cmp w3, #-1                         // force Z=0
    ret
.Lilc2_yes:
    cmp w3, w3                          // force Z=1
    ret

// ============================================================================
// tc_find_user(x0=login, x1=len, x2=table_base) -> x0 = index, or -1.
//   The base is passed in x2 (tc_users for the counting pass, a
//   caller's table for the cache module).  Exported for tc_cache.S.
// ============================================================================
    .p2align 2
    .global tc_find_user
    FUNC_TYPE(tc_find_user)
tc_find_user:
    ldr x3, [x2, #TC_US_ENTRIES]
    ldr x4, [x2, #TC_US_COUNT]
    mov x5, #0
.Lfu_loop:
    cmp x5, x4
    b.ge .Lfu_notfound
    mov x6, #TC_US_ENTRY_SZ
    mul x6, x5, x6
    add x6, x3, x6                      // entry
    mov x7, #0
.Lfu_cmp:
    cmp x7, x1
    b.ge .Lfu_cmp_nul
    ldrb w8, [x6, x7]
    ldrb w9, [x0, x7]
    cmp w8, w9
    b.ne .Lfu_next
    add x7, x7, #1
    b .Lfu_cmp
.Lfu_cmp_nul:
    ldrb w8, [x6, x7]
    cbnz w8, .Lfu_next
    mov x0, x5
    ret
.Lfu_next:
    add x5, x5, #1
    b .Lfu_loop
.Lfu_notfound:
    mov x0, #-1
    ret

// ============================================================================
// tc_add_user(x0=login, x1=len, x2=table_base) -> x0 = index (grows the entry
//   array).  The base is passed in x2.  Exported for tc_cache.S.
// ============================================================================
    .p2align 2
    .global tc_add_user
    FUNC_TYPE(tc_add_user)
tc_add_user:
    PROLOGUE 3
    mov x19, x0                         // login
    mov x20, x1                         // len
    mov x21, x2                         // table base
    ldr x22, [x21, #TC_US_COUNT]
    ldr x0, [x21, #TC_US_CAP]
    cmp x22, x0
    b.lt .Lau_append
    cbz x0, .Lau_new
    lsl x0, x0, #1
    b .Lau_alloc
.Lau_new:
    mov x0, #USERS_INIT
.Lau_alloc:
    // Fix: the new capacity is held in x23 (callee-saved) across the
    // realloc() call, NOT x6 — realloc clobbers caller-saved registers, so
    // the old code stored a garbage capacity and the user table stopped
    // growing (a run with >54 distinct users overflowed the entries array
    // and segfaulted; the cap became a huge stale value, so the count could
    // never trigger another growth).
    mov x23, x0                         // new cap (survives realloc)
    mov x5, #TC_US_ENTRY_SZ
    mul x5, x0, x5
    mov x1, x5
    ldr x0, [x21, #TC_US_ENTRIES]
    bl realloc
    cbz x0, .Lau_oom
    str x0, [x21, #TC_US_ENTRIES]
    str x23, [x21, #TC_US_CAP]
.Lau_append:
    ldr x3, [x21, #TC_US_COUNT]
    ldr x4, [x21, #TC_US_ENTRIES]
    mov x5, #TC_US_ENTRY_SZ
    mul x5, x3, x5
    add x4, x4, x5                      // entry
    mov x6, #0
.Lau_copy:
    cmp x6, x20
    b.ge .Lau_copy_done
    ldrb w7, [x19, x6]
    strb w7, [x4, x6]
    add x6, x6, #1
    b .Lau_copy
.Lau_copy_done:
    mov w7, #0
    strb w7, [x4, x6]
    str xzr, [x4, #TC_US_LIVE]
    str xzr, [x4, #TC_US_OFFLINE]
    str xzr, [x4, #TC_US_UNKNOWN]
    add x3, x3, #1
    str x3, [x21, #TC_US_COUNT]
    sub x0, x3, #1
    EPILOGUE 3
    ret
.Lau_oom:
    LEA x0, s_oom
    bl tc_fail

// ============================================================================
// tc_reuse_apply(x0=login, x1=len, x2=state, x3=n) -> x0 = 0
//   Add n to the user entry's state bucket and the matching all-state total
//   (tc_core_g_*).  This is core_process_message's increment section, exported so
//   the rollup cache (tc_cache.S) can serve a whole cached day into the same
//   tables the counting pass fills.  state is TC_ST_LIVE/OFFLINE/UNKNOWN.
// ============================================================================
    .p2align 2
    .global tc_reuse_apply
    FUNC_TYPE(tc_reuse_apply)
tc_reuse_apply:
    PROLOGUE 2
    mov x19, x0                         // login
    mov x20, x1                         // len
    mov x21, x2                         // state
    mov x22, x3                         // n
    LEA x2, tc_users
    mov x0, x19
    mov x1, x20
    bl tc_find_user                        // x0 = index or -1
    cmp x0, #0
    b.ge .Lrua_have
    mov x0, x19
    mov x1, x20
    LEA x2, tc_users
    bl tc_add_user                         // x0 = index
.Lrua_have:
    // entry = users.entries + index*50
    LEA x9, tc_users
    ldr x10, [x9, #TC_US_ENTRIES]
    mov x11, #TC_US_ENTRY_SZ
    mul x11, x0, x11
    add x10, x10, x11                   // entry
    cmp x21, #TC_ST_LIVE
    b.eq .Lrua_live
    cmp x21, #TC_ST_OFFLINE
    b.eq .Lrua_off
    b .Lrua_unk
.Lrua_live:
    ldr x11, [x10, #TC_US_LIVE]
    add x11, x11, x22
    str x11, [x10, #TC_US_LIVE]
    LEA x12, core_g_live
    ldr x13, [x12]
    add x13, x13, x22
    str x13, [x12]
    b .Lrua_done
.Lrua_off:
    ldr x11, [x10, #TC_US_OFFLINE]
    add x11, x11, x22
    str x11, [x10, #TC_US_OFFLINE]
    LEA x12, core_g_off
    ldr x13, [x12]
    add x13, x13, x22
    str x13, [x12]
    b .Lrua_done
.Lrua_unk:
    ldr x11, [x10, #TC_US_UNKNOWN]
    add x11, x11, x22
    str x11, [x10, #TC_US_UNKNOWN]
    LEA x12, core_g_unk
    ldr x13, [x12]
    add x13, x13, x22
    str x13, [x12]
.Lrua_done:
    mov x0, #0
    EPILOGUE 2
    ret

// ============================================================================
// core_sort_dnames — insertion sort the core_dnames pointer array by string.
// ============================================================================
    .p2align 2
core_sort_dnames:
    PROLOGUE 3
    LEA x19, core_dnames
    LEA x20, core_dname_count
    ldr x20, [x20]
    mov x21, #1
.Lsd_outer:
    cmp x21, x20
    b.ge .Lsd_done
    ldr x22, [x19, x21, lsl #3]         // key
    mov x23, x21
.Lsd_inner:
    cbz x23, .Lsd_place
    sub x24, x23, #1
    ldr x25, [x19, x24, lsl #3]         // previous
    mov x0, x25
    mov x1, x22
    bl strcmp                        // musl returns a 32-bit int
    cmp w0, #0
    b.le .Lsd_place
    str x25, [x19, x23, lsl #3]
    mov x23, x24
    b .Lsd_inner
.Lsd_place:
    str x22, [x19, x23, lsl #3]
    add x21, x21, #1
    b .Lsd_outer
.Lsd_done:
    EPILOGUE 3
    ret

// ============================================================================
// core_sort_listing — insertion sort tc_listing entries by (ymd, name) ascending
//   (the name tiebreak mirrors Python's sorted((date, path))).
// ============================================================================
    .p2align 2
core_sort_listing:
    PROLOGUE 4
    LEA x19, tc_listing
    ldr x20, [x19, #TC_L_COUNT]
    ldr x21, [x19, #TC_L_ENTRIES]
    mov x22, #1
.Lsl_outer:
    cmp x22, x20
    b.ge .Lsl_done
    // key = entry x22, copied into core_list_key
    mov x23, #TC_L_ENTRY_SZ
    mul x23, x22, x23
    add x23, x21, x23
    LEA x24, core_list_key
    mov x9, #0
.Lsl_save:
    cmp x9, #TC_L_ENTRY_SZ
    b.ge .Lsl_save_done
    ldrb w10, [x23, x9]
    strb w10, [x24, x9]
    add x9, x9, #1
    b .Lsl_save
.Lsl_save_done:
    mov x25, x22                        // j
.Lsl_inner:
    cbz x25, .Lsl_place
    sub x26, x25, #1
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x26, x9
    add x9, x21, x9                     // prev
    ldr x10, [x24]                      // key ymd
    ldr x11, [x9]                       // prev ymd
    cmp x11, x10
    b.lt .Lsl_place
    b.gt .Lsl_shift
    add x11, x9, #TC_L_NAME
    add x12, x24, #TC_L_NAME
    mov x0, x11
    mov x1, x12
    bl strcmp
    cmp w0, #0
    b.le .Lsl_place
.Lsl_shift:
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x25, x9
    add x9, x21, x9                     // dest
    mov x10, #TC_L_ENTRY_SZ
    mul x10, x26, x10
    add x10, x21, x10                   // src
    mov x11, #0
.Lsl_shift_loop:
    cmp x11, #TC_L_ENTRY_SZ
    b.ge .Lsl_shift_done
    ldrb w12, [x10, x11]
    strb w12, [x9, x11]
    add x11, x11, #1
    b .Lsl_shift_loop
.Lsl_shift_done:
    mov x25, x26
    b .Lsl_inner
.Lsl_place:
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x25, x9
    add x9, x21, x9
    mov x10, #0
.Lslc_copy:
    cmp x10, #TC_L_ENTRY_SZ
    b.ge .Lslc_copy_done
    ldrb w11, [x24, x10]
    strb w11, [x9, x10]
    add x10, x10, #1
    b .Lslc_copy
.Lslc_copy_done:
    add x22, x22, #1
    b .Lsl_outer
.Lsl_done:
    EPILOGUE 4
    ret

// ============================================================================
// core_lowercase_copy(x0=src, x1=dst) — ASCII-lowercase a string into dst.
// ============================================================================
    .p2align 2
core_lowercase_copy:
    mov x2, #0
.Llc2:
    ldrb w3, [x0, x2]
    cmp w3, #'A'
    b.lt .Llc2_store
    cmp w3, #'Z'
    b.gt .Llc2_store
    add w3, w3, #('a' - 'A')
.Llc2_store:
    strb w3, [x1, x2]
    cbz w3, .Llc2_done
    add x2, x2, #1
    cmp x2, #63
    b.lt .Llc2
.Llc2_done:
    mov w3, #0
    strb w3, [x1, x2]
    ret

// ============================================================================
// core_ascii_casecmp(x0=a, x1=b) -> x0 = 0 when a equals b ignoring ASCII
//   case (b is expected to be already lowercased).
// ============================================================================
    .p2align 2
core_ascii_casecmp:
    mov x2, #0
.Lacc_loop:
    ldrb w3, [x0, x2]
    ldrb w4, [x1, x2]
    cbz w3, .Lacc_a_end
    cbz w4, .Lacc_neq
    cmp w3, #'A'
    b.lt .Lacc_norm
    cmp w3, #'Z'
    b.gt .Lacc_norm
    add w3, w3, #('a' - 'A')
.Lacc_norm:
    cmp w3, w4
    b.ne .Lacc_neq
    add x2, x2, #1
    b .Lacc_loop
.Lacc_a_end:
    cbz w4, .Lacc_eq
.Lacc_neq:
    mov x0, #1
    ret
.Lacc_eq:
    mov x0, #0
    ret

// ============================================================================
// core_copy_str(x0=dst, x1=src) — NUL-terminated string copy.
// ============================================================================
    .p2align 2
core_copy_str:
    mov x2, #0
.Lcs:
    ldrb w3, [x1, x2]
    strb w3, [x0, x2]
    add x2, x2, #1
    cbnz w3, .Lcs
    ret

// ============================================================================
// core_memzero_own(x0=ptr, x1=len)
// ============================================================================
    .p2align 2
core_memzero_own:
    mov x2, #0
.Lmz:
    cbz x1, .Lmz_done
    strb w2, [x0], #1
    sub x1, x1, #1
    b .Lmz
.Lmz_done:
    ret

// ============================================================================
// core_fmt_pad(x0=cursor, x1=value, x2=width) -> x0 = cursor after the digits.
// ============================================================================
    .p2align 2
core_fmt_pad:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    sub sp, sp, #32
    add x22, sp, #31
    mov x23, #0
    mov x3, x20
    cmp x3, #0
    b.ne .Lfp_loop
    mov w4, #'0'
    strb w4, [x22]
    sub x22, x22, #1
    mov x23, #1
    b .Lfp_pad
.Lfp_loop:
    mov x4, #10
    udiv x5, x3, x4
    msub x6, x5, x4, x3
    add x6, x6, #'0'
    strb w6, [x22]
    sub x22, x22, #1
    add x23, x23, #1
    mov x3, x5
    cbnz x3, .Lfp_loop
.Lfp_pad:
    mov x5, x21
    sub x5, x5, x23
.Lfp_pad_go:
    cbz x5, .Lfp_copy
    mov w4, #'0'
    strb w4, [x19], #1
    sub x5, x5, #1
    b .Lfp_pad_go
.Lfp_copy:
    add x22, x22, #1
.Lfp_copy_loop:
    cbz x23, .Lfp_done
    ldrb w4, [x22], #1
    strb w4, [x19], #1
    sub x23, x23, #1
    b .Lfp_copy_loop
.Lfp_done:
    mov x0, x19
    add sp, sp, #32
    EPILOGUE 5
    ret

// ============================================================================
// core_fmt_ymd_sod(x0=ymd, x1=sod, x2=out) -> x0 = cursor after "YYYY-MM-DD
//   HH:MM:SS" (no NUL written).
// ============================================================================
    .p2align 2
core_fmt_ymd_sod:
    PROLOGUE 5
    mov x19, x0                         // ymd
    mov x20, x1                         // sod
    mov x21, x2                         // out
    mov x22, #YMD_YEAR_SCALE
    udiv x23, x19, x22                  // y
    mov x22, #YMD_MONTH_SCALE
    udiv x24, x19, x22
    msub x24, x24, x22, x19             // d
    mov x22, #YMD_YEAR_SCALE
    udiv x25, x19, x22
    mov x26, #YMD_YEAR_SCALE
    mul x25, x25, x26
    sub x25, x19, x25
    mov x26, #YMD_MONTH_SCALE
    udiv x25, x25, x26                  // mo
    mov x0, x21
    mov x1, x23
    mov x2, #4
    bl core_fmt_pad
    mov x21, x0
    mov w0, #'-'
    strb w0, [x21], #1
    mov x0, x21
    mov x1, x25
    mov x2, #2
    bl core_fmt_pad
    mov x21, x0
    mov w0, #'-'
    strb w0, [x21], #1
    mov x0, x21
    mov x1, x24
    mov x2, #2
    bl core_fmt_pad
    mov x21, x0
    mov w0, #' '
    strb w0, [x21], #1
    mov x26, #SECS_PER_HOUR
    udiv x1, x20, x26
    mov x0, x21
    mov x2, #2
    bl core_fmt_pad
    mov x21, x0
    mov w0, #':'
    strb w0, [x21], #1
    mov x23, #60
    udiv x24, x20, x23
    udiv x25, x24, x23
    msub x24, x25, x23, x24             // minutes
    mov x0, x21
    mov x1, x24
    mov x2, #2
    bl core_fmt_pad
    mov x21, x0
    mov w0, #':'
    strb w0, [x21], #1
    mov x23, #60
    udiv x24, x20, x23
    msub x24, x24, x23, x20             // seconds
    mov x0, x21
    mov x1, x24
    mov x2, #2
    bl core_fmt_pad
    mov x21, x0
    mov x0, x21
    EPILOGUE 5
    ret

    .end

