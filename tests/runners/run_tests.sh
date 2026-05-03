#!/bin/bash

# Kessel positive-fixture runner.
# Usage: ./run_tests.sh [--update]
#
# Ownership:
# - Positive fixtures with pinned stdout live under tests/expected/.
# - Negative / early-error fixtures are owned by tests/verifiers/verify_negative.js.
# - Positive fixtures are all enforced here. Known gaps must fail visibly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
KESSEL_BIN="${KESSEL_BIN:-${ROOT_DIR}/bin/kessel}"
FIXTURES_DIR="${SCRIPT_DIR}/../fixtures"
EXPECTED_DIR="${SCRIPT_DIR}/../expected"

UPDATE_MODE=false
if [[ "${1:-}" == "--update" ]]; then
    UPDATE_MODE=true
fi

PASSED=0
FAILED=0
SKIPPED=0
START_TIME=$(date +%s)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "================================"
echo "Kessel Positive Fixture Test Suite"
echo "================================"
echo ""

if [[ ! -x "$KESSEL_BIN" ]]; then
    echo -e "${RED}Error: kessel binary not found at $KESSEL_BIN${NC}"
    exit 1
fi

normalize_output() {
    awk '
        /^--- Statistics ---$/ { exit }
        { print }
    ' "$1"
}

is_skipped_fixture() {
    local rel_path="$1"

    # Session 11+: every fixture is enforced here, on every run.
    # Negative / early_errors fixtures are also separately gated by
    # verify_negative.js (which only checks the error count); the unit
    # runner additionally locks the byte-for-byte AST + error JSON
    # output. "Skipped" is no longer a dumping ground for parser gaps.
    return 1
}

