#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

DIST_DIR="$ROOT_DIR/dist"
APP_NAME="$NEXHUB_PRODUCT_NAME"
DIST_BASENAME="$NEXHUB_DIST_BASENAME"
MANIFEST_PATH="${1:-$DIST_DIR/release_manifest.json}"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "Release manifest not found: $MANIFEST_PATH"
  exit 1
fi

python3 - "$MANIFEST_PATH" "$APP_NAME" "$DIST_BASENAME" <<'PY'
import json
import sys
from pathlib import Path

manifest_path = Path(sys.argv[1])
app_name = sys.argv[2]
dist_basename = sys.argv[3]
root = manifest_path.parent.parent

with manifest_path.open("r", encoding="utf-8") as handle:
    manifest = json.load(handle)

required_top = ["app", "version", "build", "git_sha", "build_time_utc", "notarized", "artifacts"]
for key in required_top:
    if key not in manifest:
        raise SystemExit(f"Manifest missing key: {key}")

if manifest["app"] != app_name:
    raise SystemExit(f"Manifest app mismatch: expected {app_name}, got {manifest['app']}")

artifacts = manifest["artifacts"]
required_artifacts = ["app", "dmg", "dmg_sha256", "zip", "zip_sha256"]

for key in required_artifacts:
    actual = artifacts.get(key)
    if not isinstance(actual, str) or not actual.startswith("dist/"):
        raise SystemExit(f"Manifest artifact path is invalid for {key}: {actual}")
    if key == "app" and actual != f"dist/{app_name}.app":
        raise SystemExit(f"Manifest artifact mismatch for {key}: expected dist/{app_name}.app, got {actual}")
    if key in {"dmg", "dmg_sha256", "zip", "zip_sha256"} and dist_basename not in actual:
        raise SystemExit(f"Manifest artifact path does not include dist basename for {key}: {actual}")
    artifact_path = root / actual
    if not artifact_path.exists():
        raise SystemExit(f"Artifact missing on disk: {artifact_path}")

distribution = manifest.get("distribution")
if distribution is not None:
    for key in ["release_base_url", "updates_published", "release_published"]:
        if key not in distribution:
            raise SystemExit(f"Manifest distribution block missing key: {key}")

    release_base_url = distribution["release_base_url"]
    if release_base_url:
        for key in ["dmg_url", "zip_url", "manifest_url"]:
            value = distribution.get(key)
            if not isinstance(value, str) or not value.startswith(release_base_url.rstrip("/") + "/"):
                raise SystemExit(f"Manifest distribution URL mismatch for {key}: {value}")

notarization = manifest.get("notarization")
if manifest["notarized"]:
    if notarization is None:
        raise SystemExit("Manifest marked notarized but notarization block is missing.")
    for key in ["profile", "app_stapled", "dmg_stapled"]:
        if key not in notarization:
            raise SystemExit(f"Manifest notarization block missing key: {key}")

print(f"Validated release manifest: {manifest_path}")
PY
