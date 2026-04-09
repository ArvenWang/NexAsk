#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

DIST_DIR="$ROOT_DIR/dist"
APP_NAME="$NEXHUB_PRODUCT_NAME"
DIST_BASENAME="$NEXHUB_DIST_BASENAME"
APP_PATH="$DIST_DIR/${APP_NAME}.app"
PACKAGE_FALLBACK_SUFFIX="${NEXHUB_PACKAGE_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
PACKAGE_PREFIX="$(resolve_package_prefix "$DIST_BASENAME" "$APP_PATH" "${NEXHUB_PACKAGE_PREFIX:-}" "$PACKAGE_FALLBACK_SUFFIX")"
ZIP_PATH="$DIST_DIR/${PACKAGE_PREFIX}-macOS.zip"
SHA_PATH="$DIST_DIR/${PACKAGE_PREFIX}-macOS.zip.sha256"
DMG_PATH="$DIST_DIR/${PACKAGE_PREFIX}-macOS.dmg"
DMG_SHA_PATH="$DIST_DIR/${PACKAGE_PREFIX}-macOS.dmg.sha256"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/${APP_NAME}.dmg.XXXXXX")"
RW_DMG_PATH="$STAGE_DIR/${PACKAGE_PREFIX}-temp.dmg"
VOLUME_NAME="${APP_NAME} Installer"
SKIP_BUILD="${NEXHUB_SKIP_BUILD:-0}"

cleanup() {
  rm -rf "$STAGE_DIR"
}
trap cleanup EXIT

if [[ "$SKIP_BUILD" != "1" ]]; then
  "$ROOT_DIR/scripts/build_app.sh"
elif [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app bundle missing: $APP_PATH"
  echo "Build first or unset NEXHUB_SKIP_BUILD."
  exit 1
fi

rm -f "$ZIP_PATH" "$SHA_PATH" "$DMG_PATH" "$DMG_SHA_PATH"

# Use ditto so the app bundle and code signature metadata survive compression.
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$SHA_PATH"

codesign --verify --deep --strict "$APP_PATH"

if xcrun stapler validate -q "$APP_PATH" >/dev/null 2>&1; then
  STAPLE_STATUS="stapled"
else
  STAPLE_STATUS="not-stapled"
fi

if spctl -a -t exec -vv "$APP_PATH" >/dev/null 2>&1; then
  GATEKEEPER_STATUS="accepted"
else
  GATEKEEPER_STATUS="notarization-required"
fi

mkdir -p "$STAGE_DIR/$APP_NAME"
cp -R "$APP_PATH" "$STAGE_DIR/$APP_NAME/"
ln -s /Applications "$STAGE_DIR/$APP_NAME/Applications"

SIZE_KB="$(du -sk "$STAGE_DIR/$APP_NAME" | awk '{ print $1 }')"
BASE_MB="$(( (SIZE_KB + 1023) / 1024 ))"
OVERHEAD_MB="$(( BASE_MB / 2 ))"
if [[ "$OVERHEAD_MB" -lt 512 ]]; then
  OVERHEAD_MB=512
fi
SIZE_MB="$(( BASE_MB + OVERHEAD_MB ))"

hdiutil create \
  -quiet \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE_DIR/$APP_NAME" \
  -fs HFS+ \
  -format UDZO \
  -imagekey zlib-level=9 \
  -size "${SIZE_MB}m" \
  "$DMG_PATH"
shasum -a 256 "$DMG_PATH" > "$DMG_SHA_PATH"

echo "Packaged: $ZIP_PATH"
echo "SHA256:   $SHA_PATH"
echo "Packaged: $DMG_PATH"
echo "SHA256:   $DMG_SHA_PATH"
echo "Package:  $PACKAGE_PREFIX"
echo "Staple:   $STAPLE_STATUS"
echo "Share the dmg file. The receiver can open it and drag ${APP_NAME}.app into Applications."
if [[ "$GATEKEEPER_STATUS" == "notarization-required" ]]; then
  echo "Gatekeeper: app is signed but not notarized."
  echo "Recipients may need right-click -> Open on first launch, especially if the dmg is downloaded from the internet."
fi
