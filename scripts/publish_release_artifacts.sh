#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

DIST_DIR="$ROOT_DIR/dist"
DIST_BASENAME="$NEXHUB_DIST_BASENAME"
MANIFEST_PATH="$DIST_DIR/release_manifest.json"
REMOTE_HOST="${NEXHUB_RELEASE_PUBLISH_HOST:-}"
REMOTE_USER="${NEXHUB_RELEASE_PUBLISH_USER:-${NEXHUB_UPDATE_PUBLISH_USER:-root}}"
REMOTE_DIR="${NEXHUB_RELEASE_PUBLISH_TARGET_DIR:-}"
SSH_KEY_FILE="${NEXHUB_RELEASE_PUBLISH_SSH_KEY_FILE:-${NEXHUB_UPDATE_PUBLISH_SSH_KEY_FILE:-}}"
SSH_PORT="${NEXHUB_RELEASE_PUBLISH_SSH_PORT:-${NEXHUB_UPDATE_PUBLISH_SSH_PORT:-22}}"
STRICT_HOST_KEY_CHECKING="${NEXHUB_RELEASE_PUBLISH_STRICT_HOST_KEY_CHECKING:-${NEXHUB_UPDATE_PUBLISH_STRICT_HOST_KEY_CHECKING:-no}}"
RELEASE_BASE_URL="${NEXHUB_RELEASE_BASE_URL:-}"
TEMP_KEY_FILE=""

cleanup() {
  if [[ -n "$TEMP_KEY_FILE" && -f "$TEMP_KEY_FILE" ]]; then
    rm -f "$TEMP_KEY_FILE"
  fi
}

trap cleanup EXIT

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "Release manifest missing: $MANIFEST_PATH"
  echo "Run ./scripts/release.sh first."
  exit 1
fi

while IFS='=' read -r key value; do
  case "$key" in
    DMG) DMG="$value" ;;
    DMG_SHA256) DMG_SHA256="$value" ;;
    ZIP) ZIP="$value" ;;
    ZIP_SHA256) ZIP_SHA256="$value" ;;
  esac
done < <(
python3 - "$MANIFEST_PATH" <<'PY'
import json
import pathlib
import shlex
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
artifacts = manifest.get("artifacts", {})

for key in ["dmg", "dmg_sha256", "zip", "zip_sha256"]:
    print(f"{key.upper()}={shlex.quote(artifacts.get(key, ''))}")
PY
)

REQUIRED_FILES=(
  "$ROOT_DIR/$DMG"
  "$ROOT_DIR/$DMG_SHA256"
  "$ROOT_DIR/$ZIP"
  "$ROOT_DIR/$ZIP_SHA256"
  "$MANIFEST_PATH"
)

STABLE_DMG_NAME="${DIST_BASENAME}-macOS.dmg"
STABLE_DMG_SHA256_NAME="${STABLE_DMG_NAME}.sha256"
STABLE_ZIP_NAME="${DIST_BASENAME}-macOS.zip"
STABLE_ZIP_SHA256_NAME="${STABLE_ZIP_NAME}.sha256"

for path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "Release artifact missing: $path"
    echo "Run ./scripts/release.sh first."
    exit 1
  fi
done

if [[ -z "$REMOTE_HOST" || -z "$REMOTE_DIR" ]]; then
  echo "NEXHUB_RELEASE_PUBLISH_HOST and NEXHUB_RELEASE_PUBLISH_TARGET_DIR are required."
  exit 1
fi

if [[ -z "$RELEASE_BASE_URL" ]]; then
  echo "NEXHUB_RELEASE_BASE_URL is required so published artifacts can be verified."
  exit 1
fi

SSH_ARGS=(-p "$SSH_PORT" -o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING")

if [[ -n "$SSH_KEY_FILE" ]]; then
  if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "SSH key file not found: $SSH_KEY_FILE"
    exit 1
  fi
  TEMP_KEY_FILE="$(mktemp /tmp/nexhub-release-key.XXXXXX)"
  cp "$SSH_KEY_FILE" "$TEMP_KEY_FILE"
  chmod 600 "$TEMP_KEY_FILE"
  SSH_ARGS+=(-i "$TEMP_KEY_FILE")
fi

REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR%/}/"

ssh "${SSH_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR%/}'"

rsync -avz \
  -e "ssh ${SSH_ARGS[*]}" \
  "${REQUIRED_FILES[@]}" \
  "$REMOTE_TARGET"

ssh "${SSH_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" \
  "cd '${REMOTE_DIR%/}' && \
   cp -f '$(basename "$DMG")' '$STABLE_DMG_NAME' && \
   cp -f '$(basename "$DMG_SHA256")' '$STABLE_DMG_SHA256_NAME' && \
   cp -f '$(basename "$ZIP")' '$STABLE_ZIP_NAME' && \
   cp -f '$(basename "$ZIP_SHA256")' '$STABLE_ZIP_SHA256_NAME'"

for name in \
  "$(basename "$DMG")" \
  "$(basename "$DMG_SHA256")" \
  "$(basename "$ZIP")" \
  "$(basename "$ZIP_SHA256")" \
  "$STABLE_DMG_NAME" \
  "$STABLE_DMG_SHA256_NAME" \
  "$STABLE_ZIP_NAME" \
  "$STABLE_ZIP_SHA256_NAME" \
  "release_manifest.json"; do
  curl -fsSI -L --max-time 20 "${RELEASE_BASE_URL%/}/$name" >/dev/null
  echo "Verified remote artifact: ${RELEASE_BASE_URL%/}/$name"
done

echo "Published release artifacts to $REMOTE_TARGET"
