// ============================================================================
// tc_platform.h — the platform layer for twitch-counts-full
// ============================================================================
//
//  Every module #includes this file first.  The assembly is written in GNU
//  as syntax for the Linux/musl static build; this header is what lets the
//  SAME sources assemble with Apple's integrated assembler into a Mach-O
//  binary on macOS.  Both toolchains run the C preprocessor over .S files
//  (clang always does; the Linux recipe assembles through musl-gcc -c), so
//  the platform is selected with cpp conditionals and the per-platform
//  spellings are cpp macros.  Multi-instruction helpers are assembler
//  macros, which both assemblers accept.
//
//  What differs, and the macro that hides it
//  -----------------------------------------
//    PAGE(sym) / LO12(sym)   adrp+add/ldr page-relative addressing:
//                            GNU  `adrp x0, sym` / `add x0, x0, :lo12:sym`
//                            Mach `adrp x0, sym@PAGE` / `add x0, x0, sym@PAGEOFF`
//    LEA reg, sym            the adrp+add pair above as one line (reg = &sym);
//    LEA_OFF reg, sym, off   the same plus `add reg, reg, #off`.  Modules
//                            use these for every symbol address; PAGE/LO12
//                            remain for the load-through form
//                            `adrp xN, PAGE(sym)` / `ldr xM, [xN, LO12(sym)]`.
//    RODATA                  the read-only data section.  On Darwin the
//                            regions hold pointer tables that the linker
//                            refuses inside __TEXT, so they live in
//                            __DATA,__const (dyld rebases them).
//    FUNC_TYPE(sym)          `.type sym, %function` on ELF; no Mach-O
//                            equivalent.
//    LOAD_EXTERN_DATA_ADDR   address of a libc DATA symbol (optarg, opterr):
//                            direct on a static ELF, via the GOT on Darwin.
//    C symbol names          Mach-O C symbols carry a leading underscore.
//                            The rename table below turns `bl printf` into
//                            `bl _printf` on Darwin without touching call
//                            sites (cpp never rewrites inside strings).
//                            musl's __errno_location is libSystem's __error.
//
//  Rules for adding platform-dependent code
//  ----------------------------------------
//    * Numeric ABI facts (struct offsets, ioctl requests, clock ids) belong
//      here, never in a module, and every value must be derived from the
//      platform headers, not remembered.
//    * A behavioural difference (variadic call marshalling, a syscall) is
//      an assembler macro or a fixed-arity wrapper in tc_util.S with two
//      bodies, never an #ifdef sprinkled through a routine.
//    * Never use x18: it is reserved on Darwin and zeroed on context switch.
//    * Never join statements with ';': it is a COMMENT character on Darwin.
//
#ifndef TC_PLATFORM_H
#define TC_PLATFORM_H

#ifdef __APPLE__
// ----------------------------------------------------------------------------
// macOS arm64 (Mach-O, libSystem)
// ----------------------------------------------------------------------------
#define PAGE(sym)       sym@PAGE
#define LO12(sym)       sym@PAGEOFF
#define RODATA          .section __DATA,__const
#define FUNC_TYPE(sym)

    .macro LOAD_EXTERN_DATA_ADDR reg, sym
    adrp \reg, \sym@GOTPAGE
    ldr  \reg, [\reg, \sym@GOTPAGEOFF]
    .endm

    .macro LEA reg, sym                 // reg = &sym
    adrp \reg, \sym@PAGE
    add  \reg, \reg, \sym@PAGEOFF
    .endm
    .macro LEA_OFF reg, sym, off        // reg = &sym + off
    adrp \reg, \sym@PAGE
    add  \reg, \reg, \sym@PAGEOFF
    add  \reg, \reg, #\off
    .endm

