#!/usr/bin/env bash
# modules/web/setup.sh
# Sets up the NASe web dashboard (FastAPI + HTMX).
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

WEB_DIR="${REPO_ROOT}/modules/web"
VENV_DIR="${WEB_DIR}/venv"
APP_DIR="${WEB_DIR}/app"
WEB_UNIT="/etc/systemd/system/nase-web.service"

port=$(config_get '.services.web.port')
port="${port:-8088}"

# ── Python check ──────────────────────────────────────────────────────────────
command -v python3 &>/dev/null || die "python3 not found — install it with: apt install python3"
python3 -c "import sys; sys.exit(0 if sys.version_info >= (3, 9) else 1)" \
    || die "Python 3.9 or newer is required (found: $(python3 --version))"
log_ok "Python: $(python3 --version)"

# ── Virtual environment ───────────────────────────────────────────────────────
if [[ ! -d "$VENV_DIR" ]]; then
    log_info "Creating virtual environment at ${VENV_DIR}..."
    python3 -m venv "$VENV_DIR"
fi

log_info "Installing/updating Python dependencies..."
"${VENV_DIR}/bin/pip" install --quiet --upgrade pip
"${VENV_DIR}/bin/pip" install --quiet -r "${WEB_DIR}/requirements.txt"
log_ok "Dependencies installed."

# ── Log file permissions ──────────────────────────────────────────────────────
# Sync and monitor services run as root; the web dashboard reads their logs.
# Make the log directory and files world-readable so the service can access them.
LOG_DIR="/var/log/nase"
if [[ -d "$LOG_DIR" ]]; then
    chmod o+rx "$LOG_DIR"
    find "$LOG_DIR" -type f -name "*.log" -exec chmod o+r {} \; 2>/dev/null || true
fi

# ── Systemd service unit ──────────────────────────────────────────────────────
unit_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe web dashboard
After=network.target

[Service]
Type=simple
Environment=REPO_ROOT=${REPO_ROOT}
ExecStart=${VENV_DIR}/bin/uvicorn main:app --host 0.0.0.0 --port ${port}
WorkingDirectory=${APP_DIR}
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target"

if [[ ! -f "$WEB_UNIT" ]] || ! diff -q <(echo "$unit_content") "$WEB_UNIT" &>/dev/null; then
    log_info "Writing ${WEB_UNIT}"
    echo "$unit_content" > "$WEB_UNIT"
    systemctl daemon-reload
fi

systemctl enable --now nase-web.service

# Restart if the app code changed since last apply.
systemctl restart nase-web.service
log_ok "NASe web dashboard running on port ${port}."
log_ok "Access at: http://$(hostname -I | awk '{print $1}'):${port}"
