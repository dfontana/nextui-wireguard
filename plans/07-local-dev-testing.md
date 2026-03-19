# Task 07: Local Development Testing Guide

## Goal
Document the exact process to test the WireGuard pak on a TrimUI Brick before submitting to
the official Pak Store. This task does not produce code — it produces testing instructions and
can be completed in parallel with other implementation tasks.

## Testing Without a Device (Script Validation)

### Syntax Checking
```sh
# Check all shell scripts for POSIX syntax errors
sh -n launch.sh
sh -n bin/on-boot
```

### Simulating the Environment
Set the environment variables NextUI provides, then run scripts manually:
```sh
export PLATFORM=tg5040
export SDCARD_PATH=/tmp/test-sdcard
export USERDATA_PATH=/tmp/test-sdcard/.userdata/tg5040
export LOGS_PATH=/tmp/test-sdcard/.userdata/tg5040/logs
export PAK_DIR=/tmp/test-pak

mkdir -p $SDCARD_PATH $USERDATA_PATH $LOGS_PATH $PAK_DIR/bin/{arm64,tg5040}

# Copy pak files
cp -r . $PAK_DIR/

# Run the config import path (requires wg0.conf at sdcard root)
cp /path/to/my/real/wg0.conf $SDCARD_PATH/wg0.conf
bash -x $PAK_DIR/launch.sh  # use bash for local testing; device uses sh/ash
```

Note: The minui-list and minui-presenter tools only work on the actual device.
For local testing, stub them:
```sh
# Stub minui-list: always return index 0 selected for both settings
cat > /tmp/test-pak/bin/tg5040/minui-list <<'EOF'
#!/bin/sh
cat "$2"  # just echo the input JSON
exit 2    # simulate "back button" to exit
EOF
chmod +x /tmp/test-pak/bin/tg5040/minui-list
```

## Testing on the Device (SD Card Method)

### Prerequisites
- TrimUI Brick with NextUI installed
- USB SD card reader
- WireGuard VPN server running and accessible

### Step 1: Build the Pak
```sh
make clean build
make release
# Produces: dist/WireGuard.pak.zip
```

### Step 2: Install to SD Card
Mount the SD card on your dev machine, then:
```sh
# Create destination directory
mkdir -p /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/

# Extract zip into it (NOT a nested folder — use -j or adjust)
unzip -o dist/WireGuard.pak.zip -d /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/

# Alternatively, for faster iteration during dev (skip zip):
rsync -av --exclude='.git' --exclude='dist' --exclude='*.md' \
  . /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/
```

### Step 3: Drop WireGuard Config
```sh
# Copy your wg0.conf to the SD card ROOT (not inside any folder)
cp ~/wg0.conf /Volumes/SDCARD/wg0.conf
```

### Step 4: Test on Device
1. Eject SD card safely
2. Insert into TrimUI Brick
3. Boot device
4. Navigate: NextUI → Tools → WireGuard
5. Verify: config is imported (wg0.conf disappears from SD root)
6. Toggle Enable → verify connection succeeds

### Step 5: Verify Connection
On the device (if SSH/debug access available):
```sh
wg show wg0
ip addr show wg0
ping 10.8.0.1  # ping WireGuard server's VPN IP
```

Check the log file for errors:
- `SD_ROOT/.userdata/tg5040/logs/WireGuard.txt`
- `SD_ROOT/.userdata/tg5040/logs/WireGuard.on-boot.txt`

## Testing Auto-Boot

1. Enable "Start on boot" in the pak menu
2. Verify `auto.sh` has the boot hook:
   ```sh
   cat /mnt/sdcard/.userdata/tg5040/auto.sh
   # Should contain: ...on-boot # WireGuard.pak-on-boot
   ```
3. Reboot device
4. After boot, verify WireGuard is connected (check wg show wg0)
5. Open pak menu — "Enable" should show as ON (already running)

## Iterating Without Reboot

Since the pak files live on the SD card, you can update scripts between tests:
```sh
# On dev machine after edit:
cp launch.sh /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/launch.sh

# On device (if you have shell access):
# Just re-launch from the NextUI menu — it reads the updated file
```

## Common Issues and Debugging

| Symptom                          | Likely Cause                                | Fix                                           |
|----------------------------------|---------------------------------------------|-----------------------------------------------|
| Pak doesn't appear in Tools menu | Missing `.pak` extension on folder          | Rename folder to `WireGuard.pak`              |
| Black screen on launch           | `launch.sh` crash at startup               | Check `WireGuard.txt` log                     |
| "wg not found"                   | Binary not executable or wrong arch        | `chmod +x bin/arm64/wg`, verify binary arch   |
| Handshake never succeeds         | Firewall / endpoint unreachable            | Test endpoint from another WireGuard client   |
| Config not imported              | wg0.conf not at SD root (e.g., in subfolder)| Must be at `/mnt/sdcard/wg0.conf` exactly    |
| wg0 comes up but no traffic      | AllowedIPs too restrictive                  | Check AllowedIPs in wg0.conf                  |
| wireguard-go fails to start      | Missing TUN kernel support                  | Check `/dev/net/tun` exists on device         |
