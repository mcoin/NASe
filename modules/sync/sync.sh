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

source_path=$(config_idx '.sync_jobs' "$job_index" '.source')
dest_path=$(config_idx   '.sync_jobs' "$job_index" '.dest')
rsync_flags=$(config_idx '.sync_jobs' "$job_index" '.rsync_flags')
on_failure=$(config_idx  '.sync_jobs' "$job_index" '.on_failure')

# ── Pre-flight: verify source and destination are accessible ─────────────────
if [[ ! -d "$source_path" ]]; then
    msg="Sync job '${JOB_NAME}': source path '${source_path}' does not exist or is not mounted."
    log_error "$msg"
    if [[ "$on_failure" == "notify" ]]; then
        "${REPO_ROOT}/modules/sync/notify.sh" \
            "NASe sync failed: ${JOB_NAME} on $(hostname)" "$msg" || true
    fi
    exit 1
fi

dest_parent=$(dirname "$dest_path")
if [[ ! -d "$dest_parent" ]]; then
    msg="Sync job '${JOB_NAME}': destination parent '${dest_parent}' does not exist or is not mounted."
    log_error "$msg"
    if [[ "$on_failure" == "notify" ]]; then
        "${REPO_ROOT}/modules/sync/notify.sh" \
            "NASe sync failed: ${JOB_NAME} on $(hostname)" "$msg" || true
    fi
    exit 1
fi

mkdir -p "$dest_path"

# ── Run rsync ─────────────────────────────────────────────────────────────────
START_TIME=$(date +%s)
log_info "Starting sync job '${JOB_NAME}': ${source_path} → ${dest_path}"
log_info "Flags: ${rsync_flags}"

RSYNC_LOG="/var/log/nas-sync-${JOB_NAME}.log"

# shellcheck disable=SC2086
# rsync_flags is intentionally word-split here
if rsync $rsync_flags \
        --log-file="$RSYNC_LOG" \
        "$source_path" "$dest_path"; then
    END_TIME=$(date +%s)
    ELAPSED=$(( END_TIME - START_TIME ))
    log_ok "Sync job '${JOB_NAME}' completed in ${ELAPSED}s."
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
