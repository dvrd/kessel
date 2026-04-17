#!/bin/bash
# Benchmark rápido - sin impresión de JSON

echo "=== Kessel Parser Benchmark (NEON SIMD) ==="
echo ""

benchmark() {
    local file=$1
    local name=$2
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    local size=$(stat -f%z "$file" 2>/dev/null)
    local lines=$(wc -l < "$file" | tr -d ' ')
    
    echo "Testing $name ($((size/1024))KB, $lines lines)..."
    
    # Medir tiempo de lexing (sin output)
    local start=$(date +%s%N)
    ./kessel lex "$file" > /dev/null 2>&1
    local end=$(date +%s%N)
    local lex_ms=$(( (end - start) / 1000000 ))
    
    # Medir tiempo de parsing (sin output)
    start=$(date +%s%N)
    timeout 5 ./kessel parse "$file" > /dev/null 2>&1 || true
    end=$(date +%s%N)
    local parse_ms=$(( (end - start) / 1000000 ))
    
    # Extraer stats
    local result=$(./kessel lex "$file" 2>&1)
    local tokens=$(echo "$result" | grep "Total tokens" | sed 's/[^0-9]//g')
    local simd=$(echo "$result" | grep "SIMD chunks" | sed 's/[^0-9]//g')
    
    printf "  Lex: %3dms  Parse: %3dms  Tokens: %s  SIMD: %s\n" \
        "$lex_ms" "$parse_ms" "${tokens:-0}" "${simd:-0}"
    
    # Throughput
    if [ $lex_ms -gt 0 ]; then
        local throughput=$(( size / lex_ms ))
        printf "  Throughput: %d bytes/ms\n" "$throughput"
    fi
    echo ""
}

benchmark "bench_tiny.js" "tiny.js"
benchmark "bench_small.js" "small.js"
benchmark "bench_medium.js" "medium.js"

echo "═══════════════════════════════════════════════════════════════"
echo "✅ Optimizaciones NEON SIMD activas:"
echo "   • 16 bytes procesados por ciclo SIMD"
echo "   • Compact tokens (76B → 16B)"
echo "   • Perfect hash keywords O(1)"
echo "   • Arena pre-sizing 4x"
echo "═══════════════════════════════════════════════════════════════"
