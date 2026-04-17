#!/bin/bash

echo "=== Quick Kessel Parser Benchmark ==="
echo ""

# Quick single run benchmark
quick_test() {
    local file=$1
    local name=$2
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    local size=$(wc -c < "$file")
    local lines=$(wc -l < "$file")
    local size_kb=$((size / 1024))
    
    echo -n "Testing $name (${size_kb}KB, ${lines} lines)... "
    
    # Single run
    local start=$(date +%s%N)
    timeout 30 ./kessel parse "$file" > /tmp/kessel_out.json 2>/tmp/kessel_stats.txt
    local status=$?
    local end=$(date +%s%N)
    
    if [ $status -ne 0 ]; then
        echo "TIMEOUT/ERROR (took >30s)"
        return
    fi
    
    local time_ms=$(( (end - start) / 1000000 ))
    local arena=$(grep "Arena used:" /tmp/kessel_stats.txt | head -1 | awk '{print $3}')
    local errors=$(grep "Parse errors:" /tmp/kessel_stats.txt | head -1 | awk '{print $3}')
    
    if [ $time_ms -gt 0 ]; then
        local throughput=$((size / time_ms))
    else
        local throughput=0
    fi
    
    echo "${time_ms}ms, ${throughput}KB/s, arena: ${arena}B, errors: ${errors}"
}

# Test small files first
echo "=== Small Files (< 100KB) ==="
quick_test "real_js/dayjs.js" "Day.js (7KB)"
quick_test "real_js/axios.js" "Axios (95KB)"
quick_test "real_js/react.js" "React (107KB)"

# Skip very large files for now as they take too long
echo ""
echo "=== Skipped (too large for quick test) ==="
ls -lh real_js/*.js 2>/dev/null | awk '$5 ~ /M/ {print $9, $5}' | while read file size; do
    echo "$file ($size) - would take >30s"
done

echo ""
echo "=== Acorn Comparison (reference) ==="
for file in "real_js/dayjs.js" "real_js/axios.js" "real_js/react.js"; do
    if [ -f "$file" ]; then
        name=$(basename "$file" .js)
        size=$(wc -c < "$file")
        start=$(date +%s%N)
        timeout 5 acorn "$file" > /dev/null 2>&1
        end=$(date +%s%N)
        time_ms=$(( (end - start) / 1000000 ))
        throughput=$((size / (time_ms + 1)))
        echo "$name: ${time_ms}ms, ${throughput}KB/s"
    fi
done

