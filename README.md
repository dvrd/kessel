# Kessel

A JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025 syntax with zero runtime dependencies.

## Performance

Kessel is **8–19% faster than OXC** (the fastest production JS parser) on real-world code, measured on Apple M1 Max:

| File | Size | Kessel | OXC | Kessel faster |
|---|---|---|---|---|
| typescript.js | 9.0 MB | 32.4 ms | 35.1 ms | 8% |
| d3.js | 587 KB | 3.5 ms | 4.3 ms | 19% |
| react-dom.dev.js | 1.1 MB | 2.7 ms | 3.4 ms | 19% |
| lodash.js | 544 KB | 1.0 ms | 1.2 ms | 17% |
| jquery.js | 285 KB | 1.2 ms | 1.4 ms | 16% |

Key architectural choices behind the speed:

- **SIMD lexer** — Cross-platform 128-bit SIMD (SSE2 on x86-64, NEON on ARM64) for string scanning, identifier body scanning, whitespace skipping, and comment skipping
- **Arena-only memory** — Single bump allocator, zero malloc during parse, zero GC
- **16-byte FastToken** — Token passed by value between lexer and parser, fits in a register pair
- **Perfect-hash keyword lookup** — 268-entry table, O(1) with 3-byte verification
- **Lazy two-token lookahead** — `nxt` is only lexed on demand, eliminating a 16-byte copy per token on 90% of advances
- **Apple Silicon QoS pinning** — P-core bias via `pthread_set_qos_class_self_np`

## Conformance

Tracked against OXC's conformance corpus (test262 + Babel + TypeScript + ESTree + misc) via the coverage harness in `tests/coverage/`. The harness mirrors OXC's `tasks/coverage/` verbatim: same skip lists, same classifier logic, same per-fixture snap classification.

| Suite | Positive (parses valid input) | Negative (rejects invalid input) |
|---|---|---|
| test262 | **100.00%** (47 114 / 47 114) | 94.62% (4 341 / 4 588) |
| Babel | **100.00%** (2 232 / 2 232) | 97.53% (1 660 / 1 702) |
| TypeScript | **100.00%** (10 773 / 10 773) | 98.96% (1 612 / 1 629) |
| ESTree | **100.00%** (39 / 39) | — |

Kessel never fails on valid input. 100% positive across every suite.

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
task build:debug              # Debug binary with bounds checks
```

### Node.js (npm)

Kessel ships as a multi-target npm package with the parser exposed as a
synchronous FFI call — no process spawn, no JSON serialization. Native
binaries are delivered as platform-specific optional dependencies, so a
fresh install pulls one ~3 MB binary, not five.

```bash
npm install @dvrdlibs/kessel
```

```js
const { parseSync } = require('@dvrdlibs/kessel');
const { program, errors } = parseSync('app.tsx', '<Counter initial={0} />');
```

Supported targets: `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`,
`win32-x64`. See [`npm/kessel/README.md`](npm/kessel/README.md) for the
full API and benchmarks.

## Usage

```bash
# Parse a file — AST as JSON to stdout
bin/kessel parse app.js
bin/kessel parse app.ts --lang=ts
bin/kessel parse component.tsx --lang=tsx

# Compact JSON
bin/kessel parse app.js --compact

# Multi-file parallel parse
bin/kessel parse src/*.js --workers 8 --out-dir tmp/ast

# Tokenize
bin/kessel lex app.js

# Benchmark
bin/kessel microbench parse app.js --iterations 500
bin/kessel microbench parse app.js --iterations 500 --ast-only

# Long-lived server mode (reads paths from stdin, writes framed JSON)
bin/kessel server --compact
```

### CLI Flags

| Flag | Description |
|---|---|
| `--compact` | Minified JSON output |
| `--lang=js\|jsx\|ts\|tsx` | Override language detection |
| `--source-type=script\|module` | Force source type (default: auto-detect) |
| `--loc` | Emit ESTree `loc` (line/column) on every node |
| `--range` | Emit ESLint-style `range: [start, end]` |
| `--preserve-parens` | Wrap `(expr)` in ParenthesizedExpression nodes |
| `--show-semantic-errors` | Run the semantic checker (pass 3) |
| `--ast-only` | Skip semantic checks (for benchmarking) |
| `--ast-type=js\|ts\|auto` | Force ESTree shape (JS or TS fields) |
| `--module-record` | Emit static import/export module record |

## Tests

```bash
task test                     # Primary gate — coverage + unit (~12s)
task test:quick               # Fast dev loop — unit + regression (~8s)
task test:release             # Zero-tolerance pre-release chain (~3 min)
```

| Command | What it tests |
|---|---|
| `task test:coverage` | 62K fixtures across test262/Babel/TS/ESTree/misc (24 Odin test procs) |
| `task test:unit` | 291 positive-fixture golden-output tests |
| `task test:regression` | 11 structural regression checks |
| `task test:real` | 466 real-world JS files — no crashes, no unexpected errors |
| `task test:estree` | String-escape decoding parity vs reference parser |
| `task test:fuzz` | 100 random valid programs, diff vs reference |
| `task test:fuzz:invalid` | 300 mutated/invalid inputs — no crashes or hangs |
| `task test:bench:regression` | 10 curated files vs baselines, fails on >5% regression |
| `task test:conformance:report` | Print conformance summary from snap files |

## Architecture

Three-pass pipeline:

1. **Lexer** (`src/lexer.odin`) — SIMD-accelerated tokenizer. Two-token lookahead. Cross-platform SIMD (SSE2 / NEON via `core:simd`). 16-byte `FastToken` by value. Cache-line-tuned hot fields.

2. **Parser** (`src/parser.odin`) — Hand-written Pratt recursive descent. Arena-only allocation. Builds the AST and enforces the subset of early errors that OXC enforces at parser level.

3. **Semantic Checker** (`src/checker.odin`) — Walks the finished AST. Enforces ECMA-262 early errors (break/continue context, label scoping, duplicate bindings, strict-mode restrictions, etc.). Opt-in via `--show-semantic-errors`.

### Source Layout

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 22.4K | Pratt parser, `Parser` struct, ~190 parsing procedures |
| `src/checker.odin` | 7.2K | AST-walker semantic checker (pass 3) |
| `src/emitter.odin` | 6.4K | ESTree JSON emitter with owned state |
| `src/lexer.odin` | 3.2K | SIMD lexer, two-token lookahead |
| `src/regex.odin` | 2.4K | ES2025 §22.2.1 regex pattern validator |
| `src/ast.odin` | 1.6K | All AST struct/union definitions |
| `src/raw_transfer.odin` | 1.3K | Zero-copy binary AST buffer |
| `src/main.odin` | 1.3K | CLI dispatch + worker pool + server mode |
| `src/simd.odin` | 614 | Cross-platform SIMD intrinsics (SSE2 / NEON) |
| `src/parse_job.odin` | 442 | Source → parsed Program deep module |
| `src/token.odin` | 383 | `TokenType` enum, `FastToken`, `LiteralValue` |
| `src/unicode_tables.odin` | 329 | ID_Start / ID_Continue range tables (Unicode 17.0) |
| `src/cli_config.odin` | 188 | `CliConfig` struct + flag parser |
| `src/source_io*.odin` | 189 | Cross-platform source reader (mmap on POSIX) |
| `src/qos_darwin.odin` | 61 | Apple Silicon QoS P-core pinning |

Total: ~48K LoC of Odin in `src/`, plus ~5.4K LoC in `tests/coverage/src/`.

## License

MIT
