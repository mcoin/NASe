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
    local arch_pattern
    case "$arch" in
        arm64) arch_pattern="linux.*arm64" ;;
        armhf) arch_pattern="linux.*armv7" ;;
        amd64) arch_pattern="linux.*amd64" ;;
        *)     die "Unsupported architecture: ${arch}" ;;
    esac

    log_info "Fetching latest filebrowser release info..."
    local release_json
    release_json=$(curl -fsSL https://api.github.com/repos/filebrowser/filebrowser/releases/latest)

    # Extract the download URL for the matching .tar.gz asset directly from the
    # API response — avoids hardcoding asset name patterns that change between releases.
    local url
    url=$(echo "$release_json" \
        | grep "browser_download_url" \
        | grep -iE "${arch_pattern}.*\.tar\.gz" \
        | head -1 \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/')

    [[ -n "$url" ]] || die "Could not find a filebrowser release asset for arch '${arch}'. Check https://github.com/filebrowser/filebrowser/releases"

    local version
    version=$(echo "$release_json" | grep '"tag_name"' | sed 's/.*"v\([^"]*\)".*/\1/')

    local tmp
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' RETURN

    log_info "Downloading filebrowser v${version} (${arch})..."
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
chown -R "${fb_user}:${fb_user}" "$FB_DIR"

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

# ── Initialise / update database ─────────────────────────────────────────────
# Stop the service first so the SQLite database is not locked.
if systemctl is-active --quiet filebrowser.service 2>/dev/null; then
    log_info "Stopping filebrowser to update database..."
    systemctl stop filebrowser.service
fi

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
User=${fb_user}
Group=${fb_user}

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
