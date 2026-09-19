// ============================================================================
// tc_render.S — ranking, provenance header, table and footer for
//               twitch-counts-full (Phase 5)
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static — musl libc + crt1.o
//
//  Byte-for-byte port of the Python reference's presentation half:
//    rank_users / choose_columns / choose_limit / plan_presentation
//    (4507-4791), provenance_rows / window_span / state_row / exclude_row /
//    share_floor_row / users_row / cache_row / unreadable_row (4550-4686),
//    header_lines / compact_header / column_widths / align_row (4811-4869),
//    results_table / footer_lines (4872-4947), render_text (4950-4985).
//
//  Exported (all .global, AAPCS64, x19-x28 preserved):
//    tc_render_report()    -> 0   the Wave E entry: plan, then emit JSON or
//                                 text exactly like run_report().
//    tc_plan_presentation()-> 0   fill the plan (ranking, columns, header
//                                 rows, limit); may exit 1 on the degenerate
//                                 per-state error.
//    tc_render_text()      -> 0   render the text report from the plan.
//    tc_report_fail(x0=msg)      "error: <msg>" stderr + exit 1, or the JSON
//                                 {"error": <msg>} shape under --json.
//
//  Frame-capture additions (Phase 7, watch mode; all default OFF so the
//  one-shot renderers are byte-identical):
//    tc_frame_begin(x0=lines, x1=max)  -> 0  arm line capture.  `lines` is an
//                                 array of `max` pointers to writable line
//                                 buffers (each >= LINE_SZ bytes); every
//                                 rendered line (including the blank header
//                                 separator) is copied into the next slot
//                                 instead of being printed.
//    tc_frame_end()          -> 0  disarm capture.
//    tc_frame_set_pin(x0=w)  -> 0  w > 0 pins the results-table login column
//                                 to `w` characters, clipping over-long
//                                 logins with U+2026 (Python pin_user_column
//                                 under --watch); 0 = self-sizing (default).
//    tc_frame_set_tint(x0=fn, x1=ctx) -> 0  when fn != 0, each displayed
//                                 table row's aligned text is passed to
//                                 fn(ctx, rec, text) -> char* before capture
//                                 (the "+ N others" row is never tinted).
//                                 `rec` is the ROW_SZ record (login @0,
//                                 count @32).
//    tc_frame_count (u64 .bss)  number of lines captured by the last
//                                 tc_render_text call while armed.
//
//  Reads (frozen, READ-ONLY): tc_opts / tc_window / tc_users / tc_tally /
//    tc_listing, tc_excl_set / tc_excl_sources / tc_excl_src_count,
//    tc_channel_name / tc_count_column / tc_user_state (tc_core.S),
//    tc_source_str (tc_cli.S), tc_shorten_path (tc_config.S),
//    tc_cache_status (Phase 5 stub / Phase 6 real module).
//
//  Notes
//  -----
//    * Row cap: --top wins, then --json is unlimited, then the terminal
//      height (isatty + TIOCGWINSZ); piped output is unlimited.  limit 0 =
//      no cap.
//    * Share sorts rank by 1000x fixed-point keys (floor(1000*state/total)),
//      a documented deviation from Python's float comparison; ties break by
//      login so the order is total.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"

// ----------------------------------------------------------------------------
// Externals
// ----------------------------------------------------------------------------
    .globl malloc
    .globl free
    .globl qsort
    .globl strcmp
    .globl tc_snprintf_d
    .globl isatty
    .globl tc_ioctl_p
    .globl write
    .globl memset
    .globl tc_strlen
    .globl tc_puts
    .globl tc_eputs
    .globl tc_fail
    .globl tc_source_str
    .globl tc_channel_name
    .globl tc_count_column
    .globl tc_user_state
    .globl tc_excl_contains
    .globl tc_shorten_path
    .globl tc_cache_status
    .globl tc_json_emit
    .globl tc_json_err

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ ROW_LOGIN,       0
    .equ ROW_COUNT,       32
    .equ ROW_LIVE,        40
    .equ ROW_OFFLINE,     48
    .equ ROW_UNKNOWN,     56
    .equ ROW_KEY,         64
    .equ ROW_SZ,          72
    .equ HDR_DESC_SZ,     32
    .equ HDR_MAX,         16
    .equ ARENA_SZ,        8192
    .equ LINE_SZ,         2048
    .equ CELL_SZ,         96
    .equ ERR_SZ,          256
    .equ NAME_SZ,         26

// ----------------------------------------------------------------------------
// .bss — the plan.  These symbols are exported so tc_json.S (and, later,
// watch mode) can read the presentation without re-deriving it.
// ----------------------------------------------------------------------------
    .bss
    .p2align 4
    .global tc_plan_columns
    .global tc_plan_col_count
    .global tc_plan_sort
    .global tc_plan_share_floor
    .global tc_plan_below_floor
    .global tc_plan_shares_shown
    .global tc_plan_reported
    .global tc_plan_reported_n
    .global tc_plan_displayed_n
    .global tc_plan_hidden_n
    .global tc_plan_limit
    .global tc_plan_limit_src
    .global tc_plan_header_mode
    .global tc_plan_in_range
    .global tc_plan_excl_appeared
    .global tc_plan_excl_msgs
    .global tc_plan_hdr_count
    .global tc_plan_excl_names
    .global tc_plan_excl_names_n
    .global tc_plan_msgs_shown
    .global tc_plan_msgs_hidden
    .global tc_plan_cache_used
    .global tc_plan_cache_reused
    .global tc_plan_cache_parsed
    .global tc_plan_cache_problem
    .global tc_plan_cache_rebuilt
    .global tc_plan_cache_path
    .global tc_plan_rows
    .global tc_plan_arena
    .global tc_plan_arena_cur
    .global tc_plan_src_join
tc_plan_columns:     .skip 6 * 8
tc_plan_col_count:   .skip 8
tc_plan_sort:        .skip 8
tc_plan_share_floor: .skip 8
tc_plan_below_floor: .skip 8
tc_plan_shares_shown:.skip 8
tc_plan_reported:    .skip 8
tc_plan_reported_n:  .skip 8
tc_plan_displayed_n: .skip 8
tc_plan_hidden_n:    .skip 8
tc_plan_limit:       .skip 8
tc_plan_limit_src:   .skip 8
tc_plan_header_mode: .skip 8
tc_plan_in_range:    .skip 8
tc_plan_excl_appeared:.skip 8
tc_plan_excl_msgs:   .skip 8
tc_plan_hdr_count:   .skip 8
tc_plan_excl_names:  .skip 8
tc_plan_excl_names_n:.skip 8
tc_plan_msgs_shown:  .skip 8
tc_plan_msgs_hidden: .skip 8
tc_plan_cache_used:  .skip 8
tc_plan_cache_reused:.skip 8
tc_plan_cache_parsed:.skip 8
tc_plan_cache_problem:.skip 8
tc_plan_cache_rebuilt:.skip 8
tc_plan_cache_path:  .skip 8
tc_plan_rows:        .skip HDR_MAX * HDR_DESC_SZ
tc_plan_arena:       .skip ARENA_SZ
tc_plan_arena_cur:   .skip 8
tc_plan_src_join:    .skip 8
tc_render_compact:   .skip LINE_SZ
tc_render_line:      .skip LINE_SZ
tc_render_cell:      .skip CELL_SZ
tc_render_errbuf:    .skip ERR_SZ
    .p2align 4
    .global tc_frame_capture
    .global tc_frame_lines
    .global tc_frame_max
    .global tc_frame_count
    .global tc_frame_pin_width
    .global tc_frame_tint_fn
    .global tc_frame_tint_ctx
tc_frame_capture:  .skip 8
tc_frame_lines:    .skip 8
tc_frame_max:      .skip 8
tc_frame_count:    .skip 8
tc_frame_pin_width:.skip 8
tc_frame_tint_fn:  .skip 8
tc_frame_tint_ctx: .skip 8

// ----------------------------------------------------------------------------
// .rodata
// ----------------------------------------------------------------------------
    RODATA
    .p2align 3
dbl_100:            .double 100.0
s_share_fmt:        .asciz "%.1f%%"
s_middot:           .ascii " \xC2\xB7 "
s_middot_end:
    .equ s_middot_len, s_middot_end - s_middot

s_label_channel:    .asciz "channel"
s_label_logs_dir:   .asciz "logs dir"
s_label_begin:      .asciz "begin"
s_label_end:        .asciz "end"
s_label_threshold:  .asciz "threshold"
s_label_users:      .asciz "users"
s_label_state:      .asciz "state"
s_label_exclude:    .asciz "exclude"
s_label_columns:    .asciz "columns"
s_label_sort:       .asciz "sort"
s_label_share_floor:.asciz "share floor"
s_label_config:     .asciz "config"
s_label_cache:      .asciz "cache"
s_label_unreadable: .asciz "unreadable"
s_label_top:        .asciz "top"
s_label_files:      .asciz "files"

s_ge:               .asciz ">= "
s_msgs:             .asciz " message(s)"
s_ge_only:          .asciz ">="
s_now:              .asciz "..now"
s_dotdot:           .asciz ".."
s_keeps:            .asciz " keeps "
s_not_filtered:     .asciz "not filtered"
s_only:             .asciz " only"
s_login_s:          .asciz " login(s), "
s_in_range_colon:   .asciz " in range: "
s_comma_more:       .asciz ", +"
s_more:             .asciz " more"
s_count_comma:      .asciz "count, "
s_comma:            .asciz ", "
s_by:               .asciz "by "
s_asked_for:        .asciz " asked for, "
s_found_over:       .asciz " found over "
s_day_s_reused:     .asciz " day(s) reused, "
s_parsed:           .asciz " parsed"
s_unavailable:      .asciz "unavailable -- "
s_every_file:       .asciz "every file parsed"
s_no_cache_c:       .asciz "no cache"
s_rebuilt:          .asciz "rebuilt: "
s_rollup_db:        .asciz "rollup.db"
s_not_counted:      .asciz "not counted"
s_file_s_skipped:   .asciz " file(s) skipped: "
s_unread:           .asciz " unread"
s_row_s:            .asciz " row(s)"
s_hidden:           .asciz " hidden"
s_rows:             .asciz " rows"
s_user_s:           .asciz " user(s)"
s_above_threshold:  .asciz " above threshold ("
s_in_range_paren:   .asciz " in range)"
s_semicolon:        .asciz "; "
s_of:               .asciz " of "
s_msg_range:        .asciz " message(s) in range"
s_excluded_pre:     .asciz "excluded "
s_excluded_mid:     .asciz " user(s), "
s_not_counted2:     .asciz " message(s) not counted"
s_no_users:         .asciz "No users met the threshold ("
s_period:           .asciz ")."
s_files_val:        .asciz " log file(s) in range"
s_plus:             .asciz "+ "
s_others:           .asciz " others"
s_unlimited_json:   .asciz "unlimited for --json"
s_terminal_height:  .asciz "terminal height"
s_loaded:           .asciz "loaded"
s_degen_mid:        .asciz " counts one state only, so per-state columns and sorts would be degenerate -- drop the state filter to compare states"
s_floor_msgs:       .asciz " message(s), "
s_floor_dropped:    .asciz " user(s) dropped"
s_floor_compact:    .asciz "floor >="
s_floor_minus:      .asciz ", -"
s_floor_unused:     .asciz "floor unused"
s_floor_not:        .asciz "not applied -- no share is shown or sorted by"
s_floor_off:        .asciz "floor off"
s_floor_disabled:   .asciz "disabled -- every share shown, on however few messages"
s_oom:              .asciz "out of memory"

    .p2align 3
// state names indexed by TC_ST_* - 1
state_names:
    .quad s_m_live
    .quad s_m_offline
    .quad s_m_unknown
// policy names indexed by TC_POLICY_*
policy_names:
    .quad s_p_at_least
    .quad s_p_at_most
    .quad s_p_nearest
s_p_at_least:       .asciz "at-least"
s_p_at_most:        .asciz "at-most"
s_p_nearest:        .asciz "nearest"
// metric names indexed by TC_M_*
    .p2align 3
metric_names:
    .quad s_m_count
    .quad s_m_login
    .quad s_m_live
    .quad s_m_offline
    .quad s_m_unknown
    .quad s_m_offshare
    .quad s_m_liveshare
s_m_count:          .asciz "count"
s_m_login:          .asciz "login"
s_m_live:           .asciz "live"
s_m_offline:        .asciz "offline"
s_m_unknown:        .asciz "unknown"
s_m_offshare:       .asciz "offline-share"
s_m_liveshare:      .asciz "live-share"
// metric headers indexed by TC_M_*
    .p2align 3
metric_headers:
    .quad h_m_count
    .quad h_m_login
    .quad h_m_live
    .quad h_m_offline
    .quad h_m_unknown
    .quad h_m_offshare
    .quad h_m_liveshare
h_m_count:          .asciz "count"
h_m_login:          .asciz "login"
h_m_live:           .asciz "live"
h_m_offline:        .asciz "offline"
h_m_unknown:        .asciz "unknown"
h_m_offshare:       .asciz "offline%"
h_m_liveshare:      .asciz "live%"

    .text

// ============================================================================
// tc_report_fail — fail in the shape the caller was promised.
// ============================================================================
    .p2align 2
    .global tc_report_fail
    FUNC_TYPE(tc_report_fail)
tc_report_fail:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.eq .Lrf_text
    mov x0, x19
    bl tc_json_err                  // writes {"error": ...} to stderr, exits
.Lrf_text:
    mov x0, x19
    bl tc_fail

// ============================================================================
// String helpers
// ============================================================================

