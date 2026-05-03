# Kessel — Handoff Document

**Date:** 2026-05-03
**Last commit:** declare on methods, ambient function body, double comma

---

## Current State

| Metric | Value |
|---|---|
| `task test:unit` | ✅ 415/415 |
| `task test:negative` | ✅ 68 rejected |
| `task test:oxc-corpus` | ✅ baseline OK |
| `verify_multifile.js` | ✅ 0 kessel-only |
| **oxc-only-rejects** | **319** (was 776 at session start) |
| **kessel-only-rejects** | **1** (same .d.ts edge) |

Total reduction this session: **776 → 319 (↓457, 59%)**

---

## What Was Done (This Session)

### Commits (12 fix commits)

| # | Technique | Δ |
|---|---|---|
| 1 | 13 early error promotions | ↓76 |
| 2 | await **, reserved binding, exponent, readonly | ↓47 |
| 3 | ambient init, arrow LT, declare ASI, .d.ts | ↓3 |
| 4 | import.meta, for-await-in, empty parens, abstract body, etc. | ↓26 |
| 5 | modifier order, import type, declare accessor, etc. | ↓11 |
| 6 | Gate variable type annotations on TS mode | ↓84 |
| 7 | Gate param/field/index annotations on TS mode | ↓42 |
| 8 | Gate type/interface/enum/declare/namespace on TS mode | ↓131 |
| 9 | Gate remaining TS syntax (return types, type params, etc.) | ↓29 |
| 10 | Gate export/import type, double comma | ↓1 |
| 11 | Declare on methods, ambient function body | ↓7 |

### Key architectural changes
- **TS mode gating**: Added `allow_ts_mode(p)` checks to ~20 call sites that previously parsed TypeScript-specific syntax in JS mode
- **Early error promotion**: Promoted ~40 checks from `report_semantic_error` (gated) to `report_error` (always-on), matching OXC's parser behavior
- **New utilities**: `report_error_at`, `in_export_default` flag

---

## Next Work: 319 remaining

### Breakdown
| Cluster | ~Count | Nature |
|---|---:|---|
| Unexpected token (diverse) | ~120 | Arrow edge cases, double commas, TS-specific |
| Expected semicolon (remaining) | ~40 | Arrow-in-binary, remaining Flow |
| Expected X but found X | ~35 | Reserved words, parser leniency |
| Cannot assign to expression | 9 | Parenthesized destructuring |
| Flow not supported | 8 | OXC-specific (unfixable) |
| Small clusters (1-5 each) | ~100 | Per-case fixes needed |

### What's blocking reaching 0
1. **Arrow function edge cases (~30)**: `((a)) => {}`, `() => {} || true`, `() => {} ? 1 : 2` — complex arrow-vs-expression disambiguation
2. **Flow-specific rejections (~8)**: `Flow is not supported` — OXC explicitly rejects these; kessel happens to accept because syntax overlaps TS
3. **Destructuring pattern validation (~9)**: `[({a: [b=2]})] = t` — parenthesized patterns in destructuring
4. **Diverse "Unexpected token" (~120)**: Each needs individual diagnosis; includes experimental plugins (discard-binding, throw-expression, etc.) that kessel doesn't support

### Commands
```bash
task build && task test:unit && task test:negative
node tests/verifiers/verify_oxc_corpus.js --baseline
node tests/verifiers/verify_oxc_corpus.js --update
```
