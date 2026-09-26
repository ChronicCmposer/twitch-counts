// ============================================================================
// check_tc_printf.S — fixed-arity printf wrappers for the harness drivers
// ============================================================================
//
//  The check_tc_cli.S / check_tc_config.S drivers report through printf.
//  printf is variadic, and on Darwin arm64 anonymous arguments travel in
//  8-byte stack slots at the callee's sp rather than in x1..x7, so the
//  drivers call these wrappers by SHAPE instead of printf directly:
//
//    tc_printf_i (x0=fmt, x1=int)                   one integer
//    tc_printf_p (x0=fmt, x1=ptr)                   one pointer (same body)
//    tc_printf_ii(x0=fmt, x1=int, x2=int)           two integers
//    tc_printf_ip(x0=fmt, x1=int, x2=ptr)           "%.*s" (same body)
//    tc_printf_7i(x0=fmt, x1..x7)                   seven integers
//
//  A printf with no anonymous argument is called directly.  Register setup
//  at the call site is exactly as for printf; only the `bl` target differs.
//  On Linux every wrapper is a tail call.  Each wrapper clobbers x0-x17,
//  preserves x19-x28 and keeps sp 16-aligned.  Linked into the drivers
//  that print (tc-cli-test, tc-config-test) by the Makefile; never into
//  twitch-counts.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
    .text

    .p2align 2
    .global tc_printf_i
    .global tc_printf_p
    FUNC_TYPE(tc_printf_i)
    FUNC_TYPE(tc_printf_p)
tc_printf_i:
tc_printf_p:
#ifdef __APPLE__
    sub sp, sp, #32
    stp x29, x30, [sp, #16]
    str x1, [sp]
    bl printf
    ldp x29, x30, [sp, #16]
    add sp, sp, #32
    ret
#else
    b printf
#endif

    .p2align 2
    .global tc_printf_ii
    .global tc_printf_ip
    FUNC_TYPE(tc_printf_ii)
    FUNC_TYPE(tc_printf_ip)
tc_printf_ii:
tc_printf_ip:
#ifdef __APPLE__
    sub sp, sp, #32
    stp x29, x30, [sp, #16]
    stp x1, x2, [sp]
    bl printf
    ldp x29, x30, [sp, #16]
    add sp, sp, #32
    ret
#else
    b printf
#endif

    .p2align 2
    .global tc_printf_7i
    FUNC_TYPE(tc_printf_7i)
tc_printf_7i:
#ifdef __APPLE__
    sub sp, sp, #80                 // 7 slots (56, padded to 64) + x29/x30
    stp x29, x30, [sp, #64]
    stp x1, x2, [sp]
    stp x3, x4, [sp, #16]
    stp x5, x6, [sp, #32]
    str x7, [sp, #48]
    bl printf
    ldp x29, x30, [sp, #64]
    add sp, sp, #80
    ret
#else
    b printf
#endif

    .end
