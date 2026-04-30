# Session 25 — Wave 0 result: Tier 3 F (SoA AST) refuted

> Date: 2026-04-30
> Start state: `s24-end` (= `s25-start`). Geo-mean ~0.93× OXC, all 10
> files beat OXC.
> End state: Tier 3 F refuted by validation prototype. No code shipped
> against `src/`. Two new prototype files in `bench/dod_proto/proto3*`.
> Tag: `s25-wave0-prototype-refresh`.

## TL;DR

Tier 3 F (full SoA AST migration) was queued as the only remaining
lever predicted to deliver >1 pp wall-time. Plan said 4–5 weeks of
work for predicted 3–4 % wall.

**Wave 0 (a 1-day prototype refresh) refuted the prediction.** The
S24 commits that pushed kessel below 1.00× OXC also closed the
AoS-side inefficiencies the original SoA prototype had measured
against. With realistic interleaved per-node work added, SoA wins
between 3 % and *loses* 2.5 % on the AST-construction subset — a
band that projects to ±0.5 pp wall. Five weeks of work for noise.

## Background — what the original prototype said

`bench/dod_proto/proto2.odin` was built in S22.3 (2026-04-29) when
kessel was at 1.064× OXC geo-mean. It compared two recursive
expression-tree builders using the same bump-pool primitive:

