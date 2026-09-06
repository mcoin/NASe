#!/usr/bin/env bash
# modules/drives/prune_mount_units.sh
# Removes NASe-managed .mount units for drives that are no longer in
# config.yaml at all, along with their (empty) mountpoints.
# Called by modules/drives/setup.sh; separate so it can be tested without
# running the whole drives module.
#
# The per-drive cleanup in setup.sh only inspects units whose UUID is still
# configured, so deleting a drive from config.yaml orphaned its unit instead
# of removing it: mnt-backup_weekly.mount survived that way for months, still
# enabled and still trying to mount a disk that is not attached (backlog #31).
#
# Units for drives that are merely `active: false` are kept — that flag means
# "temporarily detached", not "gone".
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SYSTEMD_DIR="${NASE_SYSTEMD_DIR:-/etc/systemd/system}"

configured_uuids=()
n=$(config_len '.drives')
for i in $(seq 0 $((n - 1))); do
    configured_uuids+=("$(config_idx '.drives' "$i" '.uuid')")
done

removed_unit=false
for unit_file in "${SYSTEMD_DIR}"/*.mount; do
    [[ -f "$unit_file" ]] || continue
    # Only ever touch units we wrote — they carry the managed-by comment.
    grep -q "Managed by NASe" "$unit_file" || continue

    # Bind-mount units (filebrowser) carry no UUID and belong to another
    # module. `|| true` matters: under `set -o pipefail` a grep that matches
    # nothing fails the whole assignment and would abort the drives module.
    unit_uuid=$(grep -oE 'by-uuid/[0-9a-fA-F-]+' "$unit_file" | head -1 | cut -d/ -f2 || true)
    [[ -n "$unit_uuid" ]] || continue

    known=false
    for configured in "${configured_uuids[@]:-}"; do
        if [[ "$configured" == "$unit_uuid" ]]; then
            known=true
            break
        fi
    done
    if [[ "$known" == "true" ]]; then
        continue
    fi

    unit_name=$(basename "$unit_file")
    old_mp=$(grep "^Where=" "$unit_file" | cut -d= -f2- || true)
    log_info "Removing mount unit ${unit_name}: UUID ${unit_uuid} is no longer in config.yaml (was: ${old_mp:-unknown})"
    systemctl disable --now "$unit_name" 2>/dev/null || true
    rm -f "$unit_file"
    removed_unit=true

    # Take the empty mountpoint with it. rmdir refuses a non-empty directory,
    # so anything left behind on the SD card survives to be looked at rather
    # than being silently deleted.
    if [[ -n "$old_mp" && -d "$old_mp" ]] && ! findmnt -no TARGET "$old_mp" &>/dev/null; then
        if rmdir "$old_mp" 2>/dev/null; then
            log_info "  Removed empty mountpoint ${old_mp}"
        else
            log_info "  Left ${old_mp} in place — not empty"
        fi
    fi
done

if [[ "$removed_unit" == "true" ]]; then
    systemctl daemon-reload
fi
