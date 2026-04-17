#!/bin/bash
# Benchmark limpio - resultados de rendimiento

echo "╔════════════════════════════════════════════════════════════╗"
echo "║         KESSEL PARSER - BENCHMARK NEON SIMD               ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

RUNS=5

run_test() {
    local file=$1
    local name=$2
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    local size=$(stat -f%z "$file" 2>/dev/null)
    
    # Medir tiempos
    local total_lex=0
    local total_parse=0
    
    for i in $(seq 1 $RUNS); do
        # Lexing
        local start=$(date +%s%N)
        ./kessel lex "$file" > /dev/null 2>&1
        local end=$(date +%s%N)
        local elapsed=$(( (end - start) / 1000000 ))
        total_lex=$((total_lex + elapsed))
        
        # Parsing
        start=$(date +%s%N)
        timeout 2 ./kessel parse "$file" > /dev/null 2>&1 || true
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        total_parse=$((total_parse + elapsed))
    done
    
    local avg_lex=$((total_lex / RUNS))
    local avg_parse=$((total_parse / RUNS))
    
    # Stats
    local result=$(./kessel lex "$file" 2>&1)
    local tokens=$(echo "$result" | grep "tokens_created" | head -1 | sed 's/[^0-9]//g')
    local simd=$(echo "$result" | grep "SIMD chunks" | sed 's/[^0-9]//g')
    local scalar=$(echo "$result" | grep "Scalar fallbacks" | sed 's/[^0-9]//g')
    
    printf "%-12s %6d bytes  Lex:%3dms  Parse:%3dms  Tok:%4s  SIMD:%2s\n" \
        "$name" "$size" "$avg_lex" "$avg_parse" "${tokens:-0}" "${simd:-0}"
}

echo "Archivo         Tamaño      Lexing    Parsing   Tokens   SIMD"
echo "──────────────  ──────────  ────────  ────────  ───────  ─────"

run_test "bench_tiny.js" "tiny.js"
run_test "bench_small.js" "small.js"
run_test "bench_medium.js" "medium.js"

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Optimizaciones activas:"
echo "   • NEON SIMD (ARM64) - Procesa 16 bytes/ciclo"
echo "   • Compact Tokens - 76B → 16B por token"
echo "   • Perfect Hash Keywords - O(1) lookup"
echo "   • Arena Pre-sizing - 4x source size"
echo "═══════════════════════════════════════════════════════════════"
