# Bug Task List

Known correctness issues in `bin/lib/wireguard.sh`, `bin/lib/boot-hook.sh`, and `bin/lib/common.sh`. Each file in this directory is one self-contained group of related bugs that share a fix pattern.

## Order to tackle

Numbered for impact (highest first). Within a file, fixes are independent and can ship in any order or as one diff.

1. **[01-stale-tmp-state.md](01-stale-tmp-state.md)** — `/tmp/wg0-dns.bak` and `/tmp/wg0-state` get overwritten when `wireguard_up` runs while state is already partially applied. Symptom: VPN DNS gets "restored" as the original on teardown; full-tunnel host route leaks.
2. **[02-wireguard-go-orphan.md](02-wireguard-go-orphan.md)** — `wireguard-go` is launched in the background but failure paths in `wireguard_up` only delete the interface; the process can survive. Symptom: orphan `wireguard-go` on subsequent runs.
3. **[03-setup-idempotency.md](03-setup-idempotency.md)** — Two unrelated places where re-running a setup step misbehaves: `enable_start_on_boot` appends duplicate hook lines, and `init_logging` silently drops all output if `$LOGS_PATH` doesn't exist.

## Conventions

- The device runs BusyBox ash (POSIX sh). No bash-isms. Test locally with `dash` for closer behavior than `bash`.
- Live device access: `ssh root@192.168.50.57` password `tina` (port 22, dropbear). Useful for verifying state in `/tmp/` and `/etc/resolv.conf` between fix iterations.
- Logs: `/mnt/SDCARD/.userdata/tg5040/logs/WireGuard.txt` (session) and `WireGuard.on-boot.txt` (boot).
- Deploy after change: `make release && make deploy`. Re-launching the pak from NextUI picks up script changes without a reboot.
- After fixing a bug, verify by re-running the trigger from the "Reproduction" section in each file.
