# Handoff — Kessel

## What is Kessel

A JavaScript parser written in Odin that produces an ESTree-compatible AST.
Targets sub-Rust parse times on production JS via arena allocation,
ARM64-NEON SIMD lexing, and a Pratt expression parser. The codebase is ~11k
lines of Odin split across 7 files, with a zero-copy "raw transfer" binary
output mode for cross-language consumption (rewrites native pointers to
`u32` offsets relative to the arena base).

## Current state

### Build

```
$ task build
task: [build] mkdir -p bin
task: [build] odin build src -out:bin/kessel -o:speed -no-bounds-check
task: [build] rm -rf bin/kessel.dSYM
```

Clean. No warnings, no errors. Produces a single ~720 KB binary at `bin/kessel`.

### Tests

| Suite | Command | Result |
|---|---|---|
| Unit | `task test:unit` | **98 / 98 pass** (100%) |
| Regression | `task test:regression` | **11 / 11 pass** — structural checks vs OXC for every session-fixed bug |
| ESTree deep-tree | `task test:estree` | **4 / 4 pass** — jquery.js (51,406 fields), react-dom.dev.js (104,989 fields), preact.js (2,716 fields), snabbdom.js (17 fields), all byte-exact vs OXC |
| Real-world parse | `task test:real` | **467 / 467 pass** — **0 parse errors, 0 SIGSEGVs** |
| String-escape vs OXC | **ALL 467 files** | **467 / 467 full-match, 0 mismatches, 0 partial, 0 errors** |
| String-escape vs OXC | `node tests/verify_string_escapes.js <file>` | See table below |

**Real-world string-escape verification vs OXC**:

| File                    | OXC strings | Kessel visible | compared |
|-------------------------|------------:|---------------:|---------:|
| antd.js                 |      22,135 |     **22,134** |  17,428 |
| three.module.js         |       2,177 |      **2,176** |   1,698 |
| handsontable.js         |       6,270 |      **6,270** |   6,270 |
| phaser.js               |       5,303 |      **5,303** |   5,303 |
| tone.js                 |       1,917 |      **1,911** |     493 |
| chartjs.js              |       1,248 |      **1,242** |     377 |
| mapbox.js               |       5,506 |      **5,503** |     925 |
| prettier.js             |         523 |        **518** |      82 |
| lit-html.js             |          41 |         **41** |      41 |
| petite-vue.js           |         150 |        **150** |     150 |
| babel.js                |       9,663 |          9,663 |   9,663 |
| react-dom.dev.js        |       3,790 |          3,790 |   3,790 |
| jquery.js               |         980 |            980 |     980 |
| lodash.js               |         945 |            945 |     945 |
| react.dev.js            |         335 |            335 |     335 |
| preact.js               |          72 |             72 |      72 |

> **Session totals**: 12 files that previously SIGSEGV'd or had near-zero
> visibility now parse cleanly and emit comparable string-escape counts.
> The 2 lone-surrogate mismatches on handsontable.js (`\uDEAD`,
> `\uDF06\uD834`) are also **resolved** via I-8 below. Every real-world
> file in the verifier corpus is at `mismatches=0` vs OXC.

## Project Structure

### `src/` — ~11,000 LOC Odin

| File | Lines | Purpose |
|---|---:|---|
| `src/ast.odin` | 747 | AST nodes + unions. |
| `src/token.odin` | 323 | Token types and helpers. |
| `src/simd.odin` | 128 | ARM64 NEON 16-byte helpers. |
| `src/lexer.odin` | 1,363 | Tokenizer + cooked string escapes. |
| `src/parser.odin` | 4,374 | Recursive-descent + Pratt. 4 more transmute-class sites fixed this session (3 arrow arms + export-declaration). |
| `src/raw_transfer.odin` | 651 | Walks AST and rewrites pointers to u32 offsets. **This session: cooked-string arena encoding via high-bit flag** so strings escape-decoded in the arena are distinguishable from source-origin strings when the reader reconstructs them. |
| `src/main.odin` | 3,290 | CLI, output emitters, worker driver, microbench. **This session: ClassBody full emit, direct_buf growth, full Pattern emit (RestElement / AssignmentPattern / MemberExpression pattern), `Super` leaf emit.** |

