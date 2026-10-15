#!/bin/bash
# Builds the app with full Xcode and the user's own development team. On macOS 27 the desktop widget
# gallery lists the widget from this build; the Command Line Tools build in build-macos.sh is purged by chronod.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION=Release
OUTPUT_DIR="${REPO_DIR}/dist"
TEAM_ID=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --team) TEAM_ID="$2"; shift 2 ;;
        --debug) CONFIGURATION=Debug; shift ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            echo 'Usage: scripts/build-xcode.sh --team TEAMID [--debug] [--output DIR]'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Use --team to specify the 10-character Team ID added to Xcode.' >&2; exit 2; }
# The macOS-style TEAMID. prefix needs no App Group registration or provisioning profile.
APP_GROUP_ID="${TEAM_ID}.local.agentworkboard.shared"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
DERIVED="$(mktemp -d "${TMPDIR:-/tmp}/workboard-xcode.XXXXXX")"
APP="${DERIVED}/Build/Products/${CONFIGURATION}/WorkboardApp.app"
cleanup() {
    # Xcode registers its build product; keep workboard:// links on the installed app.
    if [[ -d "$APP" ]]; then "$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true; fi
    rm -rf "$DERIVED"
}
trap cleanup EXIT

# Automatic signing may contact Apple with the account added in Xcode to refresh signing assets.
xcodebuild -project "${REPO_DIR}/macos/AgentWorkboard.xcodeproj" -scheme WorkboardApp -configuration "$CONFIGURATION" \
    -derivedDataPath "$DERIVED" DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_STYLE=Automatic \
    WORKBOARD_APP_GROUP_IDENTIFIER="$APP_GROUP_ID" -allowProvisioningUpdates -quiet build
codesign --verify --deep --strict "$APP"
for code in "$APP" "${APP}/Contents/PlugIns/WorkboardWidgets.appex" "${APP}/Contents/Helpers/workboard-service"; do
    ACTUAL_TEAM="$(codesign -d --verbose=4 "$code" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
    [[ "$ACTUAL_TEAM" == "$TEAM_ID" ]] || { echo "The signing team is not ${TEAM_ID}: ${code}" >&2; exit 1; }
done
mkdir -p "$OUTPUT_DIR"
DESTINATION="${OUTPUT_DIR}/Agent Workboard.app"
rm -rf "$DESTINATION"
ditto "$APP" "$DESTINATION"
echo "App bundle: ${DESTINATION}"
echo "App Group: ${APP_GROUP_ID} (signing team: ${TEAM_ID})"
echo 'Install: scripts/install-local.sh --start-service'
