# Handoff — Kessel OXC Parser Parity

## Current State

Build: clean. `task test`: all 291 unit + 24 coverage tests pass.

**194 fixtures from 100% OXC parser parity** (was 326).

| Suite | Positive (FPs) | Negative gap | Total gap |
|---|---|---|---|
| test262 | 0 | **0** | **0** 🎉 |
| Babel | 3 | 77 | 80 |
| TypeScript | 17 | 109 | 126 |
| ESTree | 0 | 0 | 0 |

**🎉 test262 parser: 100.00% positive AND 100.00% negative — PERFECT SCORE!**

Live numbers: `task test:conformance:report`

## What the numbers mean

- **Positive gap (FPs)** = `Expect to Parse:` lines — kessel rejects what OXC accepts. Parser bugs.
- **Negative gap** = `Expect Syntax Error:` lines — OXC's parser catches an error that kessel doesn't.
- The TS negative denominator (1660) is aligned with OXC's parser catches. Semantic/type-system errors are excluded via `TS_FORCE_POSITIVE_PATHS`.
- OXC's `parser_typescript.snap` at commit `c7a0ae10` is at `/Users/kakurega/dev/projects/oxc/tasks/coverage/snapshots/`.

## Session Progress (latest)

**+120 negatives caught, +1 misc positive, zero regressions** across 24 commits:

1. **Strict-mode reserved words in TS bindings/declarations** (+21 TS, +6 babel, +1 babel semantic)
   - Removed overly-broad `!allow_ts_mode(p)` gate on strict-reserved checks in `parse_binding_pattern`
   - Added `check_strict_ts_decl_name` for interface, enum, type alias, namespace declaration names
   - Added strict-reserved checks in object/array destructuring patterns and import specifiers

2. **TS2404 type annotation on for-in/of variable** (+6 TS)
   - `for (var i: number in arr)` now rejected

3. **TS2414/TS2427/TS2431 primitive type names as class/interface/enum names** (+12 TS)
   - `class any {}`, `interface number {}`, `enum string {}` now rejected

4. **break/continue context across function/arrow boundaries** (+4 TS, +4 babel, +1 misc positive)
   - `in_loop`, `in_switch`, `label_floor` now reset in `parse_function_body` and arrow block bodies
   - Misc positive went from 71/72 to 72/72 (100%)

5. **TS2457/TS2368 primitive type names in type aliases + type parameters** (+4 TS)
   - `type undefined = ...`, `foo<string>(...)` now rejected

6. **Retroactive strict-mode param check for arrow body-strict** (+3 babel)
   - `eval => {"use strict"}` now caught

7. **Strict-reserved function names + retroactive body-strict** (+9 babel)
   - `"use strict"; function static(){}`, `function package(){"use strict";}` now caught

8. **Multi-param arrow eval/arguments + expr_to_pattern strict check** (+5 babel)
   - `"use strict"; (eval, a) => 42` now caught

9. **TS1235 namespace in block/function scopes** (+3 TS)
   - `{ namespace M {} }` and namespace inside function bodies now caught

10. **`yield` as strict-mode function name** (+3 babel)
    - `function yield() { "use strict"; }` now caught

11. **String-literal 'constructor' promoted to Constructor kind** (+2 babel)
    - `class A { constructor(){} 'constructor'(){} }` now caught

12. **`await` as import binding in module code** (+2 TS)
    - `import * as await from "m"` now caught

13. **For-in/of head let/const vs body var duplicate binding** (+2 TS, +6 test262)
    - `for (let v of []) { var v; }` now caught via scope_process_statement
    - Added ForInStatement/ForOfStatement to has_scope_relevant_stmt

14. **Regular for-statement head let/const vs body var** (+1 babel, +2 test262)
    - `for (let i = 0; ...) { var i; }` now caught

15. **Static block label_floor + single-param destructuring dups** (+3 test262, +2 TS, +4 babel)
    - `continue label;` across static block boundary now caught
    - `([x, x]) => 1` single-param destructuring dups now caught

16. **Private getter/setter static mismatch (TS2804)** (+4 test262, +4 babel)
    - `get #f(){}` / `static set #f(){}` mismatch now caught

17. **Async arrow params-vs-body-lex check** (+1 test262)
    - `async(bar) => { let bar; }` now caught

18. **`new await` + escaped await-as-label in module code** (+2 test262)
    - Both module-reserved-await edge cases now caught

19. **§16.2.2 export of undeclared name in JS modules** (+2 test262, +6 babel, +1 misc)
    - `export { Number }` / `export { unresolvable }` now caught
    - **Achieves test262 parser 100.00% negative — perfect score!**

## The 20 FPs (kessel rejects valid code)

### Babel FPs (3) — all TS2391 class overload pre-pass

Kessel's class overload chain checker has a pre-pass that skips pure-signature classes. These 3 fixtures are pure-sig classes OXC accepts:

| Fixture | Error kessel reports |
|---|---|
| `typescript/class/members-with-modifier-names/input.ts` | TS2391: Function implementation missing |
| `typescript/class/method-with-newline-without-body/input.ts` | TS2391: Function implementation missing |
| `typescript/class/parameter-properties/input.ts` | `?` + initializer |

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

## Remaining negatives by category (rough)

| Category | TS | Babel | Notes |
|---|---|---|---|
| Duplicate identifiers / scope | ~30 | ~28 | Redeclaration, merge, shadow checks |
| Class member conflicts | ~20 | ~5 | Duplicate properties, accessors, overloads |
| Module/import/export | ~15 | ~10 | Module-level scope checks |
| Merge / augmentation | ~12 | — | TS-specific declaration merging |
| Overload chain | ~5 | — | Missing implementation, mismatched sigs |
| Enum | ~3 | — | Const enum errors, initializer follows |
| Strict mode (remaining) | ~5 | ~10 | Arrow escapes, eval/arguments edge cases |
| For-in/of/for | ~3 | — | Duplicate bindings in for-of body |
| Other | ~30 | ~60 | Various parser-level checks |

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
| `src/parser.odin` (~21K) | Parser. Most fixes go here. |
| `src/checker.odin` (~7K) | Semantic checker. Some checks need migration to parser. |
| `src/lexer.odin` (~3K) | Tokenizer. Rarely needs changes. |
| `tests/coverage/src/` | OXC conformance harness (Odin). |
| `tests/coverage/snapshots/parser_*.snap` | Ground truth. Diff these to verify fixes. |
| `tests/coverage/src/typescript_constants.odin` | `TS_FORCE_POSITIVE_PATHS` + `TS_NOT_SUPPORTED_ERROR_CODES` |
| `/Users/kakurega/dev/projects/oxc/tasks/coverage/snapshots/` | OXC's own snap files for reference. |
