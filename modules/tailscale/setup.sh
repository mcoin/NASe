#!/usr/bin/env bash
# modules/tailscale/setup.sh
# Configures Tailscale for remote access.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

# Secrets are expected to be loaded by the caller (apply.sh sources .env)
TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

[[ -n "$TAILSCALE_AUTHKEY" ]] || die "TAILSCALE_AUTHKEY is not set — add it to .env"

command -v tailscale &>/dev/null || die "tailscale not installed — run install.sh first."

# ── Enable IP forwarding (required for exit node / subnet routing) ────────────
advertise_exit_node=$(config_bool '.tailscale.advertise_exit_node' 2>/dev/null && echo true || echo false)
advertise_routes=$(config_get '.tailscale.advertise_routes')

if [[ "$advertise_exit_node" == "true" ]] || [[ -n "$advertise_routes" ]]; then
    log_info "Enabling IP forwarding for Tailscale routing..."
    cat > /etc/sysctl.d/99-nas-tailscale.conf <<'EOF'
# NASe: required for Tailscale exit node / subnet routing
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
    sysctl --system -q
fi

# ── Build tailscale up arguments ──────────────────────────────────────────────
hostname_cfg=$(config_get '.nas.hostname')

UP_ARGS=(
    --authkey "$TAILSCALE_AUTHKEY"
    --hostname "${hostname_cfg:-nas}"
    --accept-routes
)

if [[ "$advertise_exit_node" == "true" ]]; then
    UP_ARGS+=(--advertise-exit-node)
fi

if [[ -n "$advertise_routes" ]]; then
    UP_ARGS+=(--advertise-routes "$advertise_routes")
fi

# ── Start tailscaled daemon ───────────────────────────────────────────────────
systemctl enable --now tailscaled

# ── Connect / re-authenticate ────────────────────────────────────────────────
# `tailscale up` is idempotent; it re-authenticates only if the key changed.
log_info "Running tailscale up (hostname=${hostname_cfg})..."
tailscale up "${UP_ARGS[@]}"

log_ok "Tailscale connected. Status:"
tailscale status
