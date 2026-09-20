// ============================================================================
// tc_render.S — ranking, provenance header, table and footer for
//               twitch-counts
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//  Linking:    by the Makefile (build/<os>/twitch-counts and the drivers)
//
//  Byte-for-byte port of the Python reference's presentation half:
//    rank_users / choose_columns / render_choose_limit / plan_presentation
//    (4507-4791), provenance_rows / window_span / state_row / exclude_row /
//    share_floor_row / users_row / cache_row / unreadable_row (4550-4686),
//    header_lines / compact_header / column_widths / align_row (4811-4869),
//    results_table / footer_lines (4872-4947), render_text (4950-4985).
//
//  Exported (all .global, AAPCS64, x19-x28 preserved):
//    tc_render_report()    -> 0   the entry: plan, then emit JSON or
//                                 text exactly like run_report().
//    tc_plan_presentation()-> 0   fill the plan (ranking, columns, header
//                                 rows, limit); may exit 1 on the degenerate
//                                 per-state error.
//    tc_render_text()      -> 0   render the text report from the plan.
//    tc_report_fail(x0=msg)      "error: <msg>" stderr + exit 1, or the JSON
//                                 {"error": <msg>} shape under --json.
//
//  Frame-capture additions (watch mode; all default OFF so the
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
//  Reads (never writes): tc_opts / tc_window / tc_users / tc_tally /
//    tc_listing, tc_excl_set / tc_excl_sources / tc_excl_src_count,
//    tc_channel_name / tc_count_column / tc_user_state (tc_core.S),
//    tc_source_str (tc_cli.S), tc_shorten_path (tc_config.S),
//    tc_cache_status (tc_cache.S).
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
    .globl tc_fmt2
    .globl tc_fmt4
    .globl tc_setting_src_str

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
render_compact:   .skip LINE_SZ
render_line:      .skip LINE_SZ
render_cell:      .skip CELL_SZ
render_errbuf:    .skip ERR_SZ
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
    LEA x0, tc_opts
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

// render_line_zero() / render_compact_zero() — clear a render buffer so strlen-based padding
// never reads stale bytes from the previous line.
render_line_zero:
    PROLOGUE 0
    LEA x0, render_line
    mov x1, #0
    mov x2, #LINE_SZ
    bl memset
    EPILOGUE 0
    ret

render_compact_zero:
    PROLOGUE 0
    LEA x0, render_compact
    mov x1, #0
    mov x2, #LINE_SZ
    bl memset
    EPILOGUE 0
    ret

// render_line_puts(s) — print s to stdout followed by a newline (every rendered line
// in this module ends with one, exactly like Python's print).  While frame
// capture is armed, copies the line into the next capture slot instead.
    .p2align 2
