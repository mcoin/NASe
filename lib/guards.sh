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

# is_mounted_at PATH
# Returns 0 if something is mounted *exactly* at PATH, 1 otherwise.
#
# The reason this exists rather than each caller writing its own check: the
# obvious spelling, `findmnt --target PATH`, cannot answer this question.
# --target resolves *up* to the nearest enclosing mount, so for an unmounted
# /mnt/primary it finds the SD card's root mount, exits 0, and reports the
# drive as present. Used as a guard it therefore never fires, and the caller
# proceeds to read or write the mountpoint directory on the SD card.
#
# That was not hypothetical (backlog #33): modules/config-archive/archive.sh
# wrote config snapshots to /mnt/primary/backups/NASe on the SD card and
# logged success, and modules/integrity/setup.sh created a manifest there.
# Both become invisible the moment the real drive mounts over them — so the
# archive silently was not one. The same spelling in three other places has
# already been found and fixed one at a time (#31 teardown, #29 report), which
# is why this is a shared helper rather than a fourth local fix.
#
# --mountpoint matches only an exact mountpoint, which is the question asked.
is_mounted_at() {
    findmnt --mountpoint "$1" --noheadings &>/dev/null
}

# mount_options_at PATH
# The mount options of the filesystem mounted exactly at PATH, or empty if
# nothing is. Same trap as above: reading options through --target on an
# unmounted path returns the *root filesystem's* options, so a missing drive
# reads as "rw" and callers conclude it is safe to write to.
mount_options_at() {
    findmnt --mountpoint "$1" --output OPTIONS --noheadings --first-only 2>/dev/null || true
}

# is_mounted_ro_at PATH
# Returns 0 if PATH is an exact mountpoint mounted read-only.
is_mounted_ro_at() {
    mount_options_at "$1" | grep -qw ro
}
