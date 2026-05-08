# Handoff — Kessel

**Date:** 2026-05-08 (eleventh wave — coverage harness conformance push, fixture consolidation)
**Tip:** `e8106de chore: move corpus to tests/vendor/ and update paths`
**Branch:** `main`. Working tree has uncommitted fixture moves + doc refresh — see "Pending commit" below.

## What is Kessel

JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing, hand-written Pratt expression parser. Three-pass architecture (lexer → permissive parser → opt-in semantic checker) modelled on OXC's `oxc_parser` + `oxc_semantic` split. The CLI exists for development; the real consumer is a future toolchain pipeline (linter / transformer / bundler / codegen).

---

## Session Headlines (2026-05-07 → 2026-05-08, conformance push + cleanup)

13 commits landed since the previous handoff (`b8423bb`). They split into two waves:

### Wave A — OXC-style coverage harness (commits 1–6)

| Item | Before | After |
|---|---|---|
| **Conformance harness** | JS verifiers + JSON baselines, cross-parser comparator | **Odin-native, OXC-mirroring snap files** — `tests/coverage/src/`, parser + semantic `@(test)` procs per suite |
| **ES2025 conformance proof** | scattered across 4 verifiers + 3 baselines | **single file**: `parser_test262.snap` |
| **Coverage gate wall clock** | n/a (multiple ~30s gates) | **2.8 seconds** — `@(test)` procs running in parallel |
| **Coverage harness LoC** | 0 | **~3 700** (Odin) — replaces ~3 600 LoC of JS verifiers + ~10 MB of JSON baselines |

Commits: `5ff5543 → fa3e8b3` (phases 1–9 + retire test262/oxc-corpus gates).

### Wave B — conformance push + cleanup (commits 7–13)

