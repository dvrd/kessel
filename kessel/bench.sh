#!/bin/bash
# Kessel Benchmarking Suite
# Runs comprehensive performance tests across different file sizes
#
# Usage:
#   bash kessel/bench.sh              # Run all benchmarks
#   bash kessel/bench.sh --only-large # Run only large file benchmark
#   bash kessel/bench.sh --export-json results.json

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${SCRIPT_DIR}/kessel_bin"

# Color output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
WARMUP_SMALL=10
RUNS_SMALL=10
WARMUP_MEDIUM=5
RUNS_MEDIUM=10
WARMUP_LARGE=3
RUNS_LARGE=5

# Argument parsing
EXPORT_JSON=""
ONLY_CATEGORY=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --export-json)
            EXPORT_JSON="$2"
            shift 2
            ;;
        --only-small|--only-medium|--only-large)
            ONLY_CATEGORY="${1#--only-}"
            shift
            ;;
        --help)
            echo "Usage: bash kessel/bench.sh [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --export-json FILE    Export results in JSON format"
            echo "  --only-small          Run only small file benchmark"
            echo "  --only-medium         Run only medium file benchmark"
            echo "  --only-large          Run only large file benchmark"
            echo "  --help                Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Check if binary exists
if [ ! -f "$BINARY" ]; then
    echo -e "${YELLOW}Binary not found at $BINARY${NC}"
    echo "Building kessel..."
    cd "$SCRIPT_DIR"
    odin build kessel -release
fi

# Helper function to run benchmark
run_benchmark() {
    local name=$1
    local file=$2
    local warmup=$3
    local runs=$4
    
    if [ ! -f "$file" ]; then
        echo -e "${YELLOW}✗ File not found: $file${NC}"
        return 1
    fi
    
    local size=$(wc -c < "$file")
    echo -e "${BLUE}${name}${NC} ($size bytes)"
    
    if [ -n "$EXPORT_JSON" ]; then
        hyperfine \
            --warmup "$warmup" \
            --runs "$runs" \
            --export-json /tmp/bench_${name}.json \
            "$BINARY parse $file > /dev/null"
    else
        hyperfine \
            --warmup "$warmup" \
            --runs "$runs" \
            "$BINARY parse $file > /dev/null"
    fi
    
    echo ""
}

echo -e "${GREEN}=== Kessel Benchmarking Suite ===${NC}"
echo "Binary: $BINARY"
echo ""

# Run benchmarks
if [[ "$ONLY_CATEGORY" == "" ]] || [[ "$ONLY_CATEGORY" == "small" ]]; then
    echo -e "${GREEN}[1/3] Small Files${NC}"
    run_benchmark "small_001" "$SCRIPT_DIR/tests/fixtures/basic/001_const.js" $WARMUP_SMALL $RUNS_SMALL || true
fi

if [[ "$ONLY_CATEGORY" == "" ]] || [[ "$ONLY_CATEGORY" == "medium" ]]; then
    echo -e "${GREEN}[2/3] Medium Files${NC}"
    run_benchmark "medium_001" "$SCRIPT_DIR/tests/fixtures/es2020/001_optional_chain.js" $WARMUP_MEDIUM $RUNS_MEDIUM || true
fi

if [[ "$ONLY_CATEGORY" == "" ]] || [[ "$ONLY_CATEGORY" == "large" ]]; then
    echo -e "${GREEN}[3/3] Large Files${NC}"
    run_benchmark "large_bench" "$SCRIPT_DIR/bench_large.js" $WARMUP_LARGE $RUNS_LARGE || true
fi

# Handle JSON export
if [ -n "$EXPORT_JSON" ]; then
    echo -e "${GREEN}Exporting results to JSON...${NC}"
    
    # Create combined JSON (simplified — just save individual results)
    if [ -f /tmp/bench_small_001.json ]; then
        cp /tmp/bench_small_001.json "${EXPORT_JSON}"
        echo "Results saved to: $EXPORT_JSON"
    fi
fi

echo -e "${GREEN}=== Benchmark Complete ===${NC}"
echo ""
echo "To compare before/after:"
echo "  bash kessel/bench.sh --export-json /tmp/before.json"
echo "  # ... make changes ..."
echo "  bash kessel/bench.sh --export-json /tmp/after.json"
echo ""
echo "For detailed flamegraph profiling:"
echo "  samply record ./kessel_bin parse kessel/bench_large.js"
