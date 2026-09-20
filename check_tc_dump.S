// ============================================================================
// check_tc_dump.S — the shared contract-structure printer (tc_dump).
// ============================================================================
//
//  The ONE copy of tc_dump, linked by every driver whose check_<name>.S used
//  to define its own: tc-core-test (check_tc_core.o), tc-cache-test and
//  tc-cache-bump-test (both reuse check_tc_cache.o).  The format is the
//  stable, parseable summary the core and cache harnesses diff:
//
//    channel=<resolved dir name>
//    window begin=<ymd>:<sod> end=<ymd>:<sod> kind=<k> width=<w> found=<f> req=<r>
//    listing <n>
//    <ymd> <name>
//    users <n>
//    <login> <live> <offline> <unknown>
//    tally files=<f> messages=<m> parsed=<p> states=<l>:<o>:<u> excl=<l>:<o>:<u> unreadable=<u>
//    unreadable <name> <reason>
//
//  The tally line is the core format (no reused field): the core harness's
//  strict `parsed=<n> states=` regex requires the two fields adjacent.  The
//  cache harness reads reused from its own cachestatus line and tolerates
//  the absence here.
//
//  Target: AArch64 (ARMv8-A), little-endian — Linux (musl, static) and macOS
//  arm64; tc_platform.h selects.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

    .globl tc_strlen
    .globl tc_puts
    .globl tc_putu64
    .globl tc_channel_name
    .globl tc_dump

// ----------------------------------------------------------------------------
// tc_dump — print the contract structures.
// ----------------------------------------------------------------------------
    .p2align 2
tc_dump:
    PROLOGUE 5
    // ---- channel ----
    LEA x0, s_channel
    bl tc_puts
    bl tc_channel_name
    bl tc_puts
    LEA x0, s_newline
    bl tc_puts
    // ---- window ----
    LEA x19, tc_window
    LEA x0, s_w_begin
    bl tc_puts
    ldr x0, [x19, #TC_W_BEGIN_YMD]
    bl tc_putu64
    LEA x0, s_colon
    bl tc_puts
    ldr x0, [x19, #TC_W_BEGIN_SOD]
    bl tc_putu64
    LEA x0, s_w_end
    bl tc_puts
    ldr x0, [x19, #TC_W_END_YMD]
    bl tc_putu64
    LEA x0, s_colon
    bl tc_puts
    ldr x0, [x19, #TC_W_END_SOD]
    bl tc_putu64
    LEA x0, s_w_kind
    bl tc_puts
    ldr x0, [x19, #TC_W_KIND]
    bl tc_putu64
    LEA x0, s_w_width
    bl tc_puts
    ldr x0, [x19, #TC_W_USERS_WIDTH]
    bl tc_putu64
    LEA x0, s_w_found
    bl tc_puts
    ldr x0, [x19, #TC_W_USERS_FOUND]
    bl tc_putu64
    LEA x0, s_w_req
    bl tc_puts
    ldr x0, [x19, #TC_W_USERS_REQ]
    bl tc_putu64
    LEA x0, s_newline
    bl tc_puts
    // ---- listing ----
    LEA x19, tc_listing
    LEA x0, s_listing
    bl tc_puts
    ldr x0, [x19, #TC_L_COUNT]
    bl tc_putu64
    LEA x0, s_newline
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
    LEA x0, s_space
    bl tc_puts
    add x0, x23, #TC_L_NAME
    bl tc_puts
    LEA x0, s_newline
    bl tc_puts
    add x22, x22, #1
    b .Ldump_list
.Ldump_list_done:
    // ---- users ----
    LEA x19, tc_users
    LEA x0, s_users
    bl tc_puts
    ldr x0, [x19, #TC_US_COUNT]
    bl tc_putu64
    LEA x0, s_newline
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
    LEA x0, s_space
    bl tc_puts
    ldr x0, [x23, #TC_US_LIVE]
    bl tc_putu64
    LEA x0, s_space
    bl tc_puts
    ldr x0, [x23, #TC_US_OFFLINE]
    bl tc_putu64
    LEA x0, s_space
    bl tc_puts
    ldr x0, [x23, #TC_US_UNKNOWN]
    bl tc_putu64
    LEA x0, s_newline
    bl tc_puts
    add x22, x22, #1
    b .Ldump_users
.Ldump_users_done:
    // ---- tally ----
    LEA x19, tc_tally
    LEA x0, s_t_files
    bl tc_puts
    ldr x0, [x19, #TC_T_FILES]
    bl tc_putu64
    LEA x0, s_t_messages
    bl tc_puts
    ldr x0, [x19, #TC_T_MESSAGES]
    bl tc_putu64
    LEA x0, s_t_parsed
    bl tc_puts
    ldr x0, [x19, #TC_T_PARSED]
    bl tc_putu64
    LEA x0, s_t_states
    bl tc_puts
    ldr x0, [x19, #TC_T_STATES + 0]
    bl tc_putu64
    LEA x0, s_colon
    bl tc_puts
    ldr x0, [x19, #TC_T_STATES + 8]
    bl tc_putu64
    LEA x0, s_colon
    bl tc_puts
    ldr x0, [x19, #TC_T_STATES + 16]
    bl tc_putu64
    LEA x0, s_t_excl
    bl tc_puts
    ldr x0, [x19, #TC_T_EXCLUDED_STATES + 0]
    bl tc_putu64
    LEA x0, s_colon
    bl tc_puts
    ldr x0, [x19, #TC_T_EXCLUDED_STATES + 8]
    bl tc_putu64
    LEA x0, s_colon
    bl tc_puts
    ldr x0, [x19, #TC_T_EXCLUDED_STATES + 16]
    bl tc_putu64
    LEA x0, s_t_unreadable
    bl tc_puts
    ldr x0, [x19, #TC_T_UNR_COUNT]
    bl tc_putu64
    LEA x0, s_newline
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
    LEA x0, s_unr
    bl tc_puts
    mov x0, x23
    bl tc_puts                          // name
    LEA x0, s_space
    bl tc_puts
    add x0, x23, #TC_T_UNR_NAME_SZ
    bl tc_puts                          // reason
    LEA x0, s_newline
    bl tc_puts
    add x22, x22, #1
    b .Ldump_unr
.Ldump_unr_done:
    EPILOGUE 5
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
s_t_states:     .asciz " states="
s_t_excl:       .asciz " excl="
s_t_unreadable: .asciz " unreadable="
s_unr:          .asciz "unreadable "

    .end