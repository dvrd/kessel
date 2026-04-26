# Kessel

Fast, spec-focused, ESTree-compatible JavaScript parser written in [Odin](https://odin-lang.org/). Within ~4 % of [OXC](https://github.com/oxc-project/oxc) (Rust) by total runtime across the real-world corpus, with several headline files now beating OXC outright.

## What is Kessel?

Kessel parses JavaScript source code into an ESTree-compatible AST. It uses arena allocation, SIMD-accelerated lexing (ARM64 NEON), a Pratt expression parser, and a tightly-sized bump pool for AST nodes. Conformance: **98.51 %** on Test262 (parser-relevant fixtures).

## Performance

Benchmarked against OXC (Rust) on 467 real-world JavaScript files, 20 iterations per file, Apple Silicon (ARM64 macOS):

```
Faster than OXC (≤0.97x):     20 files  ( 4.3%)
At parity (0.97–1.03x):       41 files  ( 8.8%)
Slower (>1.03x):             406 files (86.9%)
```

| File | Size | Kessel | OXC | Ratio |
|------|------|--------|-----|-------|
| typescript.js    | 8.6 MB | 38.1 ms | 35.5 ms | 1.08x |
| cesium.js        | 4.7 MB | 32.6 ms | 31.3 ms | 1.04x |
| monaco.js        | 3.3 MB | 32.2 ms | 28.1 ms | 1.15x |
| antd.js          | 4.0 MB | 19.1 ms | 19.5 ms | **0.98x** |
| react-dom.dev.js | 1.0 MB |  3.3 ms |  3.4 ms | **0.99x** |
| d3.js            | 573 KB |  4.4 ms |  4.5 ms | **0.98x** |
| lodash.js        | 531 KB |  1.2 ms |  1.2 ms | **0.99x** |
| jquery.js        | 279 KB |  1.5 ms |  1.5 ms | **0.99x** |
| preact.js        |  11 KB |   146 µs |   138 µs | 1.06x |
| snabbdom.js      |   1 KB |     4 µs |     3 µs | 1.09x |

Distribution across all 467 files: median **1.17x**, mean 1.23x, p10 1.01x, p90 1.52x. Aggregate sum-time ratio **1.08x**; byte-weighted ratio **1.04x** (the 100 MB corpus parses in 4 % more wall-clock time than OXC overall).

Reproduce locally:

```bash
task bench:quick                # 10 headline files
task bench                      # all 467 files (~45 s)
task test:bench:regression      # gates against the locked baseline
```

### History

Kessel briefly held a median of ~0.78x (≈22 % faster than OXC) before the Test262 spec-conformance push in sessions 11–12 (per-token escape-flag tracking, `PrivateIdentifier` walker, contextual `await` / `yield` reservation lookups, expression-to-pattern conversion) regressed median throughput to 1.31x. The current numbers are the result of a follow-up reclaim pass (see `HANDOFF.md`) that:

* short-circuits the §15.7.3 private-name walker when no `PrivateIdentifier` was emitted,
* SIMD-scans identifier bodies on ARM64 NEON,
* defers dynamic-array allocation for empty argument / parameter / decorator / object / array / block / function / class / object-pattern bodies, and
* right-sizes the AST bump pool so files in the 4–64 KB band stop overflowing into the slow allocator path (preact.js alone went from 1924 overflows per parse to zero, 1.30x → 1.06x vs OXC).

Further wins are tracked in `HANDOFF.md`.

## Getting Started

Requires [Odin](https://odin-lang.org/docs/install/) (dev-2024-12 or later) and [Task](https://taskfile.dev/) for the task runner.

```bash
# Build
task build

# Run tests (unit + 467 real-world files)
task test

# Install to ~/.local/bin
task install
```

All tasks:

| Task | Description |
|------|-------------|
| `task build` | Build optimized binary |
| `task build:debug` | Build with debug info + bounds checks |
| `task test` | Run unit tests + real-world validation |
| `task test:unit` | Run 86 unit tests only |
| `task test:real` | Parse 467 real-world JS files |
| `task bench` | Full benchmark vs OXC (all 467 files) |
| `task bench:quick` | Benchmark 10 key files vs OXC |
| `task install` | Install kessel to `~/.local/bin` |
| `task uninstall` | Remove kessel from `~/.local/bin` |
| `task clean` | Remove build artifacts |

Or build directly:

```bash
odin build src -out:kessel_bin -o:speed -no-bounds-check
```

## Usage

### Parse a file

```bash
# AST as JSON to stdout
kessel parse app.js

# Compact JSON (no indentation)
kessel parse app.js --compact
```

### Parse multiple files

```bash
# Auto-detects CPU count for workers, writes AST to tmp/ast/
kessel parse src/*.js

# Custom output directory
kessel parse src/*.js --out-dir build/ast

# Override worker count
kessel parse src/*.js --workers 2
```

Output:
```
parse summary:
  Files: 50
  Bytes: 6495200 (6.50 MB)
  Errors: 0
  Time: 120 ms
  Throughput: 54.1 MB/s, 416.7 files/s
  Workers: 4
  Output:  build/ast/
```

Each file gets `<filename>.json` in the output directory.

### Tokenize

```bash
kessel lex app.js
```

### Benchmark

```bash
# Parse benchmark (100 iterations default)
kessel microbench parse app.js
kessel microbench parse app.js --iterations 500

# Lex benchmark
kessel microbench lex app.js --iterations 500
```

### Profile

```bash
# Parser profile: lex vs parse split, node allocs, bump pool stats
kessel profile parse app.js

# Lexer profile: throughput, bytes/token, ns/token
kessel profile lex app.js
```

## ES Features

- **ES2015+**: arrow functions, destructuring (object/array/nested/defaults), classes, template literals (nested), generators, modules, computed properties, spread/rest
- **ES2020**: optional chaining (`?.`), nullish coalescing (`??`), BigInt, dynamic import, `import.meta`
- **ES2022**: class fields, private fields/methods, static blocks, `#x in obj`
- **ES2025**: logical assignment, top-level await, class accessors
- Full ASI (automatic semicolon insertion)
- All keywords usable as property names
- Regex disambiguation via parser-directed relex
- Unicode identifiers

## Tests

```bash
# All tests (unit + real-world)
task test

# Just unit tests
task test:unit

# Just 467 real-world files
task test:real
```

## Project Structure

```
kessel/
├── src/
│   ├── main.odin       CLI: parse, lex, microbench, profile
│   ├── token.odin      TokenType, FastToken, LiteralValue
│   ├── lexer.odin      Lexer struct, init, tokenizer, all handlers
│   ├── simd.odin       ARM64 NEON: string scan, comment skip
│   ├── ast.odin        AST node definitions (ESTree)
│   └── parser.odin     Recursive descent + Pratt expression parser
├── tests/              86 test fixtures + runner
├── bench/
│   ├── real_world/     467 production JS files
│   └── oxc_compare/    OXC benchmark harness (Rust)
├── kessel_bin          Compiled binary
├── HANDOFF.md          Technical context for development
└── _archive/           Previous project structure (preserved)
```

## Architecture

```
Source (.js)
    │
    ▼
 Lexer ──── SIMD comment/string scanning (NEON)
    │        Per-letter keyword dispatch
    │        16-byte FastToken by value
    │
    ▼
 Parser ─── Pratt precedence climbing
    │        Bump-allocated AST nodes
    │        Arena-backed dynamic arrays
    │
    ▼
 AST JSON ─ Direct buffer, single write
```

Key design decisions:
- **Bump allocator** for AST nodes — zero-dispatch, scales with source size
- **FastToken (16 bytes)** passed by value — no indirection between lexer and parser
- **SIMD comment scanning** — `*/` pair detection in one NEON pass
- **Arena reuse** in benchmarks — `arena_free_all` instead of mmap/munmap per iteration
- **Lazy interner** — hash map only allocated on first `intern()` call (regex patterns)

## Known Limitations

- No TypeScript/JSX/Flow syntax
- No decorators (stage 3)
- Some complex destructuring assignment expressions may fail
- Early error validation incomplete

## License

MIT
