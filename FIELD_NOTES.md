# NASe — field notes

Hard-won findings with the evidence behind them. `CLAUDE.md` states the traps in
one line each; this file is why, so a future reader can tell a rule from a
superstition. Read it when investigating the relevant area, not routinely.

---

## Drives

### `hdparm -C` answers `unknown` for primary (#27)

Its JMicron JMS578 bridge does not implement ATA CHECK POWER MODE, even though
SMART passes through it fine. This is the bridge, not the `uas` driver: #27
forced the device onto `usb-storage` with `usb-storage.quirks=152d:0578:u` and
the answer did not change, so the quirk was rolled back.

backup_daily's ASMedia AS2105 does report power state, which is why one drive
reports `confirmed` and the other `estimated`. Never treat `unknown` as "awake" —
ask `modules/drives/spin_status.sh <name>`, which falls back to inferring state
from `/sys/block/<disk>/stat`.

Any replacement enclosure must be checked for a working `hdparm -C` **before its
return window closes**. See #30.

### Device letters move between boots

On 2026-09-05 primary moved from `/dev/sda` to `/dev/sdb` because the AS2105
enumerated first that boot. During #27 this made an `hdparm -C /dev/sda` reading
of *backup_daily* look like a successful fix to *primary*. Resolve by UUID or by
USB `vid:pid`, never by letter — and never compare a before/after measurement by
letter.

### hdparm settings do not survive a power cycle (#32)

A reboot resets APM to the drive's factory default (usually 254), which disables
spin-down in firmware and silently overrides any `-S` timer, so an idle drive
spins forever.

Re-applying them is `nase-spindown.service`'s job, not udev's: udev fires 1–2 s
after the device node appears, while a USB disk is still spinning up and its
bridge rejects `SET FEATURES`, so the old inline `RUN+="hdparm …"` failed on
every boot. `-B` and `-S` are applied as **separate** invocations — primary's
bridge has no APM at all, and a combined call fails as a whole, taking the
standby timer down with it.

If a drive spins with no I/O, check `hdparm -B <disk>` before hunting for a
process: 254 means nothing ever applied the settings.

### A missing drive costs 90s at boot, not a hang (#33)

Mount units are `WantedBy=`, not required, so `multi-user.target` is reached
either way. The wait is systemd's default device job timeout.
`x-systemd.device-timeout` in a unit file's `Options=` is **ignored** —
systemd.mount(5) says it only works in `/etc/fstab`.

---

## Shutdown (#31)

A reboot on 2026-09-05 never completed and the power had to be pulled. Ten
filebrowser bind mounts sit on two USB drive mounts; a bind mount that will not
release keeps the drive under it busy, and no systemd timeout covers a
kernel-side unmount that never returns.

`modules/drives/teardown.sh` (ExecStop of `nase-shutdown.service`) flushes any rw
drive, unmounts deepest-first with a lazy fallback, and syncs — every step
wrapped in `timeout`, every failure tolerated.

**It must never call `systemctl`**: it runs inside the shutdown transaction,
where queueing new jobs can deadlock the shutdown it exists to protect. Ordering
(`After=` in the unit) is what stops the services. The bind-mount units have
carried `After=mnt-<drive>.mount` since they were introduced, which already gives
systemd the stop ordering; the teardown adds the flush, the bounded steps and the
lazy fallback on top.

### An ExecStop hook only runs if something stops the unit

Two reboots passed with `teardown.sh` never executing, for two different reasons:

1. The unit was enabled but never started — fixed by `enable --now` in apply.sh.
2. It was active but had no stop job. `DefaultDependencies=no` suppresses the
   implicit `Conflicts=shutdown.target`, and that conflict is the only thing that
   puts a stop job into the shutdown transaction. `Before=` merely orders a stop
   job that already exists.

Both failures are silent: the shutdown looks clean, and the only evidence is the
*absence* of `Stopping nase-shutdown.service` in the journal and of teardown lines
in `nase.log`. `tests/test-teardown.sh` asserts both against the unit file.

### `orphan cleanup on readonly fs` is not evidence of a dirty shutdown

#31 originally read that line as proof the filesystems were never unmounted
cleanly. It is not. `mmcblk0p2` and backup_daily carry the ext4 `orphan_file` /
`orphan_present` features, which make `ext4_orphan_cleanup()` skip its empty-list
early return and log the line on *every* read-only mount. primary mounts rw and
never shows it; the SD card is mounted ro then remounted rw on every boot, and
backup_daily is ro by design, so both print it every time.

Confirmed 2026-09-06: backup_daily unmounted cleanly at 10:35:59, was remounted
ro at 10:39:11 and logged it again — and a reboot at 15:23, watched start to
finish in the journal, produced it on a shutdown that demonstrably completed.
`e2fsck -f -p` found nothing.

To judge whether a filesystem was dirty, use `dumpe2fs -h` (`Filesystem state`)
or the `N orphan inodes deleted` line, which is what actual cleanup logs.

---

## Reading the journal

The journal is made persistent on purpose. Raspberry Pi OS ships
`Storage=volatile` to spare the SD card, which means a hung shutdown leaves no
evidence at all — #31 had to be reconstructed from side effects. NASe installs a
capped `Storage=persistent` drop-in instead.

**This Pi has no RTC.** Journal and wtmp timestamps in the first seconds of a boot
can be minutes behind reality (systemd restores the last saved clock, then
timesyncd corrects it). Use `uptime -s` to date a boot, not the journal's first
entry.

---

## The `findmnt --target` trap (#31, #29, #33)

`findmnt --target PATH` resolves **up** to the nearest enclosing mount, so for an
unmounted `/mnt/primary` it finds the SD card's root mount and exits 0. Used as a
boolean "is this mounted?" it never fires.

Found and fixed one at a time in `teardown.sh` (#31), `report.sh` (#29), and then
in three more places at once (#33) — where it had been writing config snapshots
and an integrity manifest **to the SD card** under `/mnt/primary/...`, invisible
once the real drive mounted over them, and logging success.

Use `is_mounted_at` / `is_mounted_ro_at` from `lib/guards.sh`, or
`findmnt --mountpoint`. `is_safe_mount_path` was always correct — it compares the
resolved *device* against the root device rather than trusting findmnt's exit
status.

Related: `/mnt/backup1` and `/mnt/backup2` are stale directories on the SD card
from an earlier layout, not mountpoints — they are the original example of this.

---

## Waking drives (#4)

The nightly sync used to wake primary every night. Phases 1 and 2 moved change
detection off the platter and onto the inotify event log
(`modules/primary-watch`), and collapsed nine per-job timers into one group timer.

Two defects are written up on #4 but not fixed:

- The preflight `test -d` at `sync.sh:63`/`:69` still stats the source and
  destination on every job, before the change-detection skip — normally a dentry
  cache hit, which is why the resulting wake is intermittent.
- Wake attribution (`spin_sample.sh:98-100`) names the *last job to start* before
  the wake. With the group finishing in under three minutes and sampling every
  five, it routinely blames whichever job happened to be last. The I/O column in
  `spin-history.log` is the corrective signal: single digits is a cache miss,
  tens of thousands is something walking the drive.

`status_report.enabled: false` does **not** disable the status report — yq's
`a // b` falls back on `false` as well as null. Tracked as #40.

---

## Backlog text

Ticket descriptions, decisions and notes are stored exactly as typed and are never
rewritten. Older entries were hard-wrapped at ~80 columns and render in a
~64-character column, so `unwrap_prose()` (a Jinja filter in `main.py`) joins runs
of unindented prose at render time — headers, list items, indented blocks and
tables keep their line structure. Write new ticket text without hard wraps.
