#!/bin/bash
set -euo pipefail
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ORIGINAL_ARGS=(--internal-locked "$@")
APP_SOURCE="${REPO_DIR}/dist/Agent Workboard.app"
INSTALL_DIR="${HOME}/Applications"
BIN_DIR="${HOME}/.local/bin"
DATA_DIR="${WORKBOARD_DATA_DIR:-${HOME}/Library/Application Support/AgentWorkboard}"
SOCKET_PATH="${WORKBOARD_SOCKET:-}"
SERVICE_LABEL=local.agentworkboard.service
AGENT_DIR="${HOME}/Library/LaunchAgents"
LOG_DIR="${HOME}/Library/Logs/AgentWorkboard"
START_SERVICE=0
REGISTER_APP=1
LOCKED=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --app) APP_SOURCE="$2"; shift 2 ;;
        --destination) INSTALL_DIR="$2"; shift 2 ;;
        --bin-dir) BIN_DIR="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --socket) SOCKET_PATH="$2"; shift 2 ;;
        --service-label) SERVICE_LABEL="$2"; shift 2 ;;
        --agent-dir) AGENT_DIR="$2"; shift 2 ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --start-service) START_SERVICE=1; shift ;;
        --skip-register) REGISTER_APP=0; shift ;;
        --internal-locked) LOCKED=1; shift ;;
        -h|--help)
            echo 'Usage: scripts/install-local.sh [--app PATH] [--destination DIR] [--bin-dir DIR] [--start-service] [--skip-register]'
            echo 'Service paths: [--data-dir DIR] [--socket PATH] [--service-label local.agentworkboard.NAME] [--agent-dir DIR] [--log-dir DIR]'
            exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 2 ;;
    esac
done
[[ "$SERVICE_LABEL" == local.agentworkboard.* && "$SERVICE_LABEL" != *'/'* ]] || { echo 'The service name must start with local.agentworkboard.' >&2; exit 2; }
[[ -d "$APP_SOURCE" && ! -L "$APP_SOURCE" ]] || { echo 'Run scripts/build-macos.sh first.' >&2; exit 1; }
APP_SOURCE="$(cd "$APP_SOURCE" && pwd -P)"
for executable in workboard workboard-service workboard-install-lock; do
    [[ -x "${APP_SOURCE}/Contents/Helpers/${executable}" ]] || { echo "Bundled executable missing: ${executable}. Rebuild the app." >&2; exit 1; }
