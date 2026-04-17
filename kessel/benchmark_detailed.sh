#!/bin/bash

# Benchmark Detallado con Estadísticas
# Mide tiempo de parsing, tokens/segundo, uso de memoria

set -e

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       KESSEL PARSER - BENCHMARK DETALLADO NEON SIMD          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

KESSEL="./kessel"
RUNS=5

# Verificar que kessel existe
if [ ! -f "$KESSEL" ]; then
    echo "Error: $KESSEL no encontrado"
    exit 1
fi

# Función para medir con precisión
measure() {
    local file=$1
    local mode=$2  # 'lex' o 'parse'
    
    local times=()
    local tokens=0
    local simd_chunks=0
    local scalar_fb=0
    local arena_used=0
    
    for i in $(seq 1 $RUNS); do
        local start=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
        
        if [ "$mode" = "lex" ]; then
            output=$($KESSEL lex "$file" 2>&1) || true
            # Extraer stats
            tokens=$(echo "$output" | grep "tokens_created:" | grep -o '[0-9]*' || echo "0")
            simd_chunks=$(echo "$output" | grep "SIMD chunks:" | grep -o '[0-9]*' || echo "0")
            scalar_fb=$(echo "$output" | grep "Scalar fallbacks:" | grep -o '[0-9]*' || echo "0")
        else
            output=$($KESSEL parse "$file" 2>&1) || true
            arena_used=$(echo "$output" | grep "Arena used:" | grep -o '[0-9]*' || echo "0")
        fi
        
        local end=$(perl -MTime::HiRes=time -e 'printf "%.3f", time')
        local elapsed=$(echo "$end - $start" | bc)
        
        # Solo guardar tiempos válidos (> 0 y < 5s)
        if (( $(echo "$elapsed > 0" | bc -l) )) && (( $(echo "$elapsed < 5" | bc -l) )); then
            times+=("$elapsed")
        fi
    done
    
    # Calcular promedio y mínimo
    if [ ${#times[@]} -gt 0 ]; then
        local sum=0
        local min=${times[0]}
        for t in "${times[@]}"; do
            sum=$(echo "$sum + $t" | bc)
            if (( $(echo "$t < $min" | bc -l) )); then
                min=$t
            fi
        done
        local avg=$(echo "scale=3; $sum / ${#times[@]}" | bc)
        
        echo "$avg $min $tokens $simd_chunks $scalar_fb $arena_used"
    else
        echo "0 0 0 0 0 0"
    fi
}

# Formato de salida
printf "%-20s %10s %10s %10s %10s %10s %10s\n" "Archivo" "Tiempo" "T/s" "Tok/ms" "SIMD" "Scalar" "KB/s"
printf "%-20s %10s %10s %10s %10s %10s %10s\n" "═══════" "══════" "═══" "══════" "════" "══════" "════"

for file in bench_tiny.js bench_small.js bench_medium.js; do
    if [ ! -f "$file" ]; then
        continue
    fi
    
    size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null)
    size_kb=$((size / 1024))
    
    # Medir lexing
    result=$(measure "$file" "lex")
    read avg min tokens simd scalar arena <<< "$result"
    
    if (( $(echo "$avg > 0" | bc -l) )); then
        # Calcular métricas
        tps=$(echo "scale=0; $tokens / $avg" | bc 2>/dev/null || echo "0")
        tpms=$(echo "scale=0; $tokens / ($avg * 1000)" | bc 2>/dev/null || echo "0")
        kbs=$(echo "scale=0; $size_kb / $avg" | bc 2>/dev/null || echo "0")
        
        name=$(basename "$file" .js)
        printf "%-20s %9.3fs %9d %9d %9s %9s %9d\n" \
            "$name" "$avg" "$tps" "$tpms" "$simd" "$scalar" "$kbs"
    fi
done

echo ""
echo "=== Detalle por Fase ==="
echo ""

for file in bench_tiny.js bench_small.js; do
    if [ ! -f "$file" ]; then
        continue
    fi
    
    echo "Archivo: $file"
    echo "─────────────────────────────────────────"
    
    # Lex only
    echo -n "  Lexing:  "
    result=$(measure "$file" "lex")
    read avg min tokens simd scalar arena <<< "$result"
    if (( $(echo "$avg > 0" | bc -l) )); then
        printf "%8.3f ms (%d tokens, %d SIMD chunks)\n" "$avg" "$tokens" "$simd"
    else
        echo "timeout/error"
    fi
    
    # Parse
    echo -n "  Parsing: "
    result=$(measure "$file" "parse")
    read avg min tokens simd scalar arena <<< "$result"
    if (( $(echo "$avg > 0" | bc -l) )); then
        printf "%8.3f ms (arena: %d KB)\n" "$avg" "$((arena/1024))"
    else
        echo "timeout/error"
    fi
    
    echo ""
done

echo ""
echo "=== Uso de SIMD por Tamaño ==="
echo ""

# Crear archivos de diferentes tamaños para probar SIMD
for size in 10 50 100 500 1000 5000; do
    # Generar archivo con N declaraciones
    tmpfile=$(mktemp)
    for i in $(seq 1 $size); do
        echo "const var$i = { n: $i, f: () => $i * 2 };" >> "$tmpfile"
    done
    
    bytes=$(stat -f%z "$tmpfile" 2>/dev/null || stat -c%s "$tmpfile" 2>/dev/null)
    
    # Medir
    result=$(measure "$tmpfile" "lex")
    read avg min tokens simd scalar arena <<< "$result"
    
    printf "%6d bytes: %6.3f ms | SIMD: %3d | Scalar: %2d\n" "$bytes" "$avg" "$simd" "$scalar"
    
    rm "$tmpfile"
done

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "Nota: SIMD chunks indican cuántos bloques de 16 bytes se"
echo "      procesaron con NEON intrinsics (ARM64)"
echo "═══════════════════════════════════════════════════════════════"
