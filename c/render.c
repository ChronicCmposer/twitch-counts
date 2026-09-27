// ============================================================================
// render.c — output formatting (plan, then text or JSON).
//
//  Byte-for-byte port of the Python reference's presentation half:
//    plan_presentation / choose_columns / rank_users / sort_rows / add_column
//      (4492-4791),
//    provenance_rows / window_span / state_row / exclude_row / share_floor_row
//      / users_row / cache_row / unreadable_row (4550-4686),
//    header_lines / compact_header / column_widths / align_row (4811-4869),
//    results_table / pin_user_column / footer_lines (4872-4947),
//    render_text (4950-4985), choose_limit / adaptive_row_limit (4727-4810).
//
//  The plan is built from the already-counted selection (the parse happened
//  at the boundary): tc_plan_presentation reads the users table and turns it
//  into the ranked, floored, capped layout json.c/watch.c consume.  Text
//  output flows through one put-line seam so watch mode can capture frames.
//
//  Exported (tc_platform.h):
//    tc_render_report()   the entry: plan, then emit JSON or text
//    tc_plan_presentation() fill the plan (ranking, columns, header rows,
//                          limit, displayed/hidden split)
//    tc_render_text()     render the text report from the plan
//    tc_report_fail()     "error: <msg>" stderr + exit 1, or the JSON
//                          {"error": <msg>} shape under --json
//    tc_frame_begin/end/set_pin/set_tint  watch-mode frame hooks
//    tc_metrics           the metric metadata table (name/header/kind)
//
//  Row cap: --top wins (0 switches it off), then --json is unlimited, then
//  the terminal height (isatty + tc_term_lines); piped output is unlimited.
//  limit 0 = no cap.  Share sorts and cells use Python's exact double
//  expression (100.0 * part / total), so ordering and "%.1f" rendering are
//  byte-identical to the oracle.
// ============================================================================

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// ----------------------------------------------------------------------------
// Externs outside the header contract (the header documents both).
// ----------------------------------------------------------------------------
extern int64_t tc_excl_src_count;                 /* config.c */
extern const char *tc_cache_rebuilt_reason(const tc_cache *cache); /* cache.c */

// ----------------------------------------------------------------------------
// The metric metadata table (the header's extern; every module reads it).
// Indexed by TC_M_*; kind matches Python's Metric.kind.
// ----------------------------------------------------------------------------
const tc_metric_info tc_metrics[TC_M_MAX] = {
    { "count",        "count",    TC_METRIC_KIND_COUNT  },
    { "login",        "login",    TC_METRIC_KIND_COUNT  },
    { "live",         "live",     TC_METRIC_KIND_COUNT  },
    { "offline",      "offline",  TC_METRIC_KIND_COUNT  },
    { "unknown",      "unknown",  TC_METRIC_KIND_COUNT  },
    { "offline-share","offline%", TC_METRIC_KIND_SHARE  },
    { "live-share",   "live%",    TC_METRIC_KIND_SHARE  },
};

// ----------------------------------------------------------------------------
// Fixed-size render buffers.  Every line is built here, then either printed
// or captured into the active frame's line slots.
// ----------------------------------------------------------------------------
#define RENDER_LINE_SZ  2048
#define RENDER_CELL_SZ  96
static char s_line[RENDER_LINE_SZ];
static char s_cell[RENDER_CELL_SZ];

/* The watch seam: tc_frame_begin arms capture and records the caller's frame
   (its lines/max pre-filled); tc_render_text reads pin/tint/capture from it.
   A one-shot render has no active frame and behaves exactly like Python's
   bare Frame() — nothing tinted, nothing pinned, everything printed. */
static tc_frame *s_active_frame;

// ----------------------------------------------------------------------------
// Number formatting.  tc_fmt_u64 writes plain digits; render_fmt_u64_commas
// inserts the thousands separators Python's f"{n:,}" produces.
// ----------------------------------------------------------------------------
static char *render_fmt_u64_commas(char *dst, uint64_t v) {
    char digits[24];
    char *end = tc_fmt_u64(digits, v);
    int n = (int)(end - digits);
    int i;
    for (i = 0; i < n; i++) {
        if (i > 0 && (n - i) % 3 == 0) {
            *dst++ = ',';
        }
        *dst++ = digits[i];
    }
    return dst;
}

// ----------------------------------------------------------------------------
// The put-line seam: every rendered line ends with one '\n' (Python's print).
// While a frame is capturing, the line is copied into the next slot instead.
// ----------------------------------------------------------------------------
static void render_puts_line(const char *line) {
    if (s_active_frame != NULL && s_active_frame->capture) {
        if (s_active_frame->count < s_active_frame->max) {
            strcpy((char *)s_active_frame->lines[s_active_frame->count], line);
            s_active_frame->count++;
        }
        return;
    }
    tc_puts(line);
    tc_puts("\n");
}

// ----------------------------------------------------------------------------
// Date/time phrasing (Python str(datetime) pieces).
// ----------------------------------------------------------------------------
/* "YYYY-MM-DD" -> cursor past the NUL. */
static char *render_fmt_ymd(char *dst, int64_t ymd) {
    int y, m, d;
    tc_ymd_split(ymd, &y, &m, &d);
    dst = tc_fmt4(dst, (uint64_t)y);
    *dst++ = '-';
    dst = tc_fmt2(dst, (uint64_t)m);
    *dst++ = '-';
    dst = tc_fmt2(dst, (uint64_t)d);
    *dst = '\0';
    return dst;
}

/* "MM-DD HH:MM" -> cursor past the NUL. */
static char *render_fmt_mmdd_hhmm(char *dst, int64_t ymd, int64_t sod) {
    int y, m, d, h, min, s;
    tc_ymd_split(ymd, &y, &m, &d);
    tc_sod_split(sod, &h, &min, &s);
    (void)y;
    (void)s;
    dst = tc_fmt2(dst, (uint64_t)m);
    *dst++ = '-';
    dst = tc_fmt2(dst, (uint64_t)d);
    *dst++ = ' ';
    dst = tc_fmt2(dst, (uint64_t)h);
    *dst++ = ':';
    dst = tc_fmt2(dst, (uint64_t)min);
    *dst = '\0';
    return dst;
}

/* "HH:MM" -> cursor past the NUL. */
static char *render_fmt_hhmm(char *dst, int64_t sod) {
    int h, min, s;
    tc_sod_split(sod, &h, &min, &s);
    (void)s;
    dst = tc_fmt2(dst, (uint64_t)h);
    *dst++ = ':';
    dst = tc_fmt2(dst, (uint64_t)min);
    *dst = '\0';
    return dst;
}

/* Python window_span: the compact begin form. */
static void render_window_span(char *dst, size_t cap, const tc_opts *opts,
                               const tc_window *window) {
    char buf[TC_HDR_COMPACT_SZ];
    char *cur = buf;
    if (opts->src[TC_SET_END] == TC_SRC_DEFAULT_NOW) {
        cur = render_fmt_mmdd_hhmm(cur, window->begin_ymd, window->begin_sod);
        cur = tc_cat_cstr(cur, "..now");
    } else if (window->begin_ymd == window->end_ymd) {
        cur = render_fmt_mmdd_hhmm(cur, window->begin_ymd, window->begin_sod);
        cur = tc_cat_cstr(cur, "..");
        cur = render_fmt_hhmm(cur, window->end_sod);
    } else {
        cur = render_fmt_ymd(cur, window->begin_ymd);
        cur = tc_cat_cstr(cur, "..");
        cur = render_fmt_ymd(cur, window->end_ymd);
    }
    tc_copy_str_cap(dst, buf, cap);
}

