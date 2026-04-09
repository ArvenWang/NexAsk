#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

DIST_DIR="$ROOT_DIR/dist"
APP_NAME="$NEXHUB_PRODUCT_NAME"
DIST_BASENAME="$NEXHUB_DIST_BASENAME"
APP_PATH="$DIST_DIR/${APP_NAME}.app"
MANIFEST_PATH="$DIST_DIR/release_manifest.json"
RELEASE_BASE_URL="${NEXHUB_RELEASE_BASE_URL:-}"
UPDATE_FEED_URL="${NEXHUB_UPDATE_FEED_URL:-}"

if [[ -f "$MANIFEST_PATH" ]]; then
  eval "$(
  python3 - "$MANIFEST_PATH" <<'PY'
import json
import pathlib
import shlex
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
artifacts = manifest.get("artifacts", {})
distribution = manifest.get("distribution", {})
updates = manifest.get("updates", {})

fields = {
    "DMG_PATH": artifacts.get("dmg", ""),
    "ZIP_PATH": artifacts.get("zip", ""),
    "MANIFEST_NOTARIZED": "true" if manifest.get("notarized") else "false",
    "MANIFEST_RELEASE_BASE_URL": distribution.get("release_base_url", ""),
    "STABLE_DMG_URL": distribution.get("stable_dmg_url", ""),
    "STABLE_DMG_SHA256_URL": distribution.get("stable_dmg_sha256_url", ""),
    "STABLE_ZIP_URL": distribution.get("stable_zip_url", ""),
    "STABLE_ZIP_SHA256_URL": distribution.get("stable_zip_sha256_url", ""),
    "MANIFEST_URL": distribution.get("manifest_url", ""),
    "FEED_URL": updates.get("feed_url", ""),
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(value)}")
PY
  )"
fi

if [[ -z "$RELEASE_BASE_URL" && -n "${MANIFEST_RELEASE_BASE_URL:-}" ]]; then
  RELEASE_BASE_URL="$MANIFEST_RELEASE_BASE_URL"
fi
if [[ -z "$UPDATE_FEED_URL" && -n "${FEED_URL:-}" ]]; then
  UPDATE_FEED_URL="$FEED_URL"
fi
MANIFEST_NOTARIZED="${MANIFEST_NOTARIZED:-false}"

PACKAGE_PREFIX_DEFAULT="$(resolve_versioned_package_prefix "$DIST_BASENAME" "$APP_PATH" || true)"
if [[ -z "$PACKAGE_PREFIX_DEFAULT" ]]; then
  PACKAGE_PREFIX_DEFAULT="$DIST_BASENAME"
fi

