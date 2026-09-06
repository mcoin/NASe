#!/usr/bin/env bash
# modules/drives/spindown.sh
# Writes udev rules that ask nase-spindown.service to configure hdparm APM
# spindown timers when a drive with a known UUID is attached.  Also applies
# hdparm immediately to any drive that is currently present.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/drives/spindown_common.sh"

UDEV_RULES_FILE="/etc/udev/rules.d/99-nase-spindown.rules"

n=$(config_len '.drives')
{
    echo "# Managed by NASe — do not edit manually. Re-run apply.sh instead."
    echo "# Starts nase-spindown.service when a NASe-managed drive is attached, which"
    echo "# applies the hdparm APM/standby settings (with retries — see backlog #32)."
    echo ""
} > "$UDEV_RULES_FILE"

max_spindown_min=0

for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')

    if [[ "$active" == "false" ]]; then
        log_info "Drive '${name}': inactive — skipping spindown."
        continue
    fi

    uuid=$(config_idx '.drives' "$i" '.uuid')
    spindown_min=$(config_idx '.drives' "$i" '.spindown_min')

    if [[ "$spindown_min" -gt "$max_spindown_min" ]]; then
        max_spindown_min="$spindown_min"
    fi

    hdparm_val=$(spindown_min_to_hdparm "$spindown_min")

    if [[ "$hdparm_val" -eq 0 ]]; then
        log_info "Drive '${name}': spindown disabled"
        echo "# Drive '${name}' (spindown disabled)" >> "$UDEV_RULES_FILE"
    else
        log_info "Drive '${name}': spindown after ${spindown_min} min (hdparm -S ${hdparm_val})"
        # The rule starts nase-spindown.service rather than running hdparm
        # itself. udev fires 1-2 s after the device appears, while a USB disk
        # is still spinning up and its bridge rejects SET FEATURES — an
        # inline hdparm here failed on every boot and left both drives with
        # spin-down disabled (backlog #32). The service re-reads config.yaml,
        # resolves each drive by UUID and retries, and --no-block keeps the
        # udev worker free while it does. Boot is covered separately by the
        # unit's own WantedBy=multi-user.target, so this only has to handle
        # hot-plug.
        cat >> "$UDEV_RULES_FILE" <<EOF
# Drive: ${name} — spindown after ${spindown_min} min
ACTION=="add|change", SUBSYSTEM=="block", ENV{ID_FS_UUID}=="${uuid}", \\
  RUN+="/usr/bin/systemctl start --no-block nase-spindown.service"
EOF
    fi

    # Apply immediately too, so a config change takes effect without waiting
    # for a reboot or a re-plug. Same code path the boot service uses.
    spindown_apply_drive "$name" "$uuid" "$hdparm_val" || true
done

udevadm control --reload-rules
log_ok "Spindown rules written to ${UDEV_RULES_FILE}"

# ── Keep smartd's poll interval longer than any drive's spindown timer ──────
# smartmontools' smartd runs DEVICESCAN on a fixed interval (30 min by
# default) regardless of NASe's own per-drive smart_check setting. If that
# interval is shorter than a drive's hdparm spindown_min, smartd's periodic
# SMART read resets the drive's idle timer before it ever accumulates enough
# quiet time to spin down — the drive then never reaches standby, so
# smartd's own "-n standby" skip-if-asleep logic never kicks in either, and
# the drive spins forever. Keep smartd's interval comfortably above the
# longest configured spindown_min so every drive gets an idle window.
SMARTD_DEFAULTS="/etc/default/smartmontools"
SMARTD_MARKER_BEGIN="# --- Managed by NASe (spindown.sh): begin ---"
SMARTD_MARKER_END="# --- Managed by NASe (spindown.sh): end ---"

strip_smartd_block() {
    sed -i "/^${SMARTD_MARKER_BEGIN//\//\\/}$/,/^${SMARTD_MARKER_END//\//\\/}$/d" "$SMARTD_DEFAULTS"
}

if [[ -f "$SMARTD_DEFAULTS" ]]; then
    before_hash=$(md5sum "$SMARTD_DEFAULTS" | cut -d' ' -f1)

    grep -qF "$SMARTD_MARKER_BEGIN" "$SMARTD_DEFAULTS" && strip_smartd_block

    if [[ "$max_spindown_min" -gt 0 ]]; then
        smartd_interval_sec=$(( (max_spindown_min + 30) * 60 ))
        {
            echo "$SMARTD_MARKER_BEGIN"
            echo "# Interval kept above every configured drive spindown_min (longest: ${max_spindown_min}min)"
            echo "# so periodic SMART polling doesn't block spindown. See modules/drives/spindown.sh."
            echo "smartd_opts=\"--interval=${smartd_interval_sec}\""
            echo "$SMARTD_MARKER_END"
        } >> "$SMARTD_DEFAULTS"
    fi
    # else: no drive has spindown enabled — leave the block stripped so
    # smartd falls back to its own default interval.

    after_hash=$(md5sum "$SMARTD_DEFAULTS" | cut -d' ' -f1)

    if [[ "$before_hash" != "$after_hash" ]] && systemctl list-unit-files smartmontools.service &>/dev/null; then
        log_info "smartd config changed — restarting smartmontools.service (interval ${smartd_interval_sec:-default}s)"
        systemctl restart smartmontools.service || log_warn "  Could not restart smartmontools.service"
    fi