/* Python human_duration: the shortest --since would accept back. */
static void render_human_duration(char *dst, size_t cap, int64_t seconds) {
    static const struct {
        const char *unit;
        int64_t size;
    } units[] = {
        { "d", 86400 }, { "h", 3600 }, { "m", 60 }, { "s", 1 }
    };
    char buf[32];
    char *cur = buf;
    size_t i;
    for (i = 0; i < sizeof(units) / sizeof(units[0]); i++) {
        if (seconds >= units[i].size) {
            cur = tc_fmt_u64(cur, (uint64_t)(seconds / units[i].size));
            cur = tc_cat_cstr(cur, units[i].unit);
            seconds %= units[i].size;
        }
    }
    if (buf[0] == '\0') {
        buf[0] = '0';
        buf[1] = 's';
        buf[2] = '\0';
    }
    tc_copy_str_cap(dst, buf, cap);
}

/* "--users-policy" value names, indexed by TC_POLICY_*. */
static const char *render_policy_name(int policy) {
    static const char *const names[3] = {
        "at-least", "at-most", "nearest"
    };
    if (policy < TC_POLICY_AT_LEAST || policy > TC_POLICY_NEAREST) {
        return "at-least";
    }
    return names[policy];
}

// ----------------------------------------------------------------------------
// Share cells.  The exact Python expression (100.0 * part / total) so the
// double and the "%.1f" rendering are byte-identical; an empty total is 0.0.
// ----------------------------------------------------------------------------
static char *render_fmt_share_cell(char *dst, size_t cap, int64_t part,
                                   int64_t total) {
    double value;
    if (total <= 0) {
        value = 0.0;
    } else {
        value = 100.0 * (double)part / (double)total;
    }
    snprintf(dst, cap, "%.1f%%", value);
    return dst + strlen(dst);
}

// ----------------------------------------------------------------------------
// The header-row table (Python provenance_rows).  Each fact becomes one
// tc_header_row in plan order; a row with nothing to say is never added.
// ----------------------------------------------------------------------------
static void plan_hdr_add(tc_plan *plan, const char *label, const char *value,
                         const char *source, const char *compact) {
    tc_header_row *row;
    if (plan->hdr_count >= TC_PLAN_HDR_MAX) {
        return;
    }
    row = &plan->hdr_rows[plan->hdr_count];
    tc_copy_str_cap(row->label, label, sizeof(row->label));
    tc_copy_str_cap(row->value, value, sizeof(row->value));
    tc_copy_str_cap(row->source, source, sizeof(row->source));
    row->compact[0] = '\0';
    if (compact != NULL) {
        tc_copy_str_cap(row->compact, compact, sizeof(row->compact));
    }
    plan->hdr_count++;
}

static void plan_hdr_users(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_window *window = &report->context->window;
    const tc_opts *opts = report->args;
    char value[TC_HDR_VALUE_SZ];
    char source[TC_HDR_SOURCE_SZ];
    char compact[TC_HDR_COMPACT_SZ];
    char *cur;

    if (window->users_width == 0) {
        return;                     /* --users never ran */
    }
    cur = value;
    cur = render_fmt_u64_commas(cur, (uint64_t)window->users_req);
    cur = tc_cat_cstr(cur, " asked for, ");
    cur = render_fmt_u64_commas(cur, (uint64_t)window->users_found);
    cur = tc_cat_cstr(cur, " found over ");
    render_human_duration(cur, sizeof(value) - (size_t)(cur - value),
                          window->users_width);
    cur = source;
    cur = tc_cat_cstr(cur, tc_source_str(opts->src[TC_SET_USERS_POLICY]));
    cur = tc_cat_cstr(cur, " ");
    cur = tc_cat_cstr(cur, render_policy_name(opts->users_policy));
    if (window->users_found != window->users_req) {
        char *cc = compact;
        cc = render_fmt_u64_commas(cc, (uint64_t)window->users_found);
        cc = tc_cat_cstr(cc, "/");
        cc = render_fmt_u64_commas(cc, (uint64_t)window->users_req);
        cc = tc_cat_cstr(cc, " users");
        plan_hdr_add(plan, "users", value, source, compact);
    } else {
        plan_hdr_add(plan, "users", value, source, NULL);
    }
}

static void plan_hdr_state(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_selection *selection = report->selection;
    const tc_window *window = &report->context->window;
    const tc_opts *opts = report->args;
    const int64_t *states = selection->states;
    int filter = window->state_filter;
    char value[TC_HDR_VALUE_SZ];
    char source[TC_HDR_SOURCE_SZ];
    char compact[TC_HDR_COMPACT_SZ];
    char *cur;
    int first;
    int i;

    if (states[0] == 0 && states[1] == 0 && states[2] == 0) {
        return;
    }
    /* value: nonzero states "name N" joined " / " (commas) */
    cur = value;
    first = 1;
    for (i = 0; i < 3; i++) {
        if (states[i] == 0) {
            continue;
        }
        if (!first) {
            cur = tc_cat_cstr(cur, " / ");
        }
        cur = tc_cat_cstr(cur, tc_state_str(i + 1));
        cur = tc_cat_cstr(cur, " ");
        cur = render_fmt_u64_commas(cur, (uint64_t)states[i]);
        first = 0;
    }
    *cur = '\0';
    /* source: "<state src> keeps <name>" when filtered, else "not filtered" */
    cur = source;
    if (filter) {
        cur = tc_cat_cstr(cur, tc_source_str(opts->src[TC_SET_STATE]));
        cur = tc_cat_cstr(cur, " keeps ");
        cur = tc_cat_cstr(cur, tc_state_str(filter));
    } else {
        cur = tc_cat_cstr(cur, "not filtered");
    }
    /* compact: "NAME only" when filtered, else the split joined " " */
    cur = compact;
    if (filter) {
        cur = tc_cat_cstr(cur, tc_state_str(filter));
        cur = tc_cat_cstr(cur, " only");
    } else {
        first = 1;
        for (i = 0; i < 3; i++) {
            if (states[i] == 0) {
                continue;
            }
            if (!first) {
                *cur++ = ' ';
            }
            cur = tc_cat_cstr(cur, tc_state_str(i + 1));
            *cur = ' ';
            cur++;
            cur = render_fmt_u64_commas(cur, (uint64_t)states[i]);
            first = 0;
        }
        *cur = '\0';
    }
    plan_hdr_add(plan, "state", value, source, compact);
}

static void plan_hdr_exclude(tc_report *report) {
    tc_plan *plan = &report->plan;
    char value[TC_HDR_VALUE_SZ];
    char compact[TC_HDR_COMPACT_SZ];
    char *cur;
    int64_t n = plan->excl_names_n;
    int64_t appeared = plan->excl_appeared;
    int64_t preview_n;
    int64_t i;
    int first;

    if (n == 0) {
        return;
    }
    /* value: "N login(s), M in range: preview" (plain numbers) */
    cur = value;
    cur = tc_fmt_u64(cur, (uint64_t)n);
    cur = tc_cat_cstr(cur, " login(s), ");
    cur = tc_fmt_u64(cur, (uint64_t)appeared);
    cur = tc_cat_cstr(cur, " in range: ");
    preview_n = n < 3 ? n : 3;
    first = 1;
    for (i = 0; i < preview_n; i++) {
        if (!first) {
            *cur++ = ',';
            *cur++ = ' ';
        }
        cur = tc_cat_cstr(cur, plan->excl_names[i]);
        first = 0;
    }
    if (n > 3) {
        *cur++ = ',';
        *cur++ = ' ';
        *cur++ = '+';
        cur = tc_fmt_u64(cur, (uint64_t)(n - 3));
        cur = tc_cat_cstr(cur, " more");
    }
    if (appeared > 0) {
        char *cc = compact;
        *cc++ = '-';
        cc = tc_fmt_u64(cc, (uint64_t)appeared);
        cc = tc_cat_cstr(cc, " excl");
        plan_hdr_add(plan, "exclude", value,
                     plan->src_join != NULL ? plan->src_join : "",
                     compact);
    } else {
        plan_hdr_add(plan, "exclude", value,
                     plan->src_join != NULL ? plan->src_join : "",
                     NULL);
    }
}

