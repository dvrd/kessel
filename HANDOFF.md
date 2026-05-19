# Handoff — Kessel Performance: Progress & Remaining Gap

## Current State

Build: clean. All tests pass (291 unit + 24 coverage). All parser conformance suites at 100% positive and 100% negative.

### Performance (Apple Silicon, P50 over 30 iterations)

| File | KB | Kessel (μs) | OXC (μs) | Ratio |
|---|---|---|---|---|
| typescript.js | 8808 | 51,887 | 42,738 | **1.21x** |
| antd.js | 4059 | 27,329 | 23,306 | 1.17x |
| d3.js | 573 | 6,013 | 5,428 | 1.11x |
| jquery.js | 278 | 1,798 | 1,688 | 1.07x |
| lodash.js | 531 | 1,678 | 1,418 | 1.18x |
| react.dev.js | 107 | 487 | 390 | **1.25x** |

**Geo-mean: 1.16x (kessel is 16% slower). Down from 1.20x before optimization work.**

### Time Breakdown (typescript.js, 9 MB)

| Phase | Time | % |
|---|---|---|
| Lexer | 22.2 ms | 42% |
| Parser | 30.1 ms | 58% |
| **Total** | **52.3 ms** | |

### Allocation Profile (typescript.js)

| Metric | Before | After |
|---|---|---|
| AST node allocs | 451,413 | 376,974 |
| AST node bytes | 19.4 MB | **17.2 MB** |
| Expression wrappers | 87,487 | 92,670 |
| Statement wrappers | 75,916 | 33,810 |
| Identifiers | 69,005 | 52,356 |
| Identifier size | 48 B | **40 B** |
| Bump pool used | 58 MB / 289 MB (20.2%) | **50.9 MB / 289 MB (17.6%)** |

---

## What Was Done (3 rounds of optimization)

### Round 1: Token Elimination + Fused Allocations

**Phases 2–5 of Token elimination.** Migrated all `p.cur_tok.*` field reads to FastToken accessor functions that read directly from the lexer's `FastToken` struct:

- `p.cur_tok.had_line_terminator` → `cur_has_newline(p)` — 43 sites
- `p.cur_tok.has_escape` → `cur_has_escape(p)` — 23 sites
- `p.cur_tok.value` → `cur_value(p)` — 64+ sites
- `p.cur_tok.literal` → `cur_literal(p)` — 11 sites
- `get_current(p)` (72-byte Token copy) → `snap_current(p)` (48-byte `TokenSnap`) — 63 sites

New infrastructure:
- `TokenSnap` struct (48B): `value`, `start`, `end`, `type`, `has_escape`, `literal`
- `loc_from_token` is now a proc group dispatching to both `^Token` and `^TokenSnap`
- `cur_value(p)` extended to handle `PrivateIdentifier` escapes
- `parse_async_arrow_with_parens` and `try_parse_ts_arrow_params` signatures changed from `Token` to `TokenSnap`

**Fused expr/stmt allocation (Option B).** Converted 106 `new_node + expression_from/statement_from` pairs to single `new_expr`/`new_stmt` fused bump allocations. Remaining 44 `expression_from` + 3 `statement_from` are in different scopes and can't be fused.

### Round 2: Lexer + Parser Micro-optimizations

- **Nil-check removal.** Stripped dead `if p.lexer != nil` from all accessor functions. No perf impact (compiler already predicted).
- **TrialSnapshot shrink.** Removed 72-byte `cur_tok: Token` from snapshot struct. 41 snapshot sites now copy ~120 bytes instead of ~192. No wall-time impact.
- **SIMD string newline detection.** Extended `simd_find_string_end` to detect LF/CR during the SIMD scan (third return value). `lex_string` skips the scalar newline loop when none found (~95% of strings). ~3% lex improvement.
- **Keyword hash table.** Replaced the 132-line `lookup_keyword_by_letter` switch-on-first-char with a 268-entry hash table: `KEYWORD_HASH_TABLE[(first_char - 'a') * 11 + (length - 2)]`. 6 collisions resolved by 2nd byte switch. Non-keywords exit in 1 table load; matches verify with 3-byte u32 compare + optional tail check. ~3% lex improvement.

