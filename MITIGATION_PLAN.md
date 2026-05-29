# NASe Risk Mitigation Plan

Generated: 2026-05-29  
Status: pending implementation

This plan addresses data-safety risks identified before going into production.
Items are ordered by priority (highest risk / lowest effort first).

---

## Item 1 — Verify the notification path works (operational)

**Risk**: SMTP or webhook misconfiguration causes all failure alerts (sync, SMART)
to be silently dropped. The system appears healthy but notifications never arrive.

**Effort**: ~5 minutes.

### Steps

1. Make sure `.env` is populated with valid SMTP or webhook credentials:
   ```
   SMTP_HOST=...
   SMTP_PORT=...
   SMTP_USER=...
   SMTP_PASSWORD=...
   NOTIFY_FROM=...
   NOTIFY_TO=...
   ```
   or
   ```
   NOTIFY_WEBHOOK_URL=...
   ```

2. Run the built-in test command:
   ```bash
   sudo nase notify-test
   ```

3. Confirm the test email/webhook arrives within a few minutes.

4. If it does not arrive:
   - Check `/var/log/nase/nase.log` for errors from `notify.sh`.
   - Run `modules/sync/notify.sh` directly with a test subject and body to see
     raw output.
   - For email: verify `msmtp` or `sendmail` is installed and reachable.

**Done when**: test notification is received and confirmed.

---

## Item 2 — Atomic `config.yaml` writes (code change)

**Risk**: `_save_section()` in `modules/web/app/main.py` opens `config.yaml`
with `open(CONFIG_FILE, "w")` and streams YAML into it. A power loss or OOM
kill mid-write leaves a truncated or corrupt file. Since this is the single
source of truth, a corrupt `config.yaml` breaks `apply.sh` entirely until
manually restored.

**Effort**: ~15 minutes.

### Files to change

- `modules/web/app/main.py` — `_save_section()` function (lines ~223–238).

### Implementation

Replace the direct `open(CONFIG_FILE, "w")` write at the end of `_save_section`
with a write-to-temp + atomic rename pattern:

```python
# Before (fragile):
with open(CONFIG_FILE, "w") as f:
    ry.dump(doc, f)

# After (atomic):
import tempfile
import os

with tempfile.NamedTemporaryFile(
    "w",
    dir=CONFIG_FILE.parent,
    delete=False,
    suffix=".tmp",
) as tmp:
    ry.dump(doc, tmp)
    tmp_path = tmp.name
os.replace(tmp_path, CONFIG_FILE)   # atomic on Linux (same filesystem)
```

`os.replace()` is a single `rename(2)` syscall — it is atomic on Linux when
the temp file and the target are on the same filesystem (both in `/opt/nase/`).
A crash at any point before the rename leaves the original file untouched.

The `import tempfile` and `import os` can be moved to the top of the file with
the other imports.

### Verification

1. Open the config editor in the web UI, make a trivial change (e.g. add a
   trailing space to a comment), save.
2. Confirm `config.yaml` is still valid: `yq eval '.' /opt/nase/config.yaml`.
3. Confirm the change persisted: `git diff /opt/nase/config.yaml` or just
   re-open the editor tab.

**Done when**: `_save_section` uses `os.replace()` and manual test passes.

---

## Item 3 — Semantic validation before saving config (code change)

**Risk**: The web UI validates YAML syntax (`yaml.safe_load`) before writing,
but semantic validation (`tests/validate-config.sh`) only runs during
`apply.sh`. A logically invalid config (e.g. `drives: []`, bad UUID format,
missing required field) is written to disk immediately, with no warning until
the user clicks Apply — at which point the file is already overwritten.

**Effort**: ~30 minutes.

### Files to change

- `modules/web/app/main.py` — `save_config_section()` route handler
  (lines ~279–303).

### Implementation

After the `yaml.safe_load` syntax check but before calling `_save_section`,
write the updated section to a temp file and run `validate-config.sh` against
it:

