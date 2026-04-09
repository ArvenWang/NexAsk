#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_NAME="$NEXHUB_PRODUCT_NAME"
EXECUTABLE_NAME="$NEXHUB_EXECUTABLE_NAME"
SMOKE_NAMESPACE="$NEXHUB_SMOKE_NAMESPACE"
APP_PATH="${1:-/Applications/${APP_NAME}.app}"
WINDOW_TITLE="${APP_NAME} Settings"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"

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

[[ -d "$APP_PATH" ]] || fail "Installed app missing: $APP_PATH"

launch_app || fail "Installed app could not be launched for UI smoke."
sleep 2

if ! pgrep -f "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1; then
  fail "App process is not running after launch."
fi
pass "Installed app launched for UI smoke."

post_settings_notification() {
  local tab="$1"
  /usr/bin/swift -e "import Foundation; DistributedNotificationCenter.default().postNotificationName(Notification.Name(\"${SMOKE_NAMESPACE}.smoke.openSettings\"), object: nil, userInfo: [\"tab\": \"$tab\"], deliverImmediately: true)"
}

wait_for_identifier() {
  local identifier="$1"
  local attempts=40
  local index=0

  while [[ $index -lt $attempts ]]; do
    if /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "System Events"
  tell process "$APP_NAME"
    if not (exists window "$WINDOW_TITLE") then
      return false
    end if
    set allElements to entire contents of window "$WINDOW_TITLE"
    repeat with elem in allElements
      try
        if value of attribute "AXIdentifier" of elem is "$identifier" then
          return true
        end if
      end try
    end repeat
  end tell
end tell
return false
APPLESCRIPT
    then
      return 0
    fi
    sleep 0.25
    index=$((index + 1))
  done

  return 1
}

close_settings_window() {
  /usr/bin/osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application "System Events"
  tell process "$APP_NAME"
    if exists window "$WINDOW_TITLE" then
      click button 1 of window "$WINDOW_TITLE"
    end if
  end tell
end tell
APPLESCRIPT
}

post_settings_notification "ai"
wait_for_identifier "${SMOKE_NAMESPACE}.settings.ai.api-key" || fail "AI settings sentinel not found."
pass "AI tab opened and sentinel is visible."

post_settings_notification "privacy"
wait_for_identifier "${SMOKE_NAMESPACE}.settings.privacy.status" || fail "Privacy settings sentinel not found."
pass "Privacy tab opened and sentinel is visible."

post_settings_notification "knowledge-base"
wait_for_identifier "${SMOKE_NAMESPACE}.settings.knowledge-base.search" || fail "Knowledge Base settings sentinel not found."
pass "Knowledge Base tab opened and sentinel is visible."

close_settings_window
sleep 1

if pgrep -f "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1; then
  pass "App process is still alive after closing the settings window."
else
  fail "App process exited unexpectedly after UI smoke."
fi

echo "UI smoke OK: $APP_NAME"
