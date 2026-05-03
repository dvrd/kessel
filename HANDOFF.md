# Kessel — Handoff Document

**Date:** 2026-05-03
**Last commit:** `e83bbab fix: promote 13 early errors to parser-level, oxc-only-rejects 776→700 (↓76)`

---

## Current State

### Build & Test

```bash
task build                    # ✅ Compiles clean
task test:unit                # ✅ 415/415 pass
task test:negative            # ✅ Baseline match
task test:estree              # ✅ Binary-buffer matches JSON
task test:oxc-corpus          # ✅ Baseline OK
```

### OXC Corpus Numbers (25,140 single-file + 11,180 multi-file = 36,320 total)

| Verdict | Count | Meaning |
|---|---:|---|
| ok-vs-oxc | 15,569 | Both agree (TS suite) |
| pass-both | 3,077 | Both accept, expected pass |
| reject-both | 518 | Both reject |
| skip-multi-file | 3,519 | Multi-file fixtures (tested separately) |
| should-pass-rejected | 1,722 | Both reject, babel expects pass (out-of-scope plugins) |
| **oxc-only-rejects** | **700** | **Kessel accepts, OXC rejects ← NEXT WORK** |
| should-reject-passed | 34 | Both accept, babel expects fail (shared leniency) |
| kessel-only-rejects | **1** | OXC accepts, kessel rejects (known .d.ts edge) |

Multi-file corpus: 0 kessel-only-rejects across 11,180 virtual files.

---

## What Was Done (This Session)

### Early Error Promotion: oxc-only-rejects 776 → 700 (↓76)

Promoted 13 parser-level early errors that OXC's parser (not `oxc_semantic`) enforces:

| # | Error class | Count | Technique |
|---|---|---:|---|
| 1 | Unparenthesized unary before `**` (e.g. `(-5 ** 6)`) | 6 | Forward-walk for matching `)` between UnaryExpr end and `**` |
| 2 | Duplicate named export (JS mode only) | 20 | `report_semantic_error_at` → `report_error_at` with `allow_ts_mode` gate |
| 3 | Invalid optional chain from new (`new Foo?.()`) | 7 | NewExpression check at OptionalChain entry |
| 4 | yield/await as generator/async expression name | 7 | `report_semantic_error` → `report_error` |
| 5 | yield/await as declaration name in generator/async context | 6 | Split: gen-context → `report_error`; strict-only → stays gated |
| 6 | Using/await-using in bare case clause | 6 | `report_semantic_error` → `report_error` |
| 7 | const/using/class/gen in labeled statement | 6 | Promoted labeled-item checks |
| 8 | Gen/async/class in single-statement context | 5 | `report_semantic_error` → `report_error` |
| 9 | `type` keyword with Unicode escapes in import/export | 4 | `has_escape` check at `type` dispatch |
| 10 | `readonly` on non-array/tuple types | 5 | Post-parse operand type check |
| 11 | Using in for-init inside case clause | 2 | Clear `in_case_clause` in for-head |
| 12 | `report_error_at` helper proc | — | New utility |
| 13 | `in_export_default` flag | — | OXC accepts `export default function *yield(){}` |

### Key Fixes

**`(-5 ** 6)` false negative**: The paren-walk backward from the UnaryExpression found `(` at byte 0 and assumed paren-wrapped. But this `(` wraps the entire binary expression, not just the unary. Fixed by also walking forward from the UnaryExpression's end to verify a `)` appears before the `**` token.

**`export default function *yield() {}`**: OXC specifically accepts `yield` as a generator name in export-default position but rejects it everywhere else (`(function*yield(){})`, `var x = function*yield(){}`, `function*g() { function*yield(){} }`). Added `in_export_default` parser flag to match OXC's behavior.

**Using in for-init inside switch case**: `switch(1) { case 1: for(using x = bar();;); }` was incorrectly rejected because `in_case_clause` wasn't cleared when entering the for-statement head. Added save/restore of `in_case_clause` before the for-init.

---

## Next Work: oxc-only-rejects (700 remaining)

### Top remaining clusters (by OXC error message)

| OXC Error | Count | Fixability |
|---|---:|---|
| Expected semicolon (Flow type annotations in JS mode) | ~200 | HARD — kessel parses TS type annotations in JS mode; needs lang gating |
| Unexpected token (diverse) | ~160 | MIXED — need per-case analysis |
| Expected X but found X | ~50 | MIXED — some are Flow, some are parser leniency |
| Expected X or X but found X | ~36 | MIXED — Flow + real parser gaps |
| Flow is not supported | ~18 | EASY — but these are OXC-specific rejections |
| Identifier expected, 'X' reserved | ~30 | MODERATE — reserved word checks in various contexts |
| Cannot assign to this expression | ~9 | HARD — complex destructuring pattern validation |
| Await only in async | ~7 | Already partially done |
| Invalid rest operator's argument | ~6 | MODERATE |
| Decorators not valid here | ~5 | MODERATE |
| Abstract method with implementation | ~2 | Already checked (gated) |

### Architecture Notes

The largest remaining cluster (~200 files) is **Flow type annotations parsed as TS in JS mode**. These are `.js` files in `babel/flow/` subdirs that use Flow-style type annotations. OXC rejects them (no Flow support in JS mode), but kessel accepts them because it parses TS type annotations even when `lang=JS`. Fixing this would require gating all TS type annotation parsing on `allow_ts_mode(p)`, which is a significant change affecting many call sites.

### Checks that should stay gated (oxc_semantic, not parser)

- Strict-mode reserved identifiers
- Duplicate parameter names in strict mode
- Binding name restrictions in strict mode
- eval/arguments assignment in strict mode
- Scope analysis (duplicate declarations)
- Duplicate private class members
- Legacy octal in strict mode
- Undeclared exports
- __proto__ redefinition
- `yield` as function name in strict-only context (not generator)

---

## Commands Cheat Sheet

```bash
task build                                    # Build release binary
task test:unit                                # 415 golden-output fixtures
task test:negative                            # Early-error baseline
task test:estree                              # ESTree conformance
node tests/verifiers/verify_oxc_corpus.js     # Full 25K corpus (~15s)
node tests/verifiers/verify_oxc_corpus.js --baseline  # Gate check
node tests/verifiers/verify_oxc_corpus.js --update    # Re-baseline
node tests/verifiers/verify_multifile.js      # Multi-file corpus (~35s)

# Test OXC parser behavior:
cd bench && node -e "const r = require('oxc-parser').parseSync('t.js', 'const x;'); console.log(r.errors)"

# Full triage with error clusters:
node tests/verifiers/verify_oxc_corpus.js --json-out tmp/oxc_corpus_run.json
```