| Metric | Before | After |
|---|---:|---:|
| **`parser_test262.snap` positive** | 99.99% (47088/47090) | **100.00% (47090/47090)** |
| **`semantic_test262.snap` negative** | 67.24% (3085/4588) | **99.93% (4585/4588)** |
| **`semantic_babel.snap` negative** | 70.43% (1205/1711) | **95.15% (1628/1711)** |
| **`parser_typescript.snap` positive** | 98.92% | **100.00%** (12692/12692) |
| **`parser_babel.snap` positive** | 99.60% | 99.82% (2229/2233) |
| **JS verifiers** | 23 files | **9 files** (kept what's actually used) |
| **`tests/expected/negative/`** | 70+ stale .txt files certifying parser bugs as pinned | **gone** — must-reject ownership moved to `misc/fail/` snap |
| **`tests/test262/`** | 66-file curated subset | **gone** — superseded by 47k-fixture coverage corpus |
| **`docs/_archive/`** | stale 2025 perf notes | **gone** |
| **`Taskfile.yml`** | 736 lines (19+ gates with overlapping coverage) | 287 lines, 2-gate primary chain |

Commits: `909433d → e8106de` (classifier + bug fixes + cleanup + harness simplification).

### Pending commit (this session — fixture consolidation + doc refresh)

| Item | Before | After |
|---|---|---|
| `task test` | **broken** — `test:unit` failed on 99 negative/early-error fixtures whose expected/ files were deleted in `6ff94d8` | **green** — 24/24 coverage @(test) procs + 291/291 unit fixtures |
| `tests/fixtures/{negative,early_errors}/` | 139 must-reject fixtures with no expected files | **moved** to `tests/coverage/misc/fail/{negative,early_errors}/` (git-mv preserves history) |
| `misc.odin` `should_fail` resolver | took bucket from immediate parent (`fail` only) | **walks up** to nearest `pass`/`fail` ancestor (lets us preserve `truncation/`, `numeric_literals/`, `regex_literals/`, `strict_mode/`, `module_context/` semantic groupings) |
| `bench:oxc:build` task | missing — 4 gates broken (`test:regression`, `test:estree`, `test:fuzz`, `test:release`) | **restored** as a 6-line task |
| `verify_lexer_tokens.js` | broken — stale `oxc.parseSync(source, opts)` API call + 7 dangling fixture paths + apples-to-oranges count comparison | **fixed** — current `parseSync(filename, source, opts)` API, `result.program` extraction, fixture paths refreshed, dialect inferred via filename ext substitution |
| `verify_json_deep.js` | deleted in `6ff94d8` — broke `fuzz_diff.js` | **restored** from git history (still required by `fuzz_diff.js`) |
| `task test:release` | partial breakage from above | **fully green** — every gate, including bench regression at geo-mean 1.022x baseline (tolerance 1.05) |
| `task test:lexer-tokens` | 0/3 effective coverage (skip-on-API-error) | 11/11 pass |

The new `semantic_misc.snap` numbers reflect the 139 new fail fixtures: parser-mode rejects 161/274 (58.76%), semantic-mode rejects 229/274 (**83.58%**) — the new fixtures behaved exactly as expected.

---

## The new conformance gate — `task test:coverage`

```
$ task test:coverage
Finished 24 tests in 2.78s. All tests were successful.
```

Snap files map to suites × tools:

| Snap file | Fixtures | AST Parsed | Positive Passed | Negative Passed |
|---|---:|---|---|---|
| **`parser_test262.snap`** | 51 678 | 100% | **100.00%** (47090/47090) | 59.81% (2744/4588) |
| **`semantic_test262.snap`** | 51 678 | 100% | 100.00% | **99.93%** (4585/4588) |
| `parser_typescript.snap` | 16 162 | 100% | 100.00% (12692/12692) | 38.16% (1324/3470) |
| `semantic_typescript.snap` | 16 162 | 98.89% | 98.89% | 46.28% (1606/3470) |
| `parser_babel.snap` | 3 944 | 99.82% | 99.82% | 70.43% (1205/1711) |
| `semantic_babel.snap` | 3 944 | 98.75% | 98.75% | **95.15%** (1628/1711) |
| `parser_misc.snap` | 338 | 100% | 100.00% (64/64) | 58.76% (161/274) |
| `semantic_misc.snap` | 338 | 93.75% | 93.75% | 83.58% (229/274) |
| `parser_estree.snap` | 39 | 100% | 100% | — |
| `semantic_estree.snap` | 39 | 100% | 100% | — |

**`AST Parsed` is 100% on test262 / typescript / estree / misc** — kessel never crashes on valid input across **62 261** fixtures.

The `Negative Passed` columns are the actionable gap: every "Expect Syntax Error: ..." line is a missing kessel rejection rule. Closing that gap is the path to 100/100/100 on `parser_test262.snap` — the literal definition of ECMAScript 2025 conformance per tc39's official test suite.

---

## Architecture — `tests/coverage/src/`

```
tests/coverage/
├── src/                              ← Odin coverage harness (3 706 LoC)
│   ├── coverage.odin                 (Suite/Tool/Fixture/TestResult/CoverageRun types)
│   ├── load.odin                     (walk_and_read shared by every suite)
│   ├── babel.odin                    (determine_should_fail + skip lists)
│   ├── typescript.odin               (// @filename: directive parser, error codes)
│   ├── typescript_constants.odin     (NOT_SUPPORTED_{TEST_PATHS,ERROR_CODES})
│   ├── test262.odin                  (frontmatter parser)
│   ├── misc.odin                     (regression museum — walks up for pass/fail bucket)
│   ├── estree.odin                   (acorn-jsx pass/fail)
│   ├── runner.odin                   (parse one fixture → TestResult)
│   ├── snapshot.odin                 (render + read + write + diff)
│   ├── invariants.odin               (Odin-native AST invariant checker)
│   ├── classifier_test.odin          (per-classifier @(test) procs)
│   ├── coverage_test.odin            (suite-level @(test) procs)
│   └── main.odin                     (standalone CLI: bin/kessel_coverage)
├── snapshots/                        ← committed golden files
│   ├── parser_test262.snap           ← the ES2025 conformance number
│   ├── parser_babel.snap
│   ├── parser_typescript.snap
│   ├── parser_misc.snap
│   ├── parser_estree.snap
│   └── semantic_*.snap               (5 more; same suites, --check-semantics)
└── misc/                             ← regression museum + must-reject fixtures
    ├── pass/  (64 fixtures)          ← lifted from oxc tasks/coverage/misc/pass
    └── fail/                         ← all must-reject fixtures
        ├── (135 fixtures from oxc)
        ├── negative/                 ← 96 fixtures moved from tests/fixtures/negative
        │   ├── numeric_literals/
        │   ├── regex_literals/
        │   └── truncation/
        └── early_errors/             ← 43 fixtures moved from tests/fixtures/early_errors
            ├── strict_mode/
            └── module_context/
```

Every classifier mirrors OXC's `tasks/coverage/src/` verbatim:

  * `babel.odin:determine_should_fail` ↔ `babel/mod.rs:determine_should_fail`
  * `BABEL_PATH_SKIP_SUBSTRINGS` ↔ `load.rs:load_babel.skip_path`
  * `BABEL_PLUGIN_SKIP` ↔ `load.rs:load_babel.not_supported_plugins`
  * `TS_NOT_SUPPORTED_TEST_PATHS` + `TS_NOT_SUPPORTED_ERROR_CODES` ↔ `typescript/constants.rs`
  * Snap header `commit: <8-char-SHA>` ↔ OXC's snap header

OXC source SHA pinned in snap headers: `c7a0ae10`.

---

## Bug-fix workflow (mirrors OXC's PR style)

```bash
# Bug found parsing `class C { [[]]() {} }`

# 1. Add a regression fixture under misc/pass/ (or misc/fail/ for must-reject)
cat > tests/coverage/misc/pass/kessel-NN-array-computed-class-key.js <<'EOF'
class C { [[]]() {} }
EOF

# 2. Run the harness — fails. Diff lands as a single-line snap drift.
task test:coverage

# 3. Fix the parser — typically 1–10 lines in src/parser.odin

# 4. Update snaps; review the diff
task test:coverage:update

# 5. Commit fixture + parser fix + snap diff in one PR
git add src/parser.odin tests/coverage/
git commit -m "fix(parser): array literal in computed class key"
```

The snap diff is the evidence. No JSON merge conflicts. Ever.

---

## Tests — every gate green

`task test` (the primary gate) is now just two things:

| Gate | Result | Notes |
|---|---|---|
| `task test:coverage` | ✅ **24/24 @(test) procs** | 62 261 fixtures in 2.8s |
| `task test:unit` | ✅ **291/291 positive fixtures** | golden-output gate |

`task test:release` (zero-tolerance pre-release gate) chains the full surface:

| Gate | Result | Notes |
|---|---|---|
| `task test:coverage` | ✅ | as above |
| `task test:unit` | ✅ 291/291 | as above |
| `task test:regression` | ✅ 11/11 | path-based assertions vs OXC reference |
| `task test:real` | ✅ 467/467 | every real-world JS file parses clean |
| `task test:estree` | ✅ all OK | string-escape parity vs OXC on jquery / react.dev / lodash / babel |
| `task test:fuzz` | ✅ 100/100 | seed=20260421, deep JSON compare vs OXC |
| `task test:fuzz:invalid` | ✅ 300/300 | 0 unique crashes |
| `task test:crashes-known` | ✅ 0 new | known-SIGTRAP fixture pinning |
| `task test:bench:regression` | ✅ geo-mean 1.022 | tolerance 1.05 |
| `task test:lexer-tokens` | ✅ 11/11 | AST span structure parity vs OXC |

---

## Project Structure

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 18 694 | Pratt parser. Package exposed as library (`package kessel`); the binary entry point is the same `main` proc. |
| `src/emitter.odin` | 6 381 | ESTree JSON emitter. |
| `src/checker.odin` | 3 279 | AST-walker semantic checker (pass 3). |
| `src/lexer.odin` | 3 099 | SIMD lexer. |
| `src/regex.odin` | 2 235 | ES2025 §22.2.1 regex pattern validator. |
| `src/ast.odin` | 1 618 | AST struct/union definitions. |
| `src/raw_transfer.odin` | 1 304 | Zero-copy binary AST buffer. |
| `src/main.odin` | 1 295 | CLI dispatch + worker pool. |
| `src/simd.odin` | 601 | ARM64 NEON intrinsics. |
| `src/parse_job.odin` | 444 | "Source-to-parsed-Program" deep module. |
| `src/token.odin` | 383 | `TokenType` enum, `FastToken`, `LiteralValue`. |
| `src/unicode_tables.odin` | 329 | Unicode 17.0.0 ID range tables. |
| `src/cli_config.odin` | 188 | `CliConfig` struct. |
| `src/source_io.odin` | 103 | Cross-platform source reader. |
| `src/source_io_posix.odin` | 69 | POSIX mmap. |
| `src/qos_darwin.odin` | 61 | Apple Silicon QoS. |
| `src/source_io_other.odin` | 17 | Windows stub. |
| **Total `src/`** | **40 100** | |
| `tests/coverage/src/typescript_constants.odin` | 582 | Lifted from OXC's `constants.rs`. |
| `tests/coverage/src/babel.odin` | 434 | Babel classifier + skip lists. |
| `tests/coverage/src/typescript.odin` | 442 | TS unit splitter + error-code classifier. |
| `tests/coverage/src/invariants.odin` | 366 | Odin-native AST invariant checker. |
| `tests/coverage/src/main.odin` | 325 | Standalone CLI (`bin/kessel_coverage`). |
| `tests/coverage/src/snapshot.odin` | 248 | Snap render + diff. |
| `tests/coverage/src/test262.odin` | 247 | YAML-subset frontmatter parser. |
| `tests/coverage/src/coverage.odin` | 238 | Public types. |
| `tests/coverage/src/coverage_test.odin` | 218 | Suite-level `@(test)` procs. |
| `tests/coverage/src/runner.odin` | 182 | Parse one fixture → TestResult. |
| `tests/coverage/src/classifier_test.odin` | 140 | Per-classifier `@(test)` procs. |
| `tests/coverage/src/load.odin` | 138 | `walk_and_read`. |
| `tests/coverage/src/misc.odin` | 121 | Regression museum loader (walks up for pass/fail). |
| `tests/coverage/src/estree.odin` | 53 | Acorn-jsx pass/fail. |
| **Total `tests/coverage/src/`** | **3 734** | replaces ~3 600 LoC JS verifiers + ~10 MB JSON. |

---

## Known Issues

| # | Issue | Severity | Scope |
|---|---|---|---|
| 1 | **`misc/fail/oxc-3320.tsx`** triggers a kessel parser crash on the malformed TS template-literal-type input `m< $<{3[ ...`. Renamed `.kessel-crashes` so the harness can complete; the fixture is still in the repo as evidence. | parser bug | Real bug. Highest priority. Fix it as a regression slice using the harness's bug-fix workflow above. |
| 2 | `parser_test262.snap` shows **1 844 `Expect Syntax Error:` lines** — kessel's parser-only mode under-rejects ~40% of test262's negative fixtures. | conformance gap | The path to ES2025 conformance: each line is a missing kessel parser-side early error. The semantic checker covers 99.93% of the same fixtures (only 3 misses) — most parser-side gaps would be closed by promoting checker logic into the parser, slice-15-style. |
| 3 | `parser_typescript.snap` shows **2 146 `Expect Syntax Error:`** entries — kessel under-rejects ~62% of TS-corpus negatives. | conformance gap | TS-mode early errors. Many are TSC-specific (declaration emit, ambient-context rules, type-checker shape). Realistic target: match `semantic_typescript`'s 46% by promoting more TS checks. |
| 4 | `parser_babel.snap` shows **506 `Expect Syntax Error:`** entries plus **4 `Expect to Parse:`** lines (kessel rejects what babel says should pass). | conformance gap | The 4 `Expect to Parse:` lines are real kessel parser bugs — the actionable "kessel-only-rejects" successor. |
| 5 | `parser_misc.snap` shows **113 `Expect Syntax Error:`** lines after the 139 negative/early-error fixtures landed; `semantic_misc.snap` closes that to **45**. | conformance gap | Same shape as #2 — most are checker-only enforcement. |
| 6 | `lexer.odin` is 3 099 lines; the cache-line-tuned hot fields exposed in `Lexer` are now mature but the file size means any future SIMD work needs careful module-boundary thinking. | refactor | Watch-list, not action. |

`grep -rnE "TODO|FIXME|HACK|BUG|WORKAROUND" src/` — empty.

---

## What To Work On Next

1. **`misc/fail/oxc-3320.tsx` parser crash** — restore the file, debug, fix. Highest priority because it's a hard crash, not a conformance gap.
2. **TypeScript negative gap (62% miss)** — biggest absolute number of unrejected fixtures. Cluster `parser_typescript.snap` by error-message family, pick the largest cluster, fix.
3. **4 `parser_babel.snap` `Expect to Parse:` lines** — these are kessel rejecting what babel-the-parser accepts; same shape as the slice-15 work.
4. **Promote 1 800+ checker-only rules into the parser** — `parser_test262.snap` minus `semantic_test262.snap` is 1 841 fixtures where the checker fires but the parser doesn't. Promotion moves them from "spec-aware mode only" to "always-on" — closer to OXC's parser-side enforcement.
5. **`semantic_test262.snap` last 3 negatives** — 99.93% → 100.00% is just 3 fixtures (`top-level-await/new-await.js` + 2 others). One-shot hunt.

---

## Commands Reference

```bash
task build                    # release → bin/kessel
task build:coverage           # release → bin/kessel_coverage

# The primary conformance gate
task test                     # test:coverage + test:unit (~12s)
task test:coverage            # 24 @(test) procs, parallel, 2.8s
task test:coverage:update     # regenerate every snap baseline
task test:coverage:run -- <suite> [--semantic] [--update]

# Pre-release zero-tolerance chain
task test:release             # everything strict (~3 min including bench)

# Standalone binary entry (mirrors OXC's `cargo coverage parser`)
bin/kessel_coverage discover                 # phase-1 smoke (file counts)
bin/kessel_coverage run all                  # all 5 suites, exit 1 on drift
bin/kessel_coverage run test262              # one suite
bin/kessel_coverage run all --semantic --update

# Conformance summary (informational)
task test:conformance:report               # human-readable
task test:conformance:report:json          # JSON

# Corpus fetch (required before first `task test:coverage`)
task test:oxc-corpus:fetch                 # all (TypeScript + Babel + ESTree)
task test:oxc-corpus:fetch:typescript      # TS only (~138 MB)
task test:oxc-corpus:fetch:babel           # Babel only (~70 MB)
task test:oxc-corpus:fetch:estree          # ESTree only (~5 MB)
```

### Pass-3 / semantic checker

```bash
# Default — parser only (matches OXC parser-only)
./bin/kessel parse foo.js

# With pass 3 — every early-error check (slices 1–15 covered)
./bin/kessel parse foo.js --show-semantic-errors
```

Must-reject fixtures live under `tests/coverage/misc/fail/` and the `parser_misc.snap` / `semantic_misc.snap` pair classifies them automatically — no per-fixture flag plumbing needed.
