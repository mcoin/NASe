# NASe — Project Guide for Claude Code

Self-hosted NAS on a Raspberry Pi (aarch64): drive mounting, Samba, rsync
backups, health monitoring, web dashboard. Everything is driven by one
`config.yaml`; `sudo ./apply.sh` makes the live system match it, idempotently.

**Companion docs, read on demand:** `FIELD_NOTES.md` (hard-won findings and the
evidence behind the traps below), `INTEGRITY_DESIGN.md`, `DRIVE_REPLACEMENT.md`,
`REINSTALL.md`.

## Hardware

| role | name | UUID | size / model | USB bridge |
|------|------|------|--------------|------------|
| `main` | primary → `/mnt/primary` | `524be343-…b0f1fab13534` | 5.5 TB WDC WD60EZAX | JMS578 `152d:0578` (`uas`) |
| `backup` | backup_daily → `/mnt/backup_daily` | `532b7925-…56050eb510d2` | 1.8 TB ST2000DM001 | AS2105 `174c:5106` (`usb-storage`) |

Both ext4; backup_daily is read-only at rest. Two Intenso USB drives
(`1f75:0917`, `1f75:0903`, hfsplus) are attached but absent from `config.yaml` —
NASe does not touch them. `config.yaml` is authoritative; `uuid` is the only
field tying an entry to a physical disk.

## Traps — each cost a day to find

- **Device letters are not stable across reboots.** Resolve by UUID or USB
  `vid:pid`. Never compare a before/after measurement by letter.
- **`findmnt --target` resolves *up* to the enclosing mount**, so it can never
  answer "is this mounted?" — for an absent drive it finds the SD card and exits
  0. Use `is_mounted_at` / `is_mounted_ro_at` / `is_safe_mount_path` from
  `lib/guards.sh`. Anything that walks or writes under a mountpoint must go
  through that guard. Found four times so far.
- **`hdparm -C` always answers `unknown` for primary** — its bridge lacks ATA
  CHECK POWER MODE. Never read that as "awake"; ask
  `modules/drives/spin_status.sh <name>`.
- **Don't wake the drives.** `find`/`du`/globs under `/mnt` spin them up. Check
  `spin_status.sh` first. `sync` flushes every mounted filesystem and will wake
  them too.
- **hdparm APM/standby do not survive a power cycle** — re-applied at boot by
  `nase-spindown.service`, not udev. A drive spinning with no I/O usually means
  `hdparm -B` is back at 254.
- **`teardown.sh` must never call `systemctl`** — it runs inside the shutdown
  transaction and would risk deadlocking it.
- **`orphan cleanup on readonly fs` is normal here**, not evidence of a dirty
  shutdown. Use `dumpe2fs -h` to judge that.
- **No RTC on this Pi** — early-boot journal timestamps lag reality. Use
  `uptime -s` to date a boot.

## Layout

```
apply.sh  config.yaml  install.sh  nase (CLI)  sync.sh (wrapper)

lib/      config.sh  (yq-backed accessors; whole file parsed once, cached)
          log.sh  checks.sh  calendar.sh  watch.sh
          guards.sh (mount safety)  files.sh (write_if_changed)

modules/  drives/          mount units, spindown, teardown, SMART, spin sampler
          sync/            per-job rsync + one group timer per schedule
          integrity/       per-drive checksum manifest (see INTEGRITY_DESIGN.md)
          samba/  filebrowser/  tailscale/  web/
          primary-watch/   inotify recorder → primary-events.log
          watch/           optional file_watch notifications (unconfigured)
          config-archive/  config + backlog snapshots to the drive
          status-report/   weekly report; archives to /var/lib/nase/reports/

systemd/  nase-monitor, nase-spindown, nase-shutdown units
tests/    run-tests.sh runs every suite; --ui is not wired up yet
config/   logrotate, journald (persistent), DefaultTimeoutStopSec drop-ins
```

`modules/web/app/main.py` is the FastAPI app (status, changes, integrity,
monitoring, reports, backlog, config editor, `/apply` SSE stream).

## apply.sh order

Preflight → `.env` → validate-config → check UUIDs (warn only) → hostname →
modules (drives, integrity, config-archive, samba, sync, tailscale, web,
filebrowser, watch, primary-watch, status-report) → install `systemd/` units →
migrate `nas-*` → daemon-reload + enable → drop-ins → logrotate.

## CLI

`sudo nase status | drives | pause | resume | sync <job> | remount <rw|ro> [drive]`
`nase logs [-f] [<job>]`, `sudo nase web-restart | notify-test | report`
`sudo nase integrity status [name] | ack <name> <path> | bootstrap <name> [limit]`
`sudo nase apply [section]`

## Runtime paths

| Path | Purpose |
|------|---------|
| `/mnt/primary`, `/mnt/backup_daily` | Data drives |
| `<mountpoint>/.nase/` | Checksum manifest (root:root 0700) |
| `/srv/filebrowser` | Bind-mount virtual root |
| `/var/lib/nase/` | Stamps, `backlog.json`, `spin-history.log`, `primary-events.log`, `integrity-status/`, `reports/` |
| `/var/log/nase/nase.log` | Central log (`/var/log/nase-sync-<job>.log` per job) |
| `/etc/systemd/system/{mnt-*,srv-filebrowser-*}.mount`, `nase-*` | Generated units |

`.env` holds `SAMBA_PASSWORD_NASE`, `FILEBROWSER_PASSWORD`, `WEB_PASSWORD`,
`TAILSCALE_AUTHKEY`, and either SMTP settings or `NOTIFY_WEBHOOK_URL`.

## Design decisions

- **config.yaml is the only file to edit**, then `apply.sh` (or the web UI's
  Apply button).
- **Backup drives are read-only at rest.** Sync jobs remount rw for the run and
  back via an EXIT trap.
- **Trash instead of delete.** rsync `--backup --backup-dir` into `.trash/`,
  retention per job.
- **Change detection reads the event log, not the platter** (#4), so a nightly
  sync with no changes does not wake a drive. A `force_sync_calendar` guarantees
  periodic full runs.
- **Integrity builds progressively**, piggybacked on the sync window; it never
  triggers its own spin-up, and only runs after a real rsync.
- **The web service does not restart itself** unless its code or unit changed
  (sha256 stamp), so Apply-from-browser does not kill the page serving it.
- **Anything NASe writes about itself is not user activity.** Watcher heartbeats,
  gap markers and config-archive snapshots are filtered out of the changes page
  and the status report (#29, #39).
- **Backlog text is stored exactly as typed** and unwrapped at render time. Write
  new ticket text without hard wraps.
