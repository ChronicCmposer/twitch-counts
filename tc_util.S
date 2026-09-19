// ============================================================================
// tc_util.S — shared utilities for twitch-counts-full
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//
//  This module owns every .global utility the other tc_*.S modules share;
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
//    tc_expanduser(x0=src, x1=dst, x2=cap)             -> x0 = len (CPython expanduser)
//    tc_shorten_path(x0=path)                          -> x0 = ptr (CPython shorten_path)
//    tc_default_config_path(x0=dst, x1=cap)            -> x0 = len (platform class)
//    tc_platform_default_logs_dir(x0=dst, x1=cap)      -> x0 = len, 0 = no default
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
    LEA x1, err_prefix
    mov x2, #err_prefix_len
    bl write
    mov x0, x19                     // tc_eputs(message)
    bl tc_eputs
    mov x0, #STDERR                 // write(2, "\n", err_newline_len)
    LEA x1, err_newline
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

// ============================================================================
// Path helpers shared by every module (Python os.path.expanduser /
// shorten_path and the platform class's default paths).  They live here so
// every driver links them (tc-cli-test links the config stub, not
// tc_config.o).
// ============================================================================
    .equ PATH_SCRATCH_SZ, 1024

    .bss
    .p2align 3
tc_path_scratch:    .skip PATH_SCRATCH_SZ   // tc_shorten_path result
tc_path_scratch2:   .skip PATH_SCRATCH_SZ   // expanded home / user name
    .text

// pu_copy_n(x0=dst, x1=src, x2=n) -- copy n bytes and a NUL (clobbers x0-x3)
    .p2align 2
pu_copy_n:
    mov x3, #0
.Lpuc_loop:
    cmp x3, x2
    b.ge .Lpuc_done
    ldrb w9, [x1, x3]
    strb w9, [x0, x3]
    add x3, x3, #1
    b .Lpuc_loop
.Lpuc_done:
    strb wzr, [x0, x2]
    ret

// pu_cat(x0=dst, x1=src) -> x0 = end (at the NUL); clobbers x0-x2
    .p2align 2
pu_cat:
.Lpuk_loop:
    ldrb w2, [x1], #1
    strb w2, [x0], #1
    cbnz w2, .Lpuk_loop
    sub x0, x0, #1
    ret

// ----------------------------------------------------------------------------
// tc_expanduser(x0=src, x1=dst, x2=cap) -> x0 = length of dst
//   CPython posixpath.expanduser, exactly:
//     not starting with "~"      -> src copied unchanged
//     "~" / "~/rest"             -> home + rest, where home is $HOME when the
//                                   variable is PRESENT (even empty), else
//                                   getpwuid(getuid())->pw_dir; src unchanged
//                                   if that lookup fails
//     "~user" / "~user/rest"     -> getpwnam(user)->pw_dir + rest; src
//                                   unchanged if there is no such user
//   The home is stripped of trailing '/'; an empty result becomes "/".
//   dst is NUL-terminated; a result that does not fit in cap bytes is fatal.
//   Preserves x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_expanduser
    FUNC_TYPE(tc_expanduser)
tc_expanduser:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // src
    mov x20, x1                     // dst
    mov x21, x2                     // cap
    ldrb w9, [x19]
    cmp w9, #'~'
    b.ne .Lxpu_unchanged
    // i = index of the first '/' after the '~', or the string length
    mov x22, #1
.Lxpu_find:
    ldrb w9, [x19, x22]
    cbz w9, .Lxpu_found
    cmp w9, #'/'
    b.eq .Lxpu_found
    add x22, x22, #1
    b .Lxpu_find
.Lxpu_found:
    cmp x22, #1
    b.ne .Lxpu_named
    LEA x0, pu_s_home
    bl getenv
    cbz x0, .Lxpu_self_pwd
    mov x23, x0                     // home = $HOME (may be empty)
    b .Lxpu_have_home
