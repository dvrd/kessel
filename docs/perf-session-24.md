# Session 24 — Tier 2 E refuted, lex side at architectural limits

> Date: 2026-04-29 (continuation of S23)
> Start state: kessel 0.990× OXC geo-mean (S23 final, `caps-bumped`)
> End state: **kessel 0.990× OXC geo-mean — unchanged**
> Tag: `s24-start` (= `caps-bumped`)

## TL;DR

Tier 2 E ("per-letter identifier handlers, OXC-style") and a derived
narrower variant ("ASCII-split lex_identifier") were both implemented,
benchmarked on the full suite, and **refuted**. Both produced regressions
or noise-level deltas, never the predicted 1–2 ms on monaco.

The lex hot path is at architectural limits in this codebase. The next
real wall-time win will come from data-layout work (Tier 3 F SoA AST,
~5 weeks, predicted 3–4 %) or from a deeper parser-side investigation
(`parse_unary_expr` is 8 % of monaco — see "Path forward" below).

## What we tried

### Variant 1 — full per-letter handlers (the architectural-analysis prediction)

**Hypothesis** (from `docs/perf-architectural-analysis.md` Tier 2 E):
OXC dispatches identifier-or-keyword scanning via 21 specialised
per-letter byte handlers (`L_A`, `L_B`, …, `L_Y`) that fuse identifier
scan + keyword classification into one pass. Kessel does these in two
phases (`lex_identifier` → `lookup_keyword_by_letter`). Replacing the
two-phase dispatch with a source-level `switch c` over the first byte
in `lex_token`, calling per-letter handlers, should fuse the work and
eliminate the second-level switch on `c0`.

**Implementation**: 19 keyword-letter handlers (`lex_ident_a`…`lex_ident_y`)
+ 1 generic `lex_ident_no_keyword` for letters with no keywords (`h, j,
m, p, q, x, z`, `A-Z`, `_`, `$`). Each handler called a shared
`lex_ident_ascii_body` helper that performs the SIMD scan and validation.
Tried both with `#force_inline` on every handler (and the helper) and
without.

**Measured (5-run median, big files only, N=60 iterations)**:

| File | S23 baseline | per-letter (`#force_inline`) | per-letter (regular calls) |
|---|---:|---:|---:|
| typescript | 1.04× | 1.06× | 1.07× |
| cesium | 1.05× | **1.12×** | **1.14×** |
| monaco | 1.05× | 1.11× | 1.11× |
| antd | 1.02× | 1.03× | 1.05× |
| jquery | 1.06× | 1.08× | 1.05× |
| preact | 0.89× | 0.97× | 0.98× |
| lodash | 1.06× | 1.06× | 1.05× |
| snabbdom | 0.81× | 0.85× | 0.81× |

Both variants **regressed** geo-mean by 1–4 pp. The `#force_inline`
variant is worst on big files; the regular-call variant is worst on
the very biggest (cesium +9 pp).

**Why it failed**:

* **`#force_inline` variant**: 20 handlers × the SIMD body-scan helper
  produces 20 copies of the body-scan code inside `lex_token`. The
  function body grows by several KB and overflows L1i on
  identifier-heavy files (cesium / monaco / typescript). The icache-miss
  cost dwarfs the dispatch saving.

* **Regular-call variant**: Each identifier pays one call+ret + register
  spill / save (handler signature is `(^Lexer, u32, u8) -> FastToken`).
  With identifiers being ~30–40 % of all tokens on monaco, that's
  millions of function calls per parse. Net wash → loss.

* **The deeper reason**: the existing architecture
  (`lex_identifier #force_inline → lookup_keyword_by_letter
  #force_inline`) is **already** doing per-letter dispatch implicitly.
  When LLVM inlines both, it sees `c` (loaded once in `lex_token`) and
  `c0 := src[start]` (loaded again in `lookup_keyword_by_letter`), CSEs
  the two loads, and specialises the keyword branch tree per first byte.
  The "two switches" we wanted to collapse are already collapsed by the
  optimizer. Explicit per-letter handlers are pure code-bloat for the
  same end result.

### Variant 2 — narrow ASCII-split (`lex_identifier_ascii` + `lex_identifier`)

**Hypothesis** (refined after Variant 1 failed): drop the per-letter
ambition, just specialise `lex_identifier` for the ASCII-first-byte
case. The current `lex_identifier` has a UTF-8 byte-count prologue
(`if first >= 0x80 { ... 4-way switch ... }`) that's wasted work on
ASCII identifiers. Splitting into `lex_identifier_ascii` (no UTF-8
prologue, pure ASCII path) and `lex_identifier` (unicode) should save
~8 wasted compares per identifier on the >99 % ASCII path.

**Implementation**: ~30 lines. Added `lex_identifier_ascii` as a sibling
proc, dispatched from `lex_token` via `if c < 0x80 { lex_identifier_ascii }
else { lex_identifier }` after `is_id_start_fast(c)`. Both `#force_inline`.

