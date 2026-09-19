// ============================================================================
// tc_config.S — config & environment hooks for twitch-counts-full (Phase 3).
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    musl-gcc -static — musl libc + third_party/tomlc99/toml.o
//
//  This module implements the four frozen hooks tc_cli.S calls during layered
//  resolution (the calling contract is in tc_layout.inc) plus the exclusion-set
//  builder and the config memo API the later phases need.  It is a byte-for-byte
//  port of the Python reference's load_config_layer / config_identity /
//  load_config / resolve / build_inputs (aliases) / build_exclusions /
//  config_exclusions / exclusion_layers / shorten_path / environment handling.
//
//  Exported (all .global, AAPCS64; x19-x28 preserved)
//  --------------------------------------------------
//    [frozen contract]
//    tc_env_get(x0=name)                  -> (x0=found 0/1, x1=value_ptr)
//    tc_config_get(x0=key, x1=section_id) -> (x0=found, x1=value_ptr, x2=src)
//    tc_aliases_apply()                   -> 0   (may tc_fail)
//    tc_excl_contains(x0=ptr, x1=len)     -> x0 = 0/1
//    [additive hooks, documented for Phases 4-7]
//    tc_build_exclusions()                -> 0   (may tc_fail; fills
//                                                  tc_excl_set/tc_excl_sources)
//    tc_config_identity() -> (x0=path or 0, x1=size, x2=mtime_ns)
//    tc_config_changed()  -> x0 = 0/1  (file changed since it was loaded)
//    tc_config_reload()   -> 0        (re-read the config file now)
//    tc_shorten_path(x0=path) -> x0 = ptr to the shortened path (scratch)
//    tc_excl_src_count (u64 .bss): number of source records in tc_excl_sources
//
//  Config file resolution (Python load_config_layer + config_identity):
//    --config flag  >  env TWITCH_COUNTS_CONFIG  >  XDG default
//    ($XDG_CONFIG_HOME/twitch-counts.toml or $HOME/.config/twitch-counts.toml).
//    A missing default path is "not loaded" (not an error); a missing EXPLICIT
//    path raises "config file not found: <path>".  TOML errors raise
//    "could not read config <path>: <detail>"; a non-table root raises
//    "config <path> must be a table of settings".  [watch]/[tail] non-tables
//    raise "[watch] in <path> must be a table" (path shorten_path'd), checked
//    at load time in the same relative order the Python resolves them.
//
//  Notes for later phases
//  ---------------------
//    * The exclusion set is NOT built by tc_cli_parse (that file is frozen).
//      The orchestrator must call tc_build_exclusions() after tc_cli_parse
//      (and after every config reload under --watch).  tc_aliases_apply is
//      already called by tc_cli_parse; it rewrites TC_O_CHANNEL and the
//      channel provenance before exclusions are built, so --exclude-broadcaster
//      sees the post-alias login, exactly like the Python.
//    * tc_excl_set entries: {login[26], source_idx u64}.  source_idx indexes
//      tc_excl_sources (records of {ptr u64, len u64}); dynamic labels live in
//      tc_excl_src_buf.  tc_excl_src_count is the number of live records.
//      The record list order is the Python `sources` list order (layer order,
//      deduped, then "minus --include (N)").
//    * tc_config_identity/changed/reload implement the Python
//      (path, size, mtime_ns) memo: watch mode should call tc_config_changed()
//      on each tick and tc_config_reload() (then re-resolve) when it is 1.
//      A config that was not loaded (missing default) is memoized as
//      "permanently missing", matching the Python's ("none",) / (path,None,None)
//      cache keys.
//
//  Residual diffs vs the Python (see the Phase-3 report)
//  -----------------------------------------------------
//    * TOML syntax-error text comes from tomlc99 ("line N: ...") not tomllib
//      ("Invalid ... (at line 1, column N)").  The "could not read config
//      <path>: " prefix is byte-identical.
//    * Python's `aliases = config.get("aliases") or {}` treats a FALSY aliases
//      value (empty array/string, 0, false) as absent; this port accepts
//      "false", "0", "0.0" and empty strings/arrays and rejects other
//      non-table values.
//    * Logins longer than 25 characters (the Twitch limit) are truncated to
//      fit the frozen 26-byte entry; the Python keeps them whole.
//    * The exclusion set caps at TC_EX_MAX (512) entries; a full set fails
//      loudly ("too many excluded logins (max 512)") rather than silently
//      dropping exclusions.
//    * Error-order corner cases: with BOTH a config-table error and a
//      resolution error the Python may report the config error first; the
//      port reports whichever tc_cli reaches first.  With BOTH [watch] and
//      [tail] non-tables the Python's choice is hash-order (non-deterministic);
//      the port checks [watch] first.  With no channel AND a bad --begin the
//      Python reports "no channel given" first; tc_cli_parse converts the
//      window first, so the port reports the window error first.
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"

// ----------------------------------------------------------------------------
// Module constants
// ----------------------------------------------------------------------------
    .equ O_RDONLY,      0
    .equ S_IFMT,        0xF000
    .equ S_IFREG,       0x8000

    .equ CFG_PATH_SZ,   512          // resolved config path buffer
    .equ CFG_SCRATCH_SZ,1024
    .equ VAL_BUF_SZ,    512          // unquoted-value scratch (x2 buffers)
    .equ CFG_ERRBUF_SZ, 128          // toml_parse error buffer
    .equ EX_GROUP_MAX,  64           // max [exclude] groups / always names
    .equ SPLIT_MAX,     256          // max names from one split call

    // struct stat offsets: ST_MODE/ST_SIZE/ST_MTIM_SEC/ST_MTIM_NSEC and the
    // struct stat buffer size STAT_SZ are per-platform and come from
    // tc_platform.h (musl aarch64 vs. Darwin arm64 layouts differ).

    // config load state
    .equ CFG_ST_NONE,   0            // not attempted
    .equ CFG_ST_LOADED, 1
    .equ CFG_ST_NOLOAD, 2            // no-config or default missing
    .equ CFG_ST_BUSY,   3            // re-entrancy guard

// ----------------------------------------------------------------------------
// .bss
// ----------------------------------------------------------------------------
    .bss
    .p2align 4
    .global tc_excl_src_count
tc_excl_src_count:  .skip 8
tc_cfg_root:        .skip 8          // toml_table_t* (0 when not loaded)
tc_cfg_state:       .skip 8
tc_cfg_explicit:    .skip 8          // path chosen by --config or env
tc_cfg_size:        .skip 8
tc_cfg_mtime:       .skip 8          // st_mtim.tv_sec at load time
tc_cfg_mtime_ns:    .skip 8
tc_cfg_path:        .skip CFG_PATH_SZ
tc_cfg_where:       .skip CFG_PATH_SZ   // shorten_path(tc_cfg_path)
tc_cfg_scratch:     .skip CFG_SCRATCH_SZ
tc_cfg_scratch2:    .skip CFG_SCRATCH_SZ
tc_cfg_val_a:       .skip VAL_BUF_SZ
tc_cfg_val_b:       .skip VAL_BUF_SZ
tc_cfg_val_tog:     .skip 8
tc_cfg_errbuf:      .skip CFG_ERRBUF_SZ
tc_cfg_statbuf:     .skip STAT_SZ
tc_cfg_fd:          .skip 8
tc_cfg_buf:         .skip 8          // malloc'd file buffer
tc_cfg_bufsz:       .skip 8
tc_excl_groups:     .skip EX_GROUP_MAX * 24   // {name_ptr, name_len, arr_ptr}
tc_excl_group_n:    .skip 8
tc_excl_always:     .skip EX_GROUP_MAX * 16   // {name_ptr, name_len}
tc_excl_always_n:   .skip 8
tc_excl_flat:       .skip 512        // NUL-separated flat names
tc_excl_flat_n:     .skip 8
tc_split_tab:       .skip SPLIT_MAX * 16      // {ptr, len}
tc_split_n:         .skip 8
tc_split_buf:       .skip 1024
tc_excl_tmp:        .skip 1024       // stable copies of always names
tc_excl_tmp_cur:    .skip 8

    .text

// ============================================================================
// Exported hooks — frozen contract
// ============================================================================

// ----------------------------------------------------------------------------
// tc_env_get(x0=name) -> (x0=found 0/1, x1=value_ptr)
//   getenv lookup; unset AND empty ("") both report not-found, mirroring
//   Python's `os.environ.get(n) not in (None, "")`.
//   The config is loaded lazily on the first env lookup so that config-load
//   errors surface before any env value is accepted, matching the Python's
//   build_inputs ordering.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_env_get
    FUNC_TYPE(tc_env_get)
tc_env_get:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                     // name (survives ensure_config_loaded)
    bl ensure_config_loaded
    mov x0, x19
    bl getenv
    cbz x0, .Lenv_missing
    ldrb w1, [x0]
    cbz w1, .Lenv_missing
    mov x1, x0                      // value
    mov x0, #1                      // found
    b .Lenv_done
.Lenv_missing:
    mov x0, #0
    mov x1, #0
.Lenv_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_config_get(x0=key, x1=section_id) -> (x0=found, x1=value, x2=source_id)
//   section_id: TC_SEC_NONE/WATCH/TAIL.  The [section] table beats the top
//   level (Python resolve()); x2 is TC_SRC_CONFIG / _CONFIG_WATCH / _CONFIG_TAIL.
//   found=1 only for a key present with a non-null value.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_config_get
    FUNC_TYPE(tc_config_get)
tc_config_get:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // key
    mov x20, x1                     // section id
    bl ensure_config_loaded
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    ldr x0, [x0]
    cmp x0, #CFG_ST_LOADED
    b.ne .Lcg_missing
    adrp x0, PAGE(tc_cfg_root)
    add x0, x0, LO12(tc_cfg_root)
    ldr x21, [x0]                   // root table
    mov x22, #TC_SRC_CONFIG
    cmp x20, #TC_SEC_NONE
    b.eq .Lcg_root
    cmp x20, #TC_SEC_WATCH
    b.eq .Lcg_watch
    mov x22, #TC_SRC_CONFIG_TAIL
    adrp x1, PAGE(s_key_tail)
    add x1, x1, LO12(s_key_tail)
    b .Lcg_sect
.Lcg_watch:
    mov x22, #TC_SRC_CONFIG_WATCH
    adrp x1, PAGE(s_key_watch)
    add x1, x1, LO12(s_key_watch)
.Lcg_sect:
    mov x0, x21
    bl toml_table_in
    cbz x0, .Lcg_root
    mov x23, x0                     // section table
    mov x0, x23
    mov x1, x19
    bl toml_raw_in
    cbz x0, .Lcg_root
    mov x24, x0
    mov x0, x24
    bl toml_value_to_string
    mov x1, x0
    mov x0, #1
    mov x2, x22
    b .Lcg_done
.Lcg_root:
    mov x0, x21
    mov x1, x19
    bl toml_raw_in
    cbz x0, .Lcg_missing
    mov x24, x0
    mov x0, x24
    bl toml_value_to_string
    mov x1, x0
    mov x0, #1
    mov x2, #TC_SRC_CONFIG
    b .Lcg_done
.Lcg_missing:
    mov x0, #0
    mov x1, #0
    mov x2, #0
.Lcg_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_aliases_apply() -> 0
//   Mirrors the tail of Python build_inputs: the "no channel given" guard,
//   then the [aliases] rewrite.  When the resolved channel matches an aliases
//   key the channel value is replaced and TC_O_CHAN_SRC gets
//   "<src> -> alias '<key>'" with TC_O_SRC[TC_SET_CHANNEL] = TC_SRC_DYN_ALIAS.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_aliases_apply
    FUNC_TYPE(tc_aliases_apply)
