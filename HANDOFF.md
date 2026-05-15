# Handoff — Kessel OXC Parser Parity

## Current State

Build: clean. `task test`: all 291 unit + 23 coverage tests pass.

**326 fixtures from 100% OXC parser parity.**

| Suite | Positive (FPs) | Negative gap | Total gap |
|---|---|---|---|
| test262 | 0 | 20 | 20 |
| Babel | 3 | 121 | 124 |
| TypeScript | 17 | 165 | 182 |
| ESTree | 0 | 0 | 0 |

Live numbers: `task test:conformance:report`

## What the numbers mean

- **Positive gap (FPs)** = `Expect to Parse:` lines — kessel rejects what OXC accepts. Parser bugs.
- **Negative gap** = `Expect Syntax Error:` lines — OXC's parser catches an error that kessel doesn't.
- The TS negative denominator (1660) is aligned with OXC's parser catches. Semantic/type-system errors are excluded via `TS_FORCE_POSITIVE_PATHS`.
- OXC's `parser_typescript.snap` at commit `c7a0ae10` is at `/Users/kakurega/dev/projects/oxc/tasks/coverage/snapshots/`.

## The 20 FPs (kessel rejects valid code)

### Babel FPs (3) — all TS2391 class overload pre-pass

Kessel's class overload chain checker has a pre-pass that skips pure-signature classes. These 3 fixtures are pure-sig classes OXC accepts:

| Fixture | Error kessel reports |
|---|---|
| `typescript/class/members-with-modifier-names/input.ts` | TS2391: Function implementation missing |
| `typescript/class/method-with-newline-without-body/input.ts` | TS2391: Function implementation missing |
| `typescript/class/parameter-properties/input.ts` | `?` + initializer |

Root cause for first 2: `report_ts_overload_chain_errors` pre-pass condition `!has_any_impl && !has_non_method && !has_ctor_sig && name_count <= 1`. These classes have multiple names or non-method members, so the pre-pass doesn't skip, and the main pass reports TS2391 for each chain. Tried refining the pre-pass (lone-untyped heuristic) but it traded other negatives — reverted.

Third one: `A parameter cannot have a question mark and an initializer.` Removing this check loses 7 negatives (5 TS + 2 babel).

### TS FPs (17)

| Category | Count | Fixtures | Error |
|---|---|---|---|
| Lexical in single-stmt | 3 | `constDeclarations-{invalidContexts,scopes,validContexts}.ts` | `Lexical declaration cannot appear in a single-statement context` |
| Multi-file async generators | 4 | `parser.asyncGenerators.*.es2018.ts` | Sub-files named `*IsError.ts` have expected errors; OXC error-recovers |
| Error recovery | 3 | `corrupted.ts`, `missingCloseParenStatements.ts`, `NonInitializedExportInInternalModule.ts` | Binary file / broken parens / bare `var;` |
| Source-type detection | 3 | `modulePreserveTopLevelAwait1.ts`, `topLevelAwait.3.ts`, `withStatementInternalComments.ts` | `@module: preserve` / `.d.ts` sub-file / `with` strict |
| Decorators | 2 | `esDecorators-decoratorExpression.{1,3}.ts` | `Expected class after decorator` / type args in decorator |
| Keywords as identifiers | 1 | `convertKeywordsYes.ts` | Cascading keyword errors |
| Top-level return | 1 | `parserStatementIsNotAMemberVariableDeclaration1.ts` | `return` outside function |

## The 306 negatives (OXC catches, kessel doesn't)

### test262 (20)

```
arrow-function duplicate-binding (2), async-arrow duplicate (1),
module-code export resolution (2), new-await in module (1),
private getter/setter static mismatch (4),
continue in static-init with label (1),
for-in/of/for bound-names-in-stmt (7), labeled await-module-escaped (1),
```

All are scope/binding checks (duplicate names, bound-name-in-stmt resolution).

### Babel (121)

```
typescript/ (53), core/ (27), esprima/ (20), es2015/ (10),
es2022/ (6), jsx/ (4), annex-b/ (1)
```

### TypeScript (165)

```
compiler/ (109), conformance/parser/ (15), conformance/classes/ (14),
conformance/es6/ (10), conformance/types/ (9), conformance/statements/ (3),
conformance/externalModules/ (2), scanner/ (1), jsx/ (1), internalModules/ (1)
```

## Commands

```bash
task build                    # Release binary
task test                     # Primary gate — must be green before committing
task test:coverage            # OXC conformance harness only
task test:coverage:update     # Regenerate snap baselines after a fix
task test:conformance:report  # Print live numbers
task test:oxc-corpus:fetch    # Fetch TypeScript + Babel + ESTree corpora
```

## Workflow

1. Pick a fixture from `Expect to Parse:` (FP) or `Expect Syntax Error:` (negative gap).
2. Reproduce: `./bin/kessel parse tests/vendor/<path>` — see the error (or lack of).
3. Fix in `src/parser.odin` (or `src/lexer.odin` / `src/checker.odin`).
4. `task test` — must be green.
5. `task test:coverage:update` — review snap diff. Ensure no regressions (positive count must not drop).
6. Commit: fixture class + fix + snap diff.

## Key files

| File | What |
|---|---|
| `src/parser.odin` (~20K) | Parser. Most fixes go here. |
| `src/checker.odin` (~7K) | Semantic checker. Some checks need migration to parser. |
| `src/lexer.odin` (~3K) | Tokenizer. Rarely needs changes. |
| `tests/coverage/src/` | OXC conformance harness (Odin). |
| `tests/coverage/snapshots/parser_*.snap` | Ground truth. Diff these to verify fixes. |
| `tests/coverage/src/typescript_constants.odin` | `TS_FORCE_POSITIVE_PATHS` + `TS_NOT_SUPPORTED_ERROR_CODES` |
| `/Users/kakurega/dev/projects/oxc/tasks/coverage/snapshots/` | OXC's own snap files for reference. |
