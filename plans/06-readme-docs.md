# Task 06: README and Documentation

## Goal
Write a complete `README.md` for the repository that covers:
1. What the pak does
2. Requirements (WireGuard server setup)
3. How to create a `wg0.conf` config file
4. Installation instructions (Pak Store and manual)
5. First-time setup on the device
6. Troubleshooting guide

## README Sections

### Header
- Title: "WireGuard for NextUI / TrimUI Brick"
- Short description
- Badges: CI status, latest release

### What It Does
- Connects TrimUI Brick to a WireGuard VPN
- Allows access to home network while on the go
- Supports auto-start on device boot

### Requirements
- TrimUI Brick running NextUI
- A WireGuard server (e.g., on a home router like OpenWrt, VyOS, or a Raspberry Pi)
- Wi-Fi enabled on the device

### Creating a WireGuard Config File
Explain how to export a client config from common WireGuard server setups:
- OpenWrt (`/etc/wireguard/` + `wg genkey` / `wg pubkey`)
- Generic Linux WireGuard server
- The file should be named `wg0.conf`
- Example config format

### Installation

**Via Pak Store (once available):**
1. Open NextUI → Tools → Pak Store
2. Find "WireGuard" → Install

**Manual installation (development):**
1. Download `WireGuard.pak.zip` from the latest GitHub Release
2. Unzip into `SD_ROOT/Tools/tg5040/WireGuard.pak/`
3. Eject and insert SD card into TrimUI Brick

### First-Time Setup
1. Copy `wg0.conf` to the root of the SD card (alongside `Roms/`, `Tools/`)
2. On the device: Tools → WireGuard
3. The pak automatically imports and deletes the config file
4. Toggle "Enable" to ON → WireGuard connects
5. Optionally enable "Start on boot"

### Usage
- **Enable**: Toggles the WireGuard VPN on/off
- **Start on boot**: Auto-connects on device startup
- **Address**: Shows the VPN IP (visible when connected)
- **Handshake**: Shows time since last peer handshake

### Troubleshooting
- Check log file: `SD_ROOT/.userdata/tg5040/logs/WireGuard.txt`
- Check boot log: `SD_ROOT/.userdata/tg5040/logs/WireGuard.on-boot.txt`
- Verify `wg0.conf` is valid WireGuard format
- Ensure Wi-Fi is connected before enabling WireGuard
- If handshake never succeeds: verify server endpoint/port is reachable

### Building from Source
```sh
git clone https://github.com/dfontana/nextui-wireguard
cd nextui-wireguard
make build
make release
# Output: dist/WireGuard.pak.zip
```

## Steps

1. Write `README.md` with all sections above
2. Include a sample `wg0.conf` in a code block
3. Add CI badge once the workflow is running
4. Keep language simple (the target audience is gamers, not necessarily sysadmins)

## Expected Outcome
A clear, user-friendly README that a person with basic WireGuard knowledge can follow to get
the pak installed and working on their TrimUI Brick.
