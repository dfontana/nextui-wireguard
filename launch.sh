#!/bin/sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
set -x

rm -f "$LOGS_PATH/$PAK_NAME.txt"
exec >>"$LOGS_PATH/$PAK_NAME.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1
mkdir -p "$USERDATA_PATH/$PAK_NAME"

export PATH="$PAK_DIR/bin/arm64:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"

HUMAN_READABLE_NAME="WireGuard VPN"
WG_CONF_IMPORT_PATH="$SDCARD_PATH/wg0.conf"
WG_CONF_STORED="$USERDATA_PATH/$PAK_NAME/wg0.conf"

# ---------------------------------------------------------------------------
# UI helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Boot hook management
# ---------------------------------------------------------------------------

disable_start_on_boot() {
    sed -i "/${PAK_NAME}.pak-on-boot/d" "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    sync
    return 0
}

enable_start_on_boot() {
    if [ ! -f "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh" ]; then
        printf '#!/bin/sh\n\n' >"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    fi
    echo "test -f \"$PAK_DIR/bin/on-boot\" && \"$PAK_DIR/bin/on-boot\" # ${PAK_NAME}.pak-on-boot" \
        >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    chmod +x "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    sync
    return 0
}

will_start_on_boot() {
    grep -q "${PAK_NAME}.pak-on-boot" "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# WireGuard interface management
# NOTE: wireguard_up/down/is_wireguard_up are duplicated in bin/on-boot.
# Changes here must be mirrored there (and vice versa).
# ---------------------------------------------------------------------------

is_wireguard_up() {
    ip link show wg0 >/dev/null 2>&1
}

get_wireguard_ip() {
    ip addr show wg0 2>/dev/null | awk '/inet /{print $2}' | head -1
}

get_last_handshake() {
    ts=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
    if [ -z "$ts" ] || [ "$ts" = "0" ]; then
        echo "None"
        return
    fi
    now=$(date +%s)
    diff=$((now - ts))
    if [ "$diff" -lt 60 ]; then
        echo "${diff}s ago"
    elif [ "$diff" -lt 3600 ]; then
        echo "$((diff / 60))m ago"
    else
        echo "$((diff / 3600))h ago"
    fi
}

wireguard_up() {
    conf="$WG_CONF_STORED"

    # Parse [Interface] section
    private_key=$(awk '/^\[Interface\]/{f=1} f && /^\[Peer\]/{f=0} f && /^PrivateKey/{print}' "$conf" \
        | awk -F'=' '{print $2}' | tr -d ' \t')
    address=$(awk '/^\[Interface\]/{f=1} f && /^\[Peer\]/{f=0} f && /^Address/{print}' "$conf" \
        | awk -F'=' '{print $2}' | tr -d ' \t')

    # Parse [Peer] section
    peer_pubkey=$(awk '/^\[Peer\]/{f=1} f && /^PublicKey/{print}' "$conf" \
        | awk -F'=' '{print $2}' | tr -d ' \t')
    endpoint=$(awk '/^\[Peer\]/{f=1} f && /^Endpoint/{print}' "$conf" \
        | awk -F'[=]' '{sub(/^[^=]+=/, ""); print}' | tr -d ' \t')
    allowed_ips=$(awk '/^\[Peer\]/{f=1} f && /^AllowedIPs/{print}' "$conf" \
        | awk -F'=' '{print $2}' | tr -d ' \t')
    keepalive=$(awk '/^\[Peer\]/{f=1} f && /^PersistentKeepalive/{print}' "$conf" \
        | awk -F'=' '{print $2}' | tr -d ' \t')

    if [ -z "$private_key" ] || [ -z "$address" ] || [ -z "$peer_pubkey" ] || [ -z "$endpoint" ]; then
        echo "ERROR: wg0.conf is missing required fields"
        return 1
    fi

    # Load kernel module or fall back to wireguard-go
    if modprobe wireguard 2>/dev/null || grep -q '^wireguard ' /proc/modules 2>/dev/null; then
        echo "Using kernel WireGuard module"
        ip link add dev wg0 type wireguard 2>/dev/null || true
    elif command -v wireguard-go >/dev/null 2>&1; then
        echo "Kernel module unavailable, starting wireguard-go"
        wireguard-go wg0 &
        i=0
        while [ "$i" -lt 5 ] && ! ip link show wg0 >/dev/null 2>&1; do
            sleep 1
            i=$((i + 1))
        done
        if ! ip link show wg0 >/dev/null 2>&1; then
            echo "ERROR: wireguard-go failed to create wg0 interface"
            return 1
        fi
    else
        echo "ERROR: no WireGuard driver available"
        return 1
    fi

    # Write private key to temp file
    tmpkey=$(mktemp)
    printf '%s\n' "$private_key" >"$tmpkey"

    # Configure WireGuard interface
    if [ -n "$keepalive" ]; then
        wg set wg0 \
            private-key "$tmpkey" \
            peer "$peer_pubkey" \
            endpoint "$endpoint" \
            allowed-ips "$allowed_ips" \
            persistent-keepalive "$keepalive"
    else
        wg set wg0 \
            private-key "$tmpkey" \
            peer "$peer_pubkey" \
            endpoint "$endpoint" \
            allowed-ips "$allowed_ips"
    fi
    wg_exit=$?
    rm -f "$tmpkey"

    if [ "$wg_exit" -ne 0 ]; then
        echo "ERROR: wg set failed"
        ip link del wg0 2>/dev/null || true
        return 1
    fi

    ip addr add "$address" dev wg0 2>/dev/null || true
    ip link set up dev wg0

    # Add routes for AllowedIPs
    echo "$allowed_ips" | tr ',' '\n' | while read -r cidr; do
        cidr=$(echo "$cidr" | tr -d ' \t')
        [ -n "$cidr" ] && ip route add "$cidr" dev wg0 2>/dev/null || true
    done

    echo "WireGuard interface wg0 is up"
}

wireguard_down() {
    ip link del dev wg0 2>/dev/null || true
    killall wireguard-go 2>/dev/null || true
}

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
    minui_list_file="/tmp/${PAK_NAME}-settings.json"
    rm -f "$minui_list_file"

    # Write to temp file rather than piping/heredoc — BusyBox ash has
    # inconsistent heredoc behavior when piped to commands like jq.
    jq -rM '{settings: .settings}' "$PAK_DIR/config.json" >"$minui_list_file"

    if is_wireguard_up; then
        jq '.settings[0].selected = 1' "$minui_list_file" >"$minui_list_file.tmp"
        mv "$minui_list_file.tmp" "$minui_list_file"
    fi

    if will_start_on_boot; then
        jq '.settings[1].selected = 1' "$minui_list_file" >"$minui_list_file.tmp"
        mv "$minui_list_file.tmp" "$minui_list_file"
    fi

    cat "$minui_list_file"
}

