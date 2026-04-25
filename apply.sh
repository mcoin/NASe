#!/usr/bin/env bash
# apply.sh — idempotent config applier.
# Safe to re-run after any change to config.yaml.
# Run as root:  sudo ./apply.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck source=lib/log.sh
source "${REPO_ROOT}/lib/log.sh"
# shellcheck source=lib/config.sh
source "${REPO_ROOT}/lib/config.sh"
# shellcheck source=lib/checks.sh
source "${REPO_ROOT}/lib/checks.sh"

log_section "NASe — applying configuration"
log_info "Config: ${CONFIG_FILE}"

# ── Pre-flight ────────────────────────────────────────────────────────────────
preflight_checks

# Load secrets from .env
# shellcheck disable=SC1091
source "${REPO_ROOT}/.env"

# Validate config syntax
"${REPO_ROOT}/tests/validate-config.sh"

# Warn about any disconnected drives (non-fatal)
check_drive_uuids

# ── Set hostname ──────────────────────────────────────────────────────────────
HOSTNAME_CFG=$(config_get '.nas.hostname')
if [[ -n "$HOSTNAME_CFG" ]]; then
    log_info "Setting hostname to '${HOSTNAME_CFG}'..."
    hostnamectl set-hostname "$HOSTNAME_CFG"
fi

# ── Modules ───────────────────────────────────────────────────────────────────
run_module() {
    local module="$1"
    log_section "$module"
    bash "${REPO_ROOT}/modules/${module}/setup.sh"
}

run_module drives
run_module samba
run_module sync

if config_bool '.tailscale.enabled'; then
    run_module tailscale
fi

# ── Install repo-provided systemd units ──────────────────────────────────────
log_section "Systemd units"
for unit_src in "${REPO_ROOT}/systemd/"*; do
    unit_name=$(basename "$unit_src")
    unit_dest="/etc/systemd/system/${unit_name}"
    if ! diff -q "$unit_src" "$unit_dest" &>/dev/null; then
        log_info "Installing unit: ${unit_name}"
        cp "$unit_src" "$unit_dest"
    fi
done

systemctl daemon-reload
systemctl enable --now nas-monitor.service nas-monitor.timer

log_section "Done"
log_ok "All modules applied successfully."
log_ok "Run 'systemctl list-timers' to review scheduled jobs."
