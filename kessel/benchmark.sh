#!/bin/bash

echo "=== Kessel Parser Benchmark ==="
echo ""

# Function to benchmark kessel
benchmark_kessel() {
    local file=$1
    local name=$2
    
    # Warmup
    ./kessel parse "$file" > /dev/null 2>&1
    
    # Actual benchmark with hyperfine-like approach
    local total_time=0
    local runs=5
    
    for i in $(seq 1 $runs); do
        local start=$(date +%s%N)
        ./kessel parse "$file" > /tmp/kessel_out.json 2>/tmp/kessel_stats.txt
        local end=$(date +%s%N)
        local time_ms=$(( (end - start) / 1000000 ))
        total_time=$((total_time + time_ms))
    done
    
    local avg_time=$((total_time / runs))
    local arena=$(grep "Arena used:" /tmp/kessel_stats.txt | head -1 | awk '{print $3}')
    local errors=$(grep "Parse errors:" /tmp/kessel_stats.txt | head -1 | awk '{print $3}')
    
    echo "$name: ${avg_time}ms (arena: ${arena:-N/A} bytes, errors: ${errors:-N/A})"
}

# Function to benchmark acorn
benchmark_acorn() {
    local file=$1
    local name=$2
    
    # Warmup
    acorn "$file" > /dev/null 2>&1
    
    local total_time=0
    local runs=5
    
    for i in $(seq 1 $runs); do
        local start=$(date +%s%N)
        acorn "$file" > /tmp/acorn_out.json 2>&1
        local end=$(date +%s%N)
        local time_ms=$(( (end - start) / 1000000 ))
        total_time=$((total_time + time_ms))
    done
    
    local avg_time=$((total_time / runs))
    echo "$name: ${avg_time}ms (acorn - reference)"
}

echo "File sizes:"
ls -lh bench_*.js 2>/dev/null | awk '{print $9, $5}'
echo ""

echo "=== Kessel Performance ==="
benchmark_kessel "bench_tiny.js" "Tiny (413B)"
benchmark_kessel "bench_small.js" "Small (4.2KB)"
benchmark_kessel "bench_medium.js" "Medium (45KB)"
benchmark_kessel "bench_realistic.js" "Realistic (50KB)"
benchmark_kessel "bench_large.js" "Large (477KB)"
benchmark_kessel "example.js" "Example (1.2KB)"

echo ""
echo "=== Acorn Comparison (reference) ==="
benchmark_acorn "bench_tiny.js" "Tiny"
benchmark_acorn "bench_small.js" "Small"
benchmark_acorn "bench_medium.js" "Medium"
benchmark_acorn "bench_realistic.js" "Realistic"
# Skip large for acorn to save time

