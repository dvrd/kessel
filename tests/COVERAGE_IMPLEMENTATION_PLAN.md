# Kessel Tests-Only Coverage Implementation Plan

Scope: `tests/` directory only.
Constraint: no edits outside `tests/`.
Purpose: convert `tests/COVERAGE_GAP_CHECKLIST.md` into a concrete, staged plan of test-only work.

## Plan Philosophy

This plan is ordered by one question:

> Which additions make the suite better at measuring distance to the desired parser product, even before parser bugs are fixed?

That means we prioritize:
1. invalid input coverage,
2. ambiguity coverage,
3. recovery quality,
4. stronger differential/reference pressure,
5. broader standards pressure,
6. better visibility.

---

## Stage 1 — Expand Parser-Negative Coverage

### Goal
Make `test:negative:strict` a more meaningful statement about the parser by covering more invalid syntax families that OXC also rejects.

### Add fixture families

#### 1.1 New directory: `tests/fixtures/early_errors/module_context/`
Add focused fixtures for module-vs-script-sensitive early errors.

Status: done.

Implemented files:
- `001_export_in_script.js`
- `002_import_in_script.js`
- `003_top_level_await_in_script.js`
- `004_import_meta_in_script.js`
- `005_await_in_module_non_async_function.js`

Notes:
- Keep each fixture minimal.
- These fixtures are for a separate semantic/early-error surface and are not part of `verify_negative.js`.
- If the current harness expects flat directories only, place them in `tests/fixtures/early_errors/` with prefixed names instead.

#### 1.2 New directory: `tests/fixtures/early_errors/strict_mode/`
Expand strict-mode-specific invalid programs.

Status: done.

Implemented files:
- `001_reserved_implements.js`
- `002_reserved_interface.js`
- `003_reserved_package.js`
- `004_reserved_private.js`
- `005_reserved_protected.js`
- `006_reserved_public.js`
- `007_reserved_static.js`
- `008_reserved_yield.js`
- `009_duplicate_params_strict_nested.js`
- `010_eval_arguments_assignment.js`

Notes:
- Keep each fixture minimal.
- This family is the strict-mode companion to `module_context/`.
- These fixtures are for a separate semantic/early-error surface and are not part of `verify_negative.js`.

#### 1.3 New directory: `tests/fixtures/negative/truncation/`
Target parser cut-point failures.

Status: done.

Implemented files:
- `001_array_eof.js`
- `002_object_eof.js`
- `003_function_params_eof.js`
- `004_function_body_eof.js`
- `005_class_body_eof.js`
- `006_call_args_eof.js`
- `007_member_chain_eof.js`
- `008_optional_chain_eof.js`
- `009_template_substitution_eof.js`
- `010_jsx_tag_eof.js`

Notes:
- Keep each fixture minimal.
- These fixtures target parser cut points where EOF should surface a hard failure.
- Verified against OXC: all 10 fixtures reject there too, and the parse-error counts now match; this keeps the negative corpus aligned with the rule that Kessel should report at least as much error information as OXC.

#### 1.4 New directory: `tests/fixtures/negative/regex_literals/`
Target malformed regex syntax.

Status: done.

Implemented files:
- `001_unclosed_class.js`
- `002_bad_quantifier.js`
- `003_bad_group.js`
- `004_duplicate_flags.js`
- `005_invalid_unicode_escape.js`
- `006_trailing_backslash.js`

Notes:
- Keep each fixture minimal.
- These fixtures cover malformed character-class forms that both Kessel and OXC reject with matching error counts.

#### 1.5 New directory: `tests/fixtures/negative/numeric_literals/`
Target malformed number/bigint/separator syntax.

Status: done.

Implemented files:
- `001_separator_leading.js`
- `002_separator_trailing.js`
- `003_separator_double.js`
- `004_bigint_decimal_point.js`
- `005_bigint_exponent.js`
- `006_invalid_binary_digit.js`

Notes:
- Keep each fixture minimal.
- These fixtures cover malformed numeric syntax families that OXC also rejects.
- Current parser status: all six are still accepted, so `verify_negative.js --update` now tracks them as known bugs in `tests/baselines/negative_baseline.json`.

