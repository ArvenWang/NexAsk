#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

APP_NAME="$NEXHUB_PRODUCT_NAME"
NOTARY_PROFILE_HINT="$NEXHUB_NOTARY_PROFILE_HINT"
DIST_BASENAME="$NEXHUB_DIST_BASENAME"
ARTIFACT_PATH="${1:-$ROOT_DIR/dist/${APP_NAME}.app}"
PROFILE="${NEXHUB_NOTARY_PROFILE:-}"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/nexhub-notary.XXXXXX")"
LOG_DIR="$ROOT_DIR/dist/notary"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
STAPLE_RETRIES="${NEXHUB_STAPLER_RETRIES:-5}"
STAPLE_RETRY_DELAY="${NEXHUB_STAPLER_RETRY_DELAY:-15}"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

if [[ -z "$PROFILE" ]]; then
  echo "NEXHUB_NOTARY_PROFILE is required."
  echo "Create it once with:"
  echo "  xcrun notarytool store-credentials $NOTARY_PROFILE_HINT"
  echo "Then run with:"
  echo "  NEXHUB_NOTARY_PROFILE=$NOTARY_PROFILE_HINT ./scripts/notarize_app.sh"
  exit 1
fi

if [[ ! -e "$ARTIFACT_PATH" ]]; then
  echo "Artifact not found: $ARTIFACT_PATH"
  exit 1
fi

ARTIFACT_NAME="$(basename "$ARTIFACT_PATH")"
ARTIFACT_EXTENSION="${ARTIFACT_NAME##*.}"
UPLOAD_PATH="$ARTIFACT_PATH"
STAPLE_TARGET="$ARTIFACT_PATH"
CAN_STAPLE="0"

case "$ARTIFACT_EXTENSION" in
  app)
    SIGNING_INFO="$(codesign -dv --verbose=2 "$ARTIFACT_PATH" 2>&1 || true)"
    if ! printf '%s\n' "$SIGNING_INFO" | grep -q "Authority=Developer ID Application:"; then
      echo "The app must be signed with a Developer ID Application certificate before notarization."
      echo "Current signing info:"
      printf '%s\n' "$SIGNING_INFO"
      exit 1
    fi
    ZIP_PATH="$TMP_DIR/${DIST_BASENAME}-notary.zip"
    echo "Creating notarization zip ..."
    ditto -c -k --sequesterRsrc --keepParent "$ARTIFACT_PATH" "$ZIP_PATH"
    UPLOAD_PATH="$ZIP_PATH"
    STAPLE_TARGET="$ARTIFACT_PATH"
    CAN_STAPLE="1"
    ;;
  dmg|pkg)
    UPLOAD_PATH="$ARTIFACT_PATH"
    STAPLE_TARGET="$ARTIFACT_PATH"
    CAN_STAPLE="1"
    ;;
  zip)
    UPLOAD_PATH="$ARTIFACT_PATH"
    STAPLE_TARGET=""
    CAN_STAPLE="0"
    ;;
  *)
    echo "Unsupported artifact for notarization: $ARTIFACT_PATH"
    echo "Supported: .app, .dmg, .pkg, .zip"
    exit 1
    ;;
esac

mkdir -p "$LOG_DIR"

echo "Submitting to Apple notary service with profile: $PROFILE"
SUBMIT_OUTPUT="$(xcrun notarytool submit "$UPLOAD_PATH" --keychain-profile "$PROFILE" --wait 2>&1)"
printf '%s\n' "$SUBMIT_OUTPUT"

SUBMISSION_ID="$(
  printf '%s\n' "$SUBMIT_OUTPUT" \
    | awk -F': ' '/^id:/ { print $2; exit }'
)"
SUBMISSION_STATUS="$(
  printf '%s\n' "$SUBMIT_OUTPUT" \
    | awk -F': ' '/^  status:/ { print $2; exit }'
)"

if [[ -n "$SUBMISSION_ID" ]]; then
  LOG_PATH="$LOG_DIR/notary-log-$TIMESTAMP.json"
  if xcrun notarytool log "$SUBMISSION_ID" --keychain-profile "$PROFILE" >"$LOG_PATH"; then
    echo "Saved notarization log: $LOG_PATH"
  else
    rm -f "$LOG_PATH"
  fi
fi

if [[ "$SUBMISSION_STATUS" != "Accepted" ]]; then
  if [[ -n "${LOG_PATH:-}" && -f "${LOG_PATH:-}" ]]; then
    echo "Notarization failed with status: ${SUBMISSION_STATUS:-unknown}"
    cat "$LOG_PATH"
  else
    echo "Notarization failed with status: ${SUBMISSION_STATUS:-unknown}"
  fi
  exit 1
fi

if [[ "$CAN_STAPLE" == "1" && -n "$STAPLE_TARGET" ]]; then
  echo "Stapling ticket to artifact ..."
  attempt=1
  while true; do
    if xcrun stapler staple -v "$STAPLE_TARGET"; then
      break
    fi

    if [[ "$attempt" -ge "$STAPLE_RETRIES" ]]; then
      echo "Stapler failed after $attempt attempt(s)."
      exit 1
    fi

    echo "Stapler attempt $attempt failed; retrying in ${STAPLE_RETRY_DELAY}s..."
    sleep "$STAPLE_RETRY_DELAY"
    attempt=$((attempt + 1))
  done
  xcrun stapler validate -v "$STAPLE_TARGET"
else
  echo "Stapling skipped for $ARTIFACT_NAME"
fi

echo "Notarized: $ARTIFACT_PATH"
