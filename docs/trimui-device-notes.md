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
| OS            | Tina Linux 4.0.0 "Neptune" (Allwinner's fork of OpenWrt), build `tina.raymanfeng.20241215` |
| Kernel        | Linux 4.9.191 (aarch64, built Dec 2024, `DISTRIB_TAINTS='no-all glibc busybox'`) |
| Firmware      | NextUI (open-source, https://github.com/LoveRetro/NextUI) |
| Shell         | `sh` (BusyBox ash, POSIX-compatible)               |
| Core utils    | BusyBox (provides ls, grep, awk, sed, ip, etc.)    |

## WireGuard Kernel Support

**Confirmed: the kernel module does NOT exist on this device.** The TrimUI Brick runs Linux 4.9.191.
WireGuard was not merged into the mainline kernel until 5.6 (January 2020), and no backported
`wireguard.ko` is present in `/lib/modules/4.9.191/`. The modules directory contains only camera,
GPU, WiFi (xradio), and netfilter modules.

**wireguard-go (userspace) is always the active path on this device.** The kernel-module branch in
`wireguard_up()` is never taken. `/dev/net/tun` exists and is world-accessible (`crw-rw-rw-`),
so wireguard-go works correctly.

### Critical modprobe quirk

`modprobe wireguard` on this device returns **exit code 0** even though the module doesn't exist
and is not loaded into the kernel. Do NOT use modprobe's exit code to determine whether the module
is loaded. Use `/proc/modules` as the authoritative source:

```sh
modprobe wireguard 2>/dev/null          # attempt to load (exit code is unreliable)
grep -q '^wireguard ' /proc/modules     # authoritative: is it actually loaded?
```

This is why the code separates the modprobe call from the condition check.

## Available System Tools

BusyBox provides most standard POSIX utilities. Notable tools relevant to WireGuard:

| Tool        | Available?       | Path (confirmed)       | Notes                                             |
|-------------|------------------|------------------------|---------------------------------------------------|
| `ip`        | Yes (confirmed)  | `/sbin/ip`             | Supports `addr`, `link`, `route`, `rule`          |
| `modprobe`  | Yes (confirmed)  | `/usr/sbin/modprobe`   | Exit code unreliable — see WireGuard section above |
| `mktemp`    | Yes (confirmed)  | `/bin/mktemp`          | Used for private-key temp file                    |
| `nslookup`  | Yes (confirmed)  | `/usr/bin/nslookup`    | Used to resolve endpoint hostnames                |
| `awk`       | Yes (confirmed)  | `/usr/bin/awk`         |                                                   |
| `sed`       | Yes (confirmed)  | `/bin/sed`             | BusyBox sed, supports `-i`                        |
| `tr`        | Yes (confirmed)  | `/usr/bin/tr`          |                                                   |
| `grep`      | Yes (confirmed)  | `/bin/grep`            |                                                   |
| `date +%s`  | Yes (confirmed)  | `/bin/date`            | Unix timestamp output works                       |
| `iptables`  | Yes              | —                      | OpenWrt standard, NOT required for WireGuard      |
| `killall`   | Yes              | —                      | Signal processes by name                          |
| `wget`      | Yes              | —                      | HTTP client (BusyBox wget)                        |
| `curl`      | Not confirmed    | —                      | May not be present                                |
| `rsync`     | Not present      | —                      | Not in BusyBox; use `tar \| ssh` to transfer files |
| `resolvconf`| Not present      | —                      | DNS managed by direct resolv.conf write; see DNS section below |
| `wg`        | No               | —                      | Must be bundled; see Binary Compatibility below   |
| `wireguard-go` | No            | —                      | Must be bundled; see Binary Compatibility below   |

## Architecture Notes

- The device is **exclusively aarch64** (no 32-bit ARM mode), so only `arm64` binaries are needed.
- 32-bit ARM (`arm`/`armhf`) support was evaluated during planning but deliberately dropped — the
  TrimUI Brick has no 32-bit mode and there are no other target devices at this time.
- Go binaries built with `GOOS=linux GOARCH=arm64 CGO_ENABLED=0` run natively (fully static).
- **musl-linked C binaries WILL NOT run.** The device uses glibc 2.33; there is no musl dynamic
  linker (`/lib/ld-musl-aarch64.so.1` is absent). Statically-linked C binaries work on any ABI.

## Environment Variables (confirmed from MinUI.pak launch.sh)

These are set by MinUI.pak before launching any pak's `launch.sh`:

```sh
export PLATFORM="tg5040"
export SDCARD_PATH="/mnt/SDCARD"
export BIOS_PATH="$SDCARD_PATH/Bios"
export ROMS_PATH="$SDCARD_PATH/Roms"
export SAVES_PATH="$SDCARD_PATH/Saves"
export CHEATS_PATH="$SDCARD_PATH/Cheats"
export SYSTEM_PATH="$SDCARD_PATH/.system/$PLATFORM"
export CORES_PATH="$SYSTEM_PATH/cores"
export USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
export SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
export LOGS_PATH="$USERDATA_PATH/logs"
export HOOKS_PATH="$USERDATA_PATH/.hooks"
export DATETIME_PATH="$SHARED_USERDATA_PATH/datetime.txt"
export HOME="$USERDATA_PATH"
export DEVICE="brick"   # for TrimUI Brick
export IS_NEXT="yes"
```

## System PATH

The PATH available to paks (confirmed):

```
/mnt/SDCARD/.system/tg5040/bin:/usr/trimui/bin:/usr/sbin:/usr/bin:/sbin:/bin
```

Note: `minui-list` and `minui-presenter` are NOT in the system PATH — each pak bundles its own
copies in `bin/tg5040/`. Similarly, `jq` is NOT in the system PATH — each pak bundles its own
copy in `bin/arm64/`. These are confirmed on-device behaviors.

## SD Card Paths

| Path                                       | Purpose                                              |
|--------------------------------------------|------------------------------------------------------|
| `/mnt/SDCARD/`                             | SD card root (`$SDCARD_PATH`)                        |
| `/mnt/SDCARD/Tools/tg5040/`               | Pak installation directory                           |
| `/mnt/SDCARD/Tools/tg5040/WireGuard.pak/` | This pak's location                                  |
| `/mnt/SDCARD/.userdata/tg5040/`           | Persistent user data (`$USERDATA_PATH`)              |
| `/mnt/SDCARD/.userdata/shared/`           | Shared user data (`$SHARED_USERDATA_PATH`)           |
| `/mnt/SDCARD/.userdata/tg5040/WireGuard/` | WireGuard pak persistent data                        |
| `/mnt/SDCARD/.userdata/tg5040/auto.sh`    | Boot hook (MinUI.pak sources this on startup if it exists) |
| `/mnt/SDCARD/.userdata/tg5040/.hooks/`    | Composable hook directory (`$HOOKS_PATH`)            |
| `/mnt/SDCARD/.userdata/tg5040/.hooks/boot.d/` | Boot hook scripts (run via `run_hooks.sh boot.d`) |
| `/mnt/SDCARD/.userdata/tg5040/logs/`      | Log files (`$LOGS_PATH`)                             |
| `/mnt/SDCARD/.userdata/shared/datetime.txt` | Shared datetime file (`$DATETIME_PATH`)            |
| `/mnt/SDCARD/wg0.conf`                    | Config import: user drops wg0.conf here              |

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
  (confirmed NOT in system PATH)
- WireGuard interface `wg0` should be torn down on `launch.sh` exit if the user disables VPN
  (but should remain up if the user just closes the pak while WireGuard is running)

## Boot Hooks

MinUI.pak provides two boot hook mechanisms — both are available:

1. **`auto.sh`** — MinUI.pak executes `$USERDATA_PATH/auto.sh` if the file exists. Must be
   created by paks; it does not exist by default. Lives at
   `/mnt/SDCARD/.userdata/tg5040/auto.sh`.

2. **`boot.d` hooks** — MinUI.pak runs `"$SYSTEM_PATH/bin/run_hooks.sh" boot.d`, which
   executes all `*.sh` scripts under `$USERDATA_PATH/.hooks/boot.d/` (`$HOOKS_PATH/boot.d/`).
   This is a newer, composable system.

Both mechanisms can coexist. This pak currently uses `auto.sh`.

## Binary Compatibility

The device uses **glibc 2.33** (`/lib/libc-2.33.so`, `/lib/ld-linux-aarch64.so.1`). There is no
musl dynamic linker. This has two consequences for bundled binaries:

| Binary       | Source                        | Linking  | Works? |
|--------------|-------------------------------|----------|--------|
| `wireguard-go` | WireGuard/wireguard-go (Go) | Static (`CGO_ENABLED=0`) | ✅ Yes |
| `wg`         | Built in Alpine arm64 Docker  | Static (`LDFLAGS=-static`) | ✅ Yes |
| `jq`         | jq-linux-arm64 release        | Static   | ✅ Yes |
| `minui-list` | josegonzalez/minui-list release | Compiled for tg5040 | ✅ Yes |
| `minui-presenter` | josegonzalez/minui-presenter release | Compiled for tg5040 | ✅ Yes |

**Why `wg` must be statically built:** The pre-built Alpine APK binary for `wireguard-tools-wg`
is dynamically linked against musl libc. It cannot exec on this glibc device. The build system
compiles `wg` from source inside an Alpine arm64 Docker container with `LDFLAGS="-static"`,
producing a fully static binary with no runtime libc dependency.

Building `wg` requires Docker with arm64 support. On Apple Silicon Macs, arm64 containers run
natively — no QEMU needed. On x86_64 Linux (including CI), QEMU binfmt must be installed first;
the CI workflow does this automatically via `docker/setup-qemu-action`. For manual x86_64 setup:

```sh
docker run --privileged --rm tonistiigi/binfmt --install arm64
make bin/arm64/wg
```

The Alpine Docker container must install `build-base` (not just `gcc`) to get `musl-dev` and
the C standard library headers — without it the `wg` compilation fails with `stdio.h: No such
file or directory`.

## DNS Architecture

Confirmed via live inspection:

- `/etc/resolv.conf` → symlink → `/tmp/resolv.conf` → symlink → `/tmp/resolv.conf.auto`
- `/tmp/resolv.conf.auto` is the real file. `readlink -f /etc/resolv.conf` resolves to it.
- **No `dnsmasq`** on this device. DNS is managed directly by `udhcpc` (`udhcpc -i wlan0 -b`),
  which writes the DHCP-assigned nameserver straight to `/tmp/resolv.conf.auto`.
- **No `resolvconf`** utility.

To override DNS while the VPN is up: back up `/tmp/resolv.conf.auto`, write new `nameserver`
lines to it, restore on VPN teardown. A DHCP renewal mid-session will overwrite the file —
acceptable on a stable home Wi-Fi connection where renewals are infrequent. On reboot, `/tmp/`
is wiped and `udhcpc` resets DNS from DHCP automatically.

`ip rule show` confirms policy routing rules are present and the BusyBox `ip rule` command
works, but it is not used by this pak (the two-route trick avoids needing it).

## SSH Access

The device runs dropbear SSH on port 22. Credentials: `root` / `tina`.

The device gets a DHCP-assigned IP on wlan0 (e.g. `192.168.50.57`). Detect it with:

```sh
ip addr show wlan0
```

Or check your router's DHCP leases, or use the SSH Server pak which displays the address on screen.

Connect from your dev machine:

```sh
ssh root@<device-ip>
```

This is the fastest way to get an interactive shell for debugging without removing the SD card.

For scripted (non-interactive) access — used during dev for piping commands or transferring
files — see "Scripted SSH" in `development-guide.md`. The short version: drive `ssh` with
`expect` since dropbear is password-only and adding a pubkey would persist beyond the
session.

### Dropbear command-line length limit

The device's dropbear closes the connection when the single remote-command argument exceeds
roughly **6 KB** (observed empirically while pushing a base64-encoded shell file in one
shot — `Connection closed by remote host` with no other diagnostic). Smaller commands
transfer cleanly. For larger payloads, chunk the base64 in pieces of ~2000 chars and append
on the remote side, then `base64 -d` into the target file.

### BusyBox utility versions

BusyBox `v1.27.2` (released 2017) — older than most current Linux distros. Verified by
running `busybox` or `killall --help`. Relevant for picking up newer flags that don't exist:
e.g., `find -printf` and `grep -P` are absent. Stick to POSIX-defined flags.

### Useful on-device commands

```sh
# WireGuard state
wg show wg0
ip addr show wg0
ip route

# Kernel modules
cat /proc/modules | grep wireguard   # authoritative — modprobe exit code is unreliable
ls /lib/modules/$(uname -r)/         # list available .ko files

# TUN device
ls -la /dev/net/tun                  # crw-rw-rw- means wireguard-go will work

# Pak log
cat /mnt/SDCARD/.userdata/tg5040/logs/WireGuard.txt

# Boot hook
cat /mnt/SDCARD/.userdata/tg5040/auto.sh
```
