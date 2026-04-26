#!/usr/bin/env bash
# modules/sync/sync.sh
# Runs an rsync job defined in config.yaml by name.
# Usage (called by systemd):  sync.sh <job-name>
#        or manually:         sudo /opt/nas/modules/sync/sync.sh <job-name>
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

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

source_path=$(config_idx    '.sync_jobs' "$job_index" '.source')
dest_path=$(config_idx      '.sync_jobs' "$job_index" '.dest')
rsync_flags=$(config_idx    '.sync_jobs' "$job_index" '.rsync_flags')
on_failure=$(config_idx     '.sync_jobs' "$job_index" '.on_failure')
trash_enabled=$(config_idx  '.sync_jobs' "$job_index" '.trash.enabled')
trash_path=$(config_idx     '.sync_jobs' "$job_index" '.trash.path')
trash_days=$(config_idx     '.sync_jobs' "$job_index" '.trash.retention_days')

# ── Pre-flight: verify source and destination are accessible ─────────────────
# A missing path means a drive is inactive or temporarily disconnected — an
# expected condition, not a failure.  Skip silently (exit 0) so that timers
# don't generate spurious notifications every time they fire.
# Notifications are reserved for rsync runs that actually start and then fail.
if [[ ! -d "$source_path" ]]; then
    log_info "Sync job '${JOB_NAME}': source '${source_path}' not available — skipping."
    exit 0
fi

# Ensure source is not on the root filesystem — if the source drive is
# unmounted but its directory exists, rsync with --delete would wipe the backup.
root_dev=$(findmnt --target / --output SOURCE --noheadings --first-only)
source_dev=$(findmnt --target "$source_path" --output SOURCE --noheadings --first-only)
if [[ "$source_dev" == "$root_dev" ]]; then
    log_info "Sync job '${JOB_NAME}': source '${source_path}' is on the root filesystem — drive not mounted, skipping."
    exit 0
fi

dest_parent=$(dirname "$dest_path")
if [[ ! -d "$dest_parent" ]]; then
    log_info "Sync job '${JOB_NAME}': destination '${dest_parent}' not available — skipping."
    exit 0
fi

# Guard against writing to the root filesystem (SD card) when a destination
# drive is inactive or unmounted but its directory exists on the SD card.
root_dev=$(findmnt --target / --output SOURCE --noheadings --first-only)
dest_dev=$(findmnt --target "$dest_parent" --output SOURCE --noheadings --first-only)
if [[ "$dest_dev" == "$root_dev" ]]; then
    log_info "Sync job '${JOB_NAME}': destination '${dest_parent}' is on the root filesystem — drive not mounted, skipping."
    exit 0
fi

# ── Remount destination read-write if needed ─────────────────────────────────
# Find the mountpoint of the destination and check if it is mounted read-only.
dest_mount=$(findmnt --target "$dest_parent" --output TARGET --noheadings --first-only)
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
# When trash is enabled, deleted/overwritten files are moved to a timestamped
# subdirectory under trash.path instead of being permanently removed.
# rsync --backup combined with --delete moves would-be-deleted files to
# --backup-dir rather than wiping them.
EXTRA_FLAGS=""
if [[ "$trash_enabled" == "true" ]] && [[ -n "$trash_path" ]]; then
    TIMESTAMP=$(date +%Y-%m-%d_%H%M%S)
    TRASH_RUN_DIR="${trash_path}/${TIMESTAMP}/${JOB_NAME}"
    mkdir -p "$TRASH_RUN_DIR"
    EXTRA_FLAGS="--backup --backup-dir=${TRASH_RUN_DIR}"
    log_info "Trash enabled: removed files → ${TRASH_RUN_DIR}"
fi

# ── Run rsync ─────────────────────────────────────────────────────────────────
START_TIME=$(date +%s)
log_info "Starting sync job '${JOB_NAME}': ${source_path} → ${dest_path}"
log_info "Flags: ${rsync_flags}${EXTRA_FLAGS:+ ${EXTRA_FLAGS}}"

RSYNC_LOG="/var/log/nas-sync-${JOB_NAME}.log"

# shellcheck disable=SC2086
# rsync_flags and EXTRA_FLAGS are intentionally word-split here
if rsync $rsync_flags $EXTRA_FLAGS \
        --log-file="$RSYNC_LOG" \
        "$source_path" "$dest_path"; then
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    log_ok "Sync job '${JOB_NAME}' completed in ${ELAPSED}s."

    # Remove empty directories left by rsync inside the trash run dir
    # (-depth ensures children are processed before parents so that
    # directories become empty bottom-up and are all removed in one pass).
    # If everything is empty the run dir itself is removed too — meaning
    # a timestamp folder only exists when files were actually deleted.
    # Clean up empty directories bottom-up. TRASH_RUN_DIR is
    # trash_path/TIMESTAMP/JOB_NAME — also clean the parent timestamp
    # dir if it ends up empty (i.e. no other job deleted anything).
    if [[ -n "${TRASH_RUN_DIR:-}" ]] && [[ -d "$TRASH_RUN_DIR" ]]; then
        find "$TRASH_RUN_DIR" -depth -type d -empty -delete
        TRASH_TIMESTAMP_DIR=$(dirname "$TRASH_RUN_DIR")
        find "$TRASH_TIMESTAMP_DIR" -maxdepth 0 -empty -delete 2>/dev/null || true
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
