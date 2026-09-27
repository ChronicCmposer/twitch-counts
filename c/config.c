// ============================================================================
// config.c — env/config access, alias application and exclusion building.
//
//  The C sibling of asm/tc_config.S: implements the config/env hooks of the
//  shared contract (tc_platform.h), the tomlc99-backed loader with the Python
//  (path, size, mtime_ns) session memo, alias rewriting, and the merged
//  exclusion set.  Behavioural oracle: twitch-counts.py — load_config_layer /
//  config_identity / load_config / resolve / build_inputs (aliases) /
//  build_exclusions / config_exclusions / exclusion_layers / split_names /
//  shorten_path, byte-for-byte wherever the Python's output is observable.
//
//  Session state
//  -------------
//  The C port passes state explicitly (main() owns tc_opts), but the contract
//  hooks tc_config_get/tc_env_get/tc_config_identity/tc_config_changed/
//  tc_config_reload have no options parameter, so this module keeps one static
//  session (s_cfg: the parsed table, the resolved path, the load snapshot) and
//  a static pointer to the current tc_opts (s_opts).  tc_cli_parse registers
//  the opts up front (tc_config_register_opts, exported outside the header
//  like tc_excl_src_count) so its parse-time setting resolution honors a
//  --config path / --no-config flag; the two hooks that DO receive options —
//  tc_aliases_apply and tc_build_exclusions — register the same opts again at
//  entry (idempotent).  Before any of them runs, the no-options hooks behave
//  as "no config" (env lookups still work, config lookups report absent).
//  This mirrors the asm port, where the same state lives in .bss globals read
//  by every hook.
//
//  Load semantics (Python load_config_layer/load_config)
//  -----------------------------------------------------
//    --config flag  >  env TWITCH_COUNTS_CONFIG  >  platform default
//    ($XDG_CONFIG_HOME/twitch-counts.toml or $HOME/.config/twitch-counts.toml
//    on Linux; $HOME/.config/twitch-counts.toml on macOS — tc_default_config_path
//    in util.c supplies it).  A missing DEFAULT path is "not loaded" (never an
//    error); a missing EXPLICIT path raises "config file not found: <path>".
//    TOML errors raise "could not read config <path>: <detail>" (tomlc99's
//    text; the Python prefix is byte-identical).  [aliases]/[watch]/[tail] are
//    checked at load time, in the Python's relative order, with the Python's
//    `aliases = config.get("aliases") or {}` falsy handling (empty string,
//    "0", "0.0", "false" and an empty array count as absent).
//
//  Identity memo (Python config_identity)
//  --------------------------------------
//  tc_config_identity writes "(none)" under --no-config or when no path is
//  chosen; else "<path>" for a chosen-but-not-a-regular-file path (Python's
//  (path, None, None)); else "<path>:<size>:<mtime_ns>" for a real file.
//  tc_config_changed() compares a fresh stat of the loaded path against the
//  load-time snapshot (a config that was never loaded stays "unchanged");
//  tc_config_reload() drops the parsed table and re-runs the loader.
//
//  Exclusions (Python build_exclusions)
//  ------------------------------------
//  Layers ADD (first source wins per login), never override.  Layer order:
//  config flat, config always:<name> (in the always-list order), --exclude-group
//  <name> (CLI order), env TWITCH_EXCLUDE, --exclude (CLI order, one flattened
//  layer), --exclude-broadcaster, then "minus --include (N)" when --include
//  removed anything.  The source list is deduped by exact label; the merged set
//  caps at TC_EX_MAX (512) entries and the split arenas at EXCL_ARENA_SZ
//  (16384) bytes — either cap fails loudly with the documented messages.
//
//  Residual diffs vs the Python (shared with the asm port)
//  -------------------------------------------------------
//    * TOML syntax-error text comes from tomlc99, not tomllib.
//    * Logins longer than 25 characters are truncated to fit the frozen
//      26-byte entry; the Python keeps them whole.
//    * The split token cap (512) and arena cap (16383 bytes) are additions.
//    * os.path.expanduser is approximated: "~" and "~/" use $HOME; "~user"
//      and the passwd fallback for an unset HOME are not resolved.
// ============================================================================

#include "tc_platform.h"
#include "../third_party/tomlc99/toml.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

// ----------------------------------------------------------------------------
// Constants — mirrors the asm module (tc_config.S).
// ----------------------------------------------------------------------------
enum {
    CFG_PATH_SZ   = TC_PATH_SZ,       /* resolved config path buffer */
    CFG_ERRBUF_SZ = 128,              /* toml_parse error buffer */
    CFG_MSG_SZ    = 1024,             /* error-message composition scratch */
    VAL_BUF_SZ    = 512,              /* unquoted-value scratch (x2 buffers) */
    EX_GROUP_MAX  = 64,               /* max [exclude] groups / always names */
    EXCL_ARENA_SZ = 16384,            /* split/flat/tmp arena bytes */
    SPLIT_MAX     = TC_EX_MAX,        /* a single split never exceeds 512 */
    SRC_SLOT_MAX  = EX_GROUP_MAX * 2 + 1, /* dynamic source labels */
    LOGIN_CAP     = TC_LOGIN_SZ - 1   /* 25: the Twitch login limit */
};

enum cfg_state {
    CFG_ST_NONE = 0,                  /* not attempted yet */
    CFG_ST_LOADED,                    /* parsed and validated */
    CFG_ST_NOLOAD                     /* no-config or missing default */
};

// ----------------------------------------------------------------------------
// Static session — the asm port's .bss (see the header comment).  The
// session and the scratch arenas below are heap-owned: .bss is NOBITS RAM
// that is never reclaimed, while the config session lives only as long as
// the process and the exclusion arenas only as long as one build call.
// ----------------------------------------------------------------------------
static tc_opts *s_opts;
static struct {
    toml_table_t *root;               /* parsed TOML table, or NULL */
    char path[TC_PATH_SZ];            /* resolved (post-expanduser) path */
    char where[TC_PATH_SZ];           /* shorten_path(path), for error text */
    int state;                        /* enum cfg_state */
    int explicit;                     /* path from --config / TWITCH_COUNTS_CONFIG */
    int64_t size_snapshot;            /* st_size at load time */
    int64_t mtime_ns_snapshot;        /* st_mtime_ns at load time */
} *s_cfg;

