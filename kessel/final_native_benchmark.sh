#!/bin/bash

echo "=== Native Parser Benchmark (Pure CLI, No Node.js Overhead) ==="
echo ""

# Create test file
cat > test.js << 'EOF'
const utils = { add: (a, b) => a + b, mul: (a, b) => a * b, div: (a, b) => a / b };
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
export { utils, Calculator, obj };
EOF

SIZE=$(wc -c < test.js)
LINES=$(wc -l < test.js)
echo "Test file: ${SIZE} bytes, ${LINES} lines"
echo ""

# Single run timing with warmupecho "Warming up..."./kessel parse test.js > /dev/null 2>&1
swc parse --sync test.js > /dev/null 2>&1
hermes -parse test.js > /dev/null 2>&1
acorn test.js > /dev/null 2>&1

echo "=== Cold Start (First Run) ==="
echo "This includes binary loading time:"
echo ""

echo -n "Kessel (Odin):    "
time ./kessel parse test.js > /dev/null 2>&1 2>&1 | grep real | awk '{print $2}'

echo -n "SWC (Rust+Node):  "
time swc parse --sync test.js > /dev/null 2>&1 2>&1 | grep real | awk '{print $2}'

echo -n "Hermes (C++):     "
time hermes -parse test.js > /dev/null 2>&1 2>&1 | grep real | awk '{print $2}'

echo -n "Acorn (Node.js):  "
time acorn test.js > /dev/null 2>&1 2>&1 | grep real | awk '{print $2}'

echo ""
echo "=== Hot Runs (10 runs, fastest measured) ==="
echo ""

run_benchmark() {
    local name=$1
    local cmd=$2
    local total=0
    local min=999999
    local max=0
    
    for i in {1..10}; do
        local start=$(date +%s%N)
        eval "$cmd > /dev/null 2>&1"
        local end=$(date +%s%N)
        local ms=$(( (end - start) / 1000000 ))
        total=$((total + ms))
        [ $ms -lt $min ] && min=$ms
        [ $ms -gt $max ] && max=$ms
    done
    
    local avg=$((total / 10))
    printf "%-17s avg=%3dms  min=%3dms  max=%3dms\n" "$name" "$avg" "$min" "$max"
}

run_benchmark "Kessel (Odin)"   "./kessel parse test.js"
run_benchmark "SWC (Rust)"      "swc parse --sync test.js"
run_benchmark "Hermes (C++)"    "hermes -parse test.js"
run_benchmark "Acorn (Node.js)" "acorn test.js"

rm -f test.js

echo ""
echo "=== Verdict ==="
echo "Kessel: Native binary, no startup overhead, arena allocation"
echo "SWC:    Native Rust + Node.js CLI wrapper adds overhead"
echo "Hermes: Native C++, production parser for React Native"
echo "Acorn:  Pure JavaScript, Node.js runtime"

