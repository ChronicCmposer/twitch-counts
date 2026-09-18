// ============================================================================
// fibonacci.S — print the first N Fibonacci numbers, one per line
// ============================================================================
//
//  Target:     AArch64 (ARMv8-A), little-endian, Linux
//  Assembler:  GNU as (GAS)
//  Linking:    plain `ld` (no CRT, no libc, pure syscalls)
//
//  Behavior
//  --------
//    F(0) = 0, F(1) = 1, F(i) = F(i-1) + F(i-2)
//    `./fibonacci 10` prints:  0 1 1 2 3 5 8 13 21 34   (one per line)
//    No argument  ->  N defaults to 10.
//    N == 0       ->  prints nothing, exits 0.
//    Bad argv[1]  ->  "usage: fibonacci [N]" on stderr, exits 1.
//    N too large  ->  prints terms while they fit in 64 bits, then a note
//                     on stderr and exits 0.  The first overflow happens
//                     while computing F(94) (i.e. index 93): F(93) still
//                     fits in an unsigned 64-bit integer.
//
//  Algorithm
//  ---------
//    Iterative.  Two running values are kept in callee-saved registers so the
//    kernel (syscalls) and our own subroutines can never disturb them; the
//    program therefore needs *no* spills to memory across calls.
//
//      a = F(i)          (the term about to be printed)
//      b = F(i+1)        (the next term)
//      print a
//      a, b  <-  b, a+b
//
//    The next term is computed with `adds` (ADD and Set flags); if the sum
//    does not fit in 64 bits the carry flag C is set and `b.cs` branches to
//    the overflow handler.  N = 100 therefore prints indices 0..92 and the
//    note reports index 93.
//
//  Register roles
//  --------------
//    x19  = a   (current term F(i), callee-saved)
//    x20  = b   (next term F(i+1), callee-saved)
//    x21  = i   (index of the term just printed, callee-saved)
//    x22  = n   (number of terms to print, callee-saved)
//    x23  = scratch: the fresh sum a+b in the main loop; the digit pointer
//           in the overflow handler (safe: not live across any `bl`)
//    x24  = scratch: digit count in the overflow handler
//    x0   = syscall argument 1 (fd) / function argument / syscall return
//    x1   = syscall argument 2 (buffer) / function argument
//    x2   = syscall argument 3 (length) / function result (digit count)
//    x3..x6 = subroutine-local scratch (decimal conversion)
//    x8   = syscall number
//    x30  = link register (return address)
//
//  Linux AArch64 syscall ABI
//  -------------------------
//    * Invoke with `svc #0`; the syscall number goes in x8.
//    * Arguments are passed in x0, x1, x2, x3, x4, x5 (we only need x0-x2).
//    * The return value comes back in x0 (negative errno on failure).
//    * The kernel preserves ALL registers except x0 — so the loop state in
//      x19..x22 survives every syscall untouched.
//
//    write(fd, buf, len)   ->  x8 = 64,  x0 = fd, x1 = buf, x2 = len
//    exit(status)          ->  x8 = 93,  x0 = status
//
//    stdout = fd 1, stderr = fd 2.
//
//  Decimal conversion (decimal_convert)
//  ------------------------------------
//    Unsigned divide-by-10 loop: `udiv` gives the quotient, `msub` recovers
//    the remainder (digit).  Digits are produced least-significant first, so
//    they are written back-to-front into a 21-byte stack buffer (20 digits +
//    room for '\n'), starting at buf+20 and walking down.  When the quotient
//    reaches 0 the pointer points at the most-significant digit and the digit
//    count is known; the caller appends '\n' at buf+20 and issues one `write`.
//    The value 0 is special-cased (the loop would produce zero digits; we
//    must emit "0").
// ============================================================================

    .arch armv8-a
    .text
    .global _start

// ----------------------------------------------------------------------------
// Constants
// ----------------------------------------------------------------------------
    .equ SYS_WRITE, 64        // Linux AArch64 syscall: write
    .equ SYS_EXIT,  93        // Linux AArch64 syscall: exit
    .equ STDOUT,    1         // standard output file descriptor
    .equ STDERR,   2          // standard error file descriptor
    .equ DEFAULT_N, 10        // number of terms when no argument is given
    .equ DEC_BUF,   21        // decimal buffer size: 20 digits + '\n'

