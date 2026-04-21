# Handoff — Kessel

## What is Kessel

A JavaScript parser written in Odin that produces an ESTree-compatible AST.
Targets sub-Rust parse times on production JS via arena allocation,
ARM64-NEON SIMD lexing, and a Pratt expression parser. The codebase is ~10k
lines of Odin split across 7 files, with a zero-copy "raw transfer" binary
output mode for cross-language consumption (rewrites native pointers to
`u32` offsets relative to the arena base).

## Current state (session on top of `f8ea96a`)

### Build

```
$ task build
task: [build] mkdir -p bin
task: [build] odin build src -out:bin/kessel -o:speed -no-bounds-check
task: [build] rm -rf bin/kessel.dSYM
```

Clean. No warnings, no errors. Produces a single ~720KB binary at `bin/kessel`.

### Tests

| Suite | Command | Result |
|---|---|---|
| Unit | `task test:unit` | **93 / 93 pass** (100%) |
| **Regression (new)** | `task test:regression` | **6 / 6 pass** — structural checks vs OXC for every bug fixed this session |
| Real-world parse | `task test:real` | **427 / 467 pass** — 28 files with parse errors, **12 new SIGSEGV files surfaced by P1** (see §Known Issues) |
| String-escape vs OXC | `node tests/verify_string_escapes.js <file>` | See table below |
| Raw-deep vs OXC | `node tests/verify_raw_deep.js <file>` | Works; shallow (see §Limitations) |
| Test262 (optional) | `tests/run_test262.sh` | Not run this session |

**Real-world string-escape verification vs OXC** (re-run this session):

| File                    | OXC strings | Kessel visible | compared | mismatches |
|-------------------------|-------------|----------------|---------:|-----------:|
| babel.js                |       9,663 |          9,663 |    9,663 |          0 |
| react-dom.dev.js        |       3,790 |          3,790 |    3,790 |          0 |
| antd.js                 |      22,135 |         15,009 |    1,022 |          0 |
| three.module.js         |       2,177 |      **2,165** | **1,564** |          0 |
| jquery.js               |         980 |            980 |      980 |          0 |
| lodash.js               |         945 |            945 |      945 |          0 |
| react.dev.js            |         335 |            335 |      335 |          0 |
| preact.js               |          72 |             72 |       72 |          0 |
| handsontable.js         |       6,270 |             24 |       24 |          0 |
| phaser.js               |       5,303 |              7 |        7 |          0 |
| typescript.js           |      16,346 |              2 |        1 |          0 |
| alpine.js               |         488 |              0 |        0 |          0 |

> **P1 payoff**: three.module.js visible strings grew from 1,404 → 2,165
> (+761, +54%) and paired strings grew 283 → 1,564 (+1,281, 5.5×). Other
> class-heavy files were already blocked by parse errors upstream of the
> class body.
> **Still zero mismatches** across all real-world strings compared.

### Performance

Not re-run this session. Expect comparable to previous numbers; class body
emit adds bytes per class in pretty JSON but does not touch the parse path.

## Project Structure

### `src/` — ~10,700 LOC Odin (+~400 LOC this session)

| File | Lines | Purpose |
|---|---:|---|
| `src/ast.odin` | 747 | AST nodes, `Expression`/`Statement`/`Declaration`/`Pattern` unions, `ArrowFunctionBody` union. |
| `src/token.odin` | 323 | `TokenType` enum, `Token`/`LiteralValue`/`LexerLoc` structs. |
| `src/simd.odin` | 128 | ARM64 NEON 16-byte vector helpers. |
| `src/lexer.odin` | 1,363 | Tokenizer with SIMD fast path + scalar fallback, cooked string escapes. |
| `src/parser.odin` | 4,353 | Recursive-descent + Pratt. **This session: 3 more transmute-class (Bug H) sites fixed** — `parse_static_block`, `parse_for` for-in/of `left_decl`, `parse_export_declaration`. |
| `src/raw_transfer.odin` | 590 | Walks AST and rewrites pointers to `u32` offsets. |
| `src/main.odin` | 3,240 | CLI, output emitters, worker driver, microbench. **This session: (a) `direct_buf` grows via doubling instead of fixed 20×, (b) `print_class_body_inline` + `print_class_element_fields` + `print_class_element_static_block` emit the full ESTree ClassBody, (c) `print_declaration_ast` routes ^Declaration via correct Statement tag, (d) `print_variable_declaration_body` extracted so for-in/of/for can reuse without fake-Statement casts.** |

