#!/usr/bin/env bash
# modules/drives/spindown_common.sh
# Shared spindown helpers: the spindown_min -> hdparm -S conversion, UUID to
# whole-disk resolution, and the retrying hdparm applier.
# Sourced by spindown.sh (which writes the udev rule and applies settings
# during apply.sh), by spindown_apply.sh (the boot/hot-plug entry point) and
# by tests/test-spindown.sh.  Source this file; do not execute it.
#
# Requires lib/log.sh to be sourced first.

# hdparm binary, overridable so tests can substitute a stub.
NASE_HDPARM="${NASE_HDPARM:-hdparm}"

# Where UUID symlinks live, overridable for the same reason.
NASE_BY_UUID_DIR="${NASE_BY_UUID_DIR:-/dev/disk/by-uuid}"

# A USB drive is still spinning up when udev first sees it, and its bridge
# rejects SET FEATURES until it is ready — that race is what left both drives
# with no spindown at all after the 2026-09-05 reboot (backlog #32). Retry
# long enough to cover a cold spin-up (a 3.5" disk needs ~10-20 s) without
# holding the boot service open indefinitely.
NASE_SPINDOWN_RETRIES="${NASE_SPINDOWN_RETRIES:-6}"
NASE_SPINDOWN_RETRY_DELAY="${NASE_SPINDOWN_RETRY_DELAY:-5}"

# APM level applied to every managed drive. hdparm docs: 128-254 (many
# drives' factory default is 254) does *not* permit spin-down at the drive
# firmware level, and silently overrides -S no matter what timer is set.
# 127 is the least aggressive value that still permits spin-down, so it
# doesn't fight normal I/O.
NASE_SPINDOWN_APM_LEVEL=127

# spindown_min_to_hdparm <minutes>
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

# spindown_disk_for_uuid <uuid>
# Print the whole-disk device node for a filesystem UUID, or nothing if the
# drive isn't attached. -B/-S address the disk, not a partition, and the UUID
# belongs to the partition — so this resolves one to the other. Device letters
# are never stable across reboots (CLAUDE.md, backlog #27), so UUID is the
# only safe way in.
spindown_disk_for_uuid() {
    local uuid="$1"
    local link="${NASE_BY_UUID_DIR}/${uuid}"
    [[ -e "$link" ]] || return 0

    local dev disk
    dev=$(readlink -f "$link")
    disk=$(lsblk -no pkname "$dev" 2>/dev/null || true)
    if [[ -n "$disk" ]]; then
        echo "/dev/${disk}"
    else
        # No parent: the filesystem sits on the whole disk already.
        echo "$dev"
    fi
}

# spindown_hdparm_try <disk> <flag> <value>
# Apply one hdparm setting, retrying transient failures.
#   0 = applied
#   1 = still failing after every retry
#   2 = the bridge says the feature isn't supported — permanent, don't retry
# The distinction matters: primary's JMS578 bridge has no APM at all, and
# retrying it six times would add half a minute to every boot for a setting
# that can never take.
spindown_hdparm_try() {
    local disk="$1" flag="$2" value="$3"
    local attempt=1 out

    while :; do
        if out=$("$NASE_HDPARM" "$flag" "$value" "$disk" 2>&1); then
            return 0
        fi
        if [[ "$out" == *"not supported"* ]]; then
            return 2
        fi
        if [[ "$attempt" -ge "$NASE_SPINDOWN_RETRIES" ]]; then
            return 1
        fi
        sleep "$NASE_SPINDOWN_RETRY_DELAY"
        attempt=$(( attempt + 1 ))
    done
}

# Spin-state reporter, overridable for tests. Asking it never wakes a drive —
# that is the whole point of spin_status.sh.
NASE_SPIN_STATUS="${NASE_SPIN_STATUS:-${REPO_ROOT:-/opt/nase}/modules/drives/spin_status.sh}"

# spindown_drive_is_parked <name>
# True if the drive is already asleep. Measured on this box: an hdparm -B/-S
# *set* spins a sleeping drive back up (backup_daily went standby -> active
# when the settings were applied on 2026-09-06), so applying to a parked
# drive costs a full spin-up. It also buys nothing — a drive that reached
# standby demonstrably has working spin-down, and the paths that matter
# (boot, hot-plug) both run while the drive is spinning anyway.
spindown_drive_is_parked() {
    local out state
    out=$("$NASE_SPIN_STATUS" "$1" 2>/dev/null || true)
    state="${out%% *}"
    [[ "$state" == "standby" || "$state" == "sleeping" ]]
}

# spindown_apm_supported <disk>
# True if the bridge exposes APM at all. This is a *read* (`hdparm -B` with no
# value), which — unlike a set — is safe on a sleeping drive: it answers from
# the bridge without spinning the platter up. Asking first means primary,
# whose JMS578 has no APM, costs one query per boot instead of a full retry
# budget of failing writes against a drive we are trying not to disturb.
spindown_apm_supported() {
    local out
    out=$("$NASE_HDPARM" -B "$1" 2>&1 || true)
    [[ "$out" != *"not supported"* ]]
}

# spindown_apply_drive <name> <uuid> <hdparm_val>
# Apply APM and the standby timer to one drive, by UUID. Returns non-zero
# only when the drive is present and its standby timer could not be set.
#
# -B and -S go in as separate invocations on purpose. Run as one command,
# a bridge without APM support fails the whole invocation and the standby
# timer never gets set either — which is what the old udev rule did to
# primary on every boot.
spindown_apply_drive() {
    local name="$1" uuid="$2" hdparm_val="$3"
    local disk rc

    disk=$(spindown_disk_for_uuid "$uuid")
    if [[ -z "$disk" ]]; then
        log_info "Drive '${name}': not attached — spindown will be applied when it appears."
        return 0
    fi

    if spindown_drive_is_parked "$name"; then
        log_info "Drive '${name}' (${disk}): already parked — leaving it alone rather than waking it to configure it."
        return 0
    fi

    local applied=()
    if spindown_apm_supported "$disk"; then
        rc=0; spindown_hdparm_try "$disk" -B "$NASE_SPINDOWN_APM_LEVEL" || rc=$?
        case "$rc" in
            0) applied+=("-B ${NASE_SPINDOWN_APM_LEVEL}") ;;
            2) log_info "Drive '${name}' (${disk}): bridge reports no APM support — leaving -B alone." ;;
            *) log_warn "Drive '${name}' (${disk}): could not set APM level ${NASE_SPINDOWN_APM_LEVEL}; the drive may refuse to spin down." ;;
        esac
    else
        log_info "Drive '${name}' (${disk}): bridge reports no APM support — leaving -B alone."
    fi

    rc=0; spindown_hdparm_try "$disk" -S "$hdparm_val" || rc=$?
    case "$rc" in
        0) applied+=("-S ${hdparm_val}")
           log_ok "Drive '${name}' (${disk}): spindown applied (${applied[*]})." ;;
        2) log_warn "Drive '${name}' (${disk}): bridge reports no standby-timer support — this drive will not spin down on its own." ;;
        *) log_warn "Drive '${name}' (${disk}): could not set standby timer -S ${hdparm_val} after ${NASE_SPINDOWN_RETRIES} attempts." ;;
    esac
    [[ "$rc" -eq 0 ]]
}
