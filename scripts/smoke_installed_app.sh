#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_NAME="$NEXHUB_PRODUCT_NAME"
EXECUTABLE_NAME="$NEXHUB_EXECUTABLE_NAME"
SUPPORT_DIR_NAME="$NEXHUB_SUPPORT_DIR_NAME"
APP_PATH="${1:-/Applications/${APP_NAME}.app}"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
EXECUTABLE_PATH="$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME"
SKILLS_PATH="$APP_PATH/Contents/Resources/BuiltinSkills"
BUILD_INFO_PATH="$APP_PATH/Contents/Resources/build_info.json"
PYTHON_RUNTIME_PATH="$APP_PATH/Contents/Resources/PythonRuntime"
LEGACY_GATEWAY_PATH="$APP_PATH/Contents/Resources/local_gateway.py"
EXPECTED_LOG_PATH="$HOME/Library/Application Support/${SUPPORT_DIR_NAME}/Logs/runtime.log"

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

if [[ ! -d "$APP_PATH" ]]; then
  fail "Installed app missing: $APP_PATH"
fi
pass "Installed app exists."

[[ -f "$INFO_PLIST" ]] || fail "Missing Info.plist"
[[ -x "$EXECUTABLE_PATH" ]] || fail "Missing app executable"
[[ -d "$SKILLS_PATH" ]] || fail "Missing bundled BuiltinSkills"
[[ -f "$BUILD_INFO_PATH" ]] || fail "Missing build_info.json"
pass "Core bundled resources are present."

if [[ -e "$LEGACY_GATEWAY_PATH" ]]; then
  fail "Legacy local gateway is still bundled: $LEGACY_GATEWAY_PATH"
fi

if [[ -e "$PYTHON_RUNTIME_PATH" ]]; then
  fail "Bundled Python runtime should be removed: $PYTHON_RUNTIME_PATH"
fi
pass "Legacy Python gateway resources are absent."

launch_app || fail "Installed app could not be launched."
sleep 3

if pgrep -f "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1; then
  pass "Installed app launched and process is alive."
else
  fail "Installed app did not stay running after launch."
fi

if [[ -f "$EXPECTED_LOG_PATH" || -d "$(dirname "$EXPECTED_LOG_PATH")" ]]; then
  pass "Runtime log directory is in the formal Application Support location."
else
  echo "[WARN] Runtime log has not been created yet. Expected location remains: $EXPECTED_LOG_PATH"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo unknown)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || echo unknown)"
GIT_SHA="$(/usr/libexec/PlistBuddy -c 'Print :NexHubGitSHA' "$INFO_PLIST" 2>/dev/null || echo unknown)"

echo "Smoke OK: $APP_NAME $VERSION ($BUILD) [$GIT_SHA]"