**Measured (5-run median, N=60 on big files)**:

| File | S23 baseline | ASCII-split |
|---|---:|---:|
| typescript | 1.034× | 1.044× |
| cesium | 1.060× | 1.048× |
| monaco | 1.046× | 1.046× |
| antd | 1.020× | 1.018× |

Within run-to-run noise (±1 pp on ratios). No reliable improvement.
Variance across runs was wider than the candidate effect, so even
favourable runs couldn't be trusted.

**Why it failed**: the `if first >= 0x80` branch in `lex_identifier`
is a >99 % taken-not-taken branch on JS/TS code. Modern branch
predictors handle it for free, and LLVM lays the cold UTF-8 path out
far enough that the icache impact is ~zero. The "wasted compares" we
hoped to eliminate are already pipelined into the shadow of useful
work by the OOO core. Savings are below measurement noise.

## What this tells us about the lex hot path

The combined evidence from S22 / S23 / S24 paints a clear picture:

* `bump_append` (S22, `d0eed4e`) — **−3 pp** in one commit. Removing the
  Odin runtime memmove from the per-append fast path was the only
  meaningful lex / parser memory-allocation win.

* Cap bumping at top 8 callsites (S23, `d2ec90b`) — **−1.2 pp**. Profile-
  guided. Eliminated 68 % of slow-path grow events on monaco.

* Scalar prefix before SIMD identifier scan (S22, `66958d3`) — **−1.7 pp**.

* `force_inline` `lookup_keyword_by_letter` (S22, `caf035e`) — **−0.4 pp**.

* Darwin CPU QoS pin (S23, `4e9efe3`) — bench-neutral (real-world hedge).

* **S24**: Per-letter handlers — regressed. ASCII-split — noise.

The wins came from removing **real work** (memmove calls, slow-path grow
events, SIMD setup overhead). The S24 attempts targeted **dispatch
overhead** that LLVM has already removed. There's no more fat to cut on
the lex side. The remaining 1.05× gap on monaco/cesium is
work-not-dispatch.

## Path forward

### Where the time still goes (monaco, fresh profile post-S23)

```
40 %  lex_token (incl. inlined lookup_keyword_by_letter)
 8 %  parse_unary_expr
 6 %  parse_expr_with_prec
 4 %  arena_free_all (inter-iter reset, EXCLUDED from bench timer)
 5 %  parse_binding_pattern + parse_primary_expr
 3 %  parse_left_hand_side_expr
 2 %  parse_arguments / parse_identifier / parse_variable_declaration
 ~30 % long tail (parse_class_element, parse_function_body, lex_string, …)
```

`lex_token` at 40 % is essentially irreducible work — byte-by-byte scan
of 6 MB of text. OXC pays the same per-byte cost; the only way to beat
them on this axis is to skip bytes (we already do via SIMD), and we're
parity there.

### Recommended next levers

1. **Investigate `parse_unary_expr` (8 %)** — half-day. A Pratt parser's
   unary handler should be small (prefix op + fallthrough to primary).
   8 % of 30 ms is 2.4 ms; even a 25 % cut would be 0.6 ms = 2 pp on
   monaco. Look for redundant lexer peeks, restart loops, or cold-path
   arms hot.

2. **Tier 3 F — SoA AST** (4–5 weeks, predicted 3–4 % wall time). Plan
   in `docs/dod-prototype-plan.md`, validated in
   `bench/dod_proto/proto2.odin`. The big bet.

3. **Tier 4 J — `vm_deallocate` arena reset cycle** (1 hour, macOS-only,
   real-world only). Saves the 4 % `arena_free_all` cost between parses
   in LSP / multi-file workflows. Bench-neutral but real-world-positive.

### Levers we can now retire from consideration

* Per-letter identifier dispatch (this session, `#force_inline` and
  regular-call variants).
* ASCII-split `lex_identifier` (this session).

Both are recorded here so the next agent doesn't relitigate.

## Save points

| Tag | State |
|---|---|
| `s24-start` (= `caps-bumped`) | S23 final — geo-mean 0.990× |
| `s24-end` | Identical to `s24-start` — no code commits |

No production code changed in S24. Only documentation.

## Honest assessment

S24 was a negative result: the planned Tier 2 E lever does not work in
this codebase, and the ASCII-split refinement is below noise. The
session's value is **narrowing the search**: two more architectural
hypotheses are off the table. Combined with S23's three failed
experiments and the broader S15–S22 history, the lex side of kessel is
demonstrably at architectural parity with OXC. Future wall-time wins
must come from the parser, the AST data layout, or workload-shape
optimisations (mmap, vm_deallocate) that the current bench harness
doesn't measure.

The 1.05× gap on cesium / monaco is small enough that it's within the
range of "OXC happens to have slightly better instruction scheduling on
the M-series core" — i.e. compiler-tooling-level rather than algorithmic.
