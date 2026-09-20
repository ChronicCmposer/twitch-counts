// ============================================================================
// tc_json.S — the self-describing JSON report for twitch-counts
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//  Linking:    by the Makefile (build/<os>/twitch-counts and the drivers)
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
    .globl tc_fmt_u64
    .globl tc_fmt_ymd_sod
    .globl tc_copy_bytes
    .globl tc_entry_ptr
    .globl tc_state_names
    .globl tc_metric_names
    .globl tc_setting_src_str

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ JBUF_SZ,         16384
    .equ JISO_SZ,         64

// Record layouts this module reads (shared in tc_layout.inc): the reported
// rows ROW_* / ROW_SZ, the login stride LOGIN_SZ, and the plan struct
// TC_PLAN_* (the cache block uses TC_PLAN_CACHE_USED/REUSED/PROBLEM).

// ----------------------------------------------------------------------------
// .bss
// ----------------------------------------------------------------------------
    .bss
    .p2align 4
json_buf:        .skip JBUF_SZ
json_cur:        .skip 8
json_fd:         .skip 8
json_iso:        .skip JISO_SZ
json_tm:         .skip 64
json_ts:         .skip 16

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
s_j_end: .asciz "\n}\n"

    .p2align 3
s_jn_none:          .asciz "none"
s_j_not_filtered:   .asciz "not filtered"

    .text

// json_jinit(fd) — reset the JSON buffer
    .p2align 2
json_jinit:
    PROLOGUE 1
    mov x19, x0
    LEA x0, json_fd
    str x19, [x0]
    LEA x0, json_cur
    str xzr, [x0]
    EPILOGUE 1
    ret

// json_jflush() — write the buffered bytes
    .p2align 2
json_jflush:
    PROLOGUE 1
    LEA x0, json_cur
    ldr x19, [x0]
    cbz x19, .Ljfl_done
    str xzr, [x0]
    LEA x0, json_fd
    ldr x0, [x0]
    LEA x1, json_buf
    mov x2, x19
    bl write
.Ljfl_done:
    EPILOGUE 1
    ret

// json_jputc(c) — append one byte, flushing when full
    .p2align 2
json_jputc:
    PROLOGUE 1
    mov w19, w0
    LEA x0, json_cur
    ldr x20, [x0]
    cmp x20, #JBUF_SZ
    b.lt .Ljpc_ok
    bl json_jflush
    mov x20, #0
.Ljpc_ok:
    LEA x1, json_buf
    strb w19, [x1, x20]
    add x20, x20, #1
    LEA x1, json_cur
    str x20, [x1]
    EPILOGUE 1
    ret

// json_jputraw(s, len) — append len raw bytes
//   One bounds check, then a bulk ldp/stp copy (tc_copy_bytes) straight into
//   json_buf.  When the chunk does not fit, the current buffer is flushed and
//   the copy is retried (chunked for len > JBUF_SZ).  This replaces the old
//   per-byte json_jputc calls (~11K of them for the schema blob alone).
    .p2align 2
json_jputraw:
    PROLOGUE 2
    mov x19, x0                        // src
    mov x20, x1                        // len
.Ljpr_again:
    LEA x21, json_cur
    ldr x22, [x21]                     // cur
    mov x9, #JBUF_SZ
    sub x9, x9, x22                    // space left
    cmp x20, x9
    b.le .Ljpr_all                     // fits entirely
    cbnz x9, .Ljpr_part
    bl json_jflush                     // buffer exactly full: flush and retry
    b .Ljpr_again
.Ljpr_part:
    LEA x10, json_buf
    add x10, x10, x22
    mov x0, x10
    mov x1, x19
    mov x2, x9                         // copy the space bytes
    bl tc_copy_bytes
    add x19, x19, x9                   // src += space
    mov x22, #JBUF_SZ
    str x22, [x21]                     // buffer is now full
    sub x20, x20, x9                   // len -= space
    bl json_jflush
    b .Ljpr_again
.Ljpr_all:
    LEA x10, json_buf
    add x10, x10, x22
    mov x0, x10
    mov x1, x19
    mov x2, x20
    bl tc_copy_bytes
    add x22, x22, x20
    str x22, [x21]                     // cur += len
    EPILOGUE 2
    ret

