#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workboard-widget-preview.XXXXXX")"
trap 'rm -rf "$PREVIEW_DIR"' EXIT
cd "$REPO_DIR"
xcrun swiftc -parse-as-library -D WORKBOARD_WIDGET_PREVIEW -module-name WorkboardWidgetPreview \
    macos/WidgetExtension/WidgetSnapshot.swift macos/WidgetExtension/WorkboardWidgets.swift \
    scripts/render-widget-previews.swift -o "${PREVIEW_DIR}/render-widget-previews"
"${PREVIEW_DIR}/render-widget-previews" "${1:-${REPO_DIR}/.build/widget-previews}"