```python
import tempfile, subprocess, shutil, os

@_protected.post("/config/{section}", response_class=HTMLResponse)
async def save_config_section(request: Request, section: str):
    ...
    # 1. Syntax check (already present)
    try:
        yaml.safe_load(yaml_text)
    except yaml.YAMLError as exc:
        return _err(f"YAML parse error: {exc}")

    # 2. Write candidate config to a temp file, run validate-config.sh on it
    tmp_cfg = None
    try:
        # Build the full candidate config in memory
        import io
        ry = _make_ryaml()
        with open(CONFIG_FILE) as f:
            candidate = ry.load(f)
        new_value = ry.load(yaml_text)
        candidate[section] = new_value

        with tempfile.NamedTemporaryFile(
            "w", suffix=".yaml", delete=False
        ) as tmp:
            ry.dump(candidate, tmp)
            tmp_cfg = tmp.name

        result = subprocess.run(
            [str(REPO_ROOT / "tests" / "validate-config.sh")],
            env={**os.environ, "CONFIG_FILE": tmp_cfg},
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            output = (result.stdout + result.stderr).strip()
            return _err(f"Config validation failed:\n{output}")
    except Exception as exc:
        return _err(f"Validation error: {exc}")
    finally:
        if tmp_cfg and os.path.exists(tmp_cfg):
            os.unlink(tmp_cfg)

    # 3. Save for real
    try:
        _save_section(section, yaml_text)
    except Exception as exc:
        return _err(f"Write error: {exc}")
    ...
```

Note: `validate-config.sh` reads `CONFIG_FILE` from the environment (via
`lib/config.sh`). Confirm this is the correct env var name by checking
`lib/config.sh` before implementing.

### Verification

1. In the web UI, edit the Drives section and delete the UUID field from one
   drive.  Save → expect a validation error shown in the UI, original file
   unchanged.
2. Make a valid change → expect save to succeed.

**Done when**: semantically invalid configs are rejected at save time with a
human-readable error.

---

## Item 4 — Manually verify the trash mechanism before enabling `--delete` on real data (operational)

**Risk**: The trash mechanism is assumed to work, but has never been exercised
against real data. If trash is silently misconfigured (wrong path, backup drive
mounted ro at the moment of the backup-dir write, wrong permissions), `rsync
--delete` would permanently delete files with no recovery path.

**Effort**: ~20 minutes.

### Steps

1. Create a test file on the primary drive:
   ```bash
   echo "trash test $(date)" > /mnt/primary/test/trash-verify.txt
   ```

2. Run the test backup job manually to establish a baseline:
   ```bash
   sudo nase sync test-backup-daily
   ```
   Confirm `/mnt/backup_daily/test/trash-verify.txt` exists.

3. Delete the file from the source:
   ```bash
   rm /mnt/primary/test/trash-verify.txt
   ```

4. Run the sync job again:
   ```bash
   sudo nase sync test-backup-daily
   ```

5. Verify the trash received the file:
   ```bash
   find /mnt/backup_daily/.trash -name "trash-verify.txt"
   ```
   This should return at least one path.

6. Verify the file is gone from the backup destination:
   ```bash
   ls /mnt/backup_daily/test/trash-verify.txt   # should NOT exist
   ```

7. Check the central log for the "trashed: …" lines:
   ```bash
   nase logs | grep trash-verify
   ```

**Done when**: file appears in `.trash/` and not in the destination, log
confirms the trash count.

---

## Item 5 — Enable trash on config-archive backup jobs (config change)

**Risk**: `nase-cfg-backup-daily` and `nase-cfg-backup-weekly` use `--delete`
with `trash: enabled: false`. If `/mnt/primary/NASe/` is accidentally emptied
(e.g. config-archive timer failure, manual mistake), the next 5-minute backup
job propagates the deletion to both backup drives. The mount guard only catches
an unmounted drive — it cannot detect an empty but mounted directory.

**Effort**: ~5 minutes (after Item 4 is verified).

### Files to change

