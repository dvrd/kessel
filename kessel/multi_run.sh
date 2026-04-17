#!/bin/bash

cat > test.js << 'EOF'
const utils = { add: (a, b) => a + b, mul: (a, b) => a * b };
class Calculator { constructor() { this.history = []; } calc(op, a, b) { return utils[op](a, b); } }
const arr = [1, 2, 3, 4, 5].map(x => x * 2).filter(n => n > 4);
export { utils, Calculator };
EOF

echo "=== 5 Runs Each ==="
echo ""
echo "OXC (Node.js + WASM, cold start each time):"
for i in 1 2 3 4 5; do
    time node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); parseSync('t', fs.readFileSync('test.js', 'utf8'));" 2>&1 | grep real
done

echo ""
echo "Kessel (Odin native, cold start each time):"
for i in 1 2 3 4 5; do
    time ./kessel parse test.js > /dev/null 2>&1 | grep real
done

echo ""
echo "=== Warmed up (10 runs before measuring) ==="
echo ""

# Warmup
for i in {1..10}; do
    node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); parseSync('t', fs.readFileSync('test.js', 'utf8'));" 2>/dev/null
    ./kessel parse test.js > /dev/null 2>&1
done

echo "OXC (warmed):"
time node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); parseSync('t', fs.readFileSync('test.js', 'utf8'));" 2>&1 | grep real

echo ""
echo "Kessel (warmed):"
time ./kessel parse test.js > /dev/null 2>&1 | grep real

rm -f test.js

echo ""
echo "Conclusion: Node.js startup overhead dominates OXC times"
echo "For true comparison, need native OXC binary (not available via npm)"

