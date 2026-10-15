#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.cargo/bin:${PATH}"
BUILD_CONFIGURATION=release
BUILD_RUST=1
BUILD_WIDGET=1
OUTPUT_DIR="${REPO_DIR}/dist"
SIGN_IDENTITY="-"
APP_GROUP_ID=group.local.agentworkboard.shared
APP_GROUP_EXPLICIT=0
TEAM_ID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) BUILD_CONFIGURATION=debug; shift ;;
        --skip-rust) BUILD_RUST=0; shift ;;
        --without-widget) BUILD_WIDGET=0; shift ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --sign) SIGN_IDENTITY="$2"; shift 2 ;;
        --team) TEAM_ID="$2"; shift 2 ;;
        --app-group) APP_GROUP_ID="$2"; APP_GROUP_EXPLICIT=1; shift 2 ;;
        -h|--help)
            echo 'Usage: scripts/build-macos.sh [--debug] [--skip-rust] [--without-widget] [--output DIR] [--sign IDENTITY] [--team TEAMID] [--app-group ID]'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
if [[ -n "$TEAM_ID" ]]; then
    [[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || { echo 'Team ID must contain 10 uppercase letters or digits identifying a real development team.' >&2; exit 2; }
    [[ "$SIGN_IDENTITY" != - ]] || { echo '--team requires a real development team certificate specified with --sign.' >&2; exit 2; }
    if [[ "$APP_GROUP_EXPLICIT" == 0 ]]; then APP_GROUP_ID="${TEAM_ID}.local.agentworkboard.shared"; fi
fi
[[ "$APP_GROUP_ID" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ && "$APP_GROUP_ID" == *.* && "$APP_GROUP_ID" != *..* ]] || { echo 'Invalid App Group identifier format.' >&2; exit 2; }

cd "${REPO_DIR}"
if [[ "$BUILD_RUST" == 1 ]]; then
    if [[ "$BUILD_CONFIGURATION" == release ]]; then
        cargo build --locked --release -p workboard-cli -p workboard-service
    else
        cargo build --locked -p workboard-cli -p workboard-service
    fi
fi
swift build --package-path "${REPO_DIR}/macos" -c "$BUILD_CONFIGURATION" --product WorkboardApp
SWIFT_BIN="$(swift build --package-path "${REPO_DIR}/macos" -c "$BUILD_CONFIGURATION" --show-bin-path)"
RUST_BIN="${CARGO_TARGET_DIR:-${REPO_DIR}/target}/${BUILD_CONFIGURATION}"
for executable in workboard workboard-service; do
    [[ -x "${RUST_BIN}/${executable}" ]] || { echo "Executable not found: ${RUST_BIN}/${executable}" >&2; exit 1; }
done

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
STAGING_DIR="$(mktemp -d "${OUTPUT_DIR}/.workboard-build.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT
APP="${STAGING_DIR}/Agent Workboard.app"
CONFIG_DIR="${STAGING_DIR}/config"
swift scripts/stage-macos-config.swift "$APP_GROUP_ID" macos/Resources "$CONFIG_DIR"
mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources" "${APP}/Contents/Helpers"
cp "${SWIFT_BIN}/WorkboardApp" "${APP}/Contents/MacOS/WorkboardApp"
cp "${CONFIG_DIR}/App-Info.plist" "${APP}/Contents/Info.plist"
cp "${RUST_BIN}/workboard" "${RUST_BIN}/workboard-service" "${APP}/Contents/Helpers/"
xcrun clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 scripts/install-lock.c \
    -o "${APP}/Contents/Helpers/workboard-install-lock"
# The executable-relative location also supports direct CLI calls from the bundle.
ln -s ../Helpers/workboard "${APP}/Contents/MacOS/workboard"
ln -s ../Helpers/workboard-service "${APP}/Contents/MacOS/workboard-service"
swift scripts/generate-app-icon.swift "${STAGING_DIR}/Workboard.iconset"
iconutil -c icns "${STAGING_DIR}/Workboard.iconset" -o "${APP}/Contents/Resources/Workboard.icns"

if [[ "$BUILD_WIDGET" == 1 ]]; then
    WIDGET="${APP}/Contents/PlugIns/WorkboardWidgets.appex"
    mkdir -p "${WIDGET}/Contents/MacOS"
    cp "${CONFIG_DIR}/Widget-Info.plist" "${WIDGET}/Contents/Info.plist"
    COMPILER_FLAGS=(-O)
    [[ "$BUILD_CONFIGURATION" == debug ]] && COMPILER_FLAGS=(-Onone -g -D DEBUG)
    xcrun swiftc -parse-as-library -application-extension -D WORKBOARD_STATIC_WIDGETS -module-name WorkboardWidgets \
        -target "$(uname -m)-apple-macos14.0" "${COMPILER_FLAGS[@]}" \
        macos/WidgetExtension/WidgetSnapshot.swift macos/WidgetExtension/WorkboardWidgets.swift \
        -o "${WIDGET}/Contents/MacOS/WorkboardWidgets"
    codesign --force --sign "$SIGN_IDENTITY" --entitlements "${CONFIG_DIR}/Widget.entitlements" "$WIDGET"
fi

for executable in workboard workboard-service workboard-install-lock; do
    if [[ "$executable" == workboard-service ]]; then
        codesign --force --sign "$SIGN_IDENTITY" --entitlements "${CONFIG_DIR}/Service.entitlements" "${APP}/Contents/Helpers/${executable}"
    else
        codesign --force --sign "$SIGN_IDENTITY" "${APP}/Contents/Helpers/${executable}"
    fi
done
codesign --force --sign "$SIGN_IDENTITY" --entitlements "${CONFIG_DIR}/App.entitlements" "$APP"
ACTUAL_TEAM="$(codesign -d --verbose=4 "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
if [[ -n "$TEAM_ID" && "$ACTUAL_TEAM" != "$TEAM_ID" ]]; then
    echo 'The code signature Team ID differs from --team.' >&2; exit 1
fi
GROUP_PREFIX="${APP_GROUP_ID%%.*}"
if [[ "$GROUP_PREFIX" =~ ^[A-Z0-9]{10}$ && "$ACTUAL_TEAM" != "$GROUP_PREFIX" ]]; then
    echo 'The macOS App Group Team ID prefix differs from the signing team.' >&2; exit 1
fi
codesign --verify --deep --strict "$APP"
plutil -lint "${APP}/Contents/Info.plist"
if [[ "$BUILD_WIDGET" == 1 ]]; then plutil -lint "${WIDGET}/Contents/Info.plist"; fi
DESTINATION="${OUTPUT_DIR}/Agent Workboard.app"
if [[ -e "$DESTINATION" ]]; then
    # Replace only the generated app, after compilation and validation succeed.
    rm -rf "$DESTINATION"
fi
mv "$APP" "$DESTINATION"
echo "App bundle: ${DESTINATION}"
echo "App Group: ${APP_GROUP_ID} (signing team: ${ACTUAL_TEAM:-none})"
echo 'Local development signing does not verify notarized distribution or widget gallery behavior.'
