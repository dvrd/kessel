#!/bin/bash

echo "=== Kessel Parser Benchmark - Realistic Test ==="
echo ""

# Create a moderately sized realistic file
cat > test_realistic.js << 'EOF'
// Simulating a real-world module
import { utils } from './utils';

export class DataProcessor {
  constructor(config) {
    this.config = config;
    this.cache = new Map();
  }
  
  async process(items) {
    const results = [];
    for (const item of items) {
      if (item.active) {
        const processed = await this.transform(item);
        results.push(processed);
      }
    }
    return results;
  }
  
  async transform(item) {
    const { id, data } = item;
    const cached = this.cache.get(id);
    if (cached) return cached;
    
    const result = {
      ...data,
      processed: true,
      timestamp: Date.now()
    };
    
    this.cache.set(id, result);
    return result;
  }
  
  static create(config) {
    return new DataProcessor(config);
  }
}

export const utils = {
  format: (date) => date.toISOString(),
  parse: (str) => new Date(str),
  clamp: (val, min, max) => Math.min(Math.max(val, min), max),
};

export const helpers = {
  async fetchData(url) {
    try {
      const res = await fetch(url);
      return await res.json();
    } catch (e) {
      console.error(e);
      return null;
    }
  },
  
  debounce(fn, delay) {
    let timeout;
    return (...args) => {
      clearTimeout(timeout);
      timeout = setTimeout(() => fn(...args), delay);
    };
  },
  
  throttle(fn, limit) {
    let inThrottle;
    return (...args) => {
      if (!inThrottle) {
        fn(...args);
        inThrottle = true;
        setTimeout(() => inThrottle = false, limit);
      }
    };
  }
};
EOF

# Copy it multiple times to increase size
for i in {1..10}; do
    cat test_realistic.js >> test_large.js
done

echo "Test files created:"
ls -lh test_*.js | awk '{print $9, $5}'
echo ""

echo "=== Benchmark Results ==="
printf "%-20s %8s %8s %12s %12s\n" "File" "Size" "Time" "Throughput" "Arena"
echo "----------------------------------------------------------"

for file in test_realistic.js test_large.js example.js; do
    if [ -f "$file" ]; then
        size=$(wc -c < "$file")
        lines=$(wc -l < "$file")
        
        # Time kessel
        start=$(date +%s%N)
        ./kessel parse "$file" > /tmp/out.json 2>/tmp/stats.txt
        end=$(date +%s%N)
        
        time_ms=$(( (end - start) / 1000000 ))
        arena=$(grep "Arena used:" /tmp/stats.txt | awk '{print $3}')
        errors=$(grep "Parse errors:" /tmp/stats.txt | awk '{print $3}')
        
        if [ $time_ms -gt 0 ]; then
            throughput=$((size * 1000 / time_ms / 1024))  # KB/s
        else
            throughput=0
        fi
        
        printf "%-20s %8s %8s %10sKB/s %10sB\n" \
            "$file" "${size}B" "${time_ms}ms" "$throughput" "$arena"
        
        echo "  Lines: $lines, Errors: $errors"
    fi
done

echo ""
echo "=== Acorn (Node.js) Reference ==="
printf "%-20s %8s %8s %12s\n" "File" "Size" "Time" "Throughput"
echo "----------------------------------------------"

for file in test_realistic.js test_large.js example.js; do
    if [ -f "$file" ]; then
        size=$(wc -c < "$file")
        
        start=$(date +%s%N)
        acorn "$file" > /dev/null 2>&1
        end=$(date +%s%N)
        
        time_ms=$(( (end - start) / 1000000 ))
        if [ $time_ms -gt 0 ]; then
            throughput=$((size * 1000 / time_ms / 1024))
        else
            throughput=0
        fi
        
        printf "%-20s %8s %8s %10sKB/s\n" \
            "$file" "${size}B" "${time_ms}ms" "$throughput"
    fi
done

# Cleanup
rm -f test_realistic.js test_large.js

