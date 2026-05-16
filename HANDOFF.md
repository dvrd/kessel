# Handoff — Kessel OXC Parser Parity

## Current State

Build: clean. `task test`: all 291 unit + 24 coverage tests pass.

**102 fixtures from 100% OXC parser parity** (was 326 at prior handoff, was 194 at prior-prior).

| Suite | Positive (FPs) | Negative gap | Total gap |
|---|---|---|---|
| test262 | 0 | **0** | **0** 🎉 |
| Babel | 4 | 15 | 19 |
| TypeScript | 17 | 84 | 101 |
| ESTree | 0 | 0 | 0 |

**🎉 test262 parser: 100.00% positive AND 100.00% negative — PERFECT SCORE!**

Live numbers: `task test:conformance:report`

## What the numbers mean

- **Positive gap (FPs)** = `Expect to Parse:` lines — kessel rejects what OXC accepts. Parser bugs.
- **Negative gap** = `Expect Syntax Error:` lines — OXC's parser catches an error that kessel doesn't.
- The TS negative denominator (1673) is aligned with OXC's parser catches. Semantic/type-system errors are excluded via `TS_FORCE_POSITIVE_PATHS`.
- OXC's `parser_typescript.snap` at commit `c7a0ae10` is at `/Users/kakurega/dev/projects/oxc/tasks/coverage/snapshots/`.

## Key Metrics

| Metric | Status | Notes |
|---|---|---|
| test262 parser positive | **100.00%** | Perfect. |
| test262 parser negative | **100.00%** | Perfect. |
| Babel parser positive | **99.82%** | 4 FPs — TS2391 overload pre-pass. |
| Babel parser negative | **99.13%** | 15 remaining — all hard. |
| TS parser positive | **99.84%** | 17 FPs (unchanged). |
| TS parser negative | **94.98%** | 84 remaining. |
| ESTree | **100%** | Perfect. |

## The 4 Babel FPs (kessel rejects valid code)

All are in the TS2391 class overload pre-pass. OXC has the same FP for `constructor-with-modifier-names`.

| Fixture | Error kessel reports |
|---|---|
| `typescript/class/constructor-with-modifier-names/input.ts` | Multiple constructor implementations are not allowed. |
| `typescript/class/members-with-modifier-names/input.ts` | Function implementation missing |
| `typescript/class/method-with-newline-without-body/input.ts` | Function implementation missing |
| `typescript/class/parameter-properties/input.ts` | `?` + initializer |

## The 17 TS FPs (kessel rejects valid code)

| Category | Count | Root cause |
|---|---|---|
| Lexical in single-stmt | 3 | `const` in `if`/`label` body (existing FPs) |
| Multi-file async generators | 4 | OXC error-recovers better |
| Error recovery | 3 | Binary file / broken parens / bare `var;` |
| Source-type detection | 3 | `@module: preserve` / `.d.ts` sub-file / `with` strict |
| Decorators | 2 | `Expected class after decorator` / type args in decorator |
| Keywords as identifiers | 1 | Cascading keyword errors |
| Top-level return | 1 | `return` outside function |

## Remaining Babel negatives (15 — all require deep changes)

