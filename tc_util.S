// ============================================================================
// tc_util.S — shared utilities for twitch-counts
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
//    tc_cat_cstr(x0=cursor, x1=s)  -> x0 = position of the copied NUL
//    tc_copy_str_cap(x0=dst, x1=src, x2=cap) -> x0 = dst, copies up to
//      cap-1 bytes + NUL (bounded string copy; no return cursor)
//    tc_cat_cstr_cap(x0=cursor, x1=s, x2=cap) -> x0 = cursor at the NUL,
//      bounded append (writes at most cap-1 bytes + NUL)
//    tc_streq(x0=a, x1=b)          -> x0 = 1/0
//    tc_fmt2(x0=dst, x1=v) / tc_fmt4  -> x0 = dst+2 / dst+4 (zero-padded digits)
//    tc_days_from_civil(x0=y, x1=m, x2=d) -> x0 = days since 1970-01-01
//    tc_civil_from_days(x0=days)   -> x0=y, x1=m, x2=d
//    tc_is_leap(x0=y)              -> x0 = 1/0
//    tc_days_in_month(x0=y, x1=m)  -> x0 = 28..31
//    tc_ymd_sod_to_epoch(x0=ymd, x1=sod) -> x0 = epoch seconds
//    tc_epoch_to_ymd_sod(x0=epoch) -> x0 = ymd, x1 = sod
//      (these ten clobber only their outputs; see the block at the end)
//  Shared formatters / helpers for the later phases (each documents its own
//  clobber contract in its header comment):
//    tc_fmt_u64(x0=dst, x1=v)            -> x0 = dst+digits (no NUL)
//    tc_fmt_pad(x0=dst, x1=v, x2=width)  -> x0 = dst+width (zero-padded, no NUL)
//    tc_fmt_ymd_sod(x0=dst, x1=ymd, x2=sod, x3=sep) -> x0 = dst+19
//    tc_ymd_split(x0=ymd)                -> x0=y, x1=m, x2=d
//    tc_sod_split(x0=sod)                -> x0=hour, x1=minute, x2=second
//    tc_is_ws(x0=byte)                   -> x0 = 1 for ASCII whitespace
//    tc_copy_bytes(x0=dst, x1=src, x2=len) -> x0 = dst+len
//    tc_read_all(x0=path, x1=cap)        -> x0=status, x1=buf, x2=len
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
#include "tc_layout.inc"
    .arch armv8-a
    .text

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
// DIV10_MAGIC, SWAR_MASK_01/SWAR_MASK_80, NANOSEC and the MOV_* load macros
// live in tc_platform.h (shared, fail-loud against module-local .equ copies).

// ----------------------------------------------------------------------------
// tc_strlen — length of a NUL-terminated string.
//   in:  x0 = pointer to the string
//   out: x0 = number of bytes before the NUL
//   Word-at-a-time: align to 8 with a byte walk (checking for the NUL as we
//   go), then scan 8-byte words with the has-zero-byte trick
//   ((w - 0x0101..01) & ~w & 0x8080..80); aligned 8-byte loads never cross a
//   page, so the scan cannot fault past the NUL.  x3/x4 are saved so the
//   clobber set stays exactly x0-x2, as the callers were written against.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_strlen
    FUNC_TYPE(tc_strlen)
tc_strlen:
    stp x3, x4, [sp, #-16]!         // honor the x0-x2-only clobber contract
    mov x1, x0                      // x1 = scan pointer
    and x3, x1, #7                  // already 8-aligned?
    cbz x3, .Lslw_word
.Lslw_align:
    ldrb w2, [x1], #1               // byte walk until aligned
    cbz w2, .Lslw_nul_align         // NUL before the first word
    and x3, x1, #7
    cbnz x3, .Lslw_align
.Lslw_word:
    mov x2, #SWAR_MASK_01            // the 0x01..01 mask
.Lslw_loop:
    ldr x3, [x1]                    // next word
    sub x4, x3, x2                  // w - 0x01..01
    bic x4, x4, x3                  // & ~w
    and x4, x4, x2, lsl #7          // & 0x80..80: set bit 7 per zero byte
    cbnz x4, .Lslw_zero
    add x1, x1, #8
    b .Lslw_loop
.Lslw_zero:
    rbit x4, x4                     // lowest zero byte -> highest bit
    clz x4, x4
    lsr x4, x4, #3                  // byte index of the NUL in this word
    add x1, x1, x4                  // x1 = &NUL
    sub x0, x1, x0                  // length = NUL - start
    ldp x3, x4, [sp], #16
    ret
.Lslw_nul_align:
    sub x0, x1, x0                  // x1 = one past the NUL
    sub x0, x0, #1
    ldp x3, x4, [sp], #16
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
    ldr x4, =DIV10_MAGIC            // divide-by-10 magic (umulh >> 3)
    cmp x19, #0
    b.ne .Lputu_digit_loop
    mov x3, #'0'                    // zero case: emit a single '0'
    strb w3, [x1, #-1]!
    mov x2, #1
    b .Lputu_done
.Lputu_digit_loop:
    umulh x5, x19, x4               // quotient = value / 10
    lsr x5, x5, #3
    mov x3, #10
    msub x6, x5, x3, x19            // remainder
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
util_path_scratch:    .skip PATH_SCRATCH_SZ   // tc_shorten_path result
util_path_scratch2:   .skip PATH_SCRATCH_SZ   // expanded home / user name
    .text

// util_pu_copy_n(x0=dst, x1=src, x2=n) -- copy n bytes and a NUL
//   (clobbers x0-x3, x9-x10; callers keep their live state in x19+)
    .p2align 2
util_pu_copy_n:
    mov x3, x2                      // remaining
.Lpuc_w16:
    cmp x3, #16
    b.lt .Lpuc_w8
    ldp x9, x10, [x1], #16
    stp x9, x10, [x0], #16
    sub x3, x3, #16
    b .Lpuc_w16
.Lpuc_w8:
    cmp x3, #8
    b.lt .Lpuc_tail
    ldr x9, [x1], #8
    str x9, [x0], #8
    sub x3, x3, #8
.Lpuc_tail:
    cbz x3, .Lpuc_done
    ldrb w9, [x1], #1
    strb w9, [x0], #1
    sub x3, x3, #1
    b .Lpuc_tail
.Lpuc_done:
    strb wzr, [x0]
    ret

// util_pu_cat(x0=dst, x1=src) -> x0 = end (at the NUL); clobbers x0-x3, x9-x10
//   (length via tc_strlen, then util_pu_copy_n; LR is saved because this
//   routine makes calls)
    .p2align 2
util_pu_cat:
    stp x29, x30, [sp, #-16]!       // keep the return address across tc_strlen
    mov x9, x0                      // dst (caller-saved scratch)
    mov x3, x1                      // src survives the strlen call
    mov x0, x1
    bl tc_strlen
    mov x2, x0                      // n
    mov x0, x9
    mov x1, x3
    bl util_pu_copy_n               // x0 = dst+n (position of the NUL)
    ldp x29, x30, [sp], #16
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
    PROLOGUE 3
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
    // the user name src[1:i] goes into util_path_scratch2 for getpwnam
    sub x9, x22, #1                 // name length
    cmp x9, #PATH_SCRATCH_SZ - 1
    b.ge .Lxpu_unchanged
    LEA x0, util_path_scratch2
    add x1, x19, #1
    mov x2, x9
    bl util_pu_copy_n
    LEA x0, util_path_scratch2
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
    bl util_pu_copy_n                   // the stripped home
    add x0, x20, x24
    add x1, x19, x22
    bl util_pu_cat                     // + src[i:]  (x0 = end)
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
    bl util_pu_copy_n
    mov x0, x24
.Lxpu_out:
    EPILOGUE 3
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
    PROLOGUE 0
    mov x2, x1
    mov x1, x0
    LEA x0, pu_s_mac_logs_dir
    bl tc_expanduser
    EPILOGUE 0
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
    PROLOGUE 2
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
    bl util_pu_copy_n
    add x0, x19, x22
    sub x9, x22, #1
    ldrb w9, [x21, x9]
    LEA x1, pu_s_config_tail  // "/twitch-counts.toml"
    cmp w9, #'/'
    b.ne .Ldcp_join
    add x1, x1, #1                  // "twitch-counts.toml"
.Ldcp_join:
    bl util_pu_cat
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
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// tc_shorten_path(x0=path) -> x0 = pointer to the shortened path.
//   Python shorten_path: home = expanduser("~"); path.replace(home, "~", 1)
//   when path.startswith(home), else path.  With an empty HOME the home is
//   "/" and every absolute path shortens to "~" + the rest without its
//   leading slash -- that is what the Python prints, so it is mirrored.
//   The result lives in util_path_scratch (or is the input pointer itself).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_shorten_path
    FUNC_TYPE(tc_shorten_path)
tc_shorten_path:
    PROLOGUE 2
    mov x19, x0                     // path
    LEA x0, pu_s_tilde
    LEA x1, util_path_scratch2
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
    LEA x22, util_path_scratch2
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
    LEA x0, util_path_scratch
    mov w1, #'~'
    strb w1, [x0], #1
    add x1, x19, x20
    sub x2, x21, x20
    bl util_pu_copy_n
    LEA x0, util_path_scratch
    b .Lsp_done
.Lsp_orig:
    mov x0, x19
.Lsp_done:
    EPILOGUE 2
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
    PROLOGUE 2
    bl getenv
    cbz x0, .Lei_none
    mov x19, x0
.Lei_lead:
    ldrb w0, [x19]
    bl util_ei_is_space
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
    csel x20, x20, x1, le           // saturate: keep the value, else cap
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
    bl util_ei_is_space
    cbz w0, .Lei_none               // junk after the number
    add x19, x19, #1
    b .Lei_trail
.Lei_done:
    mov x0, x20
    b .Lei_ret
.Lei_none:
    mov x0, #0
.Lei_ret:
    EPILOGUE 2
    ret

// util_ei_is_space(w0=byte) -> w0 = 1 for ASCII whitespace (space, \t\n\v\f\r)
//   Tail-call alias of the exported tc_is_ws (identical predicate).
    .p2align 2
util_ei_is_space:
    b tc_is_ws

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
    PROLOGUE 0
    LEA x0, ts_s_columns
    bl tc_env_int
    cbnz x0, .Ltc_ret
    mov x0, #2                      // ws_col offset
    bl util_ts_winsize_field
    cbnz x0, .Ltc_ret
    mov x0, #80
.Ltc_ret:
    EPILOGUE 0
    ret

    .p2align 2
    .global tc_term_lines
    FUNC_TYPE(tc_term_lines)
tc_term_lines:
    PROLOGUE 0
    LEA x0, ts_s_lines
    bl tc_env_int
    cbnz x0, .Ltl_ret
    mov x0, #0                      // ws_row offset
    bl util_ts_winsize_field
    cbnz x0, .Ltl_ret
    mov x0, #24
.Ltl_ret:
    EPILOGUE 0
    ret

// util_ts_winsize_field(x0=offset) -> x0 = that u16 of TIOCGWINSZ on fd 1, or 0
    .p2align 2
util_ts_winsize_field:
    PROLOGUE 1
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
    EPILOGUE 1
    ret

    RODATA
ts_s_columns:         .asciz "COLUMNS"
ts_s_lines:           .asciz "LINES"
    .text


// ============================================================================
// Shared helpers that several modules used to carry private copies of.
// Every routine below clobbers ONLY its outputs (x0, plus x1/x2 where the
// contract names them): whatever a caller holds in the other caller-saved
// registers survives the call.  That is stricter than AAPCS64 on purpose --
// the former copies differed in what they scratched, and the callers were
// written against the copy they had.
// ============================================================================
    .text

// ----------------------------------------------------------------------------
// tc_cat_cstr(x0=cursor, x1=s) -> x0 = the position of the terminating NUL
//   (the string is copied NUL and all; callers overwrite the NUL with the
//   next thing they append).
//   Word-at-a-time: align the source to 8 with a byte walk (copying as we
//   go), then copy 8-byte words whole until one contains a NUL, then finish
//   byte-by-byte at the NUL.  Aligned loads never cross a page, and the
//   destination is never written past the NUL.  x2-x7 are saved, so the
//   routine still clobbers only x0 (its documented contract).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_cat_cstr
    FUNC_TYPE(tc_cat_cstr)
tc_cat_cstr:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    mov x2, x0                      // dst (advances)
    mov x3, x1                      // src (advances)
    mov x7, #SWAR_MASK_01            // the 0x01..01 mask
    and x5, x3, #7                  // source already 8-aligned?
    cbz x5, .Lcc_word
.Lcc_align:
    ldrb w4, [x3], #1
    strb w4, [x2], #1
    cbz w4, .Lcc_done_align         // NUL during the byte walk
    and x5, x3, #7
    cbnz x5, .Lcc_align
.Lcc_word:
    ldr x4, [x3]                    // next word
    sub x6, x4, x7
    bic x6, x6, x4
    and x5, x6, x7, lsl #7          // zero-byte mask
    cbnz x5, .Lcc_zero
    str x4, [x2]                    // whole word has no NUL: store it all
    add x2, x2, #8
    add x3, x3, #8
    b .Lcc_word
.Lcc_zero:
    rbit x5, x5
    clz x5, x5
    lsr x5, x5, #3                  // byte index of the NUL in this word
    mov x6, #0
.Lcc_tail:
    cmp x6, x5
    b.gt .Lcc_done
    ldrb w4, [x3, x6]               // store up to and including the NUL
    strb w4, [x2, x6]
    add x6, x6, #1
    b .Lcc_tail
.Lcc_done:
    add x0, x2, x5                  // x0 = position of the NUL
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret
.Lcc_done_align:
    sub x0, x2, #1                  // x2 = one past the NUL
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_copy_str_cap(x0=dst, x1=src, x2=cap) — bounded string copy: writes at
//   most cap-1 bytes plus a NUL (cap = capacity of dst).  Returns x0 = dst
//   unchanged (the CLI / config resolvers copy into their fixed option
//   fields, then read them back by pointer).  Clobbers x2-x3 only.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_copy_str_cap
    FUNC_TYPE(tc_copy_str_cap)
tc_copy_str_cap:
    cbz x2, .Lcsc_done
    sub x2, x2, #1
.Lcsc:
    ldrb w3, [x1], #1
    cbz w3, .Lcsc_nul
    strb w3, [x0], #1
    cbz x2, .Lcsc_full
    sub x2, x2, #1
    b .Lcsc
.Lcsc_nul:
    strb w3, [x0]
    ret
.Lcsc_full:
    mov w3, #0
    strb w3, [x0]
.Lcsc_done:
    ret

// ----------------------------------------------------------------------------
// tc_cat_cstr_cap(x0=cursor, x1=s, x2=cap) — bounded append; writes at most
//   cap-1 bytes plus a NUL (cap = bytes available from the cursor).
//   Returns the cursor at the NUL.  Call-free leaf: no frame, scratch regs
//   only (x0-x17 clobbered).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_cat_cstr_cap
    FUNC_TYPE(tc_cat_cstr_cap)
tc_cat_cstr_cap:
    mov x9, x0
    mov x10, x2                     // cap
    mov x2, #0                      // i
.Lccc_loop:
    sub x3, x10, #1
    cmp x2, x3
    b.ge .Lccc_full
    ldrb w3, [x1, x2]
    strb w3, [x9, x2]
    cbz w3, .Lccc_done
    add x2, x2, #1
    b .Lccc_loop
.Lccc_full:
    mov w3, #0
    strb w3, [x9, x2]
    add x9, x9, x2
    b .Lccc_out
.Lccc_done:
    // the NUL was copied at [x9 + x2]; return the cursor AT it so the
    // caller's next append overwrites it (cat_cstr semantics)
    add x9, x9, x2
.Lccc_out:
    mov x0, x9
    ret

// ----------------------------------------------------------------------------
// tc_streq(x0=a, x1=b) -> x0 = 1 when the strings are equal, else 0
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_streq
    FUNC_TYPE(tc_streq)
tc_streq:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    mov x2, x0
    mov x3, x1
.Lse_loop:
    ldrb w4, [x2], #1
    ldrb w5, [x3], #1
    cmp w4, w5
    b.ne .Lse_no
    cbnz w4, .Lse_loop
    mov x0, #1
    b .Lse_ret
.Lse_no:
    mov x0, #0
.Lse_ret:
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_fmt2(x0=dst, x1=0..99)   -> x0 = dst+2   two zero-padded digits, no NUL
// tc_fmt4(x0=dst, x1=0..9999) -> x0 = dst+4   four zero-padded digits, no NUL
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_fmt2
    FUNC_TYPE(tc_fmt2)
tc_fmt2:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    ldr x2, =DIV10_MAGIC            // divide-by-10 magic (umulh >> 3)
    umulh x3, x1, x2
    lsr x3, x3, #3                  // tens digit
    mov x5, #10
    msub x4, x3, x5, x1             // ones digit
    add x3, x3, #'0'
    strb w3, [x0], #1
    add x4, x4, #'0'
    strb w4, [x0], #1
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

    .p2align 2
    .global tc_fmt4
    FUNC_TYPE(tc_fmt4)
tc_fmt4:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x30, [sp, #-16]!
    ldr x2, =DIV10_MAGIC            // divide-by-10 magic (umulh >> 3)
    umulh x3, x1, x2
    lsr x3, x3, #3                  // q1 = v/10
    umulh x3, x3, x2
    lsr x3, x3, #3                  // q2 = v/100  (thousands + hundreds)
    mov x6, #100
    msub x4, x3, x6, x1             // low = v % 100 (tens + ones)
    mov x6, x3                      // high (x2-x5 survive the tc_fmt2 calls)
    mov x5, x0                      // dst
    mov x1, x6
    bl tc_fmt2                      // high digits; x0 = dst+2
    mov x5, x0
    mov x1, x4
    bl tc_fmt2                      // low digits; x0 = dst+4
    ldp x6, x30, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

// ============================================================================
// Shared decimal / date formatters and the small helpers the later phases
// used to carry private copies of.  Wave 2 re-points the callers; the
// routines here are the single source of truth.
//
// Clobber contracts are stated per routine and are what callers compile
// against: "clobbers only x0..xN" means every other caller-saved register
// survives the call (stricter than AAPCS64, matching the copies that came
// before), and x19-x28 are always preserved.
// ============================================================================

// util_u64_digits(x0=v) -> x0 = number of decimal digits (v == 0 -> 1)
//   Reciprocal divide-by-10 count; the shared digit-count of tc_fmt_u64 and
//   tc_fmt_pad.  Internal helper: clobbers x0-x3.
    .p2align 2
util_u64_digits:
    mov x1, x0
    mov x0, #0
    cbz x1, .Lud_one
    ldr x2, =DIV10_MAGIC            // divide-by-10 magic (umulh >> 3)
.Lud_loop:
    umulh x3, x1, x2
    lsr x3, x3, #3
    add x0, x0, #1
    mov x1, x3
    cbnz x1, .Lud_loop
    ret
.Lud_one:
    mov x0, #1
    ret

// ----------------------------------------------------------------------------
// tc_fmt_u64(x0=dst, x1=val) -> x0 = dst after the digits (no NUL written)
//   The shared u64->decimal formatter: counts the digits first, then writes
//   them MSB-first directly into dst (no stack temp, no copy loop).  The
//   digit count is known up front, so the cursor is exact and a caller that
//   needs the NUL writes it itself.
//   Clobbers x0, x1 only.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_fmt_u64
    FUNC_TYPE(tc_fmt_u64)
tc_fmt_u64:
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    stp x6, x7, [sp, #-16]!
    mov x2, x1                      // t = val
    mov x3, #0                      // n = digit count
    cbz x1, .Lfu_zero
    ldr x4, =DIV10_MAGIC            // divide-by-10 magic (umulh >> 3)
.Lfu_count:
    umulh x5, x2, x4
    lsr x5, x5, #3
    add x3, x3, #1
    mov x2, x5
    cbnz x2, .Lfu_count
    add x6, x0, x3                  // end = dst + n
    mov x5, #10
.Lfu_wloop:
    umulh x7, x1, x4                // q = v / 10
    lsr x7, x7, #3
    msub x1, x7, x5, x1             // r = v % 10
    add x1, x1, #'0'
    sub x6, x6, #1
    strb w1, [x6]
    mov x1, x7
    cbnz x1, .Lfu_wloop
    add x0, x6, x3                  // end = dst + n (x6 walked down to dst)
    b .Lfu_ret
.Lfu_zero:
    mov w2, #'0'
    strb w2, [x0], #1               // one digit: "0"
.Lfu_ret:
    ldp x6, x7, [sp], #16
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_fmt_pad(x0=dst, x1=val, x2=width) -> x0 = dst after the digits
//   Zero-padded variant of tc_fmt_u64: pads on the LEFT to `width` digits,
//   or just the digits when val needs more than width (width - digits goes
//   negative and no zero is written).  No NUL written.
//   Clobbers x0, x1, x2 only.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_fmt_pad
    FUNC_TYPE(tc_fmt_pad)
tc_fmt_pad:
    stp x19, x20, [sp, #-16]!
    stp x21, x30, [sp, #-16]!
    stp x3, x4, [sp, #-16]!
    mov x19, x0                     // dst
    mov x20, x1                     // val
    mov x21, x2                     // width
    mov x0, x20
    bl util_u64_digits              // x0 = digit count
    sub x21, x21, x0                // pad count (may be negative -> none)
.Lpad_zl:
    cmp x21, #0
    b.le .Lpad_dig                 // negative pad count -> digits win, no zeros
    mov w0, #'0'
    strb w0, [x19], #1
    sub x21, x21, #1
    b .Lpad_zl
.Lpad_dig:
    mov x0, x19
    mov x1, x20
    bl tc_fmt_u64                   // x0 = end cursor
    ldp x3, x4, [sp], #16
    ldp x21, x30, [sp], #16
    ldp x19, x20, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_ymd_split(x0=ymd) -> x0 = year, x1 = month, x2 = day
//   Unpacks the packed YYYYMMDD contract form (ymd = y*10000 + m*100 + d).
//   Clobbers x0, x1, x2 only.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_ymd_split
    FUNC_TYPE(tc_ymd_split)
tc_ymd_split:
    stp x3, x4, [sp, #-16]!
    mov x3, #YMD_YEAR_SCALE
    udiv x4, x0, x3                 // y
    msub x0, x4, x3, x0             // m*100 + d
    mov x3, #YMD_MONTH_SCALE
    udiv x1, x0, x3                 // m
    msub x2, x1, x3, x0             // d
    mov x0, x4
    ldp x3, x4, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_sod_split(x0=sod) -> x0 = hour, x1 = minute, x2 = second
//   Unpacks seconds-of-day (0..86399) into its clock components.
//   Clobbers x0, x1, x2 only.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_sod_split
    FUNC_TYPE(tc_sod_split)
tc_sod_split:
    stp x3, x4, [sp, #-16]!
    mov x3, #SECS_PER_HOUR
    udiv x4, x0, x3                 // hour
    msub x0, x4, x3, x0             // remainder
    mov x3, #60
    udiv x1, x0, x3                 // minute
    msub x2, x1, x3, x0             // second
    mov x0, x4
    ldp x3, x4, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_fmt_ymd_sod(x0=dst, x1=ymd, x2=sod, x3=sep) -> x0 = dst+19
//   "YYYY-MM-DD<sep>HH:MM:SS" (19 digits + separators; no NUL).  `sep` is a
//   single byte in w3.  Consolidates the json/render datetime formatters,
//   which both called tc_fmt2/tc_fmt4 identically.  Clobbers x0-x2, x6-x9
//   (the date/time arithmetic and tc_fmt2/tc_fmt4 scratch); preserves
//   x3-x5, x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_fmt_ymd_sod
    FUNC_TYPE(tc_fmt_ymd_sod)
tc_fmt_ymd_sod:
    PROLOGUE 4
    mov x19, x0                     // dst
    mov x20, x1                     // ymd
    mov x21, x2                     // sod
    mov w22, w3                     // sep
    // time components from sod, computed once (they survive the tc_fmt2
    // calls in x23-x26 as callee-saved)
    mov x2, #SECS_PER_HOUR
    udiv x23, x21, x2               // hour
    msub x24, x23, x2, x21          // rem
    mov x2, #60
    udiv x25, x24, x2               // minute
    msub x26, x25, x2, x24          // second
    // year
    mov x2, #YMD_YEAR_SCALE
    udiv x6, x20, x2
    mov x0, x19
    mov x1, x6
    bl tc_fmt4
    mov w7, #'-'
    strb w7, [x0], #1
    // month: (ymd / YMD_MONTH_SCALE) % 100
    mov x2, #YMD_MONTH_SCALE
    udiv x6, x20, x2
    mov x8, #100
    udiv x9, x6, x8
    msub x9, x9, x8, x6
    mov w1, w9
    bl tc_fmt2
    mov w7, #'-'
    strb w7, [x0], #1
    // day: ymd % 100
    mov x2, #100
    udiv x6, x20, x2
    msub x6, x6, x2, x20
    mov w1, w6
    bl tc_fmt2
    strb w22, [x0], #1
    // hour
    mov w1, w23
    bl tc_fmt2
    mov w7, #':'
    strb w7, [x0], #1
    // minute
    mov w1, w25
    bl tc_fmt2
    mov w7, #':'
    strb w7, [x0], #1
    // second
    mov w1, w26
    bl tc_fmt2
    EPILOGUE 4
    ret

// ----------------------------------------------------------------------------
// tc_is_ws(x0=byte) -> x0 = 1 for ASCII whitespace (space, \t \n \v \f \r),
//   else 0.  The ASCII str.strip() whitespace set.  Clobbers x0 only.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_is_ws
    FUNC_TYPE(tc_is_ws)
tc_is_ws:
    cmp w0, #' '
    b.eq .Lws_yes
    cmp w0, #9
    b.lt .Lws_no
    cmp w0, #13
    b.le .Lws_yes
.Lws_no:
    mov w0, #0
    ret
.Lws_yes:
    mov w0, #1
    ret

// ----------------------------------------------------------------------------
// tc_copy_bytes(x0=dst, x1=src, x2=len) -> x0 = dst+len
//   Shared 16/8/byte-tail copy: ldp/stp 16-byte bulk copy, then an 8-byte
//   word, then bytes.  Reads exactly `len` bytes (never past), writes no
//   NUL.  Clobbers x0, x1, x2 only.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_copy_bytes
    FUNC_TYPE(tc_copy_bytes)
tc_copy_bytes:
    stp x3, x4, [sp, #-16]!
    stp x5, x6, [sp, #-16]!
    mov x3, x2                      // remaining
    mov x4, x0                      // dst cursor
.Lcb_16:
    cmp x3, #16
    b.lt .Lcb_8
    ldp x5, x6, [x1], #16
    stp x5, x6, [x4], #16
    sub x3, x3, #16
    b .Lcb_16
.Lcb_8:
    cmp x3, #8
    b.lt .Lcb_tail
    ldr x5, [x1], #8
    str x5, [x4], #8
    sub x3, x3, #8
.Lcb_tail:
    cbz x3, .Lcb_done
    ldrb w5, [x1], #1
    strb w5, [x4], #1
    sub x3, x3, #1
    b .Lcb_tail
.Lcb_done:
    mov x0, x4
    ldp x5, x6, [sp], #16
    ldp x3, x4, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_read_all(x0=path, x1=cap) -> x0 = status (0 ok, 1 too large, 2 error),
//   x1 = malloc'd buffer (caller frees; 0 on early error), x2 = bytes read.
//   Shared open/malloc/grow/read file reader: opens the path O_RDONLY, reads
//   into a buffer that doubles up to `cap` (READ_CHUNK_CORE at a time), and
//   retries reads interrupted by EINTR.  A file that grows past `cap` is
//   reported "too large" (status 1) with the bytes read so far; an open,
//   allocation or read error is status 2 with a NULL buffer.  Unlike the
//   count path's old reader, this helper does not record errno anywhere.
//   Clobbers x0-x17 (libc calls); preserves x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_read_all
    FUNC_TYPE(tc_read_all)
tc_read_all:
    PROLOGUE 3
    mov x19, x0                     // path
    mov x20, x1                     // cap
    mov x0, x19
    mov x1, #O_RDONLY
    bl open
    cmp x0, #0
    b.lt .Lra_open_fail
    mov x21, x0                     // fd
    mov x0, #READ_CHUNK_CORE
    bl malloc
    cbz x0, .Lra_alloc_fail
    mov x22, x0                     // buf
    mov x23, #READ_CHUNK_CORE       // allocated capacity
    mov x24, #0                     // total bytes read
.Lra_loop:
    cmp x24, x23
    b.lt .Lra_read
    // grow: double, but never past cap (a probe byte past the cap lets a
    // file of exactly cap bytes read fully; one byte more trips "too large")
    lsl x23, x23, #1
    cmp x23, x20
    b.lt .Lra_grow_ok
    mov x23, x20
    add x23, x23, #1
.Lra_grow_ok:
    cmp x23, x24
    b.le .Lra_large
    mov x0, x22
    mov x1, x23
    bl realloc
    cbz x0, .Lra_realloc_fail
    mov x22, x0
.Lra_read:
    mov x0, x21
    add x1, x22, x24
    sub x2, x23, x24
    bl read
    cmp x0, #0
    b.lt .Lra_retry
    b.eq .Lra_done
    add x24, x24, x0
    cmp x24, x20
    b.gt .Lra_large
    b .Lra_loop
.Lra_retry:
    // read() returned -1; retry only on EINTR (fd/buf/cap/total live in
    // x19-x24, callee-saved, so they survive the errno lookup call)
    bl __errno_location
    ldr w0, [x0]
    cmp w0, #EINTR
    b.eq .Lra_read
    b .Lra_read_err
.Lra_done:
    mov x0, x21
    bl close
    mov x0, #0
    mov x1, x22
    mov x2, x24
    EPILOGUE 3
    ret
.Lra_large:
    mov x0, x21
    bl close
    mov x0, #1
    mov x1, x22
    mov x2, x24
    EPILOGUE 3
    ret
.Lra_read_err:
    mov x0, x21
    bl close
    mov x0, x22
    bl free
    mov x0, #2
    mov x1, #0
    mov x2, #0
    EPILOGUE 3
    ret
.Lra_open_fail:
    mov x0, #2
    mov x1, #0
    mov x2, #0
    EPILOGUE 3
    ret
.Lra_alloc_fail:
    mov x0, x21
    bl close
    b .Lra_alloc_fail2
.Lra_realloc_fail:
    mov x0, x22                     // the grown buffer is still live
    bl free                         // (realloc failure left it allocated)
.Lra_alloc_fail2:
    mov x0, #2
    mov x1, #0
    mov x2, #0
    EPILOGUE 3
    ret

// ============================================================================
// Calendar arithmetic -- proleptic Gregorian, Howard Hinnant's algorithms,
// verified against Python's datetime for years 1..9999.  ymd is the packed
// YYYYMMDD integer the contract structures use; sod is seconds of day.
// The algorithms count in 400-year eras starting on March 1st:
// ============================================================================
    .equ DAYS_PER_ERA,      146097      // 400 years
    .equ EPOCH_ERA_OFFSET,  719468      // days from 0000-03-01 to 1970-01-01
    .equ DAYS_PER_YEAR,     365
    .equ YEARS_PER_ERA,     400

// ----------------------------------------------------------------------------
// tc_days_from_civil(x0=y, x1=m, x2=d) -> x0 = days since 1970-01-01
//   y -= m <= 2; era = (y >= 0 ? y : y-399) / 400; yoe = y - era*400;
//   doy = (153*(m + (m > 2 ? -3 : 9)) + 2)/5 + d - 1;
//   doe = yoe*365 + yoe/4 - yoe/100 + doy; result = era*146097 + doe - 719468
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_days_from_civil
    FUNC_TYPE(tc_days_from_civil)
tc_days_from_civil:
    stp x3, x4, [sp, #-16]!
    stp x5, x6, [sp, #-16]!
    stp x7, x8, [sp, #-16]!
    stp x9, x10, [sp, #-16]!
    mov x10, x0                     // y (x0 is rebuilt at the end)
    cmp x1, #2
    b.gt .Ldfc_adj_done
    sub x10, x10, #1
.Ldfc_adj_done:
    cmp x10, #0
    b.ge .Ldfc_ypos
    sub x3, x10, #399
    b .Ldfc_era
.Ldfc_ypos:
    mov x3, x10
.Ldfc_era:
    mov x4, #YEARS_PER_ERA
    sdiv x3, x3, x4                 // era
    msub x5, x3, x4, x10            // yoe
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
    sub x6, x6, #1                  // doy
    mov x7, #DAYS_PER_YEAR
    mul x7, x5, x7
    add x7, x7, x6
    mov x9, #4
    sdiv x8, x5, x9
    add x7, x7, x8
    mov x9, #100
    sdiv x8, x5, x9
    sub x7, x7, x8                  // doe
    ldr x9, =DAYS_PER_ERA
    mul x9, x3, x9
    add x7, x7, x9
    ldr x9, =EPOCH_ERA_OFFSET
    sub x0, x7, x9
    ldp x9, x10, [sp], #16
    ldp x7, x8, [sp], #16
    ldp x5, x6, [sp], #16
    ldp x3, x4, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_civil_from_days(x0=days since 1970-01-01) -> x0 = y, x1 = m, x2 = d
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_civil_from_days
    FUNC_TYPE(tc_civil_from_days)
tc_civil_from_days:
    stp x3, x4, [sp, #-16]!
    stp x5, x6, [sp, #-16]!
    stp x7, x8, [sp, #-16]!
    stp x9, x10, [sp, #-16]!
    stp x11, x12, [sp, #-16]!
    stp x13, x14, [sp, #-16]!
    ldr x3, =EPOCH_ERA_OFFSET
    add x3, x0, x3                  // z
    cmp x3, #0
    b.ge .Lcfd_zpos
    ldr x9, =146096
    sub x4, x3, x9
    b .Lcfd_era
.Lcfd_zpos:
    mov x4, x3
.Lcfd_era:
    ldr x5, =DAYS_PER_ERA
    sdiv x4, x4, x5                 // era
    msub x6, x4, x5, x3             // doe
    ldr x7, =1460
    sdiv x8, x6, x7
    sub x8, x6, x8
    ldr x7, =36524
    sdiv x9, x6, x7
    add x8, x8, x9
    ldr x7, =146096
    sdiv x9, x6, x7
    sub x8, x8, x9
    mov x7, #DAYS_PER_YEAR
    sdiv x8, x8, x7                 // yoe
    mov x7, #YEARS_PER_ERA
    mul x9, x4, x7
    add x9, x8, x9                  // y (before the Jan/Feb fix-up)
    mov x7, #365
    mul x10, x8, x7
    sub x10, x6, x10
    mov x7, #4
    sdiv x11, x8, x7
    sub x10, x10, x11
    mov x7, #100
    sdiv x11, x8, x7
    add x10, x10, x11               // doy
    mov x7, #5
    mul x10, x10, x7
    add x10, x10, #2
    mov x7, #153
    sdiv x10, x10, x7               // mp
    mov x7, #153
    mul x11, x10, x7
    add x11, x11, #2
    mov x7, #5
    sdiv x11, x11, x7
    mov x7, #365
    mul x12, x8, x7
    sub x12, x6, x12
    mov x7, #4
    sdiv x13, x8, x7
    sub x12, x12, x13
    mov x7, #100
    sdiv x13, x8, x7
    add x12, x12, x13
    sub x12, x12, x11
    add x2, x12, #1                 // d
    cmp x10, #10
    b.ge .Lcfd_mbig
    add x1, x10, #3
    b .Lcfd_mdone
.Lcfd_mbig:
    sub x1, x10, #9
.Lcfd_mdone:                        // m
    cmp x1, #2
    b.gt .Lcfd_ret
    add x9, x9, #1
.Lcfd_ret:
    mov x0, x9
    ldp x13, x14, [sp], #16
    ldp x11, x12, [sp], #16
    ldp x9, x10, [sp], #16
    ldp x7, x8, [sp], #16
    ldp x5, x6, [sp], #16
    ldp x3, x4, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_is_leap(x0=y) -> x0 = 1 for a leap year, else 0
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_is_leap
    FUNC_TYPE(tc_is_leap)
tc_is_leap:
    stp x1, x2, [sp, #-16]!
    mov x1, #4
    sdiv x2, x0, x1
    msub x2, x2, x1, x0
    cbnz x2, .Lil_no
    mov x1, #100
    sdiv x2, x0, x1
    msub x2, x2, x1, x0
    cbnz x2, .Lil_yes
    mov x1, #400
    sdiv x2, x0, x1
    msub x2, x2, x1, x0
    cmp x2, #0
    cset x0, eq                     // 1 iff 400 divides y
    b .Lil_ret
.Lil_yes:
    mov x0, #1
    b .Lil_ret
.Lil_no:
    mov x0, #0
.Lil_ret:
    ldp x1, x2, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_days_in_month(x0=y, x1=m 1..12) -> x0 = days in that month
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_days_in_month
    FUNC_TYPE(tc_days_in_month)
tc_days_in_month:
    PROLOGUE 0
    stp x2, x3, [sp, #-16]!
    cmp x1, #2
    b.eq .Ldim_feb
    LEA x2, util_month_days
    sub x3, x1, #1
    ldrb w0, [x2, x3]
    b .Ldim_ret
.Ldim_feb:
    bl tc_is_leap
    add x0, x0, #28                 // 28 + leap
.Ldim_ret:
    ldp x2, x3, [sp], #16
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// tc_ymd_sod_to_epoch(x0=ymd, x1=sod) -> x0 = epoch seconds (UTC)
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_ymd_sod_to_epoch
    FUNC_TYPE(tc_ymd_sod_to_epoch)
tc_ymd_sod_to_epoch:
    PROLOGUE 0
    stp x1, x2, [sp, #-16]!
    stp x3, x4, [sp, #-16]!
    mov x4, x1                      // sod (survives tc_ymd_split)
    bl tc_ymd_split                 // x0=y, x1=m, x2=d
    bl tc_days_from_civil           // x0 = days since the epoch
    ldr x3, =SECS_PER_DAY
    mul x0, x0, x3
    add x0, x0, x4
    ldp x3, x4, [sp], #16
    ldp x1, x2, [sp], #16
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// tc_epoch_to_ymd_sod(x0=epoch seconds) -> x0 = ymd, x1 = sod (UTC)
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_epoch_to_ymd_sod
    FUNC_TYPE(tc_epoch_to_ymd_sod)
tc_epoch_to_ymd_sod:
    PROLOGUE 0
    stp x2, x3, [sp, #-16]!
    stp x4, x5, [sp, #-16]!
    ldr x2, =SECS_PER_DAY
    sdiv x3, x0, x2                 // q = trunc(epoch / 86400)
    msub x4, x3, x2, x0             // r = epoch - q*86400 (sign of epoch)
    cmp x4, #0
    b.ge .Letp_pos                  // r >= 0: q is already the floor
    sub x3, x3, #1                  // floor division for negative epochs:
    add x4, x4, x2                  //   q -= 1, r += 86400 (r stays < 86400)
.Letp_pos:
    mov x0, x3
    bl tc_civil_from_days           // x0=y, x1=m, x2=d
    mov x3, #YMD_YEAR_SCALE
    mul x0, x0, x3
    mov x3, #YMD_MONTH_SCALE
    madd x0, x1, x3, x0
    add x0, x0, x2                  // ymd
    mov x1, x4
    ldp x4, x5, [sp], #16
    ldp x2, x3, [sp], #16
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// tc_entry_ptr(x0=base, x1=i, x2=sz) -> x0 = base + i*sz (a record pointer).
//   The one shared `mul i, sz; add base` of the entry loops (used by
//   tc_cache.S and tc_json.S).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_entry_ptr
    FUNC_TYPE(tc_entry_ptr)
tc_entry_ptr:
    mul x2, x1, x2
    add x0, x0, x2
    ret

// ----------------------------------------------------------------------------
// tc_state_str(x0=id) -> x0 = "live"/"offline"/"unknown" ptr, or 0 when id is
//   out of range.  id is TC_ST_* (1 live, 2 offline, 3 unknown); 0 (no
//   filter) and anything > 3 return 0, matching cache_state_str's contract.
//   Shared by tc_render.S / tc_json.S (plan presentation), tc_cache.S (the
//   rollup state strings) and tc_cli.S (parse/error messages) so the
//   "live"/"offline"/"unknown" literals live in exactly one place.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_state_str
    FUNC_TYPE(tc_state_str)
tc_state_str:
    cmp x0, #TC_ST_LIVE
    b.lt .Ltss_none
    cmp x0, #TC_ST_UNKNOWN
    b.gt .Ltss_none
    sub x0, x0, #1
    LEA x1, tc_state_names
    ldr x0, [x1, x0, lsl #3]
    ret
.Ltss_none:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// tc_metric_str(x0=id) -> x0 = metric-name ptr (TC_M_* 0..6), or 0 when id is
//   out of range.  Shared by tc_render.S / tc_json.S (column headers, sort
//   names) and tc_cli.S (parse/error messages): one copy of the metric
//   strings instead of a per-module table.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_metric_str
    FUNC_TYPE(tc_metric_str)
tc_metric_str:
    cmp x0, #0
    b.lt .Ltms_none
    cmp x0, #TC_M_LIVE_SHARE
    b.gt .Ltms_none
    LEA x1, tc_metric_names
    ldr x0, [x1, x0, lsl #3]
    ret
.Ltms_none:
    mov x0, #0
    ret

// ============================================================================
// tc_win_begin_after_end_check(x0=scratch) — fail with the Python-identical
//   "begin (A) is after end (B)" when the resolved window's begin (kind
//   EARLIEST) is later than its end.  Reads tc_window, formats the message
//   into the caller's scratch buffer (>= 64 bytes) and tc_report_fail's.
//   The one shared copy of the check the CLI and the counting core both
//   make after resolving the window.  Clobbers x0-x17 only (x19-x28
//   preserved).
// ============================================================================
    .p2align 2
    .global tc_win_begin_after_end_check
    FUNC_TYPE(tc_win_begin_after_end_check)
tc_win_begin_after_end_check:
    PROLOGUE 3
    mov x19, x0                        // scratch (survives the calls below)
    LEA x20, tc_window
    ldr x0, [x20, #TC_W_BEGIN_YMD]
    ldr x1, [x20, #TC_W_BEGIN_SOD]
    bl tc_ymd_sod_to_epoch
    mov x21, x0                        // begin epoch
    ldr x0, [x20, #TC_W_END_YMD]
    ldr x1, [x20, #TC_W_END_SOD]
    bl tc_ymd_sod_to_epoch
    cmp x21, x0
    b.le .Lwbae_done
    // "begin (A) is after end (B)"
    mov x22, x19                       // cursor
    LEA x1, s_begin_paren
    mov x0, x22
    bl tc_cat_cstr
    mov x22, x0
    ldr x1, [x20, #TC_W_BEGIN_YMD]
    ldr x2, [x20, #TC_W_BEGIN_SOD]
    mov x0, x22
    mov w3, #' '
    bl tc_fmt_ymd_sod
    mov x22, x0
    LEA x1, s_is_after_end
    mov x0, x22
    bl tc_cat_cstr
    mov x22, x0
    ldr x1, [x20, #TC_W_END_YMD]
    ldr x2, [x20, #TC_W_END_SOD]
    mov x0, x22
    mov w3, #' '
    bl tc_fmt_ymd_sod
    mov w1, #')'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    mov x0, x19
    bl tc_report_fail
.Lwbae_done:
    EPILOGUE 3
    ret

    RODATA
// state names indexed by TC_ST_* - 1 (0=live, 1=offline, 2=unknown)
    .p2align 3
    .global tc_state_names
tc_state_names:
    .quad tc_str_live
    .quad tc_str_offline
    .quad tc_str_unknown
// metric names indexed by TC_M_* (0=count, 1=login, 2=live, 3=offline,
// 4=unknown, 5=offline-share, 6=live-share)
    .p2align 3
    .global tc_metric_names
tc_metric_names:
    .quad tc_str_count
    .quad tc_str_login
    .quad tc_str_live
    .quad tc_str_offline
    .quad tc_str_unknown
    .quad tc_str_offshare
    .quad tc_str_liveshare
    .global tc_str_count
    .global tc_str_login
    .global tc_str_live
    .global tc_str_offline
    .global tc_str_unknown
    .global tc_str_offshare
    .global tc_str_liveshare
tc_str_count:     .asciz "count"
tc_str_login:     .asciz "login"
tc_str_live:      .asciz "live"
tc_str_offline:   .asciz "offline"
tc_str_unknown:   .asciz "unknown"
tc_str_offshare:  .asciz "offline-share"
tc_str_liveshare: .asciz "live-share"
// "begin (A) is after end (B)" — the shared window-order failure message
// (tc_win_begin_after_end_check; byte-identical to the Python reference).
s_begin_paren:    .asciz "begin ("
s_is_after_end:   .asciz ") is after end ("

util_month_days:  .byte 31,28,31,30,31,30,31,31,30,31,30,31
    .text

    .end
