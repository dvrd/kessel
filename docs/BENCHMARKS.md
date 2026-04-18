# Kessel Benchmarks

**Last updated**: 2026-04-18  
**Platform**: macOS arm64 (Apple Silicon M1)  
**Kessel commit**: 99af12f (post-virtual-arena, microbench cmd)  
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

### CLI (ESTree JSON output, wall-clock)

| File | Kessel | OXC | Ratio |
|------|--------|-----|-------|
| small (13 B) | 1.7 ms ± 0.2 | 1.7 ms ± 0.1 | **Tie** (1.00× ± 0.16) |
| medium (2.6 KB) | 1.8 ms ± 0.2 | 1.7 ms ± 0.2 | Tie (1.04× ± 0.16) |
| large (324 KB) | 52.5 ms ± 1.2 | 9.7 ms ± 0.4 | **OXC 5.4× faster** |

### Microbench (parse cost only, P50 median)

| File | Kessel P50 | OXC P50 | Ratio |
|------|------------|---------|-------|
| small (13 B) | 6.4 µs | 0.17 µs | **OXC 37.6× faster** |
| medium (2.6 KB) | 68.5 µs | 10.4 µs | **OXC 6.6× faster** |
| large (324 KB) | 14.3 ms | 2.2 ms | **OXC 6.5× faster** |

### Overhead decomposition (CLI − microbench)

| File | Kessel overhead | OXC overhead | Notes |
|------|-----------------|--------------|-------|
| small | 1.69 ms | 1.70 ms | Both dominated by macOS process startup |
| medium | 1.73 ms | 1.69 ms | Same — startup still floor |
| **large** | **38.2 ms** | **7.5 ms** | JSON serialization + stdout write dominates |

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

1. **Byte-dispatch table** replacing the class+switch lexer. ~1.3–1.5× on
   large files, measurable with microbench. See `docs/OXC_COMPARISON.md §1`.
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
| 2026-04-18 | 99af12f | OXC 5.4× | OXC 6.5× | Baseline, first fair comparison |
