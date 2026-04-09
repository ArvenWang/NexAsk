#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_NAME="${NEXHUB_PRODUCT_NAME}"
EXECUTABLE_NAME="${NEXHUB_EXECUTABLE_NAME}"
SUPPORT_DIR_NAME="${NEXHUB_SUPPORT_DIR_NAME}"
SMOKE_NAMESPACE="${NEXHUB_SMOKE_NAMESPACE}"
APP_PATH="${APP_PATH:-/Applications/${APP_NAME}.app}"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
APP_SUPPORT_ROOT="$HOME/Library/Application Support/${SUPPORT_DIR_NAME}"
ASK_PERSISTENT_SESSION_FILE="$APP_SUPPORT_ROOT/Ask/ask_persistent_session.json"
LEGACY_PERSISTENT_SESSION_FILE="$APP_SUPPORT_ROOT/Ask/kairos_session.json"
LEGACY_FOLLOWUP_SESSION_FILE="$APP_SUPPORT_ROOT/Ask/assistant_followup_sessions.json"
KERNEL_APPROVALS_FILE="$APP_SUPPORT_ROOT/Ask/kernel_approvals.json"
KERNEL_RESULTS_FILE="$APP_SUPPORT_ROOT/Ask/kernel_results.json"
KERNEL_TASKS_FILE="$APP_SUPPORT_ROOT/Ask/kernel_tasks.json"
ASK_PLAYGROUND_CATALOG_FILE="$APP_SUPPORT_ROOT/AskPlayground/catalog.json"

pass() {
  echo "[PASS] $1"
}

fail() {
  echo "[FAIL] $1"
  exit 1
}

quit_app_if_running() {
  /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "$APP_NAME"
  if running then quit
end tell
APPLESCRIPT
  sleep 1
}

launch_app() {
  if ! open "$APP_PATH"; then
    echo "[WARN] open returned a LaunchServices error; continuing."
  fi
}

reset_persisted_ask_sessions() {
  rm -f \
    "$ASK_PERSISTENT_SESSION_FILE" \
    "$LEGACY_PERSISTENT_SESSION_FILE" \
    "$LEGACY_FOLLOWUP_SESSION_FILE" \
    "$KERNEL_APPROVALS_FILE" \
    "$KERNEL_RESULTS_FILE" \
    "$KERNEL_TASKS_FILE" \
    "$ASK_PLAYGROUND_CATALOG_FILE"
}

post_smoke_run_ask() {
  local prompt="${1:-}"
  local submit="${2:-true}"
  local reuse_visible="${3:-false}"
  local persistent_session="${4:-false}"
  local response="${5:-}"
  local trace_file="${6:-}"

  NEXHUB_SMOKE_PROMPT="$prompt" \
  NEXHUB_SMOKE_SUBMIT="$submit" \
  NEXHUB_SMOKE_REUSE_VISIBLE="$reuse_visible" \
  NEXHUB_SMOKE_PERSISTENT_SESSION="$persistent_session" \
  NEXHUB_SMOKE_RESPONSE="$response" \
  NEXHUB_SMOKE_TRACE_FILE="$trace_file" \
  NEXHUB_SMOKE_NAMESPACE="$SMOKE_NAMESPACE" \
  /usr/bin/swift - <<'SWIFT'
import Foundation

let env = ProcessInfo.processInfo.environment
var userInfo: [AnyHashable: Any] = [
    "prompt": env["NEXHUB_SMOKE_PROMPT"] ?? "",
    "submit": env["NEXHUB_SMOKE_SUBMIT"] ?? "true",
    "reuse_visible": env["NEXHUB_SMOKE_REUSE_VISIBLE"] ?? "false",
    "persistent_session": env["NEXHUB_SMOKE_PERSISTENT_SESSION"] ?? "false"
]
if let response = env["NEXHUB_SMOKE_RESPONSE"], !response.isEmpty {
    userInfo["response"] = response
}
if let traceFile = env["NEXHUB_SMOKE_TRACE_FILE"], !traceFile.isEmpty {
    userInfo["trace_file"] = traceFile
}
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("\(env["NEXHUB_SMOKE_NAMESPACE"] ?? "nexhub").smoke.runAsk"),
    object: nil,
    userInfo: userInfo,
    deliverImmediately: true
)
SWIFT
}

