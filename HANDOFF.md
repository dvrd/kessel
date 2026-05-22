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
| **Binary reader (JS)** | **291/291** | **COMPLETED** |

### Performance (lodash.js, Apple M1 Max)
| Path | Time |
|---|---|
| kessel parse (raw) | 1.0 ms |
| kessel parse + binary emit + decode | 3.6 ms |
| OXC NAPI parseSync | 3.9 ms |
| kessel JSON path (old) | 11.1 ms |

## What Was Done (Binary Reader Fix)

The JS binary reader (`npm/binary-reader.js`) had three root causes of failure:

### 1. Property Field Layout Mismatch
ObjectPattern properties (destructuring) lacked the `kind:u8` byte that ObjectExpression properties emit. The reader's `Property` case always read `kind` first, causing a 1-byte desync for every destructuring pattern. Fixed by adding `kind` + `method` flag to both emitter paths so all Property nodes share one binary layout.

### 2. Tag/TypeId Collision
`VT_NODE (5)` and `VT_NULL_NODE (7)` overlapped with `BooleanLiteral` and `BigIntLiteral` typeIds. When `readNodeOrNull()` peeked at the first byte to check for a tag, it would misinterpret literal nodes as tags (or vice versa). Fixed by moving tags to `0xFD`/`0xFE`, safely above the `BinNodeType` range (0..99).

### 3. NullNode in Bare-Node Positions
When `bin_emit_expression` writes `NullNode` for nil/unknown expressions (e.g., error-recovery "Unknown" nodes), `readNode()` would try to read a 9-byte header from a 1-byte tag, consuming bytes that belong to the next node. Fixed by having `readNode()` peek for `0xFE` before reading the header.

### Additional Fixes
- **SpreadElement** in objects: `{...x}` was emitted as a malformed Property with nil key. Now emits a proper SpreadElement node.
- **JSX nodes**: Added binary emission for JSXElement, JSXFragment, JSXOpeningElement, JSXClosingElement, JSXAttribute, JSXSpreadAttribute, JSXExpressionContainer, JSXText, JSXIdentifier, JSXMemberExpression, JSXNamespacedName.
- **TS expressions**: Added binary emission for TSAsExpression, TSSatisfiesExpression, TSNonNullExpression, TSTypeAssertion, TSInstantiationExpression.
- **Safety**: Bounds checks on `readNodeArray` counts to throw instead of OOM on desync.

## Key Files

| File | Purpose |
|---|---|
| `src/binary_emitter.odin` | Odin → compact binary AST (the writer side) |
| `npm/binary-reader.js` | JS binary → ESTree objects (the reader side) |
| `npm/index.js` | npm package entry point (koffi FFI → libkessel → binary decode) |
| `npm/test.js` | 8 smoke tests for the npm package |
| `npm/test-corpus.js` | Full corpus validation script |
| `src/ast.odin` | All AST struct definitions (reference for field layouts) |
| `src/lib_exports.odin` | C-compatible exports for the shared library |

## Commands Reference

```bash
task build                    # CLI binary → bin/kessel
task build:lib                # Shared library → bin/libkessel.dylib
task test                     # Primary gate (coverage + unit)
task test:release             # Full gate (coverage + unit + fuzz + bench)
cd npm && node test.js        # npm package smoke test
node npm/test-corpus.js       # Full corpus validation (target: 291/291 ✓)
task release                  # Auto-release (bump + changelog + publish)
```
