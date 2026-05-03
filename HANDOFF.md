# Kessel — Handoff Document

**Date:** 2026-05-02
**Last commit:** `fb83dd6 fix: enable 7 parser-level early errors`

---

## Current State

### Build & Test

```bash
task build                    # ✅ Compiles clean
task test:unit                # ✅ 415/415 pass
task test:negative            # ✅ Baseline match (3 improvements pending relock)
task test:estree              # ✅ Binary-buffer matches JSON
task test:oxc-corpus          # ✅ 0 kessel-only-rejects
```

### OXC Corpus Numbers (25,140 single-file + 11,180 multi-file = 36,320 total)

| Verdict | Count | Meaning |
|---|---:|---|
| ok-vs-oxc | 15,394 | Both agree (TS suite) |
| pass-both | 3,077 | Both accept, expected pass |
| reject-both | 513 | Both reject |
| skip-multi-file | 3,519 | Multi-file fixtures (tested separately) |
| should-pass-rejected | 1,581 | Both reject, babel expects pass (out-of-scope plugins) |
| **oxc-only-rejects** | **1,022** | **Kessel accepts, OXC rejects ← NEXT WORK** |
| should-reject-passed | 34 | Both accept, babel expects fail (shared leniency) |
| kessel-only-rejects | **0** | OXC accepts, kessel rejects ← **CLEARED** |

Multi-file corpus: 0 kessel-only-rejects across 11,180 virtual files.

---

## What Was Done (This Session)

### Parser Parity: kessel-only-rejects 18 → 0

Fixed 15 parser bugs across three commits. Every file OXC's parser accepts, kessel now also accepts.

| # | Bug | Fix Location | Technique |
|---|---|---|---|
| 1 | `let\n{ a } = …` rejected in sloppy | `parse_statement_or_declaration` | Removed `.LBrace` from `is_let_asi` |
| 2 | JSX attr `\"` treated as JS escape | `lex_string_scalar` | `!l.jsx_string_mode` gate on escape handler |
| 3 | JSX `attr={expr}` nxt lexed in wrong mode | `parse_jsx_opening_element` | Re-lex nxt String token after `{` in JSX attr |
| 4 | JSX text `7x` → "Identifier after number" | `parse_jsx_text` | Clear `lexer_errors` in re-scanned text region |
| 5 | `export { type as as if }` | `parse_export_named` | 4-token lookahead past second `as` |
| 6 | `import { type as as as }` | `parse_import_specifier` | Same 4-token lookahead (mirrored) |
| 7 | Arrow in ternary `0 ? v => (sum=v) : v => 0 : v => 0` | `parse_arrow_function` + `parse_conditional_expr` | Speculative `: Type => body` parse; commit only if ternary `:` still follows |
| 8 | TS arrow ASI `() => {…}\n() => {…}` | `parse_lhs_tail` | `(` on new line after ArrowFunctionExpression exits tail loop |
| 9 | Template literal types `\`${A<B<C>>}\`` | `parse_ts_template_literal_type` | Re-lex `}` as `lex_template_resume` when `>>` split consumed template_depth |
| 10 | Overloaded call sigs `T\n<U extends V>` | `parse_ts_type_reference` | Speculative `parse_ts_type_arguments` when `<` on new line; rollback on error |
| 11 | `.js` → no JSX (no-plugin-no-jsx) | `detect_lang_from_path` | `.js` → `Lang.JS` (was `.JSX`); `LAngle` added to directive exclusion |
| 12 | `let\n{}` in single-stmt context | `parse_statement_or_declaration` | `is_let_asi` includes `.LBrace` when `block_depth > 0` |
| 13 | `export default @dec abstract class` | `parse_export_default` | Handle `@` and `abstract` before `class` |
| 14 | `import await from "m"` | `parse_import_declaration` | Accept `can_be_binding_identifier` for default import binding |
| 15 | `false ? (param): string => param : null` | `parse_conditional_expr` | Speculative arrow with return type in conditional consequent |

### Early Error Promotion: oxc-only-rejects 1082 → 1022

Converted 7 checks from gated `report_semantic_error` to always-on `report_error`, matching OXC's parser (not `oxc_semantic`) behavior:

- `return` outside function / in static block
- `yield` in non-generator
- `await` outside async (`for await` too, with static-block exception)
- Duplicate default export
- Static member named `prototype` (with ambient-context exception)
- Rest parameter not last (new check)

### Infrastructure