### Round 3: Phase 7 + Struct Shrink

- **Phase 7: advance_token stripped.** Removed ALL `p.cur_tok` field writes from `advance_token` AND all 5 rescan/relex paths. `advance_token` is now 7 lines: prev_end save → cur←nxt swap → literal ring toggle → lex nxt → set cur_type. Writes 1 byte per token instead of 56–72. Also migrated remaining 40 `p.cur_tok.value` reads scattered across import/export/TS parsing.
- **Literal ring buffer.** Replaced the 6-field literal store (`last_lit_offset/value/type` + `cur_lit_offset/value/type`) with a 2-slot ring buffer (`lit_offset[2]`, `lit_value[2]`, `lit_type[2]`, `lit_write_idx`). `advance_token` does a single XOR toggle (1 byte) instead of copying 3 fields (~32 bytes) per literal-bearing token. ~2% improvement.
- **Loc shrink.** Removed dead `line` and `column` fields from `Loc` struct (16→8 bytes). These were never written or read — line/column computed lazily by `report_error`. Every AST node shrinks by 8 bytes. Identifier: 48→40 bytes. Total node bytes: 19.4→17.2 MB (−11.3%).
- **Dynamic array pre-sizing.** Gave sensible initial capacities to zero-cap arrays (function bodies 4, class bodies 8, etc.). Minimal wall-time impact.

---

## Why Kessel Is Still 16% Slower

### Gap Breakdown (typescript.js)

| Component | Kessel | OXC (est) | Gap | % of total gap |
|---|---|---|---|---|
| Lexer | 22.2 ms | ~15.8 ms | **6.4 ms** | **66%** |
| Parser | 30.1 ms | ~26.9 ms | **3.2 ms** | **34%** |

### Lexer Gap (66% of the problem — 6.4ms)

**1. Two-token lookahead (nxt prefetch).** `advance_token` eagerly lexes `a.nxt` on every `eat()`. OXC lexes on-demand (single lookahead). This has two costs:

- Direct: 16B FastToken copy (`a.cur = a.nxt`) + EOF branch per token = ~2 cycles/token = ~0.7ms
- Indirect: `lex_token` is called from within the `#force_inline advance_token`, which means the full lexer dispatch code gets inlined into every parse function. This causes **massive code bloat**: `parse_for_statement` compiles to 388KB (larger than L1 icache). The icache pressure costs ~3-10 cycles/token on real workloads.

110 sites reference `p.lexer.nxt` for lookahead. Eliminating the two-token design would require rearchitecting all 110.

**2. Literal snapshot mechanism (now ring buffer).** The ring buffer toggle is cheap (1 XOR), but the mechanism still exists. OXC stores literal data inline in its Token struct — no separate tracking.

**3. Lexer dispatch overhead.** `lex_token` is a ~250-line proc with whitespace skip (branchless fast path + SIMD slow path) + single-char table lookup + identifier/operator dispatch. OXC's equivalent is simpler because it doesn't prefetch nxt.

### Parser Gap (34% of the problem — 3.2ms)

**1. Expression/Statement wrapper allocations.** 126K wrapper allocations per parse (92K expr + 34K stmt). Each is a 16-byte bump alloc for a pointer-union indirection. OXC uses flat tagged enums — zero wrapper allocations. This is ~2.5ms of alloc overhead + cache pressure.

The only fix is restructuring `Expression :: union { ^Identifier, ^StringLiteral, ... }` to a flat enum or inline layout, which changes every file: ast.odin, parser.odin (~200 sites), emitter.odin (39 printers), checker.odin.

**2. Dynamic array malloc.** 85 `make([dynamic])` per parse use the system allocator (malloc/free). OXC uses arena-backed Vecs (bump pointer). We attempted an arena-backed allocator but Odin's `[dynamic]` resize contract caused alignment panics. Needs more careful engineering of the allocator protocol.

**3. Pointer indirection.** `cur_value(p)` traverses `p→lexer→cur→start` (3 dependent loads). OXC reads offsets from a flat struct.

---

## What Would Close the Gap

### Tier 1: Architecture changes (5–10% combined, weeks of work)

