#!/bin/bash

echo "=== Kessel vs OXC (The Gold Standard) ==="
echo ""

# Create test files of different sizes
echo "Creating test files..."

# Small file (example.js is ~1KB)
cp example.js test_small.js

# Medium file (~10KB)
for i in {1..10}; do cat example.js >> test_medium.js; done

# Large file (~100KB) 
for i in {1..100}; do cat example.js >> test_large.js; done

# Very large (~500KB)
for i in {1..500}; do cat example.js >> test_vlarge.js; done

echo ""
echo "File sizes:"
ls -lh test_*.js | awk '{print $9, $5}'
echo ""

# Benchmark OXC
benchmark_oxc() {
    local file=$1
    local name=$2
    
    [ ! -f "$file" ] && return
    
    size=$(wc -c < "$file")
    
    # Node script handles multiple runs internally
    result=$(node bench_oxc.js "$file" 2>&1)
    
    printf "%-15s %8sKB %20s %8s\n" "$name" "$((size/1024))" "$result" "$((size/1024))"
}

# Benchmark Kessel
benchmark_kessel() {
    local file=$1
    local name=$2
    
    [ ! -f "$file" ] && return
    
    size=$(wc -c < "$file")
    
    # Single run (already fast enough)
    start=$(date +%s%N)
    ./kessel parse "$file" > /dev/null 2>/tmp/stats.txt
    end=$(date +%s%N)
    
    time_ms=$(( (end - start) / 1000000 ))
    if [ $time_ms -eq 0 ]; then time_ms=1; fi
    throughput=$((size / time_ms))
    
    printf "%-15s %8sKB %6sms %12sKB/s\n" "$name" "$((size/1024))" "$time_ms" "$throughput"
}

echo "=== OXC Performance (Rust - Reference) ==="
printf "%-15s %8s %20s %8s\n" "File" "Size" "Time(10 runs avg)" "KB/s"
echo "--------------------------------------------------------------"
benchmark_oxc "test_small.js" "Small"
benchmark_oxc "test_medium.js" "Medium"
benchmark_oxc "test_large.js" "Large"
benchmark_oxc "test_vlarge.js" "Very Large"

echo ""
echo "=== Kessel Performance (Odin) ==="
printf "%-15s %8s %8s %12s\n" "File" "Size" "Time" "KB/s"
echo "----------------------------------------------"
benchmark_kessel "test_small.js" "Small"
benchmark_kessel "test_medium.js" "Medium"
benchmark_kessel "test_large.js" "Large"
benchmark_kessel "test_vlarge.js" "Very Large"

# Cleanup
rm -f test_*.js bench_oxc.js

echo ""
echo "=== Summary ==="
echo "OXC is written in Rust with advanced optimizations"
echo "Kessel is written in Odin (no JIT, pure compiled)"

