#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

DIST_DIR="$ROOT_DIR/dist"
APP_NAME="$NEXHUB_PRODUCT_NAME"
DIST_BASENAME="$NEXHUB_DIST_BASENAME"
PACKAGE_TIMESTAMP="${NEXHUB_PACKAGE_TIMESTAMP:-$(date -u +%Y%m%dT%H%M%SZ)}"
export NEXHUB_PACKAGE_TIMESTAMP="$PACKAGE_TIMESTAMP"
APP_PATH="$DIST_DIR/${APP_NAME}.app"
ALLOW_DIRTY="${NEXHUB_ALLOW_DIRTY:-0}"
INSTALL_AFTER_BUILD="${NEXHUB_INSTALL_AFTER_BUILD:-0}"
NOTARY_PROFILE="${NEXHUB_NOTARY_PROFILE:-}"
SKIP_CHECKS="${NEXHUB_SKIP_CHECKS:-0}"
MANIFEST_PATH="$DIST_DIR/release_manifest.json"
RELEASE_MODE="${NEXHUB_RELEASE_MODE:-candidate}"
UPDATE_FEED_URL="${NEXHUB_UPDATE_FEED_URL:-}"
RELEASE_BASE_URL="${NEXHUB_RELEASE_BASE_URL:-}"
AUTO_PUBLISH_UPDATES="${NEXHUB_PUBLISH_UPDATES:-0}"
AUTO_PUBLISH_RELEASE="${NEXHUB_PUBLISH_RELEASE:-0}"

cd "$ROOT_DIR"

case "$RELEASE_MODE" in
  candidate|formal) ;;
  *)
    echo "Unsupported NEXHUB_RELEASE_MODE: $RELEASE_MODE"
    echo "Use: candidate or formal"
    exit 1
    ;;
esac

if [[ "$RELEASE_MODE" == "formal" ]]; then
  if [[ "$ALLOW_DIRTY" == "1" ]]; then
    echo "Formal release mode does not allow NEXHUB_ALLOW_DIRTY=1."
    exit 1
  fi
  if [[ "$SKIP_CHECKS" == "1" ]]; then
    echo "Formal release mode does not allow NEXHUB_SKIP_CHECKS=1."
    exit 1
  fi
  if [[ -z "$NOTARY_PROFILE" ]]; then
    echo "Formal release mode requires NEXHUB_NOTARY_PROFILE."
    exit 1
  fi
fi

if [[ "$RELEASE_MODE" == "formal" ]]; then
  if [[ -n "${NEXHUB_UPDATE_PUBLISH_HOST:-}" && -n "${NEXHUB_UPDATE_PUBLISH_TARGET_DIR:-}" ]]; then
    AUTO_PUBLISH_UPDATES="1"
  fi
  if [[ -n "${NEXHUB_RELEASE_PUBLISH_HOST:-}" && -n "${NEXHUB_RELEASE_PUBLISH_TARGET_DIR:-}" ]]; then
    AUTO_PUBLISH_RELEASE="1"
  fi
fi

if [[ "$ALLOW_DIRTY" != "1" ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo "Refusing to create a release from a dirty working tree."
  echo "Commit or stash changes first, or rerun with NEXHUB_ALLOW_DIRTY=1."
  git status --short
  exit 1
fi

if [[ "$SKIP_CHECKS" != "1" ]]; then
  echo "==> Running project checks"
  "$ROOT_DIR/scripts/checks.sh"
else
  echo "==> Skipping project checks (NEXHUB_SKIP_CHECKS=1)"
fi

echo "==> Building app"
"$ROOT_DIR/scripts/build_app.sh"

echo "==> Verifying code signature"
codesign --verify --deep --strict "$APP_PATH"

if [[ "$RELEASE_MODE" == "formal" ]]; then
  SIGNING_INFO="$(codesign -dv --verbose=2 "$APP_PATH" 2>&1 || true)"
  if ! printf '%s\n' "$SIGNING_INFO" | grep -q "Authority=Developer ID Application:"; then
    echo "Formal release mode requires a Developer ID Application signature."
    printf '%s\n' "$SIGNING_INFO"
    exit 1
  fi
fi

if [[ "$INSTALL_AFTER_BUILD" == "1" ]]; then
  echo "==> Installing to /Applications"
  "$ROOT_DIR/scripts/install_app.sh" "$APP_PATH"
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
GIT_SHA="$(/usr/libexec/PlistBuddy -c 'Print :NexHubGitSHA' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
BUILD_TIME="$(/usr/libexec/PlistBuddy -c 'Print :NexHubBuildTimeUTC' "$APP_PATH/Contents/Info.plist" 2>/dev/null || echo unknown)"
SAFE_VERSION="$(sanitize_release_token "$VERSION")"
SAFE_BUILD="$(sanitize_release_token "$BUILD")"
PACKAGE_PREFIX="$(resolve_package_prefix "$DIST_BASENAME" "$APP_PATH" "${NEXHUB_PACKAGE_PREFIX:-}" "$PACKAGE_TIMESTAMP")"
export NEXHUB_PACKAGE_PREFIX="$PACKAGE_PREFIX"

if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "==> Notarizing app"
  NEXHUB_NOTARY_PROFILE="$NOTARY_PROFILE" "$ROOT_DIR/scripts/notarize_app.sh" "$APP_PATH"
else
  echo "==> Skipping notarization (set NEXHUB_NOTARY_PROFILE to enable it)"
fi

echo "==> Packaging release artifacts"
NEXHUB_SKIP_BUILD=1 "$ROOT_DIR/scripts/package_share.sh"

DMG_PATH="$DIST_DIR/${PACKAGE_PREFIX}-macOS.dmg"
ZIP_PATH="$DIST_DIR/${PACKAGE_PREFIX}-macOS.zip"
DMG_FILENAME="$(basename "$DMG_PATH")"
ZIP_FILENAME="$(basename "$ZIP_PATH")"
STABLE_DMG_FILENAME="${DIST_BASENAME}-macOS.dmg"
STABLE_DMG_SHA_FILENAME="${STABLE_DMG_FILENAME}.sha256"
STABLE_ZIP_FILENAME="${DIST_BASENAME}-macOS.zip"
STABLE_ZIP_SHA_FILENAME="${STABLE_ZIP_FILENAME}.sha256"

DMG_NOTARIZED="false"
if [[ -n "$NOTARY_PROFILE" ]]; then
  echo "==> Notarizing DMG"
  NEXHUB_NOTARY_PROFILE="$NOTARY_PROFILE" "$ROOT_DIR/scripts/notarize_app.sh" "$DMG_PATH"
  DMG_NOTARIZED="true"
fi

UPDATE_MANIFEST_BLOCK=""
PUBLISH_MANIFEST_BLOCK=""
NOTARIZATION_MANIFEST_BLOCK=""

if [[ -n "$UPDATE_FEED_URL" ]]; then
  echo "==> Generating Sparkle appcast"
  "$ROOT_DIR/scripts/generate_appcast.sh"
  UPDATE_MANIFEST_BLOCK="$(cat <<JSON
,
  "updates": {
    "feed_url": "$UPDATE_FEED_URL",
    "appcast": "dist/update_feed/appcast.xml",
    "latest_archive": "dist/update_feed/${DIST_BASENAME}-${SAFE_VERSION}-${SAFE_BUILD}-macOS.zip"
  }
JSON
)"
else
  echo "==> Skipping Sparkle appcast generation (set NEXHUB_UPDATE_FEED_URL to enable auto-updates)"
fi

if [[ "$AUTO_PUBLISH_UPDATES" == "1" ]]; then
  echo "==> Publishing Sparkle update feed"
  "$ROOT_DIR/scripts/publish_update_feed.sh"
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  NOTARIZATION_MANIFEST_BLOCK="$(cat <<JSON
,
  "notarization": {
    "profile": "$NOTARY_PROFILE",
    "app_stapled": true,
    "dmg_stapled": $DMG_NOTARIZED
  }
JSON
)"
fi

