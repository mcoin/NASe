#!/usr/bin/env bash
# modules/drives/spindown_apply.sh
# Applies every active drive's hdparm APM/standby settings from config.yaml.
#
# These settings do not survive a power cycle: a reboot resets APM to the
# drive's factory default (usually 254), which disables spin-down in firmware
# and silently overrides any -S timer. Something therefore has to re-apply
# them on every boot. udev used to do it inline and failed, because it fires
# 1-2 s after the device appears while the disk is still spinning up and the
# USB bridge rejects SET FEATURES — see backlog #32. So this runs as a
# systemd oneshot instead (nase-spindown.service), where it can retry.
#
# Entry points: nase-spindown.service at boot, the same unit started by the
# udev rule on hot-plug, and spindown.sh during apply.sh.
# Idempotent — safe to re-run.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/drives/spindown_common.sh"

n=$(config_len '.drives')

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
        log_info "Drive '${name}': spindown disabled."
        continue
    fi

    # A drive that can't be configured is a warning, not a boot failure: the
    # other drives still need their settings, and this unit must never leave
    # the system in a degraded state just because one enclosure misbehaved.
    spindown_apply_drive "$name" "$uuid" "$hdparm_val" || true
done
