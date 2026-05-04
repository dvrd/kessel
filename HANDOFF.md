# Kessel — Handoff Document

**Date:** 2026-05-03
**Last commit:** TS missing rejection sweep

---

## Current State

| Metric | Value |
|---|---|
| `task test:unit` | ✅ 415/415 |
| `task test:negative` | ✅ 68 rejected |
| `task test:oxc-corpus` | ✅ baseline OK |
| `verify_multifile.js` | ✅ 0 kessel-only |
| **oxc-only-rejects** | **292** (was 776) |
| **kessel-only-rejects** | **1** (same .d.ts edge) |

**Total reduction: 776 → 292 (↓484, 62%)**

---

## Summary of All Changes

### Phase 1: Early error promotions (↓163)
~40 `report_semantic_error` → `report_error`: exponentiation, duplicate exports, `new?.()`, yield/await names, using/labeled/single-stmt, readonly, escapes, ambient init, arrow LT, import.meta, for-await, empty parens, abstract body, #private accessibility, modifier order, import type, declare accessor, decorator on static block

### Phase 2: TS mode gating (↓287)
~25 call sites gated on `allow_ts_mode(p)`: variable/param/field/index type annotations, function/class/method/accessor return types, function/class type params, type/interface/enum/declare/namespace/module/global declarations, export type, import type, import-equals, export-as-namespace

### Phase 3: Targeted fixes (↓34)
Double comma in objects, declare on methods, ambient function body, import attribute values, decorator on overload, dup accessibility params, for-await on regular for, ASI decorated overload, enum reserved names, TS for-using initializer, BigInt enum member names, decorated `this` params, reserved object binding values, malformed TS import, await/yield in enum initializers, missing TS arrow expression bodies, ambient using declarations, async arrow line terminators, parenthesized trailing commas, parenthesized rest without arrow, await-using line terminators

---

## Remaining: 292

| Cluster | ~Count |
|---|---:|
| Unexpected token (diverse) | ~120 |
| Expected semicolon | ~40 |
| Expected X but found X | ~30 |
| Cannot assign to expression | 9 |
| Flow not supported | 8 |
| Expected function body (Flow) | 8 |
| await/async context | 6 |
| Invalid rest argument | 6 |
| void as identifier | 6 |
| Keywords with escapes | 5 |
| Small (1-4 each) | ~70 |

### Commands
```bash
task build && task test:unit && task test:negative
node tests/verifiers/verify_oxc_corpus.js --baseline
node tests/verifiers/verify_oxc_corpus.js --update
```