.Lxpu_self_pwd:
    bl getuid
    bl getpwuid
    cbz x0, .Lxpu_unchanged
    ldr x23, [x0, #PW_DIR_OFF]
    cbz x23, .Lxpu_unchanged
    b .Lxpu_have_home
.Lxpu_named:
    // the user name src[1:i] goes into tc_path_scratch2 for getpwnam
    sub x9, x22, #1                 // name length
    cmp x9, #PATH_SCRATCH_SZ - 1
    b.ge .Lxpu_unchanged
    LEA x0, tc_path_scratch2
    add x1, x19, #1
    mov x2, x9
    bl pu_copy_n
    LEA x0, tc_path_scratch2
    bl getpwnam
    cbz x0, .Lxpu_unchanged
    ldr x23, [x0, #PW_DIR_OFF]
    cbz x23, .Lxpu_unchanged
.Lxpu_have_home:
    // x24 = len(home) with trailing '/' stripped
    mov x0, x23
    bl tc_strlen
    mov x24, x0
.Lxpu_rstrip:
    cbz x24, .Lxpu_rest
    sub x9, x24, #1
    ldrb w9, [x23, x9]
    cmp w9, #'/'
    b.ne .Lxpu_rest
    sub x24, x24, #1
    b .Lxpu_rstrip
.Lxpu_rest:
    // total = len(home) + len(src[i:]); it must fit with its NUL in cap
    add x0, x19, x22
    bl tc_strlen
    add x9, x24, x0
    cmp x9, x21
    b.ge .Lxpu_too_long
    cbz x9, .Lxpu_root
    mov x0, x20
    mov x1, x23
    mov x2, x24
    bl pu_copy_n                   // the stripped home
    add x0, x20, x24
    add x1, x19, x22
    bl pu_cat                     // + src[i:]  (x0 = end)
    sub x0, x0, x20
    b .Lxpu_out
.Lxpu_root:
    mov w9, #'/'
    strb w9, [x20]
    strb wzr, [x20, #1]
    mov x0, #1
    b .Lxpu_out
.Lxpu_unchanged:
    mov x0, x19
    bl tc_strlen
    mov x24, x0
    add x9, x24, #1
    cmp x9, x21
    b.gt .Lxpu_too_long
    mov x0, x20
    mov x1, x19
    mov x2, x24
    bl pu_copy_n
    mov x0, x24
.Lxpu_out:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lxpu_too_long:
    LEA x0, pu_s_too_long
    bl tc_fail

// ----------------------------------------------------------------------------
// tc_platform_default_logs_dir(x0=dst, x1=cap) -> x0 = length (0: no default)
//   Python PLATFORM.logs_dir(): the MacOS class returns
//   expanduser("~/Library/Application Support/chatterino/Logs/Twitch/Channels");
//   the Linux class returns None.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_platform_default_logs_dir
    FUNC_TYPE(tc_platform_default_logs_dir)
tc_platform_default_logs_dir:
#ifdef __APPLE__
    stp x29, x30, [sp, #-16]!
    mov x2, x1
    mov x1, x0
    LEA x0, pu_s_mac_logs_dir
    bl tc_expanduser
    ldp x29, x30, [sp], #16
    ret
#else
    mov x0, #0
    ret
#endif

// ----------------------------------------------------------------------------
// tc_default_config_path(x0=dst, x1=cap) -> x0 = length
//   Python DEFAULT_CONFIG_PATH = PLATFORM.config_path():
//     MacOS: expanduser("~/.config/twitch-counts.toml")   (XDG_* ignored)
//     Linux: os.path.join(XDG_CONFIG_HOME or expanduser("~/.config"),
//                         "twitch-counts.toml") -- an empty variable counts
//            as unset, a set one is used verbatim (no ~ expansion).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_default_config_path
    FUNC_TYPE(tc_default_config_path)
tc_default_config_path:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // dst
    mov x20, x1                     // cap
#ifndef __APPLE__
    LEA x0, pu_s_xdg_config
    bl getenv
    cbz x0, .Ldcp_home
    ldrb w1, [x0]
    cbz w1, .Ldcp_home
    mov x21, x0                     // XDG_CONFIG_HOME, verbatim
    bl tc_strlen
    mov x22, x0                     // its length
    // os.path.join: add a '/' only when the base does not already end in one
    add x9, x22, #20                // + "/twitch-counts.toml" + NUL
    cmp x9, x20
    b.ge .Ldcp_too_long
    mov x0, x19
    mov x1, x21
    mov x2, x22
    bl pu_copy_n
    add x0, x19, x22
    sub x9, x22, #1
    ldrb w9, [x21, x9]
    LEA x1, pu_s_config_tail  // "/twitch-counts.toml"
    cmp w9, #'/'
    b.ne .Ldcp_join
    add x1, x1, #1                  // "twitch-counts.toml"
.Ldcp_join:
    bl pu_cat
    sub x0, x0, x19
    b .Ldcp_out
.Ldcp_too_long:
    LEA x0, pu_s_too_long
    bl tc_fail
.Ldcp_home:
#endif
    LEA x0, pu_s_default_config
    mov x1, x19
    mov x2, x20
    bl tc_expanduser
.Ldcp_out:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_shorten_path(x0=path) -> x0 = pointer to the shortened path.
//   Python shorten_path: home = expanduser("~"); path.replace(home, "~", 1)
//   when path.startswith(home), else path.  With an empty HOME the home is
//   "/" and every absolute path shortens to "~" + the rest without its
//   leading slash -- that is what the Python prints, so it is mirrored.
//   The result lives in tc_path_scratch (or is the input pointer itself).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_shorten_path
    FUNC_TYPE(tc_shorten_path)
tc_shorten_path:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // path
    LEA x0, pu_s_tilde
    LEA x1, tc_path_scratch2
    mov x2, #PATH_SCRATCH_SZ
    bl tc_expanduser
    mov x20, x0                     // home length
    cbz x20, .Lsp_orig
    mov x0, x19
    bl tc_strlen
    mov x21, x0                     // path length
    cmp x21, x20
    b.lt .Lsp_orig
    // path.startswith(home)?
    LEA x22, tc_path_scratch2
    mov x9, #0
.Lsp_cmp:
    cmp x9, x20
    b.ge .Lsp_hit
    ldrb w10, [x19, x9]
    ldrb w11, [x22, x9]
    cmp w10, w11
    b.ne .Lsp_orig
    add x9, x9, #1
    b .Lsp_cmp
.Lsp_hit:
    sub x9, x21, x20                // rest length
    add x9, x9, #2                  // + '~' + NUL
    cmp x9, #PATH_SCRATCH_SZ
    b.gt .Lsp_orig
    LEA x0, tc_path_scratch
    mov w1, #'~'
    strb w1, [x0], #1
    add x1, x19, x20
    sub x2, x21, x20
    bl pu_copy_n
    LEA x0, tc_path_scratch
    b .Lsp_done
.Lsp_orig:
    mov x0, x19
.Lsp_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

    RODATA
pu_s_home:            .asciz "HOME"
pu_s_xdg_config:      .asciz "XDG_CONFIG_HOME"
pu_s_config_tail:     .asciz "/twitch-counts.toml"
pu_s_default_config:  .asciz "~/.config/twitch-counts.toml"
pu_s_tilde:           .asciz "~"
pu_s_too_long:        .asciz "path too long"
#ifdef __APPLE__
pu_s_mac_logs_dir:    .asciz "~/Library/Application Support/chatterino/Logs/Twitch/Channels"
#endif
    .text

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

    .text
// ----------------------------------------------------------------------------
// tc_env_int(x0=name) -> x0 = int(os.environ[name]) when the variable is set
//   to a positive integer, else 0.  Python's int() grammar for what matters
//   here: surrounding whitespace, an optional sign, digits with single '_'
//   separators; anything else is a ValueError, and a value <= 0 is treated
//   the same way by shutil.get_terminal_size (both mean "ask the terminal").
//   Preserves x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_env_int
    FUNC_TYPE(tc_env_int)
tc_env_int:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    bl getenv
    cbz x0, .Lei_none
    mov x19, x0
.Lei_lead:
    ldrb w0, [x19]
    bl ei_is_space
    cbz w0, .Lei_sign
    add x19, x19, #1
    b .Lei_lead
.Lei_sign:
    ldrb w0, [x19]
    cmp w0, #'-'
    b.eq .Lei_none                  // negative: "<= 0" -> the terminal decides
    cmp w0, #'+'
    b.ne .Lei_digits
    add x19, x19, #1
.Lei_digits:
    mov x20, #0                     // value
    mov x21, #0                     // digits seen
    mov x22, #0                     // previous byte was '_'
.Lei_loop:
    ldrb w0, [x19]
    cmp w0, #'_'
    b.ne .Lei_not_us
    cbz x21, .Lei_none              // '_' before any digit
    cbnz x22, .Lei_none             // '__'
    mov x22, #1
    add x19, x19, #1
    b .Lei_loop
.Lei_not_us:
    cmp w0, #'0'
    b.lt .Lei_end
    cmp w0, #'9'
    b.gt .Lei_end
    sub w0, w0, #'0'
    mov x1, #10
    mul x20, x20, x1
    add x20, x20, x0
    mov x1, #0x7fffffff
    cmp x20, x1
    b.le .Lei_digit_ok
    mov x20, x1                     // saturate: large is large
.Lei_digit_ok:
    mov x21, #1
    mov x22, #0
    add x19, x19, #1
    b .Lei_loop
.Lei_end:
    cbz x21, .Lei_none              // no digits
    cbnz x22, .Lei_none             // trailing '_'
.Lei_trail:
    ldrb w0, [x19]
    cbz w0, .Lei_done
    bl ei_is_space
    cbz w0, .Lei_none               // junk after the number
    add x19, x19, #1
    b .Lei_trail
.Lei_done:
    mov x0, x20
    b .Lei_ret
.Lei_none:
    mov x0, #0
.Lei_ret:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ei_is_space(w0=byte) -> w0 = 1 for ASCII whitespace (space, \t\n\v\f\r)
    .p2align 2
ei_is_space:
    cmp w0, #' '
    b.eq .Leis_yes
    cmp w0, #9
    b.lt .Leis_no
    cmp w0, #13
    b.le .Leis_yes
.Leis_no:
    mov w0, #0
    ret
.Leis_yes:
    mov w0, #1
    ret

// ----------------------------------------------------------------------------
// tc_term_columns() / tc_term_lines() -> x0: shutil.get_terminal_size(
//   fallback=(80, 24)).columns / .lines.  $COLUMNS / $LINES first, then
//   TIOCGWINSZ on fd 1 (sys.__stdout__), a 0 from the terminal or a failed
//   ioctl -> the fallback.  Preserve x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_term_columns
    FUNC_TYPE(tc_term_columns)
tc_term_columns:
    stp x29, x30, [sp, #-16]!
    LEA x0, ts_s_columns
    bl tc_env_int
    cbnz x0, .Ltc_ret
    mov x0, #2                      // ws_col offset
    bl ts_winsize_field
    cbnz x0, .Ltc_ret
    mov x0, #80
.Ltc_ret:
    ldp x29, x30, [sp], #16
    ret

    .p2align 2
    .global tc_term_lines
    FUNC_TYPE(tc_term_lines)
tc_term_lines:
    stp x29, x30, [sp, #-16]!
    LEA x0, ts_s_lines
    bl tc_env_int
    cbnz x0, .Ltl_ret
    mov x0, #0                      // ws_row offset
    bl ts_winsize_field
    cbnz x0, .Ltl_ret
    mov x0, #24
.Ltl_ret:
    ldp x29, x30, [sp], #16
    ret

// ts_winsize_field(x0=offset) -> x0 = that u16 of TIOCGWINSZ on fd 1, or 0
    .p2align 2
ts_winsize_field:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #16
    mov x19, x0
    mov x0, #1
    ldr x1, =TIOCGWINSZ
    mov x2, sp
    bl tc_ioctl_p
    cmp w0, #0
    b.ne .Ltw_none
    ldrh w0, [sp, x19]
    b .Ltw_ret
.Ltw_none:
    mov x0, #0
.Ltw_ret:
    add sp, sp, #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

    RODATA
ts_s_columns:         .asciz "COLUMNS"
ts_s_lines:           .asciz "LINES"
    .text

    .end
