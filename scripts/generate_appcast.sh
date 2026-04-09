#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

DIST_DIR="$ROOT_DIR/dist"
DIST_BASENAME="$NEXHUB_DIST_BASENAME"
APP_PATH="$DIST_DIR/${NEXHUB_PRODUCT_NAME}.app"
PACKAGE_FALLBACK_SUFFIX="${NEXHUB_PACKAGE_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
PACKAGE_PREFIX="$(resolve_package_prefix "$DIST_BASENAME" "$APP_PATH" "${NEXHUB_PACKAGE_PREFIX:-}" "$PACKAGE_FALLBACK_SUFFIX")"
ZIP_PATH="$DIST_DIR/${PACKAGE_PREFIX}-macOS.zip"
UPDATE_FEED_DIR="${NEXHUB_UPDATE_FEED_DIR:-$DIST_DIR/update_feed}"
UPDATE_FEED_URL="${NEXHUB_UPDATE_FEED_URL:-}"
UPDATE_DOWNLOAD_BASE_URL="${NEXHUB_UPDATE_DOWNLOAD_BASE_URL:-}"
UPDATE_WEBSITE_URL="${NEXHUB_UPDATE_WEBSITE_URL:-}"
SPARKLE_TOOLS_DIR="$ROOT_DIR/Vendor/Sparkle/bin"
SPARKLE_APPCAST_TOOL="$SPARKLE_TOOLS_DIR/generate_appcast"
SPARKLE_SIGN_TOOL="$SPARKLE_TOOLS_DIR/sign_update"
SPARKLE_KEY_ACCOUNT="${NEXHUB_SPARKLE_KEY_ACCOUNT:-NexHub}"
SPARKLE_PRIVATE_KEY_FILE="${NEXHUB_SPARKLE_PRIVATE_KEY_FILE:-}"
RESET_APPCAST="${NEXHUB_RESET_APPCAST:-0}"

if [[ -z "$UPDATE_FEED_URL" ]]; then
  echo "NEXHUB_UPDATE_FEED_URL is required."
  echo "Example: https://downloads.example.com/nexhub/appcast.xml"
  exit 1
fi

if [[ ! -x "$SPARKLE_APPCAST_TOOL" ]]; then
  echo "Sparkle generate_appcast tool is missing: $SPARKLE_APPCAST_TOOL"
  exit 1
fi

if [[ ! -x "$SPARKLE_SIGN_TOOL" ]]; then
  echo "Sparkle sign_update tool is missing: $SPARKLE_SIGN_TOOL"
  exit 1
fi

if [[ ! -f "$ZIP_PATH" ]]; then
  echo "Release archive not found: $ZIP_PATH"
  echo "Run ./scripts/package_share.sh or ./scripts/release.sh first."
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Built app not found: $APP_PATH"
  echo "Run ./scripts/build_app.sh or ./scripts/release.sh first."
  exit 1
fi

if [[ -z "$UPDATE_DOWNLOAD_BASE_URL" ]]; then
  UPDATE_DOWNLOAD_BASE_URL="${UPDATE_FEED_URL%/*}"
fi

if [[ -z "$UPDATE_DOWNLOAD_BASE_URL" || "$UPDATE_DOWNLOAD_BASE_URL" == "$UPDATE_FEED_URL" ]]; then
  echo "Unable to infer NEXHUB_UPDATE_DOWNLOAD_BASE_URL from NEXHUB_UPDATE_FEED_URL."
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
GIT_SHA="$(/usr/libexec/PlistBuddy -c 'Print :NexHubGitSHA' "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"

if [[ -z "$VERSION" || -z "$BUILD" || -z "$GIT_SHA" ]]; then
  echo "Unable to read version metadata from $APP_PATH/Contents/Info.plist"
  exit 1
fi

