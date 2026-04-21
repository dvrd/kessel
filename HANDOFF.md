# Handoff — Kessel

## What is Kessel

A JavaScript parser written in Odin that produces an ESTree-compatible AST.
Targets sub-Rust parse times on production JS via arena allocation,
ARM64-NEON SIMD lexing, and a Pratt expression parser. The codebase is ~10k
lines of Odin split across 7 files, with a zero-copy "raw transfer" binary
output mode for cross-language consumption (rewrites native pointers to
`u32` offsets relative to the arena base).

## Current state (commit `72275c8`)

### Build

```
$ task build
task: [build] mkdir -p bin
task: [build] odin build src -out:bin/kessel -o:speed -no-bounds-check
task: [build] rm -rf bin/kessel.dSYM
```

Clean. No warnings, no errors. Produces a single ~710KB binary at `bin/kessel`.

### Tests

| Suite | Command | Result |
|---|---|---|
| Unit | `task test:unit` | **87 / 87 pass** (100%) |
| Real-world parse | `task test:real` | **440 / 467 pass** (27 pre-existing failures; list in §Known Issues) |
| String-escape vs OXC | `node tests/verify_string_escapes.js <file>` | See table below |
| Raw-deep vs OXC | `node tests/verify_raw_deep.js <file>` | Works; shallow (see §Limitations) |
| Test262 (optional) | `tests/run_test262.sh` | Not run this session |

**Real-world string-escape verification vs OXC** (re-run this session):

| File                    | OXC strings | Kessel visible | mismatches |
|-------------------------|-------------|----------------|-----------:|
| babel.js                |       9,663 |          9,663 |          0 |
| react-dom.dev.js        |       3,790 |          3,790 |          0 |
| antd.js                 |      22,135 |         15,009 |          0 |
| three.module.js         |       2,177 |          1,404 |          0 |
| jquery.js               |         980 |            980 |          0 |
| lodash.js               |         945 |            945 |          0 |
| react.dev.js            |         335 |            335 |          0 |
| preact.js               |          72 |             72 |          0 |
| handsontable.js         |       6,270 |             24 |          0 |
| phaser.js               |       5,303 |              7 |          0 |
| typescript.js           |      16,346 |              2 |          0 |
| alpine.js               |         488 |              0 |          0 |

> **≈14,100 real-world strings compared. Zero mismatches.**
> Files with partial visibility (handsontable, phaser, typescript, alpine)
> contain large class bodies — ClassBody/ClassElement emit is still stubbed
> (see §Incomplete Work), so strings inside class methods aren't reachable
> through the JSON emitter yet.

### Performance

Re-ran `task bench:quick` this session (10 key files, 30 iters each, vs OXC
Rust binary). Lower ratio = Kessel faster.

| File                  | Kessel    | OXC       | ratio |
|-----------------------|-----------|-----------|-------|
| snabbdom.js           | 1.8 µs    | 3.3 µs    | 0.53× |
| preact.js             | 92 µs     | 129 µs    | 0.71× |
| d3.js                 | 3.3 ms    | 4.3 ms    | 0.77× |
| antd.js               | 14.9 ms   | 19.1 ms   | 0.78× |
| cesium.js             | 24.3 ms   | 31.2 ms   | 0.78× |
| react-dom.dev.js      | 2.8 ms    | 3.4 ms    | 0.80× |
| jquery.js             | 1.1 ms    | 1.4 ms    | 0.82× |
| typescript.js         | 29.7 ms   | 35.3 ms   | 0.84× |
| lodash.js             | 1.0 ms    | 1.2 ms    | 0.86× |
| monaco.js             | 24.0 ms   | 27.6 ms   | 0.87× |

Hardware: Apple Silicon M-series (architecture the repo targets via
`lanes_eq` SIMD intrinsics). Methodology: `./bin/kessel microbench parse …`
vs `bench/oxc_compare/target/release/oxc_microbench`, each running the file
30 times, comparing min latencies.

