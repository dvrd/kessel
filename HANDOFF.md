# Handoff — Kessel Binary AST Reader

## What is Kessel

JavaScript/TypeScript/JSX/TSX parser written in Odin. Emits ESTree-compatible ASTs. 8-19% faster than OXC at the raw parse level. The npm package (`kessel`) uses a native shared library (`libkessel.dylib`) via koffi FFI, with a compact binary AST format decoded in JS — 8% faster than OXC at the npm boundary on measured files.

## Current State

### Build
```bash
task build      # CLI binary → bin/kessel — OK
task build:lib  # Shared library → bin/libkessel.dylib — OK
```

### Tests
| Suite | Result | Command |
|---|---|---|
| Coverage (62K fixtures) | 24/24 | `task test:coverage` |
| Unit (291 fixtures) | 291/291 | `task test:unit` |
| npm smoke test | 8/8 | `cd npm && node test.js` |
| Binary emitter (CLI) | 291/291 | All fixtures emit binary without crash |
| **Binary reader (JS)** | **264/291** | **27 failures — THIS IS THE WORK** |

### Performance (lodash.js, Apple M1 Max)
| Path | Time |
|---|---|
| kessel parse (raw) | 1.0 ms |
| kessel parse + binary emit + decode | 3.6 ms |
| OXC NAPI parseSync | 3.9 ms |
| kessel JSON path (old) | 11.1 ms |

## What Needs To Be Done

The **JS binary reader** (`npm/binary-reader.js`) fails on 27/291 unit fixtures. All failures are OOM caused by the reader going off-rails when it encounters node types whose binary field layout doesn't match what the reader expects. The reader creates runaway object trees until V8 OOMs.

### Root Cause

The binary emitter (`src/binary_emitter.odin`) and reader (`npm/binary-reader.js`) must agree on the exact byte sequence for every node type. For **27 fixtures**, the reader hits a node type where the field order or presence differs from what it expects, causing the read cursor to desync. Once desynchronized, every subsequent `readNode()` reads garbage, creating millions of bogus objects.

### Failing Fixtures (27)

All involve one or more of these patterns:
- **Object destructuring** (`const { a, b } = obj`) — `ObjectPatternProperty` emitted by Odin but read as `Property` by JS with different field layout
- **Array destructuring with defaults** (`const [a = 1] = arr`)
- **Spread in object/array patterns** (`const { ...rest } = obj`)
- **For-in/for-of with destructuring** (`for (const { x } of arr)`)
- **Complex arrow parameters** (`({ a, b = 1 }) => ...`)
- **Method shorthand in objects** (`{ method() {} }`)

### How To Fix

**Option A: Complete the reader (recommended, ~200 lines)**

Add missing cases to the `switch (typeId)` in `readNode()` in `npm/binary-reader.js`. For each failing node type:

1. Look at how the binary emitter writes it in `src/binary_emitter.odin` (search for `bin_emit_*` functions)
2. Mirror the exact field read order in the JS reader's switch case
3. Test with the failing fixture

The key functions to cross-reference:
- `bin_emit_pattern` → handles `ObjectPattern`, `ArrayPattern`, `AssignmentPattern`, `RestElement`
- `bin_emit_property` → handles `Property` (in ObjectExpression)
- `bin_emit_obj_pat_prop` → handles `ObjectPatternProperty` (in ObjectPattern) — **this is the main gap**
- `bin_emit_class_element` → handles `MethodDefinition`, `PropertyDefinition`, `StaticBlock`
- `bin_emit_function_node` → handles `FunctionExpression`, `FunctionDeclaration`

The Property node in the reader currently handles `ObjectExpression` properties but NOT `ObjectPattern` properties (which have a different field layout: `computed, shorthand, key, value-as-pattern` instead of `kind, computed, shorthand, key, value-as-expression`).

**Option B: Add node-size prefix (more robust, ~100 lines Odin + 20 lines JS)**

Add a `u32 node_byte_size` field after the type ID in each node's binary encoding. The reader can then skip unknown nodes by advancing `off += node_byte_size` instead of trying to parse fields it doesn't understand. This prevents OOM on any unhandled node type.

In `src/binary_emitter.odin`, change `bin_node_header` to:
```odin
bin_node_header :: proc(be: ^BinaryEmitter, type_id: BinNodeType, loc: Loc) -> int {
    pos := be.pos  // save position of size field
    bw_u8(be, u8(type_id))
    bw_u32(be, 0)  // placeholder for node size (patched later)
    bw_u32(be, loc.start)
    bw_u32(be, loc.end)
    be.node_count += 1
    return pos + 1  // return offset of the size field
}
```
Then at the end of each node emission, patch the size: `be.buf[size_off..size_off+4] = u32(be.pos - size_off - 4)`.

In `npm/binary-reader.js`, the `default` case in `readNode()` becomes:
```js
default:
    const nodeSize = readU32(); // already read after typeId
    off = nodeStartOff + nodeSize; // skip to next node
    break;
```

**Recommendation: Do Option A first (it's faster to implement), then add Option B as a safety net.**

### Validation

Run the corpus test after fixing:
```bash
# Binary emitter (should already be 291/291)
for f in $(find tests/fixtures -name "*.js" -type f); do
  bin/kessel parse "$f" --binary > /dev/null 2>/dev/null || echo "FAIL: $f"
done

# Binary reader
for f in $(find tests/fixtures -name "*.js" -type f | sort); do
  bin/kessel parse "$f" --binary 2>/dev/null > /tmp/_kb.bin
  node --max-old-space-size=256 -e "
    const fs=require('fs');const{decode}=require('./npm/binary-reader');
    const b=fs.readFileSync('/tmp/_kb.bin');const s=fs.readFileSync('$f','utf8');
    try{const{program}=decode(b,s);process.exit(program.type==='Program'?0:1)}
    catch{process.exit(1)}" 2>/dev/null || echo "FAIL: $f"
done
```

Target: 291/291 on both.

## Key Files

| File | Purpose |
|---|---|
| `src/binary_emitter.odin` | Odin → compact binary AST (the writer side) |
| `npm/binary-reader.js` | JS binary → ESTree objects (the reader side — **fix this**) |
| `npm/index.js` | npm package entry point (koffi FFI → libkessel → binary decode) |
| `npm/test.js` | 8 smoke tests for the npm package |
| `npm/test-corpus.js` | Full corpus validation script |
| `src/ast.odin` | All AST struct definitions (reference for field layouts) |
| `src/lib_exports.odin` | C-compatible exports for the shared library |
| `src/napi.odin` | N-API addon (experimental — 6x slower than binary path, not used) |

## Commands Reference

```bash
task build                    # CLI binary → bin/kessel
task build:lib                # Shared library → bin/libkessel.dylib
task test                     # Primary gate (coverage + unit)
task test:release             # Full gate (coverage + unit + fuzz + bench)
cd npm && node test.js        # npm package smoke test
node npm/test-corpus.js       # Full corpus validation (target: 291/291)
task release                  # Auto-release (bump + changelog + publish)
```
