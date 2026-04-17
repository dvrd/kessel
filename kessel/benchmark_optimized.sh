#!/bin/bash

echo "=== Kessel Optimized vs OXC ==="
echo ""

# Create test file
cat > bench.js << 'EOF'
const utils = {
  add: (a, b) => a + b,
  mul: (a, b) => a * b,
};

class Calculator {
  constructor() {
    this.history = [];
  }
  
  calculate(op, a, b) {
    let result;
    switch(op) {
      case 'add': result = utils.add(a, b); break;
      case 'mul': result = utils.mul(a, b); break;
    }
    this.history.push({ op, a, b, result });
    return result;
  }
}

const arr = [1, 2, 3].map(x => x * 2);
const evens = arr.filter(n => n % 2 === 0);
EOF

size=$(wc -c < bench.js)
echo "Test file: ${size} bytes"
echo ""

# OXC (with Node overhead)
echo "OXC (Rust + Node.js overhead):"
total=0
for i in {1..50}; do
    start=$(date +%s%N)
    node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); parseSync('bench.js', fs.readFileSync('bench.js', 'utf8'));" 2>/dev/null
    end=$(date +%s%N)
    ms=$(( (end - start) / 1000000 ))
    total=$((total + ms))
done
avg_oxc=$((total / 50))
echo "  Average (50 runs): ${avg_oxc}ms"

# Kessel (native)
echo ""
echo "Kessel (Odin native, optimized):"
total=0
for i in {1..50}; do
    start=$(date +%s%N)
    ./kessel parse bench.js > /dev/null 2>&1
    end=$(date +%s%N)
    ms=$(( (end - start) / 1000000 ))
    total=$((total + ms))
done
avg_kessel=$((total / 50))
echo "  Average (50 runs): ${avg_kessel}ms"

# Calculate ratio
if [ $avg_oxc -gt 0 ]; then
    ratio=$((avg_kessel / avg_oxc))
    echo ""
    echo "Kessel is ~${ratio}x slower than OXC"
fi

rm -f bench.js