// json_jputs(s) — append a NUL-terminated string (length via tc_strlen)
    .p2align 2
json_jputs:
    PROLOGUE 1
    mov x19, x0
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl json_jputraw
    EPILOGUE 1
    ret

// json_jquoted(s) — append the JSON-escaped, quoted form of a NUL-terminated string
    .p2align 2
json_jquoted:
    PROLOGUE 2
    mov x19, x0
    mov w0, #'"'
    bl json_jputc
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
    bl json_jputc
    b .Ljq_next
.Ljq_esc_quote:
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'"'
    bl json_jputc
    b .Ljq_next
.Ljq_esc_back:
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'\\'
    bl json_jputc
    b .Ljq_next
.Ljq_esc_b:
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'b'
    bl json_jputc
    b .Ljq_next
.Ljq_esc_t:
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'t'
    bl json_jputc
    b .Ljq_next
.Ljq_esc_n:
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'n'
    bl json_jputc
    b .Ljq_next
.Ljq_esc_f:
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'f'
    bl json_jputc
    b .Ljq_next
.Ljq_esc_r:
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'r'
    bl json_jputc
    b .Ljq_next
.Ljq_esc_u:
    // \u00XX with lowercase hex
    mov w0, #'\\'
    bl json_jputc
    mov w0, #'u'
    bl json_jputc
    mov w0, #'0'
    bl json_jputc
    mov w0, #'0'
    bl json_jputc
    lsr w22, w21, #4
    and w22, w22, #0xF
    mov w0, w22
    bl json_jhex
    and w22, w21, #0xF
    mov w0, w22
    bl json_jhex
    b .Ljq_next
.Ljq_next:
    add x20, x20, #1
    b .Ljq_loop
.Ljq_done:
    mov w0, #'"'
    bl json_jputc
    EPILOGUE 2
    ret

// json_jhex(nibble) — append a lowercase hex digit
    .p2align 2
json_jhex:
    PROLOGUE 0
    cmp w0, #10
    b.lt .Ljh_digit
    sub w0, w0, #10
    add w0, w0, #'a'
    b .Ljh_go
.Ljh_digit:
    add w0, w0, #'0'
.Ljh_go:
    bl json_jputc
    EPILOGUE 0
    ret

// (record-pointer arithmetic is the shared tc_entry_ptr in tc_util.S)

// json_jint(v) — append a decimal integer (no commas)
//   The digits are produced by the shared tc_fmt_u64 (count-first, MSB-first,
//   no NUL) into a 32-byte stack buffer, then handed to json_jputraw whole.
    .p2align 2
json_jint:
    PROLOGUE 1
    mov x19, x0                        // v
    sub sp, sp, #32                    // 20-digit buffer (32 keeps 16-aligned)
    mov x20, sp                        // buf (survives the calls)
    mov x0, x20
    mov x1, x19
    bl tc_fmt_u64                      // x0 = buf + digits (no NUL)
    sub x1, x0, x20                    // len
    mov x0, x20
    bl json_jputraw
    add sp, sp, #32
    EPILOGUE 1
    ret

// json_now_iso(buf) — "YYYY-MM-DDTHH:MM:SS" local time (generated_at)
    .p2align 2
