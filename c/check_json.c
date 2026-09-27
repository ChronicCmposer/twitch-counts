// ============================================================================
// check_json.c — the tc-json-test driver for the JSON report emitter.
//
//   main(): tc_cli_parse -> tc_resolve_channel -> tc_count_run, then builds
//   the presentation plan and calls tc_json_emit.  render.c's
//   tc_plan_presentation is still a stub, so the driver fills tc_plan itself,
//   mirroring Python's plan_presentation + rank_users + choose_limit; json.c
//   reads only the tc_report bundle, so the emitter is exercised end to end
//   exactly as the real pipeline will drive it.
//
//   The harness runs the driver exactly like the oracle:  -c CHANNEL -d LOGS
//   -e END --json [flags] --no-config --no-cache, capturing stdout and
//   comparing it byte-for-byte against `python3 twitch-counts.py`.
//
//   Under --json, presentation errors (the state-filter x per-state-column
//   conflict) fail through tc_json_err: the {"error": ...} document on
//   stderr, exit 1 — the Python report_failure shape.
//
//   Exit: 0 = emitted; 1 = failure (JSON error document on stderr, or a
//   tc_fail path); 2 = CLI parse error; no --json means nothing to do (0).
// ============================================================================

#define _POSIX_C_SOURCE 200809L

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The state-filter x per-state-column refusal (Python plan_presentation). */
#define DRIVER_STATE_CONFLICT_FMT \
    "--%s counts one state only, so per-state columns and sorts would be " \
    "degenerate -- drop the state filter to compare states"

/* The provenance label for the unlimited cap under --json (Python
   choose_limit). */
#define DRIVER_UNLIMITED_SOURCE "unlimited for --json"

/* ---------------------------------------------------------------------------
 * Metric predicates (Python STATE_METRICS / METRICS[].kind == "share").
 * ------------------------------------------------------------------------- */

static int is_state_metric(int metric) {
    return metric == TC_M_LIVE || metric == TC_M_OFFLINE
        || metric == TC_M_UNKNOWN || metric == TC_M_OFFLINE_SHARE
        || metric == TC_M_LIVE_SHARE;
}

static int is_share_metric(int metric) {
    return metric == TC_M_OFFLINE_SHARE || metric == TC_M_LIVE_SHARE;
}

/* The sort metric for one row: the value Python's sort_rows compares,
   descending, ties broken by login. */
static double row_metric_value(const tc_reported_row *row, int sort) {
    switch (sort) {
    case TC_M_LIVE:
        return (double)row->live;
    case TC_M_OFFLINE:
        return (double)row->offline;
    case TC_M_UNKNOWN:
        return (double)row->unknown;
    case TC_M_OFFLINE_SHARE:
        return row->count > 0
            ? 100.0 * (double)row->offline / (double)row->count : 0.0;
    case TC_M_LIVE_SHARE:
        return row->count > 0
            ? 100.0 * (double)row->live / (double)row->count : 0.0;
    default:
        return (double)row->count;
    }
}

/* The resolved listing the counting pass used (core.c exposes it; check_core.c
   declares the same symbol for its dump). */
extern tc_listing tc_core_listing;

/* ---------------------------------------------------------------------------
 * Sorting helpers.
 * ------------------------------------------------------------------------- */

static int cmp_str(const void *a, const void *b) {
    const char *const *left = (const char *const *)a;
    const char *const *right = (const char *const *)b;
    return strcmp(*left, *right);
}

/* One threshold-passing row, with the metric Python orders by.  For a login
   sort the metric is unused (all zeros), so the comparator's login tie-break
   alone decides — Python's sorted(key=login). */
typedef struct {
    tc_reported_row row;
    double metric;
} json_candidate;

static int cmp_candidate(const void *a, const void *b) {
    const json_candidate *left = (const json_candidate *)a;
    const json_candidate *right = (const json_candidate *)b;
    if (left->metric > right->metric) {
        return -1;
    }
    if (left->metric < right->metric) {
        return 1;
    }
    return strcmp(left->row.login, right->row.login);
}

/* ---------------------------------------------------------------------------
 * The presentation plan (Python plan_presentation, minus the header rows the
 * text renderer alone consumes).
 * ------------------------------------------------------------------------- */

/* The sorted exclusion set, as Python's sorted(selection.excluded). */
static const char **build_sorted_excl_names(const tc_excl_set *exclusions,
                                            int64_t *count_out) {
    const char **names;
    int64_t n = exclusions->count;
    int64_t i;
    names = malloc(n > 0 ? (size_t)n * sizeof(*names) : 1);
    if (names == NULL) {
        tc_fail("out of memory");
    }
    for (i = 0; i < n; i++) {
        names[i] = strdup(exclusions->entries[i].login);
        if (names[i] == NULL) {
            tc_fail("out of memory");
        }
    }
    qsort(names, (size_t)n, sizeof(*names), cmp_str);
    *count_out = n;
    return names;
}

