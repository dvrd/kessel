# Kessel

JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/). Emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025 syntax with zero runtime dependencies, statically-allocated arena memory, and ARM64 NEON SIMD-accelerated lexing.

Building toward a full web toolchain — the parser is the first piece of the pipeline.

## Architecture

Three-pass pipeline, each pass independent and composable:

```
Source (.js / .ts / .jsx / .tsx)
    │
    ▼
 1. Lexer ───── SIMD string/identifier scanning (ARM64 NEON)
    │            Two-token lookahead (cur + nxt)
    │            16-byte FastToken, cache-line-tuned hot fields
    │
    ▼
 2. Parser ──── Pratt precedence climbing, hand-written recursive descent
    │            Arena-only allocation (256× source, lazy-committed)
    │            Bump pool for AST nodes (zero allocator dispatch)
    │            Permissive — builds the tree, does not enforce early errors
    │
    ▼
 3. Checker ─── Semantic validation (ECMA-262 early errors)
                 Walks the finished AST, reports spec violations
                 Opt-in — off by default (matches OXC's parseSync behavior)
```

The parser does not track loop/switch context, label scopes, super/new.target validity, or strict-mode binding restrictions. It builds the AST and moves on. Early errors are the checker's job — same split as OXC (`oxc_parser` vs `oxc_semantic`).

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

## Performance

Benchmarked against OXC (Rust) on 10 headline files, 30 iterations each, Apple Silicon ARM64:

```
File                        Kessel (µs)  OXC (µs)  Ratio
snabbdom.js        (1 KB)        3.4        3.1    1.10x
preact.js         (11 KB)      138.7      131.2    1.06x
lodash.js        (531 KB)    1,746.2    1,685.0    1.04x
jquery.js        (279 KB)    1,824.4    1,798.0    1.01x
d3.js            (573 KB)    6,091.2    6,020.0    1.01x
react.dev.js     (206 KB)      554.7      540.0    1.03x
react-dom.dev.js   (1 MB)    5,327.2    5,100.0    1.04x
antd.js            (4 MB)   25,638.5   24,800.0    1.03x
monaco.js          (3 MB)   38,317.4   37,500.0    1.02x
typescript.js      (9 MB)   54,126.5   53,000.0    1.02x
```

Geo-mean ratio: ~1.03x (within 3% of OXC). Kessel's `pin_to_p_core()` biases to Apple Silicon performance cores for consistent bench numbers.

## Conformance

Tracked against three corpora:

| Corpus | Coverage |
|---|---|
| Unit fixtures | 415 / 415 (100%) |
| Real-world JS | 467 / 467 (100%) |
| OXC corpus (25,140 fixtures) | 15,191 agree with OXC; 554 kessel-only-rejects (mostly genuine gaps, not spec violations) |
| Test262 curated subset | 63 / 66 (95.5%) |

The 554 remaining kessel-only-rejects are genuine parser gaps — mostly `<<` token splitting for generic type arguments, ternary disambiguation edge cases, and a handful of `using`/`await` disambiguation corners.

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
│   ├── main.odin            CLI + JSON emitter (7,813 lines)
│   ├── parser.odin          Pratt parser, 190+ parsing procs (17,022 lines)
│   ├── lexer.odin           SIMD-accelerated tokenizer (3,420 lines)
│   ├── ast.odin             ESTree AST struct/union definitions (1,611 lines)
│   ├── checker.odin         Semantic checker — pass 3 (skeleton)
│   ├── regex.odin           ES2025 §22.2.1 regex pattern validator (1,768 lines)
│   ├── raw_transfer.odin    Zero-copy binary AST buffer (1,261 lines)
│   ├── simd.odin            ARM64 NEON intrinsics (521 lines)
│   ├── token.odin           TokenType enum, FastToken, LiteralValue (383 lines)
│   ├── unicode_tables.odin  ID_Start / ID_Continue ranges (329 lines)
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
├── vendor/                   (gitignored) Test262, TypeScript, Babel corpora
├── HANDOFF.md                Full technical context for development
└── Taskfile.yml              All build/test/bench tasks
```

## Key Design Decisions

1. **Odin, not Rust or Zig.** Structs map naturally to ESTree shapes. No async/Send/Sync ceremony. Single-source simplicity.

2. **Arena-only memory.** Single virtual-memory arena, destroyed in one syscall. No malloc/free during parsing. Deterministic teardown.

3. **Pratt parser, not generated.** Hand-written recursive descent with precedence climbing. Surgical control over error recovery, ASI, regex-vs-division, JSX-in-expression.

4. **OXC as conformance oracle.** Every gate compares kessel to OXC's `parseSync` for both accept/reject agreement and AST shape.

5. **Permissive parser + separate checker.** The parser builds the tree without enforcing early errors (like OXC). The semantic checker is a separate pass that walks the AST and validates. This keeps the parser fast and simple.

## License

MIT
