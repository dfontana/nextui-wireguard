# WireGuard interface lifecycle: bring wg0 up from a wg-quick-style conf,
# tear it down, and inspect runtime state.
# Sourced by launch.sh and bin/on-boot. Do not add a shebang.
#
# Requires on PATH: ip, wg, modprobe, awk, sed, tr, grep, nslookup, mktemp
# Optional on PATH: wireguard-go (userspace driver; required on devices
#                   without a kernel wireguard module — confirmed required
#                   on TrimUI Brick, see docs/trimui-device-notes.md)

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

# wireguard_up <conf_path>
wireguard_up() {
    conf="$1"

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

    # Load kernel module or fall back to wireguard-go userspace driver.
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

    # Configure the WireGuard interface
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
