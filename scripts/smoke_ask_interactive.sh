#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ask_smoke_common.sh"

if [[ $# -ge 1 ]]; then
  APP_PATH="$1"
  EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
fi

STATE_FILE="$(mktemp /tmp/nexhub_ask_interactive_state.XXXXXX).json"
SCREENSHOT_FILE="/tmp/nexhub_ask_interactive.png"
PROMPT_TEXT="${NEXHUB_SMOKE_ASK_INTERACTIVE_PROMPT:-Tell me in one sentence that you are ready.}"

[[ -d "$APP_PATH" ]] || fail "Installed app missing: $APP_PATH"

quit_app_if_running
reset_persisted_ask_sessions
launch_app
wait_for_app_process 80 || fail "App process is not running after launch."
sleep 2
pass "Installed app launched for interactive ASK smoke."

draw_real_ask_box
wait_for_state_condition "$STATE_FILE" 'data.get("isVisible") is True and data.get("isUsingPersistentAskSessionShell") is True' 80 || fail "ASK shell did not appear after real draw-box entry."
pass "Real draw-box ASK entry is available."

post_smoke_run_ask "$PROMPT_TEXT" "true" "true" "true"

wait_for_state_condition "$STATE_FILE" 'data.get("isStreaming") is True or bool(data.get("latestRuntimeStepTitle"))' 90 || fail "ASK did not enter an active interactive flow."
dump_ask_state "$STATE_FILE"
wait_for_state_file "$STATE_FILE" 20 || fail "Failed to dump ASK interactive state."

[[ "$(json_read "$STATE_FILE" "hasSupplementaryChrome")" == "false" ]] || fail "Supplementary ASK chrome is still visible."
[[ "$(json_read "$STATE_FILE" "scopeBarHidden")" == "true" ]] || fail "Scope bar is still visible."
[[ "$(json_read "$STATE_FILE" "sessionModeHidden")" == "true" ]] || fail "Session mode card is still visible."
[[ "$(json_read "$STATE_FILE" "taskContinuityHidden")" == "true" ]] || fail "Task continuity card is still visible."
[[ "$(json_read "$STATE_FILE" "transcriptContainsKernelPreparedTask")" == "false" ]] || fail "\"Kernel prepared task\" leaked into the transcript."

capture_screenshot "$SCREENSHOT_FILE"
pass "Interactive ASK flow started without hidden-system chrome."

echo "State file: $STATE_FILE"
echo "Screenshot: $SCREENSHOT_FILE"
