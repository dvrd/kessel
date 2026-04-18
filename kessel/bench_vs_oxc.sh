#!/usr/bin/env bash
# Head-to-head benchmark: Kessel vs OXC
# Measures both as CLI (wall-clock, includes startup) and microbench (parse cost only)
#
# Prerequisites:
#   1. kessel_bin built at repo root (odin build ./kessel/src -out:./kessel_bin -o:speed)
#   2. OXC cloned at ../oxc (git clone --depth 1 https://github.com/oxc-project/oxc.git)
#   3. OXC comparison binaries built (cd bench/oxc_compare && cargo build --release)
#
# Usage: bash kessel/bench_vs_oxc.sh

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KESSEL="$REPO_ROOT/kessel_bin"
OXC_CLI="$REPO_ROOT/bench/oxc_compare/target/release/oxc_cli_equiv"
OXC_MICRO="$REPO_ROOT/bench/oxc_compare/target/release/oxc_microbench"

# Sanity
for bin in "$KESSEL" "$OXC_CLI" "$OXC_MICRO"; do
    if [[ ! -x "$bin" ]]; then
        echo "Missing binary: $bin" >&2
        echo "See bench/oxc_compare/README.md for setup." >&2
        exit 1
    fi
done

# Files with their microbench iteration counts
declare -a FILES=(
    "kessel/tests/fixtures/basic/001_const.js:5000"
    "kessel/tests/smoke/es2025.js:2000"
    "kessel/bench_large.js:100"
)

echo "========================================"
echo " Kessel vs OXC — head-to-head"
echo " $(date)"
echo "========================================"
echo ""

for entry in "${FILES[@]}"; do
    file="${entry%:*}"
    iters="${entry#*:}"
    full="$REPO_ROOT/$file"
    size=$(wc -c < "$full" | tr -d ' ')

    echo "## $(basename $file) ($size bytes)"
    echo ""
    echo "### CLI (both emit full ESTree JSON)"
    hyperfine --warmup 10 --min-runs 50 -N \
        --command-name "kessel" "$KESSEL parse $full > /dev/null" \
        --command-name "oxc"    "$OXC_CLI $full > /dev/null" \
        2>&1 | grep -E "Time|Summary|faster" | head -8
    echo ""

    echo "### Microbench (parse cost only, P50 median)"
    printf "  kessel: "; $KESSEL microbench "$full" --iterations "$iters" 2>&1 | grep "P50:" | awk '{print $2, $3}'
    printf "  oxc:    "; $OXC_MICRO "$full" "$iters" 2>&1 | grep "P50:" | awk '{print $2, $3}'
    echo ""
done

echo "========================================"
echo " Done. Update docs/BENCHMARKS.md with any new findings."
echo "========================================"
