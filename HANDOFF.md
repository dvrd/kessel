# Handoff — Kessel OXC Parser Parity

## Current State

Build: clean. `task test`: all 291 unit + 24 coverage tests pass.

| Suite | Positive | Negative | Notes |
|---|---|---|---|
| **test262** | **100.00%** | **100.00%** | 🎉 Perfect — ES2025 fully conformant. |
| **Babel** | **100.00%** | **100.00%** | 🎉 Perfect. |
| **ESTree** | **100.00%** | — | 🎉 Perfect. |
| **Misc** | **100.00%** | 93.01% | Positive perfect. |
| **TypeScript** | **100.00%** | 96.77% | 🎉 Positive perfect. 54 negatives remain (was 63). |

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
- Multiple `export default` in TS — tsc TS2528 semantic (OXC accepts)
- Duplicate type parameter names — tsc TS2300 semantic (OXC accepts)
- `infer` outside conditional extends — tsc TS1338 (OXC may accept)

## What Was Done (latest session — TS negative push)

### TS negative: 96.23% → 96.77% (+9 fixtures)

**1. ASI for `abstract\nclass` (TS1244):**
- `abstract` on a separate line from `class` is now treated as expression statement + non-abstract class (matches OXC/TSC/Babel).
- The existing TS1244 check for abstract methods in non-abstract classes then fires.
- Applied to 3 code paths: statement parser, export-default parser, decorator parser.
- Fixes `asiAbstract.ts`.

**2. TS17019/TS17020 — `!` at start/end of type:**
- Prefix `!T` and postfix `T!` in TS type annotations now report errors.
- `?` prefix/postfix NOT flagged — JSDoc nullable (`string?`, `?string`) is valid in TS. Flagging `?` caused regressions in `expressionWithJSDocTypeArguments.ts`.
- Fixes `parseInvalidNonNullableTypes.ts`.
- `parseInvalidNullableTypes.ts` still uncaught (needs `?` check which breaks positives).

**3. TS18007 — JSX comma operator:**
- SequenceExpression in JSX attribute value `{class1, class2}` now reports error.
- Fixes `jsxParsingError1.tsx`.

**4. TS2393 — Duplicate function implementation:**
- Two class methods with the same name and both having bodies are now flagged.
- Overload sigs (body-less) are still fine. Methods with type parameters skip the check (OXC accepts different generic specializations).
- Empty-string computed keys (`[""]() {}`) now participate in dup detection (previously skipped by `if name == "" { continue }`).
- Fixes `overloadsWithinClasses.ts`, `optionalParamArgsTest.ts`, `computedPropertyNames40_ES5.ts`, `computedPropertyNames40_ES6.ts`, `parserMemberFunctionDeclarationAmbiguities1.ts`.

**5. TS2387/2388 — Mixed static/instance overload sigs:**
- Pure-sig classes where sigs for the same name have mixed static/instance modifiers are no longer silently skipped by the pre-pass.
- `elem.static` removed from the `has_modifier` set (static is tracked separately for mismatch detection).
- Fixes `memberFunctionOverloadMixingStaticAndInstance.ts`.

### Misc negative: 92.66% → 93.01% (+1 fixture)
- `kessel-ts2300-type-param-dup.ts` — now caught by TS2393/overload chain improvements.

### Fixes attempted but reverted (caused positive regressions):
- **TS2528 multiple default exports** — Enabled duplicate `export default` check in TS mode. Caused 20 positive regressions (OXC accepts multiple `export default` in TS). Reverted.
- **TS17019/TS17020 `?` prefix/postfix** — Flagging `?` in type position broke `expressionWithJSDocTypeArguments.ts` and other JSDoc-in-TS fixtures. Only `!` checks kept.
- **TS2300 duplicate type parameters** — OXC's parser doesn't flag `function A<X, X>(){}`. 6 positive regressions. Reverted.

## TS Negative Gap (54 remaining)

| Category | Count | Notes |
|---|---|---|
| Scope-level TS2300 | ~20 | class+var, function+var, import merge — needs scope tracking |
| Module/import/export | ~10 | TS2309, TS2440, TS2434, TS2882 — module semantics |
| Overload chain | ~3 | TS2395 (merged decl export mismatch), TS2391 (symbol-keyed) |
| Type-system | ~5 | TS2322, TS2344, TS2339, TS2677 — needs type checking |
| JSON/require | ~5 | TS1327, TS2339, TS2732 — needs JSON module support |
| Const enum | 1 | TS2474-2478 — const enum reference errors |
| Regex | 1 | TS1517 — char class range order with surrogates |
| Misc singletons | ~9 | TS1244 (infer), TS1338, TS1213, TS2481, TS2528, etc. |

### What to work on next

**Easiest remaining wins (parser-level, no scope tracking):**
1. **TS1338 — `infer` outside conditional extends** (2 fixtures) — needs a flag tracking conditional type nesting that survives parenthesized/tuple resets.
2. **TS1473 — import declaration in non-module position** (1 fixture) — needs tracking whether we're at module top level.
3. **TS1061/TS18056 — enum member initializer required** (1 fixture) — needs tracking previous enum member initializer type.

**Medium difficulty:**
4. **TS2309 — `export =` conflicts** (3 fixtures) — `report_ts2309_export_assignment` exists but may not fire for `declare module` bodies.
5. **TS2451 — duplicate in block scope** (1 fixture) — `exportInterfaceClassAndValue.ts`.

**Hard (requires scope tracking):**
6. **TS2300 scope-level** (~20 fixtures) — class+var, function+var, import merge conflicts. Previously attempted, caused positive regressions from TS declaration merging edge cases.

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
