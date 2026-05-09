# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript/TypeScript/JSX/TSX parser written in Odin that emits
ESTree-compatible JSON ASTs. Targets ES2015–ES2025, zero runtime
dependencies, arena-only memory, ARM64 NEON SIMD lexing, hand-written
Pratt expression parser. Three-pass pipeline: SIMD lexer → permissive
Pratt parser → opt-in semantic checker. Mirrors OXC's `oxc_parser` /
`oxc_semantic` architecture: parser builds the tree, checker validates
ECMA-262 early errors. Conformance is measured against OXC on the same
50K+ fixture corpus (Test262 + Babel + TypeScript + ESTree + misc).

## Current State

### Build

```
$ task build
task: [build] mkdir -p bin
task: [build] odin build src -out:bin/kessel -o:speed -no-bounds-check
task: [build] rm -rf bin/kessel.dSYM
```

Build succeeds, no warnings. Toolchain: Odin `dev-2026-04:df6fff6e4`,
Apple M1 Max, Darwin arm64.

### Tests

`task test` (primary gate — coverage harness + 291 unit fixtures):
- Coverage harness: `Finished 24 tests in 5.6s. All tests were successful.`
- Unit fixtures: `Passed: 291  Failed: 0  Pass rate: 100%  Time: 8s`

`task test:bench:regression` (perf gate, 10 curated files):
- All 10 within tolerance. Geo-mean ratio **1.015** (tolerance 1.050).
- lodash.js settled at **1.086x** of baseline (was 1.103x in the prior
  handoff). Within the per-file threshold; no re-baseline required.
  Other files improved.

Conformance summary (from `task test:conformance:report`):

| Suite | Parser pos | Parser neg | Semantic pos | Semantic neg |
|---|---|---|---|---|
| **test262** | 47084/47090 (99.99%) | 4563/4588 (99.46%) | 47084/47090 | **4588/4588 (100%)** |
| **Babel** | 2219/2233 (99.37%) | 1588/1711 (92.81%) | **2212/2233 (99.06%)** | **1645/1711 (96.14%)** |
| **TypeScript** | 12684/12692 (99.94%) | 1598/3470 (46.05%) | **12638/12692 (99.57%)** | **1685/3470 (48.56%)** |
| **ESTree** | 39/39 (100%) | — | 39/39 | — |
| **misc** | 64/66 (96.97%) | 252/277 (90.97%) | 61/66 (92.42%) | 264/277 (95.31%) |

Snap baselines pinned to OXC SHAs: `c543b031` (babel),
`e4104a13` (estree), `c7a0ae10` (typescript).

### Session 3 progress

Landed on top of session 2 (commit `d515d40`):

- **TS overload-chain + decl-merge in nested scopes** (commit
  `56df254`). One slice; both checks now thread through a new
  per-scope helper `ck_check_ts_body_decls`:
  - **Top-level / nested-scope FunctionDeclaration overload-chain
    (TS2391 / TS2389)** — same algorithm as session 2's class
    version, applied to a Statement list. Catches
    `function foo(); function bar() {}` (TS2389), block-scope
    `{ function foo(); function bar(){} }` (FunctionDeclaration6.ts),
    namespace-scope `namespace M { function foo(); function bar(){} }`
    (FunctionDeclaration7.ts). Conservative pre-pass mirrors the
    class one: skip when NO function in the scope has an impl body,
    so sig-only ambient files like babel's
    `typescript/function/overloads/input.ts` stay clean (matches
    oxc-semantic, even though tsc would TS2391).
  - **Decl-merge (TS2300 / TS2567) in nested scopes** — session 2's
    check ran only at Program top level. Now also fires inside
    BlockStatement, FunctionExpression, and TSModuleBlock
    (namespace) bodies. Same algorithm, same merge-pair table.
  - **TSModuleDeclaration walking** — formerly a no-op in
    `ck_walk_stmt`. Now descends through both shapes the parser
    produces (`namespace M { ... }` → TSModuleBlock,
    `namespace A.B { ... }` → nested TSModuleDeclaration). Pushes
    `is_dts` for `declare namespace`, sets `at_top_level = true`,
    increments new `ts_namespace_depth` field.
  - **`ts_namespace_depth` flag** suppresses
    `ck_check_import_export_position` inside namespace bodies
    (`namespace M { export var x = 1; }` is legal in a Script,
    matching TS / oxc).
  - **Two collateral ambient-context fixes** the new walker exposed:
    - `ck_walk_function` skips strict-mode function-name check when
      `fn.declare`, `fn.no_body`, or `ctx.is_dts` (`declare function
      eval();` and ambient sigs are type-level signatures).
    - `ck_walk_var_decl` skips strict-mode binding-id check when
      `decl.declare` or `ctx.is_dts` (`export declare namespace Foo
      { export var static: any; }` no longer false-positives).
  - Net: **+1 babel positive, +2 babel positive (collateral) =
    +2 babel positive, +1 TS positive, +12 TS negative**. Five new
    misc lock-in fixtures (3 fail + 2 pass). Zero false positives,
    test262 holds at 100%.

