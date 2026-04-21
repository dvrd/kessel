# Handoff — Kessel JavaScript Parser

## What is Kessel

A JavaScript parser written in Odin that's faster than OXC (Rust) on 97% of 467 real-world files. Produces ESTree-compatible AST. Has a zero-copy raw transfer path for cross-language integration that's 2-5x faster than OXC's parseSync NAPI binding.

## Current State

### Correctness
- **86/86** unit tests pass
- **467/467** real-world JS files parse with 0 errors (typescript.js 9MB, react, vue, d3, jquery, lodash, etc.)
- **8/8** key files verified against OXC parseSync output field-by-field

### Performance vs OXC (Rust) — Parse Only
Benchmarked on 467 files with arena reuse (`arena_free_all` per iteration):
```
Faster (≤0.97x):  454 files (97%)
Parity (0.97–1.03x):  9 files (2%)
Slower (>1.03x):       4 files (1%)
```
Median ratio: ~0.78x (22% faster than Rust).

### Performance vs OXC — JS Integration
Kessel raw transfer vs OXC parseSync (what a JS consumer actually pays):
```
preact.js   11KB    0.34x  (3x faster)
jquery.js   285KB   0.46x  (2x faster)
d3.js       587KB   0.38x  (2.6x faster)
antd.js     4.2MB   0.36x  (2.8x faster)
cesium.js   5.0MB   0.32x  (3x faster)
typescript  9.0MB   0.46x  (2.2x faster)
```

## Build & Run

