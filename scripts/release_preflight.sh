#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

VERSION_FILE="$ROOT_DIR/VERSION"
APP_NAME="$NEXHUB_PRODUCT_NAME"
BUNDLE_ID="$NEXHUB_BUNDLE_ID"
APP_PATH="$ROOT_DIR/dist/${APP_NAME}.app"
ICON_PATH="${NEXHUB_APP_ICON:-$ROOT_DIR/Resources/AppIcon.icns}"
NOTARY_PROFILE="${NEXHUB_NOTARY_PROFILE:-}"
SKIP_CHECKS="${NEXHUB_SKIP_CHECKS:-0}"
ALLOW_DIRTY="${NEXHUB_ALLOW_DIRTY:-0}"
RELEASE_MODE="${NEXHUB_RELEASE_MODE:-candidate}"
MANIFEST_PATH="$ROOT_DIR/dist/release_manifest.json"
UPDATE_FEED_URL="${NEXHUB_UPDATE_FEED_URL:-}"
RELEASE_BASE_URL="${NEXHUB_RELEASE_BASE_URL:-}"
SPARKLE_PUBLIC_KEY="${NEXHUB_SPARKLE_PUBLIC_KEY:-}"
SPARKLE_PUBLIC_KEY_FILE="${NEXHUB_SPARKLE_PUBLIC_KEY_FILE:-}"
SPARKLE_KEY_ACCOUNT="${NEXHUB_SPARKLE_KEY_ACCOUNT:-}"
SPARKLE_TOOLS_DIR="$ROOT_DIR/Vendor/Sparkle/bin"
SPARKLE_FRAMEWORK_PATH="$ROOT_DIR/Vendor/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
AUTO_PUBLISH_UPDATES="${NEXHUB_PUBLISH_UPDATES:-0}"
AUTO_PUBLISH_RELEASE="${NEXHUB_PUBLISH_RELEASE:-0}"

cd "$ROOT_DIR"

warn() {
  echo "[WARN] $1"
}

pass() {
  echo "[PASS] $1"
}

fail() {
  echo "[FAIL] $1"
  exit 1
}

require_valid_release_mode() {
  case "$RELEASE_MODE" in
    candidate|formal) ;;
    *)
      fail "Unsupported NEXHUB_RELEASE_MODE: $RELEASE_MODE (use candidate or formal)."
      ;;
  esac
}

require_valid_release_mode

if [[ "$RELEASE_MODE" == "formal" ]]; then
  if [[ -n "${NEXHUB_UPDATE_PUBLISH_HOST:-}" && -n "${NEXHUB_UPDATE_PUBLISH_TARGET_DIR:-}" ]]; then
    AUTO_PUBLISH_UPDATES="1"
  fi
  if [[ -n "${NEXHUB_RELEASE_PUBLISH_HOST:-}" && -n "${NEXHUB_RELEASE_PUBLISH_TARGET_DIR:-}" ]]; then
    AUTO_PUBLISH_RELEASE="1"
  fi
fi

if resolve_sparkle_public_key "$SPARKLE_PUBLIC_KEY" "$SPARKLE_PUBLIC_KEY_FILE" "$SPARKLE_KEY_ACCOUNT" "$SPARKLE_TOOLS_DIR/generate_keys"; then
  SPARKLE_PUBLIC_KEY="$RESOLVED_SPARKLE_PUBLIC_KEY"
else
  SPARKLE_PUBLIC_KEY=""
fi

if [[ "$RELEASE_MODE" == "formal" ]]; then
  if [[ "$ALLOW_DIRTY" == "1" ]]; then
    fail "Formal release mode does not allow NEXHUB_ALLOW_DIRTY=1."
  fi
  if [[ "$SKIP_CHECKS" == "1" ]]; then
    fail "Formal release mode does not allow NEXHUB_SKIP_CHECKS=1."
  fi
fi

if [[ -n "$(git status --porcelain)" ]]; then
  if [[ "$RELEASE_MODE" == "formal" ]]; then
    fail "Formal release mode requires a clean working tree."
  elif [[ "$ALLOW_DIRTY" == "1" ]]; then
    warn "Working tree is not clean, but continuing because NEXHUB_ALLOW_DIRTY=1."
  else
    fail "Working tree is not clean."
  fi
else
  pass "Working tree is clean."
fi

if [[ -f "$VERSION_FILE" ]] && [[ -n "$(tr -d '[:space:]' < "$VERSION_FILE")" ]]; then
  pass "VERSION file present: $(tr -d '[:space:]' < "$VERSION_FILE")"
else
  fail "VERSION file is missing or empty."
fi

if [[ "$SKIP_CHECKS" != "1" ]]; then
  if "$ROOT_DIR/scripts/checks.sh" >/dev/null; then
    pass "Project checks passed."
  else
    fail "Project checks failed. Run ./scripts/checks.sh locally."
  fi
else
  warn "Project checks were skipped because NEXHUB_SKIP_CHECKS=1."
fi

if security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application:"; then
  pass "Developer ID Application certificate found."
else
  if [[ "$RELEASE_MODE" == "formal" ]]; then
    fail "Developer ID Application certificate not found."
  else
    warn "Developer ID Application certificate not found. Release build will fall back or fail notarization."
  fi
fi

if [[ -f "$ICON_PATH" ]]; then
  pass "App icon found: $ICON_PATH"
else
  warn "App icon missing at $ICON_PATH. Finder/DMG branding will look unfinished."
fi

if [[ -d "$SPARKLE_FRAMEWORK_PATH" ]]; then
  pass "Sparkle framework vendored."
