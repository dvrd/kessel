# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX / TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing. Mirrors OXC's `oxc_parser` / `oxc_semantic` split — parser builds the tree permissively, checker enforces ECMA-262 early errors.

## Current State (2026-05-13, session 10)

### Build
```
$ odin build src -out:bin/kessel -o:speed -no-bounds-check
```
Clean success. No warnings. Binary: `bin/kessel` (Mach-O arm64).  
Toolchain: `odin version dev-2026-04:df6fff6e4`, Apple M1 Max, Darwin arm64.

Coverage harness also builds clean:
```
$ odin build tests/coverage/src -out:bin/kessel_coverage -o:speed -no-bounds-check
```

### Tests
**Primary gate** (`task test`): **All pass.**
- Coverage harness: 24 tests. All successful.
- Unit fixtures: 291 passed, 0 failed, 100%.

### Conformance
```
ES2025 (test262):  Parser 47090/47090 (100.00%) | Semantic 47090/47090 (100.00%) + neg 4588/4588 (100%)
Babel:             Parser 2227/2233  (99.73%)  | Semantic 2216/2233 (99.24%) pos, 1677/1711 (98.01%) neg
TypeScript:        Parser 12661/12664 (99.98%) | Semantic 12650/12664 (99.89%) pos, 2088/3498 (59.69%) neg
ESTree:            Parser 39/39 (100%)         | Semantic 39/39 (100%)
Misc:              Parser 72/72 (100%)         | Semantic 71/72 pos, 280/286 (97.90%) neg
```

### Performance
Benchmark baseline re-locked at session-9 start (geo-mean ~1.01x).

## Project Structure

### `src/` — 45 149 LoC

| File | Lines | Purpose |
|---|---:|---|
| `parser.odin` | 20 185 | Hand-written Pratt parser. `Parser` struct, ~200 parsing procedures. Permissive — builds AST without early errors. |
| `emitter.odin` | 6 381 | ESTree JSON emitter. `Emitter` owns writer buffer + UTF-16 offset tables + line maps. 39 node printers. |
| `checker.odin` | 7 156 | Pass-3 semantic checker. Walks finished AST, enforces ECMA-262 + TS early errors. Opt-in via `--show-semantic-errors`. |
| `lexer.odin` | 3 118 | SIMD-accelerated tokenizer. Two-token lookahead (`cur` + `nxt`). 16-byte `FastToken` by value. |
| `regex.odin` | 2 235 | ES2025 §22.2.1 regex pattern validator. Decoupled from `Lexer`. |
| `ast.odin` | 1 618 | All AST struct/union definitions. `Expression`, `Statement`, `Pattern` unions. |
| `raw_transfer.odin` | 1 304 | Zero-copy binary AST buffer (experimental). |
| `main.odin` | 1 295 | CLI dispatch + worker pool. |
| `simd.odin` | 601 | ARM64 NEON intrinsics for lexer hot loop. |
| `parse_job.odin` | 433 | `ParseJob` — arena, lexer, parser, checker for one source. |
| `token.odin` | 383 | `TokenType` enum (130+ variants), `FastToken`, `LiteralValue`. |
| `unicode_tables.odin` | 329 | ID_Start / ID_Continue range tables. |
| `cli_config.odin` | 188 | `CliConfig` struct + `cli_try_parse_flag`. |
| `source_io.odin` | 103 | Cross-platform source reader. |
| `source_io_posix.odin` | 69 | POSIX mmap implementation. |
| `qos_darwin.odin` | 61 | Apple Silicon QoS P-core pinning. |
| `source_io_other.odin` | 17 | Fallback read for non-POSIX. |

### `tests/coverage/src/` — 3 802 LoC

| File | Lines | Purpose |
|---|---:|---|
| `typescript_constants.odin` | 588 | TS corpus skip lists + NOT_SUPPORTED_ERROR_CODES table. |
| `typescript.odin` | 484 | TS corpus loader, multi-fixture splitter, compiler options parser. |
| `babel.odin` | 447 | Babel corpus loader, plugin-merge, skip lists. |
| `invariants.odin` | 366 | AST structural integrity walker (informational gate). |
| `main.odin` | 325 | Standalone harness CLI. |
| `snapshot.odin` | 248 | Snap rendering + diff. |
| `test262.odin` | 247 | Test262 corpus loader. |
| `coverage.odin` | 238 | Fixture, TestResult, Suite, Tool types. |
| `coverage_test.odin` | 217 | 24 `@(test)` procs — 10 snap tests + invariants. |
| `runner.odin` | 190 | Single-fixture parse runner, classification. |
| `classifier_test.odin` | 140 | Classifier unit tests. |
| `load.odin` | 138 | Suite dispatch + filesystem walker. |
| `misc.odin` | 121 | Misc regression museum loader. |
| `estree.odin` | 53 | ESTree conformance corpus loader. |

