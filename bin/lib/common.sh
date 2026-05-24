# Common helpers shared by launch.sh and bin/on-boot.
# This file is sourced, not executed. Do not add a shebang.
#
# Requires the following env vars from the NextUI pak environment:
#   PAK_DIR     pak install directory (caller derives from $0)
#   PLATFORM    e.g. "tg5040"
#   LOGS_PATH   e.g. /mnt/SDCARD/.userdata/tg5040/logs

init_logging() {
    log_name="$1"
    # mkdir before redirect — if $LOGS_PATH doesn't exist, `exec >>` silently
    # fails on BusyBox ash and all subsequent output is lost.
    mkdir -p "$LOGS_PATH"
    mv -f "$LOGS_PATH/$log_name" "$LOGS_PATH/$log_name.prev" 2>/dev/null || true
    exec >>"$LOGS_PATH/$log_name"
    exec 2>&1
}

init_path() {
    export PATH="$PAK_DIR/bin/arm64:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"
}

show_message() {
    message="$1"
    seconds="$2"

    if [ -z "$seconds" ]; then
        seconds="forever"
    fi

    killall minui-presenter >/dev/null 2>&1 || true
    echo "$message" 1>&2
    if [ "$seconds" = "forever" ]; then
        minui-presenter --message "$message" --timeout -1 &
    else
        minui-presenter --message "$message" --timeout "$seconds"
    fi
}
