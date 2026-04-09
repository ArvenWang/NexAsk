#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required"
  exit 1
fi

python3 "$ROOT_DIR/scripts/sync_localization_resources.py" --check

TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

rg -n \
  -g '*.swift' \
  -e 'labelWithString:\s*"[^"]+"' \
  -e 'wrappingLabelWithString:\s*"[^"]+"' \
  -e 'NSButton\(title:\s*"[^"]+"' \
  -e 'checkboxWithTitle:\s*"[^"]+"' \
  -e 'messageText\s*=\s*"[^"]+"' \
  -e 'informativeText\s*=\s*"[^"]+"' \
  -e 'setTitle\(".*"' \
  Sources \
  | rg -v '""|\\\(|labelWithString:\s*"×"|labelWithString:\s*"px"|title:\s*"AI"|title:\s*"Notion"|labelWithString:\s*"AI"|labelWithString:\s*"Notion"|wrappingLabelWithString:\s*"AI"|wrappingLabelWithString:\s*"Notion"' \
  > "$TMP_FILE" || true

if [[ -s "$TMP_FILE" ]]; then
  echo "Localization check failed. These UI strings bypass the shared localization layer:"
  cat "$TMP_FILE"
  exit 1
fi

echo "Localization check passed."
