# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX / TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing. Mirrors OXC's `oxc_parser` / `oxc_semantic` split — parser builds the tree permissively, checker enforces ECMA-262 early errors.

## Current State (2026-05-15, session 12)

### Build
```
$ odin build src -out:bin/kessel -o:speed -no-bounds-check
```
Clean success. No warnings.

### Tests
**Primary gate** (`task test`): **All pass.**
- Coverage harness: 23 tests. All successful.
- Unit fixtures: 291 passed, 0 failed, 100%.

### Conformance — Kessel vs OXC

```
test262:      parser pos 47090/47090 (100.00%) | neg 4568/4588 (99.56%)
              semantic pos 47090/47090 (100%) | neg 4588/4588 (100%)
TypeScript:   parser pos 9811/9828 (99.83%)   | neg 1406/2583 (54.43%)
Babel:        parser pos 2233/2237 (99.82%)   | neg 1602/1725 (92.87%)
              semantic pos 2224/2237 (99.42%)  | neg 1677/1725 (97.22%)
ESTree:       39/39 (100%)
Misc:         parser pos 71/72 (98.61%)       | neg 258/286 (90.21%)
```

Corpus SHAs (pinned to OXC's `clone-parallel.mjs`):
- TypeScript: `f350b523`
- Babel: `4079bcda`
- ESTree: `9c67f5e3`

## Session 12 Changes (4 commits)

### 1. `__proto__` duplicate check deferred via pending list (+3 babel FPs fixed)
**Problem:** The parser reported `Redefinition of __proto__ property` immediately when closing `}`, using `!is_token(.Assign)` as a heuristic to skip destructuring targets. This missed:
- Arrow params: `({ __proto__: x, __proto__: y }) => {}`
- Nested array destructuring: `([{ __proto__: x, __proto__: y }] = [{}])`

**Fix:** Adopted the same `pending_cover_inits` pattern already proven in the codebase. Duplicate `__proto__` key offsets are stashed in `pending_proto_dups`. When `expr_to_pattern` converts ObjectExpression → ObjectPattern, entries within that object's span are cleared. Remaining entries are reported at end of `parse_program`.

### 2. Break/continue/return checks skip ambient context (+1 TS FP fixed)
**Problem:** `break;`, `continue;`, `return;` inside `declare namespace M { ... }` triggered parser errors even though the statements are never executed.

**Fix:** Added `&& !p.in_ambient` guard to the break, continue, and return context checks. OXC's parser is lenient about statements inside ambient namespaces.

### 3. Constructor-name check skips StringLiteral keys with access modifiers
**Problem:** `public "constructor" = 0;` (StringLiteral key + access modifier) was rejected by the class field constructor-name check. OXC accepts this and defers to the type checker.

**Fix:** Skip the check when the key is a StringLiteral AND the field has an access modifier (public/private/protected). Plain Identifier-keyed `public constructor;` is still caught. No net conformance change — `convertKeywordsYes.ts` still has other errors downstream.

### 4. .d.ts files: reject pure statements (+15 TS negatives caught)
**Problem:** Kessel accepted statements like `debugger;`, `{}`, `do/while`, etc. in `.d.ts` declaration files. OXC's parser rejects these.

**Fix:** Added `report_dts_non_declaration` check in `parse_program_item`. Pure statement types (ExpressionStatement, BlockStatement, DebuggerStatement, loops, etc.) are flagged as errors. Declarations without `declare` are fine (`.d.ts` is implicitly ambient). EmptyStatement is also allowed (follows declarations with semicolons).

## Session 12 Net Impact

| Metric | Before | After | Delta |
|---|---|---|---|
| Babel parser positive | 2230/2237 | 2233/2237 | **+3** |
| TS parser positive | 9810/9828 | 9811/9828 | **+1** |
| TS parser negative | 1391/2583 | 1406/2583 | **+15** |
| test262 | No change | No change | 0 |
| ESTree | No change | No change | 0 |

## Remaining FPs (17 TS + 4 Babel)

### Babel FPs (4)
| File | Error | Notes |
|---|---|---|
| `sourcetype-commonjs/top-level-using/input.js` | 'using' at script top level | CommonJS source-type detection |
| `typescript/class/members-with-modifier-names/input.ts` | TS2391 overload chain | OXC skips when no implementations exist. Kessel's pre-pass condition too narrow. Fixing loses 9 TS negatives — bad trade. |
| `typescript/class/method-with-newline-without-body/input.ts` | TS2391 overload chain | Same root cause as above |
| `typescript/class/parameter-properties/input.ts` | `?` + initializer | OXC defers to type checker. Removing loses 7 negatives. |

### TS FPs (17)
**Lexical declaration cluster (3):** `constDeclarations-invalidContexts.ts`, `constDeclarations-scopes.ts`, `constDeclarations-validContexts.ts`. OXC doesn't enforce "Lexical declaration cannot appear in single-statement context" at parser level for these TS files. Can't remove without losing 137 test262 negatives.

**Multi-file async generator cluster (4):** `parser.asyncGenerators.*.es2018.ts` — sub-files named `*IsError.ts` produce errors. OXC's parser error-recovers more gracefully for `async * get x()` and `await` in formal params.

**Error recovery singles (5):** `corrupted.ts` (binary), `missingCloseParenStatements.ts` (broken parens), `NonInitializedExportInInternalModule.ts` (bare `var;`/`let;`/`const;`), `parserStatementIsNotAMemberVariableDeclaration1.ts` (top-level `return`), `convertKeywordsYes.ts` (cascading keyword errors).

**Source-type/ambient singles (3):** `modulePreserveTopLevelAwait1.ts` (`@module: preserve`), `topLevelAwait.3.ts` (`@filename: index.d.ts` sub-file), `withStatementInternalComments.ts` (`with` in strict TS).

**Decorator singles (2):** `esDecorators-decoratorExpression.1.ts` (Expected class after decorator), `esDecorators-decoratorExpression.3.ts` (Type args in decorator).

## PRIORITY 1 — Close TS parser negative gap (54.43% → target 60%+)

1177 "Expect Syntax Error" lines remain where OXC catches an error but kessel doesn't.

**Biggest uncaught clusters by directory:**
- `conformance/parser/ecmascript5` (80): Accessor, ClassDecl, ConstructorDecl, EnumDecl, FunctionDecl, MemberAccess, ModuleDecl, ParameterList, Statements, StrictMode, SuperExpr
- `conformance/types` (66): objectTypeLiteral (9), specifyingTypes (8), thisType (7), members (5), typeAliases (5), union (4), typeParameters (4)
- `conformance/salsa` (19): JS analysis edge cases
- `conformance/statements` (13): for-in destructuring, using declarations, labeled statements

**Approach:** Cluster by error-message family in the snap, find the largest group, fix the root cause. The `.d.ts` statement check in this session is a template for how to close clusters efficiently.

## PRIORITY 2 — Fix remaining FPs where trade-off is favorable

The TS2391 overload chain check is the most impactful remaining FP cluster (2 babel + potentially TS). The current pre-pass skip condition (`!has_any_impl && !has_non_method && !has_ctor_sig && name_count <= 1`) is too narrow. A more nuanced approach: only report TS2391 when a name appears 2+ times as body-less signatures AND at least one other method has a body. This needs careful implementation to avoid losing the 9 TS negatives.

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s |
| `task test` | **Primary gate** — 23 coverage snap tests + 291 unit fixtures | ~10s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `task test:conformance:report` | Print conformance numbers from snaps | <1s |
| `task test:oxc-corpus:fetch` | Fetch all OXC corpora | ~2 min |