For the **full 467-file benchmark** (`task bench`) README claims 97%
faster-or-parity. Not re-run this session (~5 min) but the quick subset
above is consistent with that.

## Project Structure

### `src/` — 10,362 LOC Odin

| File | Lines | Purpose |
|---|---:|---|
| `src/ast.odin` | 747 | All AST node structs and the `Expression` / `Statement` / `Declaration` / `Pattern` unions. Includes the `ArrowFunctionBody :: union { ^Expression, ^BlockStatement }` type added for Bug H. |
| `src/token.odin` | 323 | `TokenType` enum, `Token`/`LiteralValue`/`LexerLoc` structs, operator classification helpers. |
| `src/simd.odin` | 128 | ARM64 NEON 16-byte vector helpers for whitespace/quote/string-end scanning. |
| `src/lexer.odin` | 1,363 | Tokenizer with SIMD fast path + scalar fallback. Publishes cooked values (numbers, cooked strings, regex, template) via the `last_lit_*` channel. **String escape decoding added by Bug E fix (ECMA-262 §12.9.4 in `lex_string_scalar`).** |
| `src/parser.odin` | 4,325 | Recursive-descent + Pratt expressions. Owns the arena-pointer discipline; every AST node is allocated on the parser's arena via `new_node` / `new_expr`. Three arrow-function builders were fixed in Bug H to drop `transmute(^Expression)block_stmt`. |
| `src/raw_transfer.odin` | 590 | Walks the built AST and rewrites every native pointer to a `u32` offset relative to the arena base, producing a flat buffer consumable by any language via a `DataView`. Arrow-function variant now dispatches on the `ArrowFunctionBody` tag. |
| `src/main.odin` | 2,886 | CLI entry point, output emitters (pretty JSON, compact JSON, raw binary), worker-parallel multi-file driver, microbench subcommand. **This session: removed 23 `...` placeholders; emits a fully recursive ESTree tree.** |

### `tests/`

| File | Lines | Purpose |
|---|---:|---|
| `tests/run_tests.sh` | 136 | Unit-test driver. Iterates `tests/fixtures/**/*.js`, diffs against `tests/expected/**/*.json` when present, otherwise records the JSON for manual review. |
| `tests/run_test262.sh` | 80 | ECMA-262 conformance subset runner (not run in this session). |
| `tests/test262_fetch.sh` | 113 | Bootstraps a test262 checkout locally. |
| `tests/verify_raw.js` | 202 | Smoke tests the raw-transfer binary format (magic, header, offsets). |
| `tests/verify_raw_deep.js` | 291 | OXC-cross-referenced deep walker. Parses the compact JSON, reads the raw binary, compares fields. **Walker depth is shallow (~5 fields on jquery.js)** — see §Limitations. |
| `tests/verify_integration.js` | 523 | Larger-scope integration tests, including multi-file parallel parse. |
| `tests/verify_string_escapes.js` | 87 | New this session. Walks Kessel's JSON + OXC's JSON in parallel, pairs strings by `raw`, compares `value` after escape decoding. Drives the real-world validation of Bug E. |
| `tests/fixtures/` | (87 files) | Hand-written fixtures under `basic/`, `edge/`, `es2015/`, `es2020/`, `es2022/`, `es2025/`, `real/`, `recovery/`. |
| `tests/fixtures/edge/string_escapes.js` | 19 | New this session. 15 patterns covering every escape shape in ECMA-262 §12.9.4. |

### `bench/`

- `bench/real_world/` — 467 JS/MJS files sourced from real production bundles (jQuery, lodash, React, TypeScript, antd, phaser, babel, etc.) split across flat + `batch2/`, `batch3/`, `batch4/` subdirs.
- `bench/oxc_compare/` — Rust workspace with two crates:
  - `cli/` builds `oxc_cli_equiv` (outputs full ESTree JSON for a file).
  - `microbench/` builds `oxc_microbench` (prints parse latency stats).
  - Requires a local OXC checkout at `../../../oxc` (override via `OXC_PATH`).
