# Handoff — Kessel

**Date:** 2026-05-06 (continued)
**Tip:** `86cd68b feat(checker): wire --show-semantic-errors to inline parser checks (slice 2)`
**Branch:** `main`, ahead of `origin/main` by **20 commits** (architecture deepening + checker slices 1 & 2 — see git log).

## What is Kessel

JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing, hand-written Pratt expression parser. Three-pass architecture (lexer → permissive parser → opt-in semantic checker) modelled on OXC's `oxc_parser` + `oxc_semantic` split. The CLI exists for development; the real consumer is a future toolchain pipeline (linter / transformer / bundler / codegen).

---

## Session Highlights (2026-05-06 continued)

| Item | Before | After |
|---|---|---|
| **Architecture deepening chain** | 4 of 5 actionable done | **5 of 5 actionable done** — `#3 (semantic checker)` shipped in 2 slices |
| `task test:real` | 466/467 (three.module.js fail) | **467/467 PASS** |
| `task test:negative` (accepted-bug count) | 53 negative fixtures wrongly accepted | **0** — every negative fixture rejected |
| `task test:test262:subset` | 64/66 (2 unexpected_fails) | **66/66** |
| `task test:oxc-corpus` | should-pass-rejected: 2161 | should-pass-rejected: 2157 (-4 improvement) |
| `src/checker.odin` | 62-line stub | **630 lines, live AST walker** |
| `--show-semantic-errors` flag | parsed but read by no consumer | **wired through** ParseJob → parser + checker |
| README perf claim | "geo-mean ~1.00x of OXC (parity)" — stale | accurate (~1.28x; tiny files 0.79x) |

5 commits added this session on top of `ea69165`:

1. `6eb7cfa` — docs: HANDOFF.md refresh
2. `12910c4` — test(baselines): relock negative + test262:subset
3. `5a1d66d` — docs(readme): refresh source layout + unit fixture count
4. `4b93e2a` — feat(checker): semantic checker slice 1 — break/continue + label scoping
5. `86cd68b` — feat(checker): wire --show-semantic-errors to inline parser checks (slice 2)

---

## Current State

### Build

| Command | Result | Time |
|---|---|---:|
| `task build` (release) | ✅ clean, no warnings | 31.5 s cold |
| `odin build src -vet` | ✅ no warnings in any file I touched (pre-existing transmute warnings in `lexer.odin` unchanged) | — |

`odin build src -out:bin/kessel -o:speed -no-bounds-check`. 3.1 MB binary. Toolchain: **Odin dev-2026-04:df6fff6e4** on macOS 15.6 Apple M1 Max.

### Tests — every gate run this session

