# NASe — Raspberry Pi NAS Setup

Scripts to turn a Raspberry Pi with USB drives into a self-contained NAS:
USB drive management, Samba network shares, Tailscale remote access, and automated drive synchronisation — all driven by a single `config.yaml`.

## Quick start

```bash
# 1. Clone onto the Pi (e.g. /opt/nas is the expected install location)
git clone <repo-url> /opt/nas
cd /opt/nas

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

- Raspberry Pi running Raspberry Pi OS (Bookworm or Bullseye, 64- or 32-bit)
- USB drives physically attached; their UUIDs noted for `config.yaml`
- Internet access during install (packages + Tailscale)

## Repository layout

```
nas-setup/
├── config.yaml              # Single source of truth — edit this
├── .env.example             # Secret variables template (copy to .env)
├── install.sh               # First-time installer
├── apply.sh                 # Idempotent config applier (re-run after edits)
│
├── lib/
│   ├── log.sh               # Logging helpers (source'd by all scripts)
│   ├── config.sh            # yq wrappers for reading config.yaml
│   └── checks.sh            # Pre-flight sanity checks
│
├── modules/
│   ├── drives/
│   │   ├── setup.sh         # Generates systemd .mount units
│   │   ├── spindown.sh      # Writes udev rules for hdparm APM timers
│   │   └── monitor.sh       # SMART health checker (run by nas-monitor.timer)
│   ├── samba/
│   │   ├── setup.sh         # Renders smb.conf, manages Samba users
│   │   └── smb.conf.tmpl    # Global Samba config template
│   ├── tailscale/
│   │   └── setup.sh         # Installs and connects Tailscale
│   └── sync/
│       ├── setup.sh         # Generates systemd timer+service per sync job
│       ├── sync.sh          # rsync worker (called by systemd timers)
│       └── notify.sh        # Email / webhook notifications
│
├── systemd/
│   ├── nas-monitor.service  # Runs monitor.sh (SMART checks)
│   └── nas-monitor.timer    # Daily at 06:00, also 15 min after boot
│
└── tests/
    └── validate-config.sh   # Validates config.yaml before applying
```

## Configuration reference

All settings live in `config.yaml`. Secrets (passwords, API keys) go in `.env`.

### Drives

| Field | Description |
|---|---|
| `name` | Friendly label used in logs and unit names |
| `uuid` | Filesystem UUID (find with `blkid`) |
| `mountpoint` | Where the drive is mounted (e.g. `/mnt/primary`) |
| `role` | `main` or `backup` |
| `filesystem` | `ext4`, `btrfs`, etc. |
| `spindown_min` | Minutes idle before spinning down; `0` = never |
| `smart_check` | `true` / `false` — include in daily SMART check |

### Samba users

Passwords are read from `.env` at apply time. Variable naming:

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

Validate a schedule: `systemd-analyze calendar "<expression>"`

`Persistent=true` is set on all timers: if the Pi was off at the scheduled time, the job runs at next boot.

### Tailscale

Set `tailscale.enabled: true` and provide `TAILSCALE_AUTHKEY` in `.env`.  
Optionally set `advertise_routes` (e.g. `192.168.1.0/24`) for subnet routing.

## Day-to-day operations

```bash
# Re-apply after editing config.yaml
sudo ./apply.sh

# Run a sync job manually
sudo /opt/nas/modules/sync/sync.sh media-backup

# Check sync timer status
systemctl list-timers 'nas-sync-*'

# View sync job logs
journalctl -u nas-sync-media-backup.service

# View SMART check logs
journalctl -u nas-monitor.service

# Check Samba
systemctl status smbd nmbd

# Check Tailscale
tailscale status
```

## Finding drive UUIDs

```bash
blkid
# or
ls -la /dev/disk/by-uuid/
```

## Secrets

The `.env` file is sourced by `install.sh` and `apply.sh` but is **never committed** (listed in `.gitignore`).  
See `.env.example` for all supported variables.
