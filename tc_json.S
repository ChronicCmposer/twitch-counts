// ============================================================================
// tc_json.S — the self-describing JSON report for twitch-counts-full (Phase 5)
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static — musl libc + crt1.o
//
//  Byte-for-byte port of the Python reference's emit_json / build_report /
//  report_schema / report_failure (2992-3008, 4804-4808, 2784-2989).
//  The embedded schema is tc_json_schema.inc (json.dumps(report_schema(),
//  indent=2) re-indented +2 under the "schema" key, outer braces absorbed).
//
//  Exported:
//    tc_json_emit()        -> 0  write the full document to stdout.
//    tc_json_err(x0=msg)         write {"error": <msg>} to stderr, exit 1
//                                (the --json report_failure shape).
//
//  Reads the plan structures filled by tc_render.S (tc_plan_*) plus the
//  frozen contract structures (tc_opts / tc_window / tc_tally / tc_users /
//  tc_excl_*).  Integers carry no thousands separators, matching json.dump;
//  keys appear in insertion order; strings are escaped with
//  ensure_ascii=False semantics.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
#include "tc_json_schema.inc"

// ----------------------------------------------------------------------------
// Externals
// ----------------------------------------------------------------------------
    .globl write
    .globl exit
    .globl clock_gettime
    .globl localtime_r
    .globl tc_strlen
    .globl tc_source_str
    .globl tc_channel_name
    .globl tc_fail

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ STDOUT,          1
    .equ STDERR,          2
    .equ JBUF_SZ,         16384
    .equ JISO_SZ,         64
    .equ CLOCK_REALTIME,  0
    .equ TM_TM_YEAR,      20             // struct tm offsets (aarch64 musl)
    .equ TM_TM_MON,       16
    .equ TM_TM_MDAY,      12
    .equ TM_TM_HOUR,      8
    .equ TM_TM_MIN,       4
    .equ TM_TM_SEC,       0

// ----------------------------------------------------------------------------
// .bss
// ----------------------------------------------------------------------------
    .bss
    .p2align 4
tc_json_buf:        .skip JBUF_SZ
tc_json_cur:        .skip 8
tc_json_fd:         .skip 8
tc_json_iso:        .skip JISO_SZ
tc_json_tm:         .skip 64
tc_json_ts:         .skip 16

// ----------------------------------------------------------------------------
// .rodata — fixed fragments; lengths are label differences
// ----------------------------------------------------------------------------
    RODATA
s_j_open: .asciz "{\n"
s_j_err_open: .asciz "{\"error\": "
s_j_err_close: .asciz "}\n"
s_j_q: .asciz "\""
s_j_colon: .asciz ": "
s_j_nl: .asciz "\n"
s_j_comma_nl: .asciz ",\n"
s_j_null: .asciz "null"
s_j_true: .asciz "true"
s_j_false: .asciz "false"
s_j_schema_version: .asciz "  \"schema_version\": \"2.1.0\",\n"
s_j_generated_at: .asciz "  \"generated_at\": "
s_j_query: .asciz "  \"query\": {\n"
s_j_qchannel: .asciz "    \"channel\": "
s_j_qbegin: .asciz "    \"begin\": "
s_j_qend: .asciz "    \"end\": "
s_j_qmin: .asciz "    \"min_count\": "
s_j_qtop: .asciz "    \"top\": "
s_j_qstate: .asciz "    \"state\": "
s_j_qexcluded: .asciz "    \"excluded\": "
s_j_qsort: .asciz "    \"sort\": "
s_j_qsf: .asciz "    \"share_floor\": {\n"
s_j_sf_req: .asciz "      \"requested\": "
s_j_sf_app: .asciz "      \"applied\": "
s_j_qsources: .asciz "    \"sources\": {\n"
s_j_query_close: .asciz "  },\n"
s_j_totals: .asciz "  \"totals\": {\n"
s_j_t_shown: .asciz "    \"users_shown\": "
s_j_t_above: .asciz "    \"users_above_threshold\": "
s_j_t_inrange: .asciz "    \"users_in_range\": "
s_j_t_excl: .asciz "    \"users_excluded\": "
s_j_t_mshown: .asciz "    \"messages_shown\": "
s_j_t_minrange: .asciz "    \"messages_in_range\": "
s_j_t_mhidden: .asciz "    \"messages_hidden\": "
s_j_t_mexcl: .asciz "    \"messages_excluded\": "
s_j_t_trunc: .asciz "    \"truncated\": "
s_j_t_states: .asciz "    \"states\": "
s_j_t_files: .asciz "    \"log_files\": "
s_j_t_below: .asciz "    \"users_below_share_floor\": "
s_j_t_cache: .asciz "    \"cache\": {\n"
s_j_cache_used: .asciz "      \"used\": "
s_j_cache_days: .asciz "      \"days_reused\": "
s_j_cache_prob: .asciz "      \"problem\": "
s_j_t_unreadable: .asciz "    \"unreadable\": "
s_j_rows: .asciz "  \"rows\": "
s_j_row_open: .asciz "{\n"
s_j_login: .asciz "      \"login\": "
s_j_count: .asciz "      \"count\": "
s_j_states_k: .asciz "      \"states\": "
s_j_ind4: .asciz "    "
s_j_ind6: .asciz "      "
s_j_ind8: .asciz "        "
s_j_close2: .asciz "\n  }"
s_j_rows_close: .asciz "  ]"
s_j_close4: .asciz "\n    }"
s_j_close4nl: .asciz "    }"
s_j_close6nl: .asciz "      }"
s_j_close6: .asciz "\n      }"
s_j_close8: .asciz "\n        }"
s_j_end: .asciz "\n}\n"

    .p2align 3
state_names_json:
    .quad s_jn_live
    .quad s_jn_offline
    .quad s_jn_unknown
s_jn_live:          .asciz "live"
s_jn_offline:       .asciz "offline"
s_jn_unknown:       .asciz "unknown"

