# Full OXC Substitution Roadmap

## Goal

Make `@dvrdlibs/kessel` a complete drop-in replacement for the OXC toolchain
(`oxc-parser`, `oxc-codegen`, `oxc-transformer`, `oxc-resolver`,
`oxc-minifier`, `oxlint`, `oxfmt`) — across every published surface OXC
exposes today.

This is a multi-month roadmap, not a single sprint. Sequenced so each tier
ships something usable on its own.

---

## Tier 0 — Parser (done)

- Conformance: 100% test262 / Babel / TypeScript / ESTree / Misc, both
  positive and negative.
- AST: full ESTree + JSX + TS.
- Performance: 8–17% faster than OXC at the npm boundary.
- Semantic checker (pass 3) enforces ECMA early errors.

Open items inside Tier 0:

- [ ] Close 7 ambiguity divergences in
  `tests/baselines/ambiguity_known_failures.txt`. Each is a TSX/TS-overlap
  edge case with a known fixture.

---

## Tier 1 — Codegen completeness

Today's codegen is a scaffold. AST nodes exist for all syntax, but emitter
stubs for TS-only constructs are placeholder comments (`/*interface*/`).

### 1.1 Complete TS declaration codegen (in flight)

Replace stub emitters in `src/codegen_impl.odin` with real source emission:

- [ ] `gen_ts_interface_declaration`
- [ ] `gen_ts_type_alias_declaration`
- [ ] `gen_ts_enum_declaration`
- [ ] `gen_ts_module_declaration`
- [ ] `gen_ts_import_equals`
- [ ] `gen_ts_export_assignment`
- [ ] `gen_ts_namespace_export`

### 1.2 Complete `gen_ts_type` for every TS type form

In `src/codegen_helpers.odin`. Replace placeholder branches:

- [ ] `TSFunctionType` / `TSConstructorType` (full param list + return)
- [ ] `TSTypeLiteral` (member list)
- [ ] `TSConditionalType`, `TSInferType`
- [ ] `TSTypeQuery` (`typeof`), `TSTypeOperator` (`keyof`/`unique`/`readonly`)
- [ ] `TSIndexedAccessType`
- [ ] `TSMappedType`
- [ ] `TSLiteralType`, `TSTemplateLiteralType`
- [ ] `TSTypePredicate`, `TSImportType`
- [ ] `TSInstantiationExpression` (`<...>` arguments)

### 1.3 Codegen-side TS preservation

Class/function/variable nodes need to emit:

- [ ] `typeAnnotation` on identifiers, params, and class members
- [ ] `typeParameters` on functions, classes, methods
- [ ] `typeArguments` on call/new expressions
- [ ] `importKind` (`type` / `typeof`) on import declarations
- [ ] `accessibility`, `readonly`, `override` modifiers on class members
- [ ] `declare` keyword on declarations

Acceptance: every entry in `tests/baselines/codegen_known_failures.txt`
gets removed and the verifier reports 255+ pass.

### 1.4 Source maps v3

Today's codegen has no sourcemap output. Every downstream consumer
(bundlers, debuggers, error renderers) requires v3 sourcemaps.

- [ ] Reuse `src/emitter.odin`'s line-offset table machinery.
- [ ] Implement VLQ encoder.
- [ ] Add `--sourcemap` and `--sourcemap=inline` to `kessel codegen`.
- [ ] Expose `codegen(ast, { sourceMap: true })` in npm API.

---

## Tier 2 — Public traversal + semantic API

Today: read-only visitor only. No public scope graph.

### 2.1 Mutating visitor

- [ ] Add an in-place transform API to `npm/kessel/visitor.js`.
- [ ] `enter(node, parent, key) { return replacementNode | null | undefined }`
- [ ] `leave(node, parent, key)` for post-order rewrites.
- [ ] Path object (parent chain, sibling index, removal).

### 2.2 Scope / binding API

`src/checker.odin` already computes most of this internally; surface it.

- [ ] Public `Scope` and `Binding` records on the AST.
- [ ] Resolve `Identifier` → declaring `Binding` (or unresolved).
- [ ] Expose via npm: `parse(src, { scope: true })` adds `scope` field.
- [ ] Mirror OXC's `oxc-semantic` API shape.

---

## Tier 3 — Transformer

The big new surface. Without it Kessel cannot replace OXC for any
non-parser use.

### 3.1 TS-erasure transformer

- [ ] Strip `TSInterfaceDeclaration`, `TSTypeAliasDeclaration`,
  `TSModuleDeclaration` (non-`global`) declarations.
- [ ] Strip type annotations, type parameters, type arguments,
  `importKind`, accessibility modifiers, `declare` keyword.
- [ ] Lower `enum` to immediately-invoked object construction.
- [ ] Lower `namespace` to nested IIFE.
- [ ] Lower `import x = require("y")` to CJS require.
- [ ] Lower `TSAsExpression`, `TSSatisfiesExpression`,
  `TSNonNullExpression`, `TSTypeAssertion` to their inner expression.
