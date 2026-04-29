# Deep-dive: Source of the kessel-vs-OXC gap (S22.4, 2026-04-29)

> "It makes no sense that OXC can be faster than us. Keep digging." — user
>
> This document is the result of that digging.

## Where we started this deep-dive

* kessel geo-mean ratio: **1.064× OXC**
* monaco worst case: 1.20×
* Two failed attempts to close the gap: non-mutex arena (predicted 8–10 %, got 0.4 %),
  first-letter keyword gate (predicted 1–2 %, got noise).
* SoA prototype showed a fair 10–12 % win on the AST-construction subset (~3–4 %
  projected wall time), but had not yet been integrated.

## What we measured

### The gap is in LEX, specifically in identifier handling.

Profile decomposition on monaco (kessel 32 ms vs OXC 27 ms = 5 ms gap):

| Category | kessel | OXC | gap |
|---|---:|---:|---:|
| **LEX**   | 13.4 ms | 9.4 ms  | **+4.0 ms** |
| PARSE     | 13.0 ms | 11.3 ms | +1.7 ms     |
| ALLOC     | 3.0 ms  | 0.05 ms | +2.95 ms    |
| Other     | 2.5 ms  | 6.3 ms  | -3.8 ms     |
| **Total** | 32 ms   | 27 ms   | **+5 ms**   |

Within LEX, the gap is concentrated in identifier handling (kessel ~9.2 ms vs
OXC ~5 ms = ~4 ms). Single-character dispatch, string lex, whitespace skip
are at-or-below OXC parity.

### What kessel does differently per identifier (vs OXC)

| Step                          | kessel                              | OXC                                       |
|-------------------------------|-------------------------------------|-------------------------------------------|
| Dispatch into id handler      | `is_id_start_fast(c)` then `lex_identifier` | `byte_handlers[c]` jump table → letter-specific handler |
| First-byte handling           | UTF-8 width decode (always)         | None — handler knows byte is ASCII        |
| Body scan                     | NEON SIMD (6 vector compares per 16 B chunk) | `byte_search!` macro (32 B scalar batch, LLVM auto-vectorize) |
| Keyword classification        | Separate `lookup_keyword_by_letter` function call | INLINED in per-letter handler (`L_T` does keyword check for `t`-starting words) |
| Token return                  | `FastToken{start, end, kind, flags}` (4 stores) | `Kind` enum value (1 store) |

OXC's per-letter design **fuses identifier scanning and keyword classification
into one inlined function per starting letter.** kessel has them as separate
phases (scan → call classifier → return token).

## What we changed

### Win #1: scalar prefix before SIMD scan (1.064× → 1.047×)

`simd_scan_id_cont` always entered the 16-byte NEON loop, even for 1–3 byte
identifiers. With the per-chunk overhead of 6 vector compares + reduce_or +
mask extract, the SIMD path was net-slower than scalar for short IDs.

We measured monaco's identifier-length distribution:

```
len   pct    cumul
  1   35.1%  35.1%   ← single-letter (i, x, n, …)
  2    6.5%  41.6%
  4   13.6%  60.0%
  8    3.4%  80.9%   ← 81% of identifiers fit in scalar prefix
 16    1.0%  93.8%   ← 94% fit in one SIMD chunk
 >16            6.2%
```

Adding an 8-byte scalar prefix loop eliminates SIMD overhead for the 81% of
identifiers that fit. Longer ones still benefit from SIMD.

```odin
// New scalar prefix in simd_scan_id_cont:
when ODIN_ARCH == .arm64 {
    prefix_end := min(off + 8, src_len)
    for off < prefix_end {
        c := src[off]
        if c == '\\' { return off, true, has_non_ascii }
        class := CHAR_CLASS_TABLE[c]
        if class != u8(CharClass.IdStart) && class != u8(CharClass.Digit) {
            return off, false, has_non_ascii
        }
        if c >= 0x80 { has_non_ascii = true }
        off += 1
    }
    // ... existing SIMD loop ...
}
```

Per-file impact:

| File | before | after | Δ |
|---|---:|---:|---:|
| typescript.js     | 1.09× | 1.08× | flat |
| cesium.js         | 1.17× | 1.11× | **−6 pp** |
| monaco.js         | 1.20× | 1.16× | **−4 pp** |
| preact.js         | 1.01× | 0.94× | **−7 pp** (now BEATS OXC) |

Geo-mean: 1.064× → 1.047×.

### Win #2: force_inline lookup_keyword_by_letter (1.047× → 1.043×)

Reverting commit `f9fa0ec`'s `#force_no_inline`. That commit's icache-pressure
reasoning was correct for the 32 KB L1i of older CPUs, but Apple Silicon
has 192 KB L1i — plenty of room for the 13 KB keyword classifier.