tc_aliases_apply:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    bl ensure_config_loaded
    // "no channel given" guard — fires when the channel was never resolved
    // (source id still TC_SRC_DEFAULT), NOT when it resolved to "".
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x2, #TC_O_SRC
    add x2, x0, x2
    ldr x1, [x2, #TC_SET_CHANNEL*8]
    cmp x1, #TC_SRC_DEFAULT
    b.ne .Laa_have_channel
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    adrp x1, PAGE(s_no_channel_pre)
    add x1, x1, LO12(s_no_channel_pre)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_where)
    add x1, x1, LO12(tc_cfg_where)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Laa_have_channel:
    // no config -> nothing to rewrite
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    ldr x0, [x0]
    cmp x0, #CFG_ST_LOADED
    b.ne .Laa_ok
    adrp x0, PAGE(tc_cfg_root)
    add x0, x0, LO12(tc_cfg_root)
    ldr x19, [x0]                   // root
    mov x0, x19
    adrp x1, PAGE(s_key_aliases)
    add x1, x1, LO12(s_key_aliases)
    bl toml_table_in
    cbz x0, .Laa_ok
    mov x20, x0                     // aliases table
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x21, x0, #TC_O_CHANNEL      // resolved channel (the alias key)
    mov x22, #0
    mov x0, x20
    bl toml_table_total
    mov x23, x0                     // total key count
.Laa_key_loop:
    cmp x22, x23
    b.ge .Laa_ok
    mov x0, x20
    mov x1, x22
    bl toml_key_in
    cbz x0, .Laa_key_next
    mov x24, x0                     // alias key ptr
    mov x0, x21
    mov x1, x24
    bl streq
    cbz x0, .Laa_key_next
    // ---- match: rewrite channel + compose the alias source ----------------
    mov x0, x20
    mov x1, x24
    bl toml_raw_in
    cbz x0, .Laa_key_next
    mov x25, x0
    mov x0, x25
    bl toml_value_to_string         // x0 = stringified alias value
    mov x26, x0
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_CHANNEL
    mov x1, x26
    mov x2, #TC_O_CHANNEL_SZ
    bl tc_copy_str_cap
    // compose TC_O_CHAN_SRC = "<orig src> -> alias '<key>'"
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x2, #TC_O_SRC
    add x2, x0, x2
    ldr x0, [x2, #TC_SET_CHANNEL*8]
    bl tc_source_str
    mov x26, x0
    mov x25, x1                     // len
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x1, #TC_O_CHAN_SRC
    add x0, x0, x1
    mov x1, x26
    mov x2, x25
    bl cat_n
    adrp x1, PAGE(s_alias_arrow)
    add x1, x1, LO12(s_alias_arrow)
    bl cat_cstr
    mov x1, x24
    bl cat_cstr
    adrp x1, PAGE(s_squote)
    add x1, x1, LO12(s_squote)
    bl cat_cstr
    // provenance: the channel source becomes the dynamic alias string
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x2, #TC_O_SRC
    add x2, x0, x2
    mov x1, #TC_SRC_DYN_ALIAS
    str x1, [x2, #TC_SET_CHANNEL*8]
    b .Laa_ok
.Laa_key_next:
    add x22, x22, #1
    b .Laa_key_loop
.Laa_ok:
    mov x0, #0
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_excl_contains(x0=ptr, x1=len) -> x0 = 1 if the login is in tc_excl_set
//   (case-insensitive compare), else 0.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_excl_contains
    FUNC_TYPE(tc_excl_contains)
tc_excl_contains:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // login ptr
    mov x20, x1                     // login len
    adrp x21, PAGE(tc_excl_set)
    add x21, x21, LO12(tc_excl_set)
    ldr x22, [x21]                  // count
    add x23, x21, #8                // entries base
    mov x24, #0
.Lec_loop:
    cmp x24, x22
    b.ge .Lec_no
    mov x0, x24
    bl excl_entry_off
    add x0, x23, x0
    mov x1, x19
    mov x2, x20
    bl login_matches
    cbnz x0, .Lec_yes
    add x24, x24, #1
    b .Lec_loop
.Lec_yes:
    mov x0, #1
    b .Lec_done
.Lec_no:
    mov x0, #0
.Lec_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// Additive hooks — documented for Phases 4-7
// ============================================================================

// ----------------------------------------------------------------------------
// tc_build_exclusions() -> 0  (may tc_fail)
//   Fills tc_excl_set + tc_excl_sources + tc_excl_src_count exactly as the
//   Python build_exclusions folds config_exclusions/exclusion_layers: layers
//   ADD (first source wins per login), --include subtracts, --no-exclude
//   clears everything after a conflict check.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_build_exclusions
    FUNC_TYPE(tc_build_exclusions)
tc_build_exclusions:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    stp x27, x28, [sp, #-16]!
    bl ensure_config_loaded
    // ---- reset the merged set + sources --------------------------------
    adrp x0, PAGE(tc_excl_set)
    add x0, x0, LO12(tc_excl_set)
    str xzr, [x0]                   // TC_EX_COUNT = 0
    adrp x0, PAGE(tc_excl_src_count)
    add x0, x0, LO12(tc_excl_src_count)
    str xzr, [x0]
    adrp x0, PAGE(tc_excl_group_n)
    add x0, x0, LO12(tc_excl_group_n)
    str xzr, [x0]
    adrp x0, PAGE(tc_excl_always_n)
    add x0, x0, LO12(tc_excl_always_n)
    str xzr, [x0]
    adrp x0, PAGE(tc_excl_flat_n)
    add x0, x0, LO12(tc_excl_flat_n)
    str xzr, [x0]
    adrp x0, PAGE(tc_excl_tmp_cur)
    add x0, x0, LO12(tc_excl_tmp_cur)
    str xzr, [x0]

    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x19, [x0, #TC_O_FLAGS]
    // ---- --no-exclude: conflict check, then clear ----------------------
    tst x19, #TC_F_NO_EXCLUDE
    b.eq .Lbe_normal
    adrp x20, PAGE(tc_cfg_scratch)
    add x20, x20, LO12(tc_cfg_scratch)
    mov x0, x20
    adrp x1, PAGE(s_noexcl_prefix)
    add x1, x1, LO12(s_noexcl_prefix)
    bl cat_cstr
    mov x21, x0                     // end ptr
    mov x22, #0                     // wrote_any
    tst x19, #TC_F_EXCL_GIVEN
    b.eq .Lbe_nx_group
    mov x0, x21
    mov x1, x22
    bl cat_comma_if
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_flag_exclude)
    add x1, x1, LO12(s_flag_exclude)
    bl cat_cstr
    mov x21, x0
    mov x22, #1
.Lbe_nx_group:
    tst x19, #TC_F_EXCL_GROUP_GIVEN
    b.eq .Lbe_nx_bcast
    mov x0, x21
    mov x1, x22
    bl cat_comma_if
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_flag_exclude_group)
    add x1, x1, LO12(s_flag_exclude_group)
    bl cat_cstr
    mov x21, x0
    mov x22, #1
.Lbe_nx_bcast:
    tst x19, #TC_F_EXCLUDE_BCAST
    b.eq .Lbe_nx_include
    mov x0, x21
    mov x1, x22
    bl cat_comma_if
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_flag_exclude_bcast)
    add x1, x1, LO12(s_flag_exclude_bcast)
    bl cat_cstr
    mov x21, x0
    mov x22, #1
.Lbe_nx_include:
    tst x19, #TC_F_INCL_GIVEN
    b.eq .Lbe_nx_done
    mov x0, x21
    mov x1, x22
    bl cat_comma_if
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_flag_include)
    add x1, x1, LO12(s_flag_include)
    bl cat_cstr
    mov x22, #1
.Lbe_nx_done:
    cbz x22, .Lbe_ok
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Lbe_ok:
    mov x0, #0
    b .Lbe_done

.Lbe_normal:
    // ---- read the config [exclude] table -------------------------------
    bl build_groups

    // ---- validate --exclude-group names (Python exclusion_layers) -------
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x1, #TC_O_EXCL_GROUP_COUNT
    add x1, x0, x1
    ldr x20, [x1]
    mov x1, #TC_O_EXCL_GROUP_LIST
    add x21, x0, x1
    mov x22, #0
.Lbe_grp_check:
    cmp x22, x20
    b.ge .Lbe_grp_done
    mov x0, #32
    mul x0, x22, x0
    add x0, x21, x0
    bl group_index_of
    cmn x0, #1
    b.ne .Lbe_grp_next
    // unknown group error: "unknown exclude group '<name>'; defined groups: <sorted>"
    adrp x24, PAGE(tc_cfg_scratch)
    add x24, x24, LO12(tc_cfg_scratch)
    mov x0, x24
    adrp x1, PAGE(s_unknown_group_pre)
    add x1, x1, LO12(s_unknown_group_pre)
    bl cat_cstr
    mov x24, x0
    mov x0, x24
    mov x1, #32
    mul x1, x22, x1
    add x1, x21, x1
    bl cat_cstr
    mov x24, x0
    mov x0, x24
    adrp x1, PAGE(s_defined_groups)
    add x1, x1, LO12(s_defined_groups)
    bl cat_cstr
    mov x24, x0
    mov x0, x24
    adrp x1, PAGE(tc_cfg_scratch2)
    add x1, x1, LO12(tc_cfg_scratch2)
    bl sort_groups_join
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Lbe_grp_next:
    add x22, x22, #1
    b .Lbe_grp_check
.Lbe_grp_done:

    // ---- layer 1: config flat exclude ----------------------------------
    adrp x0, PAGE(tc_excl_flat_n)
    add x0, x0, LO12(tc_excl_flat_n)
    ldr x0, [x0]
    cbz x0, .Lbe_layer_always
    adrp x0, PAGE(s_src_excl_config_label)
    add x0, x0, LO12(s_src_excl_config_label)
    bl source_add_cstr
    mov x20, x0                     // source idx
    bl apply_flat_tokens
.Lbe_layer_always:
    // ---- layer 2: config always:<name> --------------------------------
    adrp x0, PAGE(tc_excl_always_n)
    add x0, x0, LO12(tc_excl_always_n)
    ldr x22, [x0]
    adrp x23, PAGE(tc_excl_always)
    add x23, x23, LO12(tc_excl_always)
    mov x24, #0
.Lbe_always_loop:
    cmp x24, x22
    b.ge .Lbe_layer_group
    // the group's login array
    mov x0, x24
    bl always_group_arr
    cbz x0, .Lbe_always_next
    mov x25, x0
    mov x0, x25
    bl split_toml_array
    cbz x0, .Lbe_always_next        // empty group -> layer skipped
    // compose "config always:<name>" into tc_excl_src_buf
    mov x0, x24
    bl excl_src_buf_slot
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_src_excl_always)
    add x1, x1, LO12(s_src_excl_always)
    bl cat_cstr
    mov x21, x0
    mov x2, #16
    mul x2, x24, x2
    ldr x25, [x23, x2]              // name ptr
    mov x0, x21
    mov x1, x25
    bl cat_cstr
    mov x0, x24
    bl excl_src_buf_slot
    bl tc_strlen
    mov x25, x0                     // len (excl_src_buf_slot clobbers x1)
    mov x0, x24
    bl excl_src_buf_slot
    mov x1, x25
    bl source_add
    mov x20, x0
    bl apply_split_tokens
.Lbe_always_next:
    add x24, x24, #1
    b .Lbe_always_loop

.Lbe_layer_group:
    // ---- layer 3: --exclude-group <name> ------------------------------
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x1, #TC_O_EXCL_GROUP_COUNT
    add x1, x0, x1
    ldr x22, [x1]
    mov x1, #TC_O_EXCL_GROUP_LIST
    add x23, x0, x1
    mov x24, #0
.Lbe_grp_loop:
    cmp x24, x22
    b.ge .Lbe_layer_env
    mov x0, #32
    mul x0, x24, x0
    add x0, x23, x0
    bl group_index_of
    cmn x0, #1
    b.eq .Lbe_grp_next2             // (validated above; defensive)
    mov x25, x0
    mov x0, x25
    bl group_arr_at
    cbz x0, .Lbe_grp_next2
    mov x26, x0
    mov x0, x26
    bl split_toml_array
    cbz x0, .Lbe_grp_next2
    mov x26, x0
    mov x0, x26
    // compose "--exclude-group <name>" (group labels live in slots 64+)
    add x0, x24, #EX_GROUP_MAX
    bl excl_src_buf_slot
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_src_excl_group)
    add x1, x1, LO12(s_src_excl_group)
    bl cat_cstr
    mov x21, x0
    mov x0, x21
    mov x1, #32
    mul x1, x24, x1
    add x1, x23, x1
    bl cat_cstr
    add x0, x24, #EX_GROUP_MAX
    bl excl_src_buf_slot
    bl tc_strlen
    mov x1, x0
    mov x25, x1
    add x0, x24, #EX_GROUP_MAX
    bl excl_src_buf_slot
    mov x26, x0
    mov x1, x25
    mov x0, x26
    mov x1, x25
    bl source_add
    mov x20, x0
    bl apply_split_tokens
