// ============================================================================
// check_tc_config.S — Phase-3 test driver for the config/env/exclusion hooks.
//   main() calls tc_cli_parse(argc, argv), then tc_build_exclusions(), then
//   prints a stable dump: resolved values + source labels, the resolved config
//   path + loaded flag, and the merged exclusion set (one login per line with
//   its source label) plus the ordered source list.  test-tc-config.sh asserts
//   against this output and compares error cases against python3
//   twitch-counts.py.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

    .globl main
    .globl printf
    .globl tc_cli_parse
    .globl tc_source_str
    .globl tc_build_exclusions
    .globl tc_strlen
    .globl tc_printf_i
    .globl tc_printf_ii
    .globl tc_printf_ip
    .globl tc_printf_p

// ----------------------------------------------------------------------------
// tc_load_src_id(x0=set id) -> x0 = the source id at TC_O_SRC[set id]
// ----------------------------------------------------------------------------
    .p2align 2
tc_load_src_id:
    LEA x1, tc_opts
    mov x2, #TC_O_SRC
    add x2, x1, x2
    mov x3, #8
    mul x0, x0, x3
    ldr x0, [x2, x0]
    ret

// ----------------------------------------------------------------------------
// tc_print_src(x0=source id) — print "src=%.*s\n" via tc_source_str
// ----------------------------------------------------------------------------
    .p2align 2
tc_print_src:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    bl tc_source_str                // x0=ptr, x1=len
    mov x19, x0
    mov x20, x1
    LEA x0, fmt_src
    mov x1, x20
    mov x2, x19
    bl tc_printf_ip
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_print_src_of(x0=set id) — print the source of a setting
// ----------------------------------------------------------------------------
    .p2align 2
tc_print_src_of:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    bl tc_load_src_id
    bl tc_print_src
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// main
// ----------------------------------------------------------------------------
    .p2align 2
main:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                     // argc
    mov x20, x1                     // argv
    mov x0, x19
    mov x1, x20
    bl tc_cli_parse                 // exits 2/1 on errors
    bl tc_build_exclusions          // exits 1 on exclusion/config errors
    // ---- channel -----------------------------------------------------------
    LEA x0, fmt_channel
    LEA_OFF x1, tc_opts, TC_O_CHANNEL
    bl tc_printf_p
    mov x0, #TC_SET_CHANNEL
    bl tc_load_src_id
    cmp x0, #TC_SRC_DYN_ALIAS
    b.ne 1f
    // tc_source_str(TC_SRC_DYN_ALIAS) is broken in tc_cli.S (falls into
    // .Lss_none); read the composed buffer directly.
    LEA x0, tc_opts
    mov x1, #TC_O_CHAN_SRC
    add x0, x0, x1
    mov x19, x0                     // chan_src ptr (callee-saved)
    bl tc_strlen
    mov x20, x0                     // len
    LEA x0, fmt_chan_src
    mov x1, x20
    mov x2, x19
    bl tc_printf_ip
    b 2f
1:
    mov x0, #TC_SET_CHANNEL
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    LEA x0, fmt_chan_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip
2:

    // ---- logs_dir ----------------------------------------------------------
    LEA x0, fmt_logs_dir
    LEA_OFF x1, tc_opts, TC_O_LOGS_DIR
    bl tc_printf_p
    mov x0, #TC_SET_LOGS_DIR
    bl tc_print_src_of

    // ---- config path + loaded flag ----------------------------------------
    LEA x0, fmt_config
    LEA_OFF x1, tc_opts, TC_O_CONFIG_PATH
    bl tc_printf_p
    LEA x0, fmt_loaded
    LEA x1, tc_opts
    ldr x1, [x1, #TC_O_CONFIG_LOADED]
    bl tc_printf_i

    // ---- numeric settings --------------------------------------------------
    LEA x19, tc_opts
    ldr x1, [x19, #TC_O_MIN_COUNT]
    LEA x0, fmt_min_count
    bl tc_printf_i
    mov x0, #TC_SET_MIN_COUNT
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_TOP]
    LEA x0, fmt_top
    bl tc_printf_i

    ldr x1, [x19, #TC_O_HEADER_MODE]
    LEA x0, fmt_header
    bl tc_printf_i
    mov x0, #TC_SET_HEADER
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_SORT]
    LEA x0, fmt_sort
    bl tc_printf_i
    mov x0, #TC_SET_SORT
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_STATE_FILTER]
    LEA x0, fmt_state
    bl tc_printf_i
    mov x0, #TC_SET_STATE
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_USERS_POLICY]
    LEA x0, fmt_users_policy
    bl tc_printf_i
    mov x0, #TC_SET_USERS_POLICY
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_USERS_MAX]
    LEA x0, fmt_users_max
    bl tc_printf_i
    mov x0, #TC_SET_USERS_MAX
    bl tc_print_src_of

    // ---- window ------------------------------------------------------------
    LEA x20, tc_window
    ldr x1, [x20, #TC_W_END_YMD]
    ldr x2, [x20, #TC_W_END_SOD]
    LEA x0, fmt_end
    bl tc_printf_ii
    mov x0, #TC_SET_END
    bl tc_print_src_of

    ldr x1, [x20, #TC_W_BEGIN_YMD]
    ldr x2, [x20, #TC_W_BEGIN_SOD]
    LEA x0, fmt_begin
    bl tc_printf_ii
    // begin source (window start source pointer)
    ldr x21, [x20, #TC_W_START_SRC]
    mov x0, x21
    bl tc_strlen
    mov x22, x1
    LEA x0, fmt_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip

    // ---- watch/tail values ------------------------------------------------
    ldr x1, [x19, #TC_O_INTERVAL]
    LEA x0, fmt_interval
    bl tc_printf_i
    mov x0, #TC_SET_INTERVAL
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_HOLD]
    LEA x0, fmt_hold
    bl tc_printf_i
    mov x0, #TC_SET_HOLD
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_SHADES]
    LEA x0, fmt_shades
    bl tc_printf_i
    mov x0, #TC_SET_SHADES
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_USER_WIDTH]
    LEA x0, fmt_user_width
    bl tc_printf_i
    mov x0, #TC_SET_USER_WIDTH
    bl tc_print_src_of

    LEA x0, fmt_fade_up
    add x1, x19, #TC_O_FADE_UP_RAW
    bl tc_printf_p
    mov x0, #TC_SET_FADE_UP
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_NOTIFY]
    LEA x0, fmt_notify
    bl tc_printf_i
    mov x0, #TC_SET_NOTIFY
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_MAX_EVENTS]
    LEA x0, fmt_max_events
    bl tc_printf_i
    mov x0, #TC_SET_MAX_EVENTS
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_SEED_LOOKBACK]
    LEA x0, fmt_seed_lookback
    bl tc_printf_i
    mov x0, #TC_SET_SEED_LOOKBACK
    bl tc_print_src_of

    LEA x19, tc_excl_set
    ldr x23, [x19]                  // count
    LEA x0, fmt_excl_count
    mov x1, x23
    bl tc_printf_i
    add x20, x19, #8                // entries base
    mov x24, #0
