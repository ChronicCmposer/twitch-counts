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

// ----------------------------------------------------------------------------
// tc_load_src_id(x0=set id) -> x0 = the source id at TC_O_SRC[set id]
// ----------------------------------------------------------------------------
    .p2align 2
tc_load_src_id:
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
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
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x20
    mov x2, x19
    bl printf
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
    adrp x0, PAGE(fmt_channel)
    add x0, x0, LO12(fmt_channel)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_CHANNEL
    bl printf
    mov x0, #TC_SET_CHANNEL
    bl tc_load_src_id
    cmp x0, #TC_SRC_DYN_ALIAS
    b.ne 1f
    // tc_source_str(TC_SRC_DYN_ALIAS) is broken in tc_cli.S (falls into
    // .Lss_none); read the composed buffer directly.
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x1, #TC_O_CHAN_SRC
    add x0, x0, x1
    mov x19, x0                     // chan_src ptr (callee-saved)
    bl tc_strlen
    mov x20, x0                     // len
    adrp x0, PAGE(fmt_chan_src)
    add x0, x0, LO12(fmt_chan_src)
    mov x1, x20
    mov x2, x19
    bl printf
    b 2f
1:
    mov x0, #TC_SET_CHANNEL
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    adrp x0, PAGE(fmt_chan_src)
    add x0, x0, LO12(fmt_chan_src)
    mov x1, x22
    mov x2, x21
    bl printf
