# Kessel Test Coverage Gap Checklist

Scope: `tests/` only.
Constraint: no edits outside the `tests/` directory.
Purpose: turn `tests/COVERAGE_AUDIT.md` into an actionable checklist of missing or weakly-covered test areas.

## How To Use This Checklist

For each item:
- add or strengthen coverage inside `tests/`,
- prefer minimal, isolated fixtures,
- add a verifier when a golden-output file is too weak,
- prefer one clear product claim per test family,
- avoid hiding gaps behind skips.

Status legend:
- `[ ]` not yet covered well enough
- `[-]` partially covered, but still weak
- `[x]` covered strongly enough for now

---

## Priority 1 — Invalid Programs / Early Errors

Reason: a parser that accepts invalid input is still far from the desired product, even if many valid programs parse.

### General malformed syntax families
- [ ] Unterminated template variants beyond the current sample set
- [ ] Unterminated comments (`/* ...` EOF)
- [ ] Unterminated JSX text / tag / attribute cases
- [ ] Truncated array/object/function/class productions at multiple cut points
- [ ] Broken nested delimiters in deeper contexts, not only top-level
- [ ] Invalid optional-chaining forms
- [ ] Invalid destructuring-assignment forms
- [ ] Invalid spread/rest placement across multiple grammar positions

### Context-sensitive early errors
- [-] `return` outside function — sampled, needs broader variants
- [-] `await` outside async — sampled, needs module/script/context matrix
- [-] `super` outside method — sampled, needs constructor / field / static-block variants
- [-] `break` / `continue` misuse — sampled, needs nested-label matrix
- [ ] `new.target` outside valid contexts
- [ ] `yield` outside generators in more contexts
- [ ] `arguments` / `eval` restrictions in strict mode beyond current sample set
- [ ] Duplicate parameter restrictions across sloppy/strict combinations
- [ ] Duplicate lexical declarations across nested scopes and mixed declaration kinds
- [ ] Duplicate private fields / private name misuse in classes

### Module vs script rule coverage
- [ ] `import` in script goal where unsupported
- [ ] `export` in script goal where unsupported
- [ ] top-level `await` in script vs module matrix
- [ ] `import.meta` context restrictions matrix
- [ ] module-only early errors beyond current fixture sampling

### Reserved words / strict-mode coverage
- [-] strict-mode reserved words — sampled, expanded with `tests/fixtures/early_errors/strict_mode/`
- [ ] sloppy-vs-strict matrix for `implements`, `interface`, `package`, `private`, `protected`, `public`, `static`, `yield`
- [ ] contextual keyword acceptance/rejection by syntactic position

### Invalid escapes / literals / regex syntax
- [-] invalid unicode/hex escape coverage — sampled, needs expansion
- [ ] invalid legacy octal cases matrix
- [ ] invalid bigint literal forms
- [ ] invalid numeric separator placements
- [ ] invalid regex group / class / quantifier forms
- [ ] invalid regex flags combinations
- [ ] invalid unicode escapes inside identifiers in more positions

---

## Priority 2 — Dialect Ambiguity: JS / TS / JSX / TSX

Reason: ambiguity surfaces are among the highest-risk parser areas and are not yet systematically mapped.

### JSX vs TypeScript ambiguity
- [-] angle-bracket type assertion vs JSX — sampled by one failing case, needs family
- [ ] generic call vs relational-expression ambiguity cases
- [ ] generic arrow/function syntax in ambiguous positions
- [ ] nested `<T>() => ...` style ambiguities
- [ ] TSX-specific ambiguity fixtures if TSX is intended to be supported

### JSX structure families
- [-] nested JSX elements — sampled, but not broadly covered
- [ ] JSX attribute values containing nested JSX across multiple depths
- [ ] JSX spread + boolean + expression attributes in one element
- [ ] JSX fragments nested inside attributes / children combinations
- [ ] namespaced/member/self-closing combinations beyond current samples
- [ ] malformed JSX recovery cases

