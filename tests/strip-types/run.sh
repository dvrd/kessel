#!/usr/bin/env bash
# strip-types fixture gate. Transformer phase M1 (`kessel strip-types`).
# Separate from the parser conformance harness and the lint gate: the
# transformer gets its OWN positive/negative fixture tree.
#
#   tests/strip-types/pass/  — erasable TS: strip MUST exit 0, and the emitted
#                              JavaScript MUST re-parse cleanly with zero TS
#                              tokens surviving (a second parse as plain JS).
#   tests/strip-types/fail/  — non-erasable TS (enum / namespace-with-body /
#                              parameter property / import=): strip MUST exit 1.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/bin/kessel"
ST_DIR="$ROOT/tests/strip-types"

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found — run 'task build' first" >&2
  exit 1
fi

pass=0
fail=0
tmp="$(mktemp -t kessel-strip.XXXXXX.js)"
trap 'rm -f "$tmp"' EXIT

# pass/: strip must succeed AND its output must re-parse as valid JavaScript.
shopt -s nullglob
for f in "$ST_DIR"/pass/*.ts "$ST_DIR"/pass/*.tsx; do
  if ! "$BIN" strip-types "$f" > "$tmp" 2>/dev/null; then
    fail=$((fail + 1)); echo "FAIL: $f (strip-types exited non-zero)" >&2; continue
  fi
  if "$BIN" parse "$tmp" --lang=js >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: $f (stripped output is not valid JS)" >&2
  fi
done

# fail/: non-erasable TS must be rejected (exit 1).
for f in "$ST_DIR"/fail/*.ts "$ST_DIR"/fail/*.tsx; do
  "$BIN" strip-types "$f" >/dev/null 2>&1
  if [[ $? -eq 1 ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: $f (expected strip-types to reject)" >&2
  fi
done

echo "================================"
echo "strip-types fixtures:"
echo "  Passed: $pass"
echo "  Failed: $fail"
echo "================================"
[[ "$fail" -eq 0 ]]
