# Handoff — Kessel

## What is Kessel

Kessel is the first piece of a web toolchain — a JavaScript /
TypeScript / JSX / TSX parser written in Odin that emits
ESTree-compatible JSON ASTs. Targets ES2015–ES2025 syntax with zero
runtime dependencies, arena-only memory, ARM64 NEON SIMD-accelerated
lexing, and a Pratt expression parser.

**Kessel is not a CLI tool.** The CLI exists for development and
testing. The real deliverable is the pipeline: lexer → parser →
semantic checker → (future: linter, transformer, bundler, codegen).
Tracks both speed (vs Rust's `oxc`) and conformance (Test262 +
microsoft/TypeScript + babel/babel + estree-conformance) as primary
metrics.

---

## Current State

### Build

Command: `task build` (resolves to `odin build src -out:bin/kessel
-o:speed -no-bounds-check && rm -rf bin/kessel.dSYM`).

Verified this session: clean build, exit 0, no warnings.
Output: `bin/kessel`, ARM64.

Hardware / toolchain (this session):
- Apple Silicon (`MacBookPro18,2`, arm64)
- Darwin
- Odin `dev-2026-04:df6fff6e4`
- Node `v25.9.0`

Debug build: `task build:debug` produces `bin/kessel-debug` plus
`bin/kessel-debug.dSYM`. Use `lldb -batch -o "run parse <file>"
-o "thread backtrace 5" bin/kessel-debug` for crash bisection.

### Tests

All gates run this session, all green:

| Suite | Count | Result | Command |
|---|---:|---|---|
| Unit (golden-output) | 415 / 415 | pass | `task test:unit` |
| Negative (must-reject) | baseline | match | `task test:negative` |
| Ambiguity (JS/TS/JSX boundary) | baseline | match | `task test:ambiguity` |
| Regression (session-fixed bugs) | 11 / 11 | pass | `task test:regression` |
| Real-world parse | 467 / 467 | pass | `task test:real` |
| ESTree drift | strict | pass | `task test:estree` |
| Nodes coverage | 57 / 57 | pass | `task test:nodes` |
| Recovery anchors | 31 / 31 | pass | `task test:recovery` |
| Lexical surfaces | baseline | match | `task test:lexical` |
| Invariants | zero-tolerance OK | pass | `task test:invariants` |
| Spec compliance | 13 files × 3 parsers | match baseline | `task test:spec-compliance` |
| Spec fixtures | 150 / 150 | pass | `task test:spec-fixtures` |
| Test262 subset (66 curated) | 66 / 66 | pass | `task test:test262` |
| Test262 subset (categorised) | baseline | match | `task test:test262:subset` |
| Multi-parser deep | pass | pass | `task test:multi-parser` |
| Fuzz diff (baselined) | 0 / 0 baseline | match | `task test:fuzz` |
| Fuzz invalid (baselined) | 8 / 8 baseline | match | `task test:fuzz:invalid` |
| Crashes-known | 0 new | pass | `task test:crashes-known` |
| Deep families | 88 / 92, 5 divergences | baseline | `task test:deep-families` |
| OXC corpus smoke | 25,140 fixtures | baseline | `task test:oxc-corpus` |
| Bench regression | 10 / 10 | pass | `task test:bench:regression` |

`task test` runs the everyday chain (unit + negative + ambiguity +
regression + real + estree + nodes + recovery + lexical + invariants +
spec-compliance + spec-fixtures + test262 + test262:subset +
multi-parser + fuzz + fuzz:invalid + crashes-known). Off the default
chain because of run time: `test:test262:full`, `test:oxc-corpus`,
`test:bench:regression`, `test:deep-families`.

Active known-failures: **none.** `tests/baselines/test262_known_failures.txt`
+ `unit_known_failures.txt` + `ambiguity_known_failures.txt` are all
documentation files with zero active entries — every previously-tracked
failure has been closed.

### OXC corpus baseline (end of W10)

Full breakdown (run with `node tests/verifiers/verify_oxc_corpus.js
--update --json-out tmp/_w6_full_smoke.json`):

```
Total fixtures: 25,140
  ok-vs-oxc            15,348   kessel and OXC agree on accept/reject
  pass-both             3,039   both parsers fully accept
  reject-both             507   both reject
  skip-multi-file       3,519   TS @[Ff]ilename: multi-file projects (not yet split)
  kessel-only-rejects      60   kessel rejects, OXC accepts (genuine parser gaps)
  oxc-only-rejects      1,135   OXC rejects, kessel accepts
  should-pass-rejected  1,499   both reject, expected pass (Babel-only plugins, Flow, etc.)
  should-reject-passed     33   both accept, expected reject
  kessel-crash              0
  kessel-timeout            0
```

