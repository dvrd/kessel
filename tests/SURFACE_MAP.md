# Kessel Test Surface Map

Scope: `tests/` only.
Purpose: map every product surface the test suite makes a claim about to the
fixtures, verifiers, and baselines that own it. If a surface doesn't appear
here, we don't measure it — so adding one here is a commitment to maintain
the supporting tests.

The machine-readable companion is [`tests/surface_status.json`](./surface_status.json).
Run [`tests/verifiers/report_surface_status.js`](./verifiers/report_surface_status.js)
for a live, baseline-aware summary.

## How To Read This Map

Each surface has:

- **Claim** — one sentence that says what the surface asserts about the parser.
- **Owns** — fixtures, verifiers, and baselines that realise the claim.
- **Policy** — `zero-tolerance` (any failure blocks) or `baseline-gated`
  (regressions block; known gaps are tracked so the claim can still be
  partially true).
- **Coverage status** — honest label of how well the surface is measured
  today: `strong`, `medium`, or `weak`.
- **Notes** — what the current status comes from and what would lift it.

Status legend:

| Status    | Meaning                                                                 |
|-----------|-------------------------------------------------------------------------|
| `strong`  | The claim is enforced end-to-end with little-to-no tracked gap.         |
| `medium`  | The claim is partially enforced; the baseline tracks real but bounded gaps. |
| `weak`    | Fixtures exist but no verifier owns the claim, OR the claim is mostly untested. |

## Surfaces

### `core_syntax` — [strong] [zero-tolerance]
- **Claim:** Valid ES2015..ES2025 programs parse without error and emit the
  expected ESTree shape.
- **Fixtures:** `tests/fixtures/basic`, `tests/fixtures/edge`,
  `tests/fixtures/es2015..es2025`, `tests/fixtures/spec/edge`,
  `tests/fixtures/spec/es2015..es2025`.
- **Verifiers:** [`tests/runners/run_tests.sh`](./runners/run_tests.sh),
  [`tests/verifiers/verify_regression.js`](./verifiers/verify_regression.js),
  [`tests/runners/run_spec_fixtures.js`](./runners/run_spec_fixtures.js).
- **Baselines:** `tests/baselines/spec_fixtures_baseline.json`.
- **Notes:** Positive fixtures parse cleanly with pinned golden outputs;
  `run_spec_fixtures.js` runs every hand-authored fixture through deep-diff
  vs OXC.

### `invalid_syntax` — [medium] [baseline-gated]
- **Claim:** Malformed programs are rejected with at least one parse error.
- **Fixtures:** `tests/fixtures/negative/*` (truncation, regex literals,
  numeric literals, and the top-level negative bucket).
- **Verifiers:** [`tests/verifiers/verify_negative.js`](./verifiers/verify_negative.js).
- **Baselines:** `tests/baselines/negative_baseline.json`.
- **Notes:** Parser-negative gate recurses into every subdirectory. Six
  numeric-separator fixtures are still silently accepted and baselined as
  known bugs — lifting to `strong` requires closing those.

### `early_errors` — [weak] [baseline-gated]
- **Claim:** Module-vs-script and strict-mode semantic early errors surface
  at parse time.
- **Fixtures:** `tests/fixtures/early_errors/module_context/*`,
  `tests/fixtures/early_errors/strict_mode/*`, and the flat fixture set.
- **Verifiers:** none yet.
- **Baselines:** none yet.
- **Notes:** Fixtures are staged but unowned. This is the gap that keeps
  the suite from making a full semantic-early-error claim. A future
  `verify_early_errors.js` would lift this to `medium` by exercising the
  fixtures in the right goal (script vs module) and asserting that each is
  rejected.

### `ambiguity_ts_jsx` — [medium] [baseline-gated]
- **Claim:** JS / TS / JSX boundary cases parse deterministically in the
  right grammar mode and match OXC where they should.
- **Fixtures:** `tests/fixtures/spec/ambiguity/*` (10 focused cases).
- **Verifiers:** [`tests/verifiers/verify_ambiguity.js`](./verifiers/verify_ambiguity.js).
- **Baselines:** `tests/baselines/ambiguity_baseline.json`,
  `tests/baselines/ambiguity_known_failures.txt`.
- **Notes:** 3/10 pass both golden and deep compare; 7 are tracked as
  known_fail. Of those seven: one (`004_generic_arrow_vs_relational`) is
  a genuine parser-recovery divergence; the other six are a mode-mismatch
  between `run_tests.sh` (which parses all of `spec/ambiguity/*` in tsx
  mode so the goldens encode the tsx interpretation) and `verify_ambiguity`
  (which parses each fixture in its per-fixture "intent" mode so the AST
  is more precise). Aligning the two gates on one lang choice per fixture
  would lift most of those six to pass.

### `recovery` — [medium] [zero-tolerance]
- **Claim:** Parser recovers from malformed input, reports a bounded number
  of errors, and preserves the anchor declarations that follow.
- **Fixtures:** `tests/fixtures/recovery/{expressions,statements,declarations,jsx_ts}/*`,
  plus the top-level recovery bucket.
- **Verifiers:** [`tests/verifiers/verify_recovery.js`](./verifiers/verify_recovery.js).
- **Baselines:** none (the verifier asserts structural properties directly
  rather than snapshotting counts).
- **Notes:** Each fixture carries `const anchor_after_error = 1;` after the
  malformed region so recovery can be proven by AST content, not error count.

### `differential_estree` — [strong] [baseline-gated]
- **Claim:** Kessel's ESTree JSON matches OXC (and, where normalisable,
  Acorn and Babel) on real and synthetic inputs.
