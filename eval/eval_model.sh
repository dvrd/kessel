#!/bin/bash
# Usage: ./eval_model.sh <model> <task_file> <output_dir>
# Runs pi with agent-tui, sends a prompt, captures output

set -euo pipefail

MODEL="$1"
TASK_FILE="$2"
OUTPUT_DIR="$3"
TASK_NAME=$(basename "$TASK_FILE" .txt)
MODEL_SAFE=$(echo "$MODEL" | tr '/' '_')
OUTFILE="${OUTPUT_DIR}/${MODEL_SAFE}__${TASK_NAME}.md"
TIMEOUT_SECONDS=120

PROMPT=$(cat "$TASK_FILE")

echo "=== Evaluating $MODEL on $TASK_NAME ==="

# Kill any leftover sessions
agent-tui sessions cleanup 2>/dev/null || true

# Start pi session
SESSION_JSON=$(agent-tui run --format json pi --model "$MODEL" --no-session 2>&1)
SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
    echo "ERROR: Failed to start session. Output: $SESSION_JSON"
    echo "FAIL: Could not start session" > "$OUTFILE"
    exit 1
fi

echo "Session: $SESSION_ID"

# Wait for pi to be ready (look for the input area)
sleep 5
agent-tui wait --session "$SESSION_ID" ">" --timeout 15000 2>/dev/null || sleep 3

# Take initial screenshot
agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' > /tmp/eval_initial.txt

# Type the prompt
agent-tui type --session "$SESSION_ID" "$PROMPT"
sleep 1

# Press Enter to send
agent-tui press --session "$SESSION_ID" Enter

echo "Prompt sent. Waiting for response (max ${TIMEOUT_SECONDS}s)..."

# Wait for the response to stabilize
START_TIME=$(date +%s)
LAST_SNAPSHOT=""
STABLE_COUNT=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    
    if [ $ELAPSED -ge $TIMEOUT_SECONDS ]; then
        echo "Timeout reached (${TIMEOUT_SECONDS}s)"
        break
    fi
    
    sleep 5
    
    CURRENT=$(agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' || echo "")
    
    if [ "$CURRENT" = "$LAST_SNAPSHOT" ]; then
        STABLE_COUNT=$((STABLE_COUNT + 1))
        if [ $STABLE_COUNT -ge 4 ]; then
            echo "Response stable for 20s, assuming complete."
            break
        fi
    else
        STABLE_COUNT=0
    fi
    
    LAST_SNAPSHOT="$CURRENT"
    
    # Check if we see a final prompt indicator
    if echo "$CURRENT" | grep -qE "^(╭|─|Rate limit|Error|API)"; then
        echo "Detected completion/error marker."
        sleep 3
        CURRENT=$(agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' || echo "")
        break
    fi
done

# Final screenshot
FINAL=$(agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' || echo "SCREENSHOT_FAILED")

# Save result
{
    echo "# Evaluation: $MODEL on $TASK_NAME"
    echo ""
    echo "**Model:** \`$MODEL\`"
    echo "**Task:** $TASK_NAME"
    echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "---"
    echo ""
    echo "$FINAL"
} > "$OUTFILE"

echo "Saved to $OUTFILE"

# Kill session
agent-tui kill --session "$SESSION_ID" 2>/dev/null || true

echo "=== Done ==="