fi

# ── Build smartd's device list, excluding drives it can't safely poll ──────
# smartd's stock config scans every ATA/SCSI device via DEVICESCAN and
# applies "-n standby" (skip a check while genuinely asleep) uniformly. Some
# USB/UAS enclosures don't implement the ATA CHECK POWER MODE command at all
# (seen on this box's primary drive) — for those, "-n standby" silently
# becomes a no-op, so smartd unconditionally polls, and thus wakes, the
# drive every interval no matter how long it's been idle. DEVICESCAN can't
# be combined with per-device overrides (per its own doc comment, any lines
# after it are ignored), so once one drive needs to be excluded, the whole
# device list has to be taken over explicitly.
#
# Drives that can't be power-mode-queried are left out of smartd entirely —
# nase-monitor.timer's own check (modules/drives/monitor.sh) covers those
# instead, via spin_status.sh's I/O-activity heuristic, which doesn't need
# CHECK POWER MODE support.
SMARTD_CONF="/etc/smartd.conf"
SMARTD_CONF_MARKER_BEGIN="# --- Managed by NASe (spindown.sh): begin device list ---"
SMARTD_CONF_MARKER_END="# --- Managed by NASe (spindown.sh): end device list ---"

if [[ -f "$SMARTD_CONF" ]]; then
    conf_before_hash=$(md5sum "$SMARTD_CONF" | cut -d' ' -f1)

    sed -i "/^${SMARTD_CONF_MARKER_BEGIN//\//\\/}$/,/^${SMARTD_CONF_MARKER_END//\//\\/}$/d" "$SMARTD_CONF"
    sed -i '/^DEVICESCAN\b/d' "$SMARTD_CONF"

    # Decide per-drive inclusion (and log it) before writing anything —
    # log_info writes to stdout, so it must not run inside the redirected
    # block below or its output would land in the conf file itself.
    smartd_conf_lines=()
    for i in $(seq 0 $((n - 1))); do
        name=$(config_idx '.drives' "$i" '.name')
        active=$(config_idx '.drives' "$i" '.active')
        [[ "$active" == "false" ]] && continue
        smart_check=$(config_idx '.drives' "$i" '.smart_check')
        [[ "$smart_check" == "true" ]] || continue

        uuid=$(config_idx '.drives' "$i" '.uuid')
        dev_symlink="/dev/disk/by-uuid/${uuid}"

        power_mode_ok="unknown"
        smartd_dev=""
        if [[ -e "$dev_symlink" ]]; then
            # by-uuid resolves to the filesystem's partition (e.g. sdb1); SMART
            # commands (and the CHECK POWER MODE probe below) need the whole
            # disk. Prefer a by-id symlink for stability across reboots,
            # falling back to the raw /dev/sdX name if none exists.
            dev=$(readlink -f "$dev_symlink")
            disk=$(lsblk -no pkname "$dev" 2>/dev/null || true)
            if [[ -n "$disk" ]]; then
                smartd_dev=$(find /dev/disk/by-id -maxdepth 1 -lname "*/${disk}" 2>/dev/null | sort | head -1)
                [[ -z "$smartd_dev" ]] && smartd_dev="/dev/${disk}"

                hdparm_out=$(hdparm -C "$smartd_dev" 2>/dev/null || true)
                if echo "$hdparm_out" | grep -qE "standby|sleeping|active|idle"; then
                    power_mode_ok="yes"
                else
                    power_mode_ok="no"
                fi
            fi
        fi

        if [[ "$power_mode_ok" == "no" ]]; then
            log_info "smartd: '${name}' — CHECK POWER MODE unsupported over this bridge, excluding from smartd (nase-monitor.timer covers it instead)"
            smartd_conf_lines+=("# Drive '${name}': excluded — CHECK POWER MODE unsupported; monitored by nase-monitor.timer instead")
        elif [[ -n "$smartd_dev" ]]; then
            smartd_conf_lines+=("${smartd_dev} -d removable -n standby -m root -M exec /usr/share/smartmontools/smartd-runner")
        else
            smartd_conf_lines+=("# Drive '${name}': not present — will be picked up on next apply once connected")
        fi
    done

    {
        echo "$SMARTD_CONF_MARKER_BEGIN"
        echo "# Explicit per-device list — replaces DEVICESCAN so drives with a"
        echo "# broken CHECK POWER MODE can be excluded. See modules/drives/spindown.sh."
        printf '%s\n' "${smartd_conf_lines[@]}"
        echo "$SMARTD_CONF_MARKER_END"
    } >> "$SMARTD_CONF"

    conf_after_hash=$(md5sum "$SMARTD_CONF" | cut -d' ' -f1)
    if [[ "$conf_before_hash" != "$conf_after_hash" ]] && systemctl list-unit-files smartmontools.service &>/dev/null; then
        log_info "smartd device list changed — restarting smartmontools.service"
        systemctl restart smartmontools.service || log_warn "  Could not restart smartmontools.service"
    fi
fi
