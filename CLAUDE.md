# NASe — Project Guide for Claude Code

## Goal

NASe is a self-hosted NAS management system running on a Raspberry Pi (ARM/Linux).
It automates drive mounting, Samba sharing, rsync backups, drive health monitoring,
and exposes a web dashboard for status and configuration.
Everything is driven by a single `config.yaml`; running `sudo ./apply.sh` makes the
live system match the config idempotently.

## Hardware

- Raspberry Pi running Debian/Ubuntu (aarch64)
- `/dev/sda` → primary drive (1.8 TB, ext4, `/mnt/primary`)
- `/dev/sdb` → backup1 (224 GB, ext4, `/mnt/backup1`, normally read-only)
- `/dev/sdc` → backup2 (239 GB, ext4, `/mnt/backup2`, normally read-only)
- SD card → OS root (`/`)

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
    spindown.sh            Writes udev rules for hdparm spindown
    monitor.sh             SMART health checks, triggered by nase-monitor.timer
  samba/
    setup.sh               Generates /etc/samba/smb.conf from config; manages Samba users
    smb.conf.tmpl          Global Samba config template (__WORKGROUP__ substituted)
  sync/
    setup.sh               Writes systemd .service + .timer pairs per sync job;
                           also creates .trash directories (remounting rw if needed)
    sync.sh                Runs one rsync job: change detection, rw remount, trash, stamps
    notify.sh              Sends email or webhook notification on failure
  filebrowser/
    setup.sh               Installs filebrowser binary; creates systemd bind-mount units
                           to populate /srv/filebrowser with a Finder-like virtual root;
                           cleans up stale bind-mount units
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

tests/
  validate-config.sh       Checks config.yaml structure (trailing slashes, required fields)
  test-sync-guards.sh      Unit tests for the SD-card guard logic
  test-config.sh           Unit tests for config.sh helpers
  run-tests.sh             Test runner

config/
  logrotate-nase.conf      Logrotate config installed to /etc/logrotate.d/nase
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
14. `systemctl daemon-reload && enable nase-monitor`
15. Install logrotate config

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
| `/mnt/backup1`, `/mnt/backup2` | Backup drives (read-only at rest) |
| `/srv/filebrowser` | Virtual root: bind-mounts of primary shares + Backup/Trash |
| `/var/lib/nase/` | Stamp files: `sync-<job>.stamp`, `web-app.hash` |
| `/var/log/nase/nase.log` | Central log |
| `/var/log/nase-sync-<job>.log` | Per-job rsync log |
| `/etc/filebrowser/` | Filebrowser DB and settings |
| `/etc/samba/smb.conf` | Generated Samba config |
| `/etc/systemd/system/mnt-*.mount` | Drive mount units (NASe-managed) |
| `/etc/systemd/system/srv-filebrowser-*.mount` | Filebrowser bind-mount units |
| `/etc/systemd/system/nase-sync-*.{service,timer}` | Per-job sync units |

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