- [ ] Lower parameter properties (`constructor(public x: number)`).
- [ ] Lower JSX as casts (`{x as React.ReactNode}` → `{x}`).

### 3.2 JSX transformer

- [ ] Classic mode: `<X />` → `React.createElement(X)`.
- [ ] Automatic mode: `<X />` → `_jsx(X)` + import injection.
- [ ] Fragments: `<></>` → `React.Fragment` / `_jsx(Fragment)`.
- [ ] Configurable pragma + jsxImportSource.

### 3.3 ES syntax downleveling

Match OXC's transformer targets:

- [ ] Optional catch binding
- [ ] Numeric separators
- [ ] Logical assignment operators
- [ ] Nullish coalescing
- [ ] Optional chaining
- [ ] Object spread
- [ ] Async/await → generators
- [ ] Async iteration
- [ ] Classes (fields, private, static blocks)
- [ ] Decorators (legacy + standard)

This is the most syntax-coverage-heavy item — months of work.

---

## Tier 4 — Resolver

OXC's resolver is widely depended on (Vite, Rspack, Rolldown).

- [ ] Node module resolution algorithm.
- [ ] `package.json` `exports` / `imports` field.
- [ ] `tsconfig.json` `paths`, `baseUrl`, `extends`.
- [ ] Conditions (`import`, `require`, `node`, `browser`, etc.).
- [ ] Symlinks + realpath resolution.
- [ ] pnpm-style virtual store handling.
- [ ] Cache layer for repeated lookups.

Roughly 2–4 weeks. Mostly mechanical, well-spec'd.

---

## Tier 5 — Minifier

Real minification (Terser/SWC parity), not just whitespace removal.

- [ ] Name mangling (preserve eval/with semantics).
- [ ] Dead code elimination.
- [ ] Constant folding.
- [ ] Inlining of single-use functions/constants.
- [ ] Property mangling (opt-in).
- [ ] Statement-level transforms (`if (x) {} else {}` collapse, etc.).
- [ ] Sourcemap-aware output.

Multi-month project.

---

## Tier 6 — Formatter

Prettier/oxfmt parity is a years-long effort.

- [ ] Doc-builder / pretty-printer IR.
- [ ] Operator-precedence-aware breaks.
- [ ] Long-line splitting heuristics.
- [ ] Comment preservation across reformat.
- [ ] Config compatibility (`.prettierrc` subset).
- [ ] Trailing-comma / quote-style / arrow-paren options.

Multi-month project.

---

## Tier 7 — Linter

oxlint ships ~500 rules. Building that is a years-long effort.

- [ ] Rule SDK: visitor + context + reporter + autofix API.
- [ ] Config file format (ESLint-compat or new schema).
- [ ] Built-in rule set (start with ~30 high-value rules).
- [ ] Plugin loading.
- [ ] Autofix / `--fix` mode.
- [ ] Sourcemap-aware diagnostic positions.
- [ ] Performance: must parse-once-walk-many.

Multi-year if comprehensive; a useful subset is achievable in months.

---

## Recommended execution order

Each tier ships independently. Order optimized for fastest user value:

1. **Tier 0 closeout** — 7 ambiguity divergences. ~3–5 days.
2. **Tier 1.1 + 1.2 + 1.3** — TS codegen completeness. ~2 weeks. Unlocks
   round-trip codegen and is the foundation for Tier 3.
3. **Tier 1.4** — Sourcemaps. ~1 week. Required by every downstream tool.
4. **Tier 2.1 + 2.2** — Visitor + scope API. ~2 weeks. Foundation for
   Tier 3, 5, 7.
5. **Tier 3.1** — TS-erasure transformer. ~2 weeks. Ships the most-wanted
   single transformer.
6. **Tier 3.2** — JSX transformer. ~1 week.
7. **Tier 4** — Resolver. ~3 weeks.
8. **Tier 3.3** — ES syntax downleveling. ~2 months.
9. **Tier 7** — Linter SDK + 30 rules. ~2 months.
10. **Tier 5** — Minifier. ~3 months.
11. **Tier 6** — Formatter. ~6 months.

Total to full OXC parity: roughly 12–18 person-months.

---

## Verification gates added per tier

- Tier 1: extend `verify_codegen` known-failures shrinks toward zero;
  add `verify_sourcemap_roundtrip`.
- Tier 2: add `verify_visitor_mutating` and `verify_scope_resolution`.
- Tier 3: per-transformer fixture suites under
  `tests/fixtures/transform/{ts,jsx,downlevel}/`, asserted against
  expected output files.
- Tier 4: vendor the OXC resolver test fixtures; pass them 1:1.
- Tier 5: bench against Terser/SWC on the real_world corpus; assert
  size + correctness (parse output before/after must be semantically
  equivalent).
- Tier 6: snapshot fixtures against Prettier output where compatible.
- Tier 7: per-rule fixtures with code + expected diagnostics + fixed
  output.

Maintain the zero-tolerance release gate (`task test:release`).

---

## This-session deliverable

Tier 1.1 + 1.2: replace stub TS codegen emitters with real source
emission so `tests/baselines/codegen_known_failures.txt` shrinks.
