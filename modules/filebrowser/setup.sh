#!/usr/bin/env bash
# modules/filebrowser/setup.sh
# Installs and configures filebrowser (https://filebrowser.xyz/).
# Username from config.yaml: services.filebrowser.username
# Password from .env: FILEBROWSER_PASSWORD
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

FB_BIN="/usr/local/bin/filebrowser"
FB_DIR="/etc/filebrowser"
FB_DB="${FB_DIR}/filebrowser.db"
FB_CFG="${FB_DIR}/settings.json"
FB_UNIT="/etc/systemd/system/filebrowser.service"

port=$(config_get '.services.filebrowser.port')
root=$(config_get '.services.filebrowser.root')
base_url=$(config_get '.services.filebrowser.base_url')
fb_user=$(config_get '.services.filebrowser.username')
fb_password="${FILEBROWSER_PASSWORD:-}"

[[ -n "$fb_user" ]]     || die "services.filebrowser.username is not set in config.yaml"
[[ -n "$fb_password" ]] || die "FILEBROWSER_PASSWORD is not set — add it to .env"

# ── Install binary ────────────────────────────────────────────────────────────
install_filebrowser() {
    local arch
    arch=$(dpkg --print-architecture)
    local asset
    case "$arch" in
        arm64) asset="linux-arm64" ;;
        armhf) asset="linux-armv7" ;;
        amd64) asset="linux-amd64" ;;
        *)     die "Unsupported architecture: ${arch}" ;;
    esac

    log_info "Fetching latest filebrowser release info..."
    local latest_version
    latest_version=$(curl -fsSL https://api.github.com/repos/filebrowser/filebrowser/releases/latest \
        | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')
    [[ -n "$latest_version" ]] || die "Could not determine latest filebrowser version from GitHub API."

    local url="https://github.com/filebrowser/filebrowser/releases/download/v${latest_version}/${asset}.tar.gz"
    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    log_info "Downloading filebrowser v${latest_version} (${asset})..."
    curl -fsSL "$url" | tar -xz -C "$tmp"
    install -m 755 "${tmp}/filebrowser" "$FB_BIN"
    log_ok "filebrowser installed: $("$FB_BIN" version)"
}

if [[ ! -x "$FB_BIN" ]]; then
    install_filebrowser
else
    log_ok "filebrowser already installed: $("$FB_BIN" version)"
fi

# ── Config directory and settings ─────────────────────────────────────────────
mkdir -p "$FB_DIR"

# Ensure the root path exists
if [[ ! -d "$root" ]]; then
    log_warn "filebrowser root '${root}' does not exist yet (drive may not be mounted). Creating directory."
    mkdir -p "$root"
fi

# Write the JSON settings file (filebrowser reads this via --config)
settings=$(cat <<EOF
{
  "port": ${port},
  "baseURL": "${base_url}",
  "address": "",
  "log": "stdout",
  "database": "${FB_DB}",
  "root": "${root}"
}
EOF
)

if [[ ! -f "$FB_CFG" ]] || ! diff -q <(echo "$settings") "$FB_CFG" &>/dev/null; then
    log_info "Writing ${FB_CFG}"
    echo "$settings" > "$FB_CFG"
    CONFIG_CHANGED=true
else
    CONFIG_CHANGED=false
fi

# ── Initialise database (first run only) ──────────────────────────────────────
if [[ ! -f "$FB_DB" ]]; then
    log_info "Initialising filebrowser database..."
    "$FB_BIN" config init --config "$FB_CFG"
    "$FB_BIN" users add "$fb_user" "$fb_password" --perm.admin --config "$FB_CFG"
    log_ok "User '${fb_user}' created."
else
    # Sync password from .env (apply.sh is authoritative).
    # If the username changed, create the new user; the old one can be
    # removed through the filebrowser UI if desired.
    if ! "$FB_BIN" users update "$fb_user" --password "$fb_password" --config "$FB_CFG" 2>/dev/null; then
        log_info "User '${fb_user}' not found — creating (username may have changed)..."
        "$FB_BIN" users add "$fb_user" "$fb_password" --perm.admin --config "$FB_CFG"
    fi
    log_ok "User '${fb_user}' updated."
fi

# ── Systemd service ───────────────────────────────────────────────────────────
unit_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=Filebrowser — web-based file manager
After=network.target $(
    m=$(config_len '.drives')
    for j in $(seq 0 $((m - 1))); do
        active=$(config_idx '.drives' "$j" '.active')
        [[ "$active" != "false" ]] || continue
        mp=$(config_idx '.drives' "$j" '.mountpoint')
        echo -n "$(systemd-escape --path "$mp").mount "
    done
)

[Service]
Type=simple
ExecStart=${FB_BIN} --config ${FB_CFG}
Restart=on-failure
RestartSec=5s
# Run as root so it can read all drive contents regardless of ownership.
# Restrict to local network + Tailscale by binding on all interfaces;
# use a firewall or Tailscale ACLs if tighter access control is needed.

[Install]
WantedBy=multi-user.target"

if [[ ! -f "$FB_UNIT" ]] || ! diff -q <(echo "$unit_content") "$FB_UNIT" &>/dev/null; then
    log_info "Writing ${FB_UNIT}"
    echo "$unit_content" > "$FB_UNIT"
    systemctl daemon-reload
fi

systemctl enable --now filebrowser.service

if [[ "$CONFIG_CHANGED" == "true" ]]; then
    log_info "Restarting filebrowser (config changed)..."
    systemctl restart filebrowser.service
fi

log_ok "Filebrowser running on port ${port}."
log_ok "Access at: http://$(hostname -I | awk '{print $1}'):${port}"