static void plan_hdr_share_floor(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_opts *opts = report->args;
    char value[TC_HDR_VALUE_SZ];
    char compact[TC_HDR_COMPACT_SZ];
    char *cur;
    int asked = opts->src[TC_SET_SHARE_FLOOR] != TC_SRC_DEFAULT_BUILTIN;

    if (plan->share_floor != 0) {
        cur = value;
        cur = tc_cat_cstr(cur, ">= ");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->share_floor);
        cur = tc_cat_cstr(cur, " message(s), ");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->below_floor);
        cur = tc_cat_cstr(cur, " user(s) dropped");
        cur = compact;
        cur = tc_cat_cstr(cur, "floor >=");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->share_floor);
        cur = tc_cat_cstr(cur, ", -");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->below_floor);
        *cur = '\0';
        plan_hdr_add(plan, "share floor", value,
                     tc_source_str(opts->src[TC_SET_SHARE_FLOOR]), compact);
    } else if (asked) {
        const char *shown_value;
        const char *shown_compact;
        if (plan->shares_shown) {
            shown_value = "disabled -- every share shown, on however few messages";
            shown_compact = "floor off";
        } else {
            shown_value = "not applied -- no share is shown or sorted by";
            shown_compact = "floor unused";
        }
        plan_hdr_add(plan, "share floor", shown_value,
                     tc_source_str(opts->src[TC_SET_SHARE_FLOOR]),
                     shown_compact);
    }
}

static void plan_hdr_cache(tc_report *report) {
    tc_plan *plan = &report->plan;
    char value[TC_HDR_VALUE_SZ];
    char source[TC_HDR_SOURCE_SZ];
    char *cur;

    if (plan->cache_used) {
        cur = value;
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->cache_reused);
        cur = tc_cat_cstr(cur, " day(s) reused, ");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->cache_parsed);
        cur = tc_cat_cstr(cur, " parsed");
        if (plan->cache_rebuilt != NULL) {
            char *cc = source;
            cc = tc_cat_cstr(cc, "rebuilt: ");
            cc = tc_cat_cstr(cc, plan->cache_rebuilt);
            plan_hdr_add(plan, "cache", value, source, NULL);
        } else if (plan->cache_path != NULL) {
            tc_copy_str_cap(source, tc_shorten_path(plan->cache_path),
                            sizeof(source));
            plan_hdr_add(plan, "cache", value, source, NULL);
        } else {
            plan_hdr_add(plan, "cache", value, "rollup.db", NULL);
        }
    } else if (plan->cache_problem != NULL) {
        cur = value;
        cur = tc_cat_cstr(cur, "unavailable -- ");
        cur = tc_cat_cstr(cur, plan->cache_problem);
        plan_hdr_add(plan, "cache", value, "every file parsed", "no cache");
    }
}

static void plan_hdr_unreadable(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_selection *selection = report->selection;
    char value[TC_HDR_VALUE_SZ];
    char compact[TC_HDR_COMPACT_SZ];
    char *cur;
    int64_t n = selection->unreadable_count;
    int64_t preview_n;
    int64_t i;
    int first;

    if (n == 0) {
        return;
    }
    /* value: "N file(s) skipped: names (reason)" (plain numbers) */
    cur = value;
    cur = tc_fmt_u64(cur, (uint64_t)n);
    cur = tc_cat_cstr(cur, " file(s) skipped: ");
    preview_n = n < 2 ? n : 2;
    first = 1;
    for (i = 0; i < preview_n; i++) {
        if (!first) {
            *cur++ = ',';
            *cur++ = ' ';
        }
        cur = tc_cat_cstr(cur, selection->unreadable[i].name);
        first = 0;
    }
    if (n > 2) {
        *cur++ = ',';
        *cur++ = ' ';
        *cur++ = '+';
        cur = tc_fmt_u64(cur, (uint64_t)(n - 2));
        cur = tc_cat_cstr(cur, " more");
    }
    *cur++ = ' ';
    *cur++ = '(';
    cur = tc_cat_cstr(cur, selection->unreadable[0].reason);
    *cur++ = ')';
    *cur = '\0';
    /* compact "N unread" */
    cur = compact;
    cur = tc_fmt_u64(cur, (uint64_t)n);
    cur = tc_cat_cstr(cur, " unread");
    plan_hdr_add(plan, "unreadable", value, "not counted", compact);
}

static void build_header_rows(tc_report *report) {
    tc_plan *plan = &report->plan;
    tc_context *context = report->context;
    tc_opts *opts = report->args;
    tc_window *window = &context->window;
    char value[TC_HDR_VALUE_SZ];
    char compact[TC_HDR_COMPACT_SZ];
    char *cur;
    int i;

    /* channel */
    plan_hdr_add(plan, "channel", context->channel_name,
                 tc_source_str(opts->src[TC_SET_CHANNEL]),
                 context->channel_name);

    /* logs dir */
    tc_copy_str_cap(value, tc_shorten_path(opts->logs_dir), sizeof(value));
    plan_hdr_add(plan, "logs dir", value,
                 tc_source_str(opts->src[TC_SET_LOGS_DIR]), NULL);

    /* begin: the window is two rows, each with its own provenance, but one
       span in compact — so the span rides on 'begin' and 'end' is full-only. */
    {
        char *end = tc_fmt_ymd_sod(value, window->begin_ymd,
                                   window->begin_sod, ' ');
        *end = '\0';
    }
    render_window_span(compact, sizeof(compact), opts, window);
    plan_hdr_add(plan, "begin", value,
                 window->start_source != NULL ? window->start_source : "",
                 compact);

    /* end */
    {
        char *end = tc_fmt_ymd_sod(value, window->end_ymd,
                                   window->end_sod, ' ');
        *end = '\0';
    }
    plan_hdr_add(plan, "end", value,
                 tc_source_str(opts->src[TC_SET_END]), NULL);

    /* threshold */
    cur = value;
    cur = tc_cat_cstr(cur, ">= ");
    cur = tc_fmt_u64(cur, (uint64_t)window->threshold);
    cur = tc_cat_cstr(cur, " message(s)");
    cur = compact;
    cur = tc_cat_cstr(cur, ">=");
    cur = tc_fmt_u64(cur, (uint64_t)window->threshold);
    *cur = '\0';
    plan_hdr_add(plan, "threshold", value,
                 tc_source_str(opts->src[TC_SET_MIN_COUNT]), compact);

    plan_hdr_users(report);
    plan_hdr_state(report);
    plan_hdr_exclude(report);

    /* columns: "count, " + the metric names beyond count */
    if (plan->col_count > 0) {
        cur = value;
        cur = tc_cat_cstr(cur, "count");
        for (i = 0; i < plan->col_count; i++) {
            cur = tc_cat_cstr(cur, ", ");
            cur = tc_cat_cstr(cur, tc_metric_str(plan->columns[i]));
        }
        plan_hdr_add(plan, "columns", value,
                     opts->columns_src_ptr != NULL ? opts->columns_src_ptr
                                                   : "",
                     NULL);
    }

    /* sort: only a non-count sort earns a row */
    if (plan->sort != TC_M_COUNT) {
        char *cc = compact;
        cc = tc_cat_cstr(cc, "by ");
        cc = tc_cat_cstr(cc, tc_metric_str(plan->sort));
        plan_hdr_add(plan, "sort", tc_metric_str(plan->sort),
                     tc_source_str(opts->src[TC_SET_SORT]), compact);
    }

    plan_hdr_share_floor(report);

    /* config */
    if (context->config_loaded) {
        tc_copy_str_cap(value, tc_shorten_path(context->config_path),
                        sizeof(value));
        plan_hdr_add(plan, "config", value, "loaded", NULL);
    }

    plan_hdr_cache(report);
    plan_hdr_unreadable(report);
}

