// ============================================================================
// check_tc_json.S — test driver for tc_json.S.
// ============================================================================
//
//  main(): tc_cli_parse -> tc_build_exclusions -> tc_cache_open ->
//          tc_count_run -> tc_plan_presentation -> tc_json_emit ->
//          tc_cache_close -> exit 0.  The JSON module is reached DIRECTLY:
//          the plan structures tc_json_emit reads are filled by
//          tc_plan_presentation, then the module's own entry point writes the
//          document.  The text/JSON dispatch inside tc_render_report is
//          skipped on purpose — this driver only ever exercises the JSON
//          path, and test-tc-json.sh runs it with --json.
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64; tc_platform.h selects.  Linked by the Makefile
//              (tc-json-test) with the real tc_cache.o.
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
    bl tc_plan_presentation         // fill the plan tc_json_emit reads
    bl tc_json_emit                 // the JSON module's entry point
    bl tc_cache_close
    mov w0, #0
    EPILOGUE 1
    ret

    .end