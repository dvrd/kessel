# Handoff — Kessel Parser Optimization

## Estado actual (commit 4877fac)

### Benchmarks vs OXC
| Fixture | Ratio | bench_large |
|---------|-------|-------------|
| expr-heavy | **1.46x** | **3.66ms** |
| object-heavy | **1.55x** | |
| class-heavy | **1.68x** | |
| member-chain | **1.71x** | |
| string-heavy | **1.89x** | |
| destructuring-heavy | **3.26x** ← outlier | |

Empezamos en ~4x promedio. Ahora estamos en ~1.6x promedio (excepto destructuring).

### Arquitectura actual
- **Lexer** (`kessel/src/lexer/lexer_optimized.odin`): produce tokens via `lex_next_compact()` que escribe a SoA (`TokenSlot` de 12 bytes) Y también genera `FastToken` (16B by-value) que el parser lee directamente.
- **Parser** (`kessel/src/parser/parser.odin`): `advance_token()` lee `fast_cur/fast_nxt` del Lexer2 directamente. No usa ring buffer ni SoA reads. Convierte FastToken → campos de `p.cur_tok` (legacy Token).
- **AST** (`kessel/src/ast/ast.odin`): Loc usa u32 (16B). Expression/Statement son pointer unions (16B).
- **Allocator**: Custom `BumpPool` para nodos AST. `new_expr`/`new_stmt` combinan nodo+wrapper en un solo bump.

### El problema de destructuring-heavy (3.26x)
88K tokens ultra-cortos (1-3 chars). Per-token cost = 39.7ns (vs OXC 12.2ns). La brecha de 27.5ns/token viene de:

1. **`lex_next_compact` todavía escribe a SoA** (TokenSlot write + literal arrays). OXC no tiene SoA — solo devuelve Token by-value. Cada `add_token` hace un store de 12B a la SoA array que NADIE lee en el fast path. Es trabajo desperdiciado.

2. **`lex_fast_token` es un wrapper sobre `lex_next_compact`** — primero escribe SoA, luego LEE BACK del SoA al FastToken. Double work. Debería producir FastToken directamente sin tocar SoA.

3. **Los sub-lexers** (`lex_identifier_optimized`, `lex_string_optimized`, etc.) todos retornan `CompactToken` y escriben a SoA. Para eliminar SoA del hot path, necesitan retornar `FastToken` directamente.

4. **Whitespace loop** todavía tiene branch por newline tracking. OXC hace branchless space skip (`pos.add(is_space as usize)`).

### Qué implementar para llegar a paridad

#### A. Eliminar SoA del hot path (MAYOR IMPACTO — ~15-20ns/token)
Reescribir los sub-lexers para retornar `(TokenType, u32_end)` en vez de `CompactToken`. Luego `lex_fast_token` construye el `FastToken` directamente sin tocar SoA:

```odin
lex_fast_token :: proc(l: ^Lexer2) -> FastToken {
    // skip whitespace...
    start := u32(l.offset)
    kind := lex_dispatch(l)  // returns just TokenType, advances l.offset
    end := u32(l.offset)
    return FastToken{start=start, end=end, kind=kind, flags=...}
}
```

Los sub-lexers que necesitan guardar literals usan `store_literal(&l.literals, start, ...)` directamente.

#### B. Per-letter keyword dispatch (MEDIUM — ~3-5ns/identifier)
Eliminar el FNV hash. En vez de `lookup_keyword_ultra`, hacer dispatch por primer carácter:
- `a` → check "async", "await", "abstract", "as"
- `b` → check "break"
- `c` → check "class", "const", "case", "catch", "continue", "constructor"
- etc.
Esto es lo que OXC hace con `L_A`, `L_B`, etc.

#### C. Branchless space skip (LOW — ~1-2ns/token)
```odin
// Before dispatching, consume one space branchlessly:
is_space := u32(l.source_bytes[l.offset] == ' ')
l.offset += int(is_space)
// Then read byte at new position for dispatch
```

#### D. Raw pointer cursor (MEDIUM-HIGH — ~2-3ns everywhere)
Reemplazar `l.offset` (int index) + `l.source_bytes[l.offset]` (bounds check) con un raw pointer:
```odin
ptr: [^]u8  // current position
end: [^]u8  // end of source
// advance: ptr = ptr[1:]  or  ptr = rawptr(uintptr(ptr) + 1)
// read: ptr[0]  (no bounds check)
```

### Archivos clave
- `kessel/src/lexer/lexer_optimized.odin` — lexer core, `lex_next_compact`, `lex_fast_token`, sub-lexers
- `kessel/src/lexer/token_compact.odin` — FastToken, TokenSlot, LiteralStore, SoA (legacy)
- `kessel/src/parser/parser.odin` — `advance_token`, `prime_token_cache`, `is_next_token`, BumpPool, `new_expr`/`new_stmt`
- `kessel/src/lexer/keyword_hash.odin` — keyword lookup (to be replaced by per-letter dispatch)
- `kessel/src/lexer/lexer.odin` — CHAR_CLASS_TABLE, is_id_start_fast, is_id_cont_fast

### Cómo correr benchmarks
```bash
# Build
odin build kessel/src -out:kessel_bin -o:speed

# Quick test
./kessel_bin parse kessel/bench_large.js --compact > /dev/null

# All fixtures
for f in kessel/tests/fixtures/basic/*.js kessel/tests/smoke/*.js; do
  ./kessel_bin parse "$f" --compact > /dev/null 2>&1 || echo "FAIL: $f"
done

# Structural benchmarks vs OXC
ITERS=80 bash kessel/bench_structural.sh

# Min-based (more stable)
for fixture in bench/generated/structural/*.js; do
  name=$(basename "$fixture")
  k_min=$(./kessel_bin microbench "$fixture" --iterations 80 2>&1 | awk '/Min:/ {print $2}')
  o_min=$(./bench/oxc_compare/target/release/oxc_microbench "$fixture" 80 2>&1 | awk '/Min:/ {print $2}')
  ratio=$(python3 -c "print(f'{float(\"$k_min\")/float(\"$o_min\"):.2f}x')")
  printf '%-26s kessel=%-12s oxc=%-12s ratio=%s\n' "$name" "${k_min}us" "${o_min}us" "$ratio"
done

# Profile
./kessel_bin profile-parser kessel/bench_large.js --iterations 20
```

### Referencia: cómo OXC lo hace
El source de OXC está en `/Users/kakurega/dev/projects/oxc/crates/oxc_parser/src/lexer/`:
- `mod.rs` — main lexer, `read_next_token()` with branchless space skip
- `byte_handlers.rs` — 256-entry dispatch table `[ByteHandler; 256]`
- `token.rs` — Token is `u128` bitpacked (16 bytes by-value)
- `source.rs` — raw pointer cursor (`*const u8`)
- `identifier.rs` / `string.rs` / `number.rs` — sub-lexers
- `whitespace.rs` — SIMD-accelerated whitespace via `memchr`-like search

Key OXC design choices:
1. Token = u128 by-value, NO storage arrays
2. Raw pointer cursor, NO offset integers
3. 256-entry function pointer table for byte dispatch
4. Per-letter keyword handlers (L_A, L_B, ...) — no hash table
5. No line/column tracking during lexing
6. Branchless single-space consumption before each token