// ----------------------------------------------------------------------------
// The ranking pipeline (Python rank_users + sort_rows + the unknown join).
// ----------------------------------------------------------------------------
/* The count column under the resolved state filter: the sum of the buckets
   matching the filter, or all three when unfiltered (Python's counts[]). */
static int64_t render_count_for_filter(const tc_user_entry *user, int filter) {
    switch (filter) {
    case TC_ST_LIVE:
        return user->live;
    case TC_ST_OFFLINE:
        return user->offline;
    case TC_ST_UNKNOWN:
        return user->unknown;
    default:
        return tc_user_count(user);
    }
}

/* Walk 1: count reported/in-range/excluded totals, then allocate. */
static void plan_rank_count(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_selection *selection = report->selection;
    const tc_window *window = &report->context->window;
    const tc_users *users = selection->users;
    const tc_excl_set *exclusions = selection->exclusions;
    int64_t reported_n = 0;
    int64_t in_range = 0;
    int64_t excl_appeared = 0;
    int64_t excl_msgs = 0;
    int64_t threshold = window->threshold;
    int filter = window->state_filter;
    int64_t i;

    for (i = 0; i < users->count; i++) {
        const tc_user_entry *entry = &users->entries[i];
        size_t llen = strlen(entry->login);
        int64_t count = render_count_for_filter(entry, filter);
        if (tc_excl_contains(exclusions, entry->login, llen)) {
            if (count > 0) {
                excl_appeared++;
                excl_msgs += count;
            }
        } else {
            if (count > 0) {
                in_range++;
            }
            if (count >= threshold) {
                reported_n++;
            }
        }
    }
    plan->reported_n = reported_n;
    plan->in_range = in_range;
    plan->excl_appeared = excl_appeared;
    plan->excl_msgs = excl_msgs;
    if (reported_n > 0) {
        plan->reported = malloc((size_t)reported_n * sizeof(tc_reported_row));
        if (plan->reported == NULL) {
            tc_report_fail(report, "out of memory");
        }
    }
}

/* Walk 2: fill the reported records (login, count, per-state split). */
static void plan_rank_fill(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_selection *selection = report->selection;
    const tc_window *window = &report->context->window;
    const tc_users *users = selection->users;
    const tc_excl_set *exclusions = selection->exclusions;
    int64_t threshold = window->threshold;
    int filter = window->state_filter;
    int64_t fill = 0;
    int64_t i;

    for (i = 0; i < users->count; i++) {
        const tc_user_entry *entry = &users->entries[i];
        size_t llen = strlen(entry->login);
        tc_reported_row *row;
        int64_t count;
        if (tc_excl_contains(exclusions, entry->login, llen)) {
            continue;
        }
        count = render_count_for_filter(entry, filter);
        if (count < threshold) {
            continue;
        }
        row = &plan->reported[fill++];
        tc_copy_str_cap(row->login, entry->login, sizeof(row->login));
        row->count = count;
        row->live = entry->live;
        row->offline = entry->offline;
        row->unknown = entry->unknown;
        row->key = 0;
    }
    plan->reported_n = fill;
}

/* The share floor: when a share is shown or sorted by and the floor is
   non-zero, compact the reported array to rows meeting it. */
static void plan_rank_floor(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_opts *opts = report->args;
    int64_t floor = opts->share_floor;
    int64_t kept = 0;
    int64_t i;

    if (!plan->shares_shown || floor == 0) {
        plan->share_floor = 0;
        plan->below_floor = 0;
        return;
    }
    for (i = 0; i < plan->reported_n; i++) {
        if (plan->reported[i].count >= floor) {
            if (kept != i) {
                plan->reported[kept] = plan->reported[i];
            }
            kept++;
        }
    }
    plan->share_floor = floor;
    plan->below_floor = plan->reported_n - kept;
    plan->reported_n = kept;
}

/* Python's share expression, for the sort key. */
static double row_sort_share(const tc_reported_row *row, int metric) {
    int64_t part = metric == TC_M_LIVE_SHARE ? row->live : row->offline;
    if (row->count <= 0) {
        return 0.0;
    }
    return 100.0 * (double)part / (double)row->count;
}

/* Python sort_rows: the chosen metric descending, ties broken by login
   ascending (the login tie-break makes the order total, so stability is
   irrelevant).  Returns <0 when a sorts before b. */
static int reported_compare(const tc_reported_row *a,
                            const tc_reported_row *b, int metric) {
    int order;
    if (metric == TC_M_LOGIN) {
        return strcmp(a->login, b->login);
    }
    switch (metric) {
    case TC_M_LIVE:
        order = (a->live > b->live) - (a->live < b->live);
        break;
    case TC_M_OFFLINE:
        order = (a->offline > b->offline) - (a->offline < b->offline);
        break;
    case TC_M_UNKNOWN:
        order = (a->unknown > b->unknown) - (a->unknown < b->unknown);
        break;
    case TC_M_OFFLINE_SHARE:
    case TC_M_LIVE_SHARE: {
        double sa = row_sort_share(a, metric);
        double sb = row_sort_share(b, metric);
        if (sa < sb) {
            return 1;
        }
        if (sa > sb) {
            return -1;
        }
        return strcmp(a->login, b->login);
    }
    default:                        /* count */
        order = (a->count > b->count) - (a->count < b->count);
        break;
    }
    if (order != 0) {
        return order < 0 ? 1 : -1;  /* descending */
    }
    return strcmp(a->login, b->login);
}

/* In-place heapsort with the metric passed explicitly (no hidden state for
   qsort's context-free comparator). */
static void reported_sift(tc_reported_row *rows, int64_t n, int64_t root,
                          int metric) {
    for (;;) {
        int64_t left = 2 * root + 1;
        int64_t right = left + 1;
        int64_t largest = root;
        if (left < n
            && reported_compare(&rows[left], &rows[largest], metric) > 0) {
            largest = left;
        }
        if (right < n
            && reported_compare(&rows[right], &rows[largest], metric) > 0) {
            largest = right;
        }
        if (largest == root) {
            break;
        }
        {
            tc_reported_row tmp = rows[root];
            rows[root] = rows[largest];
            rows[largest] = tmp;
        }
        root = largest;
    }
}

