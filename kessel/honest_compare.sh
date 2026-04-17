#!/bin/bash

echo "=== Honest Kessel vs OXC Comparison ==="
echo ""

# Test file - realistic size
cat > test.js << 'EOF'
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
export { utils, Calculator, obj };
EOF

SIZE=$(wc -c < test.js)
echo "File size: ${SIZE} bytes"
echo ""

# Verify both work
echo "Verifying parsers work..."
echo "Kessel:"
./kessel parse test.js 2>&1 | head -3

echo ""
echo "OXC:"
node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); const r = parseSync('test.js', fs.readFileSync('test.js', 'utf8')); console.log('Parsed:', !!r.program);" 2>&1

# Proper benchmark with warmup
echo ""
echo "=== Warmup (10 runs) ==="
for i in {1..10}; do
  ./kessel parse test.js > /dev/null 2>&1
  node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); parseSync('t', fs.readFileSync('test.js', 'utf8'));" 2>/dev/null
done

echo ""
echo "=== Benchmark: 100 runs ==="

echo ""
echo "Kessel (Odin):"
START=$(date +%s%N)
for i in {1..100}; do
  ./kessel parse test.js > /dev/null 2>&1
done
END=$(date +%s%N)
TOTAL_KESSEL=$(( (END - START) / 1000000 ))
AVG_KESSEL=$(echo "scale=3; $TOTAL_KESSEL / 100" | bc)
echo "  Total: ${TOTAL_KESSEL}ms, Avg: ${AVG_KESSEL}ms"

echo ""
echo "OXC (Rust via Node.js):"
START=$(date +%s%N)
for i in {1..100}; do
  node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); const r = parseSync('t', fs.readFileSync('test.js', 'utf8')); if(!r.program) throw 'err';" 2>/dev/null
done
END=$(date +%s%N)
TOTAL_OXC=$(( (END - START) / 1000000 ))
AVG_OXC=$(echo "scale=3; $TOTAL_OXC / 100" | bc)
echo "  Total: ${TOTAL_OXC}ms, Avg: ${AVG_OXC}ms"

# Calculate ratio
if [ "$AVG_OXC" != "0" ]; then
  RATIO=$(echo "scale=1; $AVG_KESSEL / $AVG_OXC" | bc)
  echo ""
  echo "=== Result ==="
  echo "Kessel is ${RATIO}x slower than OXC"
fi

rm -f test.js