Requires [Odin](https://odin-lang.org/) and [Task](https://taskfile.dev/).

```bash
task build                  # → bin/kessel
task test                   # 86 unit tests + 467 real-world files
task bench:quick            # 10 key files vs OXC
task install                # → ~/.local/bin/kessel
```

Or directly: `odin build src -out:bin/kessel -o:speed -no-bounds-check`

## CLI

```bash
kessel parse app.js                          # JSON AST to stdout
kessel parse src/*.js                        # parallel parse, AST files to tmp/ast/
kessel parse src/*.js --out-dir build/ast    # custom output dir
kessel lex app.js                            # tokens as JSON
kessel raw app.js --out ast.bin              # raw transfer binary buffer
kessel microbench parse app.js               # parse benchmark
kessel microbench lex app.js                 # lex benchmark
kessel profile parse app.js                  # parser profile (lex/parse split, alloc stats)
kessel profile lex app.js                    # lexer profile (throughput, ns/token)
```

## Project Structure

```
kessel/
├── src/                    All source code (package main, 7 files, 9,459 lines)
│   ├── token.odin          TokenType enum, Token, FastToken, LiteralValue, LiteralType
│   ├── lexer.odin          Lexer struct, init, char tables, tokenizer, all token handlers
│   ├── simd.odin           ARM64 NEON: string end scan, line/block comment skip
│   ├── ast.odin            ESTree AST node definitions
│   ├── parser.odin         Recursive descent + Pratt expression parser
│   ├── raw_transfer.odin   Zero-copy binary AST buffer (pointer→offset rewriting)
│   └── main.odin           CLI entry point
├── tests/
│   ├── run_tests.sh        86 unit test fixtures
│   ├── verify_integration.js   OXC-compared field-by-field verification
│   └── verify_raw.js       Raw buffer structure verification
├── bench/
│   ├── real_world/         467 production JS files (4 batches)
│   ├── oxc_compare/        OXC Rust benchmark binary
│   └── bench_integration.js    Kessel raw vs OXC parseSync benchmark
├── Taskfile.yml            Build, test, bench, install tasks
├── bin/                    Build output (gitignored)
├── _archive/               Previous project structure (preserved)
└── README.md
```

## Architecture

```
Source (.js)
    │
    ▼
  Lexer ──── SIMD comment/string scanning (NEON)
    │         Per-letter keyword dispatch
    │         16-byte FastToken by value (cur/nxt two-token window)
    │
    ▼
  Parser ─── Pratt precedence climbing (iterative, not recursive for binops)
    │         Bump-allocated AST nodes (zero-dispatch)
    │         Arena-backed dynamic arrays (for node children)
    │         Identifier hot-path inlined in parse_unary_expr
    │
    ├──→ JSON AST ─── Direct buffer, single write to stdout
    │
    └──→ Raw Transfer ─── Walk AST, rewrite pointers to u32 offsets
                          Buffer = arena memory, readable from any language
```

### Memory Layout

Single contiguous virtual memory arena (mmap). Everything lives here:

```
[arena base] ─────────────────────────────────────── [arena base + total_used]
  [bump pool: AST nodes]  [dynamic array data]  [...]
```

- **Bump pool**: AST node structs, allocated with inline bump (3 instructions, no dispatch)
- **Dynamic arrays**: `[dynamic]T` for variable-length children (body, params, arguments)
- Both are sub-regions of the same arena — contiguous in virtual address space
- Pool scales with source: `max(8MB, source_len * 15)`

### Raw Transfer Encoding

After parsing, `rewrite_ast_pointers` walks the AST and rewrites every native pointer to a u32 offset from the arena base:

| Type | Native (Odin) | Rewritten (buffer) |
|------|--------------|-------------------|
| `^T` (pointer) | 8-byte address | u32 offset (0=nil) |
| `string` | {ptr:8, len:8} | {u32 source_byte_offset, u32 len} |
| `[dynamic]T` | {ptr:8, len:8, cap:8, alloc:16} | {u32 data_offset, u32 len} |
| `union{^A,^B}` | {ptr:8, tag:1, pad:7} | {u32 offset, pad:4, tag:1, pad:7} |
| `Maybe(^T)` | 8-byte ptr (nil=0) | u32 offset (0=nil) |

File format: `[RawTransferHeader: 20 bytes][arena bytes]`

Header: `{magic:u32 "KESS", version:u32, program_offset:u32, source_len:u32, total_bytes:u32}`

**Important**: string offsets are BYTE offsets into the UTF-8 source, not character offsets. JS consumers must use `Buffer.toString('utf8', start, end)`, not `String.substring()`.

## Key Design Decisions

1. **Bump allocator for AST nodes** — `bump_alloc` is 3 instructions inline, no function pointer dispatch. Falls back to arena on overflow (tracked by `overflow_count`).

2. **FastToken (16 bytes by value)** — No indirection between lexer and parser. Two-token window (`cur`/`nxt`) on the Lexer struct. Parser reads `cur` fields directly.

3. **SIMD comment scanning** — `simd_skip_block_comment` searches for `*/` pair in one NEON pass (compares chunk AND chunk+1 simultaneously). Eliminates false positives from lone `*` in JSDoc comments.

4. **Arena reuse in microbench** — Single `arena_init_static` + `arena_free_all` per iteration instead of mmap/munmap. This is what made us faster than OXC on small files.

5. **Lazy interner** — String interning map only allocated on first `intern()` call (only used for regex patterns). Zero cost for 99% of files.

6. **For-loop init_decl quirk** — `ForStatement.init_decl` and `ForInStatement.left_decl` store `Maybe(^VariableDeclaration)` but the actual pointer is a transmuted `^Statement`. The raw transfer handles this by treating them as `^Statement` for rewriting (see `raw_transfer.odin` ForStatement handler).

## ES Features Implemented

ES2015+: arrow functions, destructuring, classes, template literals (nested), generators, modules, computed properties, spread/rest. ES2020: optional chaining, nullish coalescing, BigInt, dynamic import, import.meta. ES2022: class fields, private fields/methods, static blocks. ES2025: logical assignment, top-level await. Full ASI, all keywords as property names, regex disambiguation via parser-directed relex, Unicode identifiers.

## Known Limitations

- No TypeScript/JSX/Flow syntax
- No decorators (stage 3)
- Some complex destructuring assignment expressions may fail
- Early error validation incomplete
- `Literal` node type not used (we use `NumericLiteral`, `StringLiteral`, etc. — differs from ESTree's generic `Literal`)

## What To Work On Next

### 1. JS SDK / NAPI Binding
The raw transfer buffer is ready. Next step: create an npm package that:
- Spawns kessel or links as a native addon
- Provides `parseSync(source)` that returns lazy AST accessors reading from the buffer
- Each node is a thin wrapper: `class Node { constructor(buf, off) {} get type() { return TYPES[buf.getUint8(off)] } }`
- No JS objects created until a field is accessed

### 2. WASM Target
Odin has experimental `wasm32` support. The raw transfer path is ideal for WASM — the buffer IS shared memory between WASM and JS.

### 3. ESTree Full Compliance
- Use `Literal` instead of `NumericLiteral`/`StringLiteral`/`BooleanLiteral` (or provide a compat layer)
- Verify more node types in the integration test (currently only checks ~15 expression types)
- Run against the full ESTree test suite

### 4. Expand Integration Verification
`tests/verify_integration.js` currently checks ~5-80 fields per file. Needs recursive walk of ALL nodes, not just top-level + first expression depth. Target: verify every node in preact.js (smallest real file).

### 5. Performance: Eliminate the Rewrite Pass
Current raw transfer does parse → rewrite (two passes). The rewrite adds ~22% overhead. Could be eliminated by:
- Changing the parser to write offsets directly during parsing
- This requires all AST pointers to be u32 offsets instead of native pointers
- Major refactor but would make raw transfer zero-overhead

### 6. Multi-file Raw Transfer
`kessel parse *.js --out-dir` currently writes JSON per file. Should support `--raw` flag to write binary buffers instead, using the parallel worker infrastructure.

## Benchmark Commands

```bash
# Quick comparison vs OXC (10 key files)
task bench:quick

# Full suite (467 files)
task bench

# Integration benchmark (Kessel raw vs OXC parseSync from Node.js)
node bench/bench_integration.js bench/real_world/typescript.js bench/real_world/jquery.js

# Integration verification (compare AST against OXC field by field)
node tests/verify_integration.js bench/real_world/jquery.js

# Raw transfer inspection
kessel raw bench/real_world/jquery.js --out /tmp/jquery.bin
node tests/verify_raw.js /tmp/jquery.bin bench/real_world/jquery.js
```
