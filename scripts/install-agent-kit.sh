#!/bin/bash
# Installs the optional Agent Workboard integrations for Claude Code and Codex.
# They are not part of the app or the default install, and each can be removed with --uninstall.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KIT="${REPO_DIR}/integrations/agents"
MARKETPLACE=agent-workboard
PLUGIN=workboard
CLAUDE=0
CODEX=0
UNINSTALL=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --claude) CLAUDE=1; shift ;;
        --codex) CODEX=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help)
            echo 'Usage: scripts/install-agent-kit.sh [--claude] [--codex] [--uninstall]'
            echo 'Without --claude or --codex, every installed tool is selected.'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
if [[ "$CLAUDE" == 0 && "$CODEX" == 0 ]]; then
    command -v claude >/dev/null 2>&1 && CLAUDE=1
    command -v codex >/dev/null 2>&1 && CODEX=1
fi
[[ "$CLAUDE" == 1 || "$CODEX" == 1 ]] || { echo 'Neither claude nor codex was found.' >&2; exit 1; }
RULES="${CODEX_HOME:-${HOME}/.codex}/rules/workboard.rules"

claude_install() {
    claude plugin validate "$KIT" >/dev/null
    if claude plugin marketplace list 2>/dev/null | grep -Eq "[[:space:]]${MARKETPLACE}\$"; then
        claude plugin marketplace update "$MARKETPLACE" >/dev/null
    else
        claude plugin marketplace add "$KIT" >/dev/null
    fi
    # Claude Code caches the plugin by version; reinstall so the cache matches this checkout.
    if claude plugin list --json 2>/dev/null | grep -q "\"${PLUGIN}@${MARKETPLACE}\""; then
        claude plugin uninstall "${PLUGIN}@${MARKETPLACE}" >/dev/null
    fi
    claude plugin install "${PLUGIN}@${MARKETPLACE}" >/dev/null
    echo "Claude Code: installed ${PLUGIN}@${MARKETPLACE}. New sessions load board context at start."
}

claude_uninstall() {
    claude plugin uninstall "${PLUGIN}@${MARKETPLACE}" >/dev/null 2>&1 || true
    claude plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 || true
    echo 'Claude Code: removed the Agent Workboard plugin and marketplace.'
}

# The sandbox rules must name the executable as agents invoke it: bare, through PATH, or by the
# absolute path in the app bundle that launch prompts use.
codex_rules() {
    local paths=() candidate resolved existing
    for candidate in "$(command -v workboard 2>/dev/null || true)" "${HOME}/.local/bin/workboard"; do
        [[ -n "$candidate" && -x "$candidate" ]] || continue
        resolved="$(cd "$(dirname "$candidate")" && pwd -P)/$(basename "$candidate")"
        if [[ -L "$candidate" ]]; then
            resolved="$(readlink "$candidate")"
            [[ "$resolved" == /* ]] || resolved="$(dirname "$candidate")/${resolved}"
        fi
        for existing in "$candidate" "$resolved"; do
            [[ " ${paths[*]-} " == *" ${existing} "* ]] || paths+=("$existing")
        done
    done
    mkdir -p "$(dirname "$RULES")"
    {
        cat "${KIT}/codex/workboard.rules"
        for candidate in "${paths[@]+"${paths[@]}"}"; do
            [[ "$candidate" != *'"'* && "$candidate" != *'\'* ]] || continue
            printf '\n# Same rules for %s\n' "$candidate"
            sed -n '/^prefix_rule(/,/^)/p' "${KIT}/codex/workboard.rules" \
                | sed "s|\\[\"workboard\",|[\"${candidate}\",|g"
        done
    } > "${RULES}.tmp"
    mv "${RULES}.tmp" "$RULES"
}

codex_install() {
    if ! codex plugin marketplace list 2>/dev/null | grep -Eq "^${MARKETPLACE}[[:space:]]"; then
        codex plugin marketplace add "$KIT" >/dev/null
    fi
    # Codex installs a cached copy; reinstall so the cache matches this checkout.
    if codex plugin list --json 2>/dev/null | grep -q "\"${PLUGIN}@${MARKETPLACE}\""; then
        codex plugin remove "${PLUGIN}@${MARKETPLACE}" >/dev/null
    fi
    codex plugin add "${PLUGIN}@${MARKETPLACE}" >/dev/null
    codex_rules
    echo "Codex: installed ${PLUGIN}@${MARKETPLACE} and ${RULES}."
    echo 'Codex: open Codex, run /hooks, and trust the Agent Workboard SessionStart hook once.'
}

codex_uninstall() {
    codex plugin remove "${PLUGIN}@${MARKETPLACE}" >/dev/null 2>&1 || true
    codex plugin marketplace remove "$MARKETPLACE" >/dev/null 2>&1 || true
    rm -f "$RULES"
    echo 'Codex: removed the Agent Workboard plugin, marketplace, and rules.'
}

if [[ "$UNINSTALL" == 1 ]]; then
    [[ "$CLAUDE" == 1 ]] && claude_uninstall
    [[ "$CODEX" == 1 ]] && codex_uninstall
else
    [[ "$CLAUDE" == 1 ]] && claude_install
    [[ "$CODEX" == 1 ]] && codex_install
fi
exit 0
