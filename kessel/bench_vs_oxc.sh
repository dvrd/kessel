#!/usr/bin/env bash
# Head-to-head benchmark: Kessel vs OXC
# Measures both as CLI (wall-clock, includes startup) and microbench (parse cost only).
# Also runs a multi-file batch scenario to stress the scaling story.
#
# Prerequisites:
#   1. kessel_bin built at repo root: odin build ./kessel/src -out:./kessel_bin -o:speed
#   2. OXC cloned at ../oxc:        git clone --depth 1 https://github.com/oxc-project/oxc.git
#   3. OXC comparison binaries:     cd bench/oxc_compare && cargo build --release
#
# Usage: bash kessel/bench_vs_oxc.sh

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KESSEL="$REPO_ROOT/kessel_bin"
OXC_CLI="$REPO_ROOT/bench/oxc_compare/target/release/oxc_cli_equiv"
OXC_MICRO="$REPO_ROOT/bench/oxc_compare/target/release/oxc_microbench"

for bin in "$KESSEL" "$OXC_CLI" "$OXC_MICRO"; do
    if [[ ! -x "$bin" ]]; then
        echo "Missing binary: $bin" >&2
        echo "See bench/oxc_compare/README.md for setup." >&2
        exit 1
    fi
done

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

# =====================================================================
# Single-file scenarios
# =====================================================================
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

# =====================================================================
# Multi-file scenario (bundler-style batch)
# =====================================================================
echo "========================================"
echo " Multi-file scenario (50 × bench_large.js = 16.3 MB)"
echo "========================================"
echo ""

WORK_DIR="$(mktemp -d -t kessel_bench_XXXXXX)"
trap "rm -rf $WORK_DIR" EXIT

for i in $(seq 1 50); do
    cp "$REPO_ROOT/kessel/bench_large.js" "$WORK_DIR/file${i}.js"
done

FILE_LIST=$(ls $WORK_DIR/*.js)
FILE_ARGS=$(echo $FILE_LIST | tr '\n' ' ')

# Kessel parse-many at 1 / 4 / 8 workers + OXC shell loop
echo "### Strategies"
hyperfine --warmup 2 --runs 5 -N \
    --command-name "kessel parse-many w=1"  "$KESSEL parse-many $FILE_ARGS --workers 1" \
    --command-name "kessel parse-many w=4"  "$KESSEL parse-many $FILE_ARGS --workers 4" \
    --command-name "kessel parse-many w=8"  "$KESSEL parse-many $FILE_ARGS --workers 8" \
    --command-name "oxc shell-loop"         "for f in $WORK_DIR/*.js; do $OXC_CLI \$f > /dev/null; done" \
    2>&1 | grep -E "Time|Summary|faster" | head -20
echo ""

echo "========================================"
echo " Done. Update docs/BENCHMARKS.md with any new findings."
echo "========================================"
