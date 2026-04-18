# SIMD Optimization Opportunities

**Date**: 2026-04-18
**Context**: Post direct-TokenSoA stores and compact JSON emitter.
**Current lexer P50**: 3297 µs on bench_large.js (324KB)

## Lessons from ehsanmok/json (Mojo GPU JSON parser)

### What they do on GPU
1. **Bitmap-based structural character detection** — parallel NEON/GPU compares
   for `{`, `}`, `[`, `]`, `:`, `,`, `"`, `\`
2. **Parallel prefix sums** — identify "in-string" regions (between quotes)
3. **GPU stream compaction** — extract only structural positions (116× data reduction)
4. **Fused kernels** — quote detection + escape handling in single pass

### What transfers to Kessel (CPU SIMD, ARM64 NEON)

| Technique | Kessel application | Est. impact |
|-----------|-------------------|-------------|
| Prefix-sum quote detection | String parsing: find closing quote while tracking escape state | Medium |
| Bitmap structural chars | Whitespace skip: detect whitespace + comment start in one SIMD pass | Medium |
| Fused quote+escape scan | `neon_find_quote` currently falls back to scalar on escape — fixable | High |
| Batch newline count | Already done via `neon_count_newlines` | Done |

### What doesn't transfer
- GPU stream compaction (needs GPU, not applicable to CPU parsing)
- Parallel bracket matching (JS grammar is too complex for parallel structural analysis)
- Batch file parsing on GPU (files too small, <100KB typical)

## Current SIMD Implementation Status

File: `kessel/src/lexer/simd.odin` (NEON intrinsics)

| Function | Status | Issue |
|----------|--------|-------|
| `neon_count_whitespace` | ✅ Working | Falls back to scalar for newline counting inside SIMD chunk |
| `neon_count_ident` | ✅ Working | `simd_reduce_and` then scalar fallback — could use CLZ/CTZ |
| `neon_find_quote` | ⚠️ Suboptimal | Falls back to scalar on ANY escape, even if escape is after quote |
| `neon_count_newlines` | ✅ Working | Good |
| `neon_find_non_ws` | ✅ Working | Good |

## Proposed SIMD Optimizations (ordered by expected impact)

### 1. Prefix-sum quote detection for string parsing

**Current**: `neon_find_quote` finds ANY quote, then scalar checks if it's escaped.
If escape exists ANYWHERE in chunk, entire chunk falls back to scalar.

**Proposed**: Use ehsanmok's approach — bitmap of quotes, bitmap of backslashes,
then XOR to find unescaped quotes. This is O(1) for the entire 16-byte chunk.

```
quotes:      [0,0,0,1,0,0,0,0,0,0,0,0,0,0,1,0]   // positions of "
backslashes: [0,0,1,0,0,0,0,0,0,0,0,0,0,0,0,0]   // positions of \
escaped:     [0,0,0,1,0,0,0,0,0,0,0,0,0,0,1,0]   // quotes shifted right by \
real_quotes: quotes & ~escaped                      // only unescaped "
```

**Est. impact**: ~5-10% on files with many strings (bench_large.js has thousands).
**Complexity**: Medium. Need to handle multi-byte escapes (`\u{...}`).

### 2. SIMD structural character bitmap

**Current**: `skip_whitespace_scalar` handles whitespace + comments in scalar loop.

**Proposed**: In `skip_whitespace_simd_lex`, create a NEON bitmap of:
- Whitespace chars (space, tab, CR, LF)
- Comment starters (`/`)
- Everything else

Then use CTZ (count trailing zeros) to find the first non-whitespace byte
without scalar fallback.

**Est. impact**: ~3-5% on whitespace-heavy files.
**Complexity**: Low. Just need CTZ instead of scalar inner loop.

### 3. Fused whitespace + comment detection

**Current**: SIMD skip whitespace, then scalar checks for `//` and `/*`.

**Proposed**: After SIMD finds non-whitespace, check if it's `/` and peek
the next byte — all in the SIMD result. Avoids re-reading memory.

**Est. impact**: ~2-3% on comment-heavy files.
**Complexity**: Low.

## JSON I/O Optimization Roadmap

### Current bottleneck decomposition (bench_large.js CLI)

| Phase | Time | % of total |
|-------|------|------------|
| Parse (lexer + parser) | ~11 ms | 42% |
| JSON emit (compact) | ~13 ms | 50% |
| Process startup + I/O | ~3 ms | 8% |
| **Total CLI** | **~27 ms** | — |

With --compact flag, JSON emit dropped from ~35ms to ~13ms. Further gains:

### Short-term: Make --compact the default

The `--compact` flag produces valid JSON that's 53% smaller.
For CLI usage (piping to jq, etc.), compact is fine.
Only keep pretty for `--pretty` explicit flag.

### Medium-term: SIMD-accelerated JSON string escaping

Current `out_string()` escapes byte-by-byte. With NEON:
- Load 16 bytes
- Compare against chars needing escape (`"`, `\`, control chars < 0x20)
- For clean chunks (no escapes), memcpy directly
- For dirty chunks, use lookup table for escape sequences

This would help both pretty and compact modes.

### Long-term: Arena-backed string builder

Instead of writing to bufio.Writer per-field, build the entire JSON
in a pre-allocated arena buffer (we know the AST node count), then
`write()` once. Eliminates thousands of function calls.

Est. impact: ~20-30% of JSON emit time.

## What doesn't help

1. **GPU for JS parsing** — files too small (<100KB), grammar too complex
2. **GPU for JSON output** — serialization is inherently sequential (walking a tree)
3. **SIMD for parser** — parser is recursive descent with branching; SIMD doesn't apply
4. **Parallel JSON emit** — tree structure requires sequential traversal

## Revised OXC Gap Tracker

| Metric | Session start | Current | Target |
|--------|--------------|---------|--------|
| CLI large (pretty) | 52.5 ms | 45.0 ms | — |
| CLI large (compact) | N/A | **27.0 ms** | 20 ms |
| Parse P50 (in-process) | 16.2 ms | **10.7 ms** | 8 ms |
| Lex-only P50 | 8.5 ms | **3.3 ms** | 2.5 ms |
| OXC CLI gap | 5.4× | **1.73×** (compact) | <1.5× |
| OXC parse gap | 6.5× | **4.6×** | 3× |
