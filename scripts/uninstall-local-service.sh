#!/bin/bash
set -euo pipefail
LABEL=local.agentworkboard.service
launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
AGENT="${HOME}/Library/LaunchAgents/${LABEL}.plist"
if [[ -f "$AGENT" ]]; then rm "$AGENT"; fi
echo 'Automatic service startup unregistered. The app and task data are preserved.'
