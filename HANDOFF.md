# Kessel — Handoff Document

**Date:** 2026-05-04
**Last commit:** TS newlines, for-await, decorator, tuple, enum/reserved-word sweep

---

## Current State

| Metric | Value |
|---|---|
| `task test:unit` | ✅ 428/428 |
| `task test:negative` | ✅ 82 rejected |
| `task test:oxc-corpus` | ✅ baseline OK |
| `verify_multifile.js` | ✅ 0 kessel-only |
| **oxc-only-rejects** | **85** (was 776) |
| **kessel-only-rejects** | **1** (same .d.ts edge) |
| **kessel-crash** | **0** (was 3) |

**Total reduction: 776 → 85 (↓691, 89%)**

---

## Summary of All Changes

### Phase 1: Early error promotions (↓163)
~40 `report_semantic_error` → `report_error`: exponentiation, duplicate exports, `new?.()`, yield/await names, using/labeled/single-stmt, readonly, escapes, ambient init, arrow LT, import.meta, for-await, empty parens, abstract body, #private accessibility, modifier order, import type, declare accessor, decorator on static block

### Phase 2: TS mode gating (↓287)
~25 call sites gated on `allow_ts_mode(p)`: variable/param/field/index type annotations, function/class/method/accessor return types, function/class type params, type/interface/enum/declare/namespace/module/global declarations, export type, import type, import-equals, export-as-namespace

### Phase 3: Targeted fixes (↓74)
Double comma in objects, declare on methods, ambient function body, import attribute values, decorator on overload, dup accessibility params, for-await on regular for, ASI decorated overload, enum reserved names, TS for-using initializer, BigInt enum member names, decorated `this` params, reserved object binding values, malformed TS import, await/yield in enum initializers, missing TS arrow expression bodies, ambient using declarations, async arrow line terminators, parenthesized trailing commas, parenthesized rest without arrow, await-using line terminators, non-const initializers in `.d.ts` files, missing statement bodies, stray `]` statement tokens, empty catch bindings, invalid import/export module specifiers, nested spread arguments, unparenthesized arrow operands, rest parameters followed by more parameters, nil-LHS recovery in precedence loop, object rest trailing comma/patterns, labeled `let` declarations, legacy BigInt/octal-float forms, private identifiers blocked where `in` cannot bind them, member expressions rejected in arrow binding patterns

### Phase 4: Parser rejection parity sweep (↓40)
Missing unary operands (`void]` / discard-binding shapes), missing ternary consequent/alternate expressions, generator accessors in object literals, and TypeScript interface accessor signatures (`get foo(param)`, `set foo()`, optional/rest/this setter params, setter return types, accessor type parameters).

### Phase 5: More OXC early-error parity (↓28)
Async arrow restricted productions (`async await =>`, line terminator before `=>`, unparenthesized arrow call), object `async a:` modifier misuse, dynamic `import()` spread in second arg, invalid `export default using` declarations, TS class heritage/implements empty lists, readonly methods, override constructors, type-only import/export specifier misuse, parenthesized binding elements inside patterns, and mapped type `as` without a type.

### Phase 6: Newline / reserved-word / tuple / scope sweep (↓91)
- **TS declaration newlines (8):** ASI between `interface`/`type`/`namespace`/`module` and their names — newline triggers ASI, rejecting `type\nFoo = number` and `declare interface\nI {}` etc.
- **for-await context (4):** Top-level `for await` in non-module JS files correctly rejected; TS files exempt since they may contain later `export` that upgrades to module.
- **Decorator on abstract (3):** `@dec abstract foo(): void` in class bodies now rejected — decorators require implementations.
- **Tuple postfix ? (3):** Fixed `parse_ts_postfix` silently consuming postfix `?` inside tuples. Added `ts_in_tuple_type` flag so `?` correctly produces `TSOptionalType` and enables `required-after-optional` validation.
- **Reserved words as names (14):** `function enum()`, `class enum {}` rejected via value check (lexer emits `.Identifier`). `function null/true/false/if/default()` rejected by narrowing `has_name` from `is_keyword_usable_as_property_name` to `can_be_binding_identifier`.

---

## Remaining: 85

| Cluster | ~Count |
|---|---:|
| Unexpected token (diverse) | ~47 |
| Expected semicolon (paren arrows, TS edge) | ~12 |
| Expected X but found X | ~9 |
| Reserved word as identifier | ~2 |
| Keyword escapes | ~2 |
| Decorators not valid here | ~1 |
| Yield context | ~2 |
| Import type options | ~2 |
| Import type options | ~5 |
| Small (1 each) | ~7 |

### Largest remaining sub-clusters
- Parenthesized binding elements in arrow params (6): `(a, (b)) => 42`
- `await` as default param value in async (6): `async function(a = await)`
- Bare `let` in strict mode (4): `"use strict"; let\n`
- `new <T>Foo()` type assertion (4): TS-specific error recovery

### Commands
```bash
task build && task test:unit && task test:negative
node tests/verifiers/verify_oxc_corpus.js --baseline
node tests/verifiers/verify_oxc_corpus.js --update
```
