// ============================================================================
// twitch-counts.S — count Chatterino chat messages per user for a channel
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    plain `ld` (no CRT, no libc, pure syscalls)
//
//  Behavior
//  --------
//    A faithful port of the Python program twitch-counts.py (the subset this
//    file documents).  It scans Chatterino's per-day log files
//
//        <logs-dir>/<channel>/<channel>-YYYY-MM-DD.log
//
//    for a channel and time range, and prints one line per user: how many
//    messages they sent, with optional per-state columns (live/offline/
//    unknown), an optional state filter, exclusions, a row cap, and a
//    provenance header naming the source of every setting.  Pure syscalls:
//    the only kernel services used are openat, getdents64, read, write,
//    ioctl (terminal height) and clock_gettime (the "now" for a default
//    --end).
//
//    CLI (getopt-style; `--flag value`, `--flag=value`, `-f value` and
//    `-fvalue` are all accepted):
//
//        -c, --channel NAME        required
//        -d, --logs-dir DIR        required
//        -b, --begin DATETIME      start of the range
//        -S, --since DURATION      start the range this long before --end
//        -e, --end DATETIME        end of the range (default: now)
//        -m, --min-count N         only report users with >= N messages (default 1)
//        -n, --top N               show at most N rows; 0 = unlimited
//        -x, --exclude LOGIN[,...] repeatable, additive
//            --include LOGIN[,...] remove those logins from the exclusions
//            --no-exclude          clear all exclusions
//            --exclude-broadcaster exclude the channel's own account
//        -L, --live  / -O, --offline / -U, --unknown   (mutually exclusive)
//        -B, --by-state            add live, offline, offline% columns
//            --show COL[,...]      add metric columns
//            --sort METRIC         count (default), login, live, offline,
//                                  unknown, offline-share, live-share
//            --share-floor N       messages needed when a share is shown (default 10)
//            --header full|compact|none   (default full)
//        -h, --help                help to stdout, exit 0
//
//    Anything else prints `usage: twitch-counts [options]` plus the flag list
//    to stderr and exits 1.
//
//  Algorithm
//  ---------
//    Phase 1  Parse argv into an options block (.bss).  Values that fail
//             conversion (bad -m/-n/--share-floor/--show/--sort/--header,
//             unknown flags, mutual-exclusion violations) fail here.
//    Phase 2  Resolve the channel: openat the logs dir, getdents64 it, keep
//             the subdirectory names, sort them, and find the one whose
//             lowercase name equals the lowercased --channel.
//    Phase 3  Resolve the window: parse --end (or clock_gettime for now,
//             converted with civil_from_days), then --begin / --since
//             (end - delta) / the earliest dated log file.  All datetimes are
//             held internally as (ymd integer, seconds-of-day), compared by
//             ymd then sod.
//    Phase 4  Seed the stream state: walk back at most 30 files whose date
//             precedes begin.date(), newest first, and take the LAST live/
//             offline marker found in the first such file that has any.
//    Phase 5  Count: for each in-range file (begin.date <= date <= end.date),
//             read it whole (8 MiB cap), and fold every line.  Markers set
//             the current stream state; messages are clipped to the file's
//             [lo, hi] seconds-of-day and bucketed per (login, state).  The
//             user table is a fixed array of 4096 records; excluded logins
//             are dropped from the totals afterwards.
//    Phase 6  Rank and present: filter by --min-count, order by the chosen
//             metric, apply the share floor, cap rows, and render the header
//             + table + footer.  Counts get thousands separators ("1,234").
//
//  Register roles
//  --------------
//    Parse loop:  x19 = argc, x20 = argv, x21 = argv index, x22 = current
//                 argument, x24 = current option value, x25 = short-option
//                 scan pointer.
//    process_lines:  x19 = line ptr, x20 = end of buffer, x21 = lo,
//                    x22 = hi, x23 = stream state, x24 = line start,
//                    x25 = scan pointer (line end), x26 = line length.
//    process_message:  x19 = line, x20 = len, x21 = lo, x22 = hi,
//                      x23 = state, x24 = login ptr, x25 = login len.
//    x0..x17 = subroutine scratch (our helpers never touch x19..x28).
//    x8   = syscall number        x30 = link register
//
//  Linux AArch64 syscall ABI
//  -------------------------
//    * Invoke with `svc #0`; the syscall number goes in x8.
//    * Arguments in x0..x5; the return value comes back in x0 (negative
//      errno on failure).
//    * The kernel preserves all registers except x0.
//
//    clock_gettime(clockid, timespec) -> x8 = 113, x0 = clockid, x1 = &ts
//    ioctl(fd, TIOCGWINSZ, &ws)       -> x8 = 29,  x0 = fd, x1 = 0x5413, x2 = &ws
//    openat(dirfd, path, flags)       -> x8 = 56,  x0 = dirfd (or -100), x1 = path, x2 = flags
//    close(fd)                        -> x8 = 57,  x0 = fd
//    getdents64(fd, buf, count)       -> x8 = 61,  x0 = fd, x1 = buf, x2 = count
//    read(fd, buf, count)             -> x8 = 63,  x0 = fd, x1 = buf, x2 = count
//    write(fd, buf, count)            -> x8 = 64,  x0 = fd, x1 = buf, x2 = count
//    exit(status)                     -> x8 = 93,  x0 = status
//
//    stdout = fd 1, stderr = fd 2, AT_FDCWD = -100, O_RDONLY = 0.
//
//  Deviations from twitch-counts.py (documented; everything else matches)
//  ---------------------------------------------------------------------
//    * No config file, no TWITCH_* environment variables: settings resolve
//      CLI flag -> built-in default, and the header's [source] tags reflect
//      exactly those two layers.
//    * No --watch, --json, --users/--users-policy/--users-max, --manual,
//      --emit-fish-completions, --complete, --color, no rollup cache, no
//      highlight rules / ANSI tints.
//    * "now" and --since resolve in UTC, not local time (no TZif parsing).
//    * Shares are rounded half-up in integer math instead of Python's
//      float %.1f (half-even).
//    * Unknown flags, bad values and conflicting flags exit 1 (argparse
//      exits 2), and error messages omit the "--flag: " prefix Python's
//      convert() adds; the datetime/duration/column choice lists are the
//      short ones this port documents, without Python's ISO-week hints.
//    * --show accepts live, offline, unknown, offline-share, live-share
//      only ("count" is implicit and rejected like any other unknown name).
//    * Non-padded datetimes ("2026-9-1") and ISO week dates are not
//      accepted; "YYYY-MM-DD HH" (hour only) is.
//    * \r\n is treated as \n (Python leaves the \r on the line).
//    * Fixed caps: 4096 users, 4096 log files, 512 excluded logins,
//      64 unreadable files, 8 MiB per log file, 512 entries in the
//      logs-directory listing, 25-char logins, 64-char channel arguments.
// ============================================================================

    .arch armv8-a
    .text
    .global _start

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ SYS_IOCTL,         29        // Linux AArch64 syscall: ioctl
    .equ SYS_OPENAT,        56        // Linux AArch64 syscall: openat
    .equ SYS_CLOSE,         57        // Linux AArch64 syscall: close
    .equ SYS_GETDENTS64,    61        // Linux AArch64 syscall: getdents64
    .equ SYS_READ,          63        // Linux AArch64 syscall: read
    .equ SYS_WRITE,         64        // Linux AArch64 syscall: write
    .equ SYS_EXIT,          93        // Linux AArch64 syscall: exit
    .equ SYS_CLOCK_GETTIME, 113       // Linux AArch64 syscall: clock_gettime

    .equ AT_FDCWD,          -100      // openat: resolve the path from cwd
    .equ O_RDONLY,          0         // openat flags
    .equ TIOCGWINSZ,        0x5413    // ioctl request: terminal window size
    .equ STDOUT,            1
    .equ STDERR,            2
    .equ CLOCK_REALTIME,    0

    .equ DT_DIR,            4         // getdents64 d_type: directory
    .equ DT_REG,            8         // getdents64 d_type: regular file

    .equ MAX_USERS,         4096      // user-table capacity
    .equ USER_STRIDE,       64        // login[26] pad[6] live u64 off u64 unk u64 pad[8]
    .equ MAX_FILES,         4096      // log-file-table capacity
    .equ FILE_STRIDE,       128       // ymd u64 pad[8] name[120]
    .equ MAX_EXCLUDED,      512       // exclusion-set capacity
    .equ EXCL_STRIDE,       32        // login[31] + NUL
    .equ MAX_UNREADABLE,    64        // unreadable-file list capacity
    .equ MAX_DNAMES,        512       // logs-dir listing capacity
    .equ FILE_CAP,          8388608   // 8 MiB per log file
    .equ FILE_CAP_PLUS1,    8388609   // one more byte detects "file too large"
    .equ SEED_LOOKBACK,     30        // files walked back for the entering state
    .equ MIN_ADAPTIVE_ROWS, 5         // floor for the terminal-height row cap
    .equ DEFAULT_MIN_COUNT, 1
    .equ DEFAULT_SHARE_FLOOR, 10
    .equ LAST_SECOND,       86399     // 23:59:59 as seconds-of-day
    .equ SECS_PER_HOUR,     3600
    .equ SECS_PER_DAY,      86400

    .equ ST_LIVE,           1         // stream-state ids
    .equ ST_OFF,            2
    .equ ST_UNK,            3

    .equ S_COUNT,           0         // sort / column ids
    .equ S_LOGIN,           1
    .equ S_LIVE,            2
    .equ S_OFF,             3
    .equ S_UNK,             4
    .equ S_OFFSHARE,        5
    .equ S_LIVESHARE,       6

    .equ F_BY_STATE,        1         // option flags
    .equ F_BROADCASTER,     2
    .equ F_NO_EXCLUDE,      4
    .equ F_TOP_GIVEN,       8
    .equ F_FLOOR_GIVEN,     16
    .equ F_END_GIVEN,       32
    .equ F_SINCE_GIVEN,     64
    .equ F_BEGIN_GIVEN,     128
    .equ F_X_GIVEN,         256
    .equ F_INCLUDE_GIVEN,   512
    .equ F_MIN_GIVEN,       1024      // -m / --min-count was passed
    .equ F_SORT_GIVEN,      2048      // --sort was passed

    .equ H_FULL,            0         // header modes
    .equ H_COMPACT,         1
    .equ H_NONE,            2

    .equ MAX_HEADER_ROWS,   16        // provenance rows
    .equ HROW_STRIDE,       32        // {label, value, source, compact} pointers
    .equ HVALUE_SIZE,       512       // per-row value buffer
    .equ HCOMPACT_SIZE,     256       // per-row compact buffer

    .equ R_CANNOT_READ,     0         // unreadable reasons
    .equ R_TOO_LARGE,       1

    .equ SRC_NONE,          0         // header source ids (for the limit row)
    .equ SRC_TOP,           1
    .equ SRC_TERMINAL,      2

// ----------------------------------------------------------------------------
// _start — entry point.  Linux provides, with no CRT:
//     sp       -> argc
//     [sp + 8] -> argv[0] ... [sp + 8*argc] -> NULL
// ----------------------------------------------------------------------------
_start:
    ldr x19, [sp]                    // x19 = argc
    add x20, sp, #8                  // x20 = argv
    bl init_opts                     // defaults into the options block

    mov x21, #1                      // x21 = argv index

