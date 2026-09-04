#!/usr/bin/env bash
# modules/sync/setup.sh
# Generates a systemd service for every sync_job in config.yaml, plus one
# *group* service+timer pair per distinct schedule that runs those jobs in
# sequence.
#
# Jobs sharing a schedule used to get a timer each, so nine of them fired
# simultaneously at 03:00 and started nine parallel runs. That made wake
# attribution meaningless (see backlog #4 phase 2 option C and the comment at
# the top of run-group.sh). Per-job services are still written — they are what
# gives each job its own start timestamp and its own status — but they are no
# longer individually timed.
#
# Old units for jobs that no longer exist in config are removed, as are the
# per-job timers this scheme replaces.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
SYNC_SCRIPT="${REPO_ROOT}/modules/sync/sync.sh"
GROUP_SCRIPT="${REPO_ROOT}/modules/sync/run-group.sh"
UNIT_PREFIX="nase-sync-"
GROUP_PREFIX="nase-sync-group-"

# systemctl is not available in the unit-writing tests, which only inspect the
# generated files. Guarded so setup.sh stays testable without a live systemd.
_systemctl() {
    if command -v systemctl >/dev/null 2>&1 && [[ -z "${NASE_SKIP_SYSTEMCTL:-}" ]]; then
        systemctl "$@"
    fi
}

n=$(config_len '.sync_jobs')
log_info "Configuring ${n} sync job(s)..."

declare -a configured_names=()
declare -a group_slugs=()
declare -A group_schedule=()

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

    # ── Retire the per-job timer, if this install still has one ────────────────
    # The group timer below now drives this job. Left in place it would fire the
    # job a second time, in parallel, defeating the serialisation.
    old_timer="${SYSTEMD_DIR}/${unit_base}.timer"
    if [[ -f "$old_timer" ]]; then
        log_info "    Retiring per-job timer ${unit_base}.timer (superseded by group timer)"
        _systemctl disable --now "${unit_base}.timer" 2>/dev/null || true
        rm -f "$old_timer"
    fi

    # ── Note the schedule group this job belongs to ────────────────────────────
    slug=$(schedule_slug "$schedule")
    if [[ -z "${group_schedule[$slug]+x}" ]]; then
        group_schedule["$slug"]="$schedule"
        group_slugs+=("$slug")
    elif [[ "${group_schedule[$slug]}" != "$schedule" ]]; then
        # Two different schedules that slugify identically would silently share
        # one timer, and whichever was written last would win. Refuse rather
        # than pick.
        die "Sync jobs have distinct schedules ('${group_schedule[$slug]}' and '${schedule}') that both map to group '${slug}'. Rename one schedule so they differ after slugification."
    fi
done

# ── Group service + timer per distinct schedule ───────────────────────────────
for slug in "${group_slugs[@]}"; do
    schedule="${group_schedule[$slug]}"
    group_base="${GROUP_PREFIX}${slug}"

    log_info "  Group '${slug}': schedule='${schedule}'"

    group_service_file="${SYSTEMD_DIR}/${group_base}.service"
    group_service_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe sync group: ${schedule}
After=network.target $(
    m=$(config_len '.drives')
    for j in $(seq 0 $((m - 1))); do
        mp=$(config_idx '.drives' "$j" '.mountpoint')
        echo -n "$(systemd-escape --path "$mp").mount "
    done
)

[Service]
Type=oneshot
ExecStart=${GROUP_SCRIPT} ${slug}
Environment=REPO_ROOT=${REPO_ROOT}
# The group runner only starts other units and waits; the per-job services
# carry the actual nice/IO settings for the work itself.
Nice=10

[Install]
WantedBy=multi-user.target"

    if [[ ! -f "$group_service_file" ]] || ! diff -q <(echo "$group_service_content") "$group_service_file" &>/dev/null; then
        log_info "    Writing ${group_service_file}"
        echo "$group_service_content" > "$group_service_file"
    fi

    group_timer_file="${SYSTEMD_DIR}/${group_base}.timer"
    group_timer_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe sync group timer: ${schedule}

[Timer]
OnCalendar=${schedule}
# Run missed firings on next boot (e.g. Pi was off at scheduled time)
Persistent=true
Unit=${group_base}.service

[Install]
WantedBy=timers.target"

    if [[ ! -f "$group_timer_file" ]] || ! diff -q <(echo "$group_timer_content") "$group_timer_file" &>/dev/null; then
        log_info "    Writing ${group_timer_file}"
        echo "$group_timer_content" > "$group_timer_file"
    fi

    _systemctl daemon-reload
    _systemctl enable --now "${group_base}.timer"
    log_ok "  Timer ${group_base}.timer enabled."
done

# ── Remove group units whose schedule no longer exists in config ──────────────
for existing_unit in "${SYSTEMD_DIR}/${GROUP_PREFIX}"*.timer; do
    [[ -f "$existing_unit" ]] || continue
    existing_slug="${existing_unit%.timer}"
    existing_slug="${existing_slug##*${GROUP_PREFIX}}"

    still_configured=false
    for slug in "${group_slugs[@]}"; do
        [[ "$existing_slug" == "$slug" ]] && still_configured=true && break
    done

    if [[ "$still_configured" == "false" ]]; then
        group_base="${GROUP_PREFIX}${existing_slug}"
        log_warn "Removing obsolete sync group unit: ${group_base}"
        _systemctl disable --now "${group_base}.timer" 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/${group_base}.service" "${SYSTEMD_DIR}/${group_base}.timer"
    fi
done

# ── Remove units for jobs that were deleted from config ───────────────────────
# Keyed off the .service files now, since per-job timers no longer exist. Group
# units share the nase-sync- prefix, so they have to be skipped explicitly or a
# group would be mistaken for a job that vanished from config and deleted.
for existing_unit in "${SYSTEMD_DIR}/${UNIT_PREFIX}"*.service; do
    [[ -f "$existing_unit" ]] || continue
    existing_name="${existing_unit%.service}"
    existing_name="${existing_name##*${UNIT_PREFIX}}"
    [[ "$existing_name" == group-* ]] && continue

    still_configured=false
    for cname in "${configured_names[@]}"; do
        [[ "$existing_name" == "$cname" ]] && still_configured=true && break
    done

    if [[ "$still_configured" == "false" ]]; then
        unit_base="${UNIT_PREFIX}${existing_name}"
        log_warn "Removing obsolete unit: ${unit_base}"
        _systemctl disable --now "${unit_base}.timer" 2>/dev/null || true
        rm -f "${SYSTEMD_DIR}/${unit_base}.service" "${SYSTEMD_DIR}/${unit_base}.timer"
    fi
done

_systemctl daemon-reload
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
    # Walk up to the nearest existing ancestor: findmnt requires the path to
    # exist on this platform and won't resolve non-existent paths like .trash.
    _trash_lookup="$trash_path"
    while [[ -n "$_trash_lookup" && "$_trash_lookup" != "/" && ! -e "$_trash_lookup" ]]; do
        _trash_lookup="$(dirname "$_trash_lookup")"
    done
    trash_mount=$(findmnt --target "$_trash_lookup" --output TARGET --noheadings --first-only 2>/dev/null || true)
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
        mount -o remount,rw "$trash_mount" \
            || { log_error "  Cannot remount ${trash_mount} rw — skipping trash dir creation."; continue; }
        mkdir -p "$trash_path"
        mount -o remount,ro "$trash_mount" \
            || log_warn "  Failed to remount ${trash_mount} ro — drive left writable."
    else
        mkdir -p "$trash_path"
    fi
    log_ok "  Trash dir created: ${trash_path}"
done
