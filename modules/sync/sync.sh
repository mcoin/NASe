#!/usr/bin/env bash
# modules/sync/sync.sh
# Runs an rsync job defined in config.yaml by name.
# Usage (called by systemd):  sync.sh <job-name>
#        or manually:         sudo /opt/nase/modules/sync/sync.sh <job-name>
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/guards.sh"

JOB_NAME="${1:-}"
[[ -n "$JOB_NAME" ]] || die "Usage: sync.sh <job-name>"

# ── Find the job in config ────────────────────────────────────────────────────
n=$(config_len '.sync_jobs')
job_index=-1

for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.sync_jobs' "$i" '.name')
    if [[ "$name" == "$JOB_NAME" ]]; then
        job_index=$i
        break
    fi
done

[[ "$job_index" -ge 0 ]] || die "Sync job '${JOB_NAME}' not found in config.yaml."

source_path=$(config_idx      '.sync_jobs' "$job_index" '.source')
dest_path=$(config_idx        '.sync_jobs' "$job_index" '.dest')
rsync_flags=$(config_idx      '.sync_jobs' "$job_index" '.rsync_flags')
on_failure=$(config_idx       '.sync_jobs' "$job_index" '.on_failure')
force_sync_days=$(config_idx  '.sync_jobs' "$job_index" '.force_sync_days')
force_sync_days="${force_sync_days:-7}"
trash_enabled=$(config_idx    '.sync_jobs' "$job_index" '.trash.enabled')
trash_path=$(config_idx       '.sync_jobs' "$job_index" '.trash.path')
trash_days=$(config_idx       '.sync_jobs' "$job_index" '.trash.retention_days')

# ── Pre-flight: verify source and destination are accessible ─────────────────
# A missing path means a drive is inactive or temporarily disconnected — an
# expected condition, not a failure.  Skip silently (exit 0) so that timers
# don't generate spurious notifications every time they fire.
# Notifications are reserved for rsync runs that actually start and then fail.
if [[ ! -d "$source_path" ]]; then
    log_info "Sync job '${JOB_NAME}': source '${source_path}' not available — skipping."
    exit 0
fi

dest_parent=$(dirname "$dest_path")
if [[ ! -d "$dest_parent" ]]; then
    log_info "Sync job '${JOB_NAME}': destination '${dest_parent}' not available — skipping."
    exit 0
fi

# Guard against syncing from/to the root filesystem (SD card).
# This catches two scenarios:
#   1. The drive is mounted and findmnt reports the root device.
#   2. The drive is unmounted but its directory exists on the SD card —
#      in this case findmnt returns empty, which we also treat as unsafe.
# Without this guard, rsync --delete on an empty source would wipe the backup.
root_dev=$(get_mount_device /)
is_safe_mount_path "Sync job '${JOB_NAME}': source" "$source_path" "$root_dev" \
    || exit 0
is_safe_mount_path "Sync job '${JOB_NAME}': destination" "$dest_parent" "$root_dev" \
    || exit 0

# ── Skip if source is unchanged since last sync ───────────────────────────────
# Avoids spinning up the backup drive when nothing has changed on the source.
# Checked here, before any interaction with the destination drive.
# The stamp file is touched after each successful rsync run.
# On the first run (no stamp file), rsync always proceeds.
STAMP_DIR="/var/lib/nase"
STAMP_FILE="${STAMP_DIR}/sync-${JOB_NAME}.stamp"

if [[ -f "$STAMP_FILE" ]]; then
    # -print -quit exits on the first match — fast even on large trees
    changed=$(find "$source_path" -newer "$STAMP_FILE" -print -quit 2>/dev/null)
    if [[ -z "$changed" ]]; then
        # No changes detected — check whether the forced sync interval has elapsed
        force_sync=false
        if [[ "$force_sync_days" -gt 0 ]]; then
            stamp_mtime=$(stat -c %Y "$STAMP_FILE" 2>/dev/null || echo "0")
            stamp_age_days=$(( ( $(date +%s) - stamp_mtime ) / 86400 ))
            # Guard against negative age (e.g. clock correction)
            [[ $stamp_age_days -lt 0 ]] && stamp_age_days=0
            if [[ "$stamp_age_days" -ge "$force_sync_days" ]]; then
                force_sync=true
                log_info "Sync job '${JOB_NAME}': no changes detected, but ${stamp_age_days}d since last sync (threshold: ${force_sync_days}d) — forcing sync."
            fi
        fi
        if [[ "$force_sync" == "false" ]]; then
            log_info "Sync job '${JOB_NAME}': no changes since last sync — skipping."
            exit 0
        fi
    fi
fi

# ── Remount destination read-write if needed ─────────────────────────────────
# Find the mountpoint of the destination and check if it is mounted read-only.
dest_mount=$(findmnt --target "$dest_parent" --output TARGET --noheadings --first-only)
[[ -n "$dest_mount" ]] || die "Could not determine mountpoint for '${dest_parent}'."

dest_is_ro=$(findmnt --target "$dest_parent" --output OPTIONS --noheadings --first-only \
    | grep -qw ro && echo true || echo false)

if [[ "$dest_is_ro" == "true" ]]; then
    log_info "Remounting ${dest_mount} read-write for sync..."
    mount -o remount,rw "$dest_mount"
    # Ensure we remount read-only again when the script exits, even on failure
    trap 'log_info "Remounting ${dest_mount} read-only..."; mount -o remount,ro "${dest_mount}"' EXIT
fi

