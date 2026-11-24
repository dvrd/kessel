#!/usr/bin/env bash
# strip-types fixture gate. Transformer phase M1 (`kessel strip-types`).
# Separate from the parser conformance harness and the lint gate: the
# transformer gets its OWN positive/negative fixture tree.
#
#   tests/strip-types/pass/  — erasable or supported runtime TS: strip must
#                              exit 0 and the emitted JavaScript must reparse.
#   tests/strip-types/fail/  — invalid or unsupported TS: strip must exit 1.
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
  fixture=${f##*/}
  expected="$ST_DIR/expected/${fixture%.*}.js"
  if [[ -f "$expected" ]] && ! diff -u "$expected" "$tmp"; then
    fail=$((fail + 1)); echo "FAIL: $f (stripped output differs)" >&2; continue
  fi
  if "$BIN" parse "$tmp" --lang=js >/dev/null 2>&1; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: $f (stripped output is not valid JS)" >&2
  fi
done

check_strip_runtime() {
  local fixture="$1" mode="$2"
  shift 2
  if "$BIN" strip-types "$fixture" "$@" > "$tmp" && node --input-type=module < "$tmp"; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1)); echo "FAIL: $fixture runtime behavior ($mode)" >&2
  fi
}
for fixture in "$ST_DIR"/pass/{declared-class-fields,derived-parameter-properties,enum-runtime,enum-references,namespace-runtime,expression-grouping}.ts; do
  check_strip_runtime "$fixture" pretty
  check_strip_runtime "$fixture" minified --minified
done

if node "$ROOT/tests/verifiers/verify_strip_module_scope.mjs" "$BIN"; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: stripped module scope" >&2
fi

# ESTree output omits per-specifier type modifiers. Check codegen's spelling
# directly, including after minified output is reparsed and formatted again.
module_specifiers="$ST_DIR/pass/module-specifiers.ts"
if "$BIN" codegen "$module_specifiers" > "$tmp" &&
   diff -u "$module_specifiers" "$tmp" &&
   "$BIN" codegen --minified "$module_specifiers" > "$tmp" &&
   "$BIN" codegen --lang=ts "$tmp" | diff -u "$module_specifiers" -; then
  pass=$((pass + 1))
else
  fail=$((fail + 1)); echo "FAIL: module specifier codegen changed the module syntax" >&2
fi

# fail/: invalid or unsupported TypeScript must be rejected (exit 1).
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
