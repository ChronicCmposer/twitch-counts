// ============================================================================
// main.c — the entry point / orchestrator.
//
//  main() owns the session state (tc_opts/tc_window) on its stack and threads
//  pointers through the phases — no hidden globals.  Dispatch order and exit
//  codes mirror twitch-counts.py main() exactly:
//
//    1. tc_cli_parse: argparse-equivalent parse + resolution.  Parse errors
//       exit 2, resolution errors exit 1, --help prints and exits 0.  Nothing
//       here runs until the CLI has either succeeded or exited on its own.
//    2. TC_F_MANUAL         -> tc_misc_manual()          -> return 0
//    3. TC_F_EMIT_FISH      -> tc_misc_fish()            -> return 0
//    4. TC_F_COMPLETE_GIVEN -> tc_misc_complete(&opts)   -> return 0
//    5. TC_F_WATCH_PRESENT  -> build the tc_inputs half (aliases/channel/
//                              exclusions) and tc_watch_run.  watch.c owns the
//                              session: its own rollup connection and its own
//                              SIGINT loop handler (SIGINT under watch latches
//                              and returns 0, cursor restored).
//    6. otherwise (one-shot): resolve the context, run the counting pass,
//       build the report bundle, and tc_render_report (plan, then text or
//       --json).  The rollup cache is opened before the pass (the lease) and
//       closed however the path ends; the counting pass itself opens its own
//       connection (its frozen signature owns it), while this handle feeds
//       the renderer's cache row.
//
//  SIGINT (Python's except KeyboardInterrupt): the one-shot path installs a
//  handler before the run.  Text mode exits 130 quietly — the shell has
//  already echoed ^C — while --json still gets the shape it was promised:
//  {"error": "interrupted"} on stderr, exit 130.  The previous disposition is
//  restored when the run completes.  The watch path installs nothing: tc_watch
//  owns its own loop handler and the watch harness asserts SIGINT -> 0.
//
//  Errors: parse errors 2, resolution/runtime errors 1, SIGINT 130.  Under
//  --json the modules emit the {"error": ...} document on stderr themselves
//  (core_fail / tc_report_fail / tc_json_err), exactly like report_failure.
// ============================================================================

/* sigaction / write / _exit are POSIX; expose them under -std=c99. */
#define _POSIX_C_SOURCE 200809L

#include "tc_platform.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

/* cli.c records the merged-columns provenance (the "--by-state, --show"
   combination) in a LOCAL scratch buffer and stores its address in
   opts.columns_src_ptr; that pointer dangles the moment tc_cli_parse returns,
   and later code in the same function has already reused the slot.  Rebuild
   the combined source deterministically into the tc_opts columns_src_buf (the
   intended home): -B names the by-state prefix, and --show is present when a
   column sits beyond the three-column by-state prefix (cli.c leaves no flag
   for --show, so the merged columns are the only reliable signal).  The other
   shapes ("--by-state", "--show") are string literals and are safe to copy. */
static void main_stabilize_columns_src(tc_opts *opts) {
    char *cur;
    size_t left;
    int i;

    if (!(opts->flags & TC_F_BY_STATE)) {
        if (opts->columns_src_ptr != NULL) {
            tc_copy_str_cap(opts->columns_src_buf, opts->columns_src_ptr,
                            sizeof(opts->columns_src_buf));
            opts->columns_src_ptr = opts->columns_src_buf;
        }
        return;
    }

    cur = opts->columns_src_buf;
    left = sizeof(opts->columns_src_buf);
    cur = tc_cat_cstr_cap(cur, "--by-state", left);
    left -= (size_t)(cur - opts->columns_src_buf);
    for (i = 0; i < opts->column_count; i++) {
        if (i >= 3) {
            cur = tc_cat_cstr_cap(cur, ", --show", left);
            break;
        }
    }
    opts->columns_src_ptr = opts->columns_src_buf;
}

/* The SIGINT handler reads this: whether the interrupted one-shot must emit
   the JSON error document (async-signal-safe: a plain int load). */
static volatile sig_atomic_t s_main_json_mode;

// ----------------------------------------------------------------------------
// SIGINT — Ctrl-C is a request, not a crash.
// ----------------------------------------------------------------------------
static void main_sigint_handler(int sig) {
    static const char s_interrupted[] = "{\"error\": \"interrupted\"}\n";
    ssize_t ignored;
    (void)sig;
    if (s_main_json_mode) {
        /* the exact shape Python's report_failure produces for
           KeyboardInterrupt under --json (announce=False, code=130) */
        ignored = write(STDERR_FILENO, s_interrupted,
                        sizeof(s_interrupted) - 1);
        (void)ignored;
    }
    _exit(TC_EXIT_INTERRUPT);
}

/* Install the one-shot handler, saving the previous disposition. */
static void main_sigint_install(int json_mode, struct sigaction *previous) {
    struct sigaction sa;
    s_main_json_mode = json_mode;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = main_sigint_handler;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGINT, &sa, previous);
}

/* Restore the disposition the run found (the handler is only for the pass). */
static void main_sigint_restore(const struct sigaction *previous) {
    sigaction(SIGINT, previous, NULL);
}

