#!/bin/bash
set -euo pipefail
macos_dir="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$macos_dir/.build"
set --
for source in "$macos_dir"/Sources/WorkboardApp/*.swift; do
  if [[ "$(basename "$source")" != "WorkboardApp.swift" ]]; then set -- "$@" "$source"; fi
done
swiftc -swift-version 6 -parse-as-library "$@" "$macos_dir/Tests/PlannerRegression.swift" -o "$macos_dir/.build/planner-tests"
"$macos_dir/.build/planner-tests"
