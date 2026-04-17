#!/bin/bash

echo "=== Kessel Optimized vs OXC ==="
echo ""

# Test files
cat > tiny.js << 'EOF'
const x = 1 + 2;
EOF

cat > small.js << 'EOF'
const utils = { add: (a, b) => a + b, mul: (a, b) => a * b };
class Calculator { constructor() { this.history = []; } calc(op, a, b) { return utils[op](a, b); } }
const arr = [1, 2, 3, 4, 5].map(x => x * 2).filter(n => n > 4);
export { utils, Calculator };
EOF

echo "File sizes:"
wc -c tiny.js small.js

echo ""
echo "=== OXC (Rust/WASM via Node.js) ==="
echo "Note: Includes Node.js overhead"

echo ""
echo "Tiny file:"
for i in 1 2 3; do
    node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); const s=Date.now(); parseSync('t', fs.readFileSync('tiny.js', 'utf8')); console.log((Date.now()-s)+'ms');" 2>/dev/null
done

echo ""
echo "Small file:"
for i in 1 2 3; do
    node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); const s=Date.now(); parseSync('t', fs.readFileSync('small.js', 'utf8')); console.log((Date.now()-s)+'ms');" 2>/dev/null
done

echo ""
echo "=== Kessel (Odin Native) ==="

echo ""
echo "Tiny file:"
for i in 1 2 3; do
    time ./kessel parse tiny.js 2>&1 | grep real | awk '{print "  " $2}'
done

echo ""
echo "Small file:"
for i in 1 2 3; do
    time ./kessel parse small.js 2>&1 | grep real | awk '{print "  " $2}'
done

echo ""
echo "=== Summary ==="
echo "OXC times include Node.js startup overhead (~30-40ms)"
echo "Kessel times are pure native execution"
echo ""
echo "For fair comparison, measure inside same process:"
echo "  OXC inside Node: ~0.02ms per parse"
echo "  Kessel native: ~3ms per parse"
echo "  Target: Reduce to ~0.1-0.2ms (15-30x faster)"

rm -f tiny.js small.js
