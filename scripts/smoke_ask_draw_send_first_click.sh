#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_NAME="$NEXHUB_PRODUCT_NAME"
EXECUTABLE_NAME="$NEXHUB_EXECUTABLE_NAME"
SUPPORT_DIR_NAME="$NEXHUB_SUPPORT_DIR_NAME"
APP_PATH="${1:-/Applications/${APP_NAME}.app}"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
APP_LOG="$HOME/Library/Application Support/${SUPPORT_DIR_NAME}/Logs/runtime.log"
PROMPT_TEXT="${NEXHUB_SMOKE_ASK_PROMPT:-12345}"

pass() {
  echo "[PASS] $1"
}

fail() {
  echo "[FAIL] $1"
  exit 1
}

launch_app() {
  mkdir -p "$(dirname "$APP_LOG")"
  : > "$APP_LOG"
  if ! open "$APP_PATH"; then
    echo "[WARN] open returned a LaunchServices error; continuing to verify whether the app actually launched."
  fi
  return 0
}

quit_app_if_running() {
  /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "$APP_NAME"
  if running then quit
end tell
APPLESCRIPT
  sleep 1
}

wait_for_active_ask_window() {
  local attempts=60
  local index=0

  while [[ $index -lt $attempts ]]; do
    local frontmost
    local window_count
    frontmost=$(/usr/bin/osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true)
    window_count=$(/usr/bin/osascript <<APPLESCRIPT 2>/dev/null || true
tell application "System Events"
  tell process "$APP_NAME"
    return count of windows
  end tell
end tell
APPLESCRIPT
)
    if [[ "$frontmost" == "$APP_NAME" && "$window_count" == "1" ]]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done

  return 1
}

send_button_geometry() {
  /usr/bin/osascript <<APPLESCRIPT
tell application "System Events"
  tell process "$APP_NAME"
    tell button "发送" of window 1
      set {xPos, yPos} to position
      set {btnWidth, btnHeight} to size
    end tell
    set AppleScript's text item delimiters to "|"
    return {xPos as text, yPos as text, btnWidth as text, btnHeight as text} as text
  end tell
end tell
APPLESCRIPT
}

draw_real_ask_box() {
  /usr/bin/swift -e 'import AppKit; import CoreGraphics
func postKey(_ keyCode: CGKeyCode, down: Bool, flags: CGEventFlags = []) {
    guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

func postMouse(_ type: CGEventType, x: CGFloat, y: CGFloat, flags: CGEventFlags = []) {
    guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left) else { return }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

let flags: CGEventFlags = .maskAlternate
postKey(58, down: true, flags: flags)
usleep(25000)
postMouse(.leftMouseDown, x: 320, y: 760, flags: flags)
for step in 1...14 {
    let x = 320 + CGFloat(step) * 22
    let y = 760 - CGFloat(step) * 18
    usleep(12000)
    postMouse(.leftMouseDragged, x: x, y: y, flags: flags)
}
usleep(12000)
postMouse(.leftMouseUp, x: 628, y: 508, flags: flags)
usleep(25000)
postKey(58, down: false)
'
}

type_prompt_into_focused_composer() {
  /usr/bin/osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    keystroke "$PROMPT_TEXT"
  end tell
end tell
APPLESCRIPT
}

click_send_button_raw() {
  local button_x="$1"
  local button_y="$2"
  local button_width="$3"
  local button_height="$4"
  /usr/bin/swift -e "import CoreGraphics
let buttonX = Double(\"$button_x\") ?? 0
let buttonY = Double(\"$button_y\") ?? 0
let buttonWidth = Double(\"$button_width\") ?? 0
let buttonHeight = Double(\"$button_height\") ?? 0
let clickX = buttonX + buttonWidth / 2
let clickY = buttonY + buttonHeight / 2
if let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left),
   let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: CGPoint(x: clickX, y: clickY), mouseButton: .left) {
    down.post(tap: .cghidEventTap)
    usleep(12000)
    up.post(tap: .cghidEventTap)
}"
}

wait_for_submit_log() {
  local attempts=40
  local index=0

  while [[ $index -lt $attempts ]]; do
    if [[ -s "$APP_LOG" ]] && grep -q '\[ask\.session\] submit session=' "$APP_LOG"; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done

  return 1
}

[[ -d "$APP_PATH" ]] || fail "Installed app missing: $APP_PATH"

quit_app_if_running
launch_app || fail "Installed app could not be launched for draw-send smoke."
sleep 2

if ! pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1; then
  fail "App process is not running after launch."
fi
pass "Installed app launched for draw-send smoke."

draw_real_ask_box
wait_for_active_ask_window || fail "ASK window did not stay active after real draw-box capture."
pass "Real draw-box path opened ASK and brought NexHub to the front."

type_prompt_into_focused_composer
sleep 0.25
IFS='|' read -r button_x button_y button_width button_height <<<"$(send_button_geometry)"
click_send_button_raw "$button_x" "$button_y" "$button_width" "$button_height"

wait_for_submit_log || fail "Single raw click after real draw-box manual typing did not submit ASK."
pass "Single raw click after real draw-box manual typing submitted ASK."
