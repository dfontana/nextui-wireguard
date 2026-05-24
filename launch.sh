#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
set -x

. "$PAK_DIR/bin/lib/common.sh"
init_logging "$PAK_NAME.txt"

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/$PAK_NAME"
init_path

. "$PAK_DIR/bin/lib/wireguard.sh"
. "$PAK_DIR/bin/lib/boot-hook.sh"

HUMAN_READABLE_NAME="WireGuard VPN"
WG_CONF_IMPORT_PATH="$SDCARD_PATH/wg0.conf"
WG_CONF_STORED="$USERDATA_PATH/$PAK_NAME/wg0.conf"

# ---------------------------------------------------------------------------
# Config import
# ---------------------------------------------------------------------------

has_config() {
    [ -f "$WG_CONF_STORED" ]
}

import_config() {
    if [ -f "$WG_CONF_IMPORT_PATH" ] && [ -s "$WG_CONF_IMPORT_PATH" ]; then
        mkdir -p "$(dirname "$WG_CONF_STORED")"
        cp "$WG_CONF_IMPORT_PATH" "$WG_CONF_STORED"
        rm -f "$WG_CONF_IMPORT_PATH"
        echo "Config imported from $WG_CONF_IMPORT_PATH"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# Settings UI
# ---------------------------------------------------------------------------

current_settings() {
    is_wireguard_up && up=1 || up=0
    will_start_on_boot && boot=1 || boot=0
    jq -M --argjson up "$up" --argjson boot "$boot" \
        '.settings[0].selected = $up | .settings[1].selected = $boot' \
        "$PAK_DIR/config.json"
}

main_screen() {
    settings="$1"
    minui_list_file="/tmp/${PAK_NAME}-minui-list.json"
    echo "$settings" >"$minui_list_file"

    if is_wireguard_up; then
        ip_address="$(get_wireguard_ip)"
        if [ -n "$ip_address" ]; then
            jq --arg ip "$ip_address" \
                '.settings[.settings | length] |= . + {"name": "Address", "options": [$ip], "selected": 0, "features": {"unselectable": true}}' \
                "$minui_list_file" >"$minui_list_file.tmp"
            mv "$minui_list_file.tmp" "$minui_list_file"
        fi

        endpoint="$(get_endpoint)"
        if [ -n "$endpoint" ]; then
            jq --arg ep "$endpoint" \
                '.settings[.settings | length] |= . + {"name": "Endpoint", "options": [$ep], "selected": 0, "features": {"unselectable": true}}' \
                "$minui_list_file" >"$minui_list_file.tmp"
            mv "$minui_list_file.tmp" "$minui_list_file"
        fi

        handshake="$(get_last_handshake)"
        jq --arg hs "$handshake" \
            '.settings[.settings | length] |= . + {"name": "Handshake", "options": [$hs], "selected": 0, "features": {"unselectable": true}}' \
            "$minui_list_file" >"$minui_list_file.tmp"
        mv "$minui_list_file.tmp" "$minui_list_file"
    fi

    minui-list --file "$minui_list_file" --format json --title "$HUMAN_READABLE_NAME" \
        --confirm-text "SAVE" --item-key "settings" --write-value state
}

cleanup() {
    rm -f "/tmp/${PAK_NAME}-minui-list.json" /tmp/stay_awake
    killall minui-presenter 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

    # Normalize tg3040 → tg5040 (older firmware reports wrong platform for Brick)
    if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
        export DEVICE="brick"
        export PLATFORM="tg5040"
    fi

    # Verify required tools
    for cmd in minui-list minui-presenter jq wg ip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            show_message "$cmd not found." 2
            return 1
        fi
    done

    # Ensure binaries are executable
    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-list"
    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-presenter"
    chmod +x "$PAK_DIR/bin/arm64/jq"
    chmod +x "$PAK_DIR/bin/arm64/wg"
    [ -f "$PAK_DIR/bin/arm64/wireguard-go" ] && \
        chmod +x "$PAK_DIR/bin/arm64/wireguard-go"
    chmod +x "$PAK_DIR/bin/on-boot"

    # Only tg5040 (TrimUI Brick) is supported
    if [ "$PLATFORM" != "tg5040" ]; then
        show_message "$PLATFORM is not a supported platform." 2
        return 1
    fi

    # Import config from SD root if present
    if import_config; then
        show_message "WireGuard config imported." 2
    fi

    # Require a config file before showing the menu
    if ! has_config; then
        show_message "No WireGuard config found.
Drop wg0.conf at SD card root and relaunch." 5
        return 0
    fi

    while true; do
        settings="$(current_settings)"
        new_settings="$(main_screen "$settings")"
        exit_code=$?
        # exit codes: 2 = back button, 3 = menu button
        if [ "$exit_code" -ne 0 ]; then
            break
        fi

        old_enabled="$(echo "$settings" | jq -rM '.settings[0].selected')"
        enabled="$(echo "$new_settings" | jq -rM '.settings[0].selected')"
        old_start_on_boot="$(echo "$settings" | jq -rM '.settings[1].selected')"
        start_on_boot="$(echo "$new_settings" | jq -rM '.settings[1].selected')"

        if [ "$old_enabled" != "$enabled" ]; then
            if [ "$enabled" = "1" ]; then
                show_message "Starting $HUMAN_READABLE_NAME..." forever
                wireguard_up "$WG_CONF_STORED"
                rc=$?
                if [ "$rc" = 0 ]; then
                    killall minui-presenter >/dev/null 2>&1 || true
                elif [ "$rc" = 2 ]; then
                    # Exit code 2 from wireguard_up = WiFi NO-CARRIER. Toggling
                    # WiFi off and on from NextUI's WiFi panel is the known fix.
                    show_message "WiFi link down. Toggle WiFi off and back on, then try again." 5
                else
                    show_message "Failed to start $HUMAN_READABLE_NAME." 3
                fi
            else
                show_message "Stopping $HUMAN_READABLE_NAME..." 2
                wireguard_down
            fi
        fi

        if [ "$old_start_on_boot" != "$start_on_boot" ]; then
            if [ "$start_on_boot" = "1" ]; then
                show_message "Enabling start on boot." 2
                enable_start_on_boot || show_message "Failed to enable start on boot." 2
            else
                show_message "Disabling start on boot." 2
                disable_start_on_boot || show_message "Failed to disable start on boot." 2
            fi
        fi
    done
}

main "$@"