static void reported_sort(tc_reported_row *rows, int64_t n, int metric) {
    int64_t i;
    if (n < 2) {
        return;
    }
    for (i = n / 2 - 1; i >= 0; i--) {
        reported_sift(rows, n, i, metric);
    }
    for (i = n - 1; i > 0; i--) {
        tc_reported_row tmp = rows[0];
        rows[0] = rows[i];
        rows[i] = tmp;
        reported_sift(rows, i, 0, metric);
    }
}

/* Add a metric column once, optionally ahead of offline-share (Python
   add_column; the single place a column joins the list). */
static void plan_add_column(tc_plan *plan, enum tc_metric metric) {
    int at = plan->col_count;
    int i;
    if (plan->col_count >= TC_COLUMNS_MAX) {
        return;
    }
    for (i = 0; i < plan->col_count; i++) {
        if (plan->columns[i] == metric) {
            return;
        }
    }
    for (i = 0; i < plan->col_count; i++) {
        if (plan->columns[i] == TC_M_OFFLINE_SHARE) {
            at = i;
            break;
        }
    }
    for (i = plan->col_count; i > at; i--) {
        plan->columns[i] = plan->columns[i - 1];
    }
    plan->columns[at] = metric;
    plan->col_count++;
}

/* 'unknown' earns a column under --by-state when any reported row has one. */
static void plan_rank_unknown(tc_report *report) {
    tc_plan *plan = &report->plan;
    int64_t i;
    if (!(report->args->flags & TC_F_BY_STATE)) {
        return;
    }
    for (i = 0; i < plan->reported_n; i++) {
        if (plan->reported[i].unknown > 0) {
            plan_add_column(plan, TC_M_UNKNOWN);
            return;
        }
    }
}

// ----------------------------------------------------------------------------
// Exclusions: sorted login names + the ", "-joined source labels.
// ----------------------------------------------------------------------------
static int excl_name_cmp(const void *a, const void *b) {
    const char *const *pa = a;
    const char *const *pb = b;
    return strcmp(*pa, *pb);
}

static void plan_exclusions(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_excl_set *set = report->selection->exclusions;
    int64_t n = set->count;
    int64_t i;

    plan->excl_names_n = n;
    if (n > 0) {
        const char **names = malloc((size_t)n * sizeof(*names));
        if (names == NULL) {
            tc_report_fail(report, "out of memory");
        }
        for (i = 0; i < n; i++) {
            names[i] = set->entries[i].login;
        }
        qsort(names, (size_t)n, sizeof(*names), excl_name_cmp);
        plan->excl_names = names;
    }

    /* ", "-join the source records into the arena (bounded append). */
    if (tc_excl_src_count > 0) {
        char *dst = plan->arena + plan->arena_cur;
        char *cur = dst;
        size_t left = sizeof(plan->arena) - plan->arena_cur;
        for (i = 0; i < tc_excl_src_count; i++) {
            const char *ptr = set->sources[i].ptr;
            int64_t len = set->sources[i].len;
            if (len < 0) {
                len = 0;
            }
            if (i > 0) {
                if (left < 2) {
                    break;
                }
                *cur++ = ',';
                *cur++ = ' ';
                left -= 2;
            }
            if ((int64_t)left < len) {
                len = (int64_t)left - 1;
            }
            if (len > 0) {
                memcpy(cur, ptr, (size_t)len);
                cur += len;
                left -= (size_t)len;
            }
        }
        *cur = '\0';
        plan->arena_cur = (size_t)(cur + 1 - plan->arena);
        plan->src_join = dst;
    }
}

// ----------------------------------------------------------------------------
// Cache snapshot (Python cache_row's inputs), read once into the plan.
// ----------------------------------------------------------------------------
static void plan_cache_snapshot(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_selection *selection = report->selection;
    tc_cache *cache = selection->cache;

    if (cache != NULL) {
        int64_t reused;
        int64_t parsed;
        const char *problem;
        const char *path;
        tc_cache_status(cache, &reused, &parsed, &problem, &path);
        plan->cache_used = 1;
        plan->cache_reused = reused;
        plan->cache_parsed = parsed;
        plan->cache_problem = selection->cache_problem;
        plan->cache_rebuilt = tc_cache_rebuilt_reason(cache);
        plan->cache_path = path;
    } else {
        plan->cache_used = 0;
        plan->cache_reused = 0;
        plan->cache_parsed = 0;
        plan->cache_problem = selection->cache_problem;
        plan->cache_rebuilt = NULL;
        plan->cache_path = NULL;
    }
}

// ----------------------------------------------------------------------------
// The row cap (Python choose_limit + adaptive_row_limit).
// ----------------------------------------------------------------------------
static int64_t adaptive_row_limit(int64_t header_lines) {
    int64_t lines;
    if (!isatty(1)) {
        return 0;                   /* piped output stays complete */
    }
    lines = tc_term_lines();
    {
        int64_t fit = lines - (header_lines + 8);
        return fit >= 5 ? fit : 5;
    }
}

static void choose_limit(tc_report *report) {
    tc_plan *plan = &report->plan;
    tc_opts *opts = report->args;
    int64_t reserved;

    if (opts->src[TC_SET_TOP] != TC_SRC_DEFAULT_BUILTIN) {
        /* --top (or env/config) asked; 0 is the documented way to switch a
           configured limit back off. */
        plan->limit = opts->top;
        plan->limit_source = tc_source_str(opts->src[TC_SET_TOP]);
        return;
    }
    if (opts->flags & TC_F_JSON) {
        /* machine output must never be trimmed by the size of a window */
        plan->limit = 0;
        plan->limit_source = "unlimited for --json";
        return;
    }
    switch (opts->header_mode) {
    case TC_HDR_FULL:
        reserved = plan->hdr_count + 2;
        break;
    case TC_HDR_COMPACT:
        reserved = 2;
        break;
    default:
        reserved = 0;
        break;
    }
    if (opts->flags & TC_F_WATCH_PRESENT) {
        reserved += 2;
    }
    plan->limit = adaptive_row_limit(reserved);
    plan->limit_source = "terminal height";
}

/* The displayed/hidden split, the message sums, and the "top" row. */
static void build_top_row(tc_report *report) {
    tc_plan *plan = &report->plan;
    char value[TC_HDR_VALUE_SZ];
    char compact[TC_HDR_COMPACT_SZ];
    char *cur;

    cur = value;
    cur = render_fmt_u64_commas(cur, (uint64_t)plan->limit);
    cur = tc_cat_cstr(cur, " row(s)");
    if (plan->hidden_n > 0) {
        cur = tc_cat_cstr(cur, ", ");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->hidden_n);
        cur = tc_cat_cstr(cur, " hidden");
        cur = compact;
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->displayed_n);
        cur = tc_cat_cstr(cur, "/");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->reported_n);
        cur = tc_cat_cstr(cur, " rows");
        plan_hdr_add(plan, "top", value,
                     plan->limit_source != NULL ? plan->limit_source : "",
                     compact);
    } else {
        plan_hdr_add(plan, "top", value,
                     plan->limit_source != NULL ? plan->limit_source : "",
                     NULL);
    }
}

static void split_display(tc_report *report) {
    tc_plan *plan = &report->plan;
    int64_t displayed;
    int64_t i;

    if (plan->limit != 0 && plan->reported_n > 0) {
        displayed = plan->reported_n < plan->limit ? plan->reported_n
                                                   : plan->limit;
    } else {
        displayed = plan->reported_n;
    }
    plan->displayed_n = displayed;
    plan->hidden_n = plan->reported_n - displayed;
    plan->msgs_shown = 0;
    for (i = 0; i < displayed; i++) {
        plan->msgs_shown += plan->reported[i].count;
    }
    plan->msgs_hidden = 0;
    for (i = displayed; i < plan->reported_n; i++) {
        plan->msgs_hidden += plan->reported[i].count;
    }
    if (plan->limit != 0 && plan->reported_n > 0) {
        build_top_row(report);
    }
}

