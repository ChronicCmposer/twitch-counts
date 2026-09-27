// ============================================================================
// json.c — the self-describing JSON report.
//
// tc_json_emit writes the complete report document to stdout, byte-identical
// to twitch-counts.py's --json output (json.dump(indent=2, ensure_ascii=False)
// of build_report()).  The embedded JSON Schema — the "schema" key — is
// consumed verbatim from tc_json_schema.inc (a generated C string blob,
// byte-identical to the Python report_schema()).  The payload (schema_version,
// generated_at, query, totals, rows) is rendered from the tc_report bundle:
// args (the resolved settings + provenance), context (channel + window),
// selection (the counting-pass results) and plan (the presentation).
//
// tc_json_err writes the failure document {"error": ...} to stderr and exits
// 1.  The oracle emits it with json.dump({"error": message}, sys.stderr),
// whose default ensure_ascii=True escapes every non-ASCII code point as
// \uXXXX; the report itself uses ensure_ascii=False, so non-ASCII bytes pass
// through raw.  Both share one escaper.
//
// Determinism: same report in, same bytes out.  The single exception is
// generated_at, which by contract records the wall-clock instant — the oracle
// stamps the same field with datetime.now().
// ============================================================================

/* localtime_r is a POSIX function; expose it under -std=c99. */
#define _POSIX_C_SOURCE 200809L

#include "tc_platform.h"
#include "tc_json_schema.inc"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

/* The report-format version (Python's REPORT_SCHEMA_VERSION). */
#define TC_JSON_SCHEMA_VERSION "2.1.0"

/* The provenance label when no row cap was requested under --json
   (Python's choose_limit: "unlimited for --json"). */
#define TC_JSON_UNLIMITED_SOURCE "unlimited for --json"

/* The sources-map value when no stream-state filter is active. */
#define TC_JSON_NOT_FILTERED "not filtered"

/* The sources-map value when nothing was excluded. */
#define TC_JSON_NO_EXCLUSIONS "none"

/* ============================================================================
 * Low-level JSON writing — Python's json.dump(indent=2) formatting.
 * ==========================================================================*/

/* Write depth*2 spaces. */
static void json_spaces(FILE *out, int depth) {
    int i;
    for (i = 0; i < depth; i++) {
        fputs("  ", out);
    }
}

/* The code point at *cursor (a UTF-8 sequence), or -1 when the bytes are not
   a valid UTF-8 sequence.  Advances *cursor past the sequence on success. */
