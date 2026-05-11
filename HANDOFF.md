# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript/TypeScript/JSX/TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexer, hand-written Pratt expression parser. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Mirrors OXC's `oxc_parser` / `oxc_semantic` architecture.

## Current State (2026-05-11T15:30)

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

### Conformance (from this session)
```
ES2025 (test262):  Parser 47084/47090 (99.99%) | Semantic 4588/4588 (100.00%)
Babel:             Parser 2219/2233 (99.37%) | Semantic 1674/1711 (97.84%)
TypeScript:        Parser 12653/12664 (99.91%) | Semantic 1957/3498 (55.95%)
ESTree:            Parser 39/39 (100%)      | Semantic 39/39 (100%)
Misc:              Parser 72/72 (100%)      | Semantic 279/286 (97.55%)
```

### Performance
```
task test:bench:regression → geo-mean ratio: 1.002 (tolerance 1.050) → OK
```

## Session 8 Changes

### Commit 1: TS1117/TS1118 — duplicate object literal properties (+9 gaps)

Implemented duplicate property detection in object literals for TS/TSX mode:
- TS1117: "An object literal cannot have multiple properties with the same name."
- TS1118: "An object literal cannot have multiple get/set accessors with the same name."

Key decisions:
- State machine per property name: Unseen → Data / Getter / Setter / GetterSetter
- Non-computed keys: Identifier.name / StringLiteral.value / NumericLiteral.raw
- Computed keys: only StringLiteral, NumericLiteral, UnaryExpression(+/-) wrapping literals (no Identifier to avoid false positives like `{ a: 1, [a]: 2 }`)
- Guard: skip when ObjectExpression is LHS of destructuring assignment (`({a, b} = rhs)`)
- `__proto__` excluded — already handled by `ck_check_object_proto_dups`

Files: `src/checker.odin` (+~130 lines)

### Commit 2: TS2669 — reject `declare global` outside module context (+12 gaps)

Implemented TS2669: "Augmentations for the global scope can only be directly nested in external modules or ambient module declarations."

`declare global {}` is valid when:
1. At top level of a module file (source_type == .Module)
2. Inside an ambient module declaration (`declare module "..." {}`)
3. In a .d.ts file (entire file is ambient context)

Also fixed source-type auto-detection for `export = ...` (TSExportAssignment) — files using `export =` are now correctly classified as modules. This unblocked 6 additional gaps (duplicate-export-assignment cluster) and fixed 1 pre-existing false positive.

Context tracking: added `in_ambient_module_decl` flag to CheckerContext, set when entering a TSModuleDeclaration with StringLiteral id.

Files: `src/checker.odin` (+~30 lines), `src/parser.odin` (+1 line)

### Session 8 Totals
- **TS semantic negative: 1936 → 1957 (+21, 55.35% → 55.95%)**
- **TS semantic positive: 12607 → 12608 (+1 false positive fixed)**
- Zero new false positives
- Benchmark: OK (1.002x geo-mean)

## Session 8 Commit Log

```
affd43c feat(checker): TS2669 — reject `declare global` outside module context
3e45ae6 feat(checker): TS1117/TS1118 — detect duplicate object literal properties
```

## Known Issues

| Issue | Severity | Where | Workaround |
|---|---|---|---|
| `__proto__` double-reported (parser + checker) | low | `src/parser.odin` + `src/checker.odin` | Pre-existing; parser and checker both check `__proto__` dups |
| TS2667/TS2666 (imports/exports in module augmentations) attempted but caused 11 false positives | medium | `src/checker.odin` | Needs careful distinction between module augmentation vs ambient module declaration |
| Ambient context checks (TS1046/TS1036/TS1038) previously attempted, caused -38 false positives | medium | `src/checker.odin` | Needs careful `.d.ts` edge case handling |
| Type-aware cluster (TS2339: 232, TS2322: 29, etc.) unfixable without type inference | high | `src/checker.odin` | Requires type resolution infrastructure |
| 37 Babel semantic gaps remain | medium | Various | Mix of syntactic and type-system |
| 7 misc semantic gaps (module_context + jsx-in-js + oxc issues) | low | Parser/checker | Design choices + parser fixes |

