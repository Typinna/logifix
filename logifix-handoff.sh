#!/bin/bash

set -u

BASE_DIR="/Library/Application Support/LogiFix"
CONFIG_FILE="${BASE_DIR}/users.conf"

LOGI_LAUNCH_AGENT_LABEL="com.logi.cp-dev-mgr"
LOGI_LAUNCH_AGENT_PLIST="/Library/LaunchAgents/com.logi.optionsplus.plist"

PLUGIN_ROOT="/Applications/Utilities/LogiPluginService.app/Contents"

LOG_FILE="/var/log/logifix-handoff.log"
LOCK_DIR="/var/run/logifix.lock"

READY_TIMEOUT=60


log() {
    local msg

    msg="$(date '+%Y-%m-%d %H:%M:%S') | $*"

    echo "$msg"
    echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
}


load_managed_users() {
    local line

    MANAGED_USERS=()

    if [[ ! -f "$CONFIG_FILE" ]]; then
        log "ERROR: configuration file does not exist:"
        log "$CONFIG_FILE"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do

        line="${line%%#*}"

        line="$(
            printf '%s' "$line" |
            /usr/bin/sed \
                's/^[[:space:]]*//;s/[[:space:]]*$//'
        )"

        [[ -z "$line" ]] && continue

        if ! /usr/bin/id "$line" >/dev/null 2>&1; then
            log "WARNING: configured user does not exist: $line"
            continue
        fi

        MANAGED_USERS[${#MANAGED_USERS[@]}]="$line"

    done < "$CONFIG_FILE"

    if [[ ${#MANAGED_USERS[@]} -eq 0 ]]; then
        log "ERROR: no valid managed users are configured."
        return 1
    fi

    return 0
}


is_managed_user() {
    local candidate="$1"
    local user

    for user in "${MANAGED_USERS[@]}"; do
        if [[ "$candidate" == "$user" ]]; then
            return 0
        fi
    done

    return 1
}


get_uid() {
    /usr/bin/id -u "$1" 2>/dev/null
}


launch_agent_exists() {
    local uid="$1"

    /bin/launchctl print \
        "gui/${uid}/${LOGI_LAUNCH_AGENT_LABEL}" \
        >/dev/null 2>&1
}


plugin_pids_for_uid() {
    local uid="$1"

    /usr/bin/pgrep \
        -u "$uid" \
        -f "${PLUGIN_ROOT}/" \
        2>/dev/null || true
}


any_plugin_components_running() {
    /usr/bin/pgrep \
        -f "${PLUGIN_ROOT}/" \
        >/dev/null 2>&1
}


stop_launch_agent() {
    local user="$1"
    local uid="$2"

    if ! launch_agent_exists "$uid"; then
        log "Options+ LaunchAgent is not loaded for $user"
        return 0
    fi

    log "Stopping Options+ LaunchAgent for $user (UID $uid)"

    /bin/launchctl bootout \
        "gui/${uid}/${LOGI_LAUNCH_AGENT_LABEL}" \
        2>/dev/null || true
}


terminate_plugin_family_for_user() {
    local user="$1"
    local uid="$2"
    local pids

    pids="$(plugin_pids_for_uid "$uid")"

    if [[ -z "$pids" ]]; then
        log "No LogiPluginService components running for $user"
        return 0
    fi

    log "Stopping LogiPluginService components for $user: PID(s) $pids"

    /bin/kill -TERM $pids 2>/dev/null || true

    for _ in {1..20}; do

        /bin/sleep 0.25

        pids="$(plugin_pids_for_uid "$uid")"

        if [[ -z "$pids" ]]; then
            log "All LogiPluginService components exited for $user"
            return 0
        fi

    done

    pids="$(plugin_pids_for_uid "$uid")"

    if [[ -n "$pids" ]]; then
        log "Components still running; sending SIGKILL: $pids"

        /bin/kill -KILL $pids 2>/dev/null || true
        /bin/sleep 1
    fi

    pids="$(plugin_pids_for_uid "$uid")"

    if [[ -n "$pids" ]]; then
        log "ERROR: PluginService components remain for $user:"
        log "$pids"
        return 1
    fi

    log "All LogiPluginService components stopped for $user"

    return 0
}


remove_known_socket() {
    local socket="$1"

    if [[ ! -S "$socket" ]]; then
        log "Socket absent: $socket"
        return 0
    fi

    if any_plugin_components_running; then
        log "ERROR: a LogiPluginService component is still running."
        log "Refusing to remove socket:"
        log "$socket"
        return 1
    fi

    log "Removing stale Logitech socket: $socket"

    /bin/rm -f -- "$socket"
}


start_launch_agent() {
    local user="$1"
    local uid="$2"
    local pid=""
    local attempt

    if [[ ! -f "$LOGI_LAUNCH_AGENT_PLIST" ]]; then
        log "ERROR: Options+ LaunchAgent plist not found:"
        log "$LOGI_LAUNCH_AGENT_PLIST"
        return 1
    fi

    log "Starting Options+ LaunchAgent for $user (UID $uid)"

    /bin/launchctl bootout \
        "gui/${uid}/${LOGI_LAUNCH_AGENT_LABEL}" \
        2>/dev/null || true

    for _ in {1..20}; do

        if ! launch_agent_exists "$uid"; then
            break
        fi

        /bin/sleep 0.25

    done

    if launch_agent_exists "$uid"; then
        log "ERROR: old Options+ LaunchAgent registration did not disappear."
        return 1
    fi

    for attempt in 1 2 3; do

        if /usr/bin/sudo \
            -u "$user" \
            /bin/launchctl bootstrap \
            "gui/${uid}" \
            "$LOGI_LAUNCH_AGENT_PLIST"
        then
            break
        fi

        log "Bootstrap attempt $attempt failed for $user"

        if [[ $attempt -eq 3 ]]; then
            log "ERROR: unable to bootstrap Options+ for $user"
            return 1
        fi

        /bin/sleep 2

    done

    for _ in {1..40}; do

        pid="$(
            /usr/bin/pgrep \
                -u "$uid" \
                -f '/Library/Application Support/Logitech.localized/LogiOptionsPlus/logioptionsplus_agent.app/Contents/MacOS/logioptionsplus_agent --launchd' \
                2>/dev/null |
            /usr/bin/head -1
        )"

        if [[ -n "$pid" ]]; then
            log "Options+ agent successfully started for $user (PID $pid)"
            return 0
        fi

        /bin/sleep 0.25

    done

    log "ERROR: launchd was bootstrapped but logioptionsplus_agent never started."

    return 1
}


wait_for_plugin_service() {
    local active_uid="$1"
    local main_pid=""
    local native_pid=""
    local elapsed=0

    log "Waiting up to ${READY_TIMEOUT} seconds for LogiPluginService to become ready..."

    while [[ $elapsed -lt $READY_TIMEOUT ]]; do

        main_pid="$(
            /usr/bin/pgrep \
                -u "$active_uid" \
                -f "${PLUGIN_ROOT}/MacOS/LogiPluginService" \
                2>/dev/null |
            /usr/bin/head -1
        )"

        native_pid="$(
            /usr/bin/pgrep \
                -u "$active_uid" \
                -f "${PLUGIN_ROOT}/MonoBundle/.*LogiPluginServiceNative" \
                2>/dev/null |
            /usr/bin/head -1
        )"

        if [[ -n "$main_pid" \
              && -n "$native_pid" \
              && -S "/private/tmp/LogiPluginService" ]]
        then
            log "LogiPluginService is ready."
            log "Main PID:   $main_pid"
            log "Native PID: $native_pid"

            return 0
        fi

        /bin/sleep 1
        elapsed=$((elapsed + 1))

    done

    log "ERROR: LogiPluginService did not fully become ready within ${READY_TIMEOUT} seconds."

    return 1
}


acquire_lock() {
    if /bin/mkdir "$LOCK_DIR" 2>/dev/null; then
        trap '/bin/rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT INT TERM
        return 0
    fi

    log "Another LogiFix handoff is already running."
    return 1
}


if [[ $EUID -ne 0 ]]; then
    echo "LogiFix handoff must run as root." >&2
    exit 1
fi

load_managed_users || exit 1

ACTIVE_USER="$(
    /usr/bin/stat -f '%Su' /dev/console 2>/dev/null
)"

