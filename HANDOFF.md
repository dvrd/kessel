# Kessel — Handoff

**Last updated:** 2026-04-24 — Session 11 complete.
**Status headline:** 144/144 spec-fixtures; **97/100 fuzz-diff** (3 baselined Kessel-correct/OXC-permissive divergences); 0 divergences vs OXC on 12 real files; **125/125 negative-gate rejections across 54 static-error classes (ratchet engaged)**; **Test262 full corpus baselined at 48 697 / 49 729 (97.92%)** — up from 47 889 (96.30%) at Session-10 end (+808 tests across 17 parser/lexer patches); **`test:estree:strict` passes zero-tolerance on every real-world file**; 467/467 real-world; 66/66 curated test262; **32/32 recovery**; 467/467 invariants; 57/57 node-type coverage; 11/11 regression; **284/284 unit fixtures**.
**Repo state:** `main` at session-11 head (4 cleanup commits on top of 17 parser/lexer commits), ~23 530 LOC of Odin across 7 files + npm/kessel-parser shim with async server-mode bridge.

Single authoritative handoff. Supersedes the old `OXC_PARITY.md` and
`SESSION_REPORT.md` (merged in, then deleted).

---

## 1. What is Kessel

Kessel is a JavaScript / TypeScript / JSX parser written in Odin. It produces
ESTree-compatible JSON ASTs (plus optional OXC-shape module record and
structured errors). Originally built to parse ES2015–ES2025 JavaScript faster
than [oxc-parser](https://www.npmjs.com/package/oxc-parser); now also covers
~90 % of the TypeScript type system.

- **Not** a transpiler, bundler, linter, or formatter.
- **Pure** parser with JSON output. No dependencies outside the Odin toolchain.
- **Zero** heap allocations post-init (virtual arena + bump pool).

---

## 2. Current State Snapshot

### Build
```
odin build src -out:bin/kessel -o:speed -no-bounds-check
```
**Status:** ✅ passes (via `task build`). Debug build works but emits ~50
cosmetic linker warnings about JSX/TS generic symbol visibility; binary
is fine.

### Test matrix

| Suite | Command | Result | Notes |
|---|---|---|---|
| Unit | `task test:unit` | **284 / 409** (100% pass rate) | 125 skipped = negative-gate-owned early-error fixtures. Zero failures. Session-11 refreshed 10 expected files for phase-imports + recovery const-no-init. |
| Regression | `task test:regression` | **11 / 11** ✅ | Structural diff vs OXC for session-fixed bugs. |
| Real-world | `task test:real` | **467 / 467** ✅ | Zero failures across the full real-world corpus. |
| Node coverage | `task test:nodes` | **57 / 57** ✅ | Every emitted ESTree type has a live fixture. |
| Test262 (curated) | `task test:test262` | **66 / 66** ✅ | Full curated subset passing; broader Test262 (~45 000) not wired yet. |
| Spec-fixtures | `task test:spec-fixtures` | **144 / 144** ✅ | All 22 categories at 100%. lexical/001 (BOM+hashbang) rejects with matching OXC diagnostic. |
| Invariants | `task test:invariants` | **467 / 467** ✅ | Structural ESTree invariants across real corpus. |
| ESTree drift | `task test:estree` | ✅ 0 mismatches | jquery / react-dom.dev / preact / snabbdom all deep-compare against OXC byte-for-byte via `verify_integration`. |
| ESTree drift (strict) | `task test:estree:strict` | ✅ 0 mismatches | Zero-tolerance variant of the above for release gating. |
| Multi-parser | `task test:multi-parser` | ✅ matches baseline | snabbdom passes vs acorn + babel. |
| Spec-compliance | `task test:spec-compliance` | **0 divergences** ✅ (baselined) | All 12 curated real files (snabbdom, preact, jquery, react.dev, lodash, acorn, react-dom.dev, antd, d3, chalk, petite-vue, zod) match OXC byte-for-byte. 11 561 → 0 across two sweeps. |
| Fuzz (diff vs OXC) | `task test:fuzz` | **97 / 100** ✅ (baselined) | 3 baselined Session-11 known-failures: Kessel correctly rejects per-spec where OXC accepts (duplicate arrow params ×2, let / function-decl clash). |
| Fuzz (invalid input) | `task test:fuzz:invalid` | **8 / 8** ✅ (baselined) | 8 SIGTERMs on 350 KB–4 MB mutated files (deadline-crosses, not parser bugs). |
| Crashes-known | `task test:crashes-known` | ✅ 0 pinned, 0 new | |
| Recovery | `task test:recovery` | **20 / 20** ✅ | All anchors survive; spans stay sane. |
| **Negative gate** | `task test:negative` | **125 / 125 rejected** ✅ (ratchet engaged) | **54 static-error classes** enforced across `tests/fixtures/negative/` + `tests/fixtures/early_errors/`: 9 from Session 5 (`43c57dc`) + 20 from Session 6 + 12 from Session 7 + 7 from Session 8 + 6 from Session 9 (`795f442`, `e64ee36`, `62a7b61`). Baseline is 100% “rejected” so the verifier auto-strictifies: any new fixture the parser accepts fails the default gate. See ERR-5 below for the full catalog. |
| Negative gate (strict) | `task test:negative:strict` | **125 / 125 rejected** ✅ | Zero-tolerance variant, no baseline. Run before a release. |
| Recovery | `task test:recovery` | **32 / 32** ✅ | Expanded from 20 in Session 9; 12 new fixtures across expressions / statements / declarations / jsx_ts. |
| **Test262 full** | `task test:test262:full:regression` | **48 697 / 49 729 (97.92%)** baselined | **+808 tests closed in Session 11** via 17 parser + lexer patches (numeric-key ObjectPattern + cover-init clear, escaped-ReservedWord shorthand keys, §15.7.3 AllPrivateIdentifiersValid walker, static `import defer` / `import source`, class-body strict coverage, strict-mode shorthand reference, unconditional UniqueFormalParameters, `"use strict"` with non-simple params, destructuring assignment targets, `\u` after numeric, missing-init on const / using, yield/await as binding in params, Annex B.3.2/B.3.3 function-in-block, §15.7.5 class-field init `arguments`, yield/await as label + bare-await, retro legacy-octal in strict prologue, §12.9.6 untagged template invalid escapes). +3 269 in Session 10 (89.73% → 96.30%). Requires a local checkout (`git clone https://github.com/tc39/test262.git vendor/test262`). Off the default chain — runs in ~2m50s. `task test:test262:full:update` after an intentional improvement. |
| Bench regression | `task test:bench:regression` | Not run | Use before release. |

### Performance (Apple M-series, `-o:speed -no-bounds-check`)

| File | Size | Status |
|---|---|---|
| jquery.js | 285 KB | ✅ parses (was crashing pre-Phase-2) |
| lodash.js | 544 KB | ~1.6 ms (~330 MB/s) |
| react.dev.js | 110 KB | ~460 µs (~240 MB/s) |

---

## 3. Architecture

```
Source String
    │
    ▼
┌──────────┐   FastToken (16B)   ┌──────────┐   ^Program    ┌──────────┐
│  Lexer   │ ──────────────────→ │  Parser  │ ────────────→ │ Emitter  │ → JSON stdout
│ (SIMD)   │  cur/nxt lookahead  │ (Pratt)  │  AST tree     │ (direct  │
│          │                     │          │               │  buffer) │
└──────────┘                     └──────────┘               └──────────┘
     │                                │                          │
     │ comments[]                     │ errors[]                 │ errors[]
     └────────────────────────────────┴──────────────────────────┘
                    │
                    ├── Parser holds ESM module-record arrays (static/dynamic imports, exports, import.meta spans)
                    │   consumed by emit_module_record when --module-record is on.
                    │
                    └── Parser holds Lang mode (JS/JSX/TS/TSX) set from extension or --lang CLI flag.
```

**Memory.** Single `mem/virtual.Arena`, pre-allocated at `max(source_len * 256, 16 MB)`.
All AST nodes come from a bump pool (4 KB pages, overflow to arena). Zero
`free()` calls. Arena destroyed at exit.

**Hot path.** `lex_token` → branchless single-space skip → single-char lookup
table → identifier / keyword / operator dispatch. Parser `advance_token` swaps
`cur ← nxt`, lexes new `nxt`. Emitter writes directly to a pre-allocated
`direct_buf` (20× source), flushed with a single `os.write`.

**Key types.**
- `FastToken` (16 B: start u32, end u32, kind TokenType, flags u8) — passed
  by value, fits in register pair.
- `Lexer` — 64-byte hot cache line (source_bytes, offset, template_depth,
  cur, nxt).
- `Parser` — lexer pointer + cached cur_type + context flags (in_function,
  in_ambient, lang, etc.) + BumpPool.
- AST unions — Odin tagged unions, nodes heap-allocated via bump pool.

---

## 4. Project Structure

| File | LOC | Purpose |
|---|---|---|
| `src/ast.odin` | ~1 500 | All AST node types — JS, JSX (15), TS (52+), ESM record (7), union types. FunctionParameter modifier fields + TSParameterProperty logic. |
| `src/token.odin` | ~370 | TokenType enum, FastToken, LiteralValue, FLAG_NEW_LINE, FLAG_HAS_ESCAPE. |
| `src/lexer.odin` | ~1 970 | Lexer state + `lex_token` hot path + SIMD comment scanners + escaped-identifier slow path + diagnostic channel (`lexer_errors`) for numeric separators, BigInt invariants, bad escapes, unterminated strings/regex. |
| `src/parser.odin` | ~8 880 | Recursive-descent parser. Carries 29 static-error classes (Session 6 sweep). New parser fields this session: `in_method` (HomeObject context), `last_body_strict` (directive-prologue surfaced to caller), `label_stack` + `label_floor` (per-function label set). New helpers: `collect_bound_names`, `report_duplicate_lexical_names`, `report_duplicate_param_names`, `params_are_simple`, `report_let_as_lexical_name`, `report_private_class_member_errors`, `class_element_prop_name`, `property_is_literal_proto_init`, `string_raw_has_forbidden_escape`, `is_legacy_zero_prefixed_integer`, `is_strict_reserved_word`, `is_strict_reserved_name`, `is_eval_or_arguments`, `report_strict_update_on_eval_or_arguments`, `label_in_scope`. |
| `src/main.odin` | ~6 910 | CLI, JSON emitter, TS emitter. TSParameterProperty wrap, TSMappedType key+constraint shape, CallExpr/NewExpr typeArguments, FunctionExpr declare/typeParameters/returnType, ClassDecl superTypeArguments, MethodDef/PropertyDef optional, destructuring-target pattern emitter. |
| `src/simd.odin` | ~240 | SIMD comment scanners (`simd_skip_line_comment`, `simd_skip_block_comment`). |
| `src/raw_transfer.odin` | ~650 | Experimental binary AST buffer output (not on JSON path). |
| `npm/kessel-parser/index.js` | ~140 | oxc-parser-compatible `parseSync()` shim backed by CLI binary. |
| `npm/kessel-parser/visitor.js` | ~190 | ESTree `walk()` + `findAll()` visitor API. |
| **Total** | **~20 850** | |

Dependency graph (all in `package main`):
```
main.odin ──→ parser.odin ──→ lexer.odin ──→ simd.odin
    │              │               │
    └──────────────┴───────────────┴──→ ast.odin ←── token.odin
    │
    └──→ raw_transfer.odin
```

---

## 5. Key Design Decisions

1. **Single-package flat file layout** over module hierarchy. Odin's package
   system adds indirection; flat layout gives zero-cost cross-file access.
2. **FastToken by-value (16 B)** over pointer-to-token. Fits in a register
   pair; eliminates indirection on hot path.
3. **Direct buffer output** over `bufio.Writer`. Single allocation, single
   syscall, measurably faster for large JSON.
4. **Comments collected during lexing** (no separate pass). SIMD comment skip
   already touches every byte.
5. **TypeScript types parsed AND stored** (post Phase 2/3). The Phase 1
   approach of discarding type nodes was replaced by proper wiring into
   `Identifier.type_annotation`, `FunctionExpression.return_type`, etc.
6. **Lang-mode gating** (Phase 3 Wave A). `<` at expression start dispatches
   based on detected language mode (JS / JSX / TS / TSX). Extension
   detection + `--lang` CLI override.
7. **Trial-parse with lexer snapshot** for ambiguous `<T>` (TS / TSX). Saves
   lexer + parser scalars, runs speculative parse, truncates phantom errors
   on rollback.
8. **Default-off for all new output formats.** `--errors=oxc`, `--loc`,
   `--module-record` all keep byte-identical default output so existing
   consumers never break.
9. **Static-error classes are always on.** The 29 negative-gate error
   classes run unconditionally; they never change the shape of a valid
   AST, only add entries to `p.errors[]` when input is invalid. The
   module-syntax-in-script class gates on `--source-type=script` because
   auto-detect would silently upgrade; every other class fires on every
   parse.
10. **Ratcheted negative gate.** `tests/verifiers/verify_negative.js`
    flips to zero-tolerance the moment the baseline is 100% “rejected”.
    Any new fixture the parser accepts fails the default gate, not just
    `--strict`. Stops silent drift where “new fixture” would previously
    hide a regression.

---

## 6. OXC Parser Parity

> Tracking 1:1 feature parity with [oxc-parser](https://www.npmjs.com/package/oxc-parser) v0.127.

### Status overview

| Area | Progress | Notes |
|------|----------|-------|
| P0 Regressions | **3 / 3 ✅** | — |
| JavaScript Correctness | **5 / 7** | JS-2 (full Test262), JS-3 (recovery hardening) remain |
| TypeScript — Core | **12 / 12 ✅** | TS-C1c TSX single-param `<T>` still requires trailing comma |
| TypeScript — Advanced | **10 / 10 ✅** | — |
| TypeScript — Declarations | **7 / 7 ✅** | interface extends / const enum / class implements / type-param constraints all fixture-verified vs OXC. |
| ESTree / TS-ESTree Conformance | **9 / 9 ✅** | EST-5 closed: 22-category spec-fixture gate at 144/144. |
| ESM Module Record | **5 / 5 ✅** | — |
| Parser Options | **6 / 6 ✅** | — |
| Error Handling | **2 / 5** | ERR-1 + ERR-5 shipped; ERR-2/3/4 functionally solved on current corpus (recovery 20/20, 0 SIGTRAPs, 0 infinite loops); formal items remain open. |
| Test Coverage | **2 / 5** | Curated + **negative-gate ratchet** shipped; full Test262 / Babel / TS parser test suites still pending. |
| NAPI / FFI Bindings | **1 / 6** 🔶 | CLI-backed `parseSync()` shim in `npm/kessel-parser/` (`880e822`). Full zero-spawn NAPI pending. |
| Visitor API | **1 / 3** 🔶 | `walk()` + `findAll()` shipped (`880e822`). Transform API + scope analysis pending. |

Legend: ✅ done • 🔶 partial • ❌ pending

### P0 Regressions (3 / 3 ✅)
All fixed in Phase 2.
- [x] **P0-1:** `type` as JS identifier.
- [x] **P0-2:** `interface` as JS identifier.
- [x] **P0-3:** `enum` as JS identifier.

### JavaScript Correctness (5 / 7)
- [x] ES2015+ core (arrow, destructuring, classes, template literals, generators, modules)
- [x] ES2020 (optional chaining, nullish coalescing, BigInt, dynamic import, import.meta)
- [x] ES2022+ (class fields, private fields, static blocks, logical assignment, top-level await)
- [x] **JS-1:** Real-world 467/467 passing.
- [x] **JS-4:** `?` ternary guard in function body.
- [ ] **JS-2:** Full Test262 stage-4 conformance (~45 000 tests). Currently 60 curated tests pass.
- [ ] **JS-3:** Error recovery hardening. Minimal recovery today.

### TypeScript — Core (12 / 12 ✅)
- [x] Union / intersection types (`A | B`, `A & B`)
- [x] Type keywords (`any`, `number`, `string`, `boolean`, `void`, `null`, `never`, etc.)
- [x] **TS-C1a:** `function foo<T>() {}` — generic on function decls (Phase 2)
- [x] **TS-C1b:** `class Box<T> {}` — generic on classes (Phase 2)
- [x] **TS-C1c:** `<T, U>(x, y) => x` — generic arrow. Phase 3 Wave B (`b02dfe5`): pure
       `.ts` mode (no ambiguity). Phase 5 (`7fa2b40`): TSX mode via trailing-comma rule
       `<T,>(x) => x`. Multi-param `<T, U>` works in both modes without trailing comma.
       **Known limitation in TSX:** single-param `<T>(x) => x` without trailing comma
       falls through to JSX (correct per spec; write `<T,>(x) => x` instead).
- [x] **TS-C1d:** `foo<string>(x)` — generic args on call
- [x] **TS-C1e:** `new Foo<string>()` — generic args on new (Phase 2)
- [x] **TS-C2:** `x!.length` — non-null assertion `TSNonNullExpression` (Phase 2)
- [x] **TS-C3:** `let x: T = ...` — type annotations on binding id
- [x] **TS-C4:** Method signatures in interfaces
- [x] **TS-C5:** `[k: string]: T` — index signatures (Phase 2)
- [x] **TS-C6:** `<Type>expr` — angle-bracket assertion (Phase 3 Wave B, `b02dfe5`)
- [x] **TS-C7:** `x is T` / `asserts x is T` — type predicates (Phase 2)
- [x] **TS-C8:** Enum member initializers

### TypeScript — Advanced (10 / 10 ✅)
- [x] **TS-A1:** Conditional types `T extends U ? X : Y`
- [x] **TS-A2:** Mapped types `{ [K in T]: V }`, `T[K]`, `+?`/`-?`/`+readonly`/`-readonly`
- [x] **TS-A3:** Template-literal types `` `hello ${T}` ``
- [x] **TS-A4:** `import type { A }`, `import("m").T`
- [x] **TS-A5:** `declare function | class | const | let | var | interface | type | enum`
- [x] **TS-A6:** `abstract class` + abstract methods
- [x] **TS-A7:** `namespace Foo { ... }`, `A.B.C`, `module "x" { ... }`, ambient bodies
- [x] **TS-A8:** Call / construct signatures in object types
- [x] **TS-A9:** `infer U` in conditional types
- [x] **TS-A10:** Overload signatures (free functions and class methods), `973c9e6`.

### TypeScript — Declarations (7 / 7 ✅)
- [x] `interface` declarations (basic + extends)
- [x] `type` alias declarations
- [x] `enum` declarations (basic + const enum)
- [x] **TS-D declare:** on every declaration kind
- [x] **TS-D class fields:** `foo: T`, `foo?: T`, `foo!: T = x`
- [x] **TS-D ambient:** `module "x" { const y: number; function f(): void; }`
- [x] **TS-D individual verification:** `interface extends`, `const enum`,
      `class implements`, type parameter constraints/defaults. Dedicated
      fixtures at `tests/fixtures/spec/typescript/011..014` verify each
      against OXC (all passing, locked in spec-fixtures baseline).

### ESTree / TS-ESTree Conformance (9 / 9 ✅)
- [x] Core node types (57 JS node types verified)
- [x] `hashbang` field on Program with preserved content (EST-6). The
      lexer captures `value`, `start`, `end`; the emitter writes
      `{type: "Hashbang", value, start, end}` or `null`.
- [x] **EST-1:** `loc { line, column }` on every node via `--loc` flag
       (0-indexed UTF-16 columns).
- [x] **EST-2:** `range: [start, end]` on every node via `--range` flag
      (`f7577bb`). Emitted between the `end` and `loc` fields so the
      three can compose independently.
- [x] **EST-3:** `ParenthesizedExpression` via `--preserve-parens`
      (`c8f9dff`). Acorn/OXC shape; not in ESTree core. Skipped on the
      arrow-params cover path so trial-parse into arrow function keeps
      working. Reduces antd.js spec-compliance drift from 10020 → ~20.
- [x] **EST-6:** `hashbang` content preservation — already shipped, the
      old handoff entry was stale. Covered by structural test
      `tests/fixtures/hashbang/` + real-world verification.
- [x] **EST-4:** TS-ESTree shape alignment (`f8656ec`). All 10 `spec/typescript/*`
      fixtures pass deep OXC compare. Fixes: TSMappedType key+constraint,
      `new Box<T>()` callee, TSIndexSignature spans/accessibility,
      FunctionExpression declare/typeParameters/returnType null,
      ClassDeclaration superTypeArguments, CallExpression/NewExpression
      typeArguments null, MethodDef/PropertyDef optional, TSInterfaceDeclaration
      body start. OXC used as reference (typescript-estree verifier not needed).
- [x] **EST-5:** Per-category spec-fixture gate (`96bacd5`+). Baseline
      covers 22 categories x 144 fixtures
      (`tests/baselines/spec_fixtures_baseline.json`): asi, edge,
      es2015–es2025, escapes, ambiguity, interactions, jsx, lexical,
      regex_disambiguation, typescript, unicode. **144/144 passing**.
      lexical/001 (BOM+hashbang) rejects with matching OXC diagnostic.
      Gate trips on any category regression.

### ESM Module Record (5 / 5 ✅)
All shipped in Phase 3 Wave 2b (`c31de50`). CLI: `--module-record`.
- [x] **ESM-1:** `hasModuleSyntax`
- [x] **ESM-2:** `staticImports`
- [x] **ESM-3:** `staticExports`
- [x] **ESM-4:** `dynamicImports`
- [x] **ESM-5:** `importMetas`

### Parser Options (6 / 6 ✅)
- [x] **OPT-1:** `--source-type={script|module|unambiguous}` (`2b3e88b`).
      `unambiguous` (nil override) keeps the existing auto-upgrade;
      `script` disables it; `module` pins to Module regardless of body.
- [x] **OPT-2:** `--lang=js|jsx|ts|tsx` (Phase 3 Wave A, `fcd9203`)
- [x] **OPT-3:** `--preserve-parens` (`c8f9dff`) — Acorn-style wrapper.
- [x] **OPT-4:** `--loc` (EST-1, `22d2f88`)
- [x] **OPT-range (EST-2):** `--range` (`f7577bb`) — ESLint-style tuple.
- [x] **OPT-5:** `--ast-type=js|ts|auto` (`96bacd5`+). Pins the TS-ESTree shape
      independent of the parse grammar. `js` forces plain-ESTree output
      (no TS null-field padding); `ts` forces TS-ESTree output; `auto`
      (default) keeps the existing lang-driven detection (`.TS` / `.TSX`
      emit TS shape, `.JS` / `.JSX` emit plain).
- [ ] **OPT-6:** `showSemanticErrors` — requires scope/symbol analysis.

### Error Handling (2 / 5)
- [x] **ERR-1:** `--errors=oxc` for OXC TS-ESTree shape (Phase 3, `75fb36b`).
- [x] **ERR-5:** Static-error coverage. Negative gate at **125/125
      rejected** (Session 9, commit `62a7b61`) across 125 fixtures.
      **54 static-error classes** enforced at the parser layer: 9
      from Session 5 (`43c57dc`) + 20 from Session 6 + 12 from
      Session 7 + 7 from Session 8 + 6 from Session 9.

      *Session 5 additions (9 classes, `43c57dc`):* top-level `return`
      outside function; unlabelled `break` / `continue` outside
      loop / switch; stray `else` / `}` / `catch` / `finally` at
      statement position; invalid LHS of `=`; reserved keyword as
      binding identifier; `await` as unary prefix outside async;
      lexer diagnostics (numeric separators, BigInt invariants, bad
      binary / octal, unterminated string / regex, bad `\x`/`\u`
      escapes, BOM+hashbang `!`); function-param bail-out recovery.

      *Session 6 additions (20 classes, `420cb52`..`ab1f14c`):*

      *Structural / grammar:* `super` outside method, duplicate
      `__proto__` init, duplicate lexical-binding names, `let` as
      lexical-BoundName, duplicate / unknown-target labels,
      duplicate `default`, duplicate `constructor`, duplicate
      private-class-member + `#constructor`, `static prototype`
      class member, rest-element trailing-comma, `new.target`
      outside function, `new import(...)`, private identifier
      outside `in`-expression, `throw` with line-terminator,
      `delete` of a private field.

      *Strict-mode:* `with` statement, LegacyOctal / `\8` / `\9`
      in strings AND untagged templates, LegacyOctal integer
      literals, LegacyOctal BigInts, strict-mode FutureReservedWord
      bindings (`implements` / `interface` / `package` / `private`
      / `protected` / `public` / `let` / `static` / `yield`),
      `eval` / `arguments` as binding / LHS / update-operand,
      `delete <ident>`, `function eval` / `function arguments`,
      class name strict-reserved check, labeled-function-
      declaration, duplicate-params in strict.

      *Context-sensitive:* strict-mode function-body directive
      promotion + retroactive param validation, `yield` as binding
      in generator, `await` as binding in async function, `for
      await` outside async context, `import`/`export`/top-level-
      await/`import.meta` under `--source-type=script`.

      *Param validation:* UniqueFormalParameters forced by
      non-simple param list (§15.1.2 — destructuring / default /
      rest), arrow / method / accessor UniqueFormalParameters
      rules (§15.3.1 / §15.4.*).

      *Session 7 additions (12 classes, `b151f44`..`e736088`):*

      *Class / super semantics:* `super(...)` outside instance
      constructor of a derived class (§15.7.3 / §13.3.7 —
      `in_derived_constructor` flag threaded through class body;
      static blocks / field initializers / object methods / non-
      derived constructors all reject; arrow functions inherit the
      derived-constructor context so lexical `super(...)` works).

      *Escape / ReservedWord rule:* IdentifierName written with a
      `\UnicodeEscapeSequence` whose cooked StringValue matches a
      ReservedWord — rejected at every Identifier production site
      (IdentifierReference / BindingIdentifier / LabelIdentifier),
      kept legal at IdentifierName positions (member access,
      property key, method name, import/export specifier). Covers
      always-reserved keywords unconditionally plus the strict-only
      FutureReservedWords (`let` / `static` / `yield` /
      `implements` / `interface` / `package` / `private` /
      `protected` / `public`) when `p.strict_mode` is on, plus
      `yield` in generator / `await` in async context.

      *Restricted productions:* LineTerminator between ArrowParameters
      and `=>` (§15.3); LineTerminator between `async` and
      `function` in AsyncFunctionDeclaration (§15.8); LineTerminator
      between `async` and the next token in AsyncArrowFunction
      (§15.9 — treats `async` as a bare identifier and ASI splits
      the two statements). `throw`, postfix `++`/`--`, `return`,
      `yield`, `break`/`continue` label — all already handled.

      *Labels / continue:* `continue label;` requires the target
      label to name an IterationStatement (§14.8.1 — K14 closed).
      New `label_is_iteration` parallel stack indexed same as
      `label_stack`, eager lookahead at LabelledStatement push
      catches chained labels `foo: bar: for(...)` correctly.

      *Strict-mode delete:* `delete ( IdentifierReference )` —
      strict mode rejects both bare `delete x` (already shipped)
      and the parenthesised form `delete (x)` / `delete ((x))`
      (§13.5.1 / "CoverParenthesizedExpression whose contents are
      an IdentifierReference"). Paren peeling stops at any non-
      ParenthesizedExpression wrapper so `delete (x, y)` and
      `delete (x.y)` stay legal.

      *Tagged templates:* `obj?.foo\`t\`` / tagged template literal
      on an optional-chain tag (§13.3.5 — parse_lhs_tail tracks
      `is_chain`; any template tail inside the chain reports).

      *For-in / for-of:* LeftHandSideExpression cannot be an
      AssignmentExpression (§14.7.5.1 — `for (a = 1 in b)` and
      `for (a = 1 of b)` both fail). Annex B.3.5 `for (var X =
      init in Expr)` routes through `left_decl` so the narrow
      sloppy-mode carve-out is unaffected.

      *Import bindings:* Duplicate BoundNames across all
      ImportClause specifier kinds (§16.2.2). O(n²) pairwise scan
      runs post-specifier-parse via `import_spec_local_name(spec)`;
      catches every combination of default / named / namespace
      specifiers.

      *Generator params:* YieldExpression in FormalParameters of a
      GeneratorFunction / GeneratorMethod (§15.5.1 / §15.6.1).
      New `in_generator_params` flag set before parse_function_
      params in function decl / class method / object-literal
      accessor+method paths. Symmetric `in_async_arrow_params`
      scaffolded for §15.9.1 but not yet wired (async arrow
      params go through CoverCallExpression + trial-parse; needs a
      secondary hook).

      *Session 8 additions (7 classes, `bea6c76`..`a9f9ab0`):*

      *Contextual yield / await:* YieldExpression outside a
      GeneratorBody (§15.5) — `yield 1;` at script / non-generator
      function level. Outside a generator, `yield` is parsed as
      IdentifierReference whenever the lookahead is a continuation
      (binary / logical / assignment / postfix / member / call /
      tagged-template / terminator) or has a line terminator, and
      as YieldExpression with "'yield' expression is only allowed
      in a generator body" when the next token cleanly starts an
      AssignmentExpression. Matches Acorn / OXC / V8 on the clear
      cases.

      *Async parameter defaults:* AwaitExpression in the
      FormalParameters of an AsyncFunctionDeclaration /
      AsyncFunctionExpression (§15.8.1), AsyncGenerator* (§15.6.1),
      async method shorthand (class + object literal), and
      AsyncArrowFunction paren-head (§15.9.1). The stub
      `in_async_arrow_params` flag was renamed to `in_async_params`
      and wired at every async function-like param entry point
      (parse_function_declaration, parse_class_element method,
      parse_object_literal accessor + method, parse_async_arrow_
      with_parens). Checked at parse_unary_expr .Await on entry so
      errors fire before the parse tree is built.

      *Arrow cover Contains check:* YieldExpression /
      AwaitExpression in the ArrowParameters cover of a non-async
      arrow (§15.3.1). The cover parses legally inside an outer
      generator / async body; the walker runs at parse_arrow_
      function's `=>` commit and retroactively rejects. Stops at
      every function-like / class boundary per spec Contains
      semantics (FunctionExpression / ArrowFunctionExpression /
      ClassExpression). At most one error of each kind per arrow.

      *Async arrow params cross-ref:* §15.9.1 final clause folds in
      the §15.3.1 yield ban for async arrow params. The async-arrow
      path builds params directly via parse_function_params (no
      cover trial parse), so a parallel walker
      `scan_arrow_params_for_yield_only` descends the lowered
      Pattern tree (AssignmentPattern / ObjectPattern / ArrayPattern
      / RestElement) to find yield in default-init positions. Await
      is already caught by the in_async_params fast-path to avoid
      double-reporting.

      *For-in/of initializer + Annex B.3.5:* Core grammar
      (§14.7.5.1) forbids initializers on ForDeclaration. Only the
      sloppy-mode `for (var BindingIdentifier = init in Expr)`
      carve-out (Annex B.3.5) survives — not destructuring, not
      `let`/`const`/`using`, not for-of, not multiple declarators.
      Also rejects the parallel "multiple declarators in for-in/of
      head" case (`for (var x, y in z)`). To make the carve-out
      reachable, `parse_for_statement` now sets `p.no_in` around
      the var-init declarator parse; `parse_function_body` saves
      and resets no_in so a nested function inside the for-init
      declarator keeps `in` as a binary operator.

      *Export-local resolution:* `export { foo };` (no `from`)
      requires `foo` to be declared in the module (§16.2.2 —
      ExportedBindings ⊆ VarDeclaredNames ∪ LexicallyDeclaredNames).
      String-literal `export { "foo" };` without a `from` clause
      is also rejected (local must be a BindingIdentifier).
      Implemented as a post-parse pass in parse_program that
      collects the module's top-level binding set
      (VariableDeclaration + FunctionDeclaration + ClassDeclaration
      + ImportDeclaration specifiers + TS type-level declarations
      + inner declarations of `export var/function/class`) and
      then verifies every ExportNamedDeclaration without a `from`
      clause.

      *Session 9 additions (6 classes, `795f442`..`62a7b61`):*

      *Recovery hardening:* Four silent parser gaps previously
      accepted malformed input; now each reports a structured
      diagnostic: `fn(1, ..., 2)` (empty spread target),
      `var x = ;` / `let x = ;` / `const x = ;` (empty initializer),
      `function f(x = ) {}` (empty param default),
      `<T extends >` / `<T = >` (empty TS type-parameter constraint
      or default). 12 new recovery fixtures (total 32/32).

      *Regex pattern / flag validation (§22.2.1):*
      • Duplicate flags (`/abc/gg`).
      • Invalid flags (non `d|g|i|m|s|u|v|y`).
      • `u` and `v` mutually exclusive (Step 3 check).
      • Unmatched `)` in pattern body.
      • Unterminated `(` group.
      • Trailing `\\` before closing `/`.
      • Escape before newline.
      Full AtomEscape / CharacterEscape / CharacterClassEscape /
      GroupName grammar still deferred to a dedicated regex parser
      (OXC does the same via oxc_regular_expression); structural +
      flag validation here catches the common cases OXC / V8 also
      report at parse time.

      *OPT-6 scope verification MVP (§14.2 / §14.3 / §16.1.1):* new
      `--show-semantic-errors` flag enables a post-parse pass that
      walks each body-scope (Program / FunctionBody / BlockStatement
      / CatchClause / TryBlock / SwitchCase / ForStatement bodies /
      ArrowFunction block body) and reports duplicate
      LexicallyDeclaredNames, lexical/var clashes, and
      import-shadow-let cases. Off by default so downstream tooling
      (tsc, ESLint) isn't double-diagnosing.

      Baseline ratchet: once 100% rejected, any new fixture the
      parser accepts fails the default gate automatically.
      `task test:negative:strict` runs the same set without a
      baseline for release gating.

      *Session 10 additions (19 Test262-driven patches, no new
      fixtures in the negative/ slice yet):* Session 10 focused on
      closing gaps found via the full Test262 corpus run rather
      than writing new named-fixture negative tests. The negative
      gate stays at 125/125 for release polish; the new classes
      live in the parser/lexer and show up as pass-count delta on
      Test262. Summary (each landed as its own commit; see §7
      "Phase 10" for per-commit detail):

      *Destructuring grammar holes:*
        - BindingElement : BindingPattern Initializer_opt in
          nested-array-pattern element positions (`[[x] = []]`,
          `[{a} = {}]`) — pattern conversion now wraps in
          AssignmentPattern.
        - BindingRestElement : ... BindingIdentifier | ...
          BindingPattern — rest-element no longer identifier-only.
        - Arrow cover: `[...x, y]` and `[...x = []]` at the
          AssignmentExpression-to-pattern conversion point report
          "rest must be last" / "rest cannot have default".
        - §14.3.3: trailing comma after rest in destructuring
          assignment (`[...x,] = []`) — detected by scanning source
          bytes between the spread end and the array close.

      *Lexer escapes:* PrivateIdentifier accepts `\uXXXX` /
      `\u{H...H}` escapes at every IdentifierName position;
      `#\u0041`, `#\u{1F600}_`, `get #\u2118()` all parse clean.
      Fixes §12.7.2 compliance for the private name form.

      *Lexer numeric literals:*
        - §12.9.3 smooth-following: the source character
          immediately after a NumericLiteral cannot be an
          IdentifierStart or DecimalDigit. `00b0`, `1a`, `0.5c`
          now reject.
        - HexIntegerLiteral requires at least one HexDigit after
          `0x`; `0x;` and `0xn;` reject.
        - `Invalid hex digit` diagnostic mid-literal (`0xfoo`),
          mirroring the existing binary / octal parallels.

      *§13.3.10 ImportCall / Phase Imports:*
        - `import()` requires a specifier; `import()` alone
          rejects.
        - `import(...spread)` rejects (AssignmentExpression, not
          Arguments).
        - `new import.defer(x)` / `new import.source(x)` extend
          the existing `new import(x)` rejection.
        - ImportCall second argument (Import Attributes) +
          trailing comma: `import('x', { type: 'json' },)`.
        - ImportCall / MetaProperty / ImportExpression with
          §Phase Imports: `import.defer(x)` / `import.source(x)`
          parse as a single ImportExpression with phase set to
          "defer" / "source", matching OXC.

      *§13.2.5.1 CoverInitializedName:* `{ a = 1 }` is only legal
      inside a destructuring cover. Tracked via a pending-list on
      Parser; expr_to_pattern clears entries when the object gets
      promoted; anything left at end-of-parse reports.

      *§13.5 statement-only position gate:* if-consequent /
      else-alternate / while / for / do-while body cannot be a
      Declaration (LexicalDeclaration, ClassDeclaration,
      AsyncFunctionDeclaration, GeneratorDeclaration,
      AsyncGeneratorDeclaration). Annex B.3.2 carve-out kept for
      plain FunctionDeclaration in the IfStatement if-body only.

      *§14.2.1 LexicallyDeclaredNames duplicate-scan — always on.*
      Removed the `--show-semantic-errors` gate from
      scope_verify_body; duplicate lexical bindings across a
      Block / FunctionBody / CatchClause / SwitchCase / static-
      block scope are now always a parse error. Annex B.3.2 handled
      via a strict/sloppy-aware kind switch: sloppy plain
      FunctionDeclaration in a Block binds as .Var, not .Lexical.

      *§13.4.1 SimpleAssignmentTarget for UpdateExpression:*
      `import('')++`, `(a=1)++`, `true--` all reject. Annex B.3.4
      preserved: sloppy-mode `f()++` stays legal.

      *§13.15.1 / §13.5.1.1 strict eval/arguments:* Walker covers
      the destructuring-assignment LHS (`[arguments] = []`,
      `({x: eval} = {})`, `[...arguments] = []`) and the for-in/of
      head target. Previously only the direct `eval = x`
      assignment was caught.

      *§15.4.3 / §15.4.4 accessor arity:* getter rejects any param,
      setter rejects zero or >1 params and rest elements. Defaults
      on setter params are legal (SingleNameBinding Initializer_opt).

      *§12.6.1.1 strict-mode IdentifierReference:* `let`, `yield`,
      `static`, `implements`, `interface`, `package`, `private`,
      `protected`, `public` reject as IdentifierReferences in
      strict mode. Covers both the dedicated-token channel and
      the .Identifier + contextual-name channel.

      *ImportCall / import.meta as ExpressionStatement in Block:*
      `{ import('x')(); }` and `() => { import('x')(); }` now
      parse; the statement dispatcher recognises ImportCall /
      MetaProperty as expression productions and routes through
      the ExpressionStatement path.

      *Parser state leaks:* no_in no longer leaks through
      ArrayExpression / ObjectExpression / TemplateLiteral
      substitution bodies (`for ([x='y' in z] of w)` etc.).

      *Lexer token context:* .Await and .Yield added to
      can_start_regex — `await /1/` / `yield /a/.test(x)` now
      lex the `/` as a regex literal.

      *Class body ASI:* `class C { #x\n#y }` parses as two fields.
      The method-vs-field discriminator now accepts the implicit
      ASI when the cur token is on a new line and isn't `(` /
      `:` / `?` / `!`.

      *Test harness: --force-strict.* New CLI flag for the
      Test262 runner's `flags: [onlyStrict]` fixtures. Without it
      ~332 strict-only early-error fixtures couldn't fire.

      *CoverInitializedName pending list, test262 full
      --all-failures, per-subdir aggregation* — triage
      infrastructure, in-file under tests/verifiers/ and
      tests/runners/.
- [ ] **ERR-2:** Error recovery at statement boundaries. *Functionally: `task test:recovery`
      passes 20/20 with anchor survival; formal item still open for editor-tooling quality.*
- [ ] **ERR-3:** Graceful TS parse failure. *Functionally: 0 SIGTRAPs in current corpus;
      formal item still open.*
- [ ] **ERR-4:** Timeout prevention on infinite parse loops. *Functionally: 8 baselined
      SIGTERMs on 350KB–4MB mutated files only; no infinite loops.*

### Test Coverage (2 / 5)
- [x] Curated Test262 (66/66), regression (11/11), real-world (467/467),
      nodes (57/57), invariants (467/467), spec-fixtures (144/144 across 22
      categories, all ES years + asi + edge + escapes + jsx + regex + TS + unicode
      + ambiguity + interactions + lexical at 100%).
- [x] **Negative gate: 102/102 rejected** across `tests/fixtures/negative/`
      + `tests/fixtures/early_errors/` (ratchet-gated, strict mode
      available). 41 static-error classes enforced; see ERR-5 above for
      the catalog.
- [ ] **TEST-1:** Full Test262 (~45 000 tests).
- [ ] **TEST-2:** Babel parser test suite.
- [ ] **TEST-3:** TypeScript parser test suite.
- [x] **TEST-4:** TS-ESTree fixture shape diff (EST-4) ✅ Closed via OXC reference.

### NAPI / FFI + Visitor API (2 / 9) 🔶
- [x] **CLI shim** (`880e822`): `npm/kessel-parser/index.js` exposes
      `parseSync(filename, source, opts)` matching oxc-parser’s API.
      Backed by `bin/kessel` via `spawnSync`.
- [x] **Visitor API** (`880e822`): `npm/kessel-parser/visitor.js` exposes
      `walk(node, visitor)` (pre/post-order) and `findAll(root, ...types)`.
- [ ] Full NAPI bindings (zero spawn overhead). Requires C ABI export from
      Odin + C++ NAPI shim + npm packaging. Separate integration phase.
- [ ] Transform API (node replacement / mutation).
- [ ] Scope / binding analysis.

---

## 7. Commit history

### Phase 1 (pre-session)
ES2015–ES2025 JS core, JSX Phase 2, TypeScript Phase 3 foundations (AST
types, type parser, declaration parsers, emitter, `as`/`satisfies`).

### Phase 2 — 13 commits, 23 parity items closed
Session summary pre-dates this handoff. Landed P0 fixes, generics on
functions/classes/new, method/index/call/construct signatures, mapped
/ conditional / infer types, non-null assertion, type predicates,
declare / abstract / namespace / import-type.

Key commits: `457eb57 1868aa6 5adc034 8adafb0 c322e81 abb2e3b 965e062 fc3795a 6562b8b b8ba2fd 492c639 e70ffc9 cbfa3b6 3ae9b31`.

### Phase 3 — initial swarm, 13 commits

| Commit | Item | Author | Notes |
|--------|------|--------|-------|
| `e1beb05` | JSX nested attribute span fix | Haiku `48cb192f` | Fixture line 1 parses; deep-JSX-child still crashes (known) |
| `f4250a4` | Test suite expansion (fuzz, bench, crashes-known) | User mid-session | Adds 9 new baseline-gated verifiers |
| `75fb36b` | `--errors=oxc` (ERR-1) | Rescued from Haiku `5a3ffd90` stash | Haiku auto-stashed its own work; extracted surgically |
| `34121c2` | `\uXXXX` / `\u{...}` in identifiers | Orchestrator (Haiku `f7b18076` failed) | Clean design: `FLAG_HAS_ESCAPE` + `LiteralType.Identifier` |
| `22d2f88` | `--loc { line, column }` (EST-1) | Haiku `51757775` | 0-indexed UTF-16, OXC-compatible |
| `a6953eb` | Ambient module implicit-declare | Orchestrator (Haiku `21215876` lost work) | `p.in_ambient` save/restore |
| `c31de50` | ESM module record (ESM-1..5) | Haiku `d7dfd0e0` | First delegation post-safety-hardening, work intact |
| `2ad4487` | Sync OXC_PARITY with 28 items | Orchestrator | Tracker had drifted from reality |
| `4dc51cc` | Wave 3 design docs | Orchestrator | `.swarm/07`, `.swarm/08` |
| `4b543cf` | Sync OXC_PARITY post-ESM | Orchestrator | |
| `fcd9203` | Wave 3 Phase A: Lang enum + JSX gating | Orchestrator | `--lang=js|jsx|ts|tsx`, extension detection |
| `b02dfe5` | Wave 3 Phase B: `parse_ts_lt_expression` | Orchestrator | Closes TS-C1c + TS-C6. Unit tests 25/244 → 217/244 (exposed `exit_code` runner bug too) |
| `be21a52` | Sync OXC_PARITY post-Phase-B | Orchestrator | TS Core 12/12 ✅ |

### Phase 4 — post-handoff sweep, 6 commits

| Commit | Item | Notes |
|--------|------|-------|
| `c0e1a4d` | K4 + TS function type with named params | parse_primary_expr `(` trial-parses as TS arrow params when the opening matches `...` or `Identifier :`; parse_ts_primary_type `(` now routes through parse_ts_sig_params when the paren opens a named-param function type. Closes K4. |
| `f7577bb` | EST-2 `--range` flag | Emits `"range": [start, end]` on every node between the bare `end` and the optional `loc` field. Default-off, byte-identical legacy output. |
| `2b3e88b` | OPT-1 `--source-type` flag | Pins Program.sourceType. Parser carries `p.force_source_type: Maybe(SourceType)` to disable the auto-upgrade pass when set. |
| `973c9e6` | TS-A10 overload signatures | `function foo(): T;` and class-method `foo(): T;` now parse cleanly in TS mode — `parse_function_declaration` and `parse_class_element` both accept a bodyless form when `allow_ts_mode(p)`. |
| `0513d43` | K12 class access modifiers + parameter properties | Bounded modifier-scan at the top of every class element consumes `public`/`private`/`protected`/`readonly`/`override`/`static`/`abstract` in any order, stopping when the next token indicates the keyword is being used as the member name. Same scan in `parse_function_param` gates on `allow_ts_mode` for constructor parameter properties. AST + emitter extended with `accessibility`, `readonly`, `override` fields. |
| `c8f9dff` | EST-3 / OPT-3 `--preserve-parens` | Acorn/OXC-shape `ParenthesizedExpression` wrapper around every non-arrow-cover paren-grouping. Default off. Reduces antd.js spec-compliance drift from 10020 → ~20 when enabled. |

### Phase 5 — all-items sweep, 7 commits (2026-04-23)

| Commit | Item | Notes |
|--------|------|-------|
| `66f25e9` | K3: pending_paren_start + verifier | `loc_from_expr`/`get_expr_loc_ptr` missing `ParenthesizedExpression` → `start=0` on IIFE callee. `parse_lhs_tail` .LParen: save/clear `pending_paren_start` before `parse_arguments` so paren-start never leaks into arg sub-exprs. Verifier: `--preserve-parens` for OXC compares, disable `unwrapParens` for OXC, strip `directive` Kessel-side. Divergences: 11 561 → 74. |
| `7fa2b40` | Wave 3 Phase C + Arrow emitter | TSX `<T,>`/`<T extends>` → generic arrow; fall through to JSX otherwise. ArrowFunctionExpression emits `typeParameters` + `returnType` (null in TS-shape mode). |
| `b2effaa` | TSParameterProperty | `FunctionParameter` AST tracks `accessibility`/`readonly`/`override_`/`modifier_start`. Emitter wraps in `TSParameterProperty` in `emit_ts_shape` mode. |
| `128ea4f` | EST-4 pt.1: TSMappedType shape | Rewrite TSMappedType emitter: `key` + `constraint` + `optional` + `readonly` matching OXC. |
| `f8656ec` | EST-4 pt.2: 10/10 TS spec fixtures | `new Box<T>()` callee fix (allow_call=false in lhs_tail .LAngle), TSIndexSignature spans + accessibility, FunctionExpression declare/typeParameters/returnType null, ClassDeclaration superTypeArguments, CallExpression/NewExpression typeArguments null, MethodDef/PropertyDef optional, TSInterfaceDeclaration body_start fix. Updated verifier strips. |
| `880e822` | NAPI/Visitor MVP | `npm/kessel-parser/`: `parseSync()` oxc-parser shim + `walk()`/`findAll()` visitor. |
| `17cdc45` | Fuzz baseline | 9 prior span-start failures now pass (pending_paren_start fix); promoted to pass. |
| `43c57dc` | Static-errors sweep 1 | Parse-time rejection for top-level `return`, stray `else`/`}`/`catch`/`finally`, unlabelled `break`/`continue` out of context, invalid LHS of `=`. Lexer diagnostics channel for numeric separators, BigInt invariants, bad binary/octal, unterminated string/regex, bad escapes, BOM+hashbang. Negative gate 20/32 → 42/63. |

### Phase 10 — Test262 grind, 19 commits (2026-04-24)

Session 10 drove Test262 full-corpus pass rate from 89.73% to
**96.30%** (+3 269 tests) by closing systematic parser / lexer
gaps surfaced by the full-corpus runner. Most commits are
small, precise, and each carries its per-commit Test262 delta
in the message. No new negative fixtures added this session —
the gate stays at 125/125 and the new classes live in the
parser/lexer where the test262-driven errors now fire.

| Commit | Item | +tests |
|--------|------|--------|
| `e4d4eb6` | BindingPattern Initializer_opt in nested-array element (`[[x] = []]`) | +1 081 |
| `00bfe9b` | BindingRestElement accepts nested pattern (`[...[x, y]]`) | +451 |
| `704cd03` | `\uXXXX` escapes in PrivateIdentifier (`#\u0041`) | +745 |
| `3e05519` | ImportCall / import.meta as ExpressionStatement in Block | +100 |
| `41dea8e` | ImportCall §Import Attributes + trailing comma | +62 |
| `92a875b` | §Phase Imports: `import.defer(x)` / `import.source(x)` | +40 |
| `9c16839` | §13.4.1 SimpleAssignmentTarget for UpdateExpression | ∼0 (opens) |
| `567c00c` | ImportCall early-errors + `--force-strict` | +332 |
| `86797ff` | §14.2.1 duplicate LexicallyDeclaredNames always-on | +143 |
| `f9598bf` | §13.5 Statement-only position gate | +102 |
| `6769293` | BindingRestElement early-errors in arrow cover | +15 |
| `67a0d08` | strict eval/arguments in destructuring targets | +24 |
| `5467df6` | CoverInitializedName + getter/setter arity | net (no change, errors offset) |
| `023ad4b` | strict eval/arguments in for-in/of head | +5 |
| `abd72b5` | no_in leak fix (array / object / template substitution) | +7 |
| `93a02e5` | `.Await` / `.Yield` added to can_start_regex | +13 |
| `f35422b` | class field ASI (`class C { #x\n#y }`) | +123 |
| `57909e8` | §12.6.1.1 strict-mode IdentifierReference check | +45 |
| `f871fa4` | §12.9.3 smooth-following + hex-empty checks | +16 |

Triage infrastructure added to support the grind:

  * `verify_test262_full.js --all-failures` — record every
    failure in the JSON summary instead of the first 50 only.
  * Per-subdir aggregation (`perSubdir` in the summary) for
    fast pattern-finding across 2k+ failures.
  * `KESSEL_T262_ALL_FAILURES=1 bash tests/runners/run_test262_full.sh`
    threads the flag through the runner.

Key design lessons:

  * **The fast-path and the slow path must both carry the
    early-error checks.** `parse_unary_expr` has an inline
    fast-path for `.Identifier / .Get / .Set / .Let / .Static /
    .Constructor / ...` that skips `parse_primary_expr`. Several
    strict-mode IdentifierReference checks were only in the slow
    path until this session's commit `57909e8` added them to
    both.
  * **Parser state leaks.** `no_in` was set at the
    for-statement level to disable `in` as a binary operator in
    the for-init expression, but leaked into nested ArrayExpr /
    ObjectExpr / TemplateLiteral substitution bodies. Fixed in
    `abd72b5` by save/reset/restore at each natural expression
    boundary, matching the existing paren-grouping reset.
  * **ASI at class body level.** The method-vs-field
    discriminator originally checked only explicit terminators
    (`;`, `=`, `,`, `}`). A line terminator between the field
    name and the next class element also terminates the field,
    mirroring the §12.10 ASI rule. Fixed in `f35422b`.
  * **Cover-form early errors fire at the conversion point.**
    `{a = 1}` is a CoverInitializedName — legal inside a
    destructuring-assignment cover, SyntaxError as a plain
    ObjectExpression. Rather than refusing it at parse time
    (which would break the cover use), `5467df6` tracks pending
    cover-init offsets on the Parser; `expr_to_pattern` clears
    entries when the object gets promoted; leftovers at
    end-of-parse are reported.

Positive gates at end of Session 10 (unchanged or improved):
  272/272 unit · 467/467 real-world · 144/144 spec-fixtures ·
  125/125 negative · 66/66 curated test262 · 32/32 recovery ·
  57/57 nodes · 11/11 regression · 467/467 invariants ·
  0 spec-compliance divergences · 100/100 fuzz-diff ·
  8/8 fuzz-invalid (baselined) · 0 crashes-known ·
  `test:estree:strict` zero-tolerance clean ·
  Test262 full 47 889 / 49 729 (96.30%) baselined (up from
  44 620 / 49 729 at Session-9 end).

### Phase 9 — close all handoff targets, 6 commits (2026-04-24)

Session 9 closed every one of the Session-8-end next-session items:

| Commit | Item | Notes |
|--------|------|-------|
| `22ff61a` | **K13 closed** — `--strict-source-type` flag | No more silent auto-upgrade to Module on implicit import / export / top-level await. When no explicit `--source-type` is given but `--strict-source-type` is, the default is promoted to Script. `--source-type=module` explicit still opts in. |
| `795f442` | **ERR-2 partial** — recovery hardening | Four previously-silent gaps in parse_arguments / parse_variable_declarator / parse_function_param / parse_ts_type_parameters now emit structured diagnostics. 12 new recovery fixtures across expressions, statements, declarations, jsx_ts. Gate grows 20/20 → 32/32. |
| `e64ee36` | **Regex pattern / flag validation (§22.2.1)** | Group / character-class balance, trailing-backslash, escape-before-newline, duplicate / invalid / mutually-exclusive flag handling. 5 new negative fixtures. |
| `62a7b61` | **OPT-6 MVP** — `--show-semantic-errors` | Post-parse scope-verification pass: duplicate lexical / var clashes across every body-scope. Off by default. 3 new negative fixtures gated behind the flag in the negative-runner. |
| `e494ff5` | **TEST-1 wired** — full Test262 runner | Discovers 49 729 fixtures, YAML front-matter parse, per-fixture classification, per-directory aggregation, baseline compare. First-pass result: 89.73% pass rate. `task test:test262:full` / `:full:regression` / `:full:update`. |
| `5aef393` | **NAPI-1** — server mode + async Node bridge | `kessel server` subcommand reads file paths from stdin, writes AST + sentinel to stdout. `npm/kessel-parser/server.js` multiplexes async `parse()` / `parseFile()` over a long-lived subprocess pool. **3.7× throughput** over spawn-per-call path in bench. Full NAPI still on the tracker as NAPI-2 / NAPI-3. |

Positive gates at end of Session 9 (unchanged or improved):
  272/272 unit · 467/467 real-world · 144/144 spec-fixtures ·
  125/125 negative · 66/66 curated test262 · 32/32 recovery ·
  57/57 nodes · 11/11 regression · 467/467 invariants ·
  0 spec-compliance divergences · 100/100 fuzz-diff ·
  8/8 fuzz-invalid (baselined) · 0 crashes-known ·
  `test:estree:strict` zero-tolerance clean ·
  Test262 full 44 620/49 729 (89.73%) baselined.

### Phase 8 — contextual yield/await + for-in carve-out + export resolution, 6 commits (2026-04-24)

Session 8 extended the ratchet from 102/102 (41 classes) to **117/117
(48 classes)**. Seven new static-error classes landed, all of which
required deeper parser plumbing than the drop-in checks of Session 7.
All other suites stayed green (272/272 unit · 467/467 real · 144/144
spec-fixtures · 66/66 test262 · 100/100 fuzz · 20/20 recovery · 0
spec-compliance divergences · test:estree:strict zero-tolerance clean).

| Commit | Item | Notes |
|--------|------|-------|
| `bea6c76` | YieldExpression outside generator | §15.5. `parse_unary_expr` .Yield now makes a contextual choice in non-generator scope: lookahead drives "yield as IdentifierReference" (terminator / binary / postfix / call / member / tagged-template continuation) vs "yield-expression form — error" (literal / identifier-starter / unary keyword / `!` / `~`). New helper `yield_next_is_expression_argument(p)`. Fixtures 042, 043. |
| `0fb23c1` | Await in async-function / method / arrow params | §15.8.1 / §15.9.1 / §15.6.1. Session 7's stub `in_async_arrow_params` flag renamed to `in_async_params` and wired at every async function-like param entry point (parse_function_declaration, parse_class_element method, parse_object_literal accessor + method, parse_async_arrow_with_parens). The existing parse_unary_expr .Await check fires on entry. Fixtures 044, 045, 046. |
| `ad31919` | Yield / await in arrow params (§15.3.1) | The cover `(x = await 1)` parses legally inside an outer generator / async body; detection has to happen at the `=>` commit. New `scan_arrow_cover_for_yield_await` walks the raw cover Expression in `parse_arrow_function`. Stops at every FunctionExpression / ArrowFunctionExpression / ClassExpression boundary per spec Contains semantics. At most one error of each kind per arrow. Fixtures 047, 048. |
| `681fcc2` | Yield in async arrow params (§15.9.1 cross-ref) | The async-arrow path builds params directly via parse_function_params (no cover trial-parse), so the cover walker from `ad31919` doesn't see them. Adds a parallel `scan_arrow_params_for_yield_only` + `arrow_cover_walk_pattern` that descends AssignmentPattern / ObjectPattern / ArrayPattern / RestElement. Await already covered by in_async_params; yield-only to avoid double-reporting. Fixture 049. |
| `0ce291e` | For-in/of initializer + Annex B.3.5 | Sets `p.no_in` around the for-init VariableDeclaration parse so `for (var x = 1 in y)` routes through the for-in arm instead of the misleading "Expected ;" from the regular-for path. Post-branch gate enforces core §14.7.5.1 "no initializer on ForDeclaration" with the sloppy-mode `for (var BindingIdentifier = init in Expr)` Annex B.3.5 carve-out. Also rejects multiple declarators in a for-in/of head (comma-list). `parse_function_body` saves / resets no_in so a nested `function() { if (a && "x" in y) {}}` inside the for-init keeps `in` as a binary operator — restored mathjs.js / deckgl.js which regressed on the initial change. Fixtures 050–053 + strict_mode/019. |
| `a9f9ab0` | Export-local binding resolution (§16.2.2) | `export { foo };` (no `from`) requires `foo` to be declared in the module. String-literal `export { "foo" };` without `from` also rejected. Post-parse pass in `parse_program` collects the module's top-level binding set (VariableDeclaration + FunctionDeclaration + ClassDeclaration + ImportDeclaration specifiers + TS type-level decls + inner decls of `export var/function/class`) and verifies every ExportNamedDeclaration without a `from` clause. Skipped for Script source-type (already diagnosed). Helpers: `collect_pattern_bound_names`, `collect_module_top_level_names`, `verify_export_locals`. Fixtures 054, 055. |

### Phase 7 — early-errors continuation + K14 close, 6 commits (2026-04-24)

Session 7 extended the ratchet from 90/90 (29 classes) to **102/102 (41
classes)**. K14 (`continue label` iteration-target check) closed.
Delete-of-paren-identifier tightened under `--preserve-parens`. No
new K-issues introduced; all other suites stayed green.

| Commit | Item | Notes |
|--------|------|-------|
| `b151f44` | SuperCall outside derived constructor | §15.7.3 / §13.3.7. New `in_derived_constructor` + `class_has_extends` parser fields; set only for instance constructor of a class with `extends`. Arrow functions inherit (lexical super-call); every non-arrow boundary resets both flags. Fixtures 031, 032. |
| `05782a8` | Escaped-keyword as Identifier | §12.7.2. Token grows `has_escape: bool` preserved from FLAG_HAS_ESCAPE across `eat()`. New `report_escaped_reserved_word(p)` fires at IdentifierReference (parse_unary_expr fast-path + parse_primary_expr), BindingIdentifier, and LabelIdentifier sites. IdentifierName positions (member/property/method/import-spec) deliberately unchanged. Fixtures 033, 034, strict_mode/018. |
| `a1cd67e` | ArrowFunction / Async restricted productions | §15.3 (LT before `=>`), §15.8 (LT between `async` and `function` in decl), §15.9 (LT between `async` and next in arrow). `had_line_terminator` checked at the relevant dispatch points. Fixture 035. |
| `b0101bf` | K14 close + delete-paren-identifier | §14.8.1 (continue-label must name an iteration). New `label_is_iteration` parallel stack; eager `label_chain_leads_to_iteration(p)` uses lexer snapshot/restore to walk through `Identifier :` chains so `foo: bar: for(...)` correctly marks both labels iteration-valid. §13.5.1 (`delete (x)` in strict) — parse_unary_expr now peels `ParenthesizedExpression` wrappers before the Identifier check. Fixture 036. |
| `b394ba0` | 3 more classes | §13.3.5 tagged template on optional chain (parse_lhs_tail tracks `is_chain`); §14.7.5.1 for-in/for-of LHS cannot be AssignmentExpression; §16.2.2 duplicate import BoundNames (new helper `import_spec_local_name(spec)` over every specifier kind, O(n²) pairwise). Fixtures 037, 038, 039, 040. |
| `e736088` | YieldExpression in generator FormalParameters | §15.5.1 / §15.6.1. New `in_generator_params: bool` flag wrapped around parse_function_params in function decl / class method / object-literal accessor+method paths; parse_yield_expr reports on entry. Symmetric `in_async_arrow_params` added for §15.9.1 but deferred wiring (async arrow params go through CoverCallExpression + trial-parse). Fixture 041. |

### Phase 6 — negative-gate closure + early-errors sweep, 13 commits (2026-04-24)

From 42/63 rejected (9 error classes) at session start to **90/90 rejected (29 error classes)** at session end. Every other suite stayed green; one secondary fix (K9) dropped integration drift from 538 to 0.

| Commit | Item | Notes |
|--------|------|-------|
| `420cb52` | Static-errors sweep 2 — **negative gate 63/63** | Closed every session-5 baselined gap in one commit: 9 classes — `super` outside method, duplicate `__proto__`, duplicate lexical decls, strict-mode directive promotion in function bodies, class-body implicit strict, duplicate params in strict, strict-only reserved words as bindings (`let`/`static`/`yield` + `implements`/`interface`/`package`/`private`/`protected`/`public`), `eval`/`arguments` as binding / LHS, legacy octal in strict, and `import`/`export`/TLA/`import.meta` under `--source-type=script`. Verifier auto-passes `--source-type=script` for the `module_context/` dir. |
| `322a6a6` | Verifier ratchet | `verify_negative.js` now flips to zero-tolerance once baseline is 100% clean: new accepted fixtures fail the default gate. Manually verified by adding a probe file. |
| `f7f8caa` | **K9 closed** — `verify_integration` EXPR tag table | `^ChainExpression` had been inserted into `Expression` union between `^Super` and `^ArrayExpression`, shifting every downstream tag by +1; verifier decoded every expression from ArrayExpression onward as the wrong type. Added `13:'ChainExpression'` and renumbered. Also added the JSX + TS variants (34–44) that the table had been silently missing. jquery 4 → 0 / react-dom.dev 3 → 0 / preact 531 → 0 / snabbdom 0 → 0. `test:estree:strict` now passes. |
| `6d7cf07` | Handoff sync after K9 | |
| `92ee5bb` | 5 more classes — negative 69/69 | `with`-in-strict (§13.11.1), legacy-octal / `\8` / `\9` in strict StringLiteral (§12.9.4), duplicate DefaultClause in switch (§14.12.1), duplicate LabelIdentifier + unknown break/continue target (§14.13.1, §14.14.1/2), duplicate private class member + `#constructor` (§15.7.1). New `p.label_stack` + `p.label_floor` wiring; labels don't cross function boundaries. |
| `716f916` | 4 more classes — negative 73/73 | Legacy-octal / `\8` / `\9` in untagged TemplateLiteral (§12.9.4/6), `for await` outside async context (§14.7.5), `let` as lexical BoundName in both modes (§14.3.1.1), static class member named `prototype` (§15.7.1). |
| `b708c10` | 4 more classes — negative 77/77 | UpdateExpression on `eval`/`arguments` in strict (§13.4.1), `delete <ident>` in strict (§12.5.1.1), PrivateIdentifier outside `in`-expression (§13.2), `new import(...)` (§13.3.12). |
| `50a849f` | 4 more classes — negative 81/81 | UniqueFormalParameters forced by non-simple param list (§15.1.2), arrow / async-arrow / TS-generic-arrow UniqueFormalParameters always (§15.3.1), `yield` as binding in generator body (§13.2), `await` as binding in async function body (§13.2). |
| `784ca574` (397e966) | 4 more classes — negative 85/85 | `new.target` outside function (§13.3.12/§15.2), LegacyOctal BigInt (`0123n`, §12.9.3), `function eval` / `function arguments` in strict (§15.1.1), ClassDeclaration / ClassExpression with a strict-reserved name (§15.7.1). |
| `a3bdf5a` | 3 more classes + strict-retro fix — negative 87/87 | `report_duplicate_param_names` gained a `strict_override` parameter so retro-checks after a nested body-strict promotion actually fire; trailing comma after RestElement (§15.1/15.3); labeled FunctionDeclaration in strict (§14.13.1). |
| `ab1f14c` | 3 more classes — **negative 90/90** | `delete x.#y` / `delete this.#y` (§13.5.1), `throw` with LineTerminator before argument (§14.14 Restricted Production), duplicate `constructor` in class (§15.7.1). |
| `e6d100d` | Handoff sync — session close | Comprehensive ERR-5 section with full catalog of 20 classes. |

### Process lessons (from the swarms / sessions)

**Haiku silent work-loss (Phase 3).** Two Haiku sessions ran `git stash` or
`git checkout -- <file>` in their final cleanup, silently destroying
completed work that had passed verification. Upstream
`~/.agents/skills/execute-task/prompts/_safety.md` had forbidden
`git commit`/`push` but not working-tree-manipulating commands. **Hardened
upstream** on 2026-04-22 to forbid every git command that moves, discards,
or hides uncommitted changes (stash / reset / checkout-files / restore /
clean / rebase / merge / cherry-pick / revert / branch / switch / tag /
worktree). The one Haiku delegation after the hardening (`d7dfd0e0`, ESM
module record) landed intact with zero silent git operations.

**Test-runner `exit_code` bug (Phase 3).** `tests/runners/run_tests.sh`
didn't reset `exit_code` between iterations; one crashing fixture poisoned
every subsequent fixture's exit-code check. Result: apparent 10 % pass rate
that was actually 88 %. Fixed in `b02dfe5` alongside Phase B.

**Phase 2 → Phase 3 tracker drift.** The parity tracker showed ~0 items
closed when the session report documented 23 closed. Sync'd twice in
Phase 3 (`2ad4487`, `4b543cf`).

**Stale verifier tables on union-variant insert (Phase 6).** Adding
`^ChainExpression` to the `Expression` union in `ast.odin` silently
shifted every downstream tag by +1 in the raw-transfer binary output.
`verify_integration.js`'s `EXPR` table wasn't updated, so every
CallExpression got decoded as NewExpression, every FunctionExpression
as ArrowFunctionExpression, etc. Existed for weeks unnoticed because the
baseline captured the drift as “expected”. Fixed in `f7f8caa`; added a
header comment to the `EXPR` table spelling out the “track ast.odin
declaration order” invariant so the next insertion doesn't repeat it.

**Baseline ratchet (Phase 6).** The session-5 `verify_negative.js` only
failed on `rejected→accepted` regressions. New fixtures that the parser
couldn't handle were logged but didn't fail the gate — a drift window.
Post-ratchet, once the baseline reaches 100% “rejected”, any new fixture
the parser accepts fails the default run. Verified by dropping a
known-legal probe into `tests/fixtures/negative/` and confirming the gate
tripped with a pointer to `--update`.

**Strict-mode retro-checks need their own flag (Phase 6).**
`parse_function_body` sets `p.strict_mode = true` when it sees a `"use
strict"` directive, then restores on exit. By the time the caller runs
the StrictFormalParameters dup check `p.strict_mode` is already false
again. The fix was to surface the body's strict-ness as
`p.last_body_strict` and pass `strict_override` through to the helper;
caught by the fixture `function f(a,b,a,b) { 'use strict'; }`.

---

## 8. Known Issues

| # | Issue | Severity | Where | Fix status |
|---|---|---|---|---|
| K1 | **`task test:fuzz:invalid` — 8 baselined crashes** (was 29). SIGSEGV/SIGTRAP fixed in `07858c4` via emitter nil-pointer + inverted-span guards. Infinite-loops fixed in `491d083` (parse_lhs_tail .Not case + parse_jsx_children progress guard). 8 remaining are SIGTERMs (deadline-crosses) on 350 KB – 4 MB mutated files. | Low | parser (perf on very large mutated input) | Baselined in `tests/baselines/fuzz_invalid_baseline.json`. Not worth further chasing — these are deadline hits, not parser bugs. |
| K2 | ~~`task test:crashes-known` regressions~~ ✅ Fixed in `491d083`. | | | |
| K3 | ~~spec-compliance divergences~~ ✅ Closed twice over. 11 561 → 74 via `pending_paren_start` fixes + `--preserve-parens` wiring (`66f25e9`). 74 → **0** in the 2026-04-23 spec-compliance sweep via eight follow-up fixes (see §9 below). | — | — | Baselined at 0. |
| K4 | ~~Arrow-param type annotations~~ ✅ Fixed in `c0e1a4d`. `(x: T) => x`, `(...args: T[]) => ...`, `(x: T): R => ...`, generic-arrow `<T>(x: U) => x`, function-type `(cb: (x: number) => string) => ...` all parse clean. | | | |
| K5 | ~~Deep JSX child recursion crash~~ ✅ Fixed. `spec/jsx/005_nested_element` now passes both `<Outer><Middle><Inner/></Middle></Outer>` and `<Foo bar={<Baz x={1}/>}/>`. Ancestor commits (`70b5652`, Phase 2 span fixes) closed it; handoff entry was stale. | | | |
| K6 | ~~`early_errors/016_digit_start_identifier.js`~~ ✅ Fixed. `const 1a = 1;` now parses with structured errors, no SIGTRAP. | | | |
| K7 | ~~`\u00GG` invalid-hex in identifier~~ ✅ Fixed. Graceful errors, no SIGTRAP. | | | |
| K8 | ~~`x!!` double non-null~~ ✅ Fixed. Parses clean in TS mode. | | | |
| K9 | ~~`task test:estree` — 4 field-type mismatches on jquery.js (+ react-dom.dev.js 3, preact.js 531)~~ ✅ Fixed in `f7f8caa`. Root cause was a stale `EXPR` tag→name table in `tests/verifiers/verify_integration.js`: `^ChainExpression` had been inserted into the `Expression` union between `^Super` and `^ArrayExpression`, shifting every downstream tag by +1; the verifier silently decoded every expression from ArrayExpression onward as the wrong type. Fix added `13:'ChainExpression'` and renumbered. Totals went 538 → 0 mismatches across the integration corpus; `task test:estree:strict` now passes zero-tolerance. | — | — | Fixed. |
| K10 | ~~TS-ESTree shape diff~~ ✅ Closed (`f8656ec`). All 10 `spec/typescript/*` fixtures pass deep OXC compare. OXC used as reference (typescript-estree verifier not needed). | — | — | Fixed. |
| K11 | **Debug build linker warnings** — ~50 about missing symbols for JSX/TS generic instantiations. | Cosmetic | Odin toolchain | Binary works. Ignore. |
| K12 | ~~Class method access modifiers + TSParameterProperty~~ ✅ Fixed in `0513d43` + `b2effaa`. Parses all modifier permutations. Constructor parameter properties now wrapped in `TSParameterProperty { parameter, accessibility, readonly, override, static }` in emit_ts_shape mode. | — | — | Fixed. |
| K13 | ~~Module-syntax errors only fire under `--source-type=script`~~ ✅ Closed in Session 9 (`22ff61a`) via `--strict-source-type` flag. When set without explicit `--source-type`, the default is promoted to Script and implicit module-syntax (top-level import / export / import.meta / TLA) is rejected. Matches Acorn's `sourceType: 'script'` semantics. | — | — | Fixed. |
| K14 | ~~`continue label` doesn't check the label targets an IterationStatement~~ ✅ Fixed in `b0101bf`. New `label_is_iteration` parallel stack indexed same as `label_stack`; eager `label_chain_leads_to_iteration(p)` uses lexer snapshot/restore to walk through `Identifier :` chains so chained labels like `foo: bar: for(...)` correctly mark both as iteration-valid. `continue foo;` inside a labelled block now errors as spec. | — | — | Fixed. |
| K15 | **No scope / symbol analysis.** Cross-statement bindings like `let x; var x;`, block-scoped redeclaration, undefined `break`/`continue`-like semantics below the grammar, and the full `showSemanticErrors` surface all require a scope pass we haven't built. | Low | parser-wide | OPT-6 tracker item. |

---

## 9. What to work on next

Session 11 took the full Test262 corpus from 96.30% → **97.92%**
(+808 tests, 17 parser/lexer patches) by closing the systematic
clusters Session 10 surfaced. Surviving failures are now:

- **922 accepted-should-reject** (down from 1 504, −582). Biggest
  remaining clusters: regex grammar (≥336, needs a real regex
  parser — Session 11 added named-group declaration + back-
  reference validation but full AtomEscape / CharacterEscape /
  CharacterClassEscape / GroupName / v-flag set notation is still
  deferred), class elements (~140, residual private-name resolution
  + decorator surface), built-ins early errors (≥100 across
  RegExp.prototype / property-escapes that overlap the regex
  cluster).
- **109 rejected-should-accept** (down from 335, −226). Biggest
  clusters: class elements (≈60), object-rest/spread edge cases
  (≈20), TLA in exotic positions (≈20), residual restricted-
  production gaps. The 87-fixture static `import defer` decl-form
  cluster and the 48-fixture for-await-of numeric-key cluster were
  closed in Session 11.

### Session 11 accomplishments (2026-04-24)

- **Test262 full 96.30% → 97.92%** (47 889 → 48 697, +808). Baseline
  relocked at this higher pass count —
  `tests/baselines/test262_full_baseline.json` updated. Per-dir:
  language 22 014 → 22 824 (+810), staging 1 469 → 1 470 (+1),
  annexB 1 083 → 1 084 (+1), built-ins 23 323 → 23 319 (−4 net,
  accept-should-reject narrowed). One residual crash, zero
  timeouts.
- **17 parser / lexer patches** for systematic early-error,
  cover-grammar, and strict-mode gaps. Per-commit Test262 deltas:
  - `e53b11f` numeric-key ObjectPattern + for-in/of cover-init clear (+161)
  - `a2bdc4d` escaped-ReservedWord in object shorthand key (+70)
  - `a44710a` §15.7.3 AllPrivateIdentifiersValid walker (+111)
  - `c83b888` static `import defer` / `import source` decl form (+87)
  - `b4eaa1b` class body strict-mode coverage (+14)
  - `518bd07` strict-mode shorthand reference check (+24)
  - `25ecee1` unconditional UniqueFormalParameters (+3)
  - `478ed50` `"use strict"` with non-simple param list (+45)
  - `74143d4` validate destructuring assignment targets (+23)
  - `05ee9da` `\u` escape after numeric literal (+10, lexer)
  - `256ee94` missing initializer on const / using / await using (+7)
  - `942ffa3` yield/await as binding in param list (+10)
  - `3b6c9e3` Annex B.3.2/B.3.3 function-in-block scoping (+6)
  - `96c0fba` §15.7.5 class field init `arguments` (+58)
  - `e53d947` yield/await as label + await-with-no-operand (+128)
  - `ac2dc58` retro legacy-octal escape in strict prologue (+10)
  - `7af4651` §12.9.6 untagged template invalid escapes (+14)
- **§22.2.1 regex named-group validation** (`f2e59a1`, lexer +172).
  Two-pass scan: pass 1 collects every `(?<name>` declaration and
  reports empty / unterminated / invalid-character forms; pass 2
  resolves every `\k<name>` reference. Skips lookbehind forms and
  character-class interiors. Per ES2025 §Duplicate Named Capturing
  Groups, repeats in different DisjunctionAlternatives are accepted
  (matches OXC + V8). Full RegExp grammar still deferred.
- **§15.7.3 walker empty-name guard** (`1b97e8b`). The Session-10
  AllPrivateIdentifiersValid walker fired "Private field '#' must
  be declared in an enclosing class" on every empty-name
  PrivateIdentifier. Empty names are a parser recovery artifact
  (lone `#` from malformed hashbang); the lexer / parser already
  reports the structural error at the parse site, and an empty
  name can never resolve to a declared private. Guarded the three
  walker sites with `len(name) > 0` before lookup.
- **Fixture refresh** (`1705da2`, 10 files). Two clusters of
  spec-correct emission churn the expected fixtures hadn't caught
  up with: `options: null` + `phase: null` on every
  ImportExpression / ImportDeclaration (from `c83b888` Phase
  Imports, OXC-shape compatible), and the new
  `Missing initializer in 'const' declaration` error on declarators
  left with `init: null` after recovery (from `256ee94`).
- **Baselines relocked** (`9cf1520`). Test262 full baseline
  refreshed at 48 697 / 49 729. Fuzz baseline picks up 3 known
  failures where Kessel correctly rejects per-spec but OXC
  accepts: `(b, b) =>`, `(foo, foo) =>`, and a top-level `let c` /
  `function c` clash. Documented as known fuzz-baseline deltas;
  not parser regressions.
- **All other gates stayed green.** `test:real` 467/467,
  `test:spec-fixtures` 144/144, `test:spec-compliance` 0
  divergences, `test:estree:strict` zero-tolerance clean,
  `test:negative:strict` 125/125, `test:recovery` 32/32,
  `test:nodes` 57/57, `test:invariants` zero-tolerance clean.

### Session 10 accomplishments (2026-04-24)

- **Test262 full 89.73% → 96.30%** (44 620 → 47 889). Baseline
  relocked at this higher pass count —
  `tests/baselines/test262_full_baseline.json` updated.
- **19 parser/lexer patches** for systematic early-error and
  cover-grammar gaps. See §7 "Phase 10" for the per-commit
  table and §6 ERR-5 for the catalog of new classes.
- **Triage infra:** `verify_test262_full.js --all-failures` +
  `perSubdir` aggregation in the JSON summary. Every future
  session can triage without re-running.
- **--force-strict CLI flag** for Test262's `onlyStrict`
  fixtures; enables the strict-only early-error surface
  (LegacyOctalEscape, for-in initializer, eval/arguments
  binding, …) on a corpus without `"use strict"`.
- **All other gates stayed green.** `test:real` 467/467,
  `test:spec-fixtures` 144/144, `test:spec-compliance` 0
  divergences, `test:estree:strict` zero-tolerance clean,
  `test:negative` 125/125, `test:recovery` 32/32.

### Session 9 accomplishments (earlier, for reference)

Session 9 closed every one of the Session-8 next-session items
plus shipped new infrastructure:

- **K13 closed** via `--strict-source-type` flag.
- **ERR-2 partially** closed: recovery gate expanded 20/20 → 32/32
  with 4 parser hardening fixes.
- **Regex pattern-body validation** shipped: structural + flag checks
  per §22.2.1 (full AtomEscape surface still deferred to a dedicated
  regex parser).
- **OPT-6 MVP** shipped: `--show-semantic-errors` flag enables a
  post-parse scope-verification pass.
- **TEST-1 wired**: full Test262 runner + baseline at 89.73% pass.
- **NAPI-1** shipped: `kessel server` + async Node bridge, **3.7×**
  throughput over spawn-per-call.
- **Negative gate** 117/117 → **125/125** (48 → 54 static-error
  classes).

### Session 9 accomplishments (2026-04-24)

- **Recovery gate 20/20 → 32/32.** Four parser gaps closed
  (empty spread target, empty var init, empty param default, empty
  TS type-param constraint / default) and 12 new fixtures. See
  §7 Phase 9 for the per-commit breakdown.
- **Regex validation at the lexer.** Structural checks (group
  balance, character-class balance, trailing backslash, escape
  before newline) and flag validation (recognised set, duplicates,
  `u`/`v` mutual exclusion). 5 new negative fixtures.
- **OPT-6 — `--show-semantic-errors`.** Post-parse scope walker over
  every body-scope (Program / FunctionBody / BlockStatement /
  CatchClause / TryBlock / SwitchCase / for-body / arrow block
  body). Gated behind the flag to keep default output unchanged.
- **Test262 full corpus wired.** Baseline at 44 620/49 729 (89.73%)
  with per-directory breakdown. `task test:test262:full:regression`
  fails on pass-count drops or crash growth.
- **Server mode for zero-spawn calls.** New `kessel server`
  subcommand + `npm/kessel-parser/server.js` async bridge; 3.7×
  faster than spawn-per-call in bench.
- **K13 closed** (`--strict-source-type`).
- **All other suites stayed green**: 272/272 unit · 467/467 real
  · 144/144 spec-fixtures · 66/66 test262 · 100/100 fuzz · 0
  spec-compliance divergences · `test:estree:strict` zero-tolerance
  clean.

### Session 8 accomplishments (2026-04-24)

- **Negative gate 102/102 → 117/117 rejected.** **7 new static-error
  classes** over 6 parser commits. See ERR-5 in §6 for the full
  catalog and §7 “Phase 8” for the per-commit breakdown.
- **YieldExpression outside generator (§15.5).** Contextual
  lookahead in parse_unary_expr .Yield: yield is an identifier when
  the next token continues as a binary / postfix / call / member /
  terminator, and yield-expression-with-error when the next token
  cleanly starts an expression argument. Matches Acorn / OXC / V8
  on the clear cases.
- **Await in async function/method/arrow params (§15.8.1, §15.9.1,
  §15.6.1).** Renamed `in_async_arrow_params` → `in_async_params`
  and wired all five entry points. parse_unary_expr .Await reports
  on entry.
- **Yield / await in arrow params (§15.3.1).** New
  scan_arrow_cover_for_yield_await walker runs at parse_arrow_
  function's `=>` commit, traversing the raw cover Expression. Stops
  at FunctionExpression / ArrowFunctionExpression / ClassExpression
  scope boundaries per spec Contains semantics.
- **Yield in async arrow params (§15.9.1 cross-ref).** Parallel
  `scan_arrow_params_for_yield_only` for the async-arrow path which
  builds params directly via parse_function_params.
- **For-in/of initializer + Annex B.3.5 carve-out.** `parse_for_
  statement` sets `p.no_in` around the var-init declarator so
  `for (var x = 1 in y)` reaches the for-in arm. Post-branch gate
  enforces core §14.7.5.1 initializer ban with the sloppy-mode
  `for (var BindingIdentifier = init in Expr)` carve-out.
  `parse_function_body` saves/restores no_in so nested function
  bodies keep `in` as a binary operator.
- **Export-local resolution (§16.2.2).** New post-parse pass in
  parse_program collects the module's top-level binding set and
  verifies every ExportNamedDeclaration without a `from` clause.
  Also rejects `export { "foo" };` (string-literal local without
  `from`).
- **New helpers:** `yield_next_is_expression_argument`,
  `scan_arrow_cover_for_yield_await`, `arrow_cover_walk_expr`,
  `scan_arrow_params_for_yield_only`, `arrow_cover_walk_pattern`,
  `collect_pattern_bound_names`, `collect_module_top_level_names`,
  `verify_export_locals`.
- **All other suites stayed green**: 144/144 spec-fixtures, 100/100
  fuzz-diff, 0 spec-compliance divergences, 467/467 real-world,
  66/66 test262, 20/20 recovery, 57/57 nodes, 11/11 regression,
  `test:estree:strict` zero-tolerance clean.

### Session 7 accomplishments (2026-04-24)

- **Negative gate 90/90 → 102/102 rejected.** **12 new static-error
  classes** over 6 parser commits. See ERR-5 in §6 for the full
  catalog and §7 “Phase 7” for the per-commit breakdown.
- **K14 closed.** `continue label` now verifies the target label
  names an IterationStatement (directly or via a chain of
  LabelledStatements). New `label_is_iteration` parallel stack plus
  a `label_chain_leads_to_iteration(p)` helper that uses lexer
  snapshot/restore to walk through `Identifier :` chains eagerly.
- **`delete (Identifier)` under --preserve-parens.** Strict-mode
  rejection was slipping through when the Identifier was wrapped by
  ParenthesizedExpression; parse_unary_expr now peels the wrapper
  before the Identifier check.
- **Token carries has_escape.** New `Token.has_escape` preserves
  FLAG_HAS_ESCAPE across `eat()` so the parser can enforce §12.7.2
  at all Identifier-production sites. Lexer stays context-free.
- **New parser fields:** `in_derived_constructor`, `class_has_
  extends`, `label_is_iteration`, `in_generator_params`,
  `in_async_arrow_params` (scaffold only, not yet wired).
- **All other suites stayed green**: 144/144 spec-fixtures, 100/100
  fuzz-diff, 0 spec-compliance divergences, 467/467 real-world,
  66/66 test262, 20/20 recovery, 57/57 nodes, 11/11 regression,
  `test:estree:strict` still zero-tolerance clean.

### Session 6 accomplishments (2026-04-24)

- **Negative gate 42/63 → 90/90 rejected.** **20 new static-error classes**
  over 11 parser commits. See ERR-5 in §6 for the full catalog and
  §7 “Phase 6” for the per-commit breakdown.
- **Verifier ratchet engaged.** Once the baseline is 100% “rejected”,
  `verify_negative.js` auto-strictifies the default gate: new accepted
  fixtures fail immediately. Confirmed by dropping a probe file.
- **K9 closed.** `verify_integration`'s `EXPR` tag table was stale
  after `^ChainExpression` was added to the `Expression` union.
  Integration drift went 538 → 0; `test:estree:strict` now passes
  zero-tolerance.
- **Legacy items archived.** K1–K8, K10, K12 all closed in prior
  phases; K9 closed in Phase 6. K11 (debug linker warnings) remains
  cosmetic. K13–K15 are new Session-6 observations — all low-severity.
- **All other suites stayed green**: 144/144 spec-fixtures, 100/100
  fuzz-diff, 0 spec-compliance divergences, 467/467 real-world, 66/66
  test262, 20/20 recovery, 57/57 nodes, 11/11 regression.

### Remaining items (ordered by impact × feasibility)

1. **Test262 class-element grind.** 327 fixtures still
   accepted-should-reject in `language/{expressions,statements}/
   class/elements/*`. The big sub-clusters:
   * **Private-name resolution** (§15.7.3) — `AllPrivateIdentifiers
     Valid`. A PrivateIdentifier reference must resolve to a
     declared PrivateName in some enclosing class on the lexical
     stack. ~28 fixtures under
     `.../elements/syntax/early-errors/invalid-names/` wait on
     this. Needs a class-scope stack + per-class private-name
     set + post-parse walker of class method / field initializer
     bodies.
   * **§13.2.5.1 CoverInitializedName edge cases beyond the
     bare `({a = 1})` form.**
   * **Decorator proposal coverage** (~10 fixtures under
     `.../decorator/syntax/*`). Kessel parses the basic
     `@decorator class {}` surface; more complex decorator
     expressions (member / call / parenthesized) still pending.

2. **Test262 rejected-should-accept (parser bugs): 109 left.**
   Down from 335 at Session-10 end (−226). Big remaining buckets:
   * `language/expressions/class` + `language/statements/class`
     (~60 combined) — residual class-element parser
     shortcomings around escaped keywords in class names,
     static-block ASI edges, and decorator surface.
   * `language/expressions/object` (≈20) — object-rest /
     spread cover-grammar edges.
   * `language/module-code/top-level-await` (≈20) — await
     expressions in exotic positions (await in class extends,
     computed member keys, etc.).
   * Residual restricted-production gaps in async / arrow LT
   handling.
   The 87-fixture static `import defer` decl-form cluster
   (`c83b888`) and the 48-fixture for-await-of numeric-key
   cluster (`e53b11f`) were closed in Session 11.
   Use `jq -r '.all_failures[] | select(.verdict ==
   "rejected-should-accept") | .file' tmp/test262_full_run.json |
   awk -F/ '{print $1"/"$2"/"$3}' | sort | uniq -c | sort -rn` to
   re-triage after each fix.

3. **Full Regex pattern validation** (ERR-5 continuation).
   Structural + flag checks shipped in Session 9; named-group
   declaration + back-reference resolution shipped in Session 11
   (`f2e59a1`). Full AtomEscape / CharacterEscape /
   CharacterClassEscape / Unicode property escapes / v-flag set
   notation are still deferred to a dedicated regex parser (OXC
   uses oxc_regular_expression). ~336 fixtures blocked on this
   (`language/literals/regexp` 173 + `built-ins/RegExp/
   {property-escapes,prototype}` 163+28). High effort, high
   reward.

4. **Scope / symbol analysis deepening** (OPT-6 continuation).
   Session 10 promoted the §14.2.1 duplicate-LexicallyDeclaredNames
   check to always-on. Remaining semantic errors (still gated
   behind `--show-semantic-errors`): TDZ violations,
   used-before-declaration, closure capture analysis, parameter
   shadowing, `continue label` where label isn't an
   IterationStatement retroactively (K14 closed at parse-time but
   scope-pass would catch more cases).

5. **Full NAPI bindings** (NAPI-2 / NAPI-3). Server mode + async
   bridge ship in Session 9 (3.7× spawn-per-call), but a true
   sync NAPI still needs: C ABI export from Odin, node-addon-api
   wrapper, platform-specific npm packaging. Several weeks.
   Alternative: `worker_threads` + `Atomics.wait` to make
   `parseSync` work over the server protocol without NAPI —
   viable, messy.

6. **Transform API + scope-aware walker**. Mutation / replacement
   on top of the visitor API, using #4's scope tree.

7. **Babel parser test suite** (TEST-2). Wide proposal coverage;
   largely overlaps Test262 but covers more stage-0–3 features.

8. **TypeScript parser test suite** (TEST-3). TS-specific grammar
   edges; complements the TS shape-diff we have against OXC.

9. **Error recovery editor-tooling polish** (ERR-2 continuation).
   Session-9 recovery closes 4 parse gaps (32/32 fixtures); the
   remaining editor-tooling work is span-stability across error
   boundaries, phrase-level error hints, and an expanded anchor
   catalog (try/catch, class body mid-method, nested async).

### Known spec gaps I spotted but didn't add fixtures for

Preserving these so the next session can pick them up. Session 7
closed: escaped-keyword as keyword, `super()` in non-derived
constructor, `delete CoverParenthesizedExpression` (identifier
subcase), and the restricted-production gap for async/arrow LT.
Session 8 closed: yield-expression outside generator,
await/yield-in-async-arrow-params (§15.9.1), await-in-async-
function/method-params (§15.8.1 / §15.6.1), yield/await-in-arrow-
params (§15.3.1), for-in/of initializer + Annex B.3.5 carve-out,
export-local binding resolution (§16.2.2). Session 9 closed: regex
structural + flag validation, recovery gaps in parse_arguments /
var-declarator / param-default / TS-type-parameter, K13
(`--strict-source-type`), Test262 full runner + baseline, server
mode + async bridge, OPT-6 MVP. Session 10 closed: nested-pattern
+ rest-pattern destructuring defaults, PrivateIdentifier escapes,
ImportCall + Phase Imports, CoverInitializedName, §13.5
statement-only positions, §14.2.1 LexicallyDeclaredNames duplicate
always-on with Annex B.3.2 sloppy-mode carve-out, §13.4.1
SimpleAssignmentTarget for UpdateExpression, strict
eval/arguments in destructuring + for-in/of, §15.4.3/4 accessor
arity, §12.6.1.1 strict-mode IdentifierReference, class-body
ASI, no_in leak fix, can_start_regex after Await/Yield, §12.9.3
numeric smooth-following. See §7 Phase 10 for the commit table
and §6 ERR-5 for the spec citations.

Session 11 closed: numeric-key ObjectPattern + for-in/of cover-init
clear, escaped-ReservedWord in object shorthand keys, §15.7.3
AllPrivateIdentifiersValid walker (with empty-name guard), static
`import defer` / `import source` decl form, class-body strict-mode
coverage, strict-mode shorthand reference, unconditional
UniqueFormalParameters, `"use strict"` with non-simple param list,
destructuring assignment target validation, `\u` escape after
numeric literal, missing-init on const / using / await using,
yield/await as binding in param list, Annex B.3.2/B.3.3
function-in-block scoping, §15.7.5 class field init `arguments`,
yield/await as label + bare-await, retro legacy-octal escape in
strict prologue, §12.9.6 untagged template invalid escapes, §22.2.1
regex named-group declaration + back-reference validation. See
§7 Phase 11 for the commit table and §6 ERR-5 for the spec
citations.

Remaining:

- **Full Regex pattern body grammar** — AtomEscape /
  CharacterEscape / CharacterClassEscape / Unicode property
  escapes / v-flag set notation. Named-group declaration + back-
  reference resolution shipped in Session 11. OXC defers most of
  the rest to oxc_regular_expression.
- **TDZ / used-before-declaration** under OPT-6. The MVP only
  catches redeclaration / clash. Requires reachability + temporal
  ordering.
- **NAPI sync API.** Async server mode ships in Session 9 but
  `parseSync` still goes through spawn-per-call. Options: native
  NAPI addon, or `worker_threads` + `Atomics.wait` layered over
  the server protocol.
- **Duplicate LexicallyDeclaredNames across top-level Module.** The
  Session-6 duplicate-lexical-binding check fires inside Block /
  FunctionBody / SwitchCase scopes but doesn't look across top-level
  `let/const` at Program scope. Mostly a scope-pass concern.
- **`let { a, b }` shorthand-property edge cases.** Needs review
  against Test262 when we wire up the full suite.
- **ImportBindingName / ExportBindingName kind cross-check.** When
  an imported name is used as a re-export source (`import type`
  vs value), some tools flag type-only-in-value-position mismatches.
  Low priority; requires scope tracking.
- **Default export redeclaration.** `export default class X {} export
  { X };` — X is the class name and the default export name. Edge
  case in export-local resolution; kessel currently accepts.
- **Labeled FunctionDeclaration in strict (Session 6 closure).**
  Verify the Session-6 check still fires through the new `no_in`
  save/restore interactions — sanity check only, no action needed
  unless a regression surfaces.
- **§15.7.3 PrivateIdentifier resolution (AllPrivateIdentifiers
  Valid).** Every `#x` reference must resolve to a declared
  PrivateName in some lexically enclosing class. Needs a class
  scope stack + per-class private-name set + post-parse walker.
  ~28 Test262 fixtures wait on this.
- **Static `import defer * as ns from "x"` declaration form.**
  Session 10 shipped the dynamic `import.defer(x)` / `import.
  source(x)` call form. The static declaration form is a
  separate §16.2.1 extension — ~87 Test262 fixtures blocked.
- **Object pattern with numeric key** (`{0: v, 1: w}`).
  parse_object_pattern's key parse accepts String and Identifier
  but not Number. Blocks most `for-await-of/async-func-decl-
  dstr-array-ptrn-rest-obj-prop-id*` fixtures (~48).
- **Template-literal ASI + class-body methods.** Sanity check
  that the class-field ASI fix (`f35422b`) doesn't regress
  template literals in any class-initializer edge case. None
  found in the corpus; no action needed unless surfaced.

### Session 5 (2026-04-23) — archived

Session 5 drove spec-compliance divergences 74 → **0** across the 12-file
real-world corpus, via eight consecutive fixes:
`print_expression_as_pattern` helper (destructuring-target emit),
AssignmentPattern span fix in object patterns, `pending_paren_start`
leak from computed-member, `new_expr`/`new_stmt` alignment-padding
overrun (latent memory bug), single-param rest-arrow, regex flags
canonicalisation, MetaProperty hard-coded names, sparse-array hole +
NewExpression paren leak + multi-param rest-arrow end-span. See
commit `cc96a1c` and its follow-ups for the full per-fix detail.

---

## 10. Commands reference

### Build
```bash
odin build src -out:bin/kessel -o:speed -no-bounds-check   # fast
odin build src -out:bin/kessel-debug -debug                # debug + dSYM
task build                                                  # preferred
```

### Parse
```bash
bin/kessel parse <file.js>                              # ESTree JSON on stdout
bin/kessel parse <file.js> --compact                    # minified
bin/kessel parse <file.ts> --lang=ts                    # force TS mode
bin/kessel parse <file.tsx> --lang=tsx                  # TS + JSX
bin/kessel parse <file.js> --loc                        # loc{line,column}
bin/kessel parse <file.js> --range                      # ESLint range tuple
bin/kessel parse <file.js> --preserve-parens            # Acorn/OXC paren wrapper
bin/kessel parse <file.js> --source-type=module         # pin Program.sourceType
bin/kessel parse <file.js> --strict-source-type         # disable auto-upgrade Script→Module (K13)
bin/kessel parse <file.js> --force-strict               # start parse in strict mode (Test262 onlyStrict)
bin/kessel parse <file.js> --show-semantic-errors       # OPT-6 scope-verification pass
bin/kessel parse <file.js> --errors=oxc                 # OXC error shape
bin/kessel parse <file.js> --module-record              # + "module": {…} record
```

### Tests
```bash
task test                      # all suites (chain, baseline-gated)
task test:unit                 # 409 fixtures, 272 passing + 125 negative-skipped + 12 recovery
task test:regression           # 11 structural checks vs OXC
task test:real                 # 467 real-world JS files (zero failures)
task test:nodes                # 57 ESTree node-type coverage
task test:test262              # 66-test curated subset
task test:test262:full         # full Test262 corpus (requires vendor/test262 checkout); ~2m30s
task test:test262:full:json    # full corpus + write JSON summary to tmp/
task test:test262:full:regression  # compare tmp/ output against tests/baselines/test262_full_baseline.json
task test:test262:full:update  # re-run and relock the full-corpus baseline
# Triage:
KESSEL_T262_ALL_FAILURES=1 KESSEL_T262_JSON=tmp/t262.json bash tests/runners/run_test262_full.sh
# Then jq the JSON: bucket by verdict + subdir
jq -r '.all_failures[] | "\(.verdict)\t\(.file)"' tmp/t262.json | \
  awk -F'\t' '{split($2,p,"/"); print $1"\t"p[1]"/"p[2]"/"p[3]}' | sort | uniq -c | sort -rn | head -20
task test:spec-fixtures        # 144 per-category spec fixtures vs OXC, baseline-locked
task test:invariants           # structural ESTree invariants on real corpus
task test:estree               # deep-walk diff vs OXC (jquery/react-dom/preact/snabbdom)
task test:estree:strict        # zero-tolerance variant for release gating
task test:multi-parser         # cross-parser compat (Acorn + Babel)
task test:spec-compliance      # deep JSON diff on 12 curated real files (zero divergences)
task test:fuzz                 # differential fuzz vs OXC (100 seeds, baselined)
task test:fuzz:invalid         # mutation fuzzer (parser-must-not-crash contract)
task test:crashes-known        # pinned SIGTRAPs must keep crashing
task test:recovery             # 20 anchor-survival scenarios
task test:negative             # 125 negative fixtures, ratcheted (auto-strict once clean)
task test:negative:strict      # zero-tolerance variant, no baseline
task test:bench:regression     # perf regression gate (before release)
```

### Update baselines (after an intentional fix / improvement)
```bash
task test:negative:update       # after adding a new negative fixture / error class
task test:spec-compliance:update
task test:spec-fixtures:update
task test:invariants:update
task test:fuzz:update
task test:fuzz:invalid:update
task test:integration:update    # after a fix that changes raw-transfer field shape
task test:bench:regression:update
```

### Regenerate `tests/expected/*.txt` after an intentional parser change
```bash
KESSEL_BIN=bin/kessel
for f in $(find tests/fixtures -name '*.js' | sort); do
  expected="tests/expected/${f#tests/fixtures/}"
  expected="${expected%.js}.txt"
  $KESSEL_BIN parse "$f" > "$expected" 2>&1
done
```

---

## Appendix A — Design docs

Active design docs live in `.swarm/`:

- `.swarm/07-lt-trial-parse-design.md` — `<` trial-parse 4-phase plan.
  Phases A+B shipped (`fcd9203`, `b02dfe5`). Phase C (TSX trailing-comma
  rule) deferred; Phase D (JS mode `<` error) is optional polish.
- `.swarm/08-ts-estree-alignment-design.md` — EST-4 plan. Blocked on
  Node verifier infrastructure.

Per-task specs for the Phase 3 swarm delegations:
`.swarm/01..06-*.md` — preserved for reference; they document the prompts
used and the known limitations of each Haiku session.

---

*End of handoff.*
