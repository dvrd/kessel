# Handoff — Beating OXC: Performance Roadmap

## Current State

Build: clean. All tests pass (291 unit + 24 coverage). All parser conformance suites at 100% positive and 100% negative.

### Performance (measured this session, Apple Silicon, P50 over 30 iterations)

| File | KB | Kessel (μs) | OXC (μs) | Ratio |
|---|---|---|---|---|
| typescript.js | 8808 | 55,604 | 42,868 | **1.30x** |
| antd.js | 4059 | 28,594 | 23,631 | 1.21x |
| monaco.js | 3388 | 38,709 | 33,872 | 1.14x |
| d3.js | 573 | 6,404 | 5,392 | 1.19x |
| jquery.js | 278 | 1,869 | 1,722 | 1.09x |
| lodash.js | 531 | 1,748 | 1,530 | 1.14x |
| react.dev.js | 107 | 529 | 387 | **1.37x** |

**Geo-mean: 1.20x (kessel is 20% slower). Throughput: 130 MB/s vs OXC 158 MB/s.**

### Time Breakdown (typescript.js, 9 MB)

| Phase | Time | % |
|---|---|---|
| Lexer | 23.4 ms | 32% |
| Parser | 48.6 ms | 68% |
| **Total** | **72.0 ms** | |

### Allocation Profile (typescript.js)

| Metric | Value |
|---|---|
| AST node allocs | 451,413 |
| Expression wrappers | 87,487 (19.4% of allocs) |
| Statement wrappers | 75,916 (16.8% of allocs) |
| Identifiers | 69,005 |
| Bump pool used | 58 MB / 289 MB (20.2%) |
| Wrapper byte share | 13.7% of all allocated bytes |

---

## The Gap: Why Kessel is 20% Slower

The gap is not in any single hot loop. It's distributed across three architectural differences between kessel and OXC:

### 1. Token Struct Inflation (est. 8–12% of gap)

**The problem.** OXC's lexer produces a `Token` with 3 fields: `kind` (1B), `start` (4B), `end` (4B) = **9 bytes**. The parser reads `source[start..end]` lazily when it needs the text. Kessel's lexer produces a 16-byte `FastToken`, then `advance_token` inflates it into a **72-byte `Token`** struct on every token:

```
FastToken (16B)  →  advance_token  →  Token (72B)
  kind               copies kind        kind
  flags              copies flags        loc (LexerLoc)
  start              slices source       value (string = ptr+len)
  end                                    raw_end
                     snapshots literal   literal (LiteralValue union, 32B)
                     checks escapes      had_line_terminator
                                         has_escape
```

This inflation runs **~600K times** per typescript.js parse. The `literal` field (a tagged union holding `bool | f64 | string | {pattern,flags}`) is 32 bytes and only meaningful for ~20% of tokens (strings, numbers, regex, templates). The remaining 80% (identifiers, keywords, operators, punctuation) pay the full 72-byte write for nothing.

**Call sites.** `p.cur_tok` is referenced 182 times. `get_current(p)` (returns Token by value = 72B copy) is called 63 times. `p.cur_tok.value` is read 64 times. `p.cur_tok.had_line_terminator` is read 43 times.

**The fix.** Eliminate `Token` entirely. Make the parser read `FastToken` fields directly from the lexer:

- `p.cur_type` → already exists (1B, fast)
- `p.cur_tok.value` → replace with `source[lexer.cur.start:lexer.cur.end]` or a lazy `cur_value()` inline
- `p.cur_tok.had_line_terminator` → replace with `(lexer.cur.flags & FLAG_NEW_LINE) != 0`
- `p.cur_tok.has_escape` → replace with `(lexer.cur.flags & FLAG_HAS_ESCAPE) != 0`
- `p.cur_tok.literal` → replace with lazy access to `lexer.cur_lit_value` only when needed (11 call sites)
- `p.cur_tok.loc` → replace with `LexerLoc(lexer.cur.start)` (computed, not stored)

**Scope.** ~250 call sites across `src/parser.odin`. The 63 `get_current(p)` sites are the priority — each copies 72 bytes. Many only read `.value` and can be replaced with `cur_value(p)` (already exists, reads from lexer directly).

**Estimated impact.** Eliminating the 72B inflation saves ~600K × 72B = 43MB of writes per parse. Even with store-buffer absorption, this is significant cache pressure. Conservative estimate: 8–12% of the 20% gap.

### 2. Expression/Statement Wrapper Allocations (est. 4–6% of gap)