### `tests/`

| File | Lines | Purpose |
|---|---:|---|
| `tests/run_tests.sh` | 136 | Unit-test driver. |
| `tests/run_test262.sh` | 80 | ECMA-262 conformance subset runner. |
| `tests/test262_fetch.sh` | 113 | Bootstraps a test262 checkout locally. |
| `tests/verify_raw.js` | 202 | Smoke tests the raw-transfer binary format. |
| `tests/verify_raw_deep.js` | 291 | OXC-cross-referenced deep walker (shallow). |
| `tests/verify_integration.js` | 523 | Larger-scope integration tests. |
| `tests/verify_string_escapes.js` | 87 | OXC-paired string-escape verifier. |
| `tests/verify_regression.js` | 194 | **New this session.** Structural regression checks for every bug fixed this session. Path-based assertions catch bugs where the type-count would otherwise look right. |
| `tests/fixtures/regression/` | (6 files) | **New this session.** One fixture per bug. Each fixture crashes or emits wrong output on a reverted fix. |
| `tests/fixtures/edge/string_escapes.js` | 19 | 15 escape patterns per ECMA-262 §12.9.4. |
| `tests/expected/regression/*.txt` | (6 files) | **New this session.** Committed expected JSON for each regression fixture. |
| `tests/fixtures/` (rest) | (87 files) | Hand-written fixtures. |

### `bench/`

Unchanged. 467 real-world JS files plus the OXC comparison tooling in `bench/oxc_compare/`.

## Architecture

(Unchanged from previous handoff — see `git show f8ea96a:HANDOFF.md` for the
full diagram. The single substantive change is that ClassBody is no longer
stubbed; it emits the same shape OXC does.)

Memory strategy unchanged: single `mvirtual.Arena` backs every AST
allocation; raw transfer writes in-place; arena is bulk-released at end of
parse.

### direct_buf growth (new)

Before this session, `direct_buf` was sized once at `max(len(source) * 20, 4096)`
and indexed blindly thereafter. This was calibrated against stubbed ClassBody
output. Full class emit pushes some files past 20× source, causing
out-of-bounds writes.

The fix (`direct_reserve` in `src/main.odin:51`) checks capacity before each
direct-mode write and grows by doubling, amortising to O(1) per byte and
removing the ceiling. The starting 20× estimate is retained so the common
case avoids any realloc.

## Known Issues

| Issue | Severity | Where | Workaround |
|---|---|---|---|
| **12 real-world files SIGSEGV during JSON emit** (see list below) | **High** | `./bin/kessel parse <file>` for tone.js, mathjax.js, marked.js, chartjs.js, quill.js, embla.js, mapbox.js, openlayers.js, framer-motion.js, lit-html.js, petite-vue.js, prettier.js | **New crashes surfaced by P1.** These files have some AST pattern that wasn't previously reached because ClassBody emit was stubbed. lldb traces show `get_statement_type_name + 88` crashing on a union with a corrupt tag — a Bug-H-class transmute somewhere I did not locate. 4 such sites were fixed this session; at least one more remains. **P2 in §What To Work On Next.** |
| **28 real-world files fail to parse** (true parse errors, not crashes) | Medium | `task test:real` | Pre-existing. Net change: +1 (terser.js newly surfaced because `test:real` used to silently mask crashes; not a real regression). |
| **`execSync` SIGSEGV on some real files** | Medium | Node-spawned `kessel raw <file>` | Documented in previous handoff; unchanged this session. Overlaps with the 12 new crashes. |
| **`verify_raw_deep.js` walker is shallow** | Low | `tests/verify_raw_deep.js` | Enhancement blocked on ClassBody emit (now done). Walker can now be deepened. |
| **Templates don't cook escapes** | Low | `src/lexer.odin` — `lex_template` | Same bug class as Bug E. |
| **`new_node(p, Identifier)` + field copy pattern is verbose** | Cosmetic | `parser.odin` | No correctness issue. |

