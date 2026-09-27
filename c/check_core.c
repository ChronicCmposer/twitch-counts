// ============================================================================
// check_core.c — the test driver for the counting core.
//   main(): tc_cli_parse -> tc_resolve_channel -> tc_count_run -> dump.
//   The dump is the C counterpart of the asm port's shared tc_dump
//   (check_tc_dump.S), the stable contract-structure printer the core and
//   cache harnesses diff:
//
//     channel=<resolved dir name>
//     window begin=<ymd>:<sod> end=<ymd>:<sod> kind=<k> width=<w> found=<f> req=<r>
//     listing <n>
//     <ymd> <name>
//     users <n>
//     <login> <live> <offline> <unknown>
//     tally files=<f> messages=<m> parsed=<p> states=<l>:<o>:<u> excl=<l>:<o>:<u> unreadable=<u>
//     unreadable <name> <reason>
//
//  The tally line is the core format (no reused field): the core harness's
//  strict `parsed=<n> states=` regex requires the two fields adjacent.  The
//  cache harness reads reused from its own cachestatus line and tolerates
//  the absence here.
//
//  Exits 0 on success; tc_fail paths exit 1 with "error: ..." on stderr.
//
//  Cache note: the asm core driver never opens the rollup cache (its
//  tc_count_run consults a NULL module connection and so always parses), and
//  this harness's tally expectations (parsed=N) assume exactly that.  The C
//  tc_count_run opens its own cache handle per Python's select_rows, so this
//  driver forces the --no-cache flag to reproduce the asm driver's
//  deterministic cold behavior; the cache itself is exercised end to end by
//  tc-cache-test (check_cache.c), which owns its own handle.
// ============================================================================

#include "tc_platform.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* The resolved listing the counting pass used (core.c exposes it; the asm
   port's tc_dump reads the same structure from its tc_listing global). */
extern tc_listing tc_core_listing;

static void tc_dump(const char *channel_name, const tc_window *window,
                    const tc_tally *tally) {
    int64_t i;

    printf("channel=%s\n", channel_name);

    printf("window begin=%lld:%lld end=%lld:%lld kind=%lld width=%lld "
           "found=%lld req=%lld\n",
           (long long)window->begin_ymd, (long long)window->begin_sod,
           (long long)window->end_ymd, (long long)window->end_sod,
           (long long)window->kind,
           (long long)window->users_width, (long long)window->users_found,
           (long long)window->users_req);

    printf("listing %lld\n", (long long)tc_core_listing.count);
    for (i = 0; i < tc_core_listing.count; i++) {
        printf("%lld %s\n", (long long)tc_core_listing.entries[i].ymd,
               tc_core_listing.entries[i].name);
    }

    printf("users %lld\n", (long long)tally->users->count);
    for (i = 0; i < tally->users->count; i++) {
        const tc_user_entry *entry = &tally->users->entries[i];
        printf("%s %lld %lld %lld\n", entry->login,
               (long long)entry->live, (long long)entry->offline,
               (long long)entry->unknown);
    }

    printf("tally files=%lld messages=%lld parsed=%lld "
           "states=%lld:%lld:%lld excl=%lld:%lld:%lld unreadable=%lld\n",
           (long long)tally->files, (long long)tally->messages,
           (long long)tally->parsed,
           (long long)tally->states[0], (long long)tally->states[1],
           (long long)tally->states[2],
           (long long)tally->excluded_states[0],
           (long long)tally->excluded_states[1],
           (long long)tally->excluded_states[2],
           (long long)tally->unreadable_count);
    for (i = 0; i < tally->unreadable_count; i++) {
        printf("unreadable %s %s\n", tally->unreadable[i].name,
               tally->unreadable[i].reason);
    }
}

int main(int argc, char **argv) {
    tc_opts opts;
    tc_window window;
    tc_users users;
    tc_tally tally;
    char channel_dir[TC_PATH_SZ];
    char channel_name[TC_CHANNEL_SZ];
    int status;

    memset(&opts, 0, sizeof(opts));
    memset(&window, 0, sizeof(window));
    memset(&users, 0, sizeof(users));
    memset(&tally, 0, sizeof(tally));
    tally.users = &users;

    status = tc_cli_parse(argc, argv, &opts, &window);
    if (status != TC_EXIT_OK) {
        return status;
    }
    /* The core harness diffs cold parsing (parsed=N); force the no-cache path
       so a warm rollup from an earlier harness run cannot change the tally
       (see the header note). */
    opts.flags |= TC_F_NO_CACHE;

    /* Resolve the channel for the dump; tc_count_run resolves it again
       (idempotent).  Failure exits 1 with the exact Python error text. */
    status = tc_resolve_channel(&opts, channel_dir, sizeof(channel_dir),
                                channel_name, sizeof(channel_name));
    if (status != TC_EXIT_OK) {
        return status;
    }

    status = tc_count_run(&opts, &window, &tally);
    if (status != TC_EXIT_OK) {
        return status;
    }

    tc_dump(channel_name, &window, &tally);

    free(users.entries);
    free(tc_core_listing.entries);
    return 0;
}