### Verifier work

#### 1.6 Extend `tests/verifiers/verify_negative.js`
Status: done.

The verifier already recursively discovers nested subdirectories under:
- `tests/fixtures/negative`

This gate is parser-only. Semantic early-error fixtures are intentionally excluded and can be owned by a different verifier.


### Success condition
- `verify_negative.js` counts a much broader parser-invalid family set.
- `test:negative:strict` becomes a stronger parser gate without touching parser source.

---

## Stage 2 — Add Dialect Ambiguity Coverage

### Goal
Measure parser correctness at high-risk JS / TS / JSX ambiguity points.

### Add fixture family

#### 2.1 New directory: `tests/fixtures/spec/ambiguity/`
A dedicated family is better than burying these inside `typescript/` or `jsx/`.

Status: done.

Implemented files:
- `001_ts_assertion_vs_jsx_simple.js`
- `002_ts_assertion_vs_jsx_paren.js`
- `003_generic_call_vs_relational.js`
- `004_generic_arrow_vs_relational.js`
- `005_jsx_attribute_nested_element.js`
- `006_jsx_expression_nested_generic_like.js`
- `007_type_arguments_call_chain.js`
- `008_less_than_binary_not_generic.js`
- `009_jsx_fragment_vs_type_context.js`
- `010_import_type_vs_import_call.js`

Notes:
- Keep each fixture minimal.
- These cases target the TS/JSX boundary where parser mode and tokenization can change meaning.

### Expected outputs / ownership

#### 2.2 Positive golden outputs
Status: done.

Implemented files:
- `tests/expected/spec/ambiguity/001_ts_assertion_vs_jsx_simple.txt`
- `tests/expected/spec/ambiguity/002_ts_assertion_vs_jsx_paren.txt`
- `tests/expected/spec/ambiguity/003_generic_call_vs_relational.txt`
- `tests/expected/spec/ambiguity/005_jsx_attribute_nested_element.txt`
- `tests/expected/spec/ambiguity/006_jsx_expression_nested_generic_like.txt`
- `tests/expected/spec/ambiguity/008_less_than_binary_not_generic.txt`
- `tests/expected/spec/ambiguity/009_jsx_fragment_vs_type_context.txt`
- `tests/expected/spec/ambiguity/010_import_type_vs_import_call.txt`

Notes:
- Keep each fixture minimal.
- These files pin the current pretty-printed Kessel output for the fixtures that parse cleanly today.

#### 2.3 Known-failure map inside tests
Status: done.

Implemented file:
- `tests/baselines/ambiguity_known_failures.txt`

Notes:
- This file documents the current OXC-divergent / parser-error ambiguity fixtures.
- The verifier consumes it to label known failures, but it never skips execution.

### New verifier

#### 2.4 Add `tests/verifiers/verify_ambiguity.js`
Status: done.

Purpose:
- run all `tests/fixtures/spec/ambiguity/*.js`
- classify each as:
  - parses and matches expected,
  - parses with errors,
  - crashes,
  - missing expected
- optionally compare selected fixtures to OXC via `verify_json_deep.js`

Implemented behavior:
- default: report all outcomes, fail on regressions vs baseline
- `--strict`: require every ambiguity fixture to pass
- `--update`: refresh the ambiguity baseline snapshot
- known failures remain visible, but they do not get skipped

### Success condition
- ambiguity is treated as its own product surface
- failures are visible as ambiguity failures, not lost among generic unit failures

---

## Stage 3 — Expand Recovery Coverage

### Goal
Make recovery quality measurable, not just existence of a few recovery fixtures.

### Add fixture family

#### 3.1 New directory: `tests/fixtures/recovery/expressions/`
Status: done.

Implemented files:
- `001_binary_missing_rhs.js`
- `002_call_missing_arg.js`
- `003_member_missing_property.js`
- `004_nested_paren_break.js`
- `005_conditional_missing_false.js`

Notes:
- Each fixture keeps a `const anchor_after_error = 1;` declaration after the malformed expression so the verifier can prove recovery reached the later code.

#### 3.2 New directory: `tests/fixtures/recovery/statements/`
Status: done.

