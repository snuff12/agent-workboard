#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CLI="${1:-${REPO_DIR}/target/release/workboard}"
ARCHIVE_DIR="${2:-${REPO_DIR}/dist}"
[[ -x "$CLI" ]] || { echo 'The workboard CLI executable to verify is missing.' >&2; exit 1; }
VERIFY_DIR="$(mktemp -d /tmp/awb-plugin-packages.XXXXXX)"
trap 'rm -rf "$VERIFY_DIR"' EXIT
PLUGINS=(agent-memory google-workspace slack linear orca github)
for plugin in "${PLUGINS[@]}"; do
    VERSION="$(plutil -extract version raw -o - "${REPO_DIR}/plugins/${plugin}/plugin.json")"
    PACKAGE="${plugin}-${VERSION}"
    ARCHIVE="${ARCHIVE_DIR}/AgentWorkboard-plugin-${PACKAGE}.zip"
    MEMBERS="$(/usr/bin/unzip -Z -1 "$ARCHIVE")"
    EXPECTED="$(printf '%s\n%s' "${PACKAGE}/plugin.json" "${PACKAGE}/plugin.py")"
    [[ "$MEMBERS" == "$EXPECTED" ]] || { echo 'The ZIP contains items other than the manifest and executable.' >&2; exit 1; }
    /usr/bin/unzip -q "$ARCHIVE" -d "${VERIFY_DIR}/extracted"
    [[ -x "${VERIFY_DIR}/extracted/${PACKAGE}/plugin.py" ]] || { echo 'The extracted executable lacks execute permission.' >&2; exit 1; }
    "$CLI" --json --data-dir "${VERIFY_DIR}/data" --socket "${VERIFY_DIR}/s.sock" \
        plugin install "${VERIFY_DIR}/extracted/${PACKAGE}" >"${VERIFY_DIR}/install.json"
    [[ "$(plutil -extract ok raw -o - "${VERIFY_DIR}/install.json")" == true ]]
    STATUS=0
    "$CLI" --json --data-dir "${VERIFY_DIR}/data" --socket "${VERIFY_DIR}/s.sock" \
        plugin check "$plugin" >"${VERIFY_DIR}/disabled.json" || STATUS=$?
    [[ "$STATUS" != 0 && "$(plutil -extract error.code raw -o - "${VERIFY_DIR}/disabled.json")" == PLUGIN_DISABLED ]] || { echo 'The installed plugin is not disabled by default.' >&2; exit 1; }
    echo "Extraction, CLI installation, and disabled default verified: ${PACKAGE}"
done
"$CLI" --json --data-dir "${VERIFY_DIR}/data" --socket "${VERIFY_DIR}/s.sock" plugin list >"${VERIFY_DIR}/plugins.json"
[[ "$(plutil -extract result.plugins raw -o - "${VERIFY_DIR}/plugins.json")" == "${#PLUGINS[@]}" ]] || { echo 'The plugin list does not match the installed packages.' >&2; exit 1; }
for index in "${!PLUGINS[@]}"; do
    [[ "$(plutil -extract "result.plugins.${index}.enabled" raw -o - "${VERIFY_DIR}/plugins.json")" == false ]] || { echo 'An installed plugin is enabled by default.' >&2; exit 1; }
done
[[ ! -S "${VERIFY_DIR}/s.sock" ]] || { echo 'The installation and disabled-state check started the core task service.' >&2; exit 1; }
echo 'Separate plugin ZIP checks passed without calling external accounts, amem, or Orca.'
