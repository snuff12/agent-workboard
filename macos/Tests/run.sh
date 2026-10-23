#!/bin/bash
set -euo pipefail
macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$macos_dir/.build"
sources=()
for source in "$macos_dir"/Sources/WorkboardApp/*.swift; do
  if [[ "${source##*/}" != "WorkboardApp.swift" ]]; then
    sources+=("$source")
  fi
done
swiftc -swift-version 6 -parse-as-library "${sources[@]}" "$macos_dir/Tests/WorkboardAppTests/WorkboardAppTests.swift" -o "$macos_dir/.build/ui-smoke-tests"
"$macos_dir/.build/ui-smoke-tests"
