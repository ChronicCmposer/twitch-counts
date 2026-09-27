// ============================================================================
// check_misc.c — test driver for misc.c (twitch-counts).
//
//   main(): tc_cli_parse, then dispatch exactly as the Python main() does:
//       --manual               -> tc_misc_manual()
//       --emit-fish-completions-> tc_misc_fish()
//       --complete KIND        -> tc_misc_complete(&opts)
//   and returns the entry point's code (0 for all three).  This is the shape
//   the product main() takes (mirrors asm/check_tc_misc.S): the misc actions
//   never resolve the channel or build exclusions up front, so they work
//   without a channel exactly like the Python's short-circuit.
//
//   The completion module loads the config itself (misc_config_open): the C
//   tc_cli_parse resolves settings before the config module can see a
//   --config path, so misc.c is where the --config file is parsed and where a
//   missing explicit --config fails loudly — the documented divergence (the
//   Python reports quietly and exits 0).  The channel/logs-dir are also
//   re-resolved from that parsed table, so a --config channel is honored.
//
//   The binary under test is build/<os>/tc-misc-test (linked by the Makefile
//   against every C module except main.o plus the vendored libs).
// ============================================================================

#include "tc_platform.h"

int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    int status;

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;
    }
    if (opts.flags & TC_F_MANUAL) {
        return tc_misc_manual();
    }
    if (opts.flags & TC_F_EMIT_FISH) {
        return tc_misc_fish();
    }
    if (opts.flags & TC_F_COMPLETE_GIVEN) {
        return tc_misc_complete(&opts);
    }
    return TC_EXIT_OK;
}