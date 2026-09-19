// ============================================================================
// tc_core.S — channel resolution, log listing, window completion, counting
//             and --users sizing for twitch-counts-full (Phase 4)
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static (musl libc + crt1.o)
//
//  What this module owns (the frozen contract is tc_layout.inc, READ-ONLY)
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
//  Deviation notes (documented for later phases)
//  ---------------------------------------------
//    * Unreadable log files are recorded with the reason "cannot read" or
//      "file too large" (the Python uses exception strings like
//      "PermissionError: ..."; the differential normalizes these).
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
//                                  unfiltered).  Phase 5 needs this for the
//                                  ranking; it is an addition beyond the
//                                  frozen symbol list, documented here.
//    tc_user_state(x0=index, x1=TC_ST_*) -> x0 = that state's count for the
//                                  entry.  Addition (Phase 5 columns).
//
//  Phase 5/6 notes (what the contract does NOT say but this module relies on)
//  -------------------------------------------------------------------------
//    * tc_users entries include EXCLUDED users, with their counts intact.
//      The exclusion subtraction is applied to the TALLY only (states,
//      excluded_states, messages).  Phase 5 must skip excluded entries when
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
//  Phase 6 cache integration (this file is the ONLY place the cache hooks
//  live; tc_cache.S provides the SQLite rollup)
//  -------------------------------------------------------------------------
//    * tc_count_final's loop calls tc_cache_day(fpath, lo, hi, enter_state,
//      ymd) once per in-range file, right after the path is built and before
//      the read.  Result 1 = the day came from the rollup (counts already
//      applied to tc_users + the all-state totals; x1 = cached exit_state):
//      the loop stores it into tc_core_cur_state, bumps TC_T_REUSED and
//      moves on without reading the file.  Result 2 = stat failed: the loop
//      records the file as unreadable and resets the stream state (Python's
//      skip()).  Result 0 = parse normally; if the file was a whole day the
//      cache module stashed a snapshot and tc_cache_put_day writes the day
//      after a successful whole-file parse (no-op otherwise).
//    * The cache module NEVER reads tc_core_cur_state; the loop passes the
//      entering state in and stores the returned exit state itself.
//    * tc_reuse_apply(x0=login, x1=len, x2=TC_ST_*, x3=n) is exported for the
//      cache module: it adds n to one user's state bucket and the matching
//      all-state total, exactly like process_message's increment section.
//    * find_user/add_user gained a third parameter (x2 = table base) so the
//      cache module can reuse the exact table logic; process_message passes
//      the tc_users base.
//    * One-shot runs open/close the cache around tc_count_run (the driver's
//      main).  Watch mode (Wave D/E) opens once per session and keeps the
//      connection; tc_count_final uses whatever tc_cache.S has open.
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
    .globl readdir
    .globl closedir
    .globl open
    .globl close
    .globl read
    .globl strcmp
    .globl tc_strlen
    .globl tc_fail
    .globl tc_civil_from_days
    .globl tc_excl_contains
    // Phase 6: rollup-cache hooks (implemented in tc_cache.S)
    .globl tc_cache_day
    .globl tc_cache_put_day
    .globl tc_cache_discard_day

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ SECS_PER_DAY,    86400
    .equ LAST_SECOND,     86399
    .equ FILE_CAP,        1073741824      // 1 GiB sanity cap (documented)
    .equ O_RDONLY,        0
    .equ DT_DIR,          4
    .equ EINTR,           -4
    .equ MAX_DNAMES,      256
    .equ DNAME_SZ,        256
    .equ READ_CHUNK,      8192
    .equ LISTING_INIT,    64
    .equ USERS_INIT,      64
    .equ CF_ENTRY,        0               // tc_count_final frame slots
    .equ CF_LO,           8
    .equ CF_HI,           16
    .equ CF_CPTR,         24
    .equ CF_BUF,          32              // malloc'd file buffer across calls
    .equ CF_LEN,          40
    .equ CF_FRAME_SZ,     48

// ============================================================================
// .bss — private scratch (NOT part of the frozen contract; the contract
// structures tc_opts/tc_window/tc_users/tc_tally/tc_listing live in tc_cli.S)
// ============================================================================
    .bss
    .p2align 4
tc_core_scratch:    .skip 2048          // error-message composition buffer
tc_core_fmt:        .skip 64            // datetime formatting buffer
tc_core_login:      .skip 32            // speaker_login output (<= 25 + NUL)
tc_core_dirpath:    .skip 640           // logs_dir + "/" + channel_name
tc_core_fpath:      .skip 704           // dirpath + "/" + file name
tc_core_name:       .skip 64            // resolved channel directory name
tc_core_chlower:    .skip 64            // lowercased resolved channel
tc_core_dnames:     .skip MAX_DNAMES * 8
tc_core_darena:     .skip MAX_DNAMES * DNAME_SZ
tc_core_dname_count:.skip 8
tc_core_list_key:   .skip 80            // sort scratch (listing entry copy)
tc_core_cur_state:  .skip 8             // 0 = unknown, 1 = live, 2 = offline
tc_core_g_live:     .skip 8             // all-user all-state totals
tc_core_g_off:      .skip 8
tc_core_g_unk:      .skip 8

// ============================================================================
// .rodata — message literals (lengths via label arithmetic where it matters)
// ============================================================================
    RODATA
s_dir_not_found:    .asciz "logs directory not found: "
s_no_logs_pre:      .asciz "no logs for channel '"
s_no_logs_mid:      .asciz "' in "
s_avail:            .asciz "available: "
s_none_paren:       .asciz "(none)"
s_no_files_pre:     .asciz "no log files found in "
s_cant_open_dir:    .asciz "cannot open channel directory: "
s_begin_paren:      .asciz "begin ("
s_is_after_end:     .asciz ") is after end ("
s_cannot_read:      .asciz "cannot read"
s_too_large:        .asciz "file too large"
s_oom:              .asciz "out of memory"
lit_is_live:        .asciz "is live!"
lit_is_offline:     .asciz "is now offline."
month_days:         .byte 31,28,31,30,31,30,31,31,30,31,30,31

    .text

// ============================================================================
// tc_count_run — the Phase 4 entry point.
//   Reads the resolved tc_opts + tc_window, then:
//     resolve channel -> build listing -> complete window -> count.
//   Errors (ConfigError-equivalents) go through tc_fail: "error: ..." + exit 1.
// ============================================================================
    .p2align 2
    .global tc_count_run
    FUNC_TYPE(tc_count_run)
