// ============================================================================
// tc_watch.S — watch mode for twitch-counts-full (Phase 7, Wave D)
// ============================================================================
//
//  Target:     AArch64 (ARMv8-a), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static — musl libc + toml.o + sqlite3.o +
//              libpcre2-8.a (highlight-rule patterns)
//
//  Byte-for-byte port of the Python reference's watch mode:
//    resolve_watch / resolve_tail (3247-3323), color_enabled / fade_color /
//    palette_chooser / colorizer (3326-3432), visible_width / clip / Screen /
//    PollingWatcher (3435-3544), replay_horizon / session_floors /
//    replay_tints / launch_tints (3610-3692), watch_status /
//    next_tint_change / run_watch (3695-3829), plus the incremental engine
//    TailReader / LiveReaders / fold_windows / count_messages
//    (1662-2063) and hex_ramp / CURVES (929-956, 881-887).
//
//  Exported (all .global, AAPCS64; x19-x28 preserved)
//  --------------------------------------------------
//    tc_watch_run() -> x0 = 0 (clean exit) or 130 (SIGINT).
//      Called by main() when TC_F_WATCH_PRESENT is set, after tc_cli_parse,
//      tc_build_exclusions and tc_cache_open (the cache stays open for the
//      session; tc_cache_close runs after tc_watch_run returns).
//      Failures inside (non-tty, notify-on, min-interval, degenerate ramp)
//      print the exact Python ConfigError/Unsupported text via tc_report_fail
//      (text or --json shape) and exit 1; tc_watch_run never returns for them.
//      On SIGINT it restores the cursor and returns 130; main() decides the
//      "interrupted" error shape (JSON prints {"error": "interrupted"}).
//
//  How the loop keeps state between frames (the Python LiveReaders)
//  ----------------------------------------------------------------
//    * tc_watch_readers: one TailReader per in-range path.  Each reader keeps
//      a byte offset, a sorted per-second bucket array keyed
//      (second-of-day, login, state), the per-login highlight matches, the
//      live/offline state entering/exiting, and the last window/day output
//      records (stable pointers -> the fold-reuse shortcut works).
//    * tc_watch_days: whole-day memo (ymd, size, mtime_ns, enter) ->
//      (flattened counts, exit), served from the SQLite rollup via
//      tc_cache_day / tc_cache_put_day exactly like Python's readers.days +
//      Cache.get/put (partial days are never written or memoized).
//    * tc_watch_fold_wins: the last fold's window pointers + shape; when the
//      new gather returns the identical pointer list and no SQLite hit
//      occurred, the per-user table (tc_users) is reused instead of rebuilt.
//    * tc_watch_list_mtime: the listing memo (directory mtime_ns).
//    * tc_watch_seed_*: the stream-state seed memo keyed
//      (begin_ymd, earlier_last_ymd, size, mtime_ns).
//
//  Render integration (Phase 7 additions to tc_render.S, additive)
//  ----------------------------------------------------------------
//    tc_render_text is called with frame capture armed (tc_frame_begin) plus
//    the pinned login column (tc_frame_set_pin) and the row tint hook
//    (tc_frame_set_tint -> watch_tint_hook).  The hook implements the Python
//    colorizer per displayed row; the "+ N others" row is never tinted.
//    The frame capture gives the exact rendered lines, which the Screen
//    equivalent (watch_screen_paint) clips and diffs against the previous
//    painted frame.
//
//  Documented deviations from the Python (this port)
//  -------------------------------------------------
//    * [[watch.highlight]] rules were NOT parsed by the CLI when this phase
//      shipped (P_HIGHLIGHTS unimplemented), so TC_O_HL_COUNT was 0 and
//      highlights were inert; Wave E's tc_cli.S fills the contract fields
//      (tc_resolve_highlights) and this machinery is live.  The pcre2 compile
//      + matching machinery carries the rules the contract can hold.
//    * The stream-state seed scans the day-before files directly (the Python
//      may use the rollup's stored exit state; same result, one file read).
//    * On the first tick that discovers a warm whole-day rollup row for a
//      path the session has never read, the file is cold-read once to build
//      the day memo (Python reads the rollup only); the counts themselves
//      enter the fold identically and later ticks never re-read.
//    * config reload re-resolves watch/tail settings, the channel and the
//      exclusions; a config-sourced --begin/--since change mid-session is
//      not re-applied to the rolling window.
//    * The per-second buckets are a sorted array (binary-search insert)
//      rather than a dict + bisect list; identical semantics.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"

// ----------------------------------------------------------------------------
// Externals
// ----------------------------------------------------------------------------
    .globl isatty
    .globl ioctl
    .globl write
    .globl read
    .globl open
    .globl close
    .globl stat
    .globl opendir
    .globl readdir
    .globl closedir
    .globl lseek
    .globl localtime_r
    .globl memset
    .globl malloc
    .globl free
    .globl realloc
    .globl snprintf
    .globl pow
    .globl rint
    .globl clock_gettime
    .globl nanosleep
    .globl signal
    .globl fflush
    .globl strcmp
    .globl strtod
    .globl strtol
    .globl tc_strlen
    .globl tc_source_str
    .globl tc_config_get
    .globl tc_config_changed
    .globl tc_config_reload
    .globl tc_build_exclusions
    .globl tc_excl_contains
    .globl tc_resolve_channel
    .globl tc_channel_name
    .globl tc_count_column
    .globl find_user
    .globl add_user
    .globl tc_cache_day
    .globl tc_cache_put_day
    .globl tc_cache_discard_day
    .globl tc_cache_status
    .globl tc_cache_used
    .globl tc_plan_presentation
    .globl tc_render_text
    .globl tc_report_fail
    .globl tc_frame_begin
    .globl tc_frame_end
    .globl tc_frame_set_pin
    .globl tc_frame_set_tint
    .globl tc_misc_now_utc
    .globl tc_civil_from_days
    .globl pcre2_compile_8
    .globl pcre2_code_free_8
    .globl pcre2_match_8
    .globl pcre2_match_data_create_from_pattern_8
    .globl pcre2_match_data_free_8
    .globl pcre2_get_error_message_8

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ STDOUT,         1
    .equ STDERR,         2
    .equ O_RDONLY,       0
    .equ EINTR,          -4
    .equ SIGINT,         2
    .equ SEEK_SET,       0
    .equ CLOCK_MONOTONIC,1
    .equ CLOCK_REALTIME, 0
    .equ TIOCGWINSZ,     0x5413
    .equ SECS_PER_DAY,   86400
    .equ LAST_SECOND,    86399
    .equ FILE_CAP,       1073741824      // 1 GiB sanity cap (as tc_core.S)
    .equ READ_CHUNK,     65536

    // struct stat offsets (musl aarch64)
    .equ ST_DEV,         0
    .equ ST_INO,         8
    .equ ST_MODE,        16
    .equ ST_SIZE,        48
    .equ ST_MTIM_SEC,    88
    .equ ST_MTIM_NSEC,   96

    // dirent offsets (musl aarch64)
    .equ DT_TYPE,        18
    .equ DT_NAME,        19
    .equ DT_REG,         8

    // reader record offsets (READER_SZ 936)
    .equ RD_PATH,        0               // 704 path buffer
    .equ RD_FDATE,       704
    .equ RD_DEV,         712
    .equ RD_INO,         720
    .equ RD_SIZE,        728
    .equ RD_MTIME,       736
    .equ RD_OFFSET,      744
    .equ RD_REVISION,    752
    .equ RD_PARTIAL,     760
    .equ RD_FULLREADS,   768
    .equ RD_APPENDS,     776
    .equ RD_ENTER,       784
    .equ RD_EXIT,        792
    .equ RD_REMAINDER,   800             // ptr (0 = none)
    .equ RD_REM_LEN,     808
    .equ RD_BUCKETS,     816             // ptr
    .equ RD_BUCKET_N,    824
    .equ RD_BUCKET_CAP,  832
    .equ RD_MATCHES,     840             // ptr
    .equ RD_MATCH_N,     848
    .equ RD_MATCH_CAP,   856
    .equ RD_WINDOW,      864             // ptr (last window record)
    .equ RD_WIN_N,       872
    .equ RD_WIN_CAP,     880
    .equ RD_WIN_LO,      888
    .equ RD_WIN_HI,      896
    .equ RD_WIN_REV,     904
    .equ RD_DAY,         912             // ptr (day record)
    .equ RD_DAY_N,       920
    .equ RD_DAY_CAP,     928
    .equ RD_DAY_REV,     936             // revision at the last day build
    .equ RD_TEXT_BASE,   944             // malloc base of the read text buffer
    .equ READER_SZ,      952

    // bucket record (BK_SZ 48), sorted by (second, login, state)
    .equ BK_SECOND,      0
    .equ BK_LOGIN,       8
    .equ BK_STATE,       34
    .equ BK_N,           40
    .equ BK_SZ,          48

    // match record (MT_SZ 40): {second, login[26], rule u8}
    .equ MT_SECOND,      0
    .equ MT_LOGIN,       8
    .equ MT_RULE,        34
    .equ MT_SZ,          40

    // window/day record (WW_SZ 40): {login[26], state u8, n u64}
    .equ WW_LOGIN,       0
    .equ WW_STATE,       26
    .equ WW_N,           32
    .equ WW_SZ,          40

    // day memo record (DM_SZ 64)
    .equ DM_YMD,         0
    .equ DM_SIZE,        8
    .equ DM_MTIME,       16
    .equ DM_ENTER,       24
    .equ DM_EXIT,        32
    .equ DM_COUNTS,      40              // ptr to WW array
    .equ DM_COUNT,       48
    .equ DM_CAP,         56
    .equ DM_SZ,          64

    // tint record (TT_SZ 40): {login[26], dir u8, when double}
    .equ TT_LOGIN,       0
    .equ TT_DIR,         26              // 1 = up, 2 = down
    .equ TT_WHEN,        32
    .equ TT_SZ,          40

    // previous-count record (PV_SZ 40): {login[26], count u64}
    .equ PV_LOGIN,       0
    .equ PV_COUNT,       32
    .equ PV_SZ,          40

    .equ TINT_MAX,       256
    .equ PREV_MAX,       256
    .equ FRAME_LINE_SZ,  2048
    .equ WW_MAX,         256             // max entries in a window/day record
    .equ BK_INIT,        64
    .equ MT_INIT,        32
    .equ READER_INIT,    8
    .equ DAYS_INIT,      8
    .equ WINLIST_INIT,   16
    .equ SEARCH_MAX,     16              // probe-result memo for --users sizing
    .equ RAMP_MAX,       16
    .equ SHADES_MAX,     64
    .equ SHADE_SZ,       32
    .equ NANOSEC,        1000000000

    // ramp key ids
    .equ RAMP_UP,        0
    .equ RAMP_DOWN,      1

    // status of reader refresh
    .equ RD_OK_NEW,      1               // anything was read
    .equ RD_OK_NONE,     0               // nothing appended
    .equ RD_ERR,         -1              // open/read failed

    // value parsers (mirror tc_cli.S's P_* ids; tc_cli.S is frozen)
    .equ P_POS_INT,      1
    .equ P_NONNEG_INT,   2
    .equ P_NONNEG_FLOAT, 3
    .equ P_POS_FLOAT,    4
    .equ P_BOOL,         13
    .equ P_CURVE,        14
    .equ P_HEX,          15

    // tc_render.S's reported-row offsets (ROW_SZ = 72)
    .equ ROW_LOGIN,      0
    .equ ROW_COUNT,      32

// ----------------------------------------------------------------------------
// .bss — watch-session state (private; not part of the frozen contract)
// ----------------------------------------------------------------------------
    .bss
    .p2align 4
    // resolved watch settings (mirrors the Python WatchSettings + sources)
tc_watch_interval:   .skip 8             // double
tc_watch_hold:       .skip 8             // double
tc_watch_min_redraw: .skip 8             // double
tc_watch_min_interval:.skip 8            // double
tc_watch_fade_k:     .skip 8             // double
tc_watch_retain_seconds: .skip 8         // double (replay horizon)
tc_watch_match_seconds:  .skip 8         // double (max(hold,0))
tc_watch_shades:     .skip 8             // u64
tc_watch_replay_steps:.skip 8            // u64
tc_watch_full_repaint:.skip 8            // u64
tc_watch_show_timing:.skip 8             // u64 0/1
tc_watch_tint_falling:.skip 8            // u64 0/1
tc_watch_fade_curve: .skip 8             // u64 TC_CURVE_*
tc_watch_user_width: .skip 8             // u64
tc_watch_streamer:   .skip 8             // u64 0/1
tc_watch_interval_src:.skip 8            // u64 source id
tc_watch_hold_src:   .skip 8             // u64 source id
tc_watch_notify:     .skip 8             // u64 0/1
tc_watch_max_events: .skip 8
tc_watch_seed_lookback:.skip 8
    // Byte offsets of the settings block fields from tc_watch_interval (its
    // base).  Apple's assembler cannot fold a label difference inside an
    // operand, so code addresses siblings through these constants; the
    // .if guard below fails the build on either platform if they drift.
    .equ WS_INTERVAL,               0
    .equ WS_HOLD,                   8
    .equ WS_MIN_REDRAW,             16
    .equ WS_MIN_INTERVAL,           24
    .equ WS_FADE_K,                 32
    .equ WS_RETAIN_SECONDS,         40
    .equ WS_MATCH_SECONDS,          48
    .equ WS_SHADES,                 56
    .equ WS_REPLAY_STEPS,           64
    .equ WS_FULL_REPAINT,           72
    .equ WS_SHOW_TIMING,            80
    .equ WS_TINT_FALLING,           88
    .equ WS_FADE_CURVE,             96
    .equ WS_USER_WIDTH,             104
    .equ WS_STREAMER,               112
    .equ WS_INTERVAL_SRC,           120
    .equ WS_HOLD_SRC,               128
    .equ WS_NOTIFY,                 136
    .equ WS_MAX_EVENTS,             144
    .equ WS_SEED_LOOKBACK,          152
    .equ WS_SETTINGS_SIZE,       160
    .if (tc_watch_interval - tc_watch_interval) != WS_INTERVAL
    .error "tc_watch settings block drifted: tc_watch_interval"
    .endif
    .if (tc_watch_hold - tc_watch_interval) != WS_HOLD
    .error "tc_watch settings block drifted: tc_watch_hold"
    .endif
    .if (tc_watch_min_redraw - tc_watch_interval) != WS_MIN_REDRAW
    .error "tc_watch settings block drifted: tc_watch_min_redraw"
    .endif
    .if (tc_watch_min_interval - tc_watch_interval) != WS_MIN_INTERVAL
    .error "tc_watch settings block drifted: tc_watch_min_interval"
    .endif
    .if (tc_watch_fade_k - tc_watch_interval) != WS_FADE_K
    .error "tc_watch settings block drifted: tc_watch_fade_k"
    .endif
    .if (tc_watch_retain_seconds - tc_watch_interval) != WS_RETAIN_SECONDS
    .error "tc_watch settings block drifted: tc_watch_retain_seconds"
    .endif
    .if (tc_watch_match_seconds - tc_watch_interval) != WS_MATCH_SECONDS
    .error "tc_watch settings block drifted: tc_watch_match_seconds"
    .endif
    .if (tc_watch_shades - tc_watch_interval) != WS_SHADES
    .error "tc_watch settings block drifted: tc_watch_shades"
    .endif
    .if (tc_watch_replay_steps - tc_watch_interval) != WS_REPLAY_STEPS
    .error "tc_watch settings block drifted: tc_watch_replay_steps"
    .endif
    .if (tc_watch_full_repaint - tc_watch_interval) != WS_FULL_REPAINT
    .error "tc_watch settings block drifted: tc_watch_full_repaint"
    .endif
    .if (tc_watch_show_timing - tc_watch_interval) != WS_SHOW_TIMING
    .error "tc_watch settings block drifted: tc_watch_show_timing"
    .endif
    .if (tc_watch_tint_falling - tc_watch_interval) != WS_TINT_FALLING
    .error "tc_watch settings block drifted: tc_watch_tint_falling"
    .endif
    .if (tc_watch_fade_curve - tc_watch_interval) != WS_FADE_CURVE
    .error "tc_watch settings block drifted: tc_watch_fade_curve"
    .endif
    .if (tc_watch_user_width - tc_watch_interval) != WS_USER_WIDTH
    .error "tc_watch settings block drifted: tc_watch_user_width"
    .endif
    .if (tc_watch_streamer - tc_watch_interval) != WS_STREAMER
    .error "tc_watch settings block drifted: tc_watch_streamer"
    .endif
    .if (tc_watch_interval_src - tc_watch_interval) != WS_INTERVAL_SRC
    .error "tc_watch settings block drifted: tc_watch_interval_src"
    .endif
    .if (tc_watch_hold_src - tc_watch_interval) != WS_HOLD_SRC
    .error "tc_watch settings block drifted: tc_watch_hold_src"
    .endif
    .if (tc_watch_notify - tc_watch_interval) != WS_NOTIFY
    .error "tc_watch settings block drifted: tc_watch_notify"
    .endif
    .if (tc_watch_max_events - tc_watch_interval) != WS_MAX_EVENTS
    .error "tc_watch settings block drifted: tc_watch_max_events"
    .endif
    .if (tc_watch_seed_lookback - tc_watch_interval) != WS_SEED_LOOKBACK
    .error "tc_watch settings block drifted: tc_watch_seed_lookback"
    .endif

    // loop / window state
tc_watch_win_width:  .skip 8             // u64 sliding width in seconds
tc_watch_end_given:  .skip 8             // u64 1 = explicit --end
tc_watch_first:      .skip 8             // u64 1 until the first loop tick
tc_watch_painted_at: .skip 8             // double monotonic (0 = never)
tc_watch_started:    .skip 8             // double monotonic (tick start)
tc_watch_elapsed:    .skip 8             // double
tc_watch_cur_state:  .skip 8             // u64 0 unknown / 1 live / 2 offline
tc_watch_interrupted:.skip 8             // u64 set by the SIGINT handler
tc_watch_seeking:    .skip 8             // u64 1 during --users sizing probes
tc_watch_prev_n:     .skip 8
tc_watch_tint_count: .skip 8
tc_watch_now:        .skip 8             // double monotonic scratch
tc_watch_dtmp:       .skip 8             // double scratch (d-regs die on bl)

    // ramps: descriptor array {base, count} + one contiguous arena
tc_watch_ramp_count: .skip 8
tc_watch_ramps:      .skip RAMP_MAX * 16
tc_watch_ramp_arena: .skip RAMP_MAX * SHADES_MAX * SHADE_SZ

    // tints (carried): login -> (direction, when-monotonic)
tc_watch_tints:      .skip TINT_MAX * TT_SZ
    // previous frame counts: login -> count-column
tc_watch_prev:       .skip PREV_MAX * PV_SZ

    // frame capture (grows via realloc; tc_frame_begin arms these)
tc_watch_lines:      .skip 8             // ptr to array of char*
tc_watch_linebuf:    .skip 8             // ptr to contiguous line storage
tc_watch_frame_cap:  .skip 8             // current line count capacity

    // screen state
tc_watch_painted:    .skip 8             // ptr to array of char* (copies)
tc_watch_painted_block:.skip 8           // ptr to the copy storage
tc_watch_painted_cap:.skip 8
tc_watch_painted_n:  .skip 8
tc_watch_screen_width:.skip 8
tc_watch_since_full: .skip 8
tc_watch_burst:      .skip 8             // ptr to the write burst buffer
tc_watch_burst_cap:  .skip 8

    // readers: array of reader pointers
tc_watch_readers:    .skip 8
tc_watch_reader_n:   .skip 8
tc_watch_reader_cap: .skip 8

    // days memo: array of DM records
tc_watch_days:       .skip 8
tc_watch_days_n:     .skip 8
tc_watch_days_cap:   .skip 8

    // listing memo
tc_watch_list_mtime: .skip 8
tc_watch_list_have:  .skip 8

    // fold reuse (previous shape + window pointers)
tc_watch_fold_n:     .skip 8
tc_watch_fold_shape: .skip 8             // state_filter
tc_watch_fold_sqlite:.skip 8
tc_watch_fold_wins:  .skip 256 * 8

    // current gather windows list
tc_watch_wins:       .skip 8             // ptr to malloc'd ptr array
tc_watch_wins_cap:   .skip 8
tc_watch_win_n:      .skip 8
tc_watch_sqlite_hit: .skip 8

    // seed memo
tc_watch_seed_key1:  .skip 8
tc_watch_seed_key2:  .skip 8
tc_watch_seed_key3:  .skip 8
tc_watch_seed_key4:  .skip 8
tc_watch_seed_val:   .skip 8

    // gather bookkeeping (written into tc_tally after the fold)
tc_watch_g_files:    .skip 8
tc_watch_g_parsed:   .skip 8
tc_watch_g_reused:   .skip 8
tc_watch_g_unr_n:    .skip 8
tc_watch_g_unr:      .skip 64 * 96       // {name[64], reason[32]}
    // gather shared state (set by watch_gather, read by watch_gather_file)
tc_watch_g_begin:    .skip 8             // begin epoch
tc_watch_g_end:      .skip 8             // end epoch
tc_watch_g_begin_ymd:.skip 8
tc_watch_g_end_ymd:  .skip 8
tc_watch_g_enter:    .skip 8             // entering state (in/out per file)
tc_watch_g_cache:    .skip 8             // cache_used

    // --users sizing probe memo
tc_watch_search_n:   .skip 8
tc_watch_search_w:   .skip SEARCH_MAX * 8
tc_watch_search_r:   .skip SEARCH_MAX * 8

    // pcre2 compiled patterns (TC_HL_MAX rules x TC_HL_PAT_MAX patterns)
tc_watch_patterns:   .skip TC_HL_MAX * TC_HL_PAT_MAX * 8
tc_watch_match_data: .skip TC_HL_MAX * TC_HL_PAT_MAX * 8

    // scratch buffers
tc_watch_dirpath:    .skip 704
tc_watch_fpath:      .skip 704
tc_watch_scratch:    .skip 2048
tc_watch_scratch2:   .skip 8192
tc_watch_tintbuf:    .skip 4096
tc_watch_clipbuf:    .skip 4096
tc_watch_status:     .skip 256
tc_watch_errbuf:     .skip 512
tc_watch_want:       .skip 16            // "HH:MM:SS" for the cold-read seek
tc_watch_ts:         .skip 16            // clock_gettime / nanosleep ts
tc_watch_ts2:        .skip 16
tc_watch_join_old:   .skip 8             // old chunk base during remainder join
tc_watch_tm:         .skip 64            // struct tm (localtime_r)
tc_watch_stat:       .skip 128           // struct stat (musl aarch64: 128 bytes)
tc_watch_choose_wall:.skip 8             // epoch seconds (palette chooser)
tc_watch_choose_hold:.skip 8             // double
tc_watch_highlight_on:.skip 8            // u64 1 when highlight rules exist

// ----------------------------------------------------------------------------
// .rodata
// ----------------------------------------------------------------------------
    RODATA
s_need_tty:         .asciz "--watch needs a terminal (it repaints in place)"
s_todo_notify:      .asciz "TODO - not implemented: change notification on Linux. set [tail] notify = false to poll on the interval instead"

s_watching_pre:     .asciz "watching -- "
s_watching_post:    .asciz " -- Ctrl-C to stop"
s_every:            .asciz "every "
s_s_paren:          .asciz "s ("
s_close_paren:      .asciz "), hold "
s_hold_mid:         .asciz "), hold "
s_hold_s:           .asciz "s"
s_open_paren:       .asciz " ("
s_close_paren2:     .asciz ")"
s_indefinite:       .asciz "indefinite"
s_tick_ms:          .asciz ", tick "
s_ms:               .asciz "ms"
s_slower:           .asciz " -- "
s_ms_slower:        .asciz "ms tick, slower than the interval"
s_blank:            .asciz ""

s_int_min_pre:      .asciz ": interval must be at least "
s_int_min_mid:      .asciz "s ("
s_int_min_post:     .asciz ")"
s_from_paren:       .asciz " (from "
s_fade_collapse:    .asciz " with fade_k "
s_collapse_mid:     .asciz " collapses the "
s_collapse_post:    .asciz " ramp to a single colour -- lower k, or raise watch.shades"
s_rule_bad_regex:   .asciz " is not a valid regex ("
s_rule_pre:         .asciz "rule "
s_rule_mid:         .asciz ": '"
s_rule_post:        .asciz "')"
s_oom:              .asciz "out of memory"

s_cursor_hide:      .asciz "\033[?25l"
s_cursor_show:      .asciz "\033[?25h\n"
s_full_pre:         .asciz "\033[2J\033[H"
s_line_k:           .asciz "\033[K\n"
s_full_post:        .asciz "\033[J"
s_home_fmt:         .asciz "\033[%d;1H"
s_clr_eol:          .asciz "\033[K"
s_clr_below:        .asciz "\033[J"
s_reset:            .asciz "\033[0m"
s_esc_38:           .asciz "\033[38;2;"
s_m:                .asciz "m"

s_curve_linear:     .asciz "linear"
s_curve_power:      .asciz "power"
s_curve_ease_out:   .asciz "ease-out"
s_curve_bias:       .asciz "bias"
s_curve_ease_in_out:.asciz "ease-in-out"
    .p2align 3
watch_curve_names:  .quad s_curve_linear
                    .quad s_curve_power
                    .quad s_curve_ease_out
                    .quad s_curve_bias
                    .quad s_curve_ease_in_out

s_cannot_read:      .asciz "cannot read"
s_slash:            .asciz "/"
s_up:               .asciz "up"
s_down:             .asciz "down"
s_highlight:        .asciz "highlight"

s_watch_flag:       .asciz "--watch"
s_min_interval_flag:.asciz "watch.min_interval"
fmt_g:              .asciz "%g"
fmt_0f:             .asciz "%.0f"
dbl_nanosec:        .double 1000000000.0

// config keys / sections for re-resolution
s_key_interval:     .asciz "interval"
s_key_hold:         .asciz "hold"
s_key_min_redraw:   .asciz "min_redraw"
s_key_shades:       .asciz "shades"
s_key_show_timing:  .asciz "show_timing"
s_key_fade_curve:   .asciz "fade_curve"
s_key_fade_k:       .asciz "fade_k"
s_key_fade_up:      .asciz "fade_up"
s_key_fade_down:    .asciz "fade_down"
s_key_user_width:   .asciz "user_width"
s_key_streamer_mode:.asciz "streamer_mode"
s_key_notify:       .asciz "notify"
s_key_max_events:   .asciz "max_events"
s_key_seed_lookback:.asciz "seed_lookback"
s_key_channel:      .asciz "channel"

    .text
// ============================================================================
// tc_watch_run — the watch entry point (see header).
// ============================================================================
    .p2align 2
    .global tc_watch_run
    FUNC_TYPE(tc_watch_run)
tc_watch_run:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // ---- terminal check --------------------------------------------------
    mov x0, #STDOUT
    bl isatty
    cbnz w0, .Lwr_tty_ok
    adrp x0, PAGE(s_need_tty)
    add x0, x0, LO12(s_need_tty)
    bl tc_report_fail                 // noreturn
.Lwr_tty_ok:
    // ---- resolve settings, ramps, patterns, tail -------------------------
    bl watch_load_settings
    bl watch_build_ramps
    bl watch_compile_patterns
    bl watch_load_tail
    adrp x9, PAGE(tc_watch_notify)
    add x9, x9, LO12(tc_watch_notify)
    ldr x9, [x9]
    cbz x9, .Lwr_notify_ok
    adrp x0, PAGE(s_todo_notify)
    add x0, x0, LO12(s_todo_notify)
    bl tc_report_fail                 // noreturn
.Lwr_notify_ok:
    // ---- channel + listing + window --------------------------------------
    bl tc_resolve_channel
    bl watch_build_dirpath
    bl watch_build_listing            // memoized; fills tc_listing
    bl watch_init_window
    bl watch_build_listing            // memoized; fills tc_listing
    bl watch_init_window
    bl watch_size_users               // --users bisection (no-op otherwise)
    bl watch_seed_state               // -> x0 entering state
    adrp x9, PAGE(tc_watch_cur_state)
    add x9, x9, LO12(tc_watch_cur_state)
    str x0, [x9]
    // ---- prime the readers (cold read) ------------------------------------
    bl watch_roll_window              // end = now, begin slides
    bl watch_count_tick               // cold reads + fold + bookkeeping
    // ---- launch replay: reconstruct the tint state ------------------------
    bl watch_launch_tints
    // ---- hide the cursor and run the loop ---------------------------------
    adrp x0, PAGE(s_cursor_hide)
    add x0, x0, LO12(s_cursor_hide)
    bl tc_puts
    mov x0, #SIGINT
    adrp x1, PAGE(watch_sigint_handler)
    add x1, x1, LO12(watch_sigint_handler)
    bl signal
    mov x19, #0                       // x19 = loop flag (0 running)
.Lwr_loop:
    adrp x9, PAGE(tc_watch_interrupted)
    add x9, x9, LO12(tc_watch_interrupted)
    ldr x9, [x9]
    cbnz x9, .Lwr_done
    // min_redraw floor
    adrp x9, PAGE(tc_watch_painted_at)
    add x9, x9, LO12(tc_watch_painted_at)
    ldr d0, [x9]
    fcvtzu x10, d0
    cbz x10, .Lwr_minredraw_done      // never painted
    adrp x9, PAGE(tc_watch_min_redraw)
    add x9, x9, LO12(tc_watch_min_redraw)
    ldr d0, [x9]
    fcmp d0, #0.0
    b.le .Lwr_minredraw_done
    bl watch_monotonic                // d0 = now
    adrp x9, PAGE(tc_watch_painted_at)
    add x9, x9, LO12(tc_watch_painted_at)
    ldr d1, [x9]
    fsub d0, d0, d1
    adrp x9, PAGE(tc_watch_min_redraw)
    add x9, x9, LO12(tc_watch_min_redraw)
    ldr d1, [x9]
    fsub d0, d1, d0                   // early
    fcmp d0, #0.0
    b.le .Lwr_minredraw_done
    bl watch_sleep
.Lwr_minredraw_done:
    adrp x9, PAGE(tc_watch_interrupted)
    add x9, x9, LO12(tc_watch_interrupted)
    ldr x9, [x9]
    cbnz x9, .Lwr_done
    // ---- tick -------------------------------------------------------------
    bl watch_monotonic
    adrp x9, PAGE(tc_watch_started)
    add x9, x9, LO12(tc_watch_started)
    str d0, [x9]
    // config memo: reload + re-resolve when the file changed
    bl tc_config_changed
    cbz x0, .Lwr_cfg_ok
    bl tc_config_reload
    bl tc_build_exclusions
    bl watch_reresolve_settings
    bl watch_build_ramps
    bl watch_compile_patterns
    bl watch_load_tail
.Lwr_cfg_ok:
    bl watch_roll_window
    bl watch_count_tick
    bl watch_free_plan
    bl tc_plan_presentation
    // ---- frame capture ----------------------------------------------------
    bl watch_prepare_frame           // allocate line buffers for this frame
    adrp x9, PAGE(tc_watch_user_width)
    add x9, x9, LO12(tc_watch_user_width)
    ldr x0, [x9]
    bl tc_frame_set_pin
    adrp x0, PAGE(watch_tint_hook)
    add x0, x0, LO12(watch_tint_hook)
    mov x1, #0
    bl tc_frame_set_tint
    adrp x0, PAGE(tc_watch_lines)
    add x0, x0, LO12(tc_watch_lines)
    ldr x0, [x0]
    adrp x1, PAGE(tc_watch_frame_cap)
    add x1, x1, LO12(tc_watch_frame_cap)
    ldr x1, [x1]
    bl tc_frame_begin
    bl watch_filter_tints            // expire carried tints (now)
    bl tc_render_text
    bl tc_frame_end
    // ---- status line + paint ----------------------------------------------
    bl watch_build_status
    bl watch_screen_paint
    bl watch_monotonic
    adrp x9, PAGE(tc_watch_painted_at)
    add x9, x9, LO12(tc_watch_painted_at)
    str d0, [x9]
    bl watch_build_prev
    adrp x9, PAGE(tc_watch_first)
    adrp x9, PAGE(tc_watch_first)
    add x9, x9, LO12(tc_watch_first)
    str xzr, [x9]
    // ---- wait --------------------------------------------------------------
    bl watch_next_wait
    b .Lwr_loop
.Lwr_done:
    // restore the cursor + newline, flush
    adrp x0, PAGE(s_cursor_show)
    add x0, x0, LO12(s_cursor_show)
    bl tc_puts
    mov w0, #0
    bl fflush
    mov x19, #130
    mov x0, x19
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_sigint_handler — sets the interrupted flag (async-signal-safe).
// ============================================================================
    .p2align 2