### Session 2 progress

Landed on top of session 1's already-committed work:

- **TS declaration-merge dup detection (TS2300 / TS2567)** — new
  `ck_check_ts_decl_merge_body` in `src/checker.odin`. Catches
  illegal pairs like `class C; class C`, `class C; var C`, `enum E;
  function E`. Honours TypeScript declaration-merging rules
  (namespace + class, function + namespace, interface + interface,
  etc.) and ambient (`declare`) relaxation (`declare class C +
  declare function C` is the callable-class pattern). V1 covered
  Program top-level only; session 3 extended to nested scopes.
  Net: +11 babel, +18 TS.
- **TS class method overload-chain checks (TS2391 / TS2389)** — new
  `ck_check_ts_class_overloads` in `src/checker.odin`. Walks
  ClassBody members tracking the active overload-signature run;
  emits TS2391 on each unimplemented signature and TS2389 on impl
  name mismatch. Suppressed when class is `declare class`, when
  source is `.d.ts`, when method is optional or abstract, OR when
  the entire class has no method implementations.
  Net: +14 TS.
- Combined session 2: **+32 TS, +11 babel** semantic-negative gains.
  Test262 holds at 100%. Zero false positives.

### Performance

Bench numbers from `task test:bench:regression` end of session 3
(M1 Max, single-thread, microbench, 30 iterations):

| File | Baseline (us) | Current (us) | Ratio |
|---|---|---|---|
| snabbdom.js | 2.96 | 2.96 | 1.000 |
| preact.js | 120.83 | 121.92 | 1.009 |
| jquery.js | 1521.33 | 1514.25 | 0.995 |
| lodash.js | 1366.75 | 1484.00 | 1.086 |
| d3.js | 4875.13 | 5047.46 | 1.035 |
| react.dev.js | 410.96 | 428.71 | 1.043 |
| react-dom.dev.js | 4108.50 | 4094.75 | 0.997 |
| antd.js | 23045.67 | 23511.96 | 1.020 |
| monaco.js | 31537.58 | 30653.38 | 0.972 |
| typescript.js | 44908.38 | 44716.71 | 0.996 |
| (geo-mean across all 10) | — | — | **1.015** |

All within tolerance (per-file 10%, geo-mean 5%). The lodash
regression flagged in session 2 settled at 1.086x — inside the per-file
threshold, no re-baseline needed.

OXC-vs-kessel comparison is no longer the gating signal — see
AGENTS.md: "conformance has overtaken raw speed as the work-on-next
axis." `task test:fuzz` and `task test:release` exist for the full
zero-tolerance pre-release chain (~3 min).

## Project Structure

### `src/` — parser package (~41.5K LoC of Odin)

