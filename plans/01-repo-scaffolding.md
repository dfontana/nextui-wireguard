# Task 01: Repository Scaffolding

## Goal
Create the static, non-binary scaffolding files for the pak repository. These files define the
pak's identity, metadata, and build configuration skeleton. No binaries are downloaded yet.

## Files to Create

### `pak.json`
Pak store metadata. Adapt from minui-tailscale.

```json
{
  "name": "WireGuard",
  "version": "1.0.0",
  "type": "TOOL",
  "description": "A Pak for connecting to a WireGuard VPN on TrimUI Brick.",
  "author": "dfontana",
  "repo_url": "https://github.com/dfontana/nextui-wireguard",
  "release_filename": "WireGuard.pak.zip",
  "banners": {
    "BRICK": ".github/resources/banner.png"
  },
  "platforms": ["tg5040"],
  "update_ignore": ["config.json"],
  "launch": "launch.sh"
}
```

### `config.json`
Settings definition for the `minui-list` UI. Three settings:
1. **Enable** — toggle WireGuard on/off
2. **Start on boot** — auto-connect on device startup
3. **Import Config** — trigger import of `wg0.conf` from SD root (one-time)

```json
{
    "settings": [
        {
            "name": "Enable",
            "options": ["false", "true"],
            "selected": 0
        },
        {
            "name": "Start on boot",
            "options": ["false", "true"],
            "selected": 0
        }
    ]
}
```

### `LICENSE`
MIT License with the author's name and current year.

### `.gitignore`
Ignore downloaded binary files and build artifacts:
```
bin/*/minui-list
bin/*/minui-presenter
bin/arm/jq
bin/arm64/jq
bin/arm/wg
bin/arm64/wg
bin/arm/wireguard-go
bin/arm64/wireguard-go
bin/*/*.LICENSE
dist/
```

### `.gitattributes`
Mark shell scripts as text with LF line endings:
```
*.sh text eol=lf
```

### `.gitarchiveinclude`
List of downloaded binary paths to include in the release zip (not tracked by git):
```
bin/tg5040/minui-list
bin/tg5040/minui-presenter
bin/arm64/jq
bin/arm64/wg
bin/arm64/wireguard-go
bin/arm/jq
bin/arm/wg
bin/arm/wireguard-go
```

### `bin/.gitkeep`
Empty file to ensure the `bin/` directory is tracked by git.

### `Makefile` skeleton
Define variables and targets. See Task 02 for full Makefile implementation.

## Steps

1. Create `pak.json` with the content above
2. Create `config.json` with the content above
3. Create `LICENSE` (MIT, year 2025, author dfontana)
4. Create `.gitignore`
5. Create `.gitattributes`
6. Create `.gitarchiveinclude`
7. Create `bin/.gitkeep` (empty file)
8. Run `git add` and verify with `git status` — all files tracked, no binaries staged

## Expected Outcome
`git status` shows all scaffolding files as new/modified. `git diff HEAD` contains no binary data.
The repo structure matches the minui-tailscale pattern with WireGuard-specific metadata.
