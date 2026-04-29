# Handoff — Kessel

## What is Kessel

Kessel is a JavaScript/TypeScript/JSX parser written in Odin that emits
ESTree-compatible JSON ASTs. It targets ES2015–ES2025 syntax with zero
runtime dependencies, statically-allocated arena memory, ARM64 NEON
SIMD-accelerated lexing, and a Pratt expression parser. The project is
parser-only — no transpiler, bundler, linter, or formatter — and tracks
both speed (vs. Rust's `oxc`) and Test262 conformance as primary metrics.

---

## Current state (Session 24, 2026-04-29)

**Performance: kessel CRUSHES OXC. 8 / 10 files now BEAT OXC. Worst case is typescript at 0.98×.**

| File | S23 | S24 final | Δ |
|---|---:|---:|---:|
| typescript | 1.04× | **0.98×** | **−6 pp** |
| cesium | 1.06× | **0.98×** | **−8 pp** |
| monaco | 1.05× | **0.99×** | **−6 pp** |
| antd | 1.02× | **0.97×** | **−5 pp** |
| d3 | 1.01× | **0.95×** | **−6 pp** |
| jquery | 1.03× | 1.00× | −3 pp |
| react-dom | 0.97× | **0.91×** | −6 pp |
| preact | 0.89× | **0.81×** | −8 pp |
| lodash | 1.06× | **0.96×** | −10 pp |
| snabbdom | 0.81× | **0.78×** | −3 pp |

* **8 / 10 files BEAT OXC** (was 3 / 10 at S23 start — just snabbdom, preact, react-dom)
* **No file exceeds 1.00×** (was cesium / monaco / lodash above 1.05×)
* Worst-case file: typescript at 0.98× (was cesium at 1.06×)
* Geo-mean: ~0.990× → **~0.93×** (−6 pp)

**Session 23 progression**:
* S22 final: 1.002× geo-mean
* `4e9efe3` Darwin CPU QoS pin (Tier 1 K) — bench-neutral on idle machine, real-world hedge
* `d2ec90b` Cap-bump top 8 slow-path callsites (Tier 2 D-lite) — geo-mean **1.002 → 0.990** (-1.2 pp)

Full S23 write-up: `docs/perf-session-23.md`.

**Session 24 progression**: 2 refuted hypotheses + 5 commits that won.
* ~~Tier 2 E (per-letter handlers)~~ — both `#force_inline` and regular-call
  variants regressed 1–4 pp. The existing `#force_inline` chain
  (`lex_identifier` → `lookup_keyword_by_letter`) already gets per-letter
  dispatch implicitly via LLVM CSE on the duplicate `src[start]` load;
  explicit handlers are pure code-bloat / call-overhead. **Refuted.**
* ~~ASCII-split (`lex_identifier_ascii` + `lex_identifier`)~~ — below noise.
  The UTF-8 first-byte branch is >99 % taken-not-taken; predictor + cold
  layout already absorb the cost. **Refuted.**
* `7aa72d9` Eliminate dead `loc.line` / `loc.column` reads on identifier
  hot path (75 sites). −0.5 pp on big files.
* `4fb90a5` Collapse `LexerLoc` to `distinct int` (24 B → 8 B). Token
  shrinks 16 B. Drove cesium 1.06× → 1.03×. Side effect: fixed error
  printer's `Line 0, Column 0` bug (11 golden tests updated).
* **`cc72af8` — the big one.** Replaced parse_binding_pattern's 36-way
  reserved-word string switch with a single `id_name == "enum"` check.
  Static analysis showed 35 of those 36 words are caught earlier as
  dedicated tokens; only `enum` survives as `.Identifier`. Single
  biggest commit in the entire kessel-vs-OXC arc. Big files dropped
  −5 to −8 pp.
* `1b0e2bb` Pass Token to loc_from_token by pointer (avoids 64 B stack
  copy across 75 call sites).
* `2486cee` Inline `current := get_current(p)` Token snapshots in
  parse_identifier / parse_string_literal. Code cleanliness.

Full S24 write-up: `docs/perf-session-24.md`.

**The lex side of kessel is at architectural parity with OXC.** The
parser side has more room — the S24 wins came from line-by-line
reading of hot functions to find dead state the lexer rendered
unreachable. Pattern is repeatable: see the "Recommended sequence"
below for the next likely targets.

**Correctness: every gate green.**

| Suite | Result |
|---|---|
| Test262 full | **49,728 / 49,729** (99.998 %) |
| TS conformance | 21 / 21 |
| JSX conformance | 18 / 18 |
| Unit | 409 / 409 |
| Real-world | 467 / 467 |
| Negative | 125 / 125 |
| Invariants | zero-tolerance clean |
| Node coverage | 57 / 57 |
| Ambiguity | baseline-matched |
| ESTree binary walk | passes deep JSON compare vs OXC |

The lone remaining Test262 failure is `staging/sm/generators/syntax.js`
(SpiderMonkey-specific relaxation of §16.1.1 GeneratorDeclaration
duplicate detection — out of scope; SM violates spec).

---

## How we got here (perf commits, S22 + S23, in order)

| Commit | What | Δ ratio |
|---|---|---:|
| `14585d9` | `--ast-only` bench mode (apples-to-apples vs OXC parser-only) | 1.346× → 1.099× |
| `aa1b04e` | Exclude arena reset from microbench timer | 1.099× → 1.064× |
| `66958d3` | Scalar prefix before SIMD identifier scan | 1.064× → 1.047× |
| `caf035e` | `force_inline` lookup_keyword_by_letter | 1.047× → 1.043× |
| `d0eed4e` | `bump_append` (parser, 131 sites) — biggest single win | 1.043× → 1.013× |
| `50e1585` | `bump_append` (lexer, 117 sites) | 1.013× → 1.006× |
| `d121a64` | Bump pool size source_len×15 → ×32 | 1.006× → 1.002× |
| `4e9efe3` | Darwin CPU QoS pin to P-cores (Tier 1 K) | 1.002× → 1.002× (real-world hedge) |
| `d2ec90b` | Cap-bump top 8 slow-path callsites (Tier 2 D-lite) | 1.002× → **0.990×** |
| _(S24 refuted)_ | Tier 2 E per-letter handlers + ASCII-split | 0.990× → 0.990× (no code shipped) |
| `7aa72d9` | Eliminate dead `loc.line` / `loc.column` reads | −0.5 pp on big files |
| `4fb90a5` | Collapse `LexerLoc` to `distinct int` (Token −16 B) | **cesium 1.06× → 1.03×** |
| `cc72af8` | parse_binding_pattern: 36-way reserved-word switch → `== "enum"` | **−5 to −8 pp / big file** — the big one |
| `1b0e2bb` | Pass Token to loc_from_token by pointer (75 sites) | small but composes |
| `2486cee` | Inline parse_identifier / parse_string_literal Token snapshots | code cleanliness |

The biggest single win was `bump_append` in the parser (`d0eed4e`):
**−3pp in one commit**. Root cause was Odin's `_append_elem` being
`#force_no_inline` AND taking `size_of_elem` as runtime parameter, so
LLVM couldn't specialise the memcpy and every append fell through to a
system `memmove` call. Generic `#force_inline` replacement specialises
the store per type at compile time. Per-append: ~50–100 ns → ~1–5 ns.

Detailed write-ups in `docs/perf-deep-dive-summary.md` and
`docs/perf-session-22-final.md`.

---

## Failed experiments (don't relitigate)

Each came in 5–10× smaller than predicted. Profile attribution % does
NOT linearly map to wall-time savings when the function does real work.

| Lever | Predicted | Measured | Why |
|---|---:|---:|---|
| Non-mutex arena allocator | 8–10 % | 0.4 % | Apple Silicon mutex is 3–6 ns, not 10–20. Most "ALLOC" was real bump-pointer work, not the mutex. |
| First-letter keyword gate | 1–2 % | noise | Skipping 30 % of a 5 ns call ≈ < 1 % wall time. |
| Inline tagged unions | 5–8 % | 0.3 % geo / 5 % monaco | bump pool already minimised per-alloc cost. Test infra coupling reverted. |
| OXC-style proc-ptr byte dispatch | 2–4 % | −1.5 % | Odin's compiler doesn't inline through proc-pointer tables the way Rust+LTO does. |
| Skip keyword classification | (test) | parser became SLOWER | Unrecognised keywords reach parser, force more disambiguation work. The classification IS productive work. |
| **S23**: Tier 1 A pre-fault arena pages | ~1 ms / parse | +159 µs regression | Bench warm-up already commits pages; iteration prefault loop is dead work in tight bench loop. Could matter for real-world parse-once-and-exit. |
| **S23**: scope_map_make cap 4 → 8 | -100–300 µs | -400–600 µs regression on big files | scope_map_make is called per-scope; thousands of small-scope allocations got doubled. The fix only helps tail cases, not common-case allocs. |
| **S23**: source-size-conditional caps | +0.5–1 % | -400–600 µs regression | After flat cap bumps captured 89 % of slow-path events, doubling further cost more in arena traffic than it saved. Diminishing returns. |
| **S24**: Tier 2 E per-letter handlers (#force_inline) | 1–2 ms on monaco | +6 pp regression on monaco / cesium | 20 inlined handlers × SIMD-body-scan helper → several KB of duplicated code in `lex_token`, blows L1i on identifier-heavy bundles. The architectural-analysis prediction missed that LLVM's existing inline + CSE already does per-letter dispatch implicitly. |
| **S24**: Tier 2 E per-letter handlers (regular calls) | 1–2 ms on monaco | +9 pp regression on cesium | One call+ret + register spill per identifier. Identifiers are 30–40 % of tokens → millions of extra calls per parse. |
| **S24**: ASCII-split `lex_identifier` | ~0.5–1 ms on monaco | within run-to-run noise | The `if first >= 0x80` branch is >99 % predictable; LLVM lays the cold UTF-8 path far away; OOO core absorbs the wasted compares. |

All listed in `docs/perf-deep-dive-summary.md` and `docs/perf-session-23.md` with details.

---

## User principles (binding for future work)

1. **Memory is plentiful.** "Anyone parsing JavaScript has more than a
   GB of available RAM otherwise they wouldn't be able to even run a
   browser." Be generous with virtual memory reservations. Pre-allocate
   bounded arrays at max size. Bump pools should never overflow.
   Unused pages cost nothing because the OS only commits on first
   touch.

2. **Profile attribution ≠ wall-time savings.** When a function shows
   at X % of CPU, only the dispatch+bookkeeping portion is removable
   by call-graph restructuring. The actual computational work is
   irreducible at that level. To save wall time, eliminate the WORK.

3. **Always validate predictions before committing to multi-week work.**
   The session burned through 4 failed predictions (5-10× smaller than
   projected). For the SoA prototype we built a fair AB benchmark before
   committing — that's the model. Use `bench/dod_proto/` as the template.

4. **No correctness regressions.** Every commit must keep all gates
   green: Test262, TS, JSX, Real, Negative, Unit, Invariants, Nodes,
   Ambiguity, ESTree.

5. **Bench fairness matters.** OXC's bench harness defers semantic
   work; kessel's must too (`--ast-only` flag) for a fair comparison.
   Real-world parsing keeps all checks ON. Document which mode is
   being measured.

---

## Path forward — architectural roadmap

Comprehensive analysis in `docs/perf-architectural-analysis.md`. Tiers
ordered by ROI (predicted impact / effort).

### Tier 1 — cheap, high-confidence (implement next)

#### A. Pre-fault arena pages outside the timer
**Effort: 1 hour. Predicted: ~1 ms / parse on large files.**

Apple Silicon has 16 KB pages. Monaco's 57 MB arena = ~3,500 first-touch
page faults at ~300 ns each = ~1 ms inside the timed region. Touch
every page (one-byte write per 16 KB) at parser init, BEFORE
`time.tick_now()`. Subsequent writes hit pre-mapped pages with zero
fault overhead.

```odin
arena_prefault :: proc(p: ^Parser) {
    base := p.node_pool.base
    cap := p.node_pool.capacity
    page := 16 * 1024
    for off := 0; off < cap; off += page { base[off] = 0 }
}
```

#### B. Source file via mmap + MADV_SEQUENTIAL
**Effort: 1 day (cross-platform). Predicted: 0–1 ms bench, 5–10 ms cold-file real-world.**

Currently kessel uses `os.read_entire_file_from_path` which copies
file bytes from kernel page cache to user buffer. mmap eliminates the
copy and lets the kernel prefetch ahead. For microbench (file already
cached) the win is small. For LSP/build-tool workloads (cold files)
the win is large.

#### C. Custom `ParseList(T)` type bypassing Odin runtime
**Effort: 1–2 days. Predicted: ~1–2 ms on monaco.**

Even after `bump_append`, the GROW path still calls through the Odin
runtime: `_append_elem → _reserve_dynamic_array → mem_resize →
arena_allocator_proc` (4 function calls). A custom type bypasses all
of this:

```odin
ParseList :: struct(T: typeid) {
    data: [^]T,
    len:  u32,
    cap:  u32,
}
list_append :: #force_inline proc(p: ^Parser, list: ^ParseList($T), item: T) {
    if list.len >= list.cap {
        new_cap := max(list.cap * 2, 8)
        new_data := transmute([^]T)bump_alloc(&p.node_pool, int(new_cap) * size_of(T), align_of(T))
        if list.cap > 0 {
            mem.copy(new_data, list.data, int(list.len) * size_of(T))
        }
        list.data = new_data
        list.cap = new_cap
    }
    list.data[list.len] = item
    list.len += 1
}
```

Refactor: replace every `[dynamic]T` field in AST node types with
`ParseList(T)`. ~131 call sites in parser.odin. Mechanical.

Risk: medium. Test verifiers (`verify_*.js`) read AST; need to make
sure exposed slice matches expectations.

#### K. CPU QoS QOS_USER_INTERACTIVE
**Effort: 1 hour (macOS-only). Predicted: 0–10 % depending on system load.**

Apple Silicon scheduler routes threads to E-cores or P-cores by QoS.
Default for CLI tools is `QOS_DEFAULT`, which can land on E-cores
under load. `pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,
0)` pins to P-cores.

### Tier 2 — structural (after tier 1)

#### D. Pre-allocate all bounded arrays to max size
**Effort: 1 day. Predicted: ~0.5–1 ms.**

Apply user's "memory plentiful" principle uniformly:
- Token array: bounded by source_len
- AST node arrays: bounded by source_len/4
- All `make([dynamic]T, 0, N, alloc)` initial caps tuned to upper bound

#### E. Per-letter identifier handlers (OXC pattern)
**Effort: 1 week. Predicted: ~1–2 ms on monaco.**

OXC uses 21 specialised per-letter byte handlers (`L_A`, `L_B`, ...,
`L_Y`) that each FUSE identifier scan + keyword classification.
kessel does these in two phases. SOURCE-LEVEL switch in `lex_token`
on first byte → `#force_inline lex_ident_a`, `lex_ident_b`, etc.,
each with that letter's keyword family inline.

The April `[256]proc()` dispatch test (commits `02da77c`, `f815e90`)
showed Odin can't inline through proc-pointer tables. The
source-level switch CAN inline, so this approach should work where
the table approach failed.

### Tier 3 — major refactor (validated, queued)

#### F. Full SoA AST migration
**Effort: 4–5 weeks. Predicted: ~3–4 % wall time.**

Already validated in `bench/dod_proto/proto2.odin`: 10–12 % faster
on isolated AST construction subset. Real-world projection is 3–4 %
once integrated.

Plan in `docs/dod-prototype-plan.md`. Replaces `raw_transfer.odin`
entirely (trivial array writes, no pointer-rewrite logic).

### Tier 4 — OS-specific / speculative

| | Effort | Predicted | Notes |
|---|---|---:|---|
| H. Mach VM superpages (2 MB pages) | 1 hour macOS-only | 0–0.5 ms | Marginal TLB win |
| I. Cache prefetch instructions | 1 hour | 0 | M-series HW prefetcher already aggressive; tested before, no win |
| J. Skip arena zero-fill via `vm_deallocate` cycle | 1 hour macOS-only | 0 bench, 5–8 ms real-world reset | Saves cost between parses |

### Recommended sequence (post-S24, with refuted levers crossed out)

* ~~Tier 1 A pre-fault~~ — refuted in S23 (warm-up already commits pages)
* ~~Tier 1 K CPU QoS~~ — shipped in S23 (`4e9efe3`, real-world hedge)
* ~~Tier 2 D pre-allocate maxes~~ — partly shipped in S23 cap-bumps
* ~~Tier 2 E per-letter handlers~~ — refuted in S24, both variants.
* **`parse_binding_pattern` enum-only check (S24 the-big-one)** —
  shipped in `cc72af8`. The pattern is repeatable on similar
  predicates. Specific candidates with the same shape:
  * The 7 OTHER call sites of `is_always_reserved_word_name`
    (3766, 5746, 5882, 5919, 10251, 10504, 10637) — most are gated
    by `has_escape` (live) but 5882 / 5919 / 10504 are object-pattern
    and shorthand sites that COULD be optimised similarly. Each is
    less hot than parse_binding_pattern's site, so the win is
    smaller, but the pattern is the same.
  * `parse_class_element` keyword-string switches (4 cases at
    4077–4089) — TS class member modifiers (public / private /
    protected / readonly).
  * `parse_ts_identifier_type` (11 cases at 13296+) — TS built-in
    type keyword dispatch. Hot in TS code.
  * `parse_function_param` modifier loop (4 cases at 3480+) — same
    TS modifier shape.
* **Tier 1 C (ParseList)** — still on the table. After S24's wins the
  predicted ROI shrank to ~0.3 ms; validate with AB before committing.
* **Tier 3 F (SoA migration)** — 4–5 weeks, ~3–4 % wall. Validated.
  Now that kessel beats OXC on geo-mean, this is no longer a parity
  play; it's a "how much further can we go" play.
* **Tier 1 B (mmap source)** — 1 day, real-world only.
* **Tier 4 J (vm_deallocate)** — 1 hour, real-world only.

Lesson from S24: **the profile-guided line-by-line pattern is the
richest source of wins.** Predicted architectural levers (per-letter
handlers, SoA AST) are increasingly unreliable as the codebase
matures — the compiler has already optimised what it can. The
remaining wins are hidden in the gap between what the profile shows
and what the code _actually_ does — dead reads, vestigial fields,
switches the lexer's behaviour has rendered nearly-dead. Look there
first.

---

## Save points (newest first)

| Tag | State |
|---|---|
| `s24-end` | **S24 final — 8 / 10 files BEAT OXC, worst is typescript 0.98×** |
| `s24-enum-only-check` | After `cc72af8` (the big one, big files −5 to −8 pp) |
| `s24-lexerloc-shrink` | After `4fb90a5` (cesium 1.06× → 1.03×) |
| `s24-dead-loc-reads` | After `7aa72d9` (~0.5 pp on big files) |
| `s24-start` | = `caps-bumped`. Phase 1 (Tier 2 E refuted, no code shipped). |
| `caps-bumped` | S23 final — geo-mean 0.990× |
| `tier1k-qos` | After Darwin CPU QoS pin (1.002×) |
| `s23-start` | Start of S23 (1.002×–1.005×) |
| `parity-pool32` | S22 final — geo-mean 1.002× |
| `arch-analysis-complete` | After architectural analysis written |
| `bump-append-win` | After bump_append in parser+lexer |
| `parity-reached` | First time at 1.013× geo-mean |
| `deep-dive-2-wins` | Scalar prefix + force_inline keyword |
| `deep-dive-complete` | Deep-dive summary doc written |
| `dispatch-optim-exhausted` | Both dispatch wins reverted |
| `step5-phase1-validated` | SoA prototype validates |
| `step3-attempted-reverted` | Inline tagged unions tried, reverted |
| `before-inline-union-refactor` | Pre step #3 |
| `perf-bottleneck-profiled` | Deep profile breakdown |
| `perf-arena-reset-fix` | Arena reset moved out of timer |
| `perf-ast-only-bench` | Apples-to-apples flag added |
| `session22-ast-only-complete` | After steps 1+2 (1.064×) |

---

## Project structure

| File | Purpose |
|---|---|
| `src/main.odin` | CLI entry, JSON emit, microbench harness, `--ast-only` flag plumbing |
| `src/parser.odin` | Recursive-descent + Pratt expression parser. `BumpPool`, `bump_alloc`, `bump_append`. ~14K lines |
| `src/lexer.odin` | Lexer + Annex B HTML comments + Unicode validation. NEON SIMD identifier scan with scalar prefix. `bump_append` for cooking buffers and lexer errors |
| `src/simd.odin` | NEON helpers; `simd_scan_id_cont` with 8-byte scalar prefix |
| `src/ast.odin` | AST node type definitions |
| `src/raw_transfer.odin` | Binary AST emission (in-memory layout → on-disk offsets) |
| `src/regex.odin` | Regex literal lexer |
| `src/token.odin` | TokenType enum + `FastToken` struct |
| `src/unicode_tables.odin` | Unicode 17.0 ID_Start / ID_Continue tables |

---

## Commands

```bash
# Build
task build

# Core gates (all must be green)
task test:unit                       # 409 / 409
task test:negative                   # 125 / 125
task test:real                       # 467 / 467
task test:invariants                 # zero-tolerance clean
task test:nodes                      # 57 / 57
task test:ambiguity                  # baseline-matched
task test:estree                     # binary AST walk vs OXC

# Conformance gates
task test:ts:conformance             # 21 / 21
task test:jsx:conformance            # 18 / 18

# Test262
task test:test262:full:regression    # 49,728 / 49,729 (99.998 %)

# Bench (apples-to-apples vs OXC parser-only)
task bench:quick                     # default — kessel --ast-only
task bench:quick:full                # apples-to-oranges (kessel full parse)

# Microbench single file
bin/kessel microbench parse <file.js> --iterations 100 --ast-only

# Profile single file (with instrumentation)
bin/kessel profile parse <file.js> --iterations 1
```

---

## Reference docs (in priority order for next session)

Four active docs in `docs/` (all current and binding):

1. **`docs/perf-architectural-analysis.md`** — comprehensive Tier 1/2/3/4
   roadmap. **Read first** before starting any new perf work.
2. **`docs/perf-deep-dive-summary.md`** — what worked, what didn't, why.
3. **`docs/perf-session-22-final.md`** — final state summary.
4. **`docs/dod-prototype-plan.md`** — SoA migration plan (Tier 3 F).

Prototype harness: **`bench/dod_proto/`** — SoA validation; reuse the
methodology (fair-AB micro-bench against same primitives) when
validating any architectural prediction.

Archived (in `docs/_archive/`, kept for raw profile data and historical
research): `perf-analysis.md`, `perf-deep-analysis.md`,
`perf-bottleneck-profile.md`. See `docs/_archive/README.md` for
supersession map.

---

## Open work items (in priority order)

### Performance (not blocking — kessel is at OXC parity)

1. Tier 1 A + K + C (pre-fault, QoS, ParseList) — ~2 days, predicted
   monaco 1.06× → ~1.00×, geo-mean below 1.0×.
2. Tier 2 D + E (pre-allocate caps, per-letter handlers) — ~1.5 weeks,
   predicted further ~1–2 % geo-mean.
3. Tier 3 F (SoA AST) — ~5 weeks, predicted further ~3–4 %.

### Correctness (no current blockers)

The lone remaining Test262 failure (`staging/sm/generators/syntax.js`)
is documented out-of-scope.

### Bench infrastructure

`tests/baselines/bench_baseline.json` is at session-20 numbers. Not
relocked because the machine has been thermally noisy throughout S22.
A clean-system relock would tighten the perf regression gate. Not
urgent.

### Stage-3 decorators (out of scope, future)

`accessor` parses as class-element modifier. Full Decorator semantics
(method/class decorators, auto-accessor lowering) are not yet emitted.

### JSX corpus growth (nice-to-have)

Gate has 18 fixtures (10 ambiguity + 8 pure JSX). Adding real-world JSX
from a vendored library would broaden coverage.

---

*Generated: Session 23, 2026-04-29.*

*S22 took kessel from `1.346× OXC` to parity at `1.002×` by fixing
two structural Odin-runtime issues (`_append_elem` not specialising,
bump pool over-conservatively sized) and one identifier-scan
inefficiency.*

*S23 took it past parity to `0.990×` (kessel BEATS OXC) via two
low-cost changes: a Darwin CPU QoS pin (real-world hedge, bench-neutral)
and profile-guided cap bumps at the top 8 `bump_append` slow-path
callsites (-1.2 pp geo-mean). Three failed experiments along the way
(prefault arena, scope_map cap bump, source-size-conditional caps)
proved that doubling caps in high-frequency code paths or duplicating
work already done by warm-up costs more than it saves — the wins came
only from targeting the long-tail callsites.*

*Next agent: read `AGENTS.md`, then this doc, then
`docs/perf-session-23.md` for the latest measurements and
`docs/perf-architectural-analysis.md` for the Tier 2 E (per-letter
handlers, ~1 week, predicted 1–2 ms on monaco) and Tier 3 F (SoA AST,
~5 weeks, predicted 3–4 %) levers still on the table.*

*The `bump_append` pattern (S22) plus profile-guided cap tuning (S23)
is the cleanest Odin-perf playbook from these sessions — applicable
to any Odin program with hot dynamic-array appends. Profile slow-path
hits by `#caller_location`, then bump initial caps at the long-tail
callsites that account for >80 % of the events.*