### TypeScript syntax breadth
- [-] generic declarations — sampled, but shallow
- [-] mapped / conditional / predicate types — sampled, but shallow
- [ ] `declare`, `namespace`, `abstract`, `readonly`, `override`
- [ ] interfaces with heritage and complex members
- [ ] enum variants (const enum, computed members, string members)
- [ ] type-only imports/exports matrix
- [ ] `infer`, `keyof`, indexed access, tuple types, template literal types
- [ ] `as const`, satisfies, assertion chains
- [ ] parameter properties and access modifiers in constructors
- [ ] TS-only module declarations / ambient contexts

---

## Priority 3 — Error Recovery Coverage

Reason: current recovery coverage is useful but far too small to claim confidence in malformed-input behavior.

### Recovery breadth
- [-] top-level malformed token recovery — sampled
- [ ] nested expression recovery
- [ ] statement-list recovery after malformed statements
- [ ] class body recovery
- [ ] object literal recovery
- [ ] array literal recovery
- [ ] parameter list recovery
- [ ] import/export declaration recovery
- [ ] JSX recovery
- [ ] TypeScript syntax recovery

### Recovery quality assertions
- [ ] assert parser resumes at the next stable boundary
- [ ] assert parse-error count stays bounded
- [ ] assert recovered AST contains later valid declarations
- [ ] assert no bogus giant source spans after recovery
- [ ] assert no `Unknown` / unimplemented placeholder nodes leak into recovered subtrees unexpectedly

---

## Priority 4 — Differential Coverage Expansion

Reason: deep comparison against references is strong, but today it is selective.

### More spec fixtures through deep compare
- [x] expand `run_spec_fixtures.js` coverage families if not all intended families are included
- [x] add more JSX fixtures to exact deep-JSON comparison
- [x] add more TypeScript fixtures to exact deep-JSON comparison
- [x] add more unicode / escape families to exact deep-JSON comparison
- [x] add more ASI families to exact deep-JSON comparison

### More multi-parser comparison coverage
- [-] Acorn/Babel comparison now covers JSX/TS/ASI/unicode/escapes, but edge and real-world breadth are still narrow
- [ ] include more `spec/edge` fixtures
- [x] include JSX fixtures where normalization makes comparison meaningful
- [x] include more modern syntax buckets in `verify_multi_parser.js`
- [ ] include more than one real-world “gold standard” file

### More real-world differential coverage
- [ ] broaden the selected real-world file set for OXC deep-compare
- [ ] include files that stress JSX-heavy patterns if product scope includes them
- [ ] include files that stress module syntax heavily
- [ ] include files with more unicode / comment / directive-prologue oddities

---

## Priority 5 — Standards Pressure / Test262

Reason: a 60-file curated subset is helpful smoke coverage, but still weak for language-wide claims.

### Test262 breadth
- [x] curated subset exists
- [x] increase coverage of lexical grammar cases
- [ ] increase coverage of early-error cases
- [x] increase coverage of module grammar cases
- [x] increase coverage of newer ES feature categories
- [x] add category-based tracking so growth is visible per feature family
- [ ] document exactly what the subset is intended to prove

### If only syntax is in scope
- [x] create a syntax-only Test262 intake policy inside `tests/`
- [x] maintain a curated list by grammar family rather than one flat bucket
- [x] separate parser-acceptance tests from runtime-semantic tests clearly

---

## Priority 6 — Feature Interaction Matrix

Reason: current fixtures cover many individual features, but not enough interaction combinations.

### High-risk interactions
- [x] decorators × class fields × private fields × static blocks — `spec/interactions/001`
- [x] async × generators × destructuring × defaults — `spec/interactions/002`
- [x] optional chaining × call/new/member combinations — `spec/interactions/004`
- [x] `for await` × destructuring × defaults — `spec/interactions/003`
- [x] import attributes × export forms × module goal — `spec/interactions/005`
- [x] JSX × async/await expressions inside children/attributes — `spec/interactions/006`
- [x] TypeScript types inside class/method/property-heavy syntax — `spec/interactions/010`
- [x] unicode identifiers inside modern syntax positions, not only simple declarations — `spec/interactions/007`

### Contextual interactions
- [x] directives inside nested blocks / functions / modules — `spec/interactions/008`
- [-] ASI around `return`, `yield`, `await`, postfix operators in newer syntax contexts — sampled by `spec/interactions/009` (regex after ASI) and `spec/asi/*`; not exhaustive yet
- [-] regex/division ambiguity after many more token classes — `spec/lexical/005` + `006` sample comment-boundary; `spec/regex_disambiguation/*` covers token-class variants
- [x] comment/newline interactions around restricted productions — `spec/lexical/002` (CRLF + `return`) and `spec/lexical/005`/`006`