// C symbol rename table (Mach-O leading underscore).  Every C symbol the
// assembly references must appear here.  `_exit` (the C function) is not
// renamed by a macro because `exit -> _exit -> __exit` would chain; the
// single call site in tc_main.S spells it per platform.
#define main                    _main
#define __errno_location        ___error
#define clock_gettime           _clock_gettime
#define close                   _close
#define closedir                _closedir
#define exit                    _exit
#define fclose                  _fclose
#define fflush                  _fflush
#define fopen                   _fopen
#define free                    _free
#define getenv                  _getenv
#define getopt_long             _getopt_long
#define getpwnam                _getpwnam
#define getpwuid                _getpwuid
#define getuid                  _getuid
#define ioctl                   _ioctl
#define isatty                  _isatty
#define kevent                  _kevent
#define kqueue                  _kqueue
#define localtime_r             _localtime_r
#define lseek                   _lseek
#define malloc                  _malloc
#define memset                  _memset
#define mkdir                   _mkdir
#define nanosleep               _nanosleep
#define open                    _open
#define opendir                 _opendir
#define optarg                  _optarg
#define opterr                  _opterr
#define optind                  _optind
#define pow                     _pow
#define printf                  _printf
#define qsort                   _qsort
#define read                    _read
#define readdir                 _readdir
#define realloc                 _realloc
#define rint                    _rint
#define signal                  _signal
#define snprintf                _snprintf
#define stat                    _stat
#define strcmp                  _strcmp
#define strerror                _strerror
#define strtod                  _strtod
#define strtol                  _strtol
#define time                    _time
#define write                   _write
// tomlc99
#define toml_array_in           _toml_array_in
#define toml_array_kind         _toml_array_kind
#define toml_array_nelem        _toml_array_nelem
#define toml_free               _toml_free
#define toml_int_at             _toml_int_at
#define toml_key_exists         _toml_key_exists
#define toml_key_in             _toml_key_in
#define toml_parse              _toml_parse
#define toml_parse_file         _toml_parse_file
#define toml_raw_at             _toml_raw_at
#define toml_raw_in             _toml_raw_in
#define toml_rtos               _toml_rtos
#define toml_string_at          _toml_string_at
#define toml_table_at           _toml_table_at
#define toml_table_in           _toml_table_in
#define toml_table_narr         _toml_table_narr
#define toml_table_nkval        _toml_table_nkval
#define toml_table_ntab         _toml_table_ntab
// sqlite3
#define sqlite3_bind_int64      _sqlite3_bind_int64
#define sqlite3_bind_null       _sqlite3_bind_null
#define sqlite3_bind_text       _sqlite3_bind_text
#define sqlite3_close           _sqlite3_close
#define sqlite3_column_int64    _sqlite3_column_int64
#define sqlite3_column_text     _sqlite3_column_text
#define sqlite3_errcode         _sqlite3_errcode
#define sqlite3_errmsg          _sqlite3_errmsg
#define sqlite3_exec            _sqlite3_exec
#define sqlite3_finalize        _sqlite3_finalize
#define sqlite3_open_v2         _sqlite3_open_v2
#define sqlite3_prepare_v2      _sqlite3_prepare_v2
#define sqlite3_reset           _sqlite3_reset
#define sqlite3_step            _sqlite3_step
// pcre2-8
#define pcre2_code_free_8       _pcre2_code_free_8
#define pcre2_compile_8         _pcre2_compile_8
#define pcre2_get_error_message_8 _pcre2_get_error_message_8
#define pcre2_match_8           _pcre2_match_8
#define pcre2_match_data_create_from_pattern_8 _pcre2_match_data_create_from_pattern_8
#define pcre2_match_data_free_8 _pcre2_match_data_free_8

#else
// ----------------------------------------------------------------------------
// Linux AArch64 (ELF, musl, static)
// ----------------------------------------------------------------------------
#define PAGE(sym)       sym
#define LO12(sym)       :lo12:sym
#define RODATA          .section .rodata
#define FUNC_TYPE(sym)  .type sym, %function

    .macro LOAD_EXTERN_DATA_ADDR reg, sym
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
    .endm

    .macro LEA reg, sym                 // reg = &sym
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
    .endm
    .macro LEA_OFF reg, sym, off        // reg = &sym + off
    adrp \reg, \sym
    add  \reg, \reg, :lo12:\sym
    add  \reg, \reg, #\off
    .endm

#endif


