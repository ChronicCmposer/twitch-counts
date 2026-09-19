// ============================================================================
// check_tc_cache.S — Phase 6 test driver (main() + dump).
// ============================================================================
//
//  main(argc, argv): tc_cli_parse(argc, argv) -> tc_build_exclusions() ->
//    tc_cache_open() -> tc_count_run() -> dump -> tc_cache_close().
//  The dump is a stable, parseable summary of the contract structures plus
//  the rollup cache state:
//
//    channel=<resolved dir name>
//    window begin=<ymd>:<sod> end=<ymd>:<sod> kind=<k> width=<w> found=<f> req=<r>
//    listing <n>
//    <ymd> <name>
//    users <n>
//    <login> <live> <offline> <unknown>
//    tally files=<f> messages=<m> parsed=<p> reused=<r> states=<l>:<o>:<u> excl=<l>:<o>:<u> unreadable=<u>
//    unreadable <name> <reason>
//    cachestatus used=<0|1> reused=<n> parsed=<n> problem=<text|-> rebuilt=<text|-> path=<text|->
//    cachetables ... / cachecounts ... / cachefile ... / cachecount ...  (when open)
//
//  The one binary covers every cache mode through the CLI flags:
//    default          cache enabled (HOME/XDG_CACHE_HOME decides the path)
//    --no-cache       cache disabled, no db touched
//    --rebuild-cache  purge the channel then reparse everything
//
//  Exits 0 on success; tc_fail paths exit 1 with "error: ..." on stderr.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

    .globl main
    .globl tc_strlen
    .globl tc_puts
    .globl tc_putu64
    .globl tc_cli_parse
    .globl tc_build_exclusions
    .globl tc_count_run
    .globl tc_channel_name
    .globl tc_cache_open
    .globl tc_cache_close
    .globl tc_cache_status
    .globl tc_cache_debug_dump

// ----------------------------------------------------------------------------
// main(x0=argc, x1=argv)
// ----------------------------------------------------------------------------
    .p2align 2
