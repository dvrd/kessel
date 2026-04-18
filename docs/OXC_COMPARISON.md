# Kessel vs OXC: Comparative Architecture Analysis

## Context

Both Kessel and OXC parse JavaScript to AST, but take different implementation approaches:

- **OXC**: High-performance Rust parser with aggressive optimizations, used in production by Rolldown and Rspack
- **Kessel**: Educational/experimental Odin parser inspired by OXC architecture but optimized for simplicity and hackability

Both use arena-based allocation for efficient memory management and AST creation.

## 1. Lexer Byte Dispatch

### OXC Approach

**File**: `/Users/kakurega/dev/projects/oxc/crates/oxc_parser/src/lexer/byte_handlers.rs`

OXC uses a **jump table** dispatch mechanism:

```rust
pub type ByteHandler<C> = unsafe fn(&mut Lexer<'_, C>) -> Kind;
pub type ByteHandlers<C> = [ByteHandler<C>; 256];

// Macro-generated lookup table
pub static NO_TOKENS: ByteHandlers<NoTokensLexerConfig> = byte_handlers!();
```

Key features:
- **Direct indexing**: `byte_handlers[byte as usize](self)` — single indirect function call
- **Three monomorphized tables** (NoTokens/WithTokens/Runtime) — different configurations compiled separately
- **`assert_unchecked!` macros** — tell LLVM that bounds are guaranteed, eliminating runtime checks
- **Unsafe handlers**: Functions are `unsafe fn` allowing aggressive optimizations
- **Macro-based generation**: Reduces boilerplate, ensures consistency across 256 handlers

**Performance characteristic**: 1 indirect call per byte vs multi-branch switch. Branch predictor prefers indirect calls over long switches.

### Kessel Approach

**File**: `kessel/src/lexer/lexer_optimized.odin`

Kessel uses a **character class + switch** dispatch:

```odin
CHAR_CLASS_TABLE :: [256]CharClass  // Lookup character class

// In lexer loop
class := CHAR_CLASS_TABLE[byte]
switch class {
    case .Space: { /* handle space */ }
    case .Digit: { /* handle digit */ }
    case .Identifier: { /* handle identifier */ }
    // ... ~20 cases total
}
```

Characteristics:
- **Two-level dispatch**: Table lookup + switch statement
- **Fewer branches**: ~20 cases in switch vs 256 handlers in OXC
- **Grouped behavior**: Similar characters grouped (all digits → one case)
- **No macros**: Explicit, readable code
- **Single runtime flag-based configuration**: JSX context, strict mode checked at runtime

### Performance Gap: Why OXC is Faster

1. **Direct vs two-level dispatch**: OXC avoids the character class lookup overhead
2. **Monomorphization**: OXC generates 3 separate binary versions (no/with tokens, runtime). Kessel uses runtime flags
3. **Unchecked assertions**: OXC's unsafe hints let LLVM eliminate bounds checks and type checks; Kessel's Odin defaults to safe code
4. **Instruction density**: 256 function pointers (compact) vs character class lookup + switch comparison

**Estimated impact**: ~10-20% lexer speedup possible with OXC-style dispatch in Odin.

### Potential Adoption: Odin Jump Table

Odin supports procedure pointers:

```odin
LexerHandler :: proc(^Lexer) -> TokenType

byte_handlers := [256]LexerHandler {
    0: handle_nul,
    32: handle_space,
    48: handle_digit,
    // ... etc
}

// Usage
handler := byte_handlers[byte]
kind := handler(&lexer)
```

**Implementation effort**: Medium. Need to:
1. Define 256 handler procs (can be generated via code generator or macro equivalent)
2. Replace switch statement with table lookup
3. Use Odin's `#no_bounds_check` directive for the lookup itself

### Actual Experiment (2026-04-18)

Tested two approaches on `feat/byte-dispatch` branch:

1. **Proc pointer table (v1)**: `[256]proc(^Lexer2, Loc) -> CompactToken` with
   per-byte handlers. Result: **+1.5% slower** (P50 16552→16802 µs). Indirect call
   overhead (pointer load + branch misprediction) exceeds switch benefit.

