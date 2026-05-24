# Kessel

A JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025 syntax with zero runtime dependencies.

Kessel ships in two consumption modes — a standalone CLI and an npm package. Pick whichever fits your call site:

- **CLI** (`bin/kessel`) for shell pipelines, batch parsing, editor integrations.
- **npm package** (`@dvrdlibs/kessel`) for in-process Node.js use via a synchronous FFI binding — no subprocess, no JSON serialization.

## Performance

Measured on Apple M1 Max, parsing real-world files:

| File | Size | Kessel |
|---|---|---|
| typescript.js | 9.0 MB | 32.4 ms |
| d3.js | 587 KB | 3.5 ms |
| react-dom.dev.js | 1.1 MB | 2.7 ms |
| lodash.js | 544 KB | 1.0 ms |
| jquery.js | 285 KB | 1.2 ms |

Architecture notes:

- **SIMD lexer** — cross-platform 128-bit SIMD (SSE2 on x86-64, NEON on ARM64, scalar fallback elsewhere) via Odin's portable `core:simd`, for string scanning, identifier scanning, whitespace, and comment skipping.
- **Arena-only memory** — single bump allocator, no malloc during parse, no GC.
- **16-byte FastToken** — passed by value between lexer and parser, fits in a register pair.
- **Perfect-hash keyword lookup** — 268-entry table, O(1) with 3-byte verification.
- **Lazy two-token lookahead** — `nxt` is only lexed on demand, eliminating a 16-byte copy on roughly 90% of advances.
- **Apple Silicon QoS pinning** — P-core bias via `pthread_set_qos_class_self_np`.

## Conformance

Tracked via a port of OXC's coverage harness (`tests/coverage/`) against the standard JS/TS conformance corpora.

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

## Installation

### CLI

Requires [Odin](https://odin-lang.org/docs/install/) (dev-2026-04 or later) and [Task](https://taskfile.dev/).

```bash
task build                    # Release binary → bin/kessel
task build:debug              # Debug binary with bounds checks
task install                  # Symlink bin/kessel into ~/.local/bin
```

### Node.js (npm)

```bash
npm install @dvrdlibs/kessel
```

The install pulls only the platform-specific native binary that matches your host (one of `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, `win32-x64`). The other sub-packages stay on the registry, unfetched.

## Usage

### CLI

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

### Node.js

```js
const { parseSync } = require('@dvrdlibs/kessel');

const { program, errors } = parseSync(
  'Counter.tsx',
  'export const Counter = ({ initial = 0 }: { initial?: number }) => <button>{initial}</button>;'
);
```

Full API and visitor helpers documented in [`npm/kessel/README.md`](npm/kessel/README.md).

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

1. **Lexer** (`src/lexer.odin`) — SIMD-accelerated tokenizer. Two-token lookahead. Cross-platform SIMD via Odin's `core:simd` (NEON on ARM64, SSE2 on x86-64, scalar fallback elsewhere). 16-byte `FastToken` by value. Cache-line-tuned hot fields.

2. **Parser** (`src/parser.odin`) — Hand-written Pratt recursive descent. Arena-only allocation. Builds the AST and enforces the subset of ECMA-262 / TypeScript early errors that belong at parser level (overload chains, ambient restrictions, accessor shapes, etc.). Does not implement TypeScript type-system checks — those are downstream.

3. **Semantic Checker** (`src/checker.odin`) — Walks the finished AST. Enforces ECMA-262 early errors (break/continue context, label scoping, duplicate bindings, strict-mode restrictions, etc.). Opt-in via `--show-semantic-errors`.

### Source Layout

| File | Purpose |
|---|---|
| `src/parser.odin` | Pratt parser, `Parser` struct, parsing procedures |
| `src/checker.odin` | AST-walker semantic checker (pass 3) |
| `src/emitter.odin` | ESTree JSON emitter with owned state |
| `src/binary_emitter.odin` | Compact binary AST emitter (consumed by the npm package) |
| `src/lexer.odin` | SIMD lexer, two-token lookahead |
| `src/regex.odin` | ES2025 §22.2.1 regex pattern validator |
| `src/ast.odin` | All AST struct/union definitions |
| `src/raw_transfer.odin` | Zero-copy binary AST buffer wire format |
| `src/main.odin` | CLI dispatch + worker pool + server mode |
| `src/napi.odin` | N-API addon (Darwin-only experimental) |
| `src/simd.odin` | Cross-platform SIMD intrinsics |
| `src/parse_job.odin` | Source → parsed Program deep module |
| `src/token.odin` | `TokenType` enum, `FastToken`, `LiteralValue` |
| `src/unicode_tables.odin` | ID_Start / ID_Continue range tables (Unicode 17.0) |
| `src/cli_config.odin` | `CliConfig` struct + flag parser |
| `src/source_io*.odin` | Cross-platform source reader (mmap on POSIX, stub on Windows) |
| `src/qos_darwin.odin` | Apple Silicon QoS P-core pinning |

## Releases

The npm package is published automatically on every push to `main` whose conventional-commit subject implies a real change:

- `feat:` / `refactor:` → minor bump
- `feat!:` / `refactor!:` / `BREAKING CHANGE` → major bump
- `fix:` / `perf:` / `chore:` / etc. → patch bump
- Docs-only and CI-only commits don't trigger a release

The pipeline (`.github/workflows/release.yml`) builds all five platform binaries, publishes the five `@dvrdlibs/kessel-<target>` sub-packages with Sigstore provenance, then publishes the main `@dvrdlibs/kessel` package with `optionalDependencies` pinned to the same version. If any sub-package fails to publish, the main package stays at its previous version and users are unaffected.

Manual override: `gh workflow run Release --repo dvrd/kessel`.

## License

MIT
