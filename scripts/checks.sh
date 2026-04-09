#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

cleanup() {
  ./scripts/cleanup_test_residue.sh >/dev/null 2>&1 || true
}

trap cleanup EXIT

./scripts/check_localization.sh
swift test
