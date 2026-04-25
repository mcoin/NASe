#!/usr/bin/env bash
# install.sh — first-time installer for a fresh Raspberry Pi OS image.
# Run once as root:  sudo ./install.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

# shellcheck source=lib/log.sh
source "${REPO_ROOT}/lib/log.sh"

log_section "NASe Installer"

# ── Root check (before lib/checks.sh is available without yq) ────────────────
[[ $EUID -eq 0 ]] || die "Please run as root: sudo ./install.sh"

# ── Install system packages ───────────────────────────────────────────────────
log_section "System packages"

apt-get update -qq

PACKAGES=(
    # Core
    rsync
    hdparm
    smartmontools
    # Samba
    samba
    samba-common-bin
    # Utilities used by scripts
    curl
    wget
    moreutils   # sponge, ts
    # Notification (email)
    msmtp
    msmtp-mta
    mailutils
)

log_info "Installing: ${PACKAGES[*]}"
apt-get install -y "${PACKAGES[@]}"

# ── Install yq (mikefarah/yq v4) ─────────────────────────────────────────────
log_section "yq (YAML processor)"

YQ_VERSION="4.44.2"
ARCH=$(dpkg --print-architecture)
case "$ARCH" in
    arm64) YQ_BINARY="yq_linux_arm64" ;;
    armhf) YQ_BINARY="yq_linux_arm"   ;;
    amd64) YQ_BINARY="yq_linux_amd64" ;;
    *) die "Unsupported architecture: $ARCH" ;;
esac

if command -v yq &>/dev/null && yq --version 2>&1 | grep -q "mikefarah"; then
    log_ok "yq already installed: $(yq --version)"
else
    log_info "Downloading yq ${YQ_VERSION} (${YQ_BINARY})..."
    wget -q "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/${YQ_BINARY}" \
        -O /usr/local/bin/yq
    chmod +x /usr/local/bin/yq
    log_ok "yq installed: $(yq --version)"
fi

# ── Install Tailscale ─────────────────────────────────────────────────────────
log_section "Tailscale"

CONFIG_FILE="${REPO_ROOT}/config.yaml"
# shellcheck source=lib/config.sh
source "${REPO_ROOT}/lib/config.sh"

if config_bool '.tailscale.enabled'; then
    if command -v tailscale &>/dev/null; then
        log_ok "Tailscale already installed: $(tailscale version | head -1)"
    else
        log_info "Installing Tailscale..."
        curl -fsSL https://tailscale.com/install.sh | sh
    fi
else
    log_info "Tailscale disabled in config — skipping."
fi

# ── Apply configuration ───────────────────────────────────────────────────────
log_section "Applying configuration"

"${REPO_ROOT}/apply.sh"

log_section "Installation complete"
log_ok "NASe is set up. Review the service status with:"
log_ok "  systemctl status smbd nas-monitor.service"
log_ok "  systemctl list-timers 'nas-sync-*'"
