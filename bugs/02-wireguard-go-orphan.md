# `wireguard-go` Orphan on `wireguard_up` Failure

**Affected file**: `bin/lib/wireguard.sh` (function `wireguard_up`)

When the kernel WireGuard module is unavailable (the normal case on the TrimUI Brick — see `docs/trimui-device-notes.md`), `wireguard_up` launches the userspace `wireguard-go` driver in the background and then continues with `wg set`, `ip addr add`, `ip link set up`, route setup, and DNS setup. If any of those *later* steps fail, the function returns 1 — but `wireguard-go` is still running and holding `/dev/net/tun`.

## Symptom
After a failed `wireguard_up`, a `wireguard-go` process remains alive:
```
ssh root@192.168.50.57 'pgrep -lf wireguard-go'
1234 wireguard-go wg0
```
A subsequent `wireguard_up` attempt may then fail in new ways:
- `ip link add dev wg0 type wireguard` either errors or silently keeps the existing (now orphaned) device.
- `wireguard-go wg0 &` starts a *second* process that races for the same name.
- The "wait up to 5 seconds for wg0 to appear" loop passes immediately because the orphan's interface is still there.

The user-visible failure is non-obvious: the menu shows "Failed to start WireGuard," but the device is in a partial state until reboot or until `wireguard_down` is run (which does call `killall wireguard-go`).

## Reproduction
1. Build with a deliberately broken `wg0.conf` — e.g., a malformed `PublicKey` so `wg set` fails.
2. Toggle WireGuard ON. `wireguard_up` calls `wireguard-go wg0 &` (succeeds), then `wg set wg0 ...` (fails with the bad key).
3. The failure branch runs:
   ```sh
   ip link del wg0 2>/dev/null || true
   [ -n "$endpoint_ip" ] && ip route del "$endpoint_ip/32" 2>/dev/null || true
   return 1
   ```
4. SSH in: `pgrep -lf wireguard-go` shows the process is still alive.
5. Try toggling ON again with a valid config — observe whichever symptom from the list above hits first.

## Root cause
In `wireguard_up()`, after the `wireguard-go` launch block, there are several failure paths that clean up the network state but NOT the process:

```sh
# wg set failed
if [ "$wg_exit" -ne 0 ]; then
    echo "ERROR: wg set failed"
    ip link del wg0 2>/dev/null || true
    [ -n "$endpoint_ip" ] && ip route del "$endpoint_ip/32" 2>/dev/null || true
    return 1
fi
```

`ip link del wg0` closes the tun fd, which *usually* causes `wireguard-go` to exit on its own — but that's an implementation detail of `wireguard-go`'s signal handling and not guaranteed. The reliable cleanup is to call `killall wireguard-go` explicitly, as `wireguard_down` already does.

## Affected failure paths
Inside `wireguard_up`, every `return 1` AFTER the `wireguard-go wg0 &` launch needs to `killall wireguard-go` first. Currently those paths are:
1. `wireguard-go` failed to create wg0 within 5 seconds.
2. `wg set wg0 ...` exited non-zero.

The earlier failure paths (before the driver launch) are fine — there's no process to clean up yet.

## Fix approach
Two options.

**Option A (minimal)** — add `killall wireguard-go 2>/dev/null || true` to each post-launch failure path. Verbose but explicit.

**Option B (cleaner)** — extract a `_wireguard_up_cleanup_partial` helper that does the full teardown (route + interface + process + state files) and call it from every failure branch after the driver launch. Mirror what `wireguard_down` does, minus the assumption that the interface fully came up.

Option B is closer to "use `wireguard_down` as the single cleanup path." That would work too, but `wireguard_down` reads `/tmp/wg0-state` and `/tmp/wg0-dns.bak` — those may not exist yet during a partial failure, which is OK because `wireguard_down` already gates on `[ -f ... ]`. So calling `wireguard_down` from the failure paths is viable.

Recommended: Option B with `wireguard_down` reuse. It collapses 3 cleanup blocks into one call and stays correct as the function grows.

## Verification
1. Deploy fix, SSH in, `pkill -f wireguard-go` to start clean.
2. Drop a deliberately broken `wg0.conf` (bad key) into `$USERDATA_PATH/$PAK_NAME/wg0.conf`.
3. Manually invoke `wireguard_up "$conf"` from a shell (after sourcing the lib).
4. Verify `pgrep -lf wireguard-go` is empty.
5. Verify `ip link show wg0` shows no device.
6. Replace with valid config, run again — should succeed cleanly with no leftover state.

## Related
- `wireguard_down` already calls `killall wireguard-go 2>/dev/null || true`. Its pattern is the reference to copy.
- If you adopt Option B, double-check that `wireguard_down`'s DNS-restore logic doesn't run if `/tmp/wg0-dns.bak` doesn't exist — current code gates on `[ -f /tmp/wg0-dns.bak ]`, so it's safe to call after a partial `wireguard_up`.
- See `01-stale-tmp-state.md` for a related concern about state files being written before failure.
