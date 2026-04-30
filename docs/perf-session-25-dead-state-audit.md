# Session 25 — Dead-state audit (`parse_expr_with_prec` + 7 friends)

> Date: 2026-04-30
> Tag: `s25-dead-state-audit-complete`
> Verdict: no candidate cleared the S24 threshold; no production code
> changed.

## Methodology

S24 established: "(a) hot call site (>1 % of profile) AND (b) >50 % of
the work statically unreachable" is the threshold for dead-state
pruning to deliver measurable wins on this codebase.

Captured a fresh post-S24 profile of `monaco.js`:

```bash
$ samply / sample post-build kessel-prof:
  704 lex_token              41.5 %
  165 parse_unary_expr        9.7 %
  119 parse_expr_with_prec    7.0 %
   59 parse_primary_expr      3.5 %
   51 parse_left_hand_side    3.0 %
   38 parse_arguments         2.2 %
   31 parse_variable_decl     1.8 %
   27 parse_identifier        1.6 %
   26 parse_class_element     1.5 %
   25 parse_binding_pattern   1.5 %  (down from 3.8 %, post-cc72af8)
```

Audited each of the top 8 (`>1 %`) for clear staticness arguments.

## Per-function findings

### `parse_unary_expr` (9.7 %)

Identifier hot path body is six gated string-compares before the
identifier construction:

* `report_escaped_reserved_word(p)` — early-returns on `!has_escape`
  (~99 % of identifiers have no escape)
* `if p.strict_mode { is_strict_reserved_word(cur_type) ||
  is_strict_reserved_name(value) }` — strict_mode is per-file (file
  branch-predictor-friendly); `is_strict_reserved_name` has a
  first-letter `i`/`p` gate
* `has_escape && value == "async"` — escape-gated
* `in_static_block && value == "arguments"` — static-block-gated
  (rare)
* `has_escape && value == "await" && await_is_reserved_here(p)` —
  escape-gated

None has a >50 % statically-unreachable claim. Each gate is already
the tight version. **No win.**

### `parse_expr_with_prec` (7.0 %)

Three candidates examined:

1. **`for is_token(p, .As) || is_token(p, .Satisfies) { ... }`** —
   line 8318, 13 samples (0.77 % of total). Fires on every call. The
   `.As` and `.Satisfies` tokens are emitted by the lexer regardless
   of `lang` (the lexer doesn't see lang). Gating the loop on
   `allow_ts_mode(p)` would:
   * Save 2 token compares per call on JS files (~7 of 10 fixtures).
   * **Change AST output**: kessel currently parses `a as b;` in
     `.js` mode as a TSAsExpression. Verified vs OXC: OXC also emits
     a TSAsExpression but reports 1 parse error; kessel emits the
     same node and reports 0. Gating breaks both behaviors (kessel
     would emit `a` + an unexpected-token error instead).
   * Below the 1 % threshold by single-line attribution, even ignoring
     the AST behavior change.

2. **Top-of-call yield-as-LHS check** (lines 8275-8316). One tag-load
   + compare per call. Already cheap; no >50 % unreachable claim.

3. **`if cur_type == .Pow && left != nil`** (line 8434). Fires only
   when current token is `**`. Statically dead for ~99 % of binary
   operators. But the cost on the dead path is 1 compare; pruning
   saves a single compare per call to parse_expr_with_prec.

**No clear win that matches the S24 threshold.**

### `parse_primary_expr` (3.5 %)

A 30+ way `#partial switch` on `current.type`. Each case does real
work for that token type. The switch itself is jumped via a
compiler-generated table; each case is reachable depending on input.
**No dead state.**

### `parse_left_hand_side_expr` (3.0 %)

5-line wrapper around `parse_primary_expr` + `parse_lhs_tail`. All
time is in callees. **No body to prune.**

### `parse_arguments` (2.2 %)

Hot lines in profile cluster at 10817 (function entry, `expect_token(.LParen)`),
10862 (comma-elision check), 10864 (eat for stray comma), 10868
(`is_token(.Dot3)` for spread), 10874 (parse_assignment_expression
for spread arg).

The comma-elision check `if is_token(p, .Comma) { report_error... }`
fires on every iteration but is a single compare. The spread check
`if is_token(p, .Dot3)` is a single compare; `Dot3` happens in ~5 %
of arg positions. **No >50 % dead claim.**

### `parse_variable_declaration` (1.8 %)

Hot lines distributed across declarator parsing (line 4736 = the
`make([dynamic]VariableDeclarator, 0, 4, ...)`, 6488 = report_*
helpers near the bottom). The function dispatches on `cur_type`
(.Var/.Let/.Const/.Using/.Await) but each case is a simple
assignment, not a hot loop. **No dead state.**

### `parse_identifier` (1.6 %)

A single-token consumer + Identifier node alloc. The body is small;
no waste. **Nothing to prune.**

### `parse_class_element` (1.5 %)

The modifier-scan loop (lines 4061-4106) runs once per class element
to capture `static`, `public`, `private`, `protected`, `readonly`,
`abstract`, `override`. For a typical JS class member like
`foo() {}`:
* Iter 1: cur=`.Identifier`, nxt=`.LParen` → `is_member_start = true`
* Loop breaks immediately

Cost: 6 cycles. No win.

For TS members like `static foo: T`:
* Iter 1: consumes `.Static`
* Iter 2: breaks on `is_member_start`

Real work, not dead state.

The decorator path (`parse_decorators`) runs only when `@` appears
before the class element — bound to <1 % of class members on the
corpus. **No dead state.**

## Cross-cutting observations

Two patterns explain why the audit came up empty:

1. **The S24 commits compounded.** `cc72af8` (the
   parse_binding_pattern enum-only check) was the LAST big dead-
   state pruning available because the lexer's per-token-type
   discrimination feeds a small handful of "likely-keyword" branches,
   not many. After we removed the 36-way switch, the remaining
   per-identifier checks were already tight (gated on `has_escape`,
   `in_static_block`, etc.).

2. **The parser is doing real work.** A Pratt parser for
   ECMAScript+TS+JSX is fundamentally a multi-way dispatch over
   token types. Each branch encodes a real grammar rule. Most of
   what looks like "dead" at first glance turns out to be a check
   for a real edge case (yield-as-LHS, Pow-after-unary, As/Satisfies
   in TS mode, comma-elision in args, etc.).

The S24 post-mortem already predicted this:

> Future audits should require BOTH (a) a hot call site (>1 % of
> profile) AND (b) a clear staticness argument that >50 % of the
> work is unreachable.

Of 8 candidates audited, **0 cleared (b)**. The methodology has hit
its threshold on this codebase.

## What's next

Per the S25 plan, polish phase:

1. **Tier 1 B — mmap source + MADV_SEQUENTIAL** (1 day, real-world
   only). Bench-neutral; saves 5–10 ms per cold-file parse for
   LSP / build-tool workloads.

2. **Tier 4 J — `vm_deallocate` arena reset cycle** (1 hour,
   macOS-only, real-world only). Bench-neutral; saves 4–7 ms per
   parse reset for multi-file flows.

3. **Bench baseline relock** (1 hour). The session-20 baseline at
   `tests/baselines/bench_baseline.json` predates S22-S24 wins.
   Relocking tightens the regression gate.

Both Tier 1 B and Tier 4 J are **product wins, not bench wins** —
they help real users without showing on `bench:quick`. The discipline
of the past two sessions said "ship product polish, don't chase noise."

## Save points

| Tag | State |
|---|---|
| `s25-start` (= `s24-end`) | Geo-mean ~0.93×, all 10 files beat OXC |
| `s25-wave0-prototype-refresh` | Tier 3 F refuted via proto3 |
| `s25-dead-state-audit-complete` | 8 hot functions audited, no candidates cleared the S24 threshold; no `src/` change |
