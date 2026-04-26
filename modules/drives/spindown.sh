#!/usr/bin/env bash
# modules/drives/spindown.sh
# Writes udev rules that configure hdparm APM spindown timers when a drive
# with a known UUID is attached.  Also applies hdparm immediately to any
# drive that is currently present.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

UDEV_RULES_FILE="/etc/udev/rules.d/99-nase-spindown.rules"

# hdparm -S value encoding:
#   0        = disable spindown
#   1-240    = value × 5 seconds   (so 240 = 20 minutes)
#   241-251  = 30 min + (value-241) × 30 min
# We receive spindown_min from config and convert to the closest value.
spindown_min_to_hdparm() {
    local minutes="$1"
    if [[ "$minutes" -eq 0 ]]; then
        echo 0
        return
    fi
    local seconds=$(( minutes * 60 ))
    if [[ "$seconds" -le 1200 ]]; then
        # Range 1-240: each unit = 5 s
        local val=$(( seconds / 5 ))
        [[ "$val" -lt 1 ]] && val=1
        echo "$val"
    else
        # Range 241-251: 241 = 30 min, each +1 adds 30 min (up to ~5.5 h)
        local val=$(( 241 + (minutes - 30) / 30 ))
        [[ "$val" -gt 251 ]] && val=251
        echo "$val"
    fi
}

n=$(config_len '.drives')
{
    echo "# Managed by NASe — do not edit manually. Re-run apply.sh instead."
    echo "# Sets hdparm APM spindown timer when a NASe-managed drive is attached."
    echo ""
} > "$UDEV_RULES_FILE"

for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')

    if [[ "$active" == "false" ]]; then
        log_info "Drive '${name}': inactive — skipping spindown."
        continue
    fi

    uuid=$(config_idx '.drives' "$i" '.uuid')
    spindown_min=$(config_idx '.drives' "$i" '.spindown_min')

    hdparm_val=$(spindown_min_to_hdparm "$spindown_min")

    if [[ "$hdparm_val" -eq 0 ]]; then
        log_info "Drive '${name}': spindown disabled"
        echo "# Drive '${name}' (spindown disabled)" >> "$UDEV_RULES_FILE"
    else
        log_info "Drive '${name}': spindown after ${spindown_min} min (hdparm -S ${hdparm_val})"
        # The rule matches the disk device (not partition) by UUID of any partition on it.
        # DEVTYPE==disk matches the whole disk; we use the UUID of the first partition.
        cat >> "$UDEV_RULES_FILE" <<EOF
# Drive: ${name} — spindown after ${spindown_min} min
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="${uuid}", \\
  RUN+="/usr/bin/hdparm -S ${hdparm_val} /dev/%k"
EOF
    fi

    # Apply hdparm immediately if the device is currently present
    dev_symlink="/dev/disk/by-uuid/${uuid}"
    if [[ -e "$dev_symlink" ]]; then
        dev=$(readlink -f "$dev_symlink")
        # hdparm -S applies to the whole disk, not a partition
        disk=$(lsblk -no pkname "$dev" 2>/dev/null || true)
        if [[ -n "$disk" ]]; then
            log_info "  Applying hdparm -S ${hdparm_val} to /dev/${disk}"
            hdparm -S "$hdparm_val" "/dev/${disk}" &>/dev/null || log_warn "  hdparm failed for /dev/${disk}"
        fi
    fi
done

udevadm control --reload-rules
log_ok "Spindown rules written to ${UDEV_RULES_FILE}"
