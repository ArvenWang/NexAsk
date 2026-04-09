#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

VERSION_FILE="$ROOT_DIR/VERSION"

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  if [[ "${NEXHUB_ALLOW_BUILD_WITHOUT_XCODE_LICENSE:-1}" == "1" ]]; then
    echo "Warning: Xcode license not accepted; continue with SwiftPM build path."
  else
    echo "Xcode license is not accepted yet."
    echo "Run: sudo xcodebuild -license"
    exit 69
  fi
fi

BUILD_PRODUCT_NAME="$NEXHUB_BUILD_PRODUCT_NAME"
EXECUTABLE_NAME="$NEXHUB_EXECUTABLE_NAME"
APP_NAME="$NEXHUB_PRODUCT_NAME"
BUNDLE_ID="$NEXHUB_BUNDLE_ID"
PRODUCT_PROFILE="$NEXHUB_PRODUCT_PROFILE"
SUPPORT_DIR_NAME="$NEXHUB_SUPPORT_DIR_NAME"
SMOKE_NAMESPACE="$NEXHUB_SMOKE_NAMESPACE"
BUILD_DIR="$ROOT_DIR/.build/release"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
if [[ -n "${NEXHUB_APP_VERSION:-}" ]]; then
  APP_VERSION="$NEXHUB_APP_VERSION"
elif [[ -f "$VERSION_FILE" ]]; then
  APP_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
else
APP_VERSION="0.2.0"
fi
BUILD_NUMBER="${NEXHUB_BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
GIT_SHA="${NEXHUB_GIT_SHA:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
BUILD_TIME_UTC="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
APP_ICON_PATH="${NEXHUB_APP_ICON:-$ROOT_DIR/Resources/AppIcon.icns}"
MENU_BAR_ICON_PATH="${NEXHUB_MENU_BAR_ICON:-$ROOT_DIR/Resources/MenuBarIconTemplate.png}"
ENTITLEMENTS_PATH="${NEXHUB_ENTITLEMENTS_PATH:-$ROOT_DIR/scripts/nexhub.entitlements}"
SPARKLE_FRAMEWORK_SOURCE="$ROOT_DIR/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
SPARKLE_TOOLS_DIR="$ROOT_DIR/Vendor/Sparkle/bin"
SPARKLE_PUBLIC_KEY="${NEXHUB_SPARKLE_PUBLIC_KEY:-}"
SPARKLE_PUBLIC_KEY_FILE="${NEXHUB_SPARKLE_PUBLIC_KEY_FILE:-}"
SPARKLE_KEY_ACCOUNT="${NEXHUB_SPARKLE_KEY_ACCOUNT:-}"
UPDATE_FEED_URL="${NEXHUB_UPDATE_FEED_URL:-}"
UPDATE_CHECK_INTERVAL="${NEXHUB_UPDATE_CHECK_INTERVAL:-14400}"
AUTO_CHECKS_ENABLED="${NEXHUB_UPDATE_AUTOMATIC_CHECKS:-1}"
AUTO_INSTALL_ENABLED="${NEXHUB_UPDATE_AUTOMATIC_INSTALL:-1}"
SWIFT_CACHE_ROOT="${NEXHUB_SWIFT_CACHE_DIR:-$ROOT_DIR/.build-codex/cache}"
SIGN_IDENTITY="${NEXHUB_CODESIGN_IDENTITY:-}"
SIGN_MODE="Unknown"
SIGNING_TEAM="Unknown"

bool_plist_tag() {
  local raw="${1:-1}"
  local normalized
  normalized="$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]')"
  case "$normalized" in
    0|false|no)
      echo "<false/>"
      ;;
    *)
      echo "<true/>"
      ;;
  esac
}

trim_file_value() {
  local path="$1"
  tr -d '[:space:]' < "$path"
}

if resolve_sparkle_public_key "$SPARKLE_PUBLIC_KEY" "$SPARKLE_PUBLIC_KEY_FILE" "$SPARKLE_KEY_ACCOUNT" "$SPARKLE_TOOLS_DIR/generate_keys"; then
  SPARKLE_PUBLIC_KEY="$RESOLVED_SPARKLE_PUBLIC_KEY"
  SPARKLE_PUBLIC_KEY_SOURCE="$RESOLVED_SPARKLE_PUBLIC_KEY_SOURCE"
else
  SPARKLE_PUBLIC_KEY=""
  SPARKLE_PUBLIC_KEY_SOURCE=""
fi