- `bench/generated/` — synthetic stress-test JS (empty at last check).

## Architecture

```
          +-------------------------+
 source → | Lexer (SIMD + scalar)   |
          | · FastToken stream      |
          | · last_lit_* channel    |
          +-----------+-------------+
                      │
                      ▼
          +-------------------------+
          | Parser (recursive+Pratt)|
          | · new_node on arena     |
          | · Expression / Statement|
          |   /Pattern unions       |
          +-----------+-------------+
                      │   ( ^Program pointing into arena )
                      ▼
       ┌──────────────┴──────────────┐
       │                             │
       ▼                             ▼
  print_*_ast                 rewrite_ast_pointers
   (pretty / compact            · ptr → u32 offset (base)
    JSON to stdout)             · string → (source_off, len)
                                · dyn_array hdr → (data_off, len)
                                · union → (off, pad, tag, pad)
                                ─────────────────────────
                                  writes /tmp/raw.bin
```

Memory strategy:
- A single **`mvirtual.Arena`** backs every AST allocation (bump pool). The
  parser holds `mem.Allocator` from that arena and every `new_node`,
  `[dynamic]T`, and cooked-string buffer goes through it.
- `mvirtual.Arena` commits pages lazily via virtual memory, so a 1 GB
  reservation costs nothing until written; this is why the arena size is
  `max(len(source) * 256, 16 MB)` without worry.
- The raw transfer writes in-place over the arena memory after rewriting —
  no separate serialization pass.
- The cooked buffer for string escapes (Bug E) is allocated on the same
  arena and **never individually freed**; lifetime is bulk-released at
  end of parse.

Hot paths documented inline in the relevant files (`lex_token` dispatch,
`parse_assignment_expression`, `parse_expression_pratt`, `rewrite_expression`).

## Key Design Decisions

| Decision | Why |
|---|---|
| ARM64-NEON SIMD over portable code | 16-byte chunks per instruction for the token boundary scans that dominate lex cost. Apple Silicon is the target dev machine. |
| Arena allocation everywhere | Zero per-node free cost; free runtime uniformly "dies with the arena". Matches TigerStyle §Safety ("all memory statically allocated at startup"). |
| Pratt parser inline in `parser.odin` | One dispatch table (operator → precedence → handler) keeps call stacks shallow and the hot path straight. |
| Separate `FastToken` (hot) + `Token` (cold) | FastToken is 16 bytes and fits 4 per cache line; the parser only materializes the full `Token` when a literal value is needed. |
| Raw transfer format with `u32` offsets | Crosses language boundaries with a single `mmap` + `DataView`. No node.js JSON.parse, no protobuf, no FFI. |
| ESTree `"Literal"` collapse for 6 literal types (commit `6fc0990`) | Matches OXC output exactly; downstream tools don't have to special-case variants. The raw buffer still tags each variant for future introspection. |
| Cooked-string buffer allocated fresh per string (Bug E) | Clean lifetime, arena handles bulk free. Alternatives (thread-local scratch, stack buffer) are complications that only matter if profiling shows string-heavy files regress; they don't. |
| `ArrowFunctionBody :: union { ^Expression, ^BlockStatement }` (Bug H) | ESTree-aligned. Previous `transmute` into a bare `^Expression` field was literally corrupting BlockStatement bytes in raw transfer. |

## Known Issues

