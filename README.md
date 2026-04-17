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

### Memory Efficiency After Virtual Arena Migration

Migrated from `mem.Arena` + pre-allocated backing to `mem.virtual.Arena` with lazy commitment (64 KB initial block):

| Input Size | Time  | Arena Used | Arena Reserved | Utilization |
|------------|-------|------------|-----------------|-------------|
| **Small** (44 B) | ~3ms | 66 KB | 131 KB (virtual) | 50% |
| **Medium** (500 B) | ~3ms | 91 KB | 131 KB (virtual) | 69% |
| **Large** (324 KB) | ~23ms | ~2.5 MB | ~5 MB (virtual) | ~50% |

#### Improvements from Previous Release

**Before**: Static 4 MB allocation floor per file  
**After**: 64 KB virtual block, commits lazily on first touch

- **Small files**: ~98% memory reduction (4 MB → 131 KB reserved, 66 KB actual use)
- **Startup overhead**: Eliminated ~4 MB upfront cost for batch operations
- **Large files**: Same 50% utilization ratio, sub-millisecond arena initialization

Virtual arena enables efficient multi-file parsing: 100× 1KB files now use ~13 MB instead of 400 MB.

Benchmark your system:

```bash
# Run benchmark (timeout 10s per test)
timeout 10 ./kessel_bin parse kessel/bench_large.js
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