if [[ ! -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  echo "Missing Sparkle framework: $SPARKLE_FRAMEWORK_SOURCE"
  echo "Vendor the official Sparkle package into Vendor/Sparkle first."
  exit 1
fi

python3 "$ROOT_DIR/scripts/sync_localization_resources.py"

mkdir -p "$SWIFT_CACHE_ROOT/clang-module-cache" "$SWIFT_CACHE_ROOT/swiftpm-module-cache"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$SWIFT_CACHE_ROOT/clang-module-cache}"
export SWIFTPM_MODULECACHE_OVERRIDE="${SWIFTPM_MODULECACHE_OVERRIDE:-$SWIFT_CACHE_ROOT/swiftpm-module-cache}"

UPDATE_PLIST_BLOCK=""
if [[ -n "$UPDATE_FEED_URL" && -n "$SPARKLE_PUBLIC_KEY" ]]; then
  UPDATE_PLIST_BLOCK="$(cat <<PLIST
  <key>SUFeedURL</key>
  <string>${UPDATE_FEED_URL}</string>
  <key>SUPublicEDKey</key>
  <string>${SPARKLE_PUBLIC_KEY}</string>
  <key>SUEnableAutomaticChecks</key>
  $(bool_plist_tag "$AUTO_CHECKS_ENABLED")
  <key>SUAutomaticallyUpdate</key>
  $(bool_plist_tag "$AUTO_INSTALL_ENABLED")
  <key>SUAllowsAutomaticUpdates</key>
  <true/>
  <key>SUVerifyUpdateBeforeExtraction</key>
  <true/>
  <key>SURequireSignedFeed</key>
  <true/>
  <key>SUScheduledCheckInterval</key>
  <integer>${UPDATE_CHECK_INTERVAL}</integer>
PLIST
)"
fi

build_args=(
  -c release
  --product "$BUILD_PRODUCT_NAME"
)

if [[ "$PRODUCT_PROFILE" == "nexhub" ]]; then
  build_args+=(
    -Xswiftc -DNEXHUB_PRODUCT_NEXHUB
  )
fi

swift build "${build_args[@]}"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$FRAMEWORKS_DIR"

cp "$BUILD_DIR/$BUILD_PRODUCT_NAME" "$MACOS_DIR/$EXECUTABLE_NAME"
chmod +x "$MACOS_DIR/$EXECUTABLE_NAME"
while IFS= read -r -d '' resource_bundle; do
  ditto "$resource_bundle" "$RESOURCES_DIR/$(basename "$resource_bundle")"
done < <(find "$ROOT_DIR/.build" -type d -path "*/release/*.bundle" -print0)
if [[ -d "$SPARKLE_FRAMEWORK_SOURCE" ]]; then
  ditto "$SPARKLE_FRAMEWORK_SOURCE" "$FRAMEWORKS_DIR/Sparkle.framework"
  codesign --remove-signature "$FRAMEWORKS_DIR/Sparkle.framework" 2>/dev/null || true
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/$EXECUTABLE_NAME" 2>/dev/null || true
fi

cp -R "$ROOT_DIR/BuiltinSkills" "$RESOURCES_DIR/BuiltinSkills"
if [[ -d "$ROOT_DIR/SkillStore" ]]; then
  cp -R "$ROOT_DIR/SkillStore" "$RESOURCES_DIR/SkillStore"
fi
if [[ -f "$APP_ICON_PATH" ]]; then
  cp "$APP_ICON_PATH" "$RESOURCES_DIR/AppIcon.icns"
fi
if [[ -f "$MENU_BAR_ICON_PATH" ]]; then
  cp "$MENU_BAR_ICON_PATH" "$RESOURCES_DIR/MenuBarIconTemplate.png"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Developer ID Application:/ && $0 !~ /REVOKED/ { print $2; exit }')"
fi

if [[ -z "$SIGN_IDENTITY" ]]; then
  SIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F\" '/Apple Development:/ && $0 !~ /REVOKED/ { print $2; exit }')"
fi

if [[ -n "$SIGN_IDENTITY" ]]; then
  SIGN_MODE="Identity"
  if [[ "$SIGN_IDENTITY" =~ \(([A-Z0-9]+)\)$ ]]; then
    SIGNING_TEAM="${BASH_REMATCH[1]}"
  fi
else
  SIGN_MODE="Ad-hoc"
fi

write_build_metadata() {
  cat > "$RESOURCES_DIR/build_info.json" <<JSON
{
  "app_version": "$APP_VERSION",
  "build_number": "$BUILD_NUMBER",
  "git_sha": "$GIT_SHA",
  "build_time_utc": "$BUILD_TIME_UTC",
  "signing_mode": "$SIGN_MODE",
  "signing_identity": "$SIGN_IDENTITY",
  "signing_team": "$SIGNING_TEAM"
}
JSON

  cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleExecutable</key>
  <string>${EXECUTABLE_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${BUNDLE_ID}</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${APP_VERSION}</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_NUMBER}</string>
  <key>NexHubProductProfile</key>
  <string>${PRODUCT_PROFILE}</string>
  <key>NexHubSupportDirectoryName</key>
  <string>${SUPPORT_DIR_NAME}</string>
  <key>NexHubSmokeNamespace</key>
  <string>${SMOKE_NAMESPACE}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIconName</key>
  <string>AppIcon</string>
  <key>NexHubGitSHA</key>
  <string>${GIT_SHA}</string>
  <key>NexHubBuildTimeUTC</key>
  <string>${BUILD_TIME_UTC}</string>
  <key>NexHubSigningMode</key>
  <string>${SIGN_MODE}</string>
  <key>NexHubSigningIdentity</key>
  <string>${SIGN_IDENTITY}</string>
  <key>NexHubSigningTeam</key>
  <string>${SIGNING_TEAM}</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSCalendarsUsageDescription</key>
  <string>${APP_NAME} 需要访问日历来为你创建日程提醒。</string>
  <key>NSCalendarsWriteOnlyAccessUsageDescription</key>
  <string>${APP_NAME} 需要写入日历来为你创建日程提醒。</string>
  <key>NSCalendarsFullAccessUsageDescription</key>
  <string>${APP_NAME} 需要完整日历访问权限来创建和管理日程提醒。</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>${APP_NAME} 需要控制日历 App 来创建日程事件。</string>
${UPDATE_PLIST_BLOCK}
</dict>
</plist>
PLIST
}

