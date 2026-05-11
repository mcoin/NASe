#!/usr/bin/env bash
# modules/watch/setup.sh
# Creates or removes nase-watch.service based on the file_watch config.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SERVICE_FILE="/etc/systemd/system/nase-watch.service"
WATCH_SCRIPT="${REPO_ROOT}/modules/watch/watch.sh"

count=$(config_len '.file_watch')

if [[ "$count" -eq 0 ]]; then
    if [[ -f "$SERVICE_FILE" ]]; then
        log_info "No file_watch entries — removing nase-watch.service."
        systemctl disable --now nase-watch.service 2>/dev/null || true
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    else
        log_info "No file_watch entries — skipping."
    fi
    exit 0
fi

log_info "Configuring file watcher (${count} path(s))..."

service_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe file watch notifier
After=network.target

[Service]
Type=simple
ExecStart=${WATCH_SCRIPT}
Environment=REPO_ROOT=${REPO_ROOT}
EnvironmentFile=-${REPO_ROOT}/.env
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target"

if [[ ! -f "$SERVICE_FILE" ]] || ! diff -q <(echo "$service_content") "$SERVICE_FILE" &>/dev/null; then
    log_info "Writing ${SERVICE_FILE}"
    echo "$service_content" > "$SERVICE_FILE"
    systemctl daemon-reload
fi

systemctl enable nase-watch.service
log_info "Restarting nase-watch.service..."
systemctl restart nase-watch.service