static int json_utf8_decode(const unsigned char **cursor) {
    const unsigned char *p = *cursor;
    unsigned char lead = p[0];
    uint32_t cp;

    if (lead < 0x80) {
        *cursor = p + 1;
        return (int)lead;
    }
    if ((lead & 0xE0) == 0xC0) {
        if ((p[1] & 0xC0) != 0x80) {
            return -1;
        }
        cp = ((uint32_t)(lead & 0x1F) << 6) | (uint32_t)(p[1] & 0x3F);
        if (cp < 0x80) {
            return -1;                      /* overlong */
        }
        *cursor = p + 2;
        return (int)cp;
    }
    if ((lead & 0xF0) == 0xE0) {
        if ((p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80) {
            return -1;
        }
        cp = ((uint32_t)(lead & 0x0F) << 12)
           | ((uint32_t)(p[1] & 0x3F) << 6)
           | (uint32_t)(p[2] & 0x3F);
        if (cp < 0x800) {
            return -1;                      /* overlong */
        }
        if (cp >= 0xD800 && cp <= 0xDFFF) {
            return -1;                      /* surrogate half */
        }
        *cursor = p + 3;
        return (int)cp;
    }
    if ((lead & 0xF8) == 0xF0) {
        if ((p[1] & 0xC0) != 0x80 || (p[2] & 0xC0) != 0x80
            || (p[3] & 0xC0) != 0x80) {
            return -1;
        }
        cp = ((uint32_t)(lead & 0x07) << 18)
           | ((uint32_t)(p[1] & 0x3F) << 12)
           | ((uint32_t)(p[2] & 0x3F) << 6)
           | (uint32_t)(p[3] & 0x3F);
        if (cp < 0x10000 || cp > 0x10FFFF) {
            return -1;
        }
        *cursor = p + 4;
        return (int)cp;
    }
    return -1;
}

/* The four lowercase hex digits of a \uXXXX escape. */
static void json_write_u_escape(FILE *out, uint32_t cp) {
    static const char hex[] = "0123456789abcdef";
    fputc('\\', out);
    fputc('u', out);
    fputc(hex[(cp >> 12) & 0xF], out);
    fputc(hex[(cp >> 8) & 0xF], out);
    fputc(hex[(cp >> 4) & 0xF], out);
    fputc(hex[cp & 0xF], out);
}

/* One JSON string, escaped exactly as Python's json.dumps does.  With
   ensure_ascii, every non-ASCII code point becomes \uXXXX (a surrogate pair
   for astral ones); without, its UTF-8 bytes pass through raw. */
static void json_write_escaped(FILE *out, const char *text, int ensure_ascii) {
    const unsigned char *p = (const unsigned char *)text;
    fputc('"', out);
    while (*p != '\0') {
        unsigned char c = *p;
        switch (c) {
        case '"':  fputs("\\\"", out); p++; continue;
        case '\\': fputs("\\\\", out); p++; continue;
        case '\b': fputs("\\b", out);  p++; continue;
        case '\f': fputs("\\f", out);  p++; continue;
        case '\n': fputs("\\n", out);  p++; continue;
        case '\r': fputs("\\r", out);  p++; continue;
        case '\t': fputs("\\t", out);  p++; continue;
        default:
            if (c < 0x20) {
                json_write_u_escape(out, c);
                p++;
            } else if (ensure_ascii && (c >= 0x80 || c == 0x7F)) {
                int cp = json_utf8_decode(&p);
                if (cp < 0) {
                    fputc(c, out);      /* undecodable: pass the byte raw */
                    p++;
                } else if (cp <= 0xFFFF) {
                    json_write_u_escape(out, (uint32_t)cp);
                } else {
                    uint32_t v = (uint32_t)cp - 0x10000;
                    json_write_u_escape(out, 0xD800 + (v >> 10));
                    json_write_u_escape(out, 0xDC00 + (v & 0x3FF));
                }
            } else {
                fputc(c, out);
                p++;
            }
        }
    }
    fputc('"', out);
}

/* The report's strings: non-ASCII passes through (ensure_ascii=False). */
static void json_write_string(FILE *out, const char *text) {
    json_write_escaped(out, text, 0);
}

static void json_write_int(FILE *out, int64_t value) {
    char buf[24];
    char *end;
    if (value < 0) {
        fputc('-', out);
        value = -value;
    }
    end = tc_fmt_u64(buf, (uint64_t)value);
    *end = '\0';
    fputs(buf, out);
}

static void json_write_bool(FILE *out, int flag) {
    fputs(flag ? "true" : "false", out);
}

/* A date-time as Python's datetime.isoformat() would render it. */
static void json_write_datetime(FILE *out, int64_t ymd, int64_t sod) {
    int y, mo, d, h, mi, s;
    char buf[32];
    char *p = buf;
    tc_ymd_split(ymd, &y, &mo, &d);
    tc_sod_split(sod, &h, &mi, &s);
    p = tc_fmt4(p, (uint64_t)y);
    *p++ = '-';
    p = tc_fmt2(p, (uint64_t)mo);
    *p++ = '-';
    p = tc_fmt2(p, (uint64_t)d);
    *p++ = 'T';
    p = tc_fmt2(p, (uint64_t)h);
    *p++ = ':';
    p = tc_fmt2(p, (uint64_t)mi);
    *p++ = ':';
    p = tc_fmt2(p, (uint64_t)s);
    *p = '\0';
    fputs(buf, out);
}

/* generated_at: the local wall-clock instant, seconds precision (the Python
   stamps datetime.now().replace(microsecond=0).isoformat()). */
static void json_write_generated_at(FILE *out) {
    time_t now = time(NULL);
    struct tm local;
    localtime_r(&now, &local);
    json_write_datetime(out,
        (int64_t)(local.tm_year + TC_TM_YEAR_BASE) * 10000
            + (int64_t)(local.tm_mon + 1) * 100 + local.tm_mday,
        (int64_t)local.tm_hour * TC_SECS_PER_HOUR
            + (int64_t)local.tm_min * 60 + local.tm_sec);
}

/* '"key": ' at the given depth (2 spaces per depth). */
static void json_key(FILE *out, int depth, const char *key) {
    json_spaces(out, depth);
    fputc('"', out);
    fputs(key, out);
    fputs("\": ", out);
}

static void json_key_string(FILE *out, int depth, const char *key,
                            const char *value) {
    json_key(out, depth, key);
    json_write_string(out, value);
}

static void json_key_int(FILE *out, int depth, const char *key,
                         int64_t value) {
    json_key(out, depth, key);
    json_write_int(out, value);
}

static void json_key_bool(FILE *out, int depth, const char *key, int flag) {
    json_key(out, depth, key);
    json_write_bool(out, flag);
}

static void json_key_null(FILE *out, int depth, const char *key) {
    json_key(out, depth, key);
    fputs("null", out);
}

/* ============================================================================
 * The payload sections.  Each json_emit_* writes one top-level key complete
 * with its value, from '{' to '}'; the caller supplies the separators.
 * ==========================================================================*/

/* One entry of the query "sources" map (Python's settings.sources()). */
typedef struct {
    const char *name;
    const char *value;
} json_source_entry;

static void json_source_add(json_source_entry *entries, int *count, int cap,
                            const char *name, const char *value) {
    if (*count >= cap) {
        tc_fail("json: internal error: too many provenance entries");
    }
    entries[*count].name = name;
    entries[*count].value = value;
    (*count)++;
}

/* The "sources" object: where each reported setting came from, sorted by key
   so the payload is canonical (Python's dict(sorted(...))). */
static void json_emit_sources(FILE *out, int depth, const tc_report *report) {
    const tc_opts *opts = report->args;
    const tc_window *window = &report->context->window;
    const tc_plan *plan = &report->plan;
    json_source_entry entries[13];
    int count = 0;
    int i;
    int j;

    /* The reportable settings with a resolved value (Python's sources() scan
       over SETTINGS, report=True).  The C port resolves sort and top to
       built-in values even when nobody asked, so those two are gated on
       their provenance rather than on a value. */
    if (opts->src[TC_SET_CHANNEL] != TC_SRC_NONE) {
        json_source_add(entries, &count, 13, "channel",
                        tc_source_str(opts->src[TC_SET_CHANNEL]));
    }
    if (opts->src[TC_SET_END] != TC_SRC_DEFAULT_NOW) {
        json_source_add(entries, &count, 13, "end",
                        tc_source_str(opts->src[TC_SET_END]));
    }
    json_source_add(entries, &count, 13, "min_count",
                    tc_source_str(opts->src[TC_SET_MIN_COUNT]));
    /* The C port has no standalone "show" setting: --show columns merge into
       opts.columns.  A "--show" mention in the merged columns' source marks
       the flag as asked for (Python then reports "show": "--show"). */
    if (opts->columns_src_ptr != NULL
        && strstr(opts->columns_src_ptr, "--show") != NULL) {
        json_source_add(entries, &count, 13, "show", "--show");
    }
    if (opts->src[TC_SET_SORT] != TC_SRC_DEFAULT_BUILTIN) {
        json_source_add(entries, &count, 13, "sort",
                        tc_source_str(opts->src[TC_SET_SORT]));
    }
    json_source_add(entries, &count, 13, "share_floor",
                    tc_source_str(opts->src[TC_SET_SHARE_FLOOR]));
    json_source_add(entries, &count, 13, "logs_dir",
                    tc_source_str(opts->src[TC_SET_LOGS_DIR]));
    json_source_add(entries, &count, 13, "header",
                    tc_source_str(opts->src[TC_SET_HEADER]));

    /* The derived entries (Python's report_sources() extras). */
    json_source_add(entries, &count, 13, "begin",
                    window->start_source != NULL ? window->start_source
                                                 : "default");
    json_source_add(entries, &count, 13, "top",
                    plan->limit_source != NULL ? plan->limit_source
                                               : TC_JSON_UNLIMITED_SOURCE);
    json_source_add(entries, &count, 13, "state",
                    window->state_filter != TC_ST_NONE
                        ? tc_source_str(opts->src[TC_SET_STATE])
                        : TC_JSON_NOT_FILTERED);
    json_source_add(entries, &count, 13, "exclude",
                    (plan->src_join != NULL && plan->src_join[0] != '\0')
                        ? plan->src_join
                        : TC_JSON_NO_EXCLUSIONS);

    /* dict(sorted(...)): canonical, byte-stable key order. */
    for (i = 1; i < count; i++) {
        json_source_entry entry = entries[i];
        j = i - 1;
        while (j >= 0 && strcmp(entries[j].name, entry.name) > 0) {
            entries[j + 1] = entries[j];
            j--;
        }
        entries[j + 1] = entry;
    }

    json_key(out, depth, "sources");
    fputs("{\n", out);
    for (i = 0; i < count; i++) {
        json_key_string(out, depth + 1, entries[i].name, entries[i].value);
        fputs(i + 1 < count ? ",\n" : "\n", out);
    }
    json_spaces(out, depth);
    fputc('}', out);
}

/* The query "excluded" array: the sorted exclusion set. */
static void json_emit_excluded(FILE *out, int depth, const tc_report *report) {
    const tc_plan *plan = &report->plan;
    int64_t i;
    json_key(out, depth, "excluded");
    if (plan->excl_names_n == 0) {
        fputs("[]", out);
        return;
    }
    fputs("[\n", out);
    for (i = 0; i < plan->excl_names_n; i++) {
        json_spaces(out, depth + 1);
        json_write_string(out, plan->excl_names[i]);
        fputs(i + 1 < plan->excl_names_n ? ",\n" : "\n", out);
    }
    json_spaces(out, depth);
    fputc(']', out);
}

/* The query "share_floor" object.  "applied" is whether the floor acted:
   the presentation recorded a floor (Python's share_floor is not None). */
static void json_emit_share_floor(FILE *out, int depth,
                                  const tc_report *report) {
    json_key(out, depth, "share_floor");
    fputs("{\n", out);
    json_key_int(out, depth + 1, "requested", report->args->share_floor);
    fputs(",\n", out);
    json_key_bool(out, depth + 1, "applied", report->plan.share_floor != 0);
    fputs("\n", out);
    json_spaces(out, depth);
    fputc('}', out);
}

/* The query object: what was asked for, and where each setting came from. */
static void json_emit_query(FILE *out, int depth, const tc_report *report) {
    const tc_context *ctx = report->context;
    const tc_plan *plan = &report->plan;
    json_key(out, depth, "query");
    fputs("{\n", out);
    json_key_string(out, depth + 1, "channel", ctx->channel_name);
    fputs(",\n", out);
    json_key(out, depth + 1, "begin");
    fputc('"', out);
    json_write_datetime(out, ctx->window.begin_ymd, ctx->window.begin_sod);
    fputc('"', out);
    fputs(",\n", out);
    json_key(out, depth + 1, "end");
    fputc('"', out);
    json_write_datetime(out, ctx->window.end_ymd, ctx->window.end_sod);
    fputc('"', out);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "min_count", ctx->window.threshold);
    fputs(",\n", out);
    if (plan->limit > 0) {
        json_key_int(out, depth + 1, "top", plan->limit);
    } else {
        json_key_null(out, depth + 1, "top");
    }
    fputs(",\n", out);
    if (ctx->window.state_filter != TC_ST_NONE) {
        json_key_string(out, depth + 1, "state",
                        tc_state_str(ctx->window.state_filter));
    } else {
        json_key_null(out, depth + 1, "state");
    }
    fputs(",\n", out);
    json_emit_excluded(out, depth + 1, report);
    fputs(",\n", out);
    json_key_string(out, depth + 1, "sort", tc_metrics[plan->sort].name);
    fputs(",\n", out);
    json_emit_share_floor(out, depth + 1, report);
    fputs(",\n", out);
    json_emit_sources(out, depth + 1, report);
    fputs("\n", out);
    json_spaces(out, depth);
    fputc('}', out);
}