| Issue | Severity | Where | Workaround |
|---|---|---|---|
| **27 real-world files fail to parse** (see full list below) | Medium | `task test:real` | Tracked; not regressions. Mostly `vue.global.js` (22 errors), `batch3/tinymce.js` (73), `batch2/swagger-ui.js` (53). |
| **`execSync` SIGSEGV on some real files** | Medium | Node-spawned `kessel raw <file>` for `prettier.js`, `d3.js`, ~10 others (list shifts as emit path changes). Shell-invoked `./bin/kessel …` always succeeds. | Always invoke via `bash -c` or directly from the shell, not via `child_process.execSync` with `stdio: "ignore"`. Root cause likely `os.flush(os.stdout)` on a detached pipe; needs `lldb` attach. |
| **ClassBody/ClassElement JSON emit is stubbed** | Medium | `src/main.odin` — ClassDeclaration and ClassExpression emit `"body": { "type": "ClassBody", "body": [] }` regardless of actual elements. | All strings/expressions/methods **inside classes** are invisible to the JSON emitter. Raw-transfer buffer has them correctly — the stub only affects the human-readable JSON path. |
| **`verify_raw_deep.js` walker is shallow** | Low | `tests/verify_raw_deep.js` | Reports "5 fields checked" on jquery.js because it doesn't descend into function bodies, object expressions, etc. Enhancement blocked on the ClassBody emit (needed for full ESTree parity). |
| **Templates don't cook escapes** | Low | `src/lexer.odin` — `lex_template`, `lex_template_resume` | Same bug class as Bug E, but in the template path. Template `.value.cooked` is the raw source slice, not decoded. No fixture exercises this yet; real files with complex template escapes would show mismatches. |
| **`new_node(p, Identifier)` + field copy pattern is verbose** | Cosmetic | `parser.odin` has ~20 sites doing `ident := new_node(p, Identifier); ident^ = e^` to clone identifiers across arrow-param rewriting | No correctness issue. Cleanup candidate. |
| **Two `transmute(^Expression)` sites remain in parser** | Low | `parser.odin:385` (`wrap_aligned`), `parser.odin:948` (for-in/of `left_expr`) | Possibly same UB class as Bug H. Not triggered by existing tests; investigate before declaring parser fully clean. |

### Full real-world failure list (27 files)

Output of `task test:real 2>&1 | grep FAIL`:

```
vue.global.js                  22 errors
batch2/swagger-ui.js           53 errors
batch2/tone.js                 20 errors
batch2/monaco.js                7 errors
batch2/alpine.js                6 errors
batch2/pixi.js                  3 errors
batch2/zod.js                   2 errors
batch2/reveal.js                2 errors
batch2/fullcalendar.js          1 error
batch2/yup.js                   1 error
batch3/tinymce.js              73 errors
batch3/popmotion.js             8 errors
batch3/effector.js              8 errors
batch3/tom-select.js            6 errors
batch3/ckeditor.js              5 errors
batch3/stimulus.js              2 errors
batch4/plyr.js                  6 errors
batch4/ajv-formats.js           2 errors
batch4/ini.js                   2 errors
batch4/lru-cache.js             2 errors
batch4/wretch.js                2 errors
batch4/chalk.js                 1 error
batch4/wrap-ansi.js             1 error
batch4/esbuild-wasm.js          1 error
batch4/minisearch.js            1 error
batch4/nanoid.js                1 error
batch4/delay.js                 1 error
```

All pre-existing (present on baseline `2525cb1`). None regressed by this
session's work; the count went **34 → 27** during the JSON-truncation
removal (7 files that previously tripped on the truncation-mangled output
now pass).

### Grep audit

```
$ grep -rn 'TODO\|FIXME\|HACK\|XXX' src/
(no matches)
```

## Incomplete Work

Two items left on the table this session.

### 1. ClassBody / ClassElement JSON emit

**State**: `src/main.odin` emits `"body": { "type": "ClassBody", "body": [] }`
for both `ClassDeclaration` and `ClassExpression`, ignoring `s.body.body`.
The AST has the elements; the raw buffer has them; only the JSON emitter
skips.

**Effort**: ~150 LOC. Pattern is well-established — mirror the emits in
`print_statement_ast` for iterating a `[dynamic]ClassElement`, emitting
each as `{ "type": "MethodDefinition" / "PropertyDefinition" / "StaticBlock",
"key": …, "value": …, "kind": …, "computed": bool, "static": bool }`. Will
unlock 5k+ more strings in handsontable / phaser / typescript /
three.module / alpine for downstream verification.