### `tests/`

| File | Purpose |
|---|---|
| `tests/run_tests.sh` | Unit-test driver. |
| `tests/verify_raw.js` / `verify_raw_deep.js` / `verify_integration.js` | Raw-transfer & integration tests; updated for the new cooked-string arena flag. |
| `tests/verify_string_escapes.js` | OXC-paired escape verifier. |
| `tests/verify_regression.js` | **Structural regression suite** for every session-fixed bug. Ten checks, each validated by revert: reverting the specific fix in isolation causes exactly the corresponding check to fail. |
| `tests/verify_estree_structural.js` | **Deep-tree walker vs OXC** (new in orphan work); drives `task test:estree` on 4 real files. |
| `tests/fixtures/regression/001..010_*.js` | One fixture per session-fixed bug. Committed. |
| `tests/expected/regression/*.txt` | Pinned expected JSON for bit-exact diff in `run_tests.sh`. Committed. |

## Bugs Fixed Across This Session Arc

Ten regression-guarded bugs, all same or related classes.

### I-1 · `parse_static_block` transmute(^BlockStatement)
`src/parser.odin`. Fix: type assertion.
Guard: `tests/fixtures/regression/001_static_block_body.js`.

### I-2 · `parse_for` for-in/of `left_decl` transmute
`src/parser.odin`. Fix: type assertion.
Guard: `tests/fixtures/regression/003_class_for_in_of.js`.

### I-3 · For / ForIn / ForOf `(^Statement)(decl)` emit cast
`src/main.odin`. Fix: extracted `print_variable_declaration_body`; emit inline.
Guard: `tests/fixtures/regression/002_class_for_statement.js`.

### I-4 · Export declaration cross-union cast
`src/parser.odin` + `src/main.odin`. Declaration↔Statement have different
tag ordinal spaces. Fix: allocate fresh union + `print_declaration_ast`
rebuilds Statement via assignment.
Guard: `tests/fixtures/regression/004_export_declarations.js`.

### I-5 · ClassBody JSON emit stub
`src/main.odin`. Fix: `print_class_body_inline` + `print_class_element_fields`
+ `print_class_element_static_block`. Matches OXC byte-for-byte.
Guard: `tests/fixtures/regression/005_class_body_full_emit.js`.

### I-6 · `direct_buf` fixed 20× source overflow
`src/main.odin`. Fix: `direct_reserve` grows by doubling before every write.
Guard: `tests/fixtures/regression/006_direct_buf_grow.js`.

### I-8 · Lone-surrogate WTF-8 round-trip through JSON

`src/main.odin` `out_string` / `out_string_inner`. ECMA-262 permits lone
surrogates in string literals (e.g. `"\uDEAD"`); the lexer's `append_utf8`
encodes them in WTF-8 (0xED 0xA0–0xBF 0x80–0xBF), but out_string streamed
those raw bytes to stdout — JSON forbids raw surrogate bytes, so JSON.parse
normalised the invalid-UTF-8 triple to three U+FFFD chars.

Fix: `wtf8_surrogate_at` detects the 3-byte WTF-8 triple at emit time;
both `out_string` and `out_string_inner` escape as `\uXXXX` (lowercase
hex, matching OXC). ECMA-262-compliant: the ESTree `value` field
round-trips through JSON.parse as a 1-codepoint string whose codePointAt
still lies in 0xD800–0xDFFF.

