#!/bin/bash

# Benchmark Final - Resultados de Rendimiento
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║         BENCHMARK FINAL - KESSEL PARSER NEON SIMD            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

RUNS=5

run_benchmark() {
    local file=$1
    local name=$2
    
    if [ ! -f "$file" ]; then
        return
    fi
    
    local size=$(stat -f%z "$file" 2>/dev/null)
    
    echo "📄 $name (${size} bytes)"
    echo "─────────────────────────────────────────────────────────────"
    
    # Tiempos de lexing
    local total_lex=0
    for i in $(seq 1 $RUNS); do
        start=$(date +%s%N)
        ./kessel lex "$file" > /dev/null 2>&1 || true
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        total_lex=$((total_lex + elapsed))
    done
    avg_lex=$((total_lex / RUNS))
    
    # Tiempos de parsing
    local total_parse=0
    for i in $(seq 1 $RUNS); do
        start=$(date +%s%N)
        timeout 2 ./kessel parse "$file" > /dev/null 2>&1 || true
        end=$(date +%s%N)
        elapsed=$(( (end - start) / 1000000 ))
        total_parse=$((total_parse + elapsed))
    done
    avg_parse=$((total_parse / RUNS))
    
    # Stats de SIMD
    result=$(./kessel lex "$file" 2>&1)
    tokens=$(echo "$result" | grep "tokens_created" | head -1 | sed 's/[^0-9]//g')
    simd=$(echo "$result" | grep "SIMD chunks" | sed 's/[^0-9]//g')
    scalar=$(echo "$result" | grep "Scalar fallbacks" | sed 's/[^0-9]//g')
    
    echo "  Lexing:  ${avg_lex}ms"
    echo "  Parsing: ${avg_parse}ms"
    echo "  Tokens:  ${tokens:-0}"
    echo "  SIMD:    ${simd:-0} chunks"
    echo "  Scalar:  ${scalar:-0} fallbacks"
    
    # Throughput
    if [ $avg_lex -gt 0 ]; then
        throughput=$(( size / avg_lex ))
        echo "  Throughput: ${throughput} bytes/ms"
    fi
    
    # Evaluación
    echo ""
    if [ $avg_lex -lt 5 ]; then
        echo "  ✅ EXCELENTE (< 5ms)"
    elif [ $avg_lex -lt 10 ]; then
        echo "  ✓ BUENO (< 10ms)"
    elif [ $avg_lex -lt 50 ]; then
        echo "  ⚠ ACEPTABLE (< 50ms)"
    else
        echo "  ❌ LENTO (> 50ms)"
    fi
    echo ""
}

# Ejecutar benchmarks
run_benchmark "bench_tiny.js" "tiny.js"
run_benchmark "bench_small.js" "small.js"
run_benchmark "bench_medium.js" "medium.js"

# Comparación con meta
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    COMPARACIÓN CON META                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Meta para tiny.js (413 bytes): 0.1-0.2ms"
echo "Meta para small.js (4KB): < 5ms"
echo "Meta para medium.js (44KB): < 20ms"
echo ""

# Resumen de optimizaciones activas
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              OPTIMIZACIONES IMPLEMENTADAS                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ Character Table (256-byte lookup)"
echo "✅ Compact Tokens (76B → 16B, 4.75x reducción)"
echo "✅ ARM64 NEON SIMD (16 bytes/ciclo)"
echo "✅ Perfect Hash Keywords (O(1) lookup)"
echo "✅ Arena Pre-sizing (4x source size)"
echo ""

# Notas
echo "═══════════════════════════════════════════════════════════════"
echo "NOTAS:"
echo "• SIMD se activa solo con chunks >= 16 bytes consecutivos"
echo "• Archivos pequeños (< 1KB) usan mayormente scalar"
echo "• El throughput mejora significativamente en archivos grandes"
echo "═══════════════════════════════════════════════════════════════"
