# Wave 3 Item 8 — TS-ESTree Shape Alignment (EST-4)

**Goal:** Make Kessel's TS node emit match
`@typescript-eslint/typescript-estree` field-by-field for the 10
`spec/typescript/*` fixtures. Currently they parse cleanly but their
JSON shape diverges from the canonical TS-ESTree format.

## Status audit (2026-04-22)

Spec-fixtures baseline (`tests/baselines/spec_fixtures_baseline.json`)
currently tracks ONLY the ES year buckets (edge, es2015..es2025), not
the TS / JSX / unicode / asi / escapes / regex_disambiguation buckets.
So today's "56/56 pass" refers to ES fixtures only. The TS fixtures
are not gated by any JSON-diff gate.

The claim from SESSION_REPORT.md — "10 spec/typescript/* fixtures
parse clean but shape diverges from @typescript-eslint/typescript-estree"
— is untested today. There is no runnable gate producing that diff.

## Missing infrastructure

`bench/oxc_compare/cli/src/main.rs` (`oxc_cli_equiv`) uses
`to_estree_js_json`, which strips all TS-specific fields
(typeParameters, typeAnnotation, typeArguments). So even for `.ts`
input it produces a pure-JS AST, not a TS-ESTree one.

To build a real comparison, ONE of:

1. **Extend `oxc_cli_equiv` with a `--ts` flag** that uses OXC's
   `to_estree_ts_json` (if available in the oxc crate) or equivalent.
   Estimate: 30 minutes if the API exists. Plus a Rust rebuild.
2. **Shell out to `@typescript-eslint/typescript-estree`** via a Node
   script. Adds a Node dep (NO — Kessel has a zero-dep policy, but
   the bench harness already uses Node for acorn/babel comparisons).
3. **Shell out to `oxc-parser` npm package** from a Node script —
   exposes `parseSync` with TS output. Used in OXC's own test suite.

Option #3 is cleanest for EST-4 work specifically.

## Proposed workflow for EST-4

1. Write `tests/verifiers/verify_ts_estree.js` that:
   - For each `spec/typescript/*.js` fixture (renamed to `.ts` or
     passed through a temp file with `.ts` extension):
     - Run `@typescript-eslint/typescript-estree`.
     - Run Kessel.
     - Compare the emitted JSON with deep-diff.
   - Emit a baseline `tests/baselines/ts_estree_baseline.json` that
     locks known divergences.
2. Fix divergences one-by-one. Each is usually a single field rename,
   a missing field, or an extra Kessel-only field. Low-risk, incremental.

## Likely divergence classes (sampled from Kessel output of
## `spec/typescript/001_generic_function.js`)

- `TSTypeParameter` has Kessel-only fields `in: false, out: false,
  const: false`. TS-ESTree may omit these unless true. **Gate**: emit
  these only when non-default.
- `TSTypeParameterDeclaration.start`/`end` in Kessel covers only
  `<...>`. TS-ESTree may cover the full range. **Check** against
  real TS-ESTree output.
- Ordering of fields within nodes is NOT significant for
  structural-JSON comparison (most tools sort or are order-insensitive),
  but if we do byte-exact diff, Kessel's emit order differs from OXC's
  (`type, start, end, ...` vs `type, id, ..., start, end`).

## Estimated effort

- Infrastructure (Node verifier + baseline): 1 day.
- Fixture-by-fixture shape fixes: 1 day (10 fixtures, ~1 hour each
  including regen of the baseline).
- Total: 2 days.

## Priority

Lower than:
- Wave 3 item 7 (`<` trial-parse) — actively crashes.
- ESM module record — in flight.
- `range: boolean` (EST-2) — high-value for consumers.

Higher than:
- NAPI / Visitor — bigger, later phase.

Recommend tackling AFTER `<` trial-parse lands and the TS fixture set
stabilises.
