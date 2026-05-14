# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX / TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing. Mirrors OXC's `oxc_parser` / `oxc_semantic` split — parser builds the tree permissively, checker enforces ECMA-262 early errors.

## Current State (2026-05-14, session 11)

### Build
```
$ odin build src -out:bin/kessel -o:speed -no-bounds-check
```
Clean success. No warnings.

### Tests
**Primary gate** (`task test`): **All pass.**
- Coverage harness: 23 tests. All successful.
- Unit fixtures: 291 passed, 0 failed, 100%.

### Conformance — Kessel vs OXC (OXC = 100%)

Same corpus SHAs. Same exclude list. Same fixture granularity.

```
TypeScript:
  Parser positive:  9810/9828 (99.82%)  — OXC: 9818/9832 (99.86%)
  Parser negative:  1391/2583 (53.85%)  — OXC: 1532/2587 (59.22%)
  Kessel catches 90.8% of OXC's negative catches (1391/1532)
  FPs: 18 total (9 shared with OXC, 9 kessel-only)

Babel:    parser pos 2230/2237 (99.69%) | neg 1602/1725 (92.87%)
test262:  parser pos 47090/47090 (100%) | neg 4568/4588 (99.56%)
ESTree:   39/39 (100%)
```

Corpus SHAs (pinned to OXC's `clone-parallel.mjs`):
- TypeScript: `f350b523`
- Babel: `4079bcda`
- ESTree: `9c67f5e3`

## PRIORITY 1 — Fix 9 remaining kessel-only TS parser FPs

9 fixtures kessel rejects but OXC accepts. Each is a distinct issue:
1. `convertKeywordsYes.ts` — class field named 'constructor'
2. `corrupted.ts` — binary file, Expected semicolon
3. `missingCloseParenStatements.ts` — Expected ), got {
4. `modulePreserveTopLevelAwait1.ts` — for-await source-type detection
5. `withStatementInternalComments.ts` — 'with' in non-strict TS
6. `esDecorators-decoratorExpression.1.ts` — Expected class after decorator
7. `esDecorators-decoratorExpression.3.ts` — Type args in decorator
8. `topLevelAwait.3.ts` — 'await' as binding name
9. `NonInitializedExportInInternalModule.ts` — Expected binding pattern

Plus 3 `__proto__` destructuring FPs (arrow params, nested array).

## PRIORITY 2 — Close remaining TS parser negative gap

Kessel catches 90.8% of OXC's negatives (1391/1532). The remaining ~141
need investigation. Cluster by error message family and fix the largest groups.

## Completed — All checker → parser migrations DONE ✅

Every check that OXC catches at parser level now runs at parser level in kessel. Zero misplaced checker-only catches remain.

| # | Check | Parser catches gained |
|---|---|---|
| 1 | `__proto__` redefinition | +20 (3 FPs from destructuring) |
| 2 | TS2391 overload chain | +23 |
| 3 | Abstract in non-abstract class | +6 |
| 4 | abstract + private identifier | +3 |
| 5 | static + abstract | +3 |
| 6 | Label already declared | +3 |
| 7 | super.#name | +1 |
| 8 | TS1392 import alias + import type | +1 |
| 9 | Ambient function body (declare module/namespace/.d.ts) | +5 |

Also completed:
- eval/arguments as binding names allowed in TS mode (+29 FPs fixed)
- @strict:false overrides @alwaysStrict:true in harness (+8 FPs fixed)

## Session 11 Changes (22 commits)

**Parser fixes:**
1. `static` ASI in class bodies — `static\nconstructor(){}` is a static method
2. `in_static_block` reset in class field initializers — `await` as identifier in nested class
3. Static block + arrow block bodies use function-scope semantics — `var+function` coexistence
4. Skip dup-constructor check in TS mode — defer to checker for overloads
5. eval/arguments allowed as binding names in TS mode (+29 FPs fixed)

**Checker → parser migrations (all 9 done, +65 parser catches):**
6. super.#name → parse_member_expression
7. Label duplicate → parse_labelled_statement
8. static+abstract, abstract+#name, abstract-in-non-abstract → validate_class_body
9. `__proto__` redefinition → parse_object_expr (skip if `=` follows)
10. TS2391 overload chain → report_ts_overload_chain_errors
11. TS1392 import alias + import type → parse_ts_import_equals
12. Ambient function body → extended existing parser check for in_ambient/source_is_dts

**Coverage infrastructure (critical alignment with OXC):**
13. Collapse TS multi-file fixtures to match OXC per-file granularity
14. Sync corpus SHAs with OXC's clone-parallel.mjs
15. Match OXC's per-fixture variant baseline lookup (6 dimensions only)
16. Force-positive 39 fixtures matching OXC classification
17. Drop semantic_typescript — OXC has no equivalent
18. @strict:false overrides @alwaysStrict:true (+8 FPs fixed)
19. Remove 3 dead TS-only checker additions (no OXC target)

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s |
| `task test` | **Primary gate** — 23 coverage snap tests + 291 unit fixtures | ~10s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `task test:conformance:report` | Print conformance numbers from snaps | <1s |
| `task test:oxc-corpus:fetch` | Fetch all OXC corpora | ~2 min |
