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

# Load secrets from .env and export them so child processes (modules) can read them
# shellcheck disable=SC1091
set -a
source "${REPO_ROOT}/.env"
set +a

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

if config_bool '.services.web.enabled'; then
    run_module web
fi

if config_bool '.services.filebrowser.enabled'; then
    run_module filebrowser
fi

# ── Install repo-provided systemd units ──────────────────────────────────────
# Substitute __REPO_ROOT__ in unit files so they work regardless of clone path.
log_section "Systemd units"
for unit_src in "${REPO_ROOT}/systemd/"*; do
    unit_name=$(basename "$unit_src")
    unit_dest="/etc/systemd/system/${unit_name}"
    rendered=$(sed "s|__REPO_ROOT__|${REPO_ROOT}|g" "$unit_src")
    if [[ ! -f "$unit_dest" ]] || ! diff -q <(echo "$rendered") "$unit_dest" &>/dev/null; then
        log_info "Installing unit: ${unit_name}"
        echo "$rendered" > "$unit_dest"
    fi
done

# ── Migrate old nas-* unit names to nase-* ───────────────────────────────────
for old_unit in nas-monitor.service nas-monitor.timer; do
    if systemctl is-enabled --quiet "$old_unit" 2>/dev/null; then
        log_info "Migrating old unit: ${old_unit} → replacing with nase-* equivalent"
        systemctl disable --now "$old_unit" 2>/dev/null || true
        rm -f "/etc/systemd/system/${old_unit}"
    fi
done
for old_timer in /etc/systemd/system/nas-sync-*.timer; do
    [[ -f "$old_timer" ]] || continue
    unit=$(basename "$old_timer")
    log_info "Migrating old unit: ${unit}"
    systemctl disable --now "$unit" 2>/dev/null || true
    rm -f "/etc/systemd/system/${unit%.timer}.service" "$old_timer"
done

systemctl daemon-reload
systemctl enable --now nase-monitor.service nase-monitor.timer

# ── Logrotate ─────────────────────────────────────────────────────────────────
log_section "Logrotate"
LOGROTATE_SRC="${REPO_ROOT}/config/logrotate-nase.conf"
LOGROTATE_DEST="/etc/logrotate.d/nase"
if [[ ! -f "$LOGROTATE_DEST" ]] || ! diff -q "$LOGROTATE_SRC" "$LOGROTATE_DEST" &>/dev/null; then
    log_info "Installing logrotate config: ${LOGROTATE_DEST}"
    cp "$LOGROTATE_SRC" "$LOGROTATE_DEST"
    chmod 644 "$LOGROTATE_DEST"
fi
log_ok "Log rotation configured (${NAS_LOG}, 90 days)."

log_section "Done"
log_ok "All modules applied successfully."
log_ok "Run 'systemctl list-timers' to review scheduled jobs."
