#!/bin/sh
set -e

DEVICE="${DEVICE:-root@192.168.50.57}"
PAK_DIR="/mnt/SDCARD/Tools/tg5040/WireGuard.pak"
ZIP="dist/WireGuard.pak.zip"

if [ ! -f "$ZIP" ]; then
    echo "No release zip found — run 'make release' first"
    exit 1
fi

tmp=$(mktemp -d)
trap "rm -rf $tmp" EXIT

unzip -q "$ZIP" -d "$tmp"
tar -cf - -C "$tmp" . | ssh "$DEVICE" "tar -xf - -C $PAK_DIR"

echo "Deployed to $DEVICE:$PAK_DIR"