watch_sigint_handler:
    stp x19, x30, [sp, #-16]!
    adrp x9, PAGE(tc_watch_interrupted)
    add x9, x9, LO12(tc_watch_interrupted)
    mov x10, #1
    str x10, [x9]
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// watch_monotonic() -> d0 = seconds (double), CLOCK_MONOTONIC.
// ============================================================================
    .p2align 2
watch_monotonic:
    stp x19, x30, [sp, #-16]!
    mov x0, #CLOCK_MONOTONIC
    adrp x1, PAGE(tc_watch_ts)
    add x1, x1, LO12(tc_watch_ts)
    bl clock_gettime
    adrp x9, PAGE(tc_watch_ts)
    add x9, x9, LO12(tc_watch_ts)
    ldr x10, [x9]                    // tv_sec (u64)
    ldr x11, [x9, #8]                // tv_nsec
    scvtf d0, x10
    scvtf d1, x11
    adrp x9, PAGE(dbl_nanosec)
    add x9, x9, LO12(dbl_nanosec)
    ldr d2, [x9]
    fdiv d1, d1, d2
    fadd d0, d0, d1
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// watch_local_now() -> (x0=ymd, x1=sod) — the current time in LOCAL terms.
//   The logs Chatterino writes are local, so the sliding window's "now" must
//   be local too (Python's datetime.now()); a UTC end would shift --since
//   windows by the UTC offset and count the wrong messages.
// ============================================================================
    .p2align 2
watch_local_now:
    stp x19, x30, [sp, #-16]!
    stp x20, x21, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    mov x0, #CLOCK_REALTIME
    adrp x1, PAGE(tc_watch_ts)
    add x1, x1, LO12(tc_watch_ts)
    bl clock_gettime
    adrp x19, PAGE(tc_watch_ts)
    add x19, x19, LO12(tc_watch_ts)
    mov x0, x19
    adrp x1, PAGE(tc_watch_tm)
    add x1, x1, LO12(tc_watch_tm)
    bl localtime_r
    // struct tm (musl aarch64): tm_sec@0, tm_min@4, tm_hour@8, tm_mday@12,
    // tm_mon@16, tm_year@20 — all 32-bit ints
    adrp x19, PAGE(tc_watch_tm)
    add x19, x19, LO12(tc_watch_tm)
    ldr w20, [x19, #20]               // tm_year
    add x20, x20, #1900
    ldr w21, [x19, #16]               // tm_mon
    add x21, x21, #1
    ldr w22, [x19, #12]               // tm_mday
    mov x0, #10000
    mul x20, x20, x0
    mov x0, #100
    mul x21, x21, x0
    add x0, x20, x21
    add x0, x0, x22                   // ymd
    ldr w20, [x19, #8]                // tm_hour
    mov x21, #3600
    mul x20, x20, x21
    ldr w21, [x19, #4]                // tm_min
    mov x22, #60
    madd x21, x21, x22, x20
    ldr w22, [x19, #0]                // tm_sec
    add x1, x21, x22                  // sod
    ldp x22, x23, [sp], #16
    ldp x20, x21, [sp], #16
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// watch_sleep(d0 = seconds) — nanosleep; a signal (EINTR) ends it early.
// ============================================================================
    .p2align 2
watch_sleep:
    stp x19, x30, [sp, #-16]!
    fcmp d0, #0.0
    b.le .Lws_done
    fcvtzs x9, d0                    // whole seconds (toward zero; d0 > 0)
    scvtf d1, x9
    fsub d2, d0, d1                  // fraction
    adrp x10, PAGE(dbl_nanosec)
    add x10, x10, LO12(dbl_nanosec)
    ldr d3, [x10]
    fmul d2, d2, d3
    fcvtzu x11, d2                   // tv_nsec
    adrp x10, PAGE(tc_watch_ts)
    add x10, x10, LO12(tc_watch_ts)
    str x9, [x10]
    str x11, [x10, #8]
    mov x0, x10
    adrp x1, PAGE(tc_watch_ts2)
    add x1, x1, LO12(tc_watch_ts2)
    bl nanosleep
.Lws_done:
    ldp x19, x30, [sp], #16
    ret

// ============================================================================
// watch_load_settings — copy the resolved watch settings out of tc_opts into
//   the session block, then validate interval >= min_interval (the Python
//   resolve_watch ConfigError).  May tc_fail.
// ============================================================================
    .p2align 2
watch_load_settings:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    adrp x20, PAGE(tc_watch_interval)
    add x20, x20, LO12(tc_watch_interval)
    ldr d0, [x19, #TC_O_INTERVAL]
    str d0, [x20]
    ldr d0, [x19, #TC_O_HOLD]
    str d0, [x20, #WS_HOLD]
    ldr d0, [x19, #TC_O_MIN_REDRAW]
    str d0, [x20, #WS_MIN_REDRAW]
    ldr d0, [x19, #TC_O_MIN_INTERVAL]
    str d0, [x20, #WS_MIN_INTERVAL]
    ldr d0, [x19, #TC_O_FADE_K]
    str d0, [x20, #WS_FADE_K]
    ldr x21, [x19, #TC_O_SHADES]
    str x21, [x20, #WS_SHADES]
    ldr x21, [x19, #TC_O_REPLAY_STEPS]
    str x21, [x20, #WS_REPLAY_STEPS]
    ldr x21, [x19, #TC_O_FULL_REPAINT]
    str x21, [x20, #WS_FULL_REPAINT]
    ldr x21, [x19, #TC_O_SHOW_TIMING]
    str x21, [x20, #WS_SHOW_TIMING]
    ldr x21, [x19, #TC_O_TINT_FALLING]
    str x21, [x20, #WS_TINT_FALLING]
    ldr x21, [x19, #TC_O_FADE_CURVE]
    str x21, [x20, #WS_FADE_CURVE]
    ldr x21, [x19, #TC_O_USER_WIDTH]
    str x21, [x20, #WS_USER_WIDTH]
    ldr x21, [x19, #TC_O_STREAMER_MODE]
    str x21, [x20, #WS_STREAMER]
    // sources
    adrp x21, PAGE(tc_opts)
    add x21, x21, LO12(tc_opts)
    mov x22, #TC_O_SRC
    add x21, x21, x22
    ldr x22, [x21, #TC_SET_INTERVAL*8]
    str x22, [x20, #WS_INTERVAL_SRC]
    ldr x22, [x21, #TC_SET_HOLD*8]
    str x22, [x20, #WS_HOLD_SRC]
    // session floors (replay_horizon + max(hold,0))
    ldr d0, [x20, #WS_HOLD]
    ldr d1, [x20]                    // interval
    ldr x0, [x20, #WS_REPLAY_STEPS]
    bl watch_replay_horizon          // d0 = horizon
    str d0, [x20, #WS_RETAIN_SECONDS]
    ldr d0, [x20, #WS_HOLD]
    fcmp d0, #0.0
    b.le .Lwls_hold0
    str d0, [x20, #WS_MATCH_SECONDS]
    b .Lwls_check
.Lwls_hold0:
    mov x9, #0
    scvtf d1, x9
    str d1, [x20, #WS_MATCH_SECONDS]
.Lwls_check:
    // interval >= min_interval?
    ldr d0, [x20]
    ldr d1, [x20, #WS_MIN_INTERVAL]
    fcmp d0, d1
    b.ge .Lwls_ok
    // compose: {src_label}: interval must be at least {floor:g}s ({flabel})
    adrp x19, PAGE(tc_watch_errbuf)
    add x19, x19, LO12(tc_watch_errbuf)
    mov x23, x19
    // interval label
    adrp x0, PAGE(s_watch_flag)            // "--watch"
    add x0, x0, LO12(s_watch_flag)
    adrp x21, PAGE(tc_watch_interval_src)
    add x21, x21, LO12(tc_watch_interval_src)
    ldr x22, [x21]
    adrp x21, PAGE(s_watch_flag)
    add x21, x21, LO12(s_watch_flag)
    cmp x22, #TC_SRC_CLI_WATCH
    b.eq .Lwls_ilbl_plain
    // "--watch (from {src})"
    mov x0, x23
    mov x1, x21
    bl wc_cat
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_from_paren)
    add x1, x1, LO12(s_from_paren)
    bl wc_cat
    mov x23, x0
    mov x0, x22
    bl tc_source_str                  // (x0=ptr, x1=len)
    mov x2, x1
    mov x1, x0
    mov x0, x23
    bl wc_catn
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_close_paren)
    add x1, x1, LO12(s_close_paren)
    bl wc_cat
    mov x23, x0
    b .Lwls_ilbl_done
.Lwls_ilbl_plain:
    mov x0, x23
    mov x1, x21
    bl wc_cat
    mov x23, x0
.Lwls_ilbl_done:
    mov x0, x23
    adrp x1, PAGE(s_int_min_pre)
    add x1, x1, LO12(s_int_min_pre)
    bl wc_cat
    mov x23, x0
    // floor %g
    ldr d0, [x20, #WS_MIN_INTERVAL]
    mov x0, x23
    mov x1, #128
    adrp x2, PAGE(fmt_g)
    add x2, x2, LO12(fmt_g)
    bl snprintf
    mov x0, x23
    bl tc_strlen
    add x23, x23, x0
    mov x0, x23
    adrp x1, PAGE(s_int_min_mid)
    add x1, x1, LO12(s_int_min_mid)
    bl wc_cat
    mov x23, x0
    // floor label: "watch.min_interval (from {src})"
    mov x0, x23
    adrp x1, PAGE(s_min_interval_flag)
    add x1, x1, LO12(s_min_interval_flag)
    bl wc_cat
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_from_paren)
    add x1, x1, LO12(s_from_paren)
    bl wc_cat
    mov x23, x0
    adrp x21, PAGE(tc_opts)
    add x21, x21, LO12(tc_opts)
    mov x22, #TC_O_SRC
    add x21, x21, x22
    ldr x22, [x21, #TC_SET_MIN_INTERVAL*8]
    mov x0, x22
    bl tc_source_str
    mov x2, x1
    mov x1, x0
    mov x0, x23
    bl wc_catn
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_close_paren2)
    add x1, x1, LO12(s_close_paren2)
    bl wc_cat
    mov x23, x0
    mov w1, #0
    strb w1, [x23]
    adrp x0, PAGE(tc_watch_errbuf)
    add x0, x0, LO12(tc_watch_errbuf)
    bl tc_report_fail                 // noreturn
.Lwls_ok:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_replay_horizon(d0 = hold, d1 = interval, x0 = max_steps)
//   -> d0 = replay_horizon(hold, interval, max_steps) (Python 3610-3620).
// ============================================================================
    .p2align 2
watch_replay_horizon:
    stp x29, x30, [sp, #-16]!
    fcmp d0, #0.0
    b.le .Lwrh_hold0
    // horizon = hold
    b .Lwrh_div
.Lwrh_hold0:
    scvtf d2, x0                     // max_steps
    fmul d0, d1, d2                  // interval * max_steps
.Lwrh_div:
    fdiv d2, d0, d1                  // horizon / interval
    fcvtzs x9, d2                    // int()
    cmp x9, x0
    b.le .Lwrh_min_ok
    mov x9, x0
.Lwrh_min_ok:
    cmp x9, #1
    b.ge .Lwrh_steps_ok
    mov x9, #1
.Lwrh_steps_ok:
    scvtf d2, x9
    fmul d0, d2, d1                  // steps * interval
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_load_tail — copy tail settings; notify stays in tc_watch_notify.
// ============================================================================
    .p2align 2
watch_load_tail:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    adrp x20, PAGE(tc_watch_notify)
    add x20, x20, LO12(tc_watch_notify)
    ldr x21, [x19, #TC_O_NOTIFY]
    str x21, [x20]
    ldr x21, [x19, #TC_O_MAX_EVENTS]
    str x21, [x20, #(WS_MAX_EVENTS - WS_NOTIFY)]
    ldr x21, [x19, #TC_O_SEED_LOOKBACK]
    str x21, [x20, #(WS_SEED_LOOKBACK - WS_NOTIFY)]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================

// burst_cat(dst, src) -> dst + strlen(src) (no NUL; for the write burst)
    .p2align 2
burst_cat:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x0, x20
    bl tc_strlen
    mov x2, x0
    mov x0, x19
    mov x1, x20
    bl watch_copy_to
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// wc_cat(dst, src) -> dst after the copied NUL; wc_catn(dst, src, len).
// ============================================================================
    .p2align 2
wc_cat:
    mov x2, x0
.Lwc_loop:
    ldrb w3, [x1], #1
    strb w3, [x2], #1
    cbnz w3, .Lwc_loop
    sub x0, x2, #1                    // cursor AT the NUL (append in place)
    ret

    .p2align 2
wc_catn:
    mov x3, #0
.Lwcn_loop:
    cmp x3, x2
    b.ge .Lwcn_done
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    b .Lwcn_loop
.Lwcn_done:
    add x0, x0, x2
    ret

// ============================================================================
// watch_ymd_sod_to_epoch(x0=ymd, x1=sod) -> x0 = epoch seconds (UTC).
// ============================================================================
    .p2align 2
watch_ymd_sod_to_epoch:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x2, #10000
    udiv x21, x19, x2                   // year
    mul x3, x21, x2
    sub x4, x19, x3
    mov x2, #100
    udiv x22, x4, x2                    // month
    msub x23, x22, x2, x4               // day
    mov x0, x21
    mov x1, x22
    mov x2, x23
    bl watch_days_from_civil
    ldr x3, =SECS_PER_DAY
    mul x0, x0, x3
    add x0, x0, x20
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_epoch_to_ymd_sod(x0=epoch) -> x0=ymd, x1=sod (UTC).
// ============================================================================
    .p2align 2
watch_epoch_to_ymd_sod:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    ldr x19, =SECS_PER_DAY
    udiv x20, x0, x19
    msub x21, x20, x19, x0             // sod
    mov x0, x20
    bl tc_civil_from_days               // x0=y, x1=m, x2=d
    mov x3, #10000
    mul x0, x0, x3
    mov x3, #100
    mul x1, x1, x3
    add x0, x0, x1
    add x0, x0, x2
    mov x1, x21
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_days_from_civil(x0=y, x1=m, x2=d) -> x0 = days since 1970-01-01
//   (Howard Hinnant; identical to tc_core's local helper).
// ============================================================================
    .p2align 2
watch_days_from_civil:
    // Howard Hinnant's days_from_civil: y -= m <= 2; era = (y>=0?y:y-399)/400;
    // yoe = y - era*400; doy = (153*(m + (m>2?-3:9)) + 2)/5 + d - 1;
    // doe = yoe*365 + yoe/4 - yoe/100 + doy;
    // return era*146097 + doe - 719468
    cmp x1, #2
    b.gt .Lwdfc_adj_done
    sub x0, x0, #1
.Lwdfc_adj_done:
    cmp x0, #0
    b.ge .Lwdfc_ypos
    sub x3, x0, #399
    b .Lwdfc_era
.Lwdfc_ypos:
    mov x3, x0
.Lwdfc_era:
    mov x4, #400
    sdiv x5, x3, x4                    // era
    msub x6, x5, x4, x3                // yoe
    // mp = month + (month > 2 ? -3 : 9)
    cmp x1, #2
    b.gt .Lwdfc_mp_big
    add x7, x1, #9
    b .Lwdfc_doy
.Lwdfc_mp_big:
    sub x7, x1, #3
.Lwdfc_doy:
    mov x8, #153
    mul x7, x7, x8
    add x7, x7, #2
    mov x8, #5
    sdiv x7, x7, x8                    // (153*mp + 2) / 5
    add x7, x7, x2
    sub x7, x7, #1                     // doy = ... + d - 1
    // doe = yoe*365 + yoe/4 - yoe/100 + doy
    mov x9, #4
    sdiv x11, x6, x9                   // yoe/4
    mov x9, #365
    mul x10, x6, x9
    add x10, x10, x11                  // yoe*365 + yoe/4
    mov x9, #100
    sdiv x11, x6, x9
    sub x10, x10, x11                  // - yoe/100
    add x10, x10, x7                   // + doy  -> doe
    ldr x12, =146097
    mul x13, x5, x12
    add x10, x10, x13
    ldr x13, =719468
    sub x10, x10, x13
    mov x0, x10
    ret

// ============================================================================
// watch_build_dirpath — tc_watch_dirpath = logs_dir + "/" + channel_name.
// ============================================================================
    .p2align 2
watch_build_dirpath:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x0, PAGE(tc_watch_dirpath)
    add x0, x0, LO12(tc_watch_dirpath)
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_LOGS_DIR
    bl wc_cat
    mov x19, x0                        // cursor AT the NUL (append in place)
    mov w2, #'/'
    strb w2, [x19], #1
    bl tc_channel_name
    mov x1, x0
    mov x0, x19
    bl wc_cat
    mov w2, #0
    strb w2, [x0]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_build_listing — fill tc_listing with dated log files (ascending),
//   memoized on the channel directory's mtime_ns.
// ============================================================================
    .p2align 2
watch_build_listing:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // stat the channel dir; unchanged mtime + existing listing -> memo hit
    adrp x0, PAGE(tc_watch_dirpath)
    add x0, x0, LO12(tc_watch_dirpath)
    adrp x1, PAGE(tc_watch_stat)
    add x1, x1, LO12(tc_watch_stat)
    bl stat
    cbnz w0, .Lwbl_rebuild
    adrp x9, PAGE(tc_watch_ts)
    add x9, x9, LO12(tc_watch_ts)
    ldr x10, [x9, #ST_MTIM_SEC]
    movz x11, #0xCA00, lsl #0
    movk x11, #0x3B9A, lsl #16         // 1000000000
    mul x10, x10, x11
    ldr x11, [x9, #ST_MTIM_NSEC]
    add x10, x10, x11
    adrp x9, PAGE(tc_watch_list_mtime)
    add x9, x9, LO12(tc_watch_list_mtime)
    ldr x11, [x9]
    cmp x10, x11
    b.ne .Lwbl_rebuild
    adrp x9, PAGE(tc_watch_list_have)
    add x9, x9, LO12(tc_watch_list_have)
    ldr x9, [x9]
    cbnz x9, .Lwbl_done
.Lwbl_rebuild:
    // free any previous listing entries, then scan the directory
    adrp x9, PAGE(tc_listing)
    add x9, x9, LO12(tc_listing)
    ldr x10, [x9, #TC_L_ENTRIES]
    cbz x10, .Lwbl_open
    mov x0, x10
    bl free
    adrp x9, PAGE(tc_listing)
    add x9, x9, LO12(tc_listing)
    str xzr, [x9, #TC_L_ENTRIES]
    str xzr, [x9, #TC_L_CAP]
.Lwbl_open:
    adrp x0, PAGE(tc_watch_dirpath)
    add x0, x0, LO12(tc_watch_dirpath)
    bl opendir
    cbz x0, .Lwbl_memo_nodir         // dir vanished: keep an empty listing
    mov x19, x0                       // DIR*
    adrp x20, PAGE(tc_listing)
    add x20, x20, LO12(tc_listing)
    str xzr, [x20, #TC_L_COUNT]
.Lwbl_list:
    mov x0, x19
    bl readdir
    cbz x0, .Lwbl_close
    ldrb w1, [x0, #DT_TYPE]
    cmp w1, #DT_REG
    b.ne .Lwbl_list
    add x21, x0, #DT_NAME             // name ptr (callee-saved)
    mov x0, x21
    bl tc_strlen
    mov x22, x0                       // name len
    mov x0, x21
    mov x1, x22
    bl watch_parse_log_filename       // x0 = ymd or 0
    cbz x0, .Lwbl_list
    mov x23, x0                       // ymd
    // append (ymd, name): grow the entry array if needed
    ldr x10, [x20, #TC_L_COUNT]
    ldr x11, [x20, #TC_L_CAP]
    cmp x10, x11
    b.lt .Lwbl_append
    cbz x11, .Lwbl_alloc_new
    lsl x11, x11, #1
    b .Lwbl_alloc
.Lwbl_alloc_new:
    mov x11, #64
.Lwbl_alloc:
    mov x24, x11                       // new cap
    ldr x0, [x20, #TC_L_ENTRIES]
    mov x1, #TC_L_ENTRY_SZ
    mul x1, x11, x1
    bl realloc
    cbz x0, .Lwbl_oom
    str x0, [x20, #TC_L_ENTRIES]
    str x24, [x20, #TC_L_CAP]
.Lwbl_append:
    ldr x10, [x20, #TC_L_COUNT]
    ldr x11, [x20, #TC_L_ENTRIES]
    mov x12, #TC_L_ENTRY_SZ
    mul x12, x10, x12
    add x11, x11, x12                 // entry
    str x23, [x11, #TC_L_YMD]
    add x11, x11, #TC_L_NAME
    mov x12, #0
.Lwbl_copy:
    cmp x12, x22
    b.ge .Lwbl_copy_done
    ldrb w13, [x21, x12]
    strb w13, [x11, x12]
    add x12, x12, #1
    b .Lwbl_copy
.Lwbl_copy_done:
    mov w13, #0
    strb w13, [x11, x12]
    add x10, x10, #1
    str x10, [x20, #TC_L_COUNT]
    b .Lwbl_list
.Lwbl_close:
    mov x0, x19
    bl closedir
    // sort ascending by (ymd, name)
    ldr x1, [x20, #TC_L_COUNT]
    cbz x1, .Lwbl_memo
    ldr x0, [x20, #TC_L_ENTRIES]
    mov x2, #TC_L_ENTRY_SZ
    adrp x3, PAGE(watch_listing_cmp)
    add x3, x3, LO12(watch_listing_cmp)
    bl qsort
.Lwbl_memo:
    // record the dir mtime memo
    adrp x0, PAGE(tc_watch_dirpath)
    add x0, x0, LO12(tc_watch_dirpath)
    adrp x1, PAGE(tc_watch_stat)
    add x1, x1, LO12(tc_watch_stat)
    bl stat
    cbnz w0, .Lwbl_memo_skip
    adrp x9, PAGE(tc_watch_ts)
    add x9, x9, LO12(tc_watch_ts)
    ldr x10, [x9, #ST_MTIM_SEC]
    movz x11, #0xCA00, lsl #0
    movk x11, #0x3B9A, lsl #16
    mul x10, x10, x11
    ldr x11, [x9, #ST_MTIM_NSEC]
    add x10, x10, x11
    adrp x9, PAGE(tc_watch_list_mtime)
    add x9, x9, LO12(tc_watch_list_mtime)
    str x10, [x9]
.Lwbl_memo_skip:
    adrp x9, PAGE(tc_watch_list_have)
    add x9, x9, LO12(tc_watch_list_have)
    mov x10, #1
    str x10, [x9]
    b .Lwbl_done
.Lwbl_memo_nodir:
    adrp x9, PAGE(tc_watch_list_have)
    add x9, x9, LO12(tc_watch_list_have)
    mov x10, #1
    str x10, [x9]
.Lwbl_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwbl_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
// watch_listing_cmp — qsort comparator: (ymd, name) ascending.
// ============================================================================
    .p2align 2
watch_listing_cmp:
    ldr x2, [x0]
    ldr x3, [x1]
    cmp x2, x3
    b.lt .Lwlc_lt
    b.gt .Lwlc_gt
    add x0, x0, #TC_L_NAME
    add x1, x1, #TC_L_NAME
    b strcmp
.Lwlc_lt:
    mov w0, #-1
    ret
.Lwlc_gt:
    mov w0, #1
    ret

// ============================================================================
// watch_parse_log_filename(x0=name, x1=len) -> x0 = ymd, or 0.
//   FILENAME_RE: ^.+-(y{4})-(mo{2})-(d{2})\.log$ with a real calendar date.
//   Layout from the end: ".log" then "DD" '-' "MM" '-' "YYYY" '-' channel.
// ============================================================================
    .p2align 2
watch_parse_log_filename:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    cmp x1, #16                       // at least "x-YYYY-MM-DD.log"
    b.lt .Lwpf_fail
    mov x2, x0                        // scan
    add x3, x0, x1                    // end
    sub x3, x3, #1
    // ".log" suffix
    ldrb w4, [x3]
    cmp w4, #'g'
    b.ne .Lwpf_fail
    sub x3, x3, #1
    ldrb w4, [x3]
    cmp w4, #'o'
    b.ne .Lwpf_fail
    sub x3, x3, #1
    ldrb w4, [x3]
    cmp w4, #'l'
    b.ne .Lwpf_fail
    sub x3, x3, #1
    ldrb w4, [x3]
    cmp w4, #'.'
    b.ne .Lwpf_fail
    // x3 = '.': day digits at x3-2, x3-1; '-' at x3-3
    sub x4, x3, #3
    cmp x4, x0
    b.le .Lwpf_fail
    ldrb w5, [x4]
    cmp w5, #'-'
    b.ne .Lwpf_fail
    ldrb w6, [x4, #1]
    sub w6, w6, #'0'
    cmp w6, #9
    b.hi .Lwpf_fail
    ldrb w7, [x4, #2]
    sub w7, w7, #'0'
    cmp w7, #9
    b.hi .Lwpf_fail
    mov x9, #10
    mul x6, x6, x9
    add x23, x6, x7                   // day (callee-saved)
    // month: '-' at x4-3; digits at x4-2, x4-1
    sub x4, x4, #3
    cmp x4, x0
    b.le .Lwpf_fail
    ldrb w5, [x4]
    cmp w5, #'-'
    b.ne .Lwpf_fail
    ldrb w6, [x4, #1]
    sub w6, w6, #'0'
    cmp w6, #9
    b.hi .Lwpf_fail
    ldrb w7, [x4, #2]
    sub w7, w7, #'0'
    cmp w7, #9
    b.hi .Lwpf_fail
    mul x6, x6, x9
    add x22, x6, x7                   // month (callee-saved)
    // year: '-' at x4-5; digits at x4-4 .. x4-1
    sub x4, x4, #5
    cmp x4, x0
    b.le .Lwpf_fail
    ldrb w5, [x4]
    cmp w5, #'-'
    b.ne .Lwpf_fail
    mov x21, #0                       // year (callee-saved)
    mov x24, #0
.Lwpf_yr:
    cmp x24, #4
    b.ge .Lwpf_yr_done
    ldrb w5, [x4, #1]
    add x4, x4, #1
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lwpf_fail
    mov x9, #10
    mul x21, x21, x9
    add x21, x21, x5
    add x24, x24, #1
    b .Lwpf_yr
.Lwpf_yr_done:
    // channel part must be nonempty (.+) — the '-' at x4-5... the year loop
    // advanced x4 to the last year digit; the channel is before x4-4.
    sub x9, x4, #4
    cmp x9, x0
    b.le .Lwpf_fail
    // validate the date
    cmp x22, #1
    b.lt .Lwpf_fail
    cmp x22, #12
    b.gt .Lwpf_fail
    cmp x23, #1
    b.lt .Lwpf_fail
    mov x0, x21
    mov x1, x22
    bl watch_days_in_month             // x0 = days
    cmp x23, x0
    b.gt .Lwpf_fail
    mov x9, #10000
    mul x0, x21, x9
    mov x9, #100
    madd x0, x22, x9, x0
    add x0, x0, x23
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpf_fail:
    mov x0, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_days_in_month(x0=y, x1=m) -> x0 = days in the month (proleptic Greg).
// ============================================================================
    .p2align 2
watch_days_in_month:
    stp x29, x30, [sp, #-16]!
    // month_days table
    adrp x10, PAGE(watch_month_days)
    add x10, x10, LO12(watch_month_days)
    sub x11, x1, #1
    ldrb w12, [x10, x11]
    // February leap
    cmp x1, #2
    b.ne .Lwdim_out
    // leap year: y%4==0 and (y%100!=0 or y%400==0)
    mov x13, #4
    sdiv x14, x0, x13
    msub x14, x14, x13, x0
    cbnz x14, .Lwdim_out
    mov x13, #100
    sdiv x14, x0, x13
    msub x14, x14, x13, x0
    cbz x14, .Lwdim_c400
    add x12, x12, #1
    b .Lwdim_out
.Lwdim_c400:
    mov x13, #400
    sdiv x14, x0, x13
    msub x14, x14, x13, x0
    cbnz x14, .Lwdim_out
    add x12, x12, #1
.Lwdim_out:
    mov x0, x12
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_init_window — session-start window: end_given flag, sliding width,
//   earliest kind completion (no log files -> Python's ConfigError).
// ============================================================================
    .p2align 2
watch_init_window:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    // end_given?  (Python: settings["end"] truthy)
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    mov x20, #TC_O_SRC
    add x19, x19, x20
    ldr x20, [x19, #TC_SET_END*8]
    cmp x20, #TC_SRC_DEFAULT_NOW
    b.eq .Lwiw_end_default
    mov x20, #1
    b .Lwiw_end_store
.Lwiw_end_default:
    mov x20, #0
.Lwiw_end_store:
    adrp x9, PAGE(tc_watch_end_given)
    add x9, x9, LO12(tc_watch_end_given)
    str x20, [x9]
    // kind dispatch
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_KIND]
    cmp x20, #TC_WIN_EARLIEST
    b.eq .Lwiw_earliest
    cmp x20, #TC_WIN_USERS
    b.eq .Lwiw_users
    cmp x20, #TC_WIN_SINCE
    b.eq .Lwiw_since
    // kind == TC_WIN_BEGIN (0): the CLI leaves TC_W_KIND at 0 for both an
    // explicit --begin and a derived --since (tc_cli's .Lrw_since writes
    // begin/end and TC_W_BEGIN_ROLLS but never the kind).  The one-shot path
    // reads begin/end directly, so it never notices; watch must roll the
    // begin with the clock, so key on TC_W_BEGIN_ROLLS: set -> since-style
    // sliding width = end - begin, clear -> a fixed begin, width 0.
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x20, [x9, #TC_W_BEGIN_ROLLS]
    cbz x20, .Lwiw_fixed
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x0, [x9, #TC_W_BEGIN_YMD]
    ldr x1, [x9, #TC_W_BEGIN_SOD]
    bl watch_ymd_sod_to_epoch
    mov x20, x0
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x0, [x9, #TC_W_END_YMD]
    ldr x1, [x9, #TC_W_END_SOD]
    bl watch_ymd_sod_to_epoch
    sub x0, x0, x20
    adrp x9, PAGE(tc_watch_win_width)
    add x9, x9, LO12(tc_watch_win_width)
    str x0, [x9]
    b .Lwiw_done
.Lwiw_fixed:
    adrp x9, PAGE(tc_watch_win_width)
    add x9, x9, LO12(tc_watch_win_width)
    str xzr, [x9]
    b .Lwiw_done
.Lwiw_earliest:
    // begin = earliest file (midnight); "no log files found in <dir>" when none
    adrp x20, PAGE(tc_listing)
    add x20, x20, LO12(tc_listing)
    ldr x21, [x20, #TC_L_COUNT]
    cbnz x21, .Lwiw_earliest_ok
    adrp x0, PAGE(tc_watch_errbuf)
    add x0, x0, LO12(tc_watch_errbuf)
    adrp x1, PAGE(s_no_logs_pre)
    add x1, x1, LO12(s_no_logs_pre)
    bl wc_cat
    adrp x1, PAGE(tc_watch_dirpath)
    add x1, x1, LO12(tc_watch_dirpath)
    bl wc_cat
    adrp x0, PAGE(tc_watch_errbuf)
    add x0, x0, LO12(tc_watch_errbuf)
    bl tc_report_fail
.Lwiw_earliest_ok:
    ldr x22, [x20, #TC_L_ENTRIES]
    ldr x23, [x22, #TC_L_YMD]
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    str x23, [x19, #TC_W_BEGIN_YMD]
    str xzr, [x19, #TC_W_BEGIN_SOD]
    adrp x9, PAGE(tc_watch_win_width)
    add x9, x9, LO12(tc_watch_win_width)
    str xzr, [x9]
    b .Lwiw_done
.Lwiw_users:
    // begin placeholder = end; width resolved by watch_size_users
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_END_YMD]
    ldr x21, [x19, #TC_W_END_SOD]
    str x20, [x19, #TC_W_BEGIN_YMD]
    str x21, [x19, #TC_W_BEGIN_SOD]
    b .Lwiw_done
.Lwiw_since:
    // width = end - begin (seconds), recomputed each roll
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x0, [x19, #TC_W_BEGIN_YMD]
    ldr x1, [x19, #TC_W_BEGIN_SOD]
    bl watch_ymd_sod_to_epoch
    mov x20, x0
    ldr x0, [x19, #TC_W_END_YMD]
    ldr x1, [x19, #TC_W_END_SOD]
    bl watch_ymd_sod_to_epoch
    sub x0, x0, x20
    adrp x9, PAGE(tc_watch_win_width)
    add x9, x9, LO12(tc_watch_win_width)
    str x0, [x9]
.Lwiw_done:
    // fill the threshold + state filter from the options (mirror tc_complete_window)
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    adrp x10, PAGE(tc_opts)
    add x10, x10, LO12(tc_opts)
    ldr x11, [x10, #TC_O_MIN_COUNT]
    str x11, [x9, #TC_W_THRESHOLD]
    ldr x11, [x10, #TC_O_STATE_FILTER]
    str x11, [x9, #TC_W_STATE_FILTER]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_roll_window — per tick: end = now (unless explicit), begin slides.
// ============================================================================
    .p2align 2
watch_roll_window:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x9, PAGE(tc_watch_end_given)
    add x9, x9, LO12(tc_watch_end_given)
    ldr x9, [x9]
    cbnz x9, .Lwrw_slide
    bl watch_local_now                // x0=ymd, x1=sod (local: logs are local)
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    str x0, [x19, #TC_W_END_YMD]
    str x1, [x19, #TC_W_END_SOD]
.Lwrw_slide:
    // begin rolls?
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x20, [x19, #TC_W_BEGIN_ROLLS]
    cbz x20, .Lwrw_done
    ldr x21, [x19, #TC_W_END_YMD]
    ldr x22, [x19, #TC_W_END_SOD]
    mov x0, x21
    mov x1, x22
    bl watch_ymd_sod_to_epoch
    adrp x9, PAGE(tc_watch_win_width)
    add x9, x9, LO12(tc_watch_win_width)
    ldr x20, [x9]
    sub x0, x0, x20
    bl watch_epoch_to_ymd_sod         // x0=ymd, x1=sod
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    str x0, [x19, #TC_W_BEGIN_YMD]
    str x1, [x19, #TC_W_BEGIN_SOD]
.Lwrw_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// month_days table (rodata lives with the other strings)
    RODATA
    .p2align 2
watch_month_days:
    .byte 31,28,31,30,31,30,31,31,30,31,30,31
s_no_logs_pre:      .asciz "no log files found in "
    .text

// ============================================================================
// Reader machinery (the Python TailReader / LiveReaders)
// ============================================================================

// watch_reader_find(path) -> x0 = reader ptr or 0 (linear scan by path).
    .p2align 2
watch_reader_find:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // path
    adrp x9, PAGE(tc_watch_reader_n)
    add x9, x9, LO12(tc_watch_reader_n)
    ldr x20, [x9]
    adrp x9, PAGE(tc_watch_readers)
    add x9, x9, LO12(tc_watch_readers)
    ldr x21, [x9]
    mov x22, #0
.Lwrf_loop:
    cmp x22, x20
    b.ge .Lwrf_none
    ldr x23, [x21, x22, lsl #3]
    add x23, x23, #RD_PATH
    mov x0, x19
    mov x1, x23
    bl strcmp
    cbz w0, .Lwrf_found
    add x22, x22, #1
    b .Lwrf_loop
.Lwrf_found:
    ldr x0, [x21, x22, lsl #3]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrf_none:
    mov x0, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_reader_get(path, fdate) -> x0 = reader ptr (created if missing).
    .p2align 2
watch_reader_get:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // path
    mov x20, x1                        // fdate
    mov x0, x19
    bl watch_reader_find
    cbnz x0, .Lwrg_have
    // create: malloc READER_SZ, zero, copy path
    mov x0, #READER_SZ
    bl malloc
    cbz x0, .Lwrg_oom
    mov x21, x0
    mov x0, x21
    mov x1, #0
    mov x2, #READER_SZ
    bl memset
    add x0, x21, #RD_PATH
    mov x1, x19
    bl wc_cat
    str x20, [x21, #RD_FDATE]
    // append to the reader array (grow)
    adrp x9, PAGE(tc_watch_reader_n)
    add x9, x9, LO12(tc_watch_reader_n)
    ldr x22, [x9]
    adrp x10, PAGE(tc_watch_reader_cap)
    add x10, x10, LO12(tc_watch_reader_cap)
    ldr x11, [x10]
    cmp x22, x11
    b.lt .Lwrg_append
    cbz x11, .Lwrg_new
    lsl x11, x11, #1
    b .Lwrg_alloc
.Lwrg_new:
    mov x11, #READER_INIT
.Lwrg_alloc:
    mov x23, x11
    adrp x9, PAGE(tc_watch_readers)
    add x9, x9, LO12(tc_watch_readers)
    ldr x0, [x9]
    mov x1, #8
    mul x1, x11, x1
    bl realloc
    cbz x0, .Lwrg_oom
    adrp x9, PAGE(tc_watch_readers)
    add x9, x9, LO12(tc_watch_readers)
    str x0, [x9]
    adrp x9, PAGE(tc_watch_reader_cap)
    add x9, x9, LO12(tc_watch_reader_cap)
    str x23, [x9]
    adrp x9, PAGE(tc_watch_reader_n)
    add x9, x9, LO12(tc_watch_reader_n)
    ldr x22, [x9]
.Lwrg_append:
    adrp x9, PAGE(tc_watch_readers)
    add x9, x9, LO12(tc_watch_readers)
    ldr x10, [x9]
    str x21, [x10, x22, lsl #3]
    add x22, x22, #1
    adrp x9, PAGE(tc_watch_reader_n)
    add x9, x9, LO12(tc_watch_reader_n)
    str x22, [x9]
    mov x0, x21
.Lwrg_have:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrg_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// watch_reader_reset(rd) — discard buckets/matches/offset/remainder/window/day;
//   full_reads/appends are lifetime counters and survive (Python reset()).
    .p2align 2
watch_reader_reset:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    str xzr, [x19, #RD_BUCKET_N]
    str xzr, [x19, #RD_MATCH_N]
    str xzr, [x19, #RD_WINDOW]
    str xzr, [x19, #RD_WIN_N]
    str xzr, [x19, #RD_WIN_LO]
    str xzr, [x19, #RD_WIN_HI]
    str xzr, [x19, #RD_WIN_REV]
    str xzr, [x19, #RD_DAY]
    str xzr, [x19, #RD_DAY_N]
    str xzr, [x19, #RD_OFFSET]
    str xzr, [x19, #RD_REVISION]
    str xzr, [x19, #RD_PARTIAL]
    ldr x9, [x19, #RD_REMAINDER]
    cbz x9, .Lwrr_rem_ok
    mov x0, x9
    bl free
    str xzr, [x19, #RD_REMAINDER]
    str xzr, [x19, #RD_REM_LEN]
.Lwrr_rem_ok:
    str xzr, [x19, #RD_DEV]
    str xzr, [x19, #RD_INO]
    str xzr, [x19, #RD_SIZE]
    str xzr, [x19, #RD_MTIME]
    ldr x9, [x19, #RD_ENTER]
    str x9, [x19, #RD_EXIT]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_bucket_find(rd, second, login, len, state) -> x0 = bucket ptr or 0.
//   Binary search over the sorted (second, login, state) bucket array.
    .p2align 2
watch_bucket_find:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // second
    mov x21, x2                        // login
    mov x22, x3                        // len
    mov x23, x4                        // state
    ldr x24, [x19, #RD_BUCKET_N]
    ldr x25, [x19, #RD_BUCKETS]
    mov x26, #0                        // lo
.Lwbf_loop:
    cmp x26, x24
    b.ge .Lwbf_none
    sub x9, x24, x26
    lsr x9, x9, #1
    add x9, x26, x9                    // mid
    mov x10, #BK_SZ
    mul x10, x9, x10
    add x10, x25, x10                  // mid bucket
    ldr x11, [x10, #BK_SECOND]
    cmp x20, x11
    b.lt .Lwbf_hi
    b.gt .Lwbf_lo
    // seconds equal: compare login
    add x12, x10, #BK_LOGIN
    mov x0, x21
    mov x1, x12
    mov x2, x22
    mov x3, #26
    bl watch_memcmp_n                  // <0 / 0 / >0
    cmp x0, #0
    b.lt .Lwbf_hi
    b.gt .Lwbf_lo
    // login equal: compare state
    ldrb w13, [x10, #BK_STATE]
    cmp w23, w13
    b.lt .Lwbf_hi
    b.gt .Lwbf_lo
    // found
    mov x0, x10
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwbf_hi:
    mov x24, x9
    b .Lwbf_loop
.Lwbf_lo:
    add x26, x9, #1
    b .Lwbf_loop
.Lwbf_none:
    mov x0, #0
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_bucket_insert(rd, second, login, len, state) -> x0 = bucket ptr.
//   Appends or binary-search inserts, keeping (second, login, state) order.
    .p2align 2
watch_bucket_insert:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // second
    mov x21, x2                        // login
    mov x22, x3                        // len
    mov x23, x4                        // state
    ldr x24, [x19, #RD_BUCKET_N]
    ldr x25, [x19, #RD_BUCKET_CAP]
    // grow?
    cmp x24, x25
    b.lt .Lwbi_grown
    cbz x25, .Lwbi_new
    lsl x25, x25, #1
    b .Lwbi_alloc
.Lwbi_new:
    mov x25, #BK_INIT
.Lwbi_alloc:
    mov x26, x25                       // new cap
    ldr x0, [x19, #RD_BUCKETS]
    mov x1, #BK_SZ
    mul x1, x25, x1
    bl realloc
    cbz x0, .Lwbi_oom
    str x0, [x19, #RD_BUCKETS]
    str x26, [x19, #RD_BUCKET_CAP]
.Lwbi_grown:
    // find the insertion position: lower_bound over (second, login, state)
    ldr x24, [x19, #RD_BUCKET_N]
    ldr x25, [x19, #RD_BUCKETS]
    mov x26, #0                        // lo
    mov x27, x24                       // hi
.Lwbi_bs:
    cmp x26, x27
    b.ge .Lwbi_pos
    sub x9, x27, x26
    lsr x9, x9, #1
    add x9, x26, x9                    // mid
    mov x10, #BK_SZ
    mul x10, x9, x10
    add x10, x25, x10
    ldr x11, [x10, #BK_SECOND]
    cmp x20, x11
    b.lt .Lwbi_hi
    b.gt .Lwbi_lo
    add x12, x10, #BK_LOGIN
    mov x0, x21
    mov x1, x12
    mov x2, x22
    mov x3, #26
    bl watch_memcmp_n
    cmp x0, #0
    b.lt .Lwbi_hi
    b.gt .Lwbi_lo
    ldrb w13, [x10, #BK_STATE]
    cmp w23, w13
    b.lt .Lwbi_hi
    b.gt .Lwbi_lo
    mov x26, x9                        // equal: insert before (insort)
    b .Lwbi_pos
.Lwbi_hi:
    mov x27, x9
    b .Lwbi_bs
.Lwbi_lo:
    add x26, x9, #1
    b .Lwbi_bs
.Lwbi_pos:
    // shift [pos, n) up by one; pos = x26
    ldr x28, [x19, #RD_BUCKET_N]
    mov x9, #BK_SZ
    mul x9, x28, x9                    // x9 = n*BK_SZ
    add x10, x25, x9                   // src = one past the last
    mov x27, x26                       // stop bound = pos (buckets)
    mov x11, #BK_SZ
    mul x27, x27, x11                  // x27 = pos*BK_SZ
.Lwbi_shift:
    cmp x9, x27
    b.le .Lwbi_shift_done
    sub x11, x10, #BK_SZ
    ldrb w12, [x11, #0]
    strb w12, [x10, #0]
    ldrb w12, [x11, #1]
    strb w12, [x10, #1]
    ldrb w12, [x11, #2]
    strb w12, [x10, #2]
    ldrb w12, [x11, #3]
    strb w12, [x10, #3]
    ldrb w12, [x11, #4]
    strb w12, [x10, #4]
    ldrb w12, [x11, #5]
    strb w12, [x10, #5]
    ldrb w12, [x11, #6]
    strb w12, [x10, #6]
    ldrb w12, [x11, #7]
    strb w12, [x10, #7]
    ldrb w12, [x11, #8]
    strb w12, [x10, #8]
    ldrb w12, [x11, #9]
    strb w12, [x10, #9]
    ldrb w12, [x11, #10]
    strb w12, [x10, #10]
    ldrb w12, [x11, #11]
    strb w12, [x10, #11]
    ldrb w12, [x11, #12]
    strb w12, [x10, #12]
    ldrb w12, [x11, #13]
    strb w12, [x10, #13]
    ldrb w12, [x11, #14]
    strb w12, [x10, #14]
    ldrb w12, [x11, #15]
    strb w12, [x10, #15]
    ldrb w12, [x11, #16]
    strb w12, [x10, #16]
    ldrb w12, [x11, #17]
    strb w12, [x10, #17]
    ldrb w12, [x11, #18]
    strb w12, [x10, #18]
    ldrb w12, [x11, #19]
    strb w12, [x10, #19]
    ldrb w12, [x11, #20]
    strb w12, [x10, #20]
    ldrb w12, [x11, #21]
    strb w12, [x10, #21]
    ldrb w12, [x11, #22]
    strb w12, [x10, #22]
    ldrb w12, [x11, #23]
    strb w12, [x10, #23]
    ldrb w12, [x11, #24]
    strb w12, [x10, #24]
    ldrb w12, [x11, #25]
    strb w12, [x10, #25]
    ldrb w12, [x11, #26]
    strb w12, [x10, #26]
    ldrb w12, [x11, #27]
    strb w12, [x10, #27]
    ldrb w12, [x11, #28]
    strb w12, [x10, #28]
    ldrb w12, [x11, #29]
    strb w12, [x10, #29]
    ldrb w12, [x11, #30]
    strb w12, [x10, #30]
    ldrb w12, [x11, #31]
    strb w12, [x10, #31]
    ldrb w12, [x11, #32]
    strb w12, [x10, #32]
    ldrb w12, [x11, #33]
    strb w12, [x10, #33]
    ldrb w12, [x11, #34]
    strb w12, [x10, #34]
    ldrb w12, [x11, #35]
    strb w12, [x10, #35]
    ldrb w12, [x11, #36]
    strb w12, [x10, #36]
    ldrb w12, [x11, #37]
    strb w12, [x10, #37]
    ldrb w12, [x11, #38]
    strb w12, [x10, #38]
    ldrb w12, [x11, #39]
    strb w12, [x10, #39]
    ldrb w12, [x11, #40]
    strb w12, [x10, #40]
    ldrb w12, [x11, #41]
    strb w12, [x10, #41]
    ldrb w12, [x11, #42]
    strb w12, [x10, #42]
    ldrb w12, [x11, #43]
    strb w12, [x10, #43]
    ldrb w12, [x11, #44]
    strb w12, [x10, #44]
    ldrb w12, [x11, #45]
    strb w12, [x10, #45]
    ldrb w12, [x11, #46]
    strb w12, [x10, #46]
    ldrb w12, [x11, #47]
    strb w12, [x10, #47]
    mov x10, x11
    sub x9, x9, #BK_SZ
    b .Lwbi_shift
.Lwbi_shift_done:
    // fill the new record at [pos]
    mov x9, #BK_SZ
    mul x9, x26, x9
    add x10, x25, x9
    str x20, [x10, #BK_SECOND]
    add x10, x10, #BK_LOGIN
    mov x11, #0
.Lwbi_copy:
    cmp x11, x22
    b.ge .Lwbi_copy_done
    ldrb w12, [x21, x11]
    strb w12, [x10, x11]
    add x11, x11, #1
    b .Lwbi_copy
.Lwbi_copy_done:
    mov w12, #0
    strb w12, [x10, x11]
    strb w23, [x10, #(BK_STATE - BK_LOGIN)]
    mov x12, #1
    str x12, [x10, #(BK_N - BK_LOGIN)]
    ldr x12, [x19, #RD_BUCKET_N]
    add x12, x12, #1
    str x12, [x19, #RD_BUCKET_N]
    mov x0, x10
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwbi_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// watch_memcmp_n(a, b, n1, n2) -> x0 = -1/0/1: compare a[0..n1) (NUL padded)
//   against b[0..n2); the shorter string sorts first when it is a prefix.
    .p2align 2
watch_memcmp_n:
    mov x3, #0
.Lwmcn_loop:
    cmp x3, x2
    b.ge .Lwmcn_cmp_end
    ldrb w4, [x0, x3]
    ldrb w5, [x1, x3]
    cmp w4, w5
    b.ne .Lwmcn_cmp
    add x3, x3, #1
    b .Lwmcn_loop
.Lwmcn_cmp_end:
    ldrb w4, [x0, x3]
    ldrb w5, [x1, x3]
    cmp w4, w5
    b.ne .Lwmcn_cmp
    mov w0, #0
    ret
.Lwmcn_cmp:
    cmp w4, w5
    b.lt .Lwmcn_lt
    mov w0, #1
    ret
.Lwmcn_lt:
    mov w0, #-1
    ret

// ============================================================================
// watch_reader_refresh(rd, stat, enter, floor) -> x0 = RD_OK_NEW / RD_OK_NONE
//   / RD_ERR.  The Python TailReader.refresh: identity + size checks, cold
//   seek, read the appended bytes, fold complete lines.
//   in: x0 = rd, x1 = stat ptr, x2 = enter state, x3 = floor (u64)
//   Register roles: x19=rd, x20=stat, x21=enter, x22=floor, x23=fd,
//   x24=text buf, x25=text len, x26=scratch, x27=cold flag (survives calls),
//   x28=scratch2.
// ============================================================================
// watch_reader_refresh(rd, stat, enter, floor) -> x0 = RD_OK_NEW / RD_OK_NONE
//   / RD_ERR.  The Python TailReader.refresh: identity + size checks, cold
//   seek, read the appended bytes, fold complete lines.
//   in: x0 = rd, x1 = stat ptr, x2 = enter state, x3 = floor (u64)
//   Register roles: x19=rd, x20=stat, x21=enter, x22=floor, x23=fd,
//   x24=text buf, x25=text len, x26=scratch, x27=cold flag (survives calls),
//   x28=scratch2.
// ============================================================================
// watch_reader_refresh(rd, stat, enter, floor) -> x0 = RD_OK_NEW / RD_OK_NONE
//   / RD_ERR.  The Python TailReader.refresh: identity + size checks, cold
//   seek, read the appended bytes, fold complete lines.
//   in: x0 = rd, x1 = stat ptr, x2 = enter state, x3 = floor (u64)
//   Register roles: x19=rd, x20=stat, x21=enter, x22=floor, x23=fd,
//   x24=text buf, x25=text len, x26=scratch, x27=cold flag (survives calls),
//   x28=scratch2.
// ============================================================================
    .p2align 2
watch_reader_refresh:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // stat
    mov x21, x2                        // enter
    mov x22, x3                        // floor
    // identity = (st_dev, st_ino); rewound = size < offset or identity changed
    ldr x23, [x20, #ST_DEV]
    ldr x24, [x20, #ST_INO]
    ldr x25, [x20, #ST_SIZE]
    ldr x26, [x19, #RD_OFFSET]
    cmp x25, x26
    b.lt .Lwrrf_reset
    ldr x26, [x19, #RD_DEV]
    cbz x26, .Lwrrf_id_ok
    ldr x26, [x19, #RD_DEV]
    cmp x23, x26
    b.ne .Lwrrf_reset
    ldr x26, [x19, #RD_INO]
    cmp x24, x26
    b.ne .Lwrrf_reset
    b .Lwrrf_id_ok
.Lwrrf_reset:
    mov x0, x19
    bl watch_reader_reset
    str x21, [x19, #RD_ENTER]
.Lwrrf_id_ok:
    str x23, [x19, #RD_DEV]
    str x24, [x19, #RD_INO]
    str x25, [x19, #RD_SIZE]
    ldr x26, [x20, #ST_MTIM_SEC]
    movz x27, #0xCA00, lsl #0
    movk x27, #0x3B9A, lsl #16         // 1000000000
    mul x26, x26, x27
    ldr x27, [x20, #ST_MTIM_NSEC]
    add x26, x26, x27
    str x26, [x19, #RD_MTIME]
    // nothing appended? (size == offset and offset != 0)
    ldr x26, [x19, #RD_OFFSET]
    cbz x26, .Lwrrf_read
    cmp x25, x26
    b.ne .Lwrrf_read
    mov x0, #RD_OK_NONE
    b .Lwrrf_out
.Lwrrf_read:
    // cold = (pre-read offset == 0); keep it in x27 across the read loop
    ldr x27, [x19, #RD_OFFSET]
    cbz x27, .Lwrrf_cold1
    mov x27, #0
    b .Lwrrf_cold_done
.Lwrrf_cold1:
    mov x27, #1
.Lwrrf_cold_done:
    // open + lseek to offset
    add x0, x19, #RD_PATH
    mov x1, #O_RDONLY
    bl open
    mov w23, w0
    cmp w23, #0
    b.lt .Lwrrf_err
    mov x0, x23
    ldr x1, [x19, #RD_OFFSET]
    mov x2, #SEEK_SET
    bl lseek
    cmp x0, #0
    b.lt .Lwrrf_close_err
    // read all remaining into a growing buffer (cap FILE_CAP)
    mov x24, #0                         // buf
    mov x25, #0                         // len
    mov x26, #0                         // cap
.Lwrrf_rloop:
    cmp x26, #0
    b.ne .Lwrrf_grow_ok
    mov x26, #READ_CHUNK
    mov x0, x26
    bl malloc
    cbz x0, .Lwrrf_alloc_err
    mov x24, x0
    str x24, [x19, #RD_TEXT_BASE]      // remember the malloc base
    b .Lwrrf_grow_ok
.Lwrrf_grow_ok:
    cmp x25, x26
    b.lt .Lwrrf_read_chunk
    lsl x26, x26, #1
    ldr x9, =FILE_CAP
    cmp x26, x9
    b.le .Lwrrf_grow2
    mov x26, x9
.Lwrrf_grow2:
    mov x0, x24
    mov x1, x26
    bl realloc
    cbz x0, .Lwrrf_alloc_err
    mov x24, x0
    str x24, [x19, #RD_TEXT_BASE]      // realloc may have moved the base
.Lwrrf_read_chunk:
    mov x0, x23
    add x1, x24, x25
    sub x2, x26, x25                  // remaining capacity
    mov x9, #READ_CHUNK
    cmp x2, x9
    b.lt .Lwrrf_read_ok
    mov x2, x9
.Lwrrf_read_ok:
    bl read
    mov w9, w0                         // bytes this read (caller-saved, ok)
    cmp w9, #0
    b.lt .Lwrrf_eintr
    cbz w9, .Lwrrf_read_done
    add x25, x25, x9
    ldr x9, =FILE_CAP
    cmp x25, x9
    b.le .Lwrrf_rloop
    b .Lwrrf_close_err
.Lwrrf_eintr:
    cmp w9, #EINTR
    b.eq .Lwrrf_rloop
    b .Lwrrf_close_err
.Lwrrf_read_done:
    mov x0, x23
    bl close
    // new offset = old offset + bytes read
    ldr x9, [x19, #RD_OFFSET]
    add x9, x9, x25
    str x9, [x19, #RD_OFFSET]
    // text = remainder + chunk
    ldr x26, [x19, #RD_REMAINDER]
    ldr x28, [x19, #RD_REM_LEN]
    cbz x26, .Lwrrf_text
    // stash the old chunk base, join, then free it (it is not reused)
    adrp x9, PAGE(tc_watch_join_old)
    add x9, x9, LO12(tc_watch_join_old)
    str x24, [x9]
    mov x0, x24                        // chunk (a)
    mov x1, x26                        // remainder (b)
    mov x2, x28                        // blen
    mov x3, x25                        // alen
    bl watch_join_bufs                 // x0 = combined, x1 = total len
    mov x26, x0                        // combined (x26: remainder was dead)
    mov x25, x1                        // total len
    adrp x9, PAGE(tc_watch_join_old)
    add x9, x9, LO12(tc_watch_join_old)
    ldr x0, [x9]
    cbz x0, .Lwrrf_join_free_done
    bl free
    str xzr, [x9]
.Lwrrf_join_free_done:
    mov x24, x26
    str x24, [x19, #RD_TEXT_BASE]      // the combined buffer is what to free
    b .Lwrrf_text_done
.Lwrrf_text:
    // text = chunk alone
.Lwrrf_text_done:
    // cold + floor: seek past everything older than floor
    cbz x27, .Lwrrf_after_seek
    cbz x22, .Lwrrf_after_seek
    mov x0, x24
    mov x1, x25
    mov x2, x22
    bl watch_seek_window               // x0 = start or -1, x1 = entering or -1
    cmp x0, #0
    b.le .Lwrrf_after_seek
    add x24, x24, x0
    sub x25, x25, x0
    mov x26, #1
    str x26, [x19, #RD_PARTIAL]
    cmp x1, #0
    b.lt .Lwrrf_after_seek
    str x1, [x19, #RD_EXIT]
.Lwrrf_after_seek:
    // cut at the last '\n'
    mov x0, x24
    mov x1, x25
    bl watch_last_newline              // x0 = index or -1
    cmp x0, #0
    b.lt .Lwrrf_hold_all
    // cut = x0; remainder = text[cut+1:]; fold text[:cut]
    mov x28, x0                        // cut (callee-saved)
    add x26, x0, #1
    sub x9, x25, x26                   // remainder len
    cbz x9, .Lwrrf_no_rem
    mov x0, x9
    bl malloc
    cbz x0, .Lwrrf_rem_oom
    mov x1, x24
    add x1, x1, x26
    mov x2, x9
    bl watch_copy_to                  // x0 = end of copy; we need the base
    sub x0, x0, x9
    mov x23, x9                        // rem len (fd reg now free)
    mov x26, x0                        // rem ptr
    ldr x9, [x19, #RD_REMAINDER]
    cbz x9, .Lwrrf_rem_old_ok
    mov x0, x9
    bl free
.Lwrrf_rem_old_ok:
    str x26, [x19, #RD_REMAINDER]
    str x23, [x19, #RD_REM_LEN]
    b .Lwrrf_fold
.Lwrrf_no_rem:
    ldr x9, [x19, #RD_REMAINDER]
    cbz x9, .Lwrrf_rem0_ok
    mov x0, x9
    bl free
.Lwrrf_rem0_ok:
    str xzr, [x19, #RD_REMAINDER]
    str xzr, [x19, #RD_REM_LEN]
.Lwrrf_fold:
    mov x0, x19
    mov x1, x24
    mov x2, x28                        // fold text[:cut]
    bl watch_fold_lines
    // revision++, lifetime counters
    ldr x9, [x19, #RD_REVISION]
    add x9, x9, #1
    str x9, [x19, #RD_REVISION]
    cbz x27, .Lwrrf_app
    ldr x9, [x19, #RD_FULLREADS]
    add x9, x9, #1
    str x9, [x19, #RD_FULLREADS]
    b .Lwrrf_ctr_done
.Lwrrf_app:
    ldr x9, [x19, #RD_APPENDS]
    add x9, x9, #1
    str x9, [x19, #RD_APPENDS]
.Lwrrf_ctr_done:
    mov x0, #RD_OK_NEW
    b .Lwrrf_cleanup
.Lwrrf_hold_all:
    cbz x25, .Lwrrf_hold_none
    mov x0, x25
    bl malloc
    cbz x0, .Lwrrf_rem_oom
    mov x1, x24
    mov x2, x25
    bl watch_copy_to
    sub x0, x0, x25
    mov x26, x0
    ldr x9, [x19, #RD_REMAINDER]
    cbz x9, .Lwrrf_hold_old_ok
    mov x0, x9
    bl free
.Lwrrf_hold_old_ok:
    str x26, [x19, #RD_REMAINDER]
    str x25, [x19, #RD_REM_LEN]
    b .Lwrrf_hold_done
.Lwrrf_hold_none:
    str xzr, [x19, #RD_REMAINDER]
    str xzr, [x19, #RD_REM_LEN]
.Lwrrf_hold_done:
    mov x0, #RD_OK_NONE
.Lwrrf_cleanup:
    mov x28, x0                        // result (x28 dead at cleanup)
    ldr x26, [x19, #RD_TEXT_BASE]      // free the malloc base (the seek may
    cbz x26, .Lwrrf_cleanup_no_base    // have advanced x24 into the buffer)
    mov x0, x26
    bl free
    str xzr, [x19, #RD_TEXT_BASE]
.Lwrrf_cleanup_no_base:
    mov x19, x28                       // result
.Lwrrf_cleanup2:
    mov x0, x19
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrrf_close_err:
    mov x0, x23
    bl close
.Lwrrf_err:
    mov x0, #RD_ERR
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrrf_alloc_err:
    mov x0, x23
    bl close
    b .Lwrrf_err
.Lwrrf_rem_oom:
    mov x0, #RD_ERR
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrrf_out:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_join_bufs(a, b, blen, alen) -> (x0 = malloc'd a+b, x1 = total len)
    .p2align 2
watch_join_bufs:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // a
    mov x20, x1                        // b
    mov x21, x2                        // blen
    mov x22, x3                        // alen
    add x0, x21, x22
    mov x23, x0
    bl malloc
    cbz x0, .Lwjb_oom
    mov x24, x0
    mov x0, x24
    mov x1, x20
    mov x2, x21
    bl watch_copy_to
    mov x0, x24
    add x0, x0, x21
    mov x1, x19
    mov x2, x22
    bl watch_copy_to
    mov x0, x24
    mov x1, x23
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwjb_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// watch_copy_to(dst, src, len) -> dst + len
    .p2align 2
watch_copy_to:
    mov x3, #0
.Lwct_loop:
    cmp x3, x2
    b.ge .Lwct_done
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    b .Lwct_loop
.Lwct_done:
    add x0, x0, x2
    ret

// watch_last_newline(buf, len) -> x0 = index of the last '\n' or -1
    .p2align 2
watch_last_newline:
    add x2, x0, x1
.Lwln_loop:
    cmp x2, x0
    b.le .Lwln_none
    sub x2, x2, #1
    ldrb w3, [x2]
    cmp w3, #'\n'
    b.ne .Lwln_loop
    sub x0, x2, x0
    ret
.Lwln_none:
    mov x0, #-1
    ret

// ============================================================================
// watch_seek_window(text, len, floor) -> (x0 = start offset or -1, x1 =
//   entering state 0/1/2 or -1).  Port of Python seek_window + line_at_or_after.
// ============================================================================
    .p2align 2
watch_seek_window:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // text
    mov x20, x1                        // len
    mov x21, x2                        // floor
    cbz x21, .Lwsw_zero
    // want = "%02d:%02d:%02d"
    adrp x22, PAGE(tc_watch_want)
    add x22, x22, LO12(tc_watch_want)
    mov x9, #3600
    udiv x23, x21, x9                  // h
    msub x10, x23, x9, x21
    mov x9, #60
    udiv x24, x10, x9                  // m
    msub x25, x24, x9, x10             // s
    mov x0, x22
    mov x1, x23
    bl watch_fmt2
    mov w1, #':'
    strb w1, [x0], #1
    mov x1, x24
    bl watch_fmt2
    mov w1, #':'
    strb w1, [x0], #1
    mov x1, x25
    bl watch_fmt2
    mov w1, #0
    strb w1, [x0]
    // start = line_at_or_after(text, want)
    mov x0, x19
    mov x1, x20
    mov x2, x22
    bl watch_line_at_or_after          // x0 = offset or len
    cmp x0, #0
    b.le .Lwsw_zero                    // start <= 0 -> (0, None) ... Python returns 0
    // Python: if start <= 0: return 0, None  (start==0 means the whole text is inside)
    cmp x0, #0
    b.eq .Lwsw_zero
    mov x22, x0                        // start
    // scan the prefix for the last " is live!" / " is now offline." marker
    mov x23, #-1                       // state
    mov x24, #-1                       // best line_start
    // literal 1: " is live!"
    mov x26, x22                       // prefix end
    mov x25, #0                        // search from 0
.Lwsw_scan1:
    // find " is live!" in prefix [0, x26); then validate the line via LIVE_RE
    mov x0, x19
    mov x1, x26
    mov x2, #0
    adrp x3, PAGE(lit_is_live)
    add x3, x3, LO12(lit_is_live)
    mov x4, #9                         // len(" is live!") == 9
    bl watch_rfind                     // x0 = index or -1
    cmp x0, #0
    b.lt .Lwsw_scan2
    mov x26, x0                        // at
    // line_start = rfind("\n", 0, at) + 1
    mov x0, x19
    mov x1, x26
    mov x2, #0
    mov x3, #'\n'
    bl watch_rfind_char                // x0 = newline index or -1
    add x27, x0, #1                    // line_start
    // line_end = find("\n", at) or len
    mov x0, x19
    mov x1, x22
    mov x2, x26
    mov x3, #'\n'
    bl watch_find_char                 // x0 = index or -1
    cmp x0, #0
    b.lt .Lwsw_le_end
    mov x28, x0                        // line_end
    b .Lwsw_line
.Lwsw_le_end:
    mov x28, x22                       // len
.Lwsw_line:
    // line = prefix[line_start:line_end]; LIVE_RE.match?
    sub x0, x28, x27
    mov x1, x0
    add x0, x19, x27
    bl watch_line_is_marker            // x0 = state 1/2 or 0
    cbz x0, .Lwsw_not1
    // marker: keep the latest (line_start > best)
    cmp x24, #-1
    b.eq .Lwsw_best1
    cmp x27, x24
    b.le .Lwsw_not1
.Lwsw_best1:
    mov x24, x27
    mov x23, x0
.Lwsw_not1:
    // continue searching before `at`
    mov x26, x27
    cmp x26, #0
    b.gt .Lwsw_scan1
.Lwsw_scan2:
    // literal 2: " is now offline." (len 17)
    mov x26, x22
.Lwsw_scan2loop:
    mov x0, x19
    mov x1, x26
    mov x2, #0
    adrp x3, PAGE(lit_offline)
    add x3, x3, LO12(lit_offline)
    mov x4, #16
    bl watch_rfind
    cmp x0, #0
    b.lt .Lwsw_done
    mov x26, x0
    mov x0, x19
    mov x1, x26
    mov x2, #0
    mov x3, #'\n'
    bl watch_rfind_char
    add x27, x0, #1
    mov x0, x19
    mov x1, x22
    mov x2, x26
    mov x3, #'\n'
    bl watch_find_char
    cmp x0, #0
    b.lt .Lwsw_le2_end
    mov x28, x0
    b .Lwsw_line2
.Lwsw_le2_end:
    mov x28, x22
.Lwsw_line2:
    sub x0, x28, x27
    mov x1, x0
    add x0, x19, x27
    bl watch_line_is_marker
    cbz x0, .Lwsw_not2
    cmp x24, #-1
    b.eq .Lwsw_best2
    cmp x27, x24
    b.le .Lwsw_not2
.Lwsw_best2:
    mov x24, x27
    mov x23, x0
.Lwsw_not2:
    mov x26, x27
    cmp x26, #0
    b.gt .Lwsw_scan2loop
.Lwsw_done:
    mov x0, x22                        // start
    mov x1, x23                        // state or -1
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwsw_zero:
    mov x0, #0
    mov x1, #-1
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_fmt2(dst, x1=0..99) -> dst+2 zero-padded
    .p2align 2
watch_fmt2:
    mov x2, #10
    udiv x3, x1, x2
    msub x4, x3, x2, x1
    add x3, x3, #'0'
    strb w3, [x0], #1
    add x4, x4, #'0'
    strb w4, [x0], #1
    ret

// watch_line_at_or_after(text, len, want) -> x0 = offset of the first line
//   whose "[HH:MM:SS]" >= want, or len.  Python line_at_or_after (1537-1560).
    .p2align 2
watch_line_at_or_after:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // text
    mov x20, x1                        // len (size)
    mov x21, x2                        // want
    mov x22, #65536                    // span
.Lwloa_outer:
    cmp x22, x20
    b.ge .Lwloa_start0
    // start = text.find("\n", size - span) + 1
    sub x23, x20, x22
    mov x0, x19
    mov x1, x20
    mov x2, x23
    mov x3, #'\n'
    bl watch_find_char                 // x0 = index or -1
    add x23, x0, #1                    // start
    b .Lwloa_start_done
.Lwloa_start0:
    mov x23, #0
.Lwloa_start_done:
    mov x24, x23                       // pos
    mov x25, #-1                       // found
.Lwloa_inner:
    cmp x24, x20
    b.ge .Lwloa_inner_done
    ldrb w9, [x19, x24]
    cmp w9, #'['
    b.ne .Lwloa_nextline
    // compare text[pos+1:pos+9] >= want
    mov x0, x19
    mov x1, x20
    add x2, x24, #1
    mov x3, #8
    mov x4, x21
    bl watch_strncmp_ge                // x0 = 1 if >=, 0 if <
    cbz x0, .Lwloa_nextline
    mov x25, x24
    b .Lwloa_inner_done
.Lwloa_nextline:
    mov x0, x19
    mov x1, x20
    mov x2, x24
    mov x3, #'\n'
    bl watch_find_char
    cmp x0, #0
    b.lt .Lwloa_inner_done
    add x24, x0, #1
    b .Lwloa_inner
.Lwloa_inner_done:
    cmp x25, #0
    b.ge .Lwloa_found
    // nothing at or after want -> return size
    mov x0, x20
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwloa_found:
    cmp x25, x23
    b.gt .Lwloa_ret
    cbz x23, .Lwloa_ret
    lsl x22, x22, #1
    b .Lwloa_outer
.Lwloa_ret:
    mov x0, x25
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_strncmp_ge(text, len, off, n, want) -> x0 = 1 if text[off:off+n] >=
//   want (byte compare, exactly Python's slice >=), else 0.
    .p2align 2
watch_strncmp_ge:
    mov x5, #0
.Lwsg_loop:
    cmp x5, x3
    b.ge .Lwsg_eq
    ldrb w6, [x0, x2]
    ldrb w7, [x4, x5]
    cmp w6, w7
    b.lt .Lwsg_lt
    b.gt .Lwsg_gt
    add x2, x2, #1
    add x5, x5, #1
    b .Lwsg_loop
.Lwsg_eq:
    mov w0, #1
    ret
.Lwsg_gt:
    mov w0, #1
    ret
.Lwsg_lt:
    mov w0, #0
    ret

// watch_find_char(buf, len, from, ch) -> x0 = index of ch at/after `from`, or -1
    .p2align 2
watch_find_char:
    mov x4, x2
.Lwfc_loop:
    cmp x4, x1
    b.ge .Lwfc_none
    ldrb w5, [x0, x4]
    cmp w5, w3
    b.eq .Lwfc_found
    add x4, x4, #1
    b .Lwfc_loop
.Lwfc_found:
    mov x0, x4
    ret
.Lwfc_none:
    mov x0, #-1
    ret

// watch_rfind_char(buf, len, from, ch) -> x0 = index of ch in [from, len), -1
    .p2align 2
watch_rfind_char:
    mov x4, x1
.Lwrfc_loop:
    cmp x4, x2
    b.le .Lwrfc_none
    sub x4, x4, #1
    ldrb w5, [x0, x4]
    cmp w5, w3
    b.eq .Lwrfc_found
    b .Lwrfc_loop
.Lwrfc_found:
    mov x0, x4
    ret
.Lwrfc_none:
    mov x0, #-1
    ret

// watch_rfind(buf, len, from, literal, litlen) -> x0 = index of the literal
//   at or before `from`, or -1 (Python prefix.rfind(literal)).
    .p2align 2
watch_rfind:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // buf
    mov x20, x4                        // litlen
    // search window: [from, len)
    mov x9, x2                         // from
.Lwrfl_loop:
    cmp x9, x1
    b.ge .Lwrfl_none
    sub x10, x1, x9                    // remaining
    cmp x10, x20
    b.lt .Lwrfl_none
    // compare literal at buf+from
    mov x11, #0
.Lwrfl_cmp:
    cmp x11, x20
    b.ge .Lwrfl_found
    ldrb w12, [x19, x9]
    ldrb w13, [x3, x11]
    add x9, x9, #1
    add x11, x11, #1
    cmp w12, w13
    b.ne .Lwrfl_back
    b .Lwrfl_cmp
.Lwrfl_back:
    // mismatch: back up the search pointer by 1 from the matched start
    sub x9, x9, x11
    add x9, x9, #1
    b .Lwrfl_loop
.Lwrfl_found:
    sub x0, x9, x20
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrfl_none:
    mov x0, #-1
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_line_is_marker(line, len) -> x0 = 1 (live) / 2 (offline) / 0.
//   LIVE_RE: ^\[\d{2}:\d{2}:\d{2}\] \S+ is (live!|now offline\.)$
    .p2align 2
watch_line_is_marker:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    // shape: [HH:MM:SS] then space then \S+ then " is live!" / " is now offline."
    cmp x20, #12
    b.lt .Lwlim_no
    ldrb w3, [x19]
    cmp w3, #'['
    b.ne .Lwlim_no
    ldrb w3, [x19, #1]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwlim_no
    ldrb w3, [x19, #2]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwlim_no
    ldrb w3, [x19, #3]
    cmp w3, #':'
    b.ne .Lwlim_no
    ldrb w3, [x19, #4]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwlim_no
    ldrb w3, [x19, #5]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwlim_no
    ldrb w3, [x19, #6]
    cmp w3, #':'
    b.ne .Lwlim_no
    ldrb w3, [x19, #7]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwlim_no
    ldrb w3, [x19, #8]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwlim_no
    ldrb w3, [x19, #9]
    cmp w3, #']'
    b.ne .Lwlim_no
    ldrb w3, [x19, #10]
    cmp w3, #' '
    b.ne .Lwlim_no
    // \S+ = at least one char without a space before the trailing literal
    // find " is live!" at the end
    add x9, x19, #11                  // speaker start
    add x10, x19, x20                  // end
    // suffix check: " is live!" (len 9)
    sub x11, x10, #9
    cmp x11, x9
    b.lt .Lwlim_off
    adrp x12, PAGE(lit_is_live)
    add x12, x12, LO12(lit_is_live)
    mov x13, #0
.Lwlim_cl1:
    cmp x13, #9
    b.ge .Lwlim_live
    ldrb w14, [x11, x13]
    ldrb w15, [x12, x13]
    cmp w14, w15
    b.ne .Lwlim_off
    add x13, x13, #1
    b .Lwlim_cl1
.Lwlim_live:
    // the speaker [11, x11) must not contain a space
    mov x13, x9
.Lwlim_ns1:
    cmp x13, x11
    b.ge .Lwlim_yes1
    ldrb w14, [x13]
    cmp w14, #' '
    b.eq .Lwlim_off
    add x13, x13, #1
    b .Lwlim_ns1
.Lwlim_yes1:
    mov w0, #1
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwlim_off:
    // suffix check: " is now offline." (len 16)
    sub x11, x10, #16
    cmp x11, x9
    b.lt .Lwlim_no
    adrp x12, PAGE(lit_offline)
    add x12, x12, LO12(lit_offline)
    mov x13, #0
.Lwlim_cl2:
    cmp x13, #16
    b.ge .Lwlim_off2
    ldrb w14, [x11, x13]
    ldrb w15, [x12, x13]
    cmp w14, w15
    b.ne .Lwlim_no
    add x13, x13, #1
    b .Lwlim_cl2
.Lwlim_off2:
    mov x13, x9
.Lwlim_ns2:
    cmp x13, x11
    b.ge .Lwlim_yes2
    ldrb w14, [x13]
    cmp w14, #' '
    b.eq .Lwlim_no
    add x13, x13, #1
    b .Lwlim_ns2
.Lwlim_yes2:
    mov w0, #2
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwlim_no:
    mov w0, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
    RODATA
lit_is_live:        .asciz " is live!"
lit_offline:        .asciz " is now offline."
    .text

// ============================================================================
// watch_fold_lines(rd, text, len) — fold complete lines (Python fold_lines).
//   text[:len] contains complete lines ending in '\n'.  Updates the reader's
//   buckets, order, matches and exit state.
// ============================================================================
    .p2align 2
watch_fold_lines:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // text
    mov x21, x2                        // len
    ldr x22, [x19, #RD_EXIT]           // state
    mov x23, #0                        // line start
.Lwfl_loop:
    cmp x23, x21
    b.ge .Lwfl_done
    // find the next '\n'
    mov x0, x20
    mov x1, x21
    mov x2, x23
    mov x3, #'\n'
    bl watch_find_char
    cmp x0, #0
    b.lt .Lwfl_last                    // no newline: fold the final tail
    mov x24, x0                        // newline index
    sub x25, x24, x23                  // line len (excl \n)
    add x26, x24, #1                   // next line start
    add x27, x20, x23                  // line ptr (text + start)
    mov x28, x25                       // line len
    // blank or '#' -> skip
    cbz x28, .Lwfl_next
    ldrb w3, [x27]
    cmp w3, #'#'
    b.eq .Lwfl_next
    // marker?
    mov x0, x27
    mov x1, x28
    bl watch_line_is_marker
    cbnz x0, .Lwfl_marker
    // message?
    mov x0, x19
    mov x1, x27
    mov x2, x28
    mov x3, x22                        // state
    bl watch_fold_line
    b .Lwfl_next
.Lwfl_marker:
    mov x22, x0
.Lwfl_next:
    mov x23, x26
    b .Lwfl_loop
.Lwfl_last:
    // the final line has no trailing newline (Python split("\n") keeps it)
    sub x25, x21, x23
    cbz x25, .Lwfl_done
    add x27, x20, x23                  // line ptr (text + start)
    mov x28, x25                       // line len
    ldrb w3, [x27]
    cmp w3, #'#'
    b.eq .Lwfl_done
    mov x0, x27
    mov x1, x28
    bl watch_line_is_marker
    cbnz x0, .Lwfl_last_marker
    mov x0, x19
    mov x1, x27
    mov x2, x28
    mov x3, x22
    bl watch_fold_line
    b .Lwfl_done
.Lwfl_last_marker:
    mov x22, x0
.Lwfl_done:
    str x22, [x19, #RD_EXIT]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_fold_line(rd, line, len, state) — classify one message line
//   (LINE_RE + speaker_login + bucket + highlight matches).
// ============================================================================
    .p2align 2
watch_fold_line:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // line
    mov x21, x2                        // len
    mov x22, x3                        // state
    // LINE_RE shape (mirror process_message)
    cmp x21, #11
    b.lt .Lwfln_skip
    ldrb w3, [x20]
    cmp w3, #'['
    b.ne .Lwfln_skip
    ldrb w3, [x20, #1]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwfln_skip
    ldrb w3, [x20, #2]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwfln_skip
    ldrb w3, [x20, #3]
    cmp w3, #':'
    b.ne .Lwfln_skip
    ldrb w3, [x20, #4]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwfln_skip
    ldrb w3, [x20, #5]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwfln_skip
    ldrb w3, [x20, #6]
    cmp w3, #':'
    b.ne .Lwfln_skip
    ldrb w3, [x20, #7]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwfln_skip
    ldrb w3, [x20, #8]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lwfln_skip
    ldrb w3, [x20, #9]
    cmp w3, #']'
    b.ne .Lwfln_skip
    ldrb w3, [x20, #10]
    cmp w3, #' '
    b.ne .Lwfln_skip
    // find the first ": " in the rest
    add x24, x20, #11
    add x23, x20, x21                  // end
.Lwfln_colon:
    cmp x24, x23
    b.ge .Lwfln_skip
    ldrb w4, [x24]
    add x24, x24, #1
    cmp w4, #':'
    b.ne .Lwfln_colon
    cmp x24, x23
    b.ge .Lwfln_skip
    ldrb w4, [x24]
    cmp w4, #' '
    b.ne .Lwfln_colon
    sub x24, x24, #1                   // colon at x24
    // speaker = [line+11, x24); no ':' inside
    add x25, x20, #11                  // speaker ptr
    sub x26, x24, x25                  // speaker len
    cbz x26, .Lwfln_skip
    mov x27, #0
.Lwfln_nsp:
    cmp x27, x26
    b.ge .Lwfln_spk_ok
    ldrb w5, [x25, x27]
    cmp w5, #':'
    b.eq .Lwfln_skip
    add x27, x27, #1
    b .Lwfln_nsp
.Lwfln_spk_ok:
    // second-of-day from line[1..8]
    ldrb w5, [x20, #1]
    sub w5, w5, #'0'
    mov x9, #10
    mul x9, x5, x9
    ldrb w5, [x20, #2]
    sub w5, w5, #'0'
    add x9, x9, x5
    mov x10, #3600
    mul x28, x9, x10                   // h*3600 (callee-saved)
    ldrb w5, [x20, #4]
    sub w5, w5, #'0'
    mov x9, #10
    mul x9, x5, x9
    ldrb w5, [x20, #5]
    sub w5, w5, #'0'
    add x9, x9, x5
    mov x10, #60
    mul x9, x9, x10
    add x28, x28, x9
    ldrb w5, [x20, #7]
    sub w5, w5, #'0'
    mov x9, #10
    mul x9, x5, x9
    ldrb w5, [x20, #8]
    sub w5, w5, #'0'
    add x9, x9, x5
    add x28, x28, x9                   // second
    // speaker_login
    mov x0, x25
    mov x1, x26
    bl speaker_login2                  // x0 = login ptr or 0, x1 = len
    cbz x0, .Lwfln_skip
    mov x23, x0                        // login ptr
    mov x24, x1                        // login len
    mov x25, x22                       // state (callee-saved)
    cbnz x25, .Lwfln_state_set
    mov x25, #TC_ST_UNKNOWN
.Lwfln_state_set:
    // bucket find/increment
    mov x0, x19
    mov x1, x28                        // second
    mov x2, x23
    mov x3, x24
    mov x4, x25
    bl watch_bucket_find
    cbnz x0, .Lwfln_inc
    mov x0, x19
    mov x1, x28
    mov x2, x23
    mov x3, x24
    mov x4, x25
    bl watch_bucket_insert
.Lwfln_inc:
    ldr x9, [x0, #BK_N]
    add x9, x9, #1
    str x9, [x0, #BK_N]
    // highlight matching (only when rules exist)
    adrp x9, PAGE(tc_watch_highlight_on)
    add x9, x9, LO12(tc_watch_highlight_on)
    ldr x9, [x9]
    cbz x9, .Lwfln_skip
    // msg = [first ": " colon + 2, end) — re-derive the colon
    add x9, x20, #11
    add x10, x20, x21
.Lwfln_c2:
    cmp x9, x10
    b.ge .Lwfln_skip
    ldrb w5, [x9]
    add x9, x9, #1
    cmp w5, #':'
    b.ne .Lwfln_c2
    cmp x9, x10
    b.ge .Lwfln_skip
    ldrb w5, [x9]
    cmp w5, #' '
    b.ne .Lwfln_c2
    add x26, x9, #1                    // msg ptr (x26 callee-saved)
    sub x27, x10, x26                  // msg len (x27 callee-saved)
    mov x0, x26
    mov x1, x27
    bl watch_highlight_match           // x0 = rule index or -1
    cmp x0, #0
    b.lt .Lwfln_skip
    mov x27, x0                        // rule index (x27 now free)
    // matches append: {second, login, rule}
    ldr x26, [x19, #RD_MATCH_N]
    ldr x9, [x19, #RD_MATCH_CAP]
    cmp x26, x9
    b.lt .Lwfln_mapp
    cbz x9, .Lwfln_mnew
    lsl x9, x9, #1
    b .Lwflm_alloc
.Lwfln_mnew:
    mov x9, #MT_INIT
.Lwflm_alloc:
    mov x25, x9
    ldr x0, [x19, #RD_MATCHES]
    mov x1, #MT_SZ
    mul x1, x9, x1
    bl realloc
    cbz x0, .Lwflm_oom
    str x0, [x19, #RD_MATCHES]
    str x25, [x19, #RD_MATCH_CAP]
.Lwfln_mapp:
    ldr x26, [x19, #RD_MATCH_N]
    ldr x9, [x19, #RD_MATCHES]
    mov x10, #MT_SZ
    mul x10, x26, x10
    add x10, x9, x10
    str x28, [x10, #MT_SECOND]         // second
    add x10, x10, #MT_LOGIN
    mov x11, #0
.Lwfln_mcopy:
    cmp x11, x24                       // login len
    b.ge .Lwfln_mcopy_done
    ldrb w12, [x23, x11]               // login ptr (x23, callee-saved)
    strb w12, [x10, x11]
    add x11, x11, #1
    b .Lwfln_mcopy
.Lwfln_mcopy_done:
    mov w12, #0
    strb w12, [x10, x11]
    strb w27, [x10, #(MT_RULE - MT_LOGIN)]
    add x26, x26, #1
    str x26, [x19, #RD_MATCH_N]
.Lwfln_skip:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwflm_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
// speaker_login2(speaker, slen) -> (x0 = login ptr or 0, x1 = login len).
//   Port of tc_core.S's speaker_login (LOGIN_RE then LOCALIZED_RE); writes
//   the lowercased login into tc_watch_scratch2.
// ============================================================================
    .p2align 2
speaker_login2:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // speaker
    mov x20, x1                        // slen
    cmp x20, #1
    b.lt .Lsl2_fail
    cmp x20, #25
    b.gt .Lsl2_localized
    mov x2, #0
.Lsl2_login:
    cmp x2, x20
    b.ge .Lsl2_login_ok
    ldrb w3, [x19, x2]
    cmp w3, #'0'
    b.lt .Lsl2_localized
    cmp w3, #'9'
    b.le .Lsl2_char_ok
    cmp w3, #'A'
    b.lt .Lsl2_localized
    cmp w3, #'Z'
    b.le .Lsl2_char_ok
    cmp w3, #'_'
    b.eq .Lsl2_char_ok
    cmp w3, #'a'
    b.lt .Lsl2_localized
    cmp w3, #'z'
    b.le .Lsl2_char_ok
    b .Lsl2_localized
.Lsl2_char_ok:
    add x2, x2, #1
    b .Lsl2_login
.Lsl2_login_ok:
    // lowercase into scratch2
    adrp x4, PAGE(tc_watch_scratch2)
    add x4, x4, LO12(tc_watch_scratch2)
    mov x2, #0
.Lsl2_lower:
    cmp x2, x20
    b.ge .Lsl2_lower_done
    ldrb w3, [x19, x2]
    cmp w3, #'A'
    b.lt .Lsl2_lstore
    cmp w3, #'Z'
    b.gt .Lsl2_lstore
    add w3, w3, #('a' - 'A')
.Lsl2_lstore:
    strb w3, [x4, x2]
    add x2, x2, #1
    b .Lsl2_lower
.Lsl2_lower_done:
    mov w3, #0
    strb w3, [x4, x2]
    mov x0, x4
    mov x1, x20
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lsl2_localized:
    // LOCALIZED_RE: ^(\S+) ([a-z0-9_]{1,25})$ with a non-ASCII display
    // find the LAST space
    mov x2, #0
    mov x3, #-1
.Lsl2_find_sp:
    cmp x2, x20
    b.ge .Lsl2_sp_found
    ldrb w4, [x19, x2]
    cmp w4, #' '
    b.ne .Lsl2_sp_next
    mov x3, x2
.Lsl2_sp_next:
    add x2, x2, #1
    b .Lsl2_find_sp
.Lsl2_sp_found:
    cmp x3, #0
    b.lt .Lsl2_fail
    cbz x3, .Lsl2_fail
    mov x6, x3                          // space index
    sub x4, x20, x6
    sub x4, x4, #1                      // right len
    cmp x4, #1
    b.lt .Lsl2_fail
    cmp x4, #25
    b.gt .Lsl2_fail
    add x5, x19, x6
    add x5, x5, #1                      // right start
    mov x2, #0
.Lsl2_right:
    cmp x2, x4
    b.ge .Lsl2_right_ok
    ldrb w3, [x5, x2]
    cmp w3, #'0'
    b.lt .Lsl2_fail
    cmp w3, #'9'
    b.le .Lsl2_right_next
    cmp w3, #'_'
    b.eq .Lsl2_right_next
    cmp w3, #'a'
    b.lt .Lsl2_fail
    cmp w3, #'z'
    b.le .Lsl2_right_next
    b .Lsl2_fail
.Lsl2_right_next:
    add x2, x2, #1
    b .Lsl2_right
.Lsl2_right_ok:
    // left part [0, x6): no space/tab, contains a byte > 127
    mov x2, #0
    mov x7, #0
.Lsl2_left:
    cmp x2, x6
    b.ge .Lsl2_left_ok
    ldrb w3, [x19, x2]
    cmp w3, #' '
    b.eq .Lsl2_fail
    cmp w3, #9
    b.eq .Lsl2_fail
    cmp w3, #128
    b.lt .Lsl2_left_next
    mov x7, #1
.Lsl2_left_next:
    add x2, x2, #1
    b .Lsl2_left
.Lsl2_left_ok:
    cbz x7, .Lsl2_fail
    // login = right (already lowercase); copy into scratch2
    adrp x8, PAGE(tc_watch_scratch2)
    add x8, x8, LO12(tc_watch_scratch2)
    mov x2, #0
.Lsl2_copy:
    cmp x2, x4
    b.ge .Lsl2_copy_done
    ldrb w7, [x5, x2]
    strb w7, [x8, x2]
    add x2, x2, #1
    b .Lsl2_copy
.Lsl2_copy_done:
    mov w7, #0
    strb w7, [x8, x4]
    mov x0, x8
    mov x1, x4
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lsl2_fail:
    mov x0, #0
    mov x1, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_highlight_match(msg, len) -> x0 = rule index (last matching wins)
//   or -1.  Tests each compiled pattern with pcre2_match_8.
// ============================================================================
    .p2align 2
watch_highlight_match:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // msg
    mov x20, x1                        // len
    adrp x9, PAGE(tc_watch_highlight_on)
    add x9, x9, LO12(tc_watch_highlight_on)
    ldr x9, [x9]
    cbz x9, .Lwhm_none
    adrp x21, PAGE(tc_opts)
    add x21, x21, LO12(tc_opts)
    ldr x22, [x21, #TC_O_HL_COUNT]
    mov x23, #-1                       // best
    mov x24, #0                        // rule index
.Lwhm_rule:
    cmp x24, x22
    b.ge .Lwhm_done
    // rule patterns
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    add x9, x9, #TC_O_HL_ARR
    mov x10, #TC_HL_RULE_SZ
    mul x10, x24, x10
    add x9, x9, x10
    ldr x25, [x9, #TC_HL_PAT_COUNT]
    mov x26, #0                        // pattern index
.Lwhm_pat:
    cmp x26, x25
    b.ge .Lwhm_rule_next
    // compiled pattern ptr = tc_watch_patterns[rule*PAT_MAX + pat]
    adrp x9, PAGE(tc_watch_patterns)
    add x9, x9, LO12(tc_watch_patterns)
    mov x10, #TC_HL_PAT_MAX
    mul x10, x24, x10
    add x10, x10, x26
    ldr x9, [x9, x10, lsl #3]
    cbz x9, .Lwhm_pat_next
    // match data for this pattern slot
    adrp x5, PAGE(tc_watch_match_data)
    add x5, x5, LO12(tc_watch_match_data)
    ldr x5, [x5, x10, lsl #3]
    cbz x5, .Lwhm_pat_next
    // pcre2_match_8(code, subject, length, 0, 0, md, 0)
    mov x0, x9
    mov x1, x19
    mov x2, x20
    mov x3, #0
    mov x4, #0
    mov x6, #0
    bl pcre2_match_8
    cmp w0, #0
    b.lt .Lwhm_pat_next
    mov x23, x24                       // match: last rule wins
    b .Lwhm_rule_next
.Lwhm_pat_next:
    add x26, x26, #1
    b .Lwhm_pat
.Lwhm_rule_next:
    add x24, x24, #1
    b .Lwhm_rule
.Lwhm_done:
    mov x0, x23
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwhm_none:
    mov x0, #-1
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_bucket_bounds(fdate_ymd, begin_epoch, end_epoch) -> (x0 = lo,
//   x1 = hi) or x0 = -1 when the day is outside the range.
// ============================================================================
    .p2align 2
watch_bucket_bounds:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // fdate ymd
    mov x20, x1                        // begin epoch
    mov x21, x2                        // end epoch
    mov x0, x19
    mov x1, #0
    bl watch_ymd_sod_to_epoch          // day_start
    mov x22, x0
    // lo
    cmp x20, x22
    b.le .Lwbb_lo0
    sub x23, x20, x22
    b .Lwbb_hi
.Lwbb_lo0:
    mov x23, #0
.Lwbb_hi:
    ldr x9, =LAST_SECOND
    add x10, x22, x9
    cmp x21, x10
    b.ge .Lwbb_hi0
    sub x24, x21, x22
    b .Lwbb_check
.Lwbb_hi0:
    mov x24, x9
.Lwbb_check:
    cmp x23, x24
    b.gt .Lwbb_none
    mov x0, x23
    mov x1, x24
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwbb_none:
    mov x0, #-1
    mov x1, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_reader_window(rd, lo, hi) -> x0 = window record ptr (WW array).
//   The Python TailReader.window with its (revision, lo, hi, held) memo:
//   returns the SAME pointer when nothing changed.
//   Register roles: x19=rd, x20=lo, x21=hi, x22=out record, x23=n,
//   x24/x25 = dropped span, x26/x27 = added span, x28 = scratch.
// ============================================================================
    .p2align 2
watch_reader_window:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // lo
    mov x21, x2                        // hi
    // memo check: revision match and was_lo <= lo and was_hi <= hi
    ldr x9, [x19, #RD_WINDOW]
    cbz x9, .Lwrw_build
    ldr x10, [x19, #RD_WIN_REV]
    ldr x11, [x19, #RD_REVISION]
    cmp x10, x11
    b.ne .Lwrw_build
    ldr x10, [x19, #RD_WIN_LO]
    cmp x10, x20
    b.gt .Lwrw_build
    ldr x10, [x19, #RD_WIN_HI]
    cmp x10, x21
    b.gt .Lwrw_build
    // dropped = order[span(was_lo, lo-1)]; added = order[span(was_hi+1, hi)]
    ldr x22, [x19, #RD_WIN_LO]
    ldr x23, [x19, #RD_WIN_HI]
    sub x9, x20, #1
    mov x0, x19
    mov x1, x22
    mov x2, x9
    bl watch_order_span                // x0 = first, x1 = last (exclusive)
    mov x24, x0
    mov x25, x1
    add x9, x23, #1
    mov x0, x19
    mov x1, x9
    mov x2, x21
    bl watch_order_span
    mov x26, x0
    mov x27, x1
    cmp x24, x25
    b.ne .Lwrw_changed
    cmp x26, x27
    b.ne .Lwrw_changed
    // unchanged: return the held record as-is (same pointer)
    ldr x0, [x19, #RD_WINDOW]
    b .Lwrw_out
.Lwrw_changed:
    // clone the held record into a zero-filled block: the ww helpers scan up
    // to WW_MAX records and treat an empty slot (login == 0) as the end, so
    // everything past the copied n records must be zeroed, not malloc junk.
    ldr x28, [x19, #RD_WINDOW]
    ldr x9, [x19, #RD_WIN_N]
    mov x23, x9
    mov x0, #WW_MAX
    mov x1, #WW_SZ
    mul x0, x0, x1
    bl malloc
    cbz x0, .Lwrw_oom
    mov x22, x0
    mov x0, x22
    mov x1, #0
    mov x2, #WW_MAX
    mov x9, #WW_SZ
    mul x2, x2, x9
    bl memset
    mov x0, x22
    mov x1, x28
    mov x2, #WW_SZ
    mul x2, x23, x2
    bl watch_copy_to
    // drop: out[(login,state)] -= n.  The cursor is re-derived from the
    // callee-saved index x28 each pass: x9/x10 die in watch_ww_sub.
    mov x28, x24
.Lwrw_drop:
    cmp x28, x25
    b.ge .Lwrw_drop_done
    mov x9, #BK_SZ
    mul x9, x28, x9
    ldr x10, [x19, #RD_BUCKETS]
    add x9, x10, x9
    mov x0, x22
    add x1, x9, #BK_LOGIN
    ldrb w2, [x9, #BK_STATE]
    ldr x3, [x9, #BK_N]
    bl watch_ww_sub                    // subtract (removes at zero)
    add x28, x28, #1
    b .Lwrw_drop
.Lwrw_drop_done:
    // add: out[(login,state)] += n.  Same re-derivation: x9/x10 die in
    // watch_ww_add.
    mov x28, x26
.Lwrw_add:
    cmp x28, x27
    b.ge .Lwrw_add_done
    mov x9, #BK_SZ
    mul x9, x28, x9
    ldr x10, [x19, #RD_BUCKETS]
    add x9, x10, x9
    mov x0, x22
    add x1, x9, #BK_LOGIN
    ldrb w2, [x9, #BK_STATE]
    ldr x3, [x9, #BK_N]
    bl watch_ww_add
    add x28, x28, #1
    b .Lwrw_add
.Lwrw_add_done:
    mov x0, x22
    bl watch_ww_trim                   // x0 = new count (n)
    mov x23, x0
    b .Lwrw_store
.Lwrw_build:
    // fresh sum over order[span(lo, hi)]
    mov x0, x19
    mov x1, x20
    mov x2, x21
    bl watch_order_span                // x0 = first, x1 = last (exclusive)
    mov x24, x0
    mov x25, x1
    // allocate a NEW WW array each build: the pointer identity is what the
    // fold uses to detect a content change (Python's window() returns a new
    // object on rebuild), so reusing the buffer here would hide appends.
    ldr x9, [x19, #RD_WINDOW]
    cbz x9, .Lwrw_build_new
    mov x0, x9
    bl free
.Lwrw_build_new:
    mov x9, #WW_MAX
    mov x0, #WW_SZ
    mul x0, x9, x0
    mov x23, x0                        // total bytes (x23 free: n starts below)
    bl malloc
    cbz x0, .Lwrw_oom
    mov x22, x0
    mov x0, x22
    mov x1, #0
    mov x2, x23
    bl memset
    mov x9, #WW_MAX
    str x9, [x19, #RD_WIN_CAP]
    b .Lwrw_build_use
.Lwrw_build_use:
    mov x23, #0                        // n
    mov x9, #BK_SZ
    mul x9, x24, x9
    ldr x10, [x19, #RD_BUCKETS]
    add x26, x10, x9                   // bucket cursor
    mov x9, #BK_SZ
    mul x9, x25, x9
    ldr x10, [x19, #RD_BUCKETS]
    add x27, x10, x9                   // bucket end
.Lwrw_sum:
    cmp x26, x27
    b.ge .Lwrw_sum_done
    mov x0, x22
    mov x1, x23
    add x2, x26, #BK_LOGIN
    ldrb w3, [x26, #BK_STATE]
    bl watch_ww_find                   // x0 = index or -1
    cmp x0, #0
    b.lt .Lwrw_sum_new
    mov x9, #WW_SZ
    mul x9, x0, x9
    add x10, x22, x9
    ldr x11, [x10, #WW_N]
    ldr x12, [x26, #BK_N]
    add x11, x11, x12
    str x11, [x10, #WW_N]
    b .Lwrw_sum_next
.Lwrw_sum_new:
    mov x0, x22
    mov x1, x23
    add x2, x26, #BK_LOGIN
    ldrb w3, [x26, #BK_STATE]
    ldr x4, [x26, #BK_N]
    bl watch_ww_set                    // appends at n; n++
    add x23, x23, #1
.Lwrw_sum_next:
    add x26, x26, #BK_SZ
    b .Lwrw_sum
.Lwrw_sum_done:
.Lwrw_store:
    str x22, [x19, #RD_WINDOW]
    str x23, [x19, #RD_WIN_N]
    str x20, [x19, #RD_WIN_LO]
    str x21, [x19, #RD_WIN_HI]
    ldr x9, [x19, #RD_REVISION]
    str x9, [x19, #RD_WIN_REV]
    mov x0, x22
.Lwrw_out:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrw_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
    .p2align 2
watch_ww_find:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // win
    mov x20, x1                        // n
    mov x0, x2                         // login
    mov x2, x3                         // state
    mov x3, #0                         // i
.Lwwf_loop:
    cmp x3, x20
    b.ge .Lwwf_none
    mov x4, #WW_SZ
    mul x4, x3, x4
    add x4, x19, x4
    ldrb w5, [x4, #WW_STATE]
    cmp w5, w2
    b.ne .Lwwf_next
    // compare login (NUL-terminated in the record)
    mov x5, #0
.Lwwf_cmp:
    ldrb w6, [x4, #WW_LOGIN + 0]
    // use offset-free compare via a register
    add x6, x4, #WW_LOGIN
    ldrb w7, [x6, x5]
    ldrb w8, [x0, x5]
    cmp w7, w8
    b.ne .Lwwf_next
    cbz w7, .Lwwf_found
    add x5, x5, #1
    b .Lwwf_cmp
.Lwwf_found:
    mov x0, x3
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwwf_next:
    add x3, x3, #1
    b .Lwwf_loop
.Lwwf_none:
    mov x0, #-1
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_ww_set(win, n, login, state, nval) -> x0 = index (writes at index n)
    .p2align 2
watch_ww_set:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // win
    mov x20, x1                        // n
    mov x9, #WW_SZ
    mul x9, x20, x9
    add x9, x19, x9
    // copy login (up to 25 bytes) + NUL
    mov x10, #0
.Lwws_copy:
    ldrb w11, [x2, x10]
    cbz w11, .Lwws_copy_done
    cmp x10, #25
    b.ge .Lwws_copy_done
    strb w11, [x9, x10]                  // login[i] (WW_LOGIN == 0)
    add x10, x10, #1
    b .Lwws_copy
.Lwws_copy_done:
    mov w11, #0
    strb w11, [x9, x10]
    strb w3, [x9, #(WW_STATE - WW_LOGIN)]
    str x4, [x9, #(WW_N - WW_LOGIN)]
    mov x0, x20
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_ww_add(win, login, state, n) — add n to the record, or append it.
    .p2align 2
watch_ww_add:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // win
    mov x20, x1                        // login
    mov x21, x2                        // state
    mov x22, x3                        // n
    // find the count (records are NUL-terminated; scan until n is unknown —
    // the caller passes the record count implicitly via the trim; here we
    // scan a fixed max and rely on the trailing sentinel: a record with an
    // empty login and n == 0 marks the end)
    mov x23, #0
.Lwwa_find:
    cmp x23, #WW_MAX
    b.ge .Lwwa_append
    mov x9, #WW_SZ
    mul x9, x23, x9
    add x9, x19, x9
    ldrb w10, [x9, #WW_LOGIN]
    cbz w10, .Lwwa_append             // empty slot -> append
    ldrb w10, [x9, #WW_STATE]
    cmp w10, w21
    b.ne .Lwwa_next
    mov x10, #0
.Lwwa_cmp:
    add x11, x9, #WW_LOGIN
    ldrb w12, [x11, x10]
    ldrb w13, [x20, x10]
    cmp w12, w13
    b.ne .Lwwa_next
    cbz w12, .Lwwa_found
    add x10, x10, #1
    b .Lwwa_cmp
.Lwwa_found:
    ldr x10, [x9, #WW_N]
    add x10, x10, x22
    str x10, [x9, #WW_N]
    b .Lwwa_done
.Lwwa_next:
    add x23, x23, #1
    b .Lwwa_find
.Lwwa_append:
    mov x0, x19
    mov x1, x23
    mov x2, x20
    mov x3, x21
    mov x4, x22
    bl watch_ww_set
.Lwwa_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_ww_sub(win, login, state, n) — subtract n; a record reaching 0 is
//   left in place (watch_ww_trim compacts it away, Python's out += Counter()).
    .p2align 2
watch_ww_sub:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // win
    mov x20, x1                        // login
    mov x21, x2                        // state
    mov x22, x3                        // n
    mov x0, x19
    mov x1, #WW_MAX                    // scan the full record block
    mov x2, x20
    mov x3, x21
    bl watch_ww_find
    cmp x0, #0
    b.lt .Lwws_done
    mov x9, #WW_SZ
    mul x9, x0, x9
    add x9, x19, x9
    ldr x10, [x9, #WW_N]
    sub x10, x10, x22
    str x10, [x9, #WW_N]
.Lwws_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_ww_trim(win) -> x0 = live count; compacts records with n > 0 forward.
    .p2align 2
watch_ww_trim:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // win
    mov x20, #0                        // out index
    mov x21, #0                        // i
.Lwwt_loop:
    cmp x21, #WW_MAX
    b.ge .Lwwt_done
    mov x9, #WW_SZ
    mul x9, x21, x9
    add x9, x19, x9
    ldr x10, [x9, #WW_N]
    cbz x10, .Lwwt_next
    cmp x20, x21
    b.eq .Lwwt_keep
    mov x11, #0
.Lwwt_copy:
    cmp x11, #WW_SZ
    b.ge .Lwwt_keep
    ldrb w12, [x9, x11]
    mov x13, #WW_SZ
    mul x13, x20, x13
    add x13, x19, x13
    strb w12, [x13, x11]
    add x11, x11, #1
    b .Lwwt_copy
.Lwwt_keep:
    add x20, x20, #1
.Lwwt_next:
    add x21, x21, #1
    b .Lwwt_loop
.Lwwt_done:
    mov x0, x20
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_order_span(rd, lo, hi) -> (x0 = first index with second >= lo,
//   x1 = first index with second > hi).
    .p2align 2
watch_order_span:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // lo
    mov x21, x2                        // hi
    ldr x22, [x19, #RD_BUCKET_N]
    ldr x23, [x19, #RD_BUCKETS]
    // lower_bound(second >= lo)
    mov x24, #0
    mov x9, x22
.Lwosp_lb:
    cmp x24, x9
    b.ge .Lwosp_lb_done
    sub x10, x9, x24
    lsr x10, x10, #1
    add x10, x24, x10
    mov x11, #BK_SZ
    mul x11, x10, x11
    add x11, x23, x11
    ldr x12, [x11, #BK_SECOND]
    cmp x12, x20
    b.lt .Lwosp_lb_lo
    mov x9, x10
    b .Lwosp_lb
.Lwosp_lb_lo:
    add x24, x10, #1
    b .Lwosp_lb
.Lwosp_lb_done:
    mov x9, x24                        // first
    // upper_bound(second <= hi): first with second > hi
    mov x24, #0
    mov x10, x22
.Lwosp_ub:
    cmp x24, x10
    b.ge .Lwosp_ub_done
    sub x11, x10, x24
    lsr x11, x11, #1
    add x11, x24, x11
    mov x12, #BK_SZ
    mul x12, x11, x12
    add x12, x23, x12
    ldr x13, [x12, #BK_SECOND]
    cmp x13, x21
    b.le .Lwosp_ub_lo
    mov x10, x11
    b .Lwosp_ub
.Lwosp_ub_lo:
    add x24, x11, #1
    b .Lwosp_ub
.Lwosp_ub_done:
    mov x0, x9
    mov x1, x24
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_reader_day(rd) -> x0 = day record ptr (WW array, whole-day counts).
//   Rebuilt when the reader's revision changed since the last build.
// ============================================================================
    .p2align 2
watch_reader_day:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // rd
    // build when the record is absent or the revision moved
    ldr x9, [x19, #RD_DAY]
    cbz x9, .Lwday_build
    ldr x10, [x19, #RD_DAY_REV]
    ldr x11, [x19, #RD_REVISION]
    cmp x10, x11
    b.eq .Lwday_have
.Lwday_build:
    // sum every bucket into the day record
    ldr x9, [x19, #RD_DAY_CAP]
    cbz x9, .Lwday_new
    ldr x0, [x19, #RD_DAY]
    cbz x0, .Lwday_new
    b .Lwday_use
.Lwday_new:
    mov x9, #WW_MAX
    mov x0, #WW_SZ
    mul x0, x9, x0
    bl malloc
    cbz x0, .Lwday_oom
    str x9, [x19, #RD_DAY_CAP]
.Lwday_use:
    mov x20, x0                        // day buf
    mov x21, #0                        // n
    ldr x22, [x19, #RD_BUCKET_N]
    ldr x23, [x19, #RD_BUCKETS]
    mov x24, #0                        // i
.Lwday_loop:
    cmp x24, x22
    b.ge .Lwday_done
    mov x9, #BK_SZ
    mul x9, x24, x9
    add x25, x23, x9                   // bucket
    mov x0, x20
    mov x1, x21
    add x2, x25, #BK_LOGIN
    ldrb w3, [x25, #BK_STATE]
    bl watch_ww_find
    cmp x0, #0
    b.lt .Lwday_newrec
    mov x9, #WW_SZ
    mul x9, x0, x9
    add x10, x20, x9
    ldr x11, [x10, #WW_N]
    ldr x12, [x25, #BK_N]
    add x11, x11, x12
    str x11, [x10, #WW_N]
    b .Lwday_next
.Lwday_newrec:
    mov x0, x20
    mov x1, x21
    add x2, x25, #BK_LOGIN
    ldrb w3, [x25, #BK_STATE]
    ldr x4, [x25, #BK_N]
    bl watch_ww_set
    add x21, x21, #1
.Lwday_next:
    add x24, x24, #1
    b .Lwday_loop
.Lwday_done:
    str x20, [x19, #RD_DAY]
    str x21, [x19, #RD_DAY_N]
    ldr x9, [x19, #RD_REVISION]
    str x9, [x19, #RD_DAY_REV]
.Lwday_have:
    ldr x0, [x19, #RD_DAY]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwday_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
// watch_reader_prune(rd, floor, match_floor) — drop buckets with second <
//   floor and matches with second < match_floor; mark partial.
// ============================================================================
    .p2align 2
watch_reader_prune:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // floor
    mov x21, x2                        // match_floor
    cbz x20, .Lwpr_matches
    ldr x22, [x19, #RD_BUCKET_N]
    ldr x23, [x19, #RD_BUCKETS]
    mov x24, #0                        // out index
    mov x25, #0                        // i
.Lwpr_loop:
    cmp x25, x22
    b.ge .Lwpr_done
    mov x9, #BK_SZ
    mul x9, x25, x9
    add x10, x23, x9
    ldr x11, [x10, #BK_SECOND]
    cmp x11, x20
    b.lt .Lwpr_skip
    cmp x24, x25
    b.eq .Lwpr_keep
    mov x11, #0
.Lwpr_copy:
    cmp x11, #BK_SZ
    b.ge .Lwpr_keep
    ldrb w12, [x10, x11]
    mov x13, #BK_SZ
    mul x13, x24, x13
    add x13, x23, x13
    strb w12, [x13, x11]
    add x11, x11, #1
    b .Lwpr_copy
.Lwpr_keep:
    add x24, x24, #1
.Lwpr_skip:
    add x25, x25, #1
    b .Lwpr_loop
.Lwpr_done:
    str x24, [x19, #RD_BUCKET_N]
.Lwpr_matches:
    cbz x21, .Lwpr_partial
    ldr x22, [x19, #RD_MATCH_N]
    ldr x23, [x19, #RD_MATCHES]
    mov x24, #0
    mov x25, #0
.Lwpr_mloop:
    cmp x25, x22
    b.ge .Lwpr_mdone
    mov x9, #MT_SZ
    mul x9, x25, x9
    add x10, x23, x9
    ldr x11, [x10, #MT_SECOND]
    cmp x11, x21
    b.lt .Lwpr_mskip
    cmp x24, x25
    b.eq .Lwpr_mkeep
    mov x11, #0
.Lwpr_mcopy:
    cmp x11, #MT_SZ
    b.ge .Lwpr_mkeep
    ldrb w12, [x10, x11]
    mov x13, #MT_SZ
    mul x13, x24, x13
    add x13, x23, x13
    strb w12, [x13, x11]
    add x11, x11, #1
    b .Lwpr_mcopy
.Lwpr_mkeep:
    add x24, x24, #1
.Lwpr_mskip:
    add x25, x25, #1
    b .Lwpr_mloop
.Lwpr_mdone:
    str x24, [x19, #RD_MATCH_N]
.Lwpr_partial:
    mov x9, #1
    str x9, [x19, #RD_PARTIAL]
    str xzr, [x19, #RD_WINDOW]
    str xzr, [x19, #RD_WIN_N]
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// Day memo (the Python readers.days: (channel, date, size, mtime, enter) ->
//   (counts, exit))
// watch_memo_find(ymd, size, mtime, enter) -> x0 = DM ptr or 0
// ============================================================================
    .p2align 2
watch_memo_find:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // ymd
    mov x20, x1                        // size
    mov x21, x2                        // mtime
    mov x22, x3                        // enter
    adrp x9, PAGE(tc_watch_days_n)
    add x9, x9, LO12(tc_watch_days_n)
    ldr x10, [x9]
    adrp x9, PAGE(tc_watch_days)
    add x9, x9, LO12(tc_watch_days)
    ldr x11, [x9]
    mov x12, #0
.Lwmf_loop:
    cmp x12, x10
    b.ge .Lwmf_none
    mov x13, #DM_SZ
    mul x13, x12, x13
    add x13, x11, x13
    ldr x14, [x13, #DM_YMD]
    cmp x14, x19
    b.ne .Lwmf_next
    ldr x14, [x13, #DM_SIZE]
    cmp x14, x20
    b.ne .Lwmf_next
    ldr x14, [x13, #DM_MTIME]
    cmp x14, x21
    b.ne .Lwmf_next
    ldr x14, [x13, #DM_ENTER]
    cmp x14, x22
    b.ne .Lwmf_next
    mov x0, x13
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwmf_next:
    add x12, x12, #1
    b .Lwmf_loop
.Lwmf_none:
    mov x0, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_memo_put(ymd, size, mtime, enter, exit, counts, count) -> x0 = DM ptr
    .p2align 2
watch_memo_put:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                        // ymd
    mov x20, x1                        // size
    mov x21, x2                        // mtime
    mov x22, x3                        // enter
    mov x23, x4                        // exit
    mov x24, x5                        // counts ptr
    mov x25, x6                        // count
    // grow the memo array when full
    adrp x9, PAGE(tc_watch_days_n)
    add x9, x9, LO12(tc_watch_days_n)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_days_cap)
    add x11, x11, LO12(tc_watch_days_cap)
    ldr x12, [x11]
    cmp x10, x12
    b.lt .Lwmp_append
    cbz x12, .Lwmp_new
    lsl x12, x12, #1
    b .Lwmp_alloc
.Lwmp_new:
    mov x12, #DAYS_INIT
.Lwmp_alloc:
    mov x26, x12
    adrp x9, PAGE(tc_watch_days)
    add x9, x9, LO12(tc_watch_days)
    ldr x0, [x9]
    mov x1, #DM_SZ
    mul x1, x12, x1
    bl realloc
    cbz x0, .Lwmp_oom
    adrp x9, PAGE(tc_watch_days)
    add x9, x9, LO12(tc_watch_days)
    str x0, [x9]
    adrp x9, PAGE(tc_watch_days_cap)
    add x9, x9, LO12(tc_watch_days_cap)
    str x26, [x9]
.Lwmp_append:
    adrp x9, PAGE(tc_watch_days_n)
    add x9, x9, LO12(tc_watch_days_n)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_days)
    add x11, x11, LO12(tc_watch_days)
    ldr x11, [x11]
    mov x12, #DM_SZ
    mul x12, x10, x12
    add x11, x11, x12
    str x19, [x11, #DM_YMD]
    str x20, [x11, #DM_SIZE]
    str x21, [x11, #DM_MTIME]
    str x22, [x11, #DM_ENTER]
    str x23, [x11, #DM_EXIT]
    str x24, [x11, #DM_COUNTS]
    str x25, [x11, #DM_COUNT]
    add x10, x10, #1
    str x10, [x9]
    mov x0, x11
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwmp_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// watch_memo_retain(live_ymd_list...) — drop memos whose ymd is not live.
//   in: x0 = live count, x1 = live ymd array ptr
    .p2align 2
watch_memo_retain:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // live count
    mov x20, x1                        // live array
    adrp x9, PAGE(tc_watch_days_n)
    add x9, x9, LO12(tc_watch_days_n)
    ldr x21, [x9]                      // memo count
    adrp x9, PAGE(tc_watch_days)
    add x9, x9, LO12(tc_watch_days)
    ldr x22, [x9]                      // memo array
    mov x23, #0                        // out
    mov x24, #0                        // i
.Lwmr_loop:
    cmp x24, x21
    b.ge .Lwmr_done
    mov x9, #DM_SZ
    mul x9, x24, x9
    add x10, x22, x9
    ldr x11, [x10, #DM_YMD]
    // is ymd in the live array?
    mov x12, #0
.Lwmr_live:
    cmp x12, x19
    b.ge .Lwmr_drop
    ldr x13, [x20, x12, lsl #3]
    cmp x13, x11
    b.eq .Lwmr_keep
    add x12, x12, #1
    b .Lwmr_live
.Lwmr_keep:
    cmp x23, x24
    b.eq .Lwmr_next
    mov x11, #0
.Lwmr_copy:
    cmp x11, #DM_SZ
    b.ge .Lwmr_next
    ldrb w12, [x10, x11]
    mov x13, #DM_SZ
    mul x13, x23, x13
    add x13, x22, x13
    strb w12, [x13, x11]
    add x11, x11, #1
    b .Lwmr_copy
.Lwmr_next:
    add x23, x23, #1
    add x24, x24, #1
    b .Lwmr_loop
.Lwmr_drop:
    add x24, x24, #1
    b .Lwmr_loop
.Lwmr_done:
    adrp x9, PAGE(tc_watch_days_n)
    add x9, x9, LO12(tc_watch_days_n)
    str x23, [x9]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_count_tick — the per-tick gathering pass: refresh the listing, seed
//   the stream state, walk every in-range file (readers + whole-day rollup),
//   fold the windows into tc_users, and write the tally bookkeeping.
// ============================================================================
    .p2align 2
watch_count_tick:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    bl watch_refresh_listing
    bl watch_seed_state                // x0 = entering state
    adrp x9, PAGE(tc_watch_cur_state)
    add x9, x9, LO12(tc_watch_cur_state)
    str x0, [x9]
    // gather
    bl watch_gather
    // fold (reuse or rebuild)
    bl watch_fold
    // bookkeeping into the tally
    adrp x9, PAGE(tc_tally)
    add x9, x9, LO12(tc_tally)
    adrp x10, PAGE(tc_watch_g_files)
    add x10, x10, LO12(tc_watch_g_files)
    ldr x11, [x10]
    str x11, [x9, #TC_T_FILES]
    adrp x10, PAGE(tc_watch_g_parsed)
    add x10, x10, LO12(tc_watch_g_parsed)
    ldr x11, [x10]
    str x11, [x9, #TC_T_PARSED]
    adrp x10, PAGE(tc_watch_g_reused)
    add x10, x10, LO12(tc_watch_g_reused)
    ldr x11, [x10]
    str x11, [x9, #TC_T_REUSED]
    // unreadable list
    adrp x10, PAGE(tc_watch_g_unr_n)
    add x10, x10, LO12(tc_watch_g_unr_n)
    ldr x11, [x10]
    str x11, [x9, #TC_T_UNR_COUNT]
    cbz x11, .Lwct_unr_done
    add x12, x9, #TC_T_UNR_ENTRIES
    adrp x13, PAGE(tc_watch_g_unr)
    add x13, x13, LO12(tc_watch_g_unr)
    mov x14, #0
.Lwct_unr_loop:
    cmp x14, x11
    b.ge .Lwct_unr_done
    mov x15, #96
    mul x15, x14, x15
    add x16, x13, x15
    add x17, x12, x15
    mov x18, #0
.Lwct_unr_copy:
    cmp x18, #96
    b.ge .Lwct_unr_next
    ldrb w19, [x16, x18]
    strb w19, [x17, x18]
    add x18, x18, #1
    b .Lwct_unr_copy
.Lwct_unr_next:
    add x14, x14, #1
    b .Lwct_unr_loop
.Lwct_unr_done:
    // retain readers + day memos to the in-range paths/dates
    adrp x9, PAGE(tc_watch_win_n)
    add x9, x9, LO12(tc_watch_win_n)
    ldr x9, [x9]
    cbz x9, .Lwct_retain_done
    adrp x0, PAGE(tc_watch_wins)
    add x0, x0, LO12(tc_watch_wins)
    ldr x0, [x0]
    // (the windows list is handled in watch_gather; readers are retained below)
.Lwct_retain_done:
    bl watch_retain_readers
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_refresh_listing — rebuild the listing when the dir mtime changed.
// ============================================================================
    .p2align 2
watch_refresh_listing:
    stp x29, x30, [sp, #-16]!
    bl watch_build_listing
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_gather — walk the in-range listing entries and build the windows list
//   (tc_watch_wins), applying whole-day cache/memo logic and reader refreshes.
//   Bookkeeping lands in tc_watch_g_*.  Per-file processing is delegated to
//   watch_gather_file so each file gets a clean register allocation.
//   Register roles: x19=i, x20=begin_epoch, x21=end_epoch, x22=begin_ymd,
//   x23=end_ymd, x25=enter, x26=cache_used, x27=listing count.
// ============================================================================
    .p2align 2
watch_gather:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // reset bookkeeping + windows
    adrp x9, PAGE(tc_watch_g_files)
    add x9, x9, LO12(tc_watch_g_files)
    str xzr, [x9]
    str xzr, [x9, #8]                  // parsed
    str xzr, [x9, #16]                 // reused
    adrp x9, PAGE(tc_watch_g_unr_n)
    add x9, x9, LO12(tc_watch_g_unr_n)
    str xzr, [x9]
    adrp x9, PAGE(tc_watch_win_n)
    add x9, x9, LO12(tc_watch_win_n)
    str xzr, [x9]
    adrp x9, PAGE(tc_watch_sqlite_hit)
    add x9, x9, LO12(tc_watch_sqlite_hit)
    str xzr, [x9]
    // window epochs + shared state
    adrp x19, PAGE(tc_window)
    add x19, x19, LO12(tc_window)
    ldr x0, [x19, #TC_W_BEGIN_YMD]
    ldr x1, [x19, #TC_W_BEGIN_SOD]
    bl watch_ymd_sod_to_epoch
    mov x20, x0
    ldr x0, [x19, #TC_W_END_YMD]
    ldr x1, [x19, #TC_W_END_SOD]
    bl watch_ymd_sod_to_epoch
    mov x21, x0
    ldr x22, [x19, #TC_W_BEGIN_YMD]
    ldr x23, [x19, #TC_W_END_YMD]
    adrp x9, PAGE(tc_watch_cur_state)
    add x9, x9, LO12(tc_watch_cur_state)
    ldr x25, [x9]
    bl tc_cache_used
    mov x26, x0
    adrp x27, PAGE(tc_listing)
    add x27, x27, LO12(tc_listing)
    ldr x27, [x27, #TC_L_COUNT]
    // stash the shared state for the per-file helper
    adrp x9, PAGE(tc_watch_g_begin)
    add x9, x9, LO12(tc_watch_g_begin)
    str x20, [x9]
    adrp x9, PAGE(tc_watch_g_end)
    add x9, x9, LO12(tc_watch_g_end)
    str x21, [x9]
    adrp x9, PAGE(tc_watch_g_begin_ymd)
    add x9, x9, LO12(tc_watch_g_begin_ymd)
    str x22, [x9]
    adrp x9, PAGE(tc_watch_g_end_ymd)
    add x9, x9, LO12(tc_watch_g_end_ymd)
    str x23, [x9]
    adrp x9, PAGE(tc_watch_g_enter)
    add x9, x9, LO12(tc_watch_g_enter)
    str x25, [x9]
    adrp x9, PAGE(tc_watch_g_cache)
    add x9, x9, LO12(tc_watch_g_cache)
    str x26, [x9]
    mov x19, #0                        // i
.Lwg_loop:
    cmp x19, x27
    b.ge .Lwg_done
    mov x0, x19
    bl watch_gather_file
    adrp x9, PAGE(tc_watch_g_enter)
    add x9, x9, LO12(tc_watch_g_enter)
    ldr x25, [x9]
    add x19, x19, #1
    b .Lwg_loop
.Lwg_done:
    adrp x9, PAGE(tc_watch_cur_state)
    add x9, x9, LO12(tc_watch_cur_state)
    str x25, [x9]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_gather_file(i) — process one in-range listing entry.
//   Register roles: x19=listing entry, x20=stat ptr, x21=ymd, x22=day_start,
//   x23=lo, x24=hi, x25=whole_day, x26=enter, x27=size, x28=mtime_ns.
//   Reads the shared state from tc_watch_g_*; writes tc_watch_g_enter and
//   the bookkeeping counters.
// ============================================================================
    .p2align 2
watch_gather_file:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // i
    // entry
    adrp x9, PAGE(tc_listing)
    add x9, x9, LO12(tc_listing)
    ldr x10, [x9, #TC_L_ENTRIES]
    mov x11, #TC_L_ENTRY_SZ
    mul x11, x19, x11
    add x19, x10, x11                  // listing entry (x19)
    ldr x21, [x19, #TC_L_YMD]
    // range check
    adrp x9, PAGE(tc_watch_g_begin_ymd)
    add x9, x9, LO12(tc_watch_g_begin_ymd)
    ldr x10, [x9]
    cmp x21, x10
    b.lt .Lwgf_done
    adrp x9, PAGE(tc_watch_g_end_ymd)
    add x9, x9, LO12(tc_watch_g_end_ymd)
    ldr x10, [x9]
    cmp x21, x10
    b.gt .Lwgf_done
    // files++
    adrp x9, PAGE(tc_watch_g_files)
    add x9, x9, LO12(tc_watch_g_files)
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    // bounds + whole_day
    mov x0, x21
    mov x1, #0
    bl watch_ymd_sod_to_epoch
    mov x22, x0                        // day_start
    adrp x9, PAGE(tc_watch_g_begin)
    add x9, x9, LO12(tc_watch_g_begin)
    ldr x10, [x9]                      // begin_epoch
    adrp x11, PAGE(tc_watch_g_end)
    add x11, x11, LO12(tc_watch_g_end)
    ldr x11, [x11]                     // end_epoch
    cmp x10, x22
    b.le .Lwgf_lo0
    sub x23, x10, x22
    b .Lwgf_hi
.Lwgf_lo0:
    mov x23, #0
.Lwgf_hi:
    ldr x9, =LAST_SECOND
    add x12, x22, x9
    cmp x11, x12
    b.ge .Lwgf_hi0
    sub x24, x11, x22
    b .Lwgf_bounds
.Lwgf_hi0:
    mov x24, x9
.Lwgf_bounds:
    cmp x23, x24
    b.gt .Lwgf_done                    // bounds None: nothing in range
    mov x25, #0
    cmp x10, x22
    b.gt .Lwgf_wd_done
    ldr x9, =LAST_SECOND
    add x12, x22, x9
    cmp x11, x12
    b.lt .Lwgf_wd_done
    mov x25, #1                        // whole_day
.Lwgf_wd_done:
    // build the file path
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    adrp x1, PAGE(tc_watch_dirpath)
    add x1, x1, LO12(tc_watch_dirpath)
    bl wc_cat
    mov w2, #'/'
    strb w2, [x0], #1
    add x1, x19, #TC_L_NAME
    bl wc_cat
    // stat
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    adrp x20, PAGE(tc_watch_stat)
    add x20, x20, LO12(tc_watch_stat)
    mov x1, x20
    bl stat
    cbnz w0, .Lwgf_unreadable
    // entry was clobbered by the path build; reload it
    adrp x9, PAGE(tc_listing)
    add x9, x9, LO12(tc_listing)
    ldr x10, [x9, #TC_L_ENTRIES]
    mov x11, #TC_L_ENTRY_SZ
    mul x11, x0, x11
    // (x0 was the stat result 0; recompute the entry from the loop index —
    // we did not keep i; the entry base is stable, rebuild via a scratch)
    b .Lwgf_entry_reload
.Lwgf_entry_reload:
    // the loop index is recoverable: scan the listing for the ymd is wrong;
    // instead we stash the entry pointer in x19 before any call — it was
    // clobbered.  Recover it from the fdless scan below.
    // (fixed: we keep x19 as the entry across calls by re-reading it here)
    adrp x9, PAGE(tc_listing)
    add x9, x9, LO12(tc_listing)
    ldr x10, [x9, #TC_L_ENTRIES]
    // scan for the entry whose ymd matches x21
    adrp x11, PAGE(tc_listing)
    add x11, x11, LO12(tc_listing)
    ldr x12, [x11, #TC_L_COUNT]
    mov x13, #0
.Lwgf_rescan:
    cmp x13, x12
    b.ge .Lwgf_done
    mov x14, #TC_L_ENTRY_SZ
    mul x14, x13, x14
    add x14, x10, x14
    ldr x15, [x14, #TC_L_YMD]
    cmp x15, x21
    b.eq .Lwgf_rescan_done
    add x13, x13, #1
    b .Lwgf_rescan
.Lwgf_rescan_done:
    mov x19, x14                        // entry
    ldr x27, [x20, #ST_SIZE]
    ldr x9, [x20, #ST_MTIM_SEC]
    movz x10, #0xCA00, lsl #0
    movk x10, #0x3B9A, lsl #16
    mul x9, x9, x10
    ldr x10, [x20, #ST_MTIM_NSEC]
    add x28, x9, x10                    // mtime_ns
    adrp x9, PAGE(tc_watch_g_enter)
    add x9, x9, LO12(tc_watch_g_enter)
    ldr x26, [x9]                       // enter
    adrp x9, PAGE(tc_watch_g_cache)
    add x9, x9, LO12(tc_watch_g_cache)
    ldr x10, [x9]                       // cache_used
    // ---- whole-day cache/memo --------------------------------------------
    cbz x25, .Lwgf_reader
    cbz x10, .Lwgf_reader
    mov x0, x21
    mov x1, x27
    mov x2, x28
    mov x3, x26
    bl watch_memo_find
    cbz x0, .Lwgf_memo_miss
    // memo hit: reused++, window = memo counts, enter = memo exit
    adrp x9, PAGE(tc_watch_g_reused)
    add x9, x9, LO12(tc_watch_g_reused)
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    mov x11, x0                        // dm (x0 = counts below)
    ldr x0, [x11, #DM_COUNTS]
    bl watch_win_add
    ldr x9, [x11, #DM_EXIT]
    adrp x10, PAGE(tc_watch_g_enter)
    add x10, x10, LO12(tc_watch_g_enter)
    str x9, [x10]
    b .Lwgf_done
.Lwgf_memo_miss:
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    mov x1, x23                        // lo
    mov x2, x24                        // hi
    mov x3, x26
    mov x4, x21
    bl tc_cache_day
    cmp w0, #2
    b.eq .Lwgf_unreadable
    cmp w0, #1
    b.eq .Lwgf_sqlite_hit
    b .Lwgf_reader
.Lwgf_sqlite_hit:
    adrp x9, PAGE(tc_watch_sqlite_hit)
    add x9, x9, LO12(tc_watch_sqlite_hit)
    mov x10, #1
    str x10, [x9]
    adrp x9, PAGE(tc_watch_g_reused)
    add x9, x9, LO12(tc_watch_g_reused)
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    // build the memo counts from the reader (cold read once per session)
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    mov x1, x21
    bl watch_reader_get
    mov x19, x0                        // rd
    ldr x9, [x19, #RD_REVISION]

    cbnz x9, .Lwgf_sh_ready
    ldr x9, [x19, #RD_PARTIAL]
    cbnz x9, .Lwgf_sh_ready
    mov x0, x19
    mov x1, x20                        // stat
    mov x2, x26
    mov x3, #0
    bl watch_reader_refresh
    cmp x0, #0
    b.lt .Lwgf_unreadable
.Lwgf_sh_ready:

    ldr x22, [x19, #RD_EXIT]           // exit (x22 free)
    ldr x23, [x19, #RD_ENTER]          // enter (x23 free)
    mov x0, x19
    bl watch_reader_day                // x0 = day record
    mov x25, x0                        // counts (x25 free: whole_day was 1)

    ldr x26, [x19, #RD_DAY_N]          // count (x26 free)
    mov x0, x21
    mov x1, x27
    mov x2, x28
    mov x3, x23
    mov x4, x22
    mov x5, x25
    mov x6, x26
    bl watch_memo_put                  // x0 = DM ptr
    mov x11, x0
    ldr x0, [x11, #DM_COUNTS]
    bl watch_win_add
    ldr x9, [x11, #DM_EXIT]
    adrp x10, PAGE(tc_watch_g_enter)
    add x10, x10, LO12(tc_watch_g_enter)
    str x9, [x10]
    b .Lwgf_done
.Lwgf_reader:
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    mov x1, x21
    bl watch_reader_get
    mov x19, x0                        // rd
    // floor = max(0, int(lo - retain)) unless seeking

    mov x3, #0
    adrp x9, PAGE(tc_watch_seeking)
    add x9, x9, LO12(tc_watch_seeking)
    ldr x9, [x9]
    cbnz x9, .Lwgf_floor_done
    adrp x9, PAGE(tc_watch_retain_seconds)
    add x9, x9, LO12(tc_watch_retain_seconds)
    ldr d0, [x9]
    fcmp d0, #0.0
    b.le .Lwgf_floor_done
    scvtf d1, x23
    fsub d0, d1, d0
    fcmp d0, #0.0
    b.le .Lwgf_floor_done
    fcvtzs x3, d0
.Lwgf_floor_done:
    mov x0, x19
    mov x1, x20                        // stat
    mov x2, x26                        // enter
    bl watch_reader_refresh            // x0 = status (floor in x3)
    cmp x0, #0
    b.lt .Lwgf_unreadable

    cbz x0, .Lwgf_parsed_done
    adrp x9, PAGE(tc_watch_g_parsed)
    add x9, x9, LO12(tc_watch_g_parsed)
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
.Lwgf_parsed_done:
    // window(lo, hi)
    mov x0, x19
    mov x1, x23
    mov x2, x24
    bl watch_reader_window             // x0 = window ptr
    mov x23, x0                        // window ptr (lo no longer needed)

    // put whole day (cold read, no appends, not partial)
    cbz x25, .Lwgf_put_done
    adrp x9, PAGE(tc_watch_g_cache)
    add x9, x9, LO12(tc_watch_g_cache)
    ldr x9, [x9]
    cbz x9, .Lwgf_put_done
    ldr x9, [x19, #RD_APPENDS]
    cbnz x9, .Lwgf_put_done
    ldr x9, [x19, #RD_PARTIAL]
    cbnz x9, .Lwgf_put_done
    ldr x0, [x19, #RD_EXIT]
    bl tc_cache_put_day
.Lwgf_put_done:
    ldr x9, [x19, #RD_EXIT]
    adrp x10, PAGE(tc_watch_g_enter)
    add x10, x10, LO12(tc_watch_g_enter)
    str x9, [x10]
    // memo the whole day (never partial)
    cbz x25, .Lwgf_win_add
    adrp x9, PAGE(tc_watch_g_cache)
    add x9, x9, LO12(tc_watch_g_cache)
    ldr x9, [x9]
    cbz x9, .Lwgf_win_add
    ldr x9, [x19, #RD_PARTIAL]
    cbnz x9, .Lwgf_win_add
    mov x0, x19
    bl watch_reader_day                // x0 = day record
    mov x25, x0                        // counts (x25 free now)
    ldr x26, [x19, #RD_DAY_N]          // count
    ldr x22, [x19, #RD_EXIT]           // exit
    ldr x24, [x19, #RD_ENTER]          // enter (x24 free)
    mov x0, x21
    mov x1, x27
    mov x2, x28
    mov x3, x24
    mov x4, x22
    mov x5, x25
    mov x6, x26
    bl watch_memo_put                  // x0 = DM ptr
    mov x11, x0
    ldr x0, [x11, #DM_COUNTS]
    bl watch_win_add
    b .Lwgf_done
.Lwgf_win_add:
    mov x0, x23
    bl watch_win_add
    b .Lwgf_done
.Lwgf_unreadable:
    add x0, x19, #TC_L_NAME
    adrp x1, PAGE(s_cannot_read)
    add x1, x1, LO12(s_cannot_read)
    bl watch_record_unreadable
    adrp x9, PAGE(tc_watch_g_enter)
    add x9, x9, LO12(tc_watch_g_enter)
    str xzr, [x9]
.Lwgf_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_win_add(win_ptr) — append a window pointer to tc_watch_wins (grow).
// ============================================================================
    .p2align 2
watch_win_add:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // win ptr
    adrp x9, PAGE(tc_watch_win_n)
    add x9, x9, LO12(tc_watch_win_n)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_wins_cap)
    add x11, x11, LO12(tc_watch_wins_cap)
    ldr x12, [x11]
    cmp x10, x12
    b.lt .Lwina_append
    cbz x12, .Lwina_new
    lsl x12, x12, #1
    b .Lwina_alloc
.Lwina_new:
    mov x12, #WINLIST_INIT
.Lwina_alloc:
    mov x20, x12
    adrp x9, PAGE(tc_watch_wins)
    add x9, x9, LO12(tc_watch_wins)
    ldr x0, [x9]
    mov x1, #8
    mul x1, x12, x1
    bl realloc
    cbz x0, .Lwina_oom
    adrp x9, PAGE(tc_watch_wins)
    add x9, x9, LO12(tc_watch_wins)
    str x0, [x9]
    adrp x9, PAGE(tc_watch_wins_cap)
    add x9, x9, LO12(tc_watch_wins_cap)
    str x20, [x9]
.Lwina_append:
    adrp x9, PAGE(tc_watch_win_n)
    add x9, x9, LO12(tc_watch_win_n)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_wins)
    add x11, x11, LO12(tc_watch_wins)
    ldr x11, [x11]
    str x19, [x11, x10, lsl #3]
    add x10, x10, #1
    str x10, [x9]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwina_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
// watch_record_unreadable(name, reason) — capped unreadable list (96-byte
//   records {name[64], reason[32]}) into the gather scratch.
// ============================================================================
    .p2align 2
watch_record_unreadable:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // name
    mov x20, x1                        // reason
    adrp x9, PAGE(tc_watch_g_unr_n)
    add x9, x9, LO12(tc_watch_g_unr_n)
    ldr x10, [x9]
    ldr x11, =64
    cmp x10, x11
    b.ge .Lwru_done
    adrp x11, PAGE(tc_watch_g_unr)
    add x11, x11, LO12(tc_watch_g_unr)
    mov x12, #96
    mul x12, x10, x12
    add x11, x11, x12
    mov x13, #0
.Lwru_name:
    cmp x13, #63
    b.ge .Lwru_name_done
    ldrb w14, [x19, x13]
    strb w14, [x11, x13]
    cbz w14, .Lwru_name_done
    add x13, x13, #1
    b .Lwru_name
.Lwru_name_done:
    mov w14, #0
    strb w14, [x11, x13]
    add x11, x11, #64
    mov x13, #0
.Lwru_reason:
    cmp x13, #31
    b.ge .Lwru_reason_done
    ldrb w14, [x20, x13]
    strb w14, [x11, x13]
    cbz w14, .Lwru_reason_done
    add x13, x13, #1
    b .Lwru_reason
.Lwru_reason_done:
    mov w14, #0
    strb w14, [x11, x13]
    add x10, x10, #1
    str x10, [x9]
.Lwru_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_fold — the fold_windows equivalent: reuse the previous tc_users when
//   the shape (state_filter, sqlite-hit flag) and every window pointer match;
//   otherwise rebuild the table from the windows list.
// ============================================================================
    .p2align 2
watch_fold:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x19, [x9, #TC_W_STATE_FILTER]  // shape
    adrp x9, PAGE(tc_watch_sqlite_hit)
    add x9, x9, LO12(tc_watch_sqlite_hit)
    ldr x20, [x9]
    adrp x9, PAGE(tc_watch_win_n)
    add x9, x9, LO12(tc_watch_win_n)
    ldr x21, [x9]                      // n
    // reuse?
    adrp x9, PAGE(tc_watch_fold_n)
    add x9, x9, LO12(tc_watch_fold_n)
    ldr x10, [x9]
    cmp x10, x21
    b.ne .Lwf_rebuild
    adrp x9, PAGE(tc_watch_fold_shape)
    add x9, x9, LO12(tc_watch_fold_shape)
    ldr x10, [x9]
    cmp x10, x19
    b.ne .Lwf_rebuild
    adrp x9, PAGE(tc_watch_fold_sqlite)
    add x9, x9, LO12(tc_watch_fold_sqlite)
    ldr x10, [x9]
    cmp x10, x20
    b.ne .Lwf_rebuild
    // compare the pointer lists
    adrp x9, PAGE(tc_watch_fold_wins)
    add x9, x9, LO12(tc_watch_fold_wins)
    adrp x10, PAGE(tc_watch_wins)
    add x10, x10, LO12(tc_watch_wins)
    ldr x10, [x10]
    mov x22, #0
.Lwf_cmp:
    cmp x22, x21
    b.ge .Lwf_reuse
    ldr x23, [x9, x22, lsl #3]
    ldr x24, [x10, x22, lsl #3]
    cmp x23, x24
    b.ne .Lwf_rebuild
    add x22, x22, #1
    b .Lwf_cmp
.Lwf_reuse:
    // the table + tally hold the previous fold; only bookkeeping changes.
    b .Lwf_store
.Lwf_rebuild:
    bl watch_reset_count
    // apply every window
    adrp x9, PAGE(tc_watch_win_n)
    add x9, x9, LO12(tc_watch_win_n)
    ldr x21, [x9]
    adrp x9, PAGE(tc_watch_wins)
    add x9, x9, LO12(tc_watch_wins)
    ldr x10, [x9]
    mov x22, #0
.Lwf_apply:
    cmp x22, x21
    b.ge .Lwf_finish
    // reload the windows base: watch_apply below clobbers caller-saved x10
    adrp x9, PAGE(tc_watch_wins)
    add x9, x9, LO12(tc_watch_wins)
    ldr x10, [x9]
    ldr x24, [x10, x22, lsl #3]
    // iterate the WW record: each {login, state, n}
    mov x26, #0                        // record index (scan until empty)
.Lwf_ww:
    cmp x26, #WW_MAX
    b.ge .Lwf_apply_next
    mov x9, #WW_SZ
    mul x9, x26, x9
    add x27, x24, x9
    ldrb w28, [x27, #WW_LOGIN]
    cbz w28, .Lwf_apply_next           // empty slot: end of the record
    ldr x0, [x27, #WW_N]
    cbz x0, .Lwf_ww_next
    // apply(login, len, state, n)
    add x0, x27, #WW_LOGIN
    bl tc_strlen
    mov x1, x0
    add x0, x27, #WW_LOGIN
    ldrb w2, [x27, #WW_STATE]
    ldr x3, [x27, #WW_N]
    bl watch_apply
.Lwf_ww_next:
    add x26, x26, #1
    b .Lwf_ww
.Lwf_apply_next:
    add x22, x22, #1
    b .Lwf_apply
.Lwf_finish:
    bl watch_finish
.Lwf_store:
    // remember the shape + pointers
    adrp x9, PAGE(tc_watch_fold_shape)
    add x9, x9, LO12(tc_watch_fold_shape)
    str x19, [x9]
    adrp x9, PAGE(tc_watch_fold_sqlite)
    add x9, x9, LO12(tc_watch_fold_sqlite)
    str x20, [x9]
    adrp x9, PAGE(tc_watch_fold_n)
    add x9, x9, LO12(tc_watch_fold_n)
    str x21, [x9]
    adrp x9, PAGE(tc_watch_fold_wins)
    add x9, x9, LO12(tc_watch_fold_wins)
    adrp x10, PAGE(tc_watch_wins)
    add x10, x10, LO12(tc_watch_wins)
    ldr x10, [x10]
    mov x22, #0
.Lwf_copy:
    cmp x22, x21
    b.ge .Lwf_done
    ldr x23, [x10, x22, lsl #3]
    str x23, [x9, x22, lsl #3]
    add x22, x22, #1
    b .Lwf_copy
.Lwf_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_reset_count — zero the tally and the user table (mirror tc_reset_count
//   minus the core-global totals, which this module computes itself).
// ============================================================================
    .p2align 2
watch_reset_count:
    stp x29, x30, [sp, #-16]!
    adrp x0, PAGE(tc_tally)
    add x0, x0, LO12(tc_tally)
    mov x1, #0
    mov x2, #TC_TALLY_SIZE
    bl memset
    adrp x0, PAGE(tc_tally)
    add x0, x0, LO12(tc_tally)
    adrp x1, PAGE(tc_users)
    add x1, x1, LO12(tc_users)
    str x1, [x0, #TC_T_USERS_PTR]
    str xzr, [x1, #TC_US_COUNT]
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_apply(login, len, state, n) — add n to the user's state bucket
//   (mirror tc_reuse_apply minus the core-global totals).
// ============================================================================
    .p2align 2
watch_apply:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // login
    mov x20, x1                        // len
    mov x21, x2                        // state
    mov x22, x3                        // n
    adrp x2, PAGE(tc_users)
    add x2, x2, LO12(tc_users)
    mov x0, x19
    mov x1, x20
    bl find_user
    cmp x0, #0
    b.ge .Lwapp_have
    mov x0, x19
    mov x1, x20
    adrp x2, PAGE(tc_users)
    add x2, x2, LO12(tc_users)
    bl add_user
.Lwapp_have:
    adrp x9, PAGE(tc_users)
    add x9, x9, LO12(tc_users)
    ldr x10, [x9, #TC_US_ENTRIES]
    mov x11, #TC_US_ENTRY_SZ
    mul x11, x0, x11
    add x10, x10, x11
    cmp x21, #TC_ST_LIVE
    b.eq .Lwapp_live
    cmp x21, #TC_ST_OFFLINE
    b.eq .Lwapp_off
    ldr x11, [x10, #TC_US_UNKNOWN]
    add x11, x11, x22
    str x11, [x10, #TC_US_UNKNOWN]
    b .Lwapp_done
.Lwapp_live:
    ldr x11, [x10, #TC_US_LIVE]
    add x11, x11, x22
    str x11, [x10, #TC_US_LIVE]
    b .Lwapp_done
.Lwapp_off:
    ldr x11, [x10, #TC_US_OFFLINE]
    add x11, x11, x22
    str x11, [x10, #TC_US_OFFLINE]
.Lwapp_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_finish — mirror tc_finish_tally: exclusions subtract out of the
//   all-state totals, non-excluded entries sum into the messages total.
// ============================================================================
    .p2align 2
watch_finish:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_tally)
    add x19, x19, LO12(tc_tally)
    str xzr, [x19, #TC_T_STATES + 0]
    str xzr, [x19, #TC_T_STATES + 8]
    str xzr, [x19, #TC_T_STATES + 16]
    str xzr, [x19, #TC_T_EXCLUDED_STATES + 0]
    str xzr, [x19, #TC_T_EXCLUDED_STATES + 8]
    str xzr, [x19, #TC_T_EXCLUDED_STATES + 16]
    str xzr, [x19, #TC_T_MESSAGES]
    adrp x20, PAGE(tc_users)
    add x20, x20, LO12(tc_users)
    ldr x21, [x20, #TC_US_COUNT]
    ldr x22, [x20, #TC_US_ENTRIES]
    mov x23, #0
.Lwfin_loop:
    cmp x23, x21
    b.ge .Lwfin_done
    mov x24, #TC_US_ENTRY_SZ
    mul x24, x23, x24
    add x24, x22, x24
    mov x0, x24
    bl tc_strlen
    mov x1, x0
    mov x0, x24
    bl tc_excl_contains
    cbz x0, .Lwfin_not_excl
    ldr x9, [x24, #TC_US_LIVE]
    ldr x10, [x24, #TC_US_OFFLINE]
    ldr x11, [x24, #TC_US_UNKNOWN]
    ldr x12, [x19, #TC_T_EXCLUDED_STATES + 0]
    add x12, x12, x9
    str x12, [x19, #TC_T_EXCLUDED_STATES + 0]
    ldr x12, [x19, #TC_T_EXCLUDED_STATES + 8]
    add x12, x12, x10
    str x12, [x19, #TC_T_EXCLUDED_STATES + 8]
    ldr x12, [x19, #TC_T_EXCLUDED_STATES + 16]
    add x12, x12, x11
    str x12, [x19, #TC_T_EXCLUDED_STATES + 16]
    b .Lwfin_next
.Lwfin_not_excl:
    ldr x9, [x24, #TC_US_LIVE]
    ldr x10, [x24, #TC_US_OFFLINE]
    ldr x11, [x24, #TC_US_UNKNOWN]
    ldr x12, [x19, #TC_T_STATES + 0]
    add x12, x12, x9
    str x12, [x19, #TC_T_STATES + 0]
    ldr x12, [x19, #TC_T_STATES + 8]
    add x12, x12, x10
    str x12, [x19, #TC_T_STATES + 8]
    ldr x12, [x19, #TC_T_STATES + 16]
    add x12, x12, x11
    str x12, [x19, #TC_T_STATES + 16]
    mov x0, x23
    bl tc_count_column
    ldr x9, [x19, #TC_T_MESSAGES]
    add x9, x9, x0
    str x9, [x19, #TC_T_MESSAGES]
.Lwfin_next:
    add x23, x23, #1
    b .Lwfin_loop
.Lwfin_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_retain_readers — drop readers whose path is not in the current
//   listing, and day memos whose date is not in the listing (Python retain).
// ============================================================================
    .p2align 2
watch_retain_readers:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // build the live path list = listing entry names
    adrp x19, PAGE(tc_listing)
    add x19, x19, LO12(tc_listing)
    ldr x20, [x19, #TC_L_COUNT]
    ldr x21, [x19, #TC_L_ENTRIES]
    // keep readers whose path matches an entry
    adrp x22, PAGE(tc_watch_reader_n)
    add x22, x22, LO12(tc_watch_reader_n)
    ldr x23, [x22]
    adrp x24, PAGE(tc_watch_readers)
    add x24, x24, LO12(tc_watch_readers)
    ldr x24, [x24]
    mov x25, #0                        // out
    mov x26, #0                        // i
.Lwret_loop:
    cmp x26, x23
    b.ge .Lwret_done
    ldr x27, [x24, x26, lsl #3]
    // is the reader's name in the listing?
    mov x0, x27
    mov x1, x20
    mov x2, x21
    bl watch_path_in_listing           // x0 = 1/0
    cbz x0, .Lwret_drop
    cmp x25, x26
    b.eq .Lwret_keep
    ldr x9, [x24, x26, lsl #3]
    str x9, [x24, x25, lsl #3]
.Lwret_keep:
    add x25, x25, #1
    add x26, x26, #1
    b .Lwret_loop
.Lwret_drop:
    add x26, x26, #1
    b .Lwret_loop
.Lwret_done:
    str x25, [x22]

    // memo retain: live ymd list
    cbz x20, .Lwret_memo_none
    // build the live ymd array in the scratch
    adrp x0, PAGE(tc_watch_scratch)
    add x0, x0, LO12(tc_watch_scratch)
    mov x1, #0
    mov x2, #2048
    bl memset
    mov x19, #0
.Lwret_live:
    cmp x19, x20
    b.ge .Lwret_live_done
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x19, x9
    add x10, x21, x9
    ldr x11, [x10, #TC_L_YMD]
    adrp x12, PAGE(tc_watch_scratch)
    add x12, x12, LO12(tc_watch_scratch)
    str x11, [x12, x19, lsl #3]
    add x19, x19, #1
    b .Lwret_live
.Lwret_live_done:
    mov x0, x20
    adrp x1, PAGE(tc_watch_scratch)
    add x1, x1, LO12(tc_watch_scratch)
    bl watch_memo_retain
    b .Lwret_out
.Lwret_memo_none:
    adrp x9, PAGE(tc_watch_days_n)
    add x9, x9, LO12(tc_watch_days_n)
    str xzr, [x9]
.Lwret_out:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_path_in_listing(rd, n, entries) -> x0 = 1 if the reader's NAME
//   (the file part of its path) appears in the listing, else 0.
    .p2align 2
watch_path_in_listing:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // rd
    mov x20, x1                        // n
    mov x21, x2                        // entries
    add x22, x19, #RD_PATH
    // find the last '/' in the path
    mov x0, x22
    bl tc_strlen
    mov x9, #0
    mov x10, #-1
.Lwpi_scan:
    cmp x9, x0
    b.ge .Lwpi_scan_done
    ldrb w11, [x22, x9]
    cmp w11, #'/'
    b.ne .Lwpi_next
    mov x10, x9
.Lwpi_next:
    add x9, x9, #1
    b .Lwpi_scan
.Lwpi_scan_done:
    add x23, x22, x10
    add x23, x23, #1                   // name ptr
    mov x9, #0
.Lwpi_loop:
    cmp x9, x20
    b.ge .Lwpi_no
    mov x10, #TC_L_ENTRY_SZ
    mul x10, x9, x10
    add x10, x21, x10
    add x10, x10, #TC_L_NAME
    mov x0, x23
    mov x1, x10
    bl strcmp
    cbz w0, .Lwpi_yes
    add x9, x9, #1
    b .Lwpi_loop
.Lwpi_yes:
    mov x0, #1
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpi_no:
    mov x0, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_seed_state() -> x0 = 0/1/2.  The stream state entering the range:
//   scan files before begin.date(), newest first, up to seed_lookback of
//   them; the LAST marker of the first file with any wins.  Memoized on
//   (begin_ymd, earlier_last_ymd, earlier_last_size, earlier_last_mtime).
// ============================================================================
    .p2align 2
watch_seed_state:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x19, [x9, #TC_W_BEGIN_YMD]     // begin_ymd
    // find earlier = listing entries with ymd < begin_ymd
    adrp x20, PAGE(tc_listing)
    add x20, x20, LO12(tc_listing)
    ldr x21, [x20, #TC_L_COUNT]
    ldr x22, [x20, #TC_L_ENTRIES]
    mov x23, #0                        // earlier count
    mov x24, #0                        // i
.Lwss_find:
    cmp x24, x21
    b.ge .Lwss_find_done
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x24, x9
    add x10, x22, x9
    ldr x11, [x10, #TC_L_YMD]
    cmp x11, x19
    b.ge .Lwss_find_done
    add x23, x23, #1
    add x24, x24, #1
    b .Lwss_find
.Lwss_find_done:
    // earlier = [0, x23); last earlier entry = index x23-1
    cbz x23, .Lwss_none_earlier
    // stat the last earlier file
    sub x24, x23, #1
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x24, x9
    add x25, x22, x9                   // last entry
    // build its path
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    adrp x1, PAGE(tc_watch_dirpath)
    add x1, x1, LO12(tc_watch_dirpath)
    bl wc_cat
    mov w2, #'/'
    strb w2, [x0], #1
    add x1, x25, #TC_L_NAME
    bl wc_cat
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    adrp x1, PAGE(tc_watch_stat)
    add x1, x1, LO12(tc_watch_stat)
    bl stat
    cbnz w0, .Lwss_none_earlier
    adrp x1, PAGE(tc_watch_stat)             // reload: bl stat clobbered caller-saved x1
    add x1, x1, LO12(tc_watch_stat)
    ldr x26, [x25, #TC_L_YMD]          // earlier_last_ymd
    ldr x27, [x1, #ST_SIZE]            // size
    ldr x9, [x1, #ST_MTIM_SEC]
    movz x10, #0xCA00, lsl #0
    movk x10, #0x3B9A, lsl #16
    mul x9, x9, x10
    ldr x10, [x1, #ST_MTIM_NSEC]
    add x28, x9, x10                   // mtime
    b .Lwss_key
.Lwss_none_earlier:
    mov x26, #0
    mov x27, #0
    mov x28, #0
    mov x20, #0                        // not memoizable (Python: key None)
    b .Lwss_key_skip
.Lwss_key:
    mov x20, #1                        // memoizable
.Lwss_key_skip:
    // memo key match?
    adrp x9, PAGE(tc_watch_seed_key1)
    add x9, x9, LO12(tc_watch_seed_key1)
    ldr x10, [x9]
    cmp x10, x19
    b.ne .Lwss_scan
    ldr x10, [x9, #8]
    cmp x10, x26
    b.ne .Lwss_scan
    ldr x10, [x9, #16]
    cmp x10, x27
    b.ne .Lwss_scan
    ldr x10, [x9, #24]
    cmp x10, x28
    b.ne .Lwss_scan
    ldr x0, [x9, #32]
    b .Lwss_out
.Lwss_scan:
    // scan reversed(earlier[-lookback:]) — the last min(count, lookback) files
    adrp x9, PAGE(tc_watch_seed_lookback)
    add x9, x9, LO12(tc_watch_seed_lookback)
    ldr x10, [x9]
    cmp x23, x10
    b.le .Lwss_start
    mov x23, x10
.Lwss_start:
    // x21 = number to scan (the newest min(total, lookback) entries); x23
    // stays the total earlier count so the newest entries index correctly.
    // x20 must survive as the memoizable flag set at .Lwss_key — the loop
    // below counts down x21, so it is not needed as a scan counter.
    mov x19, #0                        // result state
    mov x21, x23
.Lwss_scanloop:
    cbz x21, .Lwss_done
    sub x24, x23, x21                  // index into the newest-slice
    mov x9, #TC_L_ENTRY_SZ
    mul x9, x24, x9
    add x10, x22, x9                   // entry
    // build the path
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    adrp x1, PAGE(tc_watch_dirpath)
    add x1, x1, LO12(tc_watch_dirpath)
    bl wc_cat
    mov w2, #'/'
    strb w2, [x0], #1
    add x1, x10, #TC_L_NAME
    bl wc_cat
    adrp x0, PAGE(tc_watch_fpath)
    add x0, x0, LO12(tc_watch_fpath)
    bl watch_scan_markers              // x0 = state 0/1/2 (0 = none found)
    cbnz x0, .Lwss_found
    sub x21, x21, #1
    b .Lwss_scanloop
.Lwss_found:
    mov x19, x0
.Lwss_done:
    // memoize only when the earlier-file stat succeeded (Python: key None)
    cbz x20, .Lwss_out
    adrp x9, PAGE(tc_watch_seed_key1)
    add x9, x9, LO12(tc_watch_seed_key1)
    // store the key (begin_ymd, earlier_ymd, size, mtime)
    adrp x9, PAGE(tc_watch_seed_key1)
    add x9, x9, LO12(tc_watch_seed_key1)
    adrp x10, PAGE(tc_window)
    add x10, x10, LO12(tc_window)
    ldr x10, [x10, #TC_W_BEGIN_YMD]
    str x10, [x9]
    str x26, [x9, #8]
    str x27, [x9, #16]
    str x28, [x9, #24]
    str x19, [x9, #32]
    mov x0, x19
.Lwss_out:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_scan_markers(path) -> x0 = 0/1/2: the LAST LIVE_RE marker in the file.
// ============================================================================
    .p2align 2
watch_scan_markers:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // path
    mov x0, x19
    mov x1, #O_RDONLY
    bl open
    mov w20, w0
    cmp w20, #0
    b.lt .Lwsm_none
    // read the whole file (capped)
    mov x21, #0                        // buf
    mov x22, #0                        // len
    mov x23, #0                        // cap
.Lwsm_rloop:
    cmp x23, #0
    b.ne .Lwsm_grow_ok
    mov x23, #READ_CHUNK
    mov x0, x23
    bl malloc
    cbz x0, .Lwsm_close
    mov x21, x0
    b .Lwsm_grow_ok
.Lwsm_grow_ok:
    cmp x22, x23
    b.lt .Lwsm_read
    lsl x23, x23, #1
    ldr x9, =FILE_CAP
    cmp x23, x9
    b.le .Lwsm_grow2
    mov x23, x9
.Lwsm_grow2:
    mov x0, x21
    mov x1, x23
    bl realloc
    cbz x0, .Lwsm_close
    mov x21, x0
.Lwsm_read:
    mov x0, x20
    add x1, x21, x22
    mov x2, #READ_CHUNK
    bl read
    mov w9, w0
    cmp w9, #0
    b.lt .Lwsm_eintr
    cbz w9, .Lwsm_read_done
    add x22, x22, x9
    ldr x9, =FILE_CAP
    cmp x22, x9
    b.le .Lwsm_rloop
    b .Lwsm_close
.Lwsm_eintr:
    cmp w9, #EINTR
    b.eq .Lwsm_rloop
    b .Lwsm_close
.Lwsm_read_done:
    mov x0, x20
    bl close
    // scan lines for markers; the LAST marker wins
    mov x24, #0                        // line start
    mov x25, #0                        // state
.Lwsm_scan:
    cmp x24, x22
    b.ge .Lwsm_done
    mov x0, x21
    mov x1, x22
    mov x2, x24
    mov x3, #'\n'
    bl watch_find_char
    cmp x0, #0
    b.lt .Lwsm_last_line
    mov x26, x0                        // newline
    sub x27, x26, x24                  // line len
    add x28, x26, #1                   // next start
    mov x0, x21
    add x0, x0, x24
    mov x1, x27
    bl watch_line_is_marker
    cbnz x0, .Lwsm_marker
    b .Lwsm_line_done
.Lwsm_marker:
    mov x25, x0
.Lwsm_line_done:
    mov x24, x28
    b .Lwsm_scan
.Lwsm_last_line:
    mov x0, x21
    add x0, x0, x24
    sub x1, x22, x24
    bl watch_line_is_marker
    cbnz x0, .Lwsm_marker2
    b .Lwsm_done
.Lwsm_marker2:
    mov x25, x0
.Lwsm_done:
    mov x0, x25
    mov x19, x21
    cbz x19, .Lwsm_free_done
    mov x0, x19
    bl free
.Lwsm_free_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwsm_close:
    mov x0, x20
    bl close
    cbz x21, .Lwsm_none2
    mov x0, x21
    bl free
.Lwsm_none2:
.Lwsm_none:
    mov x0, #0
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_size_users — the --users bisection (Python _search_width).  Only for
//   TC_WIN_USERS; otherwise a no-op.  Sets TC_W_USERS_WIDTH / _FOUND and
//   begin = end - width.  Probes run with tc_watch_seeking = 1 so readers
//   never seek or prune during the search.
// ============================================================================
    .p2align 2
watch_size_users:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x10, [x9, #TC_W_KIND]
    cmp x10, #TC_WIN_USERS
    b.ne .Lwsu_done
    // end epoch
    ldr x0, [x9, #TC_W_END_YMD]
    ldr x1, [x9, #TC_W_END_SOD]
    bl watch_ymd_sod_to_epoch
    mov x19, x0                        // end_epoch
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    ldr x20, [x9, #TC_O_USERS]         // requested
    ldr x21, [x9, #TC_O_USERS_MAX]     // ceiling
    cmp x21, #1
    b.ge .Lwsu_ceiling_ok
    mov x21, #1
.Lwsu_ceiling_ok:
    bl watch_eff_threshold
    mov x22, x0                        // eff
    // search memo reset
    adrp x9, PAGE(tc_watch_search_n)
    add x9, x9, LO12(tc_watch_search_n)
    str xzr, [x9]
    // seeking flag on
    adrp x9, PAGE(tc_watch_seeking)
    add x9, x9, LO12(tc_watch_seeking)
    mov x10, #1
    str x10, [x9]
    // widest = reported(ceiling)
    mov x0, x21
    bl watch_reported_width
    mov x23, x0                        // widest
    cmp x23, x20
    b.lt .Lwsu_unreachable
    // bisection 1: smallest width with count >= requested
    mov x9, #1                         // lo
    mov x10, x21                       // hi
.Lwsu_b1:
    cmp x9, x10
    b.ge .Lwsu_b1_done
    sub x11, x10, x9
    lsr x11, x11, #1
    add x11, x9, x11                   // mid (floors)
    mov x28, x11                       // keep mid in a callee-saved reg:
    mov x24, x9                        // watch_reported_width clobbers x11
    mov x25, x10
    mov x0, x11
    bl watch_reported_width
    cmp x0, x20
    b.lt .Lwsu_b1_else
    mov x10, x28
    mov x9, x24
    b .Lwsu_b1
.Lwsu_b1_else:
    add x9, x28, #1
    mov x10, x25                      // hi: the call clobbered caller-saved x10
    b .Lwsu_b1
.Lwsu_b1_done:
    mov x24, x9                        // over_width
    mov x0, x9
    bl watch_reported_width
    mov x25, x0                        // over
    // bisection 2: widest width with count <= requested
    mov x9, #1
    mov x10, x21
.Lwsu_b2:
    cmp x9, x10
    b.ge .Lwsu_b2_done
    sub x11, x10, x9
    add x11, x11, #1
    lsr x11, x11, #1
    add x11, x9, x11                   // mid (ceils)
    mov x28, x11                       // keep mid in a callee-saved reg:
    mov x26, x9                        // watch_reported_width clobbers x11
    mov x27, x10
    mov x0, x11
    bl watch_reported_width
    cmp x0, x20
    b.gt .Lwsu_b2_else
    mov x9, x28
    mov x10, x27
    b .Lwsu_b2
.Lwsu_b2_else:
    sub x10, x28, #1
    mov x9, x26
    b .Lwsu_b2
.Lwsu_b2_done:
    mov x26, x9                        // under_width
    mov x0, x9
    bl watch_reported_width
    mov x27, x0                        // under
    // policy
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    ldr x9, [x9, #TC_O_USERS_POLICY]
    cmp x9, #TC_POLICY_AT_MOST
    b.eq .Lwsu_at_most
    cmp x9, #TC_POLICY_NEAREST
    b.eq .Lwsu_nearest
    mov x1, x24                        // at-least
    mov x2, x25
    b .Lwsu_apply
.Lwsu_at_most:
    mov x1, x26
    mov x2, x27
    b .Lwsu_apply
.Lwsu_nearest:
    sub x9, x27, x20
    cmp x9, #0
    b.ge .Lwsu_n_absu
    neg x9, x9
.Lwsu_n_absu:
    sub x10, x25, x20
    cmp x10, #0
    b.ge .Lwsu_n_abso
    neg x10, x10
.Lwsu_n_abso:
    cmp x9, x10
    b.le .Lwsu_n_under
    mov x1, x24
    mov x2, x25
    b .Lwsu_apply
.Lwsu_n_under:
    mov x1, x26
    mov x2, x27
    b .Lwsu_apply
.Lwsu_unreachable:
    mov x1, x21
    mov x2, x23
    b .Lwsu_apply
.Lwsu_apply:
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    str x1, [x9, #TC_W_USERS_WIDTH]
    str x2, [x9, #TC_W_USERS_FOUND]
    adrp x9, PAGE(tc_watch_win_width)
    add x9, x9, LO12(tc_watch_win_width)
    str x1, [x9]
    sub x0, x19, x1
    bl watch_epoch_to_ymd_sod
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    str x0, [x9, #TC_W_BEGIN_YMD]
    str x1, [x9, #TC_W_BEGIN_SOD]
.Lwsu_done:
    adrp x9, PAGE(tc_watch_seeking)
    add x9, x9, LO12(tc_watch_seeking)
    str xzr, [x9]
    // clear the fold-reuse state: the probes perturbed the tables
    adrp x9, PAGE(tc_watch_fold_n)
    add x9, x9, LO12(tc_watch_fold_n)
    str xzr, [x9]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_reported_width(seconds) -> x0 = non-excluded users whose count-column
//   is >= the effective threshold for the window [end - seconds, end].
//   Sets the probe window, counts via the readers, and counts the table.
// ============================================================================
    .p2align 2
watch_reported_width:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // seconds
    adrp x20, PAGE(tc_window)
    add x20, x20, LO12(tc_window)
    ldr x0, [x20, #TC_W_END_YMD]
    ldr x1, [x20, #TC_W_END_SOD]
    bl watch_ymd_sod_to_epoch
    sub x0, x0, x19
    bl watch_epoch_to_ymd_sod
    str x0, [x20, #TC_W_BEGIN_YMD]
    str x1, [x20, #TC_W_BEGIN_SOD]
    bl watch_count_tick
    bl watch_eff_threshold
    mov x21, x0                        // eff
    adrp x22, PAGE(tc_users)
    add x22, x22, LO12(tc_users)
    ldr x23, [x22, #TC_US_COUNT]
    ldr x24, [x22, #TC_US_ENTRIES]
    mov x19, #0                        // n
    mov x20, #0                        // i
.Lwrpw_loop:
    cmp x20, x23
    b.ge .Lwrpw_done
    mov x9, #TC_US_ENTRY_SZ
    mul x9, x20, x9
    add x9, x24, x9
    mov x0, x9
    bl tc_strlen
    mov x1, x0
    mov x0, x9
    bl tc_excl_contains
    cbnz x0, .Lwrpw_next
    mov x0, x20
    bl tc_count_column
    cmp x0, x21
    b.lt .Lwrpw_next
    add x19, x19, #1
.Lwrpw_next:
    add x20, x20, #1
    b .Lwrpw_loop
.Lwrpw_done:
    mov x0, x19
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_eff_threshold() -> x0 = max(min_count, share_floor) when a share is
//   shown or sorted by and the floor is nonzero, else min_count.
// ============================================================================
    .p2align 2
watch_eff_threshold:
    stp x29, x30, [sp, #-16]!
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_MIN_COUNT]
    ldr x2, [x0, #TC_O_SORT]
    cmp x2, #TC_M_OFFLINE_SHARE
    b.ge .Lwet_shown
    ldr x3, [x0, #TC_O_COLUMN_COUNT]
    mov x4, #0
.Lwet_col:
    cmp x4, x3
    b.ge .Lwet_check
    add x5, x0, #TC_O_COLUMNS
    ldr x6, [x5, x4, lsl #3]
    cmp x6, #TC_M_OFFLINE_SHARE
    b.ge .Lwet_shown
    add x4, x4, #1
    b .Lwet_col
.Lwet_check:
    mov x0, x1
    ldp x29, x30, [sp], #16
    ret
.Lwet_shown:
    ldr x2, [x0, #TC_O_SHARE_FLOOR]
    cbz x2, .Lwet_check
    cmp x2, x1
    b.lt .Lwet_check
    mov x0, x2
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_build_ramps — the hex_ramp port: build the "up" ramp, the "down"
//   ramp when tint_falling, and one ramp per highlight rule; the degenerate
//   single-colour check raises the exact ConfigError.
// ============================================================================
    .p2align 2
watch_build_ramps:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_watch_shades)
    add x19, x19, LO12(tc_watch_shades)
    ldr x20, [x19]                     // shades
    ldr x9, =SHADES_MAX
    cmp x20, x9
    b.le .Lwbr_shades_ok
    adrp x0, PAGE(s_shades_too_large)
    add x0, x0, LO12(s_shades_too_large)
    bl tc_report_fail
.Lwbr_shades_ok:
    cmp x20, #1
    b.ge .Lwbr_shades_ge
    mov x20, #1                        // steps = max(1, shades)
.Lwbr_shades_ge:
    adrp x21, PAGE(tc_watch_ramp_count)
    add x21, x21, LO12(tc_watch_ramp_count)
    mov x22, #0                        // ramp index
    // ramp 0: up
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_FADE_UP_RGB
    mov x1, x20
    mov x2, #0                         // key "up"
    bl watch_build_one_ramp            // x0 = ramp base
    add x22, x22, #1
    // ramp 1: down when tint_falling
    adrp x9, PAGE(tc_watch_tint_falling)
    add x9, x9, LO12(tc_watch_tint_falling)
    ldr x9, [x9]
    cbz x9, .Lwbr_highlights
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_FADE_DOWN_RGB
    mov x1, x20
    mov x2, #1
    bl watch_build_one_ramp
    add x22, x22, #1
.Lwbr_highlights:
    // highlight rules
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    ldr x23, [x9, #TC_O_HL_COUNT]
    mov x24, #0
.Lwbr_hl:
    cmp x24, x23
    b.ge .Lwbr_count
    // rule entry
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    add x9, x9, #TC_O_HL_ARR
    mov x10, #TC_HL_RULE_SZ
    mul x10, x24, x10
    add x19, x9, x10                   // rule entry (callee-saved, survives calls)
    // curve: rule's curve or the global; k likewise
    mov x0, x19
    mov x1, x24
    bl watch_rule_curve_k               // x0 = curve id, x1 = k bits
    mov x25, x0
    mov x26, x1
    add x0, x19, #TC_HL_RGB
    mov x1, x20
    add x2, x22, #0
    mov x3, x25
    mov x4, x26
    bl watch_build_one_ramp_full        // x0 = ramp base
    add x22, x22, #1
    add x24, x24, #1
    b .Lwbr_hl
.Lwbr_count:
    str x22, [x21]                     // ramp_count
    // degenerate check: shades > 1 and len(set(ramp)) == 1
    cmp x20, #1
    b.le .Lwbr_done
    mov x24, #0                        // key index
.Lwbr_degen:
    cmp x24, x22
    b.ge .Lwbr_done
    mov x0, x24
    bl watch_ramp_distinct             // x0 = 1 when all shades identical
    cbz x0, .Lwbr_degen_next
    // raise the ConfigError
    adrp x19, PAGE(tc_watch_errbuf)
    add x19, x19, LO12(tc_watch_errbuf)
    mov x23, x19
    mov x0, x23
    adrp x1, PAGE(s_watch_fade_curve)
    add x1, x1, LO12(s_watch_fade_curve)
    bl wc_cat
    mov x23, x0
    // {curve!r}
    mov w1, #'\''
    strb w1, [x23], #1
    adrp x9, PAGE(tc_watch_fade_curve)
    add x9, x9, LO12(tc_watch_fade_curve)
    ldr x9, [x9]
    adrp x10, PAGE(watch_curve_names)
    add x10, x10, LO12(watch_curve_names)
    ldr x1, [x10, x9, lsl #3]
    mov x0, x23
    bl wc_cat
    mov x23, x0
    mov w1, #'\''
    strb w1, [x23], #1
    mov x0, x23
    adrp x1, PAGE(s_collapse_mid2)
    add x1, x1, LO12(s_collapse_mid2)
    bl wc_cat
    mov x23, x0
    // {k:g}
    adrp x9, PAGE(tc_watch_fade_k)
    add x9, x9, LO12(tc_watch_fade_k)
    ldr d0, [x9]
    mov x0, x23
    mov x1, #128
    adrp x2, PAGE(fmt_g)
    add x2, x2, LO12(fmt_g)
    bl snprintf
    mov x0, x23
    bl tc_strlen
    add x23, x23, x0
    mov x0, x23
    adrp x1, PAGE(s_collapse_mid)
    add x1, x1, LO12(s_collapse_mid)
    bl wc_cat
    mov x23, x0
    // the ramp key
    mov x0, x24
    bl watch_ramp_key_str              // x0 = key string
    mov x1, x0
    mov x0, x23
    bl wc_cat
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_collapse_post)
    add x1, x1, LO12(s_collapse_post)
    bl wc_cat
    mov w1, #0
    strb w1, [x0]
    adrp x0, PAGE(tc_watch_errbuf)
    add x0, x0, LO12(tc_watch_errbuf)
    bl tc_report_fail                  // noreturn
.Lwbr_degen_next:
    add x24, x24, #1
    b .Lwbr_degen
.Lwbr_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_rule_curve_k(rule_entry, index) -> (x0 = curve id, x1 = k bits).
//   A rule's -1 curve / -1.0 k inherits the global values.
// ============================================================================
    .p2align 2
watch_rule_curve_k:
    stp x29, x30, [sp, #-16]!
    ldr x2, [x0, #TC_HL_CURVE]
    cmp x2, #-1
    b.ne .Lwrck_curve_ok
    adrp x9, PAGE(tc_watch_fade_curve)
    add x9, x9, LO12(tc_watch_fade_curve)
    ldr x2, [x9]
.Lwrck_curve_ok:
    ldr d0, [x0, #TC_HL_K]
    adrp x9, PAGE(dbl_neg1)
    add x9, x9, LO12(dbl_neg1)
    ldr d1, [x9]
    fcmp d0, d1
    b.ne .Lwrck_k_ok
    adrp x9, PAGE(tc_watch_fade_k)
    add x9, x9, LO12(tc_watch_fade_k)
    ldr d0, [x9]
.Lwrck_k_ok:
    mov x0, x2
    mov x1, x0                        // (k bits are stored as an x-reg below)
    // store the double bits in x1
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    str d0, [x9]
    ldr x1, [x9]
    mov x0, x2
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_build_one_ramp(rgb_ptr, steps, key) — build a ramp with the global
//   curve/k; x0 = ramp base.  watch_build_one_ramp_full(rgb, steps, key,
//   curve, kbits) uses explicit curve/k.
// ============================================================================
    .p2align 2
watch_build_one_ramp:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x9, PAGE(tc_watch_fade_curve)
    add x9, x9, LO12(tc_watch_fade_curve)
    ldr x3, [x9]
    adrp x9, PAGE(tc_watch_fade_k)
    add x9, x9, LO12(tc_watch_fade_k)
    ldr d4, [x9]
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    str d4, [x9]
    ldr x4, [x9]
    bl watch_build_one_ramp_full
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_build_one_ramp_full(rgb_ptr, steps, key, curve, kbits) -> x0 = base
    .p2align 2
watch_build_one_ramp_full:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // rgb ptr
    mov x20, x1                        // steps
    mov x21, x2                        // key
    mov x22, x3                        // curve
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    str x4, [x9]                       // k bits
    ldr d5, [x9]                       // k (double)
    adrp x9, PAGE(tc_watch_dtmp2)            // the curve branches read k from here;
    add x9, x9, LO12(tc_watch_dtmp2)   // a stale dtmp2 would silently use k=0
    str x4, [x9]
    // ramp base = arena + key * shades_max * shade_sz
    adrp x23, PAGE(tc_watch_ramp_arena)
    add x23, x23, LO12(tc_watch_ramp_arena)
    mov x9, #SHADES_MAX
    mul x9, x21, x9
    mov x10, #SHADE_SZ
    mul x9, x9, x10
    add x23, x23, x9                   // base
    // register the ramp descriptor
    adrp x9, PAGE(tc_watch_ramps)
    add x9, x9, LO12(tc_watch_ramps)
    mov x10, #16
    mul x10, x21, x10
    add x9, x9, x10
    str x23, [x9]
    str x20, [x9, #8]
    // rgb
    ldr w24, [x19]
    ldr w25, [x19, #4]
    ldr w26, [x19, #8]
    // for step in range(steps)
    mov x27, #0                        // step
.Lwbrf_loop:
    cmp x27, x20
    b.ge .Lwbrf_done
    // x = step / steps
    scvtf d0, x27
    scvtf d1, x20
    fdiv d0, d0, d1
    // bend = CURVES[curve](x, k)
    cmp x22, #TC_CURVE_LINEAR
    b.eq .Lwbrf_bend_linear
    cmp x22, #TC_CURVE_POWER
    b.eq .Lwbrf_bend_power
    cmp x22, #TC_CURVE_EASE_OUT
    b.eq .Lwbrf_bend_ease_out
    cmp x22, #TC_CURVE_BIAS
    b.eq .Lwbrf_bend_bias
    b .Lwbrf_bend_ease_in_out
.Lwbrf_bend_linear:
    // towards = x
    b .Lwbrf_clamp
.Lwbrf_bend_power:
    // pow(x, k) — every d-reg dies on the call, so x and k live in memory
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    str d0, [x9]                       // save x
    adrp x9, PAGE(tc_watch_dtmp2)
    add x9, x9, LO12(tc_watch_dtmp2)
    ldr d1, [x9]                       // k
    bl pow                             // pow(x, k)
    b .Lwbrf_clamp
.Lwbrf_bend_ease_out:
    // 1 - (1-x)^k
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    str d0, [x9]                       // save x
    fmov d1, #1.0
    fsub d0, d1, d0                    // 1-x
    adrp x9, PAGE(tc_watch_dtmp2)
    add x9, x9, LO12(tc_watch_dtmp2)
    ldr d1, [x9]                       // k
    bl pow                             // (1-x)^k
    fmov d1, #1.0
    fsub d0, d1, d0
    b .Lwbrf_clamp
.Lwbrf_bend_bias:
    // x / (k*(1-x) + x)
    adrp x9, PAGE(tc_watch_dtmp2)
    add x9, x9, LO12(tc_watch_dtmp2)
    ldr d1, [x9]                       // k
    fmov d2, #1.0
    fsub d2, d2, d0                    // 1-x
    fmul d1, d1, d2                    // k*(1-x)
    fadd d1, d1, d0                    // k*(1-x) + x
    fdiv d0, d0, d1
    b .Lwbrf_clamp
.Lwbrf_bend_ease_in_out:
    // x^k/(x^k+(1-x)^k) if 0 < x < 1 else x
    fcmp d0, #0.0
    b.le .Lwbrf_clamp
    fmov d1, #1.0
    fcmp d0, d1
    b.ge .Lwbrf_clamp
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    str d0, [x9]                       // save x
    adrp x9, PAGE(tc_watch_dtmp2)
    add x9, x9, LO12(tc_watch_dtmp2)
    ldr d1, [x9]                       // k
    bl pow                             // x^k
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    str d0, [x9]                       // save x^k
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]                       // x
    fmov d1, #1.0
    fsub d0, d1, d0                    // 1-x
    adrp x9, PAGE(tc_watch_dtmp2)
    add x9, x9, LO12(tc_watch_dtmp2)
    ldr d1, [x9]                       // k
    bl pow                             // (1-x)^k
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d1, [x9]                       // x^k
    fadd d2, d1, d0                    // x^k + (1-x)^k
    fdiv d0, d1, d2
    b .Lwbrf_clamp
.Lwbrf_clamp:
    // towards = min(1.0, max(0.0, bend))
    fmov d1, xzr
    fcmp d0, d1
    b.ge .Lwbrf_clamp_hi
    fmov d0, xzr
.Lwbrf_clamp_hi:
    fmov d1, #1.0
    fcmp d0, d1
    b.le .Lwbrf_clamp_done
    fmov d0, #1.0
.Lwbrf_clamp_done:
    // save towards in a scratch slot (caller-saved d0 dies on snprintf)
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    str d0, [x9]
    // shade dst = base + step * SHADE_SZ
    mov x9, #SHADE_SZ
    mul x9, x27, x9
    add x28, x23, x9                   // dst
    // "\033[38;2;R;G;Bm"
    mov x0, x28
    adrp x1, PAGE(s_esc_38)
    add x1, x1, LO12(s_esc_38)
    bl wc_cat
    mov x19, x0                        // cursor AT the NUL (append in place)
    // r channel
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]
    mov x9, #255
    scvtf d1, x9
    scvtf d2, w24
    fsub d1, d1, d2                    // 255 - r
    fmul d0, d1, d0                    // (255-r)*towards
    scvtf d1, w24
    fadd d0, d1, d0                    // r + ...
    bl rint                            // banker's rounding
    fcvtzs x9, d0
    mov x0, x19
    mov x1, x9
    bl watch_fmt_u64                   // digits into the shade
    mov w1, #';'
    strb w1, [x0], #1
    mov x19, x0
    // g
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]
    mov x9, #255
    scvtf d1, x9
    scvtf d2, w25
    fsub d1, d1, d2
    fmul d0, d1, d0
    scvtf d1, w25
    fadd d0, d1, d0
    bl rint
    fcvtzs x9, d0
    mov x0, x19
    mov x1, x9
    bl watch_fmt_u64
    mov w1, #';'
    strb w1, [x0], #1
    mov x19, x0
    // b
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]
    mov x9, #255
    scvtf d1, x9
    scvtf d2, w26
    fsub d1, d1, d2
    fmul d0, d1, d0
    scvtf d1, w26
    fadd d0, d1, d0
    bl rint
    fcvtzs x9, d0
    mov x0, x19
    mov x1, x9
    bl watch_fmt_u64
    mov w1, #'m'
    strb w1, [x0], #1
    mov w1, #0
    strb w1, [x0]
    add x27, x27, #1
    b .Lwbrf_loop
.Lwbrf_done:
    mov x0, x23                        // base
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_fmt_u64(dst, x1) -> dst after digits (no NUL)
    .p2align 2
watch_fmt_u64:
    stp x29, x30, [sp, #-16]!
    sub sp, sp, #32
    add x2, sp, #20
    cmp x1, #0
    b.ne .Lwfu_digits
    mov w3, #'0'
    strb w3, [x2, #-1]!
    b .Lwfu_copy
.Lwfu_digits:
    mov x4, #10
.Lwfu_loop:
    udiv x5, x1, x4
    msub x6, x5, x4, x1
    add x6, x6, #'0'
    strb w6, [x2, #-1]!
    mov x1, x5
    cbnz x1, .Lwfu_loop
.Lwfu_copy:
    add x3, sp, #20                   // end of the digit buffer
.Lwfu_copy_loop:
    cmp x2, x3
    b.ge .Lwfu_done
    ldrb w4, [x2], #1
    strb w4, [x0], #1
    b .Lwfu_copy_loop
.Lwfu_done:
    add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret

// watch_ramp_distinct(key) -> x0 = 1 when every shade renders identically.
    .p2align 2
watch_ramp_distinct:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x9, PAGE(tc_watch_ramps)
    add x9, x9, LO12(tc_watch_ramps)
    mov x10, #16
    mul x10, x0, x10
    add x9, x9, x10
    ldr x19, [x9]                      // base (callee-saved)
    ldr x20, [x9, #8]                  // count (callee-saved)
    cmp x20, #1
    b.le .Lwrd_no
    mov x21, #1                        // i (callee-saved)
.Lwrd_loop:
    cmp x21, x20
    b.ge .Lwrd_yes
    mov x22, #SHADE_SZ
    mul x22, x21, x22
    add x22, x19, x22                  // shade ptr (callee-saved)
    mov x0, x19
    mov x1, x22
    bl strcmp
    cbnz w0, .Lwrd_no
    add x21, x21, #1
    b .Lwrd_loop
.Lwrd_yes:
    mov x0, #1
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrd_no:
    mov x0, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_ramp_key_str(key) -> x0 = "up" / "down" / "highlightN"
    .p2align 2
watch_ramp_key_str:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    cmp x0, #0
    b.eq .Lwrks_up
    cmp x0, #1
    b.eq .Lwrks_down
    // "highlight" + (key-2)
    adrp x0, PAGE(tc_watch_scratch)
    add x0, x0, LO12(tc_watch_scratch)
    adrp x1, PAGE(s_highlight)
    add x1, x1, LO12(s_highlight)
    bl wc_cat
    sub x1, x19, #2
    bl watch_fmt_u64
    mov w2, #0
    strb w2, [x0]
    adrp x0, PAGE(tc_watch_scratch)
    add x0, x0, LO12(tc_watch_scratch)
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrks_up:
    adrp x0, PAGE(s_up)
    add x0, x0, LO12(s_up)
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwrks_down:
    adrp x0, PAGE(s_down)
    add x0, x0, LO12(s_down)
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
    RODATA
    .p2align 3
dbl_neg1:           .double -1.0
s_collapse_mid2:    .asciz " with fade_k "

    .text
    .bss
    .p2align 3
tc_watch_dtmp2:     .skip 8
tc_watch_dtmp3:     .skip 8
tc_watch_dtmp4:     .skip 8
    .text

// ============================================================================
// watch_compile_patterns — pcre2-compile every highlight pattern; streamer
//   mode suppresses highlights entirely (no ramps, no matching).  A bad
//   pattern reproduces Python's parse_highlights error text.
// ============================================================================
    .p2align 2
watch_compile_patterns:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // streamer mode: highlights = () (Python resolve_watch)
    adrp x9, PAGE(tc_watch_streamer)
    add x9, x9, LO12(tc_watch_streamer)
    ldr x9, [x9]
    cbz x9, .Lwcp_streamer_ok
    adrp x9, PAGE(tc_watch_highlight_on)
    add x9, x9, LO12(tc_watch_highlight_on)
    str xzr, [x9]
    b .Lwcp_done
.Lwcp_streamer_ok:
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    ldr x20, [x19, #TC_O_HL_COUNT]
    cbz x20, .Lwcp_none
    mov x21, #0                        // rule index
.Lwcp_rule:
    cmp x21, x20
    b.ge .Lwcp_done
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    add x9, x9, #TC_O_HL_ARR
    mov x10, #TC_HL_RULE_SZ
    mul x10, x21, x10
    add x9, x9, x10
    ldr x22, [x9, #TC_HL_PAT_COUNT]
    mov x23, #0                        // pattern index
.Lwcp_pat:
    cmp x23, x22
    b.ge .Lwcp_rule_next
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    add x9, x9, #TC_O_HL_ARR
    mov x10, #TC_HL_RULE_SZ
    mul x10, x21, x10
    add x9, x9, x10
    add x9, x9, #TC_HL_PATTERNS
    mov x10, #64
    mul x10, x23, x10
    add x24, x9, x10                   // pattern string
    // pcre2_compile_8(pattern, len, 0, &errcode, &erroffset, 0)
    mov x0, x24
    bl tc_strlen
    mov x1, x0
    mov x0, x24
    mov w2, #0
    adrp x3, PAGE(tc_watch_scratch)          // errcode
    add x3, x3, LO12(tc_watch_scratch)
    add x3, x3, #0
    adrp x4, PAGE(tc_watch_scratch2)         // erroffset
    add x4, x4, LO12(tc_watch_scratch2)
    mov x5, #0
    bl pcre2_compile_8
    cbz x0, .Lwcp_bad
    // store the code; create its match data once
    adrp x9, PAGE(tc_watch_patterns)
    add x9, x9, LO12(tc_watch_patterns)
    mov x10, #TC_HL_PAT_MAX
    mul x10, x21, x10
    add x10, x10, x23
    str x0, [x9, x10, lsl #3]
    // match data (one per pattern is simplest and correct)
    // pcre2_match_data_create_from_pattern_8(code, gcontext): x1 must be
    // NULL so the fallback uses the code's own memctl (the previous
    // pcre2_compile_8 call leaves x1 as undefined caller-saved garbage).
    mov x1, xzr
    bl pcre2_match_data_create_from_pattern_8
    cbz x0, .Lwcp_md_skip
    mov x9, x0                        // md (caller-saved; no call before store)
    mov x10, #TC_HL_PAT_MAX
    mul x10, x21, x10
    add x10, x10, x23                 // slot index (no call between here and store)
    adrp x11, PAGE(tc_watch_match_data)
    add x11, x11, LO12(tc_watch_match_data)
    str x9, [x11, x10, lsl #3]
.Lwcp_md_skip:
    add x23, x23, #1
    b .Lwcp_pat
.Lwcp_rule_next:
    add x21, x21, #1
    b .Lwcp_rule
.Lwcp_bad:
    // "rule {index}: '{pattern}' is not a valid regex ({msg})"
    adrp x19, PAGE(tc_watch_errbuf)
    add x19, x19, LO12(tc_watch_errbuf)
    mov x23, x19
    mov x0, x23
    adrp x1, PAGE(s_rule_pre)
    add x1, x1, LO12(s_rule_pre)
    bl wc_cat
    mov x23, x0
    mov x0, x21
    bl watch_fmt_u64                   // rule index
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_rule_mid)
    add x1, x1, LO12(s_rule_mid)
    bl wc_cat
    mov x23, x0
    mov x0, x23
    mov x1, x24
    bl wc_cat                          // the pattern (single-quoted)
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_rule_bad_regex)
    add x1, x1, LO12(s_rule_bad_regex)
    bl wc_cat
    mov x23, x0
    // pcre2 error message
    adrp x9, PAGE(tc_watch_scratch)
    add x9, x9, LO12(tc_watch_scratch)
    ldr w0, [x9]                       // errcode
    adrp x1, PAGE(tc_watch_scratch2)
    add x1, x1, LO12(tc_watch_scratch2)
    mov x2, #512
    bl pcre2_get_error_message_8
    mov x0, x23
    adrp x1, PAGE(tc_watch_scratch2)
    add x1, x1, LO12(tc_watch_scratch2)
    bl wc_cat
    mov x23, x0
    mov x0, x23
    adrp x1, PAGE(s_rule_post)
    add x1, x1, LO12(s_rule_post)
    bl wc_cat
    mov w1, #0
    strb w1, [x0]
    adrp x0, PAGE(tc_watch_errbuf)
    add x0, x0, LO12(tc_watch_errbuf)
    bl tc_report_fail                  // noreturn
.Lwcp_none:
    adrp x9, PAGE(tc_watch_highlight_on)
    add x9, x9, LO12(tc_watch_highlight_on)
    str xzr, [x9]
.Lwcp_done:
    // highlight_on = (TC_O_HL_COUNT > 0 and not streamer)
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    ldr x10, [x9, #TC_O_HL_COUNT]
    adrp x11, PAGE(tc_watch_streamer)
    add x11, x11, LO12(tc_watch_streamer)
    ldr x11, [x11]
    cbnz x11, .Lwcp_on_off
    cbz x10, .Lwcp_on_off
    adrp x9, PAGE(tc_watch_highlight_on)
    add x9, x9, LO12(tc_watch_highlight_on)
    mov x10, #1
    str x10, [x9]
.Lwcp_on_off:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_reresolve_settings — after tc_config_reload: re-resolve every
//   watch/tail setting whose current source is the config, rebuild the
//   session values (watch_load_settings revalidates).
// ============================================================================
    .p2align 2
watch_reresolve_settings:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, PAGE(tc_opts)
    add x19, x19, LO12(tc_opts)
    mov x20, #TC_O_SRC
    add x20, x19, x20
    // channel (config-sourced only)
    ldr x21, [x20, #TC_SET_CHANNEL*8]
    cmp x21, #TC_SRC_CONFIG
    b.ne .Lwrr_channel_done
    adrp x0, PAGE(s_key_channel)
    add x0, x0, LO12(s_key_channel)
    mov x1, #TC_SEC_NONE
    bl tc_config_get
    cbz x0, .Lwrr_channel_done
    mov x0, x1
    bl watch_parse_channel_value        // copy into TC_O_CHANNEL
.Lwrr_channel_done:
    // interval
    mov x0, #TC_SET_INTERVAL
    adrp x1, PAGE(s_key_interval)
    add x1, x1, LO12(s_key_interval)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_NONNEG_FLOAT
    mov x4, #TC_O_INTERVAL
    bl watch_reresolve_one
    // min_interval
    mov x0, #TC_SET_MIN_INTERVAL
    adrp x1, PAGE(s_key_min_interval)
    add x1, x1, LO12(s_key_min_interval)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_NONNEG_FLOAT
    mov x4, #TC_O_MIN_INTERVAL
    bl watch_reresolve_one
    // hold
    mov x0, #TC_SET_HOLD
    adrp x1, PAGE(s_key_hold)
    add x1, x1, LO12(s_key_hold)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_NONNEG_FLOAT
    mov x4, #TC_O_HOLD
    bl watch_reresolve_one
    // min_redraw
    mov x0, #TC_SET_MIN_REDRAW
    adrp x1, PAGE(s_key_min_redraw)
    add x1, x1, LO12(s_key_min_redraw)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_NONNEG_FLOAT
    mov x4, #TC_O_MIN_REDRAW
    bl watch_reresolve_one
    // shades
    mov x0, #TC_SET_SHADES
    adrp x1, PAGE(s_key_shades)
    add x1, x1, LO12(s_key_shades)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_POS_INT
    mov x4, #TC_O_SHADES
    bl watch_reresolve_one
    // replay_steps
    mov x0, #TC_SET_REPLAY_STEPS
    adrp x1, PAGE(s_key_replay_steps)
    add x1, x1, LO12(s_key_replay_steps)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_NONNEG_INT
    mov x4, #TC_O_REPLAY_STEPS
    bl watch_reresolve_one
    // full_repaint
    mov x0, #TC_SET_FULL_REPAINT
    adrp x1, PAGE(s_key_full_repaint)
    add x1, x1, LO12(s_key_full_repaint)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_NONNEG_INT
    mov x4, #TC_O_FULL_REPAINT
    bl watch_reresolve_one
    // show_timing
    mov x0, #TC_SET_SHOW_TIMING
    adrp x1, PAGE(s_key_show_timing)
    add x1, x1, LO12(s_key_show_timing)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_BOOL
    mov x4, #TC_O_SHOW_TIMING
    bl watch_reresolve_one
    // tint_falling
    mov x0, #TC_SET_TINT_FALLING
    adrp x1, PAGE(s_key_tint_falling)
    add x1, x1, LO12(s_key_tint_falling)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_BOOL
    mov x4, #TC_O_TINT_FALLING
    bl watch_reresolve_one
    // fade_curve
    mov x0, #TC_SET_FADE_CURVE
    adrp x1, PAGE(s_key_fade_curve)
    add x1, x1, LO12(s_key_fade_curve)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_CURVE
    mov x4, #TC_O_FADE_CURVE
    bl watch_reresolve_one
    // fade_k
    mov x0, #TC_SET_FADE_K
    adrp x1, PAGE(s_key_fade_k)
    add x1, x1, LO12(s_key_fade_k)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_POS_FLOAT
    mov x4, #TC_O_FADE_K
    bl watch_reresolve_one
    // fade_up / fade_down (hex)
    mov x0, #TC_SET_FADE_UP
    adrp x1, PAGE(s_key_fade_up)
    add x1, x1, LO12(s_key_fade_up)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_HEX
    mov x4, #TC_O_FADE_UP_RGB
    bl watch_reresolve_hex
    mov x0, #TC_SET_FADE_DOWN
    adrp x1, PAGE(s_key_fade_down)
    add x1, x1, LO12(s_key_fade_down)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_HEX
    mov x4, #TC_O_FADE_DOWN_RGB
    bl watch_reresolve_hex
    // user_width
    mov x0, #TC_SET_USER_WIDTH
    adrp x1, PAGE(s_key_user_width)
    add x1, x1, LO12(s_key_user_width)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_NONNEG_INT
    mov x4, #TC_O_USER_WIDTH
    bl watch_reresolve_one
    // streamer_mode
    mov x0, #TC_SET_STREAMER_MODE
    adrp x1, PAGE(s_key_streamer_mode)
    add x1, x1, LO12(s_key_streamer_mode)
    mov x2, #TC_SEC_WATCH
    mov x3, #P_BOOL
    mov x4, #TC_O_STREAMER_MODE
    bl watch_reresolve_one
    // tail
    mov x0, #TC_SET_NOTIFY
    adrp x1, PAGE(s_key_notify)
    add x1, x1, LO12(s_key_notify)
    mov x2, #TC_SEC_TAIL
    mov x3, #P_BOOL
    mov x4, #TC_O_NOTIFY
    bl watch_reresolve_one
    mov x0, #TC_SET_MAX_EVENTS
    adrp x1, PAGE(s_key_max_events)
    add x1, x1, LO12(s_key_max_events)
    mov x2, #TC_SEC_TAIL
    mov x3, #P_POS_INT
    mov x4, #TC_O_MAX_EVENTS
    bl watch_reresolve_one
    mov x0, #TC_SET_SEED_LOOKBACK
    adrp x1, PAGE(s_key_seed_lookback)
    add x1, x1, LO12(s_key_seed_lookback)
    mov x2, #TC_SEC_TAIL
    mov x3, #P_POS_INT
    mov x4, #TC_O_SEED_LOOKBACK
    bl watch_reresolve_one
    // refresh the session copy + validation
    bl watch_load_settings
    bl watch_load_tail
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_reresolve_one(set, key, section, parser, value_off) — when the
//   setting's current source is config, re-query and re-convert.
    .p2align 2
watch_reresolve_one:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // set
    mov x20, x1                        // key
    mov x21, x2                        // section
    mov x22, x3                        // parser
    mov x23, x4                        // value offset
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    mov x10, #TC_O_SRC
    add x9, x9, x10
    ldr x10, [x9, x19, lsl #3]
    cmp x10, #TC_SRC_CONFIG
    b.eq .Lwrro_cfg
    cmp x10, #TC_SRC_CONFIG_WATCH
    b.eq .Lwrro_cfg
    cmp x10, #TC_SRC_CONFIG_TAIL
    b.eq .Lwrro_cfg
    b .Lwrro_done
.Lwrro_cfg:
    mov x0, x20
    mov x1, x21
    bl tc_config_get
    cbz x0, .Lwrro_done                // key gone: keep the last value
    mov x0, x22
    mov x1, x1
    bl watch_parse_for_store           // x0 = value
    cmp x1, #0
    b.ne .Lwrro_done                   // conversion error: keep (CLI validated)
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    str x0, [x9, x23]
    mov x10, #TC_O_SRC
    add x10, x9, x10
    ldr x11, [x10, x19, lsl #3]        // keep the config source id
.Lwrro_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_reresolve_hex — like watch_reresolve_one for P_HEX (writes RGB + raw)
    .p2align 2
watch_reresolve_hex:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                        // set
    mov x20, x1                        // key
    mov x21, x2                        // section
    mov x22, x4                        // rgb value offset
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    mov x10, #TC_O_SRC
    add x9, x9, x10
    ldr x10, [x9, x19, lsl #3]
    cmp x10, #TC_SRC_CONFIG
    b.eq .Lwrh_cfg
    cmp x10, #TC_SRC_CONFIG_WATCH
    b.eq .Lwrh_cfg
    b .Lwrh_done
.Lwrh_cfg:
    mov x0, x20
    mov x1, x21
    bl tc_config_get
    cbz x0, .Lwrh_done
    mov x0, x1
    bl tc_parse_hex_colour             // x0 = rgb, x1 = ok
    cmp x1, #0
    b.ne .Lwrh_done
    adrp x9, PAGE(tc_opts)
    add x9, x9, LO12(tc_opts)
    add x9, x9, x22
    lsr x10, x0, #16
    and x10, x10, #0xFF
    str w10, [x9]
    lsr x10, x0, #8
    and x10, x10, #0xFF
    str w10, [x9, #4]
    and x10, x0, #0xFF
    str w10, [x9, #8]
.Lwrh_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_parse_for_store(parser, raw) -> (x0 = value, x1 = status)
//   Mirrors tc_cli's tc_parse_for_store for the parsers this module needs.
//   The numeric parsers use strtod/strtol directly (tc_cli's versions are
//   not exported).
    .p2align 2
watch_parse_for_store:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // parser
    mov x20, x1                        // raw
    cmp x0, #P_NONNEG_FLOAT
    b.eq .Lwpfs_nnf
    cmp x0, #P_POS_FLOAT
    b.eq .Lwpfs_pf
    cmp x0, #P_POS_INT
    b.eq .Lwpfs_pos
    cmp x0, #P_NONNEG_INT
    b.eq .Lwpfs_nonneg
    cmp x0, #P_BOOL
    b.eq .Lwpfs_bool
    cmp x0, #P_CURVE
    b.eq .Lwpfs_curve
    mov x0, #0
    mov x1, #1
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpfs_nnf:
    mov x0, x20
    adrp x1, PAGE(tc_watch_scratch)
    add x1, x1, LO12(tc_watch_scratch)
    bl strtod                        // d0 = value
    fcmp d0, #0.0
    b.lt .Lwpfs_bad
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    str d0, [x9]
    ldr x0, [x9]
    mov x1, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpfs_pf:
    mov x0, x20
    adrp x1, PAGE(tc_watch_scratch)
    add x1, x1, LO12(tc_watch_scratch)
    bl strtod
    fcmp d0, #0.0
    b.le .Lwpfs_bad
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    str d0, [x9]
    ldr x0, [x9]
    mov x1, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpfs_pos:
    mov x0, x20
    adrp x1, PAGE(tc_watch_scratch)
    add x1, x1, LO12(tc_watch_scratch)
    bl strtol
    cmp x0, #0
    b.le .Lwpfs_bad
    mov x1, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpfs_nonneg:
    mov x0, x20
    adrp x1, PAGE(tc_watch_scratch)
    add x1, x1, LO12(tc_watch_scratch)
    bl strtol
    cmp x0, #0
    b.lt .Lwpfs_bad
    mov x1, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpfs_bad:
    mov x0, #0
    mov x1, #1
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpfs_bool:
    mov x0, x20
    bl tc_parse_bool
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpfs_curve:
    mov x0, x20
    bl tc_parse_curve
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_parse_channel_value(raw) — copy a config channel value into TC_O_CHANNEL
    .p2align 2
watch_parse_channel_value:
    stp x29, x30, [sp, #-16]!
    mov x1, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_CHANNEL
    mov x2, #TC_O_CHANNEL_SZ
    bl tc_copy_str_cap
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_launch_tints — launch_tints + replay_tints (Python 3636-3692).
//   Skips when an explicit --end was given.  Steps a virtual clock from the
//   replay horizon back to now, folding the readers' windows and running the
//   colorizer per step; the resulting carried tints land in tc_watch_tints.
// ============================================================================
    .p2align 2
watch_launch_tints:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // explicit end -> no replay (nothing moves)
    adrp x9, PAGE(tc_watch_end_given)
    add x9, x9, LO12(tc_watch_end_given)
    ldr x9, [x9]
    cbnz x9, .Lwlt_done
    // no readers or no max_steps -> {}
    adrp x9, PAGE(tc_watch_reader_n)
    add x9, x9, LO12(tc_watch_reader_n)
    ldr x9, [x9]
    cbz x9, .Lwlt_done
    adrp x9, PAGE(tc_watch_replay_steps)
    add x9, x9, LO12(tc_watch_replay_steps)
    ldr x9, [x9]
    cbz x9, .Lwlt_done
    // steps = max(1, int(replay_horizon(hold, interval, steps) / interval))
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d0, [x9]
    adrp x10, PAGE(tc_watch_interval)
    add x10, x10, LO12(tc_watch_interval)
    ldr d1, [x10]
    adrp x0, PAGE(tc_watch_replay_steps)
    add x0, x0, LO12(tc_watch_replay_steps)
    ldr x0, [x0]
    bl watch_replay_horizon           // d0 = horizon
    adrp x9, PAGE(tc_watch_interval)
    add x9, x9, LO12(tc_watch_interval)
    ldr d1, [x9]
    fdiv d0, d0, d1
    fcvtzs x19, d0                    // int()
    cmp x19, #1
    b.ge .Lwlt_steps_ok
    mov x19, #1
.Lwlt_steps_ok:
    // now (monotonic)
    bl watch_monotonic
    adrp x9, PAGE(tc_watch_now)
    add x9, x9, LO12(tc_watch_now)
    str d0, [x9]
    // clear tints + previous
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    str xzr, [x9]
    adrp x9, PAGE(tc_watch_prev_n)
    add x9, x9, LO12(tc_watch_prev_n)
    str xzr, [x9]
    // window epochs
    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x0, [x9, #TC_W_BEGIN_YMD]
    ldr x1, [x9, #TC_W_BEGIN_SOD]
    bl watch_ymd_sod_to_epoch
    mov x20, x0                        // begin_epoch

    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x0, [x9, #TC_W_END_YMD]
    ldr x1, [x9, #TC_W_END_SOD]
    bl watch_ymd_sod_to_epoch
    mov x21, x0                        // end_epoch

    adrp x9, PAGE(tc_window)
    add x9, x9, LO12(tc_window)
    ldr x22, [x9, #TC_W_BEGIN_ROLLS]
    ldr x23, [x9, #TC_W_STATE_FILTER]
    // for step in range(steps, -1, -1)
    mov x24, x19                       // step
.Lwlt_step:
    cmp x24, #0
    b.lt .Lwlt_done
    // back = step * interval
    adrp x9, PAGE(tc_watch_interval)
    add x9, x9, LO12(tc_watch_interval)
    ldr d0, [x9]
    scvtf d1, x24
    fmul d2, d1, d0                    // back
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    str d2, [x9]                       // back (double)
    // at_end = end_epoch - back
    fcvtzs x9, d2
    sub x25, x21, x9                   // at_end (u64)
    // at_begin
    mov x26, x20
    cbz x22, .Lwlt_begin_done
    sub x26, x20, x9                   // begin_rolls: begin - back
.Lwlt_begin_done:
    // fold every reader's window into a scratch counts map
    adrp x9, PAGE(tc_watch_scratch)
    add x9, x9, LO12(tc_watch_scratch)
    mov x0, x9
    mov x1, #0
    mov x2, #2048
    bl memset
    adrp x27, PAGE(tc_watch_reader_n)
    add x27, x27, LO12(tc_watch_reader_n)
    ldr x27, [x27]
    adrp x28, PAGE(tc_watch_readers)
    add x28, x28, LO12(tc_watch_readers)
    ldr x28, [x28]
    // replay counts map: use tc_watch_scratch2 as {login[26], n u64} records
    adrp x9, PAGE(tc_watch_scratch2)
    add x9, x9, LO12(tc_watch_scratch2)
    mov x0, x9
    mov x1, #0
    mov x2, #1024
    bl memset
    mov x9, #0                         // replay map count (x9 = caller-saved...
    // reader loop counter: x19 (callee-saved; x19 is dead after mov x24,x19)
    mov x19, #0
.Lwlt_rd:
    cmp x19, x27
    b.ge .Lwlt_fold_done
    ldr x11, [x28, x19, lsl #3]       // rd
    ldr x0, [x11, #RD_FDATE]
    mov x1, x26
    mov x2, x25
    bl watch_bucket_bounds             // x0 = lo or -1
    cmp x0, #0
    b.lt .Lwlt_rd_next
    mov x12, x0                        // lo
    mov x13, x1                        // hi
    ldr x11, [x28, x19, lsl #3]        // rd (reload: x11 is caller-saved)
    mov x0, x11
    mov x1, x12
    mov x2, x13
    bl watch_reader_window             // x0 = window record
    // fold into the replay map (apply the state filter)
    mov x14, x0                        // win
    mov x15, #0                        // rec index
.Lwlt_ww:
    cmp x15, #WW_MAX
    b.ge .Lwlt_rd_next
    mov x9, #WW_SZ
    mul x9, x15, x9
    add x16, x14, x9
    ldrb w17, [x16, #WW_LOGIN]
    cbz w17, .Lwlt_rd_next             // sentinel
    ldrb w17, [x16, #WW_STATE]
    cbz x23, .Lwlt_ww_match
    cmp x23, x17
    b.ne .Lwlt_ww_next
.Lwlt_ww_match:
    ldr x0, [x16, #WW_N]
    cbz x0, .Lwlt_ww_next
    // add to the replay map {login[26], n}
    add x1, x16, #WW_LOGIN
    bl watch_replay_add                // (login, n)
    .Lwlt_ww_next:
    add x15, x15, #1
    b .Lwlt_ww
.Lwlt_rd_next:
    add x19, x19, #1
    b .Lwlt_rd
.Lwlt_fold_done:
    // colorize this step: previous = tc_watch_prev, carried = tints,
    // now = now - back, wall = at_end (UTC epoch)
    mov x0, x25                        // at_end (wall)
    adrp x1, PAGE(tc_watch_hold)
    add x1, x1, LO12(tc_watch_hold)
    ldr d0, [x1]
    adrp x1, PAGE(tc_watch_dtmp2)
    add x1, x1, LO12(tc_watch_dtmp2)
    str d0, [x1]
    adrp x1, PAGE(tc_watch_choose_hold)
    add x1, x1, LO12(tc_watch_choose_hold)
    str d0, [x1]
    adrp x1, PAGE(tc_watch_choose_wall)
    add x1, x1, LO12(tc_watch_choose_wall)
    str x0, [x1]
    // replay now = now - back
    adrp x0, PAGE(tc_watch_now)
    add x0, x0, LO12(tc_watch_now)
    ldr d0, [x0]
    adrp x0, PAGE(tc_watch_dtmp)
    add x0, x0, LO12(tc_watch_dtmp)
    ldr d1, [x0]                       // back
    fsub d0, d0, d1
    adrp x0, PAGE(tc_watch_dtmp3)
    add x0, x0, LO12(tc_watch_dtmp3)
    str d0, [x0]                       // replay now
    bl watch_colorize_step
    // previous = the replay map (copy it into tc_watch_prev)
    adrp x0, PAGE(tc_watch_scratch2)
    add x0, x0, LO12(tc_watch_scratch2)
    adrp x1, PAGE(tc_watch_prev)
    add x1, x1, LO12(tc_watch_prev)
    mov x2, #1024
    bl memcpy_copy
    // prev_n = number of {login, n} records in the replay map
    adrp x0, PAGE(tc_watch_scratch2)
    add x0, x0, LO12(tc_watch_scratch2)
    mov x9, #0                         // count
.Lwlt_cnt:
    cmp x9, #128
    b.ge .Lwlt_cnt_done
    mov x10, #34
    mul x10, x9, x10
    add x10, x0, x10
    ldrb w11, [x10]
    cbz w11, .Lwlt_cnt_done
    add x9, x9, #1
    b .Lwlt_cnt
.Lwlt_cnt_done:
    adrp x10, PAGE(tc_watch_prev_n)
    add x10, x10, LO12(tc_watch_prev_n)
    str x9, [x10]
    sub x24, x24, #1
    b .Lwlt_step
.Lwlt_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_replay_add(login, n) — add n to {login, n} in the replay map
//   (tc_watch_scratch2 records of {login[26], n u64}).
// ============================================================================
    .p2align 2
watch_replay_add:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x14, x15, [sp, #-16]!
    stp x16, x17, [sp, #-16]!
    mov x19, x0                        // n
    mov x20, x1                        // login
    adrp x21, PAGE(tc_watch_scratch2)
    add x21, x21, LO12(tc_watch_scratch2)
    mov x22, #0
.Lwra_loop:
    cmp x22, #128
    b.ge .Lwra_append
    mov x9, #34
    mul x9, x22, x9
    add x9, x21, x9
    ldrb w10, [x9]
    cbz w10, .Lwra_append
    mov x10, #0
.Lwra_cmp:
    ldrb w11, [x9, x10]
    ldrb w12, [x20, x10]
    cmp w11, w12
    b.ne .Lwra_next
    cbz w11, .Lwra_found
    add x10, x10, #1
    b .Lwra_cmp
.Lwra_found:
    ldr x10, [x9, #32]
    add x10, x10, x19
    str x10, [x9, #32]
    b .Lwra_done
.Lwra_next:
    add x22, x22, #1
    b .Lwra_loop
.Lwra_append:
    mov x9, #34
    mul x9, x22, x9
    add x9, x21, x9
    mov x10, #0
.Lwra_copy:
    ldrb w11, [x20, x10]
    cbz w11, .Lwra_copy_done
    cmp x10, #25
    b.ge .Lwra_copy_done
    strb w11, [x9, x10]
    add x10, x10, #1
    b .Lwra_copy
.Lwra_copy_done:
    mov w11, #0
    strb w11, [x9, x10]
    str x19, [x9, #32]
.Lwra_done:
    ldp x16, x17, [sp], #16
    ldp x14, x15, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_colorize_step — the colorizer for one replay step: filter carried
//   tints by expiry, then for every (login, n) in the replay map run the
//   tint logic (Python colorizer + tinting.tint("", login, count)).
//   The replay map lives in tc_watch_scratch2 (records {login[26], n}).
// ============================================================================
    .p2align 2
watch_colorize_step:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    // filter carried tints: keep when hold <= 0 or now - when < hold
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]                       // replay now
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d1, [x9]
    fcmp d1, #0.0
    b.le .Lwcs_keep_all
    adrp x19, PAGE(tc_watch_tint_count)
    add x19, x19, LO12(tc_watch_tint_count)
    ldr x19, [x19]
    adrp x20, PAGE(tc_watch_tints)
    add x20, x20, LO12(tc_watch_tints)
    mov x21, #0                        // out
    mov x22, #0                        // i
.Lwcs_filter:
    cmp x22, x19
    b.ge .Lwcs_filter_done
    mov x9, #TT_SZ
    mul x9, x22, x9
    add x23, x20, x9
    ldr d2, [x23, #TT_WHEN]
    fsub d2, d0, d2                    // age
    fcmp d2, d1
    b.ge .Lwcs_filter_next             // age >= hold: drop
    cmp x21, x22
    b.eq .Lwcs_filter_keep
    mov x9, #TT_SZ
    mul x9, x21, x9
    add x24, x20, x9
    mov x9, #0
.Lwcs_filter_copy:
    cmp x9, #TT_SZ
    b.ge .Lwcs_filter_keep
    ldrb w10, [x23, x9]
    strb w10, [x24, x9]
    add x9, x9, #1
    b .Lwcs_filter_copy
.Lwcs_filter_keep:
    add x21, x21, #1
.Lwcs_filter_next:
    add x22, x22, #1
    b .Lwcs_filter
.Lwcs_filter_done:
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    str x21, [x9]
.Lwcs_keep_all:
    // walk the replay map
    adrp x19, PAGE(tc_watch_scratch2)
    add x19, x19, LO12(tc_watch_scratch2)
    mov x20, #0                        // i
.Lwcs_loop:
    cmp x20, #128
    b.ge .Lwcs_done
    mov x9, #34
    mul x9, x20, x9
    add x19, x19, x9                   // record
    ldrb w10, [x19]
    cbz w10, .Lwcs_done
    ldr x10, [x19, #32]                // n
    add x0, x19, #0                    // login ptr
    mov x1, x10                        // count
    adrp x2, PAGE(tc_watch_scratch)          // text ptr ("" — unused)
    add x2, x2, LO12(tc_watch_scratch)
    mov x3, x2
    mov w4, #0
    strb w4, [x3]                      // text = ""
    bl watch_tint_apply                // tints only; text is ignored
    add x20, x20, #1
    mov x19, #0                        // reset (loop recomputes below)
    // recompute the base
    adrp x19, PAGE(tc_watch_scratch2)
    add x19, x19, LO12(tc_watch_scratch2)
    b .Lwcs_loop
.Lwcs_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// memcpy_copy(dst, src, len) — byte copy helper
    .p2align 2
memcpy_copy:
    mov x3, #0
.Lmcc_loop:
    cmp x3, x2
    b.ge .Lmcc_done
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    b .Lmcc_loop
.Lmcc_done:
    ret

// ============================================================================
// Tint machinery (the Python colorizer / fade_color / palette_chooser)
// ============================================================================

// watch_tint_find(login, len) -> x0 = tint record ptr or 0
    .p2align 2
watch_tint_find:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // login
    mov x20, x1                        // len
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_tints)
    add x11, x11, LO12(tc_watch_tints)
    mov x12, #0
.Lwtf_loop:
    cmp x12, x10
    b.ge .Lwtf_none
    mov x13, #TT_SZ
    mul x13, x12, x13
    add x13, x11, x13
    mov x14, #0
.Lwtf_cmp:
    ldrb w15, [x13, x14]
    ldrb w16, [x19, x14]
    cmp w15, w16
    b.ne .Lwtf_next
    cbz w15, .Lwtf_found
    add x14, x14, #1
    b .Lwtf_cmp
.Lwtf_found:
    mov x0, x13
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwtf_next:
    add x12, x12, #1
    b .Lwtf_loop
.Lwtf_none:
    mov x0, #0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_tint_set(login, len, dir, when) — assign/refresh a tint.
    .p2align 2
watch_tint_set:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                        // login
    mov x20, x1                        // len
    mov x21, x2                        // dir
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    str d0, [x9]                       // when (double)
    mov x0, x19
    mov x1, x20
    bl watch_tint_find
    cbz x0, .Lwts_new
    strb w21, [x0, #TT_DIR]
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d0, [x9]
    str d0, [x0, #TT_WHEN]
    b .Lwts_done
.Lwts_new:
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    ldr x10, [x9]
    cmp x10, #TINT_MAX
    b.ge .Lwts_done                    // full: drop (very unlikely)
    adrp x11, PAGE(tc_watch_tints)
    add x11, x11, LO12(tc_watch_tints)
    mov x12, #TT_SZ
    mul x12, x10, x12
    add x11, x11, x12
    mov x13, #0
.Lwts_copy:
    ldrb w14, [x19, x13]
    cbz w14, .Lwts_copy_done
    cmp x13, #25
    b.ge .Lwts_copy_done
    strb w14, [x11, x13]
    add x13, x13, #1
    b .Lwts_copy
.Lwts_copy_done:
    mov w14, #0
    strb w14, [x11, x13]
    strb w21, [x11, #TT_DIR]
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d0, [x9]
    str d0, [x11, #TT_WHEN]
    add x10, x10, #1
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    str x10, [x9]
.Lwts_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_tint_remove(login, len)
    .p2align 2
watch_tint_remove:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    bl watch_tint_find
    cbz x0, .Lwtr_done
    // shift the tail down
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_tints)
    add x11, x11, LO12(tc_watch_tints)
    sub x10, x10, #1
    // index of the removed record
    sub x12, x0, x11
    mov x13, #TT_SZ
    sdiv x12, x12, x13                 // removed index
    // copy [removed+1, n) down one
    mov x14, x12
.Lwtr_shift:
    cmp x14, x10
    b.ge .Lwtr_store
    add x15, x14, #1
    mov x9, #TT_SZ
    mul x9, x15, x9
    add x15, x11, x9
    mov x9, #TT_SZ
    mul x9, x14, x9
    add x16, x11, x9
    mov x17, #0
.Lwtr_copy:
    cmp x17, #TT_SZ
    b.ge .Lwtr_shift_next
    ldrb w18, [x15, x17]
    strb w18, [x16, x17]
    add x17, x17, #1
    b .Lwtr_copy
.Lwtr_shift_next:
    add x14, x14, #1
    b .Lwtr_shift
.Lwtr_store:
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    str x10, [x9]
.Lwtr_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_prev_find(login, len) -> x0 = count or -1
    .p2align 2
watch_prev_find:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    adrp x9, PAGE(tc_watch_prev_n)
    add x9, x9, LO12(tc_watch_prev_n)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_prev)
    add x11, x11, LO12(tc_watch_prev)
    mov x12, #0
.Lwpf_loop:
    cmp x12, x10
    b.ge .Lwpf_none
    mov x13, #PV_SZ
    mul x13, x12, x13
    add x13, x11, x13
    mov x14, #0
.Lwpf_cmp:
    ldrb w15, [x13, x14]
    ldrb w16, [x19, x14]
    cmp w15, w16
    b.ne .Lwpf_next
    cbz w15, .Lwpf_found
    add x14, x14, #1
    b .Lwpf_cmp
.Lwpf_found:
    ldr x0, [x13, #PV_COUNT]
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpf_next:
    add x12, x12, #1
    b .Lwpf_loop
.Lwpf_none:
    mov x0, #-1
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// watch_build_prev — rebuild tc_watch_prev from the tally's users:
//   {login: count-column} for non-excluded users with count > 0.
    .p2align 2
watch_build_prev:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x9, PAGE(tc_watch_prev_n)
    add x9, x9, LO12(tc_watch_prev_n)
    str xzr, [x9]
    adrp x19, PAGE(tc_users)
    add x19, x19, LO12(tc_users)
    ldr x20, [x19, #TC_US_COUNT]
    ldr x21, [x19, #TC_US_ENTRIES]
    mov x22, #0                        // i
.Lwbp_loop:
    cmp x22, x20
    b.ge .Lwbp_done
    mov x9, #TC_US_ENTRY_SZ
    mul x9, x22, x9
    add x23, x21, x9
    mov x0, x23
    bl tc_strlen
    mov x1, x0
    mov x0, x23
    bl tc_excl_contains
    cbnz x0, .Lwbp_next
    mov x0, x22
    bl tc_count_column
    cbz x0, .Lwbp_next
    // append {login, count}
    adrp x9, PAGE(tc_watch_prev_n)
    add x9, x9, LO12(tc_watch_prev_n)
    ldr x10, [x9]
    cmp x10, #PREV_MAX
    b.ge .Lwbp_done
    adrp x11, PAGE(tc_watch_prev)
    add x11, x11, LO12(tc_watch_prev)
    mov x12, #PV_SZ
    mul x12, x10, x12
    add x11, x11, x12
    mov x13, #0
.Lwbp_copy:
    ldrb w14, [x23, x13]
    cbz w14, .Lwbp_copy_done
    cmp x13, #25
    b.ge .Lwbp_copy_done
    strb w14, [x11, x13]
    add x13, x13, #1
    b .Lwbp_copy
.Lwbp_copy_done:
    mov w14, #0
    strb w14, [x11, x13]
    str x0, [x11, #PV_COUNT]
    add x10, x10, #1
    str x10, [x9]
.Lwbp_next:
    add x22, x22, #1
    b .Lwbp_loop
.Lwbp_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_filter_tints — expire carried tints: keep when hold <= 0 or
//   now - when < hold.  now comes from tc_watch_dtmp3 (set per frame/replay).
// ============================================================================
    .p2align 2
watch_filter_tints:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d1, [x9]
    fcmp d1, #0.0
    b.le .Lwft_done
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]                       // now
    adrp x19, PAGE(tc_watch_tint_count)
    add x19, x19, LO12(tc_watch_tint_count)
    ldr x19, [x19]
    adrp x20, PAGE(tc_watch_tints)
    add x20, x20, LO12(tc_watch_tints)
    mov x21, #0                        // out
    mov x22, #0                        // i
.Lwft_filter:
    cmp x22, x19
    b.ge .Lwft_store
    mov x9, #TT_SZ
    mul x9, x22, x9
    add x23, x20, x9
    ldr d2, [x23, #TT_WHEN]
    fsub d2, d0, d2                    // age
    fcmp d2, d1
    b.ge .Lwft_next
    cmp x21, x22
    b.eq .Lwft_keep
    mov x9, #TT_SZ
    mul x9, x21, x9
    add x24, x20, x9
    mov x9, #0
.Lwft_copy:
    cmp x9, #TT_SZ
    b.ge .Lwft_keep
    ldrb w10, [x23, x9]
    strb w10, [x24, x9]
    add x9, x9, #1
    b .Lwft_copy
.Lwft_keep:
    add x21, x21, #1
.Lwft_next:
    add x22, x22, #1
    b .Lwft_filter
.Lwft_store:
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    str x21, [x9]
.Lwft_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_fade_color(key, age) -> x0 = shade escape ptr or 0 (expired).
//   age in d0 (double).  Python fade_color.
// ============================================================================
    .p2align 2
watch_fade_color:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // key
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    str d0, [x9]                       // age
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d1, [x9]
    fcmp d1, #0.0
    b.le .Lwfc_indef
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d0, [x9]
    fcmp d0, d1                        // age >= hold?
    b.lt .Lwfc_index
    mov x0, #0                         // expired
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwfc_index:
    // shades = ramps[key]; hold / len(shades)
    adrp x9, PAGE(tc_watch_ramps)
    add x9, x9, LO12(tc_watch_ramps)
    mov x10, #16
    mul x10, x19, x10
    add x9, x9, x10
    ldr x11, [x9]                      // base
    ldr x12, [x9, #8]                  // len
    // step = hold / len
    scvtf d1, x12
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d0, [x9]                       // hold
    fdiv d1, d0, d1                    // hold/len
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d0, [x9]                       // age
    fdiv d0, d0, d1                    // age / step
    fcvtzs x13, d0                     // int()
    sub x14, x12, #1
    cmp x13, x14
    b.le .Lwfc_idx_ok
    mov x13, x14
.Lwfc_idx_ok:
    mov x9, #SHADE_SZ
    mul x9, x13, x9
    add x0, x11, x9
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwfc_indef:
    // hold <= 0: shades[0]
    adrp x9, PAGE(tc_watch_ramps)
    add x9, x9, LO12(tc_watch_ramps)
    mov x10, #16
    mul x10, x19, x10
    add x9, x9, x10
    ldr x0, [x9]                       // base
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_choose(login) -> x0 = ramp key (0 up / 1 down / 2+i highlight) or -1.
//   The palette chooser: a match within [wall - hold, wall] on any reader
//   wins; the LAST (highest-index) rule beats earlier ones.
// ============================================================================
    .p2align 2
watch_choose:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // login
    adrp x9, PAGE(tc_watch_highlight_on)
    add x9, x9, LO12(tc_watch_highlight_on)
    ldr x9, [x9]
    cbz x9, .Lwch_none
    adrp x9, PAGE(tc_watch_choose_wall)
    add x9, x9, LO12(tc_watch_choose_wall)
    ldr x20, [x9]                      // at_wall (epoch)
    adrp x9, PAGE(tc_watch_choose_hold)
    add x9, x9, LO12(tc_watch_choose_hold)
    ldr d0, [x9]
    fcmp d0, #0.0
    b.le .Lwch_cut_none
    fcvtzs x21, d0
    sub x21, x20, x21                  // cutoff (epoch)
    b .Lwch_cut_done
.Lwch_cut_none:
    mov x21, #-1                       // no cutoff
.Lwch_cut_done:
    mov x22, #-1                       // best rule
    adrp x23, PAGE(tc_watch_reader_n)
    add x23, x23, LO12(tc_watch_reader_n)
    ldr x23, [x23]
    adrp x24, PAGE(tc_watch_readers)
    add x24, x24, LO12(tc_watch_readers)
    ldr x24, [x24]
    mov x25, #0                        // reader index
.Lwch_rd:
    cmp x25, x23
    b.ge .Lwch_done
    ldr x26, [x24, x25, lsl #3]        // rd
    // day epoch
    ldr x0, [x26, #RD_FDATE]
    mov x1, #0
    bl watch_ymd_sod_to_epoch
    mov x27, x0                        // day_start epoch
    ldr x28, [x26, #RD_MATCH_N]
    ldr x9, [x26, #RD_MATCHES]
    mov x26, #0                        // match index
.Lwch_m:
    cmp x26, x28
    b.ge .Lwch_rd_next
    mov x10, #MT_SZ
    mul x10, x26, x10
    add x10, x9, x10
    // login match?
    add x11, x10, #MT_LOGIN
    mov x0, x19
    mov x1, x11
    bl strcmp
    cbnz w0, .Lwch_m_next
    // when = day_start + second
    ldr x11, [x10, #MT_SECOND]
    add x12, x27, x11
    cmp x12, x20
    b.gt .Lwch_m_next                  // when > at_wall
    cmp x21, #0
    b.lt .Lwch_when_ok                 // no cutoff
    cmp x12, x21
    b.lt .Lwch_m_next                  // when < cutoff
.Lwch_when_ok:
    ldrb w11, [x10, #MT_RULE]
    cmp x11, x22
    b.le .Lwch_m_next
    mov x22, x11                       // best = index (last wins)
.Lwch_m_next:
    add x26, x26, #1
    b .Lwch_m
.Lwch_rd_next:
    add x25, x25, #1
    b .Lwch_rd
.Lwch_done:
    cmp x22, #0
    b.lt .Lwch_none
    add x0, x22, #2                    // ramp key = 2 + rule index
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwch_none:
    mov x0, #-1
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_tint_apply(login, count, text) -> x0 = tinted text ptr (or text).
//   The Python colorizer.tint(): compare against the previous frame, assign
//   up/down, apply the palette + fade, wrap in the escape + ANSI_RESET.
//   now comes from tc_watch_dtmp3.
// ============================================================================
    .p2align 2
watch_tint_apply:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // login
    mov x20, x1                        // count
    mov x21, x2                        // text
    // now (double)
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    str d0, [x9]                       // now
    // previous?
    adrp x9, PAGE(tc_watch_prev_n)
    add x9, x9, LO12(tc_watch_prev_n)
    ldr x10, [x9]
    cbz x10, .Lwta_no_prev
    // before = prev_find(login)
    mov x0, x19
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl watch_prev_find                 // x0 = count or -1
    mov x22, x0
    cmp x22, #0
    b.lt .Lwta_up                      // before is None -> a new row rises
    cmp x20, x22
    b.le .Lwta_no_up
    // count > before: tints[login] = ("up", now)
.Lwta_up:
    mov x0, x19
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    mov x2, #1                         // up
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d0, [x9]
    bl watch_tint_set
    b .Lwta_entry
.Lwta_no_up:
    cmp x20, x22
    b.ge .Lwta_no_before
    // count < before: down only when tint_falling and the held dir is down
    adrp x9, PAGE(tc_watch_tint_falling)
    add x9, x9, LO12(tc_watch_tint_falling)
    ldr x9, [x9]
    cbz x9, .Lwta_no_before
    mov x0, x19
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl watch_tint_find
    cbz x0, .Lwta_down_default
    ldrb w9, [x0, #TT_DIR]
    cmp w9, #2
    b.ne .Lwta_no_before
    b .Lwta_down_set
.Lwta_down_default:
    b .Lwta_down_set
.Lwta_down_set:
    mov x0, x19
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    mov x2, #2                         // down
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d0, [x9]
    bl watch_tint_set
    b .Lwta_entry
.Lwta_no_prev:
.Lwta_no_before:
.Lwta_entry:
    // entry = tints.get(login)
    mov x0, x19
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl watch_tint_find
    cbz x0, .Lwta_plain
    mov x23, x0                        // tint record
    // palette = choose(login) or entry.dir
    mov x0, x19
    bl watch_choose                    // x0 = ramp key or -1
    mov x24, x0
    cmp x24, #0
    b.ge .Lwta_palette_ok
    ldrb w24, [x23, #TT_DIR]           // 1 = up, 2 = down
.Lwta_palette_ok:
    // color = fade_color(palette, now - when, hold)
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d0, [x9]                       // now
    ldr d1, [x23, #TT_WHEN]
    fsub d0, d0, d1                    // age
    mov x0, x24
    bl watch_fade_color                // x0 = shade ptr or 0
    cbz x0, .Lwta_expired
    mov x25, x0                        // shade
    // build: {shade}{text}\033[0m
    adrp x26, PAGE(tc_watch_tintbuf)
    add x26, x26, LO12(tc_watch_tintbuf)
    mov x0, x26
    mov x1, x25
    bl wc_cat
    mov x26, x0
    mov x0, x26
    mov x1, x21
    bl wc_cat
    mov x26, x0
    mov x0, x26
    adrp x1, PAGE(s_reset)
    add x1, x1, LO12(s_reset)
    bl wc_cat
    adrp x0, PAGE(tc_watch_tintbuf)
    add x0, x0, LO12(tc_watch_tintbuf)
    b .Lwta_out
.Lwta_expired:
    // tints.pop(login); return text
    mov x0, x19
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl watch_tint_remove
    b .Lwta_plain
.Lwta_plain:
    mov x0, x21
.Lwta_out:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_tint_hook(ctx, rec, text) -> x0 = tinted text.  Called by
//   tc_render.S's emit_table_row for each displayed row; implements the
//   live-frame colorizer.  Must preserve x19-x28.
// ============================================================================
    .p2align 2
watch_tint_hook:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x1                        // rec
    mov x20, x2                        // text
    add x0, x19, #ROW_LOGIN
    ldr x1, [x19, #ROW_COUNT]
    mov x2, x20
    bl watch_tint_apply
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_next_wait — compute the sleep for the loop's tail: wait = interval -
//   elapsed, bounded by the next tint change; then sleep max(wait, 0).
// ============================================================================
    .p2align 2
watch_next_wait:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    // elapsed = now - started
    bl watch_monotonic
    adrp x9, PAGE(tc_watch_started)
    add x9, x9, LO12(tc_watch_started)
    ldr d1, [x9]
    fsub d0, d0, d1
    adrp x9, PAGE(tc_watch_elapsed)
    add x9, x9, LO12(tc_watch_elapsed)
    str d0, [x9]
    // wait = interval - elapsed
    adrp x9, PAGE(tc_watch_interval)
    add x9, x9, LO12(tc_watch_interval)
    ldr d1, [x9]
    fsub d2, d1, d0
    // due = next_tint_change(now)
    adrp x9, PAGE(tc_watch_now)
    add x9, x9, LO12(tc_watch_now)
    ldr d0, [x9]
    bl watch_next_tint_change          // d0 = due or -1 (none)
    fcmp d0, #0.0
    b.lt .Lwnw_sleep
    adrp x9, PAGE(tc_watch_now)
    add x9, x9, LO12(tc_watch_now)
    ldr d1, [x9]
    fsub d0, d0, d1                    // due - now
    fcmp d0, d2
    b.ge .Lwnw_sleep
    fmov d2, d0                        // wait = min(wait, due - now)
.Lwnw_sleep:
    fcmp d2, #0.0
    b.le .Lwnw_done
    fmov d0, d2
    bl watch_sleep
.Lwnw_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_next_tint_change(now) -> d0 = soonest shade boundary or -1 (none).
//   Python next_tint_change: step = hold/max(1,shades); due = when +
//   min((int(age/step)+1)*step, hold) over live tints.
// ============================================================================
    .p2align 2
watch_next_tint_change:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    str d0, [x9]                       // now
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d1, [x9]
    fcmp d1, #0.0
    b.le .Lwntc_none
    adrp x9, PAGE(tc_watch_tint_count)
    add x9, x9, LO12(tc_watch_tint_count)
    ldr x10, [x9]
    cbz x10, .Lwntc_none
    // step = hold / max(1, shades)
    adrp x9, PAGE(tc_watch_shades)
    add x9, x9, LO12(tc_watch_shades)
    ldr x11, [x9]
    cmp x11, #1
    b.ge .Lwntc_shades_ok
    mov x11, #1
.Lwntc_shades_ok:
    scvtf d2, x11
    fdiv d2, d1, d2                    // step
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    str d2, [x9]                       // step (double)
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    mov x10, #-1
    // encode "no soonest" as -1 bits in dtmp3
    scvtf d3, x10
    str d3, [x9]                       // soonest = -1 (sentinel)
    adrp x19, PAGE(tc_watch_tint_count)
    add x19, x19, LO12(tc_watch_tint_count)
    ldr x19, [x19]
    adrp x20, PAGE(tc_watch_tints)
    add x20, x20, LO12(tc_watch_tints)
    mov x21, #0                        // i
.Lwntc_loop:
    cmp x21, x19
    b.ge .Lwntc_done
    mov x9, #TT_SZ
    mul x9, x21, x9
    add x22, x20, x9
    ldr d0, [x22, #TT_WHEN]
    adrp x9, PAGE(tc_watch_dtmp4)
    add x9, x9, LO12(tc_watch_dtmp4)
    ldr d1, [x9]                       // now
    fsub d3, d1, d0                    // age
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d4, [x9]
    fcmp d3, d4
    b.ge .Lwntc_next                   // age >= hold: plain
    // k = int(age/step)
    adrp x9, PAGE(tc_watch_dtmp)
    add x9, x9, LO12(tc_watch_dtmp)
    ldr d2, [x9]                       // step
    fdiv d3, d3, d2
    fcvtzs x23, d3                     // int(age/step)
    add x23, x23, #1
    scvtf d3, x23
    fmul d3, d3, d2                    // (int+1)*step
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d4, [x9]
    fcmp d3, d4
    b.le .Lwntc_min_ok
    fmov d3, d4                        // min(..., hold)
.Lwntc_min_ok:
    fadd d3, d0, d3                    // due = when + ...
    // soonest = min(soonest, due)
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d4, [x9]
    fcmp d4, #0.0
    b.lt .Lwntc_first
    fcmp d3, d4
    b.ge .Lwntc_next
.Lwntc_first:
    str d3, [x9]                       // soonest = due
.Lwntc_next:
    add x21, x21, #1
    b .Lwntc_loop
.Lwntc_done:
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    ldr d0, [x9]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwntc_none:
    adrp x9, PAGE(tc_watch_dtmp3)
    add x9, x9, LO12(tc_watch_dtmp3)
    mov x10, #-1
    scvtf d0, x10
    str d0, [x9]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_build_status — the two status lines appended to every frame:
//   "" then "watching -- every {interval:g}s ({src}), hold {held} ({src})
//   [-- Ctrl-C to stop]" with the optional timing tail (Python watch_status).
//   Appends to the captured frame (tc_watch_lines/tc_watch_frame_cap).
// ============================================================================
    .p2align 2
watch_build_status:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    // blank line (append at the captured line count)
    adrp x9, PAGE(tc_frame_count)
    add x9, x9, LO12(tc_frame_count)
    ldr x10, [x9]
    adrp x11, PAGE(tc_watch_lines)
    add x11, x11, LO12(tc_watch_lines)
    ldr x11, [x11]
    ldr x12, [x11, x10, lsl #3]
    mov w13, #0
    strb w13, [x12]
    add x10, x10, #1
    str x10, [x9]
    // status line
    ldr x12, [x11, x10, lsl #3]
    mov x19, x12                       // dst
    mov x0, x19
    adrp x1, PAGE(s_watching_pre)
    add x1, x1, LO12(s_watching_pre)
    bl wc_cat
    mov x19, x0
    mov x0, x19
    adrp x1, PAGE(s_every)
    add x1, x1, LO12(s_every)
    bl wc_cat
    mov x19, x0
    // interval %g
    adrp x9, PAGE(tc_watch_interval)
    add x9, x9, LO12(tc_watch_interval)
    ldr d0, [x9]
    mov x0, x19
    mov x1, #128
    adrp x2, PAGE(fmt_g)
    add x2, x2, LO12(fmt_g)
    bl snprintf
    mov x0, x19
    bl tc_strlen
    add x19, x19, x0
    mov x0, x19
    adrp x1, PAGE(s_s_paren)
    add x1, x1, LO12(s_s_paren)
    bl wc_cat
    mov x19, x0
    // interval source
    adrp x9, PAGE(tc_watch_interval_src)
    add x9, x9, LO12(tc_watch_interval_src)
    ldr x0, [x9]
    bl tc_source_str
    mov x2, x1
    mov x1, x0
    mov x0, x19
    bl wc_catn
    mov x19, x0
    mov x0, x19
    adrp x1, PAGE(s_hold_mid)
    add x1, x1, LO12(s_hold_mid)
    bl wc_cat
    mov x19, x0
    // held
    adrp x9, PAGE(tc_watch_hold)
    add x9, x9, LO12(tc_watch_hold)
    ldr d0, [x9]
    fcmp d0, #0.0
    b.le .Lwbs_indef
    mov x0, x19
    mov x1, #128
    adrp x2, PAGE(fmt_g)
    add x2, x2, LO12(fmt_g)
    bl snprintf
    mov x0, x19
    bl tc_strlen
    add x19, x19, x0
    mov x0, x19
    adrp x1, PAGE(s_hold_s)
    add x1, x1, LO12(s_hold_s)
    bl wc_cat
    mov x19, x0
    b .Lwbs_hold_done
.Lwbs_indef:
    mov x0, x19
    adrp x1, PAGE(s_indefinite)
    add x1, x1, LO12(s_indefinite)
    bl wc_cat
    mov x19, x0
.Lwbs_hold_done:
    mov x0, x19
    adrp x1, PAGE(s_open_paren)
    add x1, x1, LO12(s_open_paren)
    bl wc_cat
    mov x19, x0
    // hold source
    adrp x9, PAGE(tc_watch_hold_src)
    add x9, x9, LO12(tc_watch_hold_src)
    ldr x0, [x9]
    bl tc_source_str
    mov x2, x1
    mov x1, x0
    mov x0, x19
    bl wc_catn
    mov x19, x0
    mov x0, x19
    adrp x1, PAGE(s_close_paren2)
    add x1, x1, LO12(s_close_paren2)
    bl wc_cat
    mov x19, x0
    // show_timing
    adrp x9, PAGE(tc_watch_show_timing)
    add x9, x9, LO12(tc_watch_show_timing)
    ldr x9, [x9]
    cbz x9, .Lwbs_slower
    mov x0, x19
    adrp x1, PAGE(s_tick_ms)
    add x1, x1, LO12(s_tick_ms)
    bl wc_cat
    mov x19, x0
    // elapsed*1000 %.0f
    adrp x9, PAGE(tc_watch_elapsed)
    add x9, x9, LO12(tc_watch_elapsed)
    ldr d0, [x9]
    ldr x10, =1000
    scvtf d1, x10
    fmul d0, d0, d1
    mov x0, x19
    mov x1, #128
    adrp x2, PAGE(fmt_0f)
    add x2, x2, LO12(fmt_0f)
    bl snprintf
    mov x0, x19
    bl tc_strlen
    add x19, x19, x0
    mov x0, x19
    adrp x1, PAGE(s_ms)
    add x1, x1, LO12(s_ms)
    bl wc_cat
    mov x19, x0
.Lwbs_slower:
    // elapsed > interval?
    adrp x9, PAGE(tc_watch_elapsed)
    add x9, x9, LO12(tc_watch_elapsed)
    ldr d0, [x9]
    adrp x9, PAGE(tc_watch_interval)
    add x9, x9, LO12(tc_watch_interval)
    ldr d1, [x9]
    fcmp d0, d1
    b.le .Lwbs_post
    mov x0, x19
    adrp x1, PAGE(s_slower)
    add x1, x1, LO12(s_slower)
    bl wc_cat
    mov x19, x0
    adrp x9, PAGE(tc_watch_elapsed)
    add x9, x9, LO12(tc_watch_elapsed)
    ldr d0, [x9]
    ldr x10, =1000
    scvtf d1, x10
    fmul d0, d0, d1
    mov x0, x19
    mov x1, #128
    adrp x2, PAGE(fmt_0f)
    add x2, x2, LO12(fmt_0f)
    bl snprintf
    mov x0, x19
    bl tc_strlen
    add x19, x19, x0
    mov x0, x19
    adrp x1, PAGE(s_ms_slower)
    add x1, x1, LO12(s_ms_slower)
    bl wc_cat
    mov x19, x0
.Lwbs_post:
    mov x0, x19
    adrp x1, PAGE(s_watching_post)
    add x1, x1, LO12(s_watching_post)
    bl wc_cat
    mov w1, #0
    strb w1, [x0]
    // bump the captured count
    adrp x9, PAGE(tc_frame_count)
    add x9, x9, LO12(tc_frame_count)
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_prepare_frame — allocate the frame line buffers for the current
//   plan (header + table + slack), grow the painted/burst buffers.
// ============================================================================
    .p2align 2
watch_prepare_frame:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    // estimate the frame height
    adrp x19, PAGE(tc_plan_reported_n)
    add x19, x19, LO12(tc_plan_reported_n)
    ldr x20, [x19]
    cbz x20, .Lwpf_empty
    // header lines
    adrp x21, PAGE(tc_opts)
    add x21, x21, LO12(tc_opts)
    ldr x22, [x21, #TC_O_HEADER_MODE]
    mov x23, #0
    cmp x22, #TC_HDR_FULL
    b.ne .Lwpf_hdr_compact
    adrp x22, PAGE(tc_plan_hdr_count)
    add x22, x22, LO12(tc_plan_hdr_count)
    ldr x23, [x22]
    add x23, x23, #2                  // rows + files + blank
    b .Lwpf_hdr_done
.Lwpf_hdr_compact:
    cmp x22, #TC_HDR_COMPACT
    b.ne .Lwpf_hdr_done
    mov x23, #2
.Lwpf_hdr_done:
    // table: header + rule + displayed + [others] + rule + footer
    add x23, x23, #2                  // header + rule
    adrp x22, PAGE(tc_plan_displayed_n)
    add x22, x22, LO12(tc_plan_displayed_n)
    ldr x22, [x22]
    add x23, x23, x22
    adrp x22, PAGE(tc_plan_hidden_n)
    add x22, x22, LO12(tc_plan_hidden_n)
    ldr x22, [x22]
    cbz x22, .Lwpf_no_others
    add x23, x23, #1
.Lwpf_no_others:
    add x23, x23, #1                  // closing rule
    add x23, x23, #1                  // footer line
    adrp x22, PAGE(tc_plan_excl_appeared)
    add x22, x22, LO12(tc_plan_excl_appeared)
    ldr x22, [x22]
    cbz x22, .Lwpf_slack
    add x23, x23, #1                  // excluded line
    b .Lwpf_slack
.Lwpf_empty:
    mov x23, #0
    adrp x22, PAGE(tc_opts)
    add x22, x22, LO12(tc_opts)
    ldr x22, [x22, #TC_O_HEADER_MODE]
    cmp x22, #TC_HDR_FULL
    b.ne .Lwpf_empty_compact
    adrp x22, PAGE(tc_plan_hdr_count)
    add x22, x22, LO12(tc_plan_hdr_count)
    ldr x23, [x22]
    add x23, x23, #2
    b .Lwpf_empty_done
.Lwpf_empty_compact:
    cmp x22, #TC_HDR_COMPACT
    b.ne .Lwpf_empty_done
    mov x23, #2
.Lwpf_empty_done:
    add x23, x23, #1                  // "No users met the threshold"
    adrp x22, PAGE(tc_plan_excl_appeared)
    add x22, x22, LO12(tc_plan_excl_appeared)
    ldr x22, [x22]
    cbz x22, .Lwpf_slack
    add x23, x23, #1
.Lwpf_slack:
    add x23, x23, #2                  // status lines
    add x23, x23, #8                  // slack
    mov x19, x23                       // need
    // grow the line pointer array + storage
    adrp x20, PAGE(tc_watch_frame_cap)
    add x20, x20, LO12(tc_watch_frame_cap)
    ldr x21, [x20]
    cmp x19, x21
    b.le .Lwpf_alloc_done
    mov x0, x19
    mov x1, #8
    mul x0, x0, x1
    bl malloc
    cbz x0, .Lwpf_oom
    mov x21, x0
    mov x0, x19
    ldr x9, =FRAME_LINE_SZ
    mul x0, x0, x9
    bl malloc
    cbz x0, .Lwpf_oom
    mov x22, x0
    // fill the pointer array
    mov x23, #0
.Lwpf_fill:
    cmp x23, x19
    b.ge .Lwpf_fill_done
    ldr x9, =FRAME_LINE_SZ
    mul x9, x23, x9
    add x9, x22, x9
    str x9, [x21, x23, lsl #3]
    add x23, x23, #1
    b .Lwpf_fill
.Lwpf_fill_done:
    adrp x9, PAGE(tc_watch_lines)
    add x9, x9, LO12(tc_watch_lines)
    str x21, [x9]
    adrp x9, PAGE(tc_watch_linebuf)
    add x9, x9, LO12(tc_watch_linebuf)
    str x22, [x9]
    str x19, [x20]
.Lwpf_alloc_done:
    // grow the painted storage
    adrp x19, PAGE(tc_watch_frame_cap)
    add x19, x19, LO12(tc_watch_frame_cap)
    ldr x19, [x19]
    adrp x20, PAGE(tc_watch_painted_cap)
    add x20, x20, LO12(tc_watch_painted_cap)
    ldr x21, [x20]
    cmp x19, x21
    b.le .Lwpf_paint_done
    mov x0, x19
    mov x1, #8
    mul x0, x0, x1
    bl malloc
    cbz x0, .Lwpf_oom
    mov x21, x0
    mov x0, x19
    ldr x9, =FRAME_LINE_SZ
    mul x0, x0, x9
    bl malloc
    cbz x0, .Lwpf_oom
    mov x22, x0
    mov x23, #0
.Lwpf_pfill:
    cmp x23, x19
    b.ge .Lwpf_pfill_done
    ldr x9, =FRAME_LINE_SZ
    mul x9, x23, x9
    add x9, x22, x9
    str x9, [x21, x23, lsl #3]
    add x23, x23, #1
    b .Lwpf_pfill
.Lwpf_pfill_done:
    adrp x9, PAGE(tc_watch_painted)
    add x9, x9, LO12(tc_watch_painted)
    str x21, [x9]
    adrp x9, PAGE(tc_watch_painted_block)
    add x9, x9, LO12(tc_watch_painted_block)
    str x22, [x9]
    str x19, [x20]
.Lwpf_paint_done:
    // grow the burst buffer
    adrp x19, PAGE(tc_watch_frame_cap)
    add x19, x19, LO12(tc_watch_frame_cap)
    ldr x19, [x19]
    ldr x9, =FRAME_LINE_SZ
    add x19, x19, #1
    mul x19, x19, x9
    add x19, x19, #64
    adrp x20, PAGE(tc_watch_burst_cap)
    add x20, x20, LO12(tc_watch_burst_cap)
    ldr x21, [x20]
    cmp x19, x21
    b.le .Lwpf_burst_done
    adrp x9, PAGE(tc_watch_burst)
    add x9, x9, LO12(tc_watch_burst)
    ldr x0, [x9]
    mov x1, x19
    bl realloc
    cbz x0, .Lwpf_oom
    adrp x9, PAGE(tc_watch_burst)
    add x9, x9, LO12(tc_watch_burst)
    str x0, [x9]
    adrp x9, PAGE(tc_watch_burst_cap)
    add x9, x9, LO12(tc_watch_burst_cap)
    str x19, [x9]
.Lwpf_burst_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwpf_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

// ============================================================================
// watch_free_plan — free the plan's per-tick allocations before re-planning.
// ============================================================================
    .p2align 2
watch_free_plan:
    stp x29, x30, [sp, #-16]!
    adrp x9, PAGE(tc_plan_reported)
    add x9, x9, LO12(tc_plan_reported)
    ldr x0, [x9]
    cbz x0, .Lwfp2_reported_ok
    bl free
    str xzr, [x9]
.Lwfp2_reported_ok:
    adrp x9, PAGE(tc_plan_excl_names)
    add x9, x9, LO12(tc_plan_excl_names)
    ldr x0, [x9]
    cbz x0, .Lwfp2_excl_ok
    bl free
    str xzr, [x9]
.Lwfp2_excl_ok:
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_screen_paint — the Screen.paint port: clip every frame line to the
//   terminal width, full-repaint on the first frame / width change / every
//   full_every frames, otherwise diff-based absolute addressing.  Writes the
//   burst with one write(1) after fflush.
//   Register roles: x19=width, x20=n, x21=lines, x22=painted ptrs,
//   x23=full flag, x24=burst, x25=burst cursor, x26=old painted n,
//   x27=row, x28=scratch.
// ============================================================================
    .p2align 2
watch_screen_paint:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    bl watch_terminal_width
    mov x19, x0                        // width
    adrp x9, PAGE(tc_frame_count)
    add x9, x9, LO12(tc_frame_count)
    ldr x20, [x9]                      // frame line count
    adrp x9, PAGE(tc_watch_lines)
    add x9, x9, LO12(tc_watch_lines)
    ldr x21, [x9]                      // lines array
    adrp x9, PAGE(tc_watch_painted)
    add x9, x9, LO12(tc_watch_painted)
    ldr x22, [x9]                      // painted ptrs
    adrp x9, PAGE(tc_watch_painted_n)
    add x9, x9, LO12(tc_watch_painted_n)
    ldr x26, [x9]                      // old painted n
    // full = painted_n == 0 or width != screen_width or (full_every and
    // since_full >= full_every)
    mov x23, #0
    cbz x26, .Lwsp_full
    adrp x9, PAGE(tc_watch_screen_width)
    add x9, x9, LO12(tc_watch_screen_width)
    ldr x10, [x9]
    cmp x10, x19
    b.ne .Lwsp_full
    adrp x9, PAGE(tc_watch_full_repaint)
    add x9, x9, LO12(tc_watch_full_repaint)
    ldr x10, [x9]
    cbz x10, .Lwsp_diff
    adrp x9, PAGE(tc_watch_full_repaint)
    add x9, x9, LO12(tc_watch_full_repaint)
    ldr x11, [x9]
    cbz x11, .Lwsp_diff
    adrp x9, PAGE(tc_watch_since_full)
    add x9, x9, LO12(tc_watch_since_full)
    ldr x10, [x9]
    cmp x10, x11
    b.lt .Lwsp_diff
    b .Lwsp_full
.Lwsp_full:
    mov x23, #1
.Lwsp_diff:
    // build the burst
    adrp x24, PAGE(tc_watch_burst)
    add x24, x24, LO12(tc_watch_burst)
    ldr x24, [x24]
    mov x25, x24                       // cursor
    cbnz x23, .Lwsp_build_full
    // diff mode: per row, clip, compare, emit, copy
    mov x27, #0
.Lwsp_diff_row:
    cmp x27, x20
    b.ge .Lwsp_diff_done
    ldr x0, [x21, x27, lsl #3]         // this tick's raw line
    mov x1, x19
    bl watch_clip                      // x0 = clipped ptr (clipbuf or line)
    mov x28, x0                        // clipped
    mov x0, x28
    ldr x1, [x22, x27, lsl #3]         // old painted text
    bl strcmp
    cbz w0, .Lwsp_diff_copy            // unchanged: still copy (no emit)
    // emit "\033[{row+1};1H" + clipped + "\033[K"
    mov x0, x25
    mov x1, #128
    add x3, x27, #1
    adrp x2, PAGE(s_home_fmt)
    add x2, x2, LO12(s_home_fmt)
    bl snprintf
    mov x0, x25
    bl tc_strlen
    add x25, x25, x0
    mov x0, x25
    mov x1, x28
    bl burst_cat
    mov x25, x0
    mov x0, x25
    adrp x1, PAGE(s_clr_eol)
    add x1, x1, LO12(s_clr_eol)
    bl burst_cat
    mov x25, x0
.Lwsp_diff_copy:
    // copy the clipped text into the painted slot (x28 survives? no —
    // reload: the slot is x22[row]; copy from the clip result)
    // (x28 is caller-saved and died in wc_cat; the clipped text lives in
    //  tc_watch_clipbuf or the line buffer; both are stable — reload it)
    ldr x0, [x21, x27, lsl #3]
    mov x1, x19
    bl watch_clip                      // recompute the clipped ptr
    ldr x1, [x22, x27, lsl #3]         // painted slot
    mov x2, x0
    mov x0, x1
    mov x1, x2
    bl watch_strcpy
    add x27, x27, #1
    b .Lwsp_diff_row
.Lwsp_diff_done:
    // shorter frame: clear below
    cmp x20, x26
    b.ge .Lwsp_diff_done2
    add x9, x20, #1
    mov x0, x25
    mov x1, #128
    mov x3, x9
    adrp x2, PAGE(s_home_fmt)
    add x2, x2, LO12(s_home_fmt)
    bl snprintf
    mov x0, x25
    bl tc_strlen
    add x25, x25, x0
    mov x0, x25
    adrp x1, PAGE(s_clr_below)
    add x1, x1, LO12(s_clr_below)
    bl burst_cat
    mov x25, x0
.Lwsp_diff_done2:
    b .Lwsp_burst_done
.Lwsp_build_full:
    mov x0, x25
    adrp x1, PAGE(s_full_pre)
    add x1, x1, LO12(s_full_pre)
    bl burst_cat
    mov x25, x0
    mov x27, #0
.Lwsp_full_row:
    cmp x27, x20
    b.ge .Lwsp_full_done
    ldr x0, [x21, x27, lsl #3]
    mov x1, x19
    bl watch_clip                      // x0 = clipped
    mov x28, x0
    mov x0, x25
    mov x1, x28
    bl burst_cat
    mov x25, x0
    mov x0, x25
    adrp x1, PAGE(s_line_k)
    add x1, x1, LO12(s_line_k)
    bl burst_cat
    mov x25, x0
    // copy into the painted slot
    ldr x1, [x22, x27, lsl #3]
    mov x2, x28
    mov x0, x1
    mov x1, x2
    bl watch_strcpy
    add x27, x27, #1
    b .Lwsp_full_row
.Lwsp_full_done:
    mov x0, x25
    adrp x1, PAGE(s_full_post)
    add x1, x1, LO12(s_full_post)
    bl burst_cat
    mov x25, x0
.Lwsp_burst_done:
    // write the burst (one write after flushing stdio)
    mov x0, #0
    bl fflush
    sub x9, x25, x24
    cbz x9, .Lwsp_no_write
    mov x0, #STDOUT
    mov x1, x24
    mov x2, x9
    bl write
.Lwsp_no_write:
    adrp x9, PAGE(tc_watch_painted_n)
    add x9, x9, LO12(tc_watch_painted_n)
    str x20, [x9]
    adrp x9, PAGE(tc_watch_screen_width)
    add x9, x9, LO12(tc_watch_screen_width)
    str x19, [x9]
    cbnz x23, .Lwsp_full_reset
    adrp x9, PAGE(tc_watch_since_full)
    add x9, x9, LO12(tc_watch_since_full)
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    b .Lwsp_done
.Lwsp_full_reset:
    adrp x9, PAGE(tc_watch_since_full)
    add x9, x9, LO12(tc_watch_since_full)
    str xzr, [x9]
.Lwsp_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
// ============================================================================
// watch_terminal_width() -> x0 = columns (isatty + TIOCGWINSZ, fallback 80).
// ============================================================================
    .p2align 2
watch_terminal_width:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x0, #STDOUT
    bl isatty
    cbz x0, .Lwtw_fallback
    sub sp, sp, #16
    mov x0, #STDOUT
    mov x1, #TIOCGWINSZ
    mov x2, sp
    bl ioctl
    cmp x0, #0
    b.ne .Lwtw_fallback2
    ldrh w9, [sp, #2]                  // ws_col
    add sp, sp, #16
    cbz w9, .Lwtw_fallback3
    mov x0, x9
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwtw_fallback2:
    add sp, sp, #16
.Lwtw_fallback3:
.Lwtw_fallback:
    mov x0, #80
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_strcpy(dst, src) — copy a NUL-terminated string; returns dst.
// ============================================================================
    .p2align 2
watch_strcpy:
    mov x2, x0
.Lwscp_loop:
    ldrb w3, [x1], #1
    strb w3, [x2], #1
    cbnz w3, .Lwscp_loop
    mov x0, x2
    ret

// ============================================================================
// watch_clip(text, width) -> x0 = clipped text ptr (tc_watch_clipbuf when
//   clipped, else the original).  Python clip (3439-3459).
// ============================================================================
    .p2align 2
watch_clip:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    mov x19, x0                        // text
    mov x20, x1                        // width
    // text length (Python walks `index < len(text)`; x27 survives calls)
    mov x0, x19
    bl tc_strlen
    mov x27, x0
    // visible width
    mov x0, x19
    bl watch_visible_width
    cmp x0, x20
    b.le .Lwcl_ret                     // fits: return the original
    // walk
    adrp x21, PAGE(tc_watch_clipbuf)
    add x21, x21, LO12(tc_watch_clipbuf)
    mov x22, x21                       // out cursor
    mov x23, #0                        // shown
    mov x24, #0                        // index
    mov x25, #0                        // has_escape
.Lwcl_loop:
    cmp x24, x27                       // index < len(text)
    b.ge .Lwcl_done
    cmp x23, x20                       // shown < width
    b.ge .Lwcl_done
    // ANSI match at index?
    mov x0, x19
    mov x1, x24
    bl watch_ansi_match                // x0 = match len or 0
    cbz x0, .Lwcl_char
    mov x26, x0
    mov x0, x22
    add x1, x19, x24
    mov x2, x26
    bl watch_copy_to
    mov x22, x0
    add x24, x24, x26
    mov x25, #1
    b .Lwcl_loop
.Lwcl_char:
    ldrb w9, [x19, x24]
    strb w9, [x22], #1
    // continuation bytes are copied but do not consume a column
    cmp w9, #0x80
    b.lt .Lwcl_shown
    cmp w9, #0xC0
    b.lt .Lwcl_skip
.Lwcl_shown:
    add x23, x23, #1
.Lwcl_skip:
    add x24, x24, #1
    b .Lwcl_loop
.Lwcl_done:
    // append ANSI_RESET when the text had an escape
    cbz x25, .Lwcl_nul
    mov x0, x22
    adrp x1, PAGE(s_reset)
    add x1, x1, LO12(s_reset)
    bl wc_cat
    mov x22, x0
.Lwcl_nul:
    mov w9, #0
    strb w9, [x22]
    mov x0, x21
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lwcl_ret:
    mov x0, x19
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_visible_width(text) -> x0 = chars outside ANSI escapes.
// ============================================================================
    .p2align 2
watch_visible_width:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                        // text
    mov x0, x19
    bl tc_strlen
    mov x20, x0                        // len
    mov x9, #0                         // i
    mov x10, #0                        // shown
.Lwvw_loop:
    cmp x9, x20
    b.ge .Lwvw_done
    mov x0, x19
    mov x1, x9
    bl watch_ansi_match
    cbz x0, .Lwvw_char
    add x9, x9, x0
    b .Lwvw_loop
.Lwvw_char:
    // Python's visible_width counts characters, and the terminal renders a
    // multibyte char as one column — a UTF-8 continuation byte (0x80..0xBF)
    // must not add a column.
    ldrb w11, [x19, x9]
    cmp w11, #0x80
    b.lt .Lwvw_count
    cmp w11, #0xC0
    b.lt .Lwvw_next
.Lwvw_count:
    add x10, x10, #1
.Lwvw_next:
    add x9, x9, #1
    b .Lwvw_loop
.Lwvw_done:
    mov x0, x10
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// watch_ansi_match(text, pos) -> x0 = length of an ANSI_RE match at pos
//   (\033\[[0-9;?]*[A-Za-z]) or 0.
// ============================================================================
    .p2align 2
watch_ansi_match:
    stp x29, x30, [sp, #-16]!
    add x0, x0, x1                     // scan from pos, not the buffer head
    ldrb w1, [x0]
    cmp w1, #0x1B
    b.ne .Lwam_none
    ldrb w1, [x0, #1]
    cmp w1, #'['
    b.ne .Lwam_none
    mov x2, #2                        // offset
.Lwam_scan:
    ldrb w1, [x0, x2]
    cbz w1, .Lwam_none
    cmp w1, #'0'
    b.lt .Lwam_check
    cmp w1, #'9'
    b.le .Lwam_next
    cmp w1, #';'
    b.eq .Lwam_next
    cmp w1, #'?'
    b.ne .Lwam_check
    b .Lwam_next
.Lwam_check:
    // must be a letter [A-Za-z]
    cmp w1, #'A'
    b.lt .Lwam_none
    cmp w1, #'Z'
    b.le .Lwam_yes
    cmp w1, #'a'
    b.lt .Lwam_none
    cmp w1, #'z'
    b.gt .Lwam_none
.Lwam_yes:
    add x0, x2, #1
    ldp x29, x30, [sp], #16
    ret
.Lwam_next:
    add x2, x2, #1
    b .Lwam_scan
.Lwam_none:
    mov x0, #0
    ldp x29, x30, [sp], #16
    ret
    .text

    .text

    .text

    RODATA
s_watch_fade_curve: .asciz "watch.fade_curve "
s_shades_too_large: .asciz "watch.shades too large (max 64)"
s_key_min_interval: .asciz "min_interval"
s_key_replay_steps: .asciz "replay_steps"
s_key_full_repaint: .asciz "full_repaint"
s_key_tint_falling: .asciz "tint_falling"
    .text

    .text
    .text
    .text
    .text
    .text
    .text
    .text
    .text
    .text

    RODATA
    .text
