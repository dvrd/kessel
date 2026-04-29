# DoD prototype results (S22.3, 2026-04-29)

## Verdict: **GO** for full SoA migration (step #5).

## Method

Two implementations of the same expression-tree builder (4 node types:
Identifier / Binary / Member / Call). Same input pattern, same
recursion depth, same checksum-validation walk. Pure AST construction
+ traversal — no lex, no parse logic.

* **AoS**: kessel-style pointer + Odin union, arena-allocated via
  `mem.virtual.arena_allocator`. One alloc per node.
* **SoA**: Zig-style fixed-capacity buffers (`tags []u8`, `data
  []NodeData`, `spans []Span`, `names []string`, `extra []u32`).
  Pre-allocated once. Per-node construction = 3 array writes + index
  increment.

Both produce identical AST shape and identical traversal checksum.

## Results

```
$ ./bench/dod_proto/proto 30 10   # 367K nodes / iter
AoS     min=7167 us  med=7279 us  max=7526 us
SoA     min=3191 us  med=3259 us  max=3506 us
SoA vs AoS: -55.2 % time  (2.234× speedup)

$ ./bench/dod_proto/proto 20 12   # 1.7M nodes / iter
AoS     min=33380 us  med=33944 us  max=36335 us
SoA     min=15017 us  med=15524 us  max=16554 us
SoA vs AoS: -54.3 % time  (2.187× speedup)
```

Consistent 2.2× speedup across two scales. Per-node: ~20 ns AoS vs
~9 ns SoA — saves ~11 ns per node.

## Real-world projection

Real kessel parse on typescript.js: ~450K AST nodes in ~45 ms parse.
SoA savings: ~5 ms per parse = **~11–15 % wall time**.

Profile of monaco shows ALLOC (10 %) + ~30 % of PARSE (~13 %) is
AST-construction-related — total ~23 % of CPU. Halving that yields
~11–12 % wall time. Lines up with the prototype measurement.

## Why this is different from previous failed predictions

Steps 1–4 (non-mutex arena, first-letter gate, byte-dispatch table,
inline tagged unions) all targeted *dispatch wrappers* around real
work. The CPU cycles spent in `arena_allocator_proc` /
`lookup_keyword_by_letter` / etc. were doing irreducible work (bump
pointer, capacity check, byte compare) — removing the wrapper saved
only the wrapper's overhead, not the work.

Step #5 (SoA AST) targets the **representation** itself:

* Per-node bytes written: ~80 B (CallExpression) → ~17 B (1 tag + 8
  data + 8 span). Less memory written = less work, full stop.
* Per-node allocs: 1 (bump pointer per node) → 0 (just an index
  increment in pre-allocated arrays).
* Cache locality: nodes scattered through arena → contiguous arrays.

The work itself is reduced, not just the wrapping. That's the
qualitative difference.

## Recommendation

Phase 2 (full SoA migration, ~3 weeks) is justified. Do it.
