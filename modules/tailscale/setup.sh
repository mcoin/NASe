#!/usr/bin/env bash
# modules/tailscale/setup.sh
# Configures Tailscale for remote access.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

TAILSCALE_AUTHKEY="${TAILSCALE_AUTHKEY:-}"

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
# If already connected, run tailscale up without an authkey (updates flags only).
# If not yet connected, an authkey is required.
if tailscale status &>/dev/null; then
    log_info "Tailscale already connected — updating settings..."
    # Remove --authkey from args since we don't need to re-authenticate
    RECONNECT_ARGS=()
    for arg in "${UP_ARGS[@]}"; do
        [[ "$arg" == "--authkey" ]] && skip_next=true && continue
        [[ "${skip_next:-false}" == "true" ]] && skip_next=false && continue
        RECONNECT_ARGS+=("$arg")
    done
    tailscale up "${RECONNECT_ARGS[@]}"
else
    [[ -n "$TAILSCALE_AUTHKEY" ]] \
        || die "Tailscale is not connected and TAILSCALE_AUTHKEY is not set — add it to .env"
    log_info "Connecting Tailscale (hostname=${hostname_cfg})..."
    tailscale up "${UP_ARGS[@]}"
fi

log_ok "Tailscale connected. Status:"
tailscale status
