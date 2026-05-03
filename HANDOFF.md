# Kessel — Handoff Document

**Date:** 2026-05-03
**Last commit:** gate TS declarations on allow_ts_mode

---

## Current State

| Metric | Value |
|---|---|
| `task test:unit` | ✅ 415/415 |
| `task test:negative` | ✅ 68 rejected |
| `task test:oxc-corpus` | ✅ baseline OK |
| `verify_multifile.js` | ✅ 0 kessel-only |
| **oxc-only-rejects** | **356** (was 776 at session start) |
| **kessel-only-rejects** | **1** (same .d.ts edge) |

---

## What Was Done (This Session): 776 → 356 (↓420)

### Phase 1: Early error promotions (776→613, ↓163)
Promoted ~30 checks from `report_semantic_error` to `report_error` matching OXC parser behavior:
- `(-5 ** 6)`, `await ** y`, duplicate exports, `new?.()`, yield/await names
- using/labeled/single-stmt checks, readonly types, type escapes
- ambient init, declare ASI, arrow LT, import.meta property
- for-await-in, export using, empty parens, abstract methods
- #private accessibility, modifier order, import type string, declare accessor

### Phase 2: TS mode gating (613→356, ↓257)
Gated TS-specific syntax on `allow_ts_mode(p)` so JS mode correctly rejects it:
- Variable declarator `: Type` annotations
- Function parameter and rest-parameter `: Type` annotations
- Class field `: Type` annotations
- Index signature `: Type` annotations
- `type X = ...` alias declarations
- `interface X { ... }` declarations
- `enum X { ... }` declarations
- `declare ...` statements
- `namespace` / `module` / `global` declarations

---

## Next Work: oxc-only-rejects (356 remaining)

### Breakdown

| Cluster | Count | Nature |
|---|---:|---|
| Unexpected token (diverse) | ~137 | Per-case: double comma, `get *iter`, `new <T>`, etc. |
| Expected semicolon | ~52 | Arrow edge cases, remaining Flow, octal float |
| Expected X but found X | ~42 | Reserved words in contexts, parser leniency |
| Cannot assign to expression | 9 | Parenthesized destructuring pattern validation |
| Expected X or X but found X | 8 | Async arrow in binary, accessor generator |
| Expected function body (Flow) | 8 | Flow function types in JS mode |
| await outside async | 7 | Top-level await in script mode |
| Invalid rest argument | 6 | Rest with non-simple pattern |
| void as identifier | 6 | `discard-binding` experimental plugin |
| Keywords with escapes | 5 | `\u{61}wait` etc. |
| declare on class element | 5 | `declare` on methods in Flow/estree |
| Small clusters (1-4 each) | ~70 | Diverse individual checks |

### What's needed to reach 0

1. **Arrow function edge cases (~20)**: parenthesized inner patterns, arrow-in-binary (`() => {} || true`), arrow-in-ternary
2. **Remaining Flow files (~30)**: function return types, this-annotations, call properties still parsed in JS mode
3. **Per-case "Unexpected token" (~137)**: each needs individual diagnosis (double commas, invalid accessor patterns, `new <T>`, etc.)
4. **Reserved words in more contexts (~15)**: `this` as parameter, `while`/`if` in destructuring, `void` as binding
5. **Decorator validation (~6)**: overload decoration, export-before/after-decorator
6. **Misc validation (~50)**: import attribute values, set accessor rest, using initializer, ambient function body, etc.

### Commands
```bash
task build && task test:unit && task test:negative
node tests/verifiers/verify_oxc_corpus.js --baseline
node tests/verifiers/verify_oxc_corpus.js --update
cd bench && node -e "console.log(require('oxc-parser').parseSync('t.ts','code').errors)"
```
