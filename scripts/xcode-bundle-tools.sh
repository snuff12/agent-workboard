#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="${HOME}/.cargo/bin:${PATH}"
RUST_CONFIGURATION=debug
if [[ "${CONFIGURATION:-Debug}" == Release ]]; then
    RUST_CONFIGURATION=release
fi
cd "$REPO_DIR"
if [[ "$RUST_CONFIGURATION" == release ]]; then
    cargo build --locked --release -p workboard-cli -p workboard-service
else
    cargo build --locked -p workboard-cli -p workboard-service
fi
APP_CONTENTS="${TARGET_BUILD_DIR:?}/${CONTENTS_FOLDER_PATH:?}"
CONFIG_DIR="${DERIVED_FILE_DIR:?}/WorkboardConfig"
swift "${REPO_DIR}/scripts/stage-macos-config.swift" "${WORKBOARD_APP_GROUP_IDENTIFIER:-group.local.agentworkboard.shared}" \
    "${REPO_DIR}/macos/Resources" "$CONFIG_DIR"
mkdir -p "${APP_CONTENTS}/Helpers" "${APP_CONTENTS}/Resources"
cp "${CARGO_TARGET_DIR:-${REPO_DIR}/target}/${RUST_CONFIGURATION}/workboard" \
    "${CARGO_TARGET_DIR:-${REPO_DIR}/target}/${RUST_CONFIGURATION}/workboard-service" "${APP_CONTENTS}/Helpers/"
xcrun clang -Wall -Wextra -Werror -O2 -mmacosx-version-min=14.0 "${REPO_DIR}/scripts/install-lock.c" \
    -o "${APP_CONTENTS}/Helpers/workboard-install-lock"
swift "${REPO_DIR}/scripts/generate-app-icon.swift" "${DERIVED_FILE_DIR:?}/Workboard.iconset"
iconutil -c icns "${DERIVED_FILE_DIR}/Workboard.iconset" -o "${APP_CONTENTS}/Resources/Workboard.icns"
# The host's sign phase covers nested executable code after this build phase.
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO && -n "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]]; then
    for executable in workboard workboard-service workboard-install-lock; do
        if [[ "$executable" == workboard-service ]]; then
            codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" --entitlements "${CONFIG_DIR}/Service.entitlements" "${APP_CONTENTS}/Helpers/${executable}"
        else
            codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" "${APP_CONTENTS}/Helpers/${executable}"
        fi
    done
fi
