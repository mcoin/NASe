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
    "${REPO_ROOT}/modules/sync/notify.sh" "SMART failure on $(hostname)" "$message" || true
    exit 1
fi

log_ok "All SMART checks passed."
