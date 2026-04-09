#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_NAME="$NEXHUB_PRODUCT_NAME"
EXECUTABLE_NAME="$NEXHUB_EXECUTABLE_NAME"
SMOKE_NAMESPACE="$NEXHUB_SMOKE_NAMESPACE"
APP_PATH="${1:-/Applications/${APP_NAME}.app}"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
TRACE_FILE="$(mktemp /tmp/nexhub_ask_first_click.XXXXXX).jsonl"
PROMPT_TEXT="${NEXHUB_SMOKE_ASK_PROMPT:-请直接发送这条 smoke 文本}"

pass() {
  echo "[PASS] $1"
}

fail() {
  echo "[FAIL] $1"
  exit 1
}

launch_app() {
  if ! open "$APP_PATH"; then
    echo "[WARN] open returned a LaunchServices error; continuing to verify whether the app actually launched."
  fi
  return 0
}

post_prepare_notification() {
  /usr/bin/swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name(\"${SMOKE_NAMESPACE}.smoke.runAsk\"), object: nil, userInfo: [\"prompt\": \"$PROMPT_TEXT\", \"trace_file\": \"$TRACE_FILE\", \"submit\": \"0\"], deliverImmediately: true)"
}

wait_for_identifier() {
  local identifier="$1"
  local attempts=60
  local index=0
  local result=""

  while [[ $index -lt $attempts ]]; do
    result=$(/usr/bin/osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "$APP_NAME"
    set allWindows to windows
    repeat with currentWindow in allWindows
      set allElements to entire contents of currentWindow
      repeat with elem in allElements
        try
          if value of attribute "AXIdentifier" of elem is "$identifier" then
            return true
          end if
        end try
      end repeat
    end repeat
  end tell
end tell
return false
APPLESCRIPT
)
    if [[ "$result" == "true" ]]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done

  return 1
}

send_button_center() {
  /usr/bin/osascript <<APPLESCRIPT
tell application "System Events"
  tell process "$APP_NAME"
    set allWindows to windows
    repeat with currentWindow in allWindows
      set allElements to entire contents of currentWindow
      repeat with elem in allElements
        try
          if value of attribute "AXIdentifier" of elem is "${SMOKE_NAMESPACE}.ask.send" then
            set {xPos, yPos} to position of elem
            set {buttonWidth, buttonHeight} to size of elem
            set AppleScript's text item delimiters to "|"
            return {((xPos + (buttonWidth / 2)) as integer) as text, ((yPos + (buttonHeight / 2)) as integer) as text} as text
          end if
        end try
      end repeat
    end repeat
  end tell
end tell
error "Ask send button was not found."
APPLESCRIPT
}

click_screen_point() {
  local x="$1"
  local y="$2"
  /usr/bin/osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  click at {$x, $y}
end tell
APPLESCRIPT
}

wait_for_stream_start() {
  local attempts=40
  local index=0

  while [[ $index -lt $attempts ]]; do
    if [[ -s "$TRACE_FILE" ]] && grep -q '"reason":"stream_start"' "$TRACE_FILE"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done

  return 1
}

[[ -d "$APP_PATH" ]] || fail "Installed app missing: $APP_PATH"

rm -f "$TRACE_FILE"
launch_app || fail "Installed app could not be launched for ASK first-click smoke."
sleep 2

if ! pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1; then
  fail "App process is not running after launch."
fi
pass "Installed app launched for ASK first-click smoke."

post_prepare_notification
wait_for_identifier "${SMOKE_NAMESPACE}.ask.send" || fail "ASK send button did not appear."
pass "ASK window appeared and send button is accessible."

/usr/bin/osascript -e 'tell application "Finder" to activate' >/dev/null 2>&1 || true
sleep 0.5

IFS='|' read -r send_x send_y <<<"$(send_button_center)"
click_screen_point "$send_x" "$send_y"

wait_for_stream_start || fail "Single inactive-window click did not start ASK streaming."
pass "Single inactive-window click started ASK streaming."

echo "Trace file: $TRACE_FILE"