## Architecture

```
CLI (main.odin)
     │
     ▼
ParseJob (parse_job.odin) — owns mvirtual.Arena, Lexer, Parser, Checker
     │
     ├─ Lexer (SIMD NEON) → token stream (FastToken by value)
     ├─ Parser (Pratt)     → Program AST (arena-allocated)
     ├─ Checker (opt-in)   → appends ParseError to parser.errors
     └─ Emitter            → ESTree JSON to stdout
```

**Memory**: All AST nodes bump-allocated from `mvirtual.Arena` in ParseJob. No malloc/free during parsing. Arena reset between fixtures.

**Key types**:
- `CheckerContext` — thread-local walker state: 25 fields tracking strict_mode, loop depth, switch depth, label scope, TS namespace depth, etc. (checker.odin lines 131–215).
- `Parser` — ~50 fields: lexer, allocator, flags, pending lists. (parser.odin ~line 300).
- `ParseConfig` — lang, source_type, force_strict, preserve_parens, source_is_dts. (parse_job.odin).
- `Expression :: union { 46 variants }`, `Statement :: union { 33 variants }`, `Pattern :: union { 6 variants }` (ast.odin).

## Key Design Decisions

| Decision | Why | Alternative |
|---|---|---|
| Permissive parser + separate checker | Mirrors OXC. Parser is pure tree builder. Checker is opt-in pass 3. | Inline early errors during parse (rejected — couples parsing decisions to error policy). |
| Arena-only allocation | Predictable latency, bulk reset, no use-after-free. | malloc/GC (rejected). |
| `__proto__` dup check in checker only | Parser can't distinguish ObjectExpression from ObjectPattern before conversion. Checker has `in_assignment_target` guard. | Pending-list approach in parser (was used before, removed in session 8). |
| `extends null` — derived but no super checks | `class X extends null`: `has_extends=true` (super() is valid) but `extends_null` flag suppresses TS2377/TS17009 (no base constructor). | Single flag approach (prior sessions). |
| Numeric property keys compared by f64 value | `0b11` and `3` are the same property. `.raw` comparison misses this. | Raw string comparison (incorrect for alternate bases). |
| Directive escape check | `'use\x20strict'` must NOT activate strict mode per §11.1.1. Check raw for backslash. | Compare decoded value only (spec-non-compliant). |

## Known Issues

| Issue | Severity | Where | Workaround |
|---|---|---|---|
| 16 TS semantic false positives ("Expect to Parse") | medium | topLevelAwait, node/allowJs patterns, jsdoc | Pre-existing; tracked in snap |
| 4 Babel semantic FPs (getter-setter, private-method-overload, etc.) | low | OXC/babel accept empty getters; private overload dup name | Accept as known |
| 1 misc semantic false positive (oxc-13284.ts) | low | TS2377 fires on nested-class edge case OXC skips | Accept as known |
| 6 Babel parser false positives | medium | `with` in sloppy mode, dup constructor with linebreaks, `await` in static block | Various parser-level issues |
| TS2667/TS2666 (imports in module augmentation) attempted S8, caused 11 FP | medium | Can't distinguish augmentation vs ambient module decl | Reverted; needs heuristic |
| TS1046 (.d.ts top-level declare/export) implemented but disabled | low | OXC doesn't enforce it; causes FP against babel/TS corpora | Code exists, commented out |
| Optional `?` on destructuring patterns not tracked in AST | low | Parser doesn't set `optional` for `[]?` / `{}?` patterns | Blocks TS1051 check |
| Type-system errors (TS2339 ×265, etc.) unfixable without type inference | high | Represents bulk of remaining ~1467 TS gaps | Requires type resolution infrastructure |

## Session 10 Changes (11 commits)