---

## Priority 7 — Lexer / Tokenization Coverage

Reason: many parser failures start as lexer ambiguities, but the current suite mostly observes them indirectly through parse outcomes.

### Tokenization-sensitive surfaces
- [-] more hashbang / BOM / shebang variants — `spec/lexical/001` added (BOM + hashbang); surfaced a real parser gap where BOM hides the hashbang (tracked as known_fail)
- [x] unicode escapes at identifier start and in identifier continuation positions — `spec/lexical/003` + `004`
- [x] ZWJ / ZWNJ in more identifier contexts — `spec/lexical/009`
- [x] comment adjacency around regex/division boundaries — `spec/lexical/005` + `006`
- [x] newline normalization / CRLF-sensitive fixtures — `spec/lexical/002` (CRLF restricted production)
- [x] numeric literal edge forms (separators, bases, bigint suffixes) — `spec/lexical/007` (matrix across every base and suffix)
- [x] template raw/cooked edge cases beyond the current sample set — `spec/lexical/008`

### If no token-level harness is added
- [x] at minimum, add parse-shape fixtures that isolate tokenization decisions one by one — `spec/lexical/*` with `verify_lexical_surfaces.js` asserting per-fixture shape

---

## Priority 8 — ESTree Product-Surface Tightening

Reason: structural verifiers are strong, but there is still room to tighten exactness where the product promise depends on ESTree compatibility.

### Node-shape precision
- [-] node-type presence is covered
- [ ] add more exact path-based assertions for tricky node placements
- [ ] assert more wrapper-node invariants for JSX / TS / chain expressions
- [ ] assert more field-presence invariants for class and module nodes
- [ ] add dedicated fixtures for any node types currently only exercised through complex sources

### Source location fidelity
- [-] containment invariants exist
- [ ] add exact spot-check fixtures for tricky start/end locations
- [ ] add location checks for JSX braces/tags boundaries
- [ ] add location checks for TS wrappers/annotations/assertions
- [ ] add location checks for comments/directives if those are part of product expectations

---

## Priority 9 — Documentation / Visibility Inside `tests/`

Reason: the suite should make progress visible, not just executable.

- [x] add a machine-readable or markdown map from syntax family → owning test(s) — `tests/SURFACE_MAP.md` (human) + `tests/surface_status.json` (machine)
- [x] add a machine-readable map from known parser surface → confidence level — `surface_status.json` carries a `coverage_status` per surface
- [x] add per-family pass/fail summaries where today only aggregate counts exist — `verify_deep_families.js` (per-family), `verify_test262_subset.js` (per-category), `report_surface_status.js` (per-surface)
- [x] document intended support scope for TS / JSX / modern ES explicitly inside `tests/` — `SURFACE_MAP.md` names `ambiguity_ts_jsx`, `interaction_combinations`, `core_syntax` and `lexical_tokenization` as explicit surfaces
- [x] document which verifiers are zero-tolerance vs baseline-gated and why — `surface_status.json` has a `policy` field per surface; `SURFACE_MAP.md` shows it inline in each surface header

---

## Already Strong Enough For Now

These areas appear strong enough that expansion is lower priority than the gaps above.

- [x] Core valid JS statement/expression smoke coverage
- [x] Known regression locking via dedicated regression fixtures
- [x] Basic ESTree node-emission smoke coverage
- [x] Presence of real-world corpus-backed checks
- [x] Presence of fuzzing for both differential and malformed-input cases

---

## Recommended Order Of Work

If improving the suite without touching `src/`, use this order:

1. **Expand invalid / early-error coverage**
2. **Add dialect ambiguity families (TS / JSX / TSX)**
3. **Expand recovery fixtures and add recovery-quality assertions**
4. **Widen deep-diff coverage to more spec families**
5. **Grow Test262 breadth by grammar family**
6. **Add more interaction-matrix fixtures**
7. **Tighten tokenization-sensitive fixtures**
8. **Improve visibility/reporting inside `tests/`**

This order makes the suite better at measuring distance to the desired product before or alongside parser fixes.