| File | Lines | Purpose |
|---|---:|---|
| `parser.odin` | 20076 | Hand-written Pratt parser. Permissive — builds AST without enforcing early errors. ~190 parsing procedures. Owns scope-clash detection, lex/var hoist tables, scope_check_body, scope_collect_pattern, scope_hoist_vars (used post-parse + by checker). Hot path. |
| `emitter.odin` | 6381 | ESTree JSON emitter. Owns writer buffer + UTF-16 + line-offset tables. 39 node printers. |
| `checker.odin` | 3309 | Pass-3 semantic checker. Walks the finished AST, enforces ECMA-262 early errors (break/continue context, label scoping, duplicate bindings, strict-mode restrictions). Mirrors OXC's `oxc_semantic`. Opt-in via `--show-semantic-errors`. |
| `lexer.odin` | 3097 | SIMD lexer. `Lexer` struct, two-token lookahead (`cur` + `nxt`). 16-byte FastToken by value. Cache-line-tuned hot fields. |
| `regex.odin` | 2235 | ES2025 §22.2.1 regex pattern validator. Decoupled from Lexer. |
| `ast.odin` | 1618 | All AST struct/union definitions. ESTree shape. |
| `raw_transfer.odin` | 1304 | Zero-copy binary AST buffer for cross-language consumption. |
| `main.odin` | 1295 | CLI dispatch + worker pool (`parse`, `lex`, `microbench`, `profile`). |
| `simd.odin` | 601 | ARM64 NEON intrinsics (Odin `core:simd`). |
| `parse_job.odin` | 433 | `ParseJob` — single "source-to-parsed-Program" deep module. Owns arena, lexer, parser, program, checker for one source. |
| `token.odin` | 383 | `TokenType` enum (~250 variants), `FastToken`, `LiteralValue`. |
| `unicode_tables.odin` | 329 | ID_Start / ID_Continue range tables. |
| `cli_config.odin` | 188 | `CliConfig` struct + shared `cli_try_parse_flag` (no globals). |
| `source_io.odin` | 103 | Cross-platform source reader. |
| `source_io_posix.odin` | 69 | mmap path. |
| `qos_darwin.odin` | 61 | Apple Silicon QoS P-core pinning. |
| `source_io_other.odin` | 17 | Non-POSIX fallback (read into buffer). |

### `tests/coverage/src/` — OXC-style conformance harness (~3.8K LoC)

| File | Lines | Purpose |
|---|---:|---|
| `typescript_constants.odin` | 582 | TS-specific compile-error code lookup tables. |
| `typescript.odin` | 457 | TypeScript corpus loader; multi-fixture splitter (`@filename:` directives), `resolve_ts_lang`, `resolve_ts_source_type`. |
| `babel.odin` | 447 | Babel corpus loader; plugin-merge from `options.json` chain, path/plugin skip lists from OXC verbatim. |
| `invariants.odin` | 366 | Post-parse AST invariants (I1..I6: source_type validity, etc.). |
| `main.odin` | 325 | Standalone harness binary entry point. |
| `snapshot.odin` | 248 | Snap rendering / diff against committed snap. |
| `test262.odin` | 247 | Test262 corpus loader; `flags: [module|onlyStrict|...]` parsing. |
| `coverage.odin` | 238 | Common types: `Fixture`, `TestResult`, `Suite`, `Tool`. |
| `coverage_test.odin` | 217 | `@(test)` procs for `core:testing` runner. |
| `runner.odin` | 190 | Single-fixture parse runner. Builds `ParseConfig`, opens job, runs parser (and checker if `tool == .Semantic`). |
| `classifier_test.odin` | 140 | Sanity tests for the per-fixture classifier. |
| `load.odin` | 138 | Suite dispatch: `load_<suite>` returns `[]Fixture`. |
| `misc.odin` | 121 | misc-corpus loader (`tests/coverage/misc/{pass,fail}/`). |
| `estree.odin` | 53 | ESTree conformance corpus loader. |

## Architecture

```
                     CLI (main.odin)
                          │
                          ▼
                 ┌────────────────┐
                 │   ParseJob     │  parse_job.odin
                 │ (arena + lang) │  Owns 1 mvirtual.Arena, lexer, parser
                 └───────┬────────┘
                         │
        ┌────────────────┼─────────────────┐
        │                │                 │
        ▼                ▼                 ▼
   ┌─────────┐     ┌─────────┐      ┌──────────┐
   │ Lexer   │ ──▶ │ Parser  │ ───▶ │ Checker  │ (opt-in)
   │ (SIMD)  │     │ (Pratt) │      │ (walker) │
   └─────────┘     └─────────┘      └──────────┘
   token stream    AST tree         Errors appended
   FastToken       Program node     to job.parser.errors
                          │
                          ▼
                   ┌──────────┐
                   │ Emitter  │ (only when ESTree JSON requested)
                   │ JSON OUT │
                   └──────────┘
```

**Memory strategy**: Every per-fixture parse runs against ONE
`mvirtual.Arena` allocated by `ParseJob`. AST nodes are `bump_append`
into that arena. No malloc/free during parsing. The arena is reset
between fixtures in batch mode (coverage harness, parallel parse).
Saved & restored across cross-fixture state via `scope_pending` is
**gone** — slice 14 removed it; each scope's lex/var clash check now
runs inline at parse-exit.

