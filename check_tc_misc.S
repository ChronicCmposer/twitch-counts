// ============================================================================
// check_tc_misc.S — Phase 8 driver for tc_misc.S (twitch-counts-full).
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static -o tc-misc-test check_tc_misc.o tc_misc.o
//              tc_core.o tc_cli.o tc_config.o tc_util.o
//              third_party/tomlc99/toml.o
//
//  Behavior
//  --------
//    main() parses the command line with the real tc_cli_parse (argparse-
//    equivalent errors exit 2, resolution errors exit 1, --help exits 0),
//    then dispatches exactly as the Python main() does:
//        --manual               -> tc_misc_manual()
//        --emit-fish-completions-> tc_misc_fish()
//        --complete KIND        -> tc_misc_complete(TC_O_COMPLETE_KIND)
//    and returns the entry point's code (0 for all three).
//
//  This is the shape Wave E's main() must take in tc_main.S.
// ============================================================================

    .arch armv8-a
    .include "tc_layout.inc"

    .globl tc_cli_parse
    .globl tc_misc_manual
    .globl tc_misc_fish
    .globl tc_misc_complete
    .globl tc_opts
    .globl exit

    .text

// ----------------------------------------------------------------------------
// main — parse, then dispatch on the flags (Python main() order).
//   in:  x0 = argc, x1 = argv
// ----------------------------------------------------------------------------
    .p2align 2
    .global main
    .type main, %function
main:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    // tc_cli_parse(argc, argv)
    mov x19, x0                         // argc (survives the call)
    mov x20, x1                         // argv
    bl tc_cli_parse
    // flags -> dispatch
    adrp x0, tc_opts
    add x0, x0, :lo12:tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_MANUAL
    b.ne .Lmain_manual
    tst x1, #TC_F_EMIT_FISH
    b.ne .Lmain_fish
    tst x1, #TC_F_COMPLETE_GIVEN
    b.ne .Lmain_complete
    // none of the misc actions: return 0 (a plain run is Wave E's job)
    mov w0, #0
    b .Lmain_out
.Lmain_manual:
    bl tc_misc_manual
    b .Lmain_out
.Lmain_fish:
    bl tc_misc_fish
    b .Lmain_out
.Lmain_complete:
    adrp x0, tc_opts
    add x0, x0, :lo12:tc_opts
    ldr x0, [x0, #TC_O_COMPLETE_KIND]
    bl tc_misc_complete
    b .Lmain_out
.Lmain_out:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

    .end
