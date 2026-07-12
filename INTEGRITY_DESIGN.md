# NASe Checksum Integrity — Design

Generated: 2026-07-12
Status: implementing

---

## Goal

Maintain a per-file checksum manifest for every drive (primary, backup_daily,
and future backup_weekly) so that silent bit-rot — a file whose bytes change
on disk without any legitimate write — is detected and reported, rather than
silently propagated or discovered only when someone opens a damaged file.

Neither of NASe's existing mechanisms catches this: `nase-monitor` (SMART)
detects drive-level failure, not per-file corruption; rsync's default
quick-check (size+mtime) never re-reads bytes of a file it thinks is already
in sync, so it will never notice that an untouched backup file has flipped a
bit.

## Feasibility summary (measured on this Pi4, 2026-07-12)

- Primary: 5.5TB HDD (USB3), 1.6TB used, ~4.3M files. Backup_daily: 1.8TB HDD
  (USB3), 1.6TB used, ~3.9M files. Both spinning disks.
- Real single-core SHA-256 throughput on this hardware: ~87MB/s.
- DB size: ~250-300 bytes/row in SQLite (path + hash + timestamps + index) →
  ~2.5-3.3GB across primary+backup_daily today, ~3.5-4.5GB once
  backup_weekly joins. Must live on the data drives, not the 14GB SD card.
- A full one-time hash of all existing bytes would cost ~5-15+ hours per
  drive (throughput-bound ~5.2h, plus real HDD seek overhead across millions
  of small files) — too disruptive to run as a single blocking pass, hence
  the progressive-discovery design below.
- Steady-state sampling (e.g. a 60-day full-verification cycle) costs on the
  order of 15-60 minutes of I/O per drive per night — comfortably inside the
  existing nightly sync window, on hardware that is otherwise idle overnight
  (3.7GB RAM, ~675MB used at rest).

## Storage layout

One SQLite database per drive, stored **on that drive**, not centrally:

```
/mnt/primary/.nase/integrity.db
/mnt/backup_daily/.nase/integrity.db
/mnt/backup_weekly/.nase/integrity.db   (when added)
```

Rationale: backup drives are normally read-only and only briefly remounted
rw during their nightly sync — writing the manifest update there piggybacks
on a window that already exists rather than needing its own rw dance. A
drive that gets physically replaced starts with no `.nase/` and therefore no
stale manifest — it's rebaselined from scratch automatically, which is the
correct behaviour for a different physical disk. It also keeps the (multi-GB
and growing) DB off the wear-sensitive SD card by construction.

## Schema

Identical DDL on every drive's `integrity.db` (see `modules/integrity/schema.sql`):

```sql
CREATE TABLE files (
  id            INTEGER PRIMARY KEY,
  path          TEXT NOT NULL UNIQUE,      -- relative to the drive's mountpoint
  size          INTEGER NOT NULL,
  mtime         INTEGER NOT NULL,          -- unix epoch, from stat
  checksum      TEXT NOT NULL,             -- sha256, lowercase hex (64 chars)
  status        TEXT NOT NULL DEFAULT 'ok' CHECK(status IN ('ok','flagged')),
  first_seen    INTEGER NOT NULL,
  last_updated  INTEGER NOT NULL,          -- checksum last legitimately (re)computed
  last_checked  INTEGER NOT NULL           -- last time verified, changed or not
);
CREATE INDEX idx_files_sample ON files(status, last_checked);

CREATE TABLE events (
  id          INTEGER PRIMARY KEY,
  ts          INTEGER NOT NULL,
  path        TEXT NOT NULL,
  event_type  TEXT NOT NULL CHECK(event_type IN ('mismatch','missing','ack')),
  detail      TEXT
);

CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);  -- schema_version, drive_uuid, discovery_cursor_n, discovery_complete,
    -- primary_events_cursor (primary drive only)
```

`idx_files_sample` makes the sampler's core query
(`WHERE status='ok' ORDER BY last_checked LIMIT N`) an index-only scan.

**On mismatch**: flag the row (`status='flagged'`), keep the *old* checksum
on record, log a `mismatch` event, send one batched alert email. Flagged
rows are excluded from future sampling until `nase integrity ack` clears
them — this stops a real, persisting corruption from being silently
re-trusted on the next cycle.

**On a sampled file that's missing from disk**: same treatment as a
mismatch (flag + `missing` event + alert), not a silent delete — an
out-of-band disappearance (not through the managed sync/trash flow) is
exactly the class of problem this feature exists to catch.

## Progressive discovery (no manual bootstrap required)

`reconcile-backup.sh` and `reconcile-primary.sh` only see *deltas* — they
can't discover the millions of files that already existed before this
feature was enabled. That discovery doesn't need a separate blocking pass,
though: it's folded into the same nightly budgeted job as the sampler.

`meta.discovery_cursor` tracks a sorted-path walk position;
`meta.discovery_complete` flips true once the walk reaches the end of the
tree. Each nightly run, per drive, within one shared budget:

```
1. resume the sorted walk from discovery_cursor, hash + insert new files
   (first_seen = last_updated = last_checked = now) until either the
   budget is spent or the walk reaches the end of tree
2. if budget remains after discovery catches up (or discovery_complete),
   spend the rest on the existing oldest-last_checked resample query
```

Per-file cost (stat + read + hash) is the same whether the file is new to
the DB or being resampled, so no separate discovery-specific config knob is
needed — `min_sample`/`max_sample` govern both. Early on, nearly all budget
goes to discovery (almost nothing to resample yet); the balance shifts
naturally as the walk completes.

Trade-off: until the walk reaches a given file, that file has no baseline —
same blind spot as before the feature existed, spread across the ramp-up
period instead of concentrated in one multi-hour, disk-and-CPU-hammering
run. `nase integrity bootstrap <drive>` re-runs the same discovery logic
with no budget cap, for a deliberate full-speed pass (e.g. right after
physically swapping in a new backup drive).

