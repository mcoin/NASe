#!/usr/bin/env bash
# modules/drives/monitor.sh
# Checks SMART health for all configured drives and notifies on failure.
# Called by nase-monitor.service (via nase-monitor.timer).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

failures=()

n=$(config_len '.drives')
for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')
    smart_check=$(config_idx '.drives' "$i" '.smart_check')

    [[ "$active" != "false" ]] || continue
    [[ "$smart_check" == "true" ]] || continue

    uuid=$(config_idx '.drives' "$i" '.uuid')

    dev_symlink="/dev/disk/by-uuid/${uuid}"
    if [[ ! -e "$dev_symlink" ]]; then
        log_warn "Drive '${name}' (UUID ${uuid}) not present — skipping SMART check."
        continue
    fi

    dev=$(readlink -f "$dev_symlink")
    # Resolve to the whole disk (not a partition)
    disk=$(lsblk -no pkname "$dev" 2>/dev/null || true)
    disk_path="${disk:+/dev/${disk}}"
    [[ -z "$disk_path" ]] && disk_path="$dev"

    # Skip the check entirely if the drive looks spun down — smartctl -H
    # would otherwise wake it just to answer. spin_status.sh already knows
    # how to tell (hdparm -C where supported, an I/O-activity heuristic
    # where the bridge doesn't implement CHECK POWER MODE).
    spin_info=$("${REPO_ROOT}/modules/drives/spin_status.sh" "$name")
    spin_state=$(awk '{print $1}' <<< "$spin_info")
    if [[ "$spin_state" == "standby" ]]; then
        log_info "  '${name}': in standby — skipping SMART check to avoid waking it."
        continue
    fi

    log_info "Checking SMART health of '${name}' (${disk_path})..."
    # -H: print overall health assessment
    # -A: print drive attributes
    smart_output=$(smartctl -H "$disk_path" 2>&1 || true)
    smart_status=$?

    if echo "$smart_output" | grep -q "PASSED"; then
        log_ok "  '${name}': SMART PASSED"
    elif echo "$smart_output" | grep -q "FAILED"; then
        log_error "  '${name}': SMART FAILED!"
        failures+=("${name} (${disk_path}): SMART health test FAILED")
    else
        # smartctl exit code 2 = drive not available, etc.
        log_warn "  '${name}': SMART status unclear (exit ${smart_status})"
        log_warn "  Output: ${smart_output}"
    fi
done

if [[ ${#failures[@]} -gt 0 ]]; then
    message="SMART health failures detected on $(hostname):"$'\n'
    for f in "${failures[@]}"; do
        message+="  - ${f}"$'\n'
    done
    log_error "$message"
    printf '%s' "$message" | "${REPO_ROOT}/modules/sync/notify.sh" "SMART failure on $(hostname)" || true
    exit 1
fi

log_ok "All SMART checks passed."

# ── Inotify watch capacity ──────────────────────────────────────────────────
# modules/primary-watch/record.sh needs one inotify watch per directory under
# /mnt/primary. Warn well before the directory count catches up with
# fs.inotify.max_user_watches, since once it's exceeded the recorder starts
# failing silently and the web UI's Changes view goes blank.
WATCH_ROOT="/mnt/primary"
WATCH_WARN_PCT=80

if [[ -d "$WATCH_ROOT" ]]; then
    watch_limit=$(cat /proc/sys/fs/inotify/max_user_watches 2>/dev/null || echo 0)
    dir_count=$(find "$WATCH_ROOT" -xdev -type d 2>/dev/null | wc -l)

    if [[ "$watch_limit" -gt 0 ]]; then
        pct=$(( dir_count * 100 / watch_limit ))
        log_info "Primary drive directory count: ${dir_count} (${pct}% of fs.inotify.max_user_watches=${watch_limit})"

        if (( pct >= WATCH_WARN_PCT )); then
            message="Primary drive has ${dir_count} directories, ${pct}% of the fs.inotify.max_user_watches limit (${watch_limit}) on $(hostname). Once this limit is exceeded, the primary-watch file-change recorder (nase-primary-watch.service) will fail to set up its watch and the Changes view will stop updating. Raise fs.inotify.max_user_watches in modules/primary-watch/setup.sh and re-apply."
            log_warn "$message"
            printf '%s' "$message" | "${REPO_ROOT}/modules/sync/notify.sh" "inotify watch capacity warning on $(hostname)" || true
        fi
    fi
fi