**The problem.** Every AST expression node requires TWO allocations: the concrete node (e.g. `Identifier`, 48B) and a wrapper `^Expression` union (16B) that points to it. Same for statements. This produces **163,403 wrapper allocations** (87K expr + 76K stmt) that are pure overhead — they exist only because Odin's union dispatch requires a pointer indirection.

OXC uses a flat `Expression` enum with inline data for small variants and arena-indexed pointers for large ones. No wrapper allocation.

```
Kessel:  new_node(p, Identifier) → 48B + new_node(p, Expression) → 16B = 64B, 2 allocs
OXC:     arena.alloc<Identifier>() → 48B, 1 alloc, Expression enum tag is inline
```

**The fix.** Two options:

**(A) Inline small variants.** The `Expression` union is currently `union { ^Identifier, ^StringLiteral, ^NumericLiteral, ... }` — all pointers. For the top-5 variants by frequency (Identifier 69K, MemberExpression, CallExpression, StringLiteral, NumericLiteral), inline the struct directly:

```odin
Expression :: union {
    Identifier,              // 48B inline (was ^Identifier = 8B pointer)
    ^FunctionExpression,     // large, keep pointer
    ^ClassExpression,        // large, keep pointer
    ...
}
```

This eliminates the separate allocation for the most common nodes. Trades union size (grows from 16B to ~80B) for allocation count (-69K allocs). The emitter (`src/emitter.odin`, 39 node printers) needs matching changes.

**(B) Fused allocation.** Allocate concrete node + wrapper in one bump:

```odin
new_expr_node :: proc(p: ^Parser, $T: typeid) -> (^T, ^Expression) {
    // Single bump alloc for T + Expression, contiguous in memory
    total := size_of(T) + size_of(Expression)
    ptr := bump_alloc(&p.node_pool, total, align_of(T))
    node := transmute(^T)ptr
    expr := transmute(^Expression)(uintptr(ptr) + uintptr(size_of(T)))
    expr^ = node
    return node, expr
}
```

This halves allocation count without changing AST layout. The emitter doesn't change. But it requires updating every `new_node(p, Foo); expression_from(p, foo)` pattern (~87K times) to the fused version.

**Scope.** Option A: `src/ast.odin` (union definitions), `src/parser.odin` (~200 sites that create expression nodes), `src/emitter.odin` (39 printers), `src/checker.odin` (expression walkers). Option B: `src/parser.odin` only (~200 sites).

**Estimated impact.** 163K fewer allocations × ~20ns per bump = ~3.3ms saved. On a 55ms parse, that's ~6%. Plus better cache locality from fused nodes.

### 3. Lexer: Identifier Keyword Dispatch (est. 2–4% of gap)

**The problem.** When the lexer encounters an identifier, it must check if it's a keyword. Kessel uses a switch on the first character + length, then compares strings. OXC uses a perfect hash table generated at compile time. The difference is ~2-3 fewer comparisons per keyword check on average.

**Where.** `src/lexer.odin`, `lex_identifier` function (~line 1060). Called for every identifier and keyword token.

**The fix.** Generate a minimal perfect hash for the ~70 JS/TS keywords. The hash maps `(first_char, length)` → keyword token directly without string comparison for the common case. Odin's `#partial switch` on a hash value is branch-free on ARM64.

**Estimated impact.** ~2–4% on large files with many keywords (typescript.js has ~200K identifiers/keywords).

### 4. Parser: Speculative Parse Overhead (est. 1–2% of gap)

**The problem.** Several parser paths use `lexer_snapshot` / `lexer_restore` for speculative parsing (arrow functions, TS type arguments, generic disambiguation). Each snapshot copies lexer state. OXC uses a "rewind" mechanism that's cheaper because it only resets the offset.

**Where.** `src/parser.odin`, `lexer_snapshot` (5 call sites), `looks_like_ts_function_type` (speculative lookahead).

**The fix.** Replace `lexer_snapshot`/`lexer_restore` with offset-based rewind where possible. The lexer's `cur`/`nxt` two-token lookahead can be restored from just `(offset, cur, nxt)` — 24 bytes instead of the full lexer state.

**Estimated impact.** Small — speculative parses are rare per file. But on files with many arrow functions (react.dev.js, 1.37x gap), this matters more.

### 5. Emitter: JSON Serialization (not in parse time, but in wall time)

