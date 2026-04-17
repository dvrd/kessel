#!/bin/bash

echo "=== Kessel Parser Benchmark - Real JavaScript Files ==="
echo ""

run_benchmark() {
    local file=$1
    local name=$2
    local runs=5
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    local size=$(wc -c < "$file")
    local lines=$(wc -l < "$file")
    
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
    
    # Calculate throughput (KB/s)
    if [ $avg_time -gt 0 ]; then
        local throughput=$((size / avg_time))
    else
        local throughput=0
    fi
    
    # Calculate bytes per token (estimated)
    local bytes_per_token=$((size / (arena / 100 + 1)))
    
    printf "%-20s %8sKB %8s %6sms %5d-%5d %10sKB/s %12sB %8s\n" \
        "$name" "$((size/1024))" "$lines" "$avg_time" "$min_time" "$max_time" "$throughput" "$arena" "$errors"
}

run_acorn() {
    local file=$1
    local name=$2
    local runs=5
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    local size=$(wc -c < "$file")
    
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
    if [ $avg_time -gt 0 ]; then
        local throughput=$((size / avg_time))
    else
        local throughput=0
    fi
    
    printf "%-20s %8sKB %6sms %5d-%5d %10sKB/s\n" \
        "$name" "$((size/1024))" "$avg_time" "$min_time" "$max_time" "$throughput"
}

echo "=== Kessel Parser Results ==="
printf "%-20s %10s %8s %8s %12s %12s %12s %8s\n" \
    "File" "Size" "Lines" "Avg(ms)" "Min-Max" "Throughput" "Arena" "Errors"
echo "--------------------------------------------------------------------------------------------"

run_benchmark "real_js/dayjs.js" "Day.js"
run_benchmark "real_js/axios.js" "Axios"
run_benchmark "real_js/react.js" "React"
run_benchmark "real_js/jquery.js" "jQuery"
run_benchmark "real_js/lodash.js" "Lodash"
run_benchmark "real_js/d3.js" "D3.js"
run_benchmark "real_js/vue.js" "Vue"
run_benchmark "real_js/react-dom.js" "ReactDOM"
run_benchmark "real_js/three.js" "Three.js"
run_benchmark "example.js" "Example"

echo ""
echo "=== Acorn (Node.js) Reference ==="
printf "%-20s %10s %8s %12s\n" "File" "Size" "Avg(ms)" "Throughput"
echo "----------------------------------------------------"
run_acorn "real_js/dayjs.js" "Day.js"
run_acorn "real_js/axios.js" "Axios"
run_acorn "real_js/react.js" "React"
run_acorn "real_js/jquery.js" "jQuery"
run_acorn "real_js/lodash.js" "Lodash"
run_acorn "real_js/d3.js" "D3.js"
run_acorn "real_js/vue.js" "Vue"
run_acorn "example.js" "Example"

echo ""
echo "=== Summary ==="
echo "Files parsed: $(ls real_js/*.js 2>/dev/null | wc -l) real JavaScript libraries"
echo ""

