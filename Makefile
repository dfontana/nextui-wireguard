PAK_NAME := $(shell jq -r .name pak.json)

ARCHITECTURES := arm arm64
PLATFORMS     := tg5040

MINUI_LIST_VERSION      := 0.11.3
MINUI_PRESENTER_VERSION := 0.7.0
JQ_VERSION              := 1.7.1

# Alpine Linux edge/community package version for wireguard-tools-wg
# Check latest at: https://pkgs.alpinelinux.org/packages?name=wireguard-tools-wg
WIREGUARD_TOOLS_VERSION := 1.0.20210914-r2

# wireguard-go built from source by the release workflow (see .github/workflows/release.yaml)
# For local development, build manually:
#   git clone https://github.com/WireGuard/wireguard-go /tmp/wireguard-go
#   cd /tmp/wireguard-go
#   GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bin/arm64/wireguard-go .
#   GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 go build -o bin/arm/wireguard-go .

.PHONY: clean bump-version build release

clean:
	rm -f bin/*/minui-list bin/*/minui-presenter || true
	rm -f bin/arm/jq bin/arm64/jq || true
	rm -f bin/arm/wg bin/arm64/wg || true
	rm -f bin/arm/wireguard-go bin/arm64/wireguard-go || true
	rm -f bin/*/*.LICENSE || true

bump-version:
	jq '.version = "$(RELEASE_VERSION)"' pak.json > pak.json.tmp
	mv pak.json.tmp pak.json

build: \
	$(foreach platform,$(PLATFORMS),bin/$(platform)/minui-list bin/$(platform)/minui-presenter) \
	$(foreach arch,$(ARCHITECTURES),bin/$(arch)/jq bin/$(arch)/wg)

bin/%/minui-list:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-list -sSL \
		https://github.com/josegonzalez/minui-list/releases/download/$(MINUI_LIST_VERSION)/minui-list-$*
	chmod +x bin/$*/minui-list

bin/%/minui-presenter:
	mkdir -p bin/$*
	curl -f -o bin/$*/minui-presenter -sSL \
		https://github.com/josegonzalez/minui-presenter/releases/download/$(MINUI_PRESENTER_VERSION)/minui-presenter-$*
	chmod +x bin/$*/minui-presenter

bin/arm/jq:
	mkdir -p bin/arm
	curl -f -o bin/arm/jq -sSL \
		https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-armhf
	chmod +x bin/arm/jq
	curl -sSL -o bin/arm/jq.LICENSE \
		"https://github.com/jqlang/jq/raw/refs/heads/master/COPYING"

bin/arm64/jq:
	mkdir -p bin/arm64
	curl -f -o bin/arm64/jq -sSL \
		https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-arm64
	chmod +x bin/arm64/jq
	curl -sSL -o bin/arm64/jq.LICENSE \
		"https://github.com/jqlang/jq/raw/refs/heads/master/COPYING"

# Extract wg from Alpine Linux wireguard-tools-wg package (gzipped tarball / APK format)
bin/arm64/wg:
	mkdir -p bin/arm64 /tmp/wg-arm64-extract
	curl -f -sSL -o /tmp/wg-arm64.apk \
		"https://dl-cdn.alpinelinux.org/alpine/edge/community/aarch64/wireguard-tools-wg-$(WIREGUARD_TOOLS_VERSION).apk"
	tar -xzf /tmp/wg-arm64.apk -C /tmp/wg-arm64-extract usr/bin/wg 2>/dev/null || \
		tar -xzf /tmp/wg-arm64.apk -C /tmp/wg-arm64-extract
	find /tmp/wg-arm64-extract -name 'wg' -type f -exec cp {} bin/arm64/wg \;
	chmod +x bin/arm64/wg
	rm -rf /tmp/wg-arm64.apk /tmp/wg-arm64-extract
	curl -sSL -o bin/arm64/wg.LICENSE \
		"https://git.zx2c4.com/wireguard-tools/plain/COPYING"

bin/arm/wg:
	mkdir -p bin/arm /tmp/wg-arm-extract
	curl -f -sSL -o /tmp/wg-arm.apk \
		"https://dl-cdn.alpinelinux.org/alpine/edge/community/armhf/wireguard-tools-wg-$(WIREGUARD_TOOLS_VERSION).apk"
	tar -xzf /tmp/wg-arm.apk -C /tmp/wg-arm-extract usr/bin/wg 2>/dev/null || \
		tar -xzf /tmp/wg-arm.apk -C /tmp/wg-arm-extract
	find /tmp/wg-arm-extract -name 'wg' -type f -exec cp {} bin/arm/wg \;
	chmod +x bin/arm/wg
	rm -rf /tmp/wg-arm.apk /tmp/wg-arm-extract
	curl -sSL -o bin/arm/wg.LICENSE \
		"https://git.zx2c4.com/wireguard-tools/plain/COPYING"

# wireguard-go is built by the release GitHub Actions workflow.
# For local development, see the comment at the top of this Makefile.
bin/arm64/wireguard-go bin/arm/wireguard-go:
	@echo "wireguard-go must be built from source (Go required)."
	@echo "See: https://github.com/WireGuard/wireguard-go"
	@echo "Build: GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bin/arm64/wireguard-go ."
	@exit 1

release: build
	mkdir -p dist
	git archive --format=zip --output "dist/$(PAK_NAME).pak.zip" HEAD
	while IFS= read -r file; do \
		if [ -f "$$file" ]; then \
			zip -r "dist/$(PAK_NAME).pak.zip" "$$file"; \
		fi; \
	done < .gitarchiveinclude
	ls -lah dist