render_line_puts:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    LEA x9, tc_frame_capture
    ldr x9, [x9]
    cbz x9, .Llp_print
    // capture: copy into tc_frame_lines[count] (drop when the frame is full)
    LEA x9, tc_frame_count
    ldr x10, [x9]
    LEA x11, tc_frame_max
    ldr x11, [x11]
    cmp x10, x11
    b.ge .Llp_cap_done
    LEA x11, tc_frame_lines
    ldr x11, [x11]
    ldr x11, [x11, x10, lsl #3]
    mov x0, x11
    mov x1, x19
    bl render_str_cat
    add x10, x10, #1
    str x10, [x9]
.Llp_cap_done:
    ldp x19, x30, [sp], #16
    ret
.Llp_print:
    bl tc_puts
    LEA x0, s_newline
    bl tc_puts
    ldp x19, x30, [sp], #16
    ret

// render_line_blank() — the blank separator line (Python's header_lines trailing "").
    .p2align 2
render_line_blank:
    stp x19, x30, [sp, #-16]!
    LEA x9, tc_frame_capture
    ldr x9, [x9]
    cbz x9, .Llb_print
    LEA x9, tc_frame_count
    ldr x10, [x9]
    LEA x11, tc_frame_max
    ldr x11, [x11]
    cmp x10, x11
    b.ge .Llb_done
    LEA x11, tc_frame_lines
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
    LEA x0, s_newline
    bl tc_puts
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// Frame-capture API (watch mode)
// ============================================================================
    .p2align 2
    .global tc_frame_begin
    FUNC_TYPE(tc_frame_begin)
tc_frame_begin:
    PROLOGUE 0
    LEA x9, tc_frame_lines
    str x0, [x9]
    LEA x9, tc_frame_max
    str x1, [x9]
    LEA x9, tc_frame_count
    str xzr, [x9]
    LEA x9, tc_frame_capture
    mov x10, #1
    str x10, [x9]
    EPILOGUE 0
    ret

    .p2align 2
    .global tc_frame_end
    FUNC_TYPE(tc_frame_end)
tc_frame_end:
    PROLOGUE 0
    LEA x9, tc_frame_capture
    str xzr, [x9]
    EPILOGUE 0
    ret

    .p2align 2
    .global tc_frame_set_pin
    FUNC_TYPE(tc_frame_set_pin)
tc_frame_set_pin:
    PROLOGUE 0
    LEA x9, tc_frame_pin_width
    str x0, [x9]
    EPILOGUE 0
    ret

    .p2align 2
    .global tc_frame_set_tint
    FUNC_TYPE(tc_frame_set_tint)
tc_frame_set_tint:
    PROLOGUE 0
    LEA x9, tc_frame_tint_fn
    str x0, [x9]
    LEA x9, tc_frame_tint_ctx
    str x1, [x9]
    EPILOGUE 0
    ret

// ============================================================================
// render_pin_cell(dst, src, width) -> dst after the login cell (watch mode).
//   With tc_frame_pin_width > 0 and strlen(src) > width, writes width-1 bytes
//   of src then U+2026 (no padding: the ellipsis is one visible column).  In
//   the unclipped case copies src and pads to `width` exactly like the
//   existing render_pad_left_to callers.  The pinned width is applied to the widths
//   table by render_table before any emit, so `width` is already the pin.
// ============================================================================
    .p2align 2
render_pin_cell:
    PROLOGUE 2
    mov x19, x0                        // dst
    mov x20, x1                        // src
    mov x21, x2                        // width
    LEA x9, tc_frame_pin_width
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
    bl render_str_cat_n
    mov w3, #0xE2
    strb w3, [x0], #1
    mov w3, #0x80
    strb w3, [x0], #1
    mov w3, #0xA6
    strb w3, [x0], #1
    EPILOGUE 2
    ret
.Lpc_pad:
    mov x0, x19
    mov x1, x20
    bl render_str_cat
    mov x0, x19
    mov x1, x21
    bl render_pad_left_to
    EPILOGUE 2
    ret

// render_str_cat(dst, src) -> dst after the copied NUL
//   Word-at-a-time: bulk-copies 8-byte words while no byte of the source word
//   is NUL (SWAR haszero), then finishes byte-by-byte from the word that holds
//   the NUL.  The final word load may transiently read up to 7 bytes past the
//   NUL of `src`; every render_str_cat source here (rodata, .bss line/cell
//   buffers, the arena, malloc'd 26-byte login records) is inside a mapped
//   region with slack past the string, so the over-read is never dereferenced
//   or written — the byte tail copies exactly through the NUL.
    .p2align 2
render_str_cat:
    mov x2, x0
    mov x4, #0x0101010101010101
    mov x5, #0x8080808080808080
.Lsc_loop:
    ldr x3, [x1], #8
    sub x6, x3, x4
    bic x7, x6, x3
    ands x7, x7, x5
    b.ne .Lsc_tail
    str x3, [x2], #8
    b .Lsc_loop
.Lsc_tail:
    sub x1, x1, #8                  // rewind once to the word that holds the NUL
.Lsc_tail_loop:
    ldrb w3, [x1], #1
    strb w3, [x2], #1
    cbnz w3, .Lsc_tail_loop
    mov x0, x2
    ret

// render_str_cat_n(dst, src, len) -> dst + len (no NUL)
//   ldp/stp 16-byte bulk copy + byte tail; reads exactly `len` bytes.
    .p2align 2
render_str_cat_n:
    mov x3, x0
.Lscn_wide:
    cmp x2, #16
    b.lt .Lscn_tail
    ldp x4, x5, [x1], #16
    stp x4, x5, [x3], #16
    sub x2, x2, #16
    b .Lscn_wide
.Lscn_tail:
    cbz x2, .Lscn_done
    ldrb w4, [x1], #1
    strb w4, [x3], #1
    sub x2, x2, #1
    b .Lscn_tail
.Lscn_done:
    mov x0, x3
    ret

// render_fmt_u64_plain(dst, v) -> dst after digits (no NUL)
//   Counts the digits first (reciprocal divide-by-10), then writes the digits
//   MSB-first directly into dst walking the pointer down — no stack temp
//   buffer, no copy loop.
    .p2align 2
render_fmt_u64_plain:
    PROLOGUE 0
    mov x2, x1                      // t = v
    mov x3, #0                      // n = digit count
    cbz x1, .Lfup_zero
    ldr x4, =0xCCCCCCCCCCCCCCCD     // divide-by-10 magic (umulh >> 3)
.Lfup_count:
    umulh x5, x2, x4
    lsr x5, x5, #3
    add x3, x3, #1
    mov x2, x5
    cbnz x2, .Lfup_count
    b .Lfup_write
.Lfup_zero:
    mov w2, #'0'
    strb w2, [x0]
    add x0, x0, #1
    EPILOGUE 0
    ret
.Lfup_write:
    add x2, x0, x3                  // cursor = dst + n
    mov x5, #10
.Lfup_wloop:
    umulh x6, x1, x4
    lsr x6, x6, #3                  // q = v / 10
    msub x7, x6, x5, x1             // r = v % 10
    add x7, x7, #'0'
    sub x2, x2, #1
    strb w7, [x2]
    mov x1, x6
    cbnz x1, .Lfup_wloop
    add x0, x2, x3                  // dst + n
    EPILOGUE 0
    ret

// render_fmt_u64_commas(dst, v) -> dst after digits (no NUL), thousands commas
//   Same count-first structure; the comma count (n-1)/3 is known up front, so
//   the digits and commas are written in place walking down from the end.
    .p2align 2
render_fmt_u64_commas:
    PROLOGUE 0
    mov x2, x1                      // t = v
    mov x3, #0                      // n = digit count
    cbz x1, .Lfuc_zero
    ldr x4, =0xCCCCCCCCCCCCCCCD     // divide-by-10 magic (umulh >> 3)
.Lfuc_count:
    umulh x5, x2, x4
    lsr x5, x5, #3
    add x3, x3, #1
    mov x2, x5
    cbnz x2, .Lfuc_count
    b .Lfuc_write
.Lfuc_zero:
    mov w2, #'0'
    strb w2, [x0]
    add x0, x0, #1
    EPILOGUE 0
    ret
.Lfuc_write:
    sub x2, x3, #1
    mov x5, #3
    udiv x6, x2, x5                 // comma count = (n-1)/3
    add x7, x0, x3
    add x7, x7, x6                  // end = dst + n + commas
    mov x2, x7                      // cursor = end
    mov x8, #3                      // comma countdown
    mov x9, #10
.Lfuc_wloop:
    umulh x10, x1, x4
    lsr x10, x10, #3                // q = v / 10
    msub x11, x10, x9, x1           // r = v % 10
    add x11, x11, #'0'
    sub x2, x2, #1
    strb w11, [x2]
    sub x8, x8, #1
    mov x1, x10
    cbz x1, .Lfuc_done
    cbnz x8, .Lfuc_wloop
    sub x2, x2, #1                  // every 3 digits from the right: comma
    mov w11, #','
    strb w11, [x2]
    mov x8, #3
    b .Lfuc_wloop
.Lfuc_done:
    mov x0, x7                      // end
    EPILOGUE 0
    ret

// render_fmt_u64_commas_len(v) -> x0 = rendered length of fmt_u64_commas(v)
//   Pure arithmetic (digit count + commas) — used by the table width pass so
//   integer cells never need a render + strlen to size themselves.
    .p2align 2
render_fmt_u64_commas_len:
    mov x1, x0                      // v
    mov x2, #0                      // n
    cbz x1, .Lfucl_zero
    ldr x3, =0xCCCCCCCCCCCCCCCD     // divide-by-10 magic (umulh >> 3)
.Lfucl_count:
    umulh x4, x1, x3
    lsr x4, x4, #3
    add x2, x2, #1
    mov x1, x4
    cbnz x1, .Lfucl_count
    sub x1, x2, #1
    mov x3, #3
    udiv x4, x1, x3
    add x0, x2, x4                  // n + (n-1)/3
    ret
.Lfucl_zero:
    mov x0, #1
    ret

// render_fmt_datetime(dst, ymd, sod, sep) -> dst+19, "YYYY-MM-DD<sep>HH:MM:SS"
    .p2align 2
render_fmt_datetime:
    PROLOGUE 2
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov w22, w3
    mov x1, x20
    mov x2, #YMD_YEAR_SCALE
    udiv x6, x20, x2
    mov x0, x19
    mov x1, x6
    bl tc_fmt4
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #YMD_MONTH_SCALE
    udiv x6, x20, x2
    mov x8, #100
    udiv x9, x6, x8
    msub x9, x9, x8, x6
    mov w1, w9
    bl tc_fmt2
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #100
    udiv x6, x20, x2
    msub x6, x6, x2, x20
    mov w1, w6
    bl tc_fmt2
    strb w22, [x0], #1
    mov x1, x21
    mov x2, #SECS_PER_HOUR
    udiv x6, x21, x2
    mov w1, w6
    bl tc_fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #SECS_PER_HOUR
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    mov w1, w6
    bl tc_fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #SECS_PER_HOUR
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    msub x6, x6, x2, x9
    mov w1, w6
    bl tc_fmt2
    EPILOGUE 2
    ret

// render_fmt_hhmm(dst, sod) -> dst+5, "HH:MM"  (sod survives the fmt2 calls)
    .p2align 2
render_fmt_hhmm:
    PROLOGUE 1
    mov x19, x1                        // sod
    mov x2, #SECS_PER_HOUR
    udiv x3, x19, x2
    mov w1, w3
    bl tc_fmt2                            // hour
    mov w3, #':'
    strb w3, [x0], #1
    mov x2, #SECS_PER_HOUR
    udiv x4, x19, x2
    msub x4, x4, x2, x19
    mov x2, #60
    udiv x4, x4, x2
    mov w1, w4
    bl tc_fmt2                            // minute
    EPILOGUE 1
    ret

// render_fmt_mmdd_hhmm(dst, ymd, sod) -> dst+11, "MM-DD HH:MM"
    .p2align 2
render_fmt_mmdd_hhmm:
    PROLOGUE 2
    mov x19, x0                        // dst
    mov x20, x1                        // ymd
    mov x21, x2                        // sod
    mov x2, #100
    udiv x3, x20, x2
    mov x4, #100
    udiv x5, x3, x4
    msub x5, x5, x4, x3
    mov w1, w5
    bl tc_fmt2                            // month
    mov w3, #'-'
    strb w3, [x0], #1
    mov x2, #100
    udiv x3, x20, x2
    msub x3, x3, x2, x20
    mov w1, w3
    bl tc_fmt2                            // day
    mov w3, #' '
    strb w3, [x0], #1
    mov x1, x21
    bl render_fmt_hhmm
    EPILOGUE 2
    ret

// render_fmt_ymd(dst, ymd) -> dst+10, "YYYY-MM-DD"  (ymd survives the fmt calls)
    .p2align 2
render_fmt_ymd:
    PROLOGUE 1
    mov x19, x0                        // dst
    mov x20, x1                        // ymd
    mov x2, #YMD_YEAR_SCALE
    udiv x3, x20, x2
    mov w1, w3
    bl tc_fmt4                            // year
    mov w3, #'-'
    strb w3, [x0], #1
    mov x2, #YMD_MONTH_SCALE
    udiv x3, x20, x2
    mov x4, #YMD_MONTH_SCALE
    udiv x5, x3, x4
    msub x5, x5, x4, x3
    mov w1, w5
    bl tc_fmt2                            // month
    mov w3, #'-'
    strb w3, [x0], #1
    mov x2, #100
    udiv x3, x20, x2
    msub x3, x3, x2, x20
    mov w1, w3
    bl tc_fmt2                            // day
    EPILOGUE 1
    ret

// render_fmt_human_duration(dst, seconds) -> dst after NUL (Python human_duration)
    .p2align 2
render_fmt_human_duration:
    PROLOGUE 1
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
    bl render_fmt_u64_plain
    mov w2, #'d'
    strb w2, [x0], #1
    mov x19, x0
.Lfhd_hours:
    cmp x20, #SECS_PER_HOUR
    b.lt .Lfhd_mins
    mov x2, #SECS_PER_HOUR
    udiv x3, x20, x2
    msub x20, x3, x2, x20
    mov x0, x19
    mov x1, x3
    bl render_fmt_u64_plain
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
    bl render_fmt_u64_plain
    mov w2, #'m'
    strb w2, [x0], #1
    mov x19, x0
.Lfhd_secs:
    cmp x20, #1
    b.lt .Lfhd_nul
    mov x0, x19
    mov x1, x20
    bl render_fmt_u64_plain
    mov w2, #'s'
    strb w2, [x0], #1
    mov x19, x0
.Lfhd_nul:
    mov w2, #0
    strb w2, [x19], #1
.Lfhd_done:
    mov x0, x19
    EPILOGUE 1
    ret

// render_fmt_share_cell(dst, state, total) -> dst + chars; "%.1f%%" of 100*state/total
    .p2align 2
render_fmt_share_cell:
    PROLOGUE 1
    mov x19, x0
    mov x20, x2
    cbnz x20, .Lfsc_div
    fmov d0, xzr
    b .Lfsc_go
.Lfsc_div:
    ucvtf d0, x1
    LEA x9, dbl_100
    ldr d1, [x9]
    fmul d0, d0, d1
    ucvtf d1, x20
    fdiv d0, d0, d1
.Lfsc_go:
    mov x0, x19
    mov x1, #CELL_SZ
    LEA x2, s_share_fmt
    bl tc_snprintf_d
    add x0, x19, x0
    EPILOGUE 1
    ret

// ============================================================================
// Arena helpers
// ============================================================================

// render_arena_get() -> x0 = current end pointer
    .p2align 2
render_arena_get:
    LEA x1, tc_plan_arena_cur
    ldr x2, [x1]
    LEA x0, tc_plan_arena
    add x0, x0, x2
    ret

// render_arena_set_end(x0=end ptr): cur = end - arena_base
    .p2align 2
render_arena_set_end:
    LEA x1, tc_plan_arena
    sub x0, x0, x1
    LEA x2, tc_plan_arena_cur
    str x0, [x2]
    ret

// render_hdr_add(label, value, source, compact) — append one HeaderRow descriptor
    .p2align 2
render_hdr_add:
    LEA x4, tc_plan_hdr_count
    ldr x5, [x4]
    cmp x5, #HDR_MAX
    b.ge .Lha_done
    LEA x6, tc_plan_rows
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

// ============================================================================
// tc_plan_presentation — the layout phase (Python plan_presentation).
// ============================================================================
    .p2align 2
    .global tc_plan_presentation
    FUNC_TYPE(tc_plan_presentation)
tc_plan_presentation:
    PROLOGUE 0
    // reset the plan
    LEA x0, tc_plan_arena_cur
    str xzr, [x0]
    LEA x0, tc_plan_hdr_count
    str xzr, [x0]
    LEA x0, tc_plan_src_join
    str xzr, [x0]
    LEA x0, tc_plan_reported
    str xzr, [x0]
    LEA x0, tc_plan_excl_names
    str xzr, [x0]
    LEA x0, tc_plan_share_floor
    str xzr, [x0]
    LEA x0, tc_plan_below_floor
    str xzr, [x0]

    bl render_plan_degeneracy_check
    bl render_plan_columns
    bl render_plan_rank
    bl render_plan_exclusions
    bl render_plan_cache_snapshot
    bl render_build_header_rows
    bl render_choose_limit
    bl render_plan_split_display
    EPILOGUE 0
    ret

// ============================================================================
// render_plan_degeneracy_check — exit 1 when a state filter meets state columns.
// ============================================================================
    .p2align 2
render_plan_degeneracy_check:
    PROLOGUE 4
    LEA x19, tc_window
    ldr x20, [x19, #TC_W_STATE_FILTER]
    cbz x20, .Lpdeg_done
    LEA x21, tc_opts
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
    LEA x0, render_errbuf
    mov w1, #'-'
    strb w1, [x0], #1
    mov w1, #'-'
    strb w1, [x0], #1
    LEA x1, state_names
    sub x2, x20, #1
    ldr x1, [x1, x2, lsl #3]
    bl render_str_cat
    sub x0, x0, #1                    // overwrite the trailing NUL
    LEA x1, s_degen_mid
    bl render_str_cat
    LEA x0, render_errbuf
    bl tc_report_fail
.Lpdeg_done:
    EPILOGUE 4
    ret

// ============================================================================
// render_plan_columns — copy TC_O_COLUMNS, sort and header mode; compute shares_shown.
// ============================================================================
    .p2align 2
render_plan_columns:
    PROLOGUE 5
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_COLUMN_COUNT]
    LEA x21, tc_plan_columns
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
    EPILOGUE 5
    ret

// ============================================================================
// render_plan_rank — walk the user table into the reported array, apply the share
// floor, compute share sort keys, qsort, and join 'unknown' when --by-state
// sees any.
// ============================================================================
    .p2align 2
render_plan_rank:
    PROLOGUE 5
    // pass 1: counts
    LEA x19, tc_users
    ldr x20, [x19, #TC_US_COUNT]
    ldr x21, [x19, #TC_US_ENTRIES]
    LEA x22, tc_window
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
    LEA x28, tc_plan_reported_n
    str x24, [x28]
    LEA x28, tc_plan_in_range
    str x25, [x28]
    LEA x28, tc_plan_excl_appeared
    str x26, [x28]
    LEA x28, tc_plan_excl_msgs
    str x27, [x28]
    // allocate
    cbz x24, .Lpr_alloc_done
    mov x0, #ROW_SZ
    mul x0, x24, x0
    bl malloc
    cbz x0, .Lpr_oom
    LEA x28, tc_plan_reported
    str x0, [x28]
.Lpr_alloc_done:
    // pass 2: fill
    LEA x19, tc_users
    ldr x20, [x19, #TC_US_COUNT]
    ldr x21, [x19, #TC_US_ENTRIES]
    LEA x22, tc_window
    ldr x23, [x22, #TC_W_THRESHOLD]
    LEA x24, tc_plan_reported
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
    LEA x28, tc_plan_reported_n
    str x25, [x28]
    // ---- share floor -----------------------------------------------------
    LEA x19, tc_plan_shares_shown
    ldr x19, [x19]
    LEA x20, tc_opts
    ldr x20, [x20, #TC_O_SHARE_FLOOR]
    LEA x21, tc_plan_reported
    ldr x21, [x21]
    LEA x22, tc_plan_reported_n
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
    LEA x24, tc_plan_share_floor
    str x20, [x24]
    LEA x25, tc_plan_below_floor
    sub x26, x22, x23
    str x26, [x25]
    LEA x25, tc_plan_reported_n
    str x23, [x25]
    mov x22, x23
    b .Lpr_keys
.Lpr_floor_none:
    LEA x24, tc_plan_share_floor
    str xzr, [x24]
.Lpr_keys:
    // share sort keys (fixed point 1000*state/count)
    LEA x19, tc_plan_sort
    ldr x20, [x19]
    cmp x20, #TC_M_OFFLINE_SHARE
    b.eq .Lpr_keys_do
    cmp x20, #TC_M_LIVE_SHARE
    b.ne .Lpr_sort
.Lpr_keys_do:
    LEA x21, tc_plan_reported
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
    LEA x0, tc_plan_reported
    ldr x0, [x0]
    mov x1, x22
    mov x2, #ROW_SZ
    LEA x3, render_cmp
    bl qsort
.Lpr_unknown:
    // unknown joins when --by-state and any reported row has unknown > 0
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_FLAGS]
    tst x20, #TC_F_BY_STATE
    b.eq .Lpr_done
    LEA x21, tc_plan_reported
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
    LEA x24, tc_plan_col_count
    ldr x25, [x24]
    LEA x26, tc_plan_columns
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
    EPILOGUE 5
    ret
.Lpr_oom:
    LEA x0, s_oom
    bl tc_report_fail

// ============================================================================
// render_plan_exclusions — sorted exclusion logins + the ", "-joined sources.
// ============================================================================
    .p2align 2
render_plan_exclusions:
    PROLOGUE 3
    LEA x19, tc_excl_set
    ldr x20, [x19]                   // exclusion count
    LEA x21, tc_plan_excl_names_n
    str x20, [x21]
    cbz x20, .Lpex_sources
    mov x0, #NAME_SZ
    mul x0, x20, x0
    bl malloc
    cbz x0, .Lpex_oom
    LEA x21, tc_plan_excl_names
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
    LEA x0, tc_plan_excl_names
    ldr x0, [x0]
    mov x1, x20
    mov x2, #NAME_SZ
    LEA x3, render_excl_name_cmp
    bl qsort
.Lpex_sources:
    // ", "-join the exclusion source records into the arena
    LEA x19, tc_excl_src_count
    ldr x20, [x19]
    bl render_arena_get
    mov x21, x0                      // dst start
    mov x22, x0                      // cursor
    mov x23, #0                      // i
    LEA x24, tc_excl_sources
.Lpex_join:
    cmp x23, x20
    b.ge .Lpex_join_done
    cbnz x23, .Lpex_join_sep
    b .Lpex_join_src
.Lpex_join_sep:
    // Fix: render_str_cat copies the source's trailing NUL, so the ", "
    // separator NUL-terminated the joined source early and every source after
    // the first was truncated out of the header (observed: an exclude line
    // rendered as "[--exclude, ]" instead of
    // "[--exclude, --exclude-broadcaster]").  render_str_cat_n copies exactly the
    // separator without a NUL, matching the .Lbhr_excl_preview join below.
    mov x0, x22
    LEA x1, s_comma
    mov x2, #2
    bl render_str_cat_n
    mov x22, x0
.Lpex_join_src:
    mov x0, #TC_EX_SRC_ENTRY_SZ
    mul x0, x23, x0
    add x0, x24, x0
    ldr x1, [x0]
    ldr x2, [x0, #8]
    mov x0, x22
    bl render_str_cat_n
    mov x22, x0
    add x23, x23, #1
    b .Lpex_join
.Lpex_join_done:
    mov w0, #0
    strb w0, [x22]
    add x0, x22, #1
    bl render_arena_set_end
    cbz x20, .Lpex_join_skip         // no source records: keep src_join = 0
    LEA x0, tc_plan_src_join
    str x21, [x0]
.Lpex_join_skip:
    EPILOGUE 3
    ret
.Lpex_oom:
    LEA x0, s_oom
    bl tc_report_fail

// render_excl_name_cmp — qsort comparator for 26-byte login records
    .p2align 2
render_excl_name_cmp:
    PROLOGUE 0
    bl strcmp
    EPILOGUE 0
    ret

// ============================================================================
// render_cmp — qsort comparator for reported rows: metric desc, login asc.
// ============================================================================
    .p2align 2
render_cmp:
    PROLOGUE 2
    mov x19, x0
    mov x20, x1
    LEA x21, tc_plan_sort
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
    EPILOGUE 2
    ret

// ============================================================================
// render_plan_cache_snapshot — call tc_cache_status once and remember the results.
// ============================================================================
    .p2align 2
render_plan_cache_snapshot:
    PROLOGUE 3
    LEA x0, tc_opts
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
    LEA x1, tc_plan_cache_used
    str x19, [x1]
    str x20, [x1, #8]
    str x21, [x1, #16]
    str x22, [x1, #24]
    str x23, [x1, #32]
    str x24, [x1, #40]
    b .Lpcs_done
.Lpcs_off:
    LEA x1, tc_plan_cache_used
    str xzr, [x1]
    str xzr, [x1, #8]
    str xzr, [x1, #16]
    str xzr, [x1, #24]
    str xzr, [x1, #32]
    str xzr, [x1, #40]
.Lpcs_done:
    EPILOGUE 3
    ret

// ============================================================================
// render_build_header_rows — the provenance table (Python provenance_rows), in
// order: one render_hdr_row_* routine per row.  The rows are independent (no
// register state crosses from one to the next); each is self-contained.
// ============================================================================
    .p2align 2
render_build_header_rows:
    PROLOGUE 0
    bl render_hdr_row_channel
    bl render_hdr_row_logs_dir
    bl render_hdr_row_begin
    bl render_hdr_row_end
    bl render_hdr_row_threshold
    bl render_hdr_row_users
    bl render_hdr_row_state
    bl render_hdr_row_exclude
    bl render_hdr_row_columns
    bl render_hdr_row_sort
    bl render_hdr_row_share_floor
    bl render_hdr_row_config
    bl render_hdr_row_cache
    bl render_hdr_row_unreadable
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_channel -- channel
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_channel:
    PROLOGUE 2
    LEA x19, s_label_channel
    bl tc_channel_name
    mov x20, x0
    mov x0, #TC_SET_CHANNEL
    bl tc_setting_src_str
    mov x21, x0
    mov x0, x19
    mov x1, x20
    mov x2, x21
    mov x3, x20
    bl render_hdr_add
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_logs_dir -- logs dir
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_logs_dir:
    PROLOGUE 2
    LEA x19, s_label_logs_dir
    LEA_OFF x0, tc_opts, TC_O_LOGS_DIR
    bl tc_shorten_path
    mov x20, x0                       // shortened (scratch — copy now)
    bl render_arena_get
    mov x21, x0
    mov x0, x21
    mov x1, x20
    bl render_str_cat
    bl render_arena_set_end
    mov x0, #TC_SET_LOGS_DIR
    bl tc_setting_src_str
    mov x22, x0
    mov x0, x19
    mov x1, x21
    mov x2, x22
    mov x3, #0
    bl render_hdr_add
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_begin -- begin
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_begin:
    PROLOGUE 4
    LEA x19, s_label_begin
    LEA x20, tc_window
    ldr x21, [x20, #TC_W_BEGIN_YMD]
    ldr x22, [x20, #TC_W_BEGIN_SOD]
    bl render_arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x21
    mov x2, x22
    mov w3, #' '
    bl render_fmt_datetime
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl render_arena_set_end
    ldr x24, [x20, #TC_W_START_SRC]   // source ptr
    bl render_arena_get
    mov x25, x0
    mov x0, x25
    mov x1, x21                       // begin ymd
    mov x2, x22                       // begin sod
    bl render_fmt_window_span
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl render_arena_set_end
    mov x0, x19
    mov x1, x23
    mov x2, x24
    mov x3, x25
    bl render_hdr_add
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_end -- end
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_end:
    PROLOGUE 3
    LEA x19, s_label_end
    LEA x20, tc_window
    ldr x21, [x20, #TC_W_END_YMD]
    ldr x22, [x20, #TC_W_END_SOD]
    bl render_arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x21
    mov x2, x22
    mov w3, #' '
    bl render_fmt_datetime
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl render_arena_set_end
    mov x0, #TC_SET_END
    bl tc_setting_src_str
    mov x24, x0
    mov x0, x19
    mov x1, x23
    mov x2, x24
    mov x3, #0
    bl render_hdr_add
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_threshold -- threshold
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_threshold:
    PROLOGUE 3
    LEA x19, s_label_threshold
    LEA x20, tc_window
    ldr x21, [x20, #TC_W_THRESHOLD]
    bl render_arena_get
    mov x22, x0
    mov x0, x22
    LEA x1, s_ge
    bl render_str_cat
    sub x0, x0, #1                    // back to before the NUL
    mov x1, x21
    bl render_fmt_u64_plain
    LEA x1, s_msgs
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    bl render_arena_get
    mov x23, x0
    mov x0, x23
    LEA x1, s_ge_only
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x21
    bl render_fmt_u64_plain
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl render_arena_set_end
    mov x0, #TC_SET_MIN_COUNT
    bl tc_setting_src_str
    mov x24, x0
    mov x0, x19
    mov x1, x22
    mov x2, x24
    mov x3, x23
    bl render_hdr_add
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_users -- users
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_users:
    PROLOGUE 5
    LEA x19, tc_window
    ldr x20, [x19, #TC_W_USERS_WIDTH]
    cbz x20, .Lbhr_users_ret
    LEA x19, s_label_users
    LEA x20, tc_window
    ldr x21, [x20, #TC_W_USERS_REQ]
    ldr x22, [x20, #TC_W_USERS_FOUND]
    ldr x23, [x20, #TC_W_USERS_WIDTH]
    bl render_arena_get
    mov x24, x0
    mov x0, x24
    mov x1, x21
    bl render_fmt_u64_commas
    LEA x1, s_asked_for
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x22
    bl render_fmt_u64_commas
    LEA x1, s_found_over
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x23
    bl render_fmt_human_duration
    mov x0, x0
    bl render_arena_set_end
    // source = policy.source + " " + policy value
    bl render_arena_get
    mov x25, x0
    mov x0, #TC_SET_USERS_POLICY
    bl tc_setting_src_str
    mov x1, x0
    mov x0, x25
    bl render_str_cat
    sub x0, x0, #1
    mov w1, #' '
    strb w1, [x0], #1
    LEA x1, policy_names
    LEA x2, tc_opts
    ldr x2, [x2, #TC_O_USERS_POLICY]
    ldr x1, [x1, x2, lsl #3]
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    // compact = "M/N users" when found != requested
    ldr x26, [x20, #TC_W_USERS_REQ]
    ldr x27, [x20, #TC_W_USERS_FOUND]
    cmp x26, x27
    b.eq .Lbhr_users_noc
    bl render_arena_get
    mov x28, x0
    mov x0, x28
    mov x1, x27
    bl render_fmt_u64_commas
    LEA x1, s_slash
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x26
    bl render_fmt_u64_commas
    LEA x1, s_users_c
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbhr_users_add
.Lbhr_users_noc:
    mov x28, #0
.Lbhr_users_add:
    mov x0, x19
    mov x1, x24
    mov x2, x25
    mov x3, x28
    bl render_hdr_add
.Lbhr_users_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_state -- state
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_state:
    PROLOGUE 5
    LEA x19, tc_tally
    ldr x20, [x19, #TC_T_STATES + 0]
    ldr x21, [x19, #TC_T_STATES + 8]
    ldr x22, [x19, #TC_T_STATES + 16]
    orr x23, x20, x21
    orr x23, x23, x22
    cbz x23, .Lbhr_state_ret
    LEA x19, s_label_state
    LEA x20, tc_tally
    // value = nonzero states "name N" joined " / "  (commas)
    bl render_arena_get
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
    LEA x1, s_of_slash
    bl render_str_cat
    sub x0, x0, #1
    mov x22, x0
.Lbhr_state_cell:
    LEA x1, state_names
    ldr x1, [x1, x24, lsl #3]
    mov x0, x22
    bl render_str_cat
    sub x0, x0, #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x22, x0
    mov x1, x26
    bl render_fmt_u64_commas
    mov x22, x0
    mov x23, #1
.Lbhr_state_next:
    add x24, x24, #1
    b .Lbhr_state_loop
.Lbhr_state_val_done:
    mov w0, #0
    strb w0, [x22]
    add x0, x22, #1
    bl render_arena_set_end
    // source (filter id rides in x25; x21 keeps the value start)
    LEA x20, tc_window
    ldr x25, [x20, #TC_W_STATE_FILTER]
    bl render_arena_get
    mov x22, x0                       // source start
    cbz x25, .Lbhr_state_nofilter
    mov x0, #TC_SET_STATE
    bl tc_setting_src_str
    mov x1, x0
    mov x0, x22
    bl render_str_cat
    sub x0, x0, #1
    LEA x1, s_keeps
    bl render_str_cat
    sub x0, x0, #1
    LEA x1, state_names
    sub x2, x25, #1
    ldr x1, [x1, x2, lsl #3]
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbhr_state_src_done
.Lbhr_state_nofilter:
    mov x0, x22
    LEA x1, s_not_filtered
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
.Lbhr_state_src_done:
    // compact: "NAME only" when filtered, else "name N" joined " "
    bl render_arena_get
    mov x23, x0                       // compact start
    cbz x25, .Lbhr_state_comp_split
    LEA x1, state_names
    sub x2, x25, #1
    ldr x1, [x1, x2, lsl #3]
    mov x0, x23
    bl render_str_cat
    sub x0, x0, #1
    LEA x1, s_only
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbhr_state_add
.Lbhr_state_comp_split:
    mov x24, x0                       // cursor
    mov x25, #0                       // first
    mov x26, #0                       // state idx
    LEA x27, tc_tally
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
    LEA x1, state_names
    ldr x1, [x1, x26, lsl #3]
    mov x0, x24
    bl render_str_cat
    sub x0, x0, #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x24, x0
    mov x1, x28
    bl render_fmt_u64_commas
    mov x24, x0
    mov x25, #1
.Lbhr_state_comp_next:
    add x26, x26, #1
    b .Lbhr_state_comp_loop
.Lbhr_state_comp_done:
    mov w0, #0
    strb w0, [x24]
    add x0, x24, #1
    bl render_arena_set_end
.Lbhr_state_add:
    LEA x19, s_label_state
    mov x0, x19
    mov x1, x21
    mov x2, x22
    mov x3, x23
    bl render_hdr_add
.Lbhr_state_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_exclude -- exclude
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_exclude:
    PROLOGUE 4
    LEA x19, tc_plan_excl_names_n
    ldr x20, [x19]                    // n names
    cbz x20, .Lbhr_exclude_ret
    LEA x19, s_label_exclude
    LEA x20, tc_plan_excl_names_n
    ldr x20, [x20]                    // N
    LEA x21, tc_plan_excl_appeared
    ldr x21, [x21]                    // M appeared
    // value: "N login(s), M in range: preview"
    bl render_arena_get
    mov x22, x0
    mov x0, x22
    mov x1, x20
    bl render_fmt_u64_plain
    LEA x1, s_login_s
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x21
    bl render_fmt_u64_plain
    LEA x1, s_in_range_colon
    bl render_str_cat
    sub x0, x0, #1                    // overwrite the trailing NUL
    // preview: first 3 names joined ", ", then ", +K more" if > 3
    LEA x23, tc_plan_excl_names
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
    LEA x1, s_comma
    mov x2, #2
    bl render_str_cat_n
.Lbhr_excl_name:
    mov x2, #NAME_SZ
    mul x2, x24, x2
    add x1, x23, x2
    bl render_str_cat
    mov x25, #1
    add x24, x24, #1
    b .Lbhr_excl_preview
.Lbhr_excl_preview_done:
    cmp x20, #3
    b.le .Lbhr_excl_val_done
    sub x0, x0, #1                    // overwrite the trailing NUL (render_str_cat
                                      // returns the cursor past it)
    LEA x1, s_comma_more
    bl render_str_cat
    sub x0, x0, #1
    sub x1, x20, #3
    bl render_fmt_u64_plain
    LEA x1, s_more
    bl render_str_cat
.Lbhr_excl_val_done:
    mov x0, x0
    bl render_arena_set_end
    // source = joined sources
    LEA x24, tc_plan_src_join
    ldr x24, [x24]
    // compact = "-M excl" when appeared
    cbz x21, .Lbhr_excl_noc
    bl render_arena_get
    mov x25, x0
    mov w1, #'-'
    strb w1, [x25]
    mov x0, x25
    add x0, x0, #1
    mov x1, x21
    bl render_fmt_u64_plain
    LEA x1, s_excl
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbhr_excl_add
.Lbhr_excl_noc:
    mov x25, #0
.Lbhr_excl_add:
    mov x0, x19
    mov x1, x22
    mov x2, x24
    mov x3, x25
    bl render_hdr_add
.Lbhr_exclude_ret:
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_columns -- columns
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_columns:
    PROLOGUE 4
    LEA x19, tc_plan_col_count
    ldr x20, [x19]
    cbz x20, .Lbhr_columns_ret
    LEA x19, s_label_columns
    bl render_arena_get
    mov x21, x0
    mov x0, x21
    LEA x1, s_m_count
    bl render_str_cat
    sub x0, x0, #1
    LEA x22, tc_plan_columns
    mov x23, #0
.Lbhr_col_loop:
    cmp x23, x20
    b.ge .Lbhr_col_done
    LEA x1, s_comma
    bl render_str_cat
    sub x0, x0, #1
    ldr x24, [x22, x23, lsl #3]
    LEA x1, metric_names
    ldr x1, [x1, x24, lsl #3]
    bl render_str_cat
    sub x0, x0, #1
    add x23, x23, #1
    b .Lbhr_col_loop
.Lbhr_col_done:
    mov w1, #0
    strb w1, [x0]
    add x0, x0, #1
    bl render_arena_set_end
    // source ptr: tc_cli.S composes it into TC_O_COLUMNS_SRC_BUF but its
    // TC_O_COLUMNS_SRC_PTR store clobbers x1 (cli_opts_off); point at the
    // composed buffer directly.
    LEA x24, tc_opts
    movz x25, #TC_O_COLUMNS_SRC_BUF
    add x25, x24, x25
    mov x0, x19
    mov x1, x21
    mov x2, x25
    mov x3, #0
    bl render_hdr_add
.Lbhr_columns_ret:
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_sort -- sort
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_sort:
    PROLOGUE 3
    LEA x19, tc_plan_sort
    ldr x20, [x19]
    cmp x20, #TC_M_COUNT
    b.eq .Lbhr_sort_ret
    LEA x19, s_label_sort
    LEA x21, metric_names
    ldr x21, [x21, x20, lsl #3]
    mov x0, #TC_SET_SORT
    bl tc_setting_src_str
    mov x22, x0
    // compact "by <name>"
    bl render_arena_get
    mov x23, x0
    mov x0, x23
    LEA x1, s_by
    bl render_str_cat
    sub x0, x0, #1
    LEA x1, metric_names
    ldr x1, [x1, x20, lsl #3]
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    mov x0, x19
    mov x1, x21
    mov x2, x22
    mov x3, x23
    bl render_hdr_add
.Lbhr_sort_ret:
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_share_floor -- share floor
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_share_floor:
    PROLOGUE 5
    LEA x19, tc_plan_share_floor
    ldr x20, [x19]                    // the floor that acted
    // asked = source != TC_SRC_DEFAULT_BUILTIN
    LEA x21, tc_opts
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
    LEA x19, s_label_share_floor
    bl render_arena_get
    mov x24, x0
    mov x0, x24
    LEA x1, s_ge
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x20
    bl render_fmt_u64_commas
    LEA x1, s_floor_msgs
    bl render_str_cat
    LEA x25, tc_plan_below_floor
    ldr x25, [x25]
    sub x0, x0, #1
    mov x1, x25
    bl render_fmt_u64_commas
    LEA x1, s_floor_dropped
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    // compact "floor >=N, -M"
    bl render_arena_get
    mov x26, x0
    mov x0, x26
    LEA x1, s_floor_compact
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x20
    bl render_fmt_u64_commas
    LEA x1, s_floor_minus
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x25
    bl render_fmt_u64_commas
    mov w3, #0
    strb w3, [x0]
    add x0, x0, #1
    bl render_arena_set_end
    b .Lbhr_sf_add
.Lbhr_sf_not_acted:
    cbz x23, .Lbhr_sf_skip            // not acted and not asked -> no row
    LEA x27, tc_plan_shares_shown
    ldr x27, [x27]
    cbz x27, .Lbhr_sf_noshare
    // shares shown but floor 0: "disabled ..."
    LEA x19, s_label_share_floor
    bl render_arena_get
    mov x24, x0
    mov x0, x24
    LEA x1, s_floor_disabled
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    mov x26, x0                       // compact ptr placeholder
    bl render_arena_get
    mov x26, x0
    mov x0, x26
    LEA x1, s_floor_off
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbhr_sf_add
.Lbhr_sf_noshare:
    // no share shown/sorted: "not applied -- ..."
    LEA x19, s_label_share_floor
    bl render_arena_get
    mov x24, x0
    mov x0, x24
    LEA x1, s_floor_not
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    bl render_arena_get
    mov x26, x0
    mov x0, x26
    LEA x1, s_floor_unused
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbhr_sf_add
.Lbhr_sf_skip:
    b .Lbhr_share_floor_ret
.Lbhr_sf_add:
    mov x0, #TC_SET_SHARE_FLOOR
    bl tc_setting_src_str
    mov x25, x0
    mov x0, x19
    mov x1, x24
    mov x2, x25
    mov x3, x26
    bl render_hdr_add
.Lbhr_share_floor_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_config -- config
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_config:
    PROLOGUE 2
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_CONFIG_LOADED]
    cbz x20, .Lbhr_config_ret
    LEA x19, s_label_config
    add x0, x19, #0
    LEA_OFF x20, tc_opts, TC_O_CONFIG_PATH
    mov x0, x20
    bl tc_shorten_path
    mov x20, x0
    bl render_arena_get
    mov x21, x0
    mov x0, x21
    mov x1, x20
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    mov x0, x19
    mov x1, x21
    LEA x2, s_loaded
    mov x3, #0
    bl render_hdr_add
.Lbhr_config_ret:
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_cache -- cache
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_cache:
    PROLOGUE 5
    LEA x19, tc_plan_cache_used
    ldr x20, [x19]                    // used
    ldr x21, [x19, #8]                // reused
    ldr x22, [x19, #16]               // parsed
    ldr x23, [x19, #24]               // problem
    ldr x24, [x19, #32]               // rebuilt
    ldr x25, [x19, #40]               // path
    cbnz x20, .Lbhr_cache_used
    cbz x23, .Lbhr_cache_ret         // not used, no problem -> no row
    // unavailable -- <problem>
    LEA x19, s_label_cache
    bl render_arena_get
    mov x26, x0
    mov x0, x26
    LEA x1, s_unavailable
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x23
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    mov x0, x19
    mov x1, x26
    LEA x2, s_every_file
    LEA x3, s_no_cache_c
    bl render_hdr_add
    b .Lbhr_cache_ret
.Lbhr_cache_used:
    LEA x19, s_label_cache
    bl render_arena_get
    mov x26, x0
    mov x0, x26
    mov x1, x21
    bl render_fmt_u64_commas
    LEA x1, s_day_s_reused
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x22
    bl render_fmt_u64_commas
    LEA x1, s_parsed
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    // source
    cbnz x24, .Lbhr_cache_rebuilt
    cbnz x25, .Lbhr_cache_path
    LEA x27, s_rollup_db
    b .Lbhr_cache_src_done
.Lbhr_cache_rebuilt:
    bl render_arena_get
    mov x27, x0
    mov x0, x27
    LEA x1, s_rebuilt
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x24
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbhr_cache_src_done
.Lbhr_cache_path:
    mov x0, x25
    bl tc_shorten_path
    mov x27, x0
    bl render_arena_get
    mov x28, x0
    mov x0, x28
    mov x1, x27
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    mov x27, x28
.Lbhr_cache_src_done:
    mov x0, x19
    mov x1, x26
    mov x2, x27
    mov x3, #0
    bl render_hdr_add
.Lbhr_cache_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// render_hdr_row_unreadable -- unreadable
// ----------------------------------------------------------------------------
    .p2align 2
render_hdr_row_unreadable:
    PROLOGUE 3
    LEA x19, tc_tally
    ldr x20, [x19, #TC_T_UNR_COUNT]
    cbz x20, .Lbhr_unreadable_ret
    LEA x19, s_label_unreadable
    LEA x20, tc_tally
    ldr x20, [x20, #TC_T_UNR_COUNT]
    bl render_arena_get
    mov x21, x0
    mov x0, x21
    mov x1, x20
    bl render_fmt_u64_plain
    LEA x1, s_file_s_skipped
    bl render_str_cat
    sub x0, x0, #1                    // overwrite the trailing NUL
    // first 2 names joined ", ", ", +K more" if > 2
    LEA_OFF x22, tc_tally, TC_T_UNR_ENTRIES
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
    LEA x1, s_comma
    mov x2, #2
    bl render_str_cat_n
.Lbhr_unr_name:
    mov x2, #TC_T_UNR_ENTRY_SZ
    mul x2, x23, x2
    add x1, x22, x2
    bl render_str_cat
    mov x24, #1
    add x23, x23, #1
    b .Lbhr_unr_preview
.Lbhr_unr_preview_done:
    cmp x20, #2
    b.le .Lbhr_unr_reason
    sub x0, x0, #1                    // overwrite the trailing NUL (render_str_cat
                                      // returns the cursor past it)
    LEA x1, s_comma_more
    bl render_str_cat
    sub x0, x0, #1
    sub x1, x20, #2
    bl render_fmt_u64_plain
    LEA x1, s_more
    bl render_str_cat
.Lbhr_unr_reason:
    sub x0, x0, #1                    // overwrite the trailing NUL
    mov w1, #' '
    strb w1, [x0], #1
    mov w1, #'('
    strb w1, [x0], #1
    LEA_OFF x22, tc_tally, TC_T_UNR_ENTRIES
    add x1, x22, #TC_T_UNR_NAME_SZ     // first reason
    bl render_str_cat
    sub x0, x0, #1
    mov w1, #')'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    add x0, x0, #1
    bl render_arena_set_end
    // compact "N unread"
    bl render_arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x20
    bl render_fmt_u64_plain
    LEA x1, s_unread
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    mov x0, x19
    mov x1, x21
    LEA x2, s_not_counted
    mov x3, x23
    bl render_hdr_add
.Lbhr_unreadable_ret:
    EPILOGUE 3
    ret

// ============================================================================
// render_fmt_window_span(dst) — the compact span ("MM-DD HH:MM..now", same-date, or
// "YYYY-MM-DD..YYYY-MM-DD"); needs the window already loaded by the caller in
// x1=begin ymd, x2=begin sod (uses tc_window for the end).
// ============================================================================
    .p2align 2
render_fmt_window_span:
    PROLOGUE 2
    mov x19, x0                       // dst
    mov x20, x1                       // begin ymd
    mov x21, x2                       // begin sod
    // end defaulted?
    LEA x22, tc_opts
    ldr x22, [x22, #TC_O_SRC + TC_SET_END*8]
    cmp x22, #TC_SRC_DEFAULT_NOW
    b.eq .Lfws_now
    LEA x22, tc_window
    ldr x22, [x22, #TC_W_END_YMD]
    cmp x20, x22
    b.eq .Lfws_same
    // different dates: "YYYY-MM-DD..YYYY-MM-DD"
    mov x0, x19
    mov x1, x20
    bl render_fmt_ymd
    LEA x1, s_dotdot
    bl render_str_cat
    sub x0, x0, #1
    LEA x22, tc_window
    ldr x1, [x22, #TC_W_END_YMD]
    bl render_fmt_ymd
    b .Lfws_done
.Lfws_same:
    // "MM-DD HH:MM..HH:MM"
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl render_fmt_mmdd_hhmm
    LEA x1, s_dotdot
    bl render_str_cat
    sub x0, x0, #1
    LEA x22, tc_window
    ldr x1, [x22, #TC_W_END_SOD]
    bl render_fmt_hhmm
    b .Lfws_done
.Lfws_now:
    // "MM-DD HH:MM..now"
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl render_fmt_mmdd_hhmm
    LEA x1, s_now
    bl render_str_cat
    sub x0, x0, #1
.Lfws_done:
    EPILOGUE 2
    ret

// ============================================================================
// render_choose_limit — Python render_choose_limit: --top, then --json unlimited, then the
// terminal height.
// ============================================================================
    .p2align 2
render_choose_limit:
    PROLOGUE 3
    // top given?
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_SRC + TC_SET_TOP*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Lcl_json
    ldr x21, [x19, #TC_O_TOP]
    LEA x22, tc_plan_limit
    str x21, [x22]
    mov x0, x20                       // x20 is already a TC_SRC_* id
    bl tc_source_str
    LEA x22, tc_plan_limit_src
    str x0, [x22]
    b .Lcl_done
.Lcl_json:
    ldr x21, [x19, #TC_O_FLAGS]
    tst x21, #TC_F_JSON
    b.eq .Lcl_term
    LEA x22, tc_plan_limit
    str xzr, [x22]
    LEA x22, tc_plan_limit_src
    LEA x0, s_unlimited_json
    str x0, [x22]
    b .Lcl_done
.Lcl_term:
    // reserved
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_HEADER_MODE]
    LEA x21, tc_plan_hdr_count
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
    LEA x22, tc_plan_limit
    str x23, [x22]
    LEA x22, tc_plan_limit_src
    LEA x0, s_terminal_height
    str x0, [x22]
    b .Lcl_done
.Lcl_term_unlimited:
    LEA x22, tc_plan_limit
    str xzr, [x22]
    LEA x22, tc_plan_limit_src
    LEA x0, s_terminal_height
    str x0, [x22]
.Lcl_done:
    EPILOGUE 3
    ret

// ============================================================================
// render_plan_split_display — displayed/hidden split, message sums, and the top row.
// ============================================================================
    .p2align 2
render_plan_split_display:
    PROLOGUE 5
    LEA x19, tc_plan_reported_n
    ldr x20, [x19]                     // reported_n
    LEA x21, tc_plan_limit
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
    LEA x24, tc_plan_displayed_n
    str x23, [x24]
    LEA x24, tc_plan_hidden_n
    sub x25, x20, x23
    str x25, [x24]
    // message sums
    LEA x26, tc_plan_reported
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
    LEA x28, tc_plan_msgs_shown
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
    LEA x28, tc_plan_msgs_hidden
    str x27, [x28]
    // top row
    cbz x22, .Lpsd_done
    cbz x20, .Lpsd_done
    bl render_build_top_row
.Lpsd_done:
    EPILOGUE 5
    ret

// ============================================================================
// render_build_top_row — "N row(s)[, M hidden]" with the limit source; compact
// "D/R rows" when hidden.
// ============================================================================
    .p2align 2
render_build_top_row:
    PROLOGUE 4
    LEA x19, tc_plan_limit
    ldr x19, [x19]                     // limit
    LEA x20, tc_plan_hidden_n
    ldr x20, [x20]                     // hidden
    LEA x21, tc_plan_displayed_n
    ldr x21, [x21]                     // displayed
    LEA x22, tc_plan_reported_n
    ldr x22, [x22]                     // reported
    bl render_arena_get
    mov x23, x0
    mov x0, x23
    mov x1, x19
    bl render_fmt_u64_commas
    LEA x1, s_row_s
    bl render_str_cat
    cbz x20, .Lbtr_val_done
    sub x0, x0, #1                    // overwrite the trailing NUL
    LEA x1, s_comma
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x20
    bl render_fmt_u64_commas
    LEA x1, s_hidden
    bl render_str_cat
.Lbtr_val_done:
    mov x0, x0
    bl render_arena_set_end
    // source
    LEA x24, tc_plan_limit_src
    ldr x24, [x24]
    // compact "D/R rows" when hidden
    cbz x20, .Lbtr_noc
    bl render_arena_get
    mov x25, x0
    mov x0, x25
    mov x1, x21
    bl render_fmt_u64_commas
    LEA x1, s_slash
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x22
    bl render_fmt_u64_commas
    LEA x1, s_rows
    bl render_str_cat
    mov x0, x0
    bl render_arena_set_end
    b .Lbtr_add
.Lbtr_noc:
    mov x25, #0
.Lbtr_add:
    LEA x0, s_label_top
    mov x1, x23
    mov x2, x24
    mov x3, x25
    bl render_hdr_add
    EPILOGUE 4
    ret

// ============================================================================
// tc_render_text — the one-shot text report (Python render_text).
// ============================================================================
    .p2align 2
    .global tc_render_text
    FUNC_TYPE(tc_render_text)
tc_render_text:
    PROLOGUE 2
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_HEADER_MODE]
    // Fix: --header none used to jump straight to the table, skipping
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
    LEA x19, tc_plan_reported_n
    ldr x20, [x19]
    cbnz x20, .Lrt_table
    // empty report
    bl render_line_zero
    LEA x19, tc_tally
    ldr x20, [x19, #TC_T_MESSAGES]
    LEA x21, render_line
    mov x0, x21
    LEA x1, s_no_users
    bl render_str_cat
    sub x0, x0, #1
    mov x1, x20
    bl render_fmt_u64_plain
    LEA x1, s_msg_range
    bl render_str_cat
    sub x0, x0, #1
    LEA x1, s_period
    bl render_str_cat
    mov x0, x21
    bl render_line_puts
    LEA x19, tc_plan_excl_appeared
    ldr x20, [x19]
    cbz x20, .Lrt_done
    bl render_emit_excluded_line
    b .Lrt_done
.Lrt_table:
    bl render_table
.Lrt_done:
    EPILOGUE 2
    ret

// ============================================================================
// render_full_header — the provenance block, aligned, then the files line.
// ============================================================================
    .p2align 2
render_full_header:
    PROLOGUE 4
    // pass 1: widths
    LEA x19, tc_plan_hdr_count
    ldr x20, [x19]                     // row count
    mov x21, #0                        // w0 (max label+1)
    mov x22, #0                        // w1 (max value)
    mov x23, #0
.Lrfh_w_loop:
    cmp x23, x20
    b.ge .Lrfh_w_done
    LEA x24, tc_plan_rows
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
    LEA x24, tc_plan_rows
    mov x25, #HDR_DESC_SZ
    mul x25, x23, x25
    add x24, x24, x25
    ldr x0, [x24]                      // label
    ldr x1, [x24, #8]                  // value
    ldr x2, [x24, #16]                 // source
    mov x3, x21                        // w0
    mov x4, x22                        // w1
    bl render_emit_header_line
    add x23, x23, #1
    b .Lrfh_line_loop
.Lrfh_ret:
.Lrfh_lines_done:
    // files line
    LEA x0, s_label_files
    LEA x1, tc_tally
    ldr x1, [x1, #TC_T_FILES]
    mov x2, x21
    mov x3, x22
    bl render_emit_files_line
    // blank line
    bl render_line_blank
    EPILOGUE 4
    ret

// render_emit_header_line(label, value, source, w0, w1) — "label:  value  [source]"
    .p2align 2
render_emit_header_line:
    PROLOGUE 4
    mov x19, x0                        // label
    mov x20, x1                        // value
    mov x21, x2                        // source
    mov x22, x3                        // w0
    mov x23, x4                        // w1
    bl render_line_zero
    LEA x24, render_line
    // label + ':'
    mov x0, x24
    mov x1, x19
    bl render_str_cat
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
    bl render_str_cat
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
    bl render_str_cat
    sub x0, x0, #1
    mov w1, #']'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    mov x0, x24
    bl render_line_puts
    EPILOGUE 4
    ret

// render_emit_files_line(label, count, w0, w1) — "files:  N log file(s) in range"
// (the value is unpadded: align_row rstrips the trailing padding)
    .p2align 2
render_emit_files_line:
    PROLOGUE 3
    mov x19, x0                        // "files"
    mov x20, x1                        // count
    mov x21, x2                        // w0
    bl render_line_zero
    LEA x22, render_line
    mov x0, x22
    mov x1, x19
    bl render_str_cat
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
    bl render_fmt_u64_plain
    LEA x1, s_files_val
    bl render_str_cat
    mov x0, x22
    bl render_line_puts
    EPILOGUE 3
    ret

// ============================================================================
// render_compact_header — " · "-joined compact cells, then a blank line.
// ============================================================================
    .p2align 2
render_compact_header:
    PROLOGUE 4
    bl render_compact_zero
    LEA x19, tc_plan_hdr_count
    ldr x20, [x19]
    LEA x21, render_compact
    mov x22, x21                       // cursor
    mov x23, #0                        // first flag
    mov x24, #0                        // i
.Lrch_loop:
    cmp x24, x20
    b.ge .Lrch_done
    LEA x25, tc_plan_rows
    mov x26, #HDR_DESC_SZ
    mul x26, x24, x26
    add x25, x25, x26
    ldr x26, [x25, #24]                // compact
    cbz x26, .Lrch_next
    cbnz x23, .Lrch_sep
    b .Lrch_cell
.Lrch_sep:
    sub x0, x22, #1                   // overwrite the trailing NUL
    LEA x1, s_middot
    mov x2, #s_middot_len
    bl render_str_cat_n
    mov x22, x0
.Lrch_cell:
    mov x0, x22
    mov x1, x26
    bl render_str_cat
    mov x22, x0
    mov x23, #1
.Lrch_next:
    add x24, x24, #1
    b .Lrch_loop
.Lrch_done:
    mov x0, x21
    bl render_line_puts
    bl render_line_blank
    EPILOGUE 4
    ret

// ============================================================================
// render_others_widths — widen render_widths for the "+ N others" row: its login,
// its count cell and its pooled-state metric cells.  x26 = hidden_n; x22 =
// render_widths base.  Preserves x19-x28 (callee-saved, no calls that
// clobber them except our own which all preserve them).
// ============================================================================
    .p2align 2
render_others_widths:
    PROLOGUE 5
    mov x19, x22                       // widths base
    mov x20, x26                       // hidden_n
    // zero the shared cell buffer
    LEA x0, render_cell
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    // login: "+ N others"
    LEA x0, render_cell
    mov w1, #'+'
    strb w1, [x0], #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x1, x20
    bl render_fmt_u64_commas
    LEA x1, s_others
    bl render_str_cat
    LEA x21, render_cell
    mov x0, x21
    bl tc_strlen
    ldr x28, [x19]
    cmp x0, x28
    b.le .Low_login_done
    str x0, [x19]
.Low_login_done:
    // pooled states over hidden rows
    LEA x21, tc_plan_reported
    ldr x21, [x21]
    LEA x22, tc_plan_displayed_n
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
    LEA x0, render_cell
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    LEA x0, render_cell
    LEA x1, tc_plan_msgs_hidden
    ldr x1, [x1]
    bl render_fmt_u64_commas
    LEA x21, render_cell
    mov x0, x21
    bl tc_strlen
    ldr x28, [x19, #8]
    cmp x0, x28
    b.le .Low_count_done
    str x0, [x19, #8]
.Low_count_done:
    // metric cells (width slots 2+i)
    LEA x21, tc_plan_col_count
    ldr x22, [x21]                     // col_count
    mov x23, #0                        // metric index i
.Low_loop:
    cmp x23, x22
    b.ge .Low_done
    LEA x24, tc_plan_columns
    ldr x24, [x24, x23, lsl #3]        // col id
    LEA x25, render_cell
    mov x0, x25
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    LEA x25, render_cell
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
    bl render_fmt_share_cell
    b .Low_place
.Low_offshare:
    mov x0, x25
    mov x1, x27
    mov x2, x20
    bl render_fmt_share_cell
    b .Low_place
.Low_live:
    mov x0, x25
    mov x1, x26
    bl render_fmt_u64_commas
    b .Low_place
.Low_offline:
    mov x0, x25
    mov x1, x27
    bl render_fmt_u64_commas
    b .Low_place
.Low_unknown:
    mov x0, x25
    mov x1, x28
    bl render_fmt_u64_commas
.Low_place:
    LEA x25, render_cell
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
    EPILOGUE 5
    ret

// ============================================================================
// render_table — headers, rule, rows, "+ N others", rule, footer.
// ============================================================================
    .p2align 2
render_table:
    PROLOGUE 5
    LEA x19, tc_plan_col_count
    ldr x20, [x19]                     // n metric columns
    add x21, x20, #2                   // total cells: user + count + metrics
    // widths: w[i], i in 0..x21-1
    LEA x22, render_widths
    // header row: "user" + "count" + metric headers
    mov w23, #4
    str x23, [x22]                     // w[0] = 4 ("user")
    mov w23, #5
    str x23, [x22, #8]                 // w[1] = 5 ("count")
    mov x23, #0
.Lrt_hdr_w:
    cmp x23, x20
    b.ge .Lrt_hdr_w_done
    LEA x24, metric_headers
    LEA x25, tc_plan_columns
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
    LEA x23, tc_plan_reported
    ldr x23, [x23]                     // reported base
    LEA x24, tc_plan_displayed_n
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
    LEA x28, tc_plan_columns
    sub x10, x27, #1
    ldr x28, [x28, x10, lsl #3]
    b .Lrt_row_w_len
.Lrt_row_w_count:
    mov x28, #TC_M_COUNT
.Lrt_row_w_len:
    mov x0, x26
    mov x1, x28
    bl render_cell_len
    add x9, x27, #1                   // recompute the slot: render_cell_len clobbers x9
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
    LEA x25, tc_plan_hidden_n
    ldr x26, [x25]
    cbz x26, .Lrt_pin
    bl render_others_widths
.Lrt_pin:
    // Watch mode: a pinned login column is fixed, not merely capped: the clip in
    // render_pin_cell already bounded every login at `pin` characters, so widths[0]
    // is set to the pin exactly (Python: widths[0] = pinned).
    LEA x25, tc_frame_pin_width
    ldr x26, [x25]
    cbz x26, .Lrt_emit
    str x26, [x22]
.Lrt_emit:
    // header line
    LEA x19, render_line
    mov x0, x19
    mov x1, x21                       // cell count
    mov x2, #1                        // header flag
    bl render_emit_table_header
    // rule
    mov x0, x19
    mov x1, x21
    bl render_emit_rule
    // rows
    LEA x23, tc_plan_reported
    ldr x23, [x23]
    LEA x24, tc_plan_displayed_n
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
    bl render_emit_table_row
    add x25, x25, #1
    b .Lrt_row_emit
.Lrt_row_emit_done:
    // "+ N others" row
    LEA x26, tc_plan_hidden_n
    ldr x26, [x26]
    cbz x26, .Lrt_rule2
    mov x0, x19
    mov x1, x26
    mov x2, x21
    bl render_emit_others_row
.Lrt_rule2:
    mov x0, x19
    mov x1, x21
    bl render_emit_rule
.Lrt_end:
    // footer
    bl render_emit_footer
    EPILOGUE 5
    ret

// render_cell_len(rec, col_id) -> x0 = rendered cell length
//   Integer cells (count/live/offline/unknown) are sized arithmetically
//   (render_fmt_u64_commas_len) — no render, no strlen, no buffer write.
//   Share cells still render into the cell buffer (snprintf NUL-terminates).
    .p2align 2
render_cell_len:
    PROLOGUE 2
    mov x19, x0                        // rec
    mov x20, x1                        // col
    cmp x20, #TC_M_COUNT
    b.eq .Lcl_count
    cmp x20, #TC_M_LIVE
    b.eq .Lcl_live
    cmp x20, #TC_M_OFFLINE
    b.eq .Lcl_offline
    cmp x20, #TC_M_UNKNOWN
    b.eq .Lcl_unknown
    cmp x20, #TC_M_OFFLINE_SHARE
    b.eq .Lcl_offshare
    // live-share
    LEA x0, render_cell
    ldr x1, [x19, #ROW_LIVE]
    ldr x2, [x19, #ROW_COUNT]
    bl render_fmt_share_cell
    b .Lcl_len
.Lcl_offshare:
    LEA x0, render_cell
    ldr x1, [x19, #ROW_OFFLINE]
    ldr x2, [x19, #ROW_COUNT]
    bl render_fmt_share_cell
    b .Lcl_len
.Lcl_count:
    ldr x1, [x19, #ROW_COUNT]
    b .Lcl_u64
.Lcl_live:
    ldr x1, [x19, #ROW_LIVE]
    b .Lcl_u64
.Lcl_offline:
    ldr x1, [x19, #ROW_OFFLINE]
    b .Lcl_u64
.Lcl_unknown:
    ldr x1, [x19, #ROW_UNKNOWN]
.Lcl_u64:
    mov x0, x1
    bl render_fmt_u64_commas_len
    EPILOGUE 2
    ret
.Lcl_len:
    LEA x0, render_cell
    bl tc_strlen
    EPILOGUE 2
    ret

// render_emit_table_header(buf, ncols, flag) — header cells aligned "lr"
    .p2align 2
render_emit_table_header:
    PROLOGUE 5
    mov x19, x0                        // buf
    mov x20, x1                        // ncols
    mov x21, x0                        // cursor
    bl render_line_zero
    mov x21, x0
    // cell 0: "user" ljust (pin-aware under watch)
    LEA x22, render_widths
    ldr x2, [x22]
    LEA x1, s_user4
    mov x0, x19
    bl render_pin_cell
    mov x21, x0
    // separator + "count" rjust w[1]
    mov w1, #' '
    strb w1, [x21], #1
    mov w1, #' '
    strb w1, [x21], #1
    LEA x24, metric_headers  // table base (kept in x24)
    ldr x26, [x24, #0]                 // "count" header string (rodata)
    LEA x27, render_cell
    mov x0, x27
    mov x1, x26
    bl render_str_cat                          // copy into writable cell buffer
    ldr x27, [x22, #8]                 // w[1]
    LEA x26, render_cell
    mov x0, x21                        // line cursor
    mov x1, x26                        // cell
    mov x2, x27                        // width
    bl render_rjust_copy
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
    LEA x25, tc_plan_columns
    ldr x25, [x25, x23, lsl #3]
    ldr x26, [x24, x25, lsl #3]        // header string (rodata)
    LEA x27, render_cell
    mov x0, x27
    mov x1, x26
    bl render_str_cat
    add x27, x23, #2
    ldr x27, [x22, x27, lsl #3]        // width
    LEA x26, render_cell
    mov x0, x21                        // line cursor
    mov x1, x26
    mov x2, x27
    bl render_rjust_copy
    mov x21, x0
    add x23, x23, #1
    b .Leth_loop
.Leth_done:
    mov w1, #0
    strb w1, [x21]
    mov x0, x19
    bl render_line_puts
    EPILOGUE 5
    ret

// render_emit_rule(buf, ncols) — dashes per width, joined "  "
    .p2align 2
render_emit_rule:
    PROLOGUE 4
    mov x19, x0
    mov x20, x1
    mov x21, x0
    bl render_line_zero
    mov x21, x0
    LEA x22, render_widths
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
    bl render_line_puts
    EPILOGUE 4
    ret

// render_emit_table_row(buf, rec, ncols) — login ljust, metric cells rjust
    .p2align 2
render_emit_table_row:
    PROLOGUE 4
    mov x19, x0                        // buf
    mov x20, x1                        // rec
    mov x21, x2                        // ncols
    mov x22, x0                        // cursor
    bl render_line_zero
    mov x22, x0
    LEA x23, render_widths
    // login cell (pin-aware under watch)
    ldr x24, [x23]
    mov x0, x19
    add x1, x20, #ROW_LOGIN
    mov x2, x24
    bl render_pin_cell
    mov x22, x0
    // count cell rjust w[1]
    mov w1, #' '
    strb w1, [x22], #1
    mov w1, #' '
    strb w1, [x22], #1
    LEA x0, render_cell
    mov x1, #TC_M_COUNT
    mov x0, x20
    bl render_cell_render
    LEA x25, render_cell
    ldr x26, [x23, #8]                 // w[1]
    mov x0, x22                        // line cursor
    mov x1, x25
    mov x2, x26
    bl render_rjust_copy
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
    // render metric cell into render_cell
    LEA x25, tc_plan_columns
    ldr x26, [x25, x24, lsl #3]
    mov x0, x20
    mov x1, x26
    bl render_cell_render
    LEA x25, render_cell
    add x26, x24, #2
    ldr x26, [x23, x26, lsl #3]
    mov x0, x22                        // line cursor
    mov x1, x25
    mov x2, x26
    bl render_rjust_copy
    mov x22, x0
    add x24, x24, #1
    b .Letr_loop
.Letr_done:
    mov w1, #0
    strb w1, [x22]
    // A tint hook (watch mode) wraps each displayed row's text.
    LEA x9, tc_frame_tint_fn
    ldr x9, [x9]
    cbz x9, .Letr_puts
    LEA x0, tc_frame_tint_ctx
    ldr x0, [x0]
    mov x1, x20                        // rec
    mov x2, x19                        // text
    blr x9
    mov x19, x0                        // tinted text (capture copies it)
.Letr_puts:
    mov x0, x19
    bl render_line_puts
    EPILOGUE 4
    ret

// render_cell_render(rec, col_id) -> renders into render_cell, returns end
    .p2align 2
render_cell_render:
    PROLOGUE 2
    mov x19, x0
    mov x20, x1
    LEA x0, render_cell
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    LEA x0, render_cell
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
    bl render_fmt_share_cell
    b .Lcr_done
.Lcr_offshare:
    ldr x1, [x19, #ROW_OFFLINE]
    ldr x2, [x19, #ROW_COUNT]
    bl render_fmt_share_cell
    b .Lcr_done
.Lcr_count:
    ldr x1, [x19, #ROW_COUNT]
    bl render_fmt_u64_commas
    b .Lcr_done
.Lcr_live:
    ldr x1, [x19, #ROW_LIVE]
    bl render_fmt_u64_commas
    b .Lcr_done
.Lcr_offline:
    ldr x1, [x19, #ROW_OFFLINE]
    bl render_fmt_u64_commas
    b .Lcr_done
.Lcr_unknown:
    ldr x1, [x19, #ROW_UNKNOWN]
    bl render_fmt_u64_commas
.Lcr_done:
    EPILOGUE 2
    ret

// render_emit_others_row(buf, hidden_n, ncols) — the pooled "+ N others" row
    .p2align 2
render_emit_others_row:
    PROLOGUE 4
    mov x19, x0                        // buf
    mov x20, x1                        // hidden_n
    mov x21, x2                        // ncols
    mov x22, x0                        // cursor
    bl render_line_zero
    mov x22, x0
    LEA x23, render_widths
    LEA x0, render_cell
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    // login cell "+ N others" (built in the cell buffer: pin-aware under watch)
    LEA x0, render_cell
    mov w1, #'+'
    strb w1, [x0], #1
    mov w1, #' '
    strb w1, [x0], #1
    mov x1, x20
    bl render_fmt_u64_commas
    LEA x1, s_others
    bl render_str_cat
    ldr x24, [x23]
    LEA x1, render_cell
    mov x0, x19
    mov x2, x24
    bl render_pin_cell
    mov x22, x0
    // The metric cells render into render_cell and rely on it being
    // zeroed (render_fmt_u64_commas writes no NUL); the login-cell build above
    // wrote into it, so clear it again before the cell loop.
    LEA x0, render_cell
    mov x1, #0
    mov x2, #CELL_SZ
    bl memset
    // pooled states over hidden rows
    LEA x24, tc_plan_reported
    ldr x24, [x24]
    LEA x25, tc_plan_displayed_n
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
    LEA x11, tc_plan_columns
    sub x13, x24, #1
    ldr x11, [x11, x13, lsl #3]
    LEA x12, render_cell
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
    bl render_fmt_share_cell
    b .Leor_place
.Leor_offshare:
    mov x0, x12
    mov x1, x27
    mov x2, x20
    bl render_fmt_share_cell
    b .Leor_place
.Leor_count:
    LEA x12, render_cell
    mov x0, x12
    LEA x13, tc_plan_msgs_hidden
    ldr x1, [x13]
    bl render_fmt_u64_commas
    b .Leor_place
.Leor_live:
    mov x0, x12
    mov x1, x26
    bl render_fmt_u64_commas
    b .Leor_place
.Leor_offline:
    mov x0, x12
    mov x1, x27
    bl render_fmt_u64_commas
    b .Leor_place
.Leor_unknown:
    mov x0, x12
    mov x1, x28
    bl render_fmt_u64_commas
.Leor_place:
    LEA x12, render_cell
    add x10, x24, #1                   // width slot (recomputed: cell renders
    ldr x13, [x23, x10, lsl #3]        // clobber caller-saved x10)
    mov x0, x22                        // line cursor
    mov x1, x12                        // cell
    mov x2, x13                        // width
    bl render_rjust_copy
    mov x22, x0
    add x24, x24, #1
    b .Leor_loop
.Leor_done:
    mov w1, #0
    strb w1, [x22]
    mov x0, x19
    bl render_line_puts
    EPILOGUE 4
    ret

// ============================================================================
// render_pad_left_to(buf, width) — pad the string at buf with trailing spaces until
// its length is `width`; returns the cursor (buf + width).  Assumes the buf
// string is NUL-terminated and shorter than width.
// ============================================================================
    .p2align 2
render_pad_left_to:
    PROLOGUE 2
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
    EPILOGUE 2
    ret

// render_rjust_copy(dst, src, width) -> dst + width; writes leading spaces then the
// NUL-terminated src (which must be <= width) into dst.  No NUL is written.
    .p2align 2
render_rjust_copy:
    PROLOGUE 3
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
    bl render_str_cat_n
    add x0, x19, x21
    EPILOGUE 3
    ret

// ============================================================================
// render_emit_footer — "users; messages" + the excluded line when exclusions acted.
// ============================================================================
    .p2align 2
render_emit_footer:
    PROLOGUE 4
    bl render_line_zero
    LEA x19, render_line
    mov x20, x19                       // cursor
    LEA x21, tc_plan_displayed_n
    ldr x22, [x21]                     // displayed
    LEA x21, tc_plan_reported_n
    ldr x23, [x21]                     // reported
    LEA x21, tc_plan_hidden_n
    ldr x24, [x21]                     // hidden
    LEA x21, tc_plan_in_range
    ldr x25, [x21]                     // in_range
    cbnz x24, .Lef_hidden
    // "R of K user(s)"
    mov x0, x20
    mov x1, x23
    bl render_fmt_u64_commas
    mov x20, x0
    LEA x1, s_of
    mov x0, x20
    bl render_str_cat
    sub x0, x0, #1
    mov x20, x0
    mov x1, x25
    bl render_fmt_u64_commas
    mov x20, x0
    LEA x1, s_user_s
    mov x0, x20
    bl render_str_cat
    mov x20, x0
    b .Lef_msgs
.Lef_hidden:
    // "D of R user(s) above threshold (K in range)"
    mov x0, x20
    mov x1, x22
    bl render_fmt_u64_commas
    mov x20, x0
    LEA x1, s_of
    mov x0, x20
    bl render_str_cat
    sub x0, x0, #1
    mov x20, x0
    mov x1, x23
    bl render_fmt_u64_commas
    mov x20, x0
    LEA x1, s_user_s
    mov x0, x20
    bl render_str_cat
    sub x0, x0, #1
    mov x20, x0
    LEA x1, s_above_threshold
    mov x0, x20
    bl render_str_cat
    sub x0, x0, #1
    mov x20, x0
    mov x1, x25
    bl render_fmt_u64_commas
    mov x20, x0
    LEA x1, s_in_range_paren
    mov x0, x20
    bl render_str_cat
    mov x20, x0
.Lef_msgs:
    // "; S of T message(s) in range"
    LEA x1, s_semicolon
    sub x0, x20, #1                  // overwrite the trailing NUL
    bl render_str_cat
    mov x20, x0
    LEA x21, tc_plan_msgs_shown
    ldr x21, [x21]
    sub x0, x20, #1
    mov x1, x21
    bl render_fmt_u64_commas
    mov x20, x0
    LEA x1, s_of
    mov x0, x20
    bl render_str_cat
    sub x0, x0, #1
    mov x20, x0
    LEA x21, tc_tally
    ldr x21, [x21, #TC_T_MESSAGES]
    mov x1, x21
    bl render_fmt_u64_commas
    mov x20, x0
    LEA x1, s_msg_range
    mov x0, x20
    bl render_str_cat
    mov x0, x19
    bl render_line_puts
    // excluded line
    LEA x21, tc_plan_excl_appeared
    ldr x22, [x21]
    cbz x22, .Lef_done
    bl render_emit_excluded_line
.Lef_done:
    EPILOGUE 4
    ret

// render_emit_excluded_line — "excluded E user(s), M message(s) not counted"
    .p2align 2
render_emit_excluded_line:
    PROLOGUE 1
    bl render_line_zero
    LEA x19, render_line
    mov x0, x19
    LEA x1, s_excluded_pre
    bl render_str_cat
    sub x0, x0, #1
    LEA x20, tc_plan_excl_appeared
    ldr x1, [x20]
    bl render_fmt_u64_commas
    LEA x1, s_excluded_mid
    bl render_str_cat
    LEA x20, tc_plan_excl_msgs
    ldr x1, [x20]
    sub x0, x0, #1
    bl render_fmt_u64_commas
    LEA x1, s_not_counted2
    bl render_str_cat
    mov x0, x19
    bl render_line_puts
    EPILOGUE 1
    ret

// ============================================================================
// tc_render_report — plan, then emit JSON or text.
// ============================================================================
    .p2align 2
    .global tc_render_report
    FUNC_TYPE(tc_render_report)
tc_render_report:
    PROLOGUE 0
    bl tc_plan_presentation
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.ne .Lrr_json
    bl tc_render_text
    b .Lrr_done
.Lrr_json:
    bl tc_json_emit
.Lrr_done:
    mov x0, #0
    EPILOGUE 0
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
render_widths:   .skip 8 * 8

    .end
