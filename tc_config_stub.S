// ============================================================================
// tc_config_stub.S — test stub of the tc_config.S hooks (never shipped).
// ============================================================================
//
//  A stand-in for tc_config.S in the tc-cli-test and tc-core-test drivers
//  (the Makefile links it there instead of tc_config.o).  It satisfies the
//  symbols tc_cli.o and tc_core.o reference:
//
//    tc_env_get / tc_config_get   -> always not-found
//    tc_aliases_apply             -> no-op
//    tc_excl_contains             -> consults the RESOLVED OPTIONS for the
//       exclusion tests: the raw --exclude list (TC_O_EXCL_LIST, split on
//       commas/whitespace) and --exclude-broadcaster (TC_O_EXCL_BCAST_VAL
//       vs the lowercased resolved channel).  This mirrors what the real
//       tc_config.S set would contain for CLI-only exclusions.
//
//  The exclusion compare is case-insensitive (the logins stored by the
//  counting pass are already lowercase; the option tokens are lowercased
//  here, matching Python's cfg_split_names()).
// ============================================================================

#include "tc_platform.h"
    .arch armv8-a
#include "tc_layout.inc"
    .text

    .globl tc_env_get
    .globl tc_config_get
    .globl tc_aliases_apply
    .globl tc_excl_contains

// ----------------------------------------------------------------------------
// tc_env_get(x0=name) -> (x0=found 0/1, x1=value_ptr) — always not-found.
// ----------------------------------------------------------------------------
    .p2align 2
tc_env_get:
    mov x0, #0
    mov x1, #0
    ret

// ----------------------------------------------------------------------------
// tc_config_get(x0=key, x1=section_id) -> (x0, x1, x2) — always not-found.
// ----------------------------------------------------------------------------
    .p2align 2
tc_config_get:
    mov x0, #0
    mov x1, #0
    mov x2, #0
    ret

// ----------------------------------------------------------------------------
// tc_aliases_apply() -> 0 — no-op.
// ----------------------------------------------------------------------------
    .p2align 2
tc_aliases_apply:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// tc_excl_contains(x0=ptr, x1=len) -> x0 = 1 if excluded (test model).
//
// NOTE (deliberate drift from tc_config.S): this stub omits the real
// function's `len==0` / `len>25` guards and its first-byte-lowercase fast
// path, and it consults tc_opts directly instead of tc_excl_set.  The
// behavior is intentionally different — the exclusion tests depend on it.
// Do NOT sync it with the real tc_excl_contains.
// ----------------------------------------------------------------------------
    .p2align 2
tc_excl_contains:
    PROLOGUE 3
    mov x19, x0                         // login ptr
    mov x20, x1                         // login len
    LEA x21, tc_opts
    // --exclude-broadcaster: exclude the lowercased resolved channel
    ldr x0, [x21, #TC_O_EXCL_BCAST_VAL]
    cbz x0, .Lstc_list
    add x0, x21, #TC_O_CHANNEL
    mov x1, x19
    mov x2, x20
    bl stub_eq_lower                  // channel vs login, case-insensitive
    cbnz x0, .Lstc_yes
.Lstc_list:
    // raw --exclude entries, split on commas / whitespace
    ldr x9, =TC_O_EXCL_COUNT
    ldr x22, [x21, x9]
    mov x23, #0
.Lstc_loop:
    cmp x23, x22
    b.ge .Lstc_no
    ldr x9, =TC_O_EXCL_LIST
    add x0, x21, x9
    mov x1, #64
    mul x1, x23, x1
    add x24, x0, x1                     // entry string
    // walk comma/space-separated tokens
.Lstc_tok:
    ldrb w0, [x24]
    cbz w0, .Lstc_tok_end
    cmp w0, #','
    b.eq .Lstc_tok_next
    cmp w0, #' '
    b.eq .Lstc_tok_next
    cmp w0, #9
    b.eq .Lstc_tok_next
    // token start
    mov x0, x24
    mov x1, #0
.Lstc_tlen:
    ldrb w2, [x24]
    cbz w2, .Lstc_tlen_done
    cmp w2, #','
    b.eq .Lstc_tlen_done
    cmp w2, #' '
    b.eq .Lstc_tlen_done
    cmp w2, #9
    b.eq .Lstc_tlen_done
    add x24, x24, #1
    add x1, x1, #1
    b .Lstc_tlen
.Lstc_tlen_done:
    // token = [x0, x1 bytes); compare vs login (login lowercase)
    mov x2, x19
    mov x3, x20
    bl stub_tok_eq                    // x0 = 0/1
    cbnz x0, .Lstc_yes
    b .Lstc_tok
.Lstc_tok_next:
    add x24, x24, #1
    b .Lstc_tok
.Lstc_tok_end:
    add x23, x23, #1
    b .Lstc_loop
.Lstc_yes:
    mov x0, #1
    EPILOGUE 3
    ret
.Lstc_no:
    mov x0, #0
    EPILOGUE 3
    ret

// ----------------------------------------------------------------------------
// stub_tok_eq — compare a bounded token (x0=ptr, x1=len) against a bounded
//   login (x2=ptr, x3=len), case-insensitively.  -> x0 = 0/1.
//   Clobbers x0-x17 only (callers keep their state in callee-saved regs).
// ----------------------------------------------------------------------------
    .p2align 2
stub_tok_eq:
    cmp x1, x3
    b.ne .Lsteq_no
    mov x4, #0
.Lsteq:
    cmp x4, x1
    b.ge .Lsteq_yes
    ldrb w5, [x0, x4]
    ldrb w6, [x2, x4]
    cmp w5, #'A'
    b.lt .Lsteq_norm
    cmp w5, #'Z'
    b.gt .Lsteq_norm
    add w5, w5, #('a' - 'A')
.Lsteq_norm:
    cmp w5, w6
    b.ne .Lsteq_no
    add x4, x4, #1
    b .Lsteq
.Lsteq_yes:
    mov x0, #1
    ret
.Lsteq_no:
    mov x0, #0
    ret

// ----------------------------------------------------------------------------
// stub_eq_lower — compare a C string (x0=ptr) against a bounded login
//   (x1=ptr, x2=len), lowercasing the C string's bytes.  -> x0 = 0/1.
// ----------------------------------------------------------------------------
    .p2align 2
stub_eq_lower:
    mov x3, #0
.Lstel:
    ldrb w4, [x0, x3]
    cmp x3, x2
    b.ge .Lstel_check_end
    cmp w4, #'A'
    b.lt .Lstel_norm
    cmp w4, #'Z'
    b.gt .Lstel_norm
    add w4, w4, #('a' - 'A')
.Lstel_norm:
    ldrb w5, [x1, x3]
    cmp w4, w5
    b.ne .Lstel_no
    add x3, x3, #1
    b .Lstel
.Lstel_check_end:
    cbz w4, .Lstel_yes
.Lstel_no:
    mov x0, #0
    ret
.Lstel_yes:
    mov x0, #1
    ret


// tc_excl_src_count() -> x0 = 0: the stub has no exclusion sources (the
// render/json modules linked into tc-core-test ask for the count).
//
// DANGER: this is a FUNCTION here but a .bss DATA variable (`.skip 8`) in
// the real tc_config.S.  Any `LEA xN, tc_excl_src_count` followed by
// `ldr` (as tc_render.S / check_tc_config.S do against the real module)
// would read the function's first instructions as a count in this stub.
// The tests depend on the function form — do NOT convert it to data.
    .p2align 2
    .global tc_excl_src_count
    FUNC_TYPE(tc_excl_src_count)
tc_excl_src_count:
    mov x0, #0
    ret

    .end
