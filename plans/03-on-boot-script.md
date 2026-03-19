# Task 03: on-boot Script

## Goal
Write `bin/on-boot` — the script that auto-starts the WireGuard connection when the device boots,
if the user has enabled "Start on boot". This is referenced from `auto.sh`.

## How It Gets Called

`launch.sh` appends this line to `$SDCARD_PATH/.userdata/tg5040/auto.sh`:
```sh
test -f "/mnt/sdcard/Tools/tg5040/WireGuard.pak/bin/on-boot" && \
  "/mnt/sdcard/Tools/tg5040/WireGuard.pak/bin/on-boot" # WireGuard.pak-on-boot
```

NextUI sources `auto.sh` during boot before launching the main menu.

## Script Logic

```
1. Set up PAK_DIR, PAK_NAME from script path
2. Redirect stdout+stderr to $LOGS_PATH/WireGuard.on-boot.txt
3. Detect architecture (arm vs arm64)
4. Extend PATH with pak bin dirs
5. Check if WireGuard is already running (wg0 interface exists) → exit if so
6. Check if a saved wg0.conf exists in $USERDATA_PATH/WireGuard/wg0.conf → exit if not
7. Call the wireguard_up() function (shared logic with launch.sh)
```

## Shared wireguard_up() Logic

This function should be identical in both `on-boot` and `launch.sh` (or sourced from a shared
`bin/wireguard-lib.sh` helper):

```sh
wireguard_up() {
    conf="$USERDATA_PATH/$PAK_NAME/wg0.conf"

    # Parse wg0.conf
    private_key=$(awk '/^\[Interface\]/,/^\[/' "$conf" | grep '^PrivateKey' | awk -F= '{print $2}' | tr -d ' ')
    address=$(awk '/^\[Interface\]/,/^\[/' "$conf" | grep '^Address' | awk -F= '{print $2}' | tr -d ' ')
    peer_pubkey=$(awk '/^\[Peer\]/,/^\[/' "$conf" | grep '^PublicKey' | awk -F= '{print $2}' | tr -d ' ')
    endpoint=$(awk '/^\[Peer\]/,/^\[/' "$conf" | grep '^Endpoint' | awk -F= '{print $2}' | tr -d ' ')
    allowed_ips=$(awk '/^\[Peer\]/,/^\[/' "$conf" | grep '^AllowedIPs' | awk -F= '{print $2}' | tr -d ' ')
    keepalive=$(awk '/^\[Peer\]/,/^\[/' "$conf" | grep '^PersistentKeepalive' | awk -F= '{print $2}' | tr -d ' ')

    # Load kernel module or start wireguard-go
    if modprobe wireguard 2>/dev/null || [ -d /sys/module/wireguard ]; then
        ip link add dev wg0 type wireguard 2>/dev/null || true
    else
        wireguard-go wg0 &
        sleep 2  # wait for TUN to initialize
    fi

    # Write private key to temp file (wg set reads from a file)
    tmpkey=$(mktemp)
    echo "$private_key" > "$tmpkey"

    # Configure WireGuard interface
    wg set wg0 private-key "$tmpkey"
    if [ -n "$keepalive" ]; then
        wg set wg0 peer "$peer_pubkey" endpoint "$endpoint" \
            allowed-ips "$allowed_ips" persistent-keepalive "$keepalive"
    else
        wg set wg0 peer "$peer_pubkey" endpoint "$endpoint" allowed-ips "$allowed_ips"
    fi
    rm -f "$tmpkey"

    # Assign IP and bring up interface
    ip addr add "$address" dev wg0 2>/dev/null || true
    ip link set up dev wg0

    # Add routes for all AllowedIPs CIDRs
    echo "$allowed_ips" | tr ',' '\n' | while read -r cidr; do
        cidr=$(echo "$cidr" | tr -d ' ')
        [ -n "$cidr" ] && ip route add "$cidr" dev wg0 2>/dev/null || true
    done
}
```

## wireguard_down() Logic

```sh
wireguard_down() {
    ip link del dev wg0 2>/dev/null || true
    killall wireguard-go 2>/dev/null || true
}
```

## is_wireguard_up() Check

```sh
is_wireguard_up() {
    ip link show wg0 >/dev/null 2>&1
}
```

## Complete on-boot Script

```sh
#!/bin/sh
BIN_DIR="$(dirname "$0")"
PAK_DIR="$(dirname "$BIN_DIR")"
PAK_NAME="$(basename "$PAK_DIR")"
PAK_NAME="${PAK_NAME%.*}"
set -x

rm -f "$LOGS_PATH/$PAK_NAME.on-boot.txt"
exec >>"$LOGS_PATH/$PAK_NAME.on-boot.txt"
exec 2>&1

echo "$0" "$@"
cd "$PAK_DIR" || exit 1

architecture=arm
if uname -m | grep -q '64'; then
    architecture=arm64
fi

export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"

main() {
    if is_wireguard_up; then
        echo "WireGuard already running, skipping boot start."
        return 0
    fi

    if [ ! -f "$USERDATA_PATH/$PAK_NAME/wg0.conf" ]; then
        echo "No wg0.conf found, skipping boot start."
        return 0
    fi

    wireguard_up
}

main "$@"
```

## Steps

1. Create `bin/on-boot` with the content above
2. Make it executable: `chmod +x bin/on-boot`
3. Verify POSIX sh compatibility: `sh -n bin/on-boot` (syntax check)
4. Review all awk/grep patterns handle the wg0.conf format correctly

## Expected Outcome
- `bin/on-boot` is a valid POSIX sh script with no syntax errors
- When called on a device with `$USERDATA_PATH/WireGuard/wg0.conf` present, it brings up `wg0`
- When called without a config, it exits cleanly with a log message
- When `wg0` is already up, it exits cleanly (idempotent)