/* The config session is process-lifetime state; allocate it once on first
   use so its ~1 KB (two path buffers + the load snapshot) never sits in
   .bss. */
static void cfg_session_init(void) {
    if (s_cfg == NULL) {
        s_cfg = malloc(sizeof(*s_cfg));
        if (s_cfg == NULL) {
            tc_fail("out of memory");
        }
        memset(s_cfg, 0, sizeof(*s_cfg));
    }
}

static char *s_val_a;                 /* unquoted config values: two buffers */
static char *s_val_b;                 /* so begin+since can both stay valid */
static int s_val_toggle;

// ----------------------------------------------------------------------------
// Exclusion scratch (transient: rebuilt by every tc_build_exclusions call;
// the split/flat/tmp arenas are heap-allocated per call and freed at its
// end — the merged set copies every login out of them, so nothing escapes.
// s_src_slots is the exception: its labels are stored in tc_excl_set.sources
// and read by the renderer, so it is a one-time process-lifetime allocation).
// ----------------------------------------------------------------------------
static char *s_split_buf;
static struct {
    char *ptr;
    size_t len;
} *s_split_tab;
static size_t s_split_n;
static char *s_excl_flat;             /* NUL-separated flat names */
static size_t s_excl_flat_n;
static char *s_excl_tmp;              /* stable copies of always names */
static size_t s_excl_tmp_cur;
static struct {
    const char *name;
    size_t name_len;
    toml_array_t *arr;
} *s_groups;
static size_t s_group_n;
static struct {
    const char *name;
    size_t name_len;
} *s_always;
static size_t s_always_n;
static char (*s_src_slots)[64];       /* dynamic source labels */
static size_t s_src_slot_cur;

/* Allocate the per-call exclusion arenas; fails loudly (the process exits)
   on any OOM rather than letting a NULL arena walk. */
static void cfg_excl_alloc(void) {
    s_split_buf = malloc(EXCL_ARENA_SZ);
    s_excl_flat = malloc(EXCL_ARENA_SZ);
    s_excl_tmp = malloc(EXCL_ARENA_SZ);
    s_split_tab = malloc(SPLIT_MAX * sizeof(*s_split_tab));
    s_groups = malloc(EX_GROUP_MAX * sizeof(*s_groups));
    s_always = malloc(EX_GROUP_MAX * sizeof(*s_always));
    if (s_split_buf == NULL || s_excl_flat == NULL || s_excl_tmp == NULL
        || s_split_tab == NULL || s_groups == NULL || s_always == NULL) {
        tc_fail("out of memory");
    }
}

static void cfg_excl_free(void) {
    free(s_split_buf);
    free(s_excl_flat);
    free(s_excl_tmp);
    free(s_split_tab);
    free(s_groups);
    free(s_always);
    s_split_buf = NULL;
    s_excl_flat = NULL;
    s_excl_tmp = NULL;
    s_split_tab = NULL;
    s_groups = NULL;
    s_always = NULL;
}

/* Number of live records in tc_excl_set.sources[].  Exported (not part of the
   header's public API) because the struct itself carries no count — this is
   the C mirror of the asm port's exported tc_excl_src_count .bss symbol. */
int64_t tc_excl_src_count;

// ----------------------------------------------------------------------------
// mtime access: musl exposes the timespec form as st_mtim; Apple/Darwin
// exposes it as st_mtimespec; glibc (used only for ad-hoc syntax checks)
// hides st_mtim behind feature macros, so fall back to the legacy
// seconds/nanoseconds fields there.
// ----------------------------------------------------------------------------
#if defined(__APPLE__)
#define TC_ST_MTIME_SEC(s)  ((s).st_mtimespec.tv_sec)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtimespec.tv_nsec)
#elif defined(__GLIBC__) && !defined(_DEFAULT_SOURCE) && !defined(_GNU_SOURCE)
#define TC_ST_MTIME_SEC(s)  ((s).st_mtime)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtimensec)
#else
#define TC_ST_MTIME_SEC(s)  ((s).st_mtim.tv_sec)
#define TC_ST_MTIME_NSEC(s) ((s).st_mtim.tv_nsec)
#endif

// Forward declarations (mutual references inside this module).
static size_t cfg_strip_copy_lower(char *dst, const char *src, size_t len);
static int cfg_login_matches(const char *stored, const char *cand, size_t len);

// ============================================================================
// Small local helpers (libc-backed; the util.c string stubs are not trusted
// while that module is still being implemented).
// ============================================================================

static int cfg_is_ws(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\n' || c == '\r'
        || c == '\v' || c == '\f';
}

static int cfg_is_split_sep(unsigned char c) {
    return c == ',' || cfg_is_ws(c);
}

static unsigned char cfg_lower_byte(unsigned char c) {
    return (c >= 'A' && c <= 'Z') ? (unsigned char)(c - 'A' + 'a') : c;
}

/* Bounded concat; returns the cursor.  Leaves room for one NUL at end-1. */
static char *cfg_cat(char *dst, char *end, const char *s) {
    while (*s != '\0' && dst < end - 1) {
        *dst++ = *s++;
    }
    return dst;
}

