#!/bin/bash
# Kessel Benchmarking Infrastructure
# Robust benchmarking with hyperfine, JSON export, and reproducibility validation
#
# Usage:
#   bash kessel/bench.sh                                  # Run all, export to bench/baselines/<timestamp>.json
#   bash kessel/bench.sh --save post-virtual-arena       # Run all, save to bench/baselines/post-virtual-arena.json
#   bash kessel/bench.sh --compare baseline.json         # Run all, then compare to baseline.json
#   bash kessel/bench.sh --only-large --runs 15          # Run only large with custom run count

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BINARY="${SCRIPT_DIR}/kessel_bin"
BENCH_DIR="${SCRIPT_DIR}/bench/baselines"

# === Colors ===
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

# === Global config ===
WARMUP_ALWAYS=10
MIN_RUNS_SMALL_MEDIUM=30
MAX_RUNS_SMALL_MEDIUM=50
RUNS_LARGE=15
ONLY_CATEGORY=""
SAVE_NAME=""
COMPARE_FILE=""
TEMP_DIR="/tmp/kessel_bench_$$"
EXPORT_FILE=""

# === Cleanup trap ===
cleanup() {
    if [ -d "$TEMP_DIR" ]; then
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT

# === Check prerequisites ===
check_hyperfine() {
    if ! command -v hyperfine &> /dev/null; then
        echo -e "${RED}ERROR: hyperfine not found. Install with: brew install hyperfine${NC}"
        exit 1
    fi
}

check_jq() {
    if ! command -v jq &> /dev/null; then
        echo -e "${YELLOW}WARNING: jq not found. JSON post-processing disabled.${NC}"
        return 1
    fi
    return 0
}

check_binary() {
    if [ ! -f "$BINARY" ]; then
        echo -e "${RED}ERROR: Binary not found at $BINARY${NC}"
        echo "Build with: cd $SCRIPT_DIR && odin build kessel -release"
        exit 1
    fi
}

# === Setup benchmarking environment ===
setup_bench_env() {
    echo -e "${BLUE}Using default QoS (user-initiated) for benchmarks${NC}"
    return 0
}

# === Argument parsing ===
while [[ $# -gt 0 ]]; do
    case $1 in
        --save)
            SAVE_NAME="$2"
            shift 2
            ;;
        --compare)
            COMPARE_FILE="$2"
            shift 2
            ;;
        --only-small|--only-medium|--only-large)
            ONLY_CATEGORY="${1#--only-}"
            shift
            ;;
        --help)
            cat << 'EOF'
Kessel Robust Benchmarking

Usage:
  bash kessel/bench.sh [OPTIONS]

Options:
  --save <name>              Save to bench/baselines/<name>.json
  --compare <file.json>      Compare results to <file.json> (runs benchmark first)
  --only-small               Run only small file benchmark
  --only-medium              Run only medium file benchmark
  --only-large               Run only large file benchmark
  --help                     Show this help message

Defaults:
  - Small/Medium: min-runs=30, max-runs=50, warmup=10
  - Large: runs=15, warmup=10
  - Exports to: bench/baselines/<timestamp>.json
  - Uses --shell=none to eliminate shell overhead
  - Default QoS (user-initiated) for optimal CPU-bound performance

Environment:
  - Binary: $BINARY
  - Baselines dir: $BENCH_DIR

Examples:
  # Run with reference save
  bash kessel/bench.sh --save post-virtual-arena

  # Compare to previous
  bash kessel/bench.sh --compare bench/baselines/post-virtual-arena.json

  # Validate reproducibility
  bash kessel/bench.sh --save run1.json
  bash kessel/bench.sh --save run2.json
  bash kessel/bench_compare.sh bench/baselines/run1.json bench/baselines/run2.json
EOF
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

# === Validate prerequisites ===
check_hyperfine
check_binary
setup_bench_env
mkdir -p "$TEMP_DIR" "$BENCH_DIR"

# === Determine output file ===
if [ -n "$SAVE_NAME" ]; then
    EXPORT_FILE="${BENCH_DIR}/${SAVE_NAME}.json"
else
    TIMESTAMP=$(date +%Y%m%d_%H%M%S)
    EXPORT_FILE="${BENCH_DIR}/bench_${TIMESTAMP}.json"
fi

echo -e "${GREEN}=== Kessel Robust Benchmarking ===${NC}"
echo "Binary:         $BINARY"
echo "Export target:  $EXPORT_FILE"
echo "Warmup:         $WARMUP_ALWAYS"
echo ""

