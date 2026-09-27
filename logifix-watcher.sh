#!/bin/bash

set -u

BASE_DIR="/Library/Application Support/LogiFix"
CONFIG_FILE="${BASE_DIR}/users.conf"
HANDOFF_SCRIPT="${BASE_DIR}/logifix-handoff.sh"

STATE_FILE="/var/run/logifix.last-user"
WATCH_LOG="/var/log/logifix-watcher.log"

POLL_INTERVAL=2


log() {
    local msg

    msg="$(date '+%Y-%m-%d %H:%M:%S') | $*"

    echo "$msg"
    echo "$msg" >> "$WATCH_LOG" 2>/dev/null || true
}


load_managed_users() {
    local line

    MANAGED_USERS=()

    [[ -f "$CONFIG_FILE" ]] || return 1

    while IFS= read -r line || [[ -n "$line" ]]; do

        line="${line%%#*}"

        line="$(
            printf '%s' "$line" |
            /usr/bin/sed \
                's/^[[:space:]]*//;s/[[:space:]]*$//'
        )"

        [[ -z "$line" ]] && continue

        if /usr/bin/id "$line" >/dev/null 2>&1; then
            MANAGED_USERS[${#MANAGED_USERS[@]}]="$line"
        fi

    done < "$CONFIG_FILE"

    [[ ${#MANAGED_USERS[@]} -gt 0 ]]
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


get_console_user() {
    /usr/bin/stat -f '%Su' /dev/console 2>/dev/null
}


set_baseline() {
    local user="$1"

    LAST_USER="$user"
    BASELINE_SET=1

    printf '%s\n' "$LAST_USER" > "$STATE_FILE"

    log "Initial active managed user: $LAST_USER"
    log "Waiting for console-user change."
}


if [[ $EUID -ne 0 ]]; then
    echo "LogiFix watcher must run as root." >&2
    exit 1
fi

if [[ ! -x "$HANDOFF_SCRIPT" ]]; then
    log "ERROR: handoff script is missing or not executable:"
    log "$HANDOFF_SCRIPT"
    exit 1
fi

if ! load_managed_users; then
    log "ERROR: no valid managed users found."
    exit 1
fi

LAST_USER=""
BASELINE_SET=0

log "======================================================"
log "LogiFix console-user watcher started"
log "Managed users: ${MANAGED_USERS[*]}"
log "Poll interval: ${POLL_INTERVAL}s"
log "======================================================"

CURRENT_USER="$(get_console_user)"

if is_managed_user "$CURRENT_USER"; then
    set_baseline "$CURRENT_USER"
else
    /bin/rm -f "$STATE_FILE"

    log "No managed user currently owns the console."
    log "The first managed user observed will become the baseline."
fi


while true; do

    /bin/sleep "$POLL_INTERVAL"

    if ! load_managed_users; then
        log "WARNING: users.conf currently contains no valid managed users."
        continue
    fi

    CURRENT_USER="$(get_console_user)"

    case "$CURRENT_USER" in
        ""|root|loginwindow|_mbsetupuser)
            continue
            ;;
    esac

    if ! is_managed_user "$CURRENT_USER"; then
        continue
    fi

    if [[ $BASELINE_SET -eq 0 ]]; then
        set_baseline "$CURRENT_USER"
        continue
    fi

    if [[ "$CURRENT_USER" == "$LAST_USER" ]]; then
        continue
    fi

    TARGET_USER="$CURRENT_USER"

    log "Console-user change detected: $LAST_USER -> $TARGET_USER"

    if "$HANDOFF_SCRIPT"; then

        LAST_USER="$TARGET_USER"

        printf '%s\n' "$LAST_USER" > "$STATE_FILE"

        log "Automatic LogiFix handoff completed for $TARGET_USER"

    else

        EXIT_CODE=$?

        log "WARNING: automatic LogiFix handoff failed for $TARGET_USER (exit $EXIT_CODE)"
        log "The watcher will retry if that user remains active."

        /bin/sleep 10

    fi

done