2. **Action enum table (v2)**: `[256]ByteAction` → compact switch on ~20 actions.
   Result: **0% change** (P50 16552→16542 µs). LLVM already compiles the dense
   byte switch to a jump table; the enum indirection adds nothing.

**Conclusion**: OXC's byte dispatch advantage comes from Rust/LLVM-specific
optimizations (`unsafe fn`, monomorphized configs, aggressive inlining), not from
the table structure itself. Odin's LLVM backend already generates optimal jump
tables for dense byte switches.

**Verdict**: Byte dispatch rejected. The actual bottleneck was TokenSoA's 8
`append()` calls per token — replacing `[dynamic]T` with direct `[]T` stores
yielded **-61% lex-only, -33% full parse** (commit `86065d3`).

## 2. Arena Allocation Strategy

### OXC Approach

**File**: `/Users/kakurega/dev/projects/oxc/crates/oxc_allocator/README.md` + `src/arena/chunks.rs`

OXC uses **chunked bump allocation** (similar to `bumpalo` crate):

```rust
pub fn allocate(&mut self) -> &mut T {
    // Try current chunk's bump pointer
    if let Some(ptr) = self.current_chunk.bump_alloc(size_of::<T>()) {
        return ptr;
    }
    
    // Current chunk full, allocate new chunk
    self.new_chunk();
    self.current_chunk.bump_alloc(size_of::<T>())
}
```

Characteristics:
- **Chunked growth**: Arena grows by allocating new chunks as needed
- **No pre-sizing required**: Works with unknown input sizes
- **Minimal waste**: Small files don't allocate gigabytes
- **Multi-chunk iteration**: Supports introspection via `iter_allocated_chunks()`
- **Configuration**: Chunk sizes can be tuned for workload

### Kessel Approach

**File**: `kessel/src/lexer/lexer_optimized.odin:65`

Kessel uses **single pre-allocated block**:

```odin
estimate_arena_size :: proc(source_len: int) -> int {
    base_size := source_len * 256  // Heuristic: 256 bytes per source byte
    
    if base_size < 4 * 1024 * 1024 {
        return 4 * 1024 * 1024  // 4 MB MINIMUM FLOOR
    }
    
    return base_size
}

backing := make([]byte, estimate_arena_size(source_len))
mem.arena_init(&arena, backing)
```

Characteristics:
- **Pre-computed size**: Estimates upfront based on source length
- **Single allocation**: One contiguous block, no chunking
- **Generous heuristic**: 256 bytes per source byte (overshoots for safety)
- **4MB floor**: Small files get 4MB minimum, wasteful for tiny inputs
- **No dynamic growth**: If estimate is wrong, allocation fails (would need to reparse with larger size)

### Performance Gap: Memory Overhead on Small Files

For a typical 1 KB JavaScript file:

| Parser | Estimated Arena | Actual Used | Waste |
|--------|-----------------|------------|-------|
| OXC | ~64 KB (estimated) | ~20 KB | 70% |
| Kessel | 4 MB (floor) | ~20 KB | **99.5%** |

OXC's chunked approach means small files incur minimal overhead. Kessel's 4 MB floor dominates.

### Real-World Impact

From `kessel/benchmark_summary.md`:

```
Small files (1 KB):  Kessel ~12ms  (OXC ~2ms)  — 6x slower
Medium files (10 KB): Kessel ~15ms (OXC ~5ms)  — 3x slower
Large files (100 KB): Kessel ~70ms (OXC ~50ms) — 1.4x slower
```

The 4 MB floor and pre-sizing heuristic contribute to slowness on small files where startup dominates.

### Potential Adoption: Odin Dynamic_Arena

Odin's `mem.Dynamic_Arena` provides chunked allocation:

```odin
arena: mem.Dynamic_Arena
mem.dynamic_arena_init(&arena, 64 * 1024)  // Start with 64 KB chunks

alloc := mem.dynamic_arena_allocator(&arena)
node := new(ast.Node, alloc)  // Auto-chunks when needed

// At end of parsing
mem.dynamic_arena_destroy(&arena)
```