/* The ", "-joined exclusion sources (Python ", ".join(exclude_sources)),
   or NULL when nothing was excluded. */
static char *join_exclusion_sources(const tc_excl_set *exclusions) {
    size_t total = 0;
    int n = 0;
    int i;
    char *joined;
    char *p;
    for (i = 0; i < TC_EX_MAX && exclusions->sources[i].ptr != NULL; i++) {
        total += (size_t)exclusions->sources[i].len;
        n++;
    }
    if (n == 0) {
        return NULL;
    }
    total += (size_t)(n - 1) * 2 + 1;   /* ", " separators + NUL */
    joined = malloc(total);
    if (joined == NULL) {
        tc_fail("out of memory");
    }
    p = joined;
    for (i = 0; i < n; i++) {
        if (i > 0) {
            *p++ = ',';
            *p++ = ' ';
        }
        memcpy(p, exclusions->sources[i].ptr,
               (size_t)exclusions->sources[i].len);
        p += exclusions->sources[i].len;
    }
    *p = '\0';
    return joined;
}

static void build_plan(tc_report *report, const tc_tally *tally) {
    tc_plan *plan = &report->plan;
    const tc_opts *opts = report->args;
    const tc_window *window = &report->context->window;
    const tc_excl_set *exclusions = &report->context->exclusions;
    const tc_users *users = tally->users;
    int filter = window->state_filter;
    int sort = opts->sort;
    int login_sort = (sort == TC_M_LOGIN);
    int64_t threshold = window->threshold;
    int shares_shown;
    int64_t floor;
    int64_t candidate_n = 0;
    int64_t kept_n;
    int64_t i;
    json_candidate *candidates;

    /* The degenerate-filter refusal (Python plan_presentation): a state
       filter with per-state columns or sorts is meaningless, so it fails
       loudly in the JSON error shape. */
    if (filter != TC_ST_NONE) {
        int conflict = is_state_metric(sort);
        for (i = 0; i < opts->column_count && !conflict; i++) {
            conflict = is_state_metric(opts->columns[i]);
        }
        if (conflict) {
            char msg[192];
            snprintf(msg, sizeof(msg), DRIVER_STATE_CONFLICT_FMT,
                     tc_state_str(filter));
            tc_json_err(msg);
        }
    }

    candidates = malloc(users->count > 0
                        ? (size_t)users->count * sizeof(*candidates) : 1);
    if (candidates == NULL) {
        tc_fail("out of memory");
    }

    plan->in_range = 0;
    plan->excl_appeared = 0;
    plan->excl_msgs = 0;

    for (i = 0; i < users->count; i++) {
        const tc_user_entry *entry = &users->entries[i];
        json_candidate *candidate = &candidates[candidate_n];
        size_t login_len = strlen(entry->login);
        int excluded = tc_excl_contains(exclusions, entry->login, login_len);

        tc_copy_str_cap(candidate->row.login, entry->login,
                        sizeof(candidate->row.login));

        /* The per-state split the report carries: under a state filter only
           the filtered state's messages count (Python's states_by_login). */
        candidate->row.live = entry->live;
        candidate->row.offline = entry->offline;
        candidate->row.unknown = entry->unknown;
        if (filter == TC_ST_LIVE) {
            candidate->row.offline = 0;
            candidate->row.unknown = 0;
        } else if (filter == TC_ST_OFFLINE) {
            candidate->row.live = 0;
            candidate->row.unknown = 0;
        } else if (filter == TC_ST_UNKNOWN) {
            candidate->row.live = 0;
            candidate->row.offline = 0;
        }
        candidate->row.count = candidate->row.live + candidate->row.offline
                             + candidate->row.unknown;

        if (excluded) {
            if (candidate->row.count > 0) {
                plan->excl_appeared++;
                plan->excl_msgs += candidate->row.count;
            }
            continue;
        }
        if (candidate->row.count > 0) {
            plan->in_range++;
        }
        if (candidate->row.count >= threshold) {
            candidate->metric = login_sort ? 0.0
                                           : row_metric_value(&candidate->row,
                                                              sort);
            candidate_n++;
        }
    }

    /* The share floor (Python rank_users): applied only when a share is
       shown or sorted by and a floor was requested. */
    shares_shown = is_share_metric(sort);
    for (i = 0; i < opts->column_count && !shares_shown; i++) {
        shares_shown = is_share_metric(opts->columns[i]);
    }
    plan->shares_shown = shares_shown;
    plan->below_floor = 0;
    plan->share_floor = 0;
    floor = opts->share_floor;
    if (shares_shown && floor > 0) {
        kept_n = 0;
        for (i = 0; i < candidate_n; i++) {
            if (candidates[i].row.count >= floor) {
                candidates[kept_n++] = candidates[i];
            }
        }
        plan->below_floor = candidate_n - kept_n;
        plan->share_floor = floor;
        candidate_n = kept_n;
    }

    qsort(candidates, (size_t)candidate_n, sizeof(*candidates),
          cmp_candidate);

    plan->reported = malloc(candidate_n > 0
                            ? (size_t)candidate_n * sizeof(tc_reported_row)
                            : 1);
    if (plan->reported == NULL) {
        tc_fail("out of memory");
    }
    for (i = 0; i < candidate_n; i++) {
        plan->reported[i] = candidates[i].row;
    }
    plan->reported_n = candidate_n;

    /* The row cap (Python choose_limit): an explicit --top, an explicit
       "-n 0" (unlimited, source kept), or the --json default. */
    if (opts->top > 0) {
        plan->limit = opts->top;
        plan->limit_source = tc_source_str(opts->src[TC_SET_TOP]);
    } else if (opts->src[TC_SET_TOP] == TC_SRC_CLI_TOP) {
        plan->limit = 0;
        plan->limit_source = "--top";
    } else {
        plan->limit = 0;
        plan->limit_source = DRIVER_UNLIMITED_SOURCE;
    }
    if (plan->limit > 0 && plan->limit < plan->reported_n) {
        plan->displayed_n = plan->limit;
    } else {
        plan->displayed_n = plan->reported_n;
    }
    plan->hidden_n = plan->reported_n - plan->displayed_n;

    plan->msgs_shown = 0;
    for (i = 0; i < plan->displayed_n; i++) {
        plan->msgs_shown += plan->reported[i].count;
    }
    plan->msgs_hidden = 0;
    for (i = plan->displayed_n; i < plan->reported_n; i++) {
        plan->msgs_hidden += plan->reported[i].count;
    }

    /* The rest of the plan the JSON emitter reads. */
    plan->sort = sort;
    plan->col_count = opts->column_count;
    for (i = 0; i < opts->column_count && i < TC_COLUMNS_MAX; i++) {
        plan->columns[i] = opts->columns[i];
    }
    plan->header_mode = opts->header_mode;
    plan->excl_names = build_sorted_excl_names(exclusions,
                                               &plan->excl_names_n);
    plan->src_join = join_exclusion_sources(exclusions);

    /* The JSON harness pins --no-cache, so the cache never served this
       driver's query: used=false, days_reused=0, problem=null. */
    plan->cache_used = 0;
    plan->cache_reused = tally->reused;
    plan->cache_parsed = tally->parsed;
    plan->cache_problem = NULL;

    free(candidates);
}

