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
TypeScript (OXC target = 100%):
  Parser positive:  9810/9828 (99.82%)  — OXC: 9818/9832 (99.86%)
  Parser negative:  1390/2583 (53.81%)  — OXC: 1532/2587 (59.22%)
  Kessel catches 90.7% of OXC's negative catches (1390/1532)
  FPs: 18 (9 shared with OXC, 9 kessel-only)

Babel:    parser pos 2230/2237 (99.69%) | neg 1597/1725 (92.58%)
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

Kessel catches 91.8% of OXC's negatives (1407/1532). The remaining ~125
need investigation. Verify parser-side coverage for:
- **`import type` violations** (65 OXC hits) — 15 parser refs, OXC catches more
- **Statements in ambient** (29 OXC hits) — 65 parser refs, verify coverage

### Checker → parser migrations: ALL 6 DONE ✅

| # | Check | Parser catches gained |
|---|---|---|
| 1 | `__proto__` redefinition | +20 (3 FPs from destructuring) |
| 2 | TS2391 overload chain | +23 |
| 3 | Abstract in non-abstract class | +6 |
| 4 | abstract + private identifier | +3 |
| 5 | Label already declared | +3 |
| 6 | super.#name | +1 |



## Session 11 Changes (17 commits)

**Parser fixes (+4 babel parser positive):**
1. fix(parser): `static` ASI in class bodies
2. fix(parser): reset `in_static_block` in class field initializers
3. fix(parser): static block + arrow block bodies use function-scope semantics
4. fix(parser): skip dup-constructor check in TS mode

**Checker → parser migrations (+33 parser catches across all suites):**
5. super.#name → parse_member_expression
6. Label duplicate → parse_labelled_statement
7. static+abstract, abstract+#name, abstract-in-non-abstract → validate_class_body_elements
8. `__proto__` redefinition → parse_object_expr (inline, skip if `=` follows)

**Coverage infrastructure:**
9. Collapse TS multi-file fixtures to match OXC per-file granularity
10. Sync corpus SHAs with OXC
11. Match OXC's per-fixture variant baseline lookup
12. Force-positive 39 fixtures matching OXC classification
13. Drop semantic_typescript (OXC has no equivalent)
14. Remove 3 dead TS-only checker additions

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s |
| `task test` | **Primary gate** — 23 coverage snap tests + 291 unit fixtures | ~10s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `task test:conformance:report` | Print conformance numbers from snaps | <1s |
| `task test:oxc-corpus:fetch` | Fetch all OXC corpora | ~2 min |
