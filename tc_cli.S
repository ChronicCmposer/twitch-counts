// ============================================================================
// tc_cli.S — the full CLI for twitch-counts
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian — Linux (musl, static) and
//              macOS arm64 (Mach-O, libSystem); tc_platform.h selects.
//  Assembler:  GNU as syntax, preprocessed (musl-gcc -c / clang -c)
//  Linking:    by the Makefile (build/<os>/twitch-counts and the drivers)
//
//  What this module owns
//  ---------------------
//    * the ENTIRE flag surface, parsed with musl getopt_long, matching
//      CPython argparse 3.11+ byte-for-byte where observable (messages,
//      wrapping, exit codes);
//    * the layered settings resolution CLI -> tc_env_get -> tc_config_get
//      -> built-in default, mirroring resolve()/resolve_settings();
//    * the window resolution (end, begin/since/users, begin>end check),
//      mirroring resolve_window_start()/resolve_context();
//    * the value parsers every later phase reuses;
//    * the source-string table served by tc_source_str().
//
//  The contract this module writes to is tc_layout.inc.  tc_env_get /
//  tc_config_get / tc_aliases_apply are implemented in tc_config.S (the
//  CLI-only driver links tc_config_stub.S instead).
//
//  Error/exit conventions (see tc_layout.inc)
//  --------------------------------------------------
//    * argparse-equivalent PARSE errors  -> usage block + "<prog>: error:
//      <msg>" on stderr, exit 2.
//    * RESOLUTION errors                 -> "error: <msg>" on stderr, exit 1.
//    * --help / -h                       -> full help on stdout, exit 0.
//    * <prog> is basename(argv[0]).
//
//  getopt_long usage
//  -----------------
//    argparse is strictly left-to-right while GNU getopt permutes, so this
//    module feeds getopt_long a CLEANED argv built by a pre-pass over the
//    original argv: recognized options (abbreviations rewritten to full
//    names) stay in encounter order with their values; unrecognized tokens
//    (unknown options and positionals) are collected separately in encounter
//    order.  The only merge is --watch's optional space-form value, which
//    getopt's optional_argument would otherwise not consume.
//
//  Exported (all .global, AAPCS64; x19-x28 preserved by every helper)
//  ------------------------------------------------------------------
//    tc_cli_parse(x0=argc, x1=argv)      -> 0; fills tc_opts + tc_window.
//    tc_source_str(x0=id)                -> (x0=ptr, x1=len)
//    tc_prog_name()                      -> x0 = basename(argv[0]) pointer
//    tc_print_help()                     prints help to stdout, exit 0
//    tc_setting_src_str(x0=TC_SET_*)     -> x0 = provenance string of a setting
//    tc_parse_datetime(x0=s, x1=eod)     -> (x0=ymd, x1=sod, x2=status,
//                                           x3=extra, x4=extra2)
//    tc_parse_duration(x0=s)             -> (x0=secs, x1=status)
//    tc_parse_bool(x0=s)                 -> (x0=0/1, x1=status)
//    tc_parse_state(x0=s)                -> (x0=TC_ST_*, x1=status)
//    tc_parse_header(x0=s)               -> (x0=TC_HDR_*, x1=status)
//    tc_parse_sort(x0=s)                 -> (x0=TC_M_*, x1=status)
//    tc_parse_curve(x0=s)                -> (x0=TC_CURVE_*, x1=status)
//    tc_parse_hex_colour(x0=s)           -> (x0=rgb, x1=status)
//    tc_parse_users_policy(x0=s)         -> (x0=id, x1=status)
//    tc_parse_metrics(x0=s)              -> (x0=count, x1=status,
//                                           x2=failing column ptr)
//    Parser status: 0 ok, 1 bad value, 2 range error (3 = no-such-week for
//    datetime; x3=year, x4=week then).
//    The int/float parsers (cli_parse_positive_int, cli_parse_nonnegative_int,
//    cli_parse_nonnegative_float, cli_parse_positive_float) are file-local.
//
//  Naming: tc_* is reserved for exported symbols; everything file-local is
//  cli_* (routines and data alike), and branch targets are .L labels.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------

    .equ VAL_CHANNEL,        1
    .equ VAL_BEGIN,          2
    .equ VAL_SINCE,          3
    .equ VAL_USERS,          4
    .equ VAL_USERS_POLICY,   5
    .equ VAL_USERS_MAX,      6
    .equ VAL_END,            7
    .equ VAL_MIN_COUNT,      8
    .equ VAL_BY_STATE,       9
    .equ VAL_SHOW,          10
    .equ VAL_SORT,          11
    .equ VAL_SHARE_FLOOR,   12
    .equ VAL_TOP,           13
    .equ VAL_HEADER,        14
    .equ VAL_LOGS_DIR,      15
    .equ VAL_JSON,          16
    .equ VAL_WATCH,         17
    .equ VAL_WATCH_HOLD,    18
    .equ VAL_COLOR,         19
    .equ VAL_LIVE,          20
    .equ VAL_OFFLINE,       21
    .equ VAL_UNKNOWN,       22
    .equ VAL_EXCLUDE,       23
    .equ VAL_EXCLUDE_GROUP, 24
    .equ VAL_EXCLUDE_BCAST, 25
    .equ VAL_INCLUDE,       26
    .equ VAL_NO_EXCLUDE,    27
    .equ VAL_CONFIG,        28
    .equ VAL_NO_CONFIG,     29
    .equ VAL_STREAMER,      30
    .equ VAL_NO_CACHE,      31
    .equ VAL_REBUILD_CACHE, 32
    .equ VAL_MANUAL,        33
    .equ VAL_EMIT_FISH,     34
    .equ VAL_COMPLETE,      35
    .equ VAL_HELP,          36
    .equ VAL_MAX,           36

    .equ P_NONE,         0
    .equ P_POS_INT,      1
    .equ P_NONNEG_INT,   2
    .equ P_NONNEG_FLOAT, 3
    .equ P_POS_FLOAT,    4
    .equ P_DURATION,     5
    .equ P_DATETIME_EOD, 6
    .equ P_DATETIME,     7
    .equ P_STATE,        8
    .equ P_HEADER,       9
    .equ P_SORT,        10
    .equ P_METRICS,     11
    .equ P_USERS_POLICY,12
    .equ P_BOOL,        13
    .equ P_CURVE,       14
    .equ P_HEX,         15
    .equ P_HIGHLIGHTS,  16
    .equ P_CHOICES_COLOR,    17
    .equ P_CHOICES_COMPLETE, 18

    .equ VT_CANON,    0
    .equ VT_SET,      8
    .equ VT_PARSER,   16
    .equ VT_HAS_ARG,  20
    .equ VT_STORE,    24
    .equ VT_FLAGS,    32
    .equ VT_CAP,      40            // string field capacity (bytes incl NUL);
                                    //   P_NONE store options use it, never a
                                    //   hard-coded cap (C6)
    .equ VT_REC_SZ,   48

    .equ LONGOPT_REC_SZ, 32            // getopt_long entry {name, has_arg, pad, flag, val, pad}

    .equ SP_ENV,      0
    .equ SP_KEY,      8
    .equ SP_SECTION,  16
    .equ SP_PARSER,   24
    .equ SP_DEFAULT,  32
    .equ SP_DEF_SRC,  40
    .equ SP_CLI_SRC,  48
    .equ SP_ENV_SRC,  56
    .equ SP_VALUE_OFF,64
    .equ SP_VALUE_SZ, 72
    .equ SP_FLAG,     80
    .equ SP_RAW2_OFF, 88
    .equ SP_REC_SZ,   96

    .equ OPT_MAX,     256
    .equ ARGSTR_SZ,   128
    .equ SCRATCH_SZ,  512
    .equ HELP_TEXT_SZ, 1104           // help text buffer (value up to ~1024)
    .equ HELP_LINE_SZ, 64
    .equ HELP_WRAP_W,  54             // argparse: 80 columns - 2 - help position 24

    // Epoch of 0001-01-01T00:00:00 UTC: tc_ymd_sod_to_epoch(10101).  The
    // --since underflow guard (C11) fails when a computed begin maps below
    // this (Python's datetime.min -> OverflowError).  (YEAR1_EPOCH lives in
    // tc_platform.h.)

// ----------------------------------------------------------------------------
// External symbols
// ----------------------------------------------------------------------------
    .globl getopt_long
    .globl optarg
    .globl opterr
    .globl strtod
    .globl clock_gettime
    .globl localtime_r
    .globl exit
    .globl fopen
    .globl fclose
    .globl tc_cat_cstr
    .globl tc_copy_str_cap
    .globl tc_streq
    .globl tc_report_fail
    .globl tc_days_from_civil
    .globl tc_civil_from_days
    .globl tc_is_leap
    .globl tc_days_in_month
    .globl tc_ymd_sod_to_epoch
    .globl tc_epoch_to_ymd_sod
    .globl tc_str_live
    .globl tc_str_offline
    .globl tc_str_unknown
    .globl tc_str_count
    .globl tc_str_login
    .globl tc_str_offshare
    .globl tc_str_liveshare

    // Highlight resolution ([[watch.highlight]]): the contract
    // tc_config_get cannot return array-of-tables (toml_raw_in only sees
    // kvals), so cli_resolve_highlights re-reads the config TOML directly via
    // tomlc99 and validates patterns with pcre2, the pattern tc_misc.S
    // established.  Every driver that links tc_cli.o also links toml.o and
    // libpcre2-8.a (the Makefile owns the driver links), so these are plain
    // strong references; the resolution path is only entered when
    // TC_O_CONFIG_LOADED is set, which tc_config_stub never sets.

// ============================================================================
// .bss
// ============================================================================
    .bss
    .p2align 4
    .global tc_opts
tc_opts:            .skip TC_OPTS_SIZE
    .global tc_window
tc_window:          .skip TC_WIN_SIZE
    .global tc_excl_set
tc_excl_set:        .skip TC_EX_SET_SZ
    .global tc_excl_sources
tc_excl_sources:    .skip TC_EX_SRC_TABLE_SZ
    .global tc_excl_src_buf
tc_excl_src_buf:    .skip TC_EX_SRC_BUF_SZ
    .global tc_users
tc_users:           .skip TC_US_HEADER_SZ
    .global tc_tally
tc_tally:           .skip TC_TALLY_SIZE
    .global tc_listing
tc_listing:         .skip TC_L_HEADER_SZ

    // private scratch (not part of the shared contract)
    .p2align 4
cli_opt_argv:        .skip 8 * OPT_MAX
cli_extras:          .skip 8 * OPT_MAX
cli_argstr:          .skip OPT_MAX * ARGSTR_SZ
cli_scratch:         .skip SCRATCH_SZ
help_text:          .skip HELP_TEXT_SZ  // "--config" help line before wrapping
help_line:          .skip HELP_LINE_SZ  // one wrapped line
cli_scratch2:        .skip SCRATCH_SZ
cli_dt_bad_year:     .skip 16              // {year, week} of a rejected ISO week
cli_err_display:     .skip SCRATCH_SZ      // normalised value quoted by a resolve error
cli_strtod_end:      .skip 8
cli_tm_buf:          .skip 64
cli_ts_buf:          .skip 16
cli_given:       .skip TC_SET_COUNT
cli_metrics_tmp:     .skip 8 * 6
cli_metrics_tmp_n:   .skip 8
cli_show_staging:    .skip 8 * 6       // --show columns before the by-state merge
cli_state:       .skip 8
cli_win_first:       .skip 8
cli_win_kind:        .skip 8
cli_win_raw:         .skip 8
cli_win_src:         .skip 8
cli_opt_n:           .skip 8
cli_extras_n:        .skip 8
cli_argc_saved:      .skip 8
cli_argv_saved:      .skip 8

    .text

// ============================================================================
// tc_cli_parse — parse + resolve.  x0=argc, x1=argv.  -> 0.
// ============================================================================
    .p2align 2
    .global tc_cli_parse
    FUNC_TYPE(tc_cli_parse)