// ----------------------------------------------------------------------------
// The first two plan stages.
// ----------------------------------------------------------------------------
/* Exit 1 when a state filter meets state columns or a state sort: the split
   would be degenerate (Python's plan_presentation ConfigError). */
static void render_degeneracy_check(tc_report *report) {
    const tc_opts *opts = report->args;
    const tc_window *window = &report->context->window;
    int filter = window->state_filter;
    char msg[256];
    char *cur;
    int i;

    if (!filter) {
        return;
    }
    if (opts->sort >= TC_M_LIVE && opts->sort <= TC_M_LIVE_SHARE) {
        goto degenerate;
    }
    for (i = 0; i < opts->column_count; i++) {
        if (opts->columns[i] >= TC_M_LIVE
            && opts->columns[i] <= TC_M_LIVE_SHARE) {
            goto degenerate;
        }
    }
    return;
degenerate:
    cur = msg;
    cur = tc_cat_cstr(cur, "--");
    cur = tc_cat_cstr(cur, tc_state_str(filter));
    cur = tc_cat_cstr(cur, " counts one state only, so per-state columns "
                           "and sorts would be degenerate -- drop the state "
                           "filter to compare states");
    tc_report_fail(report, msg);
}

/* Copy the merged metric columns, the sort and the header mode; compute
   shares_shown (Python choose_columns + rank_users' gating). */
static void render_plan_columns(tc_report *report) {
    tc_plan *plan = &report->plan;
    const tc_opts *opts = report->args;
    int i;

    plan->col_count = opts->column_count;
    for (i = 0; i < opts->column_count; i++) {
        plan->columns[i] = opts->columns[i];
    }
    plan->sort = opts->sort;
    plan->header_mode = opts->header_mode;
    plan->shares_shown = 0;
    if (opts->sort >= TC_M_OFFLINE_SHARE && opts->sort <= TC_M_LIVE_SHARE) {
        plan->shares_shown = 1;
    }
    for (i = 0; i < plan->col_count; i++) {
        if (plan->columns[i] >= TC_M_OFFLINE_SHARE
            && plan->columns[i] <= TC_M_LIVE_SHARE) {
            plan->shares_shown = 1;
        }
    }
}

// ----------------------------------------------------------------------------
// tc_plan_presentation — the layout phase.
// ----------------------------------------------------------------------------
int tc_plan_presentation(tc_report *report) {
    if (report == NULL || report->args == NULL || report->context == NULL
        || report->selection == NULL) {
        tc_fail("render: internal error: incomplete report");
    }
    /* reset the plan (frees any prior ranking; the one-shot caller's plan is
       zeroed, so the first call frees nothing) */
    free(report->plan.reported);
    free(report->plan.excl_names);
    memset(&report->plan, 0, sizeof(report->plan));

    render_degeneracy_check(report);
    render_plan_columns(report);
    plan_rank_count(report);
    plan_rank_fill(report);
    plan_rank_floor(report);
    reported_sort(report->plan.reported, report->plan.reported_n,
                   report->plan.sort);
    plan_rank_unknown(report);
    plan_exclusions(report);
    plan_cache_snapshot(report);
    build_header_rows(report);
    choose_limit(report);
    split_display(report);
    return TC_EXIT_OK;
}

// ----------------------------------------------------------------------------
// Text rendering (Python render_text and its helpers).
// ----------------------------------------------------------------------------
/* The aligned header block: "label:  value  [source]" columns, then the
   files line, then the blank separator. */
static void render_header_line(const tc_header_row *row, int64_t w0,
                               int64_t w1) {
    char *cur = s_line;
    size_t llen = strlen(row->label);
    size_t vlen = strlen(row->value);
    size_t slen = strlen(row->source);
    int64_t pad;

    memcpy(cur, row->label, llen);
    cur += llen;
    *cur++ = ':';
    pad = w0 - (int64_t)llen - 1;
    while (pad-- > 0) {
        *cur++ = ' ';
    }
    *cur++ = ' ';
    *cur++ = ' ';
    memcpy(cur, row->value, vlen);
    cur += vlen;
    pad = w1 - (int64_t)vlen;
    while (pad-- > 0) {
        *cur++ = ' ';
    }
    *cur++ = ' ';
    *cur++ = ' ';
    *cur++ = '[';
    memcpy(cur, row->source, slen);
    cur += slen;
    *cur++ = ']';
    *cur = '\0';
    render_puts_line(s_line);
}

static void render_full_header(tc_report *report) {
    tc_plan *plan = &report->plan;
    int64_t w0 = 0;
    int64_t w1 = 0;
    char *cur;
    char digits[24];
    char *end;
    int64_t i;

    for (i = 0; i < plan->hdr_count; i++) {
        const tc_header_row *row = &plan->hdr_rows[i];
        int64_t l0 = (int64_t)strlen(row->label) + 1;
        int64_t l1 = (int64_t)strlen(row->value);
        if (l0 > w0) {
            w0 = l0;
        }
        if (l1 > w1) {
            w1 = l1;
        }
    }
    if (w1 > 48) {
        w1 = 48;                    /* the value cap: no path pushes the tag off */
    }
    for (i = 0; i < plan->hdr_count; i++) {
        render_header_line(&plan->hdr_rows[i], w0, w1);
    }
    /* files line: the value is unpadded (align_row rstrips the padding) */
    cur = s_line;
    memcpy(cur, "files", 5);
    cur += 5;
    *cur++ = ':';
    {
        int64_t pad = w0 - 5 - 1;
        while (pad-- > 0) {
            *cur++ = ' ';
        }
    }
    *cur++ = ' ';
    *cur++ = ' ';
    end = tc_fmt_u64(digits, (uint64_t)report->selection->files);
    memcpy(cur, digits, (size_t)(end - digits));
    cur += end - digits;
    cur = tc_cat_cstr(cur, " log file(s) in range");
    render_puts_line(s_line);
    render_puts_line("");
}

/* The provenance block boiled down to one line. */
static void render_compact_header(tc_report *report) {
    tc_plan *plan = &report->plan;
    char *cur = s_line;
    int first = 1;
    int64_t i;

    for (i = 0; i < plan->hdr_count; i++) {
        const tc_header_row *row = &plan->hdr_rows[i];
        size_t clen;
        if (row->compact[0] == '\0') {
            continue;
        }
        if (!first) {
            memcpy(cur, " \xC2\xB7 ", 4);    /* " · " (4 bytes, no NUL) */
            cur += 4;
        }
        clen = strlen(row->compact);
        memcpy(cur, row->compact, clen);
        cur += clen;
        first = 0;
    }
    *cur = '\0';
    render_puts_line(s_line);
    render_puts_line("");
}