// ----------------------------------------------------------------------------
// Path helpers — os.path.expanduser / shorten_path, HOME-based.
// ----------------------------------------------------------------------------
static void cfg_expanduser(const char *src, char *dst, size_t cap) {
    if (cap == 0) {
        return;
    }
    dst[0] = '\0';
    if (src[0] != '~') {
        snprintf(dst, cap, "%s", src);
        return;
    }
    /* "~user" is left as-is: resolving it needs passwd, which the harness
       never exercises and this port deliberately keeps out of scope. */
    if (src[1] != '\0' && src[1] != '/') {
        snprintf(dst, cap, "%s", src);
        return;
    }
    const char *home = getenv("HOME");
    if (home == NULL || home[0] == '\0') {
        /* No HOME: keep the literal prefix (Python would fall back to passwd). */
        snprintf(dst, cap, "%s", src);
        return;
    }
    snprintf(dst, cap, "%s%s", home, src + 1);
}

static void cfg_shorten_path(const char *path, char *dst, size_t cap) {
    if (cap < 2) {
        if (cap > 0) {
            dst[0] = '\0';
        }
        return;
    }
    char home[CFG_PATH_SZ];
    cfg_expanduser("~", home, sizeof(home));
    size_t hlen = strlen(home);
    if (hlen > 0 && strncmp(path, home, hlen) == 0) {
        size_t rest = strlen(path + hlen);
        size_t n = rest < cap - 2 ? rest : cap - 2;
        dst[0] = '~';
        if (n > 0) {
            memcpy(dst + 1, path + hlen, n);
        }
        dst[n + 1] = '\0';
        return;
    }
    snprintf(dst, cap, "%s", path);
}

// ----------------------------------------------------------------------------
// Failure helpers — fail loud with the Python's exact texts (exit 1).
// ----------------------------------------------------------------------------
static void cfg_fail_too_many(void) {
    tc_fail("too many excluded logins (max 512)");
}

static void cfg_fail_too_long(void) {
    tc_fail("excluded logins list too long (max 16383 bytes)");
}

// ----------------------------------------------------------------------------
// TOML value -> string.  Non-string raws (ints/floats/bools/dates) are
// returned as-is — their text is already Python str() for the common cases.
// String raws are unquoted into one of two alternating buffers so two
// outstanding config values stay valid (the Python reads begin+since).
// ----------------------------------------------------------------------------
static char *cfg_value_buf(void) {
    if (s_val_a == NULL) {
        s_val_a = malloc(VAL_BUF_SZ);
        s_val_b = malloc(VAL_BUF_SZ);
        if (s_val_a == NULL || s_val_b == NULL) {
            tc_fail("out of memory");
        }
    }
    s_val_toggle ^= 1;
    return s_val_toggle ? s_val_b : s_val_a;
}

static const char *cfg_toml_value_to_string(const char *raw) {
    if (raw[0] == '"' || raw[0] == '\'') {
        char *dst = cfg_value_buf();
        char *unquoted = NULL;
        if (toml_rtos(raw, &unquoted) == 0 && unquoted != NULL) {
            size_t len = strlen(unquoted);
            if (len >= VAL_BUF_SZ) {
                len = VAL_BUF_SZ - 1;
            }
            memcpy(dst, unquoted, len);
            dst[len] = '\0';
            free(unquoted);
        } else {
            dst[0] = '\0';
        }
        return dst;
    }
    return raw;
}

/* Python `aliases = config.get("aliases") or {}`: a falsy scalar counts as
   absent.  "false"/"0"/"0.0" and an empty string are falsy. */
static int cfg_aliases_scalar_ok(const char *raw) {
    if (raw[0] == '"' || raw[0] == '\'') {
        return cfg_toml_value_to_string(raw)[0] == '\0';
    }
    return strcmp(raw, "false") == 0 || strcmp(raw, "0") == 0
        || strcmp(raw, "0.0") == 0;
}

// ----------------------------------------------------------------------------
// Config loading (Python load_config_layer / load_config).
// ----------------------------------------------------------------------------

/* Choose and expand the config path.  Fills s_cfg.path, s_cfg.where,
   s_cfg.explicit and (when registered) opts->config_path.  Never fails. */
static void cfg_resolve_path(void) {
    const char *src = NULL;
    int explicit = 0;
    cfg_session_init();
    if (s_opts != NULL && (s_opts->flags & TC_F_CONFIG_GIVEN)) {
        src = s_opts->config_path;
        explicit = 1;
    } else {
        const char *env = getenv("TWITCH_COUNTS_CONFIG");
        if (env != NULL && env[0] != '\0') {
            src = env;
            explicit = 1;
        }
    }
    if (src != NULL) {
        cfg_expanduser(src, s_cfg->path, sizeof(s_cfg->path));
    } else {
        size_t len = tc_default_config_path(s_cfg->path, sizeof(s_cfg->path));
        if (len == 0 || len >= sizeof(s_cfg->path)) {
            s_cfg->path[0] = '\0';
        }
    }
    s_cfg->explicit = explicit;
    cfg_shorten_path(s_cfg->path, s_cfg->where, sizeof(s_cfg->where));
    if (s_opts != NULL) {
        snprintf(s_opts->config_path, sizeof(s_opts->config_path), "%s",
                 s_cfg->path);
    }
}

static void cfg_errno_fail(int err) {
    char detail[CFG_MSG_SZ];
    char msg[CFG_MSG_SZ];
    cfg_session_init();
    snprintf(detail, sizeof(detail), "[Errno %d] %s: '%s'", err,
             strerror(err), s_cfg->path);
    snprintf(msg, sizeof(msg), "could not read config %s: %s",
             s_cfg->path, detail);
    tc_fail(msg);
}

static void cfg_check_aliases(toml_table_t *root) {
    char msg[CFG_MSG_SZ];
    cfg_session_init();
    if (toml_table_in(root, "aliases") != NULL) {
        return;
    }
    toml_array_t *arr = toml_array_in(root, "aliases");
    if (arr != NULL) {
        if (toml_array_nelem(arr) == 0) {
            return;                   /* [] is falsy (Python `or {}`) */
        }
    } else {
        const char *raw = toml_raw_in(root, "aliases");
        if (raw == NULL) {
            return;                   /* no aliases key */
        }
        if (cfg_aliases_scalar_ok(raw)) {
            return;                   /* "" / 0 / 0.0 / false count as absent */
        }
    }
    snprintf(msg, sizeof(msg),
             "[aliases] in %s must be a table of name = channel",
             s_cfg->where);
    tc_fail(msg);
}

