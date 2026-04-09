#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_NAME="$NEXHUB_PRODUCT_NAME"
EXECUTABLE_NAME="$NEXHUB_EXECUTABLE_NAME"
SRC_APP="${1:-$ROOT_DIR/dist/${APP_NAME}.app}"
DST_APP="/Applications/${APP_NAME}.app"
TMP_APP="${DST_APP}.new"
INFO_PLIST="$DST_APP/Contents/Info.plist"
MENU_BAR_ICON="$DST_APP/Contents/Resources/MenuBarIconTemplate.png"
APP_ICON="$DST_APP/Contents/Resources/AppIcon.icns"
BUILD_INFO="$DST_APP/Contents/Resources/build_info.json"
BUILTIN_SKILLS_DIR="$DST_APP/Contents/Resources/BuiltinSkills"

verify_installed_bundle() {
  [[ -f "$INFO_PLIST" ]] || return 1
  [[ -f "$MENU_BAR_ICON" ]] || return 1
  [[ -f "$APP_ICON" ]] || return 1
  [[ -f "$BUILD_INFO" ]] || return 1
  [[ -d "$BUILTIN_SKILLS_DIR" ]] || return 1
}

if [[ ! -d "$SRC_APP" ]]; then
  echo "Source app not found: $SRC_APP"
  echo "Build first: ./scripts/build_app.sh"
  exit 1
fi

echo "Installing to: $DST_APP"
pkill -f "$DST_APP/Contents/MacOS/$EXECUTABLE_NAME" >/dev/null 2>&1 || true
sleep 0.3
rm -rf "$TMP_APP"
ditto "$SRC_APP" "$TMP_APP"
xattr -dr com.apple.quarantine "$TMP_APP" >/dev/null 2>&1 || true
rm -rf "$DST_APP"
mv "$TMP_APP" "$DST_APP"

if ! verify_installed_bundle; then
  echo "Install verification failed after move; retrying with direct ditto copy..."
  rm -rf "$DST_APP"
  ditto "$SRC_APP" "$DST_APP"
  xattr -dr com.apple.quarantine "$DST_APP" >/dev/null 2>&1 || true
fi

if ! verify_installed_bundle; then
  echo "Installed app is incomplete: $DST_APP"
  exit 1
fi

echo "Installed: $DST_APP"
if [[ -f "$INFO_PLIST" ]]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST" 2>/dev/null || echo unknown)"
  BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO_PLIST" 2>/dev/null || echo unknown)"
  GIT_SHA="$(/usr/libexec/PlistBuddy -c 'Print :NexHubGitSHA' "$INFO_PLIST" 2>/dev/null || echo unknown)"
  BUILD_TIME="$(/usr/libexec/PlistBuddy -c 'Print :NexHubBuildTimeUTC' "$INFO_PLIST" 2>/dev/null || echo unknown)"
  echo "Installed version: $VERSION ($BUILD)"
  echo "Installed git sha: $GIT_SHA"
  echo "Installed build time (UTC): $BUILD_TIME"
fi
echo "Run: open '$DST_APP'"
