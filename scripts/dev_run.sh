#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

if ! command -v swift >/dev/null 2>&1; then
  echo "swift toolchain is required"
  exit 1
fi

if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  echo "Xcode license is not accepted yet."
  echo "Run: sudo xcodebuild -license"
  exit 69
fi

export NEXHUB_RUNTIME_LOG_PATH="${NEXHUB_RUNTIME_LOG_PATH:-$HOME/Library/Application Support/${NEXHUB_PRODUCT_NAME}/Logs/runtime.log}"

echo "Starting ${NEXHUB_PRODUCT_NAME} app..."

swift run
