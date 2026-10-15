#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_SOURCE="${1:-${REPO_DIR}/dist/Agent Workboard.app}"
OUTPUT="${2:-${REPO_DIR}/dist/AgentWorkboard-0.1.0.dmg}"
[[ -d "$APP_SOURCE" ]] || { echo 'Run scripts/build-macos.sh first.' >&2; exit 1; }
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workboard-dmg.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
ditto "$APP_SOURCE" "${STAGING_DIR}/Agent Workboard.app"
ln -s /Applications "${STAGING_DIR}/Applications"
mkdir -p "$(dirname "$OUTPUT")"
hdiutil create -volname AgentWorkboard -srcfolder "$STAGING_DIR" -format UDZO -ov "$OUTPUT"
hdiutil verify "$OUTPUT"
echo "Disk image: ${OUTPUT}"