**Hot path**: `lex_token` (SIMD) → `advance_token` → `parse_*` (table-
driven Pratt). Cache-tuned fields in `Lexer` and `Parser` structs.
Hot loops live in stand-alone procs without `^Parser` for register
allocation (TigerStyle "extract hot loops").

**Key design decisions** (all per AGENTS.md):

| Decision | Why | Alternative considered |
|---|---|---|
| Permissive parser, separate checker | Mirror OXC architecture; lets the parser stay a pure tree builder | Inline early errors in parser (rejected — diverges from OXC) |
| Arena-only allocation | Predictable latency, zero free, fast bulk reset | malloc/GC (rejected — unbounded latency) |
| Two-token lookahead (`cur` + `nxt`) | Most JS productions need at most 1-token lookahead, but JSX / TS arrow disambiguation needs 2 | Snapshot/restore (rejected — slow) |
| ARM64 NEON SIMD lexer | 1.5–3× speedup on character classification & whitespace skip | Scalar lexer (rejected — measurable bench loss) |
| ESTree JSON shape | Matches OXC, Acorn, Babel for downstream tool compatibility | Custom shape (rejected — no tool consumes it) |

## Key Files To Read First

1. **AGENTS.md** — project guide + TigerStyle (mandatory before editing).
2. **src/parser.odin lines 1–900** — Parser struct, context flags
   (`in_async`, `in_generator`, `in_static_block`, `in_method`,
   `in_module_top_level`, `has_module_syntax`, `is_node_ts_module`,
   `is_commonjs`, etc.) and how they thread through parsing.
3. **src/parse_job.odin** — How a single source becomes a parsed
   Program. `parse_job_open_inline` / `parse_job_open_file` /
   `parse_job_run` / `checker_run_for_job`.
4. **tests/coverage/src/runner.odin** — How a fixture becomes a
   `TestResult` (the snap shape).
5. **HANDOFF_TS.md** — TS conformance gap analysis (1521 checker gaps
   classified by category).

## Known Issues

| Issue | Severity | Where | Workaround |
|---|---|---|---|
| TS conformance negative pass at 48.6% | high (open work, not a bug) | `parser_typescript.snap` / `semantic_typescript.snap` | 1785 fixtures kessel doesn't reject that OXC does (down from 1872). **Per `HANDOFF_TS.md`: ~43 are parser-side, the rest are semantic checks the checker doesn't implement.** Work belongs in `src/checker.odin`. See "What To Work On Next" §1. |
| Babel parser-side gap: 14 invalid-pattern fixtures + 4 JSX-in-JS | medium | `parser_babel.snap` | (a) Invalid-pattern fixtures (`[(a=1)] = t`, etc.) need pattern-element walker that distinguishes parenthesized AssignmentExpression from default-value AssignmentExpression — kessel's `last_paren_expr` mechanism only tracks the most recent. (b) JSX-in-JS-without-plugin (`<>Hello</>` in `.js`) — kessel ALWAYS allows JSX in `.js` files; OXC requires explicit `jsx` plugin. Design choice; accept or change harness default. |
| 8 misc parser-side TS rules | medium | `parser_misc.snap` | `oxc-10503` (using ASI), `oxc-11485` (decorators on params), `oxc-11592-3` reverted, `oxc-11713-23` (readonly on call sig), `oxc-1942-{1,2}` (get x: () instead of get x()), `oxc-5177` fixed but check is partial, `html-comment-with-esm.js`. Each needs targeted parser rule. |
| 25 test262 parser snap "Expect Syntax Error" | accepted | `parser_test262.snap` | All 25 are checker-caught (semantic snap = 100%). Per OXC architecture they're checker rules; the parser snap counts them only because `should_fail` is metadata-classified, not because OXC's parser rejects them. Don't move to parser. |
| Function expression body now required (no overload) | feature | `parse_function_declaration` line 3938 | This session: `allow_no_body_here = !is_expr && (allow_no_body || in_ambient || allow_ts_mode)`. If you find a real-world TS file using overload-like function EXPRESSION syntax (rare), revisit. |
| `.cts` files now classified as Module by harness | feature | `tests/coverage/src/typescript.odin` `resolve_ts_source_type` | TS allows ESM `export` in `.cts` (compiles to CJS). Match OXC. |
| `.jsx` files in TS corpus now JSX (not TSX) | feature | same file, `resolve_ts_lang` | OXC distinguishes `.jsx` (no TS types) from `.tsx`. We now match. |