/* A {state: count} object with the live/offline/unknown keys in order,
   absent when zero (Python's STATES iteration).  `depth` is the depth of
   the object itself. */
static void json_emit_states_body(FILE *out, int depth, int64_t live,
                                  int64_t offline, int64_t unknown) {
    static const char *const state_names[3] = { "live", "offline", "unknown" };
    int64_t values[3];
    int shown = 0;
    int emitted = 0;
    int i;
    values[0] = live;
    values[1] = offline;
    values[2] = unknown;
    for (i = 0; i < 3; i++) {
        if (values[i] > 0) {
            shown++;
        }
    }
    if (shown == 0) {
        fputs("{}", out);
        return;
    }
    fputs("{\n", out);
    for (i = 0; i < 3; i++) {
        if (values[i] <= 0) {
            continue;
        }
        json_key_int(out, depth + 1, state_names[i], values[i]);
        emitted++;
        fputs(emitted < shown ? ",\n" : "\n", out);
    }
    json_spaces(out, depth);
    fputc('}', out);
}

/* The totals "cache" object: whether the day-rollup cache served the query. */
static void json_emit_cache(FILE *out, int depth, const tc_report *report) {
    const tc_plan *plan = &report->plan;
    json_key(out, depth, "cache");
    fputs("{\n", out);
    json_key_bool(out, depth + 1, "used", plan->cache_used != 0);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "days_reused", plan->cache_reused);
    fputs(",\n", out);
    json_key(out, depth + 1, "problem");
    if (plan->cache_problem != NULL) {
        json_write_string(out, plan->cache_problem);
    } else {
        fputs("null", out);
    }
    fputs("\n", out);
    json_spaces(out, depth);
    fputc('}', out);
}

