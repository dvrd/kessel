#!/bin/bash
# Test262 subset downloader
# Descarga ~50-100 tests representativos de tc39/test262

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SUBSET_DIR="${SCRIPT_DIR}/../test262"
mkdir -p "$SUBSET_DIR"

BASE_URL="https://raw.githubusercontent.com/tc39/test262/main/test/language"

# Array de paths a descargar
tests=(
  # Expressions (20)
  "expressions/addition/S11.6.1_A1.js"
  "expressions/addition/S11.6.1_A2_T1.js"
  "expressions/addition/S11.6.1_A2_T2.js"
  "expressions/subtraction/S11.6.2_A1.js"
  "expressions/multiplication/S11.5.1_A1.js"
  "expressions/division/S11.5.2_A1.js"
  "expressions/modulus/S11.5.3_A1.js"
  "expressions/left-shift/S11.7.1_A1.js"
  "expressions/right-shift/S11.7.2_A1.js"
  "expressions/unsigned-right-shift/S11.7.3_A1.js"
  "expressions/less-than/S11.8.1_A1.js"
  "expressions/greater-than/S11.8.2_A1.js"
  "expressions/equal/S11.9.1_A1.js"
  "expressions/logical-and/S11.11_A1.js"
  "expressions/logical-or/S11.12_A1.js"
  "expressions/conditional/S11.12_A1.js"
  "expressions/comma/S11.14_A1.js"
  "expressions/assignment/S11.13.1_A1.js"
  "expressions/assignment/S11.13.2_A1.js"
  "expressions/function/S13_A1.js"
  
  # Statements (20)
  "statements/block/S12.1_A1.js"
  "statements/do-while/S12.6.1_A1.js"
  "statements/empty/S12.3_A1.js"
  "statements/expression/S12.4_A1.js"
  "statements/if/S12.5_A1_T1.js"
  "statements/if/S12.5_A1_T2.js"
  "statements/if/S12.5_A1_T3.js"
  "statements/if/S12.5_A1_T4.js"
  "statements/labeled/S12.12_A1.js"
  "statements/return/S12.9_A1.js"
  "statements/switch/S12.11_A1.js"
  "statements/throw/S12.13_A1.js"
  "statements/try/S12.14_A1.js"
  "statements/variable-statement/S12.2_A1.js"
  "statements/while/S12.6.2_A1.js"
  "statements/with/S12.10_A1.js"
  "statements/for/S12.6.3_A1.js"
  "statements/for-in/S12.6.4_A1.js"
  "statements/break/S12.8_A1.js"
  "statements/continue/S12.7_A1.js"
  
  # Literals (10)
  "literals/string/S7.8.4_A1.1_T1.js"
  "literals/string/S7.8.4_A1.1_T2.js"
  "literals/string/S7.8.4_A1.1_T3.js"
  "literals/numeric/S7.8.3_A1.1_T1.js"
  "literals/numeric/S7.8.3_A1.1_T2.js"
  "literals/boolean/S7.8.2_A1.js"
  "literals/null/S7.8.1_A1.js"
  "literals/regular-expression/S7.8.5_A1.1_T1.js"
  "literals/regular-expression/S7.8.5_A1.1_T2.js"
  "literals/object/S11.1.5_A1_T1.js"
  
  # Functions (10)
  "functions/S13.2.1_A1.js"
  "functions/S13.2.1_A2.js"
  "functions/S13.2.1_A3.js"
  "functions/S13.2.1_A4.js"
  "functions/S13.2.1_A5.js"
  "functions/S13.2.1_A6.js"
  "functions/S13.2.2_A1.js"
  "functions/S13.2.2_A2.js"
  "functions/S13.2.2_A3.js"
  "function-objects/S15.3_A1.js"
)

total=0
success=0
failed=0

echo "Downloading Test262 subset..."
for test in "${tests[@]}"; do
  url="${BASE_URL}/${test}"
  filename=$(echo "$test" | tr '/' '_')
  outfile="${SUBSET_DIR}/${filename}"
  
  total=$((total + 1))
  
  if curl -sL --max-time 5 "$url" -o "$outfile" 2>/dev/null; then
    if [ -s "$outfile" ]; then
      success=$((success + 1))
      echo "✓ $filename"
    else
      failed=$((failed + 1))
      rm -f "$outfile"
      echo "✗ $filename (empty)"
    fi
  else
    failed=$((failed + 1))
    rm -f "$outfile"
    echo "✗ $filename (failed)"
  fi
done

echo ""
echo "Downloaded: $success/$total tests"
[ "$failed" -gt 0 ] && echo "Failed to download: $failed tests"
