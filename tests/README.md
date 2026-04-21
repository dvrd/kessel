# Kessel Test Suite

Automated test suite for the Kessel JavaScript parser.

## Structure

```
tests/
├── fixtures/           # JavaScript test files
│   ├── basic/         # Basic JS features (const, let, if, loops, etc.)
│   ├── es2015/        # ES6 features (arrow, classes, spread, etc.)
│   ├── es2020/        # ES2020 features (optional chain, nullish, BigInt)
│   ├── es2022/        # ES2022 features (class fields, private, static)
│   ├── es2025/        # ES2025 features (template literals, logical assign)
│   └── edge/          # Edge cases (labeled, comma, regex, destructuring)
├── test262_subset/    # Official Test262 suite (60 tests from tc39)
├── expected/          # Expected parser outputs (optional)
├── run_tests.sh       # Test runner for kessel fixtures
├── test262_fetch.sh   # Download Test262 subset from tc39/test262
├── run_test262.sh     # Test runner for Test262 subset
└── README.md          # This file
```

## Running Tests

### Kessel Fixture Tests

```bash
# Run all kessel fixture tests
./run_tests.sh

# Update expected outputs (creates expected files for new tests)
./run_tests.sh --update
```

### Test262 Suite

```bash
# Download Test262 subset (run once)
./test262_fetch.sh

# Run Test262 tests
./run_test262.sh [path_to_kessel_bin]
```

Default binary: `../kessel_bin`. Timeout: 10s per test.

## Test Criteria

A test passes if:
1. Parser exits with code 0
2. No timeout (max 10s per test)
3. Output contains `Parse errors: 0` or valid AST JSON

If an expected file exists, output must match exactly.

## Adding New Tests

1. Create a `.js` file in appropriate `fixtures/` subdirectory
2. Run `./run_tests.sh --update` to generate expected output
3. Verify the expected output is correct

## Current Status

- Total fixtures: 51
- Target: 80%+ pass rate
- Known issues documented below

## Known Issues

Based on test results, the following features have parsing issues:

| Category | Feature | Issue |
|----------|---------|-------|
| **Parser Hang** | switch statements | Infinite loop/timeout |
| **Parser Hang** | try/catch | Infinite loop/timeout |
| **Parser Hang** | throw statements | Infinite loop/timeout |
| **Parser Hang** | return statements | Infinite loop/timeout |
| **Parser Hang** | while/do-while | Infinite loop/timeout |
| **Parser Hang** | for loops | Infinite loop/timeout |
| **Parser Hang** | arrow functions | Infinite loop/timeout |
| **Parser Hang** | template literals | Infinite loop/timeout |
| **Parser Hang** | destructuring | Infinite loop/timeout |
| **Parser Hang** | class declarations | Infinite loop/timeout |
| **Parser Hang** | spread operator | Infinite loop/timeout |
| **Crash** | Object spread | Segfault (exit 139) |
| **Crash** | Array spread | Segfault (exit 139) |
| **Crash** | Logical assignment | Segfault (exit 139) |
| **Crash** | Async/await | Segfault (exit 139) |
| **Parse Error** | Optional chaining | Not recognized |
| **Parse Error** | Nullish coalescing | Not recognized |
| **Parse Error** | Object spread in object literal | Expected expression error |

### Currently Passing
- const/let/var declarations
- Simple if statements
- Variable assignment

### Test Results
- Total: 51 tests
- Passing: 8 (16%)
- Failing: 43 (84%)

The parser requires fixes for statement parsing, loop handling, and modern JS features support.

## Test262 Coverage

Kessel includes a subset of the official ECMAScript test suite (Test262) from tc39/test262 for broader language coverage.

### Test262 Results

- **Total tests**: 60 (subset of official tc39 suite)
- **Categories**: Expressions (20), Statements (20), Literals (10), Functions (10)
- **Pass rate**: 100% (60/60 tests passing)
- **Timeout**: 10s per test

### Test262 Breakdown

| Category | Count | Status |
|----------|-------|--------|
| Expressions | 20 | ✓ All passing |
| Statements | 20 | ✓ All passing |
| Literals | 10 | ✓ All passing |
| Functions | 10 | ✓ All passing |

The Test262 subset tests core ECMAScript functionality:
- Arithmetic and comparison operations
- Control flow (if, loops, switch)
- Variable declarations and functions
- String, numeric, and boolean literals
- Object and function basics

No Test262 issues detected.
