// ============================================================================
// check_tc_core.S — test driver for tc_core.S (main() + dump).
// ============================================================================
//
//  main(argc, argv): tc_cli_parse(argc, argv) -> tc_count_run() -> dump.
//  The dump (tc_dump) is the shared contract-structure printer from
//  check_tc_dump.S, linked in by the Makefile.  Format:
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
//  Exits 0 on success; tc_fail paths exit 1 with "error: ..." on stderr.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

    .globl main
    .globl tc_cli_parse
    .globl tc_count_run
    .globl tc_dump

// ----------------------------------------------------------------------------
// main(x0=argc, x1=argv)
// ----------------------------------------------------------------------------
    .p2align 2
main:
    PROLOGUE 0
    bl tc_cli_parse
    bl tc_count_run
    bl tc_dump
    mov w0, #0
    EPILOGUE 0
    ret

    .end