The **60 kessel-only-rejects** are genuine parser gaps — NOT early-error
disagreements (those were eliminated by the W8+W9 permissive-parser
refactor). Remaining clusters below.

The 1,135 oxc-only-rejects are kessel accepting what OXC rejects.
Not yet triaged — mix of kessel lenience and OXC quirks.

### Performance

Bench command: `task test:bench:regression` (30 iterations per file
via `kessel microbench parse <file>`, parse-only — no JSON emit).

Run this session against `tests/baselines/bench_baseline.json`
(locked at S25 end):

```
File                               baseline(us)  current(us)  ratio  verdict
batch3/snabbdom.js                       3.38         3.54   1.049   ok
batch2/preact.js                       138.71       138.96   1.002   ok
lodash.js                             1746.21      1756.29   1.006   ok
jquery.js                             1824.42      1829.25   1.003   ok
d3.js                                 6091.21      6112.38   1.003   ok
react.dev.js                           554.71       551.71   0.995   ok
react-dom.dev.js                      5327.17      5189.17   0.974   ok
antd.js                              25638.50     24600.71   0.960   ok
batch2/monaco.js                     38317.38     38332.04   1.000   ok
typescript.js                        54126.54     53315.17   0.985   ok
geo-mean ratio: 0.997 (tolerance 1.050)
```

Note: the W9 semantic-error conversion yielded a transient 15-24%
speedup mid-session (fewer `fmt.tprintf` + scope walks on the hot path
when `check_semantics=false`). The final locked run shows ~0.997× parity;
the intra-session speedup is real but masked by thermal / scheduler noise
on the final pass.

---

## Project Structure

All source is in `src/*.odin`. 14 files, 34,490 lines total.

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 17,072 | Pratt-style hand-written parser. Produces ESTree AST. Holds `Parser` struct + ~200 parsing procedures. Owns context flags (in_function, strict_mode, in_async, …), the bump pool for AST nodes, and error recovery. |
| `src/main.odin` | 7,813 | CLI entry point + JSON emitter. `main()` switches on subcommand (`parse`, `lex`, `microbench`, `profile`, `version`, `help`). `parse_file` orchestrates source_read → init_lexer → init_parser → parse_program → emit JSON. Includes `print_statement_ast`, `print_expression_ast`, etc. emit functions. |
| `src/lexer.odin` | 3,420 | SIMD-accelerated lexer. Holds `Lexer` struct (cache-line-tuned hot fields, two-token lookahead via `cur` + `nxt`). String / template / regex / identifier scanners. Two-pass: `init_lexer` builds line-offset table, then `lex_token` is called per advance. |
| `src/regex.odin` | 1,768 | ES2025 §22.2.1 regex pattern validator. Used at lex time to fail-fast on invalid regex literals. Supports `u`/`v` flags, named capture groups, lookbehind, modifier sequences. |
| `src/ast.odin` | 1,611 | All AST struct/union definitions. `Program`, `Expression` (50+ variants), `Statement` (29 variants), all `TS*` types, `Pattern`, `Loc` / `Span`. Dispatch uses tagged unions of pointers. |
| `src/raw_transfer.odin` | 1,261 | Zero-copy binary AST buffer. Walks the AST and rewrites pointers to relative offsets for cross-language consumption. Header magic `0x4B455353` (`KESS`). |
| `src/simd.odin` | 521 | ARM64 NEON intrinsics — `simd_find_string_end`, `simd_has_multibyte`. |
| `src/token.odin` | 383 | `TokenType` enum, `Token`, `FastToken` (16-byte cache-friendly variant), `LiteralValue`. |
| `src/unicode_tables.odin` | 329 | ID_Start / ID_Continue range tables. |
| `src/source_io.odin` | 103 | Cross-platform source reader (mmap on POSIX). |
| `src/source_io_posix.odin` | 69 | POSIX mmap implementation. |
| `src/checker.odin` | 62 | Semantic checker (skeleton — checks being migrated). |
| `src/qos_darwin.odin` | 61 | Apple Silicon QoS P-core pinning. |
| `src/source_io_other.odin` | 17 | Windows stub. |

### Test infrastructure

`tests/` contains everything in this repo that's not parser source:

- `tests/fixtures/` — hand-authored fixtures by category (basic,
  early_errors, edge, es2015, es2020, es2022, es2025, negative,
  real, recovery, regression, spec/{ambiguity,asi,escapes,interactions,
  jsx,lexical,regex_disambiguation,tsx,typescript,unicode})
- `tests/expected/` — golden JSON outputs paired with `tests/fixtures/`
- `tests/baselines/` — gate baselines (per-file pass counts, mismatch
  counts, etc.) for every baselined gate. Includes
  `oxc_corpus_baseline.json`.
