#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${REPO_DIR}/dist"
GOOGLE_CLIENT="${WORKBOARD_GOOGLE_OAUTH_CLIENT_FILE:-${REPO_DIR}/.local/google-workspace/oauth-client.json}"
GOOGLE_CLIENT_REQUIRED=0
if [[ -n "${WORKBOARD_GOOGLE_OAUTH_CLIENT_FILE:-}" ]]; then GOOGLE_CLIENT_REQUIRED=1; fi
while [[ $# -gt 0 ]]; do
    case "$1" in
        --google-oauth-client) GOOGLE_CLIENT="$2"; GOOGLE_CLIENT_REQUIRED=1; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) echo 'Usage: scripts/package-plugins.sh [OUTPUT_DIR] [--google-oauth-client DESKTOP_JSON]'; exit 0 ;;
        *) OUTPUT_DIR="$1"; shift ;;
    esac
done
if [[ "$GOOGLE_CLIENT_REQUIRED" == 1 && ! -f "$GOOGLE_CLIENT" ]]; then
    echo 'The publisher Google OAuth client file is missing.' >&2; exit 1
fi
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workboard-plugins.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

for plugin in agent-memory google-workspace slack orca; do
    SOURCE="${REPO_DIR}/plugins/${plugin}"
    MANIFEST="${SOURCE}/plugin.json"
    IDENTIFIER="$(plutil -extract id raw -o - "$MANIFEST")"
    VERSION="$(plutil -extract version raw -o - "$MANIFEST")"
    EXECUTABLE="$(plutil -extract executable raw -o - "$MANIFEST")"
    [[ "$IDENTIFIER" == "$plugin" ]] || { echo 'The plugin ID differs from its directory name.' >&2; exit 1; }
    [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([+-][A-Za-z0-9.-]+)?$ ]] || { echo 'Invalid plugin version format.' >&2; exit 1; }
    [[ "$EXECUTABLE" == plugin.py && -f "${SOURCE}/${EXECUTABLE}" && ! -L "${SOURCE}/${EXECUTABLE}" ]] || { echo 'Could not verify a single plugin executable for distribution.' >&2; exit 1; }
    PACKAGE="${IDENTIFIER}-${VERSION}"
    ARCHIVE="AgentWorkboard-plugin-${PACKAGE}.zip"
    mkdir "${STAGING_DIR}/${PACKAGE}"
    install -m 644 "$MANIFEST" "${STAGING_DIR}/${PACKAGE}/plugin.json"
    install -m 755 "${SOURCE}/${EXECUTABLE}" "${STAGING_DIR}/${PACKAGE}/${EXECUTABLE}"
    MEMBERS=("${PACKAGE}/plugin.json" "${PACKAGE}/${EXECUTABLE}")
    if [[ "$plugin" == google-workspace && -f "$GOOGLE_CLIENT" ]]; then
        # A publisher-owned Desktop client is public app metadata, never user tokens.
        # Copy only Desktop client fields; reject web clients and unrelated credentials.
        python3 "${REPO_DIR}/scripts/prepare-google-oauth.py" "$GOOGLE_CLIENT" "${STAGING_DIR}/${PACKAGE}/oauth-client.json"
        touch -t 200001010000 "${STAGING_DIR}/${PACKAGE}/oauth-client.json"
        MEMBERS+=("${PACKAGE}/oauth-client.json")
    fi
    # Explicit file list excludes credentials, caches, metadata and future files.
    # Normalize timestamps and omit extra ZIP fields so reruns remain reproducible.
    touch -t 200001010000 "${STAGING_DIR}/${PACKAGE}/plugin.json" "${STAGING_DIR}/${PACKAGE}/${EXECUTABLE}"
    (
        cd "$STAGING_DIR"
        /usr/bin/zip -X -q "$ARCHIVE" "${MEMBERS[@]}"
    )
    /usr/bin/unzip -tq "${STAGING_DIR}/${ARCHIVE}"
    mv -f "${STAGING_DIR}/${ARCHIVE}" "${OUTPUT_DIR}/${ARCHIVE}"
    echo "Plugin archive: ${OUTPUT_DIR}/${ARCHIVE}"
done