No `TODO` / `FIXME` / `HACK` markers in `src/` or `tests/coverage/src/`
(checked with `grep -rn`).

## Incomplete Work

`git status`: clean. All session 3 work is committed.

`git stash list`: empty. No WIP commits.

## What To Work On Next

Numbered by impact-per-effort. Read AGENTS.md before starting any of
these.

### 1. Class-body member duplicate-name detection (TS2300)  (LOW-MEDIUM impact, MEDIUM effort)
- **What**: Detect duplicate member names within a class body —
  `class C { a(): number {return 0;}; a: number; }` reports TS2300.
- **Where**: `src/checker.odin` next to `ck_check_class_private_duplicates`
  (which handles `#x` private names only). Walk `cls.body.body` once,
  bucket by `(static, name)` (statics & instances live in different
  namespaces), and emit on duplicate. Carve-outs: getter+setter pair
  with same name is legal; method overload chain (already detected by
  `ck_check_ts_class_overloads`) is legal.
- **Why**: ~3-10 fixtures direct hit (`classWithDuplicateIdentifier.ts`
  family). Plus collateral on fixtures that mix this with other TS
  errors and only need one diagnostic to flip to passing.
- **Difficulty**: Medium (carve-outs for accessor pairs + overload
  chains require care).

### 2. TS2393 "Duplicate function implementation" cluster  (LOW impact, LOW effort)
- **What**: When a top-level scope has TWO `function foo() {}` (both
  with bodies, both not `declare`), report TS2393 on each. Different
  from TS2391/TS2389 (which fires when there's a sig+impl mismatch).
  Often co-fires with TS2300 (`var foo: string; function foo(): number {}`).
- **Where**: `src/checker.odin`, extend `ck_check_ts_func_overloads`
  or add a new sibling proc. Same per-scope sweep as the overload-
  chain.
- **Why**: ~29 fixtures. Many overlap with `controlFlowFunctionLikeCircular`
  family.
- **Difficulty**: Low. Same skeleton as the overload-chain check.

### 3. Implement remaining TS-specific semantic rules in `src/checker.odin`  (HIGH impact, MEDIUM-HIGH effort)
- **What**: Walk the finished AST and enforce TypeScript's static
  semantic rules. ~1500 fixtures still need work.
- **Where**: `src/checker.odin` — add new `ck_check_*` procs invoked
  from `ck_walk_stmt` / `ck_walk_expr` arms. Mirror existing pattern.
- **Why**: This is the single largest open gap. Per the cluster
  analysis script in session 3 (run `node cluster_specific.js <code>`
  in `tests/`):
  - **TS2304** (130 fixtures) — Cannot find name. Needs symbol-
    resolution; out of scope for the checker today.
  - **TS2300** (129 fixtures) — Duplicate identifier. Most are
    type-aware (e.g. interface property dups, enum member dups).
  - **TS6203** (101 fixtures) — Subsequent variable declarations must
    have the same type. Type-aware; out of scope.
  - **TS1005** (93 fixtures) — Syntax error: `,` / `;` expected.
    These are PARSER errors that TSC catches but kessel doesn't.
    Worth a one-off pass through `parser_typescript.snap`.
  - **TS2440** (45 fixtures) — Import declaration conflicts with
    local declaration. Doable in checker (both kinds visible).
  - **TS2391** (31 fixtures still missed) — Single-sig top-level
    `function foo();` cases that we skip due to the conservative
    pre-pass. Conscious tradeoff.
  - **TS2451** (47 fixtures) — Cannot redeclare block-scoped
    variable. Often fires in the `controlFlowFunctionLikeCircular`
    family (use-before-decl with const).
- **Difficulty**: Each rule is small. Start with TS2393 (#2 above)
  and TS2440.
- **Depends on**: Read `HANDOFF_TS.md` and re-run the cluster script
  for the live fixture list.

### 4. Fix the 14 babel parser-side gaps  (MEDIUM impact, MEDIUM-HIGH effort)
- **What**: 8 invalid-assignment-pattern fixtures + 2 arrow inner-paren
  + 4 JSX-in-JS-without-plugin.
- **Where**:
  - Pattern walker: `src/parser.odin` `validate_destructure_target` /
    `validate_pattern_element`. Need to thread parenthesization through
    the cover grammar differently — the current `last_paren_expr` only
    tracks the most-recent paren, which is insufficient when the
    paren is inside an array element.
  - JSX-in-JS: `tests/coverage/src/babel.odin` `resolve_babel_lang`.
    Either change kessel's default to NOT enable JSX in `.js`
    (matches Babel's plugin model but breaks plenty of other
    tests), or add per-fixture skip / mark these as accepted
    deviations.
- **Why**: Closes the bulk of the babel snap delta.
- **Difficulty**: Medium-high (cover-grammar reasoning is subtle).

### 5. Fix the 8 misc parser-side TS rules  (LOW-MEDIUM impact, LOW effort each)
- **What**: Listed in the prior session-2 HANDOFF. Each is a small,
  isolated rule.
- **Where**: `src/parser.odin` (each rule has an obvious site).
- **Difficulty**: Low each, ~15-30 min per rule.

### 6. Migrate any remaining JS parser-side fixtures  (LOW impact, LOW effort)
- **What**: 25 test262 parser snap entries. All are
  checker-caught — none should move. Just verify the classifier
  agrees (run `node` + `oxc-parser` per `HANDOFF_TS.md` recipe).
- **Where**: `parser_test262.snap`.
- **Why**: Confirm we're not leaving anything fixable on the parser
  side.

## Commands Reference

All tested in this session.

| Command | Purpose | Time |
|---|---|---|
| `task build` | Build release binary `bin/kessel` (`-o:speed -no-bounds-check`). | ~5–60s |
| `task build:debug` | Build debug binary (with bounds checks). | similar |
| `task build:coverage` | Build the standalone coverage harness `bin/kessel_coverage`. | ~30–120s |
| `task test` | **Primary gate.** Coverage snap (24 tests) + 291 unit fixtures. Fails on ANY snap drift or unit-fixture diff. | ~13s |
| `task test:quick` | Fast dev loop — unit + regression + invariants + lexer tokens. | ~8s |
| `task test:unit` | Just the 291 positive golden-output fixtures. | ~8s |
| `task test:coverage` | Just the snap suites. | ~5s |
| `task test:coverage:update` | Regenerate every snap baseline after a deliberate parser change. | ~5s |
| `bin/kessel_coverage run <suite> --parser \[--update\]` | Single-suite parser-only run. Suites: `test262 babel typescript estree misc all`. | ~1–10s |
| `bin/kessel_coverage run <suite> --semantic \[--update\]` | Single-suite parser+checker run. | ~1–10s |
| `task test:conformance:report` | Print conformance numbers from current snaps. | <1s |
| `task test:bench:regression` | 10-file perf regression gate (geo-mean tolerance 1.05). | ~60s |
| `task test:bench:regression:update` | Re-capture bench baseline after intentional perf work. | ~60s |
| `task test:release` | Zero-tolerance pre-release chain (~3 min). | ~3min |
| `bin/kessel parse <file> [--lang=js\|jsx\|ts\|tsx] [--source-type=script\|module]` | Parse and emit ESTree JSON. | per file |
| `bin/kessel lex <file>` | Tokenize and emit JSON token stream. | per file |
| `bin/kessel microbench parse <file> [--iterations N]` | Parse benchmark (default 100 iter). | per file |

### Classifier recipe (used to write `HANDOFF_TS.md`)

```bash
npm install oxc-parser   # one-time, captured in package.json
node -e "
const oxc = require('oxc-parser');
const fs = require('fs');
const path = require('path');
// (see HANDOFF_TS.md or commit history for the full classifier)
"
```

The npm `oxc-parser` package is the authoritative oracle for parser
behavior — pinned to the same OXC SHAs as our snap baselines. Use it
to determine whether a remaining 'Expect Syntax Error' is an OXC
parser rule or an OXC semantic rule.

---

## Verification

Before publishing the session 3 handoff I:

- ran `task build` — clean.
- ran `task test` — `Pass rate: 100%` (291/291).
- ran `task test:bench:regression` — all 10 files within tolerance,
  geo-mean 1.015 (tolerance 1.050).
- ran `task test:conformance:report` — captured the table above.
- ran the cluster script (`tests/cluster_specific.js` recipe in this
  doc) to enumerate the remaining checker gaps by TS error code.
- verified zero false positives: every snap line that left the snap
  was a real upgrade (kessel now reports a previously-missed
  diagnostic). Every snap line that entered the snap is in a positive
  fixture where kessel was already failing for an unrelated reason
  and the diagnostic shifted by one position.
