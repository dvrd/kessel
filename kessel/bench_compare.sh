#!/bin/bash
# Kessel Benchmark Comparison
# Analyzes two benchmark JSON files and reports delta with statistical significance
#
# Usage:
#   bash kessel/bench_compare.sh <before.json> <after.json>
#
# Output: Table with delta, percentage change, and significance (sigma-based)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

if [ $# -ne 2 ]; then
    echo "Usage: bash $(basename "$0") <before.json> <after.json>"
    echo ""
    echo "Compares two hyperfine benchmark results and reports deltas with"
    echo "statistical significance (sigma-based test: |delta| > 2*sqrt(sigma_before^2 + sigma_after^2))"
    exit 1
fi

BEFORE_FILE="$1"
AFTER_FILE="$2"

# === Check files exist ===
if [ ! -f "$BEFORE_FILE" ]; then
    echo -e "${RED}ERROR: Before file not found: $BEFORE_FILE${NC}"
    exit 1
fi

if [ ! -f "$AFTER_FILE" ]; then
    echo -e "${RED}ERROR: After file not found: $AFTER_FILE${NC}"
    exit 1
fi

# === Check jq ===
if ! command -v jq &> /dev/null; then
    echo -e "${RED}ERROR: jq is required for comparison${NC}"
    echo "Install with: brew install jq"
    exit 1
fi

# === Get result count ===
get_result_count() {
    local file=$1
    jq '.results | length' "$file"
}

echo -e "${BLUE}=== Benchmark Comparison ===${NC}"
echo "Before: $BEFORE_FILE"
echo "After:  $AFTER_FILE"
echo ""

BEFORE_COUNT=$(get_result_count "$BEFORE_FILE")
AFTER_COUNT=$(get_result_count "$AFTER_FILE")

if [ "$BEFORE_COUNT" -ne "$AFTER_COUNT" ]; then
    echo -e "${YELLOW}WARNING: Result counts differ (before=$BEFORE_COUNT, after=$AFTER_COUNT)${NC}"
    echo ""
fi

# === Build comparison table ===
printf "${GREEN}%-20s | %-15s | %-15s | %-10s | %s${NC}\n" \
    "Command" "Before (ms)" "After (ms)" "Delta" "Significant?"
printf "%-20s | %-15s | %-15s | %-10s | %s\n" \
    "$(printf '%0.s-' {1..20})" "$(printf '%0.s-' {1..15})" "$(printf '%0.s-' {1..15})" "$(printf '%0.s-' {1..10})" "$(printf '%0.s-' {1..15})"

# === Parse and compare using jq + awk ===
MIN_INDEX=$((BEFORE_COUNT < AFTER_COUNT ? BEFORE_COUNT : AFTER_COUNT))

TOTAL_IMPROVED=0
TOTAL_REGRESSED=0
TOTAL_INCONCLUSIVE=0

for i in $(seq 0 $((MIN_INDEX - 1))); do
    # Extract data using jq
    BEFORE_DATA=$(jq -r ".results[$i] | \"\(.command | if contains(\"001_const\") then \"small\" elif contains(\"es2025\") then \"medium\" elif contains(\"bench_large\") then \"large\" else \"bench\" end)|\(.mean * 1000)|\(.stddev * 1000)\"" "$BEFORE_FILE")
    AFTER_DATA=$(jq -r ".results[$i] | \"\(.command | if contains(\"001_const\") then \"small\" elif contains(\"es2025\") then \"medium\" elif contains(\"bench_large\") then \"large\" else \"bench\" end)|\(.mean * 1000)|\(.stddev * 1000)\"" "$AFTER_FILE")
    
    IFS='|' read -r LABEL BEFORE_MEAN BEFORE_STDDEV <<< "$BEFORE_DATA"
    IFS='|' read -r _ AFTER_MEAN AFTER_STDDEV <<< "$AFTER_DATA"
    
    # All calculations using awk
    read -r DELTA DELTA_PERCENT SIGMA_COMBINED THRESHOLD DELTA_ABS SIGNIFICANT TREND <<< $(
        awk -v bm="$BEFORE_MEAN" -v am="$AFTER_MEAN" -v bs="$BEFORE_STDDEV" -v as="$AFTER_STDDEV" \
        'BEGIN {
            delta = am - bm
            delta_pct = (bm != 0) ? (delta / bm * 100) : 0
            sigma_combined = sqrt(bs*bs + as*as)
            threshold = 2 * sigma_combined
            delta_abs = (delta < 0) ? -delta : delta
            
            if (delta_abs > threshold) {
                if (delta < 0) {
                    significant = "yes"
                    trend = "down"
                } else {
                    significant = "yes"
                    trend = "up"
                }
            } else {
                significant = "no"
                trend = "neutral"
            }
            
            printf "%.2f %.1f %.4f %.4f %.4f %s %s\n", delta, delta_pct, sigma_combined, threshold, delta_abs, significant, trend
        }'
    )
    
    # Update counters
    if [ "$SIGNIFICANT" = "yes" ]; then
        if [ "$TREND" = "down" ]; then
            TOTAL_IMPROVED=$((TOTAL_IMPROVED + 1))
            TREND_SYMBOL="${GREEN}↓${NC}"
        else
            TOTAL_REGRESSED=$((TOTAL_REGRESSED + 1))
            TREND_SYMBOL="${RED}↑${NC}"
        fi
    else
        TOTAL_INCONCLUSIVE=$((TOTAL_INCONCLUSIVE + 1))
        TREND_SYMBOL="${YELLOW}~${NC}"
    fi
    
    # Format output
    printf "%-20s | %13.2f ± %4.2f | %13.2f ± %4.2f | %8.1f%% | %s\n" \
        "$LABEL" \
        "$BEFORE_MEAN" "$BEFORE_STDDEV" \
        "$AFTER_MEAN" "$AFTER_STDDEV" \
        "$DELTA_PERCENT" \
        "$SIGNIFICANT (${TREND_SYMBOL})"
done

echo ""
echo -e "${BLUE}Summary:${NC}"
echo "  ↓ Improved (significant):    $TOTAL_IMPROVED"
echo "  ↑ Regressed (significant):   $TOTAL_REGRESSED"
echo "  ~ Inconclusive (< 2σ):       $TOTAL_INCONCLUSIVE"
echo ""

if [ $TOTAL_REGRESSED -gt 0 ]; then
    echo -e "${RED}⚠ WARNING: Performance regression detected${NC}"
elif [ $TOTAL_IMPROVED -gt 0 ]; then
    echo -e "${GREEN}✓ Performance improved${NC}"
else
    echo -e "${YELLOW}~ Results within noise floor (inconclusive)${NC}"
fi
