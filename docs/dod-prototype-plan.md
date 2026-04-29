# Step #5 Phase 1: DoD Prototype + Validation

> Date: 2026-04-29 (S22.3)
>
> Status: Phase 1 (validation). Decision gate at end.

## Goal

Validate, on this codebase, whether a Zig AstGen-style SoA AST actually
delivers the predicted ~12 % wall-time gain. The prediction is based on
Tweede Golf's measurement that DoD on top of arena = 1.12× faster than
arena alone. We have a track record of dispatch-layer predictions
coming in 5–10× smaller than predicted on this codebase, so we will
**measure first, refactor second**.

If Phase 1 validates → commit to full migration (Phase 2-3, ~4 weeks).
If Phase 1 falsifies → ship at 1.064× and document the negative result.

## Phase 1 design (1–2 days)

Build the smallest possible isolated experiment that captures the
essential SoA-vs-AoS tradeoff for this parser:

### Target: Identifier-heavy expression subgraph

The hottest contiguous slice of AST building in the parser:

```
parse_unary_expr
  → parse_left_hand_side_expr
    → parse_primary_expr (often: Identifier alloc)
    → parse_lhs_tail (loop: MemberExpression / CallExpression alloc)
  → parse_expr_with_prec (loop: BinaryExpression / LogicalExpression alloc)
```

These produce ~50–60 % of all AST nodes on real-world fixtures (per
profile: parse_unary_expr 10 %, parse_expr_with_prec 6 %,
parse_lhs_tail / parse_arguments / parse_member each 2–3 %, plus the
allocation pressure inside them).

### Two implementations of the same parser subset

#### Implementation A: kessel-style (pointer + arena)

```odin
ExprNode_AOS :: union {
    ^IdentifierNode_AOS,
    ^BinaryNode_AOS,
    ^MemberNode_AOS,
    ^CallNode_AOS,
}
IdentifierNode_AOS  :: struct { name: string, span: Span }            // ~32 B
BinaryNode_AOS      :: struct { op: u8, left, right: ExprNode_AOS, span: Span }  // ~48 B
MemberNode_AOS      :: struct { object: ExprNode_AOS, prop: string, span: Span } // ~48 B
CallNode_AOS        :: struct { callee: ExprNode_AOS, args: [dynamic]ExprNode_AOS, span: Span }  // ~64 B
```

Arena-allocated, Odin's `mem.virtual.Arena` (matches kessel today).

#### Implementation B: Zig-style SoA

```odin
NodeTag :: enum u8 {
    IDENT,        // data[i] = name index in extra
    BINARY,       // data[i] = (lhs, rhs); main_token tracks op
    MEMBER,       // data[i] = (object, prop_name_index)
    CALL,         // data[i] = (callee, args_ref); args_ref → extra[]
}

NodeData :: struct {
    lhs: u32,    // index into nodes[] or extra[]
    rhs: u32,    // (semantics depend on tag)
}                // 8 B per node

Ast_SOA :: struct {
    tags:        [dynamic]NodeTag,    // 1 B per node
    data:        [dynamic]NodeData,   // 8 B per node
    main_tokens: [dynamic]u32,        // op for binary, name for ident, …
    extra:       [dynamic]u32,        // var-len payload (arg lists, …)
    spans:       [dynamic]Span,       // 8 B per node (offset, length)
}
```

Total per node: 1 + 8 + 4 + 8 = 21 B (vs kessel AoS ~40–80 B).
References between nodes are u32 indices into `tags[]` (4 B vs 16 B
for kessel's Expression union).

### Synthetic benchmark input

Generate `bench/dod_proto/expr_corpus.js` containing 100,000 synthetic
expressions that exercise all four node types in realistic proportions:

```javascript
// Pattern (repeated 100K times with varying names):
//   foo.bar.baz(a + b * 2, c.d, e()) + g.h
```

Stats target:
* ~500K nodes total
* ~40 % Identifier
* ~20 % BinaryExpression
* ~25 % MemberExpression
* ~15 % CallExpression

This isolates the AST-construction cost from JSX, classes, TS types,
patterns, etc. — all the parts that *don't* change in SoA.

### Measurement protocol

1. Build both parsers with `-o:speed -no-bounds-check`.
2. Parse the corpus 200 times, record min/median.
3. Compare:
   * Wall time (parse only)
   * Allocator calls (instrumented)
   * Total bytes allocated
   * Cache miss rate (via `samply` event sampling, if available)

### Decision gate

| Δ AoS → SoA (median) | Action |
|---|---|
| ≥ 8 % faster | **Go**: full migration justified, predicted ~12 % on real fixtures |
| 4 – 8 % faster | **Conditional go**: revisit cost/benefit; 4-week refactor for 4-6 % real-world is borderline |
| 0 – 4 % faster | **Stop**: SoA gain is dominated by other costs; ship at 1.064× |
| Negative or noise | **Stop + document**: another disproved hypothesis |

The pessimistic case from `perf-bottleneck-profile.md` (5× reduced like
prior failures) would show 2.4 % here — *below* the stop threshold.
That means we MUST see a robust signal in this isolated benchmark for
the full migration to be worth the cost.

## Phase 2 design (only on Phase 1 GO, ~3 weeks)

If Phase 1 validates, plan:

1. **Week 1**: Define the canonical SoA layout. Build `dod_ast.odin`
   with `tags`, `data`, `extra`, `main_tokens`, `spans` arrays.
   Write helpers (`ast_alloc_node`, `ast_get`, …).

2. **Week 2**: Convert the parser per node-type family in waves.
   Order by hotness:
   * Wave 1: Identifier, MemberExpression, CallExpression, BinaryExpression
   * Wave 2: ObjectExpression, ArrayExpression, Property
   * Wave 3: FunctionExpression, ArrowFunctionExpression, ClassExpression
   * Wave 4: Statements, Patterns, JSX
   * Wave 5: TS types

   Each wave keeps the rest of the AST in pointer form (parallel
   representations) until the wave's reads are migrated. This bounds
   the blast radius of each commit.

3. **Week 3**: Migrate `printer.odin` (JSON output), drop
   `raw_transfer.odin` (replaced by trivial array writes), update
   `tests/verifiers/verify_*.js` to walk the SoA arrays.

## Phase 3 design (verifier + cleanup, ~1 week)

* Update `tests/verifiers/verify_integration.js`,
  `verify_raw.js`, `verify_raw_deep.js` to read the SoA layout.
* Delete the legacy `^Expression` / `^Statement` types.
* Update `HANDOFF.md`, `docs/perf-deep-analysis.md`,
  `docs/perf-bottleneck-profile.md`.

---

## Phase 1 first action

Build the prototype harness. Instructions for the next agent:

1. `mkdir -p bench/dod_proto`
2. Create the synthetic expression corpus generator
3. Write Implementation A in a single `.odin` file
4. Write Implementation B in a single `.odin` file
5. Write the benchmark harness comparing both
6. Report the median Δ for the decision gate.

Begin.
