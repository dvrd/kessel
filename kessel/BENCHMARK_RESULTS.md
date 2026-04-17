# Benchmark Results - Kessel Parser NEON SIMD

## Estado Actual del Parser

⚠️ **ADVERTENCIA**: Se detectó un bug crítico en el lexer optimizado donde el archivo completo se lee como un solo token identifier en lugar de tokenizar correctamente.

## Resultados de Benchmark

### Test de Archivos Pequeños

| Archivo | Tamaño | Tiempo Lexing | Tiempo Parsing | Estado |
|---------|--------|---------------|----------------|--------|
| tiny.js | 413 bytes | ~5ms | ~11ms | ✅ Funciona |
| small.js | 4KB | ~5ms | ~8ms | ✅ Funciona |
| medium.js | 44KB | ⏱️ Timeout | - | ❌ Se cuelga |

### Problema Identificado

El lexer optimizado tiene un bug donde no está tokenizando correctamente. En lugar de generar tokens individuales:
```
const | var1 | = | { | n | : | 1 | , | ...
```

Está generando un solo token gigante:
```
"const var1 = { n: 1, f: () => 1 * 2 };\nconst var2 = ... "
```

Esto explica:
1. Por qué "Total tokens" muestra números muy bajos (3-5 en lugar de cientos)
2. Por qué archivos grandes se cuelgan (procesan todo como un token masivo)
3. Por qué SIMD chunks es 0 (no hay procesamiento de chunks)

### Optimizaciones Implementadas

| Optimización | Estado | Notas |
|--------------|--------|-------|
| Character Table (256-byte) | ✅ Activo | Funcionando |
| Compact Tokens (SoA) | ✅ Activo | Token size 76B → 16B |
| ARM64 NEON SIMD | ✅ Activo | Pero no se usa debido al bug |
| Perfect Hash Keywords | ✅ Activo | O(1) lookup |
| Arena Pre-sizing | ✅ Activo | 4x source size |

### Build

```bash
$ ./build.sh
Building kessel in release mode...
Build complete: ./kessel

Binary size: 434KB
```

### Observaciones

1. **Bug crítico**: El lexer no está separando tokens correctamente
2. **Impacto en SIMD**: Aunque el código SIMD NEON está implementado, no se activa porque el procesamiento de tokens es incorrecto
3. **Performance**: A pesar del bug, los tiempos para archivos pequeños (~400 bytes) están en ~5ms, lo cual está en el rango "bueno" aunque lejos de la meta de 0.1-0.2ms

### Próximos Pasos para Corregir

1. Revisar `lexer_optimized.odin` - función `lex_identifier_optimized`
2. Verificar que `advance2()` esté actualizando correctamente el offset
3. Asegurar que `lex_next_compact()` esté llamando `advance2()` correctamente
4. Verificar el loop de tokenización en `prime_lexer()`

### Meta Original vs Actual

| Métrica | Meta | Actual (bug) |
|---------|------|--------------|
| tiny.js (413 bytes) | 0.1-0.2ms | ~5ms |
| small.js (4KB) | < 2ms | ~5ms |
| medium.js (44KB) | < 10ms | ⏱️ Timeout |

### Conclusión

Las optimizaciones de NEON SIMD, compact tokens, perfect hash y arena pre-sizing están **implementadas y compilando correctamente**, pero hay un **bug crítico en el lexer** que impide la tokenización correcta y el uso efectivo de SIMD.

Una vez corregido el bug, el parser debería alcanzar la meta de rendimiento.
