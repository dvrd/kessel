# Kessel Maximum Optimization Plan

## Goal: Match OXC speed (~0.02ms for small files)

## Phase 1: Measure & Identify Bottlenecks

### 1.1 Token Representation Optimization
Current: `Token` struct is ~40 bytes
Target: Compact to 16-24 bytes

```odin
// Current
Token :: struct {
    type:     TokenType,    // 4 bytes
    loc:      Loc,          // 24 bytes (Span 16 + line 4 + column 4)
    value:    string,        // 16 bytes (ptr + len)
    literal:  LiteralValue,  // 32 bytes (union)
}
// Total: ~76 bytes!

// Optimized
Token :: struct {
    type:     TokenType,    // 2 bytes (u16)
    _pad:     u16,          // 2 bytes padding
    offset:   u32,          // 4 bytes (start offset in source)
    length:   u32,          // 4 bytes (token length)
    line:     u32,          // 4 bytes
}
// Total: 16 bytes (4.75x smaller!)
```

### 1.2 Lexer Optimizations

#### A. Branchless Character Class Detection
```odin
// Current: Switch statement (branch-heavy)
switch c {
case ' ', '\t', '\r', '\n': // whitespace
case 'a'..='z', 'A'..='Z': // identifier
case '0'..='9':            // number
}

// Optimized: Lookup table (cache-friendly)
CHAR_TABLE: [256]u8 : {
    // 0 = other, 1 = whitespace, 2 = id_start, 3 = id_cont, 4 = digit
}
class := CHAR_TABLE[c]
```

#### B. SIMD-Accelerated Whitespace Detection
Use ARM64 NEON or x86 SSE to check 16 bytes at once

#### C. Perfect Hash for Keywords
Current: O(n) linear search or hash with collisions
Target: O(1) perfect hash (CMPH algorithm)

### 1.3 Memory Layout Optimizations

#### A. Structure of Arrays (SoA) for Tokens
```odin
// Current: Array of structs
Tokens: []Token

// Optimized: Struct of arrays
TokenSoA :: struct {
    types:  []u16,
    offsets:[]u32,
    lengths:[]u32,
    lines:  []u32,
}
```

#### B. Arena Pre-sizing
```odin
// Pre-calculate needed size to avoid reallocations
estimated_tokens := source_len / 4  // ~4 bytes per token avg
arena_alloc(&arena, Token, estimated_tokens)
```

### 1.4 Parser Optimizations

#### A. Predictive Parsing
Replace recursive descent with table-driven predictive parser
- Faster: Single state machine, less function call overhead
- Harder to maintain but much faster

#### B. Pratt Parser for Expressions
More efficient than recursive descent for operators

#### C. Lazy AST Construction
Don't build full AST if only need validation

### 1.5 Compilation Optimizations

#### A. Link-Time Optimization (LTO)
```bash
odin build ... -lld -lto
```

#### B. Profile-Guided Optimization (PGO)
1. Build with instrumentation
2. Run representative workload
3. Rebuild using profile data

#### C. Target-Specific Tuning
```bash
# For ARM64 (Apple Silicon)
-target:darwin_arm64 -mcpu=apple-m1

# For x86
-target:linux_amd64 -mcpu=sandybridge
```

## Phase 2: Implement Critical Optimizations

Priority order (highest impact first):

1. ✅ Compact Token struct (4.75x memory reduction)
2. ✅ Character lookup table (eliminate branches)
3. ✅ Perfect hash for keywords
4. ⏳ SIMD whitespace (16x speedup potential)
5. ⏳ SoA token storage (cache efficiency)
6. ⏳ Arena pre-sizing (reduce allocations)
7. ⏳ Expression Pratt parser
8. ⏳ PGO build

## Expected Results

| Optimization | Speedup | Cumulative |
|--------------|---------|------------|
| Compact tokens | 1.2x | 1.2x |
| Lookup table | 1.5x | 1.8x |
| Perfect hash | 1.3x | 2.3x |
| SIMD | 2.0x | 4.6x |
| SoA | 1.4x | 6.5x |
| Pre-sizing | 1.2x | 7.8x |
| Pratt parser | 1.5x | 11.7x |
| PGO | 1.3x | 15.2x |

Target: 4ms → 0.26ms (within striking distance of OXC's 0.02ms)
