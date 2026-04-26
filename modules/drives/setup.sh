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
    active=$(config_idx '.drives' "$i" '.active')

    # active defaults to true when the field is absent
    if [[ "$active" == "false" ]]; then
        log_info "Drive '${name}': inactive — skipping."
        continue
    fi

    uuid=$(config_idx '.drives' "$i" '.uuid')
    mountpoint=$(config_idx '.drives' "$i" '.mountpoint')
    filesystem=$(config_idx '.drives' "$i" '.filesystem')
    owner=$(config_idx '.drives' "$i" '.owner')
    read_only=$(config_idx '.drives' "$i" '.read_only')

    log_info "Drive '${name}': mountpoint=${mountpoint}, uuid=${uuid}"

    # Remove stale NASe-managed mount units that reference this UUID at a
    # different mountpoint (i.e. the drive was renamed in config.yaml).
    for stale_file in "${SYSTEMD_DIR}"/*.mount; do
        [[ -f "$stale_file" ]] || continue
        # Only touch units we wrote — they carry the managed-by comment.
        grep -q "Managed by NASe" "$stale_file" || continue
        # Must reference this UUID.
        grep -q "by-uuid/${uuid}" "$stale_file" || continue
        # Skip if it already points to the correct mountpoint.
        grep -q "Where=${mountpoint}$" "$stale_file" && continue
        stale_unit=$(basename "$stale_file")
        old_mp=$(grep "^Where=" "$stale_file" | cut -d= -f2-)
        log_info "  Removing stale mount unit ${stale_unit} (was: ${old_mp})"
        systemctl disable --now "$stale_unit" 2>/dev/null || true
        rm -f "$stale_file"
        systemctl daemon-reload
    done

    # After stopping stale units, the device may still be live at other paths
    # (e.g. bind-mounts layered on top of the old base mount).
    # Collect all stale mount paths and unmount deepest-first so that child
    # mounts are removed before the parent they depend on.
    mapfile -t stale_mps < <(findmnt --source "/dev/disk/by-uuid/${uuid}" \
        --output TARGET --noheadings 2>/dev/null \
        | grep -v "^${mountpoint}$" | awk '{ print length, $0 }' \
        | sort -rn | cut -d' ' -f2- || true)
    for current_mp in "${stale_mps[@]:-}"; do
        [[ -n "$current_mp" ]] || continue
        log_info "  Device ${uuid} still live at ${current_mp} — unmounting..."
        if ! umount "$current_mp" 2>/dev/null; then
            # Regular unmount failed (busy processes holding open handles).
            # Lazy unmount detaches from the hierarchy immediately; the kernel
            # completes the release once all open file handles are closed.
            umount -l "$current_mp" 2>/dev/null \
                || log_warn "  Could not unmount ${current_mp} — may need manual cleanup"
        fi
    done

    # Create mountpoint directory
    if [[ ! -d "$mountpoint" ]]; then
        log_info "  Creating mountpoint ${mountpoint}"
        mkdir -p "$mountpoint"
    fi

    # Set ownership of the mountpoint itself (non-recursive, instant).
    # To fix ownership of all existing files run: sudo ./fix-ownership.sh
    if [[ -n "$owner" ]] && [[ -d "$mountpoint" ]]; then
        log_info "  Setting owner of ${mountpoint} to '${owner}'"
        chown "${owner}:${owner}" "$mountpoint"
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
Options=${read_only:+ro,}defaults,nofail,noatime,x-systemd.device-timeout=10s

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
