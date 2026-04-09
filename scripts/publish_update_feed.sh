#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

UPDATE_FEED_DIR="${NEXHUB_UPDATE_FEED_DIR:-$ROOT_DIR/dist/update_feed}"
REMOTE_HOST="${NEXHUB_UPDATE_PUBLISH_HOST:-}"
REMOTE_USER="${NEXHUB_UPDATE_PUBLISH_USER:-root}"
REMOTE_DIR="${NEXHUB_UPDATE_PUBLISH_TARGET_DIR:-}"
SSH_KEY_FILE="${NEXHUB_UPDATE_PUBLISH_SSH_KEY_FILE:-}"
SSH_PORT="${NEXHUB_UPDATE_PUBLISH_SSH_PORT:-22}"
VERIFY_URL="${NEXHUB_UPDATE_FEED_URL:-}"
STRICT_HOST_KEY_CHECKING="${NEXHUB_UPDATE_PUBLISH_STRICT_HOST_KEY_CHECKING:-no}"
TEMP_KEY_FILE=""

cleanup() {
  if [[ -n "$TEMP_KEY_FILE" && -f "$TEMP_KEY_FILE" ]]; then
    rm -f "$TEMP_KEY_FILE"
  fi
}

trap cleanup EXIT

if [[ ! -d "$UPDATE_FEED_DIR" ]]; then
  echo "Update feed directory not found: $UPDATE_FEED_DIR"
  echo "Run ./scripts/generate_appcast.sh first."
  exit 1
fi

if [[ -z "$REMOTE_HOST" || -z "$REMOTE_DIR" ]]; then
  echo "NEXHUB_UPDATE_PUBLISH_HOST and NEXHUB_UPDATE_PUBLISH_TARGET_DIR are required."
  exit 1
fi

SSH_ARGS=(-p "$SSH_PORT" -o "StrictHostKeyChecking=$STRICT_HOST_KEY_CHECKING")

if [[ -n "$SSH_KEY_FILE" ]]; then
  if [[ ! -f "$SSH_KEY_FILE" ]]; then
    echo "SSH key file not found: $SSH_KEY_FILE"
    exit 1
  fi
  TEMP_KEY_FILE="$(mktemp /tmp/nexhub-update-key.XXXXXX)"
  cp "$SSH_KEY_FILE" "$TEMP_KEY_FILE"
  chmod 600 "$TEMP_KEY_FILE"
  SSH_ARGS+=(-i "$TEMP_KEY_FILE")
fi

REMOTE_TARGET="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_DIR%/}/"

ssh "${SSH_ARGS[@]}" "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '${REMOTE_DIR%/}'"

rsync -avz --delete \
  -e "ssh ${SSH_ARGS[*]}" \
  "$UPDATE_FEED_DIR/" \
  "$REMOTE_TARGET"

if [[ -n "$VERIFY_URL" ]]; then
  curl -fI -L --max-time 15 "$VERIFY_URL" >/dev/null
  echo "Verified remote feed: $VERIFY_URL"
fi

echo "Published update feed to $REMOTE_TARGET"
