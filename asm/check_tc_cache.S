// ============================================================================
// check_tc_cache.S — test driver for tc_cache.S (main() + dump).
// ============================================================================
//
//  main(argc, argv): tc_cli_parse(argc, argv) -> tc_build_exclusions() ->
//    tc_cache_open() -> tc_count_run() -> dump -> tc_cache_close().
//  The dump (tc_dump) is the shared contract-structure printer from
//  check_tc_dump.S, linked in by the Makefile; this driver adds the
//  cachestatus line and the cache debug dump after it:
//
//    channel=<resolved dir name>
//    window begin=<ymd>:<sod> end=<ymd>:<sod> kind=<k> width=<w> found=<f> req=<r>
//    listing <n>
//    <ymd> <name>
//    users <n>
//    <login> <live> <offline> <unknown>
//    tally files=<f> messages=<m> parsed=<p> states=<l>:<o>:<u> excl=<l>:<o>:<u> unreadable=<u>
//    unreadable <name> <reason>
//    cachestatus used=<0|1> reused=<n> parsed=<n> problem=<text|-> rebuilt=<text|-> path=<text|->
//    cachetables ... / cachecounts ... / cachefile ... / cachecount ...  (when open)
//
//  The one binary covers every cache mode through the CLI flags:
//    default          cache enabled (HOME/XDG_CACHE_HOME decides the path)
//    --no-cache       cache disabled, no db touched
//    --rebuild-cache  purge the channel then reparse everything
//
//  Exits 0 on success; tc_fail paths exit 1 with "error: ..." on stderr.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

    .globl main
    .globl tc_cli_parse
    .globl tc_build_exclusions
    .globl tc_count_run
    .globl tc_cache_open
    .globl tc_cache_close
    .globl tc_cache_status
    .globl tc_cache_debug_dump
    .globl tc_dump

// ----------------------------------------------------------------------------
// main(x0=argc, x1=argv)
// ----------------------------------------------------------------------------
    .p2align 2
main:
    PROLOGUE 0
    bl tc_cli_parse
    bl tc_build_exclusions
    bl tc_cache_open
    bl tc_count_run
    bl tc_dump
    bl tc_cache_status
    bl tc_dump_cache_status
    bl tc_cache_debug_dump
    bl tc_cache_close
    mov w0, #0
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// tc_dump_cache_status — print the cachestatus line from tc_cache_status().
//   in: x0=used, x1=reused, x2=parsed, x3=problem, x4=rebuilt, x5=path
// ----------------------------------------------------------------------------
    .p2align 2
tc_dump_cache_status:
    PROLOGUE 3
    mov x19, x0                         // used
    mov x20, x1                         // reused
    mov x21, x2                         // parsed
    mov x22, x3                         // problem
    mov x23, x4                         // rebuilt
    mov x24, x5                         // path
    LEA x0, s_cs_used
    bl tc_puts
    mov x0, x19
    bl tc_putu64
    LEA x0, s_cs_reused
    bl tc_puts
    mov x0, x20
    bl tc_putu64
    LEA x0, s_cs_parsed
    bl tc_puts
    mov x0, x21
    bl tc_putu64
    LEA x0, s_cs_problem
    bl tc_puts
    mov x0, x22
    cbz x0, .Ldcs_problem_dash
    bl tc_puts
    b .Ldcs_problem_done
.Ldcs_problem_dash:
    LEA x0, s_dash
    bl tc_puts
.Ldcs_problem_done:
    LEA x0, s_cs_rebuilt
    bl tc_puts
    mov x0, x23
    cbz x0, .Ldcs_rebuilt_dash
    bl tc_puts
    b .Ldcs_rebuilt_done
.Ldcs_rebuilt_dash:
    LEA x0, s_dash
    bl tc_puts
.Ldcs_rebuilt_done:
    LEA x0, s_cs_path
    bl tc_puts
    mov x0, x24
    cbz x0, .Ldcs_path_dash
    bl tc_puts
    b .Ldcs_path_done
.Ldcs_path_dash:
    LEA x0, s_dash
    bl tc_puts
.Ldcs_path_done:
    LEA x0, s_newline
    bl tc_puts
    EPILOGUE 3
    ret

    RODATA
s_newline:      .asciz "\n"
s_cs_used:      .asciz "cachestatus used="
s_cs_reused:    .asciz " reused="
s_cs_parsed:    .asciz " parsed="
s_cs_problem:   .asciz " problem="
s_cs_rebuilt:   .asciz " rebuilt="
s_cs_path:      .asciz " path="
s_dash:         .asciz "-"

    .end
