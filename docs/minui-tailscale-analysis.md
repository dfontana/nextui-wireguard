# minui-tailscale Implementation Analysis

Source: https://github.com/ben16w/minui-tailscale

This document describes how minui-tailscale is structured so we can follow the same conventions
for the WireGuard pak.

---

## Repository Structure

```
minui-tailscale/
├── .github/
│   └── workflows/
│       ├── ci.yaml          # validates build
│       └── release.yaml     # tags → creates zip release artifact
├── bin/
│   ├── on-boot              # boot startup script (sourced from auto.sh)
│   ├── miyoomini/           # platform-specific minui binaries
│   ├── my282/
│   ├── rg35xxplus/
│   ├── tg5040/
│   ├── arm/                 # arch-specific binaries (jq, tailscale, tailscaled)
│   └── arm64/
├── .gitarchiveinclude       # lists bin/ contents not tracked by git (downloaded at build)
├── .gitattributes
├── .gitignore
├── LICENSE
├── Makefile
├── README.md
├── config.json              # UI settings definition
├── launch.sh                # main entry point
└── pak.json                 # pak store metadata
```

---

## Build System (Makefile)

**No cross-compilation** — all binaries are pre-built and downloaded at build time.

Variables defined:
- `PAK_NAME` — read from `pak.json` using `jq`
- `ARCHITECTURES` — `arm arm64`
- `PLATFORMS` — `miyoomini my282 rg35xxplus tg5040`
- Pinned versions for each dependency

Targets:
- `clean` — delete downloaded binaries
- `build` — download all binary dependencies
- `bump-version` — update `pak.json` version in place
- `release` — `build` + `git archive` + append downloaded bins → zip file

Binary download pattern:
```makefile
bin/%/minui-list:
    mkdir -p bin/$*
    curl -f -o bin/$*/minui-list -sSL https://github.com/josegonzalez/minui-list/releases/download/$(VERSION)/minui-list-$*
    chmod +x bin/$*/minui-list
```

The release artifact is created with:
```sh
git archive --format=zip --output dist/<NAME>.pak.zip HEAD
# Then zip -r appends the downloaded binaries (not tracked by git)
while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$file"; done < .gitarchiveinclude
```

---

## pak.json

```json
{
  "name": "Tailscale",
  "version": "1.2.0",
  "type": "TOOL",
  "description": "A Pak wrapping Tailscale, a secure and easy-to-use VPN.",
  "author": "ben16w",
  "repo_url": "https://github.com/ben16w/minui-tailscale",
  "release_filename": "Tailscale.pak.zip",
  "banners": { "BRICK": ".github/resources/banner.png" },
  "platforms": ["tg5040"],
  "update_ignore": ["config.json"],
  "launch": "launch.sh"
}
```

---

## config.json

Defines the settings menu shown by `minui-list`. Each entry has:
- `name` — display label
- `options` — array of option strings
- `selected` — index of current selection

```json
{
    "settings": [
        { "name": "Enable",        "options": ["false", "true"], "selected": 0 },
        { "name": "Start on boot", "options": ["false", "true"], "selected": 0 }
    ]
}
```

---

## launch.sh Walkthrough

Entry point called by NextUI when the user opens the pak from the Tools menu.

### Initialization
```sh
PAK_DIR="$(dirname "$0")"
PAK_NAME="$(basename "$PAK_DIR")" ; PAK_NAME="${PAK_NAME%.*}"
exec >>"$LOGS_PATH/$PAK_NAME.txt" 2>&1    # redirect all output to log file
mkdir -p "$USERDATA_PATH/$PAK_NAME"       # persistent storage dir
architecture=arm ; uname -m | grep -q '64' && architecture=arm64
export PATH="$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin:$PATH"
```

### Environment Variables (provided by NextUI)
| Variable         | Value                                             |
|------------------|---------------------------------------------------|
| `PLATFORM`       | `tg5040` (or `tg3040` — normalized in script)    |
| `SDCARD_PATH`    | Root of SD card (e.g., `/mnt/sdcard`)             |
| `LOGS_PATH`      | Log directory                                     |
| `USERDATA_PATH`  | Persistent user data directory                    |
| `PAK_DIR`        | Directory containing the `.pak` folder            |

