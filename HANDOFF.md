# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript / TypeScript / JSX / TSX parser written in Odin that emits ESTree-compatible JSON ASTs. Three-pass pipeline: SIMD lexer → permissive Pratt parser → opt-in semantic checker. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing. Mirrors OXC's `oxc_parser` / `oxc_semantic` split — parser builds the tree permissively, checker enforces ECMA-262 early errors.

## Current State (2026-05-14, session 11)

### Build
```
$ odin build src -out:bin/kessel -o:speed -no-bounds-check
```
Clean success. No warnings. Binary: `bin/kessel` (Mach-O arm64).
Toolchain: `odin version dev-2026-04:df6fff6e4`, Apple M1 Max, Darwin arm64.

### Tests
**Primary gate** (`task test`): **All pass.**
- Coverage harness: 23 tests (was 24 — semantic_typescript removed). All successful.
- Unit fixtures: 291 passed, 0 failed, 100%.

### Conformance — Kessel vs OXC (OXC = 100%)

Same corpus SHAs. Same exclude list. Same fixture granularity.

```
                       Kessel               OXC
TS positive:           9773/9828 (99.44%)   9818/9832 (99.86%)
TS parser negative:    1378/2583 (53.35%)   1532/2587 (59.22%)
  → Kessel catches 89.95% of what OXC catches (1378/1532)

Babel parser positive: 2235/2237 (99.91%)
Babel semantic neg:    1678/1725 (97.28%)

test262 parser:        47090/47090 (100%)
test262 semantic:      4588/4588  (100%)

ESTree:                39/39 (100%)
```

Corpus SHAs (pinned to OXC's `clone-parallel.mjs`):
- TypeScript: `f350b523`
- Babel: `4079bcda`
- ESTree: `9c67f5e3`

## What To Work On Next

### PRIORITY 1 — Move 6 checker-only catches to parser level

**Critical architectural debt.** These checks exist in `src/checker.odin` but OXC catches them at parser level. They must move to `src/parser.odin` so they appear in the parser snap. Without this, our TS parser negative stays at 53% instead of approaching OXC's 59%.

Each migration: move the detection logic from checker → parser, verify the parser snap gains the catches, then remove the checker-side code.

#### 1. `__proto__` redefinition (44 OXC hits on babel)
- **Checker**: `ck_check_object_proto_dups` (checker.odin:4976-4995)
- **Parser target**: `parse_object_expression` — already iterates all properties. Was in parser before session 8, moved to checker. **Revert the move.**
- **Difficulty**: low (the parser code existed before, just restore it)

#### 2. TS2391 — Function implementation missing / overload chain (11 OXC hits)
- **Checker**: `ck_check_ts_class_overloads` (checker.odin:1778-1903)
- **Parser target**: post-parse validation in `parse_class_body` — parser already iterates class elements. Add overload-chain walk after the body is built.
- **Difficulty**: medium (chain logic is ~120 lines, needs `method_fn_has_body` + `elem_overload_name` helpers)

#### 3. Abstract methods in non-abstract class (6 OXC hits)
- **Checker**: inline check in `ck_walk_class` (checker.odin:4684-4689)
- **Parser target**: `parse_class_body` — parser knows `p.class_is_abstract` (set by `parse_class_declaration`). Walk elements after body parse, reject abstract members when class isn't abstract.
- **Difficulty**: low (5-line check)

#### 4. `abstract` + private identifier (3 OXC hits)
- **Checker**: `ck_check_ts_class_modifier_conflicts` (checker.odin:2279-2293)
- **Parser target**: `parse_class_element` — parser already has `is_abstract` and `is_private` flags. Add check after modifier scanning.
- **Difficulty**: low (single if-statement)

#### 5. Label already declared (3 OXC hits)
- **Checker**: `ck_check_label_dup` (checker.odin:6336)
- **Parser target**: `parse_labelled_statement` — parser already maintains `p.label_stack`. Add duplicate check on push.
- **Difficulty**: low (scan label_stack for duplicate name)

#### 6. Private fields through `super` (1 OXC hit)
- **Checker**: `ck_check_member_super_private` (checker.odin:5243-5248)
- **Parser target**: `parse_member_expression` — parser sees `super.#priv` at parse time. Check if object is `Super` and property is `PrivateIdentifier`.
- **Difficulty**: low (single if-statement)

#### Also verify parser-side coverage for partially-migrated checks:
- **`static + abstract`** (15 OXC hits) — 2 parser refs exist but may not cover all cases
- **`import type` violations** (65 OXC hits) — 15 parser refs but OXC catches more
- **Statements in ambient** (29 OXC hits) — 65 parser refs, likely good coverage but verify

### PRIORITY 2 — Fix 45 TS parser false positives

45 valid TS files kessel incorrectly rejects (OXC has 14). These are real bugs exposed by the session 11 coverage alignment. Investigate each `Expect to Parse` entry in `parser_typescript.snap`.

### PRIORITY 3 — Close remaining TS parser negative gap

After Priority 1, we'll catch ~70 more negatives (moving from checker to parser). The remaining gap to OXC's 1532 is ~84 fixtures. Cluster by error message and fix the largest groups.

## Session 11 Changes (14 commits)

**Parser fixes (+4 babel parser positive):**
1. fix(parser): `static` ASI in class bodies — `static\nconstructor(){}` is a static method, not ASI
2. fix(parser): reset `in_static_block` in class field initializers — `await` as identifier in nested class
3. fix(parser): static block + arrow block bodies use function-scope semantics — `var+function` coexistence
4. fix(parser): skip dup-constructor check in TS mode — defer to checker for overloads

**Coverage infrastructure (critical alignment):**
5. fix(coverage): collapse TS multi-file fixtures to match OXC per-file granularity
6. chore: sync corpus SHAs + error exclude list with OXC
7. fix(coverage): match OXC's per-fixture variant baseline lookup (module/target/jsx/preserveconstenums/usedefineforclassfields/experimentaldecorators only)
8. fix(coverage): force-positive 39 fixtures matching OXC classification
9. fix(coverage): drop `semantic_typescript` — OXC has no equivalent
10. revert(checker): remove 3 TS-only checker additions (TS1243, TS2385, TS2491) — no OXC target

**Net session 11 impact:**
- TS fixture count aligned: 12411 vs OXC 12419 (was 16162 vs 12419)
- TS parser negative denominator aligned: 2583 vs OXC 2587 (was 3498)
- Babel parser positive: 2227→2235 (+8, new corpus has more fixtures)
- Babel semantic positive: 2222→2223 (+1, TS2385 FP removed)

## Commands Reference

| Command | Purpose | Time |
|---|---|---|
| `task build` | Release binary → `bin/kessel` | ~5s |
| `task test` | **Primary gate** — 23 coverage snap tests + 291 unit fixtures | ~10s |
| `task test:coverage` | Just coverage snap gate | ~7s |
| `task test:coverage:update` | Regenerate all snap baselines | ~5s |
| `task test:conformance:report` | Print conformance numbers from snaps | <1s |
| `task test:oxc-corpus:fetch` | Fetch all OXC corpora (TS + Babel + ESTree) | ~2 min |
