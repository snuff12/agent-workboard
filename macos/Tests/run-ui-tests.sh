#!/bin/bash
# Runs the native XCUITest suite against an isolated board. Requires full Xcode and
# UI automation (`automationmodetool`). The user's board, settings and widget snapshot are untouched.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DERIVED="${WORKBOARD_UI_DERIVED_DATA:-${TMPDIR:-/tmp}/workboard-ui-tests}"
RESULT="${DERIVED}/result.xcresult"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
# Local ad-hoc signing. The App Group entitlement needs a provisioning profile and the tests do not use it.
SIGNING=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= CODE_SIGN_ENTITLEMENTS=)
COMMON=(-project "${REPO_DIR}/macos/AgentWorkboard.xcodeproj" -scheme WorkboardApp -configuration Debug -derivedDataPath "$DERIVED")

APP="${DERIVED}/Build/Products/Debug/WorkboardApp.app"
RUNNER="${DERIVED}/Build/Products/Debug/WorkboardAppUITests-Runner.app"
INPUT_TOOL="${DERIVED}/input-source"
PREVIOUS_INPUT=""
cleanup() {
    # The frontmost app can take its own input source back while the test app quits; confirm the restore.
    if [[ -n "$PREVIOUS_INPUT" ]]; then
        for _ in 1 2 3 4 5; do
            "$INPUT_TOOL" "$PREVIOUS_INPUT" >/dev/null 2>&1 || true
            sleep 1
            [[ "$("$INPUT_TOOL")" == "$PREVIOUS_INPUT" ]] && break
        done
        [[ "$("$INPUT_TOOL")" == "$PREVIOUS_INPUT" ]] || echo "Could not restore the input source. Switch to ${PREVIOUS_INPUT} manually." >&2
    fi
    # Xcode registers the test build with LaunchServices. Keep workboard:// links on the installed app.
    if [[ -d "$APP" ]]; then "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true; fi
    if [[ -d "$RUNNER" ]]; then "$LSREGISTER" -u "$RUNNER" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

xcodebuild "${COMMON[@]}" "${SIGNING[@]}" build-for-testing -quiet

# Xcode signs the UI test runner with App Sandbox. Its CLI and service children would inherit it and could
# not create the isolated board outside the container, so the runner is re-signed ad-hoc without the sandbox.
ENTITLEMENTS="$(mktemp "${TMPDIR:-/tmp}/workboard-runner.XXXXXX")"
codesign -d --xml --entitlements "$ENTITLEMENTS" "$RUNNER" 2>/dev/null
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c 'Delete :com.apple.security.app-sandbox' "$ENTITLEMENTS"
    codesign --force --sign - --entitlements "$ENTITLEMENTS" "$RUNNER"
fi
rm -f "$ENTITLEMENTS"

# Shortcuts are synthesized through the active layout. Use ABC during the run and restore the user's input source.
mkdir -p "$DERIVED"
xcrun swiftc -O "${REPO_DIR}/macos/Tests/input-source.swift" -o "$INPUT_TOOL"
PREVIOUS_INPUT="$("$INPUT_TOOL")"
"$INPUT_TOOL" com.apple.keylayout.ABC >/dev/null

rm -rf "$RESULT"
xcodebuild "${COMMON[@]}" "${SIGNING[@]}" -resultBundlePath "$RESULT" test-without-building "$@"