.Lexcl_loop:
    cmp x24, x23
    b.ge .Lexcl_done
    mov x0, x24
    bl tc_excl_entry_off
    add x0, x20, x0
    mov x21, x0                     // entry: login at 0, src_idx at 26
    ldr x25, [x21, #TC_EX_LOGIN_SZ] // source index
    // print "excl=<login>|<label>"
    LEA x0, fmt_excl
    mov x1, x21
    bl tc_printf_p
    // source label: tc_excl_sources[idx] = {ptr, len}
    LEA x0, tc_excl_sources
    mov x1, #16
    mul x1, x25, x1
    add x0, x0, x1
    ldr x1, [x0, #8]                // len (precision for %.*s)
    ldr x2, [x0]                    // ptr (string for %.*s)
    LEA x0, fmt_src
    bl tc_printf_ip
    add x24, x24, #1
    b .Lexcl_loop
.Lexcl_done:
    // excl_sources=<", ".join(labels)>
    LEA x0, fmt_excl_sources_pre
    bl printf
    LEA x19, tc_excl_src_count
    ldr x24, [x19]
    mov x25, #0
.Lesrc_loop:
    cmp x25, x24
    b.ge .Lesrc_done
    cbz x25, .Lesrc_label
    LEA x0, fmt_comma
    bl printf
.Lesrc_label:
    LEA x0, tc_excl_sources
    mov x1, #16
    mul x1, x25, x1
    add x0, x0, x1
    ldr x1, [x0, #8]                // len (precision)
    ldr x2, [x0]                    // ptr (string)
    LEA x0, fmt_src2
    bl tc_printf_ip
    add x25, x25, #1
    b .Lesrc_loop
.Lesrc_done:
    LEA x0, fmt_newline
    bl printf

    mov w0, #0
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_excl_entry_off(x0=index) -> x0 = byte offset of an exclusion entry
// ----------------------------------------------------------------------------
    .p2align 2
tc_excl_entry_off:
    mov x1, #TC_EX_ENTRY_SZ
    mul x0, x0, x1
    ret

// ----------------------------------------------------------------------------
    RODATA
fmt_channel:       .asciz "channel=%s\n"
fmt_chan_src:      .asciz "chan_src=%.*s\n"
fmt_src:           .asciz "src=%.*s\n"
fmt_src2:          .asciz "%.*s"
fmt_logs_dir:      .asciz "logs_dir=%s\n"
fmt_config:        .asciz "config=%s\n"
fmt_loaded:        .asciz "config_loaded=%lld\n"
fmt_min_count:     .asciz "min_count=%lld\n"
fmt_top:           .asciz "top=%lld\n"
fmt_header:        .asciz "header=%lld\n"
fmt_sort:          .asciz "sort=%lld\n"
fmt_state:         .asciz "state=%lld\n"
fmt_users_policy:  .asciz "users_policy=%lld\n"
fmt_users_max:     .asciz "users_max=%lld\n"
fmt_end:           .asciz "end=%lld %lld\n"
fmt_begin:         .asciz "begin=%lld %lld\n"
fmt_interval:      .asciz "interval=%lld\n"
fmt_hold:          .asciz "hold=%lld\n"
fmt_shades:        .asciz "shades=%lld\n"
fmt_user_width:    .asciz "user_width=%lld\n"
fmt_fade_up:       .asciz "fade_up=%s\n"
fmt_notify:        .asciz "notify=%lld\n"
fmt_max_events:    .asciz "max_events=%lld\n"
fmt_seed_lookback: .asciz "seed_lookback=%lld\n"
fmt_excl_count:    .asciz "excl_count=%lld\n"
fmt_excl:          .asciz "excl=%s|"
fmt_excl_sources_pre: .asciz "excl_sources="
fmt_comma:         .asciz ", "
fmt_newline:       .asciz "\n"

    .end