**Checker improvements (TS semantic negative: 2064→2088, +24):**
1. fix(checker): skip catch-var redecl in TS mode for simple identifiers. Fixes tryStatements.ts FP. TS positive: 12649→12650 (+1).
2. feat(checker): TS2300 — enum member dups (`enum E { x, y, x }`) + constructor param property vs class field conflicts. +2 negative.
3. feat(checker): TS2491 — destructuring pattern in for-in LHS. `for (var [a,b] in [])` now rejected in TS. +3 negative.
4. feat(checker): TS1221 — generators not allowed in ambient context. `declare function*` rejected. +3 negative.
5. feat(checker): TS1040 — async modifier not allowed in ambient context. `declare async function` rejected. +2 negative.
6. fix(checker): TS2448 — class static block bodies participate in use-before-decl. +1 negative.
7. feat(checker): TS2434 — instantiated namespace before class/function ordering check. Skips declare/ambient/augmentation patterns. +8 negative.
8. fix(checker): TS2448 — class static block bodies participate in use-before-decl. +1 negative.
9. fix(checker): allow new.target in class field initializers and static blocks. Added class_body_depth counter. Babel positive: +1.
10. fix(checker+parser): TS1016 — required parameter after ?-optional. Fixed parser bug where optional flag wasn't set on Identifier for ?-params. TS negative: +1.
11. feat(checker): TS2384 — overload signatures must all be ambient or non-ambient. +4 negative.

**Attempted and reverted:**
- TS2395 (merged decl export visibility): caused 16 FPs — interface+namespace merges don't require matching export status.
- TS2857 (import attributes on type imports): caused 9 FPs — TS resolution-mode attributes are legal on type imports.
- .cjs auto-detect: 7 FPs fixed but 5 regressions from CJS files auto-promoting to Module.
- Overload chain suppression: suppressing TS2391 on no-impl classes fixed 3 babel FPs but caused 15 TS regressions.

## Session 9 Changes (23 feature/fix commits)

**FP fixes (parser + semantic positives):**
1. fix(checker): export-local-defined — TSImportEquals, TS decls, type-only skip. +21 TS FP.
2. fix(parser): export-default-function overloads in TS mode. +5 parser, +3 semantic.
3. fix(checker): skip export-local-defined for TS/TSX entirely. +13 TS FP.
4. fix(checker): export-default dup check — skip overload sigs. +2 TS FP.
5. fix(parser): strict-reserved words in TS ambient context. +2 parser, +2 semantic.
6. fix(parser): `new (await expr)` — parenthesized await is valid. +1 test262, +1 TS.
7. fix(parser): `using` in for-loop init at script top level. +3 test262, +3 test262 semantic.
8. fix(checker): `extends null` — allow super(), suppress TS2377/TS17009. +1 test262.
9. fix(parser+checker): sloppy-mode FunctionDecl var-hoist (Annex B.3.2). **test262 100.00%**.

**New TS checks (semantic negatives):**
10. feat(checker): TS2391 — sig-only non-exported overloads. +12.
11. feat(checker): TS1038 — `declare` in already-ambient context. +10.
12. feat(checker): TS1036 — statements in ambient contexts. +17.
13. feat(checker): TS2378 — getter must return a value. +14.
14. feat(checker): TS2331 — `this` in namespace body. +6.
15. feat(checker): TS2428 — interface merge type-parameter mismatch. +5.
16. feat(checker): TS2374 — duplicate index signature for same type. +5.
17. feat(checker): TS2373 — forward references in parameter defaults. +3.
18. feat(checker): TS1268 — index sig param type validation. +2.
19. fix(checker): class overload pre-pass — non-method interleaving. +1.

**Net session 9 impact:**
- test262 parser: 47085 → **47090 (100.00%)** (+5)
- test262 semantic: 47084 → **47090 (100.00%)** (+6), negative 4588/4588 (100%)
- TS parser: 12653 → 12661 (+8, 99.98%)
- TS semantic positive: 12608 → 12649 (+41, 99.88%)
- TS semantic negative: 1994 → 2064 (+70, 59.01%)

## Incomplete Work

No uncommitted changes. No stashes. No WIP branches. 73 commits ahead of origin/main.

## What To Work On Next

### 1. Fix TS2667/TS2666 — imports/exports in module augmentations (~10 gaps)
**What**: `import {X} from "Y"` inside `declare module "..." {}` is TS2667 when the file is a module (augmentation), but valid when the file is a script or .d.ts (ambient declaration). Session 8 attempted and caused 11 FP.  
**Key insight**: May need to check if the module specifier is a relative path (augmentation) vs bare specifier (ambient).  
**Where**: `src/checker.odin` (ck_walk_ts_module_decl + statement handlers)  
**Difficulty**: medium-high

