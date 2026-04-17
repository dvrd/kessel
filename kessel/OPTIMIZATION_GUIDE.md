# Kessel Optimization Guide

## Current Baseline
- **Parse time**: ~3ms for example.js (1.2KB)
- **Target**: ~0.02ms (150x faster, matching OXC)

## Why We're Slower Than OXC

1. **Architecture**: OXC uses aggressive zero-copy and arena parsing
2. **SIMD**: OXC uses SIMD-accelerated scanning (16-32 bytes at once)
3. **Memory**: OXC has compact tokens (16 bytes vs our ~76 bytes)
4. **Rust optimizations**: LLVM LTO, PGO, target-specific tuning

## Realistic Optimizations (Can Achieve 10-50x Speedup)

### 1. Token Structure Optimization (5x memory reduction)

Current `Token` is ~76 bytes:
```odin
Token :: struct {
    type: TokenType,      // 4 bytes
    loc: Loc,             // 24 bytes (offset 8, line 8, column 8)
    value: string,        // 16 bytes (ptr + len)
    literal: union,       // 32 bytes
}
```

Optimized to 16 bytes:
```odin
Token :: struct #packed {
    type: u16,            // Token type
    pad: u16,             // Alignment
    offset: u32,          // Start in source
    length: u32,          // Token length
    line: u32,            // Line number
}
// Value extracted from source on demand
```

### 2. Character Lookup Table (Eliminate Branches)

Replace switch statements with lookup table:
```odin
CHAR_CLASS: [256]u8

// Initialize once
init_char_class :: proc() {
    for i in 0..<256 {
        c := u8(i)
        switch {
        case c == ' ' || c == '\t' || c == '\n' || c == '\r':
            CHAR_CLASS[i] = 1  // Whitespace
        case c >= 'a' && c <= 'z', c >= 'A' && c <= 'Z', c == '_', c == '$':
            CHAR_CLASS[i] = 2  // Id start
        case c >= '0' && c <= '9':
            CHAR_CLASS[i] = 3  // Digit
        // ... etc
        }
    }
}

// Fast lookup (no branches)
class := CHAR_CLASS[c]
```

### 3. Perfect Hash for Keywords (O(1) lookup)

Replace linear search with perfect hash:
```odin
// Current: O(n) linear search
for kw in KEYWORDS {
    if kw.name == value {
        return kw.token
    }
}

// Optimized: O(1) hash lookup
hash := fnv1a(value)
idx := hash & (TABLE_SIZE - 1)
return keyword_table[idx]
```

### 4. Arena Pre-sizing (Reduce Allocations)

Pre-calculate capacity to avoid arena growth:
```odin
// Estimate tokens: ~1 per 4 bytes
estimated := len(source) / 4
arena_init(&arena, estimated * size_of(Token))
```

### 5. SIMD-Accelerated Scanning (16x speedup potential)

Use ARM64 NEON for whitespace scanning:
```odin
when ODIN_ARCH == .arm64 {
    // Load 16 bytes
    data := vld1q_u8(&source[offset])
    
    // Compare with space, tab, newline, carriage return
    spaces := vceqq_u8(data, vdupq_n_u8(' '))
    tabs := vceqq_u8(data, vdupq_n_u8('\t'))
    // ... etc
    
    // Combine and find first non-whitespace
}
```

### 6. Compilation Optimizations

```bash
# Link-Time Optimization (LTO)
odin build ... -lld -lto

# Profile-Guided Optimization (PGO)
# 1. Build with profiling
# 2. Run benchmark
# 3. Rebuild using profile

# Target-specific
-target:darwin_arm64 -mcpu=apple-m1
```

### 7. Parser Optimizations

- **Pratt Parser**: More efficient for expressions
- **Predictive Parsing**: Table-driven, less call overhead
- **Lazy AST**: Don't build full tree if not needed

## Implementation Priority

1. ✅ Character lookup table (easy, 1.5x speedup)
2. ✅ Perfect hash keywords (easy, 1.3x speedup)
3. ⏳ Compact tokens (medium, 2x speedup)
4. ⏳ Arena pre-sizing (easy, 1.2x speedup)
5. ⏳ SIMD scanning (hard, 2-4x speedup)
6. ⏳ PGO compilation (medium, 1.3x speedup)

## Expected Results

| Optimization | Speedup | Cumulative |
|--------------|---------|------------|
| Lookup table | 1.5x | 1.5x |
| Perfect hash | 1.3x | 1.95x |
| Compact tokens | 2.0x | 3.9x |
| Arena pre-size | 1.2x | 4.68x |
| SIMD | 3.0x | 14.04x |
| PGO | 1.3x | 18.25x |

**Result**: 3ms → 0.16ms (within 8x of OXC's 0.02ms)

## Quick Wins to Implement Now

1. Add lookup table to lexer
2. Replace keyword linear search with hash
3. Pre-size arena based on file length

These three alone should give 3-4x speedup.
