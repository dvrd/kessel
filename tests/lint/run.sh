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

# ignorePatterns: files matching a config ignore glob are skipped entirely.
if [[ -f "$LINT_DIR/config/ignore.json" ]]; then
  printf 'debugger;\n' > "$LINT_DIR/.ig-probe.min.js"
  "$BIN" lint --config "$LINT_DIR/config/ignore.json" "$LINT_DIR/.ig-probe.min.js" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: ignorePatterns skips *.min.js" >&2; fi
  printf 'debugger;\n' > "$LINT_DIR/.ig-probe.js"
  "$BIN" lint --config "$LINT_DIR/config/ignore.json" "$LINT_DIR/.ig-probe.js" >/dev/null 2>&1
  if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: non-ignored file still linted" >&2; fi
  rm -f "$LINT_DIR/.ig-probe.min.js" "$LINT_DIR/.ig-probe.js"
fi

# overrides: per-glob rule blocks apply on top of base rules for matching files.
if [[ -f "$LINT_DIR/config/overrides.json" ]]; then
  printf 'debugger;\n' > "$LINT_DIR/.ov-probe.js"
  "$BIN" lint --config "$LINT_DIR/config/overrides.json" "$LINT_DIR/.ov-probe.js" >/dev/null 2>&1
  if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: base rule (no-debugger:off) applies to plain file" >&2; fi
  printf 'debugger;\n' > "$LINT_DIR/.ov-probe.test.js"
  "$BIN" lint --config "$LINT_DIR/config/overrides.json" "$LINT_DIR/.ov-probe.test.js" >/dev/null 2>&1
  if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: per-glob override re-enables rule for *.test.js" >&2; fi
  rm -f "$LINT_DIR/.ov-probe.js" "$LINT_DIR/.ov-probe.test.js"
fi

# extends: a config inherits its parent's rules; the child can override them.
if [[ -f "$LINT_DIR/config/extends-child.json" ]]; then
  printf 'debugger;\n' > "$LINT_DIR/.ex-probe.js"
  "$BIN" lint --config "$LINT_DIR/config/extends-child.json" "$LINT_DIR/.ex-probe.js" >/dev/null 2>&1
  if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: extends inherits parent no-debugger" >&2; fi
  printf 'if (a == b) {}\n' > "$LINT_DIR/.ex-probe2.js"
  "$BIN" lint --config "$LINT_DIR/config/extends-child.json" "$LINT_DIR/.ex-probe2.js" >/dev/null 2>&1
  if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: extends child adds own eqeqeq" >&2; fi
  rm -f "$LINT_DIR/.ex-probe.js" "$LINT_DIR/.ex-probe2.js"
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
if [[ -f "$LINT_DIR/config/no-labels.js" ]]; then
  check_rule "no-labels:error"        "$LINT_DIR/config/no-labels.js"        1
fi
if [[ -f "$LINT_DIR/config/no-multi-assign.js" ]]; then
  check_rule "no-multi-assign:error"  "$LINT_DIR/config/no-multi-assign.js"  1
fi
if [[ -f "$LINT_DIR/config/no-ternary.js" ]]; then
  check_rule "no-ternary:error"       "$LINT_DIR/config/no-ternary.js"       1
fi
if [[ -f "$LINT_DIR/config/no-new.js" ]]; then
  check_rule "no-new:error"           "$LINT_DIR/config/no-new.js"           1
fi
if [[ -f "$LINT_DIR/config/no-return-await.js" ]]; then
  check_rule "no-return-await:error"  "$LINT_DIR/config/no-return-await.js"  1
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
fmt_out=$("$BIN" lint --format=gitlab "$LINT_DIR/.fmt-probe.js" 2>&1)
if [[ "$fmt_out" == *'"check_name":"no-debugger"'*'"severity":"major"'* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --format=gitlab ($fmt_out)" >&2; fi
fmt_out=$("$BIN" lint --format=junit "$LINT_DIR/.fmt-probe.js" 2>&1)
if [[ "$fmt_out" == *'<testsuite name="kessel"'*'<failure message='*'</testsuites>'* ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --format=junit ($fmt_out)" >&2; fi
rm -f "$LINT_DIR/.fmt-probe.js"

# Warning-severity flags (Phase 8e): --quiet and --max-warnings. no-debugger is
# default-on; forcing it to :warn exercises the warning path without a new rule.
printf 'debugger;\n' > "$LINT_DIR/.warn-probe.js"
"$BIN" lint --rule no-debugger:warn "$LINT_DIR/.warn-probe.js" >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: warning fails run by default" >&2; fi
"$BIN" lint --rule no-debugger:warn --quiet "$LINT_DIR/.warn-probe.js" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --quiet drops warning failure" >&2; fi
"$BIN" lint --rule no-debugger:warn --max-warnings 0 "$LINT_DIR/.warn-probe.js" >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --max-warnings 0 gate" >&2; fi
"$BIN" lint --rule no-debugger:warn --max-warnings 1 "$LINT_DIR/.warn-probe.js" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --max-warnings 1 tolerates one warning" >&2; fi
rm -f "$LINT_DIR/.warn-probe.js"

# Severity alias flags (Phase 8e): --deny/--warn/--allow are shorthands for
# --rule name:error|warn|off.
printf 'debugger;\n' > "$LINT_DIR/.alias-probe.js"
"$BIN" lint --allow no-debugger "$LINT_DIR/.alias-probe.js" >/dev/null 2>&1
if [[ $? -eq 0 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --allow silences default-on rule" >&2; fi
printf 'let x = 0;\nx = x + 1;\n' > "$LINT_DIR/.alias-probe.js"
"$BIN" lint --deny operator-assignment "$LINT_DIR/.alias-probe.js" >/dev/null 2>&1
if [[ $? -eq 1 ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: --deny enables default-off rule" >&2; fi
rm -f "$LINT_DIR/.alias-probe.js"

echo "================================"
echo "Lint fixtures:"
echo "  Passed: $pass"
echo "  Failed: $fail"
echo "================================"
[[ "$fail" -eq 0 ]]
