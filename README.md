# NASe — Raspberry Pi NAS

Scripts to turn a Raspberry Pi with USB drives into a self-contained NAS:
drive mounting, Samba shares, rsync backups, Tailscale remote access, SMART monitoring,
and a web dashboard — all driven by a single `config.yaml`.

## Quick start

```bash
# 1. Clone onto the Pi
git clone <repo-url> /opt/nase
cd /opt/nase

# 2. Fill in secrets
cp .env.example .env
$EDITOR .env

# 3. Configure drives, shares, sync jobs
$EDITOR config.yaml

# 4. Install (once, on a fresh Pi)
sudo ./install.sh
```

After the first install, re-apply config changes with:

```bash
sudo ./apply.sh
```

## Requirements

- Raspberry Pi running Raspberry Pi OS Bookworm or later, or Debian 12+ (64- or 32-bit)
- Python 3.9 or newer (installed by `install.sh` if missing)
- USB drives physically attached; their UUIDs noted for `config.yaml`
- Internet access during install (packages + Tailscale)

## Repository layout

```
/opt/nase/
├── config.yaml              # Single source of truth — edit this
├── .env.example             # Secret variables template (copy to .env)
├── install.sh               # First-time installer (run once as root)
├── apply.sh                 # Idempotent config applier (re-run after edits)
├── nase                     # Management CLI
│
├── lib/
│   ├── log.sh               # Logging helpers
│   ├── config.sh            # yq wrappers for reading config.yaml
│   ├── checks.sh            # Pre-flight sanity checks
│   └── guards.sh            # SD-card / unmounted-drive safety guards
│
├── modules/
│   ├── drives/
│   │   ├── setup.sh         # Generates systemd .mount units + spindown rules
│   │   └── monitor.sh       # SMART health checker (run by nase-monitor.timer)
│   ├── samba/
│   │   ├── setup.sh         # Renders smb.conf, manages Samba users
│   │   └── smb.conf.tmpl    # Global Samba config template
│   ├── sync/
│   │   ├── setup.sh         # Generates systemd timer+service per sync job
│   │   ├── sync.sh          # rsync worker (called by systemd timers)
│   │   └── notify.sh        # Email / webhook notifications
│   ├── config-archive/
│   │   ├── setup.sh         # Creates the config-archive timer
│   │   └── archive.sh       # Snapshots config.yaml on change
│   ├── status-report/
│   │   ├── setup.sh         # Creates the status-report timer
│   │   └── report.sh        # Generates and sends periodic status digest
│   ├── watch/
│   │   ├── setup.sh         # Creates nase-watch.service
│   │   └── watch.sh         # inotifywait loop; sends notifications on file events
│   ├── filebrowser/
│   │   └── setup.sh         # Installs filebrowser; creates bind-mount virtual root
│   ├── tailscale/
│   │   └── setup.sh         # Installs and connects Tailscale
│   └── web/
│       ├── setup.sh         # Creates Python venv + nase-web.service
│       └── app/             # FastAPI dashboard (status, logs, config editor)
│
├── systemd/
│   ├── nase-monitor.service  # Runs monitor.sh (SMART checks)
│   └── nase-monitor.timer    # Daily at 06:00, also 15 min after boot
│
├── tests/
│   ├── run-tests.sh          # Test runner
│   ├── validate-config.sh    # Validates config.yaml before applying
│   ├── test-config.sh        # Unit tests for lib/config.sh
│   └── test-sync-guards.sh   # Unit tests for lib/guards.sh
│
└── config/
    └── logrotate-nase.conf   # Installed to /etc/logrotate.d/nase
```

## Configuration reference

All settings live in `config.yaml`. Secrets (passwords, API keys, SMTP credentials) go in `.env`.

### Drives

| Field | Description |
|---|---|
| `name` | Identifier used in unit names and logs |
| `uuid` | Filesystem UUID — find with `blkid` |
| `label` | Partition label (informational) |
| `mountpoint` | Where the drive is mounted (e.g. `/mnt/primary`) |
| `role` | `main` or `backup` |
| `filesystem` | `ext4`, `btrfs`, etc. |
| `active` | `true` / `false` — set to `false` to skip a drive entirely |
| `read_only` | `true` to mount read-only at rest; sync jobs remount rw temporarily |
| `spindown_min` | Minutes idle before spinning down; `0` = never |
| `smart_check` | `true` / `false` — include in periodic SMART health check |
| `owner` | Unix user that should own the mountpoint (main drives) |

### Samba

