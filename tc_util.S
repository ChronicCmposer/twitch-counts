// ============================================================================
// tc_util.S — shared utilities for twitch-counts-full (split from tc_entry.S)
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//
//  This module owns every .global utility the other tc_*.S modules share.
//  The split from tc_entry.S (Wave A, Phase 2): utilities live here,
//  main() lives in tc_main.S.
//
//  Exported (all .global, AAPCS64, x19-x28 preserved):
//    tc_strlen(x0=s)          -> x0 = byte length of a NUL-terminated string
//    tc_puts(x0=s)            print string to stdout (flushes stdio first)
//    tc_eputs(x0=s)           print string to stderr (unbuffered)
//    tc_putu64(x0=v)          print unsigned 64-bit decimal to stdout, no commas
//    tc_fail(x0=msg)          print "error: <msg>" to stderr, exit 1 (noreturn)
//    tc_snprintf_d(x0=buf, x1=size, x2=fmt, d0=value)  -> x0 = snprintf() result
//    tc_snprintf_i(x0=buf, x1=size, x2=fmt, x3=value)  -> x0 = snprintf() result
//    tc_ioctl_p(x0=fd, x1=request, x2=ptr)             -> x0 = ioctl() result
//      (fixed-arity wrappers for the variadic libc calls; see below and
//      tc_platform.h — modules never call snprintf/ioctl directly)
//
//  AAPCS64 notes (the rules every later phase must follow)
//  -------------------------------------------------------
//    * Arguments in x0-x7 (integer) / v0-v7 (float); return in x0 (x1 for
//      128-bit); composites are returned in x0..x3 or via x8 (sret).
//    * Callee-saved (must be preserved across any `bl` we make):
//      x19-x28, x29 (FP).  x30 (LR) is saved by the callee that calls.
//      x18 is the platform register — never touch it.
//    * sp must stay 16-byte aligned at every call site.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
    .text

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ STDOUT, 1                   // standard output file descriptor
    .equ STDERR, 2                   // standard error file descriptor

// ----------------------------------------------------------------------------
// tc_strlen — length of a NUL-terminated string.
//   in:  x0 = pointer to the string
//   out: x0 = number of bytes before the NUL
//   Clobbers x0-x2 only; preserves x19-x28 and the stack.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_strlen
    FUNC_TYPE(tc_strlen)
tc_strlen:
    mov x1, x0                      // x1 = scan pointer
.Lstrlen_loop:
    ldrb w2, [x1], #1               // next byte
    cbnz w2, .Lstrlen_loop          // until the NUL
    sub x0, x1, x0                  // length = end - start
    sub x0, x0, #1                  // the NUL is not counted
    ret

// ----------------------------------------------------------------------------
// tc_puts — write a NUL-terminated string to stdout.
//   in:  x0 = pointer to the string
//   out: none
//   Flushes stdio stdout first so buffered printf output is never reordered
//   behind this raw write; the write itself is unbuffered.  Preserves
//   x19-x28; sp stays 16-aligned.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_puts
    FUNC_TYPE(tc_puts)
