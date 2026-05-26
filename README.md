# Kessel

A JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025 syntax with zero runtime dependencies.

Kessel ships in two consumption modes — a standalone CLI and an npm package. Pick whichever fits your call site:

- **CLI** (`bin/kessel`) for shell pipelines, batch parsing, editor integrations.
- **npm package** (`@dvrdlibs/kessel`) for in-process Node.js use via a synchronous FFI binding — no subprocess, no JSON serialization.

## Conformance

Tracked via a port of OXC's coverage harness (`tests/coverage/`) against the standard JS/TS conformance corpora.

| Suite | Positive (parses valid input) | Negative (rejects invalid input) |
|---|---|---|
| test262 | **100.00%** (47 114 / 47 114) | **100.00%** (4 588 / 4 588) |
| Babel | **100.00%** (2 232 / 2 232) | **100.00%** (1 702 / 1 702) |
| TypeScript | **100.00%** (10 773 / 10 773) | **100.00%** (1 629 / 1 629) |
| ESTree | **100.00%** (39 / 39) | — |
| Misc | **100.00%** (84 / 84) | **100.00%** (273 / 273) |

100% positive AND negative on every suite — kessel never fails on valid input
and matches the reference parser on every invalid input in the corpora.

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

The install pulls only the platform-specific native binary that matches your host (one of `darwin-arm64`, `darwin-x64`, `linux-arm64`, `linux-x64`, `win32-x64`). The other sub-packages stay on the registry, unfetched. TypeScript declarations ship in the package.

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

# Codegen — emit JS source back from the AST (round-trip / minify)
bin/kessel codegen app.js
bin/kessel codegen app.js --minified

# Benchmark
bin/kessel microbench parse app.js --iterations 500
bin/kessel microbench parse app.js --iterations 500 --ast-only

# Long-lived server mode (reads paths from stdin, writes framed JSON)
bin/kessel server --compact
```

Errors are pretty-printed (rustc-style) by default with stable K-codes
(`K1xxx` lexer, `K2xxx`/`K3xxx` parser, `K4xxx` TypeScript-specific). Pass
`--json` for machine-readable output, or set `KESSEL_COLOR=0` /
`--color=false` to disable ANSI color.

### Node.js

```js
const { parseSync, parseAsync } = require('@dvrdlibs/kessel');

const { program, errors } = parseSync(
  'Counter.tsx',
  'export const Counter = ({ initial = 0 }: { initial?: number }) => <button>{initial}</button>;'
);

// Non-blocking: runs on the libuv worker pool, off the main event loop.
const { program: p2, errors: e2 } = await parseAsync('app.ts', src);
```

Each error carries a stable `code` (e.g. `K3010`) and `severity` field for
programmatic handling. Full API and visitor helpers documented in
[`npm/kessel/README.md`](npm/kessel/README.md).

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
| `--json` | Emit errors as JSON instead of the pretty renderer |
| `--color=<bool>` | Force color on/off (overrides `KESSEL_COLOR` env) |

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
| `task test:real` | 467 real-world JS files — no crashes, no unexpected errors |
| `task test:estree` | String-escape decoding parity vs reference parser |
| `task test:fuzz` | 100 random valid programs, diff vs reference |
| `task test:fuzz:invalid` | 300 mutated/invalid inputs — no crashes or hangs |
| `task test:bench:regression` | 10 curated files vs baselines, fails on >5% regression |
| `task test:conformance:report` | Print conformance summary from snap files |

### OXC Oracle

Diff, fuzz, and benchmark comparisons use a pinned OXC oracle. The Rust
comparison binaries read the local checkout at `../oxc`, which must be at the
full SHA recorded in `OXC_ORACLE.json`; `task bench:oxc:verify` checks this
before rebuilding. The same manifest records the exact npm `oxc-parser`
version expected by JS-side deep-diff and fuzz checks.

The `commit:` header inside coverage snapshots is the vendored corpus
reference for that suite, not the local OXC checkout pin.

## Architecture

Three-pass pipeline:

1. **Lexer** (`src/lexer.odin`) — SIMD-accelerated tokenizer. Two-token lookahead. Cross-platform SIMD via Odin's `core:simd` (NEON on ARM64, SSE2 on x86-64, scalar fallback elsewhere). 16-byte `FastToken` by value. Cache-line-tuned hot fields.

2. **Parser** (`src/parser.odin`) — Hand-written Pratt recursive descent. Arena-only allocation. Builds the AST and enforces the subset of ECMA-262 / TypeScript early errors that belong at parser level (overload chains, ambient restrictions, accessor shapes, etc.). Does not implement TypeScript type-system checks — those are downstream.

3. **Semantic Checker** (`src/checker.odin`) — Walks the finished AST. Enforces ECMA-262 early errors (break/continue context, label scoping, duplicate bindings, strict-mode restrictions, etc.). Opt-in via `--show-semantic-errors`.

### Implementation notes

- **SIMD lexer** — cross-platform 128-bit SIMD (SSE2 on x86-64, NEON on ARM64, scalar fallback elsewhere) via Odin's portable `core:simd`, for string scanning, identifier scanning, whitespace, and comment skipping.
- **Arena-only memory** — single bump allocator, no malloc during parse, no GC.
- **16-byte FastToken** — passed by value between lexer and parser, fits in a register pair.
- **Perfect-hash keyword lookup** — 268-entry table, O(1) with 3-byte verification.
- **Lazy two-token lookahead** — `nxt` is only lexed on demand, eliminating a 16-byte copy on roughly 90% of advances.
- **Apple Silicon QoS pinning** — P-core bias via `pthread_set_qos_class_self_np`.

### Source Layout

| File | Purpose |
|---|---|
| `src/parser.odin` | Pratt parser, `Parser` struct, parsing procedures |
| `src/checker.odin` | AST-walker semantic checker (pass 3) |
| `src/emitter.odin` | ESTree JSON emitter with owned state |
| `src/binary_emitter.odin` | Compact binary AST emitter (consumed by the npm package) |
| `src/codegen*.odin` | AST → JS source emitter (incl. `--minified`) |
| `src/diagnostic.odin` | K-code diagnostics model (codes + severity) |
| `src/diagnostic_render.odin` | Pretty (rustc-style) error renderer |
| `src/lexer.odin` | SIMD lexer, two-token lookahead |
| `src/regex.odin` | ES2025 §22.2.1 regex pattern validator |
| `src/ast.odin` | All AST struct/union definitions |
| `src/raw_transfer.odin` | Zero-copy binary AST buffer wire format |
| `src/main.odin` | CLI dispatch + worker pool + server mode |
| `src/lib_exports.odin` | Shared-library exports for the npm FFI |
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

## Attribution

Kessel uses [OXC](https://github.com/oxc-project/oxc) extensively as a
reference implementation and comparison oracle. The conformance harness in
`tests/coverage/` is a port of OXC's coverage tooling, and the regression,
deep-diff, fuzz, and benchmark checks compare Kessel against pinned OXC parser
artifacts.

Kessel is an independent Odin implementation and does not depend on OXC at
runtime. OXC is MIT-licensed; see the OXC project for its source and license.

## License

MIT