### 12 new SIGSEGV files (high priority)

```
bench/real_world/batch2/tone.js
bench/real_world/batch2/mathjax.js
bench/real_world/batch2/marked.js
bench/real_world/batch2/chartjs.js
bench/real_world/batch2/quill.js
bench/real_world/batch3/embla.js
bench/real_world/batch3/mapbox.js
bench/real_world/batch3/openlayers.js
bench/real_world/batch3/framer-motion.js
bench/real_world/batch4/lit-html.js
bench/real_world/batch4/petite-vue.js
bench/real_world/prettier.js
```

All SIGSEGV in `get_statement_type_name + 88` during emit of a nested
`^Statement` that points at memory whose union tag is out of range. Bisection
within tone.js is unreliable (the crashing region depends on the exact
prefix boundary because the parser recovers differently at each cut). A
proper lldb + symbol-level debug session is needed. **Investigate
`grep -n 'transmute\|(\^Statement)\|(\^Declaration)\|(\^Expression)' src/parser.odin src/main.odin` as a starting point**; every remaining cast of
that form is suspect.

### 28 real-world parse-error files

Output of `task test:real 2>&1 | grep "errors$"`:

```
vue.global.js                  22 errors
batch2/swagger-ui.js           53 errors
batch2/monaco.js                7 errors
batch2/alpine.js                6 errors
batch2/fullcalendar.js          1 error
batch2/pixi.js                  3 errors
batch2/reveal.js                2 errors
batch2/terser.js                3 errors
batch2/yup.js                   1 error
batch2/zod.js                   2 errors
batch3/ckeditor.js              5 errors
batch3/effector.js              8 errors
batch3/popmotion.js             8 errors
batch3/stimulus.js              2 errors
batch3/tinymce.js              73 errors
batch3/tom-select.js            6 errors
batch4/ajv-formats.js           2 errors
batch4/chalk.js                 1 error
batch4/delay.js                 1 error
batch4/esbuild-wasm.js          1 error
batch4/ini.js                   2 errors
batch4/lru-cache.js             2 errors
batch4/minisearch.js            1 error
batch4/nanoid.js                1 error
batch4/plyr.js                  6 errors
batch4/wrap-ansi.js             1 error
batch4/wretch.js                2 errors
```

`task test:real` now honestly reports all failures. The previous Taskfile
ran `grep 'Parse errors:' | awk` which silently treated missing output (due
to SIGSEGV) as 0 errors. Fixed in this session.

## Bugs Fixed This Session

Six classes of bug with named regression fixtures.

### I-1 · `parse_static_block` transmute(^BlockStatement)

**Where**: `src/parser.odin:~1830`.
**Symptom**: Static block bodies emitted as `[]` regardless of content.
**Root cause**: `transmute(^BlockStatement)block_stmt` reinterpreted the
`^Statement` union header as a BlockStatement struct, zeroing the `body` field.
**Fix**: extract via type assertion `block_stmt^.(^BlockStatement)`.
**Regression fixture**: `tests/fixtures/regression/001_static_block_body.js`.

### I-2 · `parse_for` for-in/of `left_decl` transmute

**Where**: `src/parser.odin:~950`.
**Symptom**: Would corrupt the for-in/of left declaration pointer; combined
with I-3 below, surfaced as SIGSEGV inside class methods containing
`for (let k in/of obj)`.
**Root cause**: `transmute(^VariableDeclaration)decl_stmt` on a `^Statement`
union — reading the union header as a VariableDeclaration struct.
**Fix**: type assertion `decl_stmt^.(^VariableDeclaration)`.
**Regression fixture**: `tests/fixtures/regression/003_class_for_in_of.js`.

### I-3 · ForStatement / ForIn / ForOf `(^Statement)(decl)` cast in emit

