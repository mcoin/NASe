#!/usr/bin/env bash
# modules/drives/spin_status.sh <drive-name>
# Reports whether a drive is currently spinning, and since when.
#
# Preferred method: `hdparm -C`, which is non-intrusive — it only reads the
# drive's current power-mode register and never wakes a sleeping drive up
# just to check on it. Some USB-SATA bridges (seen on this box's primary
# drive) don't implement the ATA CHECK POWER MODE command and always answer
# "unknown" — for those we fall back to a heuristic: watch
# /sys/block/<disk>/stat read+write counters, and if they've been unchanged
# for longer than the drive's configured spindown_min, infer standby.
#
# State (and, for the heuristic, the last-seen I/O counter) is persisted to
# /var/lib/nase/spin-state/<name>.state so "since" survives across
# invocations (this script may be called every 30s by the web dashboard
# and separately by `nase drives`).
#
# Prints one line: "<state> <since-epoch> <confirmed|estimated>"
#   state: active | standby | unknown
#   since: unix timestamp state was first observed, or "-" if unknown
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/config.sh"

name="${1:?Usage: spin_status.sh <drive-name>}"

STATE_DIR="/var/lib/nase/spin-state"
mkdir -p "$STATE_DIR"
state_file="${STATE_DIR}/${name}.state"

uuid=""
spindown_min=0
n=$(config_len '.drives')
for i in $(seq 0 $((n - 1))); do
    if [[ "$(config_idx '.drives' "$i" '.name')" == "$name" ]]; then
        uuid=$(config_idx '.drives' "$i" '.uuid')
        spindown_min=$(config_idx '.drives' "$i" '.spindown_min')
        break
    fi
done

if [[ -z "$uuid" ]]; then
    echo "unknown - -"
    exit 0
fi

dev_symlink="/dev/disk/by-uuid/${uuid}"
if [[ ! -e "$dev_symlink" ]]; then
    rm -f "$state_file"
    echo "unknown - -"
    exit 0
fi

dev=$(readlink -f "$dev_symlink")
disk=$(lsblk -no pkname "$dev" 2>/dev/null || true)
disk_path="${disk:+/dev/${disk}}"
[[ -z "$disk_path" ]] && disk_path="$dev"
[[ -z "$disk" ]] && disk=$(basename "$dev")

now=$(date +%s)

# ── Preferred: direct query via hdparm -C ───────────────────────────────────
hdparm_out=$(hdparm -C "$disk_path" 2>/dev/null || true)
hdparm_state=""
if echo "$hdparm_out" | grep -qE "standby|sleeping"; then
    hdparm_state="standby"
elif echo "$hdparm_out" | grep -qE "active|idle"; then
    hdparm_state="active"
fi

f_method="" f_state="" f_since="" f_activity="" f_iocount=""
if [[ -f "$state_file" ]]; then
    read -r f_method f_state f_since f_activity f_iocount < "$state_file" || true
fi

if [[ -n "$hdparm_state" ]]; then
    if [[ "$hdparm_state" == "$f_state" && "$f_method" == "hdparm" && -n "$f_since" ]]; then
        since="$f_since"
    else
        since="$now"
    fi
    echo "hdparm ${hdparm_state} ${since} - -" > "$state_file"
    echo "${hdparm_state} ${since} confirmed"
    exit 0
fi

# ── Fallback: infer from /sys/block/<disk>/stat activity vs spindown timer ──
stat_file="/sys/block/${disk}/stat"
if [[ ! -r "$stat_file" ]] || [[ -z "$spindown_min" || "$spindown_min" == "0" ]]; then
    # No spindown configured (or no stat file) — nothing to infer against;
    # a drive with spindown disabled is assumed to stay spinning.
    rm -f "$state_file"
    if [[ ! -r "$stat_file" ]]; then
        echo "unknown - -"
    else
        echo "active ${now} estimated"
    fi
    exit 0
fi

spindown_secs=$(( spindown_min * 60 ))
read -r reads _ _ _ writes _ < "$stat_file"
io_count=$(( reads + writes ))

if [[ "$f_method" != "estimated" || -z "$f_iocount" ]]; then
    # First observation — assume active, start the activity clock now.
    echo "estimated active ${now} ${now} ${io_count}" > "$state_file"
    echo "active ${now} estimated"
    exit 0
fi

if [[ "$io_count" != "$f_iocount" ]]; then
    # Fresh I/O since last check.
    if [[ "$f_state" == "active" ]]; then
        since="$f_since"
    else
        since="$now"
    fi
    echo "estimated active ${since} ${now} ${io_count}" > "$state_file"
    echo "active ${since} estimated"
    exit 0
fi

idle_elapsed=$(( now - f_activity ))
if [[ "$idle_elapsed" -ge "$spindown_secs" ]]; then
    if [[ "$f_state" == "standby" ]]; then
        since="$f_since"
    else
        since=$(( f_activity + spindown_secs ))
        [[ "$since" -gt "$now" ]] && since="$now"
    fi
    echo "estimated standby ${since} ${f_activity} ${io_count}" > "$state_file"
    echo "standby ${since} estimated"
else
    if [[ "$f_state" == "active" ]]; then
        since="$f_since"
    else
        since="$f_activity"
    fi
    echo "estimated active ${since} ${f_activity} ${io_count}" > "$state_file"
    echo "active ${since} estimated"
fi
