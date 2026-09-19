// ============================================================================
// check_tc_cli.S — the Wave-A test driver for the CLI.
//   main() calls tc_cli_parse(argc, argv), then prints a stable dump of the
//   resolved options block + sources so test-tc-cli.sh can assert resolution.
//   On a parse/resolution error tc_cli_parse exits 2/1 itself; the harness
//   checks those exit codes + stderr directly.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

    .globl main
    .globl printf
    .globl tc_cli_parse
    .globl tc_source_str

    .p2align 2
main:
    stp x29, x30, [sp, #-16]!
    mov x19, x0                     // argc
    mov x20, x1                     // argv
    mov x0, x19
    mov x1, x20
    bl tc_cli_parse                 // exits 2/1 on errors

    // ---- channel -----------------------------------------------------------
    adrp x0, PAGE(fmt_channel)
    add x0, x0, LO12(fmt_channel)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_CHANNEL
    bl printf
    // channel source
    mov x0, #TC_SET_CHANNEL
    bl tc_load_src_id              // x0 = source id
    bl tc_source_str                // x0=ptr, x1=len
    mov x21, x0
    mov x22, x1
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x22
    mov x2, x21
    bl printf

    // ---- logs_dir ----------------------------------------------------------
    adrp x0, PAGE(fmt_logs_dir)
    add x0, x0, LO12(fmt_logs_dir)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_LOGS_DIR
    bl printf
    mov x0, #TC_SET_LOGS_DIR
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x22
    mov x2, x21
    bl printf

    // ---- window ------------------------------------------------------------
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_BEGIN_YMD]
    ldr x21, [x19, #TC_W_BEGIN_SOD]
    adrp x0, PAGE(fmt_begin)
    add x0, x0, LO12(fmt_begin)
    mov x1, x20
    mov x2, x21
    bl printf
    // begin source = window start source (static ptr or composed buffer)
    ldr x0, [x19, #TC_W_START_SRC]
    bl tc_strlen_local
    mov x21, x1
    ldr x0, [x19, #TC_W_START_SRC]
    mov x22, x0
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x21
    mov x2, x22
    bl printf
    ldr x20, [x19, #TC_W_END_YMD]
    ldr x21, [x19, #TC_W_END_SOD]
    adrp x0, PAGE(fmt_end)
    add x0, x0, LO12(fmt_end)
    mov x1, x20
    mov x2, x21
    bl printf
    // end source
    mov x0, #TC_SET_END
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x22
    mov x2, x21
    bl printf
    // window kind
    ldr x1, [x19, #TC_W_KIND]
    adrp x0, PAGE(fmt_kind)
    add x0, x0, LO12(fmt_kind)
    bl printf

    // ---- numeric settings ---------------------------------------------------
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x1, [x19, #TC_O_MIN_COUNT]
    adrp x0, PAGE(fmt_min_count)
    add x0, x0, LO12(fmt_min_count)
    bl printf
    mov x0, #TC_SET_MIN_COUNT
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x22
    mov x2, x21
    bl printf

    ldr x1, [x19, #TC_O_TOP]
    adrp x0, PAGE(fmt_top)
    add x0, x0, LO12(fmt_top)
    bl printf

    ldr x1, [x19, #TC_O_STATE_FILTER]
    adrp x0, PAGE(fmt_state)
    add x0, x0, LO12(fmt_state)
    bl printf
    mov x0, #TC_SET_STATE
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x22
    mov x2, x21
    bl printf

    ldr x1, [x19, #TC_O_SORT]
    adrp x0, PAGE(fmt_sort)
    add x0, x0, LO12(fmt_sort)
    bl printf

    // columns
    adrp x0, PAGE(fmt_columns)
    add x0, x0, LO12(fmt_columns)
    ldr x1, [x19, #TC_O_COLUMN_COUNT]
    ldr x2, [x19, #TC_O_COLUMNS + 0]
    ldr x3, [x19, #TC_O_COLUMNS + 8]
    ldr x4, [x19, #TC_O_COLUMNS + 16]
    ldr x5, [x19, #TC_O_COLUMNS + 24]
    ldr x6, [x19, #TC_O_COLUMNS + 32]
    ldr x7, [x19, #TC_O_COLUMNS + 40]
    bl printf
    ldr x0, [x19, #TC_O_COLUMNS_SRC_PTR]
    cbz x0, .Lcols_none
    mov x21, x0
    bl tc_strlen_local
    mov x22, x1
    adrp x0, PAGE(fmt_src)
    add x0, x0, LO12(fmt_src)
    mov x1, x22
    mov x2, x21
    bl printf
    b .Lcols_done
.Lcols_none:
    adrp x0, PAGE(fmt_src_none)
    add x0, x0, LO12(fmt_src_none)
    bl printf
.Lcols_done:

    ldr x1, [x19, #TC_O_HEADER_MODE]
    adrp x0, PAGE(fmt_header)
    add x0, x0, LO12(fmt_header)
    bl printf

    ldr x1, [x19, #TC_O_FLAGS]
    and x1, x1, #TC_F_JSON
    lsr x1, x1, #3
    adrp x0, PAGE(fmt_json)
    add x0, x0, LO12(fmt_json)
    bl printf

    ldr x1, [x19, #TC_O_FLAGS]
    and x1, x1, #TC_F_WATCH_PRESENT
    lsr x1, x1, #4
    adrp x0, PAGE(fmt_watch)
    add x0, x0, LO12(fmt_watch)
    bl printf

    ldr x1, [x19, #TC_O_USERS]
    adrp x0, PAGE(fmt_users)
    add x0, x0, LO12(fmt_users)
    bl printf

    ldr x1, [x19, #TC_O_FLAGS]
    adrp x0, PAGE(fmt_flags)
    add x0, x0, LO12(fmt_flags)
    bl printf

    adrp x0, PAGE(fmt_config)
    add x0, x0, LO12(fmt_config)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_CONFIG_PATH
    bl printf

    ldr x1, [x19, #TC_O_COLOR_MODE]
    adrp x0, PAGE(fmt_color)
    add x0, x0, LO12(fmt_color)
    bl printf

    mov w0, #0
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_load_src_id(x0=set id) -> x0 = the source id at TC_O_SRC[set id]
// ----------------------------------------------------------------------------
    .p2align 2
tc_load_src_id:
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    mov x2, #TC_O_SRC
    add x1, x1, x2
    mov x2, #8
    mul x0, x0, x2
    ldr x0, [x1, x0]
    ret

// ----------------------------------------------------------------------------
// tc_strlen_local(x0=s) -> x1 = length
// ----------------------------------------------------------------------------
    .p2align 2
tc_strlen_local:
    mov x1, x0
.Lsl_loop:
    ldrb w2, [x1], #1
    cbnz w2, .Lsl_loop
    sub x1, x1, x0
    sub x1, x1, #1
    ret

// ----------------------------------------------------------------------------
    RODATA
fmt_channel:    .asciz "channel=%s\n"
fmt_logs_dir:   .asciz "logs_dir=%s\n"
fmt_begin:      .asciz "begin=%lld %lld\n"
fmt_end:        .asciz "end=%lld %lld\n"
fmt_kind:       .asciz "kind=%lld\n"
fmt_min_count:  .asciz "min_count=%lld\n"
fmt_top:        .asciz "top=%lld\n"
fmt_state:      .asciz "state=%lld\n"
fmt_sort:       .asciz "sort=%lld\n"
fmt_columns:    .asciz "columns=%lld,%lld,%lld,%lld,%lld,%lld,%lld\n"
fmt_header:     .asciz "header=%lld\n"
fmt_json:       .asciz "json=%lld\n"
fmt_watch:      .asciz "watch=%lld\n"
fmt_users:      .asciz "users=%lld\n"
fmt_flags:      .asciz "flags=%lld\n"
fmt_config:     .asciz "config=%s\n"
fmt_color:      .asciz "color=%lld\n"
fmt_src:        .asciz "src=%.*s\n"
fmt_src_none:   .asciz "src=\n"

    .end
