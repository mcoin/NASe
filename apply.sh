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

# ── Archive config.yaml to primary drive ─────────────────────────────────────
log_section "Config archive"
_NASE_ARCHIVE="/mnt/primary/NASe"
if mountpoint -q /mnt/primary 2>/dev/null; then
    mkdir -p "$_NASE_ARCHIVE"
    _current_hash=$(sha256sum "${REPO_ROOT}/config.yaml" | cut -d' ' -f1)
    if [[ ! -f "${_NASE_ARCHIVE}/config.yaml" ]] \
            || [[ "$(sha256sum "${_NASE_ARCHIVE}/config.yaml" | cut -d' ' -f1)" != "$_current_hash" ]]; then
        _ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
        mkdir -p "${_NASE_ARCHIVE}/${_ts}"
        cp "${REPO_ROOT}/config.yaml" "${_NASE_ARCHIVE}/${_ts}/config.yaml"
        cp "${REPO_ROOT}/config.yaml" "${_NASE_ARCHIVE}/config.yaml"
        log_ok "Config archived → ${_NASE_ARCHIVE}/${_ts}/"
    else
        log_info "Config unchanged since last archive."
    fi
    # Prune history directories older than 90 days
    while IFS= read -r _old; do
        rm -rf "$_old"
        log_info "Pruned old config version: $(basename "$_old")"
    done < <(find "$_NASE_ARCHIVE" -maxdepth 1 -mindepth 1 -type d -mtime +90 2>/dev/null)
else
    log_warn "Primary drive not mounted — skipping config archive."
fi

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