| Gate | Result | Time | Notes |
|---|---|---:|---|
| `task test:unit` | ✅ **430/430 pass** | 12 s | 58 goldens regenerated for early_errors/* + negative/* with semantic checks now enforced |
| `task test:negative` | ✅ **rejected 139, accepted-bug 0** | <1 s | Was 86/53; relocked baseline |
| `task test:ambiguity` | ✅ baseline OK | <1 s | |
| `task test:regression` | ✅ 11/11 pass | <1 s | |
| `task test:real` | ✅ **467/467 PASS** | 5 s | three.module.js fixed (positional bug + premature parse-time rejection) |
| `task test:estree` | ✅ all OK | 3.5 s | |
| `task test:nodes` | ✅ 57/57 ESTree node types | <1 s | |
| `task test:recovery` | ❌ **30/31 pass, 1 fail** | <1 s | Same pre-existing `006_jsx_fragment_broken.js` cascade |
| `task test:lexical` | ✅ baseline OK | <1 s | |
| `task test:invariants` | ✅ baseline OK, 467/467 files | 15 s | |
| `task test:spec-compliance` | ✅ baseline OK | 4 s | |
| `task test:spec-fixtures` | ✅ **150/150 pass** | 12 s | |
| `task test:test262` | ✅ 66/66 pass | <1 s | |
| `task test:test262:subset` | ✅ **66/66**, baseline matches | <1 s | Was 64/66 |
| `task test:multi-parser` | ✅ deep JSON compare passes vs babel | <1 s | |
| `task test:fuzz` | ✅ 100/100 passed, 0 baselined failures | 8 s | seed=20260421 |
| `task test:fuzz:invalid` | ⚠️ 8/8 baselined crashes still reproduce, 0 new | <1 s | seed=20260422 |
| `task test:crashes-known` | ✅ 0 new crashes | 1 s | |
| `task test:oxc-corpus` | ✅ Baseline OK | 11 s | Improved by 4 fixtures; baseline relocked |
| `task test:bench:regression` | ⚠️ system drift (pre-existing) | 10 s | Geo-mean over tolerance; not a real regression |

The full default `task test` chain runs 18 of these. **Only one failure remains**: `tests/fixtures/recovery/jsx_ts/006_jsx_fragment_broken.js` (pre-existing; reproduces with all of this session's commits stashed out).

### Performance

Re-measured this session on Apple M1 Max via `task bench:quick` (`kessel --ast-only` for parity vs OXC parser-only):

| File | Size | kessel min | oxc min | ratio |
|---|---:|---:|---:|---:|
| typescript.js | ~9.8 MB | 62 952 µs | 42 228 µs | 1.49x |
| cesium.js | ~3.5 MB | 44 209 µs | 37 074 µs | 1.19x |
| monaco.js | ~3.5 MB | 39 210 µs | 33 019 µs | 1.19x |
| antd.js | ~6.5 MB | 31 966 µs | 22 840 µs | 1.40x |
| jquery.js | 281 KB | 2 348 µs | 1 617 µs | 1.45x |
| d3.js | 624 KB | 6 561 µs | 5 138 µs | 1.28x |
| react-dom.dev.js | 1.1 MB | 5 923 µs | 4 180 µs | 1.42x |
| preact.js | 30 KB | 166 µs | 157 µs | 1.06x |
| lodash.js | 543 KB | 2 192 µs | 1 426 µs | 1.54x |
| snabbdom.js | 4 KB | 3.0 µs | 3.8 µs | **0.79x** (faster) |

Geo-mean ~1.28x of OXC. README + AGENTS.md updated to reflect this honestly.

The semantic checker is opt-in (`--show-semantic-errors`), so it does NOT show up in `--ast-only` parity benches. When enabled it adds an extra AST walk after parse — cheap on real-world files (the walker only inspects nodes that can contain break/continue, mostly statements).

---

## Project Structure

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 19 677 | Hand-written Pratt recursive-descent parser. ~190 procedures. Permissive — emits `report_semantic_error*` for inline early-error checks gated on `p.check_semantics`. |
| `src/emitter.odin` | 6 381 | ESTree JSON emitter. `Emitter` owns writer buffer + UTF-16 + line-offset tables. |
| `src/lexer.odin` | 3 096 | SIMD-accelerated tokenizer. Two-token lookahead. |
| `src/regex.odin` | 2 235 | ES2025 §22.2.1 regex pattern validator. Decoupled from `Lexer`. |
| `src/ast.odin` | 1 611 | All AST struct/union definitions. |
| `src/raw_transfer.odin` | 1 302 | Zero-copy binary AST buffer. |
| `src/main.odin` | 1 295 | CLI dispatch + worker pool. Calls `checker_run_for_job` after `parse_job_run` when `cli.show_semantic_errors`. |
| **`src/checker.odin`** | **630** | **AST-walker semantic checker (pass 3).** Implements break/continue + label scoping. `check_program` and `checker_run_for_job` are the public entry points. |
| `src/simd.odin` | 521 | ARM64 NEON intrinsics. |
| `src/parse_job.odin` | 419 | "Source-to-parsed-Program" deep module. `parse_config_from_cli` now plumbs `cli.show_semantic_errors → cfg.check_semantics → p.check_semantics`. |
| `src/token.odin` | 383 | `TokenType` enum, `FastToken`, `LiteralValue`. |
| `src/unicode_tables.odin` | 329 | Unicode 17.0.0 ID range tables. |
| `src/cli_config.odin` | 188 | `CliConfig` struct, `cli_try_parse_flag`. |
| `src/source_io.odin` | 103 | Cross-platform source reader. |
| `src/source_io_posix.odin` | 69 | POSIX mmap path. |
| `src/qos_darwin.odin` | 61 | Apple Silicon QoS hint. |
| `src/source_io_other.odin` | 17 | Windows stub. |
| **Total** | **38 317** | |

---

## Architecture: pass 3 (semantic checker)

```
                     parse_job_run(&job)
                            │
                            ▼
                   ┌────────────────────┐
                   │ p.check_semantics  │
                   │   = false          │ ──▶ kessel parse (default)
                   │                    │     parser-only, matches OXC parseSync
                   │   = true           │ ──▶ inline report_semantic_error*
                   │                    │     fire (~100 call sites)
                   └────────────────────┘
                            │
                            ▼ (always after parse_job_run)
                   ┌────────────────────┐
                   │ if cli.show_       │
                   │  semantic_errors:  │
                   │  checker_run_for_  │ ──▶ AST walker in checker.odin:
                   │  job(&job)         │     break/continue + label scoping
                   │                    │     (more checks slice-by-slice)
                   └────────────────────┘
                            │
                            ▼
                  job.parser.errors (merged)
                            │
                            ▼
                emit_errors / Parse errors: N line
```

`cli.show_semantic_errors` is the single switch that controls BOTH the inline parser-side checks AND the new AST walker. Wired in:

- `src/parse_job.odin::parse_config_from_cli`: `cfg.check_semantics = cli.show_semantic_errors`
- `src/main.odin::parse_file` (and `parse_file_to_disk`, `raw_transfer_file`, `parse_file_raw_to_disk`): `if cli.show_semantic_errors { checker_run_for_job(&job) }`
- NOT wired in microbench (parity with OXC parser-only timing).

Verifier flow:

| Verifier | Passes `--show-semantic-errors`? | Why |
|---|---|---|
| `tests/runners/run_tests.sh` | only for `early_errors/*` and `negative/*` | Other paths verify parser-only behaviour and would see spurious semantic-only diagnostics |
| `tests/verifiers/verify_negative.js` | for `early_errors/*` and `negative/*` | These are spec-rejection fixtures owned by pass 3 |
| `tests/verifiers/verify_test262_subset.js` | yes (always) | Test262 `phase: parse` fixtures cover ECMA-262 Early Errors, which kessel implements in pass 3 |
| `tests/verifiers/verify_oxc_corpus.js` | no | Apples-to-apples vs OXC parseSync (also parser-only) |

---

## Architecture decisions made this session

| Decision | Why | Alternative considered |
|---|---|---|
| **Pass 3 (checker) is opt-in via `--show-semantic-errors`, default off** | Matches OXC's `parseSync` API (parser-only) so the OXC corpus comparison stays apples-to-apples (`oxc_semantic` is also a separate pass). Real-world tools that want spec-correct early errors enable the flag. | Default-on. Rejected because it added 61 false-positive "kessel-only-rejects" against the corpus oracle (TypeScript compiler test fixtures intentionally testing break-outside-iteration). |
| **`cli.show_semantic_errors` plumbs to BOTH `cfg.check_semantics` AND the new AST walker** | One unified flag for "I want spec-correct rejection". Both code paths share the same gate, so users don't have to know which checks live where during the migration. | Two flags (one for inline, one for new walker). Rejected because it leaks the migration's intermediate state into the CLI surface. |
| **Checker errors append to `job.parser.errors`** | Existing `emit_errors`, `Parse errors: N` diagnostic line, raw-transfer error count, verifier rejection-detection regex all just work without modification. | Separate `c.errors` field exposed to the emitter. Rejected because it widens every output path's interface for no architectural gain. |
| **Setter / getter accessor checks demoted from `report_error` to `report_semantic_error_at`** | Spec classifies them as Static Semantic Errors (Early Errors). OXC's parser accepts them; `oxc_semantic` rejects them. Match that split. The location was also wrong (`cur_offset` had advanced past the entire method body — caused three.module.js to report "Line 2033, Column 2" pointing at empty whitespace). | Keep as parse-time fatal but fix the location. Rejected because OXC's parser accepts these and three.module.js parses cleanly under OXC. |
| **Function / arrow / class-static-block establish a checker-walker boundary** | Per ECMA-262 §14.13 LabelSet is per-function; break/continue cannot escape function boundaries. The walker saves `(iter_depth, switch_depth, label_floor)` on entry and restores on exit. | Re-derive from parser's existing `label_stack`/`label_floor` fields. Rejected — that's exactly the coupling the architecture review wants to remove (parser stays permissive; checker re-derives context from the AST shape). |

---

## Known Issues

`grep -rnE "TODO\|FIXME\|HACK\|BUG\|WORKAROUND" src/` — empty.

| # | Issue | Severity | Where | Note |
|---|---|---|---|---|
| 1 | `tests/fixtures/recovery/jsx_ts/006_jsx_fragment_broken.js` produces 15 cascading errors | **annoying** (blocks `task test:recovery`) | `<><span id=></span></>` triggers a JSX-attribute-RHS recovery cascade. Runner threshold is 10. | Pre-existing. Reproduces with this session's commits stashed out. |
| 2 | `task test:bench:regression` reports >tolerance | **noise** | Bench geo-mean drift vs locked baseline. Verified pre-existing — same numbers ±2% with this session's commits stashed out. | Run `task test:bench:regression:update` on a quiet system; do not relock under load. |
| 3 | `task test:fuzz:invalid` always reports "8/8 baselined crashes still reproduce" | **annoying** | The fuzzer's bit-flipped / NUL-injected / UTF-8-broken inputs crash the parser. 8 unique crashes baselined. | Reproducer files in `tmp/fuzz_invalid_crashes/`. Each is a real input-validation gap. |
| 4 | OXC corpus has 2 161 → **2 157** "babel should-pass-rejected" | **shared gap with Babel** | Babel-specific syntax extensions neither kessel nor OXC implements (Flow types, pipeline-operator, experimental decorators). | Not kessel bugs — OXC drops them too. -4 improvement this session. |
| 5 | OXC corpus has 1 kessel-only-reject + 1 oxc-only-reject | **edge cases** | Down from 776 in 2025. | Triage with `node tests/verifiers/triage_kessel_only_rejects.js`. |
| 6 | `src/checker.odin` covers only break/continue + label scoping | **next slice** | The remaining ~17 categories listed in the doc-comment top of `checker.odin` haven't been migrated yet (super.x, new.target, duplicate __proto__, strict-mode parameter validation, duplicate private members, eval/arguments in strict mode, with statement in strict mode, duplicate exported names, ...). | Slice-by-slice migration. Each slice should: (a) add the AST walk to `checker.odin`, (b) demote the corresponding inline `report_semantic_error*` calls in parser.odin (or leave them and let the migration land later — both checkers run when the flag is on, so duplicates are an issue to watch). |

---

## Incomplete Work

| Item | State | What was the goal | What remains |
|---|---|---|---|
| **Architecture deepening chain (5/5 actionable + #4 deferred)** | **Complete** | Restructure `src/` per the architecture review. | #4 (shared AST traversal module) intentionally deferred per the recommendation in the previous handoff — premature unless concrete vocabulary emerges. |
| **#3 semantic checker migration** | **Slices 1 + 2 done** | Move ~17 early-error categories from `parser.odin` into `checker.odin`. | Slices 3+: super.x context, new.target context, duplicate __proto__, strict-mode parameter validation, duplicate private members, eval/arguments binding in strict mode, with statement in strict mode, duplicate exported names, ... See `src/checker.odin` top doc-comment for the inventory. |
| `006_jsx_fragment_broken.js` recovery cascade | Pre-existing failure | Reduce cascade ≤10 (runner threshold) by improving JSX-attribute-RHS recovery. | Investigate `parse_jsx_attribute` / equivalent. |
| 8 baselined fuzz crashes | Tracked | Real input-validation gaps from bit-flip / NUL-inject / UTF-8-broken inputs. | Each reproducer in `tmp/fuzz_invalid_crashes/`. |
| 1 kessel-only-reject in OXC corpus | Tracked | Triage with `node tests/verifiers/triage_kessel_only_rejects.js`. | Fix the parser. |
| Bench geo-mean drift vs OXC | Documented | Kessel is ~1.28x of OXC on standard files. README/AGENTS.md updated to reflect this honestly. | A future perf-focused session. The W-cadence record (`docs/perf-session-22-final.md` … `perf-session-25-*.md`) is intact. |

`git stash list` returned empty. No WIP. Branch is **20 commits ahead of origin/main** (4 new this session, 1 was pre-session HANDOFF.md).

---

## What To Work On Next

Prioritised, after this session:

1. **Continue checker migration (slice 3+)** — pick the next category from `checker.odin`'s doc-comment.
   - **Easiest next slices:** duplicate __proto__ in object literal (single AST node, simple O(n²) within object, rule is local), `super` outside method (ancestor walk, similar shape to break/continue).
   - **Approach (proven by slices 1+2):**
     1. Implement the AST walk in `checker.odin` (extend `ck_walk_*` chain).
     2. Migrate the inline `report_semantic_error*` call in `parser.odin` (or leave — the inline check still fires only when `cfg.check_semantics` is on, so duplicates aren't user-visible during the migration).
     3. Run the full gate chain. Relock baselines if any negative fixtures earn rejections.
   - **Difficulty:** Low-medium per slice now that the seam is built.

2. **Investigate `006_jsx_fragment_broken.js`** — reduce the 15-error cascade to ≤10.
   - **Where:** `src/parser.odin` — `parse_jsx_attribute` and the recovery path when the attribute RHS is missing (`<span id=></span>`).
   - **Difficulty:** Medium — recovery changes can cascade into other JSX fixtures.
   - **Depends on:** Nothing.

3. **Tackle the 1 kessel-only-reject in OXC corpus** — the trend pattern from W-cadence.
   - **Where:** `node tests/verifiers/triage_kessel_only_rejects.js`. Run, find the file, reduce, fix.
   - **Difficulty:** Low-medium — depends on the bug class.

4. **Investigate 8 baselined fuzz crashes** — each is a real input-validation gap.
   - **Where:** Reproducer files in `tmp/fuzz_invalid_crashes/`.
   - **Difficulty:** Medium-high per crash. Some may share a root cause.

5. **(Deferred — architecture review #4)** Shared AST traversal module
   - **Where to revisit:** Once slice 3+ of #3 surfaces a third concrete pattern that maps cleanly onto the emitter / raw-transfer shape.

---

## Commands Reference

### Build / Test (every command run this session)

```bash
task build                # release → bin/kessel (31.5 s)
task test:unit            # ✅ 430/430
task test:negative        # ✅ rejected 139, accepted-bug 0 (was 86/53)
task test:negative:update # relock after deliberate change
task test:test262         # ✅ 66/66
task test:test262:subset  # ✅ 66/66 (was 64/66)
task test:test262:subset:update
task test:real            # ✅ 467/467 (was 466/467)
task test:oxc-corpus      # ✅ baseline OK (-4 should-pass-rejected)
node tests/verifiers/verify_oxc_corpus.js --update
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
task bench:quick          # 10 representative files; geo-mean 1.28x of OXC
```

### Pass-3 / semantic checker

```bash
# Default — parser only (matches OXC parseSync)
./bin/kessel parse foo.js

# With pass 3 — break/continue/label scoping + ~100 inline checks fire
./bin/kessel parse foo.js --show-semantic-errors

# Test262 subset, the verifier passes the flag automatically
task test:test262:subset
```
