#!/bin/bash

# Benchmark de Rendimiento con NEON SIMD
# Compara tiempos de parsing en diferentes tamaños de archivos

set -e

echo "=========================================="
echo "Kessel Parser Benchmark - NEON SIMD"
echo "=========================================="
echo ""

# Colores para output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Función para benchmark con múltiples runs
benchmark_file() {
    local file=$1
    local name=$2
    local runs=10
    
    if [ ! -f "$file" ]; then
        echo -e "${YELLOW}⚠ Archivo no encontrado: $file${NC}"
        return
    fi
    
    local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    local lines=$(wc -l < "$file" | tr -d ' ')
    
    echo -e "${GREEN}Testing $name ($((size/1024))KB, $lines lines)${NC}"
    
    # Calcular tiempo promedio
    local total_time=0
    local valid_runs=0
    local simd_chunks_total=0
    local tokens_total=0
    
    for i in $(seq 1 $runs); do
        # Medir tiempo
        start_time=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000')
        
        result=$(./kessel parse "$file" 2>&1) || true
        
        end_time=$(perl -MTime::HiRes=time -e 'printf "%.0f\n", time*1000')
        elapsed=$((end_time - start_time))
        
        if [ $elapsed -gt 0 ] && [ $elapsed -lt 10000 ]; then
            total_time=$((total_time + elapsed))
            valid_runs=$((valid_runs + 1))
        fi
        
        # Extraer stats de SIMD (solo del primer run para no duplicar output)
        if [ $i -eq 1 ]; then
            simd_chunks=$(echo "$result" | grep "SIMD chunks" | grep -o '[0-9]*' || echo "0")
            tokens=$(echo "$result" | grep "tokens_created" | grep -o '[0-9]*' || echo "0")
            simd_chunks_total=$simd_chunks
            tokens_total=$tokens
        fi
    done
    
    if [ $valid_runs -gt 0 ]; then
        local avg_time=$((total_time / valid_runs))
        local throughput=0
        if [ $avg_time -gt 0 ]; then
            throughput=$((size / avg_time))
        fi
        
        echo "  Avg time: ${avg_time}ms (${valid_runs}/${runs} valid runs)"
        echo "  Throughput: ${throughput}KB/s"
        echo "  SIMD chunks: $simd_chunks_total"
        echo "  Tokens: $tokens_total"
        
        # Comparar con meta
        if [ $avg_time -lt 5 ]; then
            echo -e "  ${GREEN}✓ Excelente (< 5ms)${NC}"
        elif [ $avg_time -lt 10 ]; then
            echo -e "  ${YELLOW}○ Bueno (< 10ms)${NC}"
        else
            echo -e "  ${RED}✗ Lento (> 10ms)${NC}"
        fi
    else
        echo -e "  ${RED}✗ Timeout o error${NC}"
    fi
    echo ""
}

echo "=== Archivos de Test ==="
echo ""

# Tiny file (meta: 0.1-0.2ms)
benchmark_file "bench_tiny.js" "tiny.js (413 bytes)"

# Small file
benchmark_file "bench_small.js" "small.js (5KB)"

# Medium file
benchmark_file "bench_medium.js" "medium.js (44KB)"

# Large file
benchmark_file "bench_large.js" "large.js (570KB)"

# Realistic file
benchmark_file "bench_realistic.js" "realistic.js (246KB)"

echo "=========================================="
echo "Benchmark de Librerías Reales (muestra)"
echo "=========================================="
echo ""

# Solo probar 1-2 archivos reales para no tardar mucho
if [ -f "real_js/dayjs.min.js" ]; then
    benchmark_file "real_js/dayjs.min.js" "Day.js (7KB)"
fi

if [ -f "real_js/axios.min.js" ]; then
    benchmark_file "real_js/axios.min.js" "Axios (95KB)"
fi

echo "=========================================="
echo "Comparación de Modos SIMD vs Scalar"
echo "=========================================="
echo ""

# Test específico para ver uso de SIMD
echo "Análisis de uso de SIMD por tamaño de archivo:"
echo ""

for file in bench_tiny.js bench_small.js; do
    if [ -f "$file" ]; then
        size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
        echo "Archivo: $file ($size bytes)"
        
        # Extraer stats
        result=$(./kessel lex "$file" 2>&1 | grep -E "SIMD chunks|Scalar fallbacks|tokens_created" || true)
        echo "$result"
        echo ""
    fi
done

echo "=========================================="
echo "Resumen"
echo "=========================================="
echo ""
echo "Meta para tiny.js: 0.1-0.2ms"
echo "Meta para small.js: < 5ms"
echo "Meta para medium.js: < 20ms"
echo ""
echo "Nota: SIMD se activa automáticamente en chunks >= 16 bytes"
echo "      En ARM64 (Apple Silicon) se usa NEON intrinsics"
echo ""
