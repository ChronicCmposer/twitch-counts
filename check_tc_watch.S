// ============================================================================
// check_tc_watch.S — Phase 7 test driver for tc_watch.S (watch mode).
// ============================================================================
//
//  main(): tc_cli_parse -> tc_build_exclusions -> tc_cache_open ->
//          tc_watch_run -> tc_cache_close -> exit rc.
//
//  tc_watch_run returns 0 normally or 130 on SIGINT.  The Python main()
//  reports "interrupted" in the JSON shape when --json was given; watch and
//  --json are mutually exclusive in the CLI, but the driver honours the
//  flag anyway for parity with report_failure(args, "interrupted",
//  code=130, announce=False).
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Linking:    musl-gcc -static with tc_watch.o tc_render.o tc_json.o
//              tc_core.o tc_cli.o tc_config.o tc_util.o tc_cache.o toml.o
//              sqlite3.o libpcre2-8.a
// ============================================================================

    .arch armv8-a
    .include "tc_layout.inc"

    .globl tc_cli_parse
    .globl tc_build_exclusions
    .globl tc_cache_open
    .globl tc_watch_run
    .globl tc_cache_close
    .globl tc_opts
    .globl tc_strlen
    .globl write
    .globl fflush
    .globl exit

    .equ STDOUT, 1

    .text

// ----------------------------------------------------------------------------
// main — parse, exclusions, cache open, watch, cache close.
// ----------------------------------------------------------------------------
    .p2align 2
    .global main
    .type main, %function
main:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                     // argc
    mov x20, x1                     // argv
    mov x0, x19
    mov x1, x20
    bl tc_cli_parse
    bl tc_build_exclusions
    bl tc_cache_open
    bl tc_watch_run
    mov x19, x0                     // rc (0 or 130)
    bl tc_cache_close
    // interrupted + --json -> the report_failure shape
    cmp x19, #130
    b.ne .Lmain_done
    adrp x0, tc_opts
    add x0, x0, :lo12:tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.eq .Lmain_done
    // write {"error": "interrupted"}\n to stderr (fd 2)
    mov x0, #0
    bl fflush
    mov x0, #2
    adrp x1, s_interrupted
    add x1, x1, :lo12:s_interrupted
    adrp x2, s_interrupted_end
    add x2, x2, :lo12:s_interrupted_end
    sub x2, x2, x1
    bl write
.Lmain_done:
    mov x0, x19
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

    .section .rodata
s_interrupted:
    .ascii "{\"error\": \"interrupted\"}\n"
s_interrupted_end:

    .end