tc_puts:
    stp x19, x30, [sp, #-16]!       // save x19 (held string) + return address
    mov x19, x0                     // x19 = string (safe across calls)
    mov x0, #0                      // fflush(NULL): order this write after stdio
    bl fflush
    mov x0, x19
    bl tc_strlen                    // x0 = length
    mov x2, x0                      // write(1, string, length)
    mov x0, #STDOUT
    mov x1, x19
    bl write
    ldp x19, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_eputs — write a NUL-terminated string to stderr (unbuffered).
//   in:  x0 = pointer to the string
//   Preserves x19-x28; sp stays 16-aligned.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_eputs
    FUNC_TYPE(tc_eputs)
tc_eputs:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    bl tc_strlen
    mov x2, x0                      // write(2, string, length)
    mov x0, #STDERR
    mov x1, x19
    bl write
    ldp x19, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_putu64 — print an unsigned 64-bit value in decimal to stdout (no commas).
//   in:  x0 = the value
//   out: none
//   Digits are produced least-significant first into a 32-byte stack frame
//   (20 digits + NUL), then handed to tc_puts.  Preserves x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_putu64
    FUNC_TYPE(tc_putu64)
tc_putu64:
    stp x19, x30, [sp, #-16]!       // save x19 (running value) + return address
    sub sp, sp, #32                 // 21-byte digit buffer (32 keeps 16-aligned)
    mov x19, x0                     // x19 = value (safe across tc_puts)
    add x1, sp, #20                 // write digits downward from buf+20
    mov x2, #0                      // x2 = digit count
    cmp x19, #0
    b.ne .Lputu_digit_loop
    mov x3, #'0'                    // zero case: emit a single '0'
    strb w3, [x1, #-1]!
    mov x2, #1
    b .Lputu_done
.Lputu_digit_loop:
    mov x4, #10
    udiv x5, x19, x4                // quotient
    msub x6, x5, x4, x19            // remainder
    add x6, x6, #'0'                // remainder -> ASCII digit
    strb w6, [x1, #-1]!             // store digit, walk the pointer down
    add x2, x2, #1
    mov x19, x5                     // continue with the quotient
    cbnz x19, .Lputu_digit_loop
.Lputu_done:
    mov x0, #0
    strb w0, [x1, x2]               // NUL at buf+20 -> digits are a C string
    mov x0, x1                      // tc_puts(first_digit)
    bl tc_puts
    add sp, sp, #32
    ldp x19, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_fail — print "error: <message>" to stderr and exit 1.
//   in:  x0 = NUL-terminated message
//   Flushes all stdio first so buffered stdout is not lost.  Never returns.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_fail
    FUNC_TYPE(tc_fail)
tc_fail:
    stp x19, x30, [sp, #-16]!
    mov x19, x0                     // x19 = message
    mov x0, #0                      // fflush(NULL)
    bl fflush
    mov x0, #STDERR                 // write(2, "error: ", err_prefix_len)
    adrp x1, PAGE(err_prefix)
    add x1, x1, LO12(err_prefix)
    mov x2, #err_prefix_len
    bl write
    mov x0, x19                     // tc_eputs(message)
    bl tc_eputs
    mov x0, #STDERR                 // write(2, "\n", err_newline_len)
    adrp x1, PAGE(err_newline)
    add x1, x1, LO12(err_newline)
    mov x2, #err_newline_len
    bl write
    mov w0, #1                      // exit(1)
    bl exit

// ----------------------------------------------------------------------------
// Fixed-arity wrappers for the variadic libc calls the modules make.
//
//   tc_snprintf_d(x0=buf, x1=size, x2=fmt, d0=value)  -> x0 = int
//   tc_snprintf_i(x0=buf, x1=size, x2=fmt, x3=value)  -> x0 = int
//   tc_ioctl_p(x0=fd, x1=request, x2=ptr)             -> x0 = int
//
//   Call sites set the registers up exactly as for the libc function and
//   only differ in the `bl` target.  On Linux (AAPCS64) the one anonymous
//   argument is already where snprintf/ioctl read it, so the wrapper is a
//   tail call.  On Darwin arm64 anonymous arguments are passed in 8-byte
//   STACK slots starting at the callee's sp, so the wrapper opens a 32-byte
//   frame — [sp,#0] the argument slot, [sp,#16] saved x29/x30 — stores the
//   argument, calls, and unwinds.  Like the libc call they wrap, the
//   wrappers clobber x0-x17 and preserve x19-x28; sp stays 16-aligned.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_snprintf_d
    FUNC_TYPE(tc_snprintf_d)
tc_snprintf_d:
#ifdef __APPLE__
    sub sp, sp, #32
    stp x29, x30, [sp, #16]
    str d0, [sp]                    // the double goes in the first vararg slot
    bl snprintf
    ldp x29, x30, [sp, #16]
    add sp, sp, #32
    ret
#else
    b snprintf                      // d0 is already the first anonymous argument
#endif

    .p2align 2
    .global tc_snprintf_i
    FUNC_TYPE(tc_snprintf_i)
tc_snprintf_i:
#ifdef __APPLE__
    sub sp, sp, #32
    stp x29, x30, [sp, #16]
    str x3, [sp]                    // %d reads the low 32 bits of the slot
    bl snprintf
    ldp x29, x30, [sp, #16]
    add sp, sp, #32
    ret
#else
    b snprintf                      // x3 is already the first anonymous argument
#endif

    .p2align 2
    .global tc_ioctl_p
    FUNC_TYPE(tc_ioctl_p)
tc_ioctl_p:
#ifdef __APPLE__
    sub sp, sp, #32
    stp x29, x30, [sp, #16]
    str x2, [sp]                    // the pointer is ioctl's anonymous argument
    bl ioctl
    ldp x29, x30, [sp, #16]
    add sp, sp, #32
    ret
#else
    b ioctl                         // x2 is already the anonymous argument
#endif

// ----------------------------------------------------------------------------
// Read-only message data.  Lengths are label differences so the writer and
// the .equ can never drift apart.
// ----------------------------------------------------------------------------
    RODATA
err_prefix:
    .ascii "error: "
err_prefix_end:
    .equ err_prefix_len, err_prefix_end - err_prefix
err_newline:
    .ascii "\n"
err_newline_end:
    .equ err_newline_len, err_newline_end - err_newline

    .end