.Lbe_grp_next2:
    add x24, x24, #1
    b .Lbe_grp_loop

.Lbe_layer_env:
    // ---- layer 4: env TWITCH_EXCLUDE ----------------------------------
    adrp x0, PAGE(s_env_exclude)
    add x0, x0, LO12(s_env_exclude)
    bl getenv
    cbz x0, .Lbe_layer_cli
    ldrb w1, [x0]
    cbz w1, .Lbe_layer_cli
    bl split_names
    cbz x0, .Lbe_layer_cli
    adrp x0, PAGE(s_src_excl_env_label)
    add x0, x0, LO12(s_src_excl_env_label)
    bl source_add_cstr
    mov x20, x0
    bl apply_split_tokens

.Lbe_layer_cli:
    // ---- layer 5: --exclude (repeatable, one flattened layer) ----------
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x1, #TC_O_EXCL_COUNT
    add x1, x0, x1
    ldr x22, [x1]
    mov x1, #TC_O_EXCL_LIST
    add x23, x0, x1
    mov x24, #0
    mov x25, #0                     // any token chars seen?
.Lbe_cli_scan:
    cmp x24, x22
    b.ge .Lbe_cli_scan_done
    mov x0, #64
    mul x0, x24, x0
    add x0, x23, x0
    bl has_token_char
    cbnz x0, .Lbe_cli_scan_yes
    add x24, x24, #1
    b .Lbe_cli_scan
.Lbe_cli_scan_yes:
    mov x25, #1
.Lbe_cli_scan_done:
    cbz x25, .Lbe_cli_done
    adrp x0, PAGE(s_flag_exclude)
    add x0, x0, LO12(s_flag_exclude)
    bl source_add_cstr
    mov x20, x0
    mov x24, #0
.Lbe_cli_loop:
    cmp x24, x22
    b.ge .Lbe_cli_done
    mov x0, #64
    mul x0, x24, x0
    add x0, x23, x0
    bl split_names
    cbz x0, .Lbe_cli_next
    mov x26, x0                     // count
    mov x0, x20
    mov x1, x26
    bl apply_split_tokens_n
.Lbe_cli_next:
    add x24, x24, #1
    b .Lbe_cli_loop
