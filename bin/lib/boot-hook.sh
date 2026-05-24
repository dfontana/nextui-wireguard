# Boot-hook management: register or unregister this pak's on-boot script in
# MinUI's auto.sh.
# Sourced by launch.sh. Do not add a shebang.
#
# Requires the following env vars:
#   PAK_NAME       e.g. "WireGuard"
#   PLATFORM       e.g. "tg5040"
#   SDCARD_PATH    e.g. /mnt/SDCARD

disable_start_on_boot() {
    sed -i "/${PAK_NAME}.pak-on-boot/d" "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    sync
}

enable_start_on_boot() {
    # Idempotent — if the marker is already in auto.sh, do nothing. Otherwise a
    # second toggle (or any external state drift) would append duplicate hook lines.
    will_start_on_boot && return 0
    if [ ! -f "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh" ]; then
        echo '#!/bin/sh' >"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
        echo '' >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    fi
    echo "test -f \"\$SDCARD_PATH/Tools/\$PLATFORM/$PAK_NAME.pak/bin/on-boot\" && \"\$SDCARD_PATH/Tools/\$PLATFORM/$PAK_NAME.pak/bin/on-boot\" # ${PAK_NAME}.pak-on-boot" >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    chmod +x "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
    sync
}

will_start_on_boot() {
    grep -q "${PAK_NAME}.pak-on-boot" "$SDCARD_PATH/.userdata/$PLATFORM/auto.sh" 2>/dev/null
}
