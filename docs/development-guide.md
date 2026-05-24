# Development Guide

## Critical Device Facts (Read This First)

These were confirmed via live SSH inspection of the TrimUI Brick. They contradict some
common assumptions about OpenWrt-based devices.

| Fact | Detail |
|------|--------|
| Kernel | Linux **4.9.191** — predates mainline WireGuard (added in 5.6) |
| C library | **glibc 2.33** — NOT musl, NOT uclibc |
| WireGuard kernel module | **Does not exist** — `wireguard-go` is always used |
| `/dev/net/tun` | **Present** — wireguard-go works |
| `modprobe wireguard` exit code | **Unreliable** — returns 0 even when module is absent; check `/proc/modules` instead |
| Pre-built Alpine `wg` binary | **Will NOT run** — it is musl-linked; must build with `LDFLAGS=-static` |
| SSH | `root` / `tina` on port 22 (dropbear) |

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
export DEVICE=brick
export IS_NEXT=yes
export SDCARD_PATH=/tmp/test-sdcard
export USERDATA_PATH=/tmp/test-sdcard/.userdata/tg5040
export SHARED_USERDATA_PATH=/tmp/test-sdcard/.userdata/shared
export LOGS_PATH=/tmp/test-sdcard/.userdata/tg5040/logs
export HOOKS_PATH=/tmp/test-sdcard/.userdata/tg5040/.hooks
export DATETIME_PATH=/tmp/test-sdcard/.userdata/shared/datetime.txt
export PAK_DIR=/tmp/test-pak

mkdir -p $SDCARD_PATH $USERDATA_PATH $SHARED_USERDATA_PATH $LOGS_PATH $HOOKS_PATH $PAK_DIR/bin/{arm64,tg5040}

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

### Build Requirements

`make build` downloads `minui-list`, `minui-presenter`, and `jq` directly. It also builds `wg`
statically from source inside an Alpine arm64 Docker container — this requires Docker with arm64
QEMU binfmt support.

One-time setup:
```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
```

`wireguard-go` is built by the release workflow only (it requires Go). For local testing you can
build it manually:
```sh
git clone https://github.com/WireGuard/wireguard-go /tmp/wireguard-go
cd /tmp/wireguard-go
GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o bin/arm64/wireguard-go .
```

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

### SSH Access to the Device

The device runs dropbear SSH on port 22. Credentials: `root` / `tina`.

The device's IP is DHCP-assigned on wlan0. To find it, either:
- Check your router's DHCP leases, or
- Look at the device display for an IP (if a pak shows it), or
- Use the SSH Server pak which displays the IP on screen

Once you have the IP:

```sh
ssh root@<device-ip>
```

This gives you an interactive shell for debugging without needing to remove the SD card.
Useful commands once connected:

```sh
wg show wg0
ip addr show wg0
ping 10.8.0.1  # ping WireGuard server's VPN IP
logread        # system log (if available)
cat /mnt/SDCARD/.userdata/tg5040/logs/WireGuard.txt
```

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
   cat /mnt/SDCARD/.userdata/tg5040/auto.sh
   # Should contain: ...on-boot # WireGuard.pak-on-boot
   ```
3. Reboot device
4. Verify WireGuard is connected (`wg show wg0`)
5. Open pak menu — "Enable" should show as ON

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---------|-------------|-----|
| Pak doesn't appear in Tools menu | Missing `.pak` extension on folder | Rename folder to `WireGuard.pak` |
| Black screen on launch | `launch.sh` crash at startup | Check `WireGuard.txt` log via SSH |
| "wg not found" | Binary missing or not executable | Run `chmod +x bin/arm64/wg`; verify it was built with `LDFLAGS=-static` |
| `wg` fails silently / "No such file or directory" | musl-linked binary on glibc device | Rebuild `wg` statically (see Build Requirements); confirm `/lib/ld-musl-aarch64.so.1` is absent |
| "no WireGuard driver available" | Neither kernel module nor wireguard-go found | Confirm `wireguard-go` is in `bin/arm64/` and is executable |
| wireguard-go exits immediately | `/dev/net/tun` missing or inaccessible | SSH in and run `ls -la /dev/net/tun`; confirmed present on TrimUI Brick |
| WireGuard comes up but "wg set failed" | Corrupt wg0.conf or wrong key format | Check log; manually parse conf with awk |
| Handshake never succeeds | Firewall / endpoint unreachable | Test endpoint from another WireGuard client |
| Config not imported | wg0.conf not at SD root | Must be at `/mnt/SDCARD/wg0.conf` exactly (uppercase SDCARD) |
| wg0 comes up but no traffic | AllowedIPs too restrictive | Check AllowedIPs in wg0.conf |
| "Enable" toggle reverts to off after relaunch | wireguard_up() failed silently | Check `WireGuard.txt` log for the error |

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