**Expected improvement**: Eliminating the 4 MB floor would save ~3-4 MB per small file parse. For batch workloads (linting 100 files), this is significant.

**Implementation effort**: Small. Mostly a drop-in replacement for `mem.Arena`.

## 3. AST Node Representation

### OXC Approach

**File**: `/Users/kakurega/dev/projects/oxc/crates/oxc_ast/src/ast/mod.rs`

OXC uses **explicit discriminant control** with `#[repr(C, u8)]`:

```rust
#[repr(C, u8)]
pub enum Expression<'a> {
    BooleanLiteral(Box<'a, BooleanLiteral>) = 0,
    NullLiteral(Box<'a, NullLiteral>) = 1,
    NumericLiteral(Box<'a, NumericLiteral>) = 2,
    // ... ~50 variants, manually numbered
    
    // Inherited variants (via macro)
    @inherit MemberExpression,  // Variants 48-50
}

#[repr(C, u8)]
pub enum MemberExpression<'a> {
    Computed(Box<'a, ComputedMemberExpression<'a>>) = 48,
    Static(Box<'a, StaticMemberExpression<'a>>) = 49,
    PrivateField(Box<'a, PrivateFieldExpression<'a>>) = 50,
}
```

Characteristics:
- **Explicit discriminant values**: Each variant numbered manually
- **Enum inheritance via macros**: Avoid nested enums, flatten hierarchy
- **Known memory layout**: `#[repr(C, u8)]` guarantees discriminant is 1 byte
- **Compact representation**: 1-byte discriminant, then payload
- **Deterministic**: Compiler can't optimize away discriminants

### Kessel Approach

**File**: `kessel/src/ast/ast.odin`

