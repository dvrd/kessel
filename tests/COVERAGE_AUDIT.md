# Kessel Test Coverage Audit

Scope: `tests/` directory only.
Date: 2026-04-23.
Goal: describe what the current test suite covers, what it covers partially, and what it does not yet cover well enough to claim broad product-surface confidence.

## Executive Summary

The current suite is **broad and layered**, but **not exhaustive**.

It is strong at:
- preventing regressions in already-discovered bug classes,
- checking many valid syntax families,
- checking AST structural integrity,
- comparing against reference parsers on selected fixtures and real files,
- catching crashes and malformed-input failures.

It is weaker at:
- full grammar interaction coverage,
- full negative-space coverage,
- full ECMAScript conformance,
- full TS / JSX / TSX ambiguity coverage,
- comprehensive recovery correctness.

## Inventory

### Fixture counts

| Area | Count |
|---|---:|
| `tests/fixtures/basic` | 12 |
| `tests/fixtures/edge` | 19 |
| `tests/fixtures/es2015` | 12 |
| `tests/fixtures/es2020` | 5 |
| `tests/fixtures/es2022` | 7 |
| `tests/fixtures/es2025` | 22 |
| `tests/fixtures/negative` | 10 |
| `tests/fixtures/early_errors` | 16 |
| `tests/fixtures/real` | 15 |
| `tests/fixtures/recovery` | 5 |
| `tests/fixtures/regression` | 11 |
| `tests/fixtures/spec/**` | 110 |
| **Total fixture `.js` files** | **244** |

### `tests/fixtures/spec` breakdown

| Spec bucket | Count |
|---|---:|
| `asi` | 8 |
| `edge` | 19 |
| `es2015` | 10 |
| `es2016` | 2 |
| `es2017` | 2 |
| `es2018` | 3 |
| `es2019` | 2 |
| `es2020` | 6 |
| `es2021` | 2 |
| `es2022` | 6 |
| `es2023` | 2 |
| `es2024` | 2 |
| `es2025` | 2 |
| `escapes` | 8 |
| `jsx` | 8 |
| `regex_disambiguation` | 12 |
| `typescript` | 10 |
| `unicode` | 6 |

### Verifier inventory

| Verifier | Purpose |
|---|---|
| `estree_nodes_coverage.js` | node-type emission smoke coverage |
| `verify_negative.js` | invalid / early-error rejection gate |
| `verify_regression.js` | targeted structural regression checks |
| `verify_invariants.js` | AST invariants across corpus |
| `verify_discriminators.js` | enum/discriminator sanity |
| `verify_position_containment.js` | parent/child source range containment |
| `verify_raw_value_consistency.js` | literal raw/value consistency |
| `verify_json_deep.js` | deep AST compare against a reference parser |
| `verify_spec_compliance.js` | baseline-gated OXC divergence on selected real files |
| `verify_multi_parser.js` | baseline-gated Acorn/Babel divergence on selected files |
| `verify_string_escapes.js` | string-literal decoding parity |
| `verify_integration.js` | deep raw-buffer/tree integration checks |
| `verify_raw.js` / `verify_raw_deep.js` | raw transfer format checks |
| `fuzz_diff.js` | differential fuzzing |
| `fuzz_invalid.js` | malformed-input mutation fuzzing |
| `verify_crashes_known.js` | known crash-class tracking |

## Coverage Matrix

Legend:
- **Strong**: covered by multiple layers and meaningful assertions.
- **Medium**: covered by dedicated fixtures or one strong layer, but not enough for broad confidence.
- **Weak**: sampled, thin, or missing important interaction coverage.
- **Missing**: no meaningful dedicated coverage visible in `tests/`.

| Surface | Status | Evidence | Notes |
|---|---|---|---|
| Core JS syntax | Strong | `basic`, `edge`, `real`, `spec/edge`, deep diff | Good breadth on common statements and expressions. |
| Common modern JS features | Strong | `es2015`, `es2020`, `es2022`, `spec/es20xx` | Good family-level coverage, not full interaction coverage. |
| AST structural integrity | Strong | `estree_nodes_coverage`, `verify_invariants`, `verify_discriminators`, `verify_position_containment` | One of the strongest parts of the suite. |
| Known regression classes | Strong | `regression`, `verify_regression` | Strong for bugs already discovered. |
| Real-world parser stability | Strong | real-world verifiers + corpus-backed checks | Good for practical confidence. |
| Crash resistance | Strong | `fuzz_invalid`, `verify_crashes_known`, timeout checks | Good operational safety pressure. |
| Invalid program rejection | Medium | `negative`, `early_errors`, `verify_negative` | Good start, but invalid-space coverage is still small. |
| JSX syntax | Medium | `spec/jsx`, `es2025/016..018`, deep diff on selected cases | Present, but not comprehensive. |
| TypeScript syntax | Medium | `spec/typescript`, `es2025/019..022` | Good sampling, not near full TS grammar coverage. |
| Unicode identifiers | Medium | `spec/unicode` | Better than average, still not exhaustive. |
| Escape handling | Medium | `spec/escapes`, `verify_string_escapes` | Good dedicated coverage, but escape space is deep. |
| Regex vs division disambiguation | Medium | `spec/regex_disambiguation` | Dedicated family exists; still sampled. |
| ASI | Medium | `spec/asi` | Dedicated family exists; not broad enough to claim completeness. |
| Error recovery | Weak | `recovery` fixtures | Useful smoke checks, not enough for high confidence. |
| Module/script context rules | Weak | scattered fixtures, some import/export coverage | Not enough dedicated context-matrix coverage. |
| TSX ambiguity | Weak | indirect via TS + JSX fixtures | No strong dedicated TSX ambiguity suite visible. |
| Full ECMAScript conformance | Weak | curated `test262` subset (60 files) | Helpful, but far from full Test262. |
| Full grammar interaction matrix | Weak | indirect via real-world + fuzzing | No explicit combinatorial coverage. |
| Lexer/token stream correctness as a first-class layer | Weak | indirect only | No dedicated token-level conformance harness visible. |
| Full negative-space exploration | Weak | `negative` + `early_errors` + mutation fuzz | Still small relative to possible invalid programs. |

