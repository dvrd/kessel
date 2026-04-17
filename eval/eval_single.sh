#!/bin/bash
# Usage: eval_single.sh <model> <task_num> <output_dir>
# Runs ONE evaluation: starts pi, sends prompt, captures output

set -euo pipefail

MODEL="$1"
TASK_NUM="$2"
OUTPUT_DIR="$3"
TASK_FILE="/Users/kakurega/dev/projects/kessel/eval/task${TASK_NUM}.txt"
MODEL_SAFE=$(echo "$MODEL" | tr '/' '_')
OUTFILE="${OUTPUT_DIR}/${MODEL_SAFE}__task${TASK_NUM}.md"
TIMEOUT_SECONDS=180

PROMPT=$(cat "$TASK_FILE")

echo "[$MODEL task$TASK_NUM] Starting..."

# Cleanup any leftover sessions
agent-tui sessions cleanup 2>/dev/null || true

# Start pi session  
SESSION_JSON=$(agent-tui run --format json -- pi --provider openrouter --model "$MODEL" --no-session 2>&1)
SESSION_ID=$(echo "$SESSION_JSON" | jq -r '.session_id // empty')

if [ -z "$SESSION_ID" ]; then
    echo "[$MODEL task$TASK_NUM] ERROR: Failed to start session"
    echo "# FAIL: Could not start session\nModel: $MODEL\nTask: $TASK_NUM" > "$OUTFILE"
    exit 1
fi

echo "[$MODEL task$TASK_NUM] Session: $SESSION_ID"

# Wait for pi to be ready
sleep 3
agent-tui wait --session "$SESSION_ID" ">" --timeout 15000 2>/dev/null || sleep 5

# Take initial screenshot to verify we're ready
agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' > /tmp/eval_${SESSION_ID}_init.txt

# Type the prompt
agent-tui type --session "$SESSION_ID" "$PROMPT"
sleep 1

# Press Enter to send
agent-tui press --session "$SESSION_ID" Enter

echo "[$MODEL task$TASK_NUM] Prompt sent. Waiting (max ${TIMEOUT_SECONDS}s)..."

# Wait for response to stabilize
START_TIME=$(date +%s)
LAST_SNAPSHOT=""
STABLE_COUNT=0

while true; do
    NOW=$(date +%s)
    ELAPSED=$((NOW - START_TIME))
    
    if [ $ELAPSED -ge $TIMEOUT_SECONDS ]; then
        echo "[$MODEL task$TASK_NUM] Timeout (${TIMEOUT_SECONDS}s)"
        break
    fi
    
    sleep 8
    
    CURRENT=$(agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' || echo "")
    
    if [ "$CURRENT" = "$LAST_SNAPSHOT" ]; then
        STABLE_COUNT=$((STABLE_COUNT + 1))
        if [ $STABLE_COUNT -ge 3 ]; then
            echo "[$MODEL task$TASK_NUM] Stable for 24s, done."
            break
        fi
    else
        STABLE_COUNT=0
    fi
    
    LAST_SNAPSHOT="$CURRENT"
    
    # Check for error markers
    if echo "$CURRENT" | grep -qE "^(Error|API|401|403|429|500|Rate limit)"; then
        echo "[$MODEL task$TASK_NUM] Error detected."
        sleep 3
        CURRENT=$(agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' || echo "")
        break
    fi
done

# Final screenshot
FINAL=$(agent-tui screenshot --session "$SESSION_ID" --format json 2>/dev/null | jq -r '.screenshot' || echo "SCREENSHOT_FAILED")

# Save result
{
    echo "# Evaluation: $MODEL — Task $TASK_NUM"
    echo ""
    echo "**Model:** \`$MODEL\`"
    echo "**Task:** $TASK_NUM"
    echo "**Date:** $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo ""
    echo "---"
    echo ""
    echo "$FINAL"
} > "$OUTFILE"

echo "[$MODEL task$TASK_NUM] Saved to $OUTFILE"

# Kill session
agent-tui kill --session "$SESSION_ID" 2>/dev/null || true

echo "[$MODEL task$TASK_NUM] Done."
