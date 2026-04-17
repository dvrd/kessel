#!/bin/bash

echo "=== Kessel Parser Benchmark (Valid JS) ==="
echo ""

benchmark_kessel() {
    local file=$1
    local name=$2
    local runs=10
    
    # Check file exists
    if [ ! -f "$file" ]; then
        echo "$name: FILE NOT FOUND"
        return
    fi
    
    # Warmup
    ./kessel parse "$file" > /dev/null 2>&1
    
    local total_time=0
    local min_time=999999
    local max_time=0
    
    for i in $(seq 1 $runs); do
        local start=$(date +%s%N)
        ./kessel parse "$file" > /tmp/kessel_out.json 2>/tmp/kessel_stats.txt
        local end=$(date +%s%N)
        local time_ms=$(( (end - start) / 1000000 ))
        total_time=$((total_time + time_ms))
        [ $time_ms -lt $min_time ] && min_time=$time_ms
        [ $time_ms -gt $max_time ] && max_time=$time_ms
    done
    
    local avg_time=$((total_time / runs))
    local arena=$(grep "Arena used:" /tmp/kessel_stats.txt | head -1 | awk '{print $3}')
    local errors=$(grep "Parse errors:" /tmp/kessel_stats.txt | head -1 | awk '{print $3}')
    local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
    
    # Calculate throughput (KB/s)
    if [ $avg_time -gt 0 ]; then
        local throughput=$((size / avg_time))
    else
        local throughput=0
    fi
    
    printf "%-20s %6d ms  min: %3d  max: %3d  throughput: %4d KB/s  arena: %10s bytes  errors: %s\n" \
        "$name" "$avg_time" "$min_time" "$max_time" "$throughput" "$arena" "$errors"
}

benchmark_acorn() {
    local file=$1
    local name=$2
    local runs=10
    
    if [ ! -f "$file" ]; then
        echo "$name: FILE NOT FOUND"
        return
    fi
    
    # Warmup
    acorn "$file" > /dev/null 2>&1
    
    local total_time=0
    local min_time=999999
    local max_time=0
    
    for i in $(seq 1 $runs); do
        local start=$(date +%s%N)
        acorn "$file" > /tmp/acorn_out.json 2>&1
        local end=$(date +%s%N)
        local time_ms=$(( (end - start) / 1000000 ))
        total_time=$((total_time + time_ms))
        [ $time_ms -lt $min_time ] && min_time=$time_ms
        [ $time_ms -gt $max_time ] && max_time=$time_ms
    done
    
    local avg_time=$((total_time / runs))
    local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "0")
    
    if [ $avg_time -gt 0 ]; then
        local throughput=$((size / avg_time))
    else
        local throughput=0
    fi
    
    printf "%-20s %6d ms  min: %3d  max: %3d  throughput: %4d KB/s\n" \
        "$name" "$avg_time" "$min_time" "$max_time" "$throughput"
}

echo "=== File Sizes ==="
ls -lh valid_*.js 2>/dev/null | awk '{printf "%-25s %s\n", $9, $5}'
echo ""

echo "=== Kessel Performance ==="
printf "%-20s %8s  %8s  %8s  %18s  %12s  %8s\n" "File" "Avg(ms)" "Min" "Max" "Throughput(KB/s)" "Arena(bytes)" "Errors"
echo "---------------------------------------------------------------------------------------------------------------------"
benchmark_kessel "valid_tiny.js" "Tiny (562B)"
benchmark_kessel "valid_small.js" "Small (5.2KB)"
benchmark_kessel "valid_medium.js" "Medium (55KB)"
benchmark_kessel "valid_realistic.js" "Realistic (247KB)"
benchmark_kessel "valid_large.js" "Large (572KB)"
benchmark_kessel "example.js" "Example (1.2KB)"

echo ""
echo "=== Acorn Reference (Node.js parser) ==="
printf "%-20s %8s  %8s  %8s  %18s\n" "File" "Avg(ms)" "Min" "Max" "Throughput(KB/s)"
echo "-------------------------------------------------------------------------"
benchmark_acorn "valid_tiny.js" "Tiny"
benchmark_acorn "valid_small.js" "Small"
benchmark_acorn "valid_medium.js" "Medium"
benchmark_acorn "valid_realistic.js" "Realistic"
benchmark_acorn "valid_large.js" "Large"
benchmark_acorn "example.js" "Example"

