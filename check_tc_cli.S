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
    .globl tc_printf_i
    .globl tc_printf_ii
    .globl tc_printf_ip
    .globl tc_printf_p
    .globl tc_printf_7i

    .p2align 2
main:
    PROLOGUE 0
    mov x19, x0                     // argc
    mov x20, x1                     // argv
    mov x0, x19
    mov x1, x20
    bl tc_cli_parse                 // exits 2/1 on errors

    // ---- channel -----------------------------------------------------------
    LEA x0, fmt_channel
    LEA_OFF x1, tc_opts, TC_O_CHANNEL
    bl tc_printf_p
    // channel source
    mov x0, #TC_SET_CHANNEL
    bl tc_load_src_id              // x0 = source id
    bl tc_source_str                // x0=ptr, x1=len
    mov x21, x0
    mov x22, x1
    LEA x0, fmt_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip

    // ---- logs_dir ----------------------------------------------------------
    LEA x0, fmt_logs_dir
    LEA_OFF x1, tc_opts, TC_O_LOGS_DIR
    bl tc_printf_p
    mov x0, #TC_SET_LOGS_DIR
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    LEA x0, fmt_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip

    // ---- window ------------------------------------------------------------
    LEA x19, tc_window
    ldr x20, [x19, #TC_W_BEGIN_YMD]
    ldr x21, [x19, #TC_W_BEGIN_SOD]
    LEA x0, fmt_begin
    mov x1, x20
    mov x2, x21
    bl tc_printf_ii
    // begin source = window start source (static ptr or composed buffer)
    ldr x0, [x19, #TC_W_START_SRC]
    bl tc_strlen_local
    mov x21, x1
    ldr x0, [x19, #TC_W_START_SRC]
    mov x22, x0
    LEA x0, fmt_src
    mov x1, x21
    mov x2, x22
    bl tc_printf_ip
    ldr x20, [x19, #TC_W_END_YMD]
    ldr x21, [x19, #TC_W_END_SOD]
    LEA x0, fmt_end
    mov x1, x20
    mov x2, x21
    bl tc_printf_ii
    // end source
    mov x0, #TC_SET_END
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    LEA x0, fmt_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip
    // window kind
    ldr x1, [x19, #TC_W_KIND]
    LEA x0, fmt_kind
    bl tc_printf_i

    // ---- numeric settings ---------------------------------------------------
    LEA x19, tc_opts
    ldr x1, [x19, #TC_O_MIN_COUNT]
    LEA x0, fmt_min_count
    bl tc_printf_i
    mov x0, #TC_SET_MIN_COUNT
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    LEA x0, fmt_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip

    ldr x1, [x19, #TC_O_TOP]
    LEA x0, fmt_top
    bl tc_printf_i

    ldr x1, [x19, #TC_O_STATE_FILTER]
    LEA x0, fmt_state
    bl tc_printf_i
    mov x0, #TC_SET_STATE
    bl tc_load_src_id
    bl tc_source_str
    mov x21, x0
    mov x22, x1
    LEA x0, fmt_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip

    ldr x1, [x19, #TC_O_SORT]
    LEA x0, fmt_sort
    bl tc_printf_i

    // columns
    LEA x0, fmt_columns
    ldr x1, [x19, #TC_O_COLUMN_COUNT]
    ldr x2, [x19, #TC_O_COLUMNS + 0]
    ldr x3, [x19, #TC_O_COLUMNS + 8]
    ldr x4, [x19, #TC_O_COLUMNS + 16]
    ldr x5, [x19, #TC_O_COLUMNS + 24]
    ldr x6, [x19, #TC_O_COLUMNS + 32]
    ldr x7, [x19, #TC_O_COLUMNS + 40]
    bl tc_printf_7i
    ldr x0, [x19, #TC_O_COLUMNS_SRC_PTR]
    cbz x0, .Lcols_none
    mov x21, x0
    bl tc_strlen_local
    mov x22, x1
    LEA x0, fmt_src
    mov x1, x22
    mov x2, x21
    bl tc_printf_ip
    b .Lcols_done
.Lcols_none:
    LEA x0, fmt_src_none
    bl printf
.Lcols_done:

    ldr x1, [x19, #TC_O_HEADER_MODE]
    LEA x0, fmt_header
    bl tc_printf_i

    ldr x1, [x19, #TC_O_FLAGS]
    and x1, x1, #TC_F_JSON
    lsr x1, x1, #3
    LEA x0, fmt_json
    bl tc_printf_i

    ldr x1, [x19, #TC_O_FLAGS]
    and x1, x1, #TC_F_WATCH_PRESENT
    lsr x1, x1, #4
    LEA x0, fmt_watch
    bl tc_printf_i

    ldr x1, [x19, #TC_O_USERS]
    LEA x0, fmt_users
    bl tc_printf_i

    ldr x1, [x19, #TC_O_FLAGS]
    LEA x0, fmt_flags
    bl tc_printf_i

    LEA x0, fmt_config
    LEA_OFF x1, tc_opts, TC_O_CONFIG_PATH
    bl tc_printf_p

    ldr x1, [x19, #TC_O_COLOR_MODE]
    LEA x0, fmt_color
    bl tc_printf_i

    mov w0, #0
    EPILOGUE 0
    ret

// ----------------------------------------------------------------------------
// tc_load_src_id(x0=set id) -> x0 = the source id at TC_O_SRC[set id]
// ----------------------------------------------------------------------------
    .p2align 2
tc_load_src_id:
    LEA x1, tc_opts
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