/* ---------------------------------------------------------------------------
 * main()
 * ------------------------------------------------------------------------- */

int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    tc_context context;
    tc_selection selection;
    tc_users users;
    tc_tally tally;
    tc_report report;
    char channel_dir[TC_PATH_SZ];
    char channel_name[TC_CHANNEL_SZ];
    int status;

    memset(&opts, 0, sizeof(opts));
    memset(&window, 0, sizeof(window));
    memset(&context, 0, sizeof(context));
    memset(&selection, 0, sizeof(selection));
    memset(&users, 0, sizeof(users));
    memset(&tally, 0, sizeof(tally));
    tally.users = &users;

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;
    }
    if (!(opts.flags & TC_F_JSON)) {
        return 0;   /* this driver exists to exercise the JSON emitter */
    }

    status = tc_resolve_channel(&opts, channel_dir, sizeof(channel_dir),
                                channel_name, sizeof(channel_name));
    if (status != TC_EXIT_OK) {
        return status;
    }

    status = tc_count_run(&opts, &window, &tally);
    if (status != TC_EXIT_OK) {
        return status;
    }

    /* The resolved context (Python Context). */
    context.settings = &opts;
    context.config_loaded = opts.config_loaded;
    tc_copy_str_cap(context.channel_dir, channel_dir,
                    sizeof(context.channel_dir));
    tc_copy_str_cap(context.channel_name, channel_name,
                    sizeof(context.channel_name));
    context.window = window;
    status = tc_build_exclusions(&opts, &context.exclusions);
    if (status != TC_EXIT_OK) {
        return status;
    }

    /* The counting results (Python Selection). */
    selection.users = &users;
    selection.total_messages = tally.messages;
    selection.files = tally.files;
    selection.parsed = tally.parsed;
    selection.reused = tally.reused;
    selection.states[0] = tally.states[0];
    selection.states[1] = tally.states[1];
    selection.states[2] = tally.states[2];
    selection.exclusions = &context.exclusions;
    selection.cache = NULL;
    selection.cache_problem = NULL;
    selection.unreadable_count = tally.unreadable_count;
    memcpy(selection.unreadable, tally.unreadable,
           (size_t)tally.unreadable_count * sizeof(tc_unreadable_entry));

    report.args = &opts;
    report.context = &context;
    report.selection = &selection;

    build_plan(&report, &tally);
    selection.excluded_counts = report.plan.excl_msgs;

    status = tc_json_emit(&report);

    free(users.entries);
    free(report.plan.reported);
    free(report.plan.excl_names);
    free((void *)report.plan.src_join);
    free(tc_core_listing.entries);
    return status;
}