## What The Suite Currently Proves Well

### 1. Regressions on known bug classes are likely to be caught
`tests/fixtures/regression` plus `tests/verifiers/verify_regression.js` provide targeted structural assertions. This is stronger than plain golden-output testing because the checks are tied to the bug class itself.

### 2. Many valid-language feature buckets parse at all
The fixture tree gives broad coverage across core JS, newer JS, JSX, TS-like syntax, unicode, ASI, and regex-disambiguation cases.

### 3. Many ESTree-shape failures are visible
The node coverage matrix and invariant-style verifiers pressure the emitted tree structure in ways simple fixture output comparison would not.

### 4. Selected reference-parser divergence is tracked over time
The baseline gates in `verify_spec_compliance.js`, `verify_multi_parser.js`, and `run_spec_fixtures.js` mean the suite can enforce “do not drift farther away” on selected reference comparisons.

### 5. The parser gets exercised on both tiny fixtures and large real files
That combination is valuable: tiny fixtures localize syntax families; large files expose interactions and practical stability issues.

## What The Suite Does Not Yet Prove Well

### 1. Full product-surface correctness
The suite does not justify a claim like “we cover all supported language cases”. It covers many buckets, but not the full interaction space.

### 2. Complete rejection of invalid input
There is a meaningful negative gate now, but 26 fixtures is not remotely full invalid-space coverage for JS/TS/JSX parsing.

### 3. Full conformance to ECMA-262
The curated `test262` subset is useful, but it is still a subset. This is not full standards-suite coverage.

### 4. Full TS / JSX / TSX ambiguity handling
Fixtures exist, but this area still looks sampled rather than systematically mapped.

### 5. Robust recovery guarantees
Recovery fixtures exist, but they are too few to claim confidence across many malformed-input resume points.

## Risk Areas Not Yet Well-Mapped

These are areas where the current suite likely has the most remaining unknowns:

1. **Feature interaction cross-products**
   - decorators × private fields × static blocks
   - JSX × TS ambiguity points
   - module-only syntax in nested/edge contexts
   - ASI interactions with newer syntax forms

2. **Context-sensitive early errors**
   - script vs module distinctions
   - strict vs sloppy distinctions beyond the current sample set
   - context-bound keywords and reserved words

3. **Recovery correctness**
   - bad token in nested expressions
   - resume after malformed JSX/TS syntax
   - bounded error cascades and AST sanity after recovery

4. **Tokenization edge surfaces**
   - unicode escapes inside identifiers in more contexts
   - regex/body validation vs opaque scanning
   - shebang/hashbang interactions in mixed contexts
   - comment/newline interactions around restricted productions

5. **Dialect ambiguity surfaces**
   - TS angle assertions vs JSX
   - generic parameters vs relational operators in ambiguous positions
   - import attributes / type-only syntax interactions across parser modes

## Recommended Coverage Priorities

If the goal is to improve confidence in the product surface, the next testing investments should be:

### Priority 1: Expand negative / early-error coverage
Reason: acceptance of invalid input is still a large unknown area.

Suggested additions:
- more strict-mode reserved-word cases,
- module-only vs script-only early errors,
- malformed JSX/TS syntax families,
- truncated constructs at many grammar boundaries,
- invalid escape and regex edge families.

### Priority 2: Add a dialect ambiguity suite
Reason: JS/TS/JSX ambiguity points are among the highest-risk parser surfaces.

Suggested additions:
- TSX ambiguity fixtures,
- angle-bracket assertion vs JSX cases,
- generic call/class syntax in ambiguous positions,
- nested JSX-in-attribute and JSX-in-expression combinations.

### Priority 3: Expand recovery suite
Reason: current recovery confidence is low.

Suggested additions:
- one malformed token per major grammar family,
- assertions on resumed parse position,
- assertions on AST sanity after recovery,
- checks for bounded parse-error counts.

### Priority 4: Widen deep-diff coverage
Reason: current differential checks are meaningful but selective.

Suggested additions:
- more `spec` families through `verify_json_deep`,
- more real-world files through `verify_multi_parser`,
- more JSX/TS fixtures through reference-parser comparison.

### Priority 5: Grow standards pressure
Reason: curated Test262 smoke coverage is useful but limited.

Suggested additions:
- a larger curated subset,
- category-based pass-rate reporting,
- eventually a broader syntax-only Test262 sweep.

## Suggested Decision Rule

When evaluating whether the suite is getting closer to the desired product, use this rule:

- **Closer** means:
  - more valid feature families are covered,
  - more invalid families are rejected,
  - fewer known regressions remain possible,
  - differential baseline counts shrink,
  - strict gates get greener without adding hidden skips.

- **Not closer** means:
  - only output files are refreshed,
  - failures are reclassified instead of specified better,
  - new syntax is added without negative / ambiguity / differential coverage,
  - real-world and reference-parser pressure does not expand.

## Verdict

The current `tests/` directory is a **solid foundation** for measuring progress, but it is **not yet a comprehensive map of the full parser product surface**.

Best concise description:

> The suite is broad, layered, and useful for regression control, but still selective. It gives high confidence in some surfaces and only sampled confidence in others.