post_smoke_automation_run() {
  local run_id="$1"
  local job_id="$2"
  local summary="$3"
  local status="${4:-completed}"
  local task_id="${5:-}"
  local workspace_root="${6:-}"

  NEXHUB_AUTOMATION_RUN_ID="$run_id" \
  NEXHUB_AUTOMATION_JOB_ID="$job_id" \
  NEXHUB_AUTOMATION_SUMMARY="$summary" \
  NEXHUB_AUTOMATION_STATUS="$status" \
  NEXHUB_AUTOMATION_TASK_ID="$task_id" \
  NEXHUB_AUTOMATION_WORKSPACE_ROOT="$workspace_root" \
  NEXHUB_SMOKE_NAMESPACE="$SMOKE_NAMESPACE" \
  /usr/bin/swift - <<'SWIFT'
import Foundation

let env = ProcessInfo.processInfo.environment
let now = ISO8601DateFormatter().string(from: Date())
var payload: [String: Any] = [
    "id": UUID().uuidString.lowercased(),
    "jobID": env["NEXHUB_AUTOMATION_JOB_ID"] ?? "smoke-job",
    "runID": env["NEXHUB_AUTOMATION_RUN_ID"] ?? UUID().uuidString.lowercased(),
    "startedAt": now,
    "finishedAt": now,
    "status": env["NEXHUB_AUTOMATION_STATUS"] ?? "completed",
    "summary": env["NEXHUB_AUTOMATION_SUMMARY"] ?? "Smoke automation result",
    "toolSteps": [],
    "artifacts": []
]
if let taskID = env["NEXHUB_AUTOMATION_TASK_ID"], !taskID.isEmpty {
    payload["kernelTaskID"] = taskID
}
if let workspaceRoot = env["NEXHUB_AUTOMATION_WORKSPACE_ROOT"], !workspaceRoot.isEmpty {
    payload["workspaceRoot"] = workspaceRoot
}

guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
      let encoded = String(data: data, encoding: .utf8) else {
    exit(1)
}

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("\(env["NEXHUB_SMOKE_NAMESPACE"] ?? "nexhub").smoke.recordAutomationRun"),
    object: nil,
    userInfo: ["automation_run_payload": encoded],
    deliverImmediately: true
)
SWIFT
}