## Sampling scheduler

Config (`config.yaml`):

```yaml
integrity:
  enabled: true
  cycle_days: 60             # verify every known file at least once per this many days
  min_sample: 200            # floor per run, so small/young drives still get checked
  max_sample: 5000           # ceiling per run, so a large backlog can't blow the nightly budget
  skip_recent_seconds: 3600  # don't sample files touched in the last hour
```

`budget = clamp(count(status='ok') / cycle_days, min_sample, max_sample)`,
recomputed from the live row count each run so it self-adjusts as the
library grows instead of drifting off a fixed number.

## Trigger point: piggyback on the nightly sync window

- **Backup drives**: `sync.sh` already remounts the destination rw for the
  duration of an rsync run and remounts ro via an `EXIT` trap. The discovery
  + sample pass for that drive runs inside the same window, guarded so it
  fires at most once per drive per calendar day even though up to 8 jobs
  share `backup_daily` (serialized already via the existing per-drive
  `flock`).
- **Primary**: always mounted rw, so no dance needed — the same once/day
  guard triggers it from the first sync job to finish each night.

This means no new drive spin-ups are introduced beyond what NASe already
schedules — the whole point of `spindown_min` is to keep these HDDs asleep
most of the time, and this feature must not work against that.

## Change detection: two different existing signals, not a fresh tree walk

- **Backup drives**: `sync.sh` already computes the transferred-file list
  (`--out-format='NXFR %n'`, captured as `$transferred`) and the rsync log.
  `reconcile-backup.sh` reuses that plus a `--log-file-format='%i %n'`
  itemize capture to also see deletions, and upserts/deletes rows in both
  the source and destination drives' DBs for exactly the files that moved
  that run. Each touched file is hashed independently on both sides
  (defense-in-depth: catches corruption introduced during the copy itself,
  not just corruption at rest).
- **Primary**: NASe already runs `nase-primary-watch.service`
  (`modules/primary-watch/record.sh`), an inotify recorder that appends
  every create/modify/delete under `/mnt/primary` to
  `/var/lib/nase/primary-events.log` (tab-separated: timestamp, op, path).
  `reconcile-primary.sh` consumes new lines since `meta.primary_events_cursor`
  instead of doing its own tree walk or waiting for the nightly rsync —
  this is finer-grained and already-running infrastructure, not a new
  mechanism.

Known gap: a primary share path with no matching `sync_jobs` entry has
nothing pushing it to a backup drive, but is still covered by
`primary-events.log` and discovery, so it gets a baseline and gets
resampled — it just never gets a second, independently-hashed copy the way
job-backed files do. Not solved here; noted for awareness.

## Guards against accidental deletion/overwrite of `.nase/`

Backup drives bind-mount their **entire** mountpoint into filebrowser's
virtual root (`modules/filebrowser/setup.sh`) and are also exposed as a
whole-drive Samba share — so `.nase/` is reachable through both UIs unless
explicitly protected. Guards, layered:

1. **Ownership/permissions**: `.nase/` created `root:root`, mode `0700` by
   `modules/integrity/setup.sh`. Both Samba and `filebrowser.service`
   (`User=nase`) run as the `nase` OS user, so this alone makes `.nase/`
   unreadable and undeletable through either interface — this is the
   load-bearing guard for backup drives.
2. **`fix-ownership.sh`**: the existing recursive
   `chown -R "${owner}:${owner}" "$mountpoint"` would silently undo #1 the
   next time it's run (a plausible "fumbling with drives" action). Changed
   to prune `.nase/` out of the walk.
3. **`validate-config.sh`**: reject any `sync_jobs[].source`/`.dest` that
   resolves to a drive's mountpoint root itself (must be a strict
   subdirectory) — closes off the config mistake that would put `.nase/`
   inside an rsync `--delete` scope.
4. **`sync.sh`**: unconditional `--exclude=/.nase`, alongside the existing
   `._*`/`.DS_Store` excludes, regardless of configured `rsync_flags` —
   defense-in-depth on top of #3.
5. **UUID cross-check**: `meta.drive_uuid` recorded at DB creation; every
   write path re-checks the live UUID at the mountpoint before writing and
   skips (`log_warn`, not `die`) on mismatch — defense-in-depth against
   physically swapped/re-cabled drives producing cross-contaminated records.
6. `modules/drives/setup.sh`'s stale-unit cleanup / lazy-unmount logic was
   read and confirmed to only ever `umount` and manage the empty mountpoint
   directory itself — never directory contents. No change needed.

None of this uses `chattr +i` — that would fight the feature's own nightly
writes to the DB. The threat model is *casual* deletion via Samba/
filebrowser/a careless recursive command, not a deliberate `sudo rm -rf`,
which remains possible by design (and correct — a drive being decommissioned
or wiped on purpose shouldn't be fought).

## CLI

```
sudo nase integrity status [drive]      Flagged files, per-drive row counts, cycle progress
sudo nase integrity ack <drive> <path>  Clear a flagged row after manual review
sudo nase integrity bootstrap <drive>   Run discovery uncapped (full-speed baseline)
```

## Module layout

```
modules/integrity/
  schema.sql               DDL, versioned
  common.sh                shared helpers: db path, uuid check, budget calc
  setup.sh                 creates .nase/ + schema on active drives (root:root 0700)
  discover_and_sample.sh   nightly budgeted discovery + resample, called from sync.sh
  bootstrap.sh             uncapped discovery, called manually via nase CLI
  reconcile-backup.sh      called from sync.sh after a successful rsync
  reconcile-primary.sh     consumes primary-events.log since last cursor
```
