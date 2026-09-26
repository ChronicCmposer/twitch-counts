// ============================================================================
// tc_parse_facts.inc — the parser's input facts, shared across modules
// ============================================================================
//
//  Single source of truth for the literal strings the line parsers match and
//  the cache fingerprint embeds.  tc_core.S (count path), tc_watch.S (watch
//  path) and tc_cache.S (fingerprint) all #include this file and reference
//  the SAME labels, so a rename is caught at assemble time everywhere at
//  once and a text change ripples to every consumer -- the fingerprint can
//  never silently drift from the parser that produced the cached numbers.
//
//  The marker suffixes come in two consumer forms, both defined here:
//    * the bare suffix ("is live!"), which the count path's
//      core_marker_match compares and the cache fingerprint embeds.  The
//      fingerprint prefixes ("live=" / "off=") and the login-regex prefix
//      ("login=") are emitted immediately before their shared labels, so
//      each fingerprint part is ONE contiguous NUL-terminated string that
//      includes the shared bytes.
//    * the space-prefixed form (" is live!"), which is the watch path's
//      rfind needle -- CPython seek_window's literal.  It is the same
//      marker bytes with a leading space and MUST be edited together with
//      the bare form above it.
//
//  The login regex "[A-Za-z0-9_]{1,25}" is the fingerprint text for the
//  parser's LOGIN_RE logic (implemented as character-range checks in
//  tc_core.S / tc_watch.S); the shared label documents and fingerprints it.
//
// ============================================================================

#ifndef TC_PARSE_FACTS_INC
#define TC_PARSE_FACTS_INC

    RODATA
pfx_fp_live:          .ascii "live="
pfx_is_live:          .asciz "is live!"        // count-side marker suffix
pfx_fp_off:           .ascii "off="
pfx_is_offline:       .asciz "is now offline."
pfx_fp_login:         .ascii "login="
pfx_login_re:         .asciz "[A-Za-z0-9_]{1,25}"
// watch rfind needles: a leading space + the bare suffix above
pfx_is_live_sp:       .asciz " is live!"
pfx_is_offline_sp:    .asciz " is now offline."
    .text

#endif // TC_PARSE_FACTS_INC