Implemented files:
- `001_if_missing_consequent.js`
- `002_for_header_broken.js`
- `003_switch_case_broken.js`
- `004_try_catch_broken.js`
- `005_return_expression_broken.js`

Notes:
- Each fixture keeps a `const anchor_after_error = 1;` declaration after the malformed statement so the verifier can prove recovery reached the later code.

#### 3.3 New directory: `tests/fixtures/recovery/declarations/`
Status: done.

Implemented files:
- `001_function_params_broken.js`
- `002_class_member_broken.js`
- `003_import_clause_broken.js`
- `004_export_decl_broken.js`
- `005_var_decl_broken.js`

Notes:
- Each fixture keeps a `const anchor_after_error = 1;` declaration after the malformed declaration so the verifier can prove recovery reached the later code.

#### 3.4 New directory: `tests/fixtures/recovery/jsx_ts/`
Status: done.

Implemented files:
- `001_jsx_attr_broken.js`
- `002_jsx_close_tag_broken.js`
- `003_ts_type_annotation_broken.js`
- `004_ts_assertion_broken.js`
- `005_generic_param_broken.js`

Notes:
- Each fixture keeps a `const anchor_after_error = 1;` declaration after the malformed JSX/TS region so the verifier can prove recovery reached the later code.

### New verifier

#### 3.5 Add `tests/verifiers/verify_recovery.js`
Status: done.

Purpose:
- parse each recovery fixture
- assert recovery-specific properties, not just full-text equality

Implemented assertions:
- parser exits without crash
- parse errors reported are bounded (`>= 1` and below a sanity threshold)
- later anchor declarations still appear in emitted AST
- no `Unknown` node type explosions
- no absurd source ranges (containment checks, with TS type-annotation edges skipped where they are not containment-shaped)

Suggested fixture style:
Each recovery fixture includes at least one `const anchor_after_error = 1;` declaration after the malformed region, and the verifier asserts that anchor survives recovery.

### Success condition
- recovery becomes a quality surface with explicit assertions
- later parser fixes can improve recovery without weakening coverage discipline

---

## Stage 4 — Widen Deep Differential Coverage

### Goal
Increase confidence that Kessel’s AST is converging toward reference parser behavior across more product surfaces.

### Expand existing runner

#### 4.1 Extend `tests/runners/run_spec_fixtures.js`
Status: done.

The runner now walks `tests/fixtures/spec/` recursively and includes the modern
syntax families in the deep-compare pass, including:
- `ambiguity`
- `jsx`
- `typescript`
- `unicode`
- `escapes`
- `asi`
- `regex_disambiguation`

Notes:
- The category baseline is updated from the current fixture set.
- Recursive discovery means future nested fixture families are picked up
  automatically without another runner edit.

### Expand multi-parser verifier

#### 4.2 Extend `tests/verifiers/verify_multi_parser.js`
Status: done.

Broadened file selection to include:
- `tests/fixtures/spec/jsx/*.js`
- `tests/fixtures/spec/typescript/*.js`
- `tests/fixtures/spec/unicode/*.js`
- `tests/fixtures/spec/escapes/*.js`
- `tests/fixtures/spec/asi/*.js`

Notes:
- The baseline now captures the added parser-drift surface area instead of hiding it.
- Families with structural dialect drift remain baseline-gated rather than skipped.

### Add focused deep-diff verifier

#### 4.3 Add `tests/verifiers/verify_deep_families.js`
Status: done.

Purpose:
- run `verify_json_deep.js` across configurable fixture families
- produce per-family pass/fail/divergence counts
- baseline-lock family counts rather than one giant flat list

Implemented baseline:
- `tests/baselines/deep_families_baseline.json`

Suggested CLI:
- `node tests/verifiers/verify_deep_families.js --parser oxc --families jsx,typescript,unicode`
- `--update`
- `--verbose`

Notes:
- The default family set focuses on the highest-risk syntax surfaces:
  `ambiguity`, `asi`, `escapes`, `jsx`, `regex_disambiguation`,
  `typescript`, `unicode`.

### Success condition
- differential confidence is not concentrated only in a few selected files
- more syntax families get exact-AST pressure

---

## Stage 5 — Broaden Standards Pressure