main_screen() {
    settings="$1"
    minui_list_file="/tmp/${PAK_NAME}-minui-list.json"
    rm -f "$minui_list_file"

    echo "$settings" >"$minui_list_file"

    if is_wireguard_up; then
        ip_address="$(get_wireguard_ip)"
        if [ -n "$ip_address" ]; then
            jq --arg ip "$ip_address" \
                '.settings[.settings | length] |= . + {"name": "Address", "options": [$ip], "selected": 0, "features": {"unselectable": true}}' \
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
    rm -f "/tmp/${PAK_NAME}-old-settings.json"
    rm -f "/tmp/${PAK_NAME}-new-settings.json"
    rm -f "/tmp/${PAK_NAME}-settings.json"
    rm -f "/tmp/${PAK_NAME}-minui-list.json"
    rm -f /tmp/stay_awake
    killall minui-presenter >/dev/null 2>&1 || true
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
        show_message "No WireGuard config found.\nDrop wg0.conf at SD card root and relaunch." 5
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

        echo "$settings" >"/tmp/${PAK_NAME}-old-settings.json"
        echo "$new_settings" >"/tmp/${PAK_NAME}-new-settings.json"

        old_enabled="$(jq -rM '.settings[0].selected' "/tmp/${PAK_NAME}-old-settings.json")"
        enabled="$(jq -rM '.settings[0].selected' "/tmp/${PAK_NAME}-new-settings.json")"

        old_start_on_boot="$(jq -rM '.settings[1].selected' "/tmp/${PAK_NAME}-old-settings.json")"
        start_on_boot="$(jq -rM '.settings[1].selected' "/tmp/${PAK_NAME}-new-settings.json")"

        if [ "$old_enabled" != "$enabled" ]; then
            if [ "$enabled" = "1" ]; then
                show_message "Starting $HUMAN_READABLE_NAME..." forever
                if wireguard_up; then
                    killall minui-presenter >/dev/null 2>&1 || true
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
