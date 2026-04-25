#!/usr/bin/env bash
# modules/drives/setup.sh
# Generates systemd .mount units from config and (re-)applies spindown rules.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SYSTEMD_DIR="/etc/systemd/system"

n=$(config_len '.drives')
log_info "Configuring ${n} drive(s)..."

for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    uuid=$(config_idx '.drives' "$i" '.uuid')
    mountpoint=$(config_idx '.drives' "$i" '.mountpoint')
    filesystem=$(config_idx '.drives' "$i" '.filesystem')

    log_info "Drive '${name}': mountpoint=${mountpoint}, uuid=${uuid}"

    # Create mountpoint directory
    if [[ ! -d "$mountpoint" ]]; then
        log_info "  Creating mountpoint ${mountpoint}"
        mkdir -p "$mountpoint"
    fi

    # Derive the systemd unit name from the mountpoint path.
    # systemd-escape --path /mnt/primary => mnt-primary
    unit_base=$(systemd-escape --path "$mountpoint")
    unit_file="${SYSTEMD_DIR}/${unit_base}.mount"

    # Generate the mount unit
    unit_content="# Managed by NASe — do not edit manually. Re-run apply.sh instead.
[Unit]
Description=NASe mount: ${name} (${mountpoint})
After=local-fs-pre.target
Before=multi-user.target

[Mount]
What=/dev/disk/by-uuid/${uuid}
Where=${mountpoint}
Type=${filesystem}
Options=defaults,nofail,noatime,x-systemd.device-timeout=10s

[Install]
WantedBy=multi-user.target"

    # Write unit only when content has changed
    if [[ ! -f "$unit_file" ]] || ! diff -q <(echo "$unit_content") "$unit_file" &>/dev/null; then
        log_info "  Writing ${unit_file}"
        echo "$unit_content" > "$unit_file"
    fi

    systemctl daemon-reload
    systemctl enable "${unit_base}.mount"

    if ! systemctl is-active --quiet "${unit_base}.mount"; then
        log_info "  Starting ${unit_base}.mount"
        systemctl start "${unit_base}.mount" || log_warn "  Could not start ${unit_base}.mount (drive may not be connected)"
    else
        log_ok "  ${unit_base}.mount is active"
    fi
done

# Apply spindown rules
log_info "Applying spindown rules..."
"${REPO_ROOT}/modules/drives/spindown.sh"