- `config.yaml` — the two `nase-cfg-backup-*` sync job entries.

### Implementation

For both `nase-cfg-backup-daily` and `nase-cfg-backup-weekly`, change:

```yaml
    trash:
      enabled: false
```

to:

```yaml
    trash:
      enabled: true
      path: /mnt/backup_daily/.trash    # or /mnt/backup_weekly/.trash
      retention_days: 90
```

Use a longer retention (90 days, matching config-archive) since config snapshots
are small and losing them silently is costly.

Then run `sudo ./apply.sh` to create the `.trash` directory on each backup drive.

### Verification

```bash
ls /mnt/backup_daily/.trash
ls /mnt/backup_weekly/.trash
```

Both directories should exist.

**Done when**: both jobs have trash enabled and `apply.sh` completes cleanly.

---

## Item 6 — Improved SMART attribute monitoring (code change)

**Risk**: `modules/drives/monitor.sh` only greps for "PASSED"/"FAILED" in
`smartctl -H` output. Early-warning SMART attributes — reallocated sectors,
pending sectors, uncorrectable errors — accumulate silently without triggering
a FAILED status. By the time the drive hits FAILED, significant data may
already be at risk.

**Effort**: ~45 minutes.

### Files to change

- `modules/drives/monitor.sh`

### Key SMART attributes to monitor

| ID  | Attribute name                  | Alert if |
|-----|---------------------------------|----------|
| 5   | Reallocated_Sector_Ct           | > 0      |
| 187 | Reported_Uncorrect              | > 0      |
| 188 | Command_Timeout                 | > 0      |
| 197 | Current_Pending_Sector          | > 0      |
| 198 | Offline_Uncorrectable           | > 0      |

### Implementation

After the existing `smartctl -H` check, add a second `smartctl -A` pass and
parse the raw values for the attributes above:

```bash
# After the existing PASSED/FAILED check...

# Check early-warning SMART attributes
attr_output=$(smartctl -A "$disk_path" 2>&1 || true)

warn_attrs=()
while IFS= read -r line; do
    # Lines look like:
    #   5 Reallocated_Sector_Ct   0x0032   100   100   000    Old_age ...  0
    # Field 1 = ID, field 10 = raw value
    attr_id=$(echo "$line" | awk '{print $1}')
    raw_val=$(echo "$line" | awk '{print $NF}')
    case "$attr_id" in
        5|187|188|197|198)
            # Ignore obviously invalid lines
            [[ "$raw_val" =~ ^[0-9]+$ ]] || continue
            if [[ "$raw_val" -gt 0 ]]; then
                attr_name=$(echo "$line" | awk '{print $2}')
                warn_attrs+=("${name}: attribute ${attr_id} (${attr_name}) = ${raw_val}")
            fi
            ;;
    esac
done <<< "$attr_output"

if [[ ${#warn_attrs[@]} -gt 0 ]]; then
    for w in "${warn_attrs[@]}"; do
        log_warn "  SMART warning: ${w}"
        failures+=("SMART attribute warning — ${w}")
    done
fi
```

Add the warnings to the existing `failures` array so they flow into the
existing notification path without needing a separate alert mechanism.

### Verification

Run the monitor manually:
```bash
sudo /opt/nase/modules/drives/monitor.sh
```
Check `/var/log/nase/nase.log` for attribute lines. On healthy drives all
watched attributes should be 0 — the log will show "All SMART checks passed."

**Done when**: `monitor.sh` alerts on non-zero early-warning attributes and
the manual run produces clean output on healthy drives.

---

## Item 7 — Add `--checksum` to photo and video sync jobs (config change)

**Risk**: All sync jobs except `music-backup-daily` use mtime + size for
change detection. Silent bit-rot (storage controller error, filesystem
corruption) that changes file content without changing mtime goes undetected
until the next forced sync reads the file. For irreplaceable data (photos,
videos) this means a corrupted file could sit on the primary for days or weeks
before the backup reflects it — and by then the backup is also corrupted.