| Fix | Est. | Effort | Notes |
|---|---|---|---|
| Eliminate two-token lookahead | 2–4% | **VERY HIGH** | 110 `nxt` references; rearchitect lexer/parser interface |
| Eliminate Expression/Statement wrappers | 2–3% | **VERY HIGH** | Flat enum AST; changes ast + parser + emitter + checker |
| Arena-backed `[dynamic]` arrays | 1–2% | HIGH | Custom allocator matching Odin's resize contract |

### Tier 2: Already attempted, need different approach

| Fix | Issue | Alternative |
|---|---|---|
| De-inline lex_token | Call overhead > icache benefit at 1.15M calls | Need compiler-level PGO or split lex_token into hot/cold paths |
| Arena [dynamic] arrays | Odin allocator alignment panic on resize | Implement full Odin allocator protocol including Query_Features |

### Tier 3: Diminishing returns (< 1% each)

- Shrink Identifier further (already 40B, well-packed)
- Pre-size more dynamic arrays
- Further SIMD in lexer (already covers identifiers + strings + whitespace)

---

## Architecture After Optimization

### advance_token (7 lines, was 92)

```odin
advance_token :: #force_inline proc(p: ^Parser) {
    if p.lexer != nil {
        a := p.lexer
        p.prev_token_end = a.cur.end
        a.cur = a.nxt
        a.lit_write_idx ~= 1  // ring buffer toggle
        if a.cur.kind != .EOF { a.nxt = lex_token(a) }
        else { a.nxt = token_eof(u32(a.offset)) }
        p.cur_type = a.cur.kind
    }
}
```

### Token access (all reads go through FastToken accessors)

```odin
cur_value(p)       // → p.lexer.source[cur.start:cur.end] (or cooked name for escapes)
cur_loc(p)         // → Loc{span = {cur.start, cur.end}}
cur_has_newline(p) // → (cur.flags & FLAG_NEW_LINE) != 0
cur_has_escape(p)  // → (cur.flags & FLAG_HAS_ESCAPE) != 0
cur_literal(p)     // → lit_value[lit_write_idx ^ 1] (ring buffer read slot)
cur_offset(p)      // → cur.start
cur_raw_end(p)     // → cur.end
```

`p.cur_tok` is effectively dead — no reads remain. The struct still exists on `Parser` but is only written by legacy rescan paths (JSX relex, regex relex) that don't go through `advance_token`. These paths set `p.cur_type` directly from the lexer.

### Keyword lookup (hash table)

```
KEYWORD_HASH_TABLE: [268]TokenType  — indexed by (first_char - 'a') * 11 + (length - 2)
KEYWORD_VERIFY: [268]u32           — bytes 1..3 packed for verification
6 collision slots resolved by 2nd-byte switch: (a,5) (a,8) (c,5) (i,2) (s,6) (t,4)
```

### Literal storage (ring buffer)

```
Lexer.lit_offset: [2]u32
Lexer.lit_value:  [2]LiteralValue
Lexer.lit_type:   [2]LiteralType
Lexer.lit_write_idx: u8  — toggles 0↔1 each advance
```

Writer (lex_token): writes to `[lit_write_idx]`. Reader (cur_literal): reads from `[lit_write_idx ^ 1]`.

### Loc (8 bytes, was 16)

```odin
Loc :: struct { span: Span }  // Span = {start: u32, end: u32}
// line/column removed — computed lazily by report_error via offset_to_line_col
```

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
./bin/kessel microbench lex FILE --iterations 10
./bin/kessel profile parse FILE --iterations 5
bench/oxc_compare/target/release/oxc_microbench FILE 30

# Key files
src/parser.odin    # ~22.5K lines — parser + advance_token + FastToken accessors
src/lexer.odin     # ~3.1K lines — SIMD lexer, FastToken, lex_token, keyword hash
src/ast.odin       # ~1.6K lines — all AST struct/union definitions
src/emitter.odin   # ~6.4K lines — ESTree JSON emitter
src/simd.odin      # ~600 lines — ARM64 NEON intrinsics
src/token.odin     # ~380 lines — TokenType enum, FastToken struct
```
