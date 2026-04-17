#!/bin/bash

echo "=== Kessel vs OXC Final Comparison ==="
echo ""

# Create test file
cat > tiny.js << 'EOF'
const x = 1 + 2;
EOF

echo "Test: tiny.js ($(wc -c < tiny.js) bytes)"
echo ""

# OXC - 100 runs averaged
echo "OXC (oxc-parser from npm, 100 runs averaged):"
node test_oxc.js tiny.js

# Kessel - 100 runs averaged
echo ""
echo "Kessel (Odin native, 100 runs averaged):"
./kessel parse tiny.js > /dev/null 2>&1  # Warmup

START=$(date +%s%N)
for i in {1..100}; do
    ./kessel parse tiny.js > /dev/null 2>&1
done
END=$(date +%s%N)

TOTAL_MS=$(( (END - START) / 1000000 ))
AVG_MS=$(echo "scale=3; $TOTAL_MS / 100" | bc)
echo "Kessel (100 runs): avg=${AVG_MS}ms per parse"

# Larger file
echo ""
cat > small.js << 'EOF'
const utils = { add: (a, b) => a + b, mul: (a, b) => a * b };
class Calculator { constructor() { this.history = []; } calc(op, a, b) { return utils[op](a, b); } }
const arr = [1, 2, 3, 4, 5].map(x => x * 2).filter(n => n > 4);
export { utils, Calculator };
EOF

echo "Test: small.js ($(wc -c < small.js) bytes)"
echo ""

echo "OXC (100 runs averaged):"
node test_oxc.js small.js

echo ""
echo "Kessel (100 runs averaged):"
./kessel parse small.js > /dev/null 2>&1  # Warmup

START=$(date +%s%N)
for i in {1..100}; do
    ./kessel parse small.js > /dev/null 2>&1
done
END=$(date +%s%N)

TOTAL_MS=$(( (END - START) / 1000000 ))
AVG_MS=$(echo "scale=3; $TOTAL_MS / 100" | bc)
echo "Kessel (100 runs): avg=${AVG_MS}ms per parse"

rm -f tiny.js small.js test_oxc.js

echo ""
echo "Note: OXC times include minimal Node.js call overhead"
echo "Kessel times are pure native binary execution"

