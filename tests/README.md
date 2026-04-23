# Kessel Test Suite

## Directory Structure

```
tests/
├── runners/                 # Test harnesses and orchestration scripts
│   ├── run_tests.sh         # Positive-fixture golden runner (statistics stripped)
│   ├── run_test262.sh       # ECMA-262 syntax-subset runner
│   ├── run_spec_fixtures.js # ES spec fixtures vs OXC, baseline-locked
│   └── test262_fetch.sh     # Bootstrap a local test262 checkout
│
├── verifiers/               # JS scripts that compare Kessel vs reference parsers
│   ├── verify_regression.js # Structural regression checks (11 checks, OXC cross-ref)
│   ├── verify_string_escapes.js  # String Literal.value round-trip vs OXC
│   ├── verify_integration.js     # Deep raw-transfer walk vs OXC parseSync
│   ├── verify_json_deep.js       # Full JSON tree diff vs OXC/Acorn/Babel
│   ├── verify_raw.js             # Raw transfer buffer smoke test
│   ├── verify_raw_deep.js        # Raw transfer deep walk
│   ├── verify_invariants.js      # Structural ESTree invariants (467-file corpus)
│   ├── verify_negative.js        # Parser-negative fixtures must be rejected
│   ├── verify_spec_compliance.js # Deep compare vs OXC, baseline-locked
│   ├── verify_test262_subset.js  # Test262 subset, category-aware, baseline-locked
│   ├── verify_lexical_surfaces.js # Per-fixture AST assertions for lexical/tokenization cases
│   ├── report_surface_status.js  # Surface-by-surface coverage reporter (reads surface_status.json)
│   ├── estree_nodes_coverage.js  # Node-type coverage matrix (1 fixture per type)
│   └── fuzz_diff.js              # Differential fuzzer (Kessel vs OXC)
│
├── fixtures/                # Hand-authored JS inputs
│   ├── basic/               # Core language: const, let, if, while, for, switch, try
│   ├── edge/                # Edge cases: regex, ternary, IIFE, generators, templates
│   ├── es2015/              # ES2015: classes, arrows, destructuring, templates
│   ├── es2020/              # ES2020: optional chaining, nullish, BigInt
│   ├── es2022/              # ES2022: class fields, private, static blocks, top-level await
│   ├── es2025/              # ES2025: decorators, pipeline, pattern matching
│   ├── real/                # Realistic patterns: Redux, Express, React hooks, etc.
│   ├── recovery/            # Error recovery: extra semicolons, trailing commas
│   ├── regression/          # Bug-specific regression fixtures (one per fix)
│   └── spec/
│       ├── ambiguity/       # JS/TS/JSX boundary cases (verify_ambiguity.js)
│       ├── interactions/    # Stacked-feature combinations (run_spec_fixtures.js)
│       └── lexical/         # Tokenization-sensitive cases (verify_lexical_surfaces.js)
│
├── expected/                # Pinned expected outputs (mirrors fixtures/)
│   └── <same dirs as fixtures>/
│
├── baselines/               # JSON baseline files for gated tests
│   ├── invariants_baseline.json
│   ├── spec_baseline.json
│   └── spec_fixtures_baseline.json
│
└── test262/                 # ECMA-262 conformance subset (66 curated tests)
```

## Running Tests

All tests are wired through the Taskfile. From the project root:

```bash
task test              # Run everything (positive + negative + regression + real-world + more)
task test:unit         # Positive fixtures with pinned AST JSON (~1s)
task test:negative     # Parser-negative fixtures, baseline-locked
task test:negative:strict # Same gate, but any accepted invalid program fails
task test:regression   # 11 structural checks vs OXC, revert-validated (~2s)
task test:estree       # String-escape + deep tree walk vs OXC (~5s)
task test:real         # 467 real-world files, crash + parse-error detection (~3min)
task test:test262      # ECMA-262 syntax subset (66 parse-smoke tests, exit-code only)
# Additional gates (not yet wired into the Taskfile):
node tests/verifiers/verify_test262_subset.js    # category-aware Test262 gate
node tests/verifiers/verify_ambiguity.js         # JS/TS/JSX boundary gate
node tests/verifiers/verify_recovery.js          # recovery-quality gate
node tests/verifiers/verify_deep_families.js     # per-family deep-diff gate
node tests/verifiers/verify_lexical_surfaces.js  # tokenization-sensitive gate
node tests/verifiers/report_surface_status.js    # surface-by-surface summary
task test:invariants   # Structural ESTree invariants across 467-file corpus
task test:nodes        # Node-type coverage (1 fixture per emit path)
task test:fuzz         # Differential fuzzer (100 random programs vs OXC)
```

## Test Categories

### Unit Tests (`task test:unit`)

Runs `tests/runners/run_tests.sh`. Positive fixtures parse with `bin/kessel`
and compare against the matching `tests/expected/<path>.txt`, with the trailing
statistics block stripped before diffing so allocator-noise does not flap the
golden files. Parser-negative fixtures are excluded here and owned by
`tests/verifiers/verify_negative.js`. Semantic early-error fixtures are a
separate surface. Known-positive gaps are not skipped here:
if a valid fixture crashes, mis-parses, or lacks an expected file, `test:unit`
fails visibly. Use `--update` to create new expected files after deliberate
output changes.

### Negative Fixtures (`task test:negative`)

Runs `tests/verifiers/verify_negative.js`. Every file under
`tests/fixtures/negative/` must be rejected by the parser. The baseline
captures known misses so regressions fail immediately while improvements can be
relocked with `--update`. Semantic early-error fixtures are tracked separately
and are not part of this parser gate.

### Regression Tests (`task test:regression`)

Runs `tests/verifiers/verify_regression.js`. Each of the 11 checks targets a
specific bug fixed during development (e.g. I-1 through I-8, O-1 through O-3).
Every check uses **path-based assertions** — not flat type counts — to catch
the exact bug class. Each check has been **validated by revert**: reverting
the specific fix causes exactly the corresponding check to fail.

### ESTree Verification (`task test:estree`)

Two complementary checks:
1. **String-escape decoding** — walks every `Literal.value` in Kessel's
   JSON output and compares byte-for-byte against OXC across key real-world files.
2. **Deep integration walk** — parses with Kessel's raw-transfer binary format
   AND with OXC's JS bindings, walks both trees field-by-field (jquery.js:
   51,406 fields, react-dom.dev.js: 104,989 fields).

### Real-World Parse (`task test:real`)

Parses all 467 files in `bench/real_world/` with a 30-second timeout per file.
Reports both parse errors AND crash/SIGSEGV (the previous version silently
masked crashes). Current state: **467/467 pass, 0 crashes, 0 parse errors**.

## Adding Tests

### Regression fixture

When fixing a bug:

1. Create `tests/fixtures/regression/NNN_descriptive_name.js` with a minimal
   reproduction that triggers the bug on the pre-fix code.
2. Add a path-based check in `tests/verifiers/verify_regression.js` that
   asserts the specific structural property the fix provides.
3. Generate expected output: `./bin/kessel parse <fixture> > tests/expected/regression/NNN_descriptive_name.txt 2>&1`
4. Validate by revert: revert your fix, rebuild, confirm the check fails.
5. Restore the fix, rebuild, confirm all tests pass.

### Unit fixture

1. Create `tests/fixtures/<category>/NNN_name.js`
2. Run `tests/runners/run_tests.sh --update` to generate expected output
3. Commit both the fixture and the expected file
