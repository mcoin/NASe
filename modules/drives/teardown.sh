#!/usr/bin/env bash
# modules/drives/teardown.sh
# Brings the managed drives down deliberately at shutdown, ahead of systemd's
# generic unmounting. Run as ExecStop of nase-shutdown.service.
#
# Why this exists (backlog #31): on 2026-09-05 a reboot never completed and
# the power had to be pulled, leaving the SD card and backup_daily with
# orphan inodes. What shutdown has to take apart here is a stack — ten
# filebrowser bind mounts sitting on two USB drive mounts, with smbd,
# filebrowser and the primary watcher potentially holding them — and nothing
# ordered that teardown. A bind mount that will not release keeps the drive
# under it busy, and systemd has no timeout that covers a kernel-side unmount
# that never returns.
#
# Design rules, both learned the hard way:
#   * Never call systemctl from here. This runs inside the shutdown
#     transaction; queueing new jobs into it risks deadlocking the very
#     shutdown we are trying to make reliable. Ordering (After= in the unit)
#     is what stops the services; this script only touches mounts.
#   * Every external call is wrapped in `timeout` and every failure is
#     tolerated. A teardown that hangs is worse than no teardown at all: it
#     would recreate the exact bug it exists to prevent.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

# Bounds for the individual steps. The unit's own TimeoutStopSec is the
# backstop; these keep any single mount from eating the whole budget.
UMOUNT_TIMEOUT="${NASE_TEARDOWN_UMOUNT_TIMEOUT:-10}"
SYNC_TIMEOUT="${NASE_TEARDOWN_SYNC_TIMEOUT:-30}"

# unmount_path <path>
# Plain unmount first; lazy unmount as a fallback so a busy mount detaches
# from the tree instead of blocking. Same fallback modules/drives/setup.sh
# uses for stale mounts.
unmount_path() {
    local path="$1"
    if timeout "$UMOUNT_TIMEOUT" umount "$path" 2>/dev/null; then
        log_info "  unmounted ${path}"
        return 0
    fi
    if timeout "$UMOUNT_TIMEOUT" umount -l "$path" 2>/dev/null; then
        log_warn "  ${path} was busy — detached lazily"
        return 0
    fi
    log_warn "  could not unmount ${path} — leaving it to systemd"
    return 1
}

log_info "NASe teardown: bringing managed drives down before umount.target"

# ── 1. Flush anything mounted read-write ─────────────────────────────────────
# Backup drives are read-only at rest, but a sync interrupted by the shutdown
# leaves one read-write. Remounting ro forces the journal out and marks the
# filesystem clean, which is precisely the state that was missing after the
# 2026-09-05 power cut. A drive that is already ro is left alone — asking it
# to do anything would only spin it up again.
n=$(config_len '.drives')
for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')
    [[ "$active" == "false" ]] && continue
    mountpoint=$(config_idx '.drives' "$i" '.mountpoint')

    opts=$(findmnt -no OPTIONS --target "$mountpoint" 2>/dev/null || true)
    [[ -n "$opts" ]] || continue
    if [[ ",${opts}," == *",rw,"* ]]; then
        log_info "  '${name}' is mounted rw — remounting ro to flush it"
        timeout "$UMOUNT_TIMEOUT" mount -o remount,ro "$mountpoint" 2>/dev/null \
            || log_warn "  could not remount '${name}' read-only"
    fi
done

# ── 2. Unmount everything we put on top of the drives, deepest first ────────
# Sorting by path length descending unmounts /srv/filebrowser/Trash_daily
# before /srv/filebrowser/Backup_daily and the drives themselves, so no
# unmount is blocked by a child that is still attached.
mapfile -t nested < <(findmnt -rno TARGET 2>/dev/null \
    | grep -E '^/srv/filebrowser/' \
    | awk '{ print length, $0 }' | sort -rn | cut -d' ' -f2-)

for path in "${nested[@]:-}"; do
    [[ -n "$path" ]] && unmount_path "$path"
done

# ── 3. Unmount the drives themselves ────────────────────────────────────────
for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')
    [[ "$active" == "false" ]] && continue
    mountpoint=$(config_idx '.drives' "$i" '.mountpoint')

    if findmnt -no TARGET "$mountpoint" &>/dev/null; then
        unmount_path "$mountpoint"
    fi
done

# ── 4. Flush anything still buffered ────────────────────────────────────────
timeout "$SYNC_TIMEOUT" sync || log_warn "  sync did not finish within ${SYNC_TIMEOUT}s"

log_ok "NASe teardown complete."
exit 0