## What To Work On Next

### 1. Fix TS2667/TS2666 — imports/exports in module augmentations (~10 gaps)
**What**: `import {X} from "Y"` and `export {X} from "Y"` inside `declare module "..." {}` bodies are TS2667/TS2666 when the file is a MODULE (has other imports/exports) but NOT a `.d.ts` file. `import X = N.Y` (TSImportEqualsDeclaration) is always allowed.
**Why failed**: The `in_module_augmentation` flag was set too broadly. The distinction is:
  - Ambient module declaration (in script or .d.ts): imports/exports OK
  - Module augmentation (in module file, not .d.ts): imports TS2667, exports TS2666
**Key insight**: Check `!prev_dts && source_type == .Module` was not enough. Many fixtures have `declare module "..."` in `.ts` files that TypeScript considers as ambient declarations, not augmentations. The correct heuristic may require checking whether the module specifier refers to a module that already exists (which requires cross-file analysis).
**Where**: `src/checker.odin` (`ck_walk_stmt` + `ck_walk_ts_module_decl`)
**Difficulty**: medium-high

### 2. Fix ambient context checks (TS1046/TS1036/TS1038) — ~35 gaps
**What**: Implement `in_ambient` tracking in `CheckerContext`, add TS1036 (statements in ambient), TS1038 (declare in ambient), and TS1046 (.d.ts declarations). Current attempt caused -38 false positives.
**Where**: `src/checker.odin` (`CheckerContext`, `check_program`, `ck_walk_stmt`, `ck_walk_ts_module_decl`)
**Difficulty**: medium (requires understanding .d.ts semantics)

### 3. Investigate remaining Babel semantic gaps (37 gaps)
**What**: Check if any of the 37 Babel gaps are syntactic (checker-catchable) vs type-system. The `create-parenthesized-expressions` cluster (4 gaps) and `categorized/invalid-*` (3 gaps) might be low-hanging fruit.
**Where**: `src/checker.odin` / `src/parser.odin`
**Difficulty**: varies

### 4. Investigate type-aware bridge
**What**: The largest remaining cluster is type-system errors (TS2339, TS2322, etc.). Any type inference infrastructure would close a large fraction of the remaining 1541 gaps.
**Where**: New module
**Difficulty**: high (architectural)

### 5. Fix module_context misc gaps (4 gaps)
**What**: `export/import/await/import.meta` in script mode. Kessel auto-detects modules, so `export` in a "script" file upgrades to module instead of flagging an error. Need a `--source-type=script` flag that prevents auto-upgrade and reports errors.
**Where**: `src/parser.odin` (auto-detection logic) + `src/checker.odin`
**Difficulty**: medium

## Key Files To Read First

1. `AGENTS.md` — project guide + TigerStyle
2. `src/checker.odin` lines 131-210 — CheckerContext struct
3. `src/checker.odin` lines 260-350 — check_program entry point
4. `src/checker.odin` lines 840-900 — import/export/module statement handling
5. `src/checker.odin` lines 3880-3990 — TS1117/TS1118 duplicate property check
6. `src/checker.odin` lines 1033-1070 — ck_walk_ts_module_decl
7. `src/parser.odin` lines 1680-1700 — source type auto-detection

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary `bin/kessel` | ~5-60s |
| `task build:coverage` | Coverage harness `bin/kessel_coverage` | ~30-120s |
| `task test` | Primary gate — coverage (24 tests) + 291 unit fixtures | ~12s |
| `task test:coverage` | Just coverage snap gate | ~5s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `./bin/kessel_coverage run typescript --semantic --update` | Update TS semantic snap | ~1s |
| `task test:conformance:report` | Print conformance numbers | <1s |
| `task test:bench:regression` | 10-file perf gate | ~60s |
| `./bin/kessel parse <file> --lang=ts --show-semantic-errors` | Parse with checker | per file |