static void cfg_check_section_table(toml_table_t *root, const char *key) {
    char msg[CFG_MSG_SZ];
    cfg_session_init();
    if (toml_table_in(root, key) != NULL) {
        return;
    }
    if (toml_array_in(root, key) != NULL || toml_raw_in(root, key) != NULL) {
        snprintf(msg, sizeof(msg), "[%s] in %s must be a table",
                 key, s_cfg->where);
        tc_fail(msg);
    }
}

/* stat/open/read/toml_parse + the load-time table checks.  Sets s_cfg.state
   to CFG_ST_LOADED or CFG_ST_NOLOAD; fails loudly on any error. */
static void cfg_do_load(void) {
    char errbuf[CFG_ERRBUF_SZ];       /* toml_parse error text */
    char msg[CFG_MSG_SZ];
    struct stat st;
    cfg_session_init();
    if (stat(s_cfg->path, &st) != 0 || !S_ISREG(st.st_mode)) {
        if (s_cfg->explicit) {
            snprintf(msg, sizeof(msg), "config file not found: %s",
                     s_cfg->path);
            tc_fail(msg);
        }
        s_cfg->state = CFG_ST_NOLOAD;
        return;
    }
    FILE *fp = fopen(s_cfg->path, "rb");
    if (fp == NULL) {
        cfg_errno_fail(errno);
    }
    toml_table_t *root = toml_parse_file(fp, errbuf, sizeof(errbuf));
    fclose(fp);
    if (root == NULL) {
        snprintf(msg, sizeof(msg), "could not read config %s: %s",
                 s_cfg->path, errbuf);
        tc_fail(msg);
    }
    /* The Python checks these in build_inputs before any setting resolves:
       [aliases] first, then the [watch]/[tail] section shapes. */
    cfg_check_aliases(root);
    cfg_check_section_table(root, "watch");
    cfg_check_section_table(root, "tail");
    s_cfg->root = root;
    s_cfg->state = CFG_ST_LOADED;
    s_cfg->size_snapshot = (int64_t)st.st_size;
    s_cfg->mtime_ns_snapshot = (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
        + (int64_t)TC_ST_MTIME_NSEC(st);
    if (s_opts != NULL) {
        s_opts->config_loaded = 1;
    }
}

/* Idempotent lazy load — every exported hook starts here so config-load
   errors surface before any env/config value is consumed (the Python's
   build_inputs ordering). */
static void cfg_ensure_loaded(void) {
    cfg_session_init();
    if (s_cfg->state != CFG_ST_NONE) {
        return;
    }
    cfg_resolve_path();
    if (s_opts != NULL && (s_opts->flags & TC_F_NO_CONFIG)) {
        s_cfg->state = CFG_ST_NOLOAD;
        return;
    }
    cfg_do_load();
}

// ============================================================================
// Exported hooks — the contract in tc_platform.h
// ============================================================================

/* Register the session opts with the config module (exported outside the
   header: cli.c's tc_cli_parse declares it extern, mirroring the
   tc_excl_src_count data export).  tc_cli_parse calls this before resolving
   any setting, so the no-options hooks below resolve the caller's --config
   path / --no-config flag instead of the platform default.  Idempotent:
   tc_aliases_apply / tc_build_exclusions register the same opts again. */
void tc_config_register_opts(tc_opts *opts) {
    s_opts = opts;
    cfg_ensure_loaded();
}

int tc_env_get(const char *name, const char **value_out) {
    cfg_ensure_loaded();
    const char *v = getenv(name);
    if (v == NULL || v[0] == '\0') {
        *value_out = NULL;
        return 0;
    }
    *value_out = v;
    return 1;
}

int tc_config_get(const char *key, int section_id, const char **value_out,
                  int *source_out) {
    cfg_ensure_loaded();
    *value_out = NULL;
    *source_out = TC_SRC_NONE;
    if (s_cfg->state != CFG_ST_LOADED || s_cfg->root == NULL) {
        return 0;
    }
    const char *sect = NULL;
    int sect_src = TC_SRC_CONFIG_WATCH;
    if (section_id == TC_SEC_WATCH) {
        sect = "watch";
    } else if (section_id == TC_SEC_TAIL) {
        sect = "tail";
        sect_src = TC_SRC_CONFIG_TAIL;
    }
    if (sect != NULL) {
        toml_table_t *tab = toml_table_in(s_cfg->root, sect);
        if (tab != NULL) {
            const char *raw = toml_raw_in(tab, key);
            if (raw != NULL) {
                *value_out = cfg_toml_value_to_string(raw);
                *source_out = sect_src;
                return 1;
            }
        }
    }
    const char *raw = toml_raw_in(s_cfg->root, key);
    if (raw != NULL) {
        *value_out = cfg_toml_value_to_string(raw);
        *source_out = TC_SRC_CONFIG;
        return 1;
    }
    return 0;
}

/* Source labels config.c itself must compose (tc_source_str lives in cli.c,
   which is still a stub while the CLI milestone is in flight).  The labels
   are the Python's exact source strings. */
static const char *cfg_source_label(int id) {
    switch (id) {
    case TC_SRC_CLI_CHANNEL: return "--channel";
    case TC_SRC_ENV_CHANNEL: return "env TWITCH_CHANNEL";
    case TC_SRC_CONFIG: return "config";
    case TC_SRC_CLI_EXCLUDE: return "--exclude";
    case TC_SRC_CLI_EXCLUDE_GROUP: return "--exclude-group";
    case TC_SRC_CLI_EXCLUDE_BCAST: return "--exclude-broadcaster";
    case TC_SRC_ENV_EXCLUDE: return "env TWITCH_EXCLUDE";
    case TC_SRC_ENV_EXCLUDE_BCAST: return "env TWITCH_EXCLUDE_BROADCASTER";
    case TC_SRC_EXCL_CONFIG: return "config exclude";
    case TC_SRC_DEFAULT: return "default";
    default: return "";
    }
}

void tc_aliases_apply(tc_opts *opts) {
    char msg[CFG_MSG_SZ];
    s_opts = opts;
    cfg_ensure_loaded();
    /* "no channel given" guard — fires when the channel never resolved
       (source id still TC_SRC_DEFAULT), NOT when it resolved to "". */
    if (opts->src[TC_SET_CHANNEL] == TC_SRC_DEFAULT) {
        snprintf(msg, sizeof(msg),
                 "no channel given -- pass --channel, set TWITCH_CHANNEL, "
                 "or add channel = \"...\" to %s", s_cfg->where);
        tc_fail(msg);
    }
    if (s_cfg->state != CFG_ST_LOADED || s_cfg->root == NULL) {
        return;
    }
    toml_table_t *aliases = toml_table_in(s_cfg->root, "aliases");
    if (aliases == NULL) {
        return;
    }
    int total = toml_table_nkval(aliases) + toml_table_narr(aliases)
        + toml_table_ntab(aliases);
    for (int i = 0; i < total; i++) {
        const char *key = toml_key_in(aliases, i);
        if (key == NULL) {
            continue;
        }
        if (strcmp(opts->channel, key) != 0) {
            continue;
        }
        const char *raw = toml_raw_in(aliases, key);
        if (raw == NULL) {
            continue;
        }
        const char *val = cfg_toml_value_to_string(raw);
        snprintf(opts->channel, sizeof(opts->channel), "%s", val);
        snprintf(opts->chan_src, sizeof(opts->chan_src), "%s -> alias '%s'",
                 cfg_source_label(opts->src[TC_SET_CHANNEL]), key);
        opts->src[TC_SET_CHANNEL] = TC_SRC_DYN_ALIAS;
        return;
    }
}

int tc_excl_contains(const tc_excl_set *set, const char *ptr, size_t len) {
    if (set == NULL || ptr == NULL || len == 0 || len > LOGIN_CAP) {
        return 0;
    }
    for (int64_t i = 0; i < set->count; i++) {
        if (cfg_login_matches(set->entries[i].login, ptr, len)) {
            return 1;
        }
    }
    return 0;
}

// ============================================================================
// Exclusion building (Python build_exclusions).
// ============================================================================

static int cfg_qsort_strcmp(const void *a, const void *b) {
    return strcmp(*(const char *const *)a, *(const char *const *)b);
}

/* Python `", ".join(sorted(groups)) or "(none defined)"`. */
static void cfg_sort_groups_join(char *dst, size_t cap) {
    if (cap == 0) {
        return;
    }
    dst[0] = '\0';
    if (s_group_n == 0) {
        snprintf(dst, cap, "(none defined)");
        return;
    }
    const char *names[EX_GROUP_MAX];
    for (size_t i = 0; i < s_group_n; i++) {
        names[i] = s_groups[i].name;
    }
    qsort(names, s_group_n, sizeof(names[0]), cfg_qsort_strcmp);
    char *p = dst;
    char *end = dst + cap;
    for (size_t i = 0; i < s_group_n; i++) {
        if (i > 0) {
            p = cfg_cat(p, end, ", ");
        }
        p = cfg_cat(p, end, names[i]);
    }
    if (p < end) {
        *p = '\0';
    }
}

static int cfg_group_index_of(const char *name) {
    for (size_t i = 0; i < s_group_n; i++) {
        if (strcmp(s_groups[i].name, name) == 0) {
            return (int)i;
        }
    }
    return -1;
}

/* A stable copy of an always-group name, so it survives the alternating
   value buffers. */
static const char *cfg_always_name_store(const char *name) {
    size_t len = strlen(name);
    if (s_excl_tmp_cur + len + 1 > EXCL_ARENA_SZ) {
        cfg_fail_too_long();
    }
    char *dst = s_excl_tmp + s_excl_tmp_cur;
    memcpy(dst, name, len + 1);
    s_excl_tmp_cur += len + 1;
    return dst;
}

/* Python split_names: strip + lowercase, empties skipped; the string form
   splits on [,\s]+.  Fills s_split_tab/s_split_buf; returns the count. */
static size_t cfg_split_names(const char *src) {
    char *dst = s_split_buf;
    char *end = s_split_buf + EXCL_ARENA_SZ;
    size_t count = 0;
    while (*src != '\0') {
        if (cfg_is_split_sep((unsigned char)*src)) {
            src++;
            continue;
        }
        if (count >= SPLIT_MAX) {
            cfg_fail_too_many();
        }
        s_split_tab[count].ptr = dst;
        size_t len = 0;
        while (*src != '\0' && !cfg_is_split_sep((unsigned char)*src)) {
            if (dst >= end) {
                cfg_fail_too_long();
            }
            *dst++ = (char)cfg_lower_byte((unsigned char)*src++);
            len++;
        }
        if (dst >= end) {
            cfg_fail_too_long();
        }
        *dst++ = '\0';
        s_split_tab[count].len = len;
        count++;
    }
    s_split_n = count;
    return count;
}

/* Python split_names over a TOML array's stringified elements.  Same caps. */
static size_t cfg_split_toml_array(toml_array_t *arr) {
    int n = toml_array_nelem(arr);
    char *dst = s_split_buf;
    char *end = s_split_buf + EXCL_ARENA_SZ;
    size_t count = 0;
    for (int i = 0; i < n; i++) {
        const char *raw = toml_raw_at(arr, i);
        if (raw == NULL) {
            continue;
        }
        const char *str = cfg_toml_value_to_string(raw);
        size_t slen = strlen(str);
        if ((size_t)(end - dst) <= slen) {
            cfg_fail_too_long();
        }
        size_t out_len = cfg_strip_copy_lower(dst, str, slen);
        if (out_len == 0) {
            continue;
        }
        if (count >= SPLIT_MAX) {
            cfg_fail_too_many();
        }
        s_split_tab[count].ptr = dst;
        s_split_tab[count].len = out_len;
        dst += out_len;
        *dst++ = '\0';
        count++;
    }
    s_split_n = count;
    return count;
}

static size_t cfg_strip_copy_lower(char *dst, const char *src, size_t len) {
    size_t lead = 0;
    while (lead < len && cfg_is_ws((unsigned char)src[lead])) {
        lead++;
    }
    size_t end = len;
    while (end > lead && cfg_is_ws((unsigned char)src[end - 1])) {
        end--;
    }
    size_t out = end - lead;
    for (size_t i = 0; i < out; i++) {
        dst[i] = (char)cfg_lower_byte((unsigned char)src[lead + i]);
    }
    dst[out] = '\0';
    return out;
}

/* Copy the current split into the flat arena (NUL-separated). */
static void cfg_copy_split_to_flat(void) {
    size_t n = s_split_n;
    char *dst = s_excl_flat;
    char *end = s_excl_flat + EXCL_ARENA_SZ;
    for (size_t i = 0; i < n; i++) {
        size_t len = s_split_tab[i].len;
        if ((size_t)(end - dst) <= len) {
            cfg_fail_too_long();
        }
        memcpy(dst, s_split_tab[i].ptr, len);
        dst += len;
        *dst++ = '\0';
    }
    s_excl_flat_n = n;
}

/* Python config_exclusions: fills s_groups/s_always/s_excl_flat from the
   root "exclude" key.  Fails loudly on the four documented shape errors. */
static void cfg_build_groups(void) {
    char msg[CFG_MSG_SZ];
    cfg_session_init();
    if (s_cfg->state != CFG_ST_LOADED || s_cfg->root == NULL) {
        return;
    }
    toml_table_t *root = s_cfg->root;
    if (toml_raw_in(root, "exclude") != NULL) {
        snprintf(msg, sizeof(msg),
                 "`exclude` in %s must be a list of logins or a table of groups",
                 s_cfg->where);
        tc_fail(msg);
    }
    toml_array_t *arr = toml_array_in(root, "exclude");
    if (arr != NULL) {
        cfg_split_toml_array(arr);
        cfg_copy_split_to_flat();
        return;
    }
    toml_table_t *tab = toml_table_in(root, "exclude");
    if (tab == NULL) {
        return;
    }
    int total = toml_table_nkval(tab) + toml_table_narr(tab)
        + toml_table_ntab(tab);
    for (int i = 0; i < total; i++) {
        const char *name = toml_key_in(tab, i);
        if (name == NULL) {
            continue;
        }
        if (strcmp(name, "always") == 0) {
            continue;
        }
        toml_array_t *members = toml_array_in(tab, name);
        if (members == NULL) {
            snprintf(msg, sizeof(msg),
                     "[exclude].%s in %s must be a list of logins", name,
                     s_cfg->where);
            tc_fail(msg);
        }
        if (s_group_n >= EX_GROUP_MAX) {
            continue;
        }
        s_groups[s_group_n].name = name;
        s_groups[s_group_n].name_len = strlen(name);
        s_groups[s_group_n].arr = members;
        s_group_n++;
    }
    toml_array_t *always = toml_array_in(tab, "always");
    if (always != NULL) {
        int n = toml_array_nelem(always);
        for (int i = 0; i < n; i++) {
            const char *araw = toml_raw_at(always, i);
            if (araw == NULL) {
                continue;
            }
            const char *aname = cfg_toml_value_to_string(araw);
            if (cfg_group_index_of(aname) < 0) {
                char sorted[512];
                cfg_sort_groups_join(sorted, sizeof(sorted));
                snprintf(msg, sizeof(msg),
                         "[exclude].always in %s names unknown group '%s'; "
                         "defined groups: %s",
                         s_cfg->where, aname, sorted);
                tc_fail(msg);
            }
            const char *stable = cfg_always_name_store(aname);
            if (s_always_n < EX_GROUP_MAX) {
                s_always[s_always_n].name = stable;
                s_always[s_always_n].name_len = strlen(stable);
                s_always_n++;
            }
        }
    } else if (toml_raw_in(tab, "always") != NULL
               || toml_table_in(tab, "always") != NULL) {
        snprintf(msg, sizeof(msg),
                 "[exclude].always in %s must be a list of group names",
                 s_cfg->where);
        tc_fail(msg);
    }
}

/* Python exclusion_layers: every --exclude-group name must name a group. */
static void cfg_excl_validate_groups(const tc_opts *opts) {
    char msg[CFG_MSG_SZ];
    for (int i = 0; i < opts->excl_group_count; i++) {
        if (cfg_group_index_of(opts->excl_group_list[i]) >= 0) {
            continue;
        }
        char sorted[512];
        cfg_sort_groups_join(sorted, sizeof(sorted));
        snprintf(msg, sizeof(msg),
                 "unknown exclude group '%s'; defined groups: %s",
                 opts->excl_group_list[i], sorted);
        tc_fail(msg);
    }
}

/* The merged-set bookkeeping. */
static int cfg_source_add(tc_excl_set *set, const char *ptr, size_t len) {
    for (int i = 0; i < (int)tc_excl_src_count; i++) {
        if ((size_t)set->sources[i].len == len
            && memcmp(set->sources[i].ptr, ptr, len) == 0) {
            return i;
        }
    }
    int idx = (int)tc_excl_src_count;
    set->sources[idx].ptr = ptr;
    set->sources[idx].len = (int64_t)len;
    tc_excl_src_count = idx + 1;
    return idx;
}

static char *cfg_src_slot_alloc(void) {
    if (s_src_slots == NULL) {
        /* One-time process-lifetime allocation: the renderer reads the
           stored labels after tc_build_exclusions returns, so the slots
           must outlive the build call. */
        s_src_slots = malloc(SRC_SLOT_MAX * 64);
        if (s_src_slots == NULL) {
            tc_fail("out of memory");
        }
    }
    if (s_src_slot_cur >= SRC_SLOT_MAX) {
        tc_fail("too many exclusion sources (internal cap)");
    }
    return s_src_slots[s_src_slot_cur++];
}

static void cfg_add_excl_login(tc_excl_set *set, const char *login, size_t len,
                               int src_idx) {
    if (set->count >= TC_EX_MAX) {
        cfg_fail_too_many();
    }
    for (int64_t i = 0; i < set->count; i++) {
        if (cfg_login_matches(set->entries[i].login, login, len)) {
            return;                   /* first source wins */
        }
    }
    size_t n = len < LOGIN_CAP ? len : LOGIN_CAP;
    memcpy(set->entries[set->count].login, login, n);
    set->entries[set->count].login[n] = '\0';
    set->entries[set->count].source_idx = src_idx;
    set->count++;
}

/* Case-insensitive compare of a stored NUL-terminated login (<=25 chars)
   against a length-delimited candidate; the stored login must end exactly
   at `len`. */
static int cfg_login_matches(const char *stored, const char *cand, size_t len) {
    for (size_t i = 0; i < len; i++) {
        if (stored[i] == '\0') {
            return 0;
        }
        if (cfg_lower_byte((unsigned char)stored[i]) !=
            cfg_lower_byte((unsigned char)cand[i])) {
            return 0;
        }
    }
    return stored[len] == '\0';
}

static int cfg_excl_remove_if_present(tc_excl_set *set, const char *login,
                                      size_t len) {
    for (int64_t i = 0; i < set->count; i++) {
        if (!cfg_login_matches(set->entries[i].login, login, len)) {
            continue;
        }
        size_t rest = (size_t)(set->count - i - 1);
        if (rest > 0) {
            memmove(&set->entries[i], &set->entries[i + 1],
                    rest * sizeof(set->entries[0]));
        }
        set->count--;
        return 1;
    }
    return 0;
}

static void cfg_apply_split_tokens(tc_excl_set *set, int src_idx) {
    for (size_t i = 0; i < s_split_n; i++) {
        cfg_add_excl_login(set, s_split_tab[i].ptr, s_split_tab[i].len,
                           src_idx);
    }
}

static void cfg_apply_flat_tokens(tc_excl_set *set, int src_idx) {
    char *cur = s_excl_flat;
    for (size_t i = 0; i < s_excl_flat_n; i++) {
        size_t len = strlen(cur);
        cfg_add_excl_login(set, cur, len, src_idx);
        cur += len + 1;
    }
}

/* Layer 1: the config flat `exclude = [...]` form. */
static void cfg_excl_layer_flat(tc_excl_set *set) {
    if (s_excl_flat_n == 0) {
        return;
    }
    int src = cfg_source_add(set, "config exclude", strlen("config exclude"));
    cfg_apply_flat_tokens(set, src);
}

/* Layer 2: config always:<name> for each always-listed group. */
static void cfg_excl_layer_always(tc_excl_set *set) {
    for (size_t i = 0; i < s_always_n; i++) {
        int gi = cfg_group_index_of(s_always[i].name);
        if (gi < 0) {
            continue;
        }
        toml_array_t *arr = s_groups[gi].arr;
        if (arr == NULL) {
            continue;
        }
        if (cfg_split_toml_array(arr) == 0) {
            continue;                 /* an empty group contributes no layer */
        }
        char *slot = cfg_src_slot_alloc();
        snprintf(slot, 64, "config always:%s", s_always[i].name);
        int src = cfg_source_add(set, slot, strlen(slot));
        cfg_apply_split_tokens(set, src);
    }
}

/* Layer 3: --exclude-group <name> for each CLI-named group. */
static void cfg_excl_layer_group(tc_excl_set *set, const tc_opts *opts) {
    for (int i = 0; i < opts->excl_group_count; i++) {
        int gi = cfg_group_index_of(opts->excl_group_list[i]);
        if (gi < 0) {
            continue;                 /* validated above; defensive */
        }
        toml_array_t *arr = s_groups[gi].arr;
        if (arr == NULL) {
            continue;
        }
        if (cfg_split_toml_array(arr) == 0) {
            continue;
        }
        char *slot = cfg_src_slot_alloc();
        snprintf(slot, 64, "--exclude-group %s", opts->excl_group_list[i]);
        int src = cfg_source_add(set, slot, strlen(slot));
        cfg_apply_split_tokens(set, src);
    }
}

/* Layer 4: env TWITCH_EXCLUDE (empty/unset = no layer). */
static void cfg_excl_layer_env(tc_excl_set *set) {
    const char *v = getenv("TWITCH_EXCLUDE");
    if (v == NULL || v[0] == '\0') {
        return;
    }
    if (cfg_split_names(v) == 0) {
        return;
    }
    int src = cfg_source_add(set, "env TWITCH_EXCLUDE",
                             strlen("env TWITCH_EXCLUDE"));
    cfg_apply_split_tokens(set, src);
}

/* Layer 5: --exclude (repeatable, one flattened layer). */
static void cfg_excl_layer_cli(tc_excl_set *set, const tc_opts *opts) {
    int src = -1;
    for (int i = 0; i < opts->excl_count; i++) {
        if (cfg_split_names(opts->excl_list[i]) == 0) {
            continue;
        }
        if (src < 0) {
            src = cfg_source_add(set, "--exclude", strlen("--exclude"));
        }
        cfg_apply_split_tokens(set, src);
    }
}

/* Layer 6: --exclude-broadcaster — the resolved channel, lowercased. */
static void cfg_excl_layer_broadcaster(tc_excl_set *set,
                                       const tc_opts *opts) {
    if (!opts->excl_bcast_val) {
        return;
    }
    const char *label = cfg_source_label(opts->src[TC_SET_EXCLUDE_BCAST]);
    int src = cfg_source_add(set, label, strlen(label));
    char lower[TC_CHANNEL_SZ];
    size_t i = 0;
    while (opts->channel[i] != '\0' && i + 1 < sizeof(lower)) {
        lower[i] = (char)cfg_lower_byte((unsigned char)opts->channel[i]);
        i++;
    }
    lower[i] = '\0';
    cfg_add_excl_login(set, lower, strlen(lower), src);
}

/* --include subtraction: remove each named login, then report how many. */
static void cfg_excl_subtract_include(tc_excl_set *set, const tc_opts *opts) {
    int removed = 0;
    for (int i = 0; i < opts->incl_count; i++) {
        size_t n = cfg_split_names(opts->incl_list[i]);
        for (size_t j = 0; j < n; j++) {
            removed += cfg_excl_remove_if_present(set, s_split_tab[j].ptr,
                                                  s_split_tab[j].len);
        }
    }
    if (removed > 0) {
        char *slot = cfg_src_slot_alloc();
        snprintf(slot, 64, "minus --include (%d)", removed);
        cfg_source_add(set, slot, strlen(slot));
    }
}

static void cfg_noexclude_conflict(const tc_opts *opts) {
    char msg[CFG_MSG_SZ];
    const char *parts[4];
    int n = 0;
    if (opts->flags & TC_F_EXCL_GIVEN) {
        parts[n++] = "--exclude";
    }
    if (opts->flags & TC_F_EXCL_GROUP_GIVEN) {
        parts[n++] = "--exclude-group";
    }
    if (opts->flags & TC_F_EXCLUDE_BCAST) {
        parts[n++] = "--exclude-broadcaster";
    }
    if (opts->flags & TC_F_INCL_GIVEN) {
        parts[n++] = "--include";
    }
    if (n == 0) {
        return;
    }
    char *p = msg;
    char *end = msg + sizeof(msg);
    p = cfg_cat(p, end, "--no-exclude cannot be combined with ");
    for (int i = 0; i < n; i++) {
        if (i > 0) {
            p = cfg_cat(p, end, ", ");
        }
        p = cfg_cat(p, end, parts[i]);
    }
    if (p < end) {
        *p = '\0';
    }
    tc_fail(msg);
}

int tc_build_exclusions(const tc_opts *opts, tc_excl_set *set) {
    s_opts = (tc_opts *)opts;
    cfg_ensure_loaded();
    set->count = 0;
    tc_excl_src_count = 0;
    if (opts->flags & TC_F_NO_EXCLUDE) {
        cfg_noexclude_conflict(opts);   /* fails loudly on any conflict */
        return TC_EXIT_OK;
    }
    /* The transient arenas are heap-owned for the length of this call; the
       merged set copies every login out of them before they are freed. */
    cfg_excl_alloc();
    s_group_n = 0;
    s_always_n = 0;
    s_excl_flat_n = 0;
    s_excl_tmp_cur = 0;
    s_src_slot_cur = 0;
    cfg_build_groups();
    cfg_excl_validate_groups(opts);
    cfg_excl_layer_flat(set);
    cfg_excl_layer_always(set);
    cfg_excl_layer_group(set, opts);
    cfg_excl_layer_env(set);
    cfg_excl_layer_cli(set, opts);
    cfg_excl_layer_broadcaster(set, opts);
    cfg_excl_subtract_include(set, opts);
    cfg_excl_free();
    return TC_EXIT_OK;
}

// ============================================================================
// Identity memo hooks (Python config_identity; the (path,size,mtime) memo).
// ============================================================================

size_t tc_config_identity(char *dst, size_t cap) {
    if (cap == 0) {
        return 0;
    }
    cfg_session_init();
    dst[0] = '\0';
    if (s_opts != NULL && (s_opts->flags & TC_F_NO_CONFIG)) {
        return (size_t)snprintf(dst, cap, "(none)");
    }
    cfg_resolve_path();
    if (s_cfg->path[0] == '\0') {
        return (size_t)snprintf(dst, cap, "(none)");
    }
    struct stat st;
    if (stat(s_cfg->path, &st) != 0 || !S_ISREG(st.st_mode)) {
        return (size_t)snprintf(dst, cap, "%s", s_cfg->path);
    }
    int64_t mtime_ns = (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
        + (int64_t)TC_ST_MTIME_NSEC(st);
    return (size_t)snprintf(dst, cap, "%s:%lld:%lld", s_cfg->path,
                            (long long)st.st_size, (long long)mtime_ns);
}

int tc_config_changed(void) {
    cfg_session_init();
    if (s_cfg->state != CFG_ST_LOADED) {
        return 0;                     /* never loaded: memoized unchanged */
    }
    struct stat st;
    if (stat(s_cfg->path, &st) != 0) {
        return 1;                     /* vanished -> changed */
    }
    if ((int64_t)st.st_size != s_cfg->size_snapshot) {
        return 1;
    }
    int64_t mtime_ns = (int64_t)TC_ST_MTIME_SEC(st) * TC_NANOSEC
        + (int64_t)TC_ST_MTIME_NSEC(st);
    if (mtime_ns != s_cfg->mtime_ns_snapshot) {
        return 1;
    }
    return 0;
}

void tc_config_reload(void) {
    cfg_session_init();
    if (s_cfg->state != CFG_ST_LOADED || s_cfg->root == NULL) {
        return;
    }
    toml_free(s_cfg->root);
    s_cfg->root = NULL;
    s_cfg->state = CFG_ST_NONE;
    if (s_opts != NULL) {
        s_opts->config_loaded = 0;
    }
    cfg_ensure_loaded();
}