- **Fixtures:** `bench/real_world/*`, `tests/fixtures/spec/*`.
- **Verifiers:** [`verify_json_deep.js`](./verifiers/verify_json_deep.js),
  [`verify_multi_parser.js`](./verifiers/verify_multi_parser.js),
  [`verify_deep_families.js`](./verifiers/verify_deep_families.js),
  [`verify_spec_compliance.js`](./verifiers/verify_spec_compliance.js),
  [`verify_integration.js`](./verifiers/verify_integration.js),
  [`verify_raw_deep.js`](./verifiers/verify_raw_deep.js).
- **Baselines:** `tests/baselines/deep_families_baseline.json`,
  `tests/baselines/multi_parser_baseline.json`,
  `tests/baselines/spec_baseline.json`.
- **Notes:** Deep compare runs by family (ambiguity, asi, escapes,
  interactions, jsx, lexical, regex_disambiguation, typescript, unicode)
  and across three reference parsers on curated real-world files. Family
  baselines make drift visible per surface.

### `estree_node_coverage` — [strong] [zero-tolerance]
- **Claim:** Every emitted ESTree node type has at least one minimal
  fixture exercising its emit path, and zero structural invariants ever
  break on the 467-file real-world corpus.
- **Fixtures:** The fixtures live inside the verifiers themselves
  ([`estree_nodes_coverage.js`](./verifiers/estree_nodes_coverage.js)).
- **Verifiers:** [`estree_nodes_coverage.js`](./verifiers/estree_nodes_coverage.js),
  [`verify_invariants.js`](./verifiers/verify_invariants.js).
- **Baselines:** `tests/baselines/nodes_coverage_baseline.json`,
  `tests/baselines/invariants_baseline.json`.
- **Notes:** 57 node types covered, 1 fixture per emit path; the 8
  zero-tolerance invariants plus 2 baseline-locked soft invariants run
  across the real-world corpus.

### `standards_pressure` — [medium] [baseline-gated]
- **Claim:** A curated Test262 subset passes by grammar category, with any
  category-level pass-count regression failing the gate.
- **Fixtures:** `tests/test262/` (66 tests), indexed by
  [`tests/test262_manifest.json`](./test262_manifest.json).
- **Verifiers:** [`tests/runners/run_test262.sh`](./runners/run_test262.sh)
  (flat smoke test), [`tests/verifiers/verify_test262_subset.js`](./verifiers/verify_test262_subset.js)
  (category-aware gate).
- **Baselines:** `tests/baselines/test262_subset_baseline.json`,
  `tests/baselines/test262_known_failures.txt`.
- **Notes:** `run_test262.sh` reports a flat "66/66" because it checks
  only exit codes; `verify_test262_subset.js` reads front-matter to tell
  positive from negative and surfaces 2 negative string-literal fixtures
  that are wrongly accepted (tracked as known_fail). `early_errors`
  category is still empty in the manifest.

### `interaction_combinations` — [weak] [baseline-gated]
- **Claim:** High-value feature combinations (decorators × private fields
  × static blocks, async generators × destructuring, optional chaining
  chains, import attributes, JSX-async, TS-in-class, …) parse cleanly and
  match OXC.
- **Fixtures:** `tests/fixtures/spec/interactions/*` (10 stacked-feature
  cases).
- **Verifiers:** [`run_spec_fixtures.js`](./runners/run_spec_fixtures.js),
  [`verify_deep_families.js`](./verifiers/verify_deep_families.js) (family
  `interactions`).
- **Baselines:** `tests/baselines/spec_fixtures_baseline.json`,
  `tests/baselines/deep_families_baseline.json`.
- **Notes:** All 10 fixtures parse cleanly (0 parse errors); 3/10 deep-diff
  clean vs OXC today, 7/10 baseline-tracked divergences. Lifting this to
  `medium` requires closing the deep-diff gap on decorators, import
  attributes, JSX-async children, and generic TS classes.

### `lexical_tokenization` — [medium] [baseline-gated]
- **Claim:** Tokenisation-sensitive cases (BOM, hashbang, identifier
  escapes, numeric separators, template raw/cooked, comment-regex
  boundary, unicode line terminators) produce the correct AST shape.
- **Fixtures:** `tests/fixtures/spec/lexical/*` (10 targeted lexical cases).
- **Verifiers:** [`tests/verifiers/verify_lexical_surfaces.js`](./verifiers/verify_lexical_surfaces.js).
- **Baselines:** `tests/baselines/lexical_surfaces_baseline.json`.
- **Notes:** 8/10 shape assertions pass today. Two tracked lexer gaps:
  (a) BOM-before-hashbang swallows the hashbang, (b) U+2028/U+2029 are
  not treated as LineTerminators at the top level.

## Adding A New Surface

1. Pick a single, defensible claim. If the claim can't fit in one sentence,
   split it.
2. Add fixtures under `tests/fixtures/spec/<surface-name>/` (or an
   established location) — ten minimal files is usually a good starting
   density.
3. Add a verifier under `tests/verifiers/verify_<surface>.js` that
   either asserts shape directly or deep-diffs vs OXC. Follow the CLI
   convention (`--update`, `--strict`, `--verbose`).
4. Add a baseline under `tests/baselines/<surface>_baseline.json`.
5. Add the surface to `tests/surface_status.json` with honest
   `coverage_status` and `notes`.
6. Add a section to this map.
7. Update [`tests/COVERAGE_GAP_CHECKLIST.md`](./COVERAGE_GAP_CHECKLIST.md)
   to record which gap the surface closes.