DMG_PATH="${DMG_PATH:-dist/${PACKAGE_PREFIX_DEFAULT}-macOS.dmg}"
ZIP_PATH="${ZIP_PATH:-dist/${PACKAGE_PREFIX_DEFAULT}-macOS.zip}"
if [[ "$DMG_PATH" != /* ]]; then
  DMG_PATH="$ROOT_DIR/$DMG_PATH"
fi
if [[ "$ZIP_PATH" != /* ]]; then
  ZIP_PATH="$ROOT_DIR/$ZIP_PATH"
fi

pass() {
  echo "[PASS] $1"
}

fail() {
  echo "[FAIL] $1"
  exit 1
}

[[ -d "$APP_PATH" ]] || fail "App bundle missing: $APP_PATH"
[[ -f "$DMG_PATH" ]] || fail "DMG missing: $DMG_PATH"
[[ -f "$ZIP_PATH" ]] || fail "ZIP missing: $ZIP_PATH"
[[ -f "$MANIFEST_PATH" ]] || fail "Release manifest missing: $MANIFEST_PATH"

codesign --verify --deep --strict "$APP_PATH" >/dev/null
pass "App bundle passes codesign verification."

if [[ "$MANIFEST_NOTARIZED" == "true" ]]; then
  xcrun stapler validate -q "$APP_PATH" >/dev/null
  pass "App bundle staple validates."

  spctl -a -t exec -vv "$APP_PATH" >/dev/null
  pass "Gatekeeper accepts app bundle."

  xcrun stapler validate -q "$DMG_PATH" >/dev/null
  pass "DMG staple validates."

  if spctl -a -t open -vv "$DMG_PATH" >/dev/null 2>&1; then
    pass "Gatekeeper accepts DMG."
  else
    DMG_ASSESS_OUTPUT="$(spctl -a -t open -vv "$DMG_PATH" 2>&1 || true)"
    if printf '%s\n' "$DMG_ASSESS_OUTPUT" | grep -q "source=Insufficient Context"; then
      MOUNT_POINT="$(mktemp -d "${TMPDIR:-/tmp}/nexhub-dmg-verify.XXXXXX")"
      if hdiutil attach "$DMG_PATH" -quiet -nobrowse -readonly -mountpoint "$MOUNT_POINT" >/dev/null 2>&1; then
        if [[ -d "$MOUNT_POINT/${APP_NAME}.app" ]] && spctl -a -t exec -vv "$MOUNT_POINT/${APP_NAME}.app" >/dev/null 2>&1; then
          hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
          rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
          pass "DMG mount contents are accepted; local open assessment had insufficient context."
        else
          hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
          rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
          fail "DMG mounted, but the bundled app did not pass Gatekeeper assessment."
        fi
      else
        rmdir "$MOUNT_POINT" >/dev/null 2>&1 || true
        fail "DMG Gatekeeper open assessment had insufficient context and the disk image could not be mounted for fallback verification."
      fi
    else
      printf '%s\n' "$DMG_ASSESS_OUTPUT"
      fail "Gatekeeper did not accept DMG."
    fi
  fi
else
  pass "Release manifest marks this build as non-notarized; skipped staple and Gatekeeper acceptance checks."
fi

"$ROOT_DIR/scripts/validate_release_manifest.sh" "$MANIFEST_PATH" >/dev/null
pass "Release manifest validates."

if [[ -n "$RELEASE_BASE_URL" ]]; then
  for name in \
    "$(basename "$DMG_PATH")" \
    "$(basename "$DMG_PATH").sha256" \
    "$(basename "$ZIP_PATH")" \
    "$(basename "$ZIP_PATH").sha256" \
    "release_manifest.json"; do
    curl -fsSI -L --max-time 20 "${RELEASE_BASE_URL%/}/$name" >/dev/null
  done

  STABLE_DMG_URL="${STABLE_DMG_URL:-${RELEASE_BASE_URL%/}/${DIST_BASENAME}-macOS.dmg}"
  STABLE_DMG_SHA256_URL="${STABLE_DMG_SHA256_URL:-${STABLE_DMG_URL}.sha256}"
  STABLE_ZIP_URL="${STABLE_ZIP_URL:-${RELEASE_BASE_URL%/}/${DIST_BASENAME}-macOS.zip}"
  STABLE_ZIP_SHA256_URL="${STABLE_ZIP_SHA256_URL:-${STABLE_ZIP_URL}.sha256}"
  MANIFEST_URL="${MANIFEST_URL:-${RELEASE_BASE_URL%/}/release_manifest.json}"

  curl -fsSI -L --max-time 20 "$STABLE_DMG_URL" >/dev/null
  curl -fsSI -L --max-time 20 "$STABLE_DMG_SHA256_URL" >/dev/null
  curl -fsSI -L --max-time 20 "$STABLE_ZIP_URL" >/dev/null
  curl -fsSI -L --max-time 20 "$STABLE_ZIP_SHA256_URL" >/dev/null
  curl -fsSI -L --max-time 20 "$MANIFEST_URL" >/dev/null
  pass "Remote release artifacts and stable download aliases are reachable."
fi

if [[ -n "$UPDATE_FEED_URL" ]]; then
  curl -fsSI -L --max-time 20 "$UPDATE_FEED_URL" >/dev/null
  pass "Remote update feed is reachable."
fi

echo "Distribution verification complete."
