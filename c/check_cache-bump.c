// ============================================================================
// check_cache-bump.c — the tc-cache-bump-test driver (fingerprint bump).
// ============================================================================
//
//  The cache harness (h2-h4) proves that two fingerprint generations coexist
//  in one database: the normal tc-cache-test writes rows tagged with the
//  tc-cache-fp-v1 generation, then this driver — the SAME counting pass with
//  the fingerprint VERSION head bumped to tc-cache-fp-v2 — registers a second
//  generation and reuses its own rows.
//
//  The asm Makefile sed-bumps a copy of tc_cache.S (s_fp_head).  The C build
//  shares one cache.o between the two drivers, so the bump is a strong
//  definition of the cache's weak override hook: cache.c's
//  tc_cache_fp_head_override() defaults to NULL (-> "tc-cache-fp-v1"); this
//  translation unit provides the strong form returning "tc-cache-fp-v2", and
//  the linker prefers it for tc-cache-bump-test only.
//
//  The rest of the driver is check_cache.c itself, included verbatim so the
//  two binaries can never drift apart.
// ============================================================================

#define _DEFAULT_SOURCE 1

#include "tc_platform.h"

/* Strong override of the weak hook in cache.c (must come before the include:
   the driver text defines main and every helper once). */
const char *tc_cache_fp_head_override(void) {
    return "tc-cache-fp-v2";
}

#include "check_cache.c"