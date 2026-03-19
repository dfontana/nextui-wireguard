# Task 04: launch.sh — Main Interactive Script

## Goal
Write `launch.sh` — the main entry point called by NextUI when the user opens the WireGuard pak
from the Tools menu. It provides an interactive settings UI using `minui-list` and `minui-presenter`.

## User Flows

### First Launch (no config imported yet)
1. User opens WireGuard pak from Tools menu
2. Script detects no `wg0.conf` in persistent storage
3. Checks SD root for `wg0.conf`
4. If found: imports it → shows "Config imported!" message
5. Shows main settings menu (Enable is disabled by default)
6. If not found: shows "Drop wg0.conf on SD card root and relaunch" message → exits

### Subsequent Launches (config exists)
1. Shows main settings menu
2. Status info displayed: current IP address, last handshake time (if WireGuard is running)
3. User can toggle Enable (start/stop WireGuard)
4. User can toggle Start on boot

### Config Import Row (additional menu item)
- Add a third action "Import Config" that appears when `wg0.conf` exists at SD root
- Selecting it re-imports the config from SD root (allows updating keys/peers)

## Menu Layout (minui-list JSON)

```json
{
  "settings": [
    {"name": "Enable",        "options": ["false", "true"], "selected": 0},
    {"name": "Start on boot", "options": ["false", "true"], "selected": 0}
  ]
}
```

Dynamic status rows appended when WireGuard is running (unselectable):
- `{"name": "Address", "options": ["10.8.0.2/24"], "selected": 0, "features": {"unselectable": true}}`
- `{"name": "Handshake", "options": ["42 seconds ago"], "selected": 0, "features": {"unselectable": true}}`

## Key Functions

### `get_wireguard_ip()`
```sh
ip addr show wg0 2>/dev/null | awk '/inet /{print $2}' | head -1
```

### `get_last_handshake()`
```sh
# wg show wg0 latest-handshakes outputs: <pubkey>\t<unix_timestamp>
ts=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)
if [ -z "$ts" ] || [ "$ts" = "0" ]; then
    echo "None"
else
    now=$(date +%s)
    diff=$((now - ts))
    if [ $diff -lt 60 ]; then
        echo "${diff}s ago"
    elif [ $diff -lt 3600 ]; then
        echo "$((diff/60))m ago"
    else
        echo "$((diff/3600))h ago"
    fi
fi
```

### `import_config()`
```sh
src="$SDCARD_PATH/wg0.conf"
dest="$USERDATA_PATH/$PAK_NAME/wg0.conf"
if [ -f "$src" ] && [ -s "$src" ]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    rm -f "$src"
    echo "imported"
fi
```

### `has_config()`
```sh
[ -f "$USERDATA_PATH/$PAK_NAME/wg0.conf" ]
```

### `wireguard_up()` / `wireguard_down()` / `is_wireguard_up()`
Identical to the functions defined in Task 03. Can be sourced from `bin/wireguard-lib.sh`
if a shared library approach is used, OR copy-pasted into both scripts.

## Script Structure

```sh
#!/bin/sh
# ... preamble: PAK_DIR, PAK_NAME, logging, architecture, PATH ...

# ... sourced or inlined: wireguard_up, wireguard_down, is_wireguard_up ...
# ... plus: show_message, current_settings, main_screen, enable/disable_start_on_boot, ...

main() {
    echo "1" >/tmp/stay_awake
    trap "cleanup" EXIT INT TERM HUP QUIT

    # normalize tg3040 → tg5040
    if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
        export DEVICE="brick"; export PLATFORM="tg5040"
    fi

    # verify required tools
    for cmd in minui-list minui-presenter jq wg ip; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            show_message "$cmd not found." 2; return 1
        fi
    done

    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-list"
    chmod +x "$PAK_DIR/bin/$PLATFORM/minui-presenter"
    chmod +x "$PAK_DIR/bin/$architecture/jq"
    chmod +x "$PAK_DIR/bin/$architecture/wg"
    [ -f "$PAK_DIR/bin/$architecture/wireguard-go" ] && \
        chmod +x "$PAK_DIR/bin/$architecture/wireguard-go"
    chmod +x "$PAK_DIR/bin/on-boot"

    # try to import config from SD root on every launch
    if [ -f "$SDCARD_PATH/wg0.conf" ]; then
        import_config
        show_message "WireGuard config imported." 2
    fi

    # require config before showing menu
    if ! has_config; then
        show_message "No WireGuard config found.\nDrop wg0.conf at SD card root and relaunch." 4
        return 0
    fi

    while true; do
        settings="$(current_settings)"
        new_settings="$(main_screen "$settings")"
        exit_code=$?
        [ "$exit_code" -ne 0 ] && break

        old_enabled=$(jq -rM '.settings[0].selected' <<EOF
$settings
EOF
)
        enabled=$(jq -rM '.settings[0].selected' <<EOF
$new_settings
EOF
)
        old_boot=$(jq -rM '.settings[1].selected' <<EOF
$settings
EOF
)
        boot=$(jq -rM '.settings[1].selected' <<EOF
$new_settings
EOF
)

        if [ "$old_enabled" != "$enabled" ]; then
            if [ "$enabled" = "1" ]; then
                show_message "Starting WireGuard VPN..." forever
                wireguard_up && killall minui-presenter || \
                    { show_message "Failed to start WireGuard." 3; continue; }
            else
                show_message "Stopping WireGuard VPN..." 2
                wireguard_down
            fi
        fi

        if [ "$old_boot" != "$boot" ]; then
            if [ "$boot" = "1" ]; then enable_start_on_boot
            else disable_start_on_boot; fi
        fi
    done
}

main "$@"
```

## Steps

1. Write `launch.sh` with the complete implementation above
2. Make executable: `chmod +x launch.sh`
3. Syntax check: `sh -n launch.sh`
4. Review all string substitutions for quoting issues (POSIX sh strict)
5. Ensure the heredoc `<<EOF` approach for piping strings to `jq` works with BusyBox `ash`
   - Alternative: use temp files like the original tailscale script does
6. Test config import logic with a dummy `wg0.conf` in a test directory

## Expected Outcome
- `launch.sh` has no syntax errors (`sh -n launch.sh` passes)
- The script follows POSIX sh — no bashisms (`[[ ]]`, `$((...))` for non-arithmetic, etc.)
- First launch with `wg0.conf` at SD root: imports config, shows menu
- Enable toggle: calls `wireguard_up` or `wireguard_down`
- Start on boot toggle: adds/removes line from `auto.sh`
- Status rows (IP, handshake) appear in menu when WireGuard is running
