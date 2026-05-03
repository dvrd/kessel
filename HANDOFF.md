# Kessel — Handoff Document

**Date:** 2026-05-03
**Last commit:** `fix: 5 more parser-level checks, oxc-only-rejects 653→650 (↓3)`

---

## Current State

### Build & Test

```bash
task build                    # ✅ Compiles clean
task test:unit                # ✅ 415/415 pass
task test:negative            # ✅ 68 rejected (↑1 from session start)
task test:estree              # ✅ Binary-buffer matches JSON
task test:oxc-corpus          # ✅ Baseline OK
verify_multifile.js           # ✅ 0 kessel-only-rejects
```

### OXC Corpus Numbers

| Verdict | Count | Δ from start |
|---|---:|---:|
| ok-vs-oxc | 15,575 | +16 |
| pass-both | 3,074 | −3 |
| reject-both | 519 | +4 |
| should-pass-rejected | 1,762 | +103 |
| **oxc-only-rejects** | **650** | **−126** |
| should-reject-passed | 34 | 0 |
| kessel-only-rejects | **1** | 0 |

Multi-file: **0** kessel-only-rejects (11,180 virtual files).

---

## What Was Done (This Session)

### Commit 1: 13 early errors → 776→700 (↓76)

| # | Error | Fix |
|---|---|---|
| 1 | `(-5 ** 6)` false negative | Forward-walk for `)` before `**` |
| 2 | Duplicate named exports (JS) | `report_error_at` with TS gate |
| 3 | `new Foo?.()` | NewExpression check at OptionalChain |
| 4 | yield/await gen-expr/async-expr name | Promote + `in_export_default` flag |
| 5 | yield/await declaration name | Split gen-context vs strict |
| 6 | using/await-using in bare case | Promote |
| 7 | const/using/class/gen in labeled stmt | Promote |
| 8 | gen/async/class in single-stmt context | Promote |
| 9 | `type` keyword with escapes | `has_escape` at dispatch |
| 10 | `readonly` on non-array/tuple | Post-postfix operand check |
| 11 | using in for-init inside case | Clear in_case_clause in for-head |

### Commit 2: 5 checks → 700→653 (↓47)

| # | Error | Fix |
|---|---|---|
| 1 | `await expr ** y` | Extend `**` check to AwaitExpression |
| 2 | Reserved words as binding names | Promote `report_semantic_error` |
| 3 | `import { default }` | Reserved word check on no-`as` specifiers |
| 4 | `1e`, `1e+` missing exponent | Lexer exp_digits==0 check |
| 5 | `readonly` on non-array/tuple | (from commit 1) |

### Commit 3: 5 checks → 653→650 (↓3)

| # | Error | Fix |
|---|---|---|
| 1 | `declare const x: T = v` | Only error with type annotation + init |
| 2 | `()\n=>` line terminator | had_line_terminator in arrow path |
| 3 | `declare\nconst` ASI | Newline check in declare peek |
| 4 | .d.ts ambient const init | source_is_dts gate |

---

## Next Work: oxc-only-rejects (650 remaining)

### Top clusters

| OXC Error | Count | Fixability |
|---|---:|---|
| Expected semicolon (Flow types in JS mode) | ~200 | HARD — needs TS type-annotation gating on lang |
| Unexpected token (diverse) | ~160 | MIXED — per-case analysis needed |
| Expected X but found X | ~50 | MIXED |
| Expected X or X but found X | ~36 | MIXED |
| Flow is not supported | ~18 | N/A — OXC-specific rejection |
| Reserved word in identifier position | ~20 | MODERATE — scattered contexts |
| Cannot assign to expression | ~9 | HARD — destructuring pattern validation |
| Decorator on overload | ~3 | MODERATE |
| Abstract method with implementation | ~2 | MODERATE |
| Tuple required after optional | ~2 | Blocked — TSOptionalType not produced |

### Known Issues

**TSOptionalType not produced in tuple types**: `[string?]` should create TSOptionalType wrapping TSStringKeyword, but the postfix `?` check in the tuple loop fails to fire. Root cause needs investigation — the `parse_ts_type` call should return with `?` as current token, but something may be consuming it. This blocks tuple element validation (required-after-optional, rest-after-rest).

### Checks that stay gated

- Strict-mode reserved identifiers, duplicate params, binding restrictions
- eval/arguments assignment, scope analysis, duplicate private members
- Legacy octal, undeclared exports, __proto__ redefinition
- yield as function name in strict-only (no generator) context
- `let` as labeled item (OXC handles via ASI, not parser error)

---

## Commands

```bash
task build && task test:unit && task test:negative && task test:estree
node tests/verifiers/verify_oxc_corpus.js --baseline   # gate
node tests/verifiers/verify_oxc_corpus.js --update      # re-baseline
node tests/verifiers/verify_multifile.js                # multi-file
cd bench && node -e "console.log(require('oxc-parser').parseSync('t.ts','code').errors)"
```