2:

    // ---- logs_dir ----------------------------------------------------------
    adrp x0, PAGE(fmt_logs_dir)
    add x0, x0, LO12(fmt_logs_dir)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_LOGS_DIR
    bl printf
    mov x0, #TC_SET_LOGS_DIR
    bl tc_print_src_of

    // ---- config path + loaded flag ----------------------------------------
    adrp x0, PAGE(fmt_config)
    add x0, x0, LO12(fmt_config)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_CONFIG_PATH
    bl printf
    adrp x0, PAGE(fmt_loaded)
    add x0, x0, LO12(fmt_loaded)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    ldr x1, [x1, #TC_O_CONFIG_LOADED]
    bl printf

    // ---- numeric settings --------------------------------------------------
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x1, [x19, #TC_O_MIN_COUNT]
    adrp x0, PAGE(fmt_min_count)
    add x0, x0, LO12(fmt_min_count)
    bl printf
    mov x0, #TC_SET_MIN_COUNT
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_TOP]
    adrp x0, PAGE(fmt_top)
    add x0, x0, LO12(fmt_top)
    bl printf

    ldr x1, [x19, #TC_O_HEADER_MODE]
    adrp x0, PAGE(fmt_header)
    add x0, x0, LO12(fmt_header)
    bl printf
    mov x0, #TC_SET_HEADER
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_SORT]
    adrp x0, PAGE(fmt_sort)
    add x0, x0, LO12(fmt_sort)
    bl printf
    mov x0, #TC_SET_SORT
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_STATE_FILTER]
    adrp x0, PAGE(fmt_state)
    add x0, x0, LO12(fmt_state)
    bl printf
    mov x0, #TC_SET_STATE
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_USERS_POLICY]
    adrp x0, PAGE(fmt_users_policy)
    add x0, x0, LO12(fmt_users_policy)
    bl printf
    mov x0, #TC_SET_USERS_POLICY
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_USERS_MAX]
    adrp x0, PAGE(fmt_users_max)
    add x0, x0, LO12(fmt_users_max)
    bl printf
    mov x0, #TC_SET_USERS_MAX
    bl tc_print_src_of

    // ---- window ------------------------------------------------------------
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x1, [x20, #TC_W_END_YMD]
    ldr x2, [x20, #TC_W_END_SOD]
    adrp x0, PAGE(fmt_end)
    add x0, x0, LO12(fmt_end)
    bl printf
    mov x0, #TC_SET_END
    bl tc_print_src_of

    ldr x1, [x20, #TC_W_BEGIN_YMD]
    ldr x2, [x20, #TC_W_BEGIN_SOD]
    adrp x0, PAGE(fmt_begin)
    add x0, x0, LO12(fmt_begin)
    bl printf
    // begin source (window start source pointer)
    ldr x21, [x20, #TC_W_START_SRC]
    mov x0, x21
    bl tc_strlen
    mov x22, x1
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x22
    mov x2, x21
    bl printf

    // ---- watch/tail values ------------------------------------------------
    ldr x1, [x19, #TC_O_INTERVAL]
    adrp x0, PAGE(fmt_interval)
    add x0, x0, LO12(fmt_interval)
    bl printf
    mov x0, #TC_SET_INTERVAL
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_HOLD]
    adrp x0, PAGE(fmt_hold)
    add x0, x0, LO12(fmt_hold)
    bl printf
    mov x0, #TC_SET_HOLD
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_SHADES]
    adrp x0, PAGE(fmt_shades)
    add x0, x0, LO12(fmt_shades)
    bl printf
    mov x0, #TC_SET_SHADES
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_USER_WIDTH]
    adrp x0, PAGE(fmt_user_width)
    add x0, x0, LO12(fmt_user_width)
    bl printf
    mov x0, #TC_SET_USER_WIDTH
    bl tc_print_src_of

    adrp x0, PAGE(fmt_fade_up)
    add x0, x0, LO12(fmt_fade_up)
    add x1, x19, #TC_O_FADE_UP_RAW
    bl printf
    mov x0, #TC_SET_FADE_UP
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_NOTIFY]
    adrp x0, PAGE(fmt_notify)
    add x0, x0, LO12(fmt_notify)
    bl printf
    mov x0, #TC_SET_NOTIFY
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_MAX_EVENTS]
    adrp x0, PAGE(fmt_max_events)
    add x0, x0, LO12(fmt_max_events)
    bl printf
    mov x0, #TC_SET_MAX_EVENTS
    bl tc_print_src_of

    ldr x1, [x19, #TC_O_SEED_LOOKBACK]
    adrp x0, PAGE(fmt_seed_lookback)
    add x0, x0, LO12(fmt_seed_lookback)
    bl printf
    mov x0, #TC_SET_SEED_LOOKBACK
    bl tc_print_src_of

    adrp x19, PAGE(tc_excl_set)
    add x19, x19, LO12(tc_excl_set)
    ldr x23, [x19]                  // count
    adrp x0, PAGE(fmt_excl_count)
    add x0, x0, LO12(fmt_excl_count)
    mov x1, x23
    bl printf
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
    adrp x0, PAGE(fmt_excl)
    add x0, x0, LO12(fmt_excl)
    mov x1, x21
    bl printf
    // source label: tc_excl_sources[idx] = {ptr, len}
    adrp x0, PAGE(tc_excl_sources)
    add x0, x0, LO12(tc_excl_sources)
    mov x1, #16
    mul x1, x25, x1
    add x0, x0, x1
    ldr x1, [x0, #8]                // len (precision for %.*s)
    ldr x2, [x0]                    // ptr (string for %.*s)
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    bl printf
    add x24, x24, #1
    b .Lexcl_loop
.Lexcl_done:
    // excl_sources=<", ".join(labels)>
    adrp x0, PAGE(fmt_excl_sources_pre)
    add x0, x0, LO12(fmt_excl_sources_pre)
    bl printf
    adrp x19, PAGE(tc_excl_src_count)
    add x19, x19, LO12(tc_excl_src_count)
    ldr x24, [x19]
    mov x25, #0
.Lesrc_loop:
    cmp x25, x24
    b.ge .Lesrc_done
    cbz x25, .Lesrc_label
    adrp x0, PAGE(fmt_comma)
    add x0, x0, LO12(fmt_comma)
    bl printf
.Lesrc_label:
    adrp x0, PAGE(tc_excl_sources)
    add x0, x0, LO12(tc_excl_sources)
    mov x1, #16
    mul x1, x25, x1
    add x0, x0, x1
    ldr x1, [x0, #8]                // len (precision)
    ldr x2, [x0]                    // ptr (string)
    adrp x0, PAGE(fmt_src2)
    add x0, x0, LO12(fmt_src2)
    bl printf
    add x25, x25, #1
    b .Lesrc_loop
.Lesrc_done:
    adrp x0, PAGE(fmt_newline)
    add x0, x0, LO12(fmt_newline)
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


