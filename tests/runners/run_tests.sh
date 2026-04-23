#!/bin/bash

# Kessel Test Runner
# Usage: ./run_tests.sh [--update]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KESSEL_BIN="${KESSEL_BIN:-${SCRIPT_DIR}/../../bin/kessel}"
FIXTURES_DIR="${SCRIPT_DIR}/../fixtures"
EXPECTED_DIR="${SCRIPT_DIR}/../expected"

UPDATE_MODE=false
if [[ "$1" == "--update" ]]; then
    UPDATE_MODE=true
fi

PASSED=0
FAILED=0
SKIPPED=0
START_TIME=$(date +%s)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "================================"
echo "Kessel Parser Test Suite"
echo "================================"
echo ""

# Check binary exists
if [[ ! -x "$KESSEL_BIN" ]]; then
    echo -e "${RED}Error: kessel binary not found at $KESSEL_BIN${NC}"
    exit 1
fi

# Process all fixtures
for fixture in $(find "$FIXTURES_DIR" -name "*.js" | sort); do
    rel_path="${fixture#$FIXTURES_DIR/}"
    test_name="${rel_path%.js}"
    
    # Determine expected file path
    expected_file="${EXPECTED_DIR}/${rel_path%.js}.txt"
    
    echo -n "Testing ${test_name}... "

    # Path-based Lang mode injection: spec/typescript/* fixtures are .js on
    # disk but semantically TypeScript; tell the parser so `<T>` dispatches
    # to the TS handler instead of JSX. spec/jsx/* fixtures are JSX-by-path.
    lang_flag=""
    case "$rel_path" in
        spec/typescript/*) lang_flag="--lang=ts" ;;
        spec/jsx/*)        lang_flag="--lang=jsx" ;;
    esac

    # Run parser with timeout 10 (REQUIRED)
    exit_code=0
    output=$(timeout 10 "$KESSEL_BIN" parse $lang_flag "$fixture" 2>&1) || exit_code=$?
    
    if [[ ${exit_code:-0} -eq 124 ]]; then
        echo -e "${RED}TIMEOUT${NC}"
        FAILED=$((FAILED + 1))
        continue
    elif [[ ${exit_code:-0} -ne 0 ]]; then
        echo -e "${RED}CRASH (exit $exit_code)${NC}"
        FAILED=$((FAILED + 1))
        echo "  Output: $output"
        continue
    fi
    
    # Check for parse errors in output
    if echo "$output" | grep -q "Parse error"; then
        parse_errors=$(echo "$output" | grep -o "Parse errors: [0-9]*" | grep -o "[0-9]*" || echo "0")
        if [[ "$parse_errors" != "0" ]]; then
            echo -e "${RED}FAIL (parse errors: $parse_errors)${NC}"
            FAILED=$((FAILED + 1))
            continue
        fi
    fi
    
    # Check for expected file
    if [[ -f "$expected_file" ]]; then
        expected=$(cat "$expected_file")
        if [[ "$output" == "$expected" ]]; then
            echo -e "${GREEN}PASS${NC}"
            PASSED=$((PASSED + 1))
        else
            echo -e "${RED}FAIL (output mismatch)${NC}"
            FAILED=$((FAILED + 1))
            echo "  Diff (got vs expected):"
            diff <(echo "$output") <(echo "$expected") | head -20 || true
        fi
    else
        # No expected file, just verify it parses without errors
        if echo "$output" | grep -q "Parse errors: 0" || echo "$output" | grep -q "\"type\"" 2>/dev/null; then
            echo -e "${GREEN}PASS${NC} (parsed OK)"
            PASSED=$((PASSED + 1))
            
            # In update mode, create expected file
            if [[ "$UPDATE_MODE" == true ]]; then
                mkdir -p "$(dirname "$expected_file")"
                echo "$output" > "$expected_file"
                echo "  -> Updated expected file"
            fi
        else
            echo -e "${YELLOW}SKIP${NC} (no expected, unknown output format)"
            SKIPPED=$((SKIPPED + 1))
        fi
    fi
done

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

# Calculate pass rate
TOTAL=$((PASSED + FAILED))
if [[ $TOTAL -gt 0 ]]; then
    PASS_RATE=$((PASSED * 100 / TOTAL))
    echo "Pass rate: ${PASS_RATE}%"
    
    # Target: at least 80%
    if [[ $PASS_RATE -ge 80 ]]; then
        echo -e "${GREEN}Target achieved (>= 80%)${NC}"
    else
        echo -e "${RED}Target NOT achieved (< 80%)${NC}"
    fi
fi

if [[ $FAILED -gt 0 ]]; then
    exit 1
else
    exit 0
fi
