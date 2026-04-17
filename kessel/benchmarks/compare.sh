#!/bin/bash
# Compare Kessel vs acorn vs esprima

WORK_DIR="/tmp/kessel-worktrees/perf-measure"
BIN="$WORK_DIR/kessel_bin"
SUITE="/tmp/bench_suite"
TIMEFORMAT='%3R'

files="tiny.js small.js medium.js large.js"

# Headers
echo "| Parser | File | Size | Min(s) | Max(s) | Avg(s) | StdDev |"
echo "|--------|------|------|--------|--------|--------|--------|"

for file in $files; do
    filepath="$SUITE/$file"
    size=$(stat -f%z "$filepath" 2>/dev/null || stat -c%s "$filepath" 2>/dev/null)
    
    # Kessel runs
    min=9999; max=0; total=0; sumsq=0
    for run in $(seq 1 10); do
        t=$( { time ( "$BIN" parse "$filepath" >/dev/null 2>&1 ) ; } 2>&1 | tail -1 )
        t=$(echo "$t" | sed 's/s//')
        total=$(echo "$total + $t" | bc)
        sumsq=$(echo "$sumsq + $t * $t" | bc)
        if (( $(echo "$t < $min" | bc -l) )); then min=$t; fi
        if (( $(echo "$t > $max" | bc -l) )); then max=$t; fi
    done
    avg=$(echo "scale=4; $total / 10" | bc)
    stddev=$(echo "scale=4; sqrt($sumsq/10 - $avg*$avg)" | bc 2>/dev/null || echo "0.00")
    echo "| Kessel | $file | ${size}B | $min | $max | $avg | $stddev |"
    
    # Acorn runs (if available)
    if command -v acorn 2>/dev/null; then
        min=9999; max=0; total=0; sumsq=0
        for run in $(seq 1 10); do
            t=$( { time ( acorn "$filepath" >/dev/null 2>&1 ) ; } 2>&1 | tail -1 )
            t=$(echo "$t" | sed 's/s//')
            total=$(echo "$total + $t" | bc)
            sumsq=$(echo "$sumsq + $t * $t" | bc)
            if (( $(echo "$t < $min" | bc -l) )); then min=$t; fi
            if (( $(echo "$t > $max" | bc -l) )); then max=$t; fi
        done
        avg=$(echo "scale=4; $total / 10" | bc)
        stddev=$(echo "scale=4; sqrt($sumsq/10 - $avg*$avg)" | bc 2>/dev/null || echo "0.00")
        echo "| Acorn | $file | ${size}B | $min | $max | $avg | $stddev |"
    fi
    
    # Esprima runs (via Node script)
    if command -v node 2>/dev/null; then
        min=9999; max=0; total=0; sumsq=0
        for run in $(seq 1 10); do
            t=$( { time ( node -e "require('esprima').parse(require('fs').readFileSync('$filepath','utf8'))" >/dev/null 2>&1 ) ; } 2>&1 | tail -1 )
            t=$(echo "$t" | sed 's/s//')
            total=$(echo "$total + $t" | bc)
            sumsq=$(echo "$sumsq + $t * $t" | bc)
            if (( $(echo "$t < $min" | bc -l) )); then min=$t; fi
            if (( $(echo "$t > $max" | bc -l) )); then max=$t; fi
        done
        avg=$(echo "scale=4; $total / 10" | bc)
        stddev=$(echo "scale=4; sqrt($sumsq/10 - $avg*$avg)" | bc 2>/dev/null || echo "0.00")
        echo "| Esprima | $file | ${size}B | $min | $max | $avg | $stddev |"
    fi
done
