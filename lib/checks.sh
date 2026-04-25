#!/usr/bin/env bash
# lib/checks.sh — pre-flight sanity checks.
# Source this file; do not execute directly.
# Requires: lib/log.sh and lib/config.sh already sourced.

check_root() {
    [[ $EUID -eq 0 ]] || die "This script must be run as root (use sudo)."
}

check_tool() {
    local tool="$1"
    command -v "$tool" &>/dev/null || die "Required tool not found: $tool — run install.sh first."
}

check_tools() {
    check_tool yq
    check_tool rsync
    check_tool samba
    check_tool hdparm
    check_tool smartctl
    check_tool systemd-escape
}

check_config_file() {
    [[ -f "$CONFIG_FILE" ]] || die "Config file not found: $CONFIG_FILE"
}

check_env_file() {
    local env_file="${REPO_ROOT}/.env"
    [[ -f "$env_file" ]] || die ".env file not found. Copy .env.example to .env and fill in your secrets."
}

# Warn (not fatal) for any active drive UUID that does not yet appear under
# /dev/disk/by-uuid/.  Inactive drives are silently skipped.
check_drive_uuids() {
    local n
    n=$(config_len '.drives')
    for i in $(seq 0 $((n - 1))); do
        local name uuid active
        name=$(config_idx '.drives' "$i" '.name')
        active=$(config_idx '.drives' "$i" '.active')
        [[ "$active" != "false" ]] || continue
        uuid=$(config_idx '.drives' "$i" '.uuid')
        if [[ ! -e "/dev/disk/by-uuid/${uuid}" ]]; then
            log_warn "Drive '${name}' (UUID ${uuid}) not found under /dev/disk/by-uuid/ — is it connected?"
        fi
    done
}

# Run all pre-flight checks appropriate before applying config.
preflight_checks() {
    check_root
    check_config_file
    check_env_file
}
