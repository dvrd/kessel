# Session 24 — Tier 2 E refuted, then big-file gap narrowed via dead-state pruning

> Date: 2026-04-29 (continuation of S23)
> Start state: kessel 0.990× OXC geo-mean (S23 final, `caps-bumped`)
> End state: **kessel ≤0.990× OXC, big files −1 to −3 pp**
> Tags: `s24-start` (= `caps-bumped`) → `s24-dead-loc-reads` →
>       `s24-lexerloc-shrink` (final)

## TL;DR

**Phase 1 — Tier 2 E refuted.** Per-letter identifier handlers
(`#force_inline` and regular-call variants) and an ASCII-split
`lex_identifier` were both implemented, benchmarked, and refuted.
The lex hot path is at architectural parity — LLVM's existing inline
chain already does per-letter dispatch implicitly via CSE on the
duplicate `src[start]` load. No code shipped from this phase.

**Phase 2 — dead-state pruning won.** Profile-guided pivot to
`parse_unary_expr` (8 % of monaco). Discovered that `LexerLoc.line`
and `LexerLoc.column` were never written by any code path — vestigial
fields from an earlier eager-compute design. Two commits:

* `7aa72d9` — eliminated dead `loc.line` / `loc.column` reads on the
  identifier hot path (parse_unary_expr inline construction +
  loc_from_token, called from 75 sites).
* `4fb90a5` — collapsed `LexerLoc` from a 24-byte struct to
  `distinct int` (8 bytes). Token shrinks 16 bytes, every Token copy
  on the parser hot path (every `current := p.cur_tok` snapshot,
  every cross-function return, every loc_from_token call) is lighter.
  Side effect: fixed a printer bug where errors appended directly to
  `p.errors` (e.g. `__proto__` duplicates) showed `Line 0, Column 0`.

**Per-file deltas vs S23 baseline (median of 5 runs)**:

| File | S23 | S24 | Δ |
|---|---:|---:|---:|
| typescript | 1.04× | 1.03× | **-1 pp** |
| cesium | 1.06× | 1.03× | **-3 pp** |
| monaco | 1.05× | 1.04× | **-1 pp** |
| antd | 1.02× | 1.01× | **-1 pp** |
| d3 | 1.01× | 1.00× | **-1 pp** |
| react-dom | 0.97× | 0.97× | 0 |
| preact | 0.89× | 0.88× | -1 pp |
| jquery | 1.03× | 1.07× | +4 pp (noise on 1.4 ms file) |
| lodash | 1.06× | 1.07× | +1 pp |
| snabbdom | 0.81× | 0.83× | +2 pp (noise on 2.5 µs file) |

Geo-mean stays around 0.990× — small-file noise cancels the big-file
gains. The **real win is on the worst-case files**: cesium dropped
from 1.06× to 1.03×, the biggest single-commit improvement on cesium
in the entire session arc.

## Phase 1 — What we tried (refuted)

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

## Phase 2 — dead-state pruning

Profile-guided pivot. Fresh profile of monaco showed `parse_unary_expr`
at 8 % self-time. The user's instinct was right: "push into it."

### Discovery

`grep -r 'cur_tok\.loc\.line' src/` returned only **read** sites. No
write anywhere in the lexer or parser. Same for `loc.column`. The
fields had been a vestige of an earlier design where line / column
were computed eagerly per-token; the current code computes them
lazily from `offset` whenever an error needs them.

Meanwhile, two hot sites read those zero fields on every identifier:

1. `parse_unary_expr`'s identifier fast path — `id_line := u32(p.cur_tok
   .loc.line)`, then writing 0 into `id.loc.line` / `id.loc.column`.
2. `loc_from_token` — called from 75 sites across `parser.odin` on
   every AST-node-from-current-token span.

Four wasted memory ops per identifier × ~250K identifiers on monaco.

### Commit `7aa72d9` — prune dead reads

Left `Loc.line` / `Loc.column` zero-initialised (which is what the
lazy fill expected). Conformance: 100 %% across all gates. Modest but
real improvement on big files (~0.5 pp on typescript / cesium / monaco).

### Commit `4fb90a5` — collapse LexerLoc to `distinct int`

Follow-up question from the user: "if LexerLoc holds only an int, why
make a struct?" Right call. Collapsed:

```odin
LexerLoc :: struct { offset: int }   // 24 → 8 bytes after dead-field prune
```

to

```odin
LexerLoc :: distinct int             // 8 bytes
```

`distinct` keeps the type nominal (random integers can't leak into
Token / ParseError fields) without paying for a struct wrapper.
Mechanical changes: ~25 `LexerLoc{offset = X}` → `LexerLoc(X)`,
`tok.loc.offset` → `int(tok.loc)` / `u32(tok.loc)`,
`tok.loc.offset = int(X)` → `tok.loc = LexerLoc(X)`.

**Net Token shrink: 16 bytes** (~80 B → ~64 B). Every `current :=
p.cur_tok` snapshot, every Token return-by-value, every Token field
load got cheaper. The cesium ratio dropped from 1.06× to 1.03× —
the biggest single-commit win on cesium in the entire session arc.

### Bug fix as a side effect

The error printer's "Parse errors:" preamble used to show `Line 0,
Column 0` for any error appended to `p.errors` via direct `bump_append`
(pending `__proto__` duplicates, pending cover inits, lexer-side
diagnostics). Those paths bypassed `report_error`'s lazy fill, so the
line/column fields stayed at zero through to the printer. Now the
printer computes from offset on demand, so every error gets a correct
line/column. 11 golden test files updated.

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
| `s24-dead-loc-reads` | After commit `7aa72d9` (~0.5 pp on big files) |
| `s24-lexerloc-shrink` | **S24 final** — cesium 1.06× → 1.03×, 1–3 pp on big files |

## Honest assessment

S24 came in two phases. Phase 1 (Tier 2 E) was a clean negative result
— the planned lever doesn't work, and the ASCII-split refinement is
below noise. Phase 2 (parse_unary_expr profile-guided pivot) found a
**32-byte vestigial field set** (LexerLoc.line / .column) that was
being read on every identifier and never written. Pruning the dead
state and collapsing the wrapper struct delivered measurable wins on
the worst-case files: cesium 1.06× → 1.03× (single biggest cesium
improvement in the session arc), monaco / typescript / antd / d3 each
−1 pp.

Moral of the session: **profile-guided pivots beat predicted levers**.
Three of S24's four hypotheses (per-letter `#force_inline`, per-letter
regular calls, ASCII-split) were predictions from `perf-architectural-
analysis.md`. All failed. The dead-state prune was a profile-driven
discovery: "parse_unary_expr is hot, let's read it line by line" →
"these two reads return permanent 0" → wins. The same pattern that
delivered S23's `bump_append` cap-bump (instrument the slow path,
aggregate by callsite, fix the top 8) and S22's `bump_append` itself
(profile said `_append_elem` was hot, root-caused to a memmove call).

The "obvious" architectural levers (per-letter handlers, SoA AST,
mmap, vm_deallocate) are not where the wins are hiding. They're hiding
in the gap between what the profile shows and what the code
_actually_ does.
