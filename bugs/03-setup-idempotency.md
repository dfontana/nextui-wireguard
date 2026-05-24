# Setup Steps That Misbehave When Re-Run

Two unrelated setup helpers fail when the precondition they assume is violated. Both surface only after the user has used the pak more than once, or on a fresh install where directories haven't been created yet. Different files, different fixes — grouped here because both are "make a setup step robust to its actual runtime environment."

---

## Bug 1: `enable_start_on_boot` appends duplicate hook lines

**Affected file**: `bin/lib/boot-hook.sh` (function `enable_start_on_boot`)

### Symptom
After toggling "Start on boot" off then on multiple times, `/mnt/SDCARD/.userdata/tg5040/auto.sh` accumulates duplicate WireGuard hook lines. On reboot, the on-boot script runs once per duplicate (or once total, depending on shell parsing — but the file grows unboundedly either way and slows boot inspection).

Even one extra cycle is a real bug: a user who toggles the setting off and on once gets two identical lines in `auto.sh`.

### Reproduction
1. SSH to device: `ssh root@192.168.50.57`
2. Toggle "Start on boot" ON via the pak menu. Inspect:
   ```sh
   cat /mnt/SDCARD/.userdata/tg5040/auto.sh
   ```
   You'll see one line ending in `# WireGuard.pak-on-boot`.
3. Toggle OFF, then ON again.
4. `cat /mnt/SDCARD/.userdata/tg5040/auto.sh` — should still have one line, but actually still does (because `disable_start_on_boot` did clean up first). So this case is *safe* in normal usage.
5. **The bug triggers** when the toggle state shown in the menu disagrees with the actual file contents. E.g., the user enables on-boot, then manually edits `auto.sh`, then toggles in the UI. Or, more commonly: a config.json that doesn't get re-read after an external edit. In any case, two consecutive `enable_start_on_boot` calls produce two lines.
6. To force-reproduce: from device shell, source `bin/lib/boot-hook.sh` and call `enable_start_on_boot` twice. Inspect `auto.sh` — two identical lines.

### Root cause
`enable_start_on_boot` appends unconditionally:
```sh
echo "test -f \"\$SDCARD_PATH/...\" && \"...\" # ${PAK_NAME}.pak-on-boot" >>"$SDCARD_PATH/.userdata/$PLATFORM/auto.sh"
```
There's no "already enabled?" check. `will_start_on_boot` exists and is the natural guard — it greps for the marker comment — but `enable_start_on_boot` doesn't use it.

### Fix approach
Guard at the top of `enable_start_on_boot`:
```sh
enable_start_on_boot() {
    will_start_on_boot && return 0
    # ...existing append logic...
}
```

Or run a `disable_start_on_boot` first to clear any stale entries, then append. The guard is simpler.

### Verification
1. Deploy fix, SSH in.
2. Manually call `enable_start_on_boot` (after sourcing) — observe one line appears.
3. Call it again — line count unchanged.
4. Call `disable_start_on_boot`, then `enable_start_on_boot` twice — still one line.

---

## Bug 2: `init_logging` silently drops output if `$LOGS_PATH` doesn't exist

**Affected file**: `bin/lib/common.sh` (function `init_logging`)

### Symptom
On a fresh device or after `LOGS_PATH` has been deleted, launching the pak produces no log file. The Troubleshooting section of the README directs users to `$LOGS_PATH/WireGuard.txt` for diagnosis — but the file is silently absent. Worse, when this fails, the rest of the pak runs *without* stdout/stderr capture, so any failure messages are lost (`exec >> /nonexistent/path` redirects to nowhere and subsequent prints disappear).

### Reproduction
1. SSH to device: `rm -rf /mnt/SDCARD/.userdata/tg5040/logs/`
2. Launch the pak from the menu. (Or run `bin/on-boot` manually.)
3. Note: no log file is created. Any errors are invisible.

In practice the logs dir is usually present (MinUI creates it), so this bug surfaces mainly after manual cleanup, SD card replacement, or first install on a fresh card.

### Root cause
`init_logging` does:
```sh
init_logging() {
    log_name="$1"
    rm -f "$LOGS_PATH/$log_name"
    exec >>"$LOGS_PATH/$log_name"
    exec 2>&1
}
```
If `$LOGS_PATH` doesn't exist, the `rm -f` is a no-op and `exec >>` opens a file in a nonexistent directory — which on most shells errors out and leaves the original fd alone (so output goes to `/dev/null` via the parent's redirect) OR crashes the script depending on shell. BusyBox ash exits the redirect silently and continues, meaning all subsequent prints go nowhere.

### Fix approach
Create the directory before redirecting:
```sh
init_logging() {
    log_name="$1"
    mkdir -p "$LOGS_PATH"
    rm -f "$LOGS_PATH/$log_name"
    exec >>"$LOGS_PATH/$log_name"
    exec 2>&1
}
```

### Verification
1. Deploy fix, SSH in.
2. `rm -rf /mnt/SDCARD/.userdata/tg5040/logs/`
3. Launch the pak.
4. Confirm `/mnt/SDCARD/.userdata/tg5040/logs/WireGuard.txt` exists and contains the session log.

---

## Why grouped

Both bugs are "the setup step assumes something that isn't always true" (enable assumes not-already-enabled; redirect assumes dir-exists). Fixes are mechanically similar — a one-line guard at the top of each function — but in different files. Tackling them in the same PR keeps the "robustness sweep" coherent.

## Out of scope for this file
- `chmod +x` calls in `launch.sh`'s `main()` running on every launch — wasteful but harmless. Not a bug.
- `rm -f` of the log file at startup destroying historical context — a feature, not a bug (current design: one log per session). Skip.
