// ============================================================================
// check_tc_render.S — Phase 5 test driver for tc_render.S + tc_json.S.
// ============================================================================
//
//  main(): tc_cli_parse -> tc_build_exclusions -> tc_count_run ->
//          tc_render_report -> exit 0.  The renderer chooses text or JSON
//          from the --json flag itself.
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64; tc_platform.h selects.  Linked by the Makefile
//              (tc-render-test) with the real tc_cache.o.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
    .text

    .globl main
    FUNC_TYPE(main)
main:
    PROLOGUE 1
    mov x19, x0                     // argc
    mov x20, x1                     // argv
    mov x0, x19
    mov x1, x20
    bl tc_cli_parse
    bl tc_build_exclusions
    bl tc_cache_open
    bl tc_count_run
    bl tc_render_report
    bl tc_cache_close
    mov w0, #0
    EPILOGUE 1
    ret

    .end