### Goal
Make the curated Test262 subset more representative by grammar family.

### Add metadata file

#### 5.1 New file: `tests/test262_manifest.json`
Status: done.

Purpose:
- record which curated tests belong to which grammar family
- make subset intent visible

Implemented contents:
- `lexical`: 12 files
- `expressions`: 22 files
- `statements`: 20 files
- `functions`: 10 files
- `modules`: 2 files
- `early_errors`: 0 files

Notes:
- The manifest is machine-readable so later reporting can stay category-aware.
- The current curated subset is still syntax-only.

### Expand subset

#### 5.2 Add more tests under `tests/test262/`
Status: done.

Added syntax-only cases in the thin categories:
- lexical grammar:
  - `literals_bigint_S7.8.3_A1_T1.js`
  - `literals_numeric_separator_S7.8.3_A1_T1.js`
- module grammar:
  - `modules_import_export_S15.2.1_A1.js`
  - `modules_import_meta_S15.2.1_A1.js`
- newer ES syntax:
  - `expressions_optional_chaining_S11.2_A1.js`
  - `expressions_nullish_coalescing_S11.12_A1.js`

Notes:
- The curated subset now has 66 syntax-only tests.
- `tests/runners/run_test262.sh` still parses every file directly, so all
  additions were chosen to pass in the current parser configuration.

### Add verifier/reporting layer

#### 5.3 Add `tests/verifiers/verify_test262_subset.js`
Status: done.

Implemented file:
- `tests/verifiers/verify_test262_subset.js`

Implemented baseline:
- `tests/baselines/test262_subset_baseline.json`

Implemented behavior:
- Reads `tests/test262_manifest.json` as the source of truth for subset
  membership, and hard-errors if the manifest references a file missing on
  disk.
- Parses each fixture's Test262 front-matter to derive the expected outcome.
  A `negative:` block with `phase: parse` or `phase: early` means the parser
  MUST reject the program; anything else (including runtime/resolution
  phases, or no `negative:` block) means the parser MUST accept it.
- Uses the same rejection criterion as `verify_negative.js` (exit != 0 OR
  `Parse errors: N` with N >= 1) so the two gates agree on what "rejected"
  means.
- Classifies each fixture as `pass`, `known_fail` (expected-failure listed in
  `tests/baselines/test262_known_failures.txt`), or `unexpected_fail`
  (regression).
- Reports pass rate per category and overall, e.g.:
    lexical       pass=10/12  known_fail=2  unexpected_fail=0  rate=83.3%
    expressions   pass=22/22  known_fail=0  unexpected_fail=0  rate=100%
    ...
    overall       pass=64/66  known_fail=2  unexpected_fail=0  rate=97%
- Snapshots per-file verdicts AND per-category counts into the baseline. A
  regression is either a per-file transition away from `pass`, a `known_fail`
  -> `unexpected_fail` transition, or a drop in a category's or the overall
  `pass` count versus baseline.
- CLI: `--update`, `--strict`, `--verbose`, and `--category <name>` to focus
  on a single grammar family. Exit 0 on match/improvement, 1 on regression,
  2 on environment errors (missing binary, missing manifest, unknown
  category).

Notes:
- `tests/runners/run_test262.sh` stays as the blunt smoke-test (it only
  inspects exit codes, so it silently scored the two negative string fixtures
  as "pass"). `verify_test262_subset.js` is the category-aware gate that
  surfaces them as `known_fail` instead.

### Success condition
- standards pressure becomes visible by category
- gaps in subset selection become obvious

---

## Stage 6 — Add Interaction-Matrix Fixtures

### Goal
Test high-value feature combinations, not only individual features.

### Add fixture family

#### 6.1 New directory: `tests/fixtures/spec/interactions/`
Status: done.

Implemented files:
- `001_decorators_private_static_block.js`
- `002_async_generator_destructure_defaults.js`
- `003_for_await_destructure_default.js`
- `004_optional_chain_call_member_mix.js`
- `005_import_attributes_export_mix.js`
- `006_jsx_async_expression_children.js` (JSX — filename marker `_jsx_` selects jsx mode)
- `007_unicode_identifier_in_class_private_context.js`
- `008_directive_inside_nested_function_module.js`
- `009_regex_after_asi_sensitive_boundary.js`
- `010_ts_types_inside_complex_class.js` (TS — filename marker `_ts_` selects ts mode)

