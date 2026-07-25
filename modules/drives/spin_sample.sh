#!/usr/bin/env bash
# modules/drives/spin_sample.sh
# Samples every active drive's spin state (via spin_status.sh, which never
# wakes a drive just to check — hdparm -C where supported, an I/O-activity
# heuristic otherwise) and appends one line per drive to a flat history log,
# so the web dashboard's Monitoring tab can render a spin/idle timeline.
# Called on a fixed interval by nase-spin-sample.timer (see
# modules/drives/setup.sh) — not by nase-monitor.timer, which only runs once
# a day and exists for SMART health, not spin-state sampling.
#
# Log format: "<epoch>\t<drive>\t<state>\t<confirmed|estimated>\t<reason>"
# <reason> is only populated on a standby/unknown -> active transition (a
# "wake" event) — it's a best-effort guess at what caused it, so the
# Monitoring tab can help answer "what keeps waking this drive up?" instead
# of just showing that it happened. Blank ("-") on every other sample.
# Idempotent — safe to re-run (just appends/prunes).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

STAMP_DIR="${NASE_STAMP_DIR:-/var/lib/nase}"
HIST_LOG="${STAMP_DIR}/spin-history.log"
mkdir -p "$STAMP_DIR"

# Not config-driven — a fixed retention window keeps this log tiny (a
# handful of drives x one line every 5 min for a month is only a few
# thousand lines) and matches the longest window button the web UI offers
# ("30 days"), so every window has full coverage.
RETENTION_DAYS=31

now=$(date +%s)
cutoff=$(( now - RETENTION_DAYS * 86400 ))

# guess_wake_reason <mountpoint>
# Best-effort explanation for a drive waking up, cheapest/most-likely first.
# Only checks things NASe itself schedules or knows about — anything else
# (manual command, external SSH session, a cron job we don't manage) falls
# through to the "unknown" bucket, which is itself a useful signal: a drive
# that wakes mostly for "unknown" reasons is worth investigating manually.
guess_wake_reason() {
    local mountpoint="$1"
    local reason="" i job src dst

    # Sync jobs run rsync and the integrity scan inline in the same systemd
    # unit (see modules/sync/sync.sh), so this one check covers both.
    local sn
    sn=$(config_len '.sync_jobs')
    for i in $(seq 0 $((sn - 1))); do
        job=$(config_idx '.sync_jobs' "$i" '.name')
        src=$(config_idx '.sync_jobs' "$i" '.source')
        dst=$(config_idx '.sync_jobs' "$i" '.dest')
        if [[ "$src" == "$mountpoint"* || "$dst" == "$mountpoint"* ]] \
           && systemctl is-active --quiet "nase-sync-${job}.service" 2>/dev/null; then
            reason="sync job: ${job}"
            break
        fi
    done

    if [[ -z "$reason" ]] && systemctl is-active --quiet nase-monitor.service 2>/dev/null; then
        reason="SMART health check (nase-monitor)"
    fi

    if [[ -z "$reason" ]] && command -v smbstatus &>/dev/null; then
        local connected shn shp j
        connected=$(smbstatus --shares 2>/dev/null | awk 'NR>2 {print $1}') || connected=""
        if [[ -n "$connected" ]]; then
            local shares_n
            shares_n=$(config_len '.samba.shares')
            for j in $(seq 0 $((shares_n - 1))); do
                shn=$(config_idx '.samba.shares' "$j" '.name')
                shp=$(config_idx '.samba.shares' "$j" '.path')
                if [[ "$shp" == "$mountpoint"* ]] && grep -qx "$shn" <<< "$connected"; then
                    reason="Samba client connected (share: ${shn})"
                    break
                fi
            done
        fi
    fi

    [[ -z "$reason" ]] && reason="unknown (no scheduled NASe job running — manual command or external access?)"
    echo "$reason"
}

n=$(config_len '.drives')
for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')
    [[ "$active" == "false" ]] && continue

    spin_info=$("${REPO_ROOT}/modules/drives/spin_status.sh" "$name")
    read -r state _since method <<< "$spin_info"
    [[ -n "$state" ]] || continue

    reason="-"
    if [[ "$state" == "active" ]]; then
        prev_state=$(awk -F'\t' -v n="$name" '$2==n {s=$3} END{print s}' "$HIST_LOG" 2>/dev/null || true)
        if [[ "$prev_state" != "active" ]]; then
            mountpoint=$(config_idx '.drives' "$i" '.mountpoint')
            reason=$(guess_wake_reason "$mountpoint")
        fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$now" "$name" "$state" "$method" "$reason" >> "$HIST_LOG"
done

# Prune anything older than RETENTION_DAYS in one pass — same
# read-filter-replace pattern as modules/primary-watch/record.sh.
if [[ -f "$HIST_LOG" ]]; then
    tmp=$(mktemp)
    awk -F'\t' -v c="$cutoff" '$1 >= c' "$HIST_LOG" > "$tmp" && mv "$tmp" "$HIST_LOG"
    chmod 644 "$HIST_LOG"
fi
