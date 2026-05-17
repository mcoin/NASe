#!/usr/bin/env bash
# modules/config-archive/setup.sh
# Creates a systemd service + timer for the config archive job.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
ARCHIVE_SCRIPT="${REPO_ROOT}/modules/config-archive/archive.sh"
UNIT_BASE="nase-config-archive"

schedule=$(config_get '.config_archive.schedule // "*-*-* 00:00:00"')

log_info "Configuring config archive (schedule='${schedule}')..."

# Build drive mount dependencies (same pattern as sync/setup.sh)
drive_deps=""
m=$(config_len '.drives')
for j in $(seq 0 $((m - 1))); do
    mp=$(config_idx '.drives' "$j" '.mountpoint')
    drive_deps+="$(systemd-escape --path "$mp").mount "
done

# ── Service unit ──────────────────────────────────────────────────────────────
service_file="${SYSTEMD_DIR}/${UNIT_BASE}.service"
service_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe config archive
After=network.target ${drive_deps}

[Service]
Type=oneshot
ExecStart=${ARCHIVE_SCRIPT}
Environment=REPO_ROOT=${REPO_ROOT}
EnvironmentFile=-${REPO_ROOT}/.env

[Install]
WantedBy=multi-user.target"

if [[ ! -f "$service_file" ]] || ! diff -q <(echo "$service_content") "$service_file" &>/dev/null; then
    log_info "  Writing ${service_file}"
    echo "$service_content" > "$service_file"
fi

# ── Timer unit ────────────────────────────────────────────────────────────────
timer_file="${SYSTEMD_DIR}/${UNIT_BASE}.timer"
timer_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe config archive timer

[Timer]
OnCalendar=${schedule}
Persistent=true
Unit=${UNIT_BASE}.service

[Install]
WantedBy=timers.target"

if [[ ! -f "$timer_file" ]] || ! diff -q <(echo "$timer_content") "$timer_file" &>/dev/null; then
    log_info "  Writing ${timer_file}"
    echo "$timer_content" > "$timer_file"
fi

systemctl daemon-reload
systemctl enable --now "${UNIT_BASE}.timer"
log_ok "Config archive timer enabled (${schedule})."
