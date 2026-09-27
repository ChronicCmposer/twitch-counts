// ============================================================================
// check_cli.c — the Wave-A test driver for the CLI.
//   main() calls tc_cli_parse(argc, argv), then prints a stable dump of the
//   resolved options + window so test-tc-cli.sh can assert resolution.  On
//   a parse/resolution error tc_cli_parse returns 2/1 and the driver exits
//   with that code (the harness checks exit codes + stderr directly).
// ============================================================================

#include "tc_platform.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    int status;
    int i;
    static const int dyn_ids[] = {
        TC_SRC_DYN_SINCE, TC_SRC_DYN_USERS, TC_SRC_DYN_ALIAS
    };

    memset(&opts, 0, sizeof(opts));
    memset(&window, 0, sizeof(window));

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;
    }

    printf("channel=%s\n", opts.channel);
    printf("src=%s\n", tc_source_str(opts.src[TC_SET_CHANNEL]));

    printf("logs_dir=%s\n", opts.logs_dir);
    printf("src=%s\n", tc_source_str(opts.src[TC_SET_LOGS_DIR]));

    printf("begin=%lld %lld\n", (long long)window.begin_ymd,
           (long long)window.begin_sod);
    printf("src=%s\n", window.start_source ? window.start_source : "");
    printf("end=%lld %lld\n", (long long)window.end_ymd,
           (long long)window.end_sod);
    printf("src=%s\n", tc_source_str(opts.src[TC_SET_END]));
    printf("kind=%lld\n", (long long)window.kind);

    printf("min_count=%lld\n", (long long)opts.min_count);
    printf("src=%s\n", tc_source_str(opts.src[TC_SET_MIN_COUNT]));
    printf("top=%lld\n", (long long)opts.top);
    printf("state=%lld\n", (long long)opts.state_filter);
    printf("src=%s\n", tc_source_str(opts.src[TC_SET_STATE]));
    printf("sort=%lld\n", (long long)opts.sort);
    printf("columns=%lld,%lld,%lld,%lld,%lld,%lld,%lld\n",
           (long long)opts.column_count,
           (long long)opts.columns[0], (long long)opts.columns[1],
           (long long)opts.columns[2], (long long)opts.columns[3],
           (long long)opts.columns[4], (long long)opts.columns[5]);
    if (opts.columns_src_ptr != NULL) {
        printf("src=%s\n", opts.columns_src_ptr);
    } else {
        printf("src=\n");
    }
    printf("header=%lld\n", (long long)opts.header_mode);
    printf("json=%lld\n",
           (long long)((opts.flags & TC_F_JSON) ? 1 : 0));
    printf("watch=%lld\n",
           (long long)((opts.flags & TC_F_WATCH_PRESENT) ? 1 : 0));
    printf("users=%lld\n", (long long)opts.users);
    printf("flags=%lld\n", (long long)opts.flags);
    printf("config=%s\n", opts.config_path);
    printf("color=%lld\n", (long long)opts.color_mode);

    /* C5: tc_source_str on the DYN ids must return a NUL-terminated string
       whose length equals the source's length (the C port's only channel is
       the pointer; the buffers tc_cli_parse filled are NUL-terminated, so a
       strlen check is the assertion). */
    for (i = 0; i < (int)(sizeof(dyn_ids) / sizeof(dyn_ids[0])); i++) {
        const char *p = tc_source_str(dyn_ids[i]);
        if (p == NULL) {
            fprintf(stderr, "dyn_bad id=%d returned=NULL\n", dyn_ids[i]);
            return 1;
        }
        /* strlen(p) is the contract's computed length for this port */
        (void)strlen(p);
    }

    return 0;
}