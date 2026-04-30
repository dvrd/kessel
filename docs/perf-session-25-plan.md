# Session 25 plan — Tier 3 F (SoA AST migration)

> Date: 2026-04-30
> Start state: s24-end (=`s25-start`). Geo-mean ~0.93× OXC, all 10 files
> beat OXC, worst is jquery 1.00× (wall noise) / typescript-cesium-monaco
> 0.97×.
> Goal: validate then execute the SoA AST migration. Only remaining
> lever predicted to deliver >1 pp.

## TL;DR

Three phases with hard decision gates between each.

| Phase | Effort | Decision gate | Action on fail |
|---|---|---|---|
| **Wave 0 — refresh prototype** | 1 day | SoA ≥ 8 % vs current bump-pool AoS in isolated bench | Stop, document, skip Tier 3 |
| **Wave 1 — Identifier-only in tree** | 1 week | Real-world geo-mean improves ≥ 0.5 pp on big files | Revert wave, document, stop |
| **Waves 2-5 — full migration** | 4 weeks | Each wave ≥ 0.3 pp incremental | Stop at last green wave |

## Why Wave 0 first (the honest math)

The prototype validation in `bench/dod_proto/proto2.odin` (S22.3,
2026-04-29) measured **SoA = 10.2 % faster than fair-AoS/bump** on
isolated expression-tree construction. From that, real-world wall-time
projection was 3–4 %.

That measurement was taken when kessel was at **1.064× OXC**. Since
then, three commits closed parts of the gap that SoA was supposed to
close:

* `d0eed4e` (S22) `bump_append` made dynamic-array appends ~50× cheaper
  by stopping the runtime memmove call. That was the AoS-side
  inefficiency the prototype was measured against.
* `4fb90a5` (S24) collapsed `LexerLoc` to `distinct int`, shrinking
  Token by 16 B. Tokens feed AST construction; their cost is now lower.
* `ee76e1f` (S24) gates `cur_lit_*` snapshots to literal-bearing tokens
  only — skips ~80 % of per-advance snapshot work that the prototype
  did not model.

The prototype has not been re-run against a kessel with these wins.
**Until it is, the 3–4 % wall projection is stale.** The S24 post-mortem
explicitly downgraded Tier 3 F from "predicted 3–4 %" to "the only
remaining lever expected to deliver >1 pp" — emphasis on the lower
bound.

The cost of being wrong is **~5 weeks of work**. The cost of running
Wave 0 is **~1 day**.

## Wave 0 design (1 day)

Rerun a prototype with **current** primitives, against a more
representative load:

1. **Refresh `bench/dod_proto/proto2.odin`** — confirm or re-measure
   the AoS/bump → SoA delta on the synthetic expression load. Use the
   exact `bump_alloc` / `bump_append` primitives currently in
   `parser.odin`.
2. **Add `proto3.odin`** that includes a representative parser-mix
   load: lex bytes → token stream → build expression subtree → walk
   for JSON-shape serialization. The prototype's pure-construction
   model overstates the SoA win because it excludes the per-token cost
   that Token/Loc shrinks already paid.

Decision gate (median of 30 iters, big synthetic input):

| AoS/bump → SoA Δ | Action |
|---|---|
| ≥ 8 % | **Go**: full migration justified, update HANDOFF and proceed to Wave 1 |
| 4–8 % | **Conditional**: run Wave 1 (Identifier-only) as the real test; abort if real-world Δ < 0.5 pp |
| 0–4 % | **Stop**: ship at s24-end, document in HANDOFF, archive Tier 3 F |
| Negative | **Stop + document** as another disproved-after-baseline-shift hypothesis |

## Wave 1 design (1 week, only on Wave 0 GO/CONDITIONAL)

**Scope: Identifier nodes only.** Single node type. Highest count
(~40 % of all expression nodes per prototype stats). Simplest shape
(no children, just a name).

The plan is *parallel* representations:

* New file `src/dod_ast.odin` defining `SoaAst` (tags / data / spans /
  names / extra arrays) and helpers (`soa_alloc_node`, etc.).
* Add `SoaRef :: distinct u32` and a single `SoaRef` arm to the
  `Expression` union in `ast.odin`. The `SoaRef` carries an index;
  the consumer reads the tag from `SoaAst.tags[idx]` to discriminate
  per-node-type.
* Convert ONLY the parse path that produces `^Identifier` to write
  `SoaRef` instead. (`parse_identifier`, plus the inlined snapshots in
  `parse_unary_expr` etc. — ~6 sites.)
* Update consumers (printer in `main.odin`, `raw_transfer.odin`) to
  handle the `SoaRef` arm.
* Run all 10 conformance gates.
* Bench against s24-end.

Decision gate (geo-mean of 5-run median across 10 fixtures):

| Δ vs s24-end | Action |
|---|---|
| ≤ -0.5 pp (faster) | **Go**: scale to Wave 2 |
| -0.5 to +0.5 pp | **Conditional**: run Wave 2 once; if also flat, stop |
| ≥ +0.5 pp (slower) | **Revert wave, document, stop** |

## Why Identifier first, not all four together

The original plan said "Wave 1: Identifier + Member + Call + Binary."
After S24's discipline lessons, that's too aggressive for the first
in-tree validation:

* Each additional node type roughly doubles the surface area touched
  per wave (parser sites + printer arms + raw-transfer arms +
  verifier touches).
* If Wave 1 fails, we want to be able to revert one commit, not four.
* Identifier has no children → no `SoaRef`-vs-`^Expression` ambiguity
  in the union arms it points to. It's the cleanest possible test of
  the storage-layer change.

## Out of scope for S25

* Tier 1 B (mmap source) — real-world only, won't show in bench.
* Tier 4 J (vm_deallocate cycle) — same.
* Tier 1 C (`ParseList(T)`) — the predicted ROI shrank to ~0.3 ms
  after S24 wins; revisit only if Wave 0 stops Tier 3.

## Save points planned

* `s25-start` (= `s24-end`) — clean baseline
* `s25-wave0-prototype-refresh` — after Wave 0 measurement (regardless
  of outcome) so the next agent has the data
* `s25-wave1-identifier-only` — first in-tree commit; revert target if
  Wave 1 fails
* `s25-wave1-end` — after Wave 1 measurement
* `s25-end` — terminal state of S25

## Open questions for the user

1. **Sign off on the Wave 0 → Wave 1 → Waves 2-5 gating model**, or
   different gates?
2. **Identifier-first or original four-type Wave 1?** I'm proposing
   single-node-type to bound revert blast.
3. **Acceptable bench variance for the gates.** I've used 0.5 pp; that's
   roughly 2× the run-to-run noise observed across S24. Tighter (0.3 pp)
   means more measurement runs per gate; looser (1.0 pp) means we might
   ship a wash.

Default if no answer: proceed with the plan above. Wave 0 starts now.
