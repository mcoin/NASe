# NASe — Project Guide for Claude Code

## Goal

NASe is a self-hosted NAS management system running on a Raspberry Pi (ARM/Linux).
It automates drive mounting, Samba sharing, rsync backups, drive health monitoring,
and exposes a web dashboard for status and configuration.
Everything is driven by a single `config.yaml`; running `sudo ./apply.sh` makes the
live system match the config idempotently.

## Hardware

- Raspberry Pi running Debian/Ubuntu (aarch64)
- SD card → OS root (`/`)

Managed drives, identified the only two ways that stay true — role and UUID:

| role | name | UUID | size / model | USB bridge | driver |
|------|------|------|--------------|------------|--------|
| `main` | primary → `/mnt/primary` | `524be343-…b0f1fab13534` | 5.5 TB WDC WD60EZAX | JMicron JMS578 `152d:0578` | `uas` |
| `backup` | backup_daily → `/mnt/backup_daily` | `532b7925-…56050eb510d2` | 1.8 TB ST2000DM001 | ASMedia AS2105 `174c:5106` | `usb-storage` |

Both ext4; backup_daily is read-only at rest. Two Intenso Ultra Line USB drives
(`1f75:0917`, `1f75:0903`, 117 GB, hfsplus) are also attached but appear nowhere
in `config.yaml` — NASe does not manage or touch them.

**Device letters are not stable across reboots.** On 2026-09-05 primary moved
from `/dev/sda` to `/dev/sdb` simply because the AS2105 enumerated first that
boot. Never hard-code a letter and never compare a before/after measurement by
letter: doing exactly that during backlog #27 made a `hdparm -C /dev/sda` reading
of *backup_daily* look like a successful fix to *primary*. Resolve drives by
UUID (as `config.yaml` and every module do), or by USB `vid:pid`.

`config.yaml` is authoritative for drive names and mountpoints; the above is
what it currently declares. Note that `/mnt/backup1` and `/mnt/backup2` are
*stale directories on the SD card* left over from an earlier layout, not
mountpoints. `findmnt --target /mnt/backup1` therefore resolves up to the root
device — which is exactly the trap `lib/guards.sh` (`is_safe_mount_path`)
exists to catch. Any new code that walks or writes under a drive's mountpoint
must go through that guard.

