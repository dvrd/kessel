# Handoff — Kessel

**Date:** 2026-05-06 (continued, second wave)
**Tip:** `02b1661 perf: restore <-OXC ratio via SIMD + lazy module pre-scan (slice 4) + bench relock`
**Branch:** `main`, ahead of `origin/main` by **3 commits** (this session's slices 3 + 4 + bench relock).

## What is Kessel

JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing, hand-written Pratt expression parser. Three-pass architecture (lexer → permissive parser → opt-in semantic checker) modelled on OXC's `oxc_parser` + `oxc_semantic` split. The CLI exists for development; the real consumer is a future toolchain pipeline (linter / transformer / bundler / codegen).

---

## Session Highlights (2026-05-06, second wave)

| Item | Before | After |
|---|---|---|
| **Architecture deepening chain** | 5/5 actionable | **5/5 actionable + 4 checker slices** |
| **Perf vs OXC** (geo-mean, 10-file `bench:quick`) | 1.28x SLOWER | **0.94x — 9 of 10 files below OXC** |
| `task test:real` | 467/467 | **467/467** |
| `task test:negative` | 86 rejected, 0 accepted-bug | **86/0** (unchanged) |
| `task test:test262:subset` | 66/66 | **66/66** (unchanged) |
| `task test:oxc-corpus` | 1 kessel-only-reject | **0 kessel-only-rejects** (-1 improvement) |
| `task test:bench:regression` | 33.7% over tolerance (system drift) | **0.1% over (relocked clean)** |
| `task test` chain | stops at recovery #8/18 | same — recovery cascade is the only red gate |
| `src/checker.odin` | 630 lines, 2 slices | **697 lines, 3 slices** (accessor checks migrated out of parser) |
| `src/parser.odin` | 19 677 lines | 19 778 lines (+101: lazy pre-scan plumbing, -34: accessor checks) |

3 commits added this session on top of `f0a7eff`:

1. `9fabda0` — feat(checker): slice 3 — migrate accessor checks parser → checker
2. `5ece470` — perf: restore <-OXC ratio via SIMD + lazy module pre-scan (slice 4)
3. `02b1661` — test(bench): relock bench_baseline.json post-perf-restore

---

## Current State

### Build

| Command | Result | Time |
|---|---|---:|
| `task build` (release) | ✅ clean, no warnings | 31 s cold |
| `odin build src -vet` | ✅ no warnings in any file touched this session | — |

### Tests — every gate run this session

| Gate | Result | Notes |
|---|---|---|
| `task test:unit` | ✅ **430/430 pass** | |
| `task test:negative` | ✅ rejected 139, accepted-bug 0 | |
| `task test:ambiguity` | ✅ baseline OK | |
| `task test:regression` | ✅ 11/11 pass | |
| `task test:real` | ✅ **467/467** | |
| `task test:estree` | ✅ all OK | |
| `task test:nodes` | ✅ 57/57 ESTree node types | |
| `task test:recovery` | ❌ **30/31** | Same pre-existing `006_jsx_fragment_broken.js` cascade. Reproduces with this session's commits stashed out. |
| `task test:lexical` | ✅ baseline OK | |
| `task test:invariants` | ✅ 467/467 + zero-tolerance OK | |
| `task test:spec-compliance` | ✅ baseline OK | |
| `task test:spec-fixtures` | ✅ **150/150 pass** | |
| `task test:test262` | ✅ 66/66 pass | |
| `task test:test262:subset` | ✅ **66/66** (baseline) | |
| `task test:multi-parser` | ✅ deep JSON compare passes vs babel | |
| `task test:fuzz` | ✅ 100/100, 0 baselined | seed=20260421 |
| `task test:fuzz:invalid` | ⚠️ 8/8 baselined crashes still reproduce | Pre-existing input-validation gaps. |
| `task test:crashes-known` | ✅ 0 new crashes | |
| `task test:oxc-corpus` | ✅ baseline OK, **0 kessel-only-rejects** | Down from 1 (was 776 in 2025). |
| `task test:bench:regression` | ✅ **0.1% over tolerance** (relocked) | |

`task test` (full chain) **still stops at `test:recovery`** because of the pre-existing `006_jsx_fragment_broken.js` cascade. Run downstream gates individually to verify they're green; this is mechanical, not a real defect.

### Performance — `task bench:quick`

Apples-to-apples (`kessel --ast-only` vs OXC parser-only) on Apple M1 Max:

| File | Size | kessel min | oxc min | ratio | vs s25-end |
|---|---:|---:|---:|---:|---:|
| typescript.js | ~9.8 MB | 34 046 µs | 34 678 µs | **0.98x** | 0.96x |
| cesium.js | ~3.5 MB | 29 720 µs | 30 189 µs | **0.98x** | 0.97x |
| monaco.js | ~3.5 MB | 26 651 µs | 26 910 µs | **0.99x** | 0.96x |
| antd.js | ~6.5 MB | 18 038 µs | 18 604 µs | **0.97x** | 0.96x |
| jquery.js | 281 KB | 1 359 µs | 1 328 µs | 1.02x (parity) | 0.97x |
| d3.js | 624 KB | 4 077 µs | 4 227 µs | **0.96x** | 0.92x |
| react-dom.dev.js | 1.1 MB | 3 113 µs | 3 370 µs | **0.92x** | 0.90x |
| preact.js | 30 KB | 110 µs | 129 µs | **0.85x** | 0.80x |
| lodash.js | 543 KB | 1 127 µs | 1 184 µs | **0.95x** | 0.98x |
| snabbdom.js | 4 KB | 2.5 µs | 3.1 µs | **0.80x** | 0.80x |

**Geo-mean ~0.94x of OXC.** 9 of 10 files are now below OXC (kessel faster); jquery.js sits at parity (1.02x). This restores the s25-era performance that was lost between commits f0c1201 and HEAD before this session.

---

## Project Structure

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 19 778 | Hand-written Pratt parser + lazy module pre-scan + ~100 inline `report_semantic_error*` checks (gated on `p.check_semantics`). Parser stays a syntax recogniser; semantic checks live in pass 3. |
| `src/emitter.odin` | 6 381 | ESTree JSON emitter. |
| `src/lexer.odin` | 3 096 | SIMD lexer. Two-token lookahead. |
| `src/regex.odin` | 2 235 | ES2025 §22.2.1 regex pattern validator. |
| `src/ast.odin` | 1 611 | All AST struct/union definitions. |
| `src/raw_transfer.odin` | 1 302 | Zero-copy binary AST buffer. |
| `src/main.odin` | 1 295 | CLI dispatch + worker pool. |
| **`src/checker.odin`** | **697** | **AST-walker semantic checker (pass 3).** Slice 1: break/continue + label scoping. Slice 3: getter/setter accessor arity + setter rest/initializer. Public API: `check_program`, `checker_run_for_job`. |
| `src/simd.odin` | 598 | ARM64 NEON intrinsics. New: `simd_find_module_pre_scan_candidate`. |
| `src/parse_job.odin` | 419 | "Source-to-parsed-Program" deep module. `cli.show_semantic_errors → cfg.check_semantics → p.check_semantics`. |
| `src/token.odin` | 383 | `TokenType` enum, `FastToken`, `LiteralValue`. |
| `src/unicode_tables.odin` | 329 | Unicode 17.0.0 ID range tables. |
| `src/cli_config.odin` | 188 | `CliConfig` struct, `cli_try_parse_flag`. |
| `src/source_io.odin` | 103 | Cross-platform source reader. |
| `src/source_io_posix.odin` | 69 | POSIX mmap path. |
| `src/qos_darwin.odin` | 61 | Apple Silicon QoS hint. |
| `src/source_io_other.odin` | 17 | Windows stub. |
| **Total** | **38 562** | |

---

## Architecture: pass 3 (semantic checker) — slices completed

| Slice | Commit | Coverage |
|---|---|---|
| **1** | `4b93e2a` | break / continue context + label scoping (§13.9.1, §13.9.2, §14.13.1, §14.8.1). New AST walker `check_program` + `checker_run_for_job`. Function/arrow/class-static-block boundaries. |
| **2** | `86cd68b` | Wire `cli.show_semantic_errors → ParseConfig.check_semantics → p.check_semantics`. ~100 inline `report_semantic_error*` calls in parser.odin now light up under the same flag. Setter/getter check demoted from `report_error` to `report_semantic_error_at` with anchored locations (fixes three.module.js positional bug). |
| **3** | `9fabda0` | **Migrate** the 4 accessor early-error checks parser → checker. New `ck_check_accessor` walks ClassElement nodes, emits at proper locations. Parser strictly drops these — no `report_semantic_error*` for them anymore. |
| _next_ | _slice 4+_ | Migrate remaining ~100 inline `report_semantic_error*` calls slice-by-slice (super.x, new.target, duplicate __proto__, strict-mode parameter validation, duplicate private members, eval/arguments in strict mode, with statement in strict mode, duplicate exported names, ...). Each slice removes the inline call AND adds the AST-walk equivalent. The architectural rule: **parser handles syntax, checker handles semantics**. |

---

## Architecture: lazy module pre-scan (slice 4 perf fix)

The pre-scan in `pre_scan_for_module_syntax` was added in commit `f0c1201` to detect top-level `import`/`export` BEFORE the parser starts, so `await` in code like `let x = await; export {}` would resolve as keyword. Original implementation:

- Byte-by-byte state machine.
- Ran unconditionally on every auto-detect JS/JSX file.
- Cost: ~21 ms on a 9 MB CJS bundle (typescript.js).

Three independent fixes restored sub-OXC perf:

1. **SIMD acceleration**: new `simd_find_module_pre_scan_candidate` skips 16 boring bytes per ARM64 NEON cycle. Reuses the existing `simd_skip_line_comment` / `simd_skip_block_comment` / `simd_find_string_end` helpers from the lexer hot path.

2. **Lazy trigger**: pre-scan no longer runs upfront. New helper `ensure_module_syntax_resolved` runs it on demand, only from the four constructs whose validity depends on the answer being available BEFORE the parser reaches an explicit `import`/`export` token: top-level `await`, `for await`, `using`, `await using`. `module_pre_scan_done` cache prevents repeated scans.

3. **Match OXC for await-in-binding**: `await_is_reserved_here` previously kept a V8/Babel-strict module check that f0c1201 had originally removed. Per the conformance oracle (OXC), `export var await`, `export function await(){}`, `let await = 1` in module top-level binding positions are accepted. The strict module gate removed; this also removes the only hot-path lazy-scan trigger on real-world bundles (TLA expression position alone doesn't fire the scan because most awaits are inside async functions and short-circuit on `p.in_async`).

Side fixes:
- `parse_import_declaration` / `parse_export_declaration` now save/restore `p.has_module_syntax` around namespace-body imports/exports so nested `export const X = 1` inside a TS namespace doesn't leak module classification.
- `parse_ts_module_tail` now propagates `p.in_ts_namespace` into nested-name (e.g. `namespace Outer.Inner`) bodies, fixing a pre-existing context-tracking bug.

Result: 9/10 bench files below OXC, geo-mean ~0.94x (was 1.28x, target was s25-end's 0.93x).

---

## Architecture decisions made this session

| Decision | Why | Alternative considered |
|---|---|---|
| **Slice 3 done as REAL migration, not flag-gating** | Slice 2 had taken a shortcut (gate inline checks on `p.check_semantics`). Slice 3 honours the architectural rule: parser = syntax, checker = semantics. Each future slice removes the corresponding inline check AND adds the AST-walk equivalent. | Leave slice 2's gating in place. Rejected — leaves the parser bloated with semantic concerns that don't belong there. |
| **Pre-scan made lazy + SIMD, not removed** | Removing entirely loses correctness for a real (if rare) edge case (`for await` / TLA before `import`/`export`). Lazy + SIMD keeps correctness AND restores perf. | Remove the pre-scan unconditionally. Rejected — breaks `tests/fixtures/es2025/011_for_await_before_export.js`. |
| **Match OXC on await-in-module-binding** | OXC is kessel's conformance oracle for the OXC corpus. The strict V8/Babel behaviour was making 2 corpus fixtures kessel-only-rejects. The looser OXC behaviour (a) matches the oracle, (b) removes the only hot-path lazy-scan trigger. | Keep V8/Babel strict (`await` reserved as binding in modules). Rejected — drives 2 corpus regressions and forces a hot-path lazy scan that costs ~17ms on real bundles. Tradeoff documented in code. |
| **Save/restore `has_module_syntax` around namespace-body imports/exports** | Inline `p.has_module_syntax = true` writes happen at multiple points in `parse_import_declaration` / `parse_export_declaration` (downstream procs do it too). A save/restore wrapper at the entry catches all of them at once, so a malformed-import recovery path can't pollute the file's classification. | Gate every individual write site on `!p.in_ts_namespace`. Rejected — error-prone (8+ sites, easy to miss one in future migrations). |
| **`parse_ts_module_tail` propagates `in_ts_namespace`** | Pre-existing bug: dotted namespaces (`namespace Outer.Inner`) didn't set the flag for the inner body. Surfaced by the slice-4 namespace-body-export edge case. Fix is one save/set/defer triad next to the existing `in_ambient` plumbing. | Refactor namespace parsing to consolidate the flag handling. Rejected as scope creep. |

---

## Known Issues

`grep -rnE "TODO\|FIXME\|HACK\|BUG\|WORKAROUND" src/` — empty.

| # | Issue | Severity | Where | Note |
|---|---|---|---|---|
| 1 | `tests/fixtures/recovery/jsx_ts/006_jsx_fragment_broken.js` produces 15 cascading errors | **annoying** (blocks `task test:recovery`, **and `task test` chain stops here**) | `<><span id=></span></>` triggers a JSX-attribute-RHS recovery cascade. Runner threshold is 10. | Pre-existing; reproduces with all of this session's commits stashed out. After this gate is fixed, `task test` will run all 18 gates clean. |
| 2 | `task test:fuzz:invalid` 8/8 baselined crashes still reproduce | **annoying** | bit-flipped / NUL-injected / UTF-8-broken fuzz inputs. | Reproducer files in `tmp/fuzz_invalid_crashes/`. Each is a real input-validation gap. |
| 3 | OXC corpus has 2 161 → 2 157 → **2 157** "babel should-pass-rejected" | **shared gap with Babel** | Babel-specific syntax (Flow, pipeline-operator, experimental decorators). Not kessel bugs — OXC drops them too. | |
| 4 | OXC corpus has **0 kessel-only-rejects** + 1 oxc-only-reject | (improved) | Was 1 → 0 this session. | |
| 5 | `src/checker.odin` covers only break/continue + label scoping + accessor checks (3 slices) | **next slices** | The remaining ~100 inline `report_semantic_error*` calls in parser.odin haven't been migrated. Each future slice removes one category. | See the architecture decision rule: parser = syntax, checker = semantics. |
| 6 | `AGENTS.md` is `.gitignore`d | local-only | My in-session edits to AGENTS.md (refreshed source layout / perf claims) live only on this disk. They won't propagate via push/clone. By project convention `AGENTS.md` is local agent prose, not shared. The HANDOFF doc covers all material info. | |

---

## Incomplete Work

| Item | State | What remains |
|---|---|---|
| **Architecture deepening chain (5/5 actionable + #4 deferred)** | **Complete** | #4 (shared AST traversal module) intentionally deferred — premature unless concrete vocabulary emerges. |
| **#3 semantic checker migration** | **3 slices done, ~100 sites remaining** | Migrate categories slice-by-slice (super.x, new.target, duplicate __proto__, strict-mode parameter validation, duplicate private members, eval/arguments in strict mode, with statement in strict mode, duplicate exported names, ...). See `src/checker.odin` top doc-comment for the inventory. **Each slice must remove the inline check AND add the AST-walk equivalent — no flag-gating shortcuts.** |
| **Perf vs OXC** | **Restored to s25-era 0.94x geo-mean** | Future perf wins beyond s25 are exploratory. The W-cadence record (`docs/perf-session-22-final.md` … `perf-session-25-*.md`) documents what was tried and what worked. |
| `006_jsx_fragment_broken.js` recovery cascade | Pre-existing | Reduce cascade ≤10 (runner threshold) by improving JSX-attribute-RHS recovery in `parse_jsx_attribute`. |
| 8 baselined fuzz crashes | Tracked | Reproducers in `tmp/fuzz_invalid_crashes/`. |

`git stash list` empty. No WIP. Branch ahead of origin/main by 3 commits this session.

---

## What To Work On Next

Prioritised:

1. **Continue checker migration (slice 4+)** — pick the next category from `src/checker.odin`'s doc-comment.
   - **Easiest next slices:** duplicate `__proto__` in object literal (single ObjectExpression node, simple O(n²) within one object, rule is local), `super` outside method (ancestor walk, similar shape to break/continue).
   - **Approach (proven by slices 1–3):**
     1. Implement the AST walk in `checker.odin` (extend the `ck_walk_*` chain or add a per-element check like `ck_check_accessor`).
     2. **Delete** the corresponding `report_semantic_error*` call in `parser.odin`. Don't leave it gated.
     3. Run the full gate chain. Relock baselines if any negative fixtures earn rejections.

2. **Investigate `006_jsx_fragment_broken.js`** — reduce the 15-error cascade to ≤10. Once fixed, `task test` runs all 18 gates clean.
   - **Where:** `src/parser.odin` — `parse_jsx_attribute` and the recovery path when the attribute RHS is missing (`<span id=></span>`).

3. **Investigate 8 baselined fuzz crashes** — each is a real input-validation gap.
   - **Where:** Reproducer files in `tmp/fuzz_invalid_crashes/`.

4. **(Deferred — architecture review #4)** Shared AST traversal module
   - **When to revisit:** Once slice 4+ surfaces a third concrete pattern that maps cleanly onto the emitter / raw-transfer / checker walkers.

---

## Commands Reference

```bash
task build                # release → bin/kessel (31s)
task test:unit            # ✅ 430/430
task test:negative        # ✅ rejected 139, 0 accepted-bug
task test:test262         # ✅ 66/66
task test:test262:subset  # ✅ 66/66 (baseline)
task test:real            # ✅ 467/467
task test:oxc-corpus      # ✅ baseline OK, 0 kessel-only-rejects
task test:estree          # ✅
task test:nodes           # ✅ 57/57
task test:recovery        # ❌ 30/31 (006_jsx_fragment_broken pre-existing)
task test:lexical         # ✅
task test:invariants      # ✅ 467/467 + zero-tolerance OK
task test:spec-compliance # ✅
task test:spec-fixtures   # ✅ 150/150
task test:multi-parser    # ✅
task test:fuzz            # ✅ 100/100
task test:fuzz:invalid    # ⚠️ 8/8 baselined
task test:crashes-known   # ✅ 0 new
task test:ambiguity       # ✅
task test:regression      # ✅ 11/11
task test:bench:regression # ✅ 0.1% over (relocked clean)
task bench:quick          # 10 representative files; 9/10 below OXC, geo-mean 0.94x
```

### Pass-3 / semantic checker

```bash
# Default — parser only (matches OXC parseSync)
./bin/kessel parse foo.js

# With pass 3 — break/continue/label + accessor checks + ~100 inline checks fire
./bin/kessel parse foo.js --show-semantic-errors

# Test262 subset, the verifier passes the flag automatically
task test:test262:subset
```