### 2. Scope analysis improvements (TS2300 — 29+ pure fixtures)
**What**: Duplicate identifier detection in namespace bodies, cross-declaration clashes, interface/class merge conflicts.  
**Where**: `src/checker.odin` scope analysis  
**Difficulty**: high

### 3. Fix Babel parser false positives (6 remaining)
- `with` in sloppy mode, dup constructor with linebreaks, `await` in static block  
**Where**: `src/parser.odin`  
**Difficulty**: varies (medium per item)

### 4. TS2384 — overload signatures must all be ambient or non-ambient (3 gaps)
**What**: `declare function foo();` followed by `function foo() {}` in different namespace parts — the overload chain checker needs to detect ambient/non-ambient mismatch.  
**Where**: `src/checker.odin` (ck_check_ts_func_overloads)  
**Difficulty**: medium

### 5. TS2428 — interface merge type-parameter mismatch (8 pure fixtures)
**What**: All declarations of interface 'X' must have identical type parameters.  
**Where**: `src/checker.odin` interface merge check  
**Difficulty**: medium

### 6. TS1206 — decorators not valid here (11 fixtures)
**What**: Decorator placement validation for TS-specific positions.  
**Where**: `src/checker.odin`  
**Difficulty**: medium

### 7. Type-aware bridge (long-term)
**What**: TS2339 (265 fixtures), TS2322, TS2304 require type inference. Even minimal type resolution (enum values, `typeof`, literal types) would close many gaps.  
**Where**: New module  
**Difficulty**: high (architectural)

## Commands Reference

All commands verified in this session on Apple M1 Max / Darwin arm64.

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s (cached), ~45s (cold) |
| `task build:coverage` | Coverage harness → `bin/kessel_coverage` | ~60s |
| `task test` | **Primary gate** — 24 coverage snap tests + 291 unit fixtures | ~12s |
| `task test:coverage` | Just coverage snap gate | ~7s |
| `task test:unit` | Just 291 golden-output fixtures | ~8s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `./bin/kessel_coverage run <suite> [--semantic] [--update]` | Run/update one snap (test262\|babel\|typescript\|estree\|misc) | ~0.2–1s |
| `task test:conformance:report` | Print conformance numbers from snaps | <1s |
| `task test:bench:regression` | 10-file perf gate (30 iterations each) | ~60s |
| `task test:bench:regression:update` | Accept current perf as new baseline | ~60s |
| `task test:release` | Zero-tolerance pre-release chain | ~3 min |
| `task test:oxc-corpus:fetch` | Fetch all OXC corpora (TS + Babel + ESTree) | ~2 min (network) |
| `task test:oxc-corpus:fetch:typescript` | Fetch only TS corpus (~150 MB) | ~1 min |
| `./bin/kessel parse <file> [--lang=ts] [--show-semantic-errors]` | Parse with optional checker | per file |

## Session 8 Commit Log (13 features)

```
505725f feat(checker): TS1319 — reject export default inside namespaces (+4)
36f699b fix(checker): compare numeric property keys by value, not raw text (+2)
b7b46e3 feat(checker): TS2408 — setters cannot return a value (+2)
c8f8cca fix(parser): don't treat escaped 'use strict' as directive (+5 FP fix)
d443086 feat(checker): reject `import type` on namespace import aliases (+1 TS, +1 Babel)
a5a4523 fix(parser): check source_is_dts for class field initializer in ambient (+1 Babel)
6978c5a feat(checker): reject TSExportAssignment in script source type (+1 Babel)
ef807d1 feat(checker): TS2377 — derived constructors must call super() (+8)
64b7990 refactor(parser): move __proto__ duplicate check to checker (+5 FP fix)
2ebe66d feat(checker): TS17009 — detect `this` before `super()` (+20)
affd43c feat(checker): TS2669 — reject `declare global` outside module (+12, +1 FP fix)
3e45ae6 feat(checker): TS1117/TS1118 — duplicate object literal properties (+9)
```

Net: TS semantic 1936→1994 (+58, 55.35%→57.00%). Babel semantic +3. 15 false positives fixed.
