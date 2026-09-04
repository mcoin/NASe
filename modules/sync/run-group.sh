#!/usr/bin/env bash
# modules/sync/run-group.sh <schedule-slug>
# Runs every sync job sharing one schedule, in config order, one at a time.
#
# Why this exists (backlog #4, phase 2 option C): nine timers all firing at
# 03:00 started nine jobs in parallel, which made wake attribution useless.
# modules/drives/spin_sample.sh asks "which sync unit ran in the window before
# the drive woke?" — with nine units starting in the same second the answer was
# always whichever job happened to be first in config.yaml, regardless of which
# one actually spun the platter. Running them in sequence gives each job a
# distinct ExecMainStartTimestamp, so "which job was running when the drive
# woke" becomes a question with a real answer.
#
# Jobs are started through their own systemd units rather than by calling
# sync.sh directly, precisely so those per-job timestamps still exist. Losing
# them would trade one attribution problem for another.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
export REPO_ROOT

source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

slug="${1:?Usage: run-group.sh <schedule-slug>}"

# Same slug derivation as modules/sync/setup.sh — kept in lib/config.sh so the
# writer and the runner cannot drift apart.
n=$(config_len '.sync_jobs')
jobs=()
for i in $(seq 0 $((n - 1))); do
    job_schedule=$(config_idx '.sync_jobs' "$i" '.schedule')
    [[ "$(schedule_slug "$job_schedule")" == "$slug" ]] || continue
    jobs+=("$(config_idx '.sync_jobs' "$i" '.name')")
done

if [[ ${#jobs[@]} -eq 0 ]]; then
    # Not an error: the group's timer can outlive a config edit that moved or
    # removed its last job, until the next apply.sh cleans the unit up.
    log_warn "Sync group '${slug}': no jobs configured with this schedule — nothing to do."
    exit 0
fi

log_info "Sync group '${slug}': running ${#jobs[@]} job(s) in sequence: ${jobs[*]}"

# ── Run ledger, for wake attribution ─────────────────────────────────────────
# modules/drives/spin_sample.sh used to ask systemd when each sync unit last
# ran. That worked only because every job had its own .timer holding a
# reference to it: a Type=oneshot unit with nothing referencing it is unloaded
# the moment it exits, and systemctl show then reports *every* timestamp as
# empty. Removing the per-job timers (the point of this change) therefore also
# removed the evidence attribution was built on.
#
# So record it here instead. This runner knows exactly which job it started and
# when, which makes the ledger an authoritative record rather than an inference
# from whatever systemd still happens to remember.
RUN_LOG="${NASE_STAMP_DIR:-/var/lib/nase}/sync-runs.log"
RUN_LOG_KEEP=2000

ledger() {
    printf '%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" >> "$RUN_LOG" 2>/dev/null || true
}

mkdir -p "$(dirname "$RUN_LOG")" 2>/dev/null || true

failed=()
for job in "${jobs[@]}"; do
    unit="nase-sync-${job}.service"
    ledger "$job" start
    # --wait blocks until the oneshot finishes, which is what serialises the
    # group. A failing job must not stop the ones behind it: the drives are
    # already awake by then, so skipping the rest would waste the spin-up and
    # silently leave backups stale.
    if systemctl start --wait "$unit"; then
        ledger "$job" end
        log_ok "Sync group '${slug}': ${job} completed."
    else
        ledger "$job" fail
        log_error "Sync group '${slug}': ${job} failed — continuing with the rest."
        failed+=("$job")
    fi
done

# Trim in place so the ledger cannot grow without bound. Truncate-and-rewrite
# rather than mv, so anything holding the path keeps reading the same file.
if [[ -f "$RUN_LOG" ]] && (( $(wc -l < "$RUN_LOG") > RUN_LOG_KEEP )); then
    trimmed=$(tail -n "$RUN_LOG_KEEP" "$RUN_LOG") && printf '%s\n' "$trimmed" > "$RUN_LOG"
fi

if [[ ${#failed[@]} -gt 0 ]]; then
    log_error "Sync group '${slug}': ${#failed[@]} of ${#jobs[@]} job(s) failed: ${failed[*]}"
    exit 1
fi

log_ok "Sync group '${slug}': all ${#jobs[@]} job(s) completed."
