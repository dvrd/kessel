#!/bin/bash

echo "=== Native Parser Benchmark (No Node.js Overhead) ==="
echo ""

# Create test files of different sizes
cat > test_small.js << 'EOF'
const x = 1 + 2;
const arr = [1, 2, 3];
function test() { return x; }
EOF

cat > test_medium.js << 'EOF'
const utils = {
  add: (a, b) => a + b,
  mul: (a, b) => a * b,
  div: (a, b) => a / b,
};

class Calculator {
  constructor() { this.history = []; }
  calc(op, a, b) {
    const r = utils[op](a, b);
    this.history.push({ op, a, b, r });
    return r;
  }
  getHistory() { return this.history; }
}

const arr = [1, 2, 3, 4, 5].map(x => x * 2).filter(n => n > 4);
const obj = { arr, calc: new Calculator() };
export { utils, Calculator };
EOF

# Copy to make larger files
for i in {1..5}; do cat test_medium.js >> test_large.js; done

echo "File sizes:"
ls -lh test_*.js | awk '{print $9, $5}'
echo ""

# Benchmark function
benchmark_cmd() {
    local cmd=$1
    local file=$2
    local name=$3
    local runs=10
    
    echo -n "$name ($file): "
    
    total=0
    min=999999
    max=0
    
    for i in $(seq 1 $runs); do
        start=$(date +%s%N)
        eval "$cmd $file > /dev/null 2>&1"
        end=$(date +%s%N)
        
        ms=$(( (end - start) / 1000000 ))
        total=$((total + ms))
        [ $ms -lt $min ] && min=$ms
        [ $ms -gt $max ] && max=$ms
    done
    
    avg=$((total / runs))
    size=$(wc -c < "$file")
    [ $avg -gt 0 ] && throughput=$((size / avg)) || throughput=0
    
    echo "avg=${avg}ms min=${min}ms max=${max}ms (${throughput}B/ms)"
}

echo "=== Kessel (Odin) ==="
benchmark_cmd "./kessel parse" "test_small.js" "Small"
benchmark_cmd "./kessel parse" "test_medium.js" "Medium"
benchmark_cmd "./kessel parse" "test_large.js" "Large"

echo ""
echo "=== SWC (Rust) ==="
benchmark_cmd "swc parse --sync" "test_small.js" "Small"
benchmark_cmd "swc parse --sync" "test_medium.js" "Medium"
benchmark_cmd "swc parse --sync" "test_large.js" "Large"

echo ""
echo "=== Acorn (Node.js baseline) ==="
benchmark_cmd "acorn" "test_small.js" "Small"
benchmark_cmd "acorn" "test_medium.js" "Medium"
benchmark_cmd "acorn" "test_large.js" "Large"

# Cleanup
rm -f test_*.js

echo ""
echo "=== Summary ==="
echo "Kessel (Odin) vs SWC (Rust) - Lower is better"