**Where**: `src/main.odin:~1509` (ForStatement), `~1780` (ForIn), `~1808` (ForOf).
**Symptom**: **The tone.js family of SIGSEGVs** — deep inside class method
bodies with `for (let i = 0; ...)` loops.
**Root cause**: `(^Statement)(decl)` cast a `^VariableDeclaration` to
`^Statement` at the pointer level. The VariableDeclaration struct's bytes
were then dispatched via the Statement union tag — garbage dispatch.
**Fix**: extracted `print_variable_declaration_body` and emit the
VariableDeclaration inline, skipping the fake-Statement indirection.
**Regression fixture**: `tests/fixtures/regression/002_class_for_statement.js`.

### I-4 · ExportNamedDeclaration / ExportDefaultDeclaration cross-union cast

**Where**: `src/parser.odin:~2486` (parse) + `src/main.odin:~1649`, `~1702` (emit).
**Symptom**: Exported declarations emitted as `{"type": "Unknown"}`;
crashed when the Declaration in scope happened to dispatch to an invalid
Statement variant.
**Root cause**: `(^Declaration)(decl)` where `decl` is `^Statement`, and the
inverse `(^Statement)(decl)` where `decl` is `^Declaration`. The two unions
have different tag ordinals (7 Declaration variants, 25 Statement variants),
so the same pointer value decoded to different variants between the two
types.
**Fix** (parser): allocate a fresh `^Declaration` and assign the inner
variant so Odin computes the correct tag.
**Fix** (emit): `print_declaration_ast` type-switches on the Declaration
union, rebuilds a `Statement` on the stack via assignment (which produces
the correct Statement tag for the variant), and dispatches through
`print_statement_ast`.
**Regression fixture**: `tests/fixtures/regression/004_export_declarations.js`.

### I-5 · ClassBody JSON emit stub

**Where**: `src/main.odin:~1358` (ClassDeclaration), `~2459` (ClassExpression).
**Symptom**: All methods, fields, getters, setters, constructors, and static
blocks invisible to the JSON emitter; `"body": []` regardless of content.
**Fix**: `print_class_body_inline` + `print_class_element_fields` emit full
ESTree (`MethodDefinition` / `PropertyDefinition` / `StaticBlock`). Matches
OXC byte-for-byte on class element structure.
**Regression fixture**: `tests/fixtures/regression/005_class_body_full_emit.js`.

### I-6 · `direct_buf` fixed 20× source overflow

**Where**: `src/main.odin:62`.
**Symptom**: Bounds-check failure / SIGSEGV during JSON emission for
class-heavy files once the ClassBody stub was replaced with full emit.
**Root cause**: `direct_buf` was sized once at `len(source) * 20` bytes.
Pretty-mode expansion for full class bodies exceeds 20× source on some files.
**Fix**: `direct_reserve` grows the buffer by doubling before every
direct-mode write. Worker path also updated to free the current
(possibly-grown) buffer rather than the initial allocation.
**Regression fixture**: `tests/fixtures/regression/006_direct_buf_grow.js`.

## Regression Test Discipline

Every bug fixed this session is guarded by:

1. **Fixture** under `tests/fixtures/regression/` that triggers the bug
   before the fix. Checked into git.
2. **Expected JSON** under `tests/expected/regression/` (bit-exact output
   comparison via `run_tests.sh`). Checked into git.
3. **Structural check** in `tests/verify_regression.js` that compares the
   fixture's JSON against OXC along specific paths (e.g.
   `ForStatement.init.type == VariableDeclaration`). Strictly stronger
   than a flat type-count because bugs often preserve the type NAME while
   dispatching through the wrong node.

New runner: `task test:regression`. Wire it into CI alongside `task test:unit`.

Each regression check has been **validated by revert**: reverting the
specific fix in isolation causes the corresponding check to fail. Proof
that the checks actually guard the fix and not something tangential.

## What To Work On Next

Priority order, concrete tasks.

### P1 · Fix the 12 new SIGSEGVs · **high** · no deps

Most likely another Bug-H-class pointer cast that's only reached via deep
class method content. Start by greppng for remaining suspicious casts:

