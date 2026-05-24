PAK_NAME := $(shell jq -r .name pak.json)

ARCHITECTURES := arm64
PLATFORMS     := tg5040

MINUI_LIST_VERSION      := 0.11.3
MINUI_PRESENTER_VERSION := 0.7.0
JQ_VERSION              := 1.7.1

# Alpine Linux version used as the arm64 build container for wg.
# wg is compiled with LDFLAGS=-static inside an Alpine/musl container so the
# resulting binary is fully self-contained and runs on any Linux ABI (glibc,
# musl, uclibc). The TrimUI Brick uses glibc 2.33, which cannot run Alpine's
# pre-built musl-dynamic wg binary.
# Requires Docker with arm64 QEMU support; in CI that is set up by the release
# workflow before calling `make build`.
ALPINE_VERSION := 3.21

# wireguard-go built from source by the release workflow (see .github/workflows/release.yaml)
# For local development, build manually:
#   git clone https://github.com/WireGuard/wireguard-go /tmp/wireguard-go
#   cd /tmp/wireguard-go
#   GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bin/arm64/wireguard-go .

DEVICE ?= root@192.168.50.57

.PHONY: clean bump-version build release deploy

clean:
	rm -f bin/*/minui-list bin/*/minui-presenter
	rm -f bin/arm64/jq bin/arm64/wg bin/arm64/wireguard-go
	rm -f bin/*/*.LICENSE

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

bin/arm64/jq:
	mkdir -p bin/arm64
	curl -f -o bin/arm64/jq -sSL \
		https://github.com/jqlang/jq/releases/download/jq-$(JQ_VERSION)/jq-linux-arm64
	chmod +x bin/arm64/jq
	curl -sSL -o bin/arm64/jq.LICENSE \
		"https://github.com/jqlang/jq/raw/refs/heads/master/COPYING"

# Build wg statically inside an Alpine arm64 Docker container so the binary
# runs on any Linux ABI. Requires Docker with arm64 QEMU binfmt support.
# In CI the release workflow enables QEMU before calling `make build`.
# Locally: docker run --privileged --rm tonistiigi/binfmt --install arm64
bin/arm64/wg:
	mkdir -p bin/arm64
	docker run --rm --platform linux/arm64 \
		-v "$(CURDIR)/bin/arm64:/output" \
		alpine:$(ALPINE_VERSION) sh -c \
		'apk add --no-cache build-base libmnl-dev libmnl-static git && \
		 git clone --depth=1 https://git.zx2c4.com/wireguard-tools /tmp/wt && \
		 LDFLAGS="-static" make -C /tmp/wt/src wg && \
		 cp /tmp/wt/src/wg /output/wg && chmod +x /output/wg'
	curl -sSL -o bin/arm64/wg.LICENSE \
		"https://git.zx2c4.com/wireguard-tools/plain/COPYING"

# wireguard-go is built by the release GitHub Actions workflow.
# For local development, see the comment at the top of this Makefile.
bin/arm64/wireguard-go:
	@echo "wireguard-go must be built from source (Go required)."
	@echo "See: https://github.com/WireGuard/wireguard-go"
	@echo "Build: GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -o bin/arm64/wireguard-go ."
	@exit 1

PAK_FILES := \
	launch.sh \
	pak.json \
	config.json \
	bin/on-boot \
	$(foreach platform,$(PLATFORMS),bin/$(platform)/minui-list bin/$(platform)/minui-presenter) \
	$(foreach arch,$(ARCHITECTURES),bin/$(arch)/jq bin/$(arch)/wg bin/$(arch)/wireguard-go)

release: build
	mkdir -p dist
	zip "dist/$(PAK_NAME).pak.zip" $(PAK_FILES)
	ls -lah dist

deploy: release
	./deploy.sh
