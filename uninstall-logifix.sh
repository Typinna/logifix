#!/bin/bash

set -u

PROJECT_NAME="LogiFix"

INSTALL_DIR="/Library/Application Support/${PROJECT_NAME}"

PLIST_NAME="com.local.logifix.plist"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_NAME}"
SERVICE_LABEL="com.local.logifix"

STATE_FILE="/var/run/logifix.last-user"
LOCK_DIR="/var/run/logifix.lock"

LOG_FILES=(
    "/var/log/logifix-handoff.log"
    "/var/log/logifix-watcher.log"
    "/var/log/logifix-launchd.log"
    "/var/log/logifix-launchd-error.log"
)

KEEP_LOGS=0


die() {
    echo
    echo "ERROR: $*" >&2
    exit 1
}


usage() {
    cat <<'EOF'
Usage:

  sudo ./uninstall-logifix.sh
  sudo ./uninstall-logifix.sh --keep-logs

Options:

  --keep-logs
      Remove LogiFix but retain its diagnostic files in /var/log.
EOF
}


require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "Run this uninstaller with sudo:

  sudo ./uninstall-logifix.sh"
    fi
}


parse_arguments() {
    while [[ $# -gt 0 ]]; do

        case "$1" in

            --keep-logs)
                KEEP_LOGS=1
                ;;

            -h|--help)
                usage
                exit 0
                ;;

            *)
                die "Unknown argument: $1"
                ;;

        esac

        shift

    done
}


stop_daemon() {
    echo "Stopping LogiFix LaunchDaemon..."

    /bin/launchctl bootout \
        "system/${SERVICE_LABEL}" \
        >/dev/null 2>&1 || true
}


remove_launchdaemon_file() {
    if [[ -f "$PLIST_PATH" ]]; then
        echo "Removing LogiFix LaunchDaemon plist..."
        /bin/rm -f "$PLIST_PATH"
    fi
}


remove_runtime_state() {
    /bin/rm -f "$STATE_FILE"

    /bin/rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}


remove_installation() {
    if [[ -d "$INSTALL_DIR" ]]; then
        echo "Removing LogiFix files..."
        /bin/rm -rf "$INSTALL_DIR"
    fi
}


remove_logs() {
    if [[ $KEEP_LOGS -eq 1 ]]; then
        echo "Keeping LogiFix diagnostic logs."
        return 0
    fi

    echo "Removing LogiFix logs..."

    local file

    for file in "${LOG_FILES[@]}"; do
        /bin/rm -f "$file"
    done
}


print_summary() {
    echo
    echo "======================================================"
    echo "LogiFix removed"
    echo "======================================================"
    echo
    echo "Removed:"
    echo "  $INSTALL_DIR"
    echo "  $PLIST_PATH"
    echo
    echo "Logi Options+ itself was not removed or modified."
    echo
    echo "Logitech settings, databases, device profiles,"
    echo "Bluetooth pairings, and Keychain data were not removed."

    if [[ $KEEP_LOGS -eq 1 ]]; then
        echo
        echo "Diagnostic logs were preserved in /var/log."
    fi

    echo
    echo "Logi Options+ will now use its normal macOS launch behavior."
    echo
}


require_root
parse_arguments "$@"

stop_daemon
remove_launchdaemon_file
remove_runtime_state
remove_installation
remove_logs
print_summary

exit 0
