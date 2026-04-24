#!/bin/bash
# Test262 full-corpus runner.
#
# Expects a test262 checkout under $KESSEL_TEST262_DIR (env var) or
# vendor/test262 (default). Clone once with:
#
#   git clone https://github.com/tc39/test262.git vendor/test262
#
# The runner walks test/**/*.js, parses each front-matter-driven
# expectation (flags: onlyStrict | noStrict | module | async | raw;
# negative.phase: parse | early | resolution | runtime), invokes kessel
# once per applicable mode, and reports pass / fail per directory.
#
# Output: human-readable summary + optional JSON for baselining via
# tests/verifiers/verify_test262_full.js.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BINARY="${KESSEL_BIN:-${ROOT_DIR}/bin/kessel}"
TEST262_DIR="${KESSEL_TEST262_DIR:-${ROOT_DIR}/vendor/test262}"
TIMEOUT="${KESSEL_T262_TIMEOUT:-5}"
FILTER="${KESSEL_T262_FILTER:-}"    # substring filter on relative path
OUT_JSON="${KESSEL_T262_JSON:-}"    # optional path for machine-readable output
ALL_FAIL="${KESSEL_T262_ALL_FAILURES:-}"  # set=1 to record every failure (triage mode)

if [ ! -x "$BINARY" ]; then
  echo "Error: kessel binary not found at $BINARY"
  echo "Run 'task build' first or set KESSEL_BIN=..."
  exit 1
fi

if [ ! -d "$TEST262_DIR" ]; then
  echo "Test262 checkout not found at $TEST262_DIR"
  echo ""
  echo "Clone once:"
  echo "  git clone https://github.com/tc39/test262.git vendor/test262"
  echo ""
  echo "Or point at an existing checkout:"
  echo "  KESSEL_TEST262_DIR=/path/to/test262 $0"
  exit 2
fi

TEST_ROOT="${TEST262_DIR}/test"
if [ ! -d "$TEST_ROOT" ]; then
  echo "Error: $TEST262_DIR does not look like a test262 checkout (missing test/)."
  exit 2
fi

node --version >/dev/null 2>&1 || { echo "Error: node required"; exit 3; }

# Delegate the actual work to the JS driver. Bash is only responsible
# for discovery + the front-matter parse; keep the shell minimal.
DRIVER="${SCRIPT_DIR}/../verifiers/verify_test262_full.js"
if [ ! -f "$DRIVER" ]; then
  echo "Error: verifier script missing at $DRIVER"
  exit 4
fi

exec node "$DRIVER" \
  --test262-dir "$TEST262_DIR" \
  --binary "$BINARY" \
  --timeout "$TIMEOUT" \
  ${FILTER:+--filter "$FILTER"} \
  ${OUT_JSON:+--json-out "$OUT_JSON"} \
  ${ALL_FAIL:+--all-failures}