**hdparm APM/standby settings do not survive a power cycle.** A reboot resets
APM to the drive's factory default (usually 254), which disables spin-down in
firmware and silently overrides any `-S` timer, so an idle drive spins
forever. Re-applying them is `nase-spindown.service`'s job, not udev's: udev
fires 1–2 s after the device node appears, while a USB disk is still spinning
up and its bridge rejects `SET FEATURES`, so the old inline `RUN+="hdparm …"`
failed on every boot (#32). `-B` and `-S` are applied as separate invocations
— primary's bridge has no APM at all, and a combined call fails as a whole,
taking the standby timer down with it. If a drive is spinning with no I/O,
check `hdparm -B <disk>` before looking for a process: 254 means nothing ever
applied the settings.

`hdparm -C` always answers `unknown` for **primary**: its JMS578 bridge does not
implement ATA CHECK POWER MODE, even though SMART passes through it fine. This
is the bridge itself, not the `uas` driver — backlog #27 forced the device onto
`usb-storage` with `usb-storage.quirks=152d:0578:u` and the answer did not
change, so the quirk was rolled back. backup_daily's AS2105 does report power
state, which is why one drive says `confirmed` and the other `estimated`. Never
treat `unknown` as "awake" — ask `modules/drives/spin_status.sh <name>`, which
falls back to inferring state from `/sys/block/<disk>/stat` and reports
`estimated`. Any replacement enclosure must be checked for a working
`hdparm -C` before its return window closes.

## Repository layout

```
apply.sh                   Idempotent config applier — run as root after any config change
config.yaml                Single source of truth for all settings
install.sh                 First-time bootstrap (clone → venv → apply)
nase                       CLI utility (see commands below)
sync.sh                    Thin wrapper: exec modules/sync/sync.sh

lib/
  config.sh                Shell helpers: config_get / config_idx / config_len / config_bool
  log.sh                   log_info / log_ok / log_warn / log_error / log_section / die
  checks.sh                preflight_checks, check_root, check_drive_uuids
  guards.sh                is_safe_mount_path / get_mount_device (protect against SD-card rsync)

modules/
  drives/
    setup.sh               Writes systemd .mount units; cleans up stale units by UUID;
                           unmounts stale device paths (deepest-first, lazy fallback)
    spindown.sh            Writes udev rules that trigger nase-spindown.service
    spindown_common.sh     Shared spindown helpers: minutes -> hdparm -S, UUID -> disk,
                           retrying applier (-B and -S applied separately)
    spindown_apply.sh      Applies every drive's APM/standby settings; run by
                           nase-spindown.service at boot and on hot-plug
    teardown.sh            Ordered unmount of bind mounts + drives at shutdown,
                           run as ExecStop of nase-shutdown.service
    prune_mount_units.sh   Removes mount units for drives dropped from config.yaml
    monitor.sh             SMART health checks, triggered by nase-monitor.timer
  samba/
    setup.sh               Generates /etc/samba/smb.conf from config; manages Samba users
    smb.conf.tmpl          Global Samba config template (__WORKGROUP__ substituted)
  sync/
    setup.sh               Writes systemd .service + .timer pairs per sync job;
                           also creates .trash directories (remounting rw if needed)
                           and prunes stamps/cursors of jobs dropped from config
    sync.sh                Runs one rsync job: change detection, rw remount, trash, stamps
    notify.sh              Sends email or webhook notification on failure
  filebrowser/
    setup.sh               Installs filebrowser binary; creates systemd bind-mount units
                           to populate /srv/filebrowser with a Finder-like virtual root;
                           cleans up stale bind-mount units
  integrity/
    schema.sql             Per-drive checksum manifest schema (files/events/meta)
    common.sh               Shared helpers: db path, UUID cross-check, budget calc
    setup.sh                Creates <mountpoint>/.nase/ (root:root 0700) + schema
    discover_and_sample.sh  Nightly budgeted discovery + oldest-checked resample
    bootstrap.sh             Full-speed discovery for 'nase integrity bootstrap' — chained
                           200000-file passes with no limit, one capped pass with a limit
    reconcile-backup.sh      Called from sync.sh after a successful rsync run
    reconcile-primary.sh    Consumes primary-events.log since last cursor
                           See INTEGRITY_DESIGN.md for the full design.
  tailscale/
    setup.sh               Installs and configures Tailscale
  web/
    setup.sh               Creates Python venv, installs deps, writes nase-web.service;
                           restarts only when app code or unit file changed (hash stamp)
    app/main.py            FastAPI app: status, logs, config editor, apply SSE stream
    app/templates/         Jinja2 templates (base.html, index.html, config.html, partials/)
    app/static/style.css   All CSS
    requirements.txt       fastapi, uvicorn, jinja2, pyyaml, ruamel.yaml, etc.

systemd/
  nase-monitor.service     Runs modules/drives/monitor.sh
  nase-monitor.timer       Periodic SMART / health check trigger
  nase-spindown.service    Re-applies hdparm APM/standby at boot (settings do not
                           survive a power cycle)
  nase-shutdown.service    ExecStop runs modules/drives/teardown.sh before umount.target

tests/
  validate-config.sh       Checks config.yaml structure (trailing slashes, required fields)
  test-sync-guards.sh      Unit tests for the SD-card guard logic
  test-config.sh           Unit tests for config.sh helpers
  run-tests.sh             Test runner

config/
  logrotate-nase.conf      Logrotate config installed to /etc/logrotate.d/nase
  journald-nase.conf       Drop-in making the journal persistent (Raspberry Pi OS
                           ships Storage=volatile) — /etc/systemd/journald.conf.d/50-nase.conf
  system-nase.conf         Drop-in setting DefaultTimeoutStopSec=30s —
                           /etc/systemd/system.conf.d/50-nase.conf
```

## apply.sh order of operations

1. Preflight checks (root, dependencies)
2. Source `.env` (secrets)
3. `tests/validate-config.sh`
4. `check_drive_uuids` (warn on missing drives, non-fatal)
5. Set hostname
6. `run_module drives` — mount units, spindown
7. `run_module samba`
8. `run_module sync` — timer units + ensure .trash dirs exist
9. `run_module tailscale` (if enabled)
10. `run_module web` (if enabled) — only restarts service when code changed
11. `run_module filebrowser` (if enabled)
12. Install/update systemd units from `systemd/`
13. Migrate old `nas-*` unit names to `nase-*`
14. `systemctl daemon-reload && enable nase-monitor`, enable `nase-spindown`, `nase-shutdown`
15. Install systemd drop-ins (journald persistence, stop timeout)
16. Install logrotate config

## nase CLI commands

```
sudo nase status            Full status: services, sync timers, drives
sudo nase drives            Drive mount status and disk usage
sudo nase pause             Stop all sync timers
sudo nase resume            Restart all sync timers
sudo nase sync <job>        Run a sync job interactively by name
sudo nase remount <rw|ro> [drive-name]
                            Remount backup drive(s); omit name for all backup drives
nase logs [-f] [<job>]      Show/follow logs (no job = central, job name = rsync log)
sudo nase web-restart       Restart nase-web.service
sudo nase notify-test       Send a test notification
sudo nase integrity status [name]
                            Checksum manifest status: flagged files, discovery progress
sudo nase integrity ack <name> <path>
                            Clear a flagged file after manual review
sudo nase integrity bootstrap <name> [limit]
                            Run checksum discovery at full speed. With no [limit], runs
                            as chained 200000-file passes until discovery completes.
                            With [limit], stop after that many new files — safe to
                            re-run (e.g. daily) to spread a big backlog over several days.
```

## Web dashboard (port 8088)

- `/` — Dashboard: live service/drive/timer status (HTMX polling), log viewer
- `/config` — YAML editor with per-section tabs; Save writes to config.yaml
  (uses ruamel.yaml to preserve comments and formatting)
- `/apply` — SSE endpoint: streams apply.sh stdout/stderr line-by-line;
  an asyncio lock prevents concurrent runs

## Runtime paths

| Path | Purpose |
|------|---------|
| `/mnt/primary` | Main data drive |
| `/mnt/backup_daily` | Backup drive (read-only at rest) |
| `<mountpoint>/.nase/` | Per-drive checksum integrity manifest (root:root 0700 — see INTEGRITY_DESIGN.md) |
| `/srv/filebrowser` | Virtual root: bind-mounts of primary shares + Backup/Trash |
| `/var/lib/nase/` | Stamp files: `sync-<job>.stamp`, `web-app.hash` |
| `/var/log/nase/nase.log` | Central log |
| `/var/log/nase-sync-<job>.log` | Per-job rsync log |
| `/etc/filebrowser/` | Filebrowser DB and settings |
| `/etc/samba/smb.conf` | Generated Samba config |
| `/etc/systemd/system/mnt-*.mount` | Drive mount units (NASe-managed) |
| `/etc/systemd/system/srv-filebrowser-*.mount` | Filebrowser bind-mount units |
| `/etc/systemd/system/nase-sync-*.{service,timer}` | Per-job sync units |
| `/etc/udev/rules.d/99-nase-spindown.rules` | Starts `nase-spindown.service` on drive attach |
| `/etc/systemd/journald.conf.d/50-nase.conf` | Persistent journal, 200M cap |
| `/etc/systemd/system.conf.d/50-nase.conf` | `DefaultTimeoutStopSec=30s` |

## Secrets (`.env`)

```
SAMBA_PASSWORD_NASE=...
FILEBROWSER_PASSWORD=...
TAILSCALE_AUTHKEY=...
# Notification (choose one):
SMTP_HOST / SMTP_PORT / SMTP_USER / SMTP_PASSWORD / NOTIFY_FROM / NOTIFY_TO
NOTIFY_WEBHOOK_URL
```

## Key design decisions

- **config.yaml is the only file to edit.** Run `sudo ./apply.sh` after any change.
  The web UI's config editor + Apply button does this from the browser.
- **Backup drives are read-only at rest.** Sync jobs remount rw for the duration
  of the rsync, then remount ro via an EXIT trap. `nase remount` does this manually.
- **Trash instead of delete.** rsync uses `--backup --backup-dir` to move deleted
  files to a timestamped directory under `.trash/` rather than permanently deleting.
  Retention is enforced per-job (default 30 days).
- **Change detection before spinning up backup.** Each sync job checks whether
  any source file is newer than the stamp file before waking the backup drive.
  A `force_sync_days` threshold overrides this to guarantee periodic full syncs.
- **Filebrowser virtual root.** Systemd bind-mount units populate `/srv/filebrowser`
  so the web file manager mirrors the Samba/Finder layout (no raw `/mnt/primary`
  or `/mnt/backup` visible).
- **Web service self-restart problem.** `modules/web/setup.sh` only restarts
  `nase-web.service` when the app code or unit file actually changed (tracked via
  sha256 stamp), so `apply.sh` triggered from the web UI doesn't kill itself.
- **Checksum integrity manifest builds progressively, not via a blocking bootstrap.**
  `modules/integrity` maintains a per-file checksum database on each drive
  (disabled by default — `integrity.enabled` in config.yaml). Discovery of
  pre-existing files and nightly resampling of known files share one budgeted
  pass, piggybacked onto the existing nightly sync window (never triggers its
  own drive spin-up). See `INTEGRITY_DESIGN.md` for the full design and the
  guards protecting `.nase/` from Samba/filebrowser/`fix-ownership.sh`.
- **Shutdown tears the drives down in a defined order.** A reboot on
  2026-09-05 never completed and the power had to be pulled, leaving the SD
  card and backup_daily with orphan inodes (#31). Ten filebrowser bind mounts
  sit on two USB drive mounts, and nothing ordered their teardown: a bind
  mount that will not release keeps the drive under it busy, and no systemd
  timeout covers a kernel-side unmount that never returns.
  `modules/drives/teardown.sh` (ExecStop of `nase-shutdown.service`) flushes
  any rw drive, unmounts deepest-first with a lazy fallback, and syncs — every
  step wrapped in `timeout`, every failure tolerated. It must never call
  `systemctl`: it runs inside the shutdown transaction, where queueing new
  jobs can deadlock the shutdown it exists to protect. Ordering (`After=` in
  the unit) is what stops the services.
- **The journal is made persistent on purpose.** Raspberry Pi OS ships
  `Storage=volatile` to spare the SD card, which means a hung shutdown leaves
  no evidence at all — #31 had to be reconstructed from side effects. NASe
  installs a capped `Storage=persistent` drop-in instead. Related trap: this
  Pi has no RTC, so journal and wtmp timestamps in the first seconds of a boot
  can be minutes behind reality (systemd restores the last saved clock, then
  timesyncd corrects it). Use `uptime -s` to date a boot, not the journal's
  first entry.
- **Backlog text is written unwrapped; the reader folds legacy hard wraps.**
  Ticket descriptions, decisions and notes are stored exactly as typed and are
  never rewritten. Older entries were hard-wrapped at ~80 columns and render in
  a ~64-character column, so `unwrap_prose()` (main.py, a Jinja filter) joins
  runs of unindented prose at render time — headers, list items, indented
  blocks and tables keep their line structure. Write new ticket text without
  hard wraps and let the browser wrap it.