### Key Functions
- `show_message <text> [seconds]` — displays overlay via `minui-presenter`
- `is_service_running` — uses `pgrep` to check daemon
- `wait_for_service <n>` / `wait_for_service_to_stop <n>` — poll up to n seconds
- `get_service_pid` — returns PID of daemon
- `current_settings` — builds settings JSON with current live state injected
- `main_screen <settings>` — renders `minui-list` menu, returns new settings JSON
- `enable_start_on_boot` / `disable_start_on_boot` — edits `auto.sh` on SD card
- `will_start_on_boot` — greps `auto.sh` for the pak's boot line
- `cleanup` — removes temp files, kills `minui-presenter`

### Main Loop
1. Build `current_settings` JSON (reflects live service state)
2. Show `main_screen` via `minui-list`
3. If user pressed Back/Menu → exit
4. Compare old vs new settings
5. If Enable changed → start or stop the service
6. If Start on Boot changed → edit `auto.sh`
7. Loop back to step 1

### Auto-Start Pattern
The `on-boot` script is referenced in `auto.sh` with a unique comment tag:
```sh
test -f "$PAK_DIR/bin/on-boot" && "$PAK_DIR/bin/on-boot" # Tailscale.pak-on-boot
```
`enable_start_on_boot` appends this line; `disable_start_on_boot` uses `sed -i` to remove it.

### on-boot Script
```sh
#!/bin/sh
# ... preamble: set paths, logging, architecture detection ...
"$PAK_DIR/bin/$architecture/tailscaled" \
  --statedir="$USERDATA_PATH/$PAK_NAME/" \
  --no-logs-no-support &
```
Starts the daemon in the background; the kernel/TUN path is handled by tailscaled internally.

---

## UI Tools

### minui-list
- Renders a scrollable list of settings with toggle options
- Input: JSON file with `settings` array
- Output: updated JSON with new `selected` values (written to state)
- Exit codes: `0` = confirmed, `2` = back, `3` = menu button

### minui-presenter
- Displays a simple full-screen message overlay
- Options: `--message`, `--timeout` (-1 = wait forever, N = auto-dismiss after N seconds)
- Run in background with `&` for non-blocking messages
- Kill with `killall minui-presenter`

---

## Key Patterns We'll Reuse

1. **Logging**: Redirect stdout+stderr to `$LOGS_PATH/$PAK_NAME.txt`
2. **Architecture detection**: `uname -m | grep -q '64' && architecture=arm64`
3. **PATH injection**: `$PAK_DIR/bin/$architecture:$PAK_DIR/bin/$PLATFORM:$PAK_DIR/bin`
4. **Config file toggle**: persist settings by editing `config.json` (via jq/temp file swap)
5. **Boot hook**: append/remove one line in `auto.sh` with a unique comment tag
6. **stay_awake**: `echo 1 > /tmp/stay_awake` prevents screen sleep while pak is running
7. **Auth import**: one-time import of a file from SD root (authkey → wg0.conf)

---

## Differences for WireGuard Pak

| Aspect            | Tailscale                   | WireGuard                                |
|-------------------|-----------------------------|------------------------------------------|
| Daemon            | `tailscaled` (always runs)  | None / `wireguard-go` (only if no kmod)  |
| Config import     | `authkey` file at SD root   | `wg0.conf` file at SD root              |
| State dir         | `tailscaled --statedir`     | `$USERDATA_PATH/WireGuard/wg0.conf`      |
| Status info       | `tailscale ip -1`           | `ip addr show wg0` + `wg show wg0`      |
| Login step        | `tailscale up --authkey`    | No login — config IS the credential      |
| Service check     | `pgrep tailscaled`          | Check if `wg0` interface exists          |
| Tear-down         | `killall tailscaled`        | `ip link del wg0` + optionally kill wg-go |