// ============================================================================
// Function frames
// ============================================================================
//  PROLOGUE n   pushes the frame record {x29, x30}, points x29 at it (so a
//               debugger can walk the chain), then pushes n callee-saved
//               pairs in order: x19/x20, x21/x22, ... up to x27/x28 (n <= 5).
//  EPILOGUE n   pops the same n pairs in reverse, then the frame record.
//  Both keep sp 16-byte aligned; a function that needs stack locals still
//  does its own `sub sp, sp, #N` after PROLOGUE and `add` before EPILOGUE.
//  The register sets and stack layout are exactly what the hand-written
//  stp/ldp chains produced before the macros existed.
    .macro PROLOGUE n=0
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    .if \n >= 1
    stp x19, x20, [sp, #-16]!
    .endif
    .if \n >= 2
    stp x21, x22, [sp, #-16]!
    .endif
    .if \n >= 3
    stp x23, x24, [sp, #-16]!
    .endif
    .if \n >= 4
    stp x25, x26, [sp, #-16]!
    .endif
    .if \n >= 5
    stp x27, x28, [sp, #-16]!
    .endif
    .endm
    .macro EPILOGUE n=0
    .if \n >= 5
    ldp x27, x28, [sp], #16
    .endif
    .if \n >= 4
    ldp x25, x26, [sp], #16
    .endif
    .if \n >= 3
    ldp x23, x24, [sp], #16
    .endif
    .if \n >= 2
    ldp x21, x22, [sp], #16
    .endif
    .if \n >= 1
    ldp x19, x20, [sp], #16
    .endif
    ldp x29, x30, [sp], #16
    .endm


// ============================================================================
// libc struct layouts and OS constants
// ============================================================================
//  Every value below was derived by compiling a probe against the platform's
//  own headers (macOS SDK via clang; musl-1.2.6 via clang --target
//  aarch64-linux-musl against third_party/musl-1.2.6), never from memory.
//  They are cpp macros rather than .equ so that a stale module-local
//  `.equ ST_MODE, 16` becomes an assembler error instead of silently
//  overriding the platform value.
//
//  The values that are identical on both platforms are defined once,
//  unconditionally, after the per-platform block below (struct tm, the
//  file-type bits, the dirent types, the descriptors and the clock id).
//  Also identical but referenced by raw offset in the modules:
//    struct timespec tv_sec 0, tv_nsec 8 (16 bytes)
//    struct winsize ws_row 0, ws_col 2 (u16 each, 8 bytes)
//    struct option  name 0, has_arg 8, flag 16, val 24 (32 bytes)
//
#ifdef __APPLE__
// struct stat (sizeof 144): st_dev is 4 bytes, st_mode is 2 bytes.
#define ST_DEV          0
#define ST_MODE         4
#define ST_INO          8
#define ST_MTIM_SEC     48          // st_mtimespec.tv_sec
#define ST_MTIM_NSEC    56          // st_mtimespec.tv_nsec
#define ST_SIZE         96
#define STAT_SZ         160         // buffer size for a struct stat (>= 144)
// struct dirent (d_namlen occupies 18-19; d_name is up to 1023 bytes)
#define D_TYPE_OFF      20
#define D_NAME_OFF      21
// ioctl(2) request: not a valid mov immediate, load it with `ldr xN, =TIOCGWINSZ`
#define TIOCGWINSZ      0x40087468
// "monotonic" for the watch loop: CLOCK_UPTIME_RAW (8) is what CPython's
// time.monotonic() uses on macOS (mach_absolute_time), and like it stops
// while the machine sleeps.  Darwin's CLOCK_MONOTONIC is 6 and keeps
// counting through sleep; clock id 1 is not a Darwin clock at all.
#define CLOCK_MONOTONIC 8
// struct passwd (getpwuid/getpwnam): pw_dir is the home directory
#define PW_DIR_OFF      48
// kqueue(2)/kevent(2) for the watch loop's change notification (the
// Python's KqueueWatcher).  struct kevent is 32 bytes:
//   ident u64 @0, filter i16 @8, flags u16 @10, fflags u32 @12,
//   data i64 @16, udata ptr @24
#define KEVENT_SZ       32
#define KE_IDENT        0
#define KE_FILTER       8
#define KE_FLAGS        10
#define KE_FFLAGS       12
#define KE_DATA         16
#define KE_UDATA        24
#define EVFILT_VNODE    -4
#define EV_ADD          0x1
#define EV_ENABLE       0x4
#define EV_CLEAR        0x20
#define NOTE_DELETE     0x1
#define NOTE_WRITE      0x2
#define NOTE_EXTEND     0x4
#define NOTE_RENAME     0x20
#else
// struct stat (sizeof 128, musl aarch64): st_dev 8 bytes, st_mode 4 bytes.
#define ST_DEV          0
#define ST_MODE         16
#define ST_INO          8
#define ST_MTIM_SEC     88
#define ST_MTIM_NSEC    96
#define ST_SIZE         48
#define STAT_SZ         160
// struct dirent
#define D_TYPE_OFF      18
#define D_NAME_OFF      19
#define TIOCGWINSZ      0x5413
#define CLOCK_MONOTONIC 1
// struct passwd (musl): pw_name 0, pw_passwd 8, pw_uid 16, pw_gid 20,
// pw_gecos 24, pw_dir 32, pw_shell 40
#define PW_DIR_OFF      32
#endif
// ---- identical on both platforms --------------------------------------------
#define EINTR           4
#define ENOENT          2
#define O_RDONLY        0
#define SEEK_SET        0
#define S_IFMT          0xF000
#define S_IFREG         0x8000
#define S_IFDIR         0x4000
#define DT_DIR          4
#define DT_REG          8
#define SIGINT          2
#define CLOCK_REALTIME  0
#define STDOUT          1           // the descriptors, not the stdio streams
#define STDERR          2
// struct tm (int fields)
#define TM_SEC          0
#define TM_MIN          4
#define TM_HOUR         8
#define TM_MDAY         12
#define TM_MON          16
#define TM_YEAR         20

// ---- plain numeric constants every module needs ------------------------------
//  Not platform facts, but defined here for the same fail-loud reason: a
//  module-local `.equ SECS_PER_DAY, 86400` would silently shadow a shared
//  value, whereas with the cpp macro in scope it fails to assemble.
#define SECS_PER_DAY    86400

// Field loads whose WIDTH differs between the platforms.  `n` is the
// register number: LOAD_ST_MODE 1, x0  ->  w1 = st_mode (zero-extended).
#ifdef __APPLE__
    .macro LOAD_ST_MODE n, base         // mode_t is 16-bit on Darwin
    ldrh w\n, [\base, #ST_MODE]
    .endm
    .macro LOAD_ST_DEV n, base          // dev_t is 32-bit on Darwin
    ldr  w\n, [\base, #ST_DEV]
    .endm
#else
    .macro LOAD_ST_MODE n, base         // mode_t is 32-bit on musl
    ldr  w\n, [\base, #ST_MODE]
    .endm
    .macro LOAD_ST_DEV n, base          // dev_t is 64-bit on musl
    ldr  x\n, [\base, #ST_DEV]
    .endm
#endif

// Variadic C calls.  On Darwin arm64 every anonymous argument travels in an
// 8-byte STACK slot at the callee's sp, not in x1..x7/d0..d7 as on Linux.
// Modules never call a variadic libc function directly; they call these
// fixed-arity wrappers (defined in tc_util.S / check_tc_printf.S), whose
// Darwin bodies do the marshalling once:
//   tc_snprintf_d(x0=buf, x1=size, x2=fmt, d0=double)  -> x0 = int
//   tc_snprintf_i(x0=buf, x1=size, x2=fmt, x3=int)     -> x0 = int
//   tc_ioctl_p(x0=fd, x1=request, x2=pointer)          -> x0 = int
//   (harness only) tc_printf_i / tc_printf_ii / tc_printf_p / tc_printf_ip
//   / tc_printf_7i with the anonymous arguments in x1.. as on Linux.
// open(path, O_RDONLY) passes no anonymous argument and is called directly.

#endif // TC_PLATFORM_H
