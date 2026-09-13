# NASe — Replacing or promoting a drive

What to do when a drive fails to appear, when a backup drive has to stand in for
the primary, or when a drive is swapped for new hardware.

Written for backlog #33. For a fresh OS install that keeps the existing drives,
see `REINSTALL.md` instead — that is a different procedure.

---

## What NASe actually keys on

Worth knowing before changing anything, because it is less than it looks:

| Thing | Where it matters |
|---|---|
| `uuid` | The mount unit's `What=`, and the identity used by `monitor.sh`, `spindown_common.sh` and `spin_status.sh`. **This is the only field that ties a config entry to a physical disk.** |
| `mountpoint` | Determines the *unit name* (`/mnt/primary` → `mnt-primary.mount`, via `systemd-escape --path`). |
| `role` | Read in exactly one place — `modules/filebrowser/setup.sh` — to pick the virtual root's main drive and its backup folders. |
| `name` | Log messages, `nase` CLI arguments, the integrity status cache filename. |
| Paths | Everything else. `sync_jobs` source/dest, Samba share paths, `config_archive.dest`, trash paths and filebrowser bind mounts are all spelled out as `/mnt/primary/...` and `/mnt/backup_daily/...` literals. |

The consequence: **swapping which physical disk backs a mountpoint is a one-field
change** (`uuid`). Everything addressed by path keeps working untouched.

---

## 1. A drive did not appear at boot

Symptoms: `sudo nase drives` shows it as not mounted, its shares are empty, and
its sync jobs skip. Since #33 you should also have had an email — if the drive
was absent when `nase-monitor.timer` last ran.

```bash
# Is the disk visible to the kernel at all?
lsblk -o NAME,SIZE,FSTYPE,UUID,MOUNTPOINT
# Does the UUID the config expects exist?
ls -l /dev/disk/by-uuid/
# What did systemd try to do?
journalctl -b -u mnt-primary.mount
journalctl -b | grep -i "Timed out waiting for device"
```

Three outcomes:

- **The UUID is present but unmounted** — `sudo systemctl start mnt-primary.mount`
  and read the error. Usually a filesystem problem; `sudo e2fsck -f -p <dev>`.
- **The disk is visible but its UUID is not** — the partition table or filesystem
  is damaged, or you are looking at a different disk. Do not re-format anything
  yet; a UUID can be recovered more easily than data.
- **The disk is not visible at all** — a cable, an enclosure or a power problem.
  Note that a missing drive costs ~90s at every boot while systemd waits for the
  device unit, and then the boot completes normally with the drive absent.

Boot is never blocked by a missing drive: the mount units are `WantedBy=`, not
required, so `multi-user.target` is reached either way.

### What is safe while a drive is absent

Sync jobs skip (`lib/guards.sh` refuses to rsync against a path that resolves to
the SD card), the config archive holds its changes as pending, and the integrity
manifest is not touched. Nothing writes to the empty mountpoint directory. If you
are on a version predating #33, that last sentence is **not** true — check that
`lib/guards.sh` contains `is_mounted_at` before relying on it.

---

## 2. Promoting a backup drive to be the primary

Use when the primary has failed and its data is gone or unreachable, and the most
recent backup should become the live copy.

**Decide these two things first. Neither is reversible cheaply.**

1. **Capacity.** The backup is smaller than the primary. Check that what you are
   promoting actually fits, with room to grow:
   ```bash
   df -h /mnt/backup_daily
   ```
   If the backup is near full, promotion buys you a working NAS that cannot
   accept new data. That may still be the right call for a few days — decide it
   deliberately rather than discovering it later.

2. **The integrity manifest.** The promoted disk carries `.nase/integrity.db`
   describing it as a backup. Nothing will object — `integrity_check_uuid`
   compares the live UUID against the one recorded on that same disk, and they
   still match — but its history will be misleading, and `reconcile-primary.sh`
   will start feeding `primary-events.log` into it. Either keep it and accept
   that, or delete it and let discovery rebuild. Rebuilding several million
   checksums is not quick; see `INTEGRITY_DESIGN.md`.

### Procedure

```bash
# 1. Record the UUID of the disk being promoted.
lsblk -o NAME,SIZE,UUID
```

```yaml
# 2. In config.yaml, point the `primary` entry at that disk.
drives:
  - name: primary
    uuid: "<the promoted disk's UUID>"   # <- the only line that changes
    mountpoint: /mnt/primary
    role: main
    read_only: false                     # a promoted drive must be writable
```

```yaml
# 3. Deactivate the drive that is gone, so it stops being expected.
  - name: backup_daily
    active: false
```

```bash
# 4. Unmount the old mountpoint, then apply.
sudo systemctl stop mnt-backup_daily.mount
sudo ./apply.sh
sudo nase drives        # /mnt/primary should now be the promoted disk
```

The share layout survives because every sync job mirrored
`/mnt/primary/<share>/` to `/mnt/backup_daily/<share>/`, so the promoted disk
already presents the same tree at the same paths. Samba shares, the filebrowser
virtual root and `config_archive.dest` all keep working without edits.

### After promoting — you now have no backup

Setting `backup_daily` to `active: false` leaves every sync job pointing at a
destination that does not exist. They will skip, correctly and quietly. Until a
replacement backup drive exists, **nothing is being backed up**, and the only
thing that will tell you so is the weekly status report. Do not leave this state
running longer than you mean to.

---

## 3. Adding a replacement drive

```bash
# 1. Partition and format. Check the device name twice — it is not stable
#    across reboots (see CLAUDE.md).
sudo mkfs.ext4 -L backup2 /dev/sdX1
blkid /dev/sdX1          # note the new UUID
```

```yaml
# 2. Add it to config.yaml.
  - name: backup_daily
    active: true
    uuid: "<new UUID>"
    mountpoint: /mnt/backup_daily
    role: backup
    read_only: true        # backup drives are read-only at rest
    spindown_min: 60
    smart_check: true
```

```bash
sudo ./apply.sh
```

`apply.sh` creates the mount unit, the `.nase/` manifest, the trash directory and
the filebrowser bind mounts. The first sync will be a full copy — expect it to
take hours, and to keep both drives spinning throughout.

Before trusting it, confirm the enclosure reports power state, which the
JMS578 in the current primary does not:

```bash
sudo hdparm -C /dev/sdX     # "standby"/"active" = good; "unknown" = see #30
```

Check this **while the return window is still open**. See backlog #27 and #30.

---

## What to verify afterwards, in all three cases

```bash
sudo nase drives                 # mounted, expected size, right mode
sudo nase status                 # timers active, no failed units
sudo nase integrity status       # manifest present, discovery progressing
sudo nase report                 # sends a status report now; check it reads right
```

A drive reported as mounted with an implausible size — a few GB where terabytes
belong — means the mountpoint is empty and you are looking at the SD card
through it. On versions predating #33 the dashboard showed exactly that, with no
other warning.
