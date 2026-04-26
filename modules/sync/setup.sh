#!/usr/bin/env bash
# modules/sync/setup.sh
# Generates a systemd service + timer pair for every sync_job in config.yaml.
# Old units for jobs that no longer exist in config are removed.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SYSTEMD_DIR="/etc/systemd/system"
SYNC_SCRIPT="${REPO_ROOT}/modules/sync/sync.sh"
UNIT_PREFIX="nase-sync-"

n=$(config_len '.sync_jobs')
log_info "Configuring ${n} sync job(s)..."

declare -a configured_names=()

for i in $(seq 0 $((n - 1))); do
    job_name=$(config_idx '.sync_jobs' "$i" '.name')
    schedule=$(config_idx  '.sync_jobs' "$i" '.schedule')

    configured_names+=("$job_name")
    unit_base="${UNIT_PREFIX}${job_name}"

    log_info "  Job '${job_name}': schedule='${schedule}'"

    # ── Service unit ───────────────────────────────────────────────────────────
    service_file="${SYSTEMD_DIR}/${unit_base}.service"
    service_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe sync: ${job_name}
After=network.target $(
    # Add mount unit dependencies for all drives
    m=$(config_len '.drives')
    for j in $(seq 0 $((m - 1))); do
        mp=$(config_idx '.drives' "$j" '.mountpoint')
        echo -n "$(systemd-escape --path "$mp").mount "
    done
)

[Service]
Type=oneshot
ExecStart=${SYNC_SCRIPT} ${job_name}
# Ensure REPO_ROOT is available inside the service
Environment=REPO_ROOT=${REPO_ROOT}
# Nice sync jobs to avoid starving interactive access
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

[Install]
WantedBy=multi-user.target"

    if [[ ! -f "$service_file" ]] || ! diff -q <(echo "$service_content") "$service_file" &>/dev/null; then
        log_info "    Writing ${service_file}"
        echo "$service_content" > "$service_file"
    fi

    # ── Timer unit ─────────────────────────────────────────────────────────────
    timer_file="${SYSTEMD_DIR}/${unit_base}.timer"
    timer_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe sync timer: ${job_name}

[Timer]
OnCalendar=${schedule}
# Run missed firings on next boot (e.g. Pi was off at scheduled time)
Persistent=true
Unit=${unit_base}.service

[Install]
WantedBy=timers.target"

    if [[ ! -f "$timer_file" ]] || ! diff -q <(echo "$timer_content") "$timer_file" &>/dev/null; then
        log_info "    Writing ${timer_file}"
        echo "$timer_content" > "$timer_file"
    fi

    systemctl daemon-reload
    systemctl enable --now "${unit_base}.timer"
    log_ok "  Timer ${unit_base}.timer enabled."
done

# ── Remove units for jobs that were deleted from config ───────────────────────
for existing_unit in "${SYSTEMD_DIR}/${UNIT_PREFIX}"*.timer; do
    [[ -f "$existing_unit" ]] || continue
    existing_name="${existing_unit%.timer}"
    existing_name="${existing_name##*${UNIT_PREFIX}}"

    still_configured=false
    for cname in "${configured_names[@]}"; do
        [[ "$existing_name" == "$cname" ]] && still_configured=true && break
    done

    if [[ "$still_configured" == "false" ]]; then
        unit_base="${UNIT_PREFIX}${existing_name}"
        log_warn "Removing obsolete unit: ${unit_base}"
        systemctl disable --now "${unit_base}.timer" 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/${unit_base}.service" "${SYSTEMD_DIR}/${unit_base}.timer"
    fi
done

systemctl daemon-reload
log_ok "Sync jobs configured."

# ── Ensure trash directories exist ────────────────────────────────────────────
# Creates the .trash root on each backup drive that needs one.
# If the drive is mounted read-only, remounts rw briefly, creates the dir, then
# remounts ro again. Skips drives that are not yet connected.
declare -A _seen_trash_mounts=()

for i in $(seq 0 $((n - 1))); do
    trash_enabled=$(config_idx '.sync_jobs' "$i" '.trash.enabled')
    [[ "$trash_enabled" == "true" ]] || continue

    trash_path=$(config_idx '.sync_jobs' "$i" '.trash.path')
    [[ -n "$trash_path" ]] || continue

    # Find the mountpoint that owns this trash path.
    trash_mount=$(findmnt --target "$trash_path" --output TARGET --noheadings --first-only 2>/dev/null || true)
    if [[ -z "$trash_mount" ]]; then
        log_info "  Trash dir '${trash_path}': drive not mounted — skipping."
        continue
    fi

    # Only act once per mountpoint even if multiple jobs share the same trash root.
    if [[ -n "${_seen_trash_mounts[$trash_mount]+x}" ]]; then
        continue
    fi
    _seen_trash_mounts["$trash_mount"]=1

    if [[ -d "$trash_path" ]]; then
        log_info "  Trash dir '${trash_path}': already exists."
        continue
    fi

    is_ro=$(findmnt --target "$trash_mount" --output OPTIONS --noheadings --first-only \
        | grep -qw ro && echo true || echo false)

    if [[ "$is_ro" == "true" ]]; then
        log_info "  Trash dir '${trash_path}': remounting ${trash_mount} rw to create directory..."
        mount -o remount,rw "$trash_mount"
        mkdir -p "$trash_path"
        mount -o remount,ro "$trash_mount"
    else
        mkdir -p "$trash_path"
    fi
    log_ok "  Trash dir created: ${trash_path}"
done