```
grep -rn 'transmute\|(\^Statement)(\|(\^Declaration)(\|(\^Expression)(' src/parser.odin src/main.odin
```

Every hit is a candidate. Attach lldb to the crashing process on tone.js —
the `get_statement_type_name + 88` crash reliably reproduces, and the stack
always walks back through `print_class_body_inline`. Add a structural
regression check to `tests/verify_regression.js` per fix, validated by
revert.

### P2 · `verify_raw_deep.js` full-tree walker · medium · unblocked by P1 completion

The walker was previously limited because there was nothing to walk on the
JSON side of classes. Now that ClassBody emits fully, extend the walker to
descend into MethodDefinition.value, PropertyDefinition.value,
StaticBlock.body, and ArrowFunctionExpression.body (both Expression and
BlockStatement variants).

### P3 · Template-literal escape cooking · medium

Same bug class as Bug E, but in the template path. Touches
`src/lexer.odin` — `lex_template`, `lex_template_resume`.
Add `tests/fixtures/edge/template_escapes.js`.

### P4 · T4 — eliminate the rewrite pass · high · no deps · largest scope

Parser allocates native pointers, then `raw_transfer.odin` rewrites them to
u32 offsets. If the parser wrote offsets directly, we skip a full AST walk.
Requires a design pass first.

### P5 · Investigate 28 pre-existing parse failures · high · not a quick fix

Previously P5 in the last handoff; still queued. `vue.global.js` +
`batch3/tinymce.js` still account for ~90 of the total errors.

## Commands Reference

All verified in this session.

```bash
# Build
task build                                    # release binary → bin/kessel
task build:debug                              # with bounds checks + dSYM (symbols incomplete on macOS, but traps on OOB)

# Test
task test:unit                                # 93 fixtures, ~1s
task test:regression                          # 6 structural regression checks vs OXC, ~2s
task test:real                                # 467 real files, ~3-5min (40 failures: 28 parse errors + 12 SIGSEGVs)
node tests/verify_raw.js <file>               # smoke raw-transfer binary
node tests/verify_raw_deep.js <file>          # OXC-cross-ref (shallow walker)
node tests/verify_string_escapes.js <file>    # OXC-cross-ref (string-escape deep walk)
node tests/verify_regression.js               # standalone regression runner

# Bench
task bench:quick                              # 10 files vs OXC, 30 iters, ~1min
task bench                                    # all 467 files, ~5min

# Run
./bin/kessel parse <file>                     # pretty JSON AST + stats to stderr
./bin/kessel parse <file> --compact           # single-line JSON (for verifiers)
./bin/kessel parse <files...> --workers N     # multi-file parallel
./bin/kessel raw <file> --out <path>          # zero-copy binary AST
./bin/kessel microbench parse <file> --iterations N   # min/mean/p95 latency
```

## Session log — what changed

| Area | Change |
|---|---|
| P1 feature | ClassBody JSON emit full (MethodDefinition / PropertyDefinition / StaticBlock). |
| Bug fixes | 4 Bug-H-class transmute sites (I-1, I-2, I-3, I-4). |
| Buffer growth | `direct_buf` grows on demand via `direct_reserve`; worker free-path fixed. |
| Testing | `task test:regression` + 6 fixtures + 6 expected files + `verify_regression.js` (194 LOC). |
| Taskfile | `test:real` now honestly reports crashes (previously masked by `${errs:-0}`). |

## What a fresh agent should do first

1. `task build && task test:unit && task test:regression` → all three clean in <5 s.
2. Read `AGENTS.md` (TigerStyle) and this file in full.
3. **Pick P1 (fix the 12 SIGSEGVs)** from §What To Work On Next. The stack
   trace is reproducible, the bug class is known (Bug-H-style cross-union
   cast), and every new fix MUST add a regression fixture validated by
   revert. Do not commit a fix without a regression test.
4. When completing any fix, update `tests/verify_regression.js` with a
   path-based check that fails on the pre-fix code. Flat type-count checks
   are insufficient — they gave false "OK" signals this session until
   tightened to path-specific assertions.
5. Never push forward past a failing `task test:unit` or `task test:regression`.
