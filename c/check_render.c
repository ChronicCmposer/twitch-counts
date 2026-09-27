// ============================================================================
// check_render.c — the test driver for the renderer.
//   main(): tc_cli_parse -> resolve the channel -> build the report shell
//   (context + selection) -> tc_count_run -> tc_render_report -> exit 0.
//
//   The renderer chooses text or JSON from the --json flag itself.  The
//   harness (test-tc-render.sh) diffs the driver byte-for-byte against
//   python3 twitch-counts.py across the flag matrix, plus the structural
//   checks (JSON validity, the JSON error path, piped/unlimited rows), so
//   this driver must reproduce the Python's report pipeline exactly:
//
//     resolve_context + size_window + select_rows + plan_presentation
//
//   mapped onto the C modules:
//
//     * tc_cli_parse          the layered settings + window resolution
//     * tc_resolve_channel    the channel dir/name the context reports
//     * tc_count_run          the counting pass (its own cache lifecycle)
//     * tc_render_report      plan, then text or JSON
//
//   The context's exclusion set is a second build of the same deterministic
//   set tc_count_run uses internally; the count already applied it, and the
//   header reads the driver's copy for the exclude row.  Under the harness
//   every run passes --no-config --no-cache, so config_loaded stays 0 and
//   selection.cache stays NULL (exactly Python's --no-cache: no config row,
//   no cache row).
//
//   Exits 0 on success; parse errors 2, resolution/runtime errors 1 — the
//   same codes as python3 twitch-counts.py.
// ============================================================================

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    tc_users users;
    tc_tally tally;
    tc_context context;
    tc_selection selection;
    tc_report report;
    int status;

    memset(&opts, 0, sizeof(opts));
    memset(&window, 0, sizeof(window));
    memset(&users, 0, sizeof(users));
    memset(&tally, 0, sizeof(tally));
    memset(&context, 0, sizeof(context));
    memset(&selection, 0, sizeof(selection));
    memset(&report, 0, sizeof(report));

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;
    }

    /* Resolve the channel for the context; tc_count_run re-resolves it
       (idempotent).  Failure exits 1 with the exact Python error text. */
    status = tc_resolve_channel(&opts, context.channel_dir,
                                sizeof(context.channel_dir),
                                context.channel_name,
                                sizeof(context.channel_name));
    if (status != TC_EXIT_OK) {
        return status;
    }

    /* The counting pass completes the window in place (earliest begin, the
       --users sizing) — the context must see the completed window. */
    tally.users = &users;
    status = tc_count_run(&opts, &window, &tally);
    if (status != TC_EXIT_OK) {
        free(users.entries);
        return status;
    }

    /* Context: the resolved settings, the completed window, the exclusions. */
    context.settings = &opts;
    context.window = window;
    context.config_loaded = opts.config_loaded;
    tc_copy_str_cap(context.config_path, opts.config_path,
                    sizeof(context.config_path));
    status = tc_build_exclusions(&opts, &context.exclusions);
    if (status != TC_EXIT_OK) {
        free(users.entries);
        return status;
    }

    /* Selection: the count results in the Python shapes the plan reads. */
    selection.users = &users;
    selection.total_messages = tally.messages;
    selection.files = tally.files;
    selection.parsed = tally.parsed;
    selection.reused = tally.reused;
    selection.states[0] = tally.states[0];
    selection.states[1] = tally.states[1];
    selection.states[2] = tally.states[2];
    selection.excluded_counts = tally.excluded_states[0]
                              + tally.excluded_states[1]
                              + tally.excluded_states[2];
    selection.exclusions = &context.exclusions;
    selection.cache = NULL;             /* count_run owns its cache handle */
    selection.cache_problem = NULL;
    selection.unreadable_count = tally.unreadable_count;
    if (tally.unreadable_count > 0) {
        memcpy(selection.unreadable, tally.unreadable,
               (size_t)tally.unreadable_count * sizeof(tc_unreadable_entry));
    }

    report.args = &opts;
    report.context = &context;
    report.selection = &selection;

    status = tc_render_report(&report);

    free(users.entries);
    return status;
}