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
run_module integrity
run_module config-archive

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

run_module watch
run_module primary-watch
run_module status-report

# ── Install repo-provided systemd units ──────────────────────────────────────
# Substitute __REPO_ROOT__ in unit files so they work regardless of clone path.
log_section "Systemd units"
for unit_src in "${REPO_ROOT}/systemd/"*; do
    unit_name=$(basename "$unit_src")
    unit_dest="/etc/systemd/system/${unit_name}"
    rendered=$(sed "s#__REPO_ROOT__#${REPO_ROOT}#g" "$unit_src")
    if [[ ! -f "$unit_dest" ]] || ! diff -q <(echo "$rendered") "$unit_dest" &>/dev/null; then
        log_info "Installing unit: ${unit_name}"
        echo "$rendered" > "$unit_dest"
    fi
done

systemctl daemon-reload
systemctl enable --now nase-monitor.service nase-monitor.timer
# Enabled but not started: the drives module has already applied spindown in
# this same run. This unit exists to re-apply it at boot, where nothing else
# does (backlog #32).
systemctl enable nase-spindown.service
# Ordered teardown of the drives at shutdown (backlog #31). Enabled, not
# started: its ExecStart is a no-op and only its ExecStop does the work.
systemctl enable nase-shutdown.service

# ── systemd drop-ins ─────────────────────────────────────────────────────────
# Both override Raspberry Pi OS / systemd defaults that made the 2026-09-05
# shutdown hang undiagnosable and unbounded (backlog #31).
log_section "systemd drop-ins"
install_dropin() {
    local src="$1" dest="$2" reload="$3"
    mkdir -p "$(dirname "$dest")"
    if [[ ! -f "$dest" ]] || ! diff -q "$src" "$dest" &>/dev/null; then
        log_info "Installing ${dest}"
        cp "$src" "$dest"
        chmod 644 "$dest"
        eval "$reload"
    fi
}
install_dropin "${REPO_ROOT}/config/journald-nase.conf" \
    /etc/systemd/journald.conf.d/50-nase.conf \
    'systemctl restart systemd-journald && journalctl --flush || log_warn "  Could not switch the journal to persistent storage"'
install_dropin "${REPO_ROOT}/config/system-nase.conf" \
    /etc/systemd/system.conf.d/50-nase.conf \
    'systemctl daemon-reexec || log_warn "  Could not re-exec systemd"'
log_ok "Journal is persistent (200M cap); unit stop timeout is 30s."

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