// ----------------------------------------------------------------------------
// _start — entry point.  Linux provides, with no CRT:
//     sp       -> argc                       (a 64-bit count)
//     [sp + 8] -> argv[0]  (program name)
//     [sp + 16]-> argv[1]  (first argument, or NULL)
// ----------------------------------------------------------------------------
_start:
    // ---- Parse the boundary: decide N, or reject the input. -------------
    ldr x22, [sp]                // x22 = argc
    cmp x22, #1                  // was the program invoked with no arguments?
    b.eq .Ldefault_n             // yes -> use the default N

    ldr x0, [sp, #16]            // x0 = argv[1]
    bl parse_decimal             // x0 = parsed N, or -1 if invalid
    cmn x0, #1                   // flag check: is x0 + 1 == 0  (x0 == -1)?
    b.eq usage                   // invalid input -> usage, exit 1
    mov x22, x0                  // x22 = N (trusted now: pure decimal digits)
    b .Linit

.Ldefault_n:
    mov x22, #DEFAULT_N          // x22 = 10

.Linit:
    // ---- Early exit: N == 0 prints nothing. ------------------------------
    cbz x22, exit_ok             // N == 0 -> skip the loop entirely, exit 0

    // ---- Iterative state. ------------------------------------------------
    mov x19, #0                  // a = F(0) = 0
    mov x20, #1                  // b = F(1) = 1
    mov x21, #0                  // i = 0  (index of term about to be printed)

// ----------------------------------------------------------------------------
// Main loop — print a, then advance a,b <- b,a+b.
// ----------------------------------------------------------------------------
main_loop:
    bl print_term                // print F(i) = a  (uses only scratch regs)
    add x21, x21, #1             // i++
    cmp x21, x22                 // have all N terms been printed?
    b.eq exit_ok                 // yes -> done, exit 0

    // Advance the pair.  `adds` sets the carry flag C iff the unsigned sum
    // does not fit in 64 bits — that is the overflow detector.
    adds x23, x19, x20           // x23 = a + b   (C = 1 on unsigned overflow)
    b.cs overflow                // overflow -> note to stderr, exit 0
    mov x19, x20                 // a  = b
    mov x20, x23                 // b  = a + b
    b main_loop

// ----------------------------------------------------------------------------
// print_term — emit "a\n" to stdout.
//   Uses only scratch registers (x0-x3, x8, x30) so the loop state in
//   x19..x22 survives the call; lr is stacked because we call convert below.
// ----------------------------------------------------------------------------
print_term:
    str x30, [sp, #-16]!         // allocate 16 bytes, save return address
    sub sp, sp, #32              // allocate the 21-byte decimal buffer (32 keeps 16-byte alignment)
    mov x0, x19                  // value to print = a = F(i)
    mov x1, sp                   // buffer
    bl convert_u64               // -> x1 = first digit, x2 = digit count
    mov x3, #'\n'                // append the line terminator
    strb w3, [x1, x2]            // buffer[x2] = '\n'  (buffer slot buf+20)
    add x2, x2, #1               // total length = digits + 1
    mov x0, #STDOUT              // write(fd = stdout, ...)
    mov x8, #SYS_WRITE           // syscall 64
    svc #0                       // one write per line, as specified
    add sp, sp, #32              // drop the buffer
    ldr x30, [sp]                // restore return address
    add sp, sp, #16              // drop the saved-lr slot
    ret

// ----------------------------------------------------------------------------
// overflow — a+b carried: report the index and exit 0 (a successful, complete
// run up to the largest representable term).
//   Message: "fibonacci: overflow at index <i> (exceeds 64-bit)"
// ----------------------------------------------------------------------------
overflow:
    sub sp, sp, #32              // room for the index's decimal digits
    mov x0, x21                  // the index at which overflow was detected
    mov x1, sp
    bl convert_u64               // -> x1 = digits, x2 = digit count
    mov x23, x1                  // keep digits across the prefix write
    mov x24, x2                  // keep digit count across the prefix write
    mov x0, #STDERR              // write prefix
    adr x1, overflow_prefix
    mov x2, #overflow_prefix_len
    mov x8, #SYS_WRITE
    svc #0
    mov x0, #STDERR              // write the digits
    mov x1, x23
    mov x2, x24
    mov x8, #SYS_WRITE
    svc #0
    mov x0, #STDERR              // write suffix + newline
    adr x1, overflow_suffix
    mov x2, #overflow_suffix_len
    mov x8, #SYS_WRITE
    svc #0
    add sp, sp, #32              // tidy up (not strictly needed before exit)
    b exit_ok                    // overflow is not an error: exit 0

// ----------------------------------------------------------------------------
// usage — print the usage line to stderr and exit 1.
// ----------------------------------------------------------------------------
usage:
    mov x0, #STDERR              // write(2, usage_msg, usage_msg_len)
    adr x1, usage_msg
    mov x2, #usage_msg_len
    mov x8, #SYS_WRITE
    svc #0
    mov x0, #1                   // exit(1)
    mov x8, #SYS_EXIT
    svc #0

// ----------------------------------------------------------------------------
// exit_ok — terminate successfully.  Also the target for N == 0.
// ----------------------------------------------------------------------------
exit_ok:
    mov x0, #0                   // exit(0)
    mov x8, #SYS_EXIT
    svc #0

// ----------------------------------------------------------------------------
// parse_decimal — boundary parser for argv[1].
//   in:  x0 = pointer to a NUL-terminated string
//   out: x0 = the parsed unsigned value, or -1 if the string is empty,
//        contains a non-digit, or would overflow 64 bits.
//   The whole input is validated here (Parse, Don't Validate): the main
//   program downstream never re-checks; it receives either a trusted number
//   or a clear failure sentinel.
//   Clobbers x0-x6.  (Called only from _start, where nothing is live.)
// ----------------------------------------------------------------------------
parse_decimal:
    mov x1, #0                   // x1 = accumulated value
    mov x6, #0                   // x6 = digit count (empty string detection)
.Lparse_loop:
    ldrb w2, [x0], #1            // w2 = next character (zero-extended)
    cbz w2, .Lparse_done         // NUL -> end of string
    sub x2, x2, #'0'             // digit value = char - '0'
    cmp x2, #9                   // > 9 means the character was not a digit
    b.hi .Lparse_invalid
    add x6, x6, #1               // count a digit
    // value = value*10 + digit, rejecting any 64-bit overflow:
    mov x3, #10
    umulh x4, x1, x3             // high 64 bits of value*10
    cbnz x4, .Lparse_invalid     // product does not fit -> invalid
    mul x1, x1, x3               // value *= 10
    adds x1, x1, x2              // value += digit (C set if it wraps)
    b.cs .Lparse_invalid         // wrapped -> invalid
    b .Lparse_loop
.Lparse_done:
    cbz x6, .Lparse_invalid      // no digits at all -> empty string -> invalid
    mov x0, x1                   // return the trusted value
    ret
.Lparse_invalid:
    mov x0, #-1                  // failure sentinel
    ret

// ----------------------------------------------------------------------------
// convert_u64 — decimal conversion core.
//   in:  x0 = unsigned 64-bit value
//        x1 = pointer to a 21-byte buffer (DEC_BUF)
//   out: x1 = pointer to the first (most significant) digit
//        x2 = number of digits  (>= 1; the caller appends '\n' at [x1 + x2])
//   Clobbers x0-x6.  Does NOT touch x19-x24, so the caller's state is safe.
//
//   Walkthrough: digits are produced least-significant first, so they are
//   written back-to-front.  x3 starts at buf+20 and each `strb` with the
//   pre-index form `[x3, #-1]!` stores a digit and moves the pointer down.
//   After k digits, x3 = buf+20-k and x2 = k.  The caller's '\n' therefore
//   lands exactly at buf+20 = x3+k, and the write starts at x3 with length
//   k+1.  Value 0 must not fall into the loop (it would emit no digits), so
//   it is special-cased to a single '0'.
// ----------------------------------------------------------------------------
convert_u64:
    add x3, x1, #20              // x3 = buf + 20  (write digits downward)
    mov x2, #0                   // x2 = digit count
    mov x4, #10                  // x4 = divisor
    cmp x0, #0
    b.ne .Lconv_digit_loop       // nonzero -> normal loop
    mov x5, #'0'                 // zero case: emit a single '0'
    strb w5, [x3, #-1]!          // store '0', move pointer down
    mov x2, #1                   // one digit
    b .Lconv_done
.Lconv_digit_loop:
    udiv x5, x0, x4              // x5 = value / 10          (quotient)
    msub x6, x5, x4, x0          // x6 = value - (x5 * 10)   (remainder)
    add x6, x6, #'0'             // remainder -> ASCII digit
    strb w6, [x3, #-1]!          // store the digit, walk the pointer down
    add x2, x2, #1               // one more digit
    mov x0, x5                   // continue with the quotient
    cbnz x0, .Lconv_digit_loop   // until the quotient is zero
.Lconv_done:
    mov x1, x3                   // x1 = first digit
    ret

// ----------------------------------------------------------------------------
// Read-only message data.  Lengths are computed as label differences so the
// writer and the `.equ` can never drift apart.
// ----------------------------------------------------------------------------
    .section .rodata
usage_msg:
    .ascii "usage: fibonacci [N]\n"
usage_msg_end:
    .equ usage_msg_len, usage_msg_end - usage_msg

overflow_prefix:
    .ascii "fibonacci: overflow at index "
overflow_prefix_end:
    .equ overflow_prefix_len, overflow_prefix_end - overflow_prefix

overflow_suffix:
    .ascii " (exceeds 64-bit)\n"
overflow_suffix_end:
    .equ overflow_suffix_len, overflow_suffix_end - overflow_suffix

    .end