**Note**: `--checksum` significantly increases sync I/O (reads every file on
both sides). On large datasets it will spin up backup drives on every run. Test
on the `test` share first.

**Effort**: ~10 minutes (config only), plus validation time.

### Files to change

- `config.yaml` — `photos-backup-daily`, `photos-backup-weekly`,
  `videos-backup-daily`, `videos-backup-weekly`.

### Implementation

Add `--checksum` to `rsync_flags` for the four photo/video jobs:

```yaml
    rsync_flags: --archive --delete --checksum
```

Then run `sudo ./apply.sh` (no restart needed — timers just run `sync.sh`
which reads config fresh each time).

### Validation

Run one of the affected jobs manually and observe the duration:
```bash
time sudo nase sync photos-backup-daily
```

If the runtime is acceptable, the change is good. If it's too slow on a large
dataset, consider running `--checksum` only on the weekly jobs and keeping
mtime-only on the daily jobs.

**Done when**: photo and video jobs use `--checksum` and a manual run
completes without errors.

---

## Item 8 — Off-site backup for critical data (structural)

**Risk**: All three drives (primary, backup_daily, backup_weekly) are
physically co-located. A single incident (fire, power surge, theft) destroys
all copies simultaneously. This is the 3-2-1 rule violation: 3 copies, 2
media types, but only 1 location.

**Effort**: 1–4 hours depending on chosen solution.

**Priority data**: Photo_albums, Music (irreplaceable or hard to replace).
Videos and omv2 are lower priority if they can be re-downloaded or reconstructed.

### Options (choose one)

#### Option A — Tailscale + another machine (free, already have Tailscale)

If you have access to another machine (home server, relative's NAS, old laptop)
on your Tailscale network, add a sync job pointing to that machine via rsync
over SSH:

```yaml
  - name: photos-offsite
    source: /mnt/primary/Photo_albums/
    dest: user@100.x.x.x:/mnt/offsite/Photo_albums/
    schedule: '*-*-* 03:00:00'          # nightly at 3 AM
    rsync_flags: --archive --delete --checksum
    on_failure: notify
    force_sync_days: 7
    trash:
      enabled: false
```

This requires:
- SSH key auth from the NASe user to the remote machine (no password).
- `rsync` installed on the remote.
- Sufficient storage on the remote.

#### Option B — Rclone to cloud storage (S3, Backblaze B2, etc.)

Install `rclone`, configure a cloud backend, and add a cron job or systemd
timer that runs `rclone sync` nightly. Backblaze B2 is ~$6/TB/month.

This is outside NASe's current sync module scope — it would be a standalone
systemd timer, not a `sync_jobs` entry (rsync does not natively support cloud
protocols).

#### Option C — Encrypted external drive kept off-site

Periodically (monthly) plug in an encrypted external drive, run a manual sync,
then take it off-site. Low-tech but reliable. Use `nase sync <job>` targeting
the external drive for the duration.

### Recommended starting point

Option A if another Tailscale machine is available. Option B (Backblaze B2 +
rclone) otherwise — it costs ~$3/month for 500 GB of photos.

**Done when**: at least Photo_albums has a copy at a physically separate
location that is updated at least weekly.

---

## Implementation order summary

| # | Item | Type | Effort | Risk addressed |
|---|------|------|--------|----------------|
| 1 | Verify notifications work | Operational | 5 min | Silent failure |
| 2 | Atomic config.yaml writes | Code | 15 min | Corruption on power loss |
| 3 | Semantic validation on save | Code | 30 min | Invalid config written silently |
| 4 | Verify trash mechanism manually | Operational | 20 min | Assumed-working safety net |
| 5 | Enable trash on cfg-archive jobs | Config | 5 min | Config history deleted silently |
| 6 | SMART attribute monitoring | Code | 45 min | Silent drive degradation |
| 7 | `--checksum` on photo/video jobs | Config | 10 min | Silent bit-rot |
| 8 | Off-site backup | Structural | 1–4 hrs | Single location failure |
