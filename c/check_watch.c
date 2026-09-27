// ============================================================================
// check_watch.c — the test driver for watch mode (tc-watch-test).
//   main(): tc_cli_parse -> aliases/channel/exclusions (the tc_inputs half of
//   a redraw) -> tc_watch_run -> exit with its status.
//
//   The harness (test-tc-watch.sh) drives this binary through a pty and diffs
//   the ANSI-stripped first frame against python3 twitch-counts.py, checks the
//   SIGINT exit code, cursor restore and appended-line redraws, plus the
//   non-tty / --json conflict errors (both of which the CLI layer already
//   produces, so this driver just propagates them).
//
//   Division of labour with watch.c:
//     * this driver resolves everything a redraw cannot change (the Python
//       resolve_inputs): the settings live in tc_opts (tc_cli_parse), the
//       channel dir/name, the exclusion set and the window-start kind.
//     * tc_watch_run owns everything that can change: the watch/tail knobs it
//       resolves from env/config itself (like Python's resolve_watch /
//       resolve_tail — the CLI resolves only interval and hold), the rolling
//       window, the tail readers, the launch replay, the tint fade and the
//       repaint loop.
//
//   cli.c resolves the window (begin/end as ymd+sod) but deliberately keeps
//   the raw --begin/--since/--end texts in its own parse state, leaving the
//   tc_opts.raw buffers empty — so this driver transports the resolved values
//   back into those buffers (a --since window as its fixed delta in seconds,
//   a fixed begin/end as a parseable datetime).  watch.c then re-derives the
//   per-frame window from opts exactly as Python's resolve_context does.
//
//   Exits 0 on success (a SIGINT'd watch session returns 0, exactly like the
//   Python run_watch's `except KeyboardInterrupt: pass`); parse errors 2,
//   resolution/runtime errors 1.
// ============================================================================

#include "tc_platform.h"

#include <stdio.h>
#include <string.h>

/* Format the resolved window start back into a buffer watch.c can re-parse
   (Python's resolve_context derives begin from the raw settings each frame). */
static void driver_fmt_datetime(char *dst, size_t cap, int64_t ymd,
                                int64_t sod) {
    int y, mo, d, h, mi, s;
    tc_ymd_split(ymd, &y, &mo, &d);
    tc_sod_split(sod, &h, &mi, &s);
    snprintf(dst, cap, "%04d-%02d-%02d %02d:%02d:%02d", y, mo, d, h, mi, s);
}

int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    tc_inputs inputs;
    int status;

    memset(&opts, 0, sizeof(opts));
    memset(&window, 0, sizeof(window));
    memset(&inputs, 0, sizeof(inputs));

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;
    }

    /* cli.c resolves --exclude-broadcaster's value but not its provenance
       (config.c labels the broadcaster exclusion layer from that slot); fill
       it here so the exclude row's source tag is non-empty. */
    if (opts.excl_bcast_val != 0
        && opts.src[TC_SET_EXCLUDE_BCAST] == TC_SRC_NONE) {
        opts.src[TC_SET_EXCLUDE_BCAST] = TC_SRC_CLI_EXCLUDE_BCAST;
    }

    /* Transport the resolved window into the raw buffers watch.c re-derives
       from (cli.c keeps the raw texts in its own parse state). */
    if (window.kind == TC_WIN_SINCE) {
        int64_t end_epoch = tc_ymd_sod_to_epoch(window.end_ymd,
                                                window.end_sod);
        int64_t begin_epoch = tc_ymd_sod_to_epoch(window.begin_ymd,
                                                  window.begin_sod);
        snprintf(opts.since_raw, sizeof(opts.since_raw), "%llds",
                 (long long)(end_epoch - begin_epoch));
    } else if (window.kind == TC_WIN_BEGIN) {
        driver_fmt_datetime(opts.begin_raw, sizeof(opts.begin_raw),
                            window.begin_ymd, window.begin_sod);
    }
    if (opts.src[TC_SET_END] != TC_SRC_DEFAULT_NOW) {
        driver_fmt_datetime(opts.end_raw, sizeof(opts.end_raw),
                            window.end_ymd, window.end_sod);
    }

    /* The immutable half of a watch context (Python build_inputs).  Aliases
       run before the channel is resolved so the alias rewrites the name;
       tc_build_exclusions loads the config (tc_aliases_apply registers the
       session options), so config_path/config_loaded are final afterwards. */
    tc_aliases_apply(&opts);

    inputs.settings = &opts;
    inputs.config_loaded = opts.config_loaded;
    tc_copy_str_cap(inputs.config_path, opts.config_path,
                    sizeof(inputs.config_path));
    inputs.kind = window.kind;
    inputs.start_setting = (window.kind == TC_WIN_BEGIN) ? TC_SET_BEGIN
                         : (window.kind == TC_WIN_SINCE) ? TC_SET_SINCE : 0;

    status = tc_resolve_channel(&opts, inputs.channel_dir,
                                sizeof(inputs.channel_dir),
                                inputs.channel_name,
                                sizeof(inputs.channel_name));
    if (status != TC_EXIT_OK) {
        return status;
    }

    status = tc_build_exclusions(&opts, &inputs.exclusions);
    if (status != TC_EXIT_OK) {
        return status;
    }
    inputs.config_loaded = opts.config_loaded;
    tc_copy_str_cap(inputs.config_path, opts.config_path,
                    sizeof(inputs.config_path));

    return tc_watch_run(&opts, &inputs);
}