mkdir -p "$dest_path"

# ── Trash setup ───────────────────────────────────────────────────────────────
# When trash is enabled, files deleted from the destination are moved to a
# timestamped subdirectory rather than being permanently removed.
# rsync creates --backup-dir automatically and only when it has files to
# put there — so no pre-creation, and no empty directories to clean up.
EXTRA_FLAGS=""
TRASH_RUN_DIR=""
if [[ "$trash_enabled" == "true" ]] && [[ -n "$trash_path" ]]; then
    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    TRASH_RUN_DIR="${trash_path}/${TIMESTAMP}/${JOB_NAME}"
    EXTRA_FLAGS="--backup --backup-dir=${TRASH_RUN_DIR}"
    log_info "Trash enabled: deleted files will go to ${TRASH_RUN_DIR}"
fi

# ── Run rsync ─────────────────────────────────────────────────────────────────
START_TIME=$(date +%s)
log_info "Starting sync job '${JOB_NAME}': ${source_path} → ${dest_path}"
log_info "Flags: ${rsync_flags}${EXTRA_FLAGS:+ ${EXTRA_FLAGS}}"

RSYNC_LOG="/var/log/nase-sync-${JOB_NAME}.log"
# Temp file to capture per-file rsync output for central log.
# Uses --out-format with a unique prefix (NXFR) to distinguish file entries
# from rsync's stats summary lines which also go to stdout.
# Set up early so the EXIT trap can always clean it up.
RSYNC_XFER_TMP=$(mktemp)
if [[ "$dest_is_ro" == "true" ]]; then
    # Override the earlier trap to include temp file cleanup alongside the remount
    trap 'rm -f "$RSYNC_XFER_TMP"; log_info "Remounting ${dest_mount} read-only..."; mount -o remount,ro "${dest_mount}"' EXIT
else
    trap 'rm -f "$RSYNC_XFER_TMP"' EXIT
fi

# macOS writes AppleDouble resource fork files (._*) and .DS_Store files to
# SMB shares automatically.  They are meaningless on Linux and are excluded
# from every sync so they never accumulate on the backup or trigger false
# trash entries.
MACOS_EXCLUDES=(
    "--exclude=._*"
    "--exclude=.DS_Store"
)

# shellcheck disable=SC2086
# rsync_flags and EXTRA_FLAGS are intentionally word-split here
if rsync $rsync_flags $EXTRA_FLAGS \
        "${MACOS_EXCLUDES[@]}" \
        --out-format='NXFR %n' \
        --log-file="$RSYNC_LOG" \
        "$source_path" "$dest_path" | tee "$RSYNC_XFER_TMP"; then
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    log_ok "Sync job '${JOB_NAME}' completed in ${ELAPSED}s."

    # Log transferred files to the central log
    transferred=$(grep '^NXFR ' "$RSYNC_XFER_TMP" | sed 's/^NXFR //' || true)
    transferred_count=$(echo "$transferred" | grep -c . || true)
    if [[ "$transferred_count" -gt 0 ]]; then
        _log_to_file "INFO " "${transferred_count} file(s) transferred:"
        while IFS= read -r f; do
            [[ -n "$f" ]] && _log_to_file "INFO " "  synced:  ${f}"
        done <<< "$transferred"
    fi

    # Log files moved to trash this run
    if [[ -n "$TRASH_RUN_DIR" ]] && [[ -d "$TRASH_RUN_DIR" ]]; then
        trash_count=$(find "$TRASH_RUN_DIR" -type f | wc -l | tr -d ' ')
        if [[ "$trash_count" -gt 0 ]]; then
            log_info "Trash: ${trash_count} file(s) moved to ${TRASH_RUN_DIR}"
            _log_to_file "INFO " "${trash_count} file(s) moved to trash:"
            find "$TRASH_RUN_DIR" -type f -printf '%P\n' 2>/dev/null | sort \
                | while IFS= read -r f; do
                    _log_to_file "INFO " "  trashed: ${f}"
                done
        fi
    fi

    # Purge timestamp directories under the shared trash root older than
    # retention_days (top-level dirs are named by timestamp, one level up
    # from the per-job subdirectory).
    if [[ "$trash_enabled" == "true" ]] && [[ -n "$trash_path" ]] \
            && [[ -n "$trash_days" ]] && [[ "$trash_days" -gt 0 ]]; then
        log_info "Purging trash older than ${trash_days} days..."
        find "$trash_path" -mindepth 1 -maxdepth 1 -type d -mtime +"$trash_days" \
            -exec rm -rf {} \;
    fi

    # Record successful sync time for change detection on next run
    mkdir -p "$STAMP_DIR"
    touch "$STAMP_FILE"
else
    RSYNC_EXIT=$?
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    msg="Sync job '${JOB_NAME}' failed after ${ELAPSED}s (rsync exit ${RSYNC_EXIT})."$'\n'"See ${RSYNC_LOG} for details."
    log_error "$msg"

    if [[ "$on_failure" == "notify" ]]; then
        # Include last 20 lines of rsync log in notification
        tail_output=$(tail -n 20 "$RSYNC_LOG" 2>/dev/null || echo "(log unavailable)")
        full_msg="${msg}"$'\n\n'"Last log lines:"$'\n'"${tail_output}"
        "${REPO_ROOT}/modules/sync/notify.sh" \
            "NASe sync failed: ${JOB_NAME} on $(hostname)" "$full_msg" || true
    fi
    exit "$RSYNC_EXIT"
fi