else
  fail "Sparkle framework missing at $SPARKLE_FRAMEWORK_PATH"
fi

if [[ -n "$UPDATE_FEED_URL" ]]; then
  pass "Auto-update feed URL configured: $UPDATE_FEED_URL"
  if [[ -n "$SPARKLE_PUBLIC_KEY" ]]; then
    pass "Sparkle public key is available for build-time embedding."
  else
    fail "Auto-update feed URL is set, but Sparkle public key could not be resolved."
  fi
else
  warn "NEXHUB_UPDATE_FEED_URL is not set. In-app remote auto-updates will stay disabled."
fi

if [[ -n "$RELEASE_BASE_URL" ]]; then
  pass "Release base URL configured: $RELEASE_BASE_URL"
else
  warn "NEXHUB_RELEASE_BASE_URL is not set. Formal release can still build locally, but remote share artifact URLs will not be recorded."
fi

if [[ "$AUTO_PUBLISH_UPDATES" == "1" ]]; then
  if [[ -n "${NEXHUB_UPDATE_PUBLISH_HOST:-}" && -n "${NEXHUB_UPDATE_PUBLISH_TARGET_DIR:-}" ]]; then
    pass "Update-feed publish target is configured."
  else
    fail "NEXHUB_PUBLISH_UPDATES=1 requires NEXHUB_UPDATE_PUBLISH_HOST and NEXHUB_UPDATE_PUBLISH_TARGET_DIR."
  fi
fi

if [[ "$AUTO_PUBLISH_RELEASE" == "1" ]]; then
  if [[ -n "${NEXHUB_RELEASE_PUBLISH_HOST:-}" && -n "${NEXHUB_RELEASE_PUBLISH_TARGET_DIR:-}" ]]; then
    pass "Release-artifact publish target is configured."
  else
    fail "NEXHUB_PUBLISH_RELEASE=1 requires NEXHUB_RELEASE_PUBLISH_HOST and NEXHUB_RELEASE_PUBLISH_TARGET_DIR."
  fi
  if [[ -z "$RELEASE_BASE_URL" ]]; then
    fail "NEXHUB_PUBLISH_RELEASE=1 requires NEXHUB_RELEASE_BASE_URL for remote verification."
  fi
fi

if [[ -n "$NOTARY_PROFILE" ]]; then
  if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
    pass "Notary profile works: $NOTARY_PROFILE"
  else
    if [[ "$RELEASE_MODE" == "formal" ]]; then
      fail "Notary profile is set but could not be verified: $NOTARY_PROFILE"
    else
      warn "Notary profile is set but could not be verified: $NOTARY_PROFILE"
    fi
  fi
else
  if [[ "$RELEASE_MODE" == "formal" ]]; then
    fail "Formal release mode requires NEXHUB_NOTARY_PROFILE."
  else
    warn "NEXHUB_NOTARY_PROFILE is not set. Public distribution will not be notarized."
  fi
fi

if [[ -d "$APP_PATH" ]]; then
  if [[ -f "$APP_PATH/Contents/Resources/local_gateway.py" || -d "$APP_PATH/Contents/Resources/PythonRuntime" ]]; then
    fail "Packaged app still contains legacy Python gateway resources."
  else
    pass "Packaged app no longer bundles legacy Python gateway resources."
  fi

  if [[ -d "$APP_PATH/Contents/Frameworks/Sparkle.framework" ]]; then
    pass "Packaged app contains Sparkle framework."
  else
    fail "Packaged app is missing Sparkle framework."
  fi

  if [[ -d "$APP_PATH/Contents/Resources/BuiltinSkills" ]]; then
    pass "Packaged app contains BuiltinSkills."
  else
    fail "Packaged app is missing BuiltinSkills."
  fi

  if /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist" >/dev/null 2>&1; then
    ACTUAL_BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_PATH/Contents/Info.plist")"
    if [[ "$ACTUAL_BUNDLE_ID" == "$BUNDLE_ID" ]]; then
      pass "Packaged app bundle id matches expected value."
    else
      warn "Packaged app bundle id ($ACTUAL_BUNDLE_ID) does not match expected value ($BUNDLE_ID)."
    fi
  fi

  if [[ -n "$UPDATE_FEED_URL" ]]; then
    ACTUAL_FEED_URL="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP_PATH/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$ACTUAL_FEED_URL" == "$UPDATE_FEED_URL" ]]; then
      pass "Packaged app embeds the expected Sparkle feed URL."
    else
      fail "Packaged app feed URL mismatch: expected $UPDATE_FEED_URL, got ${ACTUAL_FEED_URL:-missing}"
    fi
  fi

  if codesign --verify --deep --strict "$APP_PATH" >/dev/null 2>&1; then
    pass "Packaged app passes codesign verification."
  else
    fail "Packaged app failed codesign verification."
  fi
else
  if [[ "$RELEASE_MODE" == "formal" ]]; then
    warn "Packaged app not found at $APP_PATH yet. Formal release artifacts will be validated during ./scripts/release.sh."
  else
    warn "Packaged app not found at $APP_PATH. Run ./scripts/build_app.sh or ./scripts/release.sh first."
  fi
fi

if [[ -f "$MANIFEST_PATH" ]]; then
  if "$ROOT_DIR/scripts/validate_release_manifest.sh" "$MANIFEST_PATH" >/dev/null; then
    pass "Release manifest is valid."
  else
    fail "Release manifest validation failed."
  fi
else
  if [[ "$RELEASE_MODE" == "formal" ]]; then
    warn "Release manifest not present yet. It will be validated during formal release packaging."
  else
    warn "Release manifest not found yet."
  fi
fi

echo "Preflight completed."
