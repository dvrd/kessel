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

Run `task test:format` for the pinned Prettier examples. Set `KESSEL_PRETTIER`
to the installed reference package to compare more widths and styles. After
`task test:real:fetch`, run `task test:format:real` to check that formatting the
release corpus preserves syntax and comments and that a second pass is stable.

### Primary Gate (`task test`)

CI uses Odin's `dev-2026-11` release for this gate. Fetch the four pinned
corpora from a fresh checkout before running it. The fetcher reuses existing
checkouts at the expected revisions.

```bash
bash tests/runners/oxc_corpus_fetch.sh
```

Runs the coverage harness across 50K+ fixtures from test262, Babel, TypeScript,
and ESTree corpora, plus 430 hand-authored unit fixtures. The gate passes when
the current run matches the committed snapshot files.

```bash
task test                      # Run the gate
task test:coverage:update      # Regenerate snaps after a deliberate fix
task test:conformance:report   # Human-readable summary
```

### Lint reference checks

Run `task test:lint:reference -- /path/to/oxlint` to compare lint configuration,
binding diagnostics, and autofixes with the oxlint version in `OXC_ORACLE.json`.
The task can also use `oxlint` on your path.
The React configuration checks cover plugin aliases, category severities,
inherited settings and file-specific overrides.
The control-flow checks also execute 343 combinations of transfers through
catch and finally to verify which statements JavaScript can reach.
Add `--upstream` to compare the primary diagnostic ranges on all 85 getter
fixtures, 63 reachability fixtures, 86 switch fallthrough fixtures and 441
React Hooks fixtures in the pinned Oxc checkout at `../oxc`. The comparison
records the two known differences involving duplicate and shadowed dependencies.
It also compares the fixed syntax trees for all 16 dependency-edit fixtures.
In two examples, Kessel includes a captured parameter in a newly created
callback dependency list. A runtime SDK regression exercises two renders with
different parameter values.

Add `--corpus` to measure agreement on the pinned real-world JavaScript files.
Run `task test:real:fetch` to provision them. The report counts matching and
tool-specific byte ranges for getter-return, no-unreachable and no-fallthrough,
including duplicate diagnostics. An identical file has the same reports from
both tools for that rule. Some reference warnings cover code that executes.

### TypeScript declaration checks

With the locked dependencies installed in `bench` and `npm/kessel`, run
`task test:dts` to compare native CLI and SDK declarations and diagnostics with
TypeScript 5.9.3 and type-check a downstream consumer. Run `task test:dts:corpus`
with the TypeScript fixtures available under `tests/vendor` to compare each
single-file input in the upstream isolated-declaration compiler cases. The task
exits with a failure on a diagnostic or declaration AST difference. The separate
`task test:dts:namespaces` compares all single-file inputs in TypeScript’s
`conformance/internalModules` directory, including its invalid-source fixtures.

### Release Gate (`task test:release`)

The Rust comparison binaries use the pinned sibling OXC checkout, and the
JavaScript verifiers use the locked dependencies under `bench/` and
`npm/kessel/`. The release gate includes both declaration comparisons and
checks formatting against the pinned real-world files.

```bash
git clone --no-checkout https://github.com/oxc-project/oxc.git ../oxc
git -C ../oxc checkout --detach "$(node -p "require('./OXC_ORACLE.json').oxc_git_commit")"
(cd bench && npm ci)
(cd npm/kessel && npm ci)
task bench:oxc:verify
```

The release gate reads 467 real-world JavaScript files. The fetch task downloads
individual files from the npm package versions in `tests/baselines/real_world.sources`
and checks each file against `tests/baselines/real_world.sha256`. It reuses
verified local files and reports a checksum error if an existing file differs.

```bash
task test:release        # Fetches any missing real-world fixtures
```

The release gate builds the reference revision pinned in the Taskfile with the
same Odin compiler and options as the candidate. It measures both binaries on
the same host and applies the existing 10% per-file and 5% geometric-mean
thresholds. Keep the pinned reference revision available in the checkout.
Use `task test:bench:regression` to compare against the stored timings from the
original benchmark host.

After npm publishes a release, the release workflow checks the public package
on all five target platforms and compares each installed binary's SHA-256 with
the corresponding build artifact. Run `task test:npm:registry -- MAJOR.MINOR.PATCH`
with the exact version to repeat the install locally. Set `KESSEL_PACKAGE_BINARY`
to the release library's path to include the digest check. The task uses a fresh
npm cache, verifies all five native package versions, and parses TSX through the
CommonJS and ESM entry points on the host's installed binary.

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