The ESTree JSON emitter (`src/emitter.odin`, 6.4K lines) runs after parsing. It's not measured in the parse benchmark but dominates CLI wall time. OXC uses `serde` with zero-copy string references; kessel's emitter does `fmt.tprintf` calls. This is a separate optimization track.

---

## Priority Order

| # | Fix | Est. Impact | Effort | Files |
|---|---|---|---|---|
| 1 | Eliminate Token struct inflation | 8–12% | HIGH | `parser.odin` (~250 sites) |
| 2 | Fused expr/stmt allocation | 4–6% | MEDIUM | `parser.odin` (~200 sites) |
| 3 | Perfect-hash keyword lookup | 2–4% | LOW | `lexer.odin` (1 function) |
| 4 | Cheaper speculative parse | 1–2% | LOW | `parser.odin` (5 sites) |
| **Total** | | **15–24%** | | |

Fixing #1 alone would likely bring kessel within 10% of OXC. Fixing #1 + #2 should achieve parity or better.

---

## How To Implement Fix #1 (Token Elimination)

This is the highest-impact change. Here's the step-by-step plan:

### Phase 1: Add FastToken accessor inlines (no behavior change)

Add inline helpers that read from `p.lexer.cur` directly:

```odin
cur_start :: #force_inline proc(p: ^Parser) -> u32 { return p.lexer.cur.start }
cur_end   :: #force_inline proc(p: ^Parser) -> u32 { return p.lexer.cur.end }
cur_flags :: #force_inline proc(p: ^Parser) -> u8  { return p.lexer.cur.flags }
cur_has_newline :: #force_inline proc(p: ^Parser) -> bool {
    return (p.lexer.cur.flags & FLAG_NEW_LINE) != 0
}
cur_has_escape :: #force_inline proc(p: ^Parser) -> bool {
    return (p.lexer.cur.flags & FLAG_HAS_ESCAPE) != 0
}
// cur_value already exists and reads from lexer
```

### Phase 2: Migrate `p.cur_tok.had_line_terminator` (43 sites)

Replace `p.cur_tok.had_line_terminator` with `cur_has_newline(p)`. Pure mechanical substitution — `had_line_terminator` is only read, never written except in `advance_token`.

### Phase 3: Migrate `p.cur_tok.has_escape` (23 sites)

Same pattern. Replace with `cur_has_escape(p)`.

### Phase 4: Migrate `p.cur_tok.value` (64 sites)

Replace with `cur_value(p)` (already exists). Some sites save `p.cur_tok.value` before `eat(p)` — these need `saved_value := cur_value(p)` before the eat.

### Phase 5: Eliminate `get_current(p)` (63 sites)

Each site does `current := get_current(p)` then reads `current.value`, `current.type`, `loc_from_token(&current)`. Replace with direct reads: `cur_value(p)`, `p.cur_type`, `Loc{span = {start = cur_start(p), end = 0}}`.

### Phase 6: Migrate `p.cur_tok.literal` (11 sites)

These read the cooked literal value for strings/numbers. Replace with `cur_literal(p)` that reads from `lexer.cur_lit_value`. Only 11 sites — mostly in `parse_string_literal`, `parse_numeric_literal`, `parse_template_literal`.

### Phase 7: Remove Token struct and advance_token inflation

Once all reads go through FastToken accessors, `cur_tok` and the inflation logic in `advance_token` can be deleted. `advance_token` shrinks from 92 lines to ~10 (just swap cur/nxt and lex next token).

### Validation

After each phase, run `task test` (all 291 unit + 24 coverage tests) and benchmark. The test suite is comprehensive enough to catch any behavioral regression.

---

## Commands

```bash
task build                          # Release binary
task test                           # Primary gate (coverage + unit)
task test:conformance:report        # Live conformance numbers
task test:bench:regression          # Performance regression gate
task test:bench:regression:update   # Lock new baseline after perf work

# Benchmarking
./bin/kessel microbench parse FILE --iterations 30
./bin/kessel profile parse FILE --iterations 5
bench/oxc_compare/target/release/oxc_microbench FILE 30

# Key files
src/parser.odin    # 22.6K lines — parser + Token struct + advance_token
src/lexer.odin     # 3.1K lines — SIMD lexer, FastToken, lex_token
src/ast.odin       # 1.6K lines — all AST struct/union definitions
src/token.odin     # 383 lines — TokenType enum, Token struct, FastToken
src/emitter.odin   # 6.4K lines — ESTree JSON emitter
src/parse_job.odin # 440 lines — ParseJob entry point
```
