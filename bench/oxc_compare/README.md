# OXC Comparison Harness

Two Rust binaries that wrap OXC for head-to-head comparison with Kessel:

- **`oxc_cli_equiv`** — CLI analog to `kessel_bin parse`: reads file, parses, emits ESTree JSON to stdout.
- **`oxc_microbench`** — In-process loop analog to `kessel_bin microbench`: runs `N` iterations of parse + black_box, reports mean/min/max/P50/P95/P99.

## Setup

```bash
# From kessel repo root:
git clone https://github.com/oxc-project/oxc.git ../oxc
git -C ../oxc checkout "$(node -p "require('./OXC_ORACLE.json').oxc_git_commit")"
task bench:oxc:verify
task bench:oxc:build
# Binaries land in bench/oxc_compare/target/release/
```

`OXC_ORACLE.json` is the source-of-truth pin for OXC references: the Rust
checkout commit used by comparison binaries, and the npm `oxc-parser` version
used by JS-side deep-diff/fuzz checks. Update it only as part of an
intentional oracle refresh, then rebuild the binaries and review any snapshot,
deep-diff, fuzz, or benchmark changes.

## Run

```bash
# CLI (emits full ESTree JSON):
./target/release/oxc_cli_equiv ../../kessel/bench_large.js > /dev/null

# Microbench (in-process loop, pure parse cost):
./target/release/oxc_microbench ../../kessel/bench_large.js 100
```

## Full comparison sweep

See `../../kessel/bench_vs_oxc.sh` for a reproducible sweep that measures both
Kessel and OXC on the same 3 files (small/medium/large), both CLI and
microbench, and prints a comparison table.

## Results

Measured baselines live in `../../docs/BENCHMARKS.md`. Re-run to update.
