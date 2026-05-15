# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX / TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing. Mirrors OXC's `oxc_parser` / `oxc_semantic` split.

## Current State (2026-05-15, session 12)

### Build & Tests
```
$ odin build src -out:bin/kessel -o:speed -no-bounds-check  # Clean, no warnings
$ task test                                                  # All pass: 291/291 + 23 coverage
```

### Conformance

```
test262:      parser pos 47114/47114 (100.00%) | neg 4568/4588 (99.56%)
              semantic pos 47114/47114 (100%) | neg 4588/4588 (100%)
TypeScript:   parser pos 9811/9828 (99.83%)   | neg 1443/2583 (55.87%)
Babel:        parser pos 2233/2237 (99.82%)   | neg 1603/1725 (92.93%)
              semantic pos 2224/2237 (99.42%)  | neg 1677/1725 (97.22%)
ESTree:       39/39 (100%)
Misc:         parser pos 71/72 (98.61%)       | neg 258/286 (90.21%)
```

## Session 12 Changes (10 commits)

### FP fixes (+3 babel, +1 TS positive)
1. **`__proto__` dup deferred via pending list** — same `pending_cover_inits` pattern. Clears in `expr_to_pattern` for ObjectPattern. Fixes arrow params + nested array destructuring. (+3 babel FPs)
2. **Break/continue/return skip ambient context** — `&& !p.in_ambient` guard. (+1 TS FP)
3. **Constructor-name skip for StringLiteral+access modifier** — `public "constructor" = 0;` accepted.

### Negative gap closures (+52 TS negatives, +1 babel negative)
4. **`.d.ts` statement rejection** — pure statements (loops, debugger, etc.) flagged in declaration files. (+15)
5. **TS1016 required-after-optional** — migrated from checker to parser. (+1)
6. **TS2371 default-in-overload + parameter-property** — defaults not allowed in overload/ambient sigs, param properties only in implementation constructors. (+16, +1 babel)
7. **Accessor type param / return type checks** — get can't have type params, set can't have type params or return type. (+3)
8. **TS1051 set accessor optional param** — setter parameter can't be optional. (+2)
9. **TS2491 for-in destructuring** — TS-only: destructuring patterns not allowed in for-in LHS. (+6)
10. **TS1038 declare-in-ambient** — `declare` inside `declare namespace` is redundant. (+9)

### Session 12 Net Impact

| Metric | Session 11 End | Session 12 End | Delta |
|---|---|---|---|
| Babel parser positive | 2230/2237 | 2233/2237 | **+3** |
| Babel parser negative | 1602/1725 | 1603/1725 | **+1** |
| TS parser positive | 9810/9828 | 9811/9828 | **+1** |
| TS parser negative | 1391/2583 | 1443/2583 | **+52** |
| test262 | 100% / 99.56% | 100% / 99.56% | No change |

## Remaining FPs (17 TS + 4 Babel)

### Babel FPs (4)
- `sourcetype-commonjs/top-level-using` — CommonJS source-type detection
- `members-with-modifier-names` / `method-with-newline-without-body` — TS2391 overload chain (removing loses 9 TS negatives)
- `parameter-properties` — `?` + initializer (removing loses 7 negatives)

### TS FPs (17)
- **Lexical declaration cluster (3):** `constDeclarations-{invalidContexts,scopes,validContexts}`. Can't remove without losing 137 test262 negatives.
- **Multi-file async generator cluster (4):** Sub-files with intentional errors. OXC error-recovers.
- **Error recovery singles (5):** `corrupted.ts`, `missingCloseParenStatements.ts`, `NonInitializedExportInInternalModule.ts`, `parserStatementIsNotAMemberVariableDeclaration1.ts`, `convertKeywordsYes.ts`.
- **Source-type/ambient singles (3):** `modulePreserveTopLevelAwait1.ts`, `topLevelAwait.3.ts`, `withStatementInternalComments.ts`.
- **Decorator singles (2):** `esDecorators-decoratorExpression.{1,3}.ts`.

## PRIORITY 1 — Continue closing TS negative gap

Remaining: 1140 uncaught "Expect Syntax Error" lines (2583 - 1443).

**Biggest remaining uncaught clusters:**
- `conformance/types/*` (~66): Type-system checks (duplicate properties, indexers, conditional types, etc.) — deep TS semantics
- `conformance/parser/ecmascript5/*` (~65): StrictMode (5), ModuleDecl (7), FunctionDecl (5), ClassDecl (5), Statements (10), ErrorRecovery (4), SuperExpr (3)
- `conformance/salsa/*` (~19): JS analysis edge cases — hard
- `compiler/*` (~20): Diverse mix

**Approach:** Keep migrating checker→parser for TS-specific checks that OXC enforces at parser level. Best ROI checks remaining:
- Top-level function overload chain (TS2391 for non-class functions)
- TS module/export validation (export=, multiple exports)
- TS strict-mode parameter name checks (`eval`/`arguments`)
- Duplicate property/indexer checks in interfaces/classes

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s |
| `task test` | **Primary gate** — coverage snap gate + 291 unit fixtures | ~10s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `task test:conformance:report` | Print conformance numbers from snaps | <1s |
| `task test:oxc-corpus:fetch` | Fetch all OXC corpora | ~2 min |
