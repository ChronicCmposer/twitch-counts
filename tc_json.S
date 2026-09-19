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
    .globl tc_fmt2
    .globl tc_fmt4
    .globl tc_setting_src_str

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ JBUF_SZ,         16384
    .equ JISO_SZ,         64

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

    .p2align 3
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
    PROLOGUE 1
    mov x19, x0
    LEA x0, tc_json_fd
    str x19, [x0]
    LEA x0, tc_json_cur
    str xzr, [x0]
    EPILOGUE 1
    ret

// jflush() — write the buffered bytes
    .p2align 2
jflush:
    PROLOGUE 1
    LEA x0, tc_json_cur
    ldr x19, [x0]
    cbz x19, .Ljfl_done
    str xzr, [x0]
    LEA x0, tc_json_fd
    ldr x0, [x0]
    LEA x1, tc_json_buf
    mov x2, x19
    bl write
.Ljfl_done:
    EPILOGUE 1
    ret

// jputc(c) — append one byte, flushing when full
    .p2align 2
jputc:
    PROLOGUE 1
    mov w19, w0
    LEA x0, tc_json_cur
    ldr x20, [x0]
    cmp x20, #JBUF_SZ
    b.lt .Ljpc_ok
    bl jflush
    mov x20, #0
.Ljpc_ok:
    LEA x1, tc_json_buf
    strb w19, [x1, x20]
    add x20, x20, #1
    LEA x1, tc_json_cur
    str x20, [x1]
    EPILOGUE 1
    ret

// jputraw(s, len) — append len raw bytes
    .p2align 2
jputraw:
    PROLOGUE 2
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
    EPILOGUE 2
    ret

// jputs(s) — append a NUL-terminated string (length via tc_strlen)
    .p2align 2
jputs:
    PROLOGUE 1
    mov x19, x0
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl jputraw
    EPILOGUE 1
    ret

// jquoted(s) — append the JSON-escaped, quoted form of a NUL-terminated string
    .p2align 2
jquoted:
    PROLOGUE 2
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
    EPILOGUE 2
    ret

// jhex(nibble) — append a lowercase hex digit
    .p2align 2
jhex:
    PROLOGUE 0
    cmp w0, #10
    b.lt .Ljh_digit
    sub w0, w0, #10
    add w0, w0, #'a'
    b .Ljh_go
.Ljh_digit:
    add w0, w0, #'0'
.Ljh_go:
    bl jputc
    EPILOGUE 0
    ret

// jint(v) — append a decimal integer (no commas)
    .p2align 2
jint:
    PROLOGUE 2
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
    EPILOGUE 2
    ret

// jbool(v) — "true"/"false"
    .p2align 2
jbool:
    PROLOGUE 0
    cbz x0, .Ljbo_false
    LEA x0, s_j_true
    bl jputs
    b .Ljbo_done
.Ljbo_false:
    LEA x0, s_j_false
    bl jputs
.Ljbo_done:
    EPILOGUE 0
    ret

// json_now_iso(buf) — "YYYY-MM-DDTHH:MM:SS" local time (generated_at)
    .p2align 2