metric_names_json:
    .quad s_jm_count
    .quad s_jm_login
    .quad s_jm_live
    .quad s_jm_offline
    .quad s_jm_unknown
    .quad s_jm_offshare
    .quad s_jm_liveshare
s_jm_count:         .asciz "count"
s_jm_login:         .asciz "login"
s_jm_live:          .asciz "live"
s_jm_offline:       .asciz "offline"
s_jm_unknown:       .asciz "unknown"
s_jm_offshare:      .asciz "offline-share"
s_jm_liveshare:     .asciz "live-share"

s_jn_none:          .asciz "none"
s_j_not_filtered:   .asciz "not filtered"

    .text

// jinit(fd) — reset the JSON buffer
    .p2align 2
jinit:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    adrp x0, PAGE(tc_json_fd)
    add x0, x0, LO12(tc_json_fd)
    str x19, [x0]
    adrp x0, PAGE(tc_json_cur)
    add x0, x0, LO12(tc_json_cur)
    str xzr, [x0]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// jflush() — write the buffered bytes
    .p2align 2
jflush:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x0, PAGE(tc_json_cur)
    add x0, x0, LO12(tc_json_cur)
    ldr x19, [x0]
    cbz x19, .Ljfl_done
    str xzr, [x0]
    adrp x0, PAGE(tc_json_fd)
    add x0, x0, LO12(tc_json_fd)
    ldr x0, [x0]
    adrp x1, PAGE(tc_json_buf)
    add x1, x1, LO12(tc_json_buf)
    mov x2, x19
    bl write
.Ljfl_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// jputc(c) — append one byte, flushing when full
    .p2align 2
jputc:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov w19, w0
    adrp x0, PAGE(tc_json_cur)
    add x0, x0, LO12(tc_json_cur)
    ldr x20, [x0]
    cmp x20, #JBUF_SZ
    b.lt .Ljpc_ok
    bl jflush
    mov x20, #0
.Ljpc_ok:
    adrp x1, PAGE(tc_json_buf)
    add x1, x1, LO12(tc_json_buf)
    strb w19, [x1, x20]
    add x20, x20, #1
    adrp x1, PAGE(tc_json_cur)
    add x1, x1, LO12(tc_json_cur)
    str x20, [x1]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// jputraw(s, len) — append len raw bytes
    .p2align 2
jputraw:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // src
    mov x20, x1                        // len
    mov x21, #0                        // i
.Ljpr_loop:
    cmp x21, x20
    b.ge .Ljpr_done
    ldrb w22, [x19, x21]
    mov w0, w22
    bl jputc
    add x21, x21, #1
    b .Ljpr_loop
.Ljpr_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// jputs(s) — append a NUL-terminated string (length via tc_strlen)
    .p2align 2
jputs:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl jputraw
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// jquoted(s) — append the JSON-escaped, quoted form of a NUL-terminated string
    .p2align 2
jquoted:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov w0, #'"'
    bl jputc
    mov x20, x19                       // scan pointer
.Ljq_loop:
    ldrb w21, [x20]
    cbz w21, .Ljq_done
    mov w0, w21
    cmp w21, #'"'
    b.eq .Ljq_esc_quote
    cmp w21, #'\\'
    b.eq .Ljq_esc_back
    cmp w21, #0x08
    b.eq .Ljq_esc_b
    cmp w21, #0x09
    b.eq .Ljq_esc_t
    cmp w21, #0x0a
    b.eq .Ljq_esc_n
    cmp w21, #0x0c
    b.eq .Ljq_esc_f
    cmp w21, #0x0d
    b.eq .Ljq_esc_r
    cmp w21, #0x20
    b.lt .Ljq_esc_u
    bl jputc
    b .Ljq_next
.Ljq_esc_quote:
    mov w0, #'\\'
    bl jputc
    mov w0, #'"'
    bl jputc
    b .Ljq_next
.Ljq_esc_back:
    mov w0, #'\\'
    bl jputc
    mov w0, #'\\'
    bl jputc
    b .Ljq_next
.Ljq_esc_b:
    mov w0, #'\\'
    bl jputc
    mov w0, #'b'
    bl jputc
    b .Ljq_next
.Ljq_esc_t:
    mov w0, #'\\'
    bl jputc
    mov w0, #'t'
    bl jputc
    b .Ljq_next
.Ljq_esc_n:
    mov w0, #'\\'
    bl jputc
    mov w0, #'n'
    bl jputc
    b .Ljq_next
.Ljq_esc_f:
    mov w0, #'\\'
    bl jputc
    mov w0, #'f'
    bl jputc
    b .Ljq_next
.Ljq_esc_r:
    mov w0, #'\\'
    bl jputc
    mov w0, #'r'
    bl jputc
    b .Ljq_next
.Ljq_esc_u:
    // \u00XX with lowercase hex
    mov w0, #'\\'
    bl jputc
    mov w0, #'u'
    bl jputc
    mov w0, #'0'
    bl jputc
    mov w0, #'0'
    bl jputc
    lsr w22, w21, #4
    and w22, w22, #0xF
    mov w0, w22
    bl jhex
    and w22, w21, #0xF
    mov w0, w22
    bl jhex
    b .Ljq_next
.Ljq_next:
    add x20, x20, #1
    b .Ljq_loop
.Ljq_done:
    mov w0, #'"'
    bl jputc
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// jhex(nibble) — append a lowercase hex digit
    .p2align 2
