#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/app_config.sh"
load_app_config

DIST_DIR="$ROOT_DIR/dist"
MANIFEST_PATH="$DIST_DIR/release_manifest.json"
SHARE_ROOT="$DIST_DIR/share"
APP_NAME="$NEXHUB_PRODUCT_NAME"

if [[ ! -f "$MANIFEST_PATH" ]]; then
  echo "Missing release manifest: $MANIFEST_PATH"
  echo "Run ./scripts/release.sh first."
  exit 1
fi

eval "$(
python3 - "$MANIFEST_PATH" <<'PY'
import json
import pathlib
import shlex
import sys

manifest = json.loads(pathlib.Path(sys.argv[1]).read_text())
distribution = manifest.get("distribution", {})
updates = manifest.get("updates", {})

fields = {
    "VERSION": manifest.get("version", "unknown"),
    "BUILD": manifest.get("build", "unknown"),
    "GIT_SHA": manifest.get("git_sha", "unknown"),
    "DMG_REL": manifest["artifacts"]["dmg"],
    "DMG_SHA_REL": manifest["artifacts"]["dmg_sha256"],
    "ZIP_REL": manifest["artifacts"]["zip"],
    "ZIP_SHA_REL": manifest["artifacts"]["zip_sha256"],
    "RELEASE_BASE_URL": distribution.get("release_base_url", ""),
    "DMG_URL": distribution.get("dmg_url", ""),
    "ZIP_URL": distribution.get("zip_url", ""),
    "STABLE_DMG_URL": distribution.get("stable_dmg_url", ""),
    "STABLE_ZIP_URL": distribution.get("stable_zip_url", ""),
    "MANIFEST_URL": distribution.get("manifest_url", ""),
    "FEED_URL": updates.get("feed_url", ""),
}

for key, value in fields.items():
    print(f"{key}={shlex.quote(value)}")
PY
)"

SAFE_VERSION="${VERSION//[^0-9A-Za-z._-]/-}"
SAFE_BUILD="${BUILD//[^0-9A-Za-z._-]/-}"
TAG="${NEXHUB_DIST_BASENAME}-${SAFE_VERSION}-${SAFE_BUILD}"
TARGET_DIR="$SHARE_ROOT/$TAG"

rm -rf "$TARGET_DIR"
mkdir -p "$TARGET_DIR"

cp "$ROOT_DIR/$DMG_REL" "$TARGET_DIR/"
cp "$ROOT_DIR/$DMG_SHA_REL" "$TARGET_DIR/"
cp "$ROOT_DIR/$ZIP_REL" "$TARGET_DIR/"
cp "$ROOT_DIR/$ZIP_SHA_REL" "$TARGET_DIR/"
cp "$MANIFEST_PATH" "$TARGET_DIR/"

if [[ -f "$DIST_DIR/update_feed/appcast.xml" ]]; then
  cp "$DIST_DIR/update_feed/appcast.xml" "$TARGET_DIR/"
fi

cat > "$TARGET_DIR/README.txt" <<EOF
${APP_NAME} formal share package

Version: $VERSION ($BUILD)
Git SHA: $GIT_SHA

Local artifacts in this directory:
- $(basename "$ROOT_DIR/$DMG_REL")
- $(basename "$ROOT_DIR/$DMG_SHA_REL")
- $(basename "$ROOT_DIR/$ZIP_REL")
- $(basename "$ROOT_DIR/$ZIP_SHA_REL")
- $(basename "$MANIFEST_PATH")

Install recommendation:
1. Open the DMG.
2. Drag ${APP_NAME}.app into /Applications.
3. Launch /Applications/${APP_NAME}.app.
4. Grant Accessibility permission on first launch if prompted.

Remote auto-update:
- Feed URL: ${FEED_URL:-not embedded}

Remote release URLs:
- Release base: ${RELEASE_BASE_URL:-not published}
- DMG: ${DMG_URL:-not published}
- ZIP: ${ZIP_URL:-not published}
- Stable DMG alias: ${STABLE_DMG_URL:-not published}
- Stable ZIP alias: ${STABLE_ZIP_URL:-not published}
- Manifest: ${MANIFEST_URL:-not published}
EOF

mkdir -p "$SHARE_ROOT"
ln -sfn "$TAG" "$SHARE_ROOT/latest"

echo "Prepared share directory:"
echo "  $TARGET_DIR"
echo "Latest alias:"
echo "  $SHARE_ROOT/latest"