json_now_iso:
    PROLOGUE 3
    mov x19, x0
    mov x0, #CLOCK_REALTIME
    LEA x1, tc_json_ts
    bl clock_gettime
    LEA x0, tc_json_ts
    LEA x1, tc_json_tm
    bl localtime_r
    LEA x0, tc_json_tm
    ldr w20, [x0, #TM_YEAR]
    add x20, x20, #1900
    ldr w21, [x0, #TM_MON]
    add x21, x21, #1
    ldr w22, [x0, #TM_MDAY]
    mov x1, #10000
    mul x20, x20, x1
    mov x1, #100
    mul x21, x21, x1
    add x20, x20, x21
    add x20, x20, x22                  // ymd
    ldr w21, [x0, #TM_HOUR]
    ldr w22, [x0, #TM_MIN]
    ldr w23, [x0, #TM_SEC]
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
    EPILOGUE 3
    ret

// ============================================================================
// Local date formatting on top of tc_fmt2/tc_fmt4 (tc_util.S); digits only,
// no NUL.
// ============================================================================

// json_fmt_dt(dst, ymd, sod, sep) -> dst+19, "YYYY-MM-DD<sep>HH:MM:SS"
    .p2align 2
json_fmt_dt:
    PROLOGUE 2
    mov x19, x0
    mov x20, x1                        // ymd
    mov x21, x2                        // sod
    mov w22, w3                        // separator
    mov x1, x20
    mov x2, #10000
    udiv x6, x20, x2
    mov x0, x19
    mov x1, x6
    bl tc_fmt4
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #100
    udiv x6, x20, x2
    mov x8, #100
    udiv x9, x6, x8
    msub x9, x9, x8, x6
    mov w1, w9
    bl tc_fmt2
    mov w7, #'-'
    strb w7, [x0], #1
    mov x2, #100
    udiv x6, x20, x2
    msub x6, x6, x2, x20
    mov w1, w6
    bl tc_fmt2
    strb w22, [x0], #1
    mov x1, x21
    mov x2, #3600
    udiv x6, x21, x2
    mov w1, w6
    bl tc_fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #3600
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    mov w1, w6
    bl tc_fmt2
    mov w7, #':'
    strb w7, [x0], #1
    mov x2, #3600
    udiv x8, x21, x2
    msub x9, x8, x2, x21
    mov x2, #60
    udiv x6, x9, x2
    msub x6, x6, x2, x9
    mov w1, w6
    bl tc_fmt2
    EPILOGUE 2
    ret

// ============================================================================
// tc_json_emit — the full report document.
// ============================================================================
    .p2align 2
    .global tc_json_emit
    FUNC_TYPE(tc_json_emit)
tc_json_emit:
    PROLOGUE 5
    mov x0, #STDOUT
    bl jinit
    // { + schema blob
    LEA x0, s_j_open
    mov x1, #2
    bl jputraw
    LEA x0, tc_json_schema_blob
    mov x1, #tc_json_schema_blob_len
    bl jputraw
    // schema_version + generated_at
    LEA x0, s_j_schema_version
    bl jputs
    LEA x0, s_j_generated_at
    bl jputs
    LEA x0, tc_json_iso
    bl json_now_iso
    LEA x0, tc_json_iso
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    // query
    LEA x0, s_j_query
    bl jputs
    // channel
    LEA x0, s_j_qchannel
    bl jputs
    bl tc_channel_name
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    // begin
    LEA x0, s_j_qbegin
    bl jputs
    LEA x19, tc_window
    LEA x20, tc_json_iso
    mov x0, x20
    ldr x1, [x19, #TC_W_BEGIN_YMD]
    ldr x2, [x19, #TC_W_BEGIN_SOD]
    mov w3, #'T'
    bl json_fmt_dt
    mov w1, #0
    strb w1, [x0]
    mov x0, x20
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    // end
    LEA x0, s_j_qend
    bl jputs
    LEA x20, tc_json_iso
    mov x0, x20
    ldr x1, [x19, #TC_W_END_YMD]
    ldr x2, [x19, #TC_W_END_SOD]
    mov w3, #'T'
    bl json_fmt_dt
    mov w1, #0
    strb w1, [x0]
    mov x0, x20
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    // min_count
    LEA x0, s_j_qmin
    bl jputs
    ldr x0, [x19, #TC_W_THRESHOLD]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // top
    LEA x0, s_j_qtop
    bl jputs
    LEA x19, tc_plan_limit
    ldr x20, [x19]
    cbz x20, .Lje_top_null
    mov x0, x20
    bl jint
    b .Lje_top_done
.Lje_top_null:
    LEA x0, s_j_null
    bl jputs
.Lje_top_done:
    LEA x0, s_j_comma_nl
    bl jputs
    // state
    LEA x0, s_j_qstate
    bl jputs
    LEA x19, tc_window
    ldr x20, [x19, #TC_W_STATE_FILTER]
    cbz x20, .Lje_state_null
    LEA x0, state_names_json
    sub x1, x20, #1
    ldr x0, [x0, x1, lsl #3]
    bl jquoted
    b .Lje_state_done
.Lje_state_null:
    LEA x0, s_j_null
    bl jputs
.Lje_state_done:
    LEA x0, s_j_comma_nl
    bl jputs
    // excluded
    LEA x0, s_j_qexcluded
    bl jputs
    bl emit_excluded_array
    LEA x0, s_j_comma_nl
    bl jputs
    // sort
    LEA x0, s_j_qsort
    bl jputs
    LEA x19, tc_plan_sort
    ldr x20, [x19]
    LEA x0, metric_names_json
    ldr x0, [x0, x20, lsl #3]
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    // share_floor
    LEA x0, s_j_qsf
    bl jputs
    LEA x0, s_j_sf_req
    bl jputs
    LEA x19, tc_opts
    ldr x0, [x19, #TC_O_SHARE_FLOOR]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    LEA x0, s_j_sf_app
    bl jputs
    LEA x19, tc_plan_share_floor
    ldr x20, [x19]
    cbz x20, .Lje_sf_false
    LEA x0, s_j_true
    bl jputs
    b .Lje_sf_done
.Lje_sf_false:
    LEA x0, s_j_false
    bl jputs
.Lje_sf_done:
    LEA x0, s_j_close4
    bl jputs
    LEA x0, s_j_comma_nl
    bl jputs
    // sources
    LEA x0, s_j_qsources
    bl jputs
    bl emit_sources
    LEA x0, s_j_close4nl
    bl jputs
    LEA x0, s_j_nl
    bl jputs
    // close query, open totals
    LEA x0, s_j_query_close
    bl jputs
    LEA x0, s_j_totals
    bl jputs
    bl emit_totals
    LEA x0, s_j_close2
    bl jputs
    LEA x0, s_j_comma_nl
    bl jputs
    // rows
    LEA x0, s_j_rows
    bl jputs
    bl emit_rows
    LEA x0, s_j_end
    bl jputs
    bl jflush
    mov x0, #0
    EPILOGUE 5
    ret

// ============================================================================
// emit_excluded_array — the sorted exclusion logins.
// ============================================================================
    .p2align 2
emit_excluded_array:
    PROLOGUE 2
    LEA x19, tc_plan_excl_names_n
    ldr x20, [x19]                    // n
    cbz x20, .Ljea_empty
    mov w0, #'['
    bl jputc
    mov w0, #'\n'
    bl jputc
    LEA x21, tc_plan_excl_names
    ldr x21, [x21]
    mov x22, #0
.Ljea_loop:
    cmp x22, x20
    b.ge .Ljea_done
    LEA x0, s_j_ind6
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
    LEA x0, s_j_ind4
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
    EPILOGUE 2
    ret

// src_entry(key, set_id) — emit `      "key": <source of set_id>,\n`
    .p2align 2
src_entry:
    PROLOGUE 1
    mov x19, x0                        // key
    mov x20, x1                        // set id
    LEA x0, s_j_ind6
    mov x1, #6
    bl jputraw
    mov x0, x19
    bl jquoted
    LEA x0, s_j_colon
    bl jputs
    mov x0, x20
    bl tc_setting_src_str
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    EPILOGUE 1
    ret

// src_entry_ptr(key, value_ptr) — `      "key": "<value>",\n` (value is a
// direct pointer, not a set id; same shape as src_entry)
    .p2align 2
src_entry_ptr:
    PROLOGUE 1
    mov x19, x0                        // key
    mov x20, x1                        // value ptr
    LEA x0, s_j_ind6
    mov x1, #6
    bl jputraw
    mov x0, x19
    bl jquoted
    LEA x0, s_j_colon
    bl jputs
    mov x0, x20
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    EPILOGUE 1
    ret

// src_entry_last(key, value_ptr) — `      "key": "<value>",\n` (last, no comma)
    .p2align 2
src_entry_last:
    PROLOGUE 1
    mov x19, x0                        // key
    mov x20, x1                        // value ptr
    LEA x0, s_j_ind6
    mov x1, #6
    bl jputraw
    mov x0, x19
    bl jquoted
    LEA x0, s_j_colon
    bl jputs
    mov x0, x20
    bl jquoted
    mov w0, #'\n'
    bl jputc
    EPILOGUE 1
    ret

// ============================================================================
// emit_sources — the sorted provenance map.
// ============================================================================
    .p2align 2
emit_sources:
    PROLOGUE 1
    // begin (value is a direct pointer, not a set id)
    LEA x0, s_js_begin
    LEA x1, tc_window
    ldr x1, [x1, #TC_W_START_SRC]
    bl src_entry_ptr
    // channel
    LEA x0, s_js_channel
    mov x1, #TC_SET_CHANNEL
    bl src_entry
    // end (only when not defaulted)
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_SRC + TC_SET_END*8]
    cmp x20, #TC_SRC_DEFAULT_NOW
    b.eq .Ljes_show
    LEA x0, s_js_end
    mov x1, #TC_SET_END
    bl src_entry
.Ljes_show:
    // exclude
    LEA x19, tc_plan_src_join
    ldr x20, [x19]
    cbz x20, .Ljes_excl_none
    LEA x0, s_js_exclude
    mov x1, x20
    bl src_entry_ptr
    b .Ljes_header
.Ljes_excl_none:
    LEA x0, s_js_exclude
    LEA x1, s_jn_none
    bl src_entry_ptr
.Ljes_header:
    LEA x0, s_js_header
    mov x1, #TC_SET_HEADER
    bl src_entry
    LEA x0, s_js_logs_dir
    mov x1, #TC_SET_LOGS_DIR
    bl src_entry
    LEA x0, s_js_min_count
    mov x1, #TC_SET_MIN_COUNT
    bl src_entry
    LEA x0, s_js_share_floor
    mov x1, #TC_SET_SHARE_FLOOR
    bl src_entry
    // show (only when asked)
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_SRC + TC_SET_SHOW*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Ljes_sort
    LEA x0, s_js_show
    mov x1, #TC_SET_SHOW
    bl src_entry
.Ljes_sort:
    // sort (only when asked, not the built-in default)
    ldr x20, [x19, #TC_O_SRC + TC_SET_SORT*8]
    cmp x20, #TC_SRC_DEFAULT_BUILTIN
    b.eq .Ljes_state
    LEA x0, s_js_sort
    mov x1, #TC_SET_SORT
    bl src_entry
.Ljes_state:
    ldr x20, [x19, #TC_O_SRC + TC_SET_STATE*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Ljes_state_nofilter
    LEA x0, s_js_state
    mov x1, #TC_SET_STATE
    bl src_entry
    b .Ljes_top
.Ljes_state_nofilter:
    LEA x0, s_js_state
    LEA x1, s_j_not_filtered
    bl src_entry_ptr
.Ljes_top:
    // top (last, no comma)
    LEA x0, s_js_top
    LEA x1, tc_plan_limit_src
    ldr x1, [x1]
    bl src_entry_last
    EPILOGUE 1
    ret

// ============================================================================
// emit_totals
// ============================================================================
    .p2align 2
emit_totals:
    PROLOGUE 3
    // users_shown
    LEA x0, s_j_t_shown
    bl jputs
    LEA x19, tc_plan_displayed_n
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // users_above_threshold
    LEA x0, s_j_t_above
    bl jputs
    LEA x19, tc_plan_reported_n
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // users_in_range
    LEA x0, s_j_t_inrange
    bl jputs
    LEA x19, tc_plan_in_range
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // users_excluded
    LEA x0, s_j_t_excl
    bl jputs
    LEA x19, tc_plan_excl_appeared
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // messages_shown
    LEA x0, s_j_t_mshown
    bl jputs
    LEA x19, tc_plan_msgs_shown
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // messages_in_range
    LEA x0, s_j_t_minrange
    bl jputs
    LEA x19, tc_tally
    ldr x0, [x19, #TC_T_MESSAGES]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // messages_hidden
    LEA x0, s_j_t_mhidden
    bl jputs
    LEA x19, tc_plan_msgs_hidden
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // messages_excluded
    LEA x0, s_j_t_mexcl
    bl jputs
    LEA x19, tc_plan_excl_msgs
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // truncated
    LEA x0, s_j_t_trunc
    bl jputs
    LEA x19, tc_plan_hidden_n
    ldr x20, [x19]
    cbz x20, .Ljt_trunc_false
    LEA x0, s_j_true
    bl jputs
    b .Ljt_trunc_done
.Ljt_trunc_false:
    LEA x0, s_j_false
    bl jputs
.Ljt_trunc_done:
    LEA x0, s_j_comma_nl
    bl jputs
    // states
    LEA x0, s_j_t_states
    bl jputs
    bl emit_totals_states
    LEA x0, s_j_comma_nl
    bl jputs
    // log_files
    LEA x0, s_j_t_files
    bl jputs
    LEA x19, tc_tally
    ldr x0, [x19, #TC_T_FILES]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // users_below_share_floor
    LEA x0, s_j_t_below
    bl jputs
    LEA x19, tc_plan_below_floor
    ldr x0, [x19]
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // cache
    LEA x0, s_j_t_cache
    bl jputs
    LEA x0, s_j_cache_used
    bl jputs
    LEA x19, tc_plan_cache_used
    ldr x20, [x19]
    cbz x20, .Ljt_used_false
    LEA x0, s_j_true
    bl jputs
    b .Ljt_used_done
.Ljt_used_false:
    LEA x0, s_j_false
    bl jputs
.Ljt_used_done:
    LEA x0, s_j_comma_nl
    bl jputs
    LEA x0, s_j_cache_days
    bl jputs
    ldr x0, [x19, #8]                 // reused
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    LEA x0, s_j_cache_prob
    bl jputs
    ldr x20, [x19, #24]               // problem
    cbz x20, .Ljt_prob_null
    mov x0, x20
    bl jquoted
    b .Ljt_prob_done
.Ljt_prob_null:
    LEA x0, s_j_null
    bl jputs
.Ljt_prob_done:
    LEA x0, s_j_nl
    bl jputs
    LEA x0, s_j_close4nl
    bl jputs
    LEA x0, s_j_comma_nl
    bl jputs
    // unreadable
    LEA x0, s_j_t_unreadable
    bl jputs
    bl emit_unreadable
    EPILOGUE 3
    ret

// emit_totals_states — the all-state split object (nonzero only)
    .p2align 2
emit_totals_states:
    PROLOGUE 4
    LEA x19, tc_tally
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
    LEA x0, s_j_ind6
    mov x1, #6
    bl jputraw
    LEA x0, state_names_json
    ldr x0, [x0, x24, lsl #3]
    bl jquoted
    LEA x0, s_j_colon
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
    LEA x0, s_j_close4nl
    bl jputs
    b .Ljts_out
.Ljts_empty:
    mov w0, #'{'
    bl jputc
    mov w0, #'}'
    bl jputc
.Ljts_out:
    EPILOGUE 4
    ret

// emit_unreadable — the array of {file, problem}
    .p2align 2
emit_unreadable:
    PROLOGUE 2
    LEA x19, tc_tally
    ldr x20, [x19, #TC_T_UNR_COUNT]
    cbz x20, .Ljun_empty
    mov w0, #'['
    bl jputc
    mov w0, #'\n'
    bl jputc
    add x21, x19, #TC_T_UNR_ENTRIES
    mov x22, #0
    // json.dumps(indent=2) of [{"file": ..., "problem": ...}, ...] under a
    // key at indent 4: rows open at 6, their keys sit at 8, "]" at 4.  (The
    // rows were two levels too deep, and s_j_file/s_j_problem lacked their
    // NUL, so "file" ran on into "problem": invalid JSON.)
.Ljun_loop:
    cmp x22, x20
    b.ge .Ljun_done
    LEA x0, s_j_ind6
    mov x1, #6
    bl jputraw
    LEA x0, s_j_row_open
    mov x1, #2
    bl jputraw
    LEA x0, s_j_ind8
    mov x1, #8
    bl jputraw
    LEA x0, s_j_file
    bl jputs
    mov x2, #TC_T_UNR_ENTRY_SZ
    mul x2, x22, x2
    add x0, x21, x2
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    LEA x0, s_j_ind8
    mov x1, #8
    bl jputraw
    LEA x0, s_j_problem
    bl jputs
    mov x2, #TC_T_UNR_ENTRY_SZ
    mul x2, x22, x2
    add x0, x21, x2
    add x0, x0, #TC_T_UNR_NAME_SZ
    bl jquoted
    mov w0, #'\n'
    bl jputc
    LEA x0, s_j_close6nl
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
    LEA x0, s_j_ind4
    bl jputs
    mov w0, #']'
    bl jputc
    b .Ljun_out
.Ljun_empty:
    mov w0, #'['
    bl jputc
    mov w0, #']'
    bl jputc
.Ljun_out:
    EPILOGUE 2
    ret

// ============================================================================
// emit_rows — the displayed rows.
// ============================================================================
    .p2align 2
emit_rows:
    PROLOGUE 3
    LEA x19, tc_plan_displayed_n
    ldr x20, [x19]                    // n
    cbz x20, .Ljer_empty
    mov w0, #'['
    bl jputc
    mov w0, #'\n'
    bl jputc
    LEA x21, tc_plan_reported
    ldr x21, [x21]
    mov x22, #0                        // i
.Ljer_loop:
    cmp x22, x20
    b.ge .Ljer_done
    mov x0, #72                        // ROW_SZ
    mul x0, x22, x0
    add x23, x21, x0                   // rec
    LEA x0, s_j_ind4
    mov x1, #4
    bl jputraw
    LEA x0, s_j_row_open
    mov x1, #2
    bl jputraw
    // login
    LEA x0, s_j_login
    bl jputs
    add x0, x23, #0                    // login ptr
    bl jquoted
    LEA x0, s_j_comma_nl
    bl jputs
    // count
    LEA x0, s_j_count
    bl jputs
    ldr x0, [x23, #32]                 // ROW_COUNT
    bl jint
    LEA x0, s_j_comma_nl
    bl jputs
    // states
    LEA x0, s_j_states_k
    bl jputs
    bl emit_row_states            // ends with the states close "      }"
    mov w0, #'\n'
    bl jputc
    LEA x0, s_j_close4nl
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
    LEA x0, s_j_rows_close
    bl jputs
    b .Ljer_out
.Ljer_empty:
    mov w0, #'['
    bl jputc
    mov w0, #']'
    bl jputc
.Ljer_out:
    EPILOGUE 3
    ret

// emit_row_states — the per-user states object (filtered, nonzero, name order)
//   expects x23 = rec, x20 = displayed_n (unused here)
    .p2align 2
emit_row_states:
    PROLOGUE 5
    mov x19, x23                       // rec
    LEA x20, tc_window
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
    LEA x0, s_j_ind8
    mov x1, #8
    bl jputraw
    LEA x0, state_names_json
    ldr x0, [x0, x26, lsl #3]
    bl jquoted
    LEA x0, s_j_colon
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
    LEA x0, s_j_close6nl
    bl jputs
    b .Ljrs_out
.Ljrs_empty:
    mov w0, #'{'
    bl jputc
    mov w0, #'}'
    bl jputc
.Ljrs_out:
    EPILOGUE 5
    ret

// ============================================================================
// tc_json_err — the --json failure shape: {"error": <msg>} to stderr, exit 1.
// ============================================================================
    .p2align 2
    .global tc_json_err
    .global tc_eputc
    FUNC_TYPE(tc_json_err)
tc_json_err:
    PROLOGUE 1
    mov x19, x0
    mov x0, #STDERR
    bl jinit
    LEA x0, s_j_err_open
    bl jputs
    mov x0, x19
    bl jquoted
    LEA x0, s_j_err_close
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
s_j_file:           .asciz "\"file\": "
s_j_problem:        .asciz "\"problem\": "

    .end
