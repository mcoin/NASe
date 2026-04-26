#!/usr/bin/env bash
# modules/filebrowser/setup.sh
# Installs and configures filebrowser (https://filebrowser.xyz/).
#
# The file browser root is a virtual directory (services.filebrowser.root,
# default /srv/filebrowser) that is populated at apply time with systemd bind
# mount units so the view matches the Samba/Finder layout:
#
#   /srv/filebrowser/
#     Music/         ← bind /mnt/primary/Music
#     Photo_albums/  ← bind /mnt/primary/Photo_albums
#     …              ← one entry per primary-drive samba share
#     Backup/        ← bind /mnt/backup         (collision-safe name)
#     Trash/         ← bind /mnt/backup/.trash  (collision-safe name)
#
# If a primary-drive samba share is already named "Backup" or "Trash", the
# virtual backup/trash folder gets a "_NAS" suffix to avoid ambiguity.
#
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
SYSTEMD_DIR="/etc/systemd/system"

port=$(config_get '.services.filebrowser.port')
root=$(config_get '.services.filebrowser.root')
base_url=$(config_get '.services.filebrowser.base_url')
fb_user=$(config_get '.services.filebrowser.username')
fb_password="${FILEBROWSER_PASSWORD:-}"

[[ -n "$fb_user" ]]     || die "services.filebrowser.username is not set in config.yaml"
[[ -n "$fb_password" ]] || die "FILEBROWSER_PASSWORD is not set — add it to .env"

# ── Install binary ─────────────────────────────────────────────────────────────
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

# ── Resolve drive roles ────────────────────────────────────────────────────────
primary_mp=""
backup_mp=""
n_drives=$(config_len '.drives')
for i in $(seq 0 $((n_drives - 1))); do
    drv_role=$(config_idx '.drives' "$i" '.role')
    drv_active=$(config_idx '.drives' "$i" '.active')
    [[ "$drv_active" == "false" ]] && continue
    drv_mp=$(config_idx '.drives' "$i" '.mountpoint')
    [[ "$drv_role" == "main" ]]   && primary_mp="$drv_mp"
    [[ "$drv_role" == "backup" ]] && backup_mp="$drv_mp"
done

[[ -n "$primary_mp" ]] || die "No active drive with role=main found in config."

# ── Collision-safe virtual folder names ───────────────────────────────────────
# Collect every samba share name that targets the primary drive.
declare -A _pshares
n_shares=$(config_len '.samba.shares')
for i in $(seq 0 $((n_shares - 1))); do
    sname=$(config_idx '.samba.shares' "$i" '.name')
    spath=$(config_idx '.samba.shares' "$i" '.path')
    [[ "$spath" == "${primary_mp}/"* ]] && _pshares["$sname"]=1
done

# Return a name that does not collide with any primary samba share.
_pick_safe_name() {
    local preferred="$1"
    local candidate="$preferred"
    local n=1
    while [[ -n "${_pshares[$candidate]+x}" ]]; do
        candidate="${preferred}_NAS${n}"
        (( n++ )) || true
    done
    echo "$candidate"
}

backup_vname=$(_pick_safe_name "Backup")
trash_vname=$(_pick_safe_name  "Trash")

if [[ "$backup_vname" != "Backup" ]]; then
    log_warn "Primary drive has a share named 'Backup' — backup drive virtual folder will be '${backup_vname}'."
fi
if [[ "$trash_vname" != "Trash" ]]; then
    log_warn "Primary drive has a share named 'Trash' — trash virtual folder will be '${trash_vname}'."
fi

# ── Build the virtual root with systemd bind-mount units ──────────────────────
mkdir -p "$root"

# Track units written this run so stale ones can be removed afterwards.
bind_mount_units=()

# Return the systemd unit name for a given mount path.
_unit_name_for() { echo "$(systemd-escape --path "$1").mount"; }

