#!/bin/bash

set -u

PROJECT_NAME="LogiFix"

INSTALL_DIR="/Library/Application Support/${PROJECT_NAME}"
CONFIG_FILE="${INSTALL_DIR}/users.conf"

HANDOFF_FILE="${INSTALL_DIR}/logifix-handoff.sh"
WATCHER_FILE="${INSTALL_DIR}/logifix-watcher.sh"

PLIST_NAME="com.local.logifix.plist"
PLIST_DEST="/Library/LaunchDaemons/${PLIST_NAME}"
SERVICE_LABEL="com.local.logifix"

STATE_FILE="/var/run/logifix.last-user"
LOCK_DIR="/var/run/logifix.lock"

LOGI_LAUNCH_AGENT="/Library/LaunchAgents/com.logi.optionsplus.plist"
PLUGIN_APP="/Applications/Utilities/LogiPluginService.app"

SCRIPT_DIR="$(
    cd -- "$(dirname -- "$0")" >/dev/null 2>&1
    pwd
)"

SOURCE_HANDOFF="${SCRIPT_DIR}/logifix-handoff.sh"
SOURCE_WATCHER="${SCRIPT_DIR}/logifix-watcher.sh"
SOURCE_PLIST="${SCRIPT_DIR}/${PLIST_NAME}"

MANAGED_USERS=()
CONFIG_SOURCE=""


die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}


info() {
    echo "$*"
}


require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Run this installer with sudo:

  sudo ./install-logifix.sh"
    fi
}


validate_source_files() {
    local file

    for file in \
        "$SOURCE_HANDOFF" \
        "$SOURCE_WATCHER" \
        "$SOURCE_PLIST"
    do
        [[ -f "$file" ]] || \
            die "Required repository file is missing:

  $file"
    done

    /bin/bash -n "$SOURCE_HANDOFF" || \
        die "logifix-handoff.sh failed shell syntax validation."

    /bin/bash -n "$SOURCE_WATCHER" || \
        die "logifix-watcher.sh failed shell syntax validation."

    /usr/bin/plutil -lint "$SOURCE_PLIST" >/dev/null || \
        die "${PLIST_NAME} failed plist validation."
}


check_logitech_installation() {
    [[ -f "$LOGI_LAUNCH_AGENT" ]] || \
        die "Logi Options+ LaunchAgent was not found:

  $LOGI_LAUNCH_AGENT

Is Logi Options+ installed?"

    [[ -d "$PLUGIN_APP" ]] || \
        die "LogiPluginService was not found:

  $PLUGIN_APP

Is Logi Options+ installed?"
}


valid_local_user() {
    local user="$1"
    local uid

    /usr/bin/id "$user" >/dev/null 2>&1 || return 1

    uid="$(
        /usr/bin/id -u "$user" 2>/dev/null
    )" || return 1

    [[ "$uid" =~ ^[0-9]+$ ]] || return 1
    [[ "$uid" -ge 500 ]] || return 1

    return 0
}


