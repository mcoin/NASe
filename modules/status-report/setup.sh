#!/usr/bin/env bash
# modules/status-report/setup.sh
# Creates (or disables) the systemd service + timer for the periodic status report.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
REPORT_SCRIPT="${REPO_ROOT}/modules/status-report/report.sh"
UNIT_BASE="nase-status-report"

enabled=$(config_get '.status_report.enabled // "true"')
schedule=$(config_get '.status_report.schedule // "Sat *-*-* 03:00:00"')

if [[ "$enabled" != "true" ]]; then
    if systemctl is-enabled --quiet "${UNIT_BASE}.timer" 2>/dev/null; then
        log_info "Status report disabled — stopping and disabling timer..."
        systemctl disable --now "${UNIT_BASE}.timer" 2>/dev/null || true
    fi
    log_info "Status report is disabled."
    exit 0
fi

log_info "Configuring status report (schedule='${schedule}')..."

# ── Service unit ──────────────────────────────────────────────────────────────
service_file="${SYSTEMD_DIR}/${UNIT_BASE}.service"
service_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe status report
After=network.target

[Service]
Type=oneshot
ExecStart=${REPORT_SCRIPT}
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
Description=NASe status report timer

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
log_ok "Status report timer enabled (${schedule})."
