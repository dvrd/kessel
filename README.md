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
task test                     # Primary gate — coverage harness + unit fixtures (~12s)
task test:coverage            # OXC-style conformance harness, 24 @(test) procs (~3s)
task test:unit                # 291 positive-fixture golden-output gate
task test:real                # 467 real-world JS files
task test:estree              # ESTree string-escape parity vs OXC
task test:release             # Zero-tolerance pre-release chain
task test:bench:regression    # Performance regression gate
task test:conformance:report  # Print conformance summary (informational)
```

The coverage harness classifies **62 261 fixtures** across 5 suites (test262, typescript, babel, estree, misc) × 2 tools (parser, semantic). Snap files at `tests/coverage/snapshots/` are the conformance proof. Run `task test:oxc-corpus:fetch` once to fetch the corpora before the first `task test`.

## Project Structure

```
kessel/
├── src/                       ~40 100 LoC of Odin
│   ├── main.odin              CLI dispatch + worker pool
│   ├── parser.odin            Pratt parser (permissive, ~18.7K lines)
│   ├── emitter.odin           ESTree JSON emitter
│   ├── checker.odin           AST-walker semantic checker (pass 3)
│   ├── lexer.odin             SIMD lexer
│   ├── regex.odin             ES2025 §22.2.1 regex pattern validator
│   ├── ast.odin               ESTree AST struct/union definitions
│   ├── parse_job.odin         Source → parsed Program deep module
│   ├── raw_transfer.odin      Zero-copy binary AST buffer
│   ├── simd.odin              ARM64 NEON intrinsics
│   ├── cli_config.odin        CliConfig + flag parser
│   ├── token.odin             TokenType enum, FastToken, LiteralValue
│   ├── unicode_tables.odin    ID_Start / ID_Continue ranges
│   ├── source_io*.odin        Cross-platform source reader (mmap on POSIX)
│   └── qos_darwin.odin        Apple Silicon P-core pinning
├── tests/
│   ├── coverage/              OXC-style conformance harness (Odin)
│   │   ├── src/                 Harness sources (~3 700 LoC)
│   │   ├── snapshots/           Committed .snap golden files
│   │   └── misc/                Regression museum + must-reject fixtures
│   ├── fixtures/              Hand-authored positive (must-parse) fixtures
│   ├── expected/              Golden JSON outputs for the unit gate
│   ├── baselines/             Bench / fuzz baselines
│   ├── runners/               Shell scripts (fetch corpora, run unit gate)
│   ├── verifiers/             Node.js verifiers (deep JSON, fuzz, regression)
│   └── vendor/                Vendored OXC corpora (gitignored)
├── bench/
│   ├── real_world/            467 production JS files
│   └── oxc_compare/           OXC reference binary (Rust)
└── Taskfile.yml               All build/test/bench tasks
```
## License

MIT
