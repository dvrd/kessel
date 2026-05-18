# Handoff — Kessel OXC Parser Parity

## Current State

Build: clean. `task test`: all 291 unit + 24 coverage tests pass.

| Suite | Positive | Negative | Notes |
|---|---|---|---|
| **test262** | **100.00%** | **100.00%** | 🎉 Perfect — ES2025 fully conformant. |
| **Babel** | **100.00%** | **100.00%** | 🎉 Perfect — all Babel-only fixtures skipped with rationale. |
| **ESTree** | **100.00%** | — | 🎉 Perfect. |
| **Misc** | **100.00%** | 92.66% | Positive perfect. |
| **TypeScript** | **100.00%** | 96.23% | 🎉 Positive perfect. 63 negatives remain. |

Live numbers: `task test:conformance:report`

## Architecture Decisions

### Parser stays permissive — semantic checks belong in checker

Kessel matches OXC's architecture: the parser accepts everything OXC's parser accepts. Checks that tsc implements as semantic errors (TS1xxx–TS2xxx) are NOT enforced at parser level. This includes:
- Modifier incompatibility (`static abstract`) — tsc TS1243 semantic
- Function bodies in `declare` contexts — tsc TS1183 semantic
- `with` in strict mode — tsc TS1101 semantic (in TS files only)
- Heritage clause `this.B` — tsc TS2499 semantic
- `export as namespace` + `global {}` redeclaration — tsc semantic
- `const` on type alias type params — tsc TS1277 semantic
- Duplicate constructor in TS mode — tsc TS2394 semantic

### Babel-only fixtures skipped (21 total)

18 fixtures where Babel is stricter than both tsc and OXC, plus 3 confirmed Babel parser bugs. All documented in `tests/coverage/src/babel.odin` skip list with tsc diagnostic codes and rationale.

### TS positive FPs — all resolved

All 14 former TS positive FPs are resolved:
- **5 fixed** with parser/lexer improvements (decorators, binary garbage, close-paren recovery, bare var/let/const in namespaces, missing-paren error recovery)
- **9 skipped** — spec-correct parser checks shared with OXC (constDeclarations, asyncGenerators, withStatementInternalComments, parserStatementIsNotAMemberVariableDeclaration1). Rationale documented in `TS_NOT_SUPPORTED_TEST_PATHS`.

## What Was Done (latest session — TS positive + negative push)

### TS positive: 99.87% → 100.00%

**Parser fixes (5 kessel-only FPs resolved):**
1. **Decorator expressions in TS** — added `new`, optional chaining (`?.`), tagged templates, and dangling type-args to decorator suffix loop. Fixes `esDecorators-decoratorExpression.{1,3}.ts`.
2. **Bare `var;`/`let;`/`const;` in TS namespaces** — suppress parser error inside `p.in_ts_namespace` (TS1123 is semantic). Fixes `NonInitializedExportInInternalModule.ts`.
3. **Binary garbage handling** — non-IdStart code points (U+FFFD etc.) now produce `.Invalid` tokens instead of broken identifiers. "Unexpected token" suppressed for binary-garbage `.Invalid` tokens. Fixes `corrupted.ts`.
4. **Close-paren error recovery** — infer missing `)` before `{` in if/while/with/do-while conditions (TS sloppy mode only, gated by `allow_ts_mode && !strict_mode`). Do-while also recovers when `;`/`}`/EOF follows. Fixes `missingCloseParenStatements.ts`.

**Fixture skips (9 shared-with-OXC FPs):**
- `constDeclarations-{invalidContexts,scopes,validContexts}` — §14.1.1 lexical decl in single-statement
- `withStatementInternalComments` — @ts-ignore suppresses TS1101
- `parser.asyncGenerators.{classMethods,functionDeclarations,functionExpressions,objectLiteralMethods}.es2018` — multi-file sub-unit error recovery
- `parserStatementIsNotAMemberVariableDeclaration1` — return outside function

### TS negative: 94.80% → 96.23% (+24 fixtures)

**Duplicate class member detection (`report_duplicate_class_member_errors`):**
- Property + accessor same name → duplicate
- Property + method (with body) same name → duplicate
- get + get or set + set same name → duplicate
- get + set → OK (complementary pair)
- Duplicate constructor implementations (TS2392) in TS mode
- Static / instance are separate namespaces
- TS overload sigs (body-less) excluded; override methods excluded
- Property + property: only dup when BOTH have initializers OR computed string keys
- Computed string literal keys (`["foo"]`) participate in dup detection
- **Bug fix**: `is_overload` defaulted to `true` for non-FE values — fields were misclassified as overload sigs. Fixed in both public and private dup checkers.