Kessel uses **union types** (Odin's tagged unions):

```odin
Expression :: union {
    ^NullLiteral,
    ^BooleanLiteral,
    ^NumericLiteral,
    ^StringLiteral,
    // ... ~50 types
    
    ^MemberExpression,
    ^CallExpression,
}

// Usage
expr: ^Expression
switch expr {
    case ^NullLiteral:
        // Handle null literal
    case ^BooleanLiteral:
        // Handle boolean
}
```

Characteristics:
- **Tagged unions**: Discriminant + pointer payload
- **Implicit layout**: Compiler decides discriminant size (usually 1-4 bytes depending on variant count)
- **Hierarchical**: Nested types are natural, no macro inheritance needed
- **Unknown discriminant size**: Depends on Odin's optimization choices

### Layout Comparison

| Aspect | OXC | Kessel |
|--------|-----|--------|
| Discriminant size | 1 byte (explicit) | 1-4 bytes (compiler-chosen) |
| Total node size | Depends on payload | Discriminant + pointer (8+ bytes) |
| Memory layout control | Full (repr(C, u8)) | Limited (default layout) |
| Debuggability | Can inspect discriminant | Requires pattern matching |
| Enum flattening | Via macros | Natural hierarchies |

**OXC advantage**: Explicit `u8` discriminant means better cache locality and memory layout knowledge for optimization. OXC can pack multiple nodes tightly.

**Kessel advantage**: Simpler code, no macro boilerplate, Odin's union syntax is natural.

### Potential Adoption: Explicit Union Layout

Odin may support tagged union layout hints:

```odin
Expression :: union #packed {  // Hypothetical: explicit discriminant size
    ^NullLiteral,
    ^BooleanLiteral,
    // ... will use minimal discriminant
}
```

**Expected impact**: Minor (typically 1-4 bytes per node). Less significant than dispatch or arena improvements.

## 4. Build-Time Configuration

### OXC Approach

OXC uses **type parameters** to create monomorphized specializations:

```rust
pub trait LexerConfig {
    fn byte_handlers() -> &'static ByteHandlers<Self>;
    fn skip_tokens() -> bool;
}

pub struct NoTokensLexerConfig;
pub struct TokensLexerConfig;
pub struct RuntimeLexerConfig;

// Compile three versions of Lexer<C> with C = each config
```

Effects:
- **Zero-cost abstractions**: Token collection code is literally not compiled when `NoTokens`
- **Specialized hot paths**: Each variant optimized independently
- **Binary size tradeoff**: 3x larger binary (unavoidable)
- **Compile time**: Longer (monomorphization)

### Kessel Approach

Kessel uses **runtime flags**:

```odin
Lexer2 :: struct {
    jsx_context: bool,
    strict_mode: bool,
    // ... flags checked at runtime
}

// In hot path
if l.jsx_context {
    // JSX-specific handling
}
```

Effects:
- **Small binary**: One binary, all features optional
- **Slower hot path**: Branch predictor helps, but still overhead
- **Uniform code path**: Easier to understand
- **Feature interaction bugs**: Flags can be inconsistently set

### Performance Impact

For a `no_tokens` variant, OXC entirely skips token collection:

```rust
if C::skip_tokens() {
    // Dead code (0 CPU cost)
    collect_token();
}
```

vs Kessel:

```odin
if l.collect_tokens {
    collect_token()  // Branch predicted, but still cycles
}
```

Estimated overhead: **2-5% per conditional** on modern CPUs (with good branch prediction).

## 5. Safety / Unchecked Hints

### OXC Approach

OXC heavily uses unsafe code with compiler hints:

```rust
pub(super) unsafe fn handle_byte(&mut self, byte: u8) -> Kind {
    let byte_handlers = self.config.byte_handlers();
    // SAFETY: Caller guarantees bounds — compiler eliminates checks
    unsafe { byte_handlers[byte as usize](self) }
}

// In handler macros
ascii_byte_handler!(SPS(lexer) {
    // Assertions tell LLVM next char is ASCII
    unsafe {
        assert_unchecked!(!lexer.source.is_eof());
        assert_unchecked!(lexer.source.peek_byte_unchecked() < 128);
    }
    // Compiler now optimizes away bounds checks
    lexer.consume_char()  // Single assembly instruction
});
```

**Strategy**: Heavy use of `unsafe` with comments, `assert_unchecked!` tells LLVM invariants, compiler optimizes accordingly.

### Kessel Approach

Kessel checks usage of unchecked operations:

```bash
$ grep -r "#no_bounds_check" kessel/src/lexer/
  # 0 matches — NO unchecked operations currently used
```

Kessel relies on Odin's default bounds checking, which is safe but slower.

### Unchecked Opportunities in Kessel

Potential candidates for `#no_bounds_check`:

1. **Character class lookup**: `CHAR_CLASS_TABLE[byte]` — byte is guaranteed 0-255
2. **Token array appends**: After capacity pre-estimated, appends are safe
3. **String indexing in identifier scanning**: Once we validate UTF-8, indexing is safe

Estimated impact: **2-5% speedup** from eliminated bounds checks.

### Potential Adoption

Odin has `intrinsics.assume()` and `#no_bounds_check` directive:

```odin
@(private="file")
CHAR_CLASS_TABLE :: [256]CharClass

get_char_class :: proc(b: u8) -> CharClass {
    #no_bounds_check return CHAR_CLASS_TABLE[b]
}
```

**Implementation effort**: Small. Audit hot paths, add directives, verify with profiling.

## 6. Measured Gap (2026-04-18)

After building a head-to-head comparison harness (`bench/oxc_compare/`), the
real ratios — not estimates — are:

| File | Kessel parse (P50) | OXC parse (P50) | Ratio |
|------|-------------------|-----------------|-------|
| 13 B (small) | 6.4 µs | 0.17 µs | **OXC 37.6× faster** |
| 2.6 KB (medium) | 68.5 µs | 10.4 µs | **OXC 6.6× faster** |
| 324 KB (large) | 14.3 ms | 2.2 ms | **OXC 6.5× faster** |

CLI wall-clock (both emitting full ESTree JSON):

| File | Kessel CLI | OXC CLI | Ratio |
|------|-----------|---------|-------|
| small | 1.7 ms | 1.7 ms | **Tie** (dominated by macOS process startup) |
| medium | 1.8 ms | 1.7 ms | Tie |
| large | 49.2 ms | 11.1 ms | OXC 5.0× faster *(was 5.4× pre-JSON-opts)* |

Multi-file batch (50 × 324 KB, bundler-style workload):

| Strategy | Time | vs OXC shell-loop |
|----------|------|-------------------|
| shell loop `oxc_cli_equiv` × 50 | 569 ms | baseline |
| **`kessel parse-many --workers 4`** | **309 ms** | **Kessel 1.84× faster** |
| `kessel parse-many --workers 1` | 895 ms | OXC 1.57× faster |

Full tables, methodology, and overhead breakdown: **see `docs/BENCHMARKS.md`**.

### Key findings

1. **The parser gap is structural (~6.5×)** — stable across medium/large files.
   Points to allocator + dispatch + codegen differences, not constants.
2. **Small-file CLI ratio is 1.0× (tie)** — macOS ~1.7 ms process floor
   dominates anything <3 KB regardless of parser speed.
3. **Output pipeline accounted for ~half of the large-file CLI gap** — reduced
   from 38.2 ms to ~35 ms via fmt.wprintf elimination (commit `fe0b310`).
4. **Multi-file CLI: Kessel wins** via `parse-many` amortized startup +
   thread pool. A bundler invoking parsers as CLI binaries gets 1.84×
   throughput from Kessel on Apple M1. (A bundler using OXC as a Rust
   library with its own threading would still beat Kessel.)

## 7. Actionable Items for Kessel

| # | Change | Effort | Measured Impact | Status |
|---|--------|--------|-----------------|--------|
| 1 | Virtual growing arena (mem.virtual.Arena) | Small | -98% mem floor, small-file latency -40% | ✅ **Merged** `683a708` |
| 2 | JSON output: bigger buffer + `out_s` primitives | Small | Within noise alone | ✅ **Merged** `55fd80a` |
| 3 | JSON output: replace `fmt.wprintf` hot paths | Medium | **-6.3% CLI large** (52.5 → 49.2 ms) | ✅ **Merged** `fe0b310` |
| 4 | `parse-many` command + thread pool | Medium | **2.94× scaling on M1 P-cores, 1.84× vs OXC shell-loop** | ✅ **Merged** `e4e8ca7` |
| 5 | Byte dispatch jump table | Medium | Est. 1.3–1.5× lexer speedup on large | Pending — needs microbench validation |
| 6 | Compact AST union discriminants | Medium | Est. 1.1–1.3× (cache locality) | Pending |
| 7 | `#no_bounds_check` in hot paths | Small | **No measurable impact** | ❌ **Rejected** `75d26fd` (within noise) |
| 8 | `#force_inline` helpers | Small | **No measurable impact** | ❌ **Rejected** (within noise) |

### Recommended next steps

1. **Byte dispatch table prototype** on a feature branch — with microbench as
   safety net (now that we have one). Validate >3 % parse speedup on medium
   or large before merging. Target: `docs/OXC_COMPARISON.md §1`.
2. **JSON output streaming** — attacks a different gap than the parser
   optimizations. Easy to measure via external `hyperfine` on large files.
3. **Profile on Linux** with `samply` or `perf` to validate that the lexer is
   actually the hot path before committing to byte-dispatch rewrite.

### Realistic Kessel performance goal

Closing the parser gap to ~3× of OXC (from current 6.5×) is plausible with
byte-dispatch + AST layout work. Matching OXC 1:1 is unlikely without
matching its allocator model (bumpalo-style chunked growth with typed
handles), which would be an architectural rewrite.

**Odin caveat**: Odin's codegen is younger than Rust's and LLVM is used in
both, but Rust's borrow checker + lifetime annotations give the optimizer
more information. Some fraction of the gap is fundamental to the language
choice.

## References

- OXC Parser: https://github.com/oxc-project/oxc
- OXC Allocator: https://github.com/oxc-project/oxc/tree/main/crates/oxc_allocator
- Odin mem package: https://github.com/odin-lang/Odin/tree/master/core/mem
- Bumpalo (OXC inspiration): https://docs.rs/bumpalo/latest/bumpalo/