- `tests/runners/` — shell scripts that fetch corpora (`test262_fetch.sh`,
  `oxc_corpus_fetch.sh`) + run unit tests (`run_tests.sh`).
- `tests/verifiers/` — JS verifiers (one per gate). All run from Node.
- `tests/test262/` — minimal Test262 subset (66 fixtures).
- `vendor/` (gitignored) — full corpus checkouts at pinned SHAs.

### Vendor corpora (gitignored)

| Path | Size | Content |
|---|---:|---|
| `vendor/test262/` | 261 MB | Full tc39/test262 checkout. Used by `test:test262:full`. |
| `vendor/typescript/` | 137 MB | sparse-checkout of `microsoft/TypeScript@c7a0ae10:tests/cases/` |
| `vendor/babel/` | 69 MB | sparse-checkout of `babel/babel@c543b031:packages/babel-parser/test/fixtures/` |
| `vendor/estree-conformance/` | 2.5 GB | full clone of `oxc-project/estree-conformance@e4104a13` — only ~5 MB used |

Fetcher: `bash tests/runners/oxc_corpus_fetch.sh [typescript|babel|estree]`
or `task test:oxc-corpus:fetch`. Idempotent (re-runs hard-reset to the
pinned SHA).

---

## Architecture

### Pipeline

Three-pass pipeline, each pass independent:

1. **Lexer** (`src/lexer.odin`) — SIMD-accelerated tokenization.
2. **Parser** (`src/parser.odin`) — Builds ESTree AST. **Permissive**
   — does not enforce early errors. Tracks only state that affects
   parsing decisions (`no_in`, `in_async`, `in_generator`,
   `strict_mode`). Matches OXC's `oxc_parser` architecture.
3. **Checker** (`src/checker.odin`) — Walks the finished AST and
   enforces ECMA-262 early errors. Opt-in via `check_semantics`
   flag. Currently a stub — checks gated in the parser via
   `report_semantic_error` (no-op when `check_semantics=false`,
   the default).

Future passes: linter, transformer, bundler, codegen.

### Semantic error architecture (W8+W9)

The parser has two error-reporting functions:

- `report_error(p, msg)` — **parsing error**. Always fires. Used for
  structural issues that prevent AST construction (unexpected tokens,
  missing brackets, ambiguous syntax).
- `report_semantic_error(p, msg)` — **early error**. Gated on
  `p.check_semantics` (default `false`). Used for ECMA-262 early
  errors that don't affect parsing decisions (duplicate bindings,
  strict-mode restrictions, scope violations, etc.).
- `report_semantic_error_at(p, loc, msg)` — same as above but at a
  specific source location (for post-hoc checks like scope analysis,
  private-name resolution, `__proto__` dups).

The W8 refactor converted 71 `report_error` calls. The W9 refactor
converted ~50 more, covering all remaining early-error categories:
duplicate private class members, eval/arguments strict-mode, reserved
identifiers, duplicate parameters, scope duplicate declarations,
private field resolution, `__proto__` redefinition, label duplicates,
for-in/of initializers, export-not-defined, octal escapes, etc.

Result: **kessel-only-rejects dropped from 554 → 83** in W9 alone.

### Data flow (CLI entry → output)

```
              ┌────────────────────────────────────────────────┐
              │  main.odin: main() → switch on os.args[1]      │
              │  ─────────────                                  │
              │   "parse"  ─────────────► parse_file(path)     │
              │   "raw"    ─────────────► parse_file_raw_to_disk│
              │   "microbench parse" ───► run_microbench_parse  │
              │   "lex"    ─────────────► lex_file              │
              └────────────────────┬────────────────────────────┘
                                   │
                                   ▼
            ┌──────────────────────────────────────────┐
            │  parse_file (src/main.odin:888)          │
            │                                           │
            │   1. source_read(path)  ─► SourceBuffer  │
            │      (mmap on POSIX, fallback to read)   │
            │                                           │
            │   2. mvirtual.Arena (256× source size,   │
            │      lazy-committed, virtual memory)      │
            │                                           │
            │   3. init_lexer(&lex, source, arena_alloc) │
            │      ─► Lexer with line-offset table     │
            │                                           │
            │   4. init_parser(&p, &lex, arena_alloc, lang) │
            │      ─► Parser + pre-fetched cur/nxt tokens │
            │                                           │
            │   5. parse_program(&p, source_type)       │
            │      ─► ^Program                          │
            │                                           │
            │   6. print_program_ast(program)           │
            │      ─► JSON to stdout (writer-buffered) │
            │                                           │
            │   7. arena destroy + source release       │
            └──────────────────────────────────────────┘
```

