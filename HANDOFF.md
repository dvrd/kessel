# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript/TypeScript/JSX/TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexer, hand-written Pratt expression parser. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Mirrors OXC's `oxc_parser` / `oxc_semantic` architecture.

## Current State (2026-05-11T17:00)

### Build
```bash
$ odin build src -out:bin/kessel -o:speed -no-bounds-check
```
Succeeds clean, no warnings. Toolchain: Odin `dev-2026-04:df6fff6e4`, Apple M1 Max, Darwin arm64.

### Tests
```bash
$ task test
```
- Coverage harness: `Finished 24 tests in 4.2s. All tests were successful.`
- Unit fixtures: `Passed: 291  Failed: 0  Pass rate: 100%`

### Conformance
```
ES2025 (test262):  Parser 47085/47090 (99.99%) | Semantic 4588/4588 (100.00%)
Babel:             Parser 2223/2233 (99.55%) | Semantic 1674/1711 (97.84%)
TypeScript:        Parser 12653/12664 (99.91%) | Semantic 1977/3498 (56.52%)
ESTree:            Parser 39/39 (100%)      | Semantic 39/39 (100%)
Misc:              Parser 72/72 (100%)      | Semantic 279/286 (97.55%)
```

### Performance
```
task test:bench:regression → geo-mean ratio: 1.002 (tolerance 1.050) → OK
```

## Session 8 Summary

### Commits (4 feature + 1 docs)
```
64b7990 refactor(parser): move __proto__ duplicate check to checker
2ebe66d feat(checker): TS17009 — detect `this` before `super()` in derived constructors
affd43c feat(checker): TS2669 — reject `declare global` outside module context
3e45ae6 feat(checker): TS1117/TS1118 — detect duplicate object literal properties
```

### Impact
| Metric | Before | After | Δ |
|---|---|---|---|
| TS semantic negative | 1936/3498 (55.35%) | 1977/3498 (56.52%) | **+41** |
| TS semantic positive | 12607/12664 (99.55%) | 12608/12664 (99.56%) | **+1** |
| Babel parser positive | 2219/2233 (99.37%) | 2223/2233 (99.55%) | **+4** |
| Babel semantic positive | 2209/2233 (98.93%) | 2213/2233 (99.10%) | **+4** |
| test262 semantic positive | 47084 (99.99%) | 47085 (99.99%) | **+1** |

### Slice Details

**1. TS1117/TS1118 — duplicate object literal properties (+9 TS gaps)**
- State machine per property name: Unseen → Data / Getter / Setter / GetterSetter
- Non-computed keys: Identifier.name / StringLiteral.value / NumericLiteral.raw
- Computed keys: only literals (no Identifier to avoid false positives)
- Guard: skip when ObjectExpression is LHS of destructuring assignment
- `__proto__` excluded — handled by separate check

**2. TS2669 — `declare global` outside module context (+12 TS gaps)**
- Valid in: module file top-level, `declare module "..." {}` body, .d.ts files
- Added `in_ambient_module_decl` to CheckerContext
- Also fixed `export = ...` (TSExportAssignment) source-type detection → +6 bonus gaps + 1 FP fix

**3. TS17009 — `this` before `super()` in derived constructors (+20 TS gaps)**
- Linear scan of constructor body for `this` before first `super()`
- Also catches `this` in `super(...)` arguments
- Handles ExpressionStatement, VariableDeclaration, ReturnStatement
- Only fires in TS/TSX mode (JS relies on runtime ReferenceError)

**4. Parser `__proto__` check moved to checker (+4 Babel FP, +1 test262 FP fixed)**
- Removed parser-side inline `__proto__` duplicate check
- Checker's `ck_check_object_proto_dups` handles it with `in_assignment_target` guard
- Fixes 4 Babel + 1 test262 false positives on destructuring patterns

## What To Work On Next

### 1. TS2667/TS2666 — imports/exports in module augmentations (~10 gaps)
**What**: `import {X} from "Y"` and `export {X} from "Y"` inside `declare module "..." {}` bodies. Attempted in session 8 but caused 11 false positives. 
**Key insight**: Need to distinguish module augmentations (in module files) from ambient module declarations (in scripts/.d.ts). The condition `!prev_dts && source_type == .Module` is necessary but not sufficient — some module files use `declare module "..."` as ambient declarations. May need heuristic based on whether the module specifier matches a local path pattern.
**Difficulty**: medium-high

### 2. Fix ambient context checks (TS1046/TS1036/TS1038) — ~35 gaps  
**What**: Statements in ambient contexts, `declare` in ambient contexts, `.d.ts` declaration enforcement.
**Difficulty**: medium (caused -38 FP in previous attempt)

### 3. Scope analysis improvements (TS2300 cluster — 37 fixtures)
**What**: Duplicate identifier detection in namespace bodies, cross-declaration clashes, interface/class merge conflicts.
**Where**: `src/checker.odin` scope analysis
**Difficulty**: high

### 4. Remaining Babel parser false positives (10 remaining)
- 2× `with` in sloppy mode mistakenly flagged as strict
- 2× class constructor false positive
- 1× `await` binding in static block
- 1× scope clash in static block
- Various TS/arrow ambiguity issues

### 5. TS1206 — decorators not valid here (3 gaps)
**What**: Decorators on invalid targets (class expressions, computed properties, namespaces)
**Where**: `src/checker.odin`
**Difficulty**: low

### 6. Type-aware bridge (long-term)
The largest remaining cluster is type-system errors (TS2339: 174 fixtures, TS2300: 37, TS2322: 25). Any type inference would close many gaps.

## Key Files

1. `AGENTS.md` — project guide + TigerStyle
2. `src/checker.odin` lines 131-215 — CheckerContext struct
3. `src/checker.odin` lines 260-350 — check_program entry point  
4. `src/checker.odin` lines 840-970 — import/export/module statement handling
5. `src/checker.odin` lines 3880-4000 — TS1117/TS1118 duplicate property check
6. `src/checker.odin` lines 4310-4500 — TS17009 this-before-super check
7. `src/checker.odin` lines 1033-1075 — ck_walk_ts_module_decl
8. `src/parser.odin` lines 1680-1700 — source type auto-detection

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary `bin/kessel` | ~5-60s |
| `task build:coverage` | Coverage harness `bin/kessel_coverage` | ~30-120s |
| `task test` | Primary gate — coverage (24 tests) + 291 unit fixtures | ~12s |
| `task test:coverage` | Just coverage snap gate | ~5s |
| `./bin/kessel_coverage run typescript --semantic --update` | Update TS semantic snap | ~1s |
| `task test:conformance:report` | Print conformance numbers | <1s |
| `task test:bench:regression` | 10-file perf gate | ~60s |
| `./bin/kessel parse <file> --lang=ts --show-semantic-errors` | Parse with checker | per file |
