#!/usr/bin/env bash
# Lint fixture gate. Separate from the parser conformance harness (HANDOFF
# design constraint #5): lint gets its OWN positive/negative fixture tree.
#
#   tests/lint/pass/  — files that must produce ZERO lint diagnostics (exit 0)
#   tests/lint/fail/  — files that must produce AT LEAST ONE diagnostic (exit 1)
#
# The runner asserts the process exit code per directory. `kessel lint` exits 1
# iff it printed any diagnostic (parse error or lint report), 0 otherwise.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BIN="$ROOT/bin/kessel"
LINT_DIR="$ROOT/tests/lint"

if [[ ! -x "$BIN" ]]; then
  echo "error: $BIN not found — run 'task build' first" >&2
  exit 1
fi

pass=0
fail=0

check() {
  local file="$1" want="$2"
  "$BIN" lint "$file" >/dev/null 2>&1
  local got=$?
  if [[ "$got" -eq "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $file (exit $got, expected $want)" >&2
  fi
}

shopt -s nullglob
for f in "$LINT_DIR"/pass/**/*.js "$LINT_DIR"/pass/*.js \
         "$LINT_DIR"/pass/**/*.ts "$LINT_DIR"/pass/*.ts; do
  check "$f" 0
done
for f in "$LINT_DIR"/fail/**/*.js "$LINT_DIR"/fail/*.js \
         "$LINT_DIR"/fail/**/*.ts "$LINT_DIR"/fail/*.ts; do
  check "$f" 1
done

# Config-gated rules (default-off): exercised explicitly via `--rule`.
#   check_rule <flag-value> <file> <expected-exit>
check_rule() {
  local rulearg="$1" file="$2" want="$3"
  "$BIN" lint --rule "$rulearg" "$file" >/dev/null 2>&1
  local got=$?
  if [[ "$got" -eq "$want" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: --rule $rulearg $file (exit $got, expected $want)" >&2
  fi
}

if [[ -f "$LINT_DIR/config/eqeqeq.js" ]]; then
  check_rule "eqeqeq:error"      "$LINT_DIR/config/eqeqeq.js"            1  # fires when enabled
  check_rule "no-debugger:off"   "$LINT_DIR/fail/no-debugger.js"        0  # off suppresses default-on
fi
if [[ -f "$LINT_DIR/config/constant-condition.js" ]]; then
  check_rule "no-constant-condition:error" "$LINT_DIR/config/constant-condition.js" 1
fi
if [[ -f "$LINT_DIR/config/redeclare.js" ]]; then
  check_rule "no-redeclare:error" "$LINT_DIR/config/redeclare.js" 1
  check_rule "no-redeclare:error" "$LINT_DIR/pass/no-redeclare-ok.js" 0
fi

# Scope-aware rules (M3), all default-off: exercised explicitly via --rule.
if [[ -f "$LINT_DIR/config/undef.js" ]]; then
  check_rule "no-undef:error"        "$LINT_DIR/config/undef.js"      1
  check_rule "no-undef:error"        "$LINT_DIR/config/undef-ok.js"   0
fi
if [[ -f "$LINT_DIR/config/unused.js" ]]; then
  check_rule "no-unused-vars:error"  "$LINT_DIR/config/unused.js"     1
  check_rule "no-unused-vars:error"  "$LINT_DIR/config/unused-ok.js"  0
fi
if [[ -f "$LINT_DIR/config/shadow.js" ]]; then
  check_rule "no-shadow:error"       "$LINT_DIR/config/shadow.js"     1
  check_rule "no-shadow:error"       "$LINT_DIR/config/shadow-ok.js"  0
fi

# Config-file (kessel.lint.json) loading + CLI-over-config precedence.
if [[ -f "$LINT_DIR/config/enable-eqeqeq.json" ]]; then
  "$BIN" lint --config "$LINT_DIR/config/enable-eqeqeq.json" "$LINT_DIR/config/eqeqeq.js" >/dev/null 2>&1
  if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --config enable-eqeqeq" >&2; fi
  "$BIN" lint --config "$LINT_DIR/config/enable-eqeqeq.json" --rule eqeqeq:off "$LINT_DIR/config/eqeqeq.js" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --rule overrides --config" >&2; fi
fi

# Auto-discovery: with no --config, `kessel lint` walks up from the working
# directory for a kessel.lint.json. Run from the fixture dir so the sibling
# config (eqeqeq:error) is picked up and the loose-equality compare fires.
if [[ -f "$LINT_DIR/config/autodiscover/kessel.lint.json" ]]; then
  ( cd "$LINT_DIR/config/autodiscover" && "$BIN" lint eqeqeq.js ) >/dev/null 2>&1
  if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: auto-discover kessel.lint.json" >&2; fi
fi

if [[ -f "$LINT_DIR/config/novar.js" ]]; then
  check_rule "no-var:error" "$LINT_DIR/config/novar.js" 1
  check_rule "no-var:off"   "$LINT_DIR/config/novar.js" 0
fi

# New AST-local rules (default-off), exercised via --rule + fixtures under config/.
if [[ -f "$LINT_DIR/config/operator-assignment.js" ]]; then
  check_rule "operator-assignment:error" "$LINT_DIR/config/operator-assignment.js" 1
fi
if [[ -f "$LINT_DIR/config/negated-condition.js" ]]; then
  check_rule "no-negated-condition:error" "$LINT_DIR/config/negated-condition.js" 1
fi

# Output formatters (Phase 8e): --format={unix,github,json} must emit the
# format-specific shape for a known diagnostic. Assert a signature substring of
# each formatter's output for a file that trips no-debugger (default-on).
printf 'debugger;\n' > "$LINT_DIR/.fmt-probe.js"
fmt_out=$("$BIN" lint --format=unix "$LINT_DIR/.fmt-probe.js" 2>&1)
if [[ "$fmt_out" == *":1:1: "*"[error/no-debugger]"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --format=unix ($fmt_out)" >&2; fi
fmt_out=$("$BIN" lint --format=github "$LINT_DIR/.fmt-probe.js" 2>&1)
if [[ "$fmt_out" == "::error file="*"line=1,col=1::"*"(no-debugger)" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --format=github ($fmt_out)" >&2; fi
fmt_out=$("$BIN" lint --format=json "$LINT_DIR/.fmt-probe.js" 2>&1)
if [[ "$fmt_out" == *'"ruleId":"no-debugger"'* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --format=json ($fmt_out)" >&2; fi
fmt_out=$("$BIN" lint --format=compact "$LINT_DIR/.fmt-probe.js" 2>&1)
if [[ "$fmt_out" == *": line 1, col 1, Error - "*"(no-debugger)"* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --format=compact ($fmt_out)" >&2; fi
fmt_out=$("$BIN" lint --format=checkstyle "$LINT_DIR/.fmt-probe.js" 2>&1)
if [[ "$fmt_out" == *'<checkstyle version="4.3">'*'source="no-debugger"'*'</checkstyle>'* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --format=checkstyle ($fmt_out)" >&2; fi
rm -f "$LINT_DIR/.fmt-probe.js"

echo "================================"
echo "Lint fixtures:"
echo "  Passed: $pass"
echo "  Failed: $fail"
echo "================================"
[[ "$fail" -eq 0 ]]