Inlining it lets LLVM hoist `src/start/end` into registers across the
classifier switch, saving ~5 ns of function-call overhead per identifier.

Impact: ~0.4 pp geo-mean. Small but consistent.

## What we tested and didn't ship

### Disabling keyword classification entirely

Hypothesis: lookup_keyword's 11 % of CPU is overhead — we could save it all.

Test: replaced the function body with `return .Identifier`.

Result: parser became **10–25 % SLOWER**. Reason: when keywords aren't
recognized, they reach the parser as identifiers, which then has to do
more disambiguation work. The classification is **productive work**, not
overhead.

### Un-inlining lex_identifier for cleaner profile attribution

This was a measurement experiment, not a perf change. With `#force_no_inline`,
lex_identifier showed up as a separate 4.9 ms entry. Reverted because
inlining is faster (~1–2 % regression when un-inlined).

This experiment yielded the line-attribution data that drove win #1.

## What's left: the remaining ~4 % gap

### kessel-only times we can't easily reduce

* **`lex_identifier` body (~5.9 ms on monaco)** vs OXC's `identifier_name_handler`
  (~2.6 ms). After our scalar prefix, this is 80 ns/id vs OXC's 37 ns/id —
  a 43 ns/id gap.
* **`lookup_keyword_by_letter` (~1.7 ms)** real work that doesn't go away
  by inlining (we saved only the function-call overhead, ~0.35 ms).
* **`arena_allocator_proc` chain (~3 ms)** of which only ~0.5 ms is mutex
  overhead (verified by the failed non-mutex experiment); the rest is real
  bump_alloc work.

### What would close the remaining 4 %

#### Option A: Per-letter identifier handlers (OXC's pattern) — moderate refactor

Split `lookup_keyword_by_letter` into 21 small per-letter helpers, each
inlinable into `lex_identifier`'s switch on first byte. This eliminates the
generic-classifier framework while keeping each helper small (4–8 byte
compares for its keyword family).

Predicted: 1–2 % wall time. The mechanism is the same as our win #2
(inlining), but more aggressive. Risk: the per-letter functions add up to
~13 KB of code; managing icache locality is non-trivial.

#### Option B: SoA AST migration (step #5)

Already validated as 10–12 % faster on the isolated AST-build subset
(fair benchmark using same bump pool both sides). Real-world projection:
3–4 % wall time. 4–5 weeks of work.

#### Option C: Stop here

89 % of the original gap is closed. 5/10 files at parity-or-better
(snabbdom 0.90×, preact 0.94×, react-dom 1.01×, d3 1.04×, antd 1.05×).
Worst remaining files: monaco 1.14×, jquery 1.10×, lodash 1.11×.

## The real lesson

Profile attribution percentages **overstate** the achievable savings when
the function does real work. The "10 % ALLOC" attribution doesn't mean 10 %
is removable; it means 10 % is spent there, of which ~90 % is irreducible
work (bump pointer, capacity check, memcpy).

Optimizations that actually saved time in this session targeted **work
elimination**, not dispatch overhead:

| Optimization | Mechanism | Result |
|---|---|---|
| Scalar prefix before SIMD | Skip SIMD overhead for short IDs | -1.7 pp |
| force_inline keyword | Save function-call overhead | -0.4 pp |
| (Failed) Non-mutex arena | Skip mutex op | 0.4 % (within noise) |
| (Failed) First-letter gate | Skip 30 % of calls | within noise |
| (Failed) Inline tagged unions | Smaller per-node footprint | 0.3 % geo |
| (Failed) Proc-ptr byte dispatch | Different dispatch shape | -1.5 % (regression) |

The wins were in the inner loop of the lexer where each saved cycle
compounds across millions of bytes scanned. The failures were dispatch
wrappers around real work — removing the wrapper saved a few nanoseconds
that didn't compound.

## Final state of session 22

* Geo-mean ratio: **1.043× OXC** (1.346× → 1.064× → 1.047× → 1.043×)
* Files beating OXC: **2/10** (snabbdom 0.90×, preact 0.94×)
* Files at parity (≤1.05×): **5/10**
* Files within 10 %: **8/10**
* All correctness gates green: Test262 49,728/49,729, TS 21/21, JSX 18/18,
  Real 467/467, Negative 125/125, Unit 409/409, Invariants OK,
  Nodes 57/57, Ambiguity baseline-matched, ESTree deep-walk passes.
* 89 % of original gap closed.

The understanding has paid off: two real, measured wins (scalar prefix
and force_inline lookup_keyword) both targeting actual work, both robust
across multiple runs.