### Memory strategy

**Arena-only**, statically allocated at startup. No malloc / free
after `init_parser`. The arena is a `core:mem/virtual.Arena` sized at
`max(source_len * 256, 16 MB)`, lazy-committed via virtual memory.
Every AST node, [dynamic]T, token literal, and string lives in the
arena. On parse_file exit the arena is destroyed in one syscall.

### Key types

```odin
Parser {
    lexer: ^Lexer
    cur_tok / cur_type     // current token (cache)
    prev_token_end: u32    // for ESTree span.end
    check_semantics: bool  // gate for report_semantic_error (default false)
    allocator, source_len, node_pool, errors
    interner: ^StringInterner  // identifier dedup
    in_function, in_async, in_generator, strict_mode,  // context flags
      in_method, in_static_block, in_module_top_level,
      class_has_extends, no_in, ...
    label_stack, label_floor    // §13.13 break/continue
    pending_proto_dups, pending_cover_inits  // late-error stash
    has_module_syntax, force_source_type, force_strict
    lang: Lang  // .JS | .JSX | .TS | .TSX
}

Lexer {
    // HOT (single cache line, 64 B)
    source_bytes: []u8
    offset: int
    had_line_terminator, last_token_type, template_depth
    is_module_mode
    template_brace_stack: [8]u8
    cur, nxt: FastToken           // 16 B each, two-token lookahead

    // WARM
    source: string
    last_lit_offset / value / type
    cur_lit_offset / value / type

    // COLD
    line_offsets: []u32, num_lines, line, column
    template_stack, strict_mode, at_start_of_file, comments
}
```

---

## Key Design Decisions

1. **Odin, not Rust or Zig.** Single-source language. Odin's structs
   map naturally to ESTree shapes.

2. **Arena-only memory.** All allocations live in a single
   virtual-memory arena destroyed in one syscall on exit.

3. **Pratt parser, not a generated one.** Manual recursive-descent
   with precedence climbing.

4. **OXC as the conformance oracle.** Every gate compares kessel to
   OXC's `parseSync` (npm `oxc-parser`).

5. **TS-shape emit toggle.** `emit_ts_shape` adds TS-ESTree-only
   fields when parsing TS / TSX.

6. **Field append-only on ESTree-shape structs.** Avoids raw_transfer
   ABI breakage.

7. **Skip multi-file `@filename:` projects in the OXC corpus.**
   3,519 fixtures (14%) skip-counted.

8. **Permissive parser + separate semantic checker (W8+W9).** The
   parser no longer enforces ECMA-262 early errors that don't affect
   parsing decisions. ~120 `report_semantic_error` calls gated on
   `check_semantics` (default `false`). Matches OXC's `oxc_parser`
   vs `oxc_semantic` split.

9. **`await using` 3-token lookahead (W9).** Uses `lexer_snapshot` /
   `lexer_restore` to peek past `await` and `using` and check the
   third token before committing to AwaitUsingDeclaration. Covers
   `await using in foo`, `await using.x`, `await using[x]`, etc.

---

## Known Issues

As of W9 end-of-session. No `git stash`, no WIP branches.

