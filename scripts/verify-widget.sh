#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERIFY_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workboard-widget.XXXXXX")"
trap 'rm -rf "$VERIFY_DIR"' EXIT
cd "$REPO_DIR"
xcrun swiftc -typecheck -parse-as-library -application-extension -module-name WorkboardWidgets \
    -target "$(uname -m)-apple-macos14.0" macos/WidgetExtension/WidgetSnapshot.swift \
    macos/WidgetExtension/WorkboardWidgets.swift
xcrun swiftc -typecheck -parse-as-library -application-extension -D WORKBOARD_STATIC_WIDGETS -module-name WorkboardWidgets \
    -target "$(uname -m)-apple-macos14.0" macos/WidgetExtension/WidgetSnapshot.swift \
    macos/WidgetExtension/WorkboardWidgets.swift
xcrun swiftc -parse-as-library macos/WidgetExtension/WidgetSnapshot.swift scripts/WidgetSnapshotProbe.swift \
    -o "${VERIFY_DIR}/widget-snapshot-probe"
"${VERIFY_DIR}/widget-snapshot-probe" "$@"
plutil -lint macos/Resources/App-Info.plist macos/Resources/Widget-Info.plist \
    macos/Resources/App.entitlements macos/Resources/Widget.entitlements macos/Resources/Service.entitlements
echo 'WidgetKit compilation passed. Gallery registration and desktop behavior require separate verification.'
