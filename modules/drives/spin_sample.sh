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

# unit_ran_recently <unit> <window_secs>
# True if <unit> is active right now, OR last finished within the last
# <window_secs>. The instant-only check ("is-active now") misses oneshot
# jobs (config archive, SMART checks) that routinely start and exit again
# well within the ~5 min gap between spin samples — by the time we notice
# the drive woke up, the job that woke it is long since finished. Uses
# InactiveEnterTimestamp (last exit time) rather than ActiveEnterTimestamp:
# a Type=oneshot unit without RemainAfterExit passes through "active" so
# briefly that systemd leaves ActiveEnterTimestamp unset.
unit_ran_recently() {
    local unit="$1" window="$2"
    systemctl is-active --quiet "$unit" 2>/dev/null && return 0
    local ts_str ts_epoch
    ts_str=$(systemctl show "$unit" -p InactiveEnterTimestamp --value 2>/dev/null)
    [[ -z "$ts_str" || "$ts_str" == "n/a" ]] && return 1
    ts_epoch=$(date -d "$ts_str" +%s 2>/dev/null) || return 1
    (( ts_epoch <= now && now - ts_epoch <= window ))
}

# guess_wake_reason <mountpoint> <window_secs>
# Best-effort explanation for a drive waking up, cheapest/most-likely first.
# <window_secs> is how far back to look for a triggering job — normally the
# gap since the previous sample, so coverage has no blind spots between runs.
# Only checks things NASe itself schedules or knows about — anything else
# (manual command, external SSH session, a cron job we don't manage) falls
# through to the "unknown" bucket, which is itself a useful signal: a drive
# that wakes mostly for "unknown" reasons is worth investigating manually.
guess_wake_reason() {
    local mountpoint="$1" window="$2"
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
           && unit_ran_recently "nase-sync-${job}.service" "$window"; then
            reason="sync job: ${job}"
            break
        fi
    done

    if [[ -z "$reason" ]] && unit_ran_recently nase-monitor.service "$window"; then
        reason="SMART health check (nase-monitor)"
    fi

    if [[ -z "$reason" ]]; then
        local archive_dest
        archive_dest=$(config_get '.config_archive.dest // ""')
        if [[ -n "$archive_dest" && "$archive_dest" == "$mountpoint"* ]] \
           && unit_ran_recently nase-config-archive.service "$window"; then
            reason="config archive job"
        fi
    fi

    # Tree-connect audit (full_audit vfs module, see smb.conf.tmpl) rather than
    # a live `smbstatus` snapshot: a client that already disconnected within
    # the sampling gap (e.g. a phone briefly browsing a share) would be
    # invisible to a snapshot but still shows up here, since it's a log of
    # what happened over the whole window, not just what's connected now.
    if [[ -z "$reason" ]]; then
        local shn shp j shares_n hit client
        shares_n=$(config_len '.samba.shares')
        for j in $(seq 0 $((shares_n - 1))); do
            shn=$(config_idx '.samba.shares' "$j" '.name')
            shp=$(config_idx '.samba.shares' "$j" '.path')
            [[ "$shp" == "$mountpoint"* ]] || continue
            hit=$(journalctl -t smbd_audit --since "@$((now - window))" -q --no-pager 2>/dev/null \
                  | awk -F'|' -v s="$shn" '$3==s && $4=="connect" && $5=="ok" {print}' | tail -1) || true
            if [[ -n "$hit" ]]; then
                client=$(awk -F'|' '{print $2}' <<< "$hit")
                reason="Samba client connected (share: ${shn}${client:+, client ${client}})"
                break
            fi
        done
    fi

    # The web dashboard's /integrity page reads <mountpoint>/.nase/integrity.db
    # directly, so viewing it wakes every drive with a manifest. Sync/SMART/
    # archive/Samba checks above are cheaper, so this only runs when those
    # all came up empty.
    if [[ -z "$reason" ]]; then
        local hit client
        hit=$(journalctl -u nase-web.service --since "@$((now - window))" -q --no-pager 2>/dev/null \
              | grep -E 'GET /(partials/)?integrity(\?| )' | tail -1) || true
        if [[ -n "$hit" ]]; then
            client=$(grep -oE '[0-9]{1,3}(\.[0-9]{1,3}){3}' <<< "$hit" | head -1)
            reason="web dashboard: integrity page viewed${client:+ (client ${client})}"
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
        prev_rec=$(awk -F'\t' -v n="$name" '$2==n {t=$1; s=$3} END{if (t != "") print t"\t"s}' "$HIST_LOG" 2>/dev/null || true)
        prev_ts="${prev_rec%%$'\t'*}"
        prev_state="${prev_rec##*$'\t'}"
        if [[ "$prev_state" != "active" ]]; then
            mountpoint=$(config_idx '.drives' "$i" '.mountpoint')
            # Window = gap since the last sample, so the "did a job run in
            # between" checks have no blind spot — clamped so a long outage
            # or a missing first sample doesn't turn into a giant journal scan.
            if [[ -n "$prev_ts" ]]; then
                window=$(( now - prev_ts ))
            else
                window=600
            fi
            (( window < 300 )) && window=300
            (( window > 3600 )) && window=3600
            reason=$(guess_wake_reason "$mountpoint" "$window")
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
