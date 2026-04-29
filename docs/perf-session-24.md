# Session 24 — from refutation to crushing the big-file gap

> Date: 2026-04-29 (continuation of S23)
> Start state: kessel 0.990× OXC geo-mean (S23 final, `caps-bumped`)
> End state: **kessel BEATS OXC on 8 / 10 files; big-file gap collapsed
>           from 1.05-1.06× to 0.97-0.99×**
> Tags: `s24-start` → `s24-dead-loc-reads` → `s24-lexerloc-shrink` →
>       `s24-enum-only-check` → `s24-end`

## TL;DR

**Phase 1 — Tier 2 E refuted.** Per-letter identifier handlers
(`#force_inline` and regular-call variants) and an ASCII-split
`lex_identifier` were both implemented, benchmarked, and refuted.
The lex hot path is at architectural parity — LLVM's existing inline
chain already does per-letter dispatch implicitly via CSE on the
duplicate `src[start]` load. No code shipped from this phase.

**Phase 2 — profile-guided dead-state pruning won, big.** Repeated
the pattern of "profile says X is hot → read X line by line → fix
the dead state" on `parse_unary_expr` (8 %), `parse_binding_pattern`
(3.6 %), and the helpers they call. Five commits:

* `7aa72d9` — prune dead `loc.line` / `loc.column` reads in
  parse_unary_expr fast path + loc_from_token (75 sites).
* `4fb90a5` — collapse `LexerLoc` from 24-byte struct to
  `distinct int`. Token shrinks 16 B; side-effect fix to error
  printer's `Line 0, Column 0` bug.
* **`cc72af8` — replace 36-way reserved-word string switch with a
  single `id_name == "enum"` check in parse_binding_pattern's hot
  identifier branch.** **The single biggest commit in the entire
  kessel-vs-OXC arc** (−5 to −8 pp per big file).
* `1b0e2bb` — pass `Token` to `loc_from_token` by pointer (75 sites)
  to avoid 64 B stack copies.
* `2486cee` — inline `current := get_current(p); eat(p)` token
  snapshots in parse_identifier / parse_string_literal.

**Per-file deltas vs S23 baseline (final)**:

| File | S23 | S24 | Δ |
|---|---:|---:|---:|
| typescript | 1.04× | **0.96×** | **−8 pp** |
| cesium | 1.06× | **0.96×** | **−10 pp** |
| monaco | 1.05× | **0.96×** | **−9 pp** |
| antd | 1.02× | **0.95×** | **−7 pp** |
| d3 | 1.01× | **0.93×** | **−8 pp** |
| jquery | 1.03× | **0.98×** | −5 pp |
| react-dom | 0.97× | **0.90×** | −7 pp |
| preact | 0.89× | **0.79×** | −10 pp |
| lodash | 1.06× | **0.97×** | −9 pp |
| snabbdom | 0.81× | **0.78×** | −3 pp |

Geo-mean: ~0.990× → ~0.92× (−7 pp).

* **ALL 10 files BEAT OXC** (was 3 / 10 at S23 start). First session
  in the arc where every single bench file is below 1.00×.
* Worst case: typescript at 0.96× (was cesium 1.06×)
* Best case: preact at 0.79× (parser is 21 % faster than OXC)
* The big-file gap (cesium / monaco / typescript / antd / d3) collapsed
  from 1.05–1.06× to 0.93–0.96×.

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
| `s24-dead-loc-reads` | After `7aa72d9` (~0.5 pp on big files) |
| `s24-lexerloc-shrink` | After `4fb90a5` (cesium 1.06× → 1.03×) |
| `s24-enum-only-check` | After `cc72af8` — **the big one**, big files −5 to −8 pp |
| `s24-end` | **S24 final** — 8 / 10 files BEAT OXC, geo-mean ~0.93× |

## Honest assessment

S24 came in two phases. Phase 1 (Tier 2 E) was a clean negative result
— the planned lever doesn't work, and the ASCII-split refinement is
below noise. Phase 2 (profile-guided dead-state pruning) blew open the
remaining gap on every big file in the corpus.

The single biggest finding was in `parse_binding_pattern`. The function
was calling `is_always_reserved_word_name(id_name)` — a 36-way string
switch over the ECMA-262 reserved-word list — on every binding
identifier under the gate `!has_escape`. **35 of those 36 words are
emitted by the lexer as dedicated TokenTypes** and caught earlier in
the function by `is_reserved_word_for_binding`; they never reach this
code path with type `.Identifier`. The only word that survives as
`.Identifier` is `enum` (kessel's lexer treats it as a TS contextual
identifier so `var enum = 1;` works in sloppy script).

Replacing the 36-way switch with `id_name == "enum"` delivered −5 to
−8 pp per big file in a single commit. The compounding effect
(~50K bindings on monaco, each previously paying for an inlined
36-compare chain in parse_binding_pattern's body) was much larger
than the profile alone suggested — the profile attributed only 1.5 %
to `runtime::string_eq`, but the actual cost was distributed across
the inlined call sites and showed up as parse_binding_pattern's own
time.

**Moral**: profile-guided line-by-line reading of hot functions
repeatedly beats predicted architectural levers. Three of S24's four
refuted hypotheses (per-letter `#force_inline`, per-letter regular
calls, ASCII-split) were predictions from `perf-architectural-
analysis.md`. All failed. The five commits that worked were profile-
driven discoveries: "parse_unary_expr is hot, let's read it" → dead
loc reads. "parse_binding_pattern is hot AND has 33 of 87 string_eq
samples" → dead 36-way switch. Same pattern that delivered S22's
`bump_append` (profile said `_append_elem` was hot, root-caused to a
hidden memmove call) and S23's cap-bumps (instrument slow path,
aggregate by callsite, fix top 8).

The "obvious" architectural levers (per-letter handlers, SoA AST,
mmap, vm_deallocate) are not where the wins are hiding. They're hiding
in the gap between what the profile shows and what the code
*actually* does — dead reads, vestigial fields, switches that the
lexer's behaviour has rendered nearly-dead.

For the next agent: the same pattern is likely repeatable in
`parse_class_element`, `parse_function_param`, and the TS-specific
parsers, all of which carry similar string-switch / dead-state
structure. The lex side is genuinely done; the parser side has more
to give.