/* One rendered table cell. */
static char *cell_render(const tc_reported_row *row, int metric, char *buf,
                         size_t cap) {
    char *cur = buf;
    switch (metric) {
    case TC_M_COUNT:
        cur = render_fmt_u64_commas(cur, (uint64_t)row->count);
        break;
    case TC_M_LIVE:
        cur = render_fmt_u64_commas(cur, (uint64_t)row->live);
        break;
    case TC_M_OFFLINE:
        cur = render_fmt_u64_commas(cur, (uint64_t)row->offline);
        break;
    case TC_M_UNKNOWN:
        cur = render_fmt_u64_commas(cur, (uint64_t)row->unknown);
        break;
    case TC_M_OFFLINE_SHARE:
        cur = render_fmt_share_cell(buf, cap, row->offline, row->count);
        break;
    case TC_M_LIVE_SHARE:
        cur = render_fmt_share_cell(buf, cap, row->live, row->count);
        break;
    default:
        break;
    }
    *cur = '\0';
    return cur;
}

/* The login cell: clipped to the pin (watch) or padded to the width. */
static char *login_cell(char *dst, const char *login, int64_t width) {
    int64_t pin = s_active_frame != NULL ? s_active_frame->pin_width : 0;
    size_t len = strlen(login);
    if (pin > 0 && (int64_t)len > width) {
        memcpy(dst, login, (size_t)(width - 1));
        dst += width - 1;
        *dst++ = (char)0xE2;
        *dst++ = (char)0x80;
        *dst++ = (char)0xA6;        /* U+2026 … */
        return dst;
    }
    memcpy(dst, login, len);
    dst += len;
    while ((int64_t)len < width) {
        *dst++ = ' ';
        len++;
    }
    return dst;
}

/* rjust a cell into the line (Python align_row's "r" side). */
static char *cell_rjust(char *dst, const char *cell, int64_t width) {
    size_t len = strlen(cell);
    int64_t pad = width - (int64_t)len;
    while (pad-- > 0) {
        *dst++ = ' ';
    }
    memcpy(dst, cell, len);
    return dst + len;
}

static void render_rule(const int64_t *widths, int64_t ncols) {
    char *cur = s_line;
    int64_t c;
    for (c = 0; c < ncols; c++) {
        int64_t w = widths[c];
        if (c > 0) {
            *cur++ = ' ';
            *cur++ = ' ';
        }
        while (w-- > 0) {
            *cur++ = '-';
        }
    }
    *cur = '\0';
    render_puts_line(s_line);
}

static void render_table_header(const tc_plan *plan, const int64_t *widths,
                                int64_t ncols) {
    char *cur = s_line;
    int64_t c;
    cur = login_cell(cur, "user", widths[0]);
    for (c = 1; c < ncols; c++) {
        const char *header;
        if (c == 1) {
            header = tc_metrics[TC_M_COUNT].header;
        } else {
            header = tc_metrics[plan->columns[c - 2]].header;
        }
        *cur++ = ' ';
        *cur++ = ' ';
        cur = cell_rjust(cur, header, widths[c]);
    }
    *cur = '\0';
    render_puts_line(s_line);
}

static void render_table_row(tc_report *report, const tc_reported_row *row,
                             const int64_t *widths, int64_t ncols) {
    tc_plan *plan = &report->plan;
    char *text;
    char *cur = s_line;
    int64_t c;
    cur = login_cell(cur, row->login, widths[0]);
    for (c = 1; c < ncols; c++) {
        int metric = c == 1 ? TC_M_COUNT : plan->columns[c - 2];
        *cur++ = ' ';
        *cur++ = ' ';
        cell_render(row, metric, s_cell, sizeof(s_cell));
        cur = cell_rjust(cur, s_cell, widths[c]);
    }
    *cur = '\0';
    text = s_line;
    if (s_active_frame != NULL && s_active_frame->tint_fn != NULL) {
        text = s_active_frame->tint_fn(s_line, row->login, row->count,
                                       s_active_frame->tint_ctx);
    }
    render_puts_line(text);
}

static void render_others_row(tc_report *report, const int64_t *widths,
                              int64_t ncols) {
    tc_plan *plan = &report->plan;
    char *cur = s_line;
    int64_t pooled_live = 0;
    int64_t pooled_offline = 0;
    int64_t pooled_unknown = 0;
    int64_t i;
    char *cc;

    /* the pooled login cell "+ N others" */
    cc = s_cell;
    *cc++ = '+';
    *cc++ = ' ';
    cc = render_fmt_u64_commas(cc, (uint64_t)plan->hidden_n);
    cc = tc_cat_cstr(cc, " others");
    cur = login_cell(cur, s_cell, widths[0]);

    for (i = plan->displayed_n; i < plan->reported_n; i++) {
        pooled_live += plan->reported[i].live;
        pooled_offline += plan->reported[i].offline;
        pooled_unknown += plan->reported[i].unknown;
    }
    for (i = 1; i < ncols; i++) {
        int metric = i == 1 ? TC_M_COUNT : plan->columns[i - 2];
        *cur++ = ' ';
        *cur++ = ' ';
        switch (metric) {
        case TC_M_COUNT:
            cc = render_fmt_u64_commas(s_cell, (uint64_t)plan->msgs_hidden);
            *cc = '\0';
            break;
        case TC_M_LIVE:
            cc = render_fmt_u64_commas(s_cell, (uint64_t)pooled_live);
            *cc = '\0';
            break;
        case TC_M_OFFLINE:
            cc = render_fmt_u64_commas(s_cell, (uint64_t)pooled_offline);
            *cc = '\0';
            break;
        case TC_M_UNKNOWN:
            cc = render_fmt_u64_commas(s_cell, (uint64_t)pooled_unknown);
            *cc = '\0';
            break;
        case TC_M_OFFLINE_SHARE:
            render_fmt_share_cell(s_cell, sizeof(s_cell), pooled_offline,
                                  plan->msgs_hidden);
            break;
        case TC_M_LIVE_SHARE:
            render_fmt_share_cell(s_cell, sizeof(s_cell), pooled_live,
                                  plan->msgs_hidden);
            break;
        default:
            s_cell[0] = '\0';
            break;
        }
        cur = cell_rjust(cur, s_cell, widths[i]);
    }
    *cur = '\0';
    render_puts_line(s_line);
}

static void render_excluded_line(tc_report *report) {
    tc_plan *plan = &report->plan;
    char *cur = s_line;
    cur = tc_cat_cstr(cur, "excluded ");
    cur = render_fmt_u64_commas(cur, (uint64_t)plan->excl_appeared);
    cur = tc_cat_cstr(cur, " user(s), ");
    cur = render_fmt_u64_commas(cur, (uint64_t)plan->excl_msgs);
    cur = tc_cat_cstr(cur, " message(s) not counted");
    render_puts_line(s_line);
}

static void render_footer(tc_report *report) {
    tc_plan *plan = &report->plan;
    char *cur = s_line;

    if (plan->hidden_n > 0) {
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->displayed_n);
        cur = tc_cat_cstr(cur, " of ");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->reported_n);
        cur = tc_cat_cstr(cur, " user(s) above threshold (");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->in_range);
        cur = tc_cat_cstr(cur, " in range)");
    } else {
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->reported_n);
        cur = tc_cat_cstr(cur, " of ");
        cur = render_fmt_u64_commas(cur, (uint64_t)plan->in_range);
        cur = tc_cat_cstr(cur, " user(s)");
    }
    cur = tc_cat_cstr(cur, "; ");
    cur = render_fmt_u64_commas(cur, (uint64_t)plan->msgs_shown);
    cur = tc_cat_cstr(cur, " of ");
    cur = render_fmt_u64_commas(cur,
                                (uint64_t)report->selection->total_messages);
    cur = tc_cat_cstr(cur, " message(s) in range");
    render_puts_line(s_line);
    if (plan->excl_appeared > 0) {
        render_excluded_line(report);
    }
}