post_smoke_inbox_item() {
  local item_id="$1"
  local title="$2"
  local summary="$3"
  local task_id="${4:-}"
  local resume_token="${5:-}"
  local workspace_root="${6:-}"
  local delivery_channel="${7:-ask_inbox}"

  NEXHUB_INBOX_ITEM_ID="$item_id" \
  NEXHUB_INBOX_ITEM_TITLE="$title" \
  NEXHUB_INBOX_ITEM_SUMMARY="$summary" \
  NEXHUB_INBOX_ITEM_TASK_ID="$task_id" \
  NEXHUB_INBOX_ITEM_RESUME_TOKEN="$resume_token" \
  NEXHUB_INBOX_ITEM_WORKSPACE_ROOT="$workspace_root" \
  NEXHUB_INBOX_ITEM_DELIVERY_CHANNEL="$delivery_channel" \
  NEXHUB_SMOKE_NAMESPACE="$SMOKE_NAMESPACE" \
  /usr/bin/swift - <<'SWIFT'
import Foundation

let env = ProcessInfo.processInfo.environment
let now = ISO8601DateFormatter().string(from: Date())
var payload: [String: Any] = [
    "id": env["NEXHUB_INBOX_ITEM_ID"] ?? UUID().uuidString.lowercased(),
    "kind": "assistant_update",
    "title": env["NEXHUB_INBOX_ITEM_TITLE"] ?? "ASK follow-up",
    "summary": env["NEXHUB_INBOX_ITEM_SUMMARY"] ?? "Continue the current ASK task.",
    "createdAt": now,
    "assistantDeliveryChannel": env["NEXHUB_INBOX_ITEM_DELIVERY_CHANNEL"] ?? "ask_inbox",
    "actions": [],
    "isRead": false
]
if let taskID = env["NEXHUB_INBOX_ITEM_TASK_ID"], !taskID.isEmpty {
    payload["activeTaskID"] = taskID
    payload["sourceTaskID"] = taskID
}
if let resumeToken = env["NEXHUB_INBOX_ITEM_RESUME_TOKEN"], !resumeToken.isEmpty {
    payload["activeTaskResumeToken"] = resumeToken
}
if let workspaceRoot = env["NEXHUB_INBOX_ITEM_WORKSPACE_ROOT"], !workspaceRoot.isEmpty {
    payload["workspaceRoot"] = workspaceRoot
}

guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
      let encoded = String(data: data, encoding: .utf8) else {
    exit(1)
}

DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("\(env["NEXHUB_SMOKE_NAMESPACE"] ?? "nexhub").smoke.saveInboxItem"),
    object: nil,
    userInfo: ["inbox_item_payload": encoded],
    deliverImmediately: true
)
SWIFT
}

activate_app() {
  /usr/bin/osascript - "$APP_NAME" <<'APPLESCRIPT' >/dev/null 2>&1 || true
on run argv
  tell application (item 1 of argv) to activate
end run
APPLESCRIPT
}

