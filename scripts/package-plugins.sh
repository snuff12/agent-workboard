#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${1:-${REPO_DIR}/dist}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/workboard-plugins.XXXXXX")"
trap 'rm -rf "$STAGING_DIR"' EXIT

for plugin in agent-memory google-workspace slack linear orca github; do
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
    # Explicit file list excludes credentials, caches, metadata and future files.
    # Normalize timestamps and omit extra ZIP fields so reruns remain reproducible.
    touch -t 200001010000 "${STAGING_DIR}/${PACKAGE}/plugin.json" "${STAGING_DIR}/${PACKAGE}/${EXECUTABLE}"
    (
        cd "$STAGING_DIR"
        /usr/bin/zip -X -q "$ARCHIVE" "${PACKAGE}/plugin.json" "${PACKAGE}/${EXECUTABLE}"
    )
    /usr/bin/unzip -tq "${STAGING_DIR}/${ARCHIVE}"
    mv -f "${STAGING_DIR}/${ARCHIVE}" "${OUTPUT_DIR}/${ARCHIVE}"
    echo "Plugin archive: ${OUTPUT_DIR}/${ARCHIVE}"
done
