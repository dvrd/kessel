#!/bin/bash

echo "=== Kessel vs OXC - Fair Comparison ==="
echo ""

# Create a clean test file
cat > test_1kb.js << 'EOF'
// Simple test
const x = 1;
const y = 2;
function add(a, b) { return a + b; }
const result = add(x, y);
EOF

# Create larger file
cat > test_10kb.js << 'EOF'
// Larger test
const utils = {
  add: (a, b) => a + b,
  mul: (a, b) => a * b,
  div: (a, b) => a / b,
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
      case 'div': result = utils.div(a, b); break;
    }
    this.history.push({ op, a, b, result });
    return result;
  }
  
  getHistory() {
    return this.history;
  }
}

const calc = new Calculator();
console.log(calc.calculate('add', 5, 3));
console.log(calc.calculate('mul', 4, 2));
EOF

# Replicate to get bigger files
for i in {1..10}; do cat test_10kb.js >> test_100kb.js; done

echo "File sizes:"
ls -lh test_*.js | awk '{print $9, $5}'
echo ""

# OXC through Node.js
echo "OXC (Rust via Node.js oxc-parser):"
for file in test_1kb.js test_10kb.js test_100kb.js; do
    [ ! -f "$file" ] && continue
    size=$(wc -c < "$file")
    echo -n "$file (${size}B): "
    
    # Single parse with Node.js overhead
    time node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); parseSync('$file', fs.readFileSync('$file', 'utf8'));" 2>&1 | grep real | awk '{print $2}'
done

echo ""
echo "Kessel (Odin native):"
for file in test_1kb.js test_10kb.js test_100kb.js; do
    [ ! -f "$file" ] && continue
    size=$(wc -c < "$file")
    echo -n "$file (${size}B): "
    
    time ./kessel parse "$file" > /dev/null 2>&1 | grep real | awk '{print $2}'
done

# Cleanup
rm -f test_*.js

