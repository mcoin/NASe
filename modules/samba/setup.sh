#!/usr/bin/env bash
# modules/samba/setup.sh
# Generates /etc/samba/smb.conf from config.yaml and manages Samba users.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

TMPL="${REPO_ROOT}/modules/samba/smb.conf.tmpl"
SAMBA_CONF="/etc/samba/smb.conf"
GENERATED_CONF="/tmp/nase-smb.conf.$$"
trap 'rm -f "$GENERATED_CONF"' EXIT

# ── Generate smb.conf ─────────────────────────────────────────────────────────
workgroup=$(config_get '.samba.workgroup')

# Start from the global template, substituting the workgroup placeholder
sed "s/__WORKGROUP__/${workgroup}/g" "$TMPL" > "$GENERATED_CONF"

# Append a share section for each configured share
n_shares=$(config_len '.samba.shares')
log_info "Generating ${n_shares} share(s)..."

for i in $(seq 0 $((n_shares - 1))); do
    share_name=$(config_idx '.samba.shares' "$i" '.name')
    share_path=$(config_idx '.samba.shares' "$i" '.path')
    read_only=$(config_idx  '.samba.shares' "$i" '.read_only')
    valid_users=$(config_idx '.samba.shares' "$i" '.valid_users')

    [[ "$read_only" == "true" ]] && ro_str="yes" || ro_str="no"

    # Ensure share directory exists on the filesystem.
    # Skip silently if the drive isn't mounted or is read-only.
    if [[ ! -d "$share_path" ]]; then
        if mkdir -p "$share_path" 2>/dev/null; then
            log_info "  Created share directory: ${share_path}"
        else
            log_warn "  Cannot create ${share_path} — drive not mounted or read-only; skipping."
        fi
    fi

    log_info "  Share '${share_name}': path=${share_path}, read_only=${ro_str}"

    cat >> "$GENERATED_CONF" <<EOF

[${share_name}]
   path = ${share_path}
   browseable = yes
   read only = ${ro_str}
   valid users = ${valid_users}
   create mask = 0664
   directory mask = 0775
   force create mode = 0664
   force directory mode = 0775
EOF
done

# Apply only when the file has changed (avoids unnecessary samba reloads)
if ! diff -q "$GENERATED_CONF" "$SAMBA_CONF" &>/dev/null; then
    log_info "Updating ${SAMBA_CONF}"
    # Validate before replacing
    testparm -s "$GENERATED_CONF" &>/dev/null \
        || die "smb.conf validation failed — generated config has errors."
    cp "$GENERATED_CONF" "$SAMBA_CONF"
    CONFIG_CHANGED=true
else
    log_ok "smb.conf is already up to date."
    CONFIG_CHANGED=false
fi

# ── Samba users ───────────────────────────────────────────────────────────────
n_users=$(config_len '.samba.users')
log_info "Configuring ${n_users} Samba user(s)..."

for i in $(seq 0 $((n_users - 1))); do
    samba_user=$(config_idx '.samba.users' "$i" '')
    # Password variable: SAMBA_PASSWORD_<USERNAME_UPPERCASED>
    pass_var="SAMBA_PASSWORD_${samba_user^^}"
    password="${!pass_var:-}"

    if [[ -z "$password" ]]; then
        log_warn "  No password set for user '${samba_user}' (${pass_var} not in .env) — skipping."
        continue
    fi

    # Create the Linux system user if absent (locked — no shell login)
    if ! id "$samba_user" &>/dev/null; then
        log_info "  Creating system user '${samba_user}'"
        useradd --system --no-create-home --shell /usr/sbin/nologin "$samba_user"
    fi

    # Set / update the Samba password
    log_info "  Setting Samba password for '${samba_user}'"
    printf '%s\n%s\n' "$password" "$password" | smbpasswd -s -a "$samba_user"
    smbpasswd -e "$samba_user" &>/dev/null  # ensure account is enabled
done

# ── Samba service ─────────────────────────────────────────────────────────────
systemctl enable --now smbd nmbd

if [[ "$CONFIG_CHANGED" == "true" ]]; then
    log_info "Reloading Samba (config changed)..."
    systemctl reload smbd
fi

log_ok "Samba configured."