// ---- Parse the command line (getopt-style). -------------------------------
parse_loop:
    cmp x21, x19
    b.ge parse_done
    ldr x22, [x20, x21, lsl #3]      // x22 = argv[i]
    add x21, x21, #1
    ldrb w3, [x22]
    cmp w3, #'-'
    b.ne usage_exit                  // positional argument -> usage, exit 1
    ldrb w3, [x22, #1]
    cbz w3, usage_exit               // a lone "-" is not an option
    cmp w3, #'-'
    b.eq parse_long
    b parse_short

// ---- Long options: --name, --name=value, --name value ---------------------
parse_long:
    mov x0, x22
    adrp x1, lopt_help
    add x1, x1, :lo12:lopt_help
    bl str_eq
    cbnz x0, do_help

    mov x0, x22
    adrp x1, lopt_channel
    add x1, x1, :lo12:lopt_channel
    bl str_eq
    cbz x0, .Lpl_channel_next
    mov x0, x22
    mov x1, #9                       // length of "--channel"
    bl opt_value                     // x0 = value (consumes next argv if needed)
    mov x24, x0
    adrp x0, channel_arg
    add x0, x0, :lo12:channel_arg
    mov x1, x24
    bl copy_str_64
    b parse_loop
.Lpl_channel_next:

    mov x0, x22
    adrp x1, lopt_logs_dir
    add x1, x1, :lo12:lopt_logs_dir
    bl str_eq
    cbz x0, .Lpl_dir_next
    mov x0, x22
    mov x1, #10                      // "--logs-dir"
    bl opt_value
    mov x24, x0
    adrp x0, logs_dir_arg
    add x0, x0, :lo12:logs_dir_arg
    mov x1, x24
    bl copy_str_512
    b parse_loop
.Lpl_dir_next:

    mov x0, x22
    adrp x1, lopt_begin
    add x1, x1, :lo12:lopt_begin
    bl str_eq
    cbz x0, .Lpl_begin_next
    mov x0, x22
    mov x1, #8                       // "--begin"
    bl opt_value
    mov x24, x0
    adrp x0, begin_arg
    add x0, x0, :lo12:begin_arg
    mov x1, x24
    bl copy_str_64
    ldr x0, =F_BEGIN_GIVEN
    bl set_opt_flag
    b parse_loop
.Lpl_begin_next:

    mov x0, x22
    adrp x1, lopt_since
    add x1, x1, :lo12:lopt_since
    bl str_eq
    cbz x0, .Lpl_since_next
    mov x0, x22
    mov x1, #7                       // "--since"
    bl opt_value
    mov x24, x0
    adrp x0, since_arg
    add x0, x0, :lo12:since_arg
    mov x1, x24
    bl copy_str_64
    ldr x0, =F_SINCE_GIVEN
    bl set_opt_flag
    b parse_loop
.Lpl_since_next:

    mov x0, x22
    adrp x1, lopt_end
    add x1, x1, :lo12:lopt_end
    bl str_eq
    cbz x0, .Lpl_end_next
    mov x0, x22
    mov x1, #5                       // "--end"
    bl opt_value
    mov x24, x0
    adrp x0, end_arg
    add x0, x0, :lo12:end_arg
    mov x1, x24
    bl copy_str_64
    ldr x0, =F_END_GIVEN
    bl set_opt_flag
    b parse_loop
.Lpl_end_next:

    mov x0, x22
    adrp x1, lopt_min_count
    add x1, x1, :lo12:lopt_min_count
    bl str_eq
    cbz x0, .Lpl_min_next
    mov x0, x22
    mov x1, #11                      // "--min-count"
    bl opt_value
    mov x24, x0
    bl parse_min_count
    b parse_loop
.Lpl_min_next:

    mov x0, x22
    adrp x1, lopt_top
    add x1, x1, :lo12:lopt_top
    bl str_eq
    cbz x0, .Lpl_top_next
    mov x0, x22
    mov x1, #5                       // "--top"
    bl opt_value
    mov x24, x0
    bl parse_top
    b parse_loop
.Lpl_top_next:

    mov x0, x22
    adrp x1, lopt_share_floor
    add x1, x1, :lo12:lopt_share_floor
    bl str_eq
    cbz x0, .Lpl_floor_next
    mov x0, x22
    mov x1, #13                      // "--share-floor"
    bl opt_value
    mov x24, x0
    bl parse_share_floor
    b parse_loop
.Lpl_floor_next:

    mov x0, x22
    adrp x1, lopt_exclude
    add x1, x1, :lo12:lopt_exclude
    bl str_eq
    cbz x0, .Lpl_excl_next
    mov x0, x22
    mov x1, #9                       // "--exclude"
    bl opt_value
    mov x24, x0
    bl add_exclude_value
    b parse_loop
.Lpl_excl_next:

    mov x0, x22
    adrp x1, lopt_include
    add x1, x1, :lo12:lopt_include
    bl str_eq
    cbz x0, .Lpl_inc_next
    mov x0, x22
    mov x1, #9                       // "--include"
    bl opt_value
    mov x24, x0
    bl add_include_value
    b parse_loop
.Lpl_inc_next:

    mov x0, x22
    adrp x1, lopt_no_exclude
    add x1, x1, :lo12:lopt_no_exclude
    bl str_eq
    cbz x0, .Lpl_noexcl_next
    ldr x0, =F_NO_EXCLUDE
    bl set_opt_flag
    b parse_loop
.Lpl_noexcl_next:

    mov x0, x22
    adrp x1, lopt_broadcaster
    add x1, x1, :lo12:lopt_broadcaster
    bl str_eq
    cbz x0, .Lpl_bcast_next
    ldr x0, =F_BROADCASTER
    bl set_opt_flag
    b parse_loop
.Lpl_bcast_next:

    mov x0, x22
    adrp x1, lopt_by_state
    add x1, x1, :lo12:lopt_by_state
    bl str_eq
    cbz x0, .Lpl_bystate_next
    ldr x0, =F_BY_STATE
    bl set_opt_flag
    b parse_loop
.Lpl_bystate_next:

    mov x0, x22
    adrp x1, lopt_live
    add x1, x1, :lo12:lopt_live
    bl str_eq
    cbz x0, .Lpl_live_next
    mov x0, #ST_LIVE
    bl set_state_filter
    b parse_loop
.Lpl_live_next:

    mov x0, x22
    adrp x1, lopt_offline
    add x1, x1, :lo12:lopt_offline
    bl str_eq
    cbz x0, .Lpl_off_next
    mov x0, #ST_OFF
    bl set_state_filter
    b parse_loop
.Lpl_off_next:

    mov x0, x22
    adrp x1, lopt_unknown
    add x1, x1, :lo12:lopt_unknown
    bl str_eq
    cbz x0, .Lpl_unk_next
    mov x0, #ST_UNK
    bl set_state_filter
    b parse_loop
.Lpl_unk_next:

    mov x0, x22
    adrp x1, lopt_show
    add x1, x1, :lo12:lopt_show
    bl str_eq
    cbz x0, .Lpl_show_next
    mov x0, x22
    mov x1, #6                       // "--show"
    bl opt_value
    mov x24, x0
    bl parse_show
    b parse_loop
.Lpl_show_next:

    mov x0, x22
    adrp x1, lopt_sort
    add x1, x1, :lo12:lopt_sort
    bl str_eq
    cbz x0, .Lpl_sort_next
    mov x0, x22
    mov x1, #6                       // "--sort"
    bl opt_value
    mov x24, x0
    bl parse_sort
    b parse_loop
.Lpl_sort_next:

    mov x0, x22
    adrp x1, lopt_header
    add x1, x1, :lo12:lopt_header
    bl str_eq
    cbz x0, .Lpl_header_next
    mov x0, x22
    mov x1, #8                       // "--header"
    bl opt_value
    mov x24, x0
    bl parse_header_mode
    b parse_loop
.Lpl_header_next:

    b usage_exit                     // any other --xxx -> usage, exit 1

// ---- Short options: clusters like -LB, and -fvalue / -f value -------------
parse_short:
    mov x25, x22
    add x25, x25, #1                 // x25 = scan pointer into the cluster
short_loop:
    ldrb w3, [x25]
    cbz w3, parse_loop               // end of the cluster -> next argv
    cmp w3, #'c'
    b.eq short_channel
    cmp w3, #'d'
    b.eq short_dir
    cmp w3, #'b'
    b.eq short_begin
    cmp w3, #'S'
    b.eq short_since
    cmp w3, #'e'
    b.eq short_end
    cmp w3, #'m'
    b.eq short_min
    cmp w3, #'n'
    b.eq short_top
    cmp w3, #'x'
    b.eq short_excl
    cmp w3, #'L'
    b.eq short_live
    cmp w3, #'O'
    b.eq short_off
    cmp w3, #'U'
    b.eq short_unk
    cmp w3, #'B'
    b.eq short_bystate
    cmp w3, #'h'
    b.eq do_help
    b usage_exit

// short_value — value = the rest of the cluster, or the next argv
short_value:
    ldrb w4, [x25, #1]
    cbz w4, .Lsv_next
    add x0, x25, #1
    ret
.Lsv_next:
    cmp x21, x19
    b.ge usage_exit
    ldr x0, [x20, x21, lsl #3]
    add x21, x21, #1
    ret

short_channel:
    bl short_value
    mov x24, x0
    adrp x0, channel_arg
    add x0, x0, :lo12:channel_arg
    mov x1, x24
    bl copy_str_64
    b parse_loop

short_dir:
    bl short_value
    mov x24, x0
    adrp x0, logs_dir_arg
    add x0, x0, :lo12:logs_dir_arg
    mov x1, x24
    bl copy_str_512
    b parse_loop

short_begin:
    bl short_value
    mov x24, x0
    adrp x0, begin_arg
    add x0, x0, :lo12:begin_arg
    mov x1, x24
    bl copy_str_64
    ldr x0, =F_BEGIN_GIVEN
    bl set_opt_flag
    b parse_loop

short_since:
    bl short_value
    mov x24, x0
    adrp x0, since_arg
    add x0, x0, :lo12:since_arg
    mov x1, x24
    bl copy_str_64
    ldr x0, =F_SINCE_GIVEN
    bl set_opt_flag
    b parse_loop

short_end:
    bl short_value
    mov x24, x0
    adrp x0, end_arg
    add x0, x0, :lo12:end_arg
    mov x1, x24
    bl copy_str_64
    ldr x0, =F_END_GIVEN
    bl set_opt_flag
    b parse_loop

short_min:
    bl short_value
    mov x24, x0
    bl parse_min_count
    b parse_loop

short_top:
    bl short_value
    mov x24, x0
    bl parse_top
    b parse_loop

short_excl:
    bl short_value
    mov x24, x0
    bl add_exclude_value
    b parse_loop

short_live:
    add x25, x25, #1
    mov x0, #ST_LIVE
    bl set_state_filter
    b short_loop

short_off:
    add x25, x25, #1
    mov x0, #ST_OFF
    bl set_state_filter
    b short_loop

short_unk:
    add x25, x25, #1
    mov x0, #ST_UNK
    bl set_state_filter
    b short_loop

short_bystate:
    add x25, x25, #1
    ldr x0, =F_BY_STATE
    bl set_opt_flag
    b short_loop

do_help:
    mov x0, #STDOUT
    adrp x1, help_text
    add x1, x1, :lo12:help_text
    bl print_cstr
    b exit_ok

parse_done:
    // --begin and --since are mutually exclusive (checked here, at parse time)
    adrp x0, opt_flags
    add x0, x0, :lo12:opt_flags
    ldr x0, [x0]
    and x1, x0, #(F_BEGIN_GIVEN | F_SINCE_GIVEN)
    cmp x1, #(F_BEGIN_GIVEN | F_SINCE_GIVEN)
    b.ne .Lpd_begin_ok
    adrp x1, err_begin_since
    add x1, x1, :lo12:err_begin_since
    bl fail
.Lpd_begin_ok:

    // channel presence
    adrp x0, channel_arg
    add x0, x0, :lo12:channel_arg
    ldrb w1, [x0]
    cbnz w1, .Lpd_channel_ok
    adrp x1, err_no_channel
    add x1, x1, :lo12:err_no_channel
    bl fail
.Lpd_channel_ok:

    // logs-dir presence
    adrp x0, logs_dir_arg
    add x0, x0, :lo12:logs_dir_arg
    ldrb w1, [x0]
    cbnz w1, .Lpd_dir_ok
    adrp x1, err_no_logs_dir
    add x1, x1, :lo12:err_no_logs_dir
    mov x0, #STDERR
    bl print_cstr
    adrp x1, hint_logs_dir
    add x1, x1, :lo12:hint_logs_dir
    bl fail
.Lpd_dir_ok:

    // ---- resolve the channel directory ------------------------------------
    bl resolve_channel_dir          // fills channel_name / channel_dir_path / channel_dirfd

    // ---- exclusions: conflict check, then the --include subtraction --------
    bl build_exclusions

    // ---- list the channel's dated log files (also used for the default begin)
    bl list_log_files

    // ---- resolve the window ------------------------------------------------
    bl resolve_window

    // ---- count and report --------------------------------------------------
    bl count_all
    bl build_report_data
    bl render_report
    b exit_ok

// ----------------------------------------------------------------------------
// init_opts — defaults for the options block (bss is already zeroed).
// ----------------------------------------------------------------------------
init_opts:
    adrp x0, min_count
    mov x1, #DEFAULT_MIN_COUNT
    add x0, x0, :lo12:min_count
    str x1, [x0]
    adrp x0, share_floor
    mov x1, #DEFAULT_SHARE_FLOOR
    add x0, x0, :lo12:share_floor
    str x1, [x0]
    ret

// ----------------------------------------------------------------------------
// Small helpers
// ----------------------------------------------------------------------------

// cstr_len(x0=ptr) -> x0 = length (excluding the NUL)
cstr_len:
    mov x1, #0
.Lcl:
    ldrb w2, [x0, x1]
    cbz w2, .Lcl_done
    add x1, x1, #1
    b .Lcl
.Lcl_done:
    mov x0, x1
    ret

// str_eq(x0=a, x1=b) -> x0 = 1 if the two NUL-terminated strings are equal
str_eq:
    mov x2, #0
.Lse:
    ldrb w3, [x0, x2]
    ldrb w4, [x1, x2]
    cmp w3, w4
    b.ne .Lse_no
    cbz w3, .Lse_yes
    add x2, x2, #1
    b .Lse
.Lse_yes:
    mov x0, #1
    ret
.Lse_no:
    mov x0, #0
    ret

// strcmp(x0=a, x1=b) -> x0 = -1, 0, 1 (byte order)
strcmp:
    mov x2, #0
.Lsc:
    ldrb w3, [x0, x2]
    ldrb w4, [x1, x2]
    cmp w3, w4
    b.lt .Lsc_lt
    b.gt .Lsc_gt
    cbz w3, .Lsc_eq
    add x2, x2, #1
    b .Lsc
.Lsc_lt:
    mov x0, #-1
    ret
.Lsc_gt:
    mov x0, #1
    ret
.Lsc_eq:
    mov x0, #0
    ret

// write_all(x0=fd, x1=buf, x2=len) — loop until every byte is written
write_all:
    mov x3, x0
    mov x4, x1
    mov x5, x2
.Lwa:
    cbz x5, .Lwa_done
    mov x0, x3
    mov x1, x4
    mov x2, x5
    mov x8, #SYS_WRITE
    svc #0
    cmp x0, #0
    b.le .Lwa_done                 // error or zero: give up best-effort
    add x4, x4, x0
    sub x5, x5, x0
    b .Lwa
.Lwa_done:
    ret

// print_cstr(x0=fd, x1=ptr) — write a NUL-terminated string
print_cstr:
    stp x0, x1, [sp, #-16]!          // fd, ptr
    stp x30, xzr, [sp, #-16]!        // save lr (cstr_len below clobbers it)
    mov x0, x1
    bl cstr_len
    mov x2, x0
    ldr x0, [sp, #16]                // fd
    ldr x1, [sp, #24]                // buf
    bl write_all
    ldp x30, xzr, [sp], #16          // pop the lr pair
    add sp, sp, #16                  // pop the fd/ptr pair
    ret

// write_n(x0=fd, x1=ptr, x2=len) — write exactly len bytes
write_n:
    b write_all

// fail(x1=msg) — write msg to stderr and exit 1
fail:
    stp x0, x30, [sp, #-16]!
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

// usage_exit — the usage line plus the flag list to stderr, exit 1
usage_exit:
    mov x0, #STDERR
    adrp x1, help_text
    add x1, x1, :lo12:help_text
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

exit_ok:
    mov x0, #0
    mov x8, #SYS_EXIT
    svc #0

// copy_str_64(x0=dst, x1=src) — copy at most 63 chars + NUL
copy_str_64:
    mov x2, #0
.Lcs:
    cmp x2, #63
    b.ge .Lcs_done
    ldrb w3, [x1, x2]
    strb w3, [x0, x2]
    cbz w3, .Lcs_done
    add x2, x2, #1
    b .Lcs
.Lcs_done:
    mov w3, #0
    strb w3, [x0, x2]
    ret

// copy_str_512(x0=dst, x1=src) — copy at most 511 chars + NUL
copy_str_512:
    mov x2, #0
.Lc5:
    cmp x2, #511
    b.ge .Lc5_done
    ldrb w3, [x1, x2]
    strb w3, [x0, x2]
    cbz w3, .Lc5_done
    add x2, x2, #1
    b .Lc5
.Lc5_done:
    mov w3, #0
    strb w3, [x0, x2]
    ret

// set_opt_flag(x0=bit)
set_opt_flag:
    adrp x1, opt_flags
    add x1, x1, :lo12:opt_flags
    ldr x2, [x1]
    orr x2, x2, x0
    str x2, [x1]
    ret

// opt_value(x0=arg, x1=name_len) -> x0 = value pointer; consumes the next argv
// when the value is not attached with '='.  Advances the global x21.
opt_value:
    ldrb w2, [x0, x1]
    cmp w2, #'='
    b.eq .Lov_eq
    cmp x21, x19
    b.ge usage_exit
    ldr x3, [x20, x21, lsl #3]
    add x21, x21, #1
    mov x0, x3
    ret
.Lov_eq:
    add x0, x0, x1
    add x0, x0, #1
    ret

// parse_int(x0=ptr) -> x0 = signed value, x1 = ok (1/0).  Accepts leading/
// trailing spaces and a leading '+'/'-'.  Overflow is rejected.
parse_int:
    mov x2, x0                       // scan pointer
    mov x3, #0                       // magnitude
    mov x4, #0                       // neg flag
    mov x9, #0                       // digit count (empty-string rejection)
.Lpi_sp:
    ldrb w5, [x2]
    cmp w5, #' '
    b.ne .Lpi_sign
    add x2, x2, #1
    b .Lpi_sp
.Lpi_sign:
    ldrb w5, [x2]
    cmp w5, #'-'
    b.ne .Lpi_plus
    mov x4, #1
    add x2, x2, #1
    b .Lpi_loop
.Lpi_plus:
    cmp w5, #'+'
    b.ne .Lpi_loop
    add x2, x2, #1
.Lpi_loop:
    ldrb w6, [x2]
    cbz w6, .Lpi_check
    cmp w6, #' '
    b.eq .Lpi_space
    sub w6, w6, #'0'
    cmp w6, #9
    b.hi .Lpi_bad
    mov x7, #10
    umulh x8, x3, x7
    cbnz x8, .Lpi_bad
    mul x3, x3, x7
    adds x3, x3, x6
    b.cs .Lpi_bad
    add x9, x9, #1                   // one more digit
    add x2, x2, #1
    b .Lpi_loop
.Lpi_space:
    add x2, x2, #1
    ldrb w6, [x2]
    cmp w6, #' '
    b.eq .Lpi_space
    cbnz w6, .Lpi_bad
.Lpi_check:
    cbz x9, .Lpi_bad                 // no digits at all -> invalid
    cbz x4, .Lpi_pos
    neg x3, x3
.Lpi_pos:
    mov x0, x3
    mov x1, #1
    ret
.Lpi_bad:
    mov x0, #0
    mov x1, #0
    ret

// not_int_err — "error: '<raw>' is not an integer\n" then exit 1 (x24 = raw)
not_int_err:
    adrp x1, err_not_int_pre
    add x1, x1, :lo12:err_not_int_pre
    mov x0, #STDERR
    bl print_cstr
    mov x0, #STDERR
    mov x1, x24
    bl print_cstr
    adrp x1, err_not_int_mid
    add x1, x1, :lo12:err_not_int_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

// parse_min_count(x24=raw) — positive integer, default context
parse_min_count:
    stp x30, xzr, [sp, #-16]!
    mov x0, x24
    bl parse_int
    cbz x1, not_int_err
    cmp x0, #1
    b.lt .Lpmc_ge1
    adrp x1, min_count
    add x1, x1, :lo12:min_count
    str x0, [x1]
    ldr x0, =F_MIN_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpmc_ge1:
    adrp x1, err_must_ge1
    add x1, x1, :lo12:err_must_ge1
    bl fail

// parse_top(x24=raw) — nonnegative integer, sets F_TOP_GIVEN
parse_top:
    stp x30, xzr, [sp, #-16]!
    mov x0, x24
    bl parse_int
    cbz x1, not_int_err
    cmp x0, #0
    b.lt .Lpt_rowlimit
    adrp x1, top_n
    add x1, x1, :lo12:top_n
    str x0, [x1]
    ldr x0, =F_TOP_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpt_rowlimit:
    adrp x1, err_rowlimit
    add x1, x1, :lo12:err_rowlimit
    bl fail

// parse_share_floor(x24=raw) — nonnegative integer, sets F_FLOOR_GIVEN
parse_share_floor:
    stp x30, xzr, [sp, #-16]!
    mov x0, x24
    bl parse_int
    cbz x1, not_int_err
    cmp x0, #0
    b.lt .Lpsf_rowlimit
    adrp x1, share_floor
    add x1, x1, :lo12:share_floor
    str x0, [x1]
    ldr x0, =F_FLOOR_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsf_rowlimit:
    adrp x1, err_rowlimit
    add x1, x1, :lo12:err_rowlimit
    bl fail// ============================================================================
// Part 2 — calendar math, datetime/duration parsing, epoch conversion
// ============================================================================

// ----------------------------------------------------------------------------
// Calendar math — Howard Hinnant's days_from_civil / civil_from_days, which
// convert between (y, mo, d) and a day count relative to 1970-01-01.  All
// inputs in this program are modern dates (y >= 1), so the floor divisions
// below are exact for every value that can actually occur.
// ----------------------------------------------------------------------------

// days_from_civil(x0=y, x1=m, x2=d) -> x0 = days since 1970-01-01
days_from_civil:
    cmp x1, #2
    b.gt .Ldfc_adj_done
    sub x0, x0, #1                   // y -= (m <= 2)
.Ldfc_adj_done:
    // era = (y >= 0 ? y : y - 399) / 400   (floor division)
    cmp x0, #0
    b.ge .Ldfc_ypos
    sub x3, x0, #399
    b .Ldfc_era
.Ldfc_ypos:
    mov x3, x0
.Ldfc_era:
    mov x4, #400
    sdiv x3, x3, x4                  // era
    msub x5, x3, x4, x0              // yoe = y - era*400
    // doy = (153*(m + (m > 2 ? -3 : 9)) + 2)/5 + d - 1
    cmp x1, #2
    b.gt .Ldfc_madj
    add x6, x1, #9
    b .Ldfc_doy
.Ldfc_madj:
    sub x6, x1, #3
.Ldfc_doy:
    mov x7, #153
    mul x6, x6, x7
    add x6, x6, #2
    mov x7, #5
    sdiv x6, x6, x7
    add x6, x6, x2
    sub x6, x6, #1                   // doy
    // doe = yoe*365 + yoe/4 - yoe/100 + doy; sdiv is floor for yoe >= 0
    mov x7, #365
    mul x7, x5, x7
    add x7, x7, x6
    mov x9, #4
    sdiv x8, x5, x9                  // yoe/4
    add x7, x7, x8
    mov x9, #100
    sdiv x8, x5, x9                  // yoe/100
    sub x7, x7, x8
    // + era*146097
    ldr x9, =146097
    mul x9, x3, x9
    add x7, x7, x9
    ldr x9, =719468
    sub x0, x7, x9
    ret

// civil_from_days(x0=z) -> x0 = y, x1 = m, x2 = d
civil_from_days:
    ldr x3, =719468
    add x3, x0, x3
    cmp x3, #0
    b.ge .Lcfd_zpos
    ldr x9, =146096
    sub x4, x3, x9
    b .Lcfd_era
.Lcfd_zpos:
    mov x4, x3
.Lcfd_era:
    ldr x5, =146097
    sdiv x4, x4, x5                  // era
    msub x6, x4, x5, x3               // doe = z - era*146097
    // yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    ldr x7, =1460
    sdiv x8, x6, x7
    sub x8, x6, x8
    ldr x7, =36524
    sdiv x9, x6, x7
    add x8, x8, x9
    ldr x7, =146096
    sdiv x9, x6, x7
    sub x8, x8, x9
    mov x7, #365
    sdiv x8, x8, x7                  // yoe
    // y = yoe + era*400
    mov x7, #400
    mul x9, x4, x7
    add x9, x8, x9
    // doy = doe - (365*yoe + yoe/4 - yoe/100); sdiv is floor for yoe >= 0
    mov x7, #365
    mul x10, x8, x7                  // 365*yoe
    sub x10, x6, x10                 // doe - 365*yoe
    mov x7, #4
    sdiv x11, x8, x7                 // yoe/4
    sub x10, x10, x11
    mov x7, #100
    sdiv x11, x8, x7                 // yoe/100
    add x10, x10, x11                // doy
    // mp = (5*doy + 2)/153
    mov x7, #5
    mul x10, x10, x7
    add x10, x10, #2
    mov x7, #153
    sdiv x10, x10, x7                // mp
    // d = doy - (153*mp+2)/5 + 1
    mov x7, #153
    mul x11, x10, x7
    add x11, x11, #2
    mov x7, #5
    sdiv x11, x11, x7
    // recompute doy (the first computation was consumed by mp)
    mov x7, #365
    mul x12, x8, x7                  // 365*yoe
    sub x12, x6, x12                 // doe - 365*yoe
    mov x7, #4
    sdiv x13, x8, x7                 // yoe/4
    sub x12, x12, x13
    mov x7, #100
    sdiv x13, x8, x7                 // yoe/100
    add x12, x12, x13
    sub x12, x12, x11
    add x2, x12, #1                   // d
    // m = mp + (mp < 10 ? 3 : -9)
    cmp x10, #10
    b.ge .Lcfd_mbig
    add x1, x10, #3
    b .Lcfd_mdone
.Lcfd_mbig:
    sub x1, x10, #9
.Lcfd_mdone:
    // y += (m <= 2)
    cmp x1, #2
    b.gt .Lcfd_ret
    add x9, x9, #1
.Lcfd_ret:
    mov x0, x9
    ret

// is_leap(x0=year) -> x0 = 1/0
is_leap:
    mov x1, #4
    sdiv x2, x0, x1
    msub x2, x2, x1, x0
    cbnz x2, .Lil_no
    mov x1, #100
    sdiv x2, x0, x1
    msub x2, x2, x1, x0
    cbnz x2, .Lil_yes
    mov x1, #400
    sdiv x2, x0, x1
    msub x2, x2, x1, x0
    cbnz x2, .Lil_no
.Lil_yes:
    mov x0, #1
    ret
.Lil_no:
    mov x0, #0
    ret

// days_in_month(x0=y, x1=m) -> x0 = days
days_in_month:
    stp x30, xzr, [sp, #-16]!
    cmp x1, #2
    b.eq .Ldim_feb
    adrp x2, month_days
    add x2, x2, :lo12:month_days
    sub x3, x1, #1
    ldrb w0, [x2, x3]
    ldp x30, xzr, [sp], #16
    ret
.Ldim_feb:
    mov x2, x0
    bl is_leap
    cbnz x0, .Ldim_29
    mov x0, #28
    ldp x30, xzr, [sp], #16
    ret
.Ldim_29:
    mov x0, #29
    ldp x30, xzr, [sp], #16
    ret

// ymd_sod_to_epoch(x0=ymd, x1=sod) -> x0 = epoch seconds (UTC)
ymd_sod_to_epoch:
    stp x30, xzr, [sp, #-16]!
    stp x0, x1, [sp, #-16]!          // save ymd and sod
    mov x2, #10000
    udiv x3, x0, x2                  // y
    mov x4, #100
    udiv x5, x0, x4
    msub x5, x5, x4, x0              // d = ymd % 100
    udiv x6, x0, x2
    mul x6, x6, x2
    sub x6, x0, x6                   // ymd % 10000
    udiv x6, x6, x4                  // mo
    mov x0, x3
    mov x1, x6
    mov x2, x5
    bl days_from_civil               // x0 = days
    ldr x1, [sp, #8]                 // sod
    ldr x7, =SECS_PER_DAY
    mul x0, x0, x7
    add x0, x0, x1
    add sp, sp, #16
    ldp x30, xzr, [sp], #16
    ret

// epoch_to_ymd_sod(x0=epoch) -> x0 = ymd, x1 = sod (UTC)
epoch_to_ymd_sod:
    stp x19, x20, [sp, #-16]!
    stp x30, xzr, [sp, #-16]!
    ldr x19, =SECS_PER_DAY
    udiv x20, x0, x19
    msub x5, x20, x19, x0            // sod
    stp x5, xzr, [sp, #-16]!         // civil_from_days clobbers x5
    mov x0, x20
    bl civil_from_days               // x0=y, x1=m, x2=d
    mov x3, #10000
    mul x0, x0, x3
    mov x3, #100
    mul x1, x1, x3
    add x0, x0, x1
    add x0, x0, x2                   // ymd
    ldp x5, xzr, [sp], #16           // restore sod
    mov x1, x5
    ldr x30, [sp]
    add sp, sp, #16
    ldp x19, x20, [sp], #16
    ret

// ----------------------------------------------------------------------------
// Datetime parsing
// ----------------------------------------------------------------------------

// digit_at(x0=str, x1=pos) -> x0 = digit value, or -1 if not a digit
digit_at:
    ldrb w2, [x0, x1]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Lda_bad
    mov x0, x2
    ret
.Lda_bad:
    mov x0, #-1
    ret

// parse_datetime(x0=ptr, x1=end_of_day_if_dateless) -> x0=ymd, x1=sod, x2=ok
//   Accepts YYYY-MM-DD, YYYY-MM-DD HH, YYYY-MM-DD HH:MM, YYYY-MM-DD HH:MM:SS
//   and the '/' separator variants; 'T' may separate the date and time.
parse_datetime:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                       // str
    mov x20, x1                       // end_of_day flag
    bl cstr_len
    mov x21, x0                       // len
    cmp x21, #10
    b.lt .Lpd_fail
    // separators must agree ('-' or '/')
    ldrb w0, [x19, #4]
    cmp w0, #'-'
    b.eq .Lpd_sep_ok
    cmp w0, #'/'
    b.ne .Lpd_fail
.Lpd_sep_ok:
    mov w3, w0                        // sep
    ldrb w4, [x19, #7]
    cmp w4, w3
    b.ne .Lpd_fail
    // year digits 0..3
    mov x0, x19
    mov x1, #0
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x5, x0
    mov x0, x19
    mov x1, #1
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x6, x0
    mov x0, x19
    mov x1, #2
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x7, x0
    mov x0, x19
    mov x1, #3
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x8, x0
    // month digits 5..6
    mov x0, x19
    mov x1, #5
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x11, x0
    mov x0, x19
    mov x1, #6
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x12, x0
    // day digits 8..9
    mov x0, x19
    mov x1, #8
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x13, x0
    mov x0, x19
    mov x1, #9
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x14, x0
    // assemble y, mo, d
    mov x9, #1000
    mul x5, x5, x9
    mov x9, #100
    mul x6, x6, x9
    add x5, x5, x6
    mov x9, #10
    mul x7, x7, x9
    add x5, x5, x7
    add x5, x5, x8                    // y
    mov x9, #10
    mul x11, x11, x9
    add x11, x11, x12                 // mo
    mov x9, #10
    mul x13, x13, x9
    add x13, x13, x14                 // d
    // validate the calendar date
    cbz x5, .Lpd_fail                 // year 0 is not a real date
    cmp x11, #1
    b.lt .Lpd_fail
    cmp x11, #12
    b.gt .Lpd_fail
    cmp x13, #1
    b.lt .Lpd_fail
    mov x0, x5
    mov x1, x11
    stp x5, x11, [sp, #-16]!
    stp x13, x21, [sp, #-16]!
    bl days_in_month
    ldp x13, x21, [sp], #16
    ldp x5, x11, [sp], #16
    cmp x13, x0
    b.gt .Lpd_fail
    // time part
    cmp x21, #10
    b.eq .Lpd_date_only
    cmp x21, #13
    b.eq .Lpd_hour
    cmp x21, #16
    b.eq .Lpd_min
    cmp x21, #19
    b.eq .Lpd_sec
    b .Lpd_fail
.Lpd_date_only:
    mov x15, #0
    mov x16, #0
    mov x17, #0
    b .Lpd_time_done
.Lpd_hour:
    ldrb w0, [x19, #10]
    cmp w0, #' '
    b.eq .Lpd_hour_ok
    cmp w0, #'T'
    b.ne .Lpd_fail
.Lpd_hour_ok:
    mov x0, x19
    mov x1, #11
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x15, x0
    mov x0, x19
    mov x1, #12
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x9, #10
    mul x15, x15, x9
    add x15, x15, x0                  // h
    mov x16, #0
    mov x17, #0
    b .Lpd_time_done
.Lpd_min:
    ldrb w0, [x19, #10]
    cmp w0, #' '
    b.eq .Lpd_min_ok
    cmp w0, #'T'
    b.ne .Lpd_fail
.Lpd_min_ok:
    mov x0, x19
    mov x1, #11
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x15, x0
    mov x0, x19
    mov x1, #12
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x9, #10
    mul x15, x15, x9
    add x15, x15, x0                  // h
    ldrb w0, [x19, #13]
    cmp w0, #':'
    b.ne .Lpd_fail
    mov x0, x19
    mov x1, #14
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x16, x0
    mov x0, x19
    mov x1, #15
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x9, #10
    mul x16, x16, x9
    add x16, x16, x0                  // mi
    mov x17, #0
    b .Lpd_time_done
.Lpd_sec:
    ldrb w0, [x19, #10]
    cmp w0, #' '
    b.eq .Lpd_sec_ok
    cmp w0, #'T'
    b.ne .Lpd_fail
.Lpd_sec_ok:
    mov x0, x19
    mov x1, #11
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x15, x0
    mov x0, x19
    mov x1, #12
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x9, #10
    mul x15, x15, x9
    add x15, x15, x0                  // h
    ldrb w0, [x19, #13]
    cmp w0, #':'
    b.ne .Lpd_fail
    mov x0, x19
    mov x1, #14
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x16, x0
    mov x0, x19
    mov x1, #15
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x9, #10
    mul x16, x16, x9
    add x16, x16, x0                  // mi
    ldrb w0, [x19, #16]
    cmp w0, #':'
    b.ne .Lpd_fail
    mov x0, x19
    mov x1, #17
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x17, x0
    mov x0, x19
    mov x1, #18
    bl digit_at
    cmp x0, #0
    b.lt .Lpd_fail
    mov x9, #10
    mul x17, x17, x9
    add x17, x17, x0                  // s
    b .Lpd_time_done
.Lpd_time_done:
    cmp x15, #23
    b.gt .Lpd_fail
    cmp x16, #59
    b.gt .Lpd_fail
    cmp x17, #59
    b.gt .Lpd_fail
    // a bare date for --end means 23:59:59
    cmp x21, #10
    b.ne .Lpd_sod_done
    cbz x20, .Lpd_sod_done
    mov x15, #23
    mov x16, #59
    mov x17, #59
.Lpd_sod_done:
    // ymd = y*10000 + mo*100 + d
    mov x9, #10000
    mul x5, x5, x9
    mov x9, #100
    mul x11, x11, x9
    add x5, x5, x11
    add x5, x5, x13
    // sod = h*3600 + mi*60 + s
    mov x9, #3600
    mul x15, x15, x9
    mov x9, #60
    mul x16, x16, x9
    add x15, x15, x16
    add x15, x15, x17
    mov x0, x5
    mov x1, x15
    mov x2, #1
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret
.Lpd_fail:
    mov x0, #0
    mov x1, #0
    mov x2, #0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// parse_duration(x0=ptr) -> x0 = seconds, x1 = status
//   status 0 = ok, 1 = unrecognized, 2 = zero
parse_duration:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                       // raw input
    // lowercase the input into a scratch buffer (cstr_len clobbers x2)
    bl cstr_len
    adrp x2, dur_buf
    add x2, x2, :lo12:dur_buf
    mov x3, x0
    mov x4, #0
.Lpdur_lower:
    cmp x4, x3
    b.ge .Lpdur_lower_done
    ldrb w5, [x19, x4]
    cmp w5, #'A'
    b.lt .Lpdur_lstore
    cmp w5, #'Z'
    b.gt .Lpdur_lstore
    add w5, w5, #('a' - 'A')
.Lpdur_lstore:
    strb w5, [x2, x4]
    add x4, x4, #1
    b .Lpdur_lower
.Lpdur_lower_done:
    mov w5, #0
    strb w5, [x2, x4]
    // scan parts: <digits><unit>...
    mov x19, x2                       // scan ptr
    mov x20, #0                       // total seconds
    mov x21, #0                       // part count
.Lpdur_loop:
    ldrb w5, [x19]
    cbz w5, .Lpdur_done
    // digits
    mov x22, #0                       // n
    mov x23, #0                       // digit count
.Lpdur_digits:
    ldrb w6, [x19]
    cbz w6, .Lpdur_bad
    sub w6, w6, #'0'
    cmp w6, #9
    b.hi .Lpdur_unit              // non-digit ends the number: parse the unit
    mov x7, #10
    umulh x8, x22, x7
    cbnz x8, .Lpdur_bad
    mul x22, x22, x7
    adds x22, x22, x6
    b.cs .Lpdur_bad
    add x19, x19, #1
    add x23, x23, #1
    b .Lpdur_digits
.Lpdur_unit:
    ldrb w6, [x19]
    cmp w6, #'w'
    b.eq .Lpdur_mul_w
    cmp w6, #'d'
    b.eq .Lpdur_mul_d
    cmp w6, #'h'
    b.eq .Lpdur_mul_h
    cmp w6, #'m'
    b.eq .Lpdur_mul_m
    cmp w6, #'s'
    b.eq .Lpdur_mul_s
    b .Lpdur_bad
.Lpdur_mul_w:
    ldr x7, =604800
    b .Lpdur_apply
.Lpdur_mul_d:
    ldr x7, =86400
    b .Lpdur_apply
.Lpdur_mul_h:
    mov x7, #3600
    b .Lpdur_apply
.Lpdur_mul_m:
    mov x7, #60
    b .Lpdur_apply
.Lpdur_mul_s:
    mov x7, #1
    b .Lpdur_apply
.Lpdur_apply:
    umulh x8, x22, x7
    cbnz x8, .Lpdur_bad
    mul x22, x22, x7
    add x19, x19, #1
    adds x20, x20, x22
    b.cs .Lpdur_bad
    add x21, x21, #1
    b .Lpdur_loop
.Lpdur_done:
    cbz x21, .Lpdur_bad              // at least one part required
    cbz x20, .Lpdur_zero
    mov x0, x20
    mov x1, #0
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret
.Lpdur_zero:
    mov x0, #0
    mov x1, #2
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret
.Lpdur_bad:
    mov x0, #0
    mov x1, #1
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// ----------------------------------------------------------------------------
// epoch_now — clock_gettime(CLOCK_REALTIME) -> x0 = ymd, x1 = sod (UTC)
// ----------------------------------------------------------------------------
epoch_now:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x0, #CLOCK_REALTIME
    adrp x1, ts_buf
    add x1, x1, :lo12:ts_buf
    mov x8, #SYS_CLOCK_GETTIME
    svc #0
    adrp x1, ts_buf
    add x1, x1, :lo12:ts_buf
    ldr x19, [x1]
    mov x20, x19
    ldr x0, =SECS_PER_DAY
    udiv x19, x19, x0                // days
    msub x20, x19, x0, x20           // sod
    mov x0, x19
    bl civil_from_days               // x0=y, x1=m, x2=d
    mov x3, #10000
    mul x0, x0, x3
    mov x3, #100
    mul x1, x1, x3
    add x0, x0, x1
    add x0, x0, x2                   // ymd
    mov x1, x20
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret// ============================================================================
// Part 3 — exclusion lists, state filter, --show / --sort / --header parsing
// ============================================================================

// is_login_char — sets Z iff w3 is in [A-Za-z0-9_]
is_login_char:
    cmp w3, #'0'
    b.lt .Lilc_no
    cmp w3, #'9'
    b.le .Lilc_yes
    cmp w3, #'A'
    b.lt .Lilc_no
    cmp w3, #'Z'
    b.le .Lilc_yes
    cmp w3, #'_'
    b.eq .Lilc_yes
    cmp w3, #'a'
    b.lt .Lilc_no
    cmp w3, #'z'
    b.le .Lilc_yes
.Lilc_no:
    cmp w3, #-1                      // force Z=0
    ret
.Lilc_yes:
    cmp w3, w3                       // force Z=1
    ret

// is_lower_login_char — like is_login_char but only [a-z0-9_]
is_lower_login_char:
    cmp w3, #'0'
    b.lt .Lillc_no
    cmp w3, #'9'
    b.le .Lillc_yes
    cmp w3, #'_'
    b.eq .Lillc_yes
    cmp w3, #'a'
    b.lt .Lillc_no
    cmp w3, #'z'
    b.le .Lillc_yes
.Lillc_no:
    cmp w3, #-1
    ret
.Lillc_yes:
    cmp w3, w3
    ret

// lower_ascii — copy a token into login_buf, lowercasing ASCII A-Z.
// in: x0 = src, x1 = len (<= 31).  The token is copied verbatim otherwise.
lower_ascii:
    adrp x2, login_buf
    add x2, x2, :lo12:login_buf
    mov x3, #0
.Lla:
    cmp x3, x1
    b.ge .Lla_done
    ldrb w4, [x0, x3]
    cmp w4, #'A'
    b.lt .Lla_store
    cmp w4, #'Z'
    b.gt .Lla_store
    add w4, w4, #('a' - 'A')
.Lla_store:
    strb w4, [x2, x3]
    add x3, x3, #1
    b .Lla
.Lla_done:
    mov w4, #0
    strb w4, [x2, x3]
    ret

// split_names(x0=raw, x1=dest) — split on commas/whitespace, lowercase each
// token, and add each to a destination list.
//   x1 = 0 -> excluded list (tracks x_added), x1 = 1 -> include list
split_names:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x20, x1                      // destination kind, in a callee-saved
                                     // register: include_add/excl_add clobber
                                     // the scratch x6, and the next token's
                                     // `cbz` must still see the kind
    mov x19, x0                      // scan pointer (callee-saved: survives callees)
.Lsn_outer:
    ldrb w3, [x19]
    cbz w3, .Lsn_done
    cmp w3, #','
    b.eq .Lsn_sep
    cmp w3, #' '
    b.eq .Lsn_sep
    cmp w3, #9                       // tab
    b.eq .Lsn_sep
    // start of a token
    mov x4, x19                      // token start
    mov x5, #0                       // token len
.Lsn_token:
    ldrb w3, [x19]
    cbz w3, .Lsn_token_end
    cmp w3, #','
    b.eq .Lsn_token_end
    cmp w3, #' '
    b.eq .Lsn_token_end
    cmp w3, #9
    b.eq .Lsn_token_end
    add x19, x19, #1
    add x5, x5, #1
    cmp x5, #31
    b.lt .Lsn_token
.Lsn_token_end:
    mov x0, x4
    mov x1, x5
    bl lower_ascii
    cbz x20, .Lsn_to_excl
    adrp x0, login_buf
    add x0, x0, :lo12:login_buf
    mov x1, x5
    bl include_add
    b .Lsn_outer
.Lsn_to_excl:
    adrp x0, login_buf
    add x0, x0, :lo12:login_buf
    mov x1, x5
    bl excl_add
    cbz x0, .Lsn_outer
    adrp x2, x_added
    add x2, x2, :lo12:x_added
    ldr x3, [x2]
    add x3, x3, #1
    str x3, [x2]
    b .Lsn_outer
.Lsn_sep:
    add x19, x19, #1
    b .Lsn_outer
.Lsn_done:
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// add_exclude_value(x24=raw) — one -x / --exclude value
add_exclude_value:
    stp x30, xzr, [sp, #-16]!
    mov x0, x24
    mov x1, #0
    bl split_names
    ldr x0, =F_X_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret

// add_include_value(x24=raw) — one --include value
add_include_value:
    stp x30, xzr, [sp, #-16]!
    mov x0, x24
    mov x1, #1
    bl split_names
    ldr x0, =F_INCLUDE_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret

// excl_add(x0=login, x1=len) -> x0 = 1 if newly added, 0 if already present.
// Full list -> error "too many excluded logins".
excl_add:
    adrp x2, excluded_logins
    add x2, x2, :lo12:excluded_logins
    adrp x3, excluded_count
    add x3, x3, :lo12:excluded_count
    ldr x4, [x3]
    mov x5, x2                       // entry pointer
    mov x6, x4                       // remaining
.Lea_dedupe:
    cbz x6, .Lea_add
    mov x7, #0
.Lea_cmp:
    cmp x7, x1
    b.ge .Lea_cmp_nul
    ldrb w8, [x5, x7]
    ldrb w9, [x0, x7]
    cmp w8, w9
    b.ne .Lea_next
    add x7, x7, #1
    b .Lea_cmp
.Lea_cmp_nul:
    ldrb w8, [x5, x7]
    cbnz w8, .Lea_next
    mov x0, #0                       // already present
    ret
.Lea_next:
    add x5, x5, #EXCL_STRIDE
    sub x6, x6, #1
    b .Lea_dedupe
.Lea_add:
    cmp x4, #MAX_EXCLUDED
    b.ge too_many_excl_err
    mov x5, x2
    add x5, x5, x4, lsl #5           // x4 * 32
    mov x7, #0
.Lea_copy:
    cmp x7, x1
    b.ge .Lea_copy_done
    ldrb w8, [x0, x7]
    strb w8, [x5, x7]
    add x7, x7, #1
    b .Lea_copy
.Lea_copy_done:
    mov w8, #0
    strb w8, [x5, x7]
    add x4, x4, #1
    str x4, [x3]
    mov x0, #1
    ret

// include_add(x0=login, x1=len) — add to the include list (dedupe, cap 512)
include_add:
    adrp x2, include_logins
    add x2, x2, :lo12:include_logins
    adrp x3, include_count
    add x3, x3, :lo12:include_count
    ldr x4, [x3]
    mov x5, x2
    mov x6, x4
.Lia_dedupe:
    cbz x6, .Lia_add
    mov x7, #0
.Lia_cmp:
    cmp x7, x1
    b.ge .Lia_cmp_nul
    ldrb w8, [x5, x7]
    ldrb w9, [x0, x7]
    cmp w8, w9
    b.ne .Lia_next
    add x7, x7, #1
    b .Lia_cmp
.Lia_cmp_nul:
    ldrb w8, [x5, x7]
    cbnz w8, .Lia_next
    ret
.Lia_next:
    add x5, x5, #EXCL_STRIDE
    sub x6, x6, #1
    b .Lia_dedupe
.Lia_add:
    cmp x4, #MAX_EXCLUDED
    b.ge too_many_excl_err
    mov x5, x2
    add x5, x5, x4, lsl #5
    mov x7, #0
.Lia_copy:
    cmp x7, x1
    b.ge .Lia_copy_done
    ldrb w8, [x0, x7]
    strb w8, [x5, x7]
    add x7, x7, #1
    b .Lia_copy
.Lia_copy_done:
    mov w8, #0
    strb w8, [x5, x7]
    add x4, x4, #1
    str x4, [x3]
    ret

too_many_excl_err:
    adrp x1, err_too_many_excl
    add x1, x1, :lo12:err_too_many_excl
    bl fail

// is_excluded(x0=login, x1=len) -> x0 = 1/0
is_excluded:
    adrp x2, excluded_logins
    add x2, x2, :lo12:excluded_logins
    adrp x3, excluded_count
    add x3, x3, :lo12:excluded_count
    ldr x4, [x3]
    mov x5, x2
    mov x6, x4
.Lie:
    cbz x6, .Lie_no
    mov x7, #0
.Lie_cmp:
    cmp x7, x1
    b.ge .Lie_cmp_nul
    ldrb w8, [x5, x7]
    ldrb w9, [x0, x7]
    cmp w8, w9
    b.ne .Lie_next
    add x7, x7, #1
    b .Lie_cmp
.Lie_cmp_nul:
    ldrb w8, [x5, x7]
    cbnz w8, .Lie_next
    mov x0, #1
    ret
.Lie_next:
    add x5, x5, #EXCL_STRIDE
    sub x6, x6, #1
    b .Lie
.Lie_no:
    mov x0, #0
    ret

// set_state_filter(x0=state) — records the filter; errors if already set
set_state_filter:
    stp x30, xzr, [sp, #-16]!
    adrp x1, state_filter
    add x1, x1, :lo12:state_filter
    ldr x2, [x1]
    cbnz x2, .Lssf_conflict
    str x0, [x1]
    ldp x30, xzr, [sp], #16
    ret
.Lssf_conflict:
    // names in STATES order: 1=live 2=offline 3=unknown
    mov x3, x2                       // existing
    mov x4, x0                       // new
    cmp x3, x4
    b.lt .Lssf_order_ok
    mov x5, x3
    mov x3, x4
    mov x4, x5
.Lssf_order_ok:
    // first name = x3, second = x4 (x3 <= x4, and they differ)
    cmp x3, #1
    b.eq .Lssf_first_live
    cmp x3, #2
    b.eq .Lssf_first_off
    // first is unknown (3) and differs from the second, impossible for the
    // pairs we emit; fall through defensively to the live/unknown message.
    b .Lssf_live_unk
.Lssf_first_live:
    cmp x4, #2
    b.eq .Lssf_live_off
    b .Lssf_live_unk
.Lssf_first_off:
    b .Lssf_off_unk
.Lssf_live_off:
    adrp x1, err_live_off
    add x1, x1, :lo12:err_live_off
    bl fail
.Lssf_live_unk:
    adrp x1, err_live_unk
    add x1, x1, :lo12:err_live_unk
    bl fail
.Lssf_off_unk:
    adrp x1, err_off_unk
    add x1, x1, :lo12:err_off_unk
    bl fail

// name_eq(x0=ptr, x1=len, x2=name) -> x0 = 1 if [x0..x0+x1) equals name
// (does NOT clobber x4/x5, so callers can keep a token ptr/len there)
name_eq:
    mov x3, #0
.Lne:
    ldrb w6, [x2, x3]
    cbz w6, .Lne_end
    cmp x3, x1
    b.ge .Lne_no
    ldrb w7, [x0, x3]
    cmp w6, w7
    b.ne .Lne_no
    add x3, x3, #1
    b .Lne
.Lne_end:
    cmp x3, x1
    b.ne .Lne_no
    mov x0, #1
    ret
.Lne_no:
    mov x0, #0
    ret

// parse_show(x24=raw) — parse --show columns into the show_ids[] list
parse_show:
    stp x30, xzr, [sp, #-16]!
    mov x2, x24                      // scan pointer
.Lps_outer:
    ldrb w3, [x2]
    cbz w3, .Lps_done
    cmp w3, #','
    b.eq .Lps_sep
    cmp w3, #' '
    b.eq .Lps_sep
    cmp w3, #9
    b.eq .Lps_sep
    mov x4, x2                       // token start (kept in x4)
    mov x5, #0                       // token len (kept in x5)
.Lps_token:
    ldrb w3, [x2]
    cbz w3, .Lps_token_end
    cmp w3, #','
    b.eq .Lps_token_end
    cmp w3, #' '
    b.eq .Lps_token_end
    cmp w3, #9
    b.eq .Lps_token_end
    add x2, x2, #1
    add x5, x5, #1
    b .Lps_token
.Lps_token_end:
    mov x0, x4
    mov x1, x5
    bl column_id_of                  // x0 = id or -1
    add x2, x4, x5                   // x2 = delimiter right after the token
                                     // (column_id_of clobbers x2; the outer
                                     // loop must resume at the separator)
    cmp x0, #0
    b.lt .Lps_unknown
    // dedupe into show_ids[]
    mov x6, x0
    adrp x7, show_count
    add x7, x7, :lo12:show_count
    ldr x8, [x7]
    mov x9, #0
.Lps_dedupe:
    cmp x9, x8
    b.ge .Lps_add
    adrp x10, show_ids
    add x10, x10, :lo12:show_ids
    ldr x11, [x10, x9, lsl #3]
    cmp x11, x6
    b.eq .Lps_outer
    add x9, x9, #1
    b .Lps_dedupe
.Lps_add:
    cmp x8, #7
    b.ge .Lps_outer                  // more than 7 extra columns: ignore
    adrp x10, show_ids
    add x10, x10, :lo12:show_ids
    str x6, [x10, x8, lsl #3]
    add x8, x8, #1
    str x8, [x7]
    b .Lps_outer
.Lps_unknown:
    stp x4, x5, [sp, #-16]!          // token ptr/len survive the prints
    adrp x1, err_col_pre
    add x1, x1, :lo12:err_col_pre
    mov x0, #STDERR
    bl print_cstr
    ldp x4, x5, [sp], #16
    mov x0, #STDERR
    mov x1, x4
    mov x2, x5                       // token length (print_cstr clobbered x2)
    bl write_n
    adrp x1, err_col_mid
    add x1, x1, :lo12:err_col_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0
.Lps_sep:
    add x2, x2, #1
    b .Lps_outer
.Lps_done:
    ldp x30, xzr, [sp], #16
    ret

// column_id_of(x0=ptr, x1=len) -> x0 = id, or -1 for an unknown name
column_id_of:
    stp x30, xzr, [sp, #-16]!
    adrp x2, s_live
    add x2, x2, :lo12:s_live
    bl name_eq
    cbz x0, .Lcio_next1
    mov x0, #S_LIVE
    ldp x30, xzr, [sp], #16
    ret
.Lcio_next1:
    mov x0, x4
    mov x1, x5
    adrp x2, s_offline
    add x2, x2, :lo12:s_offline
    bl name_eq
    cbz x0, .Lcio_next2
    mov x0, #S_OFF
    ldp x30, xzr, [sp], #16
    ret
.Lcio_next2:
    mov x0, x4
    mov x1, x5
    adrp x2, s_unknown
    add x2, x2, :lo12:s_unknown
    bl name_eq
    cbz x0, .Lcio_next3
    mov x0, #S_UNK
    ldp x30, xzr, [sp], #16
    ret
.Lcio_next3:
    mov x0, x4
    mov x1, x5
    adrp x2, s_offshare
    add x2, x2, :lo12:s_offshare
    bl name_eq
    cbz x0, .Lcio_next4
    mov x0, #S_OFFSHARE
    ldp x30, xzr, [sp], #16
    ret
.Lcio_next4:
    mov x0, x4
    mov x1, x5
    adrp x2, s_liveshare
    add x2, x2, :lo12:s_liveshare
    bl name_eq
    cbz x0, .Lcio_next5
    mov x0, #S_LIVESHARE
    ldp x30, xzr, [sp], #16
    ret
.Lcio_next5:
    mov x0, #-1
    ldp x30, xzr, [sp], #16
    ret

// parse_sort(x24=raw) — validate and store the sort metric id
parse_sort:
    stp x30, xzr, [sp, #-16]!
    mov x0, x24
    adrp x1, s_count
    add x1, x1, :lo12:s_count
    bl str_eq
    cbz x0, .Lpsrt_next1
    adrp x1, sort_id
    mov x2, #S_COUNT
    add x1, x1, :lo12:sort_id
    str x2, [x1]
    ldr x0, =F_SORT_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsrt_next1:
    mov x0, x24
    adrp x1, s_login
    add x1, x1, :lo12:s_login
    bl str_eq
    cbz x0, .Lpsrt_next2
    adrp x1, sort_id
    mov x2, #S_LOGIN
    add x1, x1, :lo12:sort_id
    str x2, [x1]
    ldr x0, =F_SORT_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsrt_next2:
    mov x0, x24
    adrp x1, s_live
    add x1, x1, :lo12:s_live
    bl str_eq
    cbz x0, .Lpsrt_next3
    adrp x1, sort_id
    mov x2, #S_LIVE
    add x1, x1, :lo12:sort_id
    str x2, [x1]
    ldr x0, =F_SORT_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsrt_next3:
    mov x0, x24
    adrp x1, s_offline
    add x1, x1, :lo12:s_offline
    bl str_eq
    cbz x0, .Lpsrt_next4
    adrp x1, sort_id
    mov x2, #S_OFF
    add x1, x1, :lo12:sort_id
    str x2, [x1]
    ldr x0, =F_SORT_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsrt_next4:
    mov x0, x24
    adrp x1, s_unknown
    add x1, x1, :lo12:s_unknown
    bl str_eq
    cbz x0, .Lpsrt_next5
    adrp x1, sort_id
    mov x2, #S_UNK
    add x1, x1, :lo12:sort_id
    str x2, [x1]
    ldr x0, =F_SORT_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsrt_next5:
    mov x0, x24
    adrp x1, s_offshare
    add x1, x1, :lo12:s_offshare
    bl str_eq
    cbz x0, .Lpsrt_next6
    adrp x1, sort_id
    mov x2, #S_OFFSHARE
    add x1, x1, :lo12:sort_id
    str x2, [x1]
    ldr x0, =F_SORT_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsrt_next6:
    mov x0, x24
    adrp x1, s_liveshare
    add x1, x1, :lo12:s_liveshare
    bl str_eq
    cbz x0, .Lpsrt_unknown
    adrp x1, sort_id
    mov x2, #S_LIVESHARE
    add x1, x1, :lo12:sort_id
    str x2, [x1]
    ldr x0, =F_SORT_GIVEN
    bl set_opt_flag
    ldp x30, xzr, [sp], #16
    ret
.Lpsrt_unknown:
    adrp x1, err_sort_pre
    add x1, x1, :lo12:err_sort_pre
    mov x0, #STDERR
    bl print_cstr
    mov x0, #STDERR
    mov x1, x24
    bl print_cstr
    adrp x1, err_sort_mid
    add x1, x1, :lo12:err_sort_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

// parse_header_mode(x24=raw)
parse_header_mode:
    stp x30, xzr, [sp, #-16]!
    mov x0, x24
    adrp x1, s_full
    add x1, x1, :lo12:s_full
    bl str_eq
    cbz x0, .Lph_next1
    adrp x1, header_mode
    mov x2, #H_FULL
    add x1, x1, :lo12:header_mode
    str x2, [x1]
    ldp x30, xzr, [sp], #16
    ret
.Lph_next1:
    mov x0, x24
    adrp x1, s_compact
    add x1, x1, :lo12:s_compact
    bl str_eq
    cbz x0, .Lph_next2
    adrp x1, header_mode
    mov x2, #H_COMPACT
    add x1, x1, :lo12:header_mode
    str x2, [x1]
    ldp x30, xzr, [sp], #16
    ret
.Lph_next2:
    mov x0, x24
    adrp x1, s_none
    add x1, x1, :lo12:s_none
    bl str_eq
    cbz x0, .Lph_unknown
    adrp x1, header_mode
    mov x2, #H_NONE
    add x1, x1, :lo12:header_mode
    str x2, [x1]
    ldp x30, xzr, [sp], #16
    ret
.Lph_unknown:
    adrp x1, err_header_pre
    add x1, x1, :lo12:err_header_pre
    mov x0, #STDERR
    bl print_cstr
    mov x0, #STDERR
    mov x1, x24
    bl print_cstr
    adrp x1, err_header_mid
    add x1, x1, :lo12:err_header_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0// ============================================================================
// Part 4 — channel resolution, exclusions, log listing, window resolution
// ============================================================================

// open_dir(x0=path) -> x0 = fd, or a negative errno
open_dir:
    mov x1, x0
    ldr x0, =AT_FDCWD
    mov x2, #O_RDONLY
    mov x8, #SYS_OPENAT
    svc #0
    ret

// close_fd(x0=fd)
close_fd:
    mov x8, #SYS_CLOSE
    svc #0
    ret

// lowercase_copy(x0=src, x1=dst) — lowercase an ASCII string into dst
lowercase_copy:
    mov x2, #0
.Llcc:
    ldrb w3, [x0, x2]
    cmp w3, #'A'
    b.lt .Llcc_store
    cmp w3, #'Z'
    b.gt .Llcc_store
    add w3, w3, #('a' - 'A')
.Llcc_store:
    strb w3, [x1, x2]
    cbz w3, .Llcc_done
    add x2, x2, #1
    cmp x2, #63
    b.lt .Llcc
.Llcc_done:
    mov w3, #0
    strb w3, [x1, x2]
    ret

// sort_dnames — insertion sort the dnames pointers by string
sort_dnames:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, dnames
    add x19, x19, :lo12:dnames
    adrp x20, dname_count
    add x20, x20, :lo12:dname_count
    ldr x20, [x20]
    mov x21, #1
.Lsd_outer:
    cmp x21, x20
    b.ge .Lsd_done
    ldr x22, [x19, x21, lsl #3]      // key
    mov x23, x21
.Lsd_inner:
    cbz x23, .Lsd_place
    sub x24, x23, #1
    ldr x25, [x19, x24, lsl #3]      // previous
    mov x0, x25
    mov x1, x22
    bl strcmp
    cmp x0, #0
    b.le .Lsd_place
    str x25, [x19, x23, lsl #3]
    mov x23, x24
    b .Lsd_inner
.Lsd_place:
    str x22, [x19, x23, lsl #3]
    add x21, x21, #1
    b .Lsd_outer
.Lsd_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// resolve_channel_dir — open the logs dir, list it, find the channel directory
resolve_channel_dir:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    // lowercased channel for matching and for --exclude-broadcaster
    adrp x0, channel_arg
    add x0, x0, :lo12:channel_arg
    adrp x1, channel_lower
    add x1, x1, :lo12:channel_lower
    bl lowercase_copy

    // open the logs dir
    adrp x0, logs_dir_arg
    add x0, x0, :lo12:logs_dir_arg
    bl open_dir
    cmp x0, #0
    b.lt .Lrcd_notfound
    mov x19, x0                      // logs dir fd

    // list entries, keep directories
    adrp x20, dname_count
    add x20, x20, :lo12:dname_count
    str xzr, [x20]
.Lrcd_list:
    mov x0, x19
    adrp x1, dirent_buf
    add x1, x1, :lo12:dirent_buf
    mov x2, #8192
    mov x8, #SYS_GETDENTS64
    svc #0
    cmp x0, #0
    b.le .Lrcd_list_done
    mov x21, x0                      // nread
    mov x22, #0                      // pos
.Lrcd_ent:
    cmp x22, x21
    b.ge .Lrcd_list
    add x3, x1, x22                  // entry
    ldrh w4, [x3, #16]               // d_reclen
    ldrb w5, [x3, #18]               // d_type
    add x6, x3, #19                  // d_name
    cmp w5, #DT_DIR
    b.ne .Lrcd_next_ent
    adrp x7, dname_count
    add x7, x7, :lo12:dname_count
    ldr x8, [x7]
    cmp x8, #MAX_DNAMES
    b.ge .Lrcd_next_ent
    // name length
    mov x9, x6
.Lrcd_nlen:
    ldrb w10, [x9]
    cbz w10, .Lrcd_nlen_done
    add x9, x9, #1
    b .Lrcd_nlen
.Lrcd_nlen_done:
    sub x11, x9, x6                  // name len
    cmp x11, #127
    b.gt .Lrcd_next_ent
    // skip "." and ".." (the kernel lists them; Python's listing does not)
    cmp x11, #1
    b.eq .Lrcd_check_dot
    cmp x11, #2
    b.ne .Lrcd_keep
    ldrb w10, [x6]
    cmp w10, #'.'
    b.ne .Lrcd_keep
    ldrb w10, [x6, #1]
    cmp w10, #'.'
    b.ne .Lrcd_keep
    b .Lrcd_next_ent
.Lrcd_check_dot:
    ldrb w10, [x6]
    cmp w10, #'.'
    b.ne .Lrcd_keep
    b .Lrcd_next_ent
.Lrcd_keep:
    // store the pointer and copy into the arena
    adrp x12, dnames
    add x12, x12, :lo12:dnames
    adrp x14, dname_arena
    add x14, x14, :lo12:dname_arena
    mov x15, #128
    mul x15, x8, x15
    add x14, x14, x15
    str x14, [x12, x8, lsl #3]
    mov x15, #0
.Lrcd_copy:
    cmp x15, x11
    b.ge .Lrcd_copy_done
    ldrb w16, [x6, x15]
    strb w16, [x14, x15]
    add x15, x15, #1
    b .Lrcd_copy
.Lrcd_copy_done:
    mov w16, #0
    strb w16, [x14, x15]
    add x8, x8, #1
    str x8, [x7]
.Lrcd_next_ent:
    add x22, x22, x4
    b .Lrcd_ent
.Lrcd_list_done:
    mov x0, x19
    bl close_fd

    // sort the directory names
    bl sort_dnames

    // find the channel (case-insensitive)
    adrp x19, dname_count
    add x19, x19, :lo12:dname_count
    ldr x20, [x19]
    mov x21, #0                       // index
.Lrcd_find:
    cmp x21, x20
    b.ge .Lrcd_notfound_channel
    adrp x22, dnames
    add x22, x22, :lo12:dnames
    ldr x3, [x22, x21, lsl #3]        // name
    adrp x4, channel_lower
    add x4, x4, :lo12:channel_lower
    mov x5, x3
.Lrcd_lc:
    ldrb w6, [x5]
    cbz w6, .Lrcd_lc_end
    ldrb w7, [x4]
    cbz w7, .Lrcd_next_find
    cmp w6, #'A'
    b.lt .Lrcd_lc_norm
    cmp w6, #'Z'
    b.gt .Lrcd_lc_norm
    add w6, w6, #('a' - 'A')
.Lrcd_lc_norm:
    cmp w6, w7
    b.ne .Lrcd_next_find
    add x5, x5, #1
    add x4, x4, #1
    b .Lrcd_lc
.Lrcd_lc_end:
    ldrb w7, [x4]
    cbnz w7, .Lrcd_next_find
    // found: copy the real name into channel_name
    adrp x0, channel_name
    add x0, x0, :lo12:channel_name
    mov x1, x3
    bl copy_str_64
    bl cstr_len
    adrp x2, channel_name_len
    add x2, x2, :lo12:channel_name_len
    str x0, [x2]
    // build channel_dir_path = logs_dir + "/" + channel_name
    adrp x0, channel_dir_path
    add x0, x0, :lo12:channel_dir_path
    adrp x1, logs_dir_arg
    add x1, x1, :lo12:logs_dir_arg
    bl copy_str_512
    adrp x0, channel_dir_path
    add x0, x0, :lo12:channel_dir_path
    bl cstr_len
    adrp x2, channel_dir_path
    add x2, x2, :lo12:channel_dir_path
    add x3, x2, x0
    mov w4, #'/'
    strb w4, [x3]
    add x3, x3, #1
    adrp x4, channel_name
    add x4, x4, :lo12:channel_name
.Lrcd_path_append:
    ldrb w5, [x4]
    cbz w5, .Lrcd_path_done
    strb w5, [x3]
    add x3, x3, #1
    add x4, x4, #1
    b .Lrcd_path_append
.Lrcd_path_done:
    mov w5, #0
    strb w5, [x3]
    // open the channel dir
    adrp x0, channel_dir_path
    add x0, x0, :lo12:channel_dir_path
    bl open_dir
    cmp x0, #0
    b.lt .Lrcd_cant_open
    adrp x1, channel_dirfd
    add x1, x1, :lo12:channel_dirfd
    str x0, [x1]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

.Lrcd_next_find:
    add x21, x21, #1
    b .Lrcd_find

.Lrcd_notfound:
    // "error: logs directory not found: <dir>"
    adrp x1, err_dir_not_found_pre
    add x1, x1, :lo12:err_dir_not_found_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x1, logs_dir_arg
    add x1, x1, :lo12:logs_dir_arg
    mov x0, #STDERR
    bl print_cstr
    mov x0, #STDERR
    adrp x1, newline
    add x1, x1, :lo12:newline
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

.Lrcd_notfound_channel:
    // "error: no logs for channel '<ch>' in <dir>"
    adrp x1, err_no_logs_pre
    add x1, x1, :lo12:err_no_logs_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x1, channel_arg
    add x1, x1, :lo12:channel_arg
    mov x0, #STDERR
    bl print_cstr
    adrp x1, err_no_logs_mid
    add x1, x1, :lo12:err_no_logs_mid
    mov x0, #STDERR
    bl print_cstr
    adrp x1, logs_dir_arg
    add x1, x1, :lo12:logs_dir_arg
    mov x0, #STDERR
    bl print_cstr
    mov x0, #STDERR
    adrp x1, newline
    add x1, x1, :lo12:newline
    bl print_cstr
    // "available: ..."
    adrp x1, err_avail
    add x1, x1, :lo12:err_avail
    mov x0, #STDERR
    bl print_cstr
    adrp x19, dname_count
    add x19, x19, :lo12:dname_count
    ldr x20, [x19]
    cbz x20, .Lrcd_none_avail
    mov x21, #0
.Lrcd_avail_loop:
    cmp x21, x20
    b.ge .Lrcd_avail_done
    adrp x22, dnames
    add x22, x22, :lo12:dnames
    ldr x3, [x22, x21, lsl #3]
    mov x0, #STDERR
    mov x1, x3
    bl print_cstr
    add x21, x21, #1
    cmp x21, x20
    b.ge .Lrcd_avail_done
    mov x0, #STDERR
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl print_cstr
    b .Lrcd_avail_loop
.Lrcd_avail_done:
    mov x0, #STDERR
    adrp x1, newline
    add x1, x1, :lo12:newline
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0
.Lrcd_none_avail:
    mov x0, #STDERR
    adrp x1, s_none_paren
    add x1, x1, :lo12:s_none_paren
    bl print_cstr
    mov x0, #STDERR
    adrp x1, newline
    add x1, x1, :lo12:newline
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

.Lrcd_cant_open:
    adrp x1, err_cant_open_dir
    add x1, x1, :lo12:err_cant_open_dir
    mov x0, #STDERR
    bl print_cstr
    adrp x1, channel_dir_path
    add x1, x1, :lo12:channel_dir_path
    mov x0, #STDERR
    bl print_cstr
    mov x0, #STDERR
    adrp x1, newline
    add x1, x1, :lo12:newline
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

// ----------------------------------------------------------------------------
// build_exclusions — the --no-exclude conflict check, the --include
// subtraction, and the --exclude-broadcaster login.
// ----------------------------------------------------------------------------
build_exclusions:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, opt_flags
    add x19, x19, :lo12:opt_flags
    ldr x20, [x19]
    tst x20, #F_NO_EXCLUDE
    b.eq .Lbe_normal
    // --no-exclude: conflict if -x / --include / --exclude-broadcaster given
    ldr x9, =770
    tst x20, x9
    b.eq .Lbe_clear
    adrp x1, err_noexcl_pre
    add x1, x1, :lo12:err_noexcl_pre
    mov x0, #STDERR
    bl print_cstr
    // list the conflicting flags in order --exclude, --exclude-broadcaster, --include
    mov x21, #0                      // "first printed" flag
    tst x20, #F_X_GIVEN
    b.eq .Lbe_no_x
    mov x0, #STDERR
    adrp x1, s_flag_exclude
    add x1, x1, :lo12:s_flag_exclude
    bl print_cstr
    mov x21, #1
.Lbe_no_x:
    tst x20, #F_BROADCASTER
    b.eq .Lbe_no_b
    cbz x21, .Lbe_no_b_sep
    mov x0, #STDERR
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl print_cstr
.Lbe_no_b_sep:
    mov x0, #STDERR
    adrp x1, s_flag_broadcaster
    add x1, x1, :lo12:s_flag_broadcaster
    bl print_cstr
    mov x21, #1
.Lbe_no_b:
    tst x20, #F_INCLUDE_GIVEN
    b.eq .Lbe_no_i
    cbz x21, .Lbe_no_i_sep
    mov x0, #STDERR
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl print_cstr
.Lbe_no_i_sep:
    mov x0, #STDERR
    adrp x1, s_flag_include
    add x1, x1, :lo12:s_flag_include
    bl print_cstr
.Lbe_no_i:
    mov x0, #STDERR
    adrp x1, newline
    add x1, x1, :lo12:newline
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0
.Lbe_clear:
    adrp x1, excluded_count
    add x1, x1, :lo12:excluded_count
    str xzr, [x1]
    adrp x1, x_added
    add x1, x1, :lo12:x_added
    str xzr, [x1]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

.Lbe_normal:
    // add the broadcaster login first (before the include subtraction)
    tst x20, #F_BROADCASTER
    b.eq .Lbe_include
    adrp x0, channel_lower
    add x0, x0, :lo12:channel_lower
    bl cstr_len
    mov x1, x0
    adrp x0, channel_lower
    add x0, x0, :lo12:channel_lower
    bl excl_add
.Lbe_include:
    // subtract the --include logins
    adrp x19, include_count
    add x19, x19, :lo12:include_count
    ldr x20, [x19]
    mov x21, #0
    mov x22, #0                      // removed count
.Lbe_inc_loop:
    cmp x21, x20
    b.ge .Lbe_inc_done
    adrp x23, include_logins
    add x23, x23, :lo12:include_logins
    add x23, x23, x21, lsl #5
    adrp x24, excluded_logins
    add x24, x24, :lo12:excluded_logins
    adrp x25, excluded_count
    add x25, x25, :lo12:excluded_count
    ldr x26, [x25]
    mov x27, #0
.Lbe_find:
    cmp x27, x26
    b.ge .Lbe_find_done
    add x28, x24, x27, lsl #5
    mov x0, x23
    mov x1, x28
    bl strcmp
    cbnz x0, .Lbe_find_next
    // found at x27: swap-delete with the last entry
    sub x9, x26, #1
    cmp x27, x9
    b.ge .Lbe_delete_last
    add x10, x24, x9, lsl #5
    add x11, x24, x27, lsl #5
    mov x12, #0
.Lbe_swap:
    cmp x12, #EXCL_STRIDE
    b.ge .Lbe_swap_done
    ldrb w13, [x10, x12]
    strb w13, [x11, x12]
    add x12, x12, #1
    b .Lbe_swap
.Lbe_swap_done:
.Lbe_delete_last:
    sub x9, x26, #1
    str x9, [x25]
    add x22, x22, #1
    b .Lbe_find_done
.Lbe_find_next:
    add x27, x27, #1
    b .Lbe_find
.Lbe_find_done:
    add x21, x21, #1
    b .Lbe_inc_loop
.Lbe_inc_done:
    adrp x1, include_removed
    add x1, x1, :lo12:include_removed
    str x22, [x1]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// ----------------------------------------------------------------------------
// list_log_files — getdents64 the channel dir; keep "<anything>-YYYY-MM-DD.log"
// ----------------------------------------------------------------------------
list_log_files:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x19, channel_dirfd
    add x19, x19, :lo12:channel_dirfd
    ldr x19, [x19]
    adrp x20, files_count
    add x20, x20, :lo12:files_count
    str xzr, [x20]
    adrp x23, dirent_buf
    add x23, x23, :lo12:dirent_buf
.Llf_list:
    mov x0, x19
    mov x1, x23                     // dirent_buf base (survives every call)
    mov x2, #8192
    mov x8, #SYS_GETDENTS64
    svc #0
    cmp x0, #0
    b.le .Llf_list_done
    mov x21, x0                      // nread
    mov x22, #0                      // pos
.Llf_ent:
    cmp x22, x21
    b.ge .Llf_list
    add x3, x23, x22                 // entry
    ldrh w24, [x3, #16]              // d_reclen (kept across the call)
    add x25, x3, #19                 // d_name (kept across the call)
    mov x6, x25
.Llf_nlen:
    ldrb w7, [x6]
    cbz w7, .Llf_nlen_done
    add x6, x6, #1
    b .Llf_nlen
.Llf_nlen_done:
    sub x26, x6, x25                 // name len (kept across the call)
    mov x0, x25
    mov x1, x26
    bl parse_log_filename            // x0 = ymd, or 0
    cbz x0, .Llf_next
    ldr x9, [x20]
    cmp x9, #MAX_FILES
    b.ge too_many_files_err
    adrp x10, files
    add x10, x10, :lo12:files
    mov x11, #FILE_STRIDE
    mul x11, x9, x11
    add x10, x10, x11
    str x0, [x10]                    // ymd
    add x10, x10, #8                 // name field
    mov x12, #0
.Llf_copy:
    cmp x12, x26
    b.ge .Llf_copy_done
    ldrb w13, [x25, x12]
    strb w13, [x10], #1
    add x12, x12, #1
    b .Llf_copy
.Llf_copy_done:
    mov w13, #0
    strb w13, [x10]
    add x9, x9, #1
    str x9, [x20]
.Llf_next:
    add x22, x22, x24
    b .Llf_ent
.Llf_list_done:
    bl sort_files
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

too_many_files_err:
    adrp x1, err_too_many_files
    add x1, x1, :lo12:err_too_many_files
    bl fail

// parse_log_filename(x0=name, x1=len) -> x0 = ymd, or 0 if it does not match
//   "<anything>-YYYY-MM-DD.log"  (the trailing date must be real)
parse_log_filename:
    cmp x1, #16
    b.lt .Lplf_fail
    // suffix ".log"
    sub x2, x1, #4
    ldrb w3, [x0, x2]
    cmp w3, #'.'
    b.ne .Lplf_fail
    sub x2, x1, #3
    ldrb w3, [x0, x2]
    cmp w3, #'l'
    b.ne .Lplf_fail
    sub x2, x1, #2
    ldrb w3, [x0, x2]
    cmp w3, #'o'
    b.ne .Lplf_fail
    sub x2, x1, #1
    ldrb w3, [x0, x2]
    cmp w3, #'g'
    b.ne .Lplf_fail
    // separators: '-' at len-15, len-10, len-7
    sub x2, x1, #15
    ldrb w3, [x0, x2]
    cmp w3, #'-'
    b.ne .Lplf_fail
    sub x2, x1, #10
    ldrb w3, [x0, x2]
    cmp w3, #'-'
    b.ne .Lplf_fail
    sub x2, x1, #7
    ldrb w3, [x0, x2]
    cmp w3, #'-'
    b.ne .Lplf_fail
    // the channel part before the first dash must be nonempty
    sub x2, x1, #15
    cbz x2, .Lplf_fail
    // year digits at len-14..len-11
    sub x2, x1, #14
    mov x3, #0
    mov x4, #0
.Lplf_y:
    cmp x4, #4
    b.ge .Lplf_mo
    ldrb w5, [x0, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    mov x6, #10
    mul x3, x3, x6
    add x3, x3, x5
    add x2, x2, #1
    add x4, x4, #1
    b .Lplf_y
.Lplf_mo:
    sub x2, x1, #9
    ldrb w5, [x0, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    mov x6, #10
    mul x7, x5, x6
    add x2, x2, #1
    ldrb w5, [x0, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    add x7, x7, x5                   // mo
    sub x2, x1, #6
    ldrb w5, [x0, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    mov x6, #10
    mul x8, x5, x6
    add x2, x2, #1
    ldrb w5, [x0, x2]
    sub w5, w5, #'0'
    cmp w5, #9
    b.hi .Lplf_fail
    add x8, x8, x5                   // d
    // validate the calendar date
    cbz x3, .Lplf_fail               // year 0
    cmp x7, #1
    b.lt .Lplf_fail
    cmp x7, #12
    b.gt .Lplf_fail
    cmp x8, #1
    b.lt .Lplf_fail
    mov x0, x3
    mov x1, x7
    stp x3, x7, [sp, #-16]!
    stp x8, x30, [sp, #-16]!
    bl days_in_month
    ldp x8, x30, [sp], #16
    ldp x3, x7, [sp], #16
    cmp x8, x0
    b.gt .Lplf_fail
    // ymd = y*10000 + mo*100 + d
    mov x5, #10000
    mul x3, x3, x5
    mov x5, #100
    mul x7, x7, x5
    add x3, x3, x7
    add x3, x3, x8
    mov x0, x3
    ret
.Lplf_fail:
    mov x0, #0
    ret

// sort_files — insertion sort the files table by ymd ascending.  The key
// entry is copied into a scratch buffer first: the shift below would otherwise
// overwrite it while it is still sitting in its original slot.
sort_files:
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, files
    add x19, x19, :lo12:files
    adrp x20, files_count
    add x20, x20, :lo12:files_count
    ldr x20, [x20]
    mov x21, #1
.Lsff_outer:
    cmp x21, x20
    b.ge .Lsff_done
    // key = files[x21], copied into sort_scratch
    adrp x22, sort_scratch
    add x22, x22, :lo12:sort_scratch
    mov x23, #FILE_STRIDE
    mul x23, x21, x23
    add x23, x19, x23                // source = files[x21]
    mov x9, #0
.Lsff_save:
    cmp x9, #FILE_STRIDE
    b.ge .Lsff_save_done
    ldrb w10, [x23, x9]
    strb w10, [x22, x9]
    add x9, x9, #1
    b .Lsff_save
.Lsff_save_done:
    mov x24, x21
.Lsff_inner:
    cbz x24, .Lsff_place
    sub x25, x24, #1
    mov x26, #FILE_STRIDE
    mul x26, x25, x26
    add x26, x19, x26                // prev = files[x25]
    ldr x27, [x22]                   // key ymd
    ldr x28, [x26]                   // prev ymd
    cmp x27, x28
    b.ge .Lsff_place
    // shift prev right into files[x24]
    mov x9, #FILE_STRIDE
    mul x9, x24, x9
    add x9, x19, x9                  // dest = files[x24]
    mov x10, #0
.Lsff_shift:
    cmp x10, #FILE_STRIDE
    b.ge .Lsff_shift_done
    ldrb w11, [x26, x10]
    strb w11, [x9, x10]
    add x10, x10, #1
    b .Lsff_shift
.Lsff_shift_done:
    mov x24, x25
    b .Lsff_inner
.Lsff_place:
    // files[x24] = key
    mov x9, #FILE_STRIDE
    mul x9, x24, x9
    add x9, x19, x9
    mov x10, #0
.Lsff_copy:
    cmp x10, #FILE_STRIDE
    b.ge .Lsff_copy_done
    ldrb w11, [x22, x10]
    strb w11, [x9, x10]
    add x10, x10, #1
    b .Lsff_copy
.Lsff_copy_done:
    add x21, x21, #1
    b .Lsff_outer
.Lsff_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret

// ----------------------------------------------------------------------------
// resolve_window — end (now or --end), begin (--begin / --since / earliest)
// ----------------------------------------------------------------------------
resolve_window:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x19, opt_flags
    add x19, x19, :lo12:opt_flags
    ldr x20, [x19]
    // ---- end ----
    tst x20, #F_END_GIVEN
    b.eq .Lrw_end_now
    adrp x0, end_arg
    add x0, x0, :lo12:end_arg
    mov x1, #1                       // a bare date means end of day
    bl parse_datetime
    cbz x2, datetime_err_end
    adrp x3, end_ymd
    add x3, x3, :lo12:end_ymd
    str x0, [x3]
    adrp x3, end_sod
    add x3, x3, :lo12:end_sod
    str x1, [x3]
    b .Lrw_begin
.Lrw_end_now:
    bl epoch_now                     // x0 = ymd, x1 = sod
    adrp x3, end_ymd
    add x3, x3, :lo12:end_ymd
    str x0, [x3]
    adrp x3, end_sod
    add x3, x3, :lo12:end_sod
    str x1, [x3]
    b .Lrw_begin
    // ---- begin ----
.Lrw_begin:
    tst x20, #F_BEGIN_GIVEN
    b.eq .Lrw_not_begin
    adrp x0, begin_arg
    add x0, x0, :lo12:begin_arg
    mov x1, #0                       // a bare date means start of day
    bl parse_datetime
    cbz x2, datetime_err_begin
    adrp x3, begin_ymd
    add x3, x3, :lo12:begin_ymd
    str x0, [x3]
    adrp x3, begin_sod
    add x3, x3, :lo12:begin_sod
    str x1, [x3]
    b .Lrw_check
.Lrw_not_begin:
    tst x20, #F_SINCE_GIVEN
    b.eq .Lrw_earliest
    // begin = end - delta
    adrp x0, since_arg
    add x0, x0, :lo12:since_arg
    bl parse_duration
    cmp x1, #0
    b.eq .Lrw_dur_ok
    cmp x1, #2
    b.eq duration_zero_err
    b duration_err
.Lrw_dur_ok:
    // epoch_begin = epoch_end - delta
    adrp x2, end_ymd
    add x2, x2, :lo12:end_ymd
    ldr x0, [x2]
    adrp x2, end_sod
    add x2, x2, :lo12:end_sod
    ldr x1, [x2]
    bl ymd_sod_to_epoch              // x0 = epoch_end
    mov x19, x0                      // save epoch_end (x19 is ours)
    adrp x2, since_arg
    add x0, x2, :lo12:since_arg
    bl parse_duration                // x0 = delta seconds
    sub x0, x19, x0                  // epoch_begin
    bl epoch_to_ymd_sod              // x0 = ymd, x1 = sod
    adrp x3, begin_ymd
    add x3, x3, :lo12:begin_ymd
    str x0, [x3]
    adrp x3, begin_sod
    add x3, x3, :lo12:begin_sod
    str x1, [x3]
    b .Lrw_check
.Lrw_earliest:
    adrp x0, files_count
    add x0, x0, :lo12:files_count
    ldr x1, [x0]
    cbnz x1, .Lrw_earliest_ok
    // "error: no log files found in <channel_dir>"
    adrp x1, err_no_files_pre
    add x1, x1, :lo12:err_no_files_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x1, channel_dir_path
    add x1, x1, :lo12:channel_dir_path
    mov x0, #STDERR
    bl print_cstr
    mov x0, #STDERR
    adrp x1, newline
    add x1, x1, :lo12:newline
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0
.Lrw_earliest_ok:
    adrp x1, files
    add x1, x1, :lo12:files
    ldr x2, [x1]                     // earliest ymd
    adrp x3, begin_ymd
    add x3, x3, :lo12:begin_ymd
    str x2, [x3]
    adrp x3, begin_sod
    add x3, x3, :lo12:begin_sod
    str xzr, [x3]
    b .Lrw_check
    // ---- begin > end ? ----
.Lrw_check:
    adrp x1, begin_ymd
    add x1, x1, :lo12:begin_ymd
    ldr x2, [x1]
    adrp x3, end_ymd
    add x3, x3, :lo12:end_ymd
    ldr x4, [x3]
    cmp x2, x4
    b.gt .Lrw_after
    b.lt .Lrw_done
    adrp x1, begin_sod
    add x1, x1, :lo12:begin_sod
    ldr x2, [x1]
    adrp x3, end_sod
    add x3, x3, :lo12:end_sod
    ldr x4, [x3]
    cmp x2, x4
    b.le .Lrw_done
.Lrw_after:
    // "error: begin (B) is after end (E)"
    adrp x1, err_begin_after_pre
    add x1, x1, :lo12:err_begin_after_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x0, begin_ymd
    add x0, x0, :lo12:begin_ymd
    ldr x9, [x0]                     // ymd
    adrp x0, begin_sod
    add x0, x0, :lo12:begin_sod
    ldr x2, [x0]                     // sod
    mov x0, x9
    mov x1, x2
    adrp x2, fmt_buf
    add x2, x2, :lo12:fmt_buf
    bl fmt_datetime                    // x0 = buf, x1 = 19
    mov x9, x1
    mov x1, x0
    mov x2, x9
    mov x0, #STDERR
    bl write_n
    adrp x1, err_begin_after_mid
    add x1, x1, :lo12:err_begin_after_mid
    mov x0, #STDERR
    bl print_cstr
    adrp x0, end_ymd
    add x0, x0, :lo12:end_ymd
    ldr x9, [x0]                     // ymd
    adrp x0, end_sod
    add x0, x0, :lo12:end_sod
    ldr x2, [x0]                     // sod
    mov x0, x9
    mov x1, x2
    adrp x2, fmt_buf
    add x2, x2, :lo12:fmt_buf
    bl fmt_datetime                    // x0 = buf, x1 = 19
    mov x9, x1
    mov x1, x0
    mov x2, x9
    mov x0, #STDERR
    bl write_n
    adrp x1, err_begin_after_suf
    add x1, x1, :lo12:err_begin_after_suf
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0
.Lrw_done:
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

datetime_err_begin:
    adrp x1, err_dt_pre
    add x1, x1, :lo12:err_dt_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x1, begin_arg
    add x1, x1, :lo12:begin_arg
    mov x0, #STDERR
    bl print_cstr
    adrp x1, err_dt_mid
    add x1, x1, :lo12:err_dt_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

datetime_err_end:
    adrp x1, err_dt_pre
    add x1, x1, :lo12:err_dt_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x1, end_arg
    add x1, x1, :lo12:end_arg
    mov x0, #STDERR
    bl print_cstr
    adrp x1, err_dt_mid
    add x1, x1, :lo12:err_dt_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

duration_err:
    adrp x1, err_dur_pre
    add x1, x1, :lo12:err_dur_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x1, since_arg
    add x1, x1, :lo12:since_arg
    mov x0, #STDERR
    bl print_cstr
    adrp x1, err_dur_mid
    add x1, x1, :lo12:err_dur_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

duration_zero_err:
    adrp x1, err_dur_zero
    add x1, x1, :lo12:err_dur_zero
    bl fail// ============================================================================
// Part 5 — the counting pass: seed state, line folding, user table
// ============================================================================

// read_file(x0=fd) -> x0 = status (0 ok, 1 too large, 2 error), x2 = bytes read
//   Reads the whole file into line_buf with an 8 MiB cap.  Uses only scratch
//   registers (x9-x12) so callers keep their callee-saved state untouched.
read_file:
    mov x9, x0                       // fd
    adrp x10, line_buf
    add x10, x10, :lo12:line_buf
    mov x11, #0                      // total
.Lrdf_loop:
    mov x0, x9
    mov x1, x10
    add x1, x1, x11
    ldr x2, =FILE_CAP_PLUS1
    sub x2, x2, x11
    mov x8, #SYS_READ
    svc #0
    cmp x0, #0
    b.lt .Lrdf_neg
    b.eq .Lrdf_done
    add x11, x11, x0
    ldr x2, =FILE_CAP
    cmp x11, x2
    b.hi .Lrdf_large
    b .Lrdf_loop
.Lrdf_neg:
    cmp x0, #-4                      // EINTR: retry
    b.eq .Lrdf_loop
    mov x0, #2                       // read error
    b .Lrdf_out
.Lrdf_large:
    mov x0, #1
    b .Lrdf_out
.Lrdf_done:
    mov x0, #0
.Lrdf_out:
    mov x2, x11
    ret

// marker_match(x0=line, x1=len, x2=lit, x3=litlen) -> x0 = 1 if the line ends
// with the marker literal: "[HH:MM:SS] <token> <lit>" with a single space
// before the literal and a non-empty, space-free token.
marker_match:
    mov x4, x3                       // litlen
    cmp x1, x4
    b.lt .Lmm_no
    // the line must end with the literal
    add x5, x0, x1                   // line end (one past)
    sub x6, x5, x4                   // start of the literal
    mov x7, #0
.Lmm_cmp:
    cmp x7, x4
    b.ge .Lmm_cmp_ok
    ldrb w8, [x6, x7]
    ldrb w9, [x2, x7]
    cmp w8, w9
    b.ne .Lmm_no
    add x7, x7, #1
    b .Lmm_cmp
.Lmm_cmp_ok:
    // the byte before the literal must be a space
    sub x7, x5, x4
    sub x7, x7, #1
    ldrb w8, [x7]
    cmp w8, #' '
    b.ne .Lmm_no
    // token length = len - litlen - 12  (11 for the "[HH:MM:SS] " prefix + 1
    // for the space); must be >= 1 and contain no space
    sub x9, x1, x4
    sub x9, x9, #12
    cmp x9, #1
    b.lt .Lmm_no
    add x10, x0, #11                 // token start
    mov x11, #0
.Lmm_tok:
    cmp x11, x9
    b.ge .Lmm_yes
    ldrb w12, [x10, x11]
    cmp w12, #' '
    b.eq .Lmm_no
    add x11, x11, #1
    b .Lmm_tok
.Lmm_yes:
    mov x0, #1
    ret
.Lmm_no:
    mov x0, #0
    ret

// line_is_marker(x0=line, x1=len) -> x0 = 1 (live), 2 (offline), or 0
line_is_marker:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                      // line (survives the marker_match calls)
    mov x20, x1                      // len
    cmp x1, #11
    b.lt .Llim_no
    ldrb w2, [x0]
    cmp w2, #'['
    b.ne .Llim_no
    ldrb w2, [x0, #1]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #2]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #3]
    cmp w2, #':'
    b.ne .Llim_no
    ldrb w2, [x0, #4]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #5]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #6]
    cmp w2, #':'
    b.ne .Llim_no
    ldrb w2, [x0, #7]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #8]
    sub w2, w2, #'0'
    cmp w2, #9
    b.hi .Llim_no
    ldrb w2, [x0, #9]
    cmp w2, #']'
    b.ne .Llim_no
    ldrb w2, [x0, #10]
    cmp w2, #' '
    b.ne .Llim_no
    // try "is live!"
    mov x0, x19
    mov x1, x20
    adrp x2, lit_is_live
    add x2, x2, :lo12:lit_is_live
    mov x3, #8
    bl marker_match
    cbnz x0, .Llim_live
    // try "is now offline."  (15 characters)
    mov x0, x19
    mov x1, x20
    adrp x2, lit_is_offline
    add x2, x2, :lo12:lit_is_offline
    mov x3, #15
    bl marker_match
    cbnz x0, .Llim_off
.Llim_no:
    mov x0, #0
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret
.Llim_live:
    mov x0, #1
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret
.Llim_off:
    mov x0, #2
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// scan_markers(x0=buf, x1=len) -> x0 = the LAST marker state (0/1/2) in the
// buffer.  Used by the seed pass.
scan_markers:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                      // buf
    add x20, x19, x1                 // end
    mov x21, #0                      // state
    mov x22, x19                     // line start
.Lsm_loop:
    cmp x22, x20
    b.ge .Lsm_done
    mov x23, x22
.Lsm_find:
    cmp x23, x20
    b.ge .Lsm_done                   // partial final line: stop
    ldrb w3, [x23]
    add x23, x23, #1
    cmp w3, #'\n'
    b.ne .Lsm_find
    sub x3, x23, x22
    sub x3, x3, #1                   // line len (excl '\n')
    mov x0, x22
    mov x1, x3
    bl line_is_marker
    cbnz x0, .Lsm_set
    b .Lsm_next
.Lsm_set:
    mov x21, x0
.Lsm_next:
    mov x22, x23
    b .Lsm_loop
.Lsm_done:
    mov x0, x21
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// seed_state — the live/offline state in force when the range opens.
//   Walks back through files whose date < begin.date(), newest first, at most
//   SEED_LOOKBACK of them, and returns the LAST marker found in the first
//   such file that has any.  Unreadable files are skipped.  Returns 0 when
//   nothing is known (the entering state is then "unknown").
seed_state:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, files
    add x19, x19, :lo12:files
    adrp x20, files_count
    add x20, x20, :lo12:files_count
    ldr x20, [x20]
    adrp x21, begin_ymd
    add x21, x21, :lo12:begin_ymd
    ldr x21, [x21]
    mov x22, #0                      // index
.Lss_find:
    cmp x22, x20
    b.ge .Lss_none
    mov x23, #FILE_STRIDE
    mul x23, x22, x23
    add x23, x19, x23
    ldr x24, [x23]
    cmp x24, x21
    b.ge .Lss_found
    add x22, x22, #1
    b .Lss_find
.Lss_none:
    mov x0, #0
    b .Lss_out
.Lss_found:
    sub x22, x22, #1                 // newest file before begin.date()
    cmp x22, #0
    b.lt .Lss_none2
    // limit = max(0, start - (SEED_LOOKBACK - 1))
    sub x23, x22, #(SEED_LOOKBACK - 1)
    cmp x23, #0
    b.ge .Lss_lim_ok
    mov x23, #0
.Lss_lim_ok:
    mov x24, #0                      // found state
.Lss_loop:
    cmp x22, x23
    b.lt .Lss_none2
    mov x25, #FILE_STRIDE
    mul x25, x22, x25
    add x25, x19, x25
    // open the file
    adrp x0, channel_dirfd
    add x0, x0, :lo12:channel_dirfd
    ldr x0, [x0]
    add x1, x25, #8                  // name
    mov x2, #O_RDONLY
    mov x8, #SYS_OPENAT
    svc #0
    cmp x0, #0
    b.lt .Lss_next_file
    mov x26, x0                      // fd
    bl read_file
    cmp x0, #0
    b.ne .Lss_close_next
    adrp x0, line_buf
    add x0, x0, :lo12:line_buf
    mov x1, x2
    bl scan_markers                  // x0 = state (0/1/2)
    mov x24, x0
    mov x0, x26
    bl close_fd
    cbnz x24, .Lss_found_state
    b .Lss_next_file
.Lss_close_next:
    mov x0, x26
    bl close_fd
.Lss_next_file:
    sub x22, x22, #1
    b .Lss_loop
.Lss_found_state:
    mov x0, x24
    b .Lss_out
.Lss_none2:
    mov x0, #0
.Lss_out:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// record_unreadable(x0=name_ptr, x1=reason) — capped unreadable list
record_unreadable:
    adrp x2, unreadable_count
    add x2, x2, :lo12:unreadable_count
    ldr x3, [x2]
    cmp x3, #MAX_UNREADABLE
    b.ge .Lru_done
    adrp x4, unreadable
    add x4, x4, :lo12:unreadable
    mov x5, #16
    mul x5, x3, x5
    add x4, x4, x5
    str x0, [x4]
    str x1, [x4, #8]
    add x3, x3, #1
    str x3, [x2]
.Lru_done:
    ret

// find_user(x0=login, x1=len) -> x0 = index, or -1
find_user:
    adrp x2, user_table
    add x2, x2, :lo12:user_table
    adrp x3, user_count
    add x3, x3, :lo12:user_count
    ldr x3, [x3]
    mov x4, x2                       // entry pointer
    mov x5, x3                       // remaining
.Lfnd_loop:
    cbz x5, .Lfnd_notfound
    mov x6, #0
.Lfnd_cmp:
    cmp x6, x1
    b.ge .Lfnd_cmp_nul
    ldrb w7, [x4, x6]
    ldrb w8, [x0, x6]
    cmp w7, w8
    b.ne .Lfnd_next
    add x6, x6, #1
    b .Lfnd_cmp
.Lfnd_cmp_nul:
    ldrb w7, [x4, x6]
    cbnz w7, .Lfnd_next               // table login longer than the input
    sub x7, x4, x2
    lsr x0, x7, #6                   // index
    ret
.Lfnd_next:
    add x4, x4, #USER_STRIDE
    sub x5, x5, #1
    b .Lfnd_loop
.Lfnd_notfound:
    mov x0, #-1
    ret

// add_user(x0=login, x1=len) -> x0 = index; errors "too many users" when full
add_user:
    adrp x2, user_table
    add x2, x2, :lo12:user_table
    adrp x3, user_count
    add x3, x3, :lo12:user_count
    ldr x4, [x3]
    cmp x4, #MAX_USERS
    b.ge too_many_users_err
    add x5, x2, x4, lsl #6           // entry = user_table + index*64
    mov x6, #0
.Lau_copy:
    cmp x6, x1
    b.ge .Lau_copy_done
    ldrb w7, [x0, x6]
    strb w7, [x5, x6]
    add x6, x6, #1
    b .Lau_copy
.Lau_copy_done:
    mov w7, #0
    strb w7, [x5, x6]
    str xzr, [x5, #32]               // live
    str xzr, [x5, #40]               // offline
    str xzr, [x5, #48]               // unknown
    add x4, x4, #1
    str x4, [x3]
    sub x0, x4, #1
    ret

too_many_users_err:
    adrp x1, err_too_many_users
    add x1, x1, :lo12:err_too_many_users
    bl fail

// speaker_login(x0=speaker, x1=slen) -> x0 = login_buf ptr, x1 = login len,
// or x0 = 0 when the speaker is not a real chatter.
speaker_login:
    stp x30, xzr, [sp, #-16]!
    // LOGIN_RE: ^[A-Za-z0-9_]{1,25}$
    cmp x1, #1
    b.lt .Lsl_fail
    cmp x1, #25
    b.gt .Lsl_localized
    mov x2, #0
.Lsl_login:
    cmp x2, x1
    b.ge .Lsl_login_ok
    ldrb w3, [x0, x2]
    bl is_login_char
    b.ne .Lsl_localized
    add x2, x2, #1
    b .Lsl_login
.Lsl_login_ok:
    // lowercase into login_buf
    adrp x4, login_buf
    add x4, x4, :lo12:login_buf
    mov x2, #0
.Lsl_lower:
    cmp x2, x1
    b.ge .Lsl_lower_done
    ldrb w3, [x0, x2]
    cmp w3, #'A'
    b.lt .Lsl_lstore
    cmp w3, #'Z'
    b.gt .Lsl_lstore
    add w3, w3, #('a' - 'A')
.Lsl_lstore:
    strb w3, [x4, x2]
    add x2, x2, #1
    b .Lsl_lower
.Lsl_lower_done:
    mov w3, #0
    strb w3, [x4, x2]
    mov x0, x4
    ldp x30, xzr, [sp], #16
    ret
.Lsl_localized:
    // LOCALIZED_RE: ^(\S+) ([a-z0-9_]{1,25})$ with a non-ASCII display
    // find the LAST space
    mov x2, #0
    mov x3, #-1                      // last space index
.Lsl_find_sp:
    cmp x2, x1
    b.ge .Lsl_sp_found
    ldrb w4, [x0, x2]
    cmp w4, #' '
    b.ne .Lsl_sp_next
    mov x3, x2
.Lsl_sp_next:
    add x2, x2, #1
    b .Lsl_find_sp
.Lsl_sp_found:
    cmp x3, #0
    b.lt .Lsl_fail                  // no space
    cbz x3, .Lsl_fail               // empty display
    mov x6, x3                      // space index (survives the right check)
    // right part = [x6+1, x1), must be [a-z0-9_]{1,25}
    sub x4, x1, x6
    sub x4, x4, #1                  // right len
    cmp x4, #1
    b.lt .Lsl_fail
    cmp x4, #25
    b.gt .Lsl_fail
    add x5, x0, x6
    add x5, x5, #1                  // right start
    mov x2, #0
.Lsl_right:
    cmp x2, x4
    b.ge .Lsl_right_ok
    ldrb w3, [x5, x2]
    bl is_lower_login_char
    b.ne .Lsl_fail
    add x2, x2, #1
    b .Lsl_right
.Lsl_right_ok:
    // left part = [0, x6): no space/tab, and contains a byte > 127
    mov x2, #0
    mov x7, #0                       // has non-ascii
.Lsl_left:
    cmp x2, x6
    b.ge .Lsl_left_ok
    ldrb w3, [x0, x2]
    cmp w3, #' '
    b.eq .Lsl_fail
    cmp w3, #9
    b.eq .Lsl_fail
    cmp w3, #128
    b.lt .Lsl_left_next
    mov x7, #1
.Lsl_left_next:
    add x2, x2, #1
    b .Lsl_left
.Lsl_left_ok:
    cbz x7, .Lsl_fail
    // login = right (already lowercase); copy into login_buf
    adrp x8, login_buf
    add x8, x8, :lo12:login_buf
    mov x2, #0
.Lsl_copy:
    cmp x2, x4
    b.ge .Lsl_copy_done
    ldrb w7, [x5, x2]
    strb w7, [x8, x2]
    add x2, x2, #1
    b .Lsl_copy
.Lsl_copy_done:
    mov w7, #0
    strb w7, [x8, x4]
    mov x0, x8
    ldp x30, xzr, [sp], #16
    ret
.Lsl_fail:
    mov x0, #0
    ldp x30, xzr, [sp], #16
    ret

// process_message(x0=line, x1=len, x2=lo, x3=hi, x4=state) -> x0 = 1 if counted
//   Folds one message line into the user table and the global state counters.
process_message:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                      // line
    mov x20, x1                      // len
    mov x21, x2                      // lo
    mov x22, x3                      // hi
    mov x23, x4                      // state (0/1/2)
    // timestamp prefix "[HH:MM:SS] "
    cmp x20, #11
    b.lt .Lpm_skip
    ldrb w3, [x19]
    cmp w3, #'['
    b.ne .Lpm_skip
    ldrb w3, [x19, #1]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #2]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #3]
    cmp w3, #':'
    b.ne .Lpm_skip
    ldrb w3, [x19, #4]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #5]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #6]
    cmp w3, #':'
    b.ne .Lpm_skip
    ldrb w3, [x19, #7]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #8]
    sub w3, w3, #'0'
    cmp w3, #9
    b.hi .Lpm_skip
    ldrb w3, [x19, #9]
    cmp w3, #']'
    b.ne .Lpm_skip
    ldrb w3, [x19, #10]
    cmp w3, #' '
    b.ne .Lpm_skip
    // find the first ": " in rest = [x19+11, x19+len)
    mov x24, x19
    add x24, x24, #11                // scan pointer
    add x3, x19, x20                 // line end
.Lpm_find_colon:
    cmp x24, x3
    b.ge .Lpm_skip
    ldrb w4, [x24]
    add x24, x24, #1
    cmp w4, #':'
    b.ne .Lpm_find_colon
    cmp x24, x3
    b.ge .Lpm_skip                   // ':' at the very end
    ldrb w4, [x24]
    cmp w4, #' '
    b.ne .Lpm_find_colon
    // colon at x24-1; speaker = [x19+11, x24-1)
    sub x24, x24, #1
    sub x25, x24, x19                // speaker end offset
    sub x25, x25, #11                // speaker len
    cbz x25, .Lpm_skip
    // the speaker must not contain ':'
    add x4, x19, #11
    mov x5, #0
.Lpm_spk:
    cmp x5, x25
    b.ge .Lpm_spk_ok
    ldrb w6, [x4, x5]
    cmp w6, #':'
    b.eq .Lpm_skip
    add x5, x5, #1
    b .Lpm_spk
.Lpm_spk_ok:
    // second-of-day from line[1..8]
    ldrb w6, [x19, #1]
    sub w6, w6, #'0'
    mov x7, #10
    mul x7, x6, x7
    ldrb w6, [x19, #2]
    sub w6, w6, #'0'
    add x7, x7, x6                   // h
    mov x8, #3600
    mul x7, x7, x8                   // h*3600
    ldrb w6, [x19, #4]
    sub w6, w6, #'0'
    mov x9, #10
    mul x9, x6, x9
    ldrb w6, [x19, #5]
    sub w6, w6, #'0'
    add x9, x9, x6                   // m
    mov x10, #60
    mul x9, x9, x10                  // m*60
    add x7, x7, x9
    ldrb w6, [x19, #7]
    sub w6, w6, #'0'
    mov x10, #10
    mul x10, x6, x10
    ldrb w6, [x19, #8]
    sub w6, w6, #'0'
    add x10, x10, x6                 // s
    add x26, x7, x10                 // second
    // clip to [lo, hi]
    cmp x26, x21
    b.lt .Lpm_skip
    cmp x26, x22
    b.gt .Lpm_skip
    // speaker login
    mov x0, x4
    mov x1, x25
    bl speaker_login                 // x0 = login ptr or 0, x1 = login len
    cbz x0, .Lpm_skip
    // state id: current state or unknown
    mov x24, x0                      // login ptr
    mov x25, x1                      // login len
    mov x26, x23                     // state survives the user-table calls
    cbnz x26, .Lpm_state_set
    mov x26, #ST_UNK
.Lpm_state_set:
    // find / add the user
    mov x0, x24
    mov x1, x25
    bl find_user                     // x0 = index or -1
    cmp x0, #0
    b.ge .Lpm_have_user
    mov x0, x24
    mov x1, x25
    bl add_user                      // x0 = index
.Lpm_have_user:
    // increment the user's state counter and the global counter
    adrp x9, user_table
    add x9, x9, :lo12:user_table
    mov x10, #USER_STRIDE
    mul x10, x0, x10
    add x9, x9, x10
    cmp x26, #ST_LIVE
    b.eq .Lpm_inc_live
    cmp x26, #ST_OFF
    b.eq .Lpm_inc_off
    b .Lpm_inc_unk
.Lpm_inc_live:
    ldr x11, [x9, #32]
    add x11, x11, #1
    str x11, [x9, #32]
    adrp x12, g_live
    add x12, x12, :lo12:g_live
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_excl_check
.Lpm_inc_off:
    ldr x11, [x9, #40]
    add x11, x11, #1
    str x11, [x9, #40]
    adrp x12, g_off
    add x12, x12, :lo12:g_off
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_excl_check
.Lpm_inc_unk:
    ldr x11, [x9, #48]
    add x11, x11, #1
    str x11, [x9, #48]
    adrp x12, g_unk
    add x12, x12, :lo12:g_unk
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
.Lpm_excl_check:
    // excluded login? -> the excluded global split loses this message too
    mov x0, x24
    mov x1, x25
    bl is_excluded
    cbz x0, .Lpm_counted
    cmp x26, #ST_LIVE
    b.eq .Lpm_e_live
    cmp x26, #ST_OFF
    b.eq .Lpm_e_off
    b .Lpm_e_unk
.Lpm_e_live:
    adrp x12, e_live
    add x12, x12, :lo12:e_live
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_counted
.Lpm_e_off:
    adrp x12, e_off
    add x12, x12, :lo12:e_off
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
    b .Lpm_counted
.Lpm_e_unk:
    adrp x12, e_unk
    add x12, x12, :lo12:e_unk
    ldr x13, [x12]
    add x13, x13, #1
    str x13, [x12]
.Lpm_counted:
    mov x0, #1
    b .Lpm_out
.Lpm_skip:
    mov x0, #0
.Lpm_out:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// process_lines(x0=buf, x1=len, x2=lo, x3=hi) — fold every line of one file.
//   Reads and writes the global cur_state.
process_lines:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                      // line pointer
    add x20, x0, x1                  // end
    mov x21, x2                      // lo
    mov x22, x3                      // hi
    adrp x23, cur_state
    add x23, x23, :lo12:cur_state
    ldr x23, [x23]
.Lpl:
    cmp x19, x20
    b.ge .Lpl_done
    mov x24, x19                     // line start
    mov x25, x19                     // scan pointer
.Lpl_find:
    cmp x25, x20
    b.ge .Lpl_done                   // partial final line: dropped
    ldrb w3, [x25]
    add x25, x25, #1
    cmp w3, #'\n'
    b.ne .Lpl_find
    sub x26, x25, x24                // line len incl '\n'
    sub x26, x26, #1                 // line len excl '\n'
    cbz x26, .Lpl_next
    // strip a trailing '\r'
    add x3, x24, x26
    sub x3, x3, #1
    ldrb w4, [x3]
    cmp w4, #'\r'
    b.ne .Lpl_nocr
    sub x26, x26, #1
    cbz x26, .Lpl_next
.Lpl_nocr:
    // skip comment lines
    ldrb w3, [x24]
    cmp w3, #'#'
    b.eq .Lpl_next
    // marker?
    mov x0, x24
    mov x1, x26
    bl line_is_marker
    cbnz x0, .Lpl_marker
    // message?
    mov x0, x24
    mov x1, x26
    mov x2, x21
    mov x3, x22
    mov x4, x23
    bl process_message
    b .Lpl_next
.Lpl_marker:
    mov x23, x0
    b .Lpl_next
.Lpl_next:
    mov x19, x25
    b .Lpl
.Lpl_done:
    adrp x0, cur_state
    add x0, x0, :lo12:cur_state
    str x23, [x0]
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// count_all — seed the state, then count every in-range file.
count_all:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    // seed the entering stream state
    bl seed_state                    // x0 = 0/1/2
    adrp x1, cur_state
    add x1, x1, :lo12:cur_state
    str x0, [x1]
    // loop state
    adrp x19, files_count
    add x19, x19, :lo12:files_count
    ldr x19, [x19]
    mov x20, #0                      // i
    adrp x25, begin_ymd
    add x25, x25, :lo12:begin_ymd
    ldr x25, [x25]
    adrp x26, begin_sod
    add x26, x26, :lo12:begin_sod
    ldr x26, [x26]
    adrp x27, end_ymd
    add x27, x27, :lo12:end_ymd
    ldr x27, [x27]
    adrp x28, end_sod
    add x28, x28, :lo12:end_sod
    ldr x28, [x28]
.Lca_loop:
    cmp x20, x19
    b.ge .Lca_done
    adrp x22, files
    add x22, x22, :lo12:files
    mov x23, #FILE_STRIDE
    mul x23, x20, x23
    add x23, x22, x23                // entry
    ldr x24, [x23]                   // ymd
    cmp x24, x25
    b.lt .Lca_next
    cmp x24, x27
    b.gt .Lca_next
    // count the file (in range, even if unreadable)
    adrp x9, files_total
    add x9, x9, :lo12:files_total
    ldr x10, [x9]
    add x10, x10, #1
    str x10, [x9]
    // lo/hi
    mov x3, #0
    cmp x25, x24
    b.lt .Lca_lo_ok
    mov x3, x26
.Lca_lo_ok:
    ldr x4, =LAST_SECOND
    cmp x27, x24
    b.gt .Lca_hi_ok
    mov x4, x28
.Lca_hi_ok:
    // open the file
    adrp x0, channel_dirfd
    add x0, x0, :lo12:channel_dirfd
    ldr x0, [x0]
    add x1, x23, #8                  // name
    mov x2, #O_RDONLY
    mov x8, #SYS_OPENAT
    svc #0
    cmp x0, #0
    b.lt .Lca_unreadable
    str x0, [sp, #-16]!              // stash the fd
    bl read_file                     // x0 = status, x2 = bytes
    mov x10, x0                      // keep the status across close_fd
    cmp x0, #0
    b.ne .Lca_unreadable_fd
    adrp x0, line_buf
    add x0, x0, :lo12:line_buf
    mov x1, x2
    mov x2, x3                       // lo
    mov x3, x4                       // hi
    bl process_lines
    ldr x0, [sp], #16                // fd
    bl close_fd
    b .Lca_next
.Lca_unreadable_fd:
    ldr x0, [sp], #16                // fd
    bl close_fd                      // x10 still holds the read status
    cmp x10, #1
    b.eq .Lca_too_large
    add x0, x23, #8                  // name
    mov x1, #R_CANNOT_READ
    bl record_unreadable
    b .Lca_unreadable_done
.Lca_too_large:
    add x0, x23, #8                  // name
    mov x1, #R_TOO_LARGE
    bl record_unreadable
    b .Lca_unreadable_done
.Lca_unreadable_done:
    // the stream state does not carry across an unreadable day
    adrp x9, cur_state
    add x9, x9, :lo12:cur_state
    str xzr, [x9]
    b .Lca_next
.Lca_unreadable:                     // open failed (x0 = -errno)
    add x0, x23, #8                  // name
    mov x1, #R_CANNOT_READ
    bl record_unreadable
    adrp x9, cur_state
    add x9, x9, :lo12:cur_state
    str xzr, [x9]
    b .Lca_next
.Lca_next:
    add x20, x20, #1
    b .Lca_loop
.Lca_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret// ============================================================================
// Part 6 — ranking and presentation: totals, sorting, share floor, row cap
// ============================================================================

// filtered_total(x0=user_index) -> x0 = the count-column value for the user
// (the sum of the states matching the filter, or all three when unfiltered)
filtered_total:
    adrp x1, user_table
    add x1, x1, :lo12:user_table
    mov x2, #USER_STRIDE
    mul x2, x0, x2
    add x1, x1, x2
    adrp x3, state_filter
    add x3, x3, :lo12:state_filter
    ldr x4, [x3]
    cmp x4, #ST_LIVE
    b.eq .Lft_live
    cmp x4, #ST_OFF
    b.eq .Lft_off
    cmp x4, #ST_UNK
    b.eq .Lft_unk
    ldr x0, [x1, #32]
    ldr x5, [x1, #40]
    add x0, x0, x5
    ldr x5, [x1, #48]
    add x0, x0, x5
    ret
.Lft_live:
    ldr x0, [x1, #32]
    ret
.Lft_off:
    ldr x0, [x1, #40]
    ret
.Lft_unk:
    ldr x0, [x1, #48]
    ret

// state_count(x0=user_index, x1=state_id) -> x0 = that state's count
state_count:
    adrp x2, user_table
    add x2, x2, :lo12:user_table
    mov x3, #USER_STRIDE
    mul x3, x0, x3
    add x2, x2, x3
    cmp x1, #ST_LIVE
    b.eq .Lsc_live
    cmp x1, #ST_OFF
    b.eq .Lsc_off
    ldr x0, [x2, #48]
    ret
.Lsc_live:
    ldr x0, [x2, #32]
    ret
.Lsc_off:
    ldr x0, [x2, #40]
    ret

// build_columns — compose columns[] from -B and --show, and the source id.
//   columns_source: 0 = none, 1 = --by-state, 2 = --show, 3 = both
build_columns:
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x0, columns_count
    add x0, x0, :lo12:columns_count
    str xzr, [x0]
    adrp x0, opt_flags
    add x0, x0, :lo12:opt_flags
    ldr x1, [x0]
    tst x1, #F_BY_STATE
    b.eq .Lbc_show
    adrp x0, columns
    add x0, x0, :lo12:columns
    mov x2, #S_LIVE
    str x2, [x0]
    mov x2, #S_OFF
    str x2, [x0, #8]
    mov x2, #S_OFFSHARE
    str x2, [x0, #16]
    adrp x3, columns_count
    mov x4, #3
    add x3, x3, :lo12:columns_count
    str x4, [x3]
.Lbc_show:
    // append the --show columns (dedupe)
    adrp x0, show_count
    add x0, x0, :lo12:show_count
    ldr x1, [x0]
    mov x2, #0
.Lbc_app:
    cmp x2, x1
    b.ge .Lbc_done
    adrp x3, show_ids
    add x3, x3, :lo12:show_ids
    ldr x4, [x3, x2, lsl #3]
    adrp x5, columns_count
    add x5, x5, :lo12:columns_count
    ldr x6, [x5]
    mov x7, #0
.Lbc_dup:
    cmp x7, x6
    b.ge .Lbc_add
    adrp x8, columns
    add x8, x8, :lo12:columns
    ldr x9, [x8, x7, lsl #3]
    cmp x9, x4
    b.eq .Lbc_next
    add x7, x7, #1
    b .Lbc_dup
.Lbc_add:
    cmp x6, #7
    b.ge .Lbc_next
    adrp x8, columns
    add x8, x8, :lo12:columns
    str x4, [x8, x6, lsl #3]
    add x6, x6, #1
    str x6, [x5]
.Lbc_next:
    add x2, x2, #1
    b .Lbc_app
.Lbc_done:
    // columns_source id
    adrp x0, opt_flags
    add x0, x0, :lo12:opt_flags
    ldr x1, [x0]
    mov x2, #0
    tst x1, #F_BY_STATE
    b.eq .Lbc_src_show
    mov x2, #1
.Lbc_src_show:
    adrp x0, show_count
    add x0, x0, :lo12:show_count
    ldr x3, [x0]
    cbz x3, .Lbc_src_done
    cmp x2, #1
    b.ne .Lbc_src_only_show
    mov x2, #3
    b .Lbc_src_done
.Lbc_src_only_show:
    mov x2, #2
.Lbc_src_done:
    adrp x0, columns_source
    add x0, x0, :lo12:columns_source
    str x2, [x0]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ret

// degenerate_check — a state filter with per-state columns or sorts is
// degenerate (Python raises here too)
degenerate_check:
    stp x30, xzr, [sp, #-16]!
    adrp x0, state_filter
    add x0, x0, :lo12:state_filter
    ldr x1, [x0]
    cbz x1, .Ldg_ok
    adrp x0, columns_count
    add x0, x0, :lo12:columns_count
    ldr x2, [x0]
    mov x3, #0
.Ldg_col:
    cmp x3, x2
    b.ge .Ldg_sort
    adrp x4, columns
    add x4, x4, :lo12:columns
    ldr x5, [x4, x3, lsl #3]
    cmp x5, #S_LIVE
    b.ge .Ldg_err
    add x3, x3, #1
    b .Ldg_col
.Ldg_sort:
    adrp x4, sort_id
    add x4, x4, :lo12:sort_id
    ldr x5, [x4]
    cmp x5, #S_LIVE
    b.ge .Ldg_err
.Ldg_ok:
    ldp x30, xzr, [sp], #16
    ret
.Ldg_err:
    // "error: --<state> counts one state only, ..."
    adrp x1, err_degenerate_pre
    add x1, x1, :lo12:err_degenerate_pre
    mov x0, #STDERR
    bl print_cstr
    adrp x1, state_filter
    add x1, x1, :lo12:state_filter
    ldr x2, [x1]
    cmp x2, #ST_LIVE
    b.eq .Ldg_name_live
    cmp x2, #ST_OFF
    b.eq .Ldg_name_off
    adrp x1, s_unknown
    add x1, x1, :lo12:s_unknown
    b .Ldg_name_print
.Ldg_name_live:
    adrp x1, s_live
    add x1, x1, :lo12:s_live
    b .Ldg_name_print
.Ldg_name_off:
    adrp x1, s_offline
    add x1, x1, :lo12:s_offline
.Ldg_name_print:
    mov x0, #STDERR
    bl print_cstr
    adrp x1, err_degenerate_mid
    add x1, x1, :lo12:err_degenerate_mid
    mov x0, #STDERR
    bl print_cstr
    mov x0, #1
    mov x8, #SYS_EXIT
    svc #0

// build_reported — fill reported[], counts_count, total_messages.
//   reported[] holds user indices with filtered_total >= min_count.
//   counts_count = users with filtered_total > 0 (not excluded).
//   total_messages = sum of filtered totals over non-excluded users.
build_reported:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x19, user_count
    add x19, x19, :lo12:user_count
    ldr x19, [x19]
    mov x20, #0                      // user index
    adrp x21, reported
    add x21, x21, :lo12:reported
    mov x22, #0                      // reported count
    mov x23, #0                      // counts count
    mov x24, #0                      // total messages
    adrp x25, min_count
    add x25, x25, :lo12:min_count
    ldr x25, [x25]
.Lbr_loop:
    cmp x20, x19
    b.ge .Lbr_done
    adrp x26, user_table
    add x26, x26, :lo12:user_table
    mov x27, #USER_STRIDE
    mul x27, x20, x27
    add x26, x26, x27                // entry ptr
    // excluded?
    mov x0, x26
    bl cstr_len
    mov x1, x0
    mov x0, x26
    bl is_excluded
    cbnz x0, .Lbr_next
    mov x0, x20
    bl filtered_total                // x0 = t
    mov x28, x0
    cbz x28, .Lbr_next               // t == 0 -> not in counts
    add x23, x23, #1
    add x24, x24, x28
    cmp x28, x25
    b.lt .Lbr_next
    str x20, [x21, x22, lsl #3]
    add x22, x22, #1
.Lbr_next:
    add x20, x20, #1
    b .Lbr_loop
.Lbr_done:
    adrp x0, reported_count
    add x0, x0, :lo12:reported_count
    str x22, [x0]
    adrp x0, counts_count
    add x0, x0, :lo12:counts_count
    str x23, [x0]
    adrp x0, total_messages
    add x0, x0, :lo12:total_messages
    str x24, [x0]
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// compute_excluded_appeared — for each excluded login, if it is in the user
// table with filtered_total > 0, record (login ptr, filtered total) and sum.
compute_excluded_appeared:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, excluded_count
    add x19, x19, :lo12:excluded_count
    ldr x19, [x19]
    mov x20, #0                      // excl index
    mov x21, #0                      // appeared count
    mov x22, #0                      // excluded_msgs
.Lcea_loop:
    cmp x20, x19
    b.ge .Lcea_done
    adrp x23, excluded_logins
    add x23, x23, :lo12:excluded_logins
    add x23, x23, x20, lsl #5        // login ptr
    mov x0, x23
    bl cstr_len
    mov x1, x0
    mov x0, x23
    bl find_user                     // x0 = index or -1
    cmp x0, #0
    b.lt .Lcea_next
    mov x24, x0
    bl filtered_total                // x0 = t
    cbz x0, .Lcea_next
    adrp x25, excluded_appeared
    add x25, x25, :lo12:excluded_appeared
    mov x26, #16
    mul x26, x21, x26
    add x25, x25, x26
    str x23, [x25]
    str x0, [x25, #8]
    add x21, x21, #1
    add x22, x22, x0
.Lcea_next:
    add x20, x20, #1
    b .Lcea_loop
.Lcea_done:
    adrp x0, excluded_appeared_count
    add x0, x0, :lo12:excluded_appeared_count
    str x21, [x0]
    adrp x0, excluded_msgs
    add x0, x0, :lo12:excluded_msgs
    str x22, [x0]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// reported_cmp(x0=a_index, x1=b_index) -> x0 = 1 if a sorts before b
reported_cmp:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    adrp x21, sort_id
    add x21, x21, :lo12:sort_id
    ldr x21, [x21]
    cmp x21, #S_LOGIN
    b.eq .Lrc_login
    cmp x21, #S_LIVE
    b.eq .Lrc_metric_live
    cmp x21, #S_OFF
    b.eq .Lrc_metric_off
    cmp x21, #S_UNK
    b.eq .Lrc_metric_unk
    cmp x21, #S_OFFSHARE
    b.eq .Lrc_metric_offshare
    cmp x21, #S_LIVESHARE
    b.eq .Lrc_metric_liveshare
    // S_COUNT
    mov x0, x19
    bl filtered_total
    mov x21, x0
    mov x0, x20
    bl filtered_total
    mov x22, x0
    b .Lrc_metric_cmp
.Lrc_metric_live:
    mov x0, x19
    mov x1, #ST_LIVE
    bl state_count
    mov x21, x0
    mov x0, x20
    mov x1, #ST_LIVE
    bl state_count
    mov x22, x0
    b .Lrc_metric_cmp
.Lrc_metric_off:
    mov x0, x19
    mov x1, #ST_OFF
    bl state_count
    mov x21, x0
    mov x0, x20
    mov x1, #ST_OFF
    bl state_count
    mov x22, x0
    b .Lrc_metric_cmp
.Lrc_metric_unk:
    mov x0, x19
    mov x1, #ST_UNK
    bl state_count
    mov x21, x0
    mov x0, x20
    mov x1, #ST_UNK
    bl state_count
    mov x22, x0
    b .Lrc_metric_cmp
.Lrc_metric_offshare:
    // share = 1000 * offline / total (integer fixed point)
    mov x0, x19
    mov x1, #ST_OFF
    bl state_count
    mov x21, x0
    mov x0, x19
    bl filtered_total
    mov x23, x0
    mov x0, x21
    ldr x1, =1000
    mul x0, x0, x1
    udiv x0, x0, x23
    mov x21, x0                      // share_a
    mov x0, x20
    mov x1, #ST_OFF
    bl state_count
    mov x22, x0
    mov x0, x20
    bl filtered_total
    mov x24, x0
    mov x0, x22
    ldr x1, =1000
    mul x0, x0, x1
    udiv x0, x0, x24
    mov x22, x0                      // share_b
    b .Lrc_metric_cmp
.Lrc_metric_liveshare:
    mov x0, x19
    mov x1, #ST_LIVE
    bl state_count
    mov x21, x0
    mov x0, x19
    bl filtered_total
    mov x23, x0
    mov x0, x21
    ldr x1, =1000
    mul x0, x0, x1
    udiv x0, x0, x23
    mov x21, x0
    mov x0, x20
    mov x1, #ST_LIVE
    bl state_count
    mov x22, x0
    mov x0, x20
    bl filtered_total
    mov x24, x0
    mov x0, x22
    ldr x1, =1000
    mul x0, x0, x1
    udiv x0, x0, x24
    mov x22, x0
    b .Lrc_metric_cmp
.Lrc_metric_cmp:
    // a before b if value_a > value_b, ties broken by login ascending
    cmp x21, x22
    b.gt .Lrc_yes
    b.lt .Lrc_no
    b .Lrc_login
.Lrc_login:
    adrp x0, user_table
    add x0, x0, :lo12:user_table
    mov x1, #USER_STRIDE
    mul x1, x19, x1
    add x0, x0, x1
    adrp x2, user_table
    add x2, x2, :lo12:user_table
    mov x3, #USER_STRIDE
    mul x3, x20, x3
    add x2, x2, x3
    mov x1, x2
    bl strcmp                        // x0 = -1/0/1
    cmp x0, #0
    b.lt .Lrc_yes
    b .Lrc_no
.Lrc_yes:
    mov x0, #1
    b .Lrc_out
.Lrc_no:
    mov x0, #0
.Lrc_out:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// sort_reported — insertion sort the reported[] indices
sort_reported:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, reported
    add x19, x19, :lo12:reported
    adrp x20, reported_count
    add x20, x20, :lo12:reported_count
    ldr x20, [x20]
    mov x21, #1
.Lsr_outer:
    cmp x21, x20
    b.ge .Lsr_done
    ldr x22, [x19, x21, lsl #3]      // key index
    mov x23, x21
.Lsr_inner:
    cbz x23, .Lsr_place
    sub x24, x23, #1
    ldr x25, [x19, x24, lsl #3]      // previous index
    mov x0, x22
    mov x1, x25
    bl reported_cmp                  // x0 = 1 if key sorts before previous
    cbz x0, .Lsr_place
    str x25, [x19, x23, lsl #3]
    mov x23, x24
    b .Lsr_inner
.Lsr_place:
    str x22, [x19, x23, lsl #3]
    add x21, x21, #1
    b .Lsr_outer
.Lsr_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// apply_share_floor — shares_shown detection + the floor, if it acts
apply_share_floor:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    // shares_shown = sort in {5,6} or any column in {5,6}
    adrp x0, sort_id
    add x0, x0, :lo12:sort_id
    ldr x1, [x0]
    mov x2, #0
    cmp x1, #S_OFFSHARE
    b.ge .Lasf_shown
    adrp x3, columns_count
    add x3, x3, :lo12:columns_count
    ldr x4, [x3]
    mov x5, #0
.Lasf_col:
    cmp x5, x4
    b.ge .Lasf_shown_done
    adrp x6, columns
    add x6, x6, :lo12:columns
    ldr x7, [x6, x5, lsl #3]
    cmp x7, #S_OFFSHARE
    b.ge .Lasf_shown
    add x5, x5, #1
    b .Lasf_col
.Lasf_shown:
    mov x2, #1
.Lasf_shown_done:
    adrp x0, shares_shown
    add x0, x0, :lo12:shares_shown
    str x2, [x0]
    adrp x0, share_floor_acted
    add x0, x0, :lo12:share_floor_acted
    str xzr, [x0]
    adrp x0, below_floor
    add x0, x0, :lo12:below_floor
    str xzr, [x0]
    cbz x2, .Lasf_done
    adrp x0, share_floor
    add x0, x0, :lo12:share_floor
    ldr x19, [x0]
    cbz x19, .Lasf_done
    adrp x20, reported
    add x20, x20, :lo12:reported
    adrp x21, reported_count
    add x21, x21, :lo12:reported_count
    ldr x22, [x21]
    mov x23, #0                      // write index
    mov x24, #0                      // read index
    mov x25, #0                      // dropped
.Lasf_keep:
    cmp x24, x22
    b.ge .Lasf_keep_done
    ldr x8, [x20, x24, lsl #3]
    mov x0, x8
    bl filtered_total
    cmp x0, x19
    b.lt .Lasf_drop
    str x8, [x20, x23, lsl #3]
    add x23, x23, #1
    b .Lasf_keep_next
.Lasf_drop:
    add x25, x25, #1
.Lasf_keep_next:
    add x24, x24, #1
    b .Lasf_keep
.Lasf_keep_done:
    str x23, [x21]
    adrp x8, below_floor
    add x8, x8, :lo12:below_floor
    str x25, [x8]
    adrp x8, share_floor_acted
    add x8, x8, :lo12:share_floor_acted
    str x19, [x8]
.Lasf_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// maybe_add_unknown_col — with -B, insert 'unknown' before 'offline-share'
// when any reported user has unknown > 0.
maybe_add_unknown_col:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x0, opt_flags
    add x0, x0, :lo12:opt_flags
    ldr x1, [x0]
    tst x1, #F_BY_STATE
    b.eq .Lmuc_done
    adrp x19, reported
    add x19, x19, :lo12:reported
    adrp x20, reported_count
    add x20, x20, :lo12:reported_count
    ldr x20, [x20]
    mov x21, #0
.Lmuc_loop:
    cmp x21, x20
    b.ge .Lmuc_done
    ldr x22, [x19, x21, lsl #3]
    mov x0, x22
    mov x1, #ST_UNK
    bl state_count
    cbnz x0, .Lmuc_add
    add x21, x21, #1
    b .Lmuc_loop
.Lmuc_add:
    // insert id S_UNK before the first S_OFFSHARE, or append
    adrp x23, columns
    add x23, x23, :lo12:columns
    adrp x24, columns_count
    add x24, x24, :lo12:columns_count
    ldr x24, [x24]
    mov x25, #0
.Lmuc_find:
    cmp x25, x24
    b.ge .Lmuc_insert
    ldr x26, [x23, x25, lsl #3]
    cmp x26, #S_OFFSHARE
    b.eq .Lmuc_insert_at
    add x25, x25, #1
    b .Lmuc_find
.Lmuc_insert_at:
    mov x26, x24
.Lmuc_shift:
    cmp x26, x25
    b.le .Lmuc_shift_done
    sub x27, x26, #1
    ldr x28, [x23, x27, lsl #3]
    str x28, [x23, x26, lsl #3]
    mov x26, x27
    b .Lmuc_shift
.Lmuc_shift_done:
    mov x27, #S_UNK
    str x27, [x23, x25, lsl #3]
    add x24, x24, #1
    adrp x28, columns_count
    add x28, x28, :lo12:columns_count
    str x24, [x28]
    b .Lmuc_done
.Lmuc_insert:
    adrp x28, columns
    add x28, x28, :lo12:columns
    ldr x27, [x28]
    mov x26, #S_UNK
    str x26, [x28, x27, lsl #3]
    add x27, x27, #1
    adrp x28, columns_count
    add x28, x28, :lo12:columns_count
    str x27, [x28]
.Lmuc_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// choose_limit — the row cap and its source (0 = none, 1 = --top, 2 = terminal)
choose_limit:
    adrp x0, limit
    add x0, x0, :lo12:limit
    str xzr, [x0]
    adrp x0, limit_source
    add x0, x0, :lo12:limit_source
    str xzr, [x0]
    adrp x0, opt_flags
    add x0, x0, :lo12:opt_flags
    ldr x1, [x0]
    tst x1, #F_TOP_GIVEN
    b.eq .Lcl_terminal
    adrp x0, top_n
    add x0, x0, :lo12:top_n
    ldr x2, [x0]
    adrp x3, limit
    add x3, x3, :lo12:limit
    str x2, [x3]
    adrp x3, limit_source
    mov x4, #SRC_TOP
    add x3, x3, :lo12:limit_source
    str x4, [x3]
    ret
.Lcl_terminal:
    // ioctl(STDOUT, TIOCGWINSZ, &winsize); a failure means piped -> unlimited
    mov x0, #STDOUT
    mov x1, #TIOCGWINSZ
    adrp x2, winsize
    add x2, x2, :lo12:winsize
    mov x8, #SYS_IOCTL
    svc #0
    cmp x0, #0
    b.ne .Lcl_unlimited
    adrp x2, winsize
    add x2, x2, :lo12:winsize
    ldrh w3, [x2]
    // reserved rows depend on the header mode and how many rows it has
    adrp x4, header_mode
    add x4, x4, :lo12:header_mode
    ldr x5, [x4]
    cmp x5, #H_FULL
    b.eq .Lcl_res_full
    cmp x5, #H_COMPACT
    b.eq .Lcl_res_compact
    mov x6, #0                       // header none: no reserved rows
    b .Lcl_res_done
.Lcl_res_full:
    adrp x6, header_row_count
    add x6, x6, :lo12:header_row_count
    ldr x6, [x6]
    add x6, x6, #2                   // the files: line and the top: row
    b .Lcl_res_done
.Lcl_res_compact:
    mov x6, #2                       // the compact line and its blank line
.Lcl_res_done:
    // limit = max(rows - (reserved + 8), 5)
    add x6, x6, #8
    sub x3, x3, x6
    cmp x3, #MIN_ADAPTIVE_ROWS
    b.ge .Lcl_lim_ok
    mov x3, #MIN_ADAPTIVE_ROWS
.Lcl_lim_ok:
    adrp x5, limit
    add x5, x5, :lo12:limit
    str x3, [x5]
    adrp x5, limit_source
    mov x4, #SRC_TERMINAL
    add x5, x5, :lo12:limit_source
    str x4, [x5]
    ret
.Lcl_unlimited:
    ret// ============================================================================
// Part 7 — number formatting and the render pipeline
// ============================================================================

// emit2(x0=value, x1=out) -> x1 = out+2 — two zero-padded decimal digits
emit2:
    mov x2, #10
    udiv x3, x0, x2                 // tens
    add x4, x3, #'0'
    strb w4, [x1]
    msub x3, x3, x2, x0             // units
    add x3, x3, #'0'
    strb w3, [x1, #1]
    add x1, x1, #2
    ret

// emit4(x0=value, x1=out) -> x1 = out+4 — four zero-padded decimal digits
emit4:
    mov x2, #1000
    udiv x3, x0, x2                 // thousands
    add x4, x3, #'0'
    strb w4, [x1]
    msub x3, x3, x2, x0             // rem = value % 1000
    mov x2, #100
    udiv x4, x3, x2                 // hundreds
    add x5, x4, #'0'
    strb w5, [x1, #1]
    msub x4, x4, x2, x3             // rem % 100
    mov x2, #10
    udiv x5, x4, x2                 // tens
    add x6, x5, #'0'
    strb w6, [x1, #2]
    msub x5, x5, x2, x4             // units
    add x5, x5, #'0'
    strb w5, [x1, #3]
    add x1, x1, #4
    ret

// fmt_u64(x0=value, x1=buf) -> x0 = first digit ptr, x1 = digit count
fmt_u64:
    add x3, x1, #24                 // write digits downward
    mov x2, #0
    cmp x0, #0
    b.ne .Lfu64_loop
    mov x5, #'0'
    strb w5, [x3, #-1]!
    mov x2, #1
    b .Lfu64_done
.Lfu64_loop:
    mov x4, #10
    udiv x5, x0, x4
    msub x6, x5, x4, x0
    add x6, x6, #'0'
    strb w6, [x3, #-1]!
    add x2, x2, #1
    mov x0, x5
    cbnz x0, .Lfu64_loop
.Lfu64_done:
    mov x0, x3                      // first digit pointer
    mov x1, x2                      // digit count (the documented contract)
    ret

// fmt_comma(x0=value, x1=buf) -> x0 = first digit ptr, x1 = length
//   Thousands separators: 1234 -> "1,234"
fmt_comma:
    add x3, x1, #24
    mov x2, #0
    cmp x0, #0
    b.ne .Lfc_loop
    mov x5, #'0'
    strb w5, [x3, #-1]!
    mov x2, #1
    b .Lfc_digits_done
.Lfc_loop:
    mov x4, #10
    udiv x5, x0, x4
    msub x6, x5, x4, x0
    add x6, x6, #'0'
    strb w6, [x3, #-1]!
    add x2, x2, #1
    mov x0, x5
    cbnz x0, .Lfc_loop
.Lfc_digits_done:
    // x3 = first digit, x2 = count.  Copy to the front, inserting a comma
    // before digit p (1-based from the right) when p > 1 and p % 3 == 1.
    mov x4, x1                      // out
    mov x5, x3                      // src
    mov x6, x2                      // remaining
.Lfc_copy:
    cbz x6, .Lfc_done
    mov x7, x6                       // p = this digit's 1-based position from the right
    cmp x7, x2
    b.eq .Lfc_nocomma               // no comma before the most-significant digit
    mov x8, #3
    udiv x9, x7, x8
    msub x10, x9, x8, x7            // p % 3
    cmp x10, #0
    b.ne .Lfc_nocomma               // comma before p only when p is a multiple of 3
    mov w8, #','
    strb w8, [x4], #1
.Lfc_nocomma:
    ldrb w8, [x5], #1
    strb w8, [x4], #1
    sub x6, x6, #1
    b .Lfc_copy
.Lfc_done:
    mov x0, x1
    sub x1, x4, x1
    ret

// fmt_datetime(x0=ymd, x1=sod, x2=buf) -> x0 = buf, x1 = 19
//   "YYYY-MM-DD HH:MM:SS"
fmt_datetime:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // ymd
    mov x20, x1                     // sod
    mov x21, x2                     // out
    mov x3, #10000
    udiv x22, x19, x3               // y
    mov x0, x22
    mov x1, x21
    bl emit4
    mov w3, #'-'
    strb w3, [x1], #1
    // mo = (ymd/100) % 100
    mov x3, #100
    udiv x4, x19, x3
    udiv x5, x4, x3
    msub x4, x5, x3, x4             // (ymd/100) % 100
    mov x0, x4
    bl emit2
    mov w3, #'-'
    strb w3, [x1], #1
    // d = ymd % 100
    mov x3, #100
    udiv x4, x19, x3
    msub x4, x4, x3, x19
    mov x0, x4
    bl emit2
    mov w3, #' '
    strb w3, [x1], #1
    // h = sod / 3600
    mov x3, #3600
    udiv x4, x20, x3
    mov x0, x4
    bl emit2
    mov w3, #':'
    strb w3, [x1], #1
    // mi = (sod / 60) % 60
    mov x3, #60
    udiv x4, x20, x3
    udiv x5, x4, x3
    msub x4, x5, x3, x4
    mov x0, x4
    bl emit2
    mov w3, #':'
    strb w3, [x1], #1
    // s = sod % 60
    mov x3, #60
    udiv x4, x20, x3
    msub x4, x4, x3, x20
    mov x0, x4
    bl emit2
    mov x0, x21
    mov x1, #19
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// fmt_share(x0=state, x1=total, x2=buf) -> x0 = buf, x1 = len
//   "NN.N%" with half-up rounding in integer math.
fmt_share:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // state
    mov x20, x1                     // total
    adrp x21, out_buf
    add x21, x21, :lo12:out_buf
    cbz x20, .Lfs_zero
    // tenths = round(1000*state/total) = (2*1000*state + total) / (2*total)
    ldr x22, =1000
    mul x19, x19, x22
    mov x22, #2
    mul x19, x19, x22
    add x19, x19, x20
    mov x22, #2
    mul x20, x20, x22
    udiv x19, x19, x20              // tenths
    b .Lfs_emit
.Lfs_zero:
    mov x19, #0
.Lfs_emit:
    mov x22, #10
    udiv x0, x19, x22               // whole
    msub x21, x0, x22, x19          // frac (x21 = out_buf is no longer needed)
    mov x20, x0
    mov x0, x20
    adrp x1, out_buf
    add x1, x1, :lo12:out_buf
    bl fmt_u64                      // x0 = ptr, x1 = len
    mov x2, x1
    adrp x3, out_buf
    add x3, x3, :lo12:out_buf
    cmp x0, x3
    b.eq .Lfs_moved
    mov x4, #0
.Lfs_move:
    cmp x4, x2
    b.ge .Lfs_moved
    ldrb w5, [x0, x4]
    strb w5, [x3, x4]
    add x4, x4, #1
    b .Lfs_move
.Lfs_moved:
    add x3, x3, x2
    mov w4, #'.'
    strb w4, [x3], #1
    add w4, w21, #'0'
    strb w4, [x3], #1
    mov w4, #'%'
    strb w4, [x3], #1
    adrp x0, out_buf
    add x0, x0, :lo12:out_buf
    sub x1, x3, x0
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret// ============================================================================
// Part 8 — string helpers and the provenance header rows
// ============================================================================

// str_copy_adv(x0=dst, x1=src) -> x0 = dst + len(src)  (no NUL written)
str_copy_adv:
    mov x2, #0
.Lsca:
    ldrb w3, [x1, x2]
    cbz w3, .Lsca_done
    strb w3, [x0, x2]
    add x2, x2, #1
    b .Lsca
.Lsca_done:
    add x0, x0, x2
    ret

// mem_copy_adv(x0=dst, x1=src, x2=len) -> x0 = dst + len
mem_copy_adv:
    mov x3, #0
.Lmca:
    cmp x3, x2
    b.ge .Lmca_done
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    b .Lmca
.Lmca_done:
    add x0, x0, x2
    ret

// pad_spaces(x0=dst, x1=count) -> x0 = dst + count
pad_spaces:
    cmp x1, #0
    b.le .Lpsp_none                 // never move backwards: a value longer
                                    // than the width cap simply overruns its
                                    // neighbour, exactly like Python's ljust
    mov x2, #0
.Lpsp:
    cmp x2, x1
    b.ge .Lpsp_done
    mov w3, #' '
    strb w3, [x0, x2]
    add x2, x2, #1
    b .Lpsp
.Lpsp_done:
    add x0, x0, x1
    ret
.Lpsp_none:
    ret                             // x0 unchanged (no padding needed)

// num_copy_adv(x0=dst, x1=value, x2=comma) -> x0 = dst + len
num_copy_adv:
    stp x30, xzr, [sp, #-16]!
    stp x0, x2, [sp, #-16]!         // dst, comma
    mov x0, x1                      // value
    adrp x1, fmt_buf
    add x1, x1, :lo12:fmt_buf
    cbz x2, .Lnca_plain
    bl fmt_comma                    // x0 = ptr, x1 = len
    b .Lnca_copy
.Lnca_plain:
    bl fmt_u64
.Lnca_copy:
    mov x2, x1
    ldp x3, x4, [sp], #16           // dst = x3
    mov x1, x0
    mov x0, x3
    bl mem_copy_adv
    ldp x30, xzr, [sp], #16
    ret

// share_copy_adv(x0=dst, x1=state, x2=total) -> x0 = dst + len
share_copy_adv:
    stp x30, xzr, [sp, #-16]!
    stp x0, x2, [sp, #-16]!
    mov x0, x1
    mov x1, x2
    adrp x2, fmt_buf
    add x2, x2, :lo12:fmt_buf
    bl fmt_share                    // x0 = ptr, x1 = len
    mov x2, x1
    ldp x3, x4, [sp], #16
    mov x1, x0
    mov x0, x3
    bl mem_copy_adv
    ldp x30, xzr, [sp], #16
    ret

// emit_out(x0=len) — write out_buf[0..len) plus '\n' to stdout
emit_out:
    adrp x2, out_buf
    add x2, x2, :lo12:out_buf
    add x3, x2, x0                   // the '\n' position
    mov w4, #'\n'
    strb w4, [x3]
    mov x1, x2                       // buf = out_buf base
    add x2, x0, #1                   // total length = len + 1
    mov x0, #STDOUT
    b write_all

// hv_slot() -> x0 = the value slot for the current (next) header row
hv_slot:
    adrp x0, header_row_count
    add x0, x0, :lo12:header_row_count
    ldr x0, [x0]
    adrp x1, header_value_arena
    add x1, x1, :lo12:header_value_arena
    mov x2, #HVALUE_SIZE
    mul x0, x0, x2
    add x0, x1, x0
    ret

// hc_slot() -> x0 = the compact slot for the current (next) header row
hc_slot:
    adrp x0, header_row_count
    add x0, x0, :lo12:header_row_count
    ldr x0, [x0]
    adrp x1, header_compact_arena
    add x1, x1, :lo12:header_compact_arena
    mov x2, #HCOMPACT_SIZE
    mul x0, x0, x2
    add x0, x1, x0
    ret

// hrow_push(x0=label, x1=value, x2=source, x3=compact) — append one row
hrow_push:
    adrp x4, header_rows
    add x4, x4, :lo12:header_rows
    adrp x5, header_row_count
    add x5, x5, :lo12:header_row_count
    ldr x6, [x5]
    mov x7, #HROW_STRIDE
    mul x7, x6, x7
    add x4, x4, x7
    str x0, [x4]
    str x1, [x4, #8]
    str x2, [x4, #16]
    str x3, [x4, #24]
    add x6, x6, #1
    str x6, [x5]
    ret

// state_name(x0=state) -> x0 = "live" / "offline" / "unknown"
state_name:
    cmp x0, #ST_LIVE
    b.eq .Lsn_live
    cmp x0, #ST_OFF
    b.eq .Lsn_off
    adrp x0, s_unknown
    add x0, x0, :lo12:s_unknown
    ret
.Lsn_live:
    adrp x0, s_live
    add x0, x0, :lo12:s_live
    ret
.Lsn_off:
    adrp x0, s_offline
    add x0, x0, :lo12:s_offline
    ret

// column_name(x0=id) -> x0 = the metric name (for the columns row)
column_name:
    cmp x0, #S_LOGIN
    b.eq .Lcn_login
    cmp x0, #S_LIVE
    b.eq .Lcn_live
    cmp x0, #S_OFF
    b.eq .Lcn_off
    cmp x0, #S_UNK
    b.eq .Lcn_unk
    cmp x0, #S_OFFSHARE
    b.eq .Lcn_offshare
    adrp x0, s_liveshare
    add x0, x0, :lo12:s_liveshare
    ret
.Lcn_login:
    adrp x0, s_login
    add x0, x0, :lo12:s_login
    ret
.Lcn_live:
    adrp x0, s_live
    add x0, x0, :lo12:s_live
    ret
.Lcn_off:
    adrp x0, s_offline
    add x0, x0, :lo12:s_offline
    ret
.Lcn_unk:
    adrp x0, s_unknown
    add x0, x0, :lo12:s_unknown
    ret
.Lcn_offshare:
    adrp x0, s_offshare
    add x0, x0, :lo12:s_offshare
    ret

// column_header(x0=id) -> x0 = the table header name
column_header:
    cmp x0, #S_LIVE
    b.eq .Lch_live
    cmp x0, #S_OFF
    b.eq .Lch_off
    cmp x0, #S_UNK
    b.eq .Lch_unk
    cmp x0, #S_OFFSHARE
    b.eq .Lch_offshare
    adrp x0, s_livepercent
    add x0, x0, :lo12:s_livepercent
    ret
.Lch_live:
    adrp x0, s_live
    add x0, x0, :lo12:s_live
    ret
.Lch_off:
    adrp x0, s_offline
    add x0, x0, :lo12:s_offline
    ret
.Lch_unk:
    adrp x0, s_unknown
    add x0, x0, :lo12:s_unknown
    ret
.Lch_offshare:
    adrp x0, s_offpercent
    add x0, x0, :lo12:s_offpercent
    ret

// build_header_rows — the provenance block (rows 1..11; the top row is
// appended later, after choose_limit).  Callee-saved: x19-x28.
build_header_rows:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x0, header_row_count
    add x0, x0, :lo12:header_row_count
    str xzr, [x0]

    // ---- channel ----
    adrp x0, s_label_channel
    add x0, x0, :lo12:s_label_channel
    adrp x1, channel_name
    add x1, x1, :lo12:channel_name
    adrp x2, s_src_channel
    add x2, x2, :lo12:s_src_channel
    adrp x3, channel_name
    add x3, x3, :lo12:channel_name
    bl hrow_push

    // ---- logs dir ----
    adrp x0, s_label_logsdir
    add x0, x0, :lo12:s_label_logsdir
    adrp x1, logs_dir_arg
    add x1, x1, :lo12:logs_dir_arg
    adrp x2, s_src_logsdir
    add x2, x2, :lo12:s_src_logsdir
    mov x3, #0                       // no compact form
    bl hrow_push

    // ---- begin ----
    bl hv_slot
    mov x19, x0                      // value slot
    adrp x0, begin_ymd
    add x0, x0, :lo12:begin_ymd
    ldr x9, [x0]                     // ymd
    adrp x0, begin_sod
    add x0, x0, :lo12:begin_sod
    ldr x2, [x0]                     // sod
    mov x0, x9
    mov x1, x2
    mov x2, x19
    bl fmt_datetime                  // x0 = slot, x1 = 19
    // source: --begin / --since <raw> before end / default: earliest log file
    adrp x20, opt_flags
    add x20, x20, :lo12:opt_flags
    ldr x21, [x20]
    tst x21, #F_BEGIN_GIVEN
    b.eq .Lbh_begin_since
    adrp x20, s_src_begin
    add x20, x20, :lo12:s_src_begin
    b .Lbh_begin_src_done
.Lbh_begin_since:
    tst x21, #F_SINCE_GIVEN
    b.eq .Lbh_begin_default
    // "--since <raw> before end" into begin_source_buf (x0 runs through it)
    adrp x0, begin_source_buf
    add x0, x0, :lo12:begin_source_buf
    adrp x1, s_src_since_pre
    add x1, x1, :lo12:s_src_since_pre
    bl str_copy_adv
    adrp x1, since_arg
    add x1, x1, :lo12:since_arg
    bl str_copy_adv
    adrp x1, s_src_before_end
    add x1, x1, :lo12:s_src_before_end
    bl str_copy_adv
    adrp x20, begin_source_buf
    add x20, x20, :lo12:begin_source_buf
    b .Lbh_begin_src_done
.Lbh_begin_default:
    adrp x20, s_src_default_earliest
    add x20, x20, :lo12:s_src_default_earliest
.Lbh_begin_src_done:
    // compact = window span, formatted into the compact slot
    bl hc_slot
    mov x21, x0
    mov x0, x21
    bl fmt_window_span               // x0 = advanced slot (ignored)
    adrp x0, s_label_begin
    add x0, x0, :lo12:s_label_begin
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl hrow_push

    // ---- end ----
    bl hv_slot
    mov x19, x0
    adrp x0, end_ymd
    add x0, x0, :lo12:end_ymd
    ldr x9, [x0]                     // ymd
    adrp x0, end_sod
    add x0, x0, :lo12:end_sod
    ldr x2, [x0]                     // sod
    mov x0, x9
    mov x1, x2
    mov x2, x19
    bl fmt_datetime
    adrp x20, opt_flags
    add x20, x20, :lo12:opt_flags
    ldr x21, [x20]
    tst x21, #F_END_GIVEN
    b.eq .Lbh_end_default
    adrp x20, s_src_end
    add x20, x20, :lo12:s_src_end
    b .Lbh_end_push
.Lbh_end_default:
    adrp x20, s_src_default_now
    add x20, x20, :lo12:s_src_default_now
.Lbh_end_push:
    adrp x0, s_label_end
    add x0, x0, :lo12:s_label_end
    mov x1, x19
    mov x2, x20
    mov x3, #0
    bl hrow_push

    // ---- threshold ----
    bl hv_slot
    mov x19, x0
    adrp x1, s_ge
    add x1, x1, :lo12:s_ge
    bl str_copy_adv
    adrp x1, min_count
    add x1, x1, :lo12:min_count
    ldr x1, [x1]
    mov x2, #0                       // plain number
    bl num_copy_adv
    adrp x1, s_msg_s
    add x1, x1, :lo12:s_msg_s
    bl str_copy_adv
    adrp x20, opt_flags
    add x20, x20, :lo12:opt_flags
    ldr x21, [x20]
    tst x21, #F_MIN_GIVEN
    b.eq .Lbh_min_builtin
    adrp x20, s_src_mincount
    add x20, x20, :lo12:s_src_mincount
    b .Lbh_min_push
.Lbh_min_builtin:
    adrp x20, s_src_builtin
    add x20, x20, :lo12:s_src_builtin
.Lbh_min_push:
    // compact = ">=N"
    bl hc_slot
    mov x21, x0
    adrp x1, s_ge_compact
    add x1, x1, :lo12:s_ge_compact
    bl str_copy_adv
    adrp x1, min_count
    add x1, x1, :lo12:min_count
    ldr x1, [x1]
    mov x2, #0
    bl num_copy_adv
    adrp x0, s_label_threshold
    add x0, x0, :lo12:s_label_threshold
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl hrow_push

    // ---- state ----
    // header states = global minus excluded
    adrp x19, g_live
    add x19, x19, :lo12:g_live
    ldr x20, [x19]
    adrp x21, e_live
    add x21, x21, :lo12:e_live
    ldr x22, [x21]
    sub x23, x20, x22                // header live
    adrp x19, g_off
    add x19, x19, :lo12:g_off
    ldr x20, [x19]
    adrp x21, e_off
    add x21, x21, :lo12:e_off
    ldr x22, [x21]
    sub x24, x20, x22                // header offline
    adrp x19, g_unk
    add x19, x19, :lo12:g_unk
    ldr x20, [x19]
    adrp x21, e_unk
    add x21, x21, :lo12:e_unk
    ldr x22, [x21]
    sub x25, x20, x22                // header unknown
    orr x26, x23, x24
    orr x26, x26, x25
    cbz x26, .Lbh_no_state
    // value = "<name> <comma>" joined with " / " over nonzero states
    bl hv_slot
    mov x19, x0                      // value slot
    mov x26, x0                      // running pointer
    mov x27, #0                      // first-written flag
    cbnz x23, .Lbh_st_live
    b .Lbh_st_off
.Lbh_st_live:
    cbz x27, .Lbh_st_live_plain
    mov x0, x26
    adrp x1, s_sep_slash
    add x1, x1, :lo12:s_sep_slash
    bl str_copy_adv
    mov x26, x0
.Lbh_st_live_plain:
    mov x0, x26
    adrp x1, s_live
    add x1, x1, :lo12:s_live
    bl str_copy_adv
    mov x26, x0
    mov w3, #' '
    strb w3, [x26], #1
    mov x0, x26
    mov x1, x23
    mov x2, #1                       // comma
    bl num_copy_adv
    mov x26, x0
    mov x27, #1
.Lbh_st_off:
    cbz x24, .Lbh_st_unk
    cbz x27, .Lbh_st_off_plain
    mov x0, x26
    adrp x1, s_sep_slash
    add x1, x1, :lo12:s_sep_slash
    bl str_copy_adv
    mov x26, x0
.Lbh_st_off_plain:
    mov x0, x26
    adrp x1, s_offline
    add x1, x1, :lo12:s_offline
    bl str_copy_adv
    mov x26, x0
    mov w3, #' '
    strb w3, [x26], #1
    mov x0, x26
    mov x1, x24
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    mov x27, #1
.Lbh_st_unk:
    cbz x25, .Lbh_st_done
    cbz x27, .Lbh_st_unk_plain
    mov x0, x26
    adrp x1, s_sep_slash
    add x1, x1, :lo12:s_sep_slash
    bl str_copy_adv
    mov x26, x0
.Lbh_st_unk_plain:
    mov x0, x26
    adrp x1, s_unknown
    add x1, x1, :lo12:s_unknown
    bl str_copy_adv
    mov x26, x0
    mov w3, #' '
    strb w3, [x26], #1
    mov x0, x26
    mov x1, x25
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
.Lbh_st_done:
    // source: "--<filter> keeps <state>" or "not filtered"
    adrp x28, state_filter
    add x28, x28, :lo12:state_filter
    ldr x22, [x28]
    cbz x22, .Lbh_st_not_filtered
    adrp x26, state_source_buf
    add x26, x26, :lo12:state_source_buf
    mov w3, #'-'
    strb w3, [x26]
    mov w3, #'-'
    strb w3, [x26, #1]
    add x26, x26, #2
    mov x0, x22
    bl state_name                   // x0 = name ptr
    mov x1, x0
    mov x0, x26
    bl str_copy_adv
    mov x26, x0
    mov x0, x26
    adrp x1, s_keeps
    add x1, x1, :lo12:s_keeps
    bl str_copy_adv
    mov x26, x0
    mov x0, x22
    bl state_name
    mov x1, x0
    mov x0, x26
    bl str_copy_adv
    adrp x26, state_source_buf
    add x26, x26, :lo12:state_source_buf
    mov x20, x26
    b .Lbh_st_src_done
.Lbh_st_not_filtered:
    adrp x20, s_not_filtered
    add x20, x20, :lo12:s_not_filtered
.Lbh_st_src_done:
    // compact = "<filter> only" or the space-joined split
    bl hc_slot
    mov x21, x0
    adrp x28, state_filter
    add x28, x28, :lo12:state_filter
    ldr x22, [x28]
    cbz x22, .Lbh_st_compact_split
    mov x0, x22
    bl state_name
    mov x1, x0
    mov x0, x21
    bl str_copy_adv
    adrp x1, s_only
    add x1, x1, :lo12:s_only
    bl str_copy_adv
    b .Lbh_st_push
.Lbh_st_compact_split:
    mov x26, x21                     // running
    mov x27, #0                      // first flag
    cbnz x23, .Lbh_cs_live
    b .Lbh_cs_off
.Lbh_cs_live:
    cbz x27, .Lbh_cs_live_plain
    mov w3, #' '
    strb w3, [x26], #1
.Lbh_cs_live_plain:
    mov x0, x26
    adrp x1, s_live
    add x1, x1, :lo12:s_live
    bl str_copy_adv
    mov x26, x0
    mov w3, #' '
    strb w3, [x26], #1
    mov x0, x26
    mov x1, x23
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    mov x27, #1
.Lbh_cs_off:
    cbz x24, .Lbh_cs_unk
    cbz x27, .Lbh_cs_off_plain
    mov w3, #' '
    strb w3, [x26], #1
.Lbh_cs_off_plain:
    mov x0, x26
    adrp x1, s_offline
    add x1, x1, :lo12:s_offline
    bl str_copy_adv
    mov x26, x0
    mov w3, #' '
    strb w3, [x26], #1
    mov x0, x26
    mov x1, x24
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    mov x27, #1
.Lbh_cs_unk:
    cbz x25, .Lbh_cs_done
    cbz x27, .Lbh_cs_unk_plain
    mov w3, #' '
    strb w3, [x26], #1
.Lbh_cs_unk_plain:
    mov x0, x26
    adrp x1, s_unknown
    add x1, x1, :lo12:s_unknown
    bl str_copy_adv
    mov x26, x0
    mov w3, #' '
    strb w3, [x26], #1
    mov x0, x26
    mov x1, x25
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
.Lbh_cs_done:
.Lbh_st_push:
    adrp x0, s_label_state
    add x0, x0, :lo12:s_label_state
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl hrow_push
    b .Lbh_exclude
.Lbh_no_state:
    b .Lbh_exclude

    // ---- exclude ----
.Lbh_exclude:
    adrp x0, excluded_count
    add x0, x0, :lo12:excluded_count
    ldr x1, [x0]
    cbz x1, .Lbh_columns
    bl hv_slot
    mov x19, x0                      // value slot
    mov x26, x0                      // running
    adrp x1, excluded_count
    add x1, x1, :lo12:excluded_count
    ldr x1, [x1]
    mov x2, #0                       // plain
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_login_s
    add x1, x1, :lo12:s_login_s
    bl str_copy_adv
    mov x26, x0
    adrp x1, excluded_appeared_count
    add x1, x1, :lo12:excluded_appeared_count
    ldr x1, [x1]
    mov x2, #0
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_in_range_colon
    add x1, x1, :lo12:s_in_range_colon
    bl str_copy_adv
    mov x26, x0
    // preview: first 3 sorted excluded names (fills excl_sorted[])
    bl sort_excluded_preview
    adrp x21, excluded_count
    add x21, x21, :lo12:excluded_count
    ldr x22, [x21]
    mov x23, #0
.Lbh_exc_preview:
    cmp x23, x22
    b.ge .Lbh_exc_preview_done
    cmp x23, #3
    b.ge .Lbh_exc_more
    adrp x24, excl_sorted
    add x24, x24, :lo12:excl_sorted
    ldr x25, [x24, x23, lsl #3]
    mov x0, x26
    mov x1, x25
    bl str_copy_adv
    mov x26, x0
    add x23, x23, #1
    cmp x23, x22
    b.ge .Lbh_exc_preview_done
    cmp x23, #3
    b.ge .Lbh_exc_more
    mov x0, x26
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl str_copy_adv
    mov x26, x0
    b .Lbh_exc_preview
.Lbh_exc_more:
    mov x0, x26
    adrp x1, s_comma_plus
    add x1, x1, :lo12:s_comma_plus
    bl str_copy_adv
    mov x26, x0
    sub x1, x22, #3
    mov x2, #0                       // plain count
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_more
    add x1, x1, :lo12:s_more
    bl str_copy_adv
    mov x26, x0
.Lbh_exc_preview_done:
    // source: joined exclusion sources into excl_sources_buf
    adrp x26, excl_sources_buf
    add x26, x26, :lo12:excl_sources_buf
    mov x27, #0                      // first flag
    adrp x20, x_added
    add x20, x20, :lo12:x_added
    ldr x21, [x20]
    cbz x21, .Lbh_exc_src_bcast
    mov x0, x26
    adrp x1, s_flag_exclude
    add x1, x1, :lo12:s_flag_exclude
    bl str_copy_adv
    mov x26, x0
    mov x27, #1
.Lbh_exc_src_bcast:
    adrp x20, opt_flags
    add x20, x20, :lo12:opt_flags
    ldr x21, [x20]
    tst x21, #F_BROADCASTER
    b.eq .Lbh_exc_src_minus
    cbz x27, .Lbh_exc_src_bcast_sep
    mov x0, x26
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl str_copy_adv
    mov x26, x0
.Lbh_exc_src_bcast_sep:
    mov x0, x26
    adrp x1, s_flag_broadcaster
    add x1, x1, :lo12:s_flag_broadcaster
    bl str_copy_adv
    mov x26, x0
    mov x27, #1
.Lbh_exc_src_minus:
    adrp x20, include_removed
    add x20, x20, :lo12:include_removed
    ldr x21, [x20]
    cbz x21, .Lbh_exc_src_done
    cbz x27, .Lbh_exc_src_minus_sep
    mov x0, x26
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl str_copy_adv
    mov x26, x0
.Lbh_exc_src_minus_sep:
    mov x0, x26
    adrp x1, s_minus_include_pre
    add x1, x1, :lo12:s_minus_include_pre
    bl str_copy_adv
    mov x26, x0
    adrp x1, include_removed
    add x1, x1, :lo12:include_removed
    ldr x1, [x1]
    mov x2, #1                       // comma
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_paren
    add x1, x1, :lo12:s_paren
    bl str_copy_adv
    mov x26, x0
.Lbh_exc_src_done:
    adrp x20, excl_sources_buf
    add x20, x20, :lo12:excl_sources_buf
    // compact = "-<M> excl" only when M (appeared) > 0
    adrp x21, excluded_appeared_count
    add x21, x21, :lo12:excluded_appeared_count
    ldr x22, [x21]
    cbz x22, .Lbh_exc_no_compact
    bl hc_slot
    mov x21, x0
    add x21, x21, #0
    mov w3, #'-'
    strb w3, [x21], #1
    mov x0, x21
    mov x1, x22
    mov x2, #0
    bl num_copy_adv
    adrp x1, s_excl
    add x1, x1, :lo12:s_excl
    bl str_copy_adv
    mov x3, x21                       // compact slot (unused; value irrelevant)
    b .Lbh_exc_push
.Lbh_exc_no_compact:
    mov x3, #0
.Lbh_exc_push:
    adrp x0, s_label_exclude
    add x0, x0, :lo12:s_label_exclude
    mov x1, x19
    mov x2, x20
    bl hrow_push
    b .Lbh_columns

    // ---- columns ----
.Lbh_columns:
    adrp x0, columns_count
    add x0, x0, :lo12:columns_count
    ldr x1, [x0]
    cbz x1, .Lbh_sort
    bl hv_slot
    mov x19, x0                      // value slot
    mov x26, x0                      // running
    adrp x1, s_count
    add x1, x1, :lo12:s_count
    bl str_copy_adv
    mov x26, x0
    adrp x21, columns_count
    add x21, x21, :lo12:columns_count
    ldr x22, [x21]
    mov x23, #0
.Lbh_col_loop:
    cmp x23, x22
    b.ge .Lbh_col_done
    mov x0, x26
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl str_copy_adv
    mov x26, x0
    adrp x24, columns
    add x24, x24, :lo12:columns
    ldr x25, [x24, x23, lsl #3]
    mov x0, x25
    bl column_name
    mov x1, x0
    mov x0, x26
    bl str_copy_adv
    mov x26, x0
    add x23, x23, #1
    b .Lbh_col_loop
.Lbh_col_done:
    adrp x20, columns_source
    add x20, x20, :lo12:columns_source
    ldr x21, [x20]
    cmp x21, #1
    b.eq .Lbh_col_src_bystate
    cmp x21, #2
    b.eq .Lbh_col_src_show
    cmp x21, #3
    b.eq .Lbh_col_src_both
    b .Lbh_sort
.Lbh_col_src_bystate:
    adrp x20, s_src_bystate
    add x20, x20, :lo12:s_src_bystate
    b .Lbh_col_push
.Lbh_col_src_show:
    adrp x20, s_src_show
    add x20, x20, :lo12:s_src_show
    b .Lbh_col_push
.Lbh_col_src_both:
    adrp x20, s_src_bystate_show
    add x20, x20, :lo12:s_src_bystate_show
.Lbh_col_push:
    adrp x0, s_label_columns
    add x0, x0, :lo12:s_label_columns
    mov x1, x19
    mov x2, x20
    mov x3, #0
    bl hrow_push
    b .Lbh_sort

    // ---- sort ----
.Lbh_sort:
    adrp x0, sort_id
    add x0, x0, :lo12:sort_id
    ldr x1, [x0]
    cbz x1, .Lbh_floor
    bl hv_slot
    mov x19, x0                      // value slot
    adrp x0, sort_id
    add x0, x0, :lo12:sort_id
    ldr x0, [x0]                     // reload (hv_slot clobbers x0-x2)
    bl column_name
    mov x1, x0
    mov x0, x19
    bl str_copy_adv
    adrp x20, opt_flags
    add x20, x20, :lo12:opt_flags
    ldr x21, [x20]
    tst x21, #F_SORT_GIVEN
    b.eq .Lbh_sort_src_default
    adrp x20, s_src_sort
    add x20, x20, :lo12:s_src_sort
    b .Lbh_sort_push
.Lbh_sort_src_default:
    adrp x20, s_src_default
    add x20, x20, :lo12:s_src_default
.Lbh_sort_push:
    // compact = "by <name>"
    bl hc_slot
    mov x21, x0
    adrp x1, s_by
    add x1, x1, :lo12:s_by
    bl str_copy_adv
    adrp x0, sort_id
    add x0, x0, :lo12:sort_id
    ldr x0, [x0]
    bl column_name
    mov x1, x0
    mov x0, x21
    bl str_copy_adv
    adrp x0, s_label_sort
    add x0, x0, :lo12:s_label_sort
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl hrow_push
    b .Lbh_floor

    // ---- share floor ----
.Lbh_floor:
    adrp x0, share_floor_acted
    add x0, x0, :lo12:share_floor_acted
    ldr x1, [x0]
    cbnz x1, .Lbh_floor_acted
    adrp x0, opt_flags
    add x0, x0, :lo12:opt_flags
    ldr x1, [x0]
    tst x1, #F_FLOOR_GIVEN
    b.eq .Lbh_unreadable
    // floor given but did not act
    adrp x0, shares_shown
    add x0, x0, :lo12:shares_shown
    ldr x1, [x0]
    cbz x1, .Lbh_floor_unused
    // floor given as 0 with shares shown -> "disabled"
    bl hv_slot
    mov x19, x0
    adrp x1, s_floor_off
    add x1, x1, :lo12:s_floor_off
    bl str_copy_adv
    bl hc_slot
    mov x21, x0
    adrp x1, s_floor_off_compact
    add x1, x1, :lo12:s_floor_off_compact
    bl str_copy_adv
    adrp x20, s_src_floor
    add x20, x20, :lo12:s_src_floor
    adrp x0, s_label_floor
    add x0, x0, :lo12:s_label_floor
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl hrow_push
    b .Lbh_unreadable
.Lbh_floor_unused:
    bl hv_slot
    mov x19, x0
    adrp x1, s_floor_unused
    add x1, x1, :lo12:s_floor_unused
    bl str_copy_adv
    bl hc_slot
    mov x21, x0
    adrp x1, s_floor_unused_compact
    add x1, x1, :lo12:s_floor_unused_compact
    bl str_copy_adv
    adrp x20, s_src_floor
    add x20, x20, :lo12:s_src_floor
    adrp x0, s_label_floor
    add x0, x0, :lo12:s_label_floor
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl hrow_push
    b .Lbh_unreadable
.Lbh_floor_acted:
    bl hv_slot
    mov x19, x0
    mov x26, x0
    adrp x1, s_ge
    add x1, x1, :lo12:s_ge
    bl str_copy_adv
    mov x26, x0
    adrp x1, share_floor_acted
    add x1, x1, :lo12:share_floor_acted
    ldr x1, [x1]
    mov x2, #1                       // comma
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_floor_act_mid
    add x1, x1, :lo12:s_floor_act_mid
    bl str_copy_adv
    mov x26, x0
    adrp x1, below_floor
    add x1, x1, :lo12:below_floor
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_floor_act_suf
    add x1, x1, :lo12:s_floor_act_suf
    bl str_copy_adv
    mov x26, x0
    adrp x20, opt_flags
    add x20, x20, :lo12:opt_flags
    ldr x21, [x20]
    tst x21, #F_FLOOR_GIVEN
    b.eq .Lbh_floor_src_builtin
    adrp x20, s_src_floor
    add x20, x20, :lo12:s_src_floor
    b .Lbh_floor_push
.Lbh_floor_src_builtin:
    adrp x20, s_src_builtin
    add x20, x20, :lo12:s_src_builtin
.Lbh_floor_push:
    // compact = "floor >=N, -M"
    bl hc_slot
    mov x21, x0
    mov x26, x0
    adrp x1, s_floor_compact_pre
    add x1, x1, :lo12:s_floor_compact_pre
    bl str_copy_adv
    mov x26, x0
    adrp x1, share_floor_acted
    add x1, x1, :lo12:share_floor_acted
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_floor_compact_mid
    add x1, x1, :lo12:s_floor_compact_mid
    bl str_copy_adv
    mov x26, x0
    adrp x1, below_floor
    add x1, x1, :lo12:below_floor
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    adrp x0, s_label_floor
    add x0, x0, :lo12:s_label_floor
    mov x1, x19
    mov x2, x20
    mov x3, x21
    bl hrow_push
    b .Lbh_unreadable

    // ---- unreadable ----
.Lbh_unreadable:
    adrp x0, unreadable_count
    add x0, x0, :lo12:unreadable_count
    ldr x1, [x0]
    cbz x1, .Lbh_done
    bl hv_slot
    mov x19, x0
    mov x26, x0
    adrp x1, unreadable_count
    add x1, x1, :lo12:unreadable_count
    ldr x1, [x1]
    mov x2, #0                       // plain
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_files_skipped
    add x1, x1, :lo12:s_files_skipped
    bl str_copy_adv
    mov x26, x0
    adrp x21, unreadable_count
    add x21, x21, :lo12:unreadable_count
    ldr x22, [x21]
    mov x23, #0
.Lbh_unr_loop:
    cmp x23, x22
    b.ge .Lbh_unr_names_done
    cmp x23, #2
    b.ge .Lbh_unr_more
    adrp x24, unreadable
    add x24, x24, :lo12:unreadable
    mov x25, #16
    mul x25, x23, x25
    add x24, x24, x25
    ldr x25, [x24]                   // name ptr
    mov x0, x26
    mov x1, x25
    bl str_copy_adv
    mov x26, x0
    add x23, x23, #1
    cmp x23, x22
    b.ge .Lbh_unr_names_done
    cmp x23, #2
    b.ge .Lbh_unr_more
    mov x0, x26
    adrp x1, comma_space
    add x1, x1, :lo12:comma_space
    bl str_copy_adv
    mov x26, x0
    b .Lbh_unr_loop
.Lbh_unr_more:
    mov x0, x26
    adrp x1, s_comma_plus
    add x1, x1, :lo12:s_comma_plus
    bl str_copy_adv
    mov x26, x0
    sub x1, x22, #2
    mov x2, #0
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_more
    add x1, x1, :lo12:s_more
    bl str_copy_adv
    mov x26, x0
    b .Lbh_unr_names_done
.Lbh_unr_names_done:
    adrp x24, unreadable
    add x24, x24, :lo12:unreadable
    ldr x25, [x24, #8]               // reason id of the first entry
    mov x0, x26
    adrp x1, s_paren_open
    add x1, x1, :lo12:s_paren_open
    bl str_copy_adv
    mov x26, x0
    cmp x25, #R_TOO_LARGE
    b.eq .Lbh_unr_reason_large
    adrp x1, s_reason_cannot_read
    add x1, x1, :lo12:s_reason_cannot_read
    b .Lbh_unr_reason_copy
.Lbh_unr_reason_large:
    adrp x1, s_reason_too_large
    add x1, x1, :lo12:s_reason_too_large
.Lbh_unr_reason_copy:
    mov x0, x26
    bl str_copy_adv
    mov x26, x0
    adrp x1, s_paren
    add x1, x1, :lo12:s_paren
    bl str_copy_adv
    mov x26, x0
    // compact = "<N> unread"
    bl hc_slot
    mov x21, x0
    adrp x1, unreadable_count
    add x1, x1, :lo12:unreadable_count
    ldr x1, [x1]
    mov x2, #0
    bl num_copy_adv
    adrp x1, s_unread
    add x1, x1, :lo12:s_unread
    bl str_copy_adv
    adrp x0, s_label_unreadable
    add x0, x0, :lo12:s_label_unreadable
    mov x1, x19
    adrp x2, s_not_counted
    add x2, x2, :lo12:s_not_counted
    mov x3, x21
    bl hrow_push
.Lbh_done:
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret// ============================================================================
// Part 9 — window span, excluded-preview sort, top row, report orchestrator
// ============================================================================

// fmt_md_hm(x0=dst, x1=ymd, x2=sod) -> x0 = dst + 11 — "MM-DD HH:MM"
fmt_md_hm:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x1                     // ymd
    mov x20, x2                     // sod
    mov x21, x0                     // dst
    mov x3, #100
    udiv x4, x19, x3
    udiv x5, x4, x3
    msub x4, x5, x3, x4             // (ymd/100) % 100 = month
    mov x0, x4
    mov x1, x21
    bl emit2
    mov w3, #'-'
    strb w3, [x1], #1
    mov x3, #100
    udiv x4, x19, x3
    msub x4, x4, x3, x19            // day
    mov x0, x4
    bl emit2
    mov w3, #' '
    strb w3, [x1], #1
    mov x3, #3600
    udiv x4, x20, x3
    mov x0, x4
    bl emit2
    mov w3, #':'
    strb w3, [x1], #1
    mov x3, #60
    udiv x4, x20, x3
    udiv x5, x4, x3
    msub x4, x5, x3, x4             // minutes
    mov x0, x4
    bl emit2
    mov x0, x21
    add x0, x0, #11
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// fmt_window_span(x0=dst) -> x0 = advanced dst (the cell is NUL-terminated).
//   The compact "begin" cell:
//     end defaulted  -> "MM-DD HH:MM..now"
//     same date      -> "MM-DD HH:MM..HH:MM"
//     otherwise      -> "YYYY-MM-DD..YYYY-MM-DD"
fmt_window_span:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // dst
    adrp x20, opt_flags
    add x20, x20, :lo12:opt_flags
    ldr x21, [x20]
    tst x21, #F_END_GIVEN
    b.eq .Lfws_now
    adrp x20, begin_ymd
    add x20, x20, :lo12:begin_ymd
    ldr x21, [x20]
    adrp x20, end_ymd
    add x20, x20, :lo12:end_ymd
    ldr x22, [x20]
    cmp x21, x22
    b.eq .Lfws_same
    // different dates: "YYYY-MM-DD..YYYY-MM-DD"
    adrp x20, begin_ymd
    add x20, x20, :lo12:begin_ymd
    ldr x9, [x20]                    // ymd
    adrp x20, begin_sod
    add x20, x20, :lo12:begin_sod
    ldr x2, [x20]                    // sod
    mov x0, x9
    mov x1, x2
    mov x2, x19
    bl fmt_datetime                 // 19 chars at dst
    mov w3, #'.'
    strb w3, [x19, #10]
    strb w3, [x19, #11]
    adrp x20, end_ymd
    add x20, x20, :lo12:end_ymd
    ldr x9, [x20]                    // ymd
    adrp x20, end_sod
    add x20, x20, :lo12:end_sod
    ldr x2, [x20]                    // sod
    mov x0, x9
    mov x1, x2
    mov x2, x19
    add x2, x2, #12
    bl fmt_datetime                 // 19 chars at dst+12
    add x0, x19, #22                // the string ends after the 2nd date
    mov w3, #0
    strb w3, [x0]                   // NUL-terminate
    b .Lfws_done
.Lfws_same:
    // same date: "MM-DD HH:MM..HH:MM"
    adrp x20, begin_ymd
    add x20, x20, :lo12:begin_ymd
    ldr x1, [x20]
    adrp x20, begin_sod
    add x20, x20, :lo12:begin_sod
    ldr x2, [x20]
    mov x0, x19
    bl fmt_md_hm                    // 11 chars, x0 = dst+11
    mov x23, x0
    mov w3, #'.'
    strb w3, [x23], #1
    strb w3, [x23], #1              // ".."
    // end "HH:MM"
    adrp x20, end_sod
    add x20, x20, :lo12:end_sod
    ldr x1, [x20]
    mov x2, #3600
    udiv x3, x1, x2
    mov x0, x3
    mov x1, x23
    bl emit2                        // x1 = buf+2
    mov w3, #':'
    strb w3, [x1], #1               // x1 = buf+3
    adrp x20, end_sod
    add x20, x20, :lo12:end_sod
    ldr x1, [x20]
    mov x2, #60
    udiv x3, x1, x2
    msub x3, x3, x2, x1
    mov x0, x3
    mov x1, x23
    add x1, x1, #3
    bl emit2                        // x1 = buf+5
    mov w3, #0
    strb w3, [x1]                   // NUL-terminate
    b .Lfws_done
.Lfws_now:
    // "MM-DD HH:MM..now"
    adrp x20, begin_ymd
    add x20, x20, :lo12:begin_ymd
    ldr x1, [x20]
    adrp x20, begin_sod
    add x20, x20, :lo12:begin_sod
    ldr x2, [x20]
    mov x0, x19
    bl fmt_md_hm                    // 11 chars, x0 = dst+11
    mov x23, x0
    mov w3, #'.'
    strb w3, [x23], #1
    strb w3, [x23], #1              // ".."
    mov x0, x23
    adrp x1, s_now
    add x1, x1, :lo12:s_now
    bl str_copy_adv                 // x0 = dst+16
    mov w3, #0
    strb w3, [x0]                   // NUL-terminate
    b .Lfws_done
.Lfws_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// sort_excluded_preview — fill excl_sorted[] with pointers into
// excluded_logins, sorted by string.
sort_excluded_preview:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x19, excluded_logins
    add x19, x19, :lo12:excluded_logins
    adrp x20, excluded_count
    add x20, x20, :lo12:excluded_count
    ldr x20, [x20]
    adrp x21, excl_sorted
    add x21, x21, :lo12:excl_sorted
    mov x22, #0
.Lsep_fill:
    cmp x22, x20
    b.ge .Lsep_fill_done
    mov x23, #EXCL_STRIDE
    mul x23, x22, x23
    add x23, x19, x23
    str x23, [x21, x22, lsl #3]
    add x22, x22, #1
    b .Lsep_fill
.Lsep_fill_done:
    mov x22, #1
.Lsep_outer:
    cmp x22, x20
    b.ge .Lsep_done
    ldr x23, [x21, x22, lsl #3]     // key
    mov x24, x22
.Lsep_inner:
    cbz x24, .Lsep_place
    sub x25, x24, #1
    ldr x26, [x21, x25, lsl #3]
    mov x0, x26
    mov x1, x23
    bl strcmp
    cmp x0, #0
    b.le .Lsep_place
    str x26, [x21, x24, lsl #3]
    mov x24, x25
    b .Lsep_inner
.Lsep_place:
    str x23, [x21, x24, lsl #3]
    add x22, x22, #1
    b .Lsep_outer
.Lsep_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// append_top_row — the "top:" provenance row, after choose_limit
append_top_row:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x0, limit
    add x0, x0, :lo12:limit
    ldr x1, [x0]
    cbz x1, .Latr_done               // no limit applied
    adrp x0, reported_count
    add x0, x0, :lo12:reported_count
    ldr x2, [x0]
    cbz x2, .Latr_done               // nothing reported
    bl hv_slot
    mov x19, x0                      // value slot
    mov x26, x0                      // running pointer
    adrp x1, limit
    add x1, x1, :lo12:limit
    ldr x1, [x1]
    mov x2, #1                       // comma
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_row_s
    add x1, x1, :lo12:s_row_s
    bl str_copy_adv
    mov x26, x0
    // ", <hidden> hidden" when anything was hidden
    adrp x1, reported_count
    add x1, x1, :lo12:reported_count
    ldr x2, [x1]
    adrp x1, limit
    add x1, x1, :lo12:limit
    ldr x3, [x1]
    cmp x2, x3
    b.le .Latr_no_hidden
    sub x1, x2, x3                   // hidden count
    mov x20, x1
    adrp x1, s_comma_hidden
    add x1, x1, :lo12:s_comma_hidden
    bl str_copy_adv
    mov x26, x0
    mov x0, x26
    mov x1, x20
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_hidden
    add x1, x1, :lo12:s_hidden
    bl str_copy_adv
    mov x26, x0
.Latr_no_hidden:
    // source
    adrp x21, limit_source
    add x21, x21, :lo12:limit_source
    ldr x22, [x21]
    cmp x22, #SRC_TOP
    b.eq .Latr_src_top
    adrp x20, s_src_terminal
    add x20, x20, :lo12:s_src_terminal
    b .Latr_src_done
.Latr_src_top:
    adrp x20, s_src_top
    add x20, x20, :lo12:s_src_top
.Latr_src_done:
    // compact = "<D>/<R> rows" only when hidden
    adrp x21, reported_count
    add x21, x21, :lo12:reported_count
    ldr x22, [x21]
    adrp x21, limit
    add x21, x21, :lo12:limit
    ldr x23, [x21]
    cmp x22, x23
    b.le .Latr_no_compact
    bl hc_slot
    mov x24, x0                      // compact slot
    mov x26, x0
    adrp x1, limit
    add x1, x1, :lo12:limit
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_slash_rows
    add x1, x1, :lo12:s_slash_rows
    bl str_copy_adv
    mov x26, x0
    adrp x1, reported_count
    add x1, x1, :lo12:reported_count
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_rows
    add x1, x1, :lo12:s_rows
    bl str_copy_adv
    mov x26, x0
    mov w3, #0
    strb w3, [x26]                   // NUL-terminate
    mov x3, x24
    b .Latr_push
.Latr_no_compact:
    mov x3, #0
.Latr_push:
    adrp x0, s_label_top
    add x0, x0, :lo12:s_label_top
    mov x1, x19
    mov x2, x20
    bl hrow_push
.Latr_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// build_report_data — the three phases: columns, ranking, presentation
build_report_data:
    stp x30, xzr, [sp, #-16]!
    bl build_columns
    bl degenerate_check
    bl build_reported
    bl compute_excluded_appeared
    bl sort_reported
    bl apply_share_floor
    bl maybe_add_unknown_col
    bl build_header_rows            // rows 1..11
    bl choose_limit
    bl append_top_row               // the top: row, when a limit applies
    ldp x30, xzr, [sp], #16
    ret// ============================================================================
// Part 10 — the render pipeline: headers, table, footer
// ============================================================================

// cell_ptr(x0=row, x1=col) -> x0 = pointer into the table_cells arena
cell_ptr:
    adrp x2, table_cells
    add x2, x2, :lo12:table_cells
    mov x3, #(8 * 48)
    mul x3, x0, x3
    add x2, x2, x3
    mov x3, #48
    mul x3, x1, x3
    add x0, x2, x3
    ret

// cell_puts(x0=row, x1=col, x2=src) — write a NUL-terminated string into a cell
cell_puts:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // row
    mov x20, x1                     // col
    mov x21, x2                     // src
    mov x0, x19
    mov x1, x20
    bl cell_ptr                     // x0 = cell
    mov x22, x0
    mov x0, x22
    mov x1, x21
    bl str_copy_adv
    mov w3, #0
    strb w3, [x0]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// cell_putnum(x0=row, x1=col, x2=value, x3=comma)
cell_putnum:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x0, x19
    mov x1, x20
    bl cell_ptr
    mov x23, x0
    mov x0, x23
    mov x1, x21
    mov x2, x22
    bl num_copy_adv
    mov w3, #0
    strb w3, [x0]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// cell_putshare(x0=row, x1=col, x2=state, x3=total)
cell_putshare:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0
    mov x20, x1
    mov x21, x2
    mov x22, x3
    mov x0, x19
    mov x1, x20
    bl cell_ptr
    mov x23, x0
    mov x0, x23
    mov x1, x21
    mov x2, x22
    bl share_copy_adv
    mov w3, #0
    strb w3, [x0]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// compute_display — displayed_count / hidden_count from the limit
compute_display:
    adrp x0, reported_count
    add x0, x0, :lo12:reported_count
    ldr x1, [x0]
    adrp x0, limit
    add x0, x0, :lo12:limit
    ldr x2, [x0]
    cbz x2, .Lcd_all
    cmp x1, x2
    b.le .Lcd_all
    sub x3, x1, x2
    adrp x4, displayed_count
    add x4, x4, :lo12:displayed_count
    str x2, [x4]
    adrp x4, hidden_count
    add x4, x4, :lo12:hidden_count
    str x3, [x4]
    ret
.Lcd_all:
    adrp x4, displayed_count
    add x4, x4, :lo12:displayed_count
    str x1, [x4]
    adrp x4, hidden_count
    add x4, x4, :lo12:hidden_count
    str xzr, [x4]
    ret

// compute_shown — shown_total = sum of the displayed users' filtered totals
compute_shown:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, displayed_count
    add x19, x19, :lo12:displayed_count
    ldr x19, [x19]
    adrp x20, reported
    add x20, x20, :lo12:reported
    mov x21, #0
    mov x22, #0                      // sum
.Lcsh_loop:
    cmp x21, x19
    b.ge .Lcsh_done
    ldr x23, [x20, x21, lsl #3]
    mov x0, x23
    bl filtered_total
    add x22, x22, x0
    add x21, x21, #1
    b .Lcsh_loop
.Lcsh_done:
    adrp x0, shown_total
    add x0, x0, :lo12:shown_total
    str x22, [x0]
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// render_report — the top-level renderer
render_report:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x0, header_mode
    add x0, x0, :lo12:header_mode
    ldr x1, [x0]
    cmp x1, #H_FULL
    b.eq .Lrr_full
    cmp x1, #H_COMPACT
    b.eq .Lrr_compact
    b .Lrr_body
.Lrr_full:
    bl render_full_header
    b .Lrr_body
.Lrr_compact:
    bl render_compact_header
    b .Lrr_body
.Lrr_body:
    adrp x0, reported_count
    add x0, x0, :lo12:reported_count
    ldr x1, [x0]
    cbnz x1, .Lrr_table
    bl render_empty_report
    b .Lrr_done
.Lrr_table:
    bl compute_display
    bl compute_shown
    bl build_table_cells
    bl render_table
.Lrr_done:
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// render_full_header — the provenance block, one row per line
render_full_header:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    adrp x19, header_row_count
    add x19, x19, :lo12:header_row_count
    ldr x19, [x19]
    adrp x20, header_rows
    add x20, x20, :lo12:header_rows
    // widths: w0 = widest label, w1 = min(widest value, 48)
    mov x21, #0
    mov x22, #0
    mov x23, #0
.Lrfh_widths:
    cmp x23, x19
    b.ge .Lrfh_widths_done
    mov x24, #HROW_STRIDE
    mul x24, x23, x24
    add x24, x20, x24
    ldr x25, [x24]                  // label
    mov x0, x25
    bl cstr_len
    cmp x0, x21
    b.le .Lrfh_val
    mov x21, x0
.Lrfh_val:
    ldr x25, [x24, #8]              // value
    mov x0, x25
    bl cstr_len
    cmp x0, x22
    b.le .Lrfh_next_w
    mov x22, x0
.Lrfh_next_w:
    add x23, x23, #1
    b .Lrfh_widths
.Lrfh_widths_done:
    cmp x22, #48
    b.le .Lrfh_w1_ok
    mov x22, #48
.Lrfh_w1_ok:
    // emit each row
    mov x23, #0
.Lrfh_emit:
    cmp x23, x19
    b.ge .Lrfh_files
    mov x24, #HROW_STRIDE
    mul x24, x23, x24
    add x24, x20, x24
    ldr x25, [x24]                  // label
    ldr x26, [x24, #8]              // value
    ldr x27, [x24, #16]             // source
    adrp x28, out_buf
    add x28, x28, :lo12:out_buf
    mov x0, x28
    mov x1, x25
    bl str_copy_adv                 // label
    mov x9, x0
    sub x10, x21, #0                // pad to w0
    // pad = w0 - label_len
    mov x0, x25
    bl cstr_len
    mov x10, x21
    sub x10, x10, x0
    mov x0, x9
    mov x1, x10
    bl pad_spaces
    mov w3, #' '
    strb w3, [x0], #1
    strb w3, [x0], #1
    mov x1, x26
    bl str_copy_adv
    mov x9, x0
    mov x0, x26
    bl cstr_len
    mov x10, x22
    sub x10, x10, x0
    mov x0, x9
    mov x1, x10
    bl pad_spaces
    mov w3, #' '
    strb w3, [x0], #1
    strb w3, [x0], #1
    mov w3, #'['
    strb w3, [x0], #1
    mov x1, x27
    bl str_copy_adv
    mov w3, #']'
    strb w3, [x0], #1
    mov x9, x0
    adrp x10, out_buf
    add x10, x10, :lo12:out_buf
    sub x0, x9, x10
    bl emit_out
    add x23, x23, #1
    b .Lrfh_emit
.Lrfh_files:
    // "files:" ljust w0 + "  " + "<N> log file(s) in range"
    adrp x28, out_buf
    add x28, x28, :lo12:out_buf
    mov x0, x28
    adrp x1, s_label_files
    add x1, x1, :lo12:s_label_files
    bl str_copy_adv
    mov x9, x0
    adrp x1, s_label_files
    add x1, x1, :lo12:s_label_files
    mov x0, x1
    bl cstr_len
    mov x10, x21
    sub x10, x10, x0
    mov x0, x9
    mov x1, x10
    bl pad_spaces
    mov w3, #' '
    strb w3, [x0], #1
    strb w3, [x0], #1
    adrp x1, files_total
    add x1, x1, :lo12:files_total
    ldr x1, [x1]
    mov x2, #0                       // plain
    bl num_copy_adv
    adrp x1, s_log_files_in_range
    add x1, x1, :lo12:s_log_files_in_range
    bl str_copy_adv
    mov x9, x0
    adrp x10, out_buf
    add x10, x10, :lo12:out_buf
    sub x0, x9, x10
    bl emit_out
    // blank line
    mov x0, #0
    bl emit_out
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// render_compact_header — one line of compact cells joined with " · "
render_compact_header:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, header_row_count
    add x19, x19, :lo12:header_row_count
    ldr x19, [x19]
    adrp x20, header_rows
    add x20, x20, :lo12:header_rows
    adrp x28, out_buf
    add x28, x28, :lo12:out_buf
    mov x21, #0                      // index
    mov x22, #0                      // wrote-any flag
.Lrch_loop:
    cmp x21, x19
    b.ge .Lrch_done
    mov x23, #HROW_STRIDE
    mul x23, x21, x23
    add x23, x20, x23
    ldr x24, [x23, #24]              // compact ptr
    cbz x24, .Lrch_next
    cbz x22, .Lrch_write
    // separator " · "
    adrp x1, compact_sep
    add x1, x1, :lo12:compact_sep
    mov x0, x28
    bl str_copy_adv
    mov x28, x0
.Lrch_write:
    mov x0, x28
    mov x1, x24
    bl str_copy_adv
    mov x28, x0
    mov x22, #1
.Lrch_next:
    add x21, x21, #1
    b .Lrch_loop
.Lrch_done:
    adrp x9, out_buf
    add x9, x9, :lo12:out_buf
    sub x0, x28, x9
    bl emit_out
    mov x0, #0
    bl emit_out                     // blank line
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// build_table_cells — fill the cell arena: header row, displayed rows,
// and the "+ N others" row when anything is hidden.
build_table_cells:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    // table_cols = 2 + columns_count  (user + count + the metric columns)
    adrp x0, columns_count
    add x0, x0, :lo12:columns_count
    ldr x1, [x0]
    add x1, x1, #2
    adrp x0, table_cols
    add x0, x0, :lo12:table_cols
    str x1, [x0]
    // header cells
    mov x0, #0
    mov x1, #0
    adrp x2, s_user
    add x2, x2, :lo12:s_user
    bl cell_puts
    mov x0, #0
    mov x1, #1
    adrp x2, s_count
    add x2, x2, :lo12:s_count
    bl cell_puts
    adrp x19, columns_count
    add x19, x19, :lo12:columns_count
    ldr x19, [x19]
    mov x20, #0
.Lbtc_hdr:
    cmp x20, x19
    b.ge .Lbtc_rows
    adrp x21, columns
    add x21, x21, :lo12:columns
    ldr x22, [x21, x20, lsl #3]
    mov x0, x22
    bl column_header
    mov x2, x0
    mov x0, #0
    add x1, x20, #2
    bl cell_puts
    add x20, x20, #1
    b .Lbtc_hdr
    // displayed rows
.Lbtc_rows:
    adrp x19, displayed_count
    add x19, x19, :lo12:displayed_count
    ldr x19, [x19]
    adrp x20, reported
    add x20, x20, :lo12:reported
    mov x21, #0
.Lbtc_rownum:
    cmp x21, x19
    b.ge .Lbtc_hidden
    ldr x22, [x20, x21, lsl #3]      // user index
    add x23, x21, #1                 // cell row
    // login
    adrp x24, user_table
    add x24, x24, :lo12:user_table
    mov x25, #USER_STRIDE
    mul x25, x22, x25
    add x25, x24, x25
    mov x0, x23
    mov x1, #0
    mov x2, x25
    bl cell_puts
    // count
    mov x0, x22
    bl filtered_total                // x0 = total
    mov x26, x0
    mov x0, x23
    mov x1, #1
    mov x2, x26
    mov x3, #1                       // comma
    bl cell_putnum
    // extra columns
    adrp x28, columns_count
    add x28, x28, :lo12:columns_count
    ldr x28, [x28]                   // columns bound (x19 holds displayed_count)
    mov x24, #0
.Lbtc_cols:
    cmp x24, x28
    b.ge .Lbtc_next_row
    adrp x25, columns
    add x25, x25, :lo12:columns
    ldr x26, [x25, x24, lsl #3]
    mov x0, x26
    cmp x0, #S_LIVE
    b.eq .Lbtc_cell_live
    cmp x0, #S_OFF
    b.eq .Lbtc_cell_off
    cmp x0, #S_UNK
    b.eq .Lbtc_cell_unk
    cmp x0, #S_OFFSHARE
    b.eq .Lbtc_cell_offshare
    // live-share
    adrp x25, user_table
    add x25, x25, :lo12:user_table
    mov x26, #USER_STRIDE
    mul x26, x22, x26
    add x25, x25, x26
    ldr x2, [x25, #32]               // live (preserved across the call)
    stp x2, x24, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    mov x0, x22
    bl filtered_total
    ldp x22, x23, [sp], #16
    ldp x2, x24, [sp], #16
    mov x3, x0                       // total
    mov x0, x23
    add x1, x24, #2
    bl cell_putshare
    b .Lbtc_next_col
.Lbtc_cell_live:
    adrp x25, user_table
    add x25, x25, :lo12:user_table
    mov x26, #USER_STRIDE
    mul x26, x22, x26
    add x25, x25, x26
    ldr x2, [x25, #32]
    mov x0, x23
    add x1, x24, #2
    mov x3, #1
    bl cell_putnum
    b .Lbtc_next_col
.Lbtc_cell_off:
    adrp x25, user_table
    add x25, x25, :lo12:user_table
    mov x26, #USER_STRIDE
    mul x26, x22, x26
    add x25, x25, x26
    ldr x2, [x25, #40]
    mov x0, x23
    add x1, x24, #2
    mov x3, #1
    bl cell_putnum
    b .Lbtc_next_col
.Lbtc_cell_unk:
    adrp x25, user_table
    add x25, x25, :lo12:user_table
    mov x26, #USER_STRIDE
    mul x26, x22, x26
    add x25, x25, x26
    ldr x2, [x25, #48]
    mov x0, x23
    add x1, x24, #2
    mov x3, #1
    bl cell_putnum
    b .Lbtc_next_col
.Lbtc_cell_offshare:
    adrp x25, user_table
    add x25, x25, :lo12:user_table
    mov x26, #USER_STRIDE
    mul x26, x22, x26
    add x25, x25, x26
    ldr x2, [x25, #40]               // offline (preserved across the call)
    stp x2, x24, [sp, #-16]!
    stp x22, x23, [sp, #-16]!
    mov x0, x22
    bl filtered_total
    ldp x22, x23, [sp], #16
    ldp x2, x24, [sp], #16
    mov x3, x0                       // total
    mov x0, x23
    add x1, x24, #2
    bl cell_putshare
    b .Lbtc_next_col
.Lbtc_next_col:
    add x24, x24, #1
    b .Lbtc_cols
.Lbtc_next_row:
    add x21, x21, #1
    b .Lbtc_rownum
    // the "+ N others" row
.Lbtc_hidden:
    adrp x0, hidden_count
    add x0, x0, :lo12:hidden_count
    ldr x1, [x0]
    cbz x1, .Lbtc_done
    adrp x0, displayed_count
    add x0, x0, :lo12:displayed_count
    ldr x0, [x0]
    add x0, x0, #1                   // cell row
    mov x19, x0
    // login cell "+ N others"
    adrp x26, out_buf
    add x26, x26, :lo12:out_buf
    mov w3, #'+'
    strb w3, [x26], #1
    mov w3, #' '
    strb w3, [x26], #1
    adrp x1, hidden_count
    add x1, x1, :lo12:hidden_count
    ldr x1, [x1]
    mov x2, #1
    mov x0, x26
    bl num_copy_adv
    mov x26, x0
    adrp x1, s_others
    add x1, x1, :lo12:s_others
    bl str_copy_adv
    mov w3, #0
    strb w3, [x0]
    adrp x2, out_buf
    add x2, x2, :lo12:out_buf
    mov x0, x19
    mov x1, #0
    bl cell_puts
    // pool the hidden users
    adrp x21, reported
    add x21, x21, :lo12:reported
    adrp x22, displayed_count
    add x22, x22, :lo12:displayed_count
    ldr x22, [x22]
    adrp x23, reported_count
    add x23, x23, :lo12:reported_count
    ldr x23, [x23]
    mov x24, #0                      // pooled live
    mov x25, #0                      // pooled offline
    mov x26, #0                      // pooled unknown
    mov x27, #0                      // hidden messages
.Lbtc_pool:
    cmp x22, x23
    b.ge .Lbtc_pool_done
    ldr x0, [x21, x22, lsl #3]
    mov x28, x0
    adrp x9, user_table
    add x9, x9, :lo12:user_table
    mov x10, #USER_STRIDE
    mul x10, x28, x10
    add x9, x9, x10
    ldr x11, [x9, #32]
    add x24, x24, x11
    ldr x11, [x9, #40]
    add x25, x25, x11
    ldr x11, [x9, #48]
    add x26, x26, x11
    mov x0, x28
    bl filtered_total
    add x27, x27, x0
    add x22, x22, #1
    b .Lbtc_pool
.Lbtc_pool_done:
    // count cell
    mov x0, x19
    mov x1, #1
    mov x2, x27
    mov x3, #1
    bl cell_putnum
    // extra columns
    adrp x9, columns_count
    add x9, x9, :lo12:columns_count
    ldr x9, [x9]
    mov x10, #0
.Lbtc_hcols:
    cmp x10, x9
    b.ge .Lbtc_done
    adrp x11, columns
    add x11, x11, :lo12:columns
    ldr x12, [x11, x10, lsl #3]
    cmp x12, #S_LIVE
    b.eq .Lbtc_h_live
    cmp x12, #S_OFF
    b.eq .Lbtc_h_off
    cmp x12, #S_UNK
    b.eq .Lbtc_h_unk
    cmp x12, #S_OFFSHARE
    b.eq .Lbtc_h_offshare
    // live-share
    mov x0, x19
    add x1, x10, #2
    mov x2, x24
    mov x3, x27
    bl cell_putshare
    b .Lbtc_h_next
.Lbtc_h_live:
    mov x0, x19
    add x1, x10, #2
    mov x2, x24
    mov x3, #1
    bl cell_putnum
    b .Lbtc_h_next
.Lbtc_h_off:
    mov x0, x19
    add x1, x10, #2
    mov x2, x25
    mov x3, #1
    bl cell_putnum
    b .Lbtc_h_next
.Lbtc_h_unk:
    mov x0, x19
    add x1, x10, #2
    mov x2, x26
    mov x3, #1
    bl cell_putnum
    b .Lbtc_h_next
.Lbtc_h_offshare:
    mov x0, x19
    add x1, x10, #2
    mov x2, x25
    mov x3, x27
    bl cell_putshare
.Lbtc_h_next:
    add x10, x10, #1
    b .Lbtc_hcols
.Lbtc_done:
    // table_rows = header + displayed + (1 if hidden)
    adrp x0, displayed_count
    add x0, x0, :lo12:displayed_count
    ldr x1, [x0]
    add x1, x1, #1
    adrp x0, hidden_count
    add x0, x0, :lo12:hidden_count
    ldr x2, [x0]
    cbz x2, .Lbtc_rows_done
    add x1, x1, #1
.Lbtc_rows_done:
    adrp x0, table_rows
    add x0, x0, :lo12:table_rows
    str x1, [x0]
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// compute_table_widths — table_widths[col] = widest cell in that column
compute_table_widths:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x19, table_cols
    add x19, x19, :lo12:table_cols
    ldr x19, [x19]
    adrp x20, table_rows
    add x20, x20, :lo12:table_rows
    ldr x20, [x20]
    mov x21, #0                      // col
.Lctw_outer:
    cmp x21, x19
    b.ge .Lctw_done
    mov x22, #0                      // width
    mov x23, #0                      // row
.Lctw_inner:
    cmp x23, x20
    b.ge .Lctw_store
    mov x0, x23
    mov x1, x21
    bl cell_ptr
    bl cstr_len
    cmp x0, x22
    b.le .Lctw_next_row
    mov x22, x0
.Lctw_next_row:
    add x23, x23, #1
    b .Lctw_inner
.Lctw_store:
    adrp x24, table_widths
    add x24, x24, :lo12:table_widths
    str x22, [x24, x21, lsl #3]
    add x21, x21, #1
    b .Lctw_outer
.Lctw_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// emit_table_row(x0=row) — align and write one row of cells
emit_table_row:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                      // row
    adrp x20, out_buf
    add x20, x20, :lo12:out_buf      // running pointer
    adrp x21, table_cols
    add x21, x21, :lo12:table_cols
    ldr x21, [x21]
    mov x22, #0                      // col
.Letr_loop:
    cmp x22, x21
    b.ge .Letr_done
    mov x0, x19
    mov x1, x22
    bl cell_ptr                     // x0 = cell
    mov x23, x0
    bl cstr_len                     // x0 = len
    mov x24, x0
    adrp x25, table_widths
    add x25, x25, :lo12:table_widths
    ldr x26, [x25, x22, lsl #3]     // width
    cbz x22, .Letr_write            // col 0 is ljust: pad after the cell
    // rjust: pad (width - len) before the cell
    sub x27, x26, x24
    mov x0, x20
    mov x1, x27
    bl pad_spaces
    mov x20, x0
.Letr_write:
    mov x0, x20
    mov x1, x23
    mov x2, x24
    bl mem_copy_adv
    mov x20, x0
    cbz x22, .Letr_ljust_pad
    b .Letr_gap
.Letr_ljust_pad:
    sub x27, x26, x24
    mov x0, x20
    mov x1, x27
    bl pad_spaces
    mov x20, x0
.Letr_gap:
    add x22, x22, #1
    cmp x22, x21
    b.ge .Letr_loop
    mov w3, #' '
    strb w3, [x20], #1
    strb w3, [x20], #1
    b .Letr_loop
.Letr_done:
    adrp x9, out_buf
    add x9, x9, :lo12:out_buf
    sub x0, x20, x9
    bl emit_out
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// emit_rule — "-" per column width, joined with two spaces
emit_rule:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x19, table_cols
    add x19, x19, :lo12:table_cols
    ldr x19, [x19]
    adrp x20, out_buf
    add x20, x20, :lo12:out_buf
    mov x21, #0
.Ler_loop:
    cmp x21, x19
    b.ge .Ler_done
    adrp x22, table_widths
    add x22, x22, :lo12:table_widths
    ldr x22, [x22, x21, lsl #3]     // width
    mov x23, #0
.Ler_dashes:
    cmp x23, x22
    b.ge .Ler_next
    mov w3, #'-'
    strb w3, [x20], #1
    add x23, x23, #1
    b .Ler_dashes
.Ler_next:
    add x21, x21, #1
    cmp x21, x19
    b.ge .Ler_loop
    mov w3, #' '
    strb w3, [x20], #1
    strb w3, [x20], #1
    b .Ler_loop
.Ler_done:
    adrp x9, out_buf
    add x9, x9, :lo12:out_buf
    sub x0, x20, x9
    bl emit_out
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// render_table — header line, rule, rows, rule, footer
render_table:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    bl compute_table_widths
    mov x0, #0
    bl emit_table_row               // header line
    bl emit_rule
    adrp x19, displayed_count
    add x19, x19, :lo12:displayed_count
    ldr x19, [x19]
    mov x20, #1
.Lrt_loop:
    cmp x20, x19
    b.gt .Lrt_hidden
    mov x0, x20
    bl emit_table_row
    add x20, x20, #1
    b .Lrt_loop
.Lrt_hidden:
    adrp x0, hidden_count
    add x0, x0, :lo12:hidden_count
    ldr x1, [x0]
    cbz x1, .Lrt_footer
    adrp x0, displayed_count
    add x0, x0, :lo12:displayed_count
    ldr x0, [x0]
    add x0, x0, #1
    bl emit_table_row               // the "+ N others" row
.Lrt_footer:
    bl emit_rule
    bl render_footer
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// render_empty_report — "No users met the threshold (N message(s) in range)."
render_empty_report:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x28, out_buf
    add x28, x28, :lo12:out_buf
    adrp x1, s_no_users_pre
    add x1, x1, :lo12:s_no_users_pre
    mov x0, x28
    bl str_copy_adv
    mov x28, x0
    adrp x1, total_messages
    add x1, x1, :lo12:total_messages
    ldr x1, [x1]
    mov x2, #0                       // plain (matches Python)
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_no_users_mid
    add x1, x1, :lo12:s_no_users_mid
    bl str_copy_adv
    mov x28, x0
    adrp x9, out_buf
    add x9, x9, :lo12:out_buf
    sub x0, x28, x9
    bl emit_out
    // the excluded line when any excluded user appeared
    adrp x19, excluded_appeared_count
    add x19, x19, :lo12:excluded_appeared_count
    ldr x20, [x19]
    cbz x20, .Lreu_done
    bl render_excluded_line
.Lreu_done:
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// render_excluded_line — "excluded N user(s), M message(s) not counted"
render_excluded_line:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x28, out_buf
    add x28, x28, :lo12:out_buf
    adrp x1, s_excluded_pre
    add x1, x1, :lo12:s_excluded_pre
    mov x0, x28
    bl str_copy_adv
    mov x28, x0
    adrp x1, excluded_appeared_count
    add x1, x1, :lo12:excluded_appeared_count
    ldr x1, [x1]
    mov x2, #1                       // comma
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_excluded_mid
    add x1, x1, :lo12:s_excluded_mid
    bl str_copy_adv
    mov x28, x0
    adrp x1, excluded_msgs
    add x1, x1, :lo12:excluded_msgs
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_excluded_suf
    add x1, x1, :lo12:s_excluded_suf
    bl str_copy_adv
    mov x28, x0
    adrp x9, out_buf
    add x9, x9, :lo12:out_buf
    sub x0, x28, x9
    bl emit_out
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret

// render_footer — the reconciliation lines after the table
render_footer:
    stp x30, xzr, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x28, out_buf
    add x28, x28, :lo12:out_buf
    adrp x19, hidden_count
    add x19, x19, :lo12:hidden_count
    ldr x20, [x19]
    cbz x20, .Lrfot_no_hidden
    // "<displayed> of <reported> user(s) above threshold (<counts> in range)"
    adrp x1, displayed_count
    add x1, x1, :lo12:displayed_count
    ldr x1, [x1]
    mov x2, #1
    mov x0, x28
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_of
    add x1, x1, :lo12:s_of
    bl str_copy_adv
    mov x28, x0
    adrp x1, reported_count
    add x1, x1, :lo12:reported_count
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_users_above
    add x1, x1, :lo12:s_users_above
    bl str_copy_adv
    mov x28, x0
    adrp x1, counts_count
    add x1, x1, :lo12:counts_count
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_in_range_paren
    add x1, x1, :lo12:s_in_range_paren
    bl str_copy_adv
    mov x28, x0
    b .Lrfot_msgs
.Lrfot_no_hidden:
    // "<reported> of <counts> user(s)"
    adrp x1, reported_count
    add x1, x1, :lo12:reported_count
    ldr x1, [x1]
    mov x2, #1
    mov x0, x28
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_of
    add x1, x1, :lo12:s_of
    bl str_copy_adv
    mov x28, x0
    adrp x1, counts_count
    add x1, x1, :lo12:counts_count
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_users
    add x1, x1, :lo12:s_users
    bl str_copy_adv
    mov x28, x0
.Lrfot_msgs:
    adrp x1, s_semi
    add x1, x1, :lo12:s_semi
    mov x0, x28
    bl str_copy_adv
    mov x28, x0
    adrp x1, shown_total
    add x1, x1, :lo12:shown_total
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_of
    add x1, x1, :lo12:s_of
    bl str_copy_adv
    mov x28, x0
    adrp x1, total_messages
    add x1, x1, :lo12:total_messages
    ldr x1, [x1]
    mov x2, #1
    bl num_copy_adv
    mov x28, x0
    adrp x1, s_msgs_in_range
    add x1, x1, :lo12:s_msgs_in_range
    bl str_copy_adv
    mov x28, x0
    adrp x9, out_buf
    add x9, x9, :lo12:out_buf
    sub x0, x28, x9
    bl emit_out
    // the excluded line when any excluded user appeared
    adrp x19, excluded_appeared_count
    add x19, x19, :lo12:excluded_appeared_count
    ldr x20, [x19]
    cbz x20, .Lrfot_done
    bl render_excluded_line
.Lrfot_done:
    ldp x19, x20, [sp], #16
    ldp x30, xzr, [sp], #16
    ret// ============================================================================
// Part 11 — .bss and .rodata
// ============================================================================

    .section .bss
    .align 16
ts_buf:          .skip 16            // clock_gettime timespec
winsize:         .skip 8             // ioctl winsize (ws_row at +0)
line_buf:        .skip (FILE_CAP_PLUS1 + 8)
dirent_buf:      .skip 8192
login_buf:       .skip 32
fmt_buf:         .skip 32
out_buf:         .skip 1024
dur_buf:         .skip 64

// options
opt_flags:       .skip 8
min_count:       .skip 8
share_floor:     .skip 8
top_n:           .skip 8
state_filter:    .skip 8
sort_id:         .skip 8
header_mode:     .skip 8
channel_arg:     .skip 64
logs_dir_arg:    .skip 512
begin_arg:       .skip 64
since_arg:       .skip 64
end_arg:         .skip 64

// channel
channel_lower:   .skip 64
channel_name:    .skip 64
channel_name_len:.skip 8
channel_dir_path:.skip 512
channel_dirfd:   .skip 8

// window
begin_ymd:       .skip 8
begin_sod:       .skip 8
end_ymd:         .skip 8
end_sod:         .skip 8

// exclusions
excluded_logins: .skip (MAX_EXCLUDED * EXCL_STRIDE)
excluded_count:  .skip 8
include_logins:  .skip (MAX_EXCLUDED * EXCL_STRIDE)
include_count:   .skip 8
x_added:         .skip 8
include_removed: .skip 8

// user table and counters
user_table:      .skip (MAX_USERS * USER_STRIDE)
user_count:      .skip 8
g_live:          .skip 8
g_off:           .skip 8
g_unk:           .skip 8
e_live:          .skip 8
e_off:           .skip 8
e_unk:           .skip 8
cur_state:       .skip 8

// log files
files:           .skip (MAX_FILES * FILE_STRIDE)
files_count:     .skip 8
files_total:     .skip 8
sort_scratch:    .skip 128

// unreadable files
unreadable:          .skip (MAX_UNREADABLE * 16)
unreadable_count:    .skip 8

// logs-dir listing
dnames:          .skip (MAX_DNAMES * 8)
dname_arena:     .skip (MAX_DNAMES * 128)
dname_count:     .skip 8

// provenance header
header_rows:          .skip (MAX_HEADER_ROWS * HROW_STRIDE)
header_row_count:     .skip 8
header_value_arena:   .skip (MAX_HEADER_ROWS * HVALUE_SIZE)
header_compact_arena: .skip (MAX_HEADER_ROWS * HCOMPACT_SIZE)
begin_source_buf:     .skip 256
state_source_buf:     .skip 128
excl_sources_buf:     .skip 256

// ranking / presentation
columns:             .skip (8 * 8)
columns_count:       .skip 8
columns_source:      .skip 8
show_ids:            .skip (8 * 8)
show_count:          .skip 8
reported:            .skip (MAX_USERS * 8)
reported_count:      .skip 8
counts_count:        .skip 8
total_messages:      .skip 8
excluded_appeared:   .skip (MAX_EXCLUDED * 16)
excluded_appeared_count: .skip 8
excluded_msgs:       .skip 8
excl_sorted:         .skip (MAX_EXCLUDED * 8)
shares_shown:        .skip 8
share_floor_acted:   .skip 8
below_floor:         .skip 8
limit:               .skip 8
limit_source:        .skip 8
displayed_count:     .skip 8
hidden_count:        .skip 8
shown_total:         .skip 8

// table cells
table_cells:   .skip ((MAX_USERS + 2) * 8 * 48)
table_rows:    .skip 8
table_cols:    .skip 8
table_widths:  .skip (8 * 8)

// ----------------------------------------------------------------------------
// Read-only message data.  Long strings use .asciz so every reader that walks
// to a NUL terminator (cstr_len, str_eq, str_copy_adv, ...) can share them.
// ----------------------------------------------------------------------------
    .section .rodata

// long-option names
lopt_help:       .asciz "--help"
lopt_channel:    .asciz "--channel"
lopt_logs_dir:   .asciz "--logs-dir"
lopt_begin:      .asciz "--begin"
lopt_since:      .asciz "--since"
lopt_end:        .asciz "--end"
lopt_min_count:  .asciz "--min-count"
lopt_top:        .asciz "--top"
lopt_share_floor:.asciz "--share-floor"
lopt_exclude:    .asciz "--exclude"
lopt_include:    .asciz "--include"
lopt_no_exclude: .asciz "--no-exclude"
lopt_broadcaster:.asciz "--exclude-broadcaster"
lopt_by_state:   .asciz "--by-state"
lopt_live:       .asciz "--live"
lopt_offline:    .asciz "--offline"
lopt_unknown:    .asciz "--unknown"
lopt_show:       .asciz "--show"
lopt_sort:       .asciz "--sort"
lopt_header:     .asciz "--header"

// marker literals (compared with an explicit length)
lit_is_live:     .ascii "is live!"
lit_is_offline:  .ascii "is now offline."

month_days:      .byte 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31

compact_sep:     .byte 0x20, 0xc2, 0xb7, 0x20, 0x00   // " · " (UTF-8 middle dot)

// names
s_live:          .asciz "live"
s_offline:       .asciz "offline"
s_unknown:       .asciz "unknown"
s_offshare:      .asciz "offline-share"
s_liveshare:     .asciz "live-share"
s_count:         .asciz "count"
s_login:         .asciz "login"
s_offpercent:    .asciz "offline%"
s_livepercent:   .asciz "live%"
s_full:          .asciz "full"
s_compact:       .asciz "compact"
s_none:          .asciz "none"
s_user:          .asciz "user"
s_now:           .asciz "now"
s_two_dots:      .asciz ".."
s_none_paren:    .asciz "(none)"
s_more:          .asciz " more"
s_others:        .asciz " others"
s_excl:          .asciz " excl"
s_unread:        .asciz " unread"
s_only:          .asciz " only"
s_keeps:         .asciz " keeps "
s_by:            .asciz "by "
s_ge:            .asciz ">= "
s_ge_compact:    .asciz ">="
s_semi:          .asciz "; "
s_of:            .asciz " of "
s_users:         .asciz " user(s)"
s_users_above:   .asciz " user(s) above threshold ("
s_in_range_paren:.asciz " in range)"
s_msg_s:         .asciz " message(s)"
s_row_s:         .asciz " row(s)"
s_hidden:        .asciz " hidden"
s_rows:          .asciz " rows"
s_login_s:       .asciz " login(s), "
s_in_range_colon:.asciz " in range: "
s_files_skipped: .asciz " file(s) skipped: "
s_log_files_in_range: .asciz " log file(s) in range"
s_msgs_in_range: .asciz " message(s) in range"
s_comma_hidden:  .asciz ", "
s_comma_plus:    .asciz ", +"
s_slash_rows:    .asciz "/"
s_paren:         .asciz ")"
s_paren_open:    .asciz " ("
s_sep_slash:     .asciz " / "
s_floor_act_mid: .asciz " message(s), "
s_floor_act_suf: .asciz " user(s) dropped"
s_floor_compact_pre: .asciz "floor >="
s_floor_compact_mid: .asciz ", -"
s_floor_off:     .asciz "disabled -- every share shown, on however few messages"
s_floor_off_compact: .asciz "floor off"
s_floor_unused:  .asciz "not applied -- no share is shown or sorted by"
s_floor_unused_compact: .asciz "floor unused"
s_no_users_pre:  .asciz "No users met the threshold ("
s_no_users_mid:  .asciz " message(s) in range)."
s_excluded_pre:  .asciz "excluded "
s_excluded_mid:  .asciz " user(s), "
s_excluded_suf:  .asciz " message(s) not counted"
s_reason_cannot_read: .asciz "cannot read"
s_reason_too_large:  .asciz "file too large"
s_not_counted:   .asciz "not counted"
s_minus_include_pre: .asciz "minus --include ("
s_src_since_pre: .asciz "--since "
s_src_before_end:.asciz " before end"

// provenance labels
s_label_channel:  .asciz "channel:"
s_label_logsdir:  .asciz "logs dir:"
s_label_begin:    .asciz "begin:"
s_label_end:      .asciz "end:"
s_label_threshold:.asciz "threshold:"
s_label_state:    .asciz "state:"
s_label_exclude:  .asciz "exclude:"
s_label_columns:  .asciz "columns:"
s_label_sort:     .asciz "sort:"
s_label_floor:    .asciz "share floor:"
s_label_unreadable:.asciz "unreadable:"
s_label_top:      .asciz "top:"
s_label_files:    .asciz "files:"

// provenance sources
s_src_channel:     .asciz "--channel"
s_src_logsdir:     .asciz "--logs-dir"
s_src_begin:       .asciz "--begin"
s_src_end:         .asciz "--end"
s_src_mincount:    .asciz "--min-count"
s_src_builtin:     .asciz "built-in default"
s_src_default_now: .asciz "default: now"
s_src_default_earliest: .asciz "default: earliest log file"
s_src_default:     .asciz "default"
s_src_top:         .asciz "--top"
s_src_terminal:    .asciz "terminal height"
s_src_sort:        .asciz "--sort"
s_src_floor:       .asciz "--share-floor"
s_src_bystate:     .asciz "--by-state"
s_src_show:        .asciz "--show"
s_src_bystate_show:.asciz "--by-state, --show"
s_flag_exclude:    .asciz "--exclude"
s_flag_broadcaster:.asciz "--exclude-broadcaster"
s_flag_include:    .asciz "--include"
s_not_filtered:    .asciz "not filtered"
comma_space:       .asciz ", "
newline:           .asciz "\n"

// error messages
err_no_channel:    .asciz "error: no channel given -- pass --channel\n"
err_no_logs_dir:   .asciz "error: no logs directory given -- pass --logs-dir\n"
hint_logs_dir:     .asciz "Chatterino is believed to use ~/.local/share/chatterino/Logs/Twitch/Channels\n"
err_begin_since:   .asciz "error: --begin and --since are mutually exclusive\n"
err_live_off:      .asciz "error: --live and --offline are mutually exclusive\n"
err_live_unk:      .asciz "error: --live and --unknown are mutually exclusive\n"
err_off_unk:       .asciz "error: --offline and --unknown are mutually exclusive\n"
err_dir_not_found_pre: .asciz "error: logs directory not found: "
err_no_logs_pre:   .asciz "error: no logs for channel '"
err_no_logs_mid:   .asciz "' in "
err_avail:         .asciz "available: "
err_no_files_pre:  .asciz "error: no log files found in "
err_cant_open_dir: .asciz "error: cannot open channel directory: "
err_begin_after_pre: .asciz "error: begin ("
err_begin_after_mid: .asciz ") is after end ("
err_begin_after_suf: .asciz ")\n"
err_dt_pre:        .asciz "error: unrecognized datetime '"
err_dt_mid:        .asciz "' (try 'YYYY-MM-DD', 'YYYY-MM-DD HH:MM:SS')\n"
err_dur_pre:       .asciz "error: unrecognized duration '"
err_dur_mid:       .asciz "' (try '30d', '12h', '90m', '1w3d'; units are w/d/h/m/s and 'm' is minutes)\n"
err_dur_zero:      .asciz "error: duration must be greater than zero\n"
err_col_pre:       .asciz "error: unknown column '"
err_col_mid:       .asciz "' (choose from: live, live-share, offline, offline-share, unknown)\n"
err_sort_pre:      .asciz "error: unknown sort '"
err_sort_mid:      .asciz "' (choose from: count, live, live-share, login, offline, offline-share, unknown)\n"
err_header_pre:    .asciz "error: unknown header mode '"
err_header_mid:    .asciz "' (expected full, compact, none)\n"
err_not_int_pre:   .asciz "error: '"
err_not_int_mid:   .asciz "' is not an integer\n"
err_must_ge1:      .asciz "error: must be 1 or more\n"
err_rowlimit:      .asciz "error: row limit must be 0 (unlimited) or a positive count\n"
err_noexcl_pre:    .asciz "error: --no-exclude cannot be combined with "
err_degenerate_pre:.asciz "error: --"
err_degenerate_mid:.asciz " counts one state only, so per-state columns and sorts would be degenerate -- drop the state filter to compare states\n"
err_too_many_files:.asciz "error: too many log files\n"
err_too_many_users:.asciz "error: too many users\n"
err_too_many_excl: .asciz "error: too many excluded logins\n"

// help text (also the usage text on a bad flag)
help_text:
    .ascii "usage: twitch-counts [options]\n"
    .ascii "  -c, --channel NAME            Twitch channel name (case-insensitive)\n"
    .ascii "  -d, --logs-dir DIR            Chatterino Twitch Channels directory\n"
    .ascii "  -b, --begin DATETIME          start of the range, e.g. '2026-07-01' (alternative to --since)\n"
    .ascii "  -S, --since DURATION          start the range this far before --end, e.g. '30d' (alternative to --begin)\n"
    .ascii "  -e, --end DATETIME            end of the range (default: now)\n"
    .ascii "  -m, --min-count N             only report users with at least this many messages (default: 1)\n"
    .ascii "  -n, --top N                   show at most N rows, 0 for unlimited (default: what fits the terminal; unlimited when piped)\n"
    .ascii "  -x, --exclude LOGIN[,LOGIN...]  exclude these users; repeatable, comma-separated\n"
    .ascii "      --include LOGIN[,LOGIN...]  re-include users the merged exclusions would drop; repeatable\n"
    .ascii "      --no-exclude              ignore every exclusion for this run\n"
    .ascii "      --exclude-broadcaster     exclude the channel's own account\n"
    .ascii "  -L, --live                    only messages sent while the channel was live\n"
    .ascii "  -O, --offline                 only messages sent while the channel was offline\n"
    .ascii "  -U, --unknown                 only messages no live/offline marker can place\n"
    .ascii "  -B, --by-state                add live, offline and offline% columns (shorthand for --show)\n"
    .ascii "      --show COL[,COL...]       extra columns: live, live-share, offline, offline-share, unknown\n"
    .ascii "      --sort METRIC             order rows by: count, live, live-share, login, offline, offline-share, unknown (default: count)\n"
    .ascii "      --share-floor N           messages needed to be listed when a share is shown or sorted by, 0 to disable (default: 10)\n"
    .ascii "      --header MODE             provenance block: full, compact or none (default: full)\n"
    .ascii "  -h, --help                    show this help message and exit\n"
    .byte 0

    .end
