# Stale `/tmp` State Corrupts Teardown

**Affected file**: `bin/lib/wireguard.sh` (functions `wireguard_up`, `wireguard_down`)

Two state files in `/tmp/` record "what the system looked like before WireGuard came up" so `wireguard_down` can restore it. Both are written unconditionally inside `wireguard_up`, which means if `wireguard_up` runs while a previous run's state is already in effect, the "backup" captures the *already-modified* state — and `wireguard_down` then "restores" the wrong thing.

This is the same root-cause pattern in two places. Fix them together.

---

## Bug 1: DNS backup overwrites itself

### Symptom
After toggling WireGuard off, `/etc/resolv.conf` still contains the VPN's DNS servers instead of the original (typically the Wi-Fi DHCP-provided nameservers). DNS resolution for clearnet hosts fails or routes via the VPN provider's DNS even though the tunnel is down.

### Reproduction
1. Toggle WireGuard ON (DNS gets applied; original `/etc/resolv.conf` saved to `/tmp/wg0-dns.bak`).
2. Trigger a second `wireguard_up` call while wg0 is already up, OR trigger a `wireguard_up` that fails partway after the DNS step but before completion (any reason — bad config, network blip).
3. Toggle WireGuard OFF.
4. `cat /etc/resolv.conf` — shows VPN DNS, not original.

How a second `wireguard_up` can happen in practice:
- launch.sh's main loop checks `old_enabled != enabled` before calling `wireguard_up`, so the normal UI path is safe. But:
- A user runs `bin/on-boot` manually while the interface is already up (on-boot does check `is_wireguard_up` and returns early, so it's actually safe — but the safety lives one level up, not in `wireguard_up` itself).
- A future code path that calls `wireguard_up` without the gate would silently corrupt the backup.

### Root cause
In `wireguard_up()`:
```sh
if cp "$resolv_target" /tmp/wg0-dns.bak 2>/dev/null; then
    ...write VPN DNS to resolv.conf...
fi
```
The `cp` runs every time. There is no "did we already save a backup?" check. On the second call, `$resolv_target` already contains the VPN DNS (written by the first call), so the backup becomes the VPN DNS.

### Fix approach
Guard the backup with an existence check:
```sh
if [ ! -f /tmp/wg0-dns.bak ]; then
    cp "$resolv_target" /tmp/wg0-dns.bak 2>/dev/null || { echo "WARNING: ..."; }
fi
# only write VPN DNS if backup succeeded OR was already present
```

Alternative: have `wireguard_up` early-out with `is_wireguard_up && return 0` so it's idempotent at the top level. This is a bigger behavior change — discuss before applying.

### Verification
1. SSH into device, manually invoke `wireguard_up` twice in a row (source the lib first).
2. Check `/tmp/wg0-dns.bak` contains the *original* DNS, not the VPN DNS.
3. Call `wireguard_down`, confirm `/etc/resolv.conf` restored to original.

---

## Bug 2: Full-tunnel state file overwrites itself

### Symptom
After full-tunnel WireGuard is torn down, a stale host route to the endpoint IP remains in the routing table (`ip route show | grep <endpoint-ip>`). On a subsequent VPN connect, this stale route may point at the wrong gateway (e.g., if Wi-Fi reconnected to a different network in between).

### Reproduction
1. Use a `wg0.conf` with `AllowedIPs = 0.0.0.0/0` (full-tunnel).
2. Toggle ON. `/tmp/wg0-state` now contains the endpoint IP + gateway + gw_dev.
3. Trigger a second `wireguard_up` (same conditions as Bug 1: failed retry, manual re-invocation, etc.). A second host route gets added (or the same route — depends on whether `ip route add` errored out on duplicate). `/tmp/wg0-state` is overwritten with the new gateway info.
4. Toggle OFF. Only the most-recent host route gets `ip route del`'d. If `ip` allows duplicate routes (it usually doesn't, but adoption depends on existing route exact match), one leaks.
5. More importantly: if `wireguard_up` was retried after Wi-Fi reconnected to a different gateway, the first host route now points to a stale gateway and was never cleaned up.

### Root cause
In `wireguard_up()`, full-tunnel branch:
```sh
printf 'endpoint_ip=%s\ngw=%s\ngw_dev=%s\n' \
    "$endpoint_ip" "$gw" "$gw_dev" >/tmp/wg0-state
```
Unconditional write. `wireguard_down` reads this file, deletes one host route, removes the file. If two `wireguard_up` calls happened with different gw values, only the second's route gets cleaned.

### Fix approach
Same pattern as Bug 1: guard the write.
```sh
if [ ! -f /tmp/wg0-state ]; then
    printf 'endpoint_ip=%s\ngw=%s\ngw_dev=%s\n' \
        "$endpoint_ip" "$gw" "$gw_dev" >/tmp/wg0-state
fi
```
Or accept multiple lines and have `wireguard_down` clean all of them.

The host-route add itself (`ip route add "$endpoint_ip/32" via "$gw" dev "$gw_dev" 2>/dev/null || true`) is already idempotent-safe via `|| true`, but only because matching duplicates fail silently. Don't rely on that — fix the state file.

### Verification
1. SSH to device, simulate a full-tunnel config (`AllowedIPs = 0.0.0.0/0`).
2. Run `wireguard_up "$conf"`, note `cat /tmp/wg0-state`.
3. Manually change the default gateway (or just simulate by running `wireguard_up` again).
4. Confirm `/tmp/wg0-state` was NOT clobbered (after the fix).
5. Run `wireguard_down`, then `ip route show | grep <endpoint-ip>` — should be empty.

---

## Why the two bugs share a fix file

Both are instances of "save-before-modify, but the save happens unconditionally on every entry." Either the fix is "guard the save with a file-existence check" (preferred — small, surgical) or the higher-level fix "make `wireguard_up` itself idempotent and early-out when wg0 is already up" (bigger, requires thinking about partial-failure recovery). Pick the approach for both bugs together so the function stays internally consistent.

## Out of scope for this file
- `wireguard-go` orphan cleanup on `wireguard_up` failure paths — see `02-wireguard-go-orphan.md`.
- The `/tmp/wg0-dns.bak` and `/tmp/wg0-state` files surviving across device reboots — they're on tmpfs and disappear naturally, so no fix needed.
