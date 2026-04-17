#!/bin/bash
# Test262 runner - ejecuta todos los tests y reporta pass rate

SUBSET_DIR="$(dirname "$0")/test262_subset"
BINARY="${1:-./../kessel_bin}"
TIMEOUT=10

if [ ! -f "$BINARY" ]; then
  echo "Error: Binary not found at $BINARY"
  exit 1
fi

if [ ! -d "$SUBSET_DIR" ]; then
  echo "Error: test262_subset directory not found at $SUBSET_DIR"
  exit 1
fi

test_count=$(find "$SUBSET_DIR" -name "*.js" | wc -l)
if [ "$test_count" -eq 0 ]; then
  echo "Error: No .js files found in $SUBSET_DIR"
  exit 1
fi

echo "Running Test262 subset ($test_count tests) with ${BINARY}..."
echo "Timeout: ${TIMEOUT}s per test"
echo ""

# Crear script temporal para ejecutar sin pipe (evita subshell)
temp_runner=$(mktemp)

cat > "$temp_runner" << 'RUNNER_EOF'
#!/bin/bash
SUBSET_DIR="$1"
BINARY="$2"
TIMEOUT="$3"

pass=0
fail=0
timeout_count=0

while IFS= read -r testfile; do
  testname=$(basename "$testfile")
  
  if timeout "$TIMEOUT" "$BINARY" parse "$testfile" > /dev/null 2>&1; then
    pass=$((pass + 1))
    echo "✓ $testname"
  else
    exit_code=$?
    if [ $exit_code -eq 124 ]; then
      timeout_count=$((timeout_count + 1))
      echo "⏱ $testname (timeout)"
    else
      fail=$((fail + 1))
      echo "✗ $testname (error)"
    fi
  fi
done < <(find "$SUBSET_DIR" -name "*.js" -type f | sort)

# Report final stats
total=$((pass + fail + timeout_count))
if [ "$total" -gt 0 ]; then
  pass_rate=$((pass * 100 / total))
else
  pass_rate=0
fi

echo ""
echo "=== Test262 Results ==="
echo "Pass:    $pass/$total"
echo "Fail:    $fail/$total"
echo "Timeout: $timeout_count/$total"
echo "Pass rate: ${pass_rate}%"
RUNNER_EOF

chmod +x "$temp_runner"

# Ejecutar el script temporal
"$temp_runner" "$SUBSET_DIR" "$BINARY" "$TIMEOUT"

rm -f "$temp_runner"