while IFS= read -r fixture; do
    rel_path="${fixture#$FIXTURES_DIR/}"
    test_name="${rel_path%.js}"

    if is_skipped_fixture "$rel_path"; then
        echo -e "Testing ${test_name}... ${YELLOW}SKIP${NC} (known failure or negative-gate owned)"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    expected_file="${EXPECTED_DIR}/${rel_path%.js}.txt"

    echo -n "Testing ${test_name}... "

    output_file=$(mktemp)
    normalized_output_file=$(mktemp)
    normalized_expected_file=$(mktemp)
    exit_code=0

    # Auto-detect language from directory path. Fixtures under spec/typescript/*
    # need `--lang=ts`, under spec/jsx/* need `--lang=jsx`. Without this, TS
    # angle-bracket assertions and JSX fragments parse with errors in JS mode.
    lang_flag=""
    case "$rel_path" in
        spec/typescript/*)  lang_flag="--lang=ts"  ;;
        spec/jsx/*)         lang_flag="--lang=jsx" ;;
        # spec/tsx/ added in S26 W2 — first-class TSX category for
        # generics-on-components, as-casts in JSX children, polymorphic
        # `as=` props, ref typing. Same auto-discovery as spec/jsx/.
        spec/tsx/*)         lang_flag="--lang=tsx" ;;
        # Ambiguity fixtures exercise TS+JSX disambiguation (<Type>expr vs
        # <Tag>, generic-call vs relational, generic-arrow, etc.). They need
        # TSX mode so both grammars are live.
        spec/ambiguity/*)   lang_flag="--lang=tsx" ;;
        # Interaction fixtures are intentionally a mixed-dialect bucket:
        # most are plain JS, but specific files exercise JSX or TS together
        # with other features. Rather than move them into dialect-specific
        # dirs (which hides the "interaction" intent), detect the dialect
        # from the filename marker: `_jsx_` -> JSX, `_ts_` -> TS.
        spec/interactions/*_jsx_*) lang_flag="--lang=jsx" ;;
        spec/interactions/*_ts_*)  lang_flag="--lang=ts"  ;;
        es2025/*ts_interface*|es2025/*ts_type*|es2025/*ts_enum*) lang_flag="--lang=ts" ;;
        # JSX/TSX fixtures outside the dialect dirs need explicit mode.
        recovery/jsx_ts/*)        lang_flag="--lang=tsx" ;;
        negative/truncation/*jsx*) lang_flag="--lang=jsx" ;;
        es2025/*jsx*|es2025/*fragment*) lang_flag="--lang=jsx" ;;
    esac

    if [[ -n "$lang_flag" ]]; then
        cmd=(timeout 10 "$KESSEL_BIN" parse "$lang_flag" "$fixture")
    else
        cmd=(timeout 10 "$KESSEL_BIN" parse "$fixture")
    fi
    if ! "${cmd[@]}" >"$output_file" 2>&1; then
        exit_code=$?
    fi

    if [[ $exit_code -eq 124 ]]; then
        echo -e "${RED}TIMEOUT${NC}"
        FAILED=$((FAILED + 1))
        rm -f "$output_file" "$normalized_output_file" "$normalized_expected_file"
        continue
    fi

    if [[ $exit_code -ne 0 ]]; then
        echo -e "${RED}CRASH (exit $exit_code)${NC}"
        FAILED=$((FAILED + 1))
        echo "  Output:"
        cat "$output_file"
        rm -f "$output_file" "$normalized_output_file" "$normalized_expected_file"
        continue
    fi

    # Parse-errors-expected fixtures: recovery/* exercise error recovery;
    # spec/ambiguity/001,002,004 exercise the TSX grammar restriction that
    # forbids `<Type>expr` / generic-arrow-without-trailing-comma (OXC
    # rejects these with parse errors too); negative/* and early_errors/*
    # are intentionally malformed and pin the rejected output. The gate on
    # these fixtures is the STABILITY of emitted AST + error list against
    # a golden, not error-free parsing. Everything else must parse clean.
    case "$rel_path" in
        recovery/*) ;;
        negative/*) ;;
        early_errors/*) ;;
        spec/ambiguity/001_ts_assertion_vs_jsx_simple.js) ;;
        spec/ambiguity/002_ts_assertion_vs_jsx_paren.js) ;;
        spec/ambiguity/004_generic_arrow_vs_relational.js) ;;
        # BOM + #!hashbang is rejected by OXC/Acorn/Babel per
        # ECMA-262 hashbang syntax rules. Kessel now emits a matching
        # "Invalid character `!`" error; the fixture's pinned output
        # includes that error, so we skip the parse-errors-fatal gate
        # and fall through to the golden diff below.
        spec/lexical/001_hashbang_bom.js) ;;
        *)
            if grep -Eq 'Parse errors\s*(\([1-9][0-9]*\)|:\s*[1-9][0-9]*)' "$output_file"; then
                parse_errors=$(grep -Eo 'Parse errors\s*(\([0-9]+\)|:\s*[0-9]+)' "$output_file" | grep -Eo '[0-9]+' | tail -n1)
                echo -e "${RED}FAIL (parse errors: ${parse_errors:-?})${NC}"
                FAILED=$((FAILED + 1))
                rm -f "$output_file" "$normalized_output_file" "$normalized_expected_file"
                continue
            fi
            ;;
    esac

    if [[ ! -f "$expected_file" ]]; then
        if [[ "$UPDATE_MODE" == true ]]; then
            mkdir -p "$(dirname "$expected_file")"
            cp "$output_file" "$expected_file"
            echo -e "${GREEN}PASS${NC} (created expected)"
            PASSED=$((PASSED + 1))
        else
            echo -e "${RED}FAIL${NC} (missing expected file: ${expected_file#$ROOT_DIR/})"
            FAILED=$((FAILED + 1))
        fi
        rm -f "$output_file" "$normalized_output_file" "$normalized_expected_file"
        continue
    fi

    normalize_output "$output_file" > "$normalized_output_file"
    normalize_output "$expected_file" > "$normalized_expected_file"

    if cmp -s "$normalized_output_file" "$normalized_expected_file"; then
        echo -e "${GREEN}PASS${NC}"
        PASSED=$((PASSED + 1))
    elif [[ "$UPDATE_MODE" == true ]]; then
        cp "$output_file" "$expected_file"
        echo -e "${GREEN}PASS${NC} (updated expected)"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAIL (output mismatch)${NC}"
        FAILED=$((FAILED + 1))
        echo "  Diff (got vs expected, statistics stripped):"
        diff "$normalized_output_file" "$normalized_expected_file" | head -20 || true
    fi

    rm -f "$output_file" "$normalized_output_file" "$normalized_expected_file"
done < <(find "$FIXTURES_DIR" -name "*.js" -type f | LC_ALL=C sort)

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "================================"
echo "Results:"
echo "  Passed:   $PASSED"
echo "  Failed:   $FAILED"
echo "  Skipped:  $SKIPPED"
echo "  Total:    $((PASSED + FAILED + SKIPPED))"
echo "  Time:     ${DURATION}s"
echo "================================"

TOTAL=$((PASSED + FAILED))
if [[ $TOTAL -gt 0 ]]; then
    PASS_RATE=$((PASSED * 100 / TOTAL))
    echo "Pass rate: ${PASS_RATE}%"

    if [[ $PASS_RATE -ge 80 ]]; then
        echo -e "${GREEN}Target achieved (>= 80%)${NC}"
    else
        echo -e "${RED}Target NOT achieved (< 80%)${NC}"
    fi
fi

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