jhex:
    stp x29, x30, [sp, #-16]!
    cmp w0, #10
    b.lt .Ljh_digit
    sub w0, w0, #10
    add w0, w0, #'a'
    b .Ljh_go
.Ljh_digit:
    add w0, w0, #'0'
.Ljh_go:
    bl jputc
    ldp x29, x30, [sp], #16
    ret

// jint(v) — append a decimal integer (no commas)
    .p2align 2
jint:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    // digits into the buffer backward on the stack
    sub sp, sp, #32
    add x20, sp, #20
    cmp x19, #0
    b.ne .Lji_digits
    mov w2, #'0'
    strb w2, [x20, #-1]!
    b .Lji_emit
.Lji_digits:
    mov x2, #10
.Lji_loop:
    udiv x3, x19, x2
    msub x4, x3, x2, x19
    add x4, x4, #'0'
    strb w4, [x20, #-1]!
    mov x19, x3
    cbnz x19, .Lji_loop
.Lji_emit:
    add x21, sp, #20
.Lji_emit_loop:
    cmp x20, x21
    b.ge .Lji_done
    ldrb w22, [x20], #1
    mov w0, w22
    bl jputc
    b .Lji_emit_loop
.Lji_done:
    add sp, sp, #32
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// jbool(v) — "true"/"false"
    .p2align 2
jbool:
    stp x29, x30, [sp, #-16]!
    cbz x0, .Ljbo_false
    adrp x0, PAGE(s_j_true)
    add x0, x0, LO12(s_j_true)
    bl jputs
    b .Ljbo_done
.Ljbo_false:
    adrp x0, PAGE(s_j_false)
    add x0, x0, LO12(s_j_false)
    bl jputs
.Ljbo_done:
    ldp x29, x30, [sp], #16
    ret

// json_now_iso(buf) — "YYYY-MM-DDTHH:MM:SS" local time (generated_at)
    .p2align 2
json_now_iso:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x0, #CLOCK_REALTIME
    adrp x1, PAGE(tc_json_ts)
    add x1, x1, LO12(tc_json_ts)
    bl clock_gettime
    adrp x0, PAGE(tc_json_ts)
    add x0, x0, LO12(tc_json_ts)
    adrp x1, PAGE(tc_json_tm)
    add x1, x1, LO12(tc_json_tm)
    bl localtime_r
    adrp x0, PAGE(tc_json_tm)
    add x0, x0, LO12(tc_json_tm)
    ldr w20, [x0, #TM_TM_YEAR]
    add x20, x20, #1900
    ldr w21, [x0, #TM_TM_MON]
    add x21, x21, #1
    ldr w22, [x0, #TM_TM_MDAY]
    mov x1, #10000
    mul x20, x20, x1
    mov x1, #100
    mul x21, x21, x1
    add x20, x20, x21
    add x20, x20, x22                  // ymd
    ldr w21, [x0, #TM_TM_HOUR]
    ldr w22, [x0, #TM_TM_MIN]
    ldr w23, [x0, #TM_TM_SEC]
    mov x1, #3600
    mul x21, x21, x1
    mov x1, #60
    madd x21, x22, x1, x21
    add x21, x21, x23                  // sod
    mov x0, x19
    mov x1, x20
    mov x2, x21
    mov w3, #'T'
    bl json_fmt_dt
    mov w1, #0
    strb w1, [x0]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// Local number/date formatting (duplicated from tc_render.S: the helpers there
// are module-private).  fmt4/fmt2/fmt_dt write digits only, no NUL.
// ============================================================================

// fmt2(dst, w1=0..99) -> dst+2 zero-padded
    .p2align 2
fmt2:
    mov x2, #10
    udiv x3, x1, x2
    msub x4, x3, x2, x1
    add x3, x3, #'0'
    strb w3, [x0], #1
    add x4, x4, #'0'
    strb w4, [x0], #1
    ret

// fmt4(dst, x1=0..9999) -> dst+4
    .p2align 2
fmt4:
    mov x2, #1000
    udiv x3, x1, x2
    msub x4, x3, x2, x1
    add x3, x3, #'0'
    strb w3, [x0], #1
    mov x2, #100
    udiv x3, x4, x2
    msub x5, x3, x2, x4
    add x3, x3, #'0'
    strb w3, [x0], #1
    mov x2, #10
    udiv x3, x5, x2
    msub x6, x3, x2, x5
    add x3, x3, #'0'
    strb w3, [x0], #1
    add x6, x6, #'0'
    strb w6, [x0], #1
    ret

// json_fmt_dt(dst, ymd, sod, sep) -> dst+19, "YYYY-MM-DD<sep>HH:MM:SS"
    .p2align 2
json_fmt_dt:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1                        // ymd
    mov x21, x2                        // sod
    mov w22, w3                        // separator
    mov x1, x20
    mov x2, #10000
    udiv x6, x20, x2
    mov x0, x19
    mov x1, x6
    bl fmt4
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #100
    udiv x6, x20, x2
    mov x8, #100
    udiv x9, x6, x8
    msub x9, x9, x8, x6
    mov w1, w9
    bl fmt2
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #100
    udiv x6, x20, x2
    msub x6, x6, x2, x20
    mov w1, w6
    bl fmt2
    strb w22, [x0], #1
    mov x1, x21
    mov x2, #3600
    udiv x6, x21, x2
    mov w1, w6
    bl fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #3600
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    mov w1, w6
    bl fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #3600
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    msub x6, x6, x2, x9
    mov w1, w6
    bl fmt2
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_json_emit — the full report document.
// ============================================================================
    .p2align 2
    .global tc_json_emit
    FUNC_TYPE(tc_json_emit)
tc_json_emit:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x0, #STDOUT
    bl jinit
    // { + schema blob
    adrp x0, PAGE(s_j_open)
    add x0, x0, LO12(s_j_open)
    mov x1, #2
    bl jputraw
    adrp x0, PAGE(tc_json_schema_blob)
    add x0, x0, LO12(tc_json_schema_blob)
    mov x1, #tc_json_schema_blob_len
    bl jputraw
    // schema_version + generated_at
    adrp x0, PAGE(s_j_schema_version)
    add x0, x0, LO12(s_j_schema_version)
    bl jputs
    adrp x0, PAGE(s_j_generated_at)
    add x0, x0, LO12(s_j_generated_at)
    bl jputs
    adrp x0, PAGE(tc_json_iso)
    add x0, x0, LO12(tc_json_iso)
    bl json_now_iso
    adrp x0, PAGE(tc_json_iso)
    add x0, x0, LO12(tc_json_iso)
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // query
    adrp x0, PAGE(s_j_query)
    add x0, x0, LO12(s_j_query)
    bl jputs
    // channel
    adrp x0, PAGE(s_j_qchannel)
    add x0, x0, LO12(s_j_qchannel)
    bl jputs
    bl tc_channel_name
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // begin
    adrp x0, PAGE(s_j_qbegin)
    add x0, x0, LO12(s_j_qbegin)
    bl jputs
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    adrp x20, PAGE(tc_json_iso)
    add x20, x20, LO12(tc_json_iso)
    mov x0, x20
    ldr x1, [x19, #TC_W_BEGIN_YMD]
    ldr x2, [x19, #TC_W_BEGIN_SOD]
    mov w3, #'T'
    bl json_fmt_dt
    mov w1, #0
    strb w1, [x0]
    mov x0, x20
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // end
    adrp x0, PAGE(s_j_qend)
    add x0, x0, LO12(s_j_qend)
    bl jputs
    adrp x20, PAGE(tc_json_iso)
    add x20, x20, LO12(tc_json_iso)
    mov x0, x20
    ldr x1, [x19, #TC_W_END_YMD]
    ldr x2, [x19, #TC_W_END_SOD]
    mov w3, #'T'
    bl json_fmt_dt
    mov w1, #0
    strb w1, [x0]
    mov x0, x20
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // min_count
    adrp x0, PAGE(s_j_qmin)
    add x0, x0, LO12(s_j_qmin)
    bl jputs
    ldr x0, [x19, #TC_W_THRESHOLD]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // top
    adrp x0, PAGE(s_j_qtop)
    add x0, x0, LO12(s_j_qtop)
    bl jputs
    adrp x19, PAGE(tc_plan_limit)
    add x19, x19, LO12(tc_plan_limit)
    ldr x20, [x19]
    cbz x20, .Lje_top_null
    mov x0, x20
    bl jint
    b .Lje_top_done
.Lje_top_null:
    adrp x0, PAGE(s_j_null)
    add x0, x0, LO12(s_j_null)
    bl jputs
.Lje_top_done:
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // state
    adrp x0, PAGE(s_j_qstate)
    add x0, x0, LO12(s_j_qstate)
    bl jputs
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_STATE_FILTER]
    cbz x20, .Lje_state_null
    adrp x0, PAGE(state_names_json)
    add x0, x0, LO12(state_names_json)
    sub x1, x20, #1
    ldr x0, [x0, x1, lsl #3]
    bl jquoted
    b .Lje_state_done
.Lje_state_null:
    adrp x0, PAGE(s_j_null)
    add x0, x0, LO12(s_j_null)
    bl jputs
.Lje_state_done:
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // excluded
    adrp x0, PAGE(s_j_qexcluded)
    add x0, x0, LO12(s_j_qexcluded)
    bl jputs
    bl emit_excluded_array
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // sort
    adrp x0, PAGE(s_j_qsort)
    add x0, x0, LO12(s_j_qsort)
    bl jputs
    adrp x19, PAGE(tc_plan_sort)
    add x19, x19, LO12(tc_plan_sort)
    ldr x20, [x19]
    adrp x0, PAGE(metric_names_json)
    add x0, x0, LO12(metric_names_json)
    ldr x0, [x0, x20, lsl #3]
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // share_floor
    adrp x0, PAGE(s_j_qsf)
    add x0, x0, LO12(s_j_qsf)
    bl jputs
    adrp x0, PAGE(s_j_sf_req)
    add x0, x0, LO12(s_j_sf_req)
    bl jputs
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x0, [x19, #TC_O_SHARE_FLOOR]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    adrp x0, PAGE(s_j_sf_app)
    add x0, x0, LO12(s_j_sf_app)
    bl jputs
    adrp x19, PAGE(tc_plan_share_floor)
    add x19, x19, LO12(tc_plan_share_floor)
    ldr x20, [x19]
    cbz x20, .Lje_sf_false
    adrp x0, PAGE(s_j_true)
    add x0, x0, LO12(s_j_true)
    bl jputs
    b .Lje_sf_done
.Lje_sf_false:
    adrp x0, PAGE(s_j_false)
    add x0, x0, LO12(s_j_false)
    bl jputs
.Lje_sf_done:
    adrp x0, PAGE(s_j_close4)
    add x0, x0, LO12(s_j_close4)
    bl jputs
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // sources
    adrp x0, PAGE(s_j_qsources)
    add x0, x0, LO12(s_j_qsources)
    bl jputs
    bl emit_sources
    adrp x0, PAGE(s_j_close4nl)
    add x0, x0, LO12(s_j_close4nl)
    bl jputs
    adrp x0, PAGE(s_j_nl)
    add x0, x0, LO12(s_j_nl)
    bl jputs
    // close query, open totals
    adrp x0, PAGE(s_j_query_close)
    add x0, x0, LO12(s_j_query_close)
    bl jputs
    adrp x0, PAGE(s_j_totals)
    add x0, x0, LO12(s_j_totals)
    bl jputs
    bl emit_totals
    adrp x0, PAGE(s_j_close2)
    add x0, x0, LO12(s_j_close2)
    bl jputs
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // rows
    adrp x0, PAGE(s_j_rows)
    add x0, x0, LO12(s_j_rows)
    bl jputs
    bl emit_rows
    adrp x0, PAGE(s_j_end)
    add x0, x0, LO12(s_j_end)
    bl jputs
    bl jflush
    mov x0, #0
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// emit_excluded_array — the sorted exclusion logins.
// ============================================================================
    .p2align 2
emit_excluded_array:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, PAGE(tc_plan_excl_names_n)
    add x19, x19, LO12(tc_plan_excl_names_n)
    ldr x20, [x19]                    // n
    cbz x20, .Ljea_empty
    mov w0, #'['
    bl jputc
    mov w0, #'\n'
    bl jputc
    adrp x21, PAGE(tc_plan_excl_names)
    add x21, x21, LO12(tc_plan_excl_names)
    ldr x21, [x21]
    mov x22, #0
.Ljea_loop:
    cmp x22, x20
    b.ge .Ljea_done
    adrp x0, PAGE(s_j_ind6)
    add x0, x0, LO12(s_j_ind6)
    mov x1, #6
    bl jputraw
    mov x2, #26
    mul x2, x22, x2
    add x0, x21, x2
    bl jquoted
    add x9, x22, #1
    cmp x9, x20
    b.ge .Ljea_nl
    mov w0, #','
    bl jputc
.Ljea_nl:
    mov w0, #'\n'
    bl jputc
    add x22, x22, #1
    b .Ljea_loop
.Ljea_done:
    adrp x0, PAGE(s_j_ind4)
    add x0, x0, LO12(s_j_ind4)
    mov x1, #4
    bl jputraw
    mov w0, #']'
    bl jputc
    b .Ljea_out
.Ljea_empty:
    mov w0, #'['
    bl jputc
    mov w0, #']'
    bl jputc
.Ljea_out:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// src_str(set_id) -> x0 = source string ptr
// ============================================================================
    .p2align 2
src_str:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    movz x2, #TC_O_SRC
    add x0, x0, x2
    ldr x0, [x0, x19, lsl #3]
    bl tc_source_str
    ldp x19, x30, [sp], #16
    ret

// src_entry(key, set_id) — emit `      "key": <source of set_id>,\n`
    .p2align 2
src_entry:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // key
    mov x20, x1                        // set id
    adrp x0, PAGE(s_j_ind6)
    add x0, x0, LO12(s_j_ind6)
    mov x1, #6
    bl jputraw
    mov x0, x19
    bl jquoted
    adrp x0, PAGE(s_j_colon)
    add x0, x0, LO12(s_j_colon)
    bl jputs
    mov x0, x20
    bl src_str
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// src_entry_ptr(key, value_ptr) — `      "key": "<value>",\n` (value is a
// direct pointer, not a set id; same shape as src_entry)
    .p2align 2
src_entry_ptr:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // key
    mov x20, x1                        // value ptr
    adrp x0, PAGE(s_j_ind6)
    add x0, x0, LO12(s_j_ind6)
    mov x1, #6
    bl jputraw
    mov x0, x19
    bl jquoted
    adrp x0, PAGE(s_j_colon)
    add x0, x0, LO12(s_j_colon)
    bl jputs
    mov x0, x20
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// src_entry_last(key, value_ptr) — `      "key": "<value>",\n` (last, no comma)
    .p2align 2
src_entry_last:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // key
    mov x20, x1                        // value ptr
    adrp x0, PAGE(s_j_ind6)
    add x0, x0, LO12(s_j_ind6)
    mov x1, #6
    bl jputraw
    mov x0, x19
    bl jquoted
    adrp x0, PAGE(s_j_colon)
    add x0, x0, LO12(s_j_colon)
    bl jputs
    mov x0, x20
    bl jquoted
    mov w0, #'\n'
    bl jputc
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// emit_sources — the sorted provenance map.
// ============================================================================
    .p2align 2
emit_sources:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    // begin (value is a direct pointer, not a set id)
    adrp x0, PAGE(s_js_begin)
    add x0, x0, LO12(s_js_begin)
    adrp x1, PAGE(tc_window)
    add x1, x1, LO12(tc_window)
    ldr x1, [x1, #TC_W_START_SRC]
    bl src_entry_ptr
    // channel
    adrp x0, PAGE(s_js_channel)
    add x0, x0, LO12(s_js_channel)
    mov x1, #TC_SET_CHANNEL
    bl src_entry
    // end (only when not defaulted)
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_SRC + TC_SET_END*8]
    cmp x20, #TC_SRC_DEFAULT_NOW
    b.eq .Ljes_show
    adrp x0, PAGE(s_js_end)
    add x0, x0, LO12(s_js_end)
    mov x1, #TC_SET_END
    bl src_entry
.Ljes_show:
    // exclude
    adrp x19, PAGE(tc_plan_src_join)
    add x19, x19, LO12(tc_plan_src_join)
    ldr x20, [x19]
    cbz x20, .Ljes_excl_none
    adrp x0, PAGE(s_js_exclude)
    add x0, x0, LO12(s_js_exclude)
    mov x1, x20
    bl src_entry_ptr
    b .Ljes_header
.Ljes_excl_none:
    adrp x0, PAGE(s_js_exclude)
    add x0, x0, LO12(s_js_exclude)
    adrp x1, PAGE(s_jn_none)
    add x1, x1, LO12(s_jn_none)
    bl src_entry_ptr
.Ljes_header:
    adrp x0, PAGE(s_js_header)
    add x0, x0, LO12(s_js_header)
    mov x1, #TC_SET_HEADER
    bl src_entry
    adrp x0, PAGE(s_js_logs_dir)
    add x0, x0, LO12(s_js_logs_dir)
    mov x1, #TC_SET_LOGS_DIR
    bl src_entry
    adrp x0, PAGE(s_js_min_count)
    add x0, x0, LO12(s_js_min_count)
    mov x1, #TC_SET_MIN_COUNT
    bl src_entry
    adrp x0, PAGE(s_js_share_floor)
    add x0, x0, LO12(s_js_share_floor)
    mov x1, #TC_SET_SHARE_FLOOR
    bl src_entry
    // show (only when asked)
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_SRC + TC_SET_SHOW*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Ljes_sort
    adrp x0, PAGE(s_js_show)
    add x0, x0, LO12(s_js_show)
    mov x1, #TC_SET_SHOW
    bl src_entry
.Ljes_sort:
    // sort (only when asked, not the built-in default)
    ldr x20, [x19, #TC_O_SRC + TC_SET_SORT*8]
    cmp x20, #TC_SRC_DEFAULT_BUILTIN
    b.eq .Ljes_state
    adrp x0, PAGE(s_js_sort)
    add x0, x0, LO12(s_js_sort)
    mov x1, #TC_SET_SORT
    bl src_entry
.Ljes_state:
    ldr x20, [x19, #TC_O_SRC + TC_SET_STATE*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Ljes_state_nofilter
    adrp x0, PAGE(s_js_state)
    add x0, x0, LO12(s_js_state)
    mov x1, #TC_SET_STATE
    bl src_entry
    b .Ljes_top
.Ljes_state_nofilter:
    adrp x0, PAGE(s_js_state)
    add x0, x0, LO12(s_js_state)
    adrp x1, PAGE(s_j_not_filtered)
    add x1, x1, LO12(s_j_not_filtered)
    bl src_entry_ptr
.Ljes_top:
    // top (last, no comma)
    adrp x0, PAGE(s_js_top)
    add x0, x0, LO12(s_js_top)
    adrp x1, PAGE(tc_plan_limit_src)
    add x1, x1, LO12(tc_plan_limit_src)
    ldr x1, [x1]
    bl src_entry_last
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// emit_totals
// ============================================================================
    .p2align 2
emit_totals:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    // users_shown
    adrp x0, PAGE(s_j_t_shown)
    add x0, x0, LO12(s_j_t_shown)
    bl jputs
    adrp x19, PAGE(tc_plan_displayed_n)
    add x19, x19, LO12(tc_plan_displayed_n)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // users_above_threshold
    adrp x0, PAGE(s_j_t_above)
    add x0, x0, LO12(s_j_t_above)
    bl jputs
    adrp x19, PAGE(tc_plan_reported_n)
    add x19, x19, LO12(tc_plan_reported_n)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // users_in_range
    adrp x0, PAGE(s_j_t_inrange)
    add x0, x0, LO12(s_j_t_inrange)
    bl jputs
    adrp x19, PAGE(tc_plan_in_range)
    add x19, x19, LO12(tc_plan_in_range)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // users_excluded
    adrp x0, PAGE(s_j_t_excl)
    add x0, x0, LO12(s_j_t_excl)
    bl jputs
    adrp x19, PAGE(tc_plan_excl_appeared)
    add x19, x19, LO12(tc_plan_excl_appeared)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // messages_shown
    adrp x0, PAGE(s_j_t_mshown)
    add x0, x0, LO12(s_j_t_mshown)
    bl jputs
    adrp x19, PAGE(tc_plan_msgs_shown)
    add x19, x19, LO12(tc_plan_msgs_shown)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // messages_in_range
    adrp x0, PAGE(s_j_t_minrange)
    add x0, x0, LO12(s_j_t_minrange)
    bl jputs
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    ldr x0, [x19, #TC_T_MESSAGES]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // messages_hidden
    adrp x0, PAGE(s_j_t_mhidden)
    add x0, x0, LO12(s_j_t_mhidden)
    bl jputs
    adrp x19, PAGE(tc_plan_msgs_hidden)
    add x19, x19, LO12(tc_plan_msgs_hidden)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // messages_excluded
    adrp x0, PAGE(s_j_t_mexcl)
    add x0, x0, LO12(s_j_t_mexcl)
    bl jputs
    adrp x19, PAGE(tc_plan_excl_msgs)
    add x19, x19, LO12(tc_plan_excl_msgs)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // truncated
    adrp x0, PAGE(s_j_t_trunc)
    add x0, x0, LO12(s_j_t_trunc)
    bl jputs
    adrp x19, PAGE(tc_plan_hidden_n)
    add x19, x19, LO12(tc_plan_hidden_n)
    ldr x20, [x19]
    cbz x20, .Ljt_trunc_false
    adrp x0, PAGE(s_j_true)
    add x0, x0, LO12(s_j_true)
    bl jputs
    b .Ljt_trunc_done
.Ljt_trunc_false:
    adrp x0, PAGE(s_j_false)
    add x0, x0, LO12(s_j_false)
    bl jputs
.Ljt_trunc_done:
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // states
    adrp x0, PAGE(s_j_t_states)
    add x0, x0, LO12(s_j_t_states)
    bl jputs
    bl emit_totals_states
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // log_files
    adrp x0, PAGE(s_j_t_files)
    add x0, x0, LO12(s_j_t_files)
    bl jputs
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    ldr x0, [x19, #TC_T_FILES]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // users_below_share_floor
    adrp x0, PAGE(s_j_t_below)
    add x0, x0, LO12(s_j_t_below)
    bl jputs
    adrp x19, PAGE(tc_plan_below_floor)
    add x19, x19, LO12(tc_plan_below_floor)
    ldr x0, [x19]
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // cache
    adrp x0, PAGE(s_j_t_cache)
    add x0, x0, LO12(s_j_t_cache)
    bl jputs
    adrp x0, PAGE(s_j_cache_used)
    add x0, x0, LO12(s_j_cache_used)
    bl jputs
    adrp x19, PAGE(tc_plan_cache_used)
    add x19, x19, LO12(tc_plan_cache_used)
    ldr x20, [x19]
    cbz x20, .Ljt_used_false
    adrp x0, PAGE(s_j_true)
    add x0, x0, LO12(s_j_true)
    bl jputs
    b .Ljt_used_done
.Ljt_used_false:
    adrp x0, PAGE(s_j_false)
    add x0, x0, LO12(s_j_false)
    bl jputs
.Ljt_used_done:
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    adrp x0, PAGE(s_j_cache_days)
    add x0, x0, LO12(s_j_cache_days)
    bl jputs
    ldr x0, [x19, #8]                 // reused
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    adrp x0, PAGE(s_j_cache_prob)
    add x0, x0, LO12(s_j_cache_prob)
    bl jputs
    ldr x20, [x19, #24]               // problem
    cbz x20, .Ljt_prob_null
    mov x0, x20
    bl jquoted
    b .Ljt_prob_done
.Ljt_prob_null:
    adrp x0, PAGE(s_j_null)
    add x0, x0, LO12(s_j_null)
    bl jputs
.Ljt_prob_done:
    adrp x0, PAGE(s_j_nl)
    add x0, x0, LO12(s_j_nl)
    bl jputs
    adrp x0, PAGE(s_j_close4nl)
    add x0, x0, LO12(s_j_close4nl)
    bl jputs
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // unreadable
    adrp x0, PAGE(s_j_t_unreadable)
    add x0, x0, LO12(s_j_t_unreadable)
    bl jputs
    bl emit_unreadable
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_totals_states — the all-state split object (nonzero only)
    .p2align 2
emit_totals_states:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    ldr x20, [x19, #TC_T_STATES + 0]
    ldr x21, [x19, #TC_T_STATES + 8]
    ldr x22, [x19, #TC_T_STATES + 16]
    orr x23, x20, x21
    orr x23, x23, x22
    cbz x23, .Ljts_empty
    mov w0, #'{'
    bl jputc
    mov w0, #'\n'
    bl jputc
    mov x24, #0                        // state idx
.Ljts_loop:
    cmp x24, #3
    b.ge .Ljts_done
    add x25, x19, #TC_T_STATES
    ldr x25, [x25, x24, lsl #3]
    cbz x25, .Ljts_next
    adrp x0, PAGE(s_j_ind6)
    add x0, x0, LO12(s_j_ind6)
    mov x1, #6
    bl jputraw
    adrp x0, PAGE(state_names_json)
    add x0, x0, LO12(state_names_json)
    ldr x0, [x0, x24, lsl #3]
    bl jquoted
    adrp x0, PAGE(s_j_colon)
    add x0, x0, LO12(s_j_colon)
    bl jputs
    mov x0, x25
    bl jint
    add x9, x24, #1
    // is there a later nonzero state?
    mov x10, x9
.Ljts_find:
    cmp x10, #3
    b.ge .Ljts_nocomma
    add x11, x19, #TC_T_STATES
    ldr x11, [x11, x10, lsl #3]
    cbnz x11, .Ljts_comma
    add x10, x10, #1
    b .Ljts_find
.Ljts_comma:
    mov w0, #','
    bl jputc
    b .Ljts_nl
.Ljts_nocomma:
    b .Ljts_nl
.Ljts_nl:
    mov w0, #'\n'
    bl jputc
.Ljts_next:
    add x24, x24, #1
    b .Ljts_loop
.Ljts_done:
    adrp x0, PAGE(s_j_close4nl)
    add x0, x0, LO12(s_j_close4nl)
    bl jputs
    b .Ljts_out
.Ljts_empty:
    mov w0, #'{'
    bl jputc
    mov w0, #'}'
    bl jputc
.Ljts_out:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_unreadable — the array of {file, problem}
    .p2align 2
emit_unreadable:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    ldr x20, [x19, #TC_T_UNR_COUNT]
    cbz x20, .Ljun_empty
    mov w0, #'['
    bl jputc
    mov w0, #'\n'
    bl jputc
    add x21, x19, #TC_T_UNR_ENTRIES
    mov x22, #0
.Ljun_loop:
    cmp x22, x20
    b.ge .Ljun_done
    adrp x0, PAGE(s_j_ind8)
    add x0, x0, LO12(s_j_ind8)
    mov x1, #8
    bl jputraw
    adrp x0, PAGE(s_j_row_open)
    add x0, x0, LO12(s_j_row_open)
    mov x1, #2
    bl jputraw
    adrp x0, PAGE(s_j_ind10)
    add x0, x0, LO12(s_j_ind10)
    mov x1, #10
    bl jputraw
    adrp x0, PAGE(s_j_file)
    add x0, x0, LO12(s_j_file)
    bl jputs
    mov x2, #TC_T_UNR_ENTRY_SZ
    mul x2, x22, x2
    add x0, x21, x2
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    adrp x0, PAGE(s_j_ind10)
    add x0, x0, LO12(s_j_ind10)
    mov x1, #10
    bl jputraw
    adrp x0, PAGE(s_j_problem)
    add x0, x0, LO12(s_j_problem)
    bl jputs
    mov x2, #TC_T_UNR_ENTRY_SZ
    mul x2, x22, x2
    add x0, x21, x2
    add x0, x0, #TC_T_UNR_NAME_SZ
    bl jquoted
    mov w0, #'\n'
    bl jputc
    adrp x0, PAGE(s_j_close8)
    add x0, x0, LO12(s_j_close8)
    bl jputs
    add x9, x22, #1
    cmp x9, x20
    b.ge .Ljun_nl
    mov w0, #','
    bl jputc
.Ljun_nl:
    mov w0, #'\n'
    bl jputc
    add x22, x22, #1
    b .Ljun_loop
.Ljun_done:
    adrp x0, PAGE(s_j_close6nl)
    add x0, x0, LO12(s_j_close6nl)
    bl jputs
    b .Ljun_out
.Ljun_empty:
    mov w0, #'['
    bl jputc
    mov w0, #']'
    bl jputc
.Ljun_out:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// emit_rows — the displayed rows.
// ============================================================================
    .p2align 2
emit_rows:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, PAGE(tc_plan_displayed_n)
    add x19, x19, LO12(tc_plan_displayed_n)
    ldr x20, [x19]                    // n
    cbz x20, .Ljer_empty
    mov w0, #'['
    bl jputc
    mov w0, #'\n'
    bl jputc
    adrp x21, PAGE(tc_plan_reported)
    add x21, x21, LO12(tc_plan_reported)
    ldr x21, [x21]
    mov x22, #0                        // i
.Ljer_loop:
    cmp x22, x20
    b.ge .Ljer_done
    mov x0, #72                        // ROW_SZ
    mul x0, x22, x0
    add x23, x21, x0                   // rec
    adrp x0, PAGE(s_j_ind4)
    add x0, x0, LO12(s_j_ind4)
    mov x1, #4
    bl jputraw
    adrp x0, PAGE(s_j_row_open)
    add x0, x0, LO12(s_j_row_open)
    mov x1, #2
    bl jputraw
    // login
    adrp x0, PAGE(s_j_login)
    add x0, x0, LO12(s_j_login)
    bl jputs
    add x0, x23, #0                    // login ptr
    bl jquoted
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // count
    adrp x0, PAGE(s_j_count)
    add x0, x0, LO12(s_j_count)
    bl jputs
    ldr x0, [x23, #32]                 // ROW_COUNT
    bl jint
    adrp x0, PAGE(s_j_comma_nl)
    add x0, x0, LO12(s_j_comma_nl)
    bl jputs
    // states
    adrp x0, PAGE(s_j_states_k)
    add x0, x0, LO12(s_j_states_k)
    bl jputs
    bl emit_row_states            // ends with the states close "      }"
    mov w0, #'\n'
    bl jputc
    adrp x0, PAGE(s_j_close4nl)
    add x0, x0, LO12(s_j_close4nl)
    bl jputs                      // "    }"
    add x9, x22, #1
    cmp x9, x20
    b.ge .Ljer_nl
    mov w0, #','
    bl jputc
.Ljer_nl:
    mov w0, #'\n'
    bl jputc
    add x22, x22, #1
    b .Ljer_loop
.Ljer_done:
    adrp x0, PAGE(s_j_rows_close)
    add x0, x0, LO12(s_j_rows_close)
    bl jputs
    b .Ljer_out
.Ljer_empty:
    mov w0, #'['
    bl jputc
    mov w0, #']'
    bl jputc
.Ljer_out:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// emit_row_states — the per-user states object (filtered, nonzero, name order)
//   expects x23 = rec, x20 = displayed_n (unused here)
    .p2align 2
emit_row_states:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x23                       // rec
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x21, [x20, #TC_W_STATE_FILTER]
    // gather the three (state, count) pairs
    ldr x22, [x19, #40]                // ROW_LIVE
    ldr x23, [x19, #48]                // ROW_OFFLINE
    ldr x24, [x19, #56]                // ROW_UNKNOWN
    // filter: keep only the matching state
    cmp x21, #TC_ST_NONE
    b.eq .Ljrs_write
    cmp x21, #TC_ST_LIVE
    b.eq .Ljrs_live_only
    cmp x21, #TC_ST_OFFLINE
    b.eq .Ljrs_off_only
    mov x22, #0
    mov x23, #0
    b .Ljrs_write
.Ljrs_live_only:
    mov x23, #0
    mov x24, #0
    b .Ljrs_write
.Ljrs_off_only:
    mov x22, #0
    mov x24, #0
    b .Ljrs_write
.Ljrs_write:
    orr x25, x22, x23
    orr x25, x25, x24
    cbz x25, .Ljrs_empty
    mov w0, #'{'
    bl jputc
    mov w0, #'\n'
    bl jputc
    mov x26, #0                        // idx (0=live,1=offline,2=unknown)
.Ljrs_loop:
    cmp x26, #3
    b.ge .Ljrs_done
    cmp x26, #0
    b.eq .Ljrs_live_v
    cmp x26, #1
    b.eq .Ljrs_off_v
    mov x27, x24
    b .Ljrs_emit
.Ljrs_live_v:
    mov x27, x22
    b .Ljrs_emit
.Ljrs_off_v:
    mov x27, x23
.Ljrs_emit:
    cbz x27, .Ljrs_next
    adrp x0, PAGE(s_j_ind8)
    add x0, x0, LO12(s_j_ind8)
    mov x1, #8
    bl jputraw
    adrp x0, PAGE(state_names_json)
    add x0, x0, LO12(state_names_json)
    ldr x0, [x0, x26, lsl #3]
    bl jquoted
    adrp x0, PAGE(s_j_colon)
    add x0, x0, LO12(s_j_colon)
    bl jputs
    mov x0, x27
    bl jint
    // comma if a later state is nonzero
    mov x10, x26
    add x10, x10, #1
.Ljrs_find:
    cmp x10, #3
    b.ge .Ljrs_nocomma
    cmp x10, #0
    b.eq .Ljrs_f_live
    cmp x10, #1
    b.eq .Ljrs_f_off
    mov x11, x24
    b .Ljrs_f_check
.Ljrs_f_live:
    mov x11, x22
    b .Ljrs_f_check
.Ljrs_f_off:
    mov x11, x23
.Ljrs_f_check:
    cbnz x11, .Ljrs_comma
    add x10, x10, #1
    b .Ljrs_find
.Ljrs_comma:
    mov w0, #','
    bl jputc
.Ljrs_nocomma:
    mov w0, #'\n'
    bl jputc
.Ljrs_next:
    add x26, x26, #1
    b .Ljrs_loop
.Ljrs_done:
    adrp x0, PAGE(s_j_close6nl)
    add x0, x0, LO12(s_j_close6nl)
    bl jputs
    b .Ljrs_out
.Ljrs_empty:
    mov w0, #'{'
    bl jputc
    mov w0, #'}'
    bl jputc
.Ljrs_out:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// tc_json_err — the --json failure shape: {"error": <msg>} to stderr, exit 1.
// ============================================================================
    .p2align 2
    .global tc_json_err
    .global tc_eputc
    FUNC_TYPE(tc_json_err)
tc_json_err:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x0, #STDERR
    bl jinit
    adrp x0, PAGE(s_j_err_open)
    add x0, x0, LO12(s_j_err_open)
    bl jputs
    mov x0, x19
    bl jquoted
    adrp x0, PAGE(s_j_err_close)
    add x0, x0, LO12(s_j_err_close)
    bl jputs
    bl jflush
    mov w0, #1
    bl exit

// ============================================================================
// .rodata tail — the sources keys and the unreadable row keys
// ============================================================================
    RODATA
s_js_begin:         .asciz "begin"
s_js_channel:       .asciz "channel"
s_js_end:           .asciz "end"
s_js_exclude:       .asciz "exclude"
s_js_header:        .asciz "header"
s_js_logs_dir:      .asciz "logs_dir"
s_js_min_count:     .asciz "min_count"
s_js_share_floor:   .asciz "share_floor"
s_js_show:          .asciz "show"
s_js_sort:          .asciz "sort"
s_js_state:         .asciz "state"
s_js_top:           .asciz "top"
s_j_ind10:          .ascii "          "
s_j_file:           .ascii "\"file\": "
s_j_problem:        .ascii "\"problem\": "

    .end
