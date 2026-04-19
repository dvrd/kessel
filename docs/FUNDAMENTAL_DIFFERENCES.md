# Fundamental Differences vs OXC

Last updated: 2026-04-19

This document tracks the current investigation into why Kessel remains much slower than OXC in parse-only microbenchmarks even after major CLI/output wins.

## Current state

Known from measured data on `kessel/bench_large.js`:

- CLI gap improved a lot from compact output + JSON escaping work.
- Pure parse gap remains large.
- `profile-parser` still attributes most in-process time to parser+AST work rather than lexing.
- Token traffic reductions helped, but did not change the shape of the gap.

That means the remaining gap is probably structural, not just a handful of extra checks.

## Working hypotheses

Priority order right now:

1. **AST construction / layout**
2. **Parser control flow / branch density**
3. **Compiler codegen + bounds-check elision**
4. **Allocator model / locality**
5. **Lexer** (still relevant, but no longer the main suspect)

## Current evidence snapshot

Measured on this branch:

- `./kessel_bin profile-layout`
  - `lexer.Token`: **96 B**
  - `lexer.CompactToken`: **16 B**
  - `ast.Expression`: **256 B**
  - `ast.Statement`: **16 B**
  - `ast.MemberExpression`: **56 B**
  - `ast.CallExpression`: **88 B**
  - `ast.FunctionExpression`: **248 B**
- `./kessel_bin profile-parser kessel/bench_large.js --iterations 5`
  - parser-estimated share: **74.2%**
  - AST node allocs: **135,591**
  - AST node bytes: **15.8 MB**
  - expression wrappers: **41,802** = **10.7 MB**
  - statement wrappers: **16,028** = **256 KB**
  - estimated wrapper byte share: **69.3%**
- `ITERS=10 bash kessel/bench_structural.sh`
  - string-heavy: **3.88×** slower than OXC
  - expr-heavy: **4.78×** slower
  - class-heavy: **5.28×** slower
  - object-heavy: **5.57×** slower
  - member-chain-heavy: **6.56×** slower
  - destructuring-heavy: **9.93×** slower

Interpretation so far:

- AST representation is very likely a primary factor: the `ast.Expression` union is large, and wrapper bytes alone dominate profiled AST allocation volume.
- String-heavy syntax is comparatively much closer to OXC than destructuring/member-heavy syntax.
- The worst gaps cluster around syntax that creates many wrappers / identifiers / nested structure, not around string scanning.

## New instrumentation in-tree

### 1) `profile-parser`

Now reports more attribution data from one profiled parse sample:

- total AST node allocations
- total allocated AST bytes (sum of `size_of(T)` for profiled node allocs)
- wrapper counts for `ast.Expression` and `ast.Statement`
- hot node counts:
  - identifiers
  - member expressions
  - call expressions
  - binary expressions
  - logical expressions
  - properties
  - object expressions
  - array expressions
- wrapper byte share estimate
- compact token size vs legacy token size

This is not a true allocator flamegraph, but it gives a cheap first-pass answer to:

- how much allocation volume is wrapper churn?
- which syntax families dominate node creation?
- how much larger is Kessel's token/node representation than the compact path?

### 2) `profile-layout`

Prints compile-time sizes for core data structures:

- `lexer.Token`
- `lexer.CompactToken`
- `lexer.TokenView`
- `ast.Expression` / `ast.Statement`
- key AST node structs like `MemberExpression`, `CallExpression`, `BinaryExpression`, `Property`, etc.

This is the quickest way to sanity-check representation costs before deeper allocator work.

## Structural benchmark fixtures

Generated benchmark set:

- `expr-heavy.js`
- `member-chain-heavy.js`
- `object-heavy.js`
- `class-heavy.js`
- `string-heavy.js`
- `destructuring-heavy.js`

Generate + compare:

```bash
node kessel/bench_structural_gen.js
bash kessel/bench_structural.sh
```

This isolates which syntax classes blow up the Kessel/OXC ratio.

## Why true `parse-no-ast` is not landed yet

A clean no-AST mode is more invasive than it sounds in Kessel's current parser.
The recursive-descent code threads concrete AST values through ambiguity resolution,
pattern conversion, property parsing, function/class construction, and location
tracking. A fake "return nil everywhere" mode would invalidate parser logic.