// ----------------------------------------------------------------------------
// Watch-path helpers (mirror check_watch.c: cli.c keeps the raw window texts
// in its own parse state, so the resolved window is transported back into the
// tc_opts buffers watch.c re-derives the per-frame window from).
// ----------------------------------------------------------------------------

/* Format the resolved window start back into a buffer watch.c can re-parse. */
static void main_fmt_datetime(char *dst, size_t cap, int64_t ymd,
                              int64_t sod) {
    int y, mo, d, h, mi, s;
    tc_ymd_split(ymd, &y, &mo, &d);
    tc_sod_split(sod, &h, &mi, &s);
    snprintf(dst, cap, "%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s);
}

/* cli.c resolves --exclude-broadcaster's value but not its provenance
   (config.c labels the broadcaster exclusion layer from that slot); fill it
   so the exclude row's source tag is non-empty. */
static void main_fill_bcast_source(tc_opts *opts) {
    if (opts->excl_bcast_val != 0
        && opts->src[TC_SET_EXCLUDE_BCAST] == TC_SRC_NONE) {
        opts->src[TC_SET_EXCLUDE_BCAST] = TC_SRC_CLI_EXCLUDE_BCAST;
    }
}

/* Transport the resolved window into the raw buffers watch.c re-derives from
   (a --since window as its fixed delta in seconds, a fixed begin/end as
   parseable datetimes). */
static void main_transport_window(tc_opts *opts, const tc_window *window) {
    if (window->kind == TC_WIN_SINCE) {
        int64_t end_epoch = tc_ymd_sod_to_epoch(window->end_ymd,
                                                window->end_sod);
        int64_t begin_epoch = tc_ymd_sod_to_epoch(window->begin_ymd,
                                                  window->begin_sod);
        snprintf(opts->since_raw, sizeof(opts->since_raw), "%llds",
                 (long long)(end_epoch - begin_epoch));
    } else if (window->kind == TC_WIN_BEGIN) {
        main_fmt_datetime(opts->begin_raw, sizeof(opts->begin_raw),
                          window->begin_ymd, window->begin_sod);
    }
    if (opts->src[TC_SET_END] != TC_SRC_DEFAULT_NOW) {
        main_fmt_datetime(opts->end_raw, sizeof(opts->end_raw),
                          window->end_ymd, window->end_sod);
    }
}

// ----------------------------------------------------------------------------
// The watch path (Python main() -> run_watch).
// ----------------------------------------------------------------------------
static int main_watch_run(tc_opts *opts, tc_window *window) {
    tc_inputs inputs;
    int status;

    memset(&inputs, 0, sizeof(inputs));

    main_fill_bcast_source(opts);
    main_transport_window(opts, window);

    /* The immutable half of a watch context (Python build_inputs).  Aliases
       run before the channel is resolved so the alias rewrites the name;
       tc_build_exclusions loads the config (tc_aliases_apply registers the
       session options), so config_path/config_loaded are final afterwards. */
    tc_aliases_apply(opts);

    inputs.settings = opts;
    inputs.config_loaded = opts->config_loaded;
    tc_copy_str_cap(inputs.config_path, opts->config_path,
                    sizeof(inputs.config_path));
    inputs.kind = window->kind;
    inputs.start_setting = (window->kind == TC_WIN_BEGIN) ? TC_SET_BEGIN
                         : (window->kind == TC_WIN_SINCE) ? TC_SET_SINCE : 0;

    status = tc_resolve_channel(opts, inputs.channel_dir,
                                sizeof(inputs.channel_dir),
                                inputs.channel_name,
                                sizeof(inputs.channel_name));
    if (status != TC_EXIT_OK) {
        return status;
    }

    status = tc_build_exclusions(opts, &inputs.exclusions);
    if (status != TC_EXIT_OK) {
        return status;
    }
    inputs.config_loaded = opts->config_loaded;
    tc_copy_str_cap(inputs.config_path, opts->config_path,
                    sizeof(inputs.config_path));

    /* watch.c owns the session: its own rollup connection and its own SIGINT
       loop handler (a SIGINT'd watch returns 0, cursor restored). */
    return tc_watch_run(opts, &inputs);
}

// ----------------------------------------------------------------------------
// The one-shot path (Python main() -> run_report -> build_report_data).
// ----------------------------------------------------------------------------
static int main_run_report(tc_opts *opts, tc_window *window) {
    tc_users users;
    tc_tally tally;
    tc_context context;
    tc_selection selection;
    tc_report report;
    tc_cache *cache = NULL;
    const char *cache_problem = NULL;
    char cache_path[TC_PATH_SZ];
    struct sigaction previous_sigint;
    int status;

    memset(&users, 0, sizeof(users));
    memset(&tally, 0, sizeof(tally));
    memset(&context, 0, sizeof(context));
    memset(&selection, 0, sizeof(selection));
    memset(&report, 0, sizeof(report));
    tally.users = &users;

    /* Ctrl-C is a request: catch it for the whole one-shot run (Python's try
       wraps run_report), so text mode exits 130 quietly and --json still gets
       the error document it was promised. */
    main_sigint_install((opts->flags & TC_F_JSON) != 0, &previous_sigint);

    /* Aliases first, so the alias rewrites the channel before it resolves;
       this also registers the session opts with the config layer. */
    tc_aliases_apply(opts);

    /* Resolve the channel into the context; tc_count_run re-resolves it
       (idempotent).  Failure exits 1 with the exact Python error text. */
    status = tc_resolve_channel(opts, context.channel_dir,
                                sizeof(context.channel_dir),
                                context.channel_name,
                                sizeof(context.channel_name));
    if (status != TC_EXIT_OK) {
        goto done;
    }

    /* The cache lease (Python's CacheLease): open before the pass so the
       rebuilt reason describes this run, keep the handle for the renderer's
       cache row, close however the path ends.  The counting pass opens its
       own connection (its frozen signature owns it); a cache that reports a
       problem is handed to the renderer as absent-with-problem, which is the
       "unavailable -- <step>" row. */
    if (!(opts->flags & TC_F_NO_CACHE)) {
        if (tc_default_cache_path(cache_path, sizeof(cache_path)) > 0) {
            tc_cache_open(cache_path,
                          (opts->flags & TC_F_REBUILD_CACHE) ? 1 : 0,
                          context.channel_name, &cache, &cache_problem);
            if (cache_problem != NULL) {
                tc_cache_close(cache);
                cache = NULL;
            }
        }
    }

    /* The counting pass completes the window in place (earliest begin, the
       --users sizing) — the context must see the completed window. */
    status = tc_count_run(opts, window, &tally);
    if (status != TC_EXIT_OK) {
        goto done;
    }

    /* Context: the resolved settings, the completed window, the exclusions. */
    context.settings = opts;
    context.window = *window;
    context.config_loaded = opts->config_loaded;
    tc_copy_str_cap(context.config_path, opts->config_path,
                    sizeof(context.config_path));
    status = tc_build_exclusions(opts, &context.exclusions);
    if (status != TC_EXIT_OK) {
        goto done;
    }

    /* Selection: the count results in the Python shapes the plan reads.
       Python's select_rows subtracts the excluded logins' part from the
       states ONLY when the FILTERED excluded counts are non-empty (the gate
       is `if excluded_counts`); the C core always subtracts, so restore the
       pre-subtraction split when the state filter hid every excluded message
       — exactly the --offline/--unknown case where the bots never spoke in
       the filtered state. */
    selection.users = &users;
    selection.total_messages = tally.messages;
    selection.files = tally.files;
    selection.parsed = tally.parsed;
    selection.reused = tally.reused;
    {
        int64_t excluded_filtered = 0;
        int s;
        switch (window->state_filter) {
        case TC_ST_LIVE:
            excluded_filtered = tally.excluded_states[0];
            break;
        case TC_ST_OFFLINE:
            excluded_filtered = tally.excluded_states[1];
            break;
        case TC_ST_UNKNOWN:
            excluded_filtered = tally.excluded_states[2];
            break;
        default:
            excluded_filtered = tally.excluded_states[0]
                              + tally.excluded_states[1]
                              + tally.excluded_states[2];
            break;
        }
        selection.excluded_counts = excluded_filtered;
        for (s = 0; s < 3; s++) {
            selection.states[s] = excluded_filtered > 0
                ? tally.states[s]
                : tally.states[s] + tally.excluded_states[s];
        }
    }
    selection.exclusions = &context.exclusions;
    selection.cache = cache;
    selection.cache_problem = cache_problem;
    selection.unreadable_count = tally.unreadable_count;
    if (tally.unreadable_count > 0) {
        memcpy(selection.unreadable, tally.unreadable,
               (size_t)tally.unreadable_count * sizeof(tc_unreadable_entry));
    }

    report.args = opts;
    report.context = &context;
    report.selection = &selection;

    /* plan, then text or JSON (the renderer reads the --json flag itself). */
    status = tc_render_report(&report);

done:
    tc_cache_close(cache);
    free(users.entries);
    main_sigint_restore(&previous_sigint);
    return status;
}

// ----------------------------------------------------------------------------
// main — the real orchestrator (see the header for the dispatch order).
// ----------------------------------------------------------------------------
int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    int status;

    memset(&opts, 0, sizeof(opts));
    memset(&window, 0, sizeof(window));

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;          /* parse/resolution errors exit 2/1 itself */
    }

    /* Repair the columns-provenance pointer before any call can reuse the
       stack it points into (see main_stabilize_columns_src). */
    main_stabilize_columns_src(&opts);

    /* Python main() dispatch order: manual -> fish -> complete -> watch. */
    if (opts.flags & TC_F_MANUAL) {
        return tc_misc_manual();
    }
    if (opts.flags & TC_F_EMIT_FISH) {
        return tc_misc_fish();
    }
    if (opts.flags & TC_F_COMPLETE_GIVEN) {
        return tc_misc_complete(&opts);
    }
    if (opts.flags & TC_F_WATCH_PRESENT) {
        return main_watch_run(&opts, &window);
    }
    return main_run_report(&opts, &window);
}