# Kessel

* JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/)
* Emits ESTree-compatible JSON ASTs
* Targets ES2015–ES2025 syntax

## Language Support

| Feature | Status |
|---|---|
| ES2015–ES2025 | ✅ Full syntax support |
| TypeScript | ✅ Types, interfaces, enums, namespaces, decorators, generics |
| JSX | ✅ Elements, fragments, spread attributes, expression containers |
| TSX | ✅ Type arguments on JSX elements, generic components |
| Decorators (stage 3) | ✅ Member chains, call expressions, type arguments |
| Import attributes (`with`) | ✅ |
| `using` / `await using` | ✅ |


## Getting Started

Requires [Odin](https://odin-lang.org/docs/install/) (dev-2026-04 or later) and [Task](https://taskfile.dev/).

```bash
task build                    # Release binary → bin/kessel
task build:debug              # Debug binary + dSYM → bin/kessel-debug
```

## Usage

```bash
# Parse a file — AST as JSON to stdout
bin/kessel parse app.js
bin/kessel parse app.ts --lang=ts
bin/kessel parse component.tsx --lang=tsx

# Compact JSON
bin/kessel parse app.js --compact

# Tokenize
bin/kessel lex app.js

# Benchmark (30 iterations default)
bin/kessel microbench parse app.js
bin/kessel microbench parse app.js --iterations 500

# Parser profile
bin/kessel profile parse app.js
```

## Tests

```bash
task test                     # Full gate chain (~20 tests)
task test:unit                # 415 golden-output fixtures
task test:real                # 467 real-world JS files
task test:negative            # Must-reject fixtures
task test:estree              # ESTree shape conformance
task test:test262             # 66 curated Test262 tests
task test:oxc-corpus          # 25,140 fixture smoke gate
task test:bench:regression    # Performance regression gate
```

## Project Structure

```
kessel/
├── src/
│   ├── main.odin            CLI + JSON emitter
│   ├── parser.odin          Pratt parser
│   ├── lexer.odin
│   ├── ast.odin             ESTree AST struct/union definitions
│   ├── checker.odin         Semantic checker — pass 3 (skeleton)
│   ├── regex.odin           ES2025 §22.2.1 regex pattern validator
│   ├── raw_transfer.odin    Zero-copy binary AST buffer
│   ├── simd.odin            ARM64 NEON intrinsics
│   ├── token.odin           TokenType enum, FastToken, LiteralValue
│   ├── unicode_tables.odin  ID_Start / ID_Continue ranges
│   ├── source_io.odin       Cross-platform source reader (mmap on POSIX)
│   └── qos_darwin.odin      Apple Silicon P-core pinning
├── tests/
│   ├── fixtures/             Hand-authored test fixtures by category
│   ├── expected/             Golden JSON outputs
│   ├── baselines/            Gate baselines (corpus, negative, bench)
│   ├── runners/              Shell scripts (fetch corpora, run tests)
│   ├── verifiers/            Node.js verifiers (one per gate)
│   └── test262/              Curated Test262 subset
├── bench/
│   ├── real_world/           467 production JS files
│   └── oxc_compare/          OXC microbench comparator (Rust)
└── Taskfile.yml              All build/test/bench tasks
```
## License

MIT