* AoS = pointer + Odin union (kessel's actual representation)
* SoA = Zig-AstGen-style parallel arrays (tags, data, spans, names)

Result: SoA was 9.3–11.8 % faster on pure tree construction.
Real-world wall projection: 3–4 %. README labelled it "borderline,
conditional go" — see `bench/dod_proto/README.md`.

## What changed between S22.3 and S25

Three S22-S24 commits closed exactly the AoS-side inefficiencies
the prototype had measured against:

| Commit | What it did | Effect on AoS-side |
|---|---|---|
| `d0eed4e` (S22) | `bump_append` `#force_inline` | Removed memmove call from per-append fast path; appends ~50× cheaper |
| `4fb90a5` (S24) | `LexerLoc :: distinct int` | Token shrunk 80 B → 64 B; per-token cost fell |
| `ee76e1f` (S24) | Gate `cur_lit_*` snapshot to literal-bearing tokens | Skips ~80 % of per-advance ~32 B snapshot work |

So the ~10 % SoA-vs-AoS gap measured in S22.3 was partly
"AoS-with-runtime-overhead" overhead, not a structural win for SoA.
With those overheads gone, the residual structural advantage of SoA
shrinks accordingly.

## Wave 0 measurement

### Step 1 — Refresh proto2 against current primitives

Re-ran `bench/dod_proto/proto2.odin` (no code change — primitives
already match production `bump_alloc`).

```
$ for i in 1..10; do bench/dod_proto/proto2 50 12 | grep "vs AoS"; done
SoA vs AoS/bump:  -7.4 %    (1.080x speedup)
SoA vs AoS/bump:  -7.1 %    (1.076x speedup)
SoA vs AoS/bump:  -8.3 %    (1.091x speedup)
SoA vs AoS/bump:  -8.8 %    (1.096x speedup)
SoA vs AoS/bump:  -7.8 %    (1.084x speedup)
…
median  -7.5 %
range   -5.8 to -8.8 %
```

Down from the prototype's -10 to -12 %. Exactly the erosion predicted
from the S22-S24 wins. **Right at the boundary of the gate model:**
≥ 8 % = Go, 4–8 % = Conditional, 0–4 % = Stop.

### Step 2 — Build proto3 with realistic interleaved work

`bench/dod_proto/proto3.odin` keeps the same recursive build pattern
as proto2 but adds per-node "other work" between AST allocations:

1. Source-byte read from a 1.7 MB corpus (simulates span lookup)
2. 8-byte string compare (simulates `lookup_keyword_by_letter`)
3. 64-byte token-shape write (simulates `advance_token` snapshot)
4. Light arithmetic (simulates span bookkeeping)

Compile-time toggles (`-define:SIM_NONE=true`,
`-define:SIM_LIGHT=true`) isolate which surrounding-work cost matters.

### Results (median of 10 runs at depth 12, 100 iter)

| Variant | SoA delta | Notes |
|---|---:|---|
| `SIM_NONE` (proto2-equivalent) | **−5.5 %** | Pure construction; matches proto2 |
| `SIM_LIGHT` (+ source-byte read) | **−3.0 %** | Half of the win disappears |
| Full sim (+ token-shape write) | **+2.5 %** | **SoA LOSES** |

The interleaved-work cache pressure halves the SoA win when only
source reads are added. Once token-shape writes are added — which
production's `advance_token` does on every token, even after the S24
gating — SoA flips from a win to a loss.

## Why does the win flip?

The structural advantage of SoA is **cache locality of the
representation arrays**. When you iterate `tags[]` you read 1 byte
per node sequentially. When you iterate AoS pointer chains you may
miss L1d.

But that locality benefit only applies if the rest of the working set
is small enough that the SoA arrays stay hot in cache. With realistic
per-token work writing 64 B to a token buffer adjacent to the AST
nodes, AoS keeps everything in one bump-pool stripe (high spatial
locality for "the children I just allocated"), while SoA has to keep
*five* parallel arrays hot simultaneously, plus the token buffer,
plus the source bytes.

In effect: SoA buys you locality on AST traversal but spends working
set during AST construction. When construction-time cache pressure
dominates (which it does in any realistic parser), AoS wins.

## Wall-time projection

AST construction is ~17 % of wall in current kessel:

* ALLOC ~10 % (from S22 profile)
* Half of parse_unary_expr (8 %) and parse_expr_with_prec (6 %) is
  AST construction = ~7 %

Production interleaved-work regime is between light-sim and full-sim:

| Regime | AST-subset Δ | × 17 % = wall Δ |
|---|---:|---:|
| Light-sim (best case) | −3 % | **−0.51 pp** |
| Mid (likely) | 0 % | **0 pp** |
| Full-sim (worst case) | +2.5 % | **+0.43 pp** |

The Wave 1 gate (defined in `docs/perf-session-25-plan.md`) was:

> ≤ −0.5 pp (faster) → Go; -0.5 to +0.5 → Conditional; ≥ +0.5 → revert

Best case is exactly at the gate. Likely case is no change. Worst
case is a regression. **The expected value of executing Tier 3 F is
zero.** Five weeks of work for noise.

## Decision: STOP Tier 3 F

Per the Wave 0 gate (≥8 % = Go, 4-8 % = Conditional, 0-4 % = Stop):

* Pure construction is now -5.5 %, in the **conditional** band
* Realistic interleaved is between -3 % and +2.5 %, mostly in the
  **stop** band
* Wall projection is at the noise floor

Not enough to justify 5 weeks of work touching ~14 K lines of
parser.odin, plus printer/raw-transfer/verifiers.

## What's still on the table after Wave 0

The S24 post-mortem listed three remaining levers. With Tier 3 F
refuted, the inventory shrinks:

1. **Tier 1 B — mmap source + MADV_SEQUENTIAL** (1 day, real-world
   only). Bench-neutral; saves 5–10 ms per cold-file parse.
   Real product win for LSP / build-tool workloads.

2. **Tier 4 J — `vm_deallocate` arena reset** (1 hour, macOS-only,
   real-world only). Bench-neutral; saves 5–8 ms per parse reset
   for multi-file workflows.

3. **More dead-state pruning on hot functions** (variable, profile-
   guided). Per the S24 post-mortem the methodology has a sharp
   threshold but isn't exhausted. Candidates that match the S24
   threshold (>1 % of profile + >50 % statically unreachable):
   * `parse_expr_with_prec` (6 % of profile) Pratt loop — read
     line-by-line for dead branches.
   * `parse_class_element` decorator path — large modifier switch on
     a hot path.
   * Anywhere `parse_*` hits >2 % of profile that we haven't audited.

4. **Specific function rewrites** — Pratt loop in
   `parse_expr_with_prec`, decorator handling in
   `parse_class_element`. More invasive than dead-state pruning but
   well-bounded vs. a 5-week SoA migration.

## Lessons from Wave 0

The S24 post-mortem said:

> The "obvious" architectural levers (per-letter handlers, SoA AST,
> mmap, vm_deallocate) are not where the wins are hiding.

Wave 0 confirms it — for SoA AST as well. The pattern across S22-S25:

1. **Architectural-prediction levers refute consistently.** OXC-style
   per-letter handlers, SoA AST, byte-dispatch tables, inline tagged
   unions — all promised single-digit-percent wins, all delivered
   noise or regressions.
2. **Profile-guided dead-state pruning consistently delivers** —
   when the call site is hot AND the work is statically dead.
3. **Validate predictions cheaply before committing**. Wave 0 cost
   1 day. Tier 3 F would have cost 5 weeks. The asymmetry is the
   whole reason to validate.

## Save points

| Tag | State |
|---|---|
| `s25-start` (= `s24-end`) | Geo-mean ~0.93×, all 10 files beat OXC |
| `s25-wave0-prototype-refresh` | Proto3 added, Tier 3 F refuted, no `src/` change |

## Files added / changed

| File | Change |
|---|---|
| `bench/dod_proto/proto3.odin` | New: interleaved-work prototype with `SIM_NONE` / `SIM_LIGHT` toggles |
| `bench/dod_proto/proto3` | Built binary (committed for reproducibility) |
| `bench/dod_proto/README.md` | Appended v3 results section |
| `docs/perf-session-25-plan.md` | Already in tree from Wave 0 setup |
| `docs/perf-session-25-wave0.md` | This doc |

`src/` not touched. `tests/` not touched. All 10 conformance gates
remain green by virtue of zero production code change.

## Recommendation for next session

The honest current state of kessel is **architecturally complete**:

* All 10 bench files beat OXC.
* Geo-mean 0.93×, worst case 1.00× (jquery, noise floor).
* Both predicted multi-week levers (per-letter handlers, SoA AST)
  have been refuted at validation.
* Profile-guided dead-state pruning is the only methodology that
  has consistently paid, and it has a sharp threshold the codebase
  may have already hit.

Realistic next-session ROI:

| Lever | Effort | Expected | Surface |
|---|---|---|---|
| Mmap source (Tier 1 B) | 1 day | 5–10 ms cold-file real-world | LSP / build tools |
| vm_deallocate cycle (Tier 4 J) | 1 hour | 5–8 ms per reset real-world | Multi-file flows |
| Profile-guided audit of `parse_expr_with_prec` | 1 day | 0–2 pp on big files | Bench |
| Profile-guided audit of `parse_class_element` | 1 day | 0–1 pp | Bench |
| Bench baseline relock | 1 hour | Tightens regression gate | Infra |

The first two are real product wins (not bench wins). The third and
fourth are last-pass dead-state hunts on functions we haven't yet
opened to the S24 methodology.

If the goal is "ship a polished kessel," shifting from chasing more
bench pp to **product polish** (mmap, vm_deallocate, bench relock,
maybe an LSP harness) is probably the higher-leverage move.

## Honest assessment

S25 ended where it began on bench numbers. But it answered a question
that was hanging over the project for a month: **is Tier 3 F worth
the 5 weeks?** Answer: no, not after S22-S24's wins.

That's a clean negative result, exactly what Wave 0 was designed to
produce. The S24 post-mortem and this doc together close out the
"obvious architectural levers" inventory. Future perf work needs a
different paradigm.
