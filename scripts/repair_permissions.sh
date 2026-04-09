#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_ID="$NEXHUB_BUNDLE_ID"
APP_PATH="/Applications/${NEXHUB_PRODUCT_NAME}.app"
EXECUTABLE_NAME="$NEXHUB_EXECUTABLE_NAME"

pkill -f "$APP_PATH/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1 || true
sleep 0.3

echo "Reset Accessibility permission for $APP_ID ..."
tccutil reset Accessibility "$APP_ID" || true

echo "Opening Accessibility settings ..."
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility" || true
open "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility" || true

echo "Starting app ..."
open "$APP_PATH"

echo "Done."