So the nearest low-risk attribution path is:

1. layout sizing
2. node/wrapper counting
3. syntax-directed fixtures
4. external sampling (`samply` / `perf`)

If those show AST build dominating clearly, then the next worthwhile experiment is
not a half-broken no-AST mode, but a deliberate parser refactor that separates:

- syntax recognition
- node creation
- wrapper creation

## Repro steps

### Kessel attribution

```bash
./kessel_bin profile-layout
./kessel_bin profile-parser kessel/bench_large.js --iterations 50
bash kessel/bench_structural.sh
```

### Sampling

```bash
samply record ./kessel_bin microbench kessel/bench_large.js --iterations 1
```

### OXC comparison

```bash
bench/oxc_compare/target/release/oxc_microbench kessel/bench_large.js 50
bash kessel/bench_structural.sh
```

## What to look for

### Signals that AST/layout is the main problem

- wrapper byte share is high
- node alloc count is huge relative to tokens consumed
- object/member/call/destructuring fixtures show much worse ratios than string-heavy
- flamegraph stacks cluster on `new_node`, union wrapping, dynamic array growth, or AST field initialization

### Signals that parser control flow is the main problem

- expr/member-chain fixtures are much worse than object-heavy
- lookahead/consume stays high on targeted fixtures
- flamegraph stacks cluster on `parse_expr_with_prec`, `parse_left_hand_side_expr`, and token-query helpers rather than allocation

### Signals that codegen / safety overhead is the main problem

- layout sizes look reasonable
- allocation volume is not extreme
- same hot loops remain expensive with little visible algorithmic work
- later Linux `perf` / IR / asm inspection shows extra bounds checks, worse inlining, or poorer alias assumptions versus OXC

## Post-refactor hotspot snapshot (samply, macOS)

Profiles saved locally:

- `.profiles/kessel-bench-large-5it.json.gz`
- `.profiles/member-chain-5it.json.gz`
- `.profiles/destructuring-5it.json.gz`

Key parser hotspots after the AST/layout refactors:

### `bench_large.js`

Most recurrent parser frames:

- `parse_program`
- `parse_program_item`
- `parse_expr_with_prec`
- `parse_unary_expr`
- `parse_left_hand_side_expr`
- `parse_variable_declaration`
- `next_dispatch` / `lexer::next2`
- `mem_alloc_bytes` / arena allocation helpers

Interpretation:

- The remaining cost is concentrated in **expression parsing + statement/declaration plumbing**, not in the old giant `Expression` wrapper representation.
- Token consumption still matters, but is no longer the only obvious problem.

### `member-chain-heavy`

Most recurrent parser frames:

- `parse_variable_declaration`
- `parse_expr_with_prec`
- `parse_unary_expr`
- `parse_left_hand_side_expr` (multiple offsets dominate)
- `next_dispatch` / `lexer::next2`

Interpretation:

- For chain-heavy code, `parse_left_hand_side_expr` is now the clearest syntax-specific hotspot.
- This suggests the next high-value parser optimization should target **member/call chaining construction and loop shape**.

### `destructuring-heavy`

Most recurrent parser frames:

- `parse_variable_declaration`
- `parse_object_pattern`
- `parse_array_pattern`
- `new_identifier_current`
- `intern`
- `next_dispatch` / `lexer::next2`

Interpretation:

- The pattern-specific refactor removed a lot of allocation volume, but destructuring is still expensive because of **identifier creation/interning and object/array pattern control flow**.
- The next destructuring-specific targets are likely:
  - reducing repeated identifier/interner work
  - simplifying object pattern property handling further

### Non-actionable noise seen in samples

Some recurrent symbols like `___$equal$$struct{loc:ast::Loc,value:string,raw:string}+...` and `_main+...` appear near the top of inclusive counts. These look like harness / surrounding runtime artifacts and are **not** the best next optimization targets for parser work.

## Next likely experiments

1. Attack `parse_left_hand_side_expr` directly (member/call chain path).
2. Reduce `new_identifier_current` / `intern` pressure in destructuring-heavy code.
3. Compare the same hotspots against OXC on equivalent synthetic fixtures.
4. If AST attribution is still limiting, prototype wrapper-elision / direct tagged handle paths.
