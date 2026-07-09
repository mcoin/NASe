#!/usr/bin/env bash
# modules/primary-watch/setup.sh
# Installs nase-primary-watch.service — the primary drive event recorder.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"

SERVICE_FILE="/etc/systemd/system/nase-primary-watch.service"
RECORD_SCRIPT="${REPO_ROOT}/modules/primary-watch/record.sh"

# inotifywait needs one watch per directory under /mnt/primary. The kernel
# default (usually ~30k under Linux 6.x, i.e. fs.inotify.max_user_watches) is
# nowhere near enough for a NAS-sized tree, so raise it well above what a
# multi-TB drive full of directories is likely to need.
SYSCTL_FILE="/etc/sysctl.d/99-nase-inotify.conf"
SYSCTL_WATCHES=1048576

sysctl_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
# Raised so modules/primary-watch/record.sh can recursively watch
# /mnt/primary without hitting the kernel default watch limit.
fs.inotify.max_user_watches=${SYSCTL_WATCHES}"

if [[ ! -f "$SYSCTL_FILE" ]] || ! diff -q <(echo "$sysctl_content") "$SYSCTL_FILE" &>/dev/null; then
    log_info "Writing ${SYSCTL_FILE}"
    echo "$sysctl_content" > "$SYSCTL_FILE"
    sysctl -p "$SYSCTL_FILE" >/dev/null
    log_ok "fs.inotify.max_user_watches raised to ${SYSCTL_WATCHES}."
fi

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