wait_for_app_process() {
  local attempts="${1:-80}"
  local index=0
  while [[ $index -lt $attempts ]]; do
    if pgrep -f "$EXECUTABLE_PATH" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_for_frontmost_app() {
  local attempts="${1:-40}"
  local index=0
  while [[ $index -lt $attempts ]]; do
    local frontmost
    frontmost="$(frontmost_app_name)"
    if [[ "$frontmost" == "$APP_NAME" ]]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

wait_for_identifier() {
  local identifier="$1"
  local attempts="${2:-80}"
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

click_identifier() {
  local identifier="$1"
  /usr/bin/osascript <<APPLESCRIPT >/dev/null
tell application "System Events"
  tell process "$APP_NAME"
    set allWindows to windows
    repeat with currentWindow in allWindows
      set allElements to entire contents of currentWindow
      repeat with elem in allElements
        try
          if value of attribute "AXIdentifier" of elem is "$identifier" then
            click elem
            return
          end if
        end try
      end repeat
    end repeat
  end tell
end tell
error "Identifier not found: $identifier"
APPLESCRIPT
}

identifier_geometry() {
  local identifier="$1"
  /usr/bin/osascript - "$APP_NAME" "$identifier" <<'APPLESCRIPT'
on run argv
  set appName to item 1 of argv
  set targetIdentifier to item 2 of argv
tell application "System Events"
  tell process appName
    set allWindows to windows
    repeat with currentWindow in allWindows
      set allElements to entire contents of currentWindow
      repeat with elem in allElements
        try
          if value of attribute "AXIdentifier" of elem is targetIdentifier then
            set {xPos, yPos} to position of elem
            set {btnWidth, btnHeight} to size of elem
            set AppleScript's text item delimiters to "|"
            return {xPos as text, yPos as text, btnWidth as text, btnHeight as text} as text
          end if
        end try
      end repeat
    end repeat
  end tell
end tell
error "Identifier not found: " & targetIdentifier
end run
APPLESCRIPT
}

send_button_geometry() {
  identifier_geometry "${SMOKE_NAMESPACE}.ask.send"
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

press_return_key() {
  /usr/bin/swift -e "import CoreGraphics
func post(_ code: CGKeyCode, down: Bool) {
  guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return }
  event.post(tap: .cghidEventTap)
}
post(36, down: true)
usleep(12000)
post(36, down: false)"
}

click_identifier_raw() {
  local identifier="$1"
  IFS='|' read -r button_x button_y button_width button_height <<<"$(identifier_geometry "$identifier")"
  click_send_button_raw "$button_x" "$button_y" "$button_width" "$button_height"
}

press_identifier() {
  local identifier="$1"
  /usr/bin/osascript - "$APP_NAME" "$identifier" <<'APPLESCRIPT' >/dev/null
on run argv
  set appName to item 1 of argv
  set targetIdentifier to item 2 of argv
  tell application "System Events"
    tell process appName
      set allWindows to windows
      repeat with currentWindow in allWindows
        set allElements to entire contents of currentWindow
        repeat with elem in allElements
          try
            if value of attribute "AXIdentifier" of elem is targetIdentifier then
              perform action "AXPress" of elem
              return
            end if
          end try
        end repeat
      end repeat
    end tell
  end tell
  error "Identifier not found: " & targetIdentifier
end run
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
  local prompt_text="$1"
  activate_app
  wait_for_frontmost_app 20 || true
  click_identifier_raw "${SMOKE_NAMESPACE}.ask.composer" || true
  sleep 0.2
  /usr/bin/osascript - "$APP_NAME" "$prompt_text" <<'APPLESCRIPT' >/dev/null
on run argv
  set appName to item 1 of argv
  set promptText to item 2 of argv
  set previousClipboard to the clipboard
  set the clipboard to promptText
  tell application "System Events"
    tell process appName
      keystroke "v" using command down
    end tell
  end tell
  delay 0.1
  set the clipboard to previousClipboard
end run
APPLESCRIPT
}

frontmost_app_name() {
  /usr/bin/osascript -e 'tell application "System Events" to get name of first application process whose frontmost is true' 2>/dev/null || true
}

capture_screenshot() {
  local output_path="$1"
  mkdir -p "$(dirname "$output_path")"
  screencapture -x "$output_path"
}

dump_ask_state() {
  local output_path="$1"
  mkdir -p "$(dirname "$output_path")"
  /usr/bin/swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name(\"${SMOKE_NAMESPACE}.smoke.dumpAskState\"), object: nil, userInfo: [\"file_path\": \"$output_path\"], deliverImmediately: true)"
}

wait_for_state_file() {
  local output_path="$1"
  local attempts="${2:-40}"
  local index=0
  while [[ $index -lt $attempts ]]; do
    if [[ -s "$output_path" ]]; then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}

json_read() {
  local file_path="$1"
  local key_path="$2"
  /usr/bin/python3 - "$file_path" "$key_path" <<'PY'
import json
import sys

path, key_path = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
value = data
for part in key_path.split("."):
    if isinstance(value, dict):
        value = value.get(part)
    else:
        value = None
        break
if value is None:
    print("")
elif isinstance(value, bool):
    print("true" if value else "false")
else:
    print(value)
PY
}

wait_for_state_condition() {
  local state_file="$1"
  local python_expr="$2"
  local attempts="${3:-120}"
  local index=0
  while [[ $index -lt $attempts ]]; do
    dump_ask_state "$state_file"
    if wait_for_state_file "$state_file" 12; then
if /usr/bin/python3 - "$state_file" "$python_expr" <<'PY'
import json
import sys

path, expr = sys.argv[1], sys.argv[2]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
safe_builtins = {"bool": bool, "len": len, "str": str, "float": float, "int": int}
if eval(expr, {"__builtins__": safe_builtins}, {"data": data}):
    sys.exit(0)
sys.exit(1)
PY
      then
        return 0
      fi
    fi
    sleep 1
    index=$((index + 1))
  done
  return 1
}
