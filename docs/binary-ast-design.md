# Binary AST Transfer Format — Design Document

## Problem

Kessel's raw parser is 8-19% faster than OXC, but the npm package (`kessel-parser`) is **3-5× slower** because `JSON.parse` accounts for 91% of the total time at the Node.js boundary:

| File | kessel parse | JSON.parse | Total | OXC (NAPI) |
|---|---|---|---|---|
| lodash.js (531KB) | 1.0ms | 10.1ms | 11.1ms | 3.3ms |
| typescript.js (8.8MB) | 31.8ms | 319ms | 351ms | 86ms |

## Solution

Replace JSON serialization with a compact binary format. A JS reader decodes the binary buffer into ESTree objects using `DataView` — measured at **32× faster than JSON.parse** in a realistic simulation.

**Projected performance (lodash.js):**
- kessel parse: 1.0ms
- Binary decode: ~0.4ms
- **Total: ~1.4ms** (vs OXC NAPI 3.3ms = **2.4× faster**)

## Binary Format

### Overview

```
[Header 16B] [Node Stream ...] [String Table ...] [Source Ref]
```

The format is a depth-first pre-order traversal of the AST. Each node is self-contained — the reader creates objects in DFS order and links parent→child via a stack.

### Header (16 bytes)

```
magic:              u32  0x4B455354 ("KEST")
version:            u32  1
node_count:         u32  total nodes in the stream
string_table_off:   u32  byte offset to string table start
```

### Node Stream

Each node is a variable-length record:

```
type_id:     u8      index into the type name table (0-255)
start:       u32     source byte offset
end:         u32     source byte offset
child_count: u16     number of child fields that follow
fields:      [...]   inline field data (see below)
```

### Field Encoding

Each field is:

```
field_id:    u8      index into per-type field name table
value_type:  u8      type tag (see below)
value:       [...]   inline value data
```

Value types:

| Tag | Type | Encoding |
|---|---|---|
| 0 | null | (no data) |
| 1 | bool | u8 (0/1) |
| 2 | u32 | u32 LE |
| 3 | f64 | f64 LE |
| 4 | string_ref | u32 (index into string table) |
| 5 | node_ref | (next node in stream is the child) |
| 6 | node_array | u16 count, followed by count nodes in stream |
| 7 | string_literal | u32 (string table index for value) + u32 (index for raw) |
| 8 | enum_val | u8 (e.g. "var"=0, "let"=1, "const"=2) |

### String Table

Sorted by first occurrence. Each entry:

```
offset:   u32   byte offset in source text (or STRING_ARENA_FLAG | arena_offset for cooked)
length:   u32   byte length
```

The reader slices source text directly for source-range strings. Cooked strings (escape-decoded) are appended after the string table as raw bytes.

### Type Name Table

Static — baked into both the Odin emitter and the JS reader:

```js
const TYPE_NAMES = [
  'Program',              // 0
  'Identifier',           // 1
  'PrivateIdentifier',    // 2
  'NumericLiteral',       // 3
  'StringLiteral',        // 4
  'BooleanLiteral',       // 5
  'NullLiteral',          // 6
  'BigIntLiteral',        // 7
  'RegExpLiteral',        // 8
  'TemplateLiteral',      // 9
  'TemplateElement',      // 10
  // ... ~80 node types
];
```

### Field Name Table

Per type — also static, baked into both sides:

```js
const IDENTIFIER_FIELDS = ['name'];  // field_id 0
const BINARY_EXPR_FIELDS = ['operator', 'left', 'right'];
// etc.
```

## Implementation Plan

### Phase 1: Odin Binary Emitter (~800 LoC)

New file `src/binary_emitter.odin`:
- Walk the AST in DFS pre-order (same traversal as `emitter.odin`)
- Write each node into a growable byte buffer
- Build string table with deduplication (hashmap: string → index)
- Write header at the end (back-patch node_count and string_table_off)

### Phase 2: JS Binary Reader (~500 LoC)

New file `npm/kessel-parser/binary-reader.js`:
- Read header, validate magic/version
- Pre-allocate nodes array (node_count)
- Walk the node stream, creating plain JS objects
- Resolve string references from the string table
- Link children via DFS stack

### Phase 3: Wire Into npm Package

Update `npm/kessel-parser/index.js`:
- Add `--binary` flag to kessel CLI
- `parseSync` calls kessel with `--binary`, gets a Buffer back
- Decode with binary reader instead of JSON.parse
- Same ESTree output shape

### Phase 4: NAPI Binding (future)

Once the binary format is proven, build a native Node.js addon:
- Odin compiles to `.dylib`/`.so` exporting `kessel_parse(source, len) → buffer`
- C shim wraps the Odin function for N-API
- Node addon loads the shared library, calls parse, decodes buffer
- Eliminates child process spawn entirely

## Alternatives Considered

1. **MessagePack/CBOR** — Still requires serialization on the Odin side and a decoder on the JS side. Custom binary is simpler and can be purpose-built for ESTree's shape.

2. **Raw arena dump** (`raw_transfer.odin`) — 36× source size (vs 5× for JSON). Contains alignment padding and unused arena capacity. Also has segfaults on large files.

3. **JSON streaming** — V8's `JSON.parse` is already heavily optimized; streaming doesn't help because it can't avoid creating all the objects.

4. **SharedArrayBuffer + lazy proxy** — Would avoid object creation entirely, but ESTree consumers expect real JS objects, not proxies. API compatibility would break.
