#!/bin/bash

echo "=== Kessel vs OXC Parser Benchmark ==="
echo ""
echo "WARNING: OXC runs through Node.js (has overhead)"
echo "Kessel runs native (no overhead)"
echo ""

# Test file
cat > bench.js << 'EOF'
const utils = { add: (a, b) => a + b };
class Calc { constructor() { this.x = 0; } }
const arr = [1, 2, 3].map(x => x * 2);
EOF

size=$(wc -c < bench.js)
echo "Test file: ${size} bytes"
echo ""

echo "OXC (Rust + Node.js overhead):"
for i in 1 2 3; do
    node -e "const { parseSync } = require('oxc-parser'); const fs = require('fs'); const start = Date.now(); parseSync('bench.js', fs.readFileSync('bench.js', 'utf8')); console.log('Run', $i, ':', Date.now() - start, 'ms');"
done

echo ""
echo "Kessel (Odin native):"
for i in 1 2 3; do
    start=$(date +%s%N)
    ./kessel parse bench.js > /dev/null 2>&1
    end=$(date +%s%N)
    ms=$(( (end - start) / 1000000 ))
    echo "Run $i: ${ms}ms"
done

rm -f bench.js

echo ""
echo "Note: For fair comparison, OXC should be measured with its native CLI"
echo "Current OXC measurement includes Node.js startup overhead"