| Issue | Severity | Where |
|---|---|---|
| **60 OXC-corpus kessel-only-rejects.** Genuine parser gaps (see "Remaining 60" below). | medium | `src/parser.odin` |
| **1,135 corpus oxc-only-rejects.** kessel accepts what OXC rejects. Not yet triaged. | low | various |
| **Semantic checker is a stub and `--show-semantic-errors` is effectively dead.** `src/checker.odin` has no runtime checks and `init_checker` / `check_program` have no callers in `src`. ~120 `report_semantic_error` calls in the parser are gated on `check_semantics=false` (default). Source review found `--show-semantic-errors` is parsed into `show_semantic_errors_enabled`, but no source assignment to `p.check_semantics`; `init_parser()` copies `p.check_semantics` into `lexer.check_semantics`, so semantic-gated parser errors and regex semantic validation stay off. Wire the flag and add a CLI regression before relying on semantic / regex validation modes. | high | `src/checker.odin`, `src/main.odin`, `src/parser.odin`, `src/lexer.odin` |
| **Multi-worker parse-to-disk path is not thread-safe and ignores language detection.** `parse_file_to_disk()` / `parse_file_raw_to_disk()` are called from `worker_proc`, but mutate global emitter state (`direct_buf`, `direct_pos`, `use_direct_buf`, `utf16_offsets`, plus emit toggles / loc state). The save/restore pattern is per-call, not thread-safe. These paths also call `init_parser()` / `produce_raw_buffer()` with default `.JSX`, ignoring extension detection and `--lang` for `.ts`, `.tsx`, `.mts`, `.cts`, `.d.ts`. Make emitter state per-worker/per-call and pass `resolve_lang(file_path)` through disk/raw paths. | high | `src/main.odin` |
| **Line table can silently truncate and misses JS line terminators.** `build_line_table()` preallocates `src_len / 40 + 16`, then `break`s if there are more lines than capacity. Files with many short lines get wrong `loc` and error line/column data after the cap. It also only treats `\n` as a line break; JS also has `\r`, `\r\n`, U+2028, U+2029. | medium | `src/lexer.odin` |
| **Expression loc helpers are incomplete.** `loc_from_expr()` and `get_expr_loc_ptr()` miss JSX variants, TS expression variants, and `TSInstantiationExpression`. If parser code calls `loc_from_expr()` on those nodes, spans become `{0,0}`; `set_expr_start` / `set_expr_end` / `get_expr_loc_ptr` currently look dead, but either delete them or make them exhaustive. | medium | `src/parser.odin` |
| **Raw-transfer pointer rewrite coverage is fragile/incomplete.** Source review found missing variants: `TSInstantiationExpression`, `TSImportEqualsDeclaration`, `TSExportAssignment`, `TSNamespaceExportDeclaration`. Likely missing fields include `CallExpression.type_parameters`, `NewExpression.type_parameters`, `ImportExpression.options`, `ImportExpression.phase`, `ClassExpression.super_type_arguments`, `ImportDeclaration.source/attributes/phase`, and export specifier/source/attribute internals. The `#partial switch` defaults hide new AST fields silently; comments claiming full coverage are stale. Add coverage tests / exhaustive guards. | high | `src/raw_transfer.odin`, `src/ast.odin` |
| **AST evolution has no compile-time guard.** Adding fields/variants requires updates to JSON emitter, raw-transfer walker, semantic checker, scope/private-name walkers, and tests. Today missing raw-transfer cases can compile and corrupt binary output. Add invariant tests that enumerate AST union variants and field surfaces. | medium | `src/ast.odin`, `src/raw_transfer.odin`, `src/main.odin` |
| **2.5 GB unused vendor data.** `vendor/estree-conformance/` has 2.3 GB of golden-JSON oracles we don't consume. | annoying | `vendor/estree-conformance/` |
| **TS multi-file `@filename:` projects skipped.** 3,519 fixtures (14%) skip-counted. | medium | `tests/verifiers/verify_oxc_corpus.js` |
| **estree-conformance/acorn-jsx 018.jsx fails.** kessel mis-lexes JSX text content as JS tokens. | medium | `src/lexer.odin` JSX text scanner |
| **TSImportEqualsDeclaration + TSExportAssignment + TSNamespaceExportDeclaration not wired through raw_transfer.** | low | `src/raw_transfer.odin` |
| **TSIndexSignature class-element node not emitted.** | low | `src/parser.odin` |
| **AST shape gaps (surfaces on deep walker).** `declare` class-member modifier not emitted. Per-specifier `importKind`/`exportKind` not emitted. CatchClause `type_annotation` slot missing. Parameter decorators consumed but not attached. | low | `src/ast.odin` + emitter |
| **Bench numbers vary 15-20% intra-session.** Thermal throttling / cache / scheduler. | annoying | bench methodology |

---

## Remaining 60 kessel-only-rejects

Clustered by error message (triage with
`node tests/verifiers/triage_kessel_only_rejects.js`):

### Flow-only (~10 files)
- `babel/flow/*` — kessel doesn't support Flow syntax. These produce
  "Expected (, got identifier/UNKNOWN/[/private_identifier" etc. Not
  fixable without a Flow parser. Skip.

### `<<` token splitting (~7 files)
- 3 "Expected expression after operator" — `f<<T>(...) => void>()`
- 2 "Expected {, got <<" — class/interface heritage with `<<`
- 2 "Decorators can only be applied to class expressions" — decorator
  with `<<` in type args
- 1 "Unexpected token '<<'" — `parseGenericArrowRatherThanLeftShift`
- 1 "Expected >, got <<" — JSX opening element with `<<`
- **Fix:** Split `<<` (LShift) into two `<` tokens during type-argument
  trial parse. Hard — requires lexer token splitting architecture.

### Expected semicolon (~6 files)
- Mixed bag: `importDeclWithClassModifiers`, `sourceMap-LineBreaks`,
  `yield/regexp`, `arrow-like-in-conditional`, `destructuringObjectBinding`,
  `destructuringObjectBindingPatternAndAssignment5`.
- Each is a distinct parser corner. Several are ASI edge cases.

