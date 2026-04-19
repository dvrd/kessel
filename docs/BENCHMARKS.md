# Kessel Benchmarks

**Last updated**: 2026-04-19  
**Platform**: macOS arm64 (Apple Silicon M1, 4 P-cores + 4 E-cores)  
**Kessel commit**: working tree after compact-default + SIMD JSON escaping + compact-token parser fast paths  
**OXC ref**: oxc-project/oxc `main` branch (shallow clone)  
**Tools**: hyperfine 1.x (warmup 10, min-runs 50, shell=none)

This document captures measured, reproducible benchmarks of Kessel vs the
reference parser OXC (Rust). See `bench/oxc_compare/` for the comparison harness
and `kessel/bench_vs_oxc.sh` for the reproducible sweep.

## How to reproduce

```bash
# 1. Build Kessel (release)
odin build ./kessel/src -out:./kessel_bin -o:speed

# 2. Clone OXC as a sibling directory
git clone --depth 1 https://github.com/oxc-project/oxc.git ../oxc

# 3. Build OXC comparison binaries
cd bench/oxc_compare && cargo build --release && cd ../..

# 4. Run the full sweep
bash kessel/bench_vs_oxc.sh
```

## Test files

| Alias | Path | Size |
|-------|------|------|
| small  | `kessel/tests/fixtures/basic/001_const.js` | 13 B |
| medium | `kessel/tests/smoke/es2025.js` | 2,586 B |
| large  | `kessel/bench_large.js` | 324,760 B |

## Two measurement modes

1. **CLI (wall-clock)** — External `hyperfine` timing: `read file → parse → emit
   ESTree JSON → exit`. Includes macOS process startup (~1.2 ms floor) +
   JSON serialization + stdout write.
2. **Microbench (parse cost)** — In-process loop calling `parse()` + black_box,
   N iterations, reporting P50. Isolates the parser itself from process
   overhead.

Both Kessel and OXC emit full ESTree JSON in CLI mode (outputs are same order
of magnitude: 504 B vs 338 B for small; 6.5 MB vs 6.1 MB for large).

## Measured Results

### CLI (ESTree JSON output, wall-clock, single file)

| File | Kessel | OXC | Ratio |
|------|--------|-----|-------|
| small (13 B) | 1.7 ms ± 0.2 | 1.7 ms ± 0.1 | **Tie** (1.00× ± 0.16) |
| medium (2.6 KB) | 1.8 ms ± 0.2 | 1.7 ms ± 0.2 | Tie (1.04× ± 0.16) |
| large (324 KB, compact default) | 22.8 ms ± 0.4 | 10.1 ms ± 1.2 | **OXC 2.3× faster** |
| large (324 KB, `--pretty`) | 31.2 ms ± 0.7 | 10.1 ms ± 1.2 | **OXC 3.1× faster** |

### Multi-file (50 × 324 KB = 16.3 MB total, CLI)

This matches how a bundler or linter actually invokes a parser — many files in
a batch. Kessel's `parse-many` command amortizes the ~1.7 ms process startup
across all files and parallelizes via a thread pool.

| Strategy | Time | Notes |
|----------|------|-------|
| shell loop calling `kessel parse` × 50 | 2820 ms | 50× process startup |
| shell loop calling `oxc_cli_equiv` × 50 | 569 ms | OXC 5.0× faster shell-loop |
| `kessel parse-many --workers 1` | 895 ms | 1 startup, serial parse |
| `kessel parse-many --workers 2` | 481 ms | 1.84× vs w=1 |
| **`kessel parse-many --workers 4`** | **309 ms** | **1.84× faster than OXC shell-loop** |
| `kessel parse-many --workers 8` | 299 ms | Plateau — M1 has 4 P-cores |

Key insight: a fair multi-file CLI comparison depends on the consumer's
invocation pattern. If they invoke CLI per-file (bundler calling out to
parsers), Kessel's `parse-many` beats OXC's single-file CLI shell-loop. If the
consumer is a Rust bundler calling OXC as a library (e.g. Rolldown),
that's a different comparison — OXC's in-process parser still wins
(6.5× faster per microbench) and they can do their own threading.