json_now_iso:
    PROLOGUE 3
    mov x19, x0
    mov x0, #CLOCK_REALTIME
    LEA x1, json_ts
    bl clock_gettime
    LEA x0, json_ts
    LEA x1, json_tm
    bl localtime_r
    LEA x0, json_tm
    ldr w20, [x0, #TM_YEAR]
    add x20, x20, #TM_YEAR_BASE
    ldr w21, [x0, #TM_MON]
    add x21, x21, #1
    ldr w22, [x0, #TM_MDAY]
    mov x1, #YMD_YEAR_SCALE
    mul x20, x20, x1
    mov x1, #YMD_MONTH_SCALE
    mul x21, x21, x1
    add x20, x20, x21
    add x20, x20, x22                  // ymd
    ldr w21, [x0, #TM_HOUR]
    ldr w22, [x0, #TM_MIN]
    ldr w23, [x0, #TM_SEC]
    mov x1, #SECS_PER_HOUR
    mul x21, x21, x1
    mov x1, #60
    madd x21, x22, x1, x21
    add x21, x21, x23                  // sod
    mov x0, x19
    mov x1, x20
    mov x2, x21
    mov w3, #'T'
    bl tc_fmt_ymd_sod
    mov w1, #0
    strb w1, [x0]
    EPILOGUE 3
    ret

// ============================================================================
// tc_json_emit — the full report document.
// ============================================================================
    .p2align 2
    .global tc_json_emit
    FUNC_TYPE(tc_json_emit)
tc_json_emit:
    PROLOGUE 2
    mov x0, #STDOUT
    bl json_jinit
    // { + schema blob
    LEA x0, s_j_open
    mov x1, #2
    bl json_jputraw
    LEA x0, tc_json_schema_blob
    mov x1, #tc_json_schema_blob_len
    bl json_jputraw
    // schema_version + generated_at
    LEA x0, s_j_schema_version
    bl json_jputs
    LEA x0, s_j_generated_at
    bl json_jputs
    LEA x0, json_iso
    bl json_now_iso
    LEA x0, json_iso
    bl json_jquoted
    LEA x0, s_j_comma_nl
    bl json_jputs
    // query
    LEA x0, s_j_query
    bl json_jputs
    // channel
    LEA x0, s_j_qchannel
    bl json_jputs
    bl tc_channel_name
    bl json_jquoted
    LEA x0, s_j_comma_nl
    bl json_jputs
    // begin
    LEA x0, s_j_qbegin
    bl json_jputs
    LEA x19, tc_window
    LEA x20, json_iso
    mov x0, x20
    ldr x1, [x19, #TC_W_BEGIN_YMD]
    ldr x2, [x19, #TC_W_BEGIN_SOD]
    mov w3, #'T'
    bl tc_fmt_ymd_sod
    mov w1, #0
    strb w1, [x0]
    mov x0, x20
    bl json_jquoted
    LEA x0, s_j_comma_nl
    bl json_jputs
    // end
    LEA x0, s_j_qend
    bl json_jputs
    LEA x20, json_iso
    mov x0, x20
    ldr x1, [x19, #TC_W_END_YMD]
    ldr x2, [x19, #TC_W_END_SOD]
    mov w3, #'T'
    bl tc_fmt_ymd_sod
    mov w1, #0
    strb w1, [x0]
    mov x0, x20
    bl json_jquoted
    LEA x0, s_j_comma_nl
    bl json_jputs
    // min_count
    LEA x0, s_j_qmin
    bl json_jputs
    ldr x0, [x19, #TC_W_THRESHOLD]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // top
    LEA x0, s_j_qtop
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_LIMIT
    ldr x20, [x19]
    cbz x20, .Lje_top_null
    mov x0, x20
    bl json_jint
    b .Lje_top_done
.Lje_top_null:
    LEA x0, s_j_null
    bl json_jputs
.Lje_top_done:
    LEA x0, s_j_comma_nl
    bl json_jputs
    // state
    LEA x0, s_j_qstate
    bl json_jputs
    LEA x19, tc_window
    ldr x20, [x19, #TC_W_STATE_FILTER]
    cbz x20, .Lje_state_null
    LEA x0, tc_state_names
    sub x1, x20, #1
    ldr x0, [x0, x1, lsl #3]
    bl json_jquoted
    b .Lje_state_done
.Lje_state_null:
    LEA x0, s_j_null
    bl json_jputs
.Lje_state_done:
    LEA x0, s_j_comma_nl
    bl json_jputs
    // excluded
    LEA x0, s_j_qexcluded
    bl json_jputs
    bl json_emit_excluded_array
    LEA x0, s_j_comma_nl
    bl json_jputs
    // sort
    LEA x0, s_j_qsort
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_SORT
    ldr x20, [x19]
    LEA x0, tc_metric_names
    ldr x0, [x0, x20, lsl #3]
    bl json_jquoted
    LEA x0, s_j_comma_nl
    bl json_jputs
    // share_floor
    LEA x0, s_j_qsf
    bl json_jputs
    LEA x0, s_j_sf_req
    bl json_jputs
    LEA x19, tc_opts
    ldr x0, [x19, #TC_O_SHARE_FLOOR]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    LEA x0, s_j_sf_app
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_SHARE_FLOOR
    ldr x20, [x19]
    cbz x20, .Lje_sf_false
    LEA x0, s_j_true
    bl json_jputs
    b .Lje_sf_done
.Lje_sf_false:
    LEA x0, s_j_false
    bl json_jputs
.Lje_sf_done:
    LEA x0, s_j_close4
    bl json_jputs
    LEA x0, s_j_comma_nl
    bl json_jputs
    // sources
    LEA x0, s_j_qsources
    bl json_jputs
    bl json_emit_sources
    LEA x0, s_j_close4nl
    bl json_jputs
    LEA x0, s_j_nl
    bl json_jputs
    // close query, open totals
    LEA x0, s_j_query_close
    bl json_jputs
    LEA x0, s_j_totals
    bl json_jputs
    bl json_emit_totals
    LEA x0, s_j_close2
    bl json_jputs
    LEA x0, s_j_comma_nl
    bl json_jputs
    // rows
    LEA x0, s_j_rows
    bl json_jputs
    bl json_emit_rows
    LEA x0, s_j_end
    bl json_jputs
    bl json_jflush
    mov x0, #0
    EPILOGUE 2
    ret

// ============================================================================
// json_emit_excluded_array — the sorted exclusion logins.
// ============================================================================
    .p2align 2
json_emit_excluded_array:
    PROLOGUE 2
    LEA_OFF x19, tc_plan, TC_PLAN_EXCL_NAMES_N
    ldr x20, [x19]                    // n
    cbz x20, .Ljea_empty
    mov w0, #'['
    bl json_jputc
    mov w0, #'\n'
    bl json_jputc
    LEA_OFF x21, tc_plan, TC_PLAN_EXCL_NAMES
    ldr x21, [x21]
    mov x22, #0
.Ljea_loop:
    cmp x22, x20
    b.ge .Ljea_done
    LEA x0, s_j_ind6
    mov x1, #6
    bl json_jputraw
    mov x0, x21
    mov x1, x22
    mov x2, #LOGIN_SZ
    bl tc_entry_ptr
    bl json_jquoted
    add x9, x22, #1
    cmp x9, x20
    b.ge .Ljea_nl
    mov w0, #','
    bl json_jputc
.Ljea_nl:
    mov w0, #'\n'
    bl json_jputc
    add x22, x22, #1
    b .Ljea_loop
.Ljea_done:
    LEA x0, s_j_ind4
    mov x1, #4
    bl json_jputraw
    mov w0, #']'
    bl json_jputc
    b .Ljea_out
.Ljea_empty:
    mov w0, #'['
    bl json_jputc
    mov w0, #']'
    bl json_jputc
.Ljea_out:
    EPILOGUE 2
    ret

// ============================================================================
// json_src_emit(key, value_ptr, last) — `      "key": "<value>",\n` with a
//   trailing comma unless last != 0.  Shared body of the three source-entry
//   emitters (json_src_entry / json_src_entry_ptr / json_src_entry_last).
// ============================================================================
    .p2align 2
json_src_emit:
    PROLOGUE 2
    mov x19, x0                        // key
    mov x20, x1                        // value ptr
    mov x21, x2                        // last 0/1
    LEA x0, s_j_ind6
    mov x1, #6
    bl json_jputraw
    mov x0, x19
    bl json_jquoted
    LEA x0, s_j_colon
    bl json_jputs
    mov x0, x20
    bl json_jquoted
    cbnz x21, .Ljse_nocomma
    LEA x0, s_j_comma_nl
    bl json_jputs
    b .Ljse_done
.Ljse_nocomma:
    mov w0, #'\n'
    bl json_jputc
.Ljse_done:
    EPILOGUE 2
    ret

// json_src_entry(key, set_id) — resolve the set id to its source string, then
//   the direct-pointer form (same output as before).
    .p2align 2
json_src_entry:
    PROLOGUE 1
    mov x19, x0                        // key
    mov x20, x1                        // set id
    mov x0, x20
    bl tc_setting_src_str
    mov x1, x0                         // value ptr
    mov x0, x19                        // key
    mov w2, #0
    bl json_src_emit
    EPILOGUE 1
    ret

// json_src_entry_ptr(key, value_ptr) — `      "key": "<value>",\n` (value is a
//   direct pointer, not a set id)
    .p2align 2
json_src_entry_ptr:
    mov w2, #0
    b json_src_emit

// json_src_entry_last(key, value_ptr) — `      "key": "<value>\n` (last, no
//   comma)
    .p2align 2
json_src_entry_last:
    mov w2, #1
    b json_src_emit

// ============================================================================
// json_emit_sources — the sorted provenance map.
// ============================================================================
    .p2align 2
json_emit_sources:
    PROLOGUE 1
    // begin (value is a direct pointer, not a set id)
    LEA x0, s_js_begin
    LEA x1, tc_window
    ldr x1, [x1, #TC_W_START_SRC]
    bl json_src_entry_ptr
    // channel
    LEA x0, s_js_channel
    mov x1, #TC_SET_CHANNEL
    bl json_src_entry
    // end (only when not defaulted)
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_SRC + TC_SET_END*8]
    cmp x20, #TC_SRC_DEFAULT_NOW
    b.eq .Ljes_show
    LEA x0, s_js_end
    mov x1, #TC_SET_END
    bl json_src_entry
.Ljes_show:
    // exclude
    LEA_OFF x19, tc_plan, TC_PLAN_SRC_JOIN
    ldr x20, [x19]
    cbz x20, .Ljes_excl_none
    LEA x0, s_js_exclude
    mov x1, x20
    bl json_src_entry_ptr
    b .Ljes_header
.Ljes_excl_none:
    LEA x0, s_js_exclude
    LEA x1, s_jn_none
    bl json_src_entry_ptr
.Ljes_header:
    LEA x0, s_js_header
    mov x1, #TC_SET_HEADER
    bl json_src_entry
    LEA x0, s_js_logs_dir
    mov x1, #TC_SET_LOGS_DIR
    bl json_src_entry
    LEA x0, s_js_min_count
    mov x1, #TC_SET_MIN_COUNT
    bl json_src_entry
    LEA x0, s_js_share_floor
    mov x1, #TC_SET_SHARE_FLOOR
    bl json_src_entry
    // show (only when asked)
    LEA x19, tc_opts
    ldr x20, [x19, #TC_O_SRC + TC_SET_SHOW*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Ljes_sort
    LEA x0, s_js_show
    mov x1, #TC_SET_SHOW
    bl json_src_entry
.Ljes_sort:
    // sort (only when asked, not the built-in default)
    ldr x20, [x19, #TC_O_SRC + TC_SET_SORT*8]
    cmp x20, #TC_SRC_DEFAULT_BUILTIN
    b.eq .Ljes_state
    LEA x0, s_js_sort
    mov x1, #TC_SET_SORT
    bl json_src_entry
.Ljes_state:
    ldr x20, [x19, #TC_O_SRC + TC_SET_STATE*8]
    cmp x20, #TC_SRC_DEFAULT
    b.eq .Ljes_state_nofilter
    LEA x0, s_js_state
    mov x1, #TC_SET_STATE
    bl json_src_entry
    b .Ljes_top
.Ljes_state_nofilter:
    LEA x0, s_js_state
    LEA x1, s_j_not_filtered
    bl json_src_entry_ptr
.Ljes_top:
    // top (last, no comma)
    LEA x0, s_js_top
    LEA_OFF x1, tc_plan, TC_PLAN_LIMIT_SRC
    ldr x1, [x1]
    bl json_src_entry_last
    EPILOGUE 1
    ret

// ============================================================================
// json_emit_totals
// ============================================================================
    .p2align 2
json_emit_totals:
    PROLOGUE 2
    // users_shown
    LEA x0, s_j_t_shown
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_DISPLAYED_N
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // users_above_threshold
    LEA x0, s_j_t_above
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_REPORTED_N
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // users_in_range
    LEA x0, s_j_t_inrange
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_IN_RANGE
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // users_excluded
    LEA x0, s_j_t_excl
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_EXCL_APPEARED
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // messages_shown
    LEA x0, s_j_t_mshown
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_MSGS_SHOWN
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // messages_in_range
    LEA x0, s_j_t_minrange
    bl json_jputs
    LEA x19, tc_tally
    ldr x0, [x19, #TC_T_MESSAGES]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // messages_hidden
    LEA x0, s_j_t_mhidden
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_MSGS_HIDDEN
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // messages_excluded
    LEA x0, s_j_t_mexcl
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_EXCL_MSGS
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // truncated
    LEA x0, s_j_t_trunc
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_HIDDEN_N
    ldr x20, [x19]
    cbz x20, .Ljt_trunc_false
    LEA x0, s_j_true
    bl json_jputs
    b .Ljt_trunc_done
.Ljt_trunc_false:
    LEA x0, s_j_false
    bl json_jputs
.Ljt_trunc_done:
    LEA x0, s_j_comma_nl
    bl json_jputs
    // states
    LEA x0, s_j_t_states
    bl json_jputs
    bl json_emit_totals_states
    LEA x0, s_j_comma_nl
    bl json_jputs
    // log_files
    LEA x0, s_j_t_files
    bl json_jputs
    LEA x19, tc_tally
    ldr x0, [x19, #TC_T_FILES]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // users_below_share_floor
    LEA x0, s_j_t_below
    bl json_jputs
    LEA_OFF x19, tc_plan, TC_PLAN_BELOW_FLOOR
    ldr x0, [x19]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // cache
    LEA x0, s_j_t_cache
    bl json_jputs
    LEA x0, s_j_cache_used
    bl json_jputs
    LEA x19, tc_plan
    ldr x20, [x19, #TC_PLAN_CACHE_USED]
    cbz x20, .Ljt_used_false
    LEA x0, s_j_true
    bl json_jputs
    b .Ljt_used_done
.Ljt_used_false:
    LEA x0, s_j_false
    bl json_jputs
.Ljt_used_done:
    LEA x0, s_j_comma_nl
    bl json_jputs
    LEA x0, s_j_cache_days
    bl json_jputs
    ldr x0, [x19, #TC_PLAN_CACHE_REUSED]  // reused
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    LEA x0, s_j_cache_prob
    bl json_jputs
    ldr x20, [x19, #TC_PLAN_CACHE_PROBLEM] // problem
    cbz x20, .Ljt_prob_null
    mov x0, x20
    bl json_jquoted
    b .Ljt_prob_done
.Ljt_prob_null:
    LEA x0, s_j_null
    bl json_jputs
.Ljt_prob_done:
    LEA x0, s_j_nl
    bl json_jputs
    LEA x0, s_j_close4nl
    bl json_jputs
    LEA x0, s_j_comma_nl
    bl json_jputs
    // unreadable
    LEA x0, s_j_t_unreadable
    bl json_jputs
    bl json_emit_unreadable
    EPILOGUE 2
    ret

// json_emit_totals_states — the all-state split object (nonzero only).
//   The `{`/`}` shape is shared with json_emit_row_states.
    .p2align 2
json_emit_totals_states:
    PROLOGUE 2
    LEA x19, tc_tally
    ldr x20, [x19, #TC_T_STATES + 0]
    ldr x21, [x19, #TC_T_STATES + 8]
    ldr x22, [x19, #TC_T_STATES + 16]
    mov x0, x20
    mov x1, x21
    mov x2, x22
    LEA x3, s_j_ind6
    LEA x4, s_j_close4nl
    bl json_emit_state_obj
    EPILOGUE 2
    ret

// json_emit_unreadable — the array of {file, problem}
    .p2align 2
json_emit_unreadable:
    PROLOGUE 2
    LEA x19, tc_tally
    ldr x20, [x19, #TC_T_UNR_COUNT]
    cbz x20, .Ljun_empty
    mov w0, #'['
    bl json_jputc
    mov w0, #'\n'
    bl json_jputc
    add x21, x19, #TC_T_UNR_ENTRIES
    mov x22, #0
    // rows open at 6, their keys sit at 8, the "]" closes at 4
.Ljun_loop:
    cmp x22, x20
    b.ge .Ljun_done
    LEA x0, s_j_ind6
    mov x1, #6
    bl json_jputraw
    LEA x0, s_j_row_open
    mov x1, #2
    bl json_jputraw
    LEA x0, s_j_ind8
    mov x1, #8
    bl json_jputraw
    LEA x0, s_j_file
    bl json_jputs
    mov x0, x21
    mov x1, x22
    mov x2, #TC_T_UNR_ENTRY_SZ
    bl tc_entry_ptr
    bl json_jquoted
    LEA x0, s_j_comma_nl
    bl json_jputs
    LEA x0, s_j_ind8
    mov x1, #8
    bl json_jputraw
    LEA x0, s_j_problem
    bl json_jputs
    mov x0, x21
    mov x1, x22
    mov x2, #TC_T_UNR_ENTRY_SZ
    bl tc_entry_ptr
    add x0, x0, #TC_T_UNR_NAME_SZ
    bl json_jquoted
    mov w0, #'\n'
    bl json_jputc
    LEA x0, s_j_close6nl
    bl json_jputs
    add x9, x22, #1
    cmp x9, x20
    b.ge .Ljun_nl
    mov w0, #','
    bl json_jputc
.Ljun_nl:
    mov w0, #'\n'
    bl json_jputc
    add x22, x22, #1
    b .Ljun_loop
.Ljun_done:
    LEA x0, s_j_ind4
    bl json_jputs
    mov w0, #']'
    bl json_jputc
    b .Ljun_out
.Ljun_empty:
    mov w0, #'['
    bl json_jputc
    mov w0, #']'
    bl json_jputc
.Ljun_out:
    EPILOGUE 2
    ret

// ============================================================================
// json_emit_rows — the displayed rows.
// ============================================================================
    .p2align 2
json_emit_rows:
    PROLOGUE 3
    LEA_OFF x19, tc_plan, TC_PLAN_DISPLAYED_N
    ldr x20, [x19]                    // n
    cbz x20, .Ljer_empty
    mov w0, #'['
    bl json_jputc
    mov w0, #'\n'
    bl json_jputc
    LEA_OFF x21, tc_plan, TC_PLAN_REPORTED
    ldr x21, [x21]
    mov x22, #0                        // i
.Ljer_loop:
    cmp x22, x20
    b.ge .Ljer_done
    mov x0, x21
    mov x1, x22
    mov x2, #ROW_SZ
    bl tc_entry_ptr
    mov x23, x0                        // rec
    LEA x0, s_j_ind4
    mov x1, #4
    bl json_jputraw
    LEA x0, s_j_row_open
    mov x1, #2
    bl json_jputraw
    // login
    LEA x0, s_j_login
    bl json_jputs
    add x0, x23, #0                    // login ptr
    bl json_jquoted
    LEA x0, s_j_comma_nl
    bl json_jputs
    // count
    LEA x0, s_j_count
    bl json_jputs
    ldr x0, [x23, #ROW_COUNT]
    bl json_jint
    LEA x0, s_j_comma_nl
    bl json_jputs
    // states
    LEA x0, s_j_states_k
    bl json_jputs
    bl json_emit_row_states            // ends with the states close "      }"
    mov w0, #'\n'
    bl json_jputc
    LEA x0, s_j_close4nl
    bl json_jputs                      // "    }"
    add x9, x22, #1
    cmp x9, x20
    b.ge .Ljer_nl
    mov w0, #','
    bl json_jputc
.Ljer_nl:
    mov w0, #'\n'
    bl json_jputc
    add x22, x22, #1
    b .Ljer_loop
.Ljer_done:
    LEA x0, s_j_rows_close
    bl json_jputs
    b .Ljer_out
.Ljer_empty:
    mov w0, #'['
    bl json_jputc
    mov w0, #']'
    bl json_jputc
.Ljer_out:
    EPILOGUE 3
    ret

// json_emit_row_states — the per-user states object (filtered, nonzero, name order)
//   expects x23 = rec, x20 = displayed_n (unused here)
    .p2align 2
json_emit_row_states:
    PROLOGUE 3
    mov x19, x23                       // rec
    LEA x20, tc_window
    ldr x21, [x20, #TC_W_STATE_FILTER]
    // gather the three (state, count) pairs
    ldr x22, [x19, #ROW_LIVE]
    ldr x23, [x19, #ROW_OFFLINE]
    ldr x24, [x19, #ROW_UNKNOWN]
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
.Ljrs_write:
    mov x0, x22
    mov x1, x23
    mov x2, x24
    LEA x3, s_j_ind8
    LEA x4, s_j_close6nl
    bl json_emit_state_obj
    EPILOGUE 3
    ret

// ============================================================================
// json_emit_state_obj(live=x0, offline=x1, unknown=x2, entry_indent=x3,
//   close_indent=x4) — the `{`/`}` object of the nonzero state counts:
//   "{", newline, each nonzero `"name": n` at entry_indent, comma when a
//   later state is nonzero, newline, then close_indent + "}".  Shared by
//   json_emit_totals_states (indent 6, close 4) and json_emit_row_states
//   (indent 8, close 6).
// ============================================================================
    .p2align 2
json_emit_state_obj:
    PROLOGUE 4
    mov x19, x0                        // live
    mov x20, x1                        // offline
    mov x21, x2                        // unknown
    mov x22, x3                        // entry indent (asciz)
    mov x23, x4                        // close indent (asciz)
    orr x24, x19, x20
    orr x24, x24, x21
    cbz x24, .Ljeso_empty
    mov w0, #'{'
    bl json_jputc
    mov w0, #'\n'
    bl json_jputc
    mov x25, #0                        // state idx (0=live,1=offline,2=unknown)
.Ljeso_loop:
    cmp x25, #3
    b.ge .Ljeso_done
    cmp x25, #0
    b.eq .Ljeso_live_v
    cmp x25, #1
    b.eq .Ljeso_off_v
    mov x26, x21                       // unknown
    b .Ljeso_emit
.Ljeso_live_v:
    mov x26, x19
    b .Ljeso_emit
.Ljeso_off_v:
    mov x26, x20
.Ljeso_emit:
    cbz x26, .Ljeso_next
    mov x0, x22
    bl json_jputs
    LEA x0, tc_state_names
    ldr x0, [x0, x25, lsl #3]
    bl json_jquoted
    LEA x0, s_j_colon
    bl json_jputs
    mov x0, x26
    bl json_jint
    // comma if a later state is nonzero
    mov x10, x25
    add x10, x10, #1
.Ljeso_find:
    cmp x10, #3
    b.ge .Ljeso_nocomma
    cmp x10, #0
    b.eq .Ljeso_f_live
    cmp x10, #1
    b.eq .Ljeso_f_off
    mov x11, x21                       // unknown
    b .Ljeso_f_check
.Ljeso_f_live:
    mov x11, x19
    b .Ljeso_f_check
.Ljeso_f_off:
    mov x11, x20
.Ljeso_f_check:
    cbnz x11, .Ljeso_comma
    add x10, x10, #1
    b .Ljeso_find
.Ljeso_comma:
    mov w0, #','
    bl json_jputc
.Ljeso_nocomma:
    mov w0, #'\n'
    bl json_jputc
.Ljeso_next:
    add x25, x25, #1
    b .Ljeso_loop
.Ljeso_done:
    mov x0, x23
    bl json_jputs
    b .Ljeso_out
.Ljeso_empty:
    mov w0, #'{'
    bl json_jputc
    mov w0, #'}'
    bl json_jputc
.Ljeso_out:
    EPILOGUE 4
    ret

// ============================================================================
// tc_json_err — the --json failure shape: {"error": <msg>} to stderr, exit 1.
// ============================================================================
    .p2align 2
    .global tc_json_err
    FUNC_TYPE(tc_json_err)
tc_json_err:
    PROLOGUE 1
    mov x19, x0
    mov x0, #STDERR
    bl json_jinit
    LEA x0, s_j_err_open
    bl json_jputs
    mov x0, x19
    bl json_jquoted
    LEA x0, s_j_err_close
    bl json_jputs
    bl json_jflush
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
s_j_file:           .asciz "\"file\": "
s_j_problem:        .asciz "\"problem\": "

    .end