- `tests/verifiers/verify_multifile.js` — new verifier that splits multi-file TS fixtures at `// @filename:` directives and tests each virtual file
- `tests/runners/run_tests.sh` — added `--lang=` overrides for `recovery/jsx_ts/`, `es2025/*jsx*`, `negative/truncation/*jsx*`
- `src/main.odin` — `detect_lang_from_path` returns `.JS` for `.js` files (was `.JSX`)

---

## Next Work: oxc-only-rejects (1,022 remaining)

These are files OXC's parser rejects but kessel accepts. Kessel is too lenient — it needs to add these validation checks.

### Architecture

Kessel has a `check_semantics` flag (default `false`) that gates ~200 existing `report_semantic_error` checks. **Do NOT enable this globally** — it introduces 641 false positives because:

1. Many gated checks are for `oxc_semantic`-level errors (strict-mode violations, scope analysis, duplicate private members) that OXC's **parser** doesn't check
2. Some checks have correctness bugs (over-rejection)

The right approach:
1. Identify which errors OXC's **parser** (not `oxc_semantic`) reports
2. For each: if kessel already has it as `report_semantic_error`, convert to `report_error`
3. If missing, add as `report_error`
4. Test with `cd bench && node -e "console.log(require('oxc-parser').parseSync('t.js', '...').errors)"` to verify OXC's parser actually reports each error

### How to verify OXC parser vs semantic behavior

```javascript
// In bench/ directory (has oxc-parser installed):
const oxc = require('oxc-parser');
const r = oxc.parseSync('test.js', 'const x;');
console.log(r.errors); // Parser errors only — oxc_semantic is NOT run
```

### Top error clusters (by OXC parser error message)

Run this to get the current triage:

```bash
node -e "..." # (see the inline triage scripts used in this session)
```

Or use the verifier:

```bash
node tests/verifiers/verify_oxc_corpus.js          # single-file corpus
node tests/verifiers/verify_multifile.js            # multi-file corpus
```

### Known remaining parser-level errors (OXC parser catches, kessel doesn't)

| OXC Error | Count | Where to fix |
|---|---:|---|
| Expected semicolon (ASI edge cases) | ~220 | Various parser recovery paths |
| Unexpected token | ~100 | Parser too lenient on malformed syntax |
| Identifier expected / reserved word | ~40 | Keyword-as-identifier checks |
| Modifier ordering (public static vs static public) | ~12 | `parse_class_element` |
| Implementation in ambient context | ~11 | `parse_function_declaration` needs ambient check |
| Initializer in ambient context | ~9 | Variable/class field init in `declare` |
| Empty type argument list `Foo<>` | ~7 | `parse_ts_type_arguments` |
| Missing const initializer | ~14 | Already fixed (always-on via `report_error`) |
| Parameter property with binding pattern | ~8 | Constructor param validation |
| Modifier on index signature | ~7 | `parse_ts_object_member` |

### Checks that should stay gated (oxc_semantic, not parser)

These are correctly behind `report_semantic_error` / `check_semantics`:

- Strict-mode reserved identifiers (~79 files)
- Duplicate parameter names in strict mode (~47)
- Binding name restrictions in strict mode (~39+39)
- eval/arguments assignment in strict mode (~31)
- Scope analysis (duplicate declarations) (~54)
- Duplicate private class members (~113)
- Legacy octal in strict mode (~19)
- Undeclared exports (~19)
- __proto__ redefinition (~25)

---

## File Layout Reference

| File | Lines | What changed |
|---|---:|---|
| `src/parser.odin` | ~17.5K | 15 bug fixes + 7 early-error promotions |
| `src/lexer.odin` | ~3.4K | JSX string escape fix |
| `src/main.odin` | ~8K | `.js` → `Lang.JS` |
| `tests/verifiers/verify_multifile.js` | ~230 | New multi-file verifier |
| `tests/runners/run_tests.sh` | ~230 | `--lang=` overrides for JSX fixtures |

---

## Commands Cheat Sheet

```bash
task build                                    # Build release binary
task test:unit                                # 415 golden-output fixtures
task test:negative                            # Early-error baseline
task test:estree                              # ESTree conformance
node tests/verifiers/verify_oxc_corpus.js     # Full 25K corpus (15s)
node tests/verifiers/verify_multifile.js      # Multi-file corpus (35s)
node tests/verifiers/triage_kessel_only_rejects.js  # Cluster rejects by error

# Test a single file against OXC:
cd bench && node -e "const r = require('oxc-parser').parseSync('t.ts', 'const x;'); console.log(r.errors)"
```