if [[ -n "$RELEASE_BASE_URL" || "$AUTO_PUBLISH_RELEASE" == "1" ]]; then
  PUBLISH_MANIFEST_BLOCK="$(cat <<JSON
,
  "distribution": {
    "release_base_url": "${RELEASE_BASE_URL:-}",
    "dmg_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${DMG_FILENAME}}",
    "dmg_sha256_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${DMG_FILENAME}.sha256}",
    "zip_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${ZIP_FILENAME}}",
    "zip_sha256_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${ZIP_FILENAME}.sha256}",
    "stable_dmg_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${STABLE_DMG_FILENAME}}",
    "stable_dmg_sha256_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${STABLE_DMG_SHA_FILENAME}}",
    "stable_zip_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${STABLE_ZIP_FILENAME}}",
    "stable_zip_sha256_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/${STABLE_ZIP_SHA_FILENAME}}",
    "manifest_url": "${RELEASE_BASE_URL:+${RELEASE_BASE_URL%/}/release_manifest.json}",
    "updates_published": $([[ "$AUTO_PUBLISH_UPDATES" == "1" ]] && echo "true" || echo "false"),
    "release_published": $([[ "$AUTO_PUBLISH_RELEASE" == "1" ]] && echo "true" || echo "false")
  }
JSON
)"
fi

cat > "$MANIFEST_PATH" <<JSON
{
  "app": "$APP_NAME",
  "version": "$VERSION",
  "build": "$BUILD",
  "git_sha": "$GIT_SHA",
  "build_time_utc": "$BUILD_TIME",
  "notarized": $([[ -n "$NOTARY_PROFILE" ]] && echo "true" || echo "false"),
  "artifacts": {
    "app": "dist/${APP_NAME}.app",
    "dmg": "dist/${PACKAGE_PREFIX}-macOS.dmg",
    "dmg_sha256": "dist/${PACKAGE_PREFIX}-macOS.dmg.sha256",
    "zip": "dist/${PACKAGE_PREFIX}-macOS.zip",
    "zip_sha256": "dist/${PACKAGE_PREFIX}-macOS.zip.sha256"
  }
${UPDATE_MANIFEST_BLOCK}${NOTARIZATION_MANIFEST_BLOCK}${PUBLISH_MANIFEST_BLOCK}
}
JSON

echo "==> Validating release manifest"
"$ROOT_DIR/scripts/validate_release_manifest.sh" "$MANIFEST_PATH"

if [[ "$AUTO_PUBLISH_RELEASE" == "1" ]]; then
  echo "==> Publishing release artifacts"
  "$ROOT_DIR/scripts/publish_release_artifacts.sh"
fi

if [[ "$RELEASE_MODE" == "formal" || "$AUTO_PUBLISH_UPDATES" == "1" || "$AUTO_PUBLISH_RELEASE" == "1" ]]; then
  echo "==> Verifying distribution artifacts"
  "$ROOT_DIR/scripts/verify_distribution.sh"
fi

echo "==> Preparing share directory"
"$ROOT_DIR/scripts/prepare_share_directory.sh"

echo "==> Release manifest"
echo "$MANIFEST_PATH"
echo "Release complete."
