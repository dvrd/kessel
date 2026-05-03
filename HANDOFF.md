# Kessel — Handoff Document

**Date:** 2026-05-03
**Last commit:** `c7c46de fix: gate more type annotations on TS mode, oxc-only-rejects 529→487`

---

## Current State

| Metric | Value |
|---|---|
| `task test:unit` | ✅ 415/415 |
| `task test:negative` | ✅ 68 rejected |
| `task test:estree` | ✅ matches |
| `task test:oxc-corpus` | ✅ baseline OK |
| `verify_multifile.js` | ✅ 0 kessel-only |
| **oxc-only-rejects** | **487** (was 776) |
| **kessel-only-rejects** | **1** (same) |

---

## What Was Done (This Session): 776 → 487 (↓289)

### Batch 1: Early error promotions (776→650, ↓126)
- `(-5 ** 6)` forward-walk fix, `await ** y`, duplicate exports, `new?.()`, yield/await names, using/labeled/single-stmt checks, readonly, type escapes, ambient init, declare ASI, arrow LT

### Batch 2: Targeted parser checks (650→613, ↓37)
- import.meta property, for-await-in, export using, empty parens, abstract method body, #private accessibility, modifier order, import type string, declare accessor, decorator on static block

### Batch 3: TS type annotation gating (613→487, ↓126)
- Gate variable declarator `: Type` on `allow_ts_mode(p)` (↓84)
- Gate function param, rest param, class field, index sig annotations (↓42)

---

## Next Work: oxc-only-rejects (487 remaining)

### Top clusters (estimated)
| Cluster | ~Count | Approach |
|---|---:|---|
| Expected semicolon (remaining Flow) | ~120 | More type-annotation gating needed |
| Unexpected token (diverse) | ~100 | Per-case analysis |
| Expected X but found X | ~40 | Parser leniency |
| Expected X or X | ~30 | Parser leniency |
| Flow not supported | ~17 | OXC-specific (can't fix) |
| Various small clusters | ~180 | 1-5 files each |

### Still ungated type-annotation sites
- Function return type (`: T` after params, before `{`)
- Arrow return type in `try_parse_ts_arrow_params`
- `this` parameter annotation
- Catch clause annotation

### Commands
```bash
task build && task test:unit && task test:negative
node tests/verifiers/verify_oxc_corpus.js --baseline
node tests/verifiers/verify_oxc_corpus.js --update
cd bench && node -e "console.log(require('oxc-parser').parseSync('t.ts','code').errors)"
```
