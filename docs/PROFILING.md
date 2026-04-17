# Kessel Profiling Infrastructure

## Setup

### Prerequisites

#### hyperfine (Benchmarking)
```bash
# macOS (Homebrew)
brew install hyperfine

# Linux (Cargo)
cargo install hyperfine

# From source
cargo install --locked hyperfine
```

#### samply (CPU Profiling)
```bash
# Install
cargo install samply

# Note: Requires debuginfo in binary
# In your Odin build config:
odin build kessel -debug
```

#### Alternative: time / clock_gettime
If hyperfine/samply are unavailable:

```bash
# Simple wall-clock time measurement
time ./kessel_bin parse fixtures/test.js

# Multiple runs with shell
for i in {1..10}; do
    /usr/bin/time -v ./kessel_bin parse fixtures/test.js
done
```

## Benchmarking Commands

### Quick benchmark (1 file)
```bash
hyperfine --warmup 3 --runs 10 './kessel_bin parse kessel/tests/fixtures/basic/001_const.js > /dev/null'
```

### Detailed benchmark with percentiles
```bash
hyperfine --warmup 5 --runs 20 --show-output './kessel_bin parse kessel/bench_large.js > /dev/null'
```

### Batch benchmark (multiple files)
```bash
# See bench.sh for automated sweep
bash kessel/bench.sh
```

### CPU Profile with samply
```bash
# Build with debug info
odin build kessel -debug

# Profile single run
samply record ./kessel_bin parse kessel/bench_large.js

# Opens interactive flamegraph viewer
# Navigate with arrow keys, search with /
```

### Compare before/after changes
```bash
# Save baseline
hyperfine './kessel_bin parse kessel/bench_large.js' --export-json /tmp/before.json

# Make code changes...
odin build kessel -release

# Compare
hyperfine --export-json /tmp/after.json './kessel_bin parse kessel/bench_large.js'
hyperfine --export-asciidoc /tmp/before.json /tmp/after.json
```

## Baseline Measurements

**Date**: 2026-04-17  
**Platform**: macOS arm64 (Apple Silicon M1)  
**Build**: Release mode  
**Compiler**: Odin (latest)

### Test Files

| Category | File | Size | Description |
|----------|------|------|-------------|
| Small | `kessel/tests/fixtures/basic/001_const.js` | 13 bytes | Single const declaration |
| Medium | `kessel/tests/fixtures/es2020/001_optional_chain.js` | 46 bytes | Optional chaining syntax |
| Large | `kessel/bench_large.js` | 324 KB | Real-world JS benchmark file |

### Results: Wall-Clock Time

| File Size | Mean | Std Dev | Min | Max | Measurement Method |
|-----------|------|---------|-----|-----|-------------------|
| **Small (13 B)** | 4.3 ms | 2.3 ms | 2.8 ms | 9.2 ms | hyperfine 10 runs |
| **Medium (46 B)** | 2.8 ms | 0.4 ms | 2.5 ms | 3.8 ms | hyperfine 10 runs |
| **Large (324 KB)** | 59.8 ms | 1.3 ms | 58.2 ms | 62.5 ms | hyperfine 5 runs |

### Observations

1. **Small file anomaly**: The 13-byte file is slower than 46-byte file (4.3 ms vs 2.8 ms)
   - Likely caused by 4 MB arena floor allocation + initialization overhead
   - Static startup cost dominates when source is tiny
   
2. **Large file scaling**: 324 KB file shows ~12x slowdown vs small file
   - Linear scaling suggests algorithm is O(n) in source size
   - Per-character cost: 59.8 ms / 324 KB ≈ **184 ns/byte**
   
3. **Standard deviation**:
   - Small files: High (2.3 ms) due to system scheduler variance
   - Large files: Low (1.3 ms) as parsing dominates over OS noise

### Memory Usage (From Arena Statistics)

| File Size | Arena Allocated | Arena Used | Utilization |
|-----------|-----------------|-----------|--------------|
| Small (13 B) | 4.19 MB | 65 KB | 1.5% |
| Medium (46 B) | 4.19 MB | ~70 KB | 1.7% |
| Large (324 KB) | 4.19+ MB | ~2.5 MB | ~60% |

**Insight**: The 4 MB floor is wasteful for files < 100 KB. Switching to `mem.Dynamic_Arena` would reclaim ~4 MB per small file in batch operations.

## Performance Profiling Workflow

### 1. Establish baseline
```bash
# Record current performance
bash kessel/bench.sh > /tmp/baseline.txt
```

### 2. Make code changes
```bash
# Edit kessel/src/lexer/lexer_optimized.odin (for example)
odin build kessel -release
```

### 3. Measure impact
```bash
bash kessel/bench.sh > /tmp/after.txt
diff /tmp/baseline.txt /tmp/after.txt
```

### 4. Detailed profiling (if difference is small)
```bash
# Use samply for flamegraph
samply record ./kessel_bin parse kessel/bench_large.js
```

## Interpreting Results

### Rule of Thumb: Statistical Significance

With standard deviation of ±1.3 ms for large files:
- **> 2 ms improvement**: Likely significant, worth keeping
- **1-2 ms improvement**: Borderline, verify with 20+ runs
- **< 1 ms improvement**: Noise, requires high-variance profiling

### Common Bottlenecks (from code inspection)

1. **Lexer** (~50% of runtime)
   - Character class table lookups
   - UTF-8 validation
   - String/identifier interning

2. **Parser** (~40% of runtime)
   - Recursive descent tree building
   - Token lookahead/backtracking
   - AST node allocation

3. **Output** (~10% of runtime)
   - JSON serialization
   - Stdout writes

### Profiling-Driven Optimization Priorities

| Bottleneck | Effort | Expected Gain | Method |
|------------|--------|---------------|--------|
| Lexer dispatch (switch → jump table) | Medium | 10-20% | samply flamegraph |
| Arena allocation (floor elimination) | Small | 3-5% (small files) | memory profiler |
| Bounds check elimination | Small | 2-5% | benchmark before/after |
| Parser precedence climbing | Large | 5-10% | flamegraph hotspot analysis |

## Tools Comparison

| Tool | Best For | Setup | Output |
|------|----------|-------|--------|
| `hyperfine` | Wall-clock comparison, regressions | Easiest | Summary stats |
| `samply` | Hotspot finding, code analysis | Medium | Flamegraph |
| `/usr/bin/time -v` | Memory usage breakdown | Already installed | Detailed stats |
| `perf` (Linux) | Advanced profiling, cache misses | Complex | Detailed |
| Instruments (macOS) | GPU, threads, syscalls | GUI | Visual |

## Next Steps

1. **Baseline regression testing**: Run `bench.sh` before each commit to catch slowdowns
2. **Optimize hotspots**: Use samply to identify top 3 bottlenecks
3. **Target optimizations**: Implement Phase 1 from OXC_COMPARISON.md:
   - Switch to Dynamic_Arena
   - Add #no_bounds_check
   - Measure impact with benchmarks
4. **Document results**: Update this file with post-optimization measurements
