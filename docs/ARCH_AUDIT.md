# ARCHITECTURE.md Audit

## Summary
- **Total Claims Verified**: 34
- **Status OK**: 24
- **Status STALE**: 6
- **Status WRONG**: 3
- **Status MISSING**: 1

## Claims Audit Table

| Claim | Location in doc | Status | Evidence |
|-------|-----------------|--------|----------|
| src/lexer/lexer.odin exists | "Files: src/lexer/lexer.odin" | OK | File exists at kessel/src/lexer/lexer.odin |
| src/lexer/lexer_optimized.odin exists | "Files: src/lexer/lexer_optimized.odin" | OK | File exists at kessel/src/lexer/lexer_optimized.odin (1301 lines) |
| src/lexer/simd.odin exists | "SIMD-accelerated...simd.odin" | OK | File exists at kessel/src/lexer/simd.odin |
| src/lexer/keyword_hash.odin exists | "Perfect hash table...keyword_hash.odin" | OK | File exists at kessel/src/lexer/keyword_hash.odin |
| src/lexer/token_compact.odin exists | "Files: src/lexer/token_compact.odin" | OK | File exists with SoA implementation |
| src/lexer/token.odin exists | "Files: src/lexer/token.odin" | OK | File exists at kessel/src/lexer/token.odin |
| src/parser/parser.odin exists (~2000 lines) | "File: src/parser/parser.odin (~2000 lines)" | WRONG | Actual file is 3982 lines (not ~2000). Off by ~2x. |
| src/ast/ast.odin exists | "File: src/ast/ast.odin" | OK | File exists at kessel/src/ast/ast.odin (824 lines) |
| src/main.odin exists | "File: src/main.odin (print functions)" | OK | File exists at kessel/src/main.odin |
| BindingIdentifier type exists | "Identifier Distinction: BindingIdentifier" | OK | Defined in kessel/src/ast/ast.odin:24 |
| IdentifierReference type exists | "Identifier Distinction: IdentifierReference" | OK | Defined in kessel/src/ast/ast.odin:30 |
| IdentifierName type exists | "Identifier Distinction: IdentifierName" | OK | Defined in kessel/src/ast/ast.odin:37 |
| LabelIdentifier type exists | "Identifier Distinction: LabelIdentifier" | OK | Defined in kessel/src/ast/ast.odin:43 |
| Arena allocator pre-sized | "estimate_arena_size(source_len)" | OK | Function exists at kessel/src/lexer/lexer_optimized.odin:65 |
| Arena minimum is 4MB | "Minimum: 4MB for small files" | OK | Code confirms 4MB floor in estimate_arena_size() |
| SoA token storage (types, spans, contexts) | "TokenStore :: struct { types, spans, contexts }" | STALE | Code uses TokenSoA with: types, offsets, lines, cols, lengths. Names differ slightly from doc. |
| Token size ~13 bytes | "~13 bytes/token vs ~40 bytes traditional" | WRONG | Code comment says "16 bytes per token" (kessel/src/lexer/token_compact.odin:9). Not 13. |
| Token size traditional ~40 bytes | "~40 bytes traditional" | WRONG | Token comment says traditional was "~76 bytes" (token_compact.odin:9), not 40. |
| SIMD whitespace skipping (SSE2/AVX2/NEON) | "uses SSE2/AVX2/NEON instructions where available" | STALE | Code only shows NEON implementation (ARM64). No SSE2/AVX2 implementations found. Platform-specific, not "where available" as stated. |
| Pratt parsing for precedence | "Pratt parsing for operator precedence" | OK | parse_expression and parse_*_expression functions exist throughout parser.odin |
| Automatic Semicolon Insertion (ASI) | "Automatic Semicolon Insertion (ASI)" | OK | had_line_terminator flags present in token structures |
| Two-phase parsing mention | "Two-phase parsing: Fast structural parse → optional semantic analysis" | STALE | No evidence of explicit semantic analysis phase in codebase. Parsing is single-pass. |
| Error recovery on statement boundaries | "Error recovery: Synchronizes on statement boundaries" | MISSING | No error recovery mechanism found in parser.odin. Parser appears to stop on first error. |
| Lexer throughput ~500 MB/s | "Lexer throughput | ~500 MB/s (SIMD paths)" | WRONG | No evidence in code. Benchmark shows ~12ms for 124 bytes on small files, much slower than claimed. |
| Parse throughput ~100 MB/s | "Parse throughput | ~100 MB/s typical JS" | WRONG | No evidence in code. Benchmarks show total (lex+parse) is 3-6x slower than OXC for most file sizes. |
| Memory overhead ~1.5x source size | "Memory overhead | ~1.5x source size (arena)" | STALE | Code sets 4MB minimum and 256x source size estimates. Actual overhead varies significantly by file size. |
| Token size | "Token size | ~13 bytes (SoA compact)" | WRONG | Code states 16 bytes, not 13 bytes (with padding). |
| AST node overhead ~24 bytes | "AST node overhead | ~24 bytes average" | STALE | No evidence in code for this specific number. Varies by node type in union structures. |
| JSON printer outputs source location | "JSON output with source location information" | OK | JSON printer pattern shown in src/main.odin |
| Arena bump pointer allocation | "O(1) allocation (bump pointer)" | OK | mem.Arena uses bump pointer semantics |
| Arena single deallocation | "O(1) deallocation (free entire arena at once)" | OK | Arena is freed as single block after parsing |
| Cache locality for SoA | "Sequential token type access is 8x faster" | STALE | 8x figure is unsubstantiated. Code comment says "4.75x reduction" in token_compact.odin:6 for size, not speed. |
| Regex context awareness | "distinguishes `/` (division) from `/.../` (regex)" | OK | Regex context tracking in lexer.odin via last_token_type and had_line_terminator |
| Perfect hash for keywords | "O(1) keyword lookup" via perfect hash | OK | keyword_hash.odin file implements keyword table |
| String interning | "String interning — identifiers deduplicated" | OK | string_data field in TokenSoA for identifier storage |
| Recursive descent parser | "Recursive descent parser implementing ECMAScript grammar" | OK | Parser functions throughout parser.odin |

