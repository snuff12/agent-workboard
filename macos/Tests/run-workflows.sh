#!/bin/bash
set -euo pipefail
macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$macos_dir/.build"
sources=()
for source in "$macos_dir"/Sources/WorkboardApp/*.swift; do
  if [[ "$(basename "$source")" != "WorkboardApp.swift" ]]; then sources+=("$source"); fi
done
swiftc -swift-version 6 -parse-as-library "${sources[@]}" "$macos_dir/Tests/WorkflowRegression.swift" -o "$macos_dir/.build/workflow-regression"
env -u WORKBOARD_SOCKET -u WORKBOARD_DATA_DIR -u WORKBOARD_WIDGET_SNAPSHOT "$macos_dir/.build/workflow-regression"