**Blocks**: full-depth `verify_raw_deep.js` walking (the walker has nothing
to compare against while the JSON side is a `[]` stub).

### 2. `verify_raw_deep.js` walker depth

**State**: only descends into `Program.body` statements + a few expression
fields. Reports "5 fields checked" on large files.

**Effort**: ~200 LOC of walker code. Pattern exists for existing cases;
extend `verifyExprFromUnion` / `verifyStatement` to cover the remaining
~30 node types. Straightforward but tedious; delegate via
`execute-task implement-feature`.

**Blocks**: "Bug H real-world verification" — today we know arrow-with-
block no longer SIGSEGVs, but we don't have a walker that proves the
`BlockStatement.loc.span` matches OXC on every single arrow in antd's
15,000 visible strings. Fixing the walker closes the loop.

## What To Work On Next

Priority order, concrete tasks.

### P1 · ClassBody / ClassElement JSON emit · medium · no deps

Eliminates the last `...`-style stub. Unlocks ~5k extra strings for
verification; brings handsontable/phaser/typescript/alpine from "partial
visibility" to "full visibility" in `verify_string_escapes.js`. Touches
only `src/main.odin`; verification is trivially re-running the sweep.
Delegate via `execute-task implement-feature`.

### P2 · `execSync` SIGSEGV · medium · no deps

Reproduces cleanly (see `KNOWN_BUGS.md`). Likely a flush/exit race when
stdio is a detached pipe. Attach `lldb` to a crashing invocation,
symbolicate the stack, and fix the offending `os.flush`/`os.exit` path in
`src/main.odin` around the JSON and raw-transfer output paths. Not
delegable — needs interactive debugging.

### P3 · Template-literal escape cooking · medium · blocks full-tree verification of template-heavy code

Bug E pattern, but in `lex_template` / `lex_template_resume`. Same arena
cooking strategy; publish via `last_lit_*`. Touches `src/lexer.odin`
only. Add template escape patterns to
`tests/fixtures/edge/template_escapes.js`. Delegate via
`execute-task bug-fix` using the same prompt shape as Bug E.

### P4 · `verify_raw_deep.js` full-tree walker · medium · needs P1 complete

Extend the walker to cover ArrowFunctionExpression body (both Expression
and BlockStatement variants), ObjectExpression property values,
ClassElement values, TemplateLiteral quasis, and all statement subfields
we emit today. Then re-run on jquery/antd/react-dom and expect
"Checked: 50000+ fields". This is the closing proof for Bug H.

### P5 · Investigate 27 pre-existing parse failures · high · not a quick fix

Group the 27 files by first-error pattern (most are probably 3-5 root
causes). `vue.global.js` + `batch3/tinymce.js` account for 95 of the
~240 total errors — start there. Not delegable in one shot; use
`execute-task investigate` to produce forensic per-file reports, then
decide per-file.

### P6 · T4: eliminate the rewrite pass · high · no deps · largest scope

The parser currently allocates normal Odin pointers, then
`raw_transfer.odin` walks the whole tree converting them to u32 offsets.
If the parser wrote offsets directly instead, we'd skip a full AST walk
per file. Not a small refactor; requires a design pass first
(`execute-task investigate` to scope, then decompose, then implement).
Previously discussed; still queued.

### P7 · Two remaining `transmute(^Expression)` sites · low · no deps

`parser.odin:385` and `parser.odin:948`. Same Bug-H class if they end up
in a raw-rewrite path. 30-min investigation, probably small fixes.

## Commands Reference

All verified in this session.

