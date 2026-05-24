# WireGuard for NextUI / TrimUI Brick

[![CI](https://github.com/dfontana/nextui-wireguard/actions/workflows/ci.yaml/badge.svg)](https://github.com/dfontana/nextui-wireguard/actions/workflows/ci.yaml)

A NextUI pak that connects your TrimUI Brick to a WireGuard VPN, giving you access to your home
network while on the go.

## Requirements

- TrimUI Brick running [NextUI](https://github.com/LoveRetro/NextUI)
- Wi-Fi connected on the device
- A WireGuard VPN server (e.g. on your home router running OpenWrt, a Raspberry Pi, or any Linux box)

## Installation

### Via Pak Store (once available)

1. Open NextUI → Tools → Pak Store
2. Search for "WireGuard" → Install

### Manual Installation

1. Download `WireGuard.pak.zip` from the [latest release](https://github.com/dfontana/nextui-wireguard/releases/latest)
2. Unzip into `SD_ROOT/Tools/tg5040/WireGuard.pak/`
3. Eject and reinsert the SD card into your TrimUI Brick

## First-Time Setup

### 1. Create a WireGuard client config

Export a client config from your WireGuard server. It should look like this:

```ini
[Interface]
PrivateKey = <your device private key>
Address = 10.8.0.2/24

[Peer]
PublicKey = <your server public key>
Endpoint = myhome.example.com:51820
AllowedIPs = 10.8.0.0/24, 192.168.1.0/24
PersistentKeepalive = 25
```

Save it as `wg0.conf`.

> **Tip:** On OpenWrt routers, go to **Network → WireGuard** → add a peer, then export the peer config.
> On a Linux server: `wg genkey | tee privatekey | wg pubkey > publickey`

### 2. Copy the config to your SD card

Place `wg0.conf` at the **root** of your SD card (not inside any folder):

```
SD_ROOT/
├── wg0.conf        ← here
├── Roms/
├── Tools/
└── ...
```

### 3. Launch the pak

On your TrimUI Brick: **NextUI → Tools → WireGuard**

The pak automatically imports and deletes `wg0.conf` from the SD root.
Toggle **Enable** to ON to connect.

## Usage

| Setting        | Description                                        |
|----------------|----------------------------------------------------|
| Enable         | Toggle WireGuard VPN on / off                      |
| Start on boot  | Auto-connect when the device boots                 |
| Address        | Your VPN IP address (shown when connected)         |
| Handshake      | Time since last successful peer handshake          |

To update your config, drop a new `wg0.conf` at the SD root and relaunch the pak.

## Troubleshooting

**Check the log files on your SD card:**
- `SD_ROOT/.userdata/tg5040/logs/WireGuard.txt` — main session log
- `SD_ROOT/.userdata/tg5040/logs/WireGuard.on-boot.txt` — boot startup log

**Common issues:**

| Symptom | Fix |
|---------|-----|
| Config not imported | Ensure `wg0.conf` is at the SD root, not in a subfolder |
| Handshake never succeeds | Verify the server endpoint and port are reachable from your network |
| "wg not found" | Binary may not be executable — check log for details |
| No traffic through VPN | Check `AllowedIPs` in your config covers the desired subnets |
| wireguard-go fails to start | Verify `/dev/net/tun` exists on the device (TUN kernel support required) |

## Building from Source

```sh
git clone https://github.com/dfontana/nextui-wireguard
cd nextui-wireguard
make build    # downloads all binaries
make release  # produces dist/WireGuard.pak.zip
```

> `wireguard-go` is built from source by the release GitHub Actions workflow and is not
> included in `make build`. See [`docs/development-guide.md`](docs/development-guide.md)
> for local testing instructions.

## How It Works

The pak uses:
- **`wg`** (wireguard-tools) to configure the WireGuard interface
- The kernel's `wireguard` module (loaded via `modprobe`) as the primary driver
- **`wireguard-go`** as a fallback userspace driver if the kernel module is unavailable
- **`minui-list`** / **`minui-presenter`** for the interactive settings UI

See [`docs/`](docs/) for detailed research notes on the implementation.

## Limitations

### Full-tunnel (route-all-traffic) mode is not supported

`AllowedIPs = 0.0.0.0/0` will not work correctly. The pak adds a route via `wg0` for each AllowedIPs CIDR but does not replace the existing default route via `wlan0`. With two competing default routes, traffic will not reliably go through the VPN. Split-tunnel configurations (specific subnets in `AllowedIPs`) work correctly.

### DNS is not configured

The `DNS =` field in `[Interface]` is parsed from the config file but ignored. The device continues to use its DHCP-assigned nameserver. This matters if the VPN provides internal hostnames or uses split-horizon DNS.

### Only one `[Peer]` block is supported

If `wg0.conf` contains multiple `[Peer]` sections, only the first peer's `PublicKey`, `Endpoint`, `AllowedIPs`, and `PresharedKey` are used. All subsequent peers are silently ignored.

## License

MIT — see [LICENSE](LICENSE)