.Lbe_cli_done:

    // ---- layer 6: --exclude-broadcaster --------------------------------
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_EXCL_BCAST_VAL]
    cbz x1, .Lbe_include
    mov x2, #TC_O_SRC
    add x2, x0, x2
    ldr x0, [x2, #TC_SET_EXCLUDE_BCAST*8]
    bl tc_source_str                // x0=ptr, x1=len
    bl source_add
    mov x20, x0                     // source idx
    // login = lowercased resolved channel
    adrp x0, PAGE(tc_cfg_scratch2)
    add x0, x0, LO12(tc_cfg_scratch2)
    mov x21, x0                     // dst
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_CHANNEL       // src
    bl lowercase_copy
    mov x0, x21
    bl tc_strlen
    mov x1, x0                      // len
    mov x0, x21                     // login
    mov x2, x20                     // source idx
    bl add_excl_login

.Lbe_include:
    // ---- --include subtraction ------------------------------------------
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x1, #TC_O_INCL_COUNT
    add x1, x0, x1
    ldr x22, [x1]
    mov x1, #TC_O_INCL_LIST
    add x23, x0, x1
    mov x24, #0
    mov x25, #0                     // removed
.Lbe_incl_loop:
    cmp x24, x22
    b.ge .Lbe_incl_done
    mov x0, #64
    mul x0, x24, x0
    add x0, x23, x0
    bl split_names
    mov x26, x0                     // count
    mov x27, #0
.Lbe_incl_tok:
    cmp x27, x26
    b.ge .Lbe_incl_next
    adrp x0, PAGE(tc_split_tab)
    add x0, x0, LO12(tc_split_tab)
    mov x1, #16
    mul x1, x27, x1
    add x0, x0, x1
    ldr x19, [x0]                   // token ptr
    ldr x1, [x0, #8]                // token len
    mov x0, x19
    bl excl_remove_if_present       // x0 = 0/1 removed
    add x25, x25, x0
    add x27, x27, #1
    b .Lbe_incl_tok
.Lbe_incl_next:
    add x24, x24, #1
    b .Lbe_incl_loop
.Lbe_incl_done:
    cbz x25, .Lbe_done_ok
    // append "minus --include (N)" (dedicated slot 200)
    mov x0, #200
    bl excl_src_buf_slot
    mov x21, x0
    mov x0, x21
    adrp x1, PAGE(s_minus_include)
    add x1, x1, LO12(s_minus_include)
    bl cat_cstr
    mov x21, x0
    mov x0, x21
    mov x1, x25
    bl cat_u64
    adrp x1, PAGE(s_rparen)
    add x1, x1, LO12(s_rparen)
    bl cat_cstr
    mov x0, #200
    bl excl_src_buf_slot
    bl tc_strlen
    mov x25, x0                     // len (excl_src_buf_slot clobbers x1)
    mov x0, #200
    bl excl_src_buf_slot
    mov x1, x25
    bl source_add
.Lbe_done_ok:
    mov x0, #0
.Lbe_done:
    adrp x0, PAGE(tc_excl_src_count)
    add x0, x0, LO12(tc_excl_src_count)
    ldr x1, [x0]
    adrp x0, PAGE(tc_cfg_scratch2)
    add x0, x0, LO12(tc_cfg_scratch2)
    mov x2, x0
    mov x0, x2
    mov x1, x1
    adrp x0, PAGE(tc_cfg_scratch2)
    add x0, x0, LO12(tc_cfg_scratch2)
    ldp x27, x28, [sp], #16
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_config_identity() -> (x0=path or 0, x1=size, x2=mtime_ns)
//   Python config_identity: ("none",) under --no-config -> x0=0; else the
//   (path, size, mtime_ns) of the chosen file, or (path, 0, 0) when it is
//   not a regular file.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_config_identity
    FUNC_TYPE(tc_config_identity)
tc_config_identity:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_NO_CONFIG
    b.ne .Lci_none
    bl config_resolve_path
    adrp x0, PAGE(tc_cfg_path)
    add x0, x0, LO12(tc_cfg_path)
    mov x19, x0
    adrp x0, PAGE(tc_cfg_statbuf)
    add x1, x0, LO12(tc_cfg_statbuf)
    mov x0, x19
    bl stat
    cbnz x0, .Lci_missing
    adrp x0, PAGE(tc_cfg_statbuf)
    add x0, x0, LO12(tc_cfg_statbuf)
    LOAD_ST_MODE 1, x0
    and x1, x1, #S_IFMT
    cmp x1, #S_IFREG
    b.ne .Lci_missing
    ldr x1, [x0, #ST_SIZE]
    ldr x2, [x0, #ST_MTIM_SEC]
    movz x3, #0xCA00, lsl #0
    movk x3, #0x3B9A, lsl #16       // 1000000000
    mul x2, x2, x3
    ldr x3, [x0, #ST_MTIM_NSEC]
    add x2, x2, x3
    mov x0, x19
    b .Lci_done
.Lci_missing:
    mov x0, x19
    mov x1, #0
    mov x2, #0
    b .Lci_done
.Lci_none:
    mov x0, #0
    mov x1, #0
    mov x2, #0
.Lci_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_config_changed() -> x0 = 0/1  — the loaded file's identity moved.
//   A config that was never loaded stays "unchanged" (Python memoizes a
//   missing file permanently).
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_config_changed
    FUNC_TYPE(tc_config_changed)
tc_config_changed:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    ldr x0, [x0]
    cmp x0, #CFG_ST_LOADED
    b.ne .Lcc_no
    adrp x0, PAGE(tc_cfg_path)
    add x0, x0, LO12(tc_cfg_path)
    mov x19, x0
    adrp x0, PAGE(tc_cfg_statbuf)
    add x1, x0, LO12(tc_cfg_statbuf)
    mov x0, x19
    bl stat
    cbnz x0, .Lcc_yes              // vanished -> changed
    adrp x0, PAGE(tc_cfg_statbuf)
    add x0, x0, LO12(tc_cfg_statbuf)
    ldr x1, [x0, #ST_SIZE]
    adrp x20, PAGE(tc_cfg_size)
    add x20, x20, LO12(tc_cfg_size)
    ldr x2, [x20]
    cmp x1, x2
    b.ne .Lcc_yes
    ldr x1, [x0, #ST_MTIM_SEC]
    adrp x20, PAGE(tc_cfg_mtime)
    add x20, x20, LO12(tc_cfg_mtime)
    ldr x2, [x20]
    cmp x1, x2
    b.ne .Lcc_yes
    ldr x1, [x0, #ST_MTIM_NSEC]
    adrp x20, PAGE(tc_cfg_mtime_ns)
    add x20, x20, LO12(tc_cfg_mtime_ns)
    ldr x2, [x20]
    cmp x1, x2
    b.ne .Lcc_yes
    mov x0, #0
    b .Lcc_done
.Lcc_yes:
    mov x0, #1
    b .Lcc_done
.Lcc_no:
    mov x0, #0
.Lcc_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_config_reload() -> 0 — drop the parsed table and re-read the file.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_config_reload
    FUNC_TYPE(tc_config_reload)
tc_config_reload:
    stp x29, x30, [sp, #-16]!
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    ldr x0, [x0]
    cmp x0, #CFG_ST_LOADED
    b.ne .Lcr_noop
    adrp x0, PAGE(tc_cfg_root)
    add x0, x0, LO12(tc_cfg_root)
    ldr x0, [x0]
    cbz x0, .Lcr_noop
    bl toml_free
    adrp x0, PAGE(tc_cfg_root)
    add x0, x0, LO12(tc_cfg_root)
    str xzr, [x0]
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    str xzr, [x0]
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    str xzr, [x0, #TC_O_CONFIG_LOADED]
    bl ensure_config_loaded
.Lcr_noop:
    mov x0, #0
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// tc_shorten_path(x0=path) -> x0 = pointer to the shortened path.
//   Python shorten_path: replace a leading $HOME with "~".
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_shorten_path
    FUNC_TYPE(tc_shorten_path)
tc_shorten_path:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // path
    adrp x0, PAGE(s_home)
    add x0, x0, LO12(s_home)
    bl getenv
    cbz x0, .Lsp_orig
    ldrb w1, [x0]
    cbz w1, .Lsp_orig
    mov x20, x0                     // home
    mov x0, x19
    mov x1, x20
    bl starts_with
    cbz x0, .Lsp_orig
    mov x0, x19
    bl tc_strlen
    mov x21, x0                     // path len
    mov x0, x20
    bl tc_strlen
    mov x22, x0                     // home len
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    mov x1, #'~'
    strb w1, [x0], #1
    mov x1, x19
    add x1, x1, x22
    mov x2, x21
    sub x2, x2, x22
    bl copy_n_nul
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    b .Lsp_done
.Lsp_orig:
    mov x0, x19
.Lsp_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// Internal helpers
// ============================================================================

// ----------------------------------------------------------------------------
// ensure_config_loaded() — idempotent lazy load.  Called by every exported
// hook so config-load errors surface before any env/config value is consumed
// (Python build_inputs ordering).  On error: tc_fail (noreturn).
// ----------------------------------------------------------------------------
    .p2align 2
ensure_config_loaded:
    stp x29, x30, [sp, #-16]!
    // keep TC_O_CONFIG_PATH in step with the resolved path: tc_resolve_settings
    // clobbers it with the literal default after the first load, so restore it
    // whenever a path has been resolved.
    adrp x0, PAGE(tc_cfg_path)
    add x0, x0, LO12(tc_cfg_path)
    ldrb w1, [x0]
    cbz w1, .Lel_no_path
    adrp x1, PAGE(tc_opts)
    add x1, x1, LO12(tc_opts)
    add x1, x1, #TC_O_CONFIG_PATH
    mov x2, #CFG_PATH_SZ
    mov x0, x1                     // dst = TC_O_CONFIG_PATH
    adrp x1, PAGE(tc_cfg_path)
    add x1, x1, LO12(tc_cfg_path)
    bl tc_copy_str_cap
.Lel_no_path:
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    ldr x0, [x0]
    cbnz x0, .Lel_done             // loaded, decided, or busy
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    mov x1, #CFG_ST_BUSY
    str x1, [x0]
    bl config_resolve_path
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_NO_CONFIG
    b.eq .Lel_do_load
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    mov x1, #CFG_ST_NOLOAD
    str x1, [x0]
    b .Lel_done
.Lel_do_load:
    bl config_do_load
.Lel_done:
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// config_resolve_path() — choose and expand the config path (Python
// load_config_layer).  Fills tc_cfg_path, tc_cfg_where, tc_cfg_explicit and
// TC_O_CONFIG_PATH.  Never fails.
// ----------------------------------------------------------------------------
    .p2align 2
config_resolve_path:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    ldr x1, [x0, #TC_O_FLAGS]
    tst x1, #TC_F_CONFIG_GIVEN
    b.eq .Lcr_env
    add x1, x0, #TC_O_CONFIG_PATH
    mov x19, x1
    mov x20, #1                     // explicit
    b .Lcr_expand
.Lcr_env:
    adrp x0, PAGE(s_env_config)
    add x0, x0, LO12(s_env_config)
    bl getenv
    cbz x0, .Lcr_default
    ldrb w1, [x0]
    cbz w1, .Lcr_default
    mov x19, x0
    mov x20, #1                     // explicit
    b .Lcr_expand
.Lcr_default:
    // XDG_CONFIG_HOME or $HOME/.config + "/twitch-counts.toml"
    adrp x0, PAGE(s_env_xdg)
    add x0, x0, LO12(s_env_xdg)
    bl getenv
    cbz x0, .Lcr_home
    ldrb w1, [x0]
    cbz w1, .Lcr_home
    mov x19, x0
    mov x20, #0
    adrp x21, PAGE(tc_cfg_scratch)
    add x21, x21, LO12(tc_cfg_scratch)
    mov x0, x21
    mov x1, x19
    bl cat_cstr
    adrp x1, PAGE(s_xdg_tail)
    add x1, x1, LO12(s_xdg_tail)
    bl cat_cstr
    adrp x19, PAGE(tc_cfg_scratch)
    add x19, x19, LO12(tc_cfg_scratch)
    b .Lcr_expand
.Lcr_home:
    adrp x0, PAGE(s_home)
    add x0, x0, LO12(s_home)
    bl getenv
    cbz x0, .Lcr_nohome
    ldrb w1, [x0]
    cbz w1, .Lcr_nohome
    mov x19, x0
    mov x20, #0
    adrp x21, PAGE(tc_cfg_scratch)
    add x21, x21, LO12(tc_cfg_scratch)
    mov x0, x21
    mov x1, x19
    bl cat_cstr
    adrp x1, PAGE(s_home_config_tail)
    add x1, x1, LO12(s_home_config_tail)
    bl cat_cstr
    adrp x19, PAGE(tc_cfg_scratch)
    add x19, x19, LO12(tc_cfg_scratch)
    b .Lcr_expand
.Lcr_nohome:
    adrp x19, PAGE(s_default_config_path)
    add x19, x19, LO12(s_default_config_path)
    mov x20, #0
.Lcr_expand:
    // expanduser: a leading "~" becomes $HOME (Python os.path.expanduser)
    ldrb w1, [x19]
    cmp w1, #'~'
    b.ne .Lcr_copy
    adrp x0, PAGE(s_home)
    add x0, x0, LO12(s_home)
    bl getenv
    cbz x0, .Lcr_copy
    ldrb w1, [x0]
    cbz w1, .Lcr_copy
    mov x21, x0                     // home
    add x22, x19, #1                // skip the '~'
    adrp x23, PAGE(tc_cfg_scratch)
    add x23, x23, LO12(tc_cfg_scratch)
    mov x0, x23
    mov x1, x21
    bl cat_cstr
    mov x0, x0                      // end
    mov x1, x22
    bl cat_cstr
    adrp x19, PAGE(tc_cfg_scratch)
    add x19, x19, LO12(tc_cfg_scratch)
.Lcr_copy:
    adrp x0, PAGE(tc_cfg_path)
    add x0, x0, LO12(tc_cfg_path)
    mov x1, x19
    mov x2, #CFG_PATH_SZ
    bl tc_copy_str_cap
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    add x0, x0, #TC_O_CONFIG_PATH
    adrp x1, PAGE(tc_cfg_path)
    add x1, x1, LO12(tc_cfg_path)
    mov x2, #CFG_PATH_SZ
    bl tc_copy_str_cap
    // tc_cfg_where = shorten_path(tc_cfg_path)
    adrp x0, PAGE(tc_cfg_path)
    add x0, x0, LO12(tc_cfg_path)
    bl tc_shorten_path
    mov x19, x0
    adrp x0, PAGE(tc_cfg_where)
    add x0, x0, LO12(tc_cfg_where)
    mov x1, x19
    mov x2, #CFG_PATH_SZ
    bl tc_copy_str_cap
    adrp x0, PAGE(tc_cfg_explicit)
    add x0, x0, LO12(tc_cfg_explicit)
    str x20, [x0]
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// config_do_load() — stat/open/read/toml_parse + the load-time table checks.
// Sets tc_cfg_state = CFG_ST_LOADED or CFG_ST_NOLOAD; tc_fail on errors.
// ----------------------------------------------------------------------------
    .p2align 2
config_do_load:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    // ---- stat -----------------------------------------------------------
    adrp x19, PAGE(tc_cfg_path)
    add x19, x19, LO12(tc_cfg_path)
    adrp x20, PAGE(tc_cfg_statbuf)
    add x20, x20, LO12(tc_cfg_statbuf)
    mov x0, x19
    mov x1, x20
    bl stat
    cbnz x0, .Ldl_notfile
    LOAD_ST_MODE 1, x20
    and x1, x1, #S_IFMT
    cmp x1, #S_IFREG
    b.ne .Ldl_notfile
    // ---- open -----------------------------------------------------------
    mov x0, x19
    mov x1, #O_RDONLY
    bl open
    cmn x0, #1
    b.eq .Ldl_open_fail
    mov x21, x0                     // fd
    // ---- read all -------------------------------------------------------
    mov x0, #4096
    bl malloc
    cbz x0, .Ldl_oom
    adrp x1, PAGE(tc_cfg_buf)
    add x1, x1, LO12(tc_cfg_buf)
    str x0, [x1]
    adrp x1, PAGE(tc_cfg_bufsz)
    add x1, x1, LO12(tc_cfg_bufsz)
    mov x2, #4096
    str x2, [x1]
    mov x22, x0                     // buf
    mov x23, #4096                  // bufsz
    mov x24, #0                     // off
.Ldl_read_loop:
    cmp x24, x23
    b.lt .Ldl_read
    mov x0, x22
    mov x1, x23
    lsl x1, x1, #1
    bl realloc
    cbz x0, .Ldl_oom
    mov x22, x0
    adrp x1, PAGE(tc_cfg_buf)
    add x1, x1, LO12(tc_cfg_buf)
    str x0, [x1]
    lsl x23, x23, #1
    adrp x1, PAGE(tc_cfg_bufsz)
    add x1, x1, LO12(tc_cfg_bufsz)
    str x23, [x1]
.Ldl_read:
    mov x0, x21
    add x1, x22, x24
    sub x2, x23, x24
    bl read
    cmn x0, #1
    b.eq .Ldl_read_fail
    cbz x0, .Ldl_read_done
    add x24, x24, x0
    b .Ldl_read_loop
.Ldl_read_done:
    mov w0, #0
    strb w0, [x22, x24]             // NUL-terminate
    mov x0, x21
    bl close
    // ---- parse ----------------------------------------------------------
    adrp x0, PAGE(tc_cfg_buf)
    add x0, x0, LO12(tc_cfg_buf)
    ldr x0, [x0]
    adrp x1, PAGE(tc_cfg_errbuf)
    add x1, x1, LO12(tc_cfg_errbuf)
    mov w2, #CFG_ERRBUF_SZ
    bl toml_parse
    mov x21, x0                     // root table or 0
    adrp x0, PAGE(tc_cfg_buf)
    add x0, x0, LO12(tc_cfg_buf)
    ldr x0, [x0]
    bl free
    adrp x0, PAGE(tc_cfg_buf)
    add x0, x0, LO12(tc_cfg_buf)
    str xzr, [x0]
    cbz x21, .Ldl_parse_err
    // (tomlc99 always returns a table; the Python "must be a table of
    //  settings" guard has no tomlc99 counterpart.)
    adrp x0, PAGE(tc_cfg_root)
    add x0, x0, LO12(tc_cfg_root)
    str x21, [x0]
    // ---- aliases table check (Python build_inputs, before sections) -----
    mov x0, x21
    adrp x1, PAGE(s_key_aliases)
    add x1, x1, LO12(s_key_aliases)
    bl toml_table_in
    cbnz x0, .Ldl_watch
    mov x0, x21
    adrp x1, PAGE(s_key_aliases)
    add x1, x1, LO12(s_key_aliases)
    bl toml_array_in
    cbz x0, .Ldl_aliases_scalar
    bl toml_array_nelem
    cbnz w0, .Ldl_aliases_bad
    b .Ldl_watch
.Ldl_aliases_scalar:
    mov x0, x21
    adrp x1, PAGE(s_key_aliases)
    add x1, x1, LO12(s_key_aliases)
    bl toml_raw_in
    cbz x0, .Ldl_watch
    bl aliases_scalar_ok            // x0 = 0/1 (falsy value -> ok)
    cbnz x0, .Ldl_watch
.Ldl_aliases_bad:
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    adrp x1, PAGE(s_aliases_bad_pre)
    add x1, x1, LO12(s_aliases_bad_pre)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_where)
    add x1, x1, LO12(tc_cfg_where)
    bl cat_cstr
    adrp x1, PAGE(s_aliases_bad_suf)
    add x1, x1, LO12(s_aliases_bad_suf)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Ldl_watch:
    // ---- [watch] must be a table ----------------------------------------
    mov x0, x21
    adrp x1, PAGE(s_key_watch)
    add x1, x1, LO12(s_key_watch)
    bl toml_table_in
    cbnz x0, .Ldl_tail
    adrp x0, PAGE(s_key_watch)
    add x0, x0, LO12(s_key_watch)
    bl section_must_be_table_check
.Ldl_tail:
    // ---- [tail] must be a table -----------------------------------------
    mov x0, x21
    adrp x1, PAGE(s_key_tail)
    add x1, x1, LO12(s_key_tail)
    bl toml_table_in
    cbnz x0, .Ldl_loaded
    adrp x0, PAGE(s_key_tail)
    add x0, x0, LO12(s_key_tail)
    bl section_must_be_table_check
.Ldl_loaded:
    // ---- record identity + mark loaded ----------------------------------
    ldr x1, [x20, #ST_SIZE]
    adrp x0, PAGE(tc_cfg_size)
    add x0, x0, LO12(tc_cfg_size)
    str x1, [x0]
    ldr x1, [x20, #ST_MTIM_SEC]
    adrp x0, PAGE(tc_cfg_mtime)
    add x0, x0, LO12(tc_cfg_mtime)
    str x1, [x0]
    ldr x1, [x20, #ST_MTIM_NSEC]
    adrp x0, PAGE(tc_cfg_mtime_ns)
    add x0, x0, LO12(tc_cfg_mtime_ns)
    str x1, [x0]
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    mov x1, #CFG_ST_LOADED
    str x1, [x0]
    adrp x0, PAGE(tc_opts)
    add x0, x0, LO12(tc_opts)
    mov x1, #1
    str x1, [x0, #TC_O_CONFIG_LOADED]
    b .Ldl_done

.Ldl_notfile:
    // missing (or not a regular file): default -> not loaded; explicit -> error
    adrp x0, PAGE(tc_cfg_explicit)
    add x0, x0, LO12(tc_cfg_explicit)
    ldr x0, [x0]
    cbz x0, .Ldl_notfile_ok
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    adrp x1, PAGE(s_config_not_found)
    add x1, x1, LO12(s_config_not_found)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_path)
    add x1, x1, LO12(tc_cfg_path)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Ldl_notfile_ok:
    adrp x0, PAGE(tc_cfg_state)
    add x0, x0, LO12(tc_cfg_state)
    mov x1, #CFG_ST_NOLOAD
    str x1, [x0]
    b .Ldl_done

.Ldl_open_fail:
    bl cfg_errno_message
    bl tc_fail
.Ldl_read_fail:
    mov x0, x21
    bl close
    bl cfg_errno_message
    bl tc_fail
.Ldl_parse_err:
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    adrp x1, PAGE(s_could_not_read)
    add x1, x1, LO12(s_could_not_read)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_path)
    add x1, x1, LO12(tc_cfg_path)
    bl cat_cstr
    adrp x1, PAGE(s_colon_space)
    add x1, x1, LO12(s_colon_space)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_errbuf)
    add x1, x1, LO12(tc_cfg_errbuf)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Ldl_oom:
    adrp x0, PAGE(s_oom)
    add x0, x0, LO12(s_oom)
    bl tc_fail

.Ldl_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// section_must_be_table_check(x0=key) — error "[<key>] in <where> must be a
// table" when the root has the key as anything but a sub-table.
// ----------------------------------------------------------------------------
    .p2align 2
section_must_be_table_check:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // key
    adrp x20, PAGE(tc_cfg_root)
    add x20, x20, LO12(tc_cfg_root)
    ldr x20, [x20]                  // root
    mov x0, x20
    mov x1, x19
    bl toml_table_in
    cbnz x0, .Lsm_ok
    mov x0, x20
    mov x1, x19
    bl toml_array_in
    cbnz x0, .Lsm_bad
    mov x0, x20
    mov x1, x19
    bl toml_raw_in
    cbz x0, .Lsm_ok
.Lsm_bad:
    adrp x21, PAGE(tc_cfg_scratch)
    add x21, x21, LO12(tc_cfg_scratch)
    mov x0, x21
    mov x1, #'['
    strb w1, [x0], #1
    mov x1, x19
    bl cat_cstr
    adrp x1, PAGE(s_sect_mid)
    add x1, x1, LO12(s_sect_mid)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_where)
    add x1, x1, LO12(tc_cfg_where)
    bl cat_cstr
    adrp x1, PAGE(s_sect_suf)
    add x1, x1, LO12(s_sect_suf)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Lsm_ok:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// aliases_scalar_ok(x0=raw) -> x0 = 0/1  — Python `or {}` falsy handling:
// an empty string, "0", "0.0" or "false" counts as absent.
// ----------------------------------------------------------------------------
    .p2align 2
aliases_scalar_ok:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    ldrb w1, [x19]
    cmp w1, #'"'
    b.eq .Las_quote
    cmp w1, #'\''
    b.eq .Las_quote
    adrp x1, PAGE(s_false)
    add x1, x1, LO12(s_false)
    mov x0, x19
    bl streq
    cbnz x0, .Las_yes
    adrp x1, PAGE(s_zero)
    add x1, x1, LO12(s_zero)
    mov x0, x19
    bl streq
    cbnz x0, .Las_yes
    adrp x1, PAGE(s_zero_float)
    add x1, x1, LO12(s_zero_float)
    mov x0, x19
    bl streq
    cbnz x0, .Las_yes
    b .Las_no
.Las_quote:
    mov x0, x19
    bl toml_value_to_string
    ldrb w1, [x0]
    cbz w1, .Las_yes
    b .Las_no
.Las_yes:
    mov x0, #1
    b .Las_done
.Las_no:
    mov x0, #0
.Las_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cfg_errno_message() — build "could not read config <path>: [Errno N] <msg>
// : '<path>'" into tc_cfg_scratch (Python OSError parity).  Does NOT exit.
// ----------------------------------------------------------------------------
    .p2align 2
cfg_errno_message:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    // capture errno first
    bl __errno_location
    ldr w20, [x0]                   // errno (int; w-load zero-extends into x20)
    mov x0, x20
    bl strerror
    mov x21, x0                     // strerror text
    // "[Errno N] msg: '<path>'"
    adrp x22, PAGE(tc_cfg_scratch2)
    add x22, x22, LO12(tc_cfg_scratch2)
    mov x0, x22
    adrp x1, PAGE(s_errno_lb)
    add x1, x1, LO12(s_errno_lb)
    bl cat_cstr
    mov x22, x0
    mov x0, x22
    mov x1, x20
    bl cat_u64
    mov x22, x0
    mov x0, x22
    adrp x1, PAGE(s_errno_rb)
    add x1, x1, LO12(s_errno_rb)
    bl cat_cstr
    mov x22, x0
    mov x0, x22
    mov x1, x21
    bl cat_cstr
    mov x22, x0
    mov x0, x22
    adrp x1, PAGE(s_colon_space)
    add x1, x1, LO12(s_colon_space)
    bl cat_cstr
    mov x22, x0
    mov x0, x22
    adrp x1, PAGE(s_squote)
    add x1, x1, LO12(s_squote)
    bl cat_cstr
    mov x22, x0
    mov x0, x22
    adrp x1, PAGE(tc_cfg_path)
    add x1, x1, LO12(tc_cfg_path)
    bl cat_cstr
    mov x22, x0
    mov x0, x22
    adrp x1, PAGE(s_squote)
    add x1, x1, LO12(s_squote)
    bl cat_cstr
    // "could not read config <path>: " + the above
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    adrp x1, PAGE(s_could_not_read)
    add x1, x1, LO12(s_could_not_read)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_path)
    add x1, x1, LO12(tc_cfg_path)
    bl cat_cstr
    adrp x1, PAGE(s_colon_space)
    add x1, x1, LO12(s_colon_space)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_scratch2)
    add x1, x1, LO12(tc_cfg_scratch2)
    bl cat_cstr
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// toml_value_to_string(x0=raw) -> x0 = string pointer.
//   Non-string raws (ints/floats/bools/dates) are returned as-is (their text
//   is already what Python's str() would produce for the common cases).  String
//   raws are unquoted into one of two alternating value buffers so two
//   outstanding config values (tc_resolve_window's begin+since) stay valid.
// ----------------------------------------------------------------------------
    .p2align 2
toml_value_to_string:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    ldrb w1, [x0]
    cmp w1, #'"'
    b.eq .Lvs_quote
    cmp w1, #'\''
    b.eq .Lvs_quote
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret
.Lvs_quote:
    mov x19, x0
    bl cfg_value_buf                // x0 = dst
    mov x20, x0
    mov x0, x20
    mov x1, x19
    bl toml_unquote_into
    mov x0, x20
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// toml_unquote_into(x0=dst, x1=raw) — toml_rtos into a malloc'd temp, copy
// into dst, free.  Preserves x19-x28.
// ----------------------------------------------------------------------------
    .p2align 2
toml_unquote_into:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #32                 // [sp] = char* slot (toml_rtos ret)
    mov x19, x0                     // dst
    mov x20, x1                     // raw
    add x1, sp, #0
    mov x0, x20
    bl toml_rtos
    cbnz w0, .Ltu_skip              // not a string: leave dst untouched
    ldr x20, [sp]                   // malloc'd string
    mov x0, x20
    bl tc_strlen
    mov x2, x0
    mov x0, x19
    mov x1, x20
    bl copy_n_nul
    ldr x0, [sp]
    bl free
.Ltu_skip:
    add sp, sp, #32
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cfg_value_buf() -> x0 = the alternating unquote buffer.
// ----------------------------------------------------------------------------
    .p2align 2
cfg_value_buf:
    adrp x1, PAGE(tc_cfg_val_tog)
    add x1, x1, LO12(tc_cfg_val_tog)
    ldr x2, [x1]
    eor x2, x2, #1
    str x2, [x1]
    cbz x2, .Lcvb_a
    adrp x0, PAGE(tc_cfg_val_b)
    add x0, x0, LO12(tc_cfg_val_b)
    ret
.Lcvb_a:
    adrp x0, PAGE(tc_cfg_val_a)
    add x0, x0, LO12(tc_cfg_val_a)
    ret

// ----------------------------------------------------------------------------
// toml_table_total(x0=tab) -> x0 = nkval + narr + ntab
// ----------------------------------------------------------------------------
    .p2align 2
toml_table_total:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl toml_table_nkval
    mov x20, x0
    mov x0, x19
    bl toml_table_narr
    add x20, x20, x0
    mov x0, x19
    bl toml_table_ntab
    add x0, x20, x0
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// build_groups() — Python config_exclusions: fills tc_excl_groups /
// tc_excl_always / tc_excl_flat from the root "exclude" key.  tc_fail on the
// four documented shape errors.
// ----------------------------------------------------------------------------
    .p2align 2
build_groups:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    adrp x0, PAGE(tc_cfg_root)
    add x0, x0, LO12(tc_cfg_root)
    ldr x19, [x0]                   // root (may be 0: config not loaded)
    cbz x19, .Lbg_done
    mov x0, x19
    adrp x1, PAGE(s_key_exclude)
    add x1, x1, LO12(s_key_exclude)
    bl toml_raw_in
    mov x20, x0                     // scalar
    mov x0, x19
    adrp x1, PAGE(s_key_exclude)
    add x1, x1, LO12(s_key_exclude)
    bl toml_array_in
    mov x21, x0                     // array
    mov x0, x19
    adrp x1, PAGE(s_key_exclude)
    add x1, x1, LO12(s_key_exclude)
    bl toml_table_in
    mov x22, x0                     // table
    cbnz x20, .Lbg_bad_shape        // scalar `exclude` -> error
    cbz x21, .Lbg_check_tab
    // ---- flat list ------------------------------------------------------
    mov x0, x21
    bl split_toml_array
    adrp x1, PAGE(tc_excl_flat_n)
    add x1, x1, LO12(tc_excl_flat_n)
    str x0, [x1]
    bl copy_split_to_flat
    b .Lbg_done
.Lbg_check_tab:
    cbz x22, .Lbg_done              // no `exclude` key
    // ---- groups table ---------------------------------------------------
    mov x0, x22
    bl toml_table_total
    mov x23, x0
    mov x24, #0
.Lbg_key_loop:
    cmp x24, x23
    b.ge .Lbg_always
    mov x0, x22
    mov x1, x24
    bl toml_key_in
    cbz x0, .Lbg_key_next
    mov x25, x0                     // group name ptr
    adrp x0, PAGE(s_key_always)
    add x0, x0, LO12(s_key_always)
    mov x1, x25
    bl streq
    cbnz x0, .Lbg_key_next          // "always" handled below
    mov x0, x22
    mov x1, x25
    bl toml_array_in
    cbz x0, .Lbg_member_bad
    // record {name_ptr, name_len, arr_ptr}
    mov x26, x0                     // arr
    mov x0, x25
    bl tc_strlen                    // x0 = name len (x26 survives)
    mov x3, x0                      // len
    adrp x1, PAGE(tc_excl_group_n)
    add x1, x1, LO12(tc_excl_group_n)
    ldr x2, [x1]                    // count (loaded AFTER the strlen)
    cmp x2, #EX_GROUP_MAX
    b.ge .Lbg_key_next              // (cap; documented)
    adrp x4, PAGE(tc_excl_groups)
    add x4, x4, LO12(tc_excl_groups)
    mov x5, #24
    mul x5, x2, x5
    add x4, x4, x5
    str x25, [x4]
    str x3, [x4, #8]
    str x26, [x4, #16]
    add x2, x2, #1
    str x2, [x1]
    b .Lbg_key_next
.Lbg_member_bad:
    adrp x26, PAGE(tc_cfg_scratch)
    add x26, x26, LO12(tc_cfg_scratch)
    mov x0, x26
    adrp x1, PAGE(s_excl_member_pre)
    add x1, x1, LO12(s_excl_member_pre)
    bl cat_cstr
    mov x26, x0
    mov x0, x26
    mov x1, x25
    bl cat_cstr
    mov x26, x0
    mov x0, x26
    adrp x1, PAGE(s_excl_member_mid)
    add x1, x1, LO12(s_excl_member_mid)
    bl cat_cstr
    mov x26, x0
    adrp x1, PAGE(tc_cfg_where)
    add x1, x1, LO12(tc_cfg_where)
    bl cat_cstr
    mov x26, x0
    adrp x1, PAGE(s_excl_member_suf)
    add x1, x1, LO12(s_excl_member_suf)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Lbg_key_next:
    add x24, x24, #1
    b .Lbg_key_loop
.Lbg_always:
    // ---- the "always" list ----------------------------------------------
    mov x0, x22
    adrp x1, PAGE(s_key_always)
    add x1, x1, LO12(s_key_always)
    bl toml_array_in
    cbnz x0, .Lbg_always_arr
    mov x0, x22
    adrp x1, PAGE(s_key_always)
    add x1, x1, LO12(s_key_always)
    bl toml_raw_in
    cbnz x0, .Lbg_always_bad
    mov x0, x22
    adrp x1, PAGE(s_key_always)
    add x1, x1, LO12(s_key_always)
    bl toml_table_in
    cbnz x0, .Lbg_always_bad
    b .Lbg_done
.Lbg_always_arr:
    mov x22, x0                     // the always array
    mov x0, x22
    bl toml_array_nelem
    mov x23, x0
    mov x24, #0
.Lbg_always_loop:
    cmp x24, x23
    b.ge .Lbg_done
    mov x0, x22
    mov x1, x24
    bl toml_raw_at
    cbz x0, .Lbg_always_next
    bl toml_value_to_string
    mov x25, x0                     // name
    mov x0, x25
    mov x0, x25
    bl group_index_of
    cmn x0, #1
    b.eq .Lbg_always_unknown
    // record a STABLE copy of the name {ptr, len}
    mov x0, x25
    bl always_name_store
    mov x25, x0                     // stable ptr
    mov x0, x25
    bl tc_strlen
    mov x26, x0                     // len
    adrp x1, PAGE(tc_excl_always_n)
    add x1, x1, LO12(tc_excl_always_n)
    ldr x2, [x1]
    cmp x2, #EX_GROUP_MAX
    b.ge .Lbg_always_next
    adrp x3, PAGE(tc_excl_always)
    add x3, x3, LO12(tc_excl_always)
    mov x4, #16
    mul x4, x2, x4
    add x3, x3, x4
    str x25, [x3]
    str x26, [x3, #8]
    adrp x1, PAGE(tc_excl_always_n)
    add x1, x1, LO12(tc_excl_always_n)
    add x2, x2, #1
    str x2, [x1]
    b .Lbg_always_next
.Lbg_always_unknown:
    adrp x26, PAGE(tc_cfg_scratch)
    add x26, x26, LO12(tc_cfg_scratch)
    mov x0, x26
    adrp x1, PAGE(s_always_unknown_pre)
    add x1, x1, LO12(s_always_unknown_pre)
    bl cat_cstr
    mov x26, x0
    adrp x1, PAGE(tc_cfg_where)
    add x1, x1, LO12(tc_cfg_where)
    bl cat_cstr
    mov x26, x0
    adrp x1, PAGE(s_always_unknown_mid)
    add x1, x1, LO12(s_always_unknown_mid)
    bl cat_cstr
    mov x26, x0
    mov x1, x25
    bl cat_cstr
    mov x26, x0
    adrp x1, PAGE(s_defined_groups)
    add x1, x1, LO12(s_defined_groups)
    bl cat_cstr
    mov x26, x0
    adrp x1, PAGE(tc_cfg_scratch2)
    add x1, x1, LO12(tc_cfg_scratch2)
    bl sort_groups_join
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Lbg_always_next:
    add x24, x24, #1
    b .Lbg_always_loop
.Lbg_always_bad:
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    adrp x1, PAGE(s_always_bad)
    add x1, x1, LO12(s_always_bad)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_where)
    add x1, x1, LO12(tc_cfg_where)
    bl cat_cstr
    adrp x1, PAGE(s_always_bad_suf)
    add x1, x1, LO12(s_always_bad_suf)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Lbg_bad_shape:
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    adrp x1, PAGE(s_exclude_shape)
    add x1, x1, LO12(s_exclude_shape)
    bl cat_cstr
    adrp x1, PAGE(tc_cfg_where)
    add x1, x1, LO12(tc_cfg_where)
    bl cat_cstr
    adrp x1, PAGE(s_exclude_shape_suf)
    add x1, x1, LO12(s_exclude_shape_suf)
    bl cat_cstr
    adrp x0, PAGE(tc_cfg_scratch)
    add x0, x0, LO12(tc_cfg_scratch)
    bl tc_fail
.Lbg_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// always_name_store(x0=name) -> x0 = stable pointer to a copy in tc_excl_tmp
// ----------------------------------------------------------------------------
    .p2align 2
always_name_store:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // name
    bl tc_strlen
    mov x20, x0                     // len
    adrp x0, PAGE(tc_excl_tmp_cur)
    add x0, x0, LO12(tc_excl_tmp_cur)
    ldr x21, [x0]                   // cursor
    adrp x0, PAGE(tc_excl_tmp)
    add x0, x0, LO12(tc_excl_tmp)
    add x21, x0, x21                // dst
    mov x0, x21
    mov x1, x19
    mov x2, x20
    bl copy_n_nul
    // advance cursor: += len + 1
    add x20, x20, #1
    adrp x0, PAGE(tc_excl_tmp_cur)
    add x0, x0, LO12(tc_excl_tmp_cur)
    ldr x1, [x0]
    add x1, x1, x20
    str x1, [x0]
    mov x0, x21
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// copy_split_to_flat() — copy the current tc_split_tab/buf names into
// tc_excl_flat (NUL-separated), recording tc_excl_flat_n.
// ----------------------------------------------------------------------------
    .p2align 2
copy_split_to_flat:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x0, PAGE(tc_split_n)
    add x0, x0, LO12(tc_split_n)
    ldr x19, [x0]
    adrp x0, PAGE(tc_excl_flat_n)
    add x0, x0, LO12(tc_excl_flat_n)
    str x19, [x0]
    adrp x0, PAGE(tc_excl_flat)
    add x0, x0, LO12(tc_excl_flat)
    mov x20, x0
    mov x21, #0
.Lcsf_loop:
    cmp x21, x19
    b.ge .Lcsf_done
    adrp x0, PAGE(tc_split_tab)
    add x0, x0, LO12(tc_split_tab)
    mov x1, #16
    mul x1, x21, x1
    add x0, x0, x1
    ldr x1, [x0]                    // ptr
    ldr x2, [x0, #8]                // len
    mov x0, x20
    bl copy_n_nul
    mov x20, x0
    add x20, x20, #1                // skip the NUL
    add x21, x21, #1
    b .Lcsf_loop
.Lcsf_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// has_token_char(x0=src) -> x0 = 1 if the string contains a non-separator.
// ----------------------------------------------------------------------------
    .p2align 2
has_token_char:
    stp x29, x30, [sp, #-16]!
    mov x1, x0
.Lhtc_loop:
    ldrb w0, [x1], #1
    cbz w0, .Lhtc_no
    bl is_split_sep
    cbz x0, .Lhtc_yes
    b .Lhtc_loop
.Lhtc_yes:
    mov x0, #1
    b .Lhtc_done
.Lhtc_no:
    mov x0, #0
.Lhtc_done:
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// split_names(x0=src) -> x0 = count.  Splits on [,\s]+, strips, lowercases,
// skips empties; fills tc_split_tab ({ptr,len}) and tc_split_buf (NUL-
// separated copies).
// ----------------------------------------------------------------------------
    .p2align 2
split_names:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // src
    adrp x0, PAGE(tc_split_buf)
    add x0, x0, LO12(tc_split_buf)
    mov x20, x0                     // dst
    mov x21, #0                     // count
.Lsn_skip:
    ldrb w0, [x19]
    cbz w0, .Lsn_done
    bl is_split_sep
    cbnz x0, .Lsn_skip_adv
    // start of a token
    adrp x0, PAGE(tc_split_tab)
    add x0, x0, LO12(tc_split_tab)
    mov x1, #16
    mul x1, x21, x1
    add x0, x0, x1
    str x20, [x0]                   // token ptr
    mov x22, #0                     // token len
.Lsn_tok:
    ldrb w2, [x19]
    cbz w2, .Lsn_tok_end
    mov w0, w2
    bl is_split_sep
    cbnz x0, .Lsn_tok_end
    cmp w2, #'A'
    b.lt .Lsn_tok_store
    cmp w2, #'Z'
    b.gt .Lsn_tok_store
    add w2, w2, #0x20
.Lsn_tok_store:
    strb w2, [x20], #1
    add x22, x22, #1
    add x19, x19, #1
    b .Lsn_tok
.Lsn_tok_end:
    mov w0, #0
    strb w0, [x20], #1
    adrp x0, PAGE(tc_split_tab)
    add x0, x0, LO12(tc_split_tab)
    mov x1, #16
    mul x1, x21, x1
    add x0, x0, x1
    str x22, [x0, #8]               // token len
    add x21, x21, #1
    cmp x21, #SPLIT_MAX
    b.ge .Lsn_done
    b .Lsn_skip
.Lsn_skip_adv:
    add x19, x19, #1
    b .Lsn_skip
.Lsn_done:
    adrp x0, PAGE(tc_split_n)
    add x0, x0, LO12(tc_split_n)
    str x21, [x0]
    mov x0, x21
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// split_toml_array(x0=arr) -> x0 = count.  Like split_names but for TOML
// array elements (stringified, stripped, lowercased).
// ----------------------------------------------------------------------------
    .p2align 2
split_toml_array:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // arr
    bl toml_array_nelem
    mov x20, x0                     // n
    mov x21, #0                     // out count
    mov x23, #0                     // source index
    adrp x0, PAGE(tc_split_buf)
    add x0, x0, LO12(tc_split_buf)
    mov x22, x0                     // dst cursor
.Lsta_loop:
    cmp x23, x20
    b.ge .Lsta_done
    mov x0, x19
    mov x1, x23
    bl toml_raw_at
    cbz x0, .Lsta_next
    bl toml_value_to_string         // x0 = string (scratch or raw)
    mov x24, x0
    bl tc_strlen
    mov x2, x0
    mov x0, x22
    mov x1, x24
    bl strip_copy_lower             // x0 = out len
    cbz x0, .Lsta_next              // empty after strip -> skip
    adrp x2, PAGE(tc_split_tab)
    add x2, x2, LO12(tc_split_tab)
    mov x3, #16
    mul x3, x21, x3
    add x2, x2, x3
    str x22, [x2]
    str x0, [x2, #8]
    add x22, x22, x0
    mov w0, #0
    strb w0, [x22], #1
    add x21, x21, #1
    cmp x21, #SPLIT_MAX
    b.ge .Lsta_done
.Lsta_next:
    add x23, x23, #1
    b .Lsta_loop
.Lsta_done:
    adrp x0, PAGE(tc_split_n)
    add x0, x0, LO12(tc_split_n)
    str x21, [x0]
    mov x0, x21
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// strip_copy_lower(x0=dst, x1=src, x2=len) -> x0 = out length
//   Copies src[0..len) into dst, stripped of leading/trailing ASCII
//   whitespace and lowercased (Python str(item).strip().lower()).
// ----------------------------------------------------------------------------
    .p2align 2
strip_copy_lower:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x19, x0                     // dst
    mov x20, x1                     // src
    mov x21, x2                     // len
    // leading whitespace
    mov x22, #0
.Lscl_lead:
    cmp x22, x21
    b.ge .Lscl_empty
    ldrb w0, [x20, x22]
    bl is_ws
    cbz x0, .Lscl_lead_done
    add x22, x22, #1
    b .Lscl_lead
.Lscl_lead_done:
    // trailing whitespace: end = len, back over ws
    mov x2, x21
.Lscl_trail:
    cbz x2, .Lscl_empty
    sub x2, x2, #1
    ldrb w0, [x20, x2]
    bl is_ws
    cbnz x0, .Lscl_trail
    add x2, x2, #1
    // out length = end - lead
    sub x21, x2, x22
    add x20, x20, x22               // src start
    mov x22, #0
.Lscl_copy:
    cmp x22, x21
    b.ge .Lscl_nul
    ldrb w0, [x20, x22]
    cmp w0, #'A'
    b.lt .Lscl_store
    cmp w0, #'Z'
    b.gt .Lscl_store
    add w0, w0, #0x20
.Lscl_store:
    strb w0, [x19, x22]
    add x22, x22, #1
    b .Lscl_copy
.Lscl_nul:
    mov w0, #0
    strb w0, [x19, x22]
    mov x0, x21
    b .Lscl_done
.Lscl_empty:
    mov w0, #0
    strb w0, [x19]
    mov x0, #0
.Lscl_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// is_split_sep(x0=byte) -> x0 = 1 for comma or ASCII whitespace
// ----------------------------------------------------------------------------
    .p2align 2
is_split_sep:
    cmp w0, #','
    b.eq .Liss_yes
    b is_ws
.Liss_yes:
    mov x0, #1
    ret

// ----------------------------------------------------------------------------
// is_ws(x0=byte) -> x0 = 1 for space/tab/CR/LF/FF/VT
// ----------------------------------------------------------------------------
    .p2align 2
is_ws:
    cmp w0, #0x20
    b.eq .Liw_yes
    cmp w0, #0x09
    b.eq .Liw_yes
    cmp w0, #0x0a
    b.eq .Liw_yes
    cmp w0, #0x0d
    b.eq .Liw_yes
    cmp w0, #0x0b
    b.eq .Liw_yes
    cmp w0, #0x0c
    b.eq .Liw_yes
    mov x0, #0
    ret
.Liw_yes:
    mov x0, #1
    ret

// ----------------------------------------------------------------------------
// group_index_of(x0=name) -> x0 = group index or -1
// ----------------------------------------------------------------------------
    .p2align 2
group_index_of:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                     // name
    adrp x0, PAGE(tc_excl_group_n)
    add x0, x0, LO12(tc_excl_group_n)
    ldr x20, [x0]
    mov x0, #0
.Lgio_loop:
    cmp x0, x20
    b.ge .Lgio_no
    adrp x2, PAGE(tc_excl_groups)
    add x2, x2, LO12(tc_excl_groups)
    mov x3, #24
    mul x3, x0, x3
    add x2, x2, x3
    ldr x1, [x2]                    // group name
    mov x4, x0
    mov x0, x1
    mov x1, x19
    bl streq
    cbnz x0, .Lgio_yes
    mov x0, x4
    add x0, x0, #1
    b .Lgio_loop
.Lgio_yes:
    mov x0, x4
    b .Lgio_done
.Lgio_no:
    mov x0, #-1
.Lgio_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// group_arr_at(x0=group_index) -> x0 = toml_array_t* for the group
// ----------------------------------------------------------------------------
    .p2align 2
group_arr_at:
    adrp x1, PAGE(tc_excl_groups)
    add x1, x1, LO12(tc_excl_groups)
    mov x2, #24
    mul x0, x0, x2
    add x0, x1, x0
    ldr x0, [x0, #16]
    ret

// ----------------------------------------------------------------------------
// always_group_arr(x0=always_index) -> x0 = the group array named by the
// always record (by lookup).
// ----------------------------------------------------------------------------
    .p2align 2
always_group_arr:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    adrp x1, PAGE(tc_excl_always)
    add x1, x1, LO12(tc_excl_always)
    mov x2, #16
    mul x0, x0, x2
    add x0, x1, x0
    ldr x19, [x0]                   // name ptr
    mov x0, x19
    bl group_index_of
    cmn x0, #1
    b.eq .Laga_no
    bl group_arr_at
    b .Laga_done
.Laga_no:
    mov x0, #0
.Laga_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// sort_groups_join(x0=dst) — Python ", ".join(sorted(groups)) or
// "(none defined)".  Uses tc_cfg_scratch2 for the pointer array.
// ----------------------------------------------------------------------------
    .p2align 2
sort_groups_join:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // dst
    adrp x0, PAGE(tc_excl_group_n)
    add x0, x0, LO12(tc_excl_group_n)
    ldr x20, [x0]                   // n
    cbz x20, .Lsgj_none
    adrp x0, PAGE(tc_cfg_scratch2)
    add x0, x0, LO12(tc_cfg_scratch2)
    mov x21, x0                     // ptr array base
    mov x22, #0
.Lsgj_fill:
    cmp x22, x20
    b.ge .Lsgj_sort
    adrp x0, PAGE(tc_excl_groups)
    add x0, x0, LO12(tc_excl_groups)
    mov x1, #24
    mul x1, x22, x1
    add x0, x0, x1
    ldr x0, [x0]
    str x0, [x21, x22, lsl #3]
    add x22, x22, #1
    b .Lsgj_fill
.Lsgj_sort:
    mov x22, #1
.Lsgj_outer:
    cmp x22, x20
    b.ge .Lsgj_join
    ldr x23, [x21, x22, lsl #3]     // key
    mov x24, x22
.Lsgj_inner:
    cbz x24, .Lsgj_place
    sub x0, x24, #1
    ldr x1, [x21, x0, lsl #3]
    mov x0, x1
    mov x1, x23
    bl strcmp
    cmp w0, #0
    b.le .Lsgj_place
    sub x0, x24, #1
    ldr x1, [x21, x0, lsl #3]
    str x1, [x21, x24, lsl #3]
    sub x24, x24, #1
    b .Lsgj_inner
.Lsgj_place:
    str x23, [x21, x24, lsl #3]
    add x22, x22, #1
    b .Lsgj_outer
.Lsgj_join:
    mov x0, x19
    mov x22, #0
.Lsgj_join_loop:
    cmp x22, x20
    b.ge .Lsgj_done
    cbz x22, .Lsgj_join_name
    adrp x1, PAGE(s_comma_space)
    add x1, x1, LO12(s_comma_space)
    bl cat_cstr
.Lsgj_join_name:
    ldr x1, [x21, x22, lsl #3]
    bl cat_cstr
    add x22, x22, #1
    b .Lsgj_join_loop
.Lsgj_none:
    mov x0, x19
    adrp x1, PAGE(s_none_defined)
    add x1, x1, LO12(s_none_defined)
    bl cat_cstr
.Lsgj_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// excl_src_buf_slot(x0=slot) -> x0 = ptr into tc_excl_src_buf (64 bytes each)
// ----------------------------------------------------------------------------
    .p2align 2
excl_src_buf_slot:
    adrp x1, PAGE(tc_excl_src_buf)
    add x1, x1, LO12(tc_excl_src_buf)
    mov x2, #64
    mul x0, x0, x2
    add x0, x1, x0
    ret

// ----------------------------------------------------------------------------
// source_add_cstr(x0=label) -> x0 = source index (dedup by string)
// ----------------------------------------------------------------------------
    .p2align 2
source_add_cstr:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0
    bl tc_strlen
    mov x1, x0
    mov x0, x19
    bl source_add
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// source_add(x0=label_ptr, x1=label_len) -> x0 = source index.  Dedups by
// exact string; appends a {ptr,len} record to tc_excl_sources.
// ----------------------------------------------------------------------------
    .p2align 2
source_add:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // ptr
    mov x20, x1                     // len
    adrp x21, PAGE(tc_excl_src_count)
    add x21, x21, LO12(tc_excl_src_count)
    ldr x22, [x21]                  // count
    mov x23, #0
.Lsa_loop:
    cmp x23, x22
    b.ge .Lsa_append
    adrp x0, PAGE(tc_excl_sources)
    add x0, x0, LO12(tc_excl_sources)
    mov x1, #16
    mul x1, x23, x1
    add x0, x0, x1
    ldr x2, [x0, #8]                // len
    cmp x2, x20
    b.ne .Lsa_next
    ldr x1, [x0]                    // ptr
    mov x24, x1
    mov x0, x1
    mov x1, x19
    mov x2, x20
    bl memeq
    cbnz x0, .Lsa_found
.Lsa_next:
    add x23, x23, #1
    b .Lsa_loop
.Lsa_append:
    adrp x0, PAGE(tc_excl_sources)
    add x0, x0, LO12(tc_excl_sources)
    mov x1, #16
    mul x1, x22, x1
    add x0, x0, x1
    str x19, [x0]
    str x20, [x0, #8]
    add x22, x22, #1
    str x22, [x21]
    mov x0, x22
    sub x0, x0, #1
    b .Lsa_done
.Lsa_found:
    mov x0, x23
.Lsa_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// apply_flat_tokens() — apply the flat exclusion list (tc_excl_flat) with the
// source index in x20.
// ----------------------------------------------------------------------------
    .p2align 2
apply_flat_tokens:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    adrp x0, PAGE(tc_excl_flat_n)
    add x0, x0, LO12(tc_excl_flat_n)
    ldr x21, [x0]                   // count
    adrp x0, PAGE(tc_excl_flat)
    add x0, x0, LO12(tc_excl_flat)
    mov x19, x0                     // cursor
    mov x23, #0                     // counter
.Laft_loop:
    cmp x23, x21
    b.ge .Laft_done
    mov x0, x19
    bl tc_strlen
    mov x22, x0                     // len (x19/x20 are callee-saved)
    mov x0, x19
    mov x1, x22
    mov x2, x20                     // src idx
    bl add_excl_login
    add x19, x19, x22
    add x19, x19, #1                // skip NUL
    add x23, x23, #1
    b .Laft_loop
.Laft_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// apply_split_tokens() — apply the current tc_split_tab tokens with the
// source index in x20.
// ----------------------------------------------------------------------------
    .p2align 2
apply_split_tokens:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    adrp x0, PAGE(tc_split_n)
    add x0, x0, LO12(tc_split_n)
    ldr x1, [x0]
    mov x0, x20
    bl apply_split_tokens_n
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// apply_split_tokens_n(x0=src_idx, x1=count) — apply tc_split_tab[0..count)
// with the given source index.
// ----------------------------------------------------------------------------
    .p2align 2
apply_split_tokens_n:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    mov x20, x0                     // src idx
    mov x21, x1                     // count
    mov x22, #0
.Last_loop:
    cmp x22, x21
    b.ge .Last_done
    adrp x0, PAGE(tc_split_tab)
    add x0, x0, LO12(tc_split_tab)
    mov x1, #16
    mul x1, x22, x1
    add x0, x0, x1
    ldr x19, [x0]                   // ptr
    ldr x1, [x0, #8]                // len
    mov x0, x19
    mov x2, x20
    bl add_excl_login
    add x22, x22, #1
    b .Last_loop
.Last_done:
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// add_excl_login(x0=login, x1=len, x2=source_idx) — append to tc_excl_set
// (dedup, case-insensitive).  Fails loudly when the set is full.
// ----------------------------------------------------------------------------
    .p2align 2
add_excl_login:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    mov x19, x0                     // login
    mov x20, x1                     // len
    mov x21, x2                     // source idx
    adrp x22, PAGE(tc_excl_set)
    add x22, x22, LO12(tc_excl_set)
    ldr x23, [x22]                  // count
    cmp x23, #TC_EX_MAX
    b.ge .Lael_full
    mov x24, #0
.Lael_dedup:
    cmp x24, x23
    b.ge .Lael_append
    mov x0, x24
    bl excl_entry_off
    add x0, x22, x0
    add x0, x0, #8
    mov x1, x19
    mov x2, x20
    bl login_matches
    cbnz x0, .Lael_done
    add x24, x24, #1
    b .Lael_dedup
.Lael_append:
    mov x0, x24
    bl excl_entry_off
    add x0, x22, x0
    add x0, x0, #8                  // entry login field
    mov x1, x19
    mov x2, x20
    bl copy_login_entry
    // store the source index
    mov x0, x24
    bl excl_entry_off
    add x0, x22, x0
    add x0, x0, #8
    add x0, x0, #TC_EX_LOGIN_SZ
    str x21, [x0]
    add x23, x23, #1
    str x23, [x22]
    b .Lael_done
.Lael_full:
    adrp x0, PAGE(s_too_many)
    add x0, x0, LO12(s_too_many)
    bl tc_fail
.Lael_done:
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// excl_entry_off(x0=index) -> x0 = byte offset of the entry (TC_EX_ENTRY_SZ
// stride from the entries base).
// ----------------------------------------------------------------------------
    .p2align 2
excl_entry_off:
    mov x1, #TC_EX_ENTRY_SZ
    mul x0, x0, x1
    ret

// ----------------------------------------------------------------------------
// copy_login_entry(x0=dst, x1=src, x2=len) — copy up to 25 bytes + NUL.
// ----------------------------------------------------------------------------
    .p2align 2
copy_login_entry:
    mov x3, #0
.Lcle_loop:
    cmp x3, #25
    b.ge .Lcle_nul
    cmp x3, x2
    b.ge .Lcle_nul
    ldrb w4, [x1, x3]
    strb w4, [x0, x3]
    add x3, x3, #1
    b .Lcle_loop
.Lcle_nul:
    mov w4, #0
    strb w4, [x0, x3]
    ret

// ----------------------------------------------------------------------------
// login_matches(x0=entry_login, x1=login, x2=len) -> x0 = 0/1
//   Case-insensitive compare of a stored NUL-terminated login against a
//   length-delimited login.
// ----------------------------------------------------------------------------
    .p2align 2
login_matches:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    mov x19, x0                     // stored base
    mov x20, x1                     // candidate base
    mov x3, #0
.Llm_loop:
    ldrb w4, [x19, x3]
    cbz w4, .Llm_stored_end
    cmp x3, x2
    b.ge .Llm_no                    // stored longer than candidate
    ldrb w5, [x20, x3]
    cmp w4, #'A'
    b.lt 1f
    cmp w4, #'Z'
    b.gt 1f
    add w4, w4, #0x20
1:
    cmp w5, #'A'
    b.lt 2f
    cmp w5, #'Z'
    b.gt 2f
    add w5, w5, #0x20
2:
    cmp w4, w5
    b.ne .Llm_no
    add x3, x3, #1
    b .Llm_loop
.Llm_stored_end:
    cmp x3, x2
    b.ne .Llm_no                    // stored shorter than candidate
    mov x0, #1
    b .Llm_done
.Llm_no:
    mov x0, #0
.Llm_done:
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// excl_remove_if_present(x0=login, x1=len) -> x0 = 0/1 removed.
//   Finds the login case-insensitively and shifts the array down.
// ----------------------------------------------------------------------------
    .p2align 2
excl_remove_if_present:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    stp x21, x22, [sp, #-16]!
    stp x23, x24, [sp, #-16]!
    stp x25, x26, [sp, #-16]!
    mov x19, x0                     // login
    mov x20, x1                     // len
    adrp x21, PAGE(tc_excl_set)
    add x21, x21, LO12(tc_excl_set)
    ldr x22, [x21]                  // count
    mov x23, #0
.Ler_loop:
    cmp x23, x22
    b.ge .Ler_no
    mov x0, x23
    bl excl_entry_off
    add x0, x21, x0
    add x0, x0, #8
    mov x1, x19
    mov x2, x20
    bl login_matches
    cbnz x0, .Ler_found
    add x23, x23, #1
    b .Ler_loop
.Ler_found:
    mov x24, x23
.Ler_shift:
    add x0, x24, #1
    cmp x0, x22
    b.ge .Ler_dec
    // dst = base + 8 + idx*34
    mov x0, x24
    bl excl_entry_off
    add x0, x21, x0
    add x0, x0, #8
    mov x25, x0                     // dst (callee-saved)
    // src = base + 8 + (idx+1)*34
    mov x0, x24
    add x0, x0, #1
    bl excl_entry_off
    add x0, x21, x0
    add x0, x0, #8
    mov x1, x0                      // src
    mov x0, x25
    mov x2, #TC_EX_ENTRY_SZ
    bl memmove_local
    add x24, x24, #1
    b .Ler_shift
.Ler_dec:
    sub x22, x22, #1
    str x22, [x21]
    mov x0, #1
    b .Ler_done
.Ler_no:
    mov x0, #0
.Ler_done:
    ldp x25, x26, [sp], #16
    ldp x23, x24, [sp], #16
    ldp x21, x22, [sp], #16
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// memmove_local(x0=dst, x1=src, x2=n) — byte move (forward; our shifts move up)
// ----------------------------------------------------------------------------
    .p2align 2
memmove_local:
    cbz x2, .Lmm_done
    ldrb w3, [x1], #1
    strb w3, [x0], #1
    sub x2, x2, #1
    b memmove_local
.Lmm_done:
    ret

// ----------------------------------------------------------------------------
// memeq(x0=a, x1=b, x2=n) -> x0 = 0/1 (exact compare)
// ----------------------------------------------------------------------------
    .p2align 2
memeq:
    cbz x2, .Lmeq_yes
    ldrb w3, [x0], #1
    ldrb w4, [x1], #1
    cmp w3, w4
    b.ne .Lmeq_no
    sub x2, x2, #1
    b memeq
.Lmeq_yes:
    mov x0, #1
    ret
.Lmeq_no:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// cat_comma_if(x0=dst, x1=wrote_any) -> x0 = end.  Writes ", " when set.
// ----------------------------------------------------------------------------
    .p2align 2
cat_comma_if:
    stp x29, x30, [sp, #-16]!
    cbz x1, .Lcci_done
    adrp x1, PAGE(s_comma_space)
    add x1, x1, LO12(s_comma_space)
    bl cat_cstr
.Lcci_done:
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cat_cstr(x0=dst, x1=src) -> x0 = end (points at the NUL)
// ----------------------------------------------------------------------------
    .p2align 2
cat_cstr:
    ldrb w2, [x1], #1
    strb w2, [x0], #1
    cbnz w2, cat_cstr
    sub x0, x0, #1
    ret

// ----------------------------------------------------------------------------
// cat_n(x0=dst, x1=src, x2=n) -> x0 = end (NUL-terminated)
// ----------------------------------------------------------------------------
    .p2align 2
cat_n:
    stp x29, x30, [sp, #-16]!
    mov x3, x0
.Lcatn_loop:
    cbz x2, .Lcatn_done
    ldrb w4, [x1], #1
    strb w4, [x3], #1
    sub x2, x2, #1
    b .Lcatn_loop
.Lcatn_done:
    mov w4, #0
    strb w4, [x3]
    mov x0, x3
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// cat_u64(x0=dst, x1=val) -> x0 = end
// ----------------------------------------------------------------------------
    .p2align 2
cat_u64:
    stp x29, x30, [sp, #-16]!
    stp x19, x20, [sp, #-16]!
    sub sp, sp, #32
    mov x19, x0
    mov x20, x1
    add x1, sp, #28
    mov x2, #0
    cmp x20, #0
    b.ne .Lcu_loop
    mov x3, #'0'
    strb w3, [x1, #-1]!
    mov x2, #1
    b .Lcu_done
.Lcu_loop:
    mov x4, #10
    udiv x5, x20, x4
    msub x6, x5, x4, x20
    add x6, x6, #'0'
    strb w6, [x1, #-1]!
    add x2, x2, #1
    mov x20, x5
    cbnz x20, .Lcu_loop
.Lcu_done:
    mov x0, x19
.Lcu_copy:
    ldrb w3, [x1], #1
    strb w3, [x0], #1
    cbnz w3, .Lcu_copy
    sub x0, x0, #1
    add sp, sp, #32
    ldp x19, x20, [sp], #16
    ldp x29, x30, [sp], #16
    ret

// ----------------------------------------------------------------------------
// copy_n_nul(x0=dst, x1=src, x2=n) — copy n bytes + NUL
// ----------------------------------------------------------------------------
    .p2align 2
copy_n_nul:
    cbz x2, .Lcnn_z
    ldrb w3, [x1], #1
    strb w3, [x0], #1
    sub x2, x2, #1
    b copy_n_nul
.Lcnn_z:
    mov w3, #0
    strb w3, [x0]
    ret

// ----------------------------------------------------------------------------
// streq(x0=a, x1=b) -> x0 = 0/1
// ----------------------------------------------------------------------------
    .p2align 2
streq:
    ldrb w2, [x0], #1
    ldrb w3, [x1], #1
    cmp w2, w3
    b.ne .Lse_no
    cbnz w2, streq
    mov x0, #1
    ret
.Lse_no:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// starts_with(x0=s, x1=prefix) -> x0 = 0/1
// ----------------------------------------------------------------------------
    .p2align 2
starts_with:
    ldrb w2, [x1], #1
    cbz w2, .Lsw_yes
    ldrb w3, [x0], #1
    cmp w2, w3
    b.ne .Lsw_no
    b starts_with
.Lsw_yes:
    mov x0, #1
    ret
.Lsw_no:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// lowercase_copy(x0=dst, x1=src) -> x0 = end (NUL-terminated, A-Z lowercased)
// ----------------------------------------------------------------------------
    .p2align 2
lowercase_copy:
    ldrb w2, [x1], #1
    cbz w2, .Llc_done
    cmp w2, #'A'
    b.lt .Llc_store
    cmp w2, #'Z'
    b.gt .Llc_store
    add w2, w2, #0x20
.Llc_store:
    strb w2, [x0], #1
    b lowercase_copy
.Llc_done:
    mov w2, #0
    strb w2, [x0]
    ret


// ----------------------------------------------------------------------------
// ----------------------------------------------------------------------------
    .p2align 2
    stp x29, x30, [sp, #-16]!
    sub sp, sp, #32
    mov x2, x0
    add x3, sp, #28
    mov x4, #0
    cmp x1, #0
    b.ne 1f
    mov x5, #'0'
    strb w5, [x3, #-1]!
    mov x4, #1
    b 2f
1:
    mov x5, #10
    udiv x6, x1, x5
    msub x7, x6, x5, x1
    add x7, x7, #'0'
    strb w7, [x3, #-1]!
    add x4, x4, #1
    mov x1, x6
    cbnz x1, 1b
2:
    ldrb w5, [x3], #1
    strb w5, [x2], #1
    cbnz w5, 2b
    sub x0, x2, #1
    add sp, sp, #32
    ldp x29, x30, [sp], #16
    ret

// ============================================================================
// .rodata
// ============================================================================
    RODATA
    .p2align 3

s_home:             .asciz "HOME"
s_env_config:       .asciz "TWITCH_COUNTS_CONFIG"
s_env_xdg:          .asciz "XDG_CONFIG_HOME"
s_env_exclude:      .asciz "TWITCH_EXCLUDE"
s_xdg_tail:         .asciz "/twitch-counts.toml"
s_home_config_tail: .asciz "/.config/twitch-counts.toml"
s_default_config_path: .asciz "~/.config/twitch-counts.toml"

s_key_watch:        .asciz "watch"
s_key_tail:         .asciz "tail"
s_key_aliases:      .asciz "aliases"
s_key_exclude:      .asciz "exclude"
s_key_always:       .asciz "always"

s_could_not_read:   .asciz "could not read config "
s_config_not_found: .asciz "config file not found: "
s_errno_lb:         .asciz "[Errno "
s_errno_rb:         .asciz "] "
s_colon_space:      .asciz ": "
s_squote:           .asciz "'"
s_oom:              .asciz "out of memory reading config"

s_no_channel_pre:   .asciz "no channel given -- pass --channel, set TWITCH_CHANNEL, or add channel = \"...\" to "
s_alias_arrow:      .asciz " -> alias '"
s_aliases_bad_pre:  .asciz "[aliases] in "
s_aliases_bad_suf:  .asciz " must be a table of name = channel"
s_sect_mid:         .asciz "] in "
s_sect_suf:         .asciz " must be a table"

s_false:            .asciz "false"
s_zero:             .asciz "0"
s_zero_float:       .asciz "0.0"

s_noexcl_prefix:    .asciz "--no-exclude cannot be combined with "
s_unknown_group_pre:.asciz "unknown exclude group '"
s_defined_groups:   .asciz "'; defined groups: "
s_none_defined:     .asciz "(none defined)"
s_comma_space:      .asciz ", "
s_minus_include:    .asciz "minus --include ("
s_rparen:           .asciz ")"

s_exclude_shape:    .asciz "`exclude` in "
s_exclude_shape_suf:.asciz " must be a list of logins or a table of groups"
s_excl_member_pre:  .asciz "[exclude]."
s_excl_member_mid:  .asciz " in "
s_excl_member_suf:  .asciz " must be a list of logins"
s_always_bad:       .asciz "[exclude].always in "
s_always_bad_suf:   .asciz " must be a list of group names"
s_always_unknown_pre: .asciz "[exclude].always in "
s_always_unknown_mid: .asciz " names unknown group '"
s_too_many:         .asciz "too many excluded logins (max 512)"

s_src_excl_config_label: .asciz "config exclude"
s_src_excl_always:  .asciz "config always:"
s_src_excl_group:   .asciz "--exclude-group "
s_src_excl_env_label: .asciz "env TWITCH_EXCLUDE"

// The canonical flag strings (local to this module: tc_cli.S keeps its own
// private copies).
s_flag_exclude:     .asciz "--exclude"
s_flag_exclude_group: .asciz "--exclude-group"
s_flag_exclude_bcast: .asciz "--exclude-broadcaster"
s_flag_include:     .asciz "--include"
















    .end









