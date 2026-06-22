# NASe — Fresh OS Reinstall (keep the data)

How to wipe the SD card, install a fresh OS, reinstall NASe, and resume access to
the existing data **without touching the three USB data drives**.

> **Why this is safe:** the data lives on `/dev/sda` (primary), `/dev/sdb`
> (backup_daily) and `/dev/sdc` (backup_weekly). NASe mounts them **by UUID**
> (see `config.yaml`), so as long as `config.yaml` is restored, the drives
> reattach exactly as before. The SD card only holds the OS + the `/opt/nase`
> checkout.

The whole reinstall comes down to: **back up 2 files → flash fresh OS →
re-clone → restore the 2 files → run `install.sh`.**

---

## 0. Before you start — back up the irreplaceable bits

Two files on the SD card cannot be recovered from GitHub:

| File | Tracked in git? | Why it matters |
|------|-----------------|----------------|
| `/opt/nase/.env` | **No** (gitignored) | Samba / Filebrowser passwords, Tailscale authkey, SMTP creds |
| `/opt/nase/config.yaml` | Yes, but your live copy may have **unpushed edits** | Drive UUIDs, sync jobs, all settings |

Copy both off the Pi to your laptop (or a USB stick / the primary data drive):

```bash
# from your laptop:
scp toma@nase:/opt/nase/.env         ./nase-backup/
scp toma@nase:/opt/nase/config.yaml  ./nase-backup/
```

Also, if you've made local code changes you care about, commit & push them
(or copy the whole `/opt/nase` tree):

```bash
sudo -u toma git -C /opt/nase status        # check for uncommitted work
git -C /opt/nase log origin/master..HEAD    # check for unpushed commits
```

Optional belt-and-suspenders snapshot of the entire repo:

```bash
ssh toma@nase 'sudo tar czf /tmp/nase-repo.tgz -C /opt nase' && \
  scp toma@nase:/tmp/nase-repo.tgz ./nase-backup/
```

---

## 1. Note the current drive UUIDs (sanity reference)

So you can confirm nothing changed after the reinstall:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,LABEL
```

Expected (from current `config.yaml`):

| Drive | UUID | Label | Mount |
|-------|------|-------|-------|
| primary       | `532b7925-0236-4dd4-8454-56050eb510d2` | NAS_PRIMARY  | /mnt/primary |
| backup_daily  | `044b7611-ec84-48e3-9ded-bf6a76876d01` | NAS_BACKUP_1 | /mnt/backup_daily |
| backup_weekly | `135c94c8-d188-442a-a8b4-97061c11ac62` | NAS_BACKUP_2 | /mnt/backup_weekly |

---

## 2. Shut down and physically disconnect the data drives

This is the single most important safety step for a *test* reinstall: it makes it
**impossible** to accidentally format a data drive while flashing the OS.

```bash
sudo nase pause          # stop sync timers
sudo poweroff
```

Then unplug the **three USB data drives**. Leave only the SD card.

---

## 3. Flash a fresh OS to the SD card

Use Raspberry Pi Imager on your laptop:

- OS: **Raspberry Pi OS (64-bit), Bookworm or later** (this Pi runs Trixie).
- In the imager's **⚙ advanced settings**, pre-configure:
  - hostname: `nase`
  - enable **SSH** (key-based recommended; paste your public key)
  - username `toma` + password
  - Wi-Fi / locale as needed
- Write to the SD card, insert it, boot the Pi (still **without** data drives).

First boot will resize the filesystem and reboot once. Then:

```bash
ssh toma@nase   # or ssh toma@<ip-address>
```

---

## 4. Reconnect the data drives

With the Pi running, plug the three USB data drives back in. Confirm the kernel
sees them and the UUIDs match Step 1:

```bash
lsblk -o NAME,SIZE,FSTYPE,UUID,LABEL
```

> They will **not** be mounted yet — NASe creates the mount units. That's
> expected. Don't manually mount or format them.

---

## 5. Install prerequisites and clone NASe

```bash
sudo apt-get update
sudo apt-get install -y git
sudo git clone git@github.com:mcoin/NASe.git /opt/nase
# (HTTPS alternative if no deploy key: https://github.com/mcoin/NASe.git)
sudo chown -R toma:toma /opt/nase
```

If you pushed local commits in Step 0, check out the right branch/commit now.

---

## 6. Restore the two saved files

```bash
# from your laptop:
scp ./nase-backup/.env         toma@nase:/opt/nase/.env
scp ./nase-backup/config.yaml  toma@nase:/opt/nase/config.yaml

# on the Pi — lock down secrets:
sudo chmod 600 /opt/nase/.env
```

> Restoring `config.yaml` is what makes the drives come back identically — it
> carries the UUIDs, mountpoints, read-only flags, and all sync jobs.

---

## 7. Run the installer

```bash
cd /opt/nase
sudo ./install.sh
```

This installs packages (rsync, samba, smartmontools, python venv, yq, msmtp,
Tailscale if enabled), then runs `apply.sh`, which:

- writes the systemd `.mount` units and mounts the drives by UUID,
- regenerates `/etc/samba/smb.conf` and Samba users,
- recreates the per-job sync `.service`/`.timer` pairs,
- rebuilds the Filebrowser virtual root,
- (re)authenticates Tailscale using `TAILSCALE_AUTHKEY` from `.env`,
- starts the web dashboard and `nase-monitor`.

---

## 8. Verify everything is back

```bash
sudo nase status                       # services, timers, drives
sudo nase drives                       # mounts + usage; UUIDs must match Step 1
systemctl list-timers 'nase-sync-*'    # timers active/waiting
ls /mnt/primary /mnt/backup_daily /mnt/backup_weekly   # data is there
```

Check shares and the dashboard:

- Samba: connect from another machine to `\\nase\...` (or `smb://nase/`).
- Web UI: `http://nase:8088/`
- Tailscale (if enabled): `tailscale status`

Run one sync job to confirm the rsync path end-to-end:

```bash
sudo nase sync nase-cfg-backup-daily
```

---

## Notes & gotchas

- **Tailscale device identity** resets (new node) unless you restore
  `/var/lib/tailscale/` from a backup. With an authkey in `.env` it simply
  re-registers — fine for most setups; you may want to remove the stale node
  from the Tailscale admin console.
- **Samba/Filebrowser passwords** come from `.env`; clients keep working only
  because the same passwords are restored. If you regenerate `.env`, re-enter
  credentials on clients.
- **Host SSH keys** change with a fresh OS, so `ssh` will warn about a changed
  host key — clear it with `ssh-keygen -R nase` on your laptop.
- **`backup_weekly` is currently in a degraded state** (aborted ext4 journal on
  `/dev/sdc1`). Reinstalling the OS does **not** fix that — repair the
  filesystem with `sudo e2fsck -f -y /dev/sdc1` (drive unmounted) before or
  after the reinstall.
- This procedure never formats or writes to the data drives. The only
  destructive action is flashing the **SD card**.
</content>
</invoke>
