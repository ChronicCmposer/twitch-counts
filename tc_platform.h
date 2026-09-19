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

// C symbol rename table (Mach-O leading underscore).  Every C symbol the
// assembly references must appear here.  `_exit` (the C function) is not
// renamed by a macro because `exit -> _exit -> __exit` would chain; the
// single call site in tc_main.S spells it per platform.
#define main                    _main
#define __errno_location        __error
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

#endif

#endif // TC_PLATFORM_H
