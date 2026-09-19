// ============================================================================
// tc_cache_stub.S — Phase 5 PRIVATE stub for the Phase 6 tc_cache_status.
// ============================================================================
//
//  This file is owned by Phase 5 and never shared: the real implementation
//  arrives with Phase 6 (tc_cache.S) and the orchestrator links that module
//  instead of this stub.  Do not commit this file into the final link.
//
//  Contract (frozen by the orchestrator for Phase 6):
//    tc_cache_status() -> (x0=used 0/1, x1=reused u64, x2=parsed u64,
//                          x3=problem_ptr|0, x4=rebuilt_reason_ptr|0,
//                          x5=path_ptr|0)
//    x3/x4/x5 are NUL-terminated strings or 0.
//
//  Stub behaviour: the cache is always "used" with zero days reused and every
//  parsed line counted as parsed; no problem, no rebuild reason, no path.  The
//  renderer falls back to the literal "rollup.db" when path_ptr is 0.
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Linking:    musl-gcc -static
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"

    .text

// ----------------------------------------------------------------------------
// tc_cache_status — the Phase 6 contract, stubbed.
// ----------------------------------------------------------------------------
    .p2align 2
    .global tc_cache_status
    FUNC_TYPE(tc_cache_status)
tc_cache_status:
    mov x0, #1                      // used = 1 (cache served this pass)
    mov x1, #0                      // reused = 0 days
    adrp x2, PAGE(tc_tally)
    add x2, x2, LO12(tc_tally)
    ldr x2, [x2, #TC_T_PARSED]      // parsed = lines parsed this pass
    mov x3, #0                      // problem = none
    mov x4, #0                      // rebuilt_reason = none
    mov x5, #0                      // path = none (renderer uses "rollup.db")
    ret

// ============================================================================
// Counting-pass hooks (tc_core.S calls these once per in-range file).  With
// no rollup cache every file is parsed normally.
// ============================================================================

// tc_cache_day(fpath, lo, hi, enter_state, ymd) -> x0 = 0 (parse normally)
    .p2align 2
    .global tc_cache_day
    FUNC_TYPE(tc_cache_day)
tc_cache_day:
    mov x0, #0
    ret

// tc_cache_put_day(exit_state) -> 0 (nothing stashed, nothing to write)
    .p2align 2
    .global tc_cache_put_day
    FUNC_TYPE(tc_cache_put_day)
tc_cache_put_day:
    mov x0, #0
    ret

// tc_cache_discard_day() -> 0 (drop any pending stash: none)
    .p2align 2
    .global tc_cache_discard_day
    FUNC_TYPE(tc_cache_discard_day)
tc_cache_discard_day:
    mov x0, #0
    ret

    .end
