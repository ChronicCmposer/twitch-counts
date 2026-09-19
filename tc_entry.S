// ============================================================================
// tc_entry.S — bringup smoke test + shared utilities for twitch-counts-full
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static — musl libc + crt1.o (startfile) + vendored
//              third_party/tomlc99/toml.o, third_party/sqlite3/sqlite3.o,
//              third_party/pcre2/install/lib/libpcre2-8.a
//
//  Behavior
//  --------
//    twitch-counts-full is the FULL port of twitch-counts.py (TOML config,
//    env vars, SQLite rollup cache, watch mode, JSON output, fish
//    completions, --users bisection, argparse-equivalent CLI).  This module
//    is phase 1 (TOOLCHAIN & BRINGUP): it links the whole static stack
//    together, proves each vendored library is callable, and exposes the
//    output primitives every later phase builds on.
//
//    This phase's main() is a bringup smoke routine:
//      (a) prints  tc-bringup: ok argv0=<argv[0]>   via printf
//      (b) prints  sqlite3 <sqlite3_libversion()>   via printf
//      (c) prints  pcre2 <pcre2_config(PCRE2_CONFIG_VERSION)>  via printf
//          (the library symbol is pcre2_config_8 — the "8" is PCRE2's
//          8-bit-width suffix; pcre2.h's macro renames pcre2_config to
//          pcre2_config_8 for C callers, so assembly calls the suffix)
//      (d) parses the TOML string  greeting = "hello"\n  with toml_parse
//          and prints  toml greeting=hello
//      (e) flushes stdout and returns 0
//
//  Shared utilities (all .global, AAPCS64, x19-x28 preserved)
//  ----------------------------------------------------------
//    tc_strlen(x0=s)          -> x0 = byte length of a NUL-terminated string
//    tc_puts(x0=s)            print string to stdout (flushes stdio first)
//    tc_eputs(x0=s)           print string to stderr (unbuffered)
//    tc_putu64(x0=v)          print unsigned 64-bit decimal to stdout, no commas
//    tc_fail(x0=msg)          print "error: <msg>" to stderr, exit 1 (noreturn)
//
//  Register roles
//  --------------
//    main:  x19 = argv[0]             (survives the printf calls)
//           x20 = sqlite3 version string (returned in caller-saved x0, so
//                it is stashed in callee-saved x20 before the next printf)
//           x23 = toml_table_t*       (survives toml_raw_in / toml_free)
//           sp-relative buffers: TOML config copy, toml errbuf, pcre2
//                version buffer, toml_rtos dst slot (see TC_* constants)
//    tc_puts / tc_eputs / tc_putu64 / tc_fail:
//           x19 = held string/value (saved and restored; the public
//                contract is: x19-x28 are preserved)
//    x0..x17 = subroutine scratch; our helpers never touch x19..x28
//              without saving them first.
//    x30 = link register
//
//  AAPCS64 notes (the rules every later phase must follow)
//  -------------------------------------------------------
//    * Arguments in x0-x7 (integer) / v0-v7 (float); return in x0 (x1 for
//      128-bit); composites are returned in x0..x3 or via x8 (sret).
//    * Callee-saved (must be preserved across any `bl` we make):
//      x19-x28, x29 (FP).  x30 (LR) is saved by the callee that calls.
//      x18 is the platform register — never touch it.
//    * sp must stay 16-byte aligned at every call site; allocations must
//      be multiples of 16.
//    * main is entered with x0 = argc, x1 = argv, x29/x30 valid, sp
//      16-aligned (musl's crt1.o/Scrt1.o provides this; we do NOT define
//      our own _start).
//
//  Library calls made from this module (musl libc or vendored C)
//  -------------------------------------------------------------
//    printf(const char *fmt, ...)                   -> int
//    fflush(FILE *stream)                           -> int  (0 == all)
//    write(int fd, const void *buf, size_t n)       -> ssize_t
//    exit(int status)                               -> noreturn
//    free(void *ptr)
//    sqlite3_libversion(void)                       -> const char *
//    pcre2_config_8(uint32_t what, void *where)     -> int
//        (the real library symbol; header macro aliases pcre2_config)
//    toml_parse(char *conf, char *errbuf, int sz)   -> toml_table_t *
//    toml_raw_in(const toml_table_t *, const char *) -> toml_raw_t (const char *)
//    toml_rtos(toml_raw_t src, char **ret)          -> int  (0 ok; *ret malloc'd)
//    toml_free(toml_table_t *)
// ============================================================================

    .arch armv8-a
    .text

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ STDOUT, 1                   // standard output file descriptor
    .equ STDERR, 2                   // standard error file descriptor
    .equ PCRE2_CONFIG_VERSION, 11    // pcre2.h: request type for version string

    // main() stack buffer layout (272 bytes, 16-aligned):
    .equ TC_CFG_OFF,   0             // TOML config copy
    .equ TC_CFG_SZ,    64
    .equ TC_ERR_OFF,   64            // toml_parse errbuf
    .equ TC_ERR_SZ,    128
    .equ TC_PCRE2_OFF, 192           // pcre2_config version buffer
    .equ TC_PCRE2_SZ,  64
    .equ TC_DST_OFF,   256           // toml_rtos result slot (char *)
    .equ TC_BUF_SZ,    272           // total main() stack frame

// ----------------------------------------------------------------------------
// main — bringup smoke routine (see header).  AAPCS64: x0 = argc, x1 = argv.
// ----------------------------------------------------------------------------
    .p2align 2
    .global main
    .type main, %function
