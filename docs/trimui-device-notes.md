# TrimUI Brick Device Notes

## Hardware

| Component   | Details                                         |
|-------------|-------------------------------------------------|
| Device name | TrimUI Brick                                    |
| Platform ID | `tg5040`                                        |
| CPU         | Allwinner A133 Plus (4× Cortex-A53 @ 1.8GHz)   |
| Architecture| aarch64 (ARMv8-A, 64-bit)                       |
| RAM         | 1GB LPDDR4                                      |
| Storage     | MicroSD card (user-accessible, pak install target) |
| Wi-Fi       | Yes (required for WireGuard VPN)                |

## Software Stack

| Layer         | Details                                             |
|---------------|-----------------------------------------------------|
| OS            | Tina Linux (Allwinner's fork of OpenWrt)           |
| Kernel        | Linux (ARM64, OpenWrt-based, likely 5.x)           |
| Firmware      | NextUI (open-source, https://github.com/LoveRetro/NextUI) |
| Shell         | `sh` (BusyBox ash, POSIX-compatible)               |
| Core utils    | BusyBox (provides ls, grep, awk, sed, ip, etc.)    |

## WireGuard Kernel Support

OpenWrt (and by extension Tina Linux) has included WireGuard as a kernel module since version 19.07.
The TrimUI Brick running NextUI is expected to have `wireguard.ko` available, but this should be
verified at runtime:

```sh
modprobe wireguard 2>/dev/null
# OR
cat /proc/modules | grep -i wireguard
# OR
ls /lib/modules/$(uname -r)/extra/wireguard.ko 2>/dev/null
```

If the kernel module is unavailable, fall back to `wireguard-go` userspace.

## Available System Tools

BusyBox provides most standard POSIX utilities. Notable tools relevant to WireGuard:

| Tool       | Available?  | Notes                                              |
|------------|-------------|----------------------------------------------------|
| `ip`       | Yes         | BusyBox `ip` — supports `addr`, `link`, `route`   |
| `iptables` | Likely yes  | OpenWrt standard, but NOT required for WireGuard  |
| `modprobe` | Yes         | Load kernel modules                                |
| `pgrep`    | Yes         | Process lookup                                     |
| `killall`  | Yes         | Signal processes by name                           |
| `wget`     | Yes         | HTTP client (BusyBox wget)                         |
| `curl`     | Maybe       | May not be present on all builds                   |
| `resolvconf`| Unlikely   | Not needed — we skip DNS management                |

## Architecture Notes

- The device is **exclusively aarch64** (no 32-bit ARM mode), so only `arm64` binaries are needed.
- 32-bit ARM (`arm`/`armhf`) support was evaluated during planning but deliberately dropped — the
  TrimUI Brick has no 32-bit mode and there are no other target devices at this time.
- Go binaries for `GOARCH=arm64` run natively.
- Static C binaries compiled for `aarch64-linux-musl` (Alpine/musl libc) run without issues.

## SD Card Paths

| Path                                       | Purpose                                              |
|--------------------------------------------|------------------------------------------------------|
| `/mnt/sdcard/`                             | SD card root (`$SDCARD_PATH`)                        |
| `/mnt/sdcard/Tools/tg5040/`               | Pak installation directory                           |
| `/mnt/sdcard/Tools/tg5040/WireGuard.pak/` | This pak's location                                  |
| `/mnt/sdcard/.userdata/tg5040/`           | Persistent user data (`$USERDATA_PATH`)              |
| `/mnt/sdcard/.userdata/tg5040/WireGuard/` | WireGuard pak persistent data                        |
| `/mnt/sdcard/.userdata/tg5040/auto.sh`    | Boot hook (NextUI sources this on startup)           |
| `/mnt/sdcard/.userdata/tg5040/logs/`      | Log files (`$LOGS_PATH`)                             |
| `/mnt/sdcard/wg0.conf`                    | Config import: user drops wg0.conf here              |

## Testing Without Device

Since the device is ARM-based, testing on an x86_64 dev machine requires either:
1. Cross-compilation/QEMU emulation
2. Validating shell script logic with `bash --posix` or `dash`
3. Deploying directly to the device via SD card copy

The scripts should be written to POSIX sh (not bash) for compatibility with BusyBox ash.

## Known NextUI Behavior

- `launch.sh` must exit cleanly — if it crashes, NextUI may hang on a black screen
- Keep `/tmp/stay_awake` file present while running to prevent device from sleeping
- Remove `/tmp/stay_awake` in the cleanup trap
- `minui-presenter` and `minui-list` are platform-specific binaries that live in `bin/tg5040/`
- WireGuard interface `wg0` should be torn down on `launch.sh` exit if the user disables VPN
  (but should remain up if the user just closes the pak while WireGuard is running)