main:
    stp x29, x30, [sp, #-16]!
    bl tc_cli_parse
    bl tc_build_exclusions
    bl tc_cache_open
    bl tc_count_run
    bl tc_dump
    bl tc_cache_status
    bl tc_dump_cache_status
    bl tc_cache_debug_dump
    bl tc_cache_close
    mov w0, #0
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_dump — print the contract structures (same format as check_tc_core.S
//   plus reused in the tally line).
// ----------------------------------------------------------------------------
    .p2align 2
tc_dump:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // ---- channel ----
    adrp x0, PAGE(s_channel)
    add x0, x0, LO12(s_channel)
    bl tc_puts
    bl tc_channel_name
    bl tc_puts
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    // ---- window ----
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    adrp x0, PAGE(s_w_begin)
    add x0, x0, LO12(s_w_begin)
    bl tc_puts
    ldr x0, [x19, #TC_W_BEGIN_YMD]
    bl tc_putu64
    adrp x0, PAGE(s_colon)
    add x0, x0, LO12(s_colon)
    bl tc_puts
    ldr x0, [x19, #TC_W_BEGIN_SOD]
    bl tc_putu64
    adrp x0, PAGE(s_w_end)
    add x0, x0, LO12(s_w_end)
    bl tc_puts
    ldr x0, [x19, #TC_W_END_YMD]
    bl tc_putu64
    adrp x0, PAGE(s_colon)
    add x0, x0, LO12(s_colon)
    bl tc_puts
    ldr x0, [x19, #TC_W_END_SOD]
    bl tc_putu64
    adrp x0, PAGE(s_w_kind)
    add x0, x0, LO12(s_w_kind)
    bl tc_puts
    ldr x0, [x19, #TC_W_KIND]
    bl tc_putu64
    adrp x0, PAGE(s_w_width)
    add x0, x0, LO12(s_w_width)
    bl tc_puts
    ldr x0, [x19, #TC_W_USERS_WIDTH]
    bl tc_putu64
    adrp x0, PAGE(s_w_found)
    add x0, x0, LO12(s_w_found)
    bl tc_puts
    ldr x0, [x19, #TC_W_USERS_FOUND]
    bl tc_putu64
    adrp x0, PAGE(s_w_req)
    add x0, x0, LO12(s_w_req)
    bl tc_puts
    ldr x0, [x19, #TC_W_USERS_REQ]
    bl tc_putu64
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    // ---- listing ----
    adrp x19, PAGE(tc_listing)
    add x19, x19, LO12(tc_listing)
    adrp x0, PAGE(s_listing)
    add x0, x0, LO12(s_listing)
    bl tc_puts
    ldr x0, [x19, #TC_L_COUNT]
    bl tc_putu64
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    ldr x20, [x19, #TC_L_COUNT]
    ldr x21, [x19, #TC_L_ENTRIES]
    mov x22, #0
.Ldump_list:
    cmp x22, x20
    b.ge .Ldump_list_done
    mov x23, #TC_L_ENTRY_SZ
    mul x23, x22, x23
    add x23, x21, x23
    ldr x0, [x23, #TC_L_YMD]
    bl tc_putu64
    adrp x0, PAGE(s_space)
    add x0, x0, LO12(s_space)
    bl tc_puts
    add x0, x23, #TC_L_NAME
    bl tc_puts
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    add x22, x22, #1
    b .Ldump_list
.Ldump_list_done:
    // ---- users ----
    adrp x19, PAGE(tc_users)
    add x19, x19, LO12(tc_users)
    adrp x0, PAGE(s_users)
    add x0, x0, LO12(s_users)
    bl tc_puts
    ldr x0, [x19, #TC_US_COUNT]
    bl tc_putu64
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    ldr x20, [x19, #TC_US_COUNT]
    ldr x21, [x19, #TC_US_ENTRIES]
    mov x22, #0
.Ldump_users:
    cmp x22, x20
    b.ge .Ldump_users_done
    mov x23, #TC_US_ENTRY_SZ
    mul x23, x22, x23
    add x23, x21, x23
    mov x0, x23
    bl tc_puts                          // login
    adrp x0, PAGE(s_space)
    add x0, x0, LO12(s_space)
    bl tc_puts
    ldr x0, [x23, #TC_US_LIVE]
    bl tc_putu64
    adrp x0, PAGE(s_space)
    add x0, x0, LO12(s_space)
    bl tc_puts
    ldr x0, [x23, #TC_US_OFFLINE]
    bl tc_putu64
    adrp x0, PAGE(s_space)
    add x0, x0, LO12(s_space)
    bl tc_puts
    ldr x0, [x23, #TC_US_UNKNOWN]
    bl tc_putu64
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    add x22, x22, #1
    b .Ldump_users
.Ldump_users_done:
    // ---- tally ----
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    adrp x0, PAGE(s_t_files)
    add x0, x0, LO12(s_t_files)
    bl tc_puts
    ldr x0, [x19, #TC_T_FILES]
    bl tc_putu64
    adrp x0, PAGE(s_t_messages)
    add x0, x0, LO12(s_t_messages)
    bl tc_puts
    ldr x0, [x19, #TC_T_MESSAGES]
    bl tc_putu64
    adrp x0, PAGE(s_t_parsed)
    add x0, x0, LO12(s_t_parsed)
    bl tc_puts
    ldr x0, [x19, #TC_T_PARSED]
    bl tc_putu64
    adrp x0, PAGE(s_t_reused)
    add x0, x0, LO12(s_t_reused)
    bl tc_puts
    ldr x0, [x19, #TC_T_REUSED]
    bl tc_putu64
    adrp x0, PAGE(s_t_states)
    add x0, x0, LO12(s_t_states)
    bl tc_puts
    ldr x0, [x19, #TC_T_STATES + 0]
    bl tc_putu64
    adrp x0, PAGE(s_colon)
    add x0, x0, LO12(s_colon)
    bl tc_puts
    ldr x0, [x19, #TC_T_STATES + 8]
    bl tc_putu64
    adrp x0, PAGE(s_colon)
    add x0, x0, LO12(s_colon)
    bl tc_puts
    ldr x0, [x19, #TC_T_STATES + 16]
    bl tc_putu64
    adrp x0, PAGE(s_t_excl)
    add x0, x0, LO12(s_t_excl)
    bl tc_puts
    ldr x0, [x19, #TC_T_EXCLUDED_STATES + 0]
    bl tc_putu64
    adrp x0, PAGE(s_colon)
    add x0, x0, LO12(s_colon)
    bl tc_puts
    ldr x0, [x19, #TC_T_EXCLUDED_STATES + 8]
    bl tc_putu64
    adrp x0, PAGE(s_colon)
    add x0, x0, LO12(s_colon)
    bl tc_puts
    ldr x0, [x19, #TC_T_EXCLUDED_STATES + 16]
    bl tc_putu64
    adrp x0, PAGE(s_t_unreadable)
    add x0, x0, LO12(s_t_unreadable)
    bl tc_puts
    ldr x0, [x19, #TC_T_UNR_COUNT]
    bl tc_putu64
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    // unreadable entries
    ldr x20, [x19, #TC_T_UNR_COUNT]
    add x21, x19, #TC_T_UNR_ENTRIES
    mov x22, #0
.Ldump_unr:
    cmp x22, x20
    b.ge .Ldump_unr_done
    mov x23, #TC_T_UNR_ENTRY_SZ
    mul x23, x22, x23
    add x23, x21, x23
    adrp x0, PAGE(s_unr)
    add x0, x0, LO12(s_unr)
    bl tc_puts
    mov x0, x23
    bl tc_puts                          // name
    adrp x0, PAGE(s_space)
    add x0, x0, LO12(s_space)
    bl tc_puts
    add x0, x23, #TC_T_UNR_NAME_SZ
    bl tc_puts                          // reason
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    add x22, x22, #1
    b .Ldump_unr
.Ldump_unr_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_dump_cache_status — print the cachestatus line from tc_cache_status().
//   in: x0=used, x1=reused, x2=parsed, x3=problem, x4=rebuilt, x5=path
// ----------------------------------------------------------------------------
    .p2align 2
tc_dump_cache_status:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                         // used
    mov x20, x1                         // reused
    mov x21, x2                         // parsed
    mov x22, x3                         // problem
    mov x23, x4                         // rebuilt
    mov x24, x5                         // path
    adrp x0, PAGE(s_cs_used)
    add x0, x0, LO12(s_cs_used)
    bl tc_puts
    mov x0, x19
    bl tc_putu64
    adrp x0, PAGE(s_cs_reused)
    add x0, x0, LO12(s_cs_reused)
    bl tc_puts
    mov x0, x20
    bl tc_putu64
    adrp x0, PAGE(s_cs_parsed)
    add x0, x0, LO12(s_cs_parsed)
    bl tc_puts
    mov x0, x21
    bl tc_putu64
    adrp x0, PAGE(s_cs_problem)
    add x0, x0, LO12(s_cs_problem)
    bl tc_puts
    mov x0, x22
    cbz x0, .Ldcs_problem_dash
    bl tc_puts
    b .Ldcs_problem_done
.Ldcs_problem_dash:
    adrp x0, PAGE(s_dash)
    add x0, x0, LO12(s_dash)
    bl tc_puts
.Ldcs_problem_done:
    adrp x0, PAGE(s_cs_rebuilt)
    add x0, x0, LO12(s_cs_rebuilt)
    bl tc_puts
    mov x0, x23
    cbz x0, .Ldcs_rebuilt_dash
    bl tc_puts
    b .Ldcs_rebuilt_done
.Ldcs_rebuilt_dash:
    adrp x0, PAGE(s_dash)
    add x0, x0, LO12(s_dash)
    bl tc_puts
.Ldcs_rebuilt_done:
    adrp x0, PAGE(s_cs_path)
    add x0, x0, LO12(s_cs_path)
    bl tc_puts
    mov x0, x24
    cbz x0, .Ldcs_path_dash
    bl tc_puts
    b .Ldcs_path_done
.Ldcs_path_dash:
    adrp x0, PAGE(s_dash)
    add x0, x0, LO12(s_dash)
    bl tc_puts
.Ldcs_path_done:
    adrp x0, PAGE(s_newline)
    add x0, x0, LO12(s_newline)
    bl tc_puts
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

    RODATA
s_channel:      .asciz "channel="
s_newline:      .asciz "\n"
s_colon:        .asciz ":"
s_space:        .asciz " "
s_w_begin:      .asciz "window begin="
s_w_end:        .asciz " end="
s_w_kind:       .asciz " kind="
s_w_width:      .asciz " width="
s_w_found:      .asciz " found="
s_w_req:        .asciz " req="
s_listing:      .asciz "listing "
s_users:        .asciz "users "
s_t_files:      .asciz "tally files="
s_t_messages:   .asciz " messages="
s_t_parsed:     .asciz " parsed="
s_t_reused:     .asciz " reused="
s_t_states:     .asciz " states="
s_t_excl:       .asciz " excl="
s_t_unreadable: .asciz " unreadable="
s_unr:          .asciz "unreadable "
s_cs_used:      .asciz "cachestatus used="
s_cs_reused:    .asciz " reused="
s_cs_parsed:    .asciz " parsed="
s_cs_problem:   .asciz " problem="
s_cs_rebuilt:   .asciz " rebuilt="
s_cs_path:      .asciz " path="
s_dash:         .asciz "-"

    .end
