# NextUI Pak Store Specification

Sources:
- https://github.com/LoveRetro/nextui-pak-store
- https://github.com/LoveRetro/NextUI (PAKS.md)
- minui-tailscale reference implementation

---

## What is a Pak?

A "pak" is a self-contained software package for NextUI (the custom firmware for TrimUI devices).
Paks are installed under `SD_ROOT/Tools/` and appear in the NextUI Tools menu. They can be:
- **TOOL** — utility that runs when selected
- **EMULATOR** — emulator with its own ROM library

Paks are distributed via the **Pak Store**, which is a tool that comes pre-installed with NextUI
and allows users to browse and install paks from the official pak-store repository.

---

## Directory Structure on Device

```
SD_ROOT/
├── Tools/
│   └── tg5040/
│       └── WireGuard.pak/   ← the pak folder (note .pak extension on folder)
│           ├── launch.sh    ← entry point (named in pak.json "launch" field)
│           ├── pak.json
│           ├── config.json
│           ├── bin/
│           │   ├── on-boot
│           │   ├── arm64/   ← arch-specific binaries
│           │   └── tg5040/  ← platform-specific binaries (minui-list, minui-presenter)
│           └── ...
└── .userdata/
    └── tg5040/
        ├── auto.sh          ← boot hook script
        └── WireGuard/       ← persistent pak data ($USERDATA_PATH/WireGuard/)
```

---

## pak.json Format

Required fields:

| Field              | Type           | Description                                               |
|--------------------|----------------|-----------------------------------------------------------|
| `name`             | string         | Pak display name (also used as identifier)                |
| `version`          | string         | Semantic version (`vX.X.X` format matching git tag)       |
| `type`             | string         | Category: `TOOL` or `EMULATOR`                            |
| `description`      | string         | Short description shown in the pak store                  |
| `author`           | string         | Creator name/handle                                       |
| `repo_url`         | string         | GitHub repository URL                                     |
| `release_filename` | string         | Name of the zip file in the GitHub release assets         |
| `platforms`        | array[string]  | Target devices: e.g., `["tg5040"]`                       |

Optional fields:

| Field           | Type           | Description                                                    |
|-----------------|----------------|----------------------------------------------------------------|
| `launch`        | string         | Entry point script, default `launch.sh`                        |
| `banners`       | object         | Device → image path for pak store banner (`"BRICK": "img.png"`)  |
| `update_ignore` | array[string]  | Files NOT overwritten during pak updates (e.g., `config.json`) |
| `changelog`     | string/object  | Version history shown in pak store                             |
| `screenshots`   | array[string]  | Paths to screenshot images for pak store listing               |

### Platform Identifiers
| Device          | Platform ID |
|-----------------|-------------|
| TrimUI Brick    | `tg5040`    |
| TrimUI Smart Pro | `tg3040`   |
| Miyoo Mini+     | `miyoomini` |
| RG35XX Plus     | `rg35xxplus`|

---

## Release Artifact Format

The release zip must contain all pak files at the **root level** (not nested in a subdirectory),
so that when extracted into `WireGuard.pak/` the structure is correct.

Build with:
```sh
git archive --format=zip --output dist/WireGuard.pak.zip HEAD
# Append downloaded binaries (not tracked by git):
while IFS= read -r file; do zip -r "dist/WireGuard.pak.zip" "$file"; done < .gitarchiveinclude
```

The `.gitarchiveinclude` file lists paths of downloaded/built binaries to append:
```
bin/tg5040/minui-list
bin/tg5040/minui-presenter
bin/arm64/jq
bin/arm64/wg
bin/arm64/wireguard-go
```

Git release tag must match `pak.json` version exactly: tag `v1.0.0` → `pak.json` `"version": "1.0.0"`.

---

## Submission to Pak Store

To submit a new pak to the official store:
1. Create a GitHub release with the zip artifact
2. Submit via the official GitHub issue form at: https://github.com/LoveRetro/nextui-pak-store/issues
3. Include: display name, repository URL, desired categories
4. Community review → maintainer publishes the pak

---

## Local Development Installation (Before Store Submission)

To test a pak on the device before it's on the official store:

### Method 1: Manual SD Card Copy
```sh
# On your dev machine, after `make release`:
unzip dist/WireGuard.pak.zip -d /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/
```
Then boot the device — the pak appears in NextUI → Tools menu.

### Method 2: Direct Build Copy
Copy the whole project directory (with downloaded binaries) directly:
```sh
rsync -av --exclude='.git' --exclude='dist' . /Volumes/SDCARD/Tools/tg5040/WireGuard.pak/
```

### Method 3: Via Pak Store (Development Mode)
The Pak Store tool has a "Local Paks" or similar feature in development. Check the NextUI docs.

---

## NextUI Environment Variables

When NextUI launches a pak's `launch.sh`, these environment variables are set:

| Variable        | Description                                           | Example                              |
|-----------------|-------------------------------------------------------|--------------------------------------|
| `PLATFORM`      | Device platform identifier                            | `tg5040`                             |
| `DEVICE`        | Device model (may be empty, set by script if needed)  | `brick`                              |
| `SDCARD_PATH`   | Absolute path to SD card root                         | `/mnt/sdcard`                        |
| `USERDATA_PATH` | Persistent data dir (survives firmware updates)       | `/mnt/sdcard/.userdata/tg5040`       |
| `LOGS_PATH`     | Log file directory                                    | `/mnt/sdcard/.userdata/tg5040/logs`  |

Note: Some older firmware uses `tg3040` for the Brick — normalize with:
```sh
if [ "$PLATFORM" = "tg3040" ] && [ -z "$DEVICE" ]; then
    export DEVICE="brick"
    export PLATFORM="tg5040"
fi
```