Implemented expected outputs:
- `tests/expected/spec/interactions/*.txt` (one per fixture, pinned pretty-printed AST)

Runner updates:
- `tests/runners/run_tests.sh` — per-file language detection by filename marker (`_jsx_` → jsx, `_ts_` → ts, default js) for `spec/interactions/*`.
- `tests/runners/run_spec_fixtures.js` — same per-file language detection.
- `tests/verifiers/verify_json_deep.js` — consolidated dialect detection into a single `detectDialect()` used by both the Kessel CLI flag and the OXC synthetic filename, picking up the same `_jsx_`/`_ts_` filename markers.

### Ownership
Done. Each fixture is owned by three complementary gates:
1. `run_tests.sh` — pretty-printed golden match (zero-tolerance).
2. `run_spec_fixtures.js` — deep AST compare vs OXC per category (baseline-gated).
3. `verify_deep_families.js` — family-level pass/fail/divergence counts (baseline-gated).

Current measured state:
- All 10 fixtures parse cleanly (0 parse errors).
- 2/10 match OXC exactly today; 8/10 have tracked divergences on decorator, import-attribute, JSX-async, and generic-TS-class surfaces. These are baselined and will surface improvements/regressions without blocking.

### Success condition
- the suite starts covering feature interactions intentionally, not only accidentally

---

## Stage 7 — Tokenization-Sensitive Fixture Layer

### Goal
Map lexer-sensitive cases more explicitly without requiring a separate token-stream harness.

### Add fixture family

#### 7.1 New directory: `tests/fixtures/spec/lexical/`
Status: done.

Implemented files:
- `001_hashbang_bom.js` (UTF-8 BOM prefix + hashbang line)
- `002_crlf_restricted_production.js` (CRLF line endings + `return` restricted production)
- `003_identifier_escape_start.js` (`\u0061bc` at IdentifierStart)
- `004_identifier_escape_continue.js` (`a\u0062c` at IdentifierContinue)
- `005_comment_regex_boundary.js` (`/regex/` after intervening comments)
- `006_comment_division_boundary.js` (`/` as division after intervening comments)
- `007_numeric_separator_matrix.js` (separators across decimal/hex/binary/octal/bigint/float/exponent)
- `008_template_raw_vs_cooked.js` (raw != cooked on template quasis)
- `009_zwj_identifier_contexts.js` (ZWJ/ZWNJ in IdentifierContinue)
- `010_unicode_line_terminator_contexts.js` (U+2028 / U+2029 as LineTerminators)

Implemented expected outputs:
- `tests/expected/spec/lexical/*.txt` (one per fixture).

### New verifier

#### 7.2 Add `tests/verifiers/verify_lexical_surfaces.js`
Status: done.

Implemented file:
- `tests/verifiers/verify_lexical_surfaces.js`

Implemented baseline:
- `tests/baselines/lexical_surfaces_baseline.json`

Implemented behavior:
- One focused AST assertion per fixture (not a flat pass/fail). Each fixture has a matching `check_XXX` function that pulls the specific claim out of the parsed AST:
    - `001` — `Program.hashbang` is a Hashbang node (expected to fail today; BOM hides the `#!` line)
    - `002` — `function f` body has 2 statements (CRLF ASI split)
    - `003`/`004` — first declarator `id.name` is the cooked identifier
    - `005` — every initialiser contains a RegExpLiteral
    - `006` — boundary initialisers are `BinaryExpression` with operator `/`
    - `007` — every numeric-separator literal cooks to its numeric value
    - `008` — at least one TemplateLiteral has raw != cooked
    - `009` — first declarator name contains a literal ZWJ
    - `010` — three top-level VariableDeclarations (expected to fail today; U+2028/U+2029 treated as whitespace)
- Hard error if a fixture is added without a matching assertion, or if an assertion entry has no fixture on disk.
- CLI: `--update`, `--strict`, `--verbose`. Exit 0 on match/improvement, 1 on regression, 2 on setup errors.

