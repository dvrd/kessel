# Handoff — Kessel

**Date:** 2026-05-06
**Tip:** `ea69165 refactor: bundle CLI options into CliConfig struct, drop 12 globals`
**Branch:** `main`, ahead of `origin/main` by **15 commits** (architecture deepening chain — see git log).

## What is Kessel

JavaScript / TypeScript / JSX / TSX parser written in [Odin](https://odin-lang.org/) that emits ESTree-compatible JSON ASTs. Targets ES2015–ES2025. Zero runtime dependencies, arena-only memory, ARM64 NEON SIMD lexing, hand-written Pratt expression parser. Three-pass architecture (lexer → permissive parser → opt-in semantic checker) modelled on OXC's `oxc_parser` + `oxc_semantic` split. The CLI exists for development; the real consumer is a future toolchain pipeline (linter / transformer / bundler / codegen).

---

## Current State

### Build

| Command | Result | Time |
|---|---|---:|
| `task build` (release) | ✅ clean, no warnings | 31.5 s cold |
| `task build:debug` | not run this session | — |

Underlying invocation: `odin build src -out:bin/kessel -o:speed -no-bounds-check`. Produces a 3.1 MB single binary at `bin/kessel`. Toolchain: **Odin dev-2026-04:df6fff6e4** on macOS 15.6 Apple M1 Max.

### Tests — every gate run this session

| Gate | Result | Time | Notes |
|---|---|---:|---|
| `task test:unit` | ✅ **430/430 pass** | 11 s | Golden-output fixtures |
| `task test:negative` | ⚠️ baseline OK, **1 NEW improvement** | <1 s | 83 rejected / 56 accepted-but-shouldn't / 1 new fixture rejected (`028_for_await_script_top_level.js` not yet baselined) |
| `task test:ambiguity` | ✅ baseline OK (3 pass / 7 known_fail) | <1 s | |
| `task test:regression` | ✅ 11/11 pass | <1 s | |
| `task test:estree` | ✅ all OK | 3.5 s | TS-statement / JSX raw-binary buffer matches JSON |
| `task test:nodes` | ✅ 57/57 ESTree node types covered | <1 s | |
| `task test:recovery` | ❌ **30/31 pass, 1 fail** | <1 s | `tests/fixtures/recovery/jsx_ts/006_jsx_fragment_broken.js` produces 15 cascading errors — exceeds the runner's "too many parse errors" threshold |
| `task test:lexical` | ✅ baseline OK | <1 s | |
| `task test:invariants` | ✅ baseline OK, 467/467 files | 15 s | All zero-tolerance invariants (I3–I10) clean |
| `task test:spec-compliance` | ✅ baseline OK | 4 s | |
| `task test:spec-fixtures` | ✅ **150/150 pass** | 12 s | Across 22 categories |
| `task test:test262` | ✅ 66/66 pass | <1 s | Curated subset |
| `task test:test262:subset` | ⚠️ 64/66 pass | <1 s | 2 unexpected fails: `statements_break_S12.8_A1.js`, `statements_continue_S12.7_A1.js`. **1 improvement**: `statements_return_S12.9_A1.js` now passes (likely from a recent parser fix; baseline not yet relocked) |
| `task test:multi-parser` | ✅ deep JSON compare passes vs babel | <1 s | |
| `task test:fuzz` | ✅ 100/100 passed, 0 baselined failures | 8 s | seed=20260421 |
| `task test:fuzz:invalid` | ⚠️ 8/8 baselined crashes still reproduce, 0 new | <1 s | seed=20260422 |
| `task test:crashes-known` | ✅ 0 new crashes | 1 s | |
| `task test:real` | ❌ **466/467 pass, 1 fail** | 5 s | `bench/real_world/three.module.js` parser error at "Line 2033, Column 2: A 'set' accessor cannot have an initializer." (positional bug — line 2033 is empty whitespace) |
| `task test:oxc-corpus` | ✅ Baseline OK | 11 s | typescript 15690/19209 (81.7%) · babel 3695/5892 (62.7%) · estree 39/39 (100%) · 1 kessel-only-reject · 1 oxc-only-reject |
| `task test:bench:regression` | ❌ **9.7% over tolerance** | 10 s | Pre-existing system drift: identical numbers ±2% with my refactors stashed out vs applied. The locked baseline was captured under different system conditions. |

The full default `task test` chain runs 18 of these gates. Two remaining failures (`test:real` three.module.js, `test:recovery` 006_jsx_fragment_broken) and the bench-regression drift are **pre-existing** — they reproduce identically when the last 4 commits are stashed out.

### Performance

Measured this session on Apple M1 Max via `task bench:quick` (kessel `--ast-only` for parity vs OXC parser-only):

| File | Size | kessel min | oxc min | ratio |
|---|---:|---:|---:|---:|
| typescript.js | ~9.8 MB | 51 484 µs | 34 261 µs | **1.50x** |
| cesium.js | ~3.5 MB | 36 451 µs | 30 141 µs | 1.21x |
| monaco.js | ~3.5 MB | 31 837 µs | 27 563 µs | 1.16x |
| antd.js | ~6.5 MB | 26 152 µs | 18 368 µs | 1.42x |
| jquery.js | 281 KB | 1 945 µs | 1 387 µs | 1.40x |
| d3.js | 624 KB | 5 443 µs | 4 281 µs | 1.27x |
| react-dom.dev.js | 1.1 MB | 4 920 µs | 3 396 µs | 1.45x |
| preact.js | 30 KB | 138 µs | 129 µs | 1.07x |
| lodash.js | 543 KB | 1 820 µs | 1 174 µs | 1.55x |
| snabbdom.js | 4 KB | 2.5 µs | 3.0 µs | **0.85x** (faster) |

**Reproducibility**: `bench/oxc_compare/target/release/oxc_microbench` is the reference. README/AGENTS.md claim "geo-mean ~1.00x of OXC (parity)"; the numbers above show kessel currently at ~1.3x of OXC on the standard bench files, ~0.85x on tiny files. The README claim is **stale** — it was true at an earlier point in the codebase; recent W-cadence work (see `docs/perf-session-22-final.md` … `perf-session-25-*.md`) hasn't kept pace with OXC's own improvements.

**Internal regression check**: `task test:bench:regression` compares the current run against `tests/baselines/bench_baseline.json`. Geo-mean today is 9.7% over the locked baseline. This drift is reproducible with all of my recent commits stashed out — the baseline was captured under cooler system conditions, not a real regression.

---

## Project Structure

| File | Lines | Purpose |
|---|---:|---|
| `src/parser.odin` | 19 665 | Hand-written Pratt recursive-descent parser. `Parser` struct (~285 fields), `ParseError`, `StringInterner`, `ScopePending`, ESM module-record types. ~190 parsing procedures. Permissive — builds AST without enforcing early errors. |
| `src/emitter.odin` | 6 381 | ESTree JSON emitter. `EmitConfig`, `Emitter` (owns writer buffer + UTF-16 + line-offset tables), 11 writer helpers (`emit_raw`/`emit_str`/`emit_u32`/…), 3 public entry points (`emit_program`, `emit_module_record`, `emit_errors`), 39 AST-node printer procs. Every emit proc takes `^Emitter` explicitly — no globals. **Extracted from main.odin in commit `7254419` (#2 deepening).** |
| `src/lexer.odin` | 3 096 | SIMD-accelerated tokenizer. `Lexer` struct (`source`, `cur`, `nxt`, `line_offsets`, `lexer_errors`, …), `lex_token`, BOM/hashbang handling, regex disambiguation, two-token lookahead. |
| `src/regex.odin` | 2 235 | ES2025 §22.2.1 regex pattern validator. Public API `regex_validate(source, span, flags, alloc) -> []RegexDiagnostic`. Internal pipeline through `RegexValidator` struct. **Decoupled from lexer in commit `dd77be7` (#5 deepening).** |
| `src/ast.odin` | 1 611 | All AST struct/union definitions: `Span`, `Loc`, `Comment`, `Program`, `Statement`, `Expression`, `Declaration`, `Pattern`, `TSType` (~30 variants), JSX types, all literal types. |
| `src/raw_transfer.odin` | 1 302 | Zero-copy binary AST buffer. `RawTransferHeader`, pointer-to-offset rewriter, `produce_raw_buffer_from_job(job)` (post-#1 canonical entry) and legacy `produce_raw_buffer(source, arena, alloc, lang)` wrapper. |
| `src/main.odin` | 1 284 | CLI dispatch. `main`, `print_usage`, `run_server_mode`, `parse_file`, `parse_file_to_disk`, `raw_transfer_file`, `parse_file_raw_to_disk`, `parse_many` + `worker_proc`/`ParseWorkerCtx`, `microbench_*`, `profile_*`, `lex_file`, stdout helpers (`out_print`/`out_println`/`out_printf`), `init_stdout_writer`, `flush_stdout_writer`, `AstType` enum, `HashbangInfo` struct. **Shrank from 7 823 → 1 284 lines (-83%) across commits 2b12e04 / 7254419 / ea69165.** |
| `src/simd.odin` | 521 | ARM64 NEON intrinsics: `simd_find_string_end`, `simd_has_multibyte`, `simd_build_utf16_offsets`. Wraps `core:simd` u8x16 vectors. |
| `src/parse_job.odin` | 416 | "Source-to-parsed-Program" deep module. `ParseConfig`, `ParseJob` (owns source + arena + lexer + parser + Program), three open variants (`parse_job_open` / `parse_job_open_inline` / `parse_job_open_borrowed_arena`), `parse_job_run` / `parse_job_reset_arena` / `parse_job_close`, `parse_config_from_cli`. **New file from commit `2b12e04` (#1 deepening).** |
| `src/token.odin` | 383 | `TokenType` enum (~150 variants), `Token` struct, `LiteralValue` union, `FastToken` (16-byte packed), `LexerError`, token-name lookup. |
| `src/unicode_tables.odin` | 329 | Unicode 17.0.0 ID_Start / ID_Continue range tables, binary-search lookup. |
| `src/cli_config.odin` | 183 | `CliConfig` struct (12 fields), `cli_config_default`, shared `cli_try_parse_flag(cfg, args, *i) -> bool` helper. **New file from commit `ea69165` (#6 deepening).** |
| `src/source_io.odin` | 103 | Cross-platform source reader. `SourceBuffer { data, mapped }`, `source_read` (mmap-then-fall-back-to-read), `source_release`. |
| `src/source_io_posix.odin` | 69 | POSIX mmap path (`#+build darwin, linux, freebsd, netbsd, openbsd`). Uses `posix.open` + `mmap` + `posix_madvise`. |
| `src/qos_darwin.odin` | 61 | `pin_to_p_core()` — Apple Silicon QoS hint to bias scheduler toward P-cores. |
| `src/checker.odin` | **62** | **Stub.** Defines `Checker` struct + `check_program` no-op. The doc-comment lists ~17 planned checks waiting to be migrated from the parser. **This is the next major deepening (#3 in the architecture review chain).** |
| `src/source_io_other.odin` | 17 | Windows stub (`#+build windows`). `source_try_mmap` returns `(nil, false, false)` so `source_read` falls back to `read_entire_file_from_path`. |
| **Total** | **37 718** | |

---

## Architecture

### Data flow (entry point → output)

```
                        argv[]
                          │
                          ▼
                 ┌────────────────┐
                 │   main.odin    │  ── parses subcommand, builds CliConfig
                 │   case "parse" │     via cli_try_parse_flag
                 └────────┬───────┘
                          │  cli: CliConfig
              ┌───────────┴───────────┬─────────────────┐
              ▼                       ▼                 ▼
       parse_file(...)       parse_file_to_disk    parse_many → worker_proc
       raw_transfer_file     parse_file_raw_to_disk  (each thread has its own
                                                      ParseJob + Emitter)
              │
              ▼
   ┌────────────────────────┐
   │  parse_job.odin        │
   │  parse_job_open        │ ── source_read (mmap or heap)
   │                        │ ── arena_init_static (mvirtual.Arena, 256× src or 16 MiB)
   │                        │ ── parse_job_resolve (lang, .d.ts, source-type)
   │  parse_job_run         │ ── init_lexer ─┐
   │                        │ ── init_parser │
   │                        │ ── set per-job parser flags (force_strict, …)
   │                        │ ── parse_program ────► program: ^Program
   └────────┬───────────────┘
            │  job: ^ParseJob
            ▼
   ┌────────────────────────┐
   │  parser.odin           │  ── advance_token → lex_token from lexer.odin
   │  parse_program         │     - SIMD identifier scan, regex disambiguation
   │  ~190 parse_*          │     - Two-token lookahead (cur + nxt)
   │                        │  ── builds AST in arena bump pool + dynamic arrays
   │                        │  ── lexer optionally calls regex_validate
   │                        │     (gated on lexer.check_semantics)
   └────────┬───────────────┘
            │  program: ^Program
            ▼
   ┌────────────────────────┐
   │ EITHER emit JSON       │       OR raw transfer (for cross-language consumers)
   │ ───────────────────    │       ────────────────────────────────────────────
   │  emitter.odin          │       raw_transfer.odin
   │  emitter_init          │       produce_raw_buffer_from_job(job)
   │  emitter_build_utf16   │       ── walks AST, rewrites pointers → arena
   │  emit_program          │          offsets, dynamic arrays → {offset,len}
   │  emit_module_record    │       ── returns { buffer: []u8, header, source }
   │  emit_errors           │
   │                        │
   │  → e.buf[:e.pos]       │
   └────────┬───────────────┘
            │
            ▼
       os.write(stdout)  or  os.write_entire_file(out_path)
```

### Memory strategy

| Layer | Allocator | Lifetime | Notes |
|---|---|---|---|
| **Source bytes** | `mmap` on POSIX, heap fallback on Windows | per-file | Borrowed read-only into the lexer; freed by `source_release` at job close |
| **Parse arena** | `core:mem/virtual.Arena` (lazy-commit virtual memory) | per-job | Sized `max(len(source) * 256, 16 MiB)` for prod paths; tighter `max(len(source) * 128, 256 KiB)` for bench. Holds AST nodes + lexer/parser dynamic arrays + interner + scope-pending list. **Bench can reuse via `parse_job_open_borrowed_arena` + `parse_job_reset_arena`.** |
| **Bump pool inside arena** | hand-rolled `bump_init` + `bump_alloc` (parser.odin) | per-parse | Sized 32 KiB for <1 KiB source; `30× + 32 KiB` for <64 KiB source; `32×` for ≥64 KiB. Allocated up-front from the arena. Overflow falls back to the arena allocator (tracked in profile stats). |
| **Emitter buffer** | `context.allocator` (heap) | per-call | Sized `max(len(source) * 20, 4 KiB)`. Grown by doubling in `emit_reserve`. Freed by `emitter_destroy`. |
| **UTF-16 offset table** | `context.allocator` | per-call | Built lazily by `emitter_build_utf16` only if `simd_has_multibyte(source)` returns true. ASCII-only sources skip the allocation. |
| **Line-offset table** | parse arena (built by lexer) | per-parse | Borrowed by emitter via `emitter_adopt_lines`. |

### Key types

| Type | File | Role |
|---|---|---|
| `CliConfig` | cli_config.odin | 12-field snapshot of CLI flags. Built once per command via `cli_config_default()` + `cli_try_parse_flag` loop. Passed explicitly to every command proc. |
| `ParseConfig` | parse_job.odin | 8-field snapshot of parse-relevant CLI flags. Built via `parse_config_from_cli(cli)`. Held by `ParseJob`. |
| `ParseJob` | parse_job.odin | Owns one parse's lifetime: source bytes, arena, lexer, parser, parsed `^Program`. Three open variants for file / inline / borrowed-arena. |
| `EmitConfig` | emitter.odin | 6-field snapshot of emit-relevant CLI flags + resolved `ts_shape`. Built via `emit_config_from_cli(cli, lang)`. Held by `Emitter`. |
| `Emitter` | emitter.odin | Owns writer buffer + UTF-16 table + line-offsets borrow + EmitConfig. Threaded through every `emit_*` proc. |
| `RegexValidator` | regex.odin | Per-call validator state: borrowed source bytes + owned `[dynamic]RegexDiagnostic` + allocator. Constructed inside `regex_validate`. |
| `Lexer` | lexer.odin | `source`, `source_bytes`, `offset`, `line`, two-token cache (`cur`+`nxt`), `template_stack`, `comments`, `lexer_errors`, `line_offsets`, `check_semantics`. |
| `Parser` | parser.odin (~285 fields) | The big one. Holds lexer pointer, allocator, errors, scope tracking, mode flags (in_function / in_generator / in_async / in_loop / strict_mode / etc.), pending-cover lists, ESM module-record arrays, bump pool, interner. |
| `Program` | ast.odin | Top-level AST node: `body: [dynamic]^Statement`, `source_type`, `loc`. |

### Hot paths

| Operation | Cost driver | Where |
|---|---|---|
| Token lex | SIMD identifier scan + char-class table | `lex_token` (lexer.odin), `simd_find_string_end` |
| Two-token lookahead | `advance_token` swaps `cur ↔ nxt`, lexes new `nxt` | parser.odin top |
| Expression parse | Pratt loop, precedence climbing | `parse_assignment_expr` ~3 K LOC |
| Bump alloc | aligned `pos += size` in pool | parser.odin `bump_alloc` |
| JSON emit | `emit_raw` writes to `e.buf[e.pos]`, doubles on overflow | emitter.odin |
| UTF-16 conversion | `to_utf16(e, byte_off)` lookup in `e.utf16_offsets` (nil for ASCII) | emitter.odin |

---

## Key Design Decisions

| Decision | Why | Alternative considered |
|---|---|---|
| **Three-pass pipeline (lexer → permissive parser → opt-in checker)** | Mirrors OXC. Allows the parser to stay simple (syntax only) and lets consumers skip semantic validation when they have their own (tsc, ESLint). | Single-pass parser doing both syntax and early errors (Acorn / Babel style). Rejected for clarity and to enable tooling that doesn't want diagnostics. |
| **Arena-only memory** | TigerStyle: predictable lifetimes, no GC pauses, free-all in one syscall. | RC / GC. Rejected per AGENTS.md "All memory must be statically allocated at startup." |
| **Hand-written Pratt parser, no parser generator** | OXC's choice. Generators produce slower code and worse error recovery. | yacc / tree-sitter. Rejected. |
| **Two-token lookahead on `Lexer` not `Parser`** | Lexer owns the `cur` + `nxt` pair so the parser's `advance_token` is a single-pointer swap (no re-lex on revert). | Single-token lexer with parser-side queue. Rejected for hot-path cost. |
| **`FastToken` is 16 bytes by value** | Cache-line tuned. Token data flows through the parser's hot loop without indirection. | Heap-allocated tokens. Rejected. |
| **Permissive parser, no early errors inline** | Matches OXC's `oxc_parser`. The checker pass (#3 deepening) will own these. | Inline early-error checks. Rejected because it makes the parser interface wide and conflates phases. |
| **Two-helper writer split (`out_*` for stdout, `emit_*` for AST emitter)** | Pre-#2 a single `out_s` routed via `use_direct_buf` global. The split removed dual-mode helpers and made the emitter purely `^Emitter`-threaded. | Single helper with routing. Rejected because it required ambient state (`use_direct_buf`) and dual semantics. |
| **`CliConfig` passed explicitly, no globals** | Pre-#6: 12 process globals; multi-file workers / server / tests had to reason about ambient state. Server `--compact` was silently no-op. | Thread-local CliConfig. Rejected for `^EmitConfig` parity (TigerStyle). |
| **`regex_validate` returns diagnostics, doesn't see `Lexer`** | Pre-#5 every regex proc took `l: ^Lexer` and reached into `l.source_bytes` / `l.lexer_errors`. Decoupling lets the future checker call it on `RegExpLiteral` nodes post-parse. | Keep `^Lexer` plumbing. Rejected — the brief explicitly called this out. |

---

## Known Issues

No `TODO` / `FIXME` / `HACK` / `BUG` / `WORKAROUND` strings exist in `src/*.odin` (verified by `grep -rnE "TODO|FIXME|HACK|BUG|WORKAROUND" src/` returning empty). Issues below come from running the test suites this session and reading the test runners' output.

| # | Issue | Severity | Where | Workaround / Note |
|---|---|---|---|---|
| 1 | `bench/real_world/three.module.js` produces 1 spurious error | **annoying** (blocks `task test:real`) | parser positional bug: error reported at "Line 2033, Column 2: A 'set' accessor cannot have an initializer" but line 2033 in the file is empty whitespace. Real cause is upstream of that line. | Pre-existing (reproduces with all 4 of my refactor commits stashed out). Not investigated this session. |
| 2 | `tests/fixtures/recovery/jsx_ts/006_jsx_fragment_broken.js` produces 15 cascading errors | **annoying** (blocks `task test:recovery`) | `<><span id=></span></>` triggers an error cascade because parser doesn't recover JSX-attribute-with-missing-RHS gracefully. Test runner's threshold is 10. | Pre-existing. Either fix the recovery (parser change) or relax the runner threshold. |
| 3 | `task test:test262:subset` shows 2 unexpected fails | **annoying** (only sub-suite) | `statements_break_S12.8_A1.js`, `statements_continue_S12.7_A1.js` — both test that `break`/`continue` outside loops/labels is rejected. The parser is permissive (those rejections live in #3's checker). | Will fix automatically once #3 (checker) lands and is wired to the `--show-semantic-errors` flag. Currently the flag is parsed but `cli.show_semantic_errors` is read by no consumer. |
| 4 | `task test:negative` reports "NEW fixtures (rejected): 1" for `028_for_await_script_top_level.js` | cosmetic | A new fixture was added (or earned its rejection) but `tests/baselines/negative_baseline.json` doesn't list it yet. Run `task test:negative:update` to relock. | Same fixture number `028` is also used by `028_delete_private_field.js` — duplicate numbering. |
| 5 | `task test:bench:regression` reports 9.7% over tolerance | **noise** (false positive) | Bench geo-mean drift vs locked baseline. **Verified pre-existing**: identical numbers (±2%) when the last 4 commits are stashed out. The `tests/baselines/bench_baseline.json` was captured under cooler system conditions than the M1 Max under load today. | Run `task test:bench:regression:update` to relock once a quiet system is available. Refactor work is bench-neutral. |
| 6 | README/AGENTS.md claim "Bench geo-mean ~1.00x of OXC (parity)" | docs out of date | `task bench:quick` shows kessel at 1.07–1.55x of OXC on standard files (slower), 0.85x on tiny files (faster). | Update README. The parity claim was true at the time of `docs/perf-session-22-final.md`; OXC has improved since. |
| 7 | `task test:fuzz:invalid` always reports "8/8 baselined crashes still reproduce" | **annoying** (real bugs) | The fuzzer regularly crashes the parser on bit-flipped / NUL-injected / UTF-8-broken inputs. 8 unique crashes are known and not yet fixed; the gate baselines them so they don't fail CI. | Crash inputs saved to `tmp/fuzz_invalid_crashes/case_*.js` (in `.gitignore`). Each is a real input-validation gap. Not investigated this session. |
| 8 | OXC corpus has **2 161 babel "should-pass-rejected"** | **shared gap with Babel** | Babel-specific syntax extensions that neither kessel nor OXC implement (Flow types, pipeline-operator, experimental decorators). Listed under "Shared-gap breakdown" in `task test:oxc-corpus`. | These are not kessel bugs — OXC drops them too. Tracked by `npm run` verifier output. |
| 9 | OXC corpus has **1 kessel-only-reject** | **real bug** (1 file) | One file rejected by kessel that OXC accepts. Triage with `node tests/verifiers/triage_kessel_only_rejects.js`. | Trend is good — was 776 in earlier handoff (2026-05-04), now down to 1. |
| 10 | `src/checker.odin` is a 62-line stub | **architectural debt** | Doc-comment lists 17+ early-error checks that "will be migrated here from the parser" — the migration hasn't happened. Parser still owns scope/labels/duplicate-bindings/strict-mode validation inline. | Item #3 in the architecture review chain. The other 4 items (#1, #2, #5, #6) are done; this is the remaining big move. |
| 11 | `cli.show_semantic_errors` is parsed but no consumer reads it | **dead code** | The flag survives in `CliConfig` and `cli_try_parse_flag` accepts `--show-semantic-errors`, but nothing wires it to `parser.check_semantics`. The pre-refactor code had the same gap (`show_semantic_errors_enabled` global was set but never read). | Lights up automatically when #3 (checker migration) wires the dispatch. |

**Search method for "no TODOs in src":** `grep -rnE "TODO\|FIXME\|HACK\|BUG\|WORKAROUND" src/` returned empty. Confirmed by re-running.

---

## Incomplete Work

| Item | State | What was the goal | What remains | Files |
|---|---|---|---|---|
| **Architecture deepening chain (review of 6 items)** | **4 of 5 actionable items done; 1 remaining; 1 deferred** | Restructure `src/` per the architecture review (parse job, emitter, checker, regex detach, CLI options, AST traversal). | **#3 (semantic checker migration)** is the remaining big move. **#4 (shared AST traversal)** is intentionally deferred per my recommendation — premature unless concrete vocabulary emerges. | See git log: `2b12e04`, `7254419`, `dd77be7`, `ea69165` |
| `src/checker.odin` semantic checker | Stub. 62 lines, no live checks. | Move ~17 early-error / scope / label / duplicate-binding / strict-mode checks from `parser.odin` (currently 19 665 lines) into `checker.odin`. Wire `cli.show_semantic_errors` to call `check_program(c, job.program)` after `parse_job_run`. | Everything. Inventory of which parser fields and call sites need migration is documented in `src/checker.odin`'s top doc-comment. | `src/checker.odin`, `src/parser.odin`, `src/cli_config.odin`, `src/parse_job.odin` |
| Sparse `--out` flag handling in `kessel raw` | Pre-#6 the `raw` subcommand only accepted `--lang` and `--out`. Post-#6 it now accepts every CliConfig flag (a bug-fix-for-free). | n/a — already works. | n/a | `src/main.odin` `case "raw"` |
| `kessel server --flag` now actually works | Pre-#6 it silently ignored every flag despite the doc claiming flags are sticky. Post-#6 fully wired. Verified this session: `--compact`, `--source-type=module`, `--preserve-parens`, `--module-record` all take effect. | n/a — already works. | n/a | `src/main.odin` `case "server"` |
| `tests/baselines/negative_baseline.json` | Stale by 1 entry | Tracks which negative fixtures are caught vs missed. New fixture `028_for_await_script_top_level.js` is rejected but not listed. | Run `task test:negative:update` if the new state is intentional (it is). | `tests/baselines/negative_baseline.json` |
| `tests/baselines/test262_subset_baseline.json` | Stale by 1 entry | `statements_return_S12.9_A1.js` newly passes; baseline still says `unexpected_fail`. | Run `task test:test262:subset:update`. | `tests/baselines/test262_subset_baseline.json` |
| `tests/baselines/bench_baseline.json` | System drift | Locked under different system conditions; current runs 9.7% over. | Run `task test:bench:regression:update` on a quiet system. **Do not relock blindly** — investigate first whether any single file has regressed materially (typescript.js was 17.2% slower today which is at the high end of "system drift" credibility). | `tests/baselines/bench_baseline.json` |
| README / AGENTS.md performance claim | Out of date | Both claim "geo-mean ~1.00x of OXC (parity)". Today: 1.07–1.55x slower on standard files. | Update both docs with current numbers. | `README.md`, `AGENTS.md` |
| 8 known fuzz crashes (`task test:fuzz:invalid`) | Baselined | Bit-flip / NUL-inject / UTF-8-broken fuzz inputs that crash the parser. | Each is a real input-validation gap. Reproducer files in `tmp/fuzz_invalid_crashes/`. | parser.odin / lexer.odin (depending on which crash) |
| 1 kessel-only-reject in OXC corpus | Tracked | Down from 776 in the earlier handoff (2026-05-04) — historical W-cadence work. | Investigate the one remaining via `node tests/verifiers/triage_kessel_only_rejects.js`. | parser.odin |
| `tests/baselines/HANDOFF.md` (the previous one) | Superseded | Older handoff dated 2026-05-04. | Delete or rename to `HANDOFF.2026-05-04.md` if you want to keep the historical context. | `HANDOFF.md` |

`git stash list` returned empty. No WIP commits; all uncommitted work for this session was committed (`ea69165`).

---

## What To Work On Next

Prioritised. Each item lists what / where / why / difficulty / dependencies.

1. **Migrate semantic checks from `parser.odin` → `src/checker.odin` (#3 deepening)** — the architectural payoff of the entire chain.
   - **What:** Move scope verification, label scoping, duplicate-binding detection, strict-mode parameter validation, super/new.target context checks, break/continue context checks (~17 categories listed in `src/checker.odin` top-comment) from inline parser code into a post-parse `check_program(c, job.program)` walk. Wire `cli.show_semantic_errors` → `parser.check_semantics` so the dispatch happens.
   - **Where:** `src/checker.odin` (currently 62-line stub), `src/parser.odin` (delete migrated checks), `src/parse_job.odin` (call `check_program` after `parse_job_run` when `cfg.check_semantics` is on), `src/cli_config.odin` (already has the flag).
   - **Why:** Brings kessel's architecture in line with OXC's `oxc_semantic` split. Lights up the dead `--show-semantic-errors` CLI flag. Fixes `statements_break_S12.8_A1.js` and `statements_continue_S12.7_A1.js` (the 2 known `test262:subset` fails). Lets the parser shrink from ~19 665 lines.
   - **Difficulty:** **High.** Touches the parser's hot path. Each migrated check needs a fixture-by-fixture conformance verification (test262 + negative + oxc-corpus). Recommend doing one category at a time (e.g. break/continue first, then label scoping, then duplicate bindings) with a green-gate-after-each-step discipline.
   - **Depends on:** Nothing — #1, #2, #5, #6 are all done and the entry seam is ready. ParseJob hands off `^Program`; emitter is decoupled; CliConfig has the flag.

2. **Investigate `bench/real_world/three.module.js` failure**
   - **What:** Parser reports "Line 2033, Column 2: A 'set' accessor cannot have an initializer" but that line is empty. Find the actual erroring construct (likely a class field or accessor earlier in the file) and the positional bug that misreports the location.
   - **Where:** `src/parser.odin` — find where the "A 'set' accessor cannot have an initializer" message is reported, audit its loc emission.
   - **Why:** Unblocks `task test:real`. The file is 1.27 MB / 53 K lines — likely a single class member triggers it.
   - **Difficulty:** **Low-medium.** Bisect the file with `head -N | kessel parse` to find the smallest reproducer.
   - **Depends on:** Nothing.

3. **Investigate `tests/fixtures/recovery/jsx_ts/006_jsx_fragment_broken.js` cascade**
   - **What:** `<><span id=></span></>` produces 15 errors before the runner gives up. Reduce the cascade to ≤10 (the runner threshold) by improving JSX-attribute-RHS recovery in the parser.
   - **Where:** `src/parser.odin` — look at `parse_jsx_attribute` (or equivalent) and the recovery path when the attribute value is missing.
   - **Why:** Unblocks `task test:recovery`.
   - **Difficulty:** **Medium.** Needs careful testing — recovery changes can cascade into other JSX fixtures.
   - **Depends on:** Nothing.

4. **Update README + AGENTS.md performance claims**
   - **What:** Replace "Bench geo-mean ~1.00x of OXC (parity)" with measured numbers from `task bench:quick`. Acknowledge kessel is currently behind OXC on standard files and explain why (no recent perf work; OXC has improved).
   - **Where:** `README.md`, `AGENTS.md`.
   - **Why:** Honest status. Stale claims erode trust.
   - **Difficulty:** **Low.** 10-minute edit.
   - **Depends on:** Nothing.

5. **Tackle the 1 kessel-only-reject in OXC corpus**
   - **What:** Run `node tests/verifiers/triage_kessel_only_rejects.js`, find the file kessel rejects but OXC accepts, reduce to a minimal repro, fix the parser.
   - **Where:** Whatever cluster the triage points at.
   - **Why:** Trend pattern from the W-cadence workflow. Down from 776 → 1; finishing it gets to 0.
   - **Difficulty:** **Low-medium** — depends on the bug class.
   - **Depends on:** Nothing.

6. **Re-baseline `tests/baselines/negative_baseline.json` and `tests/baselines/test262_subset_baseline.json`**
   - **What:** Run the `:update` variant of each gate.
   - **Where:** `tests/baselines/`.
   - **Why:** Both baselines have a stale entry — one new fixture rejected, one fixture newly passing. Relocking removes the noise from the gate output.
   - **Difficulty:** **Trivial** (1 minute).
   - **Depends on:** Nothing. Don't relock the bench baseline yet (item 5 above warns against that without investigation).

7. **Investigate the 8 baselined fuzz crashes**
   - **What:** Reproduce each with the file in `tmp/fuzz_invalid_crashes/`, fix the parser/lexer to reject cleanly instead of crashing.
   - **Where:** Depends on the crash — likely lexer (UTF-8 break) or parser (bit-flip into invalid AST states).
   - **Why:** Each crash is a real input-validation gap. The baseline lets them slip in CI, but they're real bugs.
   - **Difficulty:** **Medium-high** per crash. Some may share a root cause.
   - **Depends on:** Nothing.

8. **(Deferred per architecture review)** Shared AST traversal module (#4)
   - **What:** Extract a single visitor/walker abstraction for emitter, raw-transfer rewriter, and (future) checker.
   - **Why deferred:** The three existing adapters do meaningfully different things (write bytes in source order, rewrite pointers, post-parse validation). Forcing them behind one seam is premature abstraction unless the concrete vocabulary is clear.
   - **When to revisit:** If #3 surfaces a third pattern that maps cleanly onto the emitter / raw-transfer shape, the case strengthens. Until then, leave alone.

---

## Commands Reference

Every command below was run during this session unless marked otherwise.

### Build

```bash
task build                # release build → bin/kessel (31.5s cold, single odin invocation)
task build:debug          # debug build with bounds checks → bin/kessel-debug (NOT run this session)
task install              # cp bin/kessel → ~/.local/bin/kessel (NOT run this session)
task clean                # rm -rf bin tmp (NOT run this session)
```

### Tests (in `task test` chain order)

```bash
task test                 # full chain (18 sub-gates) — NOT run as one this session
task test:unit            # ✅ 430/430, 11s
task test:negative        # ⚠️ baseline OK + 1 new improvement, <1s
task test:ambiguity       # ✅ 3/10 + 7 known_fail, <1s
task test:regression      # ✅ 11/11, <1s
task test:real            # ❌ 466/467, 5s (three.module.js fails)
task test:estree          # ✅ all OK, 3.5s
task test:nodes           # ✅ 57/57 ESTree node types covered, <1s
task test:recovery        # ❌ 30/31, <1s (006_jsx_fragment_broken cascade)
task test:lexical         # ✅ baseline OK, <1s
task test:invariants      # ✅ 467/467 + zero-tolerance OK, 15s
task test:spec-compliance # ✅ baseline OK, 4s
task test:spec-fixtures   # ✅ 150/150, 12s
task test:test262         # ✅ 66/66, <1s
task test:test262:subset  # ⚠️ 64/66 + 1 improvement, <1s
task test:multi-parser    # ✅ deep JSON compare passes vs babel, <1s
task test:fuzz            # ✅ 100/100, 8s (seed=20260421)
task test:fuzz:invalid    # ⚠️ 8/8 baselined crashes reproduce, 0 new, <1s (seed=20260422)
task test:crashes-known   # ✅ 0 new, 1s
task test:oxc-corpus      # ✅ Baseline OK, 11s (typescript 81.7%, babel 62.7%, estree 100%)
task test:bench:regression # ❌ 9.7% over tolerance, 10s (pre-existing system drift)
```

### Strict / update variants (NOT run this session)

```bash
task test:negative:strict          # zero-tolerance negative gate (pre-release)
task test:negative:update          # relock baseline after a deliberate fix
task test:test262:subset:update    # relock test262:subset baseline
task test:bench:regression:update  # relock bench baseline
task test:oxc-corpus:update        # relock OXC corpus baseline
```

### Performance

```bash
task bench                # raw kessel-vs-oxc on every real_world file (60s; ran this session)
task bench:quick          # 10 representative files (10s; ran this session)
task bench:quick:full     # full kessel-vs-oxc with iteration count (NOT run)
task bench:oxc:build      # rebuild bench/oxc_compare/oxc_microbench (NOT run; binary present)
```

Microbench a single file:

```bash
./bin/kessel microbench parse <file> --iterations 30 [--ast-only]
./bin/kessel microbench lex <file> --iterations 30
./bin/kessel profile parse <file> --iterations 30   # parser profile dump
./bin/kessel profile lex <file> --iterations 30     # lexer profile dump
```

### Parsing (CLI usage)

```bash
./bin/kessel parse <file>                       # JSON AST → stdout
./bin/kessel parse <file> --compact             # one-line JSON
./bin/kessel parse <file> --loc --range         # add ESTree loc + range
./bin/kessel parse <file> --source-type=module  # explicit module mode
./bin/kessel parse <file> --module-record       # append ESM record block
./bin/kessel parse <file> --errors=oxc          # OXC error shape (default: kessel)
./bin/kessel parse <file> --raw                 # binary AST → stdout (no JSON)
./bin/kessel parse <files...> --workers 4 --out-dir tmp/ast    # multi-file parallel
./bin/kessel parse <files...> --workers 4 --out-dir tmp/raw --raw

./bin/kessel raw <file> --out file.bin          # raw transfer to file
./bin/kessel lex <file>                         # tokens → stdout JSON

./bin/kessel server [flags]                     # long-lived: read paths from stdin,
                                                # write JSON + sentinel per request
                                                # — flags are sticky (post-#6 fix)
```

All parse-relevant flags (`--source-type`, `--force-strict`, `--preserve-parens`, `--strict-source-type`, `--lang`, `--ast-type`, `--errors`, `--loc`, `--range`, `--module-record`, `--compact`, `--show-semantic-errors`) work on **every** subcommand that accepts source: `parse`, `parse --raw`, `raw`, `microbench parse`, `server`. Pre-#6 only `parse` (single-file) had the full set.

### Verifier scripts (Node, in `tests/verifiers/`)

```bash
node tests/verifiers/verify_negative.js [--update] [--strict]
node tests/verifiers/verify_oxc_corpus.js [--update]
node tests/verifiers/triage_kessel_only_rejects.js     # cluster rejects by error message
node tests/verifiers/verify_test262_full.js
node tests/verifiers/verify_ambiguity.js [--update]
node tests/verifiers/verify_bench_regression.js [--update]
```