Passwords are read from `.env` at apply time:

```
SAMBA_PASSWORD_<USERNAME_UPPERCASED>=<password>
```

### Sync jobs

Schedules use **systemd OnCalendar** format (not cron):

| Example | Meaning |
|---|---|
| `*-*-* 03:00:00` | Every day at 03:00 |
| `*-*-* *:00/30:00` | Every 30 minutes |
| `Mon *-*-* 02:00:00` | Every Monday at 02:00 |
| `Sat *-*-* 03:00:00` | Every Saturday at 03:00 |

Validate a schedule: `systemd-analyze calendar "<expression>"`

`Persistent=true` is set on all timers: if the Pi was off at the scheduled time, the job runs at next boot.

When `trash.enabled: true`, files deleted from the destination are moved to a
timestamped directory under `trash.path` rather than being permanently removed.
`trash.retention_days` controls how long they are kept.

### Notifications

```yaml
notifications:
  method: email          # email | webhook | none
  email: you@example.com # recipient (method=email)
```

SMTP credentials and the webhook URL live in `.env`. Test with `sudo nase notify-test`.

### Services

```yaml
services:
  web:
    enabled: true
    port: 8088
  filebrowser:
    enabled: true
    port: 8080
    root: /srv/filebrowser   # virtual root; populated with bind mounts
    username: nase           # password set via FILEBROWSER_PASSWORD in .env
    base_url: ""             # set if behind a reverse proxy, e.g. /files
```

### Config archive

Snapshots `config.yaml` to the primary drive on a schedule and prunes old copies:

```yaml
config_archive:
  dest: /mnt/primary/NASe
  schedule: '*-*-* *:00/05:00'   # every 5 minutes
  retention_days: 90
  on_failure: notify
```

### File watch

Sends a notification when a file or directory sees a configured event:

```yaml
file_watch:
  - path: /mnt/primary/Documents/
    label: "Documents"
    events: [modify, delete]
```

Events: `modify`, `delete`, `create`. A 60-second cooldown prevents notification floods.

### Status report

Sends a periodic digest of system health and all file operations since the last report:

```yaml
status_report:
  enabled: true
  schedule: 'Sat *-*-* 03:00:00'   # every Saturday at 3 AM
```

The report includes drive mount status, sync timer health, any errors logged in the period,
and a per-job list of synced and trashed files. Send immediately with `sudo nase report`.

### Tailscale

```yaml
tailscale:
  enabled: true
  advertise_exit_node: false
  advertise_routes: ""   # e.g. "192.168.1.0/24" for subnet routing
```

Set `TAILSCALE_AUTHKEY` in `.env`. Generate a key at <https://login.tailscale.com/admin/settings/keys>.

## Day-to-day operations

```bash
nase status                       # Overall status: services, timers, drives
nase drives                       # Drive mount status and disk usage
nase logs                         # Show recent central log entries
nase logs -f                      # Follow the central log
nase logs -f music-backup-daily   # Follow a specific sync job's rsync log

sudo nase sync music-backup-daily # Run a specific sync job now
sudo nase pause                   # Stop all sync timers
sudo nase resume                  # Restart all sync timers
sudo nase remount rw              # Remount all backup drives read-write
sudo nase remount ro              # Remount all backup drives read-only
sudo nase remount rw backup_daily # Remount one specific backup drive

sudo nase notify-test             # Send a test notification
sudo nase report                  # Send a status report immediately

sudo nase web-restart             # Restart the web dashboard
sudo nase apply                   # Re-apply all config (same as sudo ./apply.sh)
sudo nase apply samba             # Re-apply a single section
```

The web dashboard is available at `http://<hostname>:8088` — it shows live status,
logs, and a config editor with per-section Save + Apply buttons.

## Finding drive UUIDs

```bash
blkid
# or
ls -la /dev/disk/by-uuid/
```

## Secrets (`.env`)

The `.env` file is sourced by `install.sh` and `apply.sh` but is **never committed** (listed in `.gitignore`).
See `.env.example` for all supported variables.

## Recovery / reinstall

If the SD card dies and needs to be replaced:

1. Flash a fresh Raspberry Pi OS image and boot.
2. Clone the repo: `git clone <repo-url> /opt/nase && cd /opt/nase`
3. Restore `.env` from a backup (or re-enter secrets).
4. Plug in the data drives — they mount by UUID so no reconfiguration is needed.
5. Run `sudo ./install.sh`.

All data is on the USB drives. The SD card only holds the OS and the repo clone.