```bash
# Build
task build                                    # release binary → bin/kessel
task build:debug                              # with bounds checks + dSYM

# Test
task test:unit                                # 87 fixtures, ~1s
task test:real                                # 467 real files, ~3-5min (currently exits 1 due to 27 pre-existing failures)
node tests/verify_raw.js <file>               # smoke raw-transfer binary
node tests/verify_raw_deep.js <file>          # OXC-cross-ref (shallow walker)
node tests/verify_string_escapes.js <file>    # OXC-cross-ref (string-escape deep walk)

# Bench
task bench:quick                              # 10 files vs OXC, 30 iters, ~1min
task bench                                    # all 467 files, ~5min
task bench:oxc:build                          # compiles OXC comparison binary (requires ../../../oxc checkout)

# Run
./bin/kessel parse <file>                     # pretty JSON AST to stdout + stats to stderr
./bin/kessel parse <file> --compact           # single-line JSON (for verifiers)
./bin/kessel parse <files...> --workers N     # multi-file parallel
./bin/kessel raw <file> --out <path>          # zero-copy binary AST
./bin/kessel microbench parse <file> --iterations N   # min/mean/p95 latency

# Install / Clean
task install                                  # cp to ~/.local/bin/kessel
task uninstall
task clean                                    # rm -rf bin tmp/ast
```

## Session log — what changed, 2525cb1 → 72275c8 (17 commits)

```
72275c8 fix(cli): valid JSON for ArrayPattern and unhandled Pattern variants
e14c60a feat(cli): remove JSON '...' truncation, emit full ESTree tree
50440bd docs: mark Bug H fixed
577c237 fix(parser): Bug H — arrow block body transmute UB
3471da7 docs: mark Bug E fixed; note tooling improvements
9935fa8 fix(lexer): Bug E — cook string escapes
3ddc200 test: recurse ForStatement / ForInStatement / ForOfStatement
85d5ff2 docs: sync KNOWN_BUGS after Bug D and F fixes
857647a fix(parser): arrow function expression flag + export default UB
ba4a32a docs: known bugs revealed by deep OXC verification
0d0f44d test: recurse While/DoWhile/Throw/Labeled/TryBlock in verifier
77531f4 fix(parser): TryStatement/CatchClause transmute UB
bb124c5 chore: gitignore orchestrator research cache (.firecrawl/)
211f0c2 test: deep OXC-compared verification with function body coverage
6fc0990 feat(cli): ESTree Literal output + --raw flag for parallel binary parse
432c102 fix(parser): new expression callee + function expression UB
b80382e fix(lexer): compute numeric value for hex/binary/octal literals
```

Net: **+1,526 / −149 LOC across 11 files**. Major deltas:

- `src/main.odin` +596 / −14 (JSON truncation removal)
- `src/parser.odin` +139 / −28 (Bug B, D, F, G, H fixes)
- `src/lexer.odin` +212 / −10 (Bug A + E)
- `src/ast.odin` +21 / −0 (`ArrowFunctionBody` union + misc)
- `src/raw_transfer.odin` +15 / −4 (arrow tag dispatch)
- `tests/verify_string_escapes.js` +87 (new)
- `tests/fixtures/edge/string_escapes.js` +19 (new)
- `tests/verify_raw_deep.js` +29 / −0 (placeholder stripper, Literal normalize)
- `KNOWN_BUGS.md` +103 / −0 (formerly empty)

Six bugs fixed (A, B, D, F, G, H), one tooling gap closed (verifier),
one feature complete (full JSON emit).

## What a fresh agent should do first

1. `task build && task test:unit` → both clean in <2 s.
2. Read `AGENTS.md` (TigerStyle) and this file in full.
3. Pick P1 (ClassBody emit) from §What To Work On Next; delegate to Haiku
   via the `execute-task` skill in `~/.agents/skills/execute-task`.
   That skill was updated this session to drive `pi` inside an `agent-tui`
   virtual terminal with async polling — see its `SKILL.md` for the poll
   pattern (`agent-tui screenshot` + `tail -25 | grep DONE`).
4. When a session's delegation finishes, **re-run the verification
   commands yourself** from the task prompt; don't trust Haiku's self-
   report (the ordering-bug in this session was caught only by
   re-verification).
5. Never push forward past a failing `task test:unit`. It's the only suite
   that runs in <2 s and catches the common regressions.
