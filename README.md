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

Test fixtures are organized by feature in `kessel/tests/fixtures/`:
- `literals/` — Number, string, boolean, null, regex literals
- `expressions/` — Arithmetic, logical, function calls, etc.
- `statements/` — Variable declarations, if/while/for, etc.
- `functions/` — Function declarations and expressions
- `classes/` — Class declarations and methods
- `modules/` — Import/export statements

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

## Performance

Typical throughput on modern hardware:

| Input Size | Time | Memory |
|------------|------|--------|
| 10 KB | < 1 ms | ~15 KB |
| 100 KB | ~2 ms | ~150 KB |
| 1 MB | ~15 ms | ~1.5 MB |
| 10 MB | ~150 ms | ~15 MB |

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