Current measured state: 8/10 assertions pass. The two failures are real, tracked lexer gaps:
- BOM-before-hashbang swallows the `#!` line.
- U+2028 / U+2029 are treated as whitespace rather than LineTerminators at top level.

### Success condition
- tokenization-sensitive behavior becomes a named surface in the suite

---

## Stage 8 — Improve Visibility And Reporting

### Goal
Make the suite communicate product-surface progress, not just green/red execution.

### Add summary artifact

#### 8.1 New file: `tests/SURFACE_MAP.md`
Status: done.

Implemented file:
- `tests/SURFACE_MAP.md`

Implemented contents:
- Surface-by-surface map of claim → fixtures → verifiers → baselines, with a
  `strong`/`medium`/`weak` confidence label and honest notes about what the
  current status comes from and what would lift it.
- Ten surfaces covered: `core_syntax`, `invalid_syntax`, `early_errors`,
  `ambiguity_ts_jsx`, `recovery`, `differential_estree`,
  `estree_node_coverage`, `standards_pressure`, `interaction_combinations`,
  `lexical_tokenization`.
- An "Adding A New Surface" checklist at the bottom so new claims land with
  the supporting fixtures, verifier, baseline, and checklist update.

### Add progress reporter

#### 8.2 Add `tests/verifiers/report_surface_status.js`
Status: done.

Implemented file:
- `tests/verifiers/report_surface_status.js`

Implemented behavior:
- Reads `tests/surface_status.json` and walks the declared fixture dirs and
  baselines to produce a per-surface summary.
- Understands all baseline shapes the suite uses today — flat tally
  (`verify_negative`, `verify_ambiguity`, `verify_lexical_surfaces`),
  per-category/overall (`test262_subset`), per-category totals
  (`spec_fixtures`), per-family summaries (`deep_families`), and plain-text
  lists (known-failures).
- Default output is a compact one-line-per-surface table with a `[strong]`
  / `[medium]` / `[weak]` pill. `--verbose` adds per-fixture-dir counts,
  verifier list, baseline snapshot, and the surface's notes. `--surface
  <name>` focuses on one surface. `--json` emits the full machine-readable
  snapshot for downstream tools.
- This is a REPORTER, not a gate: exit 0 on valid config, 2 only on
  configuration errors (missing baseline, fixture_dir that doesn't exist,
  unknown surface filter).

### Add machine-readable config

#### 8.3 New file: `tests/surface_status.json`
Status: done.

Implemented file:
- `tests/surface_status.json`

Implemented contents (per surface):
- `name`, `description`
- `fixture_dirs` — where the supporting fixtures live (walked by the reporter)
- `verifiers` — which scripts own the claim
- `baselines` — which baseline files lock the current state
- `policy` — `zero-tolerance` or `baseline-gated`
- `coverage_status` — `strong` / `medium` / `weak`
- `notes` — free-text explanation of the current status, consumed by the
  "Coverage gaps" section of the reporter.

### Success condition
- every run or audit can answer “what surfaces are covered and how well?”

---

## Minimal First Batch

If you want the smallest valuable tests-only batch, do this first:

1. Extend `verify_negative.js` to recurse into nested subdirectories under `tests/fixtures/negative`.
2. Add `tests/fixtures/negative/truncation/` with 10 cut-point fixtures.
3. Add `tests/fixtures/spec/ambiguity/` with 10 high-risk ambiguity fixtures.
4. Add `tests/verifiers/verify_ambiguity.js`.
5. Add `tests/fixtures/recovery/jsx_ts/` with 5 fixtures.
6. Add `tests/verifiers/verify_recovery.js`.
7. Add `tests/test262_manifest.json` and `tests/verifiers/verify_test262_subset.js`.

That batch would materially improve the suite’s ability to measure distance to the desired product without touching `src/`.

---

## Definition Of Done For This Plan

This plan is succeeding if, after tests-only work:
- invalid program coverage is broader and more category-aware,
- ambiguity failures have a named home,
- recovery quality is asserted, not implied,
- deep-diff pressure applies to more families,
- Test262 subset coverage is visible by category,
- the suite can explain product-surface confidence in concrete terms.