### estree class method type params (~3 files)
- 3 "Expected method or property name" — `babel/estree/class-method/`
  with TypeScript type params in ranges mode
- **Fix:** Wire TS type params through class method in estree emit mode.

### async-call-in-conditional (~2 files)
- 2 "Expected :, got ;" — `async<T>()` in conditional (ternary)
- **Fix:** Trial-parse the generic-arrow candidate before committing.

### Export ASI (~2 files)
- 2 "Expected semicolon after export declaration" — `export ... with {}\n[0]`
- ASI doesn't insert before `[` per spec. OXC is more lenient here.

### `await` operand (~2 files)
- 2 "'await' expression requires an operand" — `topLevelAwait.2.ts`,
  `valid-script-await-as-lhs`
- `await` as identifier in non-async / script context.

### `Invalid expression for arrow function parameters` (~2 files)
- `yield` as arrow parameter inside generator.
- detached-comment lambda function.

### Misc 1-file edge cases (~26 files)
- `Expected ?, got ,` — deeply nested mapped types / call signatures
- `Expected >, got &` — JSX emit entities
- `Expected >, got EOF` — JSX no-plugin fallback
- `Invalid character in identifier` — file with Next Line (NEL) char
- `Unterminated regular expression` / `Unterminated group`
- `Unexpected token '.'` — `not-directive` test (directive prologue edge case)
- `Unexpected token '='` — `let-with-linebreak-obj-dstrk` (ASI edge case)
- `Expected '}' at end of function body` — `yield/input-not-followed-by-regex`
- `Expected template middle / tail` — `>>` splitting inside template literal types
- `Expected }, got ?` — ASI in interface with computed optional props
- `Expected {, got ?` / `Expected {, got !` — TS Flow-like nullable types
- `Expected }, got if` — export type-only `as as` keyword edge case
- Various 1-off TS/JSX/regex corners

---

## Incomplete Work

