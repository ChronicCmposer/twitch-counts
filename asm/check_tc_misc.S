// ============================================================================
// check_tc_misc.S — test driver for tc_misc.S (twitch-counts).
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//  Linking:    by the Makefile (build/<os>/tc-misc-test).
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
//  This is the shape main() takes in tc_main.S.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"

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
    FUNC_TYPE(main)
main:
    PROLOGUE 1
    // tc_cli_parse(argc, argv)
    mov x19, x0                         // argc (survives the call)
    mov x20, x1                         // argv
    bl tc_cli_parse
    // flags -> dispatch
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_MANUAL
    b.ne .Lmain_manual
    tst x1, #TC_F_EMIT_FISH
    b.ne .Lmain_fish
    tst x1, #TC_F_COMPLETE_GIVEN
    b.ne .Lmain_complete
    // none of the misc actions: return 0 (a plain run is tc_main.S's job)
    mov w0, #0
    b .Lmain_out
.Lmain_manual:
    bl tc_misc_manual
    b .Lmain_out
.Lmain_fish:
    bl tc_misc_fish
    b .Lmain_out
.Lmain_complete:
    LEA x0, tc_opts
    ldr x0, [x0, #TC_O_COMPLETE_KIND]
    bl tc_misc_complete
    b .Lmain_out
.Lmain_out:
    EPILOGUE 1
    ret

    .end