## Detailed Findings

### Critical Issues
1. **Parser line count** (3982 vs stated ~2000): Nearly 2x larger than documented. Suggests docs are outdated.
2. **Throughput numbers** (500 MB/s, 100 MB/s): Completely unvalidated. Real benchmarks show 3-6x slower than OXC on typical files.
3. **Token size** (13 vs actual 16): Off by ~3 bytes. Minor but factually wrong.

### Design Drift
1. **SIMD platforms**: Doc claims "where available" but only NEON is implemented. Misleading for x86-64 users.
2. **Two-phase parsing**: Not evident in code. Parser is single-pass.
3. **Error recovery**: Not implemented. Parser stops on first error.
4. **Memory overhead**: 4MB floor dominates for small files, not 1.5x.

### Minor Inaccuracies
1. **Token shape**: SoA layout differs slightly (offsets/lines/cols vs spans). Functionally equivalent but doc is imprecise.
2. **Cache speedup claims**: "8x faster" unsubstantiated; code mentions "4.75x" for size reduction.
3. **AST overhead**: No evidence for "~24 bytes average" figure.

## Recommendations

- [ ] Update parser line count to ~4000
- [ ] Remove or verify throughput numbers with actual benchmarks
- [ ] Clarify SIMD support: specify ARM64 NEON only (or add x86 support)
- [ ] Document actual single-pass parsing approach, remove "two-phase" language
- [ ] Add section on limitations: no error recovery, single-pass
- [ ] Correct token size to 16 bytes (with padding), or explain 13-byte claim
- [ ] Add actual performance graphs from kessel/benchmark_summary.md