| Fixture | Error class | Difficulty |
|---|---|---|
| `escape-string/non-octal-eight-and-nine-before-use-strict` | Retroactive strict `\8`/`\9` | HIGH — lexer |
| `escape-string/non-octal-eight-and-nine` | Retroactive strict `\8`/`\9` | HIGH — lexer |
| `es2015/arrow-functions/inner-parens` | `((a)) => 0` double-paren | HIGH — cover grammar |
| `esprima/es2015-arrow-function/non-arrow-param-followed-by-arrow` | `((a)) => 0` | HIGH — cover grammar |
| `esprima/invalid-syntax/migrated_0216` | `"\1"; 'use strict';` retroactive | HIGH — lexer |
| `typescript/conditional/arrow-ambiguity` | `x ? y => z : w => v` TS ambiguity | HIGH — Pratt parser |
| `typescript/conditional/arrow-like` | `a ? (b) : a => 1` | HIGH — Pratt parser |
| `typescript/conditional/arrow-param` | `a ? (b = (c) => d) : e => f` | HIGH — Pratt parser |
| `typescript/decorators/type-arguments-invalid` | `@dec<T> class {}` | MEDIUM — decorator parsing |
| `typescript/disallow-jsx-ambiguity/type-assertion` | `<T>x;` in .mts | MEDIUM — new feature |
| `typescript/disallow-jsx-ambiguity/type-parameter` | `<T>() => 1` in .mts | MEDIUM — new feature |
| `typescript/export/invalid-as-namespace-duplicate-identifier` | `export as namespace` + global dup | MEDIUM — scope check |
| `typescript/module-namespace/invalid-global-redeclare-block-level-variable` | global block redecl | MEDIUM — scope check |
| `typescript/module-namespace/invalid-global-redeclare-block-level-variable-in-module` | global block redecl | MEDIUM — scope check |
| `typescript/regression/keyword-qualified-type-2` | `interface A extends this.B` | LOW — heritage check |

## Remaining TS negatives by category (84)

| Category | Count | Notes |
|---|---|---|
| Duplicate class elements | ~15 | property+accessor, property+function, accessor+accessor |
| Overload chain / merge | ~12 | nonMergedOverloads, incorrectClassOverloadChain |
| Import/export scope | ~10 | import merge errors, module augmentation |
| Enum errors | ~5 | constEnumErrors, enumNoInitializer, sourceMapValidationEnums |
| Declaration merge / augment | ~10 | augmentedTypes*, nameCollisions |
| Class misc | ~8 | staticBlock23, autoAccessor11, reassignStaticProp |
| JSON require | 5 | requireOfJsonFile* (needs JSON import support) |
| Multiple default exports | 1 | multipleDefaultExports03 |
| Await using | 2 | awaitUsingDeclarations.13/.14 |
| Other | ~16 | Various parser-level checks |

## Commands

```bash
task build                    # Release binary → bin/kessel
task test                     # Primary gate — test:coverage + test:unit (~12s)
task test:coverage            # OXC-style conformance harness, 24 @(test) procs
task test:coverage:update     # Regenerate snap baselines after a fix
task test:unit                # 291 golden-output positive fixtures
task test:conformance:report  # Print live conformance numbers
task test:release             # Zero-tolerance pre-release chain
task test:bench:regression    # Performance regression gate
```

## Source Layout

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 21,919 | Pratt parser. `Parser` struct + ~200 parsing procedures. |
| `src/checker.odin` | 7,230 | AST-walker semantic checker (pass 3). |
| `src/emitter.odin` | 6,381 | ESTree JSON emitter. |
| `src/lexer.odin` | 3,118 | SIMD lexer. Two-token lookahead. |
| `src/regex.odin` | 2,235 | ES2025 §22.2.1 regex pattern validator. |
| `src/ast.odin` | 1,619 | All AST struct/union definitions. |
| `src/raw_transfer.odin` | 1,304 | Zero-copy binary AST buffer. |
| `src/main.odin` | 1,295 | CLI dispatch + worker pool. |
| `src/simd.odin` | 601 | ARM64 NEON intrinsics. |
| `src/parse_job.odin` | 433 | `ParseJob` — single "source-to-parsed-Program" deep module. |
| `src/token.odin` | 383 | `TokenType` enum, `FastToken`, `LiteralValue`. |
| `src/unicode_tables.odin` | 329 | ID_Start / ID_Continue range tables. |
| `src/cli_config.odin` | 188 | `CliConfig` struct + CLI flag parsing. |
| `src/source_io.odin` | 103 | Cross-platform source reader (mmap on POSIX). |
| `src/qos_darwin.odin` | 61 | Apple Silicon QoS P-core pinning. |

Total: ~47,285 LoC of Odin in `src/`, plus ~5,190 LoC in `tests/coverage/src/`.

## Development Workflow

Bug-fix slices follow the OXC PR style — fixture, fix, snap diff in one commit:

1. **Reproduce.** Add a fixture under `tests/coverage/misc/pass/` (must-parse) or `tests/coverage/misc/fail/` (must-reject).
2. **Confirm the gap.** `task test:coverage` — the snap drifts.
3. **Fix.** Edit `src/parser.odin` / `src/checker.odin` / `src/lexer.odin`.
4. **Verify.** `task test` (primary gate) — must be green.
5. **Update snaps.** `task test:coverage:update` — review the diff carefully.
6. **Check parity test.** If TS positive/negative counts changed, update `tests/coverage/src/parity.odin` manifests.
7. **Remove force-positive entries.** If a fixture in `TS_FORCE_POSITIVE_PATHS` is now correctly caught, remove it from `tests/coverage/src/typescript_constants.odin`.
8. **Commit.** Fixture + source change + snap diff in one commit.

## What To Work On Next

### High Priority — Babel negatives (only 15 remain to reach 100%)

1. **`disallowAmbiguousJSXLike` feature** (2 fixtures). Add parser option to reject angle-bracket type assertions and generic arrows in `.mts`/`.cts` mode. Files: `src/parser.odin` (type assertion parsing), `tests/coverage/src/babel.odin` (remove skip). Difficulty: MEDIUM.

2. **`global {}` block-level redeclaration** (2 fixtures). When parsing `global { let x; }`, check outer scope for same-name `let`/`const`. Files: `src/parser.odin` (`parse_ts_global_declaration`). Difficulty: MEDIUM.

3. **TS conditional/arrow ambiguity** (3 fixtures). `x ? y => z : w => v` — OXC rejects because `:` is consumed as arrow return type. Requires changing Pratt precedence for ternary vs arrow in TS mode. Files: `src/parser.odin` (expression parsing ~line 16200). Difficulty: HIGH.

4. **Retroactive `\8`/`\9` and `\1` escapes** (3 fixtures). Strings before `"use strict"` need validation. Requires lexer flag or post-directive re-scan. Files: `src/lexer.odin`, `src/parser.odin`. Difficulty: HIGH.

5. **Double-parenthesized arrow params** (2 fixtures). `((a)) => 0` — needs paren-depth tracking through the cover grammar. Files: `src/parser.odin` (paren expression + arrow conversion). Difficulty: HIGH.

### Medium Priority — TS negatives (84 remain)

6. **Duplicate class member detection** (~15 fixtures). Property+accessor, property+function, accessor+accessor conflicts. Files: `src/parser.odin` (`report_private_class_member_errors`). Difficulty: MEDIUM.

7. **Import merge errors** (~10 fixtures). `import X` + `class X` in same module. Extend `check_ts_scope_conflicts`. Files: `src/parser.odin`. Difficulty: MEDIUM.

8. **Overload chain improvements** (~12 fixtures). `nonMergedOverloads`, mixing static/instance. Files: `src/parser.odin` (`report_ts_overload_chain_errors`). Difficulty: MEDIUM-HIGH.

9. **Multiple default exports** (1 fixture). Track default export count per module. Files: `src/parser.odin` (`parse_export_default`). Difficulty: LOW.

10. **JSON require errors** (5 fixtures). When `requireOfJsonFile*` sub-files import JSON, validate the JSON. Files: `tests/coverage/src/typescript.odin` (may need fixture handling). Difficulty: LOW-MEDIUM.

## Key Files for Common Changes

| Change type | Primary file | Key proc/section |
|---|---|---|
| New parser error | `src/parser.odin` | Add check near relevant parse proc |
| Scope/redecl check | `src/parser.odin` | `check_ts_scope_conflicts` (~line 9700) |
| Overload chain | `src/parser.odin` | `report_ts_overload_chain_errors` (~line 5174) |
| Namespace body | `src/parser.odin` | `parse_ts_module_declaration` (~line 21012) |
| Force-positive list | `tests/coverage/src/typescript_constants.odin` | `TS_FORCE_POSITIVE_PATHS` |
| Parity manifests | `tests/coverage/src/parity.odin` | `assert_manifest` / `assert_ts_parent_manifest` |
| Babel harness | `tests/coverage/src/babel.odin` | `resolve_babel_lang`, `determine_should_fail` |