/* The totals "unreadable" array: {file, problem} rows for skipped logs. */
static void json_emit_unreadable(FILE *out, int depth,
                                 const tc_report *report) {
    const tc_selection *selection = report->selection;
    int64_t i;
    json_key(out, depth, "unreadable");
    if (selection->unreadable_count == 0) {
        fputs("[]", out);
        return;
    }
    fputs("[\n", out);
    for (i = 0; i < selection->unreadable_count; i++) {
        const tc_unreadable_entry *entry = &selection->unreadable[i];
        json_spaces(out, depth + 1);
        fputs("{\n", out);
        json_key_string(out, depth + 2, "file", entry->name);
        fputs(",\n", out);
        json_key_string(out, depth + 2, "problem", entry->reason);
        fputs("\n", out);
        json_spaces(out, depth + 1);
        fputc('}', out);
        fputs(i + 1 < selection->unreadable_count ? ",\n" : "\n", out);
    }
    json_spaces(out, depth);
    fputc(']', out);
}

/* The totals object: counts describing the range and what was withheld. */
static void json_emit_totals(FILE *out, int depth, const tc_report *report) {
    const tc_selection *selection = report->selection;
    const tc_plan *plan = &report->plan;
    json_key(out, depth, "totals");
    fputs("{\n", out);
    json_key_int(out, depth + 1, "users_shown", plan->displayed_n);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "users_above_threshold", plan->reported_n);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "users_in_range", plan->in_range);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "users_excluded", plan->excl_appeared);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "messages_shown", plan->msgs_shown);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "messages_in_range",
                 selection->total_messages);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "messages_hidden", plan->msgs_hidden);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "messages_excluded", plan->excl_msgs);
    fputs(",\n", out);
    json_key_bool(out, depth + 1, "truncated", plan->hidden_n > 0);
    fputs(",\n", out);
    json_key(out, depth + 1, "states");
    json_emit_states_body(out, depth + 1, selection->states[0],
                          selection->states[1], selection->states[2]);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "log_files", selection->files);
    fputs(",\n", out);
    json_key_int(out, depth + 1, "users_below_share_floor",
                 plan->below_floor);
    fputs(",\n", out);
    json_emit_cache(out, depth + 1, report);
    fputs(",\n", out);
    json_emit_unreadable(out, depth + 1, report);
    fputs("\n", out);
    json_spaces(out, depth);
    fputc('}', out);
}