codesign_target() {
  local path="$1"

  if [[ "$SIGN_MODE" == "Identity" ]]; then
    if ! codesign_with_timestamp_fallback --force --options runtime --sign "$SIGN_IDENTITY" "$path"; then
      return 1
    fi
  else
    codesign --force --sign - "$path"
  fi
}

sign_embedded_python_runtime() {
  return 0
}

codesign_with_timestamp_fallback() {
  local output=""
  if output="$(codesign "$@" --timestamp 2>&1)"; then
    return 0
  fi

  printf '%s\n' "$output" >&2
  if [[ "$output" == *"timestamp service is not available"* ]]; then
    echo "Timestamp service unavailable; retrying codesign without remote timestamp." >&2
    codesign "$@" --timestamp=none
    return $?
  fi

  return 1
}

sign_app_bundle() {
  if [[ "$SIGN_MODE" == "Identity" ]]; then
    if [[ -f "$ENTITLEMENTS_PATH" ]]; then
      codesign_with_timestamp_fallback --force --deep --options runtime --entitlements "$ENTITLEMENTS_PATH" --sign "$SIGN_IDENTITY" "$APP_DIR"
    else
      codesign_with_timestamp_fallback --force --deep --options runtime --sign "$SIGN_IDENTITY" "$APP_DIR"
    fi
  else
    if [[ -f "$ENTITLEMENTS_PATH" ]]; then
      codesign --force --deep --entitlements "$ENTITLEMENTS_PATH" --sign - "$APP_DIR"
    else
      codesign --force --deep --sign - "$APP_DIR"
    fi
  fi
}

write_build_metadata

sign_embedded_python_runtime

sign_app_bundle

if [[ "$SIGN_MODE" == "Identity" ]]; then
  DETECTED_SIGNING_TEAM="$(codesign -dv --verbose=2 "$APP_DIR" 2>&1 | awk -F= '/TeamIdentifier=/{print $2; exit}')"
  DETECTED_SIGNING_TEAM="${DETECTED_SIGNING_TEAM:-Unknown}"
  if [[ "$DETECTED_SIGNING_TEAM" != "$SIGNING_TEAM" ]]; then
    SIGNING_TEAM="$DETECTED_SIGNING_TEAM"
    write_build_metadata
    sign_app_bundle
  fi
fi

echo "Built: $APP_DIR"
echo "Version: $APP_VERSION ($BUILD_NUMBER)"
echo "Git SHA: $GIT_SHA"
echo "Build time (UTC): $BUILD_TIME_UTC"
echo "Code sign: $SIGN_MODE"
if [[ "$SIGN_MODE" == "Identity" ]]; then
  echo "Identity: $SIGN_IDENTITY"
fi
if [[ "$SIGN_MODE" == "Ad-hoc" ]]; then
  echo "Note: Ad-hoc signature may still trigger Accessibility re-authorization after updates."
  echo "Set NEXHUB_CODESIGN_IDENTITY to a stable Developer ID cert for long-term TCC stability."
fi
if [[ -n "$UPDATE_FEED_URL" && -n "$SPARKLE_PUBLIC_KEY" ]]; then
  echo "Auto-update: enabled"
  echo "Feed URL:    $UPDATE_FEED_URL"
  echo "Key source:  ${SPARKLE_PUBLIC_KEY_SOURCE:-unknown}"
else
  echo "Auto-update: disabled"
  if [[ -z "$UPDATE_FEED_URL" ]]; then
    echo "Note: Set NEXHUB_UPDATE_FEED_URL to enable Sparkle updates."
  fi
  if [[ -n "$UPDATE_FEED_URL" && -z "$SPARKLE_PUBLIC_KEY" ]]; then
    echo "Note: Set NEXHUB_SPARKLE_PUBLIC_KEY / NEXHUB_SPARKLE_PUBLIC_KEY_FILE or generate a key for account '$SPARKLE_KEY_ACCOUNT'."
  fi
fi
if [[ ! -f "$APP_ICON_PATH" ]]; then
  echo "Note: App icon not found at '$APP_ICON_PATH'. The app will use the default icon."
fi
if [[ ! -f "$MENU_BAR_ICON_PATH" ]]; then
  echo "Note: Menu bar icon not found at '$MENU_BAR_ICON_PATH'. The app will use the fallback symbol."
fi
echo "Run: open '$APP_DIR'"
