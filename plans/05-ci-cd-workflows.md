# Task 05: GitHub Actions CI/CD Workflows

## Goal
Write two GitHub Actions workflows:
1. **CI** (`ci.yaml`) — runs on pull requests and pushes to `master`; validates the build
2. **Release** (`release.yaml`) — triggered by pushing a `vX.X.X` tag; builds `wireguard-go` binaries,
   creates the release zip, and publishes a GitHub Release

## File Locations
- `.github/workflows/ci.yaml`
- `.github/workflows/release.yaml`

---

## CI Workflow (`ci.yaml`)

Triggered on: push to `master`, pull request to `master`

Steps:
1. Checkout repo
2. Install `jq` on the runner
3. Validate `pak.json` is valid JSON: `jq . pak.json`
4. Validate `pak.json` has required fields
5. Run `make build` (downloads all binaries)
6. Run `make release` (produces zip)
7. Verify zip structure is correct

```yaml
name: CI

on:
  push:
    branches: [master]
  pull_request:
    branches: [master]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: sudo apt-get install -y jq zip curl

      - name: Validate pak.json
        run: |
          jq . pak.json
          for field in name version type description author repo_url release_filename platforms; do
            val=$(jq -r ".$field" pak.json)
            [ "$val" = "null" ] && { echo "Missing required field: $field"; exit 1; }
          done

      - name: Build
        run: make build

      - name: Release
        run: make release

      - name: Verify zip structure
        run: |
          unzip -l dist/WireGuard.pak.zip | grep -E "launch.sh|pak.json|bin/"
```

---

## Release Workflow (`release.yaml`)

Triggered on: push of a tag matching `v*.*.*`

Extra step vs CI: Build `wireguard-go` from source for both `arm` and `arm64`.

```yaml
name: Release

on:
  push:
    tags:
      - 'v*.*.*'

jobs:
  release:
    runs-on: ubuntu-latest
    permissions:
      contents: write

    steps:
      - uses: actions/checkout@v4

      - name: Install dependencies
        run: sudo apt-get install -y jq zip curl

      - name: Set up Go (for wireguard-go)
        uses: actions/setup-go@v5
        with:
          go-version: '1.22'

      - name: Build wireguard-go for arm64
        run: |
          git clone https://github.com/WireGuard/wireguard-go /tmp/wireguard-go
          cd /tmp/wireguard-go
          GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o /tmp/wireguard-go-arm64 .
          mkdir -p $GITHUB_WORKSPACE/bin/arm64
          cp /tmp/wireguard-go-arm64 $GITHUB_WORKSPACE/bin/arm64/wireguard-go
          chmod +x $GITHUB_WORKSPACE/bin/arm64/wireguard-go

      - name: Build wireguard-go for arm
        run: |
          cd /tmp/wireguard-go
          GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -o /tmp/wireguard-go-arm .
          mkdir -p $GITHUB_WORKSPACE/bin/arm
          cp /tmp/wireguard-go-arm $GITHUB_WORKSPACE/bin/arm/wireguard-go
          chmod +x $GITHUB_WORKSPACE/bin/arm/wireguard-go

      - name: Extract version from tag
        id: version
        run: echo "version=${GITHUB_REF#refs/tags/v}" >> $GITHUB_OUTPUT

      - name: Update pak.json version
        run: make bump-version RELEASE_VERSION=${{ steps.version.outputs.version }}

      - name: Build all other binaries
        run: make build

      - name: Create release zip
        run: make release

      - name: Create GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: dist/WireGuard.pak.zip
          generate_release_notes: true
          draft: false
          prerelease: false
```

## Steps

1. Create `.github/workflows/ci.yaml`
2. Create `.github/workflows/release.yaml`
3. Push to a branch and verify CI runs successfully
4. Test release workflow by creating a `v1.0.0` tag (after all other tasks are done)

## Expected Outcome
- CI runs on every PR/push and validates the build
- Release workflow produces a valid `WireGuard.pak.zip` asset on the GitHub Release
- The release zip passes the pak store requirements (correct structure, valid pak.json version)