tc_count_run:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    bl tc_resolve_channel
    bl tc_build_listing
    bl tc_complete_window
    bl tc_count_final
    mov x0, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_channel_name() -> x0 = pointer to the resolved channel directory name
//   (the real on-disk name found by the case-insensitive match; what the
//   Python calls context.channel_name).  Addition for Phase 5's channel
//   header row, documented here.
// ============================================================================
    .p2align 2
    .global tc_channel_name
    FUNC_TYPE(tc_channel_name)
tc_channel_name:
    adrp x0, PAGE(tc_core_name)
    add x0, x0, LO12(tc_core_name)
    ret

// ============================================================================
// tc_count_column(x0=user index) -> x0 = the count-column for the entry:
//   the sum of the states matching the resolved state filter (TC_W_STATE_FILTER),
//   or all three states when unfiltered.  Exported for Phase 5.
// ============================================================================
    .p2align 2
    .global tc_count_column
    FUNC_TYPE(tc_count_column)
tc_count_column:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x1, PAGE(tc_users)
    add x1, x1, LO12(tc_users)
    ldr x2, [x1, #TC_US_ENTRIES]
    mov x3, #TC_US_ENTRY_SZ
    mul x3, x0, x3
    add x2, x2, x3                  // entry ptr
    adrp x3, PAGE(tc_window)
    add x3, x3, LO12(tc_window)
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
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lcc_live:
    ldr x0, [x2, #TC_US_LIVE]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lcc_off:
    ldr x0, [x2, #TC_US_OFFLINE]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lcc_unk:
    ldr x0, [x2, #TC_US_UNKNOWN]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_user_state(x0=user index, x1=TC_ST_*) -> x0 = that state's count.
// ============================================================================
    .p2align 2
    .global tc_user_state
    FUNC_TYPE(tc_user_state)
tc_user_state:
    adrp x2, PAGE(tc_users)
    add x2, x2, LO12(tc_users)
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
// tc_eff_threshold — the effective reported() floor for --users sizing:
//   max(min_count, share_floor) when a share is shown or sorted by and the
//   share floor is nonzero, else min_count.  (Python rank_users ordering:
//   the >= threshold filter, then the >= floor filter when it acts.)
// ============================================================================
    .p2align 2
tc_eff_threshold:
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
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
//   build tc_core_dirpath = <logs_dir>/<real name>; exits on error.
//   Phase 6: exported so tc_cache_open can resolve the channel before it
//   captures the channel name (the counting pass would otherwise resolve it
//   too late for the open-time purge).  Idempotent: calling it again from
//   tc_count_run re-reads the directory with identical results.
// ============================================================================
    .p2align 2
    .global tc_resolve_channel
    FUNC_TYPE(tc_resolve_channel)
tc_resolve_channel:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // lowercased channel for matching
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_CHANNEL
    adrp x1, PAGE(tc_core_chlower)
    add x1, x1, LO12(tc_core_chlower)
    bl lowercase_copy
    // open the logs dir
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_LOGS_DIR
    bl opendir
    cbz x0, .Lrc_dir_notfound
    mov x19, x0                        // DIR*
    adrp x20, PAGE(tc_core_dname_count)
    add x20, x20, LO12(tc_core_dname_count)
    str xzr, [x20]
.Lrc_list:
    mov x0, x19
    bl readdir
    cbz x0, .Lrc_list_done
    ldrb w1, [x0, #18]                 // d_type
    cmp w1, #DT_DIR
    b.ne .Lrc_list
    add x1, x0, #19                    // d_name
    // skip "." and ".."
    ldrb w2, [x1]
    cmp w2, #'.'
    b.ne .Lrc_keep
    ldrb w2, [x1, #1]
    cbz w2, .Lrc_list
    cmp w2, #'.'
    b.ne .Lrc_keep
    ldrb w2, [x1, #2]
    cbz w2, .Lrc_list
.Lrc_keep:
    ldr x3, [x20]
    cmp x3, #MAX_DNAMES
    b.ge .Lrc_list
    // name length, capped at DNAME_SZ-1
    mov x4, x1
    mov x5, #0
.Lrc_nlen:
    ldrb w6, [x4]
    cbz w6, .Lrc_nlen_done
    add x4, x4, #1
    add x5, x5, #1
    cmp x5, #(DNAME_SZ - 1)
    b.ge .Lrc_list
    b .Lrc_nlen
.Lrc_nlen_done:
    // copy into the arena
    adrp x6, PAGE(tc_core_darena)
    add x6, x6, LO12(tc_core_darena)
    mov x7, #DNAME_SZ
    mul x7, x3, x7
    add x6, x6, x7
    adrp x8, PAGE(tc_core_dnames)
    add x8, x8, LO12(tc_core_dnames)
    str x6, [x8, x3, lsl #3]
    mov x9, #0
.Lrc_copy:
    cmp x9, x5
    b.ge .Lrc_copy_done
    ldrb w10, [x1, x9]
    strb w10, [x6, x9]
    add x9, x9, #1
    b .Lrc_copy
.Lrc_copy_done:
    mov w10, #0
    strb w10, [x6, x9]
    add x3, x3, #1
    str x3, [x20]
    b .Lrc_list
.Lrc_list_done:
    mov x0, x19
    bl closedir
    bl sort_dnames
    // find the channel case-insensitively
    ldr x19, [x20]                     // count
    mov x21, #0                        // index
.Lrc_find:
    cmp x21, x19
    b.ge .Lrc_no_channel
    adrp x22, PAGE(tc_core_dnames)
    add x22, x22, LO12(tc_core_dnames)
    ldr x22, [x22, x21, lsl #3]        // name
    adrp x1, PAGE(tc_core_chlower)
    add x1, x1, LO12(tc_core_chlower)
    mov x0, x22
    bl tc_ascii_casecmp
    cbz x0, .Lrc_found
    add x21, x21, #1
    b .Lrc_find
.Lrc_found:
    // x22 = the real directory name
    adrp x0, PAGE(tc_core_name)
    add x0, x0, LO12(tc_core_name)
    mov x1, x22
    bl tc_copy_str
    // dirpath = logs_dir + "/" + name
    adrp x0, PAGE(tc_core_dirpath)
    add x0, x0, LO12(tc_core_dirpath)
    mov x23, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x1, x0, #TC_O_LOGS_DIR
    mov x0, x23
    bl tc_cat_cstr
    mov w2, #'/'
    strb w2, [x0], #1
    mov x23, x0
    adrp x1, PAGE(tc_core_name)
    add x1, x1, LO12(tc_core_name)
    mov x0, x23
    bl tc_cat_cstr
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

.Lrc_dir_notfound:
    // "logs directory not found: <dir>"
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    mov x19, x0
    adrp x1, PAGE(s_dir_not_found)
    add x1, x1, LO12(s_dir_not_found)
    bl tc_cat_cstr
    mov x19, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x1, x0, #TC_O_LOGS_DIR
    mov x0, x19
    bl tc_cat_cstr
    mov w1, #0
    strb w1, [x0]
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    bl tc_fail

.Lrc_no_channel:
    // "no logs for channel '<ch>' in <dir>\navailable: <join|(none)>"
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    mov x19, x0
    adrp x1, PAGE(s_no_logs_pre)
    add x1, x1, LO12(s_no_logs_pre)
    bl tc_cat_cstr
    mov x19, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x1, x0, #TC_O_CHANNEL
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    adrp x1, PAGE(s_no_logs_mid)
    add x1, x1, LO12(s_no_logs_mid)
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x1, x0, #TC_O_LOGS_DIR
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    mov w2, #'\n'
    strb w2, [x19], #1
    adrp x1, PAGE(s_avail)
    add x1, x1, LO12(s_avail)
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
    ldr x20, [x20]                     // dname count
    cbz x20, .Lrc_avail_none
    mov x21, #0
.Lrc_avail_loop:
    adrp x22, PAGE(tc_core_dnames)
    add x22, x22, LO12(tc_core_dnames)
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
    adrp x1, PAGE(s_none_paren)
    add x1, x1, LO12(s_none_paren)
    mov x0, x19
    bl tc_cat_cstr
    mov x19, x0
.Lrc_avail_done:
    mov w2, #0
    strb w2, [x19]
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    bl tc_fail

// ============================================================================
// tc_build_listing — fill tc_listing with every dated log file, ascending.
// ============================================================================
    .p2align 2
tc_build_listing:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_listing)
    add x19, x19, LO12(tc_listing)
    str xzr, [x19, #TC_L_COUNT]
    str xzr, [x19, #TC_L_CAP]
    str xzr, [x19, #TC_L_ENTRIES]
    adrp x0, PAGE(tc_core_dirpath)
    add x0, x0, LO12(tc_core_dirpath)
    bl opendir
    cbz x0, .Lbl_cant_open
    mov x20, x0                        // DIR*
.Lbl_list:
    mov x0, x20
    bl readdir
    cbz x0, .Lbl_done
    add x22, x0, #19                   // d_name (callee-saved)
    mov x0, x22
    bl parse_log_filename              // x0 = ymd or 0 (clobbers x0-x2)
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
    bl sort_listing
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

.Lbl_cant_open:
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    mov x19, x0
    adrp x1, PAGE(s_cant_open_dir)
    add x1, x1, LO12(s_cant_open_dir)
    bl tc_cat_cstr
    mov x19, x0
    adrp x1, PAGE(tc_core_dirpath)
    add x1, x1, LO12(tc_core_dirpath)
    mov x0, x19
    bl tc_cat_cstr
    mov w1, #0
    strb w1, [x0]
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    bl tc_fail

.Lbl_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
// parse_log_filename(x0=name) -> x0 = ymd (YYYYMMDD), or 0 when the name is
//   not "<anything>-YYYY-MM-DD.log" with a real calendar date.
// ============================================================================
    .p2align 2
parse_log_filename:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
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
    bl days_in_month
    ldp x8, x30, [sp], #16
    ldp x3, x7, [sp], #16
    cmp x8, x0
    b.gt .Lplf_fail
    // ymd = y*10000 + mo*100 + d
    mov x5, #10000
    mul x3, x3, x5
    mov x5, #100
    mul x7, x7, x5
    add x3, x3, x7
    add x3, x3, x8
    mov x0, x3
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lplf_fail:
    mov x0, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// days_in_month(x0=y, x1=m) -> x0 = days in that month.
// ============================================================================
    .p2align 2
days_in_month:
    sub x1, x1, #1
    adrp x2, PAGE(month_days)
    add x2, x2, LO12(month_days)
    ldrb w0, [x2, x1]
    cmp x1, #1                         // February
    b.ne .Ldim_out
    mov x3, x0
    mov x4, #4
    sdiv x5, x3, x4
    msub x6, x5, x4, x3
    cbnz x6, .Ldim_out                 // y%4 != 0
    mov x4, #100
    sdiv x5, x3, x4
    msub x6, x5, x4, x3
    cbz x6, .Ldim_c400                 // y%100 == 0
    mov w0, #29
    b .Ldim_out
.Ldim_c400:
    mov x4, #400
    sdiv x5, x3, x4
    msub x6, x5, x4, x3
    cbz x6, .Ldim_leap
    b .Ldim_out
.Ldim_leap:
    mov w0, #29
.Ldim_out:
    ret

// ============================================================================
// tc_complete_window — finish the window tc_cli left open:
//   kind EARLIEST: begin = earliest log file 00:00:00 (+ no-files and
//                  begin>end errors); kind USERS: the --users sizing.
//   Always fills TC_W_THRESHOLD and TC_W_STATE_FILTER from the options.
// ============================================================================
    .p2align 2
tc_complete_window:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_KIND]
    cmp x20, #TC_WIN_EARLIEST
    b.eq .Lcw_earliest
    cmp x20, #TC_WIN_USERS
    b.eq .Lcw_users
    b .Lcw_fill
.Lcw_earliest:
    adrp x21, PAGE(tc_listing)
    add x21, x21, LO12(tc_listing)
    ldr x22, [x21, #TC_L_COUNT]
    cbnz x22, .Lcw_earliest_ok
    // "no log files found in <dirpath>"
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    mov x23, x0
    adrp x1, PAGE(s_no_files_pre)
    add x1, x1, LO12(s_no_files_pre)
    bl tc_cat_cstr
    mov x23, x0
    adrp x1, PAGE(tc_core_dirpath)
    add x1, x1, LO12(tc_core_dirpath)
    mov x0, x23
    bl tc_cat_cstr
    mov w1, #0
    strb w1, [x0]
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    bl tc_fail
.Lcw_earliest_ok:
    ldr x23, [x21, #TC_L_ENTRIES]
    ldr x24, [x23]
    str x24, [x19, #TC_W_BEGIN_YMD]
    str xzr, [x19, #TC_W_BEGIN_SOD]
    bl tc_window_begin_after_end_check
    b .Lcw_fill
.Lcw_users:
    bl tc_size_users
    b .Lcw_fill
.Lcw_fill:
    adrp x20, PAGE(tc_opts)
    add x20, x20, LO12(tc_opts)
    ldr x21, [x20, #TC_O_MIN_COUNT]
    str x21, [x19, #TC_W_THRESHOLD]
    ldr x21, [x20, #TC_O_STATE_FILTER]
    str x21, [x19, #TC_W_STATE_FILTER]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_window_begin_after_end_check — "begin (B) is after end (E)" when the
//   resolved begin (kind EARLIEST) is later than the resolved end.
// ============================================================================
    .p2align 2
tc_window_begin_after_end_check:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
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
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    mov x22, x0
    adrp x1, PAGE(s_begin_paren)
    add x1, x1, LO12(s_begin_paren)
    bl tc_cat_cstr
    mov x22, x0
    ldr x1, [x19, #TC_W_BEGIN_YMD]
    ldr x2, [x19, #TC_W_BEGIN_SOD]
    mov x0, x1
    mov x1, x2
    mov x2, x22                          // format into the scratch cursor
    bl fmt_ymd_sod
    mov x22, x0
    adrp x1, PAGE(s_is_after_end)
    add x1, x1, LO12(s_is_after_end)
    mov x0, x22
    bl tc_cat_cstr
    mov x22, x0
    ldr x1, [x19, #TC_W_END_YMD]
    ldr x2, [x19, #TC_W_END_SOD]
    mov x0, x1
    mov x1, x2
    mov x2, x22                          // format into the scratch cursor
    bl fmt_ymd_sod
    mov w1, #')'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    adrp x0, PAGE(tc_core_scratch)
    add x0, x0, LO12(tc_core_scratch)
    bl tc_fail
.Lwae_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_size_users — the --users bisection (Python _search_width + _apply_width).
//   Sets TC_W_USERS_WIDTH / TC_W_USERS_FOUND and begin = end - width.
// ============================================================================
    .p2align 2
tc_size_users:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // end_epoch
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x0, [x9, #TC_W_END_YMD]
    ldr x1, [x9, #TC_W_END_SOD]
    bl tc_ymd_sod_to_epoch
    mov x19, x0                        // end_epoch
    // requested / ceiling
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    ldr x20, [x9, #TC_O_USERS]
    ldr x21, [x9, #TC_O_USERS_MAX]
    cmp x21, #1
    b.ge .Lsu_ceiling_ok
    mov x21, #1
.Lsu_ceiling_ok:
    bl tc_eff_threshold
    mov x22, x0                        // eff
    // widest = reported(ceiling)
    mov x0, x21
    bl tc_reported_width
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
    bl tc_reported_width
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
    bl tc_reported_width
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
    bl tc_reported_width
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
    bl tc_reported_width
    mov x27, x0                        // under
    // ---- policy ----
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
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
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    str x1, [x9, #TC_W_USERS_WIDTH]
    str x2, [x9, #TC_W_USERS_FOUND]
    sub x0, x19, x1                   // begin = end - width
    bl tc_epoch_to_ymd_sod
    adrp x9, PAGE(tc_window)                // reload: the call clobbered x9
    add x9, x9, LO12(tc_window)
    str x0, [x9, #TC_W_BEGIN_YMD]
    str x1, [x9, #TC_W_BEGIN_SOD]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_reported_width(x0=seconds) -> x0 = the reported population for the
//   window [end - seconds, end]: non-excluded users whose count-column is
//   >= the effective threshold (min_count, or share_floor when a share is
//   shown and the floor is nonzero).  Side effect: recounts into the user
//   table + tally for the probe window (the final pass overwrites).
// ============================================================================
    .p2align 2
tc_reported_width:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // seconds
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x0, [x20, #TC_W_END_YMD]
    ldr x1, [x20, #TC_W_END_SOD]
    bl tc_ymd_sod_to_epoch
    sub x0, x0, x19                    // begin_epoch
    bl tc_epoch_to_ymd_sod             // x0=ymd, x1=sod
    str x0, [x20, #TC_W_BEGIN_YMD]
    str x1, [x20, #TC_W_BEGIN_SOD]
    bl tc_count_final
    bl tc_eff_threshold
    mov x21, x0                        // eff
    adrp x22, PAGE(tc_users)
    add x22, x22, LO12(tc_users)
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
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_count_final — the counting pass for the resolved window [begin, end]:
//   seed state, fold every in-range file, then finish the tally.  Fills
//   tc_users and tc_tally (fresh each call; probes overwrite later).
// ============================================================================
    .p2align 2
tc_count_final:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    sub sp, sp, #CF_FRAME_SZ
    bl tc_reset_count
    bl tc_seed_state                    // x0 = 0/1/2
    adrp x9, PAGE(tc_core_cur_state)
    add x9, x9, LO12(tc_core_cur_state)
    str x0, [x9]
    adrp x19, PAGE(tc_listing)
    add x19, x19, LO12(tc_listing)
    ldr x19, [x19, #TC_L_COUNT]        // count
    adrp x20, PAGE(tc_listing)
    add x20, x20, LO12(tc_listing)
    ldr x20, [x20, #TC_L_ENTRIES]      // entries
    adrp x21, PAGE(tc_window)
    add x21, x21, LO12(tc_window)
    ldr x22, [x21, #TC_W_BEGIN_YMD]
    ldr x23, [x21, #TC_W_BEGIN_SOD]
    ldr x24, [x21, #TC_W_END_YMD]
    ldr x25, [x21, #TC_W_END_SOD]
    adrp x26, PAGE(tc_tally)
    add x26, x26, LO12(tc_tally)
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
    adrp x0, PAGE(tc_core_fpath)
    add x0, x0, LO12(tc_core_fpath)
    adrp x1, PAGE(tc_core_dirpath)
    add x1, x1, LO12(tc_core_dirpath)
    bl tc_cat_cstr
    mov w2, #'/'
    strb w2, [x0], #1
    str x0, [sp, #CF_CPTR]
    ldr x1, [sp, #CF_ENTRY]
    add x1, x1, #TC_L_NAME
    bl tc_cat_cstr
    // ---- Phase 6: rollup-cache hook ----
    // A whole-day file inside the range may come from the rollup.  The cache
    // module stats the path and returns 0 = parse normally, 1 = reused (x1 =
    // cached exit_state; counts already applied to tc_users + totals), 2 =
    // stat failed (record unreadable + reset state, like Python's skip()).
    adrp x0, PAGE(tc_core_fpath)
    add x0, x0, LO12(tc_core_fpath)
    ldr x1, [sp, #CF_LO]
    ldr x2, [sp, #CF_HI]
    adrp x9, PAGE(tc_core_cur_state)
    add x9, x9, LO12(tc_core_cur_state)
    ldr x3, [x9]
    ldr x4, [sp, #CF_ENTRY]
    ldr x4, [x4, #TC_L_YMD]
    bl tc_cache_day
    cmp w0, #1
    b.eq .Lcf_cached
    cmp w0, #2
    b.eq .Lcf_cache_unreadable
    // read the whole file
    adrp x0, PAGE(tc_core_fpath)
    add x0, x0, LO12(tc_core_fpath)
    bl tc_read_file                     // x0=status, x1=buf, x2=len
    cbnz x0, .Lcf_unreadable
    // ok: buf = x1, len = x2 -> keep them in the frame across calls
    str x1, [sp, #CF_BUF]
    str x2, [sp, #CF_LEN]
    mov x0, x1
    mov x1, x2
    bl tc_has_newline
    cbz x0, .Lcf_free
    ldr x2, [sp, #CF_LO]
    ldr x3, [sp, #CF_HI]
    ldr x0, [sp, #CF_BUF]
    ldr x1, [sp, #CF_LEN]
    bl process_lines
    ldr x11, [x26, #TC_T_PARSED]
    add x11, x11, #1
    str x11, [x26, #TC_T_PARSED]
    // ---- Phase 6: write the whole day to the rollup (no-op unless the
    // cache module stashed this file's snapshot) ----
    adrp x9, PAGE(tc_core_cur_state)
    add x9, x9, LO12(tc_core_cur_state)
    ldr x0, [x9]
    bl tc_cache_put_day
    b .Lcf_free
.Lcf_unreadable:
    mov x9, x0                          // status
    stp x9, x1, [sp, #-16]!             // save status + buf across the call
    bl tc_cache_discard_day             // Phase 6: drop any pending stash
    ldp x9, x1, [sp], #16
    str x1, [sp, #CF_BUF]               // buf (may be 0)
    ldr x0, [sp, #CF_ENTRY]
    add x0, x0, #TC_L_NAME
    cmp x9, #1
    b.eq .Lcf_too_large
    adrp x1, PAGE(s_cannot_read)
    add x1, x1, LO12(s_cannot_read)
    b .Lcf_record
.Lcf_too_large:
    adrp x1, PAGE(s_too_large)
    add x1, x1, LO12(s_too_large)
.Lcf_record:
    bl record_unreadable
    ldr x10, [sp, #CF_BUF]
    cbz x10, .Lcf_state_reset
    mov x0, x10
    bl free
.Lcf_state_reset:
    adrp x9, PAGE(tc_core_cur_state)
    add x9, x9, LO12(tc_core_cur_state)
    str xzr, [x9]
    b .Lcf_next
.Lcf_free:
    bl tc_cache_discard_day             // Phase 6: no-newline days never write
    ldr x9, [sp, #CF_BUF]
    cbz x9, .Lcf_next
    mov x0, x9
    bl free
.Lcf_next:
    add x27, x27, #1
    b .Lcf_loop
.Lcf_cached:
    // Phase 6: the day came from the rollup.  x1 = cached exit_state; the
    // cache module already applied the counts to tc_users + the totals.
    ldr x11, [x26, #TC_T_REUSED]
    add x11, x11, #1
    str x11, [x26, #TC_T_REUSED]
    adrp x9, PAGE(tc_core_cur_state)
    add x9, x9, LO12(tc_core_cur_state)
    str x1, [x9]
    b .Lcf_next
.Lcf_cache_unreadable:
    // Phase 6: stat failed inside the cache hook; record + reset state,
    // exactly like Python's skip().
    ldr x0, [sp, #CF_ENTRY]
    add x0, x0, #TC_L_NAME
    adrp x1, PAGE(s_cannot_read)
    add x1, x1, LO12(s_cannot_read)
    bl record_unreadable
    adrp x9, PAGE(tc_core_cur_state)
    add x9, x9, LO12(tc_core_cur_state)
    str xzr, [x9]
    b .Lcf_next
.Lcf_done:
    add sp, sp, #CF_FRAME_SZ
    bl tc_finish_tally
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_reset_count — zero the tally and the global counters, reset the user
//   table count (the entry buffer is kept and reused across probes).
// ============================================================================
    .p2align 2
tc_reset_count:
    stp x29, x30, [sp, #-16]!
    adrp x0, PAGE(tc_core_g_live)
    add x0, x0, LO12(tc_core_g_live)
    mov x1, #0
    str x1, [x0]
    str x1, [x0, #8]
    str x1, [x0, #16]
    adrp x0, PAGE(tc_core_cur_state)
    add x0, x0, LO12(tc_core_cur_state)
    str x1, [x0]
    adrp x0, PAGE(tc_tally)
    add x0, x0, LO12(tc_tally)
    mov x1, #TC_TALLY_SIZE
    bl tc_memzero_own
    adrp x0, PAGE(tc_tally)
    add x0, x0, LO12(tc_tally)
    adrp x1, PAGE(tc_users)
    add x1, x1, LO12(tc_users)
    str x1, [x0, #TC_T_USERS_PTR]
    str xzr, [x1, #TC_US_COUNT]
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_finish_tally — apply exclusions to the tally: TC_T_STATES becomes the
//   non-excluded all-state split, TC_T_EXCLUDED_STATES the excluded split,
//   TC_T_MESSAGES the non-excluded count-column total.
// ============================================================================
    .p2align 2
tc_finish_tally:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    adrp x20, PAGE(tc_core_g_live)
    add x20, x20, LO12(tc_core_g_live)
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
    adrp x24, PAGE(tc_users)
    add x24, x24, LO12(tc_users)
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
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// record_unreadable(x0=name, x1=reason) — capped unreadable list.
// ============================================================================
    .p2align 2
record_unreadable:
    adrp x2, PAGE(tc_tally)
    add x2, x2, LO12(tc_tally)
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
// tc_seed_state — the live/offline state in force when the range opens.
//   Walks back through files whose date < begin.date(), newest first, at most
//   seed_lookback of them; returns the LAST marker found in the first such
//   file that has any (0 = unknown).  Unreadable files are skipped.
// ============================================================================
    .p2align 2
tc_seed_state:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_listing)
    add x19, x19, LO12(tc_listing)
    ldr x20, [x19, #TC_L_COUNT]
    ldr x21, [x19, #TC_L_ENTRIES]
    adrp x22, PAGE(tc_window)
    add x22, x22, LO12(tc_window)
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
    adrp x25, PAGE(tc_opts)
    add x25, x25, LO12(tc_opts)
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
    adrp x0, PAGE(tc_core_fpath)
    add x0, x0, LO12(tc_core_fpath)
    adrp x1, PAGE(tc_core_dirpath)
    add x1, x1, LO12(tc_core_dirpath)
    bl tc_cat_cstr
    mov w2, #'/'
    strb w2, [x0], #1
    mov x10, x0
    add x1, x9, #TC_L_NAME
    mov x0, x10
    bl tc_cat_cstr
    adrp x0, PAGE(tc_core_fpath)
    add x0, x0, LO12(tc_core_fpath)
    bl tc_read_file                      // x0=status, x1=buf, x2=len
    cbnz x0, .Lss_next
    // keep buf/len on the stack: scan_markers may clobber x9-x17
    stp x1, x2, [sp, #-16]!
    mov x0, x1
    mov x1, x2
    bl scan_markers                      // x0 = last marker state 0/1/2
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
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_read_file(x0=path) -> x0 = status (0 ok, 1 too large, 2 error),
//   x1 = malloc'd buffer (caller frees; 0 on early error), x2 = bytes read.
// ============================================================================
    .p2align 2
tc_read_file:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
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
    ldr x2, =EINTR
    cmp x0, x2
    b.eq .Lrf_read
    b .Lrf_read_err
.Lrf_done:
    mov x0, x20
    bl close
    mov x0, #0
    mov x1, x21
    mov x2, x23
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lrf_large:
    mov x0, x20
    bl close
    mov x0, #1
    mov x1, x21
    mov x2, x23
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lrf_read_err:
    mov x0, x20
    bl close
    mov x0, x21
    bl free
    mov x0, #2
    mov x1, #0
    mov x2, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lrf_open_fail:
    mov x0, #2
    mov x1, #0
    mov x2, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lrf_alloc_fail:
    mov x0, x20
    bl close
    mov x0, #2
    mov x1, #0
    mov x2, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lrf_alloc_fail2:
    mov x0, x20
    bl close
    mov x0, x21
    bl free
    mov x0, #2
    mov x1, #0
    mov x2, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_has_newline(x0=buf, x1=len) -> x0 = 1 when the buffer holds a '\n'.
// ============================================================================
    .p2align 2
tc_has_newline:
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
// scan_markers(x0=buf, x1=len) -> x0 = the LAST marker state (1 live, 2
//   offline, 0 none).  Processes every line including a partial final line,
//   exactly as the Python's seed loop does.
// ============================================================================
    .p2align 2
scan_markers:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
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
    bl line_is_marker
    cbz x0, .Lsm_next
    mov x21, x0
.Lsm_next:
    mov x22, x23
    b .Lsm_loop
.Lsm_done:
    mov x0, x21
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// line_is_marker(x0=line, x1=len) -> x0 = 1 (live), 2 (offline), or 0.
// ============================================================================
    .p2align 2
line_is_marker:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
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
    adrp x2, PAGE(lit_is_live)
    add x2, x2, LO12(lit_is_live)
    mov x3, #8
    bl marker_match
    cbnz x0, .Llim_live
    mov x0, x19
    mov x1, x20
    adrp x2, PAGE(lit_is_offline)
    add x2, x2, LO12(lit_is_offline)
    mov x3, #15
    bl marker_match
    cbnz x0, .Llim_off
.Llim_no:
    mov x0, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Llim_live:
    mov x0, #1
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Llim_off:
    mov x0, #2
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// marker_match(x0=line, x1=len, x2=literal, x3=litlen) -> x0 = 1 when the
//   line ends with the literal, preceded by a space and a non-empty,
//   space-free token: "[HH:MM:SS] <token> <literal>".
// ============================================================================
    .p2align 2
marker_match:
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
// process_lines(x0=buf, x1=len, x2=lo, x3=hi) — fold one file's complete
//   lines (the partial tail is dropped, as in the Python).  Updates the
//   global cur_state from markers and counts in-window messages.
// ============================================================================
    .p2align 2
process_lines:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                         // buf
    add x20, x19, x1                    // end
    mov x21, x2                         // lo
    mov x22, x3                         // hi
    adrp x23, PAGE(tc_core_cur_state)
    add x23, x23, LO12(tc_core_cur_state)
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
    bl line_is_marker
    cbnz x0, .Lpl_marker
    mov x0, x24
    mov x1, x27
    mov x2, x21
    mov x3, x22
    mov x4, x23
    bl process_message
    b .Lpl_next
.Lpl_marker:
    mov x23, x0
.Lpl_next:
    add x24, x26, #1
    b .Lpl_loop
.Lpl_done:
    adrp x9, PAGE(tc_core_cur_state)
    add x9, x9, LO12(tc_core_cur_state)
    str x23, [x9]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// process_message(x0=line, x1=len, x2=lo, x3=hi, x4=state) -> x0 = 1 if the
//   message was counted.  The speaker is classified by speaker_login; the
//   state (0 = unknown) becomes TC_ST_UNKNOWN for the count.
// ============================================================================
    .p2align 2
process_message:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
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
    mov x8, #3600
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
    bl speaker_login                    // x0 = login ptr or 0, x1 = login len
    cbz x0, .Lpm_skip
    mov x24, x0                         // login ptr
    mov x25, x1                         // login len
    mov x26, x23                        // state survives the table calls
    cbnz x26, .Lpm_state_set
    mov x26, #TC_ST_UNKNOWN
.Lpm_state_set:
    mov x0, x24
    mov x1, x25
    adrp x2, PAGE(tc_users)
    add x2, x2, LO12(tc_users)
    bl find_user                        // x0 = index or -1
    cmp x0, #0
    b.ge .Lpm_have_user
    mov x0, x24
    mov x1, x25
    adrp x2, PAGE(tc_users)
    add x2, x2, LO12(tc_users)
    bl add_user                         // x0 = index
.Lpm_have_user:
    // entry = users.entries + index*50
    adrp x9, PAGE(tc_users)
    add x9, x9, LO12(tc_users)
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
    adrp x12, PAGE(tc_core_g_live)
    add x12, x12, LO12(tc_core_g_live)
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_counted
.Lpm_inc_off:
    ldr x11, [x10, #TC_US_OFFLINE]
    add x11, x11, #1
    str x11, [x10, #TC_US_OFFLINE]
    adrp x12, PAGE(tc_core_g_off)
    add x12, x12, LO12(tc_core_g_off)
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_counted
.Lpm_inc_unk:
    ldr x11, [x10, #TC_US_UNKNOWN]
    add x11, x11, #1
    str x11, [x10, #TC_US_UNKNOWN]
    adrp x12, PAGE(tc_core_g_unk)
    add x12, x12, LO12(tc_core_g_unk)
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
.Lpm_counted:
    mov x0, #1
    b .Lpm_out
.Lpm_skip:
    mov x0, #0
.Lpm_out:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// speaker_login(x0=speaker, x1=slen) -> x0 = login_buf ptr, x1 = login len,
//   or x0 = 0 when the speaker is not a real chatter.  LOGIN_RE first, then
//   LOCALIZED_RE with a non-ASCII display byte.
// ============================================================================
    .p2align 2
speaker_login:
    stp x29, x30, [sp, #-16]!
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
    bl is_login_char
    b.ne .Lsl_localized
    add x2, x2, #1
    b .Lsl_login
.Lsl_login_ok:
    // lowercase into login_buf
    adrp x4, PAGE(tc_core_login)
    add x4, x4, LO12(tc_core_login)
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
    ldp x29, x30, [sp], #16
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
    bl is_lower_login_char
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
    adrp x8, PAGE(tc_core_login)
    add x8, x8, LO12(tc_core_login)
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
    ldp x29, x30, [sp], #16
    ret
.Lsl_fail:
    mov x0, #0
    ldp x29, x30, [sp], #16
    ret

// is_login_char — sets EQ iff w3 is in [A-Za-z0-9_] (used as a predicate)
    .p2align 2
is_login_char:
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

// is_lower_login_char — like is_login_char but only [a-z0-9_]
    .p2align 2
is_lower_login_char:
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
// find_user(x0=login, x1=len, x2=table_base) -> x0 = index, or -1.
//   Phase 6: the base is passed in x2 (tc_users for the counting pass, a
//   caller's table for the cache module).  Exported for tc_cache.S.
// ============================================================================
    .p2align 2
    .global find_user
    FUNC_TYPE(find_user)
find_user:
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
// add_user(x0=login, x1=len, x2=table_base) -> x0 = index (grows the entry
//   array).  Phase 6: the base is passed in x2.  Exported for tc_cache.S.
// ============================================================================
    .p2align 2
    .global add_user
    FUNC_TYPE(add_user)
add_user:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
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
    // Wave E fix: the new capacity is held in x23 (callee-saved) across the
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
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lau_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
// tc_reuse_apply(x0=login, x1=len, x2=state, x3=n) -> x0 = 0
//   Add n to the user entry's state bucket and the matching all-state total
//   (tc_core_g_*).  This is process_message's increment section, exported so
//   the rollup cache (tc_cache.S) can serve a whole cached day into the same
//   tables the counting pass fills.  state is TC_ST_LIVE/OFFLINE/UNKNOWN.
// ============================================================================
    .p2align 2
    .global tc_reuse_apply
    FUNC_TYPE(tc_reuse_apply)
tc_reuse_apply:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                         // login
    mov x20, x1                         // len
    mov x21, x2                         // state
    mov x22, x3                         // n
    adrp x2, PAGE(tc_users)
    add x2, x2, LO12(tc_users)
    mov x0, x19
    mov x1, x20
    bl find_user                        // x0 = index or -1
    cmp x0, #0
    b.ge .Lrua_have
    mov x0, x19
    mov x1, x20
    adrp x2, PAGE(tc_users)
    add x2, x2, LO12(tc_users)
    bl add_user                         // x0 = index
.Lrua_have:
    // entry = users.entries + index*50
    adrp x9, PAGE(tc_users)
    add x9, x9, LO12(tc_users)
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
    adrp x12, PAGE(tc_core_g_live)
    add x12, x12, LO12(tc_core_g_live)
    ldr x13, [x12]
    add x13, x13, x22
    str x13, [x12]
    b .Lrua_done
.Lrua_off:
    ldr x11, [x10, #TC_US_OFFLINE]
    add x11, x11, x22
    str x11, [x10, #TC_US_OFFLINE]
    adrp x12, PAGE(tc_core_g_off)
    add x12, x12, LO12(tc_core_g_off)
    ldr x13, [x12]
    add x13, x13, x22
    str x13, [x12]
    b .Lrua_done
.Lrua_unk:
    ldr x11, [x10, #TC_US_UNKNOWN]
    add x11, x11, x22
    str x11, [x10, #TC_US_UNKNOWN]
    adrp x12, PAGE(tc_core_g_unk)
    add x12, x12, LO12(tc_core_g_unk)
    ldr x13, [x12]
    add x13, x13, x22
    str x13, [x12]
.Lrua_done:
    mov x0, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// sort_dnames — insertion sort the tc_core_dnames pointer array by string.
// ============================================================================
    .p2align 2
sort_dnames:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, PAGE(tc_core_dnames)
    add x19, x19, LO12(tc_core_dnames)
    adrp x20, PAGE(tc_core_dname_count)
    add x20, x20, LO12(tc_core_dname_count)
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
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// sort_listing — insertion sort tc_listing entries by (ymd, name) ascending
//   (the name tiebreak mirrors Python's sorted((date, path))).
// ============================================================================
    .p2align 2
sort_listing:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x19, PAGE(tc_listing)
    add x19, x19, LO12(tc_listing)
    ldr x20, [x19, #TC_L_COUNT]
    ldr x21, [x19, #TC_L_ENTRIES]
    mov x22, #1
.Lsl_outer:
    cmp x22, x20
    b.ge .Lsl_done
    // key = entry x22, copied into tc_core_list_key
    mov x23, #TC_L_ENTRY_SZ
    mul x23, x22, x23
    add x23, x21, x23
    adrp x24, PAGE(tc_core_list_key)
    add x24, x24, LO12(tc_core_list_key)
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
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// lowercase_copy(x0=src, x1=dst) — ASCII-lowercase a string into dst.
// ============================================================================
    .p2align 2
lowercase_copy:
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
// tc_ascii_casecmp(x0=a, x1=b) -> x0 = 0 when a equals b ignoring ASCII
//   case (b is expected to be already lowercased).
// ============================================================================
    .p2align 2
tc_ascii_casecmp:
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
// tc_cat_cstr(x0=cursor, x1=s) -> x0 = the position of the terminating NUL
//   (callers overwrite it with the next character to append).
// ============================================================================
    .p2align 2
tc_cat_cstr:
    mov x2, #0
.Lcc_loop:
    ldrb w3, [x1, x2]
    strb w3, [x0, x2]
    add x2, x2, #1
    cbnz w3, .Lcc_loop
    add x0, x0, x2
    sub x0, x0, #1
    ret

// ============================================================================
// tc_copy_str(x0=dst, x1=src) — NUL-terminated string copy.
// ============================================================================
    .p2align 2
tc_copy_str:
    mov x2, #0
.Lcs:
    ldrb w3, [x1, x2]
    strb w3, [x0, x2]
    add x2, x2, #1
    cbnz w3, .Lcs
    ret

// ============================================================================
// tc_memzero_own(x0=ptr, x1=len)
// ============================================================================
    .p2align 2
tc_memzero_own:
    mov x2, #0
.Lmz:
    cbz x1, .Lmz_done
    strb w2, [x0], #1
    sub x1, x1, #1
    b .Lmz
.Lmz_done:
    ret

// ============================================================================
// tc_ymd_sod_to_epoch(x0=ymd, x1=sod) -> x0 = epoch seconds (UTC).
// ============================================================================
    .p2align 2
tc_ymd_sod_to_epoch:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x2, #10000
    udiv x21, x19, x2                   // year
    mul x3, x21, x2
    sub x4, x19, x3                     // month*100 + day
    mov x2, #100
    udiv x22, x4, x2                    // month
    msub x23, x22, x2, x4               // day
    mov x0, x21
    mov x1, x22
    mov x2, x23
    bl tc_days_from_civil               // x0 = days since epoch
    ldr x3, =SECS_PER_DAY
    mul x0, x0, x3
    add x0, x0, x20
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_epoch_to_ymd_sod(x0=epoch) -> x0 = ymd, x1 = sod (UTC).
// ============================================================================
    .p2align 2
tc_epoch_to_ymd_sod:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    ldr x19, =SECS_PER_DAY
    udiv x20, x0, x19
    msub x21, x20, x19, x0             // sod (callee-saved: survives the call)
    mov x0, x20
    bl tc_civil_from_days               // x0=y, x1=m, x2=d
    mov x3, #10000
    mul x0, x0, x3
    mov x3, #100
    mul x1, x1, x3
    add x0, x0, x1
    add x0, x0, x2
    mov x1, x21
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_days_from_civil(x0=y, x1=m, x2=d) -> x0 = days since 1970-01-01
//   (Howard Hinnant; identical to tc_cli's local helper).
// ============================================================================
    .p2align 2
tc_days_from_civil:
    cmp x1, #2
    b.gt .Ldfc_adj_done
    sub x0, x0, #1
.Ldfc_adj_done:
    cmp x0, #0
    b.ge .Ldfc_ypos
    sub x3, x0, #399
    b .Ldfc_era
.Ldfc_ypos:
    mov x3, x0
.Ldfc_era:
    mov x4, #400
    sdiv x3, x3, x4
    msub x5, x3, x4, x0
    cmp x1, #2
    b.gt .Ldfc_madj
    add x6, x1, #9
    b .Ldfc_doy
.Ldfc_madj:
    sub x6, x1, #3
.Ldfc_doy:
    mov x7, #153
    mul x6, x6, x7
    add x6, x6, #2
    mov x7, #5
    sdiv x6, x6, x7
    add x6, x6, x2
    sub x6, x6, #1
    mov x7, #365
    mul x7, x5, x7
    add x7, x7, x6
    mov x9, #4
    sdiv x8, x5, x9
    add x7, x7, x8
    mov x9, #100
    sdiv x8, x5, x9
    sub x7, x7, x8
    ldr x9, =146097
    mul x9, x3, x9
    add x7, x7, x9
    ldr x9, =719468
    sub x0, x7, x9
    ret

// ============================================================================
// fmt_pad(x0=cursor, x1=value, x2=width) -> x0 = cursor after the digits.
// ============================================================================
    .p2align 2
fmt_pad:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
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
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// fmt_ymd_sod(x0=ymd, x1=sod, x2=out) -> x0 = cursor after "YYYY-MM-DD
//   HH:MM:SS" (no NUL written).
// ============================================================================
    .p2align 2
fmt_ymd_sod:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                         // ymd
    mov x20, x1                         // sod
    mov x21, x2                         // out
    mov x22, #10000
    udiv x23, x19, x22                  // y
    mov x22, #100
    udiv x24, x19, x22
    msub x24, x24, x22, x19             // d
    mov x22, #10000
    udiv x25, x19, x22
    mov x26, #10000
    mul x25, x25, x26
    sub x25, x19, x25
    mov x26, #100
    udiv x25, x25, x26                  // mo
    mov x0, x21
    mov x1, x23
    mov x2, #4
    bl fmt_pad
    mov x21, x0
    mov w0, #'-'
    strb w0, [x21], #1
    mov x0, x21
    mov x1, x25
    mov x2, #2
    bl fmt_pad
    mov x21, x0
    mov w0, #'-'
    strb w0, [x21], #1
    mov x0, x21
    mov x1, x24
    mov x2, #2
    bl fmt_pad
    mov x21, x0
    mov w0, #' '
    strb w0, [x21], #1
    mov x26, #3600
    udiv x1, x20, x26
    mov x0, x21
    mov x2, #2
    bl fmt_pad
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
    bl fmt_pad
    mov x21, x0
    mov w0, #':'
    strb w0, [x21], #1
    mov x23, #60
    udiv x24, x20, x23
    msub x24, x24, x23, x20             // seconds
    mov x0, x21
    mov x1, x24
    mov x2, #2
    bl fmt_pad
    mov x21, x0
    mov x0, x21
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

    .end

