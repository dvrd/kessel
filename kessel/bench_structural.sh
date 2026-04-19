#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
KESSEL="$ROOT/kessel_bin"
OXC="$ROOT/bench/oxc_compare/target/release/oxc_microbench"
GEN_DIR="$ROOT/bench/generated/structural"
ITERS="${ITERS:-25}"

node "$ROOT/kessel/bench_structural_gen.js" >/dev/null

if [[ ! -x "$KESSEL" ]]; then
  echo "missing $KESSEL" >&2
  exit 1
fi

echo "Structural microbench (iterations=$ITERS)"
printf '%-26s %-12s %-12s %-12s %-10s\n' "fixture" "size" "kessel-p50" "oxc-p50" "ratio"

for file in "$GEN_DIR"/*.js; do
  name=$(basename "$file")
  size=$(wc -c < "$file" | tr -d ' ')
  kp50=$($KESSEL microbench "$file" --iterations "$ITERS" 2>/dev/null | awk '/P50:/ {print $2}')
  op50="-"
  ratio="-"
  if [[ -x "$OXC" ]]; then
    op50=$($OXC "$file" "$ITERS" 2>/dev/null | awk '/P50:/ {print $2}')
    ratio=$(python3 - <<PY
k=float("$kp50")
o=float("$op50")
print(f"{k/o:.2f}x")
PY
)
  fi
  printf '%-26s %-12s %-12s %-12s %-10s\n' "$name" "$size" "$kp50 us" "$op50 us" "$ratio"
done

echo
echo "Tip: run ./kessel_bin profile-parser <fixture> --iterations 50 for per-syntax counters."
