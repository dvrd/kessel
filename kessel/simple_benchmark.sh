#!/bin/bash

echo "=== Simple Kessel Benchmark ==="
echo ""

test_file() {
    local file=$1
    local desc=$2
    
    if [ ! -f "$file" ]; then
        echo "$desc: NOT FOUND"
        return
    fi
    
    local size=$(wc -c < "$file")
    local lines=$(wc -l < "$file")
    
    echo -n "$desc (${size}B, ${lines} lines): "
    
    # Single run with timeout
    local start=$(date +%s%N)
    timeout 3 ./kessel parse "$file" > /tmp/out.json 2>/tmp/stats.txt
    local status=$?
    local end=$(date +%s%N)
    
    if [ $status -ne 0 ]; then
        echo "TIMEOUT/ERROR"
        return
    fi
    
    local time_ms=$(( (end - start) / 1000000 ))
    local arena=$(grep "Arena used:" /tmp/stats.txt | awk '{print $3}')
    local errors=$(grep "Parse errors:" /tmp/stats.txt | awk '{print $3}')
    
    echo "${time_ms}ms, arena: ${arena}B, errors: ${errors}"
}

echo "=== Kessel Tests ==="
test_file "example.js" "Example (67 lines)"

# Create progressively larger valid JS files
echo ""
echo "Creating test files..."

for mult in 1 5 10 50; do
    cat example.js > test_${mult}x.js
    for i in $(seq 2 $mult); do
        cat example.js >> test_${mult}x.js
    done
    lines=$((67 * mult))
    test_file "test_${mult}x.js" "${lines} lines"
done

echo ""
echo "=== Acorn Reference ==="
test_file_acorn() {
    local file=$1
    local desc=$2
    
    [ ! -f "$file" ] && return
    
    local size=$(wc -c < "$file")
    echo -n "$desc: "
    
    local start=$(date +%s%N)
    timeout 3 acorn "$file" > /dev/null 2>&1
    local end=$(date +%s%N)
    
    local time_ms=$(( (end - start) / 1000000 ))
    echo "${time_ms}ms"
}

test_file_acorn "example.js" "Example"
for mult in 1 5 10; do
    lines=$((67 * mult))
    test_file_acorn "test_${mult}x.js" "${lines} lines"
done

# Cleanup
rm -f test_*.js