main:
    stp x29, x30, [sp, #-16]!        // save frame record (sp stays 16-aligned)
    stp x19, x20, [sp, #-16]!        // save the callee-saved registers we use
    str x23, [sp, #-16]!
    sub sp, sp, #TC_BUF_SZ           // main() stack buffers (272, 16-aligned)

    ldr x19, [x1]                    // x19 = argv[0]  (program name)

    // ---- (a) bringup marker + argv[0] -------------------------------------
    adrp x0, fmt_bringup
    add x0, x0, :lo12:fmt_bringup
    mov x1, x19
    bl printf

    // ---- (b) sqlite3 version ----------------------------------------------
    bl sqlite3_libversion           // x0 = version string (caller-saved)
    mov x20, x0                     // stash it in callee-saved x20
    adrp x0, fmt_sqlite
    add x0, x0, :lo12:fmt_sqlite
    mov x1, x20
    bl printf

    // ---- (c) pcre2 version -------------------------------------------------
    mov w0, #PCRE2_CONFIG_VERSION   // pcre2_config_8(PCRE2_CONFIG_VERSION, buf)
    add x1, sp, #TC_PCRE2_OFF
    bl pcre2_config_8
    add x1, sp, #TC_PCRE2_OFF       // re-derive buf (x1 is caller-saved)
    adrp x0, fmt_pcre2
    add x0, x0, :lo12:fmt_pcre2
    bl printf

    // ---- (d) TOML: copy config into a writable buffer, then parse ---------
    add x0, sp, #TC_CFG_OFF         // dst (writable; toml_parse may write)
    adrp x1, toml_config            // src (rodata literal)
    add x1, x1, :lo12:toml_config
.Lcfg_copy:
    ldrb w2, [x1], #1
    strb w2, [x0], #1
    cbnz w2, .Lcfg_copy             // copy through and including the NUL

    add x0, sp, #TC_CFG_OFF         // toml_parse(conf, errbuf, errbufsz)
    add x1, sp, #TC_ERR_OFF
    mov w2, #TC_ERR_SZ
    bl toml_parse
    cbz x0, .Lmain_toml_parse_fail  // fail fast: parse error
    mov x23, x0                     // x23 = toml_table_t* (callee-saved)

    mov x0, x23                     // toml_raw_in(table, "greeting")
    adrp x1, key_greeting
    add x1, x1, :lo12:key_greeting
    bl toml_raw_in
    cbz x0, .Lmain_greeting_fail    // fail fast: key absent
    add x1, sp, #TC_DST_OFF         // toml_rtos(raw, &dst)
    bl toml_rtos
    cbnz x0, .Lmain_greeting_fail   // fail fast: value is not a string

    ldr x1, [sp, #TC_DST_OFF]       // printf(fmt_toml, dst)
    adrp x0, fmt_toml
    add x0, x0, :lo12:fmt_toml
    bl printf

    ldr x0, [sp, #TC_DST_OFF]       // free(dst)  — toml_rtos mallocs it
    bl free
    mov x0, x23                     // toml_free(table)
    bl toml_free

    // ---- (e) flush buffered stdout and return 0 ----------------------------
    mov x0, #0                      // fflush(NULL): push buffered stdout out
    bl fflush
    mov w0, #0                      // return 0

    add sp, sp, #TC_BUF_SZ
    ldr x23, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// Fail-fast paths (Law of Fail Fast, Fail Loud): descriptive message, exit 1.
// ----------------------------------------------------------------------------
.Lmain_toml_parse_fail:
    adrp x0, msg_toml_parse
    add x0, x0, :lo12:msg_toml_parse
    bl tc_fail                      // noreturn

.Lmain_greeting_fail:
    adrp x0, msg_toml_greeting
    add x0, x0, :lo12:msg_toml_greeting
    bl tc_fail                      // noreturn

// ----------------------------------------------------------------------------
// tc_strlen — length of a NUL-terminated string.
//   in:  x0 = pointer to the string
//   out: x0 = number of bytes before the NUL
//   Clobbers x0-x2 only; preserves x19-x28 and the stack.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_strlen
    .type tc_strlen, %function
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
    .type tc_puts, %function
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
    .type tc_eputs, %function
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
    .type tc_putu64, %function
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
    .type tc_fail, %function
tc_fail:
    stp x19, x30, [sp, #-16]!
    mov x19, x0                     // x19 = message
    mov x0, #0                      // fflush(NULL)
    bl fflush
    mov x0, #STDERR                 // write(2, "error: ", err_prefix_len)
    adrp x1, err_prefix
    add x1, x1, :lo12:err_prefix
    mov x2, #err_prefix_len
    bl write
    mov x0, x19                     // tc_eputs(message)
    bl tc_eputs
    mov x0, #STDERR                 // write(2, "\n", err_newline_len)
    adrp x1, err_newline
    add x1, x1, :lo12:err_newline
    mov x2, #err_newline_len
    bl write
    mov w0, #1                      // exit(1)
    bl exit

// ----------------------------------------------------------------------------
// Read-only message data.  Lengths are label differences so the writer and
// the .equ can never drift apart.
// ----------------------------------------------------------------------------
    .section .rodata
fmt_bringup:
    .ascii "tc-bringup: ok argv0=%s\n\0"
fmt_sqlite:
    .ascii "sqlite3 %s\n\0"
fmt_pcre2:
    .ascii "pcre2 %s\n\0"
fmt_toml:
    .ascii "toml greeting=%s\n\0"

toml_config:
    .ascii "greeting = \"hello\"\n\0"
key_greeting:
    .ascii "greeting\0"

err_prefix:
    .ascii "error: "
err_prefix_end:
    .equ err_prefix_len, err_prefix_end - err_prefix
err_newline:
    .ascii "\n"
err_newline_end:
    .equ err_newline_len, err_newline_end - err_newline

msg_toml_parse:
    .ascii "toml_parse failed\0"
msg_toml_greeting:
    .ascii "toml greeting missing or invalid\0"

    .end
