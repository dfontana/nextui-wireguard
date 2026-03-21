# Task 02: Makefile — Binary Downloads

## Goal
Write a complete `Makefile` that downloads all required pre-built binaries for the pak.
Running `make build` should produce all binaries in `bin/`. Running `make release` should
produce `dist/WireGuard.pak.zip`.

## Binaries Required

| Binary            | Arch   | Source                                                          |
|-------------------|--------|-----------------------------------------------------------------|
| `minui-list`      | tg5040 | github.com/josegonzalez/minui-list releases                    |
| `minui-presenter` | tg5040 | github.com/josegonzalez/minui-presenter releases               |
| `jq`              | arm    | github.com/jqlang/jq releases (`jq-linux-armhf`)               |
| `jq`              | arm64  | github.com/jqlang/jq releases (`jq-linux-arm64`)               |
| `wg`              | arm    | Alpine Linux edge community armhf `wireguard-tools-wg` APK     |
| `wg`              | arm64  | Alpine Linux edge community aarch64 `wireguard-tools-wg` APK   |
| `wireguard-go`    | arm    | Built from source by GitHub Actions workflow (see Task 05)     |
| `wireguard-go`    | arm64  | Built from source by GitHub Actions workflow (see Task 05)     |

### Alpine APK Extraction

Alpine Linux `.apk` files are gzipped tarballs. The `wg` binary lives at `usr/bin/wg`:
```sh
curl -o /tmp/wg.apk <ALPINE_URL>
tar -xzf /tmp/wg.apk -C /tmp usr/bin/wg
mv /tmp/usr/bin/wg bin/<arch>/wg
chmod +x bin/<arch>/wg
rm /tmp/wg.apk
```

Find the current Alpine edge community package versions at:
- aarch64: https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/
- armhf: https://dl-cdn.alpinelinux.org/alpine/edge/community/armhf/

Look for `wireguard-tools-wg-*.apk`.

### wireguard-go Binaries
These are built by the release GitHub Actions workflow (Task 05) and then re-downloaded or
included. For local `make build`, the Makefile should either:
- Download them from the repo's own GitHub release (for release builds)
- OR skip if not present (local dev: `wireguard-go` is optional if kernel module is present)

Document the `wireguard-go` download target as a `TODO` with clear instructions.

## Makefile Structure

```makefile
PAK_NAME := $(shell jq -r .name pak.json)

ARCHITECTURES := arm arm64
PLATFORMS     := tg5040

MINUI_LIST_VERSION      := 0.11.3
MINUI_PRESENTER_VERSION := 0.7.0
JQ_VERSION              := 1.7.1
WIREGUARD_TOOLS_VERSION := 1.0.20210914  # version in Alpine package name
WIREGUARD_GO_VERSION    := 0.0.20230223  # tag from wireguard-go releases

.PHONY: clean bump-version build release

clean:
    rm -f bin/*/minui-list* bin/*/minui-presenter* bin/*/jq* bin/*/wg* bin/*/wireguard-go*

bump-version:
    jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp && mv pak.json.tmp pak.json

build: <list all targets>

bin/%/minui-list:
    # download from josegonzalez/minui-list

bin/%/minui-presenter:
    # download from josegonzalez/minui-presenter

bin/arm/jq:
    # download jq-linux-armhf

bin/arm64/jq:
    # download jq-linux-arm64

bin/arm/wg:
    # extract from Alpine Linux armhf APK

bin/arm64/wg:
    # extract from Alpine Linux aarch64 APK

bin/arm/wireguard-go:
    # TODO: download from self-hosted build or GitHub Actions artifact

bin/arm64/wireguard-go:
    # TODO: download from self-hosted build or GitHub Actions artifact

release: build
    mkdir -p dist
    git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
    while IFS= read -r file; do zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; done < .gitarchiveinclude
    ls -lah dist
```

## Steps

1. Find current Alpine edge community package URLs for `wireguard-tools-wg` for aarch64 and armhf
   - Visit: https://pkgs.alpinelinux.org/packages?name=wireguard-tools-wg&arch=aarch64
   - OR browse: https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/
   - Note the exact filename including version and build suffix
2. Find the latest `minui-list` and `minui-presenter` version numbers at josegonzalez's releases
3. Write the complete Makefile with all download targets filled in
4. Run `make build` and verify all binaries download correctly and are executable
5. Run `make release` and verify `dist/WireGuard.pak.zip` is produced with correct structure
6. Verify zip structure: `unzip -l dist/WireGuard.pak.zip | head -30` — no nested folder at root

## Expected Outcome
- `make clean build` downloads all binaries without errors
- `bin/tg5040/minui-list`, `bin/tg5040/minui-presenter` are executable
- `bin/arm64/jq`, `bin/arm64/wg` are executable static binaries
- `make release` produces a valid `dist/WireGuard.pak.zip`
- The zip, when extracted, can be placed directly in `SD/Tools/tg5040/WireGuard.pak/`