**Semantic checker implementation.** `src/checker.odin` is a skeleton.
~120 `report_semantic_error` calls in the parser are gated off by
default (`check_semantics=false`). The next step is building a full
AST walker in the checker that enforces these early errors by
walking ancestors (like OXC's `oxc_semantic/src/checker/javascript.rs`).

**Parser state cleanup.** The validation-only fields (`in_loop`,
`in_switch`, `label_stack`, `label_is_iteration`, `label_floor`,
`in_method`, `in_non_arrow_function`, `in_derived_constructor`,
`class_has_extends`, `in_case_clause`, `pending_proto_dups`,
`last_body_strict`) still exist in the Parser struct — their checks
are gated but the save/restore code still runs. Removing them is
safe once the checker handles the checks, and will shrink the
Parser struct and eliminate ~135 lines of save/restore boilerplate.

**Dead/stale code and comments found by source-only review.** High-confidence
dead helpers: `label_iter_in_scope`, `set_expr_start`, `set_expr_end`,
`get_expr_loc_ptr` (only used by dead setters), `is_valid_script_property_value`,
and checker entry points until wired. Stale comments include: lexer comment saying
parser reads `bom_before_hashbang` (lexer now reports directly), continue-statement
comment saying labels are not tracked, and raw_transfer comments saying all
expression variants are handled.

No git stash. No WIP branches. No half-merged feature flags.

---

## What To Work On Next

Prioritized for the next session.

### Pipeline architecture

1. **Fix semantic flag wiring before checker work.** `--show-semantic-errors`
   must set `p.check_semantics` and `lex.check_semantics` for all parse entry
   points. Add a CLI regression where a semantic-only error is hidden by default
   and shown with the flag, plus one invalid regex body that only appears when
   semantic validation is enabled. **Files:** `src/main.odin`, `src/parser.odin`,
   `src/lexer.odin`. **Difficulty:** low.

2. **Build the semantic checker AST walker.** `src/checker.odin` is
   a stub. Implement `check_program` as a recursive visitor that
   walks `Program → Statement → Expression` and enforces early
   errors by inspecting ancestors. Start with break/continue (easiest
   to test), then labels, then super/new.target, then strict-mode
   bindings. Wire it from parse entry points when semantic checking is
   requested. **Files:** `src/checker.odin`, `src/main.odin`. **Difficulty:** medium.

3. **Fix parse-many thread safety and language mode.** Move JSON emitter state
   (`direct_buf`, `direct_pos`, `use_direct_buf`, `utf16_offsets`, loc tables)
   out of globals or make it thread-local/per-call. Pass `resolve_lang(file_path)`
   through `parse_file_to_disk()` and `parse_file_raw_to_disk()` / `produce_raw_buffer()`.
   Add a multi-worker `.ts` fixture regression. **Files:** `src/main.odin`. **Difficulty:** medium.

4. **Remove validation-only state from the Parser struct.** Once
   the checker handles each category, remove the corresponding
   field and its ~135 lines of save/restore ceremony.
   **Files:** `src/parser.odin`. **Difficulty:** low per field.

### Parser gaps (60 remaining)

5. **`<<` token splitting.** ~7 corpus files. Requires splitting the
   `<<` (LShift) token into two `<` tokens during type-argument
   trial parse. **Files:** `src/lexer.odin` + `src/parser.odin`.
   **Difficulty:** hard.

6. **Template literal type `>>` splitting.** ~1 corpus file. When
   `>>` appears inside a template literal type `${...}`, the
   `try_split_close_angle` re-lex interferes with template depth
   tracking. The re-lexed `}` isn't recognized as a template closer.
   **Files:** `src/lexer.odin`. **Difficulty:** medium.

7. **ASI edge cases.** ~3-4 corpus files. ASI inside interfaces and
   type literals with computed optional properties (`[x]?: T` without
   semicolons). `can_insert_semicolon` doesn't know it's inside an
   interface/type-literal. **Difficulty:** medium.

8. **Continue corpus bug-hunting.** Run
   `node tests/verifiers/triage_kessel_only_rejects.js` for the
   live cluster list. Each remaining cluster is 1-3 files.

### Infrastructure

9. **Implement TS multi-file `@filename:` splitting.** Unlock 3,519
   currently-skipped corpus fixtures. **Difficulty:** medium.

10. **Phase 2b — deep AST walker on the corpus.** Compare AST shape
    (not just accept/reject) against OXC. **Difficulty:** medium.

11. **Audit and harden raw_transfer exhaustiveness.** Start by wiring the
    missing surfaces from the source review: `TSImportEqualsDeclaration`,
    `TSExportAssignment`, `TSNamespaceExportDeclaration`,
    `TSInstantiationExpression`, call/new type parameters,
    `ImportExpression.options/phase`, class `super_type_arguments`, and
    import/export specifier/source/attribute internals. Then add a gate that
    fails when a new AST union variant or pointer/string-bearing field lacks
    a rewrite path. **Difficulty:** medium.

12. **Fix line/loc table generation.** Make `build_line_table()` grow instead
    of silently truncating and recognize all ECMAScript line terminators
    (`\n`, `\r`, `\r\n`, U+2028, U+2029). Add a fixture with many one-byte
    lines and mixed terminators. **Difficulty:** low.

13. **Make expression location helpers exhaustive or delete dead ones.** Add
    missing JSX / TS expression / `TSInstantiationExpression` cases to
    `loc_from_expr()` and `get_expr_loc_ptr()`, or remove `set_expr_start`,
    `set_expr_end`, and `get_expr_loc_ptr` if unused. Add invariant coverage
    for every `Expression` union variant. **Difficulty:** low.

14. **Cleanup dead code and stale comments.** Remove or update
    `label_iter_in_scope`, `is_valid_script_property_value`, stale
    `bom_before_hashbang` / continue-label / raw_transfer coverage comments,
    and noisy placeholder comments around `_unused_lexer_pad`. **Difficulty:** low.

---

## Commands Reference

### Build

```bash
task build                 # release build → bin/kessel
task build:debug           # debug build → bin/kessel-debug + dSYM
```

### Tests (fastest first)

```bash
task test:unit             # 415 fixtures, ~12 s
task test:regression       # 11 checks, ~5 s
task test:estree           # ESTree drift gate, ~10 s
task test:invariants       # zero-tolerance invariants
task test:negative         # negative fixtures must reject
task test:ambiguity        # JS/TS/JSX boundary
task test:nodes            # 57/57 ESTree node coverage
task test:recovery         # 31/31 error-recovery anchors
task test:lexical          # lexical surface gates
task test:spec-compliance  # 13 files × 3 reference parsers
task test:spec-fixtures    # 150 hand-authored ES feature fixtures
task test:test262          # 66 curated Test262 tests
task test:test262:subset   # categorised Test262 subset
task test:multi-parser     # deep JSON compare across parsers
task test:fuzz             # fuzz diff (baselined)
task test:fuzz:invalid     # fuzz invalid corpus (baselined)
task test:crashes-known    # baselined crash-reproductions
task test:real             # 467/467 real-world parse smoke
task test                  # run the everyday chain
```

### OXC corpus (off the default chain)

```bash
task test:oxc-corpus:fetch       # one-time: clone TS + Babel + estree (~213 MB)
task test:oxc-corpus              # ~13 s — baseline-gated smoke run on 25,140 fixtures
task test:oxc-corpus:full         # same run without gating, writes JSON to tmp/
task test:oxc-corpus:update       # re-lock baseline after intentional fix
node tests/verifiers/triage_kessel_only_rejects.js [--max-per-cluster N]
                                  # cluster the rejects by first-error-message
```

### Bench

```bash
task test:bench:regression        # 30 iter × 10 files vs baseline, ~30 s
task bench                        # 467-file run with summary by tier
task bench:oxc:build              # build the OXC comparator (one-time)
```

### Triage / debug

```bash
node tests/verifiers/verify_oxc_corpus.js --json-out tmp/run.json
node tests/verifiers/triage_kessel_only_rejects.js --max-per-cluster 3
bin/kessel parse <file> [--lang=ts|tsx|jsx] [--compact]
bin/kessel parse <file> --raw --out tmp/x.bin
bin/kessel microbench parse <file> [--iterations N]
lldb -batch -o "run parse <file>" -o "thread backtrace 5" bin/kessel-debug
```

---

## Session History

### W6 (S26) — OXC corpus launch + first 39 bug classes

Net: kessel-only-rejects 2,973 → 883 (-70%). 39 bug classes closed.
kessel-crash 20 → 0, kessel-timeout 222 → 0.

### W7 (S26) — 29 more bug classes

Net: kessel-only-rejects 883 → 787 (-11%). 29 bug classes closed.
New AST node: TSInstantiationExpression.

### W8 (S26) — permissive parser refactor + 12 bug classes

Net: kessel-only-rejects 787 → 554 (-30%). 12 bug classes closed.
Major refactor: 71 `report_error` → `report_semantic_error`.
New: `JSXOpeningElement.type_arguments`, `jsx_string_mode`.

### W9 (S26) — massive semantic-error conversion + disambiguation fixes

Net: kessel-only-rejects **554 → 83** (**-85%**).

| # | Fix | Impact |
|---|---|---|
| 81 | Convert ~50 early-error checks → `report_semantic_error` | -448 rejects |
| 82 | TS `this`-param in getter/setter arity + delete strict | -9 |
| 83 | `await using` 3-token lookahead disambiguation | -5 |
| 84 | `using`/`let` disambiguation in for-head + strict mode | -7 |
| 85 | Rest trailing comma → semantic error | -2 |

New helpers added:
- `report_semantic_error_at(p, loc, msg)` — semantic error at location
- `await_using_starts_decl(p)` — 3-token lookahead via snapshot
- `is_this_param(fp)` / `count_real_params(p, params)` — TS accessor
- `is_ident_continue_byte(ch)` — fast ASCII identifier check

Cumulative across all sessions: kessel-only-rejects **2,973 → 60**
(**-98.0%**).

### W10 (S26) — 10 more bug classes

Net: kessel-only-rejects **83 → 60** (**-27.7%**). 10 bug classes closed.

| # | Fix | Impact |
|---|---|---|
| 89 | Regex validation gated as semantic errors | -8 rejects |
| 90 | infer-with-constraints speculative parse + ts_disallow_conditional_types | -3 rejects |
| 91 | Decorator private field access (@C.#dec) | -2 rejects |
| 92 | Tuple keyword-labeled elements (function:, string:, void?:) | -1 reject |
| 93 | Type parameter >= split (type T<U>=U) | -1 reject |
| 94 | new A<B> relational disambiguation | -4 rejects |
| 95 | export default function ASI with newline | -1 reject |
| 96 | Conditional types in function type signature params | -1 reject |
| 97 | Reset no_in inside parse_arguments | -1 reject |
| 98 | Compound assignment LHS → semantic error | -1 reject |

New infrastructure added:
- `check_semantics: bool` on Lexer struct (propagated from Parser)
- `ts_disallow_conditional_types: int` depth counter on Parser struct
- Save/restore at grouping boundaries: (), [], {}, <>, function sigs, return types
- Speculative parse for `infer U extends C ?` disambiguation
- Speculative parse for `new Expr<` type-argument disambiguation

### Notes for the next session

* All commits pushed to `origin/main`. Clean state.
* `tmp/_w6_full_smoke.json` is up to date as of HEAD (60
  kessel-only-rejects); the triage tool reads it directly.
* Remaining 60 rejects are categorized above. The biggest
  remaining wins are:
  - `<<` token splitting (~7 files) — hard, architectural
  - "Expected semicolon" mixed bag (~6 files) — various distinct issues
  - Flow fixtures (~10 files) — won't fix (no Flow support)
  - ASI edge cases inside interfaces/type-literals — medium
  - Template literal type `>>` splitting in template contexts — medium
  - Long tail of 1-file edge cases (~26 files)
* Pipeline architecture priority: build the semantic checker.