// line_zero() / compact_zero() — clear a render buffer so strlen-based padding
// never reads stale bytes from the previous line.
line_zero:
    stp x29, x30, [sp, #-16]!
    adrp x0, PAGE(tc_render_line)
    add x0, x0, LO12(tc_render_line)
    mov x1, #0
    mov x2, #LINE_SZ
    bl memset
    ldp x29, x30, [sp], #16
    ret

compact_zero:
    stp x29, x30, [sp, #-16]!
    adrp x0, PAGE(tc_render_compact)
    add x0, x0, LO12(tc_render_compact)
    mov x1, #0
    mov x2, #LINE_SZ
    bl memset
    ldp x29, x30, [sp], #16
    ret

// line_puts(s) — print s to stdout followed by a newline (every rendered line
// in this module ends with one, exactly like Python's print).  While frame
// capture is armed, copies the line into the next capture slot instead.
    .p2align 2
line_puts:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    adrp x9, PAGE(tc_frame_capture)
    add x9, x9, LO12(tc_frame_capture)
    ldr x9, [x9]
    cbz x9, .Llp_print
    // capture: copy into tc_frame_lines[count] (drop when the frame is full)
    adrp x9, PAGE(tc_frame_count)
    add x9, x9, LO12(tc_frame_count)
    ldr x10, [x9]
    adrp x11, PAGE(tc_frame_max)
    add x11, x11, LO12(tc_frame_max)
    ldr x11, [x11]
    cmp x10, x11
    b.ge .Llp_cap_done
    adrp x11, PAGE(tc_frame_lines)
    add x11, x11, LO12(tc_frame_lines)
    ldr x11, [x11]
    ldr x11, [x11, x10, lsl #3]
    mov x0, x11
    mov x1, x19
    bl str_cat
    add x10, x10, #1
    str x10, [x9]
.Llp_cap_done:
    ldp x19, x30, [sp], #16
    ret
.Llp_print:
    bl tc_puts
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    ldp x19, x30, [sp], #16
    ret

// line_blank() — the blank separator line (Python's header_lines trailing "").
    .p2align 2
line_blank:
    stp x19, x30, [sp, #-16]!
    adrp x9, PAGE(tc_frame_capture)
    add x9, x9, LO12(tc_frame_capture)
    ldr x9, [x9]
    cbz x9, .Llb_print
    adrp x9, PAGE(tc_frame_count)
    add x9, x9, LO12(tc_frame_count)
    ldr x10, [x9]
    adrp x11, PAGE(tc_frame_max)
    add x11, x11, LO12(tc_frame_max)
    ldr x11, [x11]
    cmp x10, x11
    b.ge .Llb_done
    adrp x11, PAGE(tc_frame_lines)
    add x11, x11, LO12(tc_frame_lines)
    ldr x11, [x11]
    ldr x11, [x11, x10, lsl #3]
    mov w0, #0
    strb w0, [x11]
    add x10, x10, #1
    str x10, [x9]
.Llb_done:
    ldp x19, x30, [sp], #16
    ret
.Llb_print:
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// Frame-capture API (Phase 7, watch mode)
// ============================================================================
    .p2align 2
    .global tc_frame_begin
    FUNC_TYPE(tc_frame_begin)
tc_frame_begin:
    stp x29, x30, [sp, #-16]!
    adrp x9, PAGE(tc_frame_lines)
    add x9, x9, LO12(tc_frame_lines)
    str x0, [x9]
    adrp x9, PAGE(tc_frame_max)
    add x9, x9, LO12(tc_frame_max)
    str x1, [x9]
    adrp x9, PAGE(tc_frame_count)
    add x9, x9, LO12(tc_frame_count)
    str xzr, [x9]
    adrp x9, PAGE(tc_frame_capture)
    add x9, x9, LO12(tc_frame_capture)
    mov x10, #1
    str x10, [x9]
    ldp x29, x30, [sp], #16
    ret

    .p2align 2
    .global tc_frame_end
    FUNC_TYPE(tc_frame_end)
tc_frame_end:
    stp x29, x30, [sp, #-16]!
    adrp x9, PAGE(tc_frame_capture)
    add x9, x9, LO12(tc_frame_capture)
    str xzr, [x9]
    ldp x29, x30, [sp], #16
    ret

    .p2align 2
    .global tc_frame_set_pin
    FUNC_TYPE(tc_frame_set_pin)
tc_frame_set_pin:
    stp x29, x30, [sp, #-16]!
    adrp x9, PAGE(tc_frame_pin_width)
    add x9, x9, LO12(tc_frame_pin_width)
    str x0, [x9]
    ldp x29, x30, [sp], #16
    ret

    .p2align 2
    .global tc_frame_set_tint
    FUNC_TYPE(tc_frame_set_tint)
tc_frame_set_tint:
    stp x29, x30, [sp, #-16]!
    adrp x9, PAGE(tc_frame_tint_fn)
    add x9, x9, LO12(tc_frame_tint_fn)
    str x0, [x9]
    adrp x9, PAGE(tc_frame_tint_ctx)
    add x9, x9, LO12(tc_frame_tint_ctx)
    str x1, [x9]
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// pin_cell(dst, src, width) -> dst after the login cell (Phase 7).
//   With tc_frame_pin_width > 0 and strlen(src) > width, writes width-1 bytes
//   of src then U+2026 (no padding: the ellipsis is one visible column).  In
//   the unclipped case copies src and pads to `width` exactly like the
//   existing pad_left_to callers.  The pinned width is applied to the widths
//   table by render_table before any emit, so `width` is already the pin.
// ============================================================================
    .p2align 2
pin_cell:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // dst
    mov x20, x1                        // src
    mov x21, x2                        // width
    adrp x9, PAGE(tc_frame_pin_width)
    add x9, x9, LO12(tc_frame_pin_width)
    ldr x9, [x9]
    cbz x9, .Lpc_pad
    mov x0, x20
    bl tc_strlen
    cmp x0, x21
    b.le .Lpc_pad
    sub x22, x21, #1                   // bytes before the ellipsis
    mov x0, x19
    mov x1, x20
    mov x2, x22
    bl str_cat_n
    mov w3, #0xE2
    strb w3, [x0], #1
    mov w3, #0x80
    strb w3, [x0], #1
    mov w3, #0xA6
    strb w3, [x0], #1
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lpc_pad:
    mov x0, x19
    mov x1, x20
    bl str_cat
    mov x0, x19
    mov x1, x21
    bl pad_left_to
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// str_cat(dst, src) -> dst after the copied NUL
    .p2align 2
str_cat:
    mov x2, x0
.Lsc_loop:
    ldrb w3, [x1], #1
    strb w3, [x2], #1
    cbnz w3, .Lsc_loop
    mov x0, x2
    ret

// str_cat_n(dst, src, len) -> dst + len (no NUL)
    .p2align 2
str_cat_n:
    mov x3, #0
.Lscn_loop:
    cmp x3, x2
    b.ge .Lscn_done
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    b .Lscn_loop
.Lscn_done:
    add x0, x0, x2
    ret

// fmt_u64_plain(dst, v) -> dst after digits (no NUL)
    .p2align 2
fmt_u64_plain:
    stp x29, x30, [sp, #-16]!
    sub sp, sp, #32
    add x2, sp, #20
    cmp x1, #0
    b.ne .Lfup_digits
    mov w3, #'0'
    strb w3, [x2, #-1]!
    b .Lfup_copy
.Lfup_digits:
    mov x4, #10
.Lfup_loop:
    udiv x5, x1, x4
    msub x6, x5, x4, x1
    add x6, x6, #'0'
    strb w6, [x2, #-1]!
    mov x1, x5
    cbnz x1, .Lfup_loop
.Lfup_copy:
    add x3, sp, #20
.Lfup_copy_loop:
    cmp x2, x3
    b.ge .Lfup_done
    ldrb w6, [x2], #1
    strb w6, [x0], #1
    b .Lfup_copy_loop
.Lfup_done:
    add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret

// fmt_u64_commas(dst, v) -> dst after digits (no NUL), thousands commas
    .p2align 2
fmt_u64_commas:
    stp x29, x30, [sp, #-16]!
    sub sp, sp, #40
    add x2, sp, #28
    cmp x1, #0
    b.ne .Lfuc_digits
    mov w3, #'0'
    strb w3, [x2, #-1]!
    b .Lfuc_copy
.Lfuc_digits:
    mov x4, #10
.Lfuc_loop:
    udiv x5, x1, x4
    msub x6, x5, x4, x1
    add x6, x6, #'0'
    strb w6, [x2, #-1]!
    mov x1, x5
    cbnz x1, .Lfuc_loop
.Lfuc_copy:
    add x3, sp, #28
    sub x4, x3, x2
    mov x5, #0
.Lfuc_copy_loop:
    cmp x2, x3
    b.ge .Lfuc_done
    ldrb w6, [x2], #1
    strb w6, [x0], #1
    add x5, x5, #1
    sub x7, x4, x5
    cmp x7, #0
    b.le .Lfuc_copy_loop
    mov x8, #3
    udiv x9, x7, x8
    msub x10, x9, x8, x7
    cbnz x10, .Lfuc_copy_loop
    mov w11, #','
    strb w11, [x0], #1
    b .Lfuc_copy_loop
.Lfuc_done:
    add sp, sp, #40
    ldp x29, x30, [sp], #16
    ret

// fmt2(dst, w1=0..99) -> dst+2 zero-padded
    .p2align 2
fmt2:
    mov x2, #10
    udiv x3, x1, x2
    msub x4, x3, x2, x1
    add x3, x3, #'0'
    strb w3, [x0], #1
    add x4, x4, #'0'
    strb w4, [x0], #1
    ret

// fmt4(dst, x1=0..9999) -> dst+4
    .p2align 2
fmt4:
    mov x2, #1000
    udiv x3, x1, x2
    msub x4, x3, x2, x1
    add x3, x3, #'0'
    strb w3, [x0], #1
    mov x2, #100
    udiv x3, x4, x2
    msub x5, x3, x2, x4
    add x3, x3, #'0'
    strb w3, [x0], #1
    mov x2, #10
    udiv x3, x5, x2
    msub x6, x3, x2, x5
    add x3, x3, #'0'
    strb w3, [x0], #1
    add x6, x6, #'0'
    strb w6, [x0], #1
    ret

// fmt_datetime(dst, ymd, sod, sep) -> dst+19, "YYYY-MM-DD<sep>HH:MM:SS"
    .p2align 2
fmt_datetime:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov w22, w3
    mov x1, x20
    mov x2, #10000
    udiv x6, x20, x2
    mov x0, x19
    mov x1, x6
    bl fmt4
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #100
    udiv x6, x20, x2
    mov x8, #100
    udiv x9, x6, x8
    msub x9, x9, x8, x6
    mov w1, w9
    bl fmt2
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #100
    udiv x6, x20, x2
    msub x6, x6, x2, x20
    mov w1, w6
    bl fmt2
    strb w22, [x0], #1
    mov x1, x21
    mov x2, #3600
    udiv x6, x21, x2
    mov w1, w6
    bl fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #3600
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    mov w1, w6
    bl fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #3600
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    msub x6, x6, x2, x9
    mov w1, w6
    bl fmt2
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// fmt_hhmm(dst, sod) -> dst+5, "HH:MM"  (sod survives the fmt2 calls)
    .p2align 2
fmt_hhmm:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x1                        // sod
    mov x2, #3600
    udiv x3, x19, x2
    mov w1, w3
    bl fmt2                            // hour
    mov w3, #':'
    strb w3, [x0], #1
    mov x2, #3600
    udiv x4, x19, x2
    msub x4, x4, x2, x19
    mov x2, #60
    udiv x4, x4, x2
    mov w1, w4
    bl fmt2                            // minute
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// fmt_mmdd_hhmm(dst, ymd, sod) -> dst+11, "MM-DD HH:MM"
    .p2align 2
fmt_mmdd_hhmm:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // dst
    mov x20, x1                        // ymd
    mov x21, x2                        // sod
    mov x2, #100
    udiv x3, x20, x2
    mov x4, #100
    udiv x5, x3, x4
    msub x5, x5, x4, x3
    mov w1, w5
    bl fmt2                            // month
    mov w3, #'-'
    strb w3, [x0], #1
    mov x2, #100
    udiv x3, x20, x2
    msub x3, x3, x2, x20
    mov w1, w3
    bl fmt2                            // day
    mov w3, #' '
    strb w3, [x0], #1
    mov x1, x21
    bl fmt_hhmm
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// fmt_ymd(dst, ymd) -> dst+10, "YYYY-MM-DD"  (ymd survives the fmt calls)
    .p2align 2
fmt_ymd:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // dst
    mov x20, x1                        // ymd
    mov x2, #10000
    udiv x3, x20, x2
    mov w1, w3
    bl fmt4                            // year
    mov w3, #'-'
    strb w3, [x0], #1
    mov x2, #100
    udiv x3, x20, x2
    mov x4, #100
    udiv x5, x3, x4
    msub x5, x5, x4, x3
    mov w1, w5
    bl fmt2                            // month
    mov w3, #'-'
    strb w3, [x0], #1
    mov x2, #100
    udiv x3, x20, x2
    msub x3, x3, x2, x20
    mov w1, w3
    bl fmt2                            // day
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// fmt_human_duration(dst, seconds) -> dst after NUL (Python human_duration)
    .p2align 2
fmt_human_duration:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    cbnz x20, .Lfhd_units
    mov w2, #'0'
    strb w2, [x19], #1
    mov w2, #'s'
    strb w2, [x19], #1
    mov w2, #0
    strb w2, [x19], #1
    b .Lfhd_done
.Lfhd_units:
    movz x2, #0x1, lsl #16            // 86400
    movk x2, #0x5180, lsl #0
    cmp x20, x2
    b.lt .Lfhd_hours
    udiv x3, x20, x2
    msub x20, x3, x2, x20
    mov x0, x19
    mov x1, x3
    bl fmt_u64_plain
    mov w2, #'d'
    strb w2, [x0], #1
    mov x19, x0
.Lfhd_hours:
    cmp x20, #3600
    b.lt .Lfhd_mins
    mov x2, #3600
    udiv x3, x20, x2
    msub x20, x3, x2, x20
    mov x0, x19
    mov x1, x3
    bl fmt_u64_plain
    mov w2, #'h'
    strb w2, [x0], #1
    mov x19, x0
.Lfhd_mins:
    cmp x20, #60
    b.lt .Lfhd_secs
    mov x2, #60
    udiv x3, x20, x2
    msub x20, x3, x2, x20
    mov x0, x19
    mov x1, x3
    bl fmt_u64_plain
    mov w2, #'m'
    strb w2, [x0], #1
    mov x19, x0
.Lfhd_secs:
    cmp x20, #1
    b.lt .Lfhd_nul
    mov x0, x19
    mov x1, x20
    bl fmt_u64_plain
    mov w2, #'s'
    strb w2, [x0], #1
    mov x19, x0
.Lfhd_nul:
    mov w2, #0
    strb w2, [x19], #1
.Lfhd_done:
    mov x0, x19
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// fmt_share_cell(dst, state, total) -> dst + chars; "%.1f%%" of 100*state/total
    .p2align 2
fmt_share_cell:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x2
    cbnz x20, .Lfsc_div
    fmov d0, xzr
    b .Lfsc_go
.Lfsc_div:
    ucvtf d0, x1
    adrp x9, PAGE(dbl_100)
    add x9, x9, LO12(dbl_100)
    ldr d1, [x9]
    fmul d0, d0, d1
    ucvtf d1, x20
    fdiv d0, d0, d1
.Lfsc_go:
    mov x0, x19
    mov x1, #CELL_SZ
    adrp x2, PAGE(s_share_fmt)
    add x2, x2, LO12(s_share_fmt)
    bl tc_snprintf_d
    add x0, x19, x0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// Arena helpers
// ============================================================================

// arena_get() -> x0 = current end pointer
    .p2align 2
arena_get:
    adrp x1, PAGE(tc_plan_arena_cur)
    add x1, x1, LO12(tc_plan_arena_cur)
    ldr x2, [x1]
    adrp x0, PAGE(tc_plan_arena)
    add x0, x0, LO12(tc_plan_arena)
    add x0, x0, x2
    ret

// arena_set_end(x0=end ptr): cur = end - arena_base
    .p2align 2
arena_set_end:
    adrp x1, PAGE(tc_plan_arena)
    add x1, x1, LO12(tc_plan_arena)
    sub x0, x0, x1
    adrp x2, PAGE(tc_plan_arena_cur)
    add x2, x2, LO12(tc_plan_arena_cur)
    str x0, [x2]
    ret

// hdr_add(label, value, source, compact) — append one HeaderRow descriptor
    .p2align 2
hdr_add:
    adrp x4, PAGE(tc_plan_hdr_count)
    add x4, x4, LO12(tc_plan_hdr_count)
    ldr x5, [x4]
    cmp x5, #HDR_MAX
    b.ge .Lha_done
    adrp x6, PAGE(tc_plan_rows)
    add x6, x6, LO12(tc_plan_rows)
    mov x7, #HDR_DESC_SZ
    mul x7, x5, x7
    add x6, x6, x7
    str x0, [x6, #0]
    str x1, [x6, #8]
    str x2, [x6, #16]
    str x3, [x6, #24]
    add x5, x5, #1
    str x5, [x4]
.Lha_done:
    ret

// src_str(set_id) -> x0 = source string ptr (tc_source_str result)
    .p2align 2
src_str:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    movz x2, #TC_O_SRC
    add x0, x0, x2
    ldr x0, [x0, x19, lsl #3]
    bl tc_source_str
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// tc_plan_presentation — the layout phase (Python plan_presentation).
// ============================================================================
    .p2align 2
    .global tc_plan_presentation
    FUNC_TYPE(tc_plan_presentation)
tc_plan_presentation:
    stp x29, x30, [sp, #-16]!
    // reset the plan
    adrp x0, PAGE(tc_plan_arena_cur)
    add x0, x0, LO12(tc_plan_arena_cur)
    str xzr, [x0]
    adrp x0, PAGE(tc_plan_hdr_count)
    add x0, x0, LO12(tc_plan_hdr_count)
    str xzr, [x0]
    adrp x0, PAGE(tc_plan_src_join)
    add x0, x0, LO12(tc_plan_src_join)
    str xzr, [x0]
    adrp x0, PAGE(tc_plan_reported)
    add x0, x0, LO12(tc_plan_reported)
    str xzr, [x0]
    adrp x0, PAGE(tc_plan_excl_names)
    add x0, x0, LO12(tc_plan_excl_names)
    str xzr, [x0]
    adrp x0, PAGE(tc_plan_share_floor)
    add x0, x0, LO12(tc_plan_share_floor)
    str xzr, [x0]
    adrp x0, PAGE(tc_plan_below_floor)
    add x0, x0, LO12(tc_plan_below_floor)
    str xzr, [x0]

    bl plan_degeneracy_check
    bl plan_columns
    bl plan_rank
    bl plan_exclusions
    bl plan_cache_snapshot
    bl build_header_rows
    bl choose_limit
    bl plan_split_display
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// plan_degeneracy_check — exit 1 when a state filter meets state columns.
// ============================================================================
    .p2align 2
plan_degeneracy_check:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_STATE_FILTER]
    cbz x20, .Lpdeg_done
    adrp x21, PAGE(tc_opts)
    add x21, x21, LO12(tc_opts)
    ldr x22, [x21, #TC_O_SORT]
    cmp x22, #TC_M_LIVE
    b.lt .Lpdeg_cols
    cmp x22, #TC_M_LIVE_SHARE
    b.le .Lpdeg_fail
.Lpdeg_cols:
    ldr x23, [x21, #TC_O_COLUMN_COUNT]
    mov x24, #0
.Lpdeg_col_loop:
    cmp x24, x23
    b.ge .Lpdeg_done
    add x25, x21, #TC_O_COLUMNS
    ldr x26, [x25, x24, lsl #3]
    cmp x26, #TC_M_LIVE
    b.lt .Lpdeg_col_next
    cmp x26, #TC_M_LIVE_SHARE
    b.le .Lpdeg_fail
.Lpdeg_col_next:
    add x24, x24, #1
    b .Lpdeg_col_loop
.Lpdeg_fail:
    adrp x0, PAGE(tc_render_errbuf)
    add x0, x0, LO12(tc_render_errbuf)
    mov w1, #'-'
    strb w1, [x0], #1
    mov w1, #'-'
    strb w1, [x0], #1
    adrp x1, PAGE(state_names)
    add x1, x1, LO12(state_names)
    sub x2, x20, #1
    ldr x1, [x1, x2, lsl #3]
    bl str_cat
    sub x0, x0, #1                    // overwrite the trailing NUL
    adrp x1, PAGE(s_degen_mid)
    add x1, x1, LO12(s_degen_mid)
    bl str_cat
    adrp x0, PAGE(tc_render_errbuf)
    add x0, x0, LO12(tc_render_errbuf)
    bl tc_report_fail
.Lpdeg_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// plan_columns — copy TC_O_COLUMNS, sort and header mode; compute shares_shown.
// ============================================================================
    .p2align 2
plan_columns:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_COLUMN_COUNT]
    adrp x21, PAGE(tc_plan_columns)
    add x21, x21, LO12(tc_plan_columns)
    str x20, [x21, #48]              // plan_col_count
    mov x22, #0
.Lpc_copy:
    cmp x22, x20
    b.ge .Lpc_copy_done
    add x23, x19, #TC_O_COLUMNS
    ldr x24, [x23, x22, lsl #3]
    str x24, [x21, x22, lsl #3]
    add x22, x22, #1
    b .Lpc_copy
.Lpc_copy_done:
    ldr x23, [x19, #TC_O_SORT]
    str x23, [x21, #56]              // plan_sort
    ldr x24, [x19, #TC_O_HEADER_MODE]
    str x24, [x21, #136]             // plan_header_mode
    // shares_shown
    mov x25, #0
    cmp x23, #TC_M_OFFLINE_SHARE
    b.lt .Lpc_ss_cols
    cmp x23, #TC_M_LIVE_SHARE
    b.le .Lpc_ss_yes
.Lpc_ss_cols:
    mov x26, #0
.Lpc_ss_loop:
    cmp x26, x20
    b.ge .Lpc_ss_done
    ldr x27, [x21, x26, lsl #3]
    cmp x27, #TC_M_OFFLINE_SHARE
    b.lt .Lpc_ss_next
    cmp x27, #TC_M_LIVE_SHARE
    b.le .Lpc_ss_yes
.Lpc_ss_next:
    add x26, x26, #1
    b .Lpc_ss_loop
.Lpc_ss_yes:
    mov x25, #1
.Lpc_ss_done:
    str x25, [x21, #80]              // plan_shares_shown
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// plan_rank — walk the user table into the reported array, apply the share
// floor, compute share sort keys, qsort, and join 'unknown' when --by-state
// sees any.
// ============================================================================
    .p2align 2
plan_rank:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // pass 1: counts
    adrp x19, PAGE(tc_users)
    add x19, x19, LO12(tc_users)
    ldr x20, [x19, #TC_US_COUNT]
    ldr x21, [x19, #TC_US_ENTRIES]
    adrp x22, PAGE(tc_window)
    add x22, x22, LO12(tc_window)
    ldr x23, [x22, #TC_W_THRESHOLD]
    mov x24, #0                      // reported_n
    mov x25, #0                      // in_range
    mov x26, #0                      // excl_appeared
    mov x27, #0                      // excl_msgs
    mov x28, #0                      // i
.Lpr_walk1:
    cmp x28, x20
    b.ge .Lpr_walk1_done
    mov x0, #TC_US_ENTRY_SZ
    mul x0, x28, x0
    add x10, x21, x0                // entry (tc_strlen clobbers x0-x2 only)
    mov x0, x10
    bl tc_strlen
    mov x2, x0
    mov x0, x10
    mov x1, x2
    bl tc_excl_contains
    mov x9, x0
    mov x0, x28
    bl tc_count_column
    mov x10, x0
    cbnz x9, .Lpr_w1_excl
    cbz x10, .Lpr_w1_next
    add x25, x25, #1
    cmp x10, x23
    b.lt .Lpr_w1_next
    add x24, x24, #1
    b .Lpr_w1_next
.Lpr_w1_excl:
    cbz x10, .Lpr_w1_next
    add x26, x26, #1
    add x27, x27, x10
.Lpr_w1_next:
    add x28, x28, #1
    b .Lpr_walk1
.Lpr_walk1_done:
    adrp x28, PAGE(tc_plan_reported_n)
    add x28, x28, LO12(tc_plan_reported_n)
    str x24, [x28]
    adrp x28, PAGE(tc_plan_in_range)
    add x28, x28, LO12(tc_plan_in_range)
    str x25, [x28]
    adrp x28, PAGE(tc_plan_excl_appeared)
    add x28, x28, LO12(tc_plan_excl_appeared)
    str x26, [x28]
    adrp x28, PAGE(tc_plan_excl_msgs)
    add x28, x28, LO12(tc_plan_excl_msgs)
    str x27, [x28]
    // allocate
    cbz x24, .Lpr_alloc_done
    mov x0, #ROW_SZ
    mul x0, x24, x0
    bl malloc
    cbz x0, .Lpr_oom
    adrp x28, PAGE(tc_plan_reported)
    add x28, x28, LO12(tc_plan_reported)
    str x0, [x28]
.Lpr_alloc_done:
    // pass 2: fill
    adrp x19, PAGE(tc_users)
    add x19, x19, LO12(tc_users)
    ldr x20, [x19, #TC_US_COUNT]
    ldr x21, [x19, #TC_US_ENTRIES]
    adrp x22, PAGE(tc_window)
    add x22, x22, LO12(tc_window)
    ldr x23, [x22, #TC_W_THRESHOLD]
    adrp x24, PAGE(tc_plan_reported)
    add x24, x24, LO12(tc_plan_reported)
    ldr x24, [x24]
    mov x25, #0                      // fill index
    mov x26, #0                      // i
.Lpr_walk2:
    cmp x26, x20
    b.ge .Lpr_walk2_done
    mov x0, #TC_US_ENTRY_SZ
    mul x0, x26, x0
    add x10, x21, x0                // entry (tc_strlen clobbers x0-x2 only)
    mov x0, x10
    bl tc_strlen
    mov x2, x0
    mov x0, x10
    mov x1, x2
    bl tc_excl_contains
    cbnz x0, .Lpr_w2_next
    mov x0, x26
    bl tc_count_column
    cmp x0, x23
    b.lt .Lpr_w2_next
    mov x0, #ROW_SZ
    mul x0, x25, x0
    add x27, x24, x0
    mov x0, #TC_US_ENTRY_SZ
    mul x0, x26, x0
    add x0, x21, x0
    add x1, x27, #ROW_LOGIN
    mov x2, #0
.Lpr_w2_login:
    ldrb w3, [x0, x2]
    strb w3, [x1, x2]
    cbz w3, .Lpr_w2_login_done
    add x2, x2, #1
    cmp x2, #25
    b.lt .Lpr_w2_login
.Lpr_w2_login_done:
    mov w3, #0
    strb w3, [x1, x2]
    mov x0, x26
    bl tc_count_column
    str x0, [x27, #ROW_COUNT]
    mov x0, x26
    mov x1, #TC_ST_LIVE
    bl tc_user_state
    str x0, [x27, #ROW_LIVE]
    mov x0, x26
    mov x1, #TC_ST_OFFLINE
    bl tc_user_state
    str x0, [x27, #ROW_OFFLINE]
    mov x0, x26
    mov x1, #TC_ST_UNKNOWN
    bl tc_user_state
    str x0, [x27, #ROW_UNKNOWN]
    add x25, x25, #1
.Lpr_w2_next:
    add x26, x26, #1
    b .Lpr_walk2
.Lpr_walk2_done:
    adrp x28, PAGE(tc_plan_reported_n)
    add x28, x28, LO12(tc_plan_reported_n)
    str x25, [x28]
    // ---- share floor -----------------------------------------------------
    adrp x19, PAGE(tc_plan_shares_shown)
    add x19, x19, LO12(tc_plan_shares_shown)
    ldr x19, [x19]
    adrp x20, PAGE(tc_opts)
    add x20, x20, LO12(tc_opts)
    ldr x20, [x20, #TC_O_SHARE_FLOOR]
    adrp x21, PAGE(tc_plan_reported)
    add x21, x21, LO12(tc_plan_reported)
    ldr x21, [x21]
    adrp x22, PAGE(tc_plan_reported_n)
    add x22, x22, LO12(tc_plan_reported_n)
    ldr x22, [x22]
    cbz x19, .Lpr_floor_none
    cbz x20, .Lpr_floor_none
    mov x23, #0                      // kept
    mov x24, #0                      // i
.Lpr_floor_loop:
    cmp x24, x22
    b.ge .Lpr_floor_apply
    mov x0, #ROW_SZ
    mul x0, x24, x0
    add x0, x21, x0
    ldr x1, [x0, #ROW_COUNT]
    cmp x1, x20
    b.lt .Lpr_floor_next
    cmp x23, x24
    b.eq .Lpr_floor_keep
    mov x2, #ROW_SZ
    mul x2, x23, x2
    add x2, x21, x2
    mov x3, #0
.Lpr_floor_copy:
    cmp x3, #ROW_SZ
    b.ge .Lpr_floor_keep
    ldrb w4, [x0, x3]
    strb w4, [x2, x3]
    add x3, x3, #1
    b .Lpr_floor_copy
.Lpr_floor_keep:
    add x23, x23, #1
.Lpr_floor_next:
    add x24, x24, #1
    b .Lpr_floor_loop
.Lpr_floor_apply:
    adrp x24, PAGE(tc_plan_share_floor)
    add x24, x24, LO12(tc_plan_share_floor)
    str x20, [x24]
    adrp x25, PAGE(tc_plan_below_floor)
    add x25, x25, LO12(tc_plan_below_floor)
    sub x26, x22, x23
    str x26, [x25]
    adrp x25, PAGE(tc_plan_reported_n)
    add x25, x25, LO12(tc_plan_reported_n)
    str x23, [x25]
    mov x22, x23
    b .Lpr_keys
.Lpr_floor_none:
    adrp x24, PAGE(tc_plan_share_floor)
    add x24, x24, LO12(tc_plan_share_floor)
    str xzr, [x24]
.Lpr_keys:
    // share sort keys (fixed point 1000*state/count)
    adrp x19, PAGE(tc_plan_sort)
    add x19, x19, LO12(tc_plan_sort)
    ldr x20, [x19]
    cmp x20, #TC_M_OFFLINE_SHARE
    b.eq .Lpr_keys_do
    cmp x20, #TC_M_LIVE_SHARE
    b.ne .Lpr_sort
.Lpr_keys_do:
    adrp x21, PAGE(tc_plan_reported)
    add x21, x21, LO12(tc_plan_reported)
    ldr x21, [x21]
    mov x23, #0
.Lpr_keys_loop:
    cmp x23, x22
    b.ge .Lpr_sort
    mov x0, #ROW_SZ
    mul x0, x23, x0
    add x0, x21, x0
    cmp x20, #TC_M_OFFLINE_SHARE
    b.eq .Lpr_keys_off
    ldr x1, [x0, #ROW_LIVE]
    b .Lpr_keys_calc
.Lpr_keys_off:
    ldr x1, [x0, #ROW_OFFLINE]
.Lpr_keys_calc:
    ldr x2, [x0, #ROW_COUNT]
    mov x3, #1000
    mul x1, x1, x3
    udiv x1, x1, x2
    str x1, [x0, #ROW_KEY]
    add x23, x23, #1
    b .Lpr_keys_loop
.Lpr_sort:
    cbz x22, .Lpr_unknown
    adrp x0, PAGE(tc_plan_reported)
    add x0, x0, LO12(tc_plan_reported)
    ldr x0, [x0]
    mov x1, x22
    mov x2, #ROW_SZ
    adrp x3, PAGE(tc_render_cmp)
    add x3, x3, LO12(tc_render_cmp)
    bl qsort
.Lpr_unknown:
    // unknown joins when --by-state and any reported row has unknown > 0
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_FLAGS]
    tst x20, #TC_F_BY_STATE
    b.eq .Lpr_done
    adrp x21, PAGE(tc_plan_reported)
    add x21, x21, LO12(tc_plan_reported)
    ldr x21, [x21]
    mov x23, #0
.Lpr_unk_scan:
    cmp x23, x22
    b.ge .Lpr_done
    mov x0, #ROW_SZ
    mul x0, x23, x0
    add x0, x21, x0
    ldr x1, [x0, #ROW_UNKNOWN]
    cbnz x1, .Lpr_unk_insert
    add x23, x23, #1
    b .Lpr_unk_scan
.Lpr_unk_insert:
    adrp x24, PAGE(tc_plan_col_count)
    add x24, x24, LO12(tc_plan_col_count)
    ldr x25, [x24]
    adrp x26, PAGE(tc_plan_columns)
    add x26, x26, LO12(tc_plan_columns)
    mov x27, #0
.Lpr_unk_dedupe:
    cmp x27, x25
    b.ge .Lpr_unk_find
    ldr x28, [x26, x27, lsl #3]
    cmp x28, #TC_M_UNKNOWN
    b.eq .Lpr_done
    add x27, x27, #1
    b .Lpr_unk_dedupe
.Lpr_unk_find:
    mov x27, #0
.Lpr_unk_find_loop:
    cmp x27, x25
    b.ge .Lpr_unk_at
    ldr x28, [x26, x27, lsl #3]
    cmp x28, #TC_M_OFFLINE_SHARE
    b.eq .Lpr_unk_at
    add x27, x27, #1
    b .Lpr_unk_find_loop
.Lpr_unk_at:
    mov x28, x25
.Lpr_unk_shift:
    cmp x28, x27
    b.le .Lpr_unk_place
    ldr x9, [x26, x28, lsl #3]
    sub x10, x28, #1
    str x9, [x26, x10, lsl #3]
    sub x28, x28, #1
    b .Lpr_unk_shift
.Lpr_unk_place:
    mov x9, #TC_M_UNKNOWN
    str x9, [x26, x27, lsl #3]
    add x25, x25, #1
    str x25, [x24]
.Lpr_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lpr_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_report_fail

// ============================================================================
// plan_exclusions — sorted exclusion logins + the ", "-joined sources.
// ============================================================================
    .p2align 2
plan_exclusions:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, PAGE(tc_excl_set)
    add x19, x19, LO12(tc_excl_set)
    ldr x20, [x19]                   // exclusion count
    adrp x21, PAGE(tc_plan_excl_names_n)
    add x21, x21, LO12(tc_plan_excl_names_n)
    str x20, [x21]
    cbz x20, .Lpex_sources
    mov x0, #NAME_SZ
    mul x0, x20, x0
    bl malloc
    cbz x0, .Lpex_oom
    adrp x21, PAGE(tc_plan_excl_names)
    add x21, x21, LO12(tc_plan_excl_names)
    str x0, [x21]
    ldr x21, [x21]
    add x22, x19, #8                 // entries base
    mov x23, #0
.Lpex_copy:
    cmp x23, x20
    b.ge .Lpex_sort
    mov x0, #TC_EX_ENTRY_SZ
    mul x0, x23, x0
    add x0, x22, x0
    mov x2, #NAME_SZ
    mul x2, x23, x2
    add x1, x21, x2
    mov x2, #0
.Lpex_copy_loop:
    ldrb w3, [x0, x2]
    strb w3, [x1, x2]
    cbz w3, .Lpex_copy_next
    add x2, x2, #1
    cmp x2, #25
    b.lt .Lpex_copy_loop
.Lpex_copy_next:
    add x23, x23, #1
    b .Lpex_copy
.Lpex_sort:
    adrp x0, PAGE(tc_plan_excl_names)
    add x0, x0, LO12(tc_plan_excl_names)
    ldr x0, [x0]
    mov x1, x20
    mov x2, #NAME_SZ
    adrp x3, PAGE(excl_name_cmp)
    add x3, x3, LO12(excl_name_cmp)
    bl qsort
.Lpex_sources:
    // ", "-join the exclusion source records into the arena
    adrp x19, PAGE(tc_excl_src_count)
    add x19, x19, LO12(tc_excl_src_count)
    ldr x20, [x19]
    bl arena_get
    mov x21, x0                      // dst start
    mov x22, x0                      // cursor
    mov x23, #0                      // i
    adrp x24, PAGE(tc_excl_sources)
    add x24, x24, LO12(tc_excl_sources)
.Lpex_join:
    cmp x23, x20
    b.ge .Lpex_join_done
    cbnz x23, .Lpex_join_sep
    b .Lpex_join_src
.Lpex_join_sep:
    // Wave E fix: str_cat copies the source's trailing NUL, so the ", "
    // separator NUL-terminated the joined source early and every source after
    // the first was truncated out of the header (observed: an exclude line
    // rendered as "[--exclude, ]" instead of
    // "[--exclude, --exclude-broadcaster]").  str_cat_n copies exactly the
    // separator without a NUL, matching the .Lbhr_excl_preview join below.
    mov x0, x22
    adrp x1, PAGE(s_comma)
    add x1, x1, LO12(s_comma)
    mov x2, #2
    bl str_cat_n
    mov x22, x0
.Lpex_join_src:
    mov x0, #TC_EX_SRC_ENTRY_SZ
    mul x0, x23, x0
    add x0, x24, x0
    ldr x1, [x0]
    ldr x2, [x0, #8]
    mov x0, x22
    bl str_cat_n
    mov x22, x0
    add x23, x23, #1
    b .Lpex_join
.Lpex_join_done:
    mov w0, #0
    strb w0, [x22]
    add x0, x22, #1
    bl arena_set_end
    cbz x20, .Lpex_join_skip         // no source records: keep src_join = 0
    adrp x0, PAGE(tc_plan_src_join)
    add x0, x0, LO12(tc_plan_src_join)
    str x21, [x0]
.Lpex_join_skip:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lpex_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_report_fail

// excl_name_cmp — qsort comparator for 26-byte login records
    .p2align 2
excl_name_cmp:
    stp x29, x30, [sp, #-16]!
    bl strcmp
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_render_cmp — qsort comparator for reported rows: metric desc, login asc.
// ============================================================================
    .p2align 2
tc_render_cmp:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    adrp x21, PAGE(tc_plan_sort)
    add x21, x21, LO12(tc_plan_sort)
    ldr x21, [x21]
    cmp x21, #TC_M_LOGIN
    b.eq .Lcmp_login
    cmp x21, #TC_M_LIVE
    b.eq .Lcmp_live
    cmp x21, #TC_M_OFFLINE
    b.eq .Lcmp_offline
    cmp x21, #TC_M_UNKNOWN
    b.eq .Lcmp_unknown
    cmp x21, #TC_M_OFFLINE_SHARE
    b.eq .Lcmp_key
    cmp x21, #TC_M_LIVE_SHARE
    b.eq .Lcmp_key
    // count
    ldr x2, [x19, #ROW_COUNT]
    ldr x3, [x20, #ROW_COUNT]
    cmp x2, x3
    b.gt .Lcmp_neg
    b.lt .Lcmp_pos
    b .Lcmp_login
.Lcmp_live:
    ldr x2, [x19, #ROW_LIVE]
    ldr x3, [x20, #ROW_LIVE]
    cmp x2, x3
    b.gt .Lcmp_neg
    b.lt .Lcmp_pos
    b .Lcmp_login
.Lcmp_offline:
    ldr x2, [x19, #ROW_OFFLINE]
    ldr x3, [x20, #ROW_OFFLINE]
    cmp x2, x3
    b.gt .Lcmp_neg
    b.lt .Lcmp_pos
    b .Lcmp_login
.Lcmp_unknown:
    ldr x2, [x19, #ROW_UNKNOWN]
    ldr x3, [x20, #ROW_UNKNOWN]
    cmp x2, x3
    b.gt .Lcmp_neg
    b.lt .Lcmp_pos
    b .Lcmp_login
.Lcmp_key:
    ldr x2, [x19, #ROW_KEY]
    ldr x3, [x20, #ROW_KEY]
    cmp x2, x3
    b.gt .Lcmp_neg
    b.lt .Lcmp_pos
    b .Lcmp_login
.Lcmp_login:
    add x0, x19, #ROW_LOGIN
    add x1, x20, #ROW_LOGIN
    bl strcmp
    b .Lcmp_done
.Lcmp_neg:
    mov x0, #-1
    b .Lcmp_done
.Lcmp_pos:
    mov x0, #1
.Lcmp_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// plan_cache_snapshot — call tc_cache_status once and remember the results.
// ============================================================================
    .p2align 2
plan_cache_snapshot:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_NO_CACHE
    b.ne .Lpcs_off
    bl tc_cache_status
    mov x19, x0                      // used
    mov x20, x1                      // reused
    mov x21, x2                      // parsed
    mov x22, x3                      // problem
    mov x23, x4                      // rebuilt
    mov x24, x5                      // path
    adrp x1, PAGE(tc_plan_cache_used)
    add x1, x1, LO12(tc_plan_cache_used)
    str x19, [x1]
    str x20, [x1, #8]
    str x21, [x1, #16]
    str x22, [x1, #24]
    str x23, [x1, #32]
    str x24, [x1, #40]
    b .Lpcs_done
.Lpcs_off:
    adrp x1, PAGE(tc_plan_cache_used)
    add x1, x1, LO12(tc_plan_cache_used)
    str xzr, [x1]
    str xzr, [x1, #8]
    str xzr, [x1, #16]
    str xzr, [x1, #24]
    str xzr, [x1, #32]
    str xzr, [x1, #40]
.Lpcs_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// build_header_rows — the provenance table (Python provenance_rows), in order.
// ============================================================================
    .p2align 2
build_header_rows:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!

    // ---- channel ---------------------------------------------------------
    adrp x19, PAGE(s_label_channel)
    add x19, x19, LO12(s_label_channel)
    bl tc_channel_name
    mov x20, x0
    mov x0, #TC_SET_CHANNEL
    bl src_str
    mov x21, x0
    mov x0, x19
    mov x1, x20
    mov x2, x21
    mov x3, x20
    bl hdr_add

    // ---- logs dir --------------------------------------------------------
    adrp x19, PAGE(s_label_logs_dir)
    add x19, x19, LO12(s_label_logs_dir)
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_LOGS_DIR
    bl tc_shorten_path
    mov x20, x0                       // shortened (scratch — copy now)
    bl arena_get
    mov x21, x0
    mov x0, x21
    mov x1, x20
    bl str_cat
    bl arena_set_end
    mov x0, #TC_SET_LOGS_DIR
    bl src_str
    mov x22, x0
    mov x0, x19
    mov x1, x21
    mov x2, x22
    mov x3, #0
    bl hdr_add

    // ---- begin -----------------------------------------------------------
    adrp x19, PAGE(s_label_begin)
    add x19, x19, LO12(s_label_begin)
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x21, [x20, #TC_W_BEGIN_YMD]
    ldr x22, [x20, #TC_W_BEGIN_SOD]
    bl arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x21
    mov x2, x22
    mov w3, #' '
    bl fmt_datetime
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl arena_set_end
    ldr x24, [x20, #TC_W_START_SRC]   // source ptr
    bl arena_get
    mov x25, x0
    mov x0, x25
    mov x1, x21                       // begin ymd
    mov x2, x22                       // begin sod
    bl fmt_window_span
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl arena_set_end
    mov x0, x19
    mov x1, x23
    mov x2, x24
    mov x3, x25
    bl hdr_add

    // ---- end -------------------------------------------------------------
    adrp x19, PAGE(s_label_end)
    add x19, x19, LO12(s_label_end)
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x21, [x20, #TC_W_END_YMD]
    ldr x22, [x20, #TC_W_END_SOD]
    bl arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x21
    mov x2, x22
    mov w3, #' '
    bl fmt_datetime
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl arena_set_end
    mov x0, #TC_SET_END
    bl src_str
    mov x24, x0
    mov x0, x19
    mov x1, x23
    mov x2, x24
    mov x3, #0
    bl hdr_add

    // ---- threshold -------------------------------------------------------
    adrp x19, PAGE(s_label_threshold)
    add x19, x19, LO12(s_label_threshold)
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x21, [x20, #TC_W_THRESHOLD]
    bl arena_get
    mov x22, x0
    mov x0, x22
    adrp x1, PAGE(s_ge)
    add x1, x1, LO12(s_ge)
    bl str_cat
    sub x0, x0, #1                    // back to before the NUL
    mov x1, x21
    bl fmt_u64_plain
    adrp x1, PAGE(s_msgs)
    add x1, x1, LO12(s_msgs)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    bl arena_get
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_ge_only)
    add x1, x1, LO12(s_ge_only)
    bl str_cat
    sub x0, x0, #1
    mov x1, x21
    bl fmt_u64_plain
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl arena_set_end
    mov x0, #TC_SET_MIN_COUNT
    bl src_str
    mov x24, x0
    mov x0, x19
    mov x1, x22
    mov x2, x24
    mov x3, x23
    bl hdr_add

    // ---- users -----------------------------------------------------------
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_USERS_WIDTH]
    cbz x20, .Lbhr_state
    adrp x19, PAGE(s_label_users)
    add x19, x19, LO12(s_label_users)
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x21, [x20, #TC_W_USERS_REQ]
    ldr x22, [x20, #TC_W_USERS_FOUND]
    ldr x23, [x20, #TC_W_USERS_WIDTH]
    bl arena_get
    mov x24, x0
    mov x0, x24
    mov x1, x21
    bl fmt_u64_commas
    adrp x1, PAGE(s_asked_for)
    add x1, x1, LO12(s_asked_for)
    bl str_cat
    sub x0, x0, #1
    mov x1, x22
    bl fmt_u64_commas
    adrp x1, PAGE(s_found_over)
    add x1, x1, LO12(s_found_over)
    bl str_cat
    sub x0, x0, #1
    mov x1, x23
    bl fmt_human_duration
    mov x0, x0
    bl arena_set_end
    // source = policy.source + " " + policy value
    bl arena_get
    mov x25, x0
    mov x0, #TC_SET_USERS_POLICY
    bl src_str
    mov x1, x0
    mov x0, x25
    bl str_cat
    sub x0, x0, #1
    mov w1, #' '
    strb w1, [x0], #1
    adrp x1, PAGE(policy_names)
    add x1, x1, LO12(policy_names)
    adrp x2, PAGE(tc_opts)
    add x2, x2, LO12(tc_opts)
    ldr x2, [x2, #TC_O_USERS_POLICY]
    ldr x1, [x1, x2, lsl #3]
    bl str_cat
    mov x0, x0
    bl arena_set_end
    // compact = "M/N users" when found != requested
    ldr x26, [x20, #TC_W_USERS_REQ]
    ldr x27, [x20, #TC_W_USERS_FOUND]
    cmp x26, x27
    b.eq .Lbhr_users_noc
    bl arena_get
    mov x28, x0
    mov x0, x28
    mov x1, x27
    bl fmt_u64_commas
    adrp x1, PAGE(s_slash)
    add x1, x1, LO12(s_slash)
    bl str_cat
    sub x0, x0, #1
    mov x1, x26
    bl fmt_u64_commas
    adrp x1, PAGE(s_users_c)
    add x1, x1, LO12(s_users_c)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbhr_users_add
.Lbhr_users_noc:
    mov x28, #0
.Lbhr_users_add:
    mov x0, x19
    mov x1, x24
    mov x2, x25
    mov x3, x28
    bl hdr_add

    // ---- state -----------------------------------------------------------
.Lbhr_state:
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    ldr x20, [x19, #TC_T_STATES + 0]
    ldr x21, [x19, #TC_T_STATES + 8]
    ldr x22, [x19, #TC_T_STATES + 16]
    orr x23, x20, x21
    orr x23, x23, x22
    cbz x23, .Lbhr_exclude
    adrp x19, PAGE(s_label_state)
    add x19, x19, LO12(s_label_state)
    adrp x20, PAGE(tc_tally)
    add x20, x20, LO12(tc_tally)
    // value = nonzero states "name N" joined " / "  (commas)
    bl arena_get
    mov x21, x0                       // value start
    mov x22, x0                       // cursor
    mov x23, #0                       // first flag
    mov x24, #0                       // state idx (0=live,1=offline,2=unknown)
.Lbhr_state_loop:
    cmp x24, #3
    b.ge .Lbhr_state_val_done
    add x25, x20, #TC_T_STATES
    ldr x26, [x25, x24, lsl #3]
    cbz x26, .Lbhr_state_next
    cbnz x23, .Lbhr_state_sep
    b .Lbhr_state_cell
.Lbhr_state_sep:
    mov x0, x22
    adrp x1, PAGE(s_of_slash)
    add x1, x1, LO12(s_of_slash)
    bl str_cat
    sub x0, x0, #1
    mov x22, x0
.Lbhr_state_cell:
    adrp x1, PAGE(state_names)
    add x1, x1, LO12(state_names)
    ldr x1, [x1, x24, lsl #3]
    mov x0, x22
    bl str_cat
    sub x0, x0, #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x22, x0
    mov x1, x26
    bl fmt_u64_commas
    mov x22, x0
    mov x23, #1
.Lbhr_state_next:
    add x24, x24, #1
    b .Lbhr_state_loop
.Lbhr_state_val_done:
    mov w0, #0
    strb w0, [x22]
    add x0, x22, #1
    bl arena_set_end
    // source (filter id rides in x25; x21 keeps the value start)
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x25, [x20, #TC_W_STATE_FILTER]
    bl arena_get
    mov x22, x0                       // source start
    cbz x25, .Lbhr_state_nofilter
    mov x0, #TC_SET_STATE
    bl src_str
    mov x1, x0
    mov x0, x22
    bl str_cat
    sub x0, x0, #1
    adrp x1, PAGE(s_keeps)
    add x1, x1, LO12(s_keeps)
    bl str_cat
    sub x0, x0, #1
    adrp x1, PAGE(state_names)
    add x1, x1, LO12(state_names)
    sub x2, x25, #1
    ldr x1, [x1, x2, lsl #3]
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbhr_state_src_done
.Lbhr_state_nofilter:
    mov x0, x22
    adrp x1, PAGE(s_not_filtered)
    add x1, x1, LO12(s_not_filtered)
    bl str_cat
    mov x0, x0
    bl arena_set_end
.Lbhr_state_src_done:
    // compact: "NAME only" when filtered, else "name N" joined " "
    bl arena_get
    mov x23, x0                       // compact start
    cbz x25, .Lbhr_state_comp_split
    adrp x1, PAGE(state_names)
    add x1, x1, LO12(state_names)
    sub x2, x25, #1
    ldr x1, [x1, x2, lsl #3]
    mov x0, x23
    bl str_cat
    sub x0, x0, #1
    adrp x1, PAGE(s_only)
    add x1, x1, LO12(s_only)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbhr_state_add
.Lbhr_state_comp_split:
    mov x24, x0                       // cursor
    mov x25, #0                       // first
    mov x26, #0                       // state idx
    adrp x27, PAGE(tc_tally)
    add x27, x27, LO12(tc_tally)
.Lbhr_state_comp_loop:
    cmp x26, #3
    b.ge .Lbhr_state_comp_done
    add x28, x27, #TC_T_STATES
    ldr x28, [x28, x26, lsl #3]
    cbz x28, .Lbhr_state_comp_next
    cbnz x25, .Lbhr_state_comp_sep
    b .Lbhr_state_comp_cell
.Lbhr_state_comp_sep:
    mov w1, #' '
    strb w1, [x24], #1
.Lbhr_state_comp_cell:
    adrp x1, PAGE(state_names)
    add x1, x1, LO12(state_names)
    ldr x1, [x1, x26, lsl #3]
    mov x0, x24
    bl str_cat
    sub x0, x0, #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x24, x0
    mov x1, x28
    bl fmt_u64_commas
    mov x24, x0
    mov x25, #1
.Lbhr_state_comp_next:
    add x26, x26, #1
    b .Lbhr_state_comp_loop
.Lbhr_state_comp_done:
    mov w0, #0
    strb w0, [x24]
    add x0, x24, #1
    bl arena_set_end
.Lbhr_state_add:
    adrp x19, PAGE(s_label_state)
    add x19, x19, LO12(s_label_state)
    mov x0, x19
    mov x1, x21
    mov x2, x22
    mov x3, x23
    bl hdr_add

    // ---- exclude ---------------------------------------------------------
.Lbhr_exclude:
    adrp x19, PAGE(tc_plan_excl_names_n)
    add x19, x19, LO12(tc_plan_excl_names_n)
    ldr x20, [x19]                    // n names
    cbz x20, .Lbhr_columns
    adrp x19, PAGE(s_label_exclude)
    add x19, x19, LO12(s_label_exclude)
    adrp x20, PAGE(tc_plan_excl_names_n)
    add x20, x20, LO12(tc_plan_excl_names_n)
    ldr x20, [x20]                    // N
    adrp x21, PAGE(tc_plan_excl_appeared)
    add x21, x21, LO12(tc_plan_excl_appeared)
    ldr x21, [x21]                    // M appeared
    // value: "N login(s), M in range: preview"
    bl arena_get
    mov x22, x0
    mov x0, x22
    mov x1, x20
    bl fmt_u64_plain
    adrp x1, PAGE(s_login_s)
    add x1, x1, LO12(s_login_s)
    bl str_cat
    sub x0, x0, #1
    mov x1, x21
    bl fmt_u64_plain
    adrp x1, PAGE(s_in_range_colon)
    add x1, x1, LO12(s_in_range_colon)
    bl str_cat
    sub x0, x0, #1                    // overwrite the trailing NUL
    // preview: first 3 names joined ", ", then ", +K more" if > 3
    adrp x23, PAGE(tc_plan_excl_names)
    add x23, x23, LO12(tc_plan_excl_names)
    ldr x23, [x23]
    mov x24, #0                        // i
    mov x25, #0                        // first flag
.Lbhr_excl_preview:
    cmp x24, x20
    b.ge .Lbhr_excl_preview_done
    cmp x24, #3
    b.ge .Lbhr_excl_preview_done
    cbnz x25, .Lbhr_excl_sep
    b .Lbhr_excl_name
.Lbhr_excl_sep:
    sub x0, x0, #1                    // overwrite the trailing NUL
    adrp x1, PAGE(s_comma)
    add x1, x1, LO12(s_comma)
    mov x2, #2
    bl str_cat_n
.Lbhr_excl_name:
    mov x2, #NAME_SZ
    mul x2, x24, x2
    add x1, x23, x2
    bl str_cat
    mov x25, #1
    add x24, x24, #1
    b .Lbhr_excl_preview
.Lbhr_excl_preview_done:
    cmp x20, #3
    b.le .Lbhr_excl_val_done
    sub x0, x0, #1                    // overwrite the trailing NUL (str_cat
                                      // returns the cursor past it)
    adrp x1, PAGE(s_comma_more)
    add x1, x1, LO12(s_comma_more)
    bl str_cat
    sub x0, x0, #1
    sub x1, x20, #3
    bl fmt_u64_plain
    adrp x1, PAGE(s_more)
    add x1, x1, LO12(s_more)
    bl str_cat
.Lbhr_excl_val_done:
    mov x0, x0
    bl arena_set_end
    // source = joined sources
    adrp x24, PAGE(tc_plan_src_join)
    add x24, x24, LO12(tc_plan_src_join)
    ldr x24, [x24]
    // compact = "-M excl" when appeared
    cbz x21, .Lbhr_excl_noc
    bl arena_get
    mov x25, x0
    mov w1, #'-'
    strb w1, [x25]
    mov x0, x25
    add x0, x0, #1
    mov x1, x21
    bl fmt_u64_plain
    adrp x1, PAGE(s_excl)
    add x1, x1, LO12(s_excl)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbhr_excl_add
.Lbhr_excl_noc:
    mov x25, #0
.Lbhr_excl_add:
    mov x0, x19
    mov x1, x22
    mov x2, x24
    mov x3, x25
    bl hdr_add

    // ---- columns ---------------------------------------------------------
.Lbhr_columns:
    adrp x19, PAGE(tc_plan_col_count)
    add x19, x19, LO12(tc_plan_col_count)
    ldr x20, [x19]
    cbz x20, .Lbhr_sort
    adrp x19, PAGE(s_label_columns)
    add x19, x19, LO12(s_label_columns)
    bl arena_get
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_m_count)
    add x1, x1, LO12(s_m_count)
    bl str_cat
    sub x0, x0, #1
    adrp x22, PAGE(tc_plan_columns)
    add x22, x22, LO12(tc_plan_columns)
    mov x23, #0
.Lbhr_col_loop:
    cmp x23, x20
    b.ge .Lbhr_col_done
    adrp x1, PAGE(s_comma)
    add x1, x1, LO12(s_comma)
    bl str_cat
    sub x0, x0, #1
    ldr x24, [x22, x23, lsl #3]
    adrp x1, PAGE(metric_names)
    add x1, x1, LO12(metric_names)
    ldr x1, [x1, x24, lsl #3]
    bl str_cat
    sub x0, x0, #1
    add x23, x23, #1
    b .Lbhr_col_loop
.Lbhr_col_done:
    mov w1, #0
    strb w1, [x0]
    add x0, x0, #1
    bl arena_set_end
    // source ptr: tc_cli.S composes it into TC_O_COLUMNS_SRC_BUF but its
    // TC_O_COLUMNS_SRC_PTR store clobbers x1 (tc_opts_off); point at the
    // composed buffer directly.
    adrp x24, PAGE(tc_opts)
    add x24, x24, LO12(tc_opts)
    movz x25, #TC_O_COLUMNS_SRC_BUF
    add x25, x24, x25
    mov x0, x19
    mov x1, x21
    mov x2, x25
    mov x3, #0
    bl hdr_add

    // ---- sort ------------------------------------------------------------
.Lbhr_sort:
    adrp x19, PAGE(tc_plan_sort)
    add x19, x19, LO12(tc_plan_sort)
    ldr x20, [x19]
    cmp x20, #TC_M_COUNT
    b.eq .Lbhr_share_floor
    adrp x19, PAGE(s_label_sort)
    add x19, x19, LO12(s_label_sort)
    adrp x21, PAGE(metric_names)
    add x21, x21, LO12(metric_names)
    ldr x21, [x21, x20, lsl #3]
    mov x0, #TC_SET_SORT
    bl src_str
    mov x22, x0
    // compact "by <name>"
    bl arena_get
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_by)
    add x1, x1, LO12(s_by)
    bl str_cat
    sub x0, x0, #1
    adrp x1, PAGE(metric_names)
    add x1, x1, LO12(metric_names)
    ldr x1, [x1, x20, lsl #3]
    bl str_cat
    mov x0, x0
    bl arena_set_end
    mov x0, x19
    mov x1, x21
    mov x2, x22
    mov x3, x23
    bl hdr_add

    // ---- share floor -----------------------------------------------------
.Lbhr_share_floor:
    adrp x19, PAGE(tc_plan_share_floor)
    add x19, x19, LO12(tc_plan_share_floor)
    ldr x20, [x19]                    // the floor that acted
    // asked = source != TC_SRC_DEFAULT_BUILTIN
    adrp x21, PAGE(tc_opts)
    add x21, x21, LO12(tc_opts)
    ldr x22, [x21, #TC_O_SRC + TC_SET_SHARE_FLOOR*8]
    mov x23, #0                        // asked
    cmp x22, #TC_SRC_DEFAULT_BUILTIN
    b.eq .Lbhr_sf_asked_done
    mov x23, #1
.Lbhr_sf_asked_done:
    cbz x20, .Lbhr_sf_not_acted
    cbnz x23, .Lbhr_sf_acted
    // (acted implies asked)
.Lbhr_sf_acted:
    adrp x19, PAGE(s_label_share_floor)
    add x19, x19, LO12(s_label_share_floor)
    bl arena_get
    mov x24, x0
    mov x0, x24
    adrp x1, PAGE(s_ge)
    add x1, x1, LO12(s_ge)
    bl str_cat
    sub x0, x0, #1
    mov x1, x20
    bl fmt_u64_commas
    adrp x1, PAGE(s_floor_msgs)
    add x1, x1, LO12(s_floor_msgs)
    bl str_cat
    adrp x25, PAGE(tc_plan_below_floor)
    add x25, x25, LO12(tc_plan_below_floor)
    ldr x25, [x25]
    sub x0, x0, #1
    mov x1, x25
    bl fmt_u64_commas
    adrp x1, PAGE(s_floor_dropped)
    add x1, x1, LO12(s_floor_dropped)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    // compact "floor >=N, -M"
    bl arena_get
    mov x26, x0
    mov x0, x26
    adrp x1, PAGE(s_floor_compact)
    add x1, x1, LO12(s_floor_compact)
    bl str_cat
    sub x0, x0, #1
    mov x1, x20
    bl fmt_u64_commas
    adrp x1, PAGE(s_floor_minus)
    add x1, x1, LO12(s_floor_minus)
    bl str_cat
    sub x0, x0, #1
    mov x1, x25
    bl fmt_u64_commas
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl arena_set_end
    b .Lbhr_sf_add
.Lbhr_sf_not_acted:
    cbz x23, .Lbhr_sf_skip            // not acted and not asked -> no row
    adrp x27, PAGE(tc_plan_shares_shown)
    add x27, x27, LO12(tc_plan_shares_shown)
    ldr x27, [x27]
    cbz x27, .Lbhr_sf_noshare
    // shares shown but floor 0: "disabled ..."
    adrp x19, PAGE(s_label_share_floor)
    add x19, x19, LO12(s_label_share_floor)
    bl arena_get
    mov x24, x0
    mov x0, x24
    adrp x1, PAGE(s_floor_disabled)
    add x1, x1, LO12(s_floor_disabled)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    mov x26, x0                       // compact ptr placeholder
    bl arena_get
    mov x26, x0
    mov x0, x26
    adrp x1, PAGE(s_floor_off)
    add x1, x1, LO12(s_floor_off)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbhr_sf_add
.Lbhr_sf_noshare:
    // no share shown/sorted: "not applied -- ..."
    adrp x19, PAGE(s_label_share_floor)
    add x19, x19, LO12(s_label_share_floor)
    bl arena_get
    mov x24, x0
    mov x0, x24
    adrp x1, PAGE(s_floor_not)
    add x1, x1, LO12(s_floor_not)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    bl arena_get
    mov x26, x0
    mov x0, x26
    adrp x1, PAGE(s_floor_unused)
    add x1, x1, LO12(s_floor_unused)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbhr_sf_add
.Lbhr_sf_skip:
    b .Lbhr_config
.Lbhr_sf_add:
    mov x0, #TC_SET_SHARE_FLOOR
    bl src_str
    mov x25, x0
    mov x0, x19
    mov x1, x24
    mov x2, x25
    mov x3, x26
    bl hdr_add

    // ---- config ----------------------------------------------------------
.Lbhr_config:
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_CONFIG_LOADED]
    cbz x20, .Lbhr_cache
    adrp x19, PAGE(s_label_config)
    add x19, x19, LO12(s_label_config)
    add x0, x19, #0
    adrp x20, PAGE(tc_opts)
    add x20, x20, LO12(tc_opts)
    add x20, x20, #TC_O_CONFIG_PATH
    mov x0, x20
    bl tc_shorten_path
    mov x20, x0
    bl arena_get
    mov x21, x0
    mov x0, x21
    mov x1, x20
    bl str_cat
    mov x0, x0
    bl arena_set_end
    mov x0, x19
    mov x1, x21
    adrp x2, PAGE(s_loaded)
    add x2, x2, LO12(s_loaded)
    mov x3, #0
    bl hdr_add

    // ---- cache -----------------------------------------------------------
.Lbhr_cache:
    adrp x19, PAGE(tc_plan_cache_used)
    add x19, x19, LO12(tc_plan_cache_used)
    ldr x20, [x19]                    // used
    ldr x21, [x19, #8]                // reused
    ldr x22, [x19, #16]               // parsed
    ldr x23, [x19, #24]               // problem
    ldr x24, [x19, #32]               // rebuilt
    ldr x25, [x19, #40]               // path
    cbnz x20, .Lbhr_cache_used
    cbz x23, .Lbhr_unreadable         // not used, no problem -> no row
    // unavailable -- <problem>
    adrp x19, PAGE(s_label_cache)
    add x19, x19, LO12(s_label_cache)
    bl arena_get
    mov x26, x0
    mov x0, x26
    adrp x1, PAGE(s_unavailable)
    add x1, x1, LO12(s_unavailable)
    bl str_cat
    sub x0, x0, #1
    mov x1, x23
    bl str_cat
    mov x0, x0
    bl arena_set_end
    mov x0, x19
    mov x1, x26
    adrp x2, PAGE(s_every_file)
    add x2, x2, LO12(s_every_file)
    adrp x3, PAGE(s_no_cache_c)
    add x3, x3, LO12(s_no_cache_c)
    bl hdr_add
    b .Lbhr_unreadable
.Lbhr_cache_used:
    adrp x19, PAGE(s_label_cache)
    add x19, x19, LO12(s_label_cache)
    bl arena_get
    mov x26, x0
    mov x0, x26
    mov x1, x21
    bl fmt_u64_commas
    adrp x1, PAGE(s_day_s_reused)
    add x1, x1, LO12(s_day_s_reused)
    bl str_cat
    sub x0, x0, #1
    mov x1, x22
    bl fmt_u64_commas
    adrp x1, PAGE(s_parsed)
    add x1, x1, LO12(s_parsed)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    // source
    cbnz x24, .Lbhr_cache_rebuilt
    cbnz x25, .Lbhr_cache_path
    adrp x27, PAGE(s_rollup_db)
    add x27, x27, LO12(s_rollup_db)
    b .Lbhr_cache_src_done
.Lbhr_cache_rebuilt:
    bl arena_get
    mov x27, x0
    mov x0, x27
    adrp x1, PAGE(s_rebuilt)
    add x1, x1, LO12(s_rebuilt)
    bl str_cat
    sub x0, x0, #1
    mov x1, x24
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbhr_cache_src_done
.Lbhr_cache_path:
    mov x0, x25
    bl tc_shorten_path
    mov x27, x0
    bl arena_get
    mov x28, x0
    mov x0, x28
    mov x1, x27
    bl str_cat
    mov x0, x0
    bl arena_set_end
    mov x27, x28
.Lbhr_cache_src_done:
    mov x0, x19
    mov x1, x26
    mov x2, x27
    mov x3, #0
    bl hdr_add

    // ---- unreadable ------------------------------------------------------
.Lbhr_unreadable:
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    ldr x20, [x19, #TC_T_UNR_COUNT]
    cbz x20, .Lbhr_done
    adrp x19, PAGE(s_label_unreadable)
    add x19, x19, LO12(s_label_unreadable)
    adrp x20, PAGE(tc_tally)
    add x20, x20, LO12(tc_tally)
    ldr x20, [x20, #TC_T_UNR_COUNT]
    bl arena_get
    mov x21, x0
    mov x0, x21
    mov x1, x20
    bl fmt_u64_plain
    adrp x1, PAGE(s_file_s_skipped)
    add x1, x1, LO12(s_file_s_skipped)
    bl str_cat
    sub x0, x0, #1                    // overwrite the trailing NUL
    // first 2 names joined ", ", ", +K more" if > 2
    adrp x22, PAGE(tc_tally)
    add x22, x22, LO12(tc_tally)
    add x22, x22, #TC_T_UNR_ENTRIES
    mov x23, #0                        // i
    mov x24, #0                        // first
.Lbhr_unr_preview:
    cmp x23, x20
    b.ge .Lbhr_unr_preview_done
    cmp x23, #2
    b.ge .Lbhr_unr_preview_done
    cbnz x24, .Lbhr_unr_sep
    b .Lbhr_unr_name
.Lbhr_unr_sep:
    sub x0, x0, #1                    // overwrite the trailing NUL
    adrp x1, PAGE(s_comma)
    add x1, x1, LO12(s_comma)
    mov x2, #2
    bl str_cat_n
.Lbhr_unr_name:
    mov x2, #TC_T_UNR_ENTRY_SZ
    mul x2, x23, x2
    add x1, x22, x2
    bl str_cat
    mov x24, #1
    add x23, x23, #1
    b .Lbhr_unr_preview
.Lbhr_unr_preview_done:
    cmp x20, #2
    b.le .Lbhr_unr_reason
    sub x0, x0, #1                    // overwrite the trailing NUL (str_cat
                                      // returns the cursor past it)
    adrp x1, PAGE(s_comma_more)
    add x1, x1, LO12(s_comma_more)
    bl str_cat
    sub x0, x0, #1
    sub x1, x20, #2
    bl fmt_u64_plain
    adrp x1, PAGE(s_more)
    add x1, x1, LO12(s_more)
    bl str_cat
.Lbhr_unr_reason:
    sub x0, x0, #1                    // overwrite the trailing NUL
    mov w1, #' '
    strb w1, [x0], #1
    mov w1, #'('
    strb w1, [x0], #1
    adrp x22, PAGE(tc_tally)
    add x22, x22, LO12(tc_tally)
    add x22, x22, #TC_T_UNR_ENTRIES
    add x1, x22, #TC_T_UNR_NAME_SZ     // first reason
    bl str_cat
    sub x0, x0, #1
    mov w1, #')'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    add x0, x0, #1
    bl arena_set_end
    // compact "N unread"
    bl arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x20
    bl fmt_u64_plain
    adrp x1, PAGE(s_unread)
    add x1, x1, LO12(s_unread)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    mov x0, x19
    mov x1, x21
    adrp x2, PAGE(s_not_counted)
    add x2, x2, LO12(s_not_counted)
    mov x3, x23
    bl hdr_add
.Lbhr_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// fmt_window_span(dst) — the compact span ("MM-DD HH:MM..now", same-date, or
// "YYYY-MM-DD..YYYY-MM-DD"); needs the window already loaded by the caller in
// x1=begin ymd, x2=begin sod (uses tc_window for the end).
// ============================================================================
    .p2align 2
fmt_window_span:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                       // dst
    mov x20, x1                       // begin ymd
    mov x21, x2                       // begin sod
    // end defaulted?
    adrp x22, PAGE(tc_opts)
    add x22, x22, LO12(tc_opts)
    ldr x22, [x22, #TC_O_SRC + TC_SET_END*8]
    cmp x22, #TC_SRC_DEFAULT_NOW
    b.eq .Lfws_now
    adrp x22, PAGE(tc_window)
    add x22, x22, LO12(tc_window)
    ldr x22, [x22, #TC_W_END_YMD]
    cmp x20, x22
    b.eq .Lfws_same
    // different dates: "YYYY-MM-DD..YYYY-MM-DD"
    mov x0, x19
    mov x1, x20
    bl fmt_ymd
    adrp x1, PAGE(s_dotdot)
    add x1, x1, LO12(s_dotdot)
    bl str_cat
    sub x0, x0, #1
    adrp x22, PAGE(tc_window)
    add x22, x22, LO12(tc_window)
    ldr x1, [x22, #TC_W_END_YMD]
    bl fmt_ymd
    b .Lfws_done
.Lfws_same:
    // "MM-DD HH:MM..HH:MM"
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl fmt_mmdd_hhmm
    adrp x1, PAGE(s_dotdot)
    add x1, x1, LO12(s_dotdot)
    bl str_cat
    sub x0, x0, #1
    adrp x22, PAGE(tc_window)
    add x22, x22, LO12(tc_window)
    ldr x1, [x22, #TC_W_END_SOD]
    bl fmt_hhmm
    b .Lfws_done
.Lfws_now:
    // "MM-DD HH:MM..now"
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl fmt_mmdd_hhmm
    adrp x1, PAGE(s_now)
    add x1, x1, LO12(s_now)
    bl str_cat
    sub x0, x0, #1
.Lfws_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// choose_limit — Python choose_limit: --top, then --json unlimited, then the
// terminal height.
// ============================================================================
    .p2align 2
choose_limit:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    // top given?
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_SRC + TC_SET_TOP*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Lcl_json
    ldr x21, [x19, #TC_O_TOP]
    adrp x22, PAGE(tc_plan_limit)
    add x22, x22, LO12(tc_plan_limit)
    str x21, [x22]
    mov x0, x20                       // x20 is already a TC_SRC_* id
    bl tc_source_str
    adrp x22, PAGE(tc_plan_limit_src)
    add x22, x22, LO12(tc_plan_limit_src)
    str x0, [x22]
    b .Lcl_done
.Lcl_json:
    ldr x21, [x19, #TC_O_FLAGS]
    tst x21, #TC_F_JSON
    b.eq .Lcl_term
    adrp x22, PAGE(tc_plan_limit)
    add x22, x22, LO12(tc_plan_limit)
    str xzr, [x22]
    adrp x22, PAGE(tc_plan_limit_src)
    add x22, x22, LO12(tc_plan_limit_src)
    adrp x0, PAGE(s_unlimited_json)
    add x0, x0, LO12(s_unlimited_json)
    str x0, [x22]
    b .Lcl_done
.Lcl_term:
    // reserved
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_HEADER_MODE]
    adrp x21, PAGE(tc_plan_hdr_count)
    add x21, x21, LO12(tc_plan_hdr_count)
    ldr x22, [x21]
    cmp x20, #TC_HDR_FULL
    b.ne .Lcl_res_compact
    add x22, x22, #2
    b .Lcl_res_done
.Lcl_res_compact:
    cmp x20, #TC_HDR_COMPACT
    b.ne .Lcl_res_none
    mov x22, #2
    b .Lcl_res_done
.Lcl_res_none:
    mov x22, #0
.Lcl_res_done:
    // watch present -> +2
    ldr x23, [x19, #TC_O_FLAGS]
    tst x23, #TC_F_WATCH_PRESENT
    b.eq .Lcl_res_watch_done
    add x22, x22, #2
.Lcl_res_watch_done:
    // isatty(1)?
    mov x0, #1
    bl isatty
    cbz w0, .Lcl_term_unlimited        // int result: test w0, not x0
    // shutil.get_terminal_size(fallback=(80, 24)).lines: $LINES first,
    // then the terminal, then 24 (tc_util.S)
    bl tc_term_lines
    mov x23, x0
.Lcl_term_calc:
    // limit = max(rows - (reserved + 8), 5)   (Python adaptive_row_limit)
    sub x23, x23, x22                  // was `add`: a 30-line terminal got 32 rows
    sub x23, x23, #8
    cmp x23, #5
    b.ge .Lcl_term_store
    mov x23, #5
.Lcl_term_store:
    adrp x22, PAGE(tc_plan_limit)
    add x22, x22, LO12(tc_plan_limit)
    str x23, [x22]
    adrp x22, PAGE(tc_plan_limit_src)
    add x22, x22, LO12(tc_plan_limit_src)
    adrp x0, PAGE(s_terminal_height)
    add x0, x0, LO12(s_terminal_height)
    str x0, [x22]
    b .Lcl_done
.Lcl_term_unlimited:
    adrp x22, PAGE(tc_plan_limit)
    add x22, x22, LO12(tc_plan_limit)
    str xzr, [x22]
    adrp x22, PAGE(tc_plan_limit_src)
    add x22, x22, LO12(tc_plan_limit_src)
    adrp x0, PAGE(s_terminal_height)
    add x0, x0, LO12(s_terminal_height)
    str x0, [x22]
.Lcl_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// plan_split_display — displayed/hidden split, message sums, and the top row.
// ============================================================================
    .p2align 2
plan_split_display:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_plan_reported_n)
    add x19, x19, LO12(tc_plan_reported_n)
    ldr x20, [x19]                     // reported_n
    adrp x21, PAGE(tc_plan_limit)
    add x21, x21, LO12(tc_plan_limit)
    ldr x22, [x21]                     // limit
    cbz x22, .Lpsd_all
    cbz x20, .Lpsd_all
    cmp x20, x22
    b.le .Lpsd_min
    mov x23, x22
    b .Lpsd_store
.Lpsd_min:
    mov x23, x20
    b .Lpsd_store
.Lpsd_all:
    mov x23, x20
.Lpsd_store:
    adrp x24, PAGE(tc_plan_displayed_n)
    add x24, x24, LO12(tc_plan_displayed_n)
    str x23, [x24]
    adrp x24, PAGE(tc_plan_hidden_n)
    add x24, x24, LO12(tc_plan_hidden_n)
    sub x25, x20, x23
    str x25, [x24]
    // message sums
    adrp x26, PAGE(tc_plan_reported)
    add x26, x26, LO12(tc_plan_reported)
    ldr x26, [x26]
    mov x27, #0
    mov x28, #0
.Lpsd_shown_loop:
    cmp x28, x23
    b.ge .Lpsd_shown_done
    mov x0, #ROW_SZ
    mul x0, x28, x0
    add x0, x26, x0
    ldr x1, [x0, #ROW_COUNT]
    add x27, x27, x1
    add x28, x28, #1
    b .Lpsd_shown_loop
.Lpsd_shown_done:
    adrp x28, PAGE(tc_plan_msgs_shown)
    add x28, x28, LO12(tc_plan_msgs_shown)
    str x27, [x28]
    mov x27, #0
    mov x28, x23
.Lpsd_hidden_loop:
    cmp x28, x20
    b.ge .Lpsd_hidden_done
    mov x0, #ROW_SZ
    mul x0, x28, x0
    add x0, x26, x0
    ldr x1, [x0, #ROW_COUNT]
    add x27, x27, x1
    add x28, x28, #1
    b .Lpsd_hidden_loop
.Lpsd_hidden_done:
    adrp x28, PAGE(tc_plan_msgs_hidden)
    add x28, x28, LO12(tc_plan_msgs_hidden)
    str x27, [x28]
    // top row
    cbz x22, .Lpsd_done
    cbz x20, .Lpsd_done
    bl build_top_row
.Lpsd_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// build_top_row — "N row(s)[, M hidden]" with the limit source; compact
// "D/R rows" when hidden.
// ============================================================================
    .p2align 2
build_top_row:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x19, PAGE(tc_plan_limit)
    add x19, x19, LO12(tc_plan_limit)
    ldr x19, [x19]                     // limit
    adrp x20, PAGE(tc_plan_hidden_n)
    add x20, x20, LO12(tc_plan_hidden_n)
    ldr x20, [x20]                     // hidden
    adrp x21, PAGE(tc_plan_displayed_n)
    add x21, x21, LO12(tc_plan_displayed_n)
    ldr x21, [x21]                     // displayed
    adrp x22, PAGE(tc_plan_reported_n)
    add x22, x22, LO12(tc_plan_reported_n)
    ldr x22, [x22]                     // reported
    bl arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x19
    bl fmt_u64_commas
    adrp x1, PAGE(s_row_s)
    add x1, x1, LO12(s_row_s)
    bl str_cat
    cbz x20, .Lbtr_val_done
    sub x0, x0, #1                    // overwrite the trailing NUL
    adrp x1, PAGE(s_comma)
    add x1, x1, LO12(s_comma)
    bl str_cat
    sub x0, x0, #1
    mov x1, x20
    bl fmt_u64_commas
    adrp x1, PAGE(s_hidden)
    add x1, x1, LO12(s_hidden)
    bl str_cat
.Lbtr_val_done:
    mov x0, x0
    bl arena_set_end
    // source
    adrp x24, PAGE(tc_plan_limit_src)
    add x24, x24, LO12(tc_plan_limit_src)
    ldr x24, [x24]
    // compact "D/R rows" when hidden
    cbz x20, .Lbtr_noc
    bl arena_get
    mov x25, x0
    mov x0, x25
    mov x1, x21
    bl fmt_u64_commas
    adrp x1, PAGE(s_slash)
    add x1, x1, LO12(s_slash)
    bl str_cat
    sub x0, x0, #1
    mov x1, x22
    bl fmt_u64_commas
    adrp x1, PAGE(s_rows)
    add x1, x1, LO12(s_rows)
    bl str_cat
    mov x0, x0
    bl arena_set_end
    b .Lbtr_add
.Lbtr_noc:
    mov x25, #0
.Lbtr_add:
    adrp x0, PAGE(s_label_top)
    add x0, x0, LO12(s_label_top)
    mov x1, x23
    mov x2, x24
    mov x3, x25
    bl hdr_add
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_render_text — the one-shot text report (Python render_text).
// ============================================================================
    .p2align 2
    .global tc_render_text
    FUNC_TYPE(tc_render_text)
tc_render_text:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_HEADER_MODE]
    // Wave E fix: --header none used to jump straight to the table, skipping
    // the empty-report check, so an empty range with --header none rendered an
    // empty table instead of Python's "No users met the threshold (...)".
    // Fall through to the shared empty check (which renders nothing more for
    // the non-empty case).
    cmp x20, #TC_HDR_NONE
    b.eq .Lrt_after
    cmp x20, #TC_HDR_COMPACT
    b.eq .Lrt_compact
    bl render_full_header
    b .Lrt_after
.Lrt_compact:
    bl render_compact_header
.Lrt_after:
    adrp x19, PAGE(tc_plan_reported_n)
    add x19, x19, LO12(tc_plan_reported_n)
    ldr x20, [x19]
    cbnz x20, .Lrt_table
    // empty report
    bl line_zero
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    ldr x20, [x19, #TC_T_MESSAGES]
    adrp x21, PAGE(tc_render_line)
    add x21, x21, LO12(tc_render_line)
    mov x0, x21
    adrp x1, PAGE(s_no_users)
    add x1, x1, LO12(s_no_users)
    bl str_cat
    sub x0, x0, #1
    mov x1, x20
    bl fmt_u64_plain
    adrp x1, PAGE(s_msg_range)
    add x1, x1, LO12(s_msg_range)
    bl str_cat
    sub x0, x0, #1
    adrp x1, PAGE(s_period)
    add x1, x1, LO12(s_period)
    bl str_cat
    mov x0, x21
    bl line_puts
    adrp x19, PAGE(tc_plan_excl_appeared)
    add x19, x19, LO12(tc_plan_excl_appeared)
    ldr x20, [x19]
    cbz x20, .Lrt_done
    bl emit_excluded_line
    b .Lrt_done
.Lrt_table:
    bl render_table
.Lrt_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// render_full_header — the provenance block, aligned, then the files line.
// ============================================================================
    .p2align 2
render_full_header:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    // pass 1: widths
    adrp x19, PAGE(tc_plan_hdr_count)
    add x19, x19, LO12(tc_plan_hdr_count)
    ldr x20, [x19]                     // row count
    mov x21, #0                        // w0 (max label+1)
    mov x22, #0                        // w1 (max value)
    mov x23, #0
.Lrfh_w_loop:
    cmp x23, x20
    b.ge .Lrfh_w_done
    adrp x24, PAGE(tc_plan_rows)
    add x24, x24, LO12(tc_plan_rows)
    mov x25, #HDR_DESC_SZ
    mul x25, x23, x25
    add x24, x24, x25
    ldr x25, [x24]                     // label
    mov x0, x25
    bl tc_strlen
    add x0, x0, #1                     // + colon
    cmp x0, x21
    b.le .Lrfh_w_val
    mov x21, x0
.Lrfh_w_val:
    ldr x25, [x24, #8]                 // value
    mov x0, x25
    bl tc_strlen
    cmp x0, x22
    b.le .Lrfh_w_next
    mov x22, x0
.Lrfh_w_next:
    add x23, x23, #1
    b .Lrfh_w_loop
.Lrfh_w_done:
    cmp x22, #48
    b.le .Lrfh_w1_ok
    mov x22, #48
.Lrfh_w1_ok:
    // pass 2: emit
    mov x23, #0
.Lrfh_line_loop:
    cmp x23, x20
    b.ge .Lrfh_lines_done
    adrp x24, PAGE(tc_plan_rows)
    add x24, x24, LO12(tc_plan_rows)
    mov x25, #HDR_DESC_SZ
    mul x25, x23, x25
    add x24, x24, x25
    ldr x0, [x24]                      // label
    ldr x1, [x24, #8]                  // value
    ldr x2, [x24, #16]                 // source
    mov x3, x21                        // w0
    mov x4, x22                        // w1
    bl emit_header_line
    add x23, x23, #1
    b .Lrfh_line_loop
.Lrfh_ret:
.Lrfh_lines_done:
    // files line
    adrp x0, PAGE(s_label_files)
    add x0, x0, LO12(s_label_files)
    adrp x1, PAGE(tc_tally)
    add x1, x1, LO12(tc_tally)
    ldr x1, [x1, #TC_T_FILES]
    mov x2, x21
    mov x3, x22
    bl emit_files_line
    // blank line
    bl line_blank
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_header_line(label, value, source, w0, w1) — "label:  value  [source]"
    .p2align 2
emit_header_line:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // label
    mov x20, x1                        // value
    mov x21, x2                        // source
    mov x22, x3                        // w0
    mov x23, x4                        // w1
    bl line_zero
    adrp x24, PAGE(tc_render_line)
    add x24, x24, LO12(tc_render_line)
    // label + ':'
    mov x0, x24
    mov x1, x19
    bl str_cat
    sub x0, x0, #1
    mov w1, #':'
    strb w1, [x0], #1
    // pad to w0
    mov x0, x24
    bl tc_strlen
    mov x25, x0
.Lehl_pad0:
    cmp x25, x22
    b.ge .Lehl_gap
    mov w1, #' '
    strb w1, [x24, x25]
    add x25, x25, #1
    b .Lehl_pad0
.Lehl_gap:
    mov w1, #' '
    strb w1, [x24, x25]
    add x25, x25, #1
    mov w1, #' '
    strb w1, [x24, x25]
    add x25, x25, #1
    // value
    mov x0, x25
    add x0, x24, x0
    mov x1, x20
    bl str_cat
    sub x0, x0, #1
    mov x25, x0
    sub x25, x25, x24                  // cursor offset
    // pad value to w1: the total line must reach w0 + gap(2) + w1
.Lehl_pad1:
    add x27, x22, #2
    add x27, x27, x23                  // target total length
    mov x0, x24
    bl tc_strlen
    mov x26, x0
    cmp x26, x27
    b.ge .Lehl_src
    mov w1, #' '
    strb w1, [x24, x26]
    b .Lehl_pad1
.Lehl_src:
    mov x0, x24
    bl tc_strlen
    mov x25, x0                        // cursor = total length
    mov w1, #' '
    strb w1, [x24, x25]
    add x25, x25, #1
    mov w1, #' '
    strb w1, [x24, x25]
    add x25, x25, #1
    mov w1, #'['
    strb w1, [x24, x25]
    add x25, x25, #1
    add x0, x24, x25
    mov x1, x21
    bl str_cat
    sub x0, x0, #1
    mov w1, #']'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    mov x0, x24
    bl line_puts
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_files_line(label, count, w0, w1) — "files:  N log file(s) in range"
// (the value is unpadded: align_row rstrips the trailing padding)
    .p2align 2
emit_files_line:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // "files"
    mov x20, x1                        // count
    mov x21, x2                        // w0
    bl line_zero
    adrp x22, PAGE(tc_render_line)
    add x22, x22, LO12(tc_render_line)
    mov x0, x22
    mov x1, x19
    bl str_cat
    sub x0, x0, #1
    mov w1, #':'
    strb w1, [x0], #1
    mov x0, x22
    bl tc_strlen
    mov x23, x0
.Leftl_pad0:
    cmp x23, x21
    b.ge .Leftl_gap
    mov w1, #' '
    strb w1, [x22, x23]
    add x23, x23, #1
    b .Leftl_pad0
.Leftl_gap:
    mov w1, #' '
    strb w1, [x22, x23]
    add x23, x23, #1
    mov w1, #' '
    strb w1, [x22, x23]
    add x23, x23, #1
    add x0, x22, x23
    mov x1, x20
    bl fmt_u64_plain
    adrp x1, PAGE(s_files_val)
    add x1, x1, LO12(s_files_val)
    bl str_cat
    mov x0, x22
    bl line_puts
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// render_compact_header — " · "-joined compact cells, then a blank line.
// ============================================================================
    .p2align 2
render_compact_header:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    bl compact_zero
    adrp x19, PAGE(tc_plan_hdr_count)
    add x19, x19, LO12(tc_plan_hdr_count)
    ldr x20, [x19]
    adrp x21, PAGE(tc_render_compact)
    add x21, x21, LO12(tc_render_compact)
    mov x22, x21                       // cursor
    mov x23, #0                        // first flag
    mov x24, #0                        // i
.Lrch_loop:
    cmp x24, x20
    b.ge .Lrch_done
    adrp x25, PAGE(tc_plan_rows)
    add x25, x25, LO12(tc_plan_rows)
    mov x26, #HDR_DESC_SZ
    mul x26, x24, x26
    add x25, x25, x26
    ldr x26, [x25, #24]                // compact
    cbz x26, .Lrch_next
    cbnz x23, .Lrch_sep
    b .Lrch_cell
.Lrch_sep:
    sub x0, x22, #1                   // overwrite the trailing NUL
    adrp x1, PAGE(s_middot)
    add x1, x1, LO12(s_middot)
    mov x2, #s_middot_len
    bl str_cat_n
    mov x22, x0
.Lrch_cell:
    mov x0, x22
    mov x1, x26
    bl str_cat
    mov x22, x0
    mov x23, #1
.Lrch_next:
    add x24, x24, #1
    b .Lrch_loop
.Lrch_done:
    mov x0, x21
    bl line_puts
    bl line_blank
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// others_widths — widen tc_render_widths for the "+ N others" row: its login,
// its count cell and its pooled-state metric cells.  x26 = hidden_n; x22 =
// tc_render_widths base.  Preserves x19-x28 (callee-saved, no calls that
// clobber them except our own which all preserve them).
// ============================================================================
    .p2align 2
others_widths:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x22                       // widths base
    mov x20, x26                       // hidden_n
    // zero the shared cell buffer
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    // login: "+ N others"
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov w1, #'+'
    strb w1, [x0], #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x1, x20
    bl fmt_u64_commas
    adrp x1, PAGE(s_others)
    add x1, x1, LO12(s_others)
    bl str_cat
    adrp x21, PAGE(tc_render_cell)
    add x21, x21, LO12(tc_render_cell)
    mov x0, x21
    bl tc_strlen
    ldr x28, [x19]
    cmp x0, x28
    b.le .Low_login_done
    str x0, [x19]
.Low_login_done:
    // pooled states over hidden rows
    adrp x21, PAGE(tc_plan_reported)
    add x21, x21, LO12(tc_plan_reported)
    ldr x21, [x21]
    adrp x22, PAGE(tc_plan_displayed_n)
    add x22, x22, LO12(tc_plan_displayed_n)
    ldr x22, [x22]
    mov x26, #0                        // pooled live
    mov x27, #0                        // pooled offline
    mov x28, #0                        // pooled unknown
    mov x9, #0                         // i
.Low_pool:
    cmp x9, x20
    b.ge .Low_pool_done
    add x10, x22, x9
    mov x0, #ROW_SZ
    mul x0, x10, x0
    add x10, x21, x0
    ldr x11, [x10, #ROW_LIVE]
    add x26, x26, x11
    ldr x11, [x10, #ROW_OFFLINE]
    add x27, x27, x11
    ldr x11, [x10, #ROW_UNKNOWN]
    add x28, x28, x11
    add x9, x9, #1
    b .Low_pool
.Low_pool_done:
    // count cell: hidden messages
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    adrp x1, PAGE(tc_plan_msgs_hidden)
    add x1, x1, LO12(tc_plan_msgs_hidden)
    ldr x1, [x1]
    bl fmt_u64_commas
    adrp x21, PAGE(tc_render_cell)
    add x21, x21, LO12(tc_render_cell)
    mov x0, x21
    bl tc_strlen
    ldr x28, [x19, #8]
    cmp x0, x28
    b.le .Low_count_done
    str x0, [x19, #8]
.Low_count_done:
    // metric cells (width slots 2+i)
    adrp x21, PAGE(tc_plan_col_count)
    add x21, x21, LO12(tc_plan_col_count)
    ldr x22, [x21]                     // col_count
    mov x23, #0                        // metric index i
.Low_loop:
    cmp x23, x22
    b.ge .Low_done
    adrp x24, PAGE(tc_plan_columns)
    add x24, x24, LO12(tc_plan_columns)
    ldr x24, [x24, x23, lsl #3]        // col id
    adrp x25, PAGE(tc_render_cell)
    add x25, x25, LO12(tc_render_cell)
    mov x0, x25
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    adrp x25, PAGE(tc_render_cell)
    add x25, x25, LO12(tc_render_cell)
    cmp x24, #TC_M_LIVE
    b.eq .Low_live
    cmp x24, #TC_M_OFFLINE
    b.eq .Low_offline
    cmp x24, #TC_M_UNKNOWN
    b.eq .Low_unknown
    cmp x24, #TC_M_OFFLINE_SHARE
    b.eq .Low_offshare
    // live-share
    mov x0, x25
    mov x1, x26
    mov x2, x20
    bl fmt_share_cell
    b .Low_place
.Low_offshare:
    mov x0, x25
    mov x1, x27
    mov x2, x20
    bl fmt_share_cell
    b .Low_place
.Low_live:
    mov x0, x25
    mov x1, x26
    bl fmt_u64_commas
    b .Low_place
.Low_offline:
    mov x0, x25
    mov x1, x27
    bl fmt_u64_commas
    b .Low_place
.Low_unknown:
    mov x0, x25
    mov x1, x28
    bl fmt_u64_commas
.Low_place:
    adrp x25, PAGE(tc_render_cell)
    add x25, x25, LO12(tc_render_cell)
    mov x0, x25
    bl tc_strlen
    add x26, x23, #2
    ldr x28, [x19, x26, lsl #3]
    cmp x0, x28
    b.le .Low_next
    str x0, [x19, x26, lsl #3]
.Low_next:
    add x23, x23, #1
    b .Low_loop
.Low_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// render_table — headers, rule, rows, "+ N others", rule, footer.
// ============================================================================
    .p2align 2
render_table:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_plan_col_count)
    add x19, x19, LO12(tc_plan_col_count)
    ldr x20, [x19]                     // n metric columns
    add x21, x20, #2                   // total cells: user + count + metrics
    // widths: w[i], i in 0..x21-1
    adrp x22, PAGE(tc_render_widths)
    add x22, x22, LO12(tc_render_widths)
    // header row: "user" + "count" + metric headers
    mov w23, #4
    str x23, [x22]                     // w[0] = 4 ("user")
    mov w23, #5
    str x23, [x22, #8]                 // w[1] = 5 ("count")
    mov x23, #0
.Lrt_hdr_w:
    cmp x23, x20
    b.ge .Lrt_hdr_w_done
    adrp x24, PAGE(metric_headers)
    add x24, x24, LO12(metric_headers)
    adrp x25, PAGE(tc_plan_columns)
    add x25, x25, LO12(tc_plan_columns)
    ldr x25, [x25, x23, lsl #3]
    ldr x24, [x24, x25, lsl #3]
    mov x0, x24
    bl tc_strlen
    add x26, x23, #2                  // w[2 + metric index]
    str x0, [x22, x26, lsl #3]
    add x23, x23, #1
    b .Lrt_hdr_w
.Lrt_hdr_w_done:
    // rows
    adrp x23, PAGE(tc_plan_reported)
    add x23, x23, LO12(tc_plan_reported)
    ldr x23, [x23]                     // reported base
    adrp x24, PAGE(tc_plan_displayed_n)
    add x24, x24, LO12(tc_plan_displayed_n)
    ldr x24, [x24]                     // displayed_n
    mov x25, #0                        // i
.Lrt_row_w:
    cmp x25, x24
    b.ge .Lrt_row_w_done
    mov x0, #ROW_SZ
    mul x0, x25, x0
    add x26, x23, x0                   // rec
    // login width
    add x0, x26, #ROW_LOGIN
    bl tc_strlen
    ldr x27, [x22]
    cmp x0, x27
    b.le .Lrt_row_w_cells
    str x0, [x22]
.Lrt_row_w_cells:
    mov x27, #0
.Lrt_row_w_cell:
    add x9, x27, #1                   // width slot index (1 + i)
    cmp x27, #0
    b.eq .Lrt_row_w_count
    adrp x28, PAGE(tc_plan_columns)
    add x28, x28, LO12(tc_plan_columns)
    sub x10, x27, #1
    ldr x28, [x28, x10, lsl #3]
    b .Lrt_row_w_len
.Lrt_row_w_count:
    mov x28, #TC_M_COUNT
.Lrt_row_w_len:
    mov x0, x26
    mov x1, x28
    bl cell_len
    add x9, x27, #1                   // recompute the slot: cell_len clobbers x9
    ldr x10, [x22, x9, lsl #3]
    cmp x0, x10
    b.le .Lrt_row_w_cell_next
    str x0, [x22, x9, lsl #3]
.Lrt_row_w_cell_next:
    add x27, x27, #1
    add x10, x20, #1
    cmp x27, x10
    b.lt .Lrt_row_w_cell
.Lrt_row_w_next:
    add x25, x25, #1
    b .Lrt_row_w
.Lrt_row_w_done:
    // "+ N others" row: login + count + metric widths (Python includes it)
    adrp x25, PAGE(tc_plan_hidden_n)
    add x25, x25, LO12(tc_plan_hidden_n)
    ldr x26, [x25]
    cbz x26, .Lrt_pin
    bl others_widths
.Lrt_pin:
    // Phase 7: a pinned login column is fixed, not merely capped: the clip in
    // pin_cell already bounded every login at `pin` characters, so widths[0]
    // is set to the pin exactly (Python: widths[0] = pinned).
    adrp x25, PAGE(tc_frame_pin_width)
    add x25, x25, LO12(tc_frame_pin_width)
    ldr x26, [x25]
    cbz x26, .Lrt_emit
    str x26, [x22]
.Lrt_emit:
    // header line
    adrp x19, PAGE(tc_render_line)
    add x19, x19, LO12(tc_render_line)
    mov x0, x19
    mov x1, x21                       // cell count
    mov x2, #1                        // header flag
    bl emit_table_header
    // rule
    mov x0, x19
    mov x1, x21
    bl emit_rule
    // rows
    adrp x23, PAGE(tc_plan_reported)
    add x23, x23, LO12(tc_plan_reported)
    ldr x23, [x23]
    adrp x24, PAGE(tc_plan_displayed_n)
    add x24, x24, LO12(tc_plan_displayed_n)
    ldr x24, [x24]
    mov x25, #0
.Lrt_row_emit:
    cmp x25, x24
    b.ge .Lrt_row_emit_done
    mov x0, #ROW_SZ
    mul x0, x25, x0
    add x26, x23, x0
    mov x0, x19
    mov x1, x26
    mov x2, x21
    bl emit_table_row
    add x25, x25, #1
    b .Lrt_row_emit
.Lrt_row_emit_done:
    // "+ N others" row
    adrp x26, PAGE(tc_plan_hidden_n)
    add x26, x26, LO12(tc_plan_hidden_n)
    ldr x26, [x26]
    cbz x26, .Lrt_rule2
    mov x0, x19
    mov x1, x26
    mov x2, x21
    bl emit_others_row
.Lrt_rule2:
    mov x0, x19
    mov x1, x21
    bl emit_rule
.Lrt_end:
    // footer
    bl emit_footer
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// cell_len(rec, col_id) -> x0 = rendered cell length (renders into cell buf)
    .p2align 2
cell_len:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // rec
    mov x20, x1                        // col
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    cmp x20, #TC_M_COUNT
    b.eq .Lcl_count
    cmp x20, #TC_M_LIVE
    b.eq .Lcl_live
    cmp x20, #TC_M_OFFLINE
    b.eq .Lcl_offline
    cmp x20, #TC_M_UNKNOWN
    b.eq .Lcl_unknown
    // share
    cmp x20, #TC_M_OFFLINE_SHARE
    b.eq .Lcl_offshare
    ldr x1, [x19, #ROW_LIVE]
    ldr x2, [x19, #ROW_COUNT]
    bl fmt_share_cell
    b .Lcl_len
.Lcl_offshare:
    ldr x1, [x19, #ROW_OFFLINE]
    ldr x2, [x19, #ROW_COUNT]
    bl fmt_share_cell
    b .Lcl_len
.Lcl_count:
    ldr x1, [x19, #ROW_COUNT]
    bl fmt_u64_commas
    b .Lcl_len
.Lcl_live:
    ldr x1, [x19, #ROW_LIVE]
    bl fmt_u64_commas
    b .Lcl_len
.Lcl_offline:
    ldr x1, [x19, #ROW_OFFLINE]
    bl fmt_u64_commas
    b .Lcl_len
.Lcl_unknown:
    ldr x1, [x19, #ROW_UNKNOWN]
    bl fmt_u64_commas
.Lcl_len:
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    bl tc_strlen
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_table_header(buf, ncols, flag) — header cells aligned "lr"
    .p2align 2
emit_table_header:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // buf
    mov x20, x1                        // ncols
    mov x21, x0                        // cursor
    bl line_zero
    mov x21, x0
    // cell 0: "user" ljust (pin-aware under watch)
    adrp x22, PAGE(tc_render_widths)
    add x22, x22, LO12(tc_render_widths)
    ldr x2, [x22]
    adrp x1, PAGE(s_user4)
    add x1, x1, LO12(s_user4)
    mov x0, x19
    bl pin_cell
    mov x21, x0
    // separator + "count" rjust w[1]
    mov w1, #' '
    strb w1, [x21], #1
    mov w1, #' '
    strb w1, [x21], #1
    adrp x24, PAGE(metric_headers)
    add x24, x24, LO12(metric_headers)   // table base (kept in x24)
    ldr x26, [x24, #0]                 // "count" header string (rodata)
    adrp x27, PAGE(tc_render_cell)
    add x27, x27, LO12(tc_render_cell)
    mov x0, x27
    mov x1, x26
    bl str_cat                          // copy into writable cell buffer
    ldr x27, [x22, #8]                 // w[1]
    adrp x26, PAGE(tc_render_cell)
    add x26, x26, LO12(tc_render_cell)
    mov x0, x21                        // line cursor
    mov x1, x26                        // cell
    mov x2, x27                        // width
    bl rjust_copy
    mov x21, x0
    // metric header cells rjust (width slot 2 + i)
    mov x23, #0
.Leth_loop:
    add x26, x23, #2
    cmp x26, x20
    b.ge .Leth_done
    mov w1, #' '
    strb w1, [x21], #1
    mov w1, #' '
    strb w1, [x21], #1
    adrp x25, PAGE(tc_plan_columns)
    add x25, x25, LO12(tc_plan_columns)
    ldr x25, [x25, x23, lsl #3]
    ldr x26, [x24, x25, lsl #3]        // header string (rodata)
    adrp x27, PAGE(tc_render_cell)
    add x27, x27, LO12(tc_render_cell)
    mov x0, x27
    mov x1, x26
    bl str_cat
    add x27, x23, #2
    ldr x27, [x22, x27, lsl #3]        // width
    adrp x26, PAGE(tc_render_cell)
    add x26, x26, LO12(tc_render_cell)
    mov x0, x21                        // line cursor
    mov x1, x26
    mov x2, x27
    bl rjust_copy
    mov x21, x0
    add x23, x23, #1
    b .Leth_loop
.Leth_done:
    mov w1, #0
    strb w1, [x21]
    mov x0, x19
    bl line_puts
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_rule(buf, ncols) — dashes per width, joined "  "
    .p2align 2
emit_rule:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x0
    bl line_zero
    mov x21, x0
    adrp x22, PAGE(tc_render_widths)
    add x22, x22, LO12(tc_render_widths)
    mov x23, #0
.Leru_loop:
    cmp x23, x20
    b.ge .Leru_done
    cbnz x23, .Leru_sep
    b .Leru_dashes
.Leru_sep:
    mov w1, #' '
    strb w1, [x21], #1
    mov w1, #' '
    strb w1, [x21], #1
.Leru_dashes:
    ldr x24, [x22, x23, lsl #3]
    mov x25, #0
.Leru_dash:
    cmp x25, x24
    b.ge .Leru_next
    mov w1, #'-'
    strb w1, [x21], #1
    add x25, x25, #1
    b .Leru_dash
.Leru_next:
    add x23, x23, #1
    b .Leru_loop
.Leru_done:
    mov w1, #0
    strb w1, [x21]
    mov x0, x19
    bl line_puts
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_table_row(buf, rec, ncols) — login ljust, metric cells rjust
    .p2align 2
emit_table_row:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // buf
    mov x20, x1                        // rec
    mov x21, x2                        // ncols
    mov x22, x0                        // cursor
    bl line_zero
    mov x22, x0
    adrp x23, PAGE(tc_render_widths)
    add x23, x23, LO12(tc_render_widths)
    // login cell (pin-aware under watch)
    ldr x24, [x23]
    mov x0, x19
    add x1, x20, #ROW_LOGIN
    mov x2, x24
    bl pin_cell
    mov x22, x0
    // count cell rjust w[1]
    mov w1, #' '
    strb w1, [x22], #1
    mov w1, #' '
    strb w1, [x22], #1
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov x1, #TC_M_COUNT
    mov x0, x20
    bl cell_render
    adrp x25, PAGE(tc_render_cell)
    add x25, x25, LO12(tc_render_cell)
    ldr x26, [x23, #8]                 // w[1]
    mov x0, x22                        // line cursor
    mov x1, x25
    mov x2, x26
    bl rjust_copy
    mov x22, x0
    mov x24, #0
.Letr_loop:
    add x26, x24, #2
    cmp x26, x21
    b.ge .Letr_done
    mov w1, #' '
    strb w1, [x22], #1
    mov w1, #' '
    strb w1, [x22], #1
    // render metric cell into tc_render_cell
    adrp x25, PAGE(tc_plan_columns)
    add x25, x25, LO12(tc_plan_columns)
    ldr x26, [x25, x24, lsl #3]
    mov x0, x20
    mov x1, x26
    bl cell_render
    adrp x25, PAGE(tc_render_cell)
    add x25, x25, LO12(tc_render_cell)
    add x26, x24, #2
    ldr x26, [x23, x26, lsl #3]
    mov x0, x22                        // line cursor
    mov x1, x25
    mov x2, x26
    bl rjust_copy
    mov x22, x0
    add x24, x24, #1
    b .Letr_loop
.Letr_done:
    mov w1, #0
    strb w1, [x22]
    // Phase 7: a tint hook (watch mode) wraps each displayed row's text.
    adrp x9, PAGE(tc_frame_tint_fn)
    add x9, x9, LO12(tc_frame_tint_fn)
    ldr x9, [x9]
    cbz x9, .Letr_puts
    adrp x0, PAGE(tc_frame_tint_ctx)
    add x0, x0, LO12(tc_frame_tint_ctx)
    ldr x0, [x0]
    mov x1, x20                        // rec
    mov x2, x19                        // text
    blr x9
    mov x19, x0                        // tinted text (capture copies it)
.Letr_puts:
    mov x0, x19
    bl line_puts
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// cell_render(rec, col_id) -> renders into tc_render_cell, returns end
    .p2align 2
cell_render:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    cmp x20, #TC_M_COUNT
    b.eq .Lcr_count
    cmp x20, #TC_M_LIVE
    b.eq .Lcr_live
    cmp x20, #TC_M_OFFLINE
    b.eq .Lcr_offline
    cmp x20, #TC_M_UNKNOWN
    b.eq .Lcr_unknown
    cmp x20, #TC_M_OFFLINE_SHARE
    b.eq .Lcr_offshare
    ldr x1, [x19, #ROW_LIVE]
    ldr x2, [x19, #ROW_COUNT]
    bl fmt_share_cell
    b .Lcr_done
.Lcr_offshare:
    ldr x1, [x19, #ROW_OFFLINE]
    ldr x2, [x19, #ROW_COUNT]
    bl fmt_share_cell
    b .Lcr_done
.Lcr_count:
    ldr x1, [x19, #ROW_COUNT]
    bl fmt_u64_commas
    b .Lcr_done
.Lcr_live:
    ldr x1, [x19, #ROW_LIVE]
    bl fmt_u64_commas
    b .Lcr_done
.Lcr_offline:
    ldr x1, [x19, #ROW_OFFLINE]
    bl fmt_u64_commas
    b .Lcr_done
.Lcr_unknown:
    ldr x1, [x19, #ROW_UNKNOWN]
    bl fmt_u64_commas
.Lcr_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_others_row(buf, hidden_n, ncols) — the pooled "+ N others" row
    .p2align 2
emit_others_row:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // buf
    mov x20, x1                        // hidden_n
    mov x21, x2                        // ncols
    mov x22, x0                        // cursor
    bl line_zero
    mov x22, x0
    adrp x23, PAGE(tc_render_widths)
    add x23, x23, LO12(tc_render_widths)
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    // login cell "+ N others" (built in the cell buffer: pin-aware under watch)
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov w1, #'+'
    strb w1, [x0], #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x1, x20
    bl fmt_u64_commas
    adrp x1, PAGE(s_others)
    add x1, x1, LO12(s_others)
    bl str_cat
    ldr x24, [x23]
    adrp x1, PAGE(tc_render_cell)
    add x1, x1, LO12(tc_render_cell)
    mov x0, x19
    mov x2, x24
    bl pin_cell
    mov x22, x0
    // The metric cells render into tc_render_cell and rely on it being
    // zeroed (fmt_u64_commas writes no NUL); the login-cell build above
    // wrote into it, so clear it again before the cell loop.
    adrp x0, PAGE(tc_render_cell)
    add x0, x0, LO12(tc_render_cell)
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    // pooled states over hidden rows
    adrp x24, PAGE(tc_plan_reported)
    add x24, x24, LO12(tc_plan_reported)
    ldr x24, [x24]
    adrp x25, PAGE(tc_plan_displayed_n)
    add x25, x25, LO12(tc_plan_displayed_n)
    ldr x25, [x25]
    mov x26, #0                        // pooled live
    mov x27, #0                        // pooled offline
    mov x28, #0                        // pooled unknown
    mov x9, #0                         // i (rec index = displayed_n + i)
.Leor_pool:
    cmp x9, x20
    b.ge .Leor_pool_done
    // rec index = displayed_n + i  (hidden follows displayed)
    add x10, x25, x9
    mov x0, #ROW_SZ
    mul x0, x10, x0
    add x0, x24, x0
    ldr x11, [x0, #ROW_LIVE]
    add x26, x26, x11
    ldr x11, [x0, #ROW_OFFLINE]
    add x27, x27, x11
    ldr x11, [x0, #ROW_UNKNOWN]
    add x28, x28, x11
    add x9, x9, #1
    b .Leor_pool
.Leor_pool_done:
    // metric cells: cell 0 = count, then the metric columns
    mov x24, #0
.Leor_loop:
    add x10, x24, #1                   // width slot: count -> 1, metric i -> 2+i
    cmp x10, x21
    b.ge .Leor_done
    mov w1, #' '
    strb w1, [x22], #1
    mov w1, #' '
    strb w1, [x22], #1
    cmp x24, #0
    b.eq .Leor_count
    adrp x11, PAGE(tc_plan_columns)
    add x11, x11, LO12(tc_plan_columns)
    sub x13, x24, #1
    ldr x11, [x11, x13, lsl #3]
    adrp x12, PAGE(tc_render_cell)
    add x12, x12, LO12(tc_render_cell)
    cmp x11, #TC_M_LIVE
    b.eq .Leor_live
    cmp x11, #TC_M_OFFLINE
    b.eq .Leor_offline
    cmp x11, #TC_M_UNKNOWN
    b.eq .Leor_unknown
    cmp x11, #TC_M_OFFLINE_SHARE
    b.eq .Leor_offshare
    // live-share: pooled live / hidden msgs
    mov x0, x12
    mov x1, x26
    mov x2, x20
    bl fmt_share_cell
    b .Leor_place
.Leor_offshare:
    mov x0, x12
    mov x1, x27
    mov x2, x20
    bl fmt_share_cell
    b .Leor_place
.Leor_count:
    adrp x12, PAGE(tc_render_cell)
    add x12, x12, LO12(tc_render_cell)
    mov x0, x12
    adrp x13, PAGE(tc_plan_msgs_hidden)
    add x13, x13, LO12(tc_plan_msgs_hidden)
    ldr x1, [x13]
    bl fmt_u64_commas
    b .Leor_place
.Leor_live:
    mov x0, x12
    mov x1, x26
    bl fmt_u64_commas
    b .Leor_place
.Leor_offline:
    mov x0, x12
    mov x1, x27
    bl fmt_u64_commas
    b .Leor_place
.Leor_unknown:
    mov x0, x12
    mov x1, x28
    bl fmt_u64_commas
.Leor_place:
    adrp x12, PAGE(tc_render_cell)
    add x12, x12, LO12(tc_render_cell)
    add x10, x24, #1                   // width slot (recomputed: cell renders
    ldr x13, [x23, x10, lsl #3]        // clobber caller-saved x10)
    mov x0, x22                        // line cursor
    mov x1, x12                        // cell
    mov x2, x13                        // width
    bl rjust_copy
    mov x22, x0
    add x24, x24, #1
    b .Leor_loop
.Leor_done:
    mov w1, #0
    strb w1, [x22]
    mov x0, x19
    bl line_puts
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// pad_left_to(buf, width) — pad the string at buf with trailing spaces until
// its length is `width`; returns the cursor (buf + width).  Assumes the buf
// string is NUL-terminated and shorter than width.
// ============================================================================
    .p2align 2
pad_left_to:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    bl tc_strlen
    mov x21, x0
    add x0, x19, x21
.Lplt_loop:
    cmp x21, x20
    b.ge .Lplt_done
    mov w1, #' '
    strb w1, [x19, x21]
    add x21, x21, #1
    b .Lplt_loop
.Lplt_done:
    add x0, x19, x21
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// rjust_copy(dst, src, width) -> dst + width; writes leading spaces then the
// NUL-terminated src (which must be <= width) into dst.  No NUL is written.
    .p2align 2
rjust_copy:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // dst
    mov x20, x1                        // src
    mov x21, x2                        // width
    mov x0, x20
    bl tc_strlen
    mov x22, x0                        // len
    sub x23, x21, x22                  // leading pad count
    mov x24, #0
.Lrj_pad:
    cmp x24, x23
    b.ge .Lrj_copy
    mov w1, #' '
    strb w1, [x19, x24]
    add x24, x24, #1
    b .Lrj_pad
.Lrj_copy:
    add x0, x19, x24
    mov x1, x20
    mov x2, x22
    bl str_cat_n
    add x0, x19, x21
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// emit_footer — "users; messages" + the excluded line when exclusions acted.
// ============================================================================
    .p2align 2
emit_footer:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    bl line_zero
    adrp x19, PAGE(tc_render_line)
    add x19, x19, LO12(tc_render_line)
    mov x20, x19                       // cursor
    adrp x21, PAGE(tc_plan_displayed_n)
    add x21, x21, LO12(tc_plan_displayed_n)
    ldr x22, [x21]                     // displayed
    adrp x21, PAGE(tc_plan_reported_n)
    add x21, x21, LO12(tc_plan_reported_n)
    ldr x23, [x21]                     // reported
    adrp x21, PAGE(tc_plan_hidden_n)
    add x21, x21, LO12(tc_plan_hidden_n)
    ldr x24, [x21]                     // hidden
    adrp x21, PAGE(tc_plan_in_range)
    add x21, x21, LO12(tc_plan_in_range)
    ldr x25, [x21]                     // in_range
    cbnz x24, .Lef_hidden
    // "R of K user(s)"
    mov x0, x20
    mov x1, x23
    bl fmt_u64_commas
    mov x20, x0
    adrp x1, PAGE(s_of)
    add x1, x1, LO12(s_of)
    mov x0, x20
    bl str_cat
    sub x0, x0, #1
    mov x20, x0
    mov x1, x25
    bl fmt_u64_commas
    mov x20, x0
    adrp x1, PAGE(s_user_s)
    add x1, x1, LO12(s_user_s)
    mov x0, x20
    bl str_cat
    mov x20, x0
    b .Lef_msgs
.Lef_hidden:
    // "D of R user(s) above threshold (K in range)"
    mov x0, x20
    mov x1, x22
    bl fmt_u64_commas
    mov x20, x0
    adrp x1, PAGE(s_of)
    add x1, x1, LO12(s_of)
    mov x0, x20
    bl str_cat
    sub x0, x0, #1
    mov x20, x0
    mov x1, x23
    bl fmt_u64_commas
    mov x20, x0
    adrp x1, PAGE(s_user_s)
    add x1, x1, LO12(s_user_s)
    mov x0, x20
    bl str_cat
    sub x0, x0, #1
    mov x20, x0
    adrp x1, PAGE(s_above_threshold)
    add x1, x1, LO12(s_above_threshold)
    mov x0, x20
    bl str_cat
    sub x0, x0, #1
    mov x20, x0
    mov x1, x25
    bl fmt_u64_commas
    mov x20, x0
    adrp x1, PAGE(s_in_range_paren)
    add x1, x1, LO12(s_in_range_paren)
    mov x0, x20
    bl str_cat
    mov x20, x0
.Lef_msgs:
    // "; S of T message(s) in range"
    adrp x1, PAGE(s_semicolon)
    add x1, x1, LO12(s_semicolon)
    sub x0, x20, #1                  // overwrite the trailing NUL
    bl str_cat
    mov x20, x0
    adrp x21, PAGE(tc_plan_msgs_shown)
    add x21, x21, LO12(tc_plan_msgs_shown)
    ldr x21, [x21]
    sub x0, x20, #1
    mov x1, x21
    bl fmt_u64_commas
    mov x20, x0
    adrp x1, PAGE(s_of)
    add x1, x1, LO12(s_of)
    mov x0, x20
    bl str_cat
    sub x0, x0, #1
    mov x20, x0
    adrp x21, PAGE(tc_tally)
    add x21, x21, LO12(tc_tally)
    ldr x21, [x21, #TC_T_MESSAGES]
    mov x1, x21
    bl fmt_u64_commas
    mov x20, x0
    adrp x1, PAGE(s_msg_range)
    add x1, x1, LO12(s_msg_range)
    mov x0, x20
    bl str_cat
    mov x0, x19
    bl line_puts
    // excluded line
    adrp x21, PAGE(tc_plan_excl_appeared)
    add x21, x21, LO12(tc_plan_excl_appeared)
    ldr x22, [x21]
    cbz x22, .Lef_done
    bl emit_excluded_line
.Lef_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_excluded_line — "excluded E user(s), M message(s) not counted"
    .p2align 2
emit_excluded_line:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    bl line_zero
    adrp x19, PAGE(tc_render_line)
    add x19, x19, LO12(tc_render_line)
    mov x0, x19
    adrp x1, PAGE(s_excluded_pre)
    add x1, x1, LO12(s_excluded_pre)
    bl str_cat
    sub x0, x0, #1
    adrp x20, PAGE(tc_plan_excl_appeared)
    add x20, x20, LO12(tc_plan_excl_appeared)
    ldr x1, [x20]
    bl fmt_u64_commas
    adrp x1, PAGE(s_excluded_mid)
    add x1, x1, LO12(s_excluded_mid)
    bl str_cat
    adrp x20, PAGE(tc_plan_excl_msgs)
    add x20, x20, LO12(tc_plan_excl_msgs)
    ldr x1, [x20]
    sub x0, x0, #1
    bl fmt_u64_commas
    adrp x1, PAGE(s_not_counted2)
    add x1, x1, LO12(s_not_counted2)
    bl str_cat
    mov x0, x19
    bl line_puts
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_render_report — the Wave E entry: plan, then emit JSON or text.
// ============================================================================
    .p2align 2
    .global tc_render_report
    FUNC_TYPE(tc_render_report)
tc_render_report:
    stp x29, x30, [sp, #-16]!
    bl tc_plan_presentation
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.ne .Lrr_json
    bl tc_render_text
    b .Lrr_done
.Lrr_json:
    bl tc_json_emit
.Lrr_done:
    mov x0, #0
    ldp x29, x30, [sp], #16
    ret

// read-only message data
    RODATA
s_newline:          .asciz "\n"
s_user4:            .asciz "user"
s_of_slash:         .asciz " / "
s_excl:             .asciz " excl"
s_slash:            .asciz "/"
s_users_c:          .asciz " users"
    .bss
    .p2align 3
tc_render_widths:   .skip 8 * 8

    .end