case "$ACTIVE_USER" in
    ""|root|loginwindow|_mbsetupuser)
        log "No usable console user is currently active."
        exit 0
        ;;
esac

if ! is_managed_user "$ACTIVE_USER"; then
    log "Active console user '$ACTIVE_USER' is not managed by LogiFix."
    log "No Logitech handoff will be performed."
    exit 0
fi

ACTIVE_UID="$(get_uid "$ACTIVE_USER")"

if [[ -z "$ACTIVE_UID" ]]; then
    log "ERROR: unable to resolve active user's UID."
    exit 1
fi

acquire_lock || exit 1

log "======================================================"
log "LogiFix handoff"
log "Active user: $ACTIVE_USER ($ACTIVE_UID)"
log "Managed users: ${MANAGED_USERS[*]}"
log "======================================================"

for user in "${MANAGED_USERS[@]}"; do

    uid="$(get_uid "$user")"

    [[ -z "$uid" ]] && continue

    stop_launch_agent "$user" "$uid"

done

for user in "${MANAGED_USERS[@]}"; do

    uid="$(get_uid "$user")"

    [[ -z "$uid" ]] && continue

    terminate_plugin_family_for_user \
        "$user" \
        "$uid" || exit 1

done

if any_plugin_components_running; then

    log "ERROR: a LogiPluginService process remains after configured users were stopped."
    log "It may belong to an unmanaged user."
    log "Refusing to remove shared IPC sockets."

    /usr/bin/pgrep \
        -alf "${PLUGIN_ROOT}/" \
        2>/dev/null || true

    exit 1
fi

remove_known_socket \
    "/private/tmp/LogiPluginService" || exit 1

for user in "${MANAGED_USERS[@]}"; do

    remove_known_socket \
        "/private/tmp/LogiPluginServiceControlBus_${user}" || exit 1

done

start_launch_agent \
    "$ACTIVE_USER" \
    "$ACTIVE_UID" || exit 1

wait_for_plugin_service \
    "$ACTIVE_UID" || exit 1

log "----- Logitech processes after handoff -----"

/usr/bin/pgrep \
    -alf 'logioptionsplus_agent|LogiPluginService' \
    2>/dev/null || log "No matching Logitech processes found."

log "----- Logitech IPC sockets after handoff -----"

/usr/bin/find /private/tmp \
    -maxdepth 1 \
    -type s \
    \( -name 'LogiPluginService' \
       -o -name 'LogiPluginServiceControlBus_*' \) \
    -print \
    2>/dev/null || true

log "======================================================"
log "LogiFix handoff complete."
log "======================================================"

exit 0
