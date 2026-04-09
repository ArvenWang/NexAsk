#!/usr/bin/env bash
set -euo pipefail

# Clear lingering NexHub SwiftPM test bundles and refresh Dock so stale xctest icons disappear.
pkill -f 'NexHubPackageTests\.xctest' >/dev/null 2>&1 || true
pkill -f '/\.build/.*/xctest' >/dev/null 2>&1 || true
sleep 0.5
killall Dock >/dev/null 2>&1 || true