**Overload chain improvements:**
- Class fields (`kind=.Method` but val not FE) now break the overload chain in pre-pass and main pass. Fixes `incorrectClassOverloadChain.ts`.
- Computed string literal keys now participate in overload chain tracking.

**Numeric literal normalization:**
- `class_element_prop_name` now uses `f64 value` for NumericLiteral (not raw text), so `0`, `0.0`, `0b0` all normalize to `"0"`. Catches `numericClassMembers1`, `duplicateIdentifierDifferentSpelling`.

**Enum duplicate member detection:**
- Duplicate enum member names are now flagged (TS2300). Catches `sourceMapValidationEnums.ts`.

**`for await` in static block (TS18038):**
- Previously the `!p.in_static_block` guard skipped error reporting. Now `for await` inside static blocks is always rejected. Catches `classStaticBlock23.ts`.

**`await using` in static block (TS18054):**
- Static blocks run synchronously; `await` is not available. Catches `awaitUsingDeclarations.14.ts`.

**`class_is_abstract` flag leak fix:**
- `p.class_is_abstract` was set to `true` for abstract classes but never restored by the caller. Subsequent non-abstract classes inherited the flag, suppressing TS1253. Fixed in 3 call sites. Catches `abstractPropertyNegative.ts`.

**Excluded error code:**
- TS1490 ("File appears to be binary") — lexer-level detection neither OXC nor kessel implements.

## TS Negative Gap (63 remaining)

| Category | Count | Notes |
|---|---|---|
| Scope-level TS2300 | ~20 | class+var, function+var, import merge — needs scope tracking |
| Module/import/export | ~10 | TS2309, TS2440, TS2434, TS2882, TS5101 — module semantics |
| Overload chain | ~5 | TS2393, TS2395, TS2391 — needs type-param awareness |
| Type-system | ~5 | TS2322, TS2344, TS2339, TS2677 — needs type checking |
| JSON/require | ~5 | TS1327, TS2339, TS2732 — needs JSON module support |
| Reserved words in types | 1 | TS1213 — `public` as type in strict mode |
| Regex validation | 1 | TS1517 — char class range order |
| Misc singletons | ~16 | Each a unique semantic/type check |

### What to work on next

All remaining 63 negatives require either:
1. **Scope tracking** — building declaration maps at function/module scope to detect cross-declaration conflicts (TS2300 for class+var, function+var, import+var). This is the biggest category (~20 fixtures) and would need extending `check_ts_scope_conflicts` with Class+VarLike, Function+VarLike, Class+Function conflict rules. Attempted but caused positive regressions from TS declaration merging edge cases.
2. **Module resolution semantics** — import/export merge checks (TS2309 `export =` conflicts, TS2440 import merge, TS2434 namespace augmentation). Kessel already has `report_ts2309_export_assignment` but it doesn't fire for `declare module` bodies (needs debugging).
3. **Overload signature comparison** — method+method duplicate detection (TS2393) requires comparing type parameters, which is beyond simple name matching.
4. **Type system checks** — TS2322, TS2344, TS2339, TS2677 are type-checking errors that belong in the checker pass, not the parser.

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

## Key Files for Common Changes

| Change type | Primary file | Key proc/section |
|---|---|---|
| New parser error | `src/parser.odin` | Add check near relevant parse proc |
| Duplicate class members | `src/parser.odin` | `report_duplicate_class_member_errors` |
| Private member dups | `src/parser.odin` | `report_private_class_member_errors` |
| Overload chain | `src/parser.odin` | `report_ts_overload_chain_errors` |
| Scope/redecl check | `src/parser.odin` | `check_ts_scope_conflicts` |
| TS2309 export = | `src/parser.odin` | `report_ts2309_export_assignment` |
| Enum duplicate members | `src/parser.odin` | Inside `parse_ts_enum_declaration` |
| Namespace body | `src/parser.odin` | `parse_ts_module_declaration` |
| Lexer non-IdStart | `src/lexer.odin` | `lex_validate_unicode_identifier` |
| Close-paren recovery | `src/parser.odin` | `expect_close_paren_or_recover` |
| Force-positive list | `tests/coverage/src/typescript_constants.odin` | `TS_FORCE_POSITIVE_PATHS` |
| Skip list | `tests/coverage/src/typescript_constants.odin` | `TS_NOT_SUPPORTED_TEST_PATHS` |
| Excluded error codes | `tests/coverage/src/typescript_constants.odin` | `TS_NOT_SUPPORTED_ERROR_CODES` |
| Parity manifests | `tests/coverage/src/parity.odin` | `assert_manifest` |
| Babel harness / skip list | `tests/coverage/src/babel.odin` | `BABEL_PATH_SKIP_SUBSTRINGS` |
| ParseConfig plumbing | `src/parse_job.odin` | `ParseConfig` struct |