/* The "rows" array: the displayed users, ordered by query.sort. */
static void json_emit_rows(FILE *out, int depth, const tc_report *report) {
    const tc_plan *plan = &report->plan;
    int64_t i;
    json_key(out, depth, "rows");
    if (plan->displayed_n == 0) {
        fputs("[]", out);
        return;
    }
    fputs("[\n", out);
    for (i = 0; i < plan->displayed_n; i++) {
        const tc_reported_row *row = &plan->reported[i];
        json_spaces(out, depth + 1);
        fputs("{\n", out);
        json_key_string(out, depth + 2, "login", row->login);
        fputs(",\n", out);
        json_key_int(out, depth + 2, "count", row->count);
        fputs(",\n", out);
        json_key(out, depth + 2, "states");
        json_emit_states_body(out, depth + 2, row->live, row->offline,
                              row->unknown);
        fputs("\n", out);
        json_spaces(out, depth + 1);
        fputc('}', out);
        fputs(i + 1 < plan->displayed_n ? ",\n" : "\n", out);
    }
    json_spaces(out, depth);
    fputc(']', out);
}

/* ============================================================================
 * Public entry points.
 * ==========================================================================*/

int tc_json_emit(const tc_report *report) {
    if (report == NULL || report->args == NULL || report->context == NULL
        || report->selection == NULL) {
        tc_fail("json: internal error: incomplete report");
    }

    fputs("{\n", stdout);
    fwrite(tc_json_schema_blob, 1, sizeof(tc_json_schema_blob) - 1, stdout);

    fputs("  \"schema_version\": \"", stdout);
    fputs(TC_JSON_SCHEMA_VERSION, stdout);
    fputs("\",\n", stdout);

    fputs("  \"generated_at\": \"", stdout);
    json_write_generated_at(stdout);
    fputs("\",\n", stdout);

    json_emit_query(stdout, 1, report);
    fputs(",\n", stdout);
    json_emit_totals(stdout, 1, report);
    fputs(",\n", stdout);
    json_emit_rows(stdout, 1, report);
    fputs("\n", stdout);
    fputc('}', stdout);
    fputc('\n', stdout);
    fflush(stdout);

    return TC_EXIT_OK;
}

void tc_json_err(const char *msg) {
    if (msg == NULL) {
        msg = "";
    }
    fputs("{\"error\": ", stderr);
    json_write_escaped(stderr, msg, 1);
    fputs("}\n", stderr);
    fflush(stderr);
    exit(TC_EXIT_ERROR);
}