add_user_if_valid() {
    local candidate="$1"
    local existing

    [[ -n "$candidate" ]] || return 0

    if ! valid_local_user "$candidate"; then
        die "Not a valid interactive local macOS user: $candidate"
    fi

    for existing in "${MANAGED_USERS[@]}"; do
        if [[ "$existing" == "$candidate" ]]; then
            return 0
        fi
    done

    MANAGED_USERS[${#MANAGED_USERS[@]}]="$candidate"
}


load_users_from_config() {
    local file="$1"
    local line

    [[ -f "$file" ]] || return 1

    MANAGED_USERS=()

    while IFS= read -r line || [[ -n "$line" ]]; do

        line="${line%%#*}"

        line="$(
            printf '%s' "$line" |
            /usr/bin/sed \
                's/^[[:space:]]*//;s/[[:space:]]*$//'
        )"

        [[ -z "$line" ]] && continue

        if valid_local_user "$line"; then
            add_user_if_valid "$line"
        fi

    done < "$file"

    [[ ${#MANAGED_USERS[@]} -ge 2 ]]
}


show_detected_users() {
    echo
    echo "Detected local interactive users:"
    echo

    /usr/bin/dscl . -list /Users UniqueID 2>/dev/null |
    /usr/bin/awk '
        $2 >= 500 &&
        $1 !~ /^_/ &&
        $1 != "nobody" {
            printf "  %-25s UID %s\n", $1, $2
        }
    '

    echo
}


collect_users() {
    MANAGED_USERS=()
    CONFIG_SOURCE=""

    if [[ $# -gt 0 ]]; then

        local user

        for user in "$@"; do
            add_user_if_valid "$user"
        done

        CONFIG_SOURCE="command line"

    elif load_users_from_config "$CONFIG_FILE"; then

        CONFIG_SOURCE="$CONFIG_FILE"

        info "Existing LogiFix user configuration found."
        info "Keeping configured users: ${MANAGED_USERS[*]}"

    else

        show_detected_users

        echo "Enter the macOS short usernames that should participate"
        echo "in LogiFix Fast User Switching."
        echo
        echo "Separate usernames with spaces."
        echo
        printf "> "

        local input
        IFS= read -r input

        [[ -n "$input" ]] || \
            die "No users were entered."

        local user

        for user in $input; do
            add_user_if_valid "$user"
        done

        CONFIG_SOURCE="interactive input"
    fi

    if [[ ${#MANAGED_USERS[@]} -lt 2 ]]; then
        die "At least two valid macOS users must be configured."
    fi
}


stop_existing_daemon() {
    /bin/launchctl bootout \
        "system/${SERVICE_LABEL}" \
        >/dev/null 2>&1 || true
}


write_config() {
    {
        echo "# LogiFix managed macOS users"
        echo "#"
        echo "# One macOS short username per line."
        echo "# Blank lines and lines beginning with # are ignored."
        echo

        local user

        for user in "${MANAGED_USERS[@]}"; do
            echo "$user"
        done

    } > "$CONFIG_FILE"

    /usr/sbin/chown root:wheel "$CONFIG_FILE"
    /bin/chmod 644 "$CONFIG_FILE"
}


install_files() {
    info
    info "Installing LogiFix..."

    /bin/mkdir -p "$INSTALL_DIR"

    /usr/sbin/chown root:wheel "$INSTALL_DIR"
    /bin/chmod 755 "$INSTALL_DIR"

    /bin/cp "$SOURCE_HANDOFF" "$HANDOFF_FILE"
    /bin/cp "$SOURCE_WATCHER" "$WATCHER_FILE"
    /bin/cp "$SOURCE_PLIST" "$PLIST_DEST"

    /usr/sbin/chown root:wheel \
        "$HANDOFF_FILE" \
        "$WATCHER_FILE" \
        "$PLIST_DEST"

    /bin/chmod 755 \
        "$HANDOFF_FILE" \
        "$WATCHER_FILE"

    /bin/chmod 644 "$PLIST_DEST"

    write_config
}


validate_installed_files() {
    /bin/bash -n "$HANDOFF_FILE" || \
        die "Installed handoff script failed validation."

    /bin/bash -n "$WATCHER_FILE" || \
        die "Installed watcher script failed validation."

    /usr/bin/plutil -lint "$PLIST_DEST" >/dev/null || \
        die "Installed LaunchDaemon plist failed validation."
}


clear_runtime_state() {
    /bin/rm -f "$STATE_FILE"
    /bin/rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}


start_daemon() {
    /bin/launchctl bootstrap \
        system \
        "$PLIST_DEST" || \
        die "launchd could not bootstrap the LogiFix daemon."

    /bin/sleep 2
}


verify_daemon() {
    if ! /bin/launchctl print \
        "system/${SERVICE_LABEL}" \
        >/dev/null 2>&1
    then
        die "The LaunchDaemon was installed but is not registered with launchd."
    fi

    local state

    state="$(
        /bin/launchctl print \
            "system/${SERVICE_LABEL}" \
            2>/dev/null |
        /usr/bin/awk -F'= ' '
            /^[[:space:]]*state =/ {
                gsub(/[[:space:]]/, "", $2)
                print $2
                exit
            }
        '
    )"

    if [[ "$state" != "running" ]]; then
        echo
        echo "WARNING: LogiFix is registered with launchd but reported:"
        echo
        echo "  state = ${state:-unknown}"
        echo
        echo "Check:"
        echo
        echo "  /var/log/logifix-launchd-error.log"
        echo
        return 1
    fi

    return 0
}


print_summary() {
    echo
    echo "======================================================"
    echo "LogiFix installed successfully"
    echo "======================================================"
    echo
    echo "Managed users:"

    local user

    for user in "${MANAGED_USERS[@]}"; do
        echo "  - $user"
    done

    echo
    echo "Configuration source:"
    echo "  $CONFIG_SOURCE"
    echo
    echo "Installed files:"
    echo "  $INSTALL_DIR"
    echo "  $PLIST_DEST"
    echo
    echo "LogiFix is running and will start automatically"
    echo "when macOS boots."
    echo
    echo "No command needs to be run when Fast User Switching."
    echo
    echo "Watcher log:"
    echo "  /var/log/logifix-watcher.log"
    echo
    echo "Handoff log:"
    echo "  /var/log/logifix-handoff.log"
    echo
    echo "To uninstall:"
    echo "  sudo ./uninstall-logifix.sh"
    echo
}


require_root
validate_source_files
check_logitech_installation
collect_users "$@"

stop_existing_daemon
install_files
validate_installed_files
clear_runtime_state
start_daemon

if ! verify_daemon; then
    die "LogiFix installation could not be verified."
fi

print_summary

exit 0