/* The empty report: no table, just the message and the excluded line. */
static void render_empty_report(tc_report *report) {
    tc_plan *plan = &report->plan;
    char *cur = s_line;
    cur = tc_cat_cstr(cur, "No users met the threshold (");
    cur = tc_fmt_u64(cur, (uint64_t)report->selection->total_messages);
    cur = tc_cat_cstr(cur, " message(s) in range).");
    render_puts_line(s_line);
    if (plan->excl_appeared > 0) {
        render_excluded_line(report);
    }
}

/* One table cell's rendered length (the widths pass). */
static int64_t cell_len(const tc_reported_row *row, int metric) {
    cell_render(row, metric, s_cell, sizeof(s_cell));
    return (int64_t)strlen(s_cell);
}

/* The "+ N others" row's cells widen the column widths (Python includes the
   pooled row in column_widths). */
static void others_widths(tc_report *report, int64_t *widths) {
    tc_plan *plan = &report->plan;
    int64_t pooled_live = 0;
    int64_t pooled_offline = 0;
    int64_t pooled_unknown = 0;
    int64_t i;
    char *cc;

    cc = s_cell;
    *cc++ = '+';
    *cc++ = ' ';
    cc = render_fmt_u64_commas(cc, (uint64_t)plan->hidden_n);
    cc = tc_cat_cstr(cc, " others");
    if ((int64_t)strlen(s_cell) > widths[0]) {
        widths[0] = (int64_t)strlen(s_cell);
    }
    for (i = plan->displayed_n; i < plan->reported_n; i++) {
        pooled_live += plan->reported[i].live;
        pooled_offline += plan->reported[i].offline;
        pooled_unknown += plan->reported[i].unknown;
    }
    cc = render_fmt_u64_commas(s_cell, (uint64_t)plan->msgs_hidden);
    *cc = '\0';
    if ((int64_t)strlen(s_cell) > widths[1]) {
        widths[1] = (int64_t)strlen(s_cell);
    }
    for (i = 0; i < plan->col_count; i++) {
        int metric = plan->columns[i];
        int64_t len;
        switch (metric) {
        case TC_M_LIVE:
            cc = render_fmt_u64_commas(s_cell, (uint64_t)pooled_live);
            *cc = '\0';
            break;
        case TC_M_OFFLINE:
            cc = render_fmt_u64_commas(s_cell, (uint64_t)pooled_offline);
            *cc = '\0';
            break;
        case TC_M_UNKNOWN:
            cc = render_fmt_u64_commas(s_cell, (uint64_t)pooled_unknown);
            *cc = '\0';
            break;
        case TC_M_OFFLINE_SHARE:
            render_fmt_share_cell(s_cell, sizeof(s_cell), pooled_offline,
                                  plan->msgs_hidden);
            break;
        case TC_M_LIVE_SHARE:
            render_fmt_share_cell(s_cell, sizeof(s_cell), pooled_live,
                                  plan->msgs_hidden);
            break;
        default:
            s_cell[0] = '\0';
            break;
        }
        len = (int64_t)strlen(s_cell);
        if (len > widths[2 + i]) {
            widths[2 + i] = len;
        }
    }
}

static void render_table(tc_report *report) {
    tc_plan *plan = &report->plan;
    int64_t widths[TC_COLUMNS_MAX + 2];
    int64_t ncols = (int64_t)plan->col_count + 2;
    int64_t i;

    widths[0] = 4;                  /* "user" */
    widths[1] = 5;                  /* "count" */
    for (i = 0; i < plan->col_count; i++) {
        widths[2 + i] = (int64_t)strlen(tc_metrics[plan->columns[i]].header);
    }
    for (i = 0; i < plan->displayed_n; i++) {
        const tc_reported_row *row = &plan->reported[i];
        int64_t c;
        if ((int64_t)strlen(row->login) > widths[0]) {
            widths[0] = (int64_t)strlen(row->login);
        }
        for (c = 1; c < ncols; c++) {
            int metric = c == 1 ? TC_M_COUNT : plan->columns[c - 2];
            int64_t len = cell_len(row, metric);
            if (len > widths[c]) {
                widths[c] = len;
            }
        }
    }
    if (plan->hidden_n > 0) {
        others_widths(report, widths);
    }
    if (s_active_frame != NULL && s_active_frame->pin_width > 0) {
        widths[0] = s_active_frame->pin_width;   /* pinned, not merely capped */
    }

    render_table_header(plan, widths, ncols);
    render_rule(widths, ncols);
    for (i = 0; i < plan->displayed_n; i++) {
        render_table_row(report, &plan->reported[i], widths, ncols);
    }
    if (plan->hidden_n > 0) {
        render_others_row(report, widths, ncols);
    }
    render_rule(widths, ncols);
    render_footer(report);
}

int tc_render_text(tc_report *report) {
    tc_plan *plan = &report->plan;

    switch (plan->header_mode) {
    case TC_HDR_FULL:
        render_full_header(report);
        break;
    case TC_HDR_COMPACT:
        render_compact_header(report);
        break;
    default:
        break;
    }
    if (plan->reported_n == 0) {
        render_empty_report(report);
        return TC_EXIT_OK;
    }
    render_table(report);
    return TC_EXIT_OK;
}

// ----------------------------------------------------------------------------
// tc_render_report — plan, then emit JSON or text.
// ----------------------------------------------------------------------------
int tc_render_report(tc_report *report) {
    int status = tc_plan_presentation(report);
    if (status != TC_EXIT_OK) {
        return status;
    }
    if (report->args->flags & TC_F_JSON) {
        return tc_json_emit(report);
    }
    return tc_render_text(report);
}

// ----------------------------------------------------------------------------
// tc_report_fail — fail in the shape the caller was promised.
// ----------------------------------------------------------------------------
void tc_report_fail(const tc_report *report, const char *msg) {
    if (report != NULL && report->args != NULL
        && (report->args->flags & TC_F_JSON)) {
        tc_eputs("{\"error\": \"");
        for (; *msg != '\0'; msg++) {
            if (*msg == '"' || *msg == '\\') {
                tc_eputs("\\");
            }
            if (*msg == '\n') {
                tc_eputs("\\n");
                continue;
            }
            if (*msg == '\r') {
                tc_eputs("\\r");
                continue;
            }
            if (*msg == '\t') {
                tc_eputs("\\t");
                continue;
            }
            {
                char c[2];
                c[0] = *msg;
                c[1] = '\0';
                tc_eputs(c);
            }
        }
        tc_eputs("\"}\n");
        exit(TC_EXIT_ERROR);
    }
    tc_fail(msg);
}

// ----------------------------------------------------------------------------
// The frame-capture API (watch mode).  The caller owns the tc_frame and
// pre-fills lines/max before tc_frame_begin; the renderer tracks the active
// frame so tc_render_text can pin/tint/capture without a frame parameter.
// ----------------------------------------------------------------------------
void tc_frame_begin(tc_frame *frame) {
    frame->capture = 1;
    frame->count = 0;
    s_active_frame = frame;
}

void tc_frame_end(tc_frame *frame) {
    if (s_active_frame == frame) {
        s_active_frame = NULL;
    }
    frame->capture = 0;
}

void tc_frame_set_pin(tc_frame *frame, int width) {
    frame->pin_width = width;
}

void tc_frame_set_tint(tc_frame *frame, tc_tint_fn fn, void *ctx) {
    frame->tint_fn = fn;
    frame->tint_ctx = ctx;
}