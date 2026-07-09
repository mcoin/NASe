#!/usr/bin/env bash
# modules/primary-watch/setup.sh
# Installs nase-primary-watch.service — the primary drive event recorder.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"

SERVICE_FILE="/etc/systemd/system/nase-primary-watch.service"
RECORD_SCRIPT="${REPO_ROOT}/modules/primary-watch/record.sh"

service_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe primary drive file event recorder
After=network.target

[Service]
Type=simple
ExecStart=${RECORD_SCRIPT}
Environment=REPO_ROOT=${REPO_ROOT}
Restart=always
RestartSec=30
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target"

if [[ ! -f "$SERVICE_FILE" ]] || ! diff -q <(echo "$service_content") "$SERVICE_FILE" &>/dev/null; then
    log_info "Writing ${SERVICE_FILE}"
    echo "$service_content" > "$SERVICE_FILE"
    systemctl daemon-reload
fi

systemctl enable nase-primary-watch.service
log_info "Restarting nase-primary-watch.service..."
systemctl restart nase-primary-watch.service
log_ok "Primary watch service installed and started."
