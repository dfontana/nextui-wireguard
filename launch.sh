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
}

enable_start_on_boot() {
    if [ ! -f "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh" ]; then
        echo '#!/bin/sh' >"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
        echo '' >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    fi
    echo "test -f \"\$SDCARD_PATH/Tools/\$PLATFORM/$PAK_NAME.pak/bin/on-boot\" && \"\$SDCARD_PATH/Tools/\$PLATFORM/$PAK_NAME.pak/bin/on-boot\" # ${PAK_NAME}.pak-on-boot" >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    chmod +x "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    sync
}

will_start_on_boot() {
    grep -q "${PAK_NAME}.pak-on-boot" "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
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
    ip addr show wg0 2>/dev/null | awk '/inet /{print $2; exit}'
}

get_last_handshake() {
    ts=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')
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
    dns=$(awk '/^\[Interface\]/{f=1} f && /^\[Peer\]/{f=0} f && /^DNS/{print}' "$conf" \
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
    psk=$(awk '/^\[Peer\]/{f=1} f && /^PresharedKey/{print}' "$conf" \
        | awk -F'=' '{print $2}' | tr -d ' \t')

    if [ -z "$private_key" ] || [ -z "$address" ] || [ -z "$peer_pubkey" ] || [ -z "$endpoint" ]; then
        echo "ERROR: wg0.conf is missing required fields"
        return 1
    fi

    # Detect full-tunnel mode (AllowedIPs = 0.0.0.0/0)
    full_tunnel=0
    if echo "$allowed_ips" | tr ',' '\n' | tr -d ' \t' | grep -qxF '0.0.0.0/0'; then
        full_tunnel=1
    fi

    # Full-tunnel pre-flight: capture gateway and pin a host route for the WireGuard
    # endpoint via the original gateway BEFORE the tunnel routes come up. Without this,
    # the encrypted UDP packets to the server would loop through wg0 itself.
    endpoint_ip=""
    gw=""
    gw_dev=""
    if [ "$full_tunnel" = "1" ]; then
        gw=$(ip route show default 2>/dev/null | awk '/default via/{print $3; exit}')
        gw_dev=$(ip route show default 2>/dev/null | awk '/default via/{print $5; exit}')
        if [ -z "$gw" ] || [ -z "$gw_dev" ]; then
            echo "ERROR: cannot determine default gateway for full-tunnel routing"
            return 1
        fi
        endpoint_host=$(echo "$endpoint" | awk -F: '{print $1}')
        if echo "$endpoint_host" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
            endpoint_ip="$endpoint_host"
        else
            endpoint_ip=$(nslookup "$endpoint_host" 2>/dev/null | awk '
                /^Name:/  { found=1 }
                found && /^Address/ {
                    for (i=1; i<=NF; i++)
                        if ($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) { print $i; exit }
                }')
        fi
        if [ -z "$endpoint_ip" ]; then
            echo "ERROR: cannot resolve endpoint $endpoint_host for full-tunnel host route"
            return 1
        fi
        ip route add "$endpoint_ip/32" via "$gw" dev "$gw_dev" 2>/dev/null || true
    fi

    # Load kernel module or fall back to wireguard-go.
    # modprobe may exit 0 even when the module doesn't exist (confirmed on
    # TrimUI Brick / Tina Linux 4.9), so /proc/modules is the authoritative check.
    modprobe wireguard 2>/dev/null
    if grep -q '^wireguard ' /proc/modules 2>/dev/null; then
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
            [ -n "$endpoint_ip" ] && ip route del "$endpoint_ip/32" 2>/dev/null || true
            return 1
        fi
    else
        echo "ERROR: no WireGuard driver available"
        [ -n "$endpoint_ip" ] && ip route del "$endpoint_ip/32" 2>/dev/null || true
        return 1
    fi

    # Write private key to temp file
    tmpkey=$(mktemp)
    printf '%s\n' "$private_key" >"$tmpkey"

    # Write preshared key to temp file if present
    tmpkey_psk=""
    if [ -n "$psk" ]; then
        tmpkey_psk=$(mktemp)
        printf '%s\n' "$psk" >"$tmpkey_psk"
    fi

    # Configure WireGuard interface
    set -- private-key "$tmpkey" peer "$peer_pubkey"
    [ -n "$tmpkey_psk" ] && set -- "$@" preshared-key "$tmpkey_psk"
    set -- "$@" endpoint "$endpoint" allowed-ips "$allowed_ips"
    [ -n "$keepalive" ] && set -- "$@" persistent-keepalive "$keepalive"
    wg set wg0 "$@"
    wg_exit=$?
    rm -f "$tmpkey" "$tmpkey_psk"

    if [ "$wg_exit" -ne 0 ]; then
        echo "ERROR: wg set failed"
        ip link del wg0 2>/dev/null || true
        [ -n "$endpoint_ip" ] && ip route del "$endpoint_ip/32" 2>/dev/null || true
        return 1
    fi

    ip addr add "$address" dev wg0 2>/dev/null || true
    ip link set up dev wg0

    # Add routes
    if [ "$full_tunnel" = "1" ]; then
        # Split 0.0.0.0/0 into two /1s — more specific than the wlan0 default route,
        # so they win longest-prefix-match without displacing it.
        ip route add 0.0.0.0/1 dev wg0 2>/dev/null || true
        ip route add 128.0.0.0/1 dev wg0 2>/dev/null || true
        printf 'endpoint_ip=%s\ngw=%s\ngw_dev=%s\n' \
            "$endpoint_ip" "$gw" "$gw_dev" >/tmp/wg0-state
    else
        echo "$allowed_ips" | tr ',' '\n' | while read -r cidr; do
            cidr=$(echo "$cidr" | tr -d ' \t')
            [ -n "$cidr" ] && ip route add "$cidr" dev wg0 2>/dev/null || true
        done
    fi

    # Apply VPN DNS — only if backup of current resolv.conf succeeds, so we can
    # always restore the original on wireguard_down even if something goes wrong.
    if [ -n "$dns" ]; then
        resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)
        if cp "$resolv_target" /tmp/wg0-dns.bak 2>/dev/null; then
            {
                echo "$dns" | tr ',' '\n' | while read -r server; do
                    server=$(echo "$server" | tr -d ' \t')
                    [ -n "$server" ] && printf 'nameserver %s\n' "$server"
                done
            } >"$resolv_target" || rm -f /tmp/wg0-dns.bak
        else
            echo "WARNING: could not back up resolv.conf, skipping DNS configuration"
        fi
    fi

    echo "WireGuard interface wg0 is up"
}

wireguard_down() {
    # Restore DNS first — before the interface goes down so the original resolver
    # is in place the moment traffic reverts to wlan0.
    if [ -f /tmp/wg0-dns.bak ]; then
        resolv_target=$(readlink -f /etc/resolv.conf 2>/dev/null || echo /etc/resolv.conf)
        cp /tmp/wg0-dns.bak "$resolv_target" 2>/dev/null || true
        rm -f /tmp/wg0-dns.bak
    fi
    # Remove full-tunnel endpoint host route (pinned via wlan0 during wireguard_up).
    # The /1 tunnel routes clean themselves when the interface is deleted.
    if [ -f /tmp/wg0-state ]; then
        _ep=$(grep '^endpoint_ip=' /tmp/wg0-state | cut -d= -f2)
        _gw=$(grep '^gw=' /tmp/wg0-state | cut -d= -f2)
        _gw_dev=$(grep '^gw_dev=' /tmp/wg0-state | cut -d= -f2)
        rm -f /tmp/wg0-state
        [ -n "$_ep" ] && ip route del "$_ep/32" via "$_gw" dev "$_gw_dev" 2>/dev/null || true
    fi
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
