#!/usr/bin/env bash
# bench_codegen_vs_oxc.sh — head-to-head codegen latency, kessel vs oxc_codegen.
#
# Mirrors the parser-side `oxc_microbench` / `kessel microbench parse` setup
# but exercises the AST -> source pass. Each file is timed with the same
# iteration count on both binaries, then mean / P50 / P95 are tabulated for
# a quick side-by-side comparison.
#
# Methodology
# -----------
# Both microbenches parse once outside the timed loop. The timed loop only
# runs codegen, constructing a fresh codegen state per iteration so the
# growth path of the underlying byte buffer is exercised (steady-state
# writes alone would understate real-world cost). One warm-up iteration is
# dropped on both sides. See bench/oxc_compare/codegen_microbench/src/main.rs
# and src/main.odin::microbench_codegen for the exact loops.
#
# Usage:
#   scripts/bench_codegen_vs_oxc.sh                    # default 200 iters
#   scripts/bench_codegen_vs_oxc.sh --iters 1000       # custom
#   scripts/bench_codegen_vs_oxc.sh --quick            # 50 iters, fewer files
#
# Output: one row per file with kessel mean/P50/P95, oxc mean/P50/P95, and
# the kessel/oxc ratio (lower than 1.0 means kessel is faster).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

KESSEL_BIN="$ROOT/bin/kessel"
OXC_CG_BIN="$ROOT/bench/oxc_compare/target/release/oxc_codegen_microbench"

ITERS=200
FILES=(
  "bench/real_world/batch3/snabbdom.js"
  "bench/real_world/batch2/preact.js"
  "bench/real_world/react.dev.js"
  "bench/real_world/lodash.js"
  "bench/real_world/jquery.js"
  "bench/real_world/d3.js"
  "bench/real_world/react-dom.dev.js"
  "bench/real_world/antd.js"
  "bench/real_world/batch2/monaco.js"
  "bench/real_world/typescript.js"
)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --iters) ITERS="$2"; shift 2 ;;
    --quick)
      ITERS=50
      FILES=(
        "bench/real_world/batch3/snabbdom.js"
        "bench/real_world/react.dev.js"
        "bench/real_world/lodash.js"
        "bench/real_world/jquery.js"
        "bench/real_world/d3.js"
      )
      shift ;;
    *) echo "Unknown arg: $1" >&2 ; exit 1 ;;
  esac
done

if [[ ! -x "$KESSEL_BIN" ]]; then
  echo "missing $KESSEL_BIN — run 'task build' first" >&2
  exit 2
fi
if [[ ! -x "$OXC_CG_BIN" ]]; then
  echo "missing $OXC_CG_BIN — run 'task bench:oxc:build' first" >&2
  exit 2
fi

# Extract one statistic ("Mean" / "P50" / "P95") from a microbench output.
extract() {
  local out="$1" key="$2"
  printf '%s\n' "$out" | awk -v k="$key" 'index($0, k":") == 1 { print $2; exit }'
}

ratio() {
  awk -v a="$1" -v b="$2" 'BEGIN { if (b == 0) print "n/a"; else printf "%.2fx\n", a / b }'
}

printf '%s codegen comparison — %d iters per file\n\n' "$(date '+%F %T')" "$ITERS"
printf '%-44s | %10s %10s %10s | %10s %10s %10s | %8s\n' \
  "file" "k_mean_us" "k_p50_us" "k_p95_us" "o_mean_us" "o_p50_us" "o_p95_us" "k/o_mean"
printf -- '%.0s-' {1..132}; printf '\n'

total_k_mean=0
total_o_mean=0
count=0

for f in "${FILES[@]}"; do
  if [[ ! -f "$f" ]]; then
    printf '%-44s | %s\n' "$f" "MISSING — skipped"
    continue
  fi

  k_out="$("$KESSEL_BIN" microbench codegen "$f" --iterations "$ITERS")"
  o_out="$("$OXC_CG_BIN" "$f" "$ITERS")"

  k_mean="$(extract "$k_out" Mean)"
  k_p50="$(extract "$k_out" P50)"
  k_p95="$(extract "$k_out" P95)"
  o_mean="$(extract "$o_out" Mean)"
  o_p50="$(extract "$o_out" P50)"
  o_p95="$(extract "$o_out" P95)"

  r="$(ratio "$k_mean" "$o_mean")"

  printf '%-44s | %10s %10s %10s | %10s %10s %10s | %8s\n' \
    "$f" "$k_mean" "$k_p50" "$k_p95" "$o_mean" "$o_p50" "$o_p95" "$r"

  total_k_mean=$(awk -v a="$total_k_mean" -v b="$k_mean" 'BEGIN { print a + b }')
  total_o_mean=$(awk -v a="$total_o_mean" -v b="$o_mean" 'BEGIN { print a + b }')
  count=$((count + 1))
done

if [[ $count -gt 0 ]]; then
  avg_k=$(awk -v a="$total_k_mean" -v n="$count" 'BEGIN { printf "%.3f", a / n }')
  avg_o=$(awk -v a="$total_o_mean" -v n="$count" 'BEGIN { printf "%.3f", a / n }')
  avg_r="$(ratio "$avg_k" "$avg_o")"
  printf -- '%.0s-' {1..132}; printf '\n'
  printf '%-44s | %10s %10s %10s | %10s %10s %10s | %8s\n' \
    "AVERAGE (mean across $count files)" "$avg_k" "" "" "$avg_o" "" "" "$avg_r"
fi
