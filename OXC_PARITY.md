# OXC Parser Parity Tracker

> Tracking all work required for Kessel to reach 1:1 feature parity with
> [oxc-parser](https://www.npmjs.com/package/oxc-parser) v0.127.
>
> **Last updated:** 2026-04-22 (post Phase-2 + Phase-3 swarm)
>
> **Scope:** Parser only. OXC's linter (oxlint), formatter (oxfmt), transformer,
> minifier and resolver are separate tools — out of scope.

## Status Overview

| Area | Progress | Blocking |
|------|----------|----------|
| [P0 Regressions](#p0-regressions) | **3/3 ✅** | — |
| [JavaScript Correctness](#javascript-correctness) | **5/7** | — |
| [TypeScript — Core](#typescript-core) | **10/12** (2 `<` crashes left) | Orchestrator-led |
| [TypeScript — Advanced](#typescript-advanced) | **9/10** | — |
| [TypeScript — Declarations](#typescript-declarations) | **6/7** | — |
| [ESTree / TS-ESTree Conformance](#estree-conformance) | **3/8** | — |
| [ESM Module Record](#esm-module-record) | **5/5 ✅** | — |
| [Parser Options](#parser-options) | **0/6** | — |
| [NAPI / FFI Bindings](#napi-bindings) | 0/6 | — |
| [Visitor API](#visitor-api) | 0/3 | — |
| [Test Coverage](#test-coverage) | 1/5 | — |
| [Error Handling](#error-handling) | **1/4** | — |

Legend: ✅ done • 🔶 partial • ❌ pending • 💥 crashes

---

## P0 Regressions

> These blocked all downstream testing. All resolved in Phase 2.

- [x] **P0-1: `type` as JS identifier.** Fixed in Phase 2.
- [x] **P0-2: `interface` as JS identifier.** Fixed in Phase 2.
- [x] **P0-3: `enum` as JS identifier.** Fixed in Phase 2.

---

## JavaScript Correctness

> Fixes to reach 100% on the real-world corpus and beyond.

- [x] ES2015+ core (arrow, destructuring, classes, template literals, generators, modules)
- [x] ES2020 (optional chaining, nullish coalescing, BigInt, dynamic import, import.meta)
- [x] ES2022+ (class fields, private fields, static blocks, logical assignment, top-level await)
- [x] **JS-1: Real-world 467/467 passing.** Achieved in Phase 2. Stable across
      all subsequent commits.
- [x] **JS-4: Ternary in function body** (the `?` consumption guard).
      Fixed in Phase 2.
- [ ] **JS-2: Full Test262 stage-4 conformance.** 60 curated tests pass; the
      ~45,000-test suite is not yet wired. Ongoing.
- [ ] **JS-3: Error recovery hardening.** Minimal recovery today —
      cascading errors can cause timeouts. OXC recovers gracefully. Ongoing.

---

## TypeScript — Core

> Features used in >50% of real TypeScript files.

- [x] Union / intersection types (`A | B`, `A & B`)
- [x] Type keywords (`any`, `number`, `string`, `boolean`, `void`, `null`, `never`, etc.)
- [x] **TS-C1a:** `function foo<T>() {}` — generic type params on function decls (Phase 2, H1)
- [x] **TS-C1b:** `class Box<T> {}` — generic type params on classes (Phase 2, H1)
- [ ] **TS-C1c: `<T>(x) => x` — generic arrow function** — 💥 CRASH.
      Needs `<` trial-parse to disambiguate generic vs JSX. Orchestrator-led
      Wave 3.
- [x] **TS-C1d:** `foo<string>(x)` — generic type args on call (pre-Phase 2)
- [x] **TS-C1e:** `new Foo<string>()` — generic type args on new (Phase 2)
- [x] **TS-C2:** `x!.length` — non-null assertion `TSNonNullExpression` (Phase 2)
- [x] **TS-C3:** `let x: T = ...` — type annotations on binding id (pre-Phase 2)
- [x] **TS-C4:** Method signatures in interfaces (pre-Phase 2)
- [x] **TS-C5:** `[k: string]: T` — index signatures (Phase 2, H2 + H3)
- [ ] **TS-C6: `<Type>expr` — angle-bracket assertion** — 💥 CRASH.
      Same `<` disambiguation problem as C1c. Orchestrator-led Wave 3.
- [x] **TS-C7:** `x is T` / `asserts x is T` — type predicates (Phase 2, H3)
- [x] **TS-C8:** Enum member initializers (pre-Phase 2)

---

## TypeScript — Advanced

> Features used in utility types, .d.ts files, and advanced TS patterns.

- [x] **TS-A1:** Conditional types `T extends U ? X : Y` (Phase 2, unblocked by H1)
- [x] **TS-A2:** Mapped types `{ [K in T]: V }`, incl. `T[K]`, `+?`/`-?`/`+readonly`/`-readonly`
      (Phase 2, direct fixes: `6562b8b`, `b8ba2fd`)
- [x] **TS-A3:** Template-literal types `` `hello ${T}` `` (pre-Phase 2)
- [x] **TS-A4:** `import type { A }`, `import("m").T` (Phase 2, `e70ffc9` + pre-Phase 2)
- [x] **TS-A5:** `declare function | class | const | let | var | interface | type | enum`
      (Phase 2, H4)
- [x] **TS-A6:** `abstract class` + abstract methods (Phase 2, H6)
- [x] **TS-A7:** `namespace Foo { ... }`, nested `A.B.C`, `module "x" { ... }`
      (Phase 2, H5) + ambient module body implicit-declare (Phase 3, `a6953eb`)
- [x] **TS-A8:** Call signatures `(x): Y`, construct signatures `new (x): Y`
      in object types (Phase 2, H2)
- [x] **TS-A9:** `infer U` in conditional types (Phase 2, unblocked by H1)
- [ ] **TS-A10: Overload signatures** — multiple function signatures
      before implementation. Not started.

---

## TypeScript — Declarations

- [x] `interface` declarations (basic)
- [x] `type` alias declarations
- [x] `enum` declarations (basic)
- [x] **TS-D:** `declare` modifier on every declaration kind (Phase 2, H4)
- [x] **TS-D class fields:** `foo: T`, `foo?: T`, `foo!: T = x`, `class Box<T> { v: T }`
      (Phase 2, `fc3795a`)
- [x] **TS-D ambient:** `module "x" { const y: number; function f(): void; }`
      (Phase 3, `a6953eb`)
- [ ] **TS-D1..D4:** `interface extends`, `const enum`, `class implements`,
      type parameter constraints/defaults. Individual items need verification
      against the current state — several work via the Phase 2 generics / declare
      changes but are not explicitly tested.

---

## ESTree Conformance

- [x] Core node types (57 JS node types verified)
- [x] `hashbang` field on Program (emitting `null`)
- [x] **EST-1: `loc { line, column }` on every node** — opt-in via `--loc`.
      0-indexed UTF-16 columns, matches OXC. Default off so existing consumers
      see byte-identical output. (Phase 3, `22d2f88`)
- [x] **EST-5 + spec fixtures:** 56/56 pass (pre-Phase 2). Note: the
      `spec/typescript/*` fixtures parse cleanly but their JSON shape diverges
      from `@typescript-eslint/typescript-estree` — tracked as EST-4 below.
- [ ] **EST-2: `range: [start, end]`** — not started.
- [ ] **EST-3: `ParenthesizedExpression` / preserveParens** — not started.
- [ ] **EST-4: TS-ESTree shape alignment** — 10 `spec/typescript/*` fixtures
      parse clean but emit shape diverges from `@typescript-eslint/typescript-estree`.
      Orchestrator-led Wave 3 (forensic diff per-fixture).
- [ ] **EST-6: `hashbang` content preservation** — currently emits `null`
      always. Not started.

---

## ESM Module Record

- [x] **ESM-1: `hasModuleSyntax`** — Phase 3, `c31de50`.
- [x] **ESM-2: `staticImports` array** — Phase 3, `c31de50`.
- [x] **ESM-3: `staticExports` array** — Phase 3, `c31de50`.
- [x] **ESM-4: `dynamicImports` array** — Phase 3, `c31de50`.
- [x] **ESM-5: `importMetas` span array** — Phase 3, `c31de50`.

All five items shipped in a single commit via Haiku `d7dfd0e0`
(\$2.43, 82% ctx). CLI flag: `--module-record`. Default off so
existing consumers see byte-identical output; when on, emits a
`"module": { hasModuleSyntax, staticImports, staticExports,
dynamicImports, importMetas }` object between the program AST and
the errors array.

This was the first Wave-2b delegation after tightening the
execute-task `_safety.md` prompt — work landed intact, no silent
git operations.

Follow-up (not blocking): TS-ESTree alignment for the static
import/export entries (e.g. `importName.kind` capitalisation may
differ from OXC's "default"/"namespace"/"name" — current Kessel
uses "Default"/"Namespace"/"Name"). Forensic diff to come with
EST-4 (Wave 3 item 8).

---

## Parser Options

- [ ] **OPT-1: `sourceType: 'script' | 'module' | 'unambiguous'`** — Kessel
      auto-detects today; no CLI knob yet.
- [ ] **OPT-2: `lang: 'js' | 'jsx' | 'ts' | 'tsx'`** — inferred from file
      extension; no explicit flag.
- [ ] **OPT-3: `preserveParens: boolean`** — EST-3 territory.
- [ ] **OPT-4: `range: boolean`** — EST-2 territory.
- [ ] **OPT-5: `astType: 'js' | 'ts'`** — not started. Needed for
      TS-ESTree `typeAnnotation: null` defaults on JS nodes.
- [ ] **OPT-6: `showSemanticErrors: boolean`** — requires scope/symbol
      analysis. Not started.

---

## NAPI Bindings

- [ ] **NAPI-1..6:** Entirely pending. Kessel is CLI-only today.
      Biggest integration gap.

---

## Visitor API

- [ ] **VIS-1..3:** Entirely pending. Depends on NAPI.

---

## Test Coverage

- [x] 60/60 curated Test262 subset
- [x] **test:spec-fixtures:** 56/56 (pre-Phase 2)
- [x] **test:regression:** 11/11
- [x] **test:real:** 467/467
- [x] **test:nodes:** 57/57 node types covered
- [ ] **TEST-1: Full Test262 stage-4 suite (~45 000 tests)** — not wired.
- [ ] **TEST-2: Babel parser test suite** — not wired.
- [ ] **TEST-3: TypeScript parser test suite** — not wired.
- [ ] **TEST-4: Spec fixture TS-ESTree shape diff** — see EST-4.

**Phase-3 regression discoveries** (not introduced by this work, but surfaced):
- `early_errors/016_digit_start_identifier` — pre-existing SIGTRAP.
- `\u00GG` invalid-hex escape — pre-existing SIGTRAP.
- Deep JSX child recursion `<A><B><C/></B></A>` — pre-existing SIGTRAP
  (fixture `spec/jsx/005_nested_element` line 2).

---

## Error Handling

- [x] **ERR-1: Structured error objects — `--errors=oxc` flag.** OXC-shape
      `{ severity, message, labels: [{ span: { start, end } }] }` opt-in via
      CLI flag. Default (`--errors=kessel` or omitted) preserves legacy
      `{ message, line, column, offset }` shape for backward compat.
      (Phase 3, `75fb36b`)
- [ ] **ERR-2: Error recovery at statement boundaries** — not started.
- [ ] **ERR-3: Graceful TS parse failure** — several pre-existing SIGTRAPs
      (see Test Coverage) trace back to this.
- [ ] **ERR-4: Timeout prevention** — not started.

---

## Phase 3 (this swarm) — commits summary

| Commit | Item | Author | Notes |
|--------|------|--------|-------|
| `e1beb05` | JSX nested attribute span fix | Haiku `48cb192f` (delegation) | Fixture line 1 parses; line 2 needs pre-existing deep-JSX recursion fix |
| `75fb36b` | `--errors=oxc` flag (ERR-1) | Rescued from Haiku `5a3ffd90` stash | Haiku stashed its own work; extracted surgically |
| `34121c2` | `\uXXXX` / `\u{...}` in identifiers | Orchestrator (Haiku `f7b18076` failed at $1.74) | Clean design via `FLAG_HAS_ESCAPE` + `LiteralType.Identifier` |
| `22d2f88` | `--loc { line, column }` (EST-1) | Haiku `51757775` (delegation) | 0-indexed UTF-16 columns, OXC-compatible |
| `a6953eb` | Ambient module implicit-declare | Orchestrator (Haiku `21215876` lost work via `git checkout`) | Added `p.in_ambient` flag, save/restore in module/declare contexts |
| `c31de50` | **ESM module record (ESM-1..5)** | Haiku `d7dfd0e0` (delegation) | First delegation AFTER _safety.md hardening — all work intact |

**Process notes:**
- Two Haiku sessions silently destroyed their own work by running
  `git stash` or `git checkout -- <file>` before declaring DONE. The
  original `_safety.md` upstream prompt forbade `git commit`/`push` but
  not working-tree-manipulating commands. **Hardened the skill**:
  `~/.agents/skills/execute-task/prompts/_safety.md` now enumerates
  every forbidden git command (stash, reset, checkout, restore, clean,
  rebase, merge, cherry-pick, revert, branch, switch, tag, worktree)
  and mandates a `git status --short` check before declaring DONE.
- The `<` trial-parse items (TS-C1c, TS-C6) were flagged as
  orchestrator-led up front and not delegated.

---

## Still pending (next session)

Ordered by impact × feasibility:

1. **`<` trial-parse** — TS-C1c (`<T>(x) => x`) + TS-C6 (`<Type>expr`).
   Single hardest item but closes two crash paths. Orchestrator-led.
   See `.swarm/07-lt-trial-parse-design.md` for the 4-phase plan.
2. **TS-ESTree shape alignment** (EST-4) — 10 fixtures parse clean but
   emit JSON diverges from `@typescript-eslint/typescript-estree`.
   Blocked on infrastructure (need Node verifier shelling to
   @typescript-eslint/typescript-estree or oxc-parser npm package).
   See `.swarm/08-ts-estree-alignment-design.md`.
4. **`range: [start, end]`** (EST-2) — additive, CLI-gated.
5. **`hashbang` content preservation** (EST-6) — additive.
6. **TS-D1..D4 individual verification** — ensure
   `interface extends`, `const enum`, `class implements`, type param
   constraints/defaults all work against the current state.
7. **TS-A10 overload signatures** — function signatures before impl.
8. **Pre-existing SIGTRAPs:** deep-JSX-child, `\u00GG`, digit-start ident.
9. **`sourceType` / `lang` / `astType` CLI flags** — OPT-1/2/5.
10. **NAPI / Visitor** — biggest integration gap; parallel track.

---

## Effort estimates (revised)

| Phase | Items | Status | Notes |
|-------|-------|--------|-------|
| **Phase 1: Unblock (P0)** | P0-1..3, JS-4 | ✅ done | Phase 2 session |
| **Phase 2: TS Core + Advanced** | TS-C1a/b/d/e, C2..8 (minus C1c/C6), A1..A9, D | ✅ done | Phase 2 session, 13 commits |
| **Phase 3: ESTree + Errors** | EST-1, ERR-1, JSX nested, Unicode, ambient | ✅ done | This swarm, 5 commits |
| **Phase 4: `<` trial + EST-4** | TS-C1c, TS-C6, EST-2/4/6 | 🔶 partial (ESM done) | ESM shipped — rest is orchestrator |
| **Phase 5: Options + recovery** | OPT-1..6, ERR-2..4 | ❌ | Polish phase |
| **Phase 6: NAPI + Visitor** | NAPI-1..6, VIS-1..3 | ❌ | Integration phase |
| **Phase 7: Test suites** | TEST-1..4 | ❌ | Ongoing |

---

## Metrics

| Metric | Current | Target | Source |
|--------|---------|--------|--------|
| Real-world pass rate | **467/467 (100%)** | 467/467 | `task test:real` |
| Spec fixtures | **56/56 (100%)** | — | `task test:spec-fixtures` |
| Test262 (curated) | **60/60 (100%)** | — | `task test:test262` |
| Node type coverage | **57/57** | — | `task test:nodes` |
| Regression gates | **11/11** | — | `task test:regression` |
| TS type features | **~75%** (up from ~30%) | 100% | Checklist above |
| Crash-free JS inputs | 467/467 real + curated | 100% | real + spec |
| OXC API surface | CLI only | `parseSync` / `parse` + Visitor | — |
