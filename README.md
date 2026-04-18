# Kessel

Fast JavaScript Parser written in [Odin](https://odin-lang.org/) — inspired by [OXC](https://github.com/oxc-project/oxc).

## What is Kessel?

Kessel is a high-performance JavaScript parser that transforms JS source code into an Abstract Syntax Tree (AST). Built with speed and memory efficiency as primary goals, it uses arena allocation, SIMD-accelerated lexing, and structure-of-arrays token storage to achieve parse speeds competitive with native parsers.

## Features

- ⚡ **Arena-based memory allocation** — O(1) allocation/free, perfect cache locality
- 🚀 **SIMD-accelerated lexing** — SSE2/AVX2/NEON whitespace scanning
- 📦 **Structure of Arrays token storage** — cache-friendly token layout
- 🎯 **Hand-written recursive descent parser** — full control over parsing logic
- 🔧 **Automatic semicolon insertion** — handles optional semicolons per ECMAScript spec
- 📊 **JSON AST output** — compatible with ESTree specification
- 📝 **Tokenizer mode** — output token stream for debugging

## Building

Requires [Odin compiler](https://odin-lang.org/docs/install/) (dev-2024-12 or later).

```bash
# Clone or navigate to repo
cd kessel

# Release build (optimized)
odin build ./src -out:../kessel_bin -o:speed

# Debug build
odin build ./src -out:../kessel_bin -debug
```

## Usage

### Parse a JavaScript file

```bash
./kessel_bin parse file.js
```

Outputs JSON AST to stdout:

```json
{
  "type": "Program",
  "body": [
    {
      "type": "VariableDeclaration",
      "kind": "let",
      "declarations": [
        {
          "type": "VariableDeclarator",
          "id": {
            "type": "Identifier",
            "name": "x"
          },
          "init": {
            "type": "NumericLiteral",
            "value": 42
          }
        }
      ]
    }
  ]
}
--- Statistics ---
Arena used: 4096 bytes
Parse errors: 0
```

### Tokenize a JavaScript file

```bash
./kessel_bin lex file.js
# or
./kessel_bin tokenize file.js
```

### Parse many files in parallel (batch mode)

For bundler/linter workloads. Amortizes process startup across files and
parallelizes via a thread pool:

```bash
# Default: auto-pick worker count (8)
./kessel_bin parse-many src/*.js

# Explicit worker count (recommended: 4 on Apple Silicon M1)
./kessel_bin parse-many src/*.js --workers 4
```

Example output:

```
parse-many summary:
  Files: 50
  Bytes: 6495200 (6.50 MB)
  Errors: 0
  Time: 309 ms
  Throughput: 54.32 MB/s, 167 files/s
  Workers: 4
```

See [Performance](#performance) for scaling numbers.

### In-process microbench

Measures parse cost only (excludes process startup + JSON output):

```bash
./kessel_bin microbench bench_large.js --iterations 100
```

Reports Mean, Min, Max, P50, P95, P99 in microseconds.

### Show help

```bash
./kessel_bin help
```

## Running Tests

```bash
# Run all parser tests
cd kessel/tests && ./run_tests.sh

# Run specific test suite
cd kessel/tests && ./run_tests.sh expressions
```

## Test Coverage

- **86 test fixtures** across 8 categories:
  - `basic/` — const, let, var, if/else, loops, switch, try/catch
  - `edge/` — labeled statements, comma operator, regex, IIFE variants, generators, tagged templates
  - `es2015/` — arrow functions, template literals, destructuring, spread/rest, classes
  - `es2020/` — optional chaining, nullish coalescing, BigInt, dynamic import
  - `es2022/` — class fields, private members, static blocks
  - `es2025/` — logical assignment, async/await, for-await-of, error cause
  - `real/` — jQuery chains, Express routes, Redux reducers, React hooks, middleware patterns
  - `recovery/` — missing semicolons, extra semicolons, trailing commas, unicode recovery
- **Pass rate: 100%** (86/86 tests)

## Architecture

See [ARCHITECTURE.md](./ARCHITECTURE.md) for detailed documentation on:
- Pipeline design (lexer → tokens → parser → AST → JSON)
- Key design decisions (arena allocation, SoA tokens, SIMD)
- File structure and component overview
- Guide for extending the parser

```
┌─────────────┐    ┌─────────────┐    ┌─────────────┐    ┌─────────────┐
│   Source    │───▶│    Lexer    │───▶│   Parser    │───▶│     AST     │
│   (.js)     │    │ SIMD + Hash │    │   (SoA)     │    │  (Arena)    │
└─────────────┘    └─────────────┘    └─────────────┘    └─────────────┘
                                                                │
                                                                ▼
                                                         ┌─────────────┐
                                                         │   JSON      │
                                                         │   Output    │
                                                         └─────────────┘
```

## Known Limitations

- **No TypeScript support** — parsing `.ts` files will fail on type annotations
- **No JSX support** — React JSX syntax is not recognized
- **Limited strict mode validation** — parses strict mode but doesn't validate all restrictions
- **No source maps** — AST locations are line/column only
- **Early errors incomplete** — some ECMAScript "early error" checks not implemented

## Project Structure

```
.
├── ARCHITECTURE.md      # Detailed architecture documentation
├── README.md           # This file
├── kessel_bin          # Compiled binary (after build)
├── kessel/
│   ├── src/
│   │   ├── main.odin          # CLI entry point
│   │   ├── lexer/             # Lexer + token definitions
│   │   ├── parser/            # Recursive descent parser
│   │   └── ast/               # AST node definitions
│   ├── tests/                 # Test fixtures and runner
│   └── lib/                   # FFI bindings for Node.js
└── ...
```

## LLM Evaluation

The `eval/` directory contains a harness for benchmarking how different LLMs solve real-world Kessel implementation tasks. This evaluates models on three challenges: octal/binary number parsing, destructuring defaults, and Unicode identifiers. See [eval/README.md](./eval/README.md) for setup and usage.

## Performance

Two measurement modes, both reproducible (see [`docs/BENCHMARKS.md`](./docs/BENCHMARKS.md)):

### Parse cost (microbench, in-process loop)

Isolates the parser from process startup and JSON output. Measured with
`./kessel_bin microbench <file> --iterations N`:

| File size | Kessel P50 | OXC P50 | Ratio |
|-----------|-----------|---------|-------|
| 13 B | 6.4 µs | 0.17 µs | OXC 37.6× |
| 2.6 KB | 68.5 µs | 10.4 µs | OXC 6.6× |
| 324 KB | 14.3 ms | 2.2 ms | **OXC 6.5×** |

### CLI wall-clock (hyperfine, full ESTree JSON output)

| File size | Kessel | OXC | Notes |
|-----------|--------|-----|-------|
| 13 B | 1.7 ms | 1.7 ms | Tie — macOS process startup (~1.2 ms) dominates |
| 2.6 KB | 1.8 ms | 1.7 ms | Tie — still startup-bound |
| 324 KB | 49.2 ms | 11.1 ms | OXC 5.0× faster single-file |

### Multi-file (batch, where Kessel wins)

50 × 324 KB = 16.3 MB, the kind of workload a bundler actually does:

| Strategy | Time |
|----------|------|
| shell loop calling `oxc_cli_equiv` × 50 | 569 ms |
| **`kessel parse-many --workers 4`** | **309 ms** (1.84× faster than OXC shell-loop) |
| `kessel parse-many --workers 1` | 895 ms |

Single-file CLI gap disappears when batching: `parse-many` amortizes process
startup across files (1 startup total) and parallelizes via thread pool
(2.94× scaling on 4 P-cores).

**Honest summary**: On single-file **parser algorithm**, Kessel is ~6.5× behind
OXC (measurable via microbench). On **single-file CLI** on macOS, the gap is
5× on large files, invisible on small ones (process startup floor). On
**multi-file CLI workloads**, Kessel's `parse-many` beats OXC's per-file
shell-loop by ~2×. A Rust consumer using OXC as a library with its own
threading would still be faster than Kessel.

See [`docs/OXC_COMPARISON.md`](./docs/OXC_COMPARISON.md) for technique-by-technique
analysis and [`docs/BENCHMARKS.md`](./docs/BENCHMARKS.md) for full methodology.

### Memory

Migrated to `mem.virtual.Arena` with 64 KB lazy-committed initial block (commit [`683a708`](./CHANGELOG.md)):

| Input size | Arena used | Arena reserved | Utilization |
|------------|-----------|----------------|-------------|
| < 1 KB | ~90 KB | 131 KB (virtual) | ~70 % |
| 2.6 KB | 259 KB | 524 KB (virtual) | 50 % |
| 324 KB | 41 MB | 83 MB (virtual) | 50 % |

Migration eliminated the previous 4 MB floor: 100× 1 KB files now use ~13 MB
total instead of 400 MB.

### Benchmark your system

```bash
# Simple sweep (internal microbench + hyperfine on 3 sizes)
bash kessel/bench.sh

# Head-to-head vs OXC (requires cloning OXC — see bench/oxc_compare/README.md)
bash kessel/bench_vs_oxc.sh
```

## License

MIT License — see LICENSE file for details.

## Contributing

This is a learning project focused on parser implementation techniques. Contributions welcome for:
- Additional ECMAScript features
- Test coverage improvements
- Documentation enhancements
- Performance optimizations

See [ARCHITECTURE.md](./ARCHITECTURE.md#extending-the-parser) for how to add new syntax support.