# Write (or refresh) a systemd bind-mount unit and start it.
# Usage: _ensure_bind_mount <source> <target> <after-units>
_ensure_bind_mount() {
    local what="$1" where="$2" after_units="${3:-}"
    mkdir -p "$where"

    local uname
    uname=$(_unit_name_for "$where")
    local unit_file="${SYSTEMD_DIR}/${uname}"

    local content
    content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe filebrowser bind mount ${where}
After=${after_units}

[Mount]
What=${what}
Where=${where}
Type=none
Options=bind

[Install]
WantedBy=filebrowser.service"

    if [[ ! -f "$unit_file" ]] || ! diff -q <(echo "$content") "$unit_file" &>/dev/null; then
        log_info "Writing ${unit_file}"
        echo "$content" > "$unit_file"
        systemctl daemon-reload
    fi

    # Best-effort: source may not yet be mounted during first apply.
    systemctl enable --now "$uname" 2>/dev/null || \
        log_warn "  Could not activate ${uname} (source path may not be mounted yet)"

    bind_mount_units+=("$uname")
}

# Systemd unit names for the real drive mount points (used in After=).
primary_mount_unit="$(systemd-escape --path "$primary_mp").mount"
backup_mount_unit=""
[[ -n "$backup_mp" ]] && backup_mount_unit="$(systemd-escape --path "$backup_mp").mount"

# One bind mount per primary-drive samba share.
for i in $(seq 0 $((n_shares - 1))); do
    sname=$(config_idx '.samba.shares' "$i" '.name')
    spath=$(config_idx '.samba.shares' "$i" '.path')
    [[ "$spath" != "${primary_mp}/"* ]] && continue
    _ensure_bind_mount "$spath" "${root}/${sname}" "$primary_mount_unit"
done

# Backup drive virtual folder.
if [[ -n "$backup_mp" ]]; then
    _ensure_bind_mount "$backup_mp" "${root}/${backup_vname}" "$backup_mount_unit"

    # Trash virtual folder — derive path from first sync job that uses trash.
    trash_path=""
    n_jobs=$(config_len '.sync_jobs')
    for j in $(seq 0 $((n_jobs - 1))); do
        tp=$(config_idx '.sync_jobs' "$j" '.trash.path')
        [[ -n "$tp" ]] && { trash_path="$tp"; break; }
    done

    if [[ -n "$trash_path" && "$trash_path" != "$backup_mp" ]]; then
        # Ensure the trash directory exists on the backup drive.
        mkdir -p "$trash_path"
        _ensure_bind_mount "$trash_path" "${root}/${trash_vname}" "$backup_mount_unit"
    fi
fi

# ── Remove stale bind-mount units ─────────────────────────────────────────────
# Any <root-escaped>-*.mount left over from a previous run (e.g. after a share
# is renamed or removed) is disabled and deleted.
root_escaped=$(systemd-escape --path "$root")
for existing_file in "${SYSTEMD_DIR}/${root_escaped}-"*.mount; do
    [[ -f "$existing_file" ]] || continue
    existing_uname=$(basename "$existing_file")
    found=false
    for u in "${bind_mount_units[@]:-}"; do
        [[ "$u" == "$existing_uname" ]] && { found=true; break; }
    done
    if [[ "$found" == "false" ]]; then
        log_info "Removing stale bind-mount unit: ${existing_uname}"
        systemctl disable --now "$existing_uname" 2>/dev/null || true
        rm -f "$existing_file"
        systemctl daemon-reload
    fi
done

# ── Config directory and settings ─────────────────────────────────────────────
mkdir -p "$FB_DIR"
chown -R "${fb_user}:${fb_user}" "$FB_DIR"

# Ensure the virtual root exists (already created above, but guard anyway).
if [[ ! -d "$root" ]]; then
    log_warn "filebrowser root '${root}' does not exist yet. Creating directory."
    mkdir -p "$root"
fi

# Write the JSON settings file (filebrowser reads this via --config).
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
# Build the After= list: real drive mounts + all bind-mount units.
after_units="network.target"
for i in $(seq 0 $((n_drives - 1))); do
    active=$(config_idx '.drives' "$i" '.active')
    [[ "$active" != "false" ]] || continue
    mp=$(config_idx '.drives' "$i" '.mountpoint')
    after_units+=" $(systemd-escape --path "$mp").mount"
done
for u in "${bind_mount_units[@]:-}"; do
    after_units+=" ${u}"
done

unit_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=Filebrowser — web-based file manager
After=${after_units}

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
log_ok "Virtual root: ${root}"
if [[ "$backup_vname" != "Backup" ]]; then
    log_info "  Backup drive → '${backup_vname}/' (collision with primary share 'Backup')"
fi
if [[ "$trash_vname" != "Trash" ]]; then
    log_info "  Trash        → '${trash_vname}/'  (collision with primary share 'Trash')"
fi