### Scaling efficiency on Apple M1

| Workers | Time | Speedup | Efficiency |
|---------|------|---------|------------|
| 1 | 884 ms | 1.00× | 100% |
| 2 | 481 ms | 1.84× | 92% |
| 4 | 301 ms | 2.94× | 73% |
| 8 | 299 ms | 2.96× | 37% (plateau) |
| 10 | 331 ms | 2.67× | 27% (regress) |

The plateau at ~3× with 8+ workers is the 4 performance-core limit of the M1.
macOS scheduler doesn't allocate E-cores for user-initiated QoS by default.

### Historical CLI ratios (single large file, tracking progress)

| Kessel commit | CLI large | OXC CLI | Ratio |
|---------------|-----------|---------|-------|
| `683a708` (virtual arena) | 52.5 ms | 9.7 ms | 5.4× |
| `55fd80a` (buffer + out_s) | 53.7 ms | 10.5 ms | 5.1× (noise) |
| `fe0b310` (out_printf → direct) | 49.2 ms | 10.6 ms | 4.6× |
| `e4e8ca7` (thread-safe) | 49.2 ms | 11.1 ms | 5.0× |
| `86065d3` (direct TokenSoA) | 45.0 ms | 10.1 ms | 4.5× |

### Microbench (parse cost only, P50 median)

| File | Kessel P50 | OXC P50 | Ratio |
|------|------------|---------|-------|
| small (13 B) | 6.4 µs | 0.17 µs | **OXC 37.6× faster** |
| medium (2.6 KB) | 68.5 µs | 10.4 µs | **OXC 6.6× faster** |
| large (324 KB) | 12.7 ms | 2.3 ms | **OXC 5.5× faster** |

### Overhead decomposition (CLI − microbench)

| File | Kessel overhead | OXC overhead | Notes |
|------|-----------------|--------------|-------|
| small | 1.69 ms | 1.70 ms | Both dominated by macOS process startup |
| medium | 1.73 ms | 1.69 ms | Same — startup still floor |
| **large (compact default)** | **10.1 ms** | **7.8 ms** | Output gap shrank a lot; parser now dominates more of Kessel's in-process time |

## Interpretation

### Parser algorithm: OXC 6–37× faster

The microbench comparison isolates pure parse cost. OXC is consistently faster
across all file sizes:

- **Small files**: 37× faster in absolute (0.17 µs vs 6.4 µs). This mostly
  reflects fixed per-parse overhead that Kessel pays (arena init, lexer setup)
  that OXC amortizes better.
- **Medium and large files**: ~6.5× faster. The ratio stabilizes, suggesting
  a structural code-generation gap (Rust LLVM + bumpalo + byte-dispatch lexer
  vs Odin + growing arena + class+switch lexer).

### CLI reality is different

For interactive/CLI usage, the macOS process floor (~1.7 ms) dominates on
anything under a few KB. **Kessel and OXC are statistically tied on small and
medium files at the CLI level** — you cannot tell them apart.

On large files, OXC's CLI is 5.4× faster. Breaking this down:

- Parser itself: **-12.1 ms** (Kessel 14.3 ms vs OXC 2.2 ms)
- Output pipeline (JSON + stdout): **-30.7 ms** (Kessel 38.2 ms vs OXC 7.5 ms)

**Both contribute roughly equally** to the CLI gap in absolute terms.

### What OXC does well

Hypotheses for the 6.5× gap on large files, from reading OXC source
(see `docs/OXC_COMPARISON.md`):

| Technique | Estimated contribution |
|-----------|-----------------------|
| bumpalo arena + zero-copy `Box<'a, T>` | 1.5–2× (AST alloc) |
| Byte-dispatch jump table (no class lookup) | 1.3–1.5× (lexer) |
| `#[repr(C, u8)]` compact enum AST | 1.1–1.3× (cache) |
| `assert_unchecked!` bounds elision | 1.1–1.2× |
| Rust LLVM aggressive inlining + years of tuning | multiplicative |

### Byte dispatch experiment (2026-04-18)

