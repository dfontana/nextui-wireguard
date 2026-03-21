# Development Guide

## Local Testing (Without Device)

### Syntax Checking

```sh
sh -n launch.sh
sh -n bin/on-boot
```

### Simulating the NextUI Environment

Set the environment variables that NextUI normally provides:

```sh
export PLATFORM=tg5040
export SDCARD_PATH=/tmp/test-sdcard
export USERDATA_PATH=/tmp/test-sdcard/.userdata/tg5040
export LOGS_PATH=/tmp/test-sdcard/.userdata/tg5040/logs
export PAK_DIR=/tmp/test-pak

mkdir -p $SDCARD_PATH $USERDATA_PATH $LOGS_PATH $PAK_DIR/bin/{arm64,tg5040}

# Copy pak files into the simulated pak directory
cp -r . $PAK_DIR/

# Drop a real wg0.conf to test config import
cp /path/to/my/real/wg0.conf $SDCARD_PATH/wg0.conf

# Run with bash for local testing (device uses BusyBox ash)
bash -x $PAK_DIR/launch.sh
```

### Stubbing minui-list and minui-presenter

`minui-list` and `minui-presenter` are ARM binaries that only work on the device. For local
testing, create stub scripts:

```sh
cat > /tmp/test-pak/bin/tg5040/minui-list <<'EOF'
#!/bin/sh
cat "$2"  # echo the input JSON back
exit 2    # simulate "back button" to exit the main loop
EOF
chmod +x /tmp/test-pak/bin/tg5040/minui-list
```

This lets the script run through the config import and settings logic without the real UI.

## Testing on Device (SD Card)

### Build and Install

```sh
make clean build
make release
# Produces: dist/WireGuard.pak.zip

# Mount SD card and extract
mkdir -p /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/
unzip -o dist/WireGuard.pak.zip -d /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/

# Drop config at SD root
cp ~/wg0.conf /Volumes/SDCARD/wg0.conf
```

### Fast Iteration (Skip Zip)

```sh
rsync -av --exclude='.git' --exclude='dist' --exclude='*.md' \
  . /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/
```

You can update scripts between tests without rebooting — just re-launch from the NextUI menu.

### Verifying on Device

If you have shell access:

```sh
wg show wg0
ip addr show wg0
ping 10.8.0.1  # ping WireGuard server's VPN IP
```

### Testing Auto-Boot

1. Enable "Start on boot" in the pak menu
2. Verify the boot hook was written:
   ```sh
   cat /mnt/sdcard/.userdata/tg5040/auto.sh
   # Should contain: ...on-boot # WireGuard.pak-on-boot
   ```
3. Reboot device
4. Verify WireGuard is connected (`wg show wg0`)
5. Open pak menu — "Enable" should show as ON

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Pak doesn't appear in Tools menu | Missing `.pak` extension on folder | Rename folder to `WireGuard.pak` |
| Black screen on launch | `launch.sh` crash at startup | Check `WireGuard.txt` log |
| "wg not found" | Binary not executable or wrong arch | `chmod +x bin/arm64/wg`, verify binary arch |
| Handshake never succeeds | Firewall / endpoint unreachable | Test endpoint from another WireGuard client |
| Config not imported | wg0.conf not at SD root | Must be at `/mnt/sdcard/wg0.conf` exactly |
| wg0 comes up but no traffic | AllowedIPs too restrictive | Check AllowedIPs in wg0.conf |
| wireguard-go fails to start | Missing TUN kernel support | Check `/dev/net/tun` exists on device |

## Shell Compatibility Notes

The device runs BusyBox ash (POSIX sh). Key constraints:

- **No bash-isms**: no `[[ ]]`, no arrays, no `<<<` here-strings, no process substitution
- **No heredocs for pipe input**: BusyBox ash has inconsistent heredoc behavior when piped to
  commands like `jq`. Use temp files instead (this is why `launch.sh` writes JSON to temp files
  before passing them to `jq`, rather than using here-strings or heredocs)
- **Test locally with `dash`** for closer POSIX behavior than `bash`

## Code Maintenance Notes

The `wireguard_up()` function is duplicated in both `launch.sh` and `bin/on-boot`. These two
copies must be kept in sync when making changes to WireGuard interface setup logic. A shared
library was considered but rejected for POSIX sh simplicity (avoiding `source`/`.` path
resolution issues across different invocation contexts).
