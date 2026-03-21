# WireGuard Bash Client Research

## Overview

WireGuard is a modern, fast VPN protocol. On embedded/ARM devices there are two layers needed:
1. **Kernel driver** — the `wireguard.ko` kernel module (preferred, zero performance overhead)
2. **Userspace driver** — `wireguard-go` (fallback if the kernel module is unavailable)

Both are configured with the same `wg` CLI tool from `wireguard-tools`.

---

## Binaries Required

### `wg` (wireguard-tools)
- The userspace configuration CLI used to set peers, keys, endpoints on a WireGuard interface.
- Source: https://git.zx2c4.com/wireguard-tools
- Does NOT manage the network interface itself — just configures it after the driver creates it.
- Needs to be statically linked for embedded use.
- Available as a pre-built static binary via Alpine Linux community packages.

### `wireguard-go`
- A pure-Go userspace implementation of the WireGuard protocol.
- Acts as a TUN-based driver when the kernel module (`wireguard.ko`) is not available.
- Official source: https://github.com/WireGuard/wireguard-go
- Has no official binary releases — must be compiled from source (Go cross-compilation is trivial).
- Exposes a TUN network interface named by the argument (e.g., `wireguard-go wg0`).
- License: MIT

---

## Architecture Decision

For TrimUI Brick (aarch64, Tina Linux / OpenWrt-based):

1. **Try kernel module first**: `modprobe wireguard 2>/dev/null` — Tina Linux / OpenWrt kernels
   frequently include `wireguard.ko` in the module tree.
2. **Fallback to wireguard-go**: If `modprobe` fails and no `/sys/module/wireguard` exists, launch
   `wireguard-go wg0` as a background process, then configure with `wg`.

The device is aarch64 only (Cortex-A53), so only the `arm64` architecture is strictly required.
The Makefile also downloads `arm` binaries for potential future device support.

---

## Interface Bring-Up Sequence (without wg-quick)

`wg-quick` is a shell wrapper that provides convenience but depends on `iptables`, `resolvconf`,
and other utilities that may not be present on Tina Linux. We manage the interface manually:

```sh
# 1. Ensure kernel module or wireguard-go is running (creates the wg0 TUN device)
modprobe wireguard 2>/dev/null || wireguard-go wg0

# 2. Set private key and peer configuration
wg set wg0 \
  private-key /path/to/private.key \
  peer <PEER_PUBKEY> \
  endpoint <HOST:PORT> \
  allowed-ips <CIDR,...> \
  persistent-keepalive 25

# 3. Assign the interface IP address (from [Interface] Address = in wg0.conf)
ip addr add <ADDRESS/PREFIX> dev wg0

# 4. Bring the interface up
ip link set up dev wg0

# 5. Add routes for AllowedIPs
ip route add <CIDR> dev wg0
```

## Interface Tear-Down

```sh
ip link del dev wg0                  # removes interface; also stops kernel module path
kill <wireguard-go PID>              # stop userspace driver if it was used
```

---

## Config File Format (`wg0.conf`)

Standard WireGuard configuration file the user creates from their server:

```ini
[Interface]
PrivateKey = <base64 private key>
Address = 10.8.0.2/24
DNS = 1.1.1.1         # optional, ignored by our script

[Peer]
PublicKey = <base64 server public key>
Endpoint = myhome.example.com:51820
AllowedIPs = 10.8.0.0/24, 192.168.1.0/24
PersistentKeepalive = 25
```

Our launch script parses this file using `awk`/`grep` — no `wg-quick` dependency.

---

## Status Checking

```sh
# Check if interface exists
ip link show wg0

# Get assigned IP
ip addr show wg0 | awk '/inet /{print $2}'

# Check handshake (shows last successful handshake timestamp as Unix epoch)
wg show wg0 latest-handshakes

# Full status
wg show wg0
```

---

## Binary Download Sources

| Binary       | Arch   | Source                                                                        |
|--------------|--------|-------------------------------------------------------------------------------|
| `wg`         | arm64  | Alpine Linux edge/community aarch64 `wireguard-tools-wg` APK (extracted)     |
| `wg`         | arm    | Alpine Linux edge/community armhf `wireguard-tools-wg` APK (extracted)       |
| `wireguard-go` | arm64 | Built from source via GitHub Actions (`go build` for `GOARCH=arm64`)        |
| `wireguard-go` | arm   | Built from source via GitHub Actions (`go build` for `GOARCH=arm GOARM=7`)  |

Alpine APK format is a gzipped tar file. Extraction:
```sh
curl -o wg.apk <URL>
tar -xzf wg.apk usr/bin/wg
mv usr/bin/wg bin/arm64/wg
```

---

## Key Differences vs Tailscale

| Feature        | Tailscale                          | WireGuard                              |
|----------------|------------------------------------|----------------------------------------|
| Daemon         | `tailscaled` (always running)      | None — kernel module / `wireguard-go` only during connection |
| Auth           | Auth key file → REST API           | Config file (pre-shared private key)   |
| State          | `--statedir` with persistent JSON  | Stateless — config file IS the state   |
| IP assignment  | Dynamic from coordination server   | Static from `wg0.conf`                 |
| DNS            | Managed by `tailscaled`            | Not managed (optional via resolvconf)  |
| Peer discovery | Central coordination server        | Manual peer configuration              |
