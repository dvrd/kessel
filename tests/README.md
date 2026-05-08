# Kessel Test Suite

## Directory Structure

```
tests/
├── coverage/             # OXC-style coverage harness (Odin)
│   ├── src/              # Suite loaders, runner, snapshot, invariants
│   └── snapshots/        # Committed snapshot baselines (10 files)
├── verifiers/            # Focused Node.js checks (8 scripts)
│   ├── verify_regression.js   # Path-based structural assertions vs reference
│   ├── verify_string_escapes.js  # String-literal decoding parity
│   ├── verify_lexer_tokens.js    # Lexer token-stream conformance
│   ├── verify_bench_regression.js  # Performance regression gate
│   ├── verify_crashes_known.js     # Known crash-class tracking
│   ├── fuzz_diff.js          # Differential fuzzing vs reference
│   └── fuzz_invalid.js       # Invalid-input mutation fuzzing
├── runners/               # Shell runners
│   ├── run_tests.sh       # Unit fixture golden-output runner
│   └── oxc_corpus_fetch.sh  # Vendor corpus fetcher
├── fixtures/              # Hand-authored JS/TS/JSX inputs (430 files)
│   ├── basic/             # Core language
│   ├── edge/              # Edge cases
│   ├── es2015–es2025/     # ECMAScript features by year
│   ├── negative/          # Must-reject programs
│   ├── regression/        # Bug-specific reproductions
│   ├── spec/              # Feature-family fixtures
│   └── recovery/          # Error-recovery fixtures
├── baselines/             # JSON baseline files for gated tests
└── expected/              # Pinned expected outputs for golden tests
```

## Running Tests

Three tiers:

```bash
task test              # Primary gate — coverage harness (50K+ fixtures) + unit tests
task test:quick        # Fast dev loop — unit + regression + lexer (~8s)
task test:release      # Zero-tolerance pre-release gate
```

### Primary Gate (`task test`)

Runs the coverage harness across 50K+ fixtures from test262, Babel, TypeScript,
and ESTree corpora, plus 430 hand-authored unit fixtures. The gate passes when
the current run matches the committed snapshot files.

```bash
task test                      # Run the gate
task test:coverage:update      # Regenerate snaps after a deliberate fix
task test:conformance:report   # Human-readable summary
```

### Individual Checks

```bash
task test:unit          # 430 golden-output unit fixtures
task test:regression    # 11 structural assertions vs reference
task test:real          # 467 real-world files, crash detection
task test:estree        # String-escape decoding parity
task test:lexer-tokens  # Lexer span structure conformance
task test:fuzz          # Differential fuzzer (100 random programs)
task test:fuzz:invalid  # Invalid-input mutation fuzzer (300 mutations)
task test:crashes-known # Known crash-class tracking
```

### Conformance Numbers

```bash
task test:conformance:report       # Human-readable
task test:conformance:report:json  # Machine-readable
```

## Adding Tests

### Regression fixture

When fixing a bug:

1. Create `tests/fixtures/regression/NNN_name.js` with a minimal reproduction.
2. Add a path-based check in `tests/verifiers/verify_regression.js`.
3. Validate by revert: revert the fix, confirm the check fails.

### Misc fixture (coverage museum)

1. Add a file to `tests/coverage/misc/pass/` or `tests/coverage/misc/fail/`.
2. Run `task test:coverage:update` to regenerate the snap baseline.
3. Commit the fixture + snap diff.

### Unit fixture

1. Create `tests/fixtures/<category>/NNN_name.js`
2. Run `tests/runners/run_tests.sh --update` to generate expected output.
3. Commit both the fixture and the expected file.
