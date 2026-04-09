#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/ask_smoke_common.sh"

if [[ $# -ge 1 ]]; then
  APP_PATH="$1"
  EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
fi

STATE_FILE="$(mktemp /tmp/nexhub_ask_browser_state.XXXXXX).json"
SCREENSHOT_FILE="/tmp/nexhub_ask_browser_flow.png"
PROMPT_TEXT="${NEXHUB_SMOKE_ASK_BROWSER_PROMPT:-Search for the OpenAI official website and open the homepage.}"

[[ -d "$APP_PATH" ]] || fail "Installed app missing: $APP_PATH"

quit_app_if_running
reset_persisted_ask_sessions
launch_app
wait_for_app_process 80 || fail "App process is not running after launch."
sleep 2
pass "Installed app launched for browser ASK smoke."

/usr/bin/osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
sleep 0.5

draw_real_ask_box
wait_for_state_condition "$STATE_FILE" 'data.get("isVisible") is True and data.get("isUsingPersistentAskSessionShell") is True' 80 || fail "ASK shell did not appear after real draw-box entry."
pass "Real draw-box ASK entry is available for browser flow."

post_smoke_run_ask "$PROMPT_TEXT" "true" "true" "true"

wait_for_state_condition "$STATE_FILE" 'data.get("isStreaming") is True or bool(data.get("latestRuntimeStepTitle"))' 120 || fail "Browser ASK flow did not start."
wait_for_state_condition "$STATE_FILE" 'data.get("isStreaming") is False' 240 || fail "Browser ASK flow did not finish."

dump_ask_state "$STATE_FILE"
wait_for_state_file "$STATE_FILE" 20 || fail "Failed to dump ASK browser state."

[[ "$(json_read "$STATE_FILE" "hasSupplementaryChrome")" == "false" ]] || fail "Supplementary ASK chrome is still visible during browser flow."
[[ "$(json_read "$STATE_FILE" "transcriptContainsKernelPreparedTask")" == "false" ]] || fail "\"Kernel prepared task\" leaked into the transcript."

sleep 2
FRONTMOST_APP="$(frontmost_app_name)"
LATEST_STEP_TITLE="$(json_read "$STATE_FILE" "latestRuntimeStepTitle")"
LATEST_STEP_STATE="$(json_read "$STATE_FILE" "latestRuntimeStepState")"
LATEST_STEP_DETAIL="$(json_read "$STATE_FILE" "latestRuntimeStepDetail")"
if [[ "$FRONTMOST_APP" =~ ^(Safari|Google\ Chrome|Arc|Microsoft\ Edge|Firefox)$ ]]; then
  pass "Browser flow opened a real browser: $FRONTMOST_APP."
elif [[ "$LATEST_STEP_STATE" == "completed" && ( "$LATEST_STEP_TITLE" == *"打开"* || "$LATEST_STEP_TITLE" == *"open"* ) ]]; then
  pass "Browser flow recorded a completed open-page step even though the browser was no longer frontmost at the final check."
elif [[ "$LATEST_STEP_DETAIL" == *"browser.open_url"* && ( "$LATEST_STEP_DETAIL" == *"Opened "* || "$LATEST_STEP_DETAIL" == *"已打开"* ) ]]; then
  pass "Browser flow recorded a successful browser.open_url action even though the browser was no longer frontmost at the final check."
else
  fail "Browser flow did not bring a browser to the front."
fi

capture_screenshot "$SCREENSHOT_FILE"

echo "State file: $STATE_FILE"
echo "Screenshot: $SCREENSHOT_FILE"