done
mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$DATA_DIR"
INSTALL_DIR="$(cd "$INSTALL_DIR" && pwd -P)"
BIN_DIR="$(cd "$BIN_DIR" && pwd -P)"
DATA_DIR="$(cd "$DATA_DIR" && pwd -P)"
[[ "$(stat -f %u "$DATA_DIR")" == "$(id -u)" ]] || { echo 'The working directory belongs to another user.' >&2; exit 1; }
APP_DESTINATION="${INSTALL_DIR}/Agent Workboard.app"
[[ ! -L "$APP_DESTINATION" ]] || { echo 'The destination app is a symbolic link and will not be replaced.' >&2; exit 1; }
if [[ -z "$SOCKET_PATH" ]]; then SOCKET_PATH="${DATA_DIR}/workboard.sock"; fi
SOCKET_BYTES="$(printf '%s' "$SOCKET_PATH" | wc -c | tr -d ' ')"
[[ "$SOCKET_PATH" == /* && "$SOCKET_BYTES" -le 103 ]] || { echo 'Use --socket to specify an absolute socket path of at most 103 bytes.' >&2; exit 1; }
USER_ID="$(id -u)"
DOMAIN="gui/${USER_ID}"
AGENT="${AGENT_DIR}/${SERVICE_LABEL}.plist"
LOCK_FILE="${DATA_DIR}/service.lock"
LSREGISTER="$(command -v lsregister || true)"
if [[ -z "$LSREGISTER" ]]; then LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister; fi

if [[ "$LOCKED" == 0 ]]; then
    exec "${APP_SOURCE}/Contents/Helpers/workboard-install-lock" --lock "${DATA_DIR}/install.lock" -- \
        /bin/bash "${REPO_DIR}/scripts/install-local.sh" "${ORIGINAL_ARGS[@]}"
fi

# Discover the exact writer using both the board lock and socket, then verify UID
# and executable path before sending a signal. Never use a broad process-name kill.
WRITER_PID=""
WRITER_EXECUTABLE=""
writer_pids() {
    if [[ -e "$LOCK_FILE" ]]; then lsof -a -u "$USER_ID" -t "$LOCK_FILE" 2>/dev/null || true; fi
}
inspect_writer() {
    WRITER_PID=""; WRITER_EXECUTABLE=""
    [[ ! -L "$LOCK_FILE" && ! -L "$SOCKET_PATH" ]] || { echo 'The service lock or socket is a symbolic link.' >&2; return 1; }
    local holders listeners candidate executable
    holders="$(writer_pids)"
    listeners="$(lsof -n -a -U -t "$SOCKET_PATH" 2>/dev/null || true)"
    if [[ -z "$holders" && -z "$listeners" ]]; then return 0; fi
    [[ "$holders" =~ ^[0-9]+$ && "$listeners" == "$holders" ]] || { echo 'Could not verify a single service owner for the lock file and socket.' >&2; return 1; }
    candidate="$holders"
    [[ "$(ps -p "$candidate" -o uid= | tr -d ' ')" == "$USER_ID" ]] || { echo 'The service process belongs to another user.' >&2; return 1; }
    executable="$(lsof -a -p "$candidate" -d txt -Fn 2>/dev/null | sed -n 's/^n\(.*\/workboard-service\)$/\1/p' | head -n 1)"
    case "$executable" in
        "${APP_DESTINATION}/Contents/Helpers/workboard-service"|"${APP_SOURCE}/Contents/Helpers/workboard-service"|"${REPO_DIR}/target/debug/workboard-service"|"${REPO_DIR}/target/release/workboard-service") ;;
        *) echo 'Stopping because the service executable managed by this installation could not be verified.' >&2; return 1 ;;
    esac
    WRITER_PID="$candidate"; WRITER_EXECUTABLE="$executable"
}
wait_stopped() {
    local attempt
    for attempt in $(seq 1 100); do
        if [[ -z "$(writer_pids)" && -z "$(lsof -n -a -U -t "$SOCKET_PATH" 2>/dev/null || true)" ]]; then return 0; fi
        sleep 0.1
    done
    echo 'The service did not release its lock and socket. It will not be forcibly terminated.' >&2
    return 1
}
probe_service() {
    local response core_health
    response="$(printf '%s\n' '{"schema_version":1,"request_id":"installer-health","method":"doctor","params":{}}' | nc -U -w 2 "$SOCKET_PATH" 2>/dev/null || true)"
    core_health="$(printf '%s' "$response" | plutil -extract result.core_healthy raw -o - - 2>/dev/null || true)"
    if [[ -z "$core_health" ]]; then core_health="$(printf '%s' "$response" | plutil -extract result.healthy raw -o - - 2>/dev/null || true)"; fi
    [[ "$(printf '%s' "$response" | plutil -extract ok raw -o - - 2>/dev/null || true)" == true && "$core_health" == true ]]
}
wait_healthy() {
    local attempt
    for attempt in $(seq 1 80); do
        if probe_service; then return 0; fi
        sleep 0.1
    done
    return 1
}

for executable in workboard workboard-service; do
    LINK="${BIN_DIR}/${executable}"
    [[ ! -e "$LINK" || -L "$LINK" ]] || { echo "Will not overwrite an existing file: ${LINK}" >&2; exit 1; }
done
STAGING_DIR="$(mktemp -d "${INSTALL_DIR}/.workboard-install.XXXXXX")"
APP_SWAPPED=0
HAD_APP=0
if [[ -e "$APP_DESTINATION" ]]; then HAD_APP=1; fi
LINKS_CHANGED=0
SERVICE_STOPPED=0
NEW_BOOTSTRAPPED=0
AGENT_CHANGED=0
OLD_MANAGED=0
MANAGED_PID=""
OLD_PID=""
OLD_EXECUTABLE=""
OLD_LINK_WORKBOARD="$(readlink "${BIN_DIR}/workboard" 2>/dev/null || true)"
OLD_LINK_SERVICE="$(readlink "${BIN_DIR}/workboard-service" 2>/dev/null || true)"

finish() {
    local status=$?
    trap - EXIT INT TERM HUP
    set +e
    local preserve_stage=0
    if [[ "$status" != 0 && "$NEW_BOOTSTRAPPED" == 1 ]]; then
        # Startup can migrate SQLite before bootstrap or the health probe returns.
        # Keep this executable with that database, including any newly accepted writes.
        preserve_stage=1
        echo 'Installation did not complete after new service startup was attempted. Keeping the new app and database together; automatic downgrade is unsafe.' >&2
        if ! launchctl print "${DOMAIN}/${SERVICE_LABEL}" >/dev/null 2>&1; then
            if ! launchctl bootstrap "$DOMAIN" "$AGENT"; then
                # Login registration may be unavailable. Recover core access with the
                # same compatible executable, only if there is no other verified writer.
                if inspect_writer && [[ -z "$WRITER_PID" ]]; then
                    "${APP_DESTINATION}/Contents/Helpers/workboard-service" --data-dir "$DATA_DIR" --socket "$SOCKET_PATH" </dev/null >>"${DATA_DIR}/service.log" 2>&1 &
                fi
            fi
        fi
        if wait_healthy && inspect_writer && [[ "$WRITER_EXECUTABLE" == "${APP_DESTINATION}/Contents/Helpers/workboard-service" ]]; then
            echo 'The new task service is healthy. Run the installer again with the same options to finish registration.' >&2
        else
            echo "The new service is not healthy yet. Inspect ${LOG_DIR}/service-error.log and ${DATA_DIR}/service.log, then retry installation. Do not start the previous service against this database." >&2
        fi
    elif [[ "$status" != 0 ]]; then
        echo 'Installation did not complete. Restoring the previous app and service configuration.' >&2
        if [[ "$APP_SWAPPED" == 1 ]]; then
            if [[ -e "${STAGING_DIR}/previous.app" ]]; then
                if [[ -e "$APP_DESTINATION" ]]; then mv "$APP_DESTINATION" "${STAGING_DIR}/rejected.app"; fi
                mv "${STAGING_DIR}/previous.app" "$APP_DESTINATION" || preserve_stage=1
            elif [[ "$HAD_APP" == 0 && -e "$APP_DESTINATION" ]]; then
                mv "$APP_DESTINATION" "${STAGING_DIR}/rejected.app" || preserve_stage=1
            fi
        fi
        if [[ "$LINKS_CHANGED" == 1 ]]; then
            rm -f "${BIN_DIR}/workboard" "${BIN_DIR}/workboard-service"
            if [[ -n "$OLD_LINK_WORKBOARD" ]]; then ln -s "$OLD_LINK_WORKBOARD" "${BIN_DIR}/workboard"; fi
            if [[ -n "$OLD_LINK_SERVICE" ]]; then ln -s "$OLD_LINK_SERVICE" "${BIN_DIR}/workboard-service"; fi
        fi
        if [[ "$AGENT_CHANGED" == 1 ]]; then
            rm -f "$AGENT"
            if [[ -f "${STAGING_DIR}/previous-agent.plist" ]]; then cp "${STAGING_DIR}/previous-agent.plist" "$AGENT"; fi
        fi
        if [[ "$SERVICE_STOPPED" == 1 ]]; then
            if [[ "$OLD_MANAGED" == 1 ]]; then
                launchctl bootstrap "$DOMAIN" "$AGENT" || echo 'Could not register the previous service again. Task data is preserved.' >&2
            elif [[ -n "$OLD_EXECUTABLE" && -x "$OLD_EXECUTABLE" && -z "$(writer_pids)" ]]; then
                "$OLD_EXECUTABLE" --data-dir "$DATA_DIR" --socket "$SOCKET_PATH" </dev/null >>"${DATA_DIR}/service.log" 2>&1 &
            fi
        fi
        if [[ "$REGISTER_APP" == 1 && -d "$APP_DESTINATION" ]]; then "$LSREGISTER" -f "$APP_DESTINATION" >/dev/null 2>&1 || true; fi
    fi
    if [[ "$preserve_stage" == 0 ]]; then rm -rf "$STAGING_DIR"; else echo "Installation recovery files preserved: ${STAGING_DIR}" >&2; fi
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Always stage a complete copy, including when source and destination are equal.
ditto "$APP_SOURCE" "${STAGING_DIR}/new.app"
codesign --verify --deep --strict "${STAGING_DIR}/new.app"
[[ ! -L "$AGENT" ]] || { echo 'The LaunchAgent configuration is a symbolic link and will not be replaced.' >&2; exit 1; }
if [[ -f "$AGENT" ]]; then
    [[ -O "$AGENT" ]] || { echo 'The LaunchAgent configuration belongs to another user.' >&2; exit 1; }
    cp "$AGENT" "${STAGING_DIR}/previous-agent.plist"
fi
if MANAGED_STATE="$(launchctl print "${DOMAIN}/${SERVICE_LABEL}" 2>/dev/null)"; then
    MANAGED_PROGRAM="$(printf '%s\n' "$MANAGED_STATE" | sed -n 's/^[[:space:]]*program = //p' | head -n 1)"
    MANAGED_PID="$(printf '%s\n' "$MANAGED_STATE" | sed -n 's/^[[:space:]]*pid = \([0-9][0-9]*\)$/\1/p' | head -n 1)"
    [[ "$MANAGED_PROGRAM" == "${APP_DESTINATION}/Contents/Helpers/workboard-service" && -f "$AGENT" ]] || { echo 'The existing LaunchAgent is not a recoverable configuration for this app.' >&2; exit 1; }
    MANAGED_DATA="$(plutil -extract ProgramArguments.2 raw -o - "$AGENT" 2>/dev/null || true)"
    MANAGED_SOCKET="$(plutil -extract ProgramArguments.4 raw -o - "$AGENT" 2>/dev/null || true)"
    if [[ -z "$MANAGED_DATA" && -z "$MANAGED_SOCKET" ]]; then
        MANAGED_DATA="${HOME}/Library/Application Support/AgentWorkboard"
        MANAGED_SOCKET="${MANAGED_DATA}/workboard.sock"
    fi
    [[ "$MANAGED_DATA" == "$DATA_DIR" && "$MANAGED_SOCKET" == "$SOCKET_PATH" ]] || { echo 'The existing LaunchAgent uses a different working directory or socket.' >&2; exit 1; }
    OLD_MANAGED=1
    START_SERVICE=1
fi
if [[ "$START_SERVICE" == 1 ]]; then
    inspect_writer
    OLD_PID="$WRITER_PID"; OLD_EXECUTABLE="$WRITER_EXECUTABLE"
    if [[ "$OLD_MANAGED" == 1 ]]; then
        [[ -z "$MANAGED_PID" || "$MANAGED_PID" == "$OLD_PID" ]] || { echo 'The LaunchAgent PID differs from the service PID for the selected working directory.' >&2; exit 1; }
        launchctl bootout "${DOMAIN}/${SERVICE_LABEL}"
        SERVICE_STOPPED=1
        # A loaded but idle job can coexist with a manually started writer.
        # If bootout did not stop that writer, revalidate and stop only that PID.
        if [[ -z "$MANAGED_PID" && -n "$OLD_PID" ]]; then
            inspect_writer
            [[ "$WRITER_PID" == "$OLD_PID" && "$WRITER_EXECUTABLE" == "$OLD_EXECUTABLE" ]] || { echo 'The service changed during verification.' >&2; exit 1; }
            kill -TERM "$OLD_PID"
        fi
        wait_stopped
    elif [[ -n "$OLD_PID" ]]; then
        # Revalidate immediately before signalling to reduce PID reuse races.
        inspect_writer
        [[ "$WRITER_PID" == "$OLD_PID" && "$WRITER_EXECUTABLE" == "$OLD_EXECUTABLE" ]] || { echo 'The service changed during verification.' >&2; exit 1; }
        kill -TERM "$OLD_PID"
        SERVICE_STOPPED=1
        wait_stopped
    fi
fi

APP_SWAPPED=1
if [[ -e "$APP_DESTINATION" ]]; then mv "$APP_DESTINATION" "${STAGING_DIR}/previous.app"; fi
mv "${STAGING_DIR}/new.app" "$APP_DESTINATION"
LINKS_CHANGED=1
ln -sfn "${APP_DESTINATION}/Contents/Helpers/workboard" "${BIN_DIR}/workboard"
ln -sfn "${APP_DESTINATION}/Contents/Helpers/workboard-service" "${BIN_DIR}/workboard-service"
if [[ "$REGISTER_APP" == 1 ]]; then "$LSREGISTER" -f "$APP_DESTINATION"; fi

if [[ "$START_SERVICE" == 1 ]]; then
    mkdir -p "$AGENT_DIR" "$LOG_DIR"
    NEW_AGENT="${STAGING_DIR}/new-agent.plist"
    plutil -create xml1 "$NEW_AGENT"
    plutil -insert Label -string "$SERVICE_LABEL" "$NEW_AGENT"
    plutil -insert ProgramArguments -json '[]' "$NEW_AGENT"
    plutil -insert ProgramArguments.0 -string "${APP_DESTINATION}/Contents/Helpers/workboard-service" "$NEW_AGENT"
    plutil -insert ProgramArguments.1 -json '"--data-dir"' "$NEW_AGENT"
    plutil -insert ProgramArguments.2 -string "$DATA_DIR" "$NEW_AGENT"
    plutil -insert ProgramArguments.3 -json '"--socket"' "$NEW_AGENT"
    plutil -insert ProgramArguments.4 -string "$SOCKET_PATH" "$NEW_AGENT"
    plutil -insert RunAtLoad -bool YES "$NEW_AGENT"
    plutil -insert KeepAlive -json '{"SuccessfulExit":false}' "$NEW_AGENT"
    plutil -insert ThrottleInterval -integer 30 "$NEW_AGENT"
    # The service answers CLI and app requests directly. Background policy measured 2-4x slower replies.
    plutil -insert ProcessType -string Standard "$NEW_AGENT"
    plutil -insert StandardOutPath -string "${LOG_DIR}/service.log" "$NEW_AGENT"
    plutil -insert StandardErrorPath -string "${LOG_DIR}/service-error.log" "$NEW_AGENT"
    APP_GROUP_ID="$(plutil -extract WorkboardAppGroupIdentifier raw -o - "${APP_DESTINATION}/Contents/Info.plist" 2>/dev/null || true)"
    GROUP_CONTAINER="${HOME}/Library/Group Containers/${APP_GROUP_ID}"
    if [[ -n "$APP_GROUP_ID" && "$APP_GROUP_ID" != *'$('* && "$SERVICE_LABEL" == local.agentworkboard.service && "$DATA_DIR" == "${HOME}/Library/Application Support/AgentWorkboard" && -d "$GROUP_CONTAINER" ]]; then
        plutil -insert EnvironmentVariables -json '{}' "$NEW_AGENT"
        plutil -insert EnvironmentVariables.WORKBOARD_WIDGET_SNAPSHOT -string "${GROUP_CONTAINER}/widget-snapshot.json" "$NEW_AGENT"
    fi
    plutil -lint "$NEW_AGENT"
    AGENT_CHANGED=1
    cp "$NEW_AGENT" "$AGENT"
    # This is the recovery boundary: even a failed bootstrap may have run migrations.
    NEW_BOOTSTRAPPED=1
    launchctl bootstrap "$DOMAIN" "$AGENT"
    wait_healthy || { echo 'The registered service did not return a healthy response.' >&2; exit 1; }
    inspect_writer
    [[ "$WRITER_EXECUTABLE" == "${APP_DESTINATION}/Contents/Helpers/workboard-service" ]] || { echo 'The new service executable differs from the installed app.' >&2; exit 1; }
    echo "User service registered and health verified: ${AGENT}"
    WIDGET_HEALTH="$(printf '%s\n' '{"schema_version":1,"request_id":"installer-widget-health","method":"widget.status","params":{}}' | nc -U -w 2 "$SOCKET_PATH" 2>/dev/null || true)"
    if [[ "$(printf '%s' "$WIDGET_HEALTH" | plutil -extract result.healthy raw -o - - 2>/dev/null || true)" == false ]]; then
        echo 'Tasks are available, but widget publication failed. Run workboard doctor --json for destination errors. The service will retry automatically.' >&2
    fi
fi
# A running widget extension keeps drawing with the replaced binary until it exits. WidgetKit relaunches it.
if [[ "$REGISTER_APP" == 1 ]]; then
    pkill -f "${APP_DESTINATION}/Contents/PlugIns/WorkboardWidgets.appex/Contents/MacOS/" 2>/dev/null || true
fi
echo "App installed: ${APP_DESTINATION}"
echo "CLI link: ${BIN_DIR}/workboard"
echo 'Open the app once, then add the widget using macOS Edit Widgets.'
