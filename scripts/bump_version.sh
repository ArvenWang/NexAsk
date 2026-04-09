#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION_FILE="$ROOT_DIR/VERSION"
TARGET="${1:-patch}"

usage() {
  cat <<'EOF'
Usage:
  ./scripts/bump_version.sh
  ./scripts/bump_version.sh patch
  ./scripts/bump_version.sh minor
  ./scripts/bump_version.sh major
  ./scripts/bump_version.sh <version>

Examples:
  ./scripts/bump_version.sh          # 0.2.1 -> 0.2.2
  ./scripts/bump_version.sh minor    # 0.2.1 -> 0.3.0
  ./scripts/bump_version.sh 1.0.0    # set exact version
EOF
}

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "VERSION file not found: $VERSION_FILE"
  exit 1
fi

CURRENT_VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
if [[ ! "$CURRENT_VERSION" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  echo "Unsupported VERSION format: $CURRENT_VERSION"
  echo "Expected semantic version like 0.2.1"
  exit 1
fi

MAJOR="${BASH_REMATCH[1]}"
MINOR="${BASH_REMATCH[2]}"
PATCH="${BASH_REMATCH[3]}"

case "$TARGET" in
  patch)
    NEXT_VERSION="${MAJOR}.${MINOR}.$((PATCH + 1))"
    ;;
  minor)
    NEXT_VERSION="${MAJOR}.$((MINOR + 1)).0"
    ;;
  major)
    NEXT_VERSION="$((MAJOR + 1)).0.0"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    if [[ "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      NEXT_VERSION="$TARGET"
    else
      echo "Unsupported bump target: $TARGET"
      usage
      exit 1
    fi
    ;;
esac

if [[ "$NEXT_VERSION" == "$CURRENT_VERSION" ]]; then
  echo "VERSION already set to $CURRENT_VERSION"
  exit 0
fi

printf '%s\n' "$NEXT_VERSION" > "$VERSION_FILE"

echo "Updated VERSION: $CURRENT_VERSION -> $NEXT_VERSION"
echo "Next steps:"
echo "1. Update CHANGELOG.md"
echo "2. Commit the version bump"
echo "3. Run ./scripts/release_one_click.sh"
