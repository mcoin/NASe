#!/usr/bin/env bash
# lib/guards.sh — mount safety guards for sync operations.
# Source this file; do not execute directly.
# Requires: lib/log.sh already sourced.

# get_mount_device PATH
# Return the block device backing PATH via findmnt.
# Returns empty string on failure or if the path is not a mountpoint.
get_mount_device() {
    findmnt --target "$1" --output SOURCE --noheadings --first-only 2>/dev/null || true
}

# is_safe_mount_path LABEL PATH ROOT_DEV
# Returns 0 (safe) if PATH is on a real mounted device other than ROOT_DEV.
# Returns 1 (unsafe/skip) if PATH resolves to ROOT_DEV or to nothing at all.
#
# The empty-device case is the critical one: if a drive is unmounted but its
# mount directory exists on the root filesystem, findmnt may return empty
# instead of the root device.  Treating empty as "not safe" prevents rsync
# --delete from running against an empty directory on the SD card.
is_safe_mount_path() {
    local label="$1" path="$2" root_dev="$3"
    local dev
    dev=$(get_mount_device "$path")
    if [[ -z "$dev" ]] || [[ "$dev" == "$root_dev" ]]; then
        log_info "${label} '${path}' is not on a mounted drive — skipping."
        return 1
    fi
    return 0
}