SAFE_VERSION="${VERSION//[^0-9A-Za-z._-]/-}"
SAFE_BUILD="${BUILD//[^0-9A-Za-z._-]/-}"
VERSIONED_ARCHIVE_NAME="${DIST_BASENAME}-${SAFE_VERSION}-${SAFE_BUILD}-macOS.zip"
VERSIONED_ARCHIVE_PATH="$UPDATE_FEED_DIR/$VERSIONED_ARCHIVE_NAME"
RELEASE_NOTES_PATH="${VERSIONED_ARCHIVE_PATH%.zip}.md"
APPCAST_PATH="$UPDATE_FEED_DIR/appcast.xml"
PUBLISHED_APPCAST_PATH="${NEXHUB_UPDATE_APPCAST_OUTPUT_PATH:-$APPCAST_PATH}"

mkdir -p "$UPDATE_FEED_DIR"

if [[ "$RESET_APPCAST" == "1" ]] && [[ -f "$PUBLISHED_APPCAST_PATH" ]]; then
  rm -f "$PUBLISHED_APPCAST_PATH"
fi

find "$UPDATE_FEED_DIR" -maxdepth 1 -type f \
  \( -name "${DIST_BASENAME}-${SAFE_VERSION}-*-macOS.zip" -o -name "${DIST_BASENAME}-${SAFE_VERSION}-*-macOS.md" \) \
  ! -name "$VERSIONED_ARCHIVE_NAME" \
  -delete

cp "$ZIP_PATH" "$VERSIONED_ARCHIVE_PATH"

cat > "$RELEASE_NOTES_PATH" <<MARKDOWN
# NexHub ${VERSION} (${BUILD})

- Build: \`${BUILD}\`
- Git SHA: \`${GIT_SHA}\`
- Published from the managed NexHub release pipeline.

This package is intended for Sparkle in-app updates.
MARKDOWN

APPCAST_CMD=("$SPARKLE_APPCAST_TOOL")
if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  APPCAST_CMD+=("--ed-key-file" "$SPARKLE_PRIVATE_KEY_FILE")
else
  APPCAST_CMD+=("--account" "$SPARKLE_KEY_ACCOUNT")
fi
APPCAST_CMD+=(
  "--download-url-prefix" "$UPDATE_DOWNLOAD_BASE_URL"
  "--release-notes-url-prefix" "$UPDATE_DOWNLOAD_BASE_URL"
  "--embed-release-notes"
  "-o" "$PUBLISHED_APPCAST_PATH"
)

if [[ -n "$UPDATE_WEBSITE_URL" ]]; then
  APPCAST_CMD+=("--link" "$UPDATE_WEBSITE_URL")
fi

APPCAST_CMD+=("$UPDATE_FEED_DIR")

"${APPCAST_CMD[@]}"

python3 - "$PUBLISHED_APPCAST_PATH" "$UPDATE_DOWNLOAD_BASE_URL" <<'PY'
import pathlib
import re
import sys

appcast_path = pathlib.Path(sys.argv[1])
download_base = sys.argv[2].rstrip("/")
content = appcast_path.read_text(encoding="utf-8")

def replace(match: re.Match[str]) -> str:
    original_url = match.group(1)
    filename = pathlib.PurePosixPath(original_url).name
    return f'url="{download_base}/{filename}"'

updated = re.sub(r'url="([^"]+\.zip)"', replace, content)

if updated != content:
    appcast_path.write_text(updated, encoding="utf-8")
PY

SIGN_CMD=("$SPARKLE_SIGN_TOOL")
if [[ -n "$SPARKLE_PRIVATE_KEY_FILE" ]]; then
  SIGN_CMD+=("--ed-key-file" "$SPARKLE_PRIVATE_KEY_FILE")
else
  SIGN_CMD+=("--account" "$SPARKLE_KEY_ACCOUNT")
fi
SIGN_CMD+=("$PUBLISHED_APPCAST_PATH")

"${SIGN_CMD[@]}"

echo "Generated appcast: $PUBLISHED_APPCAST_PATH"
echo "Update archive:    $VERSIONED_ARCHIVE_PATH"
echo "Upload directory:  $UPDATE_FEED_DIR"
