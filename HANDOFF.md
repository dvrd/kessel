# Kessel — Handoff Document

**Date:** 2026-05-04
**Last commit:** Phase 6 comprehensive rejection-parity sweep

---

## Current State

| Metric | Value |
|---|---|
| `task test:unit` | ✅ 428/428 |
| `task test:negative` | ✅ 82 rejected |
| `task test:oxc-corpus` | ✅ baseline OK |
| `verify_multifile.js` | ✅ 0 kessel-only |
| **oxc-only-rejects** | **71** (was 776) |
| **kessel-only-rejects** | **1** (same .d.ts edge) |
| **kessel-crash** | **0** (was 3) |

**Total reduction: 776 → 71 (↓705, 91%)**

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

### Phase 6: Comprehensive rejection-parity sweep (↓113)
Across 12 commits:
- **TS declaration newlines (8):** ASI between `interface`/`type`/`namespace`/`module` and names
- **for-await context (4):** Top-level `for await` in non-module JS rejected
- **Decorator on abstract (3):** `@dec abstract foo()` rejected
- **Tuple postfix ? (3):** `ts_in_tuple_type` flag for TSOptionalType
- **Reserved words as names (14+):** function/class enum, null/true/false/if/default
- **Decorator on export default (2):** `@foo export default 0;` rejected
- **`export {default}` (1):** Reserved word without `as` rejected
- **`yield*` without operand (3):** Delegate yield requires expression
- **Optional param TS gate (2):** `?` on params gated on TS mode
- **Generator no name (2):** `({ * })` rejected
- **Override modifier order (1):** override must precede readonly
- **Export default interface (1):** Anonymous interface rejected
- **void in destructuring (3):** `{ p: void }`, `[ ...void ]` rejected
- **String destructuring (1):** `{ "while" }` requires `:` value
- **`export =` without expr (2):** Empty export assignment rejected
- **Interface/type name narrowing (2+):** `interface void {}` triggers ASI
- **await-in-async-params (6):** Bare `await` in params requires operand
- **Scope isolation (1):** Nested function resets `in_async_params`
- **Double-comma (2):** Type args `<a,,b>` and tuples `[T,,]` rejected
- **Type-param empty comma (2):** `<,>` rejected
- **Spread without arrow (2):** `(b, ...a)` without `=>` rejected
- **Variance keyword name (1):** `<in in>` reserved-word check
- **typeof trailing dot (2):** `typeof A.` rejected
- **Export-star non-string (1):** `export * from Aaa` rejected
- **Import-type trailing comma (1):** `import("foo", )` rejected
- **Enum empty/private (2):** `{ , }` and `{ #x }` rejected
- **Empty type annotation (2+):** `(a: )` reports error

---

## Remaining: 71

| Category | ~Count | Difficulty |
|---|---:|---|
| TS error recovery (malformed syntax) | ~30 | HARD |
| Parenthesized binding in arrows | ~7 | HARD |
| Bare `let` in strict/TS | ~4 | MEDIUM |
| JSX edge cases | ~4 | HARD |
| Import type options (escape/spread/computed) | ~4 | HARD |
| `enum` as identifier in JS | ~3 | MEDIUM |
| Keyword escapes in for-of | ~2 | MEDIUM |
| Unparenthesized fn/ctor type in union | ~2 | HARD |
| for-of/using disambiguation | ~4 | HARD |
| Other (1 each) | ~11 | MIXED |

### Commands
```bash
task build && task test:unit && task test:negative
node tests/verifiers/verify_oxc_corpus.js --baseline
node tests/verifiers/verify_oxc_corpus.js --update
```
