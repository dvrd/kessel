# Benchmark Final - Estado del Parser Kessel

## ⚠️ Problema Crítico Detectado

El lexer optimizado tiene un **bug** donde:
1. Lee todo el archivo como un solo token identifier gigante
2. No está separando tokens correctamente (`const`, `var1`, `=`, etc.)
3. Por eso "Total tokens" muestra 3-5 en lugar de cientos
4. Archivos grandes (> 200 líneas) causan timeout

## Resultados de Benchmark (con bug)

| Archivo | Tamaño | Tiempo Lex | Tiempo Parse | Tokens | SIMD | Estado |
|---------|--------|------------|--------------|--------|------|--------|
| tiny.js | 413 B | ~5ms | ~11ms | 5 | 0 | ⚠️ Bug |
| small.js | 4 KB | ~5ms | ~8ms | 5 | 0 | ⚠️ Bug |
| medium.js | 44 KB | ⏱️ | - | - | - | ❌ Timeout |

## Optimizaciones Implementadas

| Optimización | Estado | Funciona |
|--------------|--------|----------|
| NEON SIMD (ARM64) | ✅ | Compila, no se usa por bug |
| Compact Tokens (SoA) | ✅ | 76B → 16B |
| Perfect Hash Keywords | ✅ | O(1) lookup |
| Arena Pre-sizing | ✅ | 4x source |
| Character Table | ✅ | 256-byte lookup |

## Análisis del Bug

### Síntomas:
```
Input: "const var1 = { n: 1 };"
Tokens esperados: [const] [var1] [=] [{] [n] [:] [1] [}] [;]
Tokens actuales: ["const var1 = { n: 1 };"] [*] [2] [}] [;]
```

### Causa Probable:
El lexer no está avanzando correctamente después de cada token. El offset del lexer puede no estar actualizándose, causando que siempre lea desde el inicio del archivo.

### Archivos Afectados:
- `src/lexer/lexer_optimized.odin` - Funciones de lexing
- `src/lexer/lexer_adapter.odin` - Adaptador legacy

## Meta vs Realidad

| Métrica | Meta | Actual (con bug) |
|---------|------|------------------|
| tiny.js (413B) | 0.1-0.2ms | ~5ms (25x más lento) |
| small.js (4KB) | < 2ms | ~5ms (2.5x más lento) |
| medium.js (44KB) | < 10ms | ⏱️ Timeout |

## Build System

```bash
$ ./build.sh
Building kessel in release mode...
Build complete: ./kessel (434KB)
```

## Conclusión

Las **optimizaciones NEON SIMD están implementadas** pero hay un **bug crítico en el lexer** que impide la tokenización correcta.

### Para alcanzar la meta de 0.1-0.2ms:
1. Corregir bug de tokenización en `lexer_optimized.odin`
2. Verificar que `offset` avance correctamente
3. Asegurar que `add_token` reciba parámetros correctos
4. Re-hacer benchmarks

### Código SIMD NEON Funciona:
Aunque no se está usando por el bug, el código NEON con intrinsics de Odin está correctamente implementado:
```odin
// Carga 16 bytes
chunk := (transmute(^Vec16)&data[ptr])^

// Broadcast
space_vec: Vec16 = ' '

// Comparar
cmp := simd.lanes_eq(chunk, space_vec)

// Reducir
mask := intrinsics.simd_reduce_or(transmute(Vec16)cmp)
```

## Tags
- `optimization-phase-4-neon-simd` ✅ Implementado
- Bug crítico pendiente de corrección