tc_cli_parse:
    PROLOGUE 5
    mov x19, x0                     // argc
    mov x20, x1                     // argv

    // basename(argv[0])
    ldr x0, [x20]
    bl cli_basename
    LEA x1, tc_opts
    str x0, [x1, #TC_O_PROG_PTR]
    bl tc_strlen
    LEA x1, tc_opts
    str x0, [x1, #TC_O_PROG_LEN]

    // clear private marks
    LEA x0, cli_given
    mov x1, #TC_SET_COUNT
    bl cli_memzero
    LEA x0, cli_state
    mov x1, #8
    bl cli_memzero
    LEA x0, cli_win_first
    mov x1, #8
    bl cli_memzero
    LEA x0, cli_opt_n
    mov x1, #8
    bl cli_memzero
    LEA x0, cli_extras_n
    mov x1, #8
    bl cli_memzero

    // pre-pass
    mov x0, x19
    mov x1, x20
    bl cli_prepass                   // exit 2 on parse errors

    // getopt_long over the cleaned argv.  getopt's argc counts argv[0], so
    // shift the cleaned tokens right by one and put the program name first.
    LEA x0, cli_opt_n
    ldr x21, [x0]
    LEA x0, cli_opt_argv
    mov x1, x21
.Lgl_shift:
    cbz x1, .Lgl_shift_done
    sub x2, x1, #1
    ldr x3, [x0, x2, lsl #3]       // opt_argv[i-1]
    str x3, [x0, x1, lsl #3]       // opt_argv[i] = opt_argv[i-1]
    sub x1, x1, #1
    b .Lgl_shift
.Lgl_shift_done:
    ldr x2, [x20]                   // argv[0] (the program name)
    str x2, [x0]
    add x21, x21, #1                // getopt argc = opt_n + 1
    LOAD_EXTERN_DATA_ADDR x0, opterr
    str wzr, [x0]

    // getopt loop register roles: x21 = argc, x22 = current option val
    // (see .Lgl_have_optarg), x23 = optarg.  x19/x20 stay free.
.Lgl_loop:
    cbz x21, .Lgl_done
    mov x0, x21
    LEA x1, cli_opt_argv
    LEA x2, optstring
    LEA x3, cli_longopts
    mov x4, #0

    bl getopt_long
    cmn w0, #1
    b.eq .Lgl_done
    cmp w0, #VAL_MAX
    b.le .Lgl_mapped
    mov x22, x0
    bl cli_short_lookup
    mov x22, x0
    b .Lgl_have_optarg
.Lgl_mapped:
    mov x22, x0
.Lgl_have_optarg:
    LOAD_EXTERN_DATA_ADDR x23, optarg
    ldr x23, [x23]
    cmp x22, #VAL_HELP
    b.eq .Ldo_help
    mov x0, x22
    mov x1, x23
    bl cli_handle_opt
    b .Lgl_loop
.Lgl_done:

    LEA x0, cli_extras_n
    ldr x0, [x0]
    cbnz x0, .Lunrecognized

    // ---- dispatch-only flags skip the report resolution block --------------
    // Python's main() handles --manual / --emit-fish-completions before any
    // channel resolution (fixed text; no channel, window or config work), and
    // --complete resolves only the settings its candidates need.  The report
    // resolution must therefore be shaped per flag:
    //   * --manual / --emit-fish-completions: resolve NOTHING (a bare
    //     `--manual` must not fail with "no channel given").
    //   * --complete: resolve the settings (channel + logs-dir reach
    //     TC_O_CHANNEL / TC_O_LOGS_DIR / TC_O_CONFIG_PATH for the completion
    //     module, which reads them), but NOT the window (a bad --begin must
    //     not fail a completion, matching Python) and with the aliases pass
    //     guard-skipped when the channel never resolved (Python returns []
    //     quietly at a prompt instead of "no channel given").
    //   * otherwise (report / watch): full resolution below.
    LEA x0, tc_opts
    ldr x0, [x0, #TC_O_FLAGS]
    tst x0, #TC_F_MANUAL
    b.ne .Lgl_done_ret
    tst x0, #TC_F_EMIT_FISH
    b.ne .Lgl_done_ret
    tst x0, #TC_F_COMPLETE_GIVEN
    b.ne .Lgl_complete

    bl cli_resolve_settings
    bl cli_resolve_window
    bl tc_aliases_apply
    bl cli_choose_columns
    b .Lgl_done_ret

.Lgl_complete:
    bl cli_resolve_settings
    // skip the "no channel given" guard: aliases apply only when the channel
    // resolved to a real value (source != TC_SRC_DEFAULT).
    LEA x0, tc_opts
    mov x2, #TC_O_SRC
    add x2, x0, x2
    ldr x1, [x2, #TC_SET_CHANNEL*8]
    cmp x1, #TC_SRC_DEFAULT
    b.eq .Lgl_done_ret
    bl tc_aliases_apply
.Lgl_done_ret:
    EPILOGUE 5
    ret

.Ldo_help:
    bl tc_print_help

.Lunrecognized:
    LEA x0, cli_extras
    LEA x1, cli_extras_n
    ldr x1, [x1]
    LEA x2, cli_scratch
    LEA x3, s_unrecognized
    bl cli_join_args_into
    LEA x0, cli_scratch
    bl cli_arg_error

// ----------------------------------------------------------------------------
// cli_memzero(x0=ptr, x1=len)
// ----------------------------------------------------------------------------
    .p2align 2
cli_memzero:
    mov x2, #0
.Lmz:
    cbz x1, .Lmz_done
    strb w2, [x0], #1
    sub x1, x1, #1
    b .Lmz
.Lmz_done:
    ret

// ----------------------------------------------------------------------------
// cli_basename(x0=path) -> x0 = pointer after the last '/'
// ----------------------------------------------------------------------------
    .p2align 2
cli_basename:
    mov x1, x0
    mov x2, x0
.Lbn:
    ldrb w3, [x1]
    cbz w3, .Lbn_done
    cmp w3, #'/'
    b.ne .Lbn_next
    add x2, x1, #1
.Lbn_next:
    add x1, x1, #1
    b .Lbn
.Lbn_done:
    mov x0, x2
    ret

// ----------------------------------------------------------------------------
// tc_prog_name() -> x0 = basename(argv[0])
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_prog_name
    FUNC_TYPE(tc_prog_name)
tc_prog_name:
    LEA x0, tc_opts
    ldr x0, [x0, #TC_O_PROG_PTR]
    ret

// ----------------------------------------------------------------------------
// cli_join_args_into — "prefix a b c" into dst.
//   in: x0 = array, x1 = count, x2 = dst, x3 = prefix
// ----------------------------------------------------------------------------
    .p2align 2
cli_join_args_into:
    // leaf (no bl): save only the pairs actually used; the PROLOGUE's
    // x29/x30 frame record would be dead weight here.
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x4, x3
.Lj_pre:
    ldrb w5, [x4], #1
    strb w5, [x21], #1
    cbnz w5, .Lj_pre
    sub x21, x21, #1
    mov x6, #0
.Lj_loop:
    cmp x6, x20
    b.ge .Lj_done
    mov w5, #' '
    strb w5, [x21], #1
    ldr x7, [x19, x6, lsl #3]
.Lj_copy:
    ldrb w5, [x7], #1
    strb w5, [x21], #1
    cbnz w5, .Lj_copy
    sub x21, x21, #1
    add x6, x6, #1
    b .Lj_loop
.Lj_done:
    mov w5, #0
    strb w5, [x21]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cli_arg_error — usage + "<prog>: error: <msg>" to stderr, exit 2.
// ----------------------------------------------------------------------------
    .p2align 2
cli_arg_error:
    PROLOGUE 5
    mov x19, x0
    mov x0, #STDERR
    bl cli_print_usage
    LEA x0, tc_opts
    ldr x0, [x0, #TC_O_PROG_PTR]
    bl tc_eputs
    LEA x0, s_colon_err
    bl tc_eputs
    mov x0, x19
    bl tc_eputs
    LEA x0, s_newline
    bl tc_eputs
    mov w0, #2
    bl exit

// ----------------------------------------------------------------------------
// cli_print_usage(x0=fd) — the wrapped usage block.
// ----------------------------------------------------------------------------
    .p2align 2
cli_print_usage:
    // argparse.HelpFormatter._format_usage: the usage is a list of parts
    // ("[-c CHANNEL]", "[-b BEGIN | -S SINCE | --users N]", ...) packed
    // greedily into lines of text_width = max(terminal columns - 2, 11),
    // the continuation lines indented past "usage: <prog> ".  A part is
    // never split.  (Word-wrapping at a fixed 80 columns broke "[--sort
    // METRIC]" across lines and ignored $COLUMNS / the terminal.)
    PROLOGUE 5
    mov x19, x0                        // fd
    LEA x20, tc_opts
    ldr x21, [x20, #TC_O_PROG_PTR]
    ldr x22, [x20, #TC_O_PROG_LEN]
    bl tc_term_columns
    sub x20, x0, #2                    // width = columns - 2
    cmp x20, #11
    b.ge .Lpu_width_ok
    mov x20, #11                       // text_width = max(width, 11)
.Lpu_width_ok:
    // "usage: " + prog
    mov x0, x19
    LEA x1, s_usage_prefix
    bl cli_fd_puts
    mov x0, x19
    mov x1, x21
    mov x2, x22
    bl cli_fd_write
    // a prog wider than 0.75 * text_width goes on a line of its own and
    // the parts are indented by len("usage: ") only
    add x9, x22, #7
    lsl x9, x9, #2                     // 4 * (len(prefix) + len(prog))
    mov x10, #3
    mul x10, x20, x10                  // 3 * text_width
    cmp x9, x10
    b.gt .Lpu_long_prog
    add x24, x22, #8                   // indent = len(prefix) + len(prog) + 1
    add x23, x22, #7                   // line_len = (len(prefix) - 1) + len(prog) + 1
    mov x25, #1                        // the line holds an item (prog)
    b .Lpu_parts
.Lpu_long_prog:
    mov x0, x19
    LEA x1, s_newline
    mov x2, #1
    bl cli_fd_write
    mov x24, #7                        // indent = len(prefix)
    mov x28, x24
    bl cli_puts_spaces
    mov x23, #6                        // line_len = indent - 1
    mov x25, #0                        // the line is empty
.Lpu_parts:
    LEA x26, cli_usage_parts
.Lpu_loop:
    ldr x27, [x26], #8
    cbz x27, .Lpu_done
    mov x0, x27
    bl tc_strlen
    mov x28, x0                        // len(part)
    // if line_len + 1 + len(part) > text_width and line: new line
    add x9, x23, #1
    add x9, x9, x28
    cmp x9, x20
    b.le .Lpu_append
    cbz x25, .Lpu_append
    mov x0, x19
    LEA x1, s_newline
    mov x2, #1
    bl cli_fd_write
    mov x21, x28                       // keep the part length (callee-saved)
    mov x28, x24                       // count = indent
    bl cli_puts_spaces                 // clobbers x0-x17 only; x19-x28 preserved
    mov x28, x21                       // restore the part length
    sub x23, x24, #1                   // line_len = indent - 1
    mov x25, #0
.Lpu_append:
    cbz x25, .Lpu_no_sep
    mov x0, x19
    LEA x1, s_space
    mov x2, #1
    bl cli_fd_write
.Lpu_no_sep:
    mov x0, x19
    mov x1, x27
    mov x2, x28
    bl cli_fd_write
    add x23, x23, x28
    add x23, x23, #1                   // line_len += len(part) + 1
    mov x25, #1
    b .Lpu_loop
.Lpu_done:
    mov x0, x19
    LEA x1, s_newline
    mov x2, #1
    bl cli_fd_write
    EPILOGUE 5
    ret

// cli_puts_spaces(x19=fd, x28=count): write count spaces to fd.
// Preserves x19-x28 (PROLOGUE 1 covers x19,x20; x28 is read-only input);
// clobbers x0-x17 only (the internal cli_fd_write call).
cli_puts_spaces:
    PROLOGUE 1
    mov x20, x28
.Lpu_spaces_loop:
    cbz x20, .Lpu_spaces_done
    mov x0, x19
    LEA x1, s_space
    mov x2, #1
    bl cli_fd_write
    sub x20, x20, #1
    b .Lpu_spaces_loop
.Lpu_spaces_done:
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cli_fd_write(x0=fd, x1=buf, x2=len) — tail call to libc write(2), not a raw
// syscall (write is renamed to _write on Darwin by tc_platform.h).  Like any
// libc call it clobbers x0-x17; callers must hold nothing live there across
// it.  x0 = write()'s return value (bytes written, or -1) is passed through
// unexamined to our own caller.
// ----------------------------------------------------------------------------
    .p2align 2
cli_fd_write:
    b write

// ----------------------------------------------------------------------------
// cli_fd_puts(x0=fd, x1=s)
// ----------------------------------------------------------------------------
    .p2align 2
cli_fd_puts:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x0, x20
    bl tc_strlen
    mov x2, x0
    mov x0, x19
    mov x1, x20
    bl cli_fd_write
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// tc_print_help — help to stdout, exit 0
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_print_help
    FUNC_TYPE(tc_print_help)
tc_print_help:
    PROLOGUE 1
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x0, #STDOUT
    bl cli_print_usage
    LEA x0, help_body
    bl tc_puts
    // dynamic "--config" default: expanduser(DEFAULT_CONFIG_PATH), then
    // shorten_path — computed at runtime the way argparse does (line 3954
    // of twitch-counts.py).  When it comes out identical to the ordinary
    // "~/.config/twitch-counts.toml" (true whenever HOME resolves to a
    // real home directory), the pre-wrapped static two-line text is used
    // verbatim.  Otherwise the value is spliced into a single unwrapped
    // line — argparse's own wrapping only breaks the text when it does
    // not fit the terminal width, which the common short values here do.
    LEA x0, cli_scratch
    mov x1, #SCRATCH_SZ
    bl tc_default_config_path        // the platform class's DEFAULT_CONFIG_PATH
    LEA x0, cli_scratch
    bl tc_shorten_path               // x0 = ptr to shortened path (scratch)
    mov x19, x0
    LEA x1, s_default_config_path
    bl tc_streq
    cbz w0, .Lph_config_dyn
    LEA x0, s_help_config_static
    bl tc_puts
    b .Lph_config_done
.Lph_config_dyn:
    // argparse wraps a help string with textwrap at width 78 - 24 = 54
    // (an 80-column terminal, the help column at 24): greedy fill of
    // chunks split at whitespace and after a hyphen that sits between two
    // word characters; a lone chunk wider than the line is cut at the
    // width; trailing spaces are dropped at a break.  The value is spliced
    // into "TOML config file (default: <value>)" and wrapped the same way.
    LEA x20, help_text
    mov x0, x20
    LEA x1, s_help_cfg_text
    bl tc_cat_cstr
    mov x1, x19
    bl tc_cat_cstr
    mov w1, #')'
    strb w1, [x0], #1
    strb wzr, [x0]
    LEA x26, help_line
    mov x21, #0                       // pos in help_text
    mov x22, #1                       // first line pending
.Lhw_line:
    ldrb w9, [x20, x21]
    cbz w9, .Lph_config_done
    cmp w9, #' '                      // a line never starts with a space
    b.ne .Lhw_fill
    add x21, x21, #1
    b .Lhw_line
.Lhw_fill:
    mov x23, #0                       // col = line length so far
.Lhw_chunk:
    ldrb w9, [x20, x21]
    cbz w9, .Lhw_flush
    cmp w9, #' '
    b.ne .Lhw_word
    add x24, x21, #1                  // a space is a chunk of its own
    b .Lhw_have_chunk
.Lhw_word:
    mov x24, x21
.Lhw_scan:
    ldrb w9, [x20, x24]
    cbz w9, .Lhw_have_chunk
    cmp w9, #' '
    b.eq .Lhw_have_chunk
    add x24, x24, #1
    cmp w9, #'-'
    b.ne .Lhw_scan
    // hyphen: break after it when both neighbours are word characters
    sub x10, x24, #2
    cmp x10, x21
    b.lt .Lhw_scan
    ldrb w10, [x20, x10]
    bl cli_help_is_word_char
    cbz w0, .Lhw_scan
    ldrb w10, [x20, x24]
    bl cli_help_is_word_char
    cbz w0, .Lhw_scan
.Lhw_have_chunk:
    sub x25, x24, x21                 // chunk length
    add x9, x23, x25
    cmp x9, #HELP_WRAP_W
    b.le .Lhw_take
    cbnz x23, .Lhw_flush              // does not fit: break before it
    mov x25, #HELP_WRAP_W             // a lone over-wide chunk is cut
    add x24, x21, x25
.Lhw_take:
    mov x9, #0
.Lhw_copy:
    cmp x9, x25
    b.ge .Lhw_copied
    ldrb w10, [x20, x21]
    add x11, x26, x23
    strb w10, [x11]
    add x21, x21, #1
    add x23, x23, #1
    add x9, x9, #1
    b .Lhw_copy
.Lhw_copied:
    b .Lhw_chunk
.Lhw_flush:
    // drop trailing spaces, terminate, print prefix + line
    cbz x23, .Lhw_emit
    sub x9, x23, #1
    ldrb w9, [x26, x9]
    cmp w9, #' '
    b.ne .Lhw_emit
    sub x23, x23, #1
    b .Lhw_flush
.Lhw_emit:
    strb wzr, [x26, x23]
    cbz x22, .Lhw_rest_prefix
    mov x22, #0
    LEA x0, s_help_cfg_first
    b .Lhw_prefix_out
.Lhw_rest_prefix:
    LEA x0, s_help_indent
.Lhw_prefix_out:
    bl tc_puts
    mov x0, x26
    bl tc_puts
    LEA x0, s_help_nl
    bl tc_puts
    b .Lhw_line
.Lph_config_done:
    LEA x0, help_body_b
    bl tc_puts
    mov w0, #0
    bl exit


// cli_help_is_word_char: w0 = 1 when the byte in w10 is [0-9A-Za-z_], else 0.
    .p2align 2
cli_help_is_word_char:
    mov w0, #1
    cmp w10, #'0'
    b.lt .Lhiw_no
    cmp w10, #'9'
    b.le .Lhiw_yes
    cmp w10, #'A'
    b.lt .Lhiw_no
    cmp w10, #'Z'
    b.le .Lhiw_yes
    cmp w10, #'_'
    b.eq .Lhiw_yes
    cmp w10, #'a'
    b.lt .Lhiw_no
    cmp w10, #'z'
    b.le .Lhiw_yes
.Lhiw_no:
    mov w0, #0
.Lhiw_yes:
    ret

// ============================================================================
// cli_handle_opt(x0=val, x1=optarg) — dispatch one option (may exit 2).
// ============================================================================
    .p2align 2
cli_handle_opt:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    cmp x19, #VAL_BY_STATE
    b.eq .Lho_by_state
    cmp x19, #VAL_JSON
    b.eq .Lho_json
    cmp x19, #VAL_LIVE
    b.eq .Lho_live
    cmp x19, #VAL_OFFLINE
    b.eq .Lho_offline
    cmp x19, #VAL_UNKNOWN
    b.eq .Lho_unknown
    cmp x19, #VAL_EXCLUDE_BCAST
    b.eq .Lho_bcast
    cmp x19, #VAL_NO_EXCLUDE
    b.eq .Lho_no_exclude
    cmp x19, #VAL_NO_CONFIG
    b.eq .Lho_no_config
    cmp x19, #VAL_STREAMER
    b.eq .Lho_streamer
    cmp x19, #VAL_NO_CACHE
    b.eq .Lho_no_cache
    cmp x19, #VAL_REBUILD_CACHE
    b.eq .Lho_rebuild_cache
    cmp x19, #VAL_MANUAL
    b.eq .Lho_manual
    cmp x19, #VAL_EMIT_FISH
    b.eq .Lho_emit_fish
    cmp x19, #VAL_EXCLUDE
    b.eq .Lho_exclude
    cmp x19, #VAL_EXCLUDE_GROUP
    b.eq .Lho_exclude_group
    cmp x19, #VAL_INCLUDE
    b.eq .Lho_include
    cmp x19, #VAL_WATCH
    b.eq .Lho_watch
    cmp x19, #VAL_CONFIG
    b.eq .Lho_config
    cmp x19, #VAL_BEGIN
    b.eq .Lho_begin
    cmp x19, #VAL_SINCE
    b.eq .Lho_since
    cmp x19, #VAL_USERS
    b.eq .Lho_users
    mov x0, x19
    mov x1, x20
    bl cli_handle_typed
    b .Lho_done

.Lho_by_state:
    mov x0, #TC_F_BY_STATE
    bl cli_set_flag
    b .Lho_done
.Lho_json:
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_WATCH_PRESENT
    b.ne .Lho_json_conflict
    mov x0, #TC_F_JSON
    bl cli_set_flag
    b .Lho_done
.Lho_json_conflict:
    LEA x0, s_canon_json
    LEA x1, s_canon_watch
    bl cli_arg_not_allowed
.Lho_bcast:
    mov x0, #TC_F_EXCLUDE_BCAST
    bl cli_set_flag
    LEA x1, cli_given
    mov x2, #1
    strb w2, [x1, #TC_SET_EXCLUDE_BCAST]
    b .Lho_done
.Lho_no_exclude:
    mov x0, #TC_F_NO_EXCLUDE
    bl cli_set_flag
    b .Lho_done
.Lho_no_config:
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_CONFIG_GIVEN
    b.ne .Lho_no_config_conflict
    mov x0, #TC_F_NO_CONFIG
    bl cli_set_flag
    b .Lho_done
.Lho_no_config_conflict:
    LEA x0, s_canon_no_config
    LEA x1, s_canon_config
    bl cli_arg_not_allowed
.Lho_streamer:
    mov x0, #TC_F_STREAMER
    bl cli_set_flag
    LEA x1, cli_given
    mov x2, #1
    strb w2, [x1, #TC_SET_STREAMER_MODE]
    b .Lho_done
.Lho_no_cache:
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_REBUILD_CACHE
    b.ne .Lho_no_cache_conflict
    mov x0, #TC_F_NO_CACHE
    bl cli_set_flag
    b .Lho_done
.Lho_no_cache_conflict:
    LEA x0, s_canon_no_cache
    LEA x1, s_canon_rebuild_cache
    bl cli_arg_not_allowed
.Lho_rebuild_cache:
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_NO_CACHE
    b.ne .Lho_rebuild_conflict
    mov x0, #TC_F_REBUILD_CACHE
    bl cli_set_flag
    b .Lho_done
.Lho_rebuild_conflict:
    LEA x0, s_canon_rebuild_cache
    LEA x1, s_canon_no_cache
    bl cli_arg_not_allowed
.Lho_manual:
    mov x0, #TC_F_MANUAL
    bl cli_set_flag
    b .Lho_done
.Lho_emit_fish:
    mov x0, #TC_F_EMIT_FISH
    bl cli_set_flag
    b .Lho_done

.Lho_live:
    mov x0, #TC_ST_LIVE
    b .Lho_state
.Lho_offline:
    mov x0, #TC_ST_OFFLINE
    b .Lho_state
.Lho_unknown:
    mov x0, #TC_ST_UNKNOWN
.Lho_state:
    mov x19, x0
    LEA x0, cli_state
    ldr x1, [x0]
    cbnz x1, .Lho_state_conflict
    str x19, [x0]
    LEA x0, tc_opts
    str x19, [x0, #TC_O_STATE_FILTER]
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, #TC_SET_STATE]
    b .Lho_done
// x19 = the state constant for the option just parsed (current arg); x1 =
// the state constant already stored in cli_state (the earlier, conflicting
// arg).  Each adrp/add pair below must name the SAME symbol -- a mismatched
// pair (adrp of one canonical string, add LO12 of another) only produced the
// right address by accident on Linux, when both strings happened to share a
// 4 KiB page; it breaks in general and must not be "merged" into a shared
// add via a fall-through label.
.Lho_state_conflict:
    cmp x19, #TC_ST_LIVE
    b.eq .Lho_sc_live
    cmp x19, #TC_ST_OFFLINE
    b.eq .Lho_sc_offline
    LEA x0, s_canon_unknown
    b .Lho_sc_prev
.Lho_sc_live:
    LEA x0, s_canon_live
    b .Lho_sc_prev
.Lho_sc_offline:
    LEA x0, s_canon_offline
.Lho_sc_prev:
    cmp x1, #TC_ST_LIVE
    b.eq .Lho_sc_prev_live
    cmp x1, #TC_ST_OFFLINE
    b.eq .Lho_sc_prev_offline
    LEA x1, s_canon_unknown
    b .Lho_sc_emit
.Lho_sc_prev_live:
    LEA x1, s_canon_live
    b .Lho_sc_emit
.Lho_sc_prev_offline:
    LEA x1, s_canon_offline
.Lho_sc_emit:
    bl cli_arg_not_allowed

.Lho_exclude:
    mov x0, #TC_O_EXCL_LIST
    mov x1, #TC_O_EXCL_COUNT
    mov x2, #64
    mov x3, #TC_F_EXCL_GIVEN
    mov x4, #TC_SET_EXCLUDE
    b .Lho_list
.Lho_exclude_group:
    mov x0, #TC_O_EXCL_GROUP_LIST
    mov x1, #TC_O_EXCL_GROUP_COUNT
    mov x2, #32
    mov x3, #TC_F_EXCL_GROUP_GIVEN
    mov x4, #TC_SET_EXCLUDE_GROUP
    b .Lho_list
.Lho_include:
    mov x0, #TC_O_INCL_LIST
    mov x1, #TC_O_INCL_COUNT
    mov x2, #64
    mov x3, #TC_F_INCL_GIVEN
    mov x4, #TC_SET_INCLUDE
.Lho_list:
    mov x5, x20
    bl cli_append_list
    b .Lho_done

.Lho_watch:
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_JSON
    b.ne .Lho_watch_json_conflict
    mov x0, #TC_F_WATCH_PRESENT
    bl cli_set_flag
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, #TC_SET_INTERVAL]
    cbz x20, .Lho_watch_fc
    mov x0, x20
    bl cli_parse_nonnegative_float
    cbnz x1, .Lho_watch_bad
    LEA x1, tc_opts
    str x0, [x1, #TC_O_INTERVAL]
    ldr x2, [x1, #TC_O_FLAGS]
    orr x2, x2, #TC_F_WATCH_VALUE
    str x2, [x1, #TC_O_FLAGS]
    b .Lho_done
.Lho_watch_fc:
    ldr x0, =TC_WATCH_FROM_CONFIG_BITS
    LEA x1, tc_opts
    str x0, [x1, #TC_O_INTERVAL]
    b .Lho_done
.Lho_watch_bad:
    LEA x0, s_canon_watch
    mov x2, #P_NONNEG_FLOAT
    mov x3, x1                      // actual status (1=parse, 2=range)
    mov x1, x20                     // display
    bl cli_emit_typed_err
.Lho_watch_json_conflict:
    LEA x0, s_canon_watch
    LEA x1, s_canon_json
    bl cli_arg_not_allowed

.Lho_config:
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_NO_CONFIG
    b.ne .Lho_config_conflict
    mov x0, #TC_F_CONFIG_GIVEN
    bl cli_set_flag
    LEA_OFF x0, tc_opts, TC_O_CONFIG_PATH
    mov x1, x20
    mov x2, #TC_O_CONFIG_PATH_SZ
    bl tc_copy_str_cap
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, #TC_SET_CONFIG]
    b .Lho_done
.Lho_config_conflict:
    LEA x0, s_canon_config
    LEA x1, s_canon_no_config
    bl cli_arg_not_allowed

.Lho_begin:
    mov x0, #VAL_BEGIN
    mov x1, #VAL_SINCE
    mov x2, #VAL_USERS
    bl cli_win_conflict_check
    mov x0, #TC_F_BEGIN_GIVEN
    bl cli_set_flag
    LEA_OFF x0, tc_opts, TC_O_BEGIN_RAW
    mov x1, x20
    mov x2, #TC_O_BEGIN_RAW_SZ
    bl tc_copy_str_cap
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, #TC_SET_BEGIN]
    b .Lho_done
.Lho_since:
    mov x0, #VAL_SINCE
    mov x1, #VAL_BEGIN
    mov x2, #VAL_USERS
    bl cli_win_conflict_check
    mov x0, #TC_F_SINCE_GIVEN
    bl cli_set_flag
    LEA_OFF x0, tc_opts, TC_O_SINCE_RAW
    mov x1, x20
    mov x2, #TC_O_SINCE_RAW_SZ
    bl tc_copy_str_cap
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, #TC_SET_SINCE]
    b .Lho_done
.Lho_users:
    mov x0, #VAL_USERS
    mov x1, #VAL_BEGIN
    mov x2, #VAL_SINCE
    bl cli_win_conflict_check
    mov x0, x20
    bl cli_parse_positive_int
    cbnz x1, .Lho_users_bad
    LEA x1, tc_opts
    str x0, [x1, #TC_O_USERS]
    mov x0, #TC_F_USERS_GIVEN
    bl cli_set_flag
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, #TC_SET_USERS]
    b .Lho_done
.Lho_users_bad:
    LEA x0, s_canon_users
    mov x2, #P_POS_INT              // parser
    mov x3, x1                      // actual status (1=parse, 2=range)
    mov x1, x20                     // display
    bl cli_emit_typed_err
.Lho_done:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_set_flag(x0=bit)
// ----------------------------------------------------------------------------
    .p2align 2
cli_set_flag:
    LEA x1, tc_opts
    ldr x2, [x1, #TC_O_FLAGS]
    orr x2, x2, x0
    str x2, [x1, #TC_O_FLAGS]
    ret

// ----------------------------------------------------------------------------
// cli_win_conflict_check(x0=current val, x1=other A val, x2=other B val)
//   noreturn on conflict.
// ----------------------------------------------------------------------------
    .p2align 2
cli_win_conflict_check:
    PROLOGUE 5
    mov x19, x0                     // current val
    LEA x20, cli_win_first
    ldr x2, [x20]
    cbz x2, .Lwc_first
    cmp x2, x19
    b.eq .Lwc_first
    // a different window option is already recorded -> conflict.  The
    // message names the option actually seen FIRST (x2, from cli_win_first),
    // exactly as argparse's mutual-exclusion error does: the sibling that was
    // never seen is irrelevant here (this was the "names x1" bug).
    mov x20, x2                     // the seen val (for the message)
    mov x0, x19
    bl cli_val_canon
    mov x19, x0
    mov x0, x20
    bl cli_val_canon
    mov x1, x0
    mov x0, x19
    bl cli_arg_not_allowed
.Lwc_first:
    LEA x2, cli_win_first
    str x19, [x2]
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_val_canon(x0=val) -> x0 = canonical option string
// ----------------------------------------------------------------------------
    .p2align 2
cli_val_canon:
    cmp x0, #1
    b.lt .Lvc_none
    cmp x0, #VAL_MAX
    b.gt .Lvc_none
    LEA x1, cli_val_table
    mov x2, #VT_REC_SZ
    mul x0, x0, x2
    add x0, x1, x0
    ldr x0, [x0, #VT_CANON]
    ret
.Lvc_none:
    LEA x0, s_unknown_opt
    ret

// ----------------------------------------------------------------------------
// cli_arg_not_allowed — "argument X: not allowed with argument Y", exit 2.
// ----------------------------------------------------------------------------
    .p2align 2
cli_arg_not_allowed:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    LEA x0, cli_scratch2
    mov x1, x19
    mov x2, x20
    bl cli_build_not_allowed
    LEA x0, cli_scratch2
    bl cli_arg_error
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_build_not_allowed(x0=dst, x1=X, x2=Y)
// ----------------------------------------------------------------------------
    .p2align 2
cli_build_not_allowed:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, x19
    LEA x1, s_arg_prefix
    bl tc_cat_cstr
    mov x19, x0
    mov x1, x20
    bl tc_cat_cstr
    mov x19, x0
    LEA x1, s_not_allowed
    bl tc_cat_cstr
    mov x19, x0
    mov x1, x21                     // Y
    bl tc_cat_cstr
    mov x19, x0
    mov w1, #0
    strb w1, [x0]
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_append_list(x0=list off, x1=count off, x2=esz, x3=flag, x4=set, x5=value)
// ----------------------------------------------------------------------------
    .p2align 2
cli_append_list:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x5
    LEA x25, tc_opts
    add x0, x25, x20
    ldr x6, [x0]
    cmp x6, #TC_LIST_MAX
    b.ge .Lal_done
    add x0, x25, x19
    mul x7, x6, x21
    add x0, x0, x7
    mov x1, x24
    mov x2, x21
    bl tc_copy_str_cap
    add x0, x25, x20
    ldr x6, [x0]
    add x6, x6, #1
    str x6, [x0]
    mov x0, #TC_O_FLAGS
    bl cli_opts_off
    ldr x6, [x0]
    orr x6, x6, x22
    str x6, [x0]
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, x23]               // cli_given[set] = 1 (x23 = set id from x4)
.Lal_done:
    EPILOGUE 5
    ret

// ============================================================================
// cli_handle_typed(x0=val, x1=optarg) — table-driven options.
// ============================================================================
    .p2align 2
cli_handle_typed:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    LEA x21, cli_val_table
    mov x22, #VT_REC_SZ
    mul x22, x19, x22
    add x21, x21, x22
    ldr x23, [x21, #VT_SET]
    LEA x0, cli_given
    mov x1, #1
    strb w1, [x0, x23]
    ldr x1, [x21, #VT_FLAGS]
    cbz x1, .Lht_flags_done
    mov x0, x1
    bl cli_set_flag
.Lht_flags_done:
    ldr w24, [x21, #VT_PARSER]
    cbz w24, .Lht_string
    mov x0, x24
    mov x1, x20
    bl cli_parse_for_store
    cbnz x1, .Lht_bad
    ldr x25, [x21, #VT_STORE]
    cmp w24, #P_METRICS
    b.eq .Lht_metrics
    cmp w24, #P_HEX
    b.eq .Lht_hex
    LEA x1, tc_opts
    str x0, [x1, x25]
    b .Lht_done
.Lht_hex:
    LEA x1, tc_opts
    add x1, x1, x25
    lsr x2, x0, #16
    and x2, x2, #0xFF
    str w2, [x1]
    lsr x2, x0, #8
    and x2, x2, #0xFF
    str w2, [x1, #4]
    and x2, x0, #0xFF
    str w2, [x1, #8]
    add x2, x25, #24
    add x0, x1, x2
    mov x1, x20
    mov x2, #16
    bl tc_copy_str_cap
    b .Lht_done
.Lht_metrics:
    // stage into cli_show_staging (the by-state merge re-lays the final list)
    LEA x1, cli_metrics_tmp_n
    ldr x2, [x1]
    LEA x3, cli_metrics_tmp
    LEA x1, cli_show_staging
    mov x4, #0
.Lht_mc:
    cmp x4, x2
    b.ge .Lht_done
    ldr x5, [x3, x4, lsl #3]
    str x5, [x1, x4, lsl #3]
    add x4, x4, #1
    b .Lht_mc
.Lht_bad:
    // x1 = status, x2 = the offending item (P_METRICS: parse_columns raises
    // on the first unknown name, not the whole list)
    mov x3, x1                      // status
    mov x1, x20                     // display: the raw value ...
    cmp w24, #P_METRICS
    b.ne .Lht_bad_go
    cbz x2, .Lht_bad_go
    mov x1, x2                      // ... or the first unknown column
.Lht_bad_go:
    ldr x0, [x21, #VT_CANON]
    mov x2, x24                     // parser
    // x1 = display, x2 = parser, x3 = status
    bl cli_emit_typed_err
.Lht_string:
    ldr x25, [x21, #VT_STORE]
    ldr x2, [x21, #VT_CAP]
    LEA x0, tc_opts
    add x0, x0, x25
    mov x1, x20
    bl tc_copy_str_cap
.Lht_done:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_parse_for_store(x0=parser, x1=raw) -> (x0=value, x1=status, x2=extra)
//   Dispatch to the parser for `parser`; every branch falls through to the
//   single shared exit at .Lpfs_ret (no per-branch epilogue pairs).
// ----------------------------------------------------------------------------
    .p2align 2
cli_parse_for_store:
    stp x30, xzr, [sp, #-16]!
    cmp x0, #P_POS_INT
    b.eq .Lpfs_pos
    cmp x0, #P_NONNEG_INT
    b.eq .Lpfs_nonneg
    cmp x0, #P_NONNEG_FLOAT
    b.eq .Lpfs_nnf
    cmp x0, #P_POS_FLOAT
    b.eq .Lpfs_pf
    cmp x0, #P_DURATION
    b.eq .Lpfs_dur
    cmp x0, #P_HEADER
    b.eq .Lpfs_header
    cmp x0, #P_SORT
    b.eq .Lpfs_sort
    cmp x0, #P_METRICS
    b.eq .Lpfs_metrics
    cmp x0, #P_USERS_POLICY
    b.eq .Lpfs_policy
    cmp x0, #P_BOOL
    b.eq .Lpfs_bool
    cmp x0, #P_CURVE
    b.eq .Lpfs_curve
    cmp x0, #P_HEX
    b.eq .Lpfs_hex
    cmp x0, #P_CHOICES_COLOR
    b.eq .Lpfs_color
    cmp x0, #P_CHOICES_COMPLETE
    b.eq .Lpfs_complete
    cmp x0, #P_STATE
    b.eq .Lpfs_state
    mov x0, #0
    mov x1, #1
    mov x2, #0
    b .Lpfs_ret
.Lpfs_pos:     mov x0, x1
    bl cli_parse_positive_int
    b .Lpfs_ret
.Lpfs_nonneg:  mov x0, x1
    bl cli_parse_nonnegative_int
    b .Lpfs_ret
.Lpfs_nnf:     mov x0, x1
    bl cli_parse_nonnegative_float
    b .Lpfs_ret
.Lpfs_pf:      mov x0, x1
    bl cli_parse_positive_float
    b .Lpfs_ret
.Lpfs_dur:     mov x0, x1
    bl tc_parse_duration
    b .Lpfs_ret
.Lpfs_header:  mov x0, x1
    bl tc_parse_header
    b .Lpfs_ret
.Lpfs_sort:    mov x0, x1
    bl tc_parse_sort
    b .Lpfs_ret
.Lpfs_metrics: mov x0, x1
    bl tc_parse_metrics
    b .Lpfs_ret
.Lpfs_policy:  mov x0, x1
    bl tc_parse_users_policy
    b .Lpfs_ret
.Lpfs_bool:    mov x0, x1
    bl tc_parse_bool
    b .Lpfs_ret
.Lpfs_curve:   mov x0, x1
    bl tc_parse_curve
    b .Lpfs_ret
.Lpfs_hex:     mov x0, x1
    bl tc_parse_hex_colour
    b .Lpfs_ret
.Lpfs_color:   mov x0, x1
    bl cli_parse_color_choice
    b .Lpfs_ret
.Lpfs_complete: mov x0, x1
    bl cli_parse_complete_choice
    b .Lpfs_ret
.Lpfs_state:   mov x0, x1
    bl tc_parse_state
.Lpfs_ret:
    ldp x30, xzr, [sp], #16
    ret

// ============================================================================
// cli_emit_typed_err(x0=canonical, x1=display, x2=parser, x3=status) — exit 2
// ============================================================================
    .p2align 2
cli_emit_typed_err:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    LEA x0, cli_scratch
    mov x1, x19
    mov x2, x21
    mov x3, x20
    mov x4, x22
    bl cli_build_arg_msg
    LEA x0, cli_scratch
    bl cli_arg_error                // exit 2
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_build_arg_msg(x0=dst, x1=canonical, x2=parser, x3=display, x4=status)
// ----------------------------------------------------------------------------
    .p2align 2
cli_build_arg_msg:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    mov x24, x19
    mov x0, x24
    LEA x1, s_arg_prefix
    bl tc_cat_cstr
    mov x24, x0
    mov x1, x20
    bl tc_cat_cstr
    mov x24, x0
    LEA x1, s_colon_space
    bl tc_cat_cstr
    mov x24, x0
    mov x1, x21
    mov x2, x22
    mov x3, x23
    bl cli_emit_msg_body
    mov w1, #0
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_cat_quoted(x0=cursor, x1=pre, x2=display, x3=suf) -> cursor
//   Appends pre + quote + display + quote + suf to the scratch cursor.
//   Shared by the .Lmb_quote and .Lmb_dt paths of cli_emit_msg_body.
// ----------------------------------------------------------------------------
    .p2align 2
cli_cat_quoted:
    PROLOGUE 2
    mov x19, x0                     // cursor
    mov x20, x2                     // display
    mov x21, x3                     // suf
    mov x0, x19
    bl tc_cat_cstr                  // pre
    mov x19, x0
    LEA x1, s_q
    bl tc_cat_cstr
    mov x19, x0
    mov x1, x20
    bl tc_cat_cstr                  // display
    mov x19, x0
    LEA x1, s_q
    bl tc_cat_cstr
    mov x19, x0
    mov x1, x21
    bl tc_cat_cstr                  // suf
    mov x19, x0
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cli_emit_msg_body(x0=cursor, x1=parser, x2=display, x3=status) -> cursor
//   Uses the cli_msg_table: {pre, suf, alt}; status 2 uses alt (range msg).
// ----------------------------------------------------------------------------
    .p2align 2
cli_emit_msg_body:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    cmp x20, #P_DATETIME
    b.eq .Lmb_dt
    cmp x20, #P_DATETIME_EOD
    b.eq .Lmb_dt
    // table lookup
    cmp x20, #1
    b.lt .Lmb_fallback
    cmp x20, #18
    b.gt .Lmb_fallback
    LEA x23, cli_msg_table
    mov x24, #24
    mul x24, x20, x24
    add x23, x23, x24
    ldr x25, [x23]                  // pre
    ldr x26, [x23, #8]              // suf
    ldr x27, [x23, #16]             // alt
    cmp x22, #2
    b.ne .Lmb_quote
    cbnz x27, .Lmb_alt
.Lmb_quote:
    mov x0, x19
    mov x1, x25                     // pre
    mov x2, x21                     // display
    mov x3, x26                     // suf
    bl cli_cat_quoted
    mov x19, x0
    b .Lmb_done
.Lmb_alt:
    mov x0, x19
    mov x1, x27
    bl tc_cat_cstr
    mov x19, x0
    b .Lmb_done
.Lmb_dt:
    // datetime status 1: "unrecognized datetime '<display>' (try ...)"
    cmp x22, #3
    b.eq .Lmb_dt_week
    mov x0, x19
    LEA x1, s_dt_unrec_prefix
    mov x2, x21                     // display
    LEA x3, s_dt_unrec_suffix
    bl cli_cat_quoted
    mov x19, x0
    b .Lmb_done
.Lmb_dt_week:
    // status 3: "no week {week} in ISO year {year} (weeks run 1-52, or 1-53
    // in long years)" -- week and year were parked by tc_parse_datetime
    mov x0, x19
    LEA x1, s_week_no_prefix
    bl tc_cat_cstr
    mov x19, x0
    LEA x9, cli_dt_bad_year
    ldr x1, [x9, #8]                // week
    mov x0, x19
    bl tc_fmt_u64
    mov x19, x0
    LEA x1, s_week_in_iso
    bl tc_cat_cstr
    mov x19, x0
    LEA x9, cli_dt_bad_year
    ldr x1, [x9]                    // year
    mov x0, x19
    bl tc_fmt_u64
    mov x19, x0
    LEA x1, s_week_suffix
    bl tc_cat_cstr
    mov x19, x0
    b .Lmb_done
.Lmb_fallback:
    mov x0, x19
    mov x1, x21
    bl tc_cat_cstr
    mov x19, x0
.Lmb_done:
    EPILOGUE 5
    ret

// ============================================================================
// cli_prepass(x0=argc, x1=argv) — cleaned argv + extras.  Exits 2 on errors.
// ============================================================================
    .p2align 2
cli_prepass:
    PROLOGUE 5
    mov x19, x0                     // argc
    mov x20, x1                     // argv
    LEA x0, cli_argc_saved
    str x19, [x0]
    LEA x0, cli_argv_saved
    str x20, [x0]
    mov x21, #1
    mov x22, #0                     // opt_n
    mov x23, #0                     // ext_n
.Lpp_loop:
    cmp x21, x19
    b.ge .Lpp_done
    ldr x24, [x20, x21, lsl #3]
    ldrb w0, [x24]
    cmp w0, #'-'
    b.ne .Lpp_extra
    ldrb w0, [x24, #1]
    cbz w0, .Lpp_extra
    cmp w0, #'-'
    b.eq .Lpp_longish
    mov x0, x24
    mov x1, x21
    bl cli_pp_short
    mov x21, x0
    b .Lpp_loop
.Lpp_longish:
    ldrb w0, [x24, #2]
    cbz w0, .Lpp_endopts
    mov x0, x24
    mov x1, x21
    bl cli_pp_long
    mov x21, x0
    b .Lpp_loop
.Lpp_endopts:
    // Python's argparse keeps the "--" token itself in the extras
    // ('unrecognized arguments: --'), unlike traditional getopt which
    // silently consumes it.  x24 still holds argv[x21] (the "--" token).
    mov x0, x24
    bl cli_pp_extra
    add x24, x21, #1
.Lpp_end_loop:
    cmp x24, x19
    b.ge .Lpp_done
    ldr x0, [x20, x24, lsl #3]
    bl cli_pp_extra
    add x24, x24, #1
    b .Lpp_end_loop
.Lpp_extra:
    mov x0, x24
    bl cli_pp_extra
    add x21, x21, #1
    b .Lpp_loop
.Lpp_done:
    // cli_pp_emit / cli_pp_extra already updated the memory counters; the
    // register copies (x22/x23) are stale, so do NOT store them here.
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_pp_emit(x0=token) — append to the cleaned argv
// ----------------------------------------------------------------------------
    .p2align 2
cli_pp_emit:
    LEA x1, cli_opt_argv
    LEA x2, cli_opt_n
    ldr x3, [x2]
    str x0, [x1, x3, lsl #3]
    add x3, x3, #1
    str x3, [x2]
    ret

// ----------------------------------------------------------------------------
// cli_pp_extra(x0=token) — append to the extras list
// ----------------------------------------------------------------------------
    .p2align 2
cli_pp_extra:
    LEA x1, cli_extras
    LEA x2, cli_extras_n
    ldr x3, [x2]
    str x0, [x1, x3, lsl #3]
    add x3, x3, #1
    str x3, [x2]
    ret

// ----------------------------------------------------------------------------
// cli_pp_slot(x0=index) -> x0 = cli_argstr + index*ARGSTR_SZ
// ----------------------------------------------------------------------------
    .p2align 2
cli_pp_slot:
    LEA x1, cli_argstr
    mov x2, #ARGSTR_SZ
    mul x0, x0, x2
    add x0, x1, x0
    ret

// ----------------------------------------------------------------------------
// cli_opts_off(x0=offset) -> x0 = tc_opts + offset   (offsets may exceed 4095)
// ----------------------------------------------------------------------------
    .p2align 2
cli_opts_off:
    LEA x1, tc_opts
    add x0, x1, x0
    ret

// ============================================================================
// cli_pp_long(x0=token, x1=index) -> x0 = next argv index (may exit 2)
// ============================================================================
    .p2align 2
cli_pp_long:
    PROLOGUE 5
    mov x19, x0                     // token
    mov x20, x1                     // index
    // copy to the scratch slot first (we may modify it)
    mov x0, x20
    bl cli_pp_slot
    mov x21, x0                     // slot
    mov x1, x19
    mov x2, #ARGSTR_SZ
    bl tc_copy_str_cap
    mov x19, x21                    // work on the slot copy
    // split at '='
    mov x22, #0                     // rest ptr (0 = none)
    mov x23, x19
.Lpl_eq:
    ldrb w0, [x23]
    cbz w0, .Lpl_eqdone
    cmp w0, #'='
    b.eq .Lpl_eqfound
    add x23, x23, #1
    b .Lpl_eq
.Lpl_eqfound:
    mov w0, #0
    strb w0, [x23]
    add x22, x23, #1
.Lpl_eqdone:
    // comparison pointer: the token name WITHOUT the leading "--"
    // (getopt's longopts names have no dashes)
    add x23, x19, #2
    // exact match in cli_longopts (x25 is the prefix-match counter; it is
    // re-zeroed below in .Lpl_no_exact)
    LEA x24, cli_longopts
.Lpl_exact:
    ldr x26, [x24]
    cbz x26, .Lpl_no_exact
    mov x0, x23
    mov x1, x26
    bl tc_streq
    cbnz x0, .Lpl_found
    add x24, x24, #LONGOPT_REC_SZ
    b .Lpl_exact
.Lpl_found:
    mov x26, x24
    b .Lpl_have
.Lpl_no_exact:
    // prefix matches
    LEA x24, cli_longopts
    mov x25, #0
    mov x27, #0
.Lpl_pre:
    ldr x28, [x24]
    cbz x28, .Lpl_pre_done
    mov x0, x23
    mov x1, x28
    bl tc_streq
    cbnz x0, .Lpl_pre_next
    mov x0, x23
    mov x1, x28
    bl cli_startswith
    cbz x0, .Lpl_pre_next
    add x25, x25, #1
    mov x27, x24
.Lpl_pre_next:
    add x24, x24, #LONGOPT_REC_SZ
    b .Lpl_pre
.Lpl_pre_done:
    cmp x25, #1
    b.eq .Lpl_one
    cmp x25, #0
    b.eq .Lpl_unknown
    // ambiguous
    LEA x0, cli_scratch
    mov x1, x19
    bl cli_build_ambiguous
    LEA x0, cli_scratch
    bl cli_arg_error
.Lpl_one:
    mov x26, x27
    b .Lpl_have
.Lpl_unknown:
    mov x0, x19
    bl cli_pp_extra
    add x0, x20, #1
    b .Lpl_ret
.Lpl_have:
    // x26 = record; has_arg at +8; name at +0
    ldr w27, [x26, #8]
    ldr x28, [x26]
    cmp w27, #0
    b.eq .Lpl_bool
    // takes a value
    cbnz x22, .Lpl_inline
    // space form: value from the next argv if value-like
    LEA x24, cli_argc_saved
    ldr x24, [x24]
    add x25, x20, #1
    cmp x25, x24
    b.ge .Lpl_no_value
    LEA x24, cli_argv_saved
    ldr x24, [x24]
    ldr x0, [x24, x25, lsl #3]
    bl cli_is_value_token
    cbz x0, .Lpl_no_value
    // value available: rebuild the slot as "fullname=value"
    mov x0, x21
    mov x1, x28
    LEA x24, cli_argv_saved
    ldr x24, [x24]
    ldr x2, [x24, x25, lsl #3]
    bl cli_pp_rewrite_long
    bl cli_pp_emit
    add x0, x20, #2
    b .Lpl_ret
.Lpl_inline:
    // rebuild slot = fullname + "=" + rest
    mov x0, x21
    mov x1, x28
    mov x2, x22
    bl cli_pp_rewrite_long
    bl cli_pp_emit
    add x0, x20, #1
    b .Lpl_ret
.Lpl_bool:
    cbnz x22, .Lpl_bool_explicit
    // rewrite to the full name in the slot
    mov x0, x21
    mov x1, x28
    mov x2, #0
    bl cli_pp_rewrite_long
    bl cli_pp_emit
    add x0, x20, #1
    b .Lpl_ret
.Lpl_bool_explicit:
    LEA x0, cli_scratch2
    ldr x1, [x26, #24]              // val
    mov x2, x22
    bl cli_build_ignored_explicit
    LEA x0, cli_scratch2
    bl cli_arg_error
.Lpl_no_value:
    cmp w27, #1
    b.eq .Lpl_missing
    // optional: no value (from-config); rewrite to the full name
    mov x0, x21
    mov x1, x28
    mov x2, #0
    bl cli_pp_rewrite_long
    bl cli_pp_emit
    add x0, x20, #1
    b .Lpl_ret
.Lpl_missing:
    mov x0, x26
    bl cli_arg_missing_value
.Lpl_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_pp_rewrite_long(x0=slot, x1=name, x2=value_or_0) -> x0 = slot
//   Rebuilds an argv slot as "--name", appending "=value" when value_or_0 is
//   non-zero.  Shared by the four full-name rewrites in cli_pp_long.
// ----------------------------------------------------------------------------
    .p2align 2
cli_pp_rewrite_long:
    PROLOGUE 1
    mov x19, x0                     // slot
    mov x20, x2                     // value (0 = none)
    strb wzr, [x0]
    mov w3, #'-'
    strb w3, [x0]
    strb w3, [x0, #1]
    add x0, x0, #2
    bl tc_cat_cstr                  // append name
    cbz x20, .Lprl_done
    mov w3, #'='
    strb w3, [x0], #1
    mov x1, x20
    bl tc_cat_cstr                  // append value
.Lprl_done:
    mov x0, x19                     // slot
    EPILOGUE 1
    ret

// ----------------------------------------------------------------------------
// cli_startswith(x0=token, x1=long name) -> x0 = 1 when x0 is a PROPER
//   prefix of x1: the token matches the name's start and the name is
//   longer (argparse's abbreviation match).  "propre"/"longer" reads on x1
//   being the option NAME and x0 the possibly-abbreviated TOKEN.
//   in: x0 = the option token (without "--"), x1 = the full long option name
// ============================================================================
    .p2align 2
cli_startswith:
    mov x2, x0
.Lsw:
    ldrb w3, [x2], #1
    ldrb w4, [x1], #1
    cmp w3, w4
    b.ne .Lsw_no
    cbnz w3, .Lsw
    // token exhausted; option name must have more
    ldrb w4, [x1]
    cbnz w4, .Lsw_yes
.Lsw_no:
    mov x0, #0
    ret
.Lsw_yes:
    mov x0, #1
    ret

// ----------------------------------------------------------------------------
// cli_build_ambiguous(x0=dst, x1=optpart)
// ----------------------------------------------------------------------------
    .p2align 2
cli_build_ambiguous:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x19
    mov x0, x21
    LEA x1, s_ambiguous_prefix
    bl tc_cat_cstr
    mov x21, x0
    mov x1, x20
    bl tc_cat_cstr
    mov x21, x0
    LEA x1, s_ambiguous_mid
    bl tc_cat_cstr
    mov x21, x0
    add x23, x20, #2                // token name without the leading "--"
    LEA x24, cli_longopts
    mov x25, #0
.Lba:
    ldr x22, [x24]
    cbz x22, .Lba_done
    mov x0, x23
    mov x1, x22
    bl tc_streq
    cbnz x0, .Lba_next
    mov x0, x23
    mov x1, x22
    bl cli_startswith
    cbz x0, .Lba_next
    cbnz x25, .Lba_comma
    mov x25, #1
    b .Lba_name
.Lba_comma:
    mov w0, #','
    strb w0, [x21], #1
    mov w0, #' '
    strb w0, [x21], #1
.Lba_name:
    mov w0, #'-'
    strb w0, [x21], #1
    mov w0, #'-'
    strb w0, [x21], #1
    mov x0, x21
    mov x1, x22
    bl tc_cat_cstr
    mov x21, x0
.Lba_next:
    add x24, x24, #LONGOPT_REC_SZ
    b .Lba
.Lba_done:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_build_ignored_explicit(x0=dst, x1=val, x2=value) -> cursor
//   Composes "argument <canonical>: ignored explicit argument '<value>" for
//   the bool-with-explicit-value error (shared by long and short options;
//   the caller resolves val from the longopts record or the short map).
// ----------------------------------------------------------------------------
    .p2align 2
cli_build_ignored_explicit:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x19
    mov x0, x22
    LEA x1, s_arg_prefix
    bl tc_cat_cstr
    mov x22, x0
    mov x0, x20
    bl cli_val_canon
    mov x1, x0
    mov x0, x22
    bl tc_cat_cstr
    mov x22, x0
    LEA x1, s_ignored_explicit
    bl tc_cat_cstr
    mov x22, x0
    mov x1, x21
    bl tc_cat_cstr
    mov x22, x0
    LEA x1, s_q
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_arg_missing_value(x0=longopts record) — exit 2
// ----------------------------------------------------------------------------
    .p2align 2
cli_arg_missing_value:
    PROLOGUE 5
    mov x19, x0
    ldr w0, [x19, #24]
    bl cli_val_canon
    mov x1, x0
    LEA x0, cli_scratch
    mov x2, x1
    mov x1, x0
    mov x1, x2
    LEA x2, s_expected_one
    bl cli_build_simple_arg_msg
    LEA x0, cli_scratch
    bl cli_arg_error
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_build_simple_arg_msg(x0=dst, x1=canonical, x2=msg)
// ----------------------------------------------------------------------------
    .p2align 2
cli_build_simple_arg_msg:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x0, x19
    LEA x1, s_arg_prefix
    bl tc_cat_cstr
    mov x19, x0
    mov x1, x20
    bl tc_cat_cstr
    mov x19, x0
    LEA x1, s_colon_space
    bl tc_cat_cstr
    mov x19, x0
    mov x1, x21                     // suffix
    bl tc_cat_cstr
    mov x19, x0
    mov w1, #0
    strb w1, [x0]
    EPILOGUE 5
    ret

// ============================================================================
// cli_pp_short(x0=token, x1=index) -> x0 = next argv index (may exit 2)
// ============================================================================
    .p2align 2
cli_pp_short:
    PROLOGUE 5
    mov x19, x0                     // token
    mov x20, x1                     // index
    mov x21, x19                    // scan base
    mov x22, #1                     // position
.Lps_loop:
    ldrb w0, [x21, x22]
    cbz w0, .Lps_all_bool
    bl cli_short_lookup              // x0 = val or 0
    cbz x0, .Lps_unknown
    mov x23, x0                     // val
    LEA x24, cli_val_table
    mov x25, #VT_REC_SZ
    mul x25, x23, x25
    add x24, x24, x25
    ldr w25, [x24, #VT_HAS_ARG]
    cbnz w25, .Lps_value
    // boolean: check '=' right after
    add x26, x21, x22
    add x26, x26, #1
    ldrb w0, [x26]
    cmp w0, #'='
    b.eq .Lps_bool_explicit
    add x22, x22, #1
    b .Lps_loop
.Lps_bool_explicit:
    add x26, x26, #1
    LEA x0, cli_scratch2
    mov x1, x23
    mov x2, x26
    bl cli_build_ignored_explicit
    LEA x0, cli_scratch2
    bl cli_arg_error
.Lps_unknown:
    // remainder "-<rest>" is unrecognized
    mov x0, x20
    bl cli_pp_slot
    mov x26, x0                     // slot base
    mov x27, x26                    // cursor
    mov w1, #'-'
    strb w1, [x27], #1
    add x2, x21, x22
.Lps_unknown_copy:
    ldrb w3, [x2], #1
    strb w3, [x27], #1
    cbnz w3, .Lps_unknown_copy
    mov x0, x26
    bl cli_pp_extra
    add x0, x20, #1
    b .Lps_ret
.Lps_value:
    // value-taking char at position p
    add x26, x21, x22
    add x26, x26, #1
    ldrb w0, [x26]
    cbz w0, .Lps_no_attached
    cmp w0, #'='
    b.eq .Lps_eq_attached
    // attached (cluster rest is the value): token as-is
    mov x0, x19
    bl cli_pp_emit
    add x0, x20, #1
    b .Lps_ret
.Lps_eq_attached:
    add x26, x26, #1
    ldrb w0, [x26]
    cbz w0, .Lps_eq_empty
    // "=value": build merged token without the '='
    mov x0, x20
    bl cli_pp_slot
    mov x27, x0
    mov x1, x21
    add x2, x22, #1
    bl tc_copy_bytes                    // tok[0..p] (p+1 chars)
    mov x0, x27
    add x0, x0, x22
    add x0, x0, #1
    mov x1, x26
    bl tc_cat_cstr
    mov x0, x27
    bl cli_pp_emit
    add x0, x20, #1
    b .Lps_ret
.Lps_eq_empty:
    // "-x=" with an EMPTY explicit value: Python keeps it as channel/value
    // "".  A merged token of just "-x" is indistinguishable from a bare
    // "-x" to getopt_long (it would go hunting the NEXT argv for a value),
    // so route through the long-option spelling instead: "--name=" is
    // real getopt_long syntax for an explicit (possibly empty) value.
    mov x0, x23
    mov x1, x20
    bl cli_pp_build_long_val
    add x0, x20, #1
    b .Lps_ret
.Lps_no_attached:
    // value from the next argv if value-like
    LEA x26, cli_argc_saved
    ldr x26, [x26]
    add x27, x20, #1
    cmp x27, x26
    b.ge .Lps_missing
    LEA x26, cli_argv_saved
    ldr x26, [x26]
    ldr x28, [x26, x27, lsl #3]     // next argv token
    mov x0, x28
    bl cli_is_value_token
    cbz x0, .Lps_missing
    ldrb w0, [x28]
    cbz w0, .Lps_no_attached_empty  // "-c \"\"": empty separate argument
    // value available: merge tok[0..p] + value into the slot
    mov x0, x20
    bl cli_pp_slot
    mov x26, x0                     // slot base
    mov x1, x21
    add x2, x22, #1
    bl tc_copy_bytes                    // tok[0..p] -> slot
    mov x0, x26
    add x0, x0, x22
    add x0, x0, #1
    mov x1, x28
    bl tc_cat_cstr
    mov x0, x26
    bl cli_pp_emit
    add x0, x20, #2
    b .Lps_ret
.Lps_no_attached_empty:
    mov x0, x23
    mov x1, x20
    bl cli_pp_build_long_val
    add x0, x20, #2
    b .Lps_ret
.Lps_missing:
    ldr w25, [x24, #VT_HAS_ARG]
    cmp w25, #2
    b.eq .Lps_optional_noval
    // required: missing value
    ldr x0, [x24, #VT_CANON]
    mov x1, x0
    LEA x0, cli_scratch
    LEA x2, s_expected_one
    bl cli_build_simple_arg_msg
    LEA x0, cli_scratch
    bl cli_arg_error
.Lps_optional_noval:
    // "-w" no value: emit tok[0..p]
    mov x0, x20
    bl cli_pp_slot
    mov x27, x0                     // slot base
    mov x1, x21
    add x2, x22, #1
    bl tc_copy_bytes                    // tok[0..p] -> slot
    add x28, x27, x22
    mov w0, #0
    strb w0, [x28, #1]              // NUL after the option char
    mov x0, x27
    bl cli_pp_emit
    add x0, x20, #1
    b .Lps_ret
.Lps_all_bool:
    mov x0, x19
    bl cli_pp_emit
    add x0, x20, #1
    b .Lps_ret
.Lps_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_pp_build_long_val(x0=short val, x1=index) — writes "--<name>=" into
// the scratch slot for `index` and emits it.  Used to spell an explicit,
// possibly-empty value ("-c=", "-c \"\"") through getopt_long's native
// "--long=value" syntax, since a bare merged "-c" token is indistinguishable
// from "no value attached" and would make getopt_long consume another argv.
// ----------------------------------------------------------------------------
    .p2align 2
cli_pp_build_long_val:
    PROLOGUE 2
    mov w19, w0                     // short val
    mov x20, x1                     // index
    mov x0, x20
    bl cli_pp_slot
    mov x21, x0                     // slot
    LEA x0, cli_longopts
.Lpbv_scan:
    ldr x1, [x0]
    cbz x1, .Lpbv_use_fallback
    ldr w2, [x0, #24]
    cmp w2, w19
    b.eq .Lpbv_found
    add x0, x0, #LONGOPT_REC_SZ
    b .Lpbv_scan
.Lpbv_found:
    mov x22, x1
    b .Lpbv_build
.Lpbv_use_fallback:
    // No longopt record carries this short val.  This is an internal
    // invariant violation (every value-taking short option has a long form),
    // not a user error: the old code emitted "--=" and let cli_handle_opt
    // dereference NULL, so fail fast with a descriptive message instead.
    LEA x0, s_pp_no_long
    b tc_report_fail
.Lpbv_build:
    strb wzr, [x21]
    mov w2, #'-'
    strb w2, [x21]
    strb w2, [x21, #1]
    add x0, x21, #2
    mov x1, x22
    bl tc_cat_cstr
    mov w2, #'='
    strb w2, [x0]
    add x0, x0, #1
    strb wzr, [x0]
.Lpbv_done:
    mov x0, x21
    bl cli_pp_emit
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cli_short_lookup(x0=char) -> x0 = val or 0
// ----------------------------------------------------------------------------
    .p2align 2
cli_short_lookup:
    LEA x1, cli_short_pairs
.Lsl:
    ldrb w2, [x1]
    cbz w2, .Lsl_none
    cmp w0, w2
    b.eq .Lsl_found
    add x1, x1, #2
    b .Lsl
.Lsl_found:
    ldrb w0, [x1, #1]
    ret
.Lsl_none:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// cli_is_value_token(x0=s) -> x0 = 1 when a following option may consume it.
//   Non-destructive mirror of argparse's _parse_optional(s) is None.
// ============================================================================
    .p2align 2
cli_is_value_token:
    // leaf (no bl): save only the pair actually used; no x29/x30 frame.
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    ldrb w0, [x19]
    cbz w0, .Liv_yes
    cmp w0, #'-'
    b.ne .Liv_yes
    ldrb w0, [x19, #1]
    cbz w0, .Liv_yes
    // negative number?  s[1] digit or (s[1]=='.' and s[2] digit)
    ldrb w0, [x19, #1]
    cmp w0, #'0'
    b.lt .Liv_neg2
    cmp w0, #'9'
    b.le .Liv_yes
.Liv_neg2:
    cmp w0, #'.'
    b.ne .Liv_no
    ldrb w1, [x19, #2]
    cmp w1, #'0'
    b.lt .Liv_no
    cmp w1, #'9'
    b.le .Liv_yes
.Liv_no:
    mov x0, #0
    b .Liv_ret
.Liv_yes:
    mov x0, #1
.Liv_ret:
    ldp x19, x20, [sp], #16
    ret

cli_resolve_settings:
    PROLOGUE 5
    mov x19, #0
.Lrs:
    cmp x19, #TC_SET_COUNT
    b.ge .Lrs_done
    cmp x19, #TC_SET_BEGIN
    b.eq .Lrs_next
    cmp x19, #TC_SET_SINCE
    b.eq .Lrs_next
    cmp x19, #TC_SET_USERS
    b.eq .Lrs_next
    cmp x19, #TC_SET_EXCLUDE
    b.eq .Lrs_next
    cmp x19, #TC_SET_EXCLUDE_GROUP
    b.eq .Lrs_next
    cmp x19, #TC_SET_INCLUDE
    b.eq .Lrs_next
    cmp x19, #TC_SET_CONFIG
    b.eq .Lrs_config
    cmp x19, #TC_SET_COLOR
    b.eq .Lrs_color
    cmp x19, #TC_SET_STATE
    b.eq .Lrs_state
    cmp x19, #TC_SET_INTERVAL
    b.eq .Lrs_interval
    cmp x19, #TC_SET_STREAMER_MODE
    b.eq .Lrs_streamer
    cmp x19, #TC_SET_EXCLUDE_BCAST
    b.eq .Lrs_bcast
    cmp x19, #TC_SET_HIGHLIGHT
    b.eq .Lrs_highlights
    cmp x19, #TC_SET_LOGS_DIR
    b.eq .Lrs_logs_dir
    mov x0, x19
    bl cli_resolve_one
    b .Lrs_next
.Lrs_logs_dir:
    // logs_dir: CLI/env/config take the generic path.  Only when nothing
    // set it (source still TC_SRC_DEFAULT after resolution) does the
    // platform supply its built-in default (already expanded); on a
    // platform with no default (Linux) the value stays empty and the
    // source stays TC_SRC_DEFAULT, matching Python's None.
    mov x0, x19
    bl cli_resolve_one
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_SRC + TC_SET_LOGS_DIR*8]
    cmp x1, #TC_SRC_DEFAULT
    b.ne .Lrs_next
    LEA_OFF x0, tc_opts, TC_O_LOGS_DIR
    mov x1, #TC_O_LOGS_DIR_SZ
    bl tc_platform_default_logs_dir
    cbz x0, .Lrs_next
    LEA x1, tc_opts
    mov x2, #TC_SRC_DEFAULT_BUILTIN
    str x2, [x1, #TC_O_SRC + TC_SET_LOGS_DIR*8]
    b .Lrs_next
.Lrs_config:
    // config path
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_CONFIG]
    cbz w1, .Lrs_config_default
    LEA x1, tc_opts
    mov x2, #TC_SRC_CLI_CONFIG
    str x2, [x1, #TC_O_SRC + TC_SET_CONFIG*8]
    b .Lrs_next
.Lrs_config_default:
    LEA_OFF x1, tc_opts, TC_O_CONFIG_PATH
    LEA x0, s_default_config_path
.Lcfg_inline:
    ldrb w2, [x0], #1
    strb w2, [x1], #1
    cbnz w2, .Lcfg_inline
    LEA x1, tc_opts
    mov x2, #TC_SRC_DEFAULT
    str x2, [x1, #TC_O_SRC + TC_SET_CONFIG*8]
    b .Lrs_next
.Lrs_color:
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_COLOR]
    cbnz w1, .Lrs_color_cli
    LEA x0, tc_opts
    mov x1, #TC_SRC_DEFAULT
    str x1, [x0, #TC_O_SRC + TC_SET_COLOR*8]
    mov x1, #TC_COLOR_AUTO
    str x1, [x0, #TC_O_COLOR_MODE]
    b .Lrs_next
.Lrs_color_cli:
    LEA x0, tc_opts
    mov x1, #TC_SRC_CLI_COLOR
    str x1, [x0, #TC_O_SRC + TC_SET_COLOR*8]
    b .Lrs_next
.Lrs_state:
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_STATE]
    cbz w1, .Lrs_state_generic
    LEA x0, cli_state
    ldr x1, [x0]
    cmp x1, #TC_ST_LIVE
    b.eq .Lrs_state_live
    cmp x1, #TC_ST_OFFLINE
    b.eq .Lrs_state_offline
    mov x2, #TC_SRC_CLI_UNKNOWN
    b .Lrs_state_store
.Lrs_state_live:
    mov x2, #TC_SRC_CLI_LIVE
    b .Lrs_state_store
.Lrs_state_offline:
    mov x2, #TC_SRC_CLI_OFFLINE
.Lrs_state_store:
    LEA x0, tc_opts
    str x2, [x0, #TC_O_SRC + TC_SET_STATE*8]
    b .Lrs_next
.Lrs_state_generic:
    mov x0, x19
    bl cli_resolve_one
    b .Lrs_next
.Lrs_interval:
    // CLI numeric value?
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_WATCH_VALUE
    b.eq .Lrs_interval_generic
    mov x1, #TC_SRC_CLI_WATCH
    str x1, [x0, #TC_O_SRC + TC_SET_INTERVAL*8]
    b .Lrs_next
.Lrs_interval_generic:
    LEA x0, cli_given
    strb wzr, [x0, #TC_SET_INTERVAL]    // ignore the from-config sentinel
    mov x0, x19
    bl cli_resolve_one
    b .Lrs_next
.Lrs_streamer:
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_STREAMER_MODE]
    cbz w1, .Lrs_streamer_generic
    LEA x0, tc_opts
    mov x1, #1
    str x1, [x0, #TC_O_STREAMER_MODE]
    mov x1, #TC_SRC_CLI_STREAMER
    str x1, [x0, #TC_O_SRC + TC_SET_STREAMER_MODE*8]
    b .Lrs_next
.Lrs_streamer_generic:
    mov x0, x19
    bl cli_resolve_one
    b .Lrs_next
.Lrs_bcast:
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_EXCLUDE_BCAST]
    cbz w1, .Lrs_bcast_generic
    LEA x0, tc_opts
    mov x1, #1
    str x1, [x0, #TC_O_EXCL_BCAST_VAL]
    mov x1, #TC_SRC_CLI_EXCLUDE_BCAST
    str x1, [x0, #TC_O_SRC + TC_SET_EXCLUDE_BCAST*8]
    b .Lrs_next
.Lrs_bcast_generic:
    mov x0, x19
    bl cli_resolve_one
    b .Lrs_next
.Lrs_highlights:
    // [[watch.highlight]] — parsed here (cli_resolve_highlights fills
    // TC_O_HL_COUNT / TC_O_HL_ARR; Python resolve_settings + parse_highlights)
    bl cli_resolve_highlights
    b .Lrs_next
.Lrs_next:
    add x19, x19, #1
    b .Lrs
.Lrs_done:
    // exclusion/inclusion provenance
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_EXCLUDE]
    LEA x2, tc_opts
    cbz w1, .Lrs_excl_none
    mov x1, #TC_SRC_CLI_EXCLUDE
    str x1, [x2, #TC_O_SRC + TC_SET_EXCLUDE*8]
    b .Lrs_excl_done
.Lrs_excl_none:
    str xzr, [x2, #TC_O_SRC + TC_SET_EXCLUDE*8]
.Lrs_excl_done:
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_INCLUDE]
    LEA x2, tc_opts
    cbz w1, .Lrs_inc_none
    mov x1, #TC_SRC_CLI_INCLUDE
    str x1, [x2, #TC_O_SRC + TC_SET_INCLUDE*8]
    b .Lrs_inc_done
.Lrs_inc_none:
    str xzr, [x2, #TC_O_SRC + TC_SET_INCLUDE*8]
.Lrs_inc_done:
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_EXCLUDE_GROUP]
    LEA x2, tc_opts
    cbz w1, .Lrs_eg_none
    mov x1, #TC_SRC_CLI_EXCLUDE_GROUP
    str x1, [x2, #TC_O_SRC + TC_SET_EXCLUDE_GROUP*8]
    b .Lrs_eg_done
.Lrs_eg_none:
    str xzr, [x2, #TC_O_SRC + TC_SET_EXCLUDE_GROUP*8]
.Lrs_eg_done:
    EPILOGUE 5
    ret

// ============================================================================
// cli_resolve_one(x0=set id) — CLI -> env -> config -> default.
// ============================================================================
    .p2align 2
cli_resolve_one:
    PROLOGUE 5
    mov x19, x0
    LEA x20, cli_spec_table
    mov x21, #SP_REC_SZ
    mul x21, x19, x21
    add x20, x20, x21
    // CLI?
    LEA x0, cli_given
    ldrb w1, [x0, x19]
    cbz w1, .Lro_env
    ldr x1, [x20, #SP_CLI_SRC]
    mov x0, x19
    bl cli_store_src
    b .Lro_done
.Lro_env:
    ldr x21, [x20, #SP_ENV]
    cbz x21, .Lro_cfg
    mov x0, x21
    bl tc_env_get
    cbz x0, .Lro_cfg
    mov x0, x19
    mov x1, x1                      // value
    ldr x2, [x20, #SP_ENV_SRC]
    bl cli_store_from_raw
    b .Lro_done
.Lro_cfg:
    ldr x21, [x20, #SP_KEY]
    cbz x21, .Lro_default
    ldr x22, [x20, #SP_SECTION]
    cbz x22, .Lro_cfg_ok
    cmp x22, #TC_SEC_WATCH
    b.ne .Lro_cfg_ok
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_WATCH_PRESENT
    b.ne .Lro_cfg_ok
    // [watch] is inactive: Python resolve() still consults the top level
    // (resolve_settings passes section=None when not watching), so try the
    // top-level table instead of skipping config entirely.
    mov x22, #TC_SEC_NONE
.Lro_cfg_ok:
    mov x0, x21
    mov x1, x22
    bl tc_config_get
    cbz x0, .Lro_default
    mov x0, x19
    mov x1, x1                      // value
    mov x2, x2                      // source id
    bl cli_store_from_raw
    b .Lro_done
.Lro_default:
    ldr x21, [x20, #SP_DEFAULT]
    ldr x22, [x20, #SP_DEF_SRC]
    // header default_when
    cmp x19, #TC_SET_HEADER
    b.ne .Lro_default_go
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_WATCH_PRESENT
    b.eq .Lro_default_go
    LEA x21, s_default_compact
    mov x22, #TC_SRC_DEFAULT_UNDER_WATCH
.Lro_default_go:
    cbz x21, .Lro_default_none
    mov x0, x19
    mov x1, x21
    mov x2, x22
    bl cli_store_from_raw
    b .Lro_done
.Lro_default_none:
    mov x0, x19
    mov x1, x22
    bl cli_store_src
.Lro_done:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_store_src(x0=set id, x1=src)
// ----------------------------------------------------------------------------
    .p2align 2
cli_store_src:
    LEA x2, tc_opts
    mov x3, #TC_O_SRC
    add x2, x2, x3
    mov x3, #8
    mul x0, x0, x3
    str x1, [x2, x0]
    ret

// ----------------------------------------------------------------------------
// cli_store_from_raw(x0=set, x1=raw, x2=src) — convert + store; exit 1 on err
// ----------------------------------------------------------------------------
    .p2align 2
cli_store_from_raw:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    LEA x22, cli_spec_table
    mov x23, #SP_REC_SZ
    mul x23, x19, x23
    add x22, x22, x23
    mov x0, x19
    mov x1, x21
    bl cli_store_src
    ldr w23, [x22, #SP_PARSER]
    cbz w23, .Lsfr_string
    mov x0, x23
    mov x1, x20
    bl cli_parse_for_store
    cbz x1, .Lsfr_store
    // conversion error: x1 = status, x2 = the offending item (P_METRICS)
    mov x4, x1                      // status (before x1 is reused below)
    mov x3, x20                     // display: the raw value ...
    cmp w23, #P_METRICS
    b.ne .Lsfr_err_go
    cbz x2, .Lsfr_err_go
    mov x3, x2                      // ... or the first unknown column
.Lsfr_err_go:
    ldr x0, [x22, #SP_FLAG]
    mov x1, x21
    mov x2, x23
    bl cli_resolve_err
.Lsfr_store:
    cmp w23, #P_METRICS
    b.eq .Lsfr_metrics
    cmp w23, #P_HEX
    b.eq .Lsfr_hex
    ldr x24, [x22, #SP_VALUE_OFF]
    LEA x1, tc_opts
    str x0, [x1, x24]
    b .Lsfr_done
.Lsfr_hex:
    ldr x24, [x22, #SP_VALUE_OFF]
    LEA x1, tc_opts
    add x1, x1, x24
    lsr x2, x0, #16
    and x2, x2, #0xFF
    str w2, [x1]
    lsr x2, x0, #8
    and x2, x2, #0xFF
    str w2, [x1, #4]
    and x2, x0, #0xFF
    str w2, [x1, #8]
    ldr x25, [x22, #SP_RAW2_OFF]
    LEA x0, tc_opts
    add x0, x0, x25
    mov x1, x20
    mov x2, #16
    bl tc_copy_str_cap
    b .Lsfr_done
.Lsfr_metrics:
    LEA x1, cli_metrics_tmp_n
    ldr x2, [x1]
    LEA x3, cli_metrics_tmp
    LEA x1, cli_show_staging
    mov x4, #0
.Lsfr_mc:
    cmp x4, x2
    b.ge .Lsfr_done
    ldr x5, [x3, x4, lsl #3]
    str x5, [x1, x4, lsl #3]
    add x4, x4, #1
    b .Lsfr_mc
.Lsfr_string:
    ldr x24, [x22, #SP_VALUE_OFF]
    ldr x25, [x22, #SP_VALUE_SZ]
    LEA x0, tc_opts
    add x0, x0, x24
    mov x1, x20
    mov x2, x25
    bl tc_copy_str_cap
.Lsfr_done:
    EPILOGUE 5
    ret

// ============================================================================
// cli_resolve_err — "error: <flag> (from <src>): <msg>", exit 1.
//   x0=flag, x1=src id, x2=parser, x3=display, x4=status
// ============================================================================
    .p2align 2
cli_resolve_err:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x23, x4
    // parse_datetime() quotes str(text).strip(), parse_duration() quotes
    // str(text).strip().lower(): normalise the display the same way (into
    // its own buffer: cli_scratch is where the message is built)
    cmp x21, #P_DATETIME
    b.eq .Lre_norm
    cmp x21, #P_DATETIME_EOD
    b.eq .Lre_norm
    cmp x21, #P_DURATION
    b.ne .Lre_norm_done
.Lre_norm:
    LEA x0, cli_err_display
    mov x1, x22
    bl cli_strip_copy
    mov x22, x0
    cmp x21, #P_DURATION
    b.ne .Lre_norm_done
    mov x0, x22
    bl cli_lowercase
.Lre_norm_done:
    LEA x0, cli_scratch
    mov x24, x0
    mov x1, x19
    bl tc_cat_cstr
    mov x24, x0
    // source_label(): "<flag> (from <src>)" only when the source is not the
    // flag itself (a value given on the command line reads "--since: ...")
    mov x0, x20
    bl tc_source_str
    mov x25, x0
    mov x26, x1
    mov x0, x19
    mov x1, x25
    bl tc_streq
    cbz w0, .Lre_from
    mov x0, x24
    LEA x1, s_colon_space
    bl tc_cat_cstr
    mov x24, x0
    b .Lre_body
.Lre_from:
    mov x0, x24
    LEA x1, s_from_prefix
    bl tc_cat_cstr
    mov x24, x0
    mov x1, x25
    mov x2, x26
    bl tc_copy_bytes
    add x24, x24, x26
    mov x0, x24
    LEA x1, s_from_suffix
    bl tc_cat_cstr
    mov x24, x0
.Lre_body:
    mov x0, x24
    mov x1, x21
    mov x2, x22
    mov x3, x23
    bl cli_emit_msg_body
    mov w1, #0
    strb w1, [x0]
    LEA x0, cli_scratch
    bl tc_report_fail

// ============================================================================
// cli_resolve_window — fill tc_window.
// ============================================================================
    .p2align 2
cli_resolve_window:
    PROLOGUE 5
    // ---- end ---------------------------------------------------------------
    LEA x19, tc_opts
    ldrb w0, [x19, #TC_O_END_RAW]
    cbz w0, .Lrw_end_default
    add x0, x19, #TC_O_END_RAW
    mov x1, #1
    bl tc_parse_datetime
    cbz x2, .Lrw_end_ok
    mov x4, x2                      // status (before x2 is reused below)
    // end conversion error
    ldr x1, [x19, #TC_O_SRC + TC_SET_END*8]
    LEA x0, s_flag_end
    mov x2, #P_DATETIME_EOD
    add x3, x19, #TC_O_END_RAW       // the raw end string (display)
    bl cli_resolve_err
.Lrw_end_ok:
    LEA x19, tc_window
    str x0, [x19, #TC_W_END_YMD]
    str x1, [x19, #TC_W_END_SOD]
    b .Lrw_start
.Lrw_end_default:
    bl cli_now
    LEA x19, tc_window
    str x0, [x19, #TC_W_END_YMD]
    str x1, [x19, #TC_W_END_SOD]
    LEA x19, tc_opts
    mov x0, #TC_SRC_DEFAULT_NOW
    str x0, [x19, #TC_O_SRC + TC_SET_END*8]
.Lrw_start:
    // ---- window start ------------------------------------------------------
    LEA x0, cli_given
    ldrb w1, [x0, #TC_SET_USERS]
    cbnz w1, .Lrw_users
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_BEGIN_GIVEN
    b.ne .Lrw_cli_begin
    tst x1, #TC_F_SINCE_GIVEN
    b.ne .Lrw_cli_since
    b .Lrw_env
.Lrw_cli_begin:
    mov x0, #TC_SRC_CLI_BEGIN
    LEA_OFF x1, tc_opts, TC_O_BEGIN_RAW
    mov x2, #TC_WIN_BEGIN
    bl cli_win_set
    b .Lrw_convert
.Lrw_cli_since:
    mov x0, #TC_SRC_CLI_SINCE
    LEA_OFF x1, tc_opts, TC_O_SINCE_RAW
    mov x2, #TC_WIN_SINCE
    bl cli_win_set
    b .Lrw_convert
.Lrw_env:
    // .Lrw_env / .Lrw_cfg are intentionally near-duplicated: they differ in
    // the getter (tc_env_get vs tc_config_get — different arg counts), the
    // source ids, the mutex strings, and their fall-through targets.  A
    // shared helper would need a function pointer (a pattern this file
    // otherwise avoids) for a net-zero line saving, so the duplication is
    // kept explicit.
    LEA x0, s_env_begin
    bl tc_env_get
    mov x21, x0
    mov x22, x1
    LEA x0, s_env_since
    bl tc_env_get
    mov x23, x0
    mov x24, x1
    cbnz x21, .Lrw_env_begin_ok
    cbnz x23, .Lrw_env_since_ok
    b .Lrw_cfg
.Lrw_env_begin_ok:
    cbnz x23, .Lrw_env_both
    mov x0, #TC_SRC_ENV_BEGIN
    mov x1, x22
    mov x2, #TC_WIN_BEGIN
    bl cli_win_set
    b .Lrw_convert
.Lrw_env_since_ok:
    mov x0, #TC_SRC_ENV_SINCE
    mov x1, x24
    mov x2, #TC_WIN_SINCE
    bl cli_win_set
    b .Lrw_convert
.Lrw_env_both:
    LEA x0, s_mutex_env_begin
    bl tc_report_fail
.Lrw_cfg:
    LEA x0, s_key_begin
    mov x1, #TC_SEC_NONE
    bl tc_config_get
    mov x21, x0
    mov x22, x1
    LEA x0, s_key_since
    mov x1, #TC_SEC_NONE
    bl tc_config_get
    mov x23, x0
    mov x24, x1
    cbnz x21, .Lrw_cfg_begin_ok
    cbnz x23, .Lrw_cfg_since_ok
    b .Lrw_earliest
.Lrw_cfg_begin_ok:
    cbnz x23, .Lrw_cfg_both
    mov x0, #TC_SRC_CONFIG_BEGIN
    mov x1, x22
    mov x2, #TC_WIN_BEGIN
    bl cli_win_set
    b .Lrw_convert
.Lrw_cfg_since_ok:
    mov x0, #TC_SRC_CONFIG_SINCE
    mov x1, x24
    mov x2, #TC_WIN_SINCE
    bl cli_win_set
    b .Lrw_convert
.Lrw_cfg_both:
    LEA x0, s_mutex_cfg_begin
    bl tc_report_fail
.Lrw_earliest:
    LEA x19, tc_window
    mov x0, #TC_WIN_EARLIEST
    str x0, [x19, #TC_W_KIND]
    mov x0, #TC_SRC_DEFAULT_EARLIEST
    bl tc_source_str
    LEA x1, tc_window
    str x0, [x1, #TC_W_START_SRC]
    b .Lrw_common
.Lrw_users:
    LEA x19, tc_window
    mov x0, #TC_WIN_USERS
    str x0, [x19, #TC_W_KIND]
    mov x0, #1
    str x0, [x19, #TC_W_BEGIN_ROLLS]
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_USERS]
    str x1, [x19, #TC_W_USERS_REQ]
    // begin placeholder = end
    ldr x2, [x19, #TC_W_END_YMD]
    ldr x3, [x19, #TC_W_END_SOD]
    str x2, [x19, #TC_W_BEGIN_YMD]
    str x3, [x19, #TC_W_BEGIN_SOD]
    // compose "--users N" into TC_O_WIN_SRC
    mov x0, #TC_O_WIN_SRC
    bl cli_opts_off
    LEA x1, s_users_prefix
    bl tc_cat_cstr
    mov x24, x0
    LEA x0, tc_opts
    ldr x1, [x0, #TC_O_USERS]
    mov x0, x24
    bl tc_fmt_u64
    mov x0, #TC_O_WIN_SRC
    bl cli_opts_off
    LEA x1, tc_window
    str x0, [x1, #TC_W_START_SRC]
    b .Lrw_common
.Lrw_convert:
    LEA x19, cli_win_kind
    ldr x20, [x19]
    LEA x19, cli_win_raw
    ldr x21, [x19]
    LEA x19, cli_win_src
    ldr x22, [x19]
    cmp x20, #TC_WIN_SINCE
    b.eq .Lrw_since
    // begin
    mov x0, x21
    mov x1, #0
    bl tc_parse_datetime
    cbz x2, .Lrw_begin_ok
    mov x4, x2                      // status (before x2 is reused below)
    LEA x0, s_flag_begin
    mov x1, x22
    mov x2, #P_DATETIME
    mov x3, x21                     // the raw begin string (display)
    bl cli_resolve_err
.Lrw_begin_ok:
    LEA x19, tc_window
    str x0, [x19, #TC_W_BEGIN_YMD]
    str x1, [x19, #TC_W_BEGIN_SOD]
    mov x0, x22
    bl tc_source_str
    LEA x1, tc_window
    str x0, [x1, #TC_W_START_SRC]
    b .Lrw_check
.Lrw_since:
    mov x0, x21
    bl tc_parse_duration
    cbz x1, .Lrw_since_ok
    mov x4, x1                      // status (before x1 is reused below)
    LEA x0, s_flag_since
    mov x1, x22
    mov x2, #P_DURATION
    mov x3, x21                     // the raw since string (display)
    bl cli_resolve_err
.Lrw_since_ok:
    mov x25, x0                     // delta seconds (from tc_parse_duration)
    // begin = end - delta
    LEA x19, tc_window
    ldr x23, [x19, #TC_W_END_YMD]
    ldr x24, [x19, #TC_W_END_SOD]
    mov x0, x23
    mov x1, x24
    bl tc_ymd_sod_to_epoch
    sub x25, x0, x25                // begin epoch
    // --since pre-year-1 underflow: Python's datetime cannot represent a
    // year < 1 (OverflowError: date value out of range).  The old code
    // passed the negative epoch to tc_epoch_to_ymd_sod and rendered
    // garbage; fail loudly here instead.  The boundary is the epoch of
    // 0001-01-01 (tc_ymd_sod_to_epoch(10101) = -62135596800); a negative
    // epoch that still maps to year >= 1 (e.g. 1969-03-23 for --since
    // 21000d) is valid and must render like Python.
    ldr x26, =YEAR1_EPOCH           // -62135596800
    cmp x25, x26
    b.ge .Lrw_since_in_range
    LEA x0, cli_scratch
    mov x26, x0
    LEA x1, s_flag_since
    bl tc_cat_cstr
    mov x26, x0
    LEA x1, s_colon_space
    bl tc_cat_cstr
    mov x26, x0
    LEA x1, s_date_out_of_range
    bl tc_cat_cstr
    mov w1, #0
    strb w1, [x0]
    LEA x0, cli_scratch
    bl tc_report_fail
.Lrw_since_in_range:
    mov x0, x25
    bl tc_epoch_to_ymd_sod
    LEA x19, tc_window
    str x0, [x19, #TC_W_BEGIN_YMD]
    str x1, [x19, #TC_W_BEGIN_SOD]
    mov x0, #1
    str x0, [x19, #TC_W_BEGIN_ROLLS]
    // compose "<src> <raw> before end"
    mov x0, #TC_O_WIN_SRC
    bl cli_opts_off
    mov x24, x0
    mov x0, x22
    bl tc_source_str
    mov x25, x1
    mov x26, x0
    mov x0, x24
    mov x1, x26
    mov x2, x25
    bl tc_copy_bytes
    add x24, x24, x25
    mov w0, #' '
    strb w0, [x24], #1
    mov x0, x24
    mov x1, x21
    bl tc_cat_cstr
    mov x24, x0
    LEA x1, s_before_end
    bl tc_cat_cstr
    mov x0, #TC_O_WIN_SRC
    bl cli_opts_off
    LEA x1, tc_window
    str x0, [x1, #TC_W_START_SRC]
    b .Lrw_check
.Lrw_check:
    LEA x0, cli_scratch
    bl tc_win_begin_after_end_check  // fails with "begin (A) is after end (B)"
.Lrw_common:
    LEA x19, tc_opts
    LEA x20, tc_window
    ldr x21, [x19, #TC_O_MIN_COUNT]
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_win_set(x0=src id, x1=raw ptr, x2=kind) — stash the window-start choice
// ----------------------------------------------------------------------------
    .p2align 2
cli_win_set:
    LEA x3, cli_win_kind
    str x2, [x3]
    LEA x3, cli_win_raw
    str x1, [x3]
    LEA x3, cli_win_src
    str x0, [x3]
    ret

// ============================================================================
// cli_choose_columns — merge by-state + --show into TC_O_COLUMNS.
// ============================================================================
    .p2align 2
cli_choose_columns:
    PROLOGUE 5
    LEA x19, tc_opts
    // final = by-state base
    ldr x0, [x19, #TC_O_FLAGS]
    tst x0, #TC_F_BY_STATE
    b.eq .Lcc_show
    mov x20, #TC_M_LIVE
    str x20, [x19, #TC_O_COLUMNS + 0]
    mov x20, #TC_M_OFFLINE
    str x20, [x19, #TC_O_COLUMNS + 8]
    mov x20, #TC_M_OFFLINE_SHARE
    str x20, [x19, #TC_O_COLUMNS + 16]
    mov x21, #3                     // final count
    b .Lcc_append
.Lcc_show:
    mov x21, #0
.Lcc_append:
    // append staged show columns (dedupe)
    // The final columns array lives at TC_O_COLUMNS (offset 1400), NOT at the
    // base of tc_opts: indexing tc_opts + x*8 would corrupt TC_O_CHANNEL and
    // every field below 1400.  x28 is the columns base for both the dedupe
    // read and the append store.
    add x28, x19, #TC_O_COLUMNS
    LEA x22, cli_show_staging
    LEA x23, cli_metrics_tmp_n
    ldr x23, [x23]                  // staged count
    mov x24, #0
.Lcc_loop:
    cmp x24, x23
    b.ge .Lcc_src
    ldr x25, [x22, x24, lsl #3]
    // dedupe against final
    mov x26, #0
.Lcc_dedupe:
    cmp x26, x21
    b.ge .Lcc_add
    ldr x27, [x28, x26, lsl #3]     // dedupe against the real columns array
    cmp x27, x25
    b.eq .Lcc_next
    add x26, x26, #1
    b .Lcc_dedupe
.Lcc_add:
    cmp x21, #6
    b.ge .Lcc_next
    str x25, [x28, x21, lsl #3]     // append into TC_O_COLUMNS (not tc_opts+0)
    add x21, x21, #1
.Lcc_next:
    add x24, x24, #1
    b .Lcc_loop
.Lcc_src:
    // store the final count
    str x21, [x19, #TC_O_COLUMN_COUNT]
    // ---- source composition ------------------------------------------------
    ldr x22, [x19, #TC_O_SRC + TC_SET_SHOW*8]
    ldr x0, [x19, #TC_O_FLAGS]
    tst x0, #TC_F_BY_STATE
    b.eq .Lcc_src_show_only
    cmp x22, #TC_SRC_DEFAULT
    b.eq .Lcc_src_by_state_only
    // both
    mov x0, #TC_O_COLUMNS_SRC_BUF
    bl cli_opts_off
    mov x23, x0
    LEA x1, s_by_state_label
    bl tc_cat_cstr
    mov x23, x0
    LEA x1, s_comma_space
    bl tc_cat_cstr
    mov x23, x0
    mov x0, x22
    bl tc_source_str
    mov x24, x1
    mov x25, x0
    mov x0, x23
    mov x1, x25
    mov x2, x24
    bl tc_copy_bytes
    add x23, x23, x24
    mov w0, #0
    strb w0, [x23]
    b .Lcc_src_store
.Lcc_src_by_state_only:
    mov x0, #TC_O_COLUMNS_SRC_BUF
    bl cli_opts_off
    mov x23, x0
    LEA x1, s_by_state_label
    bl tc_cat_cstr
    b .Lcc_src_store
.Lcc_src_show_only:
    cmp x22, #TC_SRC_DEFAULT
    b.eq .Lcc_src_none
    mov x0, x22
    bl tc_source_str
    mov x24, x1
    mov x25, x0
    mov x0, #TC_O_COLUMNS_SRC_BUF
    bl cli_opts_off
    mov x23, x0
    mov x1, x25
    mov x2, x24
    bl tc_copy_bytes
    b .Lcc_src_store
.Lcc_src_none:
    mov x0, #TC_O_COLUMNS_SRC_PTR
    bl cli_opts_off
    str xzr, [x0]
    b .Lcc_done
.Lcc_src_store:
    // x20 is dead at this point, so it carries the buffer address across the
    // second cli_opts_off (which clobbers x1, the register the naive
    // mov x1, x0 / str x1, [x0] sequence would otherwise corrupt).
    mov x0, #TC_O_COLUMNS_SRC_BUF
    bl cli_opts_off
    mov x20, x0
    mov x0, #TC_O_COLUMNS_SRC_PTR
    bl cli_opts_off
    str x20, [x0]
.Lcc_done:
    EPILOGUE 5
    ret

// ============================================================================
// cli_resolve_highlights — fill TC_O_HL_COUNT / TC_O_HL_ARR from the config's
//   [[watch.highlight]] rules (Python resolve_settings + parse_highlights).
//
//   tc_config_get cannot return array-of-tables (toml_raw_in only
//   sees kvals), so this function re-reads the config TOML directly via
//   tomlc99, the pattern tc_misc.S established; the entry points are .weak so
//   the no-toml test driver (tc-cli-test) still links, and this path is only
//   entered when TC_O_CONFIG_LOADED is set (the stub never sets it).
//
//   Errors reproduce Python's parse_highlights text byte-for-byte, composed
//   as "watch.highlight (from <src>): <msg>" + exit 1:
//     "must be a list of tables"
//     "rule {i}: expected a table with `color` and `match`"
//     "rule {i}: needs both `color` and `match`"
//     "rule {i}: `match` needs at least one pattern"
//     "rule {i}: {pattern!r} is not a valid regex ({exc})"
//     "rule {i}: unknown fade curve '{name}' (choose from: ...)"
//     "rule {i}: '{text}' is not a number" / "must be greater than 0"
//     "rule {i}: '{text}' is not a hex colour like '#0000ff'"
//
//   Documented deviations (the layout caps):
//     * TC_HL_MAX (32) rules / TC_HL_PAT_MAX (64) patterns per rule are the
//       fixed caps; beyond them the config fails with a new message
//       ("too many highlight rules (max 32)" / "rule {i}: too many patterns
//       (max 64)") and patterns longer than 255 bytes fail with "rule {i}:
//       pattern too long (max 63 characters)".  Python has no such limits.
//     * Pattern validation uses pcre2, so the ({exc}) text is pcre2's message
//       ("missing closing parenthesis") rather than Python re's
//       ("unterminated subpattern at position 0").
//     * `color` accepts the Python forms this port's parsers cover: #rgb /
//       #rrggbb strings and 3-int arrays.  A non-string colour that is not a
//       3-int array fails with a fixed message instead of Python's repr text.
//     * Non-string pattern elements inside a `match` array use tomlc99's raw
//       text; Python str() coerces them (identical for ints and floats,
//       differs for booleans: raw "true" vs str(True)="True").
// ============================================================================
    .equ TC_HL_ERRBUF_SZ, 128

    .bss
    .p2align 3
cli_hl_errbuf:   .skip TC_HL_ERRBUF_SZ  // toml_parse_file error buffer
    .global tc_hl_patterns
tc_hl_patterns: .skip TC_HL_MAX * TC_HL_PAT_MAX * TC_HL_PAT_SZ  // rule i, pattern j: (i*TC_HL_PAT_MAX + j)*TC_HL_PAT_SZ
cli_hl_dst:      .skip 8                // toml_rtos result slot (char *)
cli_hl_errcode:  .skip 8                // pcre2_compile_8 error code
cli_hl_erroff:   .skip 8                // pcre2_compile_8 error offset
cli_hl_pat_free: .skip 8                // 0/1 free the current pattern string

    .text
    .p2align 2
cli_resolve_highlights:
    PROLOGUE 5
    LEA x19, tc_opts
    str xzr, [x19, #TC_O_HL_COUNT]    // default: no rules
    // ---- env TWITCH_WATCH_HIGHLIGHT ---------------------------------------
    // A string env value is never a list, so any non-empty value reproduces
    // Python's "must be a list of tables" (empty env is treated as unset by
    // tc_env_get, exactly like Python's `os.environ.get(n) not in (None, "")`).
    LEA x0, s_env_watch_highlight
    bl tc_env_get
    cbz x0, .Lrh_cfg
    mov x0, #TC_SRC_ENV_WATCH_HIGHLIGHT
    LEA x1, s_hl_must_be_list
    bl cli_hl_err                        // noreturn
.Lrh_cfg:
    ldr x1, [x19, #TC_O_CONFIG_LOADED]
    cbz x1, .Lrh_default
    // ---- source: [watch] when watching, else top level ---------------------
    mov x20, #TC_SRC_CONFIG
    mov x22, #0                         // 0 = search root only
    ldr x1, [x19, #TC_O_FLAGS]
    tst x1, #TC_F_WATCH_PRESENT
    b.eq .Lrh_open
    mov x20, #TC_SRC_CONFIG_WATCH
    mov x22, #1                         // 1 = search [watch] first
.Lrh_open:
    // direct tomlc99 re-parse of the resolved config path
    add x0, x19, #TC_O_CONFIG_PATH
    LEA x1, s_mode_r
    bl fopen
    cbz x0, .Lrh_default
    mov x27, x0                         // FILE*
    LEA x0, cli_hl_errbuf
    mov w1, #0
    strb w1, [x0]                       // clear the parse error buffer
    mov x1, x0
    mov w2, #TC_HL_ERRBUF_SZ
    mov x0, x27
    bl toml_parse_file
    mov x21, x0                         // root table (0 on parse failure)
    mov x0, x27
    bl fclose
    cbz x21, .Lrh_default
    // ---- find the "highlight" key: [watch] table, then top level ----------
    cbz x22, .Lrh_search_root
    mov x0, x21
    LEA x1, s_key_watch
    bl toml_table_in
    cbz x0, .Lrh_search_root
    mov x22, x0                         // [watch] table
    LEA x1, s_key_highlight
    bl toml_array_in
    cbnz x0, .Lrh_have_array
    mov x0, x22
    LEA x1, s_key_highlight
    bl toml_key_exists
    cbnz x0, .Lrh_not_array
.Lrh_search_root:
    mov x20, #TC_SRC_CONFIG             // top-level source
    mov x0, x21
    LEA x1, s_key_highlight
    bl toml_array_in
    cbnz x0, .Lrh_have_array
    mov x0, x21
    LEA x1, s_key_highlight
    bl toml_key_exists
    cbz x0, .Lrh_default_free           // absent -> built-in default
.Lrh_not_array:
    // the key exists but is a string/number/table: not a list/tuple
    mov x0, x20
    LEA x1, s_hl_must_be_list
    bl cli_hl_err                        // noreturn
.Lrh_have_array:
    mov x23, x0                         // the highlight array
    bl toml_array_nelem
    cbz x0, .Lrh_store_done             // [] -> 0 rules (source still recorded)
    cmp x0, #TC_HL_MAX
    b.gt .Lrh_too_many_rules
    mov x26, x0                         // rule count
    mov x0, x23
    bl toml_array_kind
    cmp w0, #'t'
    b.ne .Lrh_expected_table
    // ---- per-rule loop ------------------------------------------------------
    mov x24, #0                         // rule index
.Lrh_rule:
    cmp x24, x26
    b.ge .Lrh_store_done
    mov x0, x23
    mov x1, x24
    bl toml_table_at
    // the rule's slot in the contract array
    LEA_OFF x2, tc_opts, TC_O_HL_ARR
    mov x3, #TC_HL_RULE_SZ
    madd x2, x24, x3, x2
    mov x1, x24                         // rule index
    mov x3, x20                         // source id
    bl cli_hl_parse_rule                // exits on any error
    add x24, x24, #1
    b .Lrh_rule
.Lrh_store_done:
    str x20, [x19, #TC_O_SRC + TC_SET_HIGHLIGHT*8]
    str x26, [x19, #TC_O_HL_COUNT]
    mov x0, x21                         // free the toml root (x21), like
    bl toml_free                        // .Lrh_default_free — the happy
    b .Lrh_ret                          // path leaked it (C16)
.Lrh_default_free:
    mov x0, x21
    bl toml_free
.Lrh_default:
    mov x0, #TC_SRC_DEFAULT_BUILTIN
    str x0, [x19, #TC_O_SRC + TC_SET_HIGHLIGHT*8]
    str xzr, [x19, #TC_O_HL_COUNT]
.Lrh_ret:
    EPILOGUE 5
    ret

// ---- per-rule error exits ---------------------------------------------------
.Lrh_too_many_rules:
    mov x0, x20
    LEA x1, s_hl_too_many_rules
    bl cli_hl_err                        // noreturn
.Lrh_expected_table:
    mov x0, x20
    mov x1, #0
    LEA x2, s_hl_expected_table
    bl cli_hl_err_rule                   // noreturn

// ============================================================================
// cli_hl_parse_rule(x0=rule table, x1=rule index, x2=slot, x3=source id) --
//   one [[watch.highlight]] entry: `match` (a string or an array of
//   patterns, each copied into tc_hl_patterns and compile-checked with
//   pcre2), `color` (a hex string or a 3-int array) and the optional
//   `curve` / `k`, written into the rule's TC_HL_* slot.  Every failure
//   prints the exact Python parse_highlights text and exits (never returns).
// ============================================================================
    .p2align 2
cli_hl_parse_rule:
    PROLOGUE 5
    sub sp, sp, #16                     // [sp] = the rule table (x25 doubles
                                        // as the pattern text in the loop)
    mov x25, x0                         // the rule table
    mov x24, x1                         // rule index
    mov x28, x2                         // the rule's slot in the contract array
    mov x20, x3                         // source id (for the error texts)
    str x25, [sp]
    // ---- presence: needs both `color` and `match` --------------------------
    mov x0, x25
    LEA x1, s_key_color
    bl toml_key_exists
    cbz x0, .Lrh_needs_both
    mov x0, x25
    LEA x1, s_key_match
    bl toml_key_exists
    cbz x0, .Lrh_needs_both
    // ---- `match`: an array of patterns, or a single string -----------------
    mov x0, x25
    LEA x1, s_key_match
    bl toml_array_in
    cbnz x0, .Lrh_match_array
    mov x0, x25
    LEA x1, s_key_match
    bl toml_raw_in
    cbz x0, .Lrh_need_pattern           // a table match, or absent
    ldrb w1, [x0]
    cmp w1, #'"'
    b.eq .Lrh_match_str
    cmp w1, #'\''
    b.eq .Lrh_match_str
    b .Lrh_need_pattern                 // bare number/bool: not a string
.Lrh_match_str:
    // single pattern: unquote via toml_rtos
    LEA x0, cli_hl_dst
    mov x22, x0                         // &dst
    mov x0, x25
    LEA x1, s_key_match
    bl toml_raw_in
    mov x1, x22
    bl toml_rtos
    cbnz x0, .Lrh_need_pattern
    ldr x25, [x22]                      // malloc'd unquoted pattern
    mov x21, #0                         // pattern index 0
    mov x27, #1                         // pattern count 1
    mov x22, #0                         // no match array (single string)
    LEA x0, cli_hl_pat_free
    mov x1, #1
    str x1, [x0]                        // the unquoted string is malloc'd
    b .Lrh_pat_copy
.Lrh_match_array:
    mov x22, x0                         // the match array
    bl toml_array_nelem
    mov x27, x0                         // pattern count
    cbz x27, .Lrh_need_pattern          // [] -> Python "needs at least one"
    cmp x27, #TC_HL_PAT_MAX
    b.gt .Lrh_too_many_pats
    mov x21, #0                         // pattern index
.Lrh_pat:
    cmp x21, x27
    b.ge .Lrh_pat_done
    mov x0, x22
    mov x1, x21
    bl toml_string_at                   // x0 = ok, x1 = u.s (malloc'd)
    cbz w0, .Lrh_pat_raw
    mov x25, x1                         // malloc'd string
    mov x0, #1
    LEA x1, cli_hl_pat_free
    str x0, [x1]
    b .Lrh_pat_copy
.Lrh_pat_raw:
    mov x0, x22
    mov x1, x21
    bl toml_raw_at                      // x0 = raw text (into the parsed tree)
    mov x25, x0
    LEA x0, cli_hl_pat_free
    str xzr, [x0]
.Lrh_pat_copy:
    // x25 = pattern text, x27 = pattern count, x21 = pattern index
    // pattern slot address (x26 is dead here, and survives the calls below)
    LEA x26, tc_hl_patterns
    mov x10, #TC_HL_PAT_MAX
    mul x10, x24, x10                   // rule index (x24)
    add x10, x10, x21                   // + pattern index (x21)
    mov x11, #TC_HL_PAT_SZ
    mul x10, x10, x11
    add x26, x26, x10                   // pattern slot
    mov x0, x25
    bl tc_strlen
    cmp x0, #(TC_HL_PAT_SZ - 1)
    b.gt .Lrh_pat_long
    mov x2, x0                          // len
    mov x0, x26
    mov x1, x25
    bl tc_copy_bytes                    // x0 = slot + len (the returned cursor)
    strb wzr, [x0]                      // NUL-terminate the slot
    // compile-validate from the slot (the slot is the contract text)
    mov x0, x26
    bl tc_strlen
    mov x1, x0
    mov x0, x26
    ldr w2, =PCRE2_OPTS                 // Python re: Unicode \w \s \d, case folding
    LEA x3, cli_hl_errcode
    LEA x4, cli_hl_erroff
    mov x5, #0
    bl pcre2_compile_8
    cbz x0, .Lrh_bad_regex
    bl pcre2_code_free_8                // validation only; tc_watch.S recompiles
    LEA x0, cli_hl_pat_free
    ldr x0, [x0]
    cbz x0, .Lrh_pat_next
    mov x0, x25
    bl free
.Lrh_pat_next:
    add x21, x21, #1
    b .Lrh_pat
.Lrh_pat_done:
    str x27, [x28, #TC_HL_PAT_COUNT]
    b .Lrh_color
    // ---- colour -------------------------------------------------------------
.Lrh_color:
    ldr x25, [sp]                       // restore the rule table (x25 was the
                                        // pattern text during the pattern loop)
    mov x0, x25
    LEA x1, s_key_color
    bl toml_raw_in
    cbnz x0, .Lrh_color_raw
    // not a kval: the 3-int tuple form Python's parse_hex_colour accepts
    mov x0, x25
    LEA x1, s_key_color
    bl toml_array_in
    cbz x0, .Lrh_color_bad
    mov x22, x0                         // colour array
    bl toml_array_nelem
    cmp x0, #3
    b.ne .Lrh_color_bad
    mov x0, x22
    mov x1, #0
    bl toml_int_at
    cbz w0, .Lrh_color_bad
    str w1, [x28, #TC_HL_RGB]
    mov x0, x22
    mov x1, #1
    bl toml_int_at
    cbz w0, .Lrh_color_bad
    str w1, [x28, #TC_HL_RGB + 4]
    mov x0, x22
    mov x1, #2
    bl toml_int_at
    cbz w0, .Lrh_color_bad
    str w1, [x28, #TC_HL_RGB + 8]
    b .Lrh_curve
.Lrh_color_raw:
    mov x21, x0                         // raw colour text
    ldrb w1, [x21]
    cmp w1, #'"'
    b.eq .Lrh_color_unquote
    cmp w1, #'\''
    b.eq .Lrh_color_unquote
    mov x0, x21
    bl tc_parse_hex_colour
    cbnz x1, .Lrh_color_fail_plain
    b .Lrh_color_store
.Lrh_color_unquote:
    LEA x0, cli_hl_dst
    mov x22, x0                         // &dst
    mov x0, x21
    mov x1, x22
    bl toml_rtos
    cbnz x0, .Lrh_color_fail_plain
    ldr x0, [x22]
    bl tc_parse_hex_colour
    cbnz x1, .Lrh_color_fail_unq
    mov x21, x0                         // rgb (survives free)
    ldr x0, [x22]
    bl free
    mov x0, x21
.Lrh_color_store:
    lsr x2, x0, #16
    and x2, x2, #0xFF
    str w2, [x28, #TC_HL_RGB]
    lsr x2, x0, #8
    and x2, x2, #0xFF
    str w2, [x28, #TC_HL_RGB + 4]
    and x2, x0, #0xFF
    str w2, [x28, #TC_HL_RGB + 8]
    b .Lrh_curve
    // ---- curve / k -----------------------------------------------------------
.Lrh_curve:
    mov x0, x25
    LEA x1, s_key_curve
    bl toml_raw_in
    cbz x0, .Lrh_curve_none
    mov x21, x0
    ldrb w1, [x21]
    cmp w1, #'"'
    b.eq .Lrh_curve_unquote
    cmp w1, #'\''
    b.eq .Lrh_curve_unquote
    mov x0, x21
    bl tc_parse_curve
    cbnz x1, .Lrh_curve_fail_plain
    b .Lrh_curve_store
.Lrh_curve_unquote:
    LEA x0, cli_hl_dst
    mov x22, x0
    mov x0, x21
    mov x1, x22
    bl toml_rtos
    cbnz x0, .Lrh_curve_none
    ldr x0, [x22]
    bl tc_parse_curve
    cbnz x1, .Lrh_curve_fail_unq
    mov x21, x0
    ldr x0, [x22]
    bl free
    mov x0, x21
.Lrh_curve_store:
    str x0, [x28, #TC_HL_CURVE]
    b .Lrh_k
.Lrh_curve_none:
    mov x0, #-1
    str x0, [x28, #TC_HL_CURVE]
    b .Lrh_k
.Lrh_k:
    mov x0, x25
    LEA x1, s_key_k
    bl toml_raw_in
    cbz x0, .Lrh_k_none
    mov x21, x0
    ldrb w1, [x21]
    cmp w1, #'"'
    b.eq .Lrh_k_unquote
    cmp w1, #'\''
    b.eq .Lrh_k_unquote
    mov x0, x21
    bl cli_parse_positive_float
    cbz x1, .Lrh_k_store_plain
    mov x23, x1                         // status 1/2 (error path: x23 expendable)
    b .Lrh_k_fail_plain
.Lrh_k_unquote:
    LEA x0, cli_hl_dst
    mov x22, x0
    mov x0, x21
    mov x1, x22
    bl toml_rtos
    cbnz x0, .Lrh_k_none
    ldr x0, [x22]
    bl cli_parse_positive_float
    cbz x1, .Lrh_k_store_unq
    mov x23, x1                         // status 1/2 (error path)
    b .Lrh_k_fail_unq
.Lrh_k_store_plain:
    str x0, [x28, #TC_HL_K]
    b .Lrh_k_done
.Lrh_k_store_unq:
    mov x21, x0                         // bits (survives free)
    ldr x0, [x22]
    bl free
    str x21, [x28, #TC_HL_K]
    b .Lrh_k_done
.Lrh_k_none:
    LEA x0, cli_hl_dbl_neg1
    ldr x0, [x0]
    str x0, [x28, #TC_HL_K]             // -1.0 = inherit
.Lrh_k_done:
    add sp, sp, #16
    EPILOGUE 5
    ret

// ---- per-rule error exits (all noreturn) ------------------------------------
.Lrh_needs_both:
    mov x0, x20
    mov x1, x24
    LEA x2, s_hl_needs_both
    bl cli_hl_err_rule                   // noreturn
.Lrh_need_pattern:
    mov x0, x20
    mov x1, x24
    LEA x2, s_hl_need_pattern
    bl cli_hl_err_rule                   // noreturn
.Lrh_too_many_pats:
    mov x0, x20
    mov x1, x24
    LEA x2, s_hl_too_many_pats
    bl cli_hl_err_rule                   // noreturn
.Lrh_pat_long:
    mov x0, x20
    mov x1, x24
    LEA x2, s_hl_pat_long
    bl cli_hl_err_rule                   // noreturn
.Lrh_bad_regex:
    // "rule {i}: '{pat}' is not a valid regex ({pcre2 msg})"
    mov x0, x20
    bl cli_hl_begin
    mov x26, x0                         // cursor (error path: x26 is expendable)
    mov x1, x24
    bl cli_hl_rule
    mov x26, x0
    LEA x1, s_q
    bl tc_cat_cstr
    mov x26, x0
    mov x1, x25                         // the offending pattern text
    bl tc_cat_cstr
    mov x26, x0
    LEA x1, s_hl_bad_regex_mid
    bl tc_cat_cstr
    mov x26, x0
    LEA x0, cli_hl_errcode
    ldr w0, [x0]
    LEA x1, cli_scratch2
    mov x2, #SCRATCH_SZ
    bl pcre2_get_error_message_8
    mov x0, x26
    LEA x1, cli_scratch2
    bl tc_cat_cstr
    mov x26, x0
    LEA x1, s_hl_bad_regex_post
    bl tc_cat_cstr
    mov x26, x0
    bl cli_hl_finish                     // noreturn
.Lrh_color_bad:
    // colour is a table or a malformed array: fixed message (deviation text)
    mov x0, x20
    mov x1, x24
    LEA x2, s_hl_color_bad
    bl cli_hl_err_rule                   // noreturn
.Lrh_color_fail_plain:
    mov x0, x20
    bl cli_hl_begin
    mov x26, x0
    mov x1, x24
    bl cli_hl_rule
    mov x26, x0
    mov x1, #P_HEX
    mov x2, x21                         // display = raw colour text
    mov x3, #1
    bl cli_emit_msg_body
    mov x26, x0
    bl cli_hl_finish                     // noreturn
.Lrh_color_fail_unq:
    mov x0, x20
    bl cli_hl_begin
    mov x26, x0
    mov x1, x24
    bl cli_hl_rule
    mov x26, x0
    mov x1, #P_HEX
    LEA x2, cli_hl_dst
    ldr x2, [x2]                        // display = unquoted colour
    mov x3, #1
    bl cli_emit_msg_body
    mov x26, x0
    bl cli_hl_finish                     // noreturn
.Lrh_curve_fail_plain:
.Lrh_curve_fail_unq:
    // tc_parse_curve normalizes into cli_scratch2; that is Python's {name!r}
    mov x0, x20
    bl cli_hl_begin
    mov x26, x0
    mov x1, x24
    bl cli_hl_rule
    mov x26, x0
    mov x1, #P_CURVE
    LEA x2, cli_scratch2
    mov x3, #1
    bl cli_emit_msg_body
    mov x26, x0
    bl cli_hl_finish                     // noreturn
.Lrh_k_fail_plain:
    mov x0, x20
    bl cli_hl_begin
    mov x26, x0
    mov x1, x24
    bl cli_hl_rule
    mov x26, x0
    mov x1, #P_POS_FLOAT
    mov x2, x21                         // display = raw k text
    mov x3, x23                         // status 1 or 2
    bl cli_emit_msg_body
    mov x26, x0
    bl cli_hl_finish                     // noreturn
.Lrh_k_fail_unq:
    mov x0, x20
    bl cli_hl_begin
    mov x26, x0
    mov x1, x24
    bl cli_hl_rule
    mov x26, x0
    mov x1, #P_POS_FLOAT
    LEA x2, cli_hl_dst
    ldr x2, [x2]                        // display = unquoted k text
    mov x3, x23                         // status 1 or 2
    bl cli_emit_msg_body
    mov x26, x0
    bl cli_hl_finish                     // noreturn

// ============================================================================
// Highlight error composition helpers
// ============================================================================
    .p2align 2
cli_hl_begin:
    PROLOGUE 2
    mov x19, x0                         // source id
    LEA x0, cli_scratch
    mov x20, x0
    LEA x1, s_flag_highlight
    bl tc_cat_cstr
    mov x20, x0
    LEA x1, s_from_prefix
    bl tc_cat_cstr
    mov x20, x0
    mov x0, x19
    bl tc_source_str                    // x0 = ptr, x1 = len
    mov x21, x0
    mov x22, x1
    mov x0, x20
    mov x1, x21
    mov x2, x22
    bl tc_copy_bytes
    add x20, x20, x22
    mov x0, x20
    LEA x1, s_from_suffix
    bl tc_cat_cstr
    EPILOGUE 2
    ret

    .p2align 2
cli_hl_rule:
    PROLOGUE 2
    mov x19, x0                         // cursor
    mov x20, x1                         // rule index
    mov x0, x19
    LEA x1, s_hl_rule_pre
    bl tc_cat_cstr
    mov x19, x0
    mov x1, x20
    bl tc_fmt_u64                    // appends digits, returns the END cursor
    mov x19, x0
    LEA x1, s_hl_rule_mid
    bl tc_cat_cstr
    EPILOGUE 2
    ret

    .p2align 2
cli_hl_finish:
    mov w1, #0
    strb w1, [x0]
    LEA x0, cli_scratch
    b tc_report_fail                     // noreturn tail call

    .p2align 2
cli_hl_err:
    PROLOGUE 1
    mov x19, x0                         // source id
    mov x20, x1                         // message
    mov x0, x19
    bl cli_hl_begin
    mov x19, x0
    mov x1, x20
    bl tc_cat_cstr
    mov x19, x0
    bl cli_hl_finish                     // noreturn

    .p2align 2
cli_hl_err_rule:
    PROLOGUE 2
    mov x19, x0                         // source id
    mov x20, x1                         // rule index
    mov x21, x2                         // message
    mov x0, x19
    bl cli_hl_begin
    mov x19, x0
    mov x1, x20
    bl cli_hl_rule
    mov x19, x0
    mov x1, x21
    bl tc_cat_cstr
    mov x19, x0
    bl cli_hl_finish                     // noreturn

// ============================================================================
// cli_now() -> x0=ymd, x1=sod (local time)
// ============================================================================
    .p2align 2
cli_now:
    PROLOGUE 5
    mov x0, #CLOCK_REALTIME
    LEA x1, cli_ts_buf
    bl clock_gettime
    LEA x19, cli_ts_buf
    mov x0, x19
    LEA x1, cli_tm_buf
    bl localtime_r
    LEA x19, cli_tm_buf
    ldr w20, [x19, #20]
    add x20, x20, #TM_YEAR_BASE
    ldr w21, [x19, #16]
    add x21, x21, #1
    ldr w22, [x19, #12]
    mov x23, #YMD_YEAR_SCALE
    mul x20, x20, x23
    mov x23, #YMD_MONTH_SCALE
    mul x21, x21, x23
    add x20, x20, x21
    add x20, x20, x22
    ldr w21, [x19, #8]
    mov x23, #SECS_PER_HOUR
    mul x21, x21, x23
    ldr w22, [x19, #4]
    mov x23, #60
    madd x21, x22, x23, x21
    ldr w22, [x19, #0]
    add x21, x21, x22
    mov x0, x20                     // ymd
    mov x1, x21                     // sod
    EPILOGUE 5
    ret

// ============================================================================
// Civil math specific to the CLI (the shared calendar helpers live in
// tc_util.S: tc_days_from_civil, tc_civil_from_days, tc_days_in_month, ...)
// ============================================================================

// cli_weekday(x0=days) -> x0 = 1..7 (Monday=1)
    .p2align 2
cli_weekday:
    add x0, x0, #3
    mov x1, #7
    udiv x2, x0, x1
    msub x0, x2, x1, x0
    add x0, x0, #1
    ret

// cli_iso_week_monday(x0=y, x1=w) -> x0=ymd (Monday 00:00:00)
    .p2align 2
cli_iso_week_monday:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x0, x19
    mov x1, #1
    mov x2, #1
    bl tc_days_from_civil           // x0 = jan1 days
    mov x21, x0
    bl cli_weekday                   // x0 = dow
    sub x0, x0, #1
    sub x21, x21, x0                // monday of week 1
    sub x0, x20, #1
    mov x2, #7
    mul x0, x0, x2
    add x21, x21, x0                // monday of the requested week
    mov x0, x21
    bl tc_civil_from_days
    mov x3, #YMD_YEAR_SCALE
    mul x0, x0, x3
    mov x3, #YMD_MONTH_SCALE
    mul x1, x1, x3
    add x0, x0, x1
    add x0, x0, x2

    EPILOGUE 5
    ret

// cli_iso_week_count(x0=y) -> x0 = 52 or 53
    .p2align 2
cli_iso_week_count:
    PROLOGUE 5
    mov x19, x0
    mov x1, #1
    mov x2, #1
    bl tc_days_from_civil
    mov x20, x0
    bl cli_weekday
    cmp x0, #4
    b.eq .Liwc_53
    cmp x0, #3
    b.ne .Liwc_52
    mov x0, x19
    bl tc_is_leap
    cbz x0, .Liwc_52
.Liwc_53:
    mov x0, #53
    EPILOGUE 5
    ret
.Liwc_52:
    mov x0, #52
    EPILOGUE 5
    ret

// ============================================================================
// tc_parse_datetime(x0=s, x1=eod) -> (x0=ymd, x1=sod, x2=status,
//   x3=stripped ptr on status 1; x3=year, x4=week on status 3)
// ============================================================================
    .p2align 2
    .global tc_parse_datetime
    FUNC_TYPE(tc_parse_datetime)
tc_parse_datetime:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    LEA x0, cli_scratch
    mov x1, x19
    bl cli_strip_copy
    mov x21, x0                     // stripped ptr
    // ISO week / weekday
    mov x0, x21
    bl cli_match_week                // x0=1; x1=year, x2=week, x3=weekday(0=plain)
    cmp x0, #0
    b.eq .Lpd_formats
    mov x22, x1                     // year
    mov x23, x2                     // week
    mov x24, x3                     // weekday (0 = plain week)
    cbz x23, .Lpd_week_bad          // week 0 is invalid (Python rejects it)
    mov x0, x22
    bl cli_iso_week_count
    cmp x23, x0
    b.gt .Lpd_week_bad
    mov x0, x22
    mov x1, x23
    bl cli_iso_week_monday           // x0 = monday ymd
    mov x25, x0
    cbz x24, .Lpd_plain_week
    // weekday: add (weekday-1) days
    sub x24, x24, #1
    mov x0, x25
    mov x1, #0
    bl tc_ymd_sod_to_epoch
    mov x26, x0
    mov x0, x24
    ldr x1, =SECS_PER_DAY
    mul x0, x0, x1
    add x26, x26, x0
    cbz x20, .Lpd_wd_sod0
    ldr x0, =((23*3600 + 59*60 + 59))
    add x26, x26, x0
.Lpd_wd_sod0:
    mov x0, x26
    bl tc_epoch_to_ymd_sod
    mov x2, #0
    b .Lpd_ret
.Lpd_plain_week:
    mov x0, x25
    mov x1, #0
    bl tc_ymd_sod_to_epoch
    mov x26, x0
    cbz x20, .Lpd_pw_sod0
    ldr x0, =SECS_PER_DAY
    mov x1, #6
    mul x0, x0, x1
    add x26, x26, x0
    ldr x0, =((23*3600 + 59*60 + 59))
    add x26, x26, x0
.Lpd_pw_sod0:
    mov x0, x26
    bl tc_epoch_to_ymd_sod
    mov x2, #0
    b .Lpd_ret
.Lpd_week_bad:
    // status 3: the message wants the rejected week and its year; the
    // resolve-error path only carries (display, status), so park them
    LEA x0, cli_dt_bad_year
    str x22, [x0]
    str x23, [x0, #8]
    mov x0, #0
    mov x1, #0
    mov x2, #3
    mov x3, x22
    mov x4, x23
    b .Lpd_ret
.Lpd_formats:
    mov x0, x21
    bl cli_norm_T
    mov x0, x21
    mov x1, x20
    bl cli_parse_fixed_datetime      // x0=ymd, x1=sod, x2=status
    cmp x2, #0
    b.eq .Lpd_ret
    // fromisoformat subset: YYYYWwwD
    mov x0, x21
    bl cli_match_compact_week        // x0=1; x1=year, x2=week, x3=day
    cmp x0, #0
    b.eq .Lpd_fail
    mov x22, x1
    mov x23, x2
    mov x24, x3
    cbz x23, .Lpd_week_bad          // week 0 is invalid (Python rejects it)
    mov x0, x22
    bl cli_iso_week_count
    cmp x23, x0
    b.gt .Lpd_week_bad
    mov x0, x22
    mov x1, x23
    bl cli_iso_week_monday
    mov x25, x0
    sub x24, x24, #1
    mov x0, x25
    mov x1, #0
    bl tc_ymd_sod_to_epoch
    mov x26, x0
    mov x0, x24
    ldr x1, =SECS_PER_DAY
    mul x0, x0, x1
    add x26, x26, x0
    cbz x20, .Lpd_cw_sod0
    ldr x0, =((23*3600 + 59*60 + 59))
    add x26, x26, x0
.Lpd_cw_sod0:
    mov x0, x26
    bl tc_epoch_to_ymd_sod
    mov x2, #0
    b .Lpd_ret
.Lpd_fail:
    mov x0, #0
    mov x1, #0
    mov x2, #1
    mov x3, x21
    b .Lpd_ret
.Lpd_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_strip_copy(x0=dst, x1=src) -> x0 = dst (stripped copy)
// ----------------------------------------------------------------------------
    .p2align 2
cli_strip_copy:
    PROLOGUE 2
    mov x19, x0
    mov x20, x1
.Lsc_lead:
    ldrb w0, [x20]
    bl tc_is_ws
    cbz w0, .Lsc_copy
    add x20, x20, #1
    b .Lsc_lead
.Lsc_copy:
    mov x21, x19
.Lsc_loop:
    ldrb w0, [x20], #1
    strb w0, [x21], #1
    cbnz w0, .Lsc_loop
    // trim trailing whitespace: x21 is one past the NUL; back up over every
    // whitespace byte and terminate after the last kept one (str.strip())
    sub x21, x21, #1                // -> the NUL
.Lsc_trail:
    cmp x21, x19
    b.le .Lsc_done                  // nothing left
    ldrb w0, [x21, #-1]
    bl tc_is_ws
    cbz w0, .Lsc_done
    sub x21, x21, #1
    strb wzr, [x21]
    b .Lsc_trail
.Lsc_done:
    mov x0, x19
    EPILOGUE 2
    ret

// ----------------------------------------------------------------------------
// cli_norm_T(x0=s) — replace 'T' with ' ' in place
// ----------------------------------------------------------------------------
    .p2align 2
cli_norm_T:
    mov x1, x0
.Lnt:
    ldrb w2, [x1]
    cbz w2, .Lnt_done
    cmp w2, #'T'
    b.ne .Lnt_next
    mov w2, #' '
    strb w2, [x1]
.Lnt_next:
    add x1, x1, #1
    b .Lnt
.Lnt_done:
    ret

// ----------------------------------------------------------------------------
// cli_match_week(x0=s) -> x0=1 for "YYYY-Www" / "YYYYWww" (+ optional "-d");
//   x1=year, x2=week, x3=weekday (0 = none)
// ============================================================================
    .p2align 2
cli_match_week:
    PROLOGUE 5
    mov x19, x0
    mov x1, #4
    bl cli_read_digits
    cbz x1, .Lmw_no
    mov x20, x0                     // year
    ldrb w0, [x19, #4]
    cmp w0, #'-'
    b.eq .Lmw_dash
    cmp w0, #'W'
    b.eq .Lmw_w2
    cmp w0, #'w'
    b.eq .Lmw_w2
    b .Lmw_no
.Lmw_dash:
    ldrb w0, [x19, #5]
    cmp w0, #'W'
    b.eq .Lmw_w
    cmp w0, #'w'
    b.eq .Lmw_w
    b .Lmw_no
.Lmw_w2:
    add x0, x19, #5
    b .Lmw_week
.Lmw_w:
    add x0, x19, #6
.Lmw_week:
    mov x1, #1
    bl cli_read_digits_range         // x0=value, x1=ok, x2=next ptr
    cbz x1, .Lmw_no
    mov x21, x0                     // week
    ldrb w0, [x2]
    cbz w0, .Lmw_plain
    cmp w0, #'-'
    b.ne .Lmw_no
    ldrb w0, [x2, #1]
    cmp w0, #'1'
    b.lt .Lmw_no
    cmp w0, #'7'
    b.gt .Lmw_no
    ldrb w3, [x2, #2]
    cbnz w3, .Lmw_no
    sub w0, w0, #'0'
    mov x22, x0                     // weekday
    b .Lmw_yes
.Lmw_plain:
    // A plain week is accepted exactly when the week digits END the string.
    // The NUL at [x2] is that bound: the weekday branch above already forced
    // a '-' (and a weekday digit) here, so [x2] == 0 means nothing follows.
    // The old code also read [x2, #1] and required it to be NUL, which reads
    // ONE BYTE PAST the string into whatever stale bytes the shared scratch
    // buffer holds (an ISO-week --begin failed whenever a longer plain date
    // had been parsed into cli_scratch first).
    mov x22, #0                     // weekday = none
.Lmw_yes:
    mov x1, x20                     // year
    mov x2, x21                     // week
    mov x3, x22                     // weekday (0 = none)
    mov x0, #1
    EPILOGUE 5
    ret
.Lmw_no:
    mov x0, #0
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_match_compact_week(x0=s) -> x0=1 for "YYYYWwwD"; x1=year, x2=week, x3=day
// ----------------------------------------------------------------------------
    .p2align 2
cli_match_compact_week:
    PROLOGUE 5
    mov x19, x0
    mov x1, #4
    bl cli_read_digits
    cbz x1, .Lmcw_no
    mov x20, x0
    ldrb w0, [x19, #4]
    cmp w0, #'W'
    b.eq .Lmcw_w
    cmp w0, #'w'
    b.eq .Lmcw_w
    b .Lmcw_no
.Lmcw_w:
    add x0, x19, #5
    mov x1, #2
    bl cli_read_digits
    cbz x1, .Lmcw_no
    mov x21, x0
    ldrb w0, [x19, #7]
    cmp w0, #'1'
    b.lt .Lmcw_no
    cmp w0, #'7'
    b.gt .Lmcw_no
    ldrb w2, [x19, #8]
    cbnz w2, .Lmcw_no
    sub w0, w0, #'0'
    mov x22, x0
    mov x1, x20                     // year
    mov x2, x21                     // week
    mov x3, x22                     // day
    mov x0, #1
    EPILOGUE 5
    ret
.Lmcw_no:
    mov x0, #0
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_read_digits(x0=s, x1=n) -> x0=value, x1=ok (exactly n digits)
// ----------------------------------------------------------------------------
    .p2align 2
cli_read_digits:
    mov x2, #0
    mov x3, #0
.Lrd:
    cmp x3, x1
    b.ge .Lrd_done
    ldrb w4, [x0, x3]
    cmp w4, #'0'
    b.lt .Lrd_no
    cmp w4, #'9'
    b.gt .Lrd_no
    sub w4, w4, #'0'
    mov x5, #10
    mul x2, x2, x5
    add x2, x2, x4
    add x3, x3, #1
    b .Lrd
.Lrd_done:
    mov x0, x2
    mov x1, #1
    ret
.Lrd_no:
    mov x0, #0
    mov x1, #0
    ret

// ----------------------------------------------------------------------------
// cli_read_digits_range(x0=s, x1=min) -> x0=value, x1=ok, x2=next ptr
// ----------------------------------------------------------------------------
    .p2align 2
cli_read_digits_range:
    mov x2, #0
    mov x3, #0
    mov x4, x0
.Lrdr:
    ldrb w5, [x4]
    cmp w5, #'0'
    b.lt .Lrdr_stop
    cmp w5, #'9'
    b.gt .Lrdr_stop
    sub w5, w5, #'0'
    mov x6, #10
    mul x2, x2, x6
    add x2, x2, x5
    add x4, x4, #1
    add x3, x3, #1
    cmp x3, #2
    b.ge .Lrdr_stop
    b .Lrdr
.Lrdr_stop:
    cmp x3, x1
    b.lt .Lrdr_no
    mov x0, x2
    mov x1, #1
    mov x2, x4
    ret
.Lrdr_no:
    mov x0, #0
    mov x1, #0
    mov x2, x4
    ret

// ----------------------------------------------------------------------------
// cli_parse_fixed_datetime(x0=s, x1=eod) -> (x0=ymd, x1=sod, x2=status)
// ----------------------------------------------------------------------------
    .p2align 2
cli_parse_fixed_datetime:
    PROLOGUE 5
    mov x19, x0
    mov x20, x1
    mov x0, x19
    mov x1, #4
    bl cli_read_digits
    cbz x1, .Lpfd_fail
    mov x21, x0                     // year
    cbz x21, .Lpfd_fail             // year 0 is out of range (Python rejects)
    ldrb w0, [x19, #4]
    cmp w0, #'-'
    b.eq .Lpfd_sep
    cmp w0, #'/'
    b.eq .Lpfd_sep
    b .Lpfd_fail
.Lpfd_sep:
    uxtw x22, w0                    // sep
    add x0, x19, #5
    mov x1, #1
    bl cli_read_digits_range
    cbz x1, .Lpfd_fail
    mov x23, x0                     // month
    mov x24, x2                     // ptr after month
    ldrb w0, [x24]
    cmp w0, w22
    b.ne .Lpfd_fail
    add x0, x24, #1
    mov x1, #1
    bl cli_read_digits_range
    cbz x1, .Lpfd_fail
    mov x24, x0                     // day
    mov x25, x2                     // ptr after day
    cmp x23, #1
    b.lt .Lpfd_fail
    cmp x23, #12
    b.gt .Lpfd_fail
    cmp x24, #1
    b.lt .Lpfd_fail
    mov x0, x21
    mov x1, x23
    bl tc_days_in_month
    cmp x24, x0
    b.gt .Lpfd_fail
    mov x26, #0
    mov x27, #0
    mov x28, #0
    ldrb w0, [x25]
    cbz w0, .Lpfd_date_only
    cmp w0, #' '
    b.ne .Lpfd_fail
    add x0, x25, #1
    mov x1, #1
    bl cli_read_digits_range
    cbz x1, .Lpfd_fail
    mov x26, x0
    mov x25, x2
    ldrb w0, [x25]
    cbz w0, .Lpfd_time_done
    cmp w0, #':'
    b.ne .Lpfd_fail
    add x0, x25, #1
    mov x1, #1
    bl cli_read_digits_range
    cbz x1, .Lpfd_fail
    mov x27, x0
    mov x25, x2
    ldrb w0, [x25]
    cbz w0, .Lpfd_time_done
    cmp w0, #':'
    b.ne .Lpfd_fail
    add x0, x25, #1
    mov x1, #1
    bl cli_read_digits_range
    cbz x1, .Lpfd_fail
    mov x28, x0
    mov x25, x2
    ldrb w0, [x25]
    cbnz w0, .Lpfd_fail
    b .Lpfd_time_done
.Lpfd_date_only:
    cbz x20, .Lpfd_time_done
    mov x26, #23
    mov x27, #59
    mov x28, #59
.Lpfd_time_done:
    cmp x26, #23
    b.gt .Lpfd_fail
    cmp x27, #59
    b.gt .Lpfd_fail
    cmp x28, #59
    b.gt .Lpfd_fail
    mov x0, x21
    mov x1, #YMD_YEAR_SCALE
    mul x0, x0, x1
    mov x1, #YMD_MONTH_SCALE
    mul x23, x23, x1
    add x0, x0, x23
    add x0, x0, x24
    mov x1, #SECS_PER_HOUR
    mul x26, x26, x1
    mov x1, #60
    madd x1, x27, x1, x26
    add x1, x1, x28
    mov x2, #0
    b .Lpfd_ret
.Lpfd_fail:
    mov x0, #0
    mov x1, #0
    mov x2, #1
.Lpfd_ret:
    EPILOGUE 5
    ret

// ============================================================================
// tc_parse_duration(x0=s) -> (x0=secs, x1=status)  0 ok, 1 unrec, 2 zero
// ============================================================================
    .p2align 2
    .global tc_parse_duration
    FUNC_TYPE(tc_parse_duration)
tc_parse_duration:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    mov x19, x0
    bl cli_lowercase
    mov x20, #0                     // total
    mov x21, #0                     // parts
    mov x22, x19
.Lpdur_loop:
    ldrb w0, [x22]
    cbz w0, .Lpdur_done
    mov x23, #0                     // n
    mov x24, #0                     // digit count
.Lpdur_digits:
    ldrb w5, [x22]
    cmp w5, #'0'
    b.lt .Lpdur_unit
    cmp w5, #'9'
    b.gt .Lpdur_unit
    sub w5, w5, #'0'
    mov x6, #10
    umulh x7, x23, x6
    cbnz x7, .Lpdur_bad
    mul x23, x23, x6
    adds x23, x23, x5
    b.cs .Lpdur_bad
    add x22, x22, #1
    add x24, x24, #1
    b .Lpdur_digits
.Lpdur_unit:
    cbz x24, .Lpdur_bad
    ldrb w5, [x22]
    cmp w5, #'w'
    b.eq .Lpdur_w
    cmp w5, #'d'
    b.eq .Lpdur_d
    cmp w5, #'h'
    b.eq .Lpdur_h
    cmp w5, #'m'
    b.eq .Lpdur_m
    cmp w5, #'s'
    b.eq .Lpdur_s
    b .Lpdur_bad
.Lpdur_w:
    ldr x7, =SECS_PER_WEEK
    b .Lpdur_apply
.Lpdur_d:
    ldr x7, =SECS_PER_DAY
    b .Lpdur_apply
.Lpdur_h:
    mov x7, #SECS_PER_HOUR
    b .Lpdur_apply
.Lpdur_m:
    mov x7, #60
    b .Lpdur_apply
.Lpdur_s:
    mov x7, #1
.Lpdur_apply:
    umulh x8, x23, x7
    cbnz x8, .Lpdur_bad
    mul x23, x23, x7
    add x22, x22, #1
    adds x20, x20, x23
    b.cs .Lpdur_bad
    add x21, x21, #1
    b .Lpdur_loop
.Lpdur_done:
    cbz x21, .Lpdur_bad
    cbz x20, .Lpdur_zero
    mov x0, x20
    mov x1, #0
    b .Lpdur_ret
.Lpdur_zero:
    mov x0, #0
    mov x1, #2
    b .Lpdur_ret
.Lpdur_bad:
    mov x0, #0
    mov x1, #1
.Lpdur_ret:
    EPILOGUE 5
    ret

// ----------------------------------------------------------------------------
// cli_lowercase(x0=s)
// ----------------------------------------------------------------------------
    .p2align 2
cli_lowercase:
    mov x1, x0
.Llc:
    ldrb w2, [x1]
    cbz w2, .Llc_done
    cmp w2, #'A'
    b.lt .Llc_next
    cmp w2, #'Z'
    b.gt .Llc_next
    add w2, w2, #('a' - 'A')
    strb w2, [x1]
.Llc_next:
    add x1, x1, #1
    b .Llc
.Llc_done:
    ret

// ============================================================================
// Integer parsers (Python int() semantics)
// ============================================================================

// cli_parse_int_core(x0=s) -> (x0=value, x1=ok)
    .p2align 2
cli_parse_int_core:
    // leaf (no bl): save only the pairs actually used; no x29/x30 frame.
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x19
.Lpic_lead:
    ldrb w0, [x20]
    cbz w0, .Lpic_bad
    cmp w0, #' '
    b.eq .Lpic_lead_next
    cmp w0, #'\t'
    b.eq .Lpic_lead_next
    cmp w0, #'\n'
    b.eq .Lpic_lead_next
    cmp w0, #'\r'
    b.eq .Lpic_lead_next
    b .Lpic_sign
.Lpic_lead_next:
    add x20, x20, #1
    b .Lpic_lead
.Lpic_sign:
    mov x21, #1
    ldrb w0, [x20]
    cmp w0, #'+'
    b.eq .Lpic_plus
    cmp w0, #'-'
    b.eq .Lpic_minus
    b .Lpic_digits
.Lpic_plus:
    add x20, x20, #1
    b .Lpic_digits
.Lpic_minus:
    mov x21, #-1
    add x20, x20, #1
.Lpic_digits:
    mov x22, #0
    mov x23, #0
    mov x24, #0
.Lpic_loop:
    ldrb w0, [x20]
    cbz w0, .Lpic_trail
    cmp w0, #'0'
    b.lt .Lpic_underscore
    cmp w0, #'9'
    b.gt .Lpic_underscore
    sub w0, w0, #'0'
    mov x1, #10
    umulh x2, x22, x1
    cbnz x2, .Lpic_bad
    mul x22, x22, x1
    adds x22, x22, x0
    b.cs .Lpic_bad
    add x23, x23, #1
    mov x24, #1
    add x20, x20, #1
    b .Lpic_loop
.Lpic_underscore:
    cmp w0, #'_'
    b.ne .Lpic_bad
    cbz x24, .Lpic_bad
    ldrb w1, [x20, #1]
    cmp w1, #'0'
    b.lt .Lpic_bad
    cmp w1, #'9'
    b.gt .Lpic_bad
    mov x24, #0
    add x20, x20, #1
    b .Lpic_loop
.Lpic_trail:
    ldrb w0, [x20]
    cmp w0, #' '
    b.eq .Lpic_trail_next
    cmp w0, #'\t'
    b.eq .Lpic_trail_next
    cmp w0, #'\n'
    b.eq .Lpic_trail_next
    cmp w0, #'\r'
    b.eq .Lpic_trail_next
    b .Lpic_finish
.Lpic_trail_next:
    add x20, x20, #1
    b .Lpic_trail
.Lpic_finish:
    ldrb w0, [x20]
    cbnz w0, .Lpic_bad
    cbz x23, .Lpic_bad
    mul x22, x22, x21
    mov x0, x22
    mov x1, #1
    b .Lpic_ret
.Lpic_bad:
    mov x0, #0
    mov x1, #0
    b .Lpic_ret
.Lpic_ret:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret

// cli_parse_positive_int(x0=s) -> (x0=value, x1=status)
cli_parse_positive_int:
    PROLOGUE 0
    bl cli_parse_int_core
    cbz x1, .Lppi_bad
    cmp x0, #1
    b.lt .Lppi_range
    mov x1, #0
    EPILOGUE 0
    ret
.Lppi_bad:
    mov x0, #0
    mov x1, #1
    EPILOGUE 0
    ret
.Lppi_range:
    mov x0, #0
    mov x1, #2
    EPILOGUE 0
    ret

cli_parse_nonnegative_int:
    PROLOGUE 0
    bl cli_parse_int_core
    cbz x1, .Lpni_bad
    cmp x0, #0
    b.lt .Lpni_range
    mov x1, #0
    EPILOGUE 0
    ret
.Lpni_bad:
    mov x0, #0
    mov x1, #1
    EPILOGUE 0
    ret
.Lpni_range:
    mov x0, #0
    mov x1, #2
    EPILOGUE 0
    ret

cli_parse_float_core:
    PROLOGUE 3
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    mov x19, x0
    bl cli_remove_underscores
    mov x0, x19
    LEA x1, cli_strtod_end
    bl strtod
    fmov x20, d0
    LEA x21, cli_strtod_end
    ldr x22, [x21]
    cmp x22, x19
    b.eq .Lpfc_bad
    mov x23, x22
.Lpfc_ws:
    ldrb w0, [x23]
    cbz w0, .Lpfc_ok
    cmp w0, #' '
    b.eq .Lpfc_ws_next
    cmp w0, #'\t'
    b.eq .Lpfc_ws_next
    cmp w0, #'\n'
    b.eq .Lpfc_ws_next
    cmp w0, #'\r'
    b.eq .Lpfc_ws_next
    b .Lpfc_bad
.Lpfc_ws_next:
    add x23, x23, #1
    b .Lpfc_ws
.Lpfc_ok:
    mov x0, x20
    mov x1, #0
    b .Lpfc_ret
.Lpfc_bad:
    mov x0, #0
    mov x1, #1
.Lpfc_ret:
    EPILOGUE 3
    ret

// cli_remove_underscores(x0=s)
    .p2align 2
cli_remove_underscores:
    mov x1, x0
    mov x2, x0
.Lru:
    ldrb w3, [x1], #1
    cbz w3, .Lru_done
    cmp w3, #'_'
    b.eq .Lru
    strb w3, [x2], #1
    b .Lru
.Lru_done:
    strb wzr, [x2]
    ret

// cli_parse_nonnegative_float(x0=s) -> (x0=bits, x1=status)
    .p2align 2
cli_parse_nonnegative_float:
    PROLOGUE 1
    mov x19, x0
    bl cli_parse_float_core
    cbz x1, .Lpnnf_ok
    mov x0, #0
    mov x1, #1
    b .Lpnnf_ret
.Lpnnf_ok:
    mov x20, x0
    fmov d0, x0
    fcmp d0, d0
    b.vs .Lpnnf_range                // NaN is unordered with itself: reject
    fmov d1, xzr
    fcmp d0, d1
    b.ge .Lpnnf_good
.Lpnnf_range:
    mov x0, #0
    mov x1, #2
    b .Lpnnf_ret
.Lpnnf_good:
    mov x0, x20
    mov x1, #0
.Lpnnf_ret:
    EPILOGUE 1
    ret

// cli_parse_positive_float(x0=s) -> (x0=bits, x1=status)
    .p2align 2
cli_parse_positive_float:
    PROLOGUE 5
    mov x19, x0
    bl cli_parse_float_core
    cbz x1, .Lppf_ok
    mov x0, #0
    mov x1, #1
    b .Lppf_ret
.Lppf_ok:
    mov x20, x0
    fmov d0, x0
    fcmp d0, d0
    b.vs .Lppf_range                 // NaN is unordered with itself: reject
    fmov d1, xzr
    fcmp d0, d1
    b.gt .Lppf_good
.Lppf_range:
    mov x0, #0
    mov x1, #2
    b .Lppf_ret
.Lppf_good:
    mov x0, x20
    mov x1, #0
.Lppf_ret:
    EPILOGUE 5
    ret

// ============================================================================
// Choice parsers (strip + lowercase + table match)
// ============================================================================

// tc_parse_state(x0=s) -> (x0=TC_ST_*, x1=status)
    .p2align 2
    .global tc_parse_state
    FUNC_TYPE(tc_parse_state)
tc_parse_state:
    PROLOGUE 2
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    LEA x21, tc_str_live
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpst_live
    LEA x21, tc_str_offline
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpst_offline
    LEA x21, tc_str_unknown
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpst_unknown
    LEA x21, s_state_any
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpst_any
    LEA x21, s_state_all
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpst_any
    mov x0, #0
    mov x1, #1
    b .Lpst_ret
.Lpst_live:
    mov x0, #TC_ST_LIVE
    mov x1, #0
    b .Lpst_ret
.Lpst_offline:
    mov x0, #TC_ST_OFFLINE
    mov x1, #0
    b .Lpst_ret
.Lpst_unknown:
    mov x0, #TC_ST_UNKNOWN
    mov x1, #0
    b .Lpst_ret
.Lpst_any:
    mov x0, #TC_ST_NONE
    mov x1, #0
.Lpst_ret:
    EPILOGUE 2
    ret

// tc_parse_header(x0=s) -> (x0=TC_HDR_*, x1=status)
    .p2align 2
    .global tc_parse_header
    FUNC_TYPE(tc_parse_header)
tc_parse_header:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    LEA x21, s_hdr_full
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lph_full
    LEA x21, s_hdr_compact
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lph_compact
    LEA x21, s_hdr_none
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lph_none
    mov x0, #0
    mov x1, #1
    b .Lph_ret
.Lph_full:
    mov x0, #TC_HDR_FULL
    mov x1, #0
    b .Lph_ret
.Lph_compact:
    mov x0, #TC_HDR_COMPACT
    mov x1, #0
    b .Lph_ret
.Lph_none:
    mov x0, #TC_HDR_NONE
    mov x1, #0
.Lph_ret:
    EPILOGUE 5
    ret

// tc_parse_sort(x0=s) -> (x0=TC_M_*, x1=status)
    .p2align 2
    .global tc_parse_sort
    FUNC_TYPE(tc_parse_sort)
tc_parse_sort:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    LEA x21, tc_str_count
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpso_count
    LEA x21, tc_str_login
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpso_login
    LEA x21, tc_str_live
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpso_live
    LEA x21, tc_str_offline
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpso_offline
    LEA x21, tc_str_unknown
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpso_unknown
    LEA x21, tc_str_offshare
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpso_os
    LEA x21, tc_str_liveshare
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpso_ls
    mov x0, #0
    mov x1, #1
    b .Lpso_ret
.Lpso_count:  mov x0, #TC_M_COUNT
    mov x1, #0
    b .Lpso_ret
.Lpso_login:  mov x0, #TC_M_LOGIN
    mov x1, #0
    b .Lpso_ret
.Lpso_live:   mov x0, #TC_M_LIVE
    mov x1, #0
    b .Lpso_ret
.Lpso_offline:mov x0, #TC_M_OFFLINE
    mov x1, #0
    b .Lpso_ret
.Lpso_unknown:mov x0, #TC_M_UNKNOWN
    mov x1, #0
    b .Lpso_ret
.Lpso_os:     mov x0, #TC_M_OFFLINE_SHARE
    mov x1, #0
    b .Lpso_ret
.Lpso_ls:     mov x0, #TC_M_LIVE_SHARE
    mov x1, #0
.Lpso_ret:
    EPILOGUE 5
    ret

// tc_parse_curve(x0=s) -> (x0=TC_CURVE_*, x1=status)
    .p2align 2
    .global tc_parse_curve
    FUNC_TYPE(tc_parse_curve)
tc_parse_curve:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    LEA x21, s_curve_linear
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpc_linear
    LEA x21, s_curve_power
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpc_power
    LEA x21, s_curve_ease_out
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpc_easeout
    LEA x21, s_curve_bias
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpc_bias
    LEA x21, s_curve_ease_in_out
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpc_eio
    mov x0, #0
    mov x1, #1
    b .Lpc_ret
.Lpc_linear: mov x0, #TC_CURVE_LINEAR
    mov x1, #0
    b .Lpc_ret
.Lpc_power:  mov x0, #TC_CURVE_POWER
    mov x1, #0
    b .Lpc_ret
.Lpc_easeout:mov x0, #TC_CURVE_EASE_OUT
    mov x1, #0
    b .Lpc_ret
.Lpc_bias:   mov x0, #TC_CURVE_BIAS
    mov x1, #0
    b .Lpc_ret
.Lpc_eio:    mov x0, #TC_CURVE_EASE_IN_OUT
    mov x1, #0
.Lpc_ret:
    EPILOGUE 5
    ret

// tc_parse_users_policy(x0=s) -> (x0=id, x1=status)
    .p2align 2
    .global tc_parse_users_policy
    FUNC_TYPE(tc_parse_users_policy)
tc_parse_users_policy:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    LEA x21, s_policy_at_least
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpp_at_least
    LEA x21, s_policy_at_most
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpp_at_most
    LEA x21, s_policy_nearest
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpp_nearest
    mov x0, #0
    mov x1, #1
    b .Lpp_ret
.Lpp_at_least: mov x0, #TC_POLICY_AT_LEAST
    mov x1, #0
    b .Lpp_ret
.Lpp_at_most:  mov x0, #TC_POLICY_AT_MOST
    mov x1, #0
    b .Lpp_ret
.Lpp_nearest:  mov x0, #TC_POLICY_NEAREST
    mov x1, #0
.Lpp_ret:
    EPILOGUE 5
    ret

// tc_parse_bool(x0=s) -> (x0=0/1, x1=status)
    .p2align 2
    .global tc_parse_bool
    FUNC_TYPE(tc_parse_bool)
tc_parse_bool:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    ldrb w0, [x20]
    cmp w0, #'1'
    b.eq .Lpb_true
    cmp w0, #'0'
    b.eq .Lpb_false
    LEA x21, s_bool_true
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpb_true
    LEA x21, s_bool_yes
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpb_true
    LEA x21, s_bool_on
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpb_true
    LEA x21, s_bool_false
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpb_false
    LEA x21, s_bool_no
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpb_false
    LEA x21, s_bool_off
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpb_false
    mov x0, #0
    mov x1, #1
    b .Lpb_ret
.Lpb_true:
    mov x0, #1
    mov x1, #0
    b .Lpb_ret
.Lpb_false:
    mov x0, #0
    mov x1, #0
.Lpb_ret:
    EPILOGUE 5
    ret

// tc_parse_hex_colour(x0=s) -> (x0=rgb packed, x1=status)
    .p2align 2
    .global tc_parse_hex_colour
    FUNC_TYPE(tc_parse_hex_colour)
tc_parse_hex_colour:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    mov x19, x0
    ldrb w0, [x19]
    cmp w0, #'#'
    b.ne .Lphx_no_hash
    add x19, x19, #1
.Lphx_no_hash:
    mov x20, x19
    mov x21, #0
.Lphx_count:
    ldrb w0, [x20]
    cbz w0, .Lphx_count_done
    bl cli_is_hexdigit
    cbz x0, .Lphx_bad
    add x20, x20, #1
    add x21, x21, #1
    cmp x21, #6
    b.gt .Lphx_bad
    b .Lphx_count
.Lphx_count_done:
    cmp x21, #3
    b.eq .Lphx_three
    cmp x21, #6
    b.eq .Lphx_six
    b .Lphx_bad
.Lphx_three:
    ldrb w0, [x19]
    bl cli_hexval
    mov x22, x0
    ldrb w0, [x19, #1]
    bl cli_hexval
    mov x23, x0
    ldrb w0, [x19, #2]
    bl cli_hexval
    mov x24, x0
    lsl x22, x22, #4
    orr x22, x22, x22, lsr #4
    lsl x23, x23, #4
    orr x23, x23, x23, lsr #4
    lsl x24, x24, #4
    orr x24, x24, x24, lsr #4
    b .Lphx_pack
.Lphx_six:
    // int(digits[i:i + 2], 16): the first digit of each pair is the high
    // nibble ("6f" is 0x6f, not 0xf6)
    ldrb w0, [x19]
    bl cli_hexval
    lsl x22, x0, #4
    ldrb w0, [x19, #1]
    bl cli_hexval
    orr x22, x22, x0
    ldrb w0, [x19, #2]
    bl cli_hexval
    lsl x23, x0, #4
    ldrb w0, [x19, #3]
    bl cli_hexval
    orr x23, x23, x0
    ldrb w0, [x19, #4]
    bl cli_hexval
    lsl x24, x0, #4
    ldrb w0, [x19, #5]
    bl cli_hexval
    orr x24, x24, x0
.Lphx_pack:
    lsl x22, x22, #16
    lsl x23, x23, #8
    orr x22, x22, x23
    orr x22, x22, x24
    mov x0, x22
    mov x1, #0
    b .Lphx_ret
.Lphx_bad:
    mov x0, #0
    mov x1, #1
.Lphx_ret:
    EPILOGUE 5
    ret

// cli_is_hexdigit(x0=char) -> x0 = 1/0
    .p2align 2
cli_is_hexdigit:
    cmp w0, #'0'
    b.lt .Lihx_no
    cmp w0, #'9'
    b.le .Lihx_yes
    cmp w0, #'a'
    b.lt .Lihx_no
    cmp w0, #'f'
    b.le .Lihx_yes
    cmp w0, #'A'
    b.lt .Lihx_no
    cmp w0, #'F'
    b.le .Lihx_yes
.Lihx_no:
    mov x0, #0
    ret
.Lihx_yes:
    mov x0, #1
    ret

// cli_hexval(x0=char) -> x0 = hex value
    .p2align 2
cli_hexval:
    cmp w0, #'0'
    b.lt .Lhv_zero
    cmp w0, #'9'
    b.gt .Lhv_alpha
    sub w0, w0, #'0'
    ret
.Lhv_alpha:
    cmp w0, #'a'
    b.lt .Lhv_alpha_up
    sub w0, w0, #('a' - 10)
    ret
.Lhv_alpha_up:
    sub w0, w0, #('A' - 10)
    ret
.Lhv_zero:
    mov w0, #0
    ret

// cli_parse_color_choice(x0=s) -> (x0=id, x1=status)
    .p2align 2
cli_parse_color_choice:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    LEA x21, s_color_auto
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcol_auto
    LEA x21, s_color_always
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcol_always
    LEA x21, s_color_never
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcol_never
    mov x0, #0
    mov x1, #1
    b .Lpcol_ret
.Lpcol_auto:  mov x0, #TC_COLOR_AUTO
    mov x1, #0
    b .Lpcol_ret
.Lpcol_always: mov x0, #TC_COLOR_ALWAYS
    mov x1, #0
    b .Lpcol_ret
.Lpcol_never:  mov x0, #TC_COLOR_NEVER
    mov x1, #0
.Lpcol_ret:
    EPILOGUE 5
    ret

// cli_parse_complete_choice(x0=s) -> (x0=id, x1=status)
    .p2align 2
cli_parse_complete_choice:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    bl cli_lowercase
    LEA x20, cli_scratch2
    LEA x21, s_comp_channels
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcom_channels
    LEA x21, s_comp_groups
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcom_groups
    LEA x21, s_comp_dates
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcom_dates
    LEA x21, s_comp_weeks
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcom_weeks
    LEA x21, s_comp_periods
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcom_periods
    LEA x21, s_comp_users
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcom_users
    LEA x21, s_comp_includes
    mov x0, x20
    mov x1, x21
    bl tc_streq
    cbnz x0, .Lpcom_includes
    mov x0, #0
    mov x1, #1
    b .Lpcom_ret
.Lpcom_channels: mov x0, #TC_COMPLETE_CHANNELS
    mov x1, #0
    b .Lpcom_ret
.Lpcom_groups:   mov x0, #TC_COMPLETE_GROUPS
    mov x1, #0
    b .Lpcom_ret
.Lpcom_dates:    mov x0, #TC_COMPLETE_DATES
    mov x1, #0
    b .Lpcom_ret
.Lpcom_weeks:    mov x0, #TC_COMPLETE_WEEKS
    mov x1, #0
    b .Lpcom_ret
.Lpcom_periods:  mov x0, #TC_COMPLETE_PERIODS
    mov x1, #0
    b .Lpcom_ret
.Lpcom_users:    mov x0, #TC_COMPLETE_USERS
    mov x1, #0
    b .Lpcom_ret
.Lpcom_includes: mov x0, #TC_COMPLETE_INCLUDES
    mov x1, #0
.Lpcom_ret:
    EPILOGUE 5
    ret

// ============================================================================
// tc_parse_metrics(x0=s) -> (x0=count, x1=status, x2=failing column ptr)
// ============================================================================
    .p2align 2
    .global tc_parse_metrics
    FUNC_TYPE(tc_parse_metrics)
tc_parse_metrics:
    PROLOGUE 5
    mov x19, x0
    LEA x0, cli_scratch2
    mov x1, x19
    bl cli_strip_copy
    mov x19, x0
    LEA x20, cli_metrics_tmp
    mov x21, #0
    mov x22, x19
.Lpm_skip:
    ldrb w0, [x22]
    cbz w0, .Lpm_done
    cmp w0, #','
    b.eq .Lpm_skip_next
    cmp w0, #' '
    b.eq .Lpm_skip_next
    cmp w0, #'\t'
    b.eq .Lpm_skip_next
    b .Lpm_item
.Lpm_skip_next:
    add x22, x22, #1
    b .Lpm_skip
.Lpm_item:
    mov x23, x22
.Lpm_item_end:
    ldrb w0, [x23]
    cbz w0, .Lpm_item_ready
    cmp w0, #','
    b.eq .Lpm_item_ready
    cmp w0, #' '
    b.eq .Lpm_item_ready
    cmp w0, #'\t'
    b.eq .Lpm_item_ready
    add x23, x23, #1
    b .Lpm_item_end
.Lpm_item_ready:
    ldrb w0, [x23]
    cbz w0, .Lpm_item_at_end
    mov w1, #0
    strb w1, [x23]
    add x23, x23, #1
    b .Lpm_item_checked
.Lpm_item_at_end:
    add x23, x23, #1
.Lpm_item_checked:
    mov x0, x22
    bl cli_lowercase
    mov x0, x22
    bl cli_metric_id
    cmn x0, #1
    b.eq .Lpm_bad
    mov x24, x0
    mov x25, #0
.Lpm_dedupe:
    cmp x25, x21
    b.ge .Lpm_append
    ldr x26, [x20, x25, lsl #3]
    cmp x26, x24
    b.eq .Lpm_next
    add x25, x25, #1
    b .Lpm_dedupe
.Lpm_append:
    cmp x21, #6
    b.ge .Lpm_next
    str x24, [x20, x21, lsl #3]
    add x21, x21, #1
.Lpm_next:
    mov x22, x23
    b .Lpm_skip
.Lpm_bad:
    mov x0, #0
    mov x1, #1
    mov x2, x22
    b .Lpm_ret
.Lpm_done:
    LEA x0, cli_metrics_tmp_n
    str x21, [x0]
    mov x0, x21
    mov x1, #0
    mov x2, #0
.Lpm_ret:
    EPILOGUE 5
    ret

// cli_metric_id(x0=s) -> x0 = metric id or -1
    .p2align 2
cli_metric_id:
    PROLOGUE 5
    mov x19, x0
    LEA x20, tc_str_count
    mov x0, x19
    mov x1, x20
    bl tc_streq
    cbnz x0, .Lmi_count
    LEA x20, tc_str_live
    mov x0, x19
    mov x1, x20
    bl tc_streq
    cbnz x0, .Lmi_live
    LEA x20, tc_str_offline
    mov x0, x19
    mov x1, x20
    bl tc_streq
    cbnz x0, .Lmi_offline
    LEA x20, tc_str_unknown
    mov x0, x19
    mov x1, x20
    bl tc_streq
    cbnz x0, .Lmi_unknown
    LEA x20, tc_str_offshare
    mov x0, x19
    mov x1, x20
    bl tc_streq
    cbnz x0, .Lmi_os
    LEA x20, tc_str_liveshare
    mov x0, x19
    mov x1, x20
    bl tc_streq
    cbnz x0, .Lmi_ls
    mov x0, #-1
    b .Lmi_ret
.Lmi_count: mov x0, #TC_M_COUNT
    b .Lmi_ret
.Lmi_live:  mov x0, #TC_M_LIVE
    b .Lmi_ret
.Lmi_offline: mov x0, #TC_M_OFFLINE
    b .Lmi_ret
.Lmi_unknown: mov x0, #TC_M_UNKNOWN
    b .Lmi_ret
.Lmi_os:    mov x0, #TC_M_OFFLINE_SHARE
    b .Lmi_ret
.Lmi_ls:    mov x0, #TC_M_LIVE_SHARE
.Lmi_ret:
    EPILOGUE 5
    ret


// ----------------------------------------------------------------------------
// tc_setting_src_str(x0=TC_SET_* id) -> x0 = the source string of that
//   setting's provenance (tc_source_str of tc_opts.TC_O_SRC[id]).  Shared by
//   the header rows (tc_render.S) and the JSON report (tc_json.S).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_setting_src_str
    FUNC_TYPE(tc_setting_src_str)
tc_setting_src_str:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    LEA x0, tc_opts
    movz x2, #TC_O_SRC
    add x0, x0, x2
    ldr x0, [x0, x19, lsl #3]
    bl tc_source_str
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// tc_source_str(x0=id) -> (x0=ptr, x1=len)
// ============================================================================
    .p2align 2
    .global tc_source_str
    FUNC_TYPE(tc_source_str)
tc_source_str:
    PROLOGUE 5
    mov x19, x0
    cmp x19, #TC_SRC_DYN_SINCE
    b.eq .Lss_dyn_win
    cmp x19, #TC_SRC_DYN_USERS
    b.eq .Lss_dyn_win
    cmp x19, #TC_SRC_DYN_ALIAS
    b.eq .Lss_dyn_chan
    cmp x19, #1
    b.lt .Lss_none
    cmp x19, #TC_SRC_COUNT
    b.ge .Lss_none
    LEA x0, cli_source_table
    ldr x0, [x0, x19, lsl #3]
    cbz x0, .Lss_none
    mov x1, x0
    bl tc_strlen
    mov x1, x0
    LEA x2, cli_source_table
    ldr x0, [x2, x19, lsl #3]
    b .Lss_ret
.Lss_dyn_win:
    mov x0, #TC_O_WIN_SRC
    bl cli_opts_off
    mov x19, x0                     // park the pointer
    bl tc_strlen
    mov x19, x0                     // park the length (cli_opts_off clobbers x1)
    mov x0, #TC_O_WIN_SRC
    bl cli_opts_off
    mov x1, x19
    b .Lss_ret
.Lss_dyn_chan:
    mov x0, #TC_O_CHAN_SRC
    bl cli_opts_off
    mov x19, x0                     // park the pointer
    bl tc_strlen
    mov x19, x0                     // park the length (cli_opts_off clobbers x1)
    mov x0, #TC_O_CHAN_SRC
    bl cli_opts_off
    mov x1, x19
    b .Lss_ret
.Lss_none:
    mov x0, #0
    mov x1, #0
.Lss_ret:
    EPILOGUE 5
    ret

// ============================================================================
// .rodata
// ============================================================================
    .data
    .skip 1
    RODATA
    .p2align 3

s_newline:      .asciz "\n"
s_space:        .asciz " "
s_q:            .asciz "'"
s_colon_space:  .asciz ": "
s_colon_err:    .asciz ": error: "
s_usage_prefix: .asciz "usage: "
s_unrecognized: .asciz "unrecognized arguments:"
s_ambiguous_prefix: .asciz "ambiguous option: "
s_ambiguous_mid:    .asciz " could match "
s_arg_prefix:   .asciz "argument "
s_not_allowed:  .asciz ": not allowed with argument "
s_ignored_explicit: .asciz ": ignored explicit argument '"
s_expected_one: .asciz "expected one argument"
s_pp_no_long:   .asciz "internal error: no long form for a value-taking short option"
s_from_prefix:  .asciz " (from "
s_from_suffix:  .asciz "): "
s_unknown_opt:  .asciz "?"
s_before_end:   .asciz " before end"
s_users_prefix: .asciz "--users "
s_by_state_label: .asciz "--by-state"
s_comma_space:  .asciz ", "
s_default_compact: .asciz "compact"
s_default_config_path: .asciz "~/.config/twitch-counts.toml"
s_help_config_static:  .asciz "  --config CONFIG       TOML config file (default: ~/.config/twitch-\n                        counts.toml)\n"
s_help_cfg_text:       .asciz "TOML config file (default: "
s_help_cfg_first:      .asciz "  --config CONFIG       "
s_help_indent:         .asciz "                        "
s_help_nl:             .asciz "\n"
s_flag_end:     .asciz "--end"
s_flag_begin:   .asciz "--begin"
s_flag_since:   .asciz "--since"
s_env_begin:    .asciz "TWITCH_BEGIN"
s_env_since:    .asciz "TWITCH_SINCE"
s_key_begin:    .asciz "begin"
s_key_since:    .asciz "since"
s_mutex_env_begin: .asciz "env TWITCH_BEGIN and env TWITCH_SINCE are mutually exclusive"
s_mutex_cfg_begin: .asciz "config begin and config since are mutually exclusive"
s_dt_unrec_prefix: .asciz "unrecognized datetime "
s_dt_unrec_suffix: .asciz " (try 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS', '2026-W31' for a whole week, or '2026-W31-3' for its Wednesday)"
s_week_no_prefix: .asciz "no week "
    s_week_in_iso:  .asciz " in ISO year "
    s_week_suffix:  .asciz " (weeks run 1-52, or 1-53 in long years)"
    s_date_out_of_range: .asciz "date value out of range"

// message body table: one 24-byte record per parser id {pre, suf, alt}
    .p2align 3
cli_msg_table:
    .skip 24                        // P_NONE
    .quad s_empty
    .quad s_m_int_suf
    .quad s_m_must_be_1   // P_POS_INT
    .quad s_empty
    .quad s_m_int_suf
    .quad s_m_row_limit   // P_NONNEG_INT
    .quad s_empty
    .quad s_m_sec_suf
    .quad s_m_zero_secs   // P_NONNEG_FLOAT
    .quad s_empty
    .quad s_m_num_suf
    .quad s_m_greater_0   // P_POS_FLOAT
    .quad s_m_dur_pre
    .quad s_m_dur_suf
    .quad s_m_dur_zero   // P_DURATION
    .skip 24                        // P_DATETIME_EOD (handled specially)
    .skip 24                        // P_DATETIME (handled specially)
    .quad s_m_state_pre
    .quad s_m_state_suf
    .quad 0   // P_STATE
    .quad s_m_hdr_pre
    .quad s_m_hdr_suf
    .quad 0   // P_HEADER
    .quad s_m_sort_pre
    .quad s_m_sort_suf
    .quad 0   // P_SORT
    .quad s_m_col_pre
    .quad s_m_col_suf
    .quad 0   // P_METRICS
    .quad s_m_policy_pre
    .quad s_m_policy_suf
    .quad 0   // P_USERS_POLICY
    .quad s_m_bool_pre
    .quad s_m_bool_suf
    .quad 0   // P_BOOL
    .quad s_m_curve_pre
    .quad s_m_curve_suf
    .quad 0   // P_CURVE
    .quad s_empty
    .quad s_m_hex_suf
    .quad 0   // P_HEX
    .skip 24                        // P_HIGHLIGHTS
    .quad s_m_color_pre
    .quad s_m_color_suf
    .quad 0   // P_CHOICES_COLOR
    .quad s_m_complete_pre
    .quad s_m_complete_suf
    .quad 0   // P_CHOICES_COMPLETE

s_empty:        .asciz ""
s_m_int_suf:    .asciz " is not an integer"
s_m_sec_suf:    .asciz " is not a number of seconds"
s_m_num_suf:    .asciz " is not a number"
s_m_must_be_1:  .asciz "must be 1 or more"
s_m_row_limit:  .asciz "row limit must be 0 (unlimited) or a positive count"
s_m_zero_secs:  .asciz "must be 0 or more seconds"
s_m_greater_0:  .asciz "must be greater than 0"
s_m_dur_pre:    .asciz "unrecognized duration "
s_m_dur_suf:    .asciz " (try '30d', '12h', '90m', '1w3d'; units are w/d/h/m/s and 'm' is minutes)"
s_m_dur_zero:   .asciz "duration must be greater than zero"
s_m_state_pre:  .asciz "unknown chat state "
s_m_state_suf:  .asciz " (expected live, offline, unknown or any)"
s_m_hdr_pre:    .asciz "unknown header mode "
s_m_hdr_suf:    .asciz " (expected full, compact, none)"
s_m_sort_pre:   .asciz "unknown sort "
s_m_sort_suf:   .asciz " (choose from: count, live, live-share, login, offline, offline-share, unknown)"
s_m_col_pre:    .asciz "unknown column "
s_m_col_suf:    .asciz " (choose from: count, live, live-share, offline, offline-share, unknown)"
s_m_policy_pre: .asciz "unknown --users-policy "
s_m_policy_suf: .asciz " (choose from: at-least, at-most, nearest)"
s_m_bool_pre:   .asciz "expected true or false, got "
s_m_bool_suf:   .asciz ""
s_m_curve_pre:  .asciz "unknown fade curve "
s_m_curve_suf:  .asciz " (choose from: bias, ease-in-out, ease-out, linear, power)"
s_m_hex_suf:    .asciz " is not a hex colour like '#0000ff'"
s_m_color_pre:  .asciz "invalid choice: "
s_m_color_suf:  .asciz " (choose from auto, always, never)"
s_m_complete_pre: .asciz "invalid choice: "
s_m_complete_suf: .asciz " (choose from channels, groups, dates, weeks, periods, users, includes)"

s_state_any:    .asciz "any"
s_state_all:    .asciz "all"
s_hdr_full:     .asciz "full"
s_hdr_compact:  .asciz "compact"
s_hdr_none:     .asciz "none"
s_curve_linear: .asciz "linear"
s_curve_power:  .asciz "power"
s_curve_ease_out: .asciz "ease-out"
s_curve_bias:   .asciz "bias"
s_curve_ease_in_out: .asciz "ease-in-out"
s_policy_at_least: .asciz "at-least"
s_policy_at_most:  .asciz "at-most"
s_policy_nearest:  .asciz "nearest"
s_bool_true:    .asciz "true"
s_bool_yes:     .asciz "yes"
s_bool_on:      .asciz "on"
s_bool_false:   .asciz "false"
s_bool_no:      .asciz "no"
s_bool_off:     .asciz "off"
s_color_auto:   .asciz "auto"
s_color_always: .asciz "always"
s_color_never:  .asciz "never"
s_comp_channels:.asciz "channels"
s_comp_groups:  .asciz "groups"
s_comp_dates:   .asciz "dates"
s_comp_weeks:   .asciz "weeks"
s_comp_periods: .asciz "periods"
s_comp_users:   .asciz "users"
s_comp_includes:.asciz "includes"

// canonical option strings (indexed by val)
s_canon_channel:    .asciz "-c/--channel"
s_canon_begin:      .asciz "-b/--begin"
s_canon_since:      .asciz "-S/--since"
s_canon_users:      .asciz "--users"
s_canon_users_policy: .asciz "--users-policy"
s_canon_users_max:  .asciz "--users-max"
s_canon_end:        .asciz "-e/--end"
s_canon_min_count:  .asciz "-m/--min-count"
s_canon_by_state:   .asciz "-B/--by-state"
s_canon_show:       .asciz "--show"
s_canon_sort:       .asciz "--sort"
s_canon_share_floor:.asciz "--share-floor"
s_canon_top:        .asciz "-n/--top"
s_canon_header:     .asciz "--header"
s_canon_logs_dir:   .asciz "-d/--logs-dir"
s_canon_json:       .asciz "-j/--json"
s_canon_watch:      .asciz "-w/--watch"
s_canon_watch_hold: .asciz "--watch-hold"
s_canon_color:      .asciz "--color"
s_canon_live:       .asciz "-L/--live"
s_canon_offline:    .asciz "-O/--offline"
s_canon_unknown:    .asciz "-U/--unknown"
s_canon_exclude:    .asciz "-x/--exclude"
s_canon_exclude_group: .asciz "-g/--exclude-group"
s_canon_exclude_bcast: .asciz "--exclude-broadcaster"
s_canon_include:    .asciz "--include"
s_canon_no_exclude: .asciz "--no-exclude"
s_canon_config:     .asciz "--config"
s_canon_no_config:  .asciz "--no-config"
s_canon_streamer:   .asciz "--streamer"
s_canon_no_cache:   .asciz "--no-cache"
s_canon_rebuild_cache: .asciz "--rebuild-cache"
s_canon_manual:     .asciz "--manual"
s_canon_emit_fish:  .asciz "--emit-fish-completions"
s_canon_complete:   .asciz "--complete"
s_canon_help:       .asciz "-h/--help"

// ============================================================================
// The val table — one 40-byte record per val (index = val).
// ============================================================================
    .p2align 3
cli_val_table:
    .skip 48                        // VAL_NONE
    .quad s_canon_channel
    .quad TC_SET_CHANNEL
    .word P_NONE, 1
    .quad TC_O_CHANNEL
    .quad 0
    .quad TC_O_CHANNEL_SZ - 1                // VT_CAP
    .quad s_canon_begin
    .quad TC_SET_BEGIN
    .word P_NONE, 1
    .quad TC_O_BEGIN_RAW
    .quad TC_F_BEGIN_GIVEN
    .quad TC_O_BEGIN_RAW_SZ - 1              // VT_CAP
    .quad s_canon_since
    .quad TC_SET_SINCE
    .word P_NONE, 1
    .quad TC_O_SINCE_RAW
    .quad TC_F_SINCE_GIVEN
    .quad TC_O_SINCE_RAW_SZ - 1              // VT_CAP
    .quad s_canon_users
    .quad TC_SET_USERS
    .word P_POS_INT, 1
    .quad TC_O_USERS
    .quad TC_F_USERS_GIVEN
    .quad 0                                  // VT_CAP
    .quad s_canon_users_policy
    .quad TC_SET_USERS_POLICY
    .word P_USERS_POLICY, 1
    .quad TC_O_USERS_POLICY
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_users_max
    .quad TC_SET_USERS_MAX
    .word P_DURATION, 1
    .quad TC_O_USERS_MAX
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_end
    .quad TC_SET_END
    .word P_NONE, 1
    .quad TC_O_END_RAW
    .quad TC_F_END_GIVEN
    .quad TC_O_END_RAW_SZ - 1                // VT_CAP
    .quad s_canon_min_count
    .quad TC_SET_MIN_COUNT
    .word P_POS_INT, 1
    .quad TC_O_MIN_COUNT
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_by_state
    .quad TC_SET_SHOW
    .word P_NONE, 0
    .quad 0
    .quad TC_F_BY_STATE
    .quad 0                                  // VT_CAP
    .quad s_canon_show
    .quad TC_SET_SHOW
    .word P_METRICS, 1
    .quad TC_O_COLUMNS
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_sort
    .quad TC_SET_SORT
    .word P_SORT, 1
    .quad TC_O_SORT
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_share_floor
    .quad TC_SET_SHARE_FLOOR
    .word P_NONNEG_INT, 1
    .quad TC_O_SHARE_FLOOR
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_top
    .quad TC_SET_TOP
    .word P_NONNEG_INT, 1
    .quad TC_O_TOP
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_header
    .quad TC_SET_HEADER
    .word P_HEADER, 1
    .quad TC_O_HEADER_MODE
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_logs_dir
    .quad TC_SET_LOGS_DIR
    .word P_NONE, 1
    .quad TC_O_LOGS_DIR
    .quad 0
    .quad TC_O_LOGS_DIR_SZ - 1               // VT_CAP
    .quad s_canon_json
    .quad TC_SET_COLOR
    .word P_NONE, 0
    .quad 0
    .quad TC_F_JSON
    .quad 0                                  // VT_CAP
    .quad s_canon_watch
    .quad TC_SET_INTERVAL
    .word P_NONNEG_FLOAT, 2
    .quad TC_O_INTERVAL
    .quad TC_F_WATCH_PRESENT
    .quad 0                                  // VT_CAP
    .quad s_canon_watch_hold
    .quad TC_SET_HOLD
    .word P_NONNEG_FLOAT, 1
    .quad TC_O_HOLD
    .quad TC_F_WATCH_HOLD_GIVEN
    .quad 0                                  // VT_CAP
    .quad s_canon_color
    .quad TC_SET_COLOR
    .word P_CHOICES_COLOR, 1
    .quad TC_O_COLOR_MODE
    .quad TC_F_COLOR_GIVEN
    .quad 0                                  // VT_CAP
    .quad s_canon_live
    .quad TC_SET_STATE
    .word P_NONE, 0
    .quad 0
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_offline
    .quad TC_SET_STATE
    .word P_NONE, 0
    .quad 0
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_unknown
    .quad TC_SET_STATE
    .word P_NONE, 0
    .quad 0
    .quad 0
    .quad 0                                  // VT_CAP
    .quad s_canon_exclude
    .quad TC_SET_EXCLUDE
    .word P_NONE, 1
    .quad 0
    .quad TC_F_EXCL_GIVEN
    .quad 0                                  // VT_CAP
    .quad s_canon_exclude_group
    .quad TC_SET_EXCLUDE_GROUP
    .word P_NONE, 1
    .quad 0
    .quad TC_F_EXCL_GROUP_GIVEN
    .quad 0                                  // VT_CAP
    .quad s_canon_exclude_bcast
    .quad TC_SET_EXCLUDE_BCAST
    .word P_NONE, 0
    .quad 0
    .quad TC_F_EXCLUDE_BCAST
    .quad 0                                  // VT_CAP
    .quad s_canon_include
    .quad TC_SET_INCLUDE
    .word P_NONE, 1
    .quad 0
    .quad TC_F_INCL_GIVEN
    .quad 0                                  // VT_CAP
    .quad s_canon_no_exclude
    .quad TC_SET_EXCLUDE
    .word P_NONE, 0
    .quad 0
    .quad TC_F_NO_EXCLUDE
    .quad 0                                  // VT_CAP
    .quad s_canon_config
    .quad TC_SET_CONFIG
    .word P_NONE, 1
    .quad TC_O_CONFIG_PATH
    .quad TC_F_CONFIG_GIVEN
    .quad TC_O_CONFIG_PATH_SZ - 1            // VT_CAP
    .quad s_canon_no_config
    .quad TC_SET_CONFIG
    .word P_NONE, 0
    .quad 0
    .quad TC_F_NO_CONFIG
    .quad 0                                  // VT_CAP
    .quad s_canon_streamer
    .quad TC_SET_STREAMER_MODE
    .word P_NONE, 0
    .quad 0
    .quad TC_F_STREAMER
    .quad 0                                  // VT_CAP
    .quad s_canon_no_cache
    .quad TC_SET_COLOR
    .word P_NONE, 0
    .quad 0
    .quad TC_F_NO_CACHE
    .quad 0                                  // VT_CAP
    .quad s_canon_rebuild_cache
    .quad TC_SET_COLOR
    .word P_NONE, 0
    .quad 0
    .quad TC_F_REBUILD_CACHE
    .quad 0                                  // VT_CAP
    .quad s_canon_manual
    .quad TC_SET_COLOR
    .word P_NONE, 0
    .quad 0
    .quad TC_F_MANUAL
    .quad 0                                  // VT_CAP
    .quad s_canon_emit_fish
    .quad TC_SET_COLOR
    .word P_NONE, 0
    .quad 0
    .quad TC_F_EMIT_FISH
    .quad 0                                  // VT_CAP
    .quad s_canon_complete
    .quad TC_SET_COLOR
    .word P_CHOICES_COMPLETE, 1
    .quad TC_O_COMPLETE_KIND
    .quad TC_F_COMPLETE_GIVEN
    .quad 0                                  // VT_CAP
    .quad s_canon_help
    .quad TC_SET_COLOR
    .word P_NONE, 0
    .quad 0
    .quad 0
    .quad 0                                  // VT_CAP
// ============================================================================
// Short option map: {char, val} pairs, 0-terminated
// ============================================================================
cli_short_pairs:
    .byte 'B', VAL_BY_STATE
    .byte 'L', VAL_LIVE
    .byte 'O', VAL_OFFLINE
    .byte 'S', VAL_SINCE
    .byte 'U', VAL_UNKNOWN
    .byte 'b', VAL_BEGIN
    .byte 'c', VAL_CHANNEL
    .byte 'd', VAL_LOGS_DIR
    .byte 'e', VAL_END
    .byte 'g', VAL_EXCLUDE_GROUP
    .byte 'h', VAL_HELP
    .byte 'j', VAL_JSON
    .byte 'm', VAL_MIN_COUNT
    .byte 'n', VAL_TOP
    .byte 'w', VAL_WATCH
    .byte 'x', VAL_EXCLUDE
    .byte 0

// ============================================================================
// getopt_long longopts array (declaration order = abbreviation match order).
// Entry: {name, has_arg, pad, flag, val, pad} = 32 bytes.
// ============================================================================
    .p2align 3
cli_longopts:
    .quad lopt_help
    .word 0, 0
    .quad 0
    .word VAL_HELP
    .word 0
    .quad lopt_channel
    .word 1, 0
    .quad 0
    .word VAL_CHANNEL
    .word 0
    .quad lopt_begin
    .word 1, 0
    .quad 0
    .word VAL_BEGIN
    .word 0
    .quad lopt_since
    .word 1, 0
    .quad 0
    .word VAL_SINCE
    .word 0
    .quad lopt_users
    .word 1, 0
    .quad 0
    .word VAL_USERS
    .word 0
    .quad lopt_users_policy
    .word 1, 0
    .quad 0
    .word VAL_USERS_POLICY
    .word 0
    .quad lopt_users_max
    .word 1, 0
    .quad 0
    .word VAL_USERS_MAX
    .word 0
    .quad lopt_end
    .word 1, 0
    .quad 0
    .word VAL_END
    .word 0
    .quad lopt_min_count
    .word 1, 0
    .quad 0
    .word VAL_MIN_COUNT
    .word 0
    .quad lopt_by_state
    .word 0, 0
    .quad 0
    .word VAL_BY_STATE
    .word 0
    .quad lopt_show
    .word 1, 0
    .quad 0
    .word VAL_SHOW
    .word 0
    .quad lopt_sort
    .word 1, 0
    .quad 0
    .word VAL_SORT
    .word 0
    .quad lopt_share_floor
    .word 1, 0
    .quad 0
    .word VAL_SHARE_FLOOR
    .word 0
    .quad lopt_top
    .word 1, 0
    .quad 0
    .word VAL_TOP
    .word 0
    .quad lopt_header
    .word 1, 0
    .quad 0
    .word VAL_HEADER
    .word 0
    .quad lopt_logs_dir
    .word 1, 0
    .quad 0
    .word VAL_LOGS_DIR
    .word 0
    .quad lopt_json
    .word 0, 0
    .quad 0
    .word VAL_JSON
    .word 0
    .quad lopt_watch
    .word 2, 0
    .quad 0
    .word VAL_WATCH
    .word 0
    .quad lopt_watch_hold
    .word 1, 0
    .quad 0
    .word VAL_WATCH_HOLD
    .word 0
    .quad lopt_color
    .word 1, 0
    .quad 0
    .word VAL_COLOR
    .word 0
    .quad lopt_live
    .word 0, 0
    .quad 0
    .word VAL_LIVE
    .word 0
    .quad lopt_offline
    .word 0, 0
    .quad 0
    .word VAL_OFFLINE
    .word 0
    .quad lopt_unknown
    .word 0, 0
    .quad 0
    .word VAL_UNKNOWN
    .word 0
    .quad lopt_exclude
    .word 1, 0
    .quad 0
    .word VAL_EXCLUDE
    .word 0
    .quad lopt_exclude_group
    .word 1, 0
    .quad 0
    .word VAL_EXCLUDE_GROUP
    .word 0
    .quad lopt_exclude_broadcaster
    .word 0, 0
    .quad 0
    .word VAL_EXCLUDE_BCAST
    .word 0
    .quad lopt_include
    .word 1, 0
    .quad 0
    .word VAL_INCLUDE
    .word 0
    .quad lopt_no_exclude
    .word 0, 0
    .quad 0
    .word VAL_NO_EXCLUDE
    .word 0
    .quad lopt_config
    .word 1, 0
    .quad 0
    .word VAL_CONFIG
    .word 0
    .quad lopt_no_config
    .word 0, 0
    .quad 0
    .word VAL_NO_CONFIG
    .word 0
    .quad lopt_streamer
    .word 0, 0
    .quad 0
    .word VAL_STREAMER
    .word 0
    .quad lopt_no_cache
    .word 0, 0
    .quad 0
    .word VAL_NO_CACHE
    .word 0
    .quad lopt_rebuild_cache
    .word 0, 0
    .quad 0
    .word VAL_REBUILD_CACHE
    .word 0
    .quad lopt_manual
    .word 0, 0
    .quad 0
    .word VAL_MANUAL
    .word 0
    .quad lopt_emit_fish
    .word 0, 0
    .quad 0
    .word VAL_EMIT_FISH
    .word 0
    .quad lopt_complete
    .word 1, 0
    .quad 0
    .word VAL_COMPLETE
    .word 0
    .quad 0, 0, 0, 0, 0, 0

lopt_help:      .asciz "help"
lopt_channel:      .asciz "channel"
lopt_begin:      .asciz "begin"
lopt_since:      .asciz "since"
lopt_users:      .asciz "users"
lopt_users_policy:      .asciz "users-policy"
lopt_users_max:      .asciz "users-max"
lopt_end:      .asciz "end"
lopt_min_count:      .asciz "min-count"
lopt_by_state:      .asciz "by-state"
lopt_show:      .asciz "show"
lopt_sort:      .asciz "sort"
lopt_share_floor:      .asciz "share-floor"
lopt_top:      .asciz "top"
lopt_header:      .asciz "header"
lopt_logs_dir:      .asciz "logs-dir"
lopt_json:      .asciz "json"
lopt_watch:      .asciz "watch"
lopt_watch_hold:.asciz "watch-hold"
lopt_color:      .asciz "color"
lopt_live:      .asciz "live"
lopt_offline:      .asciz "offline"
lopt_unknown:      .asciz "unknown"
lopt_exclude:      .asciz "exclude"
lopt_exclude_group:      .asciz "exclude-group"
lopt_exclude_broadcaster:      .asciz "exclude-broadcaster"
lopt_include:      .asciz "include"
lopt_no_exclude:.asciz "no-exclude"
lopt_config:      .asciz "config"
lopt_no_config:      .asciz "no-config"
lopt_streamer:      .asciz "streamer"
lopt_no_cache:      .asciz "no-cache"
lopt_rebuild_cache:      .asciz "rebuild-cache"
lopt_manual:      .asciz "manual"
lopt_emit_fish:      .asciz "emit-fish-completions"
lopt_complete:      .asciz "complete"

optstring:
    .asciz "c:d:b:S:e:m:n:x:g:w::LOUBjh"

// ============================================================================
// The settings spec table — one 96-byte record per TC_SET id.
// ============================================================================
    .p2align 3
cli_spec_table:
    // TC_SET_CHANNEL
    .quad s_env_channel
    .quad s_key_channel
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_CHANNEL
    .quad TC_SRC_ENV_CHANNEL
    .quad TC_O_CHANNEL
    .quad TC_O_CHANNEL_SZ
    .quad s_flag_channel
    .quad 0
    // TC_SET_USERS_POLICY
    .quad s_env_users_policy
    .quad s_key_users_policy
    .quad TC_SEC_NONE
    .quad P_USERS_POLICY
    .quad s_def_at_least
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_USERS_POLICY
    .quad TC_SRC_ENV_USERS_POLICY
    .quad TC_O_USERS_POLICY
    .quad 0
    .quad s_flag_users_policy
    .quad 0
    // TC_SET_USERS_MAX
    .quad s_env_users_max
    .quad s_key_users_max
    .quad TC_SEC_NONE
    .quad P_DURATION
    .quad s_def_24h
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_USERS_MAX
    .quad TC_SRC_ENV_USERS_MAX
    .quad TC_O_USERS_MAX
    .quad 0
    .quad s_flag_users_max
    .quad 0
    // TC_SET_END
    .quad s_env_end
    .quad s_key_end
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_END
    .quad TC_SRC_ENV_END
    .quad TC_O_END_RAW
    .quad TC_O_END_RAW_SZ
    .quad s_flag_end
    .quad 0
    // TC_SET_MIN_COUNT
    .quad s_env_min_count
    .quad s_key_min_count
    .quad TC_SEC_NONE
    .quad P_POS_INT
    .quad s_def_1
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_MIN_COUNT
    .quad TC_SRC_ENV_MIN_COUNT
    .quad TC_O_MIN_COUNT
    .quad 0
    .quad s_flag_min_count
    .quad 0
    // TC_SET_SHOW
    .quad s_env_show
    .quad s_key_show
    .quad TC_SEC_NONE
    .quad P_METRICS
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_SHOW
    .quad TC_SRC_ENV_SHOW
    .quad TC_O_COLUMNS
    .quad 0
    .quad s_flag_show
    .quad 0
    // TC_SET_SORT
    .quad s_env_sort
    .quad s_key_sort
    .quad TC_SEC_NONE
    .quad P_SORT
    .quad s_def_count
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_SORT
    .quad TC_SRC_ENV_SORT
    .quad TC_O_SORT
    .quad 0
    .quad s_flag_sort
    .quad 0
    // TC_SET_SHARE_FLOOR
    .quad s_env_share_floor
    .quad s_key_share_floor
    .quad TC_SEC_NONE
    .quad P_NONNEG_INT
    .quad s_def_10
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_SHARE_FLOOR
    .quad TC_SRC_ENV_SHARE_FLOOR
    .quad TC_O_SHARE_FLOOR
    .quad 0
    .quad s_flag_share_floor
    .quad 0
    // TC_SET_TOP
    .quad s_env_top
    .quad s_key_top
    .quad TC_SEC_NONE
    .quad P_NONNEG_INT
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_TOP
    .quad TC_SRC_ENV_TOP
    .quad TC_O_TOP
    .quad 0
    .quad s_flag_top
    .quad 0
    // TC_SET_LOGS_DIR
    .quad s_env_logs_dir
    .quad s_key_logs_dir
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_LOGS_DIR
    .quad TC_SRC_ENV_LOGS_DIR
    .quad TC_O_LOGS_DIR
    .quad TC_O_LOGS_DIR_SZ
    .quad s_flag_logs_dir
    .quad 0
    // TC_SET_HEADER
    .quad s_env_header
    .quad s_key_header
    .quad TC_SEC_WATCH
    .quad P_HEADER
    .quad s_def_full
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_HEADER
    .quad TC_SRC_ENV_HEADER
    .quad TC_O_HEADER_MODE
    .quad 0
    .quad s_flag_header
    .quad 0
    // TC_SET_STATE
    .quad s_env_state
    .quad s_key_state
    .quad TC_SEC_NONE
    .quad P_STATE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_LIVE
    .quad TC_SRC_ENV_STATE
    .quad TC_O_STATE_FILTER
    .quad 0
    .quad s_flag_state
    .quad 0
    // TC_SET_INTERVAL
    .quad s_env_watch_interval
    .quad s_key_interval
    .quad TC_SEC_WATCH
    .quad P_NONNEG_FLOAT
    .quad s_def_1_0
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_INTERVAL
    .quad TC_O_INTERVAL
    .quad 0
    .quad s_flag_watch
    .quad 0
    // TC_SET_MIN_INTERVAL
    .quad s_env_watch_min_interval
    .quad s_key_min_interval
    .quad TC_SEC_WATCH
    .quad P_NONNEG_FLOAT
    .quad s_def_0_1
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_MIN_INTERVAL
    .quad TC_O_MIN_INTERVAL
    .quad 0
    .quad s_flag_watch_min_interval
    .quad 0
    // TC_SET_HOLD
    .quad s_env_watch_hold
    .quad s_key_hold
    .quad TC_SEC_WATCH
    .quad P_NONNEG_FLOAT
    .quad s_def_3_0
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH_HOLD
    .quad TC_SRC_ENV_WATCH_HOLD
    .quad TC_O_HOLD
    .quad 0
    .quad s_flag_watch_hold
    .quad 0
    // TC_SET_FADE_UP
    .quad s_env_watch_fade_up
    .quad s_key_fade_up
    .quad TC_SEC_WATCH
    .quad P_HEX
    .quad s_def_87ff87
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_FADE_UP
    .quad TC_O_FADE_UP_RGB
    .quad 0
    .quad s_flag_fade_up
    .quad TC_O_FADE_UP_RAW
    // TC_SET_FADE_DOWN
    .quad s_env_watch_fade_down
    .quad s_key_fade_down
    .quad TC_SEC_WATCH
    .quad P_HEX
    .quad s_def_8a8a8a
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_FADE_DOWN
    .quad TC_O_FADE_DOWN_RGB
    .quad 0
    .quad s_flag_fade_down
    .quad TC_O_FADE_DOWN_RAW
    // TC_SET_SHADES
    .quad s_env_watch_shades
    .quad s_key_shades
    .quad TC_SEC_WATCH
    .quad P_POS_INT
    .quad s_def_3
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_SHADES
    .quad TC_O_SHADES
    .quad 0
    .quad s_flag_shades
    .quad 0
    // TC_SET_USER_WIDTH
    .quad s_env_watch_user_width
    .quad s_key_user_width
    .quad TC_SEC_WATCH
    .quad P_NONNEG_INT
    .quad s_def_20
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_USER_WIDTH
    .quad TC_O_USER_WIDTH
    .quad 0
    .quad s_flag_user_width
    .quad 0
    // TC_SET_FULL_REPAINT
    .quad s_env_watch_full_repaint
    .quad s_key_full_repaint
    .quad TC_SEC_WATCH
    .quad P_NONNEG_INT
    .quad s_def_50
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_FULL_REPAINT
    .quad TC_O_FULL_REPAINT
    .quad 0
    .quad s_flag_full_repaint
    .quad 0
    // TC_SET_STREAMER_MODE
    .quad s_env_watch_streamer
    .quad s_key_streamer_mode
    .quad TC_SEC_WATCH
    .quad P_BOOL
    .quad s_def_false
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_STREAMER
    .quad TC_SRC_ENV_WATCH_STREAMER_MODE
    .quad TC_O_STREAMER_MODE
    .quad 0
    .quad s_flag_streamer
    .quad 0
    // TC_SET_MIN_REDRAW
    .quad s_env_watch_min_redraw
    .quad s_key_min_redraw
    .quad TC_SEC_WATCH
    .quad P_NONNEG_FLOAT
    .quad s_def_0_25
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_MIN_REDRAW
    .quad TC_O_MIN_REDRAW
    .quad 0
    .quad s_flag_min_redraw
    .quad 0
    // TC_SET_SHOW_TIMING
    .quad s_env_watch_show_timing
    .quad s_key_show_timing
    .quad TC_SEC_WATCH
    .quad P_BOOL
    .quad s_def_false
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_SHOW_TIMING
    .quad TC_O_SHOW_TIMING
    .quad 0
    .quad s_flag_show_timing
    .quad 0
    // TC_SET_TINT_FALLING
    .quad s_env_watch_tint_falling
    .quad s_key_tint_falling
    .quad TC_SEC_WATCH
    .quad P_BOOL
    .quad s_def_true
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_TINT_FALLING
    .quad TC_O_TINT_FALLING
    .quad 0
    .quad s_flag_tint_falling
    .quad 0
    // TC_SET_FADE_CURVE
    .quad s_env_watch_fade_curve
    .quad s_key_fade_curve
    .quad TC_SEC_WATCH
    .quad P_CURVE
    .quad s_def_linear
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_FADE_CURVE
    .quad TC_O_FADE_CURVE
    .quad 0
    .quad s_flag_fade_curve
    .quad 0
    // TC_SET_FADE_K
    .quad s_env_watch_fade_k
    .quad s_key_fade_k
    .quad TC_SEC_WATCH
    .quad P_POS_FLOAT
    .quad s_def_1_0
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_FADE_K
    .quad TC_O_FADE_K
    .quad 0
    .quad s_flag_fade_k
    .quad 0
    // TC_SET_HIGHLIGHT
    .quad s_env_watch_highlight
    .quad s_key_highlight
    .quad TC_SEC_WATCH
    .quad P_HIGHLIGHTS
    .quad 0
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_HIGHLIGHT
    .quad TC_O_HL_COUNT
    .quad 0
    .quad s_flag_highlight
    .quad 0
    // TC_SET_REPLAY_STEPS
    .quad s_env_watch_replay_steps
    .quad s_key_replay_steps
    .quad TC_SEC_WATCH
    .quad P_NONNEG_INT
    .quad s_def_200
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_WATCH_REPLAY_STEPS
    .quad TC_O_REPLAY_STEPS
    .quad 0
    .quad s_flag_replay_steps
    .quad 0
    // TC_SET_NOTIFY
    .quad s_env_tail_notify
    .quad s_key_notify
    .quad TC_SEC_TAIL
    .quad P_BOOL
    .quad s_def_true
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_TAIL_NOTIFY
    .quad TC_O_NOTIFY
    .quad 0
    .quad s_flag_notify
    .quad 0
    // TC_SET_MAX_EVENTS
    .quad s_env_tail_max_events
    .quad s_key_max_events
    .quad TC_SEC_TAIL
    .quad P_POS_INT
    .quad s_def_4
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_TAIL_MAX_EVENTS
    .quad TC_O_MAX_EVENTS
    .quad 0
    .quad s_flag_max_events
    .quad 0
    // TC_SET_SEED_LOOKBACK
    .quad s_env_tail_seed_lookback
    .quad s_key_seed_lookback
    .quad TC_SEC_TAIL
    .quad P_POS_INT
    .quad s_def_30
    .quad TC_SRC_DEFAULT_BUILTIN
    .quad TC_SRC_CLI_WATCH
    .quad TC_SRC_ENV_TAIL_SEED_LOOKBACK
    .quad TC_O_SEED_LOOKBACK
    .quad 0
    .quad s_flag_seed_lookback
    .quad 0
    // TC_SET_BEGIN (window-start; resolved by cli_resolve_window)
    .quad s_env_begin
    .quad s_key_begin
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_BEGIN
    .quad TC_SRC_ENV_BEGIN
    .quad TC_O_BEGIN_RAW
    .quad TC_O_BEGIN_RAW_SZ
    .quad s_flag_begin
    .quad 0
    // TC_SET_SINCE
    .quad s_env_since
    .quad s_key_since
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_SINCE
    .quad TC_SRC_ENV_SINCE
    .quad TC_O_SINCE_RAW
    .quad TC_O_SINCE_RAW_SZ
    .quad s_flag_since
    .quad 0
    // TC_SET_USERS (CLI only)
    .quad 0
    .quad 0
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_USERS
    .quad TC_SRC_NONE
    .quad TC_O_USERS
    .quad 0
    .quad s_flag_users
    .quad 0
    // TC_SET_EXCLUDE (repeatable)
    .quad s_env_exclude
    .quad 0
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_NONE
    .quad TC_SRC_CLI_EXCLUDE
    .quad TC_SRC_ENV_EXCLUDE
    .quad TC_O_EXCL_LIST
    .quad 0
    .quad s_flag_exclude
    .quad 0
    // TC_SET_EXCLUDE_GROUP (repeatable)
    .quad 0
    .quad 0
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_NONE
    .quad TC_SRC_CLI_EXCLUDE_GROUP
    .quad TC_SRC_NONE
    .quad TC_O_EXCL_GROUP_LIST
    .quad 0
    .quad s_flag_exclude_group
    .quad 0
    // TC_SET_EXCLUDE_BCAST
    .quad s_env_exclude_bcast
    .quad s_key_exclude_broadcaster
    .quad TC_SEC_NONE
    .quad P_BOOL
    .quad s_def_false
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_EXCLUDE_BCAST
    .quad TC_SRC_ENV_EXCLUDE_BCAST
    .quad TC_O_EXCL_BCAST_VAL
    .quad 0
    .quad s_flag_exclude_bcast
    .quad 0
    // TC_SET_INCLUDE (repeatable)
    .quad 0
    .quad 0
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_NONE
    .quad TC_SRC_CLI_INCLUDE
    .quad TC_SRC_NONE
    .quad TC_O_INCL_LIST
    .quad 0
    .quad s_flag_include
    .quad 0
    // TC_SET_CONFIG
    .quad 0
    .quad 0
    .quad TC_SEC_NONE
    .quad P_NONE
    .quad 0
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_CONFIG
    .quad TC_SRC_NONE
    .quad TC_O_CONFIG_PATH
    .quad TC_O_CONFIG_PATH_SZ
    .quad s_flag_config
    .quad 0
    // TC_SET_COLOR (hand-written)
    .quad 0
    .quad 0
    .quad TC_SEC_NONE
    .quad P_CHOICES_COLOR
    .quad s_def_auto
    .quad TC_SRC_DEFAULT
    .quad TC_SRC_CLI_COLOR
    .quad TC_SRC_NONE
    .quad TC_O_COLOR_MODE
    .quad 0
    .quad s_flag_color
    .quad 0

s_env_channel:      .asciz "TWITCH_CHANNEL"
s_env_users_policy: .asciz "TWITCH_USERS_POLICY"
s_env_users_max:    .asciz "TWITCH_USERS_MAX"
s_env_end:          .asciz "TWITCH_END"
s_env_min_count:    .asciz "TWITCH_MIN_COUNT"
s_env_show:         .asciz "TWITCH_SHOW"
s_env_sort:         .asciz "TWITCH_SORT"
s_env_share_floor:  .asciz "TWITCH_SHARE_FLOOR"
s_env_top:          .asciz "TWITCH_TOP"
s_env_logs_dir:     .asciz "TWITCH_LOGS_DIR"
s_env_header:       .asciz "TWITCH_HEADER"
s_env_state:        .asciz "TWITCH_STATE"
s_env_watch_interval:    .asciz "TWITCH_WATCH_INTERVAL"
s_env_watch_min_interval:.asciz "TWITCH_WATCH_MIN_INTERVAL"
s_env_watch_hold:        .asciz "TWITCH_WATCH_HOLD"
s_env_watch_fade_up:     .asciz "TWITCH_WATCH_FADE_UP"
s_env_watch_fade_down:   .asciz "TWITCH_WATCH_FADE_DOWN"
s_env_watch_shades:      .asciz "TWITCH_WATCH_SHADES"
s_env_watch_user_width:  .asciz "TWITCH_WATCH_USER_WIDTH"
s_env_watch_full_repaint:.asciz "TWITCH_WATCH_FULL_REPAINT"
s_env_watch_streamer:    .asciz "TWITCH_WATCH_STREAMER_MODE"
s_env_watch_min_redraw:  .asciz "TWITCH_WATCH_MIN_REDRAW"
s_env_watch_show_timing: .asciz "TWITCH_WATCH_SHOW_TIMING"
s_env_watch_tint_falling:.asciz "TWITCH_WATCH_TINT_FALLING"
s_env_watch_fade_curve:  .asciz "TWITCH_WATCH_FADE_CURVE"
s_env_watch_fade_k:      .asciz "TWITCH_WATCH_FADE_K"
s_env_watch_highlight:   .asciz "TWITCH_WATCH_HIGHLIGHT"
s_env_watch_replay_steps:.asciz "TWITCH_WATCH_REPLAY_STEPS"
s_env_tail_notify:       .asciz "TWITCH_TAIL_NOTIFY"
s_env_tail_max_events:   .asciz "TWITCH_TAIL_MAX_EVENTS"
s_env_tail_seed_lookback:.asciz "TWITCH_TAIL_SEED_LOOKBACK"
s_env_exclude:      .asciz "TWITCH_EXCLUDE"
s_env_exclude_bcast:.asciz "TWITCH_EXCLUDE_BROADCASTER"
s_key_channel:      .asciz "channel"
s_key_users_policy: .asciz "users_policy"
s_key_users_max:    .asciz "users_max"
s_key_end:          .asciz "end"
s_key_min_count:    .asciz "min_count"
s_key_show:         .asciz "show"
s_key_sort:         .asciz "sort"
s_key_share_floor:  .asciz "share_floor"
s_key_top:          .asciz "top"
s_key_logs_dir:     .asciz "logs_dir"
s_key_header:       .asciz "header"
s_key_state:        .asciz "state"
s_key_interval:     .asciz "interval"
s_key_min_interval: .asciz "min_interval"
s_key_hold:         .asciz "hold"
s_key_fade_up:      .asciz "fade_up"
s_key_fade_down:    .asciz "fade_down"
s_key_shades:       .asciz "shades"
s_key_user_width:   .asciz "user_width"
s_key_full_repaint: .asciz "full_repaint"
s_key_streamer_mode:.asciz "streamer_mode"
s_key_min_redraw:   .asciz "min_redraw"
s_key_show_timing:  .asciz "show_timing"
s_key_tint_falling: .asciz "tint_falling"
s_key_fade_curve:   .asciz "fade_curve"
s_key_fade_k:       .asciz "fade_k"
s_key_highlight:    .asciz "highlight"
s_key_replay_steps: .asciz "replay_steps"
s_key_notify:       .asciz "notify"
s_key_max_events:   .asciz "max_events"
s_key_seed_lookback:.asciz "seed_lookback"
    s_key_exclude_broadcaster: .asciz "exclude_broadcaster"
    // [[watch.highlight]] rule keys and the section key
    s_key_watch:       .asciz "watch"
    s_key_color:       .asciz "color"
    s_key_match:       .asciz "match"
    s_key_curve:       .asciz "curve"
    s_key_k:           .asciz "k"
    s_mode_r:          .asciz "r"
    // parse_highlights error text (byte-exact vs the Python)
    s_hl_must_be_list: .asciz "must be a list of tables"
    s_hl_expected_table: .asciz "expected a table with `color` and `match`"
    s_hl_needs_both:   .asciz "needs both `color` and `match`"
    s_hl_need_pattern: .asciz "`match` needs at least one pattern"
    s_hl_rule_pre:     .asciz "rule "
    s_hl_rule_mid:     .asciz ": "
    s_hl_bad_regex_mid:.asciz "' is not a valid regex ("
    s_hl_bad_regex_post:.asciz ")"
    // layout-cap errors (the contract caps these; Python has
    // no limits, so these texts are additions, documented in the Deviations)
    s_hl_too_many_rules: .asciz "too many highlight rules (max 32)"
    s_hl_too_many_pats:  .asciz "too many patterns (max 64)"
    s_hl_pat_long:       .asciz "pattern too long (max 255 characters)"
    s_hl_color_bad:      .asciz "color must be a string or a 3-integer array"
    .p2align 3
cli_hl_dbl_neg1:   .double -1.0
s_def_at_least:     .asciz "at-least"
s_def_24h:          .asciz "24h"
s_def_1:            .asciz "1"
s_def_count:        .asciz "count"
s_def_10:           .asciz "10"
s_def_full:         .asciz "full"
s_def_1_0:          .asciz "1.0"
s_def_0_1:          .asciz "0.1"
s_def_3_0:          .asciz "3.0"
s_def_87ff87:       .asciz "#87ff87"
s_def_8a8a8a:       .asciz "#8a8a8a"
s_def_3:            .asciz "3"
s_def_20:           .asciz "20"
s_def_50:           .asciz "50"
s_def_false:        .asciz "false"
s_def_0_25:         .asciz "0.25"
s_def_true:         .asciz "true"
s_def_linear:       .asciz "linear"
s_def_200:          .asciz "200"
s_def_4:            .asciz "4"
s_def_30:           .asciz "30"
s_def_auto:         .asciz "auto"
s_flag_channel:     .asciz "--channel"
s_flag_users:       .asciz "--users"
s_flag_users_policy:.asciz "--users-policy"
s_flag_users_max:   .asciz "--users-max"
s_flag_min_count:   .asciz "--min-count"
s_flag_show:        .asciz "--show"
s_flag_sort:        .asciz "--sort"
s_flag_share_floor: .asciz "--share-floor"
s_flag_top:         .asciz "--top"
s_flag_logs_dir:    .asciz "--logs-dir"
s_flag_header:      .asciz "--header"
s_flag_state:       .asciz "--live/--offline/--unknown"
s_flag_watch:       .asciz "--watch"
s_flag_watch_min_interval: .asciz "watch.min_interval"
s_flag_watch_hold:  .asciz "--watch-hold"
s_flag_fade_up:     .asciz "watch.fade_up"
s_flag_fade_down:   .asciz "watch.fade_down"
s_flag_shades:      .asciz "watch.shades"
s_flag_user_width:  .asciz "watch.user_width"
s_flag_full_repaint:.asciz "watch.full_repaint"
s_flag_streamer:    .asciz "--streamer"
s_flag_min_redraw:  .asciz "watch.min_redraw"
s_flag_show_timing: .asciz "watch.show_timing"
s_flag_tint_falling:.asciz "watch.tint_falling"
s_flag_fade_curve:  .asciz "watch.fade_curve"
s_flag_fade_k:      .asciz "watch.fade_k"
s_flag_highlight:   .asciz "watch.highlight"
s_flag_replay_steps:.asciz "watch.replay_steps"
s_flag_notify:      .asciz "tail.notify"
s_flag_max_events:  .asciz "tail.max_events"
s_flag_seed_lookback: .asciz "tail.seed_lookback"
s_flag_exclude:     .asciz "--exclude"
s_flag_exclude_group:.asciz "--exclude-group"
s_flag_exclude_bcast:.asciz "--exclude-broadcaster"
s_flag_include:     .asciz "--include"
s_flag_config:      .asciz "--config"
s_flag_color:       .asciz "--color"

// ============================================================================
// The source-string table (indexed by TC_SRC_* id)
// ============================================================================
    .p2align 3
cli_source_table:
    .quad 0
    .quad s_src_cli_channel
    .quad s_src_cli_users_policy
    .quad s_src_cli_users_max
    .quad s_src_cli_end
    .quad s_src_cli_min_count
    .quad s_src_cli_show
    .quad s_src_cli_sort
    .quad s_src_cli_share_floor
    .quad s_src_cli_top
    .quad s_src_cli_logs_dir
    .quad s_src_cli_header
    .quad s_src_cli_live
    .quad s_src_cli_offline
    .quad s_src_cli_unknown
    .quad s_src_cli_begin
    .quad s_src_cli_since
    .quad s_src_cli_users
    .quad s_src_cli_watch
    .quad s_src_cli_watch_hold
    .quad s_src_cli_exclude
    .quad s_src_cli_exclude_group
    .quad s_src_cli_exclude_bcast
    .quad s_src_cli_include
    .quad s_src_cli_config
    .quad s_src_cli_streamer
    .quad s_src_cli_color
    .quad s_src_cli_json
    .quad s_src_cli_by_state
    .quad s_src_cli_no_exclude
    .quad s_src_cli_no_config
    .quad s_src_cli_no_cache
    .quad s_src_cli_rebuild_cache
    .quad s_src_cli_manual
    .quad s_src_cli_emit_fish
    .quad s_src_cli_complete
    .quad s_src_cli_help
    .quad s_src_env_channel
    .quad s_src_env_users_policy
    .quad s_src_env_users_max
    .quad s_src_env_end
    .quad s_src_env_min_count
    .quad s_src_env_show
    .quad s_src_env_sort
    .quad s_src_env_share_floor
    .quad s_src_env_top
    .quad s_src_env_logs_dir
    .quad s_src_env_header
    .quad s_src_env_state
    .quad s_src_env_begin
    .quad s_src_env_since
    .quad s_src_env_exclude
    .quad s_src_env_exclude_bcast
    .quad s_src_env_watch_interval
    .quad s_src_env_watch_min_interval
    .quad s_src_env_watch_hold
    .quad s_src_env_watch_fade_up
    .quad s_src_env_watch_fade_down
    .quad s_src_env_watch_shades
    .quad s_src_env_watch_user_width
    .quad s_src_env_watch_full_repaint
    .quad s_src_env_watch_streamer_mode
    .quad s_src_env_watch_min_redraw
    .quad s_src_env_watch_show_timing
    .quad s_src_env_watch_tint_falling
    .quad s_src_env_watch_fade_curve
    .quad s_src_env_watch_fade_k
    .quad s_src_env_watch_highlight
    .quad s_src_env_watch_replay_steps
    .quad s_src_env_tail_notify
    .quad s_src_env_tail_max_events
    .quad s_src_env_tail_seed_lookback
    .quad s_src_config
    .quad s_src_config_watch
    .quad s_src_config_tail
    .quad s_src_default_builtin
    .quad s_src_default
    .quad s_src_default_now
    .quad s_src_default_earliest
    .quad s_src_default_under_watch
    .quad 0
    .quad 0
    .quad 0
    .quad s_src_excl_config
    .quad s_src_excl_always
    .quad s_src_excl_group
    .quad s_src_excl_env
    .quad s_src_config_begin
    .quad s_src_config_since

s_src_cli_channel:   .asciz "--channel"
s_src_cli_users_policy: .asciz "--users-policy"
s_src_cli_users_max: .asciz "--users-max"
s_src_cli_end:       .asciz "--end"
s_src_cli_min_count: .asciz "--min-count"
s_src_cli_show:      .asciz "--show"
s_src_cli_sort:      .asciz "--sort"
s_src_cli_share_floor: .asciz "--share-floor"
s_src_cli_top:       .asciz "--top"
s_src_cli_logs_dir:  .asciz "--logs-dir"
s_src_cli_header:    .asciz "--header"
s_src_cli_live:      .asciz "--live"
s_src_cli_offline:   .asciz "--offline"
s_src_cli_unknown:   .asciz "--unknown"
s_src_cli_begin:     .asciz "--begin"
s_src_cli_since:     .asciz "--since"
s_src_cli_users:     .asciz "--users"
s_src_cli_watch:     .asciz "--watch"
s_src_cli_watch_hold:.asciz "--watch-hold"
s_src_cli_exclude:   .asciz "--exclude"
s_src_cli_exclude_group: .asciz "--exclude-group"
s_src_cli_exclude_bcast: .asciz "--exclude-broadcaster"
s_src_cli_include:   .asciz "--include"
s_src_cli_config:    .asciz "--config"
s_src_cli_streamer:  .asciz "--streamer"
s_src_cli_color:     .asciz "--color"
s_src_cli_json:      .asciz "--json"
s_src_cli_by_state:  .asciz "--by-state"
s_src_cli_no_exclude:.asciz "--no-exclude"
s_src_cli_no_config: .asciz "--no-config"
s_src_cli_no_cache:  .asciz "--no-cache"
s_src_cli_rebuild_cache: .asciz "--rebuild-cache"
s_src_cli_manual:    .asciz "--manual"
s_src_cli_emit_fish: .asciz "--emit-fish-completions"
s_src_cli_complete:  .asciz "--complete"
s_src_cli_help:      .asciz "--help"
s_src_env_channel:   .asciz "env TWITCH_CHANNEL"
s_src_env_users_policy: .asciz "env TWITCH_USERS_POLICY"
s_src_env_users_max: .asciz "env TWITCH_USERS_MAX"
s_src_env_end:       .asciz "env TWITCH_END"
s_src_env_min_count: .asciz "env TWITCH_MIN_COUNT"
s_src_env_show:      .asciz "env TWITCH_SHOW"
s_src_env_sort:      .asciz "env TWITCH_SORT"
s_src_env_share_floor: .asciz "env TWITCH_SHARE_FLOOR"
s_src_env_top:       .asciz "env TWITCH_TOP"
s_src_env_logs_dir:  .asciz "env TWITCH_LOGS_DIR"
s_src_env_header:    .asciz "env TWITCH_HEADER"
s_src_env_state:     .asciz "env TWITCH_STATE"
s_src_env_begin:     .asciz "env TWITCH_BEGIN"
s_src_env_since:     .asciz "env TWITCH_SINCE"
s_src_env_exclude:   .asciz "env TWITCH_EXCLUDE"
s_src_env_exclude_bcast: .asciz "env TWITCH_EXCLUDE_BROADCASTER"
s_src_env_watch_interval: .asciz "env TWITCH_WATCH_INTERVAL"
s_src_env_watch_min_interval: .asciz "env TWITCH_WATCH_MIN_INTERVAL"
s_src_env_watch_hold: .asciz "env TWITCH_WATCH_HOLD"
s_src_env_watch_fade_up: .asciz "env TWITCH_WATCH_FADE_UP"
s_src_env_watch_fade_down: .asciz "env TWITCH_WATCH_FADE_DOWN"
s_src_env_watch_shades: .asciz "env TWITCH_WATCH_SHADES"
s_src_env_watch_user_width: .asciz "env TWITCH_WATCH_USER_WIDTH"
s_src_env_watch_full_repaint: .asciz "env TWITCH_WATCH_FULL_REPAINT"
s_src_env_watch_streamer_mode: .asciz "env TWITCH_WATCH_STREAMER_MODE"
s_src_env_watch_min_redraw: .asciz "env TWITCH_WATCH_MIN_REDRAW"
s_src_env_watch_show_timing: .asciz "env TWITCH_WATCH_SHOW_TIMING"
s_src_env_watch_tint_falling: .asciz "env TWITCH_WATCH_TINT_FALLING"
s_src_env_watch_fade_curve: .asciz "env TWITCH_WATCH_FADE_CURVE"
s_src_env_watch_fade_k: .asciz "env TWITCH_WATCH_FADE_K"
s_src_env_watch_highlight: .asciz "env TWITCH_WATCH_HIGHLIGHT"
s_src_env_watch_replay_steps: .asciz "env TWITCH_WATCH_REPLAY_STEPS"
s_src_env_tail_notify: .asciz "env TWITCH_TAIL_NOTIFY"
s_src_env_tail_max_events: .asciz "env TWITCH_TAIL_MAX_EVENTS"
s_src_env_tail_seed_lookback: .asciz "env TWITCH_TAIL_SEED_LOOKBACK"
s_src_config:        .asciz "config"
s_src_config_watch:  .asciz "config [watch]"
s_src_config_tail:   .asciz "config [tail]"
s_src_default_builtin: .asciz "built-in default"
s_src_default:       .asciz "default"
s_src_default_now:   .asciz "default: now"
s_src_default_earliest: .asciz "default: earliest log file"
s_src_default_under_watch: .asciz "default under --watch"
s_src_excl_config:   .asciz "config exclude"
s_src_excl_always:   .asciz "config always:"
s_src_excl_group:    .asciz "--exclude-group "
s_src_excl_env:      .asciz "env TWITCH_EXCLUDE"
s_src_config_begin:  .asciz "config begin"
s_src_config_since:  .asciz "config since"

// ============================================================================
// The usage parts, in argparse's order.  Python 3.13+ packs the usage one
// ACTION at a time (HelpFormatter._get_actions_usage_parts): a mutually
// exclusive group contributes one part per member, the brackets and '|'
// separators attached, so a group may break across lines at a '|'.
// ============================================================================
    .p2align 3
cli_usage_parts:
    .quad up_00
    .quad up_01
    .quad up_02
    .quad up_03
    .quad up_04
    .quad up_05
    .quad up_06
    .quad up_07
    .quad up_08
    .quad up_09
    .quad up_10
    .quad up_11
    .quad up_12
    .quad up_13
    .quad up_14
    .quad up_15
    .quad up_16
    .quad up_17
    .quad up_18
    .quad up_19
    .quad up_20
    .quad up_21
    .quad up_22
    .quad up_23
    .quad up_24
    .quad up_25
    .quad up_26
    .quad up_27
    .quad up_28
    .quad up_29
    .quad up_30
    .quad up_31
    .quad up_32
    .quad up_33
    .quad up_34
    .quad 0

up_00: .asciz "[-h]"
up_01: .asciz "[-c CHANNEL]"
up_02: .asciz "[-b BEGIN |"
up_03: .asciz "-S SINCE |"
up_04: .asciz "--users N]"
up_05: .asciz "[--users-policy HOW]"
up_06: .asciz "[--users-max DURATION]"
up_07: .asciz "[-e END]"
up_08: .asciz "[-m MIN_COUNT]"
up_09: .asciz "[-B]"
up_10: .asciz "[--show COL[,COL...]]"
up_11: .asciz "[--sort METRIC]"
up_12: .asciz "[--share-floor N]"
up_13: .asciz "[-n N]"
up_14: .asciz "[--header MODE]"
up_15: .asciz "[-d LOGS_DIR]"
up_16: .asciz "[-j |"
up_17: .asciz "-w [SECONDS]]"
up_18: .asciz "[--watch-hold SECONDS]"
up_19: .asciz "[--color {auto,always,never}]"
up_20: .asciz "[-L |"
up_21: .asciz "-O |"
up_22: .asciz "-U]"
up_23: .asciz "[-x LOGIN[,LOGIN...]]"
up_24: .asciz "[-g GROUP]"
up_25: .asciz "[--exclude-broadcaster]"
up_26: .asciz "[--include LOGIN[,LOGIN...]]"
up_27: .asciz "[--no-exclude]"
up_28: .asciz "[--config CONFIG |"
up_29: .asciz "--no-config]"
up_30: .asciz "[--streamer]"
up_31: .asciz "[--no-cache |"
up_32: .asciz "--rebuild-cache]"
up_33: .asciz "[--manual]"
up_34: .asciz "[--emit-fish-completions]"

// ============================================================================
// The help body (everything after the usage block)
// ============================================================================
help_body:
    .ascii "\n"
    .ascii "Count Chatterino chat messages per user for a channel and time range.\n"
    .ascii "\n"
    .ascii "options:\n"
    .ascii "  -h, --help            show this help message and exit\n"
    .ascii "  -c, --channel CHANNEL\n"
    .ascii "                        Twitch channel name (case-insensitive)\n"
    .ascii "  -b, --begin BEGIN     start of the range, e.g. '2026-07-01' (alternative to\n"
    .ascii "                        --since and --users)\n"
    .ascii "  -S, --since SINCE     start the range this far before --end, e.g. '30d'\n"
    .ascii "                        (alternative to --begin and --users)\n"
    .ascii "  --users N             size the window so N users meet --min-count, then hold\n"
    .ascii "                        that width\n"
    .ascii "  --users-policy HOW    how to settle when no window gives exactly --users:\n"
    .ascii "                        at-least, at-most or nearest (default: at-least)\n"
    .ascii "  --users-max DURATION  widest window --users may search (default: 24h)\n"
    .ascii "  -e, --end END         end of the range (default: now)\n"
    .ascii "  -m, --min-count MIN_COUNT\n"
    .ascii "                        only report users with at least this many messages\n"
    .ascii "                        (default: 1)\n"
    .ascii "  -B, --by-state        add live, offline and offline% columns (shorthand for\n"
    .ascii "                        --show)\n"
    .ascii "  --show COL[,COL...]   extra columns: live, live-share, offline, offline-\n"
    .ascii "                        share, unknown\n"
    .ascii "  --sort METRIC         order rows by: count, live, live-share, login,\n"
    .ascii "                        offline, offline-share, unknown (default: count)\n"
    .ascii "  --share-floor N       messages needed to be listed when a share is shown or\n"
    .ascii "                        sorted by, 0 to disable (default: 10)\n"
    .ascii "  -n, --top N           show at most N rows, 0 for unlimited (default: what\n"
    .ascii "                        fits the terminal; unlimited when piped)\n"
    .ascii "  --header MODE         provenance block: full, compact or none (default:\n"
    .ascii "                        full, or compact under --watch)\n"
    .ascii "  -d, --logs-dir LOGS_DIR\n"
    .ascii "                        Chatterino Twitch Channels directory\n"
    .ascii "  -j, --json            emit one JSON document with its own schema embedded\n"
    .ascii "  -w, --watch [SECONDS]\n"
    .ascii "                        redraw every SECONDS (default: watch.interval, 1),\n"
    .ascii "                        tinting a row green when its count rises and grey when\n"
    .ascii "                        it falls; a green still holding outranks a fall\n"
    .ascii "  --watch-hold SECONDS  how long a row stays tinted after it moves (default:\n"
    .ascii "                        watch.hold, 3s, one shade per 1/N of it; 0 holds\n"
    .ascii "                        indefinitely)\n"
    .ascii "  --color {auto,always,never}\n"
    .ascii "                        colour output (default: auto, meaning a terminal\n"
    .ascii "                        without NO_COLOR)\n"
    .ascii "  -L, --live            only messages sent while the channel was live\n"
    .ascii "  -O, --offline         only messages sent while the channel was offline\n"
    .ascii "  -U, --unknown         only messages no live/offline marker can place\n"
    .ascii "  -x, --exclude LOGIN[,LOGIN...]\n"
    .ascii "                        exclude these users; repeatable, comma-separated, ADDS\n"
    .ascii "                        to config exclusions\n"
    .ascii "  -g, --exclude-group GROUP\n"
    .ascii "                        exclude a group from the config's [exclude] table;\n"
    .ascii "                        repeatable\n"
    .ascii "  --exclude-broadcaster\n"
    .ascii "                        exclude the channel's own account\n"
    .ascii "  --include LOGIN[,LOGIN...]\n"
    .ascii "                        re-include users the merged exclusions would drop;\n"
    .ascii "                        repeatable\n"
    .ascii "  --no-exclude          ignore every exclusion for this run\n"
    .byte 0
help_body_b:
    .ascii "  --no-config           ignore the config file entirely\n"
    .ascii "  --streamer            streamer mode: no content highlights while watching\n"
    .ascii "  --no-cache            parse the logs instead of using the cache\n"
    .ascii "  --rebuild-cache       discard the cache and parse everything\n"
    .ascii "  --manual              print the full manual: config keys, layering, cache\n"
    .ascii "                        and watch behaviour\n"
    .ascii "  --emit-fish-completions\n"
    .ascii "                        print fish completions; redirect into\n"
    .ascii "                        ~/.config/fish/completions/\n"
    .ascii "\n"
    .ascii "Datetimes accept 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM[:SS]', or an ISO week\n"
    .ascii "('2026-W31', or '2026-W31-3' for its Wednesday); a bare date or week means its\n"
    .ascii "start for --begin and its end for --end, so '-b 2026-W31 -e 2026-W31' is\n"
    .ascii "exactly that week. The range is inclusive on both ends. Durations for --since\n"
    .ascii "look like '30d', '12h', '1w3d' ('m' is minutes). --users N sizes the window\n"
    .ascii "instead, widening it until N users meet --min-count and then holding that\n"
    .ascii "width. Any setting may instead come from an environment variable -- TWITCH_\n"
    .ascii "plus the flag name, or TWITCH_WATCH_/TWITCH_TAIL_ plus the config key for\n"
    .ascii "those tables -- or from the config file; --manual lists every one of them and\n"
    .ascii "the header reports which source was used. Exclusions are the exception to\n"
    .ascii "first-hit-wins: every layer adds to the set, so --exclude supplements the\n"
    .ascii "config rather than replacing it.\n"
    .byte 0

