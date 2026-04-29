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

---

## Update: v2 prototype with fair AoS (2026-04-29)

The v1 prototype compared `mem.virtual.arena_allocator` (slow path with
mutex + vtable) against pre-allocated SoA buffers. That was **unfair to
kessel's actual implementation**: kessel uses a custom `bump_alloc`
pool for AST nodes that's just pointer arithmetic, not the slow arena
path.

`bench/dod_proto/proto2.odin` reruns the comparison with both AoS and
SoA using the SAME bump-pool primitive:

```
$ ./bench/dod_proto/proto2 30 10
AoS/bump  med=3411 us
SoA       med=3008 us
SoA vs AoS/bump: -11.8 % time  (1.134× speedup)

$ ./bench/dod_proto/proto2 20 12
AoS/bump  med=15494 us
SoA       med=14060 us
SoA vs AoS/bump: -9.3 % time  (1.102× speedup)
```

**SoA is ~10–12 % faster than fair-AoS, not 2.2×.** The 2.2× from v1 was
the arena-vtable overhead, not SoA's structural advantage.

### Real-world projection (revised)

AST construction in kessel is ~25–30 % of parse CPU (sum of ~20 % of
PARSE + most of ALLOC). SoA being 10–12 % faster on that subset
projects to **~3–4 % wall-time savings** on real fixtures.

That's notable but smaller than the 12 % originally predicted. Step #5
delivers a real but modest improvement, not a dramatic one. Combined
with the architectural cleanup (smaller AST, simpler serialization,
no `raw_transfer.odin` pointer-rewrite logic), it remains worthwhile —
but the cost/benefit is borderline.

### Updated decision gate

| Δ AoS/bump → SoA | Action |
|---|---|
| ≥ 15 % | Strong go |
| 8 – 15 % | Conditional go (we're here, ~10 %) |
| 0 – 8 % | Stop |
| Negative | Stop + document |

Borderline. Wave 1 of Phase 2 will be a real test: if migrating
Identifier + Member + Call + Binary delivers ~3 % wall time on real
fixtures, scale up; if not, stop and ship at 1.064×.