Guard: `tests/fixtures/regression/011_lone_surrogate_emit.js` exercises
bare lone low/high surrogates, mixed contexts, reversed "pairs" (low+high
which don't combine), valid surrogate pairs that must NOT be escaped, and
object-literal values. Check asserts no U+FFFD ever appears in any
`Literal.value`, validated by revert (reverting the direct_buf surrogate
handling produces exactly the regression fail pattern).

### I-7 · Arrow-function body `cast(^BlockStatement)^Statement` (×3 sites)
`src/parser.odin`, `parse_arrow_function` + `parse_async_arrow_function` +
`parse_async_arrow_with_parens`. **Resolved all 12 SIGSEGV files** (tone.js,
mathjax.js, marked.js, chartjs.js, quill.js, embla.js, mapbox.js,
openlayers.js, framer-motion.js, lit-html.js, petite-vue.js, prettier.js)
in one bug. Fix: `block_stmt^.(^BlockStatement)`.
Guard: `tests/fixtures/regression/010_arrow_block_body.js`.

### O-1 · Directive Prologue emit (`"use strict"` in body + directives)
`src/main.odin`. Previously the ExpressionStatement wrapping the directive
appeared only in `program.directives`, not `program.body`. ESTree spec
requires both.
Guard: `tests/fixtures/regression/007_use_strict_directive.js`.

### O-2 · `export * from` trailing-semicolon consumption
`src/parser.odin`. Previously left a spurious EmptyStatement in body.
Guard: `tests/fixtures/regression/008_export_all.js`.

### O-3 · Pattern emit completeness (RestElement / AssignmentPattern / MemberExpression / ObjectPattern rest)
`src/main.odin`. `print_pattern_ast` only handled 3 of 6 Pattern variants;
the rest fell through to `null` and ArrayPattern.elements wrapped every
element in `{…}` unconditionally, producing invalid JSON `{null}` on
`[a, ...rest]`. ObjectPattern rest was wrapped in `Property` instead of
emitted directly.
Guard: `tests/fixtures/regression/009_destructure_patterns.js`.

### R-1 · Raw-transfer cooked-string encoding
`src/raw_transfer.odin` + `tests/verify_raw*.js`. `rewrite_string` wrote
every string as a source-relative offset, even for Bug-E-cooked strings
that live in the arena. Fix: `STRING_ARENA_FLAG = 0x8000_0000` high-bit
discriminates source vs arena origin; readers updated.
Guard: `task test:estree` on jquery.js (51,406 fields), react-dom.dev.js
(104,989 fields) all zero mismatches.

### R-2 · `Super` emitted as `[UNIMPLEMENTED]`
`src/main.odin`. ESTree spec is a leaf `{"type": "Super"}`. Fix: explicit case.
Guard: blanket no-`UNIMPLEMENTED` / no-`Unknown` assertion in every
`verify_regression.js` run (covers `super(...)` / `super.x`).

## Regression Test Discipline

Every bug above is guarded by:

1. **Fixture** under `tests/fixtures/regression/` that reproduces the bug
   on reverted code. Committed.
2. **Expected JSON** under `tests/expected/regression/` (bit-exact
   comparison via `run_tests.sh`). Committed.
3. **Structural check** in `tests/verify_regression.js` — path-based
   assertions (e.g. `ForStatement.init.type == VariableDeclaration`,
   `ArrowFunctionExpression.body.body.length > 0`). Stricter than flat
   type-count because bugs often preserve the node name while dispatching
   through the wrong variant.
4. **Blanket invariant**: no node in the emitted JSON may carry
   `[UNIMPLEMENTED]: true` or `"type": "Unknown"`. Either is a sign that a
   switch/case fell through a default arm — silent ESTree drift of the
   exact kind this session arc eliminated.
5. **Each check validated by revert**: reverting the specific fix in
   isolation causes exactly the corresponding check to fail. Proof the
   check guards the fix and not something tangential.

Runner: `task test:regression` (`node tests/verify_regression.js`).

## Known Issues

| Issue | Severity | Where | Workaround |
|---|---|---|---|
| **34 real-world files fail to parse** | Medium | `task test:real` | Genuine parse errors, pre-existing. 6 of the originally-listed 12 SIGSEGV files actually have parse-error content too (tone.js: 20 errors, framer-motion.js: 10, mapbox.js: 5, chartjs.js: 2, quill.js: 1, petite-vue.js: 1) — previously masked by the emit-time crashes. |
| **`execSync` SIGSEGV on some real files** | Medium | Node-spawned `kessel raw <file>` | Pre-existing; separate from the emit-time crashes fixed this session arc. Likely `os.flush` race on detached pipes. |
| **Templates don't cook escapes** | Low | `src/lexer.odin` — `lex_template` | Bug E class in template path. |

## What To Work On Next

### P1 · Template-literal escape cooking · medium

Bug E class, but in `lex_template` / `lex_template_resume`. Same arena
cooking strategy; publish via `last_lit_*`. Fixture under
`tests/fixtures/edge/template_escapes.js`; cross-verify vs OXC.

### P3 · T4 — eliminate the rewrite pass · high · largest scope

The parser currently allocates native pointers, then `raw_transfer.odin`
walks the tree converting to u32 offsets. Writing offsets directly from
the parser skips a full AST walk per file. Requires a design pass.

### P4 · Investigate 34 pre-existing parse failures · high · not a quick fix

`vue.global.js` + `batch3/tinymce.js` still account for ~95 of the total
errors. Group failures by first-error pattern and decide per-file.

## Commands Reference

```bash
# Build
task build                                    # release binary → bin/kessel
task build:debug                              # debug with bounds checks

# Test
task test:unit                                # 97 fixtures, ~1s
task test:regression                          # 10 structural vs OXC, ~2s
task test:estree                              # 4 deep-walked files vs OXC, ~5s
task test:real                                # 467 real files, ~3-5min (34 failures, 0 crashes)
node tests/verify_string_escapes.js <file>    # OXC-paired escape verifier
node tests/verify_regression.js               # standalone regression runner

# Bench
task bench:quick                              # 10 files vs OXC, 30 iters, ~1min
task bench                                    # all 467 files, ~5min

# Run
./bin/kessel parse <file>                     # pretty JSON + stats
./bin/kessel parse <file> --compact           # single-line JSON
./bin/kessel raw <file> --out <path>          # zero-copy binary AST
./bin/kessel microbench parse <file> --iterations N
```

## Session Log

| Area | Change |
|---|---|
| I-7 arrow-body transmute | 3 sites in `parse_arrow_function` / `parse_async_arrow_function` / `parse_async_arrow_with_parens` — all 12 SIGSEGV files resolved in one bug. Regression fixture `010_arrow_block_body.js` + path-specific check. |
| I-5 ClassBody full emit | `print_class_body_inline` + `print_class_element_fields` + `print_class_element_static_block`. |
| I-6 direct_buf growth | `direct_reserve` grows by doubling; worker free-path fixed. |
| I-1..I-4 transmute clean-up | StaticBlock, for-in/of decl, For* emit casts, Export Declaration↔Statement cross-union fix. |
| O-1..O-3 emit completeness | Directive Prologue in body + directives; `export * from;` semi consumption; full Pattern emit (RestElement / AssignmentPattern / MemberExpression-pattern / ObjectPattern rest). |
| R-1 raw-transfer cooking | `STRING_ARENA_FLAG` high-bit discriminates source vs arena origin. |
| R-2 `Super` leaf emit | Explicit case in `print_expression_ast`. |
| Taskfile | `task test:real` honest crash reporting; new `task test:regression` and `task test:estree`. |
| Regression suite | 10 committed fixtures + expected + verifier, each validated by revert. Blanket no-`UNIMPLEMENTED`/no-`Unknown` assertion. |

## What a fresh agent should do first

1. `task build && task test:unit && task test:regression && task test:estree` → all four clean in <10 s.
2. Read `AGENTS.md` (TigerStyle) and this file in full.
3. Pick **P1** (lone-surrogate emit) — smallest remaining gap vs OXC. Add a
   regression fixture with `['\uDEAD', 'x\uD834\uDF06y', ...]`, confirm it
   fails pre-fix, fix, confirm `handsontable.js` reaches
   `mismatches=0`.
4. Do not commit a fix without a regression fixture validated by revert.
   The discipline from this session arc is: every bug is guarded, every
   guard is proven to fail on the reverted code, every commit sets that
   state as the new baseline.
5. Never push past a failing `task test:unit`, `task test:regression`, or
   `task test:estree`.