# === Run benchmark ===
run_benchmark() {
    local name=$1
    local file=$2
    local category=$3
    
    if [ ! -f "$file" ]; then
        echo -e "${RED}✗ File not found: $file${NC}"
        return 1
    fi
    
    local size=$(wc -c < "$file")
    local runs
    local warmup=$WARMUP_ALWAYS
    
    case "$category" in
        small|medium)
            runs="$MIN_RUNS_SMALL_MEDIUM"
            ;;
        large)
            runs="$RUNS_LARGE"
            ;;
        *)
            runs=15
            ;;
    esac
    
    echo -e "${BLUE}${name}${NC} (${category}, ${size} bytes, warmup=${warmup}, runs=${runs})"
    
    local temp_json="${TEMP_DIR}/${name}.json"
    local cmd="$BINARY parse $file > /dev/null"
    
    hyperfine \
        --warmup "$warmup" \
        --runs "$runs" \
        --shell=none \
        --export-json "$temp_json" \
        "$cmd"
    
    # Extract and display stats
    if check_jq; then
        local stats=$(jq -r '.results[0] | "  min=\(.min*1000 | tostring[0:6])ms mean=\(.mean*1000 | tostring[0:6])ms stddev=\(.stddev*1000 | tostring[0:6])ms"' "$temp_json")
        echo "$stats"
    fi
    echo ""
    
    echo "$temp_json"
}

# === Merge JSON results ===
merge_json_results() {
    local -a temp_files=("$@")
    
    if ! check_jq; then
        echo -e "${YELLOW}Skipping JSON merge (jq not available)${NC}"
        cp "${temp_files[0]}" "$EXPORT_FILE" 2>/dev/null || true
        return
    fi
    
    # Collect all result objects
    local results_array="["
    local first=true
    
    for f in "${temp_files[@]}"; do
        if [ -f "$f" ]; then
            if [ "$first" = true ]; then
                first=false
            else
                results_array="${results_array},"
            fi
            results_array="${results_array}$(jq '.results[0]' "$f")"
        fi
    done
    results_array="${results_array}]"
    
    # Build final JSON
    local ts=$(date -Iseconds)
    jq -n \
        --argjson results "$results_array" \
        --arg ts "$ts" \
        --arg bin "$BINARY" \
        '{results: $results, benchmark_date: $ts, kessel_binary: $bin}' > "$EXPORT_FILE"
}

# === Collect results ===
declare -a TEMP_RESULTS

if [[ "$ONLY_CATEGORY" == "" ]] || [[ "$ONLY_CATEGORY" == "small" ]]; then
    echo -e "${GREEN}[1/3] Small Files${NC}"
    result=$(run_benchmark "small" "${SCRIPT_DIR}/kessel/tests/fixtures/basic/001_const.js" "small") && TEMP_RESULTS+=("${TEMP_DIR}/small.json") || true
fi

if [[ "$ONLY_CATEGORY" == "" ]] || [[ "$ONLY_CATEGORY" == "medium" ]]; then
    echo -e "${GREEN}[2/3] Medium Files${NC}"
    result=$(run_benchmark "medium" "${SCRIPT_DIR}/kessel/tests/smoke/es2025.js" "medium") && TEMP_RESULTS+=("${TEMP_DIR}/medium.json") || true
fi

if [[ "$ONLY_CATEGORY" == "" ]] || [[ "$ONLY_CATEGORY" == "large" ]]; then
    echo -e "${GREEN}[3/3] Large Files${NC}"
    result=$(run_benchmark "large" "${SCRIPT_DIR}/kessel/bench_large.js" "large") && TEMP_RESULTS+=("${TEMP_DIR}/large.json") || true
fi

# === Merge and save ===
merge_json_results "${TEMP_RESULTS[@]}"

echo -e "${GREEN}✓ Baseline saved to: $EXPORT_FILE${NC}"
echo ""

# === Compare if requested ===
if [ -n "$COMPARE_FILE" ]; then
    if [ -f "$COMPARE_FILE" ]; then
        echo -e "${GREEN}=== Comparison ===${NC}"
        bash "${SCRIPT_DIR}/kessel/bench_compare.sh" "$COMPARE_FILE" "$EXPORT_FILE"
    else
        echo -e "${YELLOW}WARNING: Compare file not found: $COMPARE_FILE${NC}"
    fi
fi

echo -e "${GREEN}=== Complete ===${NC}"