Tested two approaches on `feat/byte-dispatch` branch:
1. **Proc pointer table** (v1): +1.5% slower. Indirect call overhead exceeds benefit.
2. **Action enum table** (v2): 0% change. LLVM already compiles byte switch to jump table.

Conclusion: OXC's byte dispatch advantage comes from Rust/LLVM inlining + `unsafe`,
not from the table structure itself. Odin's switch is already optimal for this case.

### Compact-output + parser-fast-path pass (2026-04-19)

Recent measured wins on `bench_large.js`:

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| CLI large (compact default) | 45.0 ms | 22.8 ms | **-49.3%** |
| CLI large (`--pretty`) | 45.0 ms | 31.2 ms | **-30.7%** |
| Lex-only P50 | 3297 µs | 3422 µs | noise / slightly worse |
| Full parse P50 | 10728 µs | 12690 µs | different harness state; parser still primary target |
| Parser `get_current` calls | 342,454 | 59,528 | **-82.6%** |
| Parser lookahead/consume | 4.94× | 2.31× | **-53.2%** |

Interpretation: most CLI gains came from output defaults + escaping improvements;
parser fast paths clearly reduced token-materialization traffic, but the parser
algorithm / AST build remains the dominant library-mode bottleneck.

### Direct TokenSoA stores (2026-04-18)

The real bottleneck was `add_token` doing 8 `append()` calls per token on `[dynamic]T`
arrays. Each append: len check + store + len increment.

Replacing `[dynamic]T` with pre-allocated `[]T` raw slices enables direct stores
with zero overhead:

| Metric | Before | After | Change |
|--------|--------|-------|--------|
| Lex-only P50 | 8485 µs | 3297 µs | **-61.2%** |
| Full parse P50 | 16229 µs | 10728 µs | **-33.9%** |
| CLI large | 49.2 ms | 45.0 ms | **-8.5%** |

These are hypotheses, not profiled contributions. A Linux `samply` run on
`bench_large.js` would localize the actual hotspots in Kessel.

### Scaling

OXC's advantage stays roughly constant (~6×) from 2.6 KB to 324 KB. This
suggests the gap is **structural** (allocator model, dispatch strategy, codegen),
not a fixed constant that larger inputs would amortize away.

## Where Kessel stands today

- **As a library** on real-world code (1–500 KB): 5–15 ms per file. Competitive
  with pre-SWC-era JS parsers; 6.5× behind the current state of the art.
- **As a CLI** on small/medium files: statistically indistinguishable from OXC
  due to process startup floor.
- **As a learning project in Odin**: successful — 86/86 tests, ES2025 coverage,
  and a reasonable performance profile for ~10 k lines of code.

## What would close the gap

Ordered by expected ROI (based on OXC comparison + measurements):

1. ~~**Byte-dispatch table**~~ **Tested — no improvement**. LLVM already uses jump table for byte switches in Odin. OXC's advantage comes from Rust inlining + `unsafe`, not dispatch structure.
2. **JSON output streaming** — write the AST as we walk it instead of
   building a string first. Targets the 30 ms output overhead on large files
   (not the parser gap).
3. **AST layout**: compact Odin union discriminants, reduce per-node size.
   Tangible on bench_large.js (324 KB input produces a ~6 MB AST).
4. **Profile on Linux** with `samply`/`perf` to validate hypotheses before
   implementing.

## Changelog of measured ratios

| Date | Kessel ref | Large CLI ratio | Large parse ratio | Notes |
|------|-----------|-----------------|-------------------|-------|
| 2026-04-18 | `99af12f` | OXC 5.4× | OXC 6.5× | Baseline, first fair comparison |
| 2026-04-18 | `fe0b310` | OXC 4.6× | (unchanged) | After JSON output opts (-6.3%) |
| 2026-04-18 | `86065d3` | OXC 4.5× | OXC 4.6× | Direct []T TokenSoA stores: -33% parse, -61% lex-only |
| 2026-04-18 | `e4e8ca7` | OXC 5.0× single / **Kessel wins multi-file via parse-many** | OXC 6.5× | parse-many scales 2.94× on 4 